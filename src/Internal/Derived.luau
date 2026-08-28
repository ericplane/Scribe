--!strict
-- Derived fields. A derived field is computed from other declared fields instead of
-- accepting writes: never persisted, recomputed when an input changes, and replicated
-- only when the receiving realm cannot compute it for itself. This module owns the
-- compile-time half (resolve input paths, order the graph, decide who computes, build
-- the write index) plus a realm-agnostic evaluator.
--
-- Schema nodes are typed `any` throughout: Template requires this module for its
-- post-compile pass, so importing Template's SchemaNode back would be a cycle.

local Big = require(script.Parent.Big)
local Datatypes = require(script.Parent.Datatypes)
local Util = require(script.Parent.Util)

local Derived = {}

-- Read form must be a plain, immutable scalar: the value is handed to user code on
-- every recompute, so a mutable shape would let a compute function mutate live
-- state through its own argument.
local ALLOWED_INPUT_TYPES: { [string]: boolean } = {
	int = true,
	number = true,
	string = true,
	boolean = true,
	enum = true,
	big = true,
	datatype = true,
}

-- Outputs are narrower than inputs: this module computes the compile-time default,
-- and a big/datatype default would have to be converted to its stored form and
-- bounds-checked, which is validateWrite's job on the runtime path.
local ALLOWED_OUTPUT_TYPES: { [string]: boolean } = {
	int = true,
	number = true,
	string = true,
	boolean = true,
	enum = true,
}

-- ServerOnly's audience is a subset of Replicated's, which is a subset of Shared's,
-- so "can this audience see that field" is a rank comparison.
local VISIBILITY_RANK: { [string]: number } = {
	ServerOnly = 0,
	Replicated = 1,
	Shared = 2,
}

Derived.ALLOWED_INPUT_TYPES = ALLOWED_INPUT_TYPES
Derived.ALLOWED_OUTPUT_TYPES = ALLOWED_OUTPUT_TYPES

-- Stored -> read form for the value handed to a compute function. Mirrors
-- Node.unpackRead for the two split-representation types; every other allowed
-- input type stores what it reads.
function Derived.ReadForm(node: any, stored: any): any
	if stored == nil then
		return nil
	end
	if node.ValueType == "big" then
		return Big.from(stored)
	end
	if node.ValueType == "datatype" and type(stored) == "buffer" then
		return Datatypes.Unpack(node.Datatype :: string, stored)
	end
	return stored
end

-- Compile time -----------------------------------------------------------------

-- Walk STATIC children only. A container (ArrayOf/DictOf) holds its element schema
-- on AnyChild rather than Children, and a dynamic key has no schema at all, so
-- stopping at Children is exactly the "must exist in the template" rule.
local function resolveStatic(root: any, segments: { string }): any
	local node = root
	for _, segment in segments do
		local children = node.Children
		if children == nil then
			return nil
		end
		local child = children[segment]
		if child == nil then
			return nil
		end
		node = child
	end
	return node
end

local function describe(node: any): string
	if node.Timed then
		return "a Scribe.Timed field"
	elseif node.Container ~= nil then
		return `a Scribe.{node.Container}Of container`
	elseif node.ValueType == "flags" then
		return "a Scribe.Flags field"
	elseif node.ValueType == "table" then
		return "a record"
	elseif node.ValueType == "any" then
		return "an undeclared (dynamic) field"
	end
	return `a {node.ValueType} field`
end

