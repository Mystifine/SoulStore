# SoulStore Static Methods

## `SoulStore.new()`

```lua
SoulStore.new(datastoreId: string, scope: string?, player: Player, defaultData: {}) -> Soul?
```

Creates and caches a Pulling soul for the exact Player instance, DataStore, and scope. Repeated calls return its pending or active soul. A different Player instance with the same UserId gets a new object and GUID token. Ending or terminal objects are never reused.

`scope` selects the DataStore scope; `nil` uses Roblox's default, `"global"`. Each scope holds separate records and separate sessions.

Returns `nil` for invalid arguments, a departed player, or shutdown, and for defaults that could not be saved: an array at the top, or anything `SetData` would refuse inside it. Defaults are copied and unavailable through gameplay methods until loading succeeds.

```lua
local soul = SoulStore.new("PlayerData", nil, player, { Coins = 0 })
if not soul then return end
if not soul:LoadData() then return end
soul:SetData({ "Coins" }, 100)
```

## Session lookups

```lua
SoulStore.getSoul(datastoreId: string, scope: string?, player: Player) -> Soul?
SoulStore.getPendingSoul(datastoreId: string, scope: string?, player: Player) -> Soul?
SoulStore.getEndingSoul(datastoreId: string, scope: string?, player: Player) -> Soul?
SoulStore.hasActiveSession(datastoreId: string, scope: string?, player: Player) -> boolean
```

All lookups use the exact Player instance, DataStore, and scope. `getSoul` returns only an Active soul; a session stops being Active as soon as its player leaves. Pending and ending helpers are for inspection; their data is unavailable for gameplay. Old-session cleanup cannot remove a new Player instance's soul.

## `SoulStore.playerExists()`

```lua
SoulStore.playerExists(player: Player?) -> boolean
```

Returns whether the argument is a Player currently parented to `Players`.

## `SoulStore.getMetaData()`

```lua
SoulStore.getMetaData(sessionToken: string?) -> SoulMetaData
```

Returns fresh metadata with `SaveId = 0` and the current timestamp. Without a token, returns `Locked = false, SessionId = ""`. With a token, returns locked metadata owned by that token. `SessionId` is opaque and does not identify a server JobId. Applications should not overwrite persisted metadata.

## `SoulStore.deepCopy()`

```lua
SoulStore.deepCopy(data: any?) -> any
```

Recursively copies tables, keeping each table's length and leaving metatables behind. Returns primitive values unchanged.

## `SoulStore.output()`

```lua
SoulStore.output(outputFunction: (any) -> any, ...: any) -> nil
```

Writes diagnostics using the supplied function, respecting `DEBUG_MODE` and `TRACE_BACK_MESSAGE`. Persistence warnings remain visible when verbose debug output is disabled.

## `SoulStore.getDatastore()`

```lua
SoulStore.getDatastore(datastoreId: string, scope: string?) -> DataStore
```

Returns the DataStore that SoulStore uses for that name and scope.

## `SoulStore.resetData()`

```lua
SoulStore.resetData(datastoreId: string, scope: string?, datastoreKey: string) -> boolean
```

Removes one DataStore key and returns whether it succeeded. Refused while this server has a session for that key. Sessions on other servers cannot be detected, so stop them first.

!!! danger "Data Loss"
    Deletes the saved profile. See [Resetting Data](../guides/reset-data.md).

```lua
SoulStore.resetData("PlayerData", nil, tostring(player.UserId))
```

## `SoulStore.resetAllData()`

```lua
SoulStore.resetAllData(datastoreId: string, scope: string?, confirmation: string?) -> boolean
```

Waits 10 seconds, lists all keys, then removes them sequentially. Returns whether every key was removed. Refused while this server has a session in that DataStore. Outside Studio, `confirmation` must repeat `datastoreId` or nothing is deleted. Stop sessions on other servers first.

!!! danger "Data Loss"
    Deletes every profile. See [Resetting Data](../guides/reset-data.md).
