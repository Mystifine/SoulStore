# SoulStore

A lightweight, production-ready Roblox player data module with session locking, automatic saving, and change listeners.

---

## Features

- **Session locking** — prevents cross-server data collisions with time-based auto-release
- **Automatic saving** — configurable interval-based auto-save with state-aware scheduling
- **Change listeners** — subscribe to nested data changes via path-based callbacks
- **Load/save hooks** — attach `OnLoad` and `OnSave` callbacks for data transformations
- **Reconciliation** — safely merge default data into existing player data without overwriting
- **Safe shutdown** — `BindToClose` handler ensures all souls are saved before the server closes

---

## Installation

Drop `SoulStore.lua` into `ServerScriptService` or any server-accessible `ModuleScript` location, then require it from your server scripts.

```lua
local SoulStore = require(game.ServerScriptService.SoulStore)
```

---

## Quick Start

```lua
local SoulStore = require(game.ServerScriptService.SoulStore)

local DEFAULT_DATA = {
    Coins = 0,
    Level = 1,
    Inventory = {},
}

game.Players.PlayerAdded:Connect(function(player)
    local soul = SoulStore.new("PlayerData", player, DEFAULT_DATA)

    soul:SetOnLoad(function(data)
        -- Runs after data is loaded, before the soul is marked ready.
        -- Use this to migrate or transform data on load.
        if not data.Settings then
            data.Settings = { MusicEnabled = true }
        end
    end)

    soul:LoadData()

    -- Wait for load before doing anything with the data
    -- (LoadData is synchronous — it blocks until loaded or the player leaves)

    soul:SetData({"Coins"}, 100)
    print(soul:GetData({"Coins"})) -- 100
end)
```

---

## API

### `SoulStore.new(datastoreId, player, defaultData) → Soul`

Creates a new Soul object. If a soul already exists in cache for this player and datastore, the cached instance is returned instead.

| Parameter | Type | Description |
|---|---|---|
| `datastoreId` | `string` | The DataStore name to use |
| `player` | `Player` | The player this soul belongs to |
| `defaultData` | `{}` | Default data table (must be a dictionary) |

---

### `soul:LoadData()`

Loads the player's data from the DataStore. Handles session lock detection, retrying until the lock expires or the player leaves. Blocks the calling thread until resolved.

- If the player leaves mid-load, the soul is cleaned up automatically.
- The `OnLoad` callback fires after data is assigned but before `LoadState` becomes `Loaded`.

---

### `soul:SaveData(sessionEnding: boolean?)`

Saves the player's data to the DataStore.

- Pass `true` for `sessionEnding` when the player is leaving — this unlocks the session and clears the soul from cache on success.
- Auto-saves and manual saves pass `false` (or omit the argument).
- The `OnSave` callback fires on each attempt, receiving a snapshot of the data.

---

### `soul:GetData(path: {any}?) → any?`

Retrieves a value from the soul's data by path.

```lua
-- Get the entire data table
local data = soul:GetData()

-- Get a nested value
local coins = soul:GetData({"Coins"})
local musicSetting = soul:GetData({"Settings", "MusicEnabled"})
```

Returns `nil` and warns if a key in the path doesn't exist.

---

### `soul:SetData(path: {any}, value: any) → any?`

Sets a value in the soul's data by path. Fires any registered `OnDataChanged` listeners for the affected path and its ancestors.

```lua
soul:SetData({"Coins"}, 500)
soul:SetData({"Settings", "MusicEnabled"}, false)
```

---

### `soul:OnDataChanged(path, callback) → { Disconnect: () -> nil }`

Listens for changes at the given path. The callback receives `(oldValue, newValue)`.

```lua
local connection = soul:OnDataChanged({"Coins"}, function(old, new)
    print(string.format("Coins changed: %d -> %d", old, new))
end)

-- Later, when you no longer need it:
connection:Disconnect()
```

Listeners fire for changes at the exact path and any descendant path. For example, a listener on `{"Settings"}` fires when `{"Settings", "MusicEnabled"}` changes.

---

### `soul:Reconcile(data: {})`

