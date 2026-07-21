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
	AnyChild: SchemaNode?, -- dynamic-key child: the compiled element schema on an
	-- ArrayOf/DictOf node (set at compile time), otherwise a generic pseudo-node
	-- synthesized lazily on first access
	HasDatatype: boolean?, -- true if any declared descendant is a packed datatype;
	-- lets container reads skip the deep-unpack walk when there is nothing to convert
	-- Scribe.ArrayOf / Scribe.DictOf container declarators. `Container` is the
	-- discriminator (nil on every other node, including untyped dynamic containers);
	-- `IsElement` marks the compiled element root hanging off AnyChild; `Closed`
	-- marks an element record whose field set is fixed, so an undeclared key is a
	-- write error rather than a silently synthesized `any` child.
	Container: ("Array" | "Dict")?,
	IsElement: boolean?,
	Closed: boolean?,
	-- Scribe.Optional: the field may legitimately be absent. Its Default is nil, so
	-- it is not seeded into a new profile and not filled into a partial element.
	Nullable: boolean?,
	-- Element default with ServerOnly subtrees removed, used when a CLIENT mirror
	-- materializes a fresh entry (see Node.resolveContainer).
	ClientDefault: any,
	MaxItems: number?,
	MaxKeys: number?,
	MaxKeyLength: number?,
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
-- Cooldown slots share the flat _Scribe.Timed dict with timed-field pathKeys and
-- are namespaced by this prefix. Owned here (not in Server/Timed) so Compile can
-- reject a root field that would alias a cooldown slot.
local COOLDOWN_PREFIX = "@cd|"

local Template = {}
Template.RESERVED_ROOT = RESERVED_ROOT
Template.SESSION_ROOT = SESSION_ROOT
Template.COOLDOWN_PREFIX = COOLDOWN_PREFIX

local function compileError(path: { string }, message: string): never
	error(`Scribe: template error at "{table.concat(path, ".")}": {message}`, 0)
end

-- A Scribe declarator anywhere inside an array-like container (directly under a
-- key, or nested deeper) would be silently stored as its raw marker table instead
-- of compiled into a schema field, so reject the ambiguous shape outright. A valid
-- data blob contains no markers, so scanning the whole blob is safe.
local function rejectNestedMarkers(path: { string }, value: any)
	local function walk(v: any, where: string)
		if Marker.inspect(v) ~= nil then
			compileError(
				path,
				`"{where}" is a Scribe declarator inside an array-like container, which stores its `
					.. `entries as opaque data and so has no schema for the declarator to compile into. `
					.. `Declare the element shape instead: Scribe.ArrayOf(\{ ... }) for a list, or `
					.. `Scribe.DictOf(\{ ... }) for a string-keyed table. That is also the only way to `
					.. `store a Roblox datatype inside a container`
			)
		elseif type(v) == "table" then
			for k, child in v do
				walk(child, if where == "" then tostring(k) else where .. "." .. tostring(k))
			end
		end
	end
	for k, v in value do
		walk(v, tostring(k))
	end
end

-- Declarators that cannot appear inside an ArrayOf/DictOf element shape, each with
-- the reason it is unsound there. Scanned over the RAW shape at compile time so a
-- bad template fails at startup rather than behaving subtly wrong per element.
local FORBIDDEN_IN_ELEMENT: { [string]: string } = {
	Timed = "timed state is keyed by path and element paths are positional (an array index shifts on every"
		.. " insert or remove), so a running timer would resolve to the wrong element; store an expiry field"
		.. " on the element instead",
	Dynamic = "a Scribe.Dynamic factory seeds a field once per brand-new profile, and elements do not exist"
		.. " then; generate per-element values at Insert time",
	Shared = "Scribe.Shared is only supported on root fields",
	Session = "Scribe.Session is only supported on root fields",
}

