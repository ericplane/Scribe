--!nonstrict
-- MessagingService: the cross-server channel a session steal rides on.
--
-- DELIVERY IS DELIBERATELY UNORDERED, and that is a safety choice rather than a
-- convenience. Roblox documents no ordering guarantee for MessagingService, in
-- either direction. A model that assumed FIFO could HIDE a bug production has; a
-- model that reorders can at worst surface one production hides. Only the second
-- error is acceptable in a tool whose job is to find problems, so each message
-- draws its own delivery delay and messages routinely land out of order.
--
-- PUBLISHING FAILS BY DROPPING, NEVER BY RAISING. ProfileStore calls PublishAsync
-- bare inside a task.spawn with the error uncaught, so a bus that threw would
-- surface as a spawned-thread error and abort the entire run -- reporting a
-- harness artefact as a Scribe failure. Best-effort delivery is also what the
-- real service promises.
--
-- ProfileStore self-throttles its reaction to one message per six seconds per
-- subscription, so message volume is never the constraint here; latency and loss
-- are what change outcomes.

local Bus = {}
Bus.__index = Bus

-- Seconds. INVENTED, like the disk latencies -- Roblox publishes no figure. Named
-- so a sweep can move it and so no conclusion silently depends on it.
local BUS_LATENCY = 1.5
local BUS_JITTER = 1.0
local BUS_DROP_RATE = 0.0

function Bus.new(config)
	return setmetatable({
		_sched = config.Sched,
		_rng = config.Rng,
		_topics = {},
		-- jobId -> { Entries = { <subscription>, ... }, Severed = boolean }. The bus
		-- itself only knows about SUBSCRIPTIONS; this is the one place that knows
		-- which server made which, and it exists so `Sever` can cut a crashed one
		-- off in a single call. See the note on Sever.
		_servers = {},
		Latency = config.Latency or BUS_LATENCY,
		Jitter = config.Jitter or BUS_JITTER,
		DropRate = config.DropRate or BUS_DROP_RATE,
		Stats = { Published = 0, Delivered = 0, Dropped = 0 },
	}, Bus)
end

--- Deliver `data` to every subscriber of `topic`, each after its own delay.
---
--- Per-subscriber delays rather than one shared delay: two servers listening to
--- the same topic do not hear it at the same instant in reality, and making them
--- would remove an interleaving that genuinely exists.
function Bus.Publish(self, topic: string, data: any)
	self.Stats.Published += 1
	local subscribers = self._topics[topic]
	if subscribers == nil then
		return
	end

	for _, entry in table.clone(subscribers) do
		if self.DropRate > 0 and self._rng:NextNumber() < self.DropRate then
			self.Stats.Dropped += 1
			continue
		end
		local delay = self.Latency + self._rng:NextNumber() * self.Jitter
		self._sched:Delay(delay, function()
			-- Re-checked at delivery: a server can unsubscribe (or crash) while a
			-- message is in flight, and delivering to a torn-down handler would be
			-- a harness error rather than anything real.
			if entry.Connected then
				self.Stats.Delivered += 1
				entry.Handler({ Data = data, Sent = math.floor(self._sched.Now) })
			end
		end)
	end
end

function Bus.Subscribe(self, topic: string, handler: (any) -> ())
	local subscribers = self._topics[topic]
	if subscribers == nil then
		subscribers = {}
		self._topics[topic] = subscribers
	end
	local entry = { Handler = handler, Connected = true }
	table.insert(subscribers, entry)
	return entry
end

--- A MessagingService bound to one simulated server.
---
--- BOUND is the operative word, and it did not used to mean anything: the jobId
--- was ignored, so nothing could ever address a single server's traffic. Every
--- subscription this factory hands out is now recorded against `jobId`, which is
--- what makes `Sever` possible.
function Bus.ServiceFor(self, jobId: string)
	local bus = self
	local record = bus._servers[jobId]
	if record == nil then
		record = { Entries = {}, Severed = false }
		bus._servers[jobId] = record
	end
	return {
		SubscribeAsync = function(_self, topic: string, handler: (any) -> ())
			bus._sched:Wait(0.05) -- subscribing is a network call
			-- Re-checked AFTER the wait, not only recorded: the server can be severed
			-- while this subscribe is still on the wire, and a subscription that
			-- completed into a dead process would put it straight back on the bus.
			if record.Severed then
				return { Disconnect = function() end }
			end
			local entry = bus:Subscribe(topic, handler)
			table.insert(record.Entries, entry)
			return {
				Disconnect = function()
					entry.Connected = false
				end,
			}
		end,
		PublishAsync = function(_self, topic: string, data: any)
			bus._sched:Wait(0.05)
			if record.Severed then
				return
			end
			bus:Publish(topic, data)
		end,
	}
end

--- Cut one server off the bus entirely: nothing delivered in, nothing published
--- out, permanently.
---
--- WHY THIS LIVES HERE AND NOT AS A `Dead` CHECK INSIDE Publish. The bus has no
--- notion of a server at all -- it holds topics and subscription entries, and
--- Publish already re-checks `entry.Connected` at delivery time for the ordinary
--- unsubscribe case. What was missing was never the check; it was anything that
--- FLIPPED those entries when a server died. Server.Crash set Dead = true, emptied
--- the player table and stopped, leaving the crashed server's ProfileStore
--- subscriptions live -- so it kept receiving the session-steal nudge, kept
--- answering it, and could perform a release save after the machine it ran on was
--- supposed to be gone. An auditor's entire crash row was a false green until they
--- forced BusDropRate = 1.0 by hand.
---
--- Both directions, because a half-severed process models nothing real: there is
--- no machine that can still publish but not receive. And the flag LATCHES rather
--- than only sweeping the existing entries, because a crashed server's threads are
--- still in the scheduler and one of them may be part-way through a subscribe.
function Bus.Sever(self, jobId: string)
	local record = self._servers[jobId]
	if record == nil then
		return
	end
	record.Severed = true
	for _, entry in record.Entries do
		entry.Connected = false
	end
	table.clear(record.Entries)
end

Bus.BUS_LATENCY = BUS_LATENCY

return Bus
