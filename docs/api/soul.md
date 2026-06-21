# Soul Methods

Instance methods available on a `Soul` object.

---

## `:LoadData()`

Loads player data from the DataStore and acquires a session lock.

**Signature**
```lua
soul:LoadData() -> nil
```

**Behaviour**

- Yields the calling thread until data loads or the player leaves.
- Retries indefinitely while the key is session-locked or a DataStore error occurs.
- Writes default data if no existing save is found.
- Fires the `SetOnLoad` callback before `LoadState` transitions to `"Loaded"`.
- Caches the soul internally once loading succeeds.

**State Guards**

| Precondition | Result |
|---|---|
| `LoadState == "Loaded"` | No-op |
| `LoadState == "Loading"` | No-op |
| Player not in game | No-op |

!!! warning
    `:LoadData()` yields. Wrap in `task.spawn` if you need non-blocking startup.

**Example**
```lua
game.Players.PlayerAdded:Connect(function(player)
    local soul = SoulStore.new("PlayerData", player, DEFAULT_DATA)
    soul:LoadData()

    if soul.LoadState == "Loaded" then
        print("Coins:", soul:GetData({ "Coins" }))
    end
end)
```

---

## `:SaveData(sessionEnding?)`

Saves the soul's current data to the DataStore.

**Signature**
```lua
soul:SaveData(sessionEnding: boolean?) -> nil
```

**Parameters**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `sessionEnding` | `boolean?` | `false` | When `true`, releases the session lock and cleans up the soul. |

**Behaviour**

- **Mid-session save**: increments `SaveId`, updates `LastUpdate`, keeps the lock.
- **Session-ending save**: sets `Locked = false` and `SessionId = ""`, fires `SessionEndBindableEvent`, and removes the soul from cache.
- If a session-ending save is triggered while a regular save is running, the regular save is interrupted.
- Retries on DataStore failure until success or the save state changes.

**State Guards**

| Precondition | Result |
|---|---|
| `LoadState ~= "Loaded"` | No-op |
| `SaveState == "SessionEnding"` | No-op |
| `SaveState == "Saving"` and not session-ending | No-op |

**Example**
```lua
soul:SaveData()        -- mid-session manual save (e.g. after a purchase)
soul:SaveData(true)    -- session-ending (called automatically on PlayerRemoving)
```

---

## `:GetData(path?)`

Retrieves a value at the given path from `soul.Data`.

**Signature**
```lua
soul:GetData(path: {any}?) -> any?
```

**Parameters**

| Parameter | Type | Description |
|---|---|---|
| `path` | `{any}?` | Array of keys to traverse. Pass `nil` to return the full data table. |

**Returns** The value at the path, or `nil` if any key is missing or data is not loaded.

**Example**
```lua
local all   = soul:GetData()
local coins = soul:GetData({ "Coins" })
local level = soul:GetData({ "Stats", "Level" })
local item  = soul:GetData({ "Inventory", 1 })
```

---

## `:SetData(path, value)`

Sets a value at the given path in `soul.Data` and fires any registered change listeners.

**Signature**
```lua
soul:SetData(path: {any}, value: any) -> any?
```

**Parameters**

| Parameter | Type | Description |
|---|---|---|
| `path` | `{any}` | One or more keys. Must not be empty. |
| `value` | `any` | The value to assign at the final key. |

**Returns** The value that was set, or `nil` on failure.

!!! warning "Intermediate Keys Must Exist"
    `:SetData()` traverses but does not create intermediate tables. Ensure all nested structures are pre-defined in `DEFAULT_DATA`.

**Example**
```lua
soul:SetData({ "Coins" }, 500)
soul:SetData({ "Stats", "Level" }, 10)
soul:SetData({ "Inventory" }, { "Sword", "Shield" })
```

---

## `:Reconcile(data)`

Merges an external table into `soul.Data`, filling in only keys that are currently `nil`.

**Signature**
```lua
soul:Reconcile(data: {}?) -> nil
```

**Behaviour**

- Recursive — handles nested tables.
- Never overwrites an existing value.
- Warns and returns early if data is not loaded or `data` is `nil`.

**Example**
```lua
local DEFAULTS = { Coins = 0, Level = 1, NewField = "hello" }

soul:SetOnLoad(function()
    soul:Reconcile(DEFAULTS) -- back-fills NewField on old saves
end)
```

---

## `:OnDataChanged(path, callback)`

Registers a listener that fires when a value at `path` changes via `:SetData()`.

**Signature**
```lua
soul:OnDataChanged(
    path     : {string | number},
    callback : (oldData: any?, newData: any?) -> nil
) -> { Disconnect: () -> nil }
```

**Parameters**

| Parameter | Type | Description |
|---|---|---|
| `path` | `{string | number}` | Path to watch. Also fires for `:SetData()` calls whose path passes through this path. |
| `callback` | `function` | Receives `oldData` and `newData`. Called via `task.spawn`. |

**Returns** A connection object with a `Disconnect()` method.

!!! note "Partial Path Matching"
    A listener on `{ "Stats" }` fires when `:SetData({ "Stats", "Level" }, 5)` is called. See the [Change Listeners guide](../guides/listeners.md) for details.

**Example**
```lua
local conn = soul:OnDataChanged({ "Coins" }, function(old, new)
    print(("Coins: %d → %d"):format(old, new))
end)
soul:SetData({ "Coins" }, 100) --> Coins: 0 → 100
conn:Disconnect()
```

---

## `:SetOnLoad(callback)`

Registers a callback called after data is read from the DataStore, before `LoadState` becomes `"Loaded"`.

**Signature**
```lua
soul:SetOnLoad(callback: (data: {}) -> nil) -> nil
```

The callback receives the raw data table **by reference**. Mutations affect what the soul stores in memory.

!!! note
    Must be called **before** `:LoadData()`.

**Example**
```lua
soul:SetOnLoad(function(data)
    data.Coins = math.clamp(data.Coins or 0, 0, 1_000_000)
end)
soul:LoadData()
```

---

## `:SetOnSave(callback)`

Registers a callback called before each DataStore write, receiving a **deep copy** of `soul.Data`.

**Signature**
```lua
soul:SetOnSave(callback: (data: {}) -> nil) -> nil
```

Mutations affect only the save snapshot — `soul.Data` is not changed.

**Example**
```lua
soul:SetOnSave(function(snapshot)
    snapshot.TempBoost = nil -- strip runtime-only field before saving
end)
```