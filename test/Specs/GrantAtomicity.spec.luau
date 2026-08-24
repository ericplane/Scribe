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

	describe("a Grant that YIELDS", function()
		-- A yielding Grant cannot run inside RunTransaction (the transaction detects
		-- the yield and cancels the coroutine), so applyProductGrant re-runs it on the
		-- caller's stack WITHOUT rollback -- and that parks the whole ProcessReceipt
		-- invocation with the grant half-written and no dedupe marker written yet. The
		-- persisted ring is a COMPLETION record, so everything in that window sees
		-- "not yet granted".

		it("grants exactly once under two concurrent identical receipts", function()
			-- Roblox never retries a receipt it was told was GRANTED, so a second grant
			-- here is unrecoverable revenue loss for the developer -- the player paid
			-- once and received twice.
			local resume: thread? = nil
			local harness = TestCtx.make({
				Options = {
					Products = {
						Coins1000 = {
							Id = 333,
							Grant = function(data)
								-- Yield in the middle, and hold there until released.
								data.Coins.Increment(500)
								resume = coroutine.running()
								coroutine.yield()
								data.Coins.Increment(500)
							end,
						},
					},
				},
			})
			local _player, _entry, data = harness.Join(70011)

			local outcomes = {}
			task.spawn(function()
				outcomes[1] = harness.Data.HandleReceipt(receipt(70011, 333, "pid-concurrent"))
			end)
			-- The first is parked mid-grant with no marker written. The second arrives.
			local parked = resume
			resume = nil
			task.spawn(function()
				outcomes[2] = harness.Data.HandleReceipt(receipt(70011, 333, "pid-concurrent"))
			end)
			-- Release whichever calls are parked, first-in first-out.
			for _ = 1, 4 do
				local waiting = parked or resume
				parked, resume = nil, nil
				if waiting then
					task.spawn(waiting)
				end
				task.wait()
			end

			expect(`coins={data.Coins.Get()}`).to.equal("coins=1000")
			expect(`granted={outcomes[1] == GRANTED} second={tostring(outcomes[2])}`).to.equal(
				`granted=true second={tostring(NOT_PROCESSED)}`
			)
			harness.Cleanup()
		end)

		it("does not compound a yielding Grant that throws part-way across retries", function()
			-- The other half. applyProductGrant runs a yielding Grant with NO rollback
			-- and says so in its own log line, so the writes before the throw stay in
			-- the tree -- and the receipt is answered NotProcessedYet, so Roblox
			-- retries and re-applies them: 1000, then 2000, then 3000.
			--
			-- Settled as delivered-once instead, loudly (GRANT_PARTIAL), because the
			-- alternative -- refusing the retry forever -- is the outcome
			-- applyProductGrant's own comment already rejects: taking the player's
			-- Robux and never delivering.
			local harness = TestCtx.make({
				Options = {
					Products = {
						Bundle = {
							Id = 444,
							Grant = function(data)
								data.Coins.Increment(1000)
								task.wait() -- makes it a YIELDING grant: no rollback
								error("second half of the grant failed")
							end,
						},
					},
				},
			})
			local _player, _entry, data = harness.Join(70012)

			local first = harness.Data.HandleReceipt(receipt(70012, 444, "pid-partial"))
			local second = harness.Data.HandleReceipt(receipt(70012, 444, "pid-partial"))
			local third = harness.Data.HandleReceipt(receipt(70012, 444, "pid-partial"))

			-- Applied once and settled, rather than 3000 and still climbing.
			expect(`coins={data.Coins.Get()}`).to.equal("coins=1000")
			expect(`first={first == GRANTED} second={second == GRANTED} third={third == GRANTED}`).to.equal(
				"first=true second=true third=true"
			)
			-- ...and it was loud. Scanned BACKWARDS: the log ring is a process
			-- singleton shared with every other spec in the run.
			local logs = Scribe.GetRecentLogs({ Code = "GRANT_PARTIAL", Limit = 5 })
			expect(`reported={#logs > 0}`).to.equal("reported=true")
			harness.Cleanup()
		end)
	end)

	it("a Grant writing through a DANGLING container key mints a phantom and still GRANTS", function()
		-- Characterisation, not approval. This is what a `DictOf` costs on the money
		-- path, executed rather than argued, because nothing in the suite showed it.
		--
		-- `DictOf`'s contract is that any string is a valid key (src/init.luau's
		-- docstring, templates.md and monetization.md all say so), so a write that
		-- descends through a key naming no element is a legal write, not an error:
		-- the element materialises from its declared defaults, the transaction
		-- commits, the save succeeds, and the receipt settles PurchaseGranted. The
		-- player paid Robux and the goods are on a character that does not exist.
		--
		-- A `StrictKeys` option was considered for Tier C and DECLINED -- it is
		-- default-off, so it protects only the game that already knew to ask for it,
		-- which is not the game that hits this. What closes it is the guard below:
		-- resolve the pointer before spending it. This spec exists so the trade-off
		-- is visible and so the failing case is already written if that is revisited.
		local harness = TestCtx.make({
			Template = {
				ActiveSlot = Scribe.String(""),
				Characters = Scribe.DictOf({
					Name = Scribe.String(""),
					Gems = Scribe.Int(0, { Min = 0 }),
				}),
			},
			Options = {
				Products = {
					GemPack = {
						Id = 555,
						Grant = function(data)
							-- The naive recipe. `ActiveSlot` is a pointer nothing checks.
							data.Characters[data.ActiveSlot.Get()].Gems.Increment(100)
						end,
					},
				},
			},
		})
		local player, _entry, data = harness.Join(91001)
		data.Characters.hero_1.Name.Set("Hero")
		data.ActiveSlot.Set("hero_DELETED") -- points at a character that is gone

		local decision = harness.Data.HandleReceipt(receipt(91001, 555, "pid-dangling"))
		harness.Data.Flush(player)

		local keys = {}
		for key in data.Characters.Get() do
			table.insert(keys, key)
		end
		table.sort(keys)
		local persisted = harness.Fake.Persisted["Default/PLAYER_91001"].Characters
		local persistedPhantom = persisted ~= nil and persisted.hero_DELETED ~= nil

		expect(
			`granted={decision == GRANTED} keys={table.concat(keys, ",")} `
				.. `phantom={data.Characters.hero_DELETED.Gems.Get()} real={data.Characters.hero_1.Gems.Get()} `
				.. `persisted={persistedPhantom}`
		).to.equal("granted=true keys=hero_1,hero_DELETED phantom=100 real=0 persisted=true")

		harness.Cleanup()
	end)

	describe("GRANT_SEEDED_ELEMENT, the DevMode warning for that shape", function()
		-- `StrictKeys` was declined: default-off, it protects only the developer who
		-- already knew to ask, which is not the developer who hits this. This is the
		-- alternative -- no public API, no schema-hash change, and it fires during
		-- playtesting rather than requiring anyone to have read an option table.
		--
		-- The signal is IMPLICIT materialisation: a write that descended THROUGH a key
		-- naming no element, so the element had to be seeded from its defaults to
		-- carry it. Measured across eight grant shapes before this was wired; the
		-- three below are the ones that decide whether it is a signal or noise.
		local function slotTemplate()
			return {
				Coins = Scribe.Int(0, { Min = 0 }),
				ActiveSlot = Scribe.String(""),
				Characters = Scribe.DictOf({ Name = Scribe.String(""), Gems = Scribe.Int(0, { Min = 0 }) }),
			}
		end

		-- Returns the GRANT_SEEDED_ELEMENT entries a receipt produced.
		local function grantWith(userId: number, devMode: boolean, grant, setup)
			local seen = {}
			local unsubscribe = Scribe.AddLogSink(function(entry)
				if entry.Code == "GRANT_SEEDED_ELEMENT" then
					table.insert(seen, `{entry.Level}|{entry.Context and entry.Context.Paths}|{entry.Message}`)
				end
			end)
			local harness = TestCtx.make({
				Template = slotTemplate(),
				Options = { DevMode = devMode, Products = { GemPack = { Id = 557, Grant = grant } } },
			})
			local _p, _e, data = harness.Join(userId)
			setup(data)
			local decision = harness.Data.HandleReceipt(receipt(userId, 557, `pid-seed-{userId}`))
			-- Detached before any assertion: the sink list is a process singleton.
			unsubscribe()
			harness.Cleanup()
			return seen, decision
		end

		it("fires, names the path and names the product, for a dangling dereference", function()
			local seen, decision = grantWith(92001, true, function(data)
				data.Characters[data.ActiveSlot.Get()].Gems.Increment(100)
			end, function(data)
				data.Characters.hero_1.Name.Set("Hero")
				data.ActiveSlot.Set("hero_DELETED")
			end)

			expect(`n={#seen}`).to.equal("n=1")
			local entry = seen[1] or ""
			-- Warn, not Error: Scribe cannot tell a dangling id from a deliberate one,
			-- so this must not reach OnIssue and page somebody.
			expect(string.sub(entry, 1, 5)).to.equal("Warn|")
			expect(string.find(entry, "|Characters.hero_DELETED|", 1, true) ~= nil).to.equal(true)
			expect(string.find(entry, 'product "GemPack"', 1, true) ~= nil).to.equal(true)
			-- And the grant still succeeded: this is a warning, not a refusal. The
			-- receipt behaviour is unchanged from the spec above.
			expect(`granted={decision == GRANTED}`).to.equal("granted=true")
		end)

		it("stays silent for a deliberate whole-element Set, which is the legitimate create", function()
			-- The half that decides whether this is worth reading at all. A product
			-- that grants a NEW thing is the common case and must not warn.
			local seen = grantWith(92002, true, function(data)
				data.Characters.brand_new.Set({ Name = "New", Gems = 5 })
			end, function(data)
				data.Characters.hero_1.Name.Set("Hero")
			end)
			expect(`n={#seen}`).to.equal("n=0")
		end)

		it("is off outside DevMode", function()
			local seen = grantWith(92003, false, function(data)
				data.Characters[data.ActiveSlot.Get()].Gems.Increment(100)
			end, function(data)
				data.Characters.hero_1.Name.Set("Hero")
				data.ActiveSlot.Set("hero_DELETED")
			end)
			expect(`n={#seen}`).to.equal("n=0")
		end)

		it("covers the Data.Purchase grant too, not only the receipt path", function()
			-- Both money paths take a caller-supplied Grant and both run it inside a
			-- transaction; wiring only the receipt path would leave soft currency
			-- with the identical hole.
			local seen = {}
			local unsubscribe = Scribe.AddLogSink(function(entry)
				if entry.Code == "GRANT_SEEDED_ELEMENT" then
					table.insert(seen, tostring(entry.Context and entry.Context.Paths))
				end
			end)
			local harness = TestCtx.make({ Template = slotTemplate(), Options = { DevMode = true } })
			local player, _e, data = harness.Join(92004)
			data.Coins.Set(1000)
			data.Characters.hero_1.Name.Set("Hero")
			data.ActiveSlot.Set("hero_DELETED")

			local ok = harness.Data.Purchase(player, {
				Cost = { Path = "Coins", Amount = 10 },
				Category = "Shop",
				ItemId = "GemTop",
				Grant = function(d)
					d.Characters[d.ActiveSlot.Get()].Gems.Increment(100)
				end,
			})
			unsubscribe()
			harness.Cleanup()

			expect(`ok={ok} n={#seen} path={seen[1]}`).to.equal("ok=true n=1 path=Characters.hero_DELETED")
		end)
	end)

	it("...and resolving the pointer first is what actually closes it", function()
		-- The guard the monetization guide now prescribes: a Grant that THROWS is
		-- rolled back and answered NotProcessedYet, so Roblox retries and the player
		-- keeps their Robux. That is the difference between the two shapes -- not the
		-- dangling id, which is identical in both.
		local harness = TestCtx.make({
			Template = {
				ActiveSlot = Scribe.String(""),
				Characters = Scribe.DictOf({
					Name = Scribe.String(""),
					Gems = Scribe.Int(0, { Min = 0 }),
				}),
			},
			Options = {
				Products = {
					GemPack = {
						Id = 556,
						Grant = function(data)
							local slot = data.ActiveSlot.Get()
							-- Count() and Get() both exclude a key nothing has written.
							if data.Characters[slot].Name.Get() == nil then
								error(`GemPack: no character "{tostring(slot)}"`)
							end
							data.Characters[slot].Gems.Increment(100)
						end,
					},
				},
			},
		})
		local _p, _e, data = harness.Join(91002)
		data.Characters.hero_1.Name.Set("Hero")
		data.ActiveSlot.Set("hero_DELETED")

		local refused = harness.Data.HandleReceipt(receipt(91002, 556, "pid-guarded"))
		-- The read inside the guard does NOT mint the key: only a write does.
		local keys = {}
		for key in data.Characters.Get() do
			table.insert(keys, key)
		end

		-- Aim it at a real character and the same product grants exactly once.
		data.ActiveSlot.Set("hero_1")
		local granted = harness.Data.HandleReceipt(receipt(91002, 556, "pid-guarded"))

		expect(
			`refused={refused == NOT_PROCESSED} keysAfterRefusal={#keys} `
				.. `granted={granted == GRANTED} gems={data.Characters.hero_1.Gems.Get()}`
		).to.equal("refused=true keysAfterRefusal=1 granted=true gems=100")

		harness.Cleanup()
	end)

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
