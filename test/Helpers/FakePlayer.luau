--!strict
-- Fake Player objects for driving the persistence lifecycle. Tests cannot
-- create real Player instances; Scribe's runtime only reads UserId/Name/
-- Parent/MembershipType and calls Kick, so a table suffices (the `Data[player]`
-- sugar has a typeof guard — tests use Data.Get(player)/ctx internals instead).

local Players = game:GetService("Players")

local FakePlayer = {}

local nextId = 100000

function FakePlayer.new(userId: number?, name: string?)
	nextId += 1
	local id = userId or nextId
	local player = {
		ClassName = "Player",
		UserId = id,
		Name = name or `TestPlayer{id}`,
		DisplayName = name or `TestPlayer{id}`,
		-- Referencing the real Players service makes `player.Parent == Players`
		-- checks in Persistence behave exactly as they do for real players.
		Parent = Players :: any,
		MembershipType = Enum.MembershipType.None,
		Kicked = nil :: string?,
		Kick = function(self: any, message: string?)
			self.Kicked = message or ""
			self.Parent = nil
		end,
		IsA = function(_self: any, className: string): boolean
			return className == "Player" or className == "Instance"
		end,
	}
	return player
end

--- Simulates the player leaving (PlayerRemoving semantics: unparent first).
function FakePlayer.leave(player: any)
	player.Parent = nil
end

return FakePlayer
