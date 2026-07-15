--!strict
-- Template compiler + runtime schema derivation.
-- Walks the user template with sorted keys (deterministic on server and client),
-- strips declarator markers, assigns a u16 field ID to every static path node,
-- and records declared type/bounds/visibility metadata for validation and
-- wire packing.

local Util = require(script.Parent.Util)
local Marker = require(script.Parent.Marker)
local Datatypes = require(script.Parent.Datatypes)

export type Visibility = "Replicated" | "ServerOnly" | "Shared" | "Session"

export type SchemaNode = {
	Id: number?, -- nil for dynamic (any) pseudo-nodes
	Name: string?,
	Path: { string },
	Kind: "leaf" | "table" | "any",
	ValueType: "number" | "int" | "boolean" | "string" | "enum" | "buffer" | "datatype" | "table" | "any",
	Datatype: string?, -- typeof() name when ValueType == "datatype"
	Visibility: Visibility,
	Timed: boolean,
	Min: number?,
	Max: number?,
	MaxLength: number?,
	Members: { string }?,
	MemberIndex: { [string]: number }?, -- 0-based, for u8 packing
	Default: any,
	Factory: (() -> any)?, -- Scribe.Dynamic: seeds this field on a brand-new profile
	Children: { [string]: SchemaNode }?,
	ChildOrder: { string }?, -- sorted; ordinal i encodes child ChildOrder[i]
	ChildOrdinal: { [string]: number }?,
	Parent: SchemaNode?,
	AnyChild: SchemaNode?, -- lazily created pseudo-node for dynamic keys
}

export type Compiled = {
	Root: SchemaNode,
	ById: { [number]: SchemaNode },
	NodeCount: number,
	Hash: number,
	RootOrder: { string },
	DynamicNodes: { SchemaNode }, -- fields with a Scribe.Dynamic factory, in id order
	Config: CompileConfig,
}

export type CompileConfig = {
	ReplicateRobuxLog: boolean?,
	ReplicateInGameLog: boolean?,
}

local RESERVED_ROOT = "_Scribe"
local SESSION_ROOT = "_ScribeSession"

local Template = {}
Template.RESERVED_ROOT = RESERVED_ROOT
Template.SESSION_ROOT = SESSION_ROOT

local function compileError(path: { string }, message: string): never
	error(`Scribe: template error at "{table.concat(path, ".")}": {message}`, 0)
end

local function checkDefaultValue(path: { string }, value: any)
	local t = typeof(value)
	if t == "table" then
		for k, v in value do
			local kt = type(k)
			if kt ~= "string" and kt ~= "number" then
				compileError(path, `unsupported key type "{kt}"`)
			end
			local childPath = table.clone(path)
			table.insert(childPath, tostring(k))
			checkDefaultValue(childPath, v)
		end
	elseif t ~= "boolean" and t ~= "number" and t ~= "string" and t ~= "buffer" then
		compileError(
			path,
			`unsupported value type "{t}" (only booleans, numbers, strings, buffers and tables persist)`
		)
	elseif t == "number" and (value ~= value or value == math.huge or value == -math.huge) then
		compileError(path, "NaN/inf default")
	end
end

