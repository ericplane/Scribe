--!nonstrict
-- The UI-framework adapters in /adapters.
--
-- They ship as copy-in files rather than as part of the package, so nothing here can
-- require Vide, React or Fusion. Each is driven against a minimal fake implementing the
-- exact contract the adapter uses, which is the point: these specs exist to catch a
-- drift in SCRIBE's client API that would silently break every copy already pasted into
-- a game. The React fake is a real hook harness (ordered hook slots, dependency
-- comparison, effect cleanup) because a fake that never re-renders would pass whatever
-- the adapter did.

return function()
	local RunService = game:GetService("RunService")
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot) :: any
	local Client = require(ScribeRoot.Client)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Adapters = Root.Adapters

	local itRunning = if RunService:IsRunning() then it else itSKIP

	local template = {
		Coins = Scribe.Int(0, { Min = 0 }),
		Pets = Scribe.SetOf(Scribe.String("")),
	}

	--- A live client mirror plus the server accessor that drives it.
	local function make()
		local harness = TestCtx.make({ Template = template, AutoPump = true })
		local player, _entry, data = harness.Join(78001)
		harness.Transport.LocalPlayer = player
		local client = Client.new(harness.Options, harness.Compiled)
		return harness, data, client
	end

	-- Fakes ---------------------------------------------------------------------------

	--- vide.source: a closure that reads with no argument and writes with one.
	local function fakeVide()
		return {
			source = function(initial)
				local stored = initial
				return function(...)
					if select("#", ...) > 0 then
						stored = (select(1, ...))
						return nil
					end
					return stored
				end
			end,
		}
	end

	--- Fusion's Value, in both calling conventions.
	local function fakeFusion(wantsScope: boolean)
		local seenScope = nil
		local api = {}
		function api.Value(a, b)
			local initial = a
			if wantsScope then
				seenScope = a
				initial = b
			end
			local v = { _value = initial }
			function v:set(new)
				self._value = new
			end
			return v
		end
		return api, function()
			return seenScope
		end
	end

	--- An ordered-hook renderer: enough React to exercise useState, useBinding and
	--- useEffect with dependency comparison and cleanup.
	local function fakeReact()
		local slots, cursor, pending, mounted = {}, 0, {}, false
		local component
		local R = {}
		local render

		function R.useState(init)
			cursor += 1
			local slot = cursor
			if slots[slot] == nil then
				slots[slot] = { value = if type(init) == "function" then init() else init }
			end
			return slots[slot].value,
				function(new)
					slots[slot].value = new
					if mounted then
						render()
					end
				end
		end

		function R.useBinding(initial)
			cursor += 1
			local slot = cursor
			if slots[slot] == nil then
				slots[slot] = { value = initial }
			end
			local s = slots[slot]
			-- A binding does NOT re-render: that is the whole reason to use one.
			return {
				getValue = function()
					return s.value
				end,
			}, function(new)
				s.value = new
			end
		end

		function R.useEffect(fn, deps)
			cursor += 1
			local slot = cursor
			local prev = slots[slot]
			local changed = prev == nil
			if not changed and prev.deps ~= nil and deps ~= nil then
				if #prev.deps ~= #deps then
					changed = true
				else
					for i = 1, #deps do
						if prev.deps[i] ~= deps[i] then
							changed = true
							break
						end
					end
				end
			end
			if changed then
				table.insert(pending, slot)
			end
			slots[slot] = { deps = deps, cleanup = if prev then prev.cleanup else nil, fn = fn }
		end

		function render()
			cursor = 0
			pending = {}
			local out = component()
			for _, slot in pending do
				local s = slots[slot]
				if s.cleanup then
					s.cleanup()
				end
				s.cleanup = s.fn()
			end
			return out
		end

		return R,
			function(fn)
				component = fn
				local out = render()
				mounted = true
				return out
			end,
			function()
				for _, s in slots do
					if s.cleanup then
						s.cleanup()
					end
				end
			end
	end

	-- Vide ----------------------------------------------------------------------------

	describe("Vide", function()
		itRunning("seeds from the current value and tracks every later change", function()
			local harness, data, client = make()
			data.Coins.Set(7)
			harness.StepUntil(function()
				return client.Coins.Get() == 7
			end, 8)

			local useScribe = require(Adapters.Vide)(fakeVide())
			local coins, disconnect = useScribe(client.Coins)
			local seeded = coins()

			data.Coins.Set(9)
			harness.StepUntil(function()
				return coins() == 9
			end, 8)
			local afterChange = coins()

			-- The disconnect has to actually stop it, or every closed UI leaks a listener.
			disconnect()
			data.Coins.Set(11)
			harness.StepUntil(function()
				return client.Coins.Get() == 11
			end, 8)
			local afterDisconnect = coins()

			harness.Cleanup()
			expect(`seeded={seeded} changed={afterChange} afterDisconnect={afterDisconnect}`).to.equal(
				"seeded=7 changed=9 afterDisconnect=9"
			)
		end)
	end)

	-- Fusion --------------------------------------------------------------------------

	describe("Fusion", function()
		itRunning("seeds and tracks, in the 0.2 convention with no scope", function()
			local harness, data, client = make()
			data.Coins.Set(3)
			harness.StepUntil(function()
				return client.Coins.Get() == 3
			end, 8)

			local Fusion = fakeFusion(false)
			local useScribe = require(Adapters.Fusion)(Fusion)
			local value, disconnect = useScribe(client.Coins)
			local seeded = value._value

			data.Coins.Set(4)
			harness.StepUntil(function()
				return value._value == 4
			end, 8)
			local changed = value._value

			disconnect()
			harness.Cleanup()
			expect(`seeded={seeded} changed={changed}`).to.equal("seeded=3 changed=4")
		end)

		itRunning("passes the scope through in the 0.3 convention", function()
			local harness, data, client = make()
			data.Coins.Set(5)
			harness.StepUntil(function()
				return client.Coins.Get() == 5
			end, 8)

			local Fusion, seenScope = fakeFusion(true)
			local myScope = { "a scope" }
			local useScribe = require(Adapters.Fusion)(Fusion, myScope)
			local value = useScribe(client.Coins)

			local scopeReachedFusion = seenScope() == myScope
			harness.Cleanup()
			-- Getting this backwards silently builds the Value with the scope as its
			-- initial value, which reads as "my UI shows a table".
			expect(`scope={scopeReachedFusion} seeded={value._value}`).to.equal("scope=true seeded=5")
		end)
	end)

	-- React ---------------------------------------------------------------------------

	describe("React", function()
		itRunning("re-renders with the new value, and cleans up on unmount", function()
			local harness, data, client = make()
			data.Coins.Set(2)
			harness.StepUntil(function()
				return client.Coins.Get() == 2
			end, 8)

			local R, mount, unmount = fakeReact()
			local adapter = require(Adapters.React)(R)
			local renders, lastSeen = 0, nil
			mount(function()
				renders += 1
				lastSeen = adapter.useScribe(client.Coins)
				return nil
			end)
			local firstSeen = lastSeen

			data.Coins.Set(6)
			harness.StepUntil(function()
				return lastSeen == 6
			end, 8)
			local afterChange, rendersAfter = lastSeen, renders

			unmount()
			data.Coins.Set(8)
			harness.StepUntil(function()
				return client.Coins.Get() == 8
			end, 8)
			local afterUnmount, rendersFinal = lastSeen, renders

			harness.Cleanup()
			expect(
				`first={firstSeen} changed={afterChange} afterUnmount={afterUnmount} `
					.. `rerendered={rendersAfter > 1} rendersAfterUnmount={rendersFinal - rendersAfter}`
			).to.equal("first=2 changed=6 afterUnmount=6 rerendered=true rendersAfterUnmount=0")
		end)

		itRunning("updates a binding WITHOUT re-rendering, which is why it exists", function()
			local harness, data, client = make()
			local R, mount, unmount = fakeReact()
			local adapter = require(Adapters.React)(R)
			local renders, binding = 0, nil
			mount(function()
				renders += 1
				binding = adapter.useScribeBinding(client.Coins)
				return nil
			end)
			local rendersAtMount = renders

			data.Coins.Set(42)
			harness.StepUntil(function()
				return binding.getValue() == 42
			end, 8)

			local seen = `value={binding.getValue()} extraRenders={renders - rendersAtMount}`
			unmount()
			harness.Cleanup()
			expect(seen).to.equal("value=42 extraRenders=0")
		end)

		itRunning("survives a resync without losing its subscription", function()
			-- A re-Hello rebuilds the mirror. The adapter subscribes once on mount, so if
			-- a resync replaced the listener tables the UI would go quietly dead.
			local harness, data, client = make()
			local R, mount, unmount = fakeReact()
			local adapter = require(Adapters.React)(R)
			local lastSeen = nil
			mount(function()
				lastSeen = adapter.useScribe(client.Coins)
				return nil
			end)

			harness.SendHello(harness.Transport.LocalPlayer)
			harness.StepUntil(function()
				return false
			end, 6)

			data.Coins.Set(77)
			harness.StepUntil(function()
				return lastSeen == 77
			end, 8)

			local seen = tostring(lastSeen)
			unmount()
			harness.Cleanup()
			expect(seen).to.equal("77")
		end)
	end)

	-- The property every adapter rests on -----------------------------------------------

	describe("the contract the adapters depend on", function()
		itRunning("Get is referentially stable, including across a resync", function()
			-- Not decoration. A fresh table per Get would make a React memo or a Vide
			-- derived recompute forever, and it is invisible until a UI is built on it.
			local harness, data, client = make()
			data.Pets.Add("Dragon")
			harness.StepUntil(function()
				return #client.Pets.Get() == 1
			end, 8)

			local before = client.Pets.Get()
			local stableBefore = client.Pets.Get() == client.Pets.Get()

			harness.SendHello(harness.Transport.LocalPlayer)
			harness.StepUntil(function()
				return false
			end, 6)

			local stableAfter = client.Pets.Get() == client.Pets.Get()
			local sameAcross = client.Pets.Get() == before

			data.Pets.Add("Griffin")
			harness.StepUntil(function()
				return #client.Pets.Get() == 2
			end, 8)
			local movedOnChange = client.Pets.Get() ~= before

			harness.Cleanup()
			expect(
				`stableBefore={stableBefore} stableAfter={stableAfter} `
					.. `sameAcrossResync={sameAcross} movedOnChange={movedOnChange}`
			).to.equal("stableBefore=true stableAfter=true sameAcrossResync=true movedOnChange=true")
		end)

		itRunning("one frame of writes is one notification, so no adapter needs debouncing", function()
			local harness, data, client = make()
			local fires = 0
			client.Coins.Changed(function()
				fires += 1
			end)
			data.Batch(function()
				data.Coins.Increment(1)
				data.Coins.Increment(1)
				data.Coins.Increment(1)
			end)
			harness.StepUntil(function()
				return fires > 0
			end, 8)
			local seen = `fires={fires} value={client.Coins.Get()}`
			harness.Cleanup()
			expect(seen).to.equal("fires=1 value=3")
		end)
	end)
end
