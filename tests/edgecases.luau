-- Run with Lune 0.11+: lune run tests/edgecases.luau
-- Known ways Roblox data stores go wrong, from Roblox's documentation, ProfileStore, DataStore2, Lapis and the
-- developer forum. docs/guides/edge-cases.md lists each case with its source. See tests/harness.luau for what is
-- simulated.
local harness = require("./harness")

local copy, equal, expect = harness.copy, harness.equal, harness.expect
local newCluster, newWorld = harness.newCluster, harness.newWorld
local suite = harness.newSuite("data store edge cases")
local test = suite.test

local BASE_TIME = 1700000000

local function load(world, soul)
	local state = { done = false }
	world.scheduler:spawn(function()
		state.loaded, state.reason = soul:LoadData()
		state.done = true
	end)
	return state
end

local function save(world, soul, ending)
	return world.scheduler:call(function()
		return soul:SaveData(ending)
	end)
end

local function failNext(store, count, message)
	local remaining = count
	store.beforeRead = function()
		if remaining > 0 then
			remaining -= 1
			error(message, 0)
		end
	end
end

----------------------------------------------------------------------------------------- What UpdateAsync can do to you

test("a transform re-run on newer data throws away the earlier run's decision", function()
	local world = newWorld()
	local player = world:player(1)
	local store = world.dataStoreService:GetDataStore("Profiles")
	store.replays = 2
	store.afterTransform = function(key, callId, replay)
		if callId == 1 and replay == 1 then
			store.data[key] = {
				Coins = 7,
				MetaData = { Locked = true, SessionId = "other", SaveId = 3, LastUpdate = BASE_TIME },
			}
		end
	end
	local soul = assert(world.soulStore.new("Profiles", nil, player, { Coins = 0 }))
	load(world, soul)
	world.scheduler:advance(1)
	equal(soul.SessionState, "Pulling", "The first run's claim must not count")
	equal(#store.writes, 0)
	equal(store.data["1"].MetaData.SessionId, "other")
end)

test("a save re-run after a takeover reports the takeover, not success", function()
	local world = newWorld()
	local player = world:player(2)
	local soul = world:active("Profiles", player)
	local store = world.stores.Profiles
	store.replays = 2
	store.afterTransform = function(key, _callId, replay)
		if replay == 1 then
			store.data[key].MetaData.SessionId = "other"
		end
	end
	local saved, reason = save(world, soul)
	equal(saved, false)
	equal(reason, "OwnershipLost")
	equal(soul.EndReason, "OwnershipLost")
	equal(store.data["2"].MetaData.SessionId, "other")
end)

test("a save whose request returns nothing failed; the session has not lost its record", function()
	local world = newWorld()
	local player = world:player(3)
	local soul = world:active("Profiles", player)
	local store = world.stores.Profiles
	local real = store.UpdateAsync
	store.UpdateAsync = function()
		return nil, nil
	end
	local saved, reason = save(world, soul)
	equal(saved, false)
	equal(reason, "SaveFailed")
	equal(soul.SessionState, "Active")
	store.UpdateAsync = real
	equal(save(world, soul), true)
end)

test("a load whose request returns nothing waits before trying again", function()
	local world = newWorld()
	local player = world:player(4)
	local store = world.dataStoreService:GetDataStore("Profiles")
	local real = store.UpdateAsync
	local empty = 0
	store.UpdateAsync = function(self, key, transform)
		if empty < 2 then
			empty += 1
			world.scheduler.task.wait(0.01)
			return nil, nil
		end
		return real(self, key, transform)
	end
	local soul = assert(world.soulStore.new("Profiles", nil, player, { Coins = 9 }))
	local state = load(world, soul)
	world.scheduler:runUntil(function()
		return state.done
	end, 60)
	equal(state.loaded, true)
	expect(world.scheduler.now >= 4, "Two empty answers must not be retried back to back")
end)

test("a final save whose request returns nothing retries instead of ending the session", function()
	local world = newWorld()
	local player = world:player(5)
	local soul = world:active("Profiles", player, { Coins = 1 })
	soul:SetData({ "Coins" }, 2)
	local store = world.stores.Profiles
	local real = store.UpdateAsync
	local empty = 0
	store.UpdateAsync = function(self, key, transform)
		if empty < 1 then
			empty += 1
			return nil, nil
		end
		return real(self, key, transform)
	end
	equal(save(world, soul, true), true)
	equal(soul.EndReason, "Saved")
	equal(store.data["5"].Coins, 2)
end)

test("user ids and key metadata survive every kind of write", function()
	local world = newWorld()
	local player = world:player(6)
	local store = world.dataStoreService:GetDataStore("Profiles")
	store.data["6"] = { Coins = 1, MetaData = { Locked = false, SessionId = "", SaveId = 1, LastUpdate = BASE_TIME } }
	store.userIds["6"] = { 6, 777 }
	store.metadata["6"] = { Tag = "vip" }
	local soul = assert(world.soulStore.new("Profiles", nil, player, { Coins = 0 }))
	world.scheduler:call(function()
		return soul:LoadData()
	end)
	local function check(step)
		equal(store.userIds["6"][1], 6, step)
		equal(store.userIds["6"][2], 777, step)
		equal(#store.userIds["6"], 2, step)
		equal(store.metadata["6"].Tag, "vip", step)
	end
	check("load")
	save(world, soul)
	check("save")
	save(world, soul, true)
	check("final save")

	-- The release after a hook failure takes a different path
	local again = assert(world.soulStore.new("Profiles", nil, player, { Coins = 0 }))
	again:SetOnLoad(function()
		error("bad migration")
	end)
	local loaded = world.scheduler:call(function()
		return again:LoadData()
	end)
	equal(loaded, false)
	check("release")
	equal(store.data["6"].MetaData.Locked, false)
end)

test("a new record is tagged with the player's user id, for right-to-erasure requests", function()
	local world = newWorld()
	local player = world:player(7)
	world:active("Profiles", player)
	equal(world.stores.Profiles.userIds["7"][1], 7)
end)

test("negative Studio test ids are never sent to Roblox as user ids", function()
	local world = newWorld()
	local player = world:player(-1)
	local soul = world:active("Profiles", player, { Coins = 1 })
	equal(next(world.stores.Profiles.userIds["-1"]), nil)
	equal(save(world, soul), true)
	equal(save(world, soul, true), true)
end)

test("a key that already has the most user ids Roblox allows can still be saved", function()
	local world = newWorld()
	local player = world:player(8)
	local store = world.dataStoreService:GetDataStore("Profiles")
	store.data["8"] = { Coins = 1 }
	store.userIds["8"] = { 101, 102, 103, 104 }
	local soul = assert(world.soulStore.new("Profiles", nil, player, { Coins = 0 }))
	local loaded = world.scheduler:call(function()
		return soul:LoadData()
	end)
	equal(loaded, true)
	equal(save(world, soul), true)
	equal(#store.userIds["8"], 4)
end)

test("SoulStore never reads through GetAsync, whose cache can be four seconds stale", function()
	local world = newWorld()
	local player = world:player(9)
	local store = world.dataStoreService:GetDataStore("Profiles")
	store.GetAsync = function()
		error("GetAsync would serve stale data", 0)
	end
	local soul = world:active("Profiles", player)
	save(world, soul)
	save(world, soul, true)
	equal(soul.EndReason, "Saved")
end)

----------------------------------------------------------------------------------------- What a data store can hold

test("buffers can be stored, and come back whole", function()
	local world = newWorld()
	local player = world:player(10)
	local soul = world:active("Profiles", player)
	local packed = buffer.fromstring("abc")
	expect(soul:SetData({ "Packed" }, packed) ~= nil, "SetData accepts a buffer")
	soul.Data.Direct = buffer.fromstring("def")
	equal(save(world, soul), true)
	local record = world.stores.Profiles.data["10"]
	equal(buffer.tostring(record.Packed), "abc")
	equal(buffer.tostring(record.Direct), "def")
	equal(buffer.tostring(soul:GetData({ "Packed" })), "abc")
	expect(not world:logged("Dropped"), "A buffer must not be dropped")
end)

test("a buffer changed after the final copy cannot change what is written", function()
	local world = newWorld()
	local player = world:player(11)
	local soul = world:active("Profiles", player)
	local packed = buffer.fromstring("abc")
	soul.Data.Packed = packed
	local store = world.stores.Profiles
	store.beforeRead = function()
		world.scheduler.task.wait(1)
	end
	local done = false
	world.scheduler:spawn(function()
		soul:SaveData(true)
		done = true
	end)
	buffer.writeu8(packed, 0, string.byte("z"))
	world.scheduler:runUntil(function()
		return done
	end)
	equal(buffer.tostring(store.data["11"].Packed), "abc")
end)

test("a value a data store cannot hold is left out and everything else still saves", function()
	local bad = {
		func = function() end,
		thread = coroutine.create(function() end),
		instance = { _instance = true },
		vector = { _instance = true, _type = "Vector3" },
		color = { _instance = true, _type = "Color3" },
		badString = "bad\xFF",
	}
	for name, value in pairs(bad) do
		local world = newWorld()
		local player = world:player(12)
		local soul = world:active("Profiles", player, { Coins = 1 })
		soul.Data.Nested = { Keep = 1, Deep = { Keep = 2, Bad = value } }
		soul.Data.Bad = value
		soul:SetData({ "Coins" }, 5)
		equal(save(world, soul), true, name)
		local record = world.stores.Profiles.data["12"]
		equal(record.Coins, 5, name)
		equal(record.Bad, nil, name)
		equal(record.Nested.Keep, 1, name)
		equal(record.Nested.Deep.Keep, 2, name)
		equal(record.Nested.Deep.Bad, nil, name)
		expect(world:logged("Nested.Deep.Bad"), name .. " is reported with its path")
		expect(soul.Data.Nested.Deep.Bad ~= nil, "Live data is untouched")
		equal(soul:SetData({ "New" }, value), nil, name .. " is refused by SetData")
	end
end)

test("infinity is a value like any other", function()
	local world = newWorld()
	local player = world:player(120)
	local soul = world:active("Profiles", player, { Coins = 1 })
	expect(soul:SetData({ "Max" }, math.huge) ~= nil, "SetData accepts it")
	soul.Data.Nested = { Min = -math.huge }
	equal(save(world, soul, true), true)
	expect(not world:logged("Max"), "Nothing is reported")

	local again = world:active("Profiles", player)
	equal(again.Data.Max, math.huge, "It comes back")
	equal(again.Data.Nested.Min, -math.huge)
end)

test("a number key at the top of a save cannot wipe out its named fields", function()
	local world = newWorld()
	local player = world:player(30)
	local soul = world:active("Profiles", player, { Coins = 50, Inventory = { Sword = 1 } })
	local store = world.stores.Profiles

	equal(soul:SetData({ 1 }, "oops"), nil, "SetData refuses it")
	equal(store.data["30"].Coins, 50)

	-- The live table has no such check, so the save has to cope with whatever it finds
	soul.Data[1] = "oops"
	equal(save(world, soul), true)
	local record = store.data["30"]
	equal(record.Coins, 50)
	equal(record.Inventory.Sword, 1)
	equal(record.MetaData.SessionId, soul.SessionToken)
	equal(record["1"], "oops", "Nothing is lost, even this")
	expect(world:logged("the whole save"), "It is reported")

	-- It must not stop the game writing to the rest of the save
	equal(soul:SetData({ "Coins" }, 55), 55, "A named field on a table that has a stray number key")
	soul:SetData({ "Coins" }, 50)
	soul.Data.Inventory[1] = "oops too"
	equal(soul:SetData({ "Inventory", "Shield" }, 2), 2, "The same one level down")
	soul.Data.Inventory[1], soul.Data.Inventory.Shield = nil, nil

	-- The same from a hook
	soul.Data[1] = nil
	local hooked = false
	soul:SetOnSave(function(data)
		if not hooked then
			hooked = true
			data[1] = "from a hook"
		end
	end)
	equal(save(world, soul), true)
	equal(store.data["30"].Coins, 50)
	equal(store.data["30"]["1"], "from a hook")

	-- The session is unharmed, the final save lands, and the next one loads it
	equal(soul.SessionState, "Active")
	world.scheduler:advance(61)
	equal(soul.SessionState, "Active", "Autosaves still find the session's token")
	soul:SetData({ "Coins" }, 60)
	equal(save(world, soul, true), true)
	equal(store.data["30"].MetaData.Locked, false)
	local again = world:active("Profiles", world:player(30), { Coins = 0 })
	equal(again:GetData({ "Coins" }), 60)
end)

test("no table loses a value when it is saved, whatever its shape", function()
	local function allValues(value, found)
		found = found or {}
		for _, child in pairs(value) do
			if typeof(child) == "table" then
				allValues(child, found)
			else
				found[child] = true
			end
		end
		return found
	end

	local mixedArray = { "a1", "a2", "a3" }
	mixedArray.Name = "a4"
	local namedThenNumbered = { Sword = "b1", Shield = "b2" }
	namedThenNumbered[1] = "b3"
	local grownWithGap = {}
	for index = 1, 5 do
		grownWithGap[index] = "c" .. index
	end
	grownWithGap[4] = nil
	local rebuiltWithGap = {}
	for key, value in pairs(grownWithGap) do
		rebuiltWithGap[key] = "d" .. key
		local _ = value
	end
	local firstGone = { "e1", "e2", "e3" }
	firstGone[1] = nil
	firstGone.Name = "e4"
	local shapes = {
		mixedArray = mixedArray,
		namedThenNumbered = namedThenNumbered,
		grownWithGap = grownWithGap,
		rebuiltWithGap = rebuiltWithGap,
		firstGone = firstGone,
		cutShort = { [1] = "f1", [3] = "f3" },
		nearlyEmpty = { [1] = "g1", [2000] = "g2" },
		sparse = { [5] = "h1", [90] = "h2" },
		fractions = { [1.1] = "i1", [1.9] = "i2" },
		fractionsAndNames = { [1.5] = "j1", Name = "j2" },
		zero = { [0] = "k1", [1] = "k2" },
		zeroAndTwo = { [0] = "l1", [2] = "l2" },
		negative = { [-1] = "m1", [1] = "m2" },
		large = { [123456789012] = "n1", Name = "n2", [1] = "n3" },
	}
	for name, shape in pairs(shapes) do
		local world = newWorld()
		local player = world:player(31)
		local soul = world:active("Profiles", player, { Coins = 1 })
		local wanted = allValues(copy(shape))
		soul.Data.Outer = { Risky = shape }
		equal(save(world, soul), true, name)
		local stored = world.stores.Profiles.data["31"]
		local found = allValues(stored.Outer.Risky)
		for value in pairs(wanted) do
			expect(found[value], name .. " lost " .. tostring(value))
		end
		equal(stored.Coins, 1, name)
		equal(save(world, soul, true), true, name)
		local again = world:active("Profiles", world:player(31), { Coins = 0 })
		found = allValues(again:GetData({ "Outer", "Risky" }))
		for value in pairs(wanted) do
			expect(found[value], name .. " did not load back " .. tostring(value))
		end
		-- And it keeps surviving, as what came back is saved again
		equal(save(world, again, true), true, name)
	end
end)

test("arrays with gaps come back with the same indexes and no warning", function()
	local world = newWorld()
	local player = world:player(32)
	local soul = world:active("Profiles", player, { Slots = {} })
	local grown = {}
	for index = 1, 8 do
		grown[index] = "item" .. index
	end
	grown[4] = nil
	grown[7] = nil
	-- selene: allow(manual_table_clone)
	local rebuilt = {}
	for key, value in pairs(grown) do
		rebuilt[key] = value
	end
	local firstGone = { "a", "b", "c" }
	firstGone[1] = nil
	soul.Data.Grown, soul.Data.Rebuilt, soul.Data.FirstGone = grown, rebuilt, firstGone
	soul.Data.Cut = { [1] = "a", [3] = "c" }
	equal(save(world, soul, true), true)
	expect(not world:logged("will not load back"), "They do load back the same")

	local again = world:active("Profiles", world:player(32))
	for _, name in ipairs({ "Grown", "Rebuilt" }) do
		local loaded = again:GetData({ name })
		for index = 1, 8 do
			equal(loaded[index], if index == 4 or index == 7 then nil else "item" .. index, name .. " " .. index)
		end
	end
	equal(again:GetData({ "FirstGone", 2 }), "b")
	equal(again:GetData({ "FirstGone", 3 }), "c")
	equal(again:GetData({ "Cut", 1 }), "a")
	equal(again:GetData({ "Cut", 3 }), "c")
end)

test("SetData refuses what a data store would change or lose, and allows what it would not", function()
	local world = newWorld()
	local soul = world:active("Profiles", world:player(33), {
		Named = { Sword = 1 },
		List = { "a", "b" },
		Empty = {},
	})
	local gappy = { "a", "b", "c" }
	gappy[2] = nil
	soul.Data.Gappy = gappy

	local refused = {
		{ path = { 1 }, why = "the top of the save" },
		{ path = { "Named", 1 }, why = "a dictionary" },
		{ path = { "Named", 7 }, why = "a dictionary, anywhere" },
		{ path = { "List", "Count" }, why = "a string key on an array" },
		{ path = { "List", 0 }, why = "zero" },
		{ path = { "List", -1 }, why = "a negative key" },
		{ path = { "List", 1.5 }, why = "a fraction" },
		{ path = { "List", 0 / 0 }, why = "NaN" },
		{ path = { "List", math.huge }, why = "infinity" },
		{ path = { "Empty", 5 }, why = "a table this would not make an array" },
		-- selene: allow(mixed_table)
		{ path = { "New" }, value = { "a", Name = "b" }, why = "a mixed value" },
		{ path = { "New" }, value = { [5] = "a" }, why = "a value that is not an array" },
		{ path = { "New" }, value = { [0] = "a", [1] = "b" }, why = "a value with a zero key" },
		{ path = { "New" }, value = { Inner = { [1] = "a", Name = "b" } }, why = "a mix deeper down" },
	}
	for _, case in ipairs(refused) do
		equal(soul:SetData(case.path, case.value or "value"), nil, case.why)
	end
	equal(soul.Data.New, nil)
	equal(next(soul.Data.Empty), nil)
	equal(#soul.Data.List, 2)
	equal(soul.Data.Named[1], nil)
	equal(soul:SetData({ "List", 0 / 0 }, nil), nil, "removing at a NaN key, which Luau would throw for")

	equal(soul:SetData({ "Named", "Shield" }, 2), 2, "a string key on a dictionary")
	equal(soul:SetData({ "List", 3 }, "c"), "c", "continuing an array")
	equal(soul:SetData({ "List", 1 }, "z"), "z", "replacing an entry")
	equal(soul:SetData({ "List", 3 }, nil), nil)
	equal(soul.Data.List[3], nil, "removing the last entry")
	equal(soul:SetData({ "Empty", 1 }, "first"), "first", "starting an array")
	equal(soul:SetData({ "Gappy", 2 }, "filled"), "filled", "filling a gap")
	soul:SetData({ "List", 2 }, nil)
	equal(soul.Data.List[2], nil, "removing from the middle, whose gap survives")
	equal(soul:SetData({ "Whole" }, { "a", "b" }), soul.Data.Whole, "an array")
	equal(soul:SetData({ "Whole2" }, { A = { "a" }, B = {} }), soul.Data.Whole2, "a dictionary of arrays")
	equal(save(world, soul), true)
end)

test("defaults that could not be saved are refused before anyone loads", function()
	local world = newWorld()
	local player = world:player(34)
	local mixed = { "a" }
	mixed.Name = "b"
	for why, defaults in pairs({
		array = { "first", "second" },
		mixedTop = mixed,
		mixedBelow = { Inner = mixed },
		booleanKey = { [true] = 1 },
		aFunction = { Callback = print },
	}) do
		equal(world.soulStore.new("Profiles", nil, player, defaults), nil, why)
	end
	expect(world:logged("must be a dictionary"), "Says why")
	expect(world.soulStore.new("Profiles", nil, player, { List = { "a" }, Named = { A = 1 } }), "These are fine")
end)

test("a record stored as an array is left alone rather than claimed", function()
	local world = newWorld()
	local player = world:player(35)
	world.dataStoreService:GetDataStore("Profiles", nil)
	local store = world.stores.Profiles
	store.data["35"] = { "not", "a", "profile" }
	local soul = assert(world.soulStore.new("Profiles", nil, player, { Coins = 0 }))
	local loaded, reason = world.scheduler:call(function()
		return soul:LoadData()
	end)
	equal(loaded, false)
	equal(reason, "CorruptData")
	equal(#store.data["35"], 3)
	equal(store.data["35"].MetaData, nil)
end)

test("Reconcile leaves an array the save has alone, even if the template now has a dictionary there", function()
	local world = newWorld()
	local soul = world:active("Profiles", world:player(36), { Items = { "a", "b" }, Named = { A = 1 } })
	soul:Reconcile({ Items = { Rarity = "Common" }, Named = { B = 2 }, Added = { C = 3 } })
	equal(soul.Data.Items.Rarity, nil)
	equal(soul.Data.Named.B, 2)
	equal(soul.Data.Added.C, 3)
	equal(save(world, soul), true)
	equal(world.stores.Profiles.data["36"].Items[2], "b", "It stays an array")
	expect(not world:logged("will not load back"), "Nothing to warn about")
end)

test("copies keep an array's length and leave metatables behind", function()
	local world = newWorld()
	local grown = {}
	for index = 1, 5 do
		grown[index] = { Index = index }
	end
	grown[4] = nil
	local copied = world.soulStore.deepCopy({ Grown = grown })
	equal(#copied.Grown, #grown)
	expect(copied.Grown ~= grown and copied.Grown[1] ~= grown[1], "It is a deep copy")
	equal(copied.Grown[5].Index, 5)

	local locked = setmetatable({ A = { B = 1 } }, { __metatable = "locked" })
	local withMetatable = world.soulStore.deepCopy({ Locked = locked })
	equal(getmetatable(withMetatable.Locked), nil)
	equal(withMetatable.Locked.A.B, 1)
	expect(withMetatable.Locked.A ~= locked.A, "It is still a deep copy")
end)

test("NaN is saved and reported, because it comes back as it went in, and SetData refuses it", function()
	local world = newWorld()
	local player = world:player(121)
	local soul = world:active("Profiles", player, { Coins = 1 })
	equal(soul:SetData({ "Coins" }, 0 / 0), nil, "A bug must not replace a good value")
	equal(soul:GetData({ "Coins" }), 1)
	equal(soul:SetData({ "Nested" }, { Value = 0 / 0 }), nil)

	soul.Data.Score = 0 / 0
	equal(save(world, soul), true)
	local record = world.stores.Profiles.data["121"]
	expect(record.Score ~= record.Score, "Removing it could break code that expects the field")
	expect(world:logged("Score"), "It is reported with its path")
	world.config.DEBUG_MODE = false -- so that only warnings are counted
	local warnings = #world.logs
	equal(save(world, soul), true)
	equal(#world.logs, warnings, "Once per session")
end)

test("a boolean key would silently cancel the whole write, so it is removed", function()
	local world = newWorld()
	local player = world:player(122)
	local soul = world:active("Profiles", player, { Coins = 1 })
	soul.Data.Deep = { Nested = { Keep = 1, [true] = "gone" } }
	soul:SetData({ "Coins" }, 5)
	equal(save(world, soul), true)
	local record = world.stores.Profiles.data["122"]
	equal(record.Coins, 5, "Everything else landed")
	equal(record.Deep.Nested.Keep, 1)
	expect(world:logged("Deep.Nested.true"), "It is reported with its path")
end)

test("a transform that fails raises nothing on Roblox, and counts as a failed attempt", function()
	harness.expectTransformFailures()
	local world = newWorld()
	local player = world:player(123)
	local soul = world:active("Profiles", player, { Coins = 1 })
	local store = world.stores.Profiles
	store.transformFailure = "attempt to modify a readonly table"

	local saved, reason = save(world, soul)
	equal(saved, false)
	equal(reason, "SaveFailed", "It has not lost its record")
	equal(soul.SessionState, "Active")

	local done = false
	world.scheduler:spawn(function()
		soul:SaveData(true)
		done = true
	end)
	world.scheduler:advance(10)
	equal(done, false, "A final save keeps trying")
	store.transformFailure = nil
	world.scheduler:runUntil(function()
		return done
	end, 40)
	equal(soul.EndReason, "Saved")
	equal(store.data["123"].MetaData.Locked, false)

	local waiting = assert(world.soulStore.new("Profiles", nil, player, { Coins = 0 }))
	store.transformFailure = "boom"
	local calls = store.calls
	local state = load(world, waiting)
	world.scheduler:advance(20)
	equal(state.done, false, "A load keeps trying")
	expect(store.calls - calls < 6, "And waits between attempts")
	store.transformFailure = nil
	world.scheduler:runUntil(function()
		return state.done
	end, 40)
	equal(state.loaded, true)
end)

test("a table key a data store cannot hold is left out and everything else still saves", function()
	local bad = {
		boolean = true,
		table = {},
		instance = { _instance = true },
		badString = "bad\xFF",
		inf = math.huge,
	}
	for name, key in pairs(bad) do
		local world = newWorld()
		local player = world:player(13)
		local soul = world:active("Profiles", player, { Coins = 1 })
		soul.Data.Nested = { Keep = 1, [key] = "lost" }
		equal(save(world, soul), true, name)
		local record = world.stores.Profiles.data["13"]
		equal(record.Nested.Keep, 1, name)
		local left = 0
		for _ in pairs(record.Nested) do
			left += 1
		end
		equal(left, 1, name .. " is not stored under some other name")
		equal(soul:SetData({ "New" }, { [key] = 1 }), nil, name .. " is refused by SetData")
		equal(soul:SetData({ key }, 1), nil, name .. " is refused as a path")
	end
end)

test("tables that would not load back the same are reported once, with their path", function()
	local mixed = { "kept", "kept" }
	mixed.Name = "named"
	local shapes = {
		mixed = mixed,
		tooSparse = { [1] = "a", [2000] = "b" },
		noFirst = { [5] = "a", [90] = "b" },
		fraction = { [1.5] = "a" },
		zero = { [0] = "a", [1] = "b" },
		zeroAndTwo = { [0] = "a", [2] = "b" }, -- as many keys as its largest, so only the zero gives it away
		negative = { [-1] = "a" },
	}
	for name, shape in pairs(shapes) do
		local world = newWorld()
		local player = world:player(14)
		local soul = world:active("Profiles", player, { Coins = 1 })
		soul.Data.Outer = { Risky = shape }
		equal(save(world, soul), true, name)
		expect(world:logged("Outer.Risky"), name .. " is reported with its path")
		world.config.DEBUG_MODE = false -- so that only warnings are counted
		local warnings = #world.logs
		equal(save(world, soul), true, name)
		equal(#world.logs, warnings, name .. " is reported only once per session")
		equal(world.stores.Profiles.data["14"].Coins, 1, name)
	end
end)

test("arrays and dictionaries a data store round-trips are never reported", function()
	local world = newWorld()
	local player = world:player(15)
	local soul = world:active("Profiles", player)
	soul.Data.Array = { "a", "b", { 1, 2, 3 }, { Name = "x" } }
	soul.Data.Dictionary = { One = 1, ["2"] = 2, Nested = { Array = {} } }
	soul.Data.Empty = {}
	equal(save(world, soul), true)
	expect(not world:logged("Array"), "A proper array is fine")
	expect(not world:logged("Dictionary"), "A proper dictionary is fine")
	local record = world.stores.Profiles.data["15"]
	equal(record.Array[3][3], 3)
	equal(record.Array[4].Name, "x")
	equal(record.Dictionary["2"], 2)
end)

test("reporting a risky table does not change what gets written", function()
	local world = newWorld()
	local player = world:player(16)
	local soul = world:active("Profiles", player)
	soul.Data.Stringified = { [5] = "a" }
	equal(save(world, soul), true)
	equal(world.stores.Profiles.data["16"].Stringified["5"], "a", "Roblox turns these keys into strings")
	equal(soul.Data.Stringified[5], "a", "Live data keeps its number key")
end)

test("a save over the size limit is refused, and the session recovers once it shrinks", function()
	local world = newWorld()
	local player = world:player(17)
	local soul = world:active("Profiles", player, { Coins = 1 })
	soul.Data.Blob = string.rep("x", 5 * 1024 * 1024)
	local saved, reason = save(world, soul)
	equal(saved, false)
	equal(reason, "SaveRejected")
	equal(soul.SessionState, "Active")
	soul.Data.Blob = nil
	equal(save(world, soul), true)
end)

test("a final save over the size limit frees the record with the last good save", function()
	local world = newWorld()
	local player = world:player(18)
	local soul = world:active("Profiles", player, { Coins = 1 })
	soul:SetData({ "Coins" }, 5)
	equal(save(world, soul), true)
	soul.Data.Blob = string.rep("x", 5 * 1024 * 1024)
	local saved, reason = save(world, soul, true)
	equal(saved, false)
	equal(reason, "SaveRejected")
	local record = world.stores.Profiles.data["18"]
	equal(record.Coins, 5)
	equal(record.Blob, nil)
	equal(record.MetaData.Locked, false)
	expect(world.scheduler.now < 10, "Retrying cannot shrink it, so it must not retry")
end)

test("a table that contains itself cannot crash saves or keep the record locked", function()
	local world = newWorld()
	local player = world:player(19)
	local soul = world:active("Profiles", player, { Coins = 1 })
	soul:SetData({ "Coins" }, 5)
	equal(save(world, soul), true)
	soul.Data.Self = soul.Data
	local saved, reason = save(world, soul)
	equal(saved, false)
	equal(reason, "InternalError")
	equal(soul.SessionState, "Active")
	saved, reason = save(world, soul, true)
	equal(saved, false)
	equal(reason, "SaveRejected")
	local record = world.stores.Profiles.data["19"]
	equal(record.Coins, 5)
	equal(record.MetaData.Locked, false)
end)

test("replacing the whole data table with something else fails safely", function()
	local world = newWorld()
	local player = world:player(20)
	local soul = world:active("Profiles", player, { Coins = 1 })
	soul.Data = 5
	local saved = save(world, soul)
	equal(saved, false)
	saved = save(world, soul, true)
	equal(saved, false)
	local record = world.stores.Profiles.data["20"]
	equal(record.Coins, 1)
	equal(record.MetaData.Locked, false)
end)

test("frozen tables can be used as defaults, values and templates", function()
	local world = newWorld()
	local player = world:player(21)
	local defaults = table.freeze({ Coins = 1, Nested = table.freeze({ Value = 2 }) })
	local soul = world:active("Profiles", player, defaults)
	expect(soul:SetData({ "Nested", "Value" }, 3) ~= nil, "A session's data is its own copy")
	soul:Reconcile(table.freeze({ Added = table.freeze({ Value = 4 }) }))
	expect(soul:SetData({ "Added", "Value" }, 5) ~= nil, "Reconcile hands out its own copy")
	equal(defaults.Nested.Value, 2)
	equal(save(world, soul), true)
end)

test("Reconcile only fills what is missing and leaves saved values of any type alone", function()
	local world = newWorld()
	local player = world:player(22)
	local store = world.dataStoreService:GetDataStore("Profiles")
	store.data["22"] = { Off = false, Zero = 0, Wrong = 5, Nested = { Kept = 1 } }
	local soul = world:active("Profiles", player)
	local template = {
		Off = true,
		Zero = 9,
		Wrong = { Table = true },
		Nested = { Kept = 9, Added = 2 },
		Missing = { Value = 3 },
		MetaData = { Locked = false },
	}
	soul:Reconcile(template)
	equal(soul.Data.Off, false)
	equal(soul.Data.Zero, 0)
	equal(soul.Data.Wrong, 5)
	equal(soul.Data.Nested.Kept, 1)
	equal(soul.Data.Nested.Added, 2)
	equal(soul.Data.Missing.Value, 3)
	expect(soul.Data.Missing ~= template.Missing, "A template's table is never shared")
	equal(soul.Data.MetaData.Locked, true)
end)

test("Reconcile leaves a saved array alone, and copies a missing one whole", function()
	local world = newWorld()
	local player = world:player(23)
	local store = world.dataStoreService:GetDataStore("Profiles")
	store.data["23"] = {
		Slots = { 9 },
		Sold = {},
		Buildings = { { Id = "cottage" } },
		Nested = { List = { 7 } },
	}
	local soul = world:active("Profiles", player)
	local template = {
		Slots = { 1, 2, 3 },
		Sold = { "starter" },
		Buildings = { { Id = "hall", Level = 1 } },
		Nested = { List = { 1, 2 }, Name = "added" },
		Missing = { "starter", { Value = 1 } },
	}
	soul:Reconcile(template)

	equal(#soul.Data.Slots, 1, "A shorter array is not padded from the template")
	equal(soul.Data.Slots[1], 9)
	equal(#soul.Data.Sold, 0, "Something the player no longer has does not come back")
	equal(soul.Data.Buildings[1].Id, "cottage")
	equal(soul.Data.Buildings[1].Level, nil, "An entry does not get another entry's fields")
	equal(#soul.Data.Nested.List, 1, "The same at any depth")
	equal(soul.Data.Nested.Name, "added", "String keys beside an array are still filled")
	equal(soul.Data.Missing[1], "starter", "A missing array comes whole")
	equal(soul.Data.Missing[2].Value, 1)
	expect(soul.Data.Missing[2] ~= template.Missing[2], "And is a copy")
end)

test("Reconcile ignores number keys in the template, wherever they are", function()
	local world = newWorld()
	local soul = world:active("Profiles", world:player(24), { Coins = 1 })
	local template = { "top level" }
	template[5] = "sparse"
	template.Added = true
	soul:Reconcile(template)
	equal(soul.Data[1], nil)
	equal(soul.Data[5], nil)
	equal(soul.Data.Added, true)
end)

----------------------------------------------------------------------------------------- Errors, and what retrying fixes

test("errors retrying cannot fix end a load at once, with no writes and no retries", function()
	local messages = {
		"101: Key name can't be empty.",
		"102: Key name exceeds the 50 character limit.",
		"103: Value returned by update function was not allowed.",
		"104: Cannot store Array in data store.",
		"105: Serialized value converted byte size exceeds max size.",
		"401: Data model has no access to the data store.",
		"402: LuaWebService has no access.",
		"403: Cannot write to DataStore from studio if API access is not enabled.",
		"509: Operation not allowed.",
		"511: Metadata attribute size exceeds limit.",
		"512: UserID size exceeds limit.",
		"513: Attribute userId format is invalid.",
	}
	for _, message in ipairs(messages) do
		local world = newWorld()
		local player = world:player(30)
		local store = world.dataStoreService:GetDataStore("Profiles")
		store.beforeRead = function()
			error(message, 0)
		end
		local soul = assert(world.soulStore.new("Profiles", nil, player, { Coins = 0 }))
		local state = load(world, soul)
		world.scheduler:runUntil(function()
			return state.done
		end, 5)
		equal(state.loaded, false, message)
		equal(state.reason, "DataStoreError", message)
		equal(store.calls, 1, message .. " must not be retried")
		equal(#store.writes, 0, message)
	end
end)

test("an unpublished place stops the load instead of retrying forever", function()
	local world = newWorld()
	local player = world:player(31)
	world.dataStoreService.GetDataStore = function()
		error("You must publish this place to the web to access DataStore.", 0)
	end
	local soul = assert(world.soulStore.new("Profiles", nil, player, { Coins = 0 }))
	local state = load(world, soul)
	world.scheduler:runUntil(function()
		return state.done
	end, 5)
	equal(state.loaded, false)
	equal(state.reason, "DataStoreError")
end)

test("HTTP 403 means no access in Studio, but is retried on a live server", function()
	local message = "502: API Services rejected request with error. HTTP 403 (Forbidden)"

	local studio = newWorld()
	local studioStore = studio.dataStoreService:GetDataStore("Profiles")
	failNext(studioStore, 100, message)
	local studioSoul = assert(studio.soulStore.new("Profiles", nil, studio:player(32), { Coins = 0 }))
	local studioState = load(studio, studioSoul)
	studio.scheduler:runUntil(function()
		return studioState.done
	end, 5)
	equal(studioState.loaded, false)

	local live = newWorld({ live = true })
	local liveStore = live.dataStoreService:GetDataStore("Profiles")
	failNext(liveStore, 2, message)
	local liveSoul = assert(live.soulStore.new("Profiles", nil, live:player(32), { Coins = 0 }))
	local liveState = load(live, liveSoul)
	live.scheduler:runUntil(function()
		return liveState.done
	end, 60)
	equal(liveState.loaded, true)
end)

test("errors that pass with time are retried, and defaults never replace real data", function()
	local messages = {
		"301: GetAsync request dropped.",
		"304: UpdateAsync request dropped. Request was throttled, but throttled queue was full.",
		"306: RemoveAsync request dropped.",
		"404: OrderedDataStore not found.",
		"501: Can't parse response, data may be corrupted.",
		"502: API Services rejected request with error. HTTP 500 (Internal Server Error)",
		"503: Request successful, but key not found.",
		"504: Datastore response was not formatted correctly.",
		"InternalServerError: An internal server error occurred.",
		"KeyThrottled: The request rate exceeds the maximum allowed request rate for a single key.",
		"DatastoreThrottled: Too many requests.",
		"StandardWrite ExperienceThrottled",
		"StandardWrite GameServerThrottled",
		"HttpError: ConnectFail",
		"",
	}
	for _, message in ipairs(messages) do
		local world = newWorld()
		local player = world:player(33)
		local store = world.dataStoreService:GetDataStore("Profiles")
		store.data["33"] = { Coins = 77 }
		failNext(store, 2, message)
		local soul = assert(world.soulStore.new("Profiles", nil, player, { Coins = 0 }))
		local state = load(world, soul)
		world.scheduler:runUntil(function()
			return state.done
		end, 60)
		equal(state.loaded, true, message)
		equal(soul.Data.Coins, 77, message)
		equal(#store.writes, 1, message)
	end
end)

test("an error thrown as a table is handled like any other", function()
	local world = newWorld()
	local player = world:player(34)
	local store = world.dataStoreService:GetDataStore("Profiles")
	local remaining = 1
	store.beforeRead = function()
		if remaining > 0 then
			remaining -= 1
			error({ Code = 500 })
		end
	end
	local soul = assert(world.soulStore.new("Profiles", nil, player, { Coins = 0 }))
	local state = load(world, soul)
	world.scheduler:runUntil(function()
		return state.done
	end, 60)
	equal(state.loaded, true)
end)

test("a load that fails for an hour takes nothing and writes nothing until it works", function()
	local world = newWorld()
	local player = world:player(35)
	local store = world.dataStoreService:GetDataStore("Profiles")
	store.data["35"] = { Coins = 77 }
	store.beforeRead = function()
		error("502: API Services rejected request with error. HTTP 500 (Internal Server Error)", 0)
	end
	local soul = assert(world.soulStore.new("Profiles", nil, player, { Coins = 0 }))
	local state = load(world, soul)
	world.scheduler:advance(3600)
	equal(state.done, false, "LoadData waits, because the games wait on it")
	equal(#store.writes, 0)
	equal(soul.SessionState, "Pulling")
	store.beforeRead = nil
	world.scheduler:runUntil(function()
		return state.done
	end, 60)
	equal(state.loaded, true)
	equal(soul.Data.Coins, 77)
end)

test("a stuck load can be given up on, and frees the record if it took it", function()
	local world = newWorld()
	local player = world:player(36)
	local store = world.dataStoreService:GetDataStore("Profiles")
	local remaining = 1
	store.afterCommit = function()
		if remaining > 0 then
			remaining -= 1
			error("502: response lost", 0)
		end
	end
	local soul = assert(world.soulStore.new("Profiles", nil, player, { Coins = 0 }))
	local state = load(world, soul)
	world.scheduler:advance(1)
	equal(soul.SessionState, "Pulling")
	local gaveUp, why = save(world, soul, true)
	equal(gaveUp, false)
	equal(why, "Cancelled")
	world.scheduler:runUntil(function()
		return state.done
	end, 60)
	equal(state.loaded, false)
	equal(soul.SessionState, "Cancelled")
	equal(store.data["36"].MetaData.Locked, false, "The lock its lost response took is released")
end)

test("retries back off, stay capped, and do not line up across players", function()
	local world = newWorld()
	local first = world:active("Profiles", world:player(37))
	local second = world:active("Profiles", world:player(38))
	local store = world.stores.Profiles
	local attempts = { ["37"] = {}, ["38"] = {} }
	store.beforeRead = function(key)
		table.insert(attempts[key], world.scheduler.now)
		error("502: API Services rejected request with error. HTTP 500 (Internal Server Error)", 0)
	end
	world.scheduler:spawn(function()
		first:SaveData(true)
	end)
	world.scheduler:spawn(function()
		second:SaveData(true)
	end)
	world.scheduler:advance(200)
	store.beforeRead = nil

	local firstTimes, secondTimes = attempts["37"], attempts["38"]
	expect(#firstTimes >= 5 and #secondTimes >= 5)
	local firstDelay = firstTimes[2] - firstTimes[1]
	local lastDelay = firstTimes[#firstTimes] - firstTimes[#firstTimes - 1]
	expect(lastDelay > firstDelay, "Delays grow")
	local lineUp = 0
	for index = 2, math.min(#firstTimes, #secondTimes) do
		local delay = firstTimes[index] - firstTimes[index - 1]
		expect(delay <= world.config.MAX_RETRY_INTERVAL * 1.25, "Delays stay capped: " .. delay)
		if firstTimes[index] == secondTimes[index] then
			lineUp += 1
		end
	end
	equal(lineUp, 0, "Players retry at different moments")
end)

---------------------------------------------------------------------------------------------- Several servers, one record

test("a second server waits for the first to release, then sees its latest save", function()
	local servers, stores, scheduler = newCluster(2)
	local soul = servers[1]:active("Profiles", servers[1]:player(40), { Coins = 1 })
	soul:SetData({ "Coins" }, 50)

	local arriving = assert(servers[2].soulStore.new("Profiles", nil, servers[2]:player(40), { Coins = 0 }))
	local state = load(servers[2], arriving)
	scheduler:advance(10)
	equal(state.done, false, "The old server has not released it yet")

	servers[1]:remove(servers[1].players:GetPlayers()[1])
	scheduler:runUntil(function()
		return state.done
	end, 20)
	equal(state.loaded, true)
	equal(arriving.Data.Coins, 50)
	equal(stores.Profiles.data["40"].MetaData.SessionId, arriving.SessionToken)
end)

test("a crashed server's record is taken over once its lock expires", function()
	local servers, stores, scheduler = newCluster(2)
	local soul = servers[1]:active("Profiles", servers[1]:player(41), { Coins = 1 })
	soul:SetData({ "Coins" }, 50)
	scheduler:advance(35) -- an autosave lands
	soul:SetData({ "Coins" }, 60) -- never reaches the store
	servers[1]:crash()

	local arriving = assert(servers[2].soulStore.new("Profiles", nil, servers[2]:player(41), { Coins = 0 }))
	local started = scheduler.now
	local state = load(servers[2], arriving)
	scheduler:runUntil(function()
		return state.done
	end, 160)
	equal(state.loaded, true)
	local waited = scheduler.now - started
	expect(waited >= 85, "It waited long enough to rule out a live owner: " .. waited)
	expect(waited < 130, "It waited no longer than the expiry: " .. waited)
	equal(arriving.Data.Coins, 50, "It sees the last save that landed")
	equal(stores.Profiles.data["41"].MetaData.SessionId, arriving.SessionToken)
end)

test("a healthy owner never loses its record, however long another server waits", function()
	local servers, stores, scheduler = newCluster(2)
	local player = servers[1]:player(42)
	local soul = servers[1]:active("Profiles", player, { Coins = 1 })

	local arriving = assert(servers[2].soulStore.new("Profiles", nil, servers[2]:player(42), { Coins = 0 }))
	local state = load(servers[2], arriving)
	scheduler:advance(1200)
	equal(state.done, false)
	equal(soul.SessionState, "Active")
	equal(stores.Profiles.data["42"].MetaData.SessionId, soul.SessionToken)

	servers[1]:remove(player)
	scheduler:runUntil(function()
		return state.done
	end, 20)
	equal(state.loaded, true)
end)

test("a server that crashes while another waits is taken over after its last write", function()
	local servers, stores, scheduler = newCluster(2)
	local soul = servers[1]:active("Profiles", servers[1]:player(55), { Coins = 1 })

	local arriving = assert(servers[2].soulStore.new("Profiles", nil, servers[2]:player(55), { Coins = 0 }))
	local state = load(servers[2], arriving)
	scheduler:advance(70) -- autosaves land while it watches
	equal(state.done, false)
	expect(#stores.Profiles.writes >= 3, "The owner was writing")
	soul:SetData({ "Coins" }, 2)
	equal(save(servers[1], soul), true)
	servers[1]:crash()

	local crashedAt = scheduler.now
	scheduler:runUntil(function()
		return state.done
	end, 160)
	equal(state.loaded, true)
	expect(scheduler.now - crashedAt < 135, "Watching earlier versions of the lock must not cost extra")
	equal(arriving.Data.Coins, 2)
end)

test("a live owner that writes soon after an outage keeps its record", function()
	local servers, stores, scheduler = newCluster(2)
	local soul = servers[1]:active("Profiles", servers[1]:player(43), { Coins = 1 })

	local arriving = assert(servers[2].soulStore.new("Profiles", nil, servers[2]:player(43), { Coins = 0 }))
	local state = load(servers[2], arriving)
	scheduler:advance(20)

	-- Nobody can reach the store, for longer than the expiry
	servers[1].offline, servers[2].offline = true, true
	scheduler:advance(200)
	servers[1].offline, servers[2].offline = false, false
	scheduler:advance(45)

	equal(state.done, false, "The first answer after an outage proves nothing")
	equal(soul.SessionState, "Active")
	equal(stores.Profiles.data["43"].MetaData.SessionId, soul.SessionToken)
end)

test("what a load saw before an outage does not count towards the delay", function()
	local servers, stores, scheduler = newCluster(2)
	local soul = servers[1]:active("Profiles", servers[1]:player(45), { Coins = 1 })

	local arriving = assert(servers[2].soulStore.new("Profiles", nil, servers[2]:player(45), { Coins = 0 }))
	local state = load(servers[2], arriving)
	scheduler:advance(10)

	servers[1].offline, servers[2].offline = true, true
	scheduler:advance(200)
	local requests = stores.Profiles.calls
	servers[2].offline = false
	scheduler:runUntil(function()
		return stores.Profiles.calls > requests
	end, 60)
	equal(state.done, false, "A failed request says nothing about the lock, so its first look starts the delay")
	equal(stores.Profiles.data["45"].MetaData.SessionId, soul.SessionToken)
end)

test("a load whose server recovers first takes an expired lock after the delay, and the owner finds out", function()
	local servers, stores, scheduler = newCluster(2)
	local soul = servers[1]:active("Profiles", servers[1]:player(44), { Coins = 1 })

	local arriving = assert(servers[2].soulStore.new("Profiles", nil, servers[2]:player(44), { Coins = 0 }))
	local state = load(servers[2], arriving)
	scheduler:advance(10)

	servers[1].offline, servers[2].offline = true, true
	scheduler:advance(100)
	servers[2].offline = false
	scheduler:advance(5)
	equal(state.done, false, "The lock has not expired yet")
	scheduler:runUntil(function()
		return state.done
	end, 60)
	equal(state.loaded, true)

	servers[1].offline = false
	scheduler:runUntil(function()
		return soul.SessionState == "Ended"
	end, 40)
	equal(soul.EndReason, "OwnershipLost")
	equal(stores.Profiles.data["44"].MetaData.SessionId, arriving.SessionToken)
end)

test("an owner cut off from the store loses the record safely when it is taken over", function()
	local servers, stores, scheduler = newCluster(2)
	local soul = servers[1]:active("Profiles", servers[1]:player(44), { Coins = 1 })
	soul:SetData({ "Coins" }, 10)
	scheduler:advance(35)
	soul:SetData({ "Coins" }, 20)
	servers[1].offline = true

	local arriving = assert(servers[2].soulStore.new("Profiles", nil, servers[2]:player(44), { Coins = 0 }))
	local state = load(servers[2], arriving)
	scheduler:runUntil(function()
		return state.done
	end, 120)
	equal(state.loaded, true)
	equal(arriving.Data.Coins, 10)
	arriving:SetData({ "Coins" }, 500)

	servers[1].offline = false
	scheduler:runUntil(function()
		return soul.SessionState == "Ended"
	end, 40)
	equal(soul.EndReason, "OwnershipLost")
	equal(soul.SessionEndBindableEvent.fireCount, 1)
	equal(save(servers[2], arriving), true)
	equal(stores.Profiles.data["44"].Coins, 500, "The old owner wrote nothing")
end)

test("a takeover only happens on the exact lock it watched", function()
	local servers, stores, scheduler = newCluster(2)
	local soul = servers[1]:active("Profiles", servers[1]:player(45), { Coins = 1 })
	servers[1].offline = true

	local arriving = assert(servers[2].soulStore.new("Profiles", nil, servers[2]:player(45), { Coins = 0 }))
	local state = load(servers[2], arriving)
	scheduler:advance(70)
	servers[1].offline = false
	equal(save(servers[1], soul), true) -- lands just before the takeover would have
	scheduler:advance(35)
	equal(state.done, false, "Its write restarts the watch")
	equal(soul.SessionState, "Active")
	equal(stores.Profiles.data["45"].MetaData.SessionId, soul.SessionToken)
end)

test("a teleport that arrives first waits for the leave, and gets every last change", function()
	local servers, _, scheduler = newCluster(2)
	local player = servers[1]:player(46)
	local soul = servers[1]:active("Profiles", player, { Coins = 1 })
	soul:SetData({ "Coins" }, 75)

	-- Roblox can start the destination before the source has seen the player go
	local arriving = assert(servers[2].soulStore.new("Profiles", nil, servers[2]:player(46), { Coins = 0 }))
	local state = load(servers[2], arriving)
	scheduler:advance(3)
	equal(state.done, false)
	servers[1]:remove(player)
	scheduler:runUntil(function()
		return state.done
	end, 20)
	equal(arriving.Data.Coins, 75)
end)

test("a teleport that fails after the release lets the same player load again", function()
	local world = newWorld()
	local player = world:player(47)
	local soul = world:active("Profiles", player, { Coins = 1 })
	soul:SetData({ "Coins" }, 75)
	equal(save(world, soul, true), true)

	local again = assert(world.soulStore.new("Profiles", nil, player, { Coins = 0 }))
	expect(again ~= soul)
	equal(
		world.scheduler:call(function()
			return again:LoadData()
		end),
		true
	)
	equal(again.Data.Coins, 75)
	expect(again.SessionToken ~= soul.SessionToken)
end)

test("deleting a record during a session ends the session and does not bring it back", function()
	local servers, stores, scheduler = newCluster(2)
	local player = servers[1]:player(48)
	local soul = servers[1]:active("Profiles", player, { Coins = 1 })

	-- Another server, a support tool or a right-to-erasure job
	equal(servers[2].soulStore.resetData("Profiles", nil, "48"), true)
	scheduler:advance(35)
	equal(soul.EndReason, "OwnershipLost")
	equal(stores.Profiles.data["48"], nil, "An erased save must stay erased")
end)

test("a support edit that keeps the lock is overwritten by the session, as with any session lock", function()
	local world = newWorld()
	local player = world:player(49)
	local soul = world:active("Profiles", player, { Coins = 1 })
	local store = world.stores.Profiles
	store.data["49"].Coins = 9999
	equal(save(world, soul), true)
	equal(store.data["49"].Coins, 1)
end)

----------------------------------------------------------------------------------------------------------------- Clocks

test("a writer with a slow clock does not make its live lock look expired", function()
	local servers, stores, scheduler = newCluster(2, { clockOffsets = { -400, 0 } })
	local soul = servers[1]:active("Profiles", servers[1]:player(50), { Coins = 1 })

	local arriving = assert(servers[2].soulStore.new("Profiles", nil, servers[2]:player(50), { Coins = 0 }))
	local state = load(servers[2], arriving)
	scheduler:advance(10)
	equal(state.done, false, "Its stored LastUpdate looks 400 seconds old")
	equal(stores.Profiles.data["50"].MetaData.SessionId, soul.SessionToken)
end)

test("a dead lock's age comes from Roblox's timestamp, not its writer's clock", function()
	local servers, _, scheduler = newCluster(2, { clockOffsets = { -400, 0 } })
	servers[1]:active("Profiles", servers[1]:player(55), { Coins = 1 })
	servers[1]:crash()

	local arriving = assert(servers[2].soulStore.new("Profiles", nil, servers[2]:player(55), { Coins = 0 }))
	local began = scheduler.now
	local state = load(servers[2], arriving)
	scheduler:runUntil(function()
		return state.done
	end, 160)
	equal(state.loaded, true)
	local waited = scheduler.now - began
	expect(waited >= 115, "Its LastUpdate looks 400 seconds old, but the lock is new, yet it waited only " .. waited)
end)

test("a reader with a slow clock still takes over a dead lock in the usual time", function()
	local servers, _, scheduler = newCluster(2, { clockOffsets = { 0, -600 } })
	servers[1]:active("Profiles", servers[1]:player(51), { Coins = 1 })
	servers[1]:crash()

	local arriving = assert(servers[2].soulStore.new("Profiles", nil, servers[2]:player(51), { Coins = 0 }))
	local state = load(servers[2], arriving)
	scheduler:runUntil(function()
		return state.done
	end, 160)
	equal(state.loaded, true)
end)

test("a reader with a fast clock can take a live lock after the delay, and the owner finds out", function()
	local servers, stores, scheduler = newCluster(2, { clockOffsets = { 0, 400 } })
	local soul = servers[1]:active("Profiles", servers[1]:player(52), { Coins = 1 })

	local arriving = assert(servers[2].soulStore.new("Profiles", nil, servers[2]:player(52), { Coins = 0 }))
	local state = load(servers[2], arriving)
	scheduler:runUntil(function()
		return state.done
	end, 60)
	equal(state.loaded, true)
	scheduler:runUntil(function()
		return soul.SessionState == "Ended"
	end, 40)
	equal(soul.EndReason, "OwnershipLost", "Its next write is refused, so nothing is overwritten")
	equal(stores.Profiles.data["52"].MetaData.SessionId, arriving.SessionToken)
end)

test("an old lock only waits out the delay, and a recent one waits until it expires", function()
	local function waitFor(lockAge)
		local servers, stores, scheduler = newCluster(2)
		local world = servers[1]
		world:active("Profiles", world:player(53), { Coins = 7 })
		world:crash()
		scheduler:advance(lockAge)
		local arriving = assert(servers[2].soulStore.new("Profiles", nil, servers[2]:player(53), { Coins = 0 }))
		local began = scheduler.now
		local state = load(servers[2], arriving)
		scheduler:runUntil(function()
			return state.done
		end, 200)
		equal(state.loaded, true)
		equal(arriving:GetData({ "Coins" }), 7)
		equal(stores.Profiles.data["53"].MetaData.SessionId, arriving.SessionToken)
		return scheduler.now - began
	end

	local recent = waitFor(5)
	expect(recent >= 110 and recent <= 125, "A recent lock waits until it expires: " .. recent)
	local old = waitFor(400)
	expect(old >= 15 and old <= 25, "An old lock only waits out the delay: " .. old)
end)

test("a server clock that jumps forward does not end its sessions", function()
	local world = newWorld()
	local soul = world:active("Profiles", world:player(53), { Coins = 1 })
	world.clockOffset = 600
	world.scheduler:advance(3)
	equal(soul.SessionState, "Active")
	expect(soul:SetData({ "Coins" }, 2) ~= nil)
end)

test("a server clock that jumps back does not stop autosaves", function()
	local world = newWorld()
	local soul = world:active("Profiles", world:player(54), { Coins = 1 })
	world.clockOffset = -600
	local before = #world.stores.Profiles.writes
	world.scheduler:advance(70)
	expect(#world.stores.Profiles.writes >= before + 2, "Autosaves keep running")
	equal(soul.SessionState, "Active")
end)

--------------------------------------------------------------------------------------------------- Budgets and throttling

test("everyone gets their turn when there is budget for only one autosave a second", function()
	local world = newWorld()
	local souls = {}
	for userId = 1, 100 do
		souls[userId] = world:active("Profiles", world:player(userId), { Coins = 0 })
	end
	local store = world.stores.Profiles
	local before = #store.writes
	world.budget = 0
	world.spendBudget = true
	world.scheduler:spawn(function()
		while true do
			world.budget = 1
			world.scheduler.task.wait(1)
		end
	end)
	world.scheduler:advance(290)

	local perKey = {}
	for index = before + 1, #store.writes do
		local key = store.writes[index].key
		perKey[key] = (perKey[key] or 0) + 1
	end
	for userId = 1, 100 do
		local count = perKey[tostring(userId)] or 0
		expect(count >= 2 and count <= 3, "Player " .. userId .. " saved " .. count .. " times")
	end
	world.scheduler:advance(200)
	for userId = 1, 100 do
		equal(souls[userId].SessionState, "Active", "Nobody's session ends")
	end
end)

test("a backlog of autosaves is spread out, not copied all in one frame", function()
	local world = newWorld()
	for userId = 1, 90 do
		world:active("Profiles", world:player(userId), { Coins = 0 })
	end
	local store = world.stores.Profiles
	world.budget = 0
	world.scheduler:advance(60)
	local before = #store.writes
	world.budget = 1000
	world.scheduler:advance(1)
	local inOneTick = #store.writes - before
	expect(inOneTick > 0 and inOneTick <= 6, "One tick wrote " .. inOneTick .. " of 90")
	world.scheduler:advance(30)
	local keys = {}
	for index = before + 1, #store.writes do
		keys[store.writes[index].key] = true
	end
	local saved = 0
	for _ in pairs(keys) do
		saved += 1
	end
	equal(saved, 90, "It still clears within an interval")
end)

test("autosaves wait when the budget is empty and catch up when it returns", function()
	local world = newWorld()
	local soul = world:active("Profiles", world:player(60), { Coins = 1 })
	local store = world.stores.Profiles
	local before = #store.writes
	world.budget = 0
	world.scheduler:advance(90)
	equal(#store.writes, before)
	equal(world.queuedRequests, 0, "Autosaves must not fill the request queue")
	world.budget = 1000
	world.scheduler:advance(5)
	equal(#store.writes, before + 1)
	equal(soul.SessionState, "Active")
end)

test("only as many autosaves start as the budget allows", function()
	local world = newWorld()
	local souls = {}
	for index = 1, 10 do
		souls[index] = world:active("Profiles", world:player(600 + index), { Coins = 1 })
	end
	local store = world.stores.Profiles
	local before = #store.writes
	world.budget = 3
	world.spendBudget = true
	world.scheduler:advance(35)
	equal(#store.writes, before + 3)
	equal(world.queuedRequests, 0)
end)

test("final saves survive an empty budget and a full request queue", function()
	local world = newWorld()
	local players = {}
	for index = 1, 40 do
		players[index] = world:player(700 + index)
		world:active("Profiles", players[index], { Coins = index })
	end
	world.budget = 0
	for _, player in ipairs(players) do
		world:remove(player)
	end
	world.scheduler:advance(1)
	equal(world.queuedRequests, 30, "The queue fills, and the rest are dropped")
	world.scheduler:advance(10)
	world.budget = 1000
	world.scheduler:advance(60)
	local record = world.stores.Profiles.data
	for index = 1, 40 do
		equal(record[tostring(700 + index)].MetaData.Locked, false, "Everyone is released")
	end
end)

test("a save too big to write every autosave keeps its session and lands its final save", function()
	local world = newWorld()
	local soul = world:active("Profiles", world:player(61), { Coins = 1 })
	soul.Data.Blob = string.rep("x", 3 * 1024 * 1024)
	local store = world.stores.Profiles
	world.scheduler:advance(62)
	equal(soul.SessionState, "Active", "Throttled writes do not end a session")
	soul:SetData({ "Coins" }, 2)
	local saved = save(world, soul, true)
	equal(saved, true)
	equal(store.data["61"].Coins, 2)
	equal(store.data["61"].MetaData.Locked, false)
end)

--------------------------------------------------------------------------------------------------------------- Shutdown

test("shutdown saves everyone even when Players is already empty", function()
	local world = newWorld()
	local player = world:player(70)
	local soul = world:active("Profiles", player, { Coins = 1 })
	soul:SetData({ "Coins" }, 5)
	world.players.members = {}
	world:close()
	equal(soul.EndReason, "Saved")
	equal(world.stores.Profiles.data["70"].Coins, 5)
end)

test("a player leaving during shutdown writes once", function()
	local world = newWorld()
	local player = world:player(71)
	local soul = world:active("Profiles", player, { Coins = 1 })
	local store = world.stores.Profiles
	local before = #store.writes
	store.beforeRead = function()
		world.scheduler.task.wait(1)
	end
	world.scheduler:spawn(function()
		world:close()
	end)
	world:remove(player)
	world.scheduler:runUntil(function()
		return soul.SessionState == "Ended"
	end, 30)
	equal(#store.writes, before + 1)
	equal(store.maxActive, 1)
end)

test("a request that never returns holds shutdown only until Roblox ends the server", function()
	local world = newWorld()
	local soul = world:active("Profiles", world:player(72), { Coins = 1 })
	local store = world.stores.Profiles
	store.beforeRead = function()
		coroutine.yield({ event = true })
	end
	world:close()
	equal(soul.SessionState, "Ending")
	equal(store.data["72"].MetaData.SessionId, soul.SessionToken, "The lock recovers when it expires")
end)

test("many players on a slow store are all saved inside the shutdown window", function()
	local world = newWorld()
	local souls = {}
	for index = 1, 100 do
		souls[index] = world:active("Profiles", world:player(800 + index), { Coins = index })
	end
	local started = world.scheduler.now
	world.stores.Profiles.beforeRead = function()
		world.scheduler.task.wait(3)
	end
	world:close()
	expect(world.scheduler.now - started < 10, "Saves run side by side, not one after another")
	for _, soul in ipairs(souls) do
		equal(soul.EndReason, "Saved")
	end
end)

test("final saves keep retrying quickly during shutdown", function()
	local world = newWorld()
	local players = 40
	for index = 1, players do
		world:active("Profiles", world:player(805 + index), { Coins = 1 })
	end
	local attempts = 0
	world.stores.Profiles.beforeRead = function()
		attempts += 1
		error("503: temporary outage")
	end
	world:close()
	-- 2, 3, 4.5, 6, 6, 6 seconds apart. Were they to keep slowing down, the last ones would miss Roblox's 30 seconds.
	local average = attempts / players
	expect(average >= 6 and average <= 8, "Attempts each inside the window: " .. average)
end)

test("a change arriving after shutdown starts is refused rather than silently lost", function()
	local world = newWorld()
	local soul = world:active("Profiles", world:player(73), { Coins = 1 })
	soul:SetData({ "Coins" }, 5)
	world:close()
	equal(soul:SetData({ "Coins" }, 999), nil)
	equal(world.stores.Profiles.data["73"].Coins, 5)
end)

test("loads running at shutdown stop, and release whatever they took", function()
	local world = newWorld()
	local player = world:player(74)
	local store = world.dataStoreService:GetDataStore("Profiles")
	store.beforeCommit = function()
		world.scheduler.task.wait(1)
	end
	local soul = assert(world.soulStore.new("Profiles", nil, player, { Coins = 0 }))
	local state = load(world, soul)
	world:close()
	world.scheduler:runUntil(function()
		return state.done
	end, 40)
	equal(state.loaded, false)
	equal(soul.SessionState, "Cancelled")
	equal(store.data["74"].MetaData.Locked, false)
end)

------------------------------------------------------------------------------------------------------- Players come and go

test("a player already gone before the session starts gets nothing", function()
	local world = newWorld()
	local player = world:player(80)
	world:remove(player)
	equal(world.soulStore.new("Profiles", nil, player, { Coins = 0 }), nil)
	equal(world.dataStoreService:GetDataStore("Profiles").calls, 0)
end)

test("the leave event still ends the session while Parent is still set", function()
	local world = newWorld()
	local player = world:player(81)
	local soul = world:active("Profiles", player, { Coins = 1 })
	soul:SetData({ "Coins" }, 5)
	-- Under immediate signals, handlers run before Parent is cleared
	world.players.PlayerRemoving:Fire(player)
	world.scheduler:runUntil(function()
		return soul.SessionState == "Ended"
	end, 10)
	equal(world.stores.Profiles.data["81"].Coins, 5)
end)

test("every leave handler runs before the final save, in whatever order they connected", function()
	local world = newWorld()
	local player = world:player(86)
	local soul = world:active("Profiles", player, { Coins = 1 })
	local seen = {}
	soul:SetOnSave(function(data)
		table.insert(seen, data.Newer)
		table.insert(seen, data.Older)
	end)
	local leave = world.players.PlayerRemoving
	leave:Connect(function()
		soul:SetData({ "Newer" }, "n")
	end)
	-- A handler older than SoulStore's, which Roblox runs after it
	local older = leave:Connect(function()
		soul:SetData({ "Older" }, "o")
	end)
	table.remove(leave.connections)
	table.insert(leave.connections, 1, older)

	world:remove(player)
	world.scheduler:runUntil(function()
		return soul.SessionState == "Ended"
	end, 10)
	local record = world.stores.Profiles.data["86"]
	equal(record.Newer, "n")
	equal(record.Older, "o", "A handler that runs after SoulStore's still makes the final save")
	equal(seen[1], "n", "The hook sees both")
	equal(seen[2], "o")
end)

test("the final save hook works once the player has gone from Players", function()
	local world = newWorld()
	local player = world:player(87)
	local soul = world:active("Profiles", player, { Coins = 1 })
	local parent, readable = "unset", false
	soul:SetOnSave(function()
		parent, readable = player.Parent, soul:GetData() ~= nil
	end)
	world:remove(player)
	world.scheduler:runUntil(function()
		return soul.SessionState == "Ended"
	end, 10)
	equal(parent, nil, "Roblox has cleared Parent by the time deferred work runs")
	equal(readable, true)
end)

test("LoadData on a session that has ended answers with why", function()
	local world = newWorld()
	local soul = world:active("Profiles", world:player(82), { Coins = 1 })
	equal(save(world, soul, true), true)
	local loaded, reason = world.scheduler:call(function()
		return soul:LoadData()
	end)
	equal(loaded, false)
	equal(reason, "Saved")
end)

test("the end event's handlers receive the state and reason", function()
	local world = newWorld()
	local soul = world:active("Profiles", world:player(83), { Coins = 1 })
	local state, reason
	soul.SessionEndBindableEvent.Event:Connect(function(...)
		state, reason = ...
	end)
	equal(save(world, soul, true), true)
	equal(state, "Ended")
	equal(reason, "Saved")
	expect(soul.SessionEndBindableEvent.destroyed)
end)

test("a game can kick the player when a session ends during play", function()
	local world = newWorld()
	local player = world:player(84)
	local soul = world:active("Profiles", player, { Coins = 1 })
	soul.SessionEndBindableEvent.Event:Connect(function(_state, why)
		if player.Parent == world.players and why == "OwnershipLost" then
			player:Kick("Your data session ended. Please rejoin.")
		end
	end)
	world.stores.Profiles.data["84"].MetaData.SessionId = "other"
	world.scheduler:advance(35)
	equal(player.KickMessage, "Your data session ended. Please rejoin.")
end)

test("a hook that tries to save or load is refused, and strands nothing", function()
	local world = newWorld()
	local player = world:player(85)
	local soul = world:active("Profiles", player, { Coins = 1 })
	local other = world:active("Inventory", player, { Items = 1 })
	local pending = assert(world.soulStore.new("Stats", nil, player, { Level = 1 }))
	local answers = {}
	local function ask(name, ...)
		answers[name] = table.pack(...)
	end
	soul:SetOnSave(function()
		ask("save", soul:SaveData())
		ask("final", soul:SaveData(true))
		ask("otherSave", other:SaveData())
		ask("otherFinal", other:SaveData(true))
		ask("otherLoad", pending:LoadData())
	end)
	soul:SetData({ "Coins" }, 99)

	equal(save(world, soul), true, "The save that called the hook carries on")
	for name, answer in pairs(answers) do
		equal(answer[1], false, name)
		equal(answer[2], "CalledFromHook", name)
	end
	equal(world.stores.Profiles.data["85"].Coins, 99)
	equal(soul.SessionState, "Active")
	equal(other.SessionState, "Active")
	equal(pending.SessionState, "Pulling")
	expect(world:logged("Cannot be called from inside"), "Says why")

	-- All three still work as usual afterwards
	local loaded = load(world, pending)
	world.scheduler:runUntil(function()
		return loaded.done
	end, 5)
	equal(loaded.loaded, true)
	equal(save(world, other, true), true)
	equal(save(world, soul, true), true, "The final save goes ahead, with the hook refused the same way")
	equal(soul.SessionState, "Ended")
	equal(world.stores.Profiles.data["85"].MetaData.Locked, false)
end)

test("a hook that spawns a thread to save is refused until the hook is over", function()
	local world = newWorld()
	local soul = world:active("Profiles", world:player(86), { Coins = 1 })
	local spawned, deferred = nil, nil
	local once = false
	soul:SetOnSave(function()
		if once then
			return
		end
		once = true
		world.scheduler.task.spawn(function()
			spawned = table.pack(soul:SaveData(true))
		end)
		world.scheduler.task.defer(function()
			deferred = table.pack(soul:SaveData(true))
		end)
	end)
	equal(save(world, soul), true)
	equal(spawned[1], false)
	equal(spawned[2], "CalledFromHook")
	world.scheduler:flushDeferred()
	world.scheduler:runUntil(function()
		return deferred ~= nil
	end, 5)
	equal(deferred[1], true, "After the hook it is an ordinary final save")
	equal(soul.SessionState, "Ended")
end)

test("players who load together do not all autosave in the same second", function()
	local world = newWorld()
	for index = 1, 60 do
		world:active("Profiles", world:player(900 + index), { Coins = 1 })
	end
	local store = world.stores.Profiles
	local before = #store.writes
	world.scheduler:advance(32)
	local perSecond, perTenSeconds, busiest, keys = {}, {}, 0, {}
	for index = before + 1, #store.writes do
		local at = store.writes[index].at
		local second = math.floor(at)
		perSecond[second] = (perSecond[second] or 0) + 1
		busiest = math.max(busiest, perSecond[second])
		local ten = second // 10
		perTenSeconds[ten] = (perTenSeconds[ten] or 0) + 1
		keys[store.writes[index].key] = true
	end
	local saved = 0
	for _ in pairs(keys) do
		saved += 1
	end
	equal(saved, 60, "Everyone saves within one interval")
	expect(busiest <= 4, "Busiest second had " .. busiest .. " of 60")
	for ten = 0, 2 do
		local count = perTenSeconds[ten] or 0
		expect(count >= 10 and count <= 30, "They are spread over the whole interval: " .. ten .. " had " .. count)
	end
end)

test("shutting down with nothing to save returns at once", function()
	local world = newWorld()
	local started = world.scheduler.now
	world:close()
	expect(world.scheduler.now - started < 1)
end)

test("sessions that have ended leave nothing behind on a long running server", function()
	local world = newWorld({ onLog = function() end })
	local souls = setmetatable({}, { __mode = "k" })
	for userId = 1, 300 do
		local player = world:player(userId)
		local soul = world:active("Profiles", player, { Coins = userId, Items = { Sword = { Level = 1 } } })
		souls[soul] = true
		soul:OnDataChanged({ "Coins" }, function() end)
		soul:SetData({ "Coins" }, userId + 1)
		world:remove(player)
		world.scheduler:advance(1)
	end
	equal(#world.sessionCache.getAll(), 0, "The cache is empty")
	-- Lune cannot be told to collect garbage, so this makes enough of it that it has to
	local left = 300
	for _ = 1, 400 do
		local garbage = {}
		for index = 1, 10000 do
			garbage[index] = {}
		end
		left = 0
		for _ in pairs(souls) do
			left += 1
		end
		if left == 0 then
			break
		end
	end
	equal(left, 0, "Ended sessions still in memory")
end)

------------------------------------------------------------------------------------- Purchases, as Roblox documents them

-- The steps at create.roblox.com/docs/cloud-services/data-stores/player-data-purchasing: check, grant, record, save
local function processReceipt(soul, purchaseId, price)
	if not soul:GetData() then
		return "NotProcessedYet"
	end
	if not soul:GetData({ "Receipts", purchaseId }) then
		soul:SetData({ "Coins" }, soul:GetData({ "Coins" }) + price)
		soul:SetData({ "Receipts", purchaseId }, true)
	end
	return if soul:SaveData() then "PurchaseGranted" else "NotProcessedYet"
end

test("a purchase whose save fails is retried without being granted twice", function()
	local world = newWorld()
	local soul = world:active("Profiles", world:player(90), { Coins = 0, Receipts = {} })
	local store = world.stores.Profiles
	failNext(store, 1, "502: API Services rejected request with error. HTTP 500 (Internal Server Error)")
	local decision = world.scheduler:call(function()
		return processReceipt(soul, "receipt-1", 100)
	end)
	equal(decision, "NotProcessedYet")
	decision = world.scheduler:call(function()
		return processReceipt(soul, "receipt-1", 100)
	end)
	equal(decision, "PurchaseGranted")
	equal(store.data["90"].Coins, 100)
end)

test("a purchase whose save landed but whose answer was lost is not granted twice", function()
	local world = newWorld()
	local soul = world:active("Profiles", world:player(91), { Coins = 0, Receipts = {} })
	local store = world.stores.Profiles
	local remaining = 1
	store.afterCommit = function()
		if remaining > 0 then
			remaining -= 1
			error("502: response lost", 0)
		end
	end
	local decision = world.scheduler:call(function()
		return processReceipt(soul, "receipt-1", 100)
	end)
	equal(decision, "NotProcessedYet", "It cannot know the write landed")
	equal(store.data["91"].Coins, 100)
	decision = world.scheduler:call(function()
		return processReceipt(soul, "receipt-1", 100)
	end)
	equal(decision, "PurchaseGranted")
	equal(store.data["91"].Coins, 100)
end)

test("a purchase is not acknowledged once the session has lost its record", function()
	local world = newWorld()
	local soul = world:active("Profiles", world:player(92), { Coins = 0, Receipts = {} })
	world.stores.Profiles.data["92"].MetaData.SessionId = "other"
	local decision = world.scheduler:call(function()
		return processReceipt(soul, "receipt-1", 100)
	end)
	equal(decision, "NotProcessedYet")
	equal(world.stores.Profiles.data["92"].Coins, 0)
end)

test("a purchase saved while an autosave is running waits and is confirmed", function()
	local world = newWorld()
	local soul = world:active("Profiles", world:player(93), { Coins = 0, Receipts = {} })
	local store = world.stores.Profiles
	store.beforeCommit = function(_key, callId)
		if callId == 2 then
			world.scheduler.task.wait(3)
		end
	end
	world.scheduler:spawn(function()
		soul:SaveData()
	end)
	local decision = world.scheduler:call(function()
		return processReceipt(soul, "receipt-1", 100)
	end)
	equal(decision, "PurchaseGranted")
	equal(store.data["93"].Coins, 100)
	equal(store.data["93"].Receipts["receipt-1"], true)
end)

-------------------------------------------------------------------------------------------- The save format stays the same

local function metaKeys(metaData)
	local keys = {}
	for key in pairs(metaData) do
		table.insert(keys, key)
	end
	table.sort(keys)
	return table.concat(keys, ",")
end

test("a 1.x record loads unchanged and keeps its shape through every write", function()
	local world = newWorld()
	local player = world:player(100)
	local store = world.dataStoreService:GetDataStore("Profiles")
	local original = {
		Coins = 125,
		Name = "Unicode ✓",
		Off = false,
		List = { "a", "b", { Id = 1 } },
		Nested = { Deep = { Value = 1.5 } },
		Empty = {},
		MetaData = { Locked = false, SaveId = 41, LastUpdate = BASE_TIME - 1000, SessionId = "", PurchaseCommit = "x" },
	}
	store.data["100"] = copy(original)
	local function checkFields(record)
		equal(record.Coins, 125)
		equal(record.Name, "Unicode ✓")
		equal(record.Off, false)
		equal(record.List[2], "b")
		equal(record.List[3].Id, 1)
		equal(record.Nested.Deep.Value, 1.5)
		equal(next(record.Empty), nil)
		equal(record.MetaData.PurchaseCommit, "x")
		equal(metaKeys(record.MetaData), "LastUpdate,Locked,PurchaseCommit,SaveId,SessionId")
		local count = 0
		for _ in pairs(record) do
			count += 1
		end
		equal(count, 7, "No top-level field is added or removed")
	end

	local soul = world:active("Profiles", player)
	local record = store.data["100"]
	checkFields(record)
	equal(record.MetaData.SaveId, 42)
	equal(record.MetaData.Locked, true)
	equal(record.MetaData.SessionId, soul.SessionToken)
	local function checkLastUpdate()
		-- Servers still on 1.x judge a lock by this field
		equal(record.MetaData.LastUpdate, BASE_TIME + math.floor(world.scheduler.now))
	end
	checkLastUpdate()

	world.scheduler:advance(5)
	equal(save(world, soul), true)
	record = store.data["100"]
	checkFields(record)
	checkLastUpdate()
	equal(record.MetaData.SaveId, 43)
	equal(record.MetaData.Locked, true)

	world.scheduler:advance(5)
	equal(save(world, soul, true), true)
	record = store.data["100"]
	checkFields(record)
	checkLastUpdate()
	equal(record.MetaData.SaveId, 44)
	equal(record.MetaData.Locked, false)
	equal(record.MetaData.SessionId, "")
end)

test("a new player's first record holds the defaults and the four metadata fields", function()
	local world = newWorld()
	world:active("Profiles", world:player(101), { Coins = 7, Nested = { Value = 1 } })
	local record = world.stores.Profiles.data["101"]
	equal(record.Coins, 7)
	equal(record.Nested.Value, 1)
	equal(metaKeys(record.MetaData), "LastUpdate,Locked,SaveId,SessionId")
	equal(record.MetaData.SaveId, 1)
	equal(record.MetaData.Locked, true)
	equal(metaKeys(record), "Coins,MetaData,Nested", "Nothing else is added to the record")
end)

test("a record with no metadata, as an old or hand-made save may have, gets it on load", function()
	local world = newWorld()
	local store = world.dataStoreService:GetDataStore("Profiles")
	store.data["102"] = { Coins = 9 }
	local soul = world:active("Profiles", world:player(102))
	equal(soul.Data.Coins, 9)
	equal(metaKeys(store.data["102"].MetaData), "LastUpdate,Locked,SaveId,SessionId")
end)

test("metadata with odd values does not stop a load", function()
	local odd = {
		{ Locked = "yes", SessionId = 5, SaveId = "12", LastUpdate = "never" },
		{ Locked = false, SaveId = true },
		{},
	}
	for index, metaData in ipairs(odd) do
		local world = newWorld()
		local store = world.dataStoreService:GetDataStore("Profiles")
		store.data["103"] = { Coins = 9, MetaData = metaData }
		local soul = assert(world.soulStore.new("Profiles", nil, world:player(103), { Coins = 0 }))
		local state = load(world, soul)
		world.scheduler:runUntil(function()
			return state.done
		end, 160)
		equal(state.loaded, true, "Case " .. index)
		equal(soul.Data.Coins, 9, "Case " .. index)
	end
end)

test("a record that is not a save at all is left alone and reported", function()
	for _, value in ipairs({ "text", 5, true }) do
		local world = newWorld()
		local store = world.dataStoreService:GetDataStore("Profiles")
		store.data["104"] = value
		local soul = assert(world.soulStore.new("Profiles", nil, world:player(104), { Coins = 0 }))
		local state = load(world, soul)
		world.scheduler:runUntil(function()
			return state.done
		end, 5)
		equal(state.reason, "CorruptData")
		equal(store.data["104"], value)
	end
end)

test("names at Roblox's limits are accepted, and over them refused", function()
	local world = newWorld()
	local name = string.rep("n", 50)
	expect(world.soulStore.new(name, nil, world:player(105), { Coins = 0 }) ~= nil)
	expect(world.soulStore.new("Profiles", name, world:player(106), { Coins = 0 }) ~= nil)
	equal(world.soulStore.new(name .. "x", nil, world:player(107), { Coins = 0 }), nil)
	equal(world.soulStore.new("Profiles", name .. "x", world:player(108), { Coins = 0 }), nil)
	equal(world.soulStore.new("", nil, world:player(109), { Coins = 0 }), nil)
end)

suite.run()
