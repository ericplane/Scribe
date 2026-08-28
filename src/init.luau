--!strict
-- Scribe: persistent, fully-typed, automatically-replicated player data for Roblox
-- Luau, built on ProfileStore. One shared module declares the template and options and
-- returns { Server, Client }. The typed accessor tree needs the new Luau type solver;
-- without it the library still runs correctly (use `.Raw` as the untyped escape hatch).

local RunService = game:GetService("RunService")

local Types = require(script.Types)
local Util = require(script.Internal.Util)
local Marker = require(script.Internal.Marker)
local Template = require(script.Internal.Template)
local Log = require(script.Internal.Log)
local Metrics = require(script.Internal.Metrics)
local Health = require(script.Internal.Health)
local Config = require(script.Internal.Config)
local Budget = require(script.Internal.Budget)
-- Named BigMath because `Scribe.Big` is the declarator; this is the arithmetic.
local BigMath = require(script.Internal.Big)
-- Types only. Both are leaf modules with no services, so this is safe on the client.
local Exchange = require(script.Internal.Exchange)
local ExchangeLegType = require(script.Internal.ExchangeLeg)

export type ScribeTransport = Types.ScribeTransport
export type Op = Types.Op
export type LogEntry = Types.LogEntry
export type LogCode = Types.LogCode
export type LogLevel = Types.LogLevel
export type LogCategory = Types.LogCategory
export type Status = Types.Status
export type SaveInfo = Types.SaveInfo
export type BudgetSnapshot = Budget.Snapshot
export type ExchangeLeg = ExchangeLegType.Leg
export type OpenExchange = Exchange.OpenExchange
export type OpenLeg = Exchange.OpenLeg
export type LifecycleReason = Types.LifecycleReason
export type RequestReason = Types.RequestReason
export type PurchaseReason = Types.PurchaseReason
export type GiftReason = Types.GiftReason
export type LeaderboardEntry = Types.LeaderboardEntry
export type PassConfig = Types.PassConfig
export type PurchaseFilter = Types.PurchaseFilter
export type EconomyMeta = Types.EconomyMeta
export type EconomyConfig = Types.EconomyConfig
export type EconomyCurrencyConfig = Types.EconomyCurrencyConfig
export type EconomyFieldSpec = Types.EconomyFieldSpec
export type EconomyLogFn = Types.EconomyLogFn
-- LeaderboardConfig<T>, ProductConfig<T> and PurchaseSpec<T> are defined after the
-- type functions below, which they need to derive their paths from the template.

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

	-- Recursion budget: a self-referential template type would blow the type-function
	-- stack, degrading the whole accessor tree to an error type. One past
	-- Util.MAX_VALUE_DEPTH, so it can never bind before the runtime does and only a
	-- cyclic type is cut off. Matches StatPathsType's cap below.
	local MAX_DEPTH = 25

	-- One shared Scribe.Big type for the whole template. Luau resolves `<` and `<=`
	-- by metatable identity rather than by shape, so a fresh type per field leaves
	-- two big fields in the same template incomparable.
	local bigType: type? = nil
	local function bigValueType(): type
		if bigType ~= nil then
			return bigType
		end
		-- The shape Get returns; arithmetic resolves through the metatable.
		local bigProps: { [type]: type } = {}
		bigProps[ts.singleton("M")] = ts.number
		bigProps[ts.singleton("E")] = ts.number
		bigProps[ts.singleton("Short")] = ts.newfunction(
			{ head = { ts.any, ts.unionof(ts.number, ts.singleton(nil)) } },
			{ head = { ts.string } }
		)
		bigProps[ts.singleton("ToNumber")] = ts.newfunction({ head = { ts.any } }, { head = { ts.number } })
		bigProps[ts.singleton("Log10")] = ts.newfunction({ head = { ts.any } }, { head = { ts.number } })

		-- The metamethods must be typed over this table with its metatable, so the table
		-- is built first and the metatable attached after. Typed over a metatable-less
		-- copy they describe a different type from the one Get returns, and every
		-- operator becomes an error. Operands widen to the union those methods accept,
		-- because BIG_MT resolves both sides through Big.from.
		local big = ts.newtable(bigProps, nil, nil)
		-- Pow returns the big type itself, so it cannot go in bigProps: ts.newtable
		-- snapshots that table. setproperty on the live type object instead.
		big:setproperty(ts.singleton("Pow"), ts.newfunction({ head = { big, ts.number } }, { head = { big } }))
		local operand = ts.unionof(big, ts.number, ts.string)
		local arith = ts.newfunction({ head = { operand, operand } }, { head = { big } })
		local cmp = ts.newfunction({ head = { operand, operand } }, { head = { ts.boolean } })
		local mtProps: { [type]: type } = {}
		mtProps[ts.singleton("__add")] = arith
		mtProps[ts.singleton("__sub")] = arith
		mtProps[ts.singleton("__mul")] = arith
		mtProps[ts.singleton("__div")] = arith
		mtProps[ts.singleton("__unm")] = ts.newfunction({ head = { big } }, { head = { big } })
		mtProps[ts.singleton("__lt")] = cmp
		mtProps[ts.singleton("__le")] = cmp
		-- __eq only ever runs with two tables, so it stays narrow.
		mtProps[ts.singleton("__eq")] = ts.newfunction({ head = { big, big } }, { head = { ts.boolean } })
		mtProps[ts.singleton("__tostring")] = ts.newfunction({ head = { big } }, { head = { ts.string } })
		big:setmetatable(ts.newtable(mtProps, nil, nil))
		bigType = big
		return big
	end

	-- Big, Flags and SetOf carry their label in the metatable rather than in a field,
	-- so each declarator's own type is already the read shape. See BigValue.
	local function hasMarker(t: type, name: string): boolean
		local mt = t:metatable()
		return mt ~= nil and mt:readproperty(ts.singleton(name)) ~= nil
	end

	local function isBigMarker(t: type): boolean
		return hasMarker(t, "__scribeBig")
	end

	-- Timed and ServerOnly read back as a bare T, which may not be a table, so unlike
	-- the branded declarators their label has to be an ordinary field and a
	-- whole-subtree read strips it here. This only ever removes a wrapper, which is
	-- what keeps it cheap enough to run over every node.
	local unwrapCache: { [type]: type } = {}
	local function unwrapWrappers(t: type, depth: number): type
		if depth > MAX_DEPTH or not t:is("table") then
			return t
		end
		local cached = unwrapCache[t]
		if cached ~= nil then
			return cached
		end
		local function memo(result: type): type
			unwrapCache[t] = result
			return result
		end
		local timed = t:readproperty(ts.singleton("__scribeTimed"))
		if timed ~= nil then
			return memo(unwrapWrappers(widen(timed), depth + 1))
		end
		local serverOnly = t:readproperty(ts.singleton("__scribeServerOnly"))
		if serverOnly ~= nil then
			return memo(unwrapWrappers(widen(serverOnly), depth + 1))
		end
		local derived = t:readproperty(ts.singleton("__scribeDerived"))
		if derived ~= nil then
			return memo(unwrapWrappers(widen(derived), depth + 1))
		end
		-- A marker cannot hide under one of the branded declarators: their metatable
		-- brand means the shape below them is already the read shape.
		if hasMarker(t, "__scribeBig") or hasMarker(t, "__scribeFlags") or hasMarker(t, "__scribeSet") then
			return memo(t)
		end
		local props: { [type]: type } = {}
		local rebuilt = false
		for key, prop in t:properties() do
			local childType = prop.read or prop.write
			if childType ~= nil then
				local mapped = unwrapWrappers(childType, depth + 1)
				props[key] = mapped
				if mapped ~= childType then
					rebuilt = true
				end
			end
		end
		local spec: { index: type, readresult: type, writeresult: type }? = nil
		local indexer = t:indexer()
		if indexer ~= nil then
			local mapped = unwrapWrappers(indexer.readresult, depth + 1)
			spec = { index = indexer.index, readresult = mapped, writeresult = mapped }
			if mapped ~= indexer.readresult then
				rebuilt = true
			end
		end
		if not rebuilt then
			return memo(t)
		end
		return memo(ts.newtable(props, spec, nil))
	end

	local function build(rawType: type, isRoot: boolean, depth: number): type
		if depth > MAX_DEPTH then
			return anyType
		end
		local t = widen(rawType)

		-- The Scribe.ServerOnly marker has to come off first: every declarator check below
		-- reads a marker off `t`, so with the wrapper on, ServerOnly(SetOf/Big/Flags/Timed)
		-- matches none of them and the node loses its declarator surface. A second unwrap
		-- after the SetOf block handles the inverse nesting, e.g. Timed(ServerOnly(false)).
		if t:is("table") then
			local inner = t:readproperty(ts.singleton("__scribeServerOnly"))
			if inner ~= nil then
				t = widen(inner)
			end
		end

		-- A Scribe.Derived node reads as V and never writes, so this only records the
		-- flag; the mutator block below is skipped as it is for the root accessor.
		local isDerived = false
		if t:is("table") then
			local inner = t:readproperty(ts.singleton("__scribeDerived"))
			if inner ~= nil then
				isDerived = true
				t = widen(inner)
			end
		end

		local isTimed = false
		if t:is("table") then
			local inner = t:readproperty(ts.singleton("__scribeTimed"))
			if inner ~= nil then
				isTimed = true
				t = widen(inner)
			end
		end

		-- Without the marker a flags field is just { string } and would pick up the
		-- array surface, none of which it supports. `t` is already the { string } a
		-- read returns; the label is on the metatable.
		local isFlags = t:is("table") and hasMarker(t, "__scribeFlags")

		-- A big's value is an object with arithmetic metamethods rather than a number,
		-- so it gets its own method surface and none of the table one.
		local isBig = false
		if t:is("table") and isBigMarker(t) then
			isBig = true
			t = bigValueType()
		end

		-- Without the marker a set is just { T } and would pick up Insert plus
		-- index-based Remove, neither of which a set has. `t` is already the members.
		local isSet = t:is("table") and hasMarker(t, "__scribeSet")

		-- Second ServerOnly unwrap, for a marker nested inside another declarator
		-- rather than wrapped around one. The server reads these normally;
		-- StripServerOnly is what drops them from the client type.
		if t:is("table") then
			local inner = t:readproperty(ts.singleton("__scribeServerOnly"))
			if inner ~= nil then
				t = widen(inner)
			end
		end

		-- Scribe.MapOf carries its key type as a singleton, the only way to tell a sparse
		-- {[number]: V} map from an array: at the type level those are the same indexer.
		-- Last, so a map wrapped in Scribe.ServerOnly is still seen as a map. `t` stays the
		-- whole map; only the element is pulled back out, for the key events and Remove.
		local mapKey: type? = nil
		local mapValue: type? = nil
		local mapElement: type? = nil
		if t:is("table") and hasMarker(t, "__scribeMapKey") then
			local indexer = t:indexer()
			if indexer ~= nil then
				mapKey = indexer.index
				mapValue = indexer.readresult
				mapElement = widen(indexer.readresult)
			end
		end

		local props: { [type]: type } = {}
		local indexerSpec: { index: type, readresult: type, writeresult: type }? = nil

		-- Strips a nested Timed / ServerOnly label, the one thing a read should not show.
		local valueType = unwrapWrappers(t, depth)
		local function add(name: string, ty: type)
			props[ts.singleton(name)] = ty
		end

		-- Static children and container methods first, so the common node methods below win
		-- on name collisions. Maps are excluded: their own block builds the same surface
		-- with the declared key type, and two ts.singleton("Remove") calls are distinct
		-- keys, so letting a map through here duplicates rather than overrides.
		if t:is("table") and mapKey == nil and not isTimed and not isFlags and not isSet and not isBig then
			for key, prop in t:properties() do
				local childType = prop.read or prop.write
				if childType ~= nil then
					props[key] = build(childType, false, depth + 1)
				end
			end

			-- OnChildChanged reports an existing child's value moving, once per write
			-- and never coalesced, unlike Changed.
			local childKeys: { type } = {}
			local childValues: { type } = {}
			for key, prop in t:properties() do
				local childType = prop.read or prop.write
				if childType ~= nil then
					table.insert(childKeys, key)
					table.insert(childValues, widen(childType))
				end
			end

			local indexer = t:indexer()
			if indexer ~= nil then
				local elementType = widen(indexer.readresult)
				if indexer.index:is("number") then
					-- Array node: the indexer makes `arr[i]` an accessor node, which is
					-- the only way to reach a Scribe.ArrayOf element field.
					local elemNode = build(indexer.readresult, false, depth + 1)
					indexerSpec = {
						index = indexer.index,
						readresult = elemNode,
						writeresult = elemNode,
					}
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
					local childNode = build(indexer.readresult, false, depth + 1)
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
				-- A dynamic container's children are homogeneous, so the key and value
				-- types here are exact rather than a union over declared fields.
				table.insert(childKeys, indexer.index)
				table.insert(childValues, widen(indexer.readresult))
			end

			if #childKeys > 0 then
				-- (key, new, old), matching Changed's new-first order. Both values are
				-- optional: an added key has no old, a removed key has no new. On a
				-- heterogeneous static table they widen to a union Luau will not narrow from
				-- the key, which is accepted; that node kind has exact per-field listeners.
				local childKey = ts.unionof(table.unpack(childKeys))
				local childValue = optional(ts.unionof(table.unpack(childValues)))
				add("OnChildChanged", fn({ fn({ childKey, childValue, childValue }, {}) }, { disconnectType }))
			end
		end

		if mapKey ~= nil then
			-- A map's children are accessor nodes keyed by the declared type; the key
			-- events and Remove carry the element rather than the whole map.
			local element = mapElement :: type
			local childNode = build(mapValue :: type, false, depth + 1)
			indexerSpec = { index = mapKey, readresult = childNode, writeresult = childNode }
			add("Remove", fn({ mapKey, optBool }, { optional(element) }))
			add("OnKeyAdded", fn({ fn({ mapKey, element }, {}) }, { disconnectType }))
			add("OnKeyRemoved", fn({ fn({ mapKey, element }, {}) }, { disconnectType }))
			add("OnChildChanged", fn({ fn({ mapKey, optional(element), optional(element) }, {}) }, { disconnectType }))
			add("Clear", fn({ optBool }, {}))
			add("Count", fn({}, { ts.number }))
		end

		-- Common node methods.
		add("Get", fn({}, { valueType }))
		-- The root accessor cannot be Set or Updated at runtime, so those are left off the
		-- root type. A big field declares its own wider Set and Update below; adding them
		-- here too would duplicate rather than override, as the singletons are distinct keys.
		if not isRoot and not isBig and not isDerived then
			-- Writes take the unbranded shape: a caller writing a plain table literal
			-- has no way to produce a map's metatable brand. Reads still hand back the
			-- branded type, which assigns freely to the plain shape.
			local writeType = if mapKey ~= nil and mapElement ~= nil
				then ts.newtable(nil, { index = mapKey, readresult = mapElement, writeresult = mapElement }, nil)
				else valueType
			add("Set", fn({ writeType, optBool }, { valueType }))
			add("Update", fn({ fn({ valueType }, { writeType }), optBool }, { valueType }))
		end
		add("Clone", fn({}, { valueType }))
		add("Default", fn({}, { valueType }))
		-- (new, old) on every node. On a container it reports state, coalesced to one
		-- fire per batch or received frame; which child moved is OnChildChanged's job.
		add("Changed", fn({ fn({ valueType, valueType }, {}) }, { disconnectType }))
		add("Observe", fn({ fn({ valueType }, {}) }, { disconnectType }))

		if t:is("number") then
			-- Min/Max read the declared bounds, so they stay on a derived field; the
			-- two mutators do not.
			if not isDerived then
				add("Increment", fn({ ts.number, anyType }, { ts.number }))
				add("Decrement", fn({ ts.number, anyType }, { ts.number }))
			end
			add("Min", fn({}, { optNumber }))
			add("Max", fn({}, { optNumber }))
		elseif t:is("boolean") and not isDerived then
			add("Toggle", fn({ optBool }, { ts.boolean }))
		end

		if isBig then
			-- Every entry point, Set included, takes a number, a numeric string, or
			-- another big value, so the operand type is the same union everywhere.
			local operand = ts.unionof(ts.number, ts.string, valueType)
			add("Set", fn({ operand, optBool }, { valueType }))
			add("Update", fn({ fn({ valueType }, { operand }), optBool }, { valueType }))
			add("Increment", fn({ operand, anyType }, { valueType }))
			add("Decrement", fn({ operand, anyType }, { valueType }))
			add("Multiply", fn({ operand, optBool }, { valueType }))
			add("Divide", fn({ operand, optBool }, { valueType }))
			-- A big bound past the double range is only expressible as a numeric string,
			-- so these return the same union the declarator accepts.
			local optBound = optional(ts.unionof(ts.number, ts.string))
			add("Min", fn({}, { optBound }))
			add("Max", fn({}, { optBound }))
		end

		if isSet then
			-- Membership surface. Get/Set still take the whole { T }.
			local setIndexer = t:indexer()
			local element = if setIndexer ~= nil then widen(setIndexer.readresult) else anyType
			add("Add", fn({ element, optBool }, { ts.boolean }))
			add("Remove", fn({ element, optBool }, { ts.boolean }))
			add("Has", fn({ element }, { ts.boolean }))
			add("Count", fn({}, { ts.number }))
			add("Clear", fn({ optBool }, {}))
		end

		if isFlags then
			-- Named-member surface. Get/Set still take the whole { string } set.
			add("Enable", fn({ ts.string, optBool }, {}))
			add("Disable", fn({ ts.string, optBool }, {}))
			add("Has", fn({ ts.string }, { ts.boolean }))
			add("Toggle", fn({ ts.string, optBool }, { ts.boolean }))
			add("Clear", fn({ optBool }, {}))
		end

		if isTimed then
			add("SetTimed", fn({ valueType, ts.number, optBool }, {}))
			add("ExtendTimed", fn({ ts.number, optBool }, {}))
			add("Active", fn({}, { ts.boolean, optNumber }))
		end

		return ts.newtable(props, indexerSpec, nil)
	end

	return build(T, true, 0)
