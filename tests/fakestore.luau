-- Run with Lune 0.11+: lune run tests/fakestore.luau
-- Runs the probe in tests/studio against the fake data store. The probe's expected answers are what real data stores
-- gave, so this keeps the fake data store from drifting away from Roblox without anyone noticing.
local fs = require("@lune/fs")
local luau = require("@lune/luau")

local harness = require("./harness")

local suite = harness.newSuite("fake data store checks")

suite.test("the fake data store gives the same answers as real data stores", function()
	harness.expectTransformFailures() -- the probe causes them on purpose
	local world = harness.newWorld()
	local store = world.dataStoreService:GetDataStore("SoulStoreProbe")

	-- The module never uses these two, so the fake data store only has them here
	function store.GetAsync(_self, key)
		local record = store.data[key]
		local info = record ~= nil
			and {
				GetMetadata = function()
					return harness.copy(store.metadata[key] or {})
				end,
			}
		return harness.copy(record), info or nil
	end
	function store.SetAsync(_self, key, value)
		store.data[key] = harness.copy(value)
		store.metadata[key] = {}
	end

	local environment = table.clone(world.environment)
	local lines = {}
	local function collect(...)
		local parts = table.pack(...)
		for index = 1, parts.n do
			parts[index] = tostring(parts[index])
		end
		table.insert(lines, table.concat(parts, " "))
	end
	environment.print, environment.warn = collect, collect
	environment.workspace = { _instance = true, Name = "Workspace" }
	environment.Vector3 = { zero = { _instance = true, _type = "Vector3" } }
	environment.Enum = { KeyCode = { A = { _instance = true, _type = "EnumItem" } } }
	local newInstance = environment.Instance.new
	environment.Instance = {
		new = function(className)
			return if className == "DataStoreGetOptions" then {} else newInstance(className)
		end,
	}

	local probe = fs.readFile("tests/studio/DataStoreProbe.server.luau")
	world.scheduler:call(function()
		luau.load(probe, { debugName = "DataStoreProbe", environment = environment, injectGlobals = true })()
	end)

	local summary = lines[#lines]
	local differences = {}
	for _, line in ipairs(lines) do
		if string.find(line, "DIFFERS", 1, true) then
			table.insert(differences, line)
		end
	end
	harness.expect(string.find(summary, " 0 differ", 1, true), summary .. "\n" .. table.concat(differences, "\n"))
end)

suite.run()
