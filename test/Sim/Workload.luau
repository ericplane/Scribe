--!nonstrict
-- A deterministic player workload: joins, mutations, leaves, hops and crashes.
--
-- Drawn from its own named Rng stream, so changing a disk latency profile or a
-- fault rate does not shift which players did what. Two configurations at one seed
-- stay comparable, which is the only reason to have a seed at all.
--
-- ONE CONSTRAINT IS REAL RATHER THAN STYLISTIC: a player may never be rejoined to
-- a server that already holds their session. ProfileStore hard-errors if a single
-- module instance is asked to load a key it already has, so a "hop" to the same
-- server would raise a harness error rather than model anything. Real players hop
-- BETWEEN servers, so the workload routes them accordingly -- and a crashed server
-- is removed from the pool entirely, because a crash takes the whole server.

local Rng = require(script.Parent.Rng)

local Workload = {}
Workload.__index = Workload

function Workload.new(config)
	return setmetatable({
		_uni = config.Universe,
		_model = config.Model,
		_rng = Rng.Stream(config.Seed or 1, "workload"),
		-- userId -> { ServerIndex, Player, Tokens }
		--
		-- `Tokens` holds the player's writes that Scribe has NOT yet confirmed
		-- durable, and every ack path below empties it. That invariant is what makes
		-- Crash correct: it hands the whole list to Model.NoteCrashLoss, whose
		-- contract is "the caller has established these were never durable". Leave
		-- the list unpruned and a crash silently un-acknowledges writes Scribe
		-- already promised -- which is exactly the failure an acknowledged-write
		-- checker exists to catch, quietly disabled inside the checker itself.
		_players = {},
		_nextUserId = config.FirstUserId or 10000,
		-- Weights for one step. Joins dominate early because the population has to
		-- exist before anything interesting can happen to it.
		Weights = config.Weights or { Join = 0.35, Mutate = 0.40, Leave = 0.15, Hop = 0.10 },
		MaxPlayers = config.MaxPlayers or 40,
		Stats = { Joins = 0, Mutations = 0, Leaves = 0, Hops = 0, Crashes = 0, FlushOk = 0, FlushRefused = 0 },
	}, Workload)
end

local function liveServers(self)
	local out = {}
	for index, server in self._uni.Servers do
		if not server.Dead then
			table.insert(out, index)
		end
	end
	return out
end

local function activePlayers(self)
	local out = {}
	for userId in self._players do
		table.insert(out, userId)
	end
	-- Sorted: `pairs` order is not stable, and drawing from it would make the
	-- workload depend on hash layout rather than on the seed.
	table.sort(out)
	return out
end

