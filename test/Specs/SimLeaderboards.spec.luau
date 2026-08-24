--!nonstrict
-- Leaderboards against the modelled OrderedDataStore.
--
-- The only place Scribe touches DataStoreService directly, and the only traffic a
-- Mode = "NoSave" run would silently omit -- profiles stay real under NoSave while
-- leaderboards mock out, so a capacity study run that way would report a
-- suspiciously comfortable write budget.
--
-- Ordered writes are also the scarcest resource in the whole system: 30 + n*5 per
-- minute against 60 + n*40 for standard writes, eight times tighter per player.

return function()
	local Root = script.Parent.Parent.Parent
	local Universe = require(Root.Test.Sim.Universe)
	local Guard = require(Root.Test.Sim.Guard)
	-- Sim-backed: every node below needs a simulated universe, which only the headless
	-- runner can build. Under Studio they report SKIP instead of each failing with the
	-- same missing capability -- see test/Sim/Available for why it cannot be provided.
	local it = if require(Root.Test.Sim.Available).Ready then it else itSKIP
	local Budget = require(Root.Test.Sim.Disk.Budget)
	local Disk = require(Root.Test.Sim.Disk)
	local Scheduler = require(Root.Test.Sim.Scheduler)
	local Rng = require(Root.Test.Sim.Rng)
	local StubTransport = require(Root.Test.Helpers.StubTransport)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	local universe

	local function newUniverse(overrides)
		local config = {
			Seed = 4171,
			Servers = 1,
			Constants = { AUTO_SAVE_PERIOD = 20, SESSION_STEAL = 10, FIRST_LOAD_REPEAT = 2, ASSUME_DEAD = 60 },
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Instant",
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
			Template = {},
			Options = {},
		}
		for key, value in overrides or {} do
			config[key] = value
		end
		universe = Universe.new(config)
		Guard.Install(universe)
		return universe
	end

	local function newOrdered(overrides)
		local sched = Scheduler.new(1)
		local config = {
			Sched = sched,
			Rng = Rng.Stream(1, "disk.latency"),
			VersionRng = Rng.Stream(1, "disk.versionid"),
			FaultRng = Rng.Stream(1, "disk.fault"),
			LatencyProfile = "Instant",
			NoBudget = true,
		}
		for key, value in overrides or {} do
			config[key] = value
		end
		local disk = Disk.new(config)
		return disk, sched, disk:GetOrderedDataStore("LB_Coins")
	end

	local function request(sched, fn)
		local result, failure
		sched:Spawn(function()
			local ok, value = pcall(fn)
			if ok then
				result = value
			else
				failure = value
			end
		end)
		sched:Run()
		return result, failure
	end

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	describe("the ordered store", function()
		it("sorts descending and honours the page size", function()
			local _, sched, board = newOrdered()
			for i = 1, 12 do
				request(sched, function()
					return board:SetAsync(`player_{i}`, i * 100)
				end)
			end

			local page = request(sched, function()
				return board:GetSortedAsync(false, 5)
			end)
			local rows = page.GetCurrentPage()

			expect(#rows).to.equal(5)
			expect(rows[1].value).to.equal(1200)
			expect(rows[5].value).to.equal(800)
		end)

		it("breaks ties on key, so a replay cannot reorder equals", function()
			-- table.sort is not stable. Without a total order two players on the
			-- same score would swap between runs and break the digest for a reason
			-- nobody could see in the data.
			local _, sched, board = newOrdered()
			for _, name in { "charlie", "alice", "bob" } do
				request(sched, function()
					return board:SetAsync(name, 500)
				end)
			end

			local rows = request(sched, function()
				return board:GetSortedAsync(false, 10)
			end).GetCurrentPage()
			expect(rows[1].key).to.equal("alice")
			expect(rows[2].key).to.equal("bob")
			expect(rows[3].key).to.equal("charlie")
		end)

		it("refuses a non-integer value, permanently", function()
			-- Rejected identically on every attempt, which is what makes a caller
			-- that re-enqueues on failure retry forever. Scribe clamps before
			-- writing precisely to avoid that.
			local _, sched, board = newOrdered()

			local _, floatErr = request(sched, function()
				return board:SetAsync("p", 1.5)
			end)
			local _, nanErr = request(sched, function()
				return board:SetAsync("p", 0 / 0)
			end)

			expect(Disk.Errors.Classify(tostring(floatErr)).Code).to.equal(103)
			expect(Disk.Errors.Classify(tostring(floatErr)).Retryable).to.equal(false)
			expect(Disk.Errors.Classify(tostring(nanErr)).Code).to.equal(103)
		end)

		it("rejects a page size outside 1..100", function()
			local _, sched, board = newOrdered()
			local _, tooBig = request(sched, function()
				return board:GetSortedAsync(false, 101)
			end)
			expect(Disk.Errors.Classify(tostring(tooBig)).Code).to.equal(106)
		end)

		it("returns no KeyInfo, because ordered stores have none", function()
			-- nil rather than an empty stand-in. A caller that treated a non-nil
			-- KeyInfo as "this key exists" would be wrong in the same way
			-- ProfileStore's new-profile detection would be.
			local _, sched, board = newOrdered()
			local info = request(sched, function()
				return board:SetAsync("p", 10)
			end)
			expect(info).to.equal(nil)
		end)
	end)

	describe("ordered budget", function()
		it("is eight times scarcer per player than standard writes", function()
			-- The tightest real constraint at high CCU, and the reason a leaderboard
			-- that writes per score change saturates long before anything else in
			-- the system shows pressure.
			local orderedSlope = Budget.SERVER_LIMITS.OrderedWrite(200) - Budget.SERVER_LIMITS.OrderedWrite(100)
			local standardSlope = Budget.SERVER_LIMITS.StandardWrite(200) - Budget.SERVER_LIMITS.StandardWrite(100)
			expect(standardSlope / orderedSlope).to.equal(8)
		end)

		it("saturates ordered writes while standard writes still have room", function()
			local disk, sched, board = newOrdered({
				NoBudget = false,
				PlayerCount = function()
					return 10
				end,
				CCU = function()
					return 10
				end,
			})

			-- OrderedWrite at 10 players is 30 + 50 = 80/min; StandardWrite is
			-- 60 + 400 = 460/min. Well inside the standard pool, well past ordered.
			for i = 1, 120 do
				sched:Spawn(function()
					pcall(function()
						board:SetAsync(`p{i}`, i)
					end)
				end)
			end
			sched:Run()

			expect(disk.Budget.Stats.Stalls > 0).to.equal(true)
			local standardPool = disk.Budget._servers["sim-server"]
			expect(standardPool.Tokens.StandardWrite).to.equal(nil) -- never touched
		end)
	end)

	describe("Scribe's leaderboards over the modelled store", function()
		it("writes real board entries in Mode = Live", function()
			-- Mode matters: Live is the only setting where Leaderboards reaches
			-- DataStoreService at all. Under Mock or NoSave this traffic vanishes.
			local Scribe = require(Root.Scribe)
			local uni = newUniverse({
				Template = { Coins = Scribe.Int(0, { Min = 0 }) },
				Options = {
					Leaderboards = {
						Coins = { Stat = "Coins", Limit = 10, RefreshInterval = 60 },
					},
				},
			})
			local server = uni:Server(1)

			local player = FakePlayer.new(801)
			server:Join(801, player)
			uni:Run(30)
			server.Bundle.Data.Get(player).Coins.Set(4242)
			server:Leave(801)
			uni:Run(120)

			local boardName = server.Bundle.Ctx.Leaderboards.BoardStoreName("Coins")
			local board = uni.Disk:GetOrderedDataStore(boardName)
			expect(board._entries["801"]).never.to.equal(nil)
		end)

		it("does not let a throttled board flip the bundle to Outage", function()
			-- Leaderboards deliberately abstains from reporting board read and write
			-- failures to Health, so leaderboard throttling cannot block Robux
			-- receipts. That abstention is load-bearing and the simulation must not
			-- "fix" it -- a study that made boards report failures would find an
			-- outage production does not have.
			--
			-- The faults are scoped to the BOARD STORE, which is the whole point.
			-- An earlier version of this spec set a global fault rate, which failed
			-- profile saves too -- and those legitimately do report to Health. It
			-- duly went to Outage and looked like a finding; it was a badly aimed
			-- test.
			local Scribe = require(Root.Scribe)
			local uni = newUniverse({
				Template = { Coins = Scribe.Int(0, { Min = 0 }) },
				Options = {
					Leaderboards = {
						Coins = { Stat = "Coins", Limit = 10, RefreshInterval = 20 },
					},
				},
				-- Tight enough that a handful of board failures would trip it.
				StatusThresholds = { FailWindow = 60, FailCount = 2, RecoverStreak = 5 },
			})
			local server = uni:Server(1)
			local boardName = server.Bundle.Ctx.Leaderboards.BoardStoreName("Coins")

			-- Every board write and read fails, for a long time. Profile traffic is
			-- untouched.
			uni.Disk:Arm({ Kind = "ServiceError", Store = boardName, Count = 500 })

			local player = FakePlayer.new(802)
			server:Join(802, player)
			uni:Run(30)
			server.Bundle.Data.Get(player).Coins.Set(999)
			server:Leave(802)
			uni:Run(180)

			-- Boards were failing throughout; the bundle stayed healthy, so receipts
			-- and gifts would still be accepted.
			expect(server.Bundle.Health.GetStatus()).to.equal("Healthy")
			-- ...and the profile itself still persisted.
			expect(uni.Disk.Keyspace:Read("Default", "PLAYER_802").Value.Data.Coins).to.equal(999)
		end)
	end)
end
