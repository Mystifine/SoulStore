# SoulStore

SoulStore is a server-side Luau module for Roblox with per-session DataStore ownership and a path-based API.

## Features

| Feature | Description |
|---|---|
| Session ownership | GUID tokens distinguish sessions even within the same server. |
| Lifecycle | Pending and ending souls are unavailable for gameplay. |
| Autosave | Shared scheduling saves Active souls in the background, spread evenly, with everyone getting a turn when the budget is tight. |
| Safe saves | A stray key or an odd table cannot wipe out a save, and nothing in it is quietly lost. |
| Serialized finalization | Final save and unlock happen atomically after any current writer. |
| Data API | Nested paths, change listeners, reconciliation, and load/save hooks. |
| Shutdown | Cancels pending work and retries final saves within a bounded budget. |

## Quick start

Build the Rojo project with `rojo build -o SoulStore.rbxlx`, or install the Wally package. Require SoulStore from a server Script.

```lua
local SoulStore = require(path.to.SoulStore)
local DEFAULT_DATA = { Coins = 0, Level = 1 }

game.Players.PlayerAdded:Connect(function(player)
    -- The second argument is the DataStore scope. nil uses Roblox's default.
    local soul = SoulStore.new("PlayerData", nil, player, DEFAULT_DATA)
    if not soul then return end

    local loaded, reason = soul:LoadData()
    if not loaded then
        warn("Player data unavailable:", reason)
        return
    end

    soul:Reconcile(DEFAULT_DATA)
    soul:SetData({ "Coins" }, soul:GetData({ "Coins" }) + 50)
end)
```

Read [Getting Started](getting-started.md) for integration and [Session Locking](guides/session-locking.md) for lifecycle, crash recovery, and rollout guidance. Never start gameplay on a pending soul or use defaults when loading fails.

!!! warning "Server only"
    DataStoreService is unavailable on the client. Require SoulStore only from server code.
