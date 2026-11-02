--[[
	A full server's worth of sessions on the real engine, against real data stores, for what no simulation can show: real
	request times, real budgets, what saves cost in real frames, and whether every save lands. Run it in Play in a PUBLISHED
	TEST PLACE with Studio API access on, and never in a live game's place. It only touches the data store
	"SoulStoreE2EFleet", with one scope per session because one real Player has one key, and removes its keys as it goes.

	It needs the module as a ModuleScript at ServerStorage.SoulStore. It runs in the background and writes what it finds to
	the FleetResult attribute on ServerStorage, ending with a line starting "DONE". Give it a SESSIONS and a MINUTES below.

	A server with one player gets 100 requests a minute, on top of what it has built up, so 200 sessions cannot autosave
	every 30 seconds here. They autosave every 60, and run out of budget partway, which is worth seeing too. A real 200
	player server gets 8,060 requests a minute.
]]

local SESSIONS = 200
local MINUTES = 5
local ITEMS = 150 -- the size of each save, which comes to about 20 KB
local STORE = "SoulStoreE2EFleet"

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local module = ServerStorage:WaitForChild("SoulStore")
local SoulStore = require(module)
local Config = require(module:WaitForChild("Config"))
local DataValidator = require(module:WaitForChild("DataValidator"))
local DeepCopyUtil = require(module:WaitForChild("DeepCopyUtil"))

local player = Players:GetPlayers()[1] or Players.PlayerAdded:Wait()
local readOptions = Instance.new("DataStoreGetOptions")
readOptions.UseCache = false

local lines = {}
local function say(text: string)
	table.insert(lines, text)
	ServerStorage:SetAttribute("FleetResult", table.concat(lines, "\n"))
end

