--!strict
-- Packed-buffer codecs for Roblox datatypes. Declared fields (Scribe.Vector3,
-- Scribe.CFrame, ...) store this packed form in profile data. Persistence,
-- replication, cloning, and the wipe guard only ever see plain buffers, and
-- the node accessor converts at the boundary (Set packs, Get unpacks).
--
-- Roblox stores these types as f32 internally, so f32 packing is lossless.
-- Sizes (raw; DataStores keep buffers as base64, ~4/3 of raw):
--   Vector3 12, Vector2 8, Vector3int16 6, Vector2int16 4
--   CFrame 13 (axis-aligned rotation) / 29 (quaternion)
--   Color3 4 (exact-RGB) / 13 (f32), BrickColor 2, UDim 8, UDim2 16
--   Rect 16, NumberRange 8, NumberSequence 1+12/keypoint
--   ColorSequence 1+16/keypoint, DateTime 8, EnumItem 5+name, Font 3+family
--   PhysicalProperties 20

local Datatypes = {}

type Codec = {
	Pack: (value: any) -> buffer,
	Unpack: (b: buffer) -> any,
}

local codecs: { [string]: Codec } = {}

local function checkLen(b: buffer, expected: number, name: string)
	if buffer.len(b) < expected then
		error(`Scribe: malformed packed {name}`)
	end
end

-- Checked f32 writer: rejects NaN/inf components so a corrupt datatype can
-- never be silently persisted (the plain number path guards the same way).
-- The `NONFINITE` prefix lets validateWrite convert this into a clean,
-- path-tagged validation error.
local NONFINITE = "Scribe:nonfinite:"

local function wf32(b: buffer, offset: number, value: number)
	if value ~= value or value == math.huge or value == -math.huge then
		error(NONFINITE, 0)
	end
	buffer.writef32(b, offset, value)
end

Datatypes.NONFINITE = NONFINITE

-- Vectors -----------------------------------------------------------------------

codecs.Vector3 = {
	Pack = function(v: Vector3): buffer
		local b = buffer.create(12)
		wf32(b, 0, v.X)
		wf32(b, 4, v.Y)
		wf32(b, 8, v.Z)
		return b
	end,
	Unpack = function(b: buffer): Vector3
		checkLen(b, 12, "Vector3")
		return Vector3.new(buffer.readf32(b, 0), buffer.readf32(b, 4), buffer.readf32(b, 8))
	end,
}

codecs.Vector2 = {
	Pack = function(v: Vector2): buffer
		local b = buffer.create(8)
		wf32(b, 0, v.X)
		wf32(b, 4, v.Y)
		return b
	end,
	Unpack = function(b: buffer): Vector2
		checkLen(b, 8, "Vector2")
		return Vector2.new(buffer.readf32(b, 0), buffer.readf32(b, 4))
	end,
}

codecs.Vector3int16 = {
	Pack = function(v: Vector3int16): buffer
		local b = buffer.create(6)
		buffer.writei16(b, 0, v.X)
		buffer.writei16(b, 2, v.Y)
		buffer.writei16(b, 4, v.Z)
		return b
	end,
	Unpack = function(b: buffer): Vector3int16
		checkLen(b, 6, "Vector3int16")
		return Vector3int16.new(buffer.readi16(b, 0), buffer.readi16(b, 2), buffer.readi16(b, 4))
	end,
}

codecs.Vector2int16 = {
	Pack = function(v: Vector2int16): buffer
		local b = buffer.create(4)
		buffer.writei16(b, 0, v.X)
		buffer.writei16(b, 2, v.Y)
		return b
	end,
	Unpack = function(b: buffer): Vector2int16
		checkLen(b, 4, "Vector2int16")
		return Vector2int16.new(buffer.readi16(b, 0), buffer.readi16(b, 2))
	end,
}

