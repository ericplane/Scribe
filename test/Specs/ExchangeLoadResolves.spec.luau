--!nonstrict
-- The load hook: an interrupted exchange resolves itself the next time the profile loads.
--
-- Everything below the hook is already specced. This is about the WIRING, which is the
-- part that is easy to leave out and impossible to notice: every primitive can be
-- correct and every mutation can die while no code path ever calls any of it on a real
-- server. An exchange would then sit staked forever, with the player's item in an escrow
-- nothing looks at.
--
-- So these assert the plumbing, not the protocol: that the subsystem exists, that the
-- hook runs on load, that it costs nothing when there is nothing to do, and that a
-- profile which crashed mid-exchange comes back whole.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local ExchangeLeg = require(Root.Scribe.Internal.ExchangeLeg)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local TID = "tid_load"
	local USER, PARTNER = 96101, 96102

	local TEMPLATE = {
		Coins = Scribe.Int(0, { Min = 0, Max = 10000 }),
		Inventory = Scribe.DictOf({ Qty = Scribe.Int(1, { Min = 1, Max = 99 }) }, { MaxKeys = 4 }),
	}

	local function ctxFor(harness, player, entry)
		return { Tree = entry.Tree, Entry = entry, Compiled = harness.Compiled, UserId = player.UserId }
	end

	--- A profile that crashed with an exchange staked: the item is in escrow, the record is
	--- on the key, and nobody resolved it.
	local function crashedMidTrade()
		local harness = TestCtx.make({ Template = TEMPLATE })
		local player, entry = harness.Join(USER)
		local data = harness.Data.Get(player)
		data.Inventory["relic"].Set({ Qty = 1 })

		local ctx = ctxFor(harness, player, entry)
		expect(select(1, ExchangeLeg.Claim(ctx, TID, { Digest = "d", Role = "A", Partner = PARTNER }))).to.equal(true)
		expect(select(1, ExchangeLeg.Escrow(ctx, TID, { { Path = { "Inventory" }, Kind = "Key", Key = "relic" } }))).to.equal(
			true
		)
		expect(`staked={tostring(data.Inventory["relic"].Get() == nil)}`).to.equal("staked=true")

		harness.Data.Flush(player)
		harness.Leave(player)
		return harness
	end

	it("constructs the subsystem and mocks the verdict key outside a live game", function()
		-- If the subsystem is absent the load hook is skipped silently, so its presence
		-- is asserted before anything that depends on it.
		local harness = TestCtx.make({ Template = TEMPLATE })
		expect(
			`present={tostring(harness.Ctx.Exchanges ~= nil)} mocked={tostring(
				harness.Ctx.Exchanges ~= nil and harness.Ctx.Exchanges.UsesMockStore
			)}`
		).to.equal("present=true mocked=true")
		harness.Cleanup()
	end)

	it("does not make the join wait on the verdict round trip", function()
		-- ROUND 4. The hook resolved inline, so every exchange it found put a DataStore
		-- round trip in front of the player's own load: the client's first snapshot,
		-- and every other load hook behind this one, waited on a key that has nothing
		-- to do with getting that player into the game. The player who most needs their
		-- data back, the one returning with an interrupted exchange, got the slowest join.
		--
		-- Measured by asking, from INSIDE the store call and after it has yielded,
		-- whether the join has returned yet. Inline, it cannot have. Spawned, it has.
		local first = crashedMidTrade()
		local second = TestCtx.make({ Template = TEMPLATE, Fake = first.Fake })

		-- The hooks already run post-Ready, so "has Join returned" is the wrong probe and
		-- reports green on the blocking version. What actually waits is the hooks BEHIND
		-- this one in the same block: Monetization, Leaderboards, and the replication
		-- entry-ready that puts the player's first snapshot on the wire.
		local replicationRan = false
		local sawReplicationRan = nil
		local originalReady = second.Ctx.Replication.OnEntryReady
		second.Ctx.Replication.OnEntryReady = function(entry)
			replicationRan = true
			return originalReady(entry)
		end

		local inner = second.Ctx.Exchanges.VerdictStore()
		second.Ctx.Exchanges.VerdictStore = function()
			return {
				UpdateAsync = function(selfRef, key, transform)
					task.wait(0.05)
					if sawReplicationRan == nil then
						sawReplicationRan = replicationRan
					end
					return inner.UpdateAsync(selfRef, key, transform)
				end,
				GetAsync = function(selfRef, key)
					return inner.GetAsync(selfRef, key)
				end,
			}
		end

		local player = second.Join(USER)

		-- And it still finishes: off the load thread is not the same as never.
		local deadline = os.clock() + 3
		while second.Ctx.Persistence.EntryFor(player).Tree.Reserved.Exchange[TID].Get() ~= nil do
			if os.clock() > deadline then
				break
			end
			task.wait(0.02)
		end
		local data = second.Data.Get(player)

		-- Asserted DIRECTLY, never as `== false`. Nil means the store was never reached,
		-- and a comparison against false reads that as a pass: the probe would then be
		-- measuring nothing at all, which is exactly what the first version of this
		-- case did.
		expect(`replicationHadRun={tostring(sawReplicationRan)} relic={tostring(data.Inventory["relic"].Get() ~= nil)}`).to.equal(
			"replicationHadRun=true relic=true"
		)

		second.Cleanup()
		first.Cleanup()
	end)

	it("resolves an interrupted exchange on the next load, and the item comes back", function()
		-- The whole point of the hook. The player crashed with the relic in escrow and
		-- no verdict anywhere; the load proposes Abort, settles, and delivers it back.
		local first = crashedMidTrade()
		local second = TestCtx.make({ Template = TEMPLATE, Fake = first.Fake })
		local player = second.Join(USER)
		local data = second.Data.Get(player)

		local entry = second.Ctx.Persistence.EntryFor(player)
		expect(
			`relic={tostring(data.Inventory["relic"].Get() ~= nil)} record={tostring(
				entry.Tree.Reserved.Exchange[TID].Get()
			)} inbox={tostring(entry.Tree.Reserved.ExchangeInbox[TID].Get())}`
		).to.equal("relic=true record=nil inbox=nil")

		second.Cleanup()
		first.Cleanup()
	end)

	it("does nothing, and touches no store, for a profile with no exchanges", function()
		-- The common case by a very long way. A profile that has never exchanged must not
		-- pay a DataStore round trip on every load, so the hook reads two containers and
		-- returns before acquiring anything.
		local harness = TestCtx.make({ Template = TEMPLATE })
		local player = harness.Join(USER)
		local entry = harness.Ctx.Persistence.EntryFor(player)

		local resolved = harness.Ctx.Exchanges.Resolve(entry)
		expect(`resolved={resolved}`).to.equal("resolved=0")
		harness.Cleanup()
	end)

	it("delivers a parked inbox entry on load, with no record left to settle", function()
		-- The other half of what a load owes an exchange: a settle that landed but whose
		-- delivery never did. There is no record any more, only an inbox entry, and the
		-- resolution still has to run.
		local first = TestCtx.make({ Template = TEMPLATE })
		local player, entry = first.Join(USER)
		first.Data.Flush(player)
		entry.Tree.Reserved.ExchangeInbox[TID].Set({
			Id = TID,
			Verdict = "Commit",
			Legs = { { Path = { "Inventory" }, Kind = "Key", Key = "prize", Value = { Qty = 2 } } },
		})
		first.Data.Flush(player)
		first.Leave(player)

		local second = TestCtx.make({ Template = TEMPLATE, Fake = first.Fake })
		local rejoined = second.Join(USER)
		local data = second.Data.Get(rejoined)
		local prize = data.Inventory["prize"].Get()

		expect(
			`qty={tostring(prize and prize.Qty)} inbox={tostring(
				second.Ctx.Persistence.EntryFor(rejoined).Tree.Reserved.ExchangeInbox[TID].Get()
			)}`
		).to.equal("qty=2 inbox=nil")

		second.Cleanup()
		first.Cleanup()
	end)
end
