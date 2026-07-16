--!strict
-- Scribe — persistent, fully-typed, automatically-replicated player data for
-- Roblox Luau, built on ProfileStore.
--
-- One shared module declares the template and options and returns
-- { Server, Client }:
--
--   local Scribe = require(ReplicatedStorage.Packages.Scribe)
--   return Scribe({ Template = template, Transport = "Default" })
--
-- Requires the new Luau type solver for the typed accessor tree; the library
-- runs correctly without it (use `.Raw` as the untyped escape hatch).

local RunService = game:GetService("RunService")

local Types = require(script.Types)
local Util = require(script.Internal.Util)
local Marker = require(script.Internal.Marker)
local Template = require(script.Internal.Template)
local Log = require(script.Internal.Log)
local Metrics = require(script.Internal.Metrics)
local Health = require(script.Internal.Health)

export type ScribeTransport = Types.ScribeTransport
export type Op = Types.Op
export type LogEntry = Types.LogEntry
export type LogCode = Types.LogCode
export type LogLevel = Types.LogLevel
export type LogCategory = Types.LogCategory
export type Status = Types.Status
export type SaveInfo = Types.SaveInfo
export type LeaderboardEntry = Types.LeaderboardEntry
export type PassConfig = Types.PassConfig
export type PurchaseFilter = Types.PurchaseFilter
export type EconomyMeta = Types.EconomyMeta
export type EconomyConfig = Types.EconomyConfig
export type EconomyCurrencyConfig = Types.EconomyCurrencyConfig
export type EconomyFieldSpec = Types.EconomyFieldSpec
export type EconomyLogFn = Types.EconomyLogFn
-- LeaderboardConfig<T>, ProductConfig<T>, and PurchaseSpec<T> are defined
-- after the type functions below; they derive Stat/Cost paths and the Grant
-- accessor type from the template.

--------------------------------------------------------------------------------
-- The type function: walks the template type at type-check time and produces
-- the recursive typed accessor tree.
--------------------------------------------------------------------------------

-- selene: allow(undefined_variable) -- `types` is the type-function runtime library
export type function ValueType(T)
	local ts = types

	local nilType = ts.singleton(nil)

	local function optional(t: type): type
		return ts.unionof(t, nilType)
	end

	local anyType = ts.any
	local optBool = optional(ts.boolean)
	local optNumber = optional(ts.number)

	local function fn(params: { type }, rets: { type }): type
		return ts.newfunction({ head = params }, { head = rets })
	end

	local disconnectType = fn({}, {})

	local function widen(t: type): type
		if t:is("singleton") then
			local value = t:value()
			if type(value) == "boolean" then
				return ts.boolean
			elseif type(value) == "string" then
				return ts.string
			end
		end
		return t
	end

	local function build(rawType: type, isRoot: boolean): type
		local t = widen(rawType)

		-- Scribe.Timed fields carry a { __scribeTimed: V } marker type.
		local isTimed = false
		if t:is("table") then
			local inner = t:readproperty(ts.singleton("__scribeTimed"))
			if inner ~= nil then
				isTimed = true
				t = widen(inner)
			end
		end

		local props: { [type]: type } = {}
		local indexerSpec: { index: type, readresult: type, writeresult: type }? = nil

		local valueType = t
		local function add(name: string, ty: type)
			props[ts.singleton(name)] = ty
		end

		-- Static children and container methods first, so the common node
		-- methods below take precedence on name collisions (documented: method
		-- names are reserved words on containers).
		if t:is("table") and not isTimed then
			for key, prop in t:properties() do
				local childType = prop.read or prop.write
				if childType ~= nil then
					props[key] = build(childType, false)
				end
			end

			local indexer = t:indexer()
			if indexer ~= nil then
				local elementType = widen(indexer.readresult)
				if indexer.index:is("number") then
					-- Array node.
					add("Insert", fn({ elementType, optNumber, optBool }, {}))
					-- Remove returns nil on an empty/missing array (matches RemoveValue).
					add("Remove", fn({ optNumber, optBool }, { optional(elementType) }))
					add("RemoveValue", fn({ elementType, optBool }, { optional(elementType), optNumber }))
					add("Find", fn({ elementType }, { optNumber }))
					add("Has", fn({ elementType }, { ts.boolean }))
					add("OnInsert", fn({ fn({ elementType, ts.number }, {}) }, { disconnectType }))
					add("OnRemove", fn({ fn({ elementType, ts.number }, {}) }, { disconnectType }))
				else
					-- Dictionary node: children are accessor nodes.
					local childNode = build(indexer.readresult, false)
					indexerSpec = {
						index = indexer.index,
						readresult = childNode,
						writeresult = childNode,
					}
					add("Remove", fn({ ts.string, optBool }, { optional(elementType) }))
					add("OnKeyAdded", fn({ fn({ indexer.index, elementType }, {}) }, { disconnectType }))
					add("OnKeyRemoved", fn({ fn({ indexer.index, elementType }, {}) }, { disconnectType }))
				end
				add("Clear", fn({ optBool }, {}))
				add("Count", fn({}, { ts.number }))
			end
		end

		-- Common node methods.
		add("Get", fn({}, { valueType }))
		-- The root accessor (empty path) cannot be Set/Updated at runtime — those
		-- calls always throw ("cannot write to \"\""). Omit them from the root
		-- type so the typed API matches runtime and can't silently disable
		-- module-level checking with a template-typed argument.
		if not isRoot then
			add("Set", fn({ valueType, optBool }, { valueType }))
			add("Update", fn({ fn({ valueType }, { valueType }), optBool }, { valueType }))
		end
		add("Clone", fn({}, { valueType }))
		add("Default", fn({}, { valueType }))
		add("Changed", fn({ fn({ valueType, valueType, optional(ts.unionof(ts.string, ts.number)) }, {}) }, { disconnectType }))
		add("Observe", fn({ fn({ valueType }, {}) }, { disconnectType }))

		if t:is("number") then
			add("Increment", fn({ ts.number, anyType }, { ts.number }))
			add("Decrement", fn({ ts.number, anyType }, { ts.number }))
			add("Min", fn({}, { optNumber }))
			add("Max", fn({}, { optNumber }))
		elseif t:is("boolean") then
			add("Toggle", fn({ optBool }, { ts.boolean }))
		end

		if isTimed then
			add("SetTimed", fn({ valueType, ts.number, optBool }, {}))
			add("ExtendTimed", fn({ ts.number, optBool }, {}))
			add("Active", fn({}, { ts.boolean, optNumber }))
		end

		return ts.newtable(props, indexerSpec, nil)
	end

	return build(T, true)
