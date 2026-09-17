--!nonstrict
-- What a webhook receives: Scribe's branding on every message, Discord's limits held on
-- UTF-8 boundaries, secrets and player identifiers kept out, mentions off unless configured.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local ScribeTelemetry = require(Root.Addons.Telemetry.ScribeTelemetry)
	local Sanitize = require(Root.Addons.Telemetry.ScribeTelemetry.Sanitize)
	local Format = require(Root.Addons.Telemetry.ScribeTelemetry.Format)
	local H = require(Root.Test.Helpers.TelemetryHarness)

	local function field(payload, name)
		for _, f in payload.embeds[1].fields do
			if f.name == name then
				return f.value
			end
		end
		return nil
	end

	it("brands every kind of message with the fixed name and logo, on the author and the webhook", function()
		local h = H.start({
			Summaries = { Enabled = true, Interval = 60 },
			Performance = { Interval = 60, Checks = 1, Rules = { Traffic = { Threshold = 1 } } },
		}, function(scribe)
			scribe.Metrics = { BytesOut = 0 }
		end)
		h.Scribe.Log("Error", "X", "Persistence", "issue", {})
		h.Scribe.Log("Error", "X", "Persistence", "issue", {})
		h.Scribe.Log("Warn", "PROFILE_SIZE", "Persistence", "warning", {})
		h.Scribe.SetStatus("Outage")
		h.Scribe.SetStatus("Healthy")
		h.Scribe.Metrics.BytesOut = 100000
		h.Telemetry:Test("Alerts")
		h.Advance(61)
		local kinds, branded = {}, true
		for _, request in h.Http.Requests do
			local payload = request.Payload
			local embed = payload.embeds[1]
			table.insert(kinds, embed.title)
			if
				payload.username ~= "Scribe Telemetry"
				or payload.avatar_url ~= ScribeTelemetry.LogoUrl
				or embed.author.name ~= "Scribe Telemetry"
				or embed.author.icon_url ~= ScribeTelemetry.LogoUrl
			then
				branded = false
			end
		end
		h.Telemetry:Stop()
		expect(branded).to.equal(true)
		expect(#kinds >= 7).to.equal(true)
		expect(string.find(table.concat(kinds, " | "), "Still occurring: X", 1, true) ~= nil).to.equal(true)
		expect(string.find(table.concat(kinds, " | "), "Summary:", 1, true) ~= nil).to.equal(true)
		expect(string.find(table.concat(kinds, " | "), "Performance: Traffic", 1, true) ~= nil).to.equal(true)
		expect(string.find(table.concat(kinds, " | "), "Test message", 1, true) ~= nil).to.equal(true)
	end)

	it("refuses an attempt to rebrand", function()
		local ok, err = pcall(function()
			return H.start({ IconUrl = "https://example.com/x.png" })
		end)
		expect(`{ok} {err}`).to.equal(
			"false ScribeTelemetry: IconUrl and BrandName are fixed to Scribe's own and cannot be set"
		)
	end)

	it("carries the identifiers a report needs and no mention parsing", function()
		local h = H.start({ Environment = "staging" })
		h.Scribe.Log("Error", "PROFILE_LOAD_FAIL", "Persistence", "could not load", {})
		local payload = h.Http.Requests[1].Payload
		h.Telemetry.meta.JobId = ""
		h.Scribe.Log("Fatal", "SCHEMA_MISMATCH", "Persistence", "no job id", {})
		local second = h.Http.Requests[2].Payload.embeds[1].footer.text
		h.Telemetry:Stop()
		local footer = payload.embeds[1].footer.text
		local id, rest = string.match(footer, "^(.-%-%x%x%x%x) \u{00B7} (.*)$")
		local studioId = string.match(second, "^(.-%-%x%x%x%x) ")
		expect(`id={string.sub(id, -5)} rest={rest} studio={studioId}`).to.equal(
			"id=-0001 rest=v0 \u{00B7} staging \u{00B7} 22:13:20 UTC studio=studio-0002"
		)
		expect(`{field(payload, "Code")} parse={#payload.allowed_mentions.parse} content={tostring(payload.content)}`).to.equal(
			"Persistence/PROFILE_LOAD_FAIL parse=0 content=nil"
		)
	end)

	it("puts the place and library version on health and summary reports, and a join link on every report", function()
		local meta =
			{ PlaceId = 123, PlaceVersion = 7, JobId = "abcdefgh-rest", ScribeVersion = "2.4.0", Environment = "e" }
		local function names(kind: string, placeId: number): string
			local payload = Format.Payload({
				Id = "id",
				Kind = kind,
				Category = "Health",
				Severity = "Info",
				Title = "t",
				Description = "d",
				Fields = { { Name = "Own", Value = "x", Inline = true } },
				At = 0,
				Priority = 1,
			}, {
				PlaceId = placeId,
				PlaceVersion = meta.PlaceVersion,
				JobId = meta.JobId,
				ScribeVersion = meta.ScribeVersion,
				Environment = meta.Environment,
			}, { Name = "n", IconUrl = "u" }, nil)
			local out = {}
			for _, f in payload.embeds[1].fields do
				table.insert(out, `{f.name}={f.value}`)
			end
			return table.concat(out, " | ")
		end
		expect(`{names("Health", 123)} || {names("Summary", 123)} || {names("Issue", 123)} || {names("Issue", 0)}`).to.equal(
			"Own=x | Place=123 v7 | Scribe=2.4.0 | Server=[Join abcdefgh](https://www.roblox.com/games/start?placeId=123&gameInstanceId=abcdefgh-rest)"
				.. " || Own=x | Place=123 v7 | Scribe=2.4.0 | Server=[Join abcdefgh](https://www.roblox.com/games/start?placeId=123&gameInstanceId=abcdefgh-rest)"
				.. " || Own=x | Server=[Join abcdefgh](https://www.roblox.com/games/start?placeId=123&gameInstanceId=abcdefgh-rest)"
				.. " || Own=x"
		)
	end)

	it("redacts a custom profile key prefix as it does the default one", function()
		local h = H.start(nil, function(scribe)
			scribe.KeyPrefix = "user_"
		end)
		h.Scribe.Log("Error", "PROFILE_LOAD_FAIL", "Persistence", "could not load user_123456 after retries", {
			Key = "user_123456",
		})
		local body = h.Http.Requests[1].Body
		h.Telemetry:Stop()
		local leaked = string.find(body, "123456", 1, true) ~= nil
		local redacted = string.find(body, "user_[player]", 1, true) ~= nil
		expect(`leaked={leaked} redacted={redacted}`).to.equal("leaked=false redacted=true")
	end)

	it("redacts a key whatever its prefix, in the context, the subject and a repeat summary", function()
		local h = H.start({ Grouping = { Interval = 30 } }, function(scribe)
			scribe.KeyPrefix = ""
		end)
		h.Scribe.Log("Error", "PROFILE_ERASE_FAIL", "Persistence", "erase failed", { Key = "424242424" })
		h.Scribe.Log("Error", "PROFILE_ERASE_FAIL", "Persistence", "erase failed", { Key = "424242424" })
		h.Scribe.Log("Error", "PROFILE_LOAD_FAIL", "Persistence", "alt_7777777 stalled", { Key = "alt_7777777" })
		h.Scribe.Log("Error", "PROFILE_RESTORE_FAIL", "Persistence", "load failed", { Key = "p:5555555" })
		h.Scribe.KeyPrefix = "u"
		h.Scribe.Log("Error", "PROFILE_SIZE", "Persistence", "profile u3333333 failed", { ProfileKey = "3333333" })
		h.Advance(31)
		local bodies = {}
		for _, request in h.Http.Requests do
			table.insert(bodies, request.Body)
		end
		h.Telemetry:Stop()
		local all = table.concat(bodies, "\n")
		local leaked = {}
		for _, id in { "424242424", "7777777", "5555555", "3333333" } do
			if string.find(all, id, 1, true) then
				table.insert(leaked, id)
			end
		end
		local summaries = 0
		for _, body in bodies do
			if string.find(body, "Still occurring", 1, true) and string.find(body, "key:#%x+") then
				summaries += 1
			end
		end
		expect(`requests={#bodies} keyed={summaries} leaked={table.concat(leaked, ",")}`).to.equal(
			"requests=5 keyed=1 leaked="
		)
	end)

	it("redacts webhook URLs and player identifiers from the message and the context", function()
		local h = H.start({
			Webhooks = { Alerts = { Url = H.URL_A }, Custom = { Url = H.URL_CUSTOM, Enabled = false } },
			Default = "Alerts",
		})
		h.Scribe.Log(
			"Error",
			"X",
			"Persistence",
			`failed for UserId=12345678 posting to https://discord.com/api/webhooks/1/secrettoken and {H.URL_CUSTOM} twice: {H.URL_CUSTOM}`,
			{
				Key = "PLAYER_12345678",
				Url = "https://discord.com/api/webhooks/2/othersecret",
				Proxy = H.URL_PROXY,
				Nested = { userId = 99 },
			}
		)
		local payload = h.Http.Requests[1].Payload
		local body = h.Http.Requests[1].Body
		h.Telemetry:Stop()
		expect(payload.embeds[1].description).to.equal(
			"failed for UserId=[player] posting to [webhook url] and [webhook url] twice: [webhook url]"
		)
		expect(field(payload, "Key")).to.equal("[key]")
		expect(field(payload, "Url")).to.equal("[webhook url]")
		expect(field(payload, "Proxy")).to.equal("[webhook url]")
		expect(string.find(body, "dddddddd", 1, true)).to.equal(nil)
		expect(string.find(body, "eeeeeeee", 1, true)).to.equal(nil)
		expect(string.find(body, "secret", 1, true)).to.equal(nil)
		expect(string.find(body, "12345678", 1, true)).to.equal(nil)
	end)

	it("redacts a numeric player id by its field name, at any depth", function()
		local context =
			{ UserId = 12345678, RecipientId = 87654321, Count = 3, Nested = { FromUserId = 42, Kind = "gift" } }
		local h = H.start()
		h.Scribe.Log("Error", "GIFT_DELIVERY_RETRY", "Gifting", "retrying", context)
		local payload = h.Http.Requests[1].Payload
		local body = h.Http.Requests[1].Body
		h.Telemetry:Stop()
		local kept = H.start({ IncludePlayerIds = true })
		kept.Scribe.Log("Error", "GIFT_DELIVERY_RETRY", "Gifting", "retrying", context)
		local keptPayload = kept.Http.Requests[1].Payload
		kept.Telemetry:Stop()
		expect(
			`{field(payload, "UserId")} {field(payload, "RecipientId")} {field(payload, "Count")} nested={field(
				payload,
				"Nested"
			)}`
		).to.equal("[player] [player] 3 nested=FromUserId=[player], Kind=gift")
		expect(string.find(body, "12345678", 1, true) == nil and string.find(body, "87654321", 1, true) == nil).to.equal(
			true
		)
		expect(`{field(keptPayload, "UserId")} {field(keptPayload, "RecipientId")}`).to.equal("12345678 87654321")
	end)

	it("keeps player identifiers when asked to", function()
		local h = H.start({ IncludePlayerIds = true })
		h.Scribe.Log("Error", "X", "Persistence", "UserId=12345678", { Key = "PLAYER_12345678" })
		local payload = h.Http.Requests[1].Payload
		h.Telemetry:Stop()
		expect(`{payload.embeds[1].description} {field(payload, "Key")}`).to.equal("UserId=12345678 PLAYER_12345678")
	end)

	it("never serializes a function, thread or Roblox object, and bounds the context", function()
		local h = H.start()
		local big = {}
		for i = 1, 40 do
			big[`k{i}`] = i
		end
		h.Scribe.Log("Error", "X", "Persistence", "m", {
			Fn = function() end,
			Thread = coroutine.create(function() end),
			Deep = { a = { b = { c = 1 } } },
			Big = big,
			Plain = "kept",
		})
		local payload = h.Http.Requests[1].Payload
		local names = {}
		for _, f in payload.embeds[1].fields do
			table.insert(names, f.name)
		end
		table.sort(names)
		h.Telemetry:Stop()
		expect(table.concat(names, ",")).to.equal("At,Big,Code,Deep,Plain")
		expect(string.find(field(payload, "Deep"), "[table]", 1, true) ~= nil).to.equal(true)
	end)

	it("truncates on a UTF-8 boundary and holds every Discord limit", function()
		local cut = Sanitize.Truncate(string.rep("\u{00E9}", 100), 11)
		expect(`{#cut} {utf8.len(cut) ~= nil}`).to.equal("11 true")

		local h = H.start()
		-- Enough capped fields to overshoot the 6000.
		h.Scribe.Log("Error", "X", "Persistence", string.rep("\u{00E9}", 5000), {
			Big = string.rep("x", 3000),
			Big2 = string.rep("y", 3000),
			Big3 = string.rep("z", 3000),
			Big4 = string.rep("w", 3000),
		})
		local embed = h.Http.Requests[1].Payload.embeds[1]
		local total = utf8.len(embed.title)
			+ utf8.len(embed.description)
			+ utf8.len(embed.footer.text)
			+ utf8.len(embed.author.name)
		for _, f in embed.fields do
			total += utf8.len(f.name) + utf8.len(f.value)
		end
		h.Telemetry:Stop()
		expect(
			`valid={utf8.len(embed.description) ~= nil} total={total <= 6000} field={#field(
				h.Http.Requests[1].Payload,
				"Big"
			) <= 1024}`
		).to.equal("valid=true total=true field=true")
	end)

	it("never appends the identity fields past Discord's cap of 25", function()
		local fields = {}
		for i = 1, 25 do
			table.insert(fields, { Name = `F{i}`, Value = "x", Inline = true })
		end
		local payload = Format.Payload({
			Id = "id",
			Kind = "Health",
			Category = "Health",
			Severity = "Info",
			Title = "t",
			Description = "d",
			Fields = fields,
			At = 0,
			Priority = 3,
		}, { PlaceId = 123, PlaceVersion = 1, JobId = "abcdefgh", ScribeVersion = "2.4.0", Environment = "e" }, {
			Name = "n",
			IconUrl = "u",
		}, nil)
		expect(#payload.embeds[1].fields).to.equal(25)
	end)

	it("leaves the description empty when the fields already fill the embed", function()
		local meta = { PlaceId = 0, PlaceVersion = 0, JobId = "job", ScribeVersion = "0", Environment = "e" }
		local brand = { Name = "n", IconUrl = "u" }
		local function payloadWith(fields)
			return Format.Payload({
				Id = "id",
				Kind = "Issue",
				Category = "Issues",
				Severity = "Error",
				Title = "title",
				Description = "some description",
				Fields = fields,
				At = 0,
				Priority = 3,
			}, meta, brand, nil)
		end
		local bare = payloadWith({}).embeds[1]
		local fixed = utf8.len(bare.title) + utf8.len(bare.footer.text) + utf8.len(bare.author.name)
		-- Fields sized to fill exactly what the title, footer and author leave of the 6000.
		local fields = {}
		for i = 1, 5 do
			table.insert(fields, { Name = `F{i}`, Value = string.rep("v", 998), Inline = false })
		end
		table.insert(fields, { Name = "F6", Value = string.rep("v", 6000 - fixed - 5000 - 2), Inline = false })
		local embed = payloadWith(fields).embeds[1]
		local total = utf8.len(embed.title)
			+ utf8.len(embed.description)
			+ utf8.len(embed.footer.text)
			+ utf8.len(embed.author.name)
		for _, f in embed.fields do
			total += utf8.len(f.name) + utf8.len(f.value)
		end
		expect(`fields={#embed.fields} description={#embed.description} total={total}`).to.equal(
			"fields=6 description=0 total=6000"
		)
	end)

	it("drops trailing fields and shrinks the description to hold the 6000 across the embed", function()
		local fields = {}
		for i = 1, 25 do
			table.insert(fields, { Name = `F{i}`, Value = string.rep("v", 2000), Inline = false })
		end
		local payload = Format.Payload({
			Id = "id",
			Kind = "Issue",
			Category = "Issues",
			Severity = "Error",
			Title = "title",
			Description = string.rep("d", 5000),
			Fields = fields,
			At = 0,
			Priority = 3,
		}, { PlaceId = 0, PlaceVersion = 0, JobId = "job", ScribeVersion = "0", Environment = "e" }, {
			Name = "n",
			IconUrl = "u",
		}, nil)
		local embed = payload.embeds[1]
		local total = utf8.len(embed.title)
			+ utf8.len(embed.description)
			+ utf8.len(embed.footer.text)
			+ utf8.len(embed.author.name)
		for _, f in embed.fields do
			total += utf8.len(f.name) + utf8.len(f.value)
		end
		expect(
			`fields={#embed.fields} first={#embed.fields[1].value} total={total <= 6000} description={#embed.description > 0}`
		).to.equal("fields=5 first=1024 total=true description=true")
	end)
end
