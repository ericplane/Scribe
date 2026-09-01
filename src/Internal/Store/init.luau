--!strict
-- Scribe's session/profile store: a vendored fork of ProfileStore v1.0.3, additive only.
-- The lock (ForceLoadSession, the steal ladder, ASSUME_DEAD, the MessagingService
-- release, the record shape) and the stored key are byte-identical to upstream, so a
-- fleet can run mixed versions and roll back without a migration.
--
-- Added: `Profile:SaveAwait()`, an answer for one call where upstream Save() is
-- fire-and-forget (Saved is the only outcome meaning the data is on disk; NotOwned is a
-- round trip whose transform declined to write); `UpdateOfflineAsync`, a compare-and-set
-- for an absent player; and `BeginClose`/`AwaitClose`, so the owner drives shutdown order.

export type SaveOutcome = "Saved" | "NotOwned" | "Failed"

-- The vendored body is `--!nocheck` and untyped; this is the one place that casts,
-- so callers get the type above rather than `any`.
local Store = require(script.ProfileStore) :: any

return Store