end

-- Union of every static numeric leaf path in the template, dot-joined
-- ("Coins", "Stats.Wins"), giving autocomplete and compile-time validation
-- for leaderboard `Stat` and `Purchase` cost paths. Dynamic (dictionary or
-- array) segments cannot be enumerated at type level — cast those paths to
-- `any`. Falls back to plain `string` when the template has no numeric leaf.
-- selene: allow(undefined_variable)
export type function StatPathsType(T)
	local ts = types

	local paths: { type } = {}

	local function widen(t: type): type
		if t:is("singleton") then
			local value = t:value()
			if type(value) == "boolean" then
				return ts.boolean
			elseif type(value) == "string" then
				return ts.string
			end
		end
		return t
	end

	local function walk(rawType: type, prefix: string, depth: number)
		if depth > 8 then
			return
		end
		local t = widen(rawType)
		if t:is("table") then
			-- Unwrap the Scribe.Timed marker; its inner value is the leaf.
			local inner = t:readproperty(ts.singleton("__scribeTimed"))
			if inner ~= nil then
				t = widen(inner)
			end
		end
		if t:is("number") then
			if prefix ~= "" then
				table.insert(paths, ts.singleton(prefix))
			end
			return
		end
		if t:is("table") then
			for key, prop in t:properties() do
				local childType = prop.read or prop.write
				if childType ~= nil and key:is("singleton") then
					local name = key:value()
					if type(name) == "string" then
						walk(childType, if prefix == "" then name else `{prefix}.{name}`, depth + 1)
					end
				end
			end
		end
	end

	walk(T, "", 0)

	if #paths == 0 then
		return ts.string
	end
	if #paths == 1 then
		return paths[1]
	end
	return ts.unionof(table.unpack(paths))
end

-- Grant callbacks receive the typed accessor tree when a template type is
-- supplied, and stay `any` for the untyped default so un-annotated configs
-- never produce false errors.
-- selene: allow(undefined_variable)
export type function GrantDataType(T)
	if T:is("any") or T:is("unknown") then
		return types.any
	end
	return ValueType(T)
end

-- The client `Data` is the accessor tree root plus the client API. Built
-- as a type function (rather than `ValueType<T> & { ... }`) because
-- intersection normalization over a large accessor tree exceeds the solver's
-- complexity budget at the Scribe() call site.
-- selene: allow(undefined_variable)
export type function ClientDataType(T)
	local ts = types

	local function optional(t: type): type
		return ts.unionof(t, ts.singleton(nil))
	end

	local function fn(params: { type }, rets: { type }): type
		return ts.newfunction({ head = params }, { head = rets })
	end

	local anyTable = ts.newtable(nil, { index = ts.string, readresult = ts.any, writeresult = ts.any }, nil)
	local stringToNumber = ts.newtable(nil, { index = ts.string, readresult = ts.number, writeresult = ts.number }, nil)

	local entryProps: { [type]: type } = {}
	entryProps[ts.singleton("Rank")] = ts.number
	entryProps[ts.singleton("UserId")] = ts.number
	entryProps[ts.singleton("Name")] = ts.string
	entryProps[ts.singleton("Score")] = ts.number
	local leaderboardEntry = ts.newtable(entryProps, nil, nil)
	local entryArray = ts.newtable(nil, { index = ts.number, readresult = leaderboardEntry, writeresult = leaderboardEntry }, nil)
	local anyArray = ts.newtable(nil, { index = ts.number, readresult = anyTable, writeresult = anyTable }, nil)

	local statusType = ts.unionof(ts.singleton("Healthy"), ts.singleton("Degraded"), ts.singleton("Outage"))

	local saveInfoProps: { [type]: type } = {}
	saveInfoProps[ts.singleton("LastSaveAt")] = optional(ts.number)
	saveInfoProps[ts.singleton("LastResult")] = optional(ts.unionof(ts.singleton("Ok"), ts.singleton("Fail")))
	saveInfoProps[ts.singleton("Dirty")] = ts.boolean
	local saveInfo = ts.newtable(saveInfoProps, nil, nil)

	local out = ts.copy(ValueType(T))
	local function add(name: string, ty: type)
		out:setproperty(ts.singleton(name), ty)
	end

	add("IsReady", fn({}, { ts.boolean }))
	add("WaitForData", fn({ optional(ts.number) }, { ts.boolean }))
	add("Request", ts.newfunction({ head = { ts.string }, tail = ts.any }, { tail = ts.any }))
	add("GetLeaderboard", fn({ ts.string, optional(ts.number) }, { entryArray }))
	add("GetMyRank", fn({ ts.string }, { optional(ts.number) }))
	add("OnLeaderboard", ts.any)
	add("GetServiceStatus", fn({}, { statusType }))
	add("OnServiceStatus", ts.any)
	add("GetShared", fn({ ts.any }, { optional(anyTable) }))
	add("OnSharedChanged", ts.any)
	add("Owns", fn({ ts.string }, { ts.boolean }))
	add("ObserveOwned", fn({ ts.string, fn({ ts.boolean }, {}) }, { fn({}, {}) }))
	add("GetSaveInfo", fn({}, { saveInfo }))
	add("GetGiftCredits", fn({}, { stringToNumber }))
	local purchaseFilterProps: { [type]: type } = {}
	purchaseFilterProps[ts.singleton("Kind")] = optional(ts.unionof(ts.singleton("Robux"), ts.singleton("InGame")))
	purchaseFilterProps[ts.singleton("Category")] = optional(ts.string)
	purchaseFilterProps[ts.singleton("ItemId")] = optional(ts.string)
	purchaseFilterProps[ts.singleton("Since")] = optional(ts.number)
	purchaseFilterProps[ts.singleton("Limit")] = optional(ts.number)
	local purchaseFilter = optional(ts.newtable(purchaseFilterProps, nil, nil))
	add("GetPurchases", fn({ purchaseFilter }, { anyArray }))
	add("Mock", fn({ optional(anyTable), optional(anyTable) }, {}))
	add("MockCommand", ts.newfunction({ head = { ts.string, ts.newfunction({ tail = ts.any }, { tail = ts.any }) } }, { head = {} }))
	add("Raw", ts.any)

	return out
