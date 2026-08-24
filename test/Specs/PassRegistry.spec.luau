--!nonstrict
-- The GAMEPASS registry in src/Server/Monetization.luau, and the collision it now
-- refuses.
--
-- Two maps are built from `options.Passes` in the same loop:
--
--   passesByName[name] = { Id, Category }   -- keyed by the config's own table key
--   passNamesById[config.Id] = name         -- keyed by the gamepass Id
--
-- The first cannot collide: its key IS the config key. The second can, and before
-- 2.0.0 nothing checked it -- unlike the product loop immediately above, which has
-- always raised `duplicate product Id`. Two pass names sharing one gamepass Id
-- booted fine, and `passNamesById` silently kept whichever name `pairs()` happened
-- to visit last.
--
-- WHY THAT MATTERED, and why only part of it went wrong:
--
--   * Owns / ObserveOwned / OnOwnershipChanged / OwnsAsync / recipientAlreadyOwns
--     all look the pass up in `passesByName`, by NAME. Both duplicate names were in
--     there carrying the right Id, so every one of those read correctly for both.
--   * Only ONE reader goes the other way: the `PromptGamePassPurchaseFinished`
--     handler in `Start()`, which turns the engine's gamepass Id back into a name
--     via `passNamesById`. That was the whole blast radius -- an in-experience
--     purchase cached ownership, and wrote its Robux purchase-log entry, under a
--     single arbitrarily-chosen one of the two names. The other name kept reading
--     `Owns` false for the rest of the session, with the Robux already spent.
--
-- Narrow, but silent, unrecoverable within the session, and there is no config for
-- which the collision is what the developer meant -- so 2.0.0 refuses it at
-- registration rather than tolerating it. These specs pin the refusal and the boot
-- validation around it, and keep the purchase-handler coverage the duplicate specs
-- used to carry, re-measured on a config with DISTINCT Ids where it asserts the
-- correct path instead of the damage.
--
-- The purchase half is only reachable where the engine signal can be fired, which
-- means the headless runner: MarketplaceService is a real service Instance under
-- Studio and an RBXScriptSignal cannot be raised from Luau. Those specs report SKIP
-- there rather than failing, the same way the other host-dependent specs do.

