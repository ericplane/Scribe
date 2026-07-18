--!strict
-- Server assembly: builds the shared context, wires the layers together, and
-- exposes the public server `Data` API.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Internal = script.Parent.Internal
local Template = require(Internal.Template)
local TransportModule = require(Internal.Transport)
local Version = require(Internal.Version)
local Node = require(Internal.Node)
local Log = require(Internal.Log)
local Metrics = require(Internal.Metrics)
local Health = require(Internal.Health)
local Signal = require(Internal.Signal)

local Persistence = require(script.Persistence)
local Replication = require(script.Replication)
local Commands = require(script.Commands)
local Timed = require(script.Timed)
local Analytics = require(script.Analytics)
local Leaderboards = require(script.Leaderboards)
local Monetization = require(script.Monetization)

local Server = {}

-- Builds the server context and public Data API without touching engine-level
-- wiring (PlayerAdded/Removing, BindToClose). `Server.new` is the production
-- entry point; `build` also lets the test harness construct isolated
-- instances with stub transports and a fake ProfileStore, driving the player
-- lifecycle manually. Returns (Data, ctx).
function Server.build(options: any, compiled: Template.Compiled): (any, any)
	local ctx = {} :: any
	ctx.Options = options
	ctx.Compiled = compiled
	ctx.DevMode = RunService:IsStudio()
	ctx.Signals = {
		OnSave = Signal.new(), -- { Player, Ok, Duration, At }
		SessionEnded = Signal.new(), -- (player, reason)
		OnAnomaly = Signal.new(), -- { Player, Path, Value, Reason }
		OnGiftReceived = Signal.new(), -- (player, { FromUserId, Product, GiftId })
		OnGiftCredit = Signal.new(), -- (player, productName)
		OnMessage = Signal.new(), -- (player, message)
	}

	if options.LogLevel then
		Log.SetLevel(options.LogLevel)
	end
	Health.Configure(options.StatusThresholds)

	ctx.Transport = TransportModule.Resolve(options.Transport, options.TransportChannel)

	-- Build order matters only for construction-time dependencies; runtime
	-- calls flow through ctx.
	ctx.Analytics = Analytics.new(ctx)
	ctx.Timed = Timed.new(ctx)
	ctx.Persistence = Persistence.new(ctx)
	ctx.Replication = Replication.new(ctx)
	ctx.Commands = Commands.new(ctx)
	ctx.Leaderboards = Leaderboards.new(ctx)
	ctx.Monetization = Monetization.new(ctx)

	-- Background loops start only after every subsystem exists — a constructor
	-- throwing partway (bad config) must never leave an orphaned loop running
	-- against a half-built ctx.
	ctx.Monetization.Start()
	ctx.Timed.Start()
	ctx.Leaderboards.Start()

	-- Public API --------------------------------------------------------------------

	--[=[
		@class Server

		The server-side data API: `bundle.Server`. Index it with a `Player` to
		get that player's typed accessor tree (`Data[player].Coins.Increment(50)`),
		and call its methods to drive persistence, monetization, leaderboards, and
		administration.

		`Data[player]` and `Data.Get` **error while a profile is still loading**.
		Use [Server.WaitForData] first (or read inside a command handler, which
		only runs once the player is Ready).

		:::note Indexing
		`Data[player]` returns the same accessor tree as `Data.Get(player)`. The
		methods on individual fields (`.Get`, `.Set`, `.Increment`, …) are
		documented on the [Value] class.
		:::
	]=]
	local Data = {} :: any

	local function entryOrError(player: Player, what: string): any
		local entry = ctx.Persistence.EntryFor(player)
		if not entry then
			error(`Scribe: {what}: no data session for {player.Name}`, 3)
		end
		if entry.State ~= "Ready" then
			error(`Scribe: {what}: data for {player.Name} is {entry.State} — use Data.WaitForData(player)`, 3)
		end
		return entry
	end

	--[=[
		@within Server
		@tag Lifecycle
		@server
		@yields
		@param player Player
		@return (Value?, string?)
		Yields until the player's profile is Ready, then returns their accessor
		tree. On failure returns `(nil, reason)` where reason is `"load-failed"`,
		`"timeout"`, or `"session-end"`. Always handle the `nil` branch. This is
		the safe way to get data in `Players.PlayerAdded`.
	]=]
	function Data.WaitForData(player: Player)
		return ctx.Persistence.WaitForData(player)
	end
	--[=[
		@within Server
		@tag Lifecycle
		@server
		@param player Player
		@return "Loading" | "Ready" | "SessionEnded"
		The player's session state, without yielding.
	]=]
	function Data.GetState(player: Player)
		return ctx.Persistence.GetState(player)
	end
	--[=[
		@within Server
		@tag Lifecycle
		@server
		@param player Player
		@return Value
		The player's accessor tree. Errors if the profile is not Ready. Prefer
		[Server.WaitForData] on join. `Data[player]` is shorthand for this.
	]=]
	function Data.Get(player: Player)
		return entryOrError(player, "Data.Get").Tree.Accessor
	end

	--[=[
		@within Server
		@tag Lifecycle
		@server
		@param player Player
		@param fn () -> ()
		Runs `fn` as a batch: all writes inside coalesce into a single replication
		flush and one Changed pass. Use for bulk updates.
	]=]
	function Data.Batch(player: Player, fn: () -> ())
		local entry = entryOrError(player, "Data.Batch")
		entry.Tree:RunBatch(fn)
	end
	--[=[
		@within Server
		@tag Lifecycle
		@server
		@param player Player
		@param fn () -> ()
		@return (boolean, string?)
		Runs `fn` atomically: if it throws, **every** write inside is rolled back
		and `(false, error)` is returned. On success returns `(true, nil)`.
	]=]
	function Data.Transaction(player: Player, fn: () -> ()): (boolean, string?)
		local entry = entryOrError(player, "Data.Transaction")
		return entry.Tree:RunTransaction(fn)
	end

	--[=[
		@within Server
		@tag Persistence
		@server
		@yields
		@param player Player
		@param opts { Force: boolean? }?
		@return boolean
		Forces a save now instead of waiting for the next autosave. Call it right
		after a grant or purchase. `Force = true` also pushes through a blocked
		wipe-guard save.
	]=]
	function Data.Flush(player: Player, opts: { Force: boolean? }?)
		return ctx.Persistence.Flush(player, opts)
	end
	--[=[
		@within Server
		@tag Persistence
		@server
		@param player Player
		@return SaveInfo
		The player's save state (`{ LastSaveAt, LastResult, Dirty }`) for
		"Saving… / Saved ✓ / Unsaved changes" UI. Also mirrored to the owner.
	]=]
	function Data.GetSaveInfo(player: Player)
		return ctx.Persistence.GetSaveInfo(player)
	end
	--[=[
		@within Server
		@tag Persistence
		@server
		@yields
		@param userId number
		@return { [string]: any }?
		Reads a profile that is not on this server (offline, or another server),
		or `nil` if it doesn't exist. Read-only. Use [Server.UpdateOffline] to
		write.
	]=]
	function Data.GetOffline(userId: number)
		return ctx.Persistence.GetOffline(userId)
	end
	--[=[
		@within Server
		@tag Persistence
		@server
		@yields
		@param userId number
		@param fn (data: { [string]: any }) -> ()
		@return (boolean, string?)
		Mutates an offline profile's raw data. **Fails closed** if the user has an
		active session anywhere, so it can never clobber a live game.
	]=]
	function Data.UpdateOffline(userId: number, fn: (data: any) -> ())
		return ctx.Persistence.UpdateOffline(userId, fn)
	end
	--[=[
		@within Server
		@tag Persistence
		@server
		@yields
		@param userId number
		@param limit number?
		@return { { VersionId: string, CreatedAt: number, Size: number? } }
		Lists a profile's DataStore version history, for support/rollback tools.
	]=]
	function Data.ListVersions(userId: number, limit: number?)
		return ctx.Persistence.ListVersions(userId, limit)
	end
	--[=[
		@within Server
		@tag Persistence
		@server
		@yields
		@param userId number
		@param versionId string
		@return { [string]: any }?
		Reads the raw data of a specific historical version.
	]=]
	function Data.GetVersion(userId: number, versionId: string)
		return ctx.Persistence.GetVersion(userId, versionId)
	end
	--[=[
		@within Server
		@tag Persistence
		@server
		@yields
		@param userId number
		@param versionId string
		@return (boolean, string?)
		Restores a profile to a historical version. Fails closed if the user is
		active on another server.
	]=]
	function Data.RestoreVersion(userId: number, versionId: string)
		return ctx.Persistence.RestoreVersion(userId, versionId)
	end
	--[=[
		@within Server
		@tag Persistence
		@server
		@yields
		@param userId number
		@return (boolean, string?)
		GDPR right-to-erasure: removes the profile and the user's leaderboard
		entries. Returns `(false, reason)` if any part failed so you can retry.
	]=]
	function Data.Erase(userId: number)
		return ctx.Persistence.Erase(userId)
	end
	--[=[
		@within Server
		@tag Persistence
		@server
		@yields
		@param userId number
		@return string?
		GDPR data export: the profile as a JSON string (buffers base64-encoded),
		or `nil` if it doesn't exist.
	]=]
	function Data.Export(userId: number)
		return ctx.Persistence.Export(userId)
	end

	--[=[
		@within Server
		@tag Commands
		@server
		@param name string
		@param specOrHandler ({ Args: { string }? } | (player: Player, ...any) -> ...any)
		@param handler ((player: Player, ...any) -> ...any)?
		Registers a named command clients can call via [Client.Request]. Sender
		identity is always the real player; args are shape-validated, rate-limited,
		and only run once the caller is Ready.

		```lua
		Data.Command("EquipItem", { Args = { "string" } }, function(player, itemId)
		    if not Data[player].Inventory[itemId].Get() then return false, "not owned" end
		    Data[player].Equipped.Set(itemId)
		    return true
		end)
		```
	]=]
	function Data.Command(name: string, specOrHandler: any, handler: any?)
		ctx.Commands.Register(name, specOrHandler, handler)
	end

	--[=[
		@within Server
		@tag Leaderboards
		@server
		@param name string
		@param limit number?
		@return { LeaderboardEntry }
		The cached top-N of an all-time board (`{ Rank, UserId, Name, Score }`).
		Never triggers a live OrderedDataStore read.
	]=]
	function Data.GetLeaderboard(name: string, limit: number?)
		return ctx.Leaderboards.GetLeaderboard(name, limit)
	end
	--[=[
		@within Server
		@tag Leaderboards
		@server
		@param player Player
		@param name string
		@return number?
		The player's current rank on a board, or `nil` if unranked.
	]=]
	function Data.GetMyRank(player: Player, name: string)
		return ctx.Leaderboards.GetMyRank(player, name)
	end

	--[=[
		@within Server
		@tag Monetization
		@server
		@param buyer Player
		@param productName string
		@param recipientUserId number
		@return (boolean, string?)
		Prompts `buyer` to gift a product's perk to `recipientUserId`. Records a
		durable intent *before* money moves; delivery survives cross-server hops
		and offline recipients, and a held gift credit is consumed with no charge.
		Returns `(false, reason)` if the gift can't proceed.
	]=]
	function Data.PromptGift(buyer: Player, productName: string, recipientUserId: number)
		return ctx.Monetization.PromptGift(buyer, productName, recipientUserId)
	end
	--[=[
		@within Server
		@tag Monetization
		@server
		@param player Player
		@return { [string]: number }
		The player's unassigned gift credits by product name.
	]=]
	function Data.GetGiftCredits(player: Player)
		return ctx.Monetization.GetGiftCredits(player)
	end
	--[=[
		@within Server
		@tag Monetization
		@server
		@param receiptInfo table
		@return Enum.ProductPurchaseDecision
		Processes a developer-product receipt. Scribe binds `ProcessReceipt`
		automatically unless `OwnReceipts = false`, in which case call this from
		your own handler. Idempotent by `PurchaseId` and fail-closed. Robux are
		never eaten.
	]=]
	function Data.HandleReceipt(receiptInfo: any)
		return ctx.Monetization.HandleReceipt(receiptInfo)
	end
	--[=[
		@within Server
		@tag Monetization
		@server
		@param player Player
		@param key string
		@return boolean
		The unified ownership check: a granted perk **or** an owned game pass
		(cached) **or** RobloxPlus. Hide "buy" buttons whenever this is true.
	]=]
	function Data.Owns(player: Player, key: string)
		return ctx.Monetization.Owns(player, key)
	end
	--[=[
		@within Server
		@tag Monetization
		@server
		@param player Player
		@param key string
		Grants a perk directly (admin/reward flows).
	]=]
	function Data.GrantPerk(player: Player, key: string)
		return ctx.Monetization.GrantPerk(player, key)
	end
	--[=[
		@within Server
		@tag Monetization
		@server
		@param player Player
		@param key string
		Revokes a granted perk.
	]=]
	function Data.RevokePerk(player: Player, key: string)
		return ctx.Monetization.RevokePerk(player, key)
	end
	--[=[
		@within Server
		@tag Monetization
		@server
		@param player Player
		@param spec PurchaseSpec
		@return (boolean, string?)
		Atomic soft-currency purchase: debits `Cost`, runs `Grant`, and logs it.
		All or nothing. Insufficient funds or a throwing `Grant` rolls everything
		back with no debit.

		```lua
		Data.Purchase(player, {
		    Cost = { Path = "Coins", Amount = 45000 },
		    Category = "Vehicle", ItemId = "Police01",
		    Grant = function(data) data.Vehicles.Insert("Police01") end,
		})
		```
	]=]
	function Data.Purchase(player: Player, spec: any)
		return ctx.Monetization.Purchase(player, spec)
	end
	--[=[
		@within Server
		@tag Monetization
		@server
		@param player Player
		@param entry table
		Appends an entry to the player's in-game purchase log (your own records).
	]=]
	function Data.RecordPurchase(player: Player, entry: any)
		return ctx.Monetization.RecordPurchase(player, entry)
	end
	--[=[
		@within Server
		@tag Monetization
		@server
		@param player Player
		@param filter { Kind: ("Robux" | "InGame")?, Category: string?, ItemId: string?, Since: number?, Limit: number? }?
		@return { table }
		The player's purchase history (Robux receipts and in-game purchases),
		newest first, optionally filtered.
	]=]
	function Data.GetPurchases(player: Player, filter: any?)
		return ctx.Monetization.GetPurchases(player, filter)
	end

	--[=[
		@within Server
		@tag Cooldowns
		@server
		@param player Player
		@param key string
		@param seconds number
		@return (onCooldown: boolean, remaining: number)
		Checks **and arms** a keyed cooldown: returns `false` and starts a new
		`seconds` cooldown if it was off. Call it only at the grant/claim moment.
		Use [Server.PeekCooldown] for display checks.
	]=]
	function Data.OnCooldown(player: Player, key: string, seconds: number): (boolean, number)
		local entry = entryOrError(player, "Data.OnCooldown")
		return ctx.Timed.OnCooldown(entry, key, seconds)
	end

	--[=[
		@within Server
		@tag Cooldowns
		@server
		@param player Player
		@param key string
		@return (onCooldown: boolean, remaining: number)
		Read-only cooldown check. Never arms it. Safe for UI.
	]=]
	function Data.PeekCooldown(player: Player, key: string): (boolean, number)
		local entry = entryOrError(player, "Data.PeekCooldown")
		return ctx.Timed.PeekCooldown(entry, key)
	end

	--[=[
		@within Server
		@tag Cooldowns
		@server
		@param player Player
		@param key string
		Clears a cooldown (support/testing resets).
	]=]
	function Data.ClearCooldown(player: Player, key: string)
		local entry = entryOrError(player, "Data.ClearCooldown")
		ctx.Timed.ClearCooldown(entry, key)
	end

	--[=[
		@within Server
		@tag Signals
		@server
		@prop OnSave Signal
		Fires after every save attempt with `{ Player, Ok, Duration, At }`.
	]=]
	Data.OnSave = ctx.Signals.OnSave
	--[=[
		@within Server
		@tag Signals
		@server
		@prop SessionEnded Signal
		Fires when a session ends with `(player, reason)`. With
		`KickOnSessionEnd = true` (the default) the player is also kicked.
	]=]
	Data.SessionEnded = ctx.Signals.SessionEnded
	--[=[
		@within Server
		@tag Signals
		@server
		@prop OnAnomaly Signal
		Fires for integrity anomalies (out-of-bounds writes, a tripped wipe guard,
		an unserializable snapshot) with `{ Player, Path, Value, Reason }`.
	]=]
	Data.OnAnomaly = ctx.Signals.OnAnomaly
	--[=[
		@within Server
		@tag Signals
		@server
		@prop OnGiftReceived Signal
		Fires when a player receives a gift with `(player, { FromUserId, Product, GiftId })`.
	]=]
	Data.OnGiftReceived = ctx.Signals.OnGiftReceived
	--[=[
		@within Server
		@tag Signals
		@server
		@prop OnGiftCredit Signal
		Fires when a player is issued a gift credit with `(player, productName)`.
	]=]
	Data.OnGiftCredit = ctx.Signals.OnGiftCredit
	--[=[
		@within Server
		@tag Messaging
		@server
		@prop OnMessage Signal
		Fires with `(player, message)` when a cross-server message sent through
		[Server.SendMessage] arrives for an active session.
	]=]
	Data.OnMessage = ctx.Signals.OnMessage

	--[=[
		@within Server
		@tag Messaging
		@server
		@yields
		@param userId number
		@param message any
		@return boolean
		Sends a durable cross-server message to `userId`, delivered to
		[Server.OnMessage] on whatever server they are (or next become) active on,
		including offline recipients (queued until their next load). `message` must
		be DataStore-serializable. Returns whether it was committed. Rides
		ProfileStore's global-update channel, so keep messages small and infrequent.
	]=]
	function Data.SendMessage(userId: number, message: any): boolean
		local ok, delivered = pcall(function()
			return ctx.Persistence.Store:MessageAsync(ctx.Persistence.KeyFor(userId), {
				ScribeMessage = true,
				Data = message,
			})
		end)
		return ok and delivered == true
	end

	--[=[
		@within Server
		@tag Escape hatch
		@server
		@prop ProfileStore ProfileStore
		The underlying ProfileStore instance, an **advanced escape hatch** for
		store-level operations Scribe doesn't wrap (version reads, raw `MessageAsync`,
		and so on). It bypasses Scribe's schema, replication, and session guarantees,
		so treat it as read-mostly and never mutate an active-session profile through
		it. Most games never need this; prefer the typed API and [Server.SendMessage].
	]=]
	Data.ProfileStore = ctx.Persistence.Store

	-- Dev-mode misuse guard: template keys must not be shadowed by an accessor
	-- method (at any depth) or a root-level Data API name — a collided field is
	-- silently unreachable through the typed API.
	if ctx.DevMode then
		local rootChildren = compiled.Root.Children :: { [string]: any }
		for key in Data do
			if rootChildren[key] then
				Log.Warn(
					"Lifecycle",
					"API_NAME_COLLISION",
					`template root field "{key}" collides with a Data API name`,
					{}
				)
			end
		end
		for _, node in compiled.ById do
			local name = node.Name
			if
				name
				and Node.METHOD_NAMES[name]
				and node.Path[1] ~= Template.RESERVED_ROOT
				and node.Path[1] ~= Template.SESSION_ROOT
			then
				Log.Warn(
					"Lifecycle",
					"API_NAME_COLLISION",
					`template field "{name}" collides with an accessor method and is unreachable via the typed API`,
					{ Path = table.concat(node.Path :: { any }, ".") }
				)
			end
		end
	end

	-- Data[player] -> typed accessor tree.
	setmetatable(Data :: any, {
		__index = function(_, key: any)
			if typeof(key) == "Instance" and key:IsA("Player") then
				return entryOrError(key, "Data[player]").Tree.Accessor
			end
			return nil
		end,
	})

	--[=[
		@within Server
		@tag Escape hatch
		@server
		@prop Raw Server
		The same `Data` object without the typed accessor tree: the untyped escape
		hatch if the type solver ever trips on your template.
	]=]
	Data.Raw = Data

	Metrics.Set("SchemaNodes", compiled.NodeCount)
	Log.Info("Lifecycle", "SERVER_STARTED", "Scribe server initialized", {
		Fields = compiled.NodeCount,
		Transport = ctx.Transport.Name,
	})

	return Data, ctx
end

function Server.new(options: any, compiled: Template.Compiled): any
	local Data, ctx = Server.build(options, compiled)

	-- Studio-only debug hook for the Scribe Studio companion plugin. Outside
	-- Studio the branch is never taken and the hook does not exist.
	if RunService:IsStudio() then
		local ok, err = pcall(function()
			(require(script.DebugHook) :: any).Attach(Data, ctx)
		end)
		if not ok then
			Log.Warn("Lifecycle", "DEBUG_HOOK_FAIL", tostring(err), {})
		end
	end

	ctx.Persistence.BindShutdown()

	Players.PlayerAdded:Connect(function(player)
		ctx.Persistence.OnPlayerAdded(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		ctx.Persistence.OnPlayerRemoving(player)
	end)
	for _, player in Players:GetPlayers() do
		ctx.Persistence.OnPlayerAdded(player)
	end

	-- Load banner: one clean line confirming the bundle initialized
	-- (Banner = false to silence).
	if options.Banner ~= false then
		print(`Running Scribe v{Version} by ericplane — server is now initialized`)
	end

	return Data
end

return Server