end

-- The server `Data` API. P is the Player class type, passed in as a type
-- argument because class types are not constructible inside type functions.
-- Built as a type function for the same complexity-budget reason as
-- ClientDataType.
-- selene: allow(undefined_variable)
export type function ServerDataType(T, P)
	local ts = types

	local node = ValueType(T)

	local function optional(t: type): type
		return ts.unionof(t, ts.singleton(nil))
	end

	local function fn(params: { type }, rets: { type }): type
		return ts.newfunction({ head = params }, { head = rets })
	end

	local anyTable = ts.newtable(nil, { index = ts.string, readresult = ts.any, writeresult = ts.any }, nil)
	local stringToNumber = ts.newtable(nil, { index = ts.string, readresult = ts.number, writeresult = ts.number }, nil)
	local optAnyTable = optional(anyTable)
	local anyArray = ts.newtable(nil, { index = ts.number, readresult = anyTable, writeresult = anyTable }, nil)
	local boolAndReason = { ts.boolean, optional(ts.string) }

	local entryProps: { [type]: type } = {}
	entryProps[ts.singleton("Rank")] = ts.number
	entryProps[ts.singleton("UserId")] = ts.number
	entryProps[ts.singleton("Name")] = ts.string
	entryProps[ts.singleton("Score")] = ts.number
	local leaderboardEntry = ts.newtable(entryProps, nil, nil)
	local entryArray = ts.newtable(nil, { index = ts.number, readresult = leaderboardEntry, writeresult = leaderboardEntry }, nil)

	local saveInfoProps: { [type]: type } = {}
	saveInfoProps[ts.singleton("LastSaveAt")] = optional(ts.number)
	saveInfoProps[ts.singleton("LastResult")] = optional(ts.unionof(ts.singleton("Ok"), ts.singleton("Fail")))
	saveInfoProps[ts.singleton("Dirty")] = ts.boolean
	local saveInfo = ts.newtable(saveInfoProps, nil, nil)

	local versionProps: { [type]: type } = {}
	versionProps[ts.singleton("VersionId")] = ts.string
	versionProps[ts.singleton("CreatedAt")] = ts.number
	versionProps[ts.singleton("Size")] = optional(ts.number)
	local versionRecord = ts.newtable(versionProps, nil, nil)
	local versionArray = ts.newtable(nil, { index = ts.number, readresult = versionRecord, writeresult = versionRecord }, nil)

	local flushOptsProps: { [type]: type } = {}
	flushOptsProps[ts.singleton("Force")] = optional(ts.boolean)
	local flushOpts = optional(ts.newtable(flushOptsProps, nil, nil))

	local props: { [type]: type } = {}
	local function add(name: string, ty: type)
		props[ts.singleton(name)] = ty
	end

	add("Get", fn({ P }, { node }))
	add("WaitForData", fn({ P }, { optional(node), optional(ts.string) }))
	add("GetState", fn({ P }, { ts.unionof(ts.singleton("Loading"), ts.singleton("Ready"), ts.singleton("SessionEnded")) }))

	add("Batch", fn({ P, fn({}, {}) }, {}))
	add("Transaction", fn({ P, fn({}, {}) }, boolAndReason))

	add("Flush", fn({ P, flushOpts }, { ts.boolean }))
	add("GetSaveInfo", fn({ P }, { saveInfo }))
	add("GetOffline", fn({ ts.number }, { optAnyTable }))
	add("UpdateOffline", fn({ ts.number, fn({ anyTable }, {}) }, boolAndReason))
	add("ListVersions", fn({ ts.number, optional(ts.number) }, { versionArray }))
	add("GetVersion", fn({ ts.number, ts.string }, { optAnyTable }))
	add("RestoreVersion", fn({ ts.number, ts.string }, boolAndReason))

	-- Command(name, spec?, handler): the spec shape and the handler's `player`
	-- param are typed; per-arg types can't be recovered (the Args literals widen).
	local commandArgs = ts.newtable(nil, { index = ts.number, readresult = ts.string, writeresult = ts.string }, nil)
	local commandSpecProps: { [type]: type } = {}
	commandSpecProps[ts.singleton("Args")] = optional(commandArgs)
	local commandSpec = ts.newtable(commandSpecProps, nil, nil)
	local commandHandler = ts.newfunction({ head = { P }, tail = ts.any }, { tail = ts.any })
	add("Command", fn({ ts.string, ts.unionof(commandSpec, commandHandler), optional(commandHandler) }, {}))

	add("GetLeaderboard", fn({ ts.string, optional(ts.number) }, { entryArray }))
	add("GetMyRank", fn({ P, ts.string }, { optional(ts.number) }))

	add("PromptGift", fn({ P, ts.string, ts.number }, boolAndReason))
	add("GetGiftCredits", fn({ P }, { stringToNumber }))
	add("HandleReceipt", fn({ ts.any }, { ts.any }))
	add("Owns", fn({ P, ts.string }, { ts.boolean }))
	add("GrantPerk", fn({ P, ts.string }, {}))
	add("RevokePerk", fn({ P, ts.string }, {}))

	-- Purchase spec: Cost.Path is the template's numeric-leaf path union and
	-- Grant receives the typed accessor tree.
	local costProps: { [type]: type } = {}
	costProps[ts.singleton("Path")] = StatPathsType(T)
	costProps[ts.singleton("Amount")] = ts.number
	local purchaseProps: { [type]: type } = {}
	purchaseProps[ts.singleton("Cost")] = ts.newtable(costProps, nil, nil)
	purchaseProps[ts.singleton("Category")] = optional(ts.string)
	purchaseProps[ts.singleton("ItemId")] = ts.string
	purchaseProps[ts.singleton("Grant")] = optional(fn({ node }, {}))
	purchaseProps[ts.singleton("Meta")] = optAnyTable
	add("Purchase", fn({ P, ts.newtable(purchaseProps, nil, nil) }, boolAndReason))
	add("RecordPurchase", fn({ P, anyTable }, {}))
	local purchaseFilterProps: { [type]: type } = {}
	purchaseFilterProps[ts.singleton("Kind")] = optional(ts.unionof(ts.singleton("Robux"), ts.singleton("InGame")))
	purchaseFilterProps[ts.singleton("Category")] = optional(ts.string)
	purchaseFilterProps[ts.singleton("ItemId")] = optional(ts.string)
	purchaseFilterProps[ts.singleton("Since")] = optional(ts.number)
	purchaseFilterProps[ts.singleton("Limit")] = optional(ts.number)
	local purchaseFilter = optional(ts.newtable(purchaseFilterProps, nil, nil))
	add("GetPurchases", fn({ P, purchaseFilter }, { anyArray }))

	add("OnCooldown", fn({ P, ts.string, ts.number }, { ts.boolean, ts.number }))
	add("PeekCooldown", fn({ P, ts.string }, { ts.boolean, ts.number }))
	add("ClearCooldown", fn({ P, ts.string }, {}))

	add("Erase", fn({ ts.number }, boolAndReason))
	add("Export", fn({ ts.number }, { optional(ts.string) }))

	add("OnSave", ts.any)
	add("SessionEnded", ts.any)
	add("OnAnomaly", ts.any)
	add("OnGiftReceived", ts.any)
	add("OnGiftCredit", ts.any)
	add("OnMessage", ts.any)
	add("SendMessage", fn({ ts.number, ts.any }, { ts.boolean }))
	add("ProfileStore", ts.any)
	add("Raw", ts.any)

	return ts.newtable(props, { index = P, readresult = node, writeresult = node }, nil)
