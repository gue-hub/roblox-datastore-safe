# DataStoreSafe

A production-grade DataStore wrapper for Roblox. Solves the four problems every shipping game eventually hits.

```lua
local store = DataStoreSafe.new("PlayerData", {
    template = { coins = 0, level = 1 },
    autoSaveInterval = 60,
})

Players.PlayerAdded:Connect(function(player)
    local profile = store:Load(player.UserId)
    if not profile then
        player:Kick("Save load failed — try again in a minute.")
        return
    end
    profile.data.coins += 100 -- mutate freely, it auto-saves
end)

Players.PlayerRemoving:Connect(function(player)
    store:Release(player.UserId)
end)
```

## Why

`DataStoreService` is a thin wrapper over a global key-value store. Shipping with it raw means writing the same boilerplate every game:

1. **Session locking.** If a player joins server A, then quickly joins server B before A finished saving, both servers race the same key. Without a lock, one server's writes get clobbered and players see rollbacks.
2. **Transient failure.** `GetAsync` / `UpdateAsync` fail. Sometimes a lot. You have to retry with backoff, or you drop saves.
3. **Schema drift.** Today's data is `{ coins = 0 }`. Next month it's `{ wallet = { coins = 0 } }`. Old saves still need to load.
4. **Shutdown saves.** When the server dies, you have ~30 seconds before Roblox kills the process. Saves that haven't flushed yet are gone forever — unless you wired up `BindToClose`.

`DataStoreSafe` solves all four in one module with zero dependencies.

## Install

### Wally

```toml
[dependencies]
DataStoreSafe = "rumin/datastore-safe@1.0.0"
```

### Manual

Drop `src/` into `ServerStorage`, rename it to `DataStoreSafe`. The included `default.project.json` mounts it as a `ModuleScript` if you use Rojo.

## API

### `DataStoreSafe.new(name, options) -> Store`

Create a store.

| option | default | meaning |
| --- | --- | --- |
| `template` | `{}` | Default data shape; missing keys in saved data are filled from here. |
| `autoSaveInterval` | `60` | Seconds between background saves. Clamped to `[5, 270]`. |
| `retryCount` | `5` | Attempts per DataStore call before giving up. |
| `retryBaseDelay` | `1` | Base delay (seconds) for exponential backoff. |
| `schemaVersion` | `1` | Current schema version. Bumped when shape changes. |
| `migrate` | `nil` | `function(data, fromVersion, toVersion)` — mutate or return new data. |

### `Store:Load(userId) -> Profile?`

Atomically claim the session lock and read the player's data. Returns `nil` if another live server still holds the lock (call after a short delay, or kick the player).

### `Store:Get(userId) -> Profile?`

Return the in-memory profile if it's currently loaded, or `nil`.

### `Store:Release(userId)`

Save the data one last time and release the session lock so another server can claim it.

### `Store:ReleaseAll()`

Release every loaded profile in this store.

### `Profile.data`

The mutable data table. Read and write it directly — the background heartbeat will persist your changes within `autoSaveInterval` seconds.

### `Profile:Save() -> boolean`

Force an immediate save. Returns `true` on success.

## Behaviour

### Session locking

Each save stamps the key with `{ serverId, refreshedAt = os.time() }`. Other servers see the lock and refuse to load until either:

- the lock-holder explicitly releases it (clean shutdown / player leave), **or**
- five minutes pass without a refresh, at which point the lock is considered dead (server crash) and may be stolen.

The auto-save heartbeat refreshes the lock on every cycle, so as long as the server is alive, the lock stays fresh.

### Retries

DataStore calls are wrapped with exponential backoff: `delay * 2^(attempt - 1)`. With defaults that's `1s, 2s, 4s, 8s, 16s` for five attempts. Hitting all five and still failing is logged via `warn` and the call surfaces a `nil` to the caller.

### Reconciliation

After loading, missing keys are filled from `template` recursively. Existing keys are never overwritten, even if their type disagrees — that's a migration's job.

### Migrations

If `schemaVersion` is bumped, the `migrate` hook runs once on load before reconciliation:

```lua
schemaVersion = 2,
migrate = function(data, fromVersion, toVersion)
    if fromVersion == 1 then
        data.xp = data.experience or 0
        data.experience = nil
    end
    return data
end,
```

Migrations must be idempotent — they may run twice if the server crashes between load and first save.

### Shutdown

A single `game:BindToClose` flushes every loaded profile across every store, waiting up to 30 seconds for the writes to settle.

## Caveats

- Roblox enforces per-key, per-minute request limits. Don't crank `autoSaveInterval` below 30 in a busy server.
- Migrations run on the live server, not at load-time globally — old saves are migrated lazily when the user next plays.
- `template` is deep-copied per profile, so you can mutate `profile.data` without polluting future loads.

## License

MIT — see [LICENSE](LICENSE).
