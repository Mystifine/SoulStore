-- Every soul that has not settled yet: datastore, then scope, then exact Player instance.

local Logger = require(script.Parent.Logger)
local Types = require(script.Parent.Types)

type Soul = Types.Soul

local SessionCache = {}
SessionCache.DEFAULT_SCOPE = "global" -- roblox's default scope

local cachedSouls: { [string]: { [string]: { [Player]: Soul } } } = {}

function SessionCache.get(datastoreId: string, scope: string?, player: Player): Soul?
	-- The arguments used to be (datastoreId, player). Warning beats every lookup quietly finding nothing.
	if scope ~= nil and typeof(scope) ~= "string" then
		Logger.warn("scope must be a string or nil. The arguments are (datastoreId, scope, player)")
		return nil
	end

	local store = cachedSouls[datastoreId]
	local storeScope = store and store[scope or SessionCache.DEFAULT_SCOPE]
	return storeScope and storeScope[player]
end

function SessionCache.add(soul: Soul)
	local store = cachedSouls[soul.DatastoreId]
	if not store then
		store = {}
		cachedSouls[soul.DatastoreId] = store
	end

	local storeScope = store[soul.Scope]
	if not storeScope then
		storeScope = {}
		store[soul.Scope] = storeScope
	end

	storeScope[soul.Player] = soul
end

function SessionCache.remove(soul: Soul)
	local store = cachedSouls[soul.DatastoreId]
	local storeScope = store and store[soul.Scope]
	if not storeScope or storeScope[soul.Player] ~= soul then
		return
	end

	storeScope[soul.Player] = nil
	if next(storeScope) == nil then
		store[soul.Scope] = nil
		if next(store) == nil then
			cachedSouls[soul.DatastoreId] = nil
		end
	end
end

-- A list rather than the cache itself, because sessions can settle while the caller works through it.
function SessionCache.getAll(): { Soul }
	local souls = {}
	for _, store in pairs(cachedSouls) do
		for _, storeScope in pairs(store) do
			for _, soul in pairs(storeScope) do
				table.insert(souls, soul)
			end
		end
	end
	return souls
end

-- Whether this server has a session in that datastore and scope, or on one key of it if datastoreKey is given.
function SessionCache.hasSession(datastoreId: string, scope: string?, datastoreKey: string?): boolean
	for _, soul in ipairs(SessionCache.getAll()) do
		if
			soul.DatastoreId == datastoreId
			and soul.Scope == (scope or SessionCache.DEFAULT_SCOPE)
			and (datastoreKey == nil or soul.DatastoreKey == datastoreKey)
		then
			return true
		end
	end
	return false
end

return SessionCache