end

--------------------------------------------------------------------------------
-- Typed field declarators
--------------------------------------------------------------------------------

export type Timed<T> = { __scribeTimed: T }

export type NumberMeta = { Min: number?, Max: number? }
export type StringMeta = { MaxLength: number? }

-- Template-aware config types. Annotate a config local with these to get
-- autocomplete and compile-time validation: `Stat`/`Cost.Path` become the
-- template's numeric leaf-path union and `Grant` receives the typed
-- accessor tree.
---
--   type T = typeof(template)
--   local boards: { [string]: Scribe.LeaderboardConfig<T> } = {
--       TopCoins = { Stat = "Coins" }, -- "Coins" | "Stats.Kills" | ...
--   }
---
-- (The annotation is required for strict checking: when the same table
-- literal both declares the template and uses these fields, Luau widens the
-- string literals before the template type is known.) Without a type
-- argument they default to the loose untyped shape.
export type LeaderboardConfig<T = any> = {
	Stat: StatPathsType<T>,
	Limit: number?,
	Scale: number?,
	Replicate: boolean?, -- default false: server-only (Data.GetLeaderboard on the server); true streams the board to clients
	StoreName: string?, -- override the OrderedDataStore name (default "LB_<board>")
}

export type ProductConfig<T = any> = {
	Id: number,
	Category: string?,
	Grant: ((data: GrantDataType<T>) -> ())?,
	Grants: string?,
}

export type PurchaseSpec<T = any> = {
	Cost: { Path: StatPathsType<T>, Amount: number },
	Category: string?,
	ItemId: string,
	Grant: ((data: GrantDataType<T>) -> ())?,
	Meta: { [string]: any }?,
}

-- Loose, read-only option shapes. These deliberately do NOT depend on T:
-- inside the Scribe({ ... }) literal the template type is still being
-- inferred, so strict (type-function) fields would widen and reject valid
-- configs. Read-only props keep annotated strict tables assignable.
type LeaderboardConfigLoose = {
	read Stat: string,
	read Limit: number?,
	read Scale: number?,
	read Replicate: boolean?,
}

type ProductConfigLoose = {
	read Id: number,
	read Category: string?,
	read Grant: ((data: any) -> ())?,
	read Grants: string?,
}

-- Economy is loose for the same reason: inside the Scribe({ ... }) literal a
-- Resolve lambda's parameter would generalize and a strict `(Player) -> {…}`
-- field would reject it. Callers wanting strict checking annotate a config
-- local with the exported `Scribe.EconomyConfig` instead.
type EconomyCurrencyConfigLoose = {
	read Label: string?,
	read Fields: { Types.EconomyFieldSpec }?,
	read Resolve: ((player: any) -> { [string]: any })?,
}

