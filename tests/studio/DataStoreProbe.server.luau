--[[
	Checks the rules tests/harness.luau follows against real data stores, which the tests themselves cannot prove. Every
	check should come back OK. Anything marked DIFFERS means Roblox has changed, or the fake data store is wrong.

	Put this in ServerScriptService in a PUBLISHED TEST PLACE with Studio API access on, press Play, and read the
	output. It only touches a data store named "SoulStoreProbe", removes its keys when it finishes, and ends with a
	summary line. Delete the script afterwards.
]]

local DataStoreService = game:GetService("DataStoreService")

local store = DataStoreService:GetDataStore("SoulStoreProbe")
local readOptions = Instance.new("DataStoreGetOptions")
readOptions.UseCache = false

local checks, differing = 0, 0
local keys = {}

local function report(name: string, expected: any, actual: any)
	checks += 1
	if tostring(expected) == tostring(actual) then
		print(string.format("[Probe] OK      %s", name))
	else
		differing += 1
		warn(
			string.format(
				"[Probe] DIFFERS %s\n  assumed: %s\n  actual:  %s",
				name,
				tostring(expected),
				tostring(actual)
			)
		)
	end
end

-- The same table always gives the same text, with number keys written differently from string keys
local function describe(value: any): string
	if typeof(value) == "buffer" then
		return "buffer:" .. buffer.tostring(value)
	elseif typeof(value) ~= "table" then
		return tostring(value)
	end
	local parts = {}
	for key, child in pairs(value) do
		local label = if typeof(key) == "number" then "[" .. tostring(key) .. "]" else '"' .. tostring(key) .. '"'
		table.insert(parts, label .. "=" .. describe(child))
	end
	table.sort(parts)
	return "{" .. table.concat(parts, ",") .. "}"
end

local function write(name: string, value: any, userIds: any?, metadata: any?): (boolean, any)
	local key = "probe_" .. name
	table.insert(keys, key)
	return pcall(function()
		return store:UpdateAsync(key, function()
			return value, userIds, metadata
		end)
	end)
end

local function read(name: string): any
	return store:GetAsync("probe_" .. name, readOptions)
end

local function roundTrip(name: string, value: any): string
	local ok, result = write(name, value)
	if not ok then
		return "error: " .. tostring(result)
	end
	local readOk, stored = pcall(read, name)
	return if readOk then describe(stored) else "read error: " .. tostring(stored)
end

local function errorCode(ok: boolean, result: any): string
	if ok then
		return "no error"
	end
	return string.match(tostring(result), "^%s*(%d%d%d):") or tostring(result)
end

-- Starts from a save, so that a write that is cancelled can be told from one that lands
local function roundTripOverSave(name: string, value: any): string
	write(name, { Old = true })
	return roundTrip(name, value)
end

-- The shapes a save can come back in
local mixed = { "a", "b" }
mixed.Name = "lost"
report("[1] with a string key loses the string key", '{"Value"={[1]=a,[2]=b}}', roundTrip("mixed", { Value = mixed }))
report(
	"other number keys with a string key become strings",
	'{"Value"={"5"=a,"Name"=b}}',
	roundTrip("mixedNoFirst", { Value = { [5] = "a", Name = "b" } })
)
report(
	"a gap can survive",
	'{"Value"={[1]=a,[2]=b,[4]=c}}',
	roundTrip("gap", { Value = { [1] = "a", [2] = "b", [4] = "c" } })
)
report("a gap can cut the array short", '{"Value"={[1]=a}}', roundTrip("gapCut", { Value = { [1] = "a", [3] = "c" } }))
report(
	"[1] at the top of a record loses every named field",
	"{[1]=oops}",
	roundTrip("topMixed", { [1] = "oops", Coins = 50, MetaData = { SaveId = 1 } })
)
report(
	"the same as a string keeps them all",
	'{"1"=oops,"Coins"=50}',
	roundTrip("topAsString", { ["1"] = "oops", Coins = 50 })
)

-- What decides it is the table's length, which depends on how the table was built
local firstRemoved = { "a", "b", "c" }
firstRemoved[1] = nil
report(
	"a length keeps number keys, even with no first",
	'{"Value"={[2]=b,[3]=c}}',
	roundTrip("firstRemoved", { Value = firstRemoved })
)
local firstRemovedNamed = { "a", "b", "c" }
firstRemovedNamed[1] = nil
firstRemovedNamed.Name = "kept without a length"
report(
	"a length loses string keys, even with no first",
	-- Adding the name can rebuild the table, and whether it still has a length then differs between Luau versions
	if #firstRemovedNamed > 0 then '{"Value"={[2]=b,[3]=c}}' else '{"Value"={"2"=b,"3"=c,"Name"=kept without a length}}',
	roundTrip("firstRemovedNamed", { Value = firstRemovedNamed })
)
local grown = {}
for index = 1, 5 do
	grown[index] = index
