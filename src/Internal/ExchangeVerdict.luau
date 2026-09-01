--!strict
-- The verdict key: the single point of no return for an exchange. Two players are two
-- DataStore keys with no multi-key transaction, so ONE key decides and everything after
-- it is infallible or infinitely retryable. The only property owed: every participant,
-- on every server, on every retry, reads the SAME answer.
--
-- First writer wins and the loser learns from the return value. The transform never
-- returns nil: that aborts the write and yields (nil, nil), which the caller cannot tell
-- from "nothing happened". Indeterminate is not special: a proposer that never learned
-- its proposal won has not settled, and the next proposal reads the committed answer.
local Clock = require(script.Parent.Clock)

local ExchangeVerdict = {}

ExchangeVerdict.STORE_NAME = "ClaimExchangeVerdicts"

export type Verdict = {
	V: string, -- "Commit" or "Abort"
	A: number, -- userId of role A
	B: number, -- userId of role B
	D: string, -- basket digest
	HA: string?, -- content hash of A's take payload
	HB: string?,
	T: number, -- when the winner decided
}

local function fail(message: string): ()
	error(`ExchangeVerdict: {message}`, 0)
end

--- Is this a verdict record, rather than something else that happens to be stored?
local function wellFormed(value: any): boolean
	return type(value) == "table"
		and (value.V == "Commit" or value.V == "Abort")
		and type(value.D) == "string"
		and type(value.A) == "number"
		and type(value.B) == "number"
end

--- Propose a verdict for an exchange, and return whatever verdict is now in force.
---
--- Returns the committed verdict and whether THIS call decided it. A caller almost never
--- needs the second value, since winner and loser take the identical branch; it is there
--- for metrics and for the abort path, which logs differently when it lost to a Commit.
---
--- Yields. Never call it with a transaction open.
function ExchangeVerdict.Propose(store: any, exchangeId: string, proposal: any): (any, boolean, string?)
	if type(store) ~= "table" and type(store) ~= "userdata" then
		fail("Propose needs a DataStore")
	end
	if type(exchangeId) ~= "string" or #exchangeId == 0 then
		fail("Propose needs an exchange id")
	end
	if not wellFormed(proposal) then
		fail("Propose needs a well-formed verdict of Commit or Abort")
	end

	local decided = false
	local ok, committed = pcall(function()
		return store:UpdateAsync(exchangeId, function(old)
			-- NEVER nil. See the header: a nil return aborts the write and the caller
			-- gets (nil, nil), which is indistinguishable from a failure.
			if old ~= nil then
				return old
			end
			decided = true
			return {
				V = proposal.V,
				A = proposal.A,
				B = proposal.B,
				D = proposal.D,
				HA = proposal.HA,
				HB = proposal.HB,
				T = Clock.Now(),
			}
		end)
	end)

	if not ok then
		-- Includes the indeterminate case, where the write may well have landed. The
		-- caller must NOT treat this as "no verdict exists"; it means "no verdict is
		-- KNOWN", and the next proposal settles which.
		return nil, false, tostring(committed)
	end
	if committed == nil then
		return nil, false, "verdict store returned nothing, which should be unreachable"
	end
	if not wellFormed(committed) then
		return nil, false, "verdict key holds a malformed record"
	end
	-- `decided` is set inside the transform, which can run more than once under
	-- contention; the return value is the authority on WHAT was decided, and this
	-- flag only reports whether the last transform pass wrote.
	return committed, decided and committed.T ~= nil, nil
end

--- Read the verdict in force, without proposing one.
---
--- Nil means no verdict this read can see, which is not the same as "no verdict exists":
--- a proposal that landed indeterminately may still be unread. Only a proposal settles it.
function ExchangeVerdict.Read(store: any, exchangeId: string): (any, string?)
	if type(exchangeId) ~= "string" or #exchangeId == 0 then
		fail("Read needs an exchange id")
	end
	local ok, value = pcall(function()
		return store:GetAsync(exchangeId)
	end)
	if not ok then
		return nil, tostring(value)
	end
	if value == nil then
		return nil, nil
	end
	if not wellFormed(value) then
		return nil, "verdict key holds a malformed record"
	end
	return value, nil
end

--- Does this verdict govern this exchange, for this pair, on this basket? A mismatch is
--- corruption, not an expected branch, and the caller must refuse to settle rather than
--- settle against the wrong basket.
function ExchangeVerdict.Matches(verdict: any, digest: string, userIdA: number, userIdB: number): (boolean, string?)
	if not wellFormed(verdict) then
		return false, "malformed verdict"
	end
	if verdict.D ~= digest then
		return false, "digest mismatch"
	end
	if verdict.A ~= userIdA or verdict.B ~= userIdB then
		return false, "participant mismatch"
	end
	return true, nil
end

return ExchangeVerdict
