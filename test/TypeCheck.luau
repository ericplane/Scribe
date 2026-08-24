--!strict
-- End-to-end typecheck smoke test for the exported ValueType type function and
-- the typed Scribe() entry point. Analyzed via test.project.json (not shipped).

local Scribe = require(script.Parent.Parent.Scribe)

type ItemData = { Health: number, Dmg: number }

local template = {
	Coins = Scribe.Int(0, { Min = 0 }),
	CreatedAt = Scribe.Dynamic(os.time), -- number; seeded per new profile
	Gems = 0,
	Wins = 0,
	Stats = { Kills = 0, Deaths = 0 },
	Team = Scribe.Enum("Civilian", { "Civilian", "Police", "MP" }),
	Equipped = nil :: string?,
	Inventory = {} :: { [string]: ItemData },
	Settings = { Music = true, Sfx = true },
	QuestProgress = {} :: { number },
	XPBooster = Scribe.Timed(false),
	BuildData = buffer.create(4),
	SpawnPoint = Scribe.Vector3(Vector3.zero),
	HomeDoor = Scribe.CFrame(CFrame.identity),
	Tint = Scribe.Color3(Color3.fromRGB(255, 120, 0)),
	PlacedFurniture = Scribe.ArrayOf({
		Cf = Scribe.CFrame(CFrame.identity),
		ItemId = Scribe.String("", { MaxLength = 64 }),
		Note = Scribe.Optional(Scribe.String("")),
	}, { MaxItems = 200 }),
	Resources = Scribe.DictOf(Scribe.Int(0, { Min = 0 }), { MaxKeys = 64 }),
	Secret = Scribe.ServerOnly({ Flagged = false }),
	Runtime = Scribe.Session({ InCombat = false }),
	-- Scribe.Derived: reads as its output declarator, with no mutators on the node.
	Rank = Scribe.Derived(
		Scribe.Enum("Recruit", { "Recruit", "Officer" }),
		{ "Team", "Stats.Kills" },
		function(team: string, kills: number): string
			return if team ~= "Civilian" and kills > 10 then "Officer" else "Recruit"
		end
	),
	DoubledWins = Scribe.Derived(Scribe.Int(0), { "Wins" }, function(wins: number): number
		return wins * 2
	end),
}

type T = typeof(template)

-- Annotated strict configs: Stat/Cost.Path check against the template's
-- numeric leaf-path union, and Grant's `data` is the typed accessor tree.
local boards: { [string]: Scribe.LeaderboardConfig<T> } = {
	TopCoins = { Stat = "Coins", Limit = 100, Replicate = true },
	TopKills = { Stat = "Stats.Kills" },
	-- A derived numeric field is a valid stat: boards read through the accessor
	-- tree, which computes it like any other field.
	TopDoubled = { Stat = "DoubledWins" },
}

local products: { [string]: Scribe.ProductConfig<T> } = {
	Coins1000 = {
		Id = 111,
		Category = "Currency",
		Grant = function(data)
			data.Coins.Increment(1000)
		end,
	},
	GiftVIP = { Id = 222, Category = "Gamepass", Grants = "VIP" },
}

local bundle = Scribe({
	Template = template,
	Transport = "Default",
	ProfileStoreIndex = "MyGameData",
	ProfileKeyPrefix = "PLAYER_",
	Migrations = {
		[2] = function(data)
			data.Gems = data.Gems or 0
		end,
	},
	Leaderboards = boards,
	Products = products,
	Passes = { VIP = { Id = 333 } },
	Economy = {
		Prefix = true,
		Resolve = function(player)
			return { Team = player.Name }
		end,
		Currencies = {
			Coins = {
				Label = "Gold",
				Fields = { "Location", { Name = "Team", Prefix = false } },
				Resolve = function(_p)
					return { Location = "Lobby" }
				end,
			},
			Gems = { Fields = { "Zone" } },
		},
	},
})

local Data = bundle.Server

