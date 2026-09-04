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
local Failure = require(Internal.Failure)

local Persistence = require(script.Persistence)
local Replication = require(script.Replication)
local Commands = require(script.Commands)
local Timed = require(script.Timed)
local Analytics = require(script.Analytics)
local Leaderboards = require(script.Leaderboards)
local Exchanges = require(script.Exchanges)
local ServerStore = require(script.ServerStore)
local Monetization = require(script.Monetization)

local Server = {}

-- Builds the server context and public Data API without the engine-level wiring
-- (PlayerAdded/Removing, BindToClose). The test harness calls this directly to drive
-- the player lifecycle by hand against stub transports. Returns (Data, ctx).
function Server.build(options: any, compiled: Template.Compiled): (any, any)
	local ctx = {} :: any
	ctx.Options = options
	ctx.Compiled = compiled
	-- Studio by default. Overridable because patching RunService is illegal on a real
	-- service Instance, so a spec needing DevMode could not otherwise run in Studio.
	ctx.DevMode = if options.DevMode ~= nil then options.DevMode == true else RunService:IsStudio()
	-- Coarse per-player ceiling on raw inbound frames, spent before a frame is read at
	-- all. Resolved here because Persistence seeds each entry's bucket and Replication
	-- enforces it, and a default derived in two places drifts.
	--
	-- Well above CommandRateLimit on purpose: this tier drops silently, and a silently
	-- dropped Command strands the client until its RequestTimeout, so a merely chatty
	-- client should hit the command token bucket instead. The floor keeps a tiny
	-- CommandRateLimit from throttling handshake and status traffic.
	ctx.InboundFrameRate = options.MaxInboundFrameRate or math.max(60, (options.CommandRateLimit or 20) * 4)
	ctx.Signals = {
		OnSave = Signal.new(), -- { Player, Ok, Duration, At }
		SessionEnded = Signal.new(), -- (player, reason)
		OnAnomaly = Signal.new(), -- { Player, Path, Value, Reason }
		OnGiftReceived = Signal.new(), -- (player, { FromUserId, Product, GiftId })
		OnGiftCredit = Signal.new(), -- (player, productName)
		OnMessage = Signal.new(), -- (player, message)
		OnOwnershipChanged = Signal.new(), -- (player, key, owned)
		OnCooldownEnded = Signal.new(), -- (player, key)
		OnLeaderboard = Signal.new(), -- (boardName, entries)
	}

	if options.LogLevel then
		Log.SetLevel(options.LogLevel)
	end
	if options.LogRingSize ~= nil then
		Log.SetRingSize(options.LogRingSize)
	end
	Health.Configure(options.StatusThresholds)

	ctx.Transport = TransportModule.Resolve(options.Transport, options.TransportChannel)
	-- Did we claim the built-in channel? Only the claiming scope may release it, or a
	-- bundle on a custom transport would take Default away from whoever holds it. Read
	-- the option, not ctx.Transport.Name: a custom adapter may call itself "Default".
	local ownsDefaultChannel = options.Transport == nil or options.Transport == "Default"

	-- Build order matters only for construction-time dependencies; runtime calls flow
	-- through ctx. Pcalled, and the unwind releases what was already built: Replication.new
	-- installs process-global listeners and the constructors after it throw on bad config,
	-- and a failed build leaves no Data object for anyone to call Stop() on. Same list and
	-- reverse order as Data.Stop, each Stop pcalled so one failing teardown cannot replace
	-- the config error the developer is here to read.
	local constructed, constructErr = pcall(function()
		ctx.Analytics = Analytics.new(ctx)
		ctx.Timed = Timed.new(ctx)
		ctx.Persistence = Persistence.new(ctx)
		ctx.Replication = Replication.new(ctx)
		-- After Replication: its OnOp pushes onto Replication's store queue.
		ctx.ServerStore = ServerStore.new(ctx)
		ctx.Commands = Commands.new(ctx)
		ctx.Leaderboards = Leaderboards.new(ctx)
		ctx.Monetization = Monetization.new(ctx)
		-- After Persistence: it reads the resolved mode to decide whether the verdict
		-- key is real or mocked.
		ctx.Exchanges = Exchanges.new(ctx)
	end)
	if not constructed then
		for _, subsystem in
			{
				ctx.Exchanges,
				ctx.Leaderboards,
				ctx.Timed,
				ctx.Monetization,
				ctx.ServerStore,
				ctx.Replication,
				ctx.Persistence,
			}
		do
			if subsystem ~= nil and type(subsystem.Stop) == "function" then
				pcall(subsystem.Stop)
			end
		end
		-- The same release Stop performs: the channel claim and the inbound listener are
		-- both taken above this pcall, so leaving them held turns a config error into
		-- "channel already in use" on the corrected retry. After the subsystems, so
		-- nothing is still sending when the listener goes.
		if ownsDefaultChannel then
			pcall(TransportModule.ReleaseChannel, options.TransportChannel)
		end
		-- Level 0: the message carries its own origin, and re-pointing it at this
		-- line would blame the library for the caller's config.
		error(constructErr, 0)
	end

	-- Background loops start only after every subsystem exists: a constructor throwing
	-- partway must never leave an orphaned loop running against a half-built ctx.
	ctx.Monetization.Start()
	ctx.Timed.Start()
	ctx.Leaderboards.Start()
	ctx.Exchanges.Start()

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

		!!! note "Indexing"
		    `Data[player]` returns the same accessor tree as `Data.Get(player)`. The
		    methods on individual fields (`.Get`, `.Set`, `.Increment`, …) are
		    documented on the [Value] class.
	]=]
	local Data = {} :: any

	-- Luau does not flag an unknown key in an inline table literal passed to an optional
	-- table parameter, only in one bound to a local first, so a typo like
	-- `{ Forcce = true }` type-checks clean and silently does nothing. This is the only
	-- layer that catches it.
	local function checkOptions(given: any, what: string, allowed: { [string]: true })
		if given == nil then
			return
		end
		if type(given) ~= "table" then
			error(`Scribe: {what} options must be a table`, 3)
		end
		local names = {}
		for name in allowed do
			table.insert(names, name)
		end
		table.sort(names)
		for name in given do
			if not allowed[name] then
				error(`Scribe: {what}: unknown option "{tostring(name)}" (expected {table.concat(names, ", ")})`, 3)
			end
		end
	end

	local function entryOrError(player: Player, what: string): any
		local entry = ctx.Persistence.EntryFor(player)
		if not entry then
			error(`Scribe: {what}: no data session for {player.Name}`, 3)
		end
		if entry.State ~= "Ready" then
			error(`Scribe: {what}: data for {player.Name} is {entry.State}: use Data.WaitForData(player)`, 3)
		end
		return entry
	end

	--[=[
		@within Server
		@tag Lifecycle
		@server
		@yields
		@param player Player
		@param timeout number?
		@return (Value?, LifecycleReason?)
		Yields until the player's profile is Ready, then returns their accessor tree,
		waiting up to `timeout` seconds (default 60). On failure returns `(nil, reason)`,
		so always handle the `nil` branch. This is the safe way to read in `PlayerAdded`.

		`reason` is one of seven values, exported as the `Scribe.LifecycleReason` type
		and the `Scribe.Reason` table so you can branch without guessing at spellings:

		| Reason | Meaning | Retryable |
		| --- | --- | --- |
		| `player-left` | The player left. By far the most common. | no |
		| `still-loading` | The wait elapsed while the load was **still in flight**. Nothing has failed; call again, or read [Server.GetState] to watch it. | yes |
		| `timeout` | The wait elapsed and Scribe has no session for this player at all, usually because the bundle was constructed after they joined. | no |
		| `load-failed` | The profile could not be loaded. | no |
		| `migration-failed` | A migration errored, so the profile was released unmigrated. | no |
		| `session-ended` | The session ended while the player was still in game. | no |
		| `shutdown` | The server is closing. | no |

		`still-loading` and `timeout` were one value until 2.0, so handle both if you
		branch on `timeout` today. [Session Lifecycle](../lifecycle.md) says why.
	]=]
	function Data.WaitForData(player: Player, timeout: number?)
		return ctx.Persistence.WaitForData(player, timeout)
	end
	--[=[
		@within Server
		@tag Lifecycle
		@server
		@param player Player
		@return "Loading" | "Ready" | "SessionEnded"
		@return ("Importing" | "ImportThrottled")?
		The player's session state, without yielding.

		The second return says where a **Loading** player actually is, and is nil at every
		other time. `"Importing"` means `ImportLegacyData` is running; `"ImportThrottled"`
		means it is queued on the DataStore request budget. Relay it to your loading screen
		over your own remote: Scribe cannot replicate to a client that has no data yet.
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
		Runs `fn` as a batch: every write inside coalesces into a single replication
		flush and one `Changed` pass. Use it for bulk updates.

		"One `Changed` pass" applies to **containers**. Writing four fields of one
		table fires that table's (and the root's) `Changed` once rather than four
		times, on the server and on the client. Each individual field still fires its
		own leaf `Changed`, because each is a distinct transition with its own old and
		new value. Use [Value.OnChildChanged], which is never coalesced, to learn
		which children moved.

		```lua
		Data.Batch(player, function()
		    state.Index.Set(i + 1)
		    state.StartedAt.Set(0)
		    state.Current.Set(next)
		end)
		-- state.Changed fires ONCE with the end state
		-- state.OnChildChanged fires three times: Index, StartedAt, Current
		-- state.Index.Changed fires once, with its own old and new
		```
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
		Runs `fn` atomically: if it throws, **every** write inside is rolled back and
		`(false, error)` is returned. On success returns `(true, nil)`.

		`fn` **must not yield**. A yield is refused with `(false, error)` and rolled
		back, because a concurrent write landing during the yield would be pulled into
		the transaction, so do the async work before or after. Tagged
		[Value.Increment] and [Value.Decrement] calls inside `fn` defer their economy
		event to commit and drop it on rollback.

		**Atomic in memory, not on the DataStore.** A `true` return means the writes
		landed on this player's tree together, not that they are saved: they queue for
		the next save like any other write. Pair it with [Server.Flush] when the
		operation must be durable before you acknowledge it.

		**One player, and only one.** While the transaction is open, any write to a
		different player's tree is refused, and that refusal fails this transaction.
		There is no cross-player or cross-key transaction. For one-sided value, use the
		durable outbox in [Cross-Key Transactions](../transactions.md) instead.
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
		@param opts { Force: boolean?, Timeout: number? }?
		@return boolean
		Forces a save now instead of waiting for the next autosave. Call it right
		after a grant or purchase. `Force = true` also pushes through a blocked
		wipe-guard save. `Timeout` bounds the wait for save confirmation in
		seconds (default 15); on timeout Flush returns `false`, though the save
		may still complete afterwards.

		When the profile is already on disk (nothing written since the last save,
		no save still in flight, and that save succeeded), this returns `true`
		immediately and spends no DataStore request, because the answer is already
		known. `Force = true` always goes to the store. The saving is real for a
		game that flushes on a timer or a checkpoint; it never applies right after a
		grant, since a grant leaves the profile dirty by definition.
	]=]
	function Data.Flush(player: Player, opts: { Force: boolean?, Timeout: number? }?)
		checkOptions(opts, "Data.Flush", { Force = true, Timeout = true })
		return ctx.Persistence.Flush(player, opts)
	end
	--[=[
		@within Server
		@tag Persistence
		@server
		@param player Player
		@return SaveInfo
		The player's save state (`{ LastSaveAt, LastResult, Dirty, Size }`) for
		"Saving… / Saved ✓ / Unsaved changes" UI. Also mirrored to the owner.
		`Size` is the approximate byte size of the last successful save (nil before
		the first), useful for spotting a profile growing toward the ~4 MB ceiling.
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
		Mutates an offline profile's raw data. Your callback runs against a copy and
		may yield for as long as it likes, and the commit is a compare-and-set: the
		write lands only if, at that instant, the profile is still free of a live
		session **and** still byte-for-byte the one your callback was handed. **A
		refusal writes nothing at all**, not even a key version.

		Three reasons come back: `"profile does not exist"`, since it cannot create
		one; `"profile has an active session on another server"`, because it fails
		closed rather than stealing a live lock; and `"profile changed while the
		update was being prepared"`, meaning something else wrote the key first.
		Nothing was written in any of them, so retrying the last against a fresh read
		is always safe, and is the right response.

		A session whose last write is older than the store's dead-session threshold
		counts as dead and the write proceeds, so a crashed server cannot lock a
		profile out forever. [Offline Profiles](../profiles.md) covers the threshold
		and the custom-store caveat.
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
		@param opts { RollBackReserved: boolean? }?
		@return (boolean, string?)
		Restores a profile to a historical version. **Fails closed** if the user has a
		live session anywhere, and while [service health](../diagnostics.md) reports an
		outage. It needs a live key to write over, so restoring an erased profile fails
		with `no live profile exists for this user to restore over`.

		**The reserved `_Scribe` root is not rolled back.** Receipts granted, gifts
		paid for, perks bought, the purchase log and running cooldowns do not un-happen
		because a backup was restored, so that root is carried across from the live
		profile and stamped with `RestoredFrom`. A preserved root that differed from
		the snapshot's logs `RESTORE_RESERVED_PRESERVED`. The schema `Version` is the
		one exception: it describes the shape of the game data, so it travels with it.

		`RollBackReserved = true` rolls that root back too. It is a repair tool for a
		`_Scribe` that is itself corrupt, and nothing else: see the danger note in
		[Offline Profiles](../profiles.md).
	]=]
	function Data.RestoreVersion(userId: number, versionId: string, opts: { RollBackReserved: boolean? }?)
		checkOptions(opts, "Data.RestoreVersion", { RollBackReserved = true })
		return ctx.Persistence.RestoreVersion(userId, versionId, opts)
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
		@param specOrHandler ({ Args: { any }?, Idempotent: boolean? } | (player: Player, ...any) -> ...any)
		@param handler ((player: Player, ...any) -> ...any)?
		Registers a named command clients can call via [Client.Request]. Sender identity
		is always the real player; args are shape-validated and rate-limited, and the
		handler only runs once the caller is Ready.

		An `Args` entry is a type string (`"string"`, `"number?"`), a Scribe declarator
		(`Scribe.Int`, `Number`, `String`, `Enum`, `Flags`, `Optional`, `ArrayOf`,
		`SetOf`, `DictOf`, `MapOf`), or a shape table describing a table argument. A
		declarator brings its own constraints, so the range is checked before the
		handler runs rather than inside it.

		```lua
		Data.Command("EquipItem", { Args = { "string" } }, function(player, itemId)
		    if not Data[player].Inventory[itemId].Get() then return false, "not owned" end
		    Data[player].Equipped.Set(itemId)
		    return true
		end)

		Data.Command("CreateSaveSlot", {
		    Args = { Scribe.Int(1, { Min = 1, Max = 4 }) },
		}, function(player, slotNumber)
		    -- slotNumber is an integer in [1, 4]; anything else was refused already.
		end)
		```

		`Idempotent = true` makes the command require a caller-supplied key, sent with
		[Client.RequestOnce]. The handler then runs **at most once per key**, and every
		repeat, including one arriving while the first is still yielding, is answered
		with the original reply. The requirement is symmetric: a key sent to a command
		without `Idempotent`, or a plain [Client.Request] to one with it, is refused
		with `"bad-idempotency-key"`.

		[Commands & Requests](../commands.md) covers `Args` and every refusal reason.
	]=]
	function Data.Command(name: string, specOrHandler: any, handler: any?)
		ctx.Commands.Register(name, specOrHandler, handler)
	end

	--[=[
		@within Server
		@tag Exchange
		@server
		@yields
		@function Exchange.Attempt
		@param playerA Player
		@param basketA { ExchangeLeg }
		@param playerB Player
		@param basketB { ExchangeLeg }
		@return ("Committed" | "Aborted")?, string?
		Exchanges two baskets between two players who are both loaded on THIS server.

		Each basket lists what that player GIVES. A leg is one of three kinds:

		| Kind | Shape | Moves |
		| --- | --- | --- |
		| `Key` | `{ Path = { "Inventory" }, Kind = "Key", Key = itemId }` | One whole container entry |
		| `Qty` | `{ Path = { "Coins" }, Kind = "Qty", Amount = n }` | An amount of a bounded `Scribe.Int` |
		| `Stack` | `{ Path = { "Inventory" }, Kind = "Stack", Key = itemId, Amount = n }` | Part of one stacked entry |

		Every path must be declared in the `Exchangeable` option. That list is proved safe
		to move at startup, and every leg of both baskets is checked against it, by path
		AND by kind, before a slot is claimed or any value moves. So a basket may be
		built straight from what a client asked for: the worst a client can name is a
		refusal that costs nothing.

		```lua
		local outcome, why = Data.Exchange.Attempt(alice, {
		    { Path = { "Inventory" }, Kind = "Key", Key = "Emberblade" },
		    { Path = { "Coins" }, Kind = "Qty", Amount = 250 },
		}, bob, {
		    { Path = { "Inventory" }, Kind = "Key", Key = "Frostbrand" },
		})
		if outcome ~= "Committed" then
		    return false, why
		end
		```

		`"Aborted"` is a completed operation, not a failure to clean up after: every basket
		has been returned to its owner. A `nil` outcome is either a refusal before anything
		moved, or an attempt that could not establish a verdict, and the reason says which.

		**What this guarantees, stated exactly.** Atomic commit at a single verdict key.
		ZERO isolation across the two profiles. Conservation without a bounded resolution
		time: nothing is ever duplicated or destroyed, but an exchange interrupted at the
		wrong moment can take until the next load to finish. The attempt itself IS
		bounded and cancels rather than hanging.

		[Exchange](../exchange.md) covers the whole model, including what a player sees
		while an exchange is in flight.
	]=]

	--[=[
		@within Server
		@tag Exchange
		@server
		@function Exchange.Open
		@param player Player
		@return { OpenExchange }
		What this player still has in flight, and what it is holding while it does.

		One entry per open exchange: `Id`, `State` (`"Claimed"`, `"Staked"` or
		`"Delivering"`), `Partner`, `Staked` (what they handed over) and `Owed` (what they
		are owed). Escrow takes value out of the balance on purpose and the resolution time
		is not bounded, so this is how a game tells a player where their coins went rather
		than leaving them looking at a hole. Empty when nothing is open.
	]=]

	--[=[
		@within Server
		@tag Exchange
		@server
		@yields
		@function Exchange.Discard
		@param exchangeId string
		@return boolean, string?
		Drops an abandoned claim that never took value.

		An operator verb, and verdict-gated like the other two: it refuses anything with a
		verdict and anything holding staked value. Use it for a claim left behind by a
		server that died between claiming a slot and staking into it.
	]=]

	--[=[
		@within Server
		@tag Exchange
		@server
		@yields
		@function Exchange.Settle
		@param exchangeId string
		@param verdict string
		@return boolean, string?
		Forces `"Commit"` or `"Abort"` on an exchange that cannot resolve itself.

		There is no default and a missing `verdict` is refused: guessing `Abort` would, in
		exactly the situation this verb exists for, land a fresh Abort against a Commit the
		other side already acted on. `Commit` is additionally refused when it cannot be
		proved safe, which is when either loaded record holds escrow with no take recorded,
		or when only one side is loaded. `Abort` needs neither check.

		Loses to a verdict that already exists rather than overwriting it.
	]=]

	--[=[
		@within Server
		@tag Exchange
		@server
		@yields
		@function Exchange.Redirect
		@param exchangeId string
		@param userId number
		@param newKey string
		@return boolean, string?
		Lands a parked delivery on a different key of the same container.

		For a delivery that cannot apply because its destination key is taken. Refuses a
		different container, a set (where the key IS the value, so re-keying substitutes a
		different item), and a parked entry holding more than one key leg, since one new key
		cannot name several destinations without collapsing them onto each other.
	]=]
	Data.Exchange = {
		Attempt = function(playerA: Player, basketA: { any }, playerB: Player, basketB: { any })
			return ctx.Exchanges.Attempt(playerA, basketA, playerB, basketB)
		end,
		Open = function(player: Player)
			return ctx.Exchanges.Open(player)
		end,
		Discard = function(exchangeId: string)
			return ctx.Exchanges.Discard(exchangeId)
		end,
		Settle = function(exchangeId: string, verdict: string)
			return ctx.Exchanges.Settle(exchangeId, verdict)
		end,
		Redirect = function(exchangeId: string, userId: number, newKey: string)
			return ctx.Exchanges.Redirect(exchangeId, userId, newKey)
		end,
	}

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
		@param player Player
		@param name string
		@return (boolean, string?)
		Prompts `player` to buy a declared product or pass for themselves, by the name you
		gave it rather than its numeric Id.

		```lua
		local ok, why = Data.PromptPurchase(player, "CoinPack500")   -- a product
		local ok, why = Data.PromptPurchase(player, "VIP")           -- a pass
		if not ok then
		    warn(why)
		end
		```

		The name is resolved against `Products` and `Passes`, and the matching engine call
		is made: `PromptProductPurchase` for one, `PromptGamePassPurchase` for the other.
		A name declared in **both** tables is a startup error, because resolution is by
		name and table order would otherwise decide what the player is charged for.

		**Refuses something the player already owns**, so a caller does not have to pair
		every prompt with its own [Server.Owns] check. A pass is its own ownership key. A
		product is checked against its `Grants` perk, and a product with no `Grants` is a
		consumable, has nothing to own, and always prompts.

		Ownership is read from Scribe's cache rather than a live Marketplace call, because
		this is a UI gate: for a product the receipt path is what actually prevents a
		double grant, and Roblox itself refuses a pass the player holds.

		A `PaidRandom` product is refused for a player whose policy restricts paid random
		items, and while that policy is not yet known.

		Returns `(false, reason)`, where `reason` is the [Scribe.ProductState] the prompt
		refused on: `"not-loaded"`, `"owned"`, `"paid-random-restricted"` or
		`"policy-pending"`. [Server.GetProductState] answers the same state without
		prompting. Two reasons sit outside that set: an unknown name, and a prompt the
		engine refused, which is what an unpublished product looks like. None of those
		raise.

		Prompting is all it does. The grant happens on the receipt, through the same path
		every purchase takes, so a player who buys and then leaves is still granted on
		their next load.

		See [Monetization](../monetization.md).
	]=]
	function Data.PromptPurchase(player: Player, name: string)
		return ctx.Monetization.PromptPurchase(player, name)
	end
	--[=[
		@within Server
		@tag Monetization
		@server
		@param player Player
		@param name string
		@return ProductState
		The state of a declared product or pass for `player`, as one
		[Scribe.ProductState] string: what [Server.PromptPurchase] would refuse with, or
		`"purchasable"`. A shop that greys a button on this and the prompt behind it
		cannot disagree. Raises for a name that is not declared.

		```lua
		if Data.GetProductState(player, "LootBox") == Scribe.ProductState.Purchasable then
		    showBuyButton(player)
		end
		```
	]=]
	function Data.GetProductState(player: Player, name: string): string
		return ctx.Monetization.GetProductState(player, name)
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
		@param receiptInfo table
		@return Enum.ProductPurchaseDecision?
		Like [Server.HandleReceipt], but returns `nil` for a product Scribe does
		not know, so your own `ProcessReceipt` can fall through to its own
		handling. Use this one when you route **every** receipt through Scribe:

		```lua
		MarketplaceService.ProcessReceipt = function(receiptInfo)
		    local decision = Data.TryHandleReceipt(receiptInfo)
		    if decision then
		        return decision -- a Scribe product; already granted and saved
		    end
		    return myOwnHandler(receiptInfo)
		end
		```

		`HandleReceipt` answers `NotProcessedYet` for an unknown product instead, which
		is correct when Scribe owns `ProcessReceipt` but would stall **your** product in
		a permanent retry loop when routed through an external handler. This variant
		also logs nothing for an unknown product, since there it is normal.
	]=]
	function Data.TryHandleReceipt(receiptInfo: any)
		return ctx.Monetization.TryHandleReceipt(receiptInfo)
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

		Non-yielding, so it reads the gamepass cache that fills asynchronously right
		after a player joins. For a gate that must be correct at that instant, use
		[Server.OwnsAsync].
	]=]
	function Data.Owns(player: Player, key: string)
		return ctx.Monetization.Owns(player, key)
	end
	--[=[
		@within Server
		@tag Monetization
		@server
		@yields
		@param player Player
		@param key string
		@param timeout number?
		@return boolean
		Like [Server.Owns] but **authoritative and yielding**: if the pass is not
		already owned in the cache, it verifies live with the server-side
		`UserOwnsGamePassAsync` on every call, so a pass bought moments ago (in
		experience or on the Roblox website) is reflected immediately. Once owned,
		the cached value is returned without a re-check. This is the ownership check
		to gate grants on. The client's `Owns`/`OwnsAsync` are only mirror reads and
		must never gate a grant. (`timeout` applies only to the client version, which
		waits on a replicated flag.)
	]=]
	function Data.OwnsAsync(player: Player, key: string, timeout: number?)
		return ctx.Monetization.OwnsAsync(player, key, timeout)
	end
	--[=[
		@within Server
		@tag Monetization
		@server
		@param player Player
		@param key string
		@param callback (owned: boolean) -> ()
		@return () -> ()
		Calls `callback` with the player's current ownership of `key`, then again
		whenever it changes. Returns a disconnect function. The server twin of
		[Client.ObserveOwned]. To react to any key without subscribing per key, use
		[Server.OnOwnershipChanged].
	]=]
	function Data.ObserveOwned(player: Player, key: string, callback: (owned: boolean) -> ())
		return ctx.Monetization.ObserveOwned(player, key, callback)
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
		Atomic soft-currency purchase: debits `Cost`, runs `Grant`, and logs it. All or
		nothing: insufficient funds or a throwing `Grant` rolls everything back, no debit.

		```lua
		Data.Purchase(player, {
		    Cost = { Path = "Coins", Amount = 45000 },
		    Category = "Vehicle", ItemId = "Police01",
		    Grant = function(data) data.Vehicles.Insert("Police01") end,
		})
		```

		`Cost.Path` may point into a typed container, where the element's `Min` floor
		and int rule apply to the debit. An unresolvable path returns
		`(false, "invalid cost path")`, but a [Scribe.DictOf] accepts any key, so a typo
		there spends the element default as a balance nobody granted.

		An optional `IdempotencyKey` (up to 64 bytes, valid UTF-8) makes the purchase a
		once-guard: a repeat under that key answers what the first call answered and
		spends nothing. [Monetization](../monetization.md) covers claims and reasons.
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
		@param filter PurchaseFilter?
		@return { table }
		The player's purchase history (Robux receipts and in-game purchases),
		newest first, optionally filtered.

		`PurchaseFilter` is `{ Kind: ("Robux" | "InGame")?, Category: string?,
		ItemId: string?, Since: number?, Limit: number? }`, exported as
		`Scribe.PurchaseFilter`.
	]=]
	function Data.GetPurchases(player: Player, filter: any?)
		checkOptions(filter, "Data.GetPurchases", {
			Kind = true,
			Category = true,
			ItemId = true,
			Since = true,
			Limit = true,
		})
		return ctx.Monetization.GetPurchases(player, filter)
	end

	--[=[
		@within Server
		@tag Cooldowns
		@server
		@param player Player
		@param key string
		@param seconds number
		@param opts { IncludeOfflineTime: boolean? }?
		@return (onCooldown: boolean, remaining: number)
		Checks **and arms** a keyed cooldown: returns `false` and starts a new
		`seconds` cooldown if it was off. Call it only at the grant or claim moment,
		and use [Server.PeekCooldown] for display checks.

		Pass `{ IncludeOfflineTime = false }` for a cooldown that only ticks down
		while the player is **online**. The default counts wall-clock time, so a
		one-hour cooldown armed before logging off is over on a rejoin the next day;
		with the option off, that same rejoin still has the full hour left.

		```lua
		Data.OnCooldown(player, "DailyChest", 86400)                            -- ticks while offline
		Data.OnCooldown(player, "Boost", 3600, { IncludeOfflineTime = false })  -- only while playing
		```

		A key holds one cooldown either way: re-arming it in the other mode replaces
		the first rather than leaving two running, and [Server.ClearCooldown] and
		[Server.PeekCooldown] cover both without needing to know which was used.
	]=]
	function Data.OnCooldown(
		player: Player,
		key: string,
		seconds: number,
		opts: { IncludeOfflineTime: boolean? }?
	): (boolean, number)
		local entry = entryOrError(player, "Data.OnCooldown")
		checkOptions(opts, "Data.OnCooldown", { IncludeOfflineTime = true })
		return ctx.Timed.OnCooldown(entry, key, seconds, opts)
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

		The value is a [Signal](signal.md), where `Connect`, `Once` and `Wait` are documented.
	]=]
	Data.OnSave = ctx.Signals.OnSave
	--[=[
		@within Server
		@tag Signals
		@server
		@prop SessionEnded Signal
		Fires when a session ends with `(player, reason)`. With
		`KickOnSessionEnd = true` (the default) the player is also kicked.

		The value is a [Signal](signal.md), where `Connect`, `Once` and `Wait` are documented.
	]=]
	Data.SessionEnded = ctx.Signals.SessionEnded
	--[=[
		@within Server
		@tag Signals
		@server
		@prop OnAnomaly Signal
		Fires for integrity anomalies (out-of-bounds writes, a tripped wipe guard,
		an unserializable snapshot) with `{ Player, Path, Value, Reason }`.

		The value is a [Signal](signal.md), where `Connect`, `Once` and `Wait` are documented.
	]=]
	Data.OnAnomaly = ctx.Signals.OnAnomaly
	--[=[
		@within Server
		@tag Signals
		@server
		@prop OnGiftReceived Signal
		Fires when a player receives a gift with `(player, { FromUserId, Product, GiftId })`.

		The value is a [Signal](signal.md), where `Connect`, `Once` and `Wait` are documented.
	]=]
	--[=[
		@within Server
		@tag Monetization
		@server
		@prop OnOwnershipChanged Signal
		Fires `(player, key, owned)` whenever a player's effective ownership of a
		pass, perk, or RobloxPlus actually changes, covering purchases, grants, gift
		deliveries, and revokes. Pre-existing ownership at join is the baseline and
		does not fire. Use this to react to any grant without subscribing per key;
		use [Server.ObserveOwned] for one specific key.

		Ownership only ever gains within a session, so a game pass **refund** is not
		detected until the player rejoins (a cached `true` is never re-verified).

		The value is a [Signal](signal.md), where `Connect`, `Once` and `Wait` are documented.
	]=]
	Data.OnOwnershipChanged = ctx.Signals.OnOwnershipChanged
	--[=[
		@within Server
		@tag Signals
		@server
		@prop OnCooldownEnded Signal
		Fires with `(player, key)` when a cooldown lapses, within about a second of
		its expiry. A cooldown holds no value, so unlike a [Scribe.Timed] field it
		fires no `Changed`; this is its only expiry notification.

		One signal covers every cooldown, because cooldown keys are arbitrary
		strings rather than declared fields, so there is no set to subscribe to.
		Filter inside the handler for a specific one:

		```lua
		Data.OnCooldownEnded:Connect(function(player, key)
		    if key ~= "DailyReward" then
		        return
		    end
		    -- ...
		end)
		```

		Cooldowns that lapsed while the player was offline do **not** fire on join.
		Read the current state with [Server.PeekCooldown] instead.

		The value is a [Signal](signal.md), where `Connect`, `Once` and `Wait` are documented.
	]=]
	--[=[
		@within Server
		@tag Signals
		@server
		@prop OnLeaderboard Signal
		Fires with `(boardName, entries)` when a board's contents actually change, once
		per refresh cycle. `entries` is a fresh copy, safe to keep or mutate, and is
		**rank-ordered**: `entries[1]` is rank 1, the same order and shape
		[Server.GetLeaderboard] returns. An unchanged board does not re-fire, so this is
		quiet on an idle board.

		This is the server-side counterpart to the client signal of the same name, and
		unlike that one it fires for **every** board, not just `Replicate` ones. That
		matters because a server-only board is the default, and polling cannot align
		with the per-board refresh schedule.

		See [Leaderboards](../leaderboards.md) for the connect example.

		The value is a [Signal](signal.md), where `Connect`, `Once` and `Wait` are documented.
	]=]
	Data.OnLeaderboard = ctx.Signals.OnLeaderboard
	Data.OnCooldownEnded = ctx.Signals.OnCooldownEnded
	Data.OnGiftReceived = ctx.Signals.OnGiftReceived
	--[=[
		@within Server
		@tag Signals
		@server
		@prop OnGiftCredit Signal
		Fires when a player is issued a gift credit with `(player, productName)`.

		The value is a [Signal](signal.md), where `Connect`, `Once` and `Wait` are documented.
	]=]
	Data.OnGiftCredit = ctx.Signals.OnGiftCredit
	--[=[
		@within Server
		@tag Messaging
		@server
		@prop OnMessage Signal
		Fires with `(player, message)` when a cross-server message sent through
		[Server.SendMessage] arrives for an active session.

		**Delivery is at-least-once, so handlers must be idempotent.** A message is
		retired from the recipient's key only once a handler has *returned without
		raising*, and only in the same write that persists the data that handler
		produced. So a message survives, and is handed to you again on the player's
		next load, whenever nothing was connected here (logged as
		`MESSAGE_NO_LISTENER`), a handler raised (`MESSAGE_HANDLER_ERROR`), or the save
		carrying its effect never landed. Payloads carry no id of their own, so put one
		in yours (an exchange id, a payout id) and ignore a repeat. Seeing a message twice
		is recoverable; losing one is not, which is the trade this makes.

		Redelivery is bounded rather than continuous: an unacknowledged message is
		offered once per session, not once per save.

		The value is a [Signal](signal.md), where `Connect`, `Once` and `Wait` are documented.
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

		**The queue is bounded** at 1,000 undelivered messages per recipient, and a
		send past the cap returns `false` and logs
		[`MESSAGE_QUEUE_FULL`](../log-codes.md#persistence). It used to return `true` after silently
		dropping the OLDEST queued message. Always check the return value and keep the
		message retryable: a recipient's queue fills when messages arrive faster than
		they log in to drain them, or when a handler never acknowledges one.

		**`true` means committed, not delivered and not handled.** Delivery to
		[Server.OnMessage] is at-least-once: a message the recipient's handler never
		returned from, raised on, or that had no handler connected at all is kept and
		re-offered on their next load. Give the payload an id of your own and make the
		handler idempotent.

		**`false` does not always mean nothing was written.** The store retries
		internally, so a write can commit and then lose its answer, after which the
		refusal you get back is reported for a message that is already in the
		recipient's inbox. The log line and its `Context.ProvablyClean` say which
		happened; the return value cannot. Retrying is still the right response, and
		that is what the idempotent payload above is for.
	]=]
	function Data.SendMessage(userId: number, message: any): boolean
		-- `provablyClean` is MessageAsync's third return: true only where no attempt in
		-- its own retry loop could have written. Read for the log line alone; the boolean
		-- this function returns is unchanged.
		local ok, delivered, reason, provablyClean = pcall(function()
			return ctx.Persistence.Store:MessageAsync(ctx.Persistence.KeyFor(userId), {
				ScribeMessage = true,
				Data = message,
			})
		end)
		if ok and delivered == true then
			Health.ReportSuccess("SendMessage")
			return true
		end
		if ok and reason == "QueueFull" then
			-- Deliberately not Failure.Report: that calls Health.ReportFailure, and a full
			-- inbox is one player's profile rather than a DataStore fault, so a single
			-- jammed queue would degrade the whole server to Outage and refuse every Robux
			-- grant. An earlier attempt of the same call may also have committed and lost
			-- only its answer, so this can be reported for a message already in the inbox.
			Metrics.Add("MessageQueueFull")
			if provablyClean ~= true then
				Metrics.Add("MessageQueueFullAmbiguous")
			end
			Log.Warn(
				"Persistence",
				"MESSAGE_QUEUE_FULL",
				if provablyClean == true
					then "the recipient's message queue is at its cap and no attempt in this call reached "
						.. "storage; nothing was written"
					else "the recipient's message queue is at its cap, but an earlier attempt in the same "
						.. "call may already have queued this message; it may yet be delivered",
				{ UserId = userId, ProvablyClean = provablyClean == true }
			)
			return false
		end
		-- Keyed by recipient, so a shutdown that fails to deliver for one player counts as
		-- one problem instead of one per attempt. Past this point the send threw,
		-- MessageAsync gave up retrying, or it refused at its IsClosing door without
		-- attempting anything; `provablyClean` separates them. The return is `false` either
		-- way, because at-least-once is this channel's contract.
		Failure.Report({
			Subsystem = "SendMessage",
			Key = tostring(userId),
			Error = if ok then nil else delivered,
			Category = "Persistence",
			Code = "MESSAGE_SEND_FAIL",
			Message = if ok and provablyClean == true
				then "MessageAsync failed; nothing reached storage, so the message was not delivered"
				else "MessageAsync failed; the message may or may not have been delivered, so treat it as retryable",
			Context = {
				UserId = userId,
				Threw = not ok,
				ProvablyClean = ok and provablyClean == true,
				Error = if ok then nil else tostring(delivered),
			},
		})
		return false
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

	-- Dev-mode misuse guard: a template key shadowed by an accessor method, at any depth,
	-- is silently unreachable through the typed API. The root-level half runs at the very
	-- end of build; see the comment on it for why.
	if ctx.DevMode then
		local function warnCollision(node: any)
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
		-- ById covers static fields; element subtrees are id-less and hang off
		-- AnyChild, so they have to be walked explicitly.
		local function walkElements(node: any)
			local anyChild = node.AnyChild
			if anyChild and anyChild.IsElement then
				local function walkSubtree(n: any)
					warnCollision(n)
					if n.Children then
						for _, child in n.Children do
							walkSubtree(child)
						end
					end
					if n.AnyChild and n.AnyChild.IsElement then
						walkSubtree(n.AnyChild)
					end
				end
				walkSubtree(anyChild)
			end
			if node.Children then
				for _, child in node.Children do
					walkElements(child)
				end
			end
		end
		for _, node in compiled.ById do
			warnCollision(node)
		end
		walkElements(compiled.Root)
	end

	-- Data[player] -> typed accessor tree.
	setmetatable(Data :: any, {
		__index = function(_, key: unknown)
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

	-- Hoisted above the doc block below: docgen resolves a @within block from the
	-- next line of code, so a declaration between the two orphans the member.
	local stopped = false

	--[=[
		@within Server
		@tag Lifecycle
		@server
		Releases everything this bundle holds on the process: the Timed sweep, the
		leaderboard write pacer and refresh cycle, the per-frame replication flush,
		the Players and MarketplaceService listeners, the ProfileStore signal
		handlers, and `MarketplaceService.ProcessReceipt` if this bundle owns it.

		A Scribe bundle is normally built once and lives for the server's lifetime,
		so a game never needs this. It exists because a PROCESS that builds many
		bundles (a test suite, or a simulation standing up a fleet of servers)
		otherwise accumulates immortal loops and listeners, and ends up measuring
		that accumulation rather than Scribe.

		Idempotent, and does NOT save: call `Data.Flush` first if the data matters.
		Loaded sessions are left alone; drop the bundle and they go with it.
	]=]
	function Data.Stop()
		if stopped then
			return
		end
		stopped = true
		-- Reverse of the Start order: stop producing work before releasing what consumes it.
		for _, subsystem in
			{
				ctx.Exchanges,
				ctx.Leaderboards,
				ctx.Timed,
				ctx.Monetization,
				ctx.ServerStore,
				ctx.Replication,
				ctx.Persistence,
			}
		do
			if subsystem ~= nil and type(subsystem.Stop) == "function" then
				local ok, err = pcall(subsystem.Stop)
				if not ok then
					Log.Warn("Lifecycle", "SUBSYSTEM_HOOK_ERROR", `Stop failed: {tostring(err)}`, {})
				end
			end
		end
		-- After the subsystems, so nothing is still sending when the channel's listener
		-- goes. The claim is a module global that outlives this bundle, so leaving it set
		-- means the channel can never be rebound.
		if ownsDefaultChannel then
			pcall(TransportModule.ReleaseChannel, options.TransportChannel)
		end
	end

	-- Per store root, not the store's root accessor: the client holds one tree over both
	-- halves, so this keeps the surface identical on both realms.
	--[=[
		@within Server
		@tag Reads
		@server
		@prop ServerStore table
		The server-owned tree, one per server rather than per player, present only
		when the bundle declares `ServerStore`. Each declared root is an accessor
		reached with no player argument, as in `Data.ServerStore.Wave.Set(3)`.
		
		Nothing in it is saved, and the same shape appears on the client, where it
		is read-only. See [Server-owned state](../server-store.md).
	]=]
	if ctx.ServerStore ~= nil then
		local proxy = {}
		for _, key in compiled.Views.Store.RootOrder do
			proxy[key] = ctx.ServerStore.Accessor[key]
		end
		Data.ServerStore = table.freeze(proxy)
	end

	-- A root field named like a Data API name is silently shadowed by that real key (a
	-- real key always wins over __index), so it is unreachable as `Data.<name>`.
	--
	-- Keep this last, after every Data key is assigned: `for key in Data` sees only the
	-- keys that exist when it runs, so a guard placed higher exempts everything below it.
	-- Server.new redefines Data.Stop after this but adds no new key, so this still sees
	-- the whole public surface.
	-- Raw iteration, so the metatable installed above is not consulted.
	if ctx.DevMode then
		local rootChildren = compiled.Root.Children :: { [string]: any }
		for key in Data do
			if type(key) == "string" and rootChildren[key] then
				-- In the context as well as the message, so a sink need not parse prose.
				Log.Warn(
					"Lifecycle",
					"API_NAME_COLLISION",
					`template root field "{key}" collides with a Data API name`,
					{ Field = key }
				)
			end
		end
	end

	return Data, ctx
end

function Server.new(options: any, compiled: Template.Compiled): any
	local Data, ctx = Server.build(options, compiled)

	-- Studio-only debug hook for the Scribe Studio companion plugin. The remover Attach
	-- hands back is kept: it releases a Log sink and a Health.OnStatusChanged listener,
	-- both library-level singletons that outlive the bundle, and ends the digest pump.
	-- Nil on the refusal and pcall failure paths, and Stop below tolerates both.
	local detachDebugHook: (() -> ())? = nil
	if RunService:IsStudio() then
		local ok, err = pcall(function()
			detachDebugHook = (require(script.DebugHook) :: any).Attach(Data, ctx)
		end)
		if not ok then
			Log.Warn("Lifecycle", "DEBUG_HOOK_FAIL", tostring(err), {})
		end
	end

	ctx.Persistence.BindShutdown()

	local playerConnections = {
		Players.PlayerAdded:Connect(function(player)
			ctx.Persistence.OnPlayerAdded(player)
		end),
		Players.PlayerRemoving:Connect(function(player)
			ctx.Persistence.OnPlayerRemoving(player)
		end),
	}
	for _, player in Players:GetPlayers() do
		ctx.Persistence.OnPlayerAdded(player)
	end

	-- Extend build's Stop with the engine wiring only Server.new installs, so each
	-- scope releases exactly what it created.
	local stopSubsystems = Data.Stop
	function Data.Stop()
		for _, connection in playerConnections do
			pcall(function()
				connection:Disconnect()
			end)
		end
		table.clear(playerConnections)
		-- Before the subsystems, and cleared so a second Stop cannot call it twice: the
		-- digest pump reads Persistence.Entries once a tick, so the hook lets go before
		-- what it watches is dismantled. pcalled: a debug facility must not fail teardown.
		local detach = detachDebugHook
		detachDebugHook = nil
		if detach ~= nil then
			local ok, err = pcall(detach)
			if not ok then
				Log.Warn("Lifecycle", "DEBUG_HOOK_FAIL", tostring(err), {})
			end
		end
		stopSubsystems()
	end

	if options.Banner ~= false then
		print(`Running Scribe v{Version} by ericplane. Server is now initialized`)
	end

	return Data
end

return Server
