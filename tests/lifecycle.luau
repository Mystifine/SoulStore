-- Run with Lune 0.11+: lune run tests/lifecycle.luau
-- The session flow, case by case, on the real module. See tests/harness.luau for what is simulated.
local harness = require("./harness")

local newWorld, expect, equal = harness.newWorld, harness.expect, harness.equal
local suite = harness.newSuite("lifecycle regressions")
local test = suite.test

test("pending sessions deduplicate exact players and are unavailable to gameplay", function()
	local world = newWorld()
	local player = world:player(12)
	local store = world.soulStore
	local soul = assert(store.new("Profiles", nil, player, { Coins = 1 }))
	equal(soul.SessionState, "Pulling")
	equal(store.new("Profiles", nil, player, { Coins = 999 }), soul)
	equal(store.getPendingSoul("Profiles", nil, player), soul)
	equal(store.getSoul("Profiles", nil, player), nil)
	equal(store.hasActiveSession("Profiles", nil, player), false)
	equal(soul:GetData(), nil)
	soul:SetData({ "Coins" }, 999)
	equal(soul.Data.Coins, nil)
	world.scheduler:call(function()
		soul:SaveData()
	end)
	equal(world.dataStoreService:GetDataStore("Profiles").calls, 0)
	world.scheduler:call(function()
		return soul:LoadData()
	end)
	equal(store.getSoul("Profiles", nil, player), soul)
	equal(store.getPendingSoul("Profiles", nil, player), nil)
	equal(store.hasActiveSession("Profiles", nil, player), true)
	equal(soul:GetData({ "Coins" }), 1)
	equal(world.stores.Profiles.data["12"].MetaData.SessionId, soul.SessionToken)
	expect(soul.SessionToken ~= "same-server-job")
end)

test("fast rejoin creates a new object and waits for old final save", function()
	local world = newWorld()
	local oldPlayer = world:player(42)
	local oldSoul = world:active("Profiles", oldPlayer)
	oldSoul:SetData({ "Coins" }, 150)
	local store = world.stores.Profiles
	store.beforeCommit = function(_key, callId)
		if callId == 2 then
			world.scheduler.task.wait(2)
		end
	end
	world:remove(oldPlayer)
	equal(oldSoul.SessionState, "Ending")
	local player = world:player(42)
	local soul = assert(world.soulStore.new("Profiles", nil, player, { Coins = 0 }))
	expect(soul ~= oldSoul)
	expect(soul.SessionToken ~= oldSoul.SessionToken)
	equal(world.soulStore.getSoul("Profiles", nil, player), nil)
	world.scheduler:call(function()
		return soul:LoadData()
	end)
	equal(oldSoul.SessionState, "Ended")
	equal(soul.SessionState, "Active")
	equal(soul:GetData({ "Coins" }), 150)
	equal(world.soulStore.getSoul("Profiles", nil, oldPlayer), nil)
	equal(world.soulStore.getSoul("Profiles", nil, player), soul)
	equal(oldSoul.SessionEndBindableEvent.fireCount, 1)
	world.scheduler:call(function()
		oldSoul:SaveData(true)
	end)
	equal(world.soulStore.getSoul("Profiles", nil, player), soul)
	equal(store.data["42"].MetaData.SessionId, soul.SessionToken)
end)

