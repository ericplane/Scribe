--!nonstrict
-- Failure.Report: one call, and the log that follows Health's own dedup.
--
-- Reporting a failure used to be four calls -- Classify, Health.ReportFailure, a
-- Metrics.Add or two, a Log line -- repeated at eleven sites. Two things came out
-- of that, and both are pinned here.
--
-- The one with a cost attached: Health deliberately folds retries of ONE operation
-- into one problem, because ProfileStore retries a failing key by itself and
-- counting those as N problems drove servers to Outage, which refuses Robux for
-- every player on them. The log had no such rule on the identical event stream, so
-- an outage produced one warn() and one JSONEncode per attempt -- the most
-- expensive call in the stack -- and evicted the diagnostic ring while it was at
-- it. Measured on one permanently-failing key over 120 virtual seconds: 40 log
-- lines before, 5 after, which is exactly the number of distinct problems the
-- state machine counted.
--
-- The one with no cost until it bites: three sites reported no log at all, so a
-- failed GDPR erase reached no sink and no dashboard. Those are pinned at the
-- bottom, driven through the real public calls rather than by poking the module.
--
-- What is deliberately NOT folded: a report with no subject key. Folding needs an
-- identity, and that is the practical reason to pass one.

local TestCtx = require(script.Parent.Parent.Helpers.TestCtx)

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Universe = require(Root.Test.Sim.Universe)
	local Guard = require(Root.Test.Sim.Guard)
	-- Sim-backed: every node below needs a simulated universe, which only the headless
	-- runner can build. Under Studio they report SKIP instead of each failing with the
	-- same missing capability -- see test/Sim/Available for why it cannot be provided.
	local it = if require(Root.Test.Sim.Available).Ready then it else itSKIP
	local StubTransport = require(Root.Test.Helpers.StubTransport)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	local universe

	--- A universe built for its private Failure/Health pair and its virtual clock,
	--- so the 25-second retry cooldown is an assertion rather than a sleep.
	local function build()
		universe = Universe.new({
			Seed = 5150,
			Servers = 1,
			Constants = { AUTO_SAVE_PERIOD = 300, SESSION_STEAL = 40, FIRST_LOAD_REPEAT = 5, ASSUME_DEAD = 630 },
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Instant",
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 3, RecoverStreak = 5 },
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = { LogRingSize = 4096 },
		})
		Guard.Install(universe)
		local server = universe:Server(1)
		return universe, server, server.Bundle.Failure
	end

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	--- One ordinary keyed report, shaped like the ProfileStore save path.
	local function report(Failure, key: string?, code: string?, err: string?)
		return Failure.Report({
			Subsystem = "ProfileStore",
			Key = key,
			Error = err or "502: API Services rejected request with error.",
			Metric = "DataStoreErrors",
			Category = "Persistence",
			Code = code or "PROFILE_STORE_ERROR",
			Message = "save failed",
			Context = { Key = key },
		})
	end

	local function logs(server, code: string)
		return server.Bundle.Scribe.GetRecentLogs({ Code = code, Limit = 200 })
	end

	describe("the fold", function()
		it("logs once for a subject that keeps failing, not once per attempt", function()
			local _uni, server, Failure = build()
			for _ = 1, 10 do
				report(Failure, "PLAYER_1")
			end

			-- One problem, one line. Health already counted these as one problem; the
			-- console used to disagree with it ten times over.
			expect(#logs(server, "PROFILE_STORE_ERROR")).to.equal(1)

			local metrics = server.Bundle.Scribe.GetMetrics()
			-- The ERROR counters still count every attempt. Folding both would lose the
			-- evidence that something is retrying hard, which is the one signal that
			-- separates a stuck key from a quiet one.
			expect(metrics.HealthFailures).to.equal(10)
			expect(metrics.DataStoreErrors).to.equal(10)
			-- ...and the fold itself is counted, so a suppressed line is never silent.
			expect(metrics.FailuresCollapsed).to.equal(9)
		end)

		it("logs again once the retry window has passed", function()
			-- Folding retries must not mean forgiving a subject forever: a key that is
			-- STILL failing half a minute later is still worth a line.
			local uni, server, Failure = build()
			for _ = 1, 4 do
				report(Failure, "PLAYER_1")
				uni:Run(30) -- past the 25s retry cooldown, inside the 60s window
			end
			expect(#logs(server, "PROFILE_STORE_ERROR")).to.equal(4)
		end)

		it("carries the folded tally out on the line that ends the fold", function()
			-- Without this an operator sees one line every twenty-five seconds and
			-- cannot tell two retries from two hundred.
			local uni, server, Failure = build()
			for _ = 1, 7 do
				report(Failure, "PLAYER_1")
			end
			uni:Run(30)
			report(Failure, "PLAYER_1")

			local entries = logs(server, "PROFILE_STORE_ERROR")
			expect(#entries).to.equal(2)
			-- The first line stood for itself; the second stands for the six that were
			-- folded into the first.
			expect(`first={entries[1].Context.Repeats}`).to.equal("first=nil")
			expect(entries[2].Context.Repeats).to.equal(6)
			-- The caller's own context survives alongside it.
			expect(entries[2].Context.Key).to.equal("PLAYER_1")
		end)

		it("keeps distinct subjects distinct", function()
			local _uni, server, Failure = build()
			report(Failure, "PLAYER_1")
			report(Failure, "PLAYER_2")
			report(Failure, "PLAYER_3")
			expect(#logs(server, "PROFILE_STORE_ERROR")).to.equal(3)
		end)

		it("never folds a report that carries no subject", function()
			-- The reason passing a Key matters. An unkeyed report has no identity to
			-- fold on, so it logs every time -- exactly as every failure did before
			-- any of this existed.
			local _uni, server, Failure = build()
			for _ = 1, 5 do
				report(Failure, nil)
			end
			expect(#logs(server, "PROFILE_STORE_ERROR")).to.equal(5)
			expect(server.Bundle.Scribe.GetMetrics().FailuresCollapsed).to.equal(nil)
		end)

		it("always logs the first failure of a subject", function()
			-- The invariant that keeps the fold from ever hiding a problem outright:
			-- however aggressive the folding gets, the first report of an identity is
			-- always on the record.
			local _uni, server, Failure = build()
			report(Failure, "PLAYER_9")
			expect(#logs(server, "PROFILE_STORE_ERROR")).to.equal(1)
			expect(server.Bundle.Scribe.GetMetrics().FailuresCollapsed).to.equal(nil)
		end)

		it("reports whether it logged, so the fold is observable at the call site", function()
			-- A 504, deliberately, and NOT the helper's default 502. Both halves of the
			-- return are asserted here, but the class half was asserted against "Failed"
			-- -- which is what Classify returns for an unreadable message, for no message
			-- at all, and for the whole 5xx family. Hard-coding `return "Failed"` in
			-- Failure.Report therefore passed the entire suite: the assertion could not
			-- tell a working classifier from a constant. 504 is Unresolved, so it can.
			local _uni, _server, Failure = build()
			local class, logged = report(Failure, "PLAYER_1", nil, "504: Datastore request timed out.")
			expect(class).to.equal("Unresolved")
			expect(logged).to.equal(true)
			local _, second = report(Failure, "PLAYER_1", nil, "504: Datastore request timed out.")
			expect(second).to.equal(false)
		end)
	end)

	describe("the class dimension", function()
		it("counts a class breakdown where a real error was classified", function()
			local _uni, server, Failure = build()
			Failure.Report({
				Subsystem = "ProfileStore",
				Key = "PLAYER_1",
				Error = "504: Datastore request timed out.",
				Metric = "DataStoreErrors",
				Category = "Persistence",
				Code = "PROFILE_STORE_ERROR",
				Message = "timed out",
			})
			local metrics = server.Bundle.Scribe.GetMetrics()
			expect(metrics.DataStoreErrors).to.equal(1)
			expect(metrics.DataStoreErrors_Unresolved).to.equal(1)
		end)

		it("does not invent one where there was no error to read", function()
			-- A class defaulted from nothing would file every load failure under
			-- "Failed", which reads as a measurement and is not one: it means only
			-- that the call site had no message to classify.
			local _uni, server, Failure = build()
			Failure.Report({
				Subsystem = "ProfileLoad",
				Key = "PLAYER_1",
				Metric = "ProfileLoadFailures",
				Level = "Error",
				Category = "Persistence",
				Code = "PROFILE_LOAD_FAIL",
				Message = "profile failed to load",
			})
			local metrics = server.Bundle.Scribe.GetMetrics()
			expect(metrics.ProfileLoadFailures).to.equal(1)
			expect(metrics.ProfileLoadFailures_Failed).to.equal(nil)
		end)
	end)

	describe("on the real save path", function()
		it("folds an outage down to the problems Health counted", function()
			-- The integration half: the fold has to hold through the real
			-- ProfileStore.OnError handler, not just when the module is poked.
			local uni, server, _Failure = build()
			local players = {}
			for i = 1, 3 do
				local p = FakePlayer.new(65000 + i)
				server:Join(65000 + i, p)
				table.insert(players, p)
			end
			uni:Run(2)

			uni.Disk:Arm({ Kind = "ServiceError", Key = "PLAYER_65001", Count = 1000000 })
			for _ = 1, 40 do
				for _, player in players do
					local data = server.Bundle.Data.Get(player)
					if data then
						data.Coins.Increment(1)
						uni.Sched:Spawn(function()
							pcall(function()
								return server.Bundle.Data.Flush(player, { Timeout = 20 })
							end)
						end)
					end
				end
				uni:Run(3)
			end

			local metrics = server.Bundle.Scribe.GetMetrics()
			local lines = #logs(server, "PROFILE_STORE_ERROR")
			-- Every attempt is still counted as an error...
			expect(`errors={metrics.HealthFailures >= 20}`).to.equal("errors=true")
			-- ...and the console is told about the problem, not about every attempt.
			-- 120 virtual seconds at a 25s cooldown is at most six lines; asserted as
			-- a bound rather than an exact count because the flush cadence is the
			-- scheduler's business, not this spec's.
			expect(`lines={lines}, folded={lines < metrics.HealthFailures / 2}`).to.equal(`lines={lines}, folded=true`)
			expect(`some={lines > 0}`).to.equal("some=true")
			expect(`counted={metrics.FailuresCollapsed > 0}`).to.equal("counted=true")
		end)
	end)

	describe("the sites that used to report nothing", function()
		-- Three failures answered their caller and reached no log at all: an offline
		-- write, a version restore, and -- the sharp one -- a GDPR erase. Nothing an
		-- operator alerts on ever saw them. Driven through the public calls.
		it("logs a failed GDPR erase", function()
			-- No local session: all three of these refuse outright while one exists,
			-- and a refusal is the compare-and-set working rather than a failure.
			local harness = TestCtx.make({})
			harness.Fake.FailReads = true
			local ok = harness.Data.Erase(88001)
			harness.Fake.FailReads = false

			expect(ok).to.equal(false)
			expect(#Scribe.GetRecentLogs({ Code = "PROFILE_ERASE_FAIL", Limit = 5 }) > 0).to.equal(true)
			harness.Cleanup()
		end)

		it("logs a failed version restore", function()
			local harness = TestCtx.make({})
			harness.Fake.FailReads = true
			local ok = harness.Data.RestoreVersion(88002, "some-version")
			harness.Fake.FailReads = false

			expect(ok).to.equal(false)
			expect(#Scribe.GetRecentLogs({ Code = "PROFILE_RESTORE_FAIL", Limit = 5 }) > 0).to.equal(true)
			harness.Cleanup()
		end)

		it("logs a failed offline write", function()
			local harness = TestCtx.make({})
			harness.Fake.FailReads = true
			local ok = harness.Data.UpdateOffline(88003, function() end)
			harness.Fake.FailReads = false

			expect(ok).to.equal(false)
			expect(#Scribe.GetRecentLogs({ Code = "OFFLINE_WRITE_FAIL", Limit = 5 }) > 0).to.equal(true)
			harness.Cleanup()
		end)
	end)
end
