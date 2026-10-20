--!strict
-- EXPECTED_ERRORS: 29
-- Each invalid write, argument or wrapped-value use must report one type error.
local Scribe = require(script.Parent.Parent.Scribe)

local template = {
	Coins = Scribe.Int(0),
	Wealth = Scribe.Big(0),
	Shield = Scribe.Timed(false),
	Note = Scribe.Optional(Scribe.String("")),
	Score = Scribe.Optional(Scribe.Int(0)),
	Doubled = Scribe.Derived(Scribe.Int(0), { "Coins" }, function(coins)
		return coins * 2
	end),
	Rich = Scribe.Derived(false, { "Coins" }, function(coins)
		return coins > 100
	end),
	HiddenCd = Scribe.ServerOnly(Scribe.Timed(0)),
	Hidden = Scribe.Timed(Scribe.ServerOnly(false)),
	OptHidden = Scribe.Optional(Scribe.ServerOnly(Scribe.Int(0))),
	Items = Scribe.ArrayOf({ Id = Scribe.String(""), Cost = Scribe.ServerOnly(Scribe.Int(0)) }),
	HiddenSet = Scribe.SetOf(Scribe.ServerOnly(Scribe.Int(0))),
}

local boards: { [string]: Scribe.LeaderboardConfig<typeof(template)> } = {
	Bad = { Stat = "HiddenCd.__scribeTimed" }, -- 1: the internal label path
}

local bundle = Scribe({
	Template = template,
	ServerStore = { Wave = Scribe.Int(0), Pool = Scribe.ArrayOf(Scribe.Int(0)) },
	Leaderboards = boards,
	ProfileStoreIndex = "TypeCheckPrecisionErrors",
	ProfileKeyPrefix = "PLAYER_",
})

bundle.Server = bundle.Server -- 2: the halves are read-only
local _mine: { Server: Scribe.ServerData<typeof(template), any> } = bundle -- 3: a read/write record does not take it
bundle.Server.Raw = nil -- 4: so are the API members
bundle.Client.Raw = nil -- 5: on both sides
local _spec: Scribe.PurchaseSpec<typeof(template)> =
	{ Cost = { Path = "Coins", Amount = 1 }, ItemId = "a", IdempotencyKey = 5 } -- 24
local _product: Scribe.ProductConfig<typeof(template)> = { Id = 1, PaidRandom = "yes" } -- 25

return function(player: Player)
	local data = bundle.Server[player]
	local client = bundle.Client

	data.Coins.Increment(1, "oops") -- 6: tags are a table or a flag
	data.Coins.Decrement(1, { Flow = "Sourse" }) -- 7
	data.Coins.Increment(1, { ItemSku = 5 }) -- 8
	data.Wealth.Decrement(1, "x") -- 9

	local _wrongDerived: boolean = data.Doubled.Get() -- 10: a number, not any

	client.Shield.SetTimed(true, 30) -- 11: the client cannot set a deadline
	client.Shield.ExtendTimed(10) -- 12
	data.Doubled.Set(5) -- 13: derived fields take no writes
	data.Doubled.Increment(5) -- 14
	data.Rich.Toggle() -- 15
	client.ServerStore.Wave.Set(3) -- 16: the client's server store is read-only
	client.ServerStore.Wave.Increment(1) -- 17
	client.ServerStore.Pool.Insert(1) -- 18

	local _stillOptional: number = data.Score.Get() -- 19: reads stay optional
	data.Note.Increment(1) -- 20: a string has no Increment

	bundle.Server.Purchase(player, { Cost = { Path = "Coins", Amount = 5 }, ItemId = "a", IdempotencyKey = 123 }) -- 21
	bundle.Server.Purchase(player, { Cost = { Path = "Coins", Amount = 5 }, ItemId = "a", PaidRandom = "yes" }) -- 22

	local _gone = client.Hidden.Get() -- 23: server-only under Timed is absent on the client
	local _goneOptional = client.OptHidden -- 26: and under Optional
	local _goneElement = client.Items.Get()[1].Cost -- 27: and inside a container element
	data.Items.Insert({ Id = "a", Cost = "5" }) -- 28: the element field takes its value type
	data.HiddenSet.Add("5") -- 29: a set's server-only element takes its value type
end
