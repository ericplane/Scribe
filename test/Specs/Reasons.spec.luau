--!nonstrict
-- The exported reason constants, pinned against the code that actually emits them.
--
-- A table of string constants is trivially self-consistent, so asserting the table
-- against itself proves nothing. What matters is that each constant still equals the
-- literal some call site returns -- and several literals are returned from more than
-- one place, so driving one path per constant would let a divergence at the other
-- site through unnoticed. These specs drive the real refusals.
--
-- Deliberately NOT exhaustive over emitting sites: the ones reachable from the test
-- harness are driven, and the rest are covered by the type-check fixtures, which fail
-- if a literal stops being a member of its union.

local TestCtx = require(script.Parent.Parent.Helpers.TestCtx)

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)

	describe("reason constants", function()
		it("are frozen, so a consumer cannot corrupt them for everyone", function()
			-- Module-level tables shared by every bundle in the process.
			for _, tableName in { "RequestReason", "PurchaseReason", "GiftReason" } do
				expect(table.isfrozen(Scribe[tableName])).to.equal(true)
			end
		end)

		it("covers every request reason Scribe itself replies with", function()
			-- The count is asserted so that adding an emitter without adding a
			-- constant fails here rather than silently leaving callers unable to
			-- match on it. "reply-encode-failed" is the one an earlier draft of this
			-- union missed.
			local expected = {
				"rate-limited",
				"not-ready",
				"unknown-command",
				"bad-args",
				"bad-idempotency-key",
				"error",
				"reply-encode-failed",
				"timeout",
				"send-failed",
				"edit-mode",
				"mock-error",
			}
			local seen = {}
			local count = 0
			for _, value in Scribe.RequestReason do
				seen[value] = true
				count += 1
			end
			expect(count).to.equal(#expected)
			for _, reason in expected do
				expect(seen[reason]).to.equal(true)
			end
		end)
	end)

	describe("the constants match what the code returns", function()
		-- One driven refusal per union. Not exhaustive over emitting sites -- several
		-- literals are returned from more than one place, and the type-check fixtures
		-- are what catch a literal drifting out of its union. What these pin is that
		-- the CONSTANT still equals the string the running code produces, which a
		-- table asserted against itself cannot show.
		it("refuses a purchase with no funds using InsufficientFunds", function()
			local harness = TestCtx.make({})
			local player, _entry, data = harness.Join(90002)
			data.Coins.Set(10)

			local ok, reason = harness.Data.Purchase(player, {
				Cost = { Path = "Coins", Amount = 5000 },
				Category = "Test",
				ItemId = "Pricey",
				Grant = function() end,
			})

			expect(ok).to.equal(false)
			expect(reason).to.equal(Scribe.PurchaseReason.InsufficientFunds)
			harness.Cleanup()
		end)

		it("refuses a malformed cost with InvalidCostSpec", function()
			local harness = TestCtx.make({})
			local player = harness.Join(90003)

			local ok, reason = harness.Data.Purchase(player, {
				Cost = { Path = "Coins" }, -- no Amount
				Category = "Test",
				ItemId = "Broken",
				Grant = function() end,
			})

			expect(ok).to.equal(false)
			expect(reason).to.equal(Scribe.PurchaseReason.InvalidCostSpec)
			harness.Cleanup()
		end)
	end)
end
