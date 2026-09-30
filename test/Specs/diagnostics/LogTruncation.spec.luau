--!nonstrict
-- The 400-byte message cut could split a character, leaving invalid UTF-8 that no
-- sink could JSON-encode.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect

local Root = script.Parent.Parent.Parent.Parent
local Log = require(Root.Scribe.Internal.Log)

local function recent(marker: string)
	for _, entry in Log.GetRecent({ Code = "PROFILE_RESET", Limit = 50 }) do
		if entry.Context ~= nil and entry.Context.Marker == marker then
			return entry
		end
	end
	return nil
end

it("cuts a long message on a character boundary", function()
	-- 399 ASCII bytes, then a three-byte character straddling byte 400.
	local message = string.rep("a", 399) .. "\u{20AC}" .. string.rep("b", 20)
	Log.Warn("Persistence", "PROFILE_RESET", message, { Marker = "boundary" })
	local entry = recent("boundary")
	expect(entry).never.toBeNil()
	local body = string.sub(entry.Message, 1, -4)
	expect(`valid={tostring(utf8.len(entry.Message) ~= nil)} tail={string.sub(entry.Message, -3)} kept={#body}`).toBe(
		"valid=true tail=\u{2026} kept=399"
	)
end)

it("keeps a whole character that ends exactly on the limit", function()
	local message = string.rep("a", 397) .. "\u{20AC}" .. string.rep("b", 20)
	Log.Warn("Persistence", "PROFILE_RESET", message, { Marker = "exact" })
	local entry = recent("exact")
	expect(entry).never.toBeNil()
	local body = string.sub(entry.Message, 1, -4)
	expect(
		`valid={tostring(utf8.len(entry.Message) ~= nil)} kept={#body} euro={tostring(
			string.sub(body, -3) == "\u{20AC}"
		)}`
	).toBe("valid=true kept=400 euro=true")
end)

it("leaves a short message alone", function()
	Log.Warn("Persistence", "PROFILE_RESET", "short \u{20AC}", { Marker = "short" })
	local entry = recent("short")
	expect(entry).never.toBeNil()
	expect(entry.Message).toBe("short \u{20AC}")
end)