return function()
	local Root = script.Parent.Parent.Parent
	local MarketplaceService = game:GetService("MarketplaceService")
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	-- Headless the signal is the runner's FakeSignal and can be raised; under Studio
	-- it is a real RBXScriptSignal and cannot. Probe the TYPE rather than looking for
	-- a `Fire` member -- reading an unknown member off a real RBXScriptSignal RAISES
	-- instead of returning nil, so the probe would be the thing that breaks. Same
	-- idiom, same reason, as TestCtx.Step and BuildFailureTeardown's census.
	local canFire = typeof(MarketplaceService.PromptGamePassPurchaseFinished) ~= "RBXScriptSignal"
	local itPurchasable = if canFire then it else itSKIP
	-- Bound once, so the call sites read as statements rather than needing a leading
	-- semicolon to stop Luau parsing `(` as a continuation of the line above.
	local promptFinished = MarketplaceService.PromptGamePassPurchaseFinished :: any

	-- 0xFF/0xFE never appear in valid UTF-8, so utf8.len rejects any string carrying
	-- them. Built with string.char rather than written as an escape, which is both
	-- the idiom Utf8Guard.spec uses and what keeps selene from reading `\xfeB` as a
	-- malformed escape.
	local BAD_BYTES = string.char(0xFF, 0xFE)

	--- Build a bundle with `passes` registered, returning (threw, message, harness).
	--- `Server.build` unwinds cleanly on a constructor throw (BuildFailureTeardown
	--- pins that), so a refused config leaves nothing attached to clean up.
	local function boot(passes: { [string]: any }, extra: { [string]: any }?): (boolean, string?, any)
		local options: { [string]: any } = { Passes = passes }
		for key, value in extra or {} do
			options[key] = value
		end
		local ok, result = pcall(TestCtx.make, { Options = options })
		if ok then
			return false, nil, result
		end
		return true, tostring(result), nil
	end

	describe("pass registry boot validation", function()
		it("accepts a valid pass set and answers ownership per name", function()
			local ownedIds: { [number]: boolean } = { [7001] = true }
			local threw, err, harness = boot({
				Flight = { Id = 7001, Category = "Travel" },
				Radar = { Id = 7002 },
			}, {
				UserOwnsGamePassAsync = function(_userId: number, passId: number): boolean
					return ownedIds[passId] == true
				end,
			})
			expect(threw).to.equal(false)
			expect(err).to.equal(nil)

			local player = harness.Join(70100)
			-- Distinct Ids resolve independently: the owned one true, the other false,
			-- and an unregistered key false without erroring.
			expect(harness.Data.Owns(player, "Flight")).to.equal(true)
			expect(harness.Data.Owns(player, "Radar")).to.equal(false)
			expect(harness.Data.Owns(player, "NotARegisteredPass")).to.equal(false)
			harness.Cleanup()
		end)

		it("refuses a pass whose Id is not a number, naming the pass", function()
			-- A string Id is the shape someone writes after copying the number out of
			-- the Roblox website URL into quotes.
			local threwString, stringErr = boot({ Beacon = { Id = "7003" } })
			expect(threwString).to.equal(true)
			expect(stringErr).to.equal('Scribe: pass "Beacon" must declare a numeric Id')

			-- A MISSING Id lands in the same guard, with the same message.
			local threwMissing, missingErr = boot({ Beacon = { Category = "Travel" } })
			expect(threwMissing).to.equal(true)
			expect(missingErr).to.equal('Scribe: pass "Beacon" must declare a numeric Id')
		end)

		it("refuses a pass NAME that is not valid UTF-8, without naming it", function()
			-- The name is persisted as a PurchaseLog value, so invalid UTF-8 would fail
			-- the whole DataStore save (error 104) long after registration. The message
			-- deliberately does not interpolate the name: the bad bytes are the name, and
			-- echoing them would put them straight back into the log line.
			local threw, err = boot({ [BAD_BYTES .. "Badge"] = { Id = 7004 } })
			expect(threw).to.equal(true)
			expect(err).to.equal("Scribe: a pass name contains invalid UTF-8 bytes")
		end)

		it("refuses a pass CATEGORY that is not valid UTF-8, naming the pass", function()
			local threw, err = boot({ Badge = { Id = 7005, Category = BAD_BYTES .. "Travel" } })
			expect(threw).to.equal(true)
			expect(err).to.equal('Scribe: pass "Badge" Category contains invalid UTF-8 bytes')
		end)

		it("does NOT type-check Category -- a number boots, a boolean dies unhelpfully", function()
			-- FINDING, pinned as it stands rather than endorsed. `Category: string?` is
			-- enforced only by the UTF-8 guard, and that guard is `utf8.len`, which
			-- COERCES a number to a string. So a numeric Category sails through
			-- registration and lands in the persisted PurchaseLog as a number, where
			-- every reader (GetPurchases' Category filter, PurchaseLogCategories) is
			-- comparing against strings.
			local threwNumber, numberErr, harness = boot({ Badge = { Id = 7006, Category = 42 } })
			expect(threwNumber).to.equal(false)
			expect(numberErr).to.equal(nil)
			harness.Cleanup()

			-- A boolean cannot be coerced, so the same guard throws -- but from inside
			-- Util.isUtf8, so the developer gets a Luau argument error that never says
			-- which pass is at fault. Boot IS refused; only the message is useless.
			local threwBool, boolErr = boot({ CategoryIsBoolean = { Id = 7007, Category = true } })
			expect(threwBool).to.equal(true)
			expect(boolErr).to.be.ok()
			expect(string.find(tostring(boolErr), "CategoryIsBoolean", 1, true)).to.equal(nil)
		end)
	end)

	describe("the gamepass purchase handler, and the duplicate Id it refuses", function()
		local FLIGHT_ID = 7100
		local RADAR_ID = 7101
		local DUPLICATE_MESSAGE = `Scribe: duplicate pass Id {FLIGHT_ID}; two pass names cannot share one gamepass `
			.. "Id, because a purchase reports only the Id and Scribe could credit just one of them"

		--- Two passes with DISTINCT Ids and distinct Categories, which is the shape the
		--- duplicate config had to be rewritten into once the collision stopped booting.
		--- `owned` is read live on every ownership check, so a spec flips an Id in it to
		--- model the purchase actually landing on Roblox's side.
		local function withPasses(userId: number, owned: { [number]: boolean }): (any, any)
			local harness = TestCtx.make({
				Options = {
					Passes = {
						Flight = { Id = FLIGHT_ID, Category = "FlightCategory" },
						Radar = { Id = RADAR_ID, Category = "RadarCategory" },
					},
					UserOwnsGamePassAsync = function(_userId: number, passId: number): boolean
						return owned[passId] == true
					end,
				},
			})
			local player = harness.Join(userId)
			-- The join refresh has settled and nothing is owned yet. Asserted rather than
			-- assumed: every spec below reads a transition off this baseline, so a refresh
			-- still in flight would make them measure the wrong edge.
			expect(harness.Data.Owns(player, "Flight")).to.equal(false)
			expect(harness.Data.Owns(player, "Radar")).to.equal(false)
			return harness, player
		end

		it("REFUSES two pass names sharing one gamepass Id", function()
			-- THE FLIP. This booted before 2.0.0, and `passNamesById[Id] = name` kept
			-- whichever name pairs() reached last, so an in-experience purchase credited
			-- one arbitrary name while the other read Owns false for the rest of the
			-- session with the Robux already spent. Products have refused a duplicate Id
			-- all along; passes now match. It is a BREAKING change -- a config that
			-- booted yesterday stops booting -- which is why it lands in an unreleased
			-- minor and is written up under "Behaviour changes".
			local threw, err = boot({
				Alpha = { Id = FLIGHT_ID },
				Beta = { Id = FLIGHT_ID },
			})
			expect(threw).to.equal(true)
			expect(err).to.equal(DUPLICATE_MESSAGE)

			-- ...and the check is about the Id, not about having two passes. Without this
			-- arm a guard that refused every multi-pass config would satisfy the
			-- assertion above and nothing here would notice.
			local threwDistinct, distinctErr, harness = boot({
				Alpha = { Id = FLIGHT_ID },
				Beta = { Id = RADAR_ID },
			})
			expect(threwDistinct).to.equal(false)
			expect(distinctErr).to.equal(nil)
			harness.Cleanup()
		end)

		it("still lets a developer product and a gamepass share one number", function()
			-- Developer products and gamepasses are separate Id spaces on Roblox, so the
			-- same number legitimately names one of each. productsById and passNamesById
			-- are built in separate loops off separate option tables, and the new pass
			-- check must not have quietly merged the two namespaces -- which is exactly
			-- the overreach a "duplicate Id" guard invites.
			local threw, err, harness = boot({ Flight = { Id = FLIGHT_ID } }, {
				Products = { Coins = { Id = FLIGHT_ID } },
			})
			expect(threw).to.equal(false)
			expect(err).to.equal(nil)
			harness.Cleanup()
		end)

		itPurchasable("caches ownership under the purchased pass's own name", function()
			local owned: { [number]: boolean } = {}
			local harness, player = withPasses(70201, owned)

			-- The player buys the pass in-experience. The engine reports the gamepass
			-- Id, which is all it knows; Scribe has to map it back to a name.
			owned[FLIGHT_ID] = true
			promptFinished:Fire(player, FLIGHT_ID, true)
			task.wait()

			expect(harness.Data.Owns(player, "Flight")).to.equal(true)
			-- The pass that was NOT bought is untouched: the Id resolved one entry, not
			-- the whole registry.
			expect(harness.Data.Owns(player, "Radar")).to.equal(false)
			harness.Cleanup()
		end)

		itPurchasable("announces exactly that name through the ownership signals", function()
			-- Both the broadcast signal and the per-key observer are driven off the
			-- OwnsCache write, so a name the handler failed to resolve is not merely
			-- stale on a read -- a listener whose whole job is to switch the perk on when
			-- the player buys it is never called at all.
			local owned: { [number]: boolean } = {}
			local harness, player = withPasses(70202, owned)

			local changed: { string } = {}
			harness.Data.OnOwnershipChanged:Connect(function(_player: any, key: string, isOwned: boolean)
				table.insert(changed, `{key}={isOwned}`)
			end)
			local observedRadar: { boolean } = {}
			local disconnect = harness.Data.ObserveOwned(player, "Radar", function(isOwned: boolean)
				table.insert(observedRadar, isOwned)
			end)
			task.wait() -- ObserveOwned's initial push is scheduled, not immediate
			expect(#observedRadar).to.equal(1)
			expect(observedRadar[1]).to.equal(false)

			owned[FLIGHT_ID] = true
			promptFinished:Fire(player, FLIGHT_ID, true)
			task.wait()
			task.wait()

			expect(#changed).to.equal(1)
			expect(changed[1]).to.equal("Flight=true")
			-- Still just the initial false: the unbought pass's observer stays quiet.
			expect(#observedRadar).to.equal(1)
			disconnect()
			harness.Cleanup()
		end)

		itPurchasable("writes ONE purchase-log entry, under that name and its Category", function()
			-- The Robux log is the developer's audit trail and the player's receipt
			-- history, and the Category it records is read straight out of passesByName
			-- under the resolved name -- so a name resolved wrongly is wrong in PERSISTED
			-- data, not merely in a session read.
			local owned: { [number]: boolean } = {}
			local harness, player = withPasses(70203, owned)
			expect(#harness.Data.GetPurchases(player)).to.equal(0)

			owned[FLIGHT_ID] = true
			promptFinished:Fire(player, FLIGHT_ID, true)
			task.wait()

			local logs = harness.Data.GetPurchases(player)
			expect(#logs).to.equal(1)
			expect(logs[1].Kind).to.equal("Robux")
			expect(logs[1].Product).to.equal("Flight")
			expect(logs[1].Category).to.equal("FlightCategory")
			expect(logs[1].From.Type).to.equal("GamePass")
			-- The pass that was not bought leaves no trace whatsoever.
			expect(#harness.Data.GetPurchases(player, { Category = "RadarCategory" })).to.equal(0)
			harness.Cleanup()
		end)

		it("has OwnsAsync re-query live and repair a cache the purchase never reached", function()
			-- Runs on every host, because it models the purchase landing WITHOUT the
			-- engine signal: what a website purchase mid-session looks like, and what a
			-- dropped PromptGamePassPurchaseFinished looks like too. Owns is a pure cache
			-- read and stays false; OwnsAsync re-queries UserOwnsGamePassAsync on every
			-- call and writes the answer back, so it both reports correctly and repairs
			-- the cache for the next plain read. That repair is what made the duplicate-Id
			-- bug survivable, and it is worth its own spec now that the bug is gone.
			local owned: { [number]: boolean } = {}
			local harness, player = withPasses(70204, owned)

			owned[RADAR_ID] = true
			expect(harness.Data.Owns(player, "Radar")).to.equal(false)
			expect(harness.Data.OwnsAsync(player, "Radar")).to.equal(true)
			expect(harness.Data.Owns(player, "Radar")).to.equal(true)
			-- The live re-query is scoped to the key asked about.
			expect(harness.Data.Owns(player, "Flight")).to.equal(false)
			harness.Cleanup()
		end)

		itPurchasable("ignores a prompt for an unregistered Id, and an unsuccessful one", function()
			-- The control for the specs above: they all turn on the handler actually
			-- running, so a handler that bailed early for an unrelated reason would make
			-- every one of them pass while measuring nothing.
			local owned: { [number]: boolean } = {}
			local harness, player = withPasses(70205, owned)

			promptFinished:Fire(player, 999999, true)
			task.wait()
			expect(#harness.Data.GetPurchases(player)).to.equal(0)
			-- An empty log is NOT enough on its own. Measured: substituting
			-- `passNamesById[passId] or tostring(passId)` for the guard leaves the log
			-- empty too -- the invented name then misses `passesByName`, and the handler
			-- dies indexing nil inside the signal's own spawned thread, where nothing
			-- sees it. The OwnsCache write happens BEFORE that crash, so this is the
			-- assertion that separates "the guard returned" from "the handler blew up on
			-- its way past": the raw Id must never become a pass name.
			expect(harness.Data.Owns(player, "999999")).to.equal(false)

			promptFinished:Fire(player, FLIGHT_ID, false)
			task.wait()
			expect(#harness.Data.GetPurchases(player)).to.equal(0)

			-- ...and the same signal with the registered Id and success DOES log, so the
			-- two silences above are the guards firing rather than the harness being deaf.
			owned[FLIGHT_ID] = true
			promptFinished:Fire(player, FLIGHT_ID, true)
			task.wait()
			expect(#harness.Data.GetPurchases(player)).to.equal(1)
			harness.Cleanup()
		end)
	end)
end
