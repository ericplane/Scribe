--!nonstrict
-- Data.Mock replaces lists and merges records, dictionaries and maps by key.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe) :: any

local function make()
	return Scribe({
		Template = {
			OwnedLicences = Scribe.SetOf(Scribe.String("")),
			Bag = Scribe.ArrayOf(Scribe.String("")),
			Badges = Scribe.Flags({ "A", "B", "C" }),
			Daily = {
				QuestDay = Scribe.Int(0, { Min = 0 }),
				PlaySeconds = Scribe.Int(0, { Min = 0 }),
				QuestsClaimed = Scribe.SetOf(Scribe.String("")),
				Log = Scribe.ArrayOf({ Id = Scribe.String(""), At = Scribe.Int(0) }),
				Mood = Scribe.Flags({ "Happy", "Sad" }),
				Notes = {},
				Slots = Scribe.MapOf("integer", Scribe.String("")),
			},
			Wallet = Scribe.DictOf(Scribe.Int(0)),
			Backpack = Scribe.MapOf("integer", Scribe.String("")),
			Outfits = Scribe.DictOf(Scribe.ArrayOf(Scribe.String(""))),
			Pets = Scribe.DictOf({ Name = Scribe.String(""), Mood = Scribe.Flags({ "Happy", "Sad" }) }),
			Blobs = {},
			Listy = { "a", "b", "c" },
			Loose = {},
			Shelves = Scribe.DictOf(Scribe.MapOf("integer", Scribe.String(""))),
			Wealth = Scribe.Big(0),
			Vault = { Wealth = Scribe.Big(0) },
		},
		ProfileStoreIndex = "MockMerge",
		ProfileKeyPrefix = "PLAYER_",
		IsRunning = false,
		Banner = false,
	}).Client
end

local function list(value: { any }): string
	local parts = {}
	for index, item in value do
		table.insert(parts, `{index}:{tostring(item)}`)
	end
	return table.concat(parts, ",")
end

local function keyed(value: { [any]: any }): string
	local parts = {}
	for key, item in value do
		table.insert(parts, `{tostring(key)}={tostring(item)}`)
	end
	table.sort(parts)
	return table.concat(parts, ",")
end

describe("a list-like value is replaced whole", function()
	it("empties a set nested in a record with {}", function()
		local Data = make()
		Data.Mock({ Daily = { QuestsClaimed = { "Q1", "Q2" } } })
		Data.Mock({ Daily = { QuestsClaimed = {} } })
		expect(`[{list(Data.Daily.QuestsClaimed.Get())}]`).toBe("[]")
	end)

	it("empties a root set with {}", function()
		local Data = make()
		Data.Mock({ OwnedLicences = { "L1" } })
		Data.Mock({ OwnedLicences = {} })
		expect(`[{list(Data.OwnedLicences.Get())}]`).toBe("[]")
	end)

	it("replaces a longer array with a shorter one", function()
		local Data = make()
		Data.Mock({ Bag = { "a", "b", "c" } })
		Data.Mock({ Bag = { "x" } })
		expect(list(Data.Bag.Get())).toBe("1:x")
	end)

	it("replaces a set's members rather than overlaying them", function()
		local Data = make()
		Data.Mock({ OwnedLicences = { "L1", "L2" } })
		Data.Mock({ OwnedLicences = { "L3" } })
		expect(list(Data.OwnedLicences.Get())).toBe("1:L3")
	end)

	it("replaces and empties a root Flags list", function()
		local Data = make()
		Data.Mock({ Badges = { "A", "B" } })
		Data.Mock({ Badges = { "C" } })
		local replaced = list(Data.Badges.Get())
		Data.Mock({ Badges = {} })
		expect(`{replaced} | [{list(Data.Badges.Get())}]`).toBe("1:C | []")
	end)

	it("takes a Flags seed as the whole set of enabled names, however it is keyed", function()
		local Data = make()
		Data.Mock({ Badges = { "A", "B" } })
		Data.Mock({ Badges = { [2] = "C" } })
		expect(list(Data.Badges.Get())).toBe("1:C")
	end)

	it("empties a Flags list in a record and keeps its siblings", function()
		local Data = make()
		Data.Mock({ Daily = { QuestDay = 4, Mood = { "Happy", "Sad" } } })
		Data.Mock({ Daily = { Mood = {} } })
		expect(`{Data.Daily.QuestDay.Get()} [{list(Data.Daily.Mood.Get())}]`).toBe("4 []")
	end)

	it("empties a Flags list in a dictionary entry and keeps the entry's other fields", function()
		local Data = make()
		Data.Mock({ Pets = { Rex = { Name = "Rex", Mood = { "Happy", "Sad" } } } })
		Data.Mock({ Pets = { Rex = { Mood = {} } } })
		local rex = Data.Pets.Get().Rex
		expect(`{rex.Name} [{list(rex.Mood)}]`).toBe("Rex []")
	end)

	it("replaces an array of records inside a record, defaulting fields the seed omits", function()
		local Data = make()
		Data.Mock({ Daily = { Log = { { Id = "a", At = 1 }, { Id = "b", At = 2 } } } })
		Data.Mock({ Daily = { Log = { { Id = "c" } } } })
		local log = Data.Daily.Log.Get()
		expect(`{#log} {log[1].Id} {log[1].At}`).toBe("1 c 0")
	end)

	it("replaces an array inside a dictionary entry and keeps the other entries", function()
		local Data = make()
		Data.Mock({ Outfits = { Day = { "hat", "coat" }, Night = { "cape" } } })
		Data.Mock({ Outfits = { Day = { "cap" } } })
		local outfits = Data.Outfits.Get()
		expect(`Day[{list(outfits.Day)}] Night[{list(outfits.Night)}]`).toBe("Day[1:cap] Night[1:cape]")
	end)

	it("tells an observer the set is now empty", function()
		local Data = make()
		Data.Mock({ Daily = { QuestsClaimed = { "Q1" } } })
		local seen = "never fired"
		Data.Daily.QuestsClaimed.Changed(function(new, old)
			seen = `[{list(new)}] from [{list(old)}]`
		end)
		Data.Mock({ Daily = { QuestsClaimed = {} } })
		expect(seen).toBe("[] from [1:Q1]")
	end)

	it("refuses an index patch into an array, which must be passed whole", function()
		local Data = make()
		Data.Mock({ Bag = { "a", "b", "c" } })
		local ok, err = pcall(Data.Mock, { Bag = { [2] = "y" } })
		local named = string.find(tostring(err), "no holes", 1, true) ~= nil
		expect(`ok={ok} named={named} kept={list(Data.Bag.Get())}`).toBe("ok=false named=true kept=1:a,2:b,3:c")
	end)
end)

