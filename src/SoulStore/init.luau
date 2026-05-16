--[[
	Created by: Mystifine#4924
	Last Updated: 2025-12-06
	
	Lightweight module used to handle PlayerData
	
	Features:
	Session Locking
	Automatic Data Saving
]]

local Players = game.Players;
local DataStoreService = game:GetService("DataStoreService");
local RunService = game:GetService('RunService')

local SOUL_STORE_SETTINGS = {
	DEBUG_MODE = true;
	TRACE_BACK_MESSAGE = false;

	MINIMUM_SAVE_INTERVAL = 6;
	MINIMUM_LOAD_INTERVAL = 6;

	--[[
		Property: AUTO_SAVE_INTERVAL
		Description: Minimum is 6, however I wouldn't recommend it. I would suggest 30+
	]]
	AUTO_SAVE_INTERVAL = 30; 

	--[[
		Property SESSION_LOCK_AUTO_RELEASE
		Description: To avoid data save/load collison, the higher the value the better. 
		Note that this will effect player gameplay experience the longer it is.
		However you need to weigh the value of having their data safe versus them playing the game.
		If you believe their data is more valuable then you should increase the number, otherwise keep
		it at a respective value to AUTO_SAVE_INTERVAL. 
	]]
	SESSION_LOCK_AUTO_RELEASE = 60 * 5; -- 5 minutes.
}

export type Soul = {
	DatastoreId : string,
	Player : Player,
	
	Data : any?,
	LastAutoSave : number,
	_listeners : {},
	
	LoadState : string,
	SaveState : string,
	SessionEndBindableEvent : BindableEvent,
	
	OnDataChanged : (self : Soul, path : {any}?, callback : (oldData : any?, newData : any?) -> nil) -> {Disconnect : () -> nil},
	SetData : (self : Soul, path : {any}?,value : any) -> nil,
	GetData : (self : Soul, path : {any}?) -> nil,
	Reconcile : (self : Soul, data : {}?) -> nil,
	SaveData : (self : Soul, sessionEndSaving : boolean?) -> nil,
	LoadData : (self : Soul) -> nil,
}

export type SoulStore = {
	ClassName : string,
	
	resetData : (datastoreId : string, datastoreKey : string) -> nil,
	resetAllData : (datastoreId : string) -> nil,
	getMetaData : () -> {
		Locked : boolean,
		SaveId : number,
		LastUpdate : number,
		SessionId : string,
	},
	deepCopy : (data : any?) -> any,
	output : (outputFunction : (any) -> any) -> nil,
	playerExists : (Player) -> boolean?,
	getSoul : (datastoreId : string, player : Player) -> Soul?,
	new : (datastoreId : string, player : Player, defaultData : any?) -> Soul
}

local SAVE_STATES = {
	Saving = "Saving",
	SessionEnding = "SessionEnding",
	Idle = "Idle",
}

local LOAD_STATES = {
	Idle = "Idle",
	Loading = "Loading",
	Loaded = "Loaded",
}

local loadedSouls : {[string] : {[number] : Soul}} = {};

local SoulStore = {}
SoulStore.ClassName = "Soul";
SoulStore.__index = SoulStore;

--[[
	Listens to data change provided a path and a callback function.
	
	@param path - The path to the data you want to listen to. If you want to listen to the entire data structure, pass nil.
	@param callback - The function to call when the data changes.
	@return A connection object that can be disconnected.
]]
function SoulStore:OnDataChanged(path : {[number] : string | number}, callback : (oldData : any?, newData : any?) -> nil)
	local soul : Soul = self;
	
	local key = table.concat(path, ".");
	soul._listeners[key] = soul._listeners[key] or {};
	
	local listeners = soul._listeners[key];
	table.insert(listeners, callback);
	
	local disconnected = false;
	return {
		Disconnect = function()
			if disconnected then return; end
			disconnected = true;
			
			for i, cb in ipairs(listeners) do
				if cb == callback then
					table.remove(listeners, i);
					break;
				end;
			end
			
		end,
	}
