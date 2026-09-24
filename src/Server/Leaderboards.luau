--!strict
-- Global all-time leaderboards on OrderedDataStore: paced deduplicated write
-- queue, cached top-N reads, and per-player rank replication. Clients are
-- served from the server cache only.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local Internal = script.Parent.Parent.Internal
local Types = require(script.Parent.Parent.Types)
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
local Diagnostics = require(Internal.LeaderboardDiagnostics)

local Leaderboards = {}

local WRITE_INTERVAL = 1.5
local SCORE_WRITE_INTERVAL = 30
local RETRY_BASE = 30
local RETRY_MAX = 300
-- Ceiling on what one tick may drain once the queue has backed up. Every write
-- yields, so an unbounded drain turns the pacer into the unpaced flush it prevents.
local MAX_WRITES_PER_TICK = 8
local REFRESH_INTERVAL = 60
-- Floor on a per-board RefreshInterval. GetSortedAsync's request budget scales with
-- player count, so a near-empty server is the worst case. A sub-minute board is
-- almost always an in-server scoreboard, which belongs in Scribe.Shared at no
-- DataStore cost.
local MIN_REFRESH_INTERVAL = 60
-- A server board sorts the players here, with no store behind it.
local SERVER_REFRESH_INTERVAL = 5
local MIN_SERVER_REFRESH_INTERVAL = 1
-- Read twice after a rollover, so a late leave flush is not missed.
local PREVIOUS_READS = 2
local WEEK_DAYS = { Sunday = 0, Monday = 1, Tuesday = 2, Wednesday = 3, Thursday = 4, Friday = 5, Saturday = 6 }
local ERASE_BUDGET_TIMEOUT = 30
local ERASE_PROGRESS_EVERY = 25
-- Lease renewal interval when nothing else checkpoints; well inside Persistence's lease.
local ERASE_HEARTBEAT = 30
-- Boot guard on the aggregate rate, which is what actually burns budget: ten boards
-- at 60s cost more than one at 15s, and the flat floor above permits exactly that.
local MAX_REFRESH_PER_MINUTE = 12
local QUEUE_CAP = 1000
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
	WriteInterval: number,
	Replicate: boolean, -- default false: server-only, no client mirror
	-- The prefix; a periodic board appends the period index at write time.
	StoreName: string,
	Period: string?, -- "Daily" | "Weekly"; nil is lifetime
	Mode: string, -- "Gain" | "Peak"
	Scope: string, -- "Global" | "Server"
	CachePeriod: number?,
	PreviousCache: { Entries: { any }, Period: number }?,
	PreviousReads: number,
	Refreshing: boolean,
	RefreshPending: boolean,
	RefreshWaiters: { thread },
	Cache: { Entries: { any }, At: number },
	Signature: string, -- fingerprint of Cache.Entries; broadcasts only on change
	MyRanks: { [number]: number? },
	-- `any`, not `number`: a big board's score is the Big itself, not the packed key.
	MyScores: { [number]: any },
	SentState: { [number]: { Sig: string, Rank: number?, Score: any } },
	LastReadAt: number?,
	LastReadMono: number?,
	LastWriteAt: number?,
	LastReadError: string?,
	LastWriteError: string?,
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
	local started = false
	local unregisterDiagnostics: (() -> ())? = nil
	local pacerThread: thread? = nil
	local refreshThread: thread? = nil
	type WriteState = {
		Board: Board,
		UserId: number,
		StoreName: string,
		LastScore: number?,
		LastAttempt: number?,
		InFlight: boolean,
		Failures: number?,
		RetryAt: number?,
		RejectedScore: number?,
	}
	type QueueItem = {
		Board: Board,
		UserId: number,
		Score: number,
		StoreName: string,
		State: WriteState,
		Urgent: boolean,
	}
	local writeQueue: { QueueItem } = {}
	local writeQueueMap: { [string]: QueueItem } = {}
	local writeStates: { [number]: { [string]: WriteState } } = {}
	local activeUsers: { [number]: number } = {}
	local activeWrites = 0
	local budgetReleases: { [() -> ()]: boolean } = {}
	local pacerParked = false
	local function wakePacer()
		if pacerParked and pacerThread ~= nil and not stopped then
			pacerParked = false
			Sched.Resume(pacerThread)
		end
	end
	-- Overflow-log throttle: over cap the warn rate tracks the stat-change rate of every
	-- out-of-queue player, enough to roll the log ring. The counter still counts drops.
	local lastOverflowLog: number? = nil
	local overflowSinceLog = 0
	-- Defer enables burst draining and paced erasure; background admission is always gated.
	local budgetPolicy: boolean = options.BudgetPolicy == "Defer" and not useMock
	local lastBudgetLog: number? = nil

	-- Periods -------------------------------------------------------------------

	local periodReset = options.PeriodReset or {}
	if type(periodReset) ~= "table" then
		error("Scribe: PeriodReset must be a table", 0)
	end
	local utcOffset = periodReset.UtcOffset or 0
	if type(utcOffset) ~= "number" or utcOffset ~= utcOffset or utcOffset < -12 or utcOffset > 14 then
		error("Scribe: PeriodReset.UtcOffset must be a number of hours from -12 to 14", 0)
	end
	local weekStart = periodReset.WeekStart or "Monday"
	if WEEK_DAYS[weekStart] == nil then
		error(`Scribe: PeriodReset.WeekStart must be a day name, not "{tostring(weekStart)}"`, 0)
	end
	local offsetSeconds = utcOffset * 3600
	-- Day 0 of the epoch was a Thursday; this shift puts the chosen day at a multiple of 7.
	local weekShift = (11 - WEEK_DAYS[weekStart]) % 7

	local function currentPeriod(period: string): number
		local day = math.floor((Clock.Now() + offsetSeconds) / 86400)
		if period == "Daily" then
			return day
		end
		return math.floor((day + weekShift) / 7)
	end

	-- Never zero: at the rollover instant the next period has begun.
	local function periodEndsIn(period: string): number
		local localNow = Clock.Now() + offsetSeconds
		local day = math.floor(localNow / 86400)
		local endDay: number
		if period == "Daily" then
			endDay = day + 1
		else
			endDay = (math.floor((day + weekShift) / 7) + 1) * 7 - weekShift
		end
		return endDay * 86400 - localNow
	end

	local function storeNameForKind(board: Board, kind: string, period: number): string
		return `{board.StoreName}_{if kind == "Daily" then "d" else "w"}{period}`
	end

	local function storeNameFor(board: Board, period: number?): string
		if board.Period == nil or period == nil then
			return board.StoreName
		end
		return storeNameForKind(board, board.Period, period)
	end

	local function reservedRaw(data: { [string]: any }): { [string]: any }
		local reserved = data[Template.RESERVED_ROOT]
		if type(reserved) ~= "table" then
			reserved = {}
			data[Template.RESERVED_ROOT] = reserved
		end
		if type(reserved.Boards) ~= "table" then
			reserved.Boards = {}
		end
		return reserved
	end

	local function toStored(board: Board, value: any): any
		return if board.IsBig then Big.toStored(value) else value
	end

	local function fromStored(board: Board, stored: any): any
		return if board.IsBig then Big.from(stored) else stored
	end

	-- The gain since the period began, or the peak seen in it. The baseline lives in the
	-- profile; a stale period resets it to `old` so the first write after a rollover
	-- counts. The refresh thread passes commit = false and never writes it.
	local function periodScore(board: Board, entry: any, value: any, old: any, commit: boolean): any
		if board.Period == nil then
			return value
		end
		if entry.LiveData == nil then
			return nil
		end
		local period = currentPeriod(board.Period)
		local records = reservedRaw(entry.LiveData).Boards
		local record = records[board.Name]
		local write: any = nil
		if type(record) ~= "table" or record.P ~= period then
			local base = if old ~= nil then old else value
			if not commit then
				-- Not committing, and nothing gained yet.
				return if board.Mode == "Peak" then value elseif board.IsBig then Big.from(0) else 0
			end
			local first = if type(record) == "table" then record.First else period
			local prior = if type(record) == "table" then record.Prior else nil
			if type(record) == "table" and record.K ~= nil and record.K ~= board.Period then
				-- A period change closes the old range for the erase.
				prior = table.clone(prior or {})
				table.insert(prior, { K = record.K, First = record.First, Last = record.P })
				first = period
			end
			write = { P = period, V = toStored(board, base), First = first, K = board.Period, Prior = prior }
			record = write
		end
		local base = fromStored(board, record.V)
		local score: any
		if board.Mode == "Peak" then
			local higher = if board.IsBig then Big.compare(value, base) > 0 else value > base
			if higher then
				score = value
				if commit then
					write = {
						P = period,
						V = toStored(board, value),
						First = record.First,
						K = record.K,
						Prior = record.Prior,
					}
				end
			else
				score = base
			end
		else
			if board.IsBig then
				score = Big.sub(value, base)
				if Big.compare(score, Big.from(0)) < 0 then
					score = Big.from(0)
				end
			else
				score = math.max(0, value - base)
			end
		end
		if write ~= nil and commit then
			local tree = entry.Tree
			if tree ~= nil and not tree.Dead then
				tree.Reserved.Boards[board.Name].Set(write)
			else
				records[board.Name] = write
			end
		end
		return score
	end

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
		local scope = config.Scope or "Global"
		if scope ~= "Global" and scope ~= "Server" then
			error(`Scribe: leaderboard "{name}" Scope must be "Global" or "Server"`, 0)
		end
		local period = config.Period
		if period == "AllTime" then
			period = nil
		end
		if period ~= nil and period ~= "Daily" and period ~= "Weekly" then
			error(`Scribe: leaderboard "{name}" Period must be "Daily" or "Weekly"`, 0)
		end
		local boardMode = config.Mode or "Gain"
		if boardMode ~= "Gain" and boardMode ~= "Peak" then
			error(`Scribe: leaderboard "{name}" Mode must be "Gain" or "Peak"`, 0)
		end
		if config.Mode ~= nil and period == nil then
			error(`Scribe: leaderboard "{name}" Mode needs a Period; a lifetime board has nothing to gain over`, 0)
		end
		local isServer = scope == "Server"
		local storeName = if config.StoreName ~= nil
			then config.StoreName
			elseif isBig then `LB_{name}_big{sigFigs}`
			else `LB_{name}`
		if not isServer then
			if type(storeName) ~= "string" or #storeName == 0 then
				error(`Scribe: leaderboard "{name}" StoreName must be a non-empty string`, 0)
			end
			local longest = storeName
			if period then
				for offset = -1, 1 do
					local candidate =
						`{storeName}_{if period == "Daily" then "d" else "w"}{currentPeriod(period) + offset}`
					if #candidate > #longest then
						longest = candidate
					end
				end
			end
			if #longest > 50 then
				error(`Scribe: leaderboard "{name}" generated store name exceeds 50 bytes; shorten StoreName`, 0)
			end
		end
		local refreshInterval = if isServer then SERVER_REFRESH_INTERVAL else REFRESH_INTERVAL
		local writeInterval = if config.WriteInterval == nil then SCORE_WRITE_INTERVAL else config.WriteInterval
		if
			type(writeInterval) ~= "number"
			or writeInterval ~= writeInterval
			or writeInterval <= 0
			or writeInterval == math.huge
		then
			error(`Scribe: leaderboard "{name}" WriteInterval must be a finite positive number of seconds`, 0)
		end
		if writeInterval < 1 then
			Log.Warn(
				"Leaderboards",
				"LB_INTERVAL_CLAMPED",
				`leaderboard "{name}" WriteInterval was clamped to 1s`,
				{ Board = name, Requested = writeInterval, Applied = 1 }
			)
			writeInterval = 1
		end
		local minInterval = if isServer then MIN_SERVER_REFRESH_INTERVAL else MIN_REFRESH_INTERVAL
		if config.RefreshInterval ~= nil then
			local requested = config.RefreshInterval
			if type(requested) ~= "number" or requested ~= requested or requested <= 0 then
				error(`Scribe: leaderboard "{name}" RefreshInterval must be a positive number of seconds`, 0)
			end
			refreshInterval = math.max(requested, minInterval)
			if refreshInterval ~= requested then
				Log.Warn(
					"Leaderboards",
					"LB_INTERVAL_CLAMPED",
					`leaderboard "{name}" RefreshInterval {requested}s is below the {minInterval}s floor and was clamped. `
						.. 'A sub-minute board is usually an in-server scoreboard, which is Scope = "Server" (no DataStore cost).',
					{ Board = name, Requested = requested, Applied = refreshInterval }
				)
			end
		end
		boards[name] = {
			Name = name,
			RefreshInterval = refreshInterval,
			WriteInterval = writeInterval,
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
			Period = period,
			Mode = boardMode,
			Scope = scope,
			CachePeriod = nil,
			PreviousCache = nil,
			PreviousReads = 0,
			Refreshing = false,
			RefreshPending = false,
			RefreshWaiters = {},
			-- SigFigs is in the store name: big and plain keys are different layouts, so
			-- sharing `LB_<name>` would silently reinterpret every key already written
			-- when a stat is retyped or its SigFigs change, with no repair pass able to
			-- separate the two formats afterwards. An explicit StoreName still wins.
			StoreName = storeName,
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
			if board.Scope ~= "Server" then
				perMinute += 60 / board.RefreshInterval
			end
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

	-- Sizes the GetSortedAsync reserve in Persistence; a server board never reads a store.
	self.BoardCount = 0
	for _, board in boards do
		if board.Scope ~= "Server" then
			self.BoardCount += 1
		end
	end

	local function orderedStore(name: string): any
		if #name == 0 or #name > 50 then
			error("101: leaderboard store name must be between 1 and 50 bytes", 0)
		end
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

	local function writeKey(board: Board, userId: number, storeName: string): string
		return `{board.Name}|{userId}|{storeName}`
	end

	local function releaseWriteState(state: WriteState)
		local key = writeKey(state.Board, state.UserId, state.StoreName)
		if state.InFlight or writeQueueMap[key] ~= nil then
			return
		end
		local currentStore =
			storeNameFor(state.Board, if state.Board.Period then currentPeriod(state.Board.Period) else nil)
		if not stopped and (activeUsers[state.UserId] or 0) > 0 and state.StoreName == currentStore then
			return
		end
		local states = writeStates[state.UserId]
		if states and states[key] == state then
			states[key] = nil
			if next(states) == nil then
				writeStates[state.UserId] = nil
			end
		end
	end

	local function queueWrite(item: QueueItem)
		while #writeQueue >= QUEUE_CAP do
			local dropped = table.remove(writeQueue, 1)
			if dropped then
				writeQueueMap[writeKey(dropped.Board, dropped.UserId, dropped.StoreName)] = nil
				releaseWriteState(dropped.State)
			end
			Metrics.Add("LbQueueOverflow")
			overflowSinceLog += 1
		end
		if overflowSinceLog > 0 then
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
		table.insert(writeQueue, item)
		writeQueueMap[writeKey(item.Board, item.UserId, item.StoreName)] = item
		Metrics.Set("LbQueueDepth", #writeQueue)
		wakePacer()
	end

	function self.Enqueue(board: Board, entry: any, value: any, old: any?, urgent: boolean?)
		local userId: number = entry.UserId
		if isErased(userId) then
			return -- within the GDPR tombstone window; do not re-add
		end
		local score = periodScore(board, entry, value, old, true)
		if score == nil or board.Scope == "Server" then
			return -- a server board is rebuilt from live entries on refresh
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
		-- Resolved now and in the dedup key: a score drains to the period it was computed
		-- for, and a new period's score never overwrites an old one.
		local storeName = storeNameFor(board, if board.Period then currentPeriod(board.Period) else nil)
		local key = writeKey(board, userId, storeName)
		local states = writeStates[userId]
		if board.Period ~= nil and states ~= nil and states[key] == nil then
			-- Drop finished history from older periods.
			for _, state in states do
				if state.Board == board then
					releaseWriteState(state)
				end
			end
		end
		states = writeStates[userId]
		if states == nil then
			states = {}
			writeStates[userId] = states
		end
		local state: WriteState = states[key]
			or { Board = board, UserId = userId, StoreName = storeName, InFlight = false }
		states[key] = state
		if state.RejectedScore ~= nil then
			if state.RejectedScore == scaled then
				return
			end
			state.RejectedScore, state.Failures, state.RetryAt = nil, nil, nil
		end
		local existing = writeQueueMap[key]
		if existing then
			-- Dedup by (board, userId), keeping only the latest value.
			existing.Score = scaled
			existing.Urgent = existing.Urgent or urgent == true
			return
		end
		-- Keep changes queued until the in-flight write settles.
		if not state.InFlight and state.LastScore == scaled then
			Metrics.Add("LbWritesSkipped")
			releaseWriteState(state)
			return
		end
		local item: QueueItem = {
			Board = board,
			UserId = userId,
			Score = scaled,
			StoreName = storeName,
			State = state,
			Urgent = urgent == true,
		}
		queueWrite(item)
	end

	local function performWrite(item: QueueItem): (boolean, boolean)
		local board = item.Board
		local ok, err = pcall(function()
			orderedStore(item.StoreName):SetAsync(tostring(item.UserId), item.Score)
		end)
		if ok then
			Metrics.Add("LbWrites")
			board.LastWriteAt = Clock.Now()
			board.LastWriteError = nil
		else
			-- Deliberately not Health.ReportFailure: board writes are routinely throttled
			-- under load, and the shared health budget would flip global status to Outage
			-- and block Robux receipts. LbWriteFailures and LB_WRITE_FAIL signal instead.
			Metrics.Add("LbWriteFailures")
			board.LastWriteError = tostring(err)
			reportStoreFailure("LB_WRITE_FAIL", err, {
				Board = board.Name,
				UserId = item.UserId,
				Score = item.Score,
			})
		end
		return ok, not ok and (Failure.Classify(err) == "Rejected" or isStudioApiDisabled(tostring(err)))
	end

	local function claimBackground(requestType: string): (boolean, () -> ())
		if useMock then
			return true, function() end
		end
		local granted, free = Budget.TryBackground(requestType)
		if granted then
			local release: () -> ()
			release = function()
				if budgetReleases[release] then
					budgetReleases[release] = nil
					free()
				end
			end
			budgetReleases[release] = true
			return true, release
		end
		Metrics.Add("LbBudgetDeferred")
		local now = Clock.Monotonic()
		if lastBudgetLog == nil or now - lastBudgetLog >= BUDGET_LOG_INTERVAL then
			lastBudgetLog = now
			Log.Warn(
				"Leaderboards",
				"LB_BUDGET_DEFERRED",
				`leaderboard work is waiting for its share of the {requestType} request budget; boards update more slowly while this lasts`,
				{ RequestType = requestType }
			)
		end
		return false, free
	end

	-- Skip cooling or in-flight keys so other scores can progress.
	local function nextWrite(ignoreInterval: boolean, attempted: { [WriteState]: boolean }?): (number?, QueueItem?)
		local now = Clock.Monotonic()
		for index, item in writeQueue do
			local state = item.State
			if
				not state.InFlight
				and not (attempted and attempted[state])
				and (ignoreInterval or state.RetryAt == nil or now >= state.RetryAt)
				and (
					ignoreInterval
					or item.Urgent
					or state.LastScore == item.Score
					or state.LastAttempt == nil
					or now - state.LastAttempt >= item.Board.WriteInterval
				)
			then
				return index, item
			end
		end
		return nil, nil
	end

	local function dequeue(index: number, item: QueueItem)
		table.remove(writeQueue, index)
		writeQueueMap[writeKey(item.Board, item.UserId, item.StoreName)] = nil
		Metrics.Set("LbQueueDepth", #writeQueue)
	end

	local function writeItem(item: QueueItem)
		local state = item.State
		state.InFlight = true
		state.LastAttempt = Clock.Monotonic()
		activeWrites += 1
		local wrote, rejected = performWrite(item)
		if wrote then
			state.Failures, state.RetryAt, state.RejectedScore = nil, nil, nil
		else
			state.Failures = math.min((state.Failures or 0) + 1, 32)
			if rejected then
				state.RejectedScore = item.Score
			elseif state.Failures >= 3 then
				local delay = math.min(RETRY_MAX, RETRY_BASE * 2 ^ math.min(state.Failures - 3, 4))
				state.RetryAt = Clock.Monotonic() + math.min(RETRY_MAX, Rng.Jitter(delay))
			end
		end
		-- Failed responses may follow committed writes; invalidate the cached score.
		state.LastScore = if wrote then item.Score else nil
		-- SetAsync yields. An erase during it must not resurrect the score.
		if wrote and isErased(item.UserId) then
			state.LastScore = nil
			pcall(function()
				orderedStore(item.StoreName):RemoveAsync(tostring(item.UserId))
			end)
		end
		state.InFlight = false
		activeWrites -= 1
		local key = writeKey(item.Board, item.UserId, item.StoreName)
		if not wrote and not stopped and not isErased(item.UserId) then
			local newer = writeQueueMap[key]
			if rejected and (newer == nil or newer.Score == item.Score) then
				if newer then
					local index = table.find(writeQueue, newer)
					if index then
						dequeue(index, newer)
					end
				end
				reportStoreFailure("LB_WRITE_DROPPED", "leaderboard score rejected; waiting for a changed score", {
					Board = item.Board.Name,
					UserId = item.UserId,
					Score = item.Score,
				})
			elseif newer == nil then
				queueWrite(item)
			elseif rejected then
				state.RejectedScore, state.Failures, state.RetryAt = nil, nil, nil
			end
		end
		Metrics.Set("LbQueueDepth", #writeQueue)
		releaseWriteState(state)
	end

	local function writePacerLoop()
		Profile.MemoryCategory("Scribe")
		while not stopped do
			if #writeQueue == 0 then
				pacerParked = true
				coroutine.yield()
				pacerParked = false
				if stopped then
					break
				end
			end
			Clock.Wait(Rng.Jitter(WRITE_INTERVAL))
			local attempted: { [WriteState]: boolean } = {}
			-- Claim shared budget before dequeuing, including Defer batches.
			for _ = 1, math.min(if budgetPolicy then MAX_WRITES_PER_TICK else 1, #writeQueue) do
				if stopped then
					break
				end
				local index, item = nextWrite(false, attempted)
				if index == nil or item == nil then
					break
				end
				if isErased(item.UserId) or item.State.LastScore == item.Score then
					dequeue(index, item)
					if not isErased(item.UserId) then
						Metrics.Add("LbWritesSkipped")
					end
					releaseWriteState(item.State)
					continue
				end
				local granted, release = claimBackground("SetIncrementSortedAsync")
				if not granted then
					break
				end
				dequeue(index, item)
				attempted[item.State] = true
				writeItem(item)
				release()
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

	-- Ranks the players on this server by the board's score, with no store behind it.
	local function refreshServerBoard(board: Board)
		local scored: { { UserId: number, Score: any } } = {}
		for _, entry in ctx.Persistence.Entries do
			if entry.State == "Ready" and entry.LiveData then
				local value: any = readStat(entry, board)
				if board.IsBig or type(value) == "number" then
					local score = periodScore(board, entry, value, nil, false)
					if score ~= nil then
						table.insert(scored, { UserId = entry.UserId, Score = score })
					end
				end
			end
		end
		table.sort(scored, function(a, b)
			if board.IsBig then
				return Big.compare(a.Score, b.Score) > 0
			end
			return a.Score > b.Score
		end)
		local entries = {}
		local signatureParts = {}
		table.clear(board.MyRanks)
		for rank, item in scored do
			board.MyRanks[item.UserId] = rank
			board.MyScores[item.UserId] = item.Score
			if rank <= board.Limit then
				table.insert(
					entries,
					{ Rank = rank, UserId = item.UserId, Name = resolveName(item.UserId), Score = item.Score }
				)
				table.insert(signatureParts, `{item.UserId}:{item.Score}`)
			end
		end
		board.Cache = { Entries = entries, At = Clock.Monotonic() }
		board.LastReadAt, board.LastReadMono, board.LastReadError = Clock.Now(), Clock.Monotonic(), nil
		local previousSignature = board.Signature
		board.Signature = table.concat(signatureParts, "|")
		if board.Signature ~= previousSignature then
			local snapshot = table.create(#entries)
			for _, item in entries do
				table.insert(snapshot, copyEntry(board, item))
			end
			ctx.Signals.OnLeaderboard:Fire(board.Name, snapshot)
		end
		broadcastBoard(board)
	end

	-- Ranked entries. resolveName yields, so the erase check repeats after the last name is in.
	local function pageEntries(board: Board, page: any): { any }
		local named = {}
		for _, item in page:GetCurrentPage() do
			-- Per row: a name lookup can yield past a Stop.
			if stopped then
				return {}
			end
			local userId = tonumber(item.key) or 0
			if isErased(userId) then
				continue
			end
			local score: any = if board.IsBig then unpackBig(board, item.value) else item.value / board.Scale
			table.insert(named, { Rank = 0, UserId = userId, Name = resolveName(userId), Score = score })
		end
		local entries = {}
		for _, item in named do
			if not isErased(item.UserId) then
				item.Rank = #entries + 1
				table.insert(entries, item)
			end
		end
		return entries
	end

	-- Reads one period's store into an entry list, or nil on failure.
	local function readStore(board: Board, storeName: string, background: boolean?): { any }?
		local release: (() -> ())? = nil
		if background then
			local granted, free = claimBackground("GetSortedAsync")
			if not granted then
				return nil
			end
			release = free
		end
		local ok, page = pcall(function()
			return orderedStore(storeName):GetSortedAsync(false, board.Limit)
		end)
		if release then
			release()
		end
		if not ok then
			Metrics.Add("LbReadFailures")
			reportStoreFailure("LB_READ_FAIL", page, { Board = board.Name })
			return nil
		end
		return pageEntries(board, page)
	end

	local function refreshPeriodicBoard(board: Board, background: boolean?, reserved: (() -> ())?): boolean
		-- Reserve the live-board read before spending budget on history.
		local release = reserved
		if background and release == nil then
			local granted, free = claimBackground("GetSortedAsync")
			if not granted then
				return false
			end
			release = free
		end
		local period: number? = if board.Period then currentPeriod(board.Period) else nil
		if period ~= nil and period ~= board.CachePeriod then
			board.CachePeriod = period
			board.PreviousReads = 0
		end
		if period ~= nil and board.PreviousReads < PREVIOUS_READS then
			local previous = readStore(board, storeNameFor(board, period - 1), background)
			if stopped then
				if release then
					release()
				end
				return true
			end
			if previous ~= nil then
				board.PreviousReads += 1
				board.PreviousCache = { Entries = previous, Period = period - 1 }
			end
		end
		local ok, page = pcall(function()
			return orderedStore(storeNameFor(board, period)):GetSortedAsync(false, board.Limit)
		end)
		if release then
			release()
		end
		if not ok then
			-- As in performWrite: a throttled read must not drive the global health gate.
			Metrics.Add("LbReadFailures")
			board.LastReadError = tostring(page)
			reportStoreFailure("LB_READ_FAIL", page, { Board = board.Name })
			return true
		end

		local entries = pageEntries(board, page)
		if stopped then
			return true
		end
		local rankByUserId: { [number]: number } = {}
		local signatureParts = {}
		for _, item in entries do
			rankByUserId[item.UserId] = item.Rank
			table.insert(signatureParts, `{item.UserId}:{item.Score}`)
		end
		board.Cache = { Entries = entries, At = Clock.Monotonic() }
		board.LastReadAt, board.LastReadMono, board.LastReadError = Clock.Now(), Clock.Monotonic(), nil
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
		return true
	end

	local function wakeRefreshWaiters(board: Board)
		local waiters = board.RefreshWaiters
		board.RefreshWaiters = {}
		for _, thread in waiters do
			Sched.Resume(thread)
		end
	end

	--- Parks until the refresh in flight finishes or the bundle stops.
	local function awaitRefresh(board: Board)
		table.insert(board.RefreshWaiters, coroutine.running())
		coroutine.yield()
	end

	local function refreshBoard(board: Board, background: boolean?, reserved: (() -> ())?): boolean
		if board.Scope == "Server" then
			refreshServerBoard(board)
			return true
		end
		-- One refresh per board at a time and at most one waiting: later callers ride on
		-- the pending one, and nothing waiting starts after Stop.
		if board.Refreshing then
			if board.RefreshPending then
				repeat
					awaitRefresh(board)
				until stopped or not (board.Refreshing or board.RefreshPending)
				if reserved then
					reserved()
				end
				return true
			end
			board.RefreshPending = true
			repeat
				awaitRefresh(board)
			until stopped or not board.Refreshing
			board.RefreshPending = false
		end
		if stopped then
			if reserved then
				reserved()
			end
			return true
		end
		board.Refreshing = true
		local ok, result = pcall(refreshPeriodicBoard, board, background, reserved)
		if reserved then
			reserved()
		end
		board.Refreshing = false
		wakeRefreshWaiters(board)
		if not ok then
			error(result, 0)
		end
		return result
	end

	-- Due-time scheduler: each board on its own cadence, with the initial due times
	-- staggered across the first cycle so boot does not fire every board at once.
	-- When each board next reads, monotonic; empty until the first cycle is scheduled.
	local dueAt: { [string]: number } = {}

	local function refreshTick()
		local now = Clock.Monotonic()
		local dueBoards: { Board } = {}
		for boardName, board in boards do
			local due = dueAt[boardName]
			if due == nil or now >= due then
				table.insert(dueBoards, board)
			end
		end
		-- Claim budget for the oldest due board before spawning; keep denied boards overdue.
		table.sort(dueBoards, function(a, b)
			local left, right = dueAt[a.Name] or 0, dueAt[b.Name] or 0
			return if left == right then a.Name < b.Name else left < right
		end)
		for _, board in dueBoards do
			if board.Refreshing or board.RefreshPending then
				continue
			end
			local release: (() -> ())? = nil
			if board.Scope ~= "Server" then
				local granted, free = claimBackground("GetSortedAsync")
				if not granted then
					continue
				end
				release = free
			end
			dueAt[board.Name] = now + board.RefreshInterval
			Sched.Spawn(refreshBoard, board, true, release)
		end
	end

	--- Test seam: one pass of the scheduler.
	function self.RefreshTick()
		refreshTick()
	end

	local function refreshLoop()
		-- Attributes this loop's allocations to Scribe, as in writePacerLoop.
		Profile.MemoryCategory("Scribe")
		-- The jittered warm-up spreads the first refresh across a fleet booted by one
		-- deploy; the stagger below spreads boards within one server. Both are needed,
		-- and replacing the stagger with jitter would re-collide a server's own boards.
		Clock.Wait(Rng.Jitter(5))
		local index = 0
		local count = math.max(Util.count(boards), 1)
		for boardName, board in boards do
			dueAt[boardName] = Clock.Monotonic() + (board.RefreshInterval * index) / count
			index += 1
		end
		while not stopped do
			refreshTick()
			-- One draw per tick, not per re-arm. Drawing inside the board loop above would
			-- make the sequence depend on `boards` hash order, and jittering the tick
			-- decorrelates the re-arm anyway: `dueAt` inherits the drift in `now`.
			Clock.Wait(Rng.Jitter(1))
		end
	end

	type Counts = { Pending: number, Retrying: number, Rejected: number }
	local function writeCounts(onlyBoard: Board?): { [Board]: Counts }
		local counts: { [Board]: Counts } = {}
		for _, states in writeStates do
			for key, state in states do
				local board = state.Board
				if onlyBoard ~= nil and board ~= onlyBoard then
					continue
				end
				local count = counts[board]
				if count == nil then
					count = { Pending = 0, Retrying = 0, Rejected = 0 }
					counts[board] = count
				end
				local waiting = state.InFlight or writeQueueMap[key] ~= nil
				if waiting or state.RejectedScore ~= nil then
					count.Pending += 1
				end
				if state.RejectedScore ~= nil then
					count.Rejected += 1
				elseif waiting and (state.Failures or 0) > 0 then
					count.Retrying += 1
				end
			end
		end
		return counts
	end

	local function boardStatus(board: Board, count: Counts?, now: number): Types.LeaderboardStatusInfo
		local pending = if count then count.Pending else 0
		local retrying = if count then count.Retrying else 0
		local rejected = if count then count.Rejected else 0
		local age = if board.LastReadMono ~= nil then math.max(0, now - board.LastReadMono) else nil
		local stale = age ~= nil and age > 2 * board.RefreshInterval
		local status: Types.LeaderboardStatus = if retrying > 0
				or rejected > 0
				or board.LastReadError ~= nil
				or board.LastWriteError ~= nil
				or stale
			then "Degraded"
			elseif age == nil then "Starting"
			else "Healthy"
		return {
			Status = status,
			PendingWrites = pending,
			RetryingWrites = retrying,
			RejectedWrites = rejected,
			LastReadAt = board.LastReadAt,
			ReadAge = age,
			LastWriteAt = board.LastWriteAt,
			LastReadError = board.LastReadError,
			LastWriteError = board.LastWriteError,
		}
	end

	local function diagnosticSnapshot(): { [string]: Types.LeaderboardStatusInfo }
		local counts, now = writeCounts(nil), Clock.Monotonic()
		local snapshot: { [string]: Types.LeaderboardStatusInfo } = {}
		for name, board in boards do
			snapshot[name] = boardStatus(board, counts[board], now)
		end
		return snapshot
	end

	-- Called by Server.build once the full ctx is assembled, so neither loop ever runs
	-- against a half-constructed context.
	function self.Start()
		if started or stopped then
			return
		end
		started = true
		local any, global = false, false
		for _, board in boards do
			any = true
			if board.Scope ~= "Server" then
				global = true
			end
		end
		if global then
			pacerThread = Sched.Spawn(writePacerLoop)
		end
		if any then
			unregisterDiagnostics = Diagnostics.Register(diagnosticSnapshot)
			refreshThread = Sched.Spawn(refreshLoop)
		end
	end

	--- Which workers run, and whether the pacer is parked.
	function self.Workers(): { Pacer: boolean, Refresh: boolean, PacerParked: boolean }
		return { Pacer = pacerThread ~= nil, Refresh = refreshThread ~= nil, PacerParked = pacerParked }
	end

	-- Test seam: count retained score states.
	function self.WriteStateCount(): number
		local count = 0
		for _, states in writeStates do
			for _ in states do
				count += 1
			end
		end
		return count
	end

	-- Release both loops. Cancelled as well as flagged, because a parked loop would
	-- otherwise keep a thread alive per bundle until its next wake.
	function self.Stop()
		if stopped then
			return
		end
		stopped = true
		if unregisterDiagnostics then
			unregisterDiagnostics()
			unregisterDiagnostics = nil
		end
		for _, thread in { pacerThread, refreshThread } do
			pcall(task.cancel, thread)
		end
		pacerThread, refreshThread = nil, nil
		for release in budgetReleases do
			release()
		end
		table.clear(writeStates)
		table.clear(activeUsers)
		for _, board in boards do
			wakeRefreshWaiters(board)
		end
	end

	-- The OrderedDataStore a board reads and writes. Exposed so a test can pin the
	-- SigFigs namespacing, which is what keeps two key formats out of one store.
	function self.BoardStoreName(name: string, offset: number?): string?
		local board = boards[name]
		if not board then
			return nil
		end
		return storeNameFor(board, if board.Period then currentPeriod(board.Period) + (offset or 0) else nil)
	end

	function self.CurrentPeriod(name: string): number?
		local board = boards[name]
		return if board and board.Period then currentPeriod(board.Period) else nil
	end

	-- Whether boards resolved to the in-memory mock store. Exposed so a test can assert
	-- Leaderboards read the resolved Mode; board contents cannot, since a real store only
	-- happens to fail under the headless runner and in Studio the write lands.
	self.UsesMockStore = useMock

	--- The mock ordered store behind a board, so a test can make its calls fail. Mock
	--- mode only: nil on a real store, which no test may reach.
	-- Every range a period change closed, then the live one. A record with no kind is taken
	-- to be in the board's current kind.
	local function eraseRanges(board: Board, record: any): { { K: string, First: number, Last: number } }
		local last = currentPeriod(board.Period :: string)
		local sweeps = {}
		if type(record) ~= "table" then
			return { { K = board.Period :: string, First = last, Last = last } }
		end
		for _, prior in (if type(record.Prior) == "table" then record.Prior else {}) :: { any } do
			if
				type(prior) == "table"
				and (prior.K == "Daily" or prior.K == "Weekly")
				and type(prior.First) == "number"
				and type(prior.Last) == "number"
			then
				table.insert(sweeps, { K = prior.K, First = prior.First, Last = prior.Last })
			end
		end
		local kind = if record.K == "Daily" or record.K == "Weekly" then record.K else board.Period :: string
		local first = if type(record.First) == "number" then record.First else last
		if kind == board.Period then
			table.insert(sweeps, { K = kind, First = first, Last = last })
		else
			table.insert(
				sweeps,
				{ K = kind, First = first, Last = if type(record.P) == "number" then record.P else first }
			)
			table.insert(sweeps, { K = board.Period :: string, First = last, Last = last })
		end
		return sweeps
	end

	--- A mock store by full name, for a period the board no longer uses.
	function self.MockStoreNamed(storeName: string): any?
		return if useMock then orderedStore(storeName) else nil
	end

	function self.MockStoreFor(name: string, offset: number?): any?
		if not useMock then
			return nil
		end
		local storeName = self.BoardStoreName(name, offset)
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
		activeUsers[entry.UserId] = (activeUsers[entry.UserId] or 0) + 1
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
					self.Enqueue(board, entry, value)
				end
				table.insert(
					disconnects,
					-- Parenthesised to truncate the call to one value: `Changed` returns
					-- exactly one, the disconnect closure, but the accessor is `any`, so
					-- the solver sees a variadic tail and cannot pick a table.insert
					-- overload.
					(
						accessor.Changed(function(newValue: any, oldValue: any)
							if board.IsBig or type(newValue) == "number" then
								self.Enqueue(board, entry, newValue, oldValue)
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
					self.Enqueue(board, entry, value, nil, true)
				end
			end
		end
		if disconnects then
			local remaining = (activeUsers[entry.UserId] or 1) - 1
			activeUsers[entry.UserId] = if remaining > 0 then remaining else nil
		end
		local states = writeStates[entry.UserId]
		if states then
			for key, state in states do
				local queued = writeQueueMap[key]
				if queued then
					queued.Urgent = true
				end
				releaseWriteState(state)
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

	function self.GetLeaderboard(name: string, limit: number?, offset: number?): { any }
		local board = boards[name]
		if not board then
			checkBoardName(name, "GetLeaderboard")
			return {}
		end
		local entries = board.Cache.Entries
		if offset ~= nil and offset ~= 0 then
			if offset ~= -1 then
				error(`Scribe.GetLeaderboard: offset must be 0 or -1, not {tostring(offset)}`, 2)
			end
			-- A server or lifetime board has no previous period.
			local previous = board.PreviousCache
			if board.Period == nil or previous == nil or previous.Period ~= currentPeriod(board.Period) - 1 then
				return {}
			end
			entries = previous.Entries
		end
		local out = {}
		for i = 1, math.min(limit or board.Limit, #entries) do
			table.insert(out, copyEntry(board, entries[i]))
		end
		return out
	end

	function self.GetStatus(name: string): Types.LeaderboardStatusInfo?
		local board = boards[name]
		if not board then
			checkBoardName(name, "GetLeaderboardStatus")
			return nil
		end
		return boardStatus(board, writeCounts(board)[board], Clock.Monotonic())
	end

	function self.GetRefreshIn(name: string): number?
		if not boards[name] then
			checkBoardName(name, "GetLeaderboardRefreshIn")
			return nil
		end
		local due = dueAt[name]
		if due == nil then
			return nil
		end
		return math.max(0, due - Clock.Monotonic())
	end

	function self.GetResetIn(name: string): number?
		local board = boards[name]
		if not board then
			checkBoardName(name, "GetLeaderboardResetIn")
			return nil
		end
		return if board.Period then periodEndsIn(board.Period) else nil
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
		local attempts: { [WriteState]: number } = {}
		local exhausted: { [WriteState]: boolean } = {}
		while Clock.Monotonic() < deadline do
			local index, item = nextWrite(true, exhausted)
			if index == nil or item == nil then
				if activeWrites > 0 then
					Clock.Wait(math.min(0.05, math.max(0, deadline - Clock.Monotonic())))
					continue
				end
				break
			end
			dequeue(index, item)
			if isErased(item.UserId) or item.State.LastScore == item.Score then
				if not isErased(item.UserId) then
					Metrics.Add("LbWritesSkipped")
				end
				releaseWriteState(item.State)
				continue
			end
			flushed += 1
			local count = (attempts[item.State] or 0) + 1
			attempts[item.State] = count
			exhausted[item.State] = count >= 3
			writeItem(item)
		end
		Log.Info("Leaderboards", "LB_SHUTDOWN_FLUSH", "leaderboard queue drained on shutdown", {
			Flushed = flushed,
			Remaining = #writeQueue,
		})
	end

	-- GDPR: remove the user from every board. Returns (ok, err); a false ok
	-- means at least one board's RemoveAsync failed and the caller must retry.
	-- `ranges` is the profile's Boards record; a periodic board is swept from First to now.
	--- Removes `userId` from an entry list and renumbers the rest; true if it was there.
	local function pruneEntries(entries: { any }, userId: number): boolean
		local pruned = false
		for i = #entries, 1, -1 do
			if entries[i].UserId == userId then
				table.remove(entries, i)
				pruned = true
			end
		end
		if pruned then
			for i, item in entries do
				item.Rank = i
			end
		end
		return pruned
	end

	--- The third return is true when the budget never freed up.
	local function removeOne(storeName: string, key: string): (boolean, string?, boolean)
		local release: (() -> ())? = nil
		if budgetPolicy then
			local granted, free = Budget.Await("OrderedRemove", 1, ERASE_BUDGET_TIMEOUT)
			if not granted then
				return false, "the OrderedRemove budget did not free up in time", true
			end
			release = free
		end
		Metrics.Add("LbEraseRemoves")
		local ok, err = pcall(function()
			orderedStore(storeName):RemoveAsync(key)
		end)
		if release ~= nil then
			release()
		end
		return ok, if ok then nil else tostring(err), false
	end

	--- `progress`, when given, is `{ Done, Cursors, Save }`; `Save` persists the other two and
	--- answers false when the sweep must stop. It runs every 25 removals, every
	--- ERASE_HEARTBEAT seconds, and on any failure or completion.
	function self.EraseUser(userId: number, ranges: { [string]: any }?, progress: any?): (boolean, string?)
		-- Tombstone first, so an already-dequeued pacer write cannot resurrect the score
		-- after RemoveAsync. Held long enough to outlive that write plus its retries.
		erasedUsers[userId] = Clock.Monotonic() + 300
		writeStates[userId] = nil

		-- Drop any still-queued writes for this user, or the pacer would
		-- SetAsync their score back into a board we just RemoveAsync'd.
		for i = #writeQueue, 1, -1 do
			local queued = writeQueue[i]
			if queued.UserId == userId then
				writeQueueMap[`{queued.Board.Name}|{userId}|{queued.StoreName}`] = nil
				table.remove(writeQueue, i)
			end
		end
		Metrics.Set("LbQueueDepth", #writeQueue)

		local key = tostring(userId)
		local failed: string? = nil
		-- Reported once below rather than per board: the log folds by subject, so N
		-- per-board lines collapse into the first, losing which boards still hold the data.
		local failedBoards: { string }? = nil
		local halted = false
		local lost = false
		local lastSave = Clock.Monotonic()
		local function checkpoint(): boolean
			lastSave = Clock.Monotonic()
			if progress == nil or progress.Save() then
				return true
			end
			lost = true
			return false
		end
		local function heartbeatDue(): boolean
			return progress ~= nil and Clock.Monotonic() - lastSave >= ERASE_HEARTBEAT
		end
		for _, board in boards do
			-- A server board stores nothing; the cache prune below is its whole erase.
			local ok, err = true, nil
			local done = progress ~= nil and progress.Done[board.Name] == true
			if board.Scope == "Server" or done or halted or lost then
				ok = true
			elseif board.Period == nil then
				local budgetOut
				ok, err, budgetOut = removeOne(board.StoreName, key)
				if progress then
					if ok then
						progress.Done[board.Name] = true
						if heartbeatDue() then
							checkpoint()
						end
					else
						checkpoint()
					end
				end
				halted = budgetOut
			else
				local cursor = if progress then progress.Cursors[board.Name] else nil
				local removed = 0
				for index, sweep in eraseRanges(board, if ranges then ranges[board.Name] else nil) do
					if not ok or lost then
						break
					end
					local from = sweep.First
					if type(cursor) == "table" and type(cursor.Range) == "number" then
						if index < cursor.Range then
							continue
						elseif index == cursor.Range and type(cursor.Next) == "number" then
							from = math.max(from, cursor.Next)
						end
					end
					for period = from, sweep.Last do
						local okOne, errOne, budgetOut = removeOne(storeNameForKind(board, sweep.K, period), key)
						if not okOne then
							ok, err = false, errOne
							halted = budgetOut
							if progress then
								progress.Cursors[board.Name] = { Range = index, Next = period }
								checkpoint()
							end
							break
						end
						removed += 1
						if
							progress
							and period < sweep.Last
							and (removed % ERASE_PROGRESS_EVERY == 0 or heartbeatDue())
						then
							progress.Cursors[board.Name] = { Range = index, Next = period + 1 }
							if not checkpoint() then
								break
							end
						end
					end
				end
				if ok and not lost and progress then
					progress.Cursors[board.Name] = nil
					progress.Done[board.Name] = true
					checkpoint()
				end
			end
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
			-- The caches too, or the user is served until the next refresh.
			local entries = board.Cache.Entries
			if pruneEntries(entries, userId) then
				-- A new signature, so stale SentState cannot suppress the broadcast.
				local signatureParts = {}
				for _, item in entries do
					table.insert(signatureParts, `{item.UserId}:{item.Score}`)
				end
				board.Signature = table.concat(signatureParts, "|")
				broadcastBoard(board)
			end
			if board.PreviousCache ~= nil then
				pruneEntries(board.PreviousCache.Entries, userId)
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
		if lost then
			return false, "the erase was finished or replaced elsewhere"
		end
		if failed then
			return false, `a leaderboard erase failed: {failed}`
		end
		return true, nil
	end

	return self
end

return Leaderboards
