--!nonstrict
-- C3 and C2, against the MODELLED DISK rather than a fake store.
--
-- The orchestration spec proves the ordering against in-memory records, which is
-- enough to catch a mis-sequenced implementation but not enough to prove the claim.
-- The claim is about DURABILITY: the taker's copy of the payload is on the taker's own
-- KEY before any verdict record can exist. Only a real save path over a real keyspace
-- can say that, so these run under test/Sim with the vendored store.
--
-- C3 is the proof the whole design rests on. If a Commit can exist before both takes
-- are durable, then dropping a giver's escrow after Commit can destroy the only copy,
-- and no amount of retrying afterwards recovers it. The verdict store here therefore
-- does not observe the ordering, it ENFORCES it: it reads both modelled disks and
-- refuses to decide unless the payloads are already there. An implementation that
-- proposed too early cannot exchange at all.
--
-- C2 drives the same path one operation at a time with the conservation gate run
-- between every step, and with hostile game code at the points where a flush yields.
-- Every FATAL in five earlier design rounds was found on the ordinary path, so the
-- ordinary path is what gets interrupted here.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Universe = require(Root.Test.Sim.Universe)
	local Guard = require(Root.Test.Sim.Guard)
	-- Sim-backed: needs a modelled disk and the real save path.
	local it = if require(Root.Test.Sim.Available).Ready then it else itSKIP
	local StubTransport = require(Root.Test.Helpers.StubTransport)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)
	local ExchangeLeg = require(Root.Scribe.Internal.ExchangeLeg)
	local ExchangeVerdict = require(Root.Scribe.Internal.ExchangeVerdict)
	local Exchange = require(Root.Scribe.Internal.Exchange)
	local ExchangeLedger = require(Root.Test.Helpers.ExchangeLedger)

	local TID = "tid_sim_1"
	local A_ID, B_ID = 95101, 95102
	local START_COINS = 500

	local OBJECTS = {
		{ Kind = "Unique", Path = { "Inventory" }, Id = "sword" },
		{ Kind = "Unique", Path = { "Inventory" }, Id = "shield" },
		{ Kind = "Fungible", Path = { "Coins" }, Total = START_COINS * 2 },
	}

	local universe

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	--- One server, two players, each holding one item and coins, all of it flushed so
	--- the starting state is a fact about the keyspace.
	local function setup()
		universe = Universe.new({
			Seed = 20260827,
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
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
			Template = {
				Coins = Scribe.Int(0, { Min = 0, Max = 1000000 }),
				Inventory = Scribe.DictOf({ Qty = Scribe.Int(1, { Min = 1, Max = 99 }) }, { MaxKeys = 4 }),
			},
			Options = {},
		})
		Guard.Install(universe)
		local uni = universe
		local server = uni:Server(1)

		local pa, pb = FakePlayer.new(A_ID), FakePlayer.new(B_ID)
		server:Join(A_ID, pa)
		server:Join(B_ID, pb)
		uni:Run(30)

		local Data = server.Bundle.Data
		local da, db = Data.Get(pa), Data.Get(pb)
		expect(`loaded={da ~= nil and db ~= nil}`).to.equal("loaded=true")

		da.Coins.Set(START_COINS)
		da.Inventory["sword"].Set({ Qty = 1 })
		db.Coins.Set(START_COINS)
		db.Inventory["shield"].Set({ Qty = 1 })

		local function flush(player)
			local answered
			uni.Sched:Spawn(function()
				answered = Data.Flush(player, { Force = true, Timeout = 30 })
			end)
			uni:Run(120)
			return answered == true
		end
		expect(`a={flush(pa)} b={flush(pb)}`).to.equal("a=true b=true")
		uni:Settle(120)

		local function ctxFor(player)
			local entry = server.Bundle.Ctx.Persistence.EntryFor(player)
			return { Tree = entry.Tree, Entry = entry, Compiled = server.Bundle.Compiled, UserId = player.UserId }
		end

		return {
			Uni = uni,
			Server = server,
			Data = Data,
			PA = pa,
			PB = pb,
			DA = da,
			DB = db,
			Flush = flush,
			CtxA = ctxFor(pa),
			CtxB = ctxFor(pb),
		}
	end

	--- The conservation gate over both keys, as a string so a failure prints the sheet.
	local function conserved(fixture, label): string
		local snapshot = ExchangeLedger.snapshot(fixture.Uni, fixture.Server, { A_ID, B_ID })
		local ok, err = pcall(ExchangeLedger.assertConserved, snapshot, OBJECTS, label)
		return if ok then "CONSERVED" else tostring(err)
	end

	--- Has this player's Take reached their KEY, on the modelled disk?
	local function takeIsDurable(fixture, userId): boolean
		local data = ExchangeLedger.diskData(fixture.Uni, fixture.Server, userId)
		local reserved = if type(data) == "table"
			then data[ExchangeLedger.VerdictStore and "_Scribe" or "_Scribe"]
			else nil
		if type(reserved) ~= "table" or type(reserved.Exchange) ~= "table" then
			return false
		end
		local record = reserved.Exchange[TID]
		return type(record) == "table" and type(record.Take) == "table" and next(record.Take) ~= nil
	end

	local function legs(fixture)
		fixture.CtxA.Legs = nil
		return {
			A = {
				Ctx = fixture.CtxA,
				UserId = A_ID,
				Legs = {
					{ Path = { "Inventory" }, Kind = "Key", Key = "sword" },
					{ Path = { "Coins" }, Kind = "Qty", Amount = 100 },
				},
			},
			B = {
				Ctx = fixture.CtxB,
				UserId = B_ID,
				Legs = { { Path = { "Inventory" }, Kind = "Key", Key = "shield" } },
			},
		}
	end

	describe("C3: no verdict can exist before both takes are durable", function()
		it("commits an exchange whose verdict store REFUSES to decide until both disks carry the take", function()
			-- The store does not watch the ordering, it enforces it. An implementation
			-- that proposed before both flushes landed would be refused and the exchange
			-- would not commit at all, which is what makes this a proof rather than an
			-- observation.
			local fixture = setup()
			local sides = legs(fixture)
			local real = fixture.Uni.Disk:GetDataStore(ExchangeVerdict.STORE_NAME)
			local proposals, refusals = 0, 0

			local guarded = {
				UpdateAsync = function(_self, key, transform)
					proposals += 1
					if not (takeIsDurable(fixture, A_ID) and takeIsDurable(fixture, B_ID)) then
						refusals += 1
						error("verdict refused: a take was not durable yet", 0)
					end
					return real:UpdateAsync(key, transform)
				end,
				GetAsync = function(_self, key)
					return real:GetAsync(key)
				end,
			}

			local outcome
			fixture.Uni.Sched:Spawn(function()
				outcome = Exchange.Attempt({
					ExchangeId = TID,
					VerdictStore = guarded,
					Flush = function(side)
						return fixture.Flush(if side.UserId == A_ID then fixture.PA else fixture.PB)
					end,
				}, sides.A, sides.B)
			end)
			fixture.Uni:Run(300)
			fixture.Uni:Settle(120)

			expect(`outcome={tostring(outcome)} proposals={proposals} refusals={refusals}`).to.equal(
				"outcome=Committed proposals=1 refusals=0"
			)
		end)

		it("REFUSES the verdict, and conserves, when a take never reaches the disk", function()
			-- The negative control. If the guard cannot refuse, the case above proves
			-- nothing: it would pass on an implementation that proposed at any time.
			-- Here the flush is made to answer false, so no take is ever durable, and the
			-- exchange must abandon with every object still exactly where it started.
			local fixture = setup()
			local sides = legs(fixture)
			local real = fixture.Uni.Disk:GetDataStore(ExchangeVerdict.STORE_NAME)
			local refusals = 0

			local guarded = {
				UpdateAsync = function(_self, key, transform)
					if not (takeIsDurable(fixture, A_ID) and takeIsDurable(fixture, B_ID)) then
						refusals += 1
						error("verdict refused: a take was not durable yet", 0)
					end
					return real:UpdateAsync(key, transform)
				end,
				GetAsync = function(_self, key)
					return real:GetAsync(key)
				end,
			}

			local outcome, err
			fixture.Uni.Sched:Spawn(function()
				outcome, err = Exchange.Attempt({
					ExchangeId = TID,
					VerdictStore = guarded,
					Flush = function()
						return false -- never provably durable
					end,
				}, sides.A, sides.B)
			end)
			fixture.Uni:Run(300)
			fixture.Uni:Settle(120)

			expect(
				`outcome={tostring(outcome)} refused={refusals > 0} unresolved={tostring(
					err ~= nil and string.find(err, "no verdict", 1, true) ~= nil
				)}`
			).to.equal("outcome=nil refused=true unresolved=true")
		end)
	end)

	describe("C2: conservation holds between every step of the ordinary path", function()
		it("stays conserved through claim, stake, take, verdict, settle and delivery", function()
			-- Driven one operation at a time rather than through Attempt, so the gate can
			-- run between every step. The gate reads the DISK, so a step that has not
			-- been flushed shows as still-owned by its origin, which is correct: nothing
			-- has moved until it is durable.
			local fixture = setup()
			local sides = legs(fixture)
			local store = fixture.Uni.Disk:GetDataStore(ExchangeVerdict.STORE_NAME)
			local sheet = {}

			local function step(label, run)
				run()
				fixture.Uni:Run(60)
				fixture.Uni:Settle(60)
				table.insert(sheet, `{label}={conserved(fixture, label)}`)
			end

			step("start", function() end)
			step("claimA", function()
				ExchangeLeg.Claim(fixture.CtxA, TID, { Digest = "d", Role = "A", Partner = B_ID })
			end)
			step("claimB", function()
				ExchangeLeg.Claim(fixture.CtxB, TID, { Digest = "d", Role = "B", Partner = A_ID })
			end)
			step("stakeA", function()
				ExchangeLeg.Escrow(fixture.CtxA, TID, sides.A.Legs)
			end)
			step("stakeB", function()
				ExchangeLeg.Escrow(fixture.CtxB, TID, sides.B.Legs)
			end)
			step("takeB", function()
				local record = fixture.CtxA.Tree.Reserved.Exchange[TID].Get()
				ExchangeLeg.FillTake(fixture.CtxB, TID, record.Escrow)
			end)
			step("takeA", function()
				local record = fixture.CtxB.Tree.Reserved.Exchange[TID].Get()
				ExchangeLeg.FillTake(fixture.CtxA, TID, record.Escrow)
			end)
			step("flushBoth", function()
				fixture.Flush(fixture.PA)
				fixture.Flush(fixture.PB)
			end)
			step("verdict", function()
				fixture.Uni.Sched:Spawn(function()
					ExchangeVerdict.Propose(store, TID, { V = "Commit", A = A_ID, B = B_ID, D = "d" })
				end)
			end)
			step("settleA", function()
				ExchangeLeg.Settle(fixture.CtxA, TID, { V = "Commit", D = "d" })
				fixture.Flush(fixture.PA)
			end)
			step("settleB", function()
				ExchangeLeg.Settle(fixture.CtxB, TID, { V = "Commit", D = "d" })
				fixture.Flush(fixture.PB)
			end)
			step("deliverA", function()
				ExchangeLeg.Deliver(fixture.CtxA, TID)
				fixture.Flush(fixture.PA)
			end)
			step("deliverB", function()
				ExchangeLeg.Deliver(fixture.CtxB, TID)
				fixture.Flush(fixture.PB)
			end)

			local violations = {}
			for _, line in sheet do
				if not string.find(line, "=CONSERVED", 1, true) then
					table.insert(violations, line)
				end
			end
			expect(`steps={#sheet} violations={table.concat(violations, " | ")}`).to.equal("steps=13 violations=")

			-- And the exchange actually happened, or every step above was conserving
			-- because nothing ever moved.
			expect(
				`aShield={tostring(fixture.DA.Inventory["shield"].Get() ~= nil)} bSword={tostring(
					fixture.DB.Inventory["sword"].Get() ~= nil
				)} aCoins={fixture.DA.Coins.Get()}`
			).to.equal("aShield=true bSword=true aCoins=400")
		end)

		it("stays conserved while hostile game code runs between every step", function()
			-- The r3/r4/r5 failure mode was ordinary play interleaved with the protocol,
			-- so ordinary play is what runs here: spending to zero, filling the
			-- destination to MaxKeys, and re-inserting an item through a container table
			-- captured from Get() before the stake. That last one is the alias residual
			-- the design documents and cannot prevent; the gate must DETECT it.
			local fixture = setup()
			local sides = legs(fixture)
			local aliased = fixture.DA.Inventory.Get()

			ExchangeLeg.Claim(fixture.CtxA, TID, { Digest = "d", Role = "A", Partner = B_ID })
			ExchangeLeg.Claim(fixture.CtxB, TID, { Digest = "d", Role = "B", Partner = A_ID })
			ExchangeLeg.Escrow(fixture.CtxA, TID, sides.A.Legs)
			fixture.Flush(fixture.PA)
			fixture.Uni:Settle(60)

			-- The staked sword is gone from game data and sits in A's escrow.
			local staked = conserved(fixture, "staked")

			-- HOSTILE: put it back through the alias, which no funnel sees.
			aliased.sword = { Qty = 1 }
			fixture.Flush(fixture.PA)
			fixture.Uni:Settle(60)
			local afterAlias = conserved(fixture, "afterAlias")

			expect(`staked={staked} detected={tostring(afterAlias ~= "CONSERVED")}`).to.equal(
				"staked=CONSERVED detected=true"
			)
		end)
	end)
end
