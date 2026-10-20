--!strict
-- Type precision for read-only APIs, wrapper nesting and client restrictions.
-- Exact catches any leakage that plain annotations accept. Not shipped.

local Scribe = require(script.Parent.Parent.Scribe)
local ScribeLeaderstats = require(script.Parent.Parent.Addons.Leaderstats.ScribeLeaderstats)

-- selene: allow(undefined_variable)
type function Exact(T, Label)
	if T:is("any") then
		error(`leaked any: {Label:value()}`)
	end
	return T
end

-- Set and map reads must retain their metatable brand.
-- selene: allow(undefined_variable)
type function Branded(T, Label)
	if not T:is("table") or T:metatable() == nil then
		error(`lost its brand: {Label:value()}`)
	end
	return T
end

local template = {
	Coins = Scribe.Int(0),
	Wealth = Scribe.Big(0),
	Shield = Scribe.Timed(false),
	Tags = Scribe.Flags({ "A", "B" }),
	Score = Scribe.Optional(Scribe.Int(0, { Max = 10 })),
	Muted = Scribe.Optional(false),
	Unlocked = Scribe.SetOf(Scribe.String("")),
	Bag = Scribe.ArrayOf(Scribe.String("")),
	Doubled = Scribe.Derived(Scribe.Int(0, { Max = 99 }), { "Coins" }, function(coins)
		return coins * 2
	end),
	Rich = Scribe.Derived(false, { "Coins" }, function(coins)
		return coins > 100
	end),
	HiddenCd = Scribe.ServerOnly(Scribe.Timed(0)),
	Hidden = Scribe.Timed(Scribe.ServerOnly(false)),
	OptHidden = Scribe.Optional(Scribe.ServerOnly(Scribe.Int(0))),
	Prefs = { Hint = Scribe.Optional(Scribe.ServerOnly(Scribe.Int(0))), Volume = Scribe.Int(0) },
	Items = Scribe.ArrayOf({ Id = Scribe.String(""), Cost = Scribe.ServerOnly(Scribe.Int(0)) }),
	Ledger = Scribe.MapOf("integer", { Note = Scribe.String(""), Audit = Scribe.ServerOnly(Scribe.Int(0)) }),
	HiddenSet = Scribe.SetOf(Scribe.ServerOnly(Scribe.Int(0))),
	HiddenMap = Scribe.MapOf("integer", Scribe.ServerOnly(Scribe.Int(0))),
}

local boards: { [string]: Scribe.LeaderboardConfig<typeof(template)> } = {
	Cooldowns = { Stat = "HiddenCd" },
}

local bundle = Scribe({
	Template = template,
	ServerStore = { Wave = Scribe.Int(0), Pool = Scribe.ArrayOf(Scribe.Int(0)) },
	Leaderboards = boards,
	Products = { Pack = { Id = 1, PaidRandom = true } },
	ProfileStoreIndex = "TypeCheckPrecision",
	ProfileKeyPrefix = "PLAYER_",
})

-- Frozen bundles retain both API types.
local frozen: Scribe.Bundle<typeof(template), any> = table.freeze(bundle)
local Server = frozen.Server
local Client = bundle.Client

-- Addon compatibility with read-only API fields.
ScribeLeaderstats.Start(Server, { Coins = "Coins" })

local function label<T>(node: Scribe.ReadableNode<T>): T
	return node.Get()
end

-- Annotate helper results to preserve Flow's literal type.
local function sinkTags(sku: string): Scribe.EconomyMeta
	return { Flow = "Sink", ItemSku = sku }
end

