--!nonstrict
-- Luau does not flag an unknown key in an INLINE table literal passed to an
-- optional table parameter. It only flags one bound to a local first, and inline is
-- the shape everyone writes:
--
--   Data.Flush(player, { Forcce = true })   -- no diagnostic
--   local o = { Forcce = true }
--   Data.Flush(player, o)                   -- TypeError
--
-- So a typo'd option type-checks clean and silently does nothing: the flush is not
-- forced, the filter is not applied. These runtime guards are the only layer that
-- catches it, not belt-and-braces on top of the type.

return function()
	local RunService = game:GetService("RunService")
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local Config = require(Root.Scribe.Internal.Config)
	local Log = require(Root.Scribe.Internal.Log)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	it("refuses an unknown option on Flush", function()
		local harness = TestCtx.make()
		local player = harness.Join(97501)

		expect(function()
			harness.Data.Flush(player, { Forcce = true })
		end).to.throw()
		expect(function()
			harness.Data.Flush(player, { Force = true, Timeoutt = 5 })
		end).to.throw()
		-- The real spellings still work, including no options at all.
		expect(function()
			harness.Data.Flush(player, { Force = true, Timeout = 5 })
		end).never.to.throw()
		expect(function()
			harness.Data.Flush(player)
		end).never.to.throw()

		harness.Cleanup()
	end)

	it("refuses an unknown key on a purchase filter", function()
		local harness = TestCtx.make()
		local player = harness.Join(97502)

		expect(function()
			harness.Data.GetPurchases(player, { Kindd = "Robux" })
		end).to.throw()
		expect(function()
			harness.Data.GetPurchases(player, { Kind = "Robux", Limit = 5 })
		end).never.to.throw()
		expect(function()
			harness.Data.GetPurchases(player)
		end).never.to.throw()

		harness.Cleanup()
	end)

	it("does not flag a real option the release added", function()
		-- The startup scan warns for any key missing from KNOWN_OPTION_KEYS, and that
		-- table is hand-maintained alongside ScribeOptions<T>. A new option added to
		-- the type and forgotten here makes a guard whose whole purpose is catching
		-- "OnPlayerLeavng" cry wolf on "OnPlayerLeaving", on every Studio start.
		--
		-- The scan sits above Template.Compile, so an uncompilable template reaches it
		-- and then aborts, which keeps this from building a real bundle.
		--
		-- The scan only runs in Studio. In a Studio place that is already true, so
		-- nothing needs patching; headless, RunService is a plain shim table and can
		-- be patched. Assigning to the REAL RunService throws ("IsStudio is not a
		-- valid member"), so the patch has to be conditional rather than
		-- unconditional, which is what made this pass headless and fail in Studio.
		local realIsStudio = nil
		if not RunService:IsStudio() then
			realIsStudio = RunService.IsStudio
			RunService.IsStudio = function()
				return true
			end
		end
		local constructed = Config.BundleConstructed
		Config.BundleConstructed = false

		local before = #Log.GetRecent({ Code = "UNKNOWN_OPTION" })
		pcall(Scribe, {
			Template = { [1] = 0 }, -- refused by the compiler, after the scan has run
			ProfileStoreIndex = "D",
			ProfileKeyPrefix = "P_",
			Banner = false,
			OnPlayerInit = function() end,
			OnPlayerLeaving = function() end,
			OnPlayerLeavng = function() end, -- the typo the scan exists for
		})
		local flagged = {}
		local recent = Log.GetRecent({ Code = "UNKNOWN_OPTION" })
		for i = before + 1, #recent do
			table.insert(flagged, recent[i].Context and recent[i].Context.Option)
		end

		if realIsStudio ~= nil then
			RunService.IsStudio = realIsStudio
		end
		Config.BundleConstructed = constructed

		expect(table.concat(flagged, ",")).to.equal("OnPlayerLeavng")
	end)

	it("names the options it did expect", function()
		local harness = TestCtx.make()
		local player = harness.Join(97503)

		local ok, err = pcall(function()
			harness.Data.Flush(player, { Forcce = true })
		end)
		expect(ok).to.equal(false)
		-- A bare "unknown option" leaves the caller guessing at the spelling.
		expect(string.find(tostring(err), "Force", 1, true) ~= nil).to.equal(true)
		expect(string.find(tostring(err), "Timeout", 1, true) ~= nil).to.equal(true)

		harness.Cleanup()
	end)
end
