# Getting Started

## Installation
You may install SoulStore in one of two ways:

### Rojo
1. Git clone or download the repository onto your computer
2. Run `rojo build -o SoulStore.rbxlx`
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
Create a service that handles player data. This service will be responsible for creating, replicating and managing souls.
```lua
local ServerScriptService = game.ServerScriptService;
local Players = game.Players;
local ReplicatedStorage = game.ReplicatedStorage;

local SoulStore = require(ServerScriptService.Dependencies.SoulStore);

local PlayerDataSchema = require(ServerScriptService.Constants.PlayerDataSchema); -- A table of default data

local playerSouls : {[Player] : SoulStore.Soul} = {};
local PlayerDataService = {}

local dataChangedEvent = path.to.dataChangedEvent; -- This should be a remote event
local getPlayerDataFunction = path.to.getPlayerDataFunction;  -- This should be a remote function

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

function PlayerDataService.waitForDataLoaded(player : Player)
	local dataLoaded = player:WaitForChild("dataLoaded");
	return dataLoaded;
end

function PlayerDataService.getSoul(player : Player)
	local dataLoaded = PlayerDataService.waitForDataLoaded(player);
	return playerSouls[player];
end

function PlayerDataService.setData(player : Player, path : {[number] : string | number}, value : any)
	local soul = PlayerDataService.getSoul(player);
	if soul then
		soul:SetData(path, value);

		-- Replicate the change to the client
		dataChangedEvent:FireClient(player, path, value);
	end
end

function PlayerDataService.getData(player : Player, path : {[number]: string | number})
	local soul = PlayerDataService.getSoul(player);
	if soul then
		return soul:GetData(path);
	end
end

function PlayerDataService.main()
	Players.PlayerAdded:Connect(PlayerDataService._initPlayerData);
	local players = Players:GetPlayers();
	for i = 1, #players do
		task.spawn(PlayerDataService._initPlayerData, players[i]);
	end
	
	Players.PlayerRemoving:Connect(PlayerDataService._onPlayerRemoving);
	getPlayerDataFunction.OnServerInvoke = PlayerDataService.getData;
end

return PlayerDataService

```

Now you want to setup the client side to handle data replication and data management.
```lua
-- Client
local getPlayerDataFunction = path.to.getPlayerDataFunction
local dataChangedEvent = path.to.dataChangedEvent

local ClientPlayerDataService = {}

-- State
local playerData = nil;
local eventSignals = {};
local queuedChanges = {};

-- Helpers
local function pathToKey(path: {[number]: string | number}): string
	return table.concat(path, ".")
end

-- Traverses playerData down to a given depth
local function traversePath(path: {[number]: string | number}, depth: number): any?
	local data = playerData
	for i = 1, depth do
		if type(data) ~= "table" then
			warn("ClientPlayerDataService: Invalid path at index " .. i .. " ('" .. pathToKey(path) .. "')")
			return nil
		end
		data = data[path[i]]
	end
	return data
end

-- Private

function ClientPlayerDataService._onDataChanged(path: {[number]: string | number}, value: any)
	if playerData == nil then
		table.insert(queuedChanges, {path, value})
		return;
	end

	local parent = traversePath(path, #path - 1)
	if parent == nil then return end

	local lastIndex = path[#path]
	local oldData = parent[lastIndex]
	parent[lastIndex] = value

	local pathKey = pathToKey(path)
	local callbacks = eventSignals[pathKey]
	if not callbacks then return end

	for i = 1, #callbacks do
		task.spawn(callbacks[i], oldData, value)
	end
end

function ClientPlayerDataService.getData(path: {[number]: string | number}): any?
	return traversePath(path, #path)
end

function ClientPlayerDataService.onDataChanged(
	path: {[number]: string | number},
	callback: (oldData: any?, newData: any?) -> ()
)
	local pathKey = pathToKey(path)

	if not eventSignals[pathKey] then
		eventSignals[pathKey] = {}
	end
	table.insert(eventSignals[pathKey], callback)

	return {
		Disconnect = function()
			local callbacks = eventSignals[pathKey]
			if not callbacks then return end

			for i = 1, #callbacks do
				if callbacks[i] == callback then
					table.remove(callbacks, i)
					break
				end
			end

			if #eventSignals[pathKey] == 0 then
				eventSignals[pathKey] = nil
			end
		end
	}
end

function ClientPlayerDataService.main()
	dataChangedEvent.OnClientEvent:Connect(ClientPlayerDataService._onDataChanged);

	playerData = getPlayerDataFunction:InvokeServer({});
	for i = 1, #queuedChanges do
		task.spawn(ClientPlayerDataService._onDataChanged, queuedChanges[i][1], queuedChanges[i][2]);
	end
	table.clear(queuedChanges);
end

return ClientPlayerDataService

```
Make sure you call `ClientPlayerDataService.main()` and `PlayerDataService.main()`!

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