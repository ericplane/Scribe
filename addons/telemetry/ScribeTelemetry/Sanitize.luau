--!strict
-- Small plain data safe to serialize: bounded UTF-8 strings, webhook URLs and player
-- identifiers redacted, no functions, threads or Roblox objects.

local Sanitize = {}

local ELLIPSIS = "\u{2026}"
local ELLIPSIS_BYTES = #ELLIPSIS

export type Options = {
	IncludePlayerIds: boolean?,
	Urls: { string }?, -- configured endpoint URLs, redacted wherever they appear
	KeyPrefix: string?, -- the profile key prefix; it and the digits after it are redacted
}

local function escapePattern(s: string): string
	return (string.gsub(s, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

-- A profile key may carry any prefix or none, so a key field is redacted whatever it holds.
local function isKeyField(name: string): boolean
	return name == "Key" or string.match(name, "%wKey$") ~= nil
end

-- A stable stand-in, so reports about one key still group without naming it.
local function digest(s: string): string
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + string.byte(s, i)) % 16777216
	end
	return string.format("%06x", h)
end

--- Cuts `s` to at most `maxBytes` bytes without splitting a UTF-8 sequence, ending in an
--- ellipsis when it was cut.
function Sanitize.Truncate(s: string, maxBytes: number): string
	if #s <= maxBytes then
		return s
	end
	if maxBytes <= 0 then
		return ""
	end
	local keep = math.max(0, maxBytes - ELLIPSIS_BYTES)
	-- Back up off any continuation byte so the cut lands on a character boundary.
	while keep > 0 do
		local byte = string.byte(s, keep + 1)
		if byte == nil or byte < 0x80 or byte >= 0xC0 then
			break
		end
		keep -= 1
	end
	return string.sub(s, 1, keep) .. ELLIPSIS
end

-- Any host with Discord's path carries a token, configured or not.
local WEBHOOK_PATTERNS = {
	"https?://[%w%.%-]+/api/webhooks/%S+",
}

local function redactUrls(s: string, urls: { string }?): string
	if urls == nil then
		return s
	end
	for _, url in urls do
		local start = 1
		while true do
			local i, j = string.find(s, url, start, true)
			if i == nil or j == nil then
				break
			end
			s = string.sub(s, 1, i - 1) .. "[webhook url]" .. string.sub(s, j + 1)
			start = i + #"[webhook url]"
		end
	end
	return s
end

-- Identifiers a report may not carry unless the developer opted in.
local PLAYER_KEY_PATTERNS =
	{ "[Uu]ser[Ii][Dd]$", "[Pp]layer[Ii][Dd]$", "^[Pp]layer$", "^Recipient[Ii][Dd]$", "^Buyer[Ii][Dd]$" }
local PLAYER_PATTERNS = {
	{ "([Uu]ser[Ii][Dd]%s*[=:]%s*)%d+", "%1[player]" },
	{ "([Pp]layer%s*[=:]%s*)%d+", "%1[player]" },
	{ "(%f[%w][%a][%w%-]*_)%d+", "%1[player]" },
}

--- A string the report may carry: control characters dropped, webhook URLs and (unless
--- allowed) player identifiers redacted, bounded to `maxBytes`.
function Sanitize.Text(value: any, maxBytes: number, options: Options?): string
	local s = if type(value) == "string" then value else tostring(value)
	s = string.gsub(s, "[%c]", function(c)
		return if c == "\n" or c == "\t" then c else ""
	end)
	s = redactUrls(s, if options then options.Urls else nil)
	for _, pattern in WEBHOOK_PATTERNS do
		s = string.gsub(s, pattern, "[webhook url]")
	end
	if not (options and options.IncludePlayerIds) then
		for _, rule in PLAYER_PATTERNS do
			s = string.gsub(s, rule[1], rule[2])
		end
		local prefix = if options then options.KeyPrefix else nil
		if prefix ~= nil and prefix ~= "" and prefix ~= "PLAYER_" then
			s = string.gsub(s, escapePattern(prefix) .. "%d+", string.gsub(prefix, "%%", "%%%%") .. "[player]")
		end
	end
	return Sanitize.Truncate(s, maxBytes)
end

local MAX_KEYS = 12
local MAX_DEPTH = 2
local MAX_VALUE_BYTES = 200

local function isFinite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

local function snapshot(value: any, depth: number, options: Options?): any
	local t = typeof(value)
	if t == "string" then
		return Sanitize.Text(value, MAX_VALUE_BYTES, options)
	elseif t == "number" then
		return if isFinite(value) then value else tostring(value)
	elseif t == "boolean" then
		return value
	elseif t == "Instance" then
		if value:IsA("Player") then
			return if options and options.IncludePlayerIds then `Player:{value.UserId}` else "[player]"
		end
		return `{value.ClassName}:{Sanitize.Text(value.Name, 64, options)}`
	elseif t == "table" then
		if depth >= MAX_DEPTH then
			return "[table]"
		end
		local out: { [string]: any } = {}
		local kept = 0
		for key, child in value do
			if kept >= MAX_KEYS then
				out["..."] = "more keys omitted"
				break
			end
			local keyText = if type(key) == "string" then key else tostring(key)
			local snap = snapshot(child, depth + 1, options)
			if snap ~= nil and not (options and options.IncludePlayerIds) and type(child) ~= "table" then
				for _, pattern in PLAYER_KEY_PATTERNS do
					if string.match(keyText, pattern) then
						snap = "[player]"
						break
					end
				end
				if isKeyField(keyText) then
					snap = "[key]"
				end
			end
			if snap ~= nil then
				out[Sanitize.Text(keyText, 64, options)] = snap
				kept += 1
			end
		end
		return out
	end
	return nil
end

--- A small plain-data copy of a context table: at most 12 keys, two levels, scalars only.
function Sanitize.Snapshot(context: any, options: Options?): { [string]: any }?
	if type(context) ~= "table" then
		return nil
	end
	local snap = snapshot(context, 0, options)
	return if type(snap) == "table" then snap else nil
end

--- A bounded subject for grouping: the key or user a context names, or nil.
function Sanitize.Subject(context: any, options: Options?): string?
	if type(context) ~= "table" then
		return nil
	end
	local player = context.Player
	if typeof(player) == "Instance" and player:IsA("Player") then
		return if options and options.IncludePlayerIds then `user:{player.UserId}` else "[player]"
	end
	for _, field in { "UserId", "Key", "Board", "Product", "ProductId", "Subject" } do
		local value = context[field]
		if type(value) == "string" or type(value) == "number" then
			local text = Sanitize.Text(value, 48, options)
			if not (options and options.IncludePlayerIds) then
				if field == "UserId" then
					return "[player]"
				elseif field == "Key" then
					return `key:#{digest(tostring(value))}`
				end
			end
			return `{string.lower(field)}:{text}`
		end
	end
	return nil
end

return Sanitize