end

-- Union of every static rankable leaf path in the template, dot-joined ("Coins",
-- "Stats.Wins"), for leaderboard `Stat` and purchase cost paths. Dynamic segments cannot
-- be enumerated at type level, so those paths must be cast to `any`; falls back to plain
-- `string` when the template has no such leaf. `IncludeBig` is true for leaderboards and
-- false for cost paths, which must be plain numbers.
-- selene: allow(undefined_variable)
export type function StatPathsType(T, IncludeBig)
	local ts = types
	local includeBig = IncludeBig ~= nil and IncludeBig:is("singleton") and IncludeBig:value() == true

	local function hasMarker(t: type, name: string): boolean
		local mt = t:metatable()
		return mt ~= nil and mt:readproperty(ts.singleton(name)) ~= nil
	end

	local function isBigMarker(t: type): boolean
		return hasMarker(t, "__scribeBig")
	end

	local function isMapMarker(t: type): boolean
		return hasMarker(t, "__scribeMapKey")
	end

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
		if t:is("table") then
			-- Same for Scribe.ServerOnly: the server is what reads leaderboard
			-- stats, so a server-only number is still a valid stat path.
			local serverOnly = t:readproperty(ts.singleton("__scribeServerOnly"))
			if serverOnly ~= nil then
				t = widen(serverOnly)
			end
		end
		if t:is("table") then
			-- And Scribe.Derived: a board reads its stat through the accessor tree,
			-- which computes derived fields, so a derived number is a valid stat.
			local derived = t:readproperty(ts.singleton("__scribeDerived"))
			if derived ~= nil then
				t = widen(derived)
			end
		end
		if t:is("table") and isMapMarker(t) then
			-- A map's entries live under dynamic keys, which cannot be enumerated at type
			-- level. Recursing would offer the unaddressable "Field.__scribeMapValue".
			return
		end
		if t:is("table") and isBigMarker(t) then
			-- Always terminal: a big's type is its real shape, so recursing would expose the
			-- object's own M and E and offer "Coins.M" as a stat path. When a big counts, the
			-- field itself is the path, or a template whose only rankable field is big
			-- produces an empty union and collapses the gate to `string`.
			if includeBig and prefix ~= "" then
				table.insert(paths, ts.singleton(prefix))
			end
			return
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

-- T with every Scribe.ServerOnly subtree removed, at any depth, so the client type
-- cannot name a field that reads nil there. Applied to the raw template before
-- ValueType, which unwraps the marker and loses the information.
-- selene: allow(undefined_variable)
type function StripServerOnly(T)
	local ts = types
	local MARKER = ts.singleton("__scribeServerOnly")
	-- Matches ValueType's budget: a cyclic template must not blow the stack.
	local MAX_DEPTH = 25

	local function isServerOnly(t: type): boolean
		return t:is("table") and t:readproperty(MARKER) ~= nil
	end

	local function strip(t: type, depth: number): type
		if depth > MAX_DEPTH or not t:is("table") then
			return t
		end
		local out = ts.copy(t)
		for key, prop in t:properties() do
			local childType = prop.read or prop.write
			if childType ~= nil then
				if isServerOnly(childType) then
					out:setproperty(key, nil) -- the whole subtree leaves the client type
				else
					out:setproperty(key, strip(childType, depth + 1))
				end
			end
		end
		-- Element shapes live behind the indexer, not in properties: without this a
		-- ServerOnly field inside an ArrayOf or DictOf entry stays in the client type.
		local indexer = t:indexer()
		if indexer ~= nil then
			local element = strip(indexer.readresult, depth + 1)
			out:setindexer(indexer.index, element)
		end
		return out
	end

	return strip(T, 0)
end

-- Grant callbacks receive the typed accessor tree when a template type is supplied,
-- and stay `any` for the untyped default so un-annotated configs stay clean.
-- selene: allow(undefined_variable)
export type function GrantDataType(T)
	if T:is("any") or T:is("unknown") then
		return types.any
	end
	return ValueType(T)
end

-- The client `Data` is the accessor tree root plus the client API. A type function
-- rather than `ValueType<T> & { ... }`, because normalizing an intersection over a
-- large accessor tree exceeds the solver's budget at the Scribe() call site.
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
	-- `number | BigScore`, not `number`: a Scribe.Big board hands back the big itself,
	-- and the board's kind is a runtime property of the name passed in, so the type
	-- cannot pick one and the caller narrows.
	local bigScoreProps: { [type]: type } = {}
	bigScoreProps[ts.singleton("M")] = ts.number
	bigScoreProps[ts.singleton("E")] = ts.number
	bigScoreProps[ts.singleton("Short")] = ts.newfunction(
		{ head = { ts.any, ts.unionof(ts.number, ts.singleton(nil)) } },
		{ head = { ts.string } }
	)
	bigScoreProps[ts.singleton("ToNumber")] = ts.newfunction({ head = { ts.any } }, { head = { ts.number } })
	bigScoreProps[ts.singleton("Log10")] = ts.newfunction({ head = { ts.any } }, { head = { ts.number } })
	entryProps[ts.singleton("Score")] = ts.unionof(ts.number, ts.newtable(bigScoreProps, nil, nil))
	local leaderboardEntry = ts.newtable(entryProps, nil, nil)
	local entryArray =
		ts.newtable(nil, { index = ts.number, readresult = leaderboardEntry, writeresult = leaderboardEntry }, nil)
	local anyArray = ts.newtable(nil, { index = ts.number, readresult = anyTable, writeresult = anyTable }, nil)

	local statusType = ts.unionof(ts.singleton("Healthy"), ts.singleton("Degraded"), ts.singleton("Outage"))

	local saveInfoProps: { [type]: type } = {}
	saveInfoProps[ts.singleton("LastSaveAt")] = optional(ts.number)
	saveInfoProps[ts.singleton("LastResult")] = optional(ts.unionof(ts.singleton("Ok"), ts.singleton("Fail")))
	saveInfoProps[ts.singleton("Dirty")] = ts.boolean
	saveInfoProps[ts.singleton("Size")] = optional(ts.number)
	local saveInfo = ts.newtable(saveInfoProps, nil, nil)

	local out = ts.copy(ValueType(StripServerOnly(T)))
	local function add(name: string, ty: type)
		out:setproperty(ts.singleton(name), ty)
	end

	add("IsReady", fn({}, { ts.boolean }))
	add("WaitForData", fn({ optional(ts.number) }, { ts.boolean }))
	add("Request", ts.newfunction({ head = { ts.string }, tail = ts.any }, { tail = ts.any }))
	-- RequestOnce(name, key, ...): the key is a required second string, so a plain
	-- Request argument list fails to type-check rather than silently becoming a key.
	add("RequestOnce", ts.newfunction({ head = { ts.string, ts.string }, tail = ts.any }, { tail = ts.any }))
	add("GetLeaderboard", fn({ ts.string, optional(ts.number) }, { entryArray }))
	add("GetMyRank", fn({ ts.string }, { optional(ts.number) }))
	add("OnLeaderboard", ts.any)
	add("GetServiceStatus", fn({}, { statusType }))
	add("OnServiceStatus", ts.any)
	add("GetShared", fn({ ts.any }, { optional(anyTable) }))
	add("OnSharedChanged", ts.any)
	add("Owns", fn({ ts.string }, { ts.boolean }))
	add("OwnsAsync", fn({ ts.string, optional(ts.number) }, { ts.boolean }))
	add("ObserveOwned", fn({ ts.string, fn({ ts.boolean }, {}) }, { fn({}, {}) }))
	add("OnOwnershipChanged", ts.any)
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
	add(
		"MockCommand",
		ts.newfunction({ head = { ts.string, ts.newfunction({ tail = ts.any }, { tail = ts.any }) } }, { head = {} })
	)
	add("Raw", ts.any)

	return out
