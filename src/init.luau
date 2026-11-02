--[[
	Created by: Mystifine#4924
	Last Updated: 2026-11-02

	Module used to handle PlayerData

	Features:
	Session locking, with a unique ownership token per session
	Automatic data saving
	Confirmed save results
	Path-based data access, change listeners, and load and save hooks

	Where things live:
	init.luau           The public API, plus autosave, leaving and shutdown
	Session.luau        Claiming a record, normal saves and final saves
	SessionCache.luau   Which souls have not settled yet
	DataValidator.luau  What a data store can hold
	Reset.luau          resetData and resetAllData
	Logger.luau         Output
	Config.luau         Settings
	DeepCopyUtil.luau   Copying tables
	Types.luau          Exported types
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local DataStoreService = game:GetService("DataStoreService")

local Config = require(script.Config)
local DataValidator = require(script.DataValidator)
local DeepCopyUtil = require(script.DeepCopyUtil)
local Logger = require(script.Logger)
local Reset = require(script.Reset)
local Session = require(script.Session)
local SessionCache = require(script.SessionCache)
local Types = require(script.Types)

export type SoulMetaData = Types.SoulMetaData
export type Soul = Types.Soul
export type SoulStore = Types.SoulStore

local STATES = Session.States

local SoulStore = {}
SoulStore.ClassName = "Soul"

local SoulObject = {}
SoulObject.__index = SoulObject
SoulObject.ClassName = "Soul"

local function encodeListenerKey(key: any): string
	local text = tostring(key)
	return (if typeof(key) == "number" then "n" else "s") .. #text .. ":" .. text
end

---------------------------------------------------------------------------------------------------------- Soul methods

--[[
	Loads player data from the datastore, taking the session lock.

	@return true once the session is active; otherwise false and the reason
]]
function SoulObject:LoadData(): (boolean, string?)
	return Session.load(self)
end

--[[
	Saves player data to the datastore.
	@param sessionEnding: boolean - If true ends the session: the final write also releases the lock

	@return true only when this data was confirmed written; otherwise false and the reason
]]
function SoulObject:SaveData(sessionEnding: boolean?): (boolean, string?)
	if sessionEnding then
		return Session.finish(self)
	end
	return Session.save(self)
end

--[[
	Retrieves nested data from a Soul
	@param path : {any}? - Array of keys to traverse
	@return any? - The value at the path, or nil if not found or the session is not active
]]
function SoulObject:GetData(path: { any }?): any?
	local soulObject: Soul = self
	local playerName = soulObject.Player.Name

	if not Session.isUsable(soulObject) then
		Logger.info("GetData => Session is not active for player %s", playerName)
		return nil
	end

	local data: any = soulObject.Data
	if not path then
		return data
	end

	for index, key in ipairs(path) do
		local isTable = typeof(data) == "table"
		data = if isTable then data[key] else nil
		if data == nil then
			-- A missing leaf value is often expected, so only a broken path is worth a warning
			if not isTable or index < #path then
				Logger.warn("GetData => '%s' is not a valid property for player %s", tostring(key), playerName)
			end
			return nil
		end
	end

	return data
end

--[[
	Sets nested data on a Soul
	@param path : {any} - Array of keys to traverse
	@param value : any - Value to set
	@return any? - The value set, or nil if it was rejected. Callers granting something of value must check this.
]]
function SoulObject:SetData(path: { any }, value: any): any?
	local soulObject: Soul = self
	local playerName = soulObject.Player.Name

	if not Session.isUsable(soulObject) then
		Logger.warn("SetData => Session is not active for player %s", playerName)
		return nil
	end

	if typeof(path) ~= "table" or #path == 0 then
		Logger.warn("SetData => Path must contain at least one key for player %s", playerName)
		return nil
	end

	if path[1] == "MetaData" then
		Logger.warn("SetData => MetaData is reserved. Rejected for player %s", playerName)
		return nil
	end

	for _, key in ipairs(path) do
		local keyProblem = DataValidator.getKeyProblem(key)
		if keyProblem then
			Logger.warn("SetData => Rejected %s for player %s", keyProblem, playerName)
			return nil
		end
	end

	local problem = DataValidator.getValueProblem(value)
	if problem then
		local pathName = table.concat(path, ".")
		Logger.warn("SetData => Rejected %s for player %s at %s", problem, playerName, pathName)
		return nil
	end

	-- owners[i] is the table that holds path[i]
	local owners: { any } = { soulObject.Data }
	for index = 1, #path - 1 do
		local child = owners[index][path[index]]
		if typeof(child) ~= "table" then
			Logger.warn("SetData => '%s' is not a table for player %s", tostring(path[index]), playerName)
			return nil
		end
		owners[index + 1] = child
	end

	local writeProblem = DataValidator.getWriteProblem(owners[#path], path[#path], value)
	if writeProblem then
		local pathName = table.concat(path, ".")
		Logger.warn("SetData => Rejected %s for player %s at %s", writeProblem, playerName, pathName)
		return nil
	end

	-- Listeners get copies, so nothing they do can reach the saved data, and what they keep cannot change under them.
	-- The whole-table level also leaves out MetaData.
	local function copyLevel(depth: number): any
		if depth == 0 then
			local snapshot = DeepCopyUtil.deepCopy(soulObject.Data)
			snapshot.MetaData = nil
			return snapshot
		end
		return DeepCopyUtil.deepCopy(owners[depth][path[depth]])
	end

	-- Only levels someone listens to are copied. Old values have to be copied before the write.
	local notifications = {}
	local function queueListeners(depth: number, listenerKey: string)
		local listeners = soulObject._Listeners[listenerKey]
		if listeners and #listeners > 0 then
			table.insert(notifications, { Depth = depth, Listeners = table.clone(listeners), Old = copyLevel(depth) })
		end
	end

	local listenerKey = ""
	queueListeners(0, listenerKey) -- listeners on the whole data table
	for depth = 1, #path do
		listenerKey ..= encodeListenerKey(path[depth])
		queueListeners(depth, listenerKey)
	end

	owners[#path][path[#path]] = value

	for _, notification in ipairs(notifications) do
		local newValue = copyLevel(notification.Depth)
		for _, connection in ipairs(notification.Listeners) do
			if connection.Connected and soulObject.SessionState == STATES.Active then
				task.spawn(connection.Callback, notification.Old, newValue)
			end
		end
	end

	return value
end

--[[
	Fills in what the soul's data is missing from external data. Only string keys are filled: an array the save already
	has belongs to the player, and filling it by index could bring back entries they no longer have or give one entry
	the fields of another. A missing array is copied whole.

	@param data : {}? - External data to reconcile
]]
function SoulObject:Reconcile(data: {}?)
	local soulObject: Soul = self
	local playerName = soulObject.Player.Name

	if not Session.isUsable(soulObject) then
		Logger.info("Reconcile => Session is not active for player %s", playerName)
		return
	end

	if not data then
		Logger.warn("Reconcile => No data provided to reconcile for player %s", playerName)
		return
	end

	-- Internal recursive merge function
	local function merge(target: any, source: any)
		if #target > 0 then
			return -- a named field added to an array would make it something a data store cannot hold as it is
		end
		for key, value in pairs(source) do
			if typeof(key) ~= "string" then
				continue
			end
			if typeof(value) == "table" and typeof(target[key]) == "table" then
				merge(target[key], value)
			elseif target[key] == nil then
				-- Copied so no two souls, nor the template, ever share a table
				target[key] = DeepCopyUtil.deepCopy(value)
			end
		end
	end

	local template = table.clone(data)
	template.MetaData = nil
	merge(soulObject.Data, template)
	Logger.info("Reconcile => Data reconciled for player %s", playerName)
end

--[[
	Listens to data change provided a path and a callback function.

	@param path - The path to the data you want to listen to. If you want to listen to the entire data structure, pass nil.
	@param callback - Called with copies of the old and new values, which it can keep or change freely.
	@return A connection object that can be disconnected.
]]
function SoulObject:OnDataChanged(path: { string | number }?, callback: (oldData: any?, newData: any?) -> ())
	local soulObject: Soul = self

	local key = ""
	for _, pathKey in ipairs(path or {}) do
		key ..= encodeListenerKey(pathKey)
	end

	local listeners = soulObject._Listeners[key]
	if not listeners then
		listeners = {}
		soulObject._Listeners[key] = listeners
	end

	local connection = { Connected = true, Callback = callback }
	table.insert(listeners, connection)

	return {
		Disconnect = function()
			if not connection.Connected then
				return
			end
			connection.Connected = false

			local index = table.find(listeners, connection)
			if index then
				table.remove(listeners, index)
			end
		end,
	}
end

--[[
	Attaches a onLoad function that is called on a copy of the data before the session becomes active.
	If it errors or yields, the load fails and the stored data stays as it was.

	@param onLoadCallback: The callback function that you want called before the soul is returned
	@return nil
]]
function SoulObject:SetOnLoad(onLoadCallback: (dataToBeLoaded: {}) -> ())
	self._onLoad = onLoadCallback
end

--[[
	Attached a onSave function that is called on a copy of the data before it is saved.
	If it errors or yields, that copy is discarded. It may run again for a final save.

	@param onSaveCallback: The callback function that you want called before the data is saved
	@return nil
]]
function SoulObject:SetOnSave(onSaveCallback: (dataToBeSaved: {}) -> ())
	self._onSave = onSaveCallback
end

------------------------------------------------------------------------------------------------------ SoulStore functions

SoulStore.deepCopy = DeepCopyUtil.deepCopy
SoulStore.getDatastore = Session.getDatastore
SoulStore.getMetaData = Session.getMetaData
SoulStore.output = Logger.output
SoulStore.playerExists = Session.playerExists
SoulStore.resetAllData = Reset.resetAllData
SoulStore.resetData = Reset.resetData

--[[
	Retrieves the soul of a usable session

	@param datastoreId : string - The datastore id for the soul
	@param scope : string? - The scope for the soul. nil is roblox's default scope.
	@param player : Player - The player object for the soul

	@return Soul - The soul if it is active, nil otherwise
]]
function SoulStore.getSoul(datastoreId: string, scope: string?, player: Player): Soul?
	local soul = SessionCache.get(datastoreId, scope, player)
	return if soul and Session.isUsable(soul) then soul else nil
end

-- For inspection only: a session still loading. Its data is not available.
function SoulStore.getPendingSoul(datastoreId: string, scope: string?, player: Player): Soul?
	local soul = SessionCache.get(datastoreId, scope, player)
	return if soul and soul.SessionState == STATES.Pulling then soul else nil
end

-- For inspection only: a session in its final save. Its data is not available.
function SoulStore.getEndingSoul(datastoreId: string, scope: string?, player: Player): Soul?
	local soul = SessionCache.get(datastoreId, scope, player)
	return if soul and soul.SessionState == STATES.Ending then soul else nil
end

function SoulStore.hasActiveSession(datastoreId: string, scope: string?, player: Player): boolean
	return SoulStore.getSoul(datastoreId, scope, player) ~= nil
end

--[[
	Creates a soul object, or returns this player's soul if one is already loading or active

	@param datastoreId : string - The datastore id for the soul
	@param scope : string? - The scope for the soul. nil is roblox's default scope.
	@param player : Player - The player object for the soul
	@param defaultData : {} - The default data for the soul

	@return Soul? - The soul object, or nil if it cannot be created
]]
function SoulStore.new(datastoreId: string, scope: string?, player: Player, defaultData: {}): Soul?
	if Session.isShuttingDown then
		Logger.warn("SoulStore.new => The server is shutting down")
		return nil
	end

	if typeof(datastoreId) ~= "string" or datastoreId == "" or #datastoreId > 50 then
		Logger.warn("SoulStore.new => datastoreId must be a string of 1 to 50 characters")
		return nil
	end

	if scope ~= nil and (typeof(scope) ~= "string" or scope == "" or #scope > 50) then
		Logger.warn(
			"SoulStore.new => scope must be nil or 1 to 50 characters. The arguments are (id, scope, player, data)"
		)
		return nil
	end

	-- Default Data must be a table
	if typeof(defaultData) ~= "table" then
		Logger.warn("SoulStore.new => defaultData must be a table/dictionary")
		return nil
	end

	-- It is written as it is for a new player, and a save needs string keys at its top to hold MetaData
	local defaultsProblem = DataValidator.getValueProblem(defaultData)
	if defaultsProblem or #defaultData > 0 then
		Logger.warn(
			"SoulStore.new => defaultData must be a dictionary a data store can hold: %s",
			defaultsProblem or "an array"
		)
		return nil
	end

	if not Session.playerExists(player) then
		Logger.warn("SoulStore.new => Failed to create a soul. The player no longer exists in the game.")
		return nil
	end

	-- Keyed by the exact Player instance: someone rejoining is a new instance and gets a new session
	local existing = SessionCache.get(datastoreId, scope, player)
	if existing then
		if existing.SessionState == STATES.Pulling or existing.SessionState == STATES.Active then
			return existing
		end
		Logger.warn("SoulStore.new => This player's previous session is still ending")
		return nil
	end

	local defaults = DeepCopyUtil.deepCopy(defaultData)
	defaults.MetaData = nil

	local soulObject = setmetatable({}, SoulObject)

	soulObject.Player = player
	soulObject.UserId = player.UserId
	soulObject.DatastoreId = datastoreId
	soulObject.Scope = scope or SessionCache.DEFAULT_SCOPE
	soulObject.DatastoreKey = tostring(player.UserId)
	-- Ownership belongs to this session, not this server: several sessions for one player can share a JobId
	soulObject.SessionToken = HttpService:GenerateGUID(false)
	soulObject.Data = {}
	soulObject.LastAutoSave = os.clock()
	soulObject.IsSaving = false

	soulObject.SessionState = STATES.Pulling
	soulObject.LoadState = Session.LoadStates.Idle
	soulObject.SaveState = Session.SaveStates.Idle
	soulObject.SessionEndBindableEvent = Instance.new("BindableEvent")
	soulObject.SessionEndBindableEvent.Name = tostring(player.UserId)
	soulObject.SessionEndBindableEvent.Parent = script

	soulObject._Listeners = {}
	soulObject._defaultData = defaults
	soulObject._newestWrite = 0
	soulObject._warned = {}
	soulObject._isLoading = false
	soulObject._isSealing = false
	soulObject._cancelRequested = false

	SessionCache.add(soulObject)

	return soulObject
end

--------------------------------------------------------------------------------------- Autosave, leaving and shutdown

local function runSchedulerTick()
	local now = os.clock()
	local active = 0
	local due = {}
	for _, soul in ipairs(SessionCache.getAll()) do
		if soul.SessionState == STATES.Active then
			active += 1
			if
				now - soul.LastAutoSave >= Config.AUTO_SAVE_INTERVAL
				and (not soul.IsSaving or Session.hasSaveHung(soul))
			then
				table.insert(due, soul)
			end
		end
	end

	-- Autosaves wait for budget rather than overflowing the request queue. Final saves are never held back.
	local checked, budget = pcall(function()
		return DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync)
	end)
	-- Twice the steady rate at most, so that a backlog, as after an outage, is spread out rather than copying every
	-- player's data in one frame
	local steadyRate = math.ceil(active / Config.AUTO_SAVE_INTERVAL)
	local allowed = math.min(steadyRate * 2, if checked then budget else #due)
	if #due > allowed then
		-- Whoever has waited longest goes first, so that everyone gets a turn however little there is to go around
		table.sort(due, function(a, b)
			return a.LastAutoSave < b.LastAutoSave
		end)
	end
	for index, soul in ipairs(due) do
		if index > allowed then
			break
		end
		task.spawn(Session.save, soul)
	end
end

if RunService:IsServer() then
	game:BindToClose(function()
		Session.isShuttingDown = true

		local tracked = SessionCache.getAll()
		for _, soul in ipairs(tracked) do
			task.spawn(Session.finish, soul)
		end

		-- Checks each session's own state, which cannot be missed or drift the way an event or a counter can
		local function anyUnsettled(): boolean
			for _, soul in ipairs(tracked) do
				if not Session.isSettled(soul) then
					return true
				end
			end
			return false
		end

		-- Keeps the server up until every session has settled, for as long as Roblox allows. Whatever has not saved by
		-- then keeps its lock, which expires.
		while anyUnsettled() do
			task.wait(0.1)
		end
	end)

	task.spawn(function()
		while not Session.isShuttingDown do
			task.wait(1)
			local ok, problem = pcall(runSchedulerTick)
			if not ok then
				Logger.warn("Autosave tick failed: %s", tostring(problem))
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		for _, soul in ipairs(SessionCache.getAll()) do
			if soul.Player == player then
				-- Deferred, so every other leave handler has run first, in whatever order Roblox ran them, and what they
				-- wrote is in the final save. One thread per store: a stuck store must not hold up the others.
				task.defer(Session.finish, soul)
			end
		end
	end)
end

return SoulStore
