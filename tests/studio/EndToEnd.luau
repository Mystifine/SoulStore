--[[
	The real module, on the real engine, against real data stores, with a real Player. It covers what the Lune tests
	cannot: that Roblox really behaves the way the module expects. Run it in Play in a PUBLISHED TEST PLACE with Studio API
	access on, and never in a live game's place. It only touches data stores whose names start with "SoulStoreE2E", and
	removes its keys as it goes. Delete the script afterwards.

	It needs the module as a ModuleScript at ServerStorage.SoulStore, and returns its results as text. Give it a Phase
	attribute to say what to run: "Main", then "Locks1" to "Locks8", then "Leave", which kicks the player. Then "Shutdown"
	and stop Play to leave a session for BindToClose to save, and "Verify" in a new Play to see that it landed.

	Timing runs on short settings through Config, because a real takeover would otherwise take 2 minutes.
]]

local PHASE = (script:GetAttribute("Phase") or "Main") :: string

local DataStoreService = game:GetService("DataStoreService")
local LogService = game:GetService("LogService")
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

-- Connected before SoulStore loads, so Roblox runs it after SoulStore's own handler
local olderLeaveHandler = nil
Players.PlayerRemoving:Connect(function()
	if olderLeaveHandler then
		olderLeaveHandler()
	end
end)

local module = ServerStorage:WaitForChild("SoulStore")
local SoulStore = require(module)
local Config = require(module:WaitForChild("Config"))

local STORE = "SoulStoreE2E"
local player = Players:GetPlayers()[1] or Players.PlayerAdded:Wait()
local KEY = tostring(player.UserId)
local store = DataStoreService:GetDataStore(STORE)
local readOptions = Instance.new("DataStoreGetOptions")
readOptions.UseCache = false

local lines, passed, failed = {}, 0, 0
local function check(name: string, condition: any, detail: any?)
	if condition then
		passed += 1
		table.insert(lines, "PASS " .. name)
	else
		failed += 1
		table.insert(lines, "FAIL " .. name .. (if detail ~= nil then " :: " .. tostring(detail) else ""))
	end
end
local function note(text: string)
	table.insert(lines, "     " .. text)
