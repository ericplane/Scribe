--!strict
-- The Value tree runtime: a metatable-backed accessor tree that
-- lazily materializes child nodes, records paths for replication, validates
-- every write, and holds per-node callback lists. Used for the
-- server's authoritative tree and the client's mirror alike.

local Util = require(script.Parent.Util)
local Template = require(script.Parent.Template)
local Datatypes = require(script.Parent.Datatypes)

type SchemaNode = Template.SchemaNode
type Compiled = Template.Compiled

export type Op = {
	Kind: string,
	Path: { string | number },
	Value: any?,
	Index: number?,
}

export type TimedHooks = {
	SetTimed: (accessor: any, value: any, seconds: number, replicate: boolean?) -> (),
	ExtendTimed: (accessor: any, seconds: number, replicate: boolean?) -> (),
	Active: (accessor: any) -> (boolean, number?),
}

export type TreeParams = {
	Compiled: Compiled,
	Stores: { Persist: { [string]: any }, Session: { [string]: any } },
	IsServer: boolean,
	Label: string,
	OnOp: ((op: Op, schema: SchemaNode?) -> ())?,
	OnAnomaly: ((path: { string | number }, value: any, reason: string) -> ())?,
	BoundsPolicy: ("Clamp" | "Reject")?,
	DevMode: boolean?,
	TimedHooks: TimedHooks?,
	OnEconomy: ((path: { string | number }, delta: number, newValue: number, tags: { [string]: any }) -> ())?,
	LogError: (message: string) -> (),
	LogWarn: ((message: string) -> ())?,
	OnBatchEnd: (() -> ())?,
}

local Node = {}

local ACCESSOR_MT: any -- forward declaration

-- Tree ------------------------------------------------------------------------

local Tree = {}
Tree.__index = Tree

export type Tree = typeof(setmetatable(
	{} :: {
		Params: TreeParams,
		Compiled: Compiled,
		Accessor: any,
		Dead: boolean,
		_listeners: { [string]: { [string]: { [any]: (...any) -> () } } },
		-- path array for each listener'd pathKey, so the Init replay can read a
		-- node's value without reversing the (lossy) pathKey string.
		_paths: { [string]: { string | number } },
		-- true only while replaying the initial snapshot: suppresses per-op fires
		-- so descendants can be fired once, together, afterwards.
		_replaying: boolean,
		_accessors: { [string]: any },
		_batchDepth: number,
		_txn: { Snapshots: { [string]: { Path: { string | number }, Value: any } }, Ops: { { Op: Op, Schema: SchemaNode? } }, Created: { { string | number } } }?,
	},
	Tree
))

local function newAccessor(tree: Tree, path: { string | number }, schema: SchemaNode?): any
	local accessor: any = setmetatable({}, ACCESSOR_MT)
	rawset(accessor, "_tree", tree)
	rawset(accessor, "_path", path)
	rawset(accessor, "_key", Util.pathKey(path))
	rawset(accessor, "_schema", schema)
	rawset(accessor, "_children", {})
	return accessor
end

function Node.NewTree(params: TreeParams): Tree
	local self = setmetatable({
		Params = params,
		Compiled = params.Compiled,
		Accessor = nil :: any,
		Dead = false,
		_listeners = {},
		_paths = {},
		_replaying = false,
		_accessors = {},
		_batchDepth = 0,
		_txn = nil,
	}, Tree)
	self.Accessor = newAccessor(self, {}, params.Compiled.Root)
	return self :: any
end

local function assertAlive(tree: Tree)
	if tree.Dead then
		error(`Scribe: data for {tree.Params.Label} has been unloaded`, 3)
	end
end

local function storeFor(tree: Tree, rootKey: string | number): { [string]: any }
	local children = tree.Compiled.Root.Children
	if type(rootKey) == "string" and children then
		local rootSchema = children[rootKey]
		if rootSchema and rootSchema.Visibility == "Session" then
			return tree.Params.Stores.Session
		end
	end
	return tree.Params.Stores.Persist
end

