-- Deleting saved data. Refused for any record a session on this server is using: its next save would undo the reset.

local RunService = game:GetService("RunService")

local Logger = require(script.Parent.Logger)
local Session = require(script.Parent.Session)
local SessionCache = require(script.Parent.SessionCache)

local MAX_REMOVE_ATTEMPTS = 5

local Reset = {}

local function removeWithRetries(datastore: DataStore, key: string): boolean
	for attempt = 1, MAX_REMOVE_ATTEMPTS do
		local success, err = pcall(function()
			datastore:RemoveAsync(key)
		end)
		if success then
			return true
		end
		Logger.warn("resetAllData => FAILED to remove '%s' (attempt %d): %s", key, attempt, tostring(err))
		task.wait(attempt)
	end
	return false
end

--[[
	Deletes ALL keys in a SoulStore datastore.
	Use with extreme caution.

	@param datastoreId : string - The datastore id to reset.
	@param scope : string? - The scope to reset. nil is roblox's default scope.
	@param confirmation : string? - Outside Studio this must repeat datastoreId, or nothing is deleted.
	@return true if every key was removed
]]
function Reset.resetAllData(datastoreId: string, scope: string?, confirmation: string?): boolean
	if not RunService:IsStudio() and confirmation ~= datastoreId then
		Logger.warn("resetAllData => Refused. Outside Studio, pass the datastore name again to confirm.")
		return false
	end

	if SessionCache.hasSession(datastoreId, scope) then
		Logger.warn("resetAllData => Refused. This server has sessions in that datastore.")
		return false
	end

	warn(string.format(
		[[
===========================================================
SoulStore.resetAllData => WARNING
You are about to WIPE ALL DATA in datastore '%s' (scope '%s').
This operation may take a long time depending on key count.

DO NOT close Roblox Studio
DO NOT shutdown your computer
NO active player sessions should exist

Process begins in 10 seconds...
===========================================================
]],
		datastoreId,
		scope or SessionCache.DEFAULT_SCOPE
	))
	task.wait(10)

	local datastore = Session.getDatastore(datastoreId, scope)
	local success, keyPages = pcall(function()
		return datastore:ListKeysAsync(nil, 100, nil, true)
	end)
	if not success then
		Logger.warn("resetAllData => FAILED to list keys for '%s': %s", datastoreId, tostring(keyPages))
		return false
	end

	local removedKeys = 0
	while true do
		for _, entry in ipairs(keyPages:GetCurrentPage()) do
			if not removeWithRetries(datastore, entry.KeyName) then
				Logger.warn("resetAllData => Stopped early. Removed %d keys.", removedKeys)
				return false
			end
			removedKeys += 1
		end

		if keyPages.IsFinished then
			break
		end

		local advanced, advanceErr = pcall(function()
			keyPages:AdvanceToNextPageAsync()
		end)
		if not advanced then
			Logger.warn("resetAllData => Stopped early. Could not read the next page: %s", tostring(advanceErr))
			return false
		end
	end

	print(string.format("SoulStore.resetAllData => COMPLETE! Removed %d keys from '%s'.", removedKeys, datastoreId))
	return true
end

--[[
	Deletes a single key from a SoulStore datastore.

	@param datastoreId The name of the SoulStore datastore.
	@param scope The scope of the key. nil is roblox's default scope.
	@param datastoreKey The key of the profile to remove.
	@return true if the key was removed
]]
function Reset.resetData(datastoreId: string, scope: string?, datastoreKey: string): boolean
	-- The arguments used to be (datastoreId, datastoreKey), which would land the key in scope
	if typeof(datastoreKey) ~= "string" and typeof(datastoreKey) ~= "number" then
		Logger.warn("resetData => Refused. The arguments are (datastoreId, scope, datastoreKey)")
		return false
	end

	local key = tostring(datastoreKey)
	if SessionCache.hasSession(datastoreId, scope, key) then
		Logger.warn("resetData => Refused. '%s' has a session on this server.", key)
		return false
	end

	local success, err = pcall(function()
		Session.getDatastore(datastoreId, scope):RemoveAsync(key)
	end)
	if success then
		print(string.format("SoulStore.resetData => Removed profile '%s' from datastore '%s'.", key, datastoreId))
	else
		Logger.warn("resetData => FAILED to remove '%s' from '%s': %s", key, datastoreId, tostring(err))
	end
	return success
end

return Reset
