# Tests

From the repository root, with Lune 0.11 or newer:

```powershell
lune run tests/lifecycle.luau   # the session flow, case by case
lune run tests/edgecases.luau   # known ways data stores go wrong, listed in docs/guides/edge-cases.md
lune run tests/consumers.luau   # how the games built on SoulStore use it
lune run tests/games.luau       # the games' real code, if they are in sibling folders
lune run tests/fakestore.luau   # the fake data store against what real data stores answered
lune run tests/load.luau        # popular servers: the whole game, from join to leave, under load and failure
```

`harness.luau` loads the actual files in `src/` with a virtual clock and task scheduler, mock Players and BindableEvents, and an in-memory data store. Nothing connects to Roblox or touches real player data.

The fake data store follows what real data stores were seen to do, and Roblox's documentation for the rest. It refuses what Roblox refuses, treats a transform that errors or yields the way Roblox does, by writing nothing and raising nothing, applies the request queue, the per-key throughput limit and the limits on values, user ids and metadata, and returns what a later read would see. A test also fails if a transform fails when it did not set out to cause that, because on Roblox that would be silent.

`games.luau` runs each game's real `PlayerDataService` with its real schema and migrations. The only adaptation is the argument change every game has to make for 2.0. It also runs the same play session on the SoulStore version each game has installed and on this one, and compares what ended up in the data store. A game whose folder is missing is skipped, so it only tests anything on a machine that has the games. `consumers.luau` covers the same usage for CI.

`load.luau` runs a whole game through `fleet.luau`: many servers sharing one data store, each with its own copy of the real module, and players who join, play, buy things, hop servers and leave. Every write is checked as it lands, and each scenario then says what it may cost, which for most is nothing at all. The simulated limits are Roblox's documented ones, and the request times are measured from real data stores. `lune run tests/load.luau large` runs 100 and 200 player servers for simulated half hours, and `mass` runs 4,000 players for a simulated hour. Add part of a scenario's name to run just that one.

`compare.luau` runs the same game on the real ProfileStore, through the same fleet. ProfileStore is not in this repository, so give it the path to a copy: `lune run tests/compare.luau path/to/ProfileStore.luau large`.

`studio/DataStoreProbe.server.luau` checks the fake data store's rules against real data stores, and should report nothing different. Run it after a Roblox update if something looks off: put it in a published test place with Studio API access on, press Play, and read the output. It only touches a store named `SoulStoreProbe`. `fakestore.luau` runs the same probe against the fake data store, so the two cannot drift apart.

`studio/EndToEnd.luau` runs the real module on the real engine with real data stores. `studio/RealFleet.luau` runs a full server's worth of sessions there, and measures what saves cost in real time. See the top of each file for how.

The project pins Lune, StyLua, Selene, and Rojo in `rokit.toml`; install them with `rokit install`. The validation workflow runs formatting, linting, every suite except `games.luau`, and a Rojo build on pushes and pull requests.
