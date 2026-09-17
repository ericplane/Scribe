--!nonstrict
-- Client.Batch: the client's own optimistic writes coalesce into one container fire.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local Client = require(Root.Scribe.Client)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local template = {
		State = { A = Scribe.Int(0), B = Scribe.Int(0), C = Scribe.Int(0) },
	}

	local function makeLoopback()
		local harness = TestCtx.make({ AutoPump = true, Template = template, Options = { Banner = false } })
		local player = harness.Join()
		harness.Transport.LocalPlayer = player
		local client = Client.new(harness.Options, harness.Compiled)
		return harness, client
	end

	--- Writes A, B and C, batched or not, and counts the container's fires.
	local function threeWrites(client, batched: boolean): (number, number, any)
		local fires, leafFires, lastNew = 0, 0, nil
		client.State.Changed(function(new)
			fires += 1
			lastNew = new
		end)
		client.State.A.Changed(function()
			leafFires += 1
		end)
		local function body()
			client.State.A.Set(1)
			client.State.B.Set(2)
			client.State.C.Set(3)
		end
		if batched then
			client.Batch(body)
		else
			body()
		end
		return fires, leafFires, lastNew
	end

	it("collapses three local writes into ONE container fire carrying the end state", function()
		local harness, client = makeLoopback()
		local fires, leafFires, lastNew = threeWrites(client, true)
		client.Stop()
		harness.Cleanup()
		expect(`fires={fires} leaf={leafFires} end={lastNew.A},{lastNew.B},{lastNew.C}`).to.equal(
			"fires=1 leaf=1 end=1,2,3"
		)
	end)

	it("CONTROL: the same writes unbatched fire the container three times", function()
		local harness, client = makeLoopback()
		local fires = threeWrites(client, false)
		client.Stop()
		harness.Cleanup()
		expect(fires).to.equal(3)
	end)

	it("does not leak batch depth when the body throws, so the next write fires normally", function()
		local harness, client = makeLoopback()
		local ok = pcall(client.Batch, function()
			client.State.A.Set(1)
			error("body failed")
		end)
		local fires = 0
		client.State.Changed(function()
			fires += 1
		end)
		client.State.B.Set(2)
		client.Stop()
		harness.Cleanup()
		expect(`ok={ok} firesAfter={fires}`).to.equal("ok=false firesAfter=1")
	end)

	it("nests: an inner batch joins the outer one rather than flushing early", function()
		local harness, client = makeLoopback()
		local fires = 0
		client.State.Changed(function()
			fires += 1
		end)
		client.Batch(function()
			client.State.A.Set(1)
			client.Batch(function()
				client.State.B.Set(2)
			end)
			client.State.C.Set(3)
		end)
		client.Stop()
		harness.Cleanup()
		expect(fires).to.equal(1)
	end)

	it("works in edit mode, where a storybook writes several mocked fields at once", function()
		local harness = TestCtx.make({ Template = template, Options = { Banner = false, IsRunning = false } })
		local client = Client.new(harness.Options, harness.Compiled)
		local fires = 0
		client.State.Changed(function()
			fires += 1
		end)
		client.Batch(function()
			client.State.A.Set(1)
			client.State.B.Set(2)
		end)
		client.Stop()
		harness.Cleanup()
		expect(fires).to.equal(1)
	end)
end
