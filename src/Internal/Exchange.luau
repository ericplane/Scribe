--!strict
-- ClaimExchange orchestration: one same-server exchange, start to finish.
--
-- Everything fallible happens BEFORE the verdict. After it there are two kinds of step:
-- SETTLE, which writes only under the reserved root and cannot be refused by any shape,
-- cap or bound; and DELIVER, which can fail but rolls back and is retried for ever.
-- Never decide what happened from a pcall boundary: every step re-reads the record out
-- of the tree, and the pcall result only picks which question to ask.
--
-- The taker's payload is durable on its own key BEFORE any verdict exists (both forced
-- flushes return true first), so a Commit that drops the giver's escrow cannot destroy
-- the only copy. The flushes are not an optimisation.
local Clock = require(script.Parent.Clock)
local Util = require(script.Parent.Util)
local ExchangeLeg = require(script.Parent.ExchangeLeg)
local ExchangeVerdict = require(script.Parent.ExchangeVerdict)

local Exchange = {}

local DEFAULT_DEADLINE = 20

--- One leg, in the shape something player-facing needs and nothing more.
---
--- No digest, no role, no payload: the payload is the stored form and may be packed, so
--- handing it out would put buffers in front of game code for no benefit.
export type OpenLeg = {
	Path: { string | number },
	Kind: string,
	Key: any?,
	Amount: number?,
}

--- What a profile still has in flight, and what it is holding while it does.
export type OpenExchange = {
	Id: string,
	State: "Claimed" | "Staked" | "Delivering",
	Partner: number?,
	Staked: { OpenLeg }, -- what this profile handed over
	Owed: { OpenLeg }, -- what this profile is owed
	Since: number?,
}

export type Side = {
	Ctx: any, -- the ExchangeLeg context for this player
	UserId: number,
	Legs: { any }, -- what this side GIVES
}

local function fail(message: string): ()
	error(`Exchange: {message}`, 0)
end

--- A stable digest over the basket, so a verdict can only settle the exchange it names.
--- Order-independent per side and then concatenated, because two servers must derive the
--- identical string from the identical basket.
local function digestOf(exchangeId: string, sideA: Side, sideB: Side): string
	local parts = {}
	for _, side in { sideA, sideB } do
		local legs = {}
		for _, leg in side.Legs do
			table.insert(legs, `{table.concat(leg.Path, ".")}|{leg.Kind}|{tostring(leg.Key)}|{tostring(leg.Amount)}`)
		end
		table.sort(legs)
		table.insert(parts, `{side.UserId}:{table.concat(legs, ";")}`)
	end
	return `{exchangeId}#{table.concat(parts, "#")}`
end

--- The record this profile currently holds for the exchange, read fresh. The only thing
--- allowed to decide what state a side is in.
local function recordOf(side: Side, exchangeId: string): any
	return side.Ctx.Tree.Reserved.Exchange[exchangeId].Get()
end

--- Run a step and decide from the TREE whether it landed, never from the call.
---
--- `landed` is given the record as it stands afterwards. The pcall result supplies the
--- message and nothing else, because `raised == false` has five causes in Node and only
--- ONE is "committed": a dead tree, a nested transaction, a transaction open on another
--- player, a failed rollback where the tree may be partly restored, and a throw from OnOp
--- or OnEconomy where the writes already committed. That last one is dispatched after
--- `_txn` is cleared, so a listener that throws would otherwise make this module abandon
--- a slot it genuinely holds, or re-run a stake that has already moved value.
local function stepped(
	side: Side,
	exchangeId: string,
	run: () -> (boolean, string?),
	landed: (record: any) -> boolean
): (boolean, string?)
	local pok, ok, err = pcall(run)
	local record = recordOf(side, exchangeId)
	if landed(record) then
		return true, nil
	end
	local reason = if pok then tostring(err) else tostring(ok)
	return false, `{reason} (record={if record == nil then "absent" else tostring(record.Phase)})`
end

--- The record exists at all: what a claim leaves behind.
local function isClaimed(record: any): boolean
	return record ~= nil
end

--- The record is holding staked value: what an escrow leaves behind. A stake that
--- rolled back leaves the CLAIM, so testing for the record alone would read a failed
--- stake as a successful one.
local function isStaked(record: any): boolean
	return record ~= nil and record.Phase == "Staked"
end

