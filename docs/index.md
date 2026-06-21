# SoulStore
**Version:** 1.0.3

SoulStore is a lightweight Luau module for Roblox that wraps `DataStoreService` with a session-safe, path-based API.
!!! warning "AI-Assisted Documentation"
    Documentation is AI-Assisted and may contain inaccuracies. Please report any issues or suggestions on the [GitHub Issues Page](https://github.com/Mystifine/SoulStore/issues).
## Features

| Feature | Description |
|---|---|
| **Session Locking** | Prevents concurrent server writes to the same player key. |
| **Auto-Save** | Saves all active souls in the background at a configurable interval. |
| **Path-Based API** | Navigate nested data with key arrays instead of raw table references. |
| **Change Listeners** | Subscribe to value changes at any path depth. |
| **Lifecycle Hooks** | Transform or validate data before save and after load. |
| **Graceful Shutdown** | Flushes all souls before the server closes via `BindToClose`. |

## Quick Start
```
rojo build -o SoulStore.rbxlx
```
Place `SoulStore.lua` in `ServerScriptService` or a shared server `Modules` folder and `require` it from a `Script`.
```lua
local SoulStore = require(path.to.SoulStore)

local DEFAULT_DATA = { Coins = 0, Level = 1 }

game.Players.PlayerAdded:Connect(function(player)
    local soul = SoulStore.new("PlayerData", player, DEFAULT_DATA)
    soul:LoadData()
    soul:SetData({ "Coins" }, soul:GetData({ "Coins" }) + 50)
end)
```
!!! warning "Server-Only"
    `DataStoreService` is unavailable on the client. Never require SoulStore from a `LocalScript`.