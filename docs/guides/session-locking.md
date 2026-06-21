# Session Locking

## The Problem

Roblox does not guarantee only one server has a player loaded at a time. During teleports, crashes, or shutdown races, two servers can briefly both believe they own the same player. If both write to the same DataStore key, the last write wins — potentially overwriting progress.

## How SoulStore Handles It

On load, SoulStore uses `UpdateAsync` to atomically claim ownership of the key:

```lua
readData.MetaData.Locked     = true
readData.MetaData.SessionId  = game.JobId
readData.MetaData.LastUpdate = os.time()
```

A second server seeing `Locked = true` with a foreign `SessionId` enters a retry loop and logs the time remaining until the lock expires. It cannot write to the key until it acquires the lock.

On a clean session end, the lock is released:

```lua
MetaData.Locked    = false
MetaData.SessionId = ""
```

## Lock Expiry (Crash Recovery)

If a server crashes without releasing its lock, the lock expires after `SESSION_LOCK_AUTO_RELEASE` seconds. The waiting server calculates:

```
timeRemaining = SESSION_LOCK_AUTO_RELEASE - (os.time() - MetaData.LastUpdate)
```

Because `LastUpdate` is refreshed on every auto-save, frequent saves reduce how long a second server must wait after a crash.

## Tuning Recommendations

| Use Case | `AUTO_SAVE_INTERVAL` | `SESSION_LOCK_AUTO_RELEASE` |
|---|---|---|
| Casual game | 60s | 120s |
| RPG / economy | 60s | 300s |
| Competitive / ranked | 60s | 600s |

!!! warning
    Always keep `SESSION_LOCK_AUTO_RELEASE ≥ AUTO_SAVE_INTERVAL × 3`.
    If the release window is shorter than the save interval, a slow auto-save can allow another server to steal the lock mid-session.

## Graceful Shutdown

SoulStore binds to `game:BindToClose`, which Roblox calls before planned server shutdowns:

1. Spawns a session-ending save for every cached soul.
2. Yields until all `SessionEndBindableEvent` signals fire.
3. All locks are released before the process exits.

Crash scenarios rely on the lock expiry mechanism above.