-- CFrame ------------------------------------------------------------------------
-- Layout: [u8 rotation tag][3xf32 position][4xf32 quaternion when tag == 255].
-- Placed structures are overwhelmingly rotated in 90-degree steps; the 24
-- axis-aligned orientations encode as rightAxisCode * 6 + upAxisCode (< 36),
-- costing one byte instead of sixteen.

local AXIS_EPSILON = 1e-4

-- Returns 0-5 (axis index * 2 + negative bit) when the vector is a unit axis.
local function unitAxisCode(x: number, y: number, z: number): number?
	local ax, ay, az = math.abs(x), math.abs(y), math.abs(z)
	if ax > 1 - AXIS_EPSILON and ay < AXIS_EPSILON and az < AXIS_EPSILON then
		return 0 + (if x < 0 then 1 else 0)
	elseif ay > 1 - AXIS_EPSILON and ax < AXIS_EPSILON and az < AXIS_EPSILON then
		return 2 + (if y < 0 then 1 else 0)
	elseif az > 1 - AXIS_EPSILON and ax < AXIS_EPSILON and ay < AXIS_EPSILON then
		return 4 + (if z < 0 then 1 else 0)
	end
	return nil
end

local function axisFromCode(code: number): Vector3
	local sign = if code % 2 == 1 then -1 else 1
	local axis = math.floor(code / 2)
	if axis == 0 then
		return Vector3.new(sign, 0, 0)
	elseif axis == 1 then
		return Vector3.new(0, sign, 0)
	end
	return Vector3.new(0, 0, sign)
end

codecs.CFrame = {
	Pack = function(cf: CFrame): buffer
		local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
		local rightCode = unitAxisCode(r00, r10, r20)
		local upCode = unitAxisCode(r01, r11, r21)
		if rightCode and upCode and math.floor(rightCode / 2) ~= math.floor(upCode / 2) then
			local b = buffer.create(13)
			buffer.writeu8(b, 0, rightCode * 6 + upCode)
			wf32(b, 1, x)
			wf32(b, 5, y)
			wf32(b, 9, z)
			return b
		end

		-- Standard rotation-matrix -> quaternion conversion.
		local qx, qy, qz, qw
		local trace = r00 + r11 + r22
		if trace > 0 then
			local s = math.sqrt(trace + 1) * 2
			qw = s / 4
			qx = (r21 - r12) / s
			qy = (r02 - r20) / s
			qz = (r10 - r01) / s
		elseif r00 > r11 and r00 > r22 then
			local s = math.sqrt(1 + r00 - r11 - r22) * 2
			qw = (r21 - r12) / s
			qx = s / 4
			qy = (r01 + r10) / s
			qz = (r02 + r20) / s
		elseif r11 > r22 then
			local s = math.sqrt(1 + r11 - r00 - r22) * 2
			qw = (r02 - r20) / s
			qx = (r01 + r10) / s
			qy = s / 4
			qz = (r12 + r21) / s
		else
			local s = math.sqrt(1 + r22 - r00 - r11) * 2
			qw = (r10 - r01) / s
			qx = (r02 + r20) / s
			qy = (r12 + r21) / s
			qz = s / 4
		end

		local b = buffer.create(29)
		buffer.writeu8(b, 0, 255)
		wf32(b, 1, x)
		wf32(b, 5, y)
		wf32(b, 9, z)
		wf32(b, 13, qx)
		wf32(b, 17, qy)
		wf32(b, 21, qz)
		wf32(b, 25, qw)
		return b
	end,
	Unpack = function(b: buffer): CFrame
		checkLen(b, 13, "CFrame")
		local tag = buffer.readu8(b, 0)
		local position = Vector3.new(buffer.readf32(b, 1), buffer.readf32(b, 5), buffer.readf32(b, 9))
		if tag == 255 then
			checkLen(b, 29, "CFrame")
			return CFrame.new(
				position.X,
				position.Y,
				position.Z,
				buffer.readf32(b, 13),
				buffer.readf32(b, 17),
				buffer.readf32(b, 21),
				buffer.readf32(b, 25)
			)
		end
		local rightCode = math.floor(tag / 6)
		local upCode = tag % 6
		if rightCode > 5 or math.floor(rightCode / 2) == math.floor(upCode / 2) then
			error("Scribe: malformed packed CFrame orientation")
		end
		return CFrame.fromMatrix(position, axisFromCode(rightCode), axisFromCode(upCode))
	end,
}

