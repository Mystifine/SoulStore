# Edge Cases

Roblox data stores fail in ways that are easy to miss. This page lists the known ones, what SoulStore does about each, and where the case comes from. Every row has a test in `tests/edgecases.luau`, `tests/lifecycle.luau` or `tests/consumers.luau`. The tests run against a simulated data store, and `tests/studio/DataStoreProbe.server.luau` checks its rules against real data stores. Where this page disagrees with older forum posts, the probe is why.

## How UpdateAsync behaves

| Case | What SoulStore does | Source |
|---|---|---|
| Roblox runs the transform again on newer data if another server wrote first | Clears its decision at the start of every run, so only the last run counts | [GlobalDataStore][global] |
| The transform returns nil, which cancels the write | Records why inside the transform, because the call itself only returns nil | [GlobalDataStore][global] |
| The transform errors or yields, which raises nothing: Roblox prints `Transform function error`, returns nil and writes nothing | Never yields inside a transform, and hooks run outside it. A call that returns nothing counts as a failed attempt. It never ends a session, and a load waits before trying again | Probe, [DevForum][yield] |
| The call errors although the write landed | Treats the outcome as unknown. The next attempt reads the record and finds its own token | [Limits][limits] |
| User ids and key metadata are cleared unless the transform returns them | Returns them on every write, including releases | [GlobalDataStore][global] |
| A negative test id from Studio is sent as a user id | Only real user ids are sent | [ProfileStore][profilestore] |
| A key already has the most user ids allowed, which would fail every save with error 512 | Leaves the list as it is and saves | [Limits][limits] |
| `GetAsync` can answer from a cache up to four seconds old | Never reads with `GetAsync`. Every read goes through `UpdateAsync` | [Caching][caching] |

## What a data store can hold

| Case | What SoulStore does | Source |
|---|---|---|
| Functions, Instances, Vector3 and other Roblox types, which fail the whole write with error 104 | `SetData` refuses them. If one arrives through a direct table write, it is left out of the save and reported with its path | Probe, [ProfileStore][troubleshooting] |
| A boolean key, which silently cancels the whole write | The same | Probe |
| A table or Instance used as a key, or an infinite key, which is stored under a meaningless name | The same | Probe |
| A thread, which Roblox leaves out without a word | The same | Probe |
| Strings and keys that are not valid UTF-8 (error 104) | The same | Probe, [GlobalDataStore][global] |
| Infinity | An ordinary number: it saves and comes back. Older reports of it failing no longer hold | Probe |
| NaN | Also comes back as it went in, so a save keeps it and warns. `SetData` refuses it, since it is always a bug and would replace a good value | Probe |
| Buffers | Stored normally, and copied rather than shared, so a change after the final copy cannot reach the save | Probe, [DevForum][buffer] |
| A table with a length and string keys, which loses every string key. At the top of a save that means every named field and `MetaData`, which is how one stray `[1]` could wipe a whole save | `SetData` refuses it. Through a direct write, a save stores the number keys as strings so that nothing is lost, and warns once per session, naming the table | Probe, [DevForum][mixed], [DataStore2][verifier] |
| An array with a gap, which Roblox cuts short if the gap is where its length stops, depending on how the table was built | Copies keep each table's length, and a table that would still be cut is rebuilt at its full size, so it comes back with the same indexes | Probe, [DevForum][sparse] |
| Number keys with no length, which come back as strings | `SetData` refuses them. Through a direct write, written as they are, with a warning | Probe, [ProfileStore][troubleshooting] |
| Fractional keys, which come back as whole numbers in strings, so `1.1` and `1.9` land on the same key | `SetData` refuses them. Through a direct write, stored under their full text, so that neither is lost, with a warning | Probe |
| Defaults that could not be saved, or a record stored as an array, which could never hold `MetaData` | `new` returns `nil`, or the load stops with `CorruptData` and the record is left as it is | Probe |
| A table that contains itself, which silently cancels the whole write | `SetData` refuses it. Through a direct write, normal saves report `InternalError`, and a final save frees the record with the last good save | Probe, [DataStore2][verifier] |
| A save over 4 MB (error 105) | Reported as `SaveRejected`. The session continues and recovers once the save shrinks. A final save frees the record with the last good save | [Limits][limits] |
| `soul.Data` replaced with something that is not a table | Saves fail safely and the stored record is untouched | [ProfileStore][profilestore] |
| A record that is not a save at all | `CorruptData`. It is left exactly as it is, never replaced with defaults | [Best practices][best] |

## Errors

