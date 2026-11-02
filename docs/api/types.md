# Types

## `SoulMetaData`

Metadata persisted beside player data and managed by SoulStore:

```lua
export type SoulMetaData = {
    Locked: boolean,
    SaveId: number,
    LastUpdate: number,
    SessionId: string,
}
```

| Field | Meaning |
|---|---|
| `Locked` | A session owns the key. |
| `SaveId` | Save counter derived from the persisted record when saving. |
| `LastUpdate` | Unix timestamp refreshed by acquisition and saves; used for crash recovery. |
| `SessionId` | Opaque GUID session token, or `""` when unlocked. |

`MetaData` is reserved. `game.JobId` identifies a server, not its individual player sessions.

## `Soul`

A soul represents one DataStore session for one exact Player instance. Do not reassign identity properties.

| Property | Type | Meaning |
|---|---|---|
| `DatastoreId` | `string` | DataStore name. |
| `Scope` | `string` | DataStore scope; `"global"` unless one was given. |
| `DatastoreKey` | `string` | Persisted key, the UserId as a string. |
| `Player` | `Player` | Exact Player instance. |
| `UserId` | `number` | Immutable UserId used for the persisted key. |
| `SessionToken` | `string` | Immutable GUID identifying this session. |
| `Data` | `table` | Live data; use only while Active. |
| `LastAutoSave` | `number` | When the last save started, in `os.clock` time. |
| `IsSaving` | `boolean` | A save is in flight. |
| `SessionState` | `string` | Authoritative lifecycle state. |
| `EndReason` | `string?` | Reason the session settled. |
| `LoadState` | `string` | Compatibility load status; use SessionState for readiness. |
| `SaveState` | `string` | Compatibility save status. |
| `SessionEndBindableEvent` | `BindableEvent` | Fires once with `(state, reason)`, then is destroyed. |

```text
Pulling -> Active -> Ending -> Ended
Pulling -> Cancelled
```

Pulling is pending acquisition or initialization. Active permits gameplay and autosaves. Ending blocks gameplay while finalization runs. Ended and Cancelled are terminal; never reuse those objects. A confirmed acquisition during cancellation is released before settlement. An uncertain acquisition receives bounded recovery attempts, then relies on stale-lock expiry if the service remains unavailable.

`LoadData` and `SaveData` return `(boolean, string?)`. Terminal state alone does not prove a confirmed final save.

Gameplay methods also check the last confirmed lease age. Prefer `getSoul` over testing the state string alone. An expired lease blocks gameplay immediately, then background finalization ends the session with `LeaseExpired` if its final write succeeds, or `OwnershipLost` if another session has taken over. No automatic player kick occurs.

## `SoulStore`

The exported namespace type describes construction, session lookups, metadata/copy helpers, logging, and resets. See [Static Methods](soulstore.md) and [Soul Methods](soul.md) for signatures.
