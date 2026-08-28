--!strict
-- Buffer wire format. Transports carry opaque buffers; both sides derive an
-- identical schema from the shared template, so paths intern to field IDs and
-- values pack by declared type. A 1-byte header per value lets anything the
-- schema cannot describe fall back to the generic codec.

local Template = require(script.Parent.Template)

type SchemaNode = Template.SchemaNode
type Compiled = Template.Compiled

local Wire = {}

-- Bump on any frame layout change, even a purely additive one. The server's Hello
-- version check is all that stands between a mixed deploy and mis-decoded frames.
Wire.PROTOCOL_VERSION = 6

-- Max arguments a command frame carries. Shared so the client's encode cap and the
-- server's decode guard cannot drift.
Wire.MAX_COMMAND_ARGS = 16

-- Max bytes in an idempotency key, enforced on both sides. It governs a Command
-- frame's key and the persisted Data.Purchase key, so raising it raises what a
-- profile can carry. The number is repeated in prose nothing binds to this line:
-- Client/init, Server/init and Types.luau doc-comments, plus
-- docgen/guides/monetization.md and docgen/guides/log-codes.md.
Wire.MAX_IDEMPOTENCY_KEY_BYTES = 64

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
	Fragment = 11,
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

-- Only reached for a value canSchemaEncode has already proved binary32 can hold
-- within the declared error bound.
local function wf32(w: Writer, v: number)
	ensure(w, 4)
	buffer.writef32(w.buf, w.len, v)
	w.len += 4
end

-- Largest value the writer will encode. A Luau number is only an exact integer to
-- 2^53; past it the arithmetic below loses digits the reader cannot recover.
local MAX_VARINT = 2 ^ 53

-- Unsigned LEB128; arithmetic (not bit32) so values up to 2^53 round-trip.
local function wvarint(w: Writer, v: number)
	-- Refuse rather than loop: math.floor(inf) is inf, so a non-finite input grows
	-- the buffer until the process dies, and a negative wraps writeu8 into garbage.
	if v ~= v or v == math.huge or v == -math.huge or v < 0 or v > MAX_VARINT then
		error(`Scribe: cannot encode {tostring(v)} as a varint (expected an integer from 0 to 2^53)`, 0)
	end
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
	-- Remaining allocations this frame may still produce, nil for unlimited.
	budget: number?,
	-- Set when the budget ran out, so the caller can tell "too expensive" from
	-- "malformed" without matching on error text a crafted frame controls.
	overBudget: boolean?,
}

--- A reader over `buf`. `retainBudget` caps how many bytes the decoder may retain
--- from this frame, modelled per object; nil means unlimited.
---
--- Caller-supplied on purpose: the same decoder runs on the client over Init
--- frames the size of a whole profile, so a module-level budget would refuse a
--- legitimate snapshot. Only the server's untrusted inbound path passes one.
function Wire.NewReader(buf: buffer, retainBudget: number?): Reader
	return { buf = buf, pos = 0, size = buffer.len(buf), budget = retainBudget }
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

local function rf32(r: Reader): number
	local v = buffer.readf32(r.buf, r.pos)
	r.pos += 4
	return v
end

local function rvarint(r: Reader): number
	local result = 0
	local multiplier = 1
	-- 10 groups = 70 bits. A valid varint never exceeds ~8 groups; the extra
	-- headroom just bounds a malicious one.
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

-- What one decoded object retains, in bytes. Denominated in bytes rather than
-- object counts because an array slot costs the same whether it holds `true` or a
-- string pointer, while the two differ 2.5x in input bytes. Rounded up, and the two
-- Luau grows by doubling are counted at twice their unit size.
local SLOT_BYTES = 32 -- a 16-byte TValue, doubled for power-of-two array growth
local TABLE_BYTES = 64 -- the Table struct, ~56, rounded
local HASH_BYTES = 64 -- a 32-byte LuaNode, doubled for power-of-two node growth
local STRING_BYTES = 24 -- TString header, excluding the payload
local BUFFER_BYTES = 24 -- Buffer header, excluding the payload

