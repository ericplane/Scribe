--!nonstrict
-- Health transitions: what is reported, in what words, in what order, and what is not.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local H = require(Root.Test.Helpers.TelemetryHarness)

	local function field(payload, name)
		for _, f in payload.embeds[1].fields do
			if f.name == name then
				return f.value
			end
		end
		return nil
	end

	it("says nothing at a healthy start, and reports an incident already underway as such", function()
		local quiet = H.start()
		local quietCount = #quiet.Http.Requests
		quiet.Telemetry:Stop()

		local h = H.start(nil, function(scribe)
			scribe.Status = "Outage"
		end)
		local payload = h.Http.Requests[1].Payload
		h.Telemetry:Stop()
		expect(`quiet={quietCount} title={payload.embeds[1].title} observed={field(payload, "Observed")}`).to.equal(
			"quiet=0 title=Outage observed=already active when telemetry started; its start time is not known here"
		)
	end)

	it("reports degraded, outage, partial recovery and full recovery with the observed duration", function()
		local h = H.start()
		h.Scribe.SetStatus("Degraded")
		h.Advance(90)
		h.Scribe.SetStatus("Outage")
		h.Advance(30)
		h.Scribe.SetStatus("Degraded")
		h.Advance(5)
		h.Scribe.SetStatus("Healthy")
		local titles = h.Http.Titles()
		local observed = field(h.Http.Requests[2].Payload, "Observed")
		local colors = {}
		for _, request in h.Http.Requests do
			table.insert(colors, request.Payload.embeds[1].color)
		end
		h.Telemetry:Stop()
		expect(titles).to.equal(
			"Degraded (was Healthy) | Outage (was Degraded) | Partial recovery: Outage \u{2192} Degraded | Recovered: Degraded \u{2192} Healthy"
		)
		expect(observed).to.equal("1m 30s in Degraded before this change")
		expect(`{colors[2]} {colors[4]}`).to.equal("15026253 3462041")
	end)

	it("keeps a destination's health reports in order across a throttle, and never claims a global verdict", function()
		local h = H.start()
		local calls = 0
		h.Http.Responder = function()
			calls += 1
			if calls == 1 then
				return { Ok = false, Status = 429, Headers = {}, Body = '{"retry_after": 3.0}' }
			end
			return { Ok = true, Status = 204, Headers = {}, Body = "" }
		end
		h.Scribe.SetStatus("Outage")
		h.Scribe.SetStatus("Healthy")
		h.Advance(10)
		local titles = {}
		for _, request in h.Http.Requests do
			if request.Payload.embeds[1].color ~= nil then
				table.insert(titles, request.Payload.embeds[1].title)
			end
		end
		local description = h.Http.Requests[#h.Http.Requests].Payload.embeds[1].description
		h.Telemetry:Stop()
		expect(table.concat(titles, " | ")).to.equal(
			"Outage (was Healthy) | Outage (was Healthy) | Recovered: Outage \u{2192} Healthy"
		)
		expect(string.find(description, "on this server", 1, true) ~= nil).to.equal(true)
	end)

	it("mentions the configured role on an outage, once per cooldown, and never on a routine report", function()
		local h = H.start({
			Webhooks = { Alerts = { Url = H.URL_A, Mention = { RoleId = "555", On = { "Outage" }, Cooldown = 60 } } },
			Default = "Alerts",
		})
		h.Scribe.SetStatus("Outage")
		h.Scribe.SetStatus("Healthy")
		h.Scribe.SetStatus("Outage")
		h.Advance(61)
		h.Scribe.SetStatus("Healthy")
		h.Scribe.SetStatus("Outage")
		local mentions = {}
		for _, request in h.Http.Requests do
			local roles = request.Payload.allowed_mentions.roles
			table.insert(
				mentions,
				`{request.Payload.content or "-"}/{if roles then #roles else 0}/{#request.Payload.allowed_mentions.parse}`
			)
		end
		h.Telemetry:Stop()
		expect(table.concat(mentions, " ")).to.equal("<@&555>/1/0 -/0/0 -/0/0 -/0/0 <@&555>/1/0")
	end)

	it("mentions on Fatal and Outage by default, and on nothing else", function()
		local h = H.start({
			Webhooks = { Alerts = { Url = H.URL_A, Mention = { RoleId = "555", Cooldown = 0 } } },
			Default = "Alerts",
		})
		h.Scribe.Log("Error", "X", "Persistence", "error", {})
		h.Scribe.SetStatus("Degraded")
		h.Scribe.SetStatus("Outage")
		h.Scribe.Log("Fatal", "Y", "Persistence", "fatal", {})
		h.Scribe.SetStatus("Healthy")
		local mentions = {}
		for _, request in h.Http.Requests do
			table.insert(mentions, request.Payload.content or "-")
		end
		h.Telemetry:Stop()
		expect(table.concat(mentions, " ")).to.equal("- - <@&555> <@&555> -")
	end)
end