--- The record carries what this profile is owed: what filling a take leaves behind.
local function hasTake(record: any): boolean
	return record ~= nil and type(record.Take) == "table"
end

--- Admission: everything that can refuse an exchange for free, before any value moves.
local function admit(sideA: Side, sideB: Side, options: any, inFlight: any): (boolean, string?)
	if sideA.UserId == sideB.UserId then
		return false, "a player cannot exchange with themselves"
	end
	if #sideA.Legs == 0 and #sideB.Legs == 0 then
		return false, "an exchange must move something"
	end
	for _, side in { sideA, sideB } do
		-- The record below is the durable check, and it is BLIND for a long ordinary
		-- window: Settle removes it, and two resolve flushes and two deliveries all yield
		-- afterwards, so a second exchange admitted in that window sees an empty
		-- container. The in-flight set is the only thing covering that on this server.
		if inFlight ~= nil and inFlight[side.UserId] ~= nil then
			return false, `player {side.UserId} already has an exchange in flight`
		end
		if side.Ctx == nil or side.Ctx.Tree == nil or side.Ctx.Tree.Dead then
			return false, `player {side.UserId} has no live profile`
		end
		local exchange = side.Ctx.Tree.Reserved.Exchange.Get()
		if type(exchange) == "table" and next(exchange) ~= nil then
			return false, `player {side.UserId} already has an exchange in flight`
		end
		-- The inbox is untyped and so has no cap of its own, and unbounded accumulation
		-- ends in a profile that cannot save.
		local inbox = side.Ctx.Tree.Reserved.ExchangeInbox.Get()
		local pending = 0
		if type(inbox) == "table" then
			for _ in inbox do
				pending += 1
			end
		end
		local cap = if options and options.MaxInbox then options.MaxInbox else 8
		if pending >= cap then
			return false, `player {side.UserId} has {pending} undelivered exchanges, at the cap of {cap}`
		end
	end
	return true, nil
end

