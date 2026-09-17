--!nonstrict
-- Deterministic seams for the telemetry add-on: a Scribe facade, a recording HTTP fake
-- and a virtual clock that runs workers only when the spec advances time.

local HttpService = game:GetService("HttpService")

local TelemetryHarness = {}

TelemetryHarness.URL_A =
	"https://discord.com/api/webhooks/100000000000000001/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
TelemetryHarness.URL_B =
	"https://discord.com/api/webhooks/100000000000000002/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
TelemetryHarness.URL_C =
	"https://discord.com/api/webhooks/100000000000000003/cccccccccccccccccccccccccccccccccccccccccccc"
TelemetryHarness.URL_PROXY =
	"https://webhook.example.net/api/webhooks/100000000000000004/dddddddddddddddddddddddddddddddddddddddddddd"
TelemetryHarness.URL_CUSTOM = "https://api.example.com/telemetry/alerts?key=eeeeeeeeeeeeeeee"

--- A stand-in for the Scribe module: the diagnostics surface the add-on uses, driven by
--- the spec.
function TelemetryHarness.fakeScribe()
	local scribe = {}
	scribe.Version = "2.4.0"
	scribe.KeyPrefix = "PLAYER_"
	function scribe.GetProfileKeyPrefix()
		return scribe.KeyPrefix
	end
	scribe.Sinks = {}
	scribe.Status = "Healthy"
	scribe.Metrics = {}
	scribe.Percentiles = {}
	scribe.Budget = { Available = false, Reason = "not asked", Budgets = {}, At = 0 }
	local listeners = {}
	scribe.OnStatusChanged = {
		Connect = function(_, fn)
			listeners[fn] = true
			return {
				Disconnect = function()
					listeners[fn] = nil
				end,
			}
		end,
	}
	scribe.Listeners = listeners
	function scribe.AddLogSink(fn)
		table.insert(scribe.Sinks, fn)
		return function()
			local index = table.find(scribe.Sinks, fn)
			if index then
				table.remove(scribe.Sinks, index)
			end
		end
	end
	function scribe.GetStatus()
		return scribe.Status
	end
	function scribe.GetMetrics()
		return table.clone(scribe.Metrics)
	end
	function scribe.GetPercentiles()
		return table.clone(scribe.Percentiles)
	end
	function scribe.GetBudgetSnapshot()
		return scribe.Budget
	end
	scribe.Addons = {}
	function scribe.RegisterAddon(name, actions)
		scribe.Addons[name] = actions
		return function()
			if scribe.Addons[name] == actions then
				scribe.Addons[name] = nil
			end
		end
	end
	--- Moves the status and fires listeners as Scribe's Health does, (new, old).
	function scribe.SetStatus(new)
		local old = scribe.Status
		scribe.Status = new
		for fn in listeners do
			fn(new, old)
		end
	end
	--- Delivers a log entry to every sink, as Scribe's Log does.
	function scribe.Log(level, code, category, message, context)
		local entry = {
			At = scribe.Now and scribe.Now() or 0,
			Level = level,
			Category = category,
			Code = code,
			Message = message,
			Context = context,
		}
		for _, fn in table.clone(scribe.Sinks) do
			fn(entry)
		end
	end
	return scribe
end

--- Records every request; answers with `Responder(url, payload)` or a 204.
function TelemetryHarness.fakeHttp()
	local http = { Requests = {} }
	http.Responder = nil
	http.Post = function(url, body)
		local payload = HttpService:JSONDecode(body)
		table.insert(http.Requests, { Url = url, Body = body, Payload = payload })
		if http.Responder then
			return http.Responder(url, payload, #http.Requests)
		end
		return { Ok = true, Status = 204, Headers = {}, Body = "" }
	end
	--- Requests to `url`, or all of them.
	function http.For(url)
		local out = {}
		for _, request in http.Requests do
			if url == nil or request.Url == url then
				table.insert(out, request)
			end
		end
		return out
	end
	function http.Titles(url)
		local out = {}
		for _, request in http.For(url) do
			table.insert(out, request.Payload.embeds[1].title)
		end
		return table.concat(out, " | ")
	end
	return http
end

--- Virtual time. Threads the add-on spawns park on Wait until Advance reaches them; a
--- Wait from the spec's own thread advances time instead, so Flush can be driven.
function TelemetryHarness.virtualTime(startWall)
	local now = 0
	local timers = {}
	local owned = {}
	local sched = {}
	local clock = {
		Now = function()
			return (startWall or 1700000000) + now
		end,
		Monotonic = function()
			return now
		end,
	}
	local function advance(seconds)
		local target = now + seconds
		while true do
			local best, bestIndex = nil, nil
			for i, timer in timers do
				if timer.At <= target and (best == nil or timer.At < best.At) then
					best, bestIndex = timer, i
				end
			end
			if best == nil then
				break
			end
			table.remove(timers, bestIndex)
			now = best.At
			coroutine.resume(best.Thread)
		end
		now = target
	end
	function sched.Spawn(fn)
		local thread = coroutine.create(fn)
		owned[thread] = true
		coroutine.resume(thread)
	end
	function sched.Wait(seconds)
		local thread = coroutine.running()
		if owned[thread] then
			table.insert(timers, { At = now + seconds, Thread = thread })
			coroutine.yield()
		else
			advance(seconds)
		end
	end
	return {
		Clock = clock,
		Scheduler = sched,
		Advance = advance,
		Pending = function()
			return #timers
		end,
	}
end

--- Everything wired: returns the handle plus every seam.
function TelemetryHarness.start(options, setup)
	local Root = script.Parent.Parent.Parent
	local ScribeTelemetry = require(Root.Addons.Telemetry.ScribeTelemetry)
	local scribe = TelemetryHarness.fakeScribe()
	local http = TelemetryHarness.fakeHttp()
	local time = TelemetryHarness.virtualTime()
	scribe.Now = time.Clock.Now
	if setup then
		setup(scribe, http)
	end
	local merged = table.clone(options or {})
	merged.Http = http
	merged.Clock = time.Clock
	merged.Scheduler = time.Scheduler
	merged.Json = {
		Encode = function(value)
			return HttpService:JSONEncode(value)
		end,
		Decode = function(text)
			return HttpService:JSONDecode(text)
		end,
	}
	merged.Jitter = function()
		return 0.5
	end
	-- Studio would otherwise disable the add-on.
	if merged.Studio == nil then
		merged.Studio = false
	end
	if merged.Webhooks == nil then
		merged.Webhooks = { Alerts = { Url = TelemetryHarness.URL_A } }
		merged.Default = merged.Default or "Alerts"
	end
	local telemetry = ScribeTelemetry.Start(scribe, merged)
	return {
		Telemetry = telemetry,
		Scribe = scribe,
		Http = http,
		Advance = time.Advance,
		Clock = time.Clock,
		Scheduler = time.Scheduler,
		Pending = time.Pending,
	}
end

return TelemetryHarness
