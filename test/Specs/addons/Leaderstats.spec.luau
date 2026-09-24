--!nonstrict
-- Real Scribe accessors/lifecycle, with a small instance tree for the headless runner.
return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Leaderstats = require(Root.Addons.Leaderstats.ScribeLeaderstats)
	local Scribe = require(Root.Scribe) :: any
	local Signal = require(Root.Scribe.Internal.Signal)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local function newInstance(className)
		local properties = { Name = className, ClassName = className, Children = {}, Destroyed = false, Writes = 0 }
		local instance
		local methods = {}
		function methods:IsA(name)
			return name == className or name == "Instance"
		end
		function methods:FindFirstChild(name)
			for _, child in properties.Children do
				if child.Name == name then
					return child
				end
			end
			return nil
		end
		function methods:GetChildren()
			return table.clone(properties.Children)
		end
		function methods:Destroy()
			for _, child in self:GetChildren() do
				child:Destroy()
			end
			self.Parent = nil
			properties.Destroyed = true
		end
		instance = setmetatable({}, {
			__index = function(_, key)
				return methods[key] or properties[key]
			end,
			__newindex = function(_, key, value)
				if key == "Parent" then
					local previous = properties.Parent
					if previous then
						table.remove(previous.Children, table.find(previous.Children, instance))
					end
					if value then
						table.insert(value.Children, instance)
					end
				elseif key == "Value" then
					assert(not properties.Destroyed, "writing a destroyed value")
					properties.Writes += 1
				end
				properties[key] = value
			end,
		})
		return instance
	end

	local function attachChildren(player)
		player.Children = {}
		function player:FindFirstChild(name)
			for _, child in self.Children do
				if child.Name == name then
					return child
				end
			end
			return nil
		end
		return player
	end

	local function harness()
		local h = TestCtx.make({
			Template = {
				Coins = Scribe.Number(1.25),
				Title = "Novice",
				Winner = false,
				Progress = { Level = 1, Get = 4 },
				Bag = {},
			},
		})
		local player, entry, data = h.Join()
		attachChildren(player)
		local present = { player }
		local players = {
			PlayerAdded = Signal.new(),
			PlayerRemoving = Signal.new(),
			GetPlayers = function()
				return table.clone(present)
			end,
		}
		local warnings = {}
		local deps = {
			Players = players,
			NewInstance = newInstance,
			IsServer = function()
				return true
			end,
			Warn = function(message)
				table.insert(warnings, message)
			end,
		}
		return h, player, data, deps, warnings, present, entry
	end

	local function withHarness(callback)
		local h, player, data, deps, warnings, present, entry = harness()
		local handles = {}
		local function start(stats, api)
			local handle = Leaderstats.Start(api or h.Data, stats, deps)
			table.insert(handles, handle)
			return handle
		end
		local ok, err = pcall(callback, h, player, data, deps, warnings, present, entry, start)
		for _, handle in handles do
			handle:Stop()
		end
		h.Cleanup()
		if not ok then
			error(err, 0)
		end
	end

	it("creates typed values after load and mirrors real accessor changes without truncating numbers", function()
		withHarness(function(_, player, data, _, warnings, _, _, start)
			start({
				Coins = "Coins",
				Title = "Title",
				Winner = "Winner",
				Level = "Progress.Level",
				Collision = "Progress.Get",
			})
			task.wait()
			local folder = player:FindFirstChild("leaderstats")
			expect(folder:IsA("Folder")).to.equal(true)
			expect(folder:FindFirstChild("Coins").ClassName).to.equal("NumberValue")
			expect(folder:FindFirstChild("Coins").Value).to.equal(1.25)
			expect(folder:FindFirstChild("Title").ClassName).to.equal("StringValue")
			expect(folder:FindFirstChild("Winner").ClassName).to.equal("BoolValue")
			expect(folder:FindFirstChild("Collision").Value).to.equal(4)
			data.Coins.Set(4.75)
			data.Title.Set("Winner")
			data.Winner.Set(true)
			data.Progress.Set({ Level = 9, Get = 4 })
			task.wait()
			expect(folder:FindFirstChild("Coins").Value).to.equal(4.75)
			expect(folder:FindFirstChild("Title").Value).to.equal("Winner")
			expect(folder:FindFirstChild("Winner").Value).to.equal(true)
			expect(folder:FindFirstChild("Level").Value).to.equal(9)
			expect(#warnings).to.equal(0)
		end)
	end)

	it("never writes leaderstat edits back into Scribe", function()
		withHarness(function(_, player, data, _, _, _, _, start)
			start({ Coins = "Coins" })
			task.wait()
			player:FindFirstChild("leaderstats"):FindFirstChild("Coins").Value = 999
			expect(data.Coins.Get()).to.equal(1.25)
		end)
	end)

	it("attaches players who join after Start and ignores duplicate join notifications", function()
		withHarness(function(h, _, _, deps, _, _, _, start)
			start({ Coins = "Coins" })
			local nextPlayer, _, nextData = h.Join()
			attachChildren(nextPlayer)
			deps.Players.PlayerAdded:Fire(nextPlayer)
			deps.Players.PlayerAdded:Fire(nextPlayer)
			task.wait()
			expect(#nextPlayer.Children).to.equal(1)
			local stat = nextPlayer:FindFirstChild("leaderstats"):FindFirstChild("Coins")
			nextData.Coins.Set(8)
			task.wait()
			expect(stat.Value).to.equal(8)
		end)
	end)

	it("disconnects and destroys its instances on leave and session loss", function()
		for _, ending in { "leave", "session" } do
			withHarness(function(h, player, data, deps, _, _, _, start)
				start({ Coins = "Coins" })
				task.wait()
				local stat = player:FindFirstChild("leaderstats"):FindFirstChild("Coins")
				if ending == "leave" then
					deps.Players.PlayerRemoving:Fire(player)
				else
					h.Data.SessionEnded:Fire(player, "session-ended")
				end
				task.wait()
				expect(stat.Destroyed).to.equal(true)
				expect(player:FindFirstChild("leaderstats")).to.equal(nil)
				local writes = stat.Writes
				data.Coins.Set(8)
				task.wait()
				expect(stat.Writes).to.equal(writes)
			end)
		end
	end)

	it("supports idempotent Stop and a later fresh Start", function()
		withHarness(function(h, player, _, deps, _, _, _, start)
			local handle = start({ Coins = "Coins" })
			expect(function()
				Leaderstats.Start(h.Data, { Coins = "Coins" }, deps)
			end).to.throw("already started")
			handle:Stop()
			handle:Stop()
			start({ Coins = "Coins" })
			task.wait()
			expect(#player.Children).to.equal(1)
		end)
	end)

	it("returns observer and player-listener counts to baseline across repeated starts", function()
		withHarness(function(_, _, _, deps, _, _, entry, start)
			local function observerCount()
				local count = 0
				for _, events in entry.Tree._listeners do
					for _, listeners in events do
						for _ in listeners do
							count += 1
						end
					end
				end
				return count
			end
			local baseline = observerCount()
			for _ = 1, 3 do
				local handle = start({ Coins = "Coins", Title = "Title" })
				task.wait()
				expect(observerCount()).to.equal(baseline + 2)
				handle:Stop()
				expect(observerCount()).to.equal(baseline)
				expect(deps.Players.PlayerAdded._head).to.equal(false)
				expect(deps.Players.PlayerRemoving._head).to.equal(false)
			end
		end)
	end)

	it("cleans up through the real Scribe session-release path", function()
		withHarness(function(h, player, _, _, warnings, _, entry, start)
			start({ Coins = "Coins" })
			task.wait()
			local stat = player:FindFirstChild("leaderstats"):FindFirstChild("Coins")
			entry.Profile:_steal()
			task.wait()
			expect(h.Data.GetState(player)).to.equal("SessionEnded")
			expect(stat.Destroyed).to.equal(true)
			expect(player:FindFirstChild("leaderstats")).to.equal(nil)
			expect(#warnings).to.equal(0)
		end)
	end)

	it("rolls back subscriptions and instances if attaching a later observer fails", function()
		withHarness(function(h, player, data, _, warnings, _, _, start)
			local disconnected = false
			local coins = {
				Get = data.Coins.Get,
				Observe = function(callback)
					local stop = data.Coins.Observe(callback)
					return function()
						disconnected = true
						stop()
					end
				end,
			}
			local title = {
				Get = data.Title.Get,
				Observe = function()
					error("subscription failure")
				end,
			}
			local api = {
				SessionEnded = h.Data.SessionEnded,
				WaitForData = function()
					return {
						Child = function(name)
							return if name == "Coins" then coins else title
						end,
					}
				end,
			}
			start({ Coins = "Coins", Title = "Title" }, api)
			task.wait()
			expect(disconnected).to.equal(true)
			expect(player:FindFirstChild("leaderstats")).to.equal(nil)
			expect(#warnings).to.equal(1)
		end)
	end)

	it("preserves an existing folder and unrelated stats when stopped", function()
		withHarness(function(_, player, _, _, _, _, _, start)
			local folder = newInstance("Folder")
			folder.Name, folder.Parent = "leaderstats", player
			local other = newInstance("IntValue")
			other.Name, other.Parent, other.Value = "Other", folder, 7
			local handle = start({ Coins = "Coins" })
			task.wait()
			handle:Stop()
			expect(player:FindFirstChild("leaderstats")).to.equal(folder)
			expect(#folder:GetChildren()).to.equal(1)
			expect(other.Destroyed).to.equal(false)
		end)
	end)

	it("does not delete other scripts' children added to an addon-owned folder", function()
		withHarness(function(_, player, _, _, _, _, _, start)
			local handle = start({ Coins = "Coins" })
			task.wait()
			local folder = player:FindFirstChild("leaderstats")
			local other = newInstance("IntValue")
			other.Name, other.Parent = "Other", folder
			handle:Stop()
			expect(folder.Destroyed).to.equal(false)
			expect(other.Destroyed).to.equal(false)
		end)
	end)

	it("refuses collisions without partial attachments or touching the existing value", function()
		withHarness(function(_, player, data, _, warnings, _, _, start)
			local folder = newInstance("Folder")
			folder.Name, folder.Parent = "leaderstats", player
			local other = newInstance("StringValue")
			other.Name, other.Parent, other.Value = "Title", folder, "Unrelated"
			start({ Coins = "Coins", Title = "Title" })
			task.wait()
			data.Title.Set("Changed")
			task.wait()
			expect(#folder:GetChildren()).to.equal(1)
			expect(other.Value).to.equal("Unrelated")
			expect(#warnings).to.equal(1)
		end)
	end)

	it("refuses absent paths and non-scalar values before creating a folder", function()
		for _, path in { "Absent", "Progress", "Bag" } do
			withHarness(function(_, player, _, _, warnings, _, _, start)
				start({ Coins = "Coins", Invalid = path })
				task.wait()
				expect(player:FindFirstChild("leaderstats")).to.equal(nil)
				expect(#warnings).to.equal(1)
			end)
		end
	end)

	it("cleans up if a dynamic scalar changes type or disappears", function()
		for _, changeType in { true, false } do
			withHarness(function(_, player, data, _, warnings, _, _, start)
				data.Bag.Child("Value").Set(4)
				start({ Value = "Bag.Value" })
				task.wait()
				if changeType then
					data.Bag.Child("Value").Set("different")
				else
					data.Bag.Child("Value").Set(nil)
				end
				task.wait()
				expect(player:FindFirstChild("leaderstats")).to.equal(nil)
				expect(#warnings).to.equal(1)
			end)
		end
	end)

	it("validates all configuration before registering listeners or creating instances", function()
		withHarness(function(h, player, _, deps)
			for _, stats in
				{ {}, { [1] = "Coins" }, { Coins = "" }, { Coins = "Progress..Level" }, { ["Bad\nName"] = "Coins" } }
			do
				expect(function()
					Leaderstats.Start(h.Data, stats, deps)
				end).to.throw()
			end
			expect(player:FindFirstChild("leaderstats")).to.equal(nil)
			expect(deps.Players.PlayerAdded._head).to.equal(false)
		end)
	end)

	it("refuses client startup", function()
		withHarness(function(h, _, _, deps)
			deps.IsServer = function()
				return false
			end
			expect(function()
				Leaderstats.Start(h.Data, { Coins = "Coins" }, deps)
			end).to.throw("must run on the server")
		end)
	end)

	it("never attaches from a late load result after Stop or player removal", function()
		for _, stop in { true, false } do
			withHarness(function(h, player, data, deps, _, _, _, start)
				local waiting
				local timeout
				local api = {
					SessionEnded = h.Data.SessionEnded,
					WaitForData = function(_, waitSeconds)
						timeout = waitSeconds
						waiting = coroutine.running()
						coroutine.yield()
						return data
					end,
				}
				local handle = start({ Coins = "Coins" }, api)
				task.wait()
				expect(timeout).to.equal(10)
				expect(player:FindFirstChild("leaderstats")).to.equal(nil)
				if stop then
					handle:Stop()
				else
					deps.Players.PlayerRemoving:Fire(player)
				end
				task.wait()
				task.spawn(waiting)
				task.wait()
				expect(player:FindFirstChild("leaderstats")).to.equal(nil)
			end)
		end
	end)
end
