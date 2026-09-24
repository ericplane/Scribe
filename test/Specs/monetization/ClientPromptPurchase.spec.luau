--!nonstrict
-- Purchase requests cross the real command transport. Only the server's engine
-- prompt is faked: player identity, eligibility and duplicate protection are real.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local Client = require(Root.Scribe.Client)
	local Wire = require(Root.Scribe.Internal.Wire)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	local function countedSignal()
		local listeners = {}
		local signal = {}
		function signal:Connect(fn)
			local connection = { Connected = true }
			function connection.Disconnect(disconnecting)
				disconnecting.Connected = false
				listeners[disconnecting] = nil
			end
			listeners[connection] = fn
			return connection
		end
		function signal:Fire(...)
			for connection, fn in table.clone(listeners) do
				if connection.Connected then
					fn(...)
				end
			end
		end
		function signal.Count()
			local count = 0
			for _ in listeners do
				count += 1
			end
			return count
		end
		return signal
	end

	local function withClient(config, fn)
		config = config or {}
		local prompts = {}
		local productFinished, passFinished = countedSignal(), countedSignal()
		local options = {
			Products = {
				CoinBag = { Id = 4242 },
				VIPGift = { Id = 4243, Grants = "VIP" },
				LootBox = { Id = 4244, PaidRandom = true },
			},
			Passes = { VIPPass = { Id = 777 } },
			RequestTimeout = 0.1,
			CommandRateLimit = 1000,
			IsRunning = true,
			PromptProductPurchase = function(target, id)
				table.insert(prompts, { Kind = "Product", Player = target, Id = id })
			end,
			PromptGamePassPurchase = function(target, id)
				table.insert(prompts, { Kind = "Pass", Player = target, Id = id })
			end,
			PromptProductPurchaseFinished = productFinished,
			PromptGamePassPurchaseFinished = passFinished,
			UserOwnsGamePassAsync = function()
				return false
			end,
			GetPolicyInfoAsync = function()
				return { ArePaidRandomItemsRestricted = false }
			end,
		}
		for key, value in config.Server or {} do
			options[key] = value
		end
		local harness = TestCtx.make({
			Template = { Coins = 0 },
			AutoPump = config.AutoPump ~= false,
			Options = options,
		})
		local player, entry = harness.Join(9001)
		harness.Transport.LocalPlayer = player
		local clientOptions = table.clone(harness.Options)
		clientOptions.PromptProductPurchase = function()
			error("client must not open a product prompt", 0)
		end
		clientOptions.PromptGamePassPurchase = function()
			error("client must not open a pass prompt", 0)
		end
		local clientProductFinished, clientPassFinished = countedSignal(), countedSignal()
		clientOptions.PromptProductPurchaseFinished = clientProductFinished
		clientOptions.PromptGamePassPurchaseFinished = clientPassFinished
		for key, value in config.Client or {} do
			clientOptions[key] = value
		end
		local client
		local ok, err = pcall(function()
			client = Client.new(clientOptions, harness.Compiled)
			fn(harness, player, entry, client, prompts, productFinished, passFinished)
			expect(clientProductFinished.Count() + clientPassFinished.Count()).to.equal(0)
		end)
		if client then
			client.Stop()
		end
		harness.Cleanup()
		Client.SetLocalPlayerProbe(nil)
		if not ok then
			error(err, 0)
		end
	end

	local function attempt(client, name)
		local ok, why, marker = client.PromptPurchase(name)
		return `{ok} why={tostring(why)} marked={marker == Scribe.RequestFailed}`
	end

	local function commandCount(harness)
		local count = 0
		for _, frame in harness.Transport.SentToServerLog do
			if buffer.readu8(frame.Bytes, 0) == Wire.Frames.Command then
				count += 1
			end
		end
		return count
	end

	it("uses the server's product ID and transport sender even without a client LocalPlayer", function()
		withClient({ Client = { Products = { CoinBag = { Id = 99999 } } } }, function(_, player, _, client, prompts)
			expect(attempt(client, "CoinBag")).to.equal("true why=nil marked=false")
			expect(#prompts).to.equal(1)
			expect(prompts[1].Kind).to.equal("Product")
			expect(prompts[1].Id).to.equal(4242)
			expect(prompts[1].Player).to.equal(player)
		end)
	end)

	it("opens a pass through the pass prompt and never grants ownership from the finished signal", function()
		withClient(nil, function(harness, player, _, client, prompts, _, passFinished)
			expect(attempt(client, "VIPPass")).to.equal("true why=nil marked=false")
			expect(#prompts).to.equal(1)
			expect(prompts[1].Kind).to.equal("Pass")
			expect(prompts[1].Id).to.equal(777)
			expect(prompts[1].Player).to.equal(player)
			passFinished:Fire(player, 777, true)
			expect(harness.Data.Owns(player, "VIPPass")).to.equal(false)
		end)
	end)

	it("refuses server-owned perks even while the client mirror still says purchasable", function()
		withClient(nil, function(harness, player, _, client, prompts)
			harness.Data.GrantPerk(player, "VIP")
			expect(client.GetProductState("VIPGift")).to.equal("purchasable")
			expect(attempt(client, "VIPGift")).to.equal("false why=owned marked=false")
			expect(#prompts).to.equal(0)
			-- A refusal also releases the in-flight guard.
			expect(attempt(client, "CoinBag")).to.equal("true why=nil marked=false")
		end)
	end)

	it("uses the server's paid-random policy despite a permissive client policy", function()
		withClient({
			Server = {
				GetPolicyInfoAsync = function()
					return { ArePaidRandomItemsRestricted = true }
				end,
			},
			Client = {
				GetPolicyInfoAsync = function()
					return { ArePaidRandomItemsRestricted = false }
				end,
			},
		}, function(_, _, _, client, prompts)
			client.GetProductState("LootBox")
			task.wait()
			expect(client.GetProductState("LootBox")).to.equal("purchasable")
			expect(attempt(client, "LootBox")).to.equal("false why=paid-random-restricted marked=false")
			expect(#prompts).to.equal(0)
		end)
	end)

	it("refuses an unresolved server policy without blocking an ordinary product", function()
		withClient(nil, function(_, _, entry, client, prompts)
			entry.Policy = { Phase = "pending", Restricted = false, LastAttempt = 0, Logged = false }
			expect(attempt(client, "LootBox")).to.equal("false why=policy-pending marked=false")
			expect(#prompts).to.equal(0)
			expect(attempt(client, "CoinBag")).to.equal("true why=nil marked=false")
		end)
	end)

	it("returns the existing unknown-name refusal instead of raising", function()
		withClient(nil, function(_, _, _, client, prompts)
			expect(attempt(client, "Missing")).to.equal('false why=unknown product or pass "Missing" marked=false')
			expect(#prompts).to.equal(0)
			expect(attempt(client, "CoinBag")).to.equal("true why=nil marked=false")
		end)
	end)

	it("cannot prompt before Init or after Stop", function()
		withClient({ AutoPump = false }, function(_, _, _, client, prompts)
			expect(attempt(client, "CoinBag")).to.equal("false why=not-loaded marked=false")
			client.Stop()
			expect(attempt(client, "CoinBag")).to.equal("false why=not-loaded marked=false")
			expect(#prompts).to.equal(0)
		end)
	end)

	it("rejects a non-string name before sending a command", function()
		withClient(nil, function(harness, _, _, client, prompts)
			local before = commandCount(harness)
			expect(pcall(client.PromptPurchase, 4242)).to.equal(false)
			expect(commandCount(harness)).to.equal(before)
			expect(#prompts).to.equal(0)
		end)
	end)

	it("reports an edit-mode request failure without opening Roblox's prompt", function()
		withClient({ Client = { IsRunning = false } }, function(_, _, _, client, prompts)
			expect(attempt(client, "CoinBag")).to.equal("false why=edit-mode marked=true")
			expect(#prompts).to.equal(0)
		end)
	end)

	it("keeps a product prompt busy on the server until its matching completion, including cancellation", function()
		withClient(nil, function(harness, player, _, client, prompts, productFinished, passFinished)
			expect(attempt(client, "CoinBag")).to.equal("true why=nil marked=false")
			local before = commandCount(harness)
			productFinished:Fire(player.UserId + 1, 4242, false)
			productFinished:Fire(player.UserId, 4243, false)
			passFinished:Fire(player, 4242, false)
			expect(attempt(client, "VIPPass")).to.equal("false why=purchase prompt already open marked=false")
			expect(commandCount(harness)).to.equal(before + 1)
			expect(#prompts).to.equal(1)
			productFinished:Fire(player.UserId, 4242, false)
			expect(attempt(client, "VIPPass")).to.equal("true why=nil marked=false")
			expect(#prompts).to.equal(2)
		end)
	end)

	it("matches pass completion by player and pass ID, ignoring product completion", function()
		withClient(nil, function(_, player, _, client, prompts, productFinished, passFinished)
			expect(attempt(client, "VIPPass")).to.equal("true why=nil marked=false")
			passFinished:Fire(FakePlayer.new(9002), 777, false)
			passFinished:Fire(player, 778, false)
			productFinished:Fire(player.UserId, 777, false)
			expect(attempt(client, "CoinBag")).to.equal("false why=purchase prompt already open marked=false")
			passFinished:Fire(player, 777, false)
			expect(attempt(client, "CoinBag")).to.equal("true why=nil marked=false")
			expect(#prompts).to.equal(2)
		end)
	end)

	it("shares the server prompt guard with direct calls without blocking other players", function()
		withClient(nil, function(harness, player, _, client, prompts, productFinished)
			expect(harness.Data.PromptPurchase(player, "CoinBag")).to.equal(true)
			expect(attempt(client, "VIPPass")).to.equal("false why=purchase prompt already open marked=false")
			local other = harness.Join(9002)
			expect(harness.Data.PromptPurchase(other, "VIPPass")).to.equal(true)
			expect(#prompts).to.equal(2)
			expect(prompts[2].Player).to.equal(other)
			productFinished:Fire(player.UserId, 4242, false)
			expect(attempt(client, "CoinBag")).to.equal("true why=nil marked=false")
			local ok, reason = harness.Data.PromptPurchase(player, "VIPPass")
			expect(ok).to.equal(false)
			expect(reason).to.equal("purchase prompt already open")
			expect(#prompts).to.equal(3)
		end)
	end)

	it("counts accepted client requests as server purchase prompts without granting data", function()
		withClient(nil, function(harness, player, _, client, prompts, productFinished)
			local before = Scribe.GetMetrics().PurchasePrompts or 0
			expect(attempt(client, "VIPGift")).to.equal("true why=nil marked=false")
			expect(harness.Data.Owns(player, "VIP")).to.equal(false)
			productFinished:Fire(player.UserId, 4243, true)
			expect(harness.Data.Owns(player, "VIP")).to.equal(false)
			expect((Scribe.GetMetrics().PurchasePrompts or 0) - before).to.equal(1)
			expect(attempt(client, "Missing")).to.equal('false why=unknown product or pass "Missing" marked=false')
			expect((Scribe.GetMetrics().PurchasePrompts or 0) - before).to.equal(1)
			expect(#prompts).to.equal(1)
		end)
	end)

	it("rejects a second click while the server request is pending", function()
		withClient({ Server = { RequestTimeout = 5 } }, function(harness, _, _, client, prompts)
			harness.Transport.AutoPump = false
			local first
			local requester = coroutine.create(function()
				first = attempt(client, "CoinBag")
			end)
			coroutine.resume(requester)
			task.wait()
			local before = commandCount(harness)
			expect(attempt(client, "VIPPass")).to.equal("false why=purchase prompt already open marked=false")
			expect(commandCount(harness)).to.equal(before)
			expect(#prompts).to.equal(0)
			harness.Transport:PumpToServer()
			harness.Transport:PumpToClient()
			expect(first).to.equal("true why=nil marked=false")
			expect(coroutine.status(requester)).to.equal("dead")
			expect(#prompts).to.equal(1)
		end)
	end)

	it("releases the prompt guard after the engine throws", function()
		local calls = 0
		withClient({
			Server = {
				PromptProductPurchase = function()
					calls += 1
					if calls == 1 then
						error("product is unpublished", 0)
					end
				end,
			},
		}, function(_, _, _, client)
			expect(attempt(client, "CoinBag")).to.equal(
				"false why=purchase prompt failed: product is unpublished marked=false"
			)
			expect(attempt(client, "CoinBag")).to.equal("true why=nil marked=false")
			expect(calls).to.equal(2)
		end)
	end)

	it("handles a completion raised synchronously while opening the prompt", function()
		local finished
		local calls = 0
		withClient({
			Server = {
				PromptProductPurchase = function(player, id)
					calls += 1
					finished:Fire(player.UserId, id, false)
				end,
			},
		}, function(_, _, _, client, _, productFinished)
			finished = productFinished
			expect(attempt(client, "CoinBag")).to.equal("true why=nil marked=false")
			expect(attempt(client, "CoinBag")).to.equal("true why=nil marked=false")
			expect(calls).to.equal(2)
		end)
	end)

	it("keeps framework rejection distinguishable when the server session is no longer ready", function()
		withClient(nil, function(_, _, entry, client, prompts)
			entry.State = "Loading"
			local result = attempt(client, "CoinBag")
			entry.State = "Ready"
			expect(result).to.equal("false why=not-ready marked=true")
			expect(#prompts).to.equal(0)
			expect(attempt(client, "CoinBag")).to.equal("true why=nil marked=false")
		end)
	end)

	it("uses the command rate limit for client purchase requests", function()
		withClient(nil, function(_, _, entry, client, prompts)
			entry.RateTokens = -math.huge
			expect(attempt(client, "CoinBag")).to.equal("false why=rate-limited marked=true")
			expect(#prompts).to.equal(0)
			entry.RateTokens = 1000
			expect(attempt(client, "CoinBag")).to.equal("true why=nil marked=false")
			expect(#prompts).to.equal(1)
		end)
	end)

	it("forwards send failure with RequestFailed and allows a new attempt", function()
		withClient(nil, function(harness, _, _, client, prompts)
			local send = harness.Transport.SendToServer
			harness.Transport.SendToServer = function()
				error("offline", 0)
			end
			expect(attempt(client, "CoinBag")).to.equal("false why=send-failed marked=true")
			expect(#prompts).to.equal(0)
			harness.Transport.SendToServer = send
			expect(attempt(client, "CoinBag")).to.equal("true why=nil marked=false")
		end)
	end)

	it("does not retry a timed-out request, which may still open the server prompt", function()
		withClient(nil, function(harness, player, _, client, prompts, productFinished)
			harness.Transport.AutoPump = false
			local before = commandCount(harness)
			expect(attempt(client, "CoinBag")).to.equal("false why=timeout marked=true")
			expect(commandCount(harness)).to.equal(before + 1)
			expect(#prompts).to.equal(0)
			harness.Transport:PumpToServer()
			harness.Transport:PumpToClient()
			expect(#prompts).to.equal(1)
			harness.Transport.AutoPump = true
			expect(attempt(client, "CoinBag")).to.equal("false why=purchase prompt already open marked=false")
			expect(#prompts).to.equal(1)
			productFinished:Fire(player.UserId, 4242, false)
			expect(attempt(client, "CoinBag")).to.equal("true why=nil marked=false")
			expect(#prompts).to.equal(2)
		end)
	end)

	it("reports a timeout for a lost reply even though the prompt is already open", function()
		withClient(nil, function(harness, _, _, client, prompts)
			harness.Transport.AutoPump = false
			local answer
			local requester = coroutine.create(function()
				answer = attempt(client, "CoinBag")
			end)
			coroutine.resume(requester)
			task.wait()
			harness.Transport:PumpToServer()
			expect(#prompts).to.equal(1)
			harness.Transport:DropToClient()
			for _ = 1, 40 do
				if coroutine.status(requester) == "dead" then
					break
				end
				task.wait(0.01)
			end
			expect(answer).to.equal("false why=timeout marked=true")
			harness.Transport.AutoPump = true
			expect(attempt(client, "VIPPass")).to.equal("false why=purchase prompt already open marked=false")
			expect(#prompts).to.equal(1)
		end)
	end)

	it("does not cancel an already-sent server request when the client stops", function()
		withClient(nil, function(harness, _, _, client, prompts)
			harness.Transport.AutoPump = false
			local answer
			local requester = coroutine.create(function()
				answer = attempt(client, "CoinBag")
			end)
			coroutine.resume(requester)
			task.wait()
			client.Stop()
			expect(#prompts).to.equal(0)
			harness.Transport:PumpToServer()
			harness.Transport:PumpToClient()
			for _ = 1, 20 do
				if coroutine.status(requester) == "dead" then
					break
				end
				task.wait(0.01)
			end
			expect(coroutine.status(requester)).to.equal("dead")
			expect(answer).to.equal("true why=nil marked=false")
			expect(#prompts).to.equal(1)
		end)
	end)

	it("keeps an open server prompt guarded after the client stops", function()
		withClient(nil, function(harness, player, _, client, prompts, productFinished)
			expect(attempt(client, "CoinBag")).to.equal("true why=nil marked=false")
			client.Stop()
			local ok, reason = harness.Data.PromptPurchase(player, "VIPPass")
			expect(ok).to.equal(false)
			expect(reason).to.equal("purchase prompt already open")
			productFinished:Fire(player.UserId, 4242, false)
			expect(attempt(client, "CoinBag")).to.equal("false why=not-loaded marked=false")
			expect(#prompts).to.equal(1)
			expect(harness.Data.PromptPurchase(player, "VIPPass")).to.equal(true)
			expect(#prompts).to.equal(2)
		end)
	end)

	it("preserves a completed success if Stop happens before the request send returns", function()
		withClient(nil, function(harness, _, _, client, prompts)
			local send = harness.Transport.SendToServer
			harness.Transport.SendToServer = function(transport, bytes)
				send(transport, bytes)
				client.Stop()
			end
			expect(attempt(client, "CoinBag")).to.equal("true why=nil marked=false")
			expect(#prompts).to.equal(1)
			expect(attempt(client, "CoinBag")).to.equal("false why=not-loaded marked=false")
		end)
	end)

	it("does not let a game replace the internal purchase prompt handler", function()
		withClient(nil, function(harness, _, _, client, prompts)
			local registered = pcall(harness.Data.Command, Wire.PURCHASE_PROMPT_COMMAND, function()
				return true, nil, "Product", 99999
			end)
			expect(registered).to.equal(false)
			expect(attempt(client, "CoinBag")).to.equal("true why=nil marked=false")
			expect(prompts[1].Id).to.equal(4242)
		end)
	end)

	it("rejects malformed internal command arguments before resolving an asset", function()
		withClient(nil, function(_, _, _, client, prompts)
			for _, args in { { n = 0 }, table.pack(4242), table.pack("CoinBag", 99999) } do
				local ok, why, marker = client.Request(Wire.PURCHASE_PROMPT_COMMAND, table.unpack(args, 1, args.n))
				expect(ok).to.equal(false)
				expect(why).to.equal("bad-args")
				expect(marker).to.equal(Scribe.RequestFailed)
			end
			expect(#prompts).to.equal(0)
		end)
	end)
end