test("a player leaving while locked cancels its pull without a write", function()
	local world = newWorld()
	local player = world:player(6)
	local store = world.dataStoreService:GetDataStore("Profiles")
	store.data["6"] =
		{ Coins = 44, MetaData = { Locked = true, SessionId = "other", SaveId = 5, LastUpdate = 1700000000 } }
	local soul = assert(world.soulStore.new("Profiles", nil, player, { Coins = 0 }))
	local finished = false
	world.scheduler:spawn(function()
		soul:LoadData()
		finished = true
	end)
	world:remove(player)
	world.scheduler:runUntil(function()
		return finished
	end, 10)
	equal(soul.SessionState, "Cancelled")
	equal(#store.writes, 0)
	equal(world.soulStore.getPendingSoul("Profiles", nil, player), nil)
	equal(soul.SessionEndBindableEvent.fireCount, 1)
	expect(soul.SessionEndBindableEvent.destroyed)
end)

test("an acquisition committed after departure is released without becoming active", function()
	local world = newWorld()
	local player = world:player(7)
	local store = world.dataStoreService:GetDataStore("Profiles")
	store.beforeCommit = function(_key, callId)
		if callId == 1 then
			world:remove(player)
		end
	end
	local soul = assert(world.soulStore.new("Profiles", nil, player, { Coins = 9 }))
	local loaded = world.scheduler:call(function()
		return soul:LoadData()
	end)
	equal(loaded, false)
	expect(soul.SessionState == "Ended" or soul.SessionState == "Cancelled")
	equal(world.soulStore.getSoul("Profiles", nil, player), nil)
	equal(store.data["7"].MetaData.Locked, false)
	equal(store.data["7"].MetaData.SessionId, "")
	equal(soul.SessionEndBindableEvent.fireCount, 1)
end)

test("final save is serialized behind autosave and seals mutations immediately", function()
	local world = newWorld()
	local player = world:player(8)
	local soul = world:active("Profiles", player)
	soul:SetData({ "Coins" }, 10)
	local heldReference = soul:GetData()
	local store = world.stores.Profiles
	store.beforeCommit = function(_key, callId)
		if callId == 2 then
			world.scheduler.task.wait(2)
		end
	end
	local regularDone = false
	world.scheduler:spawn(function()
		soul:SaveData()
		regularDone = true
	end)
	equal(store.active, 1)
	soul:SetData({ "Coins" }, 20)
	local finalDone = false
	world.scheduler:spawn(function()
		soul:SaveData(true)
		finalDone = true
	end)
	equal(soul.SessionState, "Ending")
	equal(world.soulStore.getSoul("Profiles", nil, player), nil)
	equal(world.soulStore.getEndingSoul("Profiles", nil, player), soul)
	soul:SetData({ "Coins" }, 999)
	soul:Reconcile({ Extra = true })
	equal(soul:GetData(), nil)
	heldReference.Coins = 5000
	world.scheduler:runUntil(function()
		return regularDone and finalDone and soul.SessionState == "Ended"
	end)
	equal(store.maxActive, 1)
	equal(store.data["8"].Coins, 20)
	equal(store.data["8"].Extra, nil)
	equal(store.data["8"].MetaData.Locked, false)
	equal(soul.SessionState, "Ended")
	equal(soul.SessionEndBindableEvent.fireCount, 1)
end)

test("foreign ownership rejection is terminal and never reports success", function()
	local world = newWorld()
	local player = world:player(9)
	local soul = world:active("Profiles", player)
	local store = world.stores.Profiles
	store.data["9"].MetaData.SessionId = "new-session"
	store.data["9"].Coins = 1234
	soul:SetData({ "Coins" }, 999)
	local result = world.scheduler:call(function()
		return soul:SaveData()
	end)
	equal(result, false)
	equal(store.data["9"].Coins, 1234)
	equal(store.data["9"].MetaData.SessionId, "new-session")
	equal(#store.writes, 1)
	equal(soul.SessionState, "Ended")
	equal(world.soulStore.getSoul("Profiles", nil, player), nil)
	equal(soul.SessionEndBindableEvent.fireCount, 1)
end)

test("transform replay increments SaveId only once and preserves Roblox key metadata", function()
	local world = newWorld()
	local player = world:player(10)
	local store = world.dataStoreService:GetDataStore("Profiles")
	store.data["10"] =
		{ Coins = 11, MetaData = { Locked = false, SessionId = "", SaveId = 20, LastUpdate = 1699990000 } }
	store.metadata["10"] = { Schema = "v1" }
	store.userIds["10"] = { 10, 11 }
	store.replays = 3
	local soul = world:active("Profiles", player)
	local previous = store.data["10"].MetaData.SaveId
	world.scheduler:call(function()
		return soul:SaveData()
	end)
	equal(store.data["10"].MetaData.SaveId, previous + 1)
	equal(store.metadata["10"].Schema, "v1")
	equal(store.userIds["10"][1], 10)
	equal(store.userIds["10"][2], 11)
end)

test("lost acquisition response is reclaimed by its same session token", function()
	local world = newWorld()
	local player = world:player(11)
	local store = world.dataStoreService:GetDataStore("Profiles")
	store.afterCommit = function(_key, callId)
		if callId == 1 then
			error("response lost after commit")
		end
	end
	local soul = world:active("Profiles", player, { Coins = 23 })
	expect(world.scheduler.now < 60, "Own lock must not wait for five-minute expiry")
	equal(store.data["11"].MetaData.SessionId, soul.SessionToken)
	equal(soul:GetData({ "Coins" }), 23)
end)

test("OnLoad failure preserves original data and releases its lock", function()
	local world = newWorld()
	local player = world:player(13)
	local store = world.dataStoreService:GetDataStore("Profiles")
	store.data["13"] =
		{ Coins = 27, MetaData = { Locked = false, SessionId = "", SaveId = 7, LastUpdate = 1699990000 } }
	local soul = assert(world.soulStore.new("Profiles", nil, player, { Coins = 0 }))
	soul:SetOnLoad(function(data)
		data.Coins = -100
		error("migration failed after partial mutation")
	end)
	local loaded = world.scheduler:call(function()
		return soul:LoadData()
	end)
	equal(loaded, false)
	equal(store.data["13"].Coins, 27)
	equal(store.data["13"].MetaData.Locked, false)
	equal(world.soulStore.getSoul("Profiles", nil, player), nil)
	equal(soul.SessionEndBindableEvent.fireCount, 1)
end)

test("legacy data without metadata loads without replacing saved fields", function()
	local world = newWorld()
	local player = world:player(14)
	local store = world.dataStoreService:GetDataStore("Profiles")
	store.data["14"] = { Coins = 500, OldField = true }
	local soul = world:active("Profiles", player, { Coins = 0 })
	equal(soul:GetData({ "Coins" }), 500)
	equal(soul:GetData({ "OldField" }), true)
	equal(store.data["14"].MetaData.SessionId, soul.SessionToken)
end)

test("concurrent loads share one acquisition and run OnLoad only once", function()
	local world = newWorld()
	local player = world:player(21)
	local store = world.dataStoreService:GetDataStore("Profiles")
	store.beforeRead = function()
		world.scheduler.task.wait(1)
	end
	local soul = assert(world.soulStore.new("Profiles", nil, player, { Coins = 0 }))
	local onLoadCount = 0
	soul:SetOnLoad(function()
		onLoadCount += 1
	end)
	local first, second
	world.scheduler:spawn(function()
		first = soul:LoadData()
	end)
	world.scheduler:spawn(function()
		second = soul:LoadData()
	end)
	world.scheduler:runUntil(function()
		return first ~= nil and second ~= nil
	end)
	equal(first, true)
	equal(second, true)
	equal(store.calls, 1)
	equal(onLoadCount, 1)
end)

test("last callback replay losing ownership cannot count as a saved write", function()
	local world = newWorld()
	local player = world:player(22)
	local soul = world:active("Profiles", player)
	local store = world.stores.Profiles
	store.replays = 2
	store.afterTransform = function(_key, _call, replay)
		if replay == 1 then
			store.data["22"].MetaData.SessionId = "winning-session"
			store.data["22"].Coins = 222
		end
	end
	soul:SetData({ "Coins" }, -1)
	local result = world.scheduler:call(function()
		return soul:SaveData()
	end)
	equal(result, false)
	equal(store.data["22"].Coins, 222)
	equal(store.data["22"].MetaData.SessionId, "winning-session")
	equal(#store.writes, 1)
	equal(soul.SessionState, "Ended")
end)

test("acquire response lost after departure still releases the orphaned lock", function()
	local world = newWorld()
	local player = world:player(23)
	local store = world.dataStoreService:GetDataStore("Profiles")
	store.afterCommit = function(_key, callId)
		if callId == 1 then
			world:remove(player)
			error("acquisition committed but response lost after departure")
		end
	end
	local soul = assert(world.soulStore.new("Profiles", nil, player, { Coins = 19 }))
	local loaded = world.scheduler:call(function()
		return soul:LoadData()
	end)
	equal(loaded, false)
	equal(store.data["23"].MetaData.Locked, false)
	equal(store.data["23"].MetaData.SessionId, "")
	equal(world.soulStore.getSoul("Profiles", nil, player), nil)
	equal(soul.SessionEndBindableEvent.fireCount, 1)
end)

test("cancelled uncertain acquisitions stop retrying during a permanent outage", function()
	local world = newWorld()
	local player = world:player(37)
	local store = world.dataStoreService:GetDataStore("Profiles")
	store.afterCommit = function(_key, callId)
		if callId == 1 then
			world:remove(player)
			store.beforeRead = function()
				error("permanent backend outage")
			end
			error("acquisition response lost")
		end
	end
	local soul = assert(world.soulStore.new("Profiles", nil, player, { Coins = 5 }))
	local loaded = world.scheduler:call(function()
		return soul:LoadData()
	end)
	equal(loaded, false)
	equal(soul.SessionState, "Cancelled")
	equal(soul.EndReason, "AcquisitionUncertain")
	expect(world.scheduler.now <= 31)
	equal(#store.writes, 1)
	equal(store.data["37"].MetaData.Locked, true)
	equal(store.data["37"].MetaData.LastUpdate, 1700000000)
	equal(soul.SessionEndBindableEvent.fireCount, 1)
	expect(soul.SessionEndBindableEvent.destroyed)
end)

test("cancelled recovery handles a lost release response without acquiring again", function()
	local world = newWorld()
	local player = world:player(38)
	local store = world.dataStoreService:GetDataStore("Profiles")
	store.afterCommit = function(_key, callId)
		if callId == 1 then
			world:remove(player)
			error("acquire response lost")
		elseif callId == 2 then
			error("release response lost")
		end
	end
	local soul = assert(world.soulStore.new("Profiles", nil, player, { Coins = 6 }))
	world.scheduler:call(function()
		soul:LoadData()
	end)
	equal(soul.SessionState, "Cancelled")
	equal(soul.EndReason, "Cancelled")
	equal(store.data["38"].MetaData.Locked, false)
	equal(store.data["38"].MetaData.SessionId, "")
	equal(#store.writes, 2)
	equal(store.writes[1].data.MetaData.Locked, true)
	equal(store.writes[2].data.MetaData.Locked, false)
end)

test("cancelled uncertain request never claims an unowned record", function()
	local world = newWorld()
	local player = world:player(39)
	local store = world.dataStoreService:GetDataStore("Profiles")
	store.beforeRead = function(_key, callId)
		if callId == 1 then
			world:remove(player)
			error("acquisition failed before reading")
		end
	end
	local soul = assert(world.soulStore.new("Profiles", nil, player, { Coins = 7 }))
	world.scheduler:call(function()
		soul:LoadData()
	end)
	equal(soul.SessionState, "Cancelled")
	equal(store.data["39"], nil)
	equal(#store.writes, 0)
end)

test("an old final retry cannot overwrite a new owner after a lost response", function()
	local world = newWorld()
	local oldPlayer = world:player(24)
	local oldSoul = world:active("Profiles", oldPlayer)
	oldSoul:SetData({ "Coins" }, 41)
	local store = world.stores.Profiles
	local newSoul
	store.afterCommit = function(_key, callId)
		if callId == 2 then
			local newPlayer = world:player(24)
			newSoul = world:active("Profiles", newPlayer)
			newSoul:SetData({ "Coins" }, 99)
			newSoul:SaveData()
			error("final commit response lost")
		end
	end
	world.scheduler:call(function()
		oldSoul:SaveData(true)
	end)
	equal(oldSoul.SessionState, "Ended")
	equal(newSoul.SessionState, "Active")
	equal(store.data["24"].Coins, 99)
	equal(store.data["24"].MetaData.SessionId, newSoul.SessionToken)
	world:remove(oldPlayer)
	equal(newSoul.SessionState, "Active")
end)

test("corrupt stored data fails closed without replacing it with defaults", function()
	local world = newWorld()
	local player = world:player(25)
	local store = world.dataStoreService:GetDataStore("Profiles")
	store.data["25"] = "corrupt-player-data"
	local soul = assert(world.soulStore.new("Profiles", nil, player, { Coins = 0 }))
	local completed = false
	world.scheduler:spawn(function()
		soul:LoadData()
		completed = true
	end)
	world:remove(player)
	world.scheduler:runUntil(function()
		return completed
	end, 10)
	equal(store.data["25"], "corrupt-player-data")
	equal(#store.writes, 0)
	expect(soul.SessionState ~= "Active")
	equal(world.soulStore.getSoul("Profiles", nil, player), nil)
end)

test("a yielding OnLoad fails closed and preserves the original record", function()
	local world = newWorld()
	local player = world:player(26)
	local store = world.dataStoreService:GetDataStore("Profiles")
	store.data["26"] = { Coins = 60 }
	local soul = assert(world.soulStore.new("Profiles", nil, player, { Coins = 0 }))
	soul:SetOnLoad(function(data)
		data.Coins = -1
		world.scheduler.task.wait(1)
		data.Coins = -2
	end)
	local loaded = world.scheduler:call(function()
		return soul:LoadData()
	end)
	equal(loaded, false)
	equal(store.data["26"].Coins, 60)
	equal(store.data["26"].MetaData.Locked, false)
	equal(world.soulStore.getSoul("Profiles", nil, player), nil)
end)

test("same-server legacy locks are respected until they have gone quiet", function()
	local world = newWorld()
	local player = world:player(27)
	local store = world.dataStoreService:GetDataStore("Profiles")
	store.data["27"] =
		{ Coins = 70, MetaData = { Locked = true, SessionId = "same-server-job", SaveId = 5, LastUpdate = 1700000000 } }
	local soul = assert(world.soulStore.new("Profiles", nil, player, { Coins = 0 }))
	local loaded
	world.scheduler:spawn(function()
		loaded = soul:LoadData()
	end)
	equal(world.soulStore.getSoul("Profiles", nil, player), nil)
	equal(store.data["27"].MetaData.SessionId, "same-server-job")
	equal(#store.writes, 0)
	world.scheduler:runUntil(function()
		return loaded ~= nil
	end, 350)
	equal(loaded, true)
	expect(world.scheduler.now >= world.config.SESSION_EXPIRY)
	equal(store.data["27"].MetaData.SessionId, soul.SessionToken)
	equal(soul:GetData({ "Coins" }), 70)
end)

test("OnSave errors never commit partial transformations", function()
	local world = newWorld()
	local player = world:player(28)
	local soul = world:active("Profiles", player, { Coins = 80 })
	local store = world.stores.Profiles
	soul:SetOnSave(function(snapshot)
		snapshot.Coins = -1
		error("serializer failed")
	end)
	local saved = world.scheduler:call(function()
		return soul:SaveData()
	end)
	equal(saved, false)
	equal(store.data["28"].Coins, 80)
	equal(#store.writes, 1)
	equal(soul.SessionState, "Active")
	local attempts = 0
	soul:SetOnSave(function(snapshot)
		attempts += 1
		snapshot.Coins = -1
		error("failed halfway through")
	end)
	local finalSaved = world.scheduler:call(function()
		return soul:SaveData(true)
	end)
	equal(finalSaved, true, "The rest of the player's progress still saves")
	equal(attempts, 1)
	equal(store.data["28"].Coins, 80, "Nothing the failed hook did is written")
	equal(store.data["28"].MetaData.Locked, false)
	equal(soul.SessionState, "Ended")
end)

test("retries reuse the same OnSave transformation snapshot", function()
	local world = newWorld()
	local player = world:player(29)
	local soul = world:active("Profiles", player, { Coins = 90 })
	local store = world.stores.Profiles
	local hookCalls = 0
	soul:SetOnSave(function(snapshot)
		hookCalls += 1
		snapshot.Coins += 1
	end)
	store.beforeRead = function(_key, callId)
		if callId == 2 then
			error("temporary DataStore error")
		end
	end
	local saved = world.scheduler:call(function()
		return soul:SaveData(true)
	end)
	equal(saved, true)
	equal(hookCalls, 1)
	equal(store.data["29"].Coins, 91)
	equal(soul.Data.Coins, 90)
end)

test("completion signals fire once with the terminal state and reason", function()
	local world = newWorld()
	local player = world:player(30)
	local soul = world:active("Profiles", player)
	local calls, state, reason = 0, nil, nil
	soul.SessionEndBindableEvent.Event:Connect(function(nextState, nextReason)
		calls += 1
		state, reason = nextState, nextReason
	end)
	world.scheduler:call(function()
		return soul:SaveData(true)
	end)
	world.scheduler:call(function()
		return soul:SaveData(true)
	end)
	equal(calls, 1)
	equal(state, "Ended")
	equal(reason, "Saved")
	equal(soul.EndReason, "Saved")
	expect(soul.SessionEndBindableEvent.destroyed)
end)

test("listeners receive old snapshots and new values, and disconnect safely", function()
	local world = newWorld()
	local player = world:player(31)
	local soul = world:active("Profiles", player, { Stats = { Level = 1 }, ["a.b"] = 1, a = { b = 2 } })
	local rootOld, rootNew, statsOld, statsNew, levelOld, levelNew
	soul:OnDataChanged(nil, function(old, new)
		rootOld, rootNew = old, new
	end)
	soul:OnDataChanged({ "Stats" }, function(old, new)
		statsOld, statsNew = old, new
	end)
	local connection = soul:OnDataChanged({ "Stats", "Level" }, function(old, new)
		levelOld, levelNew = old, new
	end)
	soul:SetData({ "Stats", "Level" }, 2)
	equal(rootOld.Stats.Level, 1)
	equal(rootNew.Stats.Level, 2)
	equal(rootOld.MetaData, nil, "A whole-table listener never sees MetaData")
	equal(rootNew.MetaData, nil)
	equal(statsOld.Level, 1)
	equal(statsNew.Level, 2)
	equal(levelOld, 1)
	equal(levelNew, 2)
	connection:Disconnect()
	connection:Disconnect()
	soul:SetData({ "Stats", "Level" }, 3)
	equal(levelNew, 2)
	equal(statsNew.Level, 3)
	local literalCalls, nestedCalls = 0, 0
	soul:OnDataChanged({ "a.b" }, function()
		literalCalls += 1
	end)
	soul:OnDataChanged({ "a", "b" }, function()
		nestedCalls += 1
	end)
	soul:SetData({ "a.b" }, 10)
	equal(literalCalls, 1)
	equal(nestedCalls, 0)
	world.scheduler:call(function()
		soul:SaveData(true)
	end)
	soul:SetData({ "Stats", "Level" }, 4)
	equal(statsNew.Level, 3)
end)

test("listeners get copies, so they cannot reach the saved data", function()
	local world = newWorld()
	local player = world:player(72)
	local soul = world:active("Profiles", player, { Golems = { A = { Level = 1 } } })
	local kept, oldKept
	soul:OnDataChanged({ "Golems" }, function(old, new)
		oldKept, kept = old, new
	end)
	soul:SetData({ "Golems", "A" }, { Level = 2 })
	equal(kept.A.Level, 2)
	equal(oldKept.A.Level, 1)
	expect(kept ~= soul.Data.Golems, "The new value is not the live table")

	kept.A.Level = 99
	table.clear(oldKept)
	equal(soul:GetData({ "Golems", "A", "Level" }), 2, "Changing what it received changes nothing")

	local first = kept
	soul.Data.Golems.A.Level = 3
	equal(first.A.Level, 99, "What it kept does not change under it")
	soul:SetData({ "Golems", "A", "Level" }, 4)
	expect(kept ~= first, "The next change arrives as a new copy")
	equal(kept.A.Level, 4)
end)

test("levels nobody listens to are not copied", function()
	local world = newWorld()
	local soul = world:active("Profiles", world:player(73), { Big = { Small = { Value = 1 } } })
	local level
	soul:OnDataChanged({ "Big", "Small", "Value" }, function(_, new)
		level = new
	end)
	local big, small = soul.Data.Big, soul.Data.Big.Small
	soul:SetData({ "Big", "Small", "Value" }, 2)
	equal(level, 2)
	equal(soul.Data.Big, big, "The tables around the value stay the same tables")
	equal(soul.Data.Big.Small, small)
end)

test("metadata stays module-owned across APIs and hooks", function()
	local world = newWorld()
	local player = world:player(32)
	local soul = assert(
		world.soulStore.new("Profiles", nil, player, { Coins = 1, MetaData = { SessionId = "injected-default" } })
	)
	soul:SetOnLoad(function(data)
		data.MetaData = { SessionId = "injected-hook" }
	end)
	world.scheduler:call(function()
		soul:LoadData()
	end)
	equal(soul.Data.MetaData.SessionId, soul.SessionToken)
	soul:SetData({ "MetaData", "SessionId" }, "injected-setter")
	soul:Reconcile({ MetaData = { Extra = "injected-reconcile" } })
	equal(soul.Data.MetaData.SessionId, soul.SessionToken)
	equal(soul.Data.MetaData.Extra, nil)
	soul:SetOnSave(function(snapshot)
		snapshot.MetaData = { Locked = false, SessionId = "injected-save", SaveId = 100000 }
	end)
	world.scheduler:call(function()
		soul:SaveData()
	end)
	equal(world.stores.Profiles.data["32"].MetaData.SessionId, soul.SessionToken)
	equal(world.stores.Profiles.data["32"].MetaData.Locked, true)
	expect(world.stores.Profiles.data["32"].MetaData.SaveId < 100000)
end)

test("OnLoad may request cancellation without publishing or saving transformed data", function()
	local world = newWorld()
	local player = world:player(33)
	local soul = assert(world.soulStore.new("Profiles", nil, player, { Coins = 1 }))
	soul:SetOnLoad(function(data)
		data.Coins = 999
		soul:SaveData(true)
	end)
	local loaded = world.scheduler:call(function()
		return soul:LoadData()
	end)
	equal(loaded, false)
	equal(world.soulStore.getSoul("Profiles", nil, player), nil)
	equal(world.stores.Profiles.data["33"].Coins, 1)
	equal(world.stores.Profiles.data["33"].MetaData.Locked, false)
	equal(soul.SessionEndBindableEvent.fireCount, 1)
end)

test("autosave writes only active sessions and retains their ownership", function()
	local world = newWorld()
	local player = world:player(34)
	local soul = world:active("Profiles", player, { Coins = 1 })
	local pendingPlayer = world:player(35)
	local pending = assert(world.soulStore.new("Profiles", nil, pendingPlayer, { Coins = 0 }))
	soul:SetData({ "Coins" }, 88)
	world.scheduler:call(function()
		world.scheduler.task.wait(31)
	end)
	equal(world.stores.Profiles.data["34"].Coins, 88)
	equal(world.stores.Profiles.data["34"].MetaData.SessionId, soul.SessionToken)
	equal(world.stores.Profiles.data["35"], nil)
	equal(pending.SessionState, "Pulling")
end)

test("the final save hook can still read the session while the player leaves", function()
	local world = newWorld()
	local player = world:player(69)
	local soul = world:active("Profiles", player, { Coins = 7 })
	local store = world.stores.Profiles
	-- The game's shadow XP hook reads through GetData, and the player may already be unparented by now
	soul:SetOnSave(function(snapshot)
		snapshot.SeenByHook = soul:GetData({ "Coins" })
	end)
	world:remove(player)
	world.scheduler:runUntil(function()
		return soul.SessionState == "Ended"
	end)
	equal(store.data["69"].SeenByHook, 7)
end)

test("a leave handler running before SoulStore's still gets its write saved", function()
	local world = newWorld()
	local player = world:player(70)
	local soul = world:active("Profiles", player, { Coins = 1 })
	local store = world.stores.Profiles
	player.Parent = nil
	equal(soul:SetData({ "Coins" }, 50), 50)
	world.players.PlayerRemoving:Fire(player)
	world.scheduler:runUntil(function()
		return soul.SessionState == "Ended"
	end)
	equal(store.data["70"].Coins, 50)
end)

test("autosaves keep the lock fresh, so a long session keeps its record", function()
	local world = newWorld()
	local player = world:player(68)
	local soul = world:active("Profiles", player, { Coins = 1 })
	world.scheduler:call(function()
		world.scheduler.task.wait(360)
	end)
	equal(soul.SessionState, "Active")
	local rival = assert(world.soulStore.new("Profiles", nil, world:player(68), { Coins = 0 }))
	world.scheduler:spawn(function()
		rival:LoadData()
	end)
	world.scheduler:call(function()
		world.scheduler.task.wait(20)
	end)
	equal(rival.SessionState, "Pulling", "A live session's record must not be claimable")
	equal(world.stores.Profiles.data["68"].MetaData.SessionId, soul.SessionToken)
end)

test("an outage longer than the expiry leaves the session usable, and its next autosave lands", function()
	local world = newWorld()
	local player = world:player(40)
	local soul = world:active("Profiles", player, { Coins = 1 })
	local store = world.stores.Profiles
	soul:SetData({ "Coins" }, 100)
	store.beforeRead = function()
		error("backend outage")
	end
	world.scheduler:advance(600)
	equal(world.soulStore.getSoul("Profiles", nil, player), soul)
	equal(soul.SessionState, "Active")
	equal(soul:SetData({ "Coins" }, 200), 200, "Play carries on through the outage")
	store.beforeRead = nil
	world.scheduler:advance(35)
	equal(store.data["40"].Coins, 200)
	equal(store.data["40"].MetaData.SessionId, soul.SessionToken)
	equal(soul.SessionEndBindableEvent.fireCount, 0)
end)

test("a final save that outlives an outage reaches the record before the next session", function()
	-- Different lengths, so that the two sets of retries line up differently each time
	for round = 1, 30 do
		local servers, stores, scheduler = harness.newCluster(2)
		local player = servers[1]:player(41)
		local soul = servers[1]:active("Profiles", player, { Coins = 1 })
		servers[1].offline, servers[2].offline = true, true
		soul:SetData({ "Coins" }, 100) -- only the final save can carry this
		scheduler:advance(20 + round % 7)
		servers[1]:remove(player)
		scheduler:advance(3)

		local replacement = assert(servers[2].soulStore.new("Profiles", nil, servers[2]:player(41), { Coins = 0 }))
		local loaded
		scheduler:spawn(function()
			loaded = replacement:LoadData()
		end)
		scheduler:advance(300 + round * 0.73)
		servers[1].offline, servers[2].offline = false, false
		scheduler:runUntil(function()
			return loaded ~= nil and soul.SessionState == "Ended"
		end, 120)
		equal(soul.EndReason, "Saved")
		equal(replacement:GetData({ "Coins" }), 100, "What the old session held arrives first")
		equal(stores.Profiles.data["41"].MetaData.SessionId, replacement.SessionToken)
	end
end)

test("a final save cut off from the store stops once another session takes the record", function()
	local servers, stores, scheduler = harness.newCluster(2)
	local player = servers[1]:player(42)
	local soul = servers[1]:active("Profiles", player, { Coins = 1 })
	soul:SetData({ "Coins" }, 100)
	servers[1].offline = true
	servers[1]:remove(player)

	local replacement = servers[2]:active("Profiles", servers[2]:player(42))
	equal(soul.SessionState, "Ending", "It is still trying")
	servers[1].offline = false
	scheduler:runUntil(function()
		return soul.SessionState == "Ended"
	end, 20)
	equal(soul.EndReason, "OwnershipLost")
	equal(stores.Profiles.data["42"].Coins, 1, "It did not overwrite the new session")
	equal(stores.Profiles.data["42"].MetaData.SessionId, replacement.SessionToken)
end)

test("final saves stop slowing down at a flat 10 seconds", function()
	local world = newWorld()
	local player = world:player(43)
	world:active("Profiles", player, { Coins = 1 })
	local attempts = {}
	world.stores.Profiles.beforeRead = function()
		table.insert(attempts, world.scheduler.now)
		error("503: temporary outage")
	end
	world:remove(player)
	world.scheduler:advance(300)
	for index = 2, #attempts do
		local gap = attempts[index] - attempts[index - 1]
		expect(gap <= 12, "10 seconds, give or take 20%: " .. gap)
	end
	expect(#attempts >= 25, "It keeps trying: " .. #attempts)
end)

test("a save that hangs no longer blocks the next, and cannot undo it when it comes back", function()
	local world = newWorld()
	local soul = world:active("Profiles", world:player(44), { Coins = 1 })
	local store = world.stores.Profiles
	local hanging = true
	store.beforeRead = function()
		if hanging then
			hanging = false
			world.scheduler.task.wait(200)
		end
	end
	soul:SetData({ "Coins" }, 2)
	world.scheduler:spawn(function()
		soul:SaveData()
	end)
	soul:SetData({ "Coins" }, 3)
	local saved, reason = world.scheduler:call(function()
		return soul:SaveData()
	end)
	equal(saved, false, "It has only just started")
	equal(reason, "Saving")

	world.scheduler:advance(60)
	equal(store.data["44"].Coins, 3, "An autosave got past it")
	soul:SetData({ "Coins" }, 4)
	saved = world.scheduler:call(function()
		return soul:SaveData()
	end)
	equal(saved, true)

	world.scheduler:advance(150)
	local highest = 0
	for _, write in ipairs(store.writes) do
		expect(write.data.Coins >= highest, "The one that came back late must not undo a newer save")
		highest = write.data.Coins
	end
	equal(highest, 4)
	equal(soul.SessionState, "Active")
end)

test("a session cut off from the store never overwrites the session that took over", function()
	local servers, stores, scheduler = harness.newCluster(2)
	local soul = servers[1]:active("Profiles", servers[1]:player(41), { Coins = 1 })
	soul:SetData({ "Coins" }, 100)
	servers[1].offline = true -- this server alone is cut off, and stays that way past the takeover
	scheduler:advance(301)
	local newPlayer = servers[2]:player(41)
	local replacement = servers[2]:active("Profiles", newPlayer)
	replacement:SetData({ "Coins" }, 555)
	scheduler:call(function()
		replacement:SaveData()
	end)
	servers[1].offline = false
	scheduler:runUntil(function()
		return soul.SessionState == "Ended"
	end, 40)
	equal(soul.EndReason, "OwnershipLost")
	equal(stores.Profiles.data["41"].Coins, 555)
	equal(stores.Profiles.data["41"].MetaData.SessionId, replacement.SessionToken)
	equal(servers[2].soulStore.getSoul("Profiles", nil, newPlayer), replacement)
end)

test("shutdown joins an already retrying ending session without another writer", function()
	local world = newWorld()
	local player = world:player(36)
	local soul = world:active("Profiles", player)
	local store = world.stores.Profiles
	store.beforeRead = function(_key, callId)
		if callId == 2 then
			error("temporary final save failure")
		end
	end
	world:remove(player)
	equal(soul.SessionState, "Ending")
	world:close()
	equal(soul.SessionState, "Ended")
	equal(soul.EndReason, "Saved")
	equal(soul.SessionEndBindableEvent.fireCount, 1)
	equal(store.maxActive, 1)
	equal(store.data["36"].MetaData.Locked, false)
end)

test("player removal ends every datastore for only that exact player", function()
	local world = newWorld()
	local player = world:player(15)
	local other = world:player(16)
	local first = world:active("Main", player)
	local second = world:active("Inventory", player)
	local unrelated = world:active("Main", other)
	world:remove(player)
	world.scheduler:runUntil(function()
		return first.SessionState == "Ended" and second.SessionState == "Ended"
	end)
	equal(unrelated.SessionState, "Active")
	equal(world.stores.Main.data["15"].MetaData.Locked, false)
	equal(world.stores.Inventory.data["15"].MetaData.Locked, false)
	equal(world.stores.Main.data["16"].MetaData.SessionId, unrelated.SessionToken)
end)

test("shutdown settles active and pending sessions and rejects new sessions", function()
	local world = newWorld()
	local player = world:player(17)
	local soul = world:active("Profiles", player)
	local pendingPlayer = world:player(18)
	local pending = assert(world.soulStore.new("Profiles", nil, pendingPlayer, { Coins = 0 }))
	world:close()
	equal(soul.SessionState, "Ended")
	equal(pending.SessionState, "Cancelled")
	equal(world.stores.Profiles.data["17"].MetaData.Locked, false)
	equal(world.soulStore.new("Profiles", nil, world:player(19), { Coins = 0 }), nil)
	for _, event in ipairs(world.events) do
		expect(event.destroyed, "Terminal sessions must destroy their BindableEvents")
	end
end)

test("a shutdown the store never answers keeps its lock, until Roblox ends the server", function()
	local world = newWorld()
	local player = world:player(20)
	local soul = world:active("Profiles", player)
	local store = world.stores.Profiles
	store.beforeRead = function()
		error("DataStore unavailable")
	end
	world:close()
	equal(store.data["20"].MetaData.Locked, true)
	equal(store.data["20"].MetaData.SessionId, soul.SessionToken)
	equal(soul.SessionState, "Ending", "It was still trying when Roblox ended the server")
end)

test("a store that comes back late in a shutdown still gets the final saves", function()
	local world = newWorld()
	local souls = {}
	for index = 1, 20 do
		souls[index] = world:active("Profiles", world:player(900 + index), { Coins = 1 })
		souls[index]:SetData({ "Coins" }, 5)
	end
	local store = world.stores.Profiles
	local down = true
	store.beforeRead = function()
		if down then
			error("503: temporary outage")
		end
	end
	world.scheduler.task.delay(22, function()
		down = false
	end)
	world:close()
	for index, soul in ipairs(souls) do
		equal(soul.EndReason, "Saved")
		equal(store.data[tostring(900 + index)].Coins, 5)
	end
end)

test("regular saves make one attempt and report the failure", function()
	local world = newWorld()
	local player = world:player(50)
	local soul = world:active("Profiles", player, { Coins = 1 })
	local store = world.stores.Profiles
	soul:SetData({ "Coins" }, 2)
	store.beforeRead = function()
		error("503: temporary outage")
	end
	local callsBefore = store.calls
	local saved, reason = world.scheduler:call(function()
		return soul:SaveData()
	end)
	equal(saved, false)
	equal(reason, "SaveFailed")
	equal(store.calls, callsBefore + 1)
	equal(soul.SessionState, "Active")
	equal(soul.SaveState, "Idle")
	store.beforeRead = nil
	saved = world.scheduler:call(function()
		return soul:SaveData()
	end)
	equal(saved, true)
	equal(store.data["50"].Coins, 2)
end)

test("a save arriving during another waits its turn and is confirmed", function()
	local world = newWorld()
	local player = world:player(51)
	local soul = world:active("Profiles", player, { Coins = 1 })
	local store = world.stores.Profiles
	store.beforeCommit = function(_key, callId)
		if callId == 2 then
			world.scheduler.task.wait(2)
		end
	end
	local firstSaved, secondSaved
	world.scheduler:spawn(function()
		firstSaved = soul:SaveData()
	end)
	soul:SetData({ "Coins" }, 100)
	world.scheduler:spawn(function()
		secondSaved = soul:SaveData()
	end)
	world.scheduler:runUntil(function()
		return firstSaved ~= nil and secondSaved ~= nil
	end)
	equal(firstSaved, true)
	equal(secondSaved, true)
	equal(store.maxActive, 1)
	equal(store.data["51"].Coins, 100)
end)

test("a change made during a save survives and held tables stay live", function()
	local world = newWorld()
	local player = world:player(52)
	local soul = world:active("Profiles", player, { Coins = 1 })
	local store = world.stores.Profiles
	local held = soul:GetData()
	store.beforeCommit = function(_key, callId)
		if callId == 2 then
			world.scheduler.task.wait(2)
		end
	end
	local done = false
	world.scheduler:spawn(function()
		soul:SaveData()
		done = true
	end)
	soul:SetData({ "Coins" }, 777)
	world.scheduler:runUntil(function()
		return done
	end)
	equal(soul:GetData({ "Coins" }), 777)
	equal(soul:GetData(), held)
	held.Coins = 888
	world.scheduler:call(function()
		return soul:SaveData()
	end)
	equal(store.data["52"].Coins, 888)
end)

test("a final save retries through an outage with spaced attempts", function()
	local world = newWorld()
	local player = world:player(53)
	local soul = world:active("Profiles", player, { Coins = 1 })
	local store = world.stores.Profiles
	soul:SetData({ "Coins" }, 5)
	local attemptTimes = {}
	store.beforeRead = function()
		table.insert(attemptTimes, world.scheduler.now)
		if world.scheduler.now < 20 then
			error("503: temporary outage")
		end
	end
	local saved = world.scheduler:call(function()
		return soul:SaveData(true)
	end)
	equal(saved, true)
	equal(soul.EndReason, "Saved")
	equal(store.data["53"].Coins, 5)
	equal(store.data["53"].MetaData.Locked, false)
	expect(#attemptTimes >= 3, "A final save retries")
	for index = 2, #attemptTimes do
		expect(attemptTimes[index] - attemptTimes[index - 1] >= 1.5, "Final retries stay spaced")
	end
	local firstWait = attemptTimes[2] - attemptTimes[1]
	expect(firstWait <= 2.5, "The first retry comes quickly: " .. firstWait)
	local lastWait = attemptTimes[#attemptTimes] - attemptTimes[#attemptTimes - 1]
	expect(lastWait >= firstWait * 1.5, "And they slow down: " .. firstWait .. " then " .. lastWait)
end)

test("a permanent error stops a final save and still releases the lock", function()
	local world = newWorld()
	local player = world:player(54)
	local soul = world:active("Profiles", player, { Coins = 1 })
	local store = world.stores.Profiles
	soul:SetData({ "Coins" }, 5)
	store.beforeRead = function(_key, callId)
		if callId == 2 then
			error("104: Cannot store Dictionary in data store.", 0)
		end
	end
	local saved, reason = world.scheduler:call(function()
		return soul:SaveData(true)
	end)
	equal(saved, false)
	equal(reason, "SaveRejected")
	equal(store.calls, 3)
	equal(store.data["54"].Coins, 1)
	equal(store.data["54"].MetaData.Locked, false)
	equal(store.data["54"].MetaData.SessionId, "")
end)

test("a stuck final save cannot roll back a session that already released", function()
	local world = newWorld()
	local player = world:player(55)
	local soul = world:active("Profiles", player, { Coins = 1 })
	local store = world.stores.Profiles
	soul:SetData({ "Coins" }, 777)
	store.beforeRead = function()
		error("503: outage on this server")
	end
	world:remove(player)
	world.scheduler:call(function()
		world.scheduler.task.wait(320)
	end)
	-- The lock expired, another server claimed it, the player earned more there and left
	store.data["55"] = {
		Coins = 999,
		MetaData = { Locked = false, SessionId = "", SaveId = 60, LastUpdate = 1700000000 },
	}
	store.beforeRead = nil
	world.scheduler:runUntil(function()
		return soul.SessionState == "Ended"
	end, 40)
	equal(soul.EndReason, "OwnershipLost")
	equal(store.data["55"].Coins, 999)
end)

test("a session that lost its token cannot write over a lapsed foreign lock", function()
	local world = newWorld()
	local player = world:player(56)
	local soul = world:active("Profiles", player, { Coins = 1 })
	local store = world.stores.Profiles
	soul:SetData({ "Coins" }, 777)
	store.data["56"] = {
		Coins = 999,
		MetaData = { Locked = true, SessionId = "other", SaveId = 60, LastUpdate = 1700000000 - 400 },
	}
	local saved, reason = world.scheduler:call(function()
		return soul:SaveData()
	end)
	equal(saved, false)
	equal(reason, "OwnershipLost")
	equal(store.data["56"].Coins, 999)
	equal(store.data["56"].MetaData.SessionId, "other")
	equal(soul.SessionState, "Ended")
end)

test("a final save whose response was lost still reports success", function()
	local world = newWorld()
	local player = world:player(57)
	local soul = world:active("Profiles", player, { Coins = 1 })
	local store = world.stores.Profiles
	soul:SetData({ "Coins" }, 5)
	store.afterCommit = function(_key, callId)
		if callId == 2 then
			error("response lost after commit")
		end
	end
	local saved = world.scheduler:call(function()
		return soul:SaveData(true)
	end)
	equal(saved, true)
	equal(soul.EndReason, "Saved")
	equal(#store.writes, 2)
	equal(store.data["57"].Coins, 5)
	equal(store.data["57"].MetaData.Locked, false)
end)

test("scopes are separate sessions and separate records", function()
	local world = newWorld()
	local player = world:player(58)
	local store = world.soulStore
	local main = assert(store.new("Profiles", nil, player, { Coins = 1 }))
	local season = assert(store.new("Profiles", "Season2", player, { Coins = 2 }))
	expect(main ~= season)
	world.scheduler:call(function()
		return main:LoadData()
	end)
	world.scheduler:call(function()
		return season:LoadData()
	end)
	equal(store.getSoul("Profiles", nil, player), main)
	equal(store.getSoul("Profiles", "global", player), main)
	equal(store.getSoul("Profiles", "Season2", player), season)
	season:SetData({ "Coins" }, 20)
	world.scheduler:call(function()
		return season:SaveData()
	end)
	equal(world.stores.Profiles.data["58"].Coins, 1)
	equal(world.stores["Profiles/Season2"].data["58"].Coins, 20)
	world:remove(player)
	world.scheduler:runUntil(function()
		return main.SessionState == "Ended" and season.SessionState == "Ended"
	end)
	equal(world.stores["Profiles/Season2"].data["58"].MetaData.Locked, false)
end)

test("old-style calls fail safely instead of misusing their arguments", function()
	local world = newWorld()
	local player = world:player(59)
	local store = world.dataStoreService:GetDataStore("Profiles")
	store.data["59"] = { Coins = 1 }
	equal(world.soulStore.new("Profiles", player, { Coins = 0 }), nil)
	equal(world.soulStore.getSoul("Profiles", player), nil)
	equal(world.soulStore.resetData("Profiles", "59"), false)
	equal(store.data["59"].Coins, 1)
	equal(#store.writes, 0)
end)

test("SetData refuses values a data store cannot hold", function()
	local world = newWorld()
	local player = world:player(60)
	local soul = world:active("Profiles", player, { Coins = 1 })
	local cyclic = {}
	cyclic.Self = cyclic
	local unstorable = { function() end, 0 / 0, "\255", cyclic, { Nested = function() end }, world:player(61) }
	for _, value in ipairs(unstorable) do
		equal(soul:SetData({ "Bad" }, value), nil)
		equal(soul:GetData({ "Bad" }), nil)
	end
	equal(soul:SetData({ "Coins", "x" }, 1), nil, "A path through a non-table fails safely")
	equal(soul:SetData({ true }, 1), nil, "A path key must be a string or number")
	equal(soul:SetData({ "Bad" }, { [true] = 1 }), nil, "A table key must be a string or number")
	equal(soul:SetData({ "Good" }, { Fine = true, List = { 1, 2 } }).Fine, true)
end)

test("values set directly that a data store cannot hold are left out of the save", function()
	local world = newWorld()
	local player = world:player(62)
	local soul = world:active("Profiles", player, { Coins = 1 })
	local store = world.stores.Profiles
	soul:SetData({ "Coins" }, 2)
	soul.Data.Bad = function() end
	local saved = world.scheduler:call(function()
		return soul:SaveData()
	end)
	equal(saved, true)
	equal(store.data["62"].Coins, 2)
	equal(store.data["62"].Bad, nil)
end)

test("a save too large for a data store is refused and reported", function()
	local world = newWorld()
	local player = world:player(63)
	local soul = world:active("Profiles", player, { Coins = 1 })
	world.stores.Profiles.beforeRead = function()
		error("105: Serialized value exceeds 4MB limit.", 0)
	end
	local saved, reason = world.scheduler:call(function()
		return soul:SaveData()
	end)
	equal(saved, false)
	equal(reason, "SaveRejected")
	equal(soul.SessionState, "Active")
end)

test("failures still reach the output with DEBUG_MODE off", function()
	local world = newWorld()
	local soul = world:active("Profiles", world:player(71), { Coins = 1 })
	world.config.DEBUG_MODE = false
	table.clear(world.logs)
	world.stores.Profiles.beforeRead = function()
		error("503: outage")
	end
	world.scheduler:call(function()
		return soul:SaveData()
	end)
	expect(#world.logs > 0, "A failed save must be logged")
end)

test("the game's purchase check holds: markers survive and SaveId rises", function()
	local world = newWorld()
	local soul = world:active("Profiles", world:player(64), { Coins = 1 })
	local store = world.stores.Profiles
	-- Copied from PlayerDataService.persistSoul in AriseShadows
	local function persistSoul()
		local deadline = world.scheduler.now + 30
		while soul.SaveState == "Saving" and world.scheduler.now < deadline do
			world.scheduler.task.wait(0.1)
		end
		if soul.SaveState ~= "Idle" then
			return false
		end
		local marker = "marker:" .. tostring(world.scheduler.now)
		local before = soul.Data.MetaData.SaveId
		soul.Data.MetaData.PurchaseCommit = marker
		local ok = pcall(soul.SaveData, soul, false)
		return ok and soul.Data.MetaData.PurchaseCommit == marker and soul.Data.MetaData.SaveId > before, marker
	end
	equal(soul.LoadState, "Loaded")
	equal(soul.SaveState, "Idle")
	local durable, marker = world.scheduler:call(persistSoul)
	equal(durable, true)
	equal(store.data["64"].MetaData.PurchaseCommit, marker)
	store.beforeRead = function()
		error("503: outage")
	end
	durable = world.scheduler:call(persistSoul)
	equal(durable, false, "A failed write is not durable")
	equal(soul.SessionState, "Active")
	store.beforeRead = nil
	store.data["64"].MetaData.SessionId = "other"
	durable = world.scheduler:call(persistSoul)
	equal(durable, false, "A refused write is not durable")
	equal(store.data["64"].MetaData.SessionId, "other")
end)

test("reset functions refuse records this server is using", function()
	local world = newWorld()
	local player = world:player(65)
	local soul = world:active("Profiles", player, { Coins = 1 })
	local store = world.stores.Profiles
	equal(world.soulStore.resetData("Profiles", nil, "65"), false)
	equal(world.soulStore.resetAllData("Profiles", nil), false)
	equal(store.data["65"].Coins, 1)
	world:remove(player)
	world.scheduler:runUntil(function()
		return soul.SessionState == "Ended"
	end)
	equal(world.soulStore.resetData("Profiles", nil, "65"), true)
	equal(store.data["65"], nil)
end)

test("resetAllData outside Studio needs the datastore name repeated", function()
	local world = newWorld({ live = true })
	local store = world.dataStoreService:GetDataStore("Profiles")
	store.data["66"] = { Coins = 1 }
	store.data["67"] = { Coins = 2 }
	equal(world.soulStore.resetAllData("Profiles", nil), false)
	equal(store.data["66"].Coins, 1)
	local removed = world.scheduler:call(function()
		return world.soulStore.resetAllData("Profiles", nil, "Profiles")
	end)
	equal(removed, true)
	equal(next(store.data), nil)
end)

suite.run()