--- Attempt one exchange between two loaded, same-server players.
---
--- Yields. Returns (outcome, err) where outcome is "Committed", "Aborted" or nil.
function Exchange.Attempt(deps: any, sideA: Side, sideB: Side): (string?, string?)
	if type(deps) ~= "table" or deps.VerdictStore == nil or type(deps.Flush) ~= "function" then
		fail("Attempt needs a VerdictStore and a Flush")
	end
	local exchangeId = deps.ExchangeId
	if type(exchangeId) ~= "string" or #exchangeId == 0 then
		fail("Attempt needs an exchange id")
	end

	local admitted, why = admit(sideA, sideB, deps.Options, deps.InFlight)
	if not admitted then
		return nil, why
	end

	local digest = digestOf(exchangeId, sideA, sideB)
	local deadline = Clock.Monotonic() + (deps.Deadline or DEFAULT_DEADLINE)
	local inFlight = deps.InFlight

	-- Registered BEFORE the first claim, not after the escrows. A deferred ancestor
	-- listener can yield on this thread after each commit, so registering later leaves
	-- the same-server guard blind for the whole construction window.
	if inFlight ~= nil then
		inFlight[sideA.UserId] = exchangeId
		inFlight[sideB.UserId] = exchangeId
	end

	-- Cleared by OWNERSHIP, never by user id alone. The set maps a userId to the exchange
	-- that registered it, and deleting by id deletes whatever that player currently
	-- holds, which after the settle window above can be a different, live exchange.
	local function release()
		if inFlight ~= nil then
			if inFlight[sideA.UserId] == exchangeId then
				inFlight[sideA.UserId] = nil
			end
			if inFlight[sideB.UserId] == exchangeId then
				inFlight[sideB.UserId] = nil
			end
		end
	end

	-- 0.3 CLAIM BOTH, no yield between them, so neither profile ever advertises a free
	-- slot while the other is already committed to this exchange.
	local okA = stepped(sideA, exchangeId, function()
		return ExchangeLeg.Claim(sideA.Ctx, exchangeId, { Digest = digest, Role = "A", Partner = sideB.UserId })
	end, isClaimed)
	if not okA then
		release()
		return nil, "could not claim the first slot"
	end
	local okB, whyB = stepped(sideB, exchangeId, function()
		return ExchangeLeg.Claim(sideB.Ctx, exchangeId, { Digest = digest, Role = "B", Partner = sideA.UserId })
	end, isClaimed)
	if not okB then
		-- A claim carries no value, so releasing it here is safe and is the ONLY place
		-- in this function where a record is dropped without a verdict.
		pcall(ExchangeLeg.Unclaim, sideA.Ctx, exchangeId)
		release()
		return nil, `could not claim the second slot: {tostring(whyB)}`
	end

	--- Give up before any verdict exists. Free, because escrowed value is returned by
	--- unclaiming a record that never took any, and a record that DID take value is
	--- left for the verdict-gated abort below.
	local function abandon(reason: string): (string?, string?)
		for _, side in { sideA, sideB } do
			local record = recordOf(side, exchangeId)
			if record ~= nil and record.Phase == "Claimed" then
				pcall(ExchangeLeg.Unclaim, side.Ctx, exchangeId)
			end
		end
		-- Anything that reached "Staked" holds value and must go through the verdict.
		local staked = false
		for _, side in { sideA, sideB } do
			local record = recordOf(side, exchangeId)
			if record ~= nil then
				staked = true
			end
		end
		if not staked then
			release()
			return nil, reason
		end
		return Exchange.Resolve(deps, sideA, sideB, exchangeId, digest, "Abort", reason)
	end

	-- 0.4 to 0.6 ESCROW BOTH SIDES, then fill each side's Take from the OTHER side's
	-- escrow, so what a taker receives is provably what the giver actually gave up.
	if #sideA.Legs > 0 then
		local ok = stepped(sideA, exchangeId, function()
			return ExchangeLeg.Escrow(sideA.Ctx, exchangeId, sideA.Legs)
		end, isStaked)
		if not ok then
			return abandon("could not stake the first side")
		end
	end
	if #sideB.Legs > 0 then
		local ok = stepped(sideB, exchangeId, function()
			return ExchangeLeg.Escrow(sideB.Ctx, exchangeId, sideB.Legs)
		end, isStaked)
		if not ok then
			return abandon("could not stake the second side")
		end
	end

	local recordA, recordB = recordOf(sideA, exchangeId), recordOf(sideB, exchangeId)
	if recordA == nil or recordB == nil then
		return abandon("a stake vanished before the takes could be filled")
	end
	local takeForA = if recordB.Escrow ~= nil then recordB.Escrow else {}
	local takeForB = if recordA.Escrow ~= nil then recordA.Escrow else {}

	local okTakeB = stepped(sideB, exchangeId, function()
		return ExchangeLeg.FillTake(sideB.Ctx, exchangeId, takeForB)
	end, hasTake)
	if not okTakeB then
		return abandon("could not record the second side's take")
	end
	local okTakeA = stepped(sideA, exchangeId, function()
		return ExchangeLeg.FillTake(sideA.Ctx, exchangeId, takeForA)
	end, hasTake)
	if not okTakeA then
		return abandon("could not record the first side's take")
	end

	-- 0.8 and 0.9 FORCED FLUSHES, which YIELD. These are the ordering proof: no verdict
	-- can exist until both takes are durable. A false is UNRESOLVED, never "failed":
	-- Force is per-entry and a concurrent autosave can consume it. pcalled because a
	-- raise means the same thing a false does, and unguarded it left Attempt with both
	-- records staked, no verdict proposed and both in-flight registrations still held,
	-- which admission now reads as a permanent exchanging ban for both players.
	local okFlushA, flushedA = pcall(deps.Flush, sideA)
	local okFlushB, flushedB = pcall(deps.Flush, sideB)
	if not okFlushA or not okFlushB or flushedA ~= true or flushedB ~= true then
		return Exchange.Resolve(deps, sideA, sideB, exchangeId, digest, "Abort", "a stake could not be proved durable")
	end
	if Clock.Monotonic() > deadline then
		return Exchange.Resolve(deps, sideA, sideB, exchangeId, digest, "Abort", "the attempt passed its deadline")
	end

	return Exchange.Resolve(deps, sideA, sideB, exchangeId, digest, "Commit", nil)
end

