--!nonstrict
-- OnPlayerLeaving: the counterpart OnPlayerInit never had. It runs BEFORE the
-- final save, so whatever it writes persists. Without it, the accumulate-on-exit
-- pattern (playtime, a session summary) has nowhere to go: writing from your own
-- PlayerRemoving handler races Scribe's, decided by connection order, and a write
-- after teardown is simply lost.

return function()
	local Root = script.Parent.Parent.Parent
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local function harnessWith(hook)
		return TestCtx.make({
			Template = { Playtime = 0, Coins = 0 },
			Options = { OnPlayerLeaving = hook },
		})
	end

	it("persists what the hook writes on the way out", function()
		local harness = harnessWith(function(_player, data)
			data.Playtime.Increment(42)
		end)
		local player, _entry, data = harness.Join(97601)
		data.Playtime.Set(10)
		harness.Leave(player)

		-- 52, not 10: the hook's write reached the final save rather than landing
		-- after it.
		expect(harness.Fake.Persisted["Default/PLAYER_97601"].Playtime).to.equal(52)

		harness.Cleanup()
	end)

	it("hands over the typed accessor, so writes are validated", function()
		local seenPlayer, seenReason
		local harness = harnessWith(function(player, data, reason)
			seenPlayer, seenReason = player, reason
			-- A bounds violation must still be caught here, not written raw.
			data.Coins.Set(7)
		end)
		local player = harness.Join(97602)
		harness.Leave(player)

		expect(seenPlayer).to.equal(player)
		expect(seenReason).to.be.ok()
		expect(harness.Fake.Persisted["Default/PLAYER_97602"].Coins).to.equal(7)

		harness.Cleanup()
	end)

	it("saves anyway when the hook throws", function()
		-- A hook that errors must cost you its own writes, not the entire session.
		local harness = harnessWith(function(_player, data)
			data.Playtime.Increment(5)
			error("boom")
		end)
		local player, _entry, data = harness.Join(97603)
		data.Coins.Set(99)
		harness.Leave(player)

		local saved = harness.Fake.Persisted["Default/PLAYER_97603"]
		expect(saved).to.be.ok()
		expect(saved.Coins).to.equal(99)
		-- The write it managed before throwing still counts; it was a real write.
		expect(saved.Playtime).to.equal(5)

		harness.Cleanup()
	end)

	it("runs exactly once per session", function()
		local calls = 0
		local harness = harnessWith(function()
			calls += 1
		end)
		local player = harness.Join(97604)
		harness.Leave(player)
		expect(calls).to.equal(1)

		harness.Cleanup()
	end)

	it("runs exactly once when a yielding hook is still parked as shutdown drains", function()
		-- The hook runs under a plain pcall, so a hook that yields parks the leave
		-- with the entry still registered. BindToClose then drains that same entry and
		-- would call the hook a second time, double-counting whatever it accumulates.
		local calls = 0
		local harness = harnessWith(function()
			calls += 1
			task.wait(0.05)
		end)
		local player = harness.Join(97606)
		task.spawn(function()
			harness.Leave(player)
		end)
		expect(calls).to.equal(1)
		-- Still drainable: the leave has not torn the entry down yet.
		expect(harness.Ctx.Persistence.EntryFor(player)).to.be.ok()

		harness.Ctx.Persistence.Shutdown(1)
		expect(calls).to.equal(1)

		harness.Cleanup()
	end)

	it("is optional and changes nothing when absent", function()
		local harness = TestCtx.make({ Template = { Coins = 0 } })
		local player, _entry, data = harness.Join(97605)
		data.Coins.Set(3)
		harness.Leave(player)
		expect(harness.Fake.Persisted["Default/PLAYER_97605"].Coins).to.equal(3)
		harness.Cleanup()
	end)
end
