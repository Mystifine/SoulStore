# Data Operations

## Readiness

Only Active souls accept gameplay operations. Check the load result before making data available to the rest of the game:

```lua
local soul = SoulStore.new("PlayerData", nil, player, DEFAULT_DATA)
if not soul then return end
local loaded, reason = soul:LoadData()
if not loaded then return end
soul:Reconcile(DEFAULT_DATA)
```

For later lookups, use `SoulStore.getSoul("PlayerData", nil, player)`. It returns only a usable Active soul for that exact Player instance, including a check of the confirmed lease age. A state string alone does not prove a session is still usable.

## Path arrays

Paths are ordered string or number keys:

```lua
soul:GetData({ "Stats", "Level" })
soul:GetData({ "Inventory", 1 })
soul:GetData() -- full live table
```

Missing leaves return `nil`. Traversal through a missing or non-table intermediate value fails safely. Gameplay access outside Active returns `nil`.

## Writing data

```lua
soul:SetData({ "Coins" }, 500)
soul:SetData({ "Stats", "Level" }, 10)
soul:SetData({ "Inventory" }, { "Sword", "Shield" })
```

Intermediate tables must already exist. `MetaData` is reserved and must not be changed by application code. `SetData` returns `nil` and warns for a value a DataStore cannot hold, or a write a DataStore would change or lose, so check its result when granting something of value.

## What can be saved

Strings, numbers, booleans, buffers, and tables of those. Infinity saves and comes back like any other number, and so does NaN, though `SetData` refuses NaN and a save warns about it.

A table is either a dictionary, with string keys, or an array, with number keys from 1. The top of a save is always a dictionary, because `MetaData` lives there.

Roblox goes by a table's length, `#t`. A table with a length is stored as an array that stops there, and every other key is lost, without an error. A table with no length is stored as a dictionary, with its number keys turned into strings. On its own, that can wipe out data:

```lua
-- On Roblox this comes back as { "Sword" }. Coins is gone, and so would be MetaData.
{ [1] = "Sword", Coins = 50 }
```

SoulStore protects against this in two places.

**`SetData` refuses what would not come back the same**, and returns `nil`:

```lua
soul:SetData({ 1 }, "Sword")                  -- a number key at the top of the save
soul:SetData({ "Inventory", 1 }, "Sword")     -- a number key on a dictionary
soul:SetData({ "Items", "Count" }, 3)         -- a string key on an array
soul:SetData({ "Levels", 1001 }, true)        -- a number key that does not start an array
soul:SetData({ "Items", 1.5 }, "Sword")       -- a fraction, zero, or a negative number
soul:SetData({ "Loadout" }, { "Sword", Name = "Main" })    -- a value with the same problems

-- Fine
soul:SetData({ "Levels", "1001" }, true)      -- number-like ids as strings
soul:SetData({ "Items", #items + 1 }, "Bow")  -- adding to an array
soul:SetData({ "Items", 2 }, nil)             -- removing from an array, even from the middle
```

**A save loses nothing, whatever it finds.** The live table from `GetData` has no such check, and neither does a save hook's copy, so the save handles what gets through:

| In the table | What is written | Comes back |
|---|---|---|
| An array with gaps, such as `{ "Sword", nil, "Bow" }` | The array, with its gaps | The same, with no warning |
| Number keys alongside string keys, at any depth | Everything, with the number keys as strings | Under string keys, so `t[1]` becomes `t["1"]` |
| Number keys too sparse to be an array, such as `{ [1] = "a", [2000] = "b" }` | The same | Under string keys |
| Fractions, zero and negative numbers as keys | The same | Under string keys |

Whatever will not come back the same gets a warning once per session, naming the table. Fix the code that wrote it: nothing was lost, but your game will not find it where it put it. See [Edge Cases](edge-cases.md) for more.

## Table references

`GetData` returns live table references for compatibility. Copy a table before changing it if listeners need a reliable old value:

```lua
local inventory = SoulStore.deepCopy(soul:GetData({ "Inventory" }))
table.insert(inventory, "New Item")
soul:SetData({ "Inventory" }, inventory)
```

Direct table mutation bypasses listeners and state guards. Do not retain data references across a yielding operation without rechecking session readiness. The final snapshot is captured when Ending begins, so later reference mutations do not change the final save.

## Reconciliation

`Reconcile` recursively fills missing fields on Active data, copying inserted tables and preserving existing values:

```lua
if soul:LoadData() then
    soul:Reconcile({
        Coins = 0,
        Level = 1,
        PremiumCurrency = 0,
    })
end
```

Only string keys are filled. An array the save already has is left as it is, even an empty one, so an entry the player no longer has does not come back and one entry never picks up another's fields. A missing array is copied whole:

```lua
-- Saved: { Slots = { 9 }, Sold = {} }
soul:Reconcile({ Slots = { 1, 2, 3 }, Sold = { "Starter" }, Items = { "Starter" } })
-- Result: { Slots = { 9 }, Sold = {}, Items = { "Starter" } }
```

Inside `SetOnLoad`, migrate the callback's data argument directly. The soul is still Pulling and gameplay methods are unavailable.