local function serverUsage(player: Player)
	local data = Data[player]
	local coins: number = data.Coins.Increment(50)
	-- Read-only declared bounds (number?), on both server and client.
	local coinMin: number? = data.Coins.Min()
	local coinMax: number? = data.Coins.Max()
	-- Declared default, typed as the field's value type.
	local coinDefault: number = data.Coins.Default()
	local spawnDefault: Vector3 = data.SpawnPoint.Default()
	local createdAt: number = data.CreatedAt.Get() -- Scribe.Dynamic field types as its factory's return
	-- Economy-tagged mutation: the meta table annotates against Scribe.EconomyMeta.
	local meta: Scribe.EconomyMeta = {
		TransactionType = Enum.AnalyticsEconomyTransactionType.Shop,
		ItemSku = "hat_cowboy",
		Fields = { Location = "Lobby" },
	}
	data.Gems.Decrement(10, meta)
	data.Settings.Music.Set(false)
	local dmg: number = data.Inventory.Sword_001.Dmg.Get()
	data.QuestProgress.Insert(3)
	local has: boolean = data.QuestProgress.Has(3)

	-- Scribe.ArrayOf: elements are typed accessor nodes, reached by numeric index.
	data.PlacedFurniture.Insert({ Cf = CFrame.identity, ItemId = "OakChair" })
	local placedCf: CFrame = data.PlacedFurniture[1].Cf.Get()
	data.PlacedFurniture[1].Cf.Set(CFrame.identity)
	local note: string? = data.PlacedFurniture[1].Note.Get()
	local placedCount: number = data.PlacedFurniture.Count()
	local snapshot: { { Cf: CFrame, ItemId: string, Note: string? } } = data.PlacedFurniture.Get()

	-- Scribe.DictOf: a fresh key still types as the declared element.
	local wood: number = data.Resources.Wood.Increment(5)
	local dropped: number? = data.Resources.Remove("Wood")
	data.XPBooster.SetTimed(true, 3600)
	local active: boolean, remaining: number? = data.XPBooster.Active()
	local blob: buffer = data.BuildData.Get()
	local spawnPoint: Vector3 = data.SpawnPoint.Get()
	data.SpawnPoint.Set(Vector3.new(1, 2, 3))
	local door: CFrame = data.HomeDoor.Get()
	local tint: Color3 = data.Tint.Get()
	data.BuildData.Set(buffer.create(8))
	local equipped: string? = data.Equipped.Get()
	local flagged: boolean = data.Secret.Flagged.Get()
	local inCombat: boolean = data.Runtime.InCombat.Toggle()

	-- A WHOLE-SUBTREE read must not show a declarator's internal label. Scribe.Timed
	-- and Scribe.ServerOnly read back as a bare T, which may be a scalar, so unlike
	-- the other declarators they cannot carry a metatable brand; their label is
	-- stripped on the way out instead. These used to type as
	-- `{ __scribeTimed: boolean }` and `{ __scribeServerOnly: ... }`.
	local everything = data.Get()
	local wholeBooster: boolean = everything.XPBooster
	local wholeSecret: boolean = everything.Secret.Flagged
	-- Scribe.Derived is the third such wrapper: it reads as its output type, and a
	-- whole-subtree read must not show `{ __scribeDerived: string }` either.
	local wholeRank: string = everything.Rank

	-- A derived field reads like any other node; its inputs' declared types are the
	-- annotation the compute function carries, since a list of path strings cannot
	-- produce an argument tuple at the type level.
	local rank: string = data.Rank.Get()
	data.Rank.Observe(function(value: string)
		print(value)
	end)
	data.Rank.Changed(function(new: string, old: string)
		print(new, old)
	end)
	local rankDefault: string = data.Rank.Default()
	local doubled: number = data.DoubledWins.Get()
	local doubledMin: number? = data.DoubledWins.Min()

	local tree, reason = Data.WaitForData(player)
	if tree then
		tree.Wins.Increment(1)
	end

	Data.Command("EquipItem", { Args = { "string" } }, function(_commandPlayer: Player, _itemId: string)
		return true
	end)

	-- ImportLegacyData returns an optional raw table: a table to adopt, nil for
	-- "nothing to carry over".
	local _importer: (Player, number) -> { [string]: any }? = function(_p: Player, _userId: number)
		return { Coins = 1 }
	end

	-- The lifecycle reason is a typed union, not a bare string.
	local _tree, waitReason = Data.WaitForData(player, 30)
	local lifecycleReason: Scribe.LifecycleReason? = waitReason
	if lifecycleReason == Scribe.Reason.PlayerLeft then
		lifecycleReason = nil
	end

	local _flushed: boolean = Data.Flush(player, { Force = true, Timeout = 5 })
	-- RestoreVersion's options table is optional, and the opt-in that rolls the
	-- reserved `_Scribe` root back with the rest is typed rather than `any`.
	local _restoredPlain: boolean, _restoreReason: string? = Data.RestoreVersion(12345, "version-id")
	local _restoredRolled: boolean = Data.RestoreVersion(12345, "version-id", { RollBackReserved = true })
	local owns: boolean = Data.Owns(player, "VIP")
	local ownsAsync: boolean = Data.OwnsAsync(player, "VIP")
	local ok, err = Data.PromptGift(player, "GiftVIP", 12345)
	local onCooldown, cooldownRemaining = Data.OnCooldown(player, "DailyReward", 86400)

	-- Purchase: Cost.Path is path-checked; Grant gets the typed accessor.
	local bought = Data.Purchase(player, {
		Cost = { Path = "Coins", Amount = 100 },
		Category = "Vehicle",
		ItemId = "Police01",
		Grant = function(grantData)
			grantData.QuestProgress.Insert(1)
		end,
	})

	return coins,
		wholeBooster,
		wholeSecret,
		dmg,
		has,
		active,
		remaining,
		equipped,
		flagged,
		inCombat,
		reason,
		owns,
		ownsAsync,
		ok,
		err,
		onCooldown,
		cooldownRemaining,
		blob,
		spawnPoint,
		door,
		tint,
		bought,
		coinMin,
		coinMax,
		coinDefault,
		spawnDefault,
		createdAt,
		lifecycleReason,
		placedCf,
		note,
		placedCount,
		snapshot,
		wood,
		dropped,
		wholeRank,
		rank,
		rankDefault,
		doubled,
		doubledMin
