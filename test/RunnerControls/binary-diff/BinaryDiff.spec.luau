--!nonstrict
local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it, expect = JestGlobals.it, JestGlobals.expect

it("reports non-UTF8 buffer differences as a failed assertion", function()
	expect.assertions(6)
	local received = buffer.fromstring(string.char(0x00, 0x80, 0xFF))
	local expected = buffer.fromstring(string.char(0x00, 0x81, 0xFF))
	expect(received).toEqualBuffer(buffer.fromstring(string.char(0x00, 0x80, 0xFF)))
	expect(received).never.toEqualBuffer(expected)
	expect(buffer.create(0)).toEqualBuffer(buffer.create(0))
	expect(buffer.create(0)).never.toEqualBuffer(buffer.create(1))
	expect(buffer.fromstring(string.char(0x00, 0x80))).never.toEqualBuffer(received)
	print("SCRIBE_CONTROL_BINARY_POSITIVE_CASES_PASSED")
	expect(received).toEqualBuffer(expected)
end)
