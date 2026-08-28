--!strict
-- Process-scoped configuration. ProfileStore's AUTO_SAVE_PERIOD is a module-wide
-- constant, not a per-store one, so the autosave cadence belongs to the process
-- rather than to any one bundle. Keeping the resolved value here lets Scribe notice
-- two bundles asking for different cadences instead of silently taking the last.

local Config = {}

-- The interval actually pushed to ProfileStore, and where it came from.
Config.AutoSaveInterval = nil :: number?
Config.AutoSaveSource = nil :: string?

-- Set once a bundle has been constructed. Scribe.Configure refuses to run after
-- this point, since the value may already have been applied.
Config.BundleConstructed = false

return Config
