# Change Listeners

`:OnDataChanged()` lets you react to mutations made through `:SetData()`.

Pass `nil` as the path to observe the full data table. Listener paths distinguish string and number keys, including keys containing periods. Direct mutation of a `GetData` table does not trigger a notification.

Both values are copies, taken before and after the write, so a listener can keep them or change them without affecting the saved data. To read the current data later, use `GetData` or keep what the next notification brings. A `nil` path listener's copies leave out `MetaData`. Copies are only made at levels something is listening to, and they cost more the larger the table is, so prefer listening to the narrowest path you need.

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
    Listeners run through `task.spawn`; keep callbacks short. Notifications that have not started are skipped after disconnection or session end. All listener registrations are cleaned up when the soul settles.
