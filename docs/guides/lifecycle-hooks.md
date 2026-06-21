# Lifecycle Hooks

## SetOnLoad

Called after data is read from the DataStore, **before** `LoadState` becomes `"Loaded"`. The callback receives the raw data table **by reference** — mutations affect what the soul stores in memory.

**Common use cases:** reconcile new fields, clamp/validate values, migrate old data schemas.

```lua
soul:SetOnLoad(function(data)
    -- Back-fill new fields
    if data.PremiumCurrency == nil then
        data.PremiumCurrency = 0
    end

    -- Clamp coin balance
    data.Coins = math.clamp(data.Coins or 0, 0, 1_000_000)

    -- Schema migration example
    if data.OldXP ~= nil then
        data.Stats = data.Stats or {}
        data.Stats.XP = data.OldXP
        data.OldXP = nil
    end
end)

soul:LoadData() -- must be called AFTER SetOnLoad
```

!!! note
    Call `:SetOnLoad()` **before** `:LoadData()`.

---

## SetOnSave

Called before each DataStore write. Receives a **deep copy** of `soul.Data`. Mutations affect only the snapshot — the live in-memory data is unchanged.

**Common use cases:** strip runtime fields, save computed aggregates, redact fields before storage.

```lua
soul:SetOnSave(function(snapshot)
    -- Strip fields only valid this session
    snapshot.ActiveBoostExpiry = nil
    snapshot.TempEventData     = nil

    -- Save aggregate playtime
    snapshot.TotalPlaytime = (snapshot.TotalPlaytime or 0)
        + (os.time() - sessionStartTime)
end)
```

!!! warning
    Mutations to the snapshot do **not** affect `soul.Data`. Update live data separately via `:SetData()` if needed.

---

## Execution Order

```
DataStore read
    └── SetOnLoad  (mutates live data in place)
        └── LoadState = "Loaded"
            └── ... game logic ...
                └── SaveData triggered
                    └── deep copy of soul.Data created
                        └── SetOnSave  (mutates snapshot only)
                            └── DataStore write
```