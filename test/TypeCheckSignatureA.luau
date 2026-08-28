--!strict
-- Positive fixture for the accessor-type dedupe in ValueType.
--
-- build() memoises identical subtrees by a canonical signature. If that key is not
-- injective two subtrees collide and one gets the other's accessor, so every pair
-- here must not collide, written so a collision is a type error rather than a
-- silently wrong type.
--
-- The long field names are load-bearing: they push a pair past the point where
-- tostring(type) truncates. Shortening them makes this file pass vacuously.
--
-- Split in two, and kept out of TypeCheck.luau, because each file has to stay inside
-- the solver's complexity budget on its own.

local Scribe = require(script.Parent.Parent.Scribe)

local template = {
	-- TAIL NAME: identical long prefix, different last field name.
	AlphaName = {
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
		UniqueToAlpha = Scribe.Int(0),
	},
	BetaName = {
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
		UniqueToBeta = Scribe.Int(0),
	},
}

local bundle = Scribe({
	Template = template,
	Transport = "Default",
	ProfileStoreIndex = "SignatureFixtureA",
	ProfileKeyPrefix = "SIGA_",
})

local Data = bundle.Server

return function(player: Player)
	local data = Data[player]
	-- Each record still carries its OWN tail field.
	local a: number = data.AlphaName.UniqueToAlpha.Get()
	local b: number = data.BetaName.UniqueToBeta.Get()
	return a + b
end
