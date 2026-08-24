--!nonstrict
-- The error taxonomy the modelled disk raises.
--
-- Every message is frozen text, because callers match on it. ProfileStore decides
-- a version read failed by looking for "not valid" in the message, and Scribe's
-- own PROFILE_TOO_LARGE heuristic exists precisely because the errors it sees
-- carry no structure. Reword one of these and a consumer silently stops matching.
--
-- `Class` is the model's own annotation and is NOT visible to anything under test.
-- ProfileStore pcalls every store call and converts each failure into the same
-- RegisterError-plus-return-nil, so nothing downstream can tell a permanent
-- failure from a transient one. That is a real property worth preserving -- it is
-- why an oversized profile livelocks in retries rather than failing -- so the
-- class exists for the harness to assert on, never for the code under test to
-- branch on.
--
--   Transient      a retry could plausibly succeed
--   Permanent      a retry will fail identically forever
--   Indeterminate  the write may or may not have landed; the caller cannot know
--   Sim            the model complaining about the model, never a Roblox error
--
-- CONFIDENCE. The numbered codes and their wording follow Roblox's published
-- DataStore error table. Where the exact string could not be confirmed it is
-- marked UNCERTAIN below; those are matched on by nothing, so an imperfect
-- wording costs nothing today, but it must not be tightened into an assertion.

local Errors = {}

export type Class = "Transient" | "Permanent" | "Indeterminate" | "Sim"

export type Descriptor = {
	Code: number?,
	Message: string,
	Class: Class,
	Retryable: boolean,
}

local function describe(code: number?, message: string, class: Class, retryable: boolean): Descriptor
	return { Code = code, Message = message, Class = class, Retryable = retryable }
end

Errors.Catalog = {
	-- Input validation. Raised locally, before any latency or budget charge --
	-- Roblox rejects these client-side and they cost nothing.
	KeyEmpty = describe(101, "101: Key name can't be empty.", "Permanent", false),
	KeyTooLong = describe(102, "102: Key name exceeds the 50 character limit.", "Permanent", false),
	ValueNotAllowed = describe(103, "103: Value not allowed for this key.", "Permanent", false),
	ValueTooLarge = describe(105, "105: Serialized value exceeds 4194304 limit.", "Permanent", false),
	PageSizeInvalid = describe(106, "106: Page size must be between 1 and 100.", "Permanent", false),

	-- Throttling. Only ever raised on QUEUE OVERFLOW: ordinary budget exhaustion
	-- makes the caller wait, it does not fail. See Budget.
	RequestQueueFull = describe(
		301,
		"301: GetAsync request dropped. Request was throttled, but throttled request queue was full.",
		"Transient",
		true
	),
	SetQueueFull = describe(
		302,
		"302: SetAsync request dropped. Request was throttled, but throttled request queue was full.",
		"Transient",
		true
	),
	UpdateQueueFull = describe(
		303,
		"303: UpdateAsync request dropped. Request was throttled, but throttled request queue was full.",
		"Transient",
		true
	),
	RemoveQueueFull = describe(
		306,
		"306: RemoveAsync request dropped. Request was throttled, but throttled request queue was full.",
		"Transient",
		true
	),

	-- Service-side failures. The interesting ones: a real server sees these
	-- during a partial outage, and they are what Scribe's Health detector counts.
	ApiRejected = describe(502, "502: API Services rejected request with error. Status=Forbidden", "Transient", true),
	DataStoreUnavailable = describe(503, "503: DataStore Request successful, but key not found.", "Transient", true), -- UNCERTAIN wording
	RequestTimedOut = describe(504, "504: Datastore request timed out.", "Indeterminate", true),

	-- Metadata caps.
	AttributeSizeTooLarge = describe(511, "511: Metadata attribute size exceeds 300 bytes limit.", "Permanent", false),
	UserIdLimitExceeded = describe(512, "512: The UserIds limit was exceeded.", "Permanent", false),

	-- Version reads. ProfileStore STRING-MATCHES "not valid" on this one
	-- (its VersionQuery path), so those two words are load-bearing.
	VersionNotValid = describe(nil, "Requested version is not valid for this key.", "Permanent", false),

	-- The model complaining about the model. Never a Roblox code, and deliberately
	-- worded so it cannot be mistaken for one in a log.
	SimTransformYielded = describe(
		nil,
		"sim: an UpdateAsync transform yielded. Roblox forbids this; a yielding transform would hold ProfileStore's per-key update queue across the yield and manufacture interleavings production cannot reach.",
		"Sim",
		false
	),
	SimTransformLivelock = describe(
		nil,
		"sim: an UpdateAsync transform exceeded MaxTransformAttempts. Either contention on this key is pathological or the model is re-reading without making progress.",
		"Sim",
		false
	),
}

--- Raise `name` as the store would: message only, no position prefix.
---
--- level 0 because a DataStore error carries no Luau source location, and adding
--- one would make the model's errors distinguishable from real ones by shape --
--- which is exactly the tell that lets code accidentally special-case the sim.
function Errors.Raise(name: string, detail: string?): never
	local descriptor = Errors.Catalog[name]
	if descriptor == nil then
		error(`sim: unknown error "{name}"`, 0)
	end
	error(if detail then `{descriptor.Message} ({detail})` else descriptor.Message, 0)
end

--- Look up the descriptor a raised message came from, for harness assertions.
function Errors.Classify(message: string): Descriptor?
	for _, descriptor in Errors.Catalog do
		if string.find(message, descriptor.Message, 1, true) ~= nil then
			return descriptor
		end
	end
	return nil
end

return Errors
