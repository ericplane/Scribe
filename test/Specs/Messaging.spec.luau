--!nonstrict
-- Cross-server messaging: Data.SendMessage delivers to Data.OnMessage, and
-- gift or foreign messages on the same channel never surface as user messages.

return function()
	local Root = script.Parent.Parent.Parent
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	it("delivers SendMessage to OnMessage for an active recipient", function()
		local harness = TestCtx.make()
		local player = harness.Join(42)

		local received: any = nil
		harness.Data.OnMessage:Connect(function(p, msg)
			received = { Player = p, Message = msg }
		end)

		local ok = harness.Data.SendMessage(42, { Kind = "Hello", N = 7 })
		expect(ok).to.equal(true)
		task.wait() -- OnMessage fires via task.spawn; let it run

		expect(received).to.be.ok()
		expect(received.Player).to.equal(player)
		expect(received.Message.Kind).to.equal("Hello")
		expect(received.Message.N).to.equal(7)
	end)

	it("does not surface a foreign message as a user message", function()
		local harness = TestCtx.make()
		harness.Join(7)

		local fired = false
		harness.Data.OnMessage:Connect(function()
			fired = true
		end)

		-- An untagged message (not ScribeMessage) must not fire OnMessage.
		harness.Ctx.Persistence.Store:MessageAsync(harness.Ctx.Persistence.KeyFor(7), { Something = "else" })
		task.wait()
		expect(fired).to.equal(false)
	end)
end
