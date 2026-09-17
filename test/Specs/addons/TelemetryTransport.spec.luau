--!nonstrict
-- Delivery: bounded queues, overflow order, expiry, Discord's rate limit, transient and
-- permanent failures, and one destination's trouble staying its own.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local H = require(Root.Test.Helpers.TelemetryHarness)

	local function issue(h, code)
		h.Scribe.Log("Error", code, "Persistence", "failure", {})
	end

	--- One webhook whose every request is throttled, so what is queued stays queued.
	local function throttled(limits)
		local h = H.start({ Limits = limits })
		h.Http.Responder = function()
			return { Ok = false, Status = 429, Headers = { ["retry-after"] = "30" }, Body = "" }
		end
		return h
	end

	--- Queued bytes of one Fatal with `chars` of message and one short warning, measured.
	local function measured(chars)
		local probe = throttled({})
		probe.Scribe.Log("Fatal", "PROTECTED", "Persistence", string.rep("f", chars), {})
		local fatal = probe.Telemetry:GetStats().QueuedBytes
		probe.Scribe.Log("Warn", "PROFILE_SIZE", "Persistence", "small", {})
		local warning = probe.Telemetry:GetStats().QueuedBytes - fatal
		probe.Telemetry:Stop()
		return fatal, warning
	end

	it("refuses a report the queue could never hold, and discards nothing for it", function()
		local fatal = measured(0)
		local max = fatal * 2 + 100
		local h = throttled({ MaxQueuedBytes = max })
		issue(h, "ONE")
		issue(h, "TWO")
		local before = h.Telemetry:GetStats().Queued
		h.Scribe.Log("Fatal", "BIG", "Persistence", string.rep("x", 1400), {})
		local stats = h.Telemetry:GetStats()
		h.Telemetry:Stop()
		expect(
			`before={before} after={stats.Queued} within={stats.QueuedBytes <= max} overflow={stats.Dropped.Overflow}`
		).to.equal("before=2 after=2 within=true overflow=1")
	end)

	it("keeps a warning whose removal would still leave no room under a protected alert", function()
		local fatal, warning = measured(1200)
		local h = throttled({ MaxQueuedBytes = fatal + warning + 50 })
		h.Scribe.Log("Fatal", "PROTECTED", "Persistence", string.rep("f", 1200), {})
		h.Scribe.Log("Warn", "PROFILE_SIZE", "Persistence", "small", {})
		h.Scribe.Log("Warn", "SLOW_LOAD", "Persistence", string.rep("w", 1200), {})
		local stats = h.Telemetry:GetStats()
		h.Telemetry:Stop()
		expect(`queued={stats.Queued} overflow={stats.Dropped.Overflow}`).to.equal("queued=2 overflow=1")
	end)

	it("delivers to every routed destination and keeps a failing one from holding up the rest", function()
		local h = H.start({
			Webhooks = { Alerts = { Url = H.URL_A }, Health = { Url = H.URL_B } },
			Routes = { Issues = { "Alerts", "Health" } },
		})
		h.Http.Responder = function(url)
			if url == H.URL_B then
				return { Ok = false, Status = 500, Headers = {}, Body = "" }
			end
			return { Ok = true, Status = 204, Headers = {}, Body = "" }
		end
		issue(h, "A")
		issue(h, "B")
		local a, b = #h.Http.For(H.URL_A), #h.Http.For(H.URL_B)
		local stats = h.Telemetry:GetStats()
		h.Telemetry:Stop()
		expect(
			`a={a} b={b} deliveredA={stats.Destinations.Alerts.Delivered} queuedB={stats.Destinations.Health.Queued} failuresB={stats.Destinations.Health.Failures}`
		).to.equal("a=2 b=1 deliveredA=2 queuedB=2 failuresB=1")
	end)

	it("honours retry_after on a 429 and sends nothing to that webhook until it passes", function()
		local h = H.start()
		local calls = 0
		h.Http.Responder = function()
			calls += 1
			if calls == 1 then
				return { Ok = false, Status = 429, Headers = { ["Retry-After"] = "99" }, Body = '{"retry_after": 4.5}' }
			end
			return { Ok = true, Status = 204, Headers = {}, Body = "" }
		end
		issue(h, "A")
		h.Advance(4)
		local early = #h.Http.Requests
		h.Advance(1)
		local stats = h.Telemetry:GetStats()
		h.Telemetry:Stop()
		expect(`early={early} total={#h.Http.Requests} delivered={stats.Delivered} retries={stats.Retries}`).to.equal(
			"early=1 total=2 delivered=1 retries=1"
		)
	end)

	it("waits at least a second on a 429 that says zero, rather than posting again at once", function()
		local h = H.start()
		local calls = 0
		h.Http.Responder = function()
			calls += 1
			if calls == 1 then
				return { Ok = false, Status = 429, Headers = {}, Body = '{"retry_after": 0}' }
			end
			return { Ok = true, Status = 204, Headers = {}, Body = "" }
		end
		issue(h, "A")
		local atOnce = #h.Http.Requests
		h.Advance(1)
		h.Telemetry:Stop()
		expect(`{atOnce} {#h.Http.Requests}`).to.equal("1 2")
	end)

	it("paces on X-RateLimit-Remaining zero even without a 429", function()
		local h = H.start()
		h.Http.Responder = function()
			return {
				Ok = true,
				Status = 204,
				Headers = { ["X-RateLimit-Remaining"] = "0", ["X-RateLimit-Reset-After"] = "2" },
				Body = "",
			}
		end
		issue(h, "A")
		issue(h, "B")
		local immediate = #h.Http.Requests
		h.Advance(2)
		h.Telemetry:Stop()
		expect(`{immediate} {#h.Http.Requests}`).to.equal("1 2")
	end)

	it("retries a transient failure with backoff, then gives up after the attempt limit", function()
		local h = H.start({ Limits = { MaxAttempts = 3 } })
		h.Http.Responder = function()
			return { Ok = false, Status = 503, Headers = {}, Body = "" }
		end
		issue(h, "A")
		h.Advance(60)
		local stats = h.Telemetry:GetStats()
		h.Telemetry:Stop()
		expect(`requests={#h.Http.Requests} exhausted={stats.Dropped.Exhausted} queued={stats.Queued}`).to.equal(
			"requests=3 exhausted=1 queued=0"
		)
	end)

	it("expires a report whose retry would land past its lifetime, and stale queued ones", function()
		local h = H.start({ Limits = { MaxAge = 10, MaxRetryDelay = 300 } })
		h.Http.Responder = function()
			return { Ok = false, Status = 429, Headers = {}, Body = '{"retry_after": 30}' }
		end
		issue(h, "A")
		h.Advance(31)
		local stats = h.Telemetry:GetStats()
		h.Telemetry:Stop()
		expect(`requests={#h.Http.Requests} expired={stats.Dropped.Expired} queued={stats.Queued}`).to.equal(
			"requests=1 expired=1 queued=0"
		)
	end)

	it("never evicts the report in flight, so a finished request cannot wedge its destination", function()
		local h = H.start({
			Webhooks = { Alerts = { Url = H.URL_A }, Health = { Url = H.URL_B } },
			Default = "Alerts",
			Routes = { Health = "Health" },
			Limits = { MaxQueued = 1, PerDestination = 1 },
		})
		h.Http.Responder = function(url)
			if url == H.URL_A then
				-- In flight while the next reports arrive.
				h.Scheduler.Wait(5)
			end
			return { Ok = true, Status = 204, Headers = {}, Body = "" }
		end
		issue(h, "A")
		-- A full queue whose only candidate to evict is A, mid-request.
		h.Scribe.SetStatus("Outage")
		h.Advance(6)
		issue(h, "C")
		h.Advance(6)
		local stats = h.Telemetry:GetStats()
		h.Telemetry:Stop()
		expect(
			`{h.Http.Titles(H.URL_A)} | health={#h.Http.For(H.URL_B)} delivered={stats.Delivered} queued={stats.Destinations.Alerts.Queued} overflow={stats.Dropped.Overflow}`
		).to.equal("Error: A | Error: C | health=0 delivered=2 queued=0 overflow=1")
	end)

	it("holds MaxQueuedBytes when a follow-up replaces a smaller one", function()
		local function run(limit)
			local h = H.start({ Grouping = { Interval = 10 }, Limits = { MaxQueuedBytes = limit, MaxAttempts = 100 } })
			h.Http.Responder = function()
				return { Ok = false, Status = 503, Headers = {}, Body = "" }
			end
			issue(h, "A")
			issue(h, "A")
			h.Advance(11)
			local fitted = h.Telemetry:GetStats().QueuedBytes
			-- Upstream repeats add a sentence, so this follow-up is the larger one.
			h.Scribe.Log("Error", "A", "Persistence", "failure", { Repeats = 9 })
			h.Advance(11)
			local stats = h.Telemetry:GetStats()
			h.Telemetry:Stop()
			return fitted, stats
		end
		local fitted = run(1000000)
		local _, stats = run(fitted)
		expect(
			`bytes={stats.QueuedBytes <= fitted} queued={stats.Queued} coalesced={stats.Dropped.Coalesced} overflow={stats.Dropped.Overflow}`
		).to.equal("bytes=true queued=2 coalesced=0 overflow=1")
	end)

	it("stops retrying a deleted webhook and marks the destination dead", function()
		local h = H.start({
			Webhooks = { Alerts = { Url = H.URL_A }, Health = { Url = H.URL_B } },
			Default = "Alerts",
			Routes = { Health = "Health" },
		})
		h.Http.Responder = function(url)
			if url == H.URL_A then
				return { Ok = false, Status = 404, Headers = {}, Body = '{"message": "Unknown Webhook"}' }
			end
			return { Ok = true, Status = 204, Headers = {}, Body = "" }
		end
		issue(h, "A")
		issue(h, "B")
		h.Scribe.SetStatus("Outage")
		h.Advance(60)
		local stats = h.Telemetry:GetStats()
		h.Telemetry:Stop()
		expect(
			`alerts={#h.Http.For(H.URL_A)} health={#h.Http.For(H.URL_B)} state={stats.Destinations.Alerts.State} dropped={stats.Dropped.DeadDestination}`
		).to.equal("alerts=1 health=1 state=Dead dropped=2")
	end)

	it("names the proxy on a 403 from discord.com, and delivers through a proxy host as it would to Discord", function()
		local h = H.start({
			Webhooks = { Direct = { Url = H.URL_A }, Proxied = { Url = H.URL_PROXY } },
			Routes = { Issues = { "Direct", "Proxied" } },
		})
		h.Http.Responder = function(url)
			if url == H.URL_A then
				return { Ok = false, Status = 403, Headers = {}, Body = "<html>Forbidden</html>" }
			end
			return { Ok = true, Status = 204, Headers = {}, Body = "" }
		end
		issue(h, "A")
		local stats = h.Telemetry:GetStats()
		h.Telemetry:Stop()
		expect(`{stats.Destinations.Direct.State} | {stats.Destinations.Direct.LastError}`).to.equal(
			"Dead | webhook refused with HTTP 403; Discord refuses requests from Roblox servers, so route the webhook through a proxy"
		)
		expect(`{stats.Destinations.Proxied.State} {stats.Destinations.Proxied.Delivered} {#h.Http.For(H.URL_PROXY)}`).to.equal(
			"Ready 1 1"
		)
	end)

	it("treats a 400 as a local defect: dropped once, never retried", function()
		local h = H.start()
		h.Http.Responder = function()
			return { Ok = false, Status = 400, Headers = {}, Body = '{"embeds": ["0"]}' }
		end
		issue(h, "A")
		h.Advance(60)
		local stats = h.Telemetry:GetStats()
		h.Telemetry:Stop()
		expect(
			`requests={#h.Http.Requests} malformed={stats.Dropped.Malformed} error={stats.Destinations.Alerts.LastError}`
		).to.equal('requests=1 malformed=1 error=HTTP 400: {"embeds": ["0"]}')
	end)

	it("counts a timed-out request as uncertain and still retries it", function()
		local h = H.start()
		local calls = 0
		h.Http.Responder = function()
			calls += 1
			if calls == 1 then
				return { Ok = false, Error = "HttpError: Timeout" }
			end
			return { Ok = true, Status = 204, Headers = {}, Body = "" }
		end
		issue(h, "A")
		h.Advance(5)
		local stats = h.Telemetry:GetStats()
		h.Telemetry:Stop()
		expect(`uncertain={stats.Uncertain} delivered={stats.Delivered}`).to.equal("uncertain=1 delivered=1")
	end)

	it("holds the item and byte limits, dropping summaries before issues and never an issue for a summary", function()
		local h = H.start({
			Limits = { MaxQueued = 3, PerDestination = 3, MaxQueuedBytes = 1000000, MaxAttempts = 100 },
			Summaries = { Enabled = true, Interval = 60 },
		})
		h.Http.Responder = function()
			return { Ok = false, Status = 503, Headers = {}, Body = "" }
		end
		-- One summary queued, stuck behind the 503.
		h.Advance(61)
		issue(h, "A")
		issue(h, "B")
		-- Three issues on top of a summary: the summary gives way.
		issue(h, "C")
		local stats = h.Telemetry:GetStats()
		-- Another summary tries to enter a queue full of issues.
		h.Advance(61)
		local after = h.Telemetry:GetStats()
		-- Let the queue drain: what comes out is what the overflow kept.
		local mark = #h.Http.Requests
		h.Http.Responder = function()
			return { Ok = true, Status = 204, Headers = {}, Body = "" }
		end
		-- Past the first issue's backoff, before the next summary is due.
		h.Advance(50)
		local kept = {}
		for i = mark + 1, #h.Http.Requests do
			table.insert(kept, string.sub(h.Http.Requests[i].Payload.embeds[1].title, 1, 8))
		end
		h.Telemetry:Stop()
		expect(
			`queued={stats.Queued} overflow={stats.Dropped.Overflow} later={after.Dropped.Overflow} queuedAfter={after.Queued}`
		).to.equal("queued=3 overflow=1 later=2 queuedAfter=3")
		expect(table.concat(kept, ",")).to.equal("Error: A,Error: B,Error: C")
	end)

	it("replaces a queued follow-up for the same group, even one already backing off", function()
		local h = H.start({ Grouping = { Interval = 10 } })
		h.Http.Responder = function()
			return { Ok = false, Status = 503, Headers = {}, Body = "" }
		end
		issue(h, "A")
		issue(h, "A")
		h.Advance(11)
		issue(h, "A")
		h.Advance(11)
		local stats = h.Telemetry:GetStats()
		h.Telemetry:Stop()
		expect(`queued={stats.Queued} coalesced={stats.Dropped.Coalesced}`).to.equal("queued=1 coalesced=1")
	end)

	it("shares pacing between two destinations on one webhook", function()
		local h = H.start({
			Webhooks = { Alerts = { Url = H.URL_A }, AlsoAlerts = { Url = H.URL_A } },
			Routes = { Issues = "Alerts", Health = "AlsoAlerts" },
		})
		h.Http.Responder = function()
			return { Ok = false, Status = 429, Headers = {}, Body = '{"retry_after": 5}' }
		end
		issue(h, "A")
		h.Scribe.SetStatus("Outage")
		h.Advance(4)
		h.Telemetry:Stop()
		expect(#h.Http.Requests).to.equal(1)
	end)
end
