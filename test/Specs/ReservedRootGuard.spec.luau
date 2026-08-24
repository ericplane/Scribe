--!nonstrict
-- The reserved `_Scribe` root is the library's OWN ledger: the receipt dedupe
-- ring, perks, gift credits, pending gifts, purchase logs, timers, and the
-- migration version. `Scribe.ServerOnly` keeps it off the wire, but visibility is
-- not a write guard -- game code reached it through the ordinary accessor and
-- could clear it. Clearing ProcessedPurchaseIds is a MONEY bug: the next receipt
-- Roblox retries is granted a second time, paid once.
--
-- These specs pin the CONSEQUENCE (a retry does not double-grant, the library's
-- own writes still land) rather than the mechanism that produces it.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Client = require(Root.Scribe.Client)
	local Node = require(Root.Scribe.Internal.Node)
	local Template = require(Root.Scribe.Internal.Template)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
	local RESERVED = Template.RESERVED_ROOT

	-- How many times the product's Grant callback actually ran. This is the
	-- number the whole file exists to hold at 1.
	local grants

	local function makeHarness()
		grants = 0
		return TestCtx.make({
			Template = {
				Coins = Scribe.Int(0, { Min = 0, Max = 1000000 }),
				Bag = {},
				-- The game's OWN server-only field. `_Scribe` is ServerOnly too, so a
				-- guard that keyed on visibility instead of on the reserved path would
				-- lock the developer out of their own data -- see the control below.
				Secret = Scribe.ServerOnly({ Flagged = false }),
			},
			Options = {
				Products = {
					Coins1000 = {
						Id = 111,
						Category = "Currency",
						Grant = function(data)
							grants += 1
							data.Coins.Increment(1000)
						end,
					},
					GiftVIP = { Id = 222, Category = "Gamepass", Grants = "VIP" },
				},
				GiftCooldown = 0,
				PromptProductPurchase = function() end,
			},
		})
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

	local function throwsAbout(fn): string?
		local ok, err = pcall(fn)
		if ok then
			return nil
		end
		return tostring(err)
	end

	describe("the reserved root refuses writes from game code", function()
		it("refuses to clear the receipt ledger, so a retried receipt is not granted twice", function()
			-- The measured live bug, end to end. Without the guard the Set below
			-- succeeds, the dedupe marker is gone, and Roblox's retry re-runs Grant:
			-- coins 1000 -> 2000 for one payment.
			local harness = makeHarness()
			local player, entry, data = harness.Join(81001)

			expect(harness.Data.HandleReceipt(receipt(entry.UserId, 111, "dup-1"))).to.equal(GRANTED)
			expect(grants).to.equal(1)
			expect(data.Coins.Get()).to.equal(1000)
			expect(#data[RESERVED].ProcessedPurchaseIds.Get()).to.equal(1)

			-- Game code tries to wipe the dedupe ring.
			local err = throwsAbout(function()
				data[RESERVED].ProcessedPurchaseIds.Set({})
			end)
			expect(err).to.be.ok()
			expect(string.find(err, RESERVED, 1, true) ~= nil).to.equal(true)

			-- The marker survived, so Roblox's retry is deduped, not re-granted.
			expect(#data[RESERVED].ProcessedPurchaseIds.Get()).to.equal(1)
			expect(harness.Data.HandleReceipt(receipt(entry.UserId, 111, "dup-1"))).to.equal(GRANTED)
			expect(grants).to.equal(1)
			expect(data.Coins.Get()).to.equal(1000)
			expect(#harness.Data.GetPurchases(player, { Kind = "Robux" })).to.equal(1)

			harness.Cleanup()
		end)

		it("refuses EVERY mutator, so a mutator added later is covered without editing this spec", function()
			local harness = makeHarness()
			local _player, _entry, data = harness.Join(81002)

			-- Iterate the canonical table rather than hand-listing: the guard and
			-- this assertion then cannot drift apart.
			local checked = 0
			local missed = {}
			for name in Node.MUTATOR_METHODS do
				checked += 1
				-- Indexing the method is where the refusal happens (same shape as the
				-- derived-field guard), so no call is needed to trigger it.
				local err = throwsAbout(function()
					return data[RESERVED].Perks[name]
				end)
				if err == nil or string.find(err, "cannot be written", 1, true) == nil then
					table.insert(missed, name)
				end
			end
			expect(checked > 0).to.equal(true)
			expect(table.concat(missed, ",")).to.equal("")

			harness.Cleanup()
		end)

		it("refuses at any depth, not just the reserved root's direct children", function()
			local harness = makeHarness()
			local _player, _entry, data = harness.Join(81003)

			local depths = {
				["depth 1"] = function()
					data[RESERVED].Set({})
				end,
				["depth 2"] = function()
					data[RESERVED].Perks.Set({ VIP = true })
				end,
				["depth 3"] = function()
					data[RESERVED].Perks.VIP.Set(true)
				end,
				["depth 4"] = function()
					data[RESERVED].PurchaseLogs.Robux.Clear()
				end,
				["dynamic key"] = function()
					data[RESERVED].GiftCredits["Whatever"].Set(99)
				end,
			}
			local allowed = {}
			for label, fn in depths do
				if throwsAbout(fn) == nil then
					table.insert(allowed, label)
				end
			end
			table.sort(allowed)
			expect(table.concat(allowed, ",")).to.equal("")

			-- And nothing leaked through on the way to those errors.
			expect(next(data[RESERVED].Perks.Get() or {})).to.equal(nil)
			expect(next(data[RESERVED].GiftCredits.Get() or {})).to.equal(nil)

			harness.Cleanup()
		end)

		it("names the reserved root and points at the API that owns the ledger", function()
			local harness = makeHarness()
			local _player, _entry, data = harness.Join(81004)

			local err = throwsAbout(function()
				data[RESERVED].GiftCredits.Set({})
			end) :: string
			expect(err).to.be.ok()
			-- The path the developer actually wrote.
			expect(string.find(err, `{RESERVED}.GiftCredits`, 1, true) ~= nil).to.equal(true)
			-- What to use instead, so the error ends the investigation.
			expect(string.find(err, "GetGiftCredits", 1, true) ~= nil).to.equal(true)

			harness.Cleanup()
		end)
	end)

	describe("reads are untouched", function()
		it("still reads the reserved root, at the root and nested", function()
			local harness = makeHarness()
			local player, entry, data = harness.Join(81005)
			harness.Data.GrantPerk(player, "VIP")
			harness.Data.HandleReceipt(receipt(entry.UserId, 111, "read-1"))

			-- Whole reserved subtree.
			local whole = data[RESERVED].Get()
			expect(type(whole)).to.equal("table")
			expect(whole.Perks.VIP).to.equal(true)

			-- Nested, at three depths.
			expect(data[RESERVED].Version.Get()).to.be.ok()
			expect(data[RESERVED].Perks.VIP.Get()).to.equal(true)
			expect(#data[RESERVED].ProcessedPurchaseIds.Get()).to.equal(1)
			expect(data[RESERVED].ProcessedPurchaseIds.Get()[1].Id).to.equal("read-1")

			-- Non-mutating methods are reachable too: refusing them would break the
			-- client's perk mirror, which subscribes to _Scribe.Perks.
			local fired = 0
			local disconnect = data[RESERVED].Perks.Changed(function()
				fired += 1
			end)
			expect(type(disconnect)).to.equal("function")
			disconnect()

			harness.Cleanup()
		end)
	end)

	describe("a reader cannot write through what a read handed back", function()
		-- The write guard above refuses every MUTATOR. It was still bypassable,
		-- because `.Get()` is not a mutator: it returned the LIVE STORED TABLE, and
		-- three lines of ordinary game code walked around the whole thing.
		it("closes the three-line bypass: clearing what .Get() returned does not clear the ledger", function()
			local harness = makeHarness()
			local player, entry, data = harness.Join(81010)

			expect(harness.Data.HandleReceipt(receipt(entry.UserId, 111, "bypass-1"))).to.equal(GRANTED)
			expect(grants).to.equal(1)
			expect(data.Coins.Get()).to.equal(1000)

			-- The bypass, verbatim. No mutator is called anywhere in it.
			local ledger = data[RESERVED].ProcessedPurchaseIds.Get()
			expect(#ledger).to.equal(1)
			table.clear(ledger)
			-- The COPY really was cleared -- the caller is not being lied to, and this
			-- assertion is what keeps the case honest if table.clear ever no-ops.
			expect(#ledger).to.equal(0)

			-- ...and it was a copy: the stored ring never moved.
			expect(ledger).never.to.equal(entry.LiveData[RESERVED].ProcessedPurchaseIds)
			expect(#entry.LiveData[RESERVED].ProcessedPurchaseIds).to.equal(1)
			expect(#data[RESERVED].ProcessedPurchaseIds.Get()).to.equal(1)

			-- THE CONSEQUENCE, which is the only reason any of this matters: Roblox
			-- retries the receipt and it is DEDUPED, not granted a second time.
			expect(harness.Data.HandleReceipt(receipt(entry.UserId, 111, "bypass-1"))).to.equal(GRANTED)
			expect(grants).to.equal(1)
			expect(data.Coins.Get()).to.equal(1000)
			expect(#harness.Data.GetPurchases(player, { Kind = "Robux" })).to.equal(1)

			harness.Cleanup()
		end)

		it("closes it AT DEPTH: a nested record inside the copy is not the stored one", function()
			-- A SHALLOW copy would pass the case above and fail this one: fresh outer
			-- tables holding the same inner records, so the hole moves down one level
			-- instead of closing. The ledger nests -- PurchaseLogs.Robux is a ring of
			-- receipt records and ProcessedPurchaseIds a ring of { Id, At } -- so depth
			-- is where it actually lives.
			local harness = makeHarness()
			local _player, entry, data = harness.Join(81011)
			expect(harness.Data.HandleReceipt(receipt(entry.UserId, 111, "deep-1"))).to.equal(GRANTED)

			local storedLog = entry.LiveData[RESERVED].PurchaseLogs.Robux
			expect(#storedLog).to.equal(1)
			local storedId = storedLog[1].PurchaseId
			expect(storedId).to.equal("deep-1")

			-- One level below the container that was read.
			local ring = data[RESERVED].PurchaseLogs.Robux.Get()
			expect(#ring).to.equal(1)
			expect(ring[1]).never.to.equal(storedLog[1])
			ring[1].PurchaseId = "forged"
			table.clear(ring[1])
			expect(storedLog[1].PurchaseId).to.equal(storedId)

			-- TWO levels below: read the PurchaseLogs container, reach through .Robux.
			local logs = data[RESERVED].PurchaseLogs.Get()
			expect(logs.Robux[1]).never.to.equal(storedLog[1])
			logs.Robux[1].PurchaseId = "forged"
			table.clear(logs.Robux)
			expect(#storedLog).to.equal(1)
			expect(storedLog[1].PurchaseId).to.equal(storedId)

			-- THREE levels below: the whole reserved subtree in one read.
			local whole = data[RESERVED].Get()
			expect(whole.PurchaseLogs.Robux[1]).never.to.equal(storedLog[1])
			whole.PurchaseLogs.Robux[1].PurchaseId = "forged"
			table.clear(whole.ProcessedPurchaseIds)
			whole.Perks.Cheat = true
			expect(storedLog[1].PurchaseId).to.equal(storedId)
			expect(entry.LiveData[RESERVED].Perks.Cheat).to.equal(nil)

			-- And the dedupe record itself, which is the { Id, At } pair a retry is
			-- matched against: blanking it in the copy must not un-dedupe the purchase.
			local processed = data[RESERVED].ProcessedPurchaseIds.Get()
			expect(type(processed[1])).to.equal("table")
			processed[1].Id = "forged"
			expect(entry.LiveData[RESERVED].ProcessedPurchaseIds[1].Id).to.equal("deep-1")

			-- The consequence, after all four attempts.
			expect(harness.Data.HandleReceipt(receipt(entry.UserId, 111, "deep-1"))).to.equal(GRANTED)
			expect(grants).to.equal(1)
			expect(data.Coins.Get()).to.equal(1000)

			harness.Cleanup()
		end)

		it("closes it for LISTENERS too, which are readers wearing a callback", function()
			local harness = makeHarness()
			local _player, entry, data = harness.Join(81012)

			-- Changed on the reserved container: without the guard this fires with the
			-- live Perks table, and a listener can empty it from inside its own handler.
			local seen: any = nil
			local disconnect = data[RESERVED].Perks.Changed(function(new)
				seen = new
				if type(new) == "table" then
					table.clear(new)
					new.Cheat = true
				end
			end)
			harness.Data.GrantPerk(_player, "VIP")
			expect(type(seen)).to.equal("table")
			expect(harness.Data.Owns(_player, "VIP")).to.equal(true)
			expect(entry.LiveData[RESERVED].Perks.VIP).to.equal(true)
			expect(entry.LiveData[RESERVED].Perks.Cheat).to.equal(nil)
			disconnect()

			-- Observe takes the same path and gets the same treatment, including its
			-- immediate first call.
			local first: any = nil
			local stop = data[RESERVED].PurchaseLogs.Robux.Observe(function(value)
				if first == nil then
					first = value
				end
				if type(value) == "table" then
					table.clear(value)
				end
			end)
			expect(type(first)).to.equal("table")
			expect(first).never.to.equal(entry.LiveData[RESERVED].PurchaseLogs.Robux)
			expect(harness.Data.HandleReceipt(receipt(entry.UserId, 111, "listen-1"))).to.equal(GRANTED)
			expect(#entry.LiveData[RESERVED].PurchaseLogs.Robux).to.equal(1)
			stop()

			-- ...and so does an ENTRY listener, which receives one RECORD rather than
			-- the container. The purchase log is appended with Insert (the dedupe ring
			-- is rewritten with a single Set, so it fires no OnInsert), and blanking a
			-- record handed to a listener would forge the game's own purchase history.
			local record: any = nil
			local stopEntry = data[RESERVED].PurchaseLogs.Robux.OnInsert(function(value)
				record = value
				if type(value) == "table" then
					value.PriceInRobux = 0
					table.clear(value)
				end
			end)
			expect(harness.Data.HandleReceipt(receipt(entry.UserId, 111, "listen-2"))).to.equal(GRANTED)
			expect(type(record)).to.equal("table")
			local stored = entry.LiveData[RESERVED].PurchaseLogs.Robux
			expect(record).never.to.equal(stored[#stored])
			expect(stored[#stored].PurchaseId).to.equal("listen-2")
			expect(stored[#stored].PriceInRobux).to.equal(99)
			stopEntry()

			-- Two receipts, two grants -- and each is still deduped on retry.
			expect(grants).to.equal(2)
			expect(harness.Data.HandleReceipt(receipt(entry.UserId, 111, "listen-1"))).to.equal(GRANTED)
			expect(harness.Data.HandleReceipt(receipt(entry.UserId, 111, "listen-2"))).to.equal(GRANTED)
			expect(grants).to.equal(2)

			harness.Cleanup()
		end)

		it("CONTROL: the LIBRARY's own reads are still live, and its writes still land", function()
			-- The refusal is by CALLER, not by object -- the same split the write guard
			-- makes. If a later change copied unconditionally, the library would be
			-- reading detached snapshots of its own ledger: every write below would
			-- keep working while the reads that guard them silently stopped seeing them.
			local harness = makeHarness()
			local buyer, entry, data = harness.Join(81013)

			local reserved = entry.Tree.Reserved
			expect(reserved.Get()).to.equal(entry.LiveData[RESERVED])
			expect(reserved.ProcessedPurchaseIds.Get()).to.equal(entry.LiveData[RESERVED].ProcessedPurchaseIds)
			expect(reserved.PurchaseLogs.Robux.Get()).to.equal(entry.LiveData[RESERVED].PurchaseLogs.Robux)
			-- Same object on every read, which is what "live" means...
			expect(reserved.Perks.Get()).to.equal(reserved.Perks.Get())
			-- ...and the public handle is the other side of the split: a FRESH copy
			-- every time, never the stored table.
			expect(data[RESERVED].Perks.Get()).never.to.equal(data[RESERVED].Perks.Get())
			expect(data[RESERVED].Perks.Get()).never.to.equal(entry.LiveData[RESERVED].Perks)

			-- End to end, through the APIs that own the ledger: a real receipt, a
			-- perk, and a gift credit spent on someone else.
			expect(harness.Data.HandleReceipt(receipt(entry.UserId, 111, "live-1"))).to.equal(GRANTED)
			expect(grants).to.equal(1)
			expect(data.Coins.Get()).to.equal(1000)
			expect(#harness.Data.GetPurchases(buyer, { Kind = "Robux" })).to.equal(1)

			harness.Data.GrantPerk(buyer, "VIP")
			expect(harness.Data.Owns(buyer, "VIP")).to.equal(true)
			harness.Data.RevokePerk(buyer, "VIP")
			expect(harness.Data.Owns(buyer, "VIP")).to.equal(false)

			expect(harness.Data.HandleReceipt(receipt(entry.UserId, 222, "live-2"))).to.equal(GRANTED)
			expect(harness.Data.Owns(buyer, "VIP")).to.equal(true)
			expect(harness.Data.HandleReceipt(receipt(entry.UserId, 222, "live-3"))).to.equal(GRANTED)
			expect(harness.Data.GetGiftCredits(buyer).GiftVIP).to.equal(1)

			local recipient = harness.Join(81014)
			expect(harness.Data.PromptGift(buyer, "GiftVIP", 81014)).to.equal(true)
			expect(harness.Data.GetGiftCredits(buyer).GiftVIP).to.equal(nil)
			expect(harness.Data.Owns(recipient, "VIP")).to.equal(true)

			-- The ledger the library wrote through is the one that persists.
			local persisted = harness.Fake.Persisted[`Default/PLAYER_{entry.UserId}`]
			expect(#persisted[RESERVED].ProcessedPurchaseIds).to.equal(3)

			harness.Cleanup()
		end)

		it("CONTROL, LOAD-BEARING: an ORDINARY container still returns its LIVE table", function()
			-- This is not incidental. A gameplay container handing back the stored
			-- table is deliberate and documented, and copying every container read was
			-- declined on purpose: it charges every reader to stop a writer. The
			-- reserved root is the ONE exception. If someone later "fixes" the aliasing
			-- globally, this case fails first and says why.
			local harness = makeHarness()
			local _player, entry, data = harness.Join(81015)

			data.Bag.Sword.Set({ Qty = 1 })
			local bag = data.Bag.Get()
			expect(bag).to.equal(entry.LiveData.Bag)
			expect(data.Bag.Get()).to.equal(bag) -- the same object on every read
			local sword = data.Bag.Sword.Get()
			expect(sword).to.equal(entry.LiveData.Bag.Sword)

			-- ...and it is genuinely live in both directions.
			sword.Qty = 7
			expect(data.Bag.Sword.Qty.Get()).to.equal(7)
			expect(entry.LiveData.Bag.Sword.Qty).to.equal(7)

			-- A listener on an ordinary container is handed the live table too.
			local seen: any = nil
			local disconnect = data.Bag.Changed(function(new)
				seen = new
			end)
			data.Bag.Shield.Set({ Qty = 2 })
			expect(seen).to.equal(entry.LiveData.Bag)
			disconnect()

			-- The game's own ServerOnly field, which is what a guard keyed on
			-- VISIBILITY rather than on the reserved path would have taken away: `_Scribe`
			-- is ServerOnly too.
			data.Secret.Flagged.Set(true)
			expect(data.Secret.Get()).to.equal(entry.LiveData.Secret)

			-- Clone() remains the opt-in copy, for ordinary containers and the
			-- reserved root alike.
			expect(data.Bag.Clone()).never.to.equal(entry.LiveData.Bag)
			expect(data.Bag.Clone().Sword.Qty).to.equal(7)

			harness.Cleanup()
		end)
	end)

	describe("controls", function()
		it("the library's own writes still land: a receipt, a perk grant, and a gift credit", function()
			local harness = makeHarness()
			local buyer, entry, data = harness.Join(81006)

			-- (1) A real receipt: grant + durable dedupe marker + purchase log.
			expect(harness.Data.HandleReceipt(receipt(entry.UserId, 111, "ctl-1"))).to.equal(GRANTED)
			expect(grants).to.equal(1)
			expect(data.Coins.Get()).to.equal(1000)
			expect(#harness.Data.GetPurchases(buyer, { Kind = "Robux" })).to.equal(1)
			local persisted = harness.Fake.Persisted[`Default/PLAYER_{entry.UserId}`]
			expect(#persisted[RESERVED].ProcessedPurchaseIds).to.equal(1)

			-- (2) A perk grant, and its revoke.
			harness.Data.GrantPerk(buyer, "VIP")
			expect(harness.Data.Owns(buyer, "VIP")).to.equal(true)
			expect(entry.LiveData[RESERVED].Perks.VIP).to.equal(true)
			harness.Data.RevokePerk(buyer, "VIP")
			expect(harness.Data.Owns(buyer, "VIP")).to.equal(false)

			-- (3) A gift credit, minted by the no-intent path once the buyer owns
			-- the perk -- this writes GiftCredits AND clears a PendingGifts slot.
			expect(harness.Data.HandleReceipt(receipt(entry.UserId, 222, "ctl-2"))).to.equal(GRANTED)
			expect(harness.Data.Owns(buyer, "VIP")).to.equal(true)
			expect(harness.Data.HandleReceipt(receipt(entry.UserId, 222, "ctl-3"))).to.equal(GRANTED)
			expect(harness.Data.GetGiftCredits(buyer).GiftVIP).to.equal(1)

			-- ...and the credit is spendable, which is the reserved root being
			-- written a fourth time (credit consumed, recipient's perk granted).
			local recipient = harness.Join(81007)
			expect(harness.Data.PromptGift(buyer, "GiftVIP", 81007)).to.equal(true)
			expect(harness.Data.GetGiftCredits(buyer).GiftVIP).to.equal(nil)
			expect(harness.Data.Owns(recipient, "VIP")).to.equal(true)

			harness.Cleanup()
		end)

		it("ordinary game fields are completely unaffected", function()
			local harness = makeHarness()
			local _player, entry, data = harness.Join(81008)

			data.Coins.Set(5)
			data.Coins.Increment(10)
			data.Coins.Decrement(3)
			expect(data.Coins.Get()).to.equal(12)

			data.Bag.Sword.Set({ Qty = 1 })
			data.Bag.Sword.Qty.Increment(2)
			expect(data.Bag.Sword.Qty.Get()).to.equal(3)
			data.Bag.Sword.Set(nil)
			expect(data.Bag.Get().Sword).to.equal(nil)

			-- A field whose NAME merely starts like the reserved root is a normal
			-- field: the guard keys on the first path segment, not a prefix match.
			data.Bag["_ScribeLike"].Set(1)
			expect(data.Bag["_ScribeLike"].Get()).to.equal(1)

			-- The game's own ServerOnly field is still writable. `_Scribe` is also
			-- ServerOnly, so keying the guard on VISIBILITY -- the thing that looks
			-- like it already protects the reserved root -- would silently take this
			-- away, and every game that keeps admin state in a ServerOnly field with it.
			data.Secret.Flagged.Set(true)
			expect(data.Secret.Flagged.Get()).to.equal(true)
			data.Secret.Set({ Flagged = false })
			expect(data.Secret.Flagged.Get()).to.equal(false)

			expect(entry.LiveData.Coins).to.equal(12)

			harness.Cleanup()
		end)

		it("the CLIENT's edit-mode Data.Mock still seeds Scribe's ledgers", function()
			-- Data.Mock is the one place OUTSIDE Monetization that writes the reserved
			-- root through an accessor, and nothing in the suite drove its scribeState
			-- branch before this: without the privileged handle it would throw the
			-- guard's error at every storybook that seeds a perk.
			local options = {
				Template = { Coins = Scribe.Int(0, { Min = 0 }) },
				ProfileStoreIndex = "ReservedRootGuardSpec",
				ProfileKeyPrefix = "PLAYER_",
				IsRunning = false, -- edit mode
				Banner = false,
			}
			local compiled = Template.Compile(options.Template, {})
			local clientData = Client.new(options, compiled)

			expect(clientData.Owns("VIP")).to.equal(false)
			clientData.Mock({ Coins = 42 }, {
				Perks = { "VIP" },
				GiftCredits = { GiftVIP = 2 },
				PurchaseLogs = {
					Robux = { { PurchaseId = "mock-1", Product = "Coins1000", PriceInRobux = 99, At = 1 } },
				},
			})

			expect(clientData.Coins.Get()).to.equal(42)
			expect(clientData.Owns("VIP")).to.equal(true)
			expect(clientData.GetGiftCredits().GiftVIP).to.equal(2)
			local purchases = clientData.GetPurchases({ Kind = "Robux" })
			expect(#purchases).to.equal(1)
			expect(purchases[1].PurchaseId).to.equal("mock-1")

			-- ...while the client's PUBLIC accessor refuses the same write, exactly as
			-- the server's does. The mirror is a replica, but it is still Scribe's.
			expect(function()
				clientData[RESERVED].Perks.Cheat.Set(true)
			end).to.throw()
			expect(clientData.Owns("Cheat")).to.equal(false)
		end)

		it("the privileged handle is not reachable from an accessor a developer holds", function()
			-- A guard on the accessor is only worth what its escape hatches are worth.
			-- The Tree carries ApplyOp and Params.Stores.Persist -- raw writes that skip
			-- the accessor entirely -- and it hangs the privileged reserved handle, so
			-- reaching a Tree from game code would make every assertion above cosmetic.
			local harness = makeHarness()
			local _player, entry, data = harness.Join(81009)

			-- The Tree really is a write primitive, which is why it must not leak.
			expect(type(entry.Tree.ApplyOp)).to.equal("function")
			expect(type(entry.Tree.Params.Stores.Persist)).to.equal("table")

			-- Indexing the accessor's own internal field names yields ordinary child
			-- accessors (or a refusal) -- never the Tree, never the privileged handle,
			-- never the live path/schema tables. rawget misses for the same reason.
			local leaks = {}
			for _, name in { "_tree", "_path", "_schema", "_children", "_key", "Reserved" } do
				local ok, got = pcall(function()
					return data[name]
				end)
				if ok and (got == entry.Tree or got == entry.Tree.Reserved) then
					table.insert(leaks, `index {name}`)
				end
				local raw = rawget(data, name)
				if raw == entry.Tree or raw == entry.Tree.Reserved or type(raw) == "table" then
					table.insert(leaks, `rawget {name}`)
				end
			end
			table.sort(leaks)
			expect(table.concat(leaks, ",")).to.equal("")

			-- The capability is not a FIELD, so writing a plausible one onto the very
			-- node you are about to write does not grant it. A flag kept on the
			-- accessor (or on the Tree) would be exactly this rawset away from being
			-- no guard at all.
			local flags = { "_privileged", "Privileged", "_internal", "_library", "_reserved" }
			local granted = {}
			local targets = {
				["the reserved root"] = data[RESERVED],
				["a child of it"] = data[RESERVED].ProcessedPurchaseIds,
				["a grandchild of it"] = data[RESERVED].Perks.VIP,
			}
			for label, node in targets do
				for _, flag in flags do
					rawset(node, flag, true)
				end
				if pcall(function()
					node.Set({})
				end) then
					table.insert(granted, label)
				end
			end
			table.sort(granted)
			expect(table.concat(granted, ",")).to.equal("")

			-- The library's handle is a DIFFERENT object from the public child, and it
			-- is the one that writes.
			expect(entry.Tree.Reserved).never.to.equal(data[RESERVED])
			entry.Tree.Reserved.GiftCredits.Manual.Set(4)
			expect(data[RESERVED].GiftCredits.Manual.Get()).to.equal(4)
			expect(function()
				data[RESERVED].GiftCredits.Manual.Set(9)
			end).to.throw()
			expect(data[RESERVED].GiftCredits.Manual.Get()).to.equal(4)

			harness.Cleanup()
		end)
	end)
end
