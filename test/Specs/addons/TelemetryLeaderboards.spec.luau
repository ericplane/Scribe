--!nonstrict
return function()
	local Root = script.Parent.Parent.Parent.Parent
	local H = require(Root.Test.Helpers.TelemetryHarness)
	local Config = require(Root.Addons.Telemetry.ScribeTelemetry.Config)

	local function board(status, bundle, name)
		return {
			BundleId = bundle or 1,
			Name = name or "TopCoins",
			Status = status,
			PendingWrites = 4,
			RetryingWrites = 2,
			RejectedWrites = 1,
			ReadAge = 125,
		}
	end
	local function start(entries, options)
		return H.start(options, function(scribe)
			scribe.Boards = entries
			scribe.SnapshotReads = 0
			scribe.GetLeaderboardSnapshot = function()
				scribe.SnapshotReads += 1
				if scribe.FailSnapshot then
					error("snapshot unavailable")
				end
				return scribe.Boards
			end
		end)
	end
	local function field(payload, name)
		for _, item in payload.embeds[1].fields do
			if item.name == name then
				return item.value
			end
		end
	end
	local function latestSummary(h)
		for i = #h.Http.Requests, 1, -1 do
			local payload = h.Http.Requests[i].Payload
			if string.find(payload.embeds[1].title, "Summary:", 1, true) then
				return payload
			end
		end
		error("missing summary")
	end

	it("reports initial degradation separately from healthy profile persistence", function()
		local h = start({ board("Degraded") }, { Summaries = { Enabled = true, Interval = 60 } })
		h.Advance(60)
		local summary = latestSummary(h)
		local titles = h.Http.Titles()
		local profile = h.Scribe.GetStatus()
		h.Telemetry:Stop()
		expect(string.find(titles, "Leaderboard degraded: TopCoins (bundle 1)", 1, true) ~= nil).to.equal(true)
		expect(profile).to.equal("Healthy")
		expect(field(summary, "Profile health")).to.equal("Healthy")
		expect(string.find(field(summary, "Leaderboard health"), "1 degraded", 1, true) ~= nil).to.equal(true)
		expect(
			string.find(field(summary, "Leaderboard details"), "2 retrying, 1 rejected; cache 2m 5s", 1, true) ~= nil
		).to.equal(true)
	end)

	it("polls at the configured cadence, ignores healthy startup, and reports only transitions", function()
		local h = start({ board("Starting") })
		h.Scribe.Boards[1].Status = "Healthy"
		h.Advance(30)
		expect(#h.Http.Requests).to.equal(0)
		h.Scribe.Boards[1].Status = "Degraded"
		h.Advance(29)
		expect(h.Scribe.SnapshotReads).to.equal(2)
		expect(#h.Http.Requests).to.equal(0)
		h.Advance(1)
		h.Advance(60)
		expect(#h.Http.Requests).to.equal(1)
		h.Scribe.Boards[1].Status = "Healthy"
		h.Advance(30)
		local titles = h.Http.Titles()
		h.Telemetry:Stop()
		expect(titles).to.equal(
			"Leaderboard degraded: TopCoins (bundle 1) | Leaderboard recovered: TopCoins (bundle 1)"
		)
	end)

	it("keeps identical board names in different bundles independent", function()
		local h = start({ board("Degraded", 1), board("Degraded", 2) })
		h.Advance(1)
		h.Scribe.Boards[2].Status = "Healthy"
		h.Advance(29)
		local titles = h.Http.Titles()
		h.Telemetry:Stop()
		expect(titles).to.equal(
			"Leaderboard degraded: TopCoins (bundle 1) | Leaderboard degraded: TopCoins (bundle 2) | Leaderboard recovered: TopCoins (bundle 2)"
		)
	end)

	it("keeps a degradation open through Starting until a successful recovery", function()
		local h = start({ board("Degraded") })
		h.Advance(1)
		h.Scribe.Boards[1].Status = "Starting"
		h.Advance(29)
		h.Scribe.Boards[1].Status = "Degraded"
		h.Advance(30)
		h.Scribe.Boards[1].Status = "Starting"
		h.Advance(30)
		h.Scribe.Boards[1].Status = "Healthy"
		h.Advance(30)
		local titles = h.Http.Titles()
		h.Telemetry:Stop()
		expect(titles).to.equal(
			"Leaderboard degraded: TopCoins (bundle 1) | Leaderboard recovered: TopCoins (bundle 1)"
		)
	end)

	it("discovers later bundles and removes stopped boards without reporting recovery", function()
		local h = start({})
		h.Scribe.Boards = { board("Degraded", 3) }
		h.Advance(30)
		h.Scribe.Boards = {}
		h.Advance(30)
		local count = #h.Http.Requests
		expect(h.Telemetry:GetStats().Leaderboards.Monitored).to.equal(0)
		h.Telemetry:Stop()
		local reads = h.Scribe.SnapshotReads
		h.Advance(120)
		expect(#h.Http.Requests).to.equal(count)
		expect(count).to.equal(1)
		expect(h.Scribe.SnapshotReads).to.equal(reads)
		expect(h.Telemetry:GetStats().Leaderboards.Monitored).to.equal(0)
	end)

	it("bounds tracked boards and makes omitted coverage explicit", function()
		local h = start({ board("Degraded", 1), board("Degraded", 2), board("Degraded", 3) }, {
			Leaderboards = { MaxBoards = 2 },
			Summaries = { Enabled = true, Interval = 60 },
		})
		h.Advance(60)
		local summary = latestSummary(h)
		local stats = h.Telemetry:GetStats().Leaderboards
		h.Telemetry:Stop()
		expect(stats.Monitored).to.equal(2)
		expect(stats.Omitted).to.equal(1)
		expect(string.find(field(summary, "Leaderboard health"), "1 boards omitted", 1, true) ~= nil).to.equal(true)
		expect(string.find(h.Http.Titles(), "bundle 3", 1, true) == nil).to.equal(true)
	end)

	it("routes leaderboard alerts independently and honors explicit disable", function()
		local h = start({ board("Degraded") }, {
			Webhooks = { Profiles = { Url = H.URL_A }, Boards = { Url = H.URL_B } },
			Default = "Profiles",
			Routes = { Leaderboards = "Boards" },
		})
		h.Scribe.SetStatus("Degraded")
		h.Advance(1)
		expect(h.Http.Titles(H.URL_A)).to.equal("Degraded (was Healthy)")
		expect(h.Http.Titles(H.URL_B)).to.equal("Leaderboard degraded: TopCoins (bundle 1)")
		h.Telemetry:Stop()
		local quiet = start({ board("Degraded") }, { Routes = { Leaderboards = false } })
		quiet.Advance(60)
		expect(#quiet.Http.Requests).to.equal(0)
		expect(quiet.Telemetry:GetStats().Leaderboards.Monitored).to.equal(1)
		quiet.Telemetry:Stop()
	end)

	it("does no snapshot work when monitoring is disabled", function()
		local h = start({ board("Degraded") }, {
			Leaderboards = { Enabled = false },
			Summaries = { Enabled = true, Interval = 60 },
		})
		h.Advance(60)
		expect(h.Scribe.SnapshotReads).to.equal(0)
		expect(field(latestSummary(h), "Leaderboard health")).to.equal("Disabled")
		h.Telemetry:Stop()
	end)

	it("labels an older Scribe API unavailable and keeps existing telemetry working", function()
		local h = H.start({ Summaries = { Enabled = true, Interval = 60 } })
		h.Advance(60)
		local summary = latestSummary(h)
		h.Telemetry:Stop()
		expect(field(summary, "Profile health")).to.equal("Healthy")
		expect(string.find(field(summary, "Leaderboard health"), "Unavailable", 1, true) ~= nil).to.equal(true)
	end)

	it("does not turn a failed snapshot into healthy state or lose recovery tracking", function()
		local h = start({ board("Degraded") }, { Summaries = { Enabled = true, Interval = 60 } })
		h.Scribe.FailSnapshot = true
		h.Advance(60)
		expect(string.find(field(latestSummary(h), "Leaderboard health"), "Unavailable", 1, true) ~= nil).to.equal(true)
		h.Scribe.FailSnapshot = false
		h.Scribe.Boards[1].Status = "Healthy"
		h.Advance(30)
		local titles = h.Http.Titles()
		h.Telemetry:Stop()
		expect(string.find(titles, "Leaderboard recovered", 1, true) ~= nil).to.equal(true)
	end)

	it("rejects invalid snapshot rows without claiming recovery", function()
		local h = start({ board("Degraded") })
		h.Advance(1)
		h.Scribe.Boards = { { BundleId = 1, Name = "TopCoins", Status = "Healthy", PendingWrites = 0 / 0 } }
		h.Advance(29)
		expect(h.Telemetry:GetStats().Leaderboards.State).to.equal("Unavailable")
		expect(#h.Http.Requests).to.equal(1)
		h.Telemetry:Stop()
	end)

	it("redacts webhook URLs and profile keys in board errors", function()
		local entry = board("Degraded")
		entry.LastReadError = `failed PLAYER_1234567 {H.URL_A}`
		local h = start({ entry })
		h.Advance(1)
		local body = h.Http.Requests[1].Body
		h.Telemetry:Stop()
		expect(string.find(body, H.URL_A, 1, true) == nil).to.equal(true)
		expect(string.find(body, "PLAYER_1234567", 1, true) == nil).to.equal(true)
	end)

	it("includes actionable new warning codes by default", function()
		local codes = {
			"LB_READ_FAIL",
			"LB_WRITE_FAIL",
			"LB_QUEUE_OVERFLOW",
			"LB_BUDGET_DEFERRED",
			"PLAYER_LEAVING_HOOK_SLOW",
			"RECEIPT_RETRY",
		}
		local h = H.start()
		for _, code in codes do
			h.Scribe.Log("Warn", code, "Diagnostics", "action needed", {})
		end
		h.Advance(1)
		expect(#h.Http.Requests).to.equal(#codes)
		h.Telemetry:Stop()
	end)

	it("validates monitoring limits before starting", function()
		for _, value in { 0, -1, 1.5, math.huge, 0 / 0, 1025, "64" } do
			expect(
				pcall(Config.Resolve, { Webhooks = { A = { Url = H.URL_A } }, Leaderboards = { MaxBoards = value } })
			).to.equal(false)
		end
		for _, value in { 0, 4, math.huge, 0 / 0, "30" } do
			expect(pcall(Config.Resolve, { Webhooks = { A = { Url = H.URL_A } }, Leaderboards = { Interval = value } })).to.equal(
				false
			)
		end
		expect(pcall(Config.Resolve, { Webhooks = { A = { Url = H.URL_A } }, Leaderboards = false })).to.equal(false)
	end)
end