end

-- The server `Data` API. P is the Player class type, passed in as a type argument
-- because class types are not constructible inside a type function. A type function
-- for the same complexity-budget reason as ClientDataType.
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
	-- `number | BigScore`: a Scribe.Big board hands back the big itself, as in
	-- ClientDataType above.
	local bigScoreProps: { [type]: type } = {}
	bigScoreProps[ts.singleton("M")] = ts.number
	bigScoreProps[ts.singleton("E")] = ts.number
	bigScoreProps[ts.singleton("Short")] = ts.newfunction(
		{ head = { ts.any, ts.unionof(ts.number, ts.singleton(nil)) } },
		{ head = { ts.string } }
	)
	bigScoreProps[ts.singleton("ToNumber")] = ts.newfunction({ head = { ts.any } }, { head = { ts.number } })
	bigScoreProps[ts.singleton("Log10")] = ts.newfunction({ head = { ts.any } }, { head = { ts.number } })
	entryProps[ts.singleton("Score")] = ts.unionof(ts.number, ts.newtable(bigScoreProps, nil, nil))
	local leaderboardEntry = ts.newtable(entryProps, nil, nil)
	local entryArray =
		ts.newtable(nil, { index = ts.number, readresult = leaderboardEntry, writeresult = leaderboardEntry }, nil)

	local saveInfoProps: { [type]: type } = {}
	saveInfoProps[ts.singleton("LastSaveAt")] = optional(ts.number)
	saveInfoProps[ts.singleton("LastResult")] = optional(ts.unionof(ts.singleton("Ok"), ts.singleton("Fail")))
	saveInfoProps[ts.singleton("Dirty")] = ts.boolean
	saveInfoProps[ts.singleton("Size")] = optional(ts.number)
	local saveInfo = ts.newtable(saveInfoProps, nil, nil)

	local versionProps: { [type]: type } = {}
	versionProps[ts.singleton("VersionId")] = ts.string
	versionProps[ts.singleton("CreatedAt")] = ts.number
	versionProps[ts.singleton("Size")] = optional(ts.number)
	local versionRecord = ts.newtable(versionProps, nil, nil)
	local versionArray =
		ts.newtable(nil, { index = ts.number, readresult = versionRecord, writeresult = versionRecord }, nil)

	local flushOptsProps: { [type]: type } = {}
	flushOptsProps[ts.singleton("Force")] = optional(ts.boolean)
	flushOptsProps[ts.singleton("Timeout")] = optional(ts.number)
	local flushOpts = optional(ts.newtable(flushOptsProps, nil, nil))

	local restoreOptsProps: { [type]: type } = {}
	restoreOptsProps[ts.singleton("RollBackReserved")] = optional(ts.boolean)
	local restoreOpts = optional(ts.newtable(restoreOptsProps, nil, nil))

	-- Keep in sync with Types.LifecycleReason. Spelled out here because a type
	-- function cannot reference an exported type alias.
	local reasonUnion = ts.unionof(
		ts.singleton("load-failed"),
		ts.singleton("migration-failed"),
		ts.singleton("session-ended"),
		ts.singleton("player-left"),
		ts.singleton("shutdown"),
		ts.singleton("still-loading"),
		ts.singleton("timeout")
	)

	local props: { [type]: type } = {}
	local function add(name: string, ty: type)
		props[ts.singleton(name)] = ty
	end

	add("Get", fn({ P }, { node }))
	add("WaitForData", fn({ P, optional(ts.number) }, { optional(node), optional(reasonUnion) }))
	add(
		"GetState",
		fn({ P }, { ts.unionof(ts.singleton("Loading"), ts.singleton("Ready"), ts.singleton("SessionEnded")) })
	)

	add("Batch", fn({ P, fn({}, {}) }, {}))
	add("Transaction", fn({ P, fn({}, {}) }, boolAndReason))

	add("Flush", fn({ P, flushOpts }, { ts.boolean }))
	add("GetSaveInfo", fn({ P }, { saveInfo }))
	add("GetOffline", fn({ ts.number }, { optAnyTable }))
	add("UpdateOffline", fn({ ts.number, fn({ anyTable }, {}) }, boolAndReason))
	add("ListVersions", fn({ ts.number, optional(ts.number) }, { versionArray }))
	add("GetVersion", fn({ ts.number, ts.string }, { optAnyTable }))
	add("RestoreVersion", fn({ ts.number, ts.string, restoreOpts }, boolAndReason))

	-- Command(name, spec?, handler): the spec shape and the handler's `player` param are
	-- typed; per-arg types cannot be recovered, since the Args literals widen. Args
	-- elements are `any` rather than `string` because Commands.Register also accepts
	-- declarators and shape tables, and validates the entries itself at register time.
	local commandArgs = ts.newtable(nil, { index = ts.number, readresult = ts.any, writeresult = ts.any }, nil)
	local commandSpecProps: { [type]: type } = {}
	commandSpecProps[ts.singleton("Args")] = optional(commandArgs)
	commandSpecProps[ts.singleton("Idempotent")] = optional(ts.boolean)
	local commandSpec = ts.newtable(commandSpecProps, nil, nil)
	local commandHandler = ts.newfunction({ head = { P }, tail = ts.any }, { tail = ts.any })
	add("Command", fn({ ts.string, ts.unionof(commandSpec, commandHandler), optional(commandHandler) }, {}))

	add("GetLeaderboard", fn({ ts.string, optional(ts.number) }, { entryArray }))
	add("GetMyRank", fn({ P, ts.string }, { optional(ts.number) }))

	add("PromptGift", fn({ P, ts.string, ts.number }, boolAndReason))
	add("GetGiftCredits", fn({ P }, { stringToNumber }))
	add("HandleReceipt", fn({ ts.any }, { ts.any }))
	add("TryHandleReceipt", fn({ ts.any }, { optional(ts.any) }))
	add("Owns", fn({ P, ts.string }, { ts.boolean }))
	add("OwnsAsync", fn({ P, ts.string, optional(ts.number) }, { ts.boolean }))
	add("ObserveOwned", fn({ P, ts.string, fn({ ts.boolean }, {}) }, { fn({}, {}) }))
	add("OnOwnershipChanged", ts.any)
	add("GrantPerk", fn({ P, ts.string }, {}))
	add("RevokePerk", fn({ P, ts.string }, {}))

	-- Purchase spec: Cost.Path is the template's numeric-leaf path union and
	-- Grant receives the typed accessor tree.
	local costProps: { [type]: type } = {}
	-- false: a cost path must be a plain number balance. Monetization refuses a
	-- non-number at runtime, so this rejects a Scribe.Big path at author time.
	costProps[ts.singleton("Path")] = StatPathsType(T, ts.singleton(false))
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

	local cooldownOptsProps: { [type]: type } = {}
	cooldownOptsProps[ts.singleton("IncludeOfflineTime")] = optional(ts.boolean)
	local cooldownOpts = optional(ts.newtable(cooldownOptsProps, nil, nil))
	add("OnCooldown", fn({ P, ts.string, ts.number, cooldownOpts }, { ts.boolean, ts.number }))
	add("PeekCooldown", fn({ P, ts.string }, { ts.boolean, ts.number }))
	add("ClearCooldown", fn({ P, ts.string }, {}))

	add("Erase", fn({ ts.number }, boolAndReason))
	add("Export", fn({ ts.number }, { optional(ts.string) }))

	add("OnSave", ts.any)
	add("SessionEnded", ts.any)
	add("OnCooldownEnded", ts.any)
	add("OnLeaderboard", ts.any)
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
-- What a Scribe.Flags field reads back: the enabled member names. The label sits in
-- the metatable so a whole-table read shows the members rather than the label.
export type Flags = typeof(setmetatable({} :: { string }, {} :: { __scribeFlags: true }))
-- A set reads back as its members. Label in the metatable, as above.
export type SetOf<T> = typeof(setmetatable({} :: { T }, {} :: { __scribeSet: true }))
export type ServerOnly<T> = { __scribeServerOnly: T }
-- A derived field reads back as its output type, which may be a scalar, so the label
-- is an ordinary field stripped by unwrapWrappers rather than a metatable entry.
export type Derived<T> = { __scribeDerived: T }

export type NumberMeta = { Min: number?, Max: number? }
-- Scribe.Number only. `Precision` opts into a narrower wire form; Min and Max alone
-- select nothing. Kept off NumberMeta because a bounded Int already packs from its
-- own bounds, so Precision has nothing to say there.
export type FloatMeta = { Min: number?, Max: number?, Precision: (number | "f32")? }
-- Scribe.Big only. A bound past 1.8e308 must be written as a numeric string, because
-- a larger literal is already math.huge and the template validator rejects it.
export type BigMeta = { Min: (number | string)?, Max: (number | string)? }
export type StringMeta = { MaxLength: number? }
-- Scribe.CFrame only. The same knob as FloatMeta's Precision pointing the other way,
-- since a CFrame defaults to the lossy form. "exact" is the only value: a CFrame has no
-- intermediate widths to name.
export type CFrameMeta = { Precision: "exact"? }
-- Container declarator options. Not generic in the element type on purpose: an
-- element-typed option would let Luau infer the element type from it rather than
-- from `shape`, silently redefining the field.
export type ArrayOpts = { MaxItems: number?, Evict: ("Front" | "Back")? }
export type SetOpts = { MaxItems: number? }
export type CooldownOptions = { IncludeOfflineTime: boolean? }
export type MapKeyType = "integer" | "string"
-- What a Scribe.Big field reads back, which is also what the declarator returns.
-- `__scribeBig` lives in the metatable rather than in the fields: a label field travels
-- into every read, so `Get().Wealth.__scribeBig` would typecheck while being nil.
type BigFields = {
	M: number,
	E: number,
	Short: (self: any, decimals: number?) -> string,
	ToNumber: (self: any) -> number,
	-- Pow returns another big, typed `any` rather than BigValue: spelling the recursion
	-- here tips bundles in test/TypeCheck.luau past the solver's complexity budget. The
	-- accessor tree gets the real self-referential type from ValueType above.
	Pow: (self: any, n: number) -> any,
	Log10: (self: any) -> number,
}
type BigMt = { __scribeBig: true }
export type BigValue = typeof(setmetatable({} :: BigFields, {} :: BigMt))
-- What a Scribe.MapOf field reads back: the whole map. The declared key is a
-- singleton that has to become a real indexer key type, hence the type function; the
-- label and the key ride the metatable, as with Big, Flags and SetOf.
-- selene: allow(undefined_variable)
type function MapShape(K, V)
	local ts = types
	local key = if K:is("singleton") and K:value() == "integer" then ts.number else ts.string
	local out = ts.newtable(nil, { index = key, readresult = V, writeresult = V }, nil)
	local mt: { [type]: type } = {}
	mt[ts.singleton("__scribeMapKey")] = K
	out:setmetatable(ts.newtable(mt, nil, nil))
	return out