--- Propose a verdict and carry both profiles to their terminal state. Separated from
--- Attempt because this is exactly what a later load or cadence tick runs to finish an
--- exchange nobody is watching any more.
function Exchange.Resolve(
	deps: any,
	sideA: Side,
	sideB: Side,
	exchangeId: string,
	digest: string,
	proposed: string,
	note: string?
): (string?, string?)
	-- Released by OWNERSHIP, never by user id alone, on every exit including the ones
	-- that give up. See the registration in Attempt.
	local function release()
		if deps.InFlight == nil then
			return
		end
		if deps.InFlight[sideA.UserId] == exchangeId then
			deps.InFlight[sideA.UserId] = nil
		end
		if deps.InFlight[sideB.UserId] == exchangeId then
			deps.InFlight[sideB.UserId] = nil
		end
	end

	local verdict, _decided, err = ExchangeVerdict.Propose(deps.VerdictStore, exchangeId, {
		V = proposed,
		A = sideA.UserId,
		B = sideB.UserId,
		D = digest,
	})
	if verdict == nil then
		-- No verdict is KNOWN, which is not the same as none existing. The records stay
		-- exactly as they are and the next resolution settles which.
		release()
		return nil, `no verdict could be established: {tostring(err)}`
	end

	local matches, whyNot = ExchangeVerdict.Matches(verdict, digest, sideA.UserId, sideB.UserId)
	if not matches then
		-- Corruption, not an expected branch. Refuse to settle and leave both records in
		-- place for an operator rather than move value nobody agreed to move.
		--
		-- The registrations are still RELEASED: the sweep skips any player named in the set,
		-- so holding them would silence the one exchange that needs a human to look at it.
		release()
		return nil, `verdict does not govern this exchange: {tostring(whyNot)}`
	end

	-- 0.12 SETTLE BOTH. Infallible by construction; a failure here is a bug, not a
	-- data-dependent refusal, and it leaves the record for the next resolution.
	for _, side in { sideA, sideB } do
		pcall(ExchangeLeg.Settle, side.Ctx, exchangeId, verdict)
	end

	-- 0.13 and 0.14. A false from these flushes is unresolved, not failed, and delivery
	-- failures PARK rather than failing the exchange.
	pcall(deps.Flush, sideA)
	pcall(deps.Flush, sideB)
	for _, side in { sideA, sideB } do
		pcall(ExchangeLeg.Deliver, side.Ctx, exchangeId)
	end

	release()

	local outcome = if verdict.V == "Commit" then "Committed" else "Aborted"
	return outcome, note
end

--- Who the two participants are, from one side's own record.
---
--- A resolution usually runs with only ONE profile loaded, so the userIds cannot come
--- from the caller. Role says which side this profile is and Partner is the other.
--- Getting it backwards fails the Matches check rather than settling the wrong exchange.
local function participantsOf(record: any, ownerId: number): (number, number)
	local partner = record.Partner
	if type(partner) ~= "number" then
		return ownerId, ownerId
	end
	if record.Role == "B" then
		return partner, ownerId
	end
	return ownerId, partner
end

--- Carry ONE profile's side of an exchange to its terminal state, without the
--- counterparty. What a load or a cadence tick runs. Safe alone because settle and
--- delivery are per-profile and idempotent: the verdict key is first-writer-wins, so
--- the other side reaches the identical verdict whenever it next looks. Proposes ABORT
--- when no verdict exists, the conserving default. Yields; never call it with a
--- transaction open.
function Exchange.ResolveOne(deps: any, side: Side, exchangeId: string): (string?, string?)
	if type(deps) ~= "table" or deps.VerdictStore == nil then
		fail("ResolveOne needs a VerdictStore")
	end
	if type(exchangeId) ~= "string" or #exchangeId == 0 then
		fail("ResolveOne needs an exchange id")
	end

	local record = recordOf(side, exchangeId)
	if record == nil then
		-- No record: either nothing was ever staked here, or this side has already
		-- settled. Either way an inbox entry may still be waiting, and delivering it is
		-- the whole reason a resolution runs on every load.
		pcall(ExchangeLeg.Deliver, side.Ctx, exchangeId)
		return "Settled", nil
	end

	local userIdA, userIdB = participantsOf(record, side.UserId)
	local digest = record.Digest
	if type(digest) ~= "string" then
		return nil, `exchange "{exchangeId}" has no digest to settle against`
	end

	local verdict, _decided, err = ExchangeVerdict.Propose(deps.VerdictStore, exchangeId, {
		V = "Abort",
		A = userIdA,
		B = userIdB,
		D = digest,
	})
	if verdict == nil then
		-- No verdict is KNOWN, which is not the same as none existing. Nothing may be
		-- released and the record stays as it is.
		return nil, `no verdict could be established: {tostring(err)}`
	end

	local matches, whyNot = ExchangeVerdict.Matches(verdict, digest, userIdA, userIdB)
	if not matches then
		return nil, `verdict does not govern this exchange: {tostring(whyNot)}`
	end

	-- Settle then deliver, both per-profile. A settle that reverts and re-runs from the
	-- same verdict produces the identical result.
	pcall(ExchangeLeg.Settle, side.Ctx, exchangeId, verdict)
	pcall(ExchangeLeg.Deliver, side.Ctx, exchangeId)

	return (if verdict.V == "Commit" then "Committed" else "Aborted"), nil