end

--[[
	Loads player data from the datastore
]]
function SoulStore:LoadData()
	local soul : Soul = self;
	-- Can not load data if the soul is already loaded
	if soul.LoadState == LOAD_STATES.Loaded then return end;
	-- Can not load data if already loading
	if soul.LoadState == LOAD_STATES.Loading then return end;
	-- Can not load data if the player does not exist
	if not SoulStore.playerExists(soul.Player) then return end;
	
	local datastore = DataStoreService:GetDataStore(soul.DatastoreId);
	local playerName = soul.Player.Name;
	local datastoreKey = soul.Player.UserId;
	local loadSuccess, loadResult;
	local sessionLocked = false;
	
	-- Set the state to loading
	soul.LoadState = LOAD_STATES.Loading;
	
	-- Iterate while the player is in the game and data failed to load or the data is locked
	while SoulStore.playerExists(soul.Player) and (not loadSuccess or sessionLocked) do
		loadSuccess, loadResult = pcall(function()
			return datastore:UpdateAsync(datastoreKey, function(readData : any?)
				-- Scenario 1: No data
				if not readData then
					-- attach metaData to data and return;
					soul.Data.MetaData = SoulStore.getMetaData(); 
					sessionLocked = false;
					return soul.Data;
				end
				
				-- Scenario 2: Data exists but no metaData
				if not readData.MetaData then
					-- attach metaData to data and return;
					readData.MetaData = SoulStore.getMetaData();
					sessionLocked = false;
					return readData;
				end
				
				-- Scenario 3: Data exists and metaData exists
				if not readData.MetaData.Locked or os.time() - readData.MetaData.LastUpdate >= SOUL_STORE_SETTINGS.SESSION_LOCK_AUTO_RELEASE then
					readData.MetaData.Locked = true;
					readData.MetaData.SessionId = game.JobId;
					readData.MetaData.LastUpdate = os.time();
					sessionLocked = false;
					return readData;
				end
				
				sessionLocked = true;
				return readData; -- No modifications
			end);
		end)
		
		if not loadSuccess then
			SoulStore.output(warn, string.format("SoulStore:LoadData => Failed to load data for '%s' (%d). Error Reason: %s", playerName, datastoreKey, tostring(loadResult)));
		end
		
		if sessionLocked then
			local timeUntilLockExpire = SOUL_STORE_SETTINGS.SESSION_LOCK_AUTO_RELEASE - (os.time() - loadResult.MetaData.LastUpdate);
			SoulStore.output(warn, string.format("SoulStore:LoadData => Data for '%s' (%d) is locked. Time Until Expiry: %d(s)", playerName, datastoreKey, timeUntilLockExpire));
		end
		
		if not loadSuccess or sessionLocked then
			task.wait(SOUL_STORE_SETTINGS.MINIMUM_LOAD_INTERVAL);
		end
	end
	
	-- Souls are cached after they are loaded
	if not loadSuccess or sessionLocked then
		-- If the player leaves the game, we don't want to keep the soul object in memory
		soul.LoadState = LOAD_STATES.Idle; 
		return;		
	end
	
	-- Create cache for datastoreId;
	if not loadedSouls[soul.DatastoreId] then
		loadedSouls[soul.DatastoreId] = {};
	end
	-- Cache the soul
	loadedSouls[soul.DatastoreId][datastoreKey] = soul;
	
	-- If we get to this point the soul has been loaded
	soul.Data = loadResult;
	soul.LoadState = LOAD_STATES.Loaded;
	SoulStore.output(print, string.format("SoulStore:LoadData => Data for '%s' (%d) has been loaded successfully! (SaveId: %d)", playerName, datastoreKey, soul.Data.MetaData.SaveId));

end