end

local ClientData = bundle.Client
-- The container declarators get their OWN small template. The template above is
-- already close to the new solver's complexity budget, and adding four more roots
-- to it tips the whole file into "Code is too complex to typecheck", which would
-- silently stop checking everything else here.
local containerTemplate = {
	Unlocked = Scribe.SetOf(Scribe.String("", { MaxLength = 32 })),
	Tutorial = Scribe.Flags({ "Move", "Combat", "Trade" }),
	History = Scribe.ArrayOf(Scribe.Int(0), { MaxItems = 5, Evict = "Front" }),
	Recent = Scribe.ArrayOf(Scribe.Int(0), { MaxItems = 5, Evict = "Back" }),
	Friends = Scribe.MapOf("integer", Scribe.String("")),
	Tags = Scribe.MapOf("string", Scribe.Int(0)),
	Wealth = Scribe.Big(0, { Min = 0 }),
}

local containerBundle = Scribe({
	Template = containerTemplate,
	ProfileStoreIndex = "C",
	ProfileKeyPrefix = "C_",
	Banner = false,
})

local function containerDeclarators(player: Player)
	local data = containerBundle.Server[player]

	-- Scribe.SetOf: membership, no Insert and no index-based Remove.
	local added: boolean = data.Unlocked.Add("Desert")
	local hasIt: boolean = data.Unlocked.Has("Desert")
	local dropped: boolean = data.Unlocked.Remove("Desert")
	local members: { string } = data.Unlocked.Get()

	-- Scribe.Flags: named booleans, no array surface.
	data.Tutorial.Enable("Combat")
	local onFlag: boolean = data.Tutorial.Has("Combat")
	local flipped: boolean = data.Tutorial.Toggle("Trade")
	local enabled: { string } = data.Tutorial.Get()

	-- Both Evict spellings are in the template above, so the declared ArrayOpts type
	-- can never drift from what the runtime accepts.
	data.History.Insert(1)
	data.Recent.Insert(2, 1)

	-- Scribe.MapOf: the key type is declared, so an integer key needs no tostring
	-- and the value is fully typed through it.
	data.Friends[123456].Set("Ada")
	local seen: string = data.Friends[123456].Get()
	data.Tags.Alpha.Set(1)
	local tag: number = data.Tags.Alpha.Get()
	-- The CONTAINER node reads and writes the whole map, not one element. Without
	-- these the fixture only ever exercised element access, so the map node could
	-- be typed as its element with nothing noticing.
	local allFriends: { [number]: string } = data.Friends.Get()
	local allTags: { [string]: number } = data.Tags.Get()
	data.Friends.Set({ [123456] = "Ada" })
	local friendCount: number = data.Friends.Count()
	local removedFriend: string? = data.Friends.Remove(123456)
	-- A map node carries OnChildChanged at runtime, keyed by the declared key type
	-- and carrying the ELEMENT on both sides. Nothing in either fixture pinned it.
	data.Friends.OnChildChanged(function(_id: number, _new: string?, _old: string?) end)
	data.Friends.OnKeyAdded(function(_id: number, _name: string) end)
	data.Friends.OnKeyRemoved(function(_id: number, _name: string) end)

	-- Scribe.Big takes a number, a numeric string, or another big value everywhere.
	data.Wealth.Set("1.5e100")
	data.Wealth.Increment("1e99")
	data.Wealth.Decrement(5)
	data.Wealth.Multiply(1.15)
	data.Wealth.Divide(data.Wealth.Get())
	local shown: string = data.Wealth.Get():Short()
	local lossy: number = data.Wealth.Get():ToNumber()
	-- FINDING 23, the other declarators: a WHOLE-SUBTREE read must show the values,
	-- not the declarator's internal label. Each of these used to come back as
	-- `{ __scribeFlags: { string } }`, `{ __scribeSet: { string } }` and
	-- `{ __scribeMapKey: ..., __scribeMapValue: ... }`. Read off the ROOT so no new
	-- template root is needed, which this template has no headroom for.
	local whole = data.Get()
	local wholeFlags: { string } = whole.Tutorial
	local wholeSet: { string } = whole.Unlocked
	local wholeTags: { [string]: number } = whole.Tags
	local wholeNames: { [number]: string } = whole.Friends

	-- The operators live in bigOperators() below, on their own template: this one is
	-- already at the new solver's complexity budget.
	local summed = data.Wealth.Get() + data.Wealth.Get()
	local shownSum: string = summed:Short()
	-- Clone and Default read as bigs too, not as the stored mantissa pair.
	local clonedBig: string = data.Wealth.Clone():Short()
	local defaultBig: string = data.Wealth.Default():Short()

	return added,
		hasIt,
		dropped,
		members,
		onFlag,
		flipped,
		enabled,
		seen,
		tag,
		allFriends,
		allTags,
		friendCount,
		removedFriend,
		wholeFlags,
		wholeSet,
		wholeTags,
		wholeNames,
		shown,
		lossy,
		shownSum,
		clonedBig,
		defaultBig
