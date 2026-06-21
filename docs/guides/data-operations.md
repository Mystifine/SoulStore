# Data Operations

## Path Arrays

All data access uses **path arrays** — ordered lists of keys describing how to traverse `soul.Data`.

```lua
-- Given:
-- { Stats = { Level = 5, XP = 120 }, Inventory = { "Sword", "Shield" } }

soul:GetData({ "Stats", "Level" }) --> 5
soul:GetData({ "Stats" })          --> { Level = 5, XP = 120 }
soul:GetData({ "Inventory", 1 })   --> "Sword"
soul:GetData()                     --> full data table
```

## Reading Data

```lua
local coins = soul:GetData({ "Coins" })
local level = soul:GetData({ "Stats", "Level" })
local all   = soul:GetData()
```

Returns `nil` and logs a warning if any key in the path doesn't exist.

## Writing Data

```lua
soul:SetData({ "Coins" }, 500)
soul:SetData({ "Stats", "Level" }, level + 1)
soul:SetData({ "Inventory" }, { "Sword", "Shield", "Potion" })
```

!!! warning "Intermediate Keys Must Exist"
    `:SetData()` traverses but does not create intermediate tables. Define all nested structures in `DEFAULT_DATA`.

## Mutating Sub-Tables

`:GetData()` returns a **reference** to the live table. Mutate and write back to trigger listeners:

```lua
local inv = soul:GetData({ "Inventory" })
table.insert(inv, "New Item")
soul:SetData({ "Inventory" }, inv) -- triggers listeners
```

## Reconcile

Merges a source table into `soul.Data`, adding only keys that are missing:

```lua
local DEFAULTS = {
    Coins           = 0,
    Level           = 1,
    PremiumCurrency = 0, -- newly added field
}

soul:SetOnLoad(function()
    soul:Reconcile(DEFAULTS) -- adds PremiumCurrency to old saves only
end)
```

## Checking Load State

Verify `soul.LoadState` before operating on data outside of the initial `PlayerAdded` flow:

```lua
if soul.LoadState == "Loaded" then
    soul:SetData({ "Coins" }, soul:GetData({ "Coins" }) + 10)
end
```