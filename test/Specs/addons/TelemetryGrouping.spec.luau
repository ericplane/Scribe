--!nonstrict
-- Log forwarding: which entries are reported, how repeats fold into one follow-up, and
-- what the follow-up says about counts it did and did not see.

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

	it("forwards Error and Fatal, an allowlisted warning, and nothing else", function()
		local h = H.start()
		h.Scribe.Log("Error", "PROFILE_LOAD_FAIL", "Persistence", "could not load", {})
		h.Scribe.Log("Fatal", "SCHEMA_MISMATCH", "Lifecycle", "bad schema", {})
		h.Scribe.Log("Warn", "PROFILE_SIZE", "Persistence", "big profile", {})
		h.Scribe.Log("Warn", "SLOW_SAVE_NOT_A_CODE", "Persistence", "not allowlisted", {})
		h.Scribe.Log("Info", "PROFILE_SAVED", "Persistence", "saved", {})
		h.Scribe.Log("Debug", "INIT_SENT", "Replication", "sent", {})
		local stats = h.Telemetry:GetStats()
		local titles = h.Http.Titles()
		h.Telemetry:Stop()
		expect(titles).to.equal("Error: PROFILE_LOAD_FAIL | Fatal: SCHEMA_MISMATCH | Warn: PROFILE_SIZE")
		expect(`{stats.Filtered.Issues} {stats.Filtered.Warnings} {stats.Filtered.Ignored}`).to.equal("2 1 3")
	end)

	it("honours include and exclude lists for codes and categories", function()
		local h = H.start({
			Warnings = { Include = { "SLOW_LOAD" }, Categories = { "Gifting" } },
			Issues = { ExcludeCodes = { "NOISY" }, ExcludeCategories = { "Commands" } },
		})
		h.Scribe.Log("Warn", "SLOW_LOAD", "Persistence", "a", {})
		h.Scribe.Log("Warn", "PROFILE_SIZE", "Persistence", "b", {})
		h.Scribe.Log("Warn", "GIFT_AIM_SETTLED", "Gifting", "c", {})
		h.Scribe.Log("Error", "NOISY", "Persistence", "d", {})
		h.Scribe.Log("Error", "COMMAND_ERROR", "Commands", "e", {})
		h.Scribe.Log("Error", "OTHER", "Persistence", "f", {})
		local titles = h.Http.Titles()
		h.Telemetry:Stop()
		expect(titles).to.equal("Warn: SLOW_LOAD | Warn: GIFT_AIM_SETTLED | Error: OTHER")
	end)

	it("reports the first occurrence at once and folds repeats into one follow-up when the interval passes", function()
		local h = H.start({ Grouping = { Interval = 60 } })
		for _ = 1, 5 do
			h.Scribe.Log("Error", "PROFILE_LOAD_FAIL", "Persistence", "could not load", { Key = "PLAYER_1" })
		end
		local afterBurst = #h.Http.Requests
		h.Advance(59)
		local before = #h.Http.Requests
		h.Advance(2)
		local summary = h.Http.Requests[#h.Http.Requests].Payload.embeds[1]
		-- The next follow-up counts only what arrived since the last one.
		for _ = 1, 2 do
			h.Scribe.Log("Error", "PROFILE_LOAD_FAIL", "Persistence", "could not load", { Key = "PLAYER_1" })
		end
		h.Advance(61)
		local second = h.Http.Requests[#h.Http.Requests].Payload.embeds[1]
		h.Telemetry:Stop()
		expect(`burst={afterBurst} before={before} total={#h.Http.Requests}`).to.equal("burst=1 before=1 total=3")
		expect(summary.title).to.equal("Still occurring: PROFILE_LOAD_FAIL")
		expect(string.find(summary.description, "**4** more occurrence(s)", 1, true) ~= nil).to.equal(true)
		expect(string.find(summary.description, "**5** observed", 1, true) ~= nil).to.equal(true)
		expect(string.find(second.description, "**2** more occurrence(s)", 1, true) ~= nil).to.equal(true)
		expect(string.find(second.description, "**7** observed", 1, true) ~= nil).to.equal(true)
	end)

	it(
		"sends the pending follow-up when the interval expires with no further event, then forgets a quiet group",
		function()
			local h = H.start({ Grouping = { Interval = 30, Expiry = 120 } })
			h.Scribe.Log("Error", "X", "Persistence", "one", {})
			h.Scribe.Log("Error", "X", "Persistence", "two", {})
			h.Advance(31)
			local count = #h.Http.Requests
			local held = h.Telemetry:GetStats().Groups
			-- 119 s quiet: inside the expiry.
			h.Advance(88)
			local stillHeld = h.Telemetry:GetStats().Groups
			h.Advance(31)
			local forgotten = h.Telemetry:GetStats().Groups
			-- A fresh occurrence after the expiry is a first report again, not a follow-up.
			h.Scribe.Log("Error", "X", "Persistence", "three", {})
			local titles = h.Http.Titles()
			h.Telemetry:Stop()
			expect(`{count} groups={held}/{stillHeld}/{forgotten}`).to.equal("2 groups=1/1/0")
			expect(titles).to.equal("Error: X | Still occurring: X | Error: X")
		end
	)

	it("keeps upstream suppression separate from what it observed, and never claims an exact total", function()
		local h = H.start({ Grouping = { Interval = 10 } })
		h.Scribe.Log("Error", "PROFILE_STORE_ERROR", "Persistence", "store down", { Repeats = 7 })
		h.Scribe.Log("Error", "PROFILE_STORE_ERROR", "Persistence", "store down", { Repeats = 3 })
		h.Advance(11)
		local first = h.Http.Requests[1].Payload
		local followUp = h.Http.Requests[2].Payload.embeds[1].description
		h.Telemetry:Stop()
		expect(field(first, "Upstream")).to.equal(
			"Scribe folded 7 earlier repeat(s) into this entry before it reached telemetry"
		)
		expect(string.find(followUp, "folded a further 3 repeat(s)", 1, true) ~= nil).to.equal(true)
		expect(string.find(followUp, "underlying total is higher", 1, true) ~= nil).to.equal(true)
	end)

	it("groups by subject as well as code, and bounds the number of groups", function()
		local h = H.start({ Grouping = { Interval = 60, MaxGroups = 3 } })
		h.Scribe.Log("Error", "PROFILE_LOAD_FAIL", "Persistence", "x", { Key = "K1" })
		h.Scribe.Log("Error", "PROFILE_LOAD_FAIL", "Persistence", "x", { Key = "K1" })
		for i = 2, 5 do
			h.Scribe.Log("Error", "PROFILE_LOAD_FAIL", "Persistence", "x", { Key = `K{i}` })
		end
		local titles = h.Http.Titles()
		local evictedFollowUp = h.Http.Requests[4].Payload
		local groups = h.Telemetry:GetStats().Groups
		h.Telemetry:Stop()
		-- K4 evicts K1, the least recently seen, and K1's pending follow-up goes out first.
		expect(titles).to.equal(
			"Error: PROFILE_LOAD_FAIL | Error: PROFILE_LOAD_FAIL | Error: PROFILE_LOAD_FAIL | Still occurring: PROFILE_LOAD_FAIL | Error: PROFILE_LOAD_FAIL | Error: PROFILE_LOAD_FAIL"
		)
		local subject = tostring(field(evictedFollowUp, "Subject"))
		expect(`hashed={string.match(subject, "^key:#%x+$") ~= nil} groups={groups}`).to.equal("hashed=true groups=3")
	end)

	it("skips a category with no route and counts it, rather than sending it elsewhere", function()
		local h = H.start({
			Webhooks = { Alerts = { Url = H.URL_A } },
			Routes = { Issues = "Alerts" },
		})
		h.Scribe.Log("Warn", "PROFILE_SIZE", "Persistence", "big", {})
		h.Scribe.Log("Error", "X", "Persistence", "err", {})
		local stats = h.Telemetry:GetStats()
		h.Telemetry:Stop()
		expect(`sent={#h.Http.Requests} skippedWarnings={stats.Skipped.Warnings}`).to.equal("sent=1 skippedWarnings=1")
	end)
end
