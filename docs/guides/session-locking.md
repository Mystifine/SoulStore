# Session Locking

## Identity and lifecycle

SoulStore separates three identities:

| Identity | Use |
|---|---|
| UserId | Persisted DataStore key, encoded as a string. |
| Exact Player instance | Live object lookup within a DataStore and scope. |
| GUID SessionToken | Ownership stored in `MetaData.SessionId`. |

Each rejoin creates a fresh Player instance, soul, and token. An old soul can finish saving while a new soul waits for its lock. The old object is never handed to the new Player.

```text
Pulling -> Active -> Ending -> Ended
Pulling -> Cancelled
```

Pulling souls are cached to prevent duplicate acquisitions, but are unavailable through `getSoul` and gameplay methods. Concurrent `LoadData` calls share one acquisition. Gameplay starts only when `LoadData` returns `true`.

## Acquisition and writes

`UpdateAsync` atomically loads the record and claims its lock. A foreign live lock causes retry while the player remains present. An already-owned token is recognized when retrying after an uncertain network response.

Every save verifies that the persisted record names its exact token. A missing or foreign owner cancels the write, whether the record is locked, released, or expired: those only decide whether a new session may claim it. Returning from `UpdateAsync` without an API error does not by itself mean the save was accepted.

Normal saves make one attempt and report the result, because the next autosave carries newer data anyway. Only the final save retries.

Ending immediately blocks gameplay access and captures the final snapshot. Writers are serialized, so the final save waits behind an in-flight regular save. The same `UpdateAsync` writes the final data and clears `Locked` and `SessionId`. The lock is never released in advance of that write.

Departure during pulling cancels loading. If acquisition commits while cancellation is happening, SoulStore releases the acquired record without making it Active. PlayerRemoving targets the exact departing Player instance.

If the acquisition response failed and ownership is uncertain, cancellation probes only for its own token and releases it without acquiring a free record or refreshing the lock. Recovery retries for up to `ACQUISITION_RECOVERY_TIMEOUT` (30 seconds by default). If ownership cannot be resolved, the soul settles with `AcquisitionUncertain` and any remaining lock expires naturally. An already-submitted network request cannot be forcibly interrupted.

## Crash recovery

`SESSION_EXPIRY` (2 minutes) is the one setting for session locks. A lock can be taken once Roblox's `UpdatedTime` for the key says it has gone that long without a write. A live session writes every autosave, so this much silence means its server crashed or cannot reach the data store.

A load does not take an expired lock on first sight. It waits `TAKEOVER_DELAY` (15 seconds) and takes it only if it has not changed. After an outage every lock looks expired, and its owner may be about to land its final save, which retries at most about every 10 seconds, so the final save gets there first.

A failed request restarts that wait, because it says nothing about the owner, which may be failing the same way. A write from the owner restarts it too, and the claim only goes through on the exact version of the lock that was watched. Leaving and coming back costs nothing, because the lock's age keeps counting.

If this server's clock is slow, a lock can look newer than it is. So a load that has watched a lock for all of `SESSION_EXPIRY` takes it, however new it looks.

Any later write from the former owner is rejected by its token check, and that session ends with `OwnershipLost`. The module does not automatically kick the player. Applications can use the completion event to choose their disconnect or recovery flow.

An outage does not end a session. It stays Active and keeps accepting changes, and its next save lands once the store is back.

Keep the expiry comfortably longer than the autosave interval and expected DataStore delays. Shortening it trades faster crash recovery for a greater chance of taking over a session that is only slow.

Never allow gameplay on defaults while waiting for another session's lock. Existing malformed data is not treated as a missing save.

## Shutdown

`BindToClose` stops new sessions, cancels pending loads, and requests final saves for active sessions. Already-ending sessions remain tracked. Shutdown checks each session's state until all have settled, and keeps the server up for as long as Roblox allows, which is 30 seconds. Retries stay short during this time, which allows about seven attempts.

Network outages, hung requests, or platform termination can prevent a confirmed final save. Shutdown does not guarantee that every write succeeds; unreleased locks recover through expiry.

`SessionEndBindableEvent` fires once for terminal outcomes with `(state, reason)`. Cancellation or ownership loss is completion, not proof of a successful final save.

## Updating existing servers

The persisted layout is unchanged: `MetaData.SessionId` remains a string, now containing an opaque GUID instead of JobId. Existing unlocked saves need no migration; existing locked saves remain protected until release, takeover or expiry.

Drain old servers when deploying this change. Old code cannot enforce the new lifecycle and may already have pending writes that use only JobId. All new application code must treat SessionId as opaque; log JobId separately when debugging.
