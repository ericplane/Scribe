--!strict
-- Signal: the de-facto-standard batched, yield-safe Roblox signal (GoodSignal),
-- vendored so Scribe carries no external Signal dependency. Handlers run on a
-- cached runner thread (cheap yielding), connections form a linked list (so a
-- listener can disconnect another mid-fire safely), and a throwing handler is
-- surfaced by the scheduler rather than swallowed.
--
-- Adapted from GoodSignal by stravant (2021) and sleitnick's typed copy; both
-- MIT-licensed. Trimmed to the surface Scribe uses (new / Connect / Once /
-- Fire / Wait / DisconnectAll / Destroy).
-- https://devforum.roblox.com/t/lua-signal-class-comparison-optimal-goodsignal-class/1387063

export type Connection = {
	Disconnect: (self: Connection) -> (),
	Connected: boolean,
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Fire: (self: Signal<T...>, T...) -> (),
	Wait: (self: Signal<T...>) -> T...,
	Destroy: (self: Signal<T...>) -> (),
}

-- The currently idle runner thread. Handlers are resumed on it and it is
-- returned to idle when the handler completes, so it can be reused. If a
-- handler yields, this thread is taken over by the scheduler and Fire makes a
-- new one for the next handler.
local freeRunnerThread: thread? = nil

local function acquireRunnerThreadAndCallEventHandler(fn: (...any) -> (), ...)
	local acquired = freeRunnerThread
	freeRunnerThread = nil
	fn(...)
	freeRunnerThread = acquired
end

local function runEventHandlerInFreeThread(...)
	acquireRunnerThreadAndCallEventHandler(...)
	while true do
		acquireRunnerThreadAndCallEventHandler(coroutine.yield())
	end
end

-- Connection ------------------------------------------------------------------

local Connection = {}
Connection.__index = Connection

function Connection.Disconnect(self: any)
	if not self.Connected then
		return
	end
	self.Connected = false
	-- Unhook the node without clearing it, so a Fire currently iterating on it
	-- can still move forward; the node is GCed once no Fire references it.
	local signal = self._signal
	if signal._head == self then
		signal._head = self._next
	else
		local prev = signal._head
		while prev and prev._next ~= self do
			prev = prev._next
		end
		if prev then
			prev._next = self._next
		end
	end
end

-- Signal ----------------------------------------------------------------------

local Signal = {}
Signal.__index = Signal

function Signal.new(): any
	return setmetatable({ _head = false }, Signal)
end

function Signal.Connect(self: any, fn: (...any) -> ()): any
	local connection = setmetatable({
		Connected = true,
		_signal = self,
		_fn = fn,
		_next = self._head,
	}, Connection)
	self._head = connection
	return connection
end

function Signal.Once(self: any, fn: (...any) -> ()): any
	local connection
	connection = Signal.Connect(self, function(...)
		if connection.Connected then
			connection:Disconnect()
		end
		fn(...)
	end)
	return connection
end

function Signal.Fire(self: any, ...: any)
	local item = self._head
	while item do
		if item.Connected then
			if not freeRunnerThread then
				freeRunnerThread = coroutine.create(runEventHandlerInFreeThread)
			end
			task.spawn(freeRunnerThread :: thread, item._fn, ...)
		end
		item = item._next
	end
end

function Signal.Wait(self: any): ...any
	local waiting = coroutine.running()
	local connection
	connection = Signal.Connect(self, function(...)
		connection:Disconnect()
		task.spawn(waiting, ...)
	end)
	return coroutine.yield()
end

function Signal.DisconnectAll(self: any)
	local item = self._head
	while item do
		item.Connected = false
		item = item._next
	end
	self._head = false
end

Signal.Destroy = Signal.DisconnectAll

--------------------------------------------------------------------------------

local SignalModule = {}

function SignalModule.new(): any
	return Signal.new()
end

return SignalModule
