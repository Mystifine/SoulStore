# Load Testing

Edge case tests check one thing at a time. These check the ordinary day: whether everyone's data is saved consistently and fairly, at a sensible cost, when a whole game is running at once, and what happens when that game has a bad day.

Everything here was run on 2 November 2026 against version 2.0.0. Run it yourself before you rely on it, because Roblox's limits change.

## What runs

`tests/load.luau` runs a whole game through `tests/fleet.luau`. Each server runs its own copy of the real module against one shared data store, and players do what they do in a real game: join, load, earn things through `SetData`, write to the live table, buy things, hop servers, leave, and come back. Time is virtual, so hours pass in minutes.

Every write is checked as it lands, against what the data store really stored:

- Progress never goes backwards, and `SaveId` goes up by exactly one.
- Only the session holding the lock writes.
- A save the module confirmed is never lost, and neither is a purchase made on one.
- A player only ever loses progress if their server died.
- Every session ends, and every lock is released, unless its server died.

The limits come from [Roblox's documentation](https://create.roblox.com/docs/cloud-services/data-stores/error-codes-and-limits): `60 + 40 x players` requests a minute for a server, `300 + 20 x players` writes a minute for an experience, a queue of 30, and 4 MB of writes a minute for a key. Request times come from measuring real data stores: about 0.26 seconds, and about 30 requests a second through one server.

```powershell
lune run tests/load.luau          # small enough for CI
lune run tests/load.luau large    # servers of 100 and 200 players
lune run tests/load.luau mass     # thousands of players for a simulated hour
lune run tests/load.luau large "shutting down"   # one scenario
```

## The ordinary day

No progress lost, nobody left behind, and little of Roblox's limits used. Load and final save times are in seconds. "Between saves" is the time between one player's saves, and it should stay close to the 30 second autosave.

| Scenario | Progress lost | Between saves: median / worst | Load: median / 99% / worst | Final save: median / worst | Requests a player a minute | Most of a server's limit used |
|---|---|---|---|---|---|---|
| **4,000 players on 100-player servers, for an hour** | 0 of 5,686,447 | 30 / 31 | 0.35 / 0.53 / 6.7 | 0.20 / 0.7 | 2.26 | 6% |
| **2,600 players on 200-player servers, for an hour** | 0 of 3,689,478 | 30 / 31 | 0.38 / 0.59 / 0.8 | 0.21 / 0.8 | 2.26 | 6% |
| 360 players on 10-player servers | 0 of 256,622 | 30 / 31 | 0.32 / 0.47 / 0.6 | 0.19 / 0.5 | 2.30 | 7% |
| Two data stores a player | 0 of 1,689,166 | 30 / 31 | 0.42 / 0.66 / 1.2 | 0.23 / 0.8 | 4.59 | 12% |
| Players hopping servers all the time | 0 of 816,584 | 30 / 32 | 0.44 / 7.5 / 13.6 | 0.23 / 0.6 | 3.72 | 11% |
| Everyone joining at once | 0 of 859,038 | 30 / 32 | 0.44 / 6.9 / 7.1 | 0.20 / 0.8 | 2.24 | 9% |
| A game writing odd tables through the live table | 0 of 844,107 | 30 / 32 | 0.35 / 0.54 / 0.7 | 0.20 / 0.6 | 2.30 | 6% |

Over those two big runs, not one of the 5,000 and 3,250 accounts ever waited more than 45 seconds for a save, all 58,382 purchases were confirmed, and no request was dropped.

The other rows ran 12 servers of 100 players for a simulated half hour, apart from the 10-player servers. So did the bad days below, apart from the shutdown, which ran 4 servers of 200.

## A bad day

| Scenario | Progress lost | Sessions that lost their lock | Load: median / 99% / worst | Final save: median / worst | Between saves: worst |
|---|---|---|---|---|---|
| 1 request in 100 fails, 1 in 200 loses its response | 0 of 843,279 | 0 | 0.35 / 2.5 / 6 | 0.20 / 3 | 90 |
| 1 request in 5 fails, 1 in 20 loses its response | 0 of 843,358 | 0 | 0.38 / 10.1 / 38 | 0.21 / 30 | 210 |
| Requests taking 5 seconds | 0 of 836,505 | 0 | 5.0 / 15.6 / 25 | 3.35 / 25 | 49 |
| A 2 minute outage | 0 of 838,822 | 0 | 0.35 / 112 / 149 | 0.20 / 141 | 174 |
| A 10 minute outage, longer than the lease | 0 of 946,332 | 0 | 0.36 / 548 / 627 | 0.21 / 628 | Sessions stop accepting changes at 5 minutes |
| Requests hanging for 3 minutes | 0 of 920,028 | 0 | 0.35 / 148 / 180 | 0.20 / 180 | 210 |
| Every 200-player server shutting down at once | 0 of 556,557 | 0 | 0.38 / 0.7 / 8 | 0.22 / 7 | 31 |
| Servers closing a few at a time | 0 of 839,934 | 0 | 0.35 / 0.5 / 13 | 0.21 / 4 | 31 |
| Servers whose clocks disagree by a minute | 0 of 843,727 | 0 | 0.35 / 0.5 / 1 | 0.20 / 1 | 31 |
| Saves too big for every autosave (3 MB) | 0 of 843,733 | 0 | 0.35 / 0.5 / 75 | 0.20 / 76 | 91 |
| The experience running out of write budget, with a limit far below Roblox's | 0 of 835,421 | 0 | 0.37 / 62 / 100 | 0.22 / 450 | 300 |
| One save a second for a whole 100-player server | 0 of 28,559 | 0 | 1.92 / 3.6 / 4 | 34 / 85 | 136 |
| Servers crashing | 3,237 of 824,146 (0.39%) | 0 | 0.36 / 96 / 97 | 0.20 / 1 | 31 |

Only a server dying loses anything, and only what it had not saved. In that last row, every account that lost progress had a session die with its server, and the most lost per dead session was 14 points, or about 35 seconds of play. A load that finds a dead server's lock waits out `LOCK_TAKEOVER_TIME`, which is where the 97 seconds comes from.

## On the real engine

A simulation is only as good as its model, so `tests/studio/RealFleet.luau` runs a full server's worth of sessions on the real engine, against real data stores. One real Player has one key, so each session gets its own scope. A server with one player has far less budget than a real 200-player server, so these autosave every 60 seconds rather than 30, and run out of budget partway.

200 sessions, each with a save of about 17 KB, played for 5 minutes and then all ended at once:

| Measure | Result |
|---|---|
| Loads | 200 of 200, in 10.2 seconds |
| Frames while playing | 4.0 ms at the median, 7.0 ms at the 99th percentile. The worst, 110 ms, came in the first minute, as they all started |
| Saves for purchases | 149 of 150 confirmed when last counted, 0.39 seconds at the median, 1.77 at worst |
| Final saves, all at once with the budget used up | All 200 landed, in 120 seconds. With a real 200-player server's budget they would not wait for it |
| What reached the data stores | 29,800 points in all. Every record was exactly what the game had, with none missing and none still locked |

`tests/studio/EndToEnd.luau` also passes all 199 of its checks on the real engine, including a real player leaving and a real `BindToClose`, and `tests/studio/DataStoreProbe.server.luau` finds all 53 of its rules for the fake data store still true.

What a save costs in real time on the real engine, which is the part that runs inside one frame:

| Save | Copying and checking it |
|---|---|
| 2 KB | 0.05 ms |
| 17 KB | 0.33 ms |
| 115 KB | 2.4 ms |
| 580 KB | 11.5 ms |

Even with every player's autosave spread out, a 200-player server starts about 7 saves a second. At a typical 17 KB, that is about 2 milliseconds of work a second. No more than twice that steady rate starts in any one second, so a backlog cannot land all at once.

## Against ProfileStore

`tests/compare.luau` runs the same game on the real [ProfileStore](https://github.com/MadStudioRoblox/ProfileStore), through the same fleet, the same data store and the same failures, and used the way its tutorial says. ProfileStore is a strong module, and this is not a verdict on it. Its own default is to autosave every 5 minutes where SoulStore autosaves every 30 seconds, so it also ran at 30 seconds, to show what comes from that choice and what does not.

All of these ran 12 servers of 100 players, or 4 servers of 200 for the shutdown, for a simulated half hour.

| Measure | SoulStore | ProfileStore | ProfileStore at 30 seconds |
|---|---|---|---|
| Healthy game: progress lost | 0 of 844,129 | 0 of 844,510 | 0 of 844,717 |
| Healthy game: requests a player a minute | 2.30 | **0.56** | 2.38 |
| Healthy game: seconds between saves, median / worst | **30 / 31** | 185 / 251 | 28 / 34 |
| Crashes: progress lost | **0.39%** | 2.52% | **0.38%** |
| Crashes: worst load, waiting for a dead server's lock | 97 s | **47 s** | **48 s** |
| Hopping servers: load at the 99th percentile | 7.5 s | **6.0 s** | **6.0 s** |
| Every server shutting down: progress lost, worst final save | 0, 7 s | 0, 7 s | 0, 7 s |
| 1 in 5 requests failing: worst load, worst final save | **38 s**, 30 s | 52 s, **16 s** | 52 s, 52 s |
| 2 and 10 minute outages: progress lost | 0 | 0, but see below | 0 |
| One save a second: worst wait for a save | **136 s** | 309 s | 432 s |
| The experience out of write budget: progress lost, worst wait for a save | **0**, 300 s | **0**, 278 s | 11, 1,482 s |
| A game writing odd tables: writes that lost named fields | **0** | 16,534 | 73,783 |

**Where the difference is the autosave interval.** Crash losses and requests are simply two sides of that one setting. Given the same interval, the two lose about the same in a crash, and use about the same number of requests. ProfileStore's default costs a quarter of the requests and risks up to 5 minutes of play, and SoulStore's costs about a tenth of what Roblox allows an experience and risks about 30 seconds. Set `AUTO_SAVE_INTERVAL` to whichever suits your game.

**Where ProfileStore is better.** After a crash, its load gets in twice as fast, because it asks the owner through MessagingService and takes the lock after 40 seconds. It also has things SoulStore does not: reading old versions of a save to restore them, messages to offline players, and error signals to build monitoring on.

**Where SoulStore is better.** Autosaves watch the request budget, and whoever has waited longest goes first, so they stay fair when budget is tight. A long outage cannot lose a final save to the race for the lock: with the outage earlier in a smaller run, ProfileStore's default lost 0.95% when locks passed its 630 second limit, and SoulStore lost none. SoulStore had this same problem until these tests found it, and now watches even an old lock long enough for its owner's final save to land. Odd tables cannot cost the player anything. ProfileStore's documentation tells you not to write those tables, which is fair, but one stray `[1]` on `Profile.Data` loses every named field in it, and that is a mistake a game can make. `SaveData` also tells the caller whether the write landed, and `SetData` and `OnDataChanged` are built in.

## What the developer forum warns about

| What developers report | What SoulStore does | Shown by |
|---|---|---|
| [A failed load is treated as a new player, and defaults overwrite the real save](https://devforum.roblox.com/t/datastore-data-loss/3136888) | Defaults are only used when the data store answers that there is no record | 1 in 5 requests failing: 0 lost |
| [A player who leaves before their data has loaded has it reset](https://devforum.roblox.com/t/datastore-data-loss/3136888) | A load in progress is cancelled, and nothing is saved | `tests/lifecycle.luau`, and the short sessions in every scenario |
| [A fast leave and rejoin loads old data](https://devforum.roblox.com/t/how-would-i-prevent-data-loss-when-player-leaves-using-datastoreservice/2128361) | The new session waits for the old session's final save, usually for less than a second | Hopping servers: 0 lost, no takeovers |
| [`PlayerRemoving` and `BindToClose` both saving, which uses up the budget](https://devforum.roblox.com/t/player-removing-firing-with-bindtoclose/2458189) | One final save per session, however many things ask for it | Every server shutting down: 0 lost |
| [`BindToClose` does not run when a server crashes](https://devforum.roblox.com/t/is-autosaving-data-in-datastores-really-necessary/3400688) | Autosaves bound the loss | Crashes: about 35 seconds of play at most |
| [Too little time to save everyone at shutdown](https://devforum.roblox.com/t/is-autosaving-data-in-datastores-really-necessary/3400688) | Final saves run side by side, inside the 30 seconds | 200-player servers: 7 seconds at worst |
| [Calls that never return, with no error](https://devforum.roblox.com/t/setasync-calls-are-getting-stuck-at-scale-yields-thread-indefinitely-no-datastore-error-messages-reported/337618) | A later save waits at most 10 seconds behind one, and shutdown still ends on time | Requests hanging: 0 lost |
| [A crashed server holds its lock forever](https://devforum.roblox.com/t/session-locking-explained-datastore/846799) | A lock that stops changing is taken over | Crashes: 97 seconds at worst |
| [Mixed tables lose data](https://devforum.roblox.com/t/saving-a-datastore-mixed-array-issue/351862), and [arrays with gaps behave inconsistently](https://devforum.roblox.com/t/data-store-stringifies-array-indexes-if-array-doesnt-start-from-index-1-and-behaves-incosistently-when-array-has-missing-indexes/3677213) | `SetData` refuses them, and a save loses nothing | Odd tables: 0 lost |
| [Every server saving on the same schedule](https://create.roblox.com/docs/cloud-services/data-stores/best-practices) | Each player's autosaves are spread over the whole interval | Busiest second on a 200-player server: 24 requests |
| [Retries with no backoff or jitter](https://create.roblox.com/docs/cloud-services/data-stores/best-practices) | They start at 2 seconds, as Roblox's own sample does, grow to 30, and vary by 20% | `tests/lifecycle.luau` |

Roblox's own sample autosaves every 180 seconds, and its [guidance](https://create.roblox.com/docs/cloud-services/data-stores/player-data-purchasing) leaves that up to you. Forum advice mostly runs from 30 seconds to a minute.

## What this does not prove

- **It is a simulation.** The limits and timings are Roblox's, but the failures are the ones someone thought of. Roblox also throttles by how it splits data into partitions internally, which nothing here models.
- **Only one real server has run this at once.** Real handoffs between real servers have only been simulated. Try a real server hop and a real shutdown in a test universe before you move a live game over.
- **The real test ran in Studio,** which has its own limits, and real outages have not been tested at all.
- **Nothing here watches your live game.** SoulStore warns in the output, but it has no signal to build alerts on. Use Roblox's [observability dashboard](https://create.roblox.com/docs/cloud-services/data-stores/observability), and practise restoring a save from its [versions](https://create.roblox.com/docs/cloud-services/data-stores/versioning-listing-and-caching) before you need to.
