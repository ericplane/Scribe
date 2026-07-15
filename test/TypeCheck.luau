--!strict
-- End-to-end typecheck smoke test for the exported ValueType type function and
-- the typed Scribe() entry point. Analyzed via test.project.json (not shipped).

local Scribe = require(script.Parent.Parent.Scribe)

type ItemData = { Health: number, Dmg: number }

local template = {
	Coins = Scribe.Int(0, { Min = 0 }),
	CreatedAt = Scribe.Dynamic(os.time), -- number; seeded per new profile
	Gems = 0,
	Wins = 0,
	Stats = { Kills = 0, Deaths = 0 },
	Team = Scribe.Enum("Civilian", { "Civilian", "Police", "MP" }),
	Equipped = nil :: string?,
	Inventory = {} :: { [string]: ItemData },
	Settings = { Music = true, Sfx = true },
	QuestProgress = {} :: { number },
	XPBooster = Scribe.Timed(false),
	BuildData = buffer.create(4),
	SpawnPoint = Scribe.Vector3(Vector3.zero),
	HomeDoor = Scribe.CFrame(CFrame.identity),
	Tint = Scribe.Color3(Color3.fromRGB(255, 120, 0)),
	Secret = Scribe.ServerOnly({ Flagged = false }),
	Runtime = Scribe.Session({ InCombat = false }),
}

type T = typeof(template)

-- Annotated strict configs: Stat/Cost.Path check against the template's
-- numeric leaf-path union, and Grant's `data` is the typed accessor tree.
local boards: { [string]: Scribe.LeaderboardConfig<T> } = {
	TopCoins = { Stat = "Coins", Limit = 100, Replicate = true },
	TopKills = { Stat = "Stats.Kills" },
}

local products: { [string]: Scribe.ProductConfig<T> } = {
	Coins1000 = {
		Id = 111,
		Category = "Currency",
		Grant = function(data)
			data.Coins.Increment(1000)
		end,
	},
	GiftVIP = { Id = 222, Category = "Gamepass", Grants = "VIP" },
}

local bundle = Scribe({
	Template = template,
	Transport = "Default",
	ProfileStoreIndex = "MyGameData",
	ProfileKeyPrefix = "PLAYER_",
	Migrations = {
		[2] = function(data)
			data.Gems = data.Gems or 0
		end,
	},
	Leaderboards = boards,
	Products = products,
	Passes = { VIP = { Id = 333 } },
	Economy = {
		Prefix = true,
		Resolve = function(player)
			return { Team = player.Name }
		end,
		Currencies = {
			Coins = {
				Label = "Gold",
				Fields = { "Location", { Name = "Team", Prefix = false } },
				Resolve = function(_p)
					return { Location = "Lobby" }
				end,
			},
			Gems = { Fields = { "Zone" } },
		},
	},
})

local Data = bundle.Server

local function serverUsage(player: Player)
	local data = Data[player]
	local coins: number = data.Coins.Increment(50)
	-- Read-only declared bounds (number?), on both server and client.
	local coinMin: number? = data.Coins.Min()
	local coinMax: number? = data.Coins.Max()
	-- Declared default, typed as the field's value type.
	local coinDefault: number = data.Coins.Default()
	local spawnDefault: Vector3 = data.SpawnPoint.Default()
	local createdAt: number = data.CreatedAt.Get() -- Scribe.Dynamic field types as its factory's return
	-- Economy-tagged mutation: the meta table annotates against Scribe.EconomyMeta.
	local meta: Scribe.EconomyMeta = {
		TransactionType = Enum.AnalyticsEconomyTransactionType.Shop,
		ItemSku = "hat_cowboy",
		Fields = { Location = "Lobby" },
	}
	data.Gems.Decrement(10, meta)
	data.Settings.Music.Set(false)
	local dmg: number = data.Inventory.Sword_001.Dmg.Get()
	data.QuestProgress.Insert(3)
	local has: boolean = data.QuestProgress.Has(3)
	data.XPBooster.SetTimed(true, 3600)
	local active: boolean, remaining: number? = data.XPBooster.Active()
	local blob: buffer = data.BuildData.Get()
	local spawnPoint: Vector3 = data.SpawnPoint.Get()
	data.SpawnPoint.Set(Vector3.new(1, 2, 3))
	local door: CFrame = data.HomeDoor.Get()
	local tint: Color3 = data.Tint.Get()
	data.BuildData.Set(buffer.create(8))
	local equipped: string? = data.Equipped.Get()
	local flagged: boolean = data.Secret.Flagged.Get()
	local inCombat: boolean = data.Runtime.InCombat.Toggle()

	local tree, reason = Data.WaitForData(player)
	if tree then
		tree.Wins.Increment(1)
	end

	Data.Command("EquipItem", { Args = { "string" } }, function(_commandPlayer: Player, _itemId: string)
		return true
	end)

	local owns: boolean = Data.Owns(player, "VIP")
	local ok, err = Data.PromptGift(player, "GiftVIP", 12345)
	local onCooldown, cooldownRemaining = Data.OnCooldown(player, "DailyReward", 86400)

	-- Purchase: Cost.Path is path-checked; Grant gets the typed accessor.
	local bought = Data.Purchase(player, {
		Cost = { Path = "Coins", Amount = 100 },
		Category = "Vehicle",
		ItemId = "Police01",
		Grant = function(grantData)
			grantData.QuestProgress.Insert(1)
		end,
	})

	return coins, dmg, has, active, remaining, equipped, flagged, inCombat, reason, owns, ok, err, onCooldown, cooldownRemaining, blob, spawnPoint, door, tint, bought, coinMin, coinMax, coinDefault, spawnDefault, createdAt
