--!nonstrict
-- F5's CONSEQUENCE SPEC: Data.OnMessage acknowledges only what a handler observed.
--
-- The user-message arm of the cross-server drain used to read
--     ctx.Signals.OnMessage:Fire(entry.Player, message.Data)
--     processed()
-- with nothing between the two lines. `Fire` is fire-and-forget: it returns at the
-- handler's first yield, returns identically when NO handler is connected, and lets
-- a raised error go to the scheduler. So `processed()` retired the message in three
-- cases where nothing had happened.
--
-- THE RULE, which the gift arm and the GlobalUpdates sweep already follow: a message
-- is retired only in the same write that persists the data reflecting it.
-- `processed()` is not durability -- it flags locked_global_updates, and ProfileStore
-- removes the update inside the SAME UpdateAsync that writes profile.Data. Flagging
-- it once a handler has RETURNED is exactly that rule: whatever the handler wrote is
-- in profile.Data before any save can retire the message, and a failed save retires
-- nothing.
--
-- WHAT WAS CHOSEN FOR EACH ARM, AND WHY
--   (a) NO LISTENER  -> withhold the ack, log MESSAGE_NO_LISTENER. Almost always a
--       startup race, where the profile loads before the game binds its handler.
--       Holding costs a redelivery; dropping costs the message, and is silent and
--       irreversible. A game that NEVER connects gets a visible, bounded failure --
--       the queue climbs to its 1,000 cap and senders start getting `false` with
--       MESSAGE_QUEUE_FULL -- instead of silent loss.
--   (b) HANDLER RAISED -> withhold the ack, log MESSAGE_HANDLER_ERROR. Identical
--       reasoning: nothing observed the message. FireTracked pcalls the listener, so
--       the error no longer reaches the scheduler and this log is the only place it
--       can surface.
--   (c) HANDLER WROTE, SAVE FAILED -> the value-destroying one, and it has two
--       halves. This file owns the ORDERING half: the ack is never spent before the
--       write exists, so no save can carry the retirement without the data. The
--       "same UpdateAsync" half is ProfileStore's own sweep gate and is pinned by
--       ReleaseOnlyMessages.spec, which must stay green; this fake deletes a
--       consumed message outright and so cannot measure it.
--
-- THE CONTRACT CHANGE THIS MAKES, stated because it is one: Data.OnMessage is now
-- at-least-once. Payloads carry no id, so a redelivered message is handed to the
-- game again and handlers must be idempotent. It is documented on
-- Server.OnMessage, Server.SendMessage and in the lifecycle guide. Redelivery is
-- bounded -- ProfileStore offers each update to the handlers once per SESSION
-- (received_global_updates), not once per save.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local SENDER = 93001
	local RECIPIENT = 93002

	local function makeHarness()
		return TestCtx.make({
			Template = { Coins = Scribe.Int(0, { Min = 0, Max = 1000000 }) },
		})
	end

	local function mailboxLen(harness, userId: number): number
		local mailbox = harness.Fake.Mailboxes["Default/" .. harness.Ctx.Persistence.KeyFor(userId)]
		return if mailbox then #mailbox else 0
	end

	local function persistedCoins(harness, userId: number): number
		local stored = harness.Fake.Persisted["Default/" .. harness.Ctx.Persistence.KeyFor(userId)]
		return if stored then tonumber(stored.Coins) or -1 else -1
	end

	local function codeCounter()
		local seen = {}
		local unsubscribe = Scribe.AddLogSink(function(logEntry)
			seen[logEntry.Code] = (seen[logEntry.Code] or 0) + 1
			if logEntry.Code == "MESSAGE_HANDLER_ERROR" then
				seen._error = tostring(logEntry.Message)
			end
		end)
		return seen, unsubscribe
	end

	--------------------------------------------------------------------------------
	-- ARM (a): nothing is connected
	--------------------------------------------------------------------------------

	it("keeps a message that no listener was there to observe, and says so", function()
		local seen, unsubscribe = codeCounter()
		local harness = makeHarness()
		local sender = harness.Join(SENDER)
		local recipient, _entry, data = harness.Join(RECIPIENT)
		expect(sender).to.be.ok()

		expect(harness.Data.SendMessage(RECIPIENT, { Amount = 50 })).to.equal(true)
		harness.Data.Flush(recipient)
		task.wait()

		expect(
			("queued=%d coins=%d noListener=%d"):format(
				mailboxLen(harness, RECIPIENT),
				data.Coins.Get(),
				seen.MESSAGE_NO_LISTENER or 0
			)
		).to.equal("queued=1 coins=0 noListener=1")

		-- ...and the redelivery is not theoretical: connect a handler and the very
		-- next drain hands it the same message, applies it, and retires it. Forced,
		-- because a clean profile has nothing to save and so would never drain.
		harness.Data.OnMessage:Connect(function(_player, message)
			data.Coins.Increment(message.Amount)
		end)
		harness.Data.Flush(recipient, { Force = true })
		task.wait()
		unsubscribe()

		expect(("queued=%d coins=%d"):format(mailboxLen(harness, RECIPIENT), data.Coins.Get())).to.equal(
			"queued=0 coins=50"
		)

		-- The credit reaches storage on the save after the one that drained it: this
		-- fake reads its serialization source before draining, where real ProfileStore
		-- runs the handlers after the UpdateAsync and sweeps on the next one.
		harness.Data.Flush(recipient)
		task.wait()
		expect(persistedCoins(harness, RECIPIENT)).to.equal(50)

		harness.Cleanup()
	end)

	--------------------------------------------------------------------------------
	-- ARM (b): the handler raised
	--------------------------------------------------------------------------------

	it("keeps a message whose handler raised, and surfaces the error it swallowed", function()
		-- FireTracked pcalls the listener, so nothing reaches the scheduler any more.
		-- If this log went away the error would be invisible AND the message would be
		-- stuck, which is the worst of both.
		local seen, unsubscribe = codeCounter()
		local harness = makeHarness()
		local recipient, _entry, data = harness.Join(RECIPIENT)

		local reached = 0
		harness.Data.OnMessage:Connect(function()
			reached += 1
			error("handler blew up before writing the credit")
		end)

		expect(harness.Data.SendMessage(RECIPIENT, { Amount = 50 })).to.equal(true)
		harness.Data.Flush(recipient)
		task.wait()
		unsubscribe()

		expect(
			("reached=%d queued=%d coins=%d errors=%d text=%s"):format(
				reached,
				mailboxLen(harness, RECIPIENT),
				data.Coins.Get(),
				seen.MESSAGE_HANDLER_ERROR or 0,
				tostring(string.find(seen._error or "", "blew up", 1, true) ~= nil)
			)
		).to.equal("reached=1 queued=1 coins=0 errors=1 text=true")

		harness.Cleanup()
	end)

	it("withholds the ack when ANY of several listeners raises, and still runs them all", function()
		-- At-least-once is per message, not per listener: redelivering re-runs the one
		-- that succeeded too. That is the cost of the trade and the reason the
		-- docstrings tell games to make handlers idempotent.
		local harness = makeHarness()
		local recipient, _entry, data = harness.Join(RECIPIENT)

		local good = 0
		harness.Data.OnMessage:Connect(function()
			good += 1
		end)
		harness.Data.OnMessage:Connect(function()
			error("second listener is broken")
		end)

		expect(harness.Data.SendMessage(RECIPIENT, { Amount = 50 })).to.equal(true)
		harness.Data.Flush(recipient)
		task.wait()

		expect(("good=%d queued=%d coins=%d"):format(good, mailboxLen(harness, RECIPIENT), data.Coins.Get())).to.equal(
			"good=1 queued=1 coins=0"
		)

		harness.Cleanup()
	end)

	--------------------------------------------------------------------------------
	-- ARM (c): the write and the retirement travel together
	--------------------------------------------------------------------------------

	it("never retires a message before the write it produces exists", function()
		-- THE VALUE-DESTROYING ARM. A handler that yields before writing used to have
		-- its message acked while the write did not exist: the next save then persisted
		-- Data without the write AND retired the message that would have replayed it,
		-- leaving only this server's RAM holding the pair together.
		--
		-- What is asserted is the DURABLE record at each step: after the save that runs
		-- while the handler is parked, storage shows neither the write nor the
		-- retirement. Once the handler has finished, the next save carries both.
		local harness = makeHarness()
		local recipient, _entry, data = harness.Join(RECIPIENT)

		local parked, applied, stage = nil, false, "none"
		harness.Data.OnMessage:Connect(function(_player, message)
			if applied then
				return -- idempotent, exactly as the at-least-once contract asks
			end
			if parked == nil then
				stage = "started"
				parked = coroutine.running()
				coroutine.yield()
			end
			applied = true
			data.Coins.Increment(message.Amount)
			stage = "wrote"
		end)

		expect(harness.Data.SendMessage(RECIPIENT, { Amount = 50 })).to.equal(true)
		harness.Data.Flush(recipient)
		task.wait()

		expect(
			("stage=%s queued=%d persisted=%d"):format(
				stage,
				mailboxLen(harness, RECIPIENT),
				persistedCoins(harness, RECIPIENT)
			)
		).to.equal("stage=started queued=1 persisted=0")

		task.spawn(parked)
		task.wait()

		-- The write exists in memory now, and the message is still on the key -- so
		-- nothing has been retired against a profile that does not reflect it.
		expect(
			("stage=%s queued=%d coins=%d persisted=%d"):format(
				stage,
				mailboxLen(harness, RECIPIENT),
				data.Coins.Get(),
				persistedCoins(harness, RECIPIENT)
			)
		).to.equal("stage=wrote queued=1 coins=50 persisted=0")

		harness.Data.Flush(recipient)
		task.wait()

		expect(("queued=%d persisted=%d"):format(mailboxLen(harness, RECIPIENT), persistedCoins(harness, RECIPIENT))).to.equal(
			"queued=0 persisted=50"
		)

		harness.Cleanup()
	end)

	it("still acks in the same drain when the handler writes without yielding", function()
		-- THE CONTROL. Without it, "the message survives" is equally well explained by
		-- an ack that never happens at all, and the fix would have traded a silent loss
		-- for a permanently jammed queue.
		local harness = makeHarness()
		local recipient, _entry, data = harness.Join(RECIPIENT)

		local stage = "none"
		harness.Data.OnMessage:Connect(function(_player, message)
			data.Coins.Increment(message.Amount)
			stage = "wrote"
		end)

		expect(harness.Data.SendMessage(RECIPIENT, { Amount = 50 })).to.equal(true)
		harness.Data.Flush(recipient)
		task.wait()

		expect(("stage=%s queued=%d coins=%d"):format(stage, mailboxLen(harness, RECIPIENT), data.Coins.Get())).to.equal(
			"stage=wrote queued=0 coins=50"
		)

		-- Same one-save lag as above, and for the same fake-only reason.
		harness.Data.Flush(recipient)
		task.wait()
		expect(persistedCoins(harness, RECIPIENT)).to.equal(50)

		harness.Cleanup()
	end)

	--------------------------------------------------------------------------------
	-- The two things the arm above it must keep doing
	--------------------------------------------------------------------------------

	it("never fires OnMessage for a payload that is not tagged, and never acks one", function()
		-- The tag is what keeps gift delivery and user messages from colliding. An
		-- untagged payload belongs to neither arm, so it is left on the key rather than
		-- consumed -- unchanged by F5, and asserted here because the ack is now
		-- conditional and a mis-shaped condition could start acking strays.
		local harness = makeHarness()
		local recipient = harness.Join(RECIPIENT)

		local fires = 0
		harness.Data.OnMessage:Connect(function()
			fires += 1
		end)

		harness.Ctx.Persistence.Store:MessageAsync(
			harness.Ctx.Persistence.KeyFor(RECIPIENT),
			{ SomethingElse = true, Data = { Amount = 50 } }
		)
		harness.Data.Flush(recipient)
		task.wait()

		expect(("fires=%d queued=%d"):format(fires, mailboxLen(harness, RECIPIENT))).to.equal("fires=0 queued=1")

		harness.Cleanup()
	end)

	it("keeps the user arm reachable when the monetization arm above it declines a payload", function()
		-- The monetization arm runs FIRST and UNPROTECTED -- no pcall around
		-- OnProfileMessage -- so it has to stay a non-throwing early return for
		-- anything it does not own. If it ever raised, the user arm below would become
		-- unreachable and every Data.SendMessage message would be silently redelivered
		-- forever. A payload tagged BOTH ways, naming a product that is not registered,
		-- is the cheapest way to walk it into the gift arm's own error path.
		local harness = makeHarness()
		local recipient, _entry, data = harness.Join(RECIPIENT)

		local fires = 0
		harness.Data.OnMessage:Connect(function(_player, message)
			fires += 1
			data.Coins.Increment(message.Amount)
		end)

		harness.Ctx.Persistence.Store:MessageAsync(harness.Ctx.Persistence.KeyFor(RECIPIENT), {
			ScribeGift = true,
			ScribeMessage = true,
			Product = "NotARegisteredProduct",
			PurchaseId = "both-arms-1",
			GiftId = "gift-both-arms",
			FromUserId = SENDER,
			Data = { Amount = 50 },
		})
		harness.Data.Flush(recipient)
		task.wait()

		expect(("fires=%d queued=%d coins=%d"):format(fires, mailboxLen(harness, RECIPIENT), data.Coins.Get())).to.equal(
			"fires=1 queued=0 coins=50"
		)

		harness.Cleanup()
	end)
end