-- Colors ------------------------------------------------------------------------
-- Layout: [u8 mode] then 3xu8 (mode 0, exact fromRGB colors) or 3xf32 (mode 1).

local function packColor3Into(b: buffer, offset: number, color: Color3): number
	local r255, g255, b255 = color.R * 255, color.G * 255, color.B * 255
	local function exact(n: number): boolean
		-- Only components that round to a whole 0-255 byte qualify for the
		-- compact u8 mode; HDR/negative values fall through to f32 so
		-- writeu8's mod-256 wrap can never corrupt them.
		return math.abs(n - math.round(n)) < 1e-4 and n >= -1e-4 and n <= 255 + 1e-4
	end
	if exact(r255) and exact(g255) and exact(b255) then
		buffer.writeu8(b, offset, 0)
		buffer.writeu8(b, offset + 1, math.round(r255))
		buffer.writeu8(b, offset + 2, math.round(g255))
		buffer.writeu8(b, offset + 3, math.round(b255))
		return offset + 4
	end
	buffer.writeu8(b, offset, 1)
	wf32(b, offset + 1, color.R)
	wf32(b, offset + 5, color.G)
	wf32(b, offset + 9, color.B)
	return offset + 13
end

local function unpackColor3From(b: buffer, offset: number): (Color3, number)
	local mode = buffer.readu8(b, offset)
	if mode == 0 then
		return Color3.fromRGB(buffer.readu8(b, offset + 1), buffer.readu8(b, offset + 2), buffer.readu8(b, offset + 3)),
			offset + 4
	end
	return Color3.new(buffer.readf32(b, offset + 1), buffer.readf32(b, offset + 5), buffer.readf32(b, offset + 9)),
		offset + 13
end

codecs.Color3 = {
	Pack = function(color: Color3): buffer
		local b = buffer.create(13)
		local used = packColor3Into(b, 0, color)
		if used == buffer.len(b) then
			return b
		end
		local out = buffer.create(used)
		buffer.copy(out, 0, b, 0, used)
		return out
	end,
	Unpack = function(b: buffer): Color3
		checkLen(b, 4, "Color3")
		local color = unpackColor3From(b, 0)
		return color
	end,
}

codecs.BrickColor = {
	Pack = function(color: BrickColor): buffer
		local b = buffer.create(2)
		buffer.writeu16(b, 0, color.Number)
		return b
	end,
	Unpack = function(b: buffer): BrickColor
		checkLen(b, 2, "BrickColor")
		return BrickColor.new(buffer.readu16(b, 0))
	end,
}

-- UI ---------------------------------------------------------------------------

codecs.UDim = {
	Pack = function(value: UDim): buffer
		local b = buffer.create(8)
		wf32(b, 0, value.Scale)
		buffer.writei32(b, 4, value.Offset)
		return b
	end,
	Unpack = function(b: buffer): UDim
		checkLen(b, 8, "UDim")
		return UDim.new(buffer.readf32(b, 0), buffer.readi32(b, 4))
	end,
}

codecs.UDim2 = {
	Pack = function(value: UDim2): buffer
		local b = buffer.create(16)
		wf32(b, 0, value.X.Scale)
		buffer.writei32(b, 4, value.X.Offset)
		wf32(b, 8, value.Y.Scale)
		buffer.writei32(b, 12, value.Y.Offset)
		return b
	end,
	Unpack = function(b: buffer): UDim2
		checkLen(b, 16, "UDim2")
		return UDim2.new(buffer.readf32(b, 0), buffer.readi32(b, 4), buffer.readf32(b, 8), buffer.readi32(b, 12))
	end,
}

