--!strict
-- Scribe's session/profile store: a vendored fork of ProfileStore v1.0.3.
--
-- Scribe needs four answers ProfileStore does not expose, and each is a question
-- about a single call rather than about the lock protocol underneath:
--
--   * did MY save land?          (Save() is fire-and-forget; OnAfterSave is global)
--   * did it land, or was I superseded?   (a succeeded UpdateAsync may write nothing)
--   * can I write to an offline profile without stealing a live session?
--   * can I control the shutdown order?
--
-- So the fork is additive: the lock itself (ForceLoadSession, the steal ladder,
-- ASSUME_DEAD, the MessagingService release, the stored record shape) is kept
-- byte-identical, every constant in it being a production incident somebody
-- already paid for. The stored key is unchanged, so a fleet can run mixed versions
-- and roll back without a migration.
--
-- What the fork adds is `Profile:SaveAwait()`, returning "Saved" | "NotOwned" |
-- "Failed" for that one call. Saved is the only outcome that means the data is on
-- disk; NotOwned is a successful round trip whose transform declined to write
-- because the session moved on, and reporting that as success is how a receipt
-- gets granted for a write nobody stored. Everything else behaves as upstream.

export type SaveOutcome = "Saved" | "NotOwned" | "Failed"

-- The vendored body is `--!nocheck` and untyped, so this is the one place that
-- casts. Callers get the type above rather than `any`.
local Store = require(script.ProfileStore) :: any

return Store
