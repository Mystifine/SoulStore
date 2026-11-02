-- Shared by every test file. Runs the real files in src/ with virtual time and in-memory Roblox services. It never
-- contacts Roblox or reads or writes real player saves.
--
-- The fake data store follows what real data stores were seen to do, which tests/studio/DataStoreProbe.server.luau
-- checks, and Roblox's documentation for the rest:
-- https://create.roblox.com/docs/cloud-services/data-stores/error-codes-and-limits
-- https://create.roblox.com/docs/reference/engine/classes/GlobalDataStore
local fs = require("@lune/fs")
local luau = require("@lune/luau")

local BASE_TIME = 1700000000
local MAX_VALUE_BYTES = 4194304
local MAX_USER_IDS = 4
local MAX_METADATA_BYTES = 300
local MAX_QUEUED_REQUESTS = 30
local KEY_WRITE_BYTES_PER_MINUTE = 4 * 1024 * 1024

-- The module's children, in the order they depend on each other
local MODULES = { "Config", "DeepCopyUtil", "Types", "Logger", "DataValidator", "SessionCache", "Session", "Reset" }

local function readModuleSources(root)
	local sources = { init = fs.readFile(root .. "/init.luau") }
	for _, name in ipairs(MODULES) do
		sources[name] = fs.readFile(root .. "/" .. name .. ".luau")
	end
	return sources
end

local defaultSources = readModuleSources("src")

local function copy(value, seen)
	if typeof(value) == "buffer" then
		return buffer.fromstring(buffer.tostring(value))
	elseif type(value) ~= "table" then
		return value
	end
	seen = seen or {}
	if seen[value] then
		return seen[value]
	end
	-- Cloned, so that it keeps its length, which decides how a data store treats it
	local result = table.clone(value)
	seen[value] = result
	for key, child in pairs(value) do
		if type(key) == "table" then
			result[key] = nil
			result[copy(key, seen)] = copy(child, seen)
		elseif type(child) == "table" or typeof(child) == "buffer" then
			result[key] = copy(child, seen)
		end
	end
	return result
end

local function expect(condition, message)
	assert(condition, message or "Expectation failed")
end

