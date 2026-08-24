--!nonstrict
-- The cross-player transaction refusal, followed all the way to the DataStore.
--
-- WHAT CHANGED IN THIS FILE, AND WHY
--
-- This file pinned the DISK half of a bug that has now been fixed, so two of its
-- cases asserted the broken outcome and one asserted a shape that is no longer
-- allowed. `Data.Transaction`'s nesting guard was `if self._txn then` and `self` is
-- ONE PLAYER'S TREE, so `Transaction(A)` wrapping `Transaction(B)` tripped neither
-- the nesting guard nor the yield guard and the outer's rollback never reached the
-- inner player. This file showed where that ended up: both profiles FLUSHED, each
-- flush answering `true`, and the two keys read straight off the modelled disk into
-- a total of 150 where 100 went in -- or 50, with `true` returned. Nothing
-- reconciled it, because there was nothing to reconcile against.
--
-- A write to a different player's tree from inside a transaction is now refused, so:
--
--   * "stores a correct transfer on both keys, and conserves" ran the transfer as a
--     NESTED cross-player transaction. That shape no longer exists. It is now run as
--     two SEPARATE transactions -- the shape the library supports and the shape the
--     refusal's error text points at -- and it still has to reach both keys and still
--     has to conserve. Losing that would be a worse bug than the one being fixed.
--   * "mints currency that survives to the datastore" and "destroys currency on the
--     datastore while the API reports success" keep their bodies and assert the new
--     outcome: refused, nothing written, the disk still totalling 100. The mint case
--     covers the guard in RunTransaction (a nested transaction on another player);
--     the destroy case is rewritten around the BARE cross-player write, which no
--     nesting guard could ever have caught and which is caught on the accessor.
--   * the two controls are UNCHANGED: separate keys, and a single-player rollback
--     leaving the disk exactly as it was.
--
-- WHY THE SIM AND NOT TestCtx: this runs the real vendored ProfileStore at
-- `src/Internal/Store/` over the modelled disk, so "it reached the datastore" means
-- it went through the actual save path -- payload snapshot, UpdateAsync, commit --
-- rather than through a fake that records whatever it is handed.
--
-- THE CONTROLS ARE NOT OPTIONAL. "The disk still says 100" is exactly what a broken
-- fixture produces: a key read that returns something stale, a flush that never
-- landed, a template default masquerading as a saved value. Every one of those
-- explanations also produces "100", which is now the PASSING number rather than the
-- failing one -- so the controls carry more weight here than they did when this file
-- was pinning a defect. Case 1 shows a transfer moving the disk on BOTH keys and
-- conserving, which proves the fixture can move the disk at all. Case 3 shows a
-- single-player rollback leaving the disk untouched, which proves the save path reads
-- POST-rollback state rather than whatever the tree last touched. Only then do the
-- refusal cases mean anything.

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

	local A_ID, B_ID = 91001, 91002
	local START = 100
	local AMOUNT = 50

	local PRODUCTION = {
		AUTO_SAVE_PERIOD = 300,
		SESSION_STEAL = 40,
		FIRST_LOAD_REPEAT = 5,
		LOAD_REPEAT_PERIOD = 10,
		ASSUME_DEAD = 630,
		START_SESSION_TIMEOUT = 120,
	}

	local universe

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	--- Call a yielding Scribe API without parking the spec thread.
	---
	--- `Flush` yields, and the spec thread is not one the scheduler owns, so it has to
	--- go through Sched:Spawn like every other sim spec that flushes.
	local function call(uni, fn)
		local result
		uni.Sched:Spawn(function()
			local ok, value = pcall(fn)
			result = if ok then value else `raised: {value}`
		end)
		uni:Run(120)
		return result
	end

	--- What is actually stored under a player's key, by Scribe's own key function.
	---
	--- Returns a string rather than a number on purpose. An absent record and a
	--- record holding zero are different findings and must not both read as `0` --
	--- "the save never landed" would otherwise be indistinguishable from "the save
	--- landed and the value is zero", and the second is a legitimate state here.
	local function storedCoins(uni, server, userId: number): string
		local key = server.Bundle.Ctx.Persistence.KeyFor(userId)
		local record = uni.Disk.Keyspace:Read("Default", key)
		if record == nil or record.Value == nil or record.Value.Data == nil then
			return "ABSENT"
		end
		return tostring(record.Value.Data.Coins)
	end

	--- Save both profiles and assert Scribe said both are durable.
	---
	--- The assertion inside the helper is the load-bearing part. Every "the disk says
	--- N" claim below is only worth reading if the save it depends on actually
	--- happened, and a `Flush` that quietly returned false would otherwise leave the
	--- disk holding the PREVIOUS total -- which, for the mint case, is the number a
	--- correct implementation would produce. A silent flush failure would therefore
	--- disguise the defect as a pass.
	local function flushBoth(uni, server, pa, pb)
		local okA = call(uni, function()
			return server.Bundle.Data.Flush(pa, { Timeout = 30 })
		end)
		local okB = call(uni, function()
			return server.Bundle.Data.Flush(pb, { Timeout = 30 })
		end)
		expect(`flushA={tostring(okA)} flushB={tostring(okB)}`).to.equal("flushA=true flushB=true")
		-- Let the commits land before anything reads the keyspace.
		uni:Settle(120)
	end

	--- One server, two players, A holding 100 coins ON DISK and B holding zero.
	---
	--- Not "in memory": the setup flushes, so the starting total is a fact about the
	--- keyspace and the later comparison is disk-against-disk.
	local function setup()
		universe = Universe.new({
			Seed = 20260821,
			Servers = 1,
			Constants = PRODUCTION,
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Nominal",
			NoBudget = true,
			-- Deliberately unreachable: nothing here is about Health, and an
			-- accidental Outage would refuse writes and explain every number below
			-- with the wrong mechanism.
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
			Template = { Coins = Scribe.Int(0, { Min = 0, Max = 1000000 }) },
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
		-- If either profile is not loaded, every case below would be asserting on
		-- nils and a crash is a clearer answer than a confusing failure.
		expect(`loadedA={dA ~= nil} loadedB={dB ~= nil}`).to.equal("loadedA=true loadedB=true")

		dA.Coins.Set(START)
		dB.Coins.Set(0)
		flushBoth(uni, server, pa, pb)
		expect(`A={storedCoins(uni, server, A_ID)} B={storedCoins(uni, server, B_ID)}`).to.equal("A=100 B=0")

		return uni, server, Data, pa, pb, dA, dB
	end

	--- `diskA/diskB/total` in one string, so a failure prints the whole balance sheet
	--- rather than the first number that happened to differ.
	local function ledger(uni, server): string
		local a, b = storedCoins(uni, server, A_ID), storedCoins(uni, server, B_ID)
		local total = if a == "ABSENT" or b == "ABSENT" then "?" else tostring(tonumber(a) + tonumber(b))
		return `diskA={a} diskB={b} TOTAL={total}`
	end

	it("stores a correct transfer on both keys, and conserves", function()
		-- THE LIVENESS GATE, and now also the demonstration that the supported shape
		-- survives the guard. If this does not move the disk, every "the disk still
		-- says 100" claim below passes vacuously -- and "100" is the number a fixture
		-- that cannot write at all would report too.
		--
		-- Two transactions, side by side, neither inside the other. Each is atomic on
		-- its own key, which is the most any single Scribe transaction has ever been;
		-- what the pair is NOT is atomic with each other, and that is the gap the
		-- durable outbox exists to close (see the Transactions guide, and the error
		-- text the refusal cases below assert).
		local uni, server, Data, pa, pb, dA, dB = setup()

		local okA = Data.Transaction(pa, function()
			dA.Coins.Increment(-AMOUNT)
		end)
		local okB = Data.Transaction(pb, function()
			dB.Coins.Increment(AMOUNT)
		end)
		flushBoth(uni, server, pa, pb)

		expect(`okA={tostring(okA)} okB={tostring(okB)} {ledger(uni, server)}`).to.equal(
			"okA=true okB=true diskA=50 diskB=50 TOTAL=100"
		)
	end)

	it("keeps the two players on separate keys, which is why one save cannot cover both", function()
		-- The durability analogue of CrossPlayerTxnAtomicity's "gives each player their
		-- own Tree". Every case in this file is a claim about two INDEPENDENT saves; if
		-- a refactor ever put both players under one key, the file would keep passing
		-- while measuring something else entirely.
		local uni, server = setup()
		local Persistence = server.Bundle.Ctx.Persistence
		local keyA, keyB = Persistence.KeyFor(A_ID), Persistence.KeyFor(B_ID)

		expect(keyA).never.to.equal(keyB)
		expect(uni.Disk.Keyspace:Read("Default", keyA)).to.be.ok()
		expect(uni.Disk.Keyspace:Read("Default", keyB)).to.be.ok()
	end)

	it("leaves the disk exactly as it was when a single-player transaction throws", function()
		-- THE CONTROL. One tree, one key, one transaction, and it fails: the rollback
		-- is the whole mechanism working as designed, and the disk must not move.
		--
		-- Without this, "the disk says 150" in the next case could just as well mean
		-- the fixture writes whatever the tree last touched regardless of rollback.
		-- Here the tree IS rolled back and the disk agrees, so the save path is
		-- demonstrably reading post-rollback state.
		local uni, server, Data, pa, pb, dA = setup()

		local outerOk = Data.Transaction(pa, function()
			dA.Coins.Increment(-AMOUNT)
			error("single-player validation failed")
		end)
		flushBoth(uni, server, pa, pb)

		expect(`outerOk={tostring(outerOk)} live={dA.Coins.Get()} {ledger(uni, server)}`).to.equal(
			"outerOk=false live=100 diskA=100 diskB=0 TOTAL=100"
		)
	end)

	it("refuses the nested cross-player transaction that used to mint currency on disk", function()
		-- WAS "mints currency that survives to the datastore", and the reason this
		-- file exists. Same body, including the outer throw: the outer transaction
		-- failed AFTER the inner one had committed, A's debit was rolled back, B's
		-- credit was not, and then both profiles saved -- each save individually
		-- correct, each `Flush` answering `true`. 150 coins ended up on the disk where
		-- 100 went in, and no later save reconciled it, because the two keys have no
		-- relationship the library knows about.
		--
		-- The inner call is refused now, so `innerOk` is never even assigned, the
		-- outer fails on that refusal rather than on its own `error`, and the flush
		-- that follows writes the rolled-back state. The disk is asserted, not the
		-- tree: the claim is that nothing reached the store, which is the only version
		-- of the claim that matters once a save has run.
		local uni, server, Data, pa, pb, dA, dB = setup()

		local innerOk, err = nil, nil
		local outerOk
		outerOk, err = Data.Transaction(pa, function()
			dA.Coins.Increment(-AMOUNT)
			innerOk = Data.Transaction(pb, function()
				dB.Coins.Increment(AMOUNT)
			end)
			error("outer validation failed")
		end)
		flushBoth(uni, server, pa, pb)

		local refused = string.find(tostring(err), "do not span players", 1, true) ~= nil
		expect(
			`outerOk={tostring(outerOk)} innerRan={tostring(innerOk ~= nil)} refused={tostring(refused)} `
				.. ledger(uni, server)
		).to.equal("outerOk=false innerRan=false refused=true diskA=100 diskB=0 TOTAL=100")
	end)

	it("refuses the bare cross-player write that used to destroy currency on disk", function()
		-- WAS "destroys currency on the datastore while the API reports success" --
		-- the same defect from the other side, and worse in the way that matters,
		-- because the outer call returned `true`. That version reached the destroy
		-- through a nested transaction whose inner half rolled back. This one reaches
		-- it WITHOUT any nesting at all: a plain write to B inside A's transaction,
		-- which is what a developer actually types, and which no nesting guard could
		-- have caught however it was scoped -- there is no second transaction to
		-- notice. It is refused on the accessor instead.
		--
		-- The outer body then fails on that refusal, so A's debit rolls back too and
		-- the API's answer matches what is on the disk. That is the whole point:
		-- before, `true` meant "this tree committed" and said nothing about the half
		-- of the operation that had not.
		local uni, server, Data, pa, pb, dA, dB = setup()

		local err
		local outerOk
		outerOk, err = Data.Transaction(pa, function()
			dA.Coins.Increment(-AMOUNT)
			dB.Coins.Increment(AMOUNT)
		end)
		flushBoth(uni, server, pa, pb)

		local refused = string.find(tostring(err), "belongs to a different player", 1, true) ~= nil
		local routed = string.find(tostring(err), "Data.SendMessage", 1, true) ~= nil
		expect(
			`outerOk={tostring(outerOk)} refused={tostring(refused)} routed={tostring(routed)} ` .. ledger(uni, server)
		).to.equal("outerOk=false refused=true routed=true diskA=100 diskB=0 TOTAL=100")
	end)
end
