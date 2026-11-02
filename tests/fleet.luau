-- A whole game's worth of servers and players, for tests/load.luau and tests/compare.luau. Each server runs its own copy of
-- the real module against one shared data store, and players do what they do in a real game: join, load, play, buy things,
-- hop servers, leave, come back. Time is virtual, so hours pass in minutes. Nothing connects to Roblox.
--
-- Roblox's limits come from its documentation, and how fast requests are from measuring real data stores:
-- https://create.roblox.com/docs/cloud-services/data-stores/error-codes-and-limits
--
-- Every write to the data store is checked as it lands, so what this finds is what the data store really ended up with:
--   a save only ever goes forward: progress never goes back, and SaveId goes up by one
--   only the session holding the lock writes
--   a save the module said was confirmed is never lost
--   a player only ever loses progress if their server died
--   every session ends, and every lock is released, unless its server died
local fs = require("@lune/fs")

local harness = require("./harness")

local Fleet = {}

local PLAY_STEP = 2 -- seconds of gameplay between each player's turns

-- Measured on real data stores
local REQUEST_TIME = 0.26 -- a typical round trip, in seconds
local REQUEST_SPREAD = 0.2 -- how far from typical they stray
local REQUESTS_PER_SECOND = 30 -- what one server gets through at once. More than this wait their turn.

local STARTUP_BUDGET = 600 -- a new server's one-time burst, which Roblox documents but does not size
local SERVER_BUDGET = { base = 60, perPlayer = 40, capMinutes = 3 } -- from Roblox's documentation
local EXPERIENCE_BUDGET = { base = 300, perPlayer = 20 } -- from Roblox's documentation

local OUTAGE_ERROR = "502: API Services rejected request with error. HTTP 500 (Internal Server Error)"
local THROTTLED_ERROR =
	"502: API Services rejected request with error. Error code: 0 Reason: Too many requests, try again later."

-- What a save looks like. Earned and Steps only ever go up, so any rollback shows.
local DEFAULTS = {
	Version = 3,
	Earned = 0,
	Coins = 0,
	Steps = 0,
	Playtime = 0,
	NextItem = 1,
	Items = {},
	Receipts = {},
	History = {},
	Settings = { Music = true, Volume = 0.5, Quality = "High" },
	Quests = { State = "New", Done = {}, Counts = { Clears = 0, Raises = 0 } },
}

