# SoulStore

A lightweight, production-ready Roblox player data module with session locking, automatic saving, and change listeners.

## Features

- **Session locking** — prevents cross-server data collisions with time-based auto-release
- **Automatic saving** — configurable interval-based auto-save with state-aware scheduling
- **Change listeners** — subscribe to nested data changes via path-based callbacks
- **Load/save hooks** — attach `OnLoad` and `OnSave` callbacks for data transformations
- **Reconciliation** — safely merge default data into existing player data without overwriting
- **Safe shutdown** — `BindToClose` handler ensures all souls are saved before the server closes

## Installation

Drop `SoulStore.lua` into `ServerScriptService` or any server-accessible `ModuleScript` location:

```lua
local SoulStore = require(game.ServerScriptService.SoulStore)
```

Available via [Wally](https://wally.run/package/mystifine/soulstore).

## Quick Start

```lua
local SoulStore = require(game.ServerScriptService.SoulStore)

game.Players.PlayerAdded:Connect(function(player)
    local soul = SoulStore.new("PlayerData", player, {
        Coins = 0,
        Level = 1,
    })
    
    soul:LoadData()
    soul:SetData({"Coins"}, 100)
end)
```

## Documentation

Full documentation is available at [SoulStore Docs](https://mystifine.github.io/SoulStore/) or in the `/docs` folder.

## License

MIT License — see [LICENSE](LICENSE) for details.

*Created by Mystifine*