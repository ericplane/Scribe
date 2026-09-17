--!nonstrict
-- Start, Stop, Flush, Test and GetStats: registrations come and go cleanly, a stopped
-- add-on does nothing, and the real Scribe module is a valid first argument.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local ScribeTelemetry = require(Root.Addons.Telemetry.ScribeTelemetry)
	local H = require(Root.Test.Helpers.TelemetryHarness)

	it("keeps the webhook URL out of LastError when the request itself fails", function()
		local h = H.start(nil, function(_, http)
			http.Responder = function(url)
				return { Ok = false, Headers = {}, Body = "", Error = `HttpError: ConnectFail {url}` }
			end
		end)
		h.Scribe.Log("Error", "PROFILE_LOAD_FAIL", "Persistence", "could not load", {})
		local last = tostring(h.Telemetry:GetStats().Destinations.Alerts.LastError)
		h.Telemetry:Stop()
		local leaked = string.find(last, "api/webhooks", 1, true) ~= nil
		local kept = string.find(last, "ConnectFail", 1, true) ~= nil
		expect(`leaked={leaked} kept={kept}`).to.equal("leaked=false kept=true")
	end)

	it("cuts an echoed body on a character boundary in LastError", function()
		local h = H.start(nil, function(_, http)
			http.Responder = function()
				return { Ok = false, Status = 400, Headers = {}, Body = "a" .. string.rep("\u{1F600}", 50) }
			end
		end)
		h.Scribe.Log("Error", "PROFILE_LOAD_FAIL", "Persistence", "could not load", {})
		local last = tostring(h.Telemetry:GetStats().Destinations.Alerts.LastError)
		h.Telemetry:Stop()
		expect(`utf8={utf8.len(last) ~= nil} bounded={#last <= 180}`).to.equal("utf8=true bounded=true")
	end)

	it("registers one sink and one status listener, and removes both on Stop, however often it is called", function()
		local h = H.start()
		local listeners = 0
		for _ in h.Scribe.Listeners do
			listeners += 1
		end
		local before = `sinks={#h.Scribe.Sinks} listeners={listeners}`
		h.Telemetry:Stop()
		h.Telemetry:Stop()
		listeners = 0
		for _ in h.Scribe.Listeners do
			listeners += 1
		end
		h.Scribe.Log("Error", "X", "Persistence", "after stop", {})
		h.Scribe.SetStatus("Outage")
		h.Advance(120)
		expect(
			`{before} | after: sinks={#h.Scribe.Sinks} listeners={listeners} requests={#h.Http.Requests} state={h.Telemetry:GetStats().State}`
		).to.equal("sinks=1 listeners=1 | after: sinks=0 listeners=0 requests=0 state=Stopped")
	end)

	it("refuses a second start for the same module until the first stops", function()
		local h = H.start()
		local ok, err = pcall(ScribeTelemetry.Start, h.Scribe, { Webhooks = { A = { Url = H.URL_A } } })
		h.Telemetry:Stop()
		local again = ScribeTelemetry.Start(
			h.Scribe,
			{ Webhooks = { A = { Url = H.URL_A } }, Http = h.Http, Clock = h.Clock, Studio = false }
		)
		local restarted = again:GetStats().State
		again:Stop()
		expect(`{ok} {err} then={restarted}`).to.equal(
			"false ScribeTelemetry: already started for this Scribe module; Stop() the running one first then=Running"
		)
	end)

	it("stops cleanly during a retry wait, and a late result starts nothing", function()
		local h = H.start()
		local calls = 0
		h.Http.Responder = function()
			calls += 1
			return { Ok = false, Status = 503, Headers = {}, Body = "" }
		end
		h.Scribe.Log("Error", "X", "Persistence", "m", {})
		local during = h.Pending()
		h.Telemetry:Stop()
		h.Advance(600)
		local stats = h.Telemetry:GetStats()
		expect(`pendingDuring={during > 0} calls={calls} queued={stats.Queued} stopped={stats.Dropped.Stopped}`).to.equal(
			"pendingDuring=true calls=1 queued=0 stopped=1"
		)
	end)

	it("returns state to baseline across repeated start and stop cycles", function()
		local counts = {}
		for _ = 1, 3 do
			local h = H.start()
			h.Scribe.Log("Error", "X", "Persistence", "m", {})
			h.Telemetry:Stop()
			-- The tick loop wakes once more and exits.
			h.Advance(1)
			table.insert(counts, `{#h.Scribe.Sinks}/{h.Pending()}/{h.Telemetry:GetStats().Groups}`)
		end
		expect(table.concat(counts, " ")).to.equal("0/0/0 0/0/0 0/0/0")
	end)

	it("flushes within its deadline and reports the outcome", function()
		local h = H.start()
		local stuck = true
		h.Http.Responder = function()
			if stuck then
				return { Ok = false, Status = 503, Headers = {}, Body = "" }
			end
			return { Ok = true, Status = 204, Headers = {}, Body = "" }
		end
		h.Scribe.Log("Error", "X", "Persistence", "m", {})
		local failed = h.Telemetry:Flush(2)
		stuck = false
		local drained = h.Telemetry:Flush(30)
		h.Telemetry:Stop()
		expect(`{failed} {drained} queued={h.Telemetry:GetStats().Queued}`).to.equal("false true queued=0")
	end)

	it("reports a test message that could not be queued", function()
		local h = H.start()
		h.Http.Responder = function()
			return { Ok = false, Status = 404, Headers = {}, Body = "" }
		end
		h.Scribe.Log("Error", "X", "Persistence", "m", {})
		local ok, reason = h.Telemetry:Test("Alerts")
		local requests = #h.Http.Requests
		h.Telemetry:Stop()
		expect(`{ok} {reason} requests={requests}`).to.equal(
			"false destination is dead: webhook refused with HTTP 404 requests=1"
		)
	end)

	it("sends a test message to one named destination only, and refuses an unknown or disabled one", function()
		local h = H.start({
			Webhooks = { Alerts = { Url = H.URL_A }, Off = { Url = H.URL_B, Enabled = false } },
			Default = "Alerts",
		})
		local ok = h.Telemetry:Test("Alerts")
		local unknownOk, unknownErr = h.Telemetry:Test("Nope")
		local offOk, offErr = h.Telemetry:Test("Off")
		local payload = h.Http.Requests[1].Payload
		h.Telemetry:Stop()
		expect(`{ok} {#h.Http.For(H.URL_A)} {#h.Http.For(H.URL_B)} | {unknownOk} {unknownErr} | {offOk} {offErr}`).to.equal(
			'true 1 0 | false no destination named "Nope" | false destination is disabled'
		)
		expect(payload.embeds[1].title).to.equal("Test message")
	end)

	it("exposes queue, delivery and destination state without the webhook URL", function()
		local h = H.start()
		h.Scribe.Log("Error", "X", "Persistence", "m", {})
		local stats = h.Telemetry:GetStats()
		local dest = stats.Destinations.Alerts
		h.Telemetry:Stop()
		local HttpService = game:GetService("HttpService")
		local text = HttpService:JSONEncode(stats)
		expect(
			`delivered={stats.Delivered} last={dest.LastDeliveredAt ~= nil} state={dest.State} leaks={string.find(
				text,
				"webhooks/",
				1,
				true
			) ~= nil}`
		).to.equal("delivered=1 last=true state=Ready leaks=false")
	end)

	it("does nothing in Studio unless allowed", function()
		local h = H.start({ Studio = true })
		h.Scribe.Log("Error", "X", "Persistence", "m", {})
		local stats = h.Telemetry:GetStats()
		local testOk, testErr = h.Telemetry:Test("Alerts")
		h.Telemetry:Stop()
		local allowed = H.start({ Studio = true, AllowStudio = true })
		allowed.Scribe.Log("Error", "X", "Persistence", "m", {})
		local allowedRequests = #allowed.Http.Requests
		allowed.Telemetry:Stop()
		-- A disabled handle still answers with the exported Stats shape.
		local counters = {}
		for _, name in { "Overflow", "Expired", "Malformed", "DeadDestination", "Exhausted", "Stopped", "Coalesced" } do
			table.insert(counters, tostring(stats.Dropped[name]))
		end
		expect(
			`state={stats.State} sinks={#h.Scribe.Sinks} requests={#h.Http.Requests} test={testOk}/{testErr} allowed={allowedRequests} dropped={table.concat(
				counters,
				","
			)}`
		).to.equal(
			"state=DisabledInStudio sinks=0 requests=0 test=false/DisabledInStudio allowed=1 dropped=0,0,0,0,0,0,0"
		)
	end)

	it("accepts the real Scribe module and reports through its real log sink", function()
		local Scribe = require(Root.Scribe)
		local Log = require(Root.Scribe.Internal.Log)
		local http = H.fakeHttp()
		local time = H.virtualTime()
		local HttpService = game:GetService("HttpService")
		local handle = ScribeTelemetry.Start(Scribe, {
			Webhooks = { Alerts = { Url = H.URL_A } },
			Default = "Alerts",
			Studio = false,
			Http = http,
			Clock = time.Clock,
			Scheduler = time.Scheduler,
			Json = {
				Encode = function(v)
					return HttpService:JSONEncode(v)
				end,
				Decode = function(t)
					return HttpService:JSONDecode(t)
				end,
			},
		})
		Log.Error("Persistence", "PROFILE_LOAD_FAIL", "telemetry integration", {})
		for _ = 1, 4 do
			task.wait()
		end
		handle:Stop()
		expect(#http.Requests).to.equal(1)
		expect(http.Requests[1].Payload.embeds[1].title).to.equal("Error: PROFILE_LOAD_FAIL")
	end)
end
