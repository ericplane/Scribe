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
local Health = require(Internal.Health)

local Leaderboards = {}

local WRITE_INTERVAL = 1.5
local REFRESH_INTERVAL = 60
-- Floor on a per-board RefreshInterval. GetSortedAsync's request budget scales with
-- player count, so the worst case is a near-empty server: it has the smallest budget
-- while still refreshing every board on the same schedule. Going FASTER than the
-- default is also usually the wrong tool. A sub-minute board is almost always an
-- in-server live scoreboard, which belongs in Scribe.Shared at zero DataStore cost;
-- these boards are global and all-time. So the option exists to go slower.
local MIN_REFRESH_INTERVAL = 60
-- Boot guard on the AGGREGATE rate, which is what actually burns budget: ten boards
-- at 60s costs more than one board at 15s, and a flat floor permits the former while
-- blocking the latter. Conservative enough to stay inside a low-population server's
-- allowance with headroom for the write pacer.
local MAX_REFRESH_PER_MINUTE = 12
local QUEUE_CAP = 1000
local NAME_TTL = 900
local NAME_NEGATIVE_TTL = 120
local NAME_CACHE_CAP = 4096 -- bound the resolved-name cache; entries are re-resolvable

-- Scribe.Big leaderboards ----------------------------------------------------------
--
-- An OrderedDataStore key is an integer, and a Luau number stops being an exact
-- integer at 2^53, so a big value cannot be stored raw. It does not need to be: a
-- big is already normalized to 1 <= |m| < 10 with an integer exponent, so packing
-- exponent-major preserves the ordering EXACTLY, with no logarithm.
--
--   key = e * stride + floor(m * mantissaScale)
--
-- with stride = 10^SigFigs and mantissaScale = 10^(SigFigs - 1), so the mantissa
-- lands in [mantissaScale, stride) and can never spill into the next exponent's
-- slot. Exponent dominates, mantissa breaks ties, which is a big's own comparison
-- order.
--
-- SigFigs is per board, because the whole key has to stay under 2^53 and the two
-- halves compete for it: every extra significant figure costs a factor of ten of
-- exponent range. A prestige currency that needs to separate 1.23456789012345e900
-- from its neighbour wants more; a gem counter that only needs a rough ordering
-- over an enormous range wants fewer.
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
			table.sort(sorted, function(a, b)
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
	-- Read the RESOLVED mode, not the legacy flags. Persistence resolves Mode into
	-- its own fields and never writes it back into options, so reading UseMock here
	-- meant a Mode = "Mock" bundle still hit real OrderedDataStores. NoSave mocks
	-- too: it promises nothing can be written back, and a board write is a write.
	-- Persistence is built before Leaderboards, so Mode is set by now.
	local mode: string = ctx.Persistence.Mode
	local useMock: boolean = mode == "Mock" or mode == "NoSave"

	local boards: { [string]: Board } = {}
	local storeCache: { [string]: any } = {}
	local mockStores: { [string]: any } = {}

	local writeQueue: { { Board: Board, UserId: number, Score: number, Attempts: number } } = {}
	local writeQueueMap: { [string]: { Board: Board, UserId: number, Score: number, Attempts: number } } = {}
	-- GDPR tombstones: an erased userId is suppressed in the pacer until this
	-- clock time, long enough to outlive any in-flight write plus its retries.
	local erasedUsers: { [number]: number } = {}
	local function isErased(userId: number): boolean
		local until_ = erasedUsers[userId]
		if until_ == nil then
			return false
		end
		if os.clock() >= until_ then
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
		-- Fail fast on a Stat path that descends through a leaf field: at runtime
		-- it would throw on every player load (after Ready), skipping cross-server
		-- gift-message registration for the whole session. Paths into dynamic
		-- ("any") subtables are legitimate and pass.
		local statPath = Util.parsePath(config.Stat)
		local walkNode: any = ctx.Compiled.Root
		for i, segment in statPath do
			if walkNode == nil then
				-- ChildSchema only returns nil for an undeclared field of a closed
				-- element shape (open containers synthesize a generic child), so this
				-- Stat can never resolve: fail at boot instead of throwing on every
				-- player load.
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
		-- A board's entries live in an OrderedDataStore that outlives the session,
		-- but a Scribe.Session field is rebuilt from its default every session and
		-- is never in LiveData, which is where the refresh cycle reads scores from.
		-- The path resolves, so nothing downstream complains: the board just stays
		-- empty forever. Refuse at boot instead.
		if walkNode.Persist == false then
			error(
				`Scribe: leaderboard "{name}" Stat "{config.Stat}" is a Scribe.Session field, which never `
					.. "persists and resets every session, so there is nothing for a board to rank",
				0
			)
		end
		-- The score becomes the OrderedDataStore key, so a non-numeric stat has
		-- nothing to rank. The refresh cycle already drops it, silently, leaving an
		-- empty board and no error anywhere. "any" is a dynamic subtree whose type
		-- is unknowable at boot, so it stays allowed.
		local statType = walkNode.ValueType
		if statType ~= "number" and statType ~= "int" and statType ~= "big" and statType ~= "any" then
			error(
				`Scribe: leaderboard "{name}" Stat "{config.Stat}" is a {tostring(statType)} field; a Stat must `
					.. "resolve to a number, a Scribe.Int, or a Scribe.Big",
				0
			)
		end
		-- Scale multiplies into the stored integer and divides back out on read, so a
		-- zero divides by zero (NaN scores served to every client), a negative one
		-- silently inverts the ordering against the descending query, and a
		-- non-finite one makes every write a guaranteed OrderedDataStore rejection.
		-- Fail fast like Stat/Period rather than serving nonsense at runtime.
		if config.Replicate == true and walkNode ~= nil and walkNode.ValueType == "big" then
			-- The board frame writes each Score as an f64, and a big Score is a table.
			-- Sending one throws inside broadcastBoard, which runs under the inbound
			-- frame pcall during a client Hello: the joining player is counted as a
			-- malformed frame and silently loses every other player's Shared data.
			-- Refuse it at boot rather than shipping a board that breaks the handshake.
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
		if config.Scale ~= nil then
			local scale = config.Scale
			if type(scale) ~= "number" or scale ~= scale or scale <= 0 or scale == math.huge then
				error(`Scribe: leaderboard "{name}" Scale must be a finite number greater than 0`, 0)
			end
		end
		local isBig = walkNode ~= nil and walkNode.ValueType == "big"
		local sigFigs = BIG_DEFAULT_SIG_FIGS
		if config.SigFigs ~= nil then
			-- SigFigs is the big packing's own dial. On a plain numeric stat the key IS
			-- the value and Scale is the dial, so accepting it there would silently do
			-- nothing.
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
		-- No boot warning for a narrowed exponent range. The developer chose this
		-- deliberately, nothing is wrong yet, and warning every server start forever
		-- is how a diagnostic becomes background noise. LB_SCORE_OUT_OF_RANGE already
		-- names the cap and the SigFigs that set it, at the moment a score is actually
		-- dropped, which is when there is something to act on.
		local maxExponent = bigMaxExponent(bigStride)
		-- Opt-in slower refresh. Clamped up rather than rejected so an existing config
		-- keeps working, but the clamp is reported: silently running 6x slower than
		-- asked would be its own bug.
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
			-- Resolved at boot from the stat's schema, so the write path never has to
			-- re-walk it.
			IsBig = isBig,
			BigSigFigs = sigFigs,
			BigStride = bigStride,
			BigMantissaScale = bigStride / 10,
			BigMaxExponent = maxExponent,
			Replicate = config.Replicate == true,
			-- EVERY big board gets its own store, including one at the default
			-- SigFigs. A big is packed exponent-major and a plain numeric stat is
			-- packed as itself, so they are two key LAYOUTS, and a board name is all
			-- that separates one store from another. Sharing `LB_<name>` meant that
			-- retyping a stat from Scribe.Int to Scribe.Big (which needs no migration
			-- and produces no warning) silently reinterpreted every key already
			-- written: a legacy 9e11 decodes as 9, so a brand-new account with 100
			-- outranks it, and a legacy 3.5e12 is bit-identical to the new-format key
			-- for 5000, so no repair pass could ever separate them.
			--
			-- SigFigs is in the name because it changes the layout again, for the same
			-- reason. An explicit StoreName still wins: that caller is managing the
			-- namespace themselves.
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

	-- Aggregate budget guard. A flat per-board floor permits ten boards at 60s (10
	-- reads/min) while blocking one board at 15s (4 reads/min), so the floor alone
	-- controls the wrong thing. Fail at boot like Stat/Scale/Period rather than
	-- surfacing as mystery throttling in production.
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
			-- Below every representable key, NOT 0. A value in (0, 1) has a negative
			-- exponent and therefore a negative key, so mapping zero to 0 ranked an
			-- empty balance above every fractional one. The lowest real key is
			-- -maxExponent * stride + mantissaScale, so this sits strictly under it.
			return -board.BigMaxExponent * board.BigStride
		end
		-- The packing has no room for a sign, and silently mis-ranking negatives is
		-- worse than refusing them.
		if big.M < 0 or math.abs(big.E) > board.BigMaxExponent then
			return nil
		end
		return big.E * board.BigStride + math.floor(big.M * board.BigMantissaScale)
	end

	-- A handed-out entry is a copy, because both docs invite the caller to keep or
	-- mutate it. table.clone is SHALLOW, so a big board's Score would still alias the
	-- object in the cache and a caller writing to it would corrupt every later read
	-- until the next refresh. Rebuild the big instead.
	local function copyEntry(board: Board, item: any): any
		local copy = table.clone(item)
		if board.IsBig and copy.Score ~= nil then
			copy.Score = Big.from(copy.Score)
		end
		return copy
	end

	local function unpackBig(board: Board, key: number): any
		local stride = board.BigStride
		-- The zero sentinel, plus the legacy 0 that boards written before it used.
		if key == 0 or key <= -board.BigMaxExponent * stride then
			return Big.from(0)
		end
		-- The division cannot round up into the next exponent, which would decode a
		-- score at the wrong magnitude. The true quotient is e + mantissa/stride, so
		-- rounding up needs the gap to 1 (at least 1/stride) to fall inside half an
		-- ulp of e, which is at most e * 2^-53. That needs e * stride >= 2^53, and
		-- bigMaxExponent caps e strictly below that. Widening the cap would break
		-- this, so keep the two together.
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
			-- Scale does not apply: the packing IS the mapping into the key space.
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
		-- OrderedDataStore only accepts a signed 64-bit integer. A scaled value past
		-- that (an idle-game currency, an unbounded stat, an aggressive Scale) is
		-- rejected by SetAsync EVERY time, and the value is re-enqueued on every
		-- Changed and again on unload, so it becomes a permanent failure stream.
		-- Drop it here, loudly and once per (board, user), instead of queueing a write
		-- that cannot succeed.
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
			Log.Warn("Leaderboards", "LB_QUEUE_OVERFLOW", "write queue overflow; dropped oldest entry", {})
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
			-- Deliberately NOT Health.ReportFailure: OrderedDataStore writes are the
			-- highest-volume, least-critical DataStore traffic Scribe generates and are
			-- routinely throttled under load. Feeding them into the shared health budget
			-- let ordinary leaderboard throttling flip the GLOBAL status to Outage,
			-- which makes ProcessReceipt return NotProcessedYet and blocks Robux
			-- purchases. LbWriteFailures + LB_WRITE_FAIL are the fail-loud signal here.
			Metrics.Add("LbWriteFailures")
			Log.Warn("Leaderboards", "LB_WRITE_FAIL", tostring(err), {
				Board = board.Name,
				UserId = item.UserId,
				Score = item.Score,
			})
		end
		return ok
	end

	local function writePacerLoop()
		while true do
			task.wait(WRITE_INTERVAL)
			local item = table.remove(writeQueue, 1)
			if item then
				local key = `{item.Board.Name}|{item.UserId}`
				writeQueueMap[key] = nil
				Metrics.Set("LbQueueDepth", #writeQueue)
				-- A user erased since this item was dequeued must not be written
				-- back into the OrderedDataStore we just RemoveAsync'd.
				if isErased(item.UserId) then
					continue
				end
				local wrote = performWrite(item)
				-- performWrite's SetAsync yields; if EraseUser ran during that yield,
				-- this write resurrected the score past its RemoveAsync. Re-check and
				-- undo just this board's write so the erase holds.
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
						Log.Warn("Leaderboards", "LB_WRITE_DROPPED", "leaderboard write abandoned after retries", {
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

	-- Cache a resolved name, keeping the map bounded: names are re-resolvable, so
	-- once the cache fills, drop entries whose TTL has lapsed. Without this it
	-- grows one entry per distinct userId ever seen in any board's top-N, for the
	-- server's whole lifetime.
	local nameCacheCount = 0
	local function cacheName(userId: number, entry: { Name: string?, At: number })
		if nameCache[userId] == nil then
			nameCacheCount += 1
		end
		nameCache[userId] = entry
		if nameCacheCount >= NAME_CACHE_CAP then
			local now = os.clock()
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
			-- TTL eviction alone does not bound the map when distinct-user inflow
			-- outpaces expiry (all entries still fresh). Fall back to evicting the
			-- oldest-by-refresh-time entries down to half the cap, so the cache is
			-- hard-bounded regardless of freshness and this O(n log n) pass amortizes
			-- across the next ~cap/2 inserts.
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
		local now = os.clock()
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
		ctx.Replication.SendTo(entry, Wire.Finish(w))
		board.SentState[entry.UserId] = { Sig = board.Signature, Rank = myRank, Score = myScore }
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
			-- Same reasoning as performWrite: a throttled board read is routine and must
			-- not drive the global health gate that receipts key off.
			Metrics.Add("LbReadFailures")
			Log.Warn("Leaderboards", "LB_READ_FAIL", tostring(page), { Board = board.Name })
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
		board.Cache = { Entries = entries, At = os.clock() }
		local previousSignature = board.Signature
		board.Signature = table.concat(signatureParts, "|")

		-- Fire BEFORE broadcastBoard, which returns immediately for a board without
		-- Replicate. Server-only is the default, so those boards otherwise have no way
		-- at all to observe a refresh and the only option is polling on a timer that
		-- cannot align with this schedule. Entries are cloned: handing over the live
		-- cache would let a listener mutate what every later read serves.
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
				local value: any = entry.LiveData
				for _, segment in board.StatPath do
					value = if type(value) == "table" then value[segment] else nil
				end
				board.MyScores[entry.UserId] = if board.IsBig or type(value) == "number" then value else nil
				board.MyRanks[entry.UserId] = rankByUserId[entry.UserId]
			end
		end

		broadcastBoard(board)
	end

	-- Each board is now on its own cadence, so the single shared cycle is replaced by
	-- a due-time scheduler. Initial due times are staggered across the first cycle so
	-- boot does not fire every board in the same instant.
	local function refreshLoop()
		task.wait(5)
		local dueAt: { [string]: number } = {}
		local index = 0
		local count = math.max(Util.count(boards), 1)
		for boardName, board in boards do
			dueAt[boardName] = os.clock() + (board.RefreshInterval * index) / count
			index += 1
		end
		while true do
			local now = os.clock()
			for boardName, board in boards do
				local due = dueAt[boardName]
				if due == nil or now >= due then
					dueAt[boardName] = now + board.RefreshInterval
					task.spawn(refreshBoard, board)
				end
			end
			task.wait(1)
		end
	end

	-- Called by Server.build once the full ctx is assembled, so the paced
	-- write queue and refresh cycle never run against a half-constructed
	-- context.
	function self.Start()
		task.spawn(writePacerLoop)
		task.spawn(refreshLoop)
	end

	-- Refresh one board (or all) immediately instead of waiting for the cycle.
	-- The OrderedDataStore a board reads and writes. Exposed so a test can pin the
	-- SigFigs namespacing, which is what keeps two key formats out of one store.
	function self.BoardStoreName(name: string): string?
		local board = boards[name]
		return if board then board.StoreName else nil
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
					accessor.Changed(function(newValue: any)
						if board.IsBig or type(newValue) == "number" then
							self.Enqueue(board, entry.UserId, newValue)
						end
					end)
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
		for _, board in boards do
			board.MyRanks[entry.UserId] = nil
			board.MyScores[entry.UserId] = nil
			board.SentState[entry.UserId] = nil
		end
		-- Flush the player's latest scores on leave.
		if entry.LiveData then
			for _, board in boards do
				local value: any = entry.LiveData
				for _, segment in board.StatPath do
					value = if type(value) == "table" then value[segment] else nil
				end
				if board.IsBig or type(value) == "number" then
					self.Enqueue(board, entry.UserId, value)
				end
			end
		end
	end

	-- Public API --------------------------------------------------------------------------

	-- An unknown board name returns empty/nil with no other signal, and the names are
	-- case-sensitive, so a typo looks exactly like a board that has not refreshed yet.
	-- Warn once per name in Studio, matching checkOwnsKey in Monetization.
	local warnedBoardNames: { [string]: boolean } = {}
	local function checkBoardName(name: string, caller: string)
		if ctx.DevMode and not boards[name] and not warnedBoardNames[name] then
			warnedBoardNames[name] = true
			Log.Warn(
				"Leaderboards",
				"LB_UNKNOWN_BOARD",
				`{caller}("{name}") — no board named "{name}" is declared in the Leaderboards option (names are case-sensitive); this always returns nothing`,
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
		local deadline = os.clock() + budget
		local flushed = 0
		while os.clock() < deadline do
			local item = table.remove(writeQueue, 1)
			if not item then
				break
			end
			writeQueueMap[`{item.Board.Name}|{item.UserId}`] = nil
			flushed += 1
			-- Mirror the pacer's GDPR guard: skip a user erased before the write, and
			-- undo a write whose SetAsync yield raced a concurrent EraseUser (which
			-- would otherwise resurrect the score past its RemoveAsync).
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
		-- Tombstone first so an in-flight pacer write (already dequeued) cannot
		-- resurrect the score after we RemoveAsync it. Kept for a few minutes,
		-- enough to outlive the in-flight write plus its retries.
		erasedUsers[userId] = os.clock() + 300

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
		for _, board in boards do
			local ok, err = pcall(function()
				orderedStore(board.StoreName):RemoveAsync(key)
			end)
			if not ok then
				-- Attempt every board, but remember the failure so erase can't
				-- report success while personal data is retained.
				failed = tostring(err)
				Health.ReportFailure("Leaderboards")
				Log.Error("Leaderboards", "LB_ERASE_FAIL", tostring(err), { Board = board.Name, UserId = userId })
			end
			board.MyRanks[userId] = nil
			board.MyScores[userId] = nil
			board.SentState[userId] = nil
			-- Also drop the erased user from the in-memory cache so their userId /
			-- resolved Name / Score are not served (GetLeaderboard) or freshly pushed
			-- to a client completing the handshake before the next refreshBoard.
			local entries = board.Cache.Entries
			local pruned = false
			for i = #entries, 1, -1 do
				if entries[i].UserId == userId then
					table.remove(entries, i)
					pruned = true
				end
			end
			if pruned then
				-- Renumber so GetLeaderboard serves a contiguous rank sequence rather
				-- than a gapped one (1, 3, 4, ...) until the next refresh. Then
				-- recompute the signature (same format as refreshBoard) so the change
				-- broadcasts and stale SentState entries do not suppress the update.
				local signatureParts = {}
				for i, item in entries do
					item.Rank = i
					table.insert(signatureParts, `{item.UserId}:{item.Score}`)
				end
				board.Signature = table.concat(signatureParts, "|")
				-- Recomputing the signature only makes the change ELIGIBLE to send;
				-- broadcastBoard is what actually sends it, and refreshBoard was its
				-- only caller. Without this, connected clients kept rendering the
				-- erased user until the next 60s refresh.
				broadcastBoard(board)
			end
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