local function rejectInElementShape(path: { string }, shape: any)
	local function walk(v: any)
		if type(v) ~= "table" then
			return
		end
		local kind, default, meta = Marker.inspect(v)
		if kind ~= nil then
			local reason = FORBIDDEN_IN_ELEMENT[kind :: string]
			if reason then
				compileError(path, `Scribe.{kind} is not supported inside an element shape: {reason}`)
			end
			if kind == "ArrayOf" or kind == "DictOf" then
				-- A nested container hides its shape in Meta.Element, not in Default.
				walk(if meta then meta.Element else nil)
			else
				walk(default)
			end
			return
		end
		for _, child in v do
			walk(child)
		end
	end
	walk(shape)
end

local function checkContainerCap(path: { string }, label: string, value: any)
	if value == nil then
		return
	end
	if type(value) ~= "number" or value % 1 ~= 0 or value < 1 then
		compileError(path, `{label} must be a positive integer`)
	end
end

-- Element subtrees are addressed only through AnyChild, never by field id, so they
-- carry none. See the id-less rationale at the ArrayOf/DictOf branch in buildNode.
local function clearIds(node: SchemaNode)
	node.Id = nil
	if node.Children then
		for _, child in node.Children do
			clearIds(child)
		end
	end
	if node.AnyChild then
		clearIds(node.AnyChild)
	end
end

-- Deepest declared level below and including `node`, counting a nested container's
-- element as one further level (an element is reached through a key of its own).
local function declaredDepth(node: SchemaNode): number
	local deepest = 0
	if node.Children then
		for _, child in node.Children do
			local d = declaredDepth(child)
			if d > deepest then
				deepest = d
			end
		end
	end
	if node.AnyChild then
		local d = declaredDepth(node.AnyChild)
		if d > deepest then
			deepest = d
		end
	end
	return deepest + 1
end

-- Element default with ServerOnly subtrees dropped, mirroring BuildDefaults'
-- buildClient. A client mirror seeds fresh entries from this, so that writing one
-- field of a new element cannot conjure a ServerOnly sibling's declared value.
local function buildClientDefault(node: SchemaNode): any
	if node.Visibility == "ServerOnly" then
		return nil
	end
	if node.Kind ~= "table" or not node.Children then
		return Util.deepClone(node.Default)
	end
	local out = {}
	for key, child in node.Children do
		local value = buildClientDefault(child)
		if value ~= nil then
			out[key] = value
		end
	end
	return out
end