end
export type MapOf<K, V> = MapShape<K, V>
export type DictOpts = { MaxKeys: number?, MaxKeyLength: number? }

-- Template-aware config types. Annotate a config local with one and `Stat` / `Cost.Path`
-- become the template's numeric leaf-path union while `Grant` receives the typed accessor
-- tree. The annotation is required: in the same table literal that declares the template,
-- Luau widens the string literals before the template type is known.
export type LeaderboardConfig<T = any> = {
	Stat: StatPathsType<T, true>,
	Limit: number?,
	Scale: number?,
	-- Scribe.Big stats only: significant figures the ranking key carries, 1 to 15
	-- (default 12). Every extra figure costs a factor of ten of exponent range,
	-- because the two halves share one integer under 2^53.
	SigFigs: number?,
	Replicate: boolean?, -- default false: server-only (Data.GetLeaderboard on the server); true streams the board to clients
	RefreshInterval: number?, -- approximate seconds between reads of this board (default 60, floor 60, jittered)
	StoreName: string?, -- override the OrderedDataStore name (default "LB_<board>")
}

export type ProductConfig<T = any> = {
	Id: number,
	Category: string?,
	Grant: ((data: GrantDataType<T>) -> ())?,
	Grants: string?,
}

export type PurchaseSpec<T = any> = {
	Cost: { Path: StatPathsType<T, false>, Amount: number },
	Category: string?,
	ItemId: string,
	Grant: ((data: GrantDataType<T>) -> ())?,
	Meta: { [string]: any }?,
}

-- Loose, read-only option shapes. They deliberately do not depend on T: inside the
-- Scribe({ ... }) literal the template type is still being inferred, so strict fields
-- would widen and reject valid configs. Read-only props keep annotated strict tables
-- assignable.
type LeaderboardConfigLoose = {
	read Stat: string,
	read Limit: number?,
	read Scale: number?,
	read SigFigs: number?,
	read Replicate: boolean?,
	read RefreshInterval: number?,
}

type ProductConfigLoose = {
	read Id: number,
	read Category: string?,
	read Grant: ((data: any) -> ())?,
	read Grants: string?,
}

-- Economy is loose for the same reason: a Resolve lambda's parameter would
-- generalize inside the literal and a strict field would reject it. Annotate a
-- config local with the exported `Scribe.EconomyConfig` for strict checking.
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
	UserOwnsGamePassAsync: ((userId: number, passId: number) -> boolean)?, -- advanced/test seam
	DevMode: boolean?, -- advanced/test seam: overrides the RunService:IsStudio() default
	IsRunning: boolean?, -- advanced/test seam: overrides the RunService:IsRunning() default (false builds the edit-mode client half)
	MigrationShadow: boolean?, -- audit aid: re-runs migrations against raw pre-Reconcile data and warns on divergence (re-executes your migration bodies)
	ImportLegacyData: ((player: Player, userId: number) -> { [string]: any }?)?, -- adopt data from another library, once, before Scribe has ever saved for this player
	OnPlayerInit: ((player: Player, rawData: { [string]: any }, isNewProfile: boolean) -> ())?,
	OnPlayerLeaving: ((player: Player, data: any, reason: LifecycleReason) -> ())?,

	-- persistence
	ProfileStoreIndex: string, -- REQUIRED: the DataStore name (each game must name its own store)
	ProfileKeyPrefix: string, -- REQUIRED: prefix for per-player keys (e.g. "PLAYER_"); "" means bare user-id keys
	SaveInterval: number?, -- seconds between autosaves per profile (default 300, floor 15)
	ProfileStore: any?, -- explicit ProfileStore module (module table or ModuleScript)
	Mode: ("Live" | "Mock" | "NoSave")?, -- persistence mode (default "Live"); overrides the legacy flags below
	TargetUserId: number?, -- load this user's profile instead of the joining player's
	-- Legacy persistence flags, superseded by Mode. Still honoured when Mode is
	-- absent; ignored (with a startup warning) when it is present.
	UseMock: boolean?,
	ViewedUserId: number?,
	OverriddenUserId: number?,
	DontSave: boolean?,
	ResetData: boolean?,
	LoadFailurePolicy: ("Kick" | "Wait")?,
	LoadTimeout: number?,
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
	PurchaseIdTTL: number?,
	MaxProcessedPurchaseIds: number?,
	PurchaseClaimTTL: number?,
	MaxPurchaseClaims: number?,
	AllowDuplicateGifts: boolean?,
	NoGiftIntentPolicy: ("GrantOrCredit" | "Hold")?,

	-- economy analytics
	Economy: EconomyConfigLoose?,

	-- behaviour / limits
	CommandRateLimit: number?,
	RequestTimeout: number?,
	MaxInboundBytes: number?,
	MaxInboundRetainedBytes: number?,
	MaxOutboundBytes: number?,
	MaxInboundFrameRate: number?,
	TransportChannel: string?,

	-- integrity
	BoundsPolicy: ("Clamp" | "Reject")?,
	WipeGuardPolicy: ("Warn" | "Block")?,
	SchemaPolicy: ("Warn" | "Reject")?, -- check stored data against the template at load; off when absent
	BudgetPolicy: "Defer"?, -- pace the leaderboard background loops on the DataStore request budget; off when absent
	WipeGuardShrinkRatio: number?,

	-- diagnostics
	LogLevel: ("Debug" | "Info" | "Warn" | "Error" | "Fatal")?,
	LogRingSize: number?, -- entries Log.GetRecent retains (default 512)
	StatusThresholds: { FailWindow: number?, FailCount: number?, RecoverStreak: number? }?,
	Banner: boolean?, -- default true: print one "Scribe vX.Y.Z ... ready" line on load
}

export type ServerData<T> = ServerDataType<T, Player>

export type ClientData<T> = ClientDataType<T>

-- One player's typed accessor tree: the type of `Data[player]`, `Data.Get(player)` and
-- the client's `Data.Get()`. A plain alias because a type function cannot be invoked
-- across a module boundary: `Scribe.ValueType<T>` silently resolves to `any` rather than
-- erroring, so this is the only way a consumer can name the type.
export type PlayerData<T> = ValueType<T>

export type Bundle<T> = {
	Server: ServerData<T>,
	Client: ClientData<T>,
}

--[=[
	@within Scribe
	@interface Bundle
	@tag Setup
	.Server Server -- the server-side data API (use on the server)
	.Client Client -- the client-side data API (use on the client)
	What `Scribe(options)` returns. The same shared module is required on both
	sides; use `.Server` on the server and `.Client` on the client.
]=]

--[=[
	@within Scribe
	@interface ScribeOptions
	@tag Setup
	.Template T -- your data shape, built from plain values and declarators
	.ProfileStoreIndex string -- the DataStore name, which has no default
	.ProfileKeyPrefix string -- per-player key prefix such as "PLAYER_"; "" means bare user-id keys
	The table you hand `Scribe(options)`. Only the three fields above are
	required, and every other option has a working default, so the smallest real
	configuration is three lines long.

	Roughly fifty further options cover persistence, monetization, gifting,
	limits, integrity and diagnostics. Each is listed with its default, its
	accepted values and what happens when it is wrong in the
	[Configuration reference](../configuration.md), which is the source of truth
	for all of them. This entry deliberately does not restate that page.
]=]

--------------------------------------------------------------------------------
-- Exported type reference
--
-- Doc blocks for the exported types, gathered here rather than beside the declarations:
-- @interface/@type blocks are keyed by name, and half of these types are re-exported
-- from Types.luau with nothing here to sit beside. A new exported type needs a block or
-- it renders nowhere.
--------------------------------------------------------------------------------

--[=[
	@type Timed<T> { __scribeTimed: T }
	@tag Declarators
	What [Scribe.Timed] returns, and the type a cooldown field carries in your
	template. You never build one of these yourself. Emberfall declares
	`LastDaily = Scribe.Timed(86400)`, arms it with [Value.SetTimed], and asks
	about it with [Server.OnCooldown] and [Server.PeekCooldown]. See
	[Timers & Cooldowns](../time.md).
]=]

--[=[
	@type Flags { string }
	@tag Declarators
	What a [Scribe.Flags] field reads back: the member names currently enabled,
	not the full set of declared members. Emberfall's
	`Settings = Scribe.Flags({ "Music", "Sfx", "Tips" })` reads back as
	`{ "Music", "Tips" }` for a player who turned Sfx off. Flip one member with
	[Value.Enable], [Value.Disable] or [Value.Toggle], and test one with
	[Value.Has].
]=]

--[=[
	@type SetOf<T> { T }
	@tag Declarators
	What a [Scribe.SetOf] field reads back: its members, deduplicated and in
	sorted order, so two profiles holding the same members hold the same table.
	A set has no positions, so you change it with [Value.Add] and [Value.Remove]
	rather than by index, and both return `false` when they would be a no-op.
	See [Containers](../containers.md).
]=]

--[=[
	@type ServerOnly<T> { __scribeServerOnly: T }
	@tag Declarators
	Wraps a field so it never leaves the server. A [Scribe.ServerOnly] field is
	absent from the replicated tree entirely, so no part of it reaches the wire
	even inside a whole-subtree read, and a client cannot ask for it. Use it for
	anything an exploiter must not see, such as Emberfall's anti-cheat counters.
	See [Replication & Visibility](../visibility.md).
]=]

--[=[
	@type Derived<T> { __scribeDerived: T }
	@tag Declarators
	What [Scribe.Derived] returns. A derived field is computed from other fields
	rather than stored, so it is read-only and [Value.Set] on one throws.
	Emberfall's `Level` derives from `Xp`, recomputes whenever Xp changes, and
	replicates like any other field. See [Derived Fields](../derived.md).
]=]

--[=[
	@type MapOf<K,V> { [K]: V }
	@tag Declarators
	What a [Scribe.MapOf] field reads back: the whole map, keyed by the type you
	declared. Unlike a dictionary the key set is open, so Emberfall's
	`Friends = Scribe.MapOf("integer", { ... })` accepts any user id. Add and
	remove keys with [Value.Set] and [Value.Remove], and watch them with
	[Value.OnKeyAdded] and [Value.OnKeyRemoved].
]=]

--[=[
	@type MapKeyType "integer" | "string"
	@tag Declarators
	The key type you name in the first argument to [Scribe.MapOf]. It is a
	declaration rather than a hint. A DataStore serializes every object key to a
	string, so an integer map would come back holding `"123"` where it stored
	`123`; the declared type is what lets Scribe convert the keys back
	unambiguously on load.
]=]

--[=[
	@type BigValue
	@tag Declarators
	What a [Scribe.Big] field reads back, and what its arithmetic returns. It is
	an object rather than a number, so `data.Get().Wealth` hands you something
	carrying `.M`, `.E` and a handful of methods. Its surface has its own page:
	see [BigValue](bigvalue.md) and [Big Numbers](../big-numbers.md).
]=]

--[=[
	@interface FloatMeta
	.Min number? -- lowest accepted value; a write below it clamps or rejects per BoundsPolicy
	.Max number? -- highest accepted value
	.Precision (number | "f32")? -- opt in to a narrower wire form; omit to keep the full f64
	@tag Declarator options
	The options table for [Scribe.Number]. `Precision` is the only thing that
	narrows the field on the wire, and declaring Min and Max alone does not imply
	it. [Scribe.Int] takes Min and Max but refuses Precision, because a bounded
	integer already packs from its own bounds and there would be nothing left for
	Precision to say.
]=]

--[=[
	@interface BigMeta
	.Min (number | string)? -- lowest accepted value
	.Max (number | string)? -- highest accepted value
	@tag Declarator options
	The options table for [Scribe.Big]. A bound past 1.8e308 has to be written as
	a numeric string, because a larger Lua literal is already `math.huge` and the
	template validator rejects that. Emberfall caps prestige currency with
	`Scribe.Big(0, { Max = "1e400" })`.
]=]

--[=[
	@interface CFrameMeta
	.Precision "exact"? -- store and send the full-fidelity CFrame instead of the packed one
	@tag Declarator options
	The options table for [Scribe.CFrame]. A CFrame packs lossily by default,
	which is what you want for a saved checkpoint or camera. `"exact"` is the only
	other value, because a CFrame has no intermediate widths to offer the way a
	float does.
]=]

