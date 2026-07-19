--!strict
-- Buffer wire format. Scribe owns (de)serialization; transports carry
-- opaque buffers. Both sides derive an identical schema from the shared
-- template, so paths intern to u16 field IDs and values pack by declared type.
-- Every value carries a 1-byte mode prefix (schema-typed vs generic) so legacy
-- or dynamically-shaped data can never corrupt a frame.

local Template = require(script.Parent.Template)

type SchemaNode = Template.SchemaNode
type Compiled = Template.Compiled

local Wire = {}

Wire.PROTOCOL_VERSION = 1

-- Max arguments a command frame carries. Shared so the client's encode cap and the
-- server's decode guard cannot drift (a client-side clamp would otherwise silently
-- drop the extras before the server ever saw them).
Wire.MAX_COMMAND_ARGS = 16

Wire.Frames = {
	Hello = 1,
	Init = 2,
	Diff = 3,
	Command = 4,
	CommandReply = 5,
	Status = 6,
	SharedInit = 7,
	SharedDiff = 8,
	SharedGone = 9,
	Leaderboard = 10,
}

local KIND_TO_ID: { [string]: number } = { Set = 1, Insert = 2, Remove = 3, Clear = 4 }
local ID_TO_KIND: { [number]: string } = { "Set", "Insert", "Remove", "Clear" }

local FLAG_VALUE = 0x10
local FLAG_INDEX = 0x20

-- Writer ----------------------------------------------------------------------

export type Writer = {
	buf: buffer,
	len: number,
	cap: number,
}

function Wire.NewWriter(capacity: number?): Writer
	local cap = capacity or 128
	return { buf = buffer.create(cap), len = 0, cap = cap }
end

local function ensure(w: Writer, n: number)
	if w.len + n <= w.cap then
		return
	end
	local newCap = math.max(w.cap * 2, w.len + n)
	local newBuf = buffer.create(newCap)
	buffer.copy(newBuf, 0, w.buf, 0, w.len)
	w.buf = newBuf
	w.cap = newCap
end

local function wu8(w: Writer, v: number)
	ensure(w, 1)
	buffer.writeu8(w.buf, w.len, v)
	w.len += 1
end

local function wu16(w: Writer, v: number)
	ensure(w, 2)
	buffer.writeu16(w.buf, w.len, v)
	w.len += 2
end

local function wu32(w: Writer, v: number)
	ensure(w, 4)
	buffer.writeu32(w.buf, w.len, v)
	w.len += 4
end

local function wf64(w: Writer, v: number)
	ensure(w, 8)
	buffer.writef64(w.buf, w.len, v)
	w.len += 8
end

-- Unsigned LEB128; arithmetic (not bit32) so values up to 2^53 round-trip.
local function wvarint(w: Writer, v: number)
	v = math.floor(v)
	while v >= 128 do
		wu8(w, v % 128 + 128)
		v = math.floor(v / 128)
	end
	wu8(w, v)
end

local function wzigzag(w: Writer, v: number)
	wvarint(w, if v >= 0 then v * 2 else -v * 2 - 1)
end