local function checkDefaultValue(path: { string }, value: any)
	local t = typeof(value)
	if t == "table" then
		local hasNum, hasStr = false, false
		for k, v in value do
			local kt = type(k)
			if kt ~= "string" and kt ~= "number" then
				compileError(path, `unsupported key type "{kt}"`)
			end
			hasNum = hasNum or kt == "number"
			hasStr = hasStr or kt == "string"
			if hasNum and hasStr then
				-- A mixed table cannot be JSON-encoded, so the very first save of a
				-- new profile seeded with this default would fail outright.
				compileError(path, "a default cannot mix array indices and string keys (it would fail the save)")
			end
			-- A string default key becomes a persisted JSON object key, so it must
			-- be valid UTF-8 or the very first save of a new profile fails.
			if kt == "string" and not Util.isUtf8(k :: string) then
				compileError(path, `default key "{k}" contains invalid UTF-8 bytes`)
			end
			local childPath = table.clone(path)
			table.insert(childPath, tostring(k))
			checkDefaultValue(childPath, v)
		end
	elseif t ~= "boolean" and t ~= "number" and t ~= "string" and t ~= "buffer" then
		compileError(path, `unsupported value type "{t}" (only booleans, numbers, strings, buffers and tables persist)`)
	elseif t == "number" and (value ~= value or value == math.huge or value == -math.huge) then
		compileError(path, "NaN/inf default")
	elseif t == "string" and not Util.isUtf8(value :: string) then
		-- A string default is seeded verbatim into every new profile and saved.
		compileError(path, "string default contains invalid UTF-8 bytes")
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
	-- A field name is a persisted JSON object key. Reject invalid UTF-8 at compile
	-- time (covers every named field, root and nested) so a bad template fails
	-- loudly at startup instead of at the first save. Field names built from
	-- external/dynamic data are the realistic way this slips in.
	if name ~= nil and not Util.isUtf8(name) then
		compileError(path, `field name contains invalid UTF-8 bytes`)
	end

	local visibility: Visibility = inheritedVisibility
	local timed = false
	local meta: Marker.Meta? = nil
	local valueType: string? = nil
	local containerKind: ("Array" | "Dict")? = nil
	local nullable = false
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
		elseif kind == "Optional" then
			-- Wraps another declarator: keep unwrapping so the inner type and bounds
			-- still compile, and drop the default to nil at the end of buildNode.
			nullable = true
		elseif kind == "ArrayOf" or kind == "DictOf" then
			-- The element shape lives in Meta.Element, and the marker's Default is
			-- nil, so the `value = default` below ends the unwrap loop here.
			containerKind = if kind == "ArrayOf" then "Array" else "Dict"
			meta = markerMeta
		elseif kind == "Dynamic" then
			-- `default` is the sample (the factory ran once at declaration). Infer
			-- the field type from it and carry the factory forward; it seeds the
			-- field per brand-new profile.
			if default == nil then
				compileError(path, "Scribe.Dynamic factory must return a non-nil value")
			end
			-- Dynamic seeds into the persistent store on a brand-new profile, but
			-- Session data lives in a separate, non-persisted store that is rebuilt
			-- from its default every session -- so a Session+Dynamic field's seed
			-- would land in the wrong store (invisible and wrongly saved). Reject
			-- the combination; use OnPlayerInit to generate per-session values.
			if visibility == "Session" then
				compileError(
					path,
					"Scribe.Dynamic is not supported on a Session field; generate per-session values in OnPlayerInit instead"
				)
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

	-- Scribe.ArrayOf / Scribe.DictOf: a dynamic container carrying a COMPILED element
	-- schema. Returns early, before the leaf and default machinery below, because the
	-- container declares no data of its own (its default is an empty table) and its
	-- element shape is compiled once and hung off AnyChild, which is the node every
	-- dynamic key already resolves through (see Template.ChildSchema).
	if containerKind ~= nil then
		local declarator = `Scribe.{containerKind}Of`
		local elementShape = if meta then meta.Element else nil
		if elementShape == nil then
			compileError(path, `{declarator} requires an element shape`)
		end
		if timed then
			compileError(path, `Scribe.Timed cannot wrap {declarator}`)
		end
		if nullable then
			compileError(
				path,
				`Scribe.Optional cannot wrap {declarator}; an empty container is already the absent case`
			)
		end
		rejectInElementShape(path, elementShape)
		checkContainerCap(path, "MaxItems", meta and meta.MaxItems)
		checkContainerCap(path, "MaxKeys", meta and meta.MaxKeys)
		checkContainerCap(path, "MaxKeyLength", meta and meta.MaxKeyLength)

		local node: SchemaNode = {
			Id = state.NextId,
			Name = name,
			Path = table.clone(path),
			Kind = "table",
			ValueType = "table",
			Visibility = visibility,
			Timed = false,
			Container = containerKind :: "Array" | "Dict",
			MaxItems = meta and meta.MaxItems,
			MaxKeys = meta and meta.MaxKeys,
			MaxKeyLength = meta and meta.MaxKeyLength,
			Default = {},
			Parent = parent,
		}
		state.ById[state.NextId :: number] = node
		state.NextId += 1
		if state.NextId > 65535 then
			error("Scribe: template exceeds 65535 static fields", 0)
		end

		-- Compile the element against a throwaway id counter, then strip the ids.
		-- Element fields are reachable only through AnyChild: Template.Resolve
		-- follows Children, and Wire.EncodePath sources ids from it, so an id here
		-- would be unaddressable at best and a decoder collision at worst. Being
		-- id-less also keeps element fields out of the 65535 budget and out of
		-- DynamicNodes. Their metadata still reaches the schema hash through the
		-- element pass in Compile.
		local elementPath = table.clone(path)
		table.insert(elementPath, "[]")
		local element = buildNode({ NextId = 0, ById = {} }, nil, elementShape, elementPath, visibility, node)
		clearIds(element)
		element.IsElement = true
		if element.Children and next(element.Children) == nil then
			compileError(path, `{declarator} element shape declares no fields`)
		end
		-- A declared record has a fixed field set at EVERY depth: an undeclared key
		-- on the element or on any nested sub-record is a write error rather than a
		-- silently accepted untyped field. Nested containers compiled their own
		-- element subtree already (their buildNode call ran this same
		-- post-processing), so the walk stops at container boundaries.
		local function closeRecords(n: SchemaNode)
			if n.Container == nil and n.Children then
				if next(n.Children) ~= nil then
					n.Closed = true
				end
				for _, child in n.Children do
					closeRecords(child)
				end
			end
		end
		closeRecords(element)
		element.ClientDefault = buildClientDefault(element)
		node.AnyChild = element
		node.HasDatatype = element.ValueType == "datatype" or element.HasDatatype == true

		local deepest = #path + declaredDepth(element)
		if deepest > Util.MAX_VALUE_DEPTH then
			compileError(
				path,
				`element shape nests {deepest} levels deep, past the {Util.MAX_VALUE_DEPTH}-level write limit`
			)
		end

		return node
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

	-- checkDefaultValue validates raw persistable leaf data. Run it for leaves
	-- and for array-like default blobs (whose elements are stored as data, not
	-- recursed as schema). A named container's children are each validated when
	-- buildNode recurses into them below; here `value` still holds their
	-- un-stripped markers (a datatype marker's Default is a raw datatype, a
	-- Dynamic marker's Meta holds a factory function), so walking the whole
	-- container would wrongly reject valid nested declarators.
	if type(value) ~= "table" or Util.hasNumericKeys(value) then
		-- Marker scan FIRST: a declarator holding a non-persistable default (any
		-- datatype, e.g. Scribe.CFrame) would otherwise trip checkDefaultValue's
		-- generic "unsupported value type" on the marker's raw .Default and bury the
		-- real problem, which is the declarator being inside an array at all.
		if type(value) == "table" then
			rejectNestedMarkers(path, value)
		end
		checkDefaultValue(path, value)
	end

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
			-- Array-like default: entries are DATA (deep-cloned, generically encoded),
			-- not schema. rejectNestedMarkers already ran above and refused any
			-- declarator nested in here.
			node.Default = Util.deepClone(value)
		else
			for k in value do
				-- sortedKeys would silently drop a non-string key, compiling a schema
				-- missing the field with no diagnostic at all.
				if type(k) ~= "string" then
					compileError(path, `record fields must have string names, got a {typeof(k)} key`)
				end
			end
			local children: { [string]: SchemaNode } = {}
			local order = Util.sortedKeys(value)
			local ordinal: { [string]: number } = {}
			local default = {}
			local hasDatatype = false
			for i, key in order do
				local childPath = table.clone(path)
				table.insert(childPath, key)
				local child = buildNode(state, key, value[key], childPath, visibility, node)
				children[key] = child
				ordinal[key] = i
				default[key] = child.Default
				-- Bubble the datatype marker up (post-order: child is fully built).
				if child.ValueType == "datatype" or child.HasDatatype then
					hasDatatype = true
				end
			end
			node.Children = children
			node.ChildOrder = order
			node.ChildOrdinal = ordinal
			node.Default = default
			node.HasDatatype = hasDatatype
		end
	else
		node.Default = value
	end

	-- Scribe.Optional: the inner declarator supplied the type and its bounds; the
	-- default is dropped so the field is neither seeded into a new profile nor
	-- filled into a partial element write. Absence is the point.
	if nullable then
		if timed then
			compileError(path, "Scribe.Optional cannot wrap Scribe.Timed: a lapsed timer restores the default")
		end
		if node.Factory then
			compileError(path, "Scribe.Optional cannot wrap Scribe.Dynamic: a factory exists to seed a value")
		end
		if node.Kind == "table" then
			compileError(path, "Scribe.Optional only wraps leaf values")
		end
		node.Nullable = true
		node.Default = nil
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
	-- pass/Plus ownership cache, the player's own save info, and an ownership-sync
	-- flag the server flips true once the async gamepass refresh completes (so the
	-- client can await it before trusting OwnsCache -- see Client/Server OwnsAsync).
	local sessionTemplate = {
		OwnsCache = {},
		SaveInfo = {},
		OwnsSynced = false,
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
		-- A top-level field's pathKey is just its name, so a root named "@cd|Daily"
		-- would collide with the cooldown slot of the same name in the flat
		-- _Scribe.Timed dict. Nested fields are safe: their pathKeys always contain
		-- the \31 separator, which a cooldown key never has.
		if string.sub(key, 1, #COOLDOWN_PREFIX) == COOLDOWN_PREFIX then
			error(
				`Scribe: template may not declare a "{key}" key: the "{COOLDOWN_PREFIX}" prefix is reserved for cooldown slots`,
				0
			)
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
	-- The root node is hand-built here rather than by buildNode, so bubble its
	-- HasDatatype flag the same way (else a whole-data Get()/Clone() on the root
	-- accessor would leak packed buffers for a ROOT-level datatype field).
	local rootHasDatatype = false
	for _, child in children do
		if child.ValueType == "datatype" or child.HasDatatype then
			rootHasDatatype = true
			break
		end
	end
	root.HasDatatype = rootHasDatatype

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
					.. `:{node.Datatype or "nil"}:{members}:{node.Container or "nil"}`
					.. `:{node.MaxItems or "nil"}:{node.MaxKeys or "nil"}:{node.MaxKeyLength or "nil"}`
					.. `:{node.Nullable == true}:{if node.ChildOrder then #node.ChildOrder else -1}`,
				hash
			)
		end
	end

	-- Element subtrees carry no ids, so the ById fold above cannot see them. Their
	-- Min/Max drive int width on the wire and their Members drive enum indexing, so
	-- an element-only drift between server and client would pass the Hello schema
	-- guard and then decode every following op in the frame as garbage. Fold them
	-- explicitly. Determinism comes from ChildOrder, which is sorted at compile time
	-- and therefore identical on both realms.
	local elementOrdinal = 0
	local function foldElementNode(n: SchemaNode)
		local members = ""
		if n.Members then
			local parts = table.create(#n.Members)
			for i, m in n.Members do
				parts[i] = `{#m}:{m}`
			end
			members = table.concat(parts, ",")
		end
		-- Leaf defaults matter here (unlike static nodes, whose defaults only seed
		-- new profiles server-side): mirrors materialize fresh element entries from
		-- these, so a drift would produce different seeded content on each realm.
		-- Table defaults are composed of the leaf defaults folded below them.
		local dflt = ""
		local d = n.Default
		local dt = type(d)
		if dt == "boolean" or dt == "string" then
			dflt = tostring(d)
		elseif dt == "number" then
			dflt = string.format("%.17g", d)
		elseif dt == "buffer" then
			dflt = buffer.tostring(d)
		end
		hash = Util.fnv32(
			`@{elementOrdinal}:{n.Name or ""}:{n.ValueType}:{n.Visibility}`
				.. `:{n.Min or "nil"}:{n.Max or "nil"}:{n.MaxLength or "nil"}`
				.. `:{n.Datatype or "nil"}:{members}:{n.Container or "nil"}`
				.. `:{n.MaxItems or "nil"}:{n.MaxKeys or "nil"}:{n.MaxKeyLength or "nil"}`
				.. `:{n.Nullable == true}:{if n.ChildOrder then #n.ChildOrder else -1}`
				.. `:{#dflt}:{dflt}`,
			hash
		)
		elementOrdinal += 1
		local nodeChildren = n.Children
		if n.ChildOrder and nodeChildren then
			for _, key in n.ChildOrder do
				foldElementNode(nodeChildren[key])
			end
		end
		if n.AnyChild then
			foldElementNode(n.AnyChild)
		end
		-- Subtree terminator: without it a field moved from a sub-record up to the
		-- element root folds to the same preorder byte stream as before the move.
		hash = Util.fnv32("/", hash)
	end
	local function foldElements(n: SchemaNode)
		local anyChild = n.AnyChild
		if anyChild and anyChild.IsElement then
			foldElementNode(anyChild)
		end
		local nodeChildren = n.Children
		if n.ChildOrder and nodeChildren then
			for _, key in n.ChildOrder do
				foldElements(nodeChildren[key])
			end
		end
	end
	foldElements(root)

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
	-- A compiled element record has a fixed field set, so an undeclared key resolves
	-- to nothing and the caller rejects the write. Without this, ChildSchema would
	-- synthesize a generic `any` node and CACHE it on the shared element schema,
	-- which both accepts the typo forever and mutates the compiled tree at runtime.
	if node.Closed then
		return nil
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
		if node.Visibility == "ServerOnly" then
			return nil
		end
		-- Packed datatypes are buffers, which are mutable and whose only reference
		-- here is live profile state. Callers mutate the returned tree in place
		-- (Replication.stripServerOnly rewrites queued op values), so hand back a copy.
		if type(value) == "buffer" then
			return Util.cloneBuffer(value)
		end
		return value
	end
	local out = {}
	local anyVisible = false
	for k, v in value do
		local childNode = if type(k) == "string" and node.Children then node.Children[k] else nil
		-- An ArrayOf/DictOf element schema describes EVERY entry, numeric keys
		-- included, so a ServerOnly field declared inside an element shape is
		-- stripped exactly like a static one. Gated on IsElement so untyped dynamic
		-- containers keep the wholesale deepClone branch below: routing them through
		-- the recursive branch would start aliasing live buffers into the queue.
		if childNode == nil and node.AnyChild ~= nil and node.AnyChild.IsElement then
			childNode = node.AnyChild
		end
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

-- Backfills element fields added to an ArrayOf/DictOf shape after profiles already
-- exist. ProfileStore's Reconcile walks the STATIC template only, and an element
-- shape is reachable solely through AnyChild, so without this a field added in v2
-- would stay missing on every stored entry forever: `Get()` would return nil against
-- a type that says the field is always present.
--
-- Mirrors Reconcile's semantics exactly: fill a missing key, never touch an existing
-- one. Nullable (Scribe.Optional) fields have a nil default and are correctly skipped
-- by the `Default ~= nil` test, since absence is their whole point. Returns true when
-- anything changed, so the caller can mark the profile dirty.
function Template.ReconcileElements(compiled: Compiled, data: { [string]: any }): boolean
	-- One recursive walk. `inElement` flips true under a container's AnyChild and
	-- stays true for everything beneath it, so fills happen at every depth of an
	-- element subtree: direct fields, fields of nested sub-records, and elements
	-- of containers nested inside elements. Static template fields (inElement
	-- false) are never filled here; profile:Reconcile owns those.
	local function walk(node: SchemaNode, value: any, inElement: boolean): boolean
		if type(value) ~= "table" then
			return false
		end
		local changed = false
		if node.Container ~= nil then
			local element = node.AnyChild
			if element then
				for _, entry in value do
					if walk(element, entry, true) then
						changed = true
					end
				end
			end
			return changed
		end
		if node.Children then
			for name, child in node.Children do
				if inElement and value[name] == nil and child.Default ~= nil then
					value[name] = Util.deepClone(child.Default)
					changed = true
				end
				if walk(child, value[name], inElement) then
					changed = true
				end
			end
		end
		return changed
	end

	local changed = false
	for key, child in compiled.Root.Children :: { [string]: SchemaNode } do
		if walk(child, data[key], false) then
			changed = true
		end
	end
	return changed
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
