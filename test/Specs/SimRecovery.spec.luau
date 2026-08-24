--!nonstrict
-- The last two scenarios: whether leaderboards can saturate the scarcest budget
-- in the system, and whether a player stranded by an unsaveable profile can be
-- recovered by a different server.
--
-- The second follows directly from the oversize finding. A server that can never
-- complete its closing save never releases the session lock -- so the question
-- that actually decides how bad that is has to be asked separately: can anyone
-- else pick the player up?

return function()
	local Root = script.Parent.Parent.Parent
	local Universe = require(Root.Test.Sim.Universe)
	local Guard = require(Root.Test.Sim.Guard)
	-- Sim-backed: every node below needs a simulated universe, which only the headless
	-- runner can build. Under Studio they report SKIP instead of each failing with the
	-- same missing capability -- see test/Sim/Available for why it cannot be provided.
	local it = if require(Root.Test.Sim.Available).Ready then it else itSKIP
	local Budget = require(Root.Test.Sim.Disk.Budget)
	local Scribe = require(Root.Scribe)
	local StubTransport = require(Root.Test.Helpers.StubTransport)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

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
			LatencyProfile = "Nominal",
			NoBudget = false,
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
		}
		for key, value in overrides or {} do
			config[key] = value
		end
		universe = Universe.new(config)
		Guard.Install(universe)
		return universe
	end

	local function line(...)
		print("      " .. string.format(...))
	end

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	describe("leaderboards against the scarcest budget", function()
		it("cannot saturate ordered writes, because the pacer bounds them first", function()
			-- Ordered writes accrue at 30 + n*5 per minute, eight times tighter per
			-- player than standard writes -- so on paper leaderboards are where a
			-- busy game runs out of budget first. In practice a second limit binds
			-- earlier: Scribe drains its board queue on a fixed interval and
			-- deduplicates by player, so the write rate is capped by the CLOCK rather
			-- than by how many players are changing their score.
			local uni = build({
				Servers = 2,
				Template = { Coins = Scribe.Int(0, { Min = 0 }) },
				Options = {
					Leaderboards = {
						Coins = { Stat = "Coins", Limit = 100, RefreshInterval = 60 },
					},
				},
			})

			local players = {}
			for s = 1, 2 do
				for i = 1, 50 do
					local userId = 70000 + s * 100 + i
					local player = FakePlayer.new(userId)
					uni:Server(s):Join(userId, player)
					table.insert(players, { Server = s, Player = player, UserId = userId })
				end
			end
			uni:Run(60)

			-- Every player changes score repeatedly: the worst case for a board.
			local before = uni.Disk.Stats.Writes
			local startedAt = uni.Sched.Now
			for round = 1, 40 do
				for _, record in players do
					local ok, data = pcall(function()
						return uni:Server(record.Server).Bundle.Data.Get(record.Player)
					end)
					if ok and data then
						data.Coins.Set(round * 10 + (record.UserId % 7))
					end
				end
				uni:Run(3)
			end
			local minutes = (uni.Sched.Now - startedAt) / 60

			local board = uni.Disk:GetOrderedDataStore(uni:Server(1).Bundle.Ctx.Leaderboards.BoardStoreName("Coins"))
			local entries = 0
			for _ in board._entries do
				entries += 1
			end

			local perServerBudget = Budget.SERVER_LIMITS.OrderedWrite(50)
			line("--- LEADERBOARD SATURATION: 100 players, 4,000 score changes ---")
			line("score changes issued : %d", 40 * #players)
			line("ordered budget/min   : %d per server (50 players)", perServerBudget)
			line("board entries written: %d over %.1f virtual minutes", entries, minutes)
			line("budget stalls        : %d", uni.Disk.Budget.Stats.Stalls)
			line("budget drops         : %d", uni.Disk.Budget.Stats.Dropped)
			line("total disk writes    : %d", uni.Disk.Stats.Writes - before)

			-- Four thousand score changes, and the board never ran out of budget.
			expect(uni.Disk.Budget.Stats.Dropped).to.equal(0)
			-- ...and the board still reflects the players, so the pacing is
			-- deduplication rather than loss.
			expect(entries > 0).to.equal(true)
		end)

		it("keeps the newest score when it collapses a burst of changes", function()
			-- Deduplication is only safe if the survivor is the LATEST value. Keeping
			-- an older one would make a board that lags reality permanently rather
			-- than briefly.
			local uni = build({
				Template = { Coins = Scribe.Int(0, { Min = 0 }) },
				Options = {
					Leaderboards = {
						Coins = { Stat = "Coins", Limit = 100, RefreshInterval = 60 },
					},
				},
			})
			local server = uni:Server(1)
			local player = FakePlayer.new(71001)
			server:Join(71001, player)
			uni:Run(60)

			-- Twenty changes inside a single pacer interval.
			for i = 1, 20 do
				server.Bundle.Data.Get(player).Coins.Set(i * 5)
			end
			uni:Run(60)

			local board = uni.Disk:GetOrderedDataStore(server.Bundle.Ctx.Leaderboards.BoardStoreName("Coins"))
			line("--- DEDUP: 20 changes in one interval -> stored %s ---", tostring(board._entries["71001"]))
			expect(board._entries["71001"]).to.equal(100)
		end)
	end)

	describe("recovering a player stranded by an unsaveable profile", function()
		it("lets a second server take over once the lock goes stale", function()
			-- The open question from the oversize finding. Server A holds a profile it
			-- can never save, so it never releases the session. Nothing about that is
			-- cooperative -- the only route back is the dead-session path, which needs
			-- the lock's timestamp to stop moving.
			local uni = build({
				Servers = 2,
				Template = {
					Coins = Scribe.Int(0, { Min = 0 }),
					Blob = Scribe.String("", { MaxLength = 2000000 }),
				},
				ValueBytes = 32 * 1024,
				-- Shortened so a bounded run reaches recovery; production is 630s.
				Constants = {
					AUTO_SAVE_PERIOD = 30,
					SESSION_STEAL = 20,
					FIRST_LOAD_REPEAT = 2,
					LOAD_REPEAT_PERIOD = 5,
					ASSUME_DEAD = 90,
					START_SESSION_TIMEOUT = 300,
				},
			})
			local a, b = uni:Server(1), uni:Server(2)
			local player = FakePlayer.new(72001)

			a:Join(72001, player)
			uni:Run(60)

			-- A good save first, so there is something to recover TO.
			a.Bundle.Data.Get(player).Coins.Set(8888)
			uni.Sched:Spawn(function()
				pcall(function()
					return a.Bundle.Data.Flush(player, { Timeout = 30 })
				end)
			end)
			uni:Run(60)
			expect(uni.Disk.Keyspace:Read("Default", "PLAYER_72001").Value.Data.Coins).to.equal(8888)

			-- Now make the profile unsaveable and leave.
			a.Bundle.Data.Get(player).Blob.Set(string.rep("q", 64 * 1024))
			a:Leave(72001)
			uni:Run(120)

			local stranded = uni.Disk.Keyspace:Read("Default", "PLAYER_72001").Value.MetaData.ActiveSession
			line("--- RECOVERY: lock after A gives up = %s ---", if stranded then tostring(stranded[2]) else "released")

			-- The player reconnects on a different server.
			local recovered = FakePlayer.new(72001)
			b:Join(72001, recovered)
			uni:Run(600)

			local ok, data = pcall(function()
				return b.Bundle.Data.Get(recovered)
			end)
			local record = uni.Disk.Keyspace:Read("Default", "PLAYER_72001")
			local holder = record.Value.MetaData.ActiveSession

			line(
				"      loaded on B = %s, coins = %s, lock now = %s",
				tostring(ok),
				if ok and data then tostring(data.Coins.Get()) else "n/a",
				if holder then tostring(holder[2]) else "released"
			)

			-- The player is recoverable: B takes the session and sees the last good
			-- save. The unsaveable blob is gone, which is correct -- it never
			-- persisted and never could have.
			expect(ok).to.equal(true)
			expect(data).never.to.equal(nil)
			expect(data.Coins.Get()).to.equal(8888)
			expect(data.Blob.Get()).to.equal("")
			expect(holder).never.to.equal(nil)
			expect(holder[2]).to.equal(b.JobId)
		end)
	end)
end
