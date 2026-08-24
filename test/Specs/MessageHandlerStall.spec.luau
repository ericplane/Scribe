--!nonstrict
-- O2's CONSEQUENCE SPEC: an unacknowledged cross-server message is never SILENT.
--
-- WHAT F5 LEFT BEHIND. F5 made the drain acknowledge only what a handler actually
-- observed, and gave two of the three "did not observe" outcomes a voice:
-- MESSAGE_NO_LISTENER when nothing was connected, MESSAGE_HANDLER_ERROR when a
-- handler raised. It missed the third, because it is the one where onSettled never
-- runs at all: a handler that YIELDS AND NEVER RETURNS. FireTracked settles on the
-- LAST handler (pinned by FireTracked.spec), so a single parked handler holds the
-- fire open forever. Measured, two listeners with one parked:
--     good=1 remaining=1 codes=[]
-- No log, no metric, no Health signal -- and the message is re-offered on every
-- subsequent load FOREVER, climbing toward the 1,000-update cap and
-- MESSAGE_QUEUE_FULL with nothing in any sink to explain it. Under the old
-- unconditional ack this was at least loud in a different way (the message was
-- destroyed, but the write was visibly missing).
--
-- WITHHOLDING THE ACK IS CORRECT and is NOT what changes here. The message genuinely
-- was not handled; acknowledging anyway would reopen F5 and destroy it. The defect is
-- purely that the outcome is invisible.
--
-- THE SHAPE CHOSEN, and why it is not a timeout. A timeout has to name a duration,
-- and no duration is right: a handler doing a legitimate DataStore round trip under
-- throttle is slow, not stuck, so any threshold either fires on healthy handlers or
-- sits far enough out to be useless -- and to be testable at all it would have to
-- become a public option, widening the configuration surface for a diagnostic.
-- SESSION END needs no threshold and no timer, because it is the moment the fact
-- stops being provisional: this server will never acknowledge that message, so it
-- WILL be redelivered on the next load. The diagnostic therefore lands strictly
-- BEFORE the consequence recurs, which is the only ordering that matters.
--
-- It is a WARN, matching MESSAGE_NO_LISTENER rather than MESSAGE_HANDLER_ERROR,
-- because it spans the same benign-to-fatal range: a player leaving while a handler
-- is legitimately mid-yield reads identically to a handler parked forever. The code
-- states a FACT ("not acknowledged at session end; it will be redelivered") rather
-- than an accusation, and repetition across sessions is what distinguishes the two.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local RECIPIENT = 94002

	local function makeHarness()
		return TestCtx.make({
			Template = { Coins = Scribe.Int(0, { Min = 0, Max = 1000000 }) },
		})
	end

	local function mailboxLen(harness, userId: number): number
		local mailbox = harness.Fake.Mailboxes["Default/" .. harness.Ctx.Persistence.KeyFor(userId)]
		return if mailbox then #mailbox else 0
	end

	local function codeCounter()
		local seen = { _outstanding = -1 }
		local unsubscribe = Scribe.AddLogSink(function(logEntry)
			seen[logEntry.Code] = (seen[logEntry.Code] or 0) + 1
			if logEntry.Code == "MESSAGE_HANDLER_STALLED" then
				seen._outstanding = tonumber(logEntry.Context and logEntry.Context.Outstanding) or -1
			end
		end)
		return seen, unsubscribe
	end

	--- A listener that parks at its first call and never returns, exactly like a
	--- handler awaiting something that never arrives.
	local function parkForever(harness)
		local parked = false
		local connection = harness.Data.OnMessage:Connect(function()
			parked = true
			coroutine.yield()
		end)
		return function(): boolean
			return parked
		end, function()
			connection:Disconnect()
		end
	end

	it("stays quiet while the session runs, then reports the stall when it ends", function()
		-- THE CONSEQUENCE. Nothing is said DURING the session -- the handler may still
		-- return, and a diagnostic then would be a guess. At session end it is a fact.
		local seen, unsubscribe = codeCounter()
		local harness = makeHarness()
		local recipient, _entry, data = harness.Join(RECIPIENT)

		local good = 0
		local didPark = parkForever(harness)
		harness.Data.OnMessage:Connect(function()
			good += 1
		end)

		expect(harness.Data.SendMessage(RECIPIENT, { Amount = 50 })).to.equal(true)
		harness.Data.Flush(recipient)
		task.wait()

		local during = ("good=%d parked=%s queued=%d coins=%d stalled=%d"):format(
			good,
			tostring(didPark()),
			mailboxLen(harness, RECIPIENT),
			data.Coins.Get(),
			seen.MESSAGE_HANDLER_STALLED or 0
		)

		harness.Leave(recipient)
		task.wait()
		unsubscribe()

		-- One line, once, naming how many deliveries were still open at the moment the
		-- session ended. `good` is read again afterwards to anchor that number: the
		-- final save re-offers the still-unacknowledged message (good goes to 2), but
		-- that offer lands AFTER teardown has already reported, so it is not counted
		-- twice -- it is the same message, and it has already been named.
		expect(
			("%s || good=%d logs=%d outstanding=%d queued=%d"):format(
				during,
				good,
				seen.MESSAGE_HANDLER_STALLED or 0,
				seen._outstanding,
				mailboxLen(harness, RECIPIENT)
			)
		).to.equal("good=1 parked=true queued=1 coins=0 stalled=0 || good=2 logs=1 outstanding=1 queued=1")

		harness.Cleanup()
	end)

	it("does not acknowledge the message anyway -- the diagnostic is the whole change", function()
		-- THE GUARD AGAINST REOPENING F5. Reporting the stall must not become an
		-- excuse to retire the message: it is still on the recipient's key afterwards,
		-- and a session that CAN handle it still gets it and still applies it.
		local harness = makeHarness()
		local recipient = harness.Join(RECIPIENT)
		local _didPark, unpark = parkForever(harness)

		expect(harness.Data.SendMessage(RECIPIENT, { Amount = 50 })).to.equal(true)
		harness.Data.Flush(recipient)
		task.wait()
		harness.Leave(recipient)
		task.wait()

		local survived = mailboxLen(harness, RECIPIENT)

		-- A fresh session with a working handler drains it, proving the message really
		-- was still there rather than merely counted. The stuck listener is a
		-- server-lifetime connection, so it is removed first -- otherwise it would
		-- park on the redelivery too and hold the new session's ack open as well,
		-- which is correct behaviour but proves nothing about the message surviving.
		unpark()
		local second, _entry, data = harness.Join(RECIPIENT)
		harness.Data.OnMessage:Connect(function(_player, message)
			data.Coins.Increment(message.Amount)
		end)
		harness.Data.Flush(second, { Force = true })
		task.wait()

		expect(("survived=%d queued=%d coins=%d"):format(survived, mailboxLen(harness, RECIPIENT), data.Coins.Get())).to.equal(
			"survived=1 queued=0 coins=50"
		)

		harness.Cleanup()
	end)

	it("says nothing when every handler returned, however slowly", function()
		-- THE CONTROL, and the one that keeps this from becoming noise on every leave.
		-- A handler that yields and then FINISHES has settled: the ack was spent, so
		-- there is nothing outstanding at session end.
		local seen, unsubscribe = codeCounter()
		local harness = makeHarness()
		local recipient, _entry, data = harness.Join(RECIPIENT)

		local parked = nil
		harness.Data.OnMessage:Connect(function(_player, message)
			if parked == nil then
				parked = coroutine.running()
				coroutine.yield()
			end
			data.Coins.Increment(message.Amount)
		end)

		expect(harness.Data.SendMessage(RECIPIENT, { Amount = 50 })).to.equal(true)
		harness.Data.Flush(recipient)
		task.wait()
		local beforeResume = ("queued=%d coins=%d"):format(mailboxLen(harness, RECIPIENT), data.Coins.Get())

		task.spawn(parked) -- the handler finishes, late but genuinely
		task.wait()
		local afterResume = ("queued=%d coins=%d"):format(mailboxLen(harness, RECIPIENT), data.Coins.Get())

		harness.Leave(recipient)
		task.wait()
		unsubscribe()

		expect(
			("%s || %s || queued=%d stalled=%d"):format(
				beforeResume,
				afterResume,
				mailboxLen(harness, RECIPIENT),
				seen.MESSAGE_HANDLER_STALLED or 0
			)
			-- The trailing queued=1 is the fake's one-save lag, not a withheld ack: the
			-- ack was spent the moment the handler returned (MessageAckDurability.spec
			-- owns that ordering). What matters here is stalled=0 -- nothing outstanding.
		).to.equal("queued=1 coins=0 || queued=1 coins=50 || queued=1 stalled=0")

		harness.Cleanup()
	end)

	it("says nothing for a handler that RAISED -- that outcome already has a code", function()
		-- A raise settles the fire, so nothing is outstanding. Two diagnostics for one
		-- message would double-count every broken handler in the logs. errors=2 because
		-- the final save re-offers the still-unacknowledged message and the handler
		-- raises on that offer too -- the same re-offer the stall count sees.
		local seen, unsubscribe = codeCounter()
		local harness = makeHarness()
		local recipient = harness.Join(RECIPIENT)

		harness.Data.OnMessage:Connect(function()
			error("handler blew up")
		end)

		expect(harness.Data.SendMessage(RECIPIENT, { Amount = 50 })).to.equal(true)
		harness.Data.Flush(recipient)
		task.wait()
		harness.Leave(recipient)
		task.wait()
		unsubscribe()

		expect(
			("errors=%d stalled=%d queued=%d"):format(
				seen.MESSAGE_HANDLER_ERROR or 0,
				seen.MESSAGE_HANDLER_STALLED or 0,
				mailboxLen(harness, RECIPIENT)
			)
		).to.equal("errors=2 stalled=0 queued=1")

		harness.Cleanup()
	end)

	it("says nothing when NOTHING was connected -- that outcome already has a code too", function()
		local seen, unsubscribe = codeCounter()
		local harness = makeHarness()
		local recipient = harness.Join(RECIPIENT)

		expect(harness.Data.SendMessage(RECIPIENT, { Amount = 50 })).to.equal(true)
		harness.Data.Flush(recipient)
		task.wait()
		harness.Leave(recipient)
		task.wait()
		unsubscribe()

		expect(
			("noListener=%d stalled=%d queued=%d"):format(
				seen.MESSAGE_NO_LISTENER or 0,
				seen.MESSAGE_HANDLER_STALLED or 0,
				mailboxLen(harness, RECIPIENT)
			)
		).to.equal("noListener=2 stalled=0 queued=1")

		harness.Cleanup()
	end)

	it("says nothing on an ordinary session with no cross-server message at all", function()
		-- The cheapest regression this could cause is a warning on every single leave.
		local seen, unsubscribe = codeCounter()
		local harness = makeHarness()
		local player, _entry, data = harness.Join(RECIPIENT)
		data.Coins.Increment(7)
		harness.Data.Flush(player)
		task.wait()
		harness.Leave(player)
		task.wait()
		unsubscribe()

		expect(("stalled=%d"):format(seen.MESSAGE_HANDLER_STALLED or 0)).to.equal("stalled=0")
		harness.Cleanup()
	end)
end
