--!nonstrict
-- The exchange against REAL DataStores and REAL yields.
--
-- Every other exchange spec runs against FakeProfileStore, which is fully synchronous.
-- That leaves the design's central assumption untested: it reasons about INTERLEAVING,
-- and Attempt yields at two forced flushes and again at the verdict proposal. The
-- verdict key is the sharpest case, since first-writer-wins is what the whole design
-- rests on.
--
-- Skipped unless ConformanceStore.UseReal is set, so it is a no-op under Lune and in CI.
-- To run it: build test.project.json, set
--     require(Test.Helpers.ConformanceStore).UseReal = true
-- at the top of test/RunTests.server.luau, enable Studio API access, and press Play.
--
-- Verdict keys are PERMANENT by design, so every run leaves keys behind. Use a throwaway
-- universe, not a live game's key space. Mode must stay "Live": Mock and NoSave swap in
-- the in-memory verdict store and the run would be testing the fake again.
--
-- EXPECT MINUTES, and most of it deliberate waiting. Three Studio runs died on
-- `502 ... Too many requests` before this file could finish, and the fixes are worth
-- knowing in order:
--
--   1. Pacing on the request budget did NOTHING. A 502 is the backend refusing;
--      exhausting the client-side allowance makes a call queue and yield, not throw.
--   2. Dropping a redundant Data.Flush and spacing same-key writes helped and was not
--      enough. It moved the first failure from 20s in to 75s.
--   3. Fewer writes fixed it. The shape cases now share ONE round trip instead of nine.
--
-- The logs never cleanly separated a per-key limit from a place-wide one, so this file
-- does both: AwaitKeyWindow between writes to a key, and shared round trips. The budget
-- is per SERVER, so a Studio plugin polling its own store competes; `HttpRequestsCache`
-- in the output is the tell.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local ExchangeLeg = require(Root.Scribe.Internal.ExchangeLeg)
	local ExchangeVerdict = require(Root.Scribe.Internal.ExchangeVerdict)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local ConformanceStore = require(Root.Test.Helpers.ConformanceStore)

	if not ConformanceStore.IsReal() then
		return
	end

	local realStore = ConformanceStore.get()

	-- A fresh namespace per run, for profile keys AND exchange ids. The exchange ids
	-- matter more than the profile keys: a verdict key is never deleted, so a rerun that
	-- reused an id would read the PREVIOUS run's verdict back and decide this run's
	-- exchange with it.
	local runId = os.time()
	local nextId = 0
	local function freshUserId(): number
		nextId += 1
		return 940000 + nextId
	end
	local nextExchange = 0
	local function freshExchangeId(): string
		nextExchange += 1
		return `RBX_{runId}_{nextExchange}`
	end

	local TEMPLATE = {
		Coins = Scribe.Int(0, { Min = 0, Max = 1000000 }),
		-- A record element, the shape every existing Key-leg spec uses.
		Inventory = Scribe.DictOf({ Qty = Scribe.Int(1, { Min = 1, Max = 99 }) }, { MaxKeys = 8 }),
		-- A SCALAR element, whose payload is the value itself rather than a record.
		Resources = Scribe.DictOf(Scribe.Int(0, { Min = 0, Max = 999 }), { MaxKeys = 8 }),
		-- A datatype INSIDE the element, so the payload travels packed as a buffer and
		-- the round trip has to survive base64 in a real DataStore.
		Relics = Scribe.DictOf({
			Where = Scribe.Vector3(Vector3.new(1, 2, 3)),
			Tier = Scribe.Int(1, { Min = 1, Max = 9 }),
		}, { MaxKeys = 8 }),
		Named = Scribe.MapOf("string", { Label = Scribe.String("x", { MaxLength = 16 }) }, { MaxKeys = 8 }),
		-- Integer keys, which Node stores as numbers and CoerceMapKeys converts back on
		-- load: the one shape whose key survives a real save differently to the others.
		Pets = Scribe.MapOf("integer", { Name = Scribe.String("pet", { MaxLength = 16 }) }, { MaxKeys = 8 }),
		Badges = Scribe.SetOf(Scribe.String("x", { MaxLength = 24 }), { MaxItems = 8 }),
		Deck = Scribe.ArrayOf(Scribe.String("x", { MaxLength = 16 }), { MaxItems = 8 }),
	}

	local EXCHANGEABLE = {
		Money = { Path = { "Coins" }, Kind = "Qty" },
		Item = { Path = { "Inventory" }, Kind = "Key" },
		-- Inventory's element is a lone count, so a Stack needs no Identity: there is
		-- nothing beside Qty for a split to duplicate.
		ItemStack = { Path = { "Inventory" }, Kind = "Stack", Count = "Qty" },
		Resource = { Path = { "Resources" }, Kind = "Key" },
		Relic = { Path = { "Relics" }, Kind = "Key" },
		Named = { Path = { "Named" }, Kind = "Key" },
		Pet = { Path = { "Pets" }, Kind = "Key" },
		Badge = { Path = { "Badges" }, Kind = "Key" },
		Card = { Path = { "Deck" }, Kind = "Key" },
	}

	--- Roughly what one harness spends: two session loads, the flush an attempt forces
	--- on each side, and two session-end saves.
	local BUDGET_PER_HARNESS = 10

	local function makeHarness()
		-- The CLIENT-side allowance only, and the lesser of the two limits this file
		-- runs into. The per-key window is the one that produced the 502s, and it is
		-- handled at each write site with AwaitKeyWindow rather than here.
		ConformanceStore.AwaitBudget(BUDGET_PER_HARNESS)
		return TestCtx.make({
			Template = TEMPLATE,
			Options = {
				ProfileStore = realStore,
				ProfileStoreIndex = ConformanceStore.STORE,
				ProfileKeyPrefix = `XB_{runId}_`,
				Mode = "Live", -- the whole point: real saves, real yields, real verdict key
				UseMock = nil,
				KickOnSessionEnd = false,
				LogLevel = "Fatal",
				Banner = false,
				Exchangeable = EXCHANGEABLE,
			},
		})
	end

	-- BOTH sides are seeded, and the Qty assertion below is written off this rather than
	-- off two hardcoded totals. The receiver ends at SEED + Amount, never at Amount, and
	-- a literal pair is exactly what got that wrong the first time this file ever ran.
	local SEED_COINS = 1000

	--- Two loaded players, each seeded with one of everything.
	local function pair(harness)
		local a, _ea, da = harness.Join(freshUserId())
		local b, _eb, db = harness.Join(freshUserId())
		da.Coins.Set(SEED_COINS)
		da.Inventory["blade"].Set({ Qty = 3 })
		da.Resources["ore"].Set(50)
		da.Relics["totem"].Set({ Where = Vector3.new(4, 5, 6), Tier = 7 })
		da.Named["alpha"].Set({ Label = "first" })
		da.Pets[7].Set({ Name = "Rex" })
		da.Badges.Add("veteran")
		da.Deck.Insert("ace")
		db.Coins.Set(SEED_COINS)
		return a, b, da, db
	end

	describe("the store really is the real one", function()
		it("is not the mock verdict store, or every case below is testing the fake", function()
			-- The first thing to prove, because a Mock or NoSave bundle would swap the
			-- verdict key for an in-memory table and the whole file would pass while
			-- exercising nothing.
			local harness = makeHarness()
			local mocked = harness.Ctx.Exchanges.UsesMockStore
			local store = harness.Ctx.Exchanges.VerdictStore()
			harness.Cleanup()
			expect(`mocked={tostring(mocked)} store={tostring(store ~= nil)}`).to.equal("mocked=false store=true")
		end)
	end)

	describe("the verdict key on a real DataStore", function()
		it("is first-writer-wins, which is the property the whole design rests on", function()
			-- A real UpdateAsync, a real round trip, and a second proposal that must LOSE.
			-- Under the fake this is a table assignment; here it is the actual contract.
			local harness = makeHarness()
			local ok, err = pcall(function()
				local store = harness.Ctx.Exchanges.VerdictStore()
				local exchangeId = freshExchangeId()

				local first = ExchangeVerdict.Propose(store, exchangeId, { V = "Commit", A = 1, B = 2, D = "d" })
				local second = ExchangeVerdict.Propose(store, exchangeId, { V = "Abort", A = 1, B = 2, D = "d" })
				local readBack = ExchangeVerdict.Read(store, exchangeId)

				expect(
					`first={tostring(first and first.V)} second={tostring(second and second.V)} read={tostring(
						readBack and readBack.V
					)}`
				).to.equal("first=Commit second=Commit read=Commit")
			end)
			harness.Cleanup()
			if not ok then
				error(err, 0)
			end
		end)

		it("survives a fresh handle, so the verdict is on the key and not in memory", function()
			local harness = makeHarness()
			local exchangeId = freshExchangeId()
			local ok, err = pcall(function()
				local store = harness.Ctx.Exchanges.VerdictStore()
				ExchangeVerdict.Propose(store, exchangeId, { V = "Abort", A = 3, B = 4, D = "d" })
			end)
			harness.Cleanup()
			if not ok then
				error(err, 0)
			end

			-- A brand-new bundle, a brand-new store handle, same key.
			local second = makeHarness()
			local seen = ExchangeVerdict.Read(second.Ctx.Exchanges.VerdictStore(), exchangeId)
			second.Cleanup()
			expect(tostring(seen and seen.V)).to.equal("Abort")
		end)
	end)

	describe("every supported shape moves, through real yields", function()
		-- ONE ROUND TRIP FOR EVERY SHAPE, and the reason is not tidiness.
		--
		-- This used to be a round trip PER SHAPE: nine exchanges, nine reloads, four
		-- real DataStore writes per profile each time. Roblox refused it. Three Studio
		-- runs died with `502 ... Too many requests` and ProfileStore entering a
		-- critical state, and pacing did not save it: waiting on the request budget
		-- changed nothing at all, and spacing same-key writes seven seconds apart only
		-- moved the first failure from twenty seconds in to seventy-five. The failures
		-- then arrived about once a minute, which is a quota refilling rather than a
		-- key cooling down, so the thing that had to come down was the NUMBER OF
		-- WRITES, not their spacing.
		--
		-- WHAT IS LOST, STATED HONESTLY. One leg per exchange isolated a shape that
		-- breaks the whole attempt; now a shape that cannot be staked fails every case
		-- here together. Per-shape DIAGNOSIS is kept: each shape still owns its `it`,
		-- its reading and its expectation, so a shape that moves but does not survive
		-- the round trip still fails alone and by name, which is the case this file
		-- exists to catch.
		local SHAPES = {
			{
				Name = "a bounded integer quantity",
				Leg = { Path = { "Coins" }, Kind = "Qty", Amount = 250 },
				Read = function(da, db)
					return `A={da.Coins.Get()} B={db.Coins.Get()}`
				end,
				Expect = `A={SEED_COINS - 250} B={SEED_COINS + 250}`,
			},
			{
				Name = "part of a stacked entry, leaving the rest behind",
				Leg = { Path = { "Inventory" }, Kind = "Stack", Key = "stackable", Amount = 1 },
				Read = function(da, db)
					local mine, theirs = da.Inventory["stackable"].Get(), db.Inventory["stackable"].Get()
					return `A={tostring(mine and mine.Qty)} B={tostring(theirs and theirs.Qty)}`
				end,
				Expect = "A=2 B=1",
			},
			{
				Name = "a dict key with a record element",
				Leg = { Path = { "Inventory" }, Kind = "Key", Key = "blade" },
				Read = function(da, db)
					return `A={tostring(da.Inventory["blade"].Get() ~= nil)} B={tostring(
						db.Inventory["blade"].Get() ~= nil
					)}`
				end,
				Expect = "A=false B=true",
			},
			{
				Name = "a dict key with a scalar element",
				Leg = { Path = { "Resources" }, Kind = "Key", Key = "ore" },
				Read = function(da, db)
					return `A={tostring(da.Resources["ore"].Get() ~= nil)} B={tostring(db.Resources["ore"].Get() ~= nil)}`
				end,
				Expect = "A=false B=true",
			},
			{
				Name = "a dict key carrying a packed datatype",
				Leg = { Path = { "Relics" }, Kind = "Key", Key = "totem" },
				Read = function(da, db)
					-- Read by COMPONENT, not tostring: the headless shim renders two equal
					-- Vector3s as distinct tables, and this file should say the same thing
					-- wherever it runs.
					local got = db.Relics["totem"].Get()
					local where = got and got.Where
					return `A={tostring(da.Relics["totem"].Get() ~= nil)} B={typeof(where)},{tostring(where and where.X)},{tostring(
						where and where.Y
					)},{tostring(where and where.Z)}`
				end,
				Expect = "A=false B=Vector3,4,5,6",
			},
			{
				Name = "a string-keyed map entry",
				Leg = { Path = { "Named" }, Kind = "Key", Key = "alpha" },
				Read = function(da, db)
					return `A={tostring(da.Named["alpha"].Get() ~= nil)} B={tostring(db.Named["alpha"].Get() ~= nil)}`
				end,
				Expect = "A=false B=true",
			},
			{
				Name = "an integer-keyed map entry",
				Leg = { Path = { "Pets" }, Kind = "Key", Key = 7 },
				Read = function(da, db)
					return `A={tostring(da.Pets[7].Get() ~= nil)} B={tostring(db.Pets[7].Get() ~= nil)}`
				end,
				Expect = "A=false B=true",
			},
			{
				Name = "a set member",
				Leg = { Path = { "Badges" }, Kind = "Key", Key = "veteran" },
				Read = function(da, db)
					return `A={tostring(da.Badges.Has("veteran"))} B={tostring(db.Badges.Has("veteran"))}`
				end,
				Expect = "A=false B=true",
			},
			{
				Name = "an array entry",
				Leg = { Path = { "Deck" }, Kind = "Key", Key = "ace" },
				Read = function(da, db)
					local function holds(list): boolean
						for _, entry in list or {} do
							if entry == "ace" then
								return true
							end
						end
						return false
					end
					return `A={tostring(holds(da.Deck.Get()))} B={tostring(holds(db.Deck.Get()))}`
				end,
				Expect = "A=false B=true",
			},
		}

		--- The whole round trip, run once and remembered as PLAIN STRINGS.
		---
		--- Readings rather than live accessors, deliberately: both harnesses are torn
		--- down before any assertion runs, so no case can hold a session open while the
		--- others wait, and nothing here depends on the order TestEZ picks.
		local captured, captureError = nil, nil
		local function readings()
			if captured ~= nil then
				return captured
			end
			if captureError ~= nil then
				error(captureError, 0)
			end
			local aId, bId
			local ok, err = pcall(function()
				local harness = makeHarness()
				local passed, failure = pcall(function()
					local a, b, da = pair(harness)
					aId, bId = a.UserId, b.UserId
					-- Its own key, so the Stack leg and the whole-entry Key leg below do
					-- not both name "blade" in one basket.
					da.Inventory["stackable"].Set({ Qty = 3 })

					local basket = {}
					for _, shape in SHAPES do
						table.insert(basket, shape.Leg)
					end
					ConformanceStore.AwaitKeyWindow()
					local outcome, why = harness.Data.Exchange.Attempt(a, basket, b, {})
					expect(`{tostring(outcome)} why={tostring(why)}`).to.equal("Committed why=nil")

					ConformanceStore.AwaitKeyWindow()
					harness.Leave(a)
					harness.Leave(b)
				end)
				harness.Cleanup()
				if not passed then
					error(failure, 0)
				end

				ConformanceStore.AwaitKeyWindow()
				local second = makeHarness()
				local reloadOk, reloadErr = pcall(function()
					local _a, _ea, da = second.Join(aId)
					local _b, _eb, db = second.Join(bId)
					local out = {}
					for _, shape in SHAPES do
						out[shape.Name] = shape.Read(da, db)
					end
					captured = out
				end)
				-- The join above wrote both keys and releasing writes them again, so the
				-- window has to clear even though nothing was modified: taking and
				-- dropping a session are both writes.
				ConformanceStore.AwaitKeyWindow()
				second.Cleanup()
				if not reloadOk then
					error(reloadErr, 0)
				end
			end)
			if not ok then
				-- Remembered, so nine cases report the same real cause rather than eight
				-- of them reporting "the capture already failed".
				captureError = err
				error(err, 0)
			end
			return captured
		end

		for _, shape in SHAPES do
			it(`moves {shape.Name} and it is still there after a real reload`, function()
				expect(readings()[shape.Name]).to.equal(shape.Expect)
			end)
		end
	end)

	describe("an interrupted exchange finishes itself on a later real load", function()
		it("returns a stake nobody resolved, after a real save and a real reload", function()
			-- The liveness claim, against real keys: a profile that left with value in
			-- escrow and no verdict anywhere gets it back the next time it loads. Under
			-- the fake this never crossed a network boundary.
			local userId = freshUserId()
			local exchangeId = freshExchangeId()

			local first = makeHarness()
			local ok, err = pcall(function()
				local player, entry, data = first.Join(userId)
				data.Inventory["relic"].Set({ Qty = 2 })
				local ctx = { Tree = entry.Tree, Entry = entry, Compiled = first.Compiled, UserId = userId }

				expect(select(1, ExchangeLeg.Claim(ctx, exchangeId, { Digest = "d", Role = "A", Partner = 999 }))).to.equal(
					true
				)
				expect(
					select(
						1,
						ExchangeLeg.Escrow(ctx, exchangeId, { { Path = { "Inventory" }, Kind = "Key", Key = "relic" } })
					)
				).to.equal(true)
				expect(`staked={tostring(data.Inventory["relic"].Get() == nil)}`).to.equal("staked=true")

				-- The Flush STAYS here, unlike the shape cases: this case is about a stake
				-- that reached disk and was then abandoned, so a verified durable write is
				-- the subject rather than a convenience. It is spaced from the join above
				-- instead of dropped.
				ConformanceStore.AwaitKeyWindow()
				expect(first.Data.Flush(player, { Timeout = 30 })).to.equal(true)
				ConformanceStore.AwaitKeyWindow()
				first.Leave(player)
			end)
			first.Cleanup()
			if not ok then
				error(err, 0)
			end

			ConformanceStore.AwaitKeyWindow()
			local second = makeHarness()
			local reloadOk, reloadErr = pcall(function()
				local player, entry, data = second.Join(userId)
				-- The load hook is spawned, so give the real round trip time to land.
				local deadline = os.clock() + 30
				while entry.Tree.Reserved.Exchange[exchangeId].Get() ~= nil and os.clock() < deadline do
					task.wait(0.1)
				end
				expect(
					`back={tostring(data.Inventory["relic"].Get() ~= nil)} record={tostring(
						entry.Tree.Reserved.Exchange[exchangeId].Get()
					)}`
				).to.equal("back=true record=nil")
				second.Data.Flush(player, { Timeout = 30 })
			end)
			second.Cleanup()
			if not reloadOk then
				error(reloadErr, 0)
			end
		end)
	end)

	describe("conservation across a real round trip", function()
		it("moves a whole basket both ways with nothing duplicated or lost", function()
			-- The ordinary case, end to end, on real keys: two baskets, several shapes,
			-- and a census after the reload that has to add up to exactly what went in.
			local harness = makeHarness()
			local aId, bId
			local ok, err = pcall(function()
				local a, b, _da, db = pair(harness)
				aId, bId = a.UserId, b.UserId
				db.Inventory["shield"].Set({ Qty = 1 })

				-- Same spacing as the shape cases: the joins wrote both keys and the
				-- attempt is about to flush them.
				ConformanceStore.AwaitKeyWindow()
				local outcome = harness.Data.Exchange.Attempt(
					a,
					{
						{ Path = { "Inventory" }, Kind = "Key", Key = "blade" },
						{ Path = { "Coins" }, Kind = "Qty", Amount = 400 },
						{ Path = { "Relics" }, Kind = "Key", Key = "totem" },
					},
					b,
					{
						{ Path = { "Inventory" }, Kind = "Key", Key = "shield" },
					}
				)
				expect(tostring(outcome)).to.equal("Committed")

				-- Dropped for the same reason as the shape cases: leaving writes both keys
				-- anyway, and the census after the reload is what proves durability.
				ConformanceStore.AwaitKeyWindow()
				harness.Leave(a)
				harness.Leave(b)
			end)
			harness.Cleanup()
			if not ok then
				error(err, 0)
			end

			ConformanceStore.AwaitKeyWindow()
			local second = makeHarness()
			local reloadOk, reloadErr = pcall(function()
				local _a, _ea, da = second.Join(aId)
				local _b, _eb, db = second.Join(bId)

				-- Every object counted across BOTH profiles. Exactly one of each, and the
				-- coins summing to the 2000 that went in, is the whole claim.
				local blades = (if da.Inventory["blade"].Get() then 1 else 0)
					+ (if db.Inventory["blade"].Get() then 1 else 0)
				local shields = (if da.Inventory["shield"].Get() then 1 else 0)
					+ (if db.Inventory["shield"].Get() then 1 else 0)
				local totems = (if da.Relics["totem"].Get() then 1 else 0) + (if db.Relics["totem"].Get() then 1 else 0)
				local totem = db.Relics["totem"].Get()

				-- The datatype is compared by COMPONENT rather than by tostring, so the
				-- assertion means the same thing here and under the Lune shim.
				local where = totem and totem.Where
				expect(
					`blades={blades} shields={shields} totems={totems} coins={da.Coins.Get() + db.Coins.Get()} kind={typeof(
						where
					)} at={tostring(where and where.X)},{tostring(where and where.Y)},{tostring(where and where.Z)} tier={tostring(
						totem and totem.Tier
					)}`
				).to.equal("blades=1 shields=1 totems=1 coins=2000 kind=Vector3 at=4,5,6 tier=7")
			end)
			second.Cleanup()
			if not reloadOk then
				error(reloadErr, 0)
			end
		end)
	end)
end
