-- Run with Lune 0.11+: lune run tests/consumers.luau
-- How the games built on SoulStore actually use it, copied down to the calls they make, so a change that breaks a game
-- fails here even where the games themselves are not available. tests/games.luau runs the real game code when they are.
--
-- Only AriseShadows is live, so its tests are a hard contract. The others describe how those projects use SoulStore
-- today. When one stands in the way of the better design, change the test and the project, not the design.
local luau = require("@lune/luau")

local harness = require("./harness")

local equal, expect, newWorld = harness.equal, harness.expect, harness.newWorld
local suite = harness.newSuite("consumer contracts")
local test = suite.test

local OUTAGE = "502: API Services rejected request with error. HTTP 500 (Internal Server Error)"

local function failAlways(store)
	store.beforeRead = function()
		error(OUTAGE, 0)
	end
end

-- Loads code copied from a game, so that it runs on the test's virtual clock and tasks
local function gameCode(world, source: string)
	return luau.load(source, { environment = table.clone(world.environment), injectGlobals = true })()
end

local function settle(world, soul)
	world.scheduler:runUntil(function()
		return soul.SessionState == "Ended" or soul.SessionState == "Cancelled"
	end, 40)
end

----------------------------------------------------------------------------------------------------------- AriseShadows

-- PlayerDataService.persistSoul, unchanged
local PERSIST_SOUL = [[
	return function(soul, wanted)
		local deadline = os.clock() + 30
		while soul.SaveState == "Saving" and os.clock() < deadline do
			task.wait(0.1)
		end
		if soul.SaveState ~= "Idle" then
			return false
		end
		local marker = "job:" .. tostring(wanted)
		local before = soul.Data.MetaData.SaveId
		soul.Data.MetaData.PurchaseCommit = marker
		local ok = pcall(soul.SaveData, soul, false)
		local durable = ok and soul.Data.MetaData.PurchaseCommit == marker and soul.Data.MetaData.SaveId > before
		return durable
	end
]]

test("AriseShadows: the purchase check reads true on a save and false on a failure", function()
	local world = newWorld()
	local soul = world:active("PlayerData", world:player(1), { Coins = 0 })
	local persistSoul = gameCode(world, PERSIST_SOUL)
	local check = function(wanted)
		return world.scheduler:call(function()
			return persistSoul(soul, wanted)
		end)
	end
	equal(check(1), true)
	equal(world.stores.PlayerData.data["1"].MetaData.PurchaseCommit, "job:1")
	failAlways(world.stores.PlayerData)
	equal(check(2), false, "A failed write must not read as durable")
end)

test("AriseShadows: migrations change the live table GetData returns", function()
	local world = newWorld()
	local player = world:player(2)
	local soul = world:active("PlayerData", player, { rank = "E" })
	local live = soul:GetData()
	live.rank = "S"
	live.rankLadderVersion = 3
	equal(soul:GetData({ "rank" }), "S")
	world.scheduler:call(function()
		soul:SaveData(true)
	end)
	equal(world.stores.PlayerData.data["2"].rankLadderVersion, 3)
end)

test("AriseShadows: an onboarding reset can clear the save and keep its MetaData", function()
	local world = newWorld()
	local player = world:player(3)
	local soul = world:active("PlayerData", player, { Coins = 5, stage = 9 })
	-- OnboardingReset.apply: wipes every field, then puts MetaData back
	local data = soul:GetData()
	local meta = data.MetaData
	table.clear(data)
	data.stage = 0
	data.MetaData = meta
	world.scheduler:call(function()
		soul:SaveData()
	end)
	local stored = world.stores.PlayerData.data["3"]
	equal(stored.stage, 0)
	equal(stored.Coins, nil)
	equal(stored.MetaData.SessionId, soul.SessionToken)
end)

