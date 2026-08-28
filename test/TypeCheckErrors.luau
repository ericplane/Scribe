--!strict
-- Negative typecheck fixture: every marked line MUST produce a TypeError
-- under the new solver. The verification gate asserts this file reports
-- exactly EXPECTED_ERRORS diagnostics: if a change silently loosens the
-- template-aware config types, this file starts passing and the gate fails.
--
-- EXPECTED_ERRORS: 27

local Scribe = require(script.Parent.Parent.Scribe)

local template = {
	Coins = Scribe.Int(0, { Min = 0 }),
	Stats = { Kills = 0 },
	Nick = "",
	Quests = {} :: { number },
	Bag = Scribe.ArrayOf(Scribe.Int(0)),
	Secret = Scribe.ServerOnly({ Flagged = false }),
	Squad = Scribe.ArrayOf({ Name = Scribe.String(""), Hidden = Scribe.ServerOnly(Scribe.Int(0)) }),
	Furniture = Scribe.ArrayOf({
		Cf = Scribe.CFrame(CFrame.identity),
		Note = Scribe.Optional(Scribe.String("")),
	}),
	Doubled = Scribe.Derived(Scribe.Int(0), { "Coins" }, function(coins: number): number
		return coins * 2
	end),
}

type T = typeof(template)

local bundle = Scribe({ Template = template, ProfileStoreIndex = "D", ProfileKeyPrefix = "P_", Banner = false })
local Data = bundle.Server

local function rootAndRemove(player: Player)
	-- 4) The root accessor has no Set at runtime; it must not typecheck.
	Data[player].Set({ Coins = 0 }) -- TypeError: Set is not a member of the root

	-- 5) Array Remove returns an optional; assigning to a non-optional errors.
	local last: number = Data[player].Quests.Remove() -- TypeError: number? vs number
	return last
end

-- 1) Stat must be a numeric leaf path of the template.
local badBoards: { [string]: Scribe.LeaderboardConfig<T> } = {
	Top = { Stat = "Coinz" }, -- TypeError: not a template path
}

-- 2) Nick is a string leaf, not numeric, so not a valid stat.
local badStat: { [string]: Scribe.LeaderboardConfig<T> } = {
	Top = { Stat = "Nick" }, -- TypeError: string leaf excluded from the union
}

-- 3) Grant's data is the typed accessor tree.
local badProducts: { [string]: Scribe.ProductConfig<T> } = {
	P = {
		Id = 1,
		Grant = function(data)
			data.Coins.Set("not a number") -- TypeError: Coins is a number field
		end,
	},
}

-- 6) A wrong-typed option is caught at the Scribe({...}) call.
local badOption = Scribe({
	Template = template,
	ProfileStoreIndex = "Data",
	ProfileKeyPrefix = "PLAYER_",
	SaveInterval = "sixty", -- TypeError: string vs number?
})

-- 7) A wrong enum-literal option is caught too.
local badEnum = Scribe({
	Template = template,
	ProfileStoreIndex = "Data",
	ProfileKeyPrefix = "PLAYER_",
	LoadFailurePolicy = "Sometimes", -- TypeError: not "Kick" | "Wait"
})

-- 8) Omitting the now-required ProfileStoreIndex is a type error.
local missingStore = Scribe({
	Template = template,
	ProfileKeyPrefix = "PLAYER_", -- TypeError: ProfileStoreIndex is required
})

-- 9) An unknown log code is rejected by the typed Code union in the filter.
local badLog = Scribe.GetRecentLogs({ Code = "NOT_A_REAL_CODE" }) -- TypeError: not a LogCode

local function badTypedApis(player: Player)
	-- 10) Command's 2nd arg must be a spec table or a handler function.
	Data.Command("X", 123) -- TypeError: 123 is neither a spec nor a handler
	-- 10b) Idempotent is a boolean. A truthy string would opt the command IN at the
	-- call site and OUT of the `== true` check, so commands would silently run twice.
	Data.Command("Y", { Idempotent = "yes" }, function(_p: Player) end) -- TypeError: string vs boolean?
	-- 11) GetPurchases filter Kind must be "Robux" | "InGame".
	Data.GetPurchases(player, { Kind = "Bitcoin" }) -- TypeError: Kind not "Robux" | "InGame"
	-- 12) SendMessage's userId must be a number.
	Data.SendMessage("not-a-number", {}) -- TypeError: string vs number
end

local function badLifecycleReason()
	-- 16) The reason is a typed union, so an old/misspelled value does not fit.
	local typed: Scribe.LifecycleReason = "session-end" -- TypeError: not a member
	return typed
