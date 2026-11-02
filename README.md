# SoulStore

A Roblox player data module with per-session ownership, automatic saving, and path-based change listeners.

## Features

- GUID ownership tokens and exact Player instance caching protect fast rejoins.
- Pulling, Active, Ending, and terminal states keep pending or dying sessions out of gameplay.
- Serialized saves commit final data and release its lock atomically.
- Load/save hooks, default reconciliation, and nested change listeners.
- PlayerRemoving saves and bounded shutdown finalization.
- Saves that lose nothing, whatever shape your tables are in, and autosaves that stay fair when the budget is tight.
- Tested as a whole game: simulated servers of up to 200 players, under load and failure, and on real data stores. See [Load Testing](docs/guides/load-testing.md).

## Installation

Place the module in a server-accessible location such as `ServerScriptService`, or install it through [Wally](https://wally.run/package/mystifine/soulstore).

## Quick start

```lua
local SoulStore = require(game.ServerScriptService.SoulStore)
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
    soul:SetData({ "Coins" }, 100)
    -- Start gameplay only after successful loading.
end)
```

`getSoul(datastoreId, scope, player)` returns only an Active soul for that exact Player instance. A rejoin gets a fresh object and waits for the old session's final save; it never plays on defaults while a lock is held.

Deploy this lifecycle update by draining old servers. The save format is unchanged, but old pending writes cannot enforce GUID session ownership. Shutdown retries within its time budget; network failures or crashes may still require stale-lock recovery.

## Documentation

See [SoulStore Docs](https://mystifine.github.io/SoulStore/) or the local [documentation](docs/index.md), particularly [Session Locking](docs/guides/session-locking.md). Upgrading a game from 1.x? Read [Migrating from 1.x](docs/guides/migrating.md). Changing the module itself? Start with [How It Works](docs/guides/architecture.md).

## License

MIT License. Created by Mystifine.
