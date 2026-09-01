--!nonstrict
-- Compiling a ServerStore template.
--
-- Store roots go through the SAME compile state as the player roots, so they share one
-- id space and one schema hash. That is what makes a store safe on the wire: a field id
-- cannot collide, and store drift fails the Hello handshake like any other drift.
--
-- The views are the other half. Node reads only Root, DerivedByWrite, DerivedNodes and
-- Template.Resolve, which walks Root, so scoping a tree to a set of roots costs nothing
-- in Node itself.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local Template = require(Root.Scribe.Internal.Template)

	local function compile(player, store)
		return Template.Compile(player, { ServerStore = store })
	end

	--- The refusal message, or "compiled" when it did not refuse.
	local function refusal(player, store): string
		local ok, err = pcall(compile, player, store)
		return if ok then "compiled" else tostring(err)
	end

	local function named(player, store, needle: string): string
		local text = refusal(player, store)
		return if text == "compiled" then "compiled" else tostring(string.find(text, needle, 1, true) ~= nil)
	end

	describe("one compile, one id space", function()
		it("ADMITS a well-formed store, which is the control", function()
			local compiled = compile({ Coins = Scribe.Int(0) }, { Wave = Scribe.Int(1) })
			expect(compiled.Views.Store ~= nil).to.equal(true)
		end)

		it("issues store ids from the same counter, and never issues one twice", function()
			local compiled = compile(
				{ Coins = Scribe.Int(0), Gems = Scribe.Int(0) },
				{ Wave = Scribe.Int(1), BossHp = Scribe.Int(1) }
			)
			local seen: { [number]: string } = {}
			local duplicates = 0
			for id, node in compiled.ById do
				if seen[id] ~= nil then
					duplicates += 1
				end
				seen[id] = node.Name or "<root>"
			end
			-- Two compiles would both start at 1, so a store id would resolve against the
			-- player's ById and decode to the wrong field.
			local wave = compiled.Root.Children.Wave
			local coins = compiled.Root.Children.Coins
			expect(`duplicates={duplicates} distinct={tostring(wave.Id ~= coins.Id)}`).to.equal(
				"duplicates=0 distinct=true"
			)
		end)

		it("folds the store into the schema hash, so store drift fails the handshake", function()
			local a = compile({ Coins = Scribe.Int(0) }, { Wave = Scribe.Int(1) })
			local b = compile({ Coins = Scribe.Int(0) }, { Wave = Scribe.Int(1), BossHp = Scribe.Int(1) })
			expect(a.Hash == b.Hash).to.equal(false)
		end)

		it("gives every store node Persist = false, through elements too", function()
			local compiled = compile({ Coins = Scribe.Int(0) }, {
				Wave = Scribe.Int(1),
				Spawns = Scribe.DictOf({ Kind = Scribe.String(""), Left = Scribe.Int(0) }),
			})
			local persisted = {}
			local function walk(node)
				if node.Persist ~= false then
					table.insert(persisted, node.Name or "<node>")
				end
				for _, child in node.Children or {} do
					walk(child)
				end
				-- Element nodes carry no id, so an ById walk would miss them entirely.
				if node.AnyChild then
					walk(node.AnyChild)
				end
			end
			for _, key in compiled.Views.Store.RootOrder do
				walk(compiled.Root.Children[key])
			end
			expect(table.concat(persisted, ",")).to.equal("")
		end)
	end)

	describe("the two views", function()
		it("keeps store roots out of the player view and player roots out of the store", function()
			local compiled = compile({ Coins = Scribe.Int(0) }, { Wave = Scribe.Int(1) })
			local player = compiled.Views.Player.Root.Children
			local store = compiled.Views.Store.Root.Children
			expect(
				`playerHasWave={tostring(player.Wave ~= nil)} storeHasCoins={tostring(store.Coins ~= nil)}`
					.. ` storeHasReserved={tostring(store._Scribe ~= nil)}`
			).to.equal("playerHasWave=false storeHasCoins=false storeHasReserved=false")
		end)

		it("leaves a storeless bundle exactly as it was", function()
			local compiled = Template.Compile({ Coins = Scribe.Int(0) }, {})
			-- Identity, not equality: every existing path keeps reading the same object.
			expect(`same={tostring(compiled.Views.Player == compiled)} store={tostring(compiled.Views.Store)}`).to.equal(
				"same=true store=nil"
			)
		end)

		it("gives the view roots no Id, so a stray encode raises instead of writing id 0", function()
			local compiled = compile({ Coins = Scribe.Int(0) }, { Wave = Scribe.Int(1) })
			expect(`player={tostring(compiled.Views.Player.Root.Id)} store={tostring(compiled.Views.Store.Root.Id)}`).to.equal(
				"player=nil store=nil"
			)
		end)
	end)

	describe("what a store template may not declare", function()
		it("REFUSES a name the player template already declares", function()
			expect(named({ Wave = Scribe.Int(0) }, { Wave = Scribe.Int(1) }, "already declares")).to.equal("true")
		end)

		it("REFUSES Scribe.Shared, which would switch on the per-player fanout", function()
			expect(named({ Coins = Scribe.Int(0) }, { Pub = Scribe.Shared({ Wave = Scribe.Int(1) }) }, "Scribe.Shared")).to.equal(
				"true"
			)
		end)

		it("REFUSES Scribe.Session, which sets nothing that is not already true", function()
			expect(
				named({ Coins = Scribe.Int(0) }, { Live = Scribe.Session({ Wave = Scribe.Int(1) }) }, "Scribe.Session")
			).to.equal("true")
		end)

		it("REFUSES Scribe.Timed, which has nothing to expire it", function()
			expect(named({ Coins = Scribe.Int(0) }, { Cool = Scribe.Timed(Scribe.Int(0)) }, "Scribe.Timed")).to.equal(
				"true"
			)
		end)

		it("REFUSES Scribe.Dynamic, whose factory needs a profile that does not exist", function()
			expect(named({ Coins = Scribe.Int(0) }, {
				Seed = Scribe.Dynamic(function()
					return 1
				end),
			}, "Scribe.Dynamic")).to.equal("true")
		end)

		it("REFUSES a Timed or Dynamic nested below a store root, not just at it", function()
			local deep = named(
				{ Coins = Scribe.Int(0) },
				{ Match = { Cool = Scribe.Timed(Scribe.Int(0)) } },
				"Scribe.Timed"
			)
			expect(deep).to.equal("true")
		end)

		it("REFUSES a reserved or cooldown prefix on a store root", function()
			expect(named({ Coins = Scribe.Int(0) }, { _ScribeThing = Scribe.Int(0) }, "library-owned")).to.equal("true")
		end)

		it("REFUSES a derived field that reads across the boundary", function()
			expect(named({
				Coins = Scribe.Int(0),
				Doubled = Scribe.Derived(Scribe.Int(0), { "Wave" }, function(w: number): number
					return w * 2
				end),
			}, { Wave = Scribe.Int(1) }, "ServerStore boundary")).to.equal("true")
		end)

		it("ALLOWS a derived field whose inputs stay on one side, which is the control", function()
			local ok = pcall(compile, {
				Coins = Scribe.Int(0),
				Doubled = Scribe.Derived(Scribe.Int(0), { "Coins" }, function(c: number): number
					return c * 2
				end),
			}, { Wave = Scribe.Int(1) })
			expect(ok).to.equal(true)
		end)
	end)
end
