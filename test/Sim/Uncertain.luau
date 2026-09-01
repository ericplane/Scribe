--!nonstrict
-- The register of every number in this simulation that Roblox does not document.
--
-- Read this before quoting any result. These are INVENTED -- plausible, named, and
-- collected here so that a conclusion depending on one can be identified as such
-- rather than reported as a fact about Scribe.
--
-- The rule the sweep spec enforces: any headline finding must be reproduced across
-- at least two settings of every constant it could plausibly depend on. A result
-- that appears under one and vanishes under another is a property of THIS FILE,
-- and has to be reported that way.
--
-- Each entry says where the real constant lives, so there is exactly one place to
-- correct when Roblox documents something or someone measures it properly. This
-- module deliberately holds no values of its own for constants that already have a
-- home -- duplicating them is how two sources of truth start disagreeing.

local Uncertain = {}

export type Entry = {
	Id: string,
	Quantity: string,
	Documented: string,
	Default: string,
	Where: string,
	Direction: string, -- which way an error biases the result, when that is knowable
}

Uncertain.REGISTER = {
	{
		Id = "U1",
		Quantity = "DataStore operation latency",
		Documented = "Nothing. No figure appears in any Roblox document.",
		Default = "Nominal: read 20-90ms, write 40-150ms, 2% tail to 450/700ms",
		Where = "test/Sim/Disk/Latency.luau -> Latency.PROFILES",
		Direction = "Unknown. Latency sets the width of every conflict window, so contention findings depend on it directly. Sweep Nominal and Slow on every result.",
	},
	{
		Id = "U2",
		Quantity = "Budget accrual mechanism",
		Documented = "Limits are stated per minute. How they accrue is never described.",
		Default = "Trickle (limit/60 per second)",
		Where = "test/Sim/Disk/Budget.luau -> Budget.Mode",
		Direction = "Bucket is harsher immediately after a minute rollover and more forgiving before it. Both ship; report which conclusions move.",
	},
	{
		Id = "U4",
		Quantity = "Token cap / burst ceiling",
		Documented = "Undocumented.",
		Default = "1x the per-minute rate (no banking beyond one minute)",
		Where = "test/Sim/Disk/Budget.luau -> MAX_FACTOR",
		Direction = "Conservative. A real burst allowance would make the model report MORE throttling than production, never less.",
	},
	{
		Id = "U5",
		Quantity = "Throttle queue depth",
		Documented = "Community-reported as 30 per queue; absent from current docs.",
		Default = "30",
		Where = "test/Sim/Disk/Budget.luau -> QUEUE_DEPTH",
		Direction = "A shallower queue drops sooner. Since drops are the only path to a throttle error, this sets how often 301-306 appear at all.",
	},
	{
		Id = "U6",
		Quantity = "UpdateAsync retry bound",
		Documented = "Docs say retries are unbounded; no request timeout is specified.",
		Default = "100 attempts",
		Where = "test/Sim/Disk/init.luau -> Config.MaxTransformAttempts",
		Direction = "A bound production does not have. It raises Errors.SimTransformLivelock with Class = 'Sim', never a Roblox code, so 'the sim hit its own ceiling' can never be misread as 'Scribe livelocked'.",
	},
	{
		Id = "U7",
		Quantity = "task.wait() frame quantum",
		Documented = "'One frame'. The frame rate is not specified.",
		Default = "1/60",
		Where = "test/Sim/Env.luau -> FRAME_QUANTUM",
		Direction = "Sets the cost of every busy-poll loop in ProfileStore. Digests do NOT match across quanta -- this is a sensitivity check, never an equality check.",
	},
	{
		Id = "U8",
		Quantity = "MessagingService latency",
		Documented = "~1s, loosely, and it is the only figure published anywhere nearby.",
		Default = "1.5s plus up to 1.0s of jitter",
		Where = "test/Sim/Bus.luau -> BUS_LATENCY / BUS_JITTER",
		Direction = "Slower than published, deliberately. A slower steal notification means a LONGER contended handoff, so the model cannot hide a race by resolving it too quickly.",
	},
	{
		Id = "U9",
		Quantity = "MessagingService ordering",
		Documented = "Neither FIFO nor reordering is guaranteed.",
		Default = "unordered, optionally lossy",
		Where = "test/Sim/Bus.luau -> Bus.Publish",
		Direction = "SAFE DIRECTION ONLY. A weaker model can surface bugs production hides; it can never hide a bug production has. Assuming FIFO would be the unsafe choice.",
	},
	{
		Id = "U11",
		Quantity = "GetAsync cache window",
		Documented = "4 seconds.",
		Default = "disabled (0)",
		Where = "not implemented; noted here deliberately",
		Direction = "Omitting the cache makes the model see MORE traffic and FRESHER reads than production. It can overstate load; it cannot hide a bug.",
	},
	{
		Id = "U13",
		Quantity = "Simulation tick period",
		Documented = "n/a -- pure cost, not fidelity.",
		Default = "1.0s",
		Where = "test/Sim/Universe.luau -> TICK_PERIOD",
		Direction = "Measured behaviour-flat from 1/60 to 5s (autosave count identical). Must stay below ProfileStore's finest deadline, FIRST_LOAD_REPEAT = 5.",
	},
	{
		Id = "U14",
		Quantity = "Remote payload ceiling (server -> one client)",
		Documented = "Nothing usable. No per-FireClient byte limit appears in any Roblox document.",
		Default = "No ceiling. Link raises only when a spec sets MaxFrameBytes; StubTransport models none at all.",
		Where = "test/Sim/Link.luau -> Link.new(MaxFrameBytes)",
		Direction = "MEASURED, not invented, and it corrected this model rather than justifying it: a FireClient of 32 MiB of incompressible data was delivered IN FULL on a live server with a real client -- no raise, no drop, no disconnect, at roughly 30 MiB/s. Platform remotes do not refuse, so a raising channel is a HOSTILE transport, not a faithful one. Boundary: one client on an otherwise idle connection. The aggregate case -- a server pushing large frames to fifty players at once -- is UNMEASURED, and is the case where a real ceiling would most plausibly exist. Do not quote this as evidence that size does not matter at scale.",
	},
	{
		Id = "U12",
		Quantity = "Whether UpdateAsync spends the read request budget as well as the write one",
		Documented = "Limits are listed per request type. Whether one UpdateAsync draws on both allowances is never stated.",
		Default = "It draws on both: one StandardRead and one StandardWrite per call",
		Where = "test/Sim/Disk/init.luau -> POOL_FOR_REQUEST_TYPE",
		Direction = "Sizes GET_RESERVE in src/Server/Persistence.luau. If UpdateAsync does NOT charge reads, a join spends no read allowance, the reserve protects only the sessionless paths, and it is merely oversized. If it DOES, a filling server draws on the same pool a migration is pacing against and the reserve is load-bearing. Measured in this model at one read and one write per join (SimBudget). UNVERIFIED against the engine.",
	},
} :: { Entry }

--- The sweep matrix: settings a headline result must be reproduced across.
Uncertain.SWEEPS = {
	LatencyProfile = { "Instant", "Fixed", "Nominal", "Slow" },
	BudgetMode = { "Trickle", "Bucket" },
}

function Uncertain.Find(id: string): Entry?
	for _, entry in Uncertain.REGISTER do
		if entry.Id == id then
			return entry
		end
	end
	return nil
end

return Uncertain
