# Migrating from 1.x

The save format is unchanged, so existing saves load without a migration. Drain old servers when you release, because old pending writes cannot enforce the new per-session ownership.

## Arguments that changed

`scope` is now the second argument. Pass `nil` to keep using the same data as before.

| 1.x | 2.0 |
|---|---|
| `SoulStore.new(id, player, defaults)` | `SoulStore.new(id, nil, player, defaults)` |
| `SoulStore.getSoul(id, player)` | `SoulStore.getSoul(id, nil, player)` |
| `SoulStore.resetData(id, key)` | `SoulStore.resetData(id, nil, key)` |
| `SoulStore.resetAllData(id)` | `SoulStore.resetAllData(id, nil)` |

An old-style call fails safely with a warning: `new` and `getSoul` return `nil`, and `resetData` deletes nothing.

Every other function and method keeps its name and arguments.

## Same call, different behaviour

| Call | What changed |
|---|---|
| `LoadData()` | Returns `true`, or `false` and a reason. Stops on corrupt data or an error retrying cannot fix, instead of retrying forever. |
| `SaveData()` | Makes one attempt and returns the result. In 1.x it retried until the write landed, which blocked the caller. |
| `SaveData(true)` | Also returns the result. Retries with growing delays. |
| `GetData`, `SetData`, `Reconcile` | Refused once the session starts ending or its lease expires. Check for `nil`. |
| `SetData` | Refuses values a data store cannot hold, NaN, and `MetaData` paths, and writes a data store would change or lose, such as a number key on a dictionary. Use string keys for number-like ids: `tostring(level)`. See [What can be saved](data-operations.md#what-can-be-saved). A path through a non-table returns `nil` instead of throwing. |
| Leaving | SoulStore's own final save now runs after every other `PlayerRemoving` handler, so what they write is saved. See [When a player leaves](lifecycle-hooks.md#when-a-player-leaves). |
| `Reconcile` | Copies the tables it inserts, so players never share a template's table. Only fills string keys: in 1.x a saved `{ 9 }` with a template of `{ 1, 2, 3 }` became `{ 9, 2, 3 }`, and now it stays `{ 9 }`. If you add a new entry to a default array and every player should get it, add it in `SetOnLoad`. |
| `OnDataChanged` | The new value is now a copy, like the old value. In 1.x it was the live table, so a listener could change saved data through it, and anything it kept would change later. Code that keeps it should take the copy from each notification, as it fires for every `SetData` below the path, or read with `GetData`. |
| `SetOnLoad` | The hook works on a copy and must not yield. If it errors or yields, the load fails and the stored record is untouched. |
| `SetOnSave` | The hook must not yield. If it errors or yields, that copy is not written. |
| `getSoul` | Only returns an Active session. |
| `new` | Returns `nil` during shutdown, while the same Player instance's previous session is still ending, or for defaults that could not be saved. |
| Waiting for a lock | A lock that has not changed for 90 seconds is taken over, instead of waiting out the full 5 minutes. One already older than 5 minutes is watched for 45 seconds rather than taken at once, so an owner that outlived an outage can land its final save first. A healthy session keeps writing, so this does not affect it. |
| Saving from a hook | `SaveData` and `LoadData` called inside a hook return `false, "CalledFromHook"`. See [Lifecycle Hooks](lifecycle-hooks.md). |
| Saving odd tables | In 1.x a table with both `[1]` and string keys lost its string keys when saved, and at the top of a save that lost everything. Now nothing is lost: the number keys are saved as strings, with a warning. An array with gaps now always comes back whole. |

## Check these in your game

**Do not compare `SessionId` with `game.JobId`.** `MetaData.SessionId` is now a token for one session, not a server id, so that comparison is always false. Check the result of `SaveData` instead:

```lua
-- Before
return finished and meta.SaveId > saveIdBefore and meta.SessionId == game.JobId

-- After
local saved = soul:SaveData(false)
return saved
```

**Check the result of `LoadData`.** A load can now fail for good, so do not start gameplay without checking it:

```lua
local loaded, reason = soul:LoadData()
if not loaded then
    warn("Player data unavailable:", reason)
    return
end
```

**Make sure save hooks do not yield.** A yielding `SetOnSave` hook now fails every normal save. A final save writes the session without it.

**React when a session ends during play.** If a session loses its record or its lease expires, SoulStore stops accepting changes but does not kick the player. Connect to `SessionEndBindableEvent`, or the player keeps playing with progress that cannot be saved:

```lua
soul.SessionEndBindableEvent.Event:Connect(function(_state, reason)
    if player.Parent == Players and (reason == "OwnershipLost" or reason == "LeaseExpired") then
        player:Kick("Your data session ended. Please rejoin.")
    end
end)
```

**Update tests that load SoulStore directly.** The module now has child modules, which it requires with `script.Parent`, and methods no longer live on the module table. `SoulStore.Reconcile(soul, data)` is now `soul:Reconcile(data)`.

## Kept for existing code

`LoadState` and `SaveState` keep their old strings, so checks such as `soul.LoadState ~= "Loaded"` and `soul.SaveState == "Saving"` still work. `soul.Data` is still the live table, and extra `MetaData` fields such as a purchase marker still round-trip.
