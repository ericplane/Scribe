--!strict
-- EXPECTED_ERRORS: 18
local Scribe = require(script.Parent.Parent.Scribe)
local serverTemplate = require(script.Parent.TypeCheckServerTemplate)

local bundle = Scribe({
	Template = { Coins = 0 },
	ServerStore = serverTemplate,
	ProfileStoreIndex = "ServerStoreErrors",
	ProfileKeyPrefix = "PLAYER_",
})

local inline = Scribe.new({
	Template = { Coins = 0 },
	ServerStore = {
		Wave = Scribe.Int(0),
		Items = Scribe.DictOf({ Count = Scribe.Int(0) }),
		Secret = Scribe.ServerOnly({ Seed = 0 }),
		DoubleWave = Scribe.Derived(Scribe.Int(0), { "Wave" }, function(wave: number): number
			return wave * 2
		end),
	},
	ProfileStoreIndex = "ServerStoreInlineErrors",
	ProfileKeyPrefix = "PLAYER_",
})

local server: Scribe.ServerData<{ Coins: number }, serverTemplate.ServerTemplate> = bundle.Server
local client: Scribe.ClientData<{ Coins: number }, serverTemplate.ServerTemplate> = bundle.Client

return function()
	bundle.Server.ServerStore.Wave.Set("one")
	bundle.Server.ServerStore.Status.Set(1)
	local wave: string = bundle.Server.ServerStore.Wave.Get()
	bundle.Server.ServerStore.Missing.Get()
	bundle.Server.ServerStore.Coins.Get()
	bundle.Server.ServerStore.Set({ Wave = 0 })
	bundle.Server.ServerStore.Get()
	bundle.Server.ServerStore.Observe(function() end)
	bundle.Server.ServerStore.Round.Active.Set(1)
	inline.Server.ServerStore.Wave.Set("one")
	inline.Server.ServerStore.Items.Child(1)
	inline.Server.ServerStore.Items.Child("Apple").Count.Set("one")
	inline.Server.ServerStore.DoubleWave.Set(2)
	inline.Server.ServerStore.Secret.Seed.Set("one")
	inline.Client.ServerStore.Secret.Seed.Get()
	local status: number = bundle.Client.ServerStore.Status.Get()
	server.ServerStore.Unknown.Get()
	client.ServerStore.Round.Active.Set("yes")
	return wave, status
end