end
local function equal(name: string, actual: any, expected: any)
	check(name, actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local logs = {}
local logConnection = LogService.MessageOut:Connect(function(message)
	table.insert(logs, message)
end)
local function logged(text: string): boolean
	task.wait(0.25) -- output arrives a little later
	for _, line in ipairs(logs) do
		if string.find(line, text, 1, true) then
			return true
		end
	end
	return false
end

local function record(): (any, any)
	return store:GetAsync(KEY, readOptions)
end

local current = nil
local function finishCurrent()
	if current and (current.SessionState == "Active" or current.SessionState == "Pulling") then
		current:SaveData(true)
	end
	current = nil
end
local function fresh()
	finishCurrent()
	store:RemoveAsync(KEY)
end
local function begin(defaults: any): any
	current = assert(SoulStore.new(STORE, nil, player, defaults))
	return current
end
local function load(defaults: any): any
	local soul = begin(defaults)
	local loaded, reason = soul:LoadData()
	assert(loaded, "LoadData failed: " .. tostring(reason))
	return soul
end
-- Set for a phase that runs one step of many, because Studio can drop a call that runs for too long
local onlyStep = tonumber(string.match(PHASE, "^Locks(%d+)$"))
local stepNumber = 0
local function step(name: string, callback: () -> ())
	stepNumber += 1
	if onlyStep and onlyStep ~= stepNumber then
		return
	end
	table.insert(lines, "--- " .. name)
	local ok, problem = xpcall(callback, debug.traceback)
	if not ok then
		check(name .. " ran to the end", false, problem)
	end
end
local function count(value: any): number
	local total = 0
	for _ in pairs(value) do
		total += 1
	end
	return total
end

local function mainTests()
	step("a new player's record", function()
		fresh()
		local soul = load({ Coins = 1, Nested = { Value = 2 }, List = { "a", "b" } })
		local value, info = record()
		equal("the default scope is Roblox's own default", value and value.Coins, 1)
		equal("the session is active", soul.SessionState, "Active")
		equal("the old load state string", soul.LoadState, "Loaded")
		equal("the record is locked", value.MetaData.Locked, true)
		equal("by this session's token", value.MetaData.SessionId, soul.SessionToken)
		equal("the first SaveId", value.MetaData.SaveId, 1)
		equal("LastUpdate is a time", typeof(value.MetaData.LastUpdate), "number")
		if player.UserId > 0 then
			check("the key is tagged with the player's user id", table.find(info:GetUserIds(), player.UserId))
		else
			note("a negative test id, so no user id tag is expected")
		end
		equal("a real Player passes the player check", SoulStore.playerExists(player), true)
		equal("getSoul finds it", SoulStore.getSoul(STORE, nil, player), soul)
	end)

	step("saving", function()
		local soul = current
		soul:SetData({ "Coins" }, 5)
		soul.Data.Direct = 1
		soul.Data.MetaData.PurchaseCommit = "marker"
		local saved, reason = soul:SaveData()
		equal("SaveData confirms the write", saved, true)
		equal("with no reason", reason, nil)
		local value = record()
		equal("SetData's change landed", value.Coins, 5)
		equal("a direct change landed", value.Direct, 1)
		equal("an extra MetaData field landed", value.MetaData.PurchaseCommit, "marker")
		equal("SaveId rose", value.MetaData.SaveId, 2)
		equal("live MetaData is confirmed", soul.Data.MetaData.SaveId, 2)
		equal("the extra field stays live", soul.Data.MetaData.PurchaseCommit, "marker")
		equal("the save state is back to idle", soul.SaveState, "Idle")
	end)

	step("listeners and Reconcile", function()
		local soul = current
		local old, new
		local connection = soul:OnDataChanged({ "Nested" }, function(oldValue, newValue)
			old, new = oldValue, newValue
		end)
		soul:SetData({ "Nested", "Value" }, 3)
		equal("the listener gets the old value", old.Value, 2)
		equal("and the new value", new.Value, 3)
		check("as a copy", new ~= soul.Data.Nested)
		new.Value = 99
		equal("changing it does not reach the data", soul:GetData({ "Nested", "Value" }), 3)
		connection:Disconnect()

		soul:Reconcile({ List = { "x", "y", "z" }, Added = { "starter" }, Nested = { Extra = 1 } })
		equal("a saved array is left alone", #soul.Data.List, 2)
		equal("a missing array is filled", soul.Data.Added[1], "starter")
		equal("a missing field is filled", soul.Data.Nested.Extra, 1)
	end)

	step("save hooks", function()
		local soul = current
		soul:SetOnSave(function(data)
			data.FromHook = 1
		end)
		equal("a save with a hook lands", (soul:SaveData()), true)
		equal("the hook's change is saved", record().FromHook, 1)
		equal("live data is untouched", soul.Data.FromHook, nil)

		soul:SetOnSave(function()
			task.wait(1)
		end)
		local started = os.clock()
		local saved, reason = soul:SaveData()
		equal("a yielding hook fails the save", saved, false)
		equal("with the reason", reason, "HookFailed")
		check("without waiting for the hook", os.clock() - started < 0.9, os.clock() - started)
		check("and says why", logged("the hook yielded"))

		soul:SetOnSave(function(data)
			data.Partial = true
			error("boom")
		end)
		saved, reason = soul:SaveData()
		equal("an erroring hook fails the save", reason, "HookFailed")
		equal("and nothing it did is written", record().Partial, nil)

		soul:SetOnSave(nil :: any)
		equal("saving works again", (soul:SaveData()), true)
	end)

	step("what a data store cannot hold", function()
		local soul = current
		soul.Data.Vec = Vector3.zero
		soul.Data.Inst = workspace
		soul.Data.Enum = Enum.KeyCode.A
		soul.Data.Fn = print
		soul.Data.Thread = coroutine.create(print)
		soul.Data.BadText = "bad\xFF"
		soul.Data.BoolKey = { Keep = 1, [true] = "x" }
		soul.Data.InstKey = { Keep = 1, [workspace] = "x" }
		soul.Data.InfKey = { Keep = 1, [math.huge] = "x" }
		soul.Data.BadKey = { Keep = 1, ["bad\xFF"] = "x" }
		soul.Data.Inf = math.huge
		soul.Data.Nan = 0 / 0
		soul.Data.Buf = buffer.fromstring("abc")
		soul.Data.Big = 1e85
		soul:SetData({ "Coins" }, 6)

		local saved, reason = soul:SaveData()
		equal("the save still lands", saved, true)
		equal("with no reason", reason, nil)
		local value = record()
		equal("everything else landed", value.Coins, 6)
		for _, field in ipairs({ "Vec", "Inst", "Enum", "Fn", "Thread", "BadText" }) do
			equal(field .. " is left out", value[field], nil)
		end
		for _, field in ipairs({ "BoolKey", "InstKey", "InfKey", "BadKey" }) do
			equal(field .. " keeps only its good key", count(value[field]), 1)
			equal(field .. " keeps its good value", value[field].Keep, 1)
		end
		equal("infinity comes back", value.Inf, math.huge)
		check("NaN comes back", value.Nan ~= value.Nan)
		equal("a buffer comes back", buffer.tostring(value.Buf), "abc")
		equal("a big number comes back", value.Big, 1e85)
		check("what was dropped is reported", logged("Dropped values a data store cannot hold"))
		check("with its path", logged("BoolKey.true"))
		check("NaN is reported", logged("Saving NaN"))

		equal("SetData refuses an Instance", soul:SetData({ "New" }, workspace), nil)
		equal("SetData refuses a Vector3", soul:SetData({ "New" }, Vector3.zero), nil)
		equal("SetData refuses NaN", soul:SetData({ "New" }, 0 / 0), nil)
		equal("SetData refuses a boolean key", soul:SetData({ "New" }, { [true] = 1 }), nil)
		equal("SetData accepts infinity", soul:SetData({ "New" }, math.huge), math.huge)
		check("SetData accepts a buffer", soul:SetData({ "NewBuf" }, buffer.fromstring("x")) ~= nil)

		for _, field in ipairs({
			"Vec",
			"Inst",
			"Enum",
			"Fn",
			"Thread",
			"BadText",
			"BoolKey",
			"InstKey",
			"InfKey",
			"BadKey",
			"Nan",
			"New",
			"NewBuf",
		}) do
			soul.Data[field] = nil
		end
	end)

	step("tables a data store would change or lose", function()
		local soul = current
		local mixed = { "a", "b" }
		mixed.Name = "kept"
		local named = { Sword = 1, Shield = 2 }
		named[1] = "stray"
		soul.Data.Mixed = mixed
		soul.Data.Named = named
		soul.Data.Sparse = { [1001] = "a" }
		soul.Data.Frac = { [1.1] = "a", [1.9] = "b" }
		equal("the save lands", (soul:SaveData()), true)
		local value = record()
		equal("a mixed table keeps its string key", value.Mixed.Name, "kept")
		equal("and every entry of its array", value.Mixed["2"], "b")
		equal("named fields survive a stray number key", value.Named.Sword, 1)
		equal("and the stray value too", value.Named["1"], "stray")
		equal("a number key comes back as a string", value.Sparse["1001"], "a")
		equal("fractions do not land on each other", value.Frac["1.1"], "a")
		equal("the second fraction", value.Frac["1.9"], "b")
		check("it is reported", logged("will not load back the same"))
		check("with its path", logged("Mixed"))
		soul.Data.Mixed, soul.Data.Named, soul.Data.Sparse, soul.Data.Frac = nil, nil, nil, nil
	end)

	step("a stray number key at the top of a save", function()
		local soul = current
		local coins = soul.Data.Coins
		equal("SetData refuses it", soul:SetData({ 1 }, "oops"), nil)
		equal("SetData refuses one on a dictionary", soul:SetData({ "Nested", 1 }, "oops"), nil)
		equal("SetData refuses a name on an array", soul:SetData({ "List", "Name" }, "oops"), nil)
		-- selene: allow(mixed_table)
		equal("SetData refuses a mixed value", soul:SetData({ "New" }, { "a", Name = "b" }), nil)
		equal("SetData refuses a sparse key", soul:SetData({ "Empty" }, { [5] = "a" }), nil)
		soul.Data[1] = "oops"
		equal("written directly, the save still lands", (soul:SaveData()), true)
		local value = record()
		equal("and the named fields are all there", value.Coins, coins)
		equal("the lock too", value.MetaData.SessionId, soul.SessionToken)
		equal("and the stray value", value["1"], "oops")
		equal("the session goes on", soul.SessionState, "Active")
		soul.Data[1] = nil
		value["1"] = nil
		equal("and saves again", (soul:SaveData()), true)
		soul.Data["1"] = nil
	end)

	step("arrays with gaps", function()
		local soul = current
		local grown = {}
		for index = 1, 5 do
			grown[index] = "g" .. index
		end
		grown[4] = nil
		-- selene: allow(manual_table_clone)
		local rebuilt = {}
		for key, entry in pairs(grown) do
			rebuilt[key] = entry
		end
		note(string.format("built up, its length is %d. Rebuilt key by key, %d", #grown, #rebuilt))
		soul.Data.Grown = grown
		soul.Data.Rebuilt = rebuilt
		soul.Data.Cut = { [1] = "a", [3] = "c" }
		table.clear(logs)
		equal("the save lands", (soul:SaveData()), true)
		local value = record()
		equal("a gap survives the copy a save makes", value.Grown[5], "g5")
		equal("one that would have been cut short survives", value.Rebuilt[5], "g5")
		equal("with its number keys", value.Rebuilt[3], "g3")
		equal("as does this one", value.Cut[3], "c")
		check("none of them need a warning", not logged("will not load back the same"))
		soul.Data.Grown, soul.Data.Rebuilt, soul.Data.Cut = nil, nil, nil
	end)

	step("saves that cannot start from inside a hook", function()
		local soul = current
		local final, normal = nil, nil
		soul:SetOnSave(function()
			final = table.pack(soul:SaveData(true))
			normal = table.pack(soul:SaveData())
		end)
		soul:SetData({ "Coins" }, 12)
		local saved, reason = soul:SaveData()
		soul:SetOnSave(nil :: any)
		equal("the save that called the hook lands", saved, true)
		equal("with no reason", reason, nil)
		equal("a final save from the hook is refused", final[1], false)
		equal("with the reason", final[2], "CalledFromHook")
		equal("a normal save from the hook is refused", normal[2], "CalledFromHook")
		equal("the session goes on, and is not stranded", soul.SessionState, "Active")
		equal("the change landed", record().Coins, 12)
		check("it says why", logged("Cannot be called from inside"))
	end)

	step("what cannot ever be a save", function()
		equal("an array as defaults is refused", SoulStore.new(STORE .. "Other", nil, player, { "a", "b" }), nil)
		equal(
			"a mixed table as defaults is refused",
			-- selene: allow(mixed_table)
			SoulStore.new(STORE .. "Other", nil, player, { Inner = { "a", Name = "b" } }),
			nil
		)
		local other = DataStoreService:GetDataStore(STORE .. "All")
		other:SetAsync(KEY, { "not", "a", "profile" })
		local soul = assert(SoulStore.new(STORE .. "All", nil, player, { Coins = 1 }))
		local loaded, reason = soul:LoadData()
		equal("a record stored as an array does not load", loaded, false)
		equal("with the reason", reason, "CorruptData")
		local kept = other:GetAsync(KEY, readOptions)
		equal("and it is left as it was", #kept, 3)
		other:RemoveAsync(KEY)
	end)

	step("a save over the size limit", function()
		local soul = current
		soul.Data.Blob = string.rep("x", 5 * 1024 * 1024)
		local saved, reason = soul:SaveData()
		equal("it is refused", saved, false)
		equal("with the reason", reason, "SaveRejected")
		equal("the session continues", soul.SessionState, "Active")
		soul.Data.Blob = nil
		equal("and saves again once it shrinks", (soul:SaveData()), true)
	end)

	step("a table that contains itself", function()
		local soul = current
		soul.Data.Self = soul.Data
		local saved, reason = soul:SaveData()
		equal("the save fails", saved, false)
		equal("with the reason", reason, "InternalError")
		equal("the session continues", soul.SessionState, "Active")
		soul.Data.Self = nil
		equal("and saves again once it is gone", (soul:SaveData()), true)
	end)

	step("a transform that fails on the real engine", function()
		local soul = current
		table.clear(logs)
		soul:SetOnSave(function(data)
			table.freeze(data.MetaData) -- the transform then errors when it stamps MetaData
		end)
		local saved, reason = soul:SaveData()
		equal("it reads as a failed save", saved, false)
		equal("not as losing the record", reason, "SaveFailed")
		equal("the session continues", soul.SessionState, "Active")
		check("and Roblox says why", logged("Transform function error"))
		soul:SetOnSave(nil :: any)
		equal("the next save lands", (soul:SaveData()), true)
	end)

	step("losing the record", function()
		local soul = current
		local state, why
		soul.SessionEndBindableEvent.Event:Connect(function(...)
			state, why = ...
		end)
		store:UpdateAsync(KEY, function(old, info)
			old.MetaData.SessionId = "another session"
			return old, info:GetUserIds(), info:GetMetadata()
		end)
		local saved, reason = soul:SaveData()
		equal("the save is refused", saved, false)
		equal("with the reason", reason, "OwnershipLost")
		task.wait(0.1)
		equal("the end event fires, though the event is destroyed straight after", state, "Ended")
		equal("with the reason", why, "OwnershipLost")
		equal("the session ended", soul.EndReason, "OwnershipLost")
		equal("gameplay is refused", soul:GetData(), nil)
		equal("getSoul stops finding it", SoulStore.getSoul(STORE, nil, player), nil)
		equal("the record is not touched", record().MetaData.SessionId, "another session")
	end)

	step("the final save", function()
		fresh()
		local soul = load({ Coins = 1 })
		local pending = 25
		soul:SetOnSave(function(data)
			data.Coins += pending
			pending = 0
		end)
		local state, why
		soul.SessionEndBindableEvent.Event:Connect(function(...)
			state, why = ...
		end)
		local saved, reason = soul:SaveData(true)
		equal("it confirms the write", saved, true)
		equal("with no reason", reason, nil)
		local value = record()
		equal("the hook's change landed", value.Coins, 26)
		equal("the record is unlocked", value.MetaData.Locked, false)
		equal("its token is cleared", value.MetaData.SessionId, "")
		task.wait(0.1)
		equal("the end event fires", state, "Ended")
		equal("with the reason", why, "Saved")
		equal("a second final save does nothing", (soul:SaveData(true)), false)
		equal("gameplay is refused", soul:SetData({ "Coins" }, 1), nil)

		-- A teleport that fails after the release
		local again = load({ Coins = 0 })
		check("the same player can start again", again ~= soul)
		equal("and gets the data", again.Data.Coins, 26)
		check("under a new token", again.SessionToken ~= soul.SessionToken)
	end)

	step("deleting", function()
		equal("a reset is refused during a session", SoulStore.resetData(STORE, nil, KEY), false)
		check("and deletes nothing", record() ~= nil)
		local soul = current
		store:RemoveAsync(KEY)
		local saved, reason = soul:SaveData()
		equal("a record deleted by something else stops the session", saved, false)
		equal("with the reason", reason, "OwnershipLost")
		equal("and is not brought back", record(), nil)
		current = nil
		store:SetAsync(KEY, { Coins = 1 })
		equal("a reset with no session deletes", SoulStore.resetData(STORE, nil, KEY), true)
		equal("really", record(), nil)
	end)

	step("scopes", function()
		fresh()
		local soul = assert(SoulStore.new(STORE, "SoulStoreE2EScope", player, { Coins = 9 }))
		current = soul
		assert(soul:LoadData())
		local scoped = DataStoreService:GetDataStore(STORE, "SoulStoreE2EScope")
		equal("the scoped record is there", scoped:GetAsync(KEY, readOptions).Coins, 9)
		equal("the default scope has nothing", record(), nil)
		soul:SaveData(true)
		current = nil
		scoped:RemoveAsync(KEY)
	end)

	step("wiping a whole data store", function()
		local name = STORE .. "All"
		local wiped = DataStoreService:GetDataStore(name)
		wiped:SetAsync("one", 1)
		wiped:SetAsync("two", 2)
		equal("it reports success", SoulStore.resetAllData(name, nil), true)
		equal("the first key is gone", wiped:GetAsync("one", readOptions), nil)
		equal("the second key is gone", wiped:GetAsync("two", readOptions), nil)
	end)
end

local function lockTests()
	local defaults = {
		AUTO_SAVE_INTERVAL = Config.AUTO_SAVE_INTERVAL,
		SESSION_EXPIRY = Config.SESSION_EXPIRY,
		TAKEOVER_DELAY = Config.TAKEOVER_DELAY,
		LOAD_ATTEMPT_INTERVAL = Config.LOAD_ATTEMPT_INTERVAL,
	}
	local function restore()
		for name, value in pairs(defaults) do
			Config[name] = value
		end
	end
	local function foreignLock(saveId: number)
		store:SetAsync(KEY, {
			Coins = 7,
			MetaData = { Locked = true, SessionId = "another session", SaveId = saveId, LastUpdate = os.time() },
		})
	end

	Config.LOAD_ATTEMPT_INTERVAL = 2

	step("a lock that stops changing is taken over", function()
		fresh()
		Config.SESSION_EXPIRY = 10
		Config.TAKEOVER_DELAY = 3
		foreignLock(5)
		local _, written = record()
		local skew = os.time() - written.UpdatedTime / 1000
		local started = os.clock()
		local soul = load({ Coins = 0 })
		local waited = os.clock() - started
		note(string.format("waited %.1f seconds with an expiry of 10, and a clock %.1f seconds off", waited, skew))
		check("it waited until the lock expired", waited >= math.max(3, 10 - skew) - 1, waited)
		check("and not much longer", waited < 16, waited)
		equal("it has the record's data", soul.Data.Coins, 7)
		equal("the record is its own", record().MetaData.SessionId, soul.SessionToken)
		equal("SaveId carried on", record().MetaData.SaveId, 6)
		restore()
		Config.LOAD_ATTEMPT_INTERVAL = 2
	end)

	step("a lock that keeps changing is not taken over", function()
		fresh()
		Config.SESSION_EXPIRY = 8
		Config.TAKEOVER_DELAY = 6 -- longer than the owner's writes are apart, whatever this machine's clock says
		foreignLock(5)
		local writing = true
		task.spawn(function()
			-- The live owner, autosaving
			local saveId = 5
			while writing do
				task.wait(3)
				saveId += 1
				store:UpdateAsync(KEY, function(old)
					old.MetaData.SaveId = saveId
					old.MetaData.LastUpdate = os.time()
					return old
				end)
			end
		end)
		local soul = begin({ Coins = 0 })
		local state = {}
		local started = os.clock()
		task.spawn(function()
			state.loaded, state.reason = soul:LoadData()
			state.at = os.clock() - started
		end)
		task.wait(16)
		equal("it is still waiting, long past the expiry", soul.SessionState, "Pulling")
		equal("the owner still has the record", record().MetaData.SessionId, "another session")
		writing = false
		local deadline = os.clock() + 25
		while state.at == nil and os.clock() < deadline do
			task.wait(0.25)
		end
		note(string.format("loaded %.1f seconds in, after the owner stopped at about 16", state.at or -1))
		equal("once the owner stops, it loads", state.loaded, true)
		check("after the delay", (state.at or 0) >= 16 + 5, state.at)
		restore()
		Config.LOAD_ATTEMPT_INTERVAL = 2
	end)

	step("a lock older than the expiry, by Roblox's own timestamp", function()
		fresh()
		Config.SESSION_EXPIRY = 15
		Config.TAKEOVER_DELAY = 3
		foreignLock(5)
		local _, info = record()
		local skew = os.time() - info.UpdatedTime / 1000
		note(string.format("this machine's clock is %.1f seconds from Roblox's", skew))
		local started = os.clock()
		local soul = load({ Coins = 0 })
		local waited = os.clock() - started
		note(string.format("waited %.1f seconds with an expiry of 15", waited))
		check("it waited until the lock looked expired", waited >= 15 - skew - 3, waited)
		check("and took it", waited < 22, waited)
		equal("the record is its own", record().MetaData.SessionId, soul.SessionToken)
		finishCurrent()
		restore()
		Config.LOAD_ATTEMPT_INTERVAL = 2
	end)

	step("a lock already old when the load finds it is still watched first", function()
		fresh()
		Config.SESSION_EXPIRY = 1
		Config.TAKEOVER_DELAY = 9
		foreignLock(5)
		local _, info = record()
		local skew = os.time() - info.UpdatedTime / 1000
		task.wait(math.max(3, 3 - skew))
		local started = os.clock()
		local soul = load({ Coins = 0 })
		local waited = os.clock() - started
		note(string.format("waited %.1f seconds, for an owner that might still land its final save", waited))
		check("it did not take the lock at once", waited >= 8.5, waited)
		check("and not much longer", waited < 15, waited)
		equal("the record is its own", record().MetaData.SessionId, soul.SessionToken)

		-- This time the owner lands its final save during the watch, as after an outage
		finishCurrent()
		fresh()
		foreignLock(5)
		task.wait(3)
		local second = begin({ Coins = 0 })
		local state = {}
		task.spawn(function()
			state.loaded = second:LoadData()
		end)
		task.wait(3)
		equal("it is still watching", second.SessionState, "Pulling")
		store:UpdateAsync(KEY, function(old)
			old.Coins = 99
			old.MetaData.Locked = false
			old.MetaData.SessionId = ""
			old.MetaData.SaveId += 1
			return old
		end)
		local deadline = os.clock() + 10
		while state.loaded == nil and os.clock() < deadline do
			task.wait(0.1)
		end
		equal("it loads as soon as the lock is released", state.loaded, true)
		equal("with what the owner saved", second.Data.Coins, 99)
		restore()
		Config.LOAD_ATTEMPT_INTERVAL = 2
	end)

	step("autosave", function()
		fresh()
		Config.AUTO_SAVE_INTERVAL = 4
		local soul = load({ Coins = 1 })
		soul.Data.Coins = 2
		local before = record().MetaData.SaveId
		task.wait(11)
		local value = record()
		check("it ran by itself, more than once", value.MetaData.SaveId >= before + 2, value.MetaData.SaveId - before)
		equal("and carried the change", value.Coins, 2)
		equal("the session is still active", soul.SessionState, "Active")
		restore()
		Config.LOAD_ATTEMPT_INTERVAL = 2
		finishCurrent()
	end)

	step("a session with no confirmed write keeps accepting changes", function()
		fresh()
		Config.AUTO_SAVE_INTERVAL = 1000
		Config.SESSION_EXPIRY = 5
		local soul = load({ Coins = 1 })
		soul:SetData({ "Coins" }, 2)
		local ended = false
		soul.SessionEndBindableEvent.Event:Connect(function()
			ended = true
		end)
		task.wait(8)
		equal("it is still active", soul.SessionState, "Active")
		equal("the event has not fired", ended, false)
		equal("gameplay still works", soul:GetData({ "Coins" }), 2)
		finishCurrent()
		local value = record()
		equal("its progress was saved", value.Coins, 2)
		equal("and the record released", value.MetaData.Locked, false)
		restore()
		Config.LOAD_ATTEMPT_INTERVAL = 2
	end)

	step("a load whose transform fails on the real engine", function()
		fresh()
		table.clear(logs)
		local soul = begin({ Coins = 1 })
		soul._defaultData = 5 -- the transform errors when it reads this as a table
		local state = {}
		task.spawn(function()
			state.loaded, state.reason = soul:LoadData()
		end)
		task.wait(7)
		equal("it keeps trying", soul.SessionState, "Pulling")
		check("and Roblox says why", logged("Transform function error"))
		local attempts = 0
		for _, line in ipairs(logs) do
			if string.find(line, "Failed to load data", 1, true) then
				attempts += 1
			end
		end
		note(attempts .. " attempts in 7 seconds")
		check("it waits between attempts", attempts <= 4, attempts)
		equal("nothing was written", record(), nil)
		soul._defaultData = { Coins = 1 }
		local deadline = os.clock() + 15
		while state.loaded == nil and os.clock() < deadline do
			task.wait(0.25)
		end
		equal("it loads once the problem is gone", state.loaded, true)
	end)

	step("several saves at once", function()
		fresh()
		local soul = load({ Coins = 1 })
		local results, finished = {}, 0
		for index = 1, 5 do
			task.spawn(function()
				results[index] = soul:SaveData()
				finished += 1
			end)
		end
		local deadline = os.clock() + 20
		while finished < 5 and os.clock() < deadline do
			task.wait(0.1)
		end
		equal("they all finish", finished, 5)
		local confirmed = 0
		for _, saved in pairs(results) do
			confirmed += if saved then 1 else 0
		end
		equal("they all land, one after another", confirmed, 5)
		equal("SaveId counts each one", record().MetaData.SaveId, 6)
		finishCurrent()
	end)

	restore()
	store:RemoveAsync(KEY)
end

-- The player leaving, for real. Nothing can run for this player afterwards, so it comes last.
local function leaveTest()
	step("the player leaving", function()
		fresh()
		local soul = load({ Coins = 1 })
		soul:SetData({ "Coins" }, 3)
		local hookCouldRead, hookSawNewer, hookSawOlder = false, nil, nil
		soul:SetOnSave(function(data)
			hookCouldRead = soul:GetData() ~= nil
			hookSawNewer, hookSawOlder = data.Newer, data.Older
			data.Coins += 4
		end)
		-- Roblox runs this one before SoulStore's handler, and the older one after it
		Players.PlayerRemoving:Connect(function()
			soul:SetData({ "Newer" }, "n")
		end)
		olderLeaveHandler = function()
			soul:SetData({ "Older" }, "o")
		end
		player:Kick("SoulStore end-to-end test")
		local deadline = os.clock() + 15
		while soul.SessionState ~= "Ended" and os.clock() < deadline do
			task.wait(0.1)
		end
		equal("the session ended", soul.SessionState, "Ended")
		equal("with the reason", soul.EndReason, "Saved")
		local value = record()
		equal("the change and the hook's change landed", value.Coins, 7)
		equal("the hook could still read the session", hookCouldRead, true)
		equal("a leave handler Roblox ran first made the final save", value.Newer, "n")
		equal("a leave handler Roblox ran last made the final save", value.Older, "o")
		equal("the hook saw the first", hookSawNewer, "n")
		equal("the hook saw the last", hookSawOlder, "o")
		equal("the record is unlocked", value.MetaData.Locked, false)
		store:RemoveAsync(KEY)
	end)
end

-- Leaves a session open, so that stopping Play has to save it.
local function shutdownSetup()
	step("leaving a session for BindToClose", function()
		fresh()
		local soul = load({ Coins = 1 })
		soul:SetData({ "Coins" }, 42)
		soul:SetOnSave(function(data)
			data.FromCloseHook = true
		end)
		note("session " .. soul.SessionToken .. " is open: stop Play now")
		current = nil
	end)
end

local function shutdownVerify()
	step("what BindToClose saved", function()
		local value = record()
		check("the record is there", value ~= nil)
		equal("the last change landed", value.Coins, 42)
		equal("the save hook ran", value.FromCloseHook, true)
		equal("the record is unlocked", value.MetaData.Locked, false)
		equal("its token is cleared", value.MetaData.SessionId, "")
		store:RemoveAsync(KEY)
	end)
end

local PHASES = {
	Main = mainTests,
	Leave = leaveTest,
	Shutdown = shutdownSetup,
	Verify = shutdownVerify,
}
if onlyStep then
	lockTests()
else
	PHASES[PHASE]()
end
if PHASE ~= "Shutdown" and PHASE ~= "Verify" then
	finishCurrent()
	store:RemoveAsync(KEY)
end
logConnection:Disconnect()
table.insert(lines, string.format("=== %s: %d passed, %d failed", PHASE, passed, failed))
local text = table.concat(lines, "\n")
print(text)
return text
