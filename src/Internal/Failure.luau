--!strict
-- Classifies a DataStore failure into one of four outcomes and reports it. Failure.Report
-- at the bottom is the single entry point every failure site uses.
--
--   Throttled   dropped; back off, retrying makes it worse
--   Failed      a transient service-side failure; a retry may well work
--   Unresolved  timed out and the write may have landed, so it cannot be retried blindly
--   Rejected    permanently invalid (oversize payload, bad key, metadata cap); every
--               retry fails identically forever
--
-- Only the numeric prefix of the error string is read ("504: Datastore request timed
-- out."); the prose after the colon is not a contract. An unrecognised code classifies as
-- Failed, with the parsed code in the log context so a family that starts showing up
-- unclassified is visible rather than silent.

local Health = require(script.Parent.Health)
local Log = require(script.Parent.Log)
local Metrics = require(script.Parent.Metrics)
local Types = require(script.Parent.Parent.Types)

local Failure = {}

export type Class = "Throttled" | "Failed" | "Unresolved" | "Rejected"

-- Codes whose class does not follow from its family. Everything else falls back
-- to the family rule below, so a code Roblox adds inside a known family is
-- classified sensibly without this table being updated.
local EXPLICIT: { [number]: Class } = {
	-- A timeout is not a failure: the write may have committed before the error
	-- came back.
	[504] = "Unresolved",
	-- Metadata caps sit in the 5xx family but are permanent misuse, not service
	-- trouble: the same call will fail the same way forever.
	[511] = "Rejected",
	[512] = "Rejected",
	[513] = "Rejected",
}

--- Class for a whole code family, used when EXPLICIT has no entry.
---
--- 1xx is input validation, which Roblox rejects on the same input every time.
--- 3xx is throttling. 5xx is the service having trouble.
local function byFamily(code: number): Class
	if code >= 100 and code < 200 then
		return "Rejected"
	elseif code >= 300 and code < 400 then
		return "Throttled"
	elseif code >= 500 and code < 600 then
		return "Failed"
	end
	return "Failed"
end

--- The numeric code a DataStore error message carries, or nil if it carries none.
--- Anchored on purpose: a loose search for digits-then-colon would eventually match a
--- number inside a key name and report a confident wrong class. nil classifies as
--- Failed, the safe default.
function Failure.CodeOf(message: any): number?
	if type(message) ~= "string" then
		return nil
	end
	return tonumber(string.match(message, "^%s*(%d+):"))
end

--- Classify a DataStore error message.
function Failure.Classify(message: any): Class
	local code = Failure.CodeOf(message)
	if code == nil then
		return "Failed"
	end
	return EXPLICIT[code] or byFamily(code)
end

-- One failed operation, reported everywhere it belongs -----------------------
--
-- Health collapses retries of one operation into a single problem. The log follows
-- Health's own verdict rather than approximating it, so the identity rule (subsystem
-- namespacing, the shared throttle subject, the retry cooldown) stays in one place.
--
-- Collapsing is keyed on (subsystem, subject), so a report with no Key is never
-- collapsed and always logs. A burst that ends never prints its tail, because the tally
-- dies with its identity; `FailuresCollapsed` always moves, and the Repeats field on the
-- next line covers the rest.
export type Report = {
	-- Health subsystem: a fixed internal literal, never a value from outside.
	Subsystem: string,
	-- The subject of the operation, a profile key or a user id. Omit it only where
	-- there genuinely is none: omitting it means retries count and log separately.
	Key: string?,
	-- The raw error, classified. Supplying it is what enables the per-class metric
	-- dimension, because a class derived from nothing is not a measurement.
	Error: any?,
	-- Already classified by the caller (the ProfileStore OnError path classifies
	-- before it knows whether it has an entry to attribute to).
	Class: Class?,
	-- One counter family. Bumped as-is, plus `<Metric>_<Class>` when a real error
	-- was classified. Most sites need nothing here.
	Metric: string?,
	Level: ("Warn" | "Error")?,
	Category: Types.LogCategory,
	Code: Types.LogCode,
	Message: string,
	Context: { [string]: any }?,
}

--- Report one failed operation: classify it, count it, and say so once.
---
--- Returns `(class, logged)`. `logged` is false when this report was folded into
--- a live problem for the same subject.
function Failure.Report(report: Report): (Class, boolean)
	local classified = report.Error ~= nil or report.Class ~= nil
	local class: Class = report.Class or Failure.Classify(report.Error)

	local counted, folded = Health.ReportFailure(report.Subsystem, report.Key, class)

	local metric = report.Metric
	if metric ~= nil then
		Metrics.Add(metric)
		-- Only where a real error message was read: a class defaulted from nothing
		-- reads as a measurement and is not one.
		if classified then
			Metrics.Add(metric .. "_" .. class)
		end
	end

	if not counted then
		Metrics.Add("FailuresCollapsed")
		return class, false
	end

	local context = report.Context
	if folded > 0 then
		-- Copied rather than mutated: the caller's table may be a literal it also
		-- uses elsewhere.
		local merged: { [string]: any } = {}
		if context then
			for key, value in context do
				merged[key] = value
			end
		end
		merged.Repeats = folded
		context = merged
	end

	if report.Level == "Error" then
		Log.Error(report.Category, report.Code, report.Message, context)
	else
		Log.Warn(report.Category, report.Code, report.Message, context)
	end
	return class, true
end

return Failure
