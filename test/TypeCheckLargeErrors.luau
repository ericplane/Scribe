--!strict
-- EXPECTED_ERRORS: 6
-- Scribe() must type-check this template within Luau's subtyping budget.
-- Each numbered accessor use must still report one error.
local Scribe = require(script.Parent.Parent.Scribe)

local MODES = { "", "Solo", "Duo", "Squad", "Ranked" }
local RESULTS = { "", "Win", "Loss", "Draw", "Abandoned" }

local function Id()
	return Scribe.String("", { MaxLength = 64 })
end

local function Count()
	return Scribe.Int(0, { Min = 0 })
end

local function Stamp()
	return Scribe.Number(0, { Min = 0 })
end

local function Sum(...: number): number
	local total = 0
	for _, value in { ... } do
		total += value
	end
	return total
end

local template = {
	Profile = {
		FirstJoinedAt = Stamp(),
		Playtime = Count(),
		Locale = Id(),
		Title = Id(),
		Badges = Scribe.SetOf(Id(), { MaxItems = 64 }),
		Names = Scribe.ArrayOf({ Name = Id(), ChangedAt = Stamp() }, { MaxItems = 8 }),
		Referral = { Code = Id(), Uses = Count(), RewardedAt = Stamp() },
	},
	Wallet = {
		Coins = Count(),
		Gems = Count(),
		Tickets = Count(),
		Vault = Scribe.Big(0, { Min = 0 }),
		Ledger = Scribe.ArrayOf(
			{ Currency = Id(), Delta = Scribe.Int(0), At = Stamp(), Reason = Id() },
			{ MaxItems = 32 }
		),
		Interest = { Rate = Scribe.Number(0, { Min = 0, Max = 1 }), PaidAt = Stamp(), Pending = Count() },
	},
	Progress = {
		Level = Scribe.Int(1, { Min = 1 }),
		XP = Count(),
		Prestige = Count(),
		Tracks = { Combat = Count(), Trade = Count(), Craft = Count(), Explore = Count(), Social = Count() },
		Milestones = Scribe.SetOf(Id(), { MaxItems = 128 }),
		Boost = Scribe.Timed(false),
		BoostHistory = Scribe.ArrayOf({ Kind = Id(), EndsAt = Stamp(), Stacks = Count() }, { MaxItems = 16 }),
		Talents = Scribe.DictOf({ Rank = Count(), UnlockedAt = Stamp(), Refunded = false }, { MaxKeys = 64 }),
	},
	Inventory = {
		Slots = Count(),
		Items = Scribe.DictOf(
			{ Kind = Id(), Amount = Count(), Durability = Scribe.Number(1, { Min = 0, Max = 1 }), Bound = false },
			{ MaxKeys = 256 }
		),
		Hotbar = Scribe.MapOf("integer", Id(), { MaxKeys = 10 }),
		Loadouts = Scribe.ArrayOf({
			Name = Id(),
			Primary = Id(),
			Secondary = Id(),
			Armor = Id(),
			Trinkets = Scribe.ArrayOf(Id(), { MaxItems = 4 }),
		}, { MaxItems = 8 }),
		Favorites = Scribe.SetOf(Id(), { MaxItems = 64 }),
		Trash = Scribe.ArrayOf({ ItemKey = Id(), RemovedAt = Stamp() }, { MaxItems = 16 }),
		Dyes = Scribe.MapOf("string", Count(), { MaxKeys = 32 }),
	},
	Equipment = {
		Head = { HeadItem = Id(), HeadDye = Id(), HeadLevel = Count() },
		Chest = { ChestItem = Id(), ChestDye = Id(), ChestLevel = Count(), Emblem = Id() },
		Legs = { LegsItem = Id(), LegsDye = Id(), LegsLevel = Count() },
		Hands = { HandsItem = Id(), Enchant = Id(), Charges = Count() },
		Back = { BackItem = Id(), Trail = Id(), Visible = true },
		Sets = Scribe.ArrayOf({ SetName = Id(), Pieces = Scribe.ArrayOf(Id(), { MaxItems = 6 }), Bonus = Count() }),
	},
	Housing = {
		Plots = Scribe.DictOf({ Biome = Id(), Size = Count(), ClaimedAt = Stamp() }, { MaxKeys = 4 }),
		Furniture = Scribe.ArrayOf({
			Model = Id(),
			X = Scribe.Number(0),
			Y = Scribe.Number(0),
			Z = Scribe.Number(0),
			Rotation = Scribe.Number(0, { Min = 0, Max = 360 }),
			Room = Id(),
		}, { MaxItems = 200 }),
		Rooms = Scribe.DictOf({ Theme = Id(), Lighting = Scribe.Number(1, { Min = 0, Max = 1 }), Locked = false }),
		Visitors = Scribe.MapOf("integer", Stamp(), { MaxKeys = 32 }),
		Permissions = Scribe.DictOf({ CanBuild = false, CanOpen = false, GrantedAt = Stamp() }, { MaxKeys = 32 }),
		Garden = Scribe.ArrayOf({ Plant = Id(), PlantedAt = Stamp(), Watered = false, Bed = Count() }),
	},
	Pets = {
		Owned = Scribe.DictOf({
			Species = Id(),
			Nickname = Id(),
			PetLevel = Count(),
			Hunger = Scribe.Number(1, { Min = 0, Max = 1 }),
			Happiness = Scribe.Number(1, { Min = 0, Max = 1 }),
			BornAt = Stamp(),
		}, { MaxKeys = 64 }),
		Active = Scribe.ArrayOf(Id(), { MaxItems = 3 }),
		Eggs = Scribe.ArrayOf({ EggKind = Id(), HatchesAt = Stamp(), Incubator = Count() }, { MaxItems = 8 }),
		Breeding = { Mother = Id(), Father = Id(), ReadyAt = Stamp(), Attempts = Count() },
		Treats = Scribe.MapOf("string", Count(), { MaxKeys = 16 }),
	},
	Quests = {
		Daily = {
			Day = Count(),
			Assigned = Scribe.DictOf({ QuestId = Id(), Target = Id(), Done = Count() }, { MaxKeys = 8 }),
			Claimed = Scribe.SetOf(Id(), { MaxItems = 8 }),
			Rerolls = Count(),
		},
		Weekly = {
			Week = Count(),
			Finished = Count(),
			ClaimedOn = Count(),
			Earned = Scribe.SetOf(Count(), { MaxItems = 8 }),
		},
		Story = {
			Chapter = Count(),
			Step = Count(),
			Choices = Scribe.MapOf("string", Id(), { MaxKeys = 64 }),
			Completed = Scribe.SetOf(Id(), { MaxItems = 128 }),
		},
		Bounties = Scribe.ArrayOf({ BountyId = Id(), Quarry = Id(), Reward = Count(), ExpiresAt = Stamp() }),
		Streak = { StreakDay = Count(), StreakClaimedOn = Count(), Best = Count() },
	},
	Social = {
		Friends = Scribe.MapOf("integer", Stamp(), { MaxKeys = 200 }),
		Blocked = Scribe.SetOf(Count(), { MaxItems = 200 }),
		Guild = { GuildId = Id(), Rank = Id(), JoinedAt = Stamp(), Contribution = Count() },
		Invites = Scribe.ArrayOf({ From = Count(), InviteGuild = Id(), SentAt = Stamp() }, { MaxItems = 16 }),
		Mail = Scribe.ArrayOf({
			Sender = Count(),
			Subject = Id(),
			Body = Scribe.String("", { MaxLength = 500 }),
			MailedAt = Stamp(),
			Read = false,
			Attachment = Id(),
		}, { MaxItems = 32 }),
		Emotes = Scribe.SetOf(Id(), { MaxItems = 64 }),
	},
	Combat = {
		Stats = {
			Kills = Count(),
			Deaths = Count(),
			Assists = Count(),
			DamageDealt = Count(),
			DamageTaken = Count(),
			Healing = Count(),
		},
		Ranked = { Rating = Count(), Peak = Count(), Season = Count(), Placement = Count(), WinStreak = Count() },
		Matches = Scribe.ArrayOf({
			MatchId = Id(),
			Mode = Scribe.Enum("", MODES),
			Result = Scribe.Enum("", RESULTS),
			Duration = Count(),
			EndedAt = Stamp(),
		}, { MaxItems = 20 }),
		Weapons = Scribe.DictOf({ WeaponKills = Count(), Headshots = Count(), Skin = Id(), Mastery = Count() }),
		Titles = Scribe.SetOf(Id(), { MaxItems = 64 }),
	},
	Crafting = {
		Recipes = Scribe.SetOf(Id(), { MaxItems = 256 }),
		Queue = Scribe.ArrayOf(
			{ Recipe = Id(), StartedAt = Stamp(), ReadyAt = Stamp(), Station = Id() },
			{ MaxItems = 8 }
		),
		Stations = Scribe.DictOf({ Tier = Count(), Fuel = Count(), Output = Id() }, { MaxKeys = 16 }),
		Blueprints = Scribe.MapOf("string", Count(), { MaxKeys = 64 }),
		Research = { Topic = Id(), Points = Count(), FinishedAt = Stamp() },
	},
	Farming = {
		Fields = Scribe.DictOf({ Crop = Id(), SownAt = Stamp(), Irrigated = false, Stage = Count() }, { MaxKeys = 32 }),
		Animals = Scribe.ArrayOf({ Breed = Id(), Fed = false, Age = Count() }, { MaxItems = 32 }),
		Silo = Scribe.MapOf("string", Count(), { MaxKeys = 32 }),
		Weather = { Forecast = Id(), RainUntil = Stamp() },
	},
	Trading = {
		Listings = Scribe.ArrayOf({ ListedItem = Id(), Price = Count(), ListedAt = Stamp(), Expires = Stamp() }),
		Offers = Scribe.ArrayOf({ Bidder = Count(), WantedItem = Id(), Bid = Count(), OfferedAt = Stamp() }),
		History = Scribe.ArrayOf({ Partner = Count(), Gave = Id(), Got = Id(), TradedAt = Stamp() }, { MaxItems = 32 }),
		Reputation = { Score = Count(), Trades = Count(), Disputes = Count() },
	},
	Vehicles = {
		Owned = Scribe.DictOf({ Chassis = Id(), Paint = Id(), Tank = Count(), Mileage = Count(), Plate = Id() }),
		Garage = { Bays = Count(), Selected = Id() },
		Upgrades = Scribe.DictOf({ Engine = Count(), Tires = Count(), Plating = Count() }, { MaxKeys = 32 }),
		Races = Scribe.ArrayOf({ Track = Id(), LapTime = Stamp(), Position = Count(), RacedAt = Stamp() }),
	},
	Seasons = {
		Pass = {
			PassTier = Count(),
			PassXP = Count(),
			Premium = false,
			ClaimedFree = Scribe.SetOf(Count(), { MaxItems = 100 }),
			ClaimedPaid = Scribe.SetOf(Count(), { MaxItems = 100 }),
		},
		Events = Scribe.DictOf({ Points = Count(), Standing = Count(), EnteredAt = Stamp() }, { MaxKeys = 16 }),
		Rewards = Scribe.ArrayOf({ RewardId = Id(), GrantedAt = Stamp(), Source = Id() }, { MaxItems = 64 }),
	},
	Settings = {
		Values = Scribe.MapOf("string", Scribe.Number(0, { Min = 0, Max = 100 }), { MaxKeys = 64 }),
		Keybinds = Scribe.MapOf("string", Id(), { MaxKeys = 64 }),
		Toggles = Scribe.Flags({ "Music", "Hints", "Chat", "Trades" }),
		Audio = { Music = Count(), Effects = Count(), Voice = Count() },
		Video = { Quality = Count(), Shadows = false, FieldOfView = Count() },
		Controls = { Sensitivity = Scribe.Number(1, { Min = 0 }), Invert = false, Vibration = false },
	},
	Store = {
		StarterPacks = Scribe.MapOf("string", Stamp(), { MaxKeys = 16 }),
		Gifted = Scribe.MapOf("string", Count(), { MaxKeys = 32 }),
		Codes = Scribe.SetOf(Scribe.String("", { MaxLength = 32 }), { MaxItems = 256 }),
		Orders = Scribe.ArrayOf(
			{ Product = Count(), Lane = Id(), OrderedAt = Stamp(), Paid = false },
			{ MaxItems = 16 }
		),
		Subscriptions = Scribe.DictOf({ Plan = Id(), RenewsAt = Stamp(), Lapsed = false }, { MaxKeys = 8 }),
	},
	Moderation = Scribe.ServerOnly({
		Warnings = Scribe.ArrayOf({ WarningId = Id(), Text = Scribe.String(""), IssuedAt = Stamp(), Seen = false }),
		Strikes = Count(),
		MutedUntil = Stamp(),
		Notes = Scribe.ArrayOf({ Author = Count(), Note = Scribe.String(""), NotedAt = Stamp() }, { MaxItems = 16 }),
	}),
	Tutorial = {
		Movement = Scribe.Optional(Scribe.Int(0)),
		Building = Scribe.Optional(Scribe.Int(0)),
		Protection = Scribe.Timed(0),
		Funnel = Count(),
		Played = false,
	},
	Session = Scribe.Session({
		JoinedAt = Stamp(),
		Team = Scribe.Enum("", MODES),
		Match = { Arena = Id(), Round = Count(), Score = Count(), Alive = true, SpawnedAt = Stamp() },
		Party = Scribe.ArrayOf({ Member = Count(), Ready = false, Role = Id() }, { MaxItems = 8 }),
		Backpack = Scribe.MapOf("integer", Id(), { MaxKeys = 32 }),
		Carried = Scribe.ArrayOf(Id(), { MaxItems = 8 }),
		Job = { JobId = Id(), Vehicle = Id(), AcceptedAt = Stamp(), Deadline = Stamp(), Stage = Count() },
		Duty = { Since = Stamp(), Status = Id(), Private = false },
		Arrest = { Charge = Id(), Sentence = Count(), Until = Stamp(), Bailed = false },
		Trespass = { Zone = Id(), TrespassUntil = Stamp(), Level = Count() },
		Celebrations = Scribe.ArrayOf({ Serial = Count(), Banner = Id(), Amount = Count() }, { MaxItems = 16 }),
		Cooldowns = Scribe.MapOf("string", Stamp(), { MaxKeys = 32 }),
	}),
	TrackTotal = Scribe.Derived(
		Scribe.Int(0),
		{ "Progress.Tracks.Combat", "Progress.Tracks.Trade", "Progress.Tracks.Craft" },
		Sum
	),
	Spendable = Scribe.Derived(Scribe.Int(0), { "Wallet.Coins", "Wallet.Gems" }, Sum),
}

