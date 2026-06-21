# Change Listeners

`:OnDataChanged()` lets you react to mutations made through `:SetData()`.

---

## Basic Usage

```lua
local conn = soul:OnDataChanged({ "Coins" }, function(oldValue, newValue)
    print(("Coins: %d → %d"):format(oldValue, newValue))
end)

soul:SetData({ "Coins" }, 100)
-- Output: Coins: 0 → 100
```

---

## Disconnecting

```lua
local conn = soul:OnDataChanged({ "Coins" }, function(old, new) end)
conn:Disconnect()
```

---

## Partial Path Matching

Listeners fire for every path segment a `:SetData()` call passes through:

```lua
soul:OnDataChanged({ "Stats" }, function(old, new)
    -- Fires when any key under "Stats" changes.
    -- old/new are the entire Stats sub-table.
end)

soul:OnDataChanged({ "Stats", "Level" }, function(old, new)
    -- Fires only for the exact "Stats.Level" key.
end)

soul:SetData({ "Stats", "Level" }, 10)
-- Both listeners above fire.
```

---

## Practical Patterns
**Track inventory size:**
```lua
soul:OnDataChanged({ "Inventory" }, function(_, newInv)
    print("Inventory size:", #newInv)
end)
```

**React to any stat change:**
```lua
soul:OnDataChanged({ "Stats" }, function(_, newStats)
    updateLeaderboard(player, newStats)
end)
```

!!! note "Separate Threads"
    Listeners are called via `task.spawn` and run concurrently. They never block `:SetData()`.