-- Resolves the container holding path's last segment. When `create` is true,
-- missing intermediate tables are materialized.
local function resolveContainer(tree: Tree, path: { string | number }, create: boolean): (any, any)
	local n = #path
	if n == 0 then
		return nil, nil
	end
	local container: any = storeFor(tree, path[1])
	for i = 1, n - 1 do
		local seg = path[i]
		local nextContainer = container[seg]
		if nextContainer == nil then
			if not create then
				return nil, nil
			end
			nextContainer = {}
			container[seg] = nextContainer
			-- Record containers materialized mid-transaction so a rollback can
			-- prune them (they never existed pre-transaction).
			local txn = tree._txn
			if txn then
				txn.Created[#txn.Created + 1] = table.move(path, 1, i, 1, table.create(i))
			end
		elseif type(nextContainer) ~= "table" then
			error(`Scribe: cannot index "{Util.pathString(path)}" — "{tostring(seg)}" is not a table`, 0)
		end
		container = nextContainer
	end
	return container, path[n]
end

local function readValue(tree: Tree, path: { string | number }): any
	if #path == 0 then
		return tree.Params.Stores.Persist
	end
	local container, key = resolveContainer(tree, path, false)
	if container == nil then
		return nil
	end
	return container[key]
end

-- Listeners ---------------------------------------------------------------------

local function listenersFor(tree: Tree, pathKey: string, event: string, create: boolean): { [any]: (...any) -> () }?
	local byEvent = tree._listeners[pathKey]
	if byEvent == nil then
		if not create then
			return nil
		end
		byEvent = {}
		tree._listeners[pathKey] = byEvent
	end
	local list = byEvent[event]
	if list == nil then
		if not create then
			return nil
		end
		list = {}
		byEvent[event] = list
	end
	return list
end

local function connect(tree: Tree, path: { string | number }, event: string, fn: (...any) -> ()): () -> ()
	assertAlive(tree)
	local pathKey = Util.pathKey(path)
	local list = listenersFor(tree, pathKey, event, true) :: { [any]: (...any) -> () }
	tree._paths[pathKey] = path
	local token = {}
	list[token] = fn
	return function()
		local byEvent = tree._listeners[pathKey]
		local current = byEvent and byEvent[event]
		if current then
			current[token] = nil
			-- Reclaim now-empty listener tables so they don't accumulate and
			-- permanently defeat the fireAncestors no-listener fast path.
			if next(current) == nil then
				byEvent[event] = nil
				if next(byEvent) == nil then
					tree._listeners[pathKey] = nil
					tree._paths[pathKey] = nil
				end
			end
		end
	end
end

local function fire(tree: Tree, pathKey: string, event: string, ...: any)
	if tree._replaying then
		return -- suppressed during the Init replay; fired together afterwards
	end
	local list = listenersFor(tree, pathKey, event, false)
	if list == nil then
		return
	end
	local args = table.pack(...)
	for _, fn in list do
		local ok, err = xpcall(function()
			fn(table.unpack(args, 1, args.n))
		end, function(e)
			return debug.traceback(tostring(e), 2)
		end)
		if not ok then
			tree.Params.LogError(`listener error at "{pathKey}" ({event}): {err}`)
		end
	end
end

-- Fires Changed on every ancestor of `path` that has listeners, passing the
-- immediate child key along the changed path.
local function fireAncestors(tree: Tree, path: { string | number })
	if next(tree._listeners) == nil then
		return
	end
	for depth = #path - 1, 0, -1 do
		local prefix = table.move(path, 1, depth, 1, table.create(depth)) :: { string | number }
		local pathKey = Util.pathKey(prefix)
		local list = listenersFor(tree, pathKey, "Changed", false)
		if list and next(list) ~= nil then
			local value = readValue(tree, prefix)
			fire(tree, pathKey, "Changed", value, value, path[depth + 1])
		end
	end
end

-- Tier-1 validation ----------------------------------------------------------

local function anomaly(tree: Tree, path: { string | number }, value: any, reason: string)
	if tree.Params.OnAnomaly then
		tree.Params.OnAnomaly(path, value, reason)
	end
end

local function validationError(path: { string | number }, message: string): never
	error(`Scribe: invalid write to "{Util.pathString(path)}": {message}`, 0)
end

-- Matches the wire codec's recursion cap (Wire.luau); a value that passes
-- validation must always be encodable, so over-deep tables are rejected here.
local MAX_VALUE_DEPTH = 24

-- Returns the (possibly clamped) value to write. Throws on type violations.
local function validateWrite(
	tree: Tree,
	schema: SchemaNode?,
	path: { string | number },
	value: any,
	depth: number?
): any
	if value == nil then
		return nil
	end
	-- Depth is budgeted from the ROOT (seeded with the path length), because
	-- Init snapshots re-encode the whole root from depth 0. A value accepted
	-- here must always be encodable from the root, or it silently drops the
	-- entire root from every snapshot.
	local d = depth or math.max(0, #path - 1)
	if d > MAX_VALUE_DEPTH then
		validationError(path, `nested deeper than {MAX_VALUE_DEPTH} levels from the root`)
	end

	-- Declared datatype fields accept their Roblox datatype (packed at the
	-- boundary) or an already-packed buffer (timed sweeps restoring defaults,
	-- migrations writing packed values). Checked before the generic type gate,
	-- which would otherwise reject the userdata.
	if schema and schema.ValueType == "datatype" then
		local name = schema.Datatype :: string
		if typeof(value) == name then
			local ok, packed = pcall(Datatypes.Pack, name, value)
			if not ok then
				if type(packed) == "string" and string.find(packed, Datatypes.NONFINITE, 1, true) then
					anomaly(tree, path, value, "NonFiniteComponent")
					validationError(path, `{name} has a NaN/inf component`)
				end
				validationError(path, `could not pack {name}: {tostring(packed)}`)
			end
			return packed
		end
		if type(value) == "buffer" then
			return Util.cloneBuffer(value)
		end
		validationError(path, `expected {name}, got {typeof(value)}`)
	end

	local t = type(value)
	if t == "function" or t == "thread" or t == "userdata" or typeof(value) ~= t then
		validationError(path, `unsupported type "{typeof(value)}"`)
	end
	if t == "number" and (value ~= value or value == math.huge or value == -math.huge) then
		validationError(path, "NaN/inf")
	end

	local vt = if schema then schema.ValueType else "any"
	local policy = tree.Params.BoundsPolicy or "Clamp"

	if vt == "boolean" then
		if t ~= "boolean" then
			validationError(path, `expected boolean, got {t}`)
		end
	elseif vt == "number" or vt == "int" then
		if t ~= "number" then
			validationError(path, `expected number, got {t}`)
		end
		local v = value :: number
		if vt == "int" and v % 1 ~= 0 then
			if policy == "Reject" then
				validationError(path, "expected integer")
			end
			v = math.floor(v + 0.5)
		end
		local min = schema and schema.Min
		local max = schema and schema.Max
		if (min and v < min) or (max and v > max) then
			anomaly(tree, path, value, "OutOfBounds")
			if policy == "Reject" then
				validationError(path, `out of bounds [{min or "-inf"}, {max or "inf"}]`)
			end
			v = math.clamp(v, min or -math.huge, max or math.huge)
		end
		return v
	elseif vt == "string" or vt == "enum" then
		if t ~= "string" then
			validationError(path, `expected string, got {t}`)
		end
		if vt == "enum" then
			local index = schema and schema.MemberIndex
			if index and index[value] == nil then
				anomaly(tree, path, value, "NotAMember")
				validationError(path, `"{value}" is not a member of the enum`)
			end
		end
		local maxLength = schema and schema.MaxLength
		if maxLength and #(value :: string) > maxLength then
			anomaly(tree, path, value, "OverMaxLength")
			if policy == "Reject" then
				validationError(path, `exceeds MaxLength {maxLength}`)
			end
			return string.sub(value :: string, 1, maxLength)
		end
	elseif vt == "buffer" then
		if t ~= "buffer" then
			validationError(path, `expected buffer, got {t}`)
		end
	elseif vt == "table" then
		if t ~= "table" then
			validationError(path, `expected table, got {t}`)
		end
	end

	if t == "buffer" then
		-- Buffers are mutable: store a private copy so a caller-held reference
		-- can't bypass replication later.
		return Util.cloneBuffer(value)
	end

	if t == "table" then
		-- Recursive Tier-1 over the written table; cost is proportional to the
		-- table being written. The root-relative depth guard at the top rejects
		-- any level the wire codec could not encode.
		local out = {}
		for k, v in value do
			local kt = type(k)
			if kt ~= "string" and kt ~= "number" then
				validationError(path, `unsupported key type "{kt}"`)
			end
			if kt == "number" then
				-- Non-integer / non-finite numeric keys do not survive the
				-- DataStore JSON round-trip; reject them at the write boundary.
				if k ~= k or k == math.huge or k == -math.huge or k % 1 ~= 0 then
					validationError(path, "invalid numeric key (must be a finite integer)")
				end
			elseif string.find(k :: string, "\31", 1, true) then
				-- char 31 is the pathKey separator; a key containing it would
				-- alias a distinct path in coalescing/listeners/rollback.
				validationError(path, "string key may not contain control character \\31")
			end
			local childSchema = if schema then Template.ChildSchema(schema, k) else nil
			local childPath = table.clone(path)
			table.insert(childPath, k)
			out[k] = validateWrite(tree, childSchema, childPath, v, d + 1)
		end
		return out
	end

	return value
end

-- Mutation core ----------------------------------------------------------------

type WriteOpts = {
	Replicate: boolean?,
	FromRemote: boolean?,
	NoOp: boolean?, -- rollback writes: fire listeners but never emit ops
	NoValidate: boolean?,
}

local function emitOp(tree: Tree, op: Op, schema: SchemaNode?, opts: WriteOpts)
	if opts.NoOp or opts.FromRemote or opts.Replicate == false then
		return
	end
	local onOp = tree.Params.OnOp
	if onOp == nil then
		return
	end
	if tree._txn then
		table.insert(tree._txn.Ops, { Op = op, Schema = schema })
	else
		onOp(op, schema)
	end
end

-- Whether `a` is a strict ancestor path of `b` (a shorter, matching prefix).
local function pathIsStrictAncestor(a: { string | number }, b: { string | number }): boolean
	if #a >= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

-- Restore `value` at a relative path inside `root`, creating tables as needed.
local function setNested(root: { [any]: any }, relPath: { string | number }, value: any)
	local container = root
	for i = 1, #relPath - 1 do
		local seg = relPath[i]
		local nextContainer = container[seg]
		if type(nextContainer) ~= "table" then
			nextContainer = {}
			container[seg] = nextContainer
		end
		container = nextContainer
	end
	container[relPath[#relPath]] = value
end

-- Records the pre-transaction value of `path`, keeping snapshots DISJOINT so
-- rollback order is irrelevant. If an ancestor is already snapshotted, this
-- subtree is covered. If descendants were snapshotted earlier, this path's true
-- pre-transaction value is reconstructed by overlaying their pre-txn values
-- onto the current (possibly already-mutated) value, and those now-subsumed
-- descendant snapshots are dropped.
local function snapshotForTxn(tree: Tree, path: { string | number }, pathKey: string, oldValue: any)
	local txn = tree._txn
	if not txn or txn.Snapshots[pathKey] ~= nil then
		return
	end
	for _, snap in txn.Snapshots do
		if pathIsStrictAncestor(snap.Path, path) then
			return
		end
	end
	local value = Util.deepClone(oldValue)
	for descKey, snap in txn.Snapshots do
		if pathIsStrictAncestor(path, snap.Path) then
			if type(value) ~= "table" then
				value = {}
			end
			local relPath = table.move(snap.Path, #path + 1, #snap.Path, 1, table.create(#snap.Path - #path))
			setNested(value, relPath, snap.Value)
			txn.Snapshots[descKey] = nil
		end
	end
	txn.Snapshots[pathKey] = { Path = table.clone(path), Value = value }
end

local function applySet(tree: Tree, path: { string | number }, schema: SchemaNode?, value: any, opts: WriteOpts): any
	-- validateWrite rebuilds tables entry-by-entry (no aliasing); unvalidated
	-- table writes are cloned explicitly instead.
	local newValue = if opts.NoValidate then value else validateWrite(tree, schema, path, value)
	if type(newValue) == "table" and opts.NoValidate then
		newValue = Util.deepClone(newValue)
	end

	local container, key = resolveContainer(tree, path, newValue ~= nil)
	if container == nil then
		if newValue == nil then
			return nil -- removing under a missing parent is a no-op
		end
		error(`Scribe: cannot write to "{Util.pathString(path)}"`, 0)
	end

	local old = container[key]
	if Util.leafEquals(old, newValue) then
		return old
	end

	local pathKey = Util.pathKey(path)
	snapshotForTxn(tree, path, pathKey, old)
	container[key] = newValue

	emitOp(tree, { Kind = "Set", Path = table.clone(path), Value = newValue }, schema, opts)

	fire(tree, pathKey, "Changed", newValue, old)
	-- Dictionary key events on the parent (dynamic keys only).
	if #path >= 1 then
		local parentPath = table.move(path, 1, #path - 1, 1, table.create(#path - 1)) :: { string | number }
		local parentSchema = if schema then schema.Parent else nil
		local isDynamic = parentSchema == nil
			or parentSchema.Children == nil
			or type(key) ~= "string"
			or parentSchema.Children[key :: string] == nil
		if isDynamic then
			local parentKey = Util.pathKey(parentPath)
			if old == nil and newValue ~= nil then
				fire(tree, parentKey, "OnKeyAdded", key, newValue)
			elseif old ~= nil and newValue == nil then
				fire(tree, parentKey, "OnKeyRemoved", key, old)
			end
		end
	end
	fireAncestors(tree, path)
	return newValue
end

local function ensureContainerValue(tree: Tree, path: { string | number }, _schema: SchemaNode?): { [any]: any }
	local container, key = resolveContainer(tree, path, true)
	if container == nil then
		error(`Scribe: cannot access "{Util.pathString(path)}"`, 0)
	end
	local value = container[key]
	if value == nil then
		value = {}
		container[key] = value
	elseif type(value) ~= "table" then
		error(`Scribe: "{Util.pathString(path)}" is not a container`, 0)
	end
	return value
end

local function applyInsert(tree: Tree, path: { string | number }, schema: SchemaNode?, item: any, pos: number?, opts: WriteOpts)
	-- Validate the item BEFORE creating any container, so a rejected item can
	-- never leave a phantom container behind.
	local elementSchema = if schema then Template.ChildSchema(schema, 1) else nil
	local value = if opts.NoValidate then Util.deepClone(item) else validateWrite(tree, elementSchema, path, item)

	local pathKey = Util.pathKey(path)
	-- Snapshot the pre-creation value (nil if the array does not yet exist) so a
	-- rolled-back transaction restores the true prior state, not an empty table.
	local existingContainer, existingKey = resolveContainer(tree, path, false)
	local preValue = if existingContainer then existingContainer[existingKey] else nil
	snapshotForTxn(tree, path, pathKey, preValue)

	local arr = ensureContainerValue(tree, path, schema)
	local index = math.clamp(pos or #arr + 1, 1, #arr + 1)
	table.insert(arr, index, value)

	emitOp(tree, { Kind = "Insert", Path = table.clone(path), Value = value, Index = index }, schema, opts)
	fire(tree, pathKey, "OnInsert", value, index)
	fire(tree, pathKey, "Changed", arr, arr, index)
	fireAncestors(tree, path)
end

local function applyArrayRemove(tree: Tree, path: { string | number }, schema: SchemaNode?, pos: number?, opts: WriteOpts): any
	local container, key = resolveContainer(tree, path, false)
	local arr = if container then container[key] else nil
	if type(arr) ~= "table" or #arr == 0 then
		return nil
	end
	local index = math.clamp(pos or #arr, 1, #arr)

	local pathKey = Util.pathKey(path)
	snapshotForTxn(tree, path, pathKey, arr)
	local item = table.remove(arr, index)

	emitOp(tree, { Kind = "Remove", Path = table.clone(path), Index = index }, schema, opts)
	fire(tree, pathKey, "OnRemove", item, index)
	fire(tree, pathKey, "Changed", arr, arr, index)
	fireAncestors(tree, path)
	return item
end

local function applyClear(tree: Tree, path: { string | number }, schema: SchemaNode?, opts: WriteOpts)
	local container, key = resolveContainer(tree, path, false)
	local value = if container then container[key] else nil
	if type(value) ~= "table" then
		return
	end
	local pathKey = Util.pathKey(path)
	snapshotForTxn(tree, path, pathKey, value)
	table.clear(value)

	emitOp(tree, { Kind = "Clear", Path = table.clone(path) }, schema, opts)
	-- Bulk semantics: parent Changed fires once; per-entry events don't.
	fire(tree, pathKey, "Changed", value, value)
	fireAncestors(tree, path)
end

-- Applies an op received over the wire (client mirror / gift delivery replays).
function Tree.ApplyOp(self: Tree, op: Op)
	if self.Dead then
		return
	end
	-- Resolve the exact schema node (dynamic tail resolves to any-nodes).
	local baseSchema, dynStart = Template.Resolve(self.Compiled, op.Path)
	local exactSchema: SchemaNode? = baseSchema
	for i = dynStart, #op.Path do
		exactSchema = if exactSchema then Template.ChildSchema(exactSchema, op.Path[i]) else nil
	end
	local opts: WriteOpts = { FromRemote = true, NoValidate = true }
	if op.Kind == "Set" or op.Kind == "Init" then
		applySet(self, op.Path, exactSchema, op.Value, opts)
	elseif op.Kind == "Insert" then
		applyInsert(self, op.Path, exactSchema, op.Value, op.Index, opts)
	elseif op.Kind == "Remove" then
		applyArrayRemove(self, op.Path, exactSchema, op.Index, opts)
	elseif op.Kind == "Clear" then
		applyClear(self, op.Path, exactSchema, opts)
	end
end

-- Runs `apply` with per-op fires suppressed, then fires Changed once per
-- observed path the mutation actually changed. A whole-container Set fires
-- Changed only on the container and its ancestors, never its descendants, so a
-- nested Observe/Changed registered BEFORE the mutation would miss its value.
-- Used by the initial snapshot (ReplayInit) and edit-mode Mock, both of which
-- write whole roots. Cost is O(listeners) -- independent of player-data size.
function Tree.ReplayFire(self: Tree, apply: () -> ())
	if self.Dead then
		apply()
		return
	end
	-- Snapshot the pre-apply value of every observed path.
	local olds: { [string]: any } = {}
	for pathKey, path in self._paths do
		local byEvent = self._listeners[pathKey]
		if byEvent and byEvent.Changed then
			olds[pathKey] = readValue(self, path)
		end
	end
	self._replaying = true
	local ok, err = pcall(apply)
	self._replaying = false -- always cleared, even if `apply` threw
	if not ok then
		error(err, 0)
	end
	-- Collect the changed observed paths first (a fired listener may add or
	-- remove listeners), then fire. leafEquals is false for tables/buffers, so
	-- container observers always fire (matching a live whole-container Set);
	-- scalar leaves fire only on a real change.
	local pending: { { Key: string, New: any, Old: any } } = {}
	for pathKey, path in self._paths do
		local byEvent = self._listeners[pathKey]
		if byEvent and byEvent.Changed then
			local current = readValue(self, path)
			if not Util.leafEquals(current, olds[pathKey]) then
				table.insert(pending, { Key = pathKey, New = current, Old = olds[pathKey] })
			end
		end
	end
	for _, entry in pending do
		fire(self, entry.Key, "Changed", entry.New, entry.Old)
	end
end

-- Applies the initial snapshot (the caller has already reset the mirror to
-- defaults), firing nested observers registered before Init.
function Tree.ReplayInit(self: Tree, ops: { Op })
	self:ReplayFire(function()
		for _, op in ops do
			self:ApplyOp(op)
		end
	end)
end

-- Batch / Transaction ------------------------------------------------

function Tree.RunBatch(self: Tree, fn: () -> ())
	assertAlive(self)
	self._batchDepth += 1
	local ok, err = pcall(fn :: any)
	self._batchDepth -= 1
	if self._batchDepth == 0 and self.Params.OnBatchEnd then
		self.Params.OnBatchEnd()
	end
	if not ok then
		error(err, 0)
	end
end

function Tree.RunTransaction(self: Tree, fn: () -> ()): (boolean, string?)
	assertAlive(self)
	if self._txn then
		error("Scribe: transactions do not nest", 2)
	end
	self._txn = { Snapshots = {}, Ops = {}, Created = {} }
	self._batchDepth += 1
	local ok, err = xpcall(fn :: any, function(e)
		return debug.traceback(tostring(e), 2)
	end)
	local txn = self._txn :: any
	self._txn = nil
	self._batchDepth -= 1

	if ok then
		local onOp = self.Params.OnOp
		if onOp then
			for _, entry in txn.Ops :: { { Op: Op, Schema: SchemaNode? } } do
				onOp(entry.Op, entry.Schema)
			end
		end
		if self._batchDepth == 0 and self.Params.OnBatchEnd then
			self.Params.OnBatchEnd()
		end
		return true, nil
	end

	-- Roll back every touched field to its pre-transaction value, suppressing
	-- replication ops (listeners fire with the restored values). Snapshots are
	-- disjoint, so restore order does not matter.
	for _, snapshot in txn.Snapshots :: { [string]: { Path: { string | number }, Value: any } } do
		local baseSchema, dynStart = Template.Resolve(self.Compiled, snapshot.Path)
		local exactSchema: SchemaNode? = baseSchema
		for i = dynStart, #snapshot.Path do
			exactSchema = if exactSchema then Template.ChildSchema(exactSchema, snapshot.Path[i]) else nil
		end
		applySet(self, snapshot.Path, exactSchema, snapshot.Value, {
			NoOp = true,
			NoValidate = true,
		})
	end
	-- Prune containers materialized during the transaction (deepest first) so no
	-- phantom empty tables survive a rollback. A created path covered by a
	-- snapshot (exact or ancestor) is authoritative pre-txn state that the
	-- restore just recreated — never prune those; only prune true phantoms.
	local created = txn.Created :: { { string | number } }
	local snapshots = txn.Snapshots :: { [string]: { Path: { string | number }, Value: any } }
	local function coveredBySnapshot(createdPath: { string | number }): boolean
		for _, snap in snapshots do
			if #snap.Path == #createdPath then
				local same = true
				for i = 1, #snap.Path do
					if snap.Path[i] ~= createdPath[i] then
						same = false
						break
					end
				end
				if same then
					return true
				end
			elseif pathIsStrictAncestor(snap.Path, createdPath) then
				return true
			end
		end
		return false
	end
	for i = #created, 1, -1 do
		if not coveredBySnapshot(created[i]) then
			local container, key = resolveContainer(self, created[i], false)
			if container ~= nil and type(container[key]) == "table" and next(container[key]) == nil then
				container[key] = nil
			end
		end
	end
	return false, tostring(err)
end

function Tree.Destroy(self: Tree)
	self.Dead = true
	table.clear(self._listeners)
	table.clear(self._accessors)
end

-- Accessor methods -----------------------------------------------------------------

--[=[
	@class Value

	A node in the accessor tree: what you get from indexing your data, e.g.
	`Data[player].Coins` or `data.Inventory.Sword`. Every field is a `Value`;
	container fields also expose their children as `Value`s.

	The method set is contextual: **all** fields have `Get`/`Set`/`Update`/
	`Observe`/`Changed`; number fields add `Increment`/`Decrement`; boolean fields
	add `Toggle`; array fields add `Insert`/`Remove`/…; dictionary fields add
	`Remove`/`Count`/…; `Scribe.Timed` fields add `SetTimed`/`ExtendTimed`/`Active`.
	On the client, `Set` writes are local-only (optimistic UI).

	:::caution Reserved names
	Because method names live on the node, a template field named `Get`, `Set`,
	`Count`, `Remove`, etc. is unreachable through the typed accessor. Scribe
	warns about this in Studio.
	:::
]=]

--[=[
	@function Get
	@within Value
	@tag Core
	@return T
	Returns a copy of the field's current value.
]=]

--[=[
	@function Set
	@within Value
	@tag Core
	@param value T
	@param replicate boolean?
	@return T
	Writes a new value (validated and clamped per the declarator). Fires
	`Changed`, replicates, and returns the stored value. Pass `replicate = false`
	to keep the write server-only.
]=]

--[=[
	@function Update
	@within Value
	@tag Core
	@param transform (current: T) -> T
	@param replicate boolean?
	@return T
	Reads the current value, passes it to `transform`, and writes the result:
	a convenient read-modify-write.
]=]

--[=[
	@function Clone
	@within Value
	@tag Core
	@return T
	A deep copy of the value (for tables/buffers you intend to mutate locally).
]=]

--[=[
	@function Default
	@within Value
	@tag Core
	@return T
	The field's declared default (a deep copy for tables/buffers, the real
	datatype for datatype fields). Read-only schema metadata, so it works on the
	client and server and before data loads. Handy for "reset to default" flows
	and diffing against the current value.
]=]

--[=[
	@function Observe
	@within Value
	@tag Core
	@param callback (value: T) -> ()
	@return () -> ()
	Calls `callback` immediately with the current value, then again on every
	change. Returns a disconnect function. The go-to for driving UI.
]=]

--[=[
	@function Changed
	@within Value
	@tag Core
	@param callback (new: T, old: T) -> ()
	@return () -> ()
	Like `Observe` but fires only on change (no initial call), with both the new
	and old values. Returns a disconnect function.
]=]

--[=[
	@function Increment
	@within Value
	@tag Numbers
	@param amount number
	@param meta EconomyMeta?
	@return number
	Number fields only. Adds `amount` and returns the new value. Pass `false`
	instead of `meta` to keep the write server-only.

	Pass an [EconomyMeta](../economy.md) table to auto-emit an economy event
	(`AnalyticsService:LogEconomyEvent`): the currency is this field's name, the
	ending balance is the post-change value, and `TransactionType`, `ItemSku`,
	and per-currency custom `Fields` come from the table. Increment defaults the
	flow to `Source`.

	```lua
	Data[player].Coins.Increment(50, {
	    TransactionType = Enum.AnalyticsEconomyTransactionType.Gameplay,
	    ItemSku = "quest_daily_01",
	    Fields = { Location = "Lobby" },
	})
	```
]=]

--[=[
	@function Decrement
	@within Value
	@tag Numbers
	@param amount number
	@param meta EconomyMeta?
	@return number
	Number fields only. Subtracts `amount` and returns the new value. Like
	[Value.Increment] but the economy flow defaults to `Sink`. See the
	[Economy Analytics](../economy.md) guide.
]=]

--[=[
	@function Min
	@within Value
	@tag Numbers
	@return number?
	Number fields only. The declared minimum (`Scribe.Int(0, { Min = 0 })`), or
	`nil` if unbounded. Read-only metadata from the shared schema, so it works on
	both the client and the server, and even before data has loaded. Handy for
	driving slider ranges or validation off the single source of truth.
]=]

--[=[
	@function Max
	@within Value
	@tag Numbers
	@return number?
	Number fields only. The declared maximum, or `nil` if unbounded. See
	[Value.Min].
]=]

--[=[
	@function Toggle
	@within Value
	@tag Booleans
	@param replicate boolean?
	@return boolean
	Boolean fields only. Flips the value and returns the new one.
]=]

--[=[
	@function Insert
	@within Value
	@tag Arrays & Dictionaries
	@param value T
	@param index number?
	@param replicate boolean?
	Array fields only. Inserts `value` (at `index`, or appended).
]=]

--[=[
	@function Remove
	@within Value
	@tag Arrays & Dictionaries
	@param index number?
	@param replicate boolean?
	@return T?
	Array fields only. Removes and returns the element at `index` (or the last),
	or `nil` if empty. (On a dictionary field, `Remove(key)` deletes that key.)
]=]

--[=[
	@function RemoveValue
	@within Value
	@tag Arrays & Dictionaries
	@param value T
	@param replicate boolean?
	@return (T?, number?)
	Array fields only. Removes the first element equal to `value`, returning it
	and its former index.
]=]

--[=[
	@function Find
	@within Value
	@tag Arrays & Dictionaries
	@param value T
	@return number?
	Array fields only. The index of the first matching element, or `nil`.
]=]

--[=[
	@function Has
	@within Value
	@tag Arrays & Dictionaries
	@param value T
	@return boolean
	Array fields only. Whether `value` is present.
]=]

--[=[
	@function OnInsert
	@within Value
	@tag Arrays & Dictionaries
	@param callback (value: T, index: number) -> ()
	@return () -> ()
	Array fields only. Fires when an element is inserted, with the value and the
	index it landed at. Returns a disconnect function.
]=]

--[=[
	@function OnRemove
	@within Value
	@tag Arrays & Dictionaries
	@param callback (value: T, index: number) -> ()
	@return () -> ()
	Array fields only. Fires when an element is removed, with the removed value
	and its former index. Returns a disconnect function.
]=]

--[=[
	@function OnKeyAdded
	@within Value
	@tag Arrays & Dictionaries
	@param callback (key: K, value: T) -> ()
	@return () -> ()
	Dictionary fields only. Fires when a key is added, with the key and its new
	value. Returns a disconnect function.
]=]

--[=[
	@function OnKeyRemoved
	@within Value
	@tag Arrays & Dictionaries
	@param callback (key: K, value: T) -> ()
	@return () -> ()
	Dictionary fields only. Fires when a key is removed, with the key and its
	former value. Returns a disconnect function.
]=]

--[=[
	@function Count
	@within Value
	@tag Arrays & Dictionaries
	@return number
	Array/dictionary fields. The number of elements/keys.
]=]

--[=[
	@function Clear
	@within Value
	@tag Arrays & Dictionaries
	@param replicate boolean?
	Array/dictionary fields. Removes all entries.
]=]

--[=[
	@function SetTimed
	@within Value
	@tag Timed
	@param value T
	@param seconds number
	@param replicate boolean?
	`Scribe.Timed` fields only. Sets `value` for `seconds`, after which it
	auto-clears back to the declared default (firing `Changed`).
]=]

--[=[
	@function ExtendTimed
	@within Value
	@tag Timed
	@param seconds number
	@param replicate boolean?
	`Scribe.Timed` fields only. Adds time to a running timer.
]=]

--[=[
	@function Active
	@within Value
	@tag Timed
	@return (boolean, number?)
	`Scribe.Timed` fields only. Whether the timer is active, and the seconds
	remaining.
]=]

type Accessor = any

local function accessorSchema(accessor: Accessor): SchemaNode?
	return rawget(accessor, "_schema") :: any
end

local function accessorTree(accessor: Accessor): Tree
	return rawget(accessor, "_tree") :: any
end

local function accessorPath(accessor: Accessor): { string | number }
	return rawget(accessor, "_path") :: any
end

local function accessorKey(accessor: Accessor): string
	return rawget(accessor, "_key") :: any
end

local function parseIncrementArgs(tagsOrReplicate: any): ({ [string]: any }?, boolean?)
	if type(tagsOrReplicate) == "boolean" then
		return nil, tagsOrReplicate
	elseif type(tagsOrReplicate) == "table" then
		return tagsOrReplicate, nil
	end
	return nil, nil
end

-- Declared datatype fields store a packed buffer; the accessor converts at
-- the boundary so callers only ever see the real datatype.
local function unpackIfDatatype(schema: SchemaNode?, value: any): any
	if schema and schema.ValueType == "datatype" and type(value) == "buffer" then
		return Datatypes.Unpack(schema.Datatype :: string, value)
	end
	return value
end

local METHOD_FACTORIES: { [string]: (Accessor) -> any } = {}

METHOD_FACTORIES.Get = function(accessor)
	return function()
		local tree = accessorTree(accessor)
		assertAlive(tree)
		return unpackIfDatatype(accessorSchema(accessor), readValue(tree, accessorPath(accessor)))
	end
end

METHOD_FACTORIES.Set = function(accessor)
	return function(value: any, replicate: boolean?)
		local tree = accessorTree(accessor)
		assertAlive(tree)
		local schema = accessorSchema(accessor)
		local stored = applySet(tree, accessorPath(accessor), schema, value, { Replicate = replicate })
		return unpackIfDatatype(schema, stored)
	end
end

METHOD_FACTORIES.Update = function(accessor)
	return function(fn: (any) -> any, replicate: boolean?)
		local tree = accessorTree(accessor)
		assertAlive(tree)
		local schema = accessorSchema(accessor)
		local current = unpackIfDatatype(schema, readValue(tree, accessorPath(accessor)))
		local stored = applySet(tree, accessorPath(accessor), schema, fn(current), { Replicate = replicate })
		return unpackIfDatatype(schema, stored)
	end
end

METHOD_FACTORIES.Clone = function(accessor)
	return function()
		local tree = accessorTree(accessor)
		assertAlive(tree)
		local schema = accessorSchema(accessor)
		if schema and schema.ValueType == "datatype" then
			return unpackIfDatatype(schema, readValue(tree, accessorPath(accessor)))
		end
		return Util.deepClone(readValue(tree, accessorPath(accessor)))
	end
end

local function incrementImpl(accessor: Accessor, delta: number, tagsOrReplicate: any, defaultFlow: string): number
	local tree = accessorTree(accessor)
	assertAlive(tree)
	local path = accessorPath(accessor)
	if type(delta) ~= "number" or delta ~= delta then
		validationError(path, "Increment delta must be a number")
	end
	local current = readValue(tree, path)
	if type(current) ~= "number" then
		validationError(path, `Increment on non-number value ({typeof(current)})`)
	end
	local tags, replicate = parseIncrementArgs(tagsOrReplicate)
	local newValue = applySet(tree, path, accessorSchema(accessor), current + delta, { Replicate = replicate }) :: number
	if tags and tree.Params.OnEconomy then
		local applied = table.clone(tags)
		if applied.Flow == nil then
			applied.Flow = defaultFlow
		end
		tree.Params.OnEconomy(path, delta, newValue, applied)
	end
	return newValue
end

METHOD_FACTORIES.Increment = function(accessor)
	return function(delta: number, tagsOrReplicate: any?)
		return incrementImpl(accessor, delta, tagsOrReplicate, "Source")
	end
end

METHOD_FACTORIES.Decrement = function(accessor)
	return function(delta: number, tagsOrReplicate: any?)
		local tree = accessorTree(accessor)
		if tree.Params.DevMode and type(delta) == "number" and delta < 0 then
			local warnFn = tree.Params.LogWarn
			if warnFn then
				warnFn(`Decrement called with a negative delta at "{Util.pathString(accessorPath(accessor))}" — likely a sign error`)
			end
		end
		return incrementImpl(accessor, -delta, tagsOrReplicate, "Sink")
	end
end

-- Min/Max read the declarator's bounds off the (static) schema, so they work on
-- the server and client alike, and even before data has loaded.
METHOD_FACTORIES.Min = function(accessor)
	return function(): number?
		local schema = accessorSchema(accessor)
		return if schema then schema.Min else nil
	end
end

METHOD_FACTORIES.Max = function(accessor)
	return function(): number?
		local schema = accessorSchema(accessor)
		return if schema then schema.Max else nil
	end
end

-- The declarator's default, straight off the (static) schema: a fresh datatype
-- for packed datatype fields, a deep copy for tables/buffers, the value itself
-- for scalars. Works on server and client and before data has loaded.
METHOD_FACTORIES.Default = function(accessor)
	return function(): any
		local schema = accessorSchema(accessor)
		if schema == nil then
			return nil
		end
		if schema.ValueType == "datatype" then
			return unpackIfDatatype(schema, schema.Default)
		end
		return Util.deepClone(schema.Default)
	end
end

METHOD_FACTORIES.Toggle = function(accessor)
	return function(replicate: boolean?)
		local tree = accessorTree(accessor)
		assertAlive(tree)
		local path = accessorPath(accessor)
		local current = readValue(tree, path)
		if type(current) ~= "boolean" then
			validationError(path, `Toggle on non-boolean value ({typeof(current)})`)
		end
		return applySet(tree, path, accessorSchema(accessor), not current, { Replicate = replicate })
	end
end

METHOD_FACTORIES.Changed = function(accessor)
	return function(fn: (any, any, any?) -> ())
		local tree = accessorTree(accessor)
		local schema = accessorSchema(accessor)
		if schema and schema.ValueType == "datatype" then
			local inner = fn
			fn = function(newValue, oldValue, key)
				inner(unpackIfDatatype(schema, newValue), unpackIfDatatype(schema, oldValue), key)
			end
		end
		return connect(tree, accessorPath(accessor), "Changed", fn)
	end
end

METHOD_FACTORIES.Observe = function(accessor)
	return function(fn: (any) -> ())
		local tree = accessorTree(accessor)
		assertAlive(tree)
		local schema = accessorSchema(accessor)
		local disconnect = connect(tree, accessorPath(accessor), "Changed", function(newValue)
			fn(unpackIfDatatype(schema, newValue))
		end)
		local ok, err = xpcall(function()
			fn(unpackIfDatatype(schema, readValue(tree, accessorPath(accessor))))
		end, function(e)
			return debug.traceback(tostring(e), 2)
		end)
		if not ok then
			tree.Params.LogError(`listener error at "{accessorKey(accessor)}" (Observe): {err}`)
		end
		return disconnect
	end
end

METHOD_FACTORIES.Insert = function(accessor)
	return function(item: any, pos: number?, replicate: boolean?)
		local tree = accessorTree(accessor)
		assertAlive(tree)
		applyInsert(tree, accessorPath(accessor), accessorSchema(accessor), item, pos, { Replicate = replicate })
	end
end

METHOD_FACTORIES.Remove = function(accessor)
	return function(posOrKey: any, replicate: boolean?)
		local tree = accessorTree(accessor)
		assertAlive(tree)
		if type(posOrKey) == "string" then
			-- Dictionary removal: sugar for Set(nil) with a useful return.
			local path = table.clone(accessorPath(accessor))
			table.insert(path, posOrKey)
			local schema = accessorSchema(accessor)
			local childSchema = if schema then Template.ChildSchema(schema, posOrKey) else nil
			local container, key = resolveContainer(tree, path, false)
			local old = if container then container[key] else nil
			if old ~= nil then
				applySet(tree, path, childSchema, nil, { Replicate = replicate })
			end
			return old
		end
		return applyArrayRemove(tree, accessorPath(accessor), accessorSchema(accessor), posOrKey :: number?, { Replicate = replicate })
	end
end

METHOD_FACTORIES.RemoveValue = function(accessor)
	return function(item: any, replicate: boolean?): (any, number?)
		local tree = accessorTree(accessor)
		assertAlive(tree)
		local arr = readValue(tree, accessorPath(accessor))
		if type(arr) ~= "table" then
			return nil, nil
		end
		local index = table.find(arr, item)
		if index == nil then
			return nil, nil
		end
		local removed = applyArrayRemove(tree, accessorPath(accessor), accessorSchema(accessor), index, { Replicate = replicate })
		return removed, index
	end
end

METHOD_FACTORIES.Find = function(accessor)
	return function(item: any): number?
		local tree = accessorTree(accessor)
		assertAlive(tree)
		local arr = readValue(tree, accessorPath(accessor))
		if type(arr) ~= "table" then
			return nil
		end
		return table.find(arr, item)
	end
end

METHOD_FACTORIES.Has = function(accessor)
	return function(item: any)
		local tree = accessorTree(accessor)
		assertAlive(tree)
		local arr = readValue(tree, accessorPath(accessor))
		return type(arr) == "table" and table.find(arr, item) ~= nil
	end
end

METHOD_FACTORIES.Clear = function(accessor)
	return function(replicate: boolean?)
		local tree = accessorTree(accessor)
		assertAlive(tree)
		applyClear(tree, accessorPath(accessor), accessorSchema(accessor), { Replicate = replicate })
	end
end

METHOD_FACTORIES.Count = function(accessor)
	return function()
		local tree = accessorTree(accessor)
		assertAlive(tree)
		local value = readValue(tree, accessorPath(accessor))
		if type(value) ~= "table" then
			return 0
		end
		return Util.count(value)
	end
end

for _, event in { "OnInsert", "OnRemove", "OnKeyAdded", "OnKeyRemoved" } do
	METHOD_FACTORIES[event] = function(accessor)
		return function(fn: (...any) -> ())
			local tree = accessorTree(accessor)
			return connect(tree, accessorPath(accessor), event, fn)
		end
	end
end

local function timedHooks(accessor: Accessor): TimedHooks
	local tree = accessorTree(accessor)
	local schema = accessorSchema(accessor)
	if not schema or not schema.Timed then
		error(`Scribe: "{Util.pathString(accessorPath(accessor))}" is not a Scribe.Timed field`, 3)
	end
	local hooks = tree.Params.TimedHooks
	if not hooks then
		error("Scribe: timed fields are managed on the server", 3)
	end
	return hooks
end

METHOD_FACTORIES.SetTimed = function(accessor)
	return function(value: any, seconds: number, replicate: boolean?)
		local tree = accessorTree(accessor)
		assertAlive(tree)
		timedHooks(accessor).SetTimed(accessor, value, seconds, replicate)
	end
end

METHOD_FACTORIES.ExtendTimed = function(accessor)
	return function(seconds: number, replicate: boolean?)
		local tree = accessorTree(accessor)
		assertAlive(tree)
		timedHooks(accessor).ExtendTimed(accessor, seconds, replicate)
	end
end

METHOD_FACTORIES.Active = function(accessor)
	return function()
		local tree = accessorTree(accessor)
		assertAlive(tree)
		return timedHooks(accessor).Active(accessor)
	end
end

-- Accessor metatable -----------------------------------------------------------------

local function accessorIndex(accessor: Accessor, key: any): any
	local factory = METHOD_FACTORIES[key]
	if factory then
		local method = factory(accessor)
		rawset(accessor, key, method)
		return method
	end

	local tree = accessorTree(accessor)
	assertAlive(tree)
	if type(key) ~= "string" and type(key) ~= "number" then
		error(`Scribe: invalid child key of type {typeof(key)}`, 2)
	end
	-- The pathKey separator (char 31) would let a crafted dynamic key alias a
	-- distinct path — corrupting coalescing, listeners, and txn rollback.
	if type(key) == "string" and string.find(key, "\31", 1, true) then
		error("Scribe: dictionary keys may not contain control character \\31", 2)
	end

	local children = rawget(accessor, "_children") :: { [any]: any }
	local child = children[key]
	if child == nil then
		local schema = accessorSchema(accessor)
		if schema and schema.Kind == "leaf" then
			error(`Scribe: "{Util.pathString(accessorPath(accessor))}" is a leaf value and has no children`, 2)
		end
		local path = table.clone(accessorPath(accessor))
		table.insert(path, key)
		local childSchema = if schema then Template.ChildSchema(schema, key) else nil
		child = newAccessor(tree, path, childSchema)
		children[key] = child
	end
	return child
end

-- Callable shorthand: node() gets, node(value) sets, node(fn) updates.
local function accessorCall(accessor: Accessor, ...: any): any
	local n = select("#", ...)
	if n == 0 then
		return accessor.Get()
	end
	local first = ...
	if type(first) == "function" then
		return accessor.Update(first, select(2, ...))
	end
	return accessor.Set(...)
end

ACCESSOR_MT = {
	__index = accessorIndex,
	__call = accessorCall,
}

Node.METHOD_NAMES = {} :: { [string]: boolean }
for name in METHOD_FACTORIES do
	Node.METHOD_NAMES[name] = true
end

return Node
