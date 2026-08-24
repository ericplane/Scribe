--!nonstrict
-- THE COST INVERSION, AND WHAT HOLDS IT CLOSED. `provably_clean` was derived from
-- an ATTEMPT COUNT rather than from whether any attempt could have written, and
-- the inversion cost a buyer their paid gift credit.
--
-- MessageAsync's loop repeats while UpdateAsync answers nil, and UpdateAsync
-- returns nil for EVERY failure class -- including the two that Failure.luau
-- classifies as provably never applied (1xx "Rejected", 3xx "Throttled"). So one
-- throttle in front of an ordinary full inbox turned `attempts == 1` false and the
-- refund gate read "cannot be sure" for a call in which nothing was ever written.
--
-- WRITTEN RED, LANDED GREEN. The first three rows were RED on the tree that
-- shipped, each failing on its own final assertion with every premise above it
-- green: `false/QueueFull/false` where the call is provably clean, `false/nil/
-- false` on a key never minted, and live=0/stored=0 where the credit must survive.
-- The third is the cost: one paid credit, zero grants, nothing in the recipient's
-- inbox.
--
-- THEY DID NOT GO GREEN BY RELAXING THE COUNT, and that was measured before the
-- fix rather than assumed: flipping the two loop exits to a bare `true` turns all
-- three green and turns both rows of StoreAccessors' "could anything have been
-- written" red again, i.e. it reopens the double grant. Only classification
-- satisfies both files at once, which is why the rows below also pin the
-- classifier itself rather than only its result.
--
-- Every row runs against the REAL fork over the modelled disk, so the retry
-- behaviour is the library's own. The throttle is the sim's `Throttled` fault,
-- which raises catalogue entry RequestQueueFull -- "301: ... Request was throttled,
-- but throttled request queue was full." -- BEFORE the transform is invoked
-- (test/Sim/Disk/Store.luau, step (2)), so nothing can have been written by it.
-- Failure.Classify reads 301 -> byFamily -> "Throttled". The lost-reply shape uses
-- `Indeterminate` (504, "Unresolved"), which COMMITS and then raises.
--
-- WHAT THIS FILE DELIBERATELY DOES NOT CLAIM. StoreAccessors' give-up row arms
-- `ServiceError`, which is 502 and classifies as "Failed" -- a service-side
-- failure that may or may not have landed -- so `false/nil/false` is the correct
-- answer there both before and after this work, and that row is untouched.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Universe = require(Root.Test.Sim.Universe)
	local Guard = require(Root.Test.Sim.Guard)
	local it = if require(Root.Test.Sim.Available).Ready then it else itSKIP
	local StubTransport = require(Root.Test.Helpers.StubTransport)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	local COINS_GIFT = 991
	local BUYER = 96401
	local RECIPIENT = 96402

	local universe

	local function build(constants, options)
		local base = {
			AUTO_SAVE_PERIOD = 300,
			SESSION_STEAL = 40,
			FIRST_LOAD_REPEAT = 5,
			ASSUME_DEAD = 630,
		}
		for name, value in constants or {} do
			base[name] = value
		end
		universe = Universe.new({
			Seed = 4243,
			Servers = 1,
			Constants = base,
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Instant",
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = options or {},
		})
		Guard.Install(universe)
		return universe
	end

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	--- Run `fn` on a scheduler thread and pump until it has finished.
	local function drive(uni, fn)
		local out = {}
		uni.Sched:Spawn(function()
			fn(out)
			out.Done = true
		end)
		uni:Run(120)
		if not out.Done then
			error("call never settled", 2)
		end
		return out
	end

	describe("MessageAsync: an attempt that PROVABLY wrote nothing must not poison the call", function()
		it("a throttle in front of a full inbox still answers clean", function()
			-- THE COST INVERSION, at the store. The cap is 1 and one filler message
			-- already occupies it, so the inbox is genuinely full. A single armed
			-- throttle makes the FIRST attempt fail with 301 -- raised before the
			-- transform ran, so nothing was written and nothing could have been -- and
			-- the second attempt reaches the cap and refuses in band.
			--
			-- Two attempts, zero possible writes. The attempt COUNT this replaced said
			-- otherwise, because the throttled attempt made it two.
			local uni = build({ MAX_MESSAGE_QUEUE = 1 })
			local store = uni:Server(1).Bundle.Ctx.Persistence.Store
			local key = "INV_THROTTLE"

			local r = drive(uni, function(out)
				-- Fill the inbox first, with no fault in play.
				out.Filler = store:MessageAsync(key, { Seq = 0 })

				uni.Disk:Arm({ Kind = "Throttled", Op = "UpdateAsync", Key = key, Count = 1 })
				local ok, reason, clean = store:MessageAsync(key, { Seq = 1 })
				out.Row = `{tostring(ok)}/{tostring(reason)}/{tostring(clean)}`

				-- The premise, asserted rather than assumed: the inbox holds exactly
				-- the filler. The refused send is not in it and cannot arrive later.
				local seen = {}
				local reader = store:StartSessionAsync(key, {
					Cancel = function()
						return false
					end,
				})
				reader:MessageHandler(function(message, processed)
					table.insert(seen, tostring(message.Seq))
					processed()
				end)
				reader:SaveAwait()
				out.Seen = table.concat(seen, ",")
				reader:EndSession()
			end)

			expect(r.Filler).to.equal(true)
			expect(r.Seen).to.equal("0")
			-- The whole call is provably clean: attempt one was rejected before its
			-- transform, attempt two aborted its own write. Nothing was written.
			expect(r.Row).to.equal("false/QueueFull/true")
		end)

		it("a give-up after nothing but throttles answers clean, on a key never minted", function()
			-- THE SECOND SHAPE. Every UpdateAsync on this key is throttled, so every
			-- attempt is provably clean, and the loop ends at the closing flag with a
			-- bare `false`. `attempts == 0` was false here, so the call used to report
			-- doubt about writes that certainly did not happen, on a key that does not
			-- even exist afterwards -- which is asserted below rather than assumed.
			local uni = build()
			local module = uni:Server(1).Bundle.Options.ProfileStore
			local store = uni:Server(1).Bundle.Ctx.Persistence.Store
			local key = "INV_GIVEUP"

			local r = drive(uni, function(out)
				uni.Disk:Arm({ Kind = "Throttled", Op = "UpdateAsync", Key = key, Count = 1000000 })
				uni.Sched:Spawn(function()
					uni.Sched:Wait(4)
					module.IsClosing = true
				end)
				local ok, reason, clean = store:MessageAsync(key, { Seq = 1 })
				module.IsClosing = false
				out.Row = `{tostring(ok)}/{tostring(reason)}/{tostring(clean)}`
				out.KeyExists = uni.Disk.Keyspace:Read("Default", key) ~= nil
			end)

			expect(r.KeyExists).to.equal(false)
			expect(r.Row).to.equal("false/nil/true")
		end)

		it("says so because of the CLASSIFIER, and without one is exactly what it was before", function()
			-- THE HOOK IS THE FIX, so the hook is what gets pinned. The fork has no
			-- `require` and no `script` -- the simulation loads it as raw source into a
			-- private global table -- so Failure.Classify is handed in by Persistence as
			-- it adopts the module rather than required at the top. A spec that only
			-- asserted the answer would pass on a build where the injection was dropped
			-- and the store silently went back to counting.
			--
			-- Both directions in one row, on the SAME universe and the same fault, so
			-- the only difference between the two answers is the classifier itself.
			--
			-- AND WHAT ABSENCE MEANS IS PART OF THE CONTRACT. With no classifier every
			-- failed attempt reads as "could have written", which -- because this loop
			-- only continues on failure -- is bit-for-bit what `attempts == 1` computed.
			-- So the hook can only ever move an answer towards "provably clean", never
			-- away from it, and a caller that forgets to install it is merely back where
			-- it started rather than somewhere new.
			local uni = build({ MAX_MESSAGE_QUEUE = 1 })
			local module = uni:Server(1).Bundle.Options.ProfileStore
			local store = uni:Server(1).Bundle.Ctx.Persistence.Store

			local r = drive(uni, function(out)
				-- Installed by Persistence during the build, before any spec code runs.
				out.Installed = type(module.ClassifyError) == "function"
				out.ClassOf301 = tostring(
					module.ClassifyError(
						"301: GetAsync request dropped. Request was throttled, "
							.. "but throttled request queue was full."
					)
				)

				out.FillA = store:MessageAsync("INV_HOOK_A", { Seq = 0 })
				uni.Disk:Arm({ Kind = "Throttled", Op = "UpdateAsync", Key = "INV_HOOK_A", Count = 1 })
				local okA, whyA, cleanA = store:MessageAsync("INV_HOOK_A", { Seq = 1 })
				out.WithClassifier = `{tostring(okA)}/{tostring(whyA)}/{tostring(cleanA)}`

				local saved = module.ClassifyError
				module.ClassifyError = nil
				out.FillB = store:MessageAsync("INV_HOOK_B", { Seq = 0 })
				uni.Disk:Arm({ Kind = "Throttled", Op = "UpdateAsync", Key = "INV_HOOK_B", Count = 1 })
				local okB, whyB, cleanB = store:MessageAsync("INV_HOOK_B", { Seq = 1 })
				out.WithoutClassifier = `{tostring(okB)}/{tostring(whyB)}/{tostring(cleanB)}`
				module.ClassifyError = saved
			end)

			expect(r.Installed).to.equal(true)
			expect(r.ClassOf301).to.equal("Throttled")
			expect(r.FillA).to.equal(true)
			expect(r.FillB).to.equal(true)
			expect(r.WithClassifier).to.equal("false/QueueFull/true")
			-- The pre-hook answer, and the direction a missing injection fails in.
			expect(r.WithoutClassifier).to.equal("false/QueueFull/false")
		end)
	end)

	describe("and what the inversion used to cost a buyer", function()
		it("keeps the paid credit when an ordinary full inbox is preceded by ONE throttle", function()
			-- THE MONEY. End to end through PromptGift, against the real store: the
			-- previous brief's explicit acceptance criterion was that an ordinary full
			-- inbox with nothing written must STILL refund. One throttle in front of it
			-- is enough to break that, and the buyer pays for it.
			--
			-- Stackable on purpose, as in GiftCreditSpendContract.spec: the product
			-- grants coins through a `Grant` callback and declares no `Grants` perk, so
			-- the duplicate-recipient guard (an offline GetAsync on the armed key) is
			-- off the path.
			local prompted = {}
			local uni = build({ MAX_MESSAGE_QUEUE = 1 }, {
				GiftCooldown = 0,
				PromptProductPurchase = function(player, productId)
					table.insert(prompted, { Player = player, ProductId = productId })
				end,
				Products = {
					CoinsGift = {
						Id = COINS_GIFT,
						Category = "Currency",
						Grant = function(data)
							data.Coins.Increment(1000)
						end,
					},
				},
			})
			local server = uni:Server(1)
			local bundle = server.Bundle
			local store = bundle.Ctx.Persistence.Store
			local recipientKey = bundle.Ctx.Persistence.KeyFor(RECIPIENT)

			local buyer = FakePlayer.new(BUYER)
			server:Join(BUYER, buyer)
			uni:Run(30)

			-- One credit, DURABLY: the spend's discipline is reserve-on-disk then
			-- deliver, so a credit that was never on disk proves nothing.
			bundle.Ctx.Persistence.EntryFor(buyer).Tree.Reserved.GiftCredits.CoinsGift.Set(1)
			local r = drive(uni, function(out)
				out.Reserved = bundle.Data.Flush(buyer, { Force = true })

				-- The recipient's inbox is genuinely full, filled with no fault in play.
				out.Filler = store:MessageAsync(recipientKey, { Filler = true })

				-- ... and the delivery call sees exactly one throttle first.
				uni.Disk:Arm({ Kind = "Throttled", Op = "UpdateAsync", Key = recipientKey, Count = 1 })
				local ok, reason = bundle.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)
				out.Answer = `{tostring(ok)}/{tostring(reason)}`

				out.Live = tonumber(bundle.Data.GetGiftCredits(buyer).CoinsGift) or 0
				out.Flushed = bundle.Data.Flush(buyer, { Force = true })
			end)

			local stored = uni.Disk.Keyspace:Read("Default", bundle.Ctx.Persistence.KeyFor(BUYER))
			local scribe = stored and stored.Value and stored.Value.Data and stored.Value.Data._Scribe
			local storedCredits = tonumber(scribe and scribe.GiftCredits and scribe.GiftCredits.CoinsGift) or 0

			expect(r.Reserved).to.equal(true)
			expect(r.Filler).to.equal(true)
			expect(r.Flushed).to.equal(true)
			expect(#prompted).to.equal(0) -- a credit spend never charges Robux

			-- Nothing was delivered and nothing can arrive later: the only thing in the
			-- recipient's inbox is the filler this spec put there.
			local inbox = uni.Disk.Keyspace:Read("Default", recipientKey)
			local queue = inbox and inbox.Value and inbox.Value.GlobalUpdates and inbox.Value.GlobalUpdates[2]
			expect(#(queue or {})).to.equal(1)

			-- THE COST, named. One payment, zero grants, and the credit is gone.
			expect(`live={r.Live}/stored={storedCredits}`).to.equal("live=1/stored=1")

			-- And the buyer is told to try again, not warned off a gift that never
			-- went out.
			expect(string.find(tostring(r.Answer), "do not send it again") ~= nil).to.equal(false)

			-- WHAT THE OPERATOR IS TOLD, on the clean shape. The line used to say the
			-- gift was not delivered whatever had happened, three lines above the code
			-- that reads `provablyClean` precisely because it cannot claim that. Here
			-- it CAN, and the counter that separates the two shapes stays untouched.
			local entries = bundle.Scribe.GetRecentLogs({ Code = "MESSAGE_QUEUE_FULL", Limit = 50 })
			expect(#entries).to.equal(1)
			expect(entries[1].Context.ProvablyClean).to.equal(true)
			expect(string.find(tostring(entries[1].Message), "no attempt in this call reached storage") ~= nil).to.equal(
				true
			)
			local metrics = bundle.Scribe.GetMetrics()
			expect(metrics.MessageQueueFull).to.equal(1)
			expect(metrics.MessageQueueFullAmbiguous).to.equal(nil)
		end)

		it("tells the operator when the SAME refusal may be hiding a delivery", function()
			-- THE OTHER SHAPE, and the one an operator actually has to reconcile. The
			-- first attempt COMMITS the message and then raises (the sim's
			-- `Indeterminate` fault, 504), so with the cap at one the committed insert
			-- is itself what fills the queue and the second attempt of the same call
			-- refuses in band. `MessageQueueFull` fires for this exactly as it fires for
			-- an empty-handed refusal, so on its own it cannot distinguish a gift that
			-- was never sent from one that is sitting in the recipient's inbox.
			--
			-- Three things now do: the line's own wording, `Context.ProvablyClean`, and
			-- a second counter. The credit stays spent, which is the already-closed half
			-- and is asserted here so this row fails if it reopens.
			local prompted = {}
			local uni = build({ MAX_MESSAGE_QUEUE = 1 }, {
				GiftCooldown = 0,
				PromptProductPurchase = function(player, productId)
					table.insert(prompted, { Player = player, ProductId = productId })
				end,
				Products = {
					CoinsGift = {
						Id = COINS_GIFT,
						Category = "Currency",
						Grant = function(data)
							data.Coins.Increment(1000)
						end,
					},
				},
			})
			local server = uni:Server(1)
			local bundle = server.Bundle
			local recipientKey = bundle.Ctx.Persistence.KeyFor(RECIPIENT)

			local buyer = FakePlayer.new(BUYER)
			server:Join(BUYER, buyer)
			uni:Run(30)

			bundle.Ctx.Persistence.EntryFor(buyer).Tree.Reserved.GiftCredits.CoinsGift.Set(1)
			local r = drive(uni, function(out)
				out.Reserved = bundle.Data.Flush(buyer, { Force = true })
				uni.Disk:Arm({ Kind = "Indeterminate", Op = "UpdateAsync", Key = recipientKey, Count = 1 })
				local ok, reason = bundle.Data.PromptGift(buyer, "CoinsGift", RECIPIENT)
				out.Answer = `{tostring(ok)}/{tostring(reason)}`
				out.Commits = uni.Disk.Faults.Stats.IndeterminateCommits
				out.Live = tonumber(bundle.Data.GetGiftCredits(buyer).CoinsGift) or 0
				out.Flushed = bundle.Data.Flush(buyer, { Force = true })
			end)

			expect(r.Reserved).to.equal(true)
			expect(r.Flushed).to.equal(true)
			expect(#prompted).to.equal(0)

			-- The premise, asserted rather than assumed: the raising attempt really did
			-- commit, and the gift really is in the recipient's key.
			expect(r.Commits).to.equal(1)
			local inbox = uni.Disk.Keyspace:Read("Default", recipientKey)
			local queue = inbox and inbox.Value and inbox.Value.GlobalUpdates and inbox.Value.GlobalUpdates[2]
			expect(#(queue or {})).to.equal(1)

			-- The already-closed half: refunding here buys a second grant off one
			-- payment, so the credit stays spent and the buyer is warned off a retry.
			local stored = uni.Disk.Keyspace:Read("Default", bundle.Ctx.Persistence.KeyFor(BUYER))
			local scribe = stored and stored.Value and stored.Value.Data and stored.Value.Data._Scribe
			local storedCredits = tonumber(scribe and scribe.GiftCredits and scribe.GiftCredits.CoinsGift) or 0
			expect(`live={r.Live}/stored={storedCredits}`).to.equal("live=0/stored=0")
			expect(string.find(tostring(r.Answer), "do not send it again") ~= nil).to.equal(true)

			-- ...and the operator can tell this refusal from the other one.
			local entries = bundle.Scribe.GetRecentLogs({ Code = "MESSAGE_QUEUE_FULL", Limit = 50 })
			expect(#entries).to.equal(1)
			expect(entries[1].Context.ProvablyClean).to.equal(false)
			expect(string.find(tostring(entries[1].Message), "may already have queued this gift") ~= nil).to.equal(true)
			local metrics = bundle.Scribe.GetMetrics()
			expect(metrics.MessageQueueFull).to.equal(1)
			expect(metrics.MessageQueueFullAmbiguous).to.equal(1)
		end)
	end)

	describe("a raise between the spend and the refund gate", function()
		it("settles as unconfirmed and names the error, instead of escaping as a script error", function()
			-- THE EXIT NOBODY HAD CLASSIFIED. The two gates cover `deliverGift`
			-- RETURNING. A raise out of it unwound straight past both: the credit was
			-- already spent and durable, no refund ran, no GIFT_CREDIT_UNCONFIRMED was
			-- logged, nothing was counted, and the buyer's own remote handler got a
			-- script error rather than a documented refusal. One payment, zero grants,
			-- and no record that it happened.
			--
			-- THE SEAM STANDS IN FOR THE WHOLE CLASS, deliberately. `deliverGift` reads
			-- ctx.Persistence.EntryForUserId at call time, and its other raise sources
			-- are accessor writes onto a recipient tree that was torn down mid-yield --
			-- reachable but not constructible on demand from a spec, and the point of
			-- the pcall is that it does not depend on WHICH of them fired. Replacing
			-- this one function is the smallest thing that reaches the exit. The product
			-- is Grant-only, so the duplicate-recipient guard (the other EntryForUserId
			-- caller) is off the path and the raise cannot fire before the spend.
			--
			-- IT IS CLASSIFIED AMBIGUOUS, NOT CLEAN, and that is the whole judgement: a
			-- raise can come from before the grant or from after it, so refunding would
			-- reopen the double grant. The credit stays spent and says so loudly.
			local prompted = {}
			local uni = build(nil, {
				GiftCooldown = 0,
				PromptProductPurchase = function(player, productId)
					table.insert(prompted, { Player = player, ProductId = productId })
				end,
				Products = {
					CoinsGift = {
						Id = COINS_GIFT,
						Category = "Currency",
						Grant = function(data)
							data.Coins.Increment(1000)
						end,
					},
				},
			})
			local server = uni:Server(1)
			local bundle = server.Bundle

			local buyer = FakePlayer.new(BUYER)
			server:Join(BUYER, buyer)
			uni:Run(30)

			bundle.Ctx.Persistence.EntryFor(buyer).Tree.Reserved.GiftCredits.CoinsGift.Set(1)
			local r = drive(uni, function(out)
				out.Reserved = bundle.Data.Flush(buyer, { Force = true })

				local realLookup = bundle.Ctx.Persistence.EntryForUserId
				bundle.Ctx.Persistence.EntryForUserId = function()
					error("sim: the delivery path raised")
				end
				local ok, promptOk, reason = pcall(bundle.Data.PromptGift, buyer, "CoinsGift", RECIPIENT)
				bundle.Ctx.Persistence.EntryForUserId = realLookup

				-- pcall'd at the SPEC boundary too, so a regression that lets the raise
				-- escape shows up as this row's own assertion rather than as a crash.
				out.Raised = not ok
				out.Answer = if ok then `{tostring(promptOk)}/{tostring(reason)}` else tostring(promptOk)
				out.Live = tonumber(bundle.Data.GetGiftCredits(buyer).CoinsGift) or 0
				out.Flushed = bundle.Data.Flush(buyer, { Force = true })
			end)

			expect(r.Reserved).to.equal(true)
			expect(r.Flushed).to.equal(true)
			expect(#prompted).to.equal(0)

			-- The refusal is documented, not thrown.
			expect(r.Raised).to.equal(false)
			expect(r.Answer).to.equal("false/gift delivery could not be confirmed; do not send it again")

			-- Ambiguous, so the credit stays spent -- on disk as well as in memory.
			local stored = uni.Disk.Keyspace:Read("Default", bundle.Ctx.Persistence.KeyFor(BUYER))
			local scribe = stored and stored.Value and stored.Value.Data and stored.Value.Data._Scribe
			local storedCredits = tonumber(scribe and scribe.GiftCredits and scribe.GiftCredits.CoinsGift) or 0
			expect(`live={r.Live}/stored={storedCredits}`).to.equal("live=0/stored=0")

			-- And it is on the record, with the error that caused it. Nothing else
			-- reports this incident -- deliverGift never reached its own Failure.Report
			-- -- so a silent version of this arm is a payment nobody can trace.
			local entries = bundle.Scribe.GetRecentLogs({ Code = "GIFT_CREDIT_UNCONFIRMED", Limit = 50 })
			expect(#entries).to.equal(1)
			expect(string.find(tostring(entries[1].Context.Error), "the delivery path raised") ~= nil).to.equal(true)
			expect(bundle.Scribe.GetMetrics().GiftCreditsUnconfirmed).to.equal(1)
		end)
	end)
end
