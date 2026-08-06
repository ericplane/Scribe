--!nonstrict
-- A leaderboard Stat must resolve to something a board can actually rank.
--
-- Two configs used to pass every startup check and then rank nothing, forever,
-- with no error on any realm:
--
--   * a Scribe.Session stat, because the refresh cycle reads scores out of
--     entry.LiveData and a Session field lives in entry.SessionStore. The board
--     stayed empty and the value reset every session anyway, while the
--     OrderedDataStore entries outlive the session.
--   * a non-numeric stat, because the score becomes the OrderedDataStore key and
--     the refresh cycle silently drops anything that is not a number.
--
-- Both now fail at boot. An empty board with no error is the worst outcome: it
-- looks like nobody has scored yet.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local function build(template, boards)
		return function()
			TestCtx.make({ Template = template, Options = { Leaderboards = boards } }).Cleanup()
		end
	end

	it("refuses a Stat pointing at a Scribe.Session field", function()
		expect(build({
			Runtime = Scribe.Session({ Kills = 0 }),
		}, { Top = { Stat = "Runtime.Kills" } })).to.throw()
	end)

	it("refuses a Session stat however it is combined", function()
		expect(build({
			Runtime = Scribe.Shared(Scribe.Session({ Kills = 0 })),
		}, { Top = { Stat = "Runtime.Kills" } })).to.throw()
		expect(build({
			Runtime = Scribe.ServerOnly(Scribe.Session({ Kills = 0 })),
		}, { Top = { Stat = "Runtime.Kills" } })).to.throw()
	end)

	it("says Session in the error, not something generic", function()
		local ok, err = pcall(build({
			Runtime = Scribe.Session({ Kills = 0 }),
		}, { Top = { Stat = "Runtime.Kills" } }))
		expect(ok).to.equal(false)
		expect(string.find(tostring(err), "Session", 1, true) ~= nil).to.equal(true)
	end)

	it("refuses a non-numeric leaf Stat", function()
		expect(build({ Name = Scribe.String("") }, { Top = { Stat = "Name" } })).to.throw()
		expect(build({ Flag = false }, { Top = { Stat = "Flag" } })).to.throw()
		expect(build({ Team = Scribe.Enum("A", { "A", "B" }) }, { Top = { Stat = "Team" } })).to.throw()
		expect(build({ Done = Scribe.Flags({ "A", "B" }) }, { Top = { Stat = "Done" } })).to.throw()
		expect(build({ P = Scribe.Vector3(Vector3.zero) }, { Top = { Stat = "P" } })).to.throw()
	end)

	it("refuses a Stat naming a whole container rather than a leaf", function()
		expect(build({ Stats = { Wins = 0 } }, { Top = { Stat = "Stats" } })).to.throw()
		expect(build({ Bag = Scribe.DictOf(Scribe.Int(0)) }, { Top = { Stat = "Bag" } })).to.throw()
		expect(build({ L = Scribe.ArrayOf(Scribe.Int(0)) }, { Top = { Stat = "L" } })).to.throw()
		expect(build({ Bag = {} :: { [string]: number } }, { Top = { Stat = "Bag" } })).to.throw()
	end)

	it("still accepts every stat type a board can rank", function()
		expect(build({ Coins = 0 }, { Top = { Stat = "Coins" } })).never.to.throw()
		expect(build({ Coins = Scribe.Int(0) }, { Top = { Stat = "Coins" } })).never.to.throw()
		expect(build({ Coins = Scribe.Number(0) }, { Top = { Stat = "Coins" } })).never.to.throw()
		expect(build({ Coins = Scribe.Big(0) }, { Top = { Stat = "Coins" } })).never.to.throw()
		-- A persisted nested field is fine; only the Session axis is refused.
		expect(build({ Stats = { Wins = 0 } }, { Top = { Stat = "Stats.Wins" } })).never.to.throw()
	end)

	it("still accepts a dynamic subtree, whose type is unknowable at boot", function()
		expect(build({ Bag = {} :: { [string]: number } }, { Top = { Stat = "Bag.Gold" } })).never.to.throw()
	end)
end