return function(player: Player)
	local data = Server[player]

	-- Accept flags and inline or annotated tags.
	data.Coins.Increment(1)
	data.Coins.Increment(1, true)
	data.Coins.Increment(1, { Flow = "Source", ItemSku = "Sword" })
	local tags = { ItemSku = "Shield", Currency = "Gold" }
	data.Coins.Decrement(1, tags)
	data.Coins.Increment(1, { TransactionType = Enum.AnalyticsEconomyTransactionType.Shop })
	data.Coins.Increment(1, { TransactionType = "Shop", Fields = { Zone = "Lobby" } })
	data.Wealth.Increment(5, { Flow = "Sink" })
	data.Coins.Decrement(1, sinkTags("Sword"))

	-- Derived inference follows the output declarator.
	local doubled: Exact<typeof(data.Doubled.Get()), "derived"> = data.Doubled.Get()
	local doubledMax: Exact<typeof(data.Doubled.Max()), "derived-max"> = data.Doubled.Max()
	local rich: Exact<typeof(data.Rich.Get()), "derived-boolean"> = data.Rich.Get()

	-- Server writes and client reads.
	data.Shield.SetTimed(true, 30)
	data.Shield.ExtendTimed(10)
	local active: boolean = Client.Shield.Active()
	Client.Coins.Set(5)
	data.Tags.Enable("A")
	Server.ServerStore.Wave.Set(3)
	Server.ServerStore.Pool.Insert(1)
	local wave: Exact<typeof(Client.ServerStore.Wave.Get()), "client-store"> = Client.ServerStore.Wave.Get()

	-- Optional scalars keep their methods; sets expose Find.
	local scoreMax: Exact<typeof(data.Score.Max()), "optional-max"> = data.Score.Max()
	local scored: Exact<typeof(data.Score.Increment(1)), "optional-increment"> = data.Score.Increment(1)
	local muted: Exact<typeof(data.Muted.Toggle()), "optional-toggle"> = data.Muted.Toggle()
	local found: Exact<typeof(data.Unlocked.Find("x")), "set-find"> = data.Unlocked.Find("x")

	-- Purchase fields and the idempotency refusal constant.
	local _ok, reason = Server.Purchase(player, {
		Cost = { Path = "Coins", Amount = 5 },
		ItemId = "Sword",
		IdempotencyKey = "k1",
		PaidRandom = false,
	})
	local refusedKey: boolean = reason == Scribe.PurchaseReason.InvalidIdempotencyKey

	-- Public aliases and generic reads.
	local coins: Exact<typeof(label(data.Coins)), "readable-node"> = label(data.Coins)
	local bag: { string } = label(Client.Bag)
	local path: Scribe.Path = { "Coins" }
	local state: Scribe.SessionState = "Ready"
	local stop: Scribe.Disconnect = data.Coins.Observe(function() end)

	-- Nested wrappers retain server methods and value types.
	local hidden: boolean = data.Hidden.Get()
	local optHidden: number? = data.OptHidden.Get()
	data.OptHidden.Increment(1)
	-- Parent and element reads must also unwrap values.
	local whole: number? = data.Get().OptHidden
	data.Prefs.Set({ Hint = 3, Volume = 1 })
	local hint: number? = data.Prefs.Get().Hint
	data.Items.Insert({ Id = "a", Cost = 5 })
	local at: number? = data.Items.Find({ Id = "a", Cost = 5 })
	data.Items.OnInsert(function(item)
		local _cost: number = item.Cost
	end)
	data.Ledger.Set({ [1] = { Note = "n", Audit = 2 } })
	data.Ledger.OnKeyAdded(function(_key, entry)
		local _audit: number = entry.Audit
	end)
	-- Unwrapping elements must preserve set and map brands.
	local _ledger: Branded<typeof(data.Ledger.Get()), "map-record-element"> = data.Ledger.Get()
	local hiddenSet: Branded<typeof(data.HiddenSet.Get()), "set-element"> = data.HiddenSet.Get()
	local _members: { number } = hiddenSet
	data.HiddenSet.Add(5)
	local _isMember: boolean = data.HiddenSet.Has(5)
	local hiddenMap: Branded<typeof(data.HiddenMap.Get()), "map-element"> = data.HiddenMap.Get()
	local _amounts: { [number]: number } = hiddenMap
	data.HiddenMap.Child(3).Set(5)
	data.Prefs.OnChildChanged(function(_key, new)
		local _value: number? = new
	end)
	data.Items.OnChildChanged(function(_index, new)
		local _cost: number? = if new then new.Cost else nil
	end)

	return doubled,
		doubledMax,
		rich,
		active,
		wave,
		scoreMax,
		scored,
		muted,
		found,
		refusedKey,
		coins,
		bag,
		path,
		state,
		stop,
		hidden,
		optHidden,
		whole,
		hint,
		at
end
