--!nonstrict
-- The modelled DataStore backend: one shared key space, served to many simulated
-- servers through a DataStoreService-shaped facade.
--
-- Scope note. This file and its siblings model the STORAGE, not the library above
-- it: the real vendored ProfileStore runs unmodified on top, so the session-lock
-- protocol, the autosave engine and the retry backoff are exercised rather than
-- imitated. What is modelled here is exactly the part a test double normally
-- fakes away -- optimistic concurrency, size limits, latency, and failure.
--
-- Budget, throughput and fault injection arrive in a later step; `Admit` and
-- `ChargeThroughput` are the seams they slot into, and are deliberately present
-- as no-ops now so the call sites in Store are written once and never moved.

local Keyspace = require(script.Keyspace)
local Latency = require(script.Latency)
local Store = require(script.Store)
local Ordered = require(script.Ordered)
local Errors = require(script.Errors)
local Size = require(script.Size)
local Budget = require(script.Budget)
local Throughput = require(script.Throughput)
local Faults = require(script.Faults)

local Disk = {}
Disk.__index = Disk

Disk.Errors = Errors
Disk.Size = Size
Disk.LIMITS = { ValueBytes = Size.VALUE_BYTES }

export type Config = {
	Sched: any,
	Rng: any, -- the "disk.latency" stream; see Latency
	VersionRng: any?, -- the "disk.versionid" stream
	LatencyProfile: string?,
	ValueBytes: number?, -- override; a real 4 MB profile is not buildable in a test budget
	UserIdLimit: number?,
	MaxTransformAttempts: number?,
	StrictTransform: boolean?,
	FaultRng: any?, -- the "disk.fault" stream
	BudgetMode: string?, -- "Trickle" (default) or "Bucket"
	PlayerCount: ((jobId: string) -> number)?,
	CCU: (() -> number)?,
	NoBudget: boolean?, -- unit specs that are not about budgets
}

function Disk.new(config: Config)
	local rng = config.Rng
	return setmetatable({
		Config = config,
		Keyspace = Keyspace.new(),
		Latency = Latency.new(rng, config.LatencyProfile),
		Stats = {
			Reads = 0,
			Writes = 0,
			Removes = 0,
			Conflicts = 0,
			Transforms = 0,
			SizeDivergence = nil,
		},
		_sched = config.Sched,
		-- Version ids get their OWN stream. They land in persisted data and reach
		-- the digest, so drawing them from the latency stream would make every
		-- stored id depend on how many latencies happened to be drawn first.
		_versionRng = config.VersionRng or rng,
		_versionCounter = 0,
		_inFlight = 0,
		_stores = {},
		_ordered = {},
		_defaultJob = "sim-server",
		-- Counted because the answer is itself a finding: see the note on
		-- GetRequestBudgetForRequestType below.
		BudgetQueries = 0,
		Budget = Budget.new({
			Sched = config.Sched,
			Mode = config.BudgetMode,
			PlayerCount = config.PlayerCount,
			CCU = config.CCU,
		}),
		Throughput = Throughput.new({ Sched = config.Sched }),
		Faults = Faults.new({ Rng = config.FaultRng or config.Rng }),
	}, Disk)
end

--------------------------------------------------------------------------------
-- Time and identity
--------------------------------------------------------------------------------

function Disk.Now(self): number
	return self._sched.Now
end

--- Yield for `seconds` of virtual time, counting the operation as in flight.
---
--- In-flight accounting is separate from the scheduler's own liveness check, and
--- both are needed. The scheduler answers "did every thread finish"; this answers
--- "did every request complete". A run can satisfy one and not the other -- a
--- request abandoned mid-flight leaves no live thread -- and a simulation that
--- checked only the first would call that clean.
function Disk.Wait(self, seconds: number)
	self._inFlight += 1
	self._sched:Wait(seconds)
	self._inFlight -= 1
end

function Disk.InFlight(self): number
	return self._inFlight
end

--- Mint a version id: deterministic, unique, and visibly not a real GUID.
function Disk.MintVersionId(self): string
	self._versionCounter += 1
	return string.format("%08x-%06d", self._versionRng:NextInteger(0xFFFFFFF), self._versionCounter)
end

--------------------------------------------------------------------------------
-- Seams for the budget / throughput / fault layers
--------------------------------------------------------------------------------

--- Admission control for one request.
---
--- Order matters and is fixed: local validation has already happened (it is free
--- and client-side), so this is where the request pays. Budget first, because a
--- request that cannot be admitted never reaches the backend and therefore cannot
--- fail in any other way.
function Disk.Admit(self, jobId: string, kind: string, op: string)
	if self.Config.NoBudget then
		return true
	end
	self.Budget:Admit(jobId or self._defaultJob, kind, op)
	return true
end

--- Let the budget queue serve whoever is next. Called when a request completes.
function Disk.Release(self)
	if self.Config.NoBudget then
		return
	end
	self.Budget:Release()
end

--- Decide whether this request suffers an injected fault.
---
--- Returns the kind, or nil. The caller applies it, because WHERE a fault lands
--- is the whole distinction between a failed write and an indeterminate one.
function Disk.NextFault(self, op: string, store: string, key: string): string?
	return self.Faults:Next(op, store, key)
