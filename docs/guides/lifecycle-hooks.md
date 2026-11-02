# Lifecycle Hooks

## SetOnLoad

Register before `LoadData`. The callback receives acquired data before the soul becomes Active. Mutate its argument directly: `GetData`, `SetData`, and `Reconcile` are gameplay methods and remain unavailable during initialization.

```lua
soul:SetOnLoad(function(data)
    if data.PremiumCurrency == nil then
        data.PremiumCurrency = 0
    end
    data.Coins = math.clamp(data.Coins or 0, 0, 1_000_000)
    if data.OldXP ~= nil then
        data.Stats = data.Stats or {}
        data.Stats.XP = data.OldXP
        data.OldXP = nil
    end
end)

local loaded, reason = soul:LoadData()
if not loaded then
    warn("Data initialization failed:", reason)
    return
end
```

A failed hook prevents Active gameplay. SoulStore releases the original acquired record rather than saving partial migration changes.

## SetOnSave

Receives a copy of the save payload. Its mutations affect that attempt only; live data is unchanged.

```lua
soul:SetOnSave(function(snapshot)
    snapshot.ActiveBoostExpiry = nil
    snapshot.TempEventData = nil
end)
```

A failed hook does not write its partially modified snapshot. A normal save reports the failure and the next autosave runs the hook again. A final save writes the session without the hook, so the rest of the player's progress is not lost. Transformations must be safe to run repeatedly. Keep purchases, rewards, network requests, and other external side effects outside hooks.

Both hooks must complete without yielding and must leave `MetaData` to SoulStore. Do not call `task.wait`, asynchronous APIs, or other yielding operations from them.

Saves and loads wait on the data store, so they cannot start from inside a hook, for any soul. `SaveData` and `LoadData` return `false, "CalledFromHook"` and warn, and the save that ran the hook carries on as usual. To end a session because of something a save hook found, do it after the hook with `task.defer`. One exception: `SaveData(true)` inside `SetOnLoad` cancels the load, which needs no waiting.

## Execution order

```text
Acquire and load record
  -> SetOnLoad(data)
  -> Active
  -> gameplay
  -> copy save payload
  -> SetOnSave(snapshot)
  -> ownership-checked write

Ending
  -> capture final payload
  -> SetOnSave(snapshot)
  -> wait for existing writer
  -> final write and unlock together
  -> terminal event and cleanup
```

The final hook runs as the session starts ending, before anything yields, so nothing that runs later can change the final save. During Ending, gameplay methods reject access. Previously returned tables remain live references for compatibility, but changing them after Ending begins does not alter the captured final payload.

## When a player leaves

SoulStore starts the final save once every `PlayerRemoving` handler has run, in whatever order Roblox ran them. On Roblox the newest connection runs first, but nothing guarantees that, so do not rely on it. That leaves two rules for your own leave handlers:

- **Writing is safe.** `SetData` and changes to the live data still work inside a leave handler, and they make the final save.
- **Do not clear what a save hook reads.** The hook runs after your handler, so it would find nothing. Write it to the save in the handler instead, or clear it later with `task.delay` or when `SessionEndBindableEvent` fires.

If your own code calls `SaveData(true)` inside a leave handler, the final save starts right there, and handlers Roblox runs after it can no longer write.