type EconomyConfigLoose = {
	read Resolve: ((player: any) -> { [string]: any })?,
	read Prefix: boolean?,
	read Currencies: { read [string]: EconomyCurrencyConfigLoose }?,
	read LogEconomyEvent: Types.EconomyLogFn?,
}

export type ScribeOptions<T> = {
	Template: T,
	Transport: (Types.ScribeTransport | "Default")?,

	Migrations: { [number]: (data: { [string]: any }) -> () }?,
	OnPlayerInit: ((player: Player, rawData: { [string]: any }) -> ())?,

	-- persistence
	ProfileStoreIndex: string, -- REQUIRED: the DataStore name (each game must name its own store)
	ProfileKeyPrefix: string, -- REQUIRED: prefix for per-player keys (e.g. "PLAYER_")
	SaveInterval: number?, -- seconds between autosaves per profile (default 300, floor 15)
	ProfileStore: any?, -- explicit ProfileStore module (module table or ModuleScript)
	UseMock: boolean?,
	ViewedUserId: number?,
	OverriddenUserId: number?,
	DontSave: boolean?,
	ResetData: boolean?,
	LoadFailurePolicy: ("Kick" | "Wait")?,
	VersionAheadPolicy: ("Kick" | "Allow")?, -- default "Kick": fail closed when data is from a newer deploy
	KickOnSessionEnd: boolean?,
	LoadFailureMessage: string?,
	SessionEndMessage: string?,

	-- services
	Leaderboards: { read [string]: LeaderboardConfigLoose }?,
	Products: { read [string]: ProductConfigLoose }?,
	Passes: { [string]: PassConfig }?,
	Perks: { string }?,
	OwnReceipts: boolean?,
	PurchaseLog: {
		RobuxCap: number?,
		InGameCap: number?,
		ReplicateRobux: boolean?,
		ReplicateInGame: boolean?,
		PurchaseLogCategories: { string }?,
	}?,

	-- gifting
	GiftCooldown: number?,
	GiftMaxPending: number?,
	GiftIntentTTL: number?,
	AllowDuplicateGifts: boolean?,
	NoGiftIntentPolicy: ("GrantOrCredit" | "Hold")?,

	-- economy analytics
	Economy: EconomyConfigLoose?,

	-- behaviour / limits
	CommandRateLimit: number?,
	RequestTimeout: number?,
	MaxInboundBytes: number?,
	TransportChannel: string?,

	-- integrity
	BoundsPolicy: ("Clamp" | "Reject")?,
	WipeGuardPolicy: ("Warn" | "Block")?,
	WipeGuardShrinkRatio: number?,

	-- diagnostics
	LogLevel: ("Debug" | "Info" | "Warn" | "Error" | "Fatal")?,
	StatusThresholds: { FailWindow: number?, FailCount: number?, RecoverStreak: number? }?,
	Banner: boolean?, -- default true: print one "Scribe vX.Y.Z ... ready" line on load
}

export type ServerData<T> = ServerDataType<T, Player>

export type ClientData<T> = ClientDataType<T>

export type Bundle<T> = {
	Server: ServerData<T>,
	Client: ClientData<T>,
}

--[=[
	@within Scribe
	@interface Bundle
	.Server Server -- the server-side data API (use on the server)
	.Client Client -- the client-side data API (use on the client)
	What `Scribe(options)` returns. The same shared module is required on both
	sides; use `.Server` on the server and `.Client` on the client.
]=]

--[=[
	@within Scribe
	@interface ScribeOptions
	.Template T -- your data shape, built from plain values and declarators (required)
	.ProfileStoreIndex string -- the DataStore name (required, no default)
	.ProfileKeyPrefix string -- per-player key prefix, e.g. "PLAYER_" (required)
	.Transport ("Default" | ScribeTransport)? -- replication channel; "Default" uses two RemoteEvents
	.SaveInterval number? -- seconds between autosaves per profile (default 300, floor 15)
	.Migrations { [number]: (data) -> () }? -- versioned, fail-closed data reshapers
	.OnPlayerInit ((player, rawData) -> ())? -- runs after load, before Ready
	.Leaderboards { [string]: LeaderboardConfig }? -- all-time OrderedDataStore boards
	.Products { [string]: ProductConfig }? -- developer products (receipts, grants, gifting)
	.Passes { [string]: PassConfig }? -- game passes
	.Perks { string }? -- perk keys grantable via GrantPerk / gifting
	.Economy EconomyConfig? -- per-currency economy analytics (LogEconomyEvent custom fields)
	.LoadFailurePolicy ("Kick" | "Wait")? -- on load failure (default "Kick")
	.VersionAheadPolicy ("Kick" | "Allow")? -- data from a newer deploy (default "Kick", fail closed)
	.BoundsPolicy ("Clamp" | "Reject")? -- out-of-range numeric writes (default "Clamp")
	.WipeGuardPolicy ("Warn" | "Block")? -- suspected data wipe (default "Warn")
	.LogLevel ("Debug" | "Info" | "Warn" | "Error" | "Fatal")? -- minimum log level
	.Banner boolean? -- print a one-line load banner (default true)
	The options table passed to `Scribe(options)`. Only `Template`,
	`ProfileStoreIndex`, and `ProfileKeyPrefix` are required; every other field
	has a sensible default. (Additional gifting, rate-limit, and diagnostics
	knobs exist: see the Options reference guide.)
]=]

--------------------------------------------------------------------------------
-- Runtime
--------------------------------------------------------------------------------

