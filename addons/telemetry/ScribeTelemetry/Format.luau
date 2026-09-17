--!strict
-- One report record to one Discord webhook payload, branded and bounded to Discord's limits.

local Sanitize = require(script.Parent.Sanitize)

local Format = {}

export type Field = { Name: string, Value: string, Inline: boolean? }

export type Report = {
	Id: string,
	Kind: string, -- Issue, Warning, Repeat, Health, Performance, Summary, Test
	Category: string,
	Severity: string, -- Fatal, Error, Warn, Outage, Degraded, Recovery, Info
	Title: string,
	Code: string?,
	Description: string,
	Fields: { Field },
	At: number, -- wall clock seconds
	MentionKind: string?,
	Priority: number, -- 3 first, 1 last, when the queue has to choose
}

export type Meta = {
	PlaceId: number,
	PlaceVersion: number,
	JobId: string,
	ScribeVersion: string,
	Environment: string,
}

-- Discord's limits, in characters; applied here in bytes, which is never looser.
local TITLE_MAX = 256
local DESCRIPTION_MAX = 4096
local FIELD_NAME_MAX = 256
local FIELD_VALUE_MAX = 1024
local FOOTER_MAX = 2048
local FIELDS_MAX = 25
local EMBED_TOTAL_MAX = 6000

Format.COLORS = {
	Fatal = 0xB91C1C,
	Error = 0xE5484D,
	Warn = 0xF5A524,
	Outage = 0xE5484D,
	Degraded = 0xF5A524,
	Recovery = 0x34D399,
	Performance = 0xF97316,
	Info = 0x3B82F6,
}

local function isoTimestamp(at: number): string
	local ok, text = pcall(function()
		return os.date("!%Y-%m-%dT%H:%M:%SZ", at)
	end)
	return if ok then text else ""
end

local function utcClock(at: number): string
	local ok, text = pcall(function()
		return os.date("!%H:%M:%S UTC", at)
	end)
	return if ok then text else ""
end

--- The browser link into this server.
function Format.JoinUrl(meta: Meta): string
	return `https://www.roblox.com/games/start?placeId={meta.PlaceId}&gameInstanceId={meta.JobId}`
end

local function utf8Length(s: string): number
	local ok, n = pcall(function()
		return utf8.len(s)
	end)
	return if ok and n then n else #s
end

--- The payload for one destination. `mention` is the role id to ping, already decided
--- by the caller's severity and cooldown rules; nil sends with every mention parse off.
function Format.Payload(
	report: Report,
	meta: Meta,
	brand: { Name: string, IconUrl: string },
	mention: string?
): { [string]: any }
	local title = Sanitize.Truncate(report.Title, TITLE_MAX)
	local description = Sanitize.Truncate(report.Description, DESCRIPTION_MAX)
	local fields: { { [string]: any } } = {}
	local function add(name: string, value: string, inline: boolean?)
		if #fields >= FIELDS_MAX then
			return
		end
		local cell: { [string]: any } = {
			name = Sanitize.Truncate(name, FIELD_NAME_MAX),
			value = Sanitize.Truncate(if value == "" then "\u{2014}" else value, FIELD_VALUE_MAX),
			inline = inline == true,
		}
		table.insert(fields, cell)
	end
	for _, field in report.Fields do
		add(field.Name, field.Value, field.Inline)
	end
	-- Identity on health and summaries; a join link everywhere.
	if report.Kind == "Health" or report.Kind == "Summary" then
		add("Place", `{meta.PlaceId} v{meta.PlaceVersion}`, true)
		add("Scribe", meta.ScribeVersion, true)
	end
	if meta.PlaceId > 0 and meta.JobId ~= "" then
		add("Server", `[Join {string.sub(meta.JobId, 1, 8)}]({Format.JoinUrl(meta)})`, true)
	end
	local footer = Sanitize.Truncate(
		`{report.Id} \u{00B7} v{meta.PlaceVersion} \u{00B7} {meta.Environment} \u{00B7} {utcClock(report.At)}`,
		FOOTER_MAX
	)

	-- Fields past the 6000 are dropped from the end; the description takes what is left.
	local used = utf8Length(title) + utf8Length(footer) + utf8Length(brand.Name)
	for _, field in fields do
		used += utf8Length(field.name) + utf8Length(field.value)
	end
	while #fields > 0 and used > EMBED_TOTAL_MAX do
		local last = table.remove(fields) :: { [string]: any }
		used -= utf8Length(last.name) + utf8Length(last.value)
	end
	local room = EMBED_TOTAL_MAX - used
	if utf8Length(description) > room then
		description = Sanitize.Truncate(description, math.max(0, room))
	end

	local embed: { [string]: any } = {
		author = { name = brand.Name, icon_url = brand.IconUrl },
		title = title,
		description = description,
		color = Format.COLORS[report.Severity] or Format.COLORS.Info,
		fields = fields,
		footer = { text = footer },
		timestamp = isoTimestamp(report.At),
	}
	local payload: { [string]: any } = {
		username = brand.Name,
		avatar_url = brand.IconUrl,
		embeds = { embed },
		allowed_mentions = { parse = {} },
	}
	if mention ~= nil then
		payload.content = `<@&{mention}>`
		payload.allowed_mentions = { parse = {}, roles = { mention } }
	end
	return payload
end

return Format
