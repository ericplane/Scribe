--!nonstrict
-- The randomness seam.
--
-- Scribe had no randomness at all before jitter, so this seam is the moment the
-- library stops being provably deterministic by inspection. What replaces that
-- guarantee is this: every draw routes through Internal/Rng, CI fails the build
-- on a raw math.random/Random.new in src/, and a simulation installs its own
-- stream. These specs pin the third leg.
--
-- Every test here MUST reset: Rng is a module-level singleton, so a leak hands
-- one spec's generator to whichever spec sorts next.

return function()
	local Root = script.Parent.Parent.Parent
	local Rng = require(Root.Scribe.Internal.Rng)
	local Universe = require(Root.Test.Sim.Universe)
	local Guard = require(Root.Test.Sim.Guard)
	local StubTransport = require(Root.Test.Helpers.StubTransport)

	describe("Rng", function()
		it("defaults to a working generator and restores after Reset", function()
			-- The default has to WORK, not merely exist. Random.new would satisfy
			-- "exists" on Roblox and be nil here, which is exactly the trap: a seam
			-- whose default is never exercised looks fine until something runs it.
			local before = Rng.Next()
			expect(type(before)).to.equal("number")

			Rng.Install({
				Next = function()
					return 0.25
				end,
			})
			expect(Rng.Next()).to.equal(0.25)

			Rng.Reset()
			local after = Rng.Next()
			expect(type(after)).to.equal("number")
			expect(after).never.to.equal(0.25)
		end)

		it("stays inside [0, 1) across many draws", function()
			-- The range is a contract, not a nicety. Jitter multiplies a delay by
			-- what comes back: >= 1 stretches a backoff past the bound its caller
			-- reasoned about, and < 0 turns a wait into an immediate retry, which
			-- is the synchronised herd this seam exists to break up.
			local lo, hi = 1, 0
			for _ = 1, 2000 do
				local v = Rng.Next()
				if v < lo then
					lo = v
				end
				if v > hi then
					hi = v
				end
			end
			expect(`lo={lo >= 0} hi={hi < 1}`).to.equal("lo=true hi=true")
			-- Not a constant, either: a stuck generator would satisfy the range.
			expect(hi > lo).to.equal(true)
		end)

		it("does not draw from math.random", function()
			-- math.random is a process global the game shares. If the default drew
			-- from it, reseeding here would steer Scribe's sequence -- and Scribe's
			-- draws would silently shift the game's.
			Rng.Reset()
			math.randomseed(1)
			local first = {}
			for i = 1, 8 do
				first[i] = Rng.Next()
			end
			math.randomseed(1)
			local second = {}
			for i = 1, 8 do
				second[i] = Rng.Next()
			end
			-- Reseeding the global between the two runs must not replay the seam.
			local identical = true
			for i = 1, 8 do
				if first[i] ~= second[i] then
					identical = false
					break
				end
			end
			expect(identical).to.equal(false)
		end)

		it("leaves the default alone when Install omits Next", function()
			local before = Rng.Next
			Rng.Install({})
			expect(Rng.Next).to.equal(before)
			Rng.Reset()
		end)

		-- The one node in this describe that is not host-agnostic: it loads two fresh
		-- copies of Rng through Sim's fork loader, which only the headless runner can
		-- do. Gated on the same capability as the simulation describe below.
		local itSim = if require(Root.Test.Sim.Available).Ready then it else itSKIP

		itSim("seeds its default from JobId, so a fleet does not draw in lockstep", function()
			-- The load-bearing half of the production default, and the one a unit
			-- test cannot reach directly: the seed is a module local, taken once,
			-- lazily. So this loads two FRESH copies of the module whose worlds
			-- differ in nothing but JobId, and compares their first draws.
			--
			-- Without this the decorrelation claim is untested, and a seed built
			-- from wall time alone would pass every other spec in this file while
			-- handing a whole deploy the same jitter -- the synchronised herd the
			-- seam exists to break up.
			local Loader = require(Root.Test.Sim.Loader)
			local SimHost = __SimHost

			local function firstDrawFor(jobId: string, now: number?): number
				local overrides = {}
				for key, value in SimHost.BaseGlobals do
					if key ~= "require" and key ~= "script" then
						overrides[key] = value
					end
				end
				-- Only the job id differs; everything else falls through to the
				-- harness's own `game`, so this cannot pass by accident of a
				-- missing global.
				overrides.game = setmetatable({ JobId = jobId }, { __index = SimHost.BaseGlobals.game })
				if now ~= nil then
					-- Clock's uninstalled default reads os.time, so pinning it here
					-- is what lets the wall-time half of the seed be tested at all.
					local fakeOs = table.clone(SimHost.BaseGlobals.os)
					fakeOs.time = function()
						return now
					end
					overrides.os = fakeOs
				end
				local fresh = Loader.RequireFresh(Root.Scribe.Internal.Rng, Loader.NewCache(), overrides)
				return fresh.Next()
			end

			-- Same second, different server: the fleet must not draw in lockstep.
			expect(firstDrawFor("job-aaaa", 1700000000)).never.to.equal(firstDrawFor("job-bbbb", 1700000000))
			-- Same identity and same second replays, so this is a seed rather than
			-- noise that happened to differ.
			expect(firstDrawFor("job-cccc", 1700000000)).to.equal(firstDrawFor("job-cccc", 1700000000))
			-- Same server, different boot: Studio leaves JobId empty, so wall time
			-- is the only thing separating one run there from the next.
			expect(firstDrawFor("", 1700000000)).never.to.equal(firstDrawFor("", 1700009999))

			-- Zero is xorshift32's fixed point: seeded there the generator returns
			-- zero forever, which is a server with no jitter at all and nothing to
			-- show for it. Not a hypothetical -- FNV-1a of the empty job id is
			-- 2166136261, so a clock reading of that same value XORs the seed to
			-- exactly zero. Constructed here rather than waited for.
			expect(firstDrawFor("", 2166136261) > 0).to.equal(true)
		end)

		it("replays exactly from an installed stream, which is the point", function()
			-- What a simulation needs: same stream in, same values out. This is the
			-- assertion that makes a seeded replay meaningful rather than decorative.
			local function pinned(seed: number)
				local state = seed
				return function()
					state = bit32.bxor(state, bit32.lshift(state, 13))
					state = bit32.bxor(state, bit32.rshift(state, 17))
					state = bit32.bxor(state, bit32.lshift(state, 5))
					return state / 4294967296
				end
			end
			local function drawFive(seed: number)
				Rng.Install({ Next = pinned(seed) })
				local out = {}
				for i = 1, 5 do
					out[i] = Rng.Next()
				end
				Rng.Reset()
				return table.concat(out, ",")
			end
			expect(drawFive(5150)).to.equal(drawFive(5150))
			expect(drawFive(5150)).never.to.equal(drawFive(9999))
		end)
	end)

	-- Installing a seam that nothing in src/ calls yet is scaffolding, and
	-- scaffolding nobody asserts on is scaffolding that is quietly wrong by the
	-- time it matters. These pin the wiring itself, so jitter can be added later
	-- against a stream that is already known to be per-server and released.
	describe("under the simulation", function()
		-- Sim-backed: these need a simulated universe, which only the headless runner can
		-- build, so under Studio they report SKIP rather than each failing the same way.
		-- See test/Sim/Available. Everything in the describe above is host-agnostic
		-- except the JobId node, which carries the same gate for the same reason.
		local it = if require(Root.Test.Sim.Available).Ready then it else itSKIP

		local universe

		afterEach(function()
			Guard.Reset()
			universe = nil
		end)

		it("gives each server its own stream and releases it on teardown", function()
			universe = Universe.new({
				Seed = 4171,
				Servers = 2,
				Transport = StubTransport.new({ AutoPump = false }),
				LatencyProfile = "Nominal",
				NoBudget = true,
				-- Out of reach on purpose: this spec is about seam wiring, and a
				-- bundle that slipped into Outage would change nothing about the
				-- draws but would make a failure here read as a health problem.
				StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
			})
			Guard.Install(universe)

			local a = universe:Server(1).Bundle
			local b = universe:Server(2).Bundle
			-- Separate module copies. One shared generator would make the whole
			-- fleet jitter in lockstep -- a model gentler than reality, which is the
			-- single direction this simulation must never err in.
			expect(a.Rng).never.to.equal(b.Rng)

			local first, second = {}, {}
			for i = 1, 10 do
				first[i] = a.Rng.Next()
				second[i] = b.Rng.Next()
			end
			expect(table.concat(first, ",")).never.to.equal(table.concat(second, ","))

			-- Teardown must hand the seam back, or the next spec inherits a
			-- generator bound to a scheduler that has already stopped.
			local installed = a.Rng.Next
			a:Teardown()
			expect(a.Rng.Next).never.to.equal(installed)
		end)

		it("refuses to build a bundle with no stream rather than silently running", function()
			-- The failure this prevents is not a crash, it is a green run that
			-- cannot be replayed: without a stream the bundle falls back to the
			-- production generator, seeded from wall time, and every digest
			-- comparison starts failing somewhere far from the omission.
			--
			-- Asserted on the MESSAGE, not merely on throwing. The first draft used
			-- `.to.throw()` and proved nothing: Bundle.new({}) also has no Sched, so
			-- it threw on that instead and the test passed with the guard deleted.
			-- A mutation that replaced the guard with a silent default survived,
			-- which is what exposed it.
			local Bundle = require(Root.Test.Sim.Bundle)
			local ok, err = pcall(Bundle.new, { Rng = nil })
			expect(ok).to.equal(false)
			expect(string.find(tostring(err), "requires an Rng stream", 1, true) ~= nil).to.equal(true)
		end)
	end)
end