local KNOWN_OPTION_KEYS: { [string]: boolean } = {
	Template = true,
	Transport = true,
	TransportChannel = true,
	Migrations = true,
	OnPlayerInit = true,
	ProfileStoreIndex = true,
	ProfileKeyPrefix = true,
	SaveInterval = true,
	ProfileStore = true,
	UseMock = true,
	ViewedUserId = true,
	OverriddenUserId = true,
	DontSave = true,
	ResetData = true,
	LoadFailurePolicy = true,
	VersionAheadPolicy = true,
	KickOnSessionEnd = true,
	LoadFailureMessage = true,
	SessionEndMessage = true,
	Leaderboards = true,
	Products = true,
	Passes = true,
	Perks = true,
	OwnReceipts = true,
	PurchaseLog = true,
	GiftCooldown = true,
	GiftMaxPending = true,
	GiftIntentTTL = true,
	AllowDuplicateGifts = true,
	NoGiftIntentPolicy = true,
	Economy = true,
	CommandRateLimit = true,
	RequestTimeout = true,
	MaxInboundBytes = true,
	BoundsPolicy = true,
	WipeGuardPolicy = true,
	WipeGuardShrinkRatio = true,
	LogLevel = true,
	StatusThresholds = true,
	Banner = true,
}

local function buildBundle<T>(options: ScribeOptions<T>): Bundle<T>
	if type(options) ~= "table" then
		error("Scribe: options must be a table", 2)
	end
	if type((options :: any).Template) ~= "table" then
		error("Scribe: options.Template is required and must be a table", 2)
	end
	-- Storage location is intentional, never defaulted: two games (or a test
	-- build) accidentally sharing the "Default" store is a silent data hazard.
	local anyOpts = options :: any
	if type(anyOpts.ProfileStoreIndex) ~= "string" or anyOpts.ProfileStoreIndex == "" then
		error("Scribe: options.ProfileStoreIndex is required — name your game's DataStore explicitly", 2)
	end
	if type(anyOpts.ProfileKeyPrefix) ~= "string" or anyOpts.ProfileKeyPrefix == "" then
		error('Scribe: options.ProfileKeyPrefix is required — set a per-player key prefix (e.g. "PLAYER_")', 2)
	end

	-- The type checker enforces the TYPE of every option, but the Luau solver
	-- does not reject unknown table keys, so a misspelled option name would be
	-- silently ignored. Catch that in Studio (dev-mode) with a startup warning.
	if RunService:IsStudio() then
		for key in options :: any do
			if type(key) == "string" and not KNOWN_OPTION_KEYS[key] then
				Log.Warn("Lifecycle", "UNKNOWN_OPTION", `unknown Scribe option "{key}" — check the spelling`, { Option = key })
			end
		end
	end

	local anyOptions = options :: any
	local purchaseLog = anyOptions.PurchaseLog or {}
	-- Purchase logs are server-only unless explicitly opted in: they exist for
	-- auditing/support first, and most games never show them to the client.
	local compiled = Template.Compile(anyOptions.Template, {
		ReplicateRobuxLog = purchaseLog.ReplicateRobux == true,
		ReplicateInGameLog = purchaseLog.ReplicateInGame == true,
	})

	-- Template safety: deep-freeze after compilation; any accidental
	-- mutation of the shared template throws at the call site.
	Util.deepFreeze(anyOptions.Template)

	-- Sandbox guard: a Sandboxed script cannot fire a non-Sandboxed event, so a
	-- Sandboxed Scribe silently fails to send its replication frames (the client
	-- never handshakes, the server never delivers) and data never syncs. Detect
	-- it up front and say exactly how to fix it. This usually happens when Scribe
	-- is inserted from a model/toolbox rather than synced from source.
	local sandboxOk, sandboxed = pcall(function()
		return (script :: any).Sandboxed
	end)
	if sandboxOk and sandboxed == true then
		Log.Warn(
			"Lifecycle",
			"SANDBOXED",
			"the Scribe package is Sandboxed, so it cannot fire its replication RemoteEvents and nothing will sync. "
				.. "Set Sandboxed = false on the Scribe package (and ProfileStore).",
			{}
		)
	end

	local bundle: any
	if RunService:IsServer() then
		local Server = require(script.Server) :: any
		local serverData = Server.new(anyOptions, compiled)
		local clientStub = setmetatable({}, {
			__index = function()
				error("Scribe: the Client API is not available on the server", 2)
			end,
		})
		bundle = { Server = serverData, Client = clientStub }
	else
		local Client = require(script.Client) :: any
		local clientData = Client.new(anyOptions, compiled)
		local serverStub = setmetatable({}, {
			__index = function()
				error("Scribe: the Server API is not available on the client — client writes go through Data.Request commands", 2)
			end,
		})
		bundle = { Server = serverStub, Client = clientData }
	end

	-- Studio-only: expose the (frozen) raw template so Scribe Studio's
	-- edit-mode lint can introspect the canonical bundle-returning module.
	if RunService:IsStudio() then
		bundle.__ScribeTemplate = anyOptions.Template
	end

	return bundle :: any
end

--[=[
	@class Scribe

	The module you require and call. `Scribe(options)` compiles your template
	and returns a `{ Server, Client }` bundle. Use `.Server` on the server and
	`.Client` on the client from the same shared module.

	`Scribe` also exposes the field *declarators* (`Scribe.Int`, `Scribe.Vector3`,
	…) you use inside a template, the visibility wrappers (`Scribe.ServerOnly`,
	`Scribe.Shared`, `Scribe.Session`), and library-wide diagnostics.

	```lua
	local Scribe = require(ReplicatedStorage.Packages.Scribe)

	return Scribe({
	    Template = { Coins = Scribe.Int(0, { Min = 0 }) },
	    ProfileStoreIndex = "PlayerData",
	    ProfileKeyPrefix = "PLAYER_",
	})
	```
]=]
local Scribe = {}

--[=[
	@within Scribe
	@tag Setup
	@prop Version string
	The library version (e.g. `"1.0.0"`).
]=]
Scribe.Version = require(script.Internal.Version)

