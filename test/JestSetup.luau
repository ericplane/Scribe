--!nonstrict
local JestGlobals = require(script.Parent.Parent.DevPackages.JestGlobals)
local expect, jest = JestGlobals.expect, JestGlobals.jest

-- Jest Roblox starts each suite with fake timers. Scribe's async fixtures need
-- the real scheduler; deterministic simulations already own their virtual time.
jest.useRealTimers()
JestGlobals.beforeEach(function()
	jest.useRealTimers()
end)
-- Restore mocks through Jest's beforeEach configuration and runtime teardown.
-- A setup-file afterEach would run before the spec's own root cleanup hooks.

local function forbidFocus()
	error("Focused tests are forbidden: use SCRIBE_SPECS or SCRIBE_TEST_NAME to select tests", 2)
end
-- These are callable tables, also referenced by fit/fdescribe. Guard the table
-- itself: replacing fields on a JestGlobals copy would leave aliases usable.
for _, focused in { JestGlobals.it.only, JestGlobals.describe.only, JestGlobals.it.concurrent.only } do
	focused.each = forbidFocus
	focused.failing = forbidFocus
	setmetatable(focused, { __call = forbidFocus })
end

expect.extend({
	-- Keep arbitrary binary bytes out of Jest's UTF-8 error formatter. Compare the
	-- entire payload, then report the first differing byte in printable hex.
	toEqualBuffer = function(_self, received, expected)
		assert(type(received) == "buffer" and type(expected) == "buffer", "toEqualBuffer expects two buffers")
		local receivedLength, expectedLength = buffer.len(received), buffer.len(expected)
		local equal = buffer.tostring(received) == buffer.tostring(expected)
		return {
			pass = equal,
			message = function()
				if equal then
					return string.format("Expected buffer contents to differ (%d bytes)", receivedLength)
				end
				local offset = math.min(receivedLength, expectedLength)
				for index = 0, offset - 1 do
					if buffer.readu8(received, index) ~= buffer.readu8(expected, index) then
						offset = index
						break
					end
				end
				local function byteAt(value, length)
					return if offset < length then string.format("0x%02X", buffer.readu8(value, offset)) else "<end>"
				end
				return string.format(
					"Buffers differ at byte offset %d: received %s, expected %s (lengths %d and %d)",
					offset,
					byteAt(received, receivedLength),
					byteAt(expected, expectedLength),
					receivedLength,
					expectedLength
				)
			end,
		}
	end,
	-- Absolute error, including the boundary. Jest's decimal-precision matcher
	-- has different semantics from the tolerances used by Scribe's existing tests.
	toBeWithin = function(_self, received, expected, tolerance)
		local limit = if tolerance == nil then 1e-7 else tolerance
		assert(type(received) == "number" and type(expected) == "number", "toBeWithin expects two numbers")
		assert(type(limit) == "number" and limit >= 0 and limit < math.huge, "tolerance must be finite and nonnegative")
		return {
			pass = math.abs(received - expected) <= limit,
			message = function()
				return string.format(
					"Expected %s to be within %s of %s",
					tostring(received),
					tostring(limit),
					tostring(expected)
				)
			end,
		}
	end,
})

return nil
