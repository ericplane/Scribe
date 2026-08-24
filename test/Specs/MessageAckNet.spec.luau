--!nonstrict
-- THE CROSS-SERVER MESSAGE ACK NET.
--
-- One ProfileStore message handler is registered per session
-- (Persistence.luau, in finishLoad) and it has TWO ARMS in one function body:
--
--     ctx.Monetization.OnProfileMessage(entry, message, processed)   -- gift arm
--     if type(message) == "table" and message.ScribeMessage == true then
--         ctx.Signals.OnMessage:Fire(entry.Player, message.Data)     -- user arm
--         processed()
--     end
--
-- The gift arm runs FIRST and UNPROTECTED -- no pcall around it. So everything
-- below is really one claim: the two arms must stay independent, and the ack
-- predicate each one uses must stay the one it has.
--
--   * the gift arm acks ONLY on `durable` (AwaitSave true), because the queued
--     message is the only surviving copy of a paid gift and processed() retires
--     it for good; re-delivery is safe because the message carries a FIXED
--     purchaseId the dedupe ring catches
--   * the user arm acks unconditionally, and today that makes Data.OnMessage
--     AT-MOST-ONCE -- a Data.SendMessage payload carries NO id, so there is
--     nothing to dedupe a redelivery against
--
-- F5 rewrites the user arm. These specs exist so that a change to it cannot
-- silently disturb the gift arm beside it, and so that a change to the user arm's
-- delivery guarantee has to be a DECISION rather than a side effect.
--
-- Not duplicated here, because they already have specs that must simply stay
-- green: Messaging.spec (an untagged payload never fires OnMessage),
-- ReleaseOnlyMessages.spec (a message is retired only in the same write that
-- persists the data reflecting it), and CrossPlayerTxnAtomicity.spec's
-- non-yielding CONTROL case.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Health = require(Root.Scribe.Internal.Health)

	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted

	local function makeHarness(extraOptions)
		local options = {
			Products = {
				GiftVIP = { Id = 222, Category = "Gamepass", Grants = "VIP" },
			},
			GiftCooldown = 0,
			PromptProductPurchase = function() end,
		}
		for key, value in extraOptions or {} do
			options[key] = value
		end
		return TestCtx.make({ Options = options })
	end

	local function receipt(userId, productId, purchaseId)
		return {
			PlayerId = userId,
			ProductId = productId,
			PurchaseId = purchaseId,
			CurrencySpent = 99,
			CurrencyType = Enum.CurrencyType.Robux,
			PlaceIdWherePurchased = 0,
		}
	end

	local function mailboxLen(harness, userId: number): number
		local mailbox = harness.Fake.Mailboxes["Default/" .. harness.Ctx.Persistence.KeyFor(userId)]
		return if mailbox then #mailbox else 0
	end

	local function giftLines(harness, player): number
		local n = 0
		for _, line in harness.Data.GetPurchases(player, { Kind = "Robux" }) do
			if line.From and line.From.Type == "GiftReceived" then
				n += 1
			end
		end
		return n
	end

	--------------------------------------------------------------------------------
	-- INVARIANT 11: the gift arm acks on `durable`, and on nothing weaker
	--------------------------------------------------------------------------------

	it("keeps a queued gift in the mailbox until the recipient's save actually confirms", function()
		-- deliverGiftLocal returns (applied, durable). `applied` means the grant is in
		-- the recipient's MEMORY; `durable` means AwaitSave confirmed it. processed()
		-- destroys the only durable copy of the gift, so acking on anything weaker --
		-- `applied`, `not Dirty`, or merely "the call returned" -- loses a paid gift
		-- to any crash before the next autosave.
		local harness = makeHarness()
		local buyer = harness.Join(92001)

		-- A gift to an OFFLINE recipient: it lands in their mailbox, not their tree.
		expect(harness.Data.PromptGift(buyer, "GiftVIP", 92002)).to.equal(true)
		expect(harness.Data.HandleReceipt(receipt(92001, 222, "durable-gift"))).to.equal(GRANTED)
		expect(mailboxLen(harness, 92002)).to.equal(1)

		-- The recipient logs in while saves are down. The grant applies in memory and
		-- the save cannot confirm, so the message is NOT acked.
		harness.Fake.FailSaves = true
		local recipient = harness.Join(92002)
		-- SETTLE, and this is the whole measurement. The handler parks inside
		-- AwaitSave (it yields on a Sched.Spawn'd save), so Join returns while the
		-- ack decision has not been taken yet. Reading the mailbox here without
		-- waiting measures "the handler has not finished", which is true whatever
		-- predicate the ack uses -- an assertion that cannot tell `durable` from
		-- `applied` and quietly passes either way. Verified by mutation: gating the
		-- ack on the 1st return with no settle left the suite green.
		for _ = 1, 20 do
			task.wait()
		end
		local appliedInMemory = harness.Data.Owns(recipient, "VIP")
		local queuedWhileFailing = mailboxLen(harness, 92002)
		harness.Leave(recipient) -- and the session ends without ever persisting
		harness.Fake.FailSaves = false

		-- Nothing durable happened: the profile on disk still has no perk.
		local persisted = harness.Fake.Persisted["Default/PLAYER_92002"]
		local perkOnDisk = persisted ~= nil and persisted._Scribe ~= nil and persisted._Scribe.Perks.VIP == true

		-- The message survived, so the next session delivers the gift for real.
		local recipient2 = harness.Join(92002)
		harness.Data.Flush(recipient2)

		expect(
			("applied=%s queued=%d disk=%s redelivered=%s queuedAfter=%d lines=%d"):format(
				tostring(appliedInMemory),
				queuedWhileFailing,
				tostring(perkOnDisk),
				tostring(harness.Data.Owns(recipient2, "VIP")),
				mailboxLen(harness, 92002),
				giftLines(harness, recipient2)
			)
		).to.equal("applied=true queued=1 disk=false redelivered=true queuedAfter=0 lines=1")

		harness.Cleanup()
	end)

	--------------------------------------------------------------------------------
	-- INVARIANT 10: the gift arm is a non-throwing early return, so the user arm
	-- below it stays reachable
	--------------------------------------------------------------------------------

	it("still delivers the user message when the gift arm rejects the same payload", function()
		-- The gift arm has no pcall around it. If OnProfileMessage ever RAISES on a
		-- payload -- an unregistered product, a malformed field, anything -- the user
		-- arm below never runs and every Data.SendMessage on that key is silently
		-- redelivered forever with nothing consuming it.
		--
		-- A payload carrying both tags is reachable through the Data.Store escape
		-- hatch, and is the cheapest way to drive the gift arm's reject path and the
		-- user arm in one message.
		local codes = {}
		local unsubscribe = Scribe.AddLogSink(function(entry)
			if entry.Code == "GIFT_UNKNOWN_PRODUCT" then
				table.insert(codes, entry.Code)
			end
		end)

		local harness = makeHarness()
		local received = {}
		harness.Data.OnMessage:Connect(function(_player, message)
			table.insert(received, tostring(message and message.Tag))
		end)

		local store = harness.Ctx.Persistence.Store
		expect(store:MessageAsync(harness.Ctx.Persistence.KeyFor(92011), {
			ScribeGift = true, -- the gift arm will reject this...
			ScribeMessage = true, -- ...and the user arm must still run
			Product = "NeverRegistered",
			PurchaseId = "both-tags-1",
			GiftId = "g",
			FromUserId = 92012,
			Data = { Tag = "hello" },
		})).to.equal(true)

		local player = harness.Join(92011)
		task.wait()
		unsubscribe()

		expect(
			("fires=%s queued=%d owns=%s giftLog=%d rejected=%d"):format(
				table.concat(received, ","),
				mailboxLen(harness, 92011),
				tostring(harness.Data.Owns(player, "VIP")),
				giftLines(harness, player),
				#codes
			)
		).to.equal("fires=hello queued=0 owns=false giftLog=0 rejected=1")

		harness.Cleanup()
	end)

	--------------------------------------------------------------------------------
	-- INVARIANT 13(c): the two channels never cross
	--------------------------------------------------------------------------------

	it("keeps gift payloads off OnMessage and user payloads out of the gift arm", function()
		local harness = makeHarness()
		local buyer = harness.Join(92021)

		local onMessageFires = 0
		harness.Data.OnMessage:Connect(function()
			onMessageFires += 1
		end)

		-- A real gift to an offline recipient.
		expect(harness.Data.PromptGift(buyer, "GiftVIP", 92022)).to.equal(true)
		expect(harness.Data.HandleReceipt(receipt(92021, 222, "channel-gift"))).to.equal(GRANTED)

		-- ...and an ordinary user message to a different offline player.
		expect(harness.Data.SendMessage(92023, { Tag = "user" })).to.equal(true)

		local recipient = harness.Join(92022)
		local plain = harness.Join(92023)
		task.wait()

		expect(("giftFiredOnMessage=%d recipientVIP=%s plainVIP=%s plainGiftLines=%d"):format(
			onMessageFires - 1, -- the one legitimate fire is the user message
			tostring(harness.Data.Owns(recipient, "VIP")),
			tostring(harness.Data.Owns(plain, "VIP")),
			giftLines(harness, plain)
		)).to.equal("giftFiredOnMessage=0 recipientVIP=true plainVIP=false plainGiftLines=0")

		harness.Cleanup()
	end)

	--------------------------------------------------------------------------------
	-- INVARIANT 12 / 13(a): a durably-handled user message is delivered exactly once
	--------------------------------------------------------------------------------

	it("delivers a user message once to a handler that writes, and never again", function()
		-- The half of the F5 area that is NOT broken, and the half a fix is most
		-- likely to break. Today Data.OnMessage is AT-MOST-ONCE: the ack is
		-- unconditional, so a message that was handled is gone.
		--
		-- If F5 makes the ack conditional, this spec is the one that says what that
		-- costs. A Data.SendMessage payload carries NO id -- Server.SendMessage wraps
		-- it as `{ ScribeMessage = true, Data = message }` and nothing else -- so
		-- there is nothing for a redelivery to dedupe against, and a withheld ack
		-- turns OnMessage from at-most-once into at-least-once. That is a documented
		-- contract change: it belongs in the SendMessage/OnMessage docstrings and the
		-- guides, not in an implementation diff. If F5 keeps at-most-once, this spec
		-- keeps passing untouched.
		local harness = makeHarness()
		local sender = harness.Join(92031)
		local receiverPlayer, _, receiverData = harness.Join(92032)

		local fires = 0
		harness.Data.OnMessage:Connect(function(_player, message)
			fires += 1
			receiverData.Coins.Increment(tonumber(message.Amount) or 0)
		end)

		expect(harness.Data.SendMessage(92032, { Amount = 25 })).to.equal(true)
		expect(mailboxLen(harness, 92032)).to.equal(1)

		-- Delivery rides a save, so drive several of them.
		for _ = 1, 4 do
			harness.Data.Flush(receiverPlayer)
			task.wait()
		end

		expect(("fires=%d coins=%d queued=%d"):format(fires, receiverData.Coins.Get(), mailboxLen(harness, 92032))).to.equal(
			"fires=1 coins=25 queued=0"
		)
		expect(sender).to.be.ok()

		harness.Cleanup()
	end)

	--------------------------------------------------------------------------------
	-- INVARIANT 22: the boolean means COMMITTED, and a full queue is not an outage
	--------------------------------------------------------------------------------

	it("answers false on a full queue without degrading the server's health", function()
		-- A full inbox is a property of ONE player's profile, not a DataStore fault.
		-- Routing it through Failure.Report would call Health.ReportFailure, and a
		-- single jammed queue could then degrade the server to Outage -- which
		-- refuses every Robux grant, including the receipt retries that would have
		-- drained it. MESSAGE_QUEUE_FULL and MESSAGE_SEND_FAIL are the only two codes
		-- on this path and they mean different things.
		local codes = {}
		local lines = {}
		local unsubscribe = Scribe.AddLogSink(function(entry)
			if entry.Code == "MESSAGE_QUEUE_FULL" or entry.Code == "MESSAGE_SEND_FAIL" then
				table.insert(codes, entry.Code)
				table.insert(lines, entry)
			end
		end)

		local harness = makeHarness()
		harness.Fake.SetConstant("MAX_MESSAGE_QUEUE", 1)

		-- A DELTA, because Metrics is a process singleton under this harness and other
		-- specs legitimately move this counter before this one runs.
		local ambiguousBefore = (Scribe.GetMetrics().MessageQueueFullAmbiguous :: any) or 0

		local first = harness.Data.SendMessage(92041, { N = 1 })
		local second = harness.Data.SendMessage(92041, { N = 2 })
		task.wait()
		unsubscribe()

		expect(
			("first=%s second=%s queued=%d health=%s codes=%s"):format(
				tostring(first),
				tostring(second),
				mailboxLen(harness, 92041),
				Health.GetStatus(),
				table.concat(codes, ",")
			)
		).to.equal("first=true second=false queued=1 health=Healthy codes=MESSAGE_QUEUE_FULL")

		-- AND THE LINE MUST NOT OVERCLAIM. It used to end "nothing was written"
		-- whatever had happened, which is false of a refusal that follows a commit
		-- inside the same call -- the message is then already in the recipient's inbox
		-- and the operator is being told it is not. `provably_clean` is what the line
		-- is now conditioned on. This refusal genuinely IS clean (the fake is one
		-- attempt and cannot loop), so it claims so and the ambiguous counter stays
		-- untouched; the other shape is held against the real fork in
		-- GiftCreditCostInversion.spec, which the fake cannot produce.
		expect(#lines).to.equal(1)
		expect(lines[1].Context.ProvablyClean).to.equal(true)
		expect(string.find(tostring(lines[1].Message), "no attempt in this call reached storage") ~= nil).to.equal(true)
		local ambiguousAfter = (Scribe.GetMetrics().MessageQueueFullAmbiguous :: any) or 0
		expect(ambiguousAfter - ambiguousBefore).to.equal(0)

		harness.Cleanup()
	end)
end