--[=[
	@interface ArrayOpts
	.MaxItems number? -- cap on length; growth past it is refused unless Evict is set
	.Evict ("Front" | "Back")? -- turn the cap into a rolling window, dropping from that end
	@tag Declarator options
	The options table for [Scribe.ArrayOf], and the only container options that
	include Evict. Without MaxItems the array grows unbounded, which is how a
	profile quietly outgrows its DataStore budget. Emberfall keeps a rolling
	combat log with `Scribe.ArrayOf(Scribe.String(""), { MaxItems = 50, Evict = "Front" })`.
	See [Containers](../containers.md).
]=]

--[=[
	@interface SetOpts
	.MaxItems number? -- cap on membership; growth past it is refused
	@tag Declarator options
	The options table for [Scribe.SetOf]. The cap always refuses rather than
	evicting, and Evict itself is rejected as an unknown option here, because a
	set has no oldest member to drop.
]=]

--[=[
	@interface DictOpts
	.MaxKeys number? -- cap on how many keys the container may hold
	.MaxKeyLength number? -- cap on the byte length of any one key, string keys only
	@tag Declarator options
	The options table for [Scribe.DictOf] and [Scribe.MapOf]. Both caps matter
	because keys are attacker-controlled the moment a client command can name
	one, and an unbounded key set is the quickest way past a profile's size
	limit. MaxKeyLength counts bytes rather than characters, and an integer
	[Scribe.MapOf] refuses it outright, where it would read as a cap that does
	nothing.
]=]

--[=[
	@interface PurchaseSpec
	.Cost { Path: string, Amount: number } -- the numeric field to debit, and by how much
	.ItemId string -- what is being bought; recorded on the log entry
	.Category string? -- a grouping label of your choosing, for filtering later
	.Grant ((data) -> ())? -- runs inside the same transaction as the debit
	.Meta { [string]: any }? -- extra fields stored with the log entry
	.IdempotencyKey string? -- max 64 bytes; two calls carrying the same key apply once
	@tag Monetization
	The table you hand [Server.Purchase] for a soft-currency purchase. The debit
	and the Grant either both happen or neither does, so a Grant that throws
	leaves the balance exactly where it was. A refused purchase claims nothing,
	which is why retrying after one still works even with a key.
	See [Monetization](../monetization.md).
]=]

--[=[
	@interface PurchaseFilter
	.Kind ("Robux" | "InGame")? -- Robux receipts, soft-currency purchases, or both when omitted
	.Category string? -- match the Category recorded on the purchase
	.ItemId string? -- match a single item id
	.Since number? -- only entries at or after this Unix timestamp, in seconds
	.Limit number? -- the most recent N matches
	@tag Monetization
	The optional filter you pass [Server.GetPurchases] or [Client.GetPurchases].
	The fields combine with AND, so omitting all of them returns the whole
	retained log, which is itself capped. See [Monetization](../monetization.md).
]=]

--[=[
	@interface EconomyMeta
	.Flow ("Source" | "Sink")? -- default: Increment is a Source, Decrement is a Sink
	.TransactionType (Enum.AnalyticsEconomyTransactionType | string)? -- default "Gameplay"
	.ItemSku string? -- what was bought or awarded
	.Currency string? -- override the logged currency label; defaults to the field's name
	.Fields { [string]: any }? -- values for the custom fields you declared in Economy
	@tag Monetization
	The tag you pass [Value.Increment] or [Value.Decrement] to have Scribe emit a
	Roblox economy event alongside the write. Every field is optional and an
	untagged Increment emits nothing, so you opt in per call rather than per
	field. `Source` and `Item` are still accepted as aliases of TransactionType
	and ItemSku. See [Economy Analytics](../economy.md).
]=]

--[=[
	@interface LeaderboardEntry
	.Rank number -- 1 for the top entry
	.UserId number -- the player's user id
	.Name string -- the username recorded when the score was written
	.Score (number | BigScore) -- a big board hands back the big itself, not the packed key
	@tag Leaderboards
	One row of the array [Server.GetLeaderboard] and [Client.GetLeaderboard]
	return. `Name` is a snapshot rather than a live lookup, so a player who has
	since changed their username shows the old one until their score is written
	again. See [Leaderboards](../leaderboards.md).
]=]

--[=[
	@interface ExchangeLeg
	.Path { string } -- the exchangeable path, a top-level field or container
	.Kind ("Key" | "Qty" | "Stack") -- whole entry, an amount, or part of a stacked entry
	.Key any? -- Key and Stack: the container key, set member or array value
	.Amount number? -- Qty and Stack: how much to move
	@tag Exchange
	One item in a basket handed to [Server.Exchange.Attempt], naming what that player
	GIVES. Every `Path` must be declared in the `Exchangeable` option, and a leg is
	checked against that list by path AND by kind before any value moves. See
	[Exchange](../exchange.md).
]=]

--[=[
	@interface OpenLeg
	.Path { string } -- the path the value came from, or is going to
	.Kind string -- "Key", "Qty" or "Stack"
	.Key any? -- the container key, where the leg has one
	.Amount number? -- how much, for a Qty or Stack leg
	@tag Exchange
	One leg of what a player has staked or is owed, as reported by
	[Server.Exchange.Open]. Freshly built on every call and aliases nothing in Scribe's
	ledger, so it is safe to keep or mutate.
]=]

--[=[
	@interface OpenExchange
	.Id string -- the exchange id, which the operator verbs take
	.State ("Claimed" | "Staked" | "Delivering") -- how far this exchange got
	.Partner number? -- the counterparty's UserId
	.Staked { OpenLeg } -- what this player handed over
	.Owed { OpenLeg } -- what this player is owed
	.Since number? -- Unix timestamp the exchange reached its current state
	@tag Exchange
	One open exchange, as reported by [Server.Exchange.Open]. Escrow takes value out of
	the balance on purpose and resolution is not time bounded, so `Staked` and `Owed`
	are how a game shows a player where their items went rather than leaving them
	looking at a hole. See [Exchange](../exchange.md).
]=]

--[=[
	@interface SaveInfo
	.Dirty boolean -- true when there are writes that have not reached the DataStore
	.LastSaveAt number? -- Unix timestamp of the last successful save, in seconds; nil before the first
	.LastResult ("Ok" | "Fail")? -- how the last save attempt ended
	.Size number? -- approximate bytes written by the last successful save
	@tag Diagnostics
	What [Server.GetSaveInfo] and [Client.GetSaveInfo] return. `Size` is the field
	worth watching: a profile creeping toward the DataStore limit shows up here
	long before a save actually starts failing. See
	[Diagnostics](../diagnostics.md).
]=]

--[=[
	@interface BudgetSnapshot
	.Available boolean -- false when the engine could not be asked at all
	.Reason string? -- why not, when Available is false
	.Budgets { [string]: number } -- remaining requests, keyed by DataStoreRequestType name
	.At number -- Unix timestamp when the snapshot was taken, in seconds
	@tag Diagnostics
	What [Scribe.GetBudgetSnapshot] returns. It is resolved per call and never
	cached, and a server with no DataStoreService at all, such as a simulated
	one, reports Available false rather than raising. See
	[Diagnostics](../diagnostics.md).
]=]

--[=[
	@interface LogEntry
	.At number -- Unix timestamp when the entry was recorded, in seconds
	.Level LogLevel -- Debug through Fatal
	.Category LogCategory -- which subsystem emitted it
	.Code LogCode -- the stable identifier you branch on
	.Message string -- human-readable text, not stable across versions
	.Context { [string]: any }? -- structured detail; the keys vary by Code
	@tag Diagnostics
	One record from [Scribe.GetRecentLogs], and the single argument every sink
	registered with [Scribe.AddLogSink] receives. Branch on `Code`, never on
	`Message`. See [Diagnostics](../diagnostics.md).
]=]

