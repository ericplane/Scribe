--!nonstrict
-- Data.PromptPurchase: buying a declared product for yourself.
--
-- Until this existed the only prompt Scribe exposed was PromptGift, so a game could ask
-- a player to buy a product for somebody ELSE but not for themselves, and had to reach
-- past Scribe to MarketplaceService with a raw Id to do the ordinary thing.
--
-- The interesting half is the refusal. A prompt for a perk the player already holds
-- charges them for nothing they can receive, so this refuses it rather than leaving
-- every caller to remember its own Owns check.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local function countedSignal()
		local listeners = {}
		local signal = {}
		function signal:Connect(fn)
			local connection = { Connected = true }
			function connection.Disconnect(disconnecting)
				disconnecting.Connected = false
				listeners[disconnecting] = nil
			end
			listeners[connection] = fn
			return connection
		end
		function signal:Fire(...)
			for connection, fn in table.clone(listeners) do
				if connection.Connected then
					fn(...)
				end
			end
		end
		function signal.Count()
			local count = 0
			for _ in listeners do
				count += 1
			end
			return count
		end
		return signal
	end

	local function harnessed(fn, extra)
		local prompted = {}
		local productFinished, passFinished = countedSignal(), countedSignal()
		local config = {
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = {
				Products = {
					-- Grants a perk, so ownership is a real question.
					EmberPack = { Id = 4242, Grants = "VIP" },
					-- No Grants: a consumable, which nobody can "own".
					CoinBag = { Id = 4243 },
				},
				Passes = { VIPPass = { Id = 777 } },
				PromptProductPurchaseFinished = productFinished,
				PromptGamePassPurchaseFinished = passFinished,
				PromptProductPurchase = function(player: Player, productId: number)
					table.insert(prompted, `product {player.UserId}:{productId}`)
				end,
				PromptGamePassPurchase = function(player: Player, passId: number)
					table.insert(prompted, `pass {player.UserId}:{passId}`)
				end,
				-- The join scan warms OwnsCache for every declared pass; this decides what
				-- it finds. Overridden per case where a case needs the other answer.
				UserOwnsGamePassAsync = function()
					return false
				end,
			},
		}
		for key, value in extra or {} do
			config.Options[key] = value
		end
		local harness = TestCtx.make(config)
		local ok, err = pcall(fn, harness, prompted, productFinished, passFinished)
		harness.Cleanup()
		if not ok then
			error(err, 0)
		end
	end

	--- The outcome as one string, so a failure prints the reason rather than "false".
	local function attempt(harness, player, name): string
		local ok, why = harness.Data.PromptPurchase(player, name)
		return `{tostring(ok)} why={tostring(why)}`
	end

	describe("one active purchase prompt per player", function()
		it("subscribes only for an active prompt, and a matching cancellation permits another", function()
			harnessed(function(harness, prompted, productFinished, passFinished)
				local player = harness.Join(9301)
				expect(productFinished.Count() + passFinished.Count()).to.equal(0)
				expect(attempt(harness, player, "CoinBag")).to.equal("true why=nil")
				expect(productFinished.Count()).to.equal(1)
				expect(attempt(harness, player, "VIPPass")).to.equal("false why=purchase prompt already open")
				productFinished:Fire(player.UserId + 1, 4243, false)
				productFinished:Fire(player.UserId, 4242, false)
				passFinished:Fire(player, 777, false)
				expect(attempt(harness, player, "CoinBag")).to.equal("false why=purchase prompt already open")
				productFinished:Fire(player.UserId, 4243, false)
				expect(productFinished.Count()).to.equal(0)
				expect(attempt(harness, player, "VIPPass")).to.equal("true why=nil")
				expect(#prompted).to.equal(2)
				expect(passFinished.Count()).to.equal(1)
				passFinished:Fire(player, 777, true)
				expect(passFinished.Count()).to.equal(0)
			end)
		end)

		it("allows different players to prompt independently and matches the pass Player identity", function()
			harnessed(function(harness, prompted, _, passFinished)
				local FakePlayer = require(Root.Test.Helpers.FakePlayer)
				local first = harness.Join(9302)
				local second = harness.Join(9303)
				expect(attempt(harness, first, "VIPPass")).to.equal("true why=nil")
				expect(attempt(harness, second, "VIPPass")).to.equal("true why=nil")
				passFinished:Fire(FakePlayer.new(first.UserId), 777, false)
				passFinished:Fire(first, 778, false)
				expect(attempt(harness, first, "CoinBag")).to.equal("false why=purchase prompt already open")
				passFinished:Fire(second, 777, false)
				expect(attempt(harness, first, "CoinBag")).to.equal("false why=purchase prompt already open")
				expect(attempt(harness, second, "CoinBag")).to.equal("true why=nil")
				expect(#prompted).to.equal(3)
			end)
		end)

		it("disconnects on session unload while a stale unload cannot clear the live entry", function()
			harnessed(function(harness, _, productFinished)
				local player, entry = harness.Join(9304)
				expect(attempt(harness, player, "CoinBag")).to.equal("true why=nil")
				harness.Ctx.Monetization.OnUnload(table.clone(entry))
				expect(productFinished.Count()).to.equal(1)
				expect(attempt(harness, player, "CoinBag")).to.equal("false why=purchase prompt already open")
				harness.Leave(player)
				expect(productFinished.Count()).to.equal(0)
				local nextPlayer = harness.Join(9304)
				expect(attempt(harness, nextPlayer, "CoinBag")).to.equal("true why=nil")
				harness.Ctx.Monetization.OnUnload(entry)
				expect(attempt(harness, nextPlayer, "CoinBag")).to.equal("false why=purchase prompt already open")
			end)
		end)

		it("disconnects all active dialogs on Stop and refuses new prompts", function()
			harnessed(function(harness, _, productFinished, passFinished)
				local first = harness.Join(9305)
				local second = harness.Join(9306)
				expect(attempt(harness, first, "CoinBag")).to.equal("true why=nil")
				expect(attempt(harness, second, "VIPPass")).to.equal("true why=nil")
				harness.Ctx.Monetization.Stop()
				expect(productFinished.Count() + passFinished.Count()).to.equal(0)
				expect(attempt(harness, first, "CoinBag")).to.equal("false why=not-loaded")
			end)
		end)

		it("connects before a synchronous close and releases the guard even before prompt returns", function()
			local finish = countedSignal()
			local calls = 0
			harnessed(function(harness)
				local player = harness.Join(9307)
				expect(attempt(harness, player, "CoinBag")).to.equal("true why=nil")
				expect(finish.Count()).to.equal(0)
				expect(attempt(harness, player, "CoinBag")).to.equal("true why=nil")
				expect(calls).to.equal(2)
			end, {
				PromptProductPurchaseFinished = finish,
				PromptProductPurchase = function(player, id)
					calls += 1
					finish:Fire(player.UserId, id, false)
				end,
			})
		end)

		it("releases failed prompts so an engine error never leaves a permanent busy state", function()
			local calls = 0
			harnessed(function(harness, _, productFinished)
				local player = harness.Join(9308)
				local ok, why = harness.Data.PromptPurchase(player, "CoinBag")
				expect(ok).to.equal(false)
				expect(string.find(why, "prompt unavailable", 1, true) ~= nil).to.equal(true)
				expect(productFinished.Count()).to.equal(0)
				expect(attempt(harness, player, "CoinBag")).to.equal("true why=nil")
				expect(calls).to.equal(2)
			end, {
				PromptProductPurchase = function()
					calls += 1
					if calls == 1 then
						error("prompt unavailable", 0)
					end
				end,
			})
		end)

		it("disconnects a late subscription if Stop runs inside Connect and never invokes the prompt", function()
			local finish = countedSignal()
			local connect = finish.Connect
			local stop
			function finish:Connect(fn)
				local connection = connect(self, fn)
				stop()
				return connection
			end
			harnessed(function(harness, prompted)
				local player = harness.Join(9309)
				stop = harness.Ctx.Monetization.Stop
				expect(attempt(harness, player, "CoinBag")).to.equal("false why=not-loaded")
				expect(finish.Count()).to.equal(0)
				expect(#prompted).to.equal(0)
			end, { PromptProductPurchaseFinished = finish })
		end)

		it("refuses a torn-down entry even before its Ready state has been replaced", function()
			harnessed(function(harness, prompted, productFinished)
				local player, entry = harness.Join(9310)
				entry.TornDown = true
				local outcome = attempt(harness, player, "CoinBag")
				entry.TornDown = false
				expect(outcome).to.equal("false why=not-loaded")
				expect(productFinished.Count()).to.equal(0)
				expect(#prompted).to.equal(0)
			end)
		end)

		it("rechecks teardown after a reentrant subscription before calling the engine", function()
			local finish = countedSignal()
			local connect = finish.Connect
			local entry
			function finish:Connect(fn)
				local connection = connect(self, fn)
				entry.TornDown = true
				return connection
			end
			harnessed(function(harness, prompted)
				local player, current = harness.Join(9311)
				entry = current
				local outcome = attempt(harness, player, "CoinBag")
				entry.TornDown = false
				expect(outcome).to.equal("false why=not-loaded")
				expect(finish.Count()).to.equal(0)
				expect(#prompted).to.equal(0)
			end, { PromptProductPurchaseFinished = finish })
		end)

		it("reserves the guard before invoking a reentrant engine seam", function()
			local activeHarness, nested
			harnessed(function(harness)
				activeHarness = harness
				local player = harness.Join(9312)
				expect(attempt(harness, player, "CoinBag")).to.equal("true why=nil")
				expect(nested).to.equal("false why=purchase prompt already open")
			end, {
				PromptProductPurchase = function(player)
					nested = attempt(activeHarness, player, "VIPPass")
				end,
			})
		end)

		it("does not reattach a listener after a yielding engine call resumes past Stop", function()
			local parked
			harnessed(function(harness, _, productFinished)
				local player = harness.Join(9313)
				local outcome
				task.spawn(function()
					outcome = attempt(harness, player, "CoinBag")
				end)
				expect(parked ~= nil).to.equal(true)
				expect(productFinished.Count()).to.equal(1)
				harness.Ctx.Monetization.Stop()
				expect(productFinished.Count()).to.equal(0)
				task.spawn(parked)
				expect(outcome).to.equal("true why=nil")
				expect(productFinished.Count()).to.equal(0)
			end, {
				PromptProductPurchase = function()
					parked = coroutine.running()
					coroutine.yield()
				end,
			})
		end)
	end)

	it("prompts the player for the product's declared Id, by name", function()
		harnessed(function(harness, prompted)
			local player = harness.Join(9001)
			local outcome = attempt(harness, player, "EmberPack")
			expect(`{outcome} prompts={table.concat(prompted, ",")}`).to.equal("true why=nil prompts=product 9001:4242")
		end)
	end)

	it("REFUSES a product whose perk the player already owns, and prompts nothing", function()
		-- The case the method exists for. Charging for a perk they hold takes money for
		-- something the receipt path will decline to grant twice.
		harnessed(function(harness, prompted)
			local player = harness.Join(9002)
			harness.Data.GrantPerk(player, "VIP")
			local outcome = attempt(harness, player, "EmberPack")
			expect(`{outcome} prompts={#prompted}`).to.equal("false why=owned prompts=0")
		end)
	end)

	it("still prompts a consumable, which has no perk to own", function()
		harnessed(function(harness, prompted)
			local player = harness.Join(9003)
			harness.Data.GrantPerk(player, "VIP")
			local outcome = attempt(harness, player, "CoinBag")
			expect(`{outcome} prompts={table.concat(prompted, ",")}`).to.equal("true why=nil prompts=product 9003:4243")
		end)
	end)

	it("REFUSES an unknown product name rather than raising", function()
		harnessed(function(harness, prompted)
			local player = harness.Join(9004)
			local outcome = attempt(harness, player, "NotAProduct")
			expect(`{outcome} prompts={#prompted}`).to.equal(
				'false why=unknown product or pass "NotAProduct" prompts=0'
			)
		end)
	end)

	it("REFUSES a player whose data is not loaded", function()
		harnessed(function(harness, prompted)
			local FakePlayer = require(Root.Test.Helpers.FakePlayer)
			local stranger = FakePlayer.new(9005)
			local outcome = attempt(harness, stranger, "EmberPack")
			expect(`{outcome} prompts={#prompted}`).to.equal("false why=not-loaded prompts=0")
		end)
	end)

	it("REFUSES rather than raising when the engine's prompt throws", function()
		-- A prompt can fail for reasons outside the game: the product is unpublished, or
		-- the platform is having a bad day. That is a refusal, not a crash in the
		-- caller's shop handler.
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = {
				Products = { EmberPack = { Id = 4242, Grants = "VIP" } },
				PromptProductPurchase = function()
					error("product is not published", 0)
				end,
			},
		})
		local answer
		local ran, err = pcall(function()
			local player = harness.Join(9006)
			local ok, why = harness.Data.PromptPurchase(player, "EmberPack")
			answer = `{tostring(ok)} named={tostring(string.find(tostring(why), "not published", 1, true) ~= nil)}`
		end)
		harness.Cleanup()
		if not ran then
			error(err, 0)
		end
		expect(answer).to.equal("false named=true")
	end)
	it("prompts a declared PASS through the gamepass call, not the product one", function()
		-- The two are different engine calls. Sending a pass Id to PromptProductPurchase
		-- prompts nothing, so resolving the name to the right call is the whole point.
		harnessed(function(harness, prompted)
			local player = harness.Join(9007)
			local outcome = attempt(harness, player, "VIPPass")
			expect(`{outcome} prompts={table.concat(prompted, ",")}`).to.equal("true why=nil prompts=pass 9007:777")
		end)
	end)

	it("REFUSES a pass the player already owns, and prompts nothing", function()
		local prompted = {}
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = {
				Passes = { VIPPass = { Id = 777 } },
				PromptGamePassPurchase = function()
					table.insert(prompted, "prompted")
				end,
				UserOwnsGamePassAsync = function()
					return true
				end,
			},
		})
		local answer
		local ran, err = pcall(function()
			local player = harness.Join(9008)
			harness.Step()
			local ok, why = harness.Data.PromptPurchase(player, "VIPPass")
			answer = `{tostring(ok)} why={tostring(why)} prompts={#prompted}`
		end)
		harness.Cleanup()
		if not ran then
			error(err, 0)
		end
		expect(answer).to.equal("false why=owned prompts=0")
	end)

	it("REFUSES TO START when one name is both a product and a pass", function()
		-- Resolution is by name, so a collision would leave the order of two tables
		-- deciding what the player is charged for.
		local ok, err = pcall(function()
			local h = TestCtx.make({
				Template = { Coins = Scribe.Int(0, { Min = 0 }) },
				Options = {
					Products = { Overlap = { Id = 1 } },
					Passes = { Overlap = { Id = 2 } },
				},
			})
			h.Cleanup()
		end)
		expect(
			`ok={tostring(ok)} named={tostring(string.find(tostring(err), "both a product and a pass", 1, true) ~= nil)}`
		).to.equal("ok=false named=true")
	end)

	describe("a finished gamepass purchase is confirmed, not trusted", function()
		--- Drive the purchase-finished handler and report what was credited.
		---
		--- Calls the handler directly rather than firing the signal: a real
		--- RBXScriptSignal has no Fire, so a spec that fires one passes headless and
		--- raises in Studio, taking its harness cleanup down with it.
		local function finished(ownsAnswer): string
			local harness = TestCtx.make({
				Template = { Coins = Scribe.Int(0, { Min = 0 }) },
				Options = {
					Passes = { VIPPass = { Id = 777 } },
					UserOwnsGamePassAsync = ownsAnswer,
				},
			})
			local answer
			local ok, err = pcall(function()
				local player = harness.Join(9100)
				harness.Step()
				harness.Ctx.Monetization.OnPassPurchaseFinished(player, 777, true)
				harness.Step()
				local logs = harness.Data.GetPurchases(player, { Kind = "Robux" })
				answer = `owns={tostring(harness.Data.Owns(player, "VIPPass"))} logged={#logs}`
			end)
			-- Unconditional: a raise inside the body would otherwise leave this bundle
			-- attached to the frame signal, and the next spec's flush counts go wrong.
			harness.Cleanup()
			if not ok then
				error(err, 0)
			end
			return answer
		end

		it("credits nothing when the ownership check does not confirm it", function()
			-- The event says the DIALOG closed. Crediting on that alone writes a
			-- persisted purchase-history entry for a purchase that may not exist.
			expect(finished(function()
				return false
			end)).to.equal("owns=false logged=0")
		end)

		it("credits nothing when the ownership check itself errors", function()
			expect(finished(function()
				error("throttled", 0)
			end)).to.equal("owns=false logged=0")
		end)

		it("credits the pass and writes ONE history entry once ownership confirms", function()
			expect(finished(function()
				return true
			end)).to.equal("owns=true logged=1")
		end)
	end)

	describe("a product may grant the entitlement a PASS confers", function()
		-- There is no API to transfer a game pass, so gifting.md prescribes a product
		-- whose Grants names the pass. Owns answers across both namespaces, so the rest
		-- of a game needs no special case. These pin that the DevMode typo check knows
		-- about that shape, because it did not: it warned at the documented pattern.
		local function warningsFor(options): number
			local Log = require(Root.Scribe.Internal.Log)
			local seen = 0
			local detach = Log.AddSink(function(entry)
				if entry.Code == "UNDECLARED_PERK" then
					seen += 1
				end
			end, { Level = "Warn" })
			local ran, err = pcall(function()
				TestCtx.make({ Template = { Coins = Scribe.Int(0, { Min = 0 }) }, Options = options }).Cleanup()
			end)
			task.wait()
			detach()
			if not ran then
				error(err, 0)
			end
			return seen
		end

		it("says nothing when Grants names a declared PASS", function()
			expect(warningsFor({
				DevMode = true,
				Perks = { "Founder" },
				Passes = { VIP = { Id = 222 } },
				Products = { VIPGift = { Id = 111, Grants = "VIP" } },
			})).to.equal(0)
		end)

		it("says nothing when Grants names a declared PERK, which is the control", function()
			expect(warningsFor({
				DevMode = true,
				Perks = { "Founder" },
				Products = { FounderGift = { Id = 111, Grants = "Founder" } },
			})).to.equal(0)
		end)

		it("still warns on a name that is neither, which is the typo it exists for", function()
			expect(warningsFor({
				DevMode = true,
				Perks = { "Founder" },
				Passes = { VIP = { Id = 222 } },
				Products = { Oops = { Id = 111, Grants = "Fonder" } },
			})).to.equal(1)
		end)

		it("says nothing when the perk is GRANTED either, which the boot check does not cover", function()
			-- A second call site warns at grant time rather than registration, so a player
			-- actually buying the gift product tripped it even after the boot check was
			-- fixed. Granting the pass-named perk by hand is the same mechanic.
			local Log = require(Root.Scribe.Internal.Log)
			local seen = 0
			local detach = Log.AddSink(function(entry)
				if entry.Code == "UNDECLARED_PERK" then
					seen += 1
				end
			end, { Level = "Warn" })
			local harness = TestCtx.make({
				Template = { Coins = Scribe.Int(0, { Min = 0 }) },
				Options = {
					DevMode = true,
					Perks = { "Founder" },
					Passes = { VIP = { Id = 222 } },
				},
			})
			local answer
			local ran, err = pcall(function()
				local player = harness.Join(9200)
				harness.Data.GrantPerk(player, "VIP")
				task.wait()
				answer = `warnings={seen} owns={tostring(harness.Data.Owns(player, "VIP"))}`
			end)
			harness.Cleanup()
			detach()
			if not ran then
				error(err, 0)
			end
			expect(answer).to.equal("warnings=0 owns=true")
		end)
	end)
end