function Workload.Join(self, FakePlayer)
	local servers = liveServers(self)
	if #servers == 0 then
		return
	end
	local userId = self._nextUserId
	self._nextUserId += 1

	local index = servers[self._rng:NextInteger(#servers)]
	local player = FakePlayer.new(userId)
	self._uni:Server(index):Join(userId, player)
	self._players[userId] = { ServerIndex = index, Player = player, Tokens = {} }
	self.Stats.Joins += 1
	return userId
end

--- Append one self-describing op to a player's log.
---
--- The mutation is an APPEND rather than an arithmetic change, so two writes can
--- never cancel each other out and hide a lost update.
function Workload.Mutate(self, userId: number)
	local record = self._players[userId]
	if record == nil then
		return
	end
	local server = self._uni:Server(record.ServerIndex)
	if server.Dead then
		return
	end

	-- Data.Get RAISES for a player whose load has not finished, and for one whose
	-- session was stolen out from under them. Both are ordinary states in a
	-- contended workload rather than errors -- a player who is not loaded yet
	-- simply cannot be mutated -- so this skips rather than failing the run.
	local ok, data = pcall(function()
		return server.Bundle.Data.Get(record.Player)
	end)
	if not ok or data == nil or data.Log == nil then
		return
	end

	local token = self._model:NextOp(userId, server.JobId)
	local current = data.Log.Get()
	-- Bounded: the field has a MaxLength, and a log that overflowed it would be
	-- rejected by the template rather than by anything being tested here.
	if #current + #token + 1 > 900 then
		return
	end
	data.Log.Set(if current == "" then token else `{current};{token}`)
	self._model:Stage(userId, token)
	table.insert(record.Tokens, token)
	self.Stats.Mutations += 1
	return token
end

--- Leave, and acknowledge the player's writes ONLY once the save is confirmed.
---
--- The acknowledgement has to come from Scribe, not from the workload's own
--- optimism. An earlier version acked the moment it called Leave, which claims
--- durability nobody promised -- and under fault injection the closing save can
--- genuinely fail. The checker then reported those writes as LOST UPDATES, which
--- looked exactly like a Scribe consistency bug and was not one: the model had
--- simply asserted something the system never said.
---
--- Data.Flush returns false on timeout or failure, and that is the signal. A
--- write it did not confirm stays STAGED, so losing it is not held against the
--- run -- which is the correct reading, because nothing ever called it durable.
function Workload.Leave(self, userId: number)
	local record = self._players[userId]
	if record == nil then
		return
	end
	-- Removed first, so no further mutation can land after the flush snapshot.
	self._players[userId] = nil
	self.Stats.Leaves += 1

	local server = self._uni:Server(record.ServerIndex)
	if server.Dead then
		return
	end

	-- Spawned: Flush yields, and the workload is driven from a thread that must
	-- never park inside Scribe.
	self._uni.Sched:Spawn(function()
		-- pcall because a player whose session was stolen mid-flight cannot be
		-- flushed at all; that is a legitimate outcome, not an error, and their
		-- writes simply stay unacknowledged.
		local ok, result = pcall(function()
			return server.Bundle.Data.Flush(record.Player, { Timeout = 30 })
		end)
		local durable = ok and result == true
		if durable then
			for _, token in record.Tokens do
				self._model:Ack(userId, token)
			end
			record.Tokens = {} -- see the note on _players: acked is no longer losable
			self.Stats.FlushOk += 1
		else
			self.Stats.FlushRefused += 1
		end
		server:Leave(userId)
	end)
end
--- Ask Scribe to make a player's writes durable NOW, mid-run, and acknowledge
--- them only if it says yes.
---
--- This is the one call that makes the acknowledgement criterion load-bearing,
--- and it is worth saying why Leave is not enough. Leave acks and then leaves --
--- and the leaving save persists everything regardless of what Flush reported, so
--- a Scribe that LIED about durability is indistinguishable from one that did not.
--- Measured: with Flush's save removed entirely, 129 of 149 commits still landed
--- and the checker still reported zero violations.
---
--- Here the flush is the only save that could cover these tokens, because the
--- caller crashes the server immediately afterwards. A false "durable" therefore
--- becomes a LostUpdate rather than being quietly repaired by the next autosave.
---
--- Spawned, like Leave: Flush yields, and the workload is driven from a thread
--- that must never park inside Scribe.
function Workload.FlushNow(self, userId: number)
	local record = self._players[userId]
	if record == nil then
		return
	end
	local server = self._uni:Server(record.ServerIndex)
	if server.Dead then
		return
	end
	self._uni.Sched:Spawn(function()
		local ok, result = pcall(function()
			return server.Bundle.Data.Flush(record.Player, { Timeout = 30 })
		end)
		if ok and result == true then
			for _, token in record.Tokens do
				self._model:Ack(userId, token)
			end
			record.Tokens = {}
			self.Stats.FlushOk += 1
		else
			self.Stats.FlushRefused += 1
		end
	end)
end

--- Move a player to a DIFFERENT live server, the way a teleport does: the
--- destination starts loading while the source still holds the session, and the
--- source then releases.
---
--- The source release is the half this did not have, and its absence was not a
--- modelling choice that happened to be lossy -- it made sessions IMMORTAL. Nothing
--- ever told the old server the player had gone, so under injected faults the
--- destination's load could not steal a lock the source kept refreshing, gave up at
--- START_SESSION_TIMEOUT, and the source autosaved that profile for the rest of the
--- run. Measured before this: one leaked session in the CI-scale run and three at
--- soak scale, all still `Ready` after every player had left.
---
--- The overlap is kept deliberately -- join first, release second -- because that is
--- the window a real teleport has and it is what exercises the session-steal path.
function Workload.Hop(self, userId: number, FakePlayer)
	local record = self._players[userId]
	if record == nil then
		return
	end
	local candidates = {}
	for _, index in liveServers(self) do
		if index ~= record.ServerIndex then
			table.insert(candidates, index)
		end
	end
	if #candidates == 0 then
		return -- only one server alive; a same-server rejoin would raise
	end

	local target = candidates[self._rng:NextInteger(#candidates)]
	local from = self._uni:Server(record.ServerIndex)
	local player = FakePlayer.new(userId)
	self._uni:Server(target):Join(userId, player)
	from:Leave(userId)
	record.ServerIndex = target
	record.Player = player
	self.Stats.Hops += 1
end

--- Kill a server, and account for what its players lose.
---
--- Everything staged but not acked on that server is recorded as crash loss, not
--- as a violation: those writes were never reported durable, and holding the run
--- to them would fail every crash scenario by construction.
function Workload.Crash(self, index: number)
	local server = self._uni:Server(index)
	if server == nil or server.Dead then
		return
	end
	for userId, record in self._players do
		if record.ServerIndex == index then
			self._model:NoteCrashLoss(userId, record.Tokens)
			self._players[userId] = nil
		end
	end
	self._uni:Crash(index)
	self.Stats.Crashes += 1
end

--- Take one weighted step.
function Workload.Step(self, FakePlayer)
	local roll = self._rng:NextNumber()
	local players = activePlayers(self)

	if roll < self.Weights.Join and #players < self.MaxPlayers then
		return self:Join(FakePlayer)
	end
	if #players == 0 then
		return self:Join(FakePlayer)
	end

	local userId = players[self._rng:NextInteger(#players)]
	roll -= self.Weights.Join
	if roll < self.Weights.Mutate then
		return self:Mutate(userId)
	end
	roll -= self.Weights.Mutate
	if roll < self.Weights.Leave then
		return self:Leave(userId)
	end
	return self:Hop(userId, FakePlayer)
end

--- Ack everything still outstanding, for the end of a run where every player has
--- left cleanly and the world has settled.
function Workload.AckAll(self)
	for userId, record in self._players do
		for _, token in record.Tokens do
			self._model:Ack(userId, token)
		end
		record.Tokens = {}
	end
end

function Workload.Players(self)
	return self._players
end

return Workload