end
grown[4] = nil
report(
	"an array with a gap keeps its length",
	'{"Value"={[1]=1,[2]=2,[3]=3,[5]=5}}',
	roundTrip("grown", { Value = grown })
)
report(
	"so does a clone of it",
	'{"Value"={[1]=1,[2]=2,[3]=3,[5]=5}}',
	roundTrip("grownCloned", { Value = table.clone(grown) })
)
-- selene: allow(manual_table_clone)
local rebuilt = {}
for key, value in pairs(grown) do
	rebuilt[key] = value
end
report(
	"rebuilt key by key, it is cut short",
	'{"Value"={[1]=1,[2]=2,[3]=3}}',
	roundTrip("grownRebuilt", { Value = rebuilt })
)
local created = table.create(40)
created[1], created[40] = "a", "z"
report(
	"created at its full size, a gap survives",
	'{"Value"={[1]=a,[40]=z}}',
	roundTrip("created", { Value = created })
)
report(
	"number keys without a first become strings",
	'{"Value"={"5"=a,"9"=b}}',
	roundTrip("noFirst", { Value = { [5] = "a", [9] = "b" } })
)
report(
	"a fractional key becomes a whole number",
	'{"Value"={"1"=a}}',
	roundTrip("fraction", { Value = { [1.5] = "a" } })
)
report("[0] with [1] is lost", '{"Value"={[1]=b}}', roundTrip("zero", { Value = { [0] = "a", [1] = "b" } }))
report("a plain array", '{"Value"={[1]=a,[2]=b}}', roundTrip("array", { Value = { "a", "b" } }))
report("an empty table", '{"Value"={}}', roundTrip("empty", { Value = {} }))
report(
	"string keys that look like numbers stay strings",
	'{"Value"={"1"=a}}',
	roundTrip("numeric", { Value = { ["1"] = "a" } })
)
report("a buffer", '{"Value"=buffer:abc}', roundTrip("buffer", { Value = buffer.fromstring("abc") }))

-- Numbers
report("infinity comes back", '{"Value"=inf}', roundTrip("inf", { Value = math.huge }))
report("negative infinity comes back", '{"Value"=-inf}', roundTrip("negativeInf", { Value = -math.huge }))
write("nan", { Value = 0 / 0 })
local storedNaN = read("nan")
report("NaN comes back", true, storedNaN ~= nil and storedNaN.Value ~= storedNaN.Value)
report("a big number comes back", '{"Value"=1e+85}', roundTrip("big", { Value = 1e85 }))

-- What fails the whole write with an error
report("invalid UTF-8", "104", errorCode(write("utf8", { Value = "bad\xFF" })))
report("invalid UTF-8 in a key", "104", errorCode(write("utf8Key", { ["bad\xFF"] = 1 })))
report("a function", "104", errorCode(write("func", { Value = print })))
report("a Vector3", "104", errorCode(write("vector", { Value = Vector3.zero })))
report("an Instance", "104", errorCode(write("instance", { Value = workspace })))
report("an EnumItem", "104", errorCode(write("enum", { Value = Enum.KeyCode.A })))
report("over 4 MB", "105", errorCode(write("big4mb", { Value = string.rep("x", 5 * 1024 * 1024) })))
report("four user ids", "no error", errorCode(write("ids4", { Value = 1 }, { 1, 2, 3, 4 })))
report("five user ids", "512", errorCode(write("ids5", { Value = 1 }, { 1, 2, 3, 4, 5 })))
report("a negative user id", "no error", errorCode(write("idsNegative", { Value = 1 }, { -1 })))
report("too much metadata", "511", errorCode(write("meta", { Value = 1 }, {}, { Long = string.rep("x", 400) })))

-- What cancels the whole write without an error
local cyclic = {}
cyclic.Self = cyclic
report("a boolean key cancels the write", '{"Old"=true}', roundTripOverSave("booleanKey", { Keep = 1, [true] = "a" }))
report("a cycle cancels the write", '{"Old"=true}', roundTripOverSave("cycle", { Keep = 1, Self = cyclic }))

