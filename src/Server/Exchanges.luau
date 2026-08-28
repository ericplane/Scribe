--!strict
-- The ClaimExchange subsystem: what owns the verdict key, the in-flight set, and the
-- resolution that runs on every load. The primitives underneath are dependency-injected
-- so the specs can drive them against a modelled disk; this layer is thin on purpose and
-- only decides what the real server passes them.
--
-- Resolution runs on load because an exchange can be interrupted at any point and its two
-- profiles may never be on one server again. Every position has to reach a terminal state
-- on its own, and a load is the one moment a profile is guaranteed to be looked at. The
-- cadence exists for sessions that never end.
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")

local Internal = script.Parent.Parent.Internal
local Clock = require(Internal.Clock)
local Profile = require(Internal.Profile)
local Log = require(Internal.Log)
local Rng = require(Internal.Rng)
local Sched = require(Internal.Sched)
local Exchange = require(Internal.Exchange)
local ExchangeLeg = require(Internal.ExchangeLeg)
local ExchangeVerdict = require(Internal.ExchangeVerdict)

local Exchanges = {}

-- How often the sweep looks, and how old a record must be before it will touch it.
--
-- The age floor is not a tuning knob. A live attempt writes its records and then yields
-- through two forced flushes, and a sweep resolving them mid-attempt would propose Abort
-- against an exchange about to commit. The in-flight set covers that on THIS server but
-- not on another, which sees only the record, so the floor has to exceed the attempt's
-- own deadline.
local SWEEP_INTERVAL = 30
local RESOLVE_AGE_FLOOR = 60

--- An in-memory stand-in for the verdict key, with the SAME contract.
---
--- First writer wins and the transform never returns nil: a Mock or NoSave bundle that
--- behaved differently would make exchanges resolve one way in Studio and another in
--- production.
local function newMockVerdictStore()
	local keys: { [string]: any } = {}
	return {
		UpdateAsync = function(_self, key: string, transform: (any) -> any)
			local value = transform(keys[key])
			if value == nil then
				return nil, nil
			end
			keys[key] = value
			return value, nil
		end,
		GetAsync = function(_self, key: string)
			return keys[key], nil
		end,
	}
end