--[[
	Saves player data to the datastore.
	@param sessionEnding: boolean - If true indicates the object will be automatically cleaned up
	
	@returns nil
]]
function SoulStore:SaveData(sessionEnding : boolean)
	local soul : Soul = self;
	
	-- Can not save data if data is not loaded
	if soul.LoadState ~= LOAD_STATES.Loaded then return end;
	-- Can not overwrite session ending state
	if soul.SaveState == SAVE_STATES.SessionEnding then return end;
	-- Already saving, can not save unless it's sessionEnding (overwrite)
	if soul.SaveState == SAVE_STATES.Saving and not sessionEnding then return end;	
	
	local datastore = DataStoreService:GetDataStore(soul.DatastoreId);
	local datastoreKey = soul.Player.UserId;
	local playerName = soul.Player.Name;
	
	if sessionEnding then
		soul.SaveState = SAVE_STATES.SessionEnding;
	else
		soul.SaveState = SAVE_STATES.Saving;
	end
	
	local currentSaveState = soul.SaveState; -- Used to check incase we :Save() and then session end save immediately
	local saveSuccess, saveResult;
	while not saveSuccess and currentSaveState == soul.SaveState do
		saveSuccess, saveResult = pcall(function()
			return datastore:UpdateAsync(datastoreKey, function(oldData)				
				-- If the data exists but is NOT owned by us, we cannot modify it anymore
				if oldData and oldData.MetaData.SessionId ~= game.JobId then
					return oldData -- Return existing data unmodified
				end

				local dataToSave = soul.Data;
				dataToSave.MetaData.SaveId += 1;
				dataToSave.MetaData.LastUpdate = os.time();

				if sessionEnding then
					dataToSave.MetaData.Locked = false;
					dataToSave.MetaData.SessionId = "";
				else
					dataToSave.MetaData.Locked = true;
					dataToSave.MetaData.SessionId = game.JobId;
				end
				
				return dataToSave;
			end)	
		end)
		
		if not saveSuccess then
			SoulStore.output(warn, string.format("SoulStore:SaveData => Failed to save data for '%s' (%d) (SaveId: %d)! Error Reason: %s", playerName, datastoreKey, soul.Data.MetaData.SaveId ,tostring(saveResult)));
		end
		
		if currentSaveState ~= soul.SaveState then
			-- We have switched to a session end save
			SoulStore.output(warn, string.format("SoulStore:SaveData => Failed to save data for '%s' (%d) (SaveId: %d)! Save state interruption detected.", playerName, datastoreKey, soul.Data.MetaData.SaveId));
		end		
		
		if not saveSuccess and currentSaveState == soul.SaveState then
			task.wait(SOUL_STORE_SETTINGS.MINIMUM_SAVE_INTERVAL);
		end
	end
	
	if saveSuccess then
		
		if sessionEnding then
			soul.SessionEndBindableEvent:Fire();
			soul.SessionEndBindableEvent:Destroy(); -- Cleanup
			
			-- Clear cache
			if loadedSouls[soul.DatastoreId] and loadedSouls[soul.DatastoreId][datastoreKey] then
				loadedSouls[soul.DatastoreId][datastoreKey] = nil;
				if loadedSouls[soul.DatastoreId] and next(loadedSouls[soul.DatastoreId]) == nil then
					loadedSouls[soul.DatastoreId] = nil;
				end
			end
			SoulStore.output(print, string.format("SoulStore:SaveData => Data for '%s' (%d) has been ended their session successfully! (SaveId: %d)", playerName, datastoreKey, saveResult.MetaData.SaveId));
		else
			soul.SaveState = SAVE_STATES.Idle; -- Allow saving again
			SoulStore.output(print, string.format("SoulStore:SaveData => Data for '%s' (%d) has been saved successfully! (SaveId: %d)", playerName, datastoreKey, saveResult.MetaData.SaveId));
		end
	end
end