--[=[
	@type LogLevel "Debug" | "Info" | "Warn" | "Error" | "Fatal"
	@tag Diagnostics
	How severe a [LogEntry] is. The `LogLevel` option sets the floor, and
	anything below it is never recorded at all, so raising it is the cheapest way
	to quieten a noisy production log. See
	[Configuration](../configuration.md#diagnostics).
]=]

--[=[
	@type LogCategory "Persistence" | "Replication" | "Transport" | "Commands" | "Leaderboards" | "Monetization" | "Gifting" | "Integrity" | "Lifecycle" | "Derived"
	@tag Diagnostics
	Which subsystem emitted a [LogEntry]. A sink added with [Scribe.AddLogSink]
	usually filters on this rather than on individual codes, so you can route
	Persistence somewhere loud and Replication somewhere quiet.
]=]

--[=[
	@type LogCode
	@tag Diagnostics
	The stable identifier on a [LogEntry], such as `PROFILE_LOAD_FAILED`. There
	are over 150 of them, and every one is listed with its meaning, its severity
	and what to do about it in the [Log Code Reference](../log-codes.md). This is
	the field to branch on. `Message` is prose and is free to change between
	versions.
]=]

--[=[
	@type LifecycleReason "load-failed" | "migration-failed" | "session-ended" | "player-left" | "shutdown" | "still-loading" | "timeout"
	@tag Reasons
	Why a data session ended, or why waiting for data produced no tree. There is
	one value per state so you can branch exhaustively. It is the second return
	of [Server.WaitForData], the argument [Server.SessionEnded] fires with, and
	the reason [Server.GetState] stores. The names are also on [Scribe.Reason] if
	you would rather not spell the strings. See
	[Session Lifecycle](../lifecycle.md).
]=]

--[=[
	@type RequestReason "rate-limited" | "not-ready" | "unknown-command" | "bad-args" | "bad-idempotency-key" | "error" | "reply-encode-failed" | "timeout" | "send-failed" | "edit-mode" | "mock-error"
	@tag Reasons
	Why Scribe itself refused a [Client.Request]. The last four are produced on
	the client and never reach the server. A handler that throws yields "error",
	and its traceback goes to the COMMAND_ERROR log rather than to the client, so
	an exploiter learns nothing from a crash. The names are also on
	[Scribe.RequestReason]. See [Commands & Requests](../commands.md).
]=]

--[=[
	@type PurchaseReason "player data not loaded" | "invalid Cost spec" | "invalid Cost amount" | "invalid cost path" | "cost path is not a spendable number" | "insufficient funds"
	@tag Reasons
	The fixed refusals of [Server.Purchase]. They are not exhaustive over the
	second return: a Grant that throws passes its own error text through instead.
	Test for `"insufficient funds"` specifically rather than assuming any other
	string is one of these. The names are also on [Scribe.PurchaseReason].
]=]

--[=[
	@type GiftReason
	@tag Reasons
	The fixed refusals of [Server.PromptGift]. Each one is a finished sentence you
	can show a player unaltered: `"buyer data not loaded"`,
	`"invalid recipient"`, `"cannot gift yourself"`, `"gift cooldown"`,
	`"too many pending gifts"`, `"recipient already owns this"`,
	`"data services are experiencing issues; try again later"`,
	`"could not reserve gift credit; try again later"`,
	`"could not deliver gift; try again later"`,
	`"gift delivery could not be confirmed; do not send it again"`,
	`"could not record gift intent; try again later"`, and
	`"a gift of this item is already pending; try again shortly"`. Two further
	refusals interpolate a value and so cannot be members. The names are also on
	[Scribe.GiftReason]. See [Gifting](../gifting.md).

	The last two delivery refusals are not interchangeable. `DeliveryFailed` means
	the gift provably did not go out and a spent credit has been handed back, so a
	retry is the right advice. `DeliveryUnconfirmed` means the delivery write may
	have landed with only its answer lost: the credit stays spent on purpose, and a
	retry would send a SECOND gift under an id the recipient cannot dedupe. Show
	them as different outcomes.
]=]

--------------------------------------------------------------------------------
-- Runtime
--------------------------------------------------------------------------------

local KNOWN_OPTION_KEYS: { [string]: boolean } = {
	Template = true,
	Exchangeable = true,
	Transport = true,
	TransportChannel = true,
	Migrations = true,
	UserOwnsGamePassAsync = true,
	DevMode = true,
	IsRunning = true,
	MigrationShadow = true,
	ImportLegacyData = true,
	OnPlayerInit = true,
	OnPlayerLeaving = true,
	ProfileStoreIndex = true,
	ProfileKeyPrefix = true,
	SaveInterval = true,
	ProfileStore = true,
	Mode = true,
	TargetUserId = true,
	UseMock = true,
	ViewedUserId = true,
	OverriddenUserId = true,
	DontSave = true,
	ResetData = true,
	LoadFailurePolicy = true,
	LoadTimeout = true,
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
	PurchaseIdTTL = true,
	MaxProcessedPurchaseIds = true,
	PurchaseClaimTTL = true,
	MaxPurchaseClaims = true,
	AllowDuplicateGifts = true,
	NoGiftIntentPolicy = true,
	Economy = true,
	CommandRateLimit = true,
	RequestTimeout = true,
	MaxInboundBytes = true,
	MaxInboundRetainedBytes = true,
	MaxOutboundBytes = true,
	MaxInboundFrameRate = true,
	BoundsPolicy = true,
	WipeGuardPolicy = true,
	SchemaPolicy = true,
	BudgetPolicy = true,
	WipeGuardShrinkRatio = true,
	LogLevel = true,
	LogRingSize = true,
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
	local anyOpts = options :: any
	-- Server only on purpose: the client reads neither of these. Validating them before
	-- the realm branch would force the live DataStore name and key format into the shared
	-- module every client requires, rather than behind `if RunService:IsServer()`.
	if RunService:IsServer() then
		-- Storage location is intentional, never defaulted: two games (or a test
		-- build) accidentally sharing the "Default" store is a silent data hazard.
		if type(anyOpts.ProfileStoreIndex) ~= "string" or anyOpts.ProfileStoreIndex == "" then
			error("Scribe: options.ProfileStoreIndex is required: name your game's DataStore explicitly", 2)
		end
		-- Required, but "" is legitimate: it means bare user-id keys, which is what a
		-- game adopting an existing store keyed only by user id needs. Absent or
		-- non-string is still an error, so the choice stays explicit.
		if type(anyOpts.ProfileKeyPrefix) ~= "string" then
			error(
				'Scribe: options.ProfileKeyPrefix is required: set a per-player key prefix (e.g. "PLAYER_"), or "" for bare user-id keys',
				2
			)
		end
	end

	-- Scribe.Configure refuses to run past this point, because its process-wide values
	-- are applied during construction. Set after the option guards, so a call that
	-- only fails a guard does not poison the flag for a later Configure.
	Config.BundleConstructed = true

	-- Luau does not reject unknown table keys, so a misspelled option name is silently
	-- ignored. Catch it in Studio with a startup warning.
	if RunService:IsStudio() then
		for key in options :: any do
			if type(key) == "string" and not KNOWN_OPTION_KEYS[key] then
				Log.Warn(
					"Lifecycle",
					"UNKNOWN_OPTION",
					`unknown Scribe option "{key}": check the spelling`,
					{ Option = key }
				)
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

	-- A Sandboxed script cannot fire a non-Sandboxed event, so a Sandboxed Scribe
	-- silently never sends a replication frame and nothing syncs. Usually caused by
	-- inserting the package from the toolbox rather than syncing it from source.
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

	-- Edit mode (a storybook, the command bar, a plugin) has no server, yet
	-- RunService:IsServer() is still true there. Dispatching on that alone builds the
	-- server half, which resolves the transport and leaves RemoteEvents saved into the
	-- place file; the client half understands edit mode. `IsRunning` is also the seam
	-- specs use, since RunService cannot be patched.
	local isRunning = if anyOptions.IsRunning ~= nil then anyOptions.IsRunning == true else RunService:IsRunning()

	local bundle: any
	if RunService:IsServer() and isRunning then
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
				error(
					if isRunning
						then "Scribe: the Server API is not available on the client. Client writes go through Data.Request commands"
						else "Scribe: the Server API is not available in edit mode. Scribe builds only the client half there (storybooks, the command bar)",
					2
				)
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
	`.Client` on the client from the same shared module. Every option the table
	accepts is documented in [Configuration](../configuration.md).

	In edit mode (`RunService:IsRunning()` false, as in a UI Labs / Hoarcekat
	storybook or the command bar) there is no server to build, so the bundle holds
	the edit-mode client half and `.Server` errors if touched.

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
	@return ServerOnly<T>
	Marks a **root** field server-only: it persists and is readable on the
	server, but is never replicated to any client. May also wrap a nested field
	to keep just that subtree server-side.

	The field is absent from the **client's** accessor type, so reading it there
	is a type error rather than a `nil` at runtime. On the server it reads like
	any other field.

	Combines with [Scribe.Session] for runtime state only the server sees:
	`Scribe.ServerOnly(Scribe.Session(v))`. Combining it with [Scribe.Shared] is
	a startup error, since a field has one replication target, not two.
]=]
function Scribe.ServerOnly<T>(value: T): ServerOnly<T>
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

	Combines with [Scribe.Session] for runtime state everyone sees and nothing
	saves: `Scribe.Shared(Scribe.Session(v))`. Combining it with
	[Scribe.ServerOnly] is a startup error.
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
	Marks a **root** field session-only: never persisted, and replicated to the
	owner unless another wrapper says otherwise. Ideal for runtime state like
	`InCombat` that should reset on rejoin.

	Saving and replication are independent, so this composes with exactly one of
	[Scribe.ServerOnly] (nobody sees it) or [Scribe.Shared] (everyone does), in
	either order. Doubling it up is a startup error.
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
	@param meta FloatMeta?
	@return number
	Declares a floating-point field with optional bounds and an optional narrowed
	wire form.

	`Min` and `Max` must be finite, since `math.huge` and `NaN` would each declare a
	bound that silently checks nothing. For a bound past the double range use
	[Scribe.Big], whose bounds may be written as numeric strings.

	`Precision` is opt-in and narrows only the replicated copy; the server keeps and
	persists the full double either way. A fixed-point step requires both `Min` and
	`Max`, and bounds too wide for the width you ask for refuse to compile.

	```lua
	Health = Scribe.Number(100, { Min = 0, Max = 100, Precision = 0.5 }), -- 1 byte
	```

	See [Narrowing a float](../templates.md#narrowing-a-float) for the byte table.
]=]
function Scribe.Number(default: number, meta: FloatMeta?): number
	return Marker.make("Number", default, meta :: any) :: any
end

