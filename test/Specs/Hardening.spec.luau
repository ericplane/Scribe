--!nonstrict
-- Regression tests for the misc robustness/API additions: the OnPlayerInit
-- isNewProfile argument and the profile-size field on SaveInfo.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Wire = require(Root.Scribe.Internal.Wire)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	describe("OnPlayerInit isNewProfile", function()
		it("is true for a brand-new profile and false for a returning one", function()
			local seen = {}
			local harness = TestCtx.make({
				Options = {
					OnPlayerInit = function(player, _, isNewProfile)
						seen[player.UserId] = isNewProfile
					end,
				},
			})
			-- Brand-new player: no persisted data, SessionLoadCount == 1.
			harness.Join(80001)
			expect(seen[80001]).to.equal(true)
			-- Returning player: seed non-default persisted data (SessionLoadCount == 2,
			-- and not template-fresh), so it is neither new, reset, nor fresh-as-template.
			harness.Fake.Persisted["Default/PLAYER_80002"] = { Coins = 50 }
			harness.Join(80002)
			expect(seen[80002]).to.equal(false)
			harness.Cleanup()
		end)
	end)

	describe("profile size in SaveInfo", function()
		it("reports a byte size after a successful save", function()
			local harness = TestCtx.make()
			local player, _, data = harness.Join()
			expect(harness.Data.GetSaveInfo(player).Size).to.equal(nil) -- before first save
			data.Coins.Set(123)
			harness.Data.Flush(player)
			local info = harness.Data.GetSaveInfo(player)
			expect(type(info.Size)).to.equal("number")
			expect(info.Size > 0).to.equal(true)
			harness.Cleanup()
		end)
	end)

	describe("version history", function()
		it("lists, reads, and restores versions, refusing while a session is active", function()
			local harness = TestCtx.make()
			local player, _, data = harness.Join(95001)
			data.Coins.Set(111)
			harness.Data.Flush(player)
			data.Coins.Set(222)
			harness.Data.Flush(player)

			local versions = harness.Data.ListVersions(95001)
			expect(#versions >= 2).to.equal(true)
			local vid = versions[1].VersionId

			expect(type(harness.Data.GetVersion(95001, vid))).to.equal("table")

			-- Refused while the player has an active session on this server.
			local ok, reason = harness.Data.RestoreVersion(95001, vid)
			expect(ok).to.equal(false)
			expect(string.find(tostring(reason), "active session") ~= nil).to.equal(true)

			-- Allowed once the player is offline.
			harness.Leave(player)
			expect((harness.Data.RestoreVersion(95001, vid))).to.equal(true)
			harness.Cleanup()
		end)
	end)

	describe("late-joiner Shared snapshot", function()
		it("does not double-apply a pending Shared op the new client's snapshot already has", function()
			local template = TestCtx.defaultTemplate()
			template.Public = Scribe.Shared({ List = {} })
			local harness = TestCtx.make({ Template = template })

			-- Player A is ready.
			local playerA, entryA, dataA = harness.Join(90001)
			harness.SendHello(playerA)

			-- A does a non-idempotent Shared op that stays queued (no flush yet).
			dataA.Public.List.Insert("x")
			expect(#entryA.SharedQueue).to.equal(1)

			-- Player B joins and handshakes in the same window, before any flush.
			local playerB = harness.Join(90002)
			harness.SendHello(playerB)

			-- The fix drains A's Shared queue during B's Init, so the op reaches B only
			-- through its SharedInit snapshot with nothing left to re-broadcast.
			expect(#entryA.SharedQueue).to.equal(0)

			harness.Ctx.Replication.FlushEntry(entryA)
			expect(#harness.FramesFor(playerB, Wire.Frames.SharedInit) >= 1).to.equal(true)
			-- No redundant SharedDiff: the Insert is applied exactly once on B's mirror.
			expect(#harness.FramesFor(playerB, Wire.Frames.SharedDiff)).to.equal(0)
			harness.Cleanup()
		end)
	end)

	describe("numeric/string key aliasing", function()
		it("rejects a table holding both a numeric key and its string form", function()
			local harness = TestCtx.make()
			local _, _, data = harness.Join()
			expect(function()
				data.Inventory.Set({ [7] = "a", ["7"] = "b" })
			end).to.throw()
			harness.Cleanup()
		end)

		it("rejects setting a numeric key when its string form already exists", function()
			local harness = TestCtx.make()
			local _, _, data = harness.Join()
			data.Inventory["7"].Set("a")
			expect(function()
				data.Inventory[7].Set("b")
			end).to.throw()
			harness.Cleanup()
		end)

		it("rejects setting a string key when its numeric form already exists", function()
			local harness = TestCtx.make()
			local _, _, data = harness.Join()
			data.Inventory[7].Set("a")
			expect(function()
				data.Inventory["7"].Set("b")
			end).to.throw()
			harness.Cleanup()
		end)

		it("rejects an aliasing INTERMEDIATE segment auto-vivified by a nested write", function()
			local harness = TestCtx.make()
			local _, _, data = harness.Join()
			data.Inventory["7"].Sub.Set("a") -- creates string intermediate "7"
			expect(function()
				data.Inventory[7].Sub.Set("b") -- would auto-vivify numeric 7 alongside "7"
			end).to.throw()
			harness.Cleanup()
		end)

		it("still allows a numeric key alongside a genuinely different string key", function()
			local harness = TestCtx.make()
			local _, _, data = harness.Join()
			data.Inventory[7].Set("seven")
			data.Inventory["07"].Set("oh-seven") -- "07" ~= tostring(7), so no alias
			expect(data.Inventory[7].Get()).to.equal("seven")
			expect(data.Inventory["07"].Get()).to.equal("oh-seven")
			harness.Cleanup()
		end)
	end)

	describe("transaction yield guard", function()
		it("refuses a yielding transaction fn and rolls back its writes", function()
			local harness = TestCtx.make()
			local player, _, data = harness.Join()
			data.Coins.Set(100)
			local ok, reason = harness.Data.Transaction(player, function()
				data.Coins.Set(500)
				coroutine.yield() -- stands in for task.wait / a DataStore call: an illegal yield
				data.Coins.Set(999)
			end)
			expect(ok).to.equal(false)
			expect(string.find(tostring(reason), "yield") ~= nil).to.equal(true)
			-- Rolled back to the pre-transaction value.
			expect(data.Coins.Get()).to.equal(100)
			harness.Cleanup()
		end)

		it("still commits a normal (non-yielding) transaction", function()
			local harness = TestCtx.make()
			local player, _, data = harness.Join()
			local ok = harness.Data.Transaction(player, function()
				data.Coins.Set(42)
				data.Gems.Set(7)
			end)
			expect(ok).to.equal(true)
			expect(data.Coins.Get()).to.equal(42)
			expect(data.Gems.Get()).to.equal(7)
			harness.Cleanup()
		end)
	end)

	describe("oversize profile", function()
		local BIG = string.rep("a", 3700000) -- ~3.7 MB, over the 3.5 MB size-warn threshold

		it("fires a ProfileSize anomaly at save time when over the ceiling", function()
			local harness = TestCtx.make()
			local player, _, data = harness.Join()
			local fired = false
			harness.Ctx.Signals.OnAnomaly:Connect(function(info)
				if info.Reason == "ProfileSize" then
					fired = true
				end
			end)
			data.Inventory.Set({ big = BIG })
			harness.Data.Flush(player)
			expect(fired).to.equal(true)
			harness.Cleanup()
		end)

		it("logs PROFILE_TOO_LARGE (not a transient error) when an oversize save fails", function()
			local harness = TestCtx.make()
			local player, _, data = harness.Join()
			local sawTooLarge = false
			local conn = Scribe.OnIssue:Connect(function(entry)
				if entry.Code == "PROFILE_TOO_LARGE" then
					sawTooLarge = true
				end
			end)
			data.Inventory.Set({ big = BIG })
			harness.Fake.FailSaves = true
			harness.Data.Flush(player)
			conn:Disconnect()
			expect(sawTooLarge).to.equal(true)
			harness.Cleanup()
		end)
	end)
end