end

-- NARROWED FLOATS get their own small template, for the reason the container
-- template gives above: the main one is at the new solver's complexity budget and
-- three more roots on it tipped the whole file into "Code is too complex to
-- typecheck", which silently stops checking everything else here. (Measured, not
-- assumed -- adding them there is what produced that diagnostic.)
local floatTemplate = {
	-- Both spellings of Precision, so FloatMeta cannot drift from what the
	-- template compiler accepts at runtime.
	Velocity = Scribe.Number(0, { Min = -1000, Max = 1000, Precision = "f32" }),
	Health = Scribe.Number(100, { Min = 0, Max = 100, Precision = 0.5 }),
	Unnarrowed = Scribe.Number(0, { Min = 0, Max = 1 }),
	-- The OTHER direction of the same knob: on a CFrame, Precision widens. Here
	-- rather than on the main template for the complexity reason noted above.
	Aim = Scribe.CFrame(CFrame.identity, { Precision = "exact" }),
	Placed = Scribe.CFrame(CFrame.identity),
}

local floatBundle = Scribe({
	Template = floatTemplate,
	ProfileStoreIndex = "F",
	ProfileKeyPrefix = "F_",
	Banner = false,
})

local function narrowedFloats(player: Player)
	local data = floatBundle.Server[player]

	-- THE POINT OF THIS BLOCK. A narrowed float is still a plain `number` to the
	-- game, carrying the ordinary number accessors. Precision decides what the wire
	-- spends and must not leak into the type: a field that typed differently once
	-- narrowed would be unadoptable on an existing template, which is the opposite
	-- of what an opt-in is for.
	local velocity: number = data.Velocity.Get()
	local health: number = data.Health.Increment(-2.5)
	local healthMin: number? = data.Health.Min()
	local healthMax: number? = data.Health.Max()
	local healthDefault: number = data.Health.Default()
	data.Velocity.Set(12.5)

	-- And the undeclared one is the same type as the narrowed ones, which is what
	-- makes adding Precision to a live field a wire change and nothing more.
	local plain: number = data.Unnarrowed.Get()
	local whole = data.Get()
	local wholeVelocity: number = whole.Velocity

	-- Same argument, CFrame edition: an exact CFrame is still a plain `CFrame` to
	-- the game and types identically to an undeclared one, so `Precision` can be
	-- added to a live field without touching a single call site.
	local aim: CFrame = data.Aim.Get()
	local placed: CFrame = data.Placed.Get()
	data.Aim.Set(CFrame.identity)
	local wholeAim: CFrame = whole.Aim

	return velocity, health, healthMin, healthMax, healthDefault, plain, wholeVelocity, aim, placed, wholeAim
