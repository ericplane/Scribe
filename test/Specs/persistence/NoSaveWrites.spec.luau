--!nonstrict
-- Mode = "NoSave" never writes the real store. The session path honoured that; the
-- offline verbs and an offline gift delivery did not.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local USER = 97701
	local KEY = "Default/PLAYER_97701"

	--- A stored profile with a real value in it, then a NoSave bundle over the same store.
	local function noSaveOver(stored)
		local first = TestCtx.make()
		local player, _, data = first.Join(USER)
		data.Coins.Set(50)
		first.Data.Flush(player)
		first.Data.Flush(player)
		first.Leave(player)
		local versions = first.Data.ListVersions(USER)
		first.Cleanup()
		stored.Versions = versions
		return TestCtx.make({ Fake = first.Fake, Options = { Mode = "NoSave", UseMock = nil } })
	end

	it("refuses UpdateOffline and leaves the stored profile as it was", function()
		local stored = {}
		local harness = noSaveOver(stored)
		local ok, reason = harness.Data.UpdateOffline(USER, function(data)
			data.Coins = 999
		end)
		expect(
			`ok={tostring(ok)} coins={harness.Fake.Persisted[KEY].Coins} named={tostring(
				string.find(tostring(reason), "NoSave", 1, true) ~= nil
			)}`
		).to.equal("ok=false coins=50 named=true")
		harness.Cleanup()
	end)

	it("refuses RestoreVersion", function()
		local stored = {}
		local harness = noSaveOver(stored)
		expect(#stored.Versions >= 2).to.equal(true)
		local ok, reason = harness.Data.RestoreVersion(USER, stored.Versions[#stored.Versions].VersionId)
		expect(
			`ok={tostring(ok)} coins={harness.Fake.Persisted[KEY].Coins} named={tostring(
				string.find(tostring(reason), "NoSave", 1, true) ~= nil
			)}`
		).to.equal("ok=false coins=50 named=true")
		harness.Cleanup()
	end)

	it("refuses Erase and keeps the key", function()
		local stored = {}
		local harness = noSaveOver(stored)
		local ok, reason = harness.Data.Erase(USER)
		expect(
			`ok={tostring(ok)} kept={tostring(harness.Fake.Persisted[KEY] ~= nil)} named={tostring(
				string.find(tostring(reason), "NoSave", 1, true) ~= nil
			)}`
		).to.equal("ok=false kept=true named=true")
		harness.Cleanup()
	end)

	it("refuses to deliver a paid gift to an offline recipient, which also goes by message", function()
		-- The intent comes from a live session; the receipt lands on a NoSave bundle.
		local gifting = {
			Products = { GiftVIP = { Id = 222, Category = "Gamepass", Grants = "VIP" } },
			GiftCooldown = 0,
			PromptProductPurchase = function() end,
		}
		local first = TestCtx.make({ Options = gifting })
		local seeded = first.Join(USER)
		expect(first.Data.PromptGift(seeded, "GiftVIP", 424242)).to.equal(true)
		first.Data.Flush(seeded)
		first.Leave(seeded)
		first.Cleanup()
		local options = { Mode = "NoSave", UseMock = nil }
		for key, value in gifting do
			options[key] = value
		end
		local harness = TestCtx.make({ Fake = first.Fake, Options = options })
		harness.Join(USER)
		local decision = harness.Data.HandleReceipt({
			PlayerId = USER,
			ProductId = 222,
			PurchaseId = "nosave-gift",
			CurrencySpent = 99,
			CurrencyType = Enum.CurrencyType.Robux,
			PlaceIdWherePurchased = 0,
		})
		local mailbox = harness.Fake.Mailboxes["Default/PLAYER_424242"]
		expect(
			`decision={if decision == Enum.ProductPurchaseDecision.NotProcessedYet then "NotProcessed" else "Granted"} queued={if mailbox
				then #mailbox
				else 0}`
		).to.equal("decision=NotProcessed queued=0")
		harness.Cleanup()
	end)

	it("refuses SendMessage and queues nothing", function()
		local stored = {}
		local harness = noSaveOver(stored)
		local ok = harness.Data.SendMessage(USER, { Kind = "test" })
		local mailbox = harness.Fake.Mailboxes[KEY]
		expect(`ok={tostring(ok)} queued={if mailbox then #mailbox else 0}`).to.equal("ok=false queued=0")
		harness.Cleanup()
	end)
end
