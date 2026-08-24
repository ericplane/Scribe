--!nonstrict
-- The first executable example a new user copies has to run.
--
-- The guides build one running example, "Emberfall", and its inventory element is
-- declared with a field named `Count`. `Count` is also an accessor METHOD, so
-- `data.Inventory.Emberblade.Count` is the method, not the field, and every line
-- in the guides that dereferences it -- `.Count.Set(1)`, `.Count.Increment(1)`,
-- `.Count.Get()` -- throws "attempt to index function with 'Set'".
--
-- The library is right and already says so: it logs `API_NAME_COLLISION` under
-- DevMode, and the guides themselves state the rule twice (containers.md, "Method
-- names are reserved"; templates.md, "Method names"). The template three sections
-- earlier in the same files breaks it.
--
-- Worst of it is monetization.md's "no error, ever" grant, which is presented as
-- the safe pattern to copy and fails every purchase.
--
-- This spec transcribes the guides' template and their executable lines. It is a
-- transcription, so keep it in step with the guides: a rename in one place and not
-- the other is exactly the drift it exists to catch.
return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Log = require(Root.Scribe.Internal.Log)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	--- The Emberfall template as the guides declare it (intro.md, containers.md,
	--- templates.md, visibility.md, migrating.md all carry the same element shape).
	local function emberfallTemplate()
		return {
			Coins = Scribe.Int(0, { Min = 0 }),
			Xp = Scribe.Int(0, { Min = 0 }),
			Inventory = Scribe.DictOf({
				Qty = Scribe.Int(1, { Min = 1, Max = 999 }),
				Rarity = Scribe.Enum("Common", { "Common", "Rare", "Legendary" }),
			}, { MaxKeys = 200 }),
		}
	end

	--- Every log line emitted while `body` runs.
	local function capturing(body)
		local seen = {}
		local detach = Log.AddSink(function(entry)
			table.insert(seen, entry)
		end)
		body()
		task.wait()
		detach()
		return seen
	end

	local function hasCode(entries, code)
		for _, entry in entries do
			if entry.Code == code then
				return true
			end
		end
		return false
	end

	describe("the guides' Emberfall example", function()
		it("declares no field that collides with an accessor method", function()
			-- The library's own detector, which has been right all along and had
			-- nothing listening to it.
			local harness
			local entries = capturing(function()
				harness = TestCtx.make({
					Template = emberfallTemplate(),
					Options = { DevMode = true },
				})
				harness.Join(930001)
			end)

			if hasCode(entries, "API_NAME_COLLISION") then
				local names = {}
				for _, entry in entries do
					if entry.Code == "API_NAME_COLLISION" then
						table.insert(names, tostring(entry.Message))
					end
				end
				error(`the documented template collides with accessor names: {table.concat(names, "; ")}`)
			end

			harness.Cleanup()
		end)

		it("runs the Getting Started lines that write an inventory entry", function()
			-- intro.md's first executable block, and the line its prose then explains
			-- ("Writing Inventory.Emberblade.<qty> created that dictionary entry and
			-- filled Rarity in from its declared default").
			local harness = TestCtx.make({ Template = emberfallTemplate() })
			local _player, _entry, data = harness.Join(930002)

			data.Coins.Increment(50)
			data.Xp.Increment(120)
			data.Inventory.Emberblade.Qty.Set(1)

			expect(data.Coins.Get()).to.equal(50)
			expect(data.Inventory.Emberblade.Qty.Get()).to.equal(1)
			expect(data.Inventory.Emberblade.Rarity.Get()).to.equal("Common")

			harness.Cleanup()
		end)

		it("runs the containers guide's whole-element Set and Increment", function()
			-- containers.md: Set the whole element, then Increment the quantity to 2,
			-- then Count() the dictionary -- which is the METHOD, and has to keep
			-- working, since it is the reason the field cannot share its name.
			local harness = TestCtx.make({ Template = emberfallTemplate() })
			local _player, _entry, data = harness.Join(930003)

			data.Inventory.Emberblade.Set({ Qty = 1, Rarity = "Legendary" })
			data.Inventory.Emberblade.Qty.Increment(1)
			expect(data.Inventory.Emberblade.Qty.Get()).to.equal(2)
			expect(data.Inventory.Count()).to.equal(1)

			-- ...and the omitted-field default, from the same section.
			data.Inventory.Torch.Set({ Rarity = "Common" })
			expect(data.Inventory.Torch.Qty.Get()).to.equal(1)

			harness.Cleanup()
		end)

		it("runs the monetization guide's grant, the one labelled 'no error, ever'", function()
			-- monetization.md presents this as the safe pattern to copy. It has to
			-- actually grant.
			local granted = 0
			local harness = TestCtx.make({
				Template = emberfallTemplate(),
				Options = {
					Products = {
						EmberLantern = {
							Id = 111,
							Category = "Item",
							Grant = function(data)
								local itemId = "EmberLantern"
								-- The guide's "recommended safe" form: check, then increment.
								if data.Inventory[itemId].Qty.Get() == nil then
									data.Inventory[itemId].Set({ Qty = 1, Rarity = "Rare" })
								else
									data.Inventory[itemId].Qty.Increment(1)
								end
								granted += 1
							end,
						},
					},
				},
			})
			local player = harness.Join(930004)

			local decision = harness.Data.HandleReceipt({
				PlayerId = 930004,
				ProductId = 111,
				PurchaseId = "guide-1",
				CurrencySpent = 99,
				CurrencyType = Enum.CurrencyType.Robux,
				PlaceIdWherePurchased = 0,
			})

			expect(decision).to.equal(Enum.ProductPurchaseDecision.PurchaseGranted)
			expect(granted).to.equal(1)
			local data = harness.Data.Get(player)
			expect(data.Inventory.EmberLantern.Qty.Get()).to.equal(1)

			harness.Cleanup()
		end)

		it("still shadows a field that IS named after a method, so the rule is real", function()
			-- The control for the rule the guides state. If a field named `Count` were
			-- reachable after all, the rename would be pointless -- and the two
			-- "method names are reserved" sections would be wrong instead.
			local harness = TestCtx.make({
				Template = {
					Inventory = Scribe.DictOf({ Count = Scribe.Int(1, { Min = 1 }) }),
				},
				Options = { DevMode = true },
			})
			local _player, _entry, data = harness.Join(930005)

			expect(typeof(data.Inventory.Sword.Count)).to.equal("function")
			local ok = pcall(function()
				data.Inventory.Sword.Count.Set(1)
			end)
			expect(ok).to.equal(false)

			harness.Cleanup()
		end)
	end)
end
