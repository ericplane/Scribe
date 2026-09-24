--!strict
-- Positive fixture for the shared, explicitly callable interoperability helpers.
local Scribe = require(script.Parent.Parent.Scribe)

local bundle = Scribe.new({
	Template = {
		Items = Scribe.DictOf({ Qty = Scribe.Int(1) }),
		Bag = Scribe.ArrayOf({ Qty = Scribe.Int(1) }),
		Users = Scribe.MapOf("integer", Scribe.String("")),
		Wealth = Scribe.Big("1e400"),
	},
	ProfileStoreIndex = "Interop",
	ProfileKeyPrefix = "INTEROP_",
})

return function(player: Player)
	local data = bundle.Server.Get(player)
	local item = data.Items.Child("Get")
	local amount: number = item.Qty.Increment(1)
	local arrayAmount: number = data.Bag.Child(1).Qty.Get()
	local friend: string = data.Users.Child(123456).Get()
	local original = data.Wealth.Get()
	local result = original:Add("2e400"):Subtract(original):Multiply(3):Divide(2):Negate()
	local exponent: number = result.E
	local comparison: number = result:Compare("1e400")
	local equal: boolean = result:Equals(original)
	local rendered: string = result:Short()
	data.Wealth.Set(result)
	return amount, arrayAmount, friend, exponent, comparison, equal, rendered
end
