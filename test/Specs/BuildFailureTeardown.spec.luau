--!nonstrict
-- A bundle that fails to build must not leave anything running.
--
-- The subsystem constructors install PROCESS-GLOBAL listeners as they go:
-- `Replication` takes a `RunService.PostSimulation` handler and a
-- `Health.OnStatusChanged` connection, and both are singletons shared by every
-- bundle in the process. The build order already says as much -- the comment above
-- the `Start()` calls notes that "a constructor throwing partway (bad config) must
-- never leave an orphaned loop running against a half-built ctx" -- and defers the
-- LOOPS for exactly that reason.
--
-- The CONSTRUCTORS themselves were not covered. `Leaderboards.new` and
-- `Monetization.new` validate their config and throw on a bad board or product,
-- and they run AFTER `Replication.new`. When one of them throws, `Server.build`
-- unwinds with no Data object -- so nothing exists to call `Stop()` on, and the
-- listeners `Replication` installed stay attached for the life of the process,
-- driving a flush pump against a ctx that was never finished.
--
-- Config errors at boot are exactly when this happens, and a developer fixing one
-- typically retries in the same Studio session.
return function()
	local Root = script.Parent.Parent.Parent
	local RunService = game:GetService("RunService")
	local Scribe = require(Root.Scribe)
	local Server = require(Root.Scribe.Server)
	local Health = require(Root.Scribe.Internal.Health)
	local Template = require(Root.Scribe.Internal.Template)
	local FakeProfileStore = require(Root.Test.Helpers.FakeProfileStore)
	local StubTransport = require(Root.Test.Helpers.StubTransport)

	--- Whether the frame signal's connections can be counted on this host.
	---
	--- The headless runner's PostSimulation is a FakeSignal whose handlers are an
	--- ordinary table; Roblox's is an RBXScriptSignal, and ordinary code cannot ask one
	--- how many connections it holds. The probe is on the signal's TYPE rather than on
	--- whether it has a `_handlers` member, because reading an unknown member off a real
	--- RBXScriptSignal RAISES instead of returning nil -- so a member probe would be the
	--- thing that breaks. Same idiom, same reason, as TestCtx.Step.
	local framesCountable = typeof(RunService.PostSimulation) ~= "RBXScriptSignal"

	--- Count the listeners on the two process-global signals a Replication install
	--- attaches to. Health.OnStatusChanged is a Scribe Signal (walk `_head`);
	--- PostSimulation is the headless shim's FakeSignal (count `_handlers`), and nil
	--- where the host will not show them.
	---
	--- Nil rather than 0, because every assertion below is a "no leak" comparison and a
	--- census that quietly reported zero on a host that cannot see the listeners would
	--- satisfy all of them while measuring nothing. The Health half is a plain linked
	--- list and reads the same everywhere, so Studio still checks that half rather than
	--- skipping the node.
	local function census(): (number, number?)
		local status = 0
		local node = (Health.OnStatusChanged :: any)._head
		while node do
			status += 1
			node = node._next
		end
		if not framesCountable then
			return status, nil
		end
		local frame = 0
		for _ in (RunService.PostSimulation :: any)._handlers do
			frame += 1
		end
		return status, frame
	end

	--- Fail unless both census readings match, naming what moved.
	local function expectNoLeak(label: string, status0: number, frame0: number?, status1: number, frame1: number?)
		local frameDelta = if frame0 ~= nil and frame1 ~= nil then frame1 - frame0 else nil
		if status1 ~= status0 or (frameDelta ~= nil and frameDelta ~= 0) then
			error(`{label}: Health {status1 - status0}, PostSimulation {frameDelta or "unmeasured"}`)
		end
	end

	local compiled = Template.Compile({ Coins = Scribe.Int(0, { Min = 0 }) }, {})

	--- Build with `options` layered over the same base TestCtx.make uses, returning
	--- (threw, errorMessage, data). Built directly rather than through the harness
	--- because the harness cannot survive a build that throws.
	local function build(extra)
		local options = {
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Transport = StubTransport.new(),
			ProfileStore = FakeProfileStore.new(),
			ProfileStoreIndex = "Default",
			ProfileKeyPrefix = "PLAYER_",
			UseMock = true,
			OwnReceipts = false,
			KickOnSessionEnd = false,
			LogLevel = "Fatal",
			Banner = false,
		}
		for key, value in extra do
			options[key] = value
		end
		local ok, result = pcall(Server.build, options, compiled)
		if ok then
			return false, nil, result
		end
		return true, tostring(result), nil
	end

	describe("a build that throws partway", function()
		it("leaves nothing attached once a SUCCESSFUL bundle is stopped", function()
			-- THE CONTROL, and the measurement's own calibration: it proves the census
			-- can see the listeners at all, and that a clean Stop reclaims them. A
			-- broken census would report zero leaks for every arm below.
			local status0, frame0 = census()

			local threw, err, data = build({})
			expect(threw).to.equal(false)
			expect(err).to.equal(nil)

			local statusUp, frameUp = census()
			expect(statusUp > status0).to.equal(true)
			if framesCountable then
				expect((frameUp :: number) > (frame0 :: number)).to.equal(true)
			end

			data.Stop()
			local status1, frame1 = census()
			expectNoLeak("a clean Stop left something attached", status0, frame0, status1, frame1)
		end)

		it("leaves nothing attached when a LEADERBOARD constructor throws", function()
			-- Leaderboards.new runs after Replication.new, so its config error unwinds
			-- past listeners that are already installed.
			local status0, frame0 = census()

			local threw, err = build({ Leaderboards = { Rich = {} } })
			expect(threw).to.equal(true)
			expect(err).to.be.ok()

			local status1, frame1 = census()
			expectNoLeak("build failure leaked listeners", status0, frame0, status1, frame1)
		end)

		it("leaves nothing attached when a MONETIZATION constructor throws", function()
			-- The last constructor in the chain, so it unwinds past the most.
			local status0, frame0 = census()

			local threw, err = build({ Products = { X = {} } })
			expect(threw).to.equal(true)
			expect(err).to.be.ok()

			local status1, frame1 = census()
			expectNoLeak("build failure leaked listeners", status0, frame0, status1, frame1)
		end)

		it("still reports the ORIGINAL config error, not a teardown error", function()
			-- The developer is here because of a typo. Whatever cleanup runs on the way
			-- out must not replace the message that tells them which one.
			local _threw, boardErr = build({ Leaderboards = { Rich = {} } })
			expect(string.find(tostring(boardErr), "Rich", 1, true) ~= nil).to.equal(true)

			local _threw2, productErr = build({ Products = { X = {} } })
			expect(string.find(tostring(productErr), "X", 1, true) ~= nil).to.equal(true)
		end)

		it("does not leak across repeated failed builds", function()
			-- The Studio loop this actually costs: fix a typo, hit play, fail again.
			-- One leak per attempt is what makes it worth fixing rather than a curio.
			local status0, frame0 = census()
			for _ = 1, 5 do
				local threw = build({ Products = { X = {} } })
				expect(threw).to.equal(true)
			end
			local status1, frame1 = census()
			expectNoLeak("5 failed builds leaked listeners", status0, frame0, status1, frame1)
		end)
	end)
end
