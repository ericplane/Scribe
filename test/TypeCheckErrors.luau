--!strict
-- Negative typecheck fixture: every marked line MUST produce a TypeError
-- under the new solver. The verification gate asserts this file reports
-- exactly EXPECTED_ERRORS diagnostics — if a change silently loosens the
-- template-aware config types, this file starts passing and the gate fails.
--
-- EXPECTED_ERRORS: 16

local Scribe = require(script.Parent.Parent.Scribe)

local template = {
	Coins = Scribe.Int(0, { Min = 0 }),
	Stats = { Kills = 0 },
	Nick = "",
	Quests = {} :: { number },
	Bag = Scribe.ArrayOf(Scribe.Int(0)),
	Furniture = Scribe.ArrayOf({
		Cf = Scribe.CFrame(CFrame.identity),
		Note = Scribe.Optional(Scribe.String("")),
	}),
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

-- 2) Nick is a string leaf, not numeric — not a valid stat.
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

return {
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
}
