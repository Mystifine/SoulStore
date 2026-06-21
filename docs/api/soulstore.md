# SoulStore Static Methods

Static methods on the `SoulStore` module table.

---

## `SoulStore.new()`

Creates a new `Soul` object. Returns an existing cached soul if one is already loaded for this player and DataStore ID.

**Signature**
```lua
SoulStore.new(
    datastoreId : string,
    player      : Player,
    defaultData : {}
) -> Soul?
```

**Parameters**

| Parameter | Type | Description |
|---|---|---|
| `datastoreId` | `string` | DataStore name to read from and write to. |
| `player` | `Player` | The `Player` instance. |
| `defaultData` | `{}` | Starting data template. Deep-copied into the soul. |

**Returns** `Soul?` — `nil` if `defaultData` is not a table or the player has left.

```lua
local soul = SoulStore.new("PlayerData", player, { Coins = 0, Level = 1 })
```

---

## `SoulStore.getSoul()`

Retrieves a cached soul by DataStore ID and player.

**Signature**
```lua
SoulStore.getSoul(datastoreId: string, player: Player) -> Soul?
```

**Returns** `Soul?` — the cached soul, or `nil` if not found.

```lua
local soul = SoulStore.getSoul("PlayerData", player)
if soul then
    soul:SetData({ "Coins" }, 999)
end
```

---

## `SoulStore.playerExists()`

Returns `true` if the player is currently in the game.

**Signature**
```lua
SoulStore.playerExists(player: Player?) -> boolean?
```

Checks `player and player:IsA("Player") and player.Parent == Players`.

---

## `SoulStore.getMetaData()`

Returns a fresh `SoulMetaData` table for the current server and timestamp. Called internally during first-time data creation.

**Signature**
```lua
SoulStore.getMetaData() -> SoulMetaData
-- Returns: { Locked = true, SaveId = 0, LastUpdate = os.time(), SessionId = game.JobId }
```

---

## `SoulStore.deepCopy()`

Recursively copies a table, or returns a primitive value unchanged.

**Signature**
```lua
SoulStore.deepCopy(data: any?) -> any
```

```lua
local copy = SoulStore.deepCopy({ Stats = { Level = 5 } })
copy.Stats.Level = 99
-- original table is unchanged
```

---

## `SoulStore.output()`

Logs a message using the provided function, respecting `DEBUG_MODE` and `TRACE_BACK_MESSAGE`. No-ops if `DEBUG_MODE` is `false`.

**Signature**
```lua
SoulStore.output(outputFunction: (any) -> any, ...: any) -> nil
```

---

## `SoulStore.resetData()`

Removes a single player's DataStore key.

**Signature**
```lua
SoulStore.resetData(datastoreId: string, datastoreKey: string) -> nil
```

!!! danger "Data Loss"
    Permanently deletes the player's saved data. Cannot be undone.

```lua
SoulStore.resetData("PlayerData", tostring(player.UserId))
```

---

## `SoulStore.resetAllData()`

Deletes **every key** in a DataStore. Waits 10 seconds, then pages through all keys and removes each one sequentially.

**Signature**
```lua
SoulStore.resetAllData(datastoreId: string) -> nil
```

!!! danger "Irreversible — Extreme Caution"
    Permanently wipes all player data. See the [Resetting Data guide](../guides/reset-data.md) before using.