--[=[
	@within Scribe
	@tag Visibility
	@function ServerOnly
	@param value T
	@return T
	Marks a **root** field server-only: it persists and is readable on the
	server, but is never replicated to any client. May also wrap a nested field
	to keep just that subtree server-side.
]=]
function Scribe.ServerOnly<T>(value: T): T
	return Marker.make("ServerOnly", value) :: any
end

--[=[
	@within Scribe
	@tag Visibility
	@function Shared
	@param value T
	@return T
	Marks a **root** field shared: it replicates to *every* client (not just the
	owner), for public info like a display name or team.
]=]
function Scribe.Shared<T>(value: T): T
	return Marker.make("Shared", value) :: any
end

--[=[
	@within Scribe
	@tag Visibility
	@function Session
	@param value T
	@return T
	Marks a **root** field session-only: replicated to the owner but never
	persisted. Ideal for runtime state like `InCombat` that should reset on
	rejoin.
]=]
function Scribe.Session<T>(value: T): T
	return Marker.make("Session", value) :: any
end

--[=[
	@within Scribe
	@tag Field Types
	@function Int
	@param default number
	@param meta { Min: number?, Max: number? }?
	@return number
	Declares an integer field. Non-integer writes round (or reject under
	`BoundsPolicy = "Reject"`); out-of-range writes clamp. Bounded ints also
	pack to a smaller wire width.
]=]
function Scribe.Int(default: number, meta: NumberMeta?): number
	return Marker.make("Int", default, meta :: any) :: any
end

--[=[
	@within Scribe
	@tag Field Types
	@function Number
	@param default number
	@param meta { Min: number?, Max: number? }?
	@return number
	Declares a floating-point field with optional bounds.
]=]
function Scribe.Number(default: number, meta: NumberMeta?): number
	return Marker.make("Number", default, meta :: any) :: any
end

--[=[
	@within Scribe
	@tag Field Types
	@function String
	@param default string
	@param meta { MaxLength: number? }?
	@return string
	Declares a string field, optionally length-capped.
]=]
function Scribe.String(default: string, meta: StringMeta?): string
	return Marker.make("String", default, meta :: any) :: any
end

--[=[
	@within Scribe
	@tag Field Types
	@function Enum
	@param default string
	@param members { string }
	@return string
	Declares a string field restricted to a fixed set of members. Writes
	outside the set are rejected, and the value packs to a single byte.
]=]
function Scribe.Enum(default: string, members: { string }): string
	return Marker.make("Enum", default, { Members = members }) :: any
end

--[=[
	@within Scribe
	@tag Field Types
	@function Timed
	@param default T
	@return T
	Declares a field with an expiry. Set it with `field.SetTimed(value, seconds)`;
	it auto-clears back to `default` when the timer lapses (firing `Changed`).
	Great for boosters and temporary buffs.
]=]
function Scribe.Timed<T>(default: T): Timed<T>
	return Marker.make("Timed", default) :: any
end

--[=[
	@within Scribe
	@tag Field Types
	@function Dynamic
	@param factory () -> T
	@return T
	Declares a field whose default is produced by `factory` **per profile** rather
	than frozen once at server start. Use it for values that must be evaluated for
	each profile, like a creation timestamp:

	```lua
	CREATION_UNIX = Scribe.Dynamic(os.time),
	JOINED_AT     = Scribe.Dynamic(function() return DateTime.now() end), -- datatype, packed for you
	```

	Returning players keep their stored value; the factory only runs to seed the
	field on a brand-new profile (or one that gains the field after you add it to
	the template later). The field types as the factory's return type.

	**The factory must be pure.** It is also called once at declaration time (while
	your template module loads) to sample its return type, so it must be
	side-effect-free and must neither yield nor error; keep it to plain producers
	like `os.time` / `DateTime.now`. Anything that reserves an id, reads a store, or
	has other side effects would fire that effect at module load with no profile
	attached. Player-specific defaults (based on `player.Name`, a lookup, and so on)
	belong in `OnPlayerInit`.

	`Scribe.Dynamic` cannot sit inside a `Scribe.Session` root (a startup error):
	Session data is rebuilt from its default every session, so a one-time seed has
	nowhere to live. Use `OnPlayerInit` for per-session values.
]=]
-- `(...any) -> T` (not `() -> T`) so standard-library functions with optional
-- params typecheck when passed directly, e.g. `Scribe.Dynamic(os.time)`.
function Scribe.Dynamic<T>(factory: (...any) -> T): T
	return Marker.make("Dynamic", factory(), { Factory = factory :: any }) :: any
end

-- Roblox datatype fields (opt-in serialization): stored and replicated as a
-- compact packed buffer; Get/Set/Update/Observe convert at the boundary so
-- callers only ever see the real datatype.
local function datatypeMarker(name: string, default: any): any
	return Marker.make("Datatype", default, { Datatype = name })
end

--[=[
	@within Scribe
	@tag Field Types
	@function Vector3
	@param default Vector3
	@return Vector3
	Declares a Roblox datatype field. The value is stored and replicated as a
	compact packed buffer; `Get`/`Set` convert at the boundary, so your code only
	ever sees the real `Vector3`.

	All 17 datatype declarators share this shape:
	`Vector3`, `Vector2`, `Vector3int16`, `Vector2int16`, `CFrame`, `Color3`,
	`BrickColor`, `UDim`, `UDim2`, `Rect`, `NumberRange`, `NumberSequence`,
	`ColorSequence`, `DateTime`, `EnumItem`, `Font`, `PhysicalProperties`.
]=]
function Scribe.Vector3(default: Vector3): Vector3
	return datatypeMarker("Vector3", default)
end

function Scribe.Vector2(default: Vector2): Vector2
	return datatypeMarker("Vector2", default)
