--[[
	Scribe installation

	This bundle contains everything Scribe needs, laid out in two folders:

	    Packages          (put this in ReplicatedStorage)
	        Scribe
	    ServerPackages    (put this in ServerStorage)
	        ProfileStore

	Steps
	    1. Drag the "Packages" folder into ReplicatedStorage.
	    2. Drag the "ServerPackages" folder into ServerStorage.
	    3. Delete this outer folder once the two above are in place.
	    4. Require Scribe from a shared module:

	           local Scribe = require(game:GetService("ReplicatedStorage").Packages.Scribe)

	Notes
	    For the typed API and autocomplete, enable the new Luau type solver:
	    select Workspace in the Explorer and set UseNewLuauTypeSolver (under
	    Scripting) to Enabled. Scribe still runs correctly without it.

	    ProfileStore runs only on the server, which is why it lives in
	    ServerPackages instead of ReplicatedStorage.

	Prefer Wally? Add to wally.toml:  Scribe = "ericplane/scribe@__VERSION__"
]]

return "Scribe install guide: read the comment in this script."
