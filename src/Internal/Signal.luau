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

-- The currently idle runner thread, reused across handlers. A handler that yields
-- takes it over, and Fire makes a new one for the next handler.
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

--[=[
	@class Connection

	What [Connect](signal.md#connect) and [Once](signal.md#once) hand back: a handle
	on one handler, and the only way to detach it again.

	It carries a `Connected` boolean you may read, `true` until the handler is
	detached. Everything else on it is Scribe's own bookkeeping.
]=]
local Connection = {}
Connection.__index = Connection

--[=[
	@method Disconnect
	@within Connection
	@tag Methods
	Detaches the handler. It will not run on any later fire, and `Connected` becomes
	`false`.

	```lua
	local conn = Data.OnSave:Connect(report)
	conn:Disconnect()
	```

	Calling it twice is a no-op rather than an error, so a teardown path that runs
	more than once is safe. It is also safe from inside a handler, including on
	another connection of the same signal: a connection detached mid-fire does not
	run for that fire if its turn has not come yet.
]=]
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

--[=[
	@class Signal

	The object behind every `On...` member Scribe exposes, such as [Server.OnSave] or
	[Client.OnLeaderboard]. You never construct one and you never fire one; you
	connect to one.

	Each handler runs on its own thread, so a handler may yield with `task.wait`
	without holding up the other handlers or the code that fired. A handler that
	raises does not stop its siblings and does not break the signal: the error
	reaches the output with its traceback, and the next fire behaves normally.

	Order is not part of the contract. Never write two handlers where one has to run
	before the other; put both steps in one handler instead.

	The methods below are called with a colon, `Data.OnSave:Connect(fn)`, so the
	signatures drop the implicit `self`. The [Session Lifecycle](../lifecycle.md#working-with-signals)
	guide shows the everyday shape.
]=]
local Signal = {}
Signal.__index = Signal

function Signal.new(): any
	return setmetatable({ _head = false }, Signal)
end

--[=[
	@method Connect
	@within Signal
	@tag Methods
	@param handler (...any) -> ()
	@return Connection
	Runs `handler` on every fire, with the arguments the signal fires. Returns a
	[Connection](connection.md), which is how you stop listening again.

	```lua
	local conn = Data.OnSave:Connect(function(info)
	    print(info.Player, info.Ok)
	end)
	```

	Connecting during a fire does not join that fire; the new handler starts with
	the next one. There is no duplicate check, so connecting the same function twice
	runs it twice.
]=]
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

--[=[
	@method HasListeners
	@within Signal
	@tag Inspecting
	@return boolean
	Whether at least one handler is connected right now. It counts live connections
	only: one dropped with [Disconnect](connection.md#disconnect), or by
	[DisconnectAll](#disconnectall), stops counting immediately.

	Scribe uses it to skip building an argument that nobody would read. In game code
	it is mostly a teardown check, so that work feeding a signal can stop once the
	last listener leaves. It cannot tell one listener from four, so never use it to
	decide whether the connection still attached is yours.
]=]
-- `_head` is false when empty and a connection otherwise; Disconnect unlinks, so
-- the chain only ever holds live connections.
function Signal.HasListeners(self: any): boolean
	return not not self._head
end

--[=[
	@method Once
	@within Signal
	@tag Methods
	@param handler (...any) -> ()
	@return Connection
	Runs `handler` on the next fire only, then detaches it. Returns the same
	[Connection](connection.md) that [Connect](#connect) does, so you can cancel
	before that fire ever arrives.

	The detach happens before `handler` runs, so a handler that raises, or that
	somehow causes the signal to fire again, still cannot run a second time.
]=]
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

-- Fires like Fire does, one isolated thread per handler, then hands
-- `onSettled(ran, ok, err)` the outcome once the last handler has returned or
-- raised. Fire alone cannot say whether a handler ran, finished or blew up, and
-- the cross-server message drain has to know: retiring a message whose handler
-- never observed it destroys it.
--
-- `ran` is how many connections were live at the call, `ok` is false if any of
-- them raised, `err` is the first error. onSettled runs synchronously when no
-- handler yielded, otherwise on the last handler's thread. A handler that yields
-- and never returns never settles, so the caller is never told to acknowledge.
--
-- Not on the exported Signal type: internal machinery, like HasListeners.
function Signal.FireTracked(self: any, onSettled: (number, boolean, any) -> (), ...: any)
	local ran, settled = 0, 0
	local failed, firstError = false, nil
	-- False while the list is still being walked, so a handler that completes
	-- synchronously cannot settle the fire before its siblings are spawned.
	local dispatched = false
	local function finish(ok: boolean, err: any)
		settled += 1
		if not ok and not failed then
			failed = true
			firstError = err
		end
		if dispatched and settled == ran then
			onSettled(ran, not failed, firstError)
		end
	end
	local item = self._head
	while item do
		if item.Connected then
			ran += 1
			local fn = item._fn
			-- A fresh thread per handler rather than Fire's cached runner, which cannot
			-- report when a handler ended. Message delivery is not a hot path.
			task.spawn(function(...)
				finish(pcall(fn, ...))
			end, ...)
		end
		item = item._next
	end
	dispatched = true
	if settled == ran then
		onSettled(ran, not failed, firstError)
	end
end

--[=[
	@method Wait
	@within Signal
	@tag Methods
	@yields
	@return ...any
	Yields the calling thread until the next fire, then returns that fire's
	arguments. It starts listening at the moment you call it, so a fire that already
	happened is neither waited for nor replayed.

	```lua
	local userId, shared = Data.OnSharedChanged:Wait()
	```

	Call it from a coroutine or a `task.spawn`, never from the main body of a script
	that has to keep going. If nothing ever fires, or the signal is cleared by
	[DisconnectAll](#disconnectall) while you wait, the thread stays parked for good.
	Prefer [Once](#once) whenever you have somewhere else to be.
]=]
function Signal.Wait(self: any): ...any
	local waiting = coroutine.running()
	local connection
	connection = Signal.Connect(self, function(...)
		connection:Disconnect()
		task.spawn(waiting, ...)
	end)
	return coroutine.yield()
end

--[=[
	@method DisconnectAll
	@within Signal
	@tag Methods
	Detaches every handler at once and empties the list. Existing
	[Connection](connection.md) objects report `Connected = false` afterwards, and
	disconnecting one of them again is a no-op.

	A fire already in flight is not recalled, so handlers dispatched before the call
	still run. A thread parked in [Wait](#wait) is left parked, because the fire it
	was waiting for can no longer reach it.

	The signal stays usable. Connect to it again and it fires again.
]=]
function Signal.DisconnectAll(self: any)
	local item = self._head
	while item do
		item.Connected = false
		item = item._next
	end
	self._head = false
end

--[=[
	@method Destroy
	@within Signal
	@tag Methods
	The same function as [DisconnectAll](#disconnectall), under the name most Roblox
	objects use. It detaches every handler and does nothing further: no instance is
	destroyed, nothing beyond the handler list is released, and the signal still
	works if you connect to it again.

	You will rarely need it. The signals Scribe hands you live as long as the server
	or the client session does, so this is for a signal you made yourself.
]=]
Signal.Destroy = Signal.DisconnectAll

--------------------------------------------------------------------------------

local SignalModule = {}

function SignalModule.new(): any
	return Signal.new()
end

return SignalModule