local function wstr(w: Writer, s: string)
	wvarint(w, #s)
	ensure(w, #s)
	buffer.writestring(w.buf, w.len, s)
	w.len += #s
end

local function wbuf(w: Writer, value: buffer)
	local length = buffer.len(value)
	wvarint(w, length)
	ensure(w, length)
	buffer.copy(w.buf, w.len, value)
	w.len += length
end

function Wire.Finish(w: Writer): buffer
	local out = buffer.create(w.len)
	buffer.copy(out, 0, w.buf, 0, w.len)
	return out
end

Wire.U8 = wu8
Wire.U16 = wu16
Wire.U32 = wu32
Wire.F64 = wf64
Wire.Varint = wvarint
Wire.Str = wstr

-- Reader ----------------------------------------------------------------------

export type Reader = {
	buf: buffer,
	pos: number,
	size: number,
}

function Wire.NewReader(buf: buffer): Reader
	return { buf = buf, pos = 0, size = buffer.len(buf) }
end

local function ru8(r: Reader): number
	local v = buffer.readu8(r.buf, r.pos)
	r.pos += 1
	return v
end

local function ru16(r: Reader): number
	local v = buffer.readu16(r.buf, r.pos)
	r.pos += 2
	return v
end

local function ru32(r: Reader): number
	local v = buffer.readu32(r.buf, r.pos)
	r.pos += 4
	return v
end

local function rf64(r: Reader): number
	local v = buffer.readf64(r.buf, r.pos)
	r.pos += 8
	return v
end

local function rvarint(r: Reader): number
	local result = 0
	local multiplier = 1
	-- 10 groups = 70 bits. canSchemaEncode caps schema-mode ints at 2^52
	-- (larger values take the generic f64 path), so a valid varint never
	-- exceeds ~8 groups; the extra headroom just bounds a malicious varint.
	for _ = 1, 10 do
		local byte = ru8(r)
		result += (byte % 128) * multiplier
		if byte < 128 then
			return result
		end
		multiplier *= 128
	end
	error("Scribe: varint too long")
end

local function rzigzag(r: Reader): number
	local v = rvarint(r)
	if v % 2 == 0 then
		return v / 2
	end
	return -(v + 1) / 2
end

local function rstr(r: Reader): string
	local len = rvarint(r)
	if r.pos + len > r.size then
		error("Scribe: string overruns buffer")
	end
	local s = buffer.readstring(r.buf, r.pos, len)
	r.pos += len
	return s
end

local function rbuf(r: Reader): buffer
	local length = rvarint(r)
	if r.pos + length > r.size then
		error("Scribe: buffer overruns frame")
	end
	local out = buffer.create(length)
	buffer.copy(out, 0, r.buf, r.pos, length)
	r.pos += length
	return out
end

Wire.RU8 = ru8
Wire.RU16 = ru16
Wire.RU32 = ru32
Wire.RF64 = rf64
Wire.RVarint = rvarint
Wire.RStr = rstr

function Wire.Remaining(r: Reader): number
	return r.size - r.pos
end

-- Generic tagged value codec ---------------------------------------------------

local TAG_NIL, TAG_FALSE, TAG_TRUE, TAG_NUMBER, TAG_STRING, TAG_TABLE, TAG_BUFFER = 0, 1, 2, 3, 4, 5, 6

local function encodeGeneric(w: Writer, value: any, depth: number)
	if depth > 24 then
		error("Scribe: value too deep to serialize")
	end
	local t = type(value)
	if value == nil then
		wu8(w, TAG_NIL)
	elseif t == "boolean" then
		wu8(w, if value then TAG_TRUE else TAG_FALSE)
	elseif t == "number" then
		wu8(w, TAG_NUMBER)
		wf64(w, value)
	elseif t == "string" then
		wu8(w, TAG_STRING)
		wstr(w, value)
	elseif t == "buffer" then
		wu8(w, TAG_BUFFER)
		wbuf(w, value)
	elseif t == "table" then
		wu8(w, TAG_TABLE)
		-- Contiguous array part, then hash part.
		local arrayLen = 0
		while (value :: any)[arrayLen + 1] ~= nil do
			arrayLen += 1
		end
		wvarint(w, arrayLen)
		for i = 1, arrayLen do
			encodeGeneric(w, value[i], depth + 1)
		end
		local hashCount = 0
		for k in value do
			if not (type(k) == "number" and k % 1 == 0 and k >= 1 and k <= arrayLen) then
				hashCount += 1
			end
		end
		wvarint(w, hashCount)
		for k, v in value do
			if not (type(k) == "number" and k % 1 == 0 and k >= 1 and k <= arrayLen) then
				encodeGeneric(w, k, depth + 1)
				encodeGeneric(w, v, depth + 1)
			end
		end
	else
		error(`Scribe: cannot serialize value of type "{t}"`)
	end
end

local function decodeGeneric(r: Reader, depth: number): any
	if depth > 24 then
		error("Scribe: value too deep to deserialize")
	end
	local tag = ru8(r)
	if tag == TAG_NIL then
		return nil
	elseif tag == TAG_FALSE then
		return false
	elseif tag == TAG_TRUE then
		return true
	elseif tag == TAG_NUMBER then
		return rf64(r)
	elseif tag == TAG_STRING then
		return rstr(r)
	elseif tag == TAG_BUFFER then
		return rbuf(r)
	elseif tag == TAG_TABLE then
		local out = {}
		local arrayLen = rvarint(r)
		for i = 1, arrayLen do
			out[i] = decodeGeneric(r, depth + 1)
		end
		local hashCount = rvarint(r)
		for _ = 1, hashCount do
			local k = decodeGeneric(r, depth + 1)
			local v = decodeGeneric(r, depth + 1)
			if k ~= nil and k == k then
				out[k] = v
			end
		end
		return out
	end
	error(`Scribe: unknown generic tag {tag}`)
end

function Wire.EncodeGeneric(w: Writer, value: any)
	encodeGeneric(w, value, 0)
end

function Wire.DecodeGeneric(r: Reader): any
	return decodeGeneric(r, 0)
end

-- Schema-typed value codec -------------------------------------------------------

local MODE_SCHEMA, MODE_GENERIC = 0, 1

local function intWidth(node: SchemaNode): number?
	if node.Min ~= nil and node.Max ~= nil then
		local range = node.Max - node.Min
		if range < 256 then
			return 1
		elseif range < 65536 then
			return 2
		elseif range < 4294967296 then
			return 4
		end
	end
	return nil
end

local function canSchemaEncode(node: SchemaNode, value: any): boolean
	local vt = node.ValueType
	if vt == "boolean" then
		return type(value) == "boolean"
	elseif vt == "int" then
		if type(value) ~= "number" or value % 1 ~= 0 then
			return false
		end
		-- Beyond 2^52 the varint/zigzag arithmetic loses precision (and can
		-- flip signs or emit widths the reader rejects); fall back to the
		-- generic f64 path, which round-trips any finite double exactly.
		if value > 0x10000000000000 or value < -0x10000000000000 then
			return false
		end
		if node.Min ~= nil and node.Max ~= nil then
			return value >= node.Min and value <= node.Max
		end
		if node.Min ~= nil and node.Min >= 0 then
			return value >= 0
		end
		return true
	elseif vt == "number" then
		return type(value) == "number"
	elseif vt == "enum" then
		return type(value) == "string" and node.MemberIndex ~= nil and node.MemberIndex[value] ~= nil
	elseif vt == "string" then
		return type(value) == "string"
	elseif vt == "buffer" or vt == "datatype" then
		-- Datatype fields store (and travel as) their packed buffer form.
		return type(value) == "buffer"
	elseif vt == "table" then
		return type(value) == "table"
	end
	return false
end

local TAG_KEY_STATIC, TAG_KEY_STRING, TAG_KEY_UINT, TAG_KEY_F64 = 0, 1, 2, 3

local function encodeValue(w: Writer, node: SchemaNode?, value: any, depth: number)
	if node == nil or not canSchemaEncode(node, value) then
		wu8(w, MODE_GENERIC)
		encodeGeneric(w, value, depth)
		return
	end
	wu8(w, MODE_SCHEMA)
	local vt = node.ValueType
	if vt == "boolean" then
		wu8(w, if value then 1 else 0)
	elseif vt == "int" then
		local width = intWidth(node)
		if width == 1 then
			wu8(w, value - (node.Min :: number))
		elseif width == 2 then
			wu16(w, value - (node.Min :: number))
		elseif width == 4 then
			wu32(w, value - (node.Min :: number))
		elseif node.Min ~= nil and node.Min >= 0 then
			wvarint(w, value)
		else
			wzigzag(w, value)
		end
	elseif vt == "number" then
		wf64(w, value)
	elseif vt == "enum" then
		wu8(w, (node.MemberIndex :: { [string]: number })[value])
	elseif vt == "string" then
		wstr(w, value)
	elseif vt == "buffer" or vt == "datatype" then
		wbuf(w, value)
	elseif vt == "table" then
		if depth > 24 then
			error("Scribe: value too deep to serialize")
		end
		local count = 0
		for _ in value do
			count += 1
		end
		wvarint(w, count)
		for k, v in value do
			local child: SchemaNode? = nil
			if type(k) == "string" and node.Children and node.Children[k] then
				child = node.Children[k]
				wu8(w, TAG_KEY_STATIC)
				wvarint(w, (node.ChildOrdinal :: { [string]: number })[k])
			elseif type(k) == "string" then
				child = Template.ChildSchema(node, k)
				wu8(w, TAG_KEY_STRING)
				wstr(w, k)
			elseif type(k) == "number" and k % 1 == 0 and k >= 0 then
				child = Template.ChildSchema(node, k)
				wu8(w, TAG_KEY_UINT)
				wvarint(w, k)
			else
				child = Template.ChildSchema(node, k)
				wu8(w, TAG_KEY_F64)
				wf64(w, k)
			end
			encodeValue(w, child, v, depth + 1)
		end
	end
end

local function decodeValue(r: Reader, node: SchemaNode?, depth: number): any
	local mode = ru8(r)
	if mode == MODE_GENERIC then
		return decodeGeneric(r, depth)
	end
	if mode ~= MODE_SCHEMA or node == nil then
		error("Scribe: malformed value mode")
	end
	local vt = node.ValueType
	if vt == "boolean" then
		return ru8(r) ~= 0
	elseif vt == "int" then
		local width = intWidth(node)
		if width == 1 then
			return ru8(r) + (node.Min :: number)
		elseif width == 2 then
			return ru16(r) + (node.Min :: number)
		elseif width == 4 then
			return ru32(r) + (node.Min :: number)
		elseif node.Min ~= nil and node.Min >= 0 then
			return rvarint(r)
		else
			return rzigzag(r)
		end
	elseif vt == "number" then
		return rf64(r)
	elseif vt == "enum" then
		local idx = ru8(r)
		local member = (node.Members :: { string })[idx + 1]
		if member == nil then
			error("Scribe: enum index out of range")
		end
		return member
	elseif vt == "string" then
		return rstr(r)
	elseif vt == "buffer" or vt == "datatype" then
		return rbuf(r)
	elseif vt == "table" then
		if depth > 24 then
			error("Scribe: value too deep to deserialize")
		end
		local out = {}
		local count = rvarint(r)
		for _ = 1, count do
			local tag = ru8(r)
			local key: any
			local child: SchemaNode? = nil
			if tag == TAG_KEY_STATIC then
				local ordinal = rvarint(r)
				local name = (node.ChildOrder :: { string })[ordinal]
				if name == nil then
					error("Scribe: bad child ordinal")
				end
				key = name
				child = (node.Children :: { [string]: SchemaNode })[name]
			elseif tag == TAG_KEY_STRING then
				key = rstr(r)
				child = Template.ChildSchema(node, key)
			elseif tag == TAG_KEY_UINT then
				key = rvarint(r)
				child = Template.ChildSchema(node, key)
			elseif tag == TAG_KEY_F64 then
				key = rf64(r)
				child = Template.ChildSchema(node, key)
			else
				error("Scribe: bad key tag")
			end
			local value = decodeValue(r, child, depth + 1)
			-- Skip a NaN key (only a crafted TAG_KEY_F64 can decode to one): Lua
			-- forbids t[NaN] and would throw, dropping the whole frame. Decode the
			-- value first to keep the reader in sync. Matches decodeGeneric.
			if key == key then
				out[key] = value
			end
		end
		return out
	end
	error(`Scribe: cannot decode schema value type "{vt}"`)
end

function Wire.EncodeValue(w: Writer, node: SchemaNode?, value: any)
	encodeValue(w, node, value, 0)
end

function Wire.DecodeValue(r: Reader, node: SchemaNode?): any
	return decodeValue(r, node, 0)
end

-- Path codec --------------------------------------------------------------------

-- Encodes a path as (deepest static field ID, dynamic tail). Returns the schema
-- node the full path resolves to (dynamic segments resolve to any-nodes).
function Wire.EncodePath(w: Writer, compiled: Compiled, path: { string | number }): SchemaNode?
	local node, dynStart = Template.Resolve(compiled, path)
	wvarint(w, node.Id :: number)
	local dynCount = #path - dynStart + 1
	-- The count travels as a u8; a path deeper than this would silently wrap
	-- and desync the whole frame. Writes are capped at MAX_PATH_DYN_SEGMENTS
	-- up front (Node.validateWrite), so this only guards against a bug.
	if dynCount > 255 then
		error(`Scribe: path has too many dynamic segments ({dynCount})`)
	end
	wu8(w, dynCount)
	local target: SchemaNode? = node
	for i = dynStart, #path do
		local seg = path[i]
		if type(seg) == "string" then
			wu8(w, TAG_KEY_STRING)
			wstr(w, seg)
		elseif seg % 1 == 0 and seg >= 0 then
			wu8(w, TAG_KEY_UINT)
			wvarint(w, seg)
		else
			wu8(w, TAG_KEY_F64)
			wf64(w, seg)
		end
		target = if target then Template.ChildSchema(target, seg) else nil
	end
	return target
end

function Wire.DecodePath(r: Reader, compiled: Compiled): ({ string | number }, SchemaNode?)
	local id = rvarint(r)
	local node = compiled.ById[id]
	if node == nil then
		error(`Scribe: unknown field id {id}`)
	end
	local path: { string | number } = table.clone(node.Path) :: any
	local dynCount = ru8(r)
	local target: SchemaNode? = node
	for _ = 1, dynCount do
		local tag = ru8(r)
		local seg: string | number
		if tag == TAG_KEY_STRING then
			seg = rstr(r)
		elseif tag == TAG_KEY_UINT then
			seg = rvarint(r)
		elseif tag == TAG_KEY_F64 then
			seg = rf64(r)
		else
			error("Scribe: bad path segment tag")
		end
		table.insert(path, seg)
		target = if target then Template.ChildSchema(target, seg) else nil
	end
	return path, target
end

-- Op codec ------------------------------------------------------------------------

export type Op = {
	Kind: string, -- "Set" | "Insert" | "Remove" | "Clear"
	Path: { string | number },
	Value: any?,
	Index: number?,
}

function Wire.EncodeOp(w: Writer, compiled: Compiled, op: Op)
	local kindId = KIND_TO_ID[op.Kind]
	if kindId == nil then
		error(`Scribe: unknown op kind "{op.Kind}"`)
	end
	local head = kindId
	local hasValue = op.Value ~= nil
	if hasValue then
		head += FLAG_VALUE
	end
	if op.Index ~= nil then
		head += FLAG_INDEX
	end
	wu8(w, head)
	local target = Wire.EncodePath(w, compiled, op.Path)
	if op.Index ~= nil then
		wvarint(w, op.Index)
	end
	if hasValue then
		local valueNode = target
		if op.Kind == "Insert" and target then
			-- Array elements are children of the container node.
			valueNode = Template.ChildSchema(target, 1)
		end
		Wire.EncodeValue(w, valueNode, op.Value)
	end
end

function Wire.DecodeOp(r: Reader, compiled: Compiled): Op
	local head = ru8(r)
	local kindId = head % 16
	local kind = ID_TO_KIND[kindId]
	if kind == nil then
		error(`Scribe: unknown op kind id {kindId}`)
	end
	local hasValue = head % 32 >= 16
	local hasIndex = head % 64 >= 32
	local path, target = Wire.DecodePath(r, compiled)
	local index: number? = nil
	if hasIndex then
		index = rvarint(r)
	end
	local value: any = nil
	if hasValue then
		local valueNode = target
		if kind == "Insert" and target then
			valueNode = Template.ChildSchema(target, 1)
		end
		value = Wire.DecodeValue(r, valueNode)
	end
	return { Kind = kind, Path = path, Value = value, Index = index }
end

-- Encode a frame consisting of a frame-type byte, an optional prelude written
-- by `prelude(w)`, and a u16-counted op list.
function Wire.EncodeOpsFrame(frameType: number, compiled: Compiled, ops: { Op }, prelude: ((Writer) -> ())?): buffer
	-- Every caller pre-chunks to <= MAX_OPS_PER_FRAME; a frame over the u16
	-- count limit would silently drop its tail, so fail loudly instead.
	if #ops > 65535 then
		error(`Scribe: op frame too large ({#ops} ops); chunk before encoding`)
	end
	local w = Wire.NewWriter(64 + #ops * 16)
	wu8(w, frameType)
	if prelude then
		prelude(w)
	end
	wu16(w, #ops)
	for i = 1, #ops do
		Wire.EncodeOp(w, compiled, ops[i])
	end
	return Wire.Finish(w)
end

function Wire.DecodeOps(r: Reader, compiled: Compiled): { Op }
	local count = ru16(r)
	local ops: { Op } = table.create(count)
	for _ = 1, count do
		table.insert(ops, Wire.DecodeOp(r, compiled))
	end
	return ops
end

return Wire