local function newItem(id: number)
	return {
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

-- Repeatable, so a failure can be run again
local function newRandom(seed: number)
	local state = seed % 2147483646 + 1
	local random = {}
	function random.next(): number
		state = (state * 48271) % 2147483647
		return state / 2147483647
	end
	function random.chance(probability: number): boolean
		return random.next() < probability
	end
	function random.between(low: number, high: number): number
		return low + random.next() * (high - low)
	end
	function random.whole(low: number, high: number): number
		return low + math.floor(random.next() * (high - low + 1))
	end
	-- Many small values and a few large ones, as session lengths and request times are
	function random.skewed(median: number, spread: number): number
		local normal = math.sqrt(-2 * math.log(math.max(random.next(), 1e-9))) * math.cos(2 * math.pi * random.next())
		return median * math.exp(spread * normal)
	end
	return random
end

local function newSample()
	local sample = { values = {}, count = 0, largest = 0 }
	function sample:add(value: number)
		self.count += 1
		self.largest = math.max(self.largest, value)
		table.insert(self.values, value)
	end
	function sample:percentile(fraction: number): number
		if self.count == 0 then
			return 0
		end
		if not self.sorted or #self.sorted ~= #self.values then
			self.sorted = table.clone(self.values)
			table.sort(self.sorted)
		end
		return self.sorted[math.clamp(math.ceil(#self.sorted * fraction), 1, #self.sorted)]
	end
	return sample
end

--------------------------------------------------------------------------------------------------------------- Backends
-- What the fleet needs from a data store module, so that the same game can run on either.

Fleet.SoulStore = {
	name = "SoulStore",
	sources = nil, -- the files in src/
	takeoverAfter = function(world: any): number
		return world.config.LOCK_TAKEOVER_TIME
	end,
	-- The game's data, the save's counter if it has one, and the session holding the lock
	read = function(record: any): (any, number?, string?)
		local meta = record.MetaData
		if typeof(meta) ~= "table" or typeof(record.Earned) ~= "number" then
			return nil, nil, nil
		end
		return record, meta.SaveId, if meta.Locked then meta.SessionId else nil
	end,
	open = function(world: any, storeName: string, player: any): any?
		local soul = world.soulStore.new(storeName, nil, player, DEFAULTS)
		if not soul then
			return nil
		end
		local handle: any = {}
		function handle.load()
			soul:SetOnLoad(function(data)
				data.Version = 3 -- a migration
			end)
			local loaded, reason = soul:LoadData()
			if loaded then
				soul:Reconcile(DEFAULTS)
			end
			return loaded, reason
		end
		function handle.data()
			return soul:GetData()
		end
		function handle.read(path: { string })
			return soul:GetData(path)
		end
		function handle.set(path: { any }, value: any): boolean
			return soul:SetData(path, value) ~= nil or value == nil
		end
		function handle.save(): boolean
			return (soul:SaveData())
		end
		function handle.isActive(): boolean
			return world.soulStore.getSoul(storeName, nil, player) == soul
		end
		function handle.endNow()
			soul:SaveData(true)
		end
		function handle.onSave(callback: (any) -> ())
			soul:SetOnSave(callback)
		end
		function handle.watch(path: { string }, callback: (any, any) -> ())
			soul:OnDataChanged(path, callback)
		end
		function handle.onEnded(callback: (string) -> ())
			handle.connection = soul.SessionEndBindableEvent.Event:Connect(function(_state, reason)
				callback(reason)
			end)
		end
		function handle.forget()
			handle.connection:Disconnect()
		end
		return handle
	end,
}

-- Runs the real ProfileStore, used the way its tutorial says to. Constants are for its SetConstant.
function Fleet.profileStore(sourcePath: string, name: string?, constants: { [string]: number }?)
	return {
		name = name or "ProfileStore",
		sources = { init = fs.readFile(sourcePath) },
		takeoverAfter = function(_world: any): number
			return 0 -- it has its own rules, which the comparison measures rather than checks
		end,
		read = function(record: any): (any, number?, string?)
			local meta = record.MetaData
			if typeof(meta) ~= "table" or typeof(record.Data) ~= "table" or typeof(record.Data.Earned) ~= "number" then
				return nil, nil, nil
			end
			return record.Data, nil, if meta.ActiveSession then meta.ActiveSession[3] else nil
		end,
		open = function(world: any, storeName: string, player: any): any?
			local ProfileStore = world.soulStore
			world.profileStores = world.profileStores or {}
			local store = world.profileStores[storeName]
			if not store then
				for constant, value in pairs(constants or {}) do
					ProfileStore.SetConstant(constant, value)
				end
				store = ProfileStore.New(storeName, DEFAULTS)
				world.profileStores[storeName] = store
				-- The tutorial ends a session when its player leaves
				world.profilesByPlayer = world.profilesByPlayer or {}
				world.players.PlayerRemoving:Connect(function(leaving)
					for _, profile in ipairs(world.profilesByPlayer[leaving] or {}) do
						profile:EndSession()
					end
					world.profilesByPlayer[leaving] = nil
				end)
			end

			local handle: any = {}
			local profile = nil
			local ended, onEnded, lastReason = false, nil, nil
			local function finish(reason: string)
				if not ended then
					ended = true
					if onEnded then
						onEnded(reason)
					end
				end
			end
			function handle.load()
				local inGame = function()
					return player.Parent == world.players
				end
				profile = store:StartSessionAsync(tostring(player.UserId), {
					Cancel = function()
						return not inGame()
					end,
				})
				if not profile then
					local reason = if inGame() then "NoProfile" else "Cancelled"
					finish(reason)
					return false, reason
				end
				profile:AddUserId(player.UserId)
				profile:Reconcile()
				profile.OnLastSave:Connect(function(reason)
					lastReason = reason
				end)
				profile.OnSessionEnd:Connect(function()
					if lastReason == nil then
						finish("OwnershipLost")
					else
						finish(if lastReason == "External" then "HandedOver" else "Saved")
					end
				end)
				if not inGame() then
					profile:EndSession()
					return false, "Cancelled"
				end
				world.profilesByPlayer[player] = world.profilesByPlayer[player] or {}
				table.insert(world.profilesByPlayer[player], profile)
				return true
			end
			function handle.data()
				return if profile and profile:IsActive() then profile.Data else nil
			end
			function handle.read(path: { string })
				local node = handle.data()
				for _, key in ipairs(path) do
					node = node and node[key]
				end
				return node
			end
			function handle.set(path: { any }, value: any): boolean
				local node = handle.data()
				if not node then
					return false
				end
				for index = 1, #path - 1 do
					node = node[path[index]]
				end
				node[path[#path]] = value
				return true
			end
			-- Its guide for purchases: save, then wait to see the change in LastSavedData
			function handle.save(receipt: string?): boolean
				if not (profile and profile:IsActive()) then
					return false
				end
				profile:Save()
				local function isSaved(): boolean
					local receipts = profile.LastSavedData.Receipts
					return receipt ~= nil and receipts ~= nil and receipts[receipt] == true
				end
				local deadline = os.clock() + 30
				while profile:IsActive() and os.clock() < deadline do
					if isSaved() then
						return true
					end
					world.scheduler.task.wait(0.1)
				end
				return isSaved()
			end
			function handle.isActive(): boolean
				return profile ~= nil and profile:IsActive()
			end
			function handle.endNow()
				if profile then
					profile:EndSession()
				end
			end
			function handle.onSave(callback: (any) -> ())
				profile.OnSave:Connect(function()
					callback(profile.Data)
				end)
			end
			function handle.watch(_path: { string }, _callback: (any, any) -> ())
				-- It has no listeners. Games write their own.
			end
			function handle.onEnded(callback: (string) -> ())
				onEnded = callback
			end
			function handle.forget()
				onEnded = nil
			end
			return handle
		end,
	}
end

------------------------------------------------------------------------------------------------------------------ Fleet

function Fleet.new(settings: any)
	local scheduler = harness.newScheduler()
	scheduler.stepLimit = math.huge
	scheduler.allowBareYields = true -- what a module's own thread pool does, which ProfileStore has
	local backend = settings.backend or Fleet.SoulStore

	local fleet = {
		settings = settings,
		backend = backend,
		scheduler = scheduler,
		stores = {},
		messaging = {},
		random = newRandom(settings.seed or 20261102),
		servers = {},
		accounts = {},
		offline = {},
		problems = {},
		problemCount = 0,
		unsettled = 0,
		playing = true,
		experienceBudget = (settings.experienceRule or EXPERIENCE_BUDGET).base,
		experienceAt = 0,
		experienceThrottled = 0,
		-- Counts
		sessions = 0,
		points = 0,
		lostPoints = 0,
		worstLoss = 0,
		accountsWithLoss = 0,
		purchases = 0,
		purchasesConfirmed = 0,
		writes = 0,
		requests = 0,
		dropped = 0,
		takeovers = 0,
		peakQueue = 0,
		peakBacklog = 0,
		peakPerSecond = 0,
		peakBudgetUse = 0,
		peakExperienceUse = 0,
		peakPlayers = 0,
		playerSeconds = 0,
		crashes = 0,
		abandoned = 0,
		ended = {},
		loadFailed = {},
		logCounts = {},
		-- Timings
		loadTimes = newSample(),
		finalTimes = newSample(),
		saveGaps = newSample(),
	}

	-------------------------------------------------------------------------------------------------------- Checks

	function fleet:problem(kind: string, detail: string)
		self.problemCount += 1
		local entry = self.problems[kind]
		if not entry then
			entry = { count = 0, first = detail }
			self.problems[kind] = entry
		end
		entry.count += 1
	end

	local function accountOf(storeName: string, key: string)
		local name = storeName .. "/" .. key
		local account = fleet.accounts[name]
		if not account then
			account = {
				name = name,
				storeName = storeName,
				key = key,
				storedEarned = 0,
				storedSteps = 0,
				confirmedEarned = 0,
				receipts = {},
				granted = 0,
				died = 0,
				longestGap = 0,
			}
			fleet.accounts[name] = account
		end
		return account
	end

	-- Every write, as it lands
	local function onCommit(storeName: string, key: string, record: any)
		fleet.writes += 1
		local account = accountOf(storeName, key)
		local data, saveId, owner = backend.read(record)
		if not data then
			fleet:problem("a write lost its named fields", account.name)
			return
		end
		if saveId and account.saveId and saveId ~= account.saveId + 1 then
			fleet:problem(
				"SaveId did not go up by one",
				string.format("%s: %s then %s", account.name, tostring(account.saveId), tostring(saveId))
			)
		end
		account.saveId = saveId
		if data.Earned < account.storedEarned or data.Steps < account.storedSteps then
			fleet:problem(
				"a write rolled progress back",
				string.format("%s: %d then %d", account.name, account.storedEarned, data.Earned)
			)
		end

		local now = scheduler.now
		if owner and owner ~= data.Writer then
			-- A session claiming the record. Its own writes say who wrote them, which a claim's copy cannot yet.
			if account.owner and account.owner ~= owner then
				fleet.takeovers += 1
				if now - (account.lastWrite or 0) < account.takeoverAfter then
					fleet:problem(
						"a lock was taken too soon",
						string.format("%s after %.1fs", account.name, now - account.lastWrite)
					)
				end
			end
			account.owner = owner
			account.leftAt = nil
		elseif not owner and data.Writer ~= account.owner then
			-- A cancelled load letting go of a claim it may have made: nothing new may come with it
			if data.Earned ~= account.storedEarned then
				fleet:problem("a write by a session without the lock", account.name)
			end
			account.owner = nil
		else
			if data.Writer ~= account.owner then
				fleet:problem("a write by a session without the lock", account.name)
			end
			if owner and account.lastWrite then
				local gap = now - account.lastWrite
				fleet.saveGaps:add(gap)
				account.longestGap = math.max(account.longestGap, gap)
			end
			account.owner = owner
		end
		if not owner and account.leftAt then
			fleet.finalTimes:add(now - account.leftAt)
			account.leftAt = nil
		end
		account.lastWrite = now
		account.storedEarned = data.Earned
		account.storedSteps = data.Steps
	end

	-------------------------------------------------------------------------------------------------------- Network

	function fleet:populationNow(): number
		local total = 0
		for _, server in ipairs(self.servers) do
			if not server.dead then
				total += #server.world.players.members
			end
		end
		return total
	end

	local function takeExperienceBudget(): boolean
		local rule = settings.experienceRule or EXPERIENCE_BUDGET
		local perMinute = rule.base + rule.perPlayer * fleet:populationNow()
		local now = scheduler.now
		fleet.experienceBudget =
			math.min(perMinute, fleet.experienceBudget + (now - fleet.experienceAt) * perMinute / 60)
		fleet.experienceAt = now
		if fleet.experienceBudget < 1 then
			return false
		end
		fleet.experienceBudget -= 1
		return true
	end

	local function planRequest(server: any)
		local now = scheduler.now
		local random = fleet.random
		fleet.requests += 1

		-- How much of Roblox's limits this uses, by the minute
		local minute = now // 60
		if server.minute ~= minute then
			if server.minuteRequests then
				local players = math.max(server.minutePlayers, #server.visits)
				fleet.peakBudgetUse = math.max(
					fleet.peakBudgetUse,
					server.minuteRequests / (SERVER_BUDGET.base + SERVER_BUDGET.perPlayer * players)
				)
			end
			server.minute, server.minuteRequests = minute, 0
			server.minutePlayers = #server.visits
		end
		server.minuteRequests += 1
		if fleet.minute ~= minute then
			if fleet.minuteRequests then
				local rule = EXPERIENCE_BUDGET
				fleet.peakExperienceUse = math.max(
					fleet.peakExperienceUse,
					fleet.minuteRequests
						/ (rule.base + rule.perPlayer * math.max(fleet.minutePlayers, fleet:populationNow()))
				)
			end
			fleet.minute, fleet.minuteRequests = minute, 0
			fleet.minutePlayers = fleet:populationNow()
		end
		fleet.minuteRequests += 1
		local second = now // 1
		if server.second ~= second then
			server.second, server.secondRequests = second, 0
		end
		server.secondRequests += 1
		fleet.peakPerSecond = math.max(fleet.peakPerSecond, server.secondRequests)

		-- A server handles so many requests a second, and the rest wait their turn
		local rate = settings.requestsPerSecond or REQUESTS_PER_SECOND
		server.nextSlot = math.max(server.nextSlot or 0, now) + 1 / rate
		local waited = server.nextSlot - now
		fleet.peakBacklog = math.max(fleet.peakBacklog, waited * rate)

		local total = random.skewed(settings.requestTime or REQUEST_TIME, settings.requestSpread or REQUEST_SPREAD)
		local plan: any = { before = waited + total * 0.4, commit = total * 0.2, after = total * 0.4 }

		for _, outage in ipairs(settings.outages or {}) do
			if now >= outage.at and now < outage.at + outage.duration then
				if outage.hang then
					plan.before = outage.at + outage.duration - now + total
				else
					plan.fail = OUTAGE_ERROR
				end
				return plan
			end
		end

		if settings.failRate and random.chance(settings.failRate) then
			plan.fail = OUTAGE_ERROR
		elseif settings.lostResponseRate and random.chance(settings.lostResponseRate) then
			plan.failAfter = OUTAGE_ERROR
		elseif not takeExperienceBudget() then
			fleet.experienceThrottled += 1
			plan.fail = THROTTLED_ERROR
		end
		return plan
	end

	-------------------------------------------------------------------------------------------------------- Sessions

	local function onSessionEnded(session: any, reason: string)
		session.settled = true
		fleet.unsettled -= 1
		fleet.ended[reason] = (fleet.ended[reason] or 0) + 1
		session.server.open[session] = nil
		-- A real game kicks a player whose session is over while they are still in the server
		local visit = session.visit
		if not visit.gone and session.loaded and reason ~= "Saved" then
			fleet:leave(visit, "offline")
		end
	end

	local function seedNewPlayer(handle: any, session: any)
		if settings.blobChance and fleet.random.chance(settings.blobChance) then
			handle.set({ "Blob" }, string.rep("x", settings.blobBytes))
		end
		local roll = fleet.random.next()
		local count = if roll < 0.7 then 20 elseif roll < 0.95 then 150 else (settings.whaleItems or 1000)
		local items = {}
		for id = 1, count do
			items["S" .. id] = newItem(id)
		end
		handle.set({ "Items" }, items)
		handle.set({ "NextItem" }, count + 1)
		session.nextItem = count + 1
	end

	local function startSession(visit: any, storeName: string)
		local server = visit.server
		local world = server.world
		if not fleet.stores[storeName] then
			world.dataStoreService:GetDataStore(storeName, nil)
			local store = fleet.stores[storeName]
			store.afterCommit = function(key)
				onCommit(storeName, key, store.data[key]) -- what was stored, which is what a later read would see
			end
		end
		local account = accountOf(storeName, tostring(visit.user.id))
		account.takeoverAfter = backend.takeoverAfter(world)
		local handle = backend.open(world, storeName, visit.player)
		if not handle then
			fleet.loadFailed.NoSession = (fleet.loadFailed.NoSession or 0) + 1
			return
		end

		local session = { account = account, visit = visit, handle = handle, server = server, earned = 0, coins = 0 }
		table.insert(visit.sessions, session)
		server.open[session] = true
		fleet.sessions += 1
		fleet.unsettled += 1
		handle.onEnded(function(reason)
			onSessionEnded(session, reason)
		end)

		scheduler.task.spawn(function()
			local began = scheduler.now
			local loaded, reason = handle.load()
			if not loaded then
				if reason ~= "Cancelled" and reason ~= "AcquisitionUncertain" then
					fleet.loadFailed[tostring(reason)] = (fleet.loadFailed[tostring(reason)] or 0) + 1
				end
				if not visit.gone and not server.dead then
					fleet:leave(visit, "offline")
				end
				return
			end
			fleet.loadTimes:add(scheduler.now - began)
			if server.dead then
				return
			end

			local data = handle.data()
			session.loaded = true
			session.earned = data.Earned
			session.coins = data.Coins
			session.nextItem = data.NextItem
			session.owner = account.owner

			if data.Earned ~= account.storedEarned then
				fleet:problem("a session loaded something other than what is stored", account.name)
			end
			for receipt in pairs(account.receipts) do
				if not data.Receipts[receipt] then
					fleet:problem("a confirmed purchase is gone", account.name .. " " .. receipt)
				end
			end

			if data.NextItem == 1 then
				seedNewPlayer(handle, session)
			end

			-- The games' usual hooks. This one folds in-memory progress into the copy being saved, and says who wrote it.
			local playedFrom = scheduler.now
			local basePlaytime = data.Playtime
			local owner = account.owner
			handle.onSave(function(copy)
				copy.Playtime = basePlaytime + (scheduler.now - playedFrom)
				copy.Writer = owner
			end)
			handle.watch({ "Coins" }, function(old, new)
				if new ~= session.coins or old > new then
					fleet:problem("a listener saw the wrong values", tostring(old) .. " then " .. tostring(new))
				end
			end)
		end)
	end

	-- One player's turn: what they do during this PLAY_STEP seconds
	local function playTurn(session: any)
		local handle = session.handle
		if not session.loaded or not handle.isActive() then
			return
		end
		local random = fleet.random
		local account = session.account

		-- Points, the thing players notice if they vanish
		if random.chance(0.8) then
			local wanted = session.earned + 1
			if handle.set({ "Earned" }, wanted) then
				session.earned = wanted
				account.granted += 1
				fleet.points += 1
			end
		end
		if random.chance(0.3) then
			session.coins += 5
			if not handle.set({ "Coins" }, session.coins) then
				session.coins -= 5
			end
		end

		-- Written straight to the live table, as games do
		local data = handle.data()
		if data then
			data.Steps += 1
			data.Quests.Counts.Clears += 1
		end

		-- Reads
		handle.read({ "Settings", "Volume" })
		handle.read({ "Quests", "Counts", "Raises" })

		if random.chance(0.03) then
			local id = session.nextItem
			if handle.set({ "Items", "S" .. id }, newItem(id)) then
				session.nextItem = id + 1
				handle.set({ "NextItem" }, id + 1)
			end
		end

		-- A plain array that grows and is trimmed
		if random.chance(0.05) and data then
			local history = data.History
			handle.set({ "History", #history + 1 }, { At = 1700000000, Kind = "Clear" })
			if #history > 30 then
				table.remove(history, 1)
			end
		end

		-- The mistakes games make through the live table, which no setter can stop
		if settings.oddTables and data and random.chance(0.02) then
			data[1] = "stray" -- at the top of the save, next to everything that matters
			data.Quests.Done[1] = "stray"
			-- selene: allow(mixed_table)
			data.Settings.Oops = { "a", "b", Name = "c" }
			data.Quests.Slots = { [1] = "a", [3] = "c" }
		end

		-- A purchase: only a confirmed save lets it through, as ProcessReceipt should
		if random.chance(settings.purchaseChance or PLAY_STEP / 400) then
			fleet.purchases += 1
			local receipt = "P" .. fleet.purchases
			handle.set({ "Receipts", receipt }, true)
			local earnedAtSave = session.earned
			scheduler.task.spawn(function()
				if handle.save(receipt) then
					fleet.purchasesConfirmed += 1
					account.receipts[receipt] = true
					account.confirmedEarned = math.max(account.confirmedEarned, earnedAtSave)
				end
			end)
		end
	end

	-------------------------------------------------------------------------------------------------------- Servers

	local function gameLoop(server: any)
		while not server.dead do
			scheduler.task.wait(PLAY_STEP)
			if server.dead then
				return
			end
			local now = scheduler.now
			fleet.peakQueue = math.max(fleet.peakQueue, server.world.queuedRequests)
			fleet.playerSeconds += #server.visits * PLAY_STEP
			if fleet.playing then
				for _, visit in ipairs(table.clone(server.visits)) do
					if now >= visit.leavesAt and visit.overlapping then
						fleet:leave(visit, "gone")
					elseif now >= visit.leavesAt and fleet.random.chance(0.05) then
						-- A teleport can land on the next server a moment before this one sees the player go
						visit.overlapping = true
						visit.leavesAt = now + fleet.random.between(1, 6)
						visit.user.stillOn = server
						fleet:returnToGame(visit.user, server)
					elseif now >= visit.leavesAt then
						fleet:leave(visit)
					elseif not visit.gone then
						for _, session in ipairs(visit.sessions) do
							playTurn(session)
						end
					end
				end
				-- New arrivals, up to the server's size
				if not server.closing then
					local arrivals = math.min(server.capacity - #server.visits, server.arrivalsPerStep)
					for _ = 1, arrivals do
						local user = table.remove(fleet.offline)
						if not user then
							break
						elseif user.stillOn == server then
							table.insert(fleet.offline, 1, user) -- Roblox does not put one player on a server twice
						else
							fleet:arrive(user, server)
						end
					end
				end
			end
		end
	end

	function fleet:addServer(): any
		local index = #self.servers + 1
		local capacity = settings.playersPerServer
		local server: any = {
			index = index,
			capacity = capacity,
			visits = {},
			open = {},
			dead = false,
			arrivalsPerStep = settings.arrivalsPerStep or math.max(1, math.ceil(capacity * PLAY_STEP / 90)),
		}
		local world = harness.newWorld({
			scheduler = scheduler,
			stores = self.stores,
			messaging = self.messaging,
			jobId = "job-" .. index,
			seed = index * 7919,
			live = true,
			clockOffset = self.random.between(-(settings.clockSkew or 0), settings.clockSkew or 0),
			sources = backend.sources,
			onLog = function(line)
				local kind = string.gsub(line, "^%[[%a ]+%]:? ", "")
				kind = string.gsub(kind, "'[^']*' %(%-?%d+%)", "someone")
				kind = string.gsub(kind, "Player%d+", "someone")
				kind = string.gsub(kind, "%d+", "N")
				kind = string.sub(kind, 1, 60)
				fleet.logCounts[kind] = (fleet.logCounts[kind] or 0) + 1
			end,
		})
		world.spendBudget = true
		world.budget = settings.startupBudget or STARTUP_BUDGET
		world.budgetAt = scheduler.now
		world.budgetRule = settings.budgetRule or SERVER_BUDGET
		world.network = function()
			return planRequest(server)
		end
		world.onDropped = function()
			fleet.dropped += 1
		end
		server.world = world
		table.insert(self.servers, server)
		scheduler.task.spawn(gameLoop, server)
		return server
	end

	function fleet:pickServer(user: any, except: any?): any?
		local best, room = nil, 0
		for _, server in ipairs(self.servers) do
			if server ~= except and server ~= user.stillOn and not server.dead and not server.closing then
				local free = server.capacity - #server.visits
				if free > room then
					best, room = server, free
				end
			end
		end
		return best
	end

	function fleet:arrive(user: any, server: any)
		local visit = {
			user = user,
			server = server,
			player = server.world:player(user.id),
			sessions = {},
			gone = false,
			leavesAt = scheduler.now + self.random.skewed(settings.medianSession or 480, 1),
		}
		table.insert(server.visits, visit)
		self.peakPlayers = math.max(self.peakPlayers, self:populationNow())
		for _, storeName in ipairs(settings.storeNames or { "Profiles" }) do
			startSession(visit, storeName)
		end
	end

	-- A player leaving, and what they do next
	function fleet:leave(visit: any, nextMove: string?)
		if visit.gone then
			return
		end
		visit.gone = true
		if visit.overlapping then
			nextMove = "gone"
			visit.user.stillOn = nil
		end
		local server = visit.server
		local index = table.find(server.visits, visit)
		if index then
			table.remove(server.visits, index)
		end
		local roll = self.random.next()
		local move = nextMove or (if roll < 0.25 then "hop" elseif roll < 0.35 then "rejoin" else "offline")
		-- Some games end the session themselves before a teleport, as they are told to
		local endsFirst = move == "hop" and self.random.chance(0.3)
		for _, session in ipairs(visit.sessions) do
			if session.loaded then
				if session.account.owner == session.owner then
					session.account.leftAt = session.account.leftAt or scheduler.now
				end
				if endsFirst then
					scheduler.task.spawn(session.handle.endNow)
				end
			end
		end
		server.world:remove(visit.player)

		if not self.playing then
			table.insert(self.offline, visit.user)
			return
		end

		if move == "gone" then
			return -- already somewhere else
		elseif move == "offline" then
			-- Back of the line, so the same people do not come straight back
			table.insert(self.offline, 1, visit.user)
		elseif move == "hop" then
			scheduler.task.delay(self.random.between(1, 8), function()
				self:returnToGame(visit.user, server)
			end)
		else
			scheduler.task.delay(self.random.between(0.5, 5), function()
				self:returnToGame(visit.user, nil)
			end)
		end
	end

	function fleet:returnToGame(user: any, leftServer: any?)
		if not self.playing then
			table.insert(self.offline, user)
			return
		end
		local server = self:pickServer(user, leftServer)
		if server then
			self:arrive(user, server)
		else
			table.insert(self.offline, 1, user)
		end
	end

	-- Nothing more runs on this server. What its sessions held in memory is gone with them.
	local function killServer(server: any)
		server.dead = true
		server.world:crash()
		for session in pairs(server.open) do
			session.settled = true
			fleet.unsettled -= 1
			fleet.abandoned += 1
			session.account.died += 1
			session.handle.forget()
		end
		table.clear(server.open)
	end

	-- The process dies, nothing is saved, and the players come back somewhere else
	function fleet:crash(server: any)
		self.crashes += 1
		for _, visit in ipairs(table.clone(server.visits)) do
			visit.gone = true
			if visit.user.stillOn == server then
				visit.user.stillOn = nil
			elseif not visit.overlapping then
				scheduler.task.delay(self.random.between(1, 20), function()
					self:returnToGame(visit.user, server)
				end)
			end
		end
		server.visits = {}
		killServer(server)
		self:addServer()
	end

	-- A real shutdown: BindToClose runs and players are moved out over the next few seconds. 30 seconds later it is gone.
	function fleet:shutDown(server: any, moveWindow: number?)
		server.closing = true
		for session in pairs(server.open) do
			if session.loaded and session.account.owner == session.owner then
				session.account.leftAt = session.account.leftAt or scheduler.now
			end
		end
		for _, callback in ipairs(server.world.closers) do
			scheduler.task.spawn(callback)
		end
		for _, visit in ipairs(table.clone(server.visits)) do
			scheduler.task.delay(self.random.between(0, moveWindow or 20), function()
				self:leave(visit, "hop")
			end)
		end
		scheduler.task.delay(30, function()
			-- Roblox gives BindToClose 30 seconds. Anything not settled by now did not make it.
			killServer(server)
		end)
	end

	------------------------------------------------------------------------------------------------------------ End

	-- Stops play, sends everyone home, and waits for every session to end
	function fleet:drain(timeout: number?)
		self.playing = false
		local deadline = scheduler.now + (timeout or 900)
		for _, server in ipairs(self.servers) do
			if not server.dead then
				for _, visit in ipairs(table.clone(server.visits)) do
					scheduler.task.delay(self.random.between(0, 30), function()
						self:leave(visit)
					end)
				end
			end
		end
		-- Some modules say a session has ended when its final save starts, so the data store has the last word
		scheduler:runUntil(function()
			if scheduler.now >= deadline then
				return true
			end
			for _, server in ipairs(self.servers) do
				if not server.dead and #server.visits > 0 then
					return false
				end
			end
			if self.unsettled > 0 then
				return false
			end
			for _, account in pairs(self.accounts) do
				if account.owner and account.died == 0 then
					return false
				end
			end
			return true
		end, (timeout or 900) + 60)
		if self.unsettled > 0 then
			self:problem("sessions never ended", tostring(self.unsettled) .. " still open at the end")
		end
	end

	-- The record against what the game was promised
	function fleet:verify()
		for _, account in pairs(self.accounts) do
			local record = self.stores[account.storeName].data[account.key]
			local data = if record then backend.read(record) else nil
			if data then
				if data.Earned ~= account.storedEarned then
					self:problem("the record is not what was last written", account.name)
				end
				if data.Earned < account.confirmedEarned then
					self:problem("a confirmed save was lost", account.name)
				end
				for receipt in pairs(account.receipts) do
					if not data.Receipts[receipt] then
						self:problem("a confirmed purchase is gone", account.name .. " " .. receipt)
					end
				end
				local _, _, owner = backend.read(record)
				if owner and account.died == 0 then
					self:problem("a lock was never released", account.name)
				end
				local lost = account.granted - data.Earned
				if lost > 0 then
					self.lostPoints += lost
					self.accountsWithLoss += 1
					self.worstLoss = math.max(self.worstLoss, lost / math.max(account.died, 1))
					if account.died == 0 then
						self:problem(
							"progress was lost though its server never died",
							string.format("%s lost %d", account.name, lost)
						)
					end
				end
			elseif record then
				self:problem("a record has lost its shape", account.name)
			elseif account.granted > 0 then
				self:problem("a record that earned progress does not exist", account.name)
			end
		end
		for _, server in ipairs(self.servers) do
			local cache = server.world.sessionCache
			if cache and not server.dead and #cache.getAll() > 0 then
				self:problem("a server still holds sessions after everyone left", "server " .. server.index)
			end
		end
	end

	-- How many players had to wait longer than this for a save, however many saves they got
	function fleet:playersWaitingOver(seconds: number): (number, number)
		local over, total = 0, 0
		for _, account in pairs(self.accounts) do
			total += 1
			if account.longestGap > seconds then
				over += 1
			end
		end
		return over, total
	end

	function fleet:report(name: string, seconds: number)
		local function listCounts(counts: any): string
			local names = {}
			for key, count in pairs(counts) do
				table.insert(names, key .. " " .. count)
			end
			table.sort(names)
			return if #names > 0 then table.concat(names, ", ") else "none"
		end
		local conflicts = 0
		for _, store in pairs(self.stores) do
			conflicts += store.conflicts
		end
		local waiting, accounts = self:playersWaitingOver(45)
		print(
			string.format(
				"\n=== %s, on %s  (%.0fs of real time for %.0f simulated minutes)",
				name,
				backend.name,
				seconds,
				scheduler.now / 60
			)
		)
		print(
			string.format(
				"    %d servers, %d players at the peak, %d sessions, %d accounts, %.0f player-hours",
				#self.servers,
				self.peakPlayers,
				self.sessions,
				accounts,
				self.playerSeconds / 3600
			)
		)
		print(
			string.format(
				"    Efficient: %d requests, %.2f a player a minute, at most %.0f%% of a server's limit and %.0f%% of the experience's, busiest second on a server %d",
				self.requests,
				self.requests / math.max(self.playerSeconds / 60, 1),
				self.peakBudgetUse * 100,
				self.peakExperienceUse * 100,
				self.peakPerSecond
			)
		)
		print(
			string.format(
				"    %d writes, %d collisions, %d dropped by a full queue, %d refused by the experience limit, longest queue %d, backlog %.0f",
				self.writes,
				conflicts,
				self.dropped,
				self.experienceThrottled,
				self.peakQueue,
				self.peakBacklog
			)
		)
		print(
			string.format(
				"    No loss: %d points earned, %d lost, on %d accounts (worst %.0f per dead session). Purchases: %d, %d confirmed",
				self.points,
				self.lostPoints,
				self.accountsWithLoss,
				self.worstLoss,
				self.purchases,
				self.purchasesConfirmed
			)
		)
		print(
			string.format(
				"    Fair: between saves median %.1fs, 99%% %.1fs, worst %.1fs. %d of %d players ever waited over 45s",
				self.saveGaps:percentile(0.5),
				self.saveGaps:percentile(0.99),
				self.saveGaps.largest,
				waiting,
				accounts
			)
		)
		print(
			string.format(
				"    Load: median %.2fs, 99%% %.2fs, worst %.1fs. Final save: median %.2fs, 99%% %.2fs, worst %.1fs",
				self.loadTimes:percentile(0.5),
				self.loadTimes:percentile(0.99),
				self.loadTimes.largest,
				self.finalTimes:percentile(0.5),
				self.finalTimes:percentile(0.99),
				self.finalTimes.largest
			)
		)
		print(
			string.format(
				"    Takeovers %d. Crashes %d, sessions lost with them %d",
				self.takeovers,
				self.crashes,
				self.abandoned
			)
		)
		print("    Sessions ended: " .. listCounts(self.ended))
		print("    Loads that failed: " .. listCounts(self.loadFailed))
		print("    Output: " .. listCounts(self.logCounts))
		if self.problemCount > 0 then
			print("    BROKEN PROMISES:")
			for kind, entry in pairs(self.problems) do
				print(string.format("      %dx %s (first: %s)", entry.count, kind, entry.first))
			end
		end
	end

	return fleet
end

-- A table of results, in Markdown
function Fleet.printTableHeader()
	print(
		"| Scenario | Module | Progress lost | Sessions that lost their lock | Load seconds: median / 99% / worst | Final save seconds: median / worst | Requests a player a minute | Peak of a server's limit | Seconds between saves: median / worst | Players who waited over 45s | Broken promises |"
	)
	print("|---|---|---|---|---|---|---|---|---|---|---|")
end

function Fleet.tableRow(name: string, fleet: any): string
	local waiting, accounts = fleet:playersWaitingOver(45)
	return string.format(
		"| %s | %s | %d of %d (%.2f%%) | %d | %.2f / %.1f / %.0f | %.2f / %.0f | %.2f | %.0f%% | %.0f / %.0f | %d of %d | %d |",
		name,
		fleet.backend.name,
		fleet.lostPoints,
		fleet.points,
		fleet.lostPoints / math.max(fleet.points, 1) * 100,
		fleet.ended.OwnershipLost or 0,
		fleet.loadTimes:percentile(0.5),
		fleet.loadTimes:percentile(0.99),
		fleet.loadTimes.largest,
		fleet.finalTimes:percentile(0.5),
		fleet.finalTimes.largest,
		fleet.requests / math.max(fleet.playerSeconds / 60, 1),
		fleet.peakBudgetUse * 100,
		fleet.saveGaps:percentile(0.5),
		fleet.saveGaps.largest,
		waiting,
		accounts,
		fleet.problemCount
	)
end

-- Runs one scenario from start to finish
function Fleet.run(settings: any): any
	local began = os.clock()
	local fleet = Fleet.new(settings)
	for _ = 1, settings.servers do
		fleet:addServer()
	end
	local population = settings.servers * settings.playersPerServer * (settings.populationFactor or 2)
	for userId = population // 1, 1, -1 do
		table.insert(fleet.offline, { id = userId + 1000 })
	end
	for _, event in ipairs(settings.events or {}) do
		fleet.scheduler.task.delay(event.at, function()
			event.run(fleet)
		end)
	end
	fleet.scheduler:advance(settings.minutes * 60)
	fleet:drain(settings.drainTimeout)
	fleet:verify()
	fleet.realSeconds = os.clock() - began
	return fleet
end

-- The first server still running, and a fresh one to take its players
local function closeOneServer(fleet: any)
	for _, server in ipairs(fleet.servers) do
		if not server.dead and not server.closing then
			fleet:addServer()
			fleet:shutDown(server)
			return
		end
	end
end

local function crashOneServer(fleet: any)
	local live = {}
	for _, server in ipairs(fleet.servers) do
		if not server.dead then
			table.insert(live, server)
		end
	end
	fleet:crash(live[fleet.random.whole(1, #live)])
end

local function expectNoLoss(fleet: any)
	harness.equal(fleet.lostPoints, 0, "Progress lost")
	harness.equal(fleet.ended.OwnershipLost or 0, 0, "Sessions that lost their lock")
	harness.equal(fleet.ended.LeaseExpired or 0, 0, "Sessions that ran out of lease")
	harness.equal(next(fleet.loadFailed), nil, "Loads that failed")
end

local function expectCalm(fleet: any)
	expectNoLoss(fleet)
	harness.equal(fleet.takeovers, 0, "No lock should need taking over")
	harness.equal(fleet.dropped, 0, "No request should be dropped")
	harness.expect(fleet.saveGaps.largest <= 36, "Autosaves ran late: " .. fleet.saveGaps.largest)
end

--[[
	Every scenario, at one scale.
		size: { servers, players, minutes, largestPlayers, whaleItems }
	Each has a name, the settings to run it with, and a check that says what it may and may not cost.
]]
function Fleet.scenarios(size: any): { any }
	local function repeated(count: number, every: number, run: (any) -> ())
		local events = {}
		for round = 1, count do
			table.insert(events, { at = round * every, run = run })
		end
		return events
	end

	return {
		-- The ordinary day, at different sizes of server
		{ name = "a healthy popular game", settings = {}, check = expectCalm },
		{
			name = "small servers",
			settings = { servers = size.servers * 3, playersPerServer = 10 },
			check = expectCalm,
		},
		{
			name = "the largest servers",
			settings = { servers = math.max(1, size.servers // 3), playersPerServer = size.largestPlayers },
			check = expectCalm,
		},
		{
			name = "two data stores a player",
			settings = { storeNames = { "Profiles", "Inventory" } },
			check = expectCalm,
		},
		-- A game with careless code, writing tables a data store cannot hold as they are. Nobody's progress may suffer.
		{
			name = "a game writing odd tables",
			settings = { oddTables = true },
			check = expectCalm,
		},
		-- Lobby to match and back: every join finds the last server's lock, or just misses it
		{
			name = "players hopping servers all the time",
			settings = { medianSession = 45 },
			check = function(fleet)
				expectNoLoss(fleet)
				harness.equal(fleet.takeovers, 0, "A hop should never need a takeover")
			end,
		},
		-- A new server filling in moments, as after a migration
		{
			name = "everyone joining at once",
			settings = { arrivalsPerStep = 1000, medianSession = 900 },
			check = expectCalm,
		},
		-- An update: every server closes, and everyone moves to new ones within seconds
		{
			name = "every server shutting down at once",
			settings = {
				playersPerServer = size.largestPlayers,
				servers = math.max(1, size.servers // 3),
				events = {
					{
						at = size.minutes * 30,
						run = function(fleet)
							local closing = table.clone(fleet.servers)
							for _ = 1, #closing do
								fleet:addServer()
							end
							for _, server in ipairs(closing) do
								fleet:shutDown(server)
							end
						end,
					},
				},
			},
			check = function(fleet)
				expectNoLoss(fleet)
				harness.equal(fleet.abandoned, 0, "Every final save should land inside the 30 seconds")
			end,
		},
		{
			name = "servers closing a few at a time",
			settings = { events = repeated(8, size.minutes * 6, closeOneServer) },
			check = function(fleet)
				expectNoLoss(fleet)
				harness.equal(fleet.abandoned, 0, "Every final save should land inside the 30 seconds")
			end,
		},
		-- The data store having a bad day
		{
			name = "1 request in 100 fails, and 1 in 200 loses its response",
			settings = { failRate = 0.01, lostResponseRate = 0.005 },
			check = expectNoLoss,
		},
		{
			name = "1 request in 5 fails, and 1 in 20 loses its response",
			settings = { failRate = 0.2, lostResponseRate = 0.05 },
			check = expectNoLoss,
		},
		{
			name = "requests taking 5 seconds",
			settings = { requestTime = 5, requestSpread = 0.5 },
			check = expectNoLoss,
		},
		{
			name = "a 2 minute outage",
			settings = { outages = { { at = size.minutes * 30, duration = 120 } } },
			check = expectNoLoss,
		},
		-- Longer than the lease, so sessions stop accepting changes. Everything they did accept still lands.
		{
			name = "a 10 minute outage",
			settings = {
				minutes = size.minutes + 10,
				outages = { { at = size.minutes * 30, duration = 600 } },
			},
			check = function(fleet)
				harness.equal(fleet.lostPoints, 0, "Progress lost")
				harness.equal(fleet.ended.OwnershipLost or 0, 0, "Sessions that lost their lock")
			end,
		},
		{
			name = "requests hanging for 3 minutes",
			settings = {
				minutes = size.minutes + 3,
				outages = { { at = size.minutes * 30, duration = 180, hang = true } },
			},
			check = function(fleet)
				harness.equal(fleet.lostPoints, 0, "Progress lost")
			end,
		},
		-- A server dying takes with it only what it had not saved
		{
			name = "servers crashing",
			settings = { events = repeated(6, size.minutes * 8, crashOneServer) },
			check = function(fleet)
				harness.expect(fleet.takeovers > 0, "These crashes should need takeovers")
				-- 0.4 points a second, for at most an autosave interval plus a few seconds
				harness.expect(
					fleet.worstLoss <= 25,
					"More was lost than an autosave interval's worth: " .. fleet.worstLoss
				)
			end,
		},
		-- Roblox's clocks are close but not the same
		{
			name = "servers whose clocks disagree by a minute",
			settings = { clockSkew = 60 },
			check = function(fleet)
				expectNoLoss(fleet)
				harness.equal(fleet.takeovers, 0, "A wrong clock should not cost anyone their lock")
			end,
		},
		-- Budget used up by something else, leaving a trickle for saves. Everyone must still get their turn.
		{
			name = "one save a second for a whole server",
			settings = {
				servers = 1,
				playersPerServer = 100,
				medianSession = 36000,
				minutes = 12,
				arrivalsPerStep = 100,
				events = {
					{
						at = 60,
						run = function(fleet)
							local world = fleet.servers[1].world
							world.budget = 0
							world.budgetRule = { base = 60, perPlayer = 0, capMinutes = 1 / 60 }
						end,
					},
				},
			},
			check = function(fleet)
				harness.equal(fleet.ended.LeaseExpired or 0, 0, "Nobody's lease should run out")
				harness.equal(fleet.lostPoints, 0, "Progress lost")
				harness.expect(
					fleet.saveGaps.largest <= 160,
					"Someone waited too long for a save: " .. fleet.saveGaps.largest
				)
			end,
		},
		-- Roblox allows a key 4 MB of writes a minute, and these saves go over that with a 30 second autosave
		{
			name = "saves too big for every autosave",
			settings = { blobBytes = 3 * 1024 * 1024, blobChance = 0.1, whaleItems = 150 },
			check = expectNoLoss,
		},
		-- A game with so many players that the experience's own limit matters
		{
			name = "the experience running out of write budget",
			settings = { experienceRule = { base = size.servers * 10, perPlayer = 1 }, drainTimeout = 3600 },
			check = function(fleet)
				harness.equal(fleet.lostPoints, 0, "Progress lost")
				harness.expect(fleet.experienceThrottled > 0, "This should reach the limit")
			end,
		},
	}
end

-- Fills in what a scenario leaves out
function Fleet.settingsFor(scenario: any, size: any, backend: any?): any
	local settings = {
		servers = size.servers,
		playersPerServer = size.players,
		minutes = size.minutes,
		whaleItems = size.whaleItems,
		populationFactor = size.populationFactor,
		backend = backend,
	}
	for key, value in pairs(scenario.settings) do
		settings[key] = value
	end
	settings.seed = settings.seed or (#scenario.name * 7919)
	return settings
end

return Fleet
