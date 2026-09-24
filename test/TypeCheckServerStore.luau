--!strict
-- ServerStore retains its own template across both constructor forms.
local Scribe = require(script.Parent.Parent.Scribe)
local serverTemplate = require(script.Parent.TypeCheckServerTemplate)

local playerTemplate = { Coins = 0 }
type T = typeof(playerTemplate)
type S = serverTemplate.ServerTemplate

local bundle = Scribe({
	Template = playerTemplate,
	ServerStore = serverTemplate,
	ProfileStoreIndex = "ServerStoreTypes",
	ProfileKeyPrefix = "PLAYER_",
})

local options: Scribe.ScribeOptions<T, S> = {
	Template = playerTemplate,
	ServerStore = serverTemplate,
	ProfileStoreIndex = "ServerStoreAliases",
	ProfileKeyPrefix = "PLAYER_",
}
local annotated: Scribe.Bundle<T, S> = Scribe.new(options)
local server: Scribe.ServerData<T, S> = annotated.Server
local client: Scribe.ClientData<T, S> = annotated.Client
local legacyServer: Scribe.ServerDataType<T, Player> = bundle.Server
local legacyClient: Scribe.ClientDataType<T> = bundle.Client

local inline = Scribe.new({
	Template = playerTemplate,
	ServerStore = {
		Wave = Scribe.Int(0),
		Items = Scribe.DictOf({ Count = Scribe.Int(0) }),
		Names = Scribe.ArrayOf(Scribe.String("")),
		Secret = Scribe.ServerOnly({ Seed = 0 }),
		DoubleWave = Scribe.Derived(Scribe.Int(0), { "Wave" }, function(wave: number): number
			return wave * 2
		end),
	},
	ProfileStoreIndex = "ServerStoreInline",
	ProfileKeyPrefix = "PLAYER_",
})

local callable = Scribe({
	Template = playerTemplate,
	ServerStore = { Enabled = false, Get = 0, Changed = "" },
	ProfileStoreIndex = "ServerStoreCallable",
	ProfileKeyPrefix = "PLAYER_",
})

return function(player: Player)
	local coins: number = bundle.Server[player].Coins.Get()
	local wave: number = bundle.Server.ServerStore.Wave.Increment(1)
	local status: string = bundle.Client.ServerStore.Status.Get()
	local active: boolean = bundle.Server.ServerStore.Round.Active.Toggle()
	server.ServerStore.Status.Set("Playing")
	local clientWave: number = client.ServerStore.Wave.Get()
	local disconnect: () -> () = client.ServerStore.Status.Observe(function(value: string)
		print(value)
	end)
	local itemCount: number = inline.Server.ServerStore.Items.Child("Apple").Count.Increment(1)
	inline.Server.ServerStore.Names.Insert("Alice")
	local name: string = inline.Client.ServerStore.Names.Child(1).Get()
	local seed: number = inline.Server.ServerStore.Secret.Seed.Get()
	local doubled: number = inline.Client.ServerStore.DoubleWave.Get()
	local enabled: boolean = callable.Server.ServerStore.Enabled.Toggle()
	local namedGet: number = callable.Server.ServerStore.Get.Increment(1)
	local namedChanged: string = callable.Client.ServerStore.Changed.Get()
	local oldServerCoins: number = legacyServer[player].Coins.Get()
	local oldClientCoins: number = legacyClient.Coins.Get()
	return coins,
		wave,
		status,
		active,
		clientWave,
		disconnect,
		itemCount,
		name,
		seed,
		doubled,
		enabled,
		namedGet,
		namedChanged,
		oldServerCoins,
		oldClientCoins
end
