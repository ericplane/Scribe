--!nonstrict
-- The half of Flush's durability answer that only exists when a save takes time.
--
-- FlushDurability drives the same question against the non-sim harness, where the
-- store saves synchronously — so `SavesInFlight` is never above zero at the moment
-- a spec looks, and deleting that clause from the predicate leaves every one of
-- those tests green. Measured, as a mutation: it survived all 23.
--
-- That clause is the only one not implied by `Dirty`. Without it the predicate is
-- satisfied the instant a save STARTS, because the payload snapshot clears the
-- flag — so `Flush` would answer "already durable" for writes still on the wire,
-- which is the exact shape of the receipt-granted-on-an-unsaved-write defect the
-- fork was built to remove. It needs modelled latency to be reachable at all,
-- which is what this file is for.

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
	local deepEquals = require(Root.Test.Helpers.DeepEquals)

	local universe

	local function build(latency: string)
		universe = Universe.new({
			Seed = 20260819,
			Servers = 1,
			-- Short, so autosaves land inside the run and overlap the flushes.
			Constants = { AUTO_SAVE_PERIOD = 30, SESSION_STEAL = 40, FIRST_LOAD_REPEAT = 5, ASSUME_DEAD = 630 },
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = latency,
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 3, RecoverStreak = 5 },
			Template = { Coins = Scribe.Int(0, { Min = 0 }), Nick = Scribe.String("", { MaxLength = 16 }) },
			Options = {},
		})
		Guard.Install(universe)
		return universe, universe:Server(1)
	end

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	local function stored(uni, key: string)
		local record = uni.Disk.Keyspace:Read("Default", key)
		return record and record.Value and record.Value.Data
	end

	--- Write, flush concurrently, and every time a flush answers `true`, check the
	--- claim it just made against what is actually on the disk at that instant.
	local function run(latency: string, playerCount: number, rounds: number)
		local uni, server = build(latency)
		local Persistence = server.Bundle.Ctx.Persistence

		local players = {}
		for i = 1, playerCount do
			local p = FakePlayer.new(67000 + i)
			server:Join(67000 + i, p)
			table.insert(players, p)
		end
		uni:Run(5)

		local acked, lies, firstLie = 0, 0, nil
		for round = 1, rounds do
			for i, player in players do
				local data = server.Bundle.Data.Get(player)
				if data then
					data.Coins.Increment(1)
					if (round + i) % 3 == 0 then
						data.Nick.Set(`n{round}`)
					end
					-- Flushed from a scheduler thread so it can be in flight alongside
					-- the autosave the short period keeps firing.
					uni.Sched:Spawn(function()
						local entry = Persistence.EntryFor(player)
						local ok = false
						pcall(function()
							ok = server.Bundle.Data.Flush(player, { Timeout = 25 })
						end)
						if ok and entry then
							acked += 1
							local same, why = deepEquals(entry.LiveData, stored(uni, entry.Key))
							if not same then
								lies += 1
								firstLie = firstLie or why
							end
						end
					end)
				end
			end
			uni:Run(2)
		end
		uni:Run(60) -- let everything settle
		return acked, lies, firstLie
	end

	it("never reports data durable while its save is still on the wire", function()
		local acked, lies, why = run("Nominal", 6, 60)
		-- The run has to actually produce acknowledgements, or "no lies" is vacuous --
		-- this is the assertion that stops the spec passing for the wrong reason.
		expect(`acked={acked > 30}`).to.equal("acked=true")
		expect(`lies={lies}, {tostring(why)}`).to.equal("lies=0, nil")
	end)

	it("holds under the slow latency profile too", function()
		-- Long round trips widen the in-flight window, which is where the clause
		-- earns its place. Any finding here should reproduce across both profiles.
		local acked, lies, why = run("Slow", 4, 60)
		expect(`acked={acked > 20}`).to.equal("acked=true")
		expect(`lies={lies}, {tostring(why)}`).to.equal("lies=0, nil")
	end)

	it("waits for a save it did not start, rather than acking on the flag it cleared", function()
		-- The clause, entered deliberately instead of waited for.
		--
		-- The window is narrow and specific: a save is on the wire, its payload
		-- snapshot has ALREADY cleared Dirty, and a previous save left LastResult at
		-- "Ok" -- so every other part of the predicate says "durable" while the bytes
		-- are still in transit. A passive observer can run for a simulated hour and
		-- never sample it, which is why this drives the scheduler into the window and
		-- then asks the question.
		local uni, server = build("Slow")
		local Persistence = server.Bundle.Ctx.Persistence
		local player = FakePlayer.new(69001)
		server:Join(69001, player)
		uni:Run(10)

		local entry = Persistence.EntryFor(player)
		local data = server.Bundle.Data.Get(player)

		-- One completed save, so LastResult is "Ok" and the predicate's other clauses
		-- are satisfied from here on.
		data.Coins.Set(1)
		uni.Sched:Spawn(function()
			pcall(function()
				server.Bundle.Data.Flush(player, { Timeout = 30 })
			end)
		end)
		uni:Run(30)
		expect(entry.SaveInfo.LastResult).to.equal("Ok")

		-- Now a write, and a save that we stop time inside.
		data.Coins.Set(2)
		uni.Sched:Spawn(function()
			pcall(function()
				server.Bundle.Data.Flush(player, { Timeout = 30 })
			end)
		end)
		local entered = false
		for _ = 1, 400 do
			uni:Run(0.05)
			if (entry.SavesInFlight or 0) > 0 then
				entered = true
				break
			end
		end
		-- If this ever stops holding, the test below proves nothing and says so here
		-- rather than passing quietly.
		expect(`inFlight={entered}`).to.equal("inFlight=true")
		expect(entry.SaveInfo.Dirty).to.equal(false)
		-- ...and the bytes are demonstrably not there yet.
		local sameNow = deepEquals(entry.LiveData, stored(uni, entry.Key))
		expect(`onDiskYet={sameNow}`).to.equal("onDiskYet=false")

		-- A second flush, with NO write in between: everything except the in-flight
		-- clause says this profile is already durable.
		local ackedWithDataOnDisk = nil
		uni.Sched:Spawn(function()
			local ok = false
			pcall(function()
				ok = server.Bundle.Data.Flush(player, { Timeout = 30 })
			end)
			if ok then
				ackedWithDataOnDisk = deepEquals(entry.LiveData, stored(uni, entry.Key))
			end
		end)
		uni:Run(60)

		-- It answered true only once the data was genuinely stored.
		expect(`acked={ackedWithDataOnDisk}`).to.equal("acked=true")
	end)
end
