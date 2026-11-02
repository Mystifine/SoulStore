-- Run with Lune 0.11+: lune run tests/games.luau
-- Loads each game's real PlayerDataService from a sibling folder, with its real schema and migrations, and runs it on
-- this SoulStore. The only adaptation is the argument change every game has to make for 2.0: a nil scope is added to
-- SoulStore.new and resetData. A game whose folder is missing is skipped, so this only tests anything on a machine
-- that has the games. tests/consumers.luau covers the same usage without needing them.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local harness = require("./harness")

local equal, expect = harness.equal, harness.expect
local suite = harness.newSuite("real game modules")

local GAMES_ROOT = "../"

-- Stands in for any Roblox instance a game touches: indexing goes deeper, calling does nothing.
local function newProxy(path: string, onNewIndex: ((string, any) -> ())?)
	local children = {}
	local proxy
	proxy = setmetatable({ _path = path }, {
		__index = function(_, key)
			if key == "Parent" then
				return newProxy(string.match(path, "^(.*)/[^/]*$") or "")
			elseif key == "WaitForChild" or key == "FindFirstChild" then
				return function(_self, name)
					return proxy[name]
				end
			elseif key == "GetAttribute" or key == "FindFirstChildWhichIsA" then
				return function()
					return nil
				end
			end
			if not children[key] then
				children[key] = newProxy(path .. "/" .. tostring(key))
			end
			return children[key]
		end,
		__newindex = function(_, key, value)
			if onNewIndex then
				onNewIndex(key, value)
			end
			children[key] = value
		end,
		__call = function()
			return newProxy(path .. "()")
		end,
	})
	return proxy
end

local function readModule(root: string, path: string): string?
	for _, suffix in ipairs({ ".luau", ".lua", "/init.luau", "/init.lua" }) do
		local file = root .. "/" .. path .. suffix
		if fs.isFile(file) then
			return fs.readFile(file)
		end
	end
	return nil
end

