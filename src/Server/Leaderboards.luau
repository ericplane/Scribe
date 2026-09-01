--!strict
-- Global all-time leaderboards on OrderedDataStore: paced deduplicated write
-- queue, cached top-N reads, and per-player rank replication. Clients are
-- served from the server cache only.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local Internal = script.Parent.Parent.Internal
local Util = require(Internal.Util)
local Wire = require(Internal.Wire)
local Template = require(Internal.Template)
local Big = require(Internal.Big)
local Log = require(Internal.Log)
local Metrics = require(Internal.Metrics)
local Clock = require(Internal.Clock)
local Profile = require(Internal.Profile)
local Sched = require(Internal.Sched)
local Budget = require(Internal.Budget)
local Rng = require(Internal.Rng)
local Failure = require(Internal.Failure)

local Leaderboards = {}

local WRITE_INTERVAL = 1.5
-- Ceiling on what one tick may drain once the queue has backed up. Every write
-- yields, so an unbounded drain turns the pacer into the unpaced flush it prevents.
local MAX_WRITES_PER_TICK = 8
local REFRESH_INTERVAL = 60
-- Floor on a per-board RefreshInterval. GetSortedAsync's request budget scales with
-- player count, so a near-empty server is the worst case. A sub-minute board is
-- almost always an in-server scoreboard, which belongs in Scribe.Shared at no
-- DataStore cost.
local MIN_REFRESH_INTERVAL = 60
-- Boot guard on the aggregate rate, which is what actually burns budget: ten boards
-- at 60s cost more than one at 15s, and the flat floor above permits exactly that.
local MAX_REFRESH_PER_MINUTE = 12
local QUEUE_CAP = 1000
-- Requests left in reserve when BudgetPolicy defers. Not zero: the ungated shutdown
-- drain writes to the same Sorted pool, so the loops stop one short of emptying it.
local BUDGET_RESERVE = 1
-- Seconds between LB_BUDGET_DEFERRED warns. Deferral is normal and self-correcting,
-- so only a sustained one should be visible.
local BUDGET_LOG_INTERVAL = 30
-- Seconds between LB_QUEUE_OVERFLOW warns; drops in between are counted and
-- reported on the next one.
local OVERFLOW_LOG_INTERVAL = 30
-- Seconds between store-failure warns of the same code. Failures arrive once per
-- queued write and once per refresh, so an outage otherwise logs a line per attempt.
local FAILURE_LOG_INTERVAL = 30
local NAME_TTL = 900
local NAME_NEGATIVE_TTL = 120
local NAME_CACHE_CAP = 4096 -- bound the resolved-name cache; entries are re-resolvable

-- Scribe.Big leaderboards ----------------------------------------------------------
--
-- An OrderedDataStore key is an integer, so a big is packed exponent-major:
--
--   key = e * stride + floor(m * mantissaScale)
--
-- with stride = 10^SigFigs and mantissaScale = 10^(SigFigs - 1). The mantissa lands
-- in [mantissaScale, stride) and can never spill into the next exponent's slot, so
-- the ordering is exact. SigFigs is per board because the key must stay under 2^53
-- and every extra significant figure costs a factor of ten of exponent range.
local BIG_DEFAULT_SIG_FIGS = 12
local BIG_MIN_SIG_FIGS = 1
-- Past 15 the mantissa slot itself passes 2^53, so floor() would no longer be exact
-- and a big carries no more than ~15 significant digits anyway.
local BIG_MAX_SIG_FIGS = 15
local MAX_EXACT_INT = 2 ^ 53

-- The largest exponent whose key still lands under 2^53. The mantissa slot holds up
-- to stride - 1, so that headroom comes off the top.
local function bigMaxExponent(stride: number): number
	return math.floor((MAX_EXACT_INT - stride + 1) / stride)
end

type Board = {
	Name: string,
	StatPath: { string },
	Limit: number,
	Scale: number,
	IsBig: boolean,
	-- Big packing, derived once at boot from the board's SigFigs.
	BigSigFigs: number,
	BigStride: number,
	BigMantissaScale: number,
	BigMaxExponent: number,
	RefreshInterval: number,
	Replicate: boolean, -- default false: server-only, no client mirror
	StoreName: string,
	Cache: { Entries: { any }, At: number },
	Signature: string, -- fingerprint of Cache.Entries; broadcasts only on change
	MyRanks: { [number]: number? },
	-- `any`, not `number`: a big board's score is the Big itself, not the packed key.
	MyScores: { [number]: any },
	SentState: { [number]: { Sig: string, Rank: number?, Score: any } },
}