--[[
	Resolves every collected derived field against the finished schema tree.

	`pending` is what buildNode collected, in template order: each entry is
	{ Node, InputPaths (dotted strings), Compute }. `fail` is Template's compileError,
	passed in so the error text keeps one format.

	Returns the topologically ordered node list and the write index.
]]
function Derived.Resolve(
	root: any,
	pending: { { Node: any, InputPaths: { string }, Compute: (...any) -> any } },
	reservedRoots: { [string]: boolean },
	fail: (path: { string }, message: string) -> ()
): ({ any }, { [string]: { any } })
	-- Resolve and validate every input before ordering: a cycle message is only
	-- useful once the edges it names are known to be real fields.
	for _, entry in pending do
		local node = entry.Node
		local path = node.Path
		if not ALLOWED_OUTPUT_TYPES[node.ValueType] then
			fail(
				path,
				`Scribe.Derived produces {describe(node)}, but a derived field must be an Int, Number, String, `
					.. "Boolean or Enum"
			)
		end
		if #entry.InputPaths == 0 then
			fail(path, "Scribe.Derived requires at least one input path")
		end

		local inputs: { any } = {}
		local inputPaths: { { string } } = {}
		local seen: { [string]: boolean } = {}
		for _, raw in entry.InputPaths do
			if type(raw) ~= "string" then
				fail(path, `Scribe.Derived inputs must be dotted path strings, got a {typeof(raw)}`)
			end
			local segments = Util.parsePath(raw)
			if #segments == 0 then
				fail(path, `Scribe.Derived input "{raw}" is not a path`)
			end
			if reservedRoots[segments[1]] then
				fail(
					path,
					`Scribe.Derived input "{raw}" reads a library-owned root; derived fields cannot depend on `
						.. "Scribe's own state (perks, ownership, save info)"
				)
			end
			local key = table.concat(segments, ".")
			if seen[key] then
				fail(path, `Scribe.Derived lists the input "{raw}" twice`)
			end
			seen[key] = true

			local resolved = resolveStatic(root, segments)
			if resolved == nil then
				fail(
					path,
					`Scribe.Derived input "{raw}" does not resolve to a declared field. Inputs must name a field `
						.. "that exists in the template (a container entry or a runtime key has no schema)"
				)
			end
			if resolved == node then
				fail(path, "Scribe.Derived reads itself")
			end
			if resolved.Timed then
				fail(
					path,
					`Scribe.Derived input "{raw}" is a Scribe.Timed field. A timer lapses on the wall clock `
						.. "rather than on a write, and an expired-but-uncleared value reads differently online "
						.. "and offline, so the same profile would derive two different values"
				)
			end
			if resolved.Kind ~= "leaf" or not ALLOWED_INPUT_TYPES[resolved.ValueType] then
				fail(
					path,
					`Scribe.Derived input "{raw}" is {describe(resolved)}. Inputs must be an Int, Number, String, `
						.. "Boolean, Enum, Big or datatype field"
				)
			end
			table.insert(inputs, resolved)
			table.insert(inputPaths, segments)
		end

		node.Derived = {
			Inputs = inputs,
			InputPaths = inputPaths,
			Compute = entry.Compute,
			Transmit = false, -- decided below, once the graph is ordered
			OfflineComputable = false,
			Label = table.concat(node.Path, "."),
		}
	end

	-- Topological order over derived -> derived edges, three-colour DFS. `pending`
	-- is in sorted template order, so server and client end up with the same order.
	local ordered: { any } = {}
	local mark: { [any]: string } = {}
	local stack: { any } = {}
	local function visit(node: any)
		local state = mark[node]
		if state == "done" then
			return
		end
		if state == "open" then
			local cycle = {}
			local started = false
			for _, entry in stack do
				if entry == node then
					started = true
				end
				if started then
					table.insert(cycle, table.concat(entry.Path, "."))
				end
			end
			table.insert(cycle, table.concat(node.Path, "."))
			fail(node.Path, `derived fields form a cycle ({table.concat(cycle, " -> ")})`)
		end
		mark[node] = "open"
		table.insert(stack, node)
		for _, input in node.Derived.Inputs do
			if input.Derived ~= nil then
				visit(input)
			end
		end
		table.remove(stack)
		mark[node] = "done"
		table.insert(ordered, node)
	end
	for _, entry in pending do
		visit(entry.Node)
	end

	-- Who computes. Runs after ordering because a derived input's visibility is the
	-- visibility of that derived field.
	for _, node in ordered do
		local outRank = VISIBILITY_RANK[node.Visibility] or 1
		local transmit = false
		if node.Visibility ~= "ServerOnly" then
			for _, input in node.Derived.Inputs do
				if (VISIBILITY_RANK[input.Visibility] or 1) < outRank then
					transmit = true
					break
				end
			end
		end
		node.Derived.Transmit = transmit

		-- Offline reads see stored data only, so a root-level field whose every input
		-- persists can be computed over a snapshot. A derived input never persists but
		-- is filled in first (both passes run in topological order), so it counts as
		-- available exactly when it is itself computable.
		local offline = #node.Path == 1
		if offline then
			for _, input in node.Derived.Inputs do
				local viaDerived = input.Derived ~= nil and input.Derived.OfflineComputable
				if not input.Persist and not viaDerived then
					offline = false
					break
				end
			end
		end
		node.Derived.OfflineComputable = offline
	end

	-- Write index: a write at path W must recompute a dependent on input I when
	-- W == I or W is an ancestor of I (a whole-root Set from an init snapshot, say).
	-- Inputs are leaves, so no other relationship exists and one exact lookup per
	-- write is complete.
	local byWrite: { [string]: { any } } = {}
	for _, node in ordered do
		for _, segments in node.Derived.InputPaths do
			local prefix: { string | number } = {}
			for _, segment in segments do
				table.insert(prefix, segment)
				local key = Util.pathKey(prefix)
				local list = byWrite[key]
				if list == nil then
					list = {}
					byWrite[key] = list
				end
				local present = false
				for _, existing in list do
					if existing == node then
						present = true
						break
					end
				end
				if not present then
					table.insert(list, node)
				end
			end
		end
	end

	return ordered, byWrite
