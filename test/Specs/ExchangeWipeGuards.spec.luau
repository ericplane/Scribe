--!nonstrict
-- L3 and must-fix 14: the three operations that destroy an exchange by rolling the wrong
-- half of the profile.
--
-- ClaimExchange straddles a boundary the rest of Scribe does not. Value in flight lives in
-- the reserved root while the matching hole lives in game data, and every operation
-- that treats those two halves differently can split them:
--
--   ResetData      clears profile.Data wholesale and rebuilds from defaults, so the
--                  escrow holding a staked item is destroyed with nothing left to say
--                  it existed.
--   RestoreVersion rolls GAME DATA back to a snapshot and deliberately PRESERVES the
--                  live reserved root. That is right for receipts and perks, which do
--                  not un-happen, and wrong in both directions for an exchange: a reverted
--                  stake puts the item back in the inventory while the escrow still
--                  holds it (duplicated), and a reverted delivery takes the item out of
--                  the inventory while the inbox entry is already cleared (destroyed).
--   OnOverwrite    cannot be refused at all, and is covered separately below.
--
-- The precondition is free in both refusable cases: the state is already read.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local ExchangeLeg = require(Root.Scribe.Internal.ExchangeLeg)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local TID = "tid_wipe"
	local USER = 97901

	local TEMPLATE = {
		Coins = Scribe.Int(0, { Min = 0, Max = 10000 }),
		Inventory = Scribe.DictOf({ Qty = Scribe.Int(1, { Min = 1, Max = 99 }) }, { MaxKeys = 4 }),
	}

	local function ctxFor(harness, player, entry)
		return { Tree = entry.Tree, Entry = entry, Compiled = harness.Compiled, UserId = player.UserId }
	end

	--- A profile with one item staked into escrow, flushed, and the player gone.
	---
	--- Returns the shared fake so a second harness can load the same key.
	local function stakedAndLeft(options)
		local harness = TestCtx.make({ Template = TEMPLATE, Options = options })
		local player, entry = harness.Join(USER)
		local data = harness.Data.Get(player)

		data.Inventory["relic"].Set({ Qty = 1 })
		harness.Data.Flush(player)

		expect(select(1, ExchangeLeg.Claim(ctxFor(harness, player, entry), TID, { Digest = "d", Role = "A" }))).to.equal(
			true
		)
		expect(select(
			1,
			ExchangeLeg.Escrow(ctxFor(harness, player, entry), TID, {
				{ Path = { "Inventory" }, Kind = "Key", Key = "relic" },
			})
		)).to.equal(true)
		-- Staked: out of game data, into the escrow.
		expect(`inGame={tostring(data.Inventory["relic"].Get() ~= nil)}`).to.equal("inGame=false")
		harness.Data.Flush(player)
		harness.Leave(player)
		return harness
	end

	describe("RestoreVersion", function()
		it("REFUSES while an exchange is staked, because it would duplicate the item", function()
			-- The snapshot predates the stake, so rolling game data back puts the relic
			-- into the inventory while the live escrow is still holding it. Two copies,
			-- one player, no record that it happened.
			local harness = stakedAndLeft()
			local versions = harness.Data.ListVersions(USER)
			expect(#versions >= 2).to.equal(true)

			local ok, reason = harness.Data.RestoreVersion(USER, versions[#versions].VersionId)
			expect(`ok={tostring(ok)} named={tostring(string.find(tostring(reason), "exchange", 1, true) ~= nil)}`).to.equal(
				"ok=false named=true"
			)
			harness.Cleanup()
		end)

		it("REFUSES while an inbox entry is undelivered, because it would destroy the item", function()
			-- The mirror case. A delivered item lives in game data and its inbox entry is
			-- already gone, so rolling game data back removes the item with nothing left
			-- to redeliver it.
			local harness = TestCtx.make({ Template = TEMPLATE })
			local player, entry = harness.Join(USER)
			harness.Data.Flush(player)

			entry.Tree.Reserved.ExchangeInbox[TID].Set({
				Id = TID,
				Verdict = "Commit",
				Legs = { { Path = { "Inventory" }, Kind = "Key", Key = "relic", Value = { Qty = 1 } } },
			})
			harness.Data.Flush(player)
			harness.Leave(player)

			local versions = harness.Data.ListVersions(USER)
			local ok, reason = harness.Data.RestoreVersion(USER, versions[#versions].VersionId)
			expect(`ok={tostring(ok)} named={tostring(string.find(tostring(reason), "exchange", 1, true) ~= nil)}`).to.equal(
				"ok=false named=true"
			)
			harness.Cleanup()
		end)

		it("ALLOWS a restore once no exchange state remains, which is the control", function()
			-- Without this the refusals above are equally well explained by a restore
			-- that never works.
			local harness = TestCtx.make({ Template = TEMPLATE })
			local player, _, data = harness.Join(USER)
			data.Coins.Set(111)
			harness.Data.Flush(player)
			data.Coins.Set(222)
			harness.Data.Flush(player)
			harness.Leave(player)

			local versions = harness.Data.ListVersions(USER)
			expect((harness.Data.RestoreVersion(USER, versions[#versions].VersionId))).to.equal(true)
			harness.Cleanup()
		end)
	end)

	describe("ResetData", function()
		it("REFUSES to wipe a profile holding a staked exchange", function()
			-- ResetData clears profile.Data and rebuilds from template defaults, which
			-- takes the reserved root with it. The staked relic is in neither place
			-- afterwards, and nothing reports that anything was lost.
			local first = stakedAndLeft()
			local second = TestCtx.make({ Template = TEMPLATE, Fake = first.Fake, Options = { ResetData = true } })
			local player = second.Join(USER)

			-- Asserted on the VALUE, not on the record. The load hook resolves an
			-- interrupted exchange, so by now the abort has returned the relic to the
			-- inventory and the record is correctly gone. Had the reset gone ahead, the
			-- escrow would have been wiped with everything else and there would have
			-- been nothing left to return: relic absent, no record, no report.
			local data = second.Data.Get(player)
			expect(
				`relic={tostring(data.Inventory["relic"].Get() ~= nil)} record={tostring(
					second.Ctx.Persistence.EntryFor(player).Tree.Reserved.Exchange[TID].Get()
				)}`
			).to.equal("relic=true record=nil")

			second.Cleanup()
			first.Cleanup()
		end)

		it("still wipes a profile with no exchange state, which is the control", function()
			local first = TestCtx.make({ Template = TEMPLATE })
			local player, _, data = first.Join(USER)
			data.Coins.Set(777)
			first.Data.Flush(player)
			first.Leave(player)

			local second = TestCtx.make({ Template = TEMPLATE, Fake = first.Fake, Options = { ResetData = true } })
			local _rejoined, _entry, freshData = second.Join(USER)
			expect(`coins={freshData.Coins.Get()}`).to.equal("coins=0")

			second.Cleanup()
			first.Cleanup()
		end)
	end)
end
