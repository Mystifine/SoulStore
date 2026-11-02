# How It Works

This page is for anyone changing SoulStore itself.

## Where things live

| File | What it does |
|---|---|
| `init.luau` | The public API: every soul method and `SoulStore` function, plus autosave, leaving and shutdown. |
| `Session.luau` | The flow: claiming a record, normal saves and final saves. |
| `SessionCache.luau` | Which souls have not settled yet. |
| `DataValidator.luau` | What a data store can hold. |
| `Reset.luau` | `resetData` and `resetAllData`. |
| `Logger.luau` | Output, including the rule that warnings always show. |
| `Config.luau` | Settings. |
| `DeepCopyUtil.luau` | Copying tables. |
| `Types.luau` | Exported types. |

## The rules

**One owner per record.** Each session gets its own token, stored in `MetaData.SessionId`. A load may claim a record that is unlocked, already holds its own token, or has a lock it has watched not change for `LOCK_TAKEOVER_TIME`, or for less if the lock is older than `SESSION_LOCK_EXPIRY`. A save only asks whether the token is still its own. `Locked` and expiry never decide a save.

**One lifecycle.** `SessionState` is the only state that decides anything. Only an Active session can read or write.

```text
Pulling -> Active -> Ending -> Ended
Pulling -> Cancelled
```

**One writer at a time.** `IsSaving` makes saves queue behind each other, so two writes for a session never race.

**A lease.** A session with no confirmed write for `SESSION_LOCK_EXPIRY` stops accepting changes and attempts its final save, so a player does not keep playing for long on progress that cannot be saved. Another server may claim the record sooner than that, after `LOCK_TAKEOVER_TIME`, because a player waiting elsewhere is not playing on this session. The token check stops the old session's writes whichever comes first.

**Fail closed.** Refuse rather than guess: corrupt data is never replaced, a failed hook never writes, and a player waiting on a lock never plays on defaults.

**One clock for each job.** `os.clock` measures anything local, such as leases, autosaves and how long a lock has gone unchanged, because it cannot jump. `os.time` only compares against Roblox's `UpdatedTime`, and is written as `LastUpdate` for older servers to read.

**A table's shape is decided before Roblox sees it.** Roblox stores a table with a length as an array that stops there, losing every other key. So a save never hands Roblox a table that would lose anything, `SetData` refuses to create one, and copies use `table.clone`, because rebuilding an array key by key can change its length. See `DataValidator.removeUnstorable`.

**Nothing that waits starts inside a hook.** A hook runs on its own thread, which is cancelled if it yields. A save or load started there would stop halfway with its session stranded, so `isInsideHook` refuses them, whichever soul they are for.

## Loading

`Session.load` runs `acquireSession`, which calls `UpdateAsync` until one of these happens:

| Result | What happens next |
|---|---|
| Claimed | `finishAcquisition` runs `OnLoad`, then makes the session Active. If the player left in the meantime, it releases the lock instead. |
| Locked by someone else | Waits `LOAD_ATTEMPT_INTERVAL` and tries again. Takes the lock over once it has not changed for `LOCK_TAKEOVER_TIME`, or for `MAX_RETRY_INTERVAL` x 1.5 if it is older than the lease. That is still longer than a final save's slowest retry, so an owner that outlived an outage reaches the record first. |
| Request failed | Waits with a growing delay and tries again, unless the error cannot be fixed by retrying. Restarts the takeover wait. |
| Corrupt record | Stops without touching it. |
| Player left | Cancels. If an earlier attempt may have taken the lock, it tries to release it for up to `ACQUISITION_RECOVERY_TIMEOUT`. |

## Saving

**Normal save (`Session.save`).** Used by autosave and `SaveData()`. Waits behind any running save, copies the data, runs `OnSave` on the copy, and makes one write. If it fails, the next autosave tries again.

**Autosave (`runSchedulerTick` in `init.luau`).** Runs once a second. Starts at most twice the steady rate and never more than the request budget, longest wait first, so that a backlog does not land in one frame, and a small budget still goes round everyone.

**Final save (`Session.finish`).** Used when leaving, at shutdown, and by `SaveData(true)`. When a player leaves, it is deferred until every other `PlayerRemoving` handler has run, because Roblox runs the newest connection first and SoulStore's is one of the oldest. See [When a player leaves](lifecycle-hooks.md#when-a-player-leaves).

1. Copy the data and run `OnSave` right away, before anything can yield, so nothing that runs later can change what gets written. If the hook fails, make the copy again without it.
2. Move to Ending, which blocks gameplay.
3. Wait behind any running save.
4. Write the data and unlock in the same `UpdateAsync`.
5. Retry until the write lands, another session owns the record, or an error occurs that retrying cannot fix. In that last case the lock is released without the final data, so the player can rejoin on their last good save.

Retries start at `RETRY_INTERVAL` and grow to `MAX_RETRY_INTERVAL`. During shutdown they stop growing at three times `RETRY_INTERVAL`, because the server only has about 30 seconds.

`writeRecord` is the only place a save reaches the data store. Roblox may run a transform more than once, so it sets every metadata field from the record it was given rather than adding to a copy.

## Ending a session

`Session.settle` is the one place a session ends. It sets the final state and reason, removes the soul from the cache, then fires `SessionEndBindableEvent` once and destroys it. Shutdown checks each session's state rather than counting those events, because a state cannot be missed or drift.

## Checking your changes

```powershell
stylua src tests
selene src tests
lune run tests/lifecycle.luau
lune run tests/edgecases.luau
lune run tests/consumers.luau
lune run tests/games.luau
lune run tests/fakestore.luau
lune run tests/load.luau
rojo build --output SoulStore.rbxlx
```

`.github/workflows/validate.yml` runs all of these except `tests/games.luau`, which needs your games in sibling folders. The tests use a virtual clock and a fake data store. `tests/studio/` has the probe that checks the fake data store against real ones, the end-to-end run of the real module, and a full server's worth of sessions on the real engine. Run them in a published test place before releasing. [Load Testing](load-testing.md) has what the big runs found.
