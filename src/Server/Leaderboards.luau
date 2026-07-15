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
local Log = require(Internal.Log)
local Metrics = require(Internal.Metrics)
local Health = require(Internal.Health)

local Leaderboards = {}

local WRITE_INTERVAL = 1.5
local REFRESH_INTERVAL = 60
local QUEUE_CAP = 1000
local NAME_TTL = 900
local NAME_NEGATIVE_TTL = 120

type Board = {
	Name: string,
	StatPath: { string },
	Limit: number,
	Scale: number,
	Replicate: boolean, -- default false: server-only, no client mirror
	StoreName: string,
	Cache: { Entries: { any }, At: number },
	Signature: string, -- fingerprint of Cache.Entries; broadcasts only on change
	MyRanks: { [number]: number? },
	MyScores: { [number]: number? },
	SentState: { [number]: { Sig: string, Rank: number?, Score: number? } },
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
	local useMock: boolean = options.UseMock == true or options.DontSave == true

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
				break
			end
			if walkNode.Kind == "leaf" then
				error(
					`Scribe: leaderboard "{name}" Stat "{config.Stat}" descends through leaf field "{tostring(segment)}"`,
					0
				)
			end
			walkNode = if i < #statPath then Template.ChildSchema(walkNode, segment) else nil
		end
		boards[name] = {
			Name = name,
			StatPath = Util.parsePath(config.Stat),
			Limit = math.clamp(config.Limit or 100, 1, 100),
			Scale = config.Scale or 1,
			Replicate = config.Replicate == true,
			StoreName = if type(config.StoreName) == "string" then config.StoreName else `LB_{name}`,
			Cache = { Entries = {}, At = 0 },
			Signature = "",
			MyRanks = {},
			MyScores = {},
			SentState = {},
		}
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

	-- Write queue ------------------------------------------------------------------

	function self.Enqueue(board: Board, userId: number, score: number)
		if type(score) ~= "number" or score ~= score then
			return
		end
		if isErased(userId) then
			return -- within the GDPR tombstone window; do not re-add
		end
		local scaled = math.floor(score * board.Scale + 0.5)
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
			Health.ReportSuccess("Leaderboards")
			Metrics.Add("LbWrites")
		else
			Health.ReportFailure("Leaderboards")
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
				if not performWrite(item) then
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
			nameCache[userId] = { Name = player.Name, At = now }
			return player.Name
		end
		local ok, name = pcall(function()
			return Players:GetNameFromUserIdAsync(userId)
		end)
		-- Negative caching: failed lookups are cached briefly.
		nameCache[userId] = { Name = if ok then name else nil, At = now }
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
			Health.ReportFailure("Leaderboards")
			Log.Warn("Leaderboards", "LB_READ_FAIL", tostring(page), { Board = board.Name })
			return
		end
		Health.ReportSuccess("Leaderboards")

		local entries = {}
		local rankByUserId: { [number]: number } = {}
		local signatureParts = {}
		for rank, item in page:GetCurrentPage() do
			local userId = tonumber(item.key) or 0
			local score = item.value / board.Scale
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
		board.Signature = table.concat(signatureParts, "|")

		-- Each online player's own rank/score, computed on the refresh cycle.
		for _, entry in ctx.Persistence.Entries do
			if entry.State == "Ready" and entry.LiveData then
				local value: any = entry.LiveData
				for _, segment in board.StatPath do
					value = if type(value) == "table" then value[segment] else nil
				end
				board.MyScores[entry.UserId] = if type(value) == "number" then value else nil
				board.MyRanks[entry.UserId] = rankByUserId[entry.UserId]
			end
		end

		broadcastBoard(board)
	end

	local function refreshLoop()
		task.wait(5)
		while true do
			for _, board in boards do
				task.spawn(refreshBoard, board)
				task.wait(REFRESH_INTERVAL / math.max(Util.count(boards), 1))
			end
			if next(boards) == nil then
				task.wait(REFRESH_INTERVAL)
			end
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
			local accessor = entry.Tree.Accessor
			for _, segment in board.StatPath do
				accessor = accessor[segment]
			end
			local value = accessor.Get()
			if type(value) == "number" then
				self.Enqueue(board, entry.UserId, value)
			end
			table.insert(disconnects, accessor.Changed(function(newValue: any)
				if type(newValue) == "number" then
					self.Enqueue(board, entry.UserId, newValue)
				end
			end))
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
				if type(value) == "number" then
					self.Enqueue(board, entry.UserId, value)
				end
			end
		end
	end

	-- Public API --------------------------------------------------------------------------

	function self.GetLeaderboard(name: string, limit: number?): { any }
		local board = boards[name]
		if not board then
			return {}
		end
		local out = {}
		for i = 1, math.min(limit or board.Limit, #board.Cache.Entries) do
			table.insert(out, table.clone(board.Cache.Entries[i]))
		end
		return out
	end

	function self.GetMyRank(player: Player, name: string): number?
		local board = boards[name]
		local entry = ctx.Persistence.Entries[player]
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
			performWrite(item)
			flushed += 1
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
		end
		if failed then
			return false, `profile removed, but a leaderboard erase failed: {failed}`
		end
		return true, nil
	end

	return self
end

return Leaderboards
