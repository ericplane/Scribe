--!nonstrict
-- Wipe guard: vanished top-level keys or a collapsed payload trip it; Warn
-- logs and proceeds, Block persists the last good snapshot until forced.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local function bigTemplate()
		local template = TestCtx.defaultTemplate()
		template.Blob = string.rep("x", 4096)
		return template
	end

	local function anomalyRecorder(harness)
		local anomalies = {}
		harness.Ctx.Signals.OnAnomaly:Connect(function(info)
			if string.find(tostring(info.Reason), "WipeGuard") then
				table.insert(anomalies, info)
			end
		end)
		return anomalies
	end

	it("Warn policy: logs, fires OnAnomaly, and lets the save proceed", function()
		local harness = TestCtx.make({ Template = bigTemplate() })
		local player, entry, data = harness.Join()
		local key = `Default/PLAYER_{entry.UserId}`
		local anomalies = anomalyRecorder(harness)

		data.Coins.Set(10)
		expect(harness.Data.Flush(player)).to.equal(true) -- healthy baseline

		-- A top-level key vanishes.
		data.Nick.Set(nil)
		expect(harness.Data.Flush(player)).to.equal(true)
		task.wait()

		expect(#anomalies).to.equal(1)
		expect(#Scribe.GetRecentLogs({ Code = "WIPE_GUARD_TRIPPED", Limit = 3 }) > 0).to.equal(true)
		-- Warn: resets are legitimate; the save went through.
		expect(harness.Fake.Persisted[key].Nick).to.equal(nil)

		harness.Cleanup()
	end)

	it("Block policy: persists the last good snapshot until forced", function()
		local harness = TestCtx.make({
			Template = bigTemplate(),
			Options = { WipeGuardPolicy = "Block" },
		})
		local player, entry, data = harness.Join()
		local key = `Default/PLAYER_{entry.UserId}`
		local anomalies = anomalyRecorder(harness)

		data.Coins.Set(77)
		expect(harness.Data.Flush(player)).to.equal(true) -- baseline: Coins=77, Nick=""

		data.Nick.Set(nil) -- looks like a wipe
		data.Coins.Set(99) -- a legitimate concurrent change

		expect(harness.Data.Flush(player)).to.equal(true)
		task.wait()
		expect(#anomalies).to.equal(1)

		-- The blocked save persisted the LAST GOOD snapshot, not the wipe.
		local persisted = harness.Fake.Persisted[key]
		expect(persisted.Nick).to.equal("")
		expect(persisted.Coins).to.equal(77)
		-- Live data is untouched; the session stays alive.
		expect(data.Coins.Get()).to.equal(99)
		expect(harness.Ctx.Persistence.GetState(player)).to.equal("Ready")
		-- The player's save info shows unsaved changes.
		expect(harness.Data.GetSaveInfo(player).Dirty).to.equal(true)

		-- Force-flush pushes the live data through.
		expect(harness.Data.Flush(player, { Force = true })).to.equal(true)
		persisted = harness.Fake.Persisted[key]
		expect(persisted.Nick).to.equal(nil)
		expect(persisted.Coins).to.equal(99)
		expect(harness.Data.GetSaveInfo(player).Dirty).to.equal(false)

		harness.Cleanup()
	end)

	it("Block policy clears itself once the data passes the guard again", function()
		local harness = TestCtx.make({
			Template = bigTemplate(),
			Options = { WipeGuardPolicy = "Block" },
		})
		local player, entry, data = harness.Join()
		local key = `Default/PLAYER_{entry.UserId}`

		harness.Data.Flush(player) -- baseline
		data.Nick.Set(nil)
		harness.Data.Flush(player) -- tripped + blocked
		expect(harness.Fake.Persisted[key].Nick).to.equal("")

		data.Nick.Set("back") -- the key returns; guard passes
		harness.Data.Flush(player)
		expect(harness.Fake.Persisted[key].Nick).to.equal("back")
		expect(#Scribe.GetRecentLogs({ Code = "WIPE_GUARD_CLEARED", Limit = 3 }) > 0).to.equal(true)

		harness.Cleanup()
	end)

	it("trips on a collapsed serialized size", function()
		local harness = TestCtx.make({ Template = bigTemplate() })
		local player, _, data = harness.Join()
		local anomalies = anomalyRecorder(harness)

		harness.Data.Flush(player) -- baseline includes the 4 KB blob
		data.Blob.Set("tiny")
		harness.Data.Flush(player)
		task.wait()

		expect(#anomalies).to.equal(1)
		expect(#Scribe.GetRecentLogs({ Code = "WIPE_GUARD_TRIPPED", Limit = 3 }) > 0).to.equal(true)

		harness.Cleanup()
	end)
end
