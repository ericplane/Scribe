--[[
	Scribe installation

	This bundle contains everything Scribe needs, in one folder:

	    Packages          (put this in ReplicatedStorage)
	        Scribe

	Steps
	    1. Drag the "Packages" folder into ReplicatedStorage.
	    2. Delete this outer folder once it is in place.
	    3. Require Scribe from a shared module:

	           local Scribe = require(game:GetService("ReplicatedStorage").Packages.Scribe)

	Notes
	    For the typed API and autocomplete, enable the new Luau type solver:
	    select Workspace in the Explorer and set UseNewLuauTypeSolver (under
	    Scripting) to Enabled. Scribe still runs correctly without it.

	    Scribe vendors its own patched ProfileStore inside the package, so there
	    is no ServerPackages folder and nothing else to install. If your game
	    already uses ProfileStore, keep it -- Scribe never binds to a copy it
	    finds elsewhere, so the two coexist.

	Prefer Wally? Add to wally.toml:  Scribe = "ericplane/scribe@__VERSION__"
]]

return "Scribe install guide: read the comment in this script."
