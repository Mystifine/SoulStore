# Resetting Data

!!! danger
    Both reset functions **permanently delete** DataStore data. There is no undo.

---

## Reset a Single Player

```lua
SoulStore.resetData("PlayerData", nil, tostring(player.UserId))
```

The second argument is the DataStore scope; `nil` uses Roblox's default. Calls `RemoveAsync` on the given key, warns on failure, and returns whether it succeeded. Refused while this server has a session for that key.

**When to use:**

- Clearing a QA tester's data between test runs.
- Admin command to reset a specific player's progress by request.
- Removing a known corrupted key.

If the player has a session on another server, that session ends with `OwnershipLost` on its next save and does not bring the record back. `RemoveAsync` leaves old versions readable through version history for up to 30 days, so a right-to-erasure request should also go through [Roblox's automated process](https://create.roblox.com/docs/cloud-services/data-stores/best-practices).

---

## Reset an Entire DataStore

```lua
SoulStore.resetAllData("PlayerData", nil)
```

This function:

1. Refuses if this server has a session in the DataStore. Outside Studio, it also refuses unless the third argument repeats the DataStore name.
2. Logs a warning block and **waits 10 seconds** before starting.
3. Pages through all keys using `ListKeysAsync`.
4. Calls `RemoveAsync` on each key sequentially, retrying up to five times, and stops early if a key cannot be removed.
5. Logs a completion message and returns whether every key was removed.

**Requirements:**

- Run in **Roblox Studio** — not on a live server.
- No active player sessions in the target DataStore, on any server.
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
    -- SoulStore.resetData("PlayerData", nil, "123456789")
    -- SoulStore.resetAllData("PlayerData", nil)
end
```

Run via the Studio command bar or a `Script` with `RunContext = Legacy`.