end

local ClientData = bundle.Client

local function clientUsage()
	local ready: boolean = ClientData.IsReady()
	if ClientData.WaitForData(10) then
		local _: number = ClientData.Coins.Get()
	end
	ClientData.Coins.Observe(function(coins)
		local _: number = coins
	end)
	local rank: number? = ClientData.GetMyRank("TopCoins")
	local owns: boolean = ClientData.Owns("VIP")
	local requestOk = ClientData.Request("EquipItem", "Sword_001")
	return rank, owns, requestOk, ready
end

local function diagnosticsUsage()
	-- Valid codes, levels, and categories are accepted and fully typed.
	local recent = Scribe.GetRecentLogs({ Code = "PROFILE_LOAD_FAIL", Level = "Error", Category = "Persistence", Limit = 10 })
	local count: number = #recent
	Scribe.AddLogSink(function(entry)
		if entry.Code == "PROFILE_SIZE" or entry.Level == "Fatal" then
			local _cat: Scribe.LogCategory = entry.Category
		end
	end)
	return count
end

local function typedApis(player: Player)
	-- Command: both call shapes typecheck; the handler's `player` is typed.
	Data.Command("Ping", function(_p: Player)
		return true
	end)
	Data.Command("Buy", { Args = { "string" } }, function(_p: Player, _item)
		return true, "ok"
	end)

	-- GetPurchases: the filter is a typed record (not a { [string]: any } bag).
	local purchases = Data.GetPurchases(player, { Kind = "Robux", Category = "Gems", Limit = 5 })

	-- GetSaveInfo.LastResult narrows to ("Ok" | "Fail")? — this assignment would
	-- fail if it were still `string?`.
	local lastResult: ("Ok" | "Fail")? = Data.GetSaveInfo(player).LastResult

	-- GetMetrics values are number | { Count, Average, Max }.
	local metrics = Scribe.GetMetrics()

	-- Top-level signals carry typed payloads.
	Scribe.OnStatusChanged:Connect(function(newStatus, _old)
		local _s: string = newStatus
	end)
	Scribe.OnIssue:Connect(function(entry)
		local _code: Scribe.LogCode = entry.Code
	end)

	-- Cross-server messaging and the ProfileStore escape hatch.
	local sent: boolean = Data.SendMessage(12345, { Kind = "ping" })
	Data.OnMessage:Connect(function(_p, _msg) end)
	local _store = Data.ProfileStore

	return purchases, lastResult, metrics, sent
end

-- The exported strict config type: annotate a local (outside the Scribe literal)
-- to get Resolve's `player` typed as Player and the field names checked.
local function economyUsage(): Scribe.EconomyConfig
	return {
		Prefix = true,
		Resolve = function(player)
			return { Team = if player.Team then player.Team.Name else "None" }
		end,
		Currencies = {
			Coins = { Label = "Gold", Fields = { "Location", { Name = "Team", Prefix = false } } },
			Gems = {
				Fields = { "Zone" },
				Resolve = function(_p)
					return { Zone = "Arena" }
				end,
			},
		},
	}
end

return {
	serverUsage = serverUsage,
	clientUsage = clientUsage,
	diagnosticsUsage = diagnosticsUsage,
	typedApis = typedApis,
	economyUsage = economyUsage,
}
