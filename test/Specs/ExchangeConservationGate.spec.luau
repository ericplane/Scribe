--!nonstrict
-- C1: the conservation gate itself, built and broken BEFORE any exchange code exists.
--
-- Nothing here exercises an exchange. There is no exchange to exercise. This file exists to
-- answer one question about the gate that everything later is measured against: can
-- it tell a conserved disk from a duplicated one? A gate that cannot detect a
-- hand-planted duplicate detects nothing, and every green spec built on top of it is
-- worth nothing either.
--
-- So every state below is planted directly on the MODELLED DISK, by reference,
-- bypassing Scribe entirely. That is deliberate on two counts. The gate is a
-- function of stored bytes, so bytes are the right input; and planting through
-- Scribe would test Scribe's refusals rather than the gate's arithmetic.
--
-- THE CONTROL IS NOT OPTIONAL. Case 1 loads two real profiles through Scribe, flushes
-- them, and asserts the gate passes. Without it, every "the gate failed" result below
-- is equally well explained by a gate that reads nothing at all and reports zero
-- copies of everything -- which fails a `== 1` check for exactly the wrong reason.
--
-- The three states that must PASS matter as much as the two that must fail. A gate
-- that is red on correct code gets loosened, and the loosening that presents itself
-- (relaxing the total to `<= 1`) is precisely the one that disarms it. So the
-- pre-verdict stake and the ghost window are pinned as PASSING here, at the same time
-- as the duplicates are pinned as failing.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Template = require(Root.Scribe.Internal.Template)
	local Universe = require(Root.Test.Sim.Universe)
	local Guard = require(Root.Test.Sim.Guard)
	-- Sim-backed: needs a modelled disk, which only the headless runner can build.
	local it = if require(Root.Test.Sim.Available).Ready then it else itSKIP
	local StubTransport = require(Root.Test.Helpers.StubTransport)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)
	local ExchangeLedger = require(Root.Test.Helpers.ExchangeLedger)

	local RESERVED = Template.RESERVED_ROOT
	local A_ID, B_ID = 92001, 92002
	local ITEM_A, ITEM_B = "it_a7f", "it_b19"
	local TID = "tid_gate_1"
	local START_COINS = 100

	local PRODUCTION = {
		AUTO_SAVE_PERIOD = 300,
		SESSION_STEAL = 40,
		FIRST_LOAD_REPEAT = 5,
		LOAD_REPEAT_PERIOD = 10,
		ASSUME_DEAD = 630,
		START_SESSION_TIMEOUT = 120,
	}

	-- The three objects every case below tracks. Two unique keys and one fungible
	-- total, because the two kinds count differently and a gate that only handles
	-- one of them is half a gate.
	local OBJECTS = {
		{ Kind = "Unique", Path = { "Inventory" }, Id = ITEM_A },
		{ Kind = "Unique", Path = { "Inventory" }, Id = ITEM_B },
		{ Kind = "Fungible", Path = { "Coins" }, Total = START_COINS },
	}

	local universe

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	--- Call a yielding Scribe API without parking the spec thread.
	local function call(uni, fn)
		local result
		uni.Sched:Spawn(function()
			local ok, value = pcall(fn)
			result = if ok then value else `raised: {value}`
		end)
		uni:Run(120)
		return result
	end

	--- One server, two players, each holding one item on DISK, A holding the coins.
	---
	--- Flushed, so the starting state is a fact about the keyspace rather than about
	--- a tree in memory, and every later comparison is disk against disk.
	local function setup()
		universe = Universe.new({
			Seed = 20260825,
			Servers = 1,
			Constants = PRODUCTION,
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Nominal",
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
			Template = {
				Coins = Scribe.Int(0, { Min = 0, Max = 1000000 }),
				Inventory = Scribe.DictOf({
					Qty = Scribe.Int(1, { Min = 1, Max = 999 }),
				}, { MaxKeys = 50 }),
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
		local dA, dB = Data.Get(pa), Data.Get(pb)
		expect(`loadedA={dA ~= nil} loadedB={dB ~= nil}`).to.equal("loadedA=true loadedB=true")

		dA.Coins.Set(START_COINS)
		dA.Inventory[ITEM_A].Set({ Qty = 1 })
		dB.Coins.Set(0)
		dB.Inventory[ITEM_B].Set({ Qty = 1 })

		local okA = call(uni, function()
			return Data.Flush(pa, { Timeout = 30 })
		end)
		local okB = call(uni, function()
			return Data.Flush(pb, { Timeout = 30 })
		end)
		expect(`flushA={tostring(okA)} flushB={tostring(okB)}`).to.equal("flushA=true flushB=true")
		uni:Settle(120)

		return uni, server, Data, pa, pb
	end

	--- The stored data for a player, BY REFERENCE, so a plant lands on the disk the
	--- gate reads rather than on a copy of it.
	local function disk(uni, server, userId)
		local key = server.Bundle.Ctx.Persistence.KeyFor(userId)
		local record = uni.Disk.Keyspace:Read("Default", key)
		expect(`record={record ~= nil} data={record ~= nil and record.Value ~= nil}`).to.equal("record=true data=true")
		return record.Value.Data
	end

	--- The reserved root's Exchange container on a stored profile, created if absent.
	---
	--- Absent is the normal state here: STEP 1 has not run, so nothing declares
	--- these containers yet. The gate must cope with both.
	local function exchangeContainer(data, key: string)
		local reserved = data[RESERVED]
		if type(reserved) ~= "table" then
			reserved = {}
			data[RESERVED] = reserved
		end
		if type(reserved[key]) ~= "table" then
			reserved[key] = {}
		end
		return reserved[key]
	end

	--- A Key leg carrying one unique item.
	local function keyLeg(path: string, id: string)
		return { Path = { path }, Kind = "Key", Key = id, Value = { Qty = 1 } }
	end

	--- Plant a committed verdict for the exchange.
	local function plantVerdict(uni, exchangeId: string, decision: string)
		uni.Disk.Keyspace:Commit(ExchangeLedger.VerdictStore, exchangeId, {
			V = decision,
			A = A_ID,
			B = B_ID,
			D = "digest",
		}, { Now = 0, VersionId = `v_{exchangeId}_{decision}` })
	end

	--- Run the gate and report what it decided, as a string, so a failure prints the
	--- balance sheet rather than only the word "false".
	local function gate(uni, server): string
		local snapshot = ExchangeLedger.snapshot(uni, server, { A_ID, B_ID })
		local ok, err = pcall(ExchangeLedger.assertConserved, snapshot, OBJECTS, "gate")
		if ok then
			return "CONSERVED"
		end
		return tostring(err)
	end

	it("passes on two untouched profiles, which is the control for every case below", function()
		-- If this fails, nothing else in the file means anything: a gate that reads
		-- no copies of anything also reports "not 1" for a planted duplicate, and
		-- would look like it was working.
		local uni, server = setup()
		expect(gate(uni, server)).to.equal("CONSERVED")

		-- And the balance sheet says the copies were actually FOUND, not merely that
		-- the count came out right. Zero copies of everything would also satisfy a
		-- gate that never looked.
		local snapshot = ExchangeLedger.snapshot(uni, server, { A_ID, B_ID })
		expect(ExchangeLedger.describe(snapshot, OBJECTS[1])).to.equal(
			`Inventory/{ITEM_A} owned=1 ghosts=0 [game[{A_ID}]=1]`
		)
		expect(ExchangeLedger.describe(snapshot, OBJECTS[3])).to.equal(`Coins owned=100 ghosts=0 [game[{A_ID}]=100]`)
	end)

	it("FAILS on a unique item hand-planted onto the other profile", function()
		-- THE MUTATION THE WHOLE FILE EXISTS FOR. No exchange code is involved: the item
		-- is copied onto B's stored inventory by hand, which is exactly what a
		-- duplicating exchange would leave behind.
		local uni, server = setup()
		local dataB = disk(uni, server, B_ID)
		dataB.Inventory[ITEM_A] = { Qty = 1 }

		local verdict = gate(uni, server)
		expect(verdict:find("conservation violated") ~= nil).to.equal(true)
		expect(verdict:find(`Inventory/{ITEM_A} owned=2`) ~= nil).to.equal(true)
	end)

	it("FAILS on an item destroyed off both profiles, not only on one duplicated onto two", function()
		-- Destruction is the other half of the gate and it is the half that gets
		-- forgotten, because the word people reach for is "duplication". An exchange that
		-- silently burns the item conserves nothing, and a gate stated as "no more
		-- than one owner" would pass this. Stating it as EXACTLY one is what makes
		-- the burn visible, and this case is what stops that being relaxed.
		local uni, server = setup()
		local dataB = disk(uni, server, B_ID)
		dataB.Inventory[ITEM_B] = nil

		local verdict = gate(uni, server)
		expect(verdict:find(`Inventory/{ITEM_B} owned=0`) ~= nil).to.equal(true)
	end)

	it("FAILS on a fungible amount minted onto the other profile", function()
		-- The same defect in the shape the gate counts differently. A unique object
		-- is present or absent; a quantity is a sum, and a gate that only knows how
		-- to count keys would pass this.
		local uni, server = setup()
		local dataB = disk(uni, server, B_ID)
		dataB.Coins = 50

		local verdict = gate(uni, server)
		expect(verdict:find("Coins owned=150") ~= nil).to.equal(true)
	end)

	it("FAILS on a mint hidden behind a negative balance, which a sum alone cannot see", function()
		-- The hole an adversarial review found in this gate AFTER it was already
		-- mutation-tested. A quantity leg with no declared Min can debit past zero:
		-- Scribe.Int(0) compiles Min = nil (Template.luau:780-782) and validateWrite
		-- skips the bounds clause entirely when min is nil (Node.luau:1106-1115), so
		-- a debit of 1000 against a balance of 100 stores -900 and every per-leg
		-- assertion passes exactly.
		--
		-- A gate that sums holdings algebraically is BLIND to it: -900 + 1000 == 100,
		-- which is the starting total, so conservation reads as intact while 1000
		-- real spendable units were created. A negative balance is not a holding, it
		-- is a liability, and it stops being one the moment any ordinary write floors
		-- the field at zero, at which point the mint is unrecoverable and unattributable.
		local uni, server = setup()
		local dataA, dataB = disk(uni, server, A_ID), disk(uni, server, B_ID)
		dataA.Coins = -900
		dataB.Coins = 1000

		local verdict = gate(uni, server)
		expect(verdict:find("conservation violated") ~= nil).to.equal(true)
		expect(verdict:find("negative") ~= nil).to.equal(true)
	end)

	it("FAILS on an escrow copy with no verdict backing it, because that is not a ghost", function()
		-- An escrow copy is excused ONLY as a ghost: a record still owing its own
		-- deletion, on the side the verdict dispossessed. Here A still holds the item
		-- in game data and B holds a second copy in escrow, so there are two owners
		-- and the gate must say so.
		local uni, server = setup()
		local dataB = disk(uni, server, B_ID)
		exchangeContainer(dataB, "Exchange")[TID] = {
			Id = TID,
			Role = "B",
			Partner = A_ID,
			Phase = "Staked",
			Escrow = { keyLeg("Inventory", ITEM_A) },
		}

		local verdict = gate(uni, server)
		expect(verdict:find(`Inventory/{ITEM_A} owned=2`) ~= nil).to.equal(true)
	end)

	it("PASSES on a pre-verdict stake, where the escrow owns it and the take is a copy", function()
		-- The state between 0.5 and the verdict, which is CORRECT and must not be
		-- flagged. A's item has left game data for A's escrow, and B is already
		-- holding a copy in its Take because the taker's copy has to be durable
		-- before a verdict can exist. Two copies on disk, one owner.
		local uni, server = setup()
		local dataA, dataB = disk(uni, server, A_ID), disk(uni, server, B_ID)
		dataA.Inventory[ITEM_A] = nil
		exchangeContainer(dataA, "Exchange")[TID] = {
			Id = TID,
			Role = "A",
			Phase = "Staked",
			Escrow = { keyLeg("Inventory", ITEM_A) },
		}
		exchangeContainer(dataB, "Exchange")[TID] = {
			Id = TID,
			Role = "B",
			Phase = "Staked",
			Take = { keyLeg("Inventory", ITEM_A) },
		}

		expect(gate(uni, server)).to.equal("CONSERVED")
		local snapshot = ExchangeLedger.snapshot(uni, server, { A_ID, B_ID })
		expect(ExchangeLedger.describe(snapshot, OBJECTS[1])).to.equal(
			`Inventory/{ITEM_A} owned=1 ghosts=1 [escrow[{A_ID}/{TID}]=1 take[{B_ID}/{TID}]=1 GHOST]`
		)
	end)

	it("PASSES during the ghost window, where a Commit moved ownership but a settle has not run", function()
		-- P6 in the crash matrix. The verdict says Commit, so B's Take owns the item
		-- and A's escrow copy is dispossessed: still on disk, owed for deletion, not
		-- spendable by anyone. One owner. If the gate flagged this it would be red on
		-- correct code, and the obvious relief would disarm it against the two cases
		-- above.
		local uni, server = setup()
		local dataA, dataB = disk(uni, server, A_ID), disk(uni, server, B_ID)
		dataA.Inventory[ITEM_A] = nil
		exchangeContainer(dataA, "Exchange")[TID] = {
			Id = TID,
			Role = "A",
			Phase = "Staked",
			Escrow = { keyLeg("Inventory", ITEM_A) },
		}
		exchangeContainer(dataB, "Exchange")[TID] = {
			Id = TID,
			Role = "B",
			Phase = "Staked",
			Take = { keyLeg("Inventory", ITEM_A) },
		}
		plantVerdict(uni, TID, "Commit")

		expect(gate(uni, server)).to.equal("CONSERVED")
		local snapshot = ExchangeLedger.snapshot(uni, server, { A_ID, B_ID })
		expect(ExchangeLedger.describe(snapshot, OBJECTS[1])).to.equal(
			`Inventory/{ITEM_A} owned=1 ghosts=1 [escrow[{A_ID}/{TID}]=1 GHOST take[{B_ID}/{TID}]=1]`
		)
	end)

	it("PASSES once the item is settled into the inbox and gone from both records", function()
		-- The far side of the settle, before delivery. One copy, in the taker's
		-- inbox, owned. This is the state the retry ladder converges on and it has to
		-- read as conserved or every liveness spec later will be fighting the gate.
		local uni, server = setup()
		local dataA, dataB = disk(uni, server, A_ID), disk(uni, server, B_ID)
		dataA.Inventory[ITEM_A] = nil
		-- The shape a settle actually writes, not a bare leg list. Planting the
		-- convenient shape here is how the gate came to read the wrong one.
		exchangeContainer(dataB, "ExchangeInbox")[TID] =
			{ Id = TID, Verdict = "Commit", Legs = { keyLeg("Inventory", ITEM_A) } }
		plantVerdict(uni, TID, "Commit")

		expect(gate(uni, server)).to.equal("CONSERVED")
	end)
end
