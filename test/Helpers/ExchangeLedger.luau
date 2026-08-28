--!nonstrict
-- The conservation gate for ClaimExchange, and the ONE definition of conservation.
--
-- Roughly thirty specs in this suite hand-roll "and nothing was duplicated", and no
-- two of them agree on what that means. This module states it once, over the
-- MODELLED DISK, so every exchange spec measures the same thing.
--
-- THE INVARIANT. For every tracked object O, at every instant:
--
--     SPENDABLE(O) + ESCROWED(O) + INBOXED(O) + TAKE_HELD(O) == 1
--
-- with the verdict naming which of the two candidate locations is the owner.
-- SPENDABLE(O) <= 1 falls out as a theorem rather than being the axiom, and that
-- ordering matters: stated the other way round the gate is RED on correct code for
-- the whole interval between the stake and the delivery, and the relief that
-- presents itself is exactly the relaxation that disarms it.
--
-- WHY OVER THE DISK AND NOT "REACHABLE BY GAME CODE". Scribe cannot promise
-- reachability for a game container: Get() hands back the live stored table (pinned
-- by ExchangeSubstrateFacts) and game code holding an alias can put an item back after
-- it was staked. That is a real residual, documented rather than defended against.
-- The gate's job is to DETECT it, which it can only do by reading bytes.
--
-- OWNERSHIP, WHICH IS THE PART THAT NEEDS THE VERDICT. A leg sitting in a record's
-- Escrow was given BY that profile; a leg in its Take is owed TO it. Both exist at
-- once between 0.5 and the settle, on purpose, because the taker's copy must be
-- durable before a verdict can exist. So exactly one of the pair is the owner:
--
--   no verdict yet   the Escrow owns it; the Take is a pre-positioned copy
--   Commit           the Take owns it; the Escrow is a GHOST, owed for deletion
--   Abort            the Escrow owns it; the Take is a ghost
--
-- A ghost is excused only while its record is still there to owe the deletion. An
-- unbacked copy is not a ghost, it is a duplicate, and it counts.
--
-- WHY A SUM IS NOT ENOUGH, checked separately from the total. A quantity field with no
-- declared Min can be debited past zero: Scribe.Int(0) compiles Min = nil
-- (Template.luau:780-782) and validateWrite skips its bounds clause entirely when min is
-- nil (Node.luau:1106-1115). So a debit of 1000 against 100 stores -900, and a gate that
-- only sums holdings reads -900 + 1000 == 100 and calls that conserved while 1000 real
-- units were minted. A NEGATIVE HOLDING IS NOT A HOLDING. It is a liability nothing can
-- collect, and it evaporates the moment any ordinary write floors the field, taking the
-- evidence with it. So it fails the gate on its own, independent of any total.
local Root = script.Parent.Parent.Parent
local Template = require(Root.Scribe.Internal.Template)

local ExchangeLedger = {}

local RESERVED = Template.RESERVED_ROOT
local VERDICT_STORE = "ClaimExchangeVerdicts"

ExchangeLedger.VerdictStore = VERDICT_STORE

-- A leg, as escrow, take and inbox payloads all carry it. Fixed here because the
-- gate has to read the shape before applyLeg exists to write it.
export type Leg = {
	Path: { string }, -- container or field path in game data
	Kind: string, -- "Key" for a unique object, "Qty" for a fungible amount
	Key: string?, -- Key legs
	Amount: number?, -- Qty legs
	Value: any?, -- the payload moved for a Key leg
}

export type Object = {
	Kind: string, -- "Unique", "Fungible" or "Stack"
	Path: { string },
	Id: string?, -- Unique and Stack: the container key
	Count: string?, -- Stack: the element field holding how many. nil for a scalar element.
	Total: number?, -- Fungible and Stack: the conserved sum across both profiles
}

local function pathKey(path: { string }): string
	return table.concat(path, ".")
end

--- Walk a game-data path and return what is stored at it, or nil.
local function atPath(data: any, path: { string }, id: string?): any
	local node = data
	for _, segment in path do
		if type(node) ~= "table" then
			return nil
		end
		node = node[segment]
	end
	if id == nil then
		return node
	end
	if type(node) ~= "table" then
		return nil
	end
	return node[id]
