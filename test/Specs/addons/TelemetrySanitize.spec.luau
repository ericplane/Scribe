--!nonstrict

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect

local Root = script.Parent.Parent.Parent.Parent
local Sanitize = require(Root.Addons.Telemetry.ScribeTelemetry.Sanitize)
local OMITTED = "[oversized text omitted]"

it("preserves profile-key redaction boundaries and adjacent matches", function()
	for _, case in
		{
			{ "PLAYER_123", "PLAYER_[player]" },
			{ "user-data_42", "user-data_[player]" },
			{ "123user_42", "123user_42" },
			{ "123-user_42", "123-user_[player]" },
			{ "12-_42", "12-_42" },
			{ "-a_1", "-a_[player]" },
			{ "a_123b_456", "a_[player]b_456" },
			{ "a_123-b_456", "a_[player]-b_[player]" },
			{ "_a_1", "_a_[player]" },
			{ "a_123abc-foo_9", "a_[player]abc-foo_[player]" },
			{ "\u{00E9}user_42", "\u{00E9}user_[player]" },
			{ "underscore_name_99", "underscore_name_[player]" },
			{ "Player = 42; userId: 65", "Player = [player]; userId: [player]" },
		}
	do
		expect(Sanitize.Text(case[1], 4096)).toBe(case[2])
	end
end)

it("matches the previous profile-key rules across short mixed strings", function()
	local alphabet = { "a", "Z", "0", "4", "-", "_", " ", ".", "\u{00E9}" }
	local seed = 37
	for _ = 1, 500 do
		local chars = {}
		for _ = 1, 64 do
			seed = (seed * 16807) % 2147483647
			table.insert(chars, alphabet[seed % #alphabet + 1])
		end
		local text = table.concat(chars)
		local expected = string.gsub(text, "(%f[%w][%a][%w%-]*_)%d+", "%1[player]")
		expect(Sanitize.Text(text, 4096)).toBe(expected)
	end
end)

it("handles long failing prefixes and still redacts a valid suffix", function()
	local text = string.rep("a-", 2048)
	expect(Sanitize.Text(text, 4096)).toBe(text)
	local prefix = string.rep("a-", 1900)
	expect(Sanitize.Text(prefix .. "name_42", 4096)).toBe(prefix .. "name_[player]")
end)

it("omits raw strings above 4096 bytes before cleaning or redacting", function()
	local boundary = string.rep("x", 4096)
	expect(Sanitize.Text(boundary, 5000)).toBe(boundary)
	expect(Sanitize.Text(boundary .. "x", 5000)).toBe(OMITTED)
	expect(Sanitize.Text(string.rep("\0", 4097) .. "safe", 5000)).toBe(OMITTED)
	expect(Sanitize.Text(boundary .. "x", 5000, { IncludePlayerIds = true })).toBe(OMITTED)
end)

it("omits oversized secrets wholly and keeps bounded URLs and custom prefixes private", function()
	local url = "https://example.com/private/" .. string.rep("secret", 800)
	expect(Sanitize.Text(url, 10000, { Urls = { url } })).toBe(OMITTED)
	local options = { Urls = { "https://example.com/private/token" }, KeyPrefix = "p.%_" }
	expect(Sanitize.Text("https://example.com/private/token p.%_42", 1000, options)).toBe("[webhook url] p.%_[player]")
	expect(Sanitize.Text("https://proxy.example/api/webhooks/42/token", 1000)).toBe("[webhook url]")
	expect(Sanitize.Text("PLAYER_42", 1000, { IncludePlayerIds = true })).toBe("PLAYER_42")
end)

it("keeps omission markers and Unicode output within even tiny byte limits", function()
	local text = string.rep("x", 4097)
	for _, limit in { 0, 1, 2, 3, 4, 10, 23 } do
		local out = Sanitize.Text(text, limit)
		expect(#out <= limit).toBe(true)
		expect(utf8.len(out) ~= nil).toBe(true)
	end
	local out = Sanitize.Text(string.rep("\u{00E9}", 30), 10)
	expect(#out <= 10).toBe(true)
	expect(utf8.len(out) ~= nil).toBe(true)
end)

it("omits oversized context keys and values before inspecting their contents", function()
	local key = string.rep("a-", 3000) .. "UserId"
	local result = Sanitize.Snapshot({ [key] = 12345, Note = string.rep("a-", 3000) })
	expect(result[OMITTED]).toBe(OMITTED)
	expect(result.Note).toBe(OMITTED)
	expect(result[key]).toBe(nil)
end)

it("does not hash oversized subject keys or bypass the cap when identifiers are allowed", function()
	local key = string.rep("a-", 3000)
	expect(Sanitize.Subject({ Key = key })).toBe("key:" .. OMITTED)
	expect(Sanitize.Subject({ Key = key }, { IncludePlayerIds = true })).toBe("key:" .. OMITTED)
	expect(Sanitize.Subject({ Board = key })).toBe("board:" .. OMITTED)
	expect(Sanitize.Subject({ UserId = key })).toBe("[player]")
	expect(Sanitize.Subject({ Key = "PLAYER_42" })).toBe("key:#bec797")
end)

it("bounds context traversal even when every value is unsupported", function()
	local context = {}
	for index = 1, 100 do
		context[index] = function() end
	end
	local result = Sanitize.Snapshot(context)
	expect(result["..."]).toBe("more keys omitted")
	local count = 0
	for _ in result do
		count += 1
	end
	expect(count).toBe(1)
end)