-- What is stored, but not as it was
local thread = coroutine.create(function() end)
report("a thread is left out", '{"Keep"=1}', roundTripOverSave("thread", { Keep = 1, Bad = thread }))
report(
	"an Instance key gets a meaningless name",
	'{"<Instance> (Workspace)"=a}',
	roundTrip("instanceKey", { [workspace] = "a" })
)
report(
	"an infinite key gets a meaningless name",
	'{"-9223372036854775808"=a}',
	roundTrip("infKey", { [math.huge] = "a" })
)
report("a metatable is left out", '{"A"=1}', roundTrip("metatable", setmetatable({ A = 1 }, { __index = { B = 2 } })))

-- Transforms that go wrong: nothing is raised, nil comes back, and nothing is written
local function transformCase(name: string, transform: () -> any)
	local key = "probe_" .. name
	table.insert(keys, key)
	store:SetAsync(key, "before")
	local ok, result = pcall(function()
		return store:UpdateAsync(key, transform)
	end)
	report(name .. " raises nothing and returns nil", "true nil", tostring(ok) .. " " .. tostring(result))
	report(name .. " writes nothing", "before", store:GetAsync(key, readOptions))
end
transformCase("a yielding transform", function()
	task.wait()
	return { Value = 1 }
end)
transformCase("an erroring transform", function()
	error("boom")
end)

-- What UpdateAsync does
table.insert(keys, "probe_cancel")
local cancelOk, cancelResult, cancelInfo = pcall(function()
	return store:UpdateAsync("probe_cancel", function()
		return nil
	end)
end)
report("a cancelled write returns nil", true, cancelOk and cancelResult == nil and cancelInfo == nil)

table.insert(keys, "probe_return")
local written = { [5] = "a" }
local returned = store:UpdateAsync("probe_return", function()
	return written
end)
report("the return value is what a read would see", '{"5"=a}', describe(returned))
report("the return value is a new table", true, returned ~= written)

table.insert(keys, "probe_race")
store:SetAsync("probe_race", 0)
local runs, finished = 0, 0
for _ = 1, 5 do
	task.spawn(function()
		store:UpdateAsync("probe_race", function(old)
			runs += 1
			return old + 1
		end)
		finished += 1
	end)
end
local raceDeadline = os.clock() + 30
while finished < 5 and os.clock() < raceDeadline do
	task.wait(0.1)
end
report("writes at once all count", 5, store:GetAsync("probe_race", readOptions))
print(string.format("[Probe] INFO    those 5 writes ran their transforms %d times", runs))

table.insert(keys, "probe_info")
local firstKeyInfo = "not called"
local infoOk, _, writtenInfo = pcall(function()
	return store:UpdateAsync("probe_info", function(_, keyInfo)
		firstKeyInfo = keyInfo
		return { Value = 1 }, {}, { Tag = "kept" }
	end)
end)
report("a new key has no key info", "nil", tostring(firstKeyInfo))
report(
	"UpdatedTime is in milliseconds",
	true,
	infoOk and typeof(writtenInfo.UpdatedTime) == "number" and writtenInfo.UpdatedTime > 1e12
)
if infoOk then
	-- This is how far this server's os.time is from Roblox's. A big number means lock ages can be wrong.
	print(
		string.format(
			"[Probe] INFO    this server's clock is %.1f seconds from Roblox's",
			os.time() - writtenInfo.UpdatedTime / 1000
		)
	)
end
local _, clearedInfo = pcall(function()
	store:UpdateAsync("probe_info", function()
		return { Value = 2 } -- does not return the metadata
	end)
	return select(2, store:GetAsync("probe_info", readOptions))
end)
report("metadata not returned by a transform is cleared", "{}", describe(clearedInfo and clearedInfo:GetMetadata()))

-- Signals and clocks
local handled = false
local event = Instance.new("BindableEvent")
event.Event:Connect(function()
	handled = true
end)
event:Fire()
event:Destroy()
task.wait(0.1)
report("a handler still runs when the event is destroyed right after firing", true, handled)

local clockBefore = os.clock()
task.wait(1)
report("os.clock keeps counting through a wait", true, os.clock() - clockBefore >= 0.9)

for _, key in ipairs(keys) do
	pcall(function()
		store:RemoveAsync(key)
	end)
end

print(string.format("[Probe] Finished: %d checks, %d differ.", checks, differing))