--[[ 
	Merges external data into the soul's data
	@param data : {}? - External data to reconcile
]]
function SoulStore:Reconcile(data : {}?)
	local soul : Soul = self

	if soul.LoadState ~= LOAD_STATES.Loaded then
		SoulStore.output(warn, "SoulStore:Reconcile => Cannot reconcile. Data not loaded for player " .. soul.Player.Name)
		return
	end

	if not data then
		SoulStore.output(warn, "SoulStore:Reconcile => No data provided to reconcile for player " .. soul.Player.Name)
		return
	end

	-- Internal recursive merge function
	local function merge(target, source)
		for key, value in pairs(source) do
			if typeof(value) == "table" and typeof(target[key]) == "table" then
				merge(target[key], value)
			else
				-- Only overwrite if target[key] is nil
				if target[key] == nil then
					target[key] = value
				end
			end
		end
	end

	merge(soul.Data, data)
	SoulStore.output(print, "SoulStore:Reconcile => Data reconciled for player " .. soul.Player.Name)
end

--[[ 
	Retrieves nested data from a Soul
	@param path : {any}? - Array of keys to traverse
	@return any? - The value at the path or nil if not found
]]
function SoulStore:GetData(path : {any}?) : any?
	local soul : Soul = self

	-- Ensure data is loaded
	if soul.LoadState ~= LOAD_STATES.Loaded then
		SoulStore.output(warn, "SoulStore:GetData => Data not loaded for player " .. soul.Player.Name .. ". Did you forget to call LoadData?")
		return nil
	end

	local data = soul.Data
	if not path then return data end

	for i = 1, #path do
		local key = path[i]
		if data[key] == nil then
			SoulStore.output(warn, string.format(
				"SoulStore:GetData => Failed to retrieve data for player %s. '%s' is not a valid property.", 
				soul.Player.Name, key
				))
			return nil
		end
		data = data[key]
	end

	return data
end

--[[
	Sets nested data on a Soul
	@param path : {any} - Array of keys to traverse
	@param value : any - Value to set
	@return any? - The value set, or nil if failed
]]
function SoulStore:SetData(path : {any}, value : any) : any?
	local soul : Soul = self

	-- Ensure data is loaded
	if soul.LoadState ~= LOAD_STATES.Loaded then
		SoulStore.output(warn, "SoulStore:SetData => Data not loaded for player " .. soul.Player.Name)
		return nil
	end

	if #path == 0 then
		SoulStore.output(warn, "SoulStore:SetData => Path must contain at least one key for player " .. soul.Player.Name)
		return nil
	end

	local data = soul.Data
	local parent = nil
	local key = nil

	-- Traverse to the parent of the target
	for pathIndex = 1, #path do
		key = path[pathIndex]
		parent = data

		if pathIndex == #path then
			-- Last key, set the value
			local oldData = SoulStore.deepCopy(parent[key])
			parent[key] = value

			-- Fire listeners
			local fullPath = ""

			for k = 1, #path do
				fullPath = (k == 1) and tostring(path[k]) or (fullPath .. "." .. tostring(path[k]))
				local listeners = soul._listeners[fullPath]
				if listeners then
					for _, fn in ipairs(listeners) do
						task.spawn(fn, oldData, value)
					end
				end
			end

			return value
		else
			data = data[key]
			if data == nil then
				SoulStore.output(warn, string.format(
					"SoulStore:SetData => Failed to traverse data for player %s. '%s' is not a valid property.", 
					soul.Player.Name, key
					))
				return nil;
			end
		end
	end
	return nil;
end

--[[
	Gets new meta data
	
	@return MetaData - The meta data
]]
function SoulStore.getMetaData()
	return {
		Locked = true,
		SaveId = 0,
		LastUpdate = os.time(),
		SessionId = game.JobId
	}
end

