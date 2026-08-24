--!nonstrict
-- Jitter: whether a fleet that started together stays in lockstep.
--
-- Before this, every timed loop in src/ was a pure function of a constant and a
-- counter, so any two servers booted by one deploy computed the same offsets and
-- hit the DataStore at the same instants forever. Recovery from an outage was a
-- synchronised herd, and the periodic loops were a fleet-wide metronome.
--
-- MOST OF THESE PIN AN EXACT NUMBER, not a distribution, by installing a source
-- whose draw is fixed. With Next() pinned to 0 every jittered delay is exactly
-- three quarters of nominal, so each call site has one arithmetic consequence
-- that a missing Rng.Jitter changes. A first draft of this file asserted only
-- fleet-wide spread and was worthless: it passed with the refresh loop entirely
-- unjittered, because the warm-up and the tick each produce spread on their own,
-- so neither was necessary and a mutation of either survived.
--
-- Note what none of this claims. On a real mass rejoin the time is spent inside
-- the vendored ProfileStore's own unjittered backoff, which is not reachable
-- from src/ and is not touched here.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Rng = require(Root.Scribe.Internal.Rng)
	local Clock = require(Root.Scribe.Internal.Clock)
	local Client = require(Root.Scribe.Client)
	local Universe = require(Root.Test.Sim.Universe)
	local Guard = require(Root.Test.Sim.Guard)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local StubTransport = require(Root.Test.Helpers.StubTransport)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	-- Next() = 0 is the bottom of the band, so every jittered delay becomes
	-- exactly 0.75x nominal and the whole run is arithmetic rather than statistics.
	local FLOOR_FACTOR = 0.75

	describe("Rng.Jitter", function()
		it("stays inside a quarter either way, and never returns zero", function()
			-- The bound is what makes jitter safe to drop into loops that already
			-- carry timing assertions. The strictly-positive floor is what keeps a
			-- `while ... do Clock.Wait(n) end` loop yielding: under the simulation a
			-- wait of <= 0 goes straight back on the ready set without advancing
			-- virtual time, and the run burns to its step limit and reports a stall.
			local lo, hi = math.huge, 0
			for _ = 1, 3000 do
				local v = Rng.Jitter(4)
				lo, hi = math.min(lo, v), math.max(hi, v)
			end
			expect(`lo>=3 {lo >= 3} hi<5 {hi < 5} positive {lo > 0}`).to.equal("lo>=3 true hi<5 true positive true")
			expect(hi - lo > 0.5).to.equal(true) -- and it actually moves
		end)

		it("stays positive even if an installed source breaks its contract", function()
			Rng.Install({
				Next = function()
					return 0
				end,
			})
			expect(Rng.Jitter(1) > 0).to.equal(true)
			expect(Rng.Jitter(0) > 0).to.equal(true)
			Rng.Reset()
		end)

		it("is two-sided: it can shorten as well as lengthen", function()
			-- A one-sided design only ever waits longer, which passes every "has it
			-- happened yet" test while strictly slowing recovery.
			local shortened, lengthened = false, false
			for _ = 1, 500 do
				local v = Rng.Jitter(10)
				shortened = shortened or v < 10
				lengthened = lengthened or v > 10
			end
			expect(`short {shortened} long {lengthened}`).to.equal("short true long true")
		end)
	end)

	describe("under the simulation", function()
		-- Sim-backed: these need a simulated universe, which only the headless runner can
		-- build, so under Studio they report SKIP rather than each failing the same way.
		-- See test/Sim/Available. The nodes above this describe are host-agnostic.
		local it = if require(Root.Test.Sim.Available).Ready then it else itSKIP

		local universe

		afterEach(function()
			Guard.Reset()
			universe = nil
		end)

		local function fleet(servers: number, refreshInterval: number)
			universe = Universe.new({
				Seed = 8112,
				Servers = servers,
				Constants = { AUTO_SAVE_PERIOD = 20, SESSION_STEAL = 10, FIRST_LOAD_REPEAT = 2, ASSUME_DEAD = 60 },
				Transport = StubTransport.new({ AutoPump = false }),
				LatencyProfile = "Instant",
				NoBudget = true,
				StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
				Template = { Coins = Scribe.Int(0, { Min = 0 }) },
				Options = {
					Leaderboards = {
						Coins = { Stat = "Coins", Limit = 10, RefreshInterval = refreshInterval or 60 },
					},
				},
			})
			Guard.Install(universe)
			return universe
		end

		--- Pin every bundle's draw to the bottom of the band, before any loop ticks.
		local function pinAll(uni, servers: number)
			for i = 1, servers do
				uni:Server(i).Bundle.Rng.Install({
					Next = function()
						return 0
					end,
				})
			end
		end

		local function instantsOf(uni, storeName: string, method: string)
			local ordered = uni.Disk:GetOrderedDataStore(storeName)
			local seen = {}
			local real = ordered[method]
			ordered[method] = function(selfStore, ...)
				table.insert(seen, uni.Sched.Now)
				return real(selfStore, ...)
			end
			return seen
		end

		local function gaps(values: { number }): { number }
			local out = {}
			for i = 2, #values do
				table.insert(out, math.floor((values[i] - values[i - 1]) * 1000 + 0.5) / 1000)
			end
			return out
		end

		local function distinct(values: { number }): number
			local set, n = {}, 0
			for _, v in values do
				local key = math.floor(v * 1000)
				if set[key] == nil then
					set[key] = true
					n += 1
				end
			end
			return n
		end

		it("jitters the refresh loop's warm-up, moving the FIRST refresh", function()
			-- Without this every server in a fleet finishes its warm-up at the same
			-- instant with dueAt already elapsed, so the first refresh of a deploy is
			-- perfectly synchronised no matter what the tick does afterwards.
			--
			-- NOT pinned, and it cannot be: Sched.Spawn runs the loop immediately, so
			-- the warm-up is drawn during Universe.new -- before any handle exists to
			-- install through. The seeded per-server streams are what separate these,
			-- which is the property under test anyway.
			--
			-- The interval is longer than the run, so each server reads exactly once
			-- and every recorded instant is somebody's FIRST refresh.
			local uni = fleet(4, 60)
			local name = uni:Server(1).Bundle.Ctx.Leaderboards.BoardStoreName("Coins")
			local reads = instantsOf(uni, name, "GetSortedAsync")
			uni:Run(20)
			expect(#reads).to.equal(4)
			-- A fixed warm-up puts all four on one instant.
			expect(`distinct={distinct(reads)}`).never.to.equal("distinct=1")
		end)

		it("jitters the refresh loop's tick, moving every refresh after the first", function()
			-- The tick is what keeps servers apart over time: a fixed tick would let
			-- two servers that drew similar warm-ups stay collided forever, while a
			-- jittered one re-randomises the phase every second.
			--
			-- 61 is chosen with care, and two earlier drafts got it wrong. It has to
			-- clear the 60s MIN_REFRESH_INTERVAL floor (a request for 31 is silently
			-- clamped to 60), and it must NOT be a whole multiple of either tick --
			-- 30 and 60 are divisible by both 1 and 0.75, so the gap came out
			-- identical either way and a mutation reverting the tick survived.
			--
			-- Pinned, the loop ticks every 0.75s, so a board due at t+61 is taken at
			-- the first tick at or past it: ceil(61 / 0.75) * 0.75 = 61.5. A fixed 1s
			-- tick lands on 61 exactly.
			local uni = fleet(1, 61)
			pinAll(uni, 1)
			local name = uni:Server(1).Bundle.Ctx.Leaderboards.BoardStoreName("Coins")
			local reads = instantsOf(uni, name, "GetSortedAsync")
			uni:Run(200)
			local g = gaps(reads)
			expect(#g > 0).to.equal(true)
			expect(`near-pinned={math.abs(g[1] - 61.5) < 0.05} near-fixed={math.abs(g[1] - 61) < 0.05}`).to.equal(
				"near-pinned=true near-fixed=false"
			)
		end)

		it("jitters the write pacer's tick", function()
			local uni = fleet(1, 60)
			pinAll(uni, 1)
			local server = uni:Server(1)
			local name = server.Bundle.Ctx.Leaderboards.BoardStoreName("Coins")
			local writes = instantsOf(uni, name, "SetAsync")

			for i = 1, 6 do
				local player = FakePlayer.new(7100 + i)
				server:Join(7100 + i, player)
				uni:Run(1)
				server.Bundle.Data.Get(player).Coins.Increment(10 + i)
			end
			uni:Run(60)

			local g = gaps(writes)
			expect(#g > 0).to.equal(true)
			-- 1.5s nominal at the bottom of the band is 1.125; a fixed pacer gives
			-- 1.5. Compared with a tolerance because the write's own modelled latency
			-- lands inside the gap, so the figure is 1.125 plus a millisecond.
			local nominal, pinned = 1.5, 1.5 * FLOOR_FACTOR
			expect(`near-pinned={math.abs(g[1] - pinned) < 0.05} near-nominal={math.abs(g[1] - nominal) < 0.05}`).to.equal(
				"near-pinned=true near-nominal=false"
			)
		end)

		it("jitters the timed sweep", function()
			local uni = fleet(1, 60)
			pinAll(uni, 1)
			local server = uni:Server(1)
			local player = FakePlayer.new(7200)
			server:Join(7200, player)
			uni:Run(2)

			local sweeps = {}
			local realSweep = server.Bundle.Ctx.Timed.Sweep
			server.Bundle.Ctx.Timed.Sweep = function(...)
				table.insert(sweeps, uni.Sched.Now)
				return realSweep(...)
			end
			uni:Run(20)
			server.Bundle.Ctx.Timed.Sweep = realSweep

			local g = gaps(sweeps)
			expect(#g > 0).to.equal(true)
			-- 1s nominal at the bottom of the band; a fixed sweep would give 1.
			expect(`gap={g[1]}`).to.equal(`gap={1 * FLOOR_FACTOR}`)
		end)

		it("spreads a fleet's refreshes instead of firing them together", function()
			-- The headline claim, on the real seeded source rather than a pinned one:
			-- four servers built at the same virtual instant, sharing one board.
			local uni = fleet(4, 30)
			local name = uni:Server(1).Bundle.Ctx.Leaderboards.BoardStoreName("Coins")
			local reads = instantsOf(uni, name, "GetSortedAsync")
			uni:Run(200)

			expect(#reads > 8).to.equal(true) -- the loops actually ran
			-- In lockstep this would be one shared instant per cycle, i.e. about a
			-- quarter as many distinct values as reads.
			expect(distinct(reads) > #reads // 2).to.equal(true)
		end)

		it("jitters the profile-load retry backoff", function()
			-- The path the whole item is named for: a fleet that lost the DataStore
			-- at one instant must not come back at one instant. Scoped honestly --
			-- this loop only runs under LoadFailurePolicy = "Wait", and the default
			-- is "Kick".
			--
			-- Asserted on the ARGUMENT handed to Clock.Wait rather than on elapsed
			-- time, so it is an assertion rather than a five-second sleep.
			--
			-- ORDER MATTERS HERE. The recorder goes in AFTER the harness is built,
			-- because with the draw pinned the leaderboard refresh warm-up is also
			-- 5s -> 3.75 -- the very number this asserts. Recording from before
			-- construction would let the warm-up satisfy an assertion about the
			-- backoff, and the spec would prove nothing.
			local harness = TestCtx.make({ Options = { LoadFailurePolicy = "Wait" } })

			Rng.Install({
				Next = function()
					return 0
				end,
			})
			local waits = {}
			local realWait = Clock.Wait
			Clock.Install({
				Wait = function(seconds)
					table.insert(waits, seconds)
					return realWait(seconds)
				end,
			})

			harness.Fake.FailNextLoad = true
			local player = FakePlayer.new(7300)
			harness.Ctx.Persistence.OnPlayerAdded(player)
			-- The first attempt has failed and the loader is parked in its backoff.
			expect(harness.Ctx.Persistence.GetState(player)).to.equal("Loading")

			Clock.Reset()
			Rng.Reset()

			local backoff = nil
			for _, seconds in waits do
				if seconds > 3 then
					backoff = seconds
				end
			end
			-- Attempt 1 is a 5s backoff; pinned to the bottom of the band that is
			-- 3.75. Unjittered it would be exactly 5.
			expect(`backoff={backoff}`).to.equal(`backoff={5 * FLOOR_FACTOR}`)

			FakePlayer.leave(player) -- the retry tears the entry down when it wakes
			harness.Cleanup()
		end)

		it("jitters the client's Hello RETRY but leaves the first Hello immediate", function()
			-- A mass rejoin has every client sending its first Hello at connect and
			-- then retrying on the same 2 / 3 / 4.5 ladder. The retry is what needs
			-- spreading; the FIRST send must stay immediate, because every loopback
			-- handshake spec pumps a handful of frames and expects it to have gone,
			-- and delaying it would slow every ordinary join to fix a problem only a
			-- mass rejoin has.
			--
			-- A transport whose send always throws keeps `loaded` false, so the retry
			-- loop runs.
			local harness = TestCtx.make({ AutoPump = false })

			Rng.Install({
				Next = function()
					return 0
				end,
			})
			local waits = {}
			local realWait = Clock.Wait
			Clock.Install({
				Wait = function(seconds)
					table.insert(waits, seconds)
					return realWait(seconds)
				end,
			})

			local blocked = {
				Name = "Blocked",
				SendToServer = function()
					error("cannot fire 'Up': the calling thread is sandboxed")
				end,
				ListenClient = function() end,
				SendToClient = function() end,
				ListenServer = function() end,
			}
			local opts = table.clone(harness.Options)
			opts.Transport = blocked
			Client.new(opts, harness.Compiled)
			for _ = 1, 6 do
				task.wait()
			end

			Clock.Reset()
			Rng.Reset()

			-- The first send happened without waiting for anything.
			expect(#Scribe.GetRecentLogs({ Code = "SEND_FAIL", Limit = 5 }) > 0).to.equal(true)

			-- 2s nominal pinned to the bottom of the band is 1.5. The band excludes
			-- every other loop's pinned interval (sweep and refresh tick at 0.75,
			-- pacer at 1.125), so nothing else can satisfy this.
			local retry = nil
			for _, seconds in waits do
				if seconds > 1.2 and seconds < 1.9 then
					retry = seconds
				end
			end
			expect(`retry={retry}`).to.equal(`retry={2 * FLOOR_FACTOR}`)

			harness.Cleanup()
		end)

		it("keeps a seeded run byte-identical despite the extra draws", function()
			-- Jitter is only acceptable because it stays deterministic under a seed.
			local function run()
				local uni = fleet(3, 60)
				uni:Run(150)
				local digest = uni:Digest()
				Guard.Reset()
				universe = nil
				return digest
			end
			expect(run()).to.equal(run())
		end)
	end)
end