codecs.Rect = {
	Pack = function(value: Rect): buffer
		local b = buffer.create(16)
		wf32(b, 0, value.Min.X)
		wf32(b, 4, value.Min.Y)
		wf32(b, 8, value.Max.X)
		wf32(b, 12, value.Max.Y)
		return b
	end,
	Unpack = function(b: buffer): Rect
		checkLen(b, 16, "Rect")
		return Rect.new(
			Vector2.new(buffer.readf32(b, 0), buffer.readf32(b, 4)),
			Vector2.new(buffer.readf32(b, 8), buffer.readf32(b, 12))
		)
	end,
}

-- Ranges and sequences -------------------------------------------------------------

codecs.NumberRange = {
	Pack = function(value: NumberRange): buffer
		local b = buffer.create(8)
		wf32(b, 0, value.Min)
		wf32(b, 4, value.Max)
		return b
	end,
	Unpack = function(b: buffer): NumberRange
		checkLen(b, 8, "NumberRange")
		return NumberRange.new(buffer.readf32(b, 0), buffer.readf32(b, 4))
	end,
}

codecs.NumberSequence = {
	Pack = function(value: NumberSequence): buffer
		local keypoints = value.Keypoints
		if #keypoints > 255 then
			error("Scribe: NumberSequence has too many keypoints")
		end
		local b = buffer.create(1 + #keypoints * 12)
		buffer.writeu8(b, 0, #keypoints)
		local offset = 1
		for _, keypoint in keypoints do
			wf32(b, offset, keypoint.Time)
			wf32(b, offset + 4, keypoint.Value)
			wf32(b, offset + 8, keypoint.Envelope)
			offset += 12
		end
		return b
	end,
	Unpack = function(b: buffer): NumberSequence
		checkLen(b, 1, "NumberSequence")
		local count = buffer.readu8(b, 0)
		checkLen(b, 1 + count * 12, "NumberSequence")
		local keypoints = table.create(count)
		local offset = 1
		for _ = 1, count do
			table.insert(
				keypoints,
				NumberSequenceKeypoint.new(
					buffer.readf32(b, offset),
					buffer.readf32(b, offset + 4),
					buffer.readf32(b, offset + 8)
				)
			)
			offset += 12
		end
		return NumberSequence.new(keypoints)
	end,
}

codecs.ColorSequence = {
	Pack = function(value: ColorSequence): buffer
		local keypoints = value.Keypoints
		if #keypoints > 255 then
			error("Scribe: ColorSequence has too many keypoints")
		end
		local b = buffer.create(1 + #keypoints * 16)
		buffer.writeu8(b, 0, #keypoints)
		local offset = 1
		for _, keypoint in keypoints do
			wf32(b, offset, keypoint.Time)
			wf32(b, offset + 4, keypoint.Value.R)
			wf32(b, offset + 8, keypoint.Value.G)
			wf32(b, offset + 12, keypoint.Value.B)
			offset += 16
		end
		return b
	end,
	Unpack = function(b: buffer): ColorSequence
		checkLen(b, 1, "ColorSequence")
		local count = buffer.readu8(b, 0)
		checkLen(b, 1 + count * 16, "ColorSequence")
		local keypoints = table.create(count)
		local offset = 1
		for _ = 1, count do
			table.insert(
				keypoints,
				ColorSequenceKeypoint.new(
					buffer.readf32(b, offset),
					Color3.new(
						buffer.readf32(b, offset + 4),
						buffer.readf32(b, offset + 8),
						buffer.readf32(b, offset + 12)
					)
				)
			)
			offset += 16
		end
		return ColorSequence.new(keypoints)
	end,
}

-- Time, enums, fonts, physics ---------------------------------------------------------

codecs.DateTime = {
	Pack = function(value: DateTime): buffer
		local b = buffer.create(8)
		buffer.writef64(b, 0, value.UnixTimestampMillis)
		return b
	end,
	Unpack = function(b: buffer): DateTime
		checkLen(b, 8, "DateTime")
		return DateTime.fromUnixTimestampMillis(buffer.readf64(b, 0))
	end,
}

local function writeShortString(b: buffer, offset: number, s: string): number
	buffer.writeu8(b, offset, #s)
	buffer.writestring(b, offset + 1, s)
	return offset + 1 + #s
end

local function readShortString(b: buffer, offset: number): (string, number)
	local length = buffer.readu8(b, offset)
	return buffer.readstring(b, offset + 1, length), offset + 1 + length
end

local function enumItemFromValue(enumTypeName: string, value: number): EnumItem
	local enumType = (Enum :: any)[enumTypeName]
	local ok, item = pcall(function()
		return enumType:FromValue(value)
	end)
	if ok and item then
		return item
	end
	for _, candidate in enumType:GetEnumItems() do
		if candidate.Value == value then
			return candidate
		end
	end
	error(`Scribe: no {enumTypeName} enum item with value {value}`)
end

codecs.EnumItem = {
	Pack = function(value: EnumItem): buffer
		local typeName = tostring(value.EnumType)
		if #typeName > 255 then
			error("Scribe: enum type name too long")
		end
		local b = buffer.create(1 + #typeName + 4)
		local offset = writeShortString(b, 0, typeName)
		buffer.writeu32(b, offset, value.Value)
		return b
	end,
	Unpack = function(b: buffer): EnumItem
		checkLen(b, 5, "EnumItem")
		local typeName, offset = readShortString(b, 0)
		return enumItemFromValue(typeName, buffer.readu32(b, offset))
	end,
}

codecs.Font = {
	Pack = function(value: Font): buffer
		local family = value.Family
		if #family > 255 then
			error("Scribe: font family too long")
		end
		local b = buffer.create(1 + #family + 3)
		local offset = writeShortString(b, 0, family)
		buffer.writeu16(b, offset, value.Weight.Value)
		buffer.writeu8(b, offset + 2, value.Style.Value)
		return b
	end,
	Unpack = function(b: buffer): Font
		checkLen(b, 4, "Font")
		local family, offset = readShortString(b, 0)
		local weight = enumItemFromValue("FontWeight", buffer.readu16(b, offset))
		local style = enumItemFromValue("FontStyle", buffer.readu8(b, offset + 2))
		return Font.new(family, weight :: any, style :: any)
	end,
}

codecs.PhysicalProperties = {
	Pack = function(value: PhysicalProperties): buffer
		local b = buffer.create(20)
		wf32(b, 0, value.Density)
		wf32(b, 4, value.Friction)
		wf32(b, 8, value.Elasticity)
		wf32(b, 12, value.FrictionWeight)
		wf32(b, 16, value.ElasticityWeight)
		return b
	end,
	Unpack = function(b: buffer): PhysicalProperties
		checkLen(b, 20, "PhysicalProperties")
		return PhysicalProperties.new(
			buffer.readf32(b, 0),
			buffer.readf32(b, 4),
			buffer.readf32(b, 8),
			buffer.readf32(b, 12),
			buffer.readf32(b, 16)
		)
	end,
}

--------------------------------------------------------------------------------

function Datatypes.IsSupported(name: string): boolean
	return codecs[name] ~= nil
end

function Datatypes.Pack(name: string, value: any): buffer
	local codec = codecs[name]
	if not codec then
		error(`Scribe: unsupported datatype "{name}"`, 2)
	end
	return codec.Pack(value)
end

function Datatypes.Unpack(name: string, b: buffer): any
	local codec = codecs[name]
	if not codec then
		error(`Scribe: unsupported datatype "{name}"`, 2)
	end
	return codec.Unpack(b)
end

return Datatypes
