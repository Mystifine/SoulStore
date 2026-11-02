-- Run with Lune 0.11+: lune run tests/compare.luau path/to/ProfileStore.luau [ci|large] [part of a scenario's name] [a module's name]
-- Runs the same game on SoulStore and on the real ProfileStore, which is not in this repository, through the same fleet,
-- the same data store and the same failures. See tests/fleet.luau. It reports rather than passes or fails, because the two
-- make different choices. Most of all, ProfileStore autosaves every 5 minutes and SoulStore every 30 seconds.
local process = require("@lune/process")

local Fleet = require("./fleet")

local PROFILE_STORE = assert(process.args[1], "Give the path to ProfileStore's source")
local SCALE = process.args[2] or "ci"
local ONLY = process.args[3]
local ONLY_MODULE = process.args[4]

local SCALES = {
	ci = { servers = 3, players = 25, minutes = 8, largestPlayers = 100, whaleItems = 300 },
	large = { servers = 12, players = 100, minutes = 30, largestPlayers = 200, whaleItems = 600 },
}
local size = assert(SCALES[SCALE], "The scale is ci or large")
local backends = {
	Fleet.SoulStore,
	Fleet.profileStore(PROFILE_STORE),
	-- The same autosave interval as SoulStore, to see what comes from that choice and what does not
	Fleet.profileStore(PROFILE_STORE, "ProfileStore at 30s", { AUTO_SAVE_PERIOD = 30 }),
}

local rows = {}
for _, scenario in ipairs(Fleet.scenarios(size)) do
	if not ONLY or string.find(string.lower(scenario.name), string.lower(ONLY), 1, true) then
		for _, backend in ipairs(backends) do
			if not ONLY_MODULE or backend.name == ONLY_MODULE then
				local ok, fleet = pcall(Fleet.run, Fleet.settingsFor(scenario, size, backend))
				if ok then
					fleet:report(scenario.name, fleet.realSeconds)
					table.insert(rows, Fleet.tableRow(scenario.name, fleet))
				else
					print("\n=== " .. scenario.name .. ", on " .. backend.name .. " STOPPED: " .. tostring(fleet))
					table.insert(
						rows,
						string.format("| %s | %s | stopped: %s |", scenario.name, backend.name, tostring(fleet))
					)
				end
			end
		end
	end
end

print("")
Fleet.printTableHeader()
for _, row in ipairs(rows) do
	print(row)
end