test("AriseShadows: a leave handler commits what the save hook has not folded in yet", function()
	local world = newWorld()
	local player = world:player(4)
	local soul = world:active("PlayerData", player, { xp = 0 })
	local pending = { [player] = 25 }
	local ready = { [player] = true }
	soul:SetOnSave(function(data)
		-- ShadowService: Roster.snapshot folds pending XP into the copy
		if ready[player] then
			data.xp += pending[player]
		end
		expect(soul:GetData() ~= nil, "The hook can still read the session")
	end)
	world.players.PlayerRemoving:Connect(function(leaving)
		-- ShadowService: Roster.commitAll writes it for real, and only then forgets it
		expect(soul:SetData({ "xp" }, soul:GetData({ "xp" }) + pending[leaving]) ~= nil, "The session still accepts it")
		pending[leaving], ready[leaving] = nil, nil
	end)
	world:remove(player)
	settle(world, soul)
	equal(world.stores.PlayerData.data["4"].xp, 25)
end)

test("AriseShadows: state a leave handler clears later is still there for the final save hook", function()
	local world = newWorld()
	local player = world:player(10)
	local soul = world:active("PlayerData", player, { offline = {} })
	local loaded = { [player] = true }
	soul:SetOnSave(function(data)
		-- OfflineIncomeService stamps the leaving save
		if loaded[player] then
			data.offline.lastSeen = 123
		end
	end)
	world.players.PlayerRemoving:Connect(function(leaving)
		world.scheduler.task.delay(60, function()
			loaded[leaving] = nil
		end)
	end)
	world:remove(player)
	settle(world, soul)
	equal(world.stores.PlayerData.data["10"].offline.lastSeen, 123)
end)

test("AriseShadows: a final snapshot a leave handler takes is what the hook saves", function()
	local world = newWorld()
	local player = world:player(11)
	local soul = world:active("PlayerData", player, { analytics = {} })
	local session, finalSnapshot = { Active = true, Value = 1 }, nil
	soul:SetOnSave(function(data)
		-- ProgressionAnalyticsService: works whichever of the two runs first
		data.analytics = if session.Active then { Value = session.Value } else finalSnapshot
	end)
	world.players.PlayerRemoving:Connect(function()
		finalSnapshot = { Value = session.Value }
		session.Active = false
	end)
	world:remove(player)
	settle(world, soul)
	equal(world.stores.PlayerData.data["11"].analytics.Value, 1)
end)

test("AriseShadows: LoadData ends when the player leaves, and LoadState says so", function()
	local world = newWorld()
	local player = world:player(5)
	local store = world.dataStoreService:GetDataStore("PlayerData")
	store.data["5"] = { MetaData = { Locked = true, SessionId = "other", SaveId = 1, LastUpdate = 1700000000 } }
	local soul = assert(world.soulStore.new("PlayerData", nil, player, { Coins = 0 }))
	local done = false
	world.scheduler:spawn(function()
		soul:LoadData()
		done = true
	end)
	world:remove(player)
	world.scheduler:runUntil(function()
		return done
	end, 10)
	expect(soul.LoadState ~= "Loaded")
end)

test("AriseShadows: a player leaving as the load finishes can still end the session", function()
	local world = newWorld()
	local player = world:player(6)
	local soul = world:active("PlayerData", player, { Coins = 0 })
	player.Parent = nil -- gone, with SoulStore's own handler not having seen it yet
	if player.Parent ~= world.players then
		world.scheduler:call(function()
			soul:SaveData(true)
		end)
	end
	equal(soul.EndReason, "Saved")
	equal(world.stores.PlayerData.data["6"].MetaData.Locked, false)
end)

