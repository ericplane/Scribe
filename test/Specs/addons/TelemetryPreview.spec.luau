--!nonstrict
-- Preview: every report design to one destination, labelled, and the live state untouched.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Preview = require(Root.Addons.Telemetry.ScribeTelemetry.Preview)
	local H = require(Root.Test.Helpers.TelemetryHarness)

	local MENTION_ALL = { "Fatal", "Error", "Outage", "Degraded", "Recovery", "Performance" }

	local function two(extra)
		local options = {
			Webhooks = {
				Alerts = { Url = H.URL_A, Mention = { RoleId = "123", On = MENTION_ALL, Cooldown = 600 } },
				Other = { Url = H.URL_B },
			},
			Default = "Alerts",
			Routes = { Summaries = "Other" },
		}
		for key, value in extra or {} do
			options[key] = value
		end
		return H.start(options)
	end

	it("sends every scenario to the named destination, titled PREVIEW, labelled, and never mentioning", function()
		local h = two()
		local before = h.Telemetry:GetStats().Reports
		local ok, why = h.Telemetry:Preview("Alerts", "All")
		h.Telemetry:Flush(60)
		local toA, toB = h.Http.For(H.URL_A), h.Http.For(H.URL_B)
		local prefixed, labelled, mentions = 0, 0, 0
		for _, request in toA do
			local embed = request.Payload.embeds[1]
			if string.sub(embed.title, 1, 9) == "PREVIEW: " then
				prefixed += 1
			end
			for _, field in embed.fields do
				if field.name == "Preview" then
					labelled += 1
				end
			end
			if request.Payload.content ~= nil or request.Payload.allowed_mentions.roles ~= nil then
				mentions += 1
			end
		end
		local stats = h.Telemetry:GetStats()
		h.Telemetry:Stop()
		local n = #Preview.SCENARIOS
		expect(
			`ok={ok} why={tostring(why)} toA={#toA} toB={#toB} prefixed={prefixed} labelled={labelled} mentions={mentions} previews={stats.Previews} reports={stats.Reports - before}`
		).to.equal(`ok=true why=nil toA={n} toB=0 prefixed={n} labelled={n} mentions=0 previews={n} reports=0`)
	end)

	it("a group sends its scenarios in order and a name sends one", function()
		local h = two()
		h.Telemetry:Preview("Alerts", "Health")
		h.Telemetry:Flush(60)
		local health = h.Http.Titles(H.URL_A)
		h.Telemetry:Preview("Other", "Outage")
		h.Telemetry:Flush(60)
		local one = h.Http.Titles(H.URL_B)
		h.Telemetry:Stop()
		expect(`{health} | {one}`).to.equal(
			"PREVIEW: Scribe Telemetry started | PREVIEW: Degraded (was Healthy) | PREVIEW: Outage (was Degraded) | PREVIEW: Partial recovery: Outage \u{2192} Degraded | PREVIEW: Recovered: Degraded \u{2192} Healthy | PREVIEW: Outage | PREVIEW: Outage (was Degraded)"
		)
	end)

	it("refuses an unknown kind, an unknown or disabled destination, a stopped add-on and Studio", function()
		local h = H.start({
			Webhooks = {
				Alerts = { Url = H.URL_A },
				Off = { Url = H.URL_B, Enabled = false },
			},
		})
		local kind = { h.Telemetry:Preview("Alerts", "Sometimes") }
		local unknown = { h.Telemetry:Preview("Nowhere", "All") }
		local disabled = { h.Telemetry:Preview("Off", "All") }
		h.Telemetry:Flush(60)
		local sent = #h.Http.Requests
		h.Telemetry:Stop()
		local stopped = { h.Telemetry:Preview("Alerts", "All") }
		local studio = H.start({ Webhooks = { Alerts = { Url = H.URL_A } }, Studio = true })
		local inStudio = { studio.Telemetry:Preview("Alerts", "All") }
		studio.Telemetry:Stop()
		expect(
			`kind={kind[1]}:{kind[2]} unknown={unknown[1]}:{unknown[2]} disabled={disabled[1]}:{disabled[2]} sent={sent} stopped={stopped[1]}:{stopped[2]} studio={inStudio[1]}:{inStudio[2]}`
		).to.equal(
			'kind=false:no preview named "Sometimes" unknown=false:no destination named "Nowhere" disabled=false:destination is disabled sent=0 stopped=false:Stopped studio=false:DisabledInStudio'
		)
	end)

	it("leaves the summary baseline, the rule state, the groups and the mention cooldown untouched", function()
		local h = H.start({
			Webhooks = { Alerts = { Url = H.URL_A, Mention = { RoleId = "123", On = { "Fatal" }, Cooldown = 600 } } },
			Default = "Alerts",
			Summaries = { Enabled = true, Interval = 600 },
			Performance = { Interval = 60, Checks = 1, Rules = { SaveFailures = { Threshold = 1 } } },
		}, function(scribe)
			scribe.Metrics = { SavesOk = 0, SavesFailed = 0, SaveDuration = { Count = 0 } }
		end)
		h.Advance(300)
		h.Telemetry:Preview("Alerts", "All")
		h.Telemetry:Preview("Alerts", "SaveFailures")
		h.Telemetry:Flush(60)
		local previews = #h.Http.Requests
		h.Scribe.Metrics = { SavesOk = 5, SavesFailed = 0, SaveDuration = { Count = 5 } }
		h.Scribe.Log("Fatal", "LOAD_FAILED", "Persistence", "a real one", {})
		h.Advance(300)
		h.Telemetry:Flush(60)
		local mention, saves, cleared = "none", "none", 0
		for i = previews + 1, #h.Http.Requests do
			local request = h.Http.Requests[i]
			local embed = request.Payload.embeds[1]
			if embed.title == "Fatal: LOAD_FAILED" then
				mention = tostring(request.Payload.content)
			elseif string.sub(embed.title, 1, 8) == "Summary:" then
				for _, field in embed.fields do
					if field.name == "Saves" then
						saves = field.value
					end
				end
			elseif string.find(embed.title, "cleared", 1, true) then
				cleared += 1
			end
		end
		local stats = h.Telemetry:GetStats()
		h.Telemetry:Stop()
		expect(`mention={mention} saves={saves} cleared={cleared} groups={stats.Groups} reports={stats.Reports}`).to.equal(
			"mention=<@&123> saves=5 ok, 0 failed cleared=0 groups=1 reports=2"
		)
	end)

	it("sanitises like a real report: redacted ids and urls, a bounded message, capped context", function()
		local h = two()
		h.Telemetry:Preview("Alerts", "Formatting")
		h.Telemetry:Flush(60)
		local long, redacted
		for _, request in h.Http.For(H.URL_A) do
			local embed = request.Payload.embeds[1]
			if embed.title == "PREVIEW: Error: LONG_MESSAGE" then
				long = embed
			elseif embed.title == "PREVIEW: Warn: REDACTED" then
				redacted = request
			end
		end
		h.Telemetry:Stop()
		local body = redacted.Body
		expect(
			`descriptionBounded={#long.description <= 1600} fields={#long.fields} rawUrl={string.find(
				body,
				"api/webhooks/1234",
				1,
				true
			) ~= nil} rawId={string.find(body, "1234567", 1, true) ~= nil}`
		).to.equal("descriptionBounded=true fields=11 rawUrl=false rawId=false")
	end)

	it("registers Status and Preview with Scribe while running, and unregisters on Stop", function()
		local h = two()
		local actions = h.Scribe.Addons.Telemetry
		local status = actions.Status.Run({})
		local run = actions.Preview.Run({ Destination = "Other", Kind = "Outage" })
		h.Telemetry:Flush(60)
		local titles = h.Http.Titles(H.URL_B)
		local writes = actions.Preview.Writes
		h.Telemetry:Stop()
		local after = h.Scribe.Addons.Telemetry
		expect(
			`state={status.State} destinations={table.concat(status.Destinations, ",")} kinds={#status.Kinds}:{status.Kinds[1]}/{status.Kinds[2]} run={run.Ok}:{tostring(
				run.Reason
			)} writes={writes} titles={titles} after={tostring(after)}`
		).to.equal(
			`state=Running destinations=Alerts,Other kinds={1 + 7 + #Preview.SCENARIOS}:All/Health run=true:nil writes=true titles=PREVIEW: Outage (was Degraded) after=nil`
		)
	end)

	it("registers its state when disabled in Studio, so the plugin can say why", function()
		local studio = H.start({
			Webhooks = { Alerts = { Url = H.URL_A }, Off = { Url = H.URL_B, Enabled = false } },
			Studio = true,
		})
		local status = studio.Scribe.Addons.Telemetry.Status.Run({})
		local run = studio.Scribe.Addons.Telemetry.Preview.Run({ Destination = "Alerts", Kind = "All" })
		studio.Telemetry:Stop()
		local after = studio.Scribe.Addons.Telemetry
		expect(
			`state={status.State} destinations={table.concat(status.Destinations, ",")} run={run.Ok}:{run.Reason} after={tostring(
				after
			)}`
		).to.equal("state=DisabledInStudio destinations=Alerts run=false:DisabledInStudio after=nil")
	end)

	it("never displaces a real report, and is the first to go when a real one needs room", function()
		local function throttled()
			local h = two({ Limits = { MaxQueued = 1 } })
			local requests = 0
			h.Http.Responder = function()
				requests += 1
				if requests == 1 then
					return { Ok = false, Status = 429, Headers = { ["retry-after"] = "30" }, Body = "" }
				end
				return { Ok = true, Status = 204, Headers = {}, Body = "" }
			end
			return h
		end
		local h = throttled()
		h.Scribe.Log("Fatal", "REAL", "Persistence", "a real alert awaiting retry", {})
		local ok, why = h.Telemetry:Preview("Alerts", "Outage")
		h.Advance(31)
		h.Telemetry:Flush(60)
		local realFirst = `preview={ok}:{tostring(why)} titles={h.Http.Titles(H.URL_A)}`
		h.Telemetry:Stop()
		h = throttled()
		h.Telemetry:Preview("Alerts", "Outage")
		h.Scribe.Log("Fatal", "REAL", "Persistence", "a real alert needs the slot", {})
		h.Advance(31)
		h.Telemetry:Flush(60)
		local previewFirst = h.Http.Titles(H.URL_A)
		h.Telemetry:Stop()
		expect(`{realFirst} | {previewFirst}`).to.equal(
			"preview=false:queue is full titles=Fatal: REAL | Fatal: REAL | PREVIEW: Outage (was Degraded) | Fatal: REAL"
		)
	end)

	--- Two webhooks whose every request is throttled, so what is queued stays queued.
	local function throttledTwo(limits)
		local h = two({ Limits = limits })
		h.Http.Responder = function()
			return { Ok = false, Status = 429, Headers = { ["retry-after"] = "30" }, Body = "" }
		end
		return h
	end

	local function queued(h)
		local stats = h.Telemetry:GetStats()
		return `alerts={stats.Destinations.Alerts.Queued} other={stats.Destinations.Other.Queued} overflow={stats.Dropped.Overflow}`
	end

	it("gives a real report the slot a preview holds on another webhook", function()
		local h = throttledTwo({ MaxQueued = 2 })
		h.Scribe.Log("Fatal", "FIRST", "Persistence", "first", {})
		h.Telemetry:Preview("Other", "Outage")
		h.Scribe.Log("Fatal", "SECOND", "Persistence", "second", {})
		local state = queued(h)
		h.Telemetry:Stop()
		expect(state).to.equal("alerts=2 other=0 overflow=1")
	end)

	it("evicts the oldest of equals wherever it is queued", function()
		local h = throttledTwo({ MaxQueued = 2 })
		h.Telemetry:Test("Alerts")
		h.Advance(1)
		h.Telemetry:Test("Other")
		h.Advance(1)
		h.Telemetry:Test("Alerts")
		local state = queued(h)
		h.Telemetry:Stop()
		expect(state).to.equal("alerts=1 other=1 overflow=1")
	end)

	it("routes a real report logged during a preview's delivery as real", function()
		local h = two()
		local logged = false
		h.Http.Responder = function()
			if not logged then
				logged = true
				h.Scribe.Log("Fatal", "REAL", "Persistence", "raised by the transport", {})
			end
			return { Ok = true, Status = 204, Headers = {}, Body = "" }
		end
		h.Telemetry:Preview("Other", "Outage")
		h.Telemetry:Flush(60)
		local toA = h.Http.For(H.URL_A)
		local real = toA[1]
		h.Telemetry:Stop()
		expect(
			`logged={logged} toA={#toA}:{if real then real.Payload.embeds[1].title else "none"} mention={tostring(
				if real then real.Payload.content else nil
			)} toB={h.Http.Titles(H.URL_B)}`
		).to.equal("logged=true toA=1:Fatal: REAL mention=<@&123> toB=PREVIEW: Outage (was Degraded)")
	end)

	it("reports a stop that happens while it is running", function()
		local h = two()
		h.Http.Responder = function()
			h.Telemetry:Stop()
			return { Ok = true, Status = 204, Headers = {}, Body = "" }
		end
		local ok, why = h.Telemetry:Preview("Alerts", "All")
		local previews = h.Telemetry:GetStats().Previews
		expect(`ok={ok} why={why} short={previews < #Preview.SCENARIOS}`).to.equal("ok=false why=Stopped short=true")
	end)

	it("rides the normal queue, so a dead destination refuses", function()
		local h = two()
		h.Http.Responder = function()
			return { Ok = false, Status = 403, Headers = {}, Body = "" }
		end
		h.Telemetry:Test("Alerts")
		h.Telemetry:Flush(60)
		local ok, why = h.Telemetry:Preview("Alerts", "Outage")
		h.Telemetry:Stop()
		expect(`ok={ok} why={string.sub(tostring(why), 1, 19)}`).to.equal("ok=false why=destination is dead")
	end)
end
