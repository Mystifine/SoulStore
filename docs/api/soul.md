# Soul Methods

A soul belongs to one exact Player instance and DataStore. Gameplay access requires an Active session. Use `getSoul` for readiness checks. A session starts ending as soon as its player leaves. An outage does not end a session: it stays Active, and its next save lands once the store is back.

## `:LoadData()`

```lua
soul:LoadData() -> (boolean, string?)
```

Yields until ownership is acquired and `SetOnLoad` completes, or loading stops. Returns `true` only when the soul is Active; otherwise returns `false` and a reason. Concurrent callers wait for the same load rather than issuing duplicate acquisitions.

Foreign locks and transient DataStore errors retry while the player remains present. Defaults are written only for a missing record. Malformed existing data, including a record stored as an array, is never replaced with defaults: the load stops with `CorruptData` and the record is left as it is. Leaving or shutdown cancels pending work. A confirmed acquisition after cancellation is released without starting gameplay. If the response is uncertain, bounded recovery tries to release only this token; an unresolved lock relies on expiry.

```lua
local soul = SoulStore.new("PlayerData", nil, player, DEFAULT_DATA)
if not soul then return end
local loaded, reason = soul:LoadData()
if not loaded then
    warn("Player data unavailable:", reason)
    return
end
print("Coins:", soul:GetData({ "Coins" }))
```

## `:SaveData(sessionEnding?)`

```lua
soul:SaveData(sessionEnding: boolean?) -> (boolean, string?)
```

With `false` or no argument, saves an Active soul, increments `SaveId`, refreshes `LastUpdate`, and retains ownership. It makes one attempt, waiting first behind any save already running. Returns `true` for a confirmed write; rejected or unavailable operations return `false` and a reason. A failed attempt is not retried, because the next autosave carries newer data anyway.

With `true`, immediately transitions to Ending, captures the final snapshot, and stops gameplay access. The final writer waits behind an in-flight save, then writes data and unlocks in the same `UpdateAsync`. It retries until the write lands, another session owns the record, or an error occurs that retrying cannot fix, in which case the lock is released without the final data. Repeated end requests coalesce; an end request received while finalization is running may return `false, "Ending"`. Observe `SessionEndBindableEvent` or terminal state for completion.

Foreign or missing ownership is never overwritten or reported as a successful save. Ending a Pulling soul cancels loading instead of saving its defaults. Called from inside a load or save hook, it returns `false, "CalledFromHook"`. See [Lifecycle Hooks](../guides/lifecycle-hooks.md).

```lua
local saved, reason = soul:SaveData()
if not saved then warn("Save not confirmed:", reason) end
-- Normally automatic on PlayerRemoving and shutdown:
soul:SaveData(true)
```

## `:GetData(path?)`

```lua
soul:GetData(path: {string | number}?) -> any?
```

Returns a nested value, or the full data table when the path is omitted. Returns `nil` outside Active, for a missing key, or when traversal encounters a non-table.

```lua
local coins = soul:GetData({ "Coins" })
local level = soul:GetData({ "Stats", "Level" })
local item = soul:GetData({ "Inventory", 1 })
```

Table results remain live references for compatibility. Direct mutation bypasses state guards and listeners, so prefer `SetData`. The final snapshot is captured when Ending starts; later changes through retained references do not affect it.

## `:SetData(path, value)`

```lua
soul:SetData(path: {string | number}, value: any) -> any?
```

Sets a value and notifies path listeners. Returns the assigned value, or `nil` on rejection. Requires an Active soul, a nonempty path, and existing intermediate tables. `MetaData` is reserved for SoulStore.

Values a DataStore cannot hold are rejected: functions, threads, Instances and other Roblox types, strings that are not valid UTF-8, table keys that are not strings or numbers, and tables that contain themselves. NaN is rejected as well, because it is always a bug and would replace a good value. If one of these reaches the data through a direct table write, it is left out of each save with a warning instead of failing the save, except NaN, which saves as it is, also with a warning.

So are writes a DataStore would change or lose: a number key on a table with string keys, including the top of the save, a string key on an array, a number key that is not a whole number from 1, any number key but 1 on a table that is not an array yet, and a value with any of these inside it. See [What can be saved](../guides/data-operations.md#what-can-be-saved). Check the return value when granting something of value.

```lua
soul:SetData({ "Coins" }, 500)
soul:SetData({ "Stats", "Level" }, 10)
soul:SetData({ "Inventory" }, { "Sword", "Shield" })
```

## `:Reconcile(data)`

```lua
soul:Reconcile(data: {}?) -> nil
```

Recursively fills missing string keys on an Active soul without replacing existing values. An array the save already has is left as it is, and a missing one is copied whole. Newly inserted tables are copied; reserved metadata is excluded.

```lua
if soul:LoadData() then
    soul:Reconcile(DEFAULT_DATA)
end
```

Inside `SetOnLoad`, work directly on the callback argument; gameplay methods are unavailable before Active.

## `:OnDataChanged(path, callback)`

```lua
soul:OnDataChanged(
    path: {string | number}?,
    callback: (oldData: any?, newData: any?) -> nil
) -> { Disconnect: () -> nil }
```

Registers a listener for `SetData` changes. A listener on `{ "Stats" }` also fires for `{ "Stats", "Level" }`. It receives copies of the old and new values. Pass `nil` to observe the full data table. Call `Disconnect()` to unsubscribe. Listeners are cleaned up when the soul terminates. See [Change Listeners](../guides/listeners.md).

## `:SetOnLoad(callback)`

```lua
soul:SetOnLoad(callback: (data: {}) -> nil) -> nil
```

Register before loading. Receives acquired data for validation or migration before Active. Mutate the argument directly. Hooks must not yield or modify `MetaData`.

A failed hook prevents gameplay. SoulStore releases ownership using the original acquired record, so partial migration changes are not saved.

```lua
soul:SetOnLoad(function(data)
    data.Coins = math.clamp(data.Coins or 0, 0, 1_000_000)
end)
local loaded, reason = soul:LoadData()
```

## `:SetOnSave(callback)`

```lua
soul:SetOnSave(callback: (snapshot: {}) -> nil) -> nil
```

Receives a copy of the save payload. Changes affect only that attempt, not live data. Hooks must not yield, modify `MetaData`, or perform non-idempotent side effects: they may run again on retries. Failed hooks do not commit their partial snapshots.

```lua
soul:SetOnSave(function(snapshot)
    snapshot.TempBoost = nil
end)
```

## Session completion

`SessionEndBindableEvent.Event` fires once with `(state, reason)` for terminal outcomes, including cancellation and ownership loss. The event and listeners are then destroyed. Connect before starting work; inspect `SessionState` and `EndReason` after completion instead of waiting for an event that already fired.

```lua
soul.SessionEndBindableEvent.Event:Connect(function(state, reason)
    print("Data session settled:", state, reason)
end)
```

Terminal state alone does not prove that a final save succeeded.

If another session takes the record, this session's next write is refused and it ends with `EndReason == "OwnershipLost"`. SoulStore does not kick the player automatically; the owning service can react to the completion event.
