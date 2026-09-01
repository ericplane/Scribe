--!nonstrict
-- Client.Stop, the client bundle's teardown. A storybook remounts a bundle per story and
-- a test suite builds hundreds; without it each one leaves a listener behind.

return function()
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot) :: any
	local Client = require(ScribeRoot.Client)
	local Clock = require(ScribeRoot.Internal.Clock)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local template = { Coins = Scribe.Int(0, { Min = 0 }) }

	--- Counts Release calls. All four members, because the Lune harness reports IsServer and
	--- Resolve then validates the server pair too.
	local function spyTransport()
		local spy = { Releases = 0, Listener = nil }
		spy.Adapter = {
			Name = "Spy",
			SendToClient = function() end,
			ListenServer = function() end,
			SendToServer = function() end,
			ListenClient = function(_, callback)
				spy.Listener = callback
			end,
			Release = function()
				spy.Releases += 1
			end,
		}
		return spy
	end

	--- A LocalPlayer whose subscription watch counts its disconnects.
	local function installLocalPlayer()
		local disconnected = 0
		local player = {
			Name = "Local",
			UserId = 78101,
			HasRobloxSubscription = false,
			GetPropertyChangedSignal = function()
				return {
					Once = function()
						return {
							Disconnect = function()
								disconnected += 1
							end,
						}
					end,
				}
			end,
		}
		Client.SetLocalPlayerProbe(function()
			return player
		end)
		return function()
			return disconnected
		end, function()
			Client.SetLocalPlayerProbe(nil)
		end
	end

	local function makeClient(spy, extra)
		local options = { Transport = spy.Adapter, Banner = false }
		for k, v in extra or {} do
			options[k] = v
		end
		local harness = TestCtx.make({ Template = template, Options = options })
		return harness, Client.new(harness.Options, harness.Compiled)
	end

	it("releases the transport listener, exactly ONCE, however often it is called", function()
		local spy = spyTransport()
		local harness, client = makeClient(spy)
		task.wait()
		client.Stop()
		client.Stop()
		client.Stop()
		harness.Cleanup()
		expect(`listened={spy.Listener ~= nil} releases={spy.Releases}`).to.equal("listened=true releases=1")
	end)

	it("disconnects the subscription watch it armed", function()
		local disconnected, restore = installLocalPlayer()
		local spy = spyTransport()
		local harness, client = makeClient(spy, {
			Passes = { VIP = { Id = 111 } },
			GetProductInfoAsync = function()
				return { PriceInRobux = 1, UserBasePriceInRobux = 1 }
			end,
		})
		client.GetPrice("VIP")
		task.wait()
		local before = disconnected()
		client.Stop()
		local after = disconnected()
		restore()
		harness.Cleanup()
		expect(`before={before} after={after}`).to.equal("before=0 after=1")
	end)

	it("tolerates an adapter with no Release", function()
		-- Release is optional on ScribeTransport.
		local harness = TestCtx.make({
			Template = template,
			Options = {
				Banner = false,
				Transport = {
					Name = "Bare",
					SendToClient = function() end,
					ListenServer = function() end,
					SendToServer = function() end,
					ListenClient = function() end,
				},
			},
		})
		local client = Client.new(harness.Options, harness.Compiled)
		task.wait()
		local ok, err = pcall(client.Stop)
		harness.Cleanup()
		expect(`ok={ok} err={tostring(err)}`).to.equal("ok=true err=nil")
	end)

	it("stops the Hello retry loop", function()
		-- A Wait that yields one frame makes the retry cadence frames rather than jittered
		-- seconds, so the control (it retries at all) and the claim (not after Stop) are
		-- both measured in the same few frames.
		local waitImpl = Clock.Wait
		Clock.Install({
			Wait = function()
				return task.wait()
			end,
		})
		local sends = 0
		local harness = TestCtx.make({
			Template = template,
			Options = {
				Banner = false,
				Transport = {
					Name = "Counting",
					SendToClient = function() end,
					ListenServer = function() end,
					SendToServer = function()
						sends += 1
					end,
					ListenClient = function() end,
				},
			},
		})
		local client = Client.new(harness.Options, harness.Compiled)
		for _ = 1, 6 do
			task.wait()
		end
		local beforeStop = sends
		client.Stop()
		local atStop = sends
		for _ = 1, 12 do
			task.wait()
		end
		local later = sends
		Clock.Install({ Wait = waitImpl })
		harness.Cleanup()
		expect(`retriedBeforeStop={beforeStop > 1} grewAfterStop={later > atStop}`).to.equal(
			"retriedBeforeStop=true grewAfterStop=false"
		)
	end)
end
