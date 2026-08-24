--!nonstrict
-- A player who leaves while their profile is still loading has to be torn down.
--
-- `OnPlayerRemoving` skips the `Loading` state on the strength of one parenthesised
-- claim: "(Loading sessions abort via the StartSessionAsync Cancel guard.)" That
-- guard is real, and for the ordinary policy it is enough -- the Cancel hook sees
-- `player.Parent ~= Players`, the load aborts, and the entry is torn down.
--
-- Under `LoadFailurePolicy = "Wait"` it is not. The retry loop does not sit inside
-- `StartSessionAsync`; it sits in the BACKOFF between attempts, where no Cancel
-- hook exists to consult. So the entry survives the leave, the loop keeps asking
-- the DataStore for a player who has gone, and the teardown lands whenever the
-- backoff next happens to check -- up to a minute later.
--
-- The wasted requests self-heal. The rejoin does not: a player who comes back
-- inside the backoff gets a NEW entry, and then the OLD entry's late teardown runs
-- and broadcasts its Shared-root removal to every other client. The bystanders'
-- mirror of a live, Ready player is dropped, and nothing restores it for the rest
-- of the session.
--
-- Tearing down at the leave is what `docgen/guides/lifecycle.md` already describes,
-- so the only externally visible change is that `SessionEnded` fires when the
-- player leaves rather than up to a minute afterwards.
return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Clock = require(Root.Scribe.Internal.Clock)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	local function fastClock()
		Clock.Install({
			Wait = function()
				return task.wait()
			end,
			Delay = function(_seconds, fn, ...)
				return task.spawn(fn, ...)
			end,
		})
	end

	--- A Wait-policy harness whose loads fail, with a counter, and a switch to let
	--- loads start succeeding again (so a rejoin can reach Ready).
	local function makeHarness()
		local harness = TestCtx.make({
			Template = {
				Coins = Scribe.Int(0, { Min = 0 }),
				Pub = Scribe.Shared({ Title = "" }),
			},
			Options = { LoadFailurePolicy = "Wait" },
		})
		local realStart = harness.Ctx.Persistence.Store.StartSessionAsync
		local attempts = 0
		local failing = true
		harness.Ctx.Persistence.Store.StartSessionAsync = function(selfStore, key, params)
			attempts += 1
			if failing then
				if params and type(params.Cancel) == "function" then
					params.Cancel()
				end
				return nil
			end
			return realStart(selfStore, key, params)
		end
		return harness,
			{
				Attempts = function()
					return attempts
				end,
				StopFailing = function()
					failing = false
				end,
			}
	end

	local function frames(n)
		for _ = 1, n do
			task.wait()
		end
	end

	describe("a player who leaves while Loading", function()
		it("is torn down at once when the profile HAS loaded", function()
			-- THE CONTROL. The ordinary path, unchanged: a Ready player leaving is
			-- released through the final save.
			local harness = TestCtx.make({ Template = { Coins = Scribe.Int(0, { Min = 0 }) } })
			local player = harness.Join(910101)
			expect(harness.Ctx.Persistence.EntryFor(player)).to.be.ok()

			harness.Leave(player)
			expect(harness.Ctx.Persistence.EntryFor(player)).to.equal(nil)

			harness.Cleanup()
		end)

		it("is really parked in the backoff, so the measurement means something", function()
			-- THE CALIBRATION: without it, "the entry is gone" would also be satisfied
			-- by a load that never started.
			fastClock()
			local harness, ctl = makeHarness()
			local player = FakePlayer.new(910102)
			harness.Ctx.Persistence.OnPlayerAdded(player)
			frames(6)

			local entry = harness.Ctx.Persistence.EntryFor(player)
			expect(entry).to.be.ok()
			expect(entry.State).to.equal("Loading")
			expect(ctl.Attempts() > 1).to.equal(true)

			harness.Data.Stop()
			Clock.Reset()
			harness.Cleanup()
		end)

		it("does not survive OnPlayerRemoving", function()
			-- The defect, at its root: the entry outlives the player.
			fastClock()
			local harness = makeHarness()
			local player = FakePlayer.new(910103)
			harness.Ctx.Persistence.OnPlayerAdded(player)
			frames(6)
			expect(harness.Ctx.Persistence.EntryFor(player)).to.be.ok()

			FakePlayer.leave(player)
			harness.Ctx.Persistence.OnPlayerRemoving(player)

			expect(harness.Ctx.Persistence.EntryFor(player)).to.equal(nil)

			harness.Data.Stop()
			Clock.Reset()
			harness.Cleanup()
		end)

		it("fires SessionEnded at the leave rather than a backoff later", function()
			-- The externally visible half, and the one lifecycle.md already promises.
			fastClock()
			local harness = makeHarness()
			local ended = {}
			harness.Data.SessionEnded:Connect(function(_player, reason)
				table.insert(ended, reason)
			end)
			local player = FakePlayer.new(910104)
			harness.Ctx.Persistence.OnPlayerAdded(player)
			frames(6)
			expect(#ended).to.equal(0)

			FakePlayer.leave(player)
			harness.Ctx.Persistence.OnPlayerRemoving(player)

			expect(#ended).to.equal(1)
			expect(ended[1]).to.equal("player-left")

			harness.Data.Stop()
			Clock.Reset()
			harness.Cleanup()
		end)

		it("does not strand a REJOIN inside the backoff window", function()
			-- The consequence that does not self-heal. The old entry's late teardown
			-- broadcasts its Shared-root removal, and a bystander's mirror of the live,
			-- Ready player is dropped with nothing to restore it.
			fastClock()
			local harness, ctl = makeHarness()
			local player = FakePlayer.new(910105)
			harness.Ctx.Persistence.OnPlayerAdded(player)
			frames(6)
			local stale = harness.Ctx.Persistence.EntryFor(player)
			expect(stale).to.be.ok()

			-- They leave...
			FakePlayer.leave(player)
			harness.Ctx.Persistence.OnPlayerRemoving(player)

			-- ...and come straight back, into a store that now works.
			ctl.StopFailing()
			local rejoined = FakePlayer.new(910105)
			harness.Ctx.Persistence.OnPlayerAdded(rejoined)
			for _ = 1, 60 do
				local live = harness.Ctx.Persistence.EntryFor(rejoined)
				if live and live.State == "Ready" then
					break
				end
				task.wait()
			end
			local live = harness.Ctx.Persistence.EntryFor(rejoined)
			expect(live).to.be.ok()
			expect(live.State).to.equal("Ready")

			-- Let the old backoff run to wherever it was going.
			frames(20)

			-- The live session must still be the live session, with a live tree.
			local stillLive = harness.Ctx.Persistence.EntryFor(rejoined)
			expect(stillLive).to.equal(live)
			expect(stillLive.State).to.equal("Ready")
			expect(stillLive.Tree.Dead).to.equal(false)
			expect(harness.Ctx.Persistence.EntriesByUserId[910105]).to.equal(live)

			harness.Data.Stop()
			Clock.Reset()
			harness.Cleanup()
		end)
	end)
end
