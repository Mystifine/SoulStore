# Getting Started

## Installation
You may install SoulStore in one of two ways:

### Rojo
1. Git clone or download the repository onto your computer
2. Run `rojo build --o SoulStore.rbxlx`
3. Copy 'SoulStore' in ServerScriptService into your desired location

### Wally
1. Edit your `wally.toml` file to include the following:
```toml
[dependencies]
soulstore = "mystifine/soulstore@1.0.3"
```
2. Run `wally install`

## Importing SoulStore
In your scripts, require the module:
```lua
local SoulStore = require(path.to.SoulStore)
```

## Common Patterns
SoulStore is designed to be used in a common pattern. It is recommended to use the following pattern to ensure data integrity and prevent data loss.

### Data Schema
Create a table of default data to be used as a schema.
```lua
local PlayerDataSchema = {
	Stats = {
        Gold = 0,
		Gems = 0,
    },
	Units = {},
	Bag = {},
	Equipments = {},
}

return PlayerDataSchema
```

### Creating a PlayerDataService
Create a service that handles player data. This service will be responsible for creating and managing souls.
```lua
local ServerScriptService = game.ServerScriptService;
local Players = game.Players;
local ReplicatedStorage = game.ReplicatedStorage;

local SoulStore = require(ServerScriptService.Dependencies.SoulStore);

local PlayerDataSchema = require(ServerScriptService.Constants.PlayerDataSchema); -- A table of default data

local playerSouls : {[Player] : SoulStore.Soul} = {};
local PlayerDataService = {}

function PlayerDataService._initPlayerData(player : Player)
	local newSoul = SoulStore.new("PlayerData", player, PlayerDataSchema);
	newSoul:LoadData();
	newSoul:Reconcile(PlayerDataSchema);
		
    -- This is an example of how to create a container for stats and attach change listeners to update the data through instance value property change
	local statsContainer = Instance.new("Folder")
	statsContainer.Name = "Stats";
	statsContainer.Parent = player;

	local DATA_TYPE_TO_OBJECT = {
		["string"] = "StringValue",
		["number"] = "NumberValue",
		["boolean"] = "BoolValue"
	}
	local playerStats = newSoul:GetData({"Stats"});
	for statName, statValue in pairs(playerStats) do
		local statObject = Instance.new(DATA_TYPE_TO_OBJECT[typeof(statValue)]);
		statObject.Name = statName;
		statObject.Value = statValue;
		statObject.Parent = statsContainer;

		newSoul:OnDataChanged({"Stats", statName}, function(oldData: any?, newData: any?): nil 
			statObject.Value = newData;
		end)
	end
		
	local dataLoaded = Instance.new("BoolValue");
	dataLoaded.Value = true;
	dataLoaded.Name = "dataLoaded";
	dataLoaded.Parent = player;
	
	playerSouls[player] = newSoul;
end

function PlayerDataService._onPlayerRemoving(player : Player)
	local soul = playerSouls[player];
	if soul then
		soul:SaveData(true);
	end
	playerSouls[player] = nil;
end

function PlayerDataService.getSoul(player : Player)
	local dataLoaded = PlayerDataService.waitForDataLoaded(player);
	return playerSouls[player];
end

function PlayerDataService.main()
	Players.PlayerAdded:Connect(PlayerDataService._initPlayerData);
	local players = Players:GetPlayers();
	for i = 1, #players do
		task.spawn(PlayerDataService._initPlayerData, players[i]);
	end
	
	Players.PlayerRemoving:Connect(PlayerDataService._onPlayerRemoving);
end

return PlayerDataService

```

## Configuration

Adjust the `SOUL_STORE_SETTINGS` table at the top of the module file before deploying.

---

### `DEBUG_MODE`

| | |
|---|---|
| **Type** | `boolean` |
| **Default** | `true` |

Enables console logging for load/save events, session-lock warnings, and errors. Disable in production.

```lua
DEBUG_MODE = false
```

---

### `TRACE_BACK_MESSAGE`

| | |
|---|---|
| **Type** | `boolean` |
| **Default** | `false` |

When `true`, appends a full `debug.traceback()` string to every debug log. Useful during development to trace the origin of unexpected save/load calls.

---

### `MINIMUM_SAVE_INTERVAL`

| | |
|---|---|
| **Type** | `number` (seconds) |
| **Default** | `6` |

Minimum delay between retry attempts when a save operation fails. Prevents hammering the DataStore API on repeated errors.

---

### `MINIMUM_LOAD_INTERVAL`

| | |
|---|---|
| **Type** | `number` (seconds) |
| **Default** | `6` |

Minimum delay between retry attempts when a load fails or a key is session-locked by another server.

---

### `AUTO_SAVE_INTERVAL`

| | |
|---|---|
| **Type** | `number` (seconds) |
| **Default** | `30` |

How often SoulStore auto-saves all active souls in the background. The internal loop ticks every 10 seconds and saves any soul whose `LastAutoSave` has exceeded this value.

!!! tip
    Values between **30–120 seconds** are recommended. Lower values consume more DataStore budget; higher values increase potential data loss on a crash.

---

### `SESSION_LOCK_AUTO_RELEASE`

| | |
|---|---|
| **Type** | `number` (seconds) |
| **Default** | `300` (5 min) |

How long another server waits before forcibly claiming a session-locked key after the original server appears to have crashed.

!!! warning "Safe Tuning Rule"
    Always set `SESSION_LOCK_AUTO_RELEASE` to at least **3× your** `AUTO_SAVE_INTERVAL`. If the release window is shorter than the save interval, a slow auto-save could allow another server to steal the lock mid-session, causing a data conflict.