--[[
	Options:
		live: whether the world is a live server rather than Studio
		installed: run on the SoulStore version the game has installed, with its old arguments
		overrides: module paths that get a stand-in
		patches: { [path]: { find, replace } } for a change the game has to make to run on 2.0
		service: the path of the module to load
]]
local function loadGame(project: string, options: any)
	local root = GAMES_ROOT .. project .. "/src"
	local installed = nil
	if options.installed then
		local index = GAMES_ROOT .. project .. "/ServerPackages/_Index"
		for _, folder in ipairs(fs.readDir(index)) do
			if string.find(folder, "soulstore", 1, true) then
				installed = { init = fs.readFile(index .. "/" .. folder .. "/soulstore/init.luau") }
			end
		end
		assert(installed, project .. " has no SoulStore installed")
	end
	local world = harness.newWorld({ live = options.live, sources = installed })
	local base = world.environment
	local loaded, standIns = {}, {}

	local gameProxy = newProxy("")
	local function gameService(name: string)
		return world.services[name] or gameProxy[name]
	end

	local realStore = world.soulStore
	local soulStore = if options.installed
		then realStore
		else setmetatable({
			new = function(datastoreId, player, defaults)
				return realStore.new(datastoreId, nil, player, defaults)
			end,
			resetData = function(datastoreId, key)
				return realStore.resetData(datastoreId, nil, key)
			end,
		}, { __index = realStore })

	local function requireModule(module: any)
		if type(module) ~= "table" or not module._path then
			return module
		end
		local path = string.sub(module._path, 2)
		if loaded[path] ~= nil then
			return loaded[path]
		end
		if string.find(path, "/soulstore$") then
			loaded[path] = soulStore
			return soulStore
		end
		if options.overrides and options.overrides[path] then
			loaded[path] = options.overrides[path]
			return loaded[path]
		end
		local source = readModule(root, path)
		if not source then
			table.insert(standIns, path)
			loaded[path] = newProxy(module._path)
			return loaded[path]
		end
		for _, patch in ipairs(options.patches and options.patches[path] or {}) do
			local first, last = string.find(source, patch[1], 1, true)
			assert(first, project .. ": a patch no longer matches " .. path)
			source = string.sub(source, 1, first - 1) .. patch[2] .. string.sub(source, last + 1)
		end

		local environment = table.clone(base)
		environment.game = setmetatable({}, {
			__index = function(_, key)
				if key == "GetService" then
					return function(_self, name)
						return gameService(name)
					end
				elseif key == "Players" then
					return world.players
				elseif key == "JobId" or key == "PlaceId" then
					return world.game[key]
				elseif key == "BindToClose" then
					return function(_self, callback)
						world.game:BindToClose(callback)
					end
				end
				return gameService(key)
			end,
		})
		environment.script = newProxy(module._path)
		environment.require = requireModule
		-- Real Roblox datatypes, because constants modules build Color3s and UDim2s as they load
		for name, value in pairs(roblox) do
			if string.match(name, "^%u") then
				environment[name] = value
			end
		end
		environment.Instance = {
			new = function(className)
				local instance = { ClassName = className }
				return setmetatable(instance, {
					__newindex = function(self, key, value)
						rawset(self, key, value)
						if key == "Parent" and type(value) == "table" then
							rawset(value, self.Name, self)
						end
					end,
				})
			end,
		}
		environment.DateTime = {
			now = function()
				return { UnixTimestamp = environment.os.time(), UnixTimestampMillis = environment.os.time() * 1000 }
			end,
		}
		local chunk =
			luau.load(source, { debugName = project .. "/" .. path, environment = environment, injectGlobals = true })
		loaded[path] = chunk()
		return loaded[path]
	end

	local service = requireModule(newProxy("/" .. options.service))

	-- What the games' code expects of a player beyond the harness's own
	local basePlayer = world.player
	function world:player(userId)
		local player = basePlayer(self, userId)
		function player.WaitForChild(playerSelf, name)
			while rawget(playerSelf, name) == nil do
				base.task.wait()
			end
			return rawget(playerSelf, name)
		end
		function player.FindFirstChild(playerSelf, name)
			return rawget(playerSelf, name)
		end
		function player.SetAttribute() end
		function player.GetAttribute() end
		return player
	end

	if #standIns > 0 and not options.installed then
		print(string.format("     %s stand-ins: %s", project, table.concat(standIns, ", ")))
	end
	return { world = world, service = service, soulStore = realStore, standIns = standIns }
end

local function gamePresent(project: string): boolean
	return fs.isDir(GAMES_ROOT .. project .. "/src")
end

local function gameTest(project: string, name: string, options: any, callback: (any) -> ())
	suite.test(project .. ": " .. name, function()
		if not gamePresent(project) then
			print("SKIP " .. project .. " is not next to this repository")
			return
		end
		callback(loadGame(project, options))
	end)
end

local function assertNoWarnings(world, text: string)
	expect(not world:logged(text), "Unexpected output: " .. text)
end

----------------------------------------------------------------------------------------------------------- AriseShadows

local ARISE = { service = "ServerScriptService/Services/PlayerDataService" }

gameTest("AriseShadows", "a new player loads the real schema and every migration runs", ARISE, function(game)
	local world, service = game.world, game.service
	local player = world:player(1001)
	world.scheduler:call(function()
		service._initPlayerData(player)
	end)
	local soul = service.getSoul(player)
	expect(soul, "The player gets a soul")
	equal(soul.LoadState, "Loaded")
	expect(soul:GetData({ "monetization" }) ~= nil, "The real schema is in place")
	assertNoWarnings(world, "will not load back the same")
	assertNoWarnings(world, "Dropped values")
end)

gameTest("AriseShadows", "persistPurchases keeps the purchase check true on a real save", ARISE, function(game)
	local world, service = game.world, game.service
	local player = world:player(1002)
	world.scheduler:call(function()
		service._initPlayerData(player)
	end)
	service.markPurchaseMutation(player)
	expect(not service.arePurchasesDurable(player))
	local durable = world.scheduler:call(function()
		return service.persistPurchases(player)
	end)
	equal(durable, true)
	expect(service.arePurchasesDurable(player))
	local stored = world.stores[next(world.stores)].data["1002"]
	expect(stored.MetaData.PurchaseCommit ~= nil, "The marker reached the store")

	-- A failed write must read as not durable, so Roblox retries the receipt
	world.stores[next(world.stores)].beforeRead = function()
		error("502: API Services rejected request with error. HTTP 500 (Internal Server Error)", 0)
	end
	service.markPurchaseMutation(player)
	durable = world.scheduler:call(function()
		return service.persistPurchases(player)
	end)
	equal(durable, false)
end)

gameTest(
	"AriseShadows",
	"the real leave path carries what a service commits and what a hook folds",
	ARISE,
	function(game)
		local world, service = game.world, game.service
		world.scheduler:call(function()
			service.main()
		end)
		local pending = 25
		service.onSave(function(_, data)
			data.FoldedByHook = pending
		end)
		local player = world:player(1003)
		world.players.PlayerAdded:Fire(player)
		local soul = world.scheduler:call(function()
			return service.getSoul(player)
		end)
		-- Started after PlayerDataService, like every other service, so Roblox runs this before its final save
		world.players.PlayerRemoving:Connect(function(leaving)
			service.setData(leaving, { "CommittedOnLeave" }, pending)
			pending = 0
		end)
		world:remove(player)
		world.scheduler:runUntil(function()
			return soul.SessionState == "Ended"
		end, 30)
		equal(soul.EndReason, "Saved")
		local stored = world.stores[next(world.stores)].data["1003"]
		equal(stored.CommittedOnLeave, 25)
		equal(stored.FoldedByHook, 0, "The hook sees what the leave handler left it")
		equal(stored.MetaData.Locked, false)
	end
)

gameTest("AriseShadows", "a player leaving during the load gets no soul", ARISE, function(game)
	local world, service = game.world, game.service
	local player = world:player(1004)
	local done = false
	world.latency = 1
	world.scheduler:spawn(function()
		service._initPlayerData(player)
		done = true
	end)
	world:remove(player)
	world.scheduler:runUntil(function()
		return done
	end, 40)
	equal(service.getSoul(player), nil)
end)

------------------------------------------------------------------------------------------------------- WalkToHatchGolems

local GOLEMS = { service = "ServerScriptService/Services/PlayerDataService" }

gameTest("WalkToHatchGolems", "a new player loads the real schema", GOLEMS, function(game)
	local world, service = game.world, game.service
	local player = world:player(2001)
	world.scheduler:call(function()
		service._initPlayerData(player)
	end)
	local soul = service.getSoul(player)
	expect(soul)
	expect(soul:GetData({ "Settings" }) ~= nil)
	assertNoWarnings(world, "will not load back the same")
	assertNoWarnings(world, "Dropped values")
end)

gameTest("WalkToHatchGolems", "an old save goes through every real repair and stays repaired", GOLEMS, function(game)
	local world, service = game.world, game.service
	local player = world:player(2002)
	local store = world.dataStoreService:GetDataStore("PlayerData")
	store.data["2002"] = {
		Coins = 5,
		SessionRewards = { Old = true },
		Settings = { RetiredSetting = 1 },
		Golems = {
			["uuid-a"] = { Id = "Madara Golem", UUID = "uuid-a", Level = 3, Experience = 1e85, FuseProgress = 2 },
		},
		FighterGolems = {},
		Index = { ["Madara Golem"] = { Claimed = true } },
		Inventory = { ["Madara Egg"] = 2 },
		IncubatedEggs = { { EggId = "Madara Egg" } },
		Rebirth = { FirstPityDone = { ["Crimson Eye Egg"] = { Legendary = true } } },
		MetaData = { Locked = false, SessionId = "", SaveId = 900, LastUpdate = 1600000000 },
	}
	world.scheduler:call(function()
		service._initPlayerData(player)
	end)
	local soul = service.getSoul(player)
	local data = soul:GetData({})
	equal(data.SessionRewards, nil, "Retired keys are removed through SetData(path, nil)")
	equal(data.Settings.RetiredSetting, nil)
	local golem = data.Golems["uuid-a"]
	equal(golem.Id, "Crimson Warlord Golem", "A numeric-free path through a keyed table")
	equal(golem.FuseProgress, nil)
	expect(golem.Experience < 1e85, "The real experience repair ran")
	equal(data.Inventory["Crimson Eye Egg"], 2)
	equal(data.Inventory["Madara Egg"], nil)
	equal(data.IncubatedEggs[1].EggId, "Crimson Eye Egg", "A number in a path")
	equal(data.Rebirth.FirstPityDone, nil)
	equal(data.Rebirth.PityRounds["Crimson Eye Egg"].Legendary, 1)

	world:remove(player)
	service._onPlayerRemoving(player)
	world.scheduler:runUntil(function()
		return soul.SessionState == "Ended"
	end, 30)
	local stored = store.data["2002"]
	equal(stored.Golems["uuid-a"].Id, "Crimson Warlord Golem")
	equal(stored.SessionRewards, nil)
	equal(stored.MetaData.SaveId > 900, true)
end)

gameTest("WalkToHatchGolems", "a listener keeping the combat cache current receives copies", GOLEMS, function(game)
	local world, service = game.world, game.service
	local player = world:player(2003)
	world.scheduler:call(function()
		service._initPlayerData(player)
	end)
	local cached
	world.scheduler:call(function()
		service.onDataChanged(player, { "FighterGolems" }, function(_, newData)
			cached = newData
		end)
	end)
	world.scheduler:call(function()
		service.setData(player, { "FighterGolems", "uuid-b" }, { Level = 1 })
	end)
	equal(cached["uuid-b"].Level, 1)
	world.scheduler:call(function()
		service.setData(player, { "FighterGolems", "uuid-b", "Level" }, 2)
	end)
	equal(cached["uuid-b"].Level, 2, "Each change below the path fires it again")
	local soul = service.getSoul(player)
	expect(cached ~= soul:GetData({ "FighterGolems" }), "It is not the live table")
end)

---------------------------------------------------------------------------------------------------------------- TierBound

local TIER = { service = "ServerScriptService/Services/PlayerDataService" }

gameTest("TierBound", "the real schema loads, saves and reconciles without sharing tables", TIER, function(game)
	local world, service = game.world, game.service
	local player = world:player(3001)
	world.scheduler:call(function()
		service._initPlayerData(player)
	end)
	local soul = service.getSoul(player)
	expect(soul)
	equal(service.getData(player, { "Silver" }), 100)
	world.scheduler:call(function()
		service.setData(player, { "CombatStats", "Strength" }, 9)
	end)
	world:remove(player)
	service._onPlayerRemoving(player)
	world.scheduler:runUntil(function()
		return soul.SessionState == "Ended"
	end, 30)
	local stored = world.stores.PlayerData.data["3001"]
	equal(stored.CombatStats.Strength, 9)
	equal(stored.MetaData.Locked, false)
	assertNoWarnings(world, "will not load back the same")
end)

gameTest("TierBound", "a load that fails leaves GetData empty rather than handing out defaults", TIER, function(game)
	local world, service = game.world, game.service
	local player = world:player(3002)
	local store = world.dataStoreService:GetDataStore("PlayerData")
	store.data["3002"] = "not a save"
	world.scheduler:call(function()
		service._initPlayerData(player)
	end)
	equal(service.getData(player, { "Silver" }), nil)
	equal(store.data["3002"], "not a save")
end)

------------------------------------------------------------------------------------------------------------ Critterhaven

local CRITTER = { service = "ServerScriptService/Services/PlayerDataService", live = true }

gameTest("Critterhaven", "the real load, update and leave flow", CRITTER, function(game)
	local world, service = game.world, game.service
	world.scheduler:call(function()
		service.main()
	end)
	local player = world:player(4001)
	world.players.PlayerAdded:Fire(player)
	world.scheduler:runUntil(function()
		return service.GetSnapshot(player) ~= nil
	end, 30)
	local revision = service.GetSnapshot(player).revision
	local updated = service.Update(player, function(data)
		data.CompatProbe = 5
	end)
	equal(updated, true)
	equal(service.GetSnapshot(player).revision, revision + 1)
	equal(service.GetSnapshot(player).data.CompatProbe, 5, "The root table the game keeps sees SetData's change")

	local storeName = next(world.stores)
	world:remove(player)
	world.scheduler:runUntil(function()
		return world.stores[storeName].data["4001"].MetaData.Locked == false
	end, 30)
	equal(world.stores[storeName].data["4001"].Data.CompatProbe, 5)
	assertNoWarnings(world, "will not load back the same")
	assertNoWarnings(world, "Dropped values")
end)