-- The default budget of MaxInboundBytes * 16 (Replication.luau) is a ceiling, not
-- a per-byte figure: a nested empty table costs the sender two bytes and retains a
-- whole Table struct on top of the slot holding it, so table-valued elements
-- amplify well past 16:1 (WireBitmask.spec pins each path's worst case). Nothing
-- untrusted reaches the schema-typed decoder today; re-derive the multiplier from
-- those figures before one does.

-- Charge what one decoded object will retain, refusing the frame when the budget
-- runs out. Depth alone does not bound this: a flat table of four thousand empty
-- buffers is depth 1 and two bytes each. Raises rather than returning early, since
-- everything downstream assumes a failed decode discards the whole frame.
local function charge(r: Reader, bytes: number)
	local left = r.budget
	if left == nil then
		return
	end
	if left < bytes then
		r.overBudget = true
		error("Scribe: inbound frame exceeded its retention budget")
	end
	r.budget = left - bytes
end

--- Read a string, refusing it from its length prefix instead of after the fact: a
--- cap applied to the result has already paid for the allocation.
local function rstrBounded(r: Reader, maxBytes: number): string
	local len = rvarint(r)
	if len > maxBytes then
		error(`Scribe: string field of {len} bytes exceeds its {maxBytes}-byte limit`)
	end
	if r.pos + len > r.size then
		error("Scribe: string overruns buffer")
	end
	local s = buffer.readstring(r.buf, r.pos, len)
	r.pos += len
	return s
end

--- `headerBytes` is the fixed per-object overhead charged against the frame's
--- retention budget, plus the payload length taken from the length prefix. Omitted
--- by callers not decoding untrusted generic data.
local function rstr(r: Reader, headerBytes: number?): string
	local len = rvarint(r)
	if headerBytes ~= nil then
		charge(r, headerBytes + len)
	end
	if r.pos + len > r.size then
		error("Scribe: string overruns buffer")
	end
	local s = buffer.readstring(r.buf, r.pos, len)
	r.pos += len
	return s
end

local function rbuf(r: Reader, headerBytes: number?): buffer
	local length = rvarint(r)
	if headerBytes ~= nil then
		charge(r, headerBytes + length)
	end
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
Wire.RStrBounded = rstrBounded

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
		return rstr(r, STRING_BYTES)
	elseif tag == TAG_BUFFER then
		return rbuf(r, BUFFER_BYTES)
	elseif tag == TAG_TABLE then
		charge(r, TABLE_BYTES)
		local out = {}
		local arrayLen = rvarint(r)
		for i = 1, arrayLen do
			-- Charged per slot, not just per table: a table of N booleans would
			-- otherwise cost one charge while allocating N slots, at one byte each.
			-- Charged before the recursive decode so the refusal precedes it.
			charge(r, SLOT_BYTES)
			out[i] = decodeGeneric(r, depth + 1)
		end
		local hashCount = rvarint(r)
		for _ = 1, hashCount do
			-- Same reasoning; a hash pair costs at least as much as an array slot.
			charge(r, HASH_BYTES)
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

-- The value header byte, in front of every encoded value.
--
--   bits 0-1 mode, an enumeration rather than independent flags:
--              GENERIC  the schema cannot describe this value, so it degrades to
--                       the self-describing generic codec.
--              DENSE    keys are exactly 1..n; the body writes values positionally,
--                       with no key at all.
--              STATIC   keys are all declared children; the body is one presence
--                       bitmask over ChildOrder, then the present values in order.
--              TAGGED   the fallback, and the only mode that can carry a key the
--                       schema does not know.
--   bits 2-3 key tag, present only for an entry of a tagged table. A static
--            table's children need none; the bitmask is their key.
--   bits 4-7 reserved, and refused rather than ignored: a set bit is a drifted
--            encoder or a crafted frame.
--
-- A standalone header is 0..3 and a table entry's 0..15, each checked against its
-- own range. DENSE and STATIC are also refused on a non-table node, which the
-- scalar readers would otherwise accept in silence.
local VH_TAGGED = 0x00
local VH_GENERIC = 0x01
local VH_DENSE = 0x02
local VH_STATIC = 0x03
-- The key tag lives in bits 2-3, so it is scaled by 4 rather than shifted, which
-- makes VH_KEY_SCALE double as the modulus that extracts the mode. Bit work here
-- is arithmetic so that nothing depends on 32-bit truncation.
local VH_KEY_SCALE = 4
local VH_ENTRY_MAX = 16 -- one past the largest legal table-entry header
local VH_VALUE_MAX = 4 -- one past the largest legal standalone value header

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

-- Narrowed floats. The plan, the constants and the step count come from Template,
-- so the compiler, the encoder and the decoder share one derivation.
local FLOAT_F64 = Template.FLOAT_F64
local FLOAT_F32 = Template.FLOAT_F32
local FLOAT_Q8 = Template.FLOAT_Q8
local FLOAT_Q16 = Template.FLOAT_Q16
-- FLOAT_Q32 is deliberately absent: it is the fall-through plan in both the
-- encoder and the decoder below.
local F32_MAX = Template.F32_MAX
local F32_MIN_NORMAL = Template.F32_MIN_NORMAL
local floatPlan = Template.FloatPlan

--- The grid index of `v` on this node's fixed-point grid, rounded to nearest.
--- Truncating instead would double the worst-case error and bias it, so a quantized
--- field would drift downward over repeated round trips.
---
--- The clamp is unreachable while canSchemaEncode holds, and stays: without it a
--- value just past Max reaches buffer.writeu8 as 256, wraps, and comes back as Min.
local function quantIndex(node: SchemaNode, v: number, steps: number): number
	local q = math.floor((v - (node.Min :: number)) / (node.Precision :: number) + 0.5)
	if q < 0 then
		return 0
	elseif q > steps then
		return steps
	end
	return q
end

--- The grid point `q` names, clamped to Max.
---
--- Not about crafted frames: `steps` is ceil((Max - Min)/Precision), so when
--- Precision does not divide the range the top index sits one grid point past Max
--- and quantIndex rounds Max itself onto it. Min=0, Max=100, Precision=0.6 gives
--- 167 steps and 167*0.6 = 100.2 for a legal, in-range 100. The int path has no
--- legitimate overshoot to correct. Max is never nil here: a numeric Precision
--- requires both bounds.
local function quantValue(node: SchemaNode, q: number): number
	local v = (node.Min :: number) + q * (node.Precision :: number)
	local max = node.Max :: number
	if v > max then
		return max
	end
	return v
end

local function canSchemaEncode(node: SchemaNode, value: any): boolean
	local vt = node.ValueType
	if vt == "boolean" then
		return type(value) == "boolean"
	elseif vt == "int" then
		if type(value) ~= "number" or value % 1 ~= 0 then
			return false
		end
		-- Beyond 2^52 the varint/zigzag arithmetic loses precision; fall back
		-- to the generic f64 path, which round-trips any finite double.
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
		if type(value) ~= "number" then
			return false
		end
		local plan = floatPlan(node)
		if plan == FLOAT_F64 then
			-- The default, and the only arm an undeclared Scribe.Number reaches: any
			-- double at all, NaN and both infinities included.
			return true
		end
		-- Narrowed, so the tests below are the precision guarantee: anything outside
		-- the stated error bound is refused here and takes the generic path, where it
		-- round-trips as an exact f64. NaN and the infinities fall out of the same
		-- comparisons.
		if plan == FLOAT_F32 then
			local magnitude = math.abs(value)
			-- Zero is exact in binary32. Above F32_MAX the nearest binary32 is
			-- infinity; below F32_MIN_NORMAL the relative error blows past the 2^-24
			-- the width promises.
			return magnitude == 0 or (magnitude >= F32_MIN_NORMAL and magnitude <= F32_MAX)
		end
		-- Fixed-point. The grid only exists between the declared bounds, and both are
		-- finite, so this also rejects the infinities and NaN.
		return value >= (node.Min :: number) and value <= (node.Max :: number)
	elseif vt == "enum" then
		return type(value) == "string" and node.MemberIndex ~= nil and node.MemberIndex[value] ~= nil
	elseif vt == "big" then
		return type(value) == "table" and type(value[1]) == "number" and type(value[2]) == "number"
	elseif vt == "flags" then
		if type(value) ~= "table" or node.MemberIndex == nil then
			return false
		end
		for _, name in value :: { any } do
			if type(name) ~= "string" or node.MemberIndex[name] == nil then
				return false
			end
		end
		return true
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

--- Whether `value`'s keys are exactly 1..count, so its body can be written
--- positionally. The only thing that may set the dense bit.
---
--- `#value == count` is not equivalent: `#` on a holey table may return either
--- boundary, so `{[1]=1,[3]=3}` can answer 3 and would be written as three
--- positional values and read back as a different table. Probing every index costs
--- O(count) against an iteration that is already O(count).
local function isDenseArray(value: any, count: number): boolean
	if count == 0 then
		-- An empty table is trivially dense, but the flag saves nothing and costs
		-- the decoder a shape it need not model.
		return false
	end
	for i = 1, count do
		if value[i] == nil then
			return false
		end
	end
	return true
end

--- The number of bytes wvarint spends on `v`, for comparing two candidate
--- encodings before either is written.
local function varintLen(v: number): number
	local n = 1
	while v >= 128 do
		v = math.floor(v / 128)
		n += 1
	end
	return n
end

--- Whether every key of `value` is a static child `node` declares, and whether a
--- presence bitmask costs fewer bytes than tagging each key. The only thing that
--- may set the static mode.
---
--- The test is over the table's keys, not the schema's: walking ChildOrder instead
--- and finding every declared child present would pass a table that also carried
--- undeclared keys, and those would vanish from the frame in silence. No
--- empty-table guard is needed, unlike isDenseArray: no mask fits in fewer than
--- two bytes, so the cost comparison below already refuses one.
local function isStaticStruct(node: SchemaNode, value: any, count: number): boolean
	local children = node.Children
	local order = node.ChildOrder
	if children == nil or order == nil then
		return false
	end
	-- Unreachable for a compiled node that has Children, but it is the precondition
	-- the encoder's `math.ceil(declared / 8) - 1` loop bound depends on.
	local declared = #order
	if declared == 0 then
		return false
	end
	for k in value do
		if type(k) ~= "string" or children[k] == nil then
			return false
		end
	end
	-- Static spends a width varint plus the mask; tagged spends a count varint plus
	-- one ordinal varint per entry. Header and payload per field cancel. A tie goes
	-- to tagged.
	local staticBytes = varintLen(declared) + math.ceil(declared / 8)
	local taggedBytes = varintLen(count) + count
	return staticBytes < taggedBytes
end

--- The header bits for `value` under `node`, the node its payload is written
--- against (nil means the generic codec), and a table's entry count, so the payload
--- writer need not walk it again.
---
--- Split out because a table entry writes its key between the header and the
--- payload: returning the bits lets the caller fold in the key tag and emit one byte.
local function valueHeaderBits(node: SchemaNode?, value: any): (number, SchemaNode?, number)
	if node == nil or not canSchemaEncode(node, value) then
		return VH_GENERIC, nil, 0
	end
	if node.ValueType == "table" then
		local count = 0
		for _ in value do
			count += 1
		end
		if isDenseArray(value, count) then
			return VH_DENSE, node, count
		end
		if isStaticStruct(node, value, count) then
			return VH_STATIC, node, count
		end
		return VH_TAGGED, node, count
	end
	return VH_TAGGED, node, 0
end

local encodeValuePayload: (Writer, SchemaNode?, any, number, number, number) -> ()

--- Writes the value header (with no key tag; see the entry loop for the folded
--- form) and then the payload.
local function encodeValue(w: Writer, node: SchemaNode?, value: any, depth: number)
	local bits, target, count = valueHeaderBits(node, value)
	wu8(w, bits)
	encodeValuePayload(w, target, value, depth, bits, count)
end

--- `bits` and `count` come from valueHeaderBits rather than being recomputed: the
--- header is already written, so the mode here has to be the one it announced.
function encodeValuePayload(w: Writer, node: SchemaNode?, value: any, depth: number, bits: number, count: number)
	if node == nil then
		encodeGeneric(w, value, depth)
		return
	end
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
		local plan = floatPlan(node)
		if plan == FLOAT_F64 then
			wf64(w, value)
		elseif plan == FLOAT_F32 then
			wf32(w, value)
		else
			local steps = Template.QuantSteps(node.Min :: number, node.Max :: number, node.Precision :: number)
			local q = quantIndex(node, value, steps)
			if plan == FLOAT_Q8 then
				wu8(w, q)
			elseif plan == FLOAT_Q16 then
				wu16(w, q)
			else
				wu32(w, q) -- FLOAT_Q32
			end
		end
	elseif vt == "enum" then
		wu8(w, (node.MemberIndex :: { [string]: number })[value])
	elseif vt == "big" then
		-- The mantissa needs full double precision; the exponent is a small signed
		-- integer, so a zigzag varint is one or two bytes for any realistic value.
		wf64(w, value[1])
		wzigzag(w, value[2])
	elseif vt == "flags" then
		-- One bit per declared member, LSB = first member. Positional only within a
		-- frame; the stored form is the member names.
		local index = node.MemberIndex :: { [string]: number }
		local mask = 0
		for _, name in value :: { string } do
			-- MemberIndex is 0-based, so the first member owns bit 0.
			mask += 2 ^ index[name]
		end
		local memberCount = #(node.Members :: { string })
		if memberCount <= 8 then
			wu8(w, mask)
		elseif memberCount <= 16 then
			wu16(w, mask)
		else
			wu32(w, mask)
		end
	elseif vt == "string" then
		wstr(w, value)
	elseif vt == "buffer" or vt == "datatype" then
		wbuf(w, value)
	elseif vt == "table" then
		if depth > 24 then
			error("Scribe: value too deep to serialize")
		end
		local mode = bits % VH_KEY_SCALE
		if mode == VH_STATIC then
			-- One bit per declared child replaces the keys, then the present values in
			-- ordinal order. No entry count: it would restate the mask's popcount. Each
			-- child still carries its own header, so a value the schema cannot describe
			-- degrades to generic in place; only an undeclared key forces the tagged path.
			local order = node.ChildOrder :: { string }
			local children = node.Children :: { [string]: SchemaNode }
			local declared = #order
			wvarint(w, declared)
			-- LSB of the first byte is ordinal 1. Padding bits past `declared` are
			-- written zero and refused on the way back in.
			for byteIndex = 0, math.ceil(declared / 8) - 1 do
				local mask = 0
				for bit = 0, 7 do
					local ordinal = byteIndex * 8 + bit + 1
					if ordinal <= declared and value[order[ordinal]] ~= nil then
						mask += 2 ^ bit
					end
				end
				wu8(w, mask)
			end
			for i = 1, declared do
				local name = order[i]
				local v = value[name]
				if v ~= nil then
					local ebits, etarget, ecount = valueHeaderBits(children[name], v)
					wu8(w, ebits)
					encodeValuePayload(w, etarget, v, depth + 1, ebits, ecount)
				end
			end
		elseif mode == VH_DENSE then
			wvarint(w, count)
			-- Keys are 1..count and inferable from position, so nothing is written for
			-- them. Each element still carries a header and can degrade to generic.
			for i = 1, count do
				local child = Template.ChildSchema(node, i)
				local element = value[i]
				local ebits, etarget, ecount = valueHeaderBits(child, element)
				wu8(w, ebits)
				encodeValuePayload(w, etarget, element, depth + 1, ebits, ecount)
			end
		else
			wvarint(w, count)
			for k, v in value do
				local child: SchemaNode? = nil
				local keyTag: number
				if type(k) == "string" and node.Children and node.Children[k] then
					child = node.Children[k]
					keyTag = TAG_KEY_STATIC
				elseif type(k) == "string" then
					child = Template.ChildSchema(node, k)
					keyTag = TAG_KEY_STRING
				elseif type(k) == "number" and k % 1 == 0 and k >= 0 then
					child = Template.ChildSchema(node, k)
					keyTag = TAG_KEY_UINT
				else
					child = Template.ChildSchema(node, k)
					keyTag = TAG_KEY_F64
				end
				local ebits, etarget, ecount = valueHeaderBits(child, v)
				-- The fold: key tag and value mode share one byte.
				wu8(w, ebits + keyTag * VH_KEY_SCALE)
				if keyTag == TAG_KEY_STATIC then
					wvarint(w, (node.ChildOrdinal :: { [string]: number })[k])
				elseif keyTag == TAG_KEY_STRING then
					wstr(w, k :: string)
				elseif keyTag == TAG_KEY_UINT then
					wvarint(w, k :: number)
				else
					wf64(w, k :: number)
				end
				encodeValuePayload(w, etarget, v, depth + 1, ebits, ecount)
			end
		end
	end
end

local decodeValuePayload: (Reader, SchemaNode?, number, number) -> any

--- Reads a standalone value header (no key tag) and its payload.
local function decodeValue(r: Reader, node: SchemaNode?, depth: number): any
	local header = ru8(r)
	-- A standalone header owns bits 0-1 only. Key-tag bits here mean the writer and
	-- the reader disagree about whether this value sits in a table.
	if header >= VH_VALUE_MAX then
		error("Scribe: malformed value header")
	end
	return decodeValuePayload(r, node, depth, header)
end

--- `header` carries the mode and dense bits (bits 0-1); the caller has already
--- stripped any key tag and validated the reserved range.
function decodeValuePayload(r: Reader, node: SchemaNode?, depth: number, header: number): any
	-- An enumeration, not a set of flags: VH_STATIC is 3, so a `header % 2` test
	-- for genericness would decode a presence bitmask as a generic type tag.
	local mode = header % VH_KEY_SCALE
	if mode == VH_GENERIC then
		return decodeGeneric(r, depth)
	end
	if node == nil then
		error("Scribe: malformed value mode")
	end
	local vt = node.ValueType
	-- DENSE and STATIC describe a table's body, so either over a scalar node is a
	-- drifted encoder or a crafted header. Refused rather than ignored: none of the
	-- scalar readers below looks at the mode.
	if mode >= VH_DENSE and vt ~= "table" then
		error(`Scribe: table value mode on a "{vt}" node`)
	end
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
		local plan = floatPlan(node)
		if plan == FLOAT_F64 then
			return rf64(r)
		elseif plan == FLOAT_F32 then
			return rf32(r)
		elseif plan == FLOAT_Q8 then
			return quantValue(node, ru8(r))
		elseif plan == FLOAT_Q16 then
			return quantValue(node, ru16(r))
		end
		-- FLOAT_Q32, as the tail rather than a branch of its own. These arms must
		-- mirror the encoder's, or a field is written and read at different widths.
		return quantValue(node, ru32(r))
	elseif vt == "big" then
		return { rf64(r), rzigzag(r) }
	elseif vt == "flags" then
		local members = node.Members :: { string }
		local count = #members
		local mask = if count <= 8 then ru8(r) elseif count <= 16 then ru16(r) else ru32(r)
		charge(r, TABLE_BYTES)
		local out = {}
		for i, name in members do
			if mask % (2 ^ i) >= 2 ^ (i - 1) then
				-- The name is interned in the compiled template, so only the slot is
				-- new; charged for symmetry with decodeGeneric.
				charge(r, SLOT_BYTES)
				table.insert(out, name)
			end
		end
		return out
	elseif vt == "enum" then
		local idx = ru8(r)
		local member = (node.Members :: { string })[idx + 1]
		if member == nil then
			error("Scribe: enum index out of range")
		end
		return member
	elseif vt == "string" then
		return rstr(r, STRING_BYTES)
	elseif vt == "buffer" or vt == "datatype" then
		return rbuf(r, BUFFER_BYTES)
	elseif vt == "table" then
		if depth > 24 then
			error("Scribe: value too deep to deserialize")
		end
		charge(r, TABLE_BYTES)
		-- Written with a string key in the static branch and a number key in the
		-- array branch, so the first write alone must not pin the index type.
		local out: { [string | number]: any } = {}
		if mode == VH_STATIC then
			local order = node.ChildOrder
			local children = node.Children
			if order == nil or children == nil then
				-- An open any-node or a leaf element declares no children, so there is
				-- no ChildOrder for a bitmask to index.
				error("Scribe: static table under a node with no declared children")
			end
			local declared = rvarint(r)
			-- The mask's width comes from the frame and is checked against the schema,
			-- so a disagreeing frame fails here, at the table that is wrong, rather than
			-- mis-parsing everything after it. It also bounds the read below by the
			-- schema rather than by an attacker-chosen varint.
			if declared ~= #order then
				error("Scribe: static bitmask width disagrees with the schema")
			end
			local maskBytes = math.ceil(declared / 8)
			local maskStart = r.pos
			if maskStart + maskBytes > r.size then
				error("Scribe: static bitmask overruns buffer")
			end
			r.pos += maskBytes
			-- Charged up front from the popcount, so a wide struct is refused before the
			-- first recursive decode. The mask already states the whole entry list.
			local present = 0
			for b = 0, maskBytes - 1 do
				local byte = buffer.readu8(r.buf, maskStart + b)
				if b == maskBytes - 1 then
					-- Padding bits past `declared` are written zero; a frame that sets
					-- one is refused rather than masked off.
					local used = declared - b * 8
					if used < 8 and byte >= 2 ^ used then
						error("Scribe: static bitmask has bits set past its declared width")
					end
				end
				while byte > 0 do
					present += byte % 2
					byte = math.floor(byte / 2)
				end
			end
			charge(r, HASH_BYTES * present)
			for i = 1, declared do
				local byte = buffer.readu8(r.buf, maskStart + math.floor((i - 1) / 8))
				local bit = (i - 1) % 8
				if byte % (2 ^ (bit + 1)) >= 2 ^ bit then
					local name = order[i]
					out[name] = decodeValue(r, children[name], depth + 1)
				end
			end
			return out
		end
		local count = rvarint(r)
		if mode == VH_DENSE then
			for i = 1, count do
				-- SLOT_BYTES rather than the tagged path's HASH_BYTES because these
				-- really are array slots, and two bytes against 32 is the same ratio as
				-- the tagged path's four against 64. Charged before the decode.
				charge(r, SLOT_BYTES)
				out[i] = decodeValue(r, Template.ChildSchema(node, i), depth + 1)
			end
			return out
		end
		for _ = 1, count do
			-- Charged per declared entry, from the count above, before the key or the
			-- value is read. A no-op against the client's nil budget today; it is here
			-- so it is not a hole to rediscover.
			charge(r, HASH_BYTES)
			local entryHeader = ru8(r)
			if entryHeader >= VH_ENTRY_MAX then
				error("Scribe: malformed value header")
			end
			local tag = (entryHeader - entryHeader % VH_KEY_SCALE) / VH_KEY_SCALE
			local key: any
			local child: SchemaNode? = nil
			if tag == TAG_KEY_STATIC then
				local ordinal = rvarint(r)
				-- ChildOrder is nil on a node that declares no static children, so a
				-- frame claiming a static key under one is malformed. Without this it
				-- surfaces as "attempt to index nil with number", reading as a bug.
				local order = node.ChildOrder
				local name = if order ~= nil then order[ordinal] else nil
				if name == nil then
					error("Scribe: bad child ordinal")
				end
				key = name
				child = (node.Children :: { [string]: SchemaNode })[name]
			elseif tag == TAG_KEY_STRING then
				key = rstr(r, STRING_BYTES)
				child = Template.ChildSchema(node, key)
			elseif tag == TAG_KEY_UINT then
				key = rvarint(r)
				child = Template.ChildSchema(node, key)
			else
				key = rf64(r)
				child = Template.ChildSchema(node, key)
			end
			local value = decodeValuePayload(r, child, depth + 1, entryHeader % VH_KEY_SCALE)
			-- Skip a NaN key (only a crafted TAG_KEY_F64 decodes to one): t[NaN] throws.
			-- Decode the value first to keep the reader in sync.
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
	-- The count travels as a u8, so a deeper path would wrap and desync the frame.
	-- Writes are already capped at MAX_PATH_DYN_SEGMENTS (Node.validateWrite).
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

--- The initial writer capacity EncodeOpsFrame will choose for `opCount` ops and an
--- optional `sizeHint`. Exported so a spec can pin it: seeding changes allocation
--- counts and not one output byte, so nothing else could tell it from an
--- implementation that quietly stopped seeding. InitWriterSeed.spec watches it.
function Wire.OpsFrameCapacity(opCount: number, sizeHint: number?): number
	-- A hint smaller than the op count implies, from a tiny previous Init before a
	-- large one, must not shrink the writer below what the ops alone justify.
	local capacity = 64 + opCount * 16
	if sizeHint ~= nil and sizeHint > capacity then
		return sizeHint
	end
	return capacity
end

--- Encodes a frame: a frame-type byte, an optional prelude written by `prelude(w)`,
--- and a u16-counted op list. When `spans` is given it is filled with each op's
--- encoded byte length, in order, measured from the writer's own offset rather than
--- by re-encoding, which would cost a second pass and over-count one header per op.
---
--- `sizeHint` is a floor for the writer's initial capacity, in bytes, and only the
--- Init path passes one. `#ops` models a Diff but not an Init: ownerSnapshotOps
--- emits one op per root, so a forty-thousand-field profile produces the same
--- handful of ops as a tiny one and the writer doubles its way up from a couple of
--- hundred bytes. The last Init's size estimates the next.
function Wire.EncodeOpsFrame(
	frameType: number,
	compiled: Compiled,
	ops: { Op },
	prelude: ((Writer) -> ())?,
	spans: { number }?,
	sizeHint: number?
): buffer
	-- Callers pre-chunk to MAX_OPS_PER_FRAME; a frame over the u16 count limit
	-- would silently drop its tail, so fail loudly instead.
	if #ops > 65535 then
		error(`Scribe: op frame too large ({#ops} ops); chunk before encoding`)
	end
	local w = Wire.NewWriter(Wire.OpsFrameCapacity(#ops, sizeHint))
	wu8(w, frameType)
	if prelude then
		prelude(w)
	end
	wu16(w, #ops)
	if spans == nil then
		for i = 1, #ops do
			Wire.EncodeOp(w, compiled, ops[i])
		end
	else
		local prev = w.len
		for i = 1, #ops do
			Wire.EncodeOp(w, compiled, ops[i])
			spans[i] = w.len - prev
			prev = w.len
		end
	end
	return Wire.Finish(w)
end

-- Frame fragmentation ------------------------------------------------------------
--
-- Framing, not replication. An Init snapshot is one op per root, so no op-level
-- chunking can divide it; splitting the encoded buffer always works.
--
--   u8 Frames.Fragment | u16 seq | u32 total | u16 index | <payload slice>
--
-- `total` is the reassembled length, repeated in every fragment so the receiver can
-- size its destination from the first one. `index` makes a lost middle fragment
-- detectable, where a gap would otherwise write later bytes at the wrong offset and
-- still reach `total`. Without `seq`, index 0 is the only reset trigger, so two
-- interleaved logical frames splice into a buffer whose indices ascend and whose
-- length matches, and decode cleanly into values that existed in neither snapshot.
-- Scribe never interleaves today, but only by transport contract.
Wire.FRAGMENT_HEADER = 9

--- Splits `bytes` into fragments no larger than `maxBytes`, handing each to `emit`
--- in order. Returns nil when the frame already fits and `emit` was never called;
--- otherwise whether every fragment was emitted (`emit` may return false to stop).
---
--- Streaming rather than list-returning: a materialised list is a second full copy
--- of the frame, and the unicast Init has one recipient and needs none.
function Wire.Fragment(bytes: buffer, maxBytes: number, seq: number, emit: (buffer) -> boolean): boolean?
	local total = buffer.len(bytes)
	if total <= maxBytes then
		return nil
	end
	local capacity = maxBytes - Wire.FRAGMENT_HEADER
	if capacity < 1 then
		error(`Scribe: fragment budget of {maxBytes} bytes cannot carry a payload`, 0)
	end
	-- buffer.writeu16 truncates silently, so a wrapped index would reset the
	-- receiver mid-frame and a wrapped count would end it early.
	local count = math.ceil(total / capacity)
	if count > 65535 then
		error(`Scribe: frame of {total} bytes needs {count} fragments (max 65535); raise MaxOutboundBytes`, 0)
	end
	local offset, index = 0, 0
	while offset < total do
		local take = math.min(capacity, total - offset)
		local frame = buffer.create(Wire.FRAGMENT_HEADER + take)
		buffer.writeu8(frame, 0, Wire.Frames.Fragment)
		buffer.writeu16(frame, 1, seq)
		buffer.writeu32(frame, 3, total)
		buffer.writeu16(frame, 7, index)
		buffer.copy(frame, Wire.FRAGMENT_HEADER, bytes, offset, take)
		if not emit(frame) then
			return false
		end
		offset += take
		index += 1
	end
	return true
end

function Wire.DecodeOps(r: Reader, compiled: Compiled): { Op }
	local count = ru16(r)
	local ops = table.create(count) :: { Op }
	for _ = 1, count do
		table.insert(ops, Wire.DecodeOp(r, compiled))
	end
	return ops
end

return Wire
