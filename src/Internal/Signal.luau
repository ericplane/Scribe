--!strict
-- Signal provider. Prefers the sleitnick/signal Wally dependency when it is
-- installed as a sibling of the Scribe package; otherwise falls back to a
-- small built-in implementation with the same surface (new/Connect/Once/
-- Fire/Wait/Destroy). The fallback keeps Scribe functional in storybooks and
-- test rigs where Packages aren't wired up.

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

local function findExternalSignal(): any
	-- The Scribe package root is the parent of the Internal folder.
	local packageRoot = script.Parent and script.Parent.Parent
	local candidates: { Instance? } = {
		packageRoot and packageRoot.Parent, -- wally _Index sibling links
	}
	for _, container in candidates do
		if container then
			local found = container:FindFirstChild("Signal")
			if found and found:IsA("ModuleScript") then
				local ok, mod = pcall(require, found)
				if ok and type(mod) == "table" and type((mod :: any).new) == "function" then
					return mod
				end
			end
		end
	end
	return nil
end

-- Built-in fallback -----------------------------------------------------------

local FallbackSignal = {}
FallbackSignal.__index = FallbackSignal

function FallbackSignal.new()
	return setmetatable({ _handlers = {} :: { [any]: (...any) -> () } }, FallbackSignal)
end

function FallbackSignal.Connect(self: any, fn: (...any) -> ()): Connection
	local connection: any
	connection = {
		Connected = true,
		Disconnect = function()
			connection.Connected = false
			self._handlers[connection] = nil
		end,
	}
	self._handlers[connection] = fn
	return connection
end

function FallbackSignal.Once(self: any, fn: (...any) -> ()): Connection
	local connection: Connection
	connection = FallbackSignal.Connect(self, function(...)
		connection:Disconnect()
		fn(...)
	end)
	return connection
end

function FallbackSignal.Fire(self: any, ...: any)
	for _, fn in self._handlers do
		task.spawn(fn, ...)
	end
end

function FallbackSignal.Wait(self: any): ...any
	local thread = coroutine.running()
	local connection: Connection
	connection = FallbackSignal.Connect(self, function(...)
		connection:Disconnect()
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function FallbackSignal.Destroy(self: any)
	table.clear(self._handlers)
end

-- Some Signal implementations use DisconnectAll instead of Destroy.
FallbackSignal.DisconnectAll = FallbackSignal.Destroy

--------------------------------------------------------------------------------

local external = findExternalSignal()
local provider: any = external or FallbackSignal

local SignalModule = {}

function SignalModule.new(): any
	return provider.new()
end

return SignalModule
