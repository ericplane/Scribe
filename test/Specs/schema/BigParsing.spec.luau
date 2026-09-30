--!nonstrict
-- Bounded numeric text must preserve its value or fail before a write.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe)
local Big = require(Root.Scribe.Internal.Big)
local TestCtx = require(Root.Test.Helpers.TestCtx)

local function expectPair(text, mantissa, exponent)
	local parsed = Big.from(text)
	expect(parsed ~= nil).toBe(true)
	expect(parsed.M).toBe(mantissa)
	expect(parsed.E).toBe(exponent)
end

it("accepts literal and scientific zero forms", function()
	for _, text in { "0", "-0", "+000", "0.", ".0", "-000.000", "0e400", "0e-400", "+00E+000", " \t- 0. 0\n" } do
		expectPair(text, 0, 0)
	end
end)

it("preserves nonzero values outside the double range", function()
	for _, case in
		{
			{ "1e-400", 1, -400 },
			{ "-1.5E-400", -1.5, -400 },
			{ "+1.5e400", 1.5, 400 },
			{ " 1 . 5 e + 4 0 0 ", 1.5, 400 },
			{ string.rep("0", 250) .. "1e-400", 1, -400 },
		}
	do
		expectPair(case[1], case[2], case[3])
	end
end)

it("rejects malformed zero and exponent text", function()
	for _, text in { "", "+", "-", ".", "+.", "0..0", "00x", "0e", "0e+", "1e1.5" } do
		expect(Big.from(text)).toBe(nil)
	end
end)

it("enforces the 256-byte limit before stripping whitespace", function()
	expectPair(string.rep("0", 256), 0, 0)
	expectPair(string.rep(" ", 255) .. "1", 1, 0)
	expectPair(string.rep("0", 254) .. "e0", 0, 0)
	for _, text in
		{
			string.rep("0", 257),
			string.rep(" ", 256) .. "1",
			string.rep("0", 255) .. "e0",
			string.rep("0", 8000) .. "e0",
		}
	do
		expect(Big.from(text)).toBe(nil)
	end
end)

it("keeps number and stored-pair inputs independent of the text limit", function()
	expectPair(1.5e300, 1.5, 300)
	expectPair({ 1.5, 400 }, 1.5, 400)
	expectPair({ M = -1.5, E = -400 }, -1.5, -400)
end)

it("rejects oversized accessor writes and operands without changing the balance", function()
	local h = TestCtx.make({ Template = { Coins = Scribe.Big(10) } })
	local _, entry, data = h.Join(97451)
	local oversized = string.rep("0", 8000) .. "e0"
	for _, write in
		{ data.Coins.Set, data.Coins.Increment, data.Coins.Decrement, data.Coins.Multiply, data.Coins.Divide }
	do
		expect(function()
			write(oversized)
		end).toThrow()
		expect(data.Coins.Get():ToNumber()).toBe(10)
	end
	expect(function()
		return data.Coins.Get() + oversized
	end).toThrow()
	expect(entry.LiveData.Coins[1]).toBe(1)
	expect(entry.LiveData.Coins[2]).toBe(1)
	h.Cleanup()
end)