| Case | What SoulStore does | Source |
|---|---|---|
| An error retrying cannot fix: 101-107, 401-403, 509, 511-513 | Stops at once, with no retries | [Limits][limits] |
| An unpublished place, or Studio without API access | Stops at once with `DataStoreError` rather than retrying forever | [ProfileStore][profilestore] |
| `502: ... HTTP 403` | Stops in Studio, where it means no access. Retries on a live server | [ProfileStore][profilestore] |
| Queue-full drops, 5xx errors, `KeyThrottled`, `ExperienceThrottled` and anything unrecognized | Retries | [Limits][limits] |
| Retrying at the same moment as everyone else | Delays grow by half up to `MAX_RETRY_INTERVAL`, or `MAX_FINAL_SAVE_RETRY_INTERVAL` for a final save, and each wait varies by 20% either way | [Best practices][best] |
| A save request never returns | The next save runs after `HUNG_SAVE_TIME` (60 seconds). Only the newest write may land, so the hung one cannot undo a newer save if it comes back late | |
| A failed load being treated as a new player | Defaults are only used when the store answers that no record exists | [Best practices][best] |
| A long outage at load | `LoadData` keeps waiting and writes nothing. A game can stop waiting by calling `SaveData(true)` or kicking the player | [Player data][purchasing] |

## More than one server

| Case | What SoulStore does | Source |
|---|---|---|
| A teleport arrives before the old server has seen the player leave | The new server waits, then loads the final save | [Player data][purchasing] |
| A retry of an old write landing after a newer one | Saves write only while the record names their own token | [Best practices][best] |
| A server crashes while holding a lock | Another server takes over once the lock is past `SESSION_EXPIRY` (2 minutes) and has looked the same for `TAKEOVER_DELAY` (15 seconds) | [ProfileStore][profilestore] |
| A healthy server loses its lock to a player waiting elsewhere | Its autosaves keep the lock from expiring, unless its clock or the reader's is badly wrong. See below | |
| An outage makes a live server look dead | A failed request restarts `TAKEOVER_DELAY`, so only an unchanged lock seen through working requests counts. A live session's next autosave can still be up to 30 seconds away, so if that player is loading on a second server just then, the load can win. The old session's next write is refused, and what it had not saved is lost | |
| A long outage ends, every lock now looks expired, and a new server reaches a lock before its old owner lands its final save | `TAKEOVER_DELAY` is longer than a final save's slowest retry, so the final save gets there first and nothing is lost | `tests/load.luau` |
| A new server's connection recovers more than `TAKEOVER_DELAY` before the old server's | The new server takes the expired lock. The old session's next write is refused, so nothing is overwritten, but what it had not saved is lost | |
| A server cut off from the store is taken over, then comes back | Its next write is refused. The session ends with `OwnershipLost` and writes nothing | [Player data][purchasing] |
| A record is deleted during a session | The session ends with `OwnershipLost` and does not bring the record back | [Lapis][lapis] |
| A teleport fails after the session was released | The same Player can call `SoulStore.new` again and load normally | [ProfileStore][troubleshooting] |

## Clocks

Servers can disagree about the time, by up to five minutes [according to one report][clock]. In the one test that measured it, a Studio machine was 9.5 seconds off Roblox's own timestamps.

| Case | What SoulStore does |
|---|---|
| A writer's clock is slow, so its live lock looks old | Lock age comes from Roblox's `UpdatedTime`, not the writer's clock |
| A reader's clock is slow, so a dead lock looks new | A load that has watched a lock for all of `SESSION_EXPIRY` takes it, however new it looks |
| A server's clock jumps forward or back | Autosaves use `os.clock`, so it does not stop them |
| A reader's clock is far ahead | It reads a live lock as expired, and can take it after `TAKEOVER_DELAY`, between the owner's autosaves. The old session's next write is refused, so nothing is overwritten, but what it had not saved yet is lost. It takes a clock about 2 minutes off, and that player loading on a second server while the first still holds them |

## Budgets and throttling

| Case | What SoulStore does | Source |
|---|---|---|
| The request budget runs out | Autosaves wait for budget, and only as many start as it allows. Whoever has waited longest goes first, so nobody is left behind while others save again | [Limits][limits], outside review |
| Saves bunching up after a stall, which would copy every player's data in one frame | No more than twice the steady rate starts in one second | |
| The request queue fills, which drops requests with error 304 | Final saves are never held back, and a dropped one retries | [Limits][limits] |
| A save too large to write every 30 seconds, since each key is limited to 4 MB per minute | Throttled writes fail like any other. The session stays active and the final save retries | [Limits][limits] |
| Many players load at once | Autosaves are spread over the whole interval, as Roblox's own sample does, and stay spread | [Best practices][best], [Player data][purchasing] |

## Shutdown

