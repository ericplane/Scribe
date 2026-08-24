--!nonstrict
-- The built-in transport channel has to be handed back on `Data.Stop()`.
--
-- `Transport.Resolve("Default")` claims a channel in a module-level table and
-- errors if anyone claims it twice -- correctly, because two Scribe instances on
-- one pair of RemoteEvents would receive each other's frames and fail schema
-- decoding. Nothing ever released the claim, and nothing disconnected the
-- `OnServerEvent` listener it installed.
--
-- So a stopped bundle keeps a live inbound path: a client frame still reaches it,
-- still runs registered Command handlers, still mutates profile data that the
-- now-dead flush and save paths will never persist, and still replies over the
-- RemoteEvent. And the channel can never be rebound, which directly defeats the
-- documented reason `Stop` exists -- "a process that builds many bundles (a test
-- suite, or a simulation standing up a fleet of servers)".
--
-- Monetization already does exactly this for its own module-global (`receiptsBound`
-- is cleared in `Stop`); the transport did not.
--
-- The headless shim's `Instance.new("RemoteEvent")` has no `OnServerEvent`, so
-- `buildDefault` cannot construct one unaided. The remotes are pre-wired into
-- ReplicatedStorage below and `buildDefault`'s own FindFirstChild path then runs
-- UNMODIFIED -- this drives the real transport, not a stub of it.
return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Server = require(Root.Scribe.Server) :: any
	local Transport = require(Root.Scribe.Internal.Transport) :: any
	local Template = require(Root.Scribe.Internal.Template)
	local FakeProfileStore = require(Root.Test.Helpers.FakeProfileStore)

	local compiled = Template.Compile({ Coins = Scribe.Int(0, { Min = 0 }) }, {})

	--- The smallest thing RemoteEvent.OnServerEvent has to be.
	local function fakeSignal()
		local handlers = {}
		return {
			Connect = function(_self, fn)
				local connection
				connection = {
					Connected = true,
					Disconnect = function()
						connection.Connected = false
						handlers[connection] = nil
					end,
				}
				handlers[connection] = fn
				return connection
			end,
			Fire = function(...)
				for _, fn in handlers do
					fn(...)
				end
			end,
			Count = function()
				local n = 0
				for _ in handlers do
					n += 1
				end
				return n
			end,
		}
	end

	--- Whether `Instance.new("RemoteEvent")` on this host produces a usable RemoteEvent.
	---
	--- This is the one host difference the file turns on, and it is the difference the
	--- header describes: headless, a fabricated RemoteEvent has no `OnServerEvent`, so
	--- `buildDefault` cannot construct the pair itself and the pair has to be planted
	--- for it. Under Roblox it can, so there is nothing to plant. Probing the member on
	--- a freshly built instance answers it directly -- the shim's fake Instance returns
	--- nil for an unknown member, and a real RemoteEvent returns the signal. The
	--- unparented probe is unreferenced afterwards and collected.
	local remotesAreReal = typeof((Instance.new("RemoteEvent") :: any).OnServerEvent) == "RBXScriptSignal"

	--- Make sure `channel` has a Down/Up pair, and hand back a handle that undoes it.
	---
	--- `Up.Count()` is the number of inbound listeners on the Up remote, or nil where
	--- the host will not say: Roblox exposes no way for ordinary code to enumerate an
	--- RBXScriptSignal's connections. Nil rather than 0, because the two nodes that read
	--- it assert a COUNT, and answering zero everywhere would turn "no listener was
	--- left behind" into a sentence that is true by construction.
	---
	--- Under Roblox `buildDefault` creates the folder and both remotes on its own, so
	--- there is nothing to pre-wire and this only has to clean up after it. Headless the
	--- pair is planted, after which buildDefault's own FindFirstChild path runs
	--- UNMODIFIED -- which is what makes this drive the real transport, not a stub.
	local function wireChannel(channel)
		local name = `ScribeTransport_{channel}`
		if remotesAreReal then
			return {
				Name = name,
				Up = {
					Count = function(): number?
						return nil
					end,
				},
			}
		end
		local up = fakeSignal()
		local sent = {}
		local folder = { Name = name, _children = {} }
		folder.FindFirstChild = function(_self, childName)
			return folder._children[childName]
		end
		folder._children.Down = {
			Name = "Down",
			FireClient = function(_self, player, bytes)
				table.insert(sent, { Player = player, Bytes = bytes })
			end,
			FireAllClients = function(_self, bytes)
				table.insert(sent, { Player = nil, Bytes = bytes })
			end,
		}
		folder._children.Up = { Name = "Up", OnServerEvent = up }
		rawget(ReplicatedStorage, "_children")[name] = folder
		return { Up = up, Sent = sent, Name = name }
	end

	local function unwireChannel(wired)
		if remotesAreReal then
			-- Whatever buildDefault created, so the next node starts from nothing.
			local folder = ReplicatedStorage:FindFirstChild(wired.Name)
			if folder then
				folder:Destroy()
			end
			return
		end
		rawget(ReplicatedStorage, "_children")[wired.Name] = nil
	end

	local function build(channel)
		return Server.build({
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Transport = "Default",
			TransportChannel = channel,
			ProfileStore = FakeProfileStore.new(),
			ProfileStoreIndex = "Default",
			ProfileKeyPrefix = "PLAYER_",
			UseMock = true,
			OwnReceipts = false,
			KickOnSessionEnd = false,
			LogLevel = "Fatal",
			Banner = false,
		}, compiled)
	end

	describe("the Default transport channel and Data.Stop", function()
		it("refuses a SECOND live bundle on the same channel", function()
			-- THE CONTROL, and the behaviour that must survive the fix: the claim
			-- exists for a reason, and releasing it on Stop must not turn into never
			-- claiming it. Two LIVE bundles on one channel stay an error.
			local wired = wireChannel("RelA")
			local first = build("RelA")

			local ok, err = pcall(build, "RelA")
			expect(ok).to.equal(false)
			expect(string.find(tostring(err), "transport channel", 1, true) ~= nil).to.equal(true)

			first.Stop()
			unwireChannel(wired)
		end)

		it("lets the channel be rebound after Stop", function()
			-- The defect's first half, and the one that defeats the documented purpose
			-- of Stop: a process that builds bundles can never replace one.
			local wired = wireChannel("RelB")
			local first = build("RelB")
			first.Stop()

			local ok, second = pcall(build, "RelB")
			if not ok then
				error(`rebinding the channel after Stop failed: {tostring(second)}`)
			end
			second.Stop()
			unwireChannel(wired)
		end)

		it("stops listening on the RemoteEvent after Stop", function()
			-- The defect's second half, and the dangerous one: a stopped bundle still
			-- has a live inbound path from clients.
			local wired = wireChannel("RelC")
			local data = build("RelC")
			local live = wired.Up.Count()

			data.Stop()
			local stopped = wired.Up.Count()

			-- Unmeasurable in Studio, where Up is a real RemoteEvent: what stays checked
			-- there is that the real transport builds and stops without throwing, which
			-- is the half the headless runner cannot check at all.
			if live ~= nil then
				expect(`live={live} stopped={stopped}`).to.equal("live=1 stopped=0")
			end

			unwireChannel(wired)
		end)

		it("does not touch a channel it never claimed", function()
			-- The boundary. A bundle running a CUSTOM transport must not release the
			-- Default channel out from under a different bundle that legitimately holds
			-- it -- which is exactly what an unconditional release on Stop would do.
			local wired = wireChannel("RelD")
			local holder = build("RelD")

			local StubTransport = require(Root.Test.Helpers.StubTransport)
			local custom = Server.build({
				Template = { Coins = Scribe.Int(0, { Min = 0 }) },
				Transport = StubTransport.new(),
				TransportChannel = "RelD",
				ProfileStore = FakeProfileStore.new(),
				ProfileStoreIndex = "Default",
				ProfileKeyPrefix = "PLAYER_",
				UseMock = true,
				OwnReceipts = false,
				KickOnSessionEnd = false,
				LogLevel = "Fatal",
				Banner = false,
			}, compiled)
			custom.Stop()

			-- The Default holder still holds it.
			local ok = pcall(build, "RelD")
			expect(ok).to.equal(false)

			holder.Stop()
			unwireChannel(wired)
		end)

		it("releases the channel when the BUILD ITSELF throws, so a corrected retry works", function()
			-- THE FIRST-HOUR CASE. A developer mistypes an option, reads the error, fixes
			-- it, and hits Play again inside the same session. The claim is taken in
			-- Transport.Resolve before the constructor block runs, so a throw from inside
			-- that block leaves it held by a bundle that does not exist, and the corrected
			-- second attempt is refused with a message about a second Scribe instance.
			local wired = wireChannel("RelF")

			local badOk, badErr = pcall(function()
				return Server.build({
					Template = { Coins = Scribe.Int(0, { Min = 0 }) },
					Transport = "Default",
					TransportChannel = "RelF",
					ProfileStore = FakeProfileStore.new(),
					ProfileStoreIndex = "Default",
					ProfileKeyPrefix = "PLAYER_",
					UseMock = true,
					OwnReceipts = false,
					KickOnSessionEnd = false,
					LogLevel = "Fatal",
					Banner = false,
					-- A constructor-time config error, not a compile-time one: it has to
					-- throw from inside the pcall'd block so the unwind is what runs.
					Leaderboards = { TopCoins = { Stat = "Coins", RefreshInterval = -5 } },
				}, compiled)
			end)

			-- The build must fail, and it must fail for the caller's reason.
			expect(badOk).to.equal(false)
			expect(string.find(tostring(badErr), "RefreshInterval", 1, true) ~= nil).to.equal(true)

			-- THE CONSEQUENCE. The corrected retry must succeed, and must not be told
			-- that some other Scribe instance holds the channel.
			local goodOk, good = pcall(build, "RelF")
			expect(
				("retry=%s wrongReason=%s"):format(
					tostring(goodOk),
					tostring(not goodOk and string.find(tostring(good), "already using the", 1, true) ~= nil)
				)
			).to.equal("retry=true wrongReason=false")

			good.Stop()
			unwireChannel(wired)
		end)

		it("leaves no inbound listener behind when the build throws", function()
			-- The claim and the listener are installed by different lines, so releasing
			-- one without the other would still leave client frames reaching a bundle
			-- that was never finished. Counted directly off the RemoteEvent.
			local wired = wireChannel("RelG")
			local before = wired.Up.Count()

			pcall(function()
				return Server.build({
					Template = { Coins = Scribe.Int(0, { Min = 0 }) },
					Transport = "Default",
					TransportChannel = "RelG",
					ProfileStore = FakeProfileStore.new(),
					ProfileStoreIndex = "Default",
					ProfileKeyPrefix = "PLAYER_",
					UseMock = true,
					OwnReceipts = false,
					KickOnSessionEnd = false,
					LogLevel = "Fatal",
					Banner = false,
					Leaderboards = { TopCoins = { Stat = "Coins", RefreshInterval = -5 } },
				}, compiled)
			end)

			local after = wired.Up.Count()
			if before ~= nil and after ~= nil then
				expect(("listeners=%d"):format(after - before)).to.equal("listeners=0")
			end
			unwireChannel(wired)
		end)

		it("releases a channel released directly, and is safe to call twice", function()
			-- ReleaseChannel is what Stop calls; a process tearing bundles down out of
			-- order must not be able to make it throw.
			local wired = wireChannel("RelE")
			local data = build("RelE")
			data.Stop()
			Transport.ReleaseChannel("RelE")
			Transport.ReleaseChannel("RelE")
			Transport.ReleaseChannel("NeverBound")

			local ok, second = pcall(build, "RelE")
			expect(ok).to.equal(true)
			second.Stop()
			unwireChannel(wired)
		end)
	end)
end
