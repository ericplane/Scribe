--!nonstrict
-- Rolling back a transaction must produce the same result every time.
--
-- The restores themselves are disjoint, so their order does not change what they
-- write. The LISTENER WRITES they trigger are a different matter: a listener that
-- mirrors one field into another writes a value that is not part of the
-- transaction, so it is neither snapshotted nor rolled back. Whether it survived
-- used to depend on where `next` happened to walk the snapshot hash map, so the
-- same program rolled back to different states on different runs -- measured as
-- Coins/Gems landing one way and Alpha/Zulu the other.
--
-- Non-determinism here is worse than a debatable end state. `Universe.Digest`
-- hashes stored profile values, so a simulation replaying one seed would hash
-- differently run to run, and every replay-equality spec becomes flaky for reasons
-- nobody can reproduce.
--
-- What is NOT claimed here: that a listener cannot write during a rollback. It can,
-- and it should be able to -- listeners fire during the transaction's own writes
-- too, so anything they derive already holds the transaction's values, and a
-- rollback that stayed silent would leave that derived state stale forever. The
-- guarantee is that the outcome is fixed and reproducible.
return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	--- Roll back a transaction that wrote both fields, with `mirrorFrom` mirroring
	--- into `mirrorTo`, and report the final stored values.
	local function rollbackWith(fieldA: string, fieldB: string, mirrorFrom: string, mirrorTo: string)
		local template = {}
		template[fieldA] = Scribe.Int(0, { Min = 0 })
		template[fieldB] = Scribe.Int(0, { Min = 0 })
		local harness = TestCtx.make({ Template = template })
		local player = harness.Join()
		local data = harness.Data.Get(player)

		data[fieldA].Set(100)
		data[fieldB].Set(5)

		data[mirrorFrom].Changed(function(new)
			data[mirrorTo].Set(new + 1)
		end)

		harness.Data.Transaction(player, function()
			data[fieldA].Set(200)
			data[fieldB].Set(300)
			error("abort")
		end)

		local result = { [fieldA] = data[fieldA].Get(), [fieldB] = data[fieldB].Get() }
		harness.Cleanup()
		return result
	end

	describe("rolling back a transaction with a mirroring listener", function()
		it("lands on the same state every time", function()
			-- Ten runs of the identical program. Under hash-order restores this is
			-- exactly the shape that varied.
			local first = rollbackWith("Coins", "Gems", "Coins", "Gems")
			for _ = 1, 9 do
				local again = rollbackWith("Coins", "Gems", "Coins", "Gems")
				expect(`{again.Coins}/{again.Gems}`).to.equal(`{first.Coins}/{first.Gems}`)
			end
		end)

		it("does not change its answer because the fields were named differently", function()
			-- The measured symptom: Coins/Gems and Alpha/Zulu disagreed, purely
			-- because the names hashed into a different walk order. Same structure,
			-- same mirror direction, so the same relationship must hold.
			local coins = rollbackWith("Coins", "Gems", "Coins", "Gems")
			local alpha = rollbackWith("Alpha", "Zulu", "Alpha", "Zulu")
			expect(`{coins.Coins}/{coins.Gems}`).to.equal(`{alpha.Alpha}/{alpha.Zulu}`)
		end)

		it("tells listeners once, after the tree is whole, and lets their write land", function()
			-- The rule this pins, in one sentence: the rollback restores the tree, then
			-- tells the listeners, and whatever they do next is an ordinary
			-- post-rollback write.
			--
			-- So a mirror running Coins -> Gems leaves Gems at 101. That is not the
			-- pre-transaction value, and it is deliberate. The listener has ALREADY RUN
			-- during the transaction's own writes -- it fired its RemoteEvent, wrote its
			-- leaderboard row, sent its analytics event -- so erasing its tree write
			-- would leave the tree disagreeing with what the game already told the
			-- outside world. Undoing it also does not terminate in general: undoing the
			-- write re-fires the listener that made it.
			--
			-- What DID have to go was the listener reading a half-restored tree. Firing
			-- as each restore landed let a listener observe -- and persist a value
			-- derived from -- a state that never existed, and let it see containers the
			-- rollback was about to prune. The fires are queued for the duration and
			-- drained once every restore has landed.
			local r = rollbackWith("Coins", "Gems", "Coins", "Gems")
			expect(`{r.Coins}/{r.Gems}`).to.equal("100/101")
		end)
	end)
end