local function equal(actual, expected, message)
	assert(
		actual == expected,
		(message or "Values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual)
	)
end

-- Roblox treats these like the transform itself failing: it prints this, raises nothing and writes nothing.
local TRANSFORM_FAILED = "Transform function error "

-- What a key becomes when its table is stored as a dictionary
local function storedKeyName(key)
	local kind = typeof(key)
	if kind == "string" then
		return key
	elseif kind == "number" then
		if math.abs(key) == math.huge then
			return "-9223372036854775808"
		end
		return string.format("%d", (math.modf(key))) -- 1.9 comes back as "1"
	elseif kind == "table" and key._instance then
		return "<Instance> (" .. tostring(key.Name) .. ")"
	end
	return "<Table> (" .. tostring(key) .. ")"
end

-- Stores a value the way a data store does: raises what Roblox raises, and hands back what a later read would see.
local function serialize(value, ancestors)
	local kind = typeof(value)
	if kind == "string" then
		if not utf8.len(value) then
			error("104: Cannot store  in data store. Data stores can only accept valid UTF-8 characters.", 0)
		end
		return value, #value
	elseif kind == "number" then
		return value, 8 -- NaN and infinity come back as they went in
	elseif kind == "boolean" then
		return value, 5
	elseif kind == "buffer" then
		return buffer.fromstring(buffer.tostring(value)), buffer.len(value)
	elseif kind == "thread" then
		return nil, 0 -- left out without a word
	elseif kind ~= "table" or value._instance then
		error("104: Cannot store  in data store. Data stores can only accept valid UTF-8 characters.", 0)
	end

	if ancestors[value] then
		error(TRANSFORM_FAILED .. "tables cannot be cyclic", 0)
	end
	ancestors[value] = true

	for key in pairs(value) do
		local keyKind = typeof(key)
		if keyKind == "boolean" then
			error(TRANSFORM_FAILED .. "Invalid table key type used", 0)
		elseif keyKind == "string" and not utf8.len(key) then
			error("104: Cannot store  in data store. Data stores can only accept valid UTF-8 characters.", 0)
		end
	end

	local result, size = table.create(#value), 2
	if #value > 0 then
		-- An array: it runs as far as the table's length, so every other key is lost, and a gap can cut it short
		for index = 1, #value do
			if value[index] ~= nil then
				local child, childSize = serialize(value[index], ancestors)
				result[index] = child
				size += childSize + 1
			end
		end
	else
		-- A dictionary: number keys come back as whole-number strings, so 1.1 and 1.9 land on the same key
		for key, child in pairs(value) do
			local stored, childSize = serialize(child, ancestors)
			local storedKey = storedKeyName(key)
			if stored ~= nil and result[storedKey] == nil then
				result[storedKey] = stored
				size += childSize + #storedKey + 4
			end
		end
	end

	ancestors[value] = nil
	return result, size
end

local function checkKeyAttributes(userIds, metadata)
	if userIds ~= nil then
		if typeof(userIds) ~= "table" then
			error("513: Attribute userId format is invalid.", 0)
		end
		if #userIds > MAX_USER_IDS then
			error("512: UserID size exceeds " .. MAX_USER_IDS .. " limit.", 0)
		end
		for _, userId in ipairs(userIds) do
			if typeof(userId) ~= "number" then
				error("513: Attribute userId format is invalid.", 0)
			end
		end
	end
	if metadata ~= nil then
		if typeof(metadata) ~= "table" then
			error("513: Attribute metadata format is invalid.", 0)
		end
		local _, size = serialize(metadata, {})
		if size > MAX_METADATA_BYTES then
			error("511: Metadata attribute size exceeds " .. MAX_METADATA_BYTES .. " limit.", 0)
		end
	end
end

-- A transform failing is silent on Roblox, so each test fails if one does, unless it set out to cause that.
local transformFailures = {}
local transformFailuresExpected = false

local function newScheduler()
	local scheduler = { now = 0, queue = {}, deferred = {}, nextId = 0, errors = {}, guid = 0, stepLimit = 500000 }

	-- The queue is a binary heap, ordered by when each thread is due and then by which was queued first
	local function comesFirst(a, b)
		return a.due < b.due or (a.due == b.due and a.id < b.id)
	end

	local function pushItem(item)
		local queue = scheduler.queue
		local index = #queue + 1
		queue[index] = item
		while index > 1 do
			local parent = index // 2
			if not comesFirst(queue[index], queue[parent]) then
				break
			end
			queue[index], queue[parent] = queue[parent], queue[index]
			index = parent
		end
	end

	local function popItem()
		local queue = scheduler.queue
		local count = #queue
		local top = queue[1]
		queue[1] = queue[count]
		queue[count] = nil
		count -= 1
		local index = 1
		while true do
			local left, right, best = index * 2, index * 2 + 1, index
			if left <= count and comesFirst(queue[left], queue[best]) then
				best = left
			end
			if right <= count and comesFirst(queue[right], queue[best]) then
				best = right
			end
			if best == index then
				return top
			end
			queue[index], queue[best] = queue[best], queue[index]
			index = best
		end
	end

	function scheduler:enqueue(thread, due, arguments, deferred)
		self.nextId += 1
		local item = {
			thread = thread,
			due = due,
			id = self.nextId,
			arguments = arguments or { n = 0 },
		}
		pushItem(item)
		if deferred then
			table.insert(self.deferred, item)
		end
	end

	-- Runs what task.defer has queued, as Roblox does once the handlers for an event have finished
	function scheduler:flushDeferred()
		local index = 1
		while index <= #self.deferred do
			local item = self.deferred[index]
			index += 1
			if not item.done then
				item.done = true
				self:resume(item.thread, item.arguments)
			end
		end
		table.clear(self.deferred)
	end

	function scheduler:resume(thread, arguments)
		if coroutine.status(thread) == "dead" then
			return
		end
		local result = table.pack(coroutine.resume(thread, table.unpack(arguments, 1, arguments.n)))
		if not result[1] then
			table.insert(self.errors, tostring(result[2]) .. "\n" .. debug.traceback(thread))
			return
		end
		if coroutine.status(thread) == "suspended" then
			local request = result[2]
			if (type(request) ~= "table" or not request.event) and not self.allowBareYields then
				table.insert(self.errors, "Unexpected coroutine yield")
			end
		end
	end

	function scheduler:spawn(callback, ...)
		local thread = if type(callback) == "thread" then callback else coroutine.create(callback)
		self:resume(thread, table.pack(...))
		return thread
	end

	function scheduler:runUntil(predicate, timeout)
		local deadline = self.now + (timeout or 600)
		local steps = 0
		while not predicate() do
			if #self.errors > 0 then
				error(table.concat(self.errors, "\n"), 0)
			end
			local item = popItem()
			if not item or item.due > deadline then
				error("Virtual scheduler timed out at " .. tostring(self.now), 0)
			end
			self.now = math.max(self.now, item.due)
			if not item.done then
				item.done = true
				self:resume(item.thread, item.arguments)
			end
			steps += 1
			assert(steps < self.stepLimit, "Virtual scheduler exceeded step limit")
		end
		if #self.errors > 0 then
			error(table.concat(self.errors, "\n"), 0)
		end
	end

	function scheduler:call(callback)
		local done = false
		local result
		self:spawn(function()
			result = table.pack(callback())
			done = true
		end)
		self:runUntil(function()
			return done
		end)
		return table.unpack(result, 1, result.n)
	end

	function scheduler:advance(seconds)
		local due = self.now + seconds
		self:runUntil(function()
			return self.now >= due
		end, seconds + 1)
	end

	local taskMock = {}
	-- Registers itself, as Roblox's does, so that it wakes up whoever resumed the thread that called it
	function taskMock.wait(duration)
		local seconds = math.max(duration or 0.05, 0.001)
		scheduler:enqueue(coroutine.running(), scheduler.now + seconds, table.pack(seconds))
		return coroutine.yield({ event = scheduler })
	end
	function taskMock.spawn(callback, ...)
		return scheduler:spawn(callback, ...)
	end
	function taskMock.defer(callback, ...)
		local thread = if type(callback) == "thread" then callback else coroutine.create(callback)
		scheduler:enqueue(thread, scheduler.now, table.pack(...), true)
		return thread
	end
	function taskMock.delay(duration, callback, ...)
		local thread = coroutine.create(callback)
		scheduler:enqueue(thread, scheduler.now + duration, table.pack(...))
		return thread
	end
	function taskMock.cancel(thread)
		coroutine.close(thread)
	end
	scheduler.task = taskMock
	return scheduler
end

local function newSignal(scheduler)
	local signal = { connections = {}, waiters = {} }
	function signal:Connect(callback)
		local connection = { Connected = true, callback = callback }
		function connection.Disconnect(connectionSelf)
			connectionSelf.Connected = false
		end
		table.insert(self.connections, connection)
		return connection
	end
	function signal:Once(callback)
		local connection
		connection = self:Connect(function(...)
			connection:Disconnect()
			callback(...)
		end)
		return connection
	end
	function signal:Wait()
		table.insert(self.waiters, coroutine.running())
		return coroutine.yield({ event = self })
	end
	function signal:Fire(...)
		local arguments = table.pack(...)
		local waiters = self.waiters
		self.waiters = {}
		for _, thread in ipairs(waiters) do
			scheduler:enqueue(thread, scheduler.now, arguments)
		end
		-- The newest connection runs first, as it does on Roblox
		local connections = table.clone(self.connections)
		for index = #connections, 1, -1 do
			if connections[index].Connected then
				scheduler:spawn(connections[index].callback, ...)
			end
		end
	end
	return signal
end

--[[
	One server. Options:
		live: not running in Studio
		scheduler, stores: share these with other worlds to run several servers against one data store
		clockOffset: how far this server's os.time is from the real time
		sources: the module files to run, for comparing against another version
		onLog: gets each line of output instead of it being kept, for runs too long to keep them all
]]
local function newWorld(options)
	options = options or {}
	local scheduler = options.scheduler or newScheduler()
	local sharedStores = options.stores ~= nil
	local world = {
		scheduler = scheduler,
		stores = options.stores or {},
		logs = {},
		events = {},
		closers = {},
		budget = 1000, -- what GetRequestBudgetForRequestType reports
		spendBudget = false, -- whether requests use it up
		budgetRule = nil, -- { base, perPlayer, startup }: refills the budget over time, the way Roblox's does
		budgetAt = 0,
		budgetQueue = {},
		queuedRequests = 0,
		latency = 0, -- how long each request takes
		network = nil, -- function(key) -> a plan for that request. See UpdateAsync.
		clockOffset = options.clockOffset or 0,
		crashed = false,
		offline = false,
	}
	function world:log(line)
		if options.onLog then
			options.onLog(line)
		else
			table.insert(self.logs, line)
		end
	end
	local players = { members = {}, PlayerRemoving = newSignal(scheduler), PlayerAdded = newSignal(scheduler) }
	function players:GetPlayers()
		return table.clone(self.members)
	end
	function players:GetPlayerByUserId(userId)
		for _, player in ipairs(self.members) do
			if player.UserId == userId then
				return player
			end
		end
		return nil
	end
	world.players = players
	function world:player(userId)
		local player = { Name = "Player" .. tostring(userId), UserId = userId, Parent = players, _instance = true }
		function player.IsA(_player, className)
			return className == "Player" or className == "Instance"
		end
		function player.Kick(playerSelf, message)
			playerSelf.KickMessage = message
			self:remove(playerSelf)
		end
		table.insert(players.members, player)
		return player
	end
	function world:remove(player)
		for index, member in ipairs(players.members) do
			if member == player then
				table.remove(players.members, index)
				break
			end
		end
		-- Handlers still see the player in Players, and what they defer does not, as on Roblox
		players.PlayerRemoving:Fire(player)
		player.Parent = nil
		scheduler:flushDeferred()
	end

	-- Everything this server is running stops where it stands, and no leave or close handler ever runs.
	function world:crash()
		self.crashed = true
	end
	local function park()
		coroutine.yield({ event = true })
	end

	local function backendMillis()
		return (BASE_TIME + scheduler.now) * 1000
	end

	function world:refillBudget()
		local rule = self.budgetRule
		if rule then
			local perMinute = rule.base + rule.perPlayer * #self.players.members
			local refilled = self.budget + (scheduler.now - self.budgetAt) * perMinute / 60
			self.budget = math.max(self.budget, math.min(perMinute * (rule.capMinutes or 1), refilled))
			self.budgetAt = scheduler.now
		end
	end

	-- A write waits in a queue when the server is over budget, and is dropped when that queue is full. The queue is first
	-- come, first served, as Roblox documents.
	local function runBudgetQueue(server)
		server.budgetQueueRunning = true
		while #server.budgetQueue > 0 do
			server:refillBudget()
			if server.budget >= 1 then
				local thread = table.remove(server.budgetQueue, 1)
				server.queuedRequests -= 1
				if server.spendBudget then
					server.budget -= 1
				end
				scheduler:enqueue(thread, scheduler.now)
			else
				scheduler.task.wait(0.05)
			end
		end
		server.budgetQueueRunning = false
	end

	local function awaitBudget(server)
		server:refillBudget()
		if server.budget < 1 or #server.budgetQueue > 0 then
			if server.queuedRequests >= MAX_QUEUED_REQUESTS then
				if server.onDropped then
					server.onDropped()
				end
				error("304: UpdateAsync request dropped. Request was throttled, but throttled queue was full.", 0)
			end
			server.queuedRequests += 1
			table.insert(server.budgetQueue, coroutine.running())
			if not server.budgetQueueRunning then
				scheduler:spawn(runBudgetQueue, server)
			end
			coroutine.yield({ event = server })
		elseif server.spendBudget then
			server.budget -= 1
		end
	end

	local dataStoreService = {}
	function dataStoreService:GetRequestBudgetForRequestType(_requestType)
		world:refillBudget()
		return math.floor(world.budget)
	end

	local function newStore()
		local store = {
			data = {},
			userIds = {},
			metadata = {},
			writes = {},
			updatedAt = {},
			createdAt = {},
			recentWrites = {},
			versions = {},
			keepWrites = not options.onLog, -- a long run cannot keep a copy of every write
			conflicts = 0,
			calls = 0,
			active = 0,
			maxActive = 0,
			replays = 1,
		}

		-- A record a test seeded directly counts as written at its own LastUpdate
		local function keyInfoOf(key)
			local record = store.data[key]
			if record == nil then
				return nil
			end
			local seededAt = type(record) == "table" and type(record.MetaData) == "table" and record.MetaData.LastUpdate
			local updatedTime = store.updatedAt[key]
				or if type(seededAt) == "number" then seededAt * 1000 else backendMillis()
			local info = {
				Version = tostring(updatedTime),
				CreatedTime = store.createdAt[key] or updatedTime,
				UpdatedTime = updatedTime,
			}
			function info.GetUserIds(_info)
				return copy(store.userIds[key] or {})
			end
			function info.GetMetadata(_info)
				return copy(store.metadata[key] or {})
			end
			return info
		end

		local function transformFailed(message)
			world:log(TRANSFORM_FAILED .. tostring(message))
			table.insert(transformFailures, tostring(message))
		end

		local function runTransform(transform, key)
			if store.transformFailure then
				return false, store.transformFailure
			end
			local thread = coroutine.create(transform)
			local result = table.pack(coroutine.resume(thread, copy(store.data[key]), keyInfoOf(key)))
			if not result[1] then
				return false, result[2]
			end
			if coroutine.status(thread) ~= "dead" then
				coroutine.close(thread)
				return false, "Callbacks cannot yield"
			end
			return true, result[2], result[3], result[4]
		end

		local function checkThroughput(key, size)
			local recent = store.recentWrites[key] or {}
			store.recentWrites[key] = recent
			local total = size
			for index = #recent, 1, -1 do
				if scheduler.now - recent[index].at >= 60 then
					table.remove(recent, index)
				else
					total += recent[index].size
				end
			end
			if total > KEY_WRITE_BYTES_PER_MINUTE then
				error("KeyThrottled: The request rate exceeds the maximum allowed request rate for a single key.", 0)
			end
			table.insert(recent, { at = scheduler.now, size = size })
		end

		-- A plan from the server's network function says what happens to one request: before and after are how long it spends
		-- going there and coming back, commit is the gap between reading and writing, in which another write makes this one
		-- run its transform again, fail raises instead of doing anything, and failAfter raises after it was written, when
		-- only the response was lost.
		function store:UpdateAsync(key, transform, server)
			server = server or world
			-- Roblox converts a number to a string here, which versions before 2.0 relied on
			key = if type(key) == "number" then tostring(key) else key
			assert(type(key) == "string", "DataStore keys must be strings")
			if key == "" then
				error("101: Key name can't be empty.", 0)
			elseif #key > 50 then
				error("102: Key name exceeds the 50 character limit.", 0)
			end
			self.calls += 1
			local callId = self.calls
			self.active += 1
			self.maxActive = math.max(self.maxActive, self.active)
			local ok, value, keyInfo = pcall(function()
				awaitBudget(server)
				local plan = if server.network then server.network(key) else nil
				local travel = if plan then plan.before else server.latency
				if travel and travel > 0 then
					scheduler.task.wait(travel)
				end
				if plan and plan.fail then
					error(plan.fail, 0)
				end
				if self.beforeRead then
					self.beforeRead(key, callId)
				end
				local transformed, userIds, metadata, stored, size
				repeat
					local readVersion = self.versions[key]
					for replay = 1, self.replays do
						local ran
						ran, transformed, userIds, metadata = runTransform(transform, key)
						if not ran then
							transformFailed(transformed)
							return nil, nil
						end
						if transformed == nil then
							return nil, nil
						end
						if self.afterTransform then
							self.afterTransform(key, callId, replay)
						end
					end
					if self.beforeCommit then
						self.beforeCommit(key, callId, transformed)
					end
					local serialized
					serialized, stored, size = pcall(serialize, transformed, {})
					if not serialized then
						if string.sub(tostring(stored), 1, #TRANSFORM_FAILED) == TRANSFORM_FAILED then
							transformFailed(string.sub(stored, #TRANSFORM_FAILED + 1))
							return nil, nil
						end
						error(stored, 0)
					end
					if size > MAX_VALUE_BYTES then
						error(
							"105: Serialized value converted byte size exceeds max size " .. MAX_VALUE_BYTES .. ".",
							0
						)
					end
					checkKeyAttributes(userIds, metadata)
					if plan and plan.commit and plan.commit > 0 then
						scheduler.task.wait(plan.commit)
					end
					local collided = self.versions[key] ~= readVersion
					if collided then
						self.conflicts += 1
					end
				until not collided
				checkThroughput(key, size)
				self.createdAt[key] = self.createdAt[key] or backendMillis()
				self.updatedAt[key] = backendMillis()
				self.versions[key] = (self.versions[key] or 0) + 1
				self.data[key] = stored
				self.userIds[key] = copy(userIds or {})
				self.metadata[key] = copy(metadata or {})
				if self.keepWrites then
					table.insert(self.writes, { key = key, data = copy(stored), call = callId, at = scheduler.now })
				end
				if self.afterCommit then
					self.afterCommit(key, callId, transformed)
				end
				if plan and plan.after and plan.after > 0 then
					scheduler.task.wait(plan.after)
				end
				if plan and plan.failAfter then
					error(plan.failAfter, 0)
				end
				return copy(stored), keyInfoOf(key)
			end)
			self.active -= 1
			if not ok then
				error(value, 0)
			end
			return value, keyInfo
		end
		function store:RemoveAsync(key)
			local old = self.data[key]
			self.data[key] = nil
			self.updatedAt[key] = nil
			self.versions[key] = (self.versions[key] or 0) + 1
			return old
		end
		function store:ListKeysAsync()
			local entries = {}
			for key in pairs(self.data) do
				table.insert(entries, { KeyName = key })
			end
			return {
				IsFinished = true,
				GetCurrentPage = function()
					return entries
				end,
			}
		end
		return store
	end

	function dataStoreService.GetDataStore(_service, datastoreId, scope)
		local name = if scope == nil or scope == "global" then datastoreId else datastoreId .. "/" .. scope
		if not world.stores[name] then
			world.stores[name] = newStore()
		end
		local store = world.stores[name]
		if not sharedStores then
			return store
		end
		-- With several servers, each sees the one store through its own connection
		return setmetatable({
			UpdateAsync = function(_self, key, transform)
				if world.crashed then
					park()
				end
				if world.offline then
					error("502: API Services rejected request with error. HTTP 500 (Internal Server Error)", 0)
				end
				local result = table.pack(pcall(store.UpdateAsync, store, key, transform, world))
				-- A request that was sent still lands, but a crashed server never hears back
				if world.crashed then
					park()
				end
				if not result[1] then
					error(result[2], 0)
				end
				return table.unpack(result, 2, result.n)
			end,
		}, { __index = store })
	end
	world.dataStoreService = dataStoreService

	local httpService = {}
	function httpService:GenerateGUID(_braces)
		scheduler.guid += 1
		return string.format("00000000-0000-4000-8000-%012d", scheduler.guid)
	end
	function httpService:JSONEncode(_value)
		return "{}"
	end
	local services = { Players = players, DataStoreService = dataStoreService, HttpService = httpService }
	services.RunService = {
		Heartbeat = newSignal(scheduler),
		IsServer = function()
			return true
		end,
		IsStudio = function()
			return not options.live
		end,
	}
	-- SoulStore uses neither of these two, but they let other modules run here for comparison
	local heartbeat = services.RunService.Heartbeat
	local connectHeartbeat = heartbeat.Connect
	function heartbeat.Connect(signal, callback)
		if not signal.running then
			signal.running = true
			scheduler:spawn(function()
				while not world.crashed do
					scheduler.task.wait(0.25)
					signal:Fire(0.25)
				end
			end)
		end
		return connectHeartbeat(signal, callback)
	end
	local messaging = options.messaging or {}
	services.MessagingService = {
		SubscribeAsync = function(_service, topic, callback)
			local subscribers = messaging[topic] or {}
			messaging[topic] = subscribers
			local subscription = { server = world, callback = callback }
			table.insert(subscribers, subscription)
			return {
				Disconnect = function()
					local index = table.find(subscribers, subscription)
					if index then
						table.remove(subscribers, index)
					end
				end,
			}
		end,
		PublishAsync = function(_service, topic, data)
			for _, subscription in ipairs(messaging[topic] or {}) do
				if not subscription.server.crashed then
					scheduler.task.delay(0.3, subscription.callback, { Data = data })
				end
			end
		end,
	}
	world.services = services
	local gameMock = { Players = players, JobId = options.jobId or "same-server-job", PlaceId = 1 }
	function gameMock:GetService(name)
		return assert(services[name], "Unexpected service " .. name)
	end
	function gameMock:BindToClose(callback)
		table.insert(world.closers, callback)
	end
	world.game = gameMock
	local instanceMock = {}
	function instanceMock.new(className)
		if className == "DataStoreOptions" then
			return { SetExperimentalFeatures = function() end }
		end
		assert(className == "BindableEvent", "Unexpected mock instance " .. className)
		local instance = { _instance = true, Event = newSignal(scheduler), fireCount = 0, destroyed = false }
		function instance:Fire(...)
			assert(not self.destroyed, "Fired destroyed BindableEvent")
			self.fireCount += 1
			self.Event:Fire(...)
		end
		function instance:Destroy()
			assert(not self.destroyed, "Destroyed BindableEvent twice")
			self.destroyed = true
		end
		if not options.onLog then
			table.insert(world.events, instance)
		end
		return instance
	end
	local osMock = table.clone(os)
	osMock.time = function()
		return BASE_TIME + math.floor(scheduler.now) + world.clockOffset
	end
	osMock.clock = function()
		return scheduler.now
	end
	local function log(...)
		local arguments = table.pack(...)
		for index = 1, arguments.n do
			arguments[index] = tostring(arguments[index])
		end
		world:log(table.concat(arguments, " "))
	end
	-- Everything this server runs stops at its next wait once it has crashed
	local taskMock = table.clone(scheduler.task)
	function taskMock.wait(duration)
		local result = scheduler.task.wait(duration)
		if world.crashed then
			park()
		end
		return result
	end
	-- Repeatable random numbers, so a failure can be run again
	local randomState = options.seed or 12345
	local mathMock = table.clone(math)
	function mathMock.random(first, second)
		randomState = (randomState * 1103515245 + 12345) % 2147483648
		local fraction = randomState / 2147483648
		if first == nil then
			return fraction
		end
		local low, high = if second then first else 1, second or first
		return low + math.floor(fraction * (high - low + 1))
	end
	local script = {}
	local environment = {
		game = gameMock,
		script = script,
		require = function(module)
			return module
		end,
		task = taskMock,
		Instance = instanceMock,
		os = osMock,
		math = mathMock,
		Enum = {
			DataStoreRequestType = {
				GetAsync = "GetAsync",
				SetIncrementAsync = "SetIncrementAsync",
				UpdateAsync = "UpdateAsync",
			},
		},
		-- Two functions, because the module treats warnings and routine messages differently
		warn = function(...)
			log(...)
		end,
		print = function(...)
			log(...)
		end,
		typeof = function(value)
			return if type(value) == "table" and value._instance then value._type or "Instance" else typeof(value)
		end,
	}
	world.environment = environment
	local function loadModule(moduleSource, name, moduleScript)
		local moduleEnvironment = table.clone(environment)
		moduleEnvironment.script = moduleScript
		return luau.load(moduleSource, { debugName = name, environment = moduleEnvironment, injectGlobals = true })()
	end
	local sources = options.sources or defaultSources
	for _, name in ipairs(MODULES) do
		-- Versions before 2.0 are one file
		if sources[name] then
			script[name] = loadModule(sources[name], name, { Parent = script })
		end
	end
	world.config = script.Config
	world.session = script.Session
	world.sessionCache = script.SessionCache
	world.soulStore = loadModule(sources.init, "SoulStore", script)
	function world:active(storeName, player, defaults)
		local soul = assert(self.soulStore.new(storeName, nil, player, defaults or { Coins = 0 }))
		local loaded = self.scheduler:call(function()
			return soul:LoadData()
		end)
		equal(loaded, true, "LoadData succeeds")
		equal(soul.SessionState, "Active")
		return soul
	end
	function world:close()
		local remaining = #self.closers
		for _, callback in ipairs(self.closers) do
			self.scheduler:spawn(function()
				callback()
				remaining -= 1
			end)
		end
		self.scheduler:runUntil(function()
			return remaining == 0
		end, 35)
	end
	-- Whether any line of output contains this text
	function world:logged(text)
		for _, line in ipairs(self.logs) do
			if string.find(line, text, 1, true) then
				return true
			end
		end
		return false
	end
	return world
end

-- Several servers that share one data store and one clock
local function newCluster(count, options)
	options = options or {}
	local scheduler = newScheduler()
	local stores = {}
	local worlds = {}
	for index = 1, count do
		worlds[index] = newWorld({
			scheduler = scheduler,
			stores = stores,
			jobId = "job-" .. index,
			seed = index * 7919,
			clockOffset = options.clockOffsets and options.clockOffsets[index] or 0,
			sources = options.sources and options.sources[index],
		})
	end
	return worlds, stores, scheduler
end

local function newSuite(label)
	local cases = {}
	local suite = {}
	function suite.test(name, callback)
		table.insert(cases, { name = name, callback = callback })
	end
	function suite.run()
		local failures = {}
		for _, case in ipairs(cases) do
			table.clear(transformFailures)
			transformFailuresExpected = false
			local success, result = pcall(case.callback)
			if success and #transformFailures > 0 and not transformFailuresExpected then
				success, result = false, "A transform failed: " .. transformFailures[1]
			end
			if success then
				print("PASS " .. case.name)
			else
				print("FAIL " .. case.name .. "\n" .. tostring(result))
				table.insert(failures, case.name)
			end
		end
		print(string.format("\n%d/%d %s passed", #cases - #failures, #cases, label))
		assert(#failures == 0, "Failed cases: " .. table.concat(failures, "; "))
	end
	return suite
end

return {
	copy = copy,
	equal = equal,
	expect = expect,
	expectTransformFailures = function()
		transformFailuresExpected = true
	end,
	newCluster = newCluster,
	newScheduler = newScheduler,
	newSignal = newSignal,
	newSuite = newSuite,
	newWorld = newWorld,
	readModuleSources = readModuleSources,
}