-- In-memory OrderedDataStore shim for UseMock/DontSave testing.
local function newMockOrderedStore()
	local values: { [string]: number } = {}
	return {
		SetAsync = function(_, key: string, value: number)
			values[key] = value
		end,
		RemoveAsync = function(_, key: string)
			values[key] = nil
		end,
		GetSortedAsync = function(_, ascending: boolean, pageSize: number)
			local sorted = {}
			for key, value in values do
				table.insert(sorted, { key = key, value = value })
			end
			table.sort(sorted, function(a: { key: string, value: number }, b: { key: string, value: number })
				if ascending then
					return a.value < b.value
				end
				return a.value > b.value
			end)
			local page = table.move(sorted, 1, math.min(pageSize, #sorted), 1, {})
			return {
				GetCurrentPage = function()
					return page
				end,
			}
		end,
	}
end

function Leaderboards.new(ctx: any)
	local self = {} :: any
	local options = ctx.Options
	-- Read the resolved mode, not options.UseMock: Persistence resolves Mode into its
	-- own fields and never writes it back, so a Mode = "Mock" bundle would otherwise
	-- hit real OrderedDataStores. NoSave mocks too, since a board write is a write.
	local mode: string = ctx.Persistence.Mode
	local useMock: boolean = mode == "Mock" or mode == "NoSave"

	local boards: { [string]: Board } = {}
	local storeCache: { [string]: any } = {}
	local mockStores: { [string]: any } = {}

	local stopped = false
	local pacerThread: thread? = nil
	local refreshThread: thread? = nil
	local writeQueue: { { Board: Board, UserId: number, Score: number, Attempts: number } } = {}
	local writeQueueMap: { [string]: { Board: Board, UserId: number, Score: number, Attempts: number } } = {}
	-- Overflow-log throttle: over cap the warn rate tracks the stat-change rate of every
	-- out-of-queue player, enough to roll the log ring. The counter still counts drops.
	local lastOverflowLog: number? = nil
	local overflowSinceLog = 0
	-- Budget-aware admission for the two background loops, opt-in. Mock modes never
	-- touch a real DataStore, so asking would stall the loops on nothing.
	local budgetPolicy: boolean = options.BudgetPolicy == "Defer" and not useMock
	local lastBudgetLog: number? = nil

	-- Store-failure reporting -------------------------------------------------------

	local failureLog: { [string]: { Last: number?, Since: number } } = {}
	-- Studio with API access off refuses every store call for the whole session. It is
	-- a setting rather than an outage, so it is reported once and then silenced.
	local apiAccessReported = false

	--- Is Studio refusing the call because API access is off, rather than a store problem?
	--- Matched on the two phrasings Roblox uses. A miss costs nothing: the caller throttles.
	local function isStudioApiDisabled(text: string): boolean
		local lower = string.lower(text)
		return string.find(lower, "studio access to apis", 1, true) ~= nil
			or string.find(lower, "api access is not enabled", 1, true) ~= nil
	end

	--- One line per failure code per interval, with the suppressed count carried onto the
	--- next. Callers count their own metric, which stays accurate while this is quiet.
	local function reportStoreFailure(code: string, err: any, context: { [string]: any })
		-- Once the Studio setting has been named, every later failure has the same cause.
		if apiAccessReported then
			return
		end
		local text = tostring(err)
		if isStudioApiDisabled(text) then
			apiAccessReported = true
			Log.Warn(
				"Leaderboards",
				code :: any,
				"leaderboard store calls are being refused because Studio API access is off, so boards "
					.. "will neither read nor write for this session. Turn on File > Game Settings > "
					.. "Security > Enable Studio Access to API Services (the place must be published). "
					.. "Reported once; further failures are counted in LbReadFailures and LbWriteFailures",
				context
			)
			return
		end
		local state = failureLog[code]
		if state == nil then
			state = { Last = nil, Since = 0 } :: { Last: number?, Since: number }
			failureLog[code] = state
		end
		state.Since += 1
		local now = Clock.Monotonic()
		if state.Last == nil or now - state.Last >= FAILURE_LOG_INTERVAL then
			state.Last = now
			local suppressed = state.Since - 1
			state.Since = 0
			Log.Warn(
				"Leaderboards",
				code :: any,
				if suppressed > 0 then `{text} ({suppressed} more since the last of these)` else text,
				context
			)
		end
	end
	-- GDPR tombstones: an erased userId is suppressed in the pacer until this
	-- clock time, long enough to outlive any in-flight write plus its retries.
	local erasedUsers: { [number]: number } = {}
	local function isErased(userId: number): boolean
		local until_ = erasedUsers[userId]
		if until_ == nil then
			return false
		end
		if Clock.Monotonic() >= until_ then
			erasedUsers[userId] = nil -- expired; a returning player may re-enter
			return false
		end
		return true
	end
	local nameCache: { [number]: { Name: string?, At: number } } = {}
	local statDisconnects: { [any]: { () -> () } } = {}

	for name, config in (options.Leaderboards or {}) :: { [string]: any } do
		if type(config.Stat) ~= "string" then
			error(`Scribe: leaderboard "{name}" must declare a Stat path`, 0)
		end
		if config.Period ~= nil and config.Period ~= "AllTime" then
			error(`Scribe: leaderboard "{name}": only all-time leaderboards are supported`, 0)
		end
		-- Fail fast on a Stat path that descends through a leaf field: at runtime it
		-- throws on every player load, after Ready, skipping the rest of that load's
		-- wiring. Paths into dynamic ("any") subtables are legitimate and pass.
		local statPath = Util.parsePath(config.Stat)
		local walkNode: any = ctx.Compiled.Root
		for i, segment in statPath do
			if walkNode == nil then
				-- ChildSchema returns nil only for an undeclared field of a closed
				-- element shape, so this Stat can never resolve.
				error(
					`Scribe: leaderboard "{name}" Stat "{config.Stat}": `
						.. `"{tostring(statPath[i - 1])}" has no declared field "{tostring(segment)}"`,
					0
				)
			end
			if walkNode.Kind == "leaf" then
				error(
					`Scribe: leaderboard "{name}" Stat "{config.Stat}" descends through leaf field "{tostring(segment)}"`,
					0
				)
			end
			walkNode = Template.ChildSchema(walkNode, segment)
		end
		if walkNode == nil then
			-- Final-segment miss: the leaf itself is an undeclared field of a closed
			-- element shape.
			error(
				`Scribe: leaderboard "{name}" Stat "{config.Stat}": `
					.. `no declared field "{tostring(statPath[#statPath])}"`,
				0
			)
		end
		-- A board outlives the session but a Scribe.Session field is rebuilt from its
		-- default every session, so the board would rank a default forever. A Derived
		-- field does not persist either, but is rankable when it is a pure function of
		-- fields that do, which is what OfflineComputable means.
		local derived = walkNode.Derived
		if derived ~= nil then
			if not derived.OfflineComputable then
				error(
					`Scribe: leaderboard "{name}" Stat "{config.Stat}" is a derived field that reads `
						.. "session-only state, so its value is not reproducible across sessions and a board "
						.. "cannot rank it. Derive the stat from persisted fields instead",
					0
				)
			end
		elseif walkNode.Persist == false then
			error(
				`Scribe: leaderboard "{name}" Stat "{config.Stat}" is a Scribe.Session field, which never `
					.. "persists and resets every session, so there is nothing for a board to rank",
				0
			)
		end
		-- The score becomes the OrderedDataStore key, so a non-numeric stat has nothing
		-- to rank and the refresh cycle would silently drop it. "any" is a dynamic
		-- subtree whose type is unknowable at boot, so it stays allowed.
		local statType = walkNode.ValueType
		if statType ~= "number" and statType ~= "int" and statType ~= "big" and statType ~= "any" then
			error(
				`Scribe: leaderboard "{name}" Stat "{config.Stat}" is a {tostring(statType)} field; a Stat must `
					.. "resolve to a number, a Scribe.Int, or a Scribe.Big",
				0
			)
		end
		if config.Replicate == true and walkNode ~= nil and walkNode.ValueType == "big" then
			-- The board frame writes each Score as an f64 and a big Score is a table.
			-- Sending one throws inside broadcastBoard, under the inbound frame pcall
			-- during a client Hello, breaking that player's handshake. Refuse at boot.
			error(
				`Scribe: leaderboard "{name}" Stat "{config.Stat}" is a Scribe.Big, which cannot be `
					.. "replicated yet; read it on the server with GetLeaderboard or OnLeaderboard",
				0
			)
		end
		if config.Scale ~= nil and walkNode ~= nil and walkNode.ValueType == "big" then
			error(
				`Scribe: leaderboard "{name}" Stat "{config.Stat}" is a Scribe.Big; Scale does not apply, `
					.. "because the exponent packing already maps it into the key space",
				0
			)
		end
		-- Scale multiplies into the stored integer and divides back out on read, so a zero
		-- serves NaN, a negative inverts the ordering against the descending query, and a
		-- non-finite makes every write a guaranteed rejection.
		if config.Scale ~= nil then
			local scale = config.Scale
			if type(scale) ~= "number" or scale ~= scale or scale <= 0 or scale == math.huge then
				error(`Scribe: leaderboard "{name}" Scale must be a finite number greater than 0`, 0)
			end
		end
		local isBig = walkNode ~= nil and walkNode.ValueType == "big"
		local sigFigs = BIG_DEFAULT_SIG_FIGS
		if config.SigFigs ~= nil then
			-- SigFigs is the big packing's dial; on a plain numeric stat the key is the
			-- value and Scale is the dial, so accepting SigFigs there would do nothing.
			if not isBig then
				error(
					`Scribe: leaderboard "{name}" Stat "{config.Stat}" is not a Scribe.Big; SigFigs only applies `
						.. "to the big exponent packing. Use Scale to control a plain numeric stat's resolution",
					0
				)
			end
			local requested = config.SigFigs
			if
				type(requested) ~= "number"
				or requested % 1 ~= 0
				or requested < BIG_MIN_SIG_FIGS
				or requested > BIG_MAX_SIG_FIGS
			then
				error(
					`Scribe: leaderboard "{name}" SigFigs must be a whole number from {BIG_MIN_SIG_FIGS} to `
						.. `{BIG_MAX_SIG_FIGS}, got {tostring(requested)}`,
					0
				)
			end
			sigFigs = requested
		end
		local bigStride = 10 ^ sigFigs
		-- No boot warning for a narrowed exponent range: LB_SCORE_OUT_OF_RANGE names the
		-- cap and its SigFigs when a score is actually dropped, which is when it matters.
		local maxExponent = bigMaxExponent(bigStride)
		-- Clamped up rather than rejected so an existing config keeps working, but the
		-- clamp is reported: silently running slower than asked is its own bug.
		local refreshInterval = REFRESH_INTERVAL
		if config.RefreshInterval ~= nil then
			local requested = config.RefreshInterval
			if type(requested) ~= "number" or requested ~= requested or requested <= 0 then
				error(`Scribe: leaderboard "{name}" RefreshInterval must be a positive number of seconds`, 0)
			end
			refreshInterval = math.max(requested, MIN_REFRESH_INTERVAL)
			if refreshInterval ~= requested then
				Log.Warn(
					"Leaderboards",
					"LB_INTERVAL_CLAMPED",
					`leaderboard "{name}" RefreshInterval {requested}s is below the {MIN_REFRESH_INTERVAL}s floor and was clamped. `
						.. "A sub-minute board is usually an in-server scoreboard, which belongs in Scribe.Shared (no DataStore cost).",
					{ Board = name, Requested = requested, Applied = refreshInterval }
				)
			end
		end
		boards[name] = {
			Name = name,
			RefreshInterval = refreshInterval,
			StatPath = Util.parsePath(config.Stat),
			Limit = math.clamp(config.Limit or 100, 1, 100),
			Scale = config.Scale or 1,
			-- Resolved at boot from the stat's schema, so the write path never re-walks it.
			IsBig = isBig,
			BigSigFigs = sigFigs,
			BigStride = bigStride,
			BigMantissaScale = bigStride / 10,
			BigMaxExponent = maxExponent,
			Replicate = config.Replicate == true,
			-- SigFigs is in the store name: big and plain keys are different layouts, so
			-- sharing `LB_<name>` would silently reinterpret every key already written
			-- when a stat is retyped or its SigFigs change, with no repair pass able to
			-- separate the two formats afterwards. An explicit StoreName still wins.
			StoreName = if type(config.StoreName) == "string"
				then config.StoreName
				elseif isBig then `LB_{name}_big{sigFigs}`
				else `LB_{name}`,
			Cache = { Entries = {}, At = 0 },
			Signature = "",
			MyRanks = {},
			MyScores = {},
			SentState = {},
		}
	end

	-- Aggregate budget guard: fail at boot rather than as mystery throttling in production.
	do
		local perMinute = 0
		for _, board in boards do
			perMinute += 60 / board.RefreshInterval
		end
		if perMinute > MAX_REFRESH_PER_MINUTE then
			error(
				`Scribe: leaderboards would issue {string.format("%.1f", perMinute)} GetSortedAsync reads per minute `
					.. `across {Util.count(boards)} board(s), over the {MAX_REFRESH_PER_MINUTE}/min guard. `
					.. "Raise RefreshInterval on some boards, or declare fewer of them.",
				0
			)
		end
	end

	-- Sizes the GetSortedAsync reserve in Persistence. Zero boards must reserve nothing.
	self.BoardCount = Util.count(boards)

	local function orderedStore(name: string): any
		if useMock then
			local mock = mockStores[name]
			if not mock then
				mock = newMockOrderedStore()
				mockStores[name] = mock
			end
			return mock
		end
		local store = storeCache[name]
		if not store then
			store = DataStoreService:GetOrderedDataStore(name)
			storeCache[name] = store
		end
		return store
	end

	local function packBig(board: Board, value: any): number?
		local big = Big.from(value)
		if big == nil then
			return nil
		end
		if big.M == 0 then
			-- Below every representable key, not 0: a value in (0, 1) has a negative
			-- exponent and so a negative key, which a zero mapped to 0 would outrank.
			return -board.BigMaxExponent * board.BigStride
		end
		-- The packing has no room for a sign, and mis-ranking negatives is worse than
		-- refusing them.
		if big.M < 0 or math.abs(big.E) > board.BigMaxExponent then
			return nil
		end
		return big.E * board.BigStride + math.floor(big.M * board.BigMantissaScale)
	end

	-- Copy a handed-out entry, since the caller may keep or mutate it. table.clone is
	-- shallow, so a big Score would still alias the cache; rebuild the big instead.
	local function copyEntry(board: Board, item: any): any
		local copy = table.clone(item)
		if board.IsBig and copy.Score ~= nil then
			copy.Score = Big.from(copy.Score)
		end
		return copy
	end

	-- A player's current value for a board's Stat. Reads through the accessor tree,
	-- the only view that sees Session and Derived fields; LiveData is the persisted
	-- store alone, and is the fallback when teardown races the leave flush.
	local function readStat(entry: any, board: Board): any
		local tree = entry.Tree
		if tree ~= nil and not tree.Dead then
			local ok, value = pcall(function()
				local accessor = tree.Accessor
				for _, segment in board.StatPath do
					accessor = accessor[segment]
				end
				return accessor.Get()
			end)
			if ok then
				return value
			end
		end
		local value: any = entry.LiveData
		for _, segment in board.StatPath do
			value = if type(value) == "table" then value[segment] else nil
		end
		return value
	end

	local function unpackBig(board: Board, key: number): any
		local stride = board.BigStride
		-- The zero sentinel, plus the legacy 0 that boards written before it used.
		if key == 0 or key <= -board.BigMaxExponent * stride then
			return Big.from(0)
		end
		-- The division cannot round up into the next exponent, which would decode the
		-- score at the wrong magnitude: that needs e * stride >= 2^53, and
		-- bigMaxExponent caps e strictly below it. Widening that cap breaks this.
		local exponent = math.floor(key / stride)
		return Big.normalize((key - exponent * stride) / board.BigMantissaScale, exponent)
	end

	-- Write queue ------------------------------------------------------------------

	function self.Enqueue(board: Board, userId: number, score: any)
		if isErased(userId) then
			return -- within the GDPR tombstone window; do not re-add
		end
		local scaled: number
		if board.IsBig then
			-- Scale does not apply: the packing is the mapping into the key space.
			local packed = packBig(board, score)
			if packed == nil then
				Metrics.Add("LbScoreOutOfRange")
				Log.Warn(
					"Leaderboards",
					"LB_SCORE_OUT_OF_RANGE",
					`big score cannot be ranked (negative, or exponent past {board.BigMaxExponent} at SigFigs `
						.. `{board.BigSigFigs}); not written`,
					{ Board = board.Name, UserId = userId }
				)
				return
			end
			scaled = packed
		else
			if type(score) ~= "number" or score ~= score then
				return
			end
			scaled = math.floor(score * board.Scale + 0.5)
		end
		-- A scaled value outside the exact integer range is rejected by SetAsync every
		-- time and re-enqueued on every Changed, so it becomes a permanent failure stream.
		if scaled ~= scaled or math.abs(scaled) > 9007199254740992 then
			Metrics.Add("LbScoreOutOfRange")
			Log.Warn(
				"Leaderboards",
				"LB_SCORE_OUT_OF_RANGE",
				`score {tostring(score)} x Scale {board.Scale} is outside the exact integer range (2^53); not written`,
				{ Board = board.Name, UserId = userId }
			)
			return
		end
		local key = `{board.Name}|{userId}`
		local existing = writeQueueMap[key]
		if existing then
			-- Dedup by (board, userId), keeping only the latest value.
			existing.Score = scaled
			return
		end
		if #writeQueue >= QUEUE_CAP then
			local dropped = table.remove(writeQueue, 1)
			if dropped then
				writeQueueMap[`{dropped.Board.Name}|{dropped.UserId}`] = nil
			end
			Metrics.Add("LbQueueOverflow")
			overflowSinceLog += 1
			local now = Clock.Monotonic()
			if lastOverflowLog == nil or now - lastOverflowLog >= OVERFLOW_LOG_INTERVAL then
				lastOverflowLog = now
				Log.Warn(
					"Leaderboards",
					"LB_QUEUE_OVERFLOW",
					`write queue overflow; dropped the oldest entry ({overflowSinceLog} drop(s) since the last of these). `
						.. "Scores are being produced faster than the write pacer drains them",
					{ Dropped = overflowSinceLog, Depth = #writeQueue }
				)
				overflowSinceLog = 0
			end
		end
		local item = { Board = board, UserId = userId, Score = scaled, Attempts = 0 }
		table.insert(writeQueue, item)
		writeQueueMap[key] = item
		Metrics.Set("LbQueueDepth", #writeQueue)
	end

	local function performWrite(item: { Board: Board, UserId: number, Score: number, Attempts: number }): boolean
		local board = item.Board
		local ok, err = pcall(function()
			orderedStore(board.StoreName):SetAsync(tostring(item.UserId), item.Score)
		end)
		if ok then
			Metrics.Add("LbWrites")
		else
			-- Deliberately not Health.ReportFailure: board writes are routinely throttled
			-- under load, and the shared health budget would flip global status to Outage
			-- and block Robux receipts. LbWriteFailures and LB_WRITE_FAIL signal instead.
			Metrics.Add("LbWriteFailures")
			reportStoreFailure("LB_WRITE_FAIL", err, {
				Board = board.Name,
				UserId = item.UserId,
				Score = item.Score,
			})
		end
		return ok
	end

	-- Should a deferrable background request wait for allowance? Returns the reading
	-- alongside the verdict, since two queries in one tick can disagree. A `nil` from
	-- Budget.Remaining means the engine could not be asked, not an empty allowance;
	-- reading it as exhausted would park both loops for the life of the process.
	local function shouldDefer(requestType: string, what: string): (boolean, number?)
		if not budgetPolicy then
			return false, nil
		end
		local remaining = Budget.Remaining(requestType)
		if remaining == nil or remaining > BUDGET_RESERVE then
			return false, remaining
		end
		Metrics.Add("LbBudgetDeferred")
		local now = Clock.Monotonic()
		if lastBudgetLog == nil or now - lastBudgetLog >= BUDGET_LOG_INTERVAL then
			lastBudgetLog = now
			Log.Warn(
				"Leaderboards",
				"LB_BUDGET_DEFERRED",
				`{what} is waiting on the {requestType} request budget ({remaining} left). `
					.. "Nothing is dropped -- writes stay queued and refreshes retry on the next tick -- but "
					.. "boards update more slowly while this lasts",
				{ RequestType = requestType, Remaining = remaining }
			)
		end
		return true, remaining
	end

	-- How many queued writes one tick may drain: one, unless the queue has backed up and
	-- the engine reports allowance to spare. With no backlog the pacer keeps its dedup
	-- window, which collapses a burst of score changes into a single write.
	local function drainAllowance(remaining: number?): number
		-- nil is "could not ask" and infinity is "no meaningful limit"; neither is licence
		-- to drain faster. A simulation with budgets disabled answers infinity.
		if remaining == nil or remaining == math.huge then
			return 1
		end
		local spare = math.floor(remaining) - BUDGET_RESERVE
		if spare <= 1 then
			return 1
		end
		-- Bounding by the current queue length keeps a failed write's retries spaced: a
		-- failure re-inserts at the tail, behind everything this tick would drain anyway.
		-- Without it one tick burns all three attempts and abandons the item.
		return math.min(MAX_WRITES_PER_TICK, spare, #writeQueue)
	end

	local function writePacerLoop()
		-- Its own long-lived thread, so what it allocates is attributable. Scribe's own
		-- background work only: an accessor write runs on the game's calling thread and
		-- stays under the game's category.
		Profile.MemoryCategory("Scribe")
		while not stopped do
			-- Jittered above the gate and the dequeue, so it only moves when the tick
			-- happens, never whether a queued write survives it.
			Clock.Wait(Rng.Jitter(WRITE_INTERVAL))
			-- Gated before the dequeue: below the table.remove the item is already out
			-- of the queue, so deferring there would drop the write, not postpone it.
			local defer, remaining = shouldDefer("SetIncrementSortedAsync", "the leaderboard write queue")
			if defer then
				continue
			end
			-- Bounded drain rather than a fixed one per tick, so `continue` below skips
			-- one item rather than a whole tick.
			for _ = 1, drainAllowance(remaining) do
				if stopped then
					break
				end
				local item = table.remove(writeQueue, 1)
				if item == nil then
					break
				end
				local key = `{item.Board.Name}|{item.UserId}`
				writeQueueMap[key] = nil
				Metrics.Set("LbQueueDepth", #writeQueue)
				-- A user erased since this item was dequeued must not be written back into
				-- the OrderedDataStore we just RemoveAsync'd.
				if isErased(item.UserId) then
					continue
				end
				local wrote = performWrite(item)
				-- SetAsync yields, so an EraseUser during it would have been resurrected
				-- by this write. Undo just this board's write so the erase holds.
				if wrote and isErased(item.UserId) then
					pcall(function()
						orderedStore(item.Board.StoreName):RemoveAsync(tostring(item.UserId))
					end)
					continue
				end
				if not wrote then
					item.Attempts += 1
					-- Only requeue if no newer value for this key arrived during
					-- the SetAsync yield (dedup) and the user was not erased.
					if item.Attempts < 3 and writeQueueMap[key] == nil and not isErased(item.UserId) then
						table.insert(writeQueue, item)
						writeQueueMap[key] = item
					elseif item.Attempts >= 3 and writeQueueMap[key] == nil then
						reportStoreFailure("LB_WRITE_DROPPED", "leaderboard write abandoned after retries", {
							Board = item.Board.Name,
							UserId = item.UserId,
							Score = item.Score,
						})
					end
				end
			end
		end
	end

	-- Reads + refresh cycle -----------------------------------------------------------

	-- Cache a resolved name, dropping TTL-lapsed entries once the map fills. Unbounded it
	-- grows one entry per distinct userId ever seen in a top-N, for the server's lifetime.
	local nameCacheCount = 0
	local function cacheName(userId: number, entry: { Name: string?, At: number })
		if nameCache[userId] == nil then
			nameCacheCount += 1
		end
		nameCache[userId] = entry
		if nameCacheCount >= NAME_CACHE_CAP then
			local now = Clock.Monotonic()
			local kept = 0
			for id, c in nameCache do
				local ttl = if c.Name then NAME_TTL else NAME_NEGATIVE_TTL
				if now - c.At >= ttl then
					nameCache[id] = nil
				else
					kept += 1
				end
			end
			nameCacheCount = kept
			-- TTL eviction alone does not bound the map when every entry is still fresh, so
			-- drop the oldest down to half the cap, amortizing this sort over cap/2 inserts.
			if nameCacheCount >= NAME_CACHE_CAP then
				local ordered: { { Id: number, At: number } } = {}
				for id, c in nameCache do
					table.insert(ordered, { Id = id, At = c.At })
				end
				table.sort(ordered, function(a: { Id: number, At: number }, b: { Id: number, At: number })
					return a.At < b.At
				end)
				local target = NAME_CACHE_CAP // 2
				for i = 1, #ordered - target do
					nameCache[ordered[i].Id] = nil
				end
				nameCacheCount = target
			end
		end
	end

	local function resolveName(userId: number): string
		local cached = nameCache[userId]
		local now = Clock.Monotonic()
		if cached then
			local ttl = if cached.Name then NAME_TTL else NAME_NEGATIVE_TTL
			if now - cached.At < ttl then
				return cached.Name or "Unknown"
			end
		end
		local player = Players:GetPlayerByUserId(userId)
		if player then
			cacheName(userId, { Name = player.Name, At = now })
			return player.Name
		end
		local ok, name = pcall(function()
			return Players:GetNameFromUserIdAsync(userId)
		end)
		-- Negative caching: failed lookups are cached briefly.
		cacheName(userId, { Name = if ok then name else nil, At = now })
		return if ok then name else "Unknown"
	end

	local function sendBoardTo(board: Board, entry: any)
		local w = Wire.NewWriter(64 + #board.Cache.Entries * 32)
		Wire.U8(w, Wire.Frames.Leaderboard)
		Wire.Str(w, board.Name)
		Wire.U8(w, #board.Cache.Entries)
		for _, item in board.Cache.Entries do
			Wire.F64(w, item.UserId)
			Wire.Str(w, item.Name)
			Wire.F64(w, item.Score)
		end
		local myRank = board.MyRanks[entry.UserId]
		local myScore = board.MyScores[entry.UserId]
		if myRank and myScore then
			Wire.U8(w, 1)
			Wire.Varint(w, myRank)
			Wire.F64(w, myScore)
		else
			Wire.U8(w, 0)
		end
		-- Only stamp what actually left: SentState is broadcastBoard's dedup key, so a
		-- refused board recorded as delivered is not resent until its content changes.
		if ctx.Replication.SendTo(entry, Wire.Finish(w)) then
			board.SentState[entry.UserId] = { Sig = board.Signature, Rank = myRank, Score = myScore }
		end
	end

	-- Change-driven: a client only receives the board when its content or their
	-- own rank/score differs from what they were last sent.
	local function broadcastBoard(board: Board)
		if not board.Replicate then
			return
		end
		for _, entry in ctx.Persistence.Entries do
			if not entry.HandshakeReady then
				continue
			end
			local sent = board.SentState[entry.UserId]
			if
				sent == nil
				or sent.Sig ~= board.Signature
				or sent.Rank ~= board.MyRanks[entry.UserId]
				or sent.Score ~= board.MyScores[entry.UserId]
			then
				sendBoardTo(board, entry)
			end
		end
	end

	local function refreshBoard(board: Board)
		local ok, page = pcall(function()
			return orderedStore(board.StoreName):GetSortedAsync(false, board.Limit)
		end)
		if not ok then
			-- As in performWrite: a throttled read must not drive the global health gate.
			Metrics.Add("LbReadFailures")
			reportStoreFailure("LB_READ_FAIL", page, { Board = board.Name })
			return
		end

		local entries = {}
		local rankByUserId: { [number]: number } = {}
		local signatureParts = {}
		for rank, item in page:GetCurrentPage() do
			local userId = tonumber(item.key) or 0
			local score: any = if board.IsBig then unpackBig(board, item.value) else item.value / board.Scale
			rankByUserId[userId] = rank
			table.insert(entries, {
				Rank = rank,
				UserId = userId,
				Name = resolveName(userId),
				Score = score,
			})
			table.insert(signatureParts, `{userId}:{score}`)
		end
		board.Cache = { Entries = entries, At = Clock.Monotonic() }
		local previousSignature = board.Signature
		board.Signature = table.concat(signatureParts, "|")

		-- Fire before broadcastBoard, which returns immediately for a non-replicated
		-- board: server-only is the default and those would have no other way to observe
		-- a refresh. Cloned so a listener cannot mutate what every later read serves.
		if board.Signature ~= previousSignature then
			local snapshot = table.create(#board.Cache.Entries)
			for _, item in board.Cache.Entries do
				table.insert(snapshot, copyEntry(board, item))
			end
			ctx.Signals.OnLeaderboard:Fire(board.Name, snapshot)
		end

		-- Each online player's own rank/score, computed on the refresh cycle.
		for _, entry in ctx.Persistence.Entries do
			if entry.State == "Ready" and entry.LiveData then
				local value: any = readStat(entry, board)
				board.MyScores[entry.UserId] = if board.IsBig or type(value) == "number" then value else nil
				board.MyRanks[entry.UserId] = rankByUserId[entry.UserId]
			end
		end

		broadcastBoard(board)
	end

	-- Due-time scheduler: each board on its own cadence, with the initial due times
	-- staggered across the first cycle so boot does not fire every board at once.
	local function refreshLoop()
		-- Attributes this loop's allocations to Scribe, as in writePacerLoop.
		Profile.MemoryCategory("Scribe")
		-- The jittered warm-up spreads the first refresh across a fleet booted by one
		-- deploy; the stagger below spreads boards within one server. Both are needed,
		-- and replacing the stagger with jitter would re-collide a server's own boards.
		Clock.Wait(Rng.Jitter(5))
		local dueAt: { [string]: number } = {}
		local index = 0
		local count = math.max(Util.count(boards), 1)
		for boardName, board in boards do
			dueAt[boardName] = Clock.Monotonic() + (board.RefreshInterval * index) / count
			index += 1
		end
		while not stopped do
			local now = Clock.Monotonic()
			for boardName, board in boards do
				local due = dueAt[boardName]
				if due == nil or now >= due then
					-- Gated before dueAt is advanced: below that line a deferral costs a
					-- whole RefreshInterval instead of one tick.
					if shouldDefer("GetSortedAsync", `refreshing board "{boardName}"`) then
						continue
					end
					dueAt[boardName] = now + board.RefreshInterval
					Sched.Spawn(refreshBoard, board)
				end
			end
			-- One draw per tick, not per re-arm. Drawing inside the board loop above would
			-- make the sequence depend on `boards` hash order, and jittering the tick
			-- decorrelates the re-arm anyway: `dueAt` inherits the drift in `now`.
			Clock.Wait(Rng.Jitter(1))
		end
	end

	-- Called by Server.build once the full ctx is assembled, so neither loop ever runs
	-- against a half-constructed context.
	function self.Start()
		pacerThread = Sched.Spawn(writePacerLoop)
		refreshThread = Sched.Spawn(refreshLoop)
	end

	-- Release both loops. Cancelled as well as flagged, because a parked loop would
	-- otherwise keep a thread alive per bundle until its next wake.
	function self.Stop()
		if stopped then
			return
		end
		stopped = true
		for _, thread in { pacerThread, refreshThread } do
			pcall(task.cancel, thread)
		end
		pacerThread, refreshThread = nil, nil
	end

	-- The OrderedDataStore a board reads and writes. Exposed so a test can pin the
	-- SigFigs namespacing, which is what keeps two key formats out of one store.
	function self.BoardStoreName(name: string): string?
		local board = boards[name]
		return if board then board.StoreName else nil
	end

	-- Whether boards resolved to the in-memory mock store. Exposed so a test can assert
	-- Leaderboards read the resolved Mode; board contents cannot, since a real store only
	-- happens to fail under the headless runner and in Studio the write lands.
	self.UsesMockStore = useMock

	--- The mock ordered store behind a board, so a test can make its calls fail. Mock
	--- mode only: nil on a real store, which no test may reach.
	function self.MockStoreFor(name: string): any?
		if not useMock then
			return nil
		end
		local storeName = self.BoardStoreName(name)
		return if storeName then orderedStore(storeName) else nil
	end

	function self.RefreshNow(name: string?)
		if name then
			local board = boards[name]
			if board then
				refreshBoard(board)
			end
			return
		end
		for _, board in boards do
			refreshBoard(board)
		end
	end

	-- Called by Replication when a client completes the handshake: hand them
	-- the current cached replicated boards once, then only changes are broadcast.
	function self.OnClientReady(entry: any)
		for _, board in boards do
			if board.Replicate and board.Cache.At > 0 then
				sendBoardTo(board, entry)
			end
		end
	end

	-- Player lifecycle ------------------------------------------------------------------

	function self.OnLoad(entry: any)
		local disconnects = {}
		for _, board in boards do
			-- Per-board isolation: one board's path failing at runtime must not kill
			-- the wiring of every remaining board for the whole session.
			local ok, err = pcall(function()
				local accessor = entry.Tree.Accessor
				for _, segment in board.StatPath do
					accessor = accessor[segment]
				end
				local value = accessor.Get()
				if board.IsBig or type(value) == "number" then
					self.Enqueue(board, entry.UserId, value)
				end
				table.insert(
					disconnects,
					-- Parenthesised to truncate the call to one value: `Changed` returns
					-- exactly one, the disconnect closure, but the accessor is `any`, so
					-- the solver sees a variadic tail and cannot pick a table.insert
					-- overload.
					(
						accessor.Changed(function(newValue: any)
							if board.IsBig or type(newValue) == "number" then
								self.Enqueue(board, entry.UserId, newValue)
							end
						end)
					)
				)
			end)
			if not ok then
				Log.Warn(
					"Leaderboards",
					"LB_STAT_RESOLVE_FAIL",
					`board "{board.Name}" stat did not resolve for this player: {tostring(err)}`,
					{ Board = board.Name, UserId = entry.UserId }
				)
			end
		end
		statDisconnects[entry] = disconnects
	end

	function self.OnUnload(entry: any)
		local disconnects = statDisconnects[entry]
		if disconnects then
			statDisconnects[entry] = nil
			for _, disconnect in disconnects do
				disconnect()
			end
		end
		-- Only if this is still the live entry for that user id. TargetUserId points every
		-- session at one profile, so two entries can share an id and either leaving would
		-- blank the other's. EntriesByUserId still points here when teardown calls in.
		if ctx.Persistence.EntriesByUserId[entry.UserId] == entry then
			for _, board in boards do
				board.MyRanks[entry.UserId] = nil
				board.MyScores[entry.UserId] = nil
				board.SentState[entry.UserId] = nil
			end
		end
		-- Flush the player's latest scores on leave.
		if entry.LiveData then
			for _, board in boards do
				local value: any = readStat(entry, board)
				if board.IsBig or type(value) == "number" then
					self.Enqueue(board, entry.UserId, value)
				end
			end
		end
	end

	-- Public API --------------------------------------------------------------------------

	-- Names are case-sensitive and an unknown one returns empty with no other signal, so a
	-- typo looks like a board that has not refreshed. Warn once per name in Studio.
	local warnedBoardNames: { [string]: boolean } = {}
	local function checkBoardName(name: string, caller: string)
		if ctx.DevMode and not boards[name] and not warnedBoardNames[name] then
			warnedBoardNames[name] = true
			Log.Warn(
				"Leaderboards",
				"LB_UNKNOWN_BOARD",
				`{caller}("{name}"): no board named "{name}" is declared in the Leaderboards option (names are case-sensitive); this always returns nothing`,
				{ Board = name }
			)
		end
	end

	function self.GetLeaderboard(name: string, limit: number?): { any }
		local board = boards[name]
		if not board then
			checkBoardName(name, "GetLeaderboard")
			return {}
		end
		local out = {}
		for i = 1, math.min(limit or board.Limit, #board.Cache.Entries) do
			table.insert(out, copyEntry(board, board.Cache.Entries[i]))
		end
		return out
	end

	function self.GetMyRank(player: Player, name: string): number?
		local board = boards[name]
		local entry = ctx.Persistence.Entries[player]
		if not board then
			checkBoardName(name, "GetMyRank")
		end
		if not board or not entry then
			return nil
		end
		return board.MyRanks[entry.UserId]
	end

	-- Drain the whole queue synchronously within a deadline.
	function self.FlushAllBlocking(budget: number)
		local deadline = Clock.Monotonic() + budget
		local flushed = 0
		while Clock.Monotonic() < deadline do
			local item = table.remove(writeQueue, 1)
			if not item then
				break
			end
			writeQueueMap[`{item.Board.Name}|{item.UserId}`] = nil
			flushed += 1
			-- Mirror the pacer's GDPR guard: skip an erased user, and undo a write whose
			-- SetAsync yield raced a concurrent EraseUser.
			if isErased(item.UserId) then
				continue
			end
			local wrote = performWrite(item)
			if wrote and isErased(item.UserId) then
				pcall(function()
					orderedStore(item.Board.StoreName):RemoveAsync(tostring(item.UserId))
				end)
			end
		end
		Log.Info("Leaderboards", "LB_SHUTDOWN_FLUSH", "leaderboard queue drained on shutdown", {
			Flushed = flushed,
			Remaining = #writeQueue,
		})
	end

	-- GDPR: remove the user from every board. Returns (ok, err); a false ok
	-- means at least one board's RemoveAsync failed and the caller must retry.
	function self.EraseUser(userId: number): (boolean, string?)
		-- Tombstone first, so an already-dequeued pacer write cannot resurrect the score
		-- after RemoveAsync. Held long enough to outlive that write plus its retries.
		erasedUsers[userId] = Clock.Monotonic() + 300

		-- Drop any still-queued writes for this user, or the pacer would
		-- SetAsync their score back into a board we just RemoveAsync'd.
		for i = #writeQueue, 1, -1 do
			local queued = writeQueue[i]
			if queued.UserId == userId then
				writeQueueMap[`{queued.Board.Name}|{userId}`] = nil
				table.remove(writeQueue, i)
			end
		end
		Metrics.Set("LbQueueDepth", #writeQueue)

		local key = tostring(userId)
		local failed: string? = nil
		-- Reported once below rather than per board: the log folds by subject, so N
		-- per-board lines collapse into the first, losing which boards still hold the data.
		local failedBoards: { string }? = nil
		for _, board in boards do
			local ok, err = pcall(function()
				orderedStore(board.StoreName):RemoveAsync(key)
			end)
			if not ok then
				-- Attempt every board, but remember the failure so erase can't
				-- report success while personal data is retained.
				failed = tostring(err)
				failedBoards = failedBoards or {}
				table.insert(failedBoards :: { string }, board.Name)
			end
			board.MyRanks[userId] = nil
			board.MyScores[userId] = nil
			board.SentState[userId] = nil
			-- Drop the erased user from the in-memory cache too, so nothing is served or
			-- pushed to a client completing the handshake before the next refreshBoard.
			local entries = board.Cache.Entries
			local pruned = false
			for i = #entries, 1, -1 do
				if entries[i].UserId == userId then
					table.remove(entries, i)
					pruned = true
				end
			end
			if pruned then
				-- Renumber so GetLeaderboard serves contiguous ranks until the next refresh,
				-- then recompute the signature so stale SentState cannot suppress the update.
				local signatureParts = {}
				for i, item in entries do
					item.Rank = i
					table.insert(signatureParts, `{item.UserId}:{item.Score}`)
				end
				board.Signature = table.concat(signatureParts, "|")
				-- The signature only makes the change eligible to send; without this
				-- call clients keep rendering the erased user until the next refresh.
				broadcastBoard(board)
			end
		end
		if failedBoards ~= nil then
			-- Board names as a string, not an array: Log trims an oversized context down
			-- to its scalar fields, so an array is the first thing dropped.
			Failure.Report({
				Subsystem = "Leaderboards",
				Key = tostring(userId),
				Error = failed,
				Level = "Error",
				Category = "Leaderboards",
				Code = "LB_ERASE_FAIL",
				Message = tostring(failed),
				Context = {
					UserId = userId,
					Boards = table.concat(failedBoards :: { string }, ", "),
					BoardCount = #(failedBoards :: { string }),
				},
			})
		end
		-- Evict the resolved name so it is neither re-served nor re-broadcast.
		if nameCache[userId] ~= nil then
			nameCache[userId] = nil
			nameCacheCount -= 1
		end
		if failed then
			return false, `profile removed, but a leaderboard erase failed: {failed}`
		end
		return true, nil
	end

	return self
end

return Leaderboards