describe("a leaf is replaced whole", function()
	it("seeds a Big with a value read from another Big", function()
		local Data = make()
		Data.Mock({ Wealth = "1e30", Vault = { Wealth = "1e20" } })
		Data.Mock({ Wealth = Data.Vault.Wealth.Get() })
		expect(tostring(Data.Wealth.Get())).toBe("1e20")
	end)
end)

describe("an untyped table is judged by its value", function()
	it("replaces and empties a list", function()
		local Data = make()
		Data.Mock({ Blobs = { "a", "b", "c" } })
		Data.Mock({ Blobs = { "x" } })
		local replaced = list(Data.Blobs.Get())
		Data.Mock({ Blobs = {} })
		expect(`{replaced} | [{list(Data.Blobs.Get())}]`).toBe("1:x | []")
	end)

	it("replaces a list declared with a list default", function()
		local Data = make()
		Data.Mock({ Listy = { "x" } })
		expect(list(Data.Listy.Get())).toBe("1:x")
	end)

	it("replaces a list nested in a record", function()
		local Data = make()
		Data.Mock({ Daily = { Notes = { "one", "two" } } })
		Data.Mock({ Daily = { Notes = { "three" } } })
		expect(list(Data.Daily.Notes.Get())).toBe("1:three")
	end)

	it("still merges a string-keyed table, and {} leaves it alone", function()
		local Data = make()
		Data.Mock({ Loose = { a = 1, b = 2 } })
		Data.Mock({ Loose = { b = 3 } })
		local merged = keyed(Data.Loose.Get())
		Data.Mock({ Loose = {} })
		expect(`{merged} | {keyed(Data.Loose.Get())}`).toBe("a=1,b=3 | a=1,b=3")
	end)
end)

describe("records, dictionaries and maps still merge key by key", function()
	it("keeps a record's other fields, its set included", function()
		local Data = make()
		Data.Mock({ Daily = { QuestDay = 3, QuestsClaimed = { "Q1" } } })
		Data.Mock({ Daily = { PlaySeconds = 60 } })
		local daily = Data.Daily.Get()
		expect(`{daily.QuestDay} {daily.PlaySeconds} [{list(daily.QuestsClaimed)}]`).toBe("3 60 [1:Q1]")
	end)

	it("merges a dictionary entry by entry", function()
		local Data = make()
		Data.Mock({ Wallet = { Gold = 5, Gems = 2 } })
		Data.Mock({ Wallet = { Gems = 9 } })
		expect(keyed(Data.Wallet.Get())).toBe("Gems=9,Gold=5")
	end)

	it("merges a map entry by entry, so one slot can be cleared", function()
		local Data = make()
		Data.Mock({ Backpack = { [1] = "rope", [2] = "lamp", [3] = "map" } })
		Data.Mock({ Backpack = { [2] = "" } })
		expect(keyed(Data.Backpack.Get())).toBe("1=rope,2=,3=map")
	end)

	it("merges a map even when the seed is shaped like a list", function()
		local Data = make()
		Data.Mock({ Backpack = { "rope", "lamp" } })
		Data.Mock({ Backpack = { "hat" } })
		expect(keyed(Data.Backpack.Get())).toBe("1=hat,2=lamp")
	end)

	it("merges a map nested in a record", function()
		local Data = make()
		Data.Mock({ Daily = { Slots = { "a", "b" } } })
		Data.Mock({ Daily = { Slots = { "c" } } })
		expect(keyed(Data.Daily.Slots.Get())).toBe("1=c,2=b")
	end)

	it("merges a map inside a dictionary entry", function()
		local Data = make()
		Data.Mock({ Shelves = { Top = { "x", "y" } } })
		Data.Mock({ Shelves = { Top = { "z" } } })
		expect(keyed(Data.Shelves.Get().Top)).toBe("1=z,2=y")
	end)

	it("cannot empty a dictionary, which Set does instead", function()
		local Data = make()
		Data.Mock({ Wallet = { Gold = 5 } })
		Data.Mock({ Wallet = {} })
		local afterMock = keyed(Data.Wallet.Get())
		Data.Wallet.Set({})
		expect(`{afterMock} | [{keyed(Data.Wallet.Get())}]`).toBe("Gold=5 | []")
	end)
end)