end

--- One leg, copied out rather than aliased.
local function openLeg(leg: any): OpenLeg
	return {
		Path = if type(leg.Path) == "table" then table.clone(leg.Path) else {},
		Kind = tostring(leg.Kind),
		-- An array leg's key IS its value and may be a table, so it is cloned rather
		-- than handed out of the reserved root by reference.
		Key = if type(leg.Key) == "table" then Util.deepClone(leg.Key) else leg.Key,
		Amount = if type(leg.Amount) == "number" then leg.Amount else nil,
	}
end

local function openLegs(legs: any): { OpenLeg }
	local out = {}
	if type(legs) == "table" then
		for _, leg in legs do
			if type(leg) == "table" then
				table.insert(out, openLeg(leg))
			end
		end
	end
	return out
end

--- Everything this profile still has in flight, WITH what it is holding.
---
--- Escrow takes value out of the balance on purpose, and the resolution time is
--- deliberately not bounded, so a player whose exchange stalls has to be shown what they
--- staked and what they are owed. The game cannot read either otherwise: the ledger is
--- ServerOnly and the accessor refuses reserved-root reads.
---
--- Every table returned is freshly built. Nothing here aliases the reserved root.
function Exchange.OpenExchanges(side: Side): { OpenExchange }
	local reserved = side.Ctx.Tree.Reserved
	local records = reserved.Exchange.Get() :: { [string]: any }?
	local inbox = reserved.ExchangeInbox.Get() :: { [string]: any }?
	local byId: { [string]: OpenExchange } = {}
	local ids: { string } = {}

	if type(records) == "table" then
		for exchangeId, record in records do
			if type(record) == "table" then
				byId[exchangeId] = {
					Id = exchangeId,
					State = if record.Phase == "Staked" then "Staked" else "Claimed",
					Partner = if type(record.Partner) == "number" then record.Partner else nil,
					Staked = openLegs(record.Escrow),
					Owed = openLegs(record.Take),
					Since = if type(record.StakedAt) == "number" then record.StakedAt else nil,
				}
				table.insert(ids, exchangeId)
			end
		end
	end

	-- An inbox entry outranks the record: it means the verdict landed and the only
	-- thing left is putting the value somewhere, which is a different thing to tell a
	-- player than "still being agreed".
	if type(inbox) == "table" then
		for exchangeId, entry in inbox do
			if type(entry) == "table" then
				-- Bound non-optional up front rather than assigned inside the nil
				-- branch: an assignment there does not narrow the local, so every use
				-- below would still carry the optional.
				local existing: OpenExchange? = byId[exchangeId]
				local open: OpenExchange = existing
					or {
						Id = exchangeId,
						State = "Delivering",
						Partner = nil,
						Staked = {},
						Owed = {},
						Since = nil,
					}
				if existing == nil then
					byId[exchangeId] = open
					table.insert(ids, exchangeId)
				end
				open.State = "Delivering"
				open.Owed = openLegs(entry.Legs)
				if type(entry.SettledAt) == "number" then
					open.Since = entry.SettledAt
				end
			end
		end
	end

	table.sort(ids)
	local out = {}
	for _, exchangeId in ids do
		table.insert(out, byId[exchangeId])
	end
	return out
end

function Exchange.OpenExchangeIds(side: Side): { string }
	local ids, seen = {}, {}
	local reserved = side.Ctx.Tree.Reserved
	for _, container in { reserved.Exchange.Get(), reserved.ExchangeInbox.Get() } do
		if type(container) == "table" then
			for exchangeId in container do
				if not seen[exchangeId] then
					seen[exchangeId] = true
					table.insert(ids, exchangeId)
				end
			end
		end
	end
	table.sort(ids)
	return ids
end

return Exchange