-- The one intended difference from 1.x. A saved cottage in the slot where the schema has its starter town hall used to
-- pick up the hall's missing fields.
local function startCritterTown(game)
	local world, service = game.world, game.service
	world.dataStoreService:GetDataStore("MyCuteTown_PlayerData_Development").data["4002"] = {
		SchemaVersion = 7,
		Data = {
			landSections = { { x = 5, z = 5 } },
			buildings = { { id = "b1", typeId = "cottage", level = 2, x = 10, z = 10 } },
			decorations = {},
		},
	}
	world.scheduler:call(function()
		service.main()
	end)
	local player = world:player(4002)
	world.players.PlayerAdded:Fire(player)
	world.scheduler:runUntil(function()
		return service.GetSnapshot(player) ~= nil
	end, 30)
	return service.GetSnapshot(player).data
end

gameTest("Critterhaven", "Reconcile leaves a saved town's buildings and land as they are", CRITTER, function(game)
	local data = startCritterTown(game)
	equal(#data.buildings, 1)
	equal(data.buildings[1].typeId, "cottage")
	equal(data.buildings[1].rotation, nil, "The schema's starter hall stays out of it")
	equal(data.landSections[1].x, 5)
	expect(data.resources ~= nil and data.resources.coins == 120, "Fields the save is missing still arrive")
end)

gameTest(
	"Critterhaven",
	"the installed version is the one that filled a building from the starter hall",
	{ service = CRITTER.service, live = true, installed = true },
	function(game)
		equal(
			startCritterTown(game).buildings[1].rotation,
			0,
			"If this ever fails, the note in migrating.md is out of date"
		)
	end
)

--------------------------------------------------------------------------------------------------------- PlusOneTemplate

local PLUS_ONE_FIX = { "meta.SessionId == game.JobId", "meta.SessionId == soul.SessionToken" }
-- The one thing its schema needs from the MysLib package
local PLUS_ONE_PACKAGES = {
	["ReplicatedStorage/Packages/myslib"] = setmetatable(
		{ TableUtil = { deepCopy = harness.copy } },
		{ __index = newProxy("/ReplicatedStorage/Packages/myslib") }
	),
}
local PLUS_ONE = { service = "ServerScriptService/Services/PlayerDataService", overrides = PLUS_ONE_PACKAGES }
local PLUS_ONE_FIXED = {
	service = "ServerScriptService/Services/PlayerDataService",
	overrides = PLUS_ONE_PACKAGES,
	patches = { ["ServerScriptService/Services/PlayerDataService"] = { PLUS_ONE_FIX } },
}

local function startPlusOne(game, userId)
	local world, service = game.world, game.service
	world.scheduler:call(function()
		service.main()
	end)
	local player = world:player(userId)
	world.players.PlayerAdded:Fire(player)
	world.scheduler:runUntil(function()
		return service.IsLoaded(player)
	end, 30)
	return world, service, player
end

gameTest(
	"PlusOneTemplate",
	"the load hook normalizes and the save hook stamps the snapshot",
	PLUS_ONE_FIXED,
	function(game)
		local world, service, player = startPlusOne(game, 5001)
		local data = service.Get(player)
		expect(data, "Get returns the live table")
		local saved = world.scheduler:call(function()
			return service.SaveNow(player, 20)
		end)
		equal(saved, true)
		local stored = world.stores[next(world.stores)].data["5001"]
		expect(stored.meta.lastSaveAt ~= nil, "The save hook ran on the copy")
		equal(data.meta.lastSaveAt == stored.meta.lastSaveAt, false, "Live data is untouched by the hook")
		assertNoWarnings(world, "will not load back the same")
		assertNoWarnings(world, "Dropped values")
	end
)

gameTest("PlusOneTemplate", "with the one-line fix, SaveNow reports a failed write", PLUS_ONE_FIXED, function(game)
	local world, service, player = startPlusOne(game, 5002)
	world.stores[next(world.stores)].beforeRead = function()
		error("502: API Services rejected request with error. HTTP 500 (Internal Server Error)", 0)
	end
	local saved = world.scheduler:call(function()
		return service.SaveNow(player, 20)
	end)
	equal(saved, false)
end)

gameTest("PlusOneTemplate", "unchanged, SaveNow's JobId check can never pass on 2.0", PLUS_ONE, function(game)
	local world, service, player = startPlusOne(game, 5003)
	local saved = world.scheduler:call(function()
		return service.SaveNow(player, 20)
	end)
	equal(saved, false, "If this ever passes, the fix in migrating.md is no longer needed")
	local stored = world.stores[next(world.stores)].data["5003"]
	expect(stored.MetaData.SaveId >= 2, "The write itself landed, so purchases would retry forever")
end)

gameTest(
	"PlusOneTemplate",
	"direct edits through Mutate are saved, and the session end stops them",
	PLUS_ONE_FIXED,
	function(game)
		local world, service, player = startPlusOne(game, 5004)
		local ok, code = service.Mutate(player, { "economy" }, function(data)
			data.CompatProbe = 5
		end)
		equal(ok, true)
		equal(code, "SUCCESS")
		world:remove(player)
		world.scheduler:runUntil(function()
			return world.stores[next(world.stores)].data["5004"].MetaData.Locked == false
		end, 30)
		equal(world.stores[next(world.stores)].data["5004"].CompatProbe, 5)
	end
)

-------------------------------------------------------------------------------- Old and new servers during an update

local OLD_SOULSTORE = GAMES_ROOT .. "AriseShadows/ServerPackages/_Index/mystifine_soulstore@1.0.8/soulstore/init.luau"

local function fleetTest(name: string, callback: (any, any, any, any) -> ())
	suite.test("rolling update: " .. name, function()
		if not fs.isFile(OLD_SOULSTORE) then
			print("SKIP the published 1.0.8 is not available")
			return
		end
		local servers, stores, scheduler =
			harness.newCluster(2, { sources = { { init = fs.readFile(OLD_SOULSTORE) }, nil } })
		callback(servers[1], servers[2], stores, scheduler)
	end)
end

local function oldActive(server, userId, defaults)
	local player = server:player(userId)
	local soul = assert(server.soulStore.new("PlayerData", player, defaults))
	server.scheduler:call(function()
		soul:LoadData()
	end)
	return soul, player
end

local function newLoad(server, userId, defaults)
	local soul = assert(server.soulStore.new("PlayerData", nil, server:player(userId), defaults))
	local state = { done = false }
	server.scheduler:spawn(function()
		state.loaded = soul:LoadData()
		state.done = true
	end)
	return soul, state
end

fleetTest("a player moving from an old server to a new one keeps everything", function(old, new, stores, scheduler)
	local soul, player = oldActive(old, 7001, { Coins = 1 })
	soul:SetData({ "Coins" }, 50)
	soul.Data.MetaData.PurchaseCommit = "x"
	local arriving, state = newLoad(new, 7001, { Coins = 0 })
	scheduler:advance(10)
	equal(state.done, false, "The old server's lock is respected")
	old:remove(player)
	scheduler:runUntil(function()
		return state.done
	end, 30)
	equal(state.loaded, true)
	equal(arriving.Data.Coins, 50)
	equal(arriving.Data.MetaData.PurchaseCommit, "x")
	equal(stores.PlayerData.data["7001"].MetaData.SessionId, arriving.SessionToken)
end)

fleetTest("a player moving from a new server to an old one keeps everything", function(old, new, stores, scheduler)
	local player = new:player(7002)
	local soul = new:active("PlayerData", player, { Coins = 1 })
	soul:SetData({ "Coins" }, 50)
	local oldPlayer = old:player(7002)
	local arriving = assert(old.soulStore.new("PlayerData", oldPlayer, { Coins = 0 }))
	local loaded = false
	scheduler:spawn(function()
		arriving:LoadData()
		loaded = true
	end)
	scheduler:advance(10)
	equal(loaded, false, "The old server understands the new lock")
	new:remove(player)
	scheduler:runUntil(function()
		return loaded
	end, 30)
	equal(arriving.LoadState, "Loaded")
	equal(arriving.Data.Coins, 50)
	equal(stores.PlayerData.data["7002"].MetaData.SessionId, old.game.JobId, "Old servers still use the JobId")
end)

fleetTest("a healthy old server keeps its record while a new one waits", function(old, new, stores, scheduler)
	local soul = oldActive(old, 7003, { Coins = 1 })
	local _, state = newLoad(new, 7003, { Coins = 0 })
	scheduler:advance(600)
	equal(state.done, false, "1.x autosaves restart the takeover wait")
	equal(stores.PlayerData.data["7003"].MetaData.Locked, true)
	expect(soul.Data.MetaData.SaveId > 1)
end)

fleetTest("a healthy new server keeps its record while an old one waits", function(old, new, stores, scheduler)
	local soul = new:active("PlayerData", new:player(7004), { Coins = 1 })
	local arriving = assert(old.soulStore.new("PlayerData", old:player(7004), { Coins = 0 }))
	scheduler:spawn(function()
		arriving:LoadData()
	end)
	scheduler:advance(600)
	equal(arriving.LoadState, "Loading", "Autosaves keep LastUpdate fresh for old servers")
	equal(soul.SessionState, "Active")
	equal(stores.PlayerData.data["7004"].MetaData.SessionId, soul.SessionToken)
end)

fleetTest("a crashed old server is taken over by a new one", function(old, new, stores, scheduler)
	oldActive(old, 7005, { Coins = 1 })
	old:crash()
	local arriving, state = newLoad(new, 7005, { Coins = 0 })
	scheduler:runUntil(function()
		return state.done
	end, 120)
	equal(state.loaded, true)
	equal(stores.PlayerData.data["7005"].MetaData.SessionId, arriving.SessionToken)
end)

--------------------------------------------------------------------- The same flow on the installed version and this one

-- Fields that are meant to differ: who holds the lock, how many writes it took, and the time of day
local EXPECTED_TO_DIFFER = {
	["MetaData.SessionId"] = true,
	["MetaData.LastUpdate"] = true,
	["MetaData.SaveId"] = true,
	["MetaData.PurchaseCommit"] = true,
	["meta.lastSaveAt"] = true,
	["meta.lastSeenAt"] = true,
}

local function findDifferences(left: any, right: any, path: string, found: { string })
	if EXPECTED_TO_DIFFER[path] then
		return
	end
	if type(left) == "table" and type(right) == "table" then
		for key, value in pairs(left) do
			local child = if path == "" then tostring(key) else path .. "." .. tostring(key)
			findDifferences(value, right[key], child, found)
		end
		for key, value in pairs(right) do
			if left[key] == nil then
				local child = if path == "" then tostring(key) else path .. "." .. tostring(key)
				table.insert(found, string.format("%s: only in this version: %s", child, tostring(value)))
			end
		end
	elseif left ~= right and not (left ~= left and right ~= right) then
		-- Values of different types land here as well, because they are never equal
		table.insert(found, string.format("%s: %s vs %s", path, tostring(left), tostring(right)))
	end
end

-- Runs a flow on both versions and compares everything it left in the data stores.
local function compareVersions(project: string, name: string, options: any, flow: (any) -> ())
	suite.test(project .. ": " .. name, function()
		if not gamePresent(project) then
			print("SKIP " .. project .. " is not next to this repository")
			return
		end
		local oldOptions = table.clone(options)
		oldOptions.installed = true
		local old = loadGame(project, oldOptions)
		flow(old)
		local new = loadGame(project, options)
		flow(new)

		local differences = {}
		for storeName, store in pairs(old.world.stores) do
			local other = new.world.stores[storeName]
			expect(other, "This version never opened " .. storeName)
			findDifferences(store.data, other.data, "", differences)
		end
		-- The records are one level down, so strip the key from the ignored paths
		local unexpected = {}
		for _, difference in ipairs(differences) do
			local withoutKey = string.match(difference, "^[^.]*%.(.*)$") or difference
			local field = string.match(withoutKey, "^([^:]*):")
			if not EXPECTED_TO_DIFFER[field] then
				table.insert(unexpected, difference)
			end
		end
		expect(#unexpected == 0, "Stored data differs:\n" .. table.concat(unexpected, "\n"))
	end)
end

local function leaveAndSettle(world, player)
	world:remove(player)
	world.scheduler:advance(20)
end

compareVersions("AriseShadows", "the same play session stores the same data", ARISE, function(game)
	local world, service = game.world, game.service
	service.onSave(function(_player, data)
		data.FoldedByHook = 25
	end)
	local player = world:player(6001)
	world.scheduler:call(function()
		service._initPlayerData(player)
	end)
	world.scheduler:call(function()
		service.setData(player, { "settings", "CompatProbe" }, 5)
		service.persistPurchases(player)
		service._onPlayerRemoving(player)
	end)
	leaveAndSettle(world, player)
end)

compareVersions("WalkToHatchGolems", "an old save ends up the same after a play session", GOLEMS, function(game)
	local world, service = game.world, game.service
	local player = world:player(6002)
	world.dataStoreService:GetDataStore("PlayerData").data["6002"] = {
		Coins = 5,
		SessionRewards = { Old = true },
		Settings = { RetiredSetting = 1, MusicVolume = 0.5 },
		Golems = {
			["uuid-a"] = { Id = "Madara Golem", UUID = "uuid-a", Level = 3, Experience = 1e85, FuseProgress = 2 },
		},
		Inventory = { ["Madara Egg"] = 2 },
		IncubatedEggs = { { EggId = "Madara Egg" } },
		MetaData = { Locked = false, SessionId = "", SaveId = 900, LastUpdate = 1600000000 },
	}
	world.scheduler:call(function()
		service._initPlayerData(player)
	end)
	world.scheduler:call(function()
		service.setData(player, { "Settings", "MusicVolume" }, 0.25)
		service.setData(player, { "FighterGolems", "uuid-b" }, { Level = 1 })
		service._onPlayerRemoving(player)
	end)
	leaveAndSettle(world, player)
end)

compareVersions("TierBound", "the same play session stores the same data", TIER, function(game)
	local world, service = game.world, game.service
	local player = world:player(6003)
	world.scheduler:call(function()
		service._initPlayerData(player)
	end)
	world.scheduler:call(function()
		service.setData(player, { "CombatStats", "Strength" }, 9)
		service.setData(player, { "Inventory", 1 }, { Id = "Sword" })
		service._onPlayerRemoving(player)
	end)
	leaveAndSettle(world, player)
end)

compareVersions("Critterhaven", "the same play session stores the same data", CRITTER, function(game)
	local world, service = game.world, game.service
	world.scheduler:call(function()
		service.main()
	end)
	local player = world:player(6004)
	world.players.PlayerAdded:Fire(player)
	world.scheduler:runUntil(function()
		return service.GetSnapshot(player) ~= nil
	end, 30)
	service.Update(player, function(data)
		data.CompatProbe = 5
	end)
	leaveAndSettle(world, player)
end)

compareVersions("PlusOneTemplate", "the same play session stores the same data", PLUS_ONE, function(game)
	local world, service = game.world, game.service
	world.scheduler:call(function()
		service.main()
	end)
	local player = world:player(6005)
	world.players.PlayerAdded:Fire(player)
	world.scheduler:runUntil(function()
		return service.IsLoaded(player)
	end, 30)
	service.Mutate(player, { "economy" }, function(data)
		data.CompatProbe = 5
	end)
	world.scheduler:call(function()
		service.SaveNow(player, 20)
	end)
	leaveAndSettle(world, player)
end)

suite.run()