end

--- Arm an exact fault. See Faults.
function Disk.Arm(self, spec)
	self.Faults:Arm(spec)
end

function Disk.SetFaultRate(self, rates)
	self.Faults:SetRate(rates)
end

--- Return the world to health, so a soak can assert the system RECOVERS.
function Disk.Heal(self)
	self.Faults:Heal()
end

--- Record bytes moved on a key, for the per-key throughput window.
function Disk.ChargeThroughput(self, store: string, key: string, direction: string, bytes: number)
	self.Throughput:Charge(`{#store}:{store}:{key}`, direction, bytes)
end

--- Would this request breach the key's throughput window?
function Disk.WouldThrottleKey(self, store: string, key: string, direction: string, bytes: number): boolean
	return self.Throughput:WouldExceed(`{#store}:{store}:{key}`, direction, bytes)
end
-- Which modelled pool(s) each engine request type spends from. Taken from where
-- the ops actually charge: Ordered.luau charges OrderedWrite / OrderedRead, and
-- Store.luau charges StandardRead for a get, StandardWrite for a set, and BOTH
-- for an UpdateAsync.
local POOL_FOR_REQUEST_TYPE: { [string]: { string } } = {
	GetAsync = { "StandardRead" },
	SetIncrementAsync = { "StandardWrite" },
	UpdateAsync = { "StandardRead", "StandardWrite" },
	GetSortedAsync = { "OrderedRead" },
	SetIncrementSortedAsync = { "OrderedWrite" },
}

--- The documented budget query.
---
--- A live finding rather than a modelling detail: NOTHING in Scribe or
--- ProfileStore ever calls this. Every save, receipt await, gift check, version
--- query and offline update is issued unbudgeted and scales linearly with CCU.
--- The budget model is what makes that visible.
function Disk.GetRequestBudgetForRequestType(self, kind: any, jobId: string?): number
	self.BudgetQueries += 1
	if self.Config.NoBudget then
		return math.huge
	end
	-- The engine names request TYPES; the budget models POOLS, and several types
	-- share one. Without this mapping the lookup used the Enum name as a pool key,
	-- which is never written, so every unstubbed query answered 0 no matter what
	-- the modelled allowance actually was -- a budget modelled in detail that its
	-- own query API could not read.
	local name = if type(kind) == "table" and kind.Name then kind.Name else tostring(kind)
	local pools = POOL_FOR_REQUEST_TYPE[name]
	if pools == nil then
		return 0
	end
	-- An UpdateAsync spends BOTH standard pools, so what it has left is whichever
	-- is scarcer. Reporting only one would promise headroom the other cannot honour.
	local least = math.huge
	for _, pool in pools do
		least = math.min(least, self.Budget:Peek(jobId or self._defaultJob, pool))
	end
	return math.floor(least)
end

--------------------------------------------------------------------------------
-- The DataStoreService surface
--------------------------------------------------------------------------------

function Disk.GetDataStore(self, name: string, scope: string?, _options: any?)
	if type(name) ~= "string" or name == "" or #name > 50 then
		Errors.Raise("KeyTooLong", "store name")
	end
	local cacheKey = `{name}\0{scope or ""}`
	local existing = self._stores[cacheKey]
	if existing == nil then
		existing = Store.new(self, name, scope)
		self._stores[cacheKey] = existing
	end
	return existing
end

function Disk.GetOrderedDataStore(self, name: string, scope: string?)
	if type(name) ~= "string" or name == "" or #name > 50 then
		Errors.Raise("KeyTooLong", "store name")
	end
	local cacheKey = `{#name}:{name}:{scope or ""}`
	local existing = self._ordered[cacheKey]
	if existing == nil then
		existing = Ordered.new(self, name, scope)
		self._ordered[cacheKey] = existing
	end
	return existing
end
--- A DataStoreService bound to one simulated server.
---
--- Per-server rather than shared because budget is charged per server, so the
--- backend has to know who is asking. The key space behind it is the same one for
--- everybody -- that part is the point.
function Disk.ServiceFor(self, jobId: string)
	local disk = self
	return {
		GetDataStore = function(_self, name: string, scope: string?, options: any?)
			local store = disk:GetDataStore(name, scope, options)
			-- Stores are cached per (name, scope); binding the requesting server
			-- onto the shared object would make the last caller win. A thin
			-- per-server view keeps the identity with the caller.
			return setmetatable({ _jobId = jobId }, { __index = store, __metatable = false })
		end,
		GetOrderedDataStore = function(_self, name: string, scope: string?)
			local store = disk:GetOrderedDataStore(name, scope)
			-- Same per-server view as the standard store: the ordered store is
			-- shared, but budget is charged to whoever asked.
			return setmetatable({ _jobId = jobId }, { __index = store, __metatable = false })
		end,
		GetRequestBudgetForRequestType = function(_self, kind: any)
			-- Threaded like _jobId on the stores above: without it the query peeked the
			-- default job while charges went to the caller's, so a server never saw its
			-- own drain.
			return disk:GetRequestBudgetForRequestType(kind, jobId)
		end,
	}
end

return Disk
