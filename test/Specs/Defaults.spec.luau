--!nonstrict
-- The timeout defaults, pinned: a change to any of them is a documented behaviour change.

return function()
	local Root = script.Parent.Parent.Parent
	local Defaults = require(Root.Scribe.Internal.Defaults)

	it("holds the documented values", function()
		expect(
			`client={Defaults.ClientWaitForData} server={Defaults.ServerWaitForData} request={Defaults.Request} `
				.. `owns={Defaults.OwnsAsync} product={Defaults.ProductInfo} budget={Defaults.AwaitBudget}`
		).to.equal("client=30 server=60 request=10 owns=10 product=10 budget=120")
	end)

	it("is frozen, so a bundle cannot quietly change another bundle's defaults", function()
		local ok = pcall(function()
			(Defaults :: any).Request = 1
		end)
		expect(ok).to.equal(false)
	end)
end