local function percentile(values: { number }, fraction: number): number
	local sorted = table.clone(values)
	table.sort(sorted)
	return sorted[math.clamp(math.ceil(#sorted * fraction), 1, math.max(#sorted, 1))] or 0
end

local function newProfile(items: number)
	local owned = {}
	for id = 1, items do
		owned["S" .. id] = {
			Monster = "M" .. id % 40,
			Rank = "E",
			Scale = 1.25,
			Size = 3,
			Xp = id,
			Age = 0,
			ExtractedAt = 1700000000,
			Locked = false,
		}
	end
	return {
		Earned = 0,
		Steps = 0,
		Items = owned,
		Settings = { Music = true, Volume = 0.5, Quality = "High" },
		Quests = { State = "New", Done = {}, Counts = { Clears = 0, Raises = 0 } },
		History = {},
		Receipts = {},
	}
end

-- What a save costs this server's CPU, by the size of the save. It is the part that runs inside one frame.
local function measureSaveCost()
	say("--- What preparing one save costs, in real time on this engine")
	for _, items in ipairs({ 20, 150, 1000, 5000 }) do
		local profile = newProfile(items)
		local json = #game:GetService("HttpService"):JSONEncode(profile)
		local began = os.clock()
		local rounds = 0
		while os.clock() - began < 0.5 do
			local copy = DeepCopyUtil.deepCopy(profile)
			DataValidator.removeUnstorable(copy)
			rounds += 1
		end
		say(string.format("%5d items, %7d bytes: %.3f ms", items, json, (os.clock() - began) / rounds * 1000))
		task.wait()
	end
end

task.spawn(function()
	measureSaveCost()
	task.wait(1)

	say(string.format("--- %d sessions for %d minutes, autosaving every 60 seconds", SESSIONS, MINUTES))
	Config.AUTO_SAVE_INTERVAL = 60
	Config.LOCK_TAKEOVER_TIME = 180

	-- Frame times, while all of this runs
	local frames = {}
	local frameConnection = RunService.Heartbeat:Connect(function(step)
		table.insert(frames, step)
	end)

	local sessions = {}
	local loadTimes, failedLoads, failures = {}, 0, {}
	local remaining = SESSIONS
	local started = os.clock()
	for index = 1, SESSIONS do
		task.spawn(function()
			local soul = assert(SoulStore.new(STORE, "s" .. index, player, newProfile(ITEMS)))
			local began = os.clock()
			local loaded, reason = soul:LoadData()
			remaining -= 1
			if loaded then
				table.insert(loadTimes, os.clock() - began)
				table.insert(sessions, { soul = soul, scope = "s" .. index, earned = 0, steps = 0, confirmed = 0 })
			else
				failedLoads += 1
				failures[tostring(reason)] = (failures[tostring(reason)] or 0) + 1
			end
		end)
	end
	while remaining > 0 and os.clock() - started < 120 do
		task.wait(0.25)
	end
	say(
		string.format(
			"Loaded %d of %d in %.1fs. Each load: median %.2fs, worst %.2fs. Failed %d. Budget now %d",
			#sessions,
			SESSIONS,
			os.clock() - started,
			percentile(loadTimes, 0.5),
			percentile(loadTimes, 1),
			failedLoads,
			DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync)
		)
	)

	-- Gameplay: everyone earns something every couple of seconds, and now and then buys something, which has to be confirmed
	local playing = true
	local purchases, confirmed, saveTimes = 0, 0, {}
	task.spawn(function()
		while playing do
			task.wait(2)
			for _, session in ipairs(sessions) do
				local soul = session.soul
				if soul.SessionState == "Active" then
					if soul:SetData({ "Earned" }, session.earned + 1) ~= nil then
						session.earned += 1
					end
					local data = soul:GetData()
					if data then
						data.Steps += 1
						session.steps = data.Steps
					end
					if math.random() < 2 / 400 then
						purchases += 1
						local earnedNow = session.earned
						task.spawn(function()
							local began = os.clock()
							if soul:SaveData() then
								confirmed += 1
								session.confirmed = math.max(session.confirmed, earnedNow)
								table.insert(saveTimes, os.clock() - began)
							end
						end)
					end
				end
			end
		end
	end)

	local playUntil = os.clock() + MINUTES * 60
	while os.clock() < playUntil do
		task.wait(60)
		local active = 0
		for _, session in ipairs(sessions) do
			active += if session.soul.SessionState == "Active" then 1 else 0
		end
		say(
			string.format(
				"  at %.0fs: %d active, %d purchases, %d confirmed, budget %d, frames so far: median %.1f ms, 99%% %.1f ms, worst %.1f ms",
				os.clock() - started,
				active,
				purchases,
				confirmed,
				DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync),
				percentile(frames, 0.5) * 1000,
				percentile(frames, 0.99) * 1000,
				percentile(frames, 1) * 1000
			)
		)
	end
	playing = false

	say(
		string.format(
			"While playing: frames median %.1f ms, 99%% %.1f ms, worst %.1f ms. Saves asked for by purchases: median %.2fs, worst %.2fs",
			percentile(frames, 0.5) * 1000,
			percentile(frames, 0.99) * 1000,
			percentile(frames, 1) * 1000,
			percentile(saveTimes, 0.5),
			percentile(saveTimes, 1)
		)
	)

	-- Everyone leaves at once, as a shutdown would have it
	table.clear(frames)
	local finalsLeft, finalTimes, finalFailed = #sessions, {}, 0
	local finalStarted = os.clock()
	for _, session in ipairs(sessions) do
		task.spawn(function()
			local began = os.clock()
			local saved, reason = session.soul:SaveData(true)
			if saved then
				table.insert(finalTimes, os.clock() - began)
			else
				finalFailed += 1
				failures[tostring(reason)] = (failures[tostring(reason)] or 0) + 1
			end
			finalsLeft -= 1
		end)
	end
	while finalsLeft > 0 and os.clock() - finalStarted < 120 do
		task.wait(0.25)
	end
	say(
		string.format(
			"%d final saves at once, took %.1fs. Each: median %.2fs, worst %.2fs. Failed %d. Frames during them: 99%% %.1f ms, worst %.1f ms",
			#sessions,
			os.clock() - finalStarted,
			percentile(finalTimes, 0.5),
			percentile(finalTimes, 1),
			finalFailed,
			percentile(frames, 0.99) * 1000,
			percentile(frames, 1) * 1000
		)
	)
	frameConnection:Disconnect()

	-- What really reached the data stores
	task.wait(5)
	local missing, lost, stillLocked, totalEarned, readErrors = 0, 0, 0, 0, 0
	for _, session in ipairs(sessions) do
		local store = DataStoreService:GetDataStore(STORE, session.scope)
		local ok, record = pcall(function()
			return store:GetAsync(tostring(player.UserId), readOptions)
		end)
		if not ok then
			readErrors += 1
		elseif not record then
			missing += 1
		else
			totalEarned += record.Earned
			if record.Earned ~= session.earned or record.Steps ~= session.steps then
				lost += 1
			end
			if record.MetaData.Locked then
				stillLocked += 1
			end
		end
		pcall(function()
			store:RemoveAsync(tostring(player.UserId))
		end)
		task.wait(0.02)
	end
	say(
		string.format(
			"Checked each record: %d points in all, %d records different from the game's, %d missing, %d still locked, %d not readable",
			totalEarned,
			lost,
			missing,
			stillLocked,
			readErrors
		)
	)
	for reason, count in pairs(failures) do
		say(string.format("  %dx %s", count, reason))
	end
	say(string.format("DONE in %.0fs", os.clock() - started))
end)

return "started"
