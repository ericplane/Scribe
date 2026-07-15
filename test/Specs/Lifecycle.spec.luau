--!nonstrict
-- Profile lifecycle: load → mutate → flush → unload, with leak assertions
-- that internal maps end up empty.

return function()
	local Root = script.Parent.Parent.Parent
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local harness

	beforeEach(function()
		harness = TestCtx.make()
	end)

	afterEach(function()
		harness.Cleanup()
	end)

	it("loads a profile to Ready with reconciled template defaults", function()
		local player, entry, data = harness.Join()
		expect(harness.Ctx.Persistence.GetState(player)).to.equal("Ready")
		expect(data.Coins.Get()).to.equal(0)
		expect(data.Settings.Music.Get()).to.equal(true)
		expect(data.Secret.Flagged.Get()).to.equal(false)
		-- Reserved root reconciled.
		expect(entry.LiveData._Scribe).to.be.ok()
		expect(entry.LiveData._Scribe.Version).to.equal(1)
		-- Session store built separately, never inside profile data.
		expect(data.Runtime.InCombat.Get()).to.equal(false)
		expect(entry.LiveData.Runtime).to.equal(nil)
	end)

	it("persists mutations on flush", function()
		local player, entry, data = harness.Join()
		data.Coins.Set(50)
		data.Inventory.Sword.Set({ Dmg = 5 })
		expect(harness.Data.Flush(player)).to.equal(true)

		local persisted = harness.Fake.Persisted[`Default/PLAYER_{entry.UserId}`]
		expect(persisted).to.be.ok()
		expect(persisted.Coins).to.equal(50)
		expect(persisted.Inventory.Sword.Dmg).to.equal(5)

		local info = harness.Data.GetSaveInfo(player)
		expect(info.LastResult).to.equal("Ok")
		expect(info.Dirty).to.equal(false)
	end)

	it("never persists Session roots", function()
		local player, entry, data = harness.Join()
		data.Runtime.InCombat.Set(true)
		harness.Data.Flush(player)
		local persisted = harness.Fake.Persisted[`Default/PLAYER_{entry.UserId}`]
		expect(persisted.Runtime).to.equal(nil)
	end)

	it("reloads persisted data on a later session", function()
		local player, _entry, data = harness.Join(4242)
		data.Coins.Set(777)
		harness.Data.Flush(player)
		harness.Leave(player)

		local _, _, data2 = harness.Join(4242)
		expect(data2.Coins.Get()).to.equal(777)
	end)

	it("tears down fully on leave: dead tree, no listeners, empty maps", function()
		local player, entry, data = harness.Join()
		local fired = 0
		data.Coins.Observe(function()
			fired += 1
		end)
		expect(fired).to.equal(1)

		local tree = entry.Tree
		harness.Leave(player)

		-- Dead-tree writes throw with the documented message.
		expect(tree.Dead).to.equal(true)
		local ok, err = pcall(function()
			data.Coins.Set(1)
		end)
		expect(ok).to.equal(false)
		expect(string.find(tostring(err), "unloaded") ~= nil).to.equal(true)

		-- Listener/accessor maps cleared.
		expect(next(tree._listeners)).to.equal(nil)
		expect(next(tree._accessors)).to.equal(nil)
	end)

	it("leaks nothing across many load/unload cycles", function()
		for _ = 1, 5 do
			local player = harness.Join()
			local data = harness.Data.Get(player)
			data.Coins.Increment(10)
			harness.Leave(player)
		end
		expect(next(harness.Ctx.Persistence.Entries)).to.equal(nil)
		expect(next(harness.Fake.ActiveProfiles)).to.equal(nil)
	end)

	it("fires SessionEnded before teardown completes, with the reason", function()
		local player = harness.Join()
		local seenReason = nil
		harness.Ctx.Signals.SessionEnded:Connect(function(endedPlayer, reason)
			if endedPlayer == player then
				seenReason = reason
			end
		end)
		harness.Leave(player)
		task.wait() -- signal handlers run on their own threads
		expect(seenReason).to.equal("left")
		expect(harness.Ctx.Persistence.GetState(player)).to.equal("SessionEnded")
	end)

	it("fails closed when the profile cannot load (Kick policy)", function()
		harness.Fake.FailNextLoad = true
		local FakePlayer = require(Root.Test.Helpers.FakePlayer)
		local player = FakePlayer.new()
		harness.Ctx.Persistence.OnPlayerAdded(player)
		local data, reason = harness.Ctx.Persistence.WaitForData(player)
		expect(data).to.equal(nil)
		expect(reason).to.equal("load-failed")
		expect(player.Kicked).to.be.ok()
	end)

	it("Data.WaitForData returns the accessor once Ready", function()
		local player = harness.Join()
		local data, reason = harness.Data.WaitForData(player)
		expect(data).to.be.ok()
		expect(reason).to.equal(nil)
		expect(data.Coins.Get()).to.equal(0)
	end)

	it("rejects non-persistable value types at the write site", function()
		local _, _, data = harness.Join()
		expect(function()
			data.Inventory.Fn.Set(function() end)
		end).to.throw()
		expect(data.Inventory.Count()).to.equal(0)
		expect(function()
			TestCtx.make({ Template = { Fn = function() end } })
		end).to.throw()
	end)

	it("stores, copies, and persists buffer fields", function()
		local template = TestCtx.defaultTemplate()
		template.Packed = buffer.fromstring("\0\1\2")
		local bufferHarness = TestCtx.make({ Template = template })

		local player, entry, data = bufferHarness.Join(4300)
		expect(buffer.tostring(data.Packed.Get())).to.equal("\0\1\2")

		-- Writes snapshot the buffer: mutating the caller's copy afterwards
		-- must not leak into stored data.
		local written = buffer.fromstring("ABCD")
		data.Packed.Set(written)
		buffer.writeu8(written, 0, 88)
		expect(buffer.tostring(data.Packed.Get())).to.equal("ABCD")

		-- Re-Setting a mutated buffer counts as a change (buffers never
		-- compare equal by content).
		local changes = 0
		data.Packed.Changed(function()
			changes += 1
		end)
		local live = data.Packed.Clone()
		buffer.writeu8(live, 0, 69) -- "E"
		data.Packed.Set(live)
		expect(changes).to.equal(1)

		-- Dynamic dictionary paths accept buffers too.
		data.Inventory.Chunk.Set(buffer.fromstring("chunk"))

		-- Persistence round-trips content without aliasing live data.
		expect(bufferHarness.Data.Flush(player)).to.equal(true)
		local persisted = bufferHarness.Fake.Persisted[`Default/PLAYER_4300`]
		expect(buffer.tostring(persisted.Packed)).to.equal("EBCD")
		expect(persisted.Packed == entry.LiveData.Packed).to.equal(false)
		expect(buffer.tostring(persisted.Inventory.Chunk)).to.equal("chunk")

		-- A later session reloads the same bytes.
		bufferHarness.Leave(player)
		local player2, _, data2 = bufferHarness.Join(4300)
		expect(buffer.tostring(data2.Packed.Get())).to.equal("EBCD")

		-- GDPR export base64-encodes buffer fields into valid JSON.
		local exported = bufferHarness.Data.Export(4300)
		expect(type(exported)).to.equal("string")
		expect(string.find(exported, "base64:", 1, true) ~= nil).to.equal(true)
		local _ = player2

		bufferHarness.Cleanup()
	end)

	it("supports Batch and Transaction semantics", function()
		local player, _, data = harness.Join()

		harness.Data.Batch(player, function()
			data.Coins.Set(1)
			harness.Data.Batch(player, function()
				data.Gems.Set(2) -- nested batch coalesces to the outermost
			end)
			data.Coins.Set(3)
		end)
		expect(data.Coins.Get()).to.equal(3)
		expect(data.Gems.Get()).to.equal(2)

		local ok, err = harness.Data.Transaction(player, function()
			data.Coins.Set(100)
			data.Quests.Insert("q1")
			error("boom")
		end)
		expect(ok).to.equal(false)
		expect(string.find(tostring(err), "boom") ~= nil).to.equal(true)
		-- Full rollback of every touched field.
		expect(data.Coins.Get()).to.equal(3)
		expect(data.Quests.Count()).to.equal(0)

		-- Transactions do not nest.
		harness.Data.Transaction(player, function()
			expect(function()
				harness.Data.Transaction(player, function() end)
			end).to.throw()
		end)
	end)
end
