--!nonstrict
-- Which ProfileStore implementation the conformance suite runs against.
--
-- The suite exists to catch FakeProfileStore drifting from the real library. It is
-- written once and run twice: headless under Lune against the fake (every CI run),
-- and in Studio against the REAL ProfileStore and real DataStores (before a
-- release). An assertion that passes on one and fails on the other is a fidelity
-- bug, which is the class that has twice hidden a live defect: a view reporting the
-- wrong SessionLoadCount (which silently skipped every migration in a dry run) and
-- SetAsync throwing on failure (which let Scribe bank a Robux grant that never
-- persisted).
--
-- To run against the real library in Studio, build test.project.json, then set
--     require(<this module>).UseReal = true
-- before the test runner starts (top of test/RunTests.server.luau).
local Root = script.Parent.Parent.Parent

local ConformanceStore = {}

-- Flipped by the Studio runner. A plain module field rather than a global, so it
-- works identically under Lune and in Roblox with no environment assumptions.
ConformanceStore.UseReal = false

function ConformanceStore.IsReal(): boolean
	return ConformanceStore.UseReal == true
end

-- Returns (store, label). `store` is a ProfileStore-shaped module exposing .New.
function ConformanceStore.get(): (any, string)
	if ConformanceStore.IsReal() then
		-- Same folder the test place maps ServerPackages into (test.project.json).
		local ok, real = pcall(function()
			return require(Root.ServerPackages.ProfileStore)
		end)
		if ok and real then
			return real, "real"
		end
		error("ConformanceStore.UseReal is set but the real ProfileStore module could not be required")
	end
	return require(Root.Test.Helpers.FakeProfileStore).new(), "fake"
end

-- A key namespace that is safe to write to. Against the real library this touches a
-- real DataStore, so it is deliberately its own store name and prefix.
ConformanceStore.STORE = "ScribeConformance"
ConformanceStore.PREFIX = "CONF_"

return ConformanceStore
