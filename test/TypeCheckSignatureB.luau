--!strict
-- Positive fixture for the accessor-type dedupe in ValueType. See TypeCheckSignatureA.
-- Each pair differs in exactly one thing the signature must capture, and is asserted
-- through a method only one side has, so a collision is a type error.

local Scribe = require(script.Parent.Parent.Scribe)

local template = {
	-- TAIL TYPE: identical long prefix, same last field NAME, different type.
	AlphaType = {
		AVeryLongDescriptiveFieldName00 = Scribe.String(""),
		AVeryLongDescriptiveFieldName01 = Scribe.String(""),
		AVeryLongDescriptiveFieldName02 = Scribe.String(""),
		AVeryLongDescriptiveFieldName03 = Scribe.String(""),
		AVeryLongDescriptiveFieldName04 = Scribe.String(""),
		AVeryLongDescriptiveFieldName05 = Scribe.String(""),
		AVeryLongDescriptiveFieldName06 = Scribe.String(""),
		AVeryLongDescriptiveFieldName07 = Scribe.String(""),
		AVeryLongDescriptiveFieldName08 = Scribe.String(""),
		AVeryLongDescriptiveFieldName09 = Scribe.String(""),
		AVeryLongDescriptiveFieldName10 = Scribe.String(""),
		AVeryLongDescriptiveFieldName11 = Scribe.String(""),
		AVeryLongDescriptiveFieldName12 = Scribe.String(""),
		AVeryLongDescriptiveFieldName13 = Scribe.String(""),
		AVeryLongDescriptiveFieldName14 = Scribe.String(""),
		AVeryLongDescriptiveFieldName15 = Scribe.String(""),
		Last = Scribe.Int(0),
	},
	BetaType = {
		AVeryLongDescriptiveFieldName00 = Scribe.String(""),
		AVeryLongDescriptiveFieldName01 = Scribe.String(""),
		AVeryLongDescriptiveFieldName02 = Scribe.String(""),
		AVeryLongDescriptiveFieldName03 = Scribe.String(""),
		AVeryLongDescriptiveFieldName04 = Scribe.String(""),
		AVeryLongDescriptiveFieldName05 = Scribe.String(""),
		AVeryLongDescriptiveFieldName06 = Scribe.String(""),
		AVeryLongDescriptiveFieldName07 = Scribe.String(""),
		AVeryLongDescriptiveFieldName08 = Scribe.String(""),
		AVeryLongDescriptiveFieldName09 = Scribe.String(""),
		AVeryLongDescriptiveFieldName10 = Scribe.String(""),
		AVeryLongDescriptiveFieldName11 = Scribe.String(""),
		AVeryLongDescriptiveFieldName12 = Scribe.String(""),
		AVeryLongDescriptiveFieldName13 = Scribe.String(""),
		AVeryLongDescriptiveFieldName14 = Scribe.String(""),
		AVeryLongDescriptiveFieldName15 = Scribe.String(""),
		Last = Scribe.String(""),
	},

	-- INDEXER: same element, different key type. Skipping the indexer would let the
	-- integer map take the string map's accessor.
	IntMap = Scribe.MapOf("integer", Scribe.Int(0)),
	StrMap = Scribe.MapOf("string", Scribe.Int(0)),

	-- INDEXER, isolated: no properties and no brand, so the element type is the only
	-- difference.
	IntList = Scribe.ArrayOf(Scribe.Int(0)),
	StrList = Scribe.ArrayOf(Scribe.String("")),

	-- METATABLE: both are `{ string }` underneath and differ only by the brand.
	-- Asserted through Enable and Add, since Has exists on both.
	FlagSet = Scribe.Flags({ "Move", "Combat" }),
	StringSet = Scribe.SetOf(Scribe.String("")),
}

local bundle = Scribe({
	Template = template,
	Transport = "Default",
	ProfileStoreIndex = "SignatureFixtureB",
	ProfileKeyPrefix = "SIGB_",
})

local Data = bundle.Server

return function(player: Player)
	local data = Data[player]

	local c: number = data.AlphaType.Last.Get()
	local d: string = data.BetaType.Last.Get()

	data.IntMap.Remove(1)
	data.StrMap.Remove("a")

	data.IntList.Insert(1)
	data.StrList.Insert("x")

	data.FlagSet.Enable("Move")
	data.StringSet.Add("x")

	return c + #d
end