test("AriseShadows: both leave handlers ending the session write once", function()
	local world = newWorld()
	local player = world:player(7)
	local soul = world:active("PlayerData", player, { Coins = 0 })
	local store = world.stores.PlayerData
	local before = #store.writes
	store.beforeRead = function()
		world.scheduler.task.wait(1)
	end
	world:remove(player)
	world.scheduler:spawn(function()
		soul:SaveData(true) -- PlayerDataService._onPlayerRemoving, after SoulStore's own handler
	end)
	settle(world, soul)
	equal(#store.writes, before + 1)
end)

test("AriseShadows: a Studio test resets the save before each join", function()
	local world = newWorld()
	local player = world:player(8)
	local store = world.dataStoreService:GetDataStore("PlayerData_QA")
	store.data["8"] = { Coins = 999 }
	equal(world.soulStore.resetData("PlayerData_QA", nil, tostring(player.UserId)), true)
	local soul = world:active("PlayerData_QA", player, { Coins = 0 })
	equal(soul.Data.Coins, 0)
end)

test("AriseShadows: a plot listens to one nested value", function()
	local world = newWorld()
	local soul = world:active("PlayerData", world:player(9), { base = { level = 1 } })
	local seenOld, seenNew
	local connection = soul:OnDataChanged({ "base", "level" }, function(old, new)
		seenOld, seenNew = old, new
	end)
	soul:SetData({ "base", "level" }, 2)
	equal(seenOld, 1)
	equal(seenNew, 2)
	connection:Disconnect()
	soul:SetData({ "base", "level" }, 3)
	equal(seenNew, 2)
end)

------------------------------------------------------------------------------------------------------- WalkToHatchGolems

test("WalkToHatchGolems: an empty path returns the whole live table", function()
	local world = newWorld()
	local soul = world:active("PlayerData", world:player(20), { Coins = 1 })
	equal(soul:GetData({}), soul.Data)
end)

test("WalkToHatchGolems: setting a path to nil removes it, however deep", function()
	local world = newWorld()
	local soul = world:active("PlayerData", world:player(21), {
		Settings = { Retired = 1 },
		Golems = { ["uuid-a"] = { FuseProgress = 2, Level = 1 } },
		Old = true,
	})
	expect(soul:SetData({ "Settings", "Retired" }, nil) == nil)
	soul:SetData({ "Golems", "uuid-a", "FuseProgress" }, nil)
	soul:SetData({ "Old" }, nil)
	equal(soul.Data.Settings.Retired, nil)
	equal(soul.Data.Golems["uuid-a"].FuseProgress, nil)
	equal(soul.Data.Golems["uuid-a"].Level, 1)
	equal(soul.Data.Old, nil)
end)

test("WalkToHatchGolems: a path can hold a number, for an array of eggs", function()
	local world = newWorld()
	local soul = world:active("PlayerData", world:player(22), { IncubatedEggs = { { EggId = "Old" } } })
	soul:SetData({ "IncubatedEggs", 1, "EggId" }, "New")
	equal(soul.Data.IncubatedEggs[1].EggId, "New")
end)

test("WalkToHatchGolems: a combat cache a listener keeps pointing at the new copy stays current", function()
	local world = newWorld()
	local soul = world:active("PlayerData", world:player(23), { FighterGolems = { a = { Level = 1 } } })
	local cached, oldSnapshot
	soul:OnDataChanged({ "FighterGolems" }, function(old, new)
		oldSnapshot, cached = old, new -- GolemSystem:541 points its cache at the new table
	end)
	soul:SetData({ "FighterGolems", "a" }, { Level = 2 })
	equal(cached.a.Level, 2)
	equal(oldSnapshot.a.Level, 1)
	soul:SetData({ "FighterGolems", "a", "Level" }, 3)
	equal(cached.a.Level, 3, "Every SetData below the path fires it again")
end)

test("WalkToHatchGolems: a huge number already in a save loads, saves and can be repaired", function()
	local world = newWorld()
	local store = world.dataStoreService:GetDataStore("PlayerData")
	store.data["24"] = { Golems = { a = { Experience = 1e85, Level = 1200 } } }
	local soul = world:active("PlayerData", world:player(24))
	equal(soul:GetData({ "Golems", "a", "Experience" }), 1e85)
	world.scheduler:call(function()
		soul:SaveData()
	end)
	equal(store.data["24"].Golems.a.Experience, 1e85, "A big number is not a bad number")
	expect(soul:SetData({ "Golems", "a", "Experience" }, 0) ~= nil)
end)

test("WalkToHatchGolems: Reconcile with a deep copied schema never shares tables between players", function()
	local world = newWorld()
	local schema = { Settings = { Music = 1 }, Golems = {} }
	local first = world:active("PlayerData", world:player(25), {})
	local second = world:active("PlayerData", world:player(26), {})
	first:Reconcile(world.soulStore.deepCopy(schema))
	second:Reconcile(world.soulStore.deepCopy(schema))
	first:SetData({ "Settings", "Music" }, 0)
	equal(second.Data.Settings.Music, 1)
	equal(schema.Settings.Music, 1)
end)

---------------------------------------------------------------------------------------------------------------- TierBound

test("TierBound: Reconcile with the schema itself does not hand out the schema's tables", function()
	local world = newWorld()
	local schema = { CombatStats = { Strength = 0 }, Inventory = {} }
	local soul = world:active("PlayerData", world:player(30), {})
	soul:Reconcile(schema)
	soul:SetData({ "CombatStats", "Strength" }, 9)
	equal(schema.CombatStats.Strength, 0)
end)

test("TierBound: never checking LoadData cannot put defaults over a real save", function()
	local world = newWorld()
	local player = world:player(31)
	local store = world.dataStoreService:GetDataStore("PlayerData")
	store.data["31"] = "not a save"
	local schema = { Silver = 100 }
	local soul = assert(world.soulStore.new("PlayerData", nil, player, schema))
	world.scheduler:call(function()
		soul:LoadData()
		soul:Reconcile(schema) -- straight after, whatever LoadData said
	end)
	equal(soul:GetData({ "Silver" }), nil)
	equal(soul:SetData({ "Silver" }, 5), nil)
	world.scheduler:call(function()
		soul:SaveData(true)
	end)
	equal(store.data["31"], "not a save")
end)

------------------------------------------------------------------------------------------------------------ Critterhaven

test("Critterhaven: the root table it keeps sees every SetData of its one big key", function()
	local world = newWorld()
	local soul = world:active("PlayerData", world:player(40), { Data = { Coins = 1 } })
	local data = soul:GetData() -- session.data
	expect(soul:SetData({ "Data" }, { Coins = 2 }) ~= nil)
	equal(data.Data.Coins, 2)
	world.scheduler:call(function()
		soul:SaveData()
	end)
	equal(world.stores.PlayerData.data["40"].Data.Coins, 2)
end)

test("Critterhaven: Reconcile with starter entries leaves a town's own buildings and land alone", function()
	local world = newWorld()
	local store = world.dataStoreService:GetDataStore("PlayerData")
	store.data["42"] = {
		SchemaVersion = 7,
		Data = {
			landSections = { { x = 5, z = 5 } },
			buildings = { { id = "b1", typeId = "cottage", x = 10, z = 10 } },
		},
	}
	local soul = world:active("PlayerData", world:player(42))
	-- Schema.create() has a starter town hall and a starter land section in these arrays
	soul:Reconcile({
		SchemaVersion = 7,
		Data = {
			plotTier = 1,
			landSections = { { x = 2, z = 2 } },
			buildings = { { id = "starter_town_hall", typeId = "town_hall", level = 1, x = 75, z = 75, rotation = 0 } },
		},
	})
	local data = soul:GetData({ "Data" })
	equal(data.plotTier, 1, "A new field still arrives")
	equal(#data.buildings, 1)
	equal(data.buildings[1].typeId, "cottage")
	equal(data.buildings[1].level, nil, "A cottage does not pick up the town hall's fields")
	equal(data.buildings[1].rotation, nil)
	equal(data.landSections[1].x, 5)
end)

test("Critterhaven: a load timeout that kicks the player leaves nothing locked", function()
	local world = newWorld()
	local player = world:player(41)
	local store = world.dataStoreService:GetDataStore("PlayerData")
	failAlways(store)
	local soul = assert(world.soulStore.new("PlayerData", nil, player, { Coins = 0 }))
	local done = false
	world.scheduler:spawn(function()
		soul:LoadData()
		done = true
	end)
	world.scheduler:advance(60) -- Profile.LoadTimeoutSeconds
	player:Kick("Your data could not be loaded. Please rejoin.")
	store.beforeRead = nil
	world.scheduler:runUntil(function()
		return done
	end, 40)
	equal(soul.SessionState, "Cancelled")
	expect(soul.LoadState ~= "Loaded")
end)

--------------------------------------------------------------------------------------------------------- PlusOneTemplate

-- PlayerDataService.SaveNow, with its one line changed for 2.0's session tokens
local SAVE_NOW = [[
	return function(soul, timeoutSeconds)
		local deadline = os.clock() + (timeoutSeconds or 20)
		while soul.SaveState == "Saving" and os.clock() < deadline do
			task.wait(0.1)
		end
		if soul.SaveState ~= "Idle" then
			return false
		end
		local saveIdBefore = soul.Data.MetaData.SaveId
		local finished = false
		task.spawn(function()
			soul:SaveData(false)
			finished = true
		end)
		while not finished and os.clock() < deadline do
			task.wait(0.1)
		end
		local meta = soul.Data.MetaData
		return finished and meta.SaveId > saveIdBefore and meta.SessionId == soul.SessionToken
	end
]]

test("PlusOneTemplate: SaveNow confirms a save and reports a failure", function()
	local world = newWorld()
	local run = gameCode(world, SAVE_NOW)
	local soul = world:active("Profiles", world:player(50), { Coins = 0 })
	equal(
		world.scheduler:call(function()
			return run(soul, 20)
		end),
		true
	)
	failAlways(world.stores.Profiles)
	equal(
		world.scheduler:call(function()
			return run(soul, 20)
		end),
		false
	)
end)

test("PlusOneTemplate: SaveNow waits out an autosave already running", function()
	local world = newWorld()
	local run = gameCode(world, SAVE_NOW)
	local soul = world:active("Profiles", world:player(51), { Coins = 0 })
	local store = world.stores.Profiles
	store.beforeCommit = function(_key, callId)
		if callId == 2 then
			world.scheduler.task.wait(3)
		end
	end
	world.scheduler:spawn(function()
		soul:SaveData()
	end)
	equal(soul.SaveState, "Saving")
	soul.Data.Coins = 100
	equal(
		world.scheduler:call(function()
			return run(soul, 20)
		end),
		true
	)
	equal(store.data["51"].Coins, 100)
	equal(soul.SaveState, "Idle")
end)

test("PlusOneTemplate: hooks normalize the load and stamp the save copy", function()
	local world = newWorld()
	local player = world:player(52)
	local soul = assert(world.soulStore.new("Profiles", nil, player, { meta = {}, stats = {} }))
	soul:SetOnLoad(function(data)
		data.stats.normalized = true
	end)
	soul:SetOnSave(function(snapshot)
		snapshot.meta.lastSaveAt = 123
	end)
	world.scheduler:call(function()
		soul:LoadData()
	end)
	equal(soul.Data.stats.normalized, true)
	equal(world.stores.Profiles.data["52"].stats.normalized, nil, "OnLoad's change is not saved until a save")
	world.scheduler:call(function()
		soul:SaveData()
	end)
	local stored = world.stores.Profiles.data["52"]
	equal(stored.meta.lastSaveAt, 123)
	equal(stored.stats.normalized, true)
	equal(soul.Data.meta.lastSaveAt, nil, "The hook only touched the copy")
end)

test("PlusOneTemplate: direct edits to soul.Data are saved", function()
	local world = newWorld()
	local player = world:player(53)
	local soul = world:active("Profiles", player, { stats = { totalOnlineSeconds = 0 } })
	local data = soul.Data
	data.stats.totalOnlineSeconds += 10 -- the online-time loop
	world.scheduler:advance(35)
	equal(world.stores.Profiles.data["53"].stats.totalOnlineSeconds, 10, "An autosave carries them")
	data.stats.totalOnlineSeconds += 10
	world:remove(player)
	settle(world, soul)
	equal(world.stores.Profiles.data["53"].stats.totalOnlineSeconds, 20, "So does the final save")
end)

test("PlusOneTemplate: a dev reset replaces each key in place and keeps MetaData", function()
	local world = newWorld()
	local player = world:player(54)
	local soul = world:active("Profiles", player, { Coins = 5, Nested = { Value = 1 } })
	local defaults = { Coins = 0, Nested = { Value = 0 } }
	for key, value in pairs(defaults) do
		soul.Data[key] = world.soulStore.deepCopy(value)
	end
	world.scheduler:call(function()
		soul:SaveData()
	end)
	local stored = world.stores.Profiles.data["54"]
	equal(stored.Coins, 0)
	equal(stored.Nested.Value, 0)
	equal(stored.MetaData.SessionId, soul.SessionToken)
end)

suite.run()
