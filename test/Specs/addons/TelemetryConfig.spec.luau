--!nonstrict
-- ScribeTelemetry configuration: what Start refuses, and where each category resolves to.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local Root = script.Parent.Parent.Parent.Parent
local Config = require(Root.Addons.Telemetry.ScribeTelemetry.Config)
local H = require(Root.Test.Helpers.TelemetryHarness)

local function refusal(options): string
	local ok, err = pcall(Config.Resolve, options)
	return if ok then "accepted" else string.gsub(tostring(err), "^ScribeTelemetry: ", "")
end

local function base(extra)
	local options = { Webhooks = { Alerts = { Url = H.URL_A }, Health = { Url = H.URL_B } } }
	for key, value in extra or {} do
		options[key] = value
	end
	return options
end

describe("validation", function()
	it("refuses anything that is not an http or https URL with a host, before anything listens", function()
		local message = "Webhooks.Alerts.Url must be an http or https URL with a host"
		expect(refusal({ Webhooks = { Alerts = { Url = "discord.com/api/webhooks/1/token" } } })).toBe(message)
		expect(refusal({ Webhooks = { Alerts = { Url = "ftp://192.173.178.182/telemetry" } } })).toBe(message)
		expect(refusal({ Webhooks = { Alerts = { Url = "https://" } } })).toBe(message)
		expect(refusal({ Webhooks = { Alerts = { Url = "http:///telemetry" } } })).toBe(message)
		expect(refusal({ Webhooks = { Alerts = { Url = 42 } } })).toBe(message)
	end)

	it("accepts Discord, a proxy with Discord's path, and a service of your own by name or address", function()
		for _, url in
			{
				H.URL_A,
				H.URL_PROXY,
				H.URL_CUSTOM,
				"https://api.example.com:8443/hooks",
				"http://192.173.178.182/telemetry/alerts",
				"http://192.173.178.182:8080",
				"http://[2001:db8::1]/telemetry",
			}
		do
			expect(`{url} {refusal({ Webhooks = { Alerts = { Url = url } } })}`).toBe(`{url} accepted`)
		end
	end)

	it("asks Discord to wait for the message on Discord's path only", function()
		expect(
			`{Config.PostUrl(H.URL_A)} | {Config.PostUrl(H.URL_PROXY .. "?thread_id=1")} | {Config.PostUrl(H.URL_CUSTOM)}`
		).toBe(`{H.URL_A}?wait=true | {H.URL_PROXY}?thread_id=1&wait=true | {H.URL_CUSTOM}`)
	end)

	it("refuses a route to a destination that does not exist, and an empty list", function()
		expect(refusal(base({ Routes = { Issues = "Nope" } }))).toBe(
			'Routes.Issues names a destination that is not in Webhooks: "Nope"'
		)
		expect(refusal(base({ Routes = { Issues = {} } }))).toBe(
			"Routes.Issues is an empty list; use false to disable the category"
		)
		expect(refusal(base({ Routes = { Everything = "Alerts" } }))).toBe(
			"Routes.Everything is not a report category; use Health, Issues, Warnings, Performance, Summaries, Leaderboards"
		)
	end)

	it("refuses a default that is not a destination, a bad role id, and a rule with no threshold", function()
		expect(refusal(base({ Default = "Missing" }))).toBe(
			'Default names a destination that is not in Webhooks: "Missing"'
		)
		expect(refusal(base({ Webhooks = { Alerts = { Url = H.URL_A, Mention = { RoleId = "abc" } } } }))).toBe(
			"Webhooks.Alerts.Mention.RoleId must be a role id as a string of digits"
		)
		expect(refusal(base({ Performance = { Rules = { SlowSaves = {} } } }))).toBe(
			"Performance.Rules.SlowSaves.Threshold must be a positive number; there is no default"
		)
	end)

	it("fills the documented defaults", function()
		local config = Config.Resolve(base())
		expect(
			`{config.GroupInterval} {config.SummariesEnabled} {config.SummaryInterval} {config.PerformanceChecks} {config.IncludePlayerIds} {config.AllowStudio}`
		).toBe("60 false 1800 3 false false")
		expect(config.WarningCodes.PROFILE_SIZE).toBe(true)
		expect(config.IconUrl).toBe(Config.LOGO_URL)
	end)
end)

describe("routing", function()
	it("sends a category to one destination, several, or nowhere when told so", function()
		local config = Config.Resolve(base({
			Routes = { Issues = "Alerts", Health = { "Alerts", "Health" }, Summaries = false },
		}))
		local function names(category)
			local resolution = Config.Route(config, category)
			local out = {}
			for _, dest in resolution.Destinations do
				table.insert(out, dest.Name)
			end
			if resolution.Skipped then
				return `{table.concat(out, ",")}skipped={resolution.Skipped}`
			end
			return table.concat(out, ",")
		end
		expect(`{names("Issues")} | {names("Health")} | {names("Summaries")}`).toBe(
			"Alerts | Alerts,Health | skipped=disabled"
		)
	end)

	it("falls back to the default only for an omitted route, never a disabled one", function()
		local withDefault = Config.Resolve(base({ Default = "Alerts", Routes = { Summaries = false } }))
		local without = Config.Resolve(base({ Routes = { Issues = "Alerts" } }))
		expect(
			`{#Config.Route(withDefault, "Warnings").Destinations} {Config.Route(withDefault, "Summaries").Skipped} {Config.Route(
				without,
				"Warnings"
			).Skipped}`
		).toBe("1 disabled unrouted")
	end)

	it("delivers once per webhook when two names share one URL or a route repeats a name", function()
		local config = Config.Resolve({
			Webhooks = { Alerts = { Url = H.URL_A }, AlsoAlerts = { Url = H.URL_A }, Health = { Url = H.URL_B } },
			Routes = { Health = { "Alerts", "AlsoAlerts", "Health", "Health" } },
		})
		expect(#Config.Route(config, "Health").Destinations).toBe(2)
	end)

	it("skips a category whose only destinations are disabled, and says so", function()
		local config = Config.Resolve({
			Webhooks = { Alerts = { Url = H.URL_A, Enabled = false } },
			Routes = { Issues = "Alerts" },
		})
		expect(Config.Route(config, "Issues").Skipped).toBe("none-enabled")
	end)
end)