end

--- What is stored under a player's key on the modelled disk, by Scribe's own key
--- function. Nil when the key was never written, which is a different finding from
--- an empty profile and must not read as one.
function ExchangeLedger.diskData(uni: any, server: any, userId: number): any
	local key = server.Bundle.Ctx.Persistence.KeyFor(userId)
	local record = uni.Disk.Keyspace:Read("Default", key)
	if record == nil or record.Value == nil then
		return nil
	end
	return record.Value.Data
end

--- The committed verdict for an exchange, or nil while none has been proposed.
function ExchangeLedger.diskVerdict(uni: any, exchangeId: string): any
	local record = uni.Disk.Keyspace:Read(VERDICT_STORE, exchangeId)
	if record == nil then
		return nil
	end
	return record.Value
end

--- Both profiles and every verdict they refer to, read off the modelled disk.
---
--- Exchange ids are collected from the profiles rather than passed in, so a record
--- nobody expected still gets its verdict read and still takes part in the count.
function ExchangeLedger.snapshot(uni: any, server: any, userIds: { number }): any
	local profiles, exchangeIds = {}, {}
	for _, userId in userIds do
		local data = ExchangeLedger.diskData(uni, server, userId)
		profiles[userId] = data
		local reserved = if type(data) == "table" then data[RESERVED] else nil
		if type(reserved) == "table" then
			for _, container in { reserved.Exchange, reserved.ExchangeInbox } do
				if type(container) == "table" then
					for exchangeId in container do
						exchangeIds[exchangeId] = true
					end
				end
			end
		end
	end

	local verdicts = {}
	for exchangeId in exchangeIds do
		verdicts[exchangeId] = ExchangeLedger.diskVerdict(uni, exchangeId)
	end
	return { Profiles = profiles, Verdicts = verdicts, UserIds = userIds }
end

--- Does this leg carry the object being tracked?
local function legHolds(leg: any, object: Object): boolean
	if type(leg) ~= "table" or type(leg.Path) ~= "table" then
		return false
	end
	if pathKey(leg.Path) ~= pathKey(object.Path) then
		return false
	end
	if object.Kind == "Unique" then
		return leg.Key == object.Id
	end
	if object.Kind == "Stack" then
		-- Keyed AND amounted. A Key leg on the same container carries the whole entry
		-- and no Amount, so it would otherwise read as zero and hide a whole stack.
		return leg.Key == object.Id and type(leg.Amount) == "number"
	end
	return type(leg.Amount) == "number"
end

--- What a payload holds of one object: 1 per leg for a Unique, the amount for a
--- Fungible.
local function payloadHolding(payload: any, object: Object): number
	if type(payload) ~= "table" then
		return 0
	end
	local held = 0
	for _, leg in payload do
		if legHolds(leg, object) then
			held += if object.Kind == "Unique" then 1 else leg.Amount :: number
		end
	end
	return held
end