-- Builds one schema node from a (possibly marker-wrapped) template value.
local function buildNode(
	state: { NextId: number, ById: { [number]: SchemaNode } },
	name: string?,
	rawValue: any,
	path: { string },
	inheritedVisibility: Visibility,
	parent: SchemaNode?
): SchemaNode
	local visibility: Visibility = inheritedVisibility
	local timed = false
	local meta: Marker.Meta? = nil
	local valueType: string? = nil
	local value = rawValue

	-- Unwrap (possibly nested) markers, e.g. Scribe.Session wrapping a table
	-- whose fields use Scribe.Int.
	while true do
		local kind, default, markerMeta = Marker.inspect(value)
		if kind == nil then
			break
		end
		if kind == "ServerOnly" or kind == "Shared" or kind == "Session" then
			if (kind == "Shared" or kind == "Session") and #path > 1 then
				compileError(path, `Scribe.{kind} is only supported on root fields`)
			end
			visibility = kind :: Visibility
		elseif kind == "Timed" then
			timed = true
		elseif kind == "Int" then
			valueType = "int"
			meta = markerMeta
		elseif kind == "Number" then
			valueType = "number"
			meta = markerMeta
		elseif kind == "String" then
			valueType = "string"
			meta = markerMeta
		elseif kind == "Enum" then
			valueType = "enum"
			meta = markerMeta
		elseif kind == "Datatype" then
			valueType = "datatype"
			meta = markerMeta
		elseif kind == "Dynamic" then
			-- `default` is the sample (the factory ran once at declaration). Infer
			-- the field type from it and carry the factory forward; it seeds the
			-- field per brand-new profile.
			if default == nil then
				compileError(path, "Scribe.Dynamic factory must return a non-nil value")
			end
			local factory = if markerMeta then markerMeta.Factory else nil
			local sampleType = typeof(default)
			if Datatypes.IsSupported(sampleType) then
				valueType = "datatype"
				meta = { Datatype = sampleType, Factory = factory } :: Marker.Meta
			elseif type(default) == "table" then
				compileError(path, "Scribe.Dynamic only wraps leaf values (numbers, strings, datatypes, ...)")
			else
				meta = { Factory = factory } :: Marker.Meta
			end
		end
		value = default
	end

	local datatypeName: string? = nil
	if valueType == "datatype" then
		datatypeName = meta and meta.Datatype
		if not datatypeName or not Datatypes.IsSupported(datatypeName) then
			compileError(path, `unsupported datatype declarator`)
		end
		if typeof(value) ~= datatypeName then
			compileError(path, `default must be a {datatypeName}, got {typeof(value)}`)
		end
		-- Profile data only ever holds the packed form.
		value = Datatypes.Pack(datatypeName :: string, value)
	end

	checkDefaultValue(path, value)

	local node: SchemaNode = {
		Id = state.NextId,
		Name = name,
		Path = table.clone(path),
		Kind = if type(value) == "table" then "table" else "leaf",
		ValueType = (valueType or (if type(value) == "table" then "table" else type(value))) :: any,
		Visibility = visibility,
		Timed = timed,
		Datatype = datatypeName,
		Default = nil,
		Parent = parent,
	}
	state.ById[state.NextId :: number] = node
	state.NextId += 1
	if state.NextId > 65535 then
		error("Scribe: template exceeds 65535 static fields", 0)
	end

	if meta then
		node.Min = meta.Min
		node.Max = meta.Max
		node.MaxLength = meta.MaxLength
		if meta.Members then
			local members = table.clone(meta.Members)
			local index: { [string]: number } = {}
			for i, member in members do
				if type(member) ~= "string" then
					compileError(path, "enum members must be strings")
				end
				index[member] = i - 1
			end
			if #members > 255 then
				compileError(path, "enums support at most 255 members")
			end
			node.Members = members
			node.MemberIndex = index
		end
	end

	-- Scribe.Dynamic: record a factory that seeds this field on brand-new
	-- profiles. Datatype results are packed (profile.Data holds the packed form);
	-- other leaves pass through unchanged.
	if meta and meta.Factory then
		local rawFactory = meta.Factory
		if datatypeName then
			local dtName = datatypeName :: string
			node.Factory = function()
				return Datatypes.Pack(dtName, rawFactory())
			end
		else
			node.Factory = rawFactory
		end
	end

	-- Declarator sanity.
	if node.ValueType == "int" then
		if type(value) ~= "number" or value % 1 ~= 0 then
			compileError(path, "Scribe.Int default must be an integer")
		end
		-- Fractional bounds skew fixed-width int packing (value - Min is
		-- truncated), so require integer Min/Max on Int fields.
		if (node.Min ~= nil and node.Min % 1 ~= 0) or (node.Max ~= nil and node.Max % 1 ~= 0) then
			compileError(path, "Scribe.Int Min/Max must be integers")
		end
	elseif node.ValueType == "enum" then
		if not node.MemberIndex or node.MemberIndex[value] == nil then
			compileError(path, "enum default must be one of its members")
		end
	elseif node.ValueType == "string" and type(value) ~= "string" then
		compileError(path, "Scribe.String default must be a string")
	elseif node.ValueType == "number" and type(value) ~= "number" then
		compileError(path, "Scribe.Number default must be a number")
	end
	if node.Min and node.Max and node.Min > node.Max then
		compileError(path, "Min > Max")
	end
	if timed and type(value) == "table" then
		compileError(path, "Scribe.Timed only wraps leaf values")
	end

	if node.Kind == "table" then
		if Util.hasNumericKeys(value) then
			-- Array-like default: entries are data, not schema. Elements are
			-- encoded generically.
			node.Default = Util.deepClone(value)
		else
			local children: { [string]: SchemaNode } = {}
			local order = Util.sortedKeys(value)
			local ordinal: { [string]: number } = {}
			local default = {}
			for i, key in order do
				local childPath = table.clone(path)
				table.insert(childPath, key)
				local child = buildNode(state, key, value[key], childPath, visibility, node)
				children[key] = child
				ordinal[key] = i
				default[key] = child.Default
			end
			node.Children = children
			node.ChildOrder = order
			node.ChildOrdinal = ordinal
			node.Default = default
		end
	else
		node.Default = value
	end

	return node
