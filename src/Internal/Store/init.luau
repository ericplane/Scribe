--!strict
-- Scribe's session/profile store: a vendored fork of ProfileStore v1.0.3.
--
-- Additive only. The lock (ForceLoadSession, the steal ladder, ASSUME_DEAD, the
-- MessagingService release, the stored record shape) is kept byte-identical, every
-- constant in it being a production incident somebody already paid for, and the
-- stored key is unchanged, so a fleet can run mixed versions and roll back without
-- a migration.
--
-- The addition is `Profile:SaveAwait()`, an answer about one call rather than about
-- the lock underneath: upstream Save() is fire-and-forget and OnAfterSave is global.
-- Saved is the only outcome that means the data is on disk. NotOwned is a
-- successful round trip whose transform declined to write because the session moved
-- on, and reporting that as success is how a receipt gets granted for a write
-- nobody stored.
--
-- Also added: UpdateOfflineAsync, a compare-and-set write for an absent player so the
-- "still offline" check and the write are one call rather than a read-then-write race,
-- and BeginClose/AwaitClose, so the owner drives shutdown order instead of racing this
-- module's own BindToClose.

export type SaveOutcome = "Saved" | "NotOwned" | "Failed"

-- The vendored body is `--!nocheck` and untyped; this is the one place that casts,
-- so callers get the type above rather than `any`.
local Store = require(script.ProfileStore) :: any

return Store
