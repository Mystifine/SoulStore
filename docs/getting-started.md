# Getting Started

## Installation

Require SoulStore only from server code.

For Rojo, clone the repository, run `rojo build -o SoulStore.rbxlx`, and copy the SoulStore module from ServerScriptService into your project.

For Wally, add `soulstore = "mystifine/soulstore@2.0.0"` to your project's server dependencies, then run `wally install`. If your game already uses 1.x, read [Migrating from 1.x](guides/migrating.md) first, because some arguments changed.

```lua
local SoulStore = require(path.to.SoulStore)
```

## Player lifecycle

Keep the default schema in a shared server module. Create one soul per exact Player instance and DataStore, and start gameplay only after a successful load.

```lua
local Players = game:GetService("Players")
local SoulStore = require(path.to.SoulStore)
local DEFAULT_DATA = {
    Stats = { Gold = 0, Gems = 0 },
    Inventory = {},
}

local function onPlayerAdded(player)
    -- Avoid repeating this service's own initialization during startup races.
    if SoulStore.getPendingSoul("PlayerData", nil, player)
        or SoulStore.hasActiveSession("PlayerData", nil, player)
        or SoulStore.getEndingSoul("PlayerData", nil, player) then
        return
    end
    -- The second argument is the DataStore scope. nil uses Roblox's default.
    local soul = SoulStore.new("PlayerData", nil, player, DEFAULT_DATA)
    if not soul then return end

    soul:SetOnLoad(function(data)
        -- Migrate the argument directly; soul gameplay methods are unavailable here.
        if data.Stats == nil then
            data.Stats = { Gold = 0, Gems = 0 }
        end
    end)

    local loaded, reason = soul:LoadData()
    if not loaded then
        warn("Could not initialize player data:", reason)
        return
    end

    soul:Reconcile(DEFAULT_DATA)
    -- Start gameplay and replication here, after confirmed ownership.
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
    task.spawn(onPlayerAdded, player)
end
```

SoulStore caches pending work immediately and shares concurrent loads. Application startup should still be wired once, so your own gameplay initialization is not repeated.

SoulStore handles PlayerRemoving and BindToClose automatically. A departing Player's soul is cancelled if still Pulling, or final-saved if Active. A rejoining Player gets a fresh soul and waits for the old session to release its lock.

For later gameplay requests, look up the current session:

```lua
local function awardGold(player, amount)
    local soul = SoulStore.getSoul("PlayerData", nil, player)
    if not soul then return end
    local gold = soul:GetData({ "Stats", "Gold" })
    soul:SetData({ "Stats", "Gold" }, gold + amount)
end
```

Validate all client-originating requests on the server before using data APIs. Replicate only the gameplay fields the client needs; keep session metadata on the server.

## Replication example

SoulStore does not create remotes. If your project has a `GetPlayerData` RemoteFunction in ReplicatedStorage, its server handler can expose an explicit gameplay snapshot:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local getPlayerData = ReplicatedStorage:WaitForChild("GetPlayerData")

getPlayerData.OnServerInvoke = function(player)
    local soul = SoulStore.getSoul("PlayerData", nil, player)
    if not soul then return nil end
    return {
        Stats = SoulStore.deepCopy(soul:GetData({ "Stats" })),
        Inventory = SoulStore.deepCopy(soul:GetData({ "Inventory" })),
    }
end
```

The client should keep its loading UI visible when no Active data is available. Request again through your game's readiness flow after initialization; do not replace an unavailable response with a default profile.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local getPlayerData = ReplicatedStorage:WaitForChild("GetPlayerData")
local data = getPlayerData:InvokeServer()
if data then
    -- Initialize the player's data UI from this confirmed snapshot.
end
```

For later changes, have trusted server gameplay call `SetData` and send the resulting field through your own RemoteEvent. `OnDataChanged` can drive those deltas. Clients should request actions such as buying an item; the server validates them and decides the data mutation.

## Readiness and failure handling

`LoadData` returns `true` only for Active data. Failed loads, pending locks, and terminal sessions must not enter gameplay. Do not publish a loaded marker, send a default profile to the client, or grant rewards before successful loading.

`getSoul` returns only usable Active sessions, checking the confirmed lease age. Use `getPendingSoul` and `getEndingSoul` for inspection. `SessionState` describes the lifecycle; `LoadState` is a compatibility status. An expired lease can deny gameplay access before background finalization changes the lifecycle state.

React to `SessionEndBindableEvent` if your game should disconnect or move a player out of gameplay after lease expiry or ownership loss. SoulStore does not kick players automatically. Check `EndReason` for outcomes such as `Saved`, `LeaseExpired`, `OwnershipLost`, `Cancelled`, `AcquisitionUncertain`, `SaveRejected`, `CorruptData`, `HookFailed`, `DataStoreError`, `InternalError`, or `ShutdownTimeout`.

Check the boolean result of manual `SaveData` calls when a confirmed write matters. A normal save makes one attempt, so `false` means it did not land; try again or wait for the next autosave. Session completion also includes cancellation and ownership loss, so a terminal event alone is not proof of a successful final save.

## Configuration

Edit `src/Config.luau` before deployment.

| Setting | Default | Purpose |
|---|---|---|
| `DEBUG_MODE` | `false` | Verbose diagnostic output. Persistence warnings remain visible. |
| `TRACE_BACK_MESSAGE` | `false` | Append stack traces to diagnostics. |
| `LOAD_ATTEMPT_INTERVAL` | `6` seconds | Delay between looks at a lock that a load is waiting for. |
| `RETRY_INTERVAL` | `2` seconds | First delay before a failed load or final save retries. |
| `MAX_RETRY_INTERVAL` | `30` seconds | Longest delay that retries slow down to after repeated failures. |
| `AUTO_SAVE_INTERVAL` | `30` seconds | Background save scheduling interval. |
| `SESSION_LOCK_EXPIRY` | `300` seconds | How long a session keeps working without a confirmed write. A lock older than this takes less waiting for. |
| `LOCK_TAKEOVER_TIME` | `90` seconds | How long a load watches a lock that never changes before taking it over. Three autosave intervals. |
| `WRITER_WAIT_TIMEOUT` | `10` seconds | Longest a save waits behind one already running. |
| `ACQUISITION_RECOVERY_TIMEOUT` | `30` seconds | Retry window for releasing a cancelled acquisition with an uncertain response. |
| `SHUTDOWN_TIMEOUT` | `25` seconds | Maximum time spent waiting for shutdown settlement. |

The shared autosave scheduler checks Active souls once per second. Each player's autosaves are spread over the whole interval, a backlog is cleared at no more than twice the steady rate, and when the request budget cannot cover everyone, whoever has waited longest goes first. Normal saves make one attempt. Load and final-save retry delays increase after consecutive failures and are capped at `MAX_RETRY_INTERVAL`, except during shutdown, when final saves stop slowing down at three times `RETRY_INTERVAL`. Each wait varies by 20% either way, so players and servers do not retry at the same moment.

Keep expiry comfortably longer than autosaves and expected request delays. Shutdown uses a bounded finalization budget of about 25 seconds and cannot guarantee successful writes during an outage.

Before deploying this lifecycle update, drain old servers. Existing data does not need migration, but older pending writes cannot enforce the new per-session token model. See [Session Locking](guides/session-locking.md), and [Migrating from 1.x](guides/migrating.md) if your game already uses SoulStore.