end

-- Every operator the Scribe.Big docstring promises, across TWO different big fields
-- and against plain operands. Its own template because it needs a second big root
-- and containerTemplate is already at the complexity budget.
--
-- Same-field-only coverage used to pass while `a + b` across fields, `a + 5`, and
-- feeding a result back into Set were all type errors: the metamethods were typed
-- over a metatable-less copy of the shape Get returns, and Luau resolves `<` by
-- metatable IDENTITY, so every big field in a template has to share one.
local bigOpsTemplate = { Wealth = Scribe.Big(0, { Min = 0 }), Other = Scribe.Big(0) }

-- A Scribe.Big is a valid leaderboard stat: it packs exponent-major into the
-- OrderedDataStore key. Its type is the marker table rather than `number`, so the
-- stat-path walk needs its own case for it, and without this nothing here pairs a
-- big field with LeaderboardConfig<T>. It rides this template rather than the
-- container one because StatPathsType over seven marker roots is expensive enough
-- to tip this FILE (three bundles in one module) past the solver's budget.
local bigBoards: { [string]: Scribe.LeaderboardConfig<typeof(bigOpsTemplate)> } = {
	TopWealth = { Stat = "Wealth" },
	-- SigFigs splits the ranking key's budget between exponent range and resolution.
	FineWealth = { Stat = "Wealth", SigFigs = 14, StoreName = "LB_FineWealth" },
}

local bigOpsBundle = Scribe({
	Template = bigOpsTemplate,
	ProfileStoreIndex = "B",
	ProfileKeyPrefix = "B_",
	Leaderboards = bigBoards,
	Banner = false,
})

