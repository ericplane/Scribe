--!strict
-- Process-scoped configuration.
--
-- ProfileStore's AUTO_SAVE_PERIOD is a module-wide constant, not a per-store one,
-- so the autosave cadence belongs to the PROCESS rather than to any one Scribe
-- bundle. Keeping the resolved value here (instead of only inside a bundle's
-- options) is what lets Scribe notice that two bundles asked for different
-- cadences, which previously resolved as a silent last-writer-wins.

local Config = {}

-- The interval actually pushed to ProfileStore, and where it came from.
Config.AutoSaveInterval = nil :: number?
Config.AutoSaveSource = nil :: string?

-- Set once a bundle has been constructed. Scribe.Configure refuses to run after
-- this point, because the value may already have been applied.
Config.BundleConstructed = false

return Config