end

-- Reserved internal roots: built server-only by default, then per-subkey
-- visibility applied explicitly so the rules are exact.
local function buildInternalRoots(state: any, root: SchemaNode, config: CompileConfig)
	local scribeTemplate = {
		GiftCredits = {},
		PendingGifts = {},
		Perks = {},
		ProcessedPurchaseIds = {},
		PurchaseLogs = {
			InGame = {},
			Robux = {},
		},
		Timed = {},
		Version = Marker.make("Int", 1, { Min = 0 }),
	}

	local scribeNode = buildNode(state, RESERVED_ROOT, scribeTemplate, { RESERVED_ROOT }, "ServerOnly", root)
	local children = scribeNode.Children :: { [string]: SchemaNode }
	local function setVisibility(node: SchemaNode, visibility: Visibility)
		node.Visibility = visibility
		if node.Children then
			for _, child in node.Children do
				setVisibility(child, visibility)
			end
		end
	end
	setVisibility(children.Perks, "Replicated")
	setVisibility(children.GiftCredits, "Replicated")
	-- Purchase logs are opt-in per kind (PurchaseLog.ReplicateRobux/InGame);
	-- the container itself only replicates when at least one kind does, so the
	-- default sends nothing at all.
	local logs = children.PurchaseLogs
	local replicateRobux = config.ReplicateRobuxLog == true
	local replicateInGame = config.ReplicateInGameLog == true
	logs.Visibility = if replicateRobux or replicateInGame then "Replicated" else "ServerOnly"
	local logChildren = logs.Children :: { [string]: SchemaNode }
	setVisibility(logChildren.Robux, (if replicateRobux then "Replicated" else "ServerOnly") :: Visibility)
	setVisibility(logChildren.InGame, (if replicateInGame then "Replicated" else "ServerOnly") :: Visibility)

	-- _ScribeSession: never persisted, replicated to the owner. Holds the pass/
	-- pass/Plus ownership cache and the player's own save info.
	local sessionTemplate = {
		OwnsCache = {},
		SaveInfo = {},
	}
	local sessionNode = buildNode(state, SESSION_ROOT, sessionTemplate, { SESSION_ROOT }, "Session", root)

	return scribeNode, sessionNode
end