local function bigOperators(player: Player)
	local data = bigOpsBundle.Server[player]
	local summed = data.Wealth.Get() + data.Other.Get()
	local subbed = data.Wealth.Get() - 5
	local scaled = 2 * data.Wealth.Get()
	local divided = data.Wealth.Get() / "1e10"
	local negated = -data.Wealth.Get()
	local ordered: boolean = data.Wealth.Get() < data.Other.Get()
	local chained: boolean = summed <= data.Other.Get()
	local same: boolean = data.Wealth.Get() == data.Other.Get()
	local asText: string = tostring(data.Wealth.Get())
	-- An arithmetic result has to satisfy the operand union it came from.
	data.Wealth.Set(summed)
	data.Wealth.Increment(subbed)
	data.Wealth.Multiply(scaled)
	local shown: string = summed:Short()
	local lossy: number = negated:ToNumber()

	-- Pow returns the big type ITSELF, which is why it is attached with setproperty on the
	-- live type object rather than written into the props table: ts.newtable snapshots that
	-- table, so a self-referential entry added afterwards reads as a missing key. Chaining
	-- into Short and feeding the result back into Set is what proves it round-trips.
	local raised: string = data.Wealth.Get():Pow(3):Short()
	local exponent: number = data.Wealth.Get():Log10()
	data.Wealth.Set(data.Wealth.Get():Pow(2))

	-- A WHOLE-SUBTREE read must show the value, not the declarator's internal label.
	-- Scribe.Big's label lives in its metatable rather than in its fields precisely
	-- so this works: a label written as a field travels with the type into every
	-- read, and these used to come back as `{ __scribeBig: true }`.
	local whole = data.Get()
	local viaRoot: string = whole.Wealth:Short()
	local viaOther: number = whole.Other:ToNumber()
	local viaClone: string = data.Clone().Wealth:Short()

	-- A leaderboard entry's Score is `number | BigScore`, because which one it is
	-- depends on the board named at runtime. A bare `number` blessed a read that
	-- crashes on a big board; the union forces the narrow.
	local entries = bigOpsBundle.Server.GetLeaderboard("Top", 10)
	local rendered = ""
	for _, entry in entries do
		local score = entry.Score
		rendered = if type(score) == "number" then tostring(score) else score:Short()
	end

	return divided,
		ordered,
		chained,
		same,
		asText,
		shown,
		lossy,
		rendered,
		viaRoot,
		viaOther,
		viaClone,
		raised,
		exponent
end

-- Scribe.ServerOnly wrapping a declarator gets its own template, again for the
-- complexity budget. Every marker check reads a property off the same type, so a
-- ServerOnly wrapper left on hides ALL of them: the node loses its declarator
-- surface entirely and Get() types as the raw marker. The runtime always supported
-- these, so nothing but a type-level fixture can catch it.
local wrappedTemplate = {
	Unlocked = Scribe.ServerOnly(Scribe.SetOf(Scribe.String(""))),
	Wealth = Scribe.ServerOnly(Scribe.Big(0)),
	Tutorial = Scribe.ServerOnly(Scribe.Flags({ "Move", "Combat" })),
	Booster = Scribe.ServerOnly(Scribe.Timed(false)),
	Tags = Scribe.ServerOnly(Scribe.MapOf("string", Scribe.Int(0))),
	-- The inverse nesting, which relies on the second unwrap.
	Shield = Scribe.Timed(Scribe.ServerOnly(false)),
}

local wrappedBundle = Scribe({
	Template = wrappedTemplate,
	ProfileStoreIndex = "W",
	ProfileKeyPrefix = "W_",
	Banner = false,
})

local function serverOnlyWrappers(player: Player)
	local data = wrappedBundle.Server[player]
	data.Unlocked.Add("Desert")
	local members: { string } = data.Unlocked.Get()
	data.Wealth.Increment("1e40")
	local wealth: string = data.Wealth.Get():Short()
	data.Tutorial.Enable("Combat")
	local flags: { string } = data.Tutorial.Get()
	data.Booster.SetTimed(true, 60)
	local boosted: boolean = data.Booster.Active()
	data.Tags.Alpha.Set(1)
	local tags: { [string]: number } = data.Tags.Get()
	data.Shield.SetTimed(true, 30)
	return members, wealth, flags, boosted, tags
end
local function clientUsage()
	local ready: boolean = ClientData.IsReady()
	if ClientData.WaitForData(10) then
		local _: number = ClientData.Coins.Get()
	end
	ClientData.Coins.Observe(function(coins)
		local _: number = coins
	end)
	-- Replicated table field and a Scribe.Session root both stay in the client
	-- tree. Only Scribe.ServerOnly is stripped from it, so an over-broad strip
	-- breaks these two lines rather than passing silently.
	local music: boolean = ClientData.Settings.Music.Get()
	local inCombat: boolean = ClientData.Runtime.InCombat.Get()
	local rank: number? = ClientData.GetMyRank("TopCoins")
	local owns: boolean = ClientData.Owns("VIP")
	local ownsAsync: boolean = ClientData.OwnsAsync("VIP")
	local requestOk = ClientData.Request("EquipItem", "Sword_001")
	-- RequestOnce takes the idempotency key as a required second string, then the
	-- command's own arguments.
	local requestOnceOk = ClientData.RequestOnce("EquipItem", "click-1", "Sword_001")
	return rank, owns, ownsAsync, requestOk, requestOnceOk, ready, music, inCombat