--- The full balance sheet for one object: what each bucket holds, on which
--- profile, and which holdings the verdict designates as owned.
---
--- The Where list is why a failure is readable. A bare count says two copies exist
--- and says nothing about where to look, and the point of the gate is that a
--- failure names the bug.
function ExchangeLedger.census(snapshot: any, object: Object): any
	local owned, ghosts, where, negative = 0, 0, {}, {}

	local function note(bucket: string, userId: number, amount: number, isOwner: boolean, exchangeId: string?)
		if amount < 0 then
			local at = if exchangeId then `{userId}/{exchangeId}` else tostring(userId)
			table.insert(negative, `{bucket}[{at}]={amount}`)
		end
		if amount == 0 then
			return
		end
		if isOwner then
			owned += amount
		else
			ghosts += amount
		end
		local at = if exchangeId then `{userId}/{exchangeId}` else tostring(userId)
		table.insert(where, `{bucket}[{at}]={amount}{if isOwner then "" else " GHOST"}`)
	end

	for _, userId in snapshot.UserIds do
		local data = snapshot.Profiles[userId]
		if type(data) ~= "table" then
			continue
		end

		-- SPENDABLE: game data, the only place game code can spend from.
		local stored = atPath(data, object.Path, object.Id)
		if object.Kind == "Unique" then
			note("game", userId, if stored ~= nil then 1 else 0, true)
		elseif object.Kind == "Stack" then
			-- The count is a FIELD of the element, or the element itself when the
			-- container holds bare numbers. An absent key holds zero, not nothing:
			-- a stack that was fully moved away must still be counted as gone.
			local held = if object.Count == nil
				then stored
				else (if type(stored) == "table" then stored[object.Count] else nil)
			note("game", userId, if type(held) == "number" then held else 0, true)
		elseif type(stored) == "number" then
			note("game", userId, stored, true)
		end

		local reserved = data[RESERVED]
		if type(reserved) ~= "table" then
			continue
		end

		-- ESCROWED and TAKE_HELD: both live in one record and the verdict picks
		-- between them. Both are counted even when one is a ghost, because an
		-- unaccounted ghost is how a duplicate hides.
		if type(reserved.Exchange) == "table" then
			for exchangeId, record in reserved.Exchange do
				if type(record) ~= "table" then
					continue
				end
				local verdict = snapshot.Verdicts[exchangeId]
				local decision = if type(verdict) == "table" then verdict.V else nil
				note("escrow", userId, payloadHolding(record.Escrow, object), decision ~= "Commit", exchangeId)
				note("take", userId, payloadHolding(record.Take, object), decision == "Commit", exchangeId)
			end
		end

		-- INBOXED: past the settle, so the verdict already designated it.
		--
		-- A settle writes the entry as a RECORD wrapping its legs, not as a bare list:
		-- `{ Id, Verdict, Legs, SettledAt }`. Reading the record as if it were the list
		-- finds no legs and silently counts zero, which reads as value destroyed. The
		-- bare-list form is still tolerated because a hand-planted fixture may use it,
		-- but the wrapper is what the implementation actually writes.
		if type(reserved.ExchangeInbox) == "table" then
			for exchangeId, entry in reserved.ExchangeInbox do
				local payload = if type(entry) == "table" and type(entry.Legs) == "table" then entry.Legs else entry
				note("inbox", userId, payloadHolding(payload, object), true, exchangeId)
			end
		end
	end

	table.sort(where)
	table.sort(negative)
	return { Owned = owned, Ghosts = ghosts, Where = where, Negative = negative }
end

--- A one-line balance sheet, for an expect() that has to print.
function ExchangeLedger.describe(snapshot: any, object: Object): string
	local id = if object.Kind == "Unique" then `{pathKey(object.Path)}/{object.Id}` else pathKey(object.Path)
	local census = ExchangeLedger.census(snapshot, object)
	local neg = if #census.Negative > 0 then ` negative=[{table.concat(census.Negative, " ")}]` else ""
	return `{id} owned={census.Owned} ghosts={census.Ghosts} [{table.concat(census.Where, " ")}]{neg}`
end

--- Raise unless every tracked object has exactly one owner.
---
--- Raises rather than returning false so a caller cannot quietly ignore it, and
--- carries the balance sheet in the message so the failure names the location
--- rather than only the count.
function ExchangeLedger.assertConserved(snapshot: any, objects: { Object }, label: string?)
	local failures = {}
	for _, object in objects do
		local census = ExchangeLedger.census(snapshot, object)
		local expected = if object.Kind == "Unique" then 1 else object.Total :: number
		-- Before the total, and separately from it: a negative holding is exactly what
		-- makes a total look right while value has been minted.
		if #census.Negative > 0 then
			table.insert(failures, `negative holding, {ExchangeLedger.describe(snapshot, object)}`)
		end
		if census.Owned ~= expected then
			table.insert(failures, `expected {expected}, found {ExchangeLedger.describe(snapshot, object)}`)
		end
	end
	if #failures > 0 then
		local at = if label then ` at {label}` else ""
		error(`ExchangeLedger: conservation violated{at}: {table.concat(failures, " | ")}`, 2)
	end
end

return ExchangeLedger