| Case | What SoulStore does | Source |
|---|---|---|
| `Players:GetPlayers()` is already empty at shutdown | Works from its own list of sessions | [DevForum][close] |
| A player leaves during shutdown | One write, not two | [DevForum][close] |
| A request never returns | Roblox ends the server after 30 seconds. The lock recovers when it expires | [BindToClose][bindtoclose] |
| Many players on a slow store | Saves run side by side | [BindToClose][bindtoclose] |
| A change arrives after shutdown began | `SetData` returns nil rather than losing it silently | |

## Players leaving

| Case | What SoulStore does | Source |
|---|---|---|
| Roblox runs `PlayerRemoving` handlers newest first, so a handler connected after SoulStore's runs before it | The final save starts once every handler has run, so what any of them writes is saved | Probe |
| A leave handler clears state a save hook reads | The hook finds it gone. See [the rules for leave handlers](lifecycle-hooks.md#when-a-player-leaves) | Probe |
| `player.Parent` is nil by the time deferred work runs | A session does not depend on it, so the final hook can still read the session | Probe |

## Hooks

| Case | What SoulStore does | Source |
|---|---|---|
| A hook errors or yields | That copy is not written. A final save writes the session without the hook | |
| A hook calls `SaveData` or `LoadData`, on this soul or another, which would wait inside a thread that is cancelled for waiting, and strand the session in `Ending` with its lock held | Refused with `CalledFromHook`, and the save that ran the hook carries on. `SaveData(true)` in `SetOnLoad` still cancels the load, since that needs no waiting | Outside review |

## What only your game can do

**Check `LoadData`.** A load can fail for good, so don't start gameplay without checking it.

**React when a session ends during play.** SoulStore stops accepting changes but does not kick the player. [Migrating](migrating.md) has an example.

**Record purchases in the save.** Follow [Roblox's steps][purchasing]: check the purchase id, grant, record the id, then return `PurchaseGranted` only if `SaveData()` returned `true`. If the save failed, the retry finds the id and saves again without granting twice.

**Save before a teleport.** Call `SaveData(true)` and wait for it, so the destination does not have to wait for the lock. If the teleport fails, start a new session.

**Save both sides of a trade.** Session locking stops a player loading old data, but one side of a trade can still land without the other. Call `SaveData()` on both, and do not treat the trade as final unless both return `true`.

**Keep Studio away from live data.** With API access on, Studio writes to real keys. Use a different store name in Studio, as your games already do.

**Take a snapshot before an update that changes how data is saved.** Version history only keeps the first write of each UTC hour, for 30 days. [Snapshots][caching] protect what was written just before the update.

**Set up right-to-erasure.** SoulStore tags each key with the player's user id, and `RemoveAsync` leaves old versions for up to 30 days. Roblox's [automated right-to-be-forgotten][best] handles keys that follow a fixed pattern.

**Keep saves well under 2 MB.** At the default autosave interval, larger saves are throttled by the per-key limit on some autosaves.

**Numbers above 2^53 lose precision**, as they do everywhere in Luau. Store larger values as strings.

[global]: https://create.roblox.com/docs/reference/engine/classes/GlobalDataStore
[limits]: https://create.roblox.com/docs/cloud-services/data-stores/error-codes-and-limits
[best]: https://create.roblox.com/docs/cloud-services/data-stores/best-practices
[caching]: https://create.roblox.com/docs/cloud-services/data-stores/versioning-listing-and-caching
[purchasing]: https://create.roblox.com/docs/cloud-services/data-stores/player-data-purchasing
[bindtoclose]: https://create.roblox.com/docs/reference/engine/classes/DataModel
[profilestore]: https://github.com/MadStudioRoblox/ProfileStore
[troubleshooting]: https://madstudioroblox.github.io/ProfileStore/troubleshooting/
[verifier]: https://github.com/Kampfkarren/Roblox/blob/master/DataStore2/Verifier.lua
[lapis]: https://github.com/nezuo/lapis
[yield]: https://devforum.roblox.com/t/cant-use-teleportservicereserveserver-inside-updateasync-transform-function-error-callbacks-cannot-yield/1832335
[buffer]: https://devforum.roblox.com/t/introducing-luau-buffer-type-beta/2724894
[mixed]: https://devforum.roblox.com/t/saving-a-datastore-mixed-array-issue/351862
[sparse]: https://devforum.roblox.com/t/data-store-stringifies-array-indexes-if-array-doesnt-start-from-index-1-and-behaves-incosistently-when-array-has-missing-indexes/3677213
[clock]: https://devforum.roblox.com/t/ostime-returns-values-up-to-5-minutes-in-the-past-and-in-the-future/337324
[close]: https://devforum.roblox.com/t/can-this-happen-for-updateasync/4818300