--[[
	Deep copies data
	
	@param data : any? - The data to copy
	
	@return any? - The copied data
]]
function SoulStore.deepCopy(data : any?)
	-- Deep copy the data
	if typeof(data) ~= "table" then
		return data;
	end
	
	local copiedData = {};
	for i, v in pairs(data) do 
		copiedData[i] = SoulStore.deepCopy(v);
	end
	
	return copiedData;
end

--[[ 
	Outputs a message to the console with optional debug and traceback support
	
	@param outputFunction : (any) -> any - The function to output the message (e.g., print, warn)
	@param ... : any - The arguments to pass to the output function
]]
function SoulStore.output(outputFunction : (any) -> any, ...)
	if not SOUL_STORE_SETTINGS.DEBUG_MODE then return end

	local args = {...}
	local message = table.concat(args, " ")

	if SOUL_STORE_SETTINGS.TRACE_BACK_MESSAGE then
		-- Append a simple stack trace
		message ..= "\nTraceback:" .. debug.traceback()
	end

	outputFunction(message)
end

--[[
	Checks if a player exists
	
	@param player : Player - The player to check
	
	@return PlayerExists - Returns true if the player exists, false otherwise
]]
function SoulStore.playerExists(player : Player?)
	return player and player:IsA("Player") and player.Parent == Players;
end

--[[
	Retrieves a soul object if cached
	
	@param datastoreId : string - The datastore id for the soul
	@param player : Player - The player object for the soul
	
	@return Soul - Returns the soul object if cached, nil otherwise
]]
function SoulStore.getSoul(datastoreId : string, player : Player)
	-- If soul already exists for this player then use the existing soul (from player rejoins)
	if loadedSouls[datastoreId] and loadedSouls[datastoreId][player.UserId] then
		return loadedSouls[datastoreId][player.UserId];
	end
	return nil;
end

--[[
	Creates a soul object
	
	@param datastoreId : string - The datastore id for the soul
	@param player : Player - The player object for the soul
	@param defaultData : any? - The default data for the soul
	
	@return Soul - The soul object
	
]]
function SoulStore.new(datastoreId : string, player : Player, defaultData : {})
	
	if typeof(defaultData) ~= "table" then
		SoulStore.output(warn, "SoulStore.new => defaultData must be a table/dictionary");
		return;
	end
	
	if not SoulStore.playerExists(player) then
		local playerName, playerUserId = player and player.Name or "nil", player and player.UserId or 0;
		SoulStore.output(warn, string.format("SoulStore.new => Failed to create a soul for '%s' (%d). Player no longer exists in the game.", playerName, playerUserId));
		return;
	end
	
	-- If soul already exists for this player then use the existing soul (from player rejoins)
	local loadedSoul = SoulStore.getSoul(datastoreId, player);
	if loadedSoul then
		return loadedSoul;
	end
	
	local soul = setmetatable({}, SoulStore);
	soul.DatastoreId = datastoreId;
	soul.Player = player;
	soul.Data = SoulStore.deepCopy(defaultData);
	soul.LastAutoSave = os.time();
	soul._listeners = {};
	
	soul.LoadState = LOAD_STATES.Idle;
	soul.SaveState = SAVE_STATES.Idle;
	soul.SessionEndBindableEvent = Instance.new("BindableEvent");
	soul.SessionEndBindableEvent.Name = player.UserId;
	soul.SessionEndBindableEvent.Parent = script;
	
	return soul;
end

