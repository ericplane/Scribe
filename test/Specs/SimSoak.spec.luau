--!nonstrict
-- Long randomised runs checked against a reference model, plus the sensitivity
-- sweeps that say which conclusions actually hold.
--
-- The deep runs are gated behind SCRIBE_SOAK=1 so the ordinary suite stays fast;
-- a short version of each runs by default, because a soak nobody ever runs is a
-- soak that has quietly stopped working. Every run here is bounded by VIRTUAL time
-- and step count, never by wall clock -- a wall-clock bound would make results
-- depend on the machine.

return function()
	local Root = script.Parent.Parent.Parent
	local Universe = require(Root.Test.Sim.Universe)
	local Guard = require(Root.Test.Sim.Guard)
	-- Sim-backed: every node below needs a simulated universe, which only the headless
	-- runner can build. Under Studio they report SKIP instead of each failing with the
	-- same missing capability -- see test/Sim/Available for why it cannot be provided.
	local it = if require(Root.Test.Sim.Available).Ready then it else itSKIP
	local Model = require(Root.Test.Sim.Model)
	local Workload = require(Root.Test.Sim.Workload)
	local Uncertain = require(Root.Test.Sim.Uncertain)
	local Scribe = require(Root.Scribe)
	local StubTransport = require(Root.Test.Helpers.StubTransport)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	-- The template the workload writes to. `Log` is a string that ops APPEND to,
	-- which is what makes writes non-commutative: two appends can never cancel out
	-- and hide a lost update the way two arithmetic changes can.
	local TEMPLATE = {
		Log = Scribe.String("", { MaxLength = 1024 }),
		Coins = Scribe.Int(0, { Min = 0 }),
	}

	local CONSTANTS = {
		AUTO_SAVE_PERIOD = 20,
		SESSION_STEAL = 10,
		FIRST_LOAD_REPEAT = 2,
		LOAD_REPEAT_PERIOD = 3,
		ASSUME_DEAD = 60,
		START_SESSION_TIMEOUT = 120,
	}

	-- Deep runs are opt-in via SCRIBE_SOAK=1. Read through the harness escape
	-- hatch, because @lune/process is unreachable from a shim-loaded module -- an
	-- earlier version required it inside a pcall and silently never enabled the
	-- soak, which is precisely how a long test quietly stops being a long test.
	-- Absent under Studio, where SimHost does not exist, so the short runs apply.
	-- A plain global in the harness environment. Reading an undefined global is nil
	-- rather than an error, so under Studio -- where SimHost does not exist -- this
	-- simply leaves the short runs in place.
	local SOAK = __SimHost ~= nil and __SimHost.Env ~= nil and __SimHost.Env.SCRIBE_SOAK == "1"

	local universe

	local function newUniverse(overrides)
		local config = {
			Seed = 4171,
			Servers = 3,
			Constants = CONSTANTS,
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Nominal",
			NoBudget = true,
			Template = TEMPLATE,
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
		}
		for key, value in overrides or {} do
			config[key] = value
		end
		universe = Universe.new(config)
		Guard.Install(universe)
		return universe
	end

	--- Run a randomised workload and check every player's log against the model.
	local function soak(options)
		local uni = newUniverse(options.Universe)
		local model = Model.new()
		local workload = Workload.new({
			Universe = uni,
			Model = model,
			Seed = (options.Universe and options.Universe.Seed) or 4171,
			MaxPlayers = options.MaxPlayers or 24,
		})

		-- Arm the fault model BEFORE the first step, or the early joins run clean
		-- and the run is a nominal one wearing a fault-injection label -- which is
		-- exactly what this helper used to do for every caller.
		if options.FaultRate then
			uni.Disk:SetFaultRate(options.FaultRate)
		end

		for step = 1, options.Steps do
			workload:Step(FakePlayer)
			uni:Run(options.SecondsPerStep or 3)
			if options.CrashAt and step == options.CrashAt then
				workload:Crash(1)
			end
		end

		-- Everyone leaves cleanly, so what remains is a durable claim.
		for userId in table.clone(workload:Players()) do
			workload:Leave(userId)
		end

		-- Heal first, then require progress: TigerBeetle's technique. A system that
		-- is uncorrupted but STUCK is the failure a high-CCU study most wants to
		-- catch, and it is invisible unless the faults stop and recovery is demanded.
		uni.Disk:Heal()
		uni:Run(120)
		uni:Quiesce()
		-- Scaled with the run, not fixed. A flat 300 was a number tuned against the
		-- 50-step CI run and then applied unchanged to the 300- and 400-step
		-- SCRIBE_SOAK ones, which is the shape of bug this whole tier is about: a
		-- bound that means "generous" in one mode and "tight" in another, on a
		-- gate whose failure reads as a product defect.
		--
		-- Steps * 3 is the run's own length in virtual seconds (SecondsPerStep
		-- defaults to 3 below), so the drain budget is a fixed fraction of the work
		-- that has to drain. The floor keeps every existing caller at least as much
		-- room as it had. Measured after the Quiesce fix: BOTH modes settle in two
		-- windows -- 10 virtual seconds -- so this is headroom rather than a
		-- threshold anything currently sits near.
		local settleBudget = options.SettleSeconds or math.max(300, options.Steps * 2)
		local settled = uni:Settle(settleBudget)

		-- Sessions still held after everyone has left, counted across every LIVE
		-- server. A crashed server is skipped on purpose: it was never told anything
		-- and its locks are supposed to outlive it.
		--
		-- This is the difference between "recovers" meaning STORAGE WENT QUIET and it
		-- meaning EVERY SESSION RELEASED, and the two were not the same: the run
		-- settled with leaked Ready entries autosaving forever, and nothing looked.
		local heldSessions = 0
		for index = 1, #uni.Servers do
			local server = uni:Server(index)
			if server ~= nil and not server.Dead and server.Bundle ~= nil then
				for _ in server.Bundle.Ctx.Persistence.Entries do
					heldSessions += 1
				end
			end
		end

		local violations = {}
		-- Counted so a spec can prove the checker had something to check. "Zero
		-- violations" over zero acknowledged writes is not a passing safety claim,
		-- it is a spec that never looked -- and that failure mode is invisible
		-- unless the count is asserted alongside it.
		local ackedChecked = 0
		for userId in model._players do
			local record = uni.Disk.Keyspace:Read("Default", `PLAYER_{userId}`)
			local log = record and record.Value and record.Value.Data and record.Value.Data.Log
			ackedChecked += #model:Expected(userId)
			for _, violation in model:Verify(userId, log) do
				table.insert(violations, violation)
			end
		end

		return {
			Universe = uni,
			Model = model,
			Workload = workload,
			Settled = settled,
			HeldSessions = heldSessions,
			Violations = violations,
			AckedChecked = ackedChecked,
			-- Reported rather than inferred. Disk:Heal() above clears the RATES but
			-- deliberately not the STATS, so these still describe the run that just
			-- happened -- and a spec claiming to inject faults has to be able to
			-- prove it injected some.
			Injected = uni.Disk.Faults.Stats.Injected,
			Indeterminate = uni.Disk.Faults.Stats.IndeterminateCommits,
		}
	end

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	describe("randomised workload against the reference model", function()
		it("loses no acknowledged write under nominal conditions", function()
			-- The core safety claim. Every op reported durable must appear exactly
			-- once in the stored log: missing is a lost update, twice is a
			-- double-apply.
			local result = soak({ Steps = if SOAK then 400 else 60 })

			expect(result.Settled).to.equal(true)
			-- And every session RELEASED, which "settled" does not imply: storage can go
			-- quiet with profiles still loaded and autosaving. Measured before Hop
			-- released its source server and the simulation marked a leaving player
			-- gone: 1 leaked session at CI scale, 3 at soak scale.
			expect(`held={result.HeldSessions}`).to.equal("held=0")
			expect(#result.Violations).to.equal(0)
			-- ...and the workload actually did something, or the assertion above is
			-- vacuously true.
			expect(result.Workload.Stats.Mutations > 0).to.equal(true)
			expect(result.Workload.Stats.Hops > 0).to.equal(true)
			-- ...and the checker actually held the run to durable writes, rather than
			-- passing because there were none.
			expect(result.AckedChecked > 0).to.equal(true)
		end)

		it("recovers, and stays consistent, after a burst of injected faults", function()
			-- INDETERMINATE, not a transient error, and that choice is the point.
			-- The write COMMITS and then the call raises, so ProfileStore -- which
			-- treats every error as "did not happen" -- retries a save that already
			-- landed. That is the double-apply path, and DuplicateWrite is precisely
			-- what the reference model's append-only token log exists to detect.
			--
			-- ONE kind, not a mix. Faults.Next iterates `_rates` in pairs order, so
			-- with two kinds set, WHICH one fires depends on table layout rather than
			-- on the seed -- and a soak whose fault kind is not reproducible is not
			-- a soak, it is a lottery.
			--
			-- 0.5 is not arbitrary either. Measured across a rate sweep on this seed:
			-- the acknowledged-write count collapses as the rate climbs (22 acked at
			-- 0.0, 9 at 0.30, 2 at 0.60, ZERO at 0.90) because Workload.Leave only
			-- acks when Flush confirms -- so a high rate makes "no violations" true
			-- because nothing was checked. Above ~0.55 the run also stops settling,
			-- which would fail this test for liveness rather than for safety and read
			-- as a flake. 0.5 sits where both still hold.
			local result = soak({
				Steps = if SOAK then 300 else 50,
				Universe = { Seed = 909 },
				FaultRate = { Indeterminate = 0.5 },
			})
			expect(result.Settled).to.equal(true)
			expect(`held={result.HeldSessions}`).to.equal("held=0")
			expect(#result.Violations).to.equal(0)
			-- The faults were real. Without these two the test reverts, silently, to
			-- being a duplicate of the nominal run with a different seed -- which is
			-- what it was.
			expect(result.Injected > 0).to.equal(true)
			expect(result.Indeterminate > 0).to.equal(true)
			-- ...and the checker still had acknowledged writes to hold the run to.
			-- This guard matters MORE here than on the nominal test: raising the
			-- fault rate is exactly what drives the checked set to zero, so adding
			-- injection without this assertion makes the test weaker, not stronger.
			expect(result.AckedChecked > 0).to.equal(true)
		end)

		it("reports crash loss without calling it corruption", function()
			-- Writes made after the last save are legitimately gone when a server
			-- dies. Failing the run for them would train everyone to ignore the
			-- checker, so they are recorded separately and never asserted on.
			local result = soak({
				Steps = if SOAK then 200 else 45,
				CrashAt = if SOAK then 100 else 20,
				Universe = { Seed = 77 },
			})

			expect(result.Settled).to.equal(true)
			expect(`held={result.HeldSessions}`).to.equal("held=0")
			-- No CONSISTENCY violations, whatever the crash took with it.
			expect(#result.Violations).to.equal(0)
		end)

		it("holds Scribe to what it acknowledged, even when the server dies immediately after", function()
			-- THE test the no-lost-writes claim actually rests on, and the reason the
			-- nominal soak above cannot be it.
			--
			-- Under nominal conditions every save genuinely succeeds, so a Scribe that
			-- always answered "durable" is behaviourally identical to one that answers
			-- honestly -- there is no input on which they disagree. Measured: making
			-- AwaitSave return true unconditionally leaves all ten SimSoak tests green.
			-- And even a wrong answer is invisible there, because Workload.Leave acks
			-- and then leaves, and the LEAVING save persists the data regardless.
			--
			-- So: make the flush the only save that could ever cover these writes, by
			-- killing the server the instant it answers. A false "durable" then has
			-- nowhere to hide and shows up as a LostUpdate.
			local uni = newUniverse({ Servers = 1, Seed = 31337 })
			local model = Model.new()
			local workload = Workload.new({ Universe = uni, Model = model, Seed = 31337 })

			local userId = workload:Join(FakePlayer)
			uni:Run(30)
			expect(workload:Mutate(userId)).never.to.equal(nil)

			-- Every UpdateAsync on this key now fails BEFORE the transform, so nothing
			-- commits. Indeterminate would be the wrong kind here on purpose: it commits
			-- and then raises, so the data would be on disk anyway and a lie about
			-- durability would go unpunished.
			uni.Disk:Arm({
				Kind = "ServiceError",
				Op = "UpdateAsync",
				Store = "Default",
				Key = `PLAYER_{userId}`,
				Count = 500,
			})

			workload:FlushNow(userId)
			uni:Run(120)

			-- Scribe refused, so nothing was acknowledged.
			expect(workload.Stats.FlushRefused).to.equal(1)
			expect(workload.Stats.FlushOk).to.equal(0)
			expect(#model:Expected(userId)).to.equal(0)

			-- The server dies before any other save can cover the write.
			workload:Crash(1)
			uni:Quiesce()

			local record = uni.Disk.Keyspace:Read("Default", `PLAYER_{userId}`)
			local log = record and record.Value and record.Value.Data and record.Value.Data.Log
			-- The write really is gone -- which is correct, because nobody promised it.
			expect(#Model.Parse(log)).to.equal(0)
			-- ...and because it was never acknowledged, that is not a violation.
			expect(#model:Verify(userId, log)).to.equal(0)
		end)

		it("counts an acknowledged write as durable, and finds it on disk after the crash", function()
			-- The control arm for the test above, and it has to exist: the assertions
			-- there are all satisfied by a Scribe that simply refuses every flush.
			-- Without a case where the flush SUCCEEDS and the data is then found on
			-- disk, "never acknowledges a write that did not land" is trivially met by
			-- never acknowledging anything.
			local uni = newUniverse({ Servers = 1, Seed = 31337 })
			local model = Model.new()
			local workload = Workload.new({ Universe = uni, Model = model, Seed = 31337 })

			local userId = workload:Join(FakePlayer)
			uni:Run(30)
			local token = workload:Mutate(userId)
			expect(token).never.to.equal(nil)

			workload:FlushNow(userId) -- no faults armed: this one must land
			uni:Run(120)
			expect(workload.Stats.FlushOk).to.equal(1)
			expect(workload.Stats.FlushRefused).to.equal(0)
			expect(#model:Expected(userId)).to.equal(1)

			workload:Crash(1)
			uni:Quiesce()

			local record = uni.Disk.Keyspace:Read("Default", `PLAYER_{userId}`)
			local log = record and record.Value and record.Value.Data and record.Value.Data.Log
			-- Acknowledged, so the crash is no excuse: it must be there.
			expect(#model:Verify(userId, log)).to.equal(0)
			expect(#Model.Parse(log)).to.equal(1)
			expect(Model.Parse(log)[1]).to.equal(token)
		end)

		it("un-acknowledges what a crash took, so it is not reported as loss", function()
			-- The distinction the whole crash story rests on. A write confirmed
			-- durable and then absent is a LOST UPDATE and must fail the run; a write
			-- that a crash took before it was ever confirmed is expected and must
			-- not. Failing on the second would make every crash scenario red and
			-- train everyone to ignore the checker.
			--
			-- Tested directly, because the workload today only acknowledges on a
			-- clean leave -- so a crashed player's tokens were never acked and the
			-- un-acking never runs in a soak. That will change the moment autosaves
			-- start acknowledging, and this is the guard for when it does.
			local model = Model.new()
			model:Stage(1, "job#1")
			model:Stage(1, "job#2")
			model:Ack(1, "job#1")
			model:Ack(1, "job#2")

			-- The crash claims the second one back.
			model:NoteCrashLoss(1, { "job#2" })

			local found = model:Verify(1, "job#1")
			expect(#found).to.equal(0)
			expect(#model.CrashLoss).to.equal(1)
			expect(model.CrashLoss[1].Token).to.equal("job#2")

			-- ...while a write that was NOT claimed by the crash is still held to.
			local strict = Model.new()
			strict:Stage(2, "job#9")
			strict:Ack(2, "job#9")
			expect(#strict:Verify(2, "")).to.equal(1)
		end)
		it("catches a double-applied write", function()
			-- Proof the checker has teeth. Without this, "zero violations" could
			-- just mean the model never looks.
			local model = Model.new()
			model:Stage(1, "job#1")
			model:Ack(1, "job#1")
			local found = model:Verify(1, "job#1;job#1")

			expect(#found).to.equal(1)
			expect(found[1].Kind).to.equal("DuplicateWrite")
		end)

		it("catches a lost write", function()
			local model = Model.new()
			model:Stage(1, "job#1")
			model:Stage(1, "job#2")
			model:Ack(1, "job#1")
			model:Ack(1, "job#2")
			local found = model:Verify(1, "job#1")

			expect(#found).to.equal(1)
			expect(found[1].Kind).to.equal("LostUpdate")
			expect(found[1].Token).to.equal("job#2")
		end)

		it("catches a value nobody wrote", function()
			local model = Model.new()
			model:Stage(1, "job#1")
			model:Ack(1, "job#1")
			local found = model:Verify(1, "job#1;ghost#99")

			expect(#found).to.equal(1)
			expect(found[1].Kind).to.equal("GarbageRead")
		end)
	end)

	describe("sensitivity to the numbers Roblox does not document", function()
		it("keeps the safety claim across every latency profile", function()
			-- The rule: a headline result must survive every plausible setting of a
			-- constant it could depend on. Latency sets the width of every conflict
			-- window, so it is the one most likely to move a contention finding --
			-- and if the no-lost-writes claim held only at one profile, it would be
			-- a property of test/Sim/Disk/Latency.luau rather than of Scribe.
			for _, profile in Uncertain.SWEEPS.LatencyProfile do
				local result = soak({
					Steps = if SOAK then 120 else 30,
					Universe = { LatencyProfile = profile, Seed = 2024 },
				})
				expect(#result.Violations).to.equal(0)
				expect(result.Settled).to.equal(true)
				expect(`held={result.HeldSessions}`).to.equal("held=0")
				Guard.Reset()
				universe = nil
			end
		end)

		it("keeps the safety claim under both budget accrual models", function()
			-- Roblox states the limits per minute and never says how they accrue.
			-- Trickle is smooth; Bucket grants a whole minute at once and is far
			-- harsher just after a rollover. Both ship, and the claim has to hold
			-- under each.
			for _, mode in Uncertain.SWEEPS.BudgetMode do
				local result = soak({
					Steps = if SOAK then 120 else 30,
					Universe = {
						NoBudget = false,
						BudgetMode = mode,
						LatencyProfile = "Fixed",
						Seed = 31337,
					},
				})
				expect(#result.Violations).to.equal(0)
				-- Liveness too. This was the one soak-shaped test in the file with no
				-- Settled assertion at all, so a run that stayed uncorrupted but
				-- livelocked under Bucket accrual passed it.
				expect(`{mode} settled={result.Settled}`).to.equal(`{mode} settled=true`)
				expect(`held={result.HeldSessions}`).to.equal("held=0")
				Guard.Reset()
				universe = nil
			end
		end)

		it("documents every invented number in one place", function()
			-- The register is not decoration. Any result quoted from this simulation
			-- has to be checkable against the assumptions behind it, and an entry
			-- without a location is an assumption nobody can find to correct.
			expect(#Uncertain.REGISTER > 0).to.equal(true)
			for _, entry in Uncertain.REGISTER do
				expect(type(entry.Id)).to.equal("string")
				expect(#entry.Documented > 0).to.equal(true)
				expect(#entry.Where > 0).to.equal(true)
				expect(#entry.Direction > 0).to.equal(true)
			end
			-- The two that most often get quoted as if they were measured.
			expect(Uncertain.Find("U1")).never.to.equal(nil)
			expect(Uncertain.Find("U9")).never.to.equal(nil)
		end)
	end)
end