function Template.Compile(userTemplate: any, config: CompileConfig?): Compiled
	local cfg: CompileConfig = config or {}
	if type(userTemplate) ~= "table" then
		error("Scribe: Template must be a table", 0)
	end
	for key in userTemplate do
		if type(key) ~= "string" then
			error("Scribe: template root keys must be strings", 0)
		end
		if string.sub(key, 1, #RESERVED_ROOT) == RESERVED_ROOT then
			error(`Scribe: template may not declare a "{key}" key — the {RESERVED_ROOT} root is library-owned`, 0)
		end
	end

	local state = { NextId = 1, ById = {} :: { [number]: SchemaNode } }
	local root: SchemaNode = {
		Id = 0,
		Name = nil,
		Path = {},
		Kind = "table",
		ValueType = "table",
		Visibility = "Replicated",
		Timed = false,
		Default = nil,
		Parent = nil,
	}
	state.ById[0] = root

	local children: { [string]: SchemaNode } = {}
	local userOrder = Util.sortedKeys(userTemplate)
	for _, key in userOrder do
		children[key] = buildNode(state, key, userTemplate[key], { key }, "Replicated", root)
	end

	local scribeNode, sessionNode = buildInternalRoots(state, root, cfg)
	children[RESERVED_ROOT] = scribeNode
	children[SESSION_ROOT] = sessionNode

	local order = table.clone(userOrder)
	table.insert(order, RESERVED_ROOT)
	table.insert(order, SESSION_ROOT)
	table.sort(order)

	local ordinal: { [string]: number } = {}
	for i, key in order do
		ordinal[key] = i
	end
	root.Children = children
	root.ChildOrder = order
	root.ChildOrdinal = ordinal

	-- The hash must fold every field that affects the wire byte layout, or a
	-- server/client schema drift decodes silently wrong. Min/Max drive int
	-- width; Members drive enum indexing; Datatype/MaxLength are semantic.
	local hash = 2166136261
	for id = 0, state.NextId - 1 do
		local node = state.ById[id]
		if node then
			local members = ""
			if node.Members then
				local parts = table.create(#node.Members)
				for i, m in node.Members do
					parts[i] = `{#m}:{m}`
				end
				members = table.concat(parts, ",")
			end
			hash = Util.fnv32(
				`{id}:{node.Name or ""}:{node.ValueType}:{node.Visibility}`
					.. `:{node.Min or "nil"}:{node.Max or "nil"}:{node.MaxLength or "nil"}`
					.. `:{node.Datatype or "nil"}:{members}`,
				hash
			)
		end
	end

	-- Flatten the fields carrying a Scribe.Dynamic factory (in id order), so the
	-- load path can seed them on a new profile without walking the whole tree.
	local dynamicNodes: { SchemaNode } = {}
	for id = 0, state.NextId - 1 do
		local node = state.ById[id]
		if node and node.Factory then
			table.insert(dynamicNodes, node)
		end
	end

	return {
		Root = root,
		ById = state.ById,
		NodeCount = state.NextId,
		Hash = hash,
		RootOrder = order,
		DynamicNodes = dynamicNodes,
		Config = cfg,
	}
end

-- Schema node for a child key: the static child when one exists, otherwise a
-- (cached) dynamic pseudo-node inheriting the parent's visibility. Returns nil
-- for children of leaves.
function Template.ChildSchema(node: SchemaNode, key: string | number): SchemaNode?
	if node.Kind == "leaf" then
		return nil
	end
	if type(key) == "string" and node.Children then
		local child = node.Children[key]
		if child then
			return child
		end
	end
	local anyChild = node.AnyChild
	if not anyChild then
		local created: SchemaNode = {
			Id = nil,
			Name = nil,
			Path = node.Path,
			Kind = "any",
			ValueType = "any",
			Visibility = node.Visibility,
			Timed = false,
			Default = nil,
			Parent = node,
		}
		node.AnyChild = created
		anyChild = created
	end
	return anyChild
end

-- Resolve a path to (deepest static schema node, index of the first dynamic
-- segment). If the whole path is static, the index is #path + 1.
function Template.Resolve(compiled: Compiled, path: { string | number }): (SchemaNode, number)
	local node = compiled.Root
	for i, seg in path do
		if type(seg) == "string" and node.Children and node.Children[seg] then
			node = node.Children[seg]
		else
			return node, i
		end
	end
	return node, #path + 1
end

-- Effective visibility of a path (deepest static node's visibility; dynamic
-- segments inherit).
function Template.VisibilityOf(compiled: Compiled, path: { string | number }): Visibility
	local node = Template.Resolve(compiled, path)
	return node.Visibility
end

-- Deep-cloned default data. which:
--  "Persistent" — everything saved (visibility ~= Session); the ProfileStore template
--  "Session"    — Session roots only
--  "Client"     — everything except ServerOnly subtrees (the owner's mirror)
function Template.BuildDefaults(compiled: Compiled, which: "Persistent" | "Session" | "Client"): { [string]: any }
	local function include(node: SchemaNode): boolean
		if which == "Persistent" then
			return node.Visibility ~= "Session"
		elseif which == "Session" then
			return node.Visibility == "Session"
		else
			return node.Visibility ~= "ServerOnly"
		end
	end

	-- Client defaults strip ServerOnly subtrees but keep mixed-visibility
	-- containers whose children are visible (the _Scribe reserved root).
	local function buildClient(node: SchemaNode): any
		if node.Kind ~= "table" or not node.Children then
			return if node.Visibility == "ServerOnly" then nil else Util.deepClone(node.Default)
		end
		local out = {}
		local anyVisible = false
		for key, child in node.Children do
			local value = buildClient(child)
			if value ~= nil then
				out[key] = value
				anyVisible = true
			end
		end
		if node.Visibility == "ServerOnly" and not anyVisible then
			return nil
		end
		return out
	end

	local function build(node: SchemaNode): any
		if node.Kind ~= "table" or not node.Children then
			return Util.deepClone(node.Default)
		end
		local out = {}
		for key, child in node.Children do
			out[key] = build(child)
		end
		return out
	end

	local out = {}
	for key, child in compiled.Root.Children :: { [string]: SchemaNode } do
		if which == "Client" then
			out[key] = buildClient(child)
		elseif include(child) then
			out[key] = build(child)
		end
	end
	return out
end

-- Clone `value` at `node`, stripping ServerOnly subtrees (used for Init
-- snapshots and offline perk reads). Mixed-visibility containers (like the
-- reserved _Scribe root: ServerOnly by default with Replicated subkeys)
-- keep their visible children; returns nil only when nothing is visible AND
-- the node itself is ServerOnly.
function Template.CloneVisible(node: SchemaNode, value: any): any
	if type(value) ~= "table" then
		return if node.Visibility == "ServerOnly" then nil else value
	end
	local out = {}
	local anyVisible = false
	for k, v in value do
		local childNode = if type(k) == "string" and node.Children then node.Children[k] else nil
		if childNode then
			local cloned = Template.CloneVisible(childNode, v)
			if cloned ~= nil then
				out[k] = cloned
				anyVisible = true
			end
		elseif node.Visibility ~= "ServerOnly" then
			-- Dynamic entries inherit this node's visibility.
			out[k] = Util.deepClone(v)
			anyVisible = true
		end
	end
	if node.Visibility == "ServerOnly" and not anyVisible then
		return nil
	end
	return out
end

-- Top-level keys present in `data` but absent from the schema (dev-mode
-- warning; note that `nil :: T?` template fields are invisible at runtime).
function Template.UnknownRootKeys(compiled: Compiled, data: { [string]: any }): { string }
	local unknown = {}
	local children = compiled.Root.Children :: { [string]: SchemaNode }
	for key in data do
		if type(key) ~= "string" or not children[key] then
			table.insert(unknown, tostring(key))
		end
	end
	table.sort(unknown)
	return unknown
end

return Template
