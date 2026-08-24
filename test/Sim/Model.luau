--!nonstrict
-- The reference model: what SHOULD be on disk, checked against what is.
--
-- WRITES ARE NON-COMMUTATIVE AND SELF-DESCRIBING, and that is the whole design.
-- The obvious workload -- add and remove coins -- is commutative, so a lost update
-- that happens to cancel against another is invisible to any checker comparing
-- totals. Instead every mutation APPENDS a `{writer}:{seq}` token to a log inside
-- the profile, so each write leaves a distinct, attributable trace.
--
-- That turns the invariant into something checkable without knowing an expected
-- value: every acknowledged op appears EXACTLY ONCE. Missing means a lost update;
-- twice means a double-apply, which is precisely what an Indeterminate write
-- produces when ProfileStore retries a save that had already committed.
--
-- Two tiers, because "written" and "durable" are different claims:
--   STAGED  applied locally; may or may not survive
--   ACKED   Scribe reported the write durable, so losing it is a violation
--
-- Data lost across a CRASH is recorded and reported, never asserted. Writes after
-- the last save are legitimately gone, and failing a run for them would train
-- everyone to ignore the checker.

local Model = {}
Model.__index = Model

-- Elle's vocabulary, because these are the same phenomena a transactional
-- consistency checker names, and inventing new words for them would only make the
-- results harder to compare with the literature.
export type ViolationKind =
	"LostUpdate" -- an acked op is absent from the final state
	| "DuplicateWrite" -- an op appears more than once
	| "GarbageRead" -- the state contains a token nobody wrote
	| "AbortedRead" -- a staged-but-failed op is visible (G1a)
	| "IntermediateRead" -- a value from mid-transaction is visible (G1b)

function Model.new()
	return setmetatable({
		-- userId -> { Staged = {token -> true}, Acked = {token -> true}, Order = {token} }
		_players = {},
		_seq = 0,
		Violations = {},
		-- Recorded, not asserted: writes a crash took with them.
		CrashLoss = {},
	}, Model)
end

local function playerState(self, userId: number)
	local state = self._players[userId]
	if state == nil then
		state = { Staged = {}, Acked = {}, Order = {} }
		self._players[userId] = state
	end
	return state
end

--- Mint the next op token for a player on a given server.
function Model.NextOp(self, _userId: number, jobId: string): string
	self._seq += 1
	return `{jobId}#{self._seq}`
end

--- Record an op as applied locally but not yet known durable.
function Model.Stage(self, userId: number, token: string)
	local state = playerState(self, userId)
	state.Staged[token] = true
	table.insert(state.Order, token)
end

--- Promote an op to durable. Losing it after this is a violation.
function Model.Ack(self, userId: number, token: string)
	local state = playerState(self, userId)
	state.Staged[token] = nil
	state.Acked[token] = true
end

--- Everything a player's log should contain if nothing was lost.
function Model.Expected(self, userId: number): { string }
	local state = playerState(self, userId)
	local out = {}
	for _, token in state.Order do
		if state.Acked[token] then
			table.insert(out, token)
		end
	end
	return out
end

--- Parse a stored log back into tokens.
function Model.Parse(log: string?): { string }
	local out = {}
	if log == nil or log == "" then
		return out
	end
	for token in string.gmatch(log, "[^;]+") do
		table.insert(out, token)
	end
	return out
end

--- Compare a player's observed log against the model.
---
--- Returns the violations found, and also records them, so a soak can assert on an
--- empty list at the end rather than after each check.
function Model.Verify(self, userId: number, observedLog: string?): { any }
	local state = playerState(self, userId)
	local observed = Model.Parse(observedLog)

	local seen = {}
	local found = {}

	for _, token in observed do
		seen[token] = (seen[token] or 0) + 1
	end

	for token, count in seen do
		if count > 1 then
			table.insert(found, {
				Kind = "DuplicateWrite" :: ViolationKind,
				UserId = userId,
				Token = token,
				Detail = `appears {count} times`,
			})
		end
		if state.Acked[token] == nil and state.Staged[token] == nil then
			-- A token nobody ever staged. Either the model lost track or the disk
			-- invented data; both are worth failing on.
			table.insert(found, {
				Kind = "GarbageRead" :: ViolationKind,
				UserId = userId,
				Token = token,
			})
		end
	end

	for token in state.Acked do
		if seen[token] == nil then
			table.insert(found, {
				Kind = "LostUpdate" :: ViolationKind,
				UserId = userId,
				Token = token,
				Detail = "acknowledged durable, absent from the stored log",
			})
		end
	end

	for _, violation in found do
		table.insert(self.Violations, violation)
	end
	return found
end

--- Record writes a crash legitimately took with it.
function Model.NoteCrashLoss(self, userId: number, tokens: { string })
	for _, token in tokens do
		table.insert(self.CrashLoss, { UserId = userId, Token = token })
	end
	-- Un-ack them: they were never durable, and holding them against the run
	-- afterwards would report expected behaviour as corruption.
	local state = playerState(self, userId)
	for _, token in tokens do
		state.Acked[token] = nil
	end
end

-- Errors a soak may legitimately encounter. An EXACT-STRING table rather than a
-- chain of `string.find`, because a substring match quietly grows to cover
-- failures nobody meant to allow -- and the point of an allowlist is that
-- everything not on it fails the run.
Model.BENIGN_ERRORS = {
	["301: GetAsync request dropped. Request was throttled, but throttled request queue was full."] = true,
	["302: SetAsync request dropped. Request was throttled, but throttled request queue was full."] = true,
	["303: UpdateAsync request dropped. Request was throttled, but throttled request queue was full."] = true,
	["306: RemoveAsync request dropped. Request was throttled, but throttled request queue was full."] = true,
	["502: API Services rejected request with error. Status=Forbidden"] = true,
	["504: Datastore request timed out."] = true,
}

function Model.IsBenign(message: string): boolean
	return Model.BENIGN_ERRORS[message] == true
end

return Model
