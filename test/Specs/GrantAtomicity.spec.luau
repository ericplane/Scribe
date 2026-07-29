--!nonstrict
-- A receipt is retried until it is granted. A product Grant that wrote part-way
-- and then threw used to leave those writes behind while markProcessed never ran,
-- so Roblox re-invoked the callback and re-applied them on every retry.
return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local NOT_PROCESSED = Enum.ProductPurchaseDecision.NotProcessedYet
	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted

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

	it("rolls back a Grant that throws part-way, so retries do not compound it", function()
		local shouldThrow = true
		local harness = TestCtx.make({
			Options = {
				Products = {
					Bundle = {
						Id = 111,
						Grant = function(data)
							data.Coins.Increment(1000)
							if shouldThrow then
								error("second half of the grant failed")
							end
							data.Gems.Increment(5)
						end,
					},
				},
			},
		})
		local _player, _entry, data = harness.Join(70001)

		-- Three retries of the SAME PurchaseId, all failing part-way.
		for _ = 1, 3 do
			expect(harness.Data.HandleReceipt(receipt(70001, 111, "pid-1"))).to.equal(NOT_PROCESSED)
		end
		-- Without the rollback this reads 3000.
		expect(data.Coins.Get()).to.equal(0)
		expect(data.Gems.Get()).to.equal(0)

		-- Once the Grant succeeds it applies exactly once, and is then deduped.
		shouldThrow = false
		expect(harness.Data.HandleReceipt(receipt(70001, 111, "pid-1"))).to.equal(GRANTED)
		expect(data.Coins.Get()).to.equal(1000)
		expect(data.Gems.Get()).to.equal(5)
		expect(harness.Data.HandleReceipt(receipt(70001, 111, "pid-1"))).to.equal(GRANTED)
		expect(data.Coins.Get()).to.equal(1000)

		harness.Cleanup()
	end)

	it("rolls back the perk write when a Grant on the same product throws", function()
		local harness = TestCtx.make({
			Options = {
				Products = {
					VIPBundle = {
						Id = 222,
						Grants = "VIP",
						Grant = function(data)
							data.Coins.Increment(50)
							error("grant blew up")
						end,
					},
				},
			},
		})
		local player, _entry, data = harness.Join(70002)

		expect(harness.Data.HandleReceipt(receipt(70002, 222, "pid-2"))).to.equal(NOT_PROCESSED)
		expect(data.Coins.Get()).to.equal(0)
		-- The perk must not be granted for a receipt that was never processed.
		expect(harness.Data.Owns(player, "VIP")).to.equal(false)

		harness.Cleanup()
	end)

	it("rejects a malformed product Grants at registration, not at purchase time", function()
		-- A wrong type used to be stored unchecked and only surface when a player
		-- actually bought the product: the perk landed under a bad key and Owns kept
		-- answering false, with the Robux already spent.
		expect(function()
			TestCtx.make({ Options = { Products = { Bad = { Id = 901, Grants = 123 } } } })
		end).to.throw()
		expect(function()
			TestCtx.make({ Options = { Products = { Bad = { Id = 902, Grants = "" } } } })
		end).to.throw()

		-- A well-formed one still registers and works.
		local harness = TestCtx.make({
			Options = { Products = { Good = { Id = 903, Grants = "VIP" } } },
		})
		local player = harness.Join(70003)
		expect(harness.Data.HandleReceipt(receipt(70003, 903, "pid-3"))).to.equal(GRANTED)
		expect(harness.Data.Owns(player, "VIP")).to.equal(true)
		harness.Cleanup()
	end)

	it("a yielding Grant still delivers, loudly, instead of retrying forever", function()
		local harness = TestCtx.make({
			Options = {
				Products = {
					Slow = {
						Id = 904,
						Grant = function(data)
							task.wait() -- a yield: cannot be made atomic
							data.Coins.Increment(25)
						end,
					},
				},
			},
		})
		local _player, _entry, data = harness.Join(70004)

		-- Before the fallback this answered NotProcessedYet forever: the player paid
		-- and never received the product.
		expect(harness.Data.HandleReceipt(receipt(70004, 904, "pid-4"))).to.equal(GRANTED)
		expect(data.Coins.Get()).to.equal(25)

		-- ...but it is reported loudly, naming the product and the remedy.
		local logs = Scribe.GetRecentLogs({ Code = "GRANT_FAIL", Limit = 20 })
		local warned = false
		for _, entry in logs do
			if string.find(entry.Message, "yields", 1, true) then
				warned = true
			end
		end
		expect(warned).to.equal(true)

		-- Dedup still holds: the second receipt does not re-run the Grant.
		expect(harness.Data.HandleReceipt(receipt(70004, 904, "pid-4"))).to.equal(GRANTED)
		expect(data.Coins.Get()).to.equal(25)

		harness.Cleanup()
	end)
end