end

function Scribe.Vector3int16(default: Vector3int16): Vector3int16
	return datatypeMarker("Vector3int16", default)
end

function Scribe.Vector2int16(default: Vector2int16): Vector2int16
	return datatypeMarker("Vector2int16", default)
end

--[=[
	@within Scribe
	@tag Field Types
	@function CFrame
	@param default CFrame
	@return CFrame
	Declares a `CFrame` field. Axis-aligned rotations (the overwhelmingly common
	case for placed structures) pack to just 13 bytes; arbitrary rotations use a
	quaternion. See `Scribe.Vector3` for the full datatype list.
]=]
function Scribe.CFrame(default: CFrame): CFrame
	return datatypeMarker("CFrame", default)
end

function Scribe.Color3(default: Color3): Color3
	return datatypeMarker("Color3", default)
end

function Scribe.BrickColor(default: BrickColor): BrickColor
	return datatypeMarker("BrickColor", default)
end

function Scribe.UDim(default: UDim): UDim
	return datatypeMarker("UDim", default)
end

function Scribe.UDim2(default: UDim2): UDim2
	return datatypeMarker("UDim2", default)
end

function Scribe.Rect(default: Rect): Rect
	return datatypeMarker("Rect", default)
end

function Scribe.NumberRange(default: NumberRange): NumberRange
	return datatypeMarker("NumberRange", default)
end

function Scribe.NumberSequence(default: NumberSequence): NumberSequence
	return datatypeMarker("NumberSequence", default)
end

function Scribe.ColorSequence(default: ColorSequence): ColorSequence
	return datatypeMarker("ColorSequence", default)
end

function Scribe.DateTime(default: DateTime): DateTime
	return datatypeMarker("DateTime", default)
end

function Scribe.EnumItem(default: EnumItem): EnumItem
	return datatypeMarker("EnumItem", default)
end

function Scribe.Font(default: Font): Font
	return datatypeMarker("Font", default)
end

function Scribe.PhysicalProperties(default: PhysicalProperties): PhysicalProperties
	return datatypeMarker("PhysicalProperties", default)
end

--[=[
	@within Scribe
	@tag Field Types
	@prop Datatypes { Pack: (name: string, value: any) -> buffer, Unpack: (name: string, b: buffer) -> any }
	Low-level pack/unpack helpers for the 17 datatypes, exposed so migrations can
	convert legacy representations to the packed form.
]=]
Scribe.Datatypes = require(script.Internal.Datatypes)

--[=[
	@within Scribe
	@tag Diagnostics
	@function GetStatus
	@return "Healthy" | "Degraded" | "Outage"
	The current data-service health, derived from ProfileStore's error signals
	with hysteresis. Also broadcast to clients via `Client:GetServiceStatus`.
]=]
function Scribe.GetStatus(): Status
	return Health.GetStatus()
end

--[=[
	@within Scribe
	@tag Diagnostics
	@prop OnStatusChanged Signal
	Fires with the new status (`"Healthy" | "Degraded" | "Outage"`) whenever
	service health changes.
]=]
Scribe.OnStatusChanged = Health.OnStatusChanged

--[=[
	@within Scribe
	@tag Diagnostics
	@prop OnIssue Signal
	Fires for every Error/Fatal log entry: the single hook to wire up developer
	alerting (Discord webhook, PagerDuty, …) from your own game code.
]=]
Scribe.OnIssue = Log.OnIssue

--[=[
	@within Scribe
	@tag Diagnostics
	@function AddLogSink
	@param fn (entry: LogEntry) -> ()
	Registers an extra log sink. Scribe never sends logs anywhere itself. Add a
	sink to forward them to your own pipeline. Keep secrets in game code.
]=]
function Scribe.AddLogSink(fn: (entry: LogEntry) -> ())
	Log.AddSink(fn :: any)
end

--[=[
	@within Scribe
	@tag Diagnostics
	@function GetRecentLogs
	@param filter { Level: LogLevel?, Category: LogCategory?, Code: LogCode?, Limit: number? }?
	@return { LogEntry }
	Returns entries from the 512-entry ring buffer, newest first, optionally
	filtered by level/category/code. `Code`, `Level`, and `Category` are typed
	string unions, so editors autocomplete valid values (see the Log Code
	Reference for the full list of codes).
]=]
function Scribe.GetRecentLogs(filter: Log.LogFilter?): { LogEntry }
	return Log.GetRecent(filter)
end

--[=[
	@within Scribe
	@tag Diagnostics
	@function GetMetrics
	@return { [string]: number | { Count: number, Average: number, Max: number } }
	A snapshot of internal counters (saves, loads, receipt outcomes, queue
	depths, …) for admin panels and load tests. Plain counters are numbers;
	timing and size distributions are `{ Count, Average, Max }` records.
]=]
function Scribe.GetMetrics(): { [string]: number | { Count: number, Average: number, Max: number } }
	return Metrics.Get()
end

--[=[
	@within Scribe
	@tag Setup
	@function new
	@param options ScribeOptions
	@return Bundle
	Compiles the template and builds the `{ Server, Client }` bundle. Calling the
	module directly (`Scribe(options)`) is sugar for this. Require the same
	shared module on both the server and the client and use the matching half.
]=]
Scribe.new = buildBundle

-- The metatable is attached through a cast so it stays invisible to the type
-- system; the callable type is declared explicitly below instead (the new
-- solver does not yet instantiate generic __call metamethods).
setmetatable(Scribe :: any, {
	__call = function<T>(_self: any, options: ScribeOptions<T>): Bundle<T>
		return buildBundle(options)
	end,
})

export type ScribeModule = typeof(Scribe) & <T>(options: ScribeOptions<T>) -> Bundle<T>

return (Scribe :: any) :: ScribeModule
