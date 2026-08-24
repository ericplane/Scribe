--!nonstrict
-- Telling apart the four ways a DataStore call can go wrong.
--
-- Before this, Scribe had one distinction and it was a guess: PROFILE_TOO_LARGE,
-- inferred from the profile's own measured size because the error carried no
-- structure anyone read. Everything else was binary. That collapses a throttle
-- (back off), a service blip (retry), a timeout (the write MAY HAVE LANDED) and
-- a permanently invalid payload (retrying is useless) into one counter.
--
-- The unit specs pin the classifier. The simulation specs pin the split
-- end-to-end, one armed fault class at a time, asserting on counters rather than
-- on elapsed time.

return function()
	local Root = script.Parent.Parent.Parent
	local Failure = require(Root.Scribe.Internal.Failure)
	local Universe = require(Root.Test.Sim.Universe)
	local Guard = require(Root.Test.Sim.Guard)
	local Scribe = require(Root.Scribe)
	local StubTransport = require(Root.Test.Helpers.StubTransport)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	describe("classifier", function()
		local function classifies(cases: { [string]: string })
			for message, expected in cases do
				expect(`{message} -> {Failure.Classify(message)}`).to.equal(`{message} -> {expected}`)
			end
		end

		it("reads a timeout as unresolved, not as a failure", function()
			-- The one that earns the module its keep. The write may have committed
			-- before the error came back, so treating it as a clean failure is how a
			-- retry becomes a double-apply.
			classifies({ ["504: Datastore request timed out."] = "Unresolved" })
		end)

		it("reads the throttle family as throttled", function()
			classifies({
				["301: GetAsync request dropped. Request was throttled, but throttled request queue was full."] = "Throttled",
				["302: SetAsync request dropped."] = "Throttled",
				["303: UpdateAsync request dropped."] = "Throttled",
				["306: RemoveAsync request dropped."] = "Throttled",
			})
		end)

		it("reads service-side trouble as failed", function()
			classifies({
				["502: API Services rejected request with error. Status=Forbidden"] = "Failed",
				["503: DataStore Request successful, but key not found."] = "Failed",
			})
		end)

		it("reads permanently invalid input as rejected, not as retryable", function()
			-- These fail identically forever. Counting them beside transient errors
			-- is what lets one bad key look like an outage.
			classifies({
				["101: Key name can't be empty."] = "Rejected",
				["103: Value not allowed for this key."] = "Rejected",
				["105: Serialized value exceeds 4194304 limit."] = "Rejected",
				-- 5xx by family, but permanent misuse: the metadata caps.
				["511: Metadata attribute size exceeds 300 bytes limit."] = "Rejected",
				["512: The UserIds limit was exceeded."] = "Rejected",
			})
		end)

		it("falls back to the code family for a code it has never seen", function()
			-- So a code Roblox adds later is classified sensibly instead of landing
			-- in whatever the default happens to be.
			classifies({
				["199: some future validation error"] = "Rejected",
				["307: some future throttle"] = "Throttled",
				["599: some future service error"] = "Failed",
			})
		end)

		it("treats anything it cannot read as failed, the safe default", function()
			classifies({
				["Requested version is not valid for this key."] = "Failed",
				["Undefined error"] = "Failed",
				[""] = "Failed",
			})
			expect(Failure.Classify(nil)).to.equal("Failed")
			expect(Failure.Classify(504)).to.equal("Failed")
		end)

		it("only reads a code at the START of the message", function()
			-- The anchor is the whole reason this is safe to run on arbitrary error
			-- text. A loose search would eventually find a number inside a key name
			-- or a quoted value and report a confident WRONG class -- worse than the
			-- honest "Failed" an unreadable message gets.
			expect(Failure.Classify("failed writing key 504: totally unrelated")).to.equal("Failed")
			expect(Failure.CodeOf("failed writing key 504: totally unrelated")).to.equal(nil)
			expect(Failure.CodeOf("504: Datastore request timed out.")).to.equal(504)
			expect(Failure.CodeOf("no code here")).to.equal(nil)
		end)
	end)

	describe("under the simulation", function()
		-- Sim-backed: these need a simulated universe, which only the headless runner can
		-- build, so under Studio they report SKIP rather than each failing the same way.
		-- See test/Sim/Available. The nodes above this describe are host-agnostic.
		local it = if require(Root.Test.Sim.Available).Ready then it else itSKIP

		local universe

		local function build(overrides)
			local config = {
				Seed = 20260817,
				Servers = 1,
				Constants = {
					AUTO_SAVE_PERIOD = 300,
					SESSION_STEAL = 40,
					FIRST_LOAD_REPEAT = 5,
					LOAD_REPEAT_PERIOD = 10,
					ASSUME_DEAD = 630,
					START_SESSION_TIMEOUT = 120,
				},
				Transport = StubTransport.new({ AutoPump = false }),
				LatencyProfile = "Fixed",
				NoBudget = true,
				-- Out of reach: this spec is about how failures are COUNTED, and a
				-- bundle that slipped into Outage would start refusing the operations
				-- being counted.
				StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
			}
			for key, value in overrides or {} do
				config[key] = value
			end
			universe = Universe.new(config)
			Guard.Install(universe)
			return universe
		end

		afterEach(function()
			Guard.Reset()
			universe = nil
		end)

		local function joined(uni)
			local server = uni:Server(1)
			local player = FakePlayer.new(9001)
			server:Join(9001, player)
			uni:Run(5)
			return server, player
		end

		--- Force save failures of one armed kind and report how they were counted.
		local function countBy(kind: string)
			local uni = build({ Template = { Coins = Scribe.Int(0, { Min = 0 }) } })
			local server, player = joined(uni)
			uni.Disk:Arm({ Kind = kind, Op = "UpdateAsync", Count = 50 })
			for _ = 1, 4 do
				server.Bundle.Data.Get(player).Coins.Increment(1)
				uni.Sched:Spawn(function()
					pcall(function()
						return server.Bundle.Data.Flush(player, { Timeout = 20 })
					end)
				end)
				uni:Run(5)
			end
			uni:Run(20)
			local m = server.Bundle.Scribe.GetMetrics()
			return {
				Throttled = m.DataStoreErrors_Throttled or 0,
				Failed = m.DataStoreErrors_Failed or 0,
				Unresolved = m.DataStoreErrors_Unresolved or 0,
				Rejected = m.DataStoreErrors_Rejected or 0,
				Total = m.DataStoreErrors or 0,
				HealthFailures = m.HealthFailures or 0,
			}
		end

		it("routes a throttle to the throttle counter and nowhere else", function()
			local c = countBy("Throttled")
			expect(c.Throttled > 0).to.equal(true)
			expect(`failed={c.Failed} unresolved={c.Unresolved} rejected={c.Rejected}`).to.equal(
				"failed=0 unresolved=0 rejected=0"
			)
		end)

		it("routes a timeout to the unresolved counter, not to failed", function()
			-- The simulated Indeterminate fault COMMITS and then raises, which is the
			-- only honest way to exercise this: the outcome really is unknown to the
			-- caller rather than merely labelled that way.
			local c = countBy("Indeterminate")
			expect(c.Unresolved > 0).to.equal(true)
			expect(`throttled={c.Throttled} failed={c.Failed} rejected={c.Rejected}`).to.equal(
				"throttled=0 failed=0 rejected=0"
			)
		end)

		it("routes a service error to the failure counter", function()
			local c = countBy("ServiceError")
			expect(c.Failed > 0).to.equal(true)
			expect(`throttled={c.Throttled} unresolved={c.Unresolved} rejected={c.Rejected}`).to.equal(
				"throttled=0 unresolved=0 rejected=0"
			)
		end)

		it("keeps the classes summing to the total, so nothing is lost or double-counted", function()
			local c = countBy("ServiceError")
			expect(c.Throttled + c.Failed + c.Unresolved + c.Rejected).to.equal(c.Total)
		end)

		it("still feeds Health exactly as before, throttles included", function()
			-- The classification is purely additive by design. Deciding that a
			-- throttle should NOT move the health status is a separate change with
			-- Robux downstream of it, and this pins that it has not happened by
			-- accident here.
			local c = countBy("Throttled")
			expect(c.HealthFailures >= c.Throttled).to.equal(true)
			expect(c.HealthFailures > 0).to.equal(true)
		end)

		it("carries the class and the raw code on the log entry", function()
			-- The metric says how many; the log says which one and why. Sinks added
			-- with AddLogSink see this context, so it is a real surface rather than
			-- a debugging aid -- and the Code is what makes an error Roblox adds
			-- later visible as "unclassified" instead of silently transient.
			local uni = build({ Template = { Coins = Scribe.Int(0, { Min = 0 }) } })
			local server, player = joined(uni)
			uni.Disk:Arm({ Kind = "Indeterminate", Op = "UpdateAsync", Count = 50 })
			server.Bundle.Data.Get(player).Coins.Increment(1)
			uni.Sched:Spawn(function()
				pcall(function()
					return server.Bundle.Data.Flush(player, { Timeout = 20 })
				end)
			end)
			uni:Run(25)

			local logs = server.Bundle.Scribe.GetRecentLogs({ Code = "PROFILE_STORE_ERROR", Limit = 5 })
			expect(#logs > 0).to.equal(true)
			local entry = logs[#logs]
			expect(`class={entry.Context and entry.Context.Class}`).to.equal("class=Unresolved")
			expect(`code={entry.Context and entry.Context.Code}`).to.equal("code=504")
		end)

		it("counts a save wait that timed out separately from a save that failed", function()
			-- The purest unresolved case, and the sharpest demonstration of why the
			-- distinction matters: the timeout is set BELOW the disk's write latency,
			-- so the caller is told `false` for a save that then lands. Before this
			-- counter there was nothing anywhere to tell those two apart.
			local uni = build({ Template = { Coins = Scribe.Int(0, { Min = 0 }) } })
			local server, player = joined(uni)

			local result
			server.Bundle.Data.Get(player).Coins.Increment(5)
			uni.Sched:Spawn(function()
				pcall(function()
					result = server.Bundle.Data.Flush(player, { Timeout = 0.01 })
				end)
			end)
			uni:Run(30)

			local m = server.Bundle.Scribe.GetMetrics()
			expect(result).to.equal(false) -- the caller was told "no"
			expect(m.SaveWaitTimeouts).to.equal(1)
			-- ...for a save that in fact succeeded, and which was never a failure.
			expect(m.SavesFailed or 0).to.equal(0)
			expect((m.SavesOk or 0) > 0).to.equal(true)
			expect(#server.Bundle.Scribe.GetRecentLogs({ Code = "SAVE_WAIT_TIMEOUT", Limit = 5 })).to.equal(1)
		end)
	end)
end
