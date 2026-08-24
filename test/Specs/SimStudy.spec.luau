--!nonstrict
-- The study: measured answers to "does Scribe hold up at high CCU".
--
-- Gated behind SCRIBE_STUDY=1 -- this is an instrument, not a regression test.
-- Every number printed here comes from a run that actually happened; nothing is
-- extrapolated. Read test/Sim/Uncertain.luau before quoting any of it, because
-- several inputs are invented and named there.

return function()
	local Root = script.Parent.Parent.Parent
	local Universe = require(Root.Test.Sim.Universe)
	local Guard = require(Root.Test.Sim.Guard)
	local Model = require(Root.Test.Sim.Model)
	local Workload = require(Root.Test.Sim.Workload)
	local Budget = require(Root.Test.Sim.Disk.Budget)
	local Scribe = require(Root.Scribe)
	local StubTransport = require(Root.Test.Helpers.StubTransport)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	local STUDY = __SimHost ~= nil and __SimHost.Env ~= nil and __SimHost.Env.SCRIBE_STUDY == "1"

	local TEMPLATE = {
		Log = Scribe.String("", { MaxLength = 1024 }),
		Coins = Scribe.Int(0, { Min = 0 }),
	}

	-- PRODUCTION values. The point of the study is what happens to a real game, so
	-- the shortened constants the other specs use would answer a different question.
	local PRODUCTION = {
		AUTO_SAVE_PERIOD = 300,
		SESSION_STEAL = 40,
		FIRST_LOAD_REPEAT = 5,
		LOAD_REPEAT_PERIOD = 10,
		ASSUME_DEAD = 630,
		START_SESSION_TIMEOUT = 120,
	}

	local universe

	local function build(servers, overrides)
		local config = {
			Seed = 20260817,
			Servers = servers,
			Constants = PRODUCTION,
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Nominal",
			Template = TEMPLATE,
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
			NoBudget = false,
		}
		for key, value in overrides or {} do
			config[key] = value
		end
		universe = Universe.new(config)
		Guard.Install(universe)
		return universe
	end

	-- Rows printed by the case currently running, reset per case by `study` below.
	--
	-- It exists because six of these seven cases closed with an assertion that could
	-- not fail, so a sweep that built no universe, or exited after its header,
	-- printed a table with nothing in it and passed. Asserting the row count does not
	-- invent a claim about the RESULTS -- this is an instrument, and its numbers are
	-- the output rather than the assertion -- it asserts that the instrument ran.
	local rows = 0
	local function line(...)
		rows += 1
		print("      " .. string.format(...))
	end

	--- One study case: SKIPPED, not silently returned, when the gate is off.
	---
	--- The seven bodies used to open with an early return, so the ordinary suite
	--- reported seven PASSES for seven bodies that had not executed -- 411 lines
	--- counted as coverage that could not fail. itSKIP reports the same fact
	--- honestly, and the suite total drops by exactly seven with nothing deleted.
	local function study(name: string, body: () -> ())
		local runner = if STUDY then it else itSKIP
		runner(name, function()
			rows = 0
			body()
		end)
	end

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	describe("STUDY", function()
		study("1. steady-state write cost per player", function()
			line("--- 1. STEADY STATE: what a resident player costs, per server ---")
			line(
				"%-8s %-8s %-9s %-9s %-9s %-9s %-9s %-9s",
				"servers",
				"players",
				"writes",
				"reads",
				"stalls",
				"drops",
				"loaded",
				"all-in s"
			)

			for _, shape in { { 2, 50 }, { 10, 50 }, { 20, 50 }, { 40, 50 } } do
				local servers, per = shape[1], shape[2]
				local uni = build(servers)
				local uid = 0
				for s = 1, servers do
					for _ = 1, per do
						uid += 1
						uni:Server(s):Join(uid, FakePlayer.new(uid))
					end
				end
				-- Time to a fully-loaded population. Everyone joins at t=0, which is the
				-- thundering herd: a mass rejoin after an outage or a restart. The
				-- interesting operational number is not whether it recovers but how
				-- long players spend waiting while it does.
				local target = servers * per
				local startedAt = uni.Sched.Now
				local settledAt = nil
				while uni.Sched.Now - startedAt < 600 do
					uni:Run(5)
					if settledAt == nil then
						local live = 0
						for _, entry in uni.Disk.Keyspace:Each() do
							if entry.Record.Value ~= nil and entry.Record.Value.MetaData ~= nil then
								live += 1
							end
						end
						if live >= target then
							settledAt = uni.Sched.Now - startedAt
						end
					end
				end

				-- The number that decides whether the drops MATTER. A throttle drop is
				-- transient and ProfileStore retries; the question is whether every
				-- player ended up with a live session anyway.
				local loaded = 0
				for _, entry in uni.Disk.Keyspace:Each() do
					if entry.Record.Value ~= nil and entry.Record.Value.MetaData ~= nil then
						loaded += 1
					end
				end

				line(
					"%-8d %-8d %-9d %-9d %-9d %-9d %-9d %-9.0f",
					servers,
					servers * per,
					uni.Disk.Stats.Writes,
					uni.Disk.Stats.Reads,
					uni.Disk.Budget.Stats.Stalls,
					uni.Disk.Budget.Stats.Dropped,
					loaded,
					settledAt or -1
				)
				Guard.Reset()
				universe = nil
			end
			expect(`rows={rows}`).to.equal("rows=6")
		end)

		study("2. which budget ceiling binds first", function()
			line("--- 2. BUDGET CEILINGS: per-server vs per-experience, writes/min ---")
			line("%-8s %-14s %-16s %-12s", "CCU", "per-server*N", "per-experience", "binds")
			for _, ccu in { 100, 500, 1000, 2000, 5000, 10000 } do
				local servers = math.ceil(ccu / 50)
				local perServer = Budget.SERVER_LIMITS.StandardWrite(50) * servers
				local experience = Budget.EXPERIENCE_LIMITS.Write(ccu)
				line(
					"%-8d %-14d %-16d %-12s",
					ccu,
					perServer,
					experience,
					if experience < perServer then "EXPERIENCE" else "per-server"
				)
			end
			expect(`rows={rows}`).to.equal("rows=8")
		end)

		study("3. churn: joins and leaves, not autosaves, drive write load", function()
			line("--- 3. CHURN: write load under player turnover ---")
			line("%-10s %-9s %-9s %-9s %-9s %-9s", "steps", "joins", "leaves", "writes", "stalls", "drops")

			for _, steps in { 100, 300, 600 } do
				local uni = build(10)
				local model = Model.new()
				local workload = Workload.new({
					Universe = uni,
					Model = model,
					Seed = 20260817,
					MaxPlayers = 200,
					Weights = { Join = 0.45, Mutate = 0.20, Leave = 0.30, Hop = 0.05 },
				})
				for _ = 1, steps do
					workload:Step(FakePlayer)
					uni:Run(2)
				end
				line(
					"%-10d %-9d %-9d %-9d %-9d %-9d",
					steps,
					workload.Stats.Joins,
					workload.Stats.Leaves,
					uni.Disk.Stats.Writes,
					uni.Disk.Budget.Stats.Stalls,
					uni.Disk.Budget.Stats.Dropped
				)
				Guard.Reset()
				universe = nil
			end
			expect(`rows={rows}`).to.equal("rows=5")
		end)

		study("4. contention: cost of a hop at production timings", function()
			line("--- 4. CONTENTION: server hops at production SESSION_STEAL = 40s ---")
			line("%-10s %-12s %-12s %-12s %-12s", "hops", "steals", "conflicts", "elapsed s", "violations")

			for _, hopCount in { 5, 20, 50 } do
				local uni = build(4)
				local model = Model.new()
				local workload = Workload.new({
					Universe = uni,
					Model = model,
					Seed = 20260817,
					MaxPlayers = 60,
					Weights = { Join = 0.30, Mutate = 0.25, Leave = 0.05, Hop = 0.40 },
				})

				local startedAt = uni.Sched.Now
				local steps = 0
				while workload.Stats.Hops < hopCount and steps < 4000 do
					workload:Step(FakePlayer)
					uni:Run(3)
					steps += 1
				end
				for userId in table.clone(workload:Players()) do
					workload:Leave(userId)
				end
				uni.Disk:Heal()
				uni:Run(300)
				uni:Quiesce()
				uni:Settle(600)

				local violations = 0
				for userId in model._players do
					local record = uni.Disk.Keyspace:Read("Default", `PLAYER_{userId}`)
					local log = record and record.Value and record.Value.Data and record.Value.Data.Log
					violations += #model:Verify(userId, log)
				end

				-- Steals, not CAS conflicts. Two servers rarely write the SAME key at
				-- the same instant, so conflicts stay near zero even when every hop
				-- succeeds -- SessionLoadCount is what actually records an ownership
				-- change, and it is what the protocol itself keys off.
				local steals = 0
				for _, entry in uni.Disk.Keyspace:Each() do
					local meta = entry.Record.Value and entry.Record.Value.MetaData
					if meta and meta.SessionLoadCount then
						steals += math.max(0, meta.SessionLoadCount - 1)
					end
				end

				line(
					"%-10d %-12d %-12d %-12.0f %-12d",
					workload.Stats.Hops,
					steals,
					uni.Disk.Stats.Conflicts,
					uni.Sched.Now - startedAt,
					violations
				)
				Guard.Reset()
				universe = nil
			end
			expect(`rows={rows}`).to.equal("rows=5")
		end)

		study("5. consistency under injected failure", function()
			line("--- 5. FAULTS: consistency as the failure rate rises ---")
			line("%-10s %-10s %-12s %-12s %-10s", "rate", "injected", "indeterm.", "violations", "settled")

			local totalViolations = 0
			for _, rate in { 0.0, 0.01, 0.05, 0.15 } do
				local uni = build(4)
				local model = Model.new()
				local workload = Workload.new({
					Universe = uni,
					Model = model,
					Seed = 20260817,
					MaxPlayers = 40,
				})
				if rate > 0 then
					uni.Disk:SetFaultRate({ ServiceError = rate, Indeterminate = rate / 4 })
				end

				for _ = 1, 200 do
					workload:Step(FakePlayer)
					uni:Run(3)
				end
				for userId in table.clone(workload:Players()) do
					workload:Leave(userId)
				end

				uni.Disk:Heal()
				uni:Run(300)
				uni:Quiesce()
				local settled = uni:Settle(900)

				local violations = 0
				local kinds = {}
				for userId in model._players do
					local record = uni.Disk.Keyspace:Read("Default", `PLAYER_{userId}`)
					local log = record and record.Value and record.Value.Data and record.Value.Data.Log
					for _, v in model:Verify(userId, log) do
						violations += 1
						kinds[v.Kind] = (kinds[v.Kind] or 0) + 1
					end
				end
				if violations > 0 then
					local parts = {}
					for kind, count in kinds do
						table.insert(parts, `{kind}={count}`)
					end
					line("      violation kinds: %s", table.concat(parts, ", "))
				end

				line(
					"%-10.2f %-10d %-12d %-12d %-10s",
					rate,
					uni.Disk.Faults.Stats.Injected,
					uni.Disk.Faults.Stats.IndeterminateCommits,
					violations,
					tostring(settled)
				)
				-- Accumulated and asserted after the sweep, not just printed. This used to
				-- claim to be the ONE place in the suite combining injected faults with the
				-- reference model. It is not, and has not been since SimSoak.spec.luau:199
				-- ("recovers, and stays consistent, after a burst of injected faults"), which
				-- does exactly that, asserts zero violations, and runs in the DEFAULT arm --
				-- SCRIBE_SOAK only scales its step count, it does not gate it. Over-valuing
				-- this case on a uniqueness it does not have is how a study gets mistaken
				-- for a safety net.
				--
				-- What is genuinely only here: the rate SWEEP, at production constants, over
				-- a MIX of two fault kinds. Note the mix is also why this stays a study and
				-- not a soak -- SimSoak:206 records that Faults.Next iterates `_rates` in
				-- pairs order, so with two kinds set WHICH one fires depends on table layout
				-- rather than on the seed. That is acceptable for measuring a trend across
				-- rates; it is not a reproducible fault schedule, and nothing here should be
				-- read as one.
				--
				-- It used to close with `expect(true).to.equal(true)`
				-- -- so it reported the violation count it had just computed and could
				-- not fail on it. Measured: 333 fabricated LostUpdates, still green.
				--
				-- After the sweep rather than per rate, so the whole table prints before
				-- anything fails and the operator can see WHICH rate broke it.
				totalViolations += violations
				Guard.Reset()
				universe = nil
			end
			expect(totalViolations).to.equal(0)
			expect(`rows={rows}`).to.equal("rows=6")
		end)

		study("6. sensitivity: does the answer move with the invented numbers", function()
			line("--- 6. SENSITIVITY: same workload, different assumptions ---")
			line("%-12s %-10s %-10s %-10s %-10s", "latency", "budget", "conflicts", "stalls", "violations")

			for _, profile in { "Fixed", "Nominal", "Slow" } do
				for _, mode in { "Trickle", "Bucket" } do
					local uni = build(4, { LatencyProfile = profile, BudgetMode = mode })
					local model = Model.new()
					local workload = Workload.new({
						Universe = uni,
						Model = model,
						Seed = 20260817,
						MaxPlayers = 40,
						Weights = { Join = 0.30, Mutate = 0.25, Leave = 0.15, Hop = 0.30 },
					})
					for _ = 1, 150 do
						workload:Step(FakePlayer)
						uni:Run(3)
					end
					for userId in table.clone(workload:Players()) do
						workload:Leave(userId)
					end
					uni.Disk:Heal()
					uni:Run(300)
					uni:Quiesce()
					uni:Settle(600)

					local violations = 0
					for userId in model._players do
						local record = uni.Disk.Keyspace:Read("Default", `PLAYER_{userId}`)
						local log = record and record.Value and record.Value.Data and record.Value.Data.Log
						violations += #model:Verify(userId, log)
					end

					line(
						"%-12s %-10s %-10d %-10d %-10d",
						profile,
						mode,
						uni.Disk.Stats.Conflicts,
						uni.Disk.Budget.Stats.Stalls,
						violations
					)
					Guard.Reset()
					universe = nil
				end
			end
			expect(`rows={rows}`).to.equal("rows=8")
		end)

		study("7. unbudgeted paths", function()
			line("--- 7. BUDGET AWARENESS: who ever asks how much budget is left ---")
			local uni = build(2)
			local before = uni.Disk.Stats.Reads
			for i = 1, 20 do
				uni:Server(1):Join(900 + i, FakePlayer.new(900 + i))
			end
			uni:Run(300)
			line("GetRequestBudgetForRequestType calls observed: %d", uni.Disk.BudgetQueries or 0)
			line("(reads issued in the same window: %d)", uni.Disk.Stats.Reads - before)
			expect(`rows={rows}`).to.equal("rows=3")
		end)
	end)
end
