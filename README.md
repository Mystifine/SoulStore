
# SoulStore 💾

[![Lua](https://img.shields.io/badge/language-Lua-2C2C2C)](https://www.lua.org/)  
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)  

A **lightweight Roblox data management module** for handling player data efficiently. `SoulStore` provides session locking, automatic saving, data reconciliation, and robust error handling to keep player data safe and consistent.  

---

## Features

- **Session Locking** – Prevents concurrent access to player data to avoid conflicts.  
- **Automatic Data Saving** – Configurable auto-save intervals keep data safe during gameplay.  
- **Manual Save & Load** – Explicitly load or save player data when needed.  
- **Data Reconciliation** – Merge external updates into existing player data.  
- **Nested Data Access** – Get or set nested properties safely with path arrays.  
- **Reset Data** – Reset individual or all datastore entries.  
- **Debug & Traceback Support** – Optional verbose logging for development.  

---

## Installation

Place `SoulStore.lua` in your Roblox project and require it where needed:

```lua
local SoulStore = require(game.ReplicatedStorage.Services.SoulStore)
````

---

## Usage Example

### Create a new player profile

```lua
local defaultData = {
    Coins = 0,
    Level = 1,
    Inventory = {}
}

local soul = SoulStore.new("PlayerDataStore", player, defaultData)
soul:LoadData()
```

### Access and modify data

```lua
-- Get a value
local coins = soul:GetData({"Coins"})

-- Set a value
soul:SetData({"Coins"}, coins + 10)

-- Listen for changes
local listener = soul:OnDataChanged({"Coins"}, function(oldValue, newValue)
    print("Coins changed:", oldValue, "->", newValue)
end)
```

### Save data manually

```lua
soul:SaveData(false) -- Normal save
soul:SaveData(true)  -- Session-ending save
```

### Reset all or specific data

```lua
-- Reset a single player
SoulStore.resetData("PlayerDataStore", tostring(player.UserId))

-- Reset entire datastore (use with caution)
SoulStore.resetAllData("PlayerDataStore")
```

---

## Configuration

Located at the top of the module:

```lua
SOUL_STORE_SETTINGS = {
    DEBUG_MODE = true,                -- Enable debug messages
    TRACE_BACK_MESSAGE = false,       -- Append stack trace to messages
    MINIMUM_SAVE_INTERVAL = 6,        -- Wait time between retries
    MINIMUM_LOAD_INTERVAL = 6,        -- Wait time between retries
    AUTO_SAVE_INTERVAL = 30,          -- Time between automatic saves
    SESSION_LOCK_AUTO_RELEASE = 60*5  -- Time before a lock auto-releases
}
```

Adjust `AUTO_SAVE_INTERVAL` and `SESSION_LOCK_AUTO_RELEASE` depending on gameplay priorities and data safety requirements.

---

## API

### `SoulStore.new(datastoreId: string, player: Player, defaultData: table) -> Soul`

Creates a new player soul object.

### `Soul:LoadData()`

Loads player data from the datastore.

### `Soul:SaveData(sessionEnding: boolean)`

Saves player data to the datastore. Set `sessionEnding` to `true` when the player leaves.

### `Soul:GetData(path: table) -> any`

Retrieve nested data from the soul.

### `Soul:SetData(path: table, value: any)`

Set nested data and notify listeners.

### `Soul:OnDataChanged(path: table, callback: function) -> {Disconnect: function}`

Listen for changes to specific data paths.

### `Soul:Reconcile(data: table)`

Merge external data into the soul’s data safely.

### `SoulStore.resetData(datastoreId: string, datastoreKey: string)`

Delete a single player profile from a datastore.

### `SoulStore.resetAllData(datastoreId: string)`

Delete all entries in a datastore. **Use with caution.**

---

## Auto Save & Server Handling

* Automatically saves all loaded souls every `AUTO_SAVE_INTERVAL` seconds.
* Saves player data when they leave the game.
* Saves all active data before the server shuts down.

---

## License

MIT License. See [LICENSE](LICENSE) for details.