Merges `data` into the soul's existing data. Only fills in keys that are `nil` — existing values are never overwritten. Useful for adding new fields to returning players.

```lua
soul:Reconcile({
    NewFeatureFlag = false,  -- only added if not already present
    Coins = 999,             -- ignored, Coins already exists
})
```

---

### `soul:SetOnLoad(callback: (data: {}) -> nil)`

Attaches a callback that fires once after data is loaded from the DataStore. Receives the raw loaded data table directly — use this for migrations or one-time transforms.

```lua
soul:SetOnLoad(function(data)
    -- Rename an old key
    if data.Gold then
        data.Coins = data.Gold
        data.Gold = nil
    end
end)
```

The callback is wrapped in a `pcall` — errors are logged but do not interrupt loading.

---

### `soul:SetOnSave(callback: (data: {}) -> nil)`

Attaches a callback that fires before each save attempt. Receives a **snapshot** of the data (not the live table) — mutations here affect what gets saved, not `soul.Data` itself.

```lua
soul:SetOnSave(function(data)
    -- Strip a temporary runtime field before saving
    data.SessionStartTime = nil
end)
```

The callback is wrapped in a `pcall`. Because it runs inside the retry loop, it fires on every save attempt including retries.

---

### `SoulStore.getSoul(datastoreId, player) → Soul?`

Returns the cached soul for a player if one exists. Returns `nil` otherwise.

---

### `SoulStore.resetData(datastoreId, datastoreKey)`

Removes a single key from a DataStore. Intended for development and admin tooling only.

---

### `SoulStore.resetAllData(datastoreId)`

Removes **all keys** from a DataStore. Includes a 10-second warning delay. Use with extreme caution — this is irreversible.

---

## Configuration

Settings are defined at the top of the module in `SOUL_STORE_SETTINGS`:

| Setting | Default | Description |
|---|---|---|
| `DEBUG_MODE` | `true` | Enables console output for load/save events and errors |
| `TRACE_BACK_MESSAGE` | `false` | Appends a stack trace to all debug output |
| `AUTO_SAVE_INTERVAL` | `30` | Seconds between automatic saves (minimum 6, recommended 30+) |
| `MINIMUM_SAVE_INTERVAL` | `6` | Minimum seconds between save retry attempts |
| `MINIMUM_LOAD_INTERVAL` | `6` | Minimum seconds between load retry attempts |
| `SESSION_LOCK_AUTO_RELEASE` | `300` | Seconds before a session lock is considered stale and released |

---

## Session Locking

SoulStore attaches metadata to each player's DataStore entry to prevent two servers from writing the same player's data simultaneously.

When a player joins:
1. `LoadData` reads the DataStore and checks for a lock.
2. If unlocked (or the lock has expired), it claims ownership by writing `Locked = true` and the current `JobId`.
3. If locked by another server, it waits `MINIMUM_LOAD_INTERVAL` seconds and retries.

When a player leaves:
1. `SaveData(true)` writes the final data with `Locked = false`, releasing the lock.
2. Any other server can now load this player's data cleanly.

`SESSION_LOCK_AUTO_RELEASE` is the safety net for cases where a server crashes before releasing its lock. Set it higher than `AUTO_SAVE_INTERVAL` to ensure saves always happen within the lock window.

---

## Types

```lua
export type SoulMetaData = {
    Locked: boolean,
    SaveId: number,
    LastUpdate: number,
    SessionId: string,
}

export type Soul = {
    DatastoreId: string,
    Player: Player,
    Data: { MetaData: SoulMetaData },
    LoadState: string,
    SaveState: string,
    -- methods...
}
```

---

## Notes

- `LoadData` is **synchronous** — it yields the calling thread until data is loaded or the player leaves. Call it inside a `task.spawn` or a `PlayerAdded` connection to avoid blocking other code.
- `soul.Data` should not be mutated directly for tracked fields. Use `SetData` to ensure change listeners fire correctly.
- `MetaData` is a reserved key inside the data table. Do not use it in your `defaultData`.
- `resetData` and `resetAllData` are available on the live module. Consider guarding them with `RunService:IsStudio()` in your own code if you expose admin tooling.

---

*Created by Mystifine*