--!strict
-- EXPECTED_ERRORS: 7
local Scribe = require(script.Parent.Parent.Scribe)

local bundle = Scribe.new({
	Template = {
		Items = Scribe.DictOf({ Qty = Scribe.Int(1) }),
		Bag = Scribe.ArrayOf({ Qty = Scribe.Int(1) }),
		Users = Scribe.MapOf("integer", Scribe.String("")),
		Wealth = Scribe.Big("1e400"),
	},
	ProfileStoreIndex = "InteropErrors",
	ProfileKeyPrefix = "INTEROP_ERRORS_",
})

return function(player: Player)
	local data = bundle.Server.Get(player)
	data.Items.Child(1)
	data.Items.Child("Get").Qty.Set("wrong")
	data.Bag.Child("wrong")
	data.Users.Child("123456")
	data.Wealth.Get():Add(false)
	data.Wealth.Get():Add(1):Compare(false)
	local invalid: string = data.Wealth.Get():Divide(2):ToNumber()
	return invalid
end