end

local function diagnosticsUsage()
	-- Valid codes, levels, and categories are accepted and fully typed.
	local recent =
		Scribe.GetRecentLogs({ Code = "PROFILE_LOAD_FAIL", Level = "Error", Category = "Persistence", Limit = 10 })
	local count: number = #recent
	Scribe.AddLogSink(function(entry)
		if entry.Code == "PROFILE_SIZE" or entry.Level == "Fatal" then
			local _cat: Scribe.LogCategory = entry.Category
		end
	end)
	-- The budget snapshot is a typed record, and Available is what gates the
	-- numbers: "could not ask" is not an allowance of zero.
	local budget: Scribe.BudgetSnapshot = Scribe.GetBudgetSnapshot()
	local available: boolean = budget.Available
	local budgetReason: string? = budget.Reason
	local updates: number? = budget.Budgets.UpdateAsync
	return count, available, budgetReason, updates
end

local function typedApis(player: Player)
	-- Command: both call shapes typecheck; the handler's `player` is typed.
	Data.Command("Ping", function(_p: Player)
		return true
	end)
	Data.Command("Buy", { Args = { "string" } }, function(_p: Player, _item)
		return true, "ok"
	end)
	-- Idempotent is part of the spec shape, on its own and alongside Args.
	Data.Command("ClaimDaily", { Idempotent = true }, function(_p: Player)
		return true
	end)
	Data.Command("Spend", { Args = { "number" }, Idempotent = true }, function(_p: Player, _amount)
		return true
	end)

	-- EVERY DOCUMENTED Args FORM, and that is the point of listing them out.
	-- Commands.Register accepts a type string, ANY of ten Scribe declarators, or a
	-- shape table -- commands.md says so and security.md's headline example uses a
	-- declarator. The exported type said `{ string }`, so eight of the ten
	-- declarators and the shape form were type errors under --!strict with the new
	-- solver: a strict author copying the recommended-secure pattern got a red
	-- squiggle on it, and the obvious way to silence that is to fall back to the
	-- bare `"number"` form that commands.md itself calls "the half of the check
	-- that never catches anything interesting".
	Data.Command("ArgsString", { Args = { "string" } }, function(_p: Player, _a)
		return true
	end)
	Data.Command("ArgsScribeString", { Args = { Scribe.String("") } }, function(_p: Player, _a)
		return true
	end)
	Data.Command("ArgsEnum", { Args = { Scribe.Enum("H", { "H", "M" }) } }, function(_p: Player, _a)
		return true
	end)
	Data.Command("ArgsInt", { Args = { Scribe.Int(1, { Min = 1, Max = 10 }) } }, function(_p: Player, _a)
		return true
	end)
	Data.Command("ArgsNumber", { Args = { Scribe.Number(1) } }, function(_p: Player, _a)
		return true
	end)
	Data.Command("ArgsFlags", { Args = { Scribe.Flags({ "A", "B" }) } }, function(_p: Player, _a)
		return true
	end)
	Data.Command("ArgsOptional", { Args = { Scribe.Optional(Scribe.String("")) } }, function(_p: Player, _a)
		return true
	end)
	Data.Command("ArgsArrayOf", { Args = { Scribe.ArrayOf(Scribe.String("")) } }, function(_p: Player, _a)
		return true
	end)
	Data.Command("ArgsSetOf", { Args = { Scribe.SetOf(Scribe.String("")) } }, function(_p: Player, _a)
		return true
	end)
	Data.Command("ArgsDictOf", { Args = { Scribe.DictOf(Scribe.Int(0)) } }, function(_p: Player, _a)
		return true
	end)
	Data.Command("ArgsMapOf", { Args = { Scribe.MapOf("integer", Scribe.Int(0)) } }, function(_p: Player, _a)
		return true
	end)
	-- The shape-table form, from commands.md's "Table payloads".
	Data.Command(
		"ArgsShape",
		{ Args = { { ItemId = "string", Count = "number?", Reagents = { "string" } } } },
		function(_p: Player, _order)
			return true
		end
	)
	-- Mixed, which is what a real command looks like.
	Data.Command(
		"ArgsMixed",
		{ Args = { "string", Scribe.Int(1, { Min = 1, Max = 10 }) }, Idempotent = true },
		function(_p: Player, _a, _b)
			return true
		end
	)

	-- GetPurchases: the filter is a typed record (not a { [string]: any } bag).
	local purchases = Data.GetPurchases(player, { Kind = "Robux", Category = "Gems", Limit = 5 })

	-- GetSaveInfo.LastResult narrows to ("Ok" | "Fail")? — this assignment would
	-- fail if it were still `string?`.
	local lastResult: ("Ok" | "Fail")? = Data.GetSaveInfo(player).LastResult

	-- GetMetrics values are number | { Count, Average, Max }.
	local metrics = Scribe.GetMetrics()

	-- GetPercentiles is keyed by metric name and each record is three numbers, so
	-- indexing straight into P99 must type-check without a cast.
	local percentiles = Scribe.GetPercentiles()
	local saveDuration = percentiles.SaveDuration
	local saveP99: number? = if saveDuration then saveDuration.P99 else nil

	-- Top-level signals carry typed payloads.
	Scribe.OnStatusChanged:Connect(function(newStatus, _old)
		local _s: string = newStatus
	end)
	Scribe.OnIssue:Connect(function(entry)
		local _code: Scribe.LogCode = entry.Code
	end)

	-- Cross-server messaging and the ProfileStore escape hatch.
	local sent: boolean = Data.SendMessage(12345, { Kind = "ping" })
	Data.OnMessage:Connect(function(_p, _msg) end)
	local _store = Data.ProfileStore

	return purchases, lastResult, metrics, sent, saveP99
