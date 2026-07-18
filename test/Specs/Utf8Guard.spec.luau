--!nonstrict
-- Regression tests for the UTF-8 write guards. A string or JSON object key with
-- invalid UTF-8 bytes fails the ENTIRE DataStore profile save (error 104), so it
-- must be rejected (or, for MaxLength, truncated safely) at the write boundary and
-- never reach the store. Covers runtime values, runtime keys, MaxLength clamping,
-- and compile-time template validation.

return function()
	local Root = script.Parent.Parent.Parent
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	-- 0xFF/0xFE never appear in valid UTF-8, so utf8.len rejects this outright.
	local BAD = string.char(0xFF, 0xFE)
	local SMILE = utf8.char(0x1F600) -- U+1F600, a valid 4-byte character

	describe("string value guard", function()
		it("rejects a declared String field set to invalid UTF-8", function()
			local harness = TestCtx.make()
			local _, _, data = harness.Join()
			expect(function()
				data.Nick.Set(BAD)
			end).to.throw()
			expect(data.Nick.Get()).to.equal("") -- unchanged
			harness.Cleanup()
		end)

		it("rejects invalid UTF-8 in an untyped (any) dynamic value", function()
			local harness = TestCtx.make()
			local _, _, data = harness.Join()
			expect(function()
				data.Inventory.Set({ Sword = BAD })
			end).to.throw()
			harness.Cleanup()
		end)

		it("fires OnAnomaly with reason InvalidUtf8 at the offending path", function()
			local harness = TestCtx.make()
			local _, _, data = harness.Join()
			local seen = nil
			harness.Ctx.Signals.OnAnomaly:Connect(function(info)
				if info.Reason == "InvalidUtf8" then
					seen = info
				end
			end)
			pcall(function()
				data.Nick.Set(BAD)
			end)
			expect(seen ~= nil).to.equal(true)
			expect(seen.Path[1]).to.equal("Nick")
			harness.Cleanup()
		end)

		it("accepts a valid multi-byte (emoji) string", function()
			local harness = TestCtx.make()
			local _, _, data = harness.Join()
			data.Nick.Set(SMILE) -- 4 bytes, within MaxLength 8
			expect(data.Nick.Get()).to.equal(SMILE)
			expect(utf8.len(data.Nick.Get()) ~= nil).to.equal(true)
			harness.Cleanup()
		end)
	end)

	describe("MaxLength truncation stays valid UTF-8", function()
		it("drops a multi-byte character that straddles the byte limit", function()
			local harness = TestCtx.make() -- Nick has MaxLength = 8
			local _, _, data = harness.Join()
			-- "aaaaa" (5 bytes) + 4-byte emoji = 9 bytes. A raw string.sub to 8 bytes
			-- would split the emoji into an invalid half-character; the guard must
			-- instead drop the whole straddling character.
			data.Nick.Set("aaaaa" .. SMILE)
			local stored = data.Nick.Get()
			expect(#stored <= 8).to.equal(true)
			expect(utf8.len(stored) ~= nil).to.equal(true) -- valid, not a half-char
			expect(stored).to.equal("aaaaa")
			harness.Cleanup()
		end)

		it("keeps whole characters that fit exactly", function()
			local harness = TestCtx.make()
			local _, _, data = harness.Join()
			local two = SMILE .. utf8.char(0x1F601) -- exactly 8 bytes
			data.Nick.Set(two .. utf8.char(0x1F602)) -- 12 bytes -> clamps to 8
			local stored = data.Nick.Get()
			expect(stored).to.equal(two)
			expect(utf8.len(stored)).to.equal(2)
			harness.Cleanup()
		end)
	end)

	describe("key guards", function()
		it("rejects a dynamic dictionary key with invalid UTF-8", function()
			local harness = TestCtx.make()
			local _, _, data = harness.Join()
			expect(function()
				local _ = data.Inventory[BAD] -- indexing builds the path segment
			end).to.throw()
			harness.Cleanup()
		end)

		it("rejects an invalid-UTF-8 key inside a written table", function()
			local harness = TestCtx.make()
			local _, _, data = harness.Join()
			expect(function()
				data.Inventory.Set({ [BAD] = { qty = 1 } })
			end).to.throw()
			harness.Cleanup()
		end)
	end)

	describe("template compile-time checks", function()
		it("rejects a field name with invalid UTF-8", function()
			expect(function()
				TestCtx.make({ Template = { [BAD] = 0 } })
			end).to.throw()
		end)

		it("rejects a string default with invalid UTF-8", function()
			expect(function()
				TestCtx.make({ Template = { Motto = BAD } })
			end).to.throw()
		end)

		it("rejects an invalid-UTF-8 key in a default data blob", function()
			expect(function()
				TestCtx.make({ Template = { Bag = { [BAD] = 1 } } })
			end).to.throw()
		end)
	end)

	-- Raw-table save boundaries that bypass Node.validateWrite: these mutate
	-- profile.Data directly, so they get their own deep UTF-8 scan.
	describe("raw-table save boundaries", function()
		it("UpdateOffline rejects invalid UTF-8 and does not persist", function()
			local harness = TestCtx.make()
			local key = "Default/PLAYER_70001"
			harness.Fake.Persisted[key] = { Coins = 5 }
			local ok, reason = harness.Data.UpdateOffline(70001, function(data)
				data.Nick = BAD
			end)
			expect(ok).to.equal(false)
			expect(string.find(tostring(reason), "UTF%-8") ~= nil).to.equal(true)
			-- The bad write never reached SetAsync; the original is intact.
			expect(harness.Fake.Persisted[key].Coins).to.equal(5)
			expect(harness.Fake.Persisted[key].Nick).to.equal(nil)
			harness.Cleanup()
		end)

		it("OnPlayerInit invalid UTF-8 fires InvalidUtf8 (non-fatal) at the path", function()
			local harness = TestCtx.make({
				Options = {
					OnPlayerInit = function(_, data)
						data.Nick = BAD
					end,
				},
			})
			local fired = nil
			harness.Ctx.Signals.OnAnomaly:Connect(function(info)
				if info.Reason == "InvalidUtf8" then
					fired = info
				end
			end)
			local _, _, data = harness.Join() -- load still completes
			expect(data).never.to.equal(nil)
			expect(fired ~= nil).to.equal(true)
			expect(fired.Path[#fired.Path]).to.equal("Nick")
			harness.Cleanup()
		end)

		it("fails a load closed when a migration produces invalid UTF-8", function()
			local harness = TestCtx.make({
				Options = {
					Migrations = {
						[2] = function(data)
							data.Nick = BAD
						end,
					},
				},
			})
			local key = "Default/PLAYER_70050"
			harness.Fake.Persisted[key] = { Coins = 7 } -- legacy v1 profile
			expect(function()
				harness.Join(70050)
			end).to.throw()
			-- Fail-closed: the pre-migration original persists (Coins intact) and the
			-- invalid migrated value never reached the store (Nick is not BAD).
			expect(harness.Fake.Persisted[key].Coins).to.equal(7)
			expect(harness.Fake.Persisted[key].Nick).never.to.equal(BAD)
			harness.Cleanup()
		end)

		-- The guard also catches unserializable leaves (userdata/Instance/function),
		-- not just invalid UTF-8 -- a function stands in for userdata, which the
		-- headless test env cannot construct (both hit the same "Unserializable" arm).
		it("UpdateOffline rejects an unserializable value", function()
			local harness = TestCtx.make()
			local key = "Default/PLAYER_70002"
			harness.Fake.Persisted[key] = { Coins = 3 }
			local ok, reason = harness.Data.UpdateOffline(70002, function(data)
				data.Bad = function() end
			end)
			expect(ok).to.equal(false)
			expect(string.find(tostring(reason), "unpersistable") ~= nil).to.equal(true)
			expect(harness.Fake.Persisted[key].Coins).to.equal(3)
			harness.Cleanup()
		end)

		it("fails a load closed when a migration produces an unserializable value", function()
			local harness = TestCtx.make({
				Options = {
					Migrations = {
						[2] = function(data)
							data.Bad = function() end
						end,
					},
				},
			})
			local key = "Default/PLAYER_70051"
			harness.Fake.Persisted[key] = { Coins = 4 }
			expect(function()
				harness.Join(70051)
			end).to.throw()
			expect(harness.Fake.Persisted[key].Coins).to.equal(4)
			harness.Cleanup()
		end)
	end)

	describe("monetization registration checks", function()
		it("rejects a product name with invalid UTF-8", function()
			expect(function()
				TestCtx.make({ Options = { Products = { [BAD] = { Id = 999 } } } })
			end).to.throw()
		end)

		it("rejects a product Category with invalid UTF-8", function()
			expect(function()
				TestCtx.make({ Options = { Products = { Sword = { Id = 998, Category = BAD } } } })
			end).to.throw()
		end)
	end)
end