local bundle = Scribe({
	Template = template,
	ServerStore = { Wave = Scribe.Int(0), Queue = Scribe.ArrayOf({ UserId = Scribe.Int(0), Since = Scribe.Number(0) }) },
	ProfileStoreIndex = "TypeCheckLargeErrors",
	ProfileKeyPrefix = "PLAYER_",
	OnPlayerLeaving = function(_player, data)
		local joinedAt = data.Session.JoinedAt.Get()
		if joinedAt > 0 then
			data.Profile.Playtime.Increment(math.max(0, os.time() - joinedAt))
		end
	end,
})

return function(player: Player)
	local data = bundle.Server[player]
	local client = bundle.Client

	local coins: number = data.Wallet.Coins.Get()
	local rotation: number = data.Housing.Furniture[1].Rotation.Get()
	local rating: number = client.Combat.Ranked.Rating.Get()
	data.Session.Match.Round.Increment(1)
	data.Progress.Boost.SetTimed(true, 30)
	data.Moderation.Strikes.Increment(1)
	bundle.Server.ServerStore.Queue.Insert({ UserId = player.UserId, Since = os.clock() })

	local _leaf: string = data.Wallet.Coins.Get() -- 1: numeric server field
	local _element: string = data.Housing.Furniture[1].Rotation.Get() -- 2: numeric array element field
	data.Session.Match.Round.Set("one") -- 3: numeric session field
	local _clientLeaf: string = client.Combat.Ranked.Rating.Get() -- 4: numeric client field
	local _hidden = client.Moderation -- 5: server-only root
	client.Progress.Boost.SetTimed(true, 30) -- 6: client cannot set a deadline

	return coins, rotation, rating
end
