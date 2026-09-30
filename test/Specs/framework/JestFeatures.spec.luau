--!nonstrict
-- Exercise Jest's production configuration against real arithmetic and signals.
local Root = game:GetService("ReplicatedStorage").ScribeDev
local JestGlobals = require(Root.DevPackages.JestGlobals)
local describe, it, expect = JestGlobals.describe, JestGlobals.it, JestGlobals.expect
local beforeEach, afterEach, jest = JestGlobals.beforeEach, JestGlobals.afterEach, JestGlobals.jest
local Promise = require(Root.DevPackages.Promise)
local Big = require(Root.Scribe.Internal.Big)
local Signal = require(Root.Scribe.Internal.Signal)

describe("Jest production integration", function()
	it.each({
		{ -2, 3, { -8, 0 } },
		{ -2, 2, { 4, 0 } },
		{ 250, 0, { 1, 0 } },
	})("represents %s raised to %s exactly", function(base, power, stored)
		expect(Big.toStored(Big.pow(Big.from(base), power))).toEqual(stored)
	end)

	it("preserves the absolute tolerance used by numerical specifications", function()
		local result = Big.toNumber(Big.div(Big.from(1), Big.from(3)))
		expect(result).toBeWithin(1 / 3)
		expect(result).never.toBeWithin(0.33, 0.001)
	end)

	describe("signal observers", function()
		local signal
		local received
		local function receive(value)
			table.insert(received, value)
		end
		local observer = { receive = receive }

		beforeEach(function()
			signal = Signal.new()
			received = {}
			task.wait()
		end)

		afterEach(function()
			signal:Destroy()
			task.wait()
		end)

		it("observes a once listener's arguments without replacing its behaviour", function()
			local spy = jest.spyOn(observer, "receive")
			signal:Once(function(value)
				observer.receive(value)
			end)
			signal:Fire(250)
			signal:Fire(275)
			task.wait()
			expect(spy).toHaveBeenCalledTimes(1)
			expect(spy).toHaveBeenCalledWith(250)
			expect(received).toEqual({ 250 })
		end)

		it("restores observers automatically before the following test", function()
			expect(observer.receive).toBe(receive)
			expect(jest.isMockFunction(observer.receive)).toBe(false)
			signal:Connect(observer.receive)
			signal:Fire(275)
			task.wait()
			expect(received).toEqual({ 275 })
		end)

		it("awaits a returned Promise and counts assertions after signal delivery", function()
			expect.assertions(2)
			local delivery = Promise.new(function(resolve)
				signal:Once(function(value)
					receive(value)
					resolve({ Wallet = { Coins = value }, Delivery = "signal" })
				end)
				task.defer(function()
					signal:Fire(250)
				end)
			end)
			return expect(delivery).resolves
				.toEqual(expect.objectContaining({ Wallet = { Coins = 250 } }))
				:andThen(function()
					expect(received).toEqual(expect.arrayContaining({ 250 }))
				end)
		end)

		it("awaits callback completion after a yielding signal listener", function(_context, done)
			expect.assertions(1)
			signal:Once(function(value)
				task.wait()
				local ok, err = pcall(function()
					expect(value).toBe(275)
				end)
				done(if ok then nil else err)
			end)
			signal:Fire(275)
		end)
	end)
end)