--[[
    Deletes ALL keys in a SoulStore datastore.
    Use with extreme caution.
    
    @param datastoreId : string - The datastore id to reset.
]]
function SoulStore.resetAllData(datastoreId : string)
	local datastore = DataStoreService:GetDataStore(datastoreId)

	local warningText = string.format([[
\n===========================================================
SoulStore.resetAllData => WARNING
You are about to WIPE ALL DATA in datastore '%s'.
This operation may take a long time depending on key count.

❗ DO NOT close Roblox Studio
❗ DO NOT shutdown your computer
❗ NO active player sessions should exist

Process begins in 10 seconds...
===========================================================
]], datastoreId)

	warn(warningText)
	task.wait(10)

	-- List Keys
	local success, listResult = pcall(function()
		return datastore:ListKeysAsync(nil, 100, nil, true)
	end)

	if not success then
		warn(string.format(
			"SoulStore.resetAllData => FAILED to list keys for '%s'. Error: %s",
			datastoreId,
			tostring(listResult)
			))
		return
	end

	local keyPages = listResult
	local allKeys = {}

	-- Gather all pages
	while true do
		for _, entry in ipairs(keyPages:GetCurrentPage()) do
			table.insert(allKeys, entry.KeyName)
		end

		if keyPages.IsFinished then
			break
		else
			keyPages:AdvanceToNextPageAsync()
		end
	end

	print(string.format(
		"SoulStore.resetAllData => Found %d keys in datastore '%s'. Starting removal...",
		#allKeys,
		datastoreId
		))

	-- Remove keys sequentially with retry
	for i, key in ipairs(allKeys) do
		local removed = false
		while not removed do
			local removeSuccess, removeErr = pcall(function()
				datastore:RemoveAsync(key)
			end)

			if removeSuccess then
				print(string.format(
					"SoulStore.resetAllData => Removed key '%s' (%d/%d)",
					key,
					i,
					#allKeys
					))
				removed = true
			else
				warn(string.format(
					"SoulStore.resetAllData => FAILED to remove '%s'. Retrying in 1s.\nError: %s (%d/%d)",
					key,
					tostring(removeErr),
					i,
					#allKeys
					))
				task.wait(1)
			end
		end
	end

	print(string.format(
		"SoulStore.resetAllData => COMPLETE! All keys removed from '%s'.",
		datastoreId
		))
end

--[[
    Deletes a single key from a SoulStore datastore.
    
    @param datastoreId The name of the SoulStore datastore.
    @param datastoreKey The key of the profile to remove.
    
]]
function SoulStore.resetData(datastoreId : string, datastoreKey : string)
	local datastore = DataStoreService:GetDataStore(datastoreId)

	local success, err = pcall(function()
		datastore:RemoveAsync(datastoreKey)
	end)

	if success then
		print(string.format(
			"SoulStore.resetData => Successfully removed profile '%s' from datastore '%s'.",
			datastoreKey,
			datastoreId
			))
	else
		warn(string.format(
			"SoulStore.resetData => FAILED to remove profile '%s' from datastore '%s'. Error: %s",
			datastoreKey,
			datastoreId,
			tostring(err)
			))
	end
end

if RunService:IsServer() then
	game:BindToClose(function()
		local totalSouls = 0;
		local savedSouls = 0;
		for _, cachedSouls : {[number] : Soul} in pairs(loadedSouls) do
			for _, soul : Soul in pairs(cachedSouls) do
				totalSouls += 1;
				
				soul.SessionEndBindableEvent.Event:Connect(function()
					savedSouls += 1;
				end)
				
				task.spawn(function()
					soul:SaveData(true);
				end)
			end
		end
		
		-- Yield until all souls are saved
		while savedSouls < totalSouls do
			task.wait();
		end
	end)
end
task.spawn(function()
	while true do
		for _, cachedSouls : {[number] : Soul} in pairs(loadedSouls) do
			for _, soul : Soul in pairs(cachedSouls) do
				if os.time() - soul.LastAutoSave < SOUL_STORE_SETTINGS.AUTO_SAVE_INTERVAL then continue end;
				soul.LastAutoSave = os.time();

				-- It will create new threads
				task.spawn(function()
					soul:SaveData(false);
				end)
			end
		end
		task.wait(10)
	end
end)

Players.PlayerRemoving:Connect(function(player)
	for _, cachedSouls in pairs(loadedSouls) do
		local soul = cachedSouls[player.UserId]
		if soul then
			soul:SaveData(true)
		end
	end
end)

return SoulStore
