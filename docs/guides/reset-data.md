# Resetting Data

!!! danger
    Both reset functions **permanently delete** DataStore data. There is no undo.

---

## Reset a Single Player

```lua
SoulStore.resetData("PlayerData", tostring(player.UserId))
```

Calls `DataStoreService:RemoveAsync` on the given key. Retries once and warns on failure.

**When to use:**

- Clearing a QA tester's data between test runs.
- Admin command to reset a specific player's progress by request.
- Removing a known corrupted key.

---

## Reset an Entire DataStore

```lua
SoulStore.resetAllData("PlayerData")
```

This function:

1. Logs a warning block and **waits 10 seconds** before starting.
2. Pages through all keys using `ListKeysAsync`.
3. Calls `RemoveAsync` on each key sequentially, retrying on failure.
4. Logs progress per key and a completion message.

**Requirements:**

- Run in **Roblox Studio only** — never on a live server.
- No active player sessions in the target DataStore.
- Do not close Studio or interrupt the script during the operation.

!!! warning "No Cancel Mechanism"
    The only safety net is the 10-second delay. Once the loop begins it cannot be stopped from within the script.

---

## Safe Usage Pattern

Guard all reset calls behind a Studio-only check:

```lua
local RunService = game:GetService("RunService")

if RunService:IsStudio() then
    -- Uncomment exactly one:
    -- SoulStore.resetData("PlayerData", "123456789")
    -- SoulStore.resetAllData("PlayerData")
end
```

Run via the Studio command bar or a `Script` with `RunContext = Legacy`.