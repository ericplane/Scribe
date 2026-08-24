--!nonstrict
-- What is actually wired when WaitForData hands you the session.
--
-- The documented path is PlayerAdded -> WaitForData -> read. WaitForData parks on
-- the entry's state signal, and the state becomes "Ready" partway through the load:
-- the cross-server message handler, the monetization ownership refresh, the initial
-- leaderboard score and the replication hookup all happen on the lines AFTER it.
-- Signals dispatch synchronously and a resume runs on the caller's stack, so the
-- parked thread used to come back from inside setState -- ahead of all of them.
--
-- The suite could not see this. A load only parks a waiter if it yields, and the
-- fake store returns without yielding, so every spec took the "already Ready" branch
-- and never exercised a resume at all. Production yields on every join.
--
-- What the fix buys is bounded and worth stating: deferring the wake takes it out of
-- setState's stack, so the synchronous remainder of the load completes first. It is
-- not a "fully wired" barrier -- the monetization hook spawns an ownership refresh
-- that yields on purpose, and a deferred wake can land in that gap.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	--- Join the way the guides tell a game to, with a load that really parks the
	--- waiter, and report what was wired at the instant WaitForData returned.
	local function joinAndInspect(harness, userId: number)
		harness.Fake.YieldOnSessionStart = true
		local player = FakePlayer.new(userId)
		harness.Ctx.Persistence.OnPlayerAdded(player)

		local seen = nil
		task.spawn(function()
			harness.Ctx.Persistence.WaitForData(player)
			local entry = harness.Ctx.Persistence.EntryFor(player)
			seen = {
				State = entry.State,
				-- Registered at Persistence's `profile:MessageHandler(...)`, which is
				-- what makes a gift sent from another server land rather than sit in
				-- the mailbox until the next save.
				Handlers = entry.Profile.HandlerCount or 0,
				-- Deliberately NOT asserted on: Leaderboards.OnLoad runs after the
				-- monetization hook, which spawns an ownership refresh that yields by
				-- design. A deferred wake is one resumption point, not a barrier, so
				-- nothing past the first yielding hook is part of the guarantee.
				Queued = Scribe.GetMetrics().LbQueueDepth or 0,
			}
		end)
		for _ = 1, 200 do
			if seen ~= nil then
				break
			end
			task.wait()
		end
		return player, seen
	end

	it("has finished wiring the session before WaitForData returns", function()
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = { Leaderboards = { TopCoins = { Stat = "Coins", Limit = 10 } } },
		})
		local player, seen = joinAndInspect(harness, 97901)

		expect(`resumed={seen ~= nil}`).to.equal("resumed=true")
		-- The claim, stated exactly: the wake can no longer preempt the synchronous
		-- tail of the load. A handler count of zero here means the waiter came back
		-- from inside setState, with finishLoad still on the stack below it.
		expect(`state={seen.State} handlers={seen.Handlers > 0}`).to.equal("state=Ready handlers=true")

		harness.Ctx.Persistence.OnPlayerRemoving(player)
		harness.Cleanup()
	end)

	it("still answers a waiter promptly when the load never parks it", function()
		-- The control arm. Nothing above may be bought by making the common case --
		-- a store that answers without yielding -- take a scheduler turn it did not
		-- need, or every spec in the suite pays for it.
		local harness = TestCtx.make({ Template = { Coins = Scribe.Int(0, { Min = 0 }) } })
		local player, _entry, data = harness.Join(97902)
		expect(`coins={data.Coins.Get()}`).to.equal("coins=0")
		expect(`state={harness.Ctx.Persistence.EntryFor(player).State}`).to.equal("state=Ready")
		harness.Cleanup()
	end)
end
