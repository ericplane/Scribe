--!nonstrict
-- Economy analytics: Increment/Decrement auto-emit LogEconomyEvent with the
-- currency taken from the field name, per-currency custom-field slots, an
-- ambient Resolve, prefixing, and label/currency overrides. The events are
-- captured through the Economy.LogEconomyEvent seam.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	-- CustomField01/02/03 slot key names, resolved the same way Analytics does.
	local SLOT1 = Enum.AnalyticsCustomFieldKeys.CustomField01.Name
	local SLOT2 = Enum.AnalyticsCustomFieldKeys.CustomField02.Name
	local SLOT3 = Enum.AnalyticsCustomFieldKeys.CustomField03.Name

	local function makeHarness(economy)
		local events = {}
		economy.LogEconomyEvent = function(player, flowType, currency, amount, balance, txn, itemSku, customFields)
			table.insert(events, {
				Player = player,
				Flow = flowType,
				Currency = currency,
				Amount = amount,
				Balance = balance,
				Txn = txn,
				ItemSku = itemSku,
				Fields = customFields,
			})
		end
		local harness = TestCtx.make({
			Template = {
				Coins = Scribe.Int(0, { Min = 0 }),
				Gems = Scribe.Int(0, { Min = 0 }),
				Tickets = Scribe.Int(0, { Min = 0 }),
			},
			Options = { Economy = economy },
		})
		return harness, events
	end

	it("auto-emits a Source event with the field name as currency and the ending balance", function()
		local harness, events = makeHarness({})
		local _, _, data = harness.Join()

		local newValue = data.Coins.Increment(100, { TransactionType = "QuestReward", ItemSku = "quest_01" })
		expect(newValue).to.equal(100)
		expect(#events).to.equal(1)

		local e = events[1]
		expect(e.Flow.Name).to.equal("Source")
		expect(e.Currency).to.equal("Coins") -- no Label override -> field name
		expect(e.Amount).to.equal(100)
		expect(e.Balance).to.equal(100)
		expect(e.Txn).to.equal("QuestReward")
		expect(e.ItemSku).to.equal("quest_01")
		expect(e.Fields).to.equal(nil) -- no currency config -> no custom fields

		harness.Cleanup()
	end)

	it("defaults Decrement to a Sink event with the positive magnitude", function()
		local harness, events = makeHarness({})
		local _, _, data = harness.Join()
		data.Coins.Increment(100) -- untagged: no event
		expect(#events).to.equal(0)

		data.Coins.Decrement(30, { TransactionType = "Shop" })
		expect(#events).to.equal(1)
		local e = events[1]
		expect(e.Flow.Name).to.equal("Sink")
		expect(e.Amount).to.equal(30) -- magnitude, not -30
		expect(e.Balance).to.equal(70)

		harness.Cleanup()
	end)

	it("does not emit when no meta is passed", function()
		local harness, events = makeHarness({})
		local _, _, data = harness.Join()
		data.Coins.Increment(10)
		data.Coins.Decrement(5)
		expect(#events).to.equal(0)
		harness.Cleanup()
	end)

	it("extracts .Name from an AnalyticsEconomyTransactionType enum", function()
		local harness, events = makeHarness({})
		local _, _, data = harness.Join()
		data.Coins.Increment(5, { TransactionType = Enum.AnalyticsEconomyTransactionType.Shop })
		expect(events[1].Txn).to.equal("Shop")
		harness.Cleanup()
	end)

	it("defaults the transaction type to Gameplay", function()
		local harness, events = makeHarness({})
		local _, _, data = harness.Join()
		data.Coins.Increment(5, { ItemSku = "x" })
		expect(events[1].Txn).to.equal("Gameplay")
		harness.Cleanup()
	end)

	it("maps declared fields to slots, merging ambient Resolve with per-call Fields and honoring Prefix", function()
		local harness, events = makeHarness({
			Prefix = true,
			Resolve = function(_player)
				return { Team = "Red" }
			end,
			Currencies = {
				Coins = {
					Label = "Gold",
					Fields = { "Location", "Team", { Name = "ItemType", Prefix = false } },
				},
			},
		})
		local _, _, data = harness.Join()

		data.Coins.Increment(50, { Fields = { Location = "Lobby", ItemType = "Weapon" } })
		local e = events[1]
		expect(e.Currency).to.equal("Gold") -- Label override
		expect(e.Fields[SLOT1]).to.equal("Location - Lobby") -- per-call, prefixed
		expect(e.Fields[SLOT2]).to.equal("Team - Red") -- ambient Resolve, prefixed
		expect(e.Fields[SLOT3]).to.equal("Weapon") -- prefix disabled for this field

		harness.Cleanup()
	end)

	it("lets a per-call Field override an ambient one, and per-currency Resolve merge over the global", function()
		local harness, events = makeHarness({
			Resolve = function(_player)
				return { Team = "Red" }
			end,
			Currencies = {
				Gems = {
					Fields = { "Zone", "Team" },
					Resolve = function(_player)
						return { Zone = "Arena" }
					end,
				},
			},
		})
		local _, _, data = harness.Join()

		data.Gems.Increment(20, { Fields = { Team = "Blue" } })
		local e = events[1]
		expect(e.Currency).to.equal("Gems")
		expect(e.Fields[SLOT1]).to.equal("Zone - Arena") -- currency Resolve
		expect(e.Fields[SLOT2]).to.equal("Team - Blue") -- per-call beats the global Resolve's "Red"

		harness.Cleanup()
	end)

	it("keeps each currency's fields and label independent", function()
		local harness, events = makeHarness({
			Resolve = function(_player)
				return { Team = "Red" }
			end,
			Currencies = {
				Coins = { Label = "Gold", Fields = { "Location", "Team" } },
				Gems = { Fields = { "Zone", "Team" } },
			},
		})
		local _, _, data = harness.Join()

		data.Coins.Increment(10, { Fields = { Location = "Lobby" } })
		data.Gems.Increment(10, { Fields = { Zone = "Arena" } })

		expect(events[1].Currency).to.equal("Gold")
		expect(events[1].Fields[SLOT1]).to.equal("Location - Lobby")
		expect(events[2].Currency).to.equal("Gems")
		expect(events[2].Fields[SLOT1]).to.equal("Zone - Arena")
		expect(events[2].Fields[SLOT2]).to.equal("Team - Red")

		harness.Cleanup()
	end)

	it("honors a per-call Currency label override", function()
		local harness, events = makeHarness({
			Currencies = { Coins = { Label = "Gold" } },
		})
		local _, _, data = harness.Join()
		data.Coins.Increment(5, { Currency = "Pounds" })
		expect(events[1].Currency).to.equal("Pounds")
		harness.Cleanup()
	end)

	it("emits a plain event (no custom fields) for an undeclared currency", function()
		local harness, events = makeHarness({
			Resolve = function(_player)
				return { Team = "Red" }
			end,
			Currencies = { Coins = { Fields = { "Location" } } },
		})
		local _, _, data = harness.Join()
		-- Tickets is not declared under Currencies.
		data.Tickets.Increment(3, { Fields = { Location = "Lobby" } })
		local e = events[1]
		expect(e.Currency).to.equal("Tickets")
		expect(e.Fields).to.equal(nil)
		harness.Cleanup()
	end)

	it("caps custom fields at the 3 Roblox slots, dropping the rest", function()
		local harness, events = makeHarness({
			Currencies = {
				Coins = { Fields = { "A", "B", "C", "D" } },
			},
		})
		local _, _, data = harness.Join()
		data.Coins.Increment(5, { Fields = { A = "1", B = "2", C = "3", D = "4" } })
		local e = events[1]
		expect(e.Fields[SLOT1]).to.equal("A - 1")
		expect(e.Fields[SLOT2]).to.equal("B - 2")
		expect(e.Fields[SLOT3]).to.equal("C - 3")
		-- "D" had no slot; it appears nowhere.
		local seenD = false
		for _, value in e.Fields do
			if value == "D - 4" then
				seenD = true
			end
		end
		expect(seenD).to.equal(false)
		harness.Cleanup()
	end)

	it("counts successful emits in the EconomyEvents metric", function()
		local harness, _ = makeHarness({})
		local _, _, data = harness.Join()
		local before = Scribe.GetMetrics().EconomyEvents or 0
		data.Coins.Increment(1, { TransactionType = "A" })
		data.Coins.Increment(1, { TransactionType = "B" })
		local after = Scribe.GetMetrics().EconomyEvents or 0
		expect(after - before).to.equal(2)
		harness.Cleanup()
	end)

	it("honors the legacy Source/Item aliases and an explicit Flow (the Data.Purchase tag shape)", function()
		-- Monetization.Purchase emits with { Source = ..., Flow = "Sink", Item = ... };
		-- lock that mapping so dropping the aliases in Analytics fails a test.
		local harness, events = makeHarness({})
		local _, _, data = harness.Join()
		data.Coins.Increment(40, { Source = "QuestReward", Flow = "Sink", Item = "sku_1" })
		local e = events[1]
		expect(e.Txn).to.equal("QuestReward") -- Source -> transactionType
		expect(e.ItemSku).to.equal("sku_1") -- Item -> itemSku
		expect(e.Flow.Name).to.equal("Sink") -- explicit Flow is honored
		expect(e.Amount).to.equal(40)
		harness.Cleanup()
	end)

	it("survives a throwing Resolve, dropping only its fields", function()
		local harness, events = makeHarness({
			Resolve = function(_player)
				error("global resolve boom")
			end,
			Currencies = {
				Coins = {
					Fields = { "Location", "Team" },
					Resolve = function(_player)
						return { Team = "Red" } -- the currency resolver still contributes
					end,
				},
			},
		})
		local _, _, data = harness.Join()
		local newValue = data.Coins.Increment(25, { Fields = { Location = "Lobby" } })
		expect(newValue).to.equal(25) -- mutation applied, Increment returned normally
		expect(#events).to.equal(1) -- the event still emitted
		local e = events[1]
		expect(e.Fields[SLOT1]).to.equal("Location - Lobby") -- per-call field mapped
		expect(e.Fields[SLOT2]).to.equal("Team - Red") -- surviving currency resolver
		harness.Cleanup()
	end)

	it("never lets a throwing field value abort the mutation", function()
		local harness, events = makeHarness({
			Prefix = true,
			Currencies = { Coins = { Fields = { "Location" } } },
		})
		local _, _, data = harness.Join()
		-- A per-call value whose __tostring throws while the field is being formatted.
		local bomb = setmetatable({}, {
			__tostring = function()
				error("boom")
			end,
		})
		local before = Scribe.GetMetrics().EconomyEventFailures or 0
		local newValue = data.Coins.Increment(15, { Fields = { Location = bomb } })
		expect(newValue).to.equal(15) -- Increment returned; gameplay is not aborted
		expect(#events).to.equal(0) -- the event was dropped, not emitted
		local after = Scribe.GetMetrics().EconomyEventFailures or 0
		expect(after - before).to.equal(1) -- and it was counted as a failure
		harness.Cleanup()
	end)

	it("warns in DevMode on an undeclared per-call field and on field overflow", function()
		-- The two config warnings are DevMode-gated; force Studio like Server.new does.
		local RunService = game:GetService("RunService")
		local origIsStudio = RunService.IsStudio
		RunService.IsStudio = function()
			return true
		end
		local harness, _ = makeHarness({
			Currencies = {
				Coins = { Fields = { "Location" } }, -- only "Location" declared
				Gems = { Fields = { "A", "B", "C", "D" } }, -- 4 > 3 slots -> overflow at build
			},
		})
		RunService.IsStudio = origIsStudio

		-- Overflow warning fires at build time (Analytics.new).
		expect(#Scribe.GetRecentLogs({ Code = "ECONOMY_FIELDS_OVERFLOW", Limit = 5 }) > 0).to.equal(true)

		local _, _, data = harness.Join()
		data.Coins.Increment(5, { Fields = { Typo = "x" } }) -- "Typo" is not declared
		expect(#Scribe.GetRecentLogs({ Code = "ECONOMY_FIELD_UNDECLARED", Limit = 5 }) > 0).to.equal(true)

		harness.Cleanup()
	end)
end
