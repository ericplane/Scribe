--!nonstrict
-- Install and reset every seam a simulation touches, in one place.
--
-- Meant to be used as a beforeEach/afterEach pair so no individual spec can
-- forget, and that matters more than it looks. Scribe's src modules are process
-- singletons under the harness cache, and specs run in alphabetical order -- so a
-- leaked virtual clock does not fail the spec that leaked it, it fails whichever
-- spec happens to sort next. The virtual epoch sits BELOW real os.time(), which
-- inverts every "this deadline is in the future" comparison in the suite: dozens
-- of assertions across many files, none of them near the cause.
--
-- The runner invokes afterEach outside its success guard, so a spec that throws
-- still resets. That is what makes this safe to rely on.

local Guard = {}

local installed = nil

--- Whether `service` is the headless shim's stand-in rather than a real Roblox
--- service, and therefore carries the test seams below.
---
--- THE PROBE HAS TO BE ON THE OBJECT, NOT ON THE MEMBER. `type(service.Install) ==
--- "function"` reads like a feature check and is one under Lune, where every service
--- is a plain table and an absent key is nil. On a real Roblox Instance, indexing a
--- member that does not exist RAISES -- "Install is not a valid member of
--- DataStoreService" -- so the guard is what breaks the moment it is asked the
--- question it exists to answer. It fired from the afterEach, which is why a single
--- unrunnable spec used to report two errors.
---
--- `typeof` is the idiom that works on both: it never touches a member, it answers
--- "Instance" for anything Roblox created, and the shim's own `typeof`
--- (lune/run-tests.luau) answers "table" for these services because they are tables
--- -- only ReplicatedStorage and its siblings are built as fake Instances there. So
--- the two hosts give opposite answers to the same expression, which is exactly what
--- a host probe needs to do.
---
--- Not a pcall. Wrapping the old probe in one would silence the error and turn Guard
--- into a no-op, which is far worse than a crash: the simulation would then run
--- against the LIVE DataStoreService with none of its disk installed.
local function hasTestSeams(service: any): boolean
	return typeof(service) ~= "Instance"
end

--- Point the shared DataStoreService at a simulation's disk and pin the GUID
--- sequence, so a replayed seed produces the same stored ids.
function Guard.Install(universe)
	local DataStoreService = game:GetService("DataStoreService")
	local HttpService = game:GetService("HttpService")

	if hasTestSeams(DataStoreService) then
		DataStoreService:Install(universe.Disk)
	end
	if hasTestSeams(HttpService) then
		HttpService:ResetGuidSequence(universe.Seed)
	end
	installed = universe
end

--- Put everything back. Safe to call when nothing was installed.
function Guard.Reset()
	local DataStoreService = game:GetService("DataStoreService")
	local HttpService = game:GetService("HttpService")

	if installed ~= nil then
		-- Tear down the servers first: each holds a bundle whose private Clock and
		-- Sched are still bound to a scheduler that is about to go away.
		pcall(function()
			installed:Destroy()
		end)
		installed = nil
	end
	if hasTestSeams(DataStoreService) then
		DataStoreService:Reset()
	end
	if hasTestSeams(HttpService) then
		HttpService:ResetGuidSequence()
	end
end

return Guard
