--!nonstrict
-- Receipt history survives replay and refuses growth before paid value moves.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Clock = require(Root.Scribe.Internal.Clock)
	local Util = require(Root.Scribe.Internal.Util)
	local Metrics = require(Root.Scribe.Internal.Metrics)
	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
	local RETRY = Enum.ProductPurchaseDecision.NotProcessedYet
	local BUYER, RECIPIENT = 78301, 78302
	local RETENTION = 30 * 24 * 3600
	local now

	beforeEach(function()
		now = 1800000000
		Clock.Install({
			Now = function()
				return now
			end,
		})
	end)

	afterEach(function()
		Clock.Reset()
	end)

	local function oneReceiptBytes()
		return Util.approxSize({ { Id = "a", At = now } })
	end

	local function receipt(id, productId)
		return { PlayerId = BUYER, ProductId = productId or 101, PurchaseId = id, CurrencySpent = 9 }
	end

	local function make(extra)
		local options = {
			Products = {
				Coins = {
					Id = 101,
					Grant = function(data)
						data.Coins.Increment(1)
					end,
				},
				VIP = { Id = 102, Grants = "VIP" },
				Broken = {
					Id = 103,
					Grant = function(data)
						data.Coins.Increment(1)
						error("no grant")
					end,
				},
			},
			GiftCooldown = 0,
			PromptProductPurchase = function() end,
		}
		for key, value in extra or {} do
			options[key] = value
		end
		return TestCtx.make({ Options = options })
	end

	local function fill(entry)
		entry.Tree.Reserved.ProcessedPurchaseIds.Set({ { Id = "a", At = now } })
	end

	it("refuses a new grant at the byte limit and still acknowledges a saved duplicate", function()
		local h = make({ MaxReceiptHistoryBytes = oneReceiptBytes() })
		local player, entry, data = h.Join(BUYER)
		expect(h.Data.HandleReceipt(receipt("a"))).to.equal(GRANTED)
		local before = Metrics.Get().ReceiptHistoryRefusals or 0
		expect(h.Data.HandleReceipt(receipt("b"))).to.equal(RETRY)
		expect(data.Coins.Get()).to.equal(1)
		expect(h.Data.HandleReceipt(receipt("a"))).to.equal(GRANTED)
		expect(#entry.LiveData._Scribe.ProcessedPurchaseIds).to.equal(1)
		expect((Metrics.Get().ReceiptHistoryRefusals or 0) - before).to.equal(1)
		h.Leave(player)
		local _, _, reloaded = h.Join(BUYER)
		expect(h.Data.HandleReceipt(receipt("a"))).to.equal(GRANTED)
		expect(reloaded.Coins.Get()).to.equal(1)
		h.Cleanup()
	end)

	it("uses thirty days independently of legacy TTL and count options", function()
		local h = make({ PurchaseIdTTL = 1, MaxProcessedPurchaseIds = 1 })
		local _, entry, data = h.Join(BUYER)
		entry.Tree.Reserved.ProcessedPurchaseIds.Set({ { Id = "old", At = now - RETENTION + 1 }, "legacy" })
		for _, id in { "a", "b", "old", "legacy" } do
			expect(h.Data.HandleReceipt(receipt(id))).to.equal(GRANTED)
		end
		expect(data.Coins.Get()).to.equal(2)
		expect(#entry.LiveData._Scribe.ProcessedPurchaseIds).to.equal(4)
		now += 1
		expect(h.Data.HandleReceipt(receipt("old"))).to.equal(GRANTED)
		expect(data.Coins.Get()).to.equal(3)
		expect(entry.LiveData._Scribe.ProcessedPurchaseIds[4].At).to.equal(now)
		h.Cleanup()
	end)

	it("releases capacity after a rolled back grant", function()
		local h = make({ MaxReceiptHistoryBytes = oneReceiptBytes() })
		local _, _, data = h.Join(BUYER)
		expect(h.Data.HandleReceipt(receipt("a", 103))).to.equal(RETRY)
		expect(data.Coins.Get()).to.equal(0)
		expect(h.Data.HandleReceipt(receipt("b"))).to.equal(GRANTED)
		expect(data.Coins.Get()).to.equal(1)
		h.Cleanup()
	end)

	it("expires at thirty days and does not refresh the timestamp on duplicates", function()
		local h = make({ MaxReceiptHistoryBytes = oneReceiptBytes() })
		local player, entry, data = h.Join(BUYER)
		local grantedAt = now
		expect(h.Data.HandleReceipt(receipt("a"))).to.equal(GRANTED)
		expect(entry.LiveData._Scribe.ProcessedPurchaseIds[1].At).to.equal(grantedAt)
		now += RETENTION - 1
		expect(h.Data.HandleReceipt(receipt("a"))).to.equal(GRANTED)
		expect(data.Coins.Get()).to.equal(1)
		expect(entry.LiveData._Scribe.ProcessedPurchaseIds[1].At).to.equal(grantedAt)
		h.Leave(player)
		now += 1
		local _, reloadedEntry, reloadedData = h.Join(BUYER)
		expect(#reloadedEntry.LiveData._Scribe.ProcessedPurchaseIds).to.equal(0)
		expect(h.Data.HandleReceipt(receipt("a"))).to.equal(GRANTED)
		expect(reloadedData.Coins.Get()).to.equal(2)
		expect(reloadedEntry.LiveData._Scribe.ProcessedPurchaseIds[1].At).to.equal(now)
		h.Cleanup()
	end)

	it("reclaims expired capacity during a live session", function()
		local h = make({ MaxReceiptHistoryBytes = oneReceiptBytes() })
		local _, entry, data = h.Join(BUYER)
		expect(h.Data.HandleReceipt(receipt("a"))).to.equal(GRANTED)
		now += RETENTION - 1
		expect(h.Data.HandleReceipt(receipt("b"))).to.equal(RETRY)
		now += 1
		expect(h.Data.HandleReceipt(receipt("b"))).to.equal(GRANTED)
		expect(data.Coins.Get()).to.equal(2)
		expect(#entry.LiveData._Scribe.ProcessedPurchaseIds).to.equal(1)
		expect(entry.LiveData._Scribe.ProcessedPurchaseIds[1].Id).to.equal("b")
		h.Cleanup()
	end)

	it("dates unknown-age IDs once on load and preserves that date on reload", function()
		local h = make()
		local player, entry = h.Join(BUYER)
		entry.Tree.Reserved.ProcessedPurchaseIds.Set({ "legacy", { Id = "undated" } })
		h.Leave(player)
		local adoptedAt = now
		local reloaded, reloadedEntry = h.Join(BUYER)
		for _, record in reloadedEntry.LiveData._Scribe.ProcessedPurchaseIds do
			expect(record.At).to.equal(adoptedAt)
		end
		expect(#reloadedEntry.LiveData._Scribe.ProcessedPurchaseIds).to.equal(2)
		h.Leave(reloaded)
		now += RETENTION - 1
		local again, againEntry, data = h.Join(BUYER)
		expect(h.Data.HandleReceipt(receipt("legacy"))).to.equal(GRANTED)
		expect(data.Coins.Get()).to.equal(0)
		expect(againEntry.LiveData._Scribe.ProcessedPurchaseIds[1].At).to.equal(adoptedAt)
		h.Leave(again)
		now += 1
		local _, expiredEntry = h.Join(BUYER)
		expect(#expiredEntry.LiveData._Scribe.ProcessedPurchaseIds).to.equal(0)
		h.Cleanup()
	end)

	it("counts record timestamps before admitting a grant", function()
		local h = make({ MaxReceiptHistoryBytes = oneReceiptBytes() - 1 })
		local _, entry, data = h.Join(BUYER)
		expect(h.Data.HandleReceipt(receipt("a"))).to.equal(RETRY)
		expect(data.Coins.Get()).to.equal(0)
		expect(#entry.LiveData._Scribe.ProcessedPurchaseIds).to.equal(0)
		h.Cleanup()
	end)

	it("defaults to one MiB of recent receipt records", function()
		local h = make()
		local _, entry, data = h.Join(BUYER)
		local history = { { Id = "", At = now } }
		history[1].Id = string.rep("x", 1024 * 1024 - Util.approxSize(history))
		expect(Util.approxSize(history)).to.equal(1024 * 1024)
		entry.Tree.Reserved.ProcessedPurchaseIds.Set(history)
		expect(h.Data.HandleReceipt(receipt("a"))).to.equal(RETRY)
		expect(data.Coins.Get()).to.equal(0)
		expect(#entry.LiveData._Scribe.ProcessedPurchaseIds).to.equal(1)
		h.Cleanup()
	end)

	it("keeps legacy protection when timestamp migration would exceed profile headroom", function()
		local h = make()
		local player, entry = h.Join(BUYER)
		entry.Tree.Reserved.ProcessedPurchaseIds.Set({ "a" })
		entry.LiveData.Inventory.Padding = ""
		entry.LiveData.Inventory.Padding = string.rep("x", 3800000 - Util.approxSize(entry.LiveData) - 10)
		h.Leave(player)
		local _, reloadedEntry, data = h.Join(BUYER)
		expect(reloadedEntry.LiveData._Scribe.ProcessedPurchaseIds[1]).to.equal("a")
		expect(Util.approxSize(reloadedEntry.LiveData) <= 3800000).to.equal(true)
		expect(h.Data.HandleReceipt(receipt("a"))).to.equal(GRANTED)
		expect(data.Coins.Get()).to.equal(0)
		expect(reloadedEntry.LiveData._Scribe.ProcessedPurchaseIds[1]).to.equal("a")
		reloadedEntry.LiveData.Inventory.Padding = nil
		expect(h.Data.HandleReceipt(receipt("b"))).to.equal(GRANTED)
		expect(reloadedEntry.LiveData._Scribe.ProcessedPurchaseIds[1].Id).to.equal("a")
		expect(reloadedEntry.LiveData._Scribe.ProcessedPurchaseIds[1].At).to.equal(now)
		h.Cleanup()
	end)

	it("reclaims expired history during an offline receipt commit", function()
		local h = make({ MaxReceiptHistoryBytes = oneReceiptBytes() })
		local player, entry = h.Join(BUYER)
		fill(entry)
		h.Leave(player)
		now += RETENTION
		expect(h.Data.HandleReceipt(receipt("b", 102))).to.equal(GRANTED)
		local reserved = h.Fake.Persisted[`Default/PLAYER_{BUYER}`]._Scribe
		expect(reserved.Perks.VIP).to.equal(true)
		expect(#reserved.ProcessedPurchaseIds).to.equal(1)
		expect(reserved.ProcessedPurchaseIds[1].Id).to.equal("b")
		expect(reserved.ProcessedPurchaseIds[1].At).to.equal(now)
		expect(h.Data.HandleReceipt(receipt("b", 102))).to.equal(GRANTED)
		expect(h.Fake.Persisted[`Default/PLAYER_{BUYER}`]._Scribe.GiftCredits.VIP).to.equal(nil)
		h.Cleanup()
	end)

	it("dates legacy IDs during an offline commit without refreshing later duplicates", function()
		local h = make()
		local player, entry = h.Join(BUYER)
		entry.Tree.Reserved.ProcessedPurchaseIds.Set({ "a" })
		h.Leave(player)
		local adoptedAt = now
		expect(h.Data.HandleReceipt(receipt("b", 102))).to.equal(GRANTED)
		local history = h.Fake.Persisted[`Default/PLAYER_{BUYER}`]._Scribe.ProcessedPurchaseIds
		expect(#history).to.equal(2)
		expect(history[1].Id).to.equal("a")
		expect(history[1].At).to.equal(adoptedAt)
		now += RETENTION - 1
		expect(h.Data.HandleReceipt(receipt("a", 102))).to.equal(GRANTED)
		local reserved = h.Fake.Persisted[`Default/PLAYER_{BUYER}`]._Scribe
		expect(reserved.ProcessedPurchaseIds[1].At).to.equal(adoptedAt)
		expect(reserved.GiftCredits.VIP).to.equal(nil)
		h.Cleanup()
	end)

	it("reclaims a gift recipient's expired history before mailbox delivery", function()
		local h = make({ MaxReceiptHistoryBytes = oneReceiptBytes() })
		local player, entry = h.Join(RECIPIENT)
		fill(entry)
		h.Leave(player)
		now += RETENTION
		h.Ctx.Persistence.Store:MessageAsync(`PLAYER_{RECIPIENT}`, {
			ScribeGift = true,
			Product = "VIP",
			PurchaseId = "b",
			GiftId = "gift",
			FromUserId = BUYER,
		})
		local recipient, recipientEntry = h.Join(RECIPIENT)
		expect(h.Data.Owns(recipient, "VIP")).to.equal(true)
		expect(#recipientEntry.LiveData._Scribe.ProcessedPurchaseIds).to.equal(1)
		expect(recipientEntry.LiveData._Scribe.ProcessedPurchaseIds[1].Id).to.equal("b")
		expect(recipientEntry.LiveData._Scribe.ProcessedPurchaseIds[1].At).to.equal(now)
		expect(#(h.Fake.Mailboxes[`Default/PLAYER_{RECIPIENT}`] or {})).to.equal(0)
		h.Cleanup()
	end)

	it("retains pending gift reservations when completed history expires", function()
		local h = make({ MaxReceiptHistoryBytes = oneReceiptBytes() })
		local player, entry = h.Join(BUYER)
		fill(entry)
		entry.Tree.Reserved.ReceiptReservations.b.Set({
			Product = "VIP",
			ProductId = 102,
			RecipientId = RECIPIENT,
			GiftId = "pending",
			FromAim = false,
		})
		h.Leave(player)
		now += RETENTION + 1
		local _, reloadedEntry, data = h.Join(BUYER)
		expect(#reloadedEntry.LiveData._Scribe.ProcessedPurchaseIds).to.equal(0)
		expect(reloadedEntry.LiveData._Scribe.ReceiptReservations.b.RecipientId).to.equal(RECIPIENT)
		expect(h.Data.HandleReceipt(receipt("c"))).to.equal(RETRY)
		expect(data.Coins.Get()).to.equal(0)
		expect(h.Data.HandleReceipt(receipt("b", 102))).to.equal(GRANTED)
		expect(next(reloadedEntry.LiveData._Scribe.ReceiptReservations)).to.equal(nil)
		expect(#h.Fake.Mailboxes[`Default/PLAYER_{RECIPIENT}`]).to.equal(1)
		h.Cleanup()
	end)

	it("keeps an unconfirmed grant deduplicated without reporting it saved", function()
		local h = make({ MaxReceiptHistoryBytes = oneReceiptBytes() })
		local player, entry, data = h.Join(BUYER)
		local await = h.Ctx.Persistence.AwaitSave
		h.Ctx.Persistence.AwaitSave = function()
			return false
		end
		expect(h.Data.HandleReceipt(receipt("a"))).to.equal(RETRY)
		expect(h.Data.HandleReceipt(receipt("a"))).to.equal(RETRY)
		expect(data.Coins.Get()).to.equal(1)
		h.Ctx.Persistence.AwaitSave = await
		expect(h.Data.Flush(player, { Force = true })).to.equal(true)
		expect(h.Data.HandleReceipt(receipt("a"))).to.equal(GRANTED)
		expect(#entry.LiveData._Scribe.ProcessedPurchaseIds).to.equal(1)
		h.Cleanup()
	end)

	for _, offline in { false, true } do
		for _, owned in { false, true } do
			it(
				`refuses a full {if offline then "offline" else "online"} {if owned then "gift credit" else "perk grant"}`,
				function()
					local h = make({ MaxReceiptHistoryBytes = oneReceiptBytes() })
					local player, entry = h.Join(BUYER)
					fill(entry)
					if owned then
						h.Data.GrantPerk(player, "VIP")
					end
					if offline then
						h.Leave(player)
					end
					expect(h.Data.HandleReceipt(receipt("b", 102))).to.equal(RETRY)
					local reserved = if offline
						then h.Fake.Persisted[`Default/PLAYER_{BUYER}`]._Scribe
						else entry.LiveData._Scribe
					expect(reserved.Perks.VIP == true).to.equal(owned)
					expect(reserved.GiftCredits.VIP).to.equal(nil)
					h.Cleanup()
				end
			)
		end

		it(`refuses a full {if offline then "offline" else "online"} buyer before gift delivery`, function()
			local h = make({ MaxReceiptHistoryBytes = oneReceiptBytes() })
			local player, entry = h.Join(BUYER)
			fill(entry)
			entry.Tree.Reserved.PendingGifts["102"].Set({
				RecipientId = RECIPIENT,
				GiftId = "gift",
				Product = "VIP",
				Ts = now,
			})
			if offline then
				h.Leave(player)
			end
			expect(h.Data.HandleReceipt(receipt("b", 102))).to.equal(RETRY)
			expect(#(h.Fake.Mailboxes[`Default/PLAYER_{RECIPIENT}`] or {})).to.equal(0)
			local reserved = if offline
				then h.Fake.Persisted[`Default/PLAYER_{BUYER}`]._Scribe
				else entry.LiveData._Scribe
			expect(reserved.PendingGifts["102"].GiftId).to.equal("gift")
			h.Cleanup()
		end)
	end

	it("keeps a full recipient's paid message queued", function()
		local h = make({ MaxReceiptHistoryBytes = oneReceiptBytes() })
		local player, entry = h.Join(RECIPIENT)
		fill(entry)
		h.Leave(player)
		h.Ctx.Persistence.Store:MessageAsync(`PLAYER_{RECIPIENT}`, {
			ScribeGift = true,
			Product = "VIP",
			PurchaseId = "b",
			GiftId = "gift",
			FromUserId = BUYER,
		})
		local recipient = h.Join(RECIPIENT)
		expect(h.Data.Owns(recipient, "VIP")).to.equal(false)
		expect(#h.Fake.Mailboxes[`Default/PLAYER_{RECIPIENT}`]).to.equal(1)
		h.Cleanup()
	end)

	it("refunds an existing credit when local recipient capacity refuses before granting", function()
		local h = make({ MaxReceiptHistoryBytes = oneReceiptBytes() })
		local buyer, buyerEntry = h.Join(BUYER)
		local recipient, recipientEntry = h.Join(RECIPIENT)
		fill(recipientEntry)
		buyerEntry.Tree.Reserved.GiftCredits.VIP.Set(1)
		expect(h.Data.PromptGift(buyer, "VIP", RECIPIENT)).to.equal(false)
		expect(h.Data.GetGiftCredits(buyer).VIP).to.equal(1)
		expect(h.Data.Owns(recipient, "VIP")).to.equal(false)
		h.Cleanup()
	end)

	it("reserves offline buyer capacity durably before sending", function()
		local h = make({ MaxReceiptHistoryBytes = oneReceiptBytes() })
		local buyer, entry = h.Join(BUYER)
		entry.Tree.Reserved.PendingGifts["102"].Set({
			RecipientId = RECIPIENT,
			GiftId = "gift",
			Product = "VIP",
			Ts = now,
		})
		h.Leave(buyer)
		local store = h.Ctx.Persistence.Store
		local send = store.MessageAsync
		local sawReservation = false
		store.MessageAsync = function(self, key, message)
			local route = h.Fake.Persisted[`Default/PLAYER_{BUYER}`]._Scribe.ReceiptReservations.b
			sawReservation = type(route) == "table" and route.RecipientId == RECIPIENT and route.ProductId == 102
			expect(h.Data.HandleReceipt(receipt("c", 102))).to.equal(RETRY)
			return send(self, key, message)
		end
		expect(h.Data.HandleReceipt(receipt("b", 102))).to.equal(GRANTED)
		expect(sawReservation).to.equal(true)
		local reserved = h.Fake.Persisted[`Default/PLAYER_{BUYER}`]._Scribe
		expect(reserved.ProcessedPurchaseIds[1].Id).to.equal("b")
		expect(next(reserved.ReceiptReservations)).to.equal(nil)
		h.Cleanup()
	end)

	it("does not deliver when the offline reservation cannot be saved", function()
		local h = make({ MaxReceiptHistoryBytes = oneReceiptBytes() })
		local buyer, entry = h.Join(BUYER)
		entry.Tree.Reserved.PendingGifts["102"].Set({
			RecipientId = RECIPIENT,
			GiftId = "gift",
			Product = "VIP",
			Ts = now,
		})
		h.Leave(buyer)
		h.Fake.FailSaves = true
		expect(h.Data.HandleReceipt(receipt("b", 102))).to.equal(RETRY)
		expect(#(h.Fake.Mailboxes[`Default/PLAYER_{RECIPIENT}`] or {})).to.equal(0)
		expect(next(h.Fake.Persisted[`Default/PLAYER_{BUYER}`]._Scribe.ReceiptReservations)).to.equal(nil)
		h.Fake.FailSaves = false
		expect(h.Data.HandleReceipt(receipt("b", 102))).to.equal(GRANTED)
		h.Cleanup()
	end)

	it("counts online grants that have reserved capacity but not finished", function()
		local h
		local nested
		h = make({
			MaxReceiptHistoryBytes = oneReceiptBytes(),
			Products = {
				Coins = {
					Id = 101,
					Grant = function(data)
						nested = h.Data.HandleReceipt(receipt("b", 102))
						data.Coins.Increment(1)
					end,
				},
				VIP = { Id = 102, Grants = "VIP" },
			},
		})
		local player, entry, data = h.Join(BUYER)
		expect(h.Data.HandleReceipt(receipt("a"))).to.equal(GRANTED)
		expect(nested).to.equal(RETRY)
		expect(data.Coins.Get()).to.equal(1)
		expect(h.Data.Owns(player, "VIP")).to.equal(false)
		expect(entry.LiveData._Scribe.ProcessedPurchaseIds[1].Id).to.equal("a")
		h.Cleanup()
	end)

	it("finishes a paid reservation after the configured limit is lowered", function()
		local h = make({ MaxReceiptHistoryBytes = 1 })
		local buyer, entry = h.Join(BUYER)
		entry.Tree.Reserved.ReceiptReservations.a.Set(true)
		entry.Tree.Reserved.PendingGifts["102"].Set({
			RecipientId = RECIPIENT,
			GiftId = "gift",
			Product = "VIP",
			Ts = now,
		})
		h.Leave(buyer)
		expect(h.Data.HandleReceipt(receipt("a", 102))).to.equal(GRANTED)
		local reserved = h.Fake.Persisted[`Default/PLAYER_{BUYER}`]._Scribe
		expect(reserved.ProcessedPurchaseIds[1].Id).to.equal("a")
		expect(next(reserved.ReceiptReservations)).to.equal(nil)
		h.Cleanup()
	end)

	it("checks sender and live recipient independently", function()
		local h = make({ MaxReceiptHistoryBytes = oneReceiptBytes() })
		local _buyer, entry = h.Join(BUYER)
		local recipient, recipientEntry = h.Join(RECIPIENT)
		fill(recipientEntry)
		entry.Tree.Reserved.PendingGifts["102"].Set({
			RecipientId = RECIPIENT,
			GiftId = "gift",
			Product = "VIP",
			Ts = now,
		})
		expect(h.Data.HandleReceipt(receipt("b", 102))).to.equal(RETRY)
		expect(h.Data.Owns(recipient, "VIP")).to.equal(false)
		expect(#entry.LiveData._Scribe.ProcessedPurchaseIds).to.equal(0)
		expect(entry.LiveData._Scribe.PendingGifts["102"].GiftId).to.equal("gift")
		expect(entry.LiveData._Scribe.ReceiptReservations.b.RecipientId).to.equal(RECIPIENT)
		expect(h.Data.HandleReceipt(receipt("c"))).to.equal(RETRY)
		h.Cleanup()
	end)

	it("refuses a nearly full profile before its Grant callback", function()
		local h = make()
		local _, entry, data = h.Join(BUYER)
		entry.LiveData.Inventory.Padding = string.rep("x", 3800000)
		expect(h.Data.HandleReceipt(receipt("a"))).to.equal(RETRY)
		expect(data.Coins.Get()).to.equal(0)
		entry.LiveData.Inventory.Padding = nil
		h.Cleanup()
	end)

	it("bounds recent history by bytes without evicting unexpired markers", function()
		local h = make({ MaxReceiptHistoryBytes = 100 })
		local _, entry, data = h.Join(BUYER)
		local granted = 0
		for i = 1, 40 do
			if h.Data.HandleReceipt(receipt(tostring(i))) == GRANTED then
				granted += 1
			end
		end
		expect(granted > 0 and granted < 40).to.equal(true)
		expect(#entry.LiveData._Scribe.ProcessedPurchaseIds).to.equal(granted)
		expect(Util.approxSize(entry.LiveData._Scribe.ProcessedPurchaseIds) <= 100).to.equal(true)
		expect(h.Data.HandleReceipt(receipt("1"))).to.equal(GRANTED)
		expect(data.Coins.Get()).to.equal(granted)
		h.Cleanup()
	end)

	it("validates the byte guard", function()
		for _, limit in { 0, -1, 1.5, math.huge, 0 / 0, 2097153, "100", false } do
			local ok = pcall(make, { MaxReceiptHistoryBytes = limit })
			expect(ok).to.equal(false)
		end
	end)
end
