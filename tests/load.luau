-- Run with Lune 0.11+: lune run tests/load.luau [ci|large|mass] [part of a scenario's name]
-- Popular servers, simulated. tests/fleet.luau says what is simulated and what is checked as it runs. Each scenario then
-- says how much it may cost: for most of them no progress at all, and no session ever losing its lock.
local process = require("@lune/process")

local Fleet = require("./fleet")
local harness = require("./harness")

local SCALE = process.args[1] or "ci"
local ONLY = process.args[2]

-- How many servers, how many players on each, how long, how big the largest servers and saves get, and how many
-- accounts there are for each player online
local SCALES = {
	ci = { servers = 3, players = 25, minutes = 8, largestPlayers = 100, whaleItems = 300 },
	large = { servers = 12, players = 100, minutes = 30, largestPlayers = 200, whaleItems = 600 },
	mass = {
		servers = 40,
		players = 100,
		minutes = 60,
		largestPlayers = 200,
		whaleItems = 600,
		populationFactor = 1.25,
	},
}
local size = assert(SCALES[SCALE], "The scale is ci, large or mass")
local suite = harness.newSuite("load scenarios")
local rows = {}

for _, scenario in ipairs(Fleet.scenarios(size)) do
	if not ONLY or string.find(string.lower(scenario.name), string.lower(ONLY), 1, true) then
		suite.test(scenario.name, function()
			local fleet = Fleet.run(Fleet.settingsFor(scenario, size))
			fleet:report(scenario.name, fleet.realSeconds)
			table.insert(rows, Fleet.tableRow(scenario.name, fleet))
			if fleet.problemCount > 0 then
				local kinds = {}
				for kind, entry in pairs(fleet.problems) do
					table.insert(kinds, string.format("%dx %s (%s)", entry.count, kind, entry.first))
				end
				error(table.concat(kinds, "; "), 0)
			end
			scenario.check(fleet)
		end)
	end
end

local ok, problem = pcall(suite.run)
print("")
Fleet.printTableHeader()
for _, row in ipairs(rows) do
	print(row)
end
assert(ok, problem)
