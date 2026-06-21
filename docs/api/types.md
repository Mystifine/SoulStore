# Types

SoulStore exports three Luau types for use in typed scripts.

---

## `SoulMetaData`

Internal metadata stored alongside every player's data table. Managed automatically — do not write to these fields manually.

```lua
export type SoulMetaData = {
    Locked     : boolean, -- true while a server owns the session
    SaveId     : number,  -- incremented on every successful write
    LastUpdate : number,  -- os.time() of the last DataStore write
    SessionId  : string,  -- game.JobId of the owning server; "" when unlocked
}
```

| Field | Type | Description |
|---|---|---|
| `Locked` | `boolean` | Whether the key is owned by an active server. |
| `SaveId` | `number` | Monotonic save counter. Useful for auditing. |
| `LastUpdate` | `number` | Timestamp of the last write; used to calculate lock expiry. |
| `SessionId` | `string` | `game.JobId` of the owner. Empty string when unlocked. |

!!! note
    `MetaData` lives at `soul.Data.MetaData` and is persisted alongside player data.

---

## `Soul`

Represents a single player's live data session.

```lua
export type Soul = {
    DatastoreId             : string,
    Player                  : Player,
    Data                    : { MetaData : SoulMetaData },
    LastAutoSave            : number,
    LoadState               : string, -- "Idle" | "Loading" | "Loaded"
    SaveState               : string, -- "Idle" | "Saving" | "SessionEnding"
    SessionEndBindableEvent : BindableEvent,
}
```

| Property | Type | Description |
|---|---|---|
| `DatastoreId` | `string` | DataStore name this soul reads/writes. |
| `Player` | `Player` | The associated `Player` instance. |
| `Data` | `table` | Live data table. Mutated by `:SetData()`. |
| `LastAutoSave` | `number` | Timestamp of the last auto-save. |
| `LoadState` | `string` | Current load phase. |
| `SaveState` | `string` | Current save phase. |
| `SessionEndBindableEvent` | `BindableEvent` | Fires once after a successful session-ending save. |

---

## `SoulStore`

The module table, usable as a static namespace.

```lua
export type SoulStore = {
    ClassName    : string,
    new          : (datastoreId: string, player: Player, defaultData: {}) -> Soul?,
    getSoul      : (datastoreId: string, player: Player) -> Soul?,
    playerExists : (player: Player?) -> boolean?,
    getMetaData  : () -> SoulMetaData,
    deepCopy     : (data: any?) -> any,
    output       : (fn: (any) -> any, ...any) -> nil,
    resetData    : (datastoreId: string, datastoreKey: string) -> nil,
    resetAllData : (datastoreId: string) -> nil,
}
```