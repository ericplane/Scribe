--!nonstrict
-- The add-on registry the Studio hook reads: register, list, invoke, replace, unregister.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local Addons = require(Root.Scribe.Internal.Addons)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	it("reports the profile key prefix the last Start was given", function()
		local harness = TestCtx.make({ Options = { ProfileKeyPrefix = "user_" } })
		local prefix = Scribe.GetProfileKeyPrefix()
		harness.Cleanup()
		expect(prefix).to.equal("user_")
	end)

	it("lists what is registered, runs an action, and refuses what is not there", function()
		local unregister = Scribe.RegisterAddon("Fixture", {
			Ping = {
				Run = function(args)
					return { Echo = args.Value }
				end,
			},
			Poke = {
				Run = function()
					return 1
				end,
				Writes = true,
			},
		})
		local listed = Addons.List().Fixture
		local ok, result = Addons.Invoke("Fixture", "Ping", { Value = 7 })
		local noAction, why1 = Addons.Invoke("Fixture", "Nope", {})
		local noAddon, why2 = Addons.Invoke("Missing", "Ping", {})
		local writes =
			`{tostring(Addons.Writes("Fixture", "Poke"))}/{tostring(Addons.Writes("Fixture", "Ping"))}/{tostring(
				Addons.Writes("Fixture", "Nope")
			)}`
		unregister()
		local gone = Addons.List().Fixture
		expect(
			`ping={listed.Ping.Writes} poke={listed.Poke.Writes} ok={ok}:{result.Echo} noAction={noAction}:{why1} noAddon={noAddon}:{why2} writes={writes} gone={tostring(
				gone
			)}`
		).to.equal(
			'ping=false poke=true ok=true:7 noAction=false:add-on "Fixture" has no action "Nope" noAddon=false:no add-on named "Missing" is registered writes=true/false/nil gone=nil'
		)
	end)

	it("registering the same table twice is two registrations, and the first remover leaves the second", function()
		local actions = {
			A = {
				Run = function()
					return "same"
				end,
			},
		}
		local first = Scribe.RegisterAddon("Fixture", actions)
		local second = Scribe.RegisterAddon("Fixture", actions)
		first()
		local _, afterFirst = Addons.Invoke("Fixture", "A", {})
		second()
		local listed = Addons.List().Fixture
		expect(`afterFirst={afterFirst} listed={tostring(listed)}`).to.equal("afterFirst=same listed=nil")
	end)

	it("a second registration replaces the first, whose unregister then does nothing", function()
		local first = Scribe.RegisterAddon("Fixture", {
			A = {
				Run = function()
					return "first"
				end,
			},
		})
		local second = Scribe.RegisterAddon("Fixture", {
			A = {
				Run = function()
					return "second"
				end,
			},
		})
		first()
		local _, afterStale = Addons.Invoke("Fixture", "A", {})
		second()
		local listed = Addons.List().Fixture
		expect(`afterStale={afterStale} listed={tostring(listed)}`).to.equal("afterStale=second listed=nil")
	end)
end