--[=[
	@within Scribe
	@tag Field Types
	@function Big
	@param default (number | string)?
	@param meta BigMeta?
	@return BigValue
	A number with unlimited range, for an idle or simulator currency that runs past
	2^53. It carries about 15 significant digits at any magnitude, so
	`1e20 + 1 == 1e20`; use [Scribe.Int] when every digit has to be exact.

	```lua
	Essence = Scribe.Big(0, { Min = 0, Max = "1e600" }), -- a bound past 1.8e308 must be a string
	data.Essence.Get():Short() --> "1.95Dc"
	```

	`Set` and every arithmetic method take a plain number, a numeric string, or
	another big value, and [Value.Multiply] and [Value.Divide] exist only here.
	`Get()` returns a [BigValue](bigvalue.md), not a plain number, and it will not
	compare against one: `Get() < 2000` throws and `Get() == 5` is silently false.

	A big field may be a leaderboard stat, which requires non-negative values and
	refuses `Scale`. See [Big Numbers](../big-numbers.md) and
	[Leaderboards](../leaderboards.md#ranking-a-scribebig).
]=]
function Scribe.Big(default: (number | string)?, meta: BigMeta?): BigValue
	return Marker.make("Big", if default == nil then 0 else default, meta :: any) :: any
end

--[=[
	@within Scribe
	@tag Field Types
	@function String
	@param default string
	@param meta { MaxLength: number? }?
	@return string
	Declares a string field, optionally length-capped.

	`MaxLength` is a **byte** budget and must be a non-negative integer; a template
	declaring otherwise fails to compile. Over-long values are truncated on a
	character boundary (never mid-character, which would produce invalid UTF-8 and
	fail the profile's next save), or refused outright under
	`BoundsPolicy = "Reject"`.
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
	@function Flags
	@param members { string }
	@return Flags
	A fixed set of named booleans stored as one field, up to 32 members, addressed
	by name:

	```lua
	Settings = Scribe.Flags({ "Music", "Sfx", "TutorialDone" }),
	data.Settings.Enable("Music")
	data.Settings.Has("Music") --> true
	```

	The accessors are [Value.Enable], [Value.Disable], [Value.Toggle], [Value.Has],
	[Value.Count] and [Value.Clear]. Members are not accessor children, so it is
	`Settings.Enable("Music")` and not `Settings.Music.Set(true)`. Enabling an
	undeclared name is an error, and setting a flag to what it holds writes nothing.

	The stored value is the enabled member names, so reordering or removing members
	later is safe, and more than 32 is refused when the template compiles. See
	[Named booleans](../containers.md#named-booleans).
]=]
function Scribe.Flags(members: { string }): Flags
	return Marker.make("Flags", {}, { Members = members }) :: any
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
	Declares a field whose default is produced by `factory` per profile rather than
	frozen once at server start. The field types as the factory's return type, and a
	datatype result is packed for you.

	```lua
	CreatedUnix = Scribe.Dynamic(os.time),
	JoinedAt    = Scribe.Dynamic(function() return DateTime.now() end),
	```

	The factory runs only to seed a brand-new profile, or an existing profile that
	gains the field after you add it, so a returning player keeps a stored value.

	It must be pure, because Scribe also calls it once while your template module
	loads to sample its return type, so anything that yields, errors or reserves an
	id fires that effect with no profile attached. A factory takes no arguments, so
	player-specific defaults belong in `OnPlayerInit`, and `Scribe.Dynamic` inside a
	[Scribe.Session] root is a startup error.
]=]
-- `(...any) -> T` (not `() -> T`) so standard-library functions with optional
-- params typecheck when passed directly, e.g. `Scribe.Dynamic(os.time)`.
function Scribe.Dynamic<T>(factory: (...any) -> T): T
	return Marker.make("Dynamic", factory(), { Factory = factory :: any }) :: any
end

--[=[
	@within Scribe
	@tag Field Types
	@function Derived
	@param output T
	@param inputs { string }
	@param compute (...any) -> T
	@return T
	Declares a field Scribe computes from other declared fields instead of accepting
	writes. It is never persisted, never migrated, recomputed whenever an input
	changes, and replicated only when the receiver cannot compute it itself.

	`output` is an ordinary declarator supplying the type and bounds. `inputs` are
	dotted paths to statically declared scalar fields, passed to `compute` in the
	order written; one derived field may read another, and the compiler orders the
	graph and rejects cycles at startup. `compute` must be pure, because Scribe calls
	it once per realm at startup to seed the default.

	Reads are ordinary (`Get`, `Changed`, `Observe`) and every mutator throws. The
	field must be a root field or live inside a [Scribe.Session] root, and wrapping
	it in `Scribe.Session`, `Scribe.Timed`, `Scribe.Dynamic`, `Scribe.Optional` or a
	container is refused when the template compiles. See
	[Derived Fields](../derived.md).
]=]
function Scribe.Derived<T>(output: T, inputs: { string }, compute: (...any) -> T): Derived<T>
	return Marker.make("Derived", output, { Inputs = inputs, Compute = compute :: any }) :: any
end

--[=[
	@within Scribe
	@tag Field Types
	@function Optional
	@param inner T
	@return T?
	Declares a field that may legitimately be **absent**, wrapping another
	declarator for its type and bounds:

	```lua
	Pets = Scribe.DictOf({
	    Species  = Scribe.String("", { MaxLength = 32 }),
	    Nickname = Scribe.Optional(Scribe.String("", { MaxLength = 20 })),
	}),
	```

	The inner declarator's default is dropped: an optional field has **no** default,
	so it is not seeded into a new profile and not filled in when an element write
	omits it. `Get()` returns `nil` until something writes it, and `Set(nil)` takes
	it back to absent.

	It wraps leaves only. `Scribe.Timed`, `Scribe.Dynamic` and the container
	declarators are all refused inside it, since each of the three exists to supply
	a value an optional field is defined not to have.
]=]
function Scribe.Optional<T>(inner: T): T?
	return Marker.make("Optional", inner) :: any
end

--[=[
	@within Scribe
	@tag Field Types
	@function ArrayOf
	@param shape T
	@param opts ArrayOpts?
	@return { T }
	Declares an array whose elements have a schema, so type checking, bounds and
	datatype packing all apply per element. `shape` may be a record or a single leaf
	declarator, and it nests freely.

	```lua
	PlacedFurniture = Scribe.ArrayOf({
	    Cf = Scribe.CFrame(CFrame.new()), ItemId = Scribe.String("", { MaxLength = 64 }),
	}, { MaxItems = 200, Evict = "Front" }),
	```

	`opts` takes `MaxItems` and `Evict` and nothing else. `MaxItems` refuses growth
	past the cap but leaves an already-oversized container writable, so a rolling
	deploy is safe. `Evict` requires `MaxItems` and names the end an `Insert` at the
	cap drops from, `"Front"` or `"Back"`.

	Element records are closed at every depth, and [Value.Find], [Value.Has] and
	[Value.RemoveValue] compare by value. See [Containers](../containers.md#element-rules).
]=]
function Scribe.ArrayOf<T>(shape: T, opts: ArrayOpts?): { T }
	if opts ~= nil then
		for key in opts :: any do
			-- A silently dropped option (MaxKeys on an ArrayOf, say) leaves the
			-- container uncapped while reading as protected; refuse it.
			if key ~= "MaxItems" and key ~= "Evict" then
				error(`Scribe.ArrayOf: unknown option "{tostring(key)}" (ArrayOf takes MaxItems and Evict)`, 2)
			end
		end
	end
	return Marker.make("ArrayOf", nil, {
		Element = shape,
		MaxItems = if opts then opts.MaxItems else nil,
		Evict = if opts then opts.Evict else nil,
	}) :: any
end

--[=[
	@within Scribe
	@tag Field Types
	@function SetOf
	@param element T
	@param opts SetOpts?
	@return SetOf<T>
	A collection of unique entries: membership, not order. Use it where you would
	otherwise keep a dictionary of `true` values, such as owned items.

	```lua
	Unlocked = Scribe.SetOf(Scribe.String("", { MaxLength = 32 })),
	data.Unlocked.Add("AshfallRidge")    --> true
	data.Unlocked.Remove("AshfallRidge") --> true
	```

	The accessors are [Value.Add], [Value.Remove], [Value.Has], [Value.Find],
	[Value.Count] and [Value.Clear]. `Remove` takes the member itself and returns
	whether it was one. An `Add` of a value already present, or a `Remove` of one
	that is absent, writes nothing and fires no `Changed`.

	Entries are stored deduplicated and sorted, so `element` must be a scalar and a
	record shape is refused by the declarator. `MaxItems` caps membership and is the
	only option. See [Sets of unique values](../containers.md#sets-of-unique-values).
]=]
function Scribe.SetOf<T>(element: T, opts: SetOpts?): SetOf<T>
	if opts ~= nil then
		for key in opts :: any do
			if key ~= "MaxItems" then
				error(`Scribe.SetOf: unknown option "{tostring(key)}" (SetOf takes MaxItems)`, 2)
			end
		end
	end
	-- A set is deduplicated and sorted, neither of which works on a record: table.sort
	-- throws a bare comparison error on the second member. Refuse it here rather than at
	-- the surprising second Add.
	if type(element) == "table" and (element :: any).__scribeMarker == nil then
		error("Scribe.SetOf takes a scalar element (Scribe.String, Scribe.Int, ...), not a record shape", 2)
	end
	return Marker.make("SetOf", nil, {
		Element = element,
		MaxItems = if opts then opts.MaxItems else nil,
		Unique = true,
	}) :: any
end

--[=[
	@within Scribe
	@tag Field Types
	@function MapOf
	@param keyType MapKeyType
	@param value V
	@param opts DictOpts?
	@return MapOf<K, V>
	A dictionary whose keys have a declared type, for keys that are user ids or
	anything else you would otherwise `tostring` at every write and `tonumber` at
	every read. [Scribe.DictOf] is the string-keyed shorthand.

	```lua
	Friends = Scribe.MapOf("integer", { Name = Scribe.String("") }),
	data.Friends[ava.UserId].Name.Set("Ava") -- no tostring
	```

	`keyType` is `"integer"` or `"string"`, and anything else errors at declaration.
	Integer keys come back as numbers even though a DataStore serializes every object
	key to a string, and fractional, infinite and NaN keys are refused at the write.

	`opts` takes `MaxKeys` and `MaxKeyLength` and nothing else, and `MaxKeyLength`
	with `keyType = "integer"` is an error rather than a cap that could never fire.
	See [Maps with typed keys](../containers.md#maps-with-typed-keys).
]=]
function Scribe.MapOf<K, V>(keyType: K & MapKeyType, value: V, opts: DictOpts?): MapOf<K, V>
	if keyType ~= "integer" and keyType ~= "string" then
		error(`Scribe.MapOf: keyType must be "integer" or "string", got {tostring(keyType)}`, 2)
	end
	if opts ~= nil then
		for key in opts :: any do
			if key ~= "MaxKeys" and key ~= "MaxKeyLength" then
				error(`Scribe.MapOf: unknown option "{tostring(key)}" (MapOf takes MaxKeys and MaxKeyLength)`, 2)
			end
		end
	end
	if keyType == "integer" and opts ~= nil and (opts :: any).MaxKeyLength ~= nil then
		error("Scribe.MapOf: MaxKeyLength applies to string keys only", 2)
	end
	return Marker.make("MapOf", nil, {
		Element = value,
		KeyType = keyType,
		MaxKeys = if opts then opts.MaxKeys else nil,
		MaxKeyLength = if opts then opts.MaxKeyLength else nil,
	}) :: any
end

--[=[
	@within Scribe
	@tag Field Types
	@function DictOf
	@param shape V
	@param opts { MaxKeys: number?, MaxKeyLength: number? }?
	@return { [string]: V }
	Declares a string-keyed dictionary whose values have a schema, the dictionary
	counterpart of [Scribe.ArrayOf]:

	```lua
	Inventory = Scribe.DictOf({ Count = Scribe.Int(1, { Min = 1, Max = 999 }) }, { MaxKeys = 200 }),
	data.Inventory.Emberblade.Count.Get()        -- nil: nothing has written this key
	data.Inventory.Emberblade.Count.Increment(5) -- 6: starts from the declared default
	```

	A key exists only once something writes it; until then `Get()` is `nil` and
	`Count()` does not include it. Any string is a valid key, so a typo is a new key
	rather than an error. Use plain declared fields when the key set is fixed.

	`MaxKeys` caps the key count and `MaxKeyLength` caps each key's byte length. Both
	are write errors, and `MaxKeyLength` rejects rather than truncates. The element
	rules match [Scribe.ArrayOf]; see [Containers](../containers.md#element-rules).
]=]
function Scribe.DictOf<V>(shape: V, opts: DictOpts?): { [string]: V }
	if opts ~= nil then
		for key in opts :: any do
			if key ~= "MaxKeys" and key ~= "MaxKeyLength" then
				error(`Scribe.DictOf: unknown option "{tostring(key)}" (DictOf takes MaxKeys and MaxKeyLength)`, 2)
			end
		end
	end
	return Marker.make("DictOf", nil, {
		Element = shape,
		MaxKeys = if opts then opts.MaxKeys else nil,
		MaxKeyLength = if opts then opts.MaxKeyLength else nil,
	}) :: any
end

-- Roblox datatype fields (opt-in serialization): stored and replicated as a
-- compact packed buffer; Get/Set/Update/Observe convert at the boundary so
-- callers only ever see the real datatype.
local function datatypeMarker(name: string, default: any, precision: string?): any
	return Marker.make("Datatype", default, { Datatype = name, Precision = precision })
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
	@param meta CFrameMeta?
	@return CFrame
	Declares a `CFrame` field. An axis-aligned rotation, the common case for placed
	structures, packs to 13 bytes; any other rotation packs as a quaternion in 29
	and reads back turned by roughly `1e-7`.

	`Precision = "exact"` is the only option and it is off by default. It stores all
	twelve components as `f32` at a flat 49 bytes, so the value round-trips bit for
	bit. Reach for it when the orientation is data you compare, accumulate or replay.
	`"exact"` is its only accepted value, and `Precision` on any other datatype
	declarator is refused when the template compiles.

	```lua
	Camera = Scribe.CFrame(CFrame.identity, { Precision = "exact" }), -- 49 bytes, lossless
	```

	See [Full-precision CFrames](../datatypes.md#full-precision-cframes) for the byte
	table and for the axis snapping the 13-byte path does.
]=]
function Scribe.CFrame(default: CFrame, meta: CFrameMeta?): CFrame
	if meta ~= nil then
		for key in meta :: any do
			if key ~= "Precision" then
				error(`Scribe.CFrame: unknown option "{tostring(key)}" (CFrame takes Precision)`, 2)
			end
		end
	end
	return datatypeMarker("CFrame", default, if meta then meta.Precision else nil)
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
	@prop Datatypes table
	Low-level helpers for the 17 Roblox datatypes, exposed so a migration can convert
	a legacy representation into the packed form.

	| Call | Returns |
	| --- | --- |
	| `Pack(name, value, precision?)` | the packed `buffer` |
	| `Unpack(name, b)` | the datatype |
	| `IsSupported(name)` | whether Scribe has a codec for `name` |
	| `PrecisionValues(name)` | the `Precision` values `name` accepts, sorted, or `nil` |

	`Pack` and `Unpack` both throw `Scribe: unsupported datatype "<name>"` on a name
	with no codec, so ask `IsSupported` first when the name is not a literal.

	`precision` is optional and additive: omit it and every datatype packs exactly the
	bytes it always has. `PrecisionValues` reports what a datatype accepts, and today
	only [Scribe.CFrame] accepts anything (`"exact"`); any other value throws naming
	the ones it does. `Unpack` takes none, because every layout is self-describing
	from its first byte, which is what lets old data keep decoding.
]=]
Scribe.Datatypes = require(script.Internal.Datatypes)

--[=[
	@within Scribe
	@tag Lifecycle
	@prop Reason { [string]: LifecycleReason }
	Every value [Server.WaitForData] and the
	`SessionEnded` signal can report, as a frozen table, so you can branch on a
	constant instead of a hand-typed string:

	```lua
	local data, reason = Data.WaitForData(player)
	if not data and reason ~= Scribe.Reason.PlayerLeft then
	    warn("data unavailable:", reason)   -- PlayerLeft is routine, not an error
	end
	```

	The seven members are `LoadFailed`, `MigrationFailed`, `SessionEnded`,
	`PlayerLeft`, `Shutdown`, `StillLoading` and `Timeout`. Each one's string, what it
	means and whether it is worth retrying are in the
	[Session Lifecycle](../lifecycle.md#when-there-is-no-data) guide.

	The matching `Scribe.LifecycleReason` type is the same set as a string union,
	so a comparison against a typo fails to type-check.
]=]
--[=[
	@within Scribe
	@param value number | BigValue
	@param decimals number?
	@return string
	Renders a quantity the short way a player reads it: `1.5K`, `100M`, `2.4B`.

	```lua
	local label = Scribe.Short(data.Coins.Get()) -- "1.5M"
	```

	Takes a plain number or a `Scribe.Big` value, so a balance label does not have to
	know which numeric type the field was declared as.

	`decimals` defaults to 2 and rounds rather than truncates, so `Scribe.Short(1500, 0)`
	gives `"2K"`. Anything past the suffix table renders in full rather than losing
	its magnitude.
]=]
function Scribe.Short(value: (number | BigValue)?, decimals: number?): string
	if decimals ~= nil and (type(decimals) ~= "number" or decimals < 0 or decimals % 1 ~= 0) then
		error(`Scribe.Short: decimals must be a non-negative whole number, got {tostring(decimals)}`, 2)
	end
	local big = BigMath.from(value)
	if big == nil then
		error(`Scribe.Short: expected a number or a Scribe.Big value, got {typeof(value)}`, 2)
	end
	return BigMath.toShort(big, decimals)
end

--[=[
	@within Scribe
	@param suffixes { string }
	Replaces the suffix table [Scribe.Short] and `BigValue:Short()` render with.

	```lua
	Scribe.SetShortSuffixes({ "", "K", "M", "B", "T", "aa", "ab", "ac" })
	```

	The defaults run `K, M, B, T, Qa, Qi, Sx` and on up. The conventions diverge past
	`T`, so this exists rather than leaving a game to write its own formatter and stop
	using this one. Index 1 is the units tier and must be empty, because it is what
	renders a small number unchanged.
]=]
function Scribe.SetShortSuffixes(suffixes: { string })
	BigMath.SetSuffixes(suffixes)
end

--[=[
	@within Scribe
	@tag Configuration
	@function Configure
	@param config { AutoSaveInterval: number? }
	Sets configuration that belongs to the process rather than to one bundle. Call
	it once, before constructing any bundle:

	```lua
	Scribe.Configure({ AutoSaveInterval = 60 })
	```

	`AutoSaveInterval` is the autosave cadence, and it lives here because
	ProfileStore's `AUTO_SAVE_PERIOD` is a module-wide constant that also covers any
	direct ProfileStore use in the same game. The per-bundle `SaveInterval` option
	still wins where it is set, and two bundles asking for different cadences logs
	`SAVE_INTERVAL_CONFLICT`. Values below 15 seconds clamp up to it.

	Calling this twice with different values, or after a bundle exists, is an error,
	because the value may already have been applied.
]=]
function Scribe.Configure(config: { AutoSaveInterval: number? })
	if type(config) ~= "table" then
		error("Scribe.Configure: config must be a table", 2)
	end
	for key in config :: { [string]: any } do
		if key ~= "AutoSaveInterval" then
			error(`Scribe.Configure: unknown key "{tostring(key)}" (Configure takes AutoSaveInterval)`, 2)
		end
	end
	if Config.BundleConstructed then
		error("Scribe.Configure must be called before any Scribe bundle is constructed", 2)
	end
	local interval = config.AutoSaveInterval
	if interval ~= nil then
		if type(interval) ~= "number" or interval ~= interval or interval <= 0 then
			error("Scribe.Configure: AutoSaveInterval must be a positive number of seconds", 2)
		end
		if
			Config.AutoSaveSource == "Configure"
			and Config.AutoSaveInterval ~= nil
			and Config.AutoSaveInterval ~= interval
		then
			error(
				`Scribe.Configure: AutoSaveInterval was already set to {Config.AutoSaveInterval}; `
					.. "it is a process-wide setting, so configure it once",
				2
			)
		end
		Config.AutoSaveInterval = interval
		Config.AutoSaveSource = "Configure"
	end
end

Scribe.Reason = table.freeze({
	LoadFailed = "load-failed" :: Types.LifecycleReason,
	MigrationFailed = "migration-failed" :: Types.LifecycleReason,
	SessionEnded = "session-ended" :: Types.LifecycleReason,
	PlayerLeft = "player-left" :: Types.LifecycleReason,
	Shutdown = "shutdown" :: Types.LifecycleReason,
	StillLoading = "still-loading" :: Types.LifecycleReason,
	Timeout = "timeout" :: Types.LifecycleReason,
})

--[=[
	@within Scribe
	@tag Commands
	@prop RequestReason { [string]: RequestReason }
	The reasons Scribe answers a `Client.Request` with, as named constants.

	The eleven members are `RateLimited`, `NotReady`, `UnknownCommand`, `BadArgs`,
	`BadIdempotencyKey`, `Error`, `ReplyEncodeFailed`, `Timeout`, `SendFailed`,
	`EditMode` and `MockError`. Each one's string and what provokes it are in the
	[Commands and Requests](../commands.md#what-the-caller-gets-back-on-failure)
	guide.

	A command handler may return any `(false, string)` of its own; those are
	deliberately not members, so a reason that is not in this table came from your
	handler rather than from Scribe.
]=]
Scribe.RequestReason = table.freeze({
	RateLimited = "rate-limited" :: Types.RequestReason,
	NotReady = "not-ready" :: Types.RequestReason,
	UnknownCommand = "unknown-command" :: Types.RequestReason,
	BadArgs = "bad-args" :: Types.RequestReason,
	BadIdempotencyKey = "bad-idempotency-key" :: Types.RequestReason,
	Error = "error" :: Types.RequestReason,
	ReplyEncodeFailed = "reply-encode-failed" :: Types.RequestReason,
	Timeout = "timeout" :: Types.RequestReason,
	SendFailed = "send-failed" :: Types.RequestReason,
	EditMode = "edit-mode" :: Types.RequestReason,
	MockError = "mock-error" :: Types.RequestReason,
})

--[=[
	@within Scribe
	@tag Commands
	@prop RequestFailed table
	The marker [Client.Request] returns as a third value whenever the refusal is
	Scribe's rather than your handler's.

	`RequestReason` tells you what a reason string means, but not who said it: a
	handler may return any `(false, string)` it likes, including `false, "timeout"`,
	and those values reach the caller verbatim. Compare against this frozen table
	instead; handler values cross the wire, which carries no reference identity, so
	nothing a handler returns can ever equal it.

	```lua
	local ok, reason, failed = Data.Request("EquipItem", itemId)
	if failed == Scribe.RequestFailed then
	    retryLater(reason) -- Scribe refused; `reason` is a RequestReason
	elseif not ok then
	    showToast(reason)  -- your handler's own message, safe to show
	end
	```

	It is present on every framework refusal, including the four the client raises
	with no reply frame at all, and absent on success and on handler values.
]=]
Scribe.RequestFailed = Types.RequestFailed

--[=[
	@within Scribe
	@tag Monetization
	@prop PurchaseReason { [string]: PurchaseReason }
	The fixed refusals of [Server.Purchase]. A `Grant` that throws passes its own
	error text through instead, so a non-member reason is a failed grant.

	The six members are `DataNotLoaded`, `InvalidCostSpec`, `InvalidCostAmount`,
	`InvalidCostPath`, `CostPathNotSpendable` and `InsufficientFunds`. Each one's
	string is in the [Monetization](../monetization.md#reading-the-refusal) guide.
]=]
Scribe.PurchaseReason = table.freeze({
	DataNotLoaded = "player data not loaded" :: Types.PurchaseReason,
	InvalidCostSpec = "invalid Cost spec" :: Types.PurchaseReason,
	InvalidCostAmount = "invalid Cost amount" :: Types.PurchaseReason,
	InvalidCostPath = "invalid cost path" :: Types.PurchaseReason,
	CostPathNotSpendable = "cost path is not a spendable number" :: Types.PurchaseReason,
	InsufficientFunds = "insufficient funds" :: Types.PurchaseReason,
})

--[=[
	@within Scribe
	@tag Monetization
	@prop GiftReason { [string]: GiftReason }
	The fixed refusals of [Server.PromptGift]. Two further refusals are interpolated
	with the offending value and so cannot be constants: an unknown product name, and
	a failed purchase prompt.

	The twelve members are `BuyerDataNotLoaded`, `InvalidRecipient`,
	`CannotGiftYourself`, `GiftCooldown`, `TooManyPending`, `DataServicesDown`,
	`RecipientAlreadyOwns`, `CreditReserveFailed`, `DeliveryFailed`,
	`DeliveryUnconfirmed`, `AlreadyPending` and `IntentRecordFailed`. Each one's
	string is in the [Gifting](../gifting.md#reading-the-refusal) guide.
]=]
Scribe.GiftReason = table.freeze({
	BuyerDataNotLoaded = "buyer data not loaded" :: Types.GiftReason,
	InvalidRecipient = "invalid recipient" :: Types.GiftReason,
	CannotGiftYourself = "cannot gift yourself" :: Types.GiftReason,
	GiftCooldown = "gift cooldown" :: Types.GiftReason,
	TooManyPending = "too many pending gifts" :: Types.GiftReason,
	DataServicesDown = "data services are experiencing issues; try again later" :: Types.GiftReason,
	RecipientAlreadyOwns = "recipient already owns this" :: Types.GiftReason,
	CreditReserveFailed = "could not reserve gift credit; try again later" :: Types.GiftReason,
	DeliveryFailed = "could not deliver gift; try again later" :: Types.GiftReason,
	DeliveryUnconfirmed = "gift delivery could not be confirmed; do not send it again" :: Types.GiftReason,
	AlreadyPending = "a gift of this item is already pending; try again shortly" :: Types.GiftReason,
	IntentRecordFailed = "could not record gift intent; try again later" :: Types.GiftReason,
})

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

	The value is a [Signal](signal.md), where `Connect`, `Once` and `Wait` are documented.
]=]
Scribe.OnStatusChanged = Health.OnStatusChanged

--[=[
	@within Scribe
	@tag Diagnostics
	@prop OnIssue Signal
	Fires for every Error/Fatal log entry: the single hook to wire up developer
	alerting (Discord webhook, PagerDuty, …) from your own game code.

	The value is a [Signal](signal.md), where `Connect`, `Once` and `Wait` are documented.
]=]
Scribe.OnIssue = Log.OnIssue

--[=[
	@within Scribe
	@tag Diagnostics
	@function AddLogSink
	@param fn (entry: LogEntry) -> ()
	@return () -> ()
	Registers an extra log sink. Scribe never sends logs anywhere itself. Add a
	sink to forward them to your own pipeline. Keep secrets in game code.

	Returns a function that removes the sink again. Calling it twice is a no-op
	rather than removing whoever took that slot since. Keep it if your sink has a
	lifetime (a hot-reloaded module, a bundle you `Stop()`), because the sink list
	is a module singleton that nothing else clears, and **every entry spawns a
	thread per registered sink**, on the busiest failure path there is.
]=]
function Scribe.AddLogSink(fn: (entry: LogEntry) -> ()): () -> ()
	return Log.AddSink(fn :: any)
end

--[=[
	@within Scribe
	@tag Diagnostics
	@function GetRecentLogs
	@param filter { Level: LogLevel?, Category: LogCategory?, Code: LogCode?, Limit: number? }?
	@return { LogEntry }
	Returns entries from the ring buffer in chronological order, so the newest is
	the LAST element. The ring holds 512 entries unless the `LogRingSize` option
	raises it. `Limit` keeps the most recent N. Optionally
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
	@tag Diagnostics
	@function GetPercentiles
	@return { [string]: { P50: number, P90: number, P99: number } }
	Nearest-rank percentiles for every distribution [`GetMetrics`](#getmetrics)
	reports as a `{ Count, Average, Max }` record: save durations, profile sizes,
	per-frame flush costs, bytes per send.
	
	The half `GetMetrics` cannot give you: an average hides the tail, and a P99 save
	duration is what a player actually waits for on a bad key.

	Keyed by metric name. A name that has never been observed is **absent** rather
	than present with zeroes, so `next()` on the result tells you whether anything
	has been measured at all.

	Computed over a rolling window of the most recent 256 samples per name, bounded
	because an unbounded sample list on a metric observed once per save is a slow
	leak. So these describe recent behaviour, and `GetMetrics().<name>.Count` is the
	all-time count, which deliberately does not agree with the window.
]=]
function Scribe.GetPercentiles(): { [string]: { P50: number, P90: number, P99: number } }
	return Metrics.GetPercentiles()
end

--[=[
	@within Scribe
	@tag Diagnostics
	@function GetBudgetSnapshot
	@return BudgetSnapshot
	The DataStore request allowance the engine currently reports, by request type.

	```lua
	local budget = Scribe.GetBudgetSnapshot()
	if budget.Available and budget.Budgets.UpdateAsync < 10 then
	    warn("running low on save allowance")
	end
	```

	`Available` is `false` when the engine could not be asked at all, such as on a
	headless runner or in Studio with API access off. Treat that as *no opinion*: it
	is not the same as an allowance of zero, and code that confuses the two stalls
	forever in exactly the environments where there is nothing to conserve.

	Purely a read. To have Scribe act on it, set
	[`BudgetPolicy`](../configuration.md#integrity), which paces the two leaderboard
	background loops and deliberately touches no save path.
]=]
function Scribe.GetBudgetSnapshot(): Budget.Snapshot
	return Budget.Snapshot()
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

	`options` is a `ScribeOptions` table. Only three fields are required; the rest
	cover persistence, monetization, gifting, behaviour limits and diagnostics.
	[Configuration](../configuration.md) documents every one of them, and
	[The three you must set](../configuration.md#the-three-you-must-set) is where
	to start on a first bundle.
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
