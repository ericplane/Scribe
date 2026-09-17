--!nonstrict
-- Periodic summaries and performance rules: interval arithmetic from counter deltas,
-- honest labels for what is missing or stale, and sustained evidence before an alert.

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

	it("is off by default, and on reports interval deltas rather than lifetime counters", function()
		local quiet = H.start(nil, function(scribe)
			scribe.Metrics = { SavesOk = 500 }
		end)
		quiet.Advance(3600)
		local quietCount = #quiet.Http.Requests
		quiet.Telemetry:Stop()

		local h = H.start({ Summaries = { Enabled = true, Interval = 600 } }, function(scribe)
			scribe.Metrics =
				{ SavesOk = 500, SavesFailed = 2, ProfilesLoaded = 40, ActiveSessions = 12, BytesOut = 1000000 }
		end)
		h.Scribe.Metrics.SavesOk = 530
		h.Scribe.Metrics.SavesFailed = 2
		h.Scribe.Metrics.ProfilesLoaded = 45
		h.Scribe.Metrics.BytesOut = 1000000 + 600 * 2048
		h.Advance(600)
		local payload = h.Http.Requests[1].Payload
		h.Telemetry:Stop()
		expect(quietCount).to.equal(0)
		expect(
			`{payload.embeds[1].title} | saves={field(payload, "Saves")} | loads={field(payload, "Loads")} | bytes={field(
				payload,
				"Bytes out"
			)} | sessions={field(payload, "Sessions")}`
		).to.equal(
			"Summary: last 10m 0s on this server | saves=30 ok, 0 failed | loads=5 ok, n/a failed | bytes=2.0 KB/s | sessions=12"
		)
	end)

	it("labels percentiles with their own window and shows a missing distribution or budget as such", function()
		local h = H.start({ Summaries = { Enabled = true, Interval = 60 } }, function(scribe)
			scribe.Percentiles =
				{ SaveDuration = { P50 = 0.4, P90 = 1.2, P99 = 3.5, Samples = 42, Window = 7200, Age = 90 } }
			scribe.Budget = { Available = false, Reason = "no DataStoreService", Budgets = {}, At = 0 }
		end)
		h.Advance(60)
		local payload = h.Http.Requests[1].Payload
		h.Telemetry:Stop()
		expect(field(payload, "Save duration")).to.equal(
			"p50 0.40s \u{00B7} p90 1.20s \u{00B7} p99 3.50s (42 samples over 2h 0m, newest 1m 30s ago)"
		)
		expect(field(payload, "Profile size")).to.equal("no samples")
		expect(field(payload, "DataStore budget")).to.equal("not readable here (no DataStoreService)")
		expect(string.find(payload.embeds[1].description, "not the interval", 1, true) ~= nil).to.equal(true)
	end)

	it("does not count saves made before telemetry started as fresh", function()
		local h = H.start({
			Performance = { Interval = 60, Checks = 1, Rules = { SlowSaves = { Threshold = 2, MinSamples = 10 } } },
		}, function(scribe)
			scribe.Metrics = { SaveDuration = { Count = 100, Average = 5, Max = 9 } }
			scribe.Percentiles = { SaveDuration = { P50 = 4, P90 = 5, P99 = 6, Samples = 100, Window = 600, Age = 1 } }
		end)
		h.Advance(60)
		local beforeAnySave = #h.Http.Requests
		h.Scribe.Metrics.SaveDuration.Count = 110
		h.Advance(60)
		local titles = h.Http.Titles()
		h.Telemetry:Stop()
		expect(`before={beforeAnySave} {titles}`).to.equal("before=0 Performance: SlowSaves")
	end)

	it("needs MinSamples fresh saves at every check, not one fresh save on top of old ones", function()
		local h = H.start({
			Performance = { Interval = 60, Checks = 3, Rules = { SlowSaves = { Threshold = 2, MinSamples = 10 } } },
		}, function(scribe)
			scribe.Metrics = { SaveDuration = { Count = 0, Average = 0, Max = 0 } }
			scribe.Percentiles = {}
		end)
		local function saves(count)
			h.Scribe.Metrics.SaveDuration.Count = count
			h.Scribe.Percentiles.SaveDuration =
				{ P50 = 1, P90 = 2, P99 = 5, Samples = math.min(count, 256), Window = 60, Age = 1 }
		end
		for _, count in { 100, 102, 104, 106 } do
			saves(count)
			h.Advance(60)
		end
		local trickle = #h.Http.Requests
		for _, count in { 116, 126 } do
			saves(count)
			h.Advance(60)
		end
		local titles = h.Http.Titles()
		h.Telemetry:Stop()
		expect(`trickle={trickle} {titles}`).to.equal("trickle=0 Performance: SlowSaves")
	end)

	it("alerts on sustained slow saves only after three checks with fresh samples, and reports the clear", function()
		local h = H.start({
			Performance = { Interval = 60, Checks = 3, Rules = { SlowSaves = { Threshold = 2, MinSamples = 10 } } },
		}, function(scribe)
			scribe.Metrics = { SaveDuration = { Count = 0, Average = 0, Max = 0 } }
			scribe.Percentiles = {}
		end)
		local function saves(count, p99)
			h.Scribe.Metrics.SaveDuration.Count = count
			h.Scribe.Percentiles.SaveDuration =
				{ P50 = 1, P90 = 2, P99 = p99, Samples = math.min(count, 256), Window = 60, Age = 1 }
		end
		saves(20, 5)
		h.Advance(60)
		saves(30, 5)
		h.Advance(60)
		local beforeThird = #h.Http.Requests
		-- Unchanged samples are not evidence: this check must not count.
		h.Advance(60)
		local afterStale = #h.Http.Requests
		saves(40, 5)
		h.Advance(60)
		local afterThird = #h.Http.Requests
		saves(50, 0.5)
		h.Advance(60)
		local titles = h.Http.Titles()
		h.Telemetry:Stop()
		expect(`beforeThird={beforeThird} stale={afterStale} third={afterThird}`).to.equal(
			"beforeThird=0 stale=0 third=1"
		)
		expect(titles).to.equal("Performance: SlowSaves | Performance cleared: SlowSaves")
	end)

	it("rates save failures and traffic against the elapsed interval, and a quiet interval clears them", function()
		local h = H.start({
			Performance = {
				Interval = 60,
				Checks = 2,
				Rules = { SaveFailures = { Threshold = 2 }, Traffic = { Threshold = 1000 } },
			},
		}, function(scribe)
			scribe.Metrics = { SavesFailed = 0, BytesOut = 0 }
		end)
		-- 3 failures per minute, 2000 B/s.
		h.Scribe.Metrics.SavesFailed = 3
		h.Scribe.Metrics.BytesOut = 120000
		h.Advance(60)
		h.Scribe.Metrics.SavesFailed = 6
		h.Scribe.Metrics.BytesOut = 240000
		h.Advance(60)
		local alerted = h.Http.Titles()
		-- Counters unchanged: a quiet interval clears both.
		h.Advance(60)
		local titles = h.Http.Titles()
		h.Telemetry:Stop()
		expect(alerted).to.equal("Performance: SaveFailures | Performance: Traffic")
		expect(titles).to.equal(
			"Performance: SaveFailures | Performance: Traffic | Performance cleared: SaveFailures | Performance cleared: Traffic"
		)
	end)
end