end

-- The exported strict config type: annotate a local (outside the Scribe literal)
-- to get Resolve's `player` typed as Player and the field names checked.
local function economyUsage(): Scribe.EconomyConfig
	return {
		Prefix = true,
		Resolve = function(player)
			return { Team = if player.Team then player.Team.Name else "None" }
		end,
		Currencies = {
			Coins = { Label = "Gold", Fields = { "Location", { Name = "Team", Prefix = false } } },
			Gems = {
				Fields = { "Zone" },
				Resolve = function(_p)
					return { Zone = "Arena" }
				end,
			},
		},
	}
end

-- Scribe.PlayerData<T> names one player's accessor tree, which consumers need to
-- store a profile in their own class. Gated here because `ValueType` is a type
-- FUNCTION and cannot be invoked across a module boundary: `Scribe.ValueType<T>`
-- silently resolves to `any` instead of erroring, so a regression is invisible.
local function playerDataAlias(player: Player): number
	local d: Scribe.PlayerData<T> = Data[player]
	d.Stats.Kills.Increment(1)
	return d.Coins.Get()
end

-- Every signal exposed on Data must also be declared in ServerDataType, or a
-- strict consumer cannot connect to it. The runtime table and the type surface
-- are edited in separate files, so this is what keeps them in sync.
local function signalSurface()
	Data.OnCooldownEnded:Connect(function(_player: Player, _key: string) end)
	Data.OnLeaderboard:Connect(function(_board: string, _entries: { any }) end)
	Data.OnOwnershipChanged:Connect(function(_player: Player, _key: string, _owned: boolean) end)
end

return {
	serverUsage = serverUsage,
	clientUsage = clientUsage,
	diagnosticsUsage = diagnosticsUsage,
	typedApis = typedApis,
	economyUsage = economyUsage,
	playerDataAlias = playerDataAlias,
	containerDeclarators = containerDeclarators,
	narrowedFloats = narrowedFloats,
	serverOnlyWrappers = serverOnlyWrappers,
	bigOperators = bigOperators,
	signalSurface = signalSurface,
}