end

-- Validates a computed value against the output declarator, at the one place that
-- has no applySet to lean on: the compile-time default. Returns an error string.
local function checkDefault(node: any, value: any): string?
	local t = type(value)
	if node.ValueType == "int" or node.ValueType == "number" then
		if t ~= "number" then
			return `returned a {typeof(value)}, but the field is a {node.ValueType}`
		end
		if value ~= value or value == math.huge or value == -math.huge then
			return "returned NaN or infinity"
		end
	elseif node.ValueType == "string" then
		if t ~= "string" then
			return `returned a {typeof(value)}, but the field is a string`
		end
		if not Util.isUtf8(value :: string) then
			return "returned a string containing invalid UTF-8"
		end
	elseif node.ValueType == "boolean" then
		if t ~= "boolean" then
			return `returned a {typeof(value)}, but the field is a boolean`
		end
	elseif node.ValueType == "enum" then
		if t ~= "string" or node.MemberIndex == nil or node.MemberIndex[value] == nil then
			return `returned {tostring(value)}, which is not a member of the enum`
		end
	end
	return nil
end

--[[
	Seeds every derived field's Default from its inputs' defaults, in topological
	order, so a brand-new profile / a fresh session store / an edit-mode client all
	start out correct with no runtime work. Also the earliest possible purity check:
	the function runs once per realm at startup, before any player exists.
]]
function Derived.SeedDefaults(ordered: { any }, fail: (path: { string }, message: string) -> ())
	for _, node in ordered do
		local spec = node.Derived
		local values = table.create(#spec.Inputs)
		for i, input in spec.Inputs do
			values[i] = Derived.ReadForm(input, input.Default)
		end
		local ok, value = pcall(spec.Compute, table.unpack(values, 1, #spec.Inputs))
		if not ok then
			fail(node.Path, `the Scribe.Derived compute function threw while evaluating its default: {tostring(value)}`)
		end
		local problem = checkDefault(node, value)
		if problem then
			fail(node.Path, `the Scribe.Derived compute function {problem}`)
		end
		node.Default = value
	end
end

-- Evaluation -------------------------------------------------------------------

--- Runs one field's compute function. Never raises: a throwing function must not
--- fail the write that triggered the recompute.
function Derived.Compute(node: any, values: { any }, count: number): (boolean, any)
	return pcall(node.Derived.Compute, table.unpack(values, 1, count))
end

local function readPlain(data: { [string]: any }, segments: { string }): (boolean, any)
	local value: any = data
	for _, segment in segments do
		if type(value) ~= "table" then
			return false, nil
		end
		value = value[segment]
	end
	return true, value
end

--[[
	Evaluates derived fields over a plain data table (an offline profile snapshot, a
	client's Shared mirror for another player) rather than over an accessor tree.

	`filter` selects which fields apply; a field whose parent table is absent from
	`data` is skipped, which is what keeps an offline snapshot from growing a root
	that stored data never had.
]]
function Derived.EvaluateInto(compiled: any, data: { [string]: any }, filter: (node: any) -> boolean)
	local ordered = compiled.DerivedNodes
	if ordered == nil then
		return
	end
	for _, node in ordered do
		if filter(node) then
			local spec = node.Derived
			local values = table.create(#spec.Inputs)
			local complete = true
			for i, input in spec.Inputs do
				local ok, stored = readPlain(data, spec.InputPaths[i])
				if not ok then
					complete = false
					break
				end
				values[i] = Derived.ReadForm(input, stored)
			end
			if complete then
				-- Resolve the parent container in `data`; skip rather than create,
				-- so a mirror that never received this root stays as it was.
				local container: any = data
				local path = node.Path
				for i = 1, #path - 1 do
					container = if type(container) == "table" then container[path[i]] else nil
				end
				if type(container) == "table" then
					local ok, value = Derived.Compute(node, values, #spec.Inputs)
					if ok then
						container[path[#path]] = value
					end
				end
			end
		end
	end
end

return Derived