function Exchanges.new(ctx: any)
	local self = {} :: any

	-- Read the RESOLVED mode rather than the option, the same way Leaderboards does:
	-- Persistence turns Mode into its own fields and never writes it back, so a
	-- Mode = "Mock" bundle would otherwise reach a real DataStore.
	local mode: string = ctx.Persistence.Mode
	local useMock: boolean = mode == "Mock" or mode == "NoSave"
	local storeHandle: any = nil
	local stopped = false
	local sweepThread: thread? = nil

	-- exchangeId per userId, for THIS server only. The cheap local check, never the
	-- authority: the record answers the same question durably.
	local inFlight: { [number]: string } = {}

	self.UsesMockStore = useMock
	self.InFlight = inFlight

	-- Refused at STARTUP, by name, so a misconfigured game fails to boot rather than
	-- discovering the problem when two players are mid-exchange and value is in escrow.
	-- Logged as well as raised: the raise stops the boot, and the log entry makes the
	-- refusal a filterable diagnostic rather than only a stack trace, which matters when
	-- it surfaces from a place-start in someone else's CI.
	local refuseOk, refusal = pcall(ExchangeLeg.Refuse, ctx.Compiled, ctx.Options.Exchangeable)
	if not refuseOk then
		Log.Error("Exchanges", "EXCHANGE_REGISTRATION_REFUSED", tostring(refusal), {})
		error(refusal, 0)
	end

	-- Indexed once, and READ on every basket. The startup refusal above proves the
	-- declarations are safe to move; on its own it gated a list nothing consulted, so
	-- a caller could hand Attempt any path the template declared.
	local approved = ExchangeLeg.Approve(ctx.Options.Exchangeable)

	--- The verdict key's store, acquired lazily: a bundle that never exchanges should not
	--- touch DataStoreService at all, and the acquisition can throw on a server with no data
	--- access.
	function self.VerdictStore(): any
		if storeHandle ~= nil then
			return storeHandle
		end
		if useMock then
			storeHandle = newMockVerdictStore()
			return storeHandle
		end
		local ok, store = pcall(function()
			return DataStoreService:GetDataStore(ExchangeVerdict.STORE_NAME)
		end)
		if not ok or store == nil then
			-- No data access. Falling back to a mock would let exchanges "resolve" against a
			-- store nothing else can see, and the verdict is the one thing that must be global.
			Log.Error(
				"Exchanges",
				"EXCHANGE_STORE_UNAVAILABLE",
				`could not reach the verdict store: {tostring(store)}`,
				{}
			)
			return nil
		end
		storeHandle = store
		return storeHandle
	end

	--- The side descriptor the resolver takes, built from a loaded entry.
	local function sideFor(entry: any): Exchange.Side
		return {
			Ctx = {
				Tree = entry.Tree,
				Entry = entry,
				Compiled = ctx.Compiled,
				UserId = entry.UserId,
				-- On the context, not in the escrow record: a parked delivery can
				-- outlive the server that staked it.
				Plans = approved,
			},
			UserId = entry.UserId,
			Legs = {},
		}
	end

	-- Conditions already announced, keyed by code and exchange id.
	--
	-- The sweep revisits a stranded exchange every thirty seconds and a parked delivery on
	-- every load, and an alarm repeating twice a minute buries the next one. A restart
	-- re-announces, which is correct: the condition lives on the key, not in this process.
	local announced: { [string]: boolean } = {}

	local function announce(code: any, exchangeId: string, message: string, context: any)
		local key = `{code}|{exchangeId}`
		if announced[key] then
			return
		end
		announced[key] = true
		Log.Warn("Exchanges", code, message, context)
	end

	--- Forget an exchange that reached a clean end, so a later one on the same id is heard.
	local function forget(exchangeId: string)
		announced[`EXCHANGE_UNRESOLVED|{exchangeId}`] = nil
		announced[`EXCHANGE_PARKED|{exchangeId}`] = nil
	end

	--- One exchange, carried to a terminal state and REPORTED. Returns whether it reached
	--- one.
	---
	--- Shared by the load path and the sweep because the sweep's copy drifted: it counted
	--- every call that did not RAISE, and ResolveOne returns nil with a reason rather than
	--- raising when it merely cannot resolve, so an unreachable verdict key was reported as
	--- resolved on every tick and logged nothing.
	local function resolveExchange(side: any, exchangeId: string, entry: any): boolean
		local store = self.VerdictStore()
		if store == nil then
			return false
		end
		local ok, outcome, err = pcall(Exchange.ResolveOne, { VerdictStore = store }, side, exchangeId)
		local context = { Player = entry.Player, ExchangeId = exchangeId }
		if not ok then
			Log.Error(
				"Exchanges",
				"EXCHANGE_RESOLVE_ERROR",
				`resolving "{exchangeId}" raised: {tostring(outcome)}`,
				context
			)
			return false
		end
		if outcome == nil then
			announce(
				"EXCHANGE_UNRESOLVED",
				exchangeId,
				`"{exchangeId}" could not be resolved: {tostring(err)}`,
				context
			)
			return false
		end

		-- A delivery that could not be applied stays in the inbox and is retried for ever,
		-- so nothing is lost, but it is invisible unless something says so. It is also the
		-- exact condition Redirect exists for.
		if side.Ctx.Tree.Reserved.ExchangeInbox[exchangeId].Get() ~= nil then
			announce("EXCHANGE_PARKED", exchangeId, `"{exchangeId}" settled but could not be delivered yet`, context)
		else
			forget(exchangeId)
		end
		Log.Info("Exchanges", "EXCHANGE_RESOLVED", `"{exchangeId}" resolved as {outcome}`, context)
		return true
	end

	--- Carry every exchange this profile still has business with to a terminal state.
	---
	--- Yields, and runs AFTER the profile is Ready: an exchange resolving a second into play
	--- is invisible, where a load waiting on a DataStore round trip would not be.
	function self.Resolve(entry: any): number
		if stopped or entry == nil or entry.Tree == nil or entry.Tree.Dead then
			return 0
		end
		local side = sideFor(entry)
		local open = Exchange.OpenExchangeIds(side)
		if #open == 0 then
			return 0
		end
		if self.VerdictStore() == nil then
			return 0
		end

		local resolved = 0
		for _, exchangeId in open do
			if stopped or entry.Tree.Dead then
				break
			end
			-- One exchange's failure must not strand the rest: a digest mismatch on one record
			-- is an operator problem, not a reason to leave another exchange's value in escrow.
			if resolveExchange(side, exchangeId, entry) then
				resolved += 1
			end
		end
		return resolved
	end

	--- Exchange ids an operator verb is currently working on. The sweep skips these: a verb
	--- reads state, decides and writes, and a sweep resolving the same exchange in between
	--- would act on state the verb had already ruled on.
	local operatorHold: { [string]: boolean } = {}
	self.OperatorHold = operatorHold

	--- The two userIds for an exchange, from a record plus whoever is loaded.
	local function participantsFor(record: any, sides: { any }): (number, number)
		local owner = if type(record.Owner) == "number" then record.Owner else sides[1].UserId
		local partner = if type(record.Partner) == "number" then record.Partner else owner
		if record.Role == "B" then
			return partner, owner
		end
		return owner, partner
	end

	--- Is this record old enough, and quiet enough, for the sweep to touch? Both guards are
	--- needed: the in-flight set knows only about attempts THIS server is running.
	local function sweepMayResolve(record: any, userId: number, exchangeId: string): boolean
		if inFlight[userId] ~= nil or operatorHold[exchangeId] then
			return false
		end
		local stakedAt = if type(record) == "table" then record.StakedAt else nil
		if type(stakedAt) ~= "number" then
			-- No timestamp: an inbox-only entry, or a record from before this field
			-- existed. Nothing is mid-attempt on it, so the floor has nothing to protect.
			return true
		end
		return (Clock.Now() - stakedAt) >= RESOLVE_AGE_FLOOR
	end

	--- One sweep over the profiles this server is holding, for sessions that never end: a
	--- load resolves what it finds, but a player who stays on for six hours after a
	--- counterparty vanished would otherwise wait six hours. Returns how many it resolved.
	function self.Sweep(): number
		if stopped then
			return 0
		end
		-- Snapshotted before any yield. The body yields on a store round trip, and adding a
		-- key to a table mid-traversal is undefined in Luau, so a player joining during a
		-- sweep could abandon the rest of the cycle in silence. Never reproduced: the copy
		-- removes the undefined behaviour rather than a measured defect.
		local entries = {}
		for _, entry in ctx.Persistence.Entries do
			table.insert(entries, entry)
		end

		local resolved = 0
		for _, entry in entries do
			if stopped then
				break
			end
			if entry.State == "Ready" and entry.Tree ~= nil and not entry.Tree.Dead then
				local side = sideFor(entry)
				for _, exchangeId in Exchange.OpenExchangeIds(side) do
					local record = entry.Tree.Reserved.Exchange[exchangeId].Get()
					if
						sweepMayResolve(record, entry.UserId, exchangeId) and resolveExchange(side, exchangeId, entry)
					then
						resolved += 1
					end
				end
			end
		end
		return resolved
	end

	local function sweepLoop()
		-- Its own long-lived thread, so what it allocates is attributable. Only Scribe's own
		-- background work: an accessor write runs on the game's calling thread and stays
		-- under the game's category.
		Profile.MemoryCategory("Scribe")
		-- Jittered so a shard restart does not put every server's sweep on the same
		-- second, which is how a quiet key becomes a throttled one.
		Clock.Wait(Rng.Jitter(SWEEP_INTERVAL))
		while not stopped do
			pcall(self.Sweep)
			Clock.Wait(Rng.Jitter(SWEEP_INTERVAL))
		end
	end

	function self.Start()
		if sweepThread == nil then
			sweepThread = Sched.Spawn(sweepLoop)
		end
	end

	--------------------------------------------------------------------------------
	-- Operator verbs
	--
	-- For the one case the automatic machinery cannot finish: a verdict key that is gone,
	-- or records that disagree, where a person has to decide. Every one is verdict-gated,
	-- because the verb that replaced the last catastrophic verb reintroduced its shape.
	--------------------------------------------------------------------------------

	--- Every loaded profile that has business with this exchange.
	local function sidesFor(exchangeId: string)
		local found = {}
		for _, entry in ctx.Persistence.Entries do
			if entry.State == "Ready" and entry.Tree ~= nil and not entry.Tree.Dead then
				local reserved = entry.Tree.Reserved
				if reserved.Exchange[exchangeId].Get() ~= nil or reserved.ExchangeInbox[exchangeId].Get() ~= nil then
					table.insert(found, sideFor(entry))
				end
			end
		end
		return found
	end

	--- Drop an abandoned exchange that never took value.
	---
	--- REFUSES IF ANY VERDICT EXISTS. The tempting precondition, "both records are present,
	--- so no side has settled", is true at the read and false at the write with a yielding
	--- store call in between; the verdict key is the only durable statement.
	function self.Discard(exchangeId: string): (boolean, string?)
		if type(exchangeId) ~= "string" or #exchangeId == 0 then
			return false, "discard needs an exchange id"
		end
		if operatorHold[exchangeId] then
			return false, "another operator verb is already holding this exchange"
		end
		operatorHold[exchangeId] = true

		local ok, result, reason = pcall(function(): (boolean, string?)
			local store = self.VerdictStore()
			if store == nil then
				return false, "the verdict store is unreachable, so no discard can be proved safe"
			end
			local verdict = ExchangeVerdict.Read(store, exchangeId)
			if verdict ~= nil then
				return false, `exchange "{exchangeId}" already has a {verdict.V} verdict; use settle, not discard`
			end

			local dropped = 0
			for _, side in sidesFor(exchangeId) do
				-- Phase is re-asserted INSIDE the write by Unclaim, not carried from the
				-- read above: the store call between them yields.
				if select(1, ExchangeLeg.Unclaim(side.Ctx, exchangeId)) then
					dropped += 1
				end
			end
			if dropped == 0 then
				return false, `nothing to discard: no loaded profile holds an unstaked claim for "{exchangeId}"`
			end
			return true, nil
		end)

		operatorHold[exchangeId] = nil
		if not ok then
			return false, tostring(result)
		end
		return result, reason
	end

	--- Force a verdict on an exchange that cannot resolve itself.
	---
	--- The verdict is REQUIRED. Inheriting the resolver's "propose Abort when the key is
	--- empty" would, in exactly the state this verb exists for, land a fresh Abort against a
	--- Commit the other side has already settled.
	function self.Settle(exchangeId: string, verdictKind: string?): (boolean, string?)
		if type(exchangeId) ~= "string" or #exchangeId == 0 then
			return false, "settle needs an exchange id"
		end
		if verdictKind ~= "Commit" and verdictKind ~= "Abort" then
			return false, "settle requires an explicit verdict of Commit or Abort; there is no safe default"
		end
		if operatorHold[exchangeId] then
			return false, "another operator verb is already holding this exchange"
		end
		operatorHold[exchangeId] = true

		local ok, result, reason = pcall(function(): (boolean, string?)
			local store = self.VerdictStore()
			if store == nil then
				return false, "the verdict store is unreachable"
			end
			local sides = sidesFor(exchangeId)
			if #sides == 0 then
				return false, `no loaded profile has business with "{exchangeId}"`
			end
			local record = nil
			for _, side in sides do
				record = record or side.Ctx.Tree.Reserved.Exchange[exchangeId].Get()
			end
			if record == nil then
				return false, `"{exchangeId}" has no record to settle; only an inbox entry, which delivers on its own`
			end

			-- Commit is not the peer of Abort. A Commit drops each profile's escrow, safe only
			-- because the counterparty took a durable copy first, and the Take is the evidence.
			-- Both checks below run BEFORE the proposal because the verdict key is permanent and
			-- first-writer-wins: proposing Commit and only then finding the settle cannot be
			-- applied marks the exchange Commit for ever. Abort needs neither check, because
			-- returning an escrow to its owner needs no counterparty at all.
			if verdictKind == "Commit" then
				if #sides < 2 then
					return false,
						`"{exchangeId}" needs both sides loaded to Commit: the verdict binds the absent profile too and `
							.. "this server cannot prove its take was ever filled. Abort is safe from one side"
				end
				for _, side in sides do
					local held = side.Ctx.Tree.Reserved.Exchange[exchangeId].Get()
					if
						held ~= nil
						and type(held.Take) ~= "table"
						and type(held.Escrow) == "table"
						and next(held.Escrow) ~= nil
					then
						return false,
							`"{exchangeId}" holds escrow for {side.UserId} with no take recorded; a Commit would destroy `
								.. "it. Abort returns it to its owner"
					end
				end
			end

			local userIdA, userIdB = participantsFor(record, sides)
			local verdict = ExchangeVerdict.Propose(store, exchangeId, {
				V = verdictKind,
				A = userIdA,
				B = userIdB,
				D = record.Digest,
			})
			if verdict == nil then
				return false, "no verdict could be established"
			end
			for _, side in sides do
				pcall(ExchangeLeg.Settle, side.Ctx, exchangeId, verdict)
				pcall(ExchangeLeg.Deliver, side.Ctx, exchangeId)
			end
			return true, `settled as {verdict.V}`
		end)

		operatorHold[exchangeId] = nil
		if not ok then
			return false, tostring(result)
		end
		return result, reason
	end

	--- Re-point a parked delivery at a different key on the same container.
	---
	--- The park that needs this is a destination that is occupied and stays occupied. Only
	--- the KEY moves, so a redirect cannot land value on a path registration never vetted.
	function self.Redirect(exchangeId: string, userId: number, newKey: string): (boolean, string?)
		if type(exchangeId) ~= "string" or type(newKey) ~= "string" or #newKey == 0 then
			return false, "redirect needs an exchange id and a new key"
		end
		if operatorHold[exchangeId] then
			return false, "another operator verb is already holding this exchange"
		end
		-- TAKEN, not merely tested for. This verb checked the hold and never set it, so a
		-- sweep could run underneath: it rewrites a key and then delivers, and a resolution
		-- landing between those two acts on state the verb has already ruled on.
		operatorHold[exchangeId] = true

		local ok, result, reason = pcall(function(): (boolean, string?)
			for _, side in sidesFor(exchangeId) do
				if side.UserId == userId then
					local parked = side.Ctx.Tree.Reserved.ExchangeInbox[exchangeId].Get()
					if type(parked) ~= "table" or type(parked.Legs) ~= "table" then
						return false, `"{exchangeId}" has no parked delivery for {userId}`
					end

					-- ONE leg, named by nothing but being the only one. The rewrite used
					-- to point EVERY key leg at the new key, so a two item basket came out
					-- with both legs naming one key: never deliverable, and never
					-- recoverable, because no later redirect can tell them apart again.
					local target = nil
					local count = 0
					-- Stack legs count too: a mixed basket would otherwise collapse a Key
					-- and a Stack leg onto one destination.
					for index, leg in parked.Legs do
						if leg.Kind == "Key" or leg.Kind == "Stack" then
							count += 1
							target = target or index
						end
					end
					if count == 0 then
						return false, `"{exchangeId}" has no key leg to redirect`
					end
					if count > 1 then
						return false,
							`"{exchangeId}" holds more than one key leg, and one new key cannot name {count} `
								.. "destinations without collapsing them onto each other"
					end

					local rekeyable, whyNot = ExchangeLeg.Rekeyable(ctx.Compiled, parked.Legs[target].Path)
					if not rekeyable then
						return false, `"{exchangeId}" cannot be redirected: {tostring(whyNot)}`
					end

					side.Ctx.Tree.Reserved.ExchangeInbox[exchangeId].Legs[target].Key.Set(newKey)
					local delivered = select(1, ExchangeLeg.Deliver(side.Ctx, exchangeId))
					return true,
						if delivered
							then `redirected to "{newKey}" and delivered`
							else `redirected to "{newKey}", still parked`
				end
			end
			return false, `no loaded profile holds a parked delivery for "{exchangeId}"`
		end)

		operatorHold[exchangeId] = nil
		if not ok then
			return false, tostring(result)
		end
		return result, reason
	end

	--- Every leg in this basket is one the game declared exchangeable.
	---
	--- THE TRUST BOUNDARY. Baskets enter the library here, and an exchange UI naturally
	--- builds them from what a client asked for. It runs before any slot is claimed and
	--- before any value moves, so a refused basket costs the player nothing.
	local function approveBasket(basket: any): (boolean, string?)
		if basket == nil then
			return true, nil
		end
		if type(basket) ~= "table" then
			return false, "each basket must be a list of legs"
		end
		for _, leg in basket do
			local okLeg, whyLeg = ExchangeLeg.ApprovedLeg(approved, leg)
			if not okLeg then
				return false, whyLeg
			end
		end
		return true, nil
	end

	--- Begin an exchange between two players on this server.
	---
	--- Yields. Returns "Committed", "Aborted", or nil with a reason.
	function self.Attempt(playerA: Player, basketA: { any }, playerB: Player, basketB: { any }): (string?, string?)
		local entryA = ctx.Persistence.Entries[playerA]
		local entryB = ctx.Persistence.Entries[playerB]
		if entryA == nil or entryB == nil or entryA.State ~= "Ready" or entryB.State ~= "Ready" then
			return nil, "both players must be loaded on this server"
		end
		-- The allowlist, enforced on the basket. Checked one basket at a time rather than
		-- through a `{ basketA, basketB }` literal, because a nil first basket makes that
		-- literal iterate nothing and skips both.
		local okA, whyA = approveBasket(basketA)
		if not okA then
			return nil, whyA
		end
		local okB, whyB = approveBasket(basketB)
		if not okB then
			return nil, whyB
		end

		local store = self.VerdictStore()
		if store == nil then
			return nil, "the verdict store is unreachable"
		end

		local sideA = sideFor(entryA)
		local sideB = sideFor(entryB)
		sideA.Legs = basketA or {}
		sideB.Legs = basketB or {}

		return Exchange.Attempt({
			ExchangeId = `{entryA.UserId}-{entryB.UserId}-{HttpService:GenerateGUID(false)}`,
			VerdictStore = store,
			InFlight = inFlight,
			Options = ctx.Options.Exchange,
			Flush = function(side)
				local player = if side.UserId == entryA.UserId then playerA else playerB
				return ctx.Persistence.Flush(player, { Force = true, Timeout = 8 })
			end,
		}, sideA, sideB)
	end

	--- What this player still has in flight, and what it is holding while it does.
	function self.Open(player: Player): { Exchange.OpenExchange }
		local entry = ctx.Persistence.Entries[player]
		if entry == nil or entry.Tree == nil or entry.Tree.Dead then
			return {}
		end
		return Exchange.OpenExchanges(sideFor(entry))
	end

	--- The load hook. Named separately from Resolve so the hook contract and the
	--- operator-facing call cannot drift apart.
	function self.OnLoad(entry: any)
		self.Resolve(entry)
	end

	function self.Stop()
		if stopped then
			return
		end
		stopped = true
		-- Cancelled as well as flagged: a parked loop would otherwise hold a thread per
		-- bundle until its next wake.
		if sweepThread ~= nil then
			pcall(task.cancel, sweepThread)
			sweepThread = nil
		end
		table.clear(inFlight)
	end

	return self
end

return Exchanges
