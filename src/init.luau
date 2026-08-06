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
local Config = require(script.Internal.Config)

export type ScribeTransport = Types.ScribeTransport
export type Op = Types.Op
export type LogEntry = Types.LogEntry
export type LogCode = Types.LogCode
export type LogLevel = Types.LogLevel
export type LogCategory = Types.LogCategory
export type Status = Types.Status
export type SaveInfo = Types.SaveInfo
export type LifecycleReason = Types.LifecycleReason
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

	-- Recursion budget. A self-referential template type (a record whose indexer
	-- element type reaches back to the record, e.g. `{ Id: string, Kids: { Node } }`)
	-- would otherwise recurse forever and blow the type-function stack, which
	-- degrades the whole accessor tree to an error type and silently disables
	-- checking for the entire template. Matches StatPathsType's depth cap below.
	-- One past Util.MAX_VALUE_DEPTH (a leaf at path depth N sits at build depth N,
	-- and the deepest runtime-writable leaf has a 25-segment path), so this can
	-- never bind before the runtime does: a legal template is always fully typed,
	-- and only a cyclic type (which no write could satisfy either) is cut off.
	local MAX_DEPTH = 25

	-- ONE shared Scribe.Big type for the whole template. Luau decides `<` and `<=`
	-- by metatable IDENTITY, not by shape, so building a fresh one per field made
	-- two big fields in the same template incomparable ("do not have the same
	-- metatable") even though their types printed identically.
	local bigType: type? = nil
	local function bigValueType(): type
		if bigType ~= nil then
			return bigType
		end
		-- The shape Get actually returns. Arithmetic goes through the metatable,
		-- which the new solver honours for operator resolution.
		local bigProps: { [type]: type } = {}
		bigProps[ts.singleton("M")] = ts.number
		bigProps[ts.singleton("E")] = ts.number
		bigProps[ts.singleton("Short")] = ts.newfunction(
			{ head = { ts.any, ts.unionof(ts.number, ts.singleton(nil)) } },
			{ head = { ts.string } }
		)
		bigProps[ts.singleton("ToNumber")] = ts.newfunction({ head = { ts.any } }, { head = { ts.number } })

		-- The metamethods have to be typed over THIS table, metatable included, so
		-- the table is built first and the metatable attached afterwards. Typing them
		-- over a metatable-less copy instead made every one of them a lie: the copy
		-- is a different type from what Get returns, so `a + b` and `a < b` were type
		-- errors, and the RESULT did not satisfy the operand union, so Set and
		-- Increment refused to take it back.
		--
		-- Operands are widened to the same union those methods accept, because BIG_MT
		-- resolves both sides through Big.from: `Get() + 5` and `5 + Get()` both work
		-- at runtime, and Lua tries the metamethod of either operand.
		local big = ts.newtable(bigProps, nil, nil)
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

	-- Big, Flags and SetOf are recognised by a label in their METATABLE rather than
	-- in their fields, so each declarator's own type is already the read shape and a
	-- whole-subtree read shows values instead of labels. See BigValue.
	local function hasMarker(t: type, name: string): boolean
		local mt = t:metatable()
		return mt ~= nil and mt:readproperty(ts.singleton(name)) ~= nil
	end

	local function isBigMarker(t: type): boolean
		return hasMarker(t, "__scribeBig")
	end

	-- Scribe.Timed and Scribe.ServerOnly read back as a bare T, which may be a
	-- number or a string, and a metatable cannot attach to a non-table. So unlike
	-- Big, Flags, SetOf and MapOf, their label has to stay an ordinary field, and a
	-- whole-subtree read has to strip it instead.
	--
	-- This only ever REMOVES a wrapper, so the types it produces are strictly smaller
	-- than the ones it consumes. That is what makes it affordable where a general
	-- read-shape transform was not: that one had to BUILD the read shape for every
	-- declarator, embedding a big's whole metatable type into every enclosing record.
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

		-- Scribe.ServerOnly carries a { __scribeServerOnly: V } marker, and it has to
		-- come off FIRST. Every declarator check below reads a marker property off
		-- `t`, so with the wrapper still on, ServerOnly(SetOf/Big/Flags/Timed) matched
		-- none of them: the node lost its whole declarator surface, Get() typed as the
		-- raw marker table, and the static-children walk hung a phantom
		-- `__scribeSet`-style child off it. The runtime supports all of these; only
		-- the type surface did not. There is a second unwrap after the SetOf block for
		-- the inverse nesting, e.g. Scribe.Timed(Scribe.ServerOnly(false)).
		if t:is("table") then
			local inner = t:readproperty(ts.singleton("__scribeServerOnly"))
			if inner ~= nil then
				t = widen(inner)
			end
		end

		-- Scribe.Timed fields carry a { __scribeTimed: V } marker type.
		local isTimed = false
		if t:is("table") then
			local inner = t:readproperty(ts.singleton("__scribeTimed"))
			if inner ~= nil then
				isTimed = true
				t = widen(inner)
			end
		end

		-- Scribe.Flags carries a { __scribeFlags: { string } } marker. Without it a
		-- flags field is just {string} at the type level, so it would pick up Insert,
		-- Remove and the rest of the array surface, none of which it supports.
		-- `t` is already the { string } a read returns; the label is on the metatable.
		local isFlags = t:is("table") and hasMarker(t, "__scribeFlags")

		-- Scribe.Big carries a { __scribeBig: true } marker. Its VALUE is an object
		-- with arithmetic metamethods rather than a number, so it gets its own method
		-- surface and none of the table one.
		local isBig = false
		if t:is("table") and isBigMarker(t) then
			isBig = true
			t = bigValueType()
		end

		-- Scribe.SetOf carries a { __scribeSet: { T } } marker. Without it a set is
		-- just {T} at the type level and would pick up Insert plus index-based
		-- Remove, neither of which a set has.
		-- Same for a set: `t` is already the { T } of members.
		local isSet = t:is("table") and hasMarker(t, "__scribeSet")

		-- Second ServerOnly unwrap, for a marker nested INSIDE another declarator
		-- rather than wrapped around one. The SERVER reads these normally, so unwrap
		-- to the value type and build as usual; the marker exists so ClientDataType
		-- can drop them via StripServerOnly, since they are never replicated and read
		-- nil on the client.
		if t:is("table") then
			local inner = t:readproperty(ts.singleton("__scribeServerOnly"))
			if inner ~= nil then
				t = widen(inner)
			end
		end

		-- Scribe.MapOf carries its key type as a singleton, which is the only way the
		-- accessor can know that {[number]: V} is a sparse map rather than an array:
		-- at the Luau type level those are the same indexer. Last, so a map wrapped in
		-- Scribe.ServerOnly is still seen as a map rather than as the raw marker.
		--
		-- `t` becomes the MAP, not its element. Collapsing it to the element made
		-- Get() claim to return one entry, Set() demand one, and the element's own
		-- method surface (Increment on a map of ints, the element record's fields)
		-- hang off the container, none of which the runtime does.
		-- `t` is already the map a read returns, indexer and all. Only the element is
		-- pulled back out, for the key events and Remove.
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

		-- Strips a nested Scribe.Timed / Scribe.ServerOnly label, which is the one
		-- thing a read still shows that it should not.
		local valueType = unwrapWrappers(t, depth)
		local function add(name: string, ty: type)
			props[ts.singleton(name)] = ty
		end

		-- Static children and container methods first, so the common node
		-- methods below take precedence on name collisions (documented: method
		-- names are reserved words on containers).
		--
		-- A map is excluded because its own block below builds the same surface with
		-- the declared key type. Letting it through here would give an integer-keyed
		-- map the ARRAY methods (Insert, Find, Has) and a string-keyed one a second,
		-- duplicate Remove/OnKeyAdded/OnKeyRemoved rather than an override, since two
		-- ts.singleton("Remove") calls are distinct keys.
		if t:is("table") and mapKey == nil and not isTimed and not isFlags and not isSet and not isBig then
			for key, prop in t:properties() do
				local childType = prop.read or prop.write
				if childType ~= nil then
					props[key] = build(childType, false, depth + 1)
				end
			end

			-- OnChildChanged: the TRANSITION half, and the only way to learn that an
			-- existing child's value moved. Fires once per write, never coalesced,
			-- unlike Changed above. OnKeyAdded and OnKeyRemoved report a key
			-- appearing or disappearing; this reports one changing.
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
					-- Array node. The indexer makes `arr[i]` an accessor node, matching
					-- the runtime (Node.accessorIndex already resolves numeric keys); a
					-- Scribe.ArrayOf element field is only reachable this way.
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
				-- optional: a key being added has no old, a key being removed has no new.
				-- On a heterogeneous static table they are a union Luau will not narrow
				-- from the key, which is accepted, since that node kind already has exact
				-- per-field leaf listeners and this event exists mainly for ArrayOf and
				-- DictOf, where both types are precise.
				local childKey = ts.unionof(table.unpack(childKeys))
				local childValue = optional(ts.unionof(table.unpack(childValues)))
				add("OnChildChanged", fn({ fn({ childKey, childValue, childValue }, {}) }, { disconnectType }))
			end
		end

		if mapKey ~= nil then
			-- A map's children are accessor nodes keyed by the declared type. The key
			-- events and Remove carry the ELEMENT, not the whole map, which valueType
			-- now correctly is.
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
		-- The root accessor (empty path) cannot be Set/Updated at runtime — those
		-- calls always throw ("cannot write to \"\""). Omit them from the root
		-- type so the typed API matches runtime and can't silently disable
		-- module-level checking with a template-typed argument.
		-- A big field declares its own Set and Update below, taking the wider operand
		-- union. Re-adding them here would leave two entries for the same name rather
		-- than overriding, because two ts.singleton("Set") calls are distinct keys.
		if not isRoot and not isBig then
			-- Writes take the UNBRANDED shape. A map's type carries its declared key on
			-- the metatable so the accessor can tell an integer map from a string one,
			-- and a caller writing a plain table literal has no way to produce that
			-- brand. Reads still hand back the branded type, which assigns freely to
			-- the plain shape, so `Set(Get())` and `Set({ ... })` both work.
			local writeType = if mapKey ~= nil and mapElement ~= nil
				then ts.newtable(nil, { index = mapKey, readresult = mapElement, writeresult = mapElement }, nil)
				else valueType
			add("Set", fn({ writeType, optBool }, { valueType }))
			add("Update", fn({ fn({ valueType }, { writeType }), optBool }, { valueType }))
		end
		add("Clone", fn({}, { valueType }))
		add("Default", fn({}, { valueType }))
		-- (new, old) on every node. On a container this is STATE: "it is different,
		-- here it is", coalesced to one fire per batch or per received frame. Which
		-- child moved is OnChildChanged's job, so there is exactly one place to look
		-- and no parameter that is conditionally nil.
		add("Changed", fn({ fn({ valueType, valueType }, {}) }, { disconnectType }))
		add("Observe", fn({ fn({ valueType }, {}) }, { disconnectType }))

		if t:is("number") then
			add("Increment", fn({ ts.number, anyType }, { ts.number }))
			add("Decrement", fn({ ts.number, anyType }, { ts.number }))
			add("Min", fn({}, { optNumber }))
			add("Max", fn({}, { optNumber }))
		elseif t:is("boolean") then
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
			-- These hand back the declared bound verbatim, and a big bound past the
			-- double range is only expressible as a numeric string, so the return type
			-- is the same union the declarator accepts.
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

-- Union of every static rankable leaf path in the template, dot-joined
-- ("Coins", "Stats.Wins"), giving autocomplete and compile-time validation
-- for leaderboard `Stat` and `Purchase` cost paths. Dynamic (dictionary or
-- array) segments cannot be enumerated at type level, so cast those paths to
-- `any`. Falls back to plain `string` when the template has no such leaf.
--
-- `IncludeBig` distinguishes the two callers. Leaderboards rank a Scribe.Big
-- (packed into the OrderedDataStore key), so it passes true; a purchase cost path
-- must be a plain number, which Monetization enforces at runtime, so it passes
-- false and a big path is a type error rather than a runtime refusal.
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
		if t:is("table") and isMapMarker(t) then
			-- A map's entries live under dynamic keys, which cannot be enumerated at
			-- type level any more than a DictOf's can. Recursing into the marker's own
			-- properties instead produced the literal path "Field.__scribeMapValue",
			-- which is not addressable and crowded out the real ones.
			return
		end
		if t:is("table") and isBigMarker(t) then
			-- ALWAYS terminal, whether or not a big counts here. Now that a big's type
			-- is its real shape, recursing would expose the object's own M and E as
			-- numeric leaves and offer "Coins.M" as a stat path. When a big DOES
			-- count, the field itself is the path: a template whose only rankable
			-- field is big would otherwise produce an empty union, collapsing the
			-- gate to plain `string`.
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

-- T with every Scribe.ServerOnly subtree removed, at any depth. The client never
-- receives those fields, so leaving them in the client's accessor type made
-- `Data.Secret.Flagged.Get()` typecheck clean and return nil at runtime. Applied
-- to the raw template BEFORE ValueType, because ValueType unwraps the marker and
-- the information is gone by then.
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
		-- Element shapes live behind the indexer, not in properties, so without this a
		-- Scribe.ServerOnly field inside an ArrayOf or DictOf entry stayed in the
		-- client type as non-nil while reading nil at runtime.
		local indexer = t:indexer()
		if indexer ~= nil then
			local element = strip(indexer.readresult, depth + 1)
			out:setindexer(indexer.index, element)
		end
		return out
	end

	return strip(T, 0)
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
	-- `number | BigScore`, not `number`. A Scribe.Big board hands back the big
	-- itself, so a bare `number` silently blessed `local n: number = entry.Score`
	-- and crashed on it, while the documented `entry.Score:Short()` was an error.
	-- The board's kind is a runtime property of the name passed in, so the type
	-- cannot pick one: a caller narrows, which is the honest contract.
	local bigScoreProps: { [type]: type } = {}
	bigScoreProps[ts.singleton("M")] = ts.number
	bigScoreProps[ts.singleton("E")] = ts.number
	bigScoreProps[ts.singleton("Short")] = ts.newfunction(
		{ head = { ts.any, ts.unionof(ts.number, ts.singleton(nil)) } },
		{ head = { ts.string } }
	)
	bigScoreProps[ts.singleton("ToNumber")] = ts.newfunction({ head = { ts.any } }, { head = { ts.number } })
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
	-- `number | BigScore`, not `number`. A Scribe.Big board hands back the big
	-- itself, so a bare `number` silently blessed `local n: number = entry.Score`
	-- and crashed on it, while the documented `entry.Score:Short()` was an error.
	-- The board's kind is a runtime property of the name passed in, so the type
	-- cannot pick one: a caller narrows, which is the honest contract.
	local bigScoreProps: { [type]: type } = {}
	bigScoreProps[ts.singleton("M")] = ts.number
	bigScoreProps[ts.singleton("E")] = ts.number
	bigScoreProps[ts.singleton("Short")] = ts.newfunction(
		{ head = { ts.any, ts.unionof(ts.number, ts.singleton(nil)) } },
		{ head = { ts.string } }
	)
	bigScoreProps[ts.singleton("ToNumber")] = ts.newfunction({ head = { ts.any } }, { head = { ts.number } })
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

	-- Keep in sync with Types.LifecycleReason. Spelled out here because a type
	-- function cannot reference an exported type alias.
	local reasonUnion = ts.unionof(
		ts.singleton("load-failed"),
		ts.singleton("migration-failed"),
		ts.singleton("session-ended"),
		ts.singleton("player-left"),
		ts.singleton("shutdown"),
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
-- The value a Scribe.Flags field READS BACK: the list of enabled member names.
-- The label sits in the METATABLE for the same reason Scribe.Big's does, so a
-- whole-table read shows the members rather than `{ __scribeFlags: { string } }`.
export type Flags = typeof(setmetatable({} :: { string }, {} :: { __scribeFlags: true }))
-- A set READS BACK as its members. Label in the metatable, as above.
export type SetOf<T> = typeof(setmetatable({} :: { T }, {} :: { __scribeSet: true }))
export type ServerOnly<T> = { __scribeServerOnly: T }

export type NumberMeta = { Min: number?, Max: number? }
-- Scribe.Big only. A bound past 1.8e308 has to be written as a numeric string,
-- because a larger literal is already math.huge, which the template validator
-- rejects. Int and Number stay on NumberMeta: a string bound there is not accepted
-- at compile and would crash comparing against a number at the first write.
export type BigMeta = { Min: (number | string)?, Max: (number | string)? }
export type StringMeta = { MaxLength: number? }
-- Container declarator options. Deliberately NOT generic in the element type: an
-- element-typed field here (a seed default, say) would let Luau infer the element
-- type from the option instead of from `shape`, silently redefining the field.
export type ArrayOpts = { MaxItems: number?, Evict: ("Front" | "Back")? }
export type SetOpts = { MaxItems: number? }
export type CooldownOptions = { IncludeOfflineTime: boolean? }
export type MapKeyType = "integer" | "string"
-- The value a Scribe.Big field READS BACK, which is also what the declarator
-- returns, so a whole-table read shows the value rather than a label.
--
-- `__scribeBig` is how the type functions recognise the declarator. It lives in the
-- METATABLE rather than in the fields on purpose: a label written as an ordinary
-- field travels with the type into every read, so `data.Stats.Get().Wealth` typed as
-- `{ __scribeBig: true }`, and `Get().Wealth.__scribeBig` typechecked as `true` while
-- being nil at runtime. A metatable entry is visible to the type machinery and
-- invisible to a read.
type BigFields = {
	M: number,
	E: number,
	Short: (self: any, decimals: number?) -> string,
	ToNumber: (self: any) -> number,
}
type BigMt = { __scribeBig: true }
export type BigValue = typeof(setmetatable({} :: BigFields, {} :: BigMt))
-- The value a Scribe.MapOf field READS BACK: the whole map. The declared key is a
-- singleton ("integer" or "string") that has to become a real indexer key type, so
-- the shape goes through a small type function; the label and the declared key ride
-- the metatable, as with Big, Flags and SetOf.
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
	Stat: StatPathsType<T, true>,
	Limit: number?,
	Scale: number?,
	-- Scribe.Big stats only: significant figures the ranking key carries, 1 to 15
	-- (default 12). Every extra figure costs a factor of ten of exponent range,
	-- because the two halves share one integer under 2^53.
	SigFigs: number?,
	Replicate: boolean?, -- default false: server-only (Data.GetLeaderboard on the server); true streams the board to clients
	RefreshInterval: number?, -- seconds between reads of this board (default 60; values below 60 are clamped up)
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

-- Loose, read-only option shapes. These deliberately do NOT depend on T:
-- inside the Scribe({ ... }) literal the template type is still being
-- inferred, so strict (type-function) fields would widen and reject valid
-- configs. Read-only props keep annotated strict tables assignable.
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
	UserOwnsGamePassAsync: ((userId: number, passId: number) -> boolean)?, -- advanced/test seam
	DevMode: boolean?, -- advanced/test seam: overrides the RunService:IsStudio() default
	MigrationShadow: boolean?, -- audit aid: re-runs migrations against raw pre-Reconcile data and warns on divergence (re-executes your migration bodies)
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

-- One player's typed accessor tree: the type of `Data[player]`, `Data.Get(player)`
-- and the client's `Data.Get()`. Exported as a plain alias because `ValueType` is
-- a type FUNCTION, and a type function cannot be invoked across a module boundary
-- (`Scribe.ValueType<T>` silently resolves to `any` rather than erroring), so this
-- is the only way a consumer can name the accessor type.
export type PlayerData<T> = ValueType<T>

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
	.ProfileKeyPrefix string -- per-player key prefix, e.g. "PLAYER_" (required; "" means bare user-id keys)
	.Transport ("Default" | ScribeTransport)? -- replication channel; "Default" uses two RemoteEvents
	.SaveInterval number? -- seconds between autosaves per profile (default 300, floor 15)
	.Migrations { [number]: (data) -> () }? -- versioned, fail-closed data reshapers
	.OnPlayerInit ((player, rawData, isNewProfile) -> ())? -- runs after load, before Ready; isNewProfile is true on a brand-new/reset profile
	.OnPlayerLeaving ((player, data, reason) -> ())? -- last chance to write; runs before the final save, so its writes persist
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
	UserOwnsGamePassAsync = true,
	DevMode = true,
	MigrationShadow = true,
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
	-- Still required, but "" is a legitimate value: it means bare user-id keys,
	-- which is what a game adopting a database whose keys were only the user id
	-- needs. Absent or non-string is still an error, so the choice stays explicit.
	if type(anyOpts.ProfileKeyPrefix) ~= "string" then
		error(
			'Scribe: options.ProfileKeyPrefix is required — set a per-player key prefix (e.g. "PLAYER_"), or "" for bare user-id keys',
			2
		)
	end

	-- Scribe.Configure refuses to run past this point: the process-wide values it
	-- sets are applied during construction, so a later change would be ignored.
	-- Set AFTER the option guards, not before: a call that merely fails a guard
	-- constructs nothing, and poisoning the flag there made a later Configure
	-- report "a bundle was already constructed" when none ever was.
	Config.BundleConstructed = true

	-- The type checker enforces the TYPE of every option, but the Luau solver
	-- does not reject unknown table keys, so a misspelled option name would be
	-- silently ignored. Catch that in Studio (dev-mode) with a startup warning.
	if RunService:IsStudio() then
		for key in options :: any do
			if type(key) == "string" and not KNOWN_OPTION_KEYS[key] then
				Log.Warn(
					"Lifecycle",
					"UNKNOWN_OPTION",
					`unknown Scribe option "{key}" — check the spelling`,
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
				error(
					"Scribe: the Server API is not available on the client — client writes go through Data.Request commands",
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
	@function Big
	@param default (number | string)?
	@param meta BigMeta?
	@return BigValue
	A number with unlimited **range**, for an idle or simulator currency that runs
	past 2^53 where a plain Luau number stops being exact, and past 1.8e308 where it
	stops existing.

	```lua
	Coins = Scribe.Big(0, { Min = 0 }),

	data.Coins.Set("1.5e100")
	data.Coins.Increment("2e99", { Source = "Quest" })
	data.Coins.Multiply(1.15)
	data.Coins.Get():Short()          --> "1.95Dc"
	tostring(data.Coins.Get())        --> "1.9550e100"
	```

	A bound past 1.8e308 has to be written as a numeric string, since a bigger
	literal is already `math.huge`: `Scribe.Big(0, { Min = 0, Max = "1e600" })`.

	This trades precision for range **on purpose**. A value carries exactly 15
	significant digits at any magnitude, so `1e20 + 1 == 1e20`. That is the right
	trade for a currency whose magnitude is the point, and the wrong one for anything
	audited: use [Scribe.Int] when every digit has to be exact.

	`Get()` returns a value supporting `+`, `-`, `*`, `/`, `<`, `<=`, `==`,
	`tostring`, `:Short()` for display, and `:ToNumber()` (lossy, saturates to
	infinity past the double range). `Set` and the arithmetic methods all accept a
	plain number, a numeric string like `"1.5e100"`, or another big value.

	The ARITHMETIC operators accept a plain number or a numeric string on either
	side, so `Get() + 5` and `5 + Get()` both work. The COMPARISONS do not: Luau
	picks `<` and `<=` by metatable identity, so `Get() < 2000` throws "attempt to
	compare table < number". `==` fails more quietly, since Luau only consults it
	when BOTH sides are tables, making `Get() == 5` always false. Two big values
	compare directly; against a constant, go through `:ToNumber()`.

	A big field **can** be a leaderboard stat. Scribe packs it exponent-major into the
	OrderedDataStore key, which preserves the ordering exactly and breaks ties on the
	mantissa, so no separate rank field is needed and entries come back with a big
	`Score`. Two limits follow from the key being an integer: the value must be
	**non-negative**, since the packing has no room for a sign, and the exponent must
	be within the board's cap (1e9006 by default). A score outside either is dropped
	with `LB_SCORE_OUT_OF_RANGE` rather than ranked wrongly. `Scale` is refused on
	such a board, because the packing already maps the value into the key space.

	The exponent and the mantissa share one integer under 2^53, so a board's
	`SigFigs` (1 to 15, default 12) decides how that budget is split: it is how many
	significant figures the key keeps, and therefore how many the `Score` can show.
	Each extra figure costs a factor of ten of exponent range, so a prestige currency
	that has to separate near-identical scores sets it high and a counter spanning a
	huge range sets it low. See the leaderboards guide.
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
	A fixed set of named booleans stored as one field. Up to 32 members, addressed
	by name:

	```lua
	Tutorial = Scribe.Flags({ "Movement", "Combat", "Trading" }),

	data.Tutorial.Enable("Combat")
	data.Tutorial.Has("Combat")   --> true
	data.Tutorial.Get()           --> { "Combat" }
	```

	Prefer this over a table of sibling booleans when the set is fixed and you flip
	several at once: it is one write and one `Changed` rather than one per flag, the
	valid names are declared rather than implied by whatever strings the code passes,
	and it packs to a bitmask on the wire.

	The value is stored as the enabled member **names**, in declaration order, so
	reordering or removing members later is safe. Only the wire packing is
	positional, and both ends of a replication frame always come from the same build.
	Enabling a name that is not a member is an error rather than a silent no-op.
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

	This is mainly what makes closed [Scribe.ArrayOf] / [Scribe.DictOf]
	element shapes practical: without it, every element field would need a sentinel
	value standing in for "not set", and `""` or `0` is usually a real value too.

	It only wraps leaves, and it cannot wrap `Scribe.Timed` (a lapsed timer restores
	a default, which an optional field does not have), `Scribe.Dynamic` (a factory
	exists to seed a value), or a container declarator (an empty container is
	already the absent case).
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
	Declares an array whose **elements have a schema**. Everything a declared field
	gets (type checking, bounds, enum members, and automatic datatype packing) then
	applies per element:

	```lua
	PlacedFurniture = Scribe.ArrayOf({
	    Cf       = Scribe.CFrame(CFrame.new()),
	    ItemId   = Scribe.String("", { MaxLength = 64 }),
	}, { MaxItems = 200 }),
	```

	```lua
	data.PlacedFurniture.Insert({ Cf = CFrame.new(0, 5, 0), ItemId = "OakChair" })
	local cf = data.PlacedFurniture[1].Cf.Get() -- a real CFrame, unpacked for you
	```

	An element schema is the only way to have Scribe pack and unpack a Roblox
	datatype inside a container. A plain array literal stores its entries as opaque
	data, so a `Scribe.CFrame` inside one is a template error: with no schema for the
	entries, Scribe cannot tell a packed CFrame from a buffer you stored yourself when
	reading it back. To keep the container free-form, leave it plain and call
	[Scribe.Datatypes] `Pack` and `Unpack` around the buffer yourself.

	The element shape may be a single leaf declarator (`Scribe.ArrayOf(Scribe.CFrame(CFrame.new()))`
	is an array of CFrames) and nests freely: an element field may itself be an
	`ArrayOf` or a `DictOf`.

	Element records are **closed** at every depth, nested sub-records included.
	Writing a field the shape does not declare is an error rather than a silently
	stored extra field, which is what makes a typo like
	`data.PlacedFurniture[1].Colour.Set(...)` fail loudly.

	An `Insert` or `Set` that omits a declared field fills it from that field's
	default, but strict Luau still asks for every non-optional field, since the type
	level cannot know the runtime fills them. Pass the whole element, or mark the
	omittable fields [Scribe.Optional].

	`Evict` turns the cap into a rolling window: an `Insert` at the cap drops an
	entry instead of erroring, which is what you want for a bounded history like
	recent matches or a kill feed. The drop is a real removal, so it fires
	[Value.OnRemove] and replicates, and it trims all the way down when the array is
	already over cap (a lowered `MaxItems`, or data from before it existed). `Evict`
	requires `MaxItems`.

	It names the **end** to drop from, not an age, because which end is oldest
	depends on how you insert. Append with `Insert(item)` and the oldest entry is at
	the front, so you want `"Front"`. Prepend with `Insert(item, 1)` and the oldest
	is at the back, so you want `"Back"`. Picking the end your inserts do not target
	churns that end while the other freezes.

	```lua
	-- newest last, drop the oldest from the front
	RecentMatches = Scribe.ArrayOf({
	    MapId = Scribe.String(""),
	    Score = Scribe.Int(0),
	}, { MaxItems = 10, Evict = "Front" }),
	```

		`MaxItems` caps the entry count; exceeding it is a write error, but only growth
	is refused, so a container a newer-template server already stored over cap stays
	writable through a rolling deploy. Elements may not use `Scribe.Timed`,
	`Scribe.Dynamic`, `Scribe.Shared` or `Scribe.Session`.

	[Value.Find], [Value.Has] and [Value.RemoveValue] compare entries by value, not
	by identity as they do on an untyped array.]=]
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
	A collection of **unique** entries: membership, not order. Use it for the shape
	that would otherwise be a dictionary of `true` values, such as owned items,
	unlocked levels, completed quests, or claimed rewards.

	```lua
	Unlocked = Scribe.SetOf(Scribe.String("", { MaxLength = 32 })),

	data.Unlocked.Add("Desert")
	data.Unlocked.Has("Desert")     --> true
	data.Unlocked.Remove("Desert")
	data.Unlocked.Count()
	```

	`Add` on a value already present and `Remove` on one that is absent both do
	nothing: no write, no replication, no `Changed`. Entries are kept deduplicated
	and in sorted order, so two profiles holding the same set hold the same table.

	Unlike [Scribe.ArrayOf] there is no `Insert` and no index-based `Remove`, and
	`MaxItems` caps membership. `Evict` does not apply, because a set has no oldest
	entry to drop.
]=]
function Scribe.SetOf<T>(element: T, opts: SetOpts?): SetOf<T>
	if opts ~= nil then
		for key in opts :: any do
			if key ~= "MaxItems" then
				error(`Scribe.SetOf: unknown option "{tostring(key)}" (SetOf takes MaxItems)`, 2)
			end
		end
	end
	-- A set is deduplicated and sorted, and neither is meaningful for a record: two
	-- tables are never equal by value here, and table.sort on them throws a bare
	-- Luau comparison error on the SECOND member. Refuse it where the mistake is,
	-- rather than at the surprising second Add.
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
	A dictionary whose **keys have a declared type**. `Scribe.DictOf` is the
	string-keyed shorthand; use this when the keys are user ids, item ids, or
	anything else you would otherwise have to `tostring` at every write and
	`tonumber` at every read.

	```lua
	Friends = Scribe.MapOf("integer", {
	    Name = Scribe.String(""),
	    LastSeen = Scribe.Int(0),
	}),

	data.Friends[player.UserId].Name.Set("Ada")   -- no tostring
	```

	`keyType` is `"integer"` or `"string"`. Integer keys are stored and reloaded as
	numbers even though a DataStore serializes every object key to a string, because
	the declared key type is what makes that round trip unambiguous: without it,
	`"123"` on disk could equally have been the number `123` or the string `"123"`.

	Non-integer, infinite, and NaN keys are refused, since none of them survive the
	round trip.
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
	Declares a string-keyed dictionary whose **values have a schema**, the
	dictionary counterpart of [Scribe.ArrayOf]:

	```lua
	Resources = Scribe.DictOf(Scribe.Int(0, { Min = 0 }), { MaxKeys = 500 }),
	Pets      = Scribe.DictOf({
	    Level = Scribe.Int(1, { Min = 1, Max = 100 }),
	    Home  = Scribe.CFrame(CFrame.new()),
	}),
	```

	```lua
	data.Resources.Wood.Get()        -- nil: nothing has written this key yet
	data.Resources.Wood.Increment(5) -- 5: the write starts from the declared default
	data.Pets.Dragon.Level.Set(12)   -- creates Dragon with Home at its default too
	```

	A key exists only once something writes it: until then `Get()` is `nil` and
	`Count()` does not include it. The element default is what the first write
	starts from, not a value every conceivable key already reports.

	Any string is a valid key, so a typo is a new key rather than an error. Use
	`DictOf` for open-ended keys like catalog ids, and plain declared fields when the
	key set is fixed, which buys back that typo protection. `MaxKeys` caps how many
	keys there may be and `MaxKeyLength` caps each key's byte length; both are write
	errors, and `MaxKeyLength` rejects rather than truncates, since a truncated key
	writes to the wrong slot.

	The same element rules as `ArrayOf` apply: records are closed, missing fields
	fill from their defaults, and `Scribe.Timed` / `Scribe.Dynamic` / `Scribe.Shared`
	/ `Scribe.Session` are rejected inside the shape.
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
	@tag Lifecycle
	@prop Reason { [string]: LifecycleReason }
	Every value [Server.WaitForData] and the
	`SessionEnded` signal can report, as a frozen table, so you can branch on a
	constant instead of a hand-typed string:

	```lua
	local data, reason = Data.WaitForData(player)
	if not data then
	    if reason == Scribe.Reason.PlayerLeft then
	        return -- routine, not an error
	    end
	    warn("data unavailable:", reason)
	end
	```

	The matching `Scribe.LifecycleReason` type is the same set as a string union,
	so a comparison against a typo fails to type-check.
]=]
--[=[
	@within Scribe
	@tag Configuration
	@function Configure
	@param config { AutoSaveInterval: number? }
	Sets configuration that belongs to the **process**, not to one bundle. Call it
	once, before constructing any bundle:

	```lua
	Scribe.Configure({ AutoSaveInterval = 60 })
	```

	`AutoSaveInterval` is the autosave cadence. It lives here because ProfileStore's
	`AUTO_SAVE_PERIOD` is a module-wide constant: it applies to every Scribe bundle
	AND to any direct ProfileStore use in the same game. The per-bundle
	`SaveInterval` option still works and still wins if it is set, but two bundles
	asking for different cadences is a conflict Scribe can only resolve as
	last-writer-wins, so it now logs `SAVE_INTERVAL_CONFLICT` when that happens.

	Values below 15 seconds clamp up to it, since Roblox throttles per-key writes
	to roughly one per 6 seconds and saving faster just produces failures.

	Calling this twice with different values, or after a bundle exists, is an
	error: the value may already have been applied, so a late change would be
	silently ignored.
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
	Timeout = "timeout" :: Types.LifecycleReason,
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
	Returns entries from the 512-entry ring buffer in chronological order, so the
	newest is the LAST element. `Limit` keeps the most recent N. Optionally
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