end

local function badContainers(player: Player)
	-- 13) An ArrayOf element is typed, so Insert rejects the wrong element type.
	Data[player].Bag.Insert("x") -- TypeError: string vs number element

	-- 14) A declared element FIELD is typed too, reached by numeric index.
	Data[player].Furniture[1].Cf.Set("nope") -- TypeError: string vs CFrame

	-- 15) Scribe.Optional makes the field nilable; assigning to a non-optional errors.
	local note: string = Data[player].Furniture[1].Note.Get() -- TypeError: string? vs string
	return note
end

local function serverOnlyOnClient(player: Player)
	local Client = bundle.Client
	-- 16) A Scribe.ServerOnly field is never replicated, so it must not appear in
	-- the CLIENT accessor type. It reads nil at runtime; before the marker type it
	-- typechecked clean, which is the worst shape a defect can take.
	local flagged: boolean = Client.Secret.Flagged.Get() -- TypeError: Secret is not a member of the client tree
	-- 17) A Scribe.ServerOnly field inside an element shape is behind the indexer,
	-- not in properties. It never replicates either, so it must be gone from the
	-- client type too rather than typing clean and reading nil.
	local hidden: number = Client.Squad[1].Hidden.Get() -- TypeError: Hidden is not on the client
	-- The server still reads it normally, so this line must stay CLEAN. Its
	-- absence would mean the strip leaked into ValueType and broke every
	-- ServerOnly field everywhere.
	local onServer: boolean = Data[player].Secret.Flagged.Get()
	return flagged, onServer, hidden
end

-- Scribe.Big and Scribe.MapOf get their own small template: the one above is
-- already close to the new solver's complexity budget.
local bigTemplate = {
	Coins = Scribe.Big(0, { Min = 0 }),
	Gems = Scribe.Int(0, { Min = 0 }),
	Nick = Scribe.String(""),
	Tags = Scribe.MapOf("string", Scribe.Int(0)),
}

type BigT = typeof(bigTemplate)

-- 18) A typo is still caught alongside a Scribe.Big field. TypeCheck.luau asserts
-- the positive half, that a big field IS an accepted stat.
local bigBoards: { [string]: Scribe.LeaderboardConfig<BigT> } = {
	Typo = { Stat = "Coinz" }, -- TypeError: not a template path
}

-- 19) A purchase cost path must be a plain number balance. Monetization refuses a
-- non-number at runtime, so a big path is rejected here rather than at the till.
local bigCost: Scribe.PurchaseSpec<BigT> = {
	Cost = { Path = "Coins", Amount = 5 }, -- TypeError: a big is not a cost path
	ItemId = "Hat",
}

local bigBundle = Scribe({ Template = bigTemplate, ProfileStoreIndex = "E", ProfileKeyPrefix = "E_", Banner = false })

-- 22) A leaderboard entry's Score is `number | BigScore`, because a Scribe.Big
-- board hands back the big itself. Reading it straight into a number has to be
-- refused: it typechecked clean and crashed on a big board. This case is the only
-- thing pinning the union, since a positive fixture narrows and the dead branch
-- swallows the difference.
local function badScore()
	local entries = bigBundle.Server.GetLeaderboard("Top", 10)
	local n: number = entries[1].Score -- TypeError: the union is not a number
	return n
end

local function badMapContainer(player: Player)
	local data = bigBundle.Server[player]
	-- 20) The map node reads and writes the WHOLE map. Typing it as its element
	-- made this line clean and the correct whole-map read a type error.
	data.Tags.Set(5) -- TypeError: number vs { [string]: number }
	-- 21) And the element's own methods must not leak onto the container.
	data.Tags.Increment(5) -- TypeError: Increment is not on a map node
	return data.Tags.Get()
end

local function badDerived(player: Player)
	local data = bundle.Server[player]
	-- 24) A derived field is computed, so the mutators are absent from its type.
	data.Doubled.Set(10) -- TypeError: Set is not on a derived node
	-- 25) Including the numeric ones.
	data.Doubled.Increment(1) -- TypeError: Increment is not on a derived node
	-- 26) It still reads as its output declarator, so this assignment is wrong.
	local wrong: string = data.Doubled.Get() -- TypeError: number vs string
	return wrong
end

return {
	badDerived,
	badBoards,
	badStat,
	badProducts,
	rootAndRemove,
	badOption,
	badEnum,
	missingStore,
	badLog,
	badTypedApis,
	badContainers,
	badLifecycleReason,
	serverOnlyOnClient,
	bigBoards,
	bigCost,
	badMapContainer,
	badScore,
}
