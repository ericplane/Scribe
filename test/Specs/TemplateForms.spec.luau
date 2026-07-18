--!nonstrict
-- Exhaustive template-shape coverage: a single rich, deeply-nested template that
-- mixes every declarator form (plain values, Int/Number/String/Enum, nested
-- datatypes, nested Scribe.Dynamic, arrays, array-of-tables, dynamic dicts,
-- dict-of-tables, Timed, buffers, and the ServerOnly/Shared/Session wrappers),
-- driven end-to-end: compile -> defaults at depth -> Dynamic seeding -> nested
-- read/write + datatype packing -> full server->client replication (Init
-- snapshot + post-Init diffs) at every depth.
--
-- NOTE: uses Vector3/CFrame/Color3/UDim2/NumberRange/DateTime, which the headless
-- shim models faithfully. EnumItem is exercised in real Studio (the shim's fake
-- enum items are plain tables, so EnumItem packing can't run headless); nested
-- datatype machinery is identical regardless of which datatype, so a nested
-- Vector3 that round-trips proves the nested-EnumItem path too.
return function()
	local RunService = game:GetService("RunService")
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot) :: any
	local Client = require(ScribeRoot.Client)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local itRunning = if RunService:IsRunning() then it else itSKIP

	local function makeTemplate()
		return {
			-- flat scalars, every leaf declarator
			Coins = Scribe.Int(0, { Min = 0, Max = 1000000 }),
			Ratio = Scribe.Number(1.5, { Min = 0, Max = 10 }),
			Nick = Scribe.String("Guest", { MaxLength = 16 }),
			Team = Scribe.Enum("Red", { "Red", "Blue", "Green" }),
			Online = false, -- plain boolean
			Plain = 7, -- plain number

			-- deeply nested containers mixing declarators, datatypes, sub-containers
			Settings = {
				Input = {
					Keyboard = { -- datatypes 3 levels deep
						Forward = Scribe.Vector3(Vector3.new(1, 0, 0)),
						Back = Scribe.Vector3(Vector3.new(-1, 0, 0)),
						Views = { -- sub-container of datatypes, 4 deep
							Home = Scribe.CFrame(CFrame.new(1, 2, 3)),
							Tint = Scribe.Color3(Color3.fromRGB(10, 20, 30)),
						},
					},
					Sensitivity = Scribe.Number(0.5, { Min = 0, Max = 1 }),
				},
				Graphics = {
					Render = Scribe.Int(32000, { Min = 5000, Max = 120000 }),
					Shadows = true,
				},
				Audio = { Master = Scribe.Int(50, { Min = 0, Max = 100 }) },
				HudAnchor = Scribe.UDim2(UDim2.new(0.5, 10, 0.5, 20)), -- datatype 2 deep
			},

			-- nested Scribe.Dynamic (datatype + scalar), plus a top-level one
			Files = {
				Latest = {
					LandingDate = Scribe.Dynamic(function()
						return DateTime.now()
					end),
					Fpm = Scribe.Int(0),
				},
				CreatedUnix = Scribe.Dynamic(os.time),
			},
			JoinedAt = Scribe.Dynamic(os.time),

			-- arrays: scalars and tables
			Quests = {} :: { number },
			History = {} :: { { Score: number, Name: string } },

			-- dynamic dictionaries: scalars and tables
			Inventory = {} :: { [string]: { Dmg: number, Level: number } },
			Flags = {} :: { [string]: boolean },

			-- top-level datatypes + range
			Spawn = Scribe.Vector3(Vector3.new(0, 5, 0)),
			Zone = Scribe.NumberRange(NumberRange.new(1, 5)),

			-- timed field, buffer, empty container
			Booster = Scribe.Timed(false),
			Blob = buffer.fromstring("XYZ"),
			Loose = {}, -- empty dynamic dictionary

			-- NESTED Scribe.Timed fields: their pathKey embeds the \31 separator, the
			-- exact shape that used to crash SetTimed/ExtendTimed/the sweep.
			Powers = {
				Boost = Scribe.Timed(false),
				Charges = Scribe.Timed(0),
			},

			-- visibility wrappers (with nested content for ServerOnly). Pub carries a
			-- datatype so the Shared-mirror unpack path is exercised on the client.
			Secret = Scribe.ServerOnly({ Flagged = false, Deep = { Level = 1 } }),
			Pub = Scribe.Shared({ Title = "", Home = Scribe.Vector3(Vector3.new(1, 2, 3)) }),
			Runtime = Scribe.Session({ InCombat = false }),
		}
	end

	itRunning("compiles the deep mixed template and exposes defaults at every depth", function()
		local harness = TestCtx.make({ Template = makeTemplate() })
		local _p, _e, data = harness.Join(7001)

		-- top-level declarators
		expect(data.Coins.Get()).to.equal(0)
		expect(data.Ratio.Get()).to.equal(1.5)
		expect(data.Nick.Get()).to.equal("Guest")
		expect(data.Team.Get()).to.equal("Red")
		expect(data.Online.Get()).to.equal(false)
		expect(data.Plain.Get()).to.equal(7)

		-- nested scalars + a bounded default within range (not clamped)
		expect(data.Settings.Graphics.Render.Get()).to.equal(32000)
		expect(data.Settings.Audio.Master.Get()).to.equal(50)
		expect(data.Settings.Input.Sensitivity.Get()).to.equal(0.5)
		expect(data.Settings.Graphics.Shadows.Get()).to.equal(true)

		-- nested datatypes unpack to the real datatype at depth
		local fwd = data.Settings.Input.Keyboard.Forward.Get()
		expect(typeof(fwd)).to.equal("Vector3")
		expect(fwd.X).to.equal(1)
		local home = data.Settings.Input.Keyboard.Views.Home.Get()
		expect(typeof(home)).to.equal("CFrame")
		expect(typeof(data.Settings.Input.Keyboard.Views.Tint.Get())).to.equal("Color3")
		expect(typeof(data.Settings.HudAnchor.Get())).to.equal("UDim2")
		expect(typeof(data.Spawn.Get())).to.equal("Vector3")
		expect(typeof(data.Zone.Get())).to.equal("NumberRange")

		-- empty containers materialize as tables; buffer round-trips
		expect(typeof(data.Loose.Get())).to.equal("table")
		expect(buffer.tostring(data.Blob.Get())).to.equal("XYZ")

		-- visibility wrappers all readable on the server, including nested ServerOnly
		expect(data.Secret.Flagged.Get()).to.equal(false)
		expect(data.Secret.Deep.Level.Get()).to.equal(1)
		expect(data.Pub.Title.Get()).to.equal("")
		expect(data.Runtime.InCombat.Get()).to.equal(false)

		harness.Cleanup()
	end)

	itRunning("seeds nested and top-level Scribe.Dynamic fields on a new profile, packing datatypes", function()
		local harness = TestCtx.make({ Template = makeTemplate() })
		local _p, entry, data = harness.Join(7002)

		expect(typeof(data.Files.Latest.LandingDate.Get())).to.equal("DateTime") -- nested datatype Dynamic
		expect(type(data.Files.CreatedUnix.Get())).to.equal("number") -- nested scalar Dynamic
		expect(type(data.JoinedAt.Get())).to.equal("number") -- top-level Dynamic
		-- the datatype Dynamic is stored packed
		expect(type(entry.LiveData.Files.Latest.LandingDate)).to.equal("buffer")
		harness.Cleanup()
	end)

	itRunning("round-trips nested datatypes, arrays (scalar + table), and dynamic dicts on the server", function()
		local harness = TestCtx.make({ Template = makeTemplate() })
		local _p, entry, data = harness.Join(7003)

		-- nested datatype write/read + packed storage
		data.Settings.Input.Keyboard.Forward.Set(Vector3.new(9, 8, 7))
		expect(data.Settings.Input.Keyboard.Forward.Get().X).to.equal(9)
		expect(type(entry.LiveData.Settings.Input.Keyboard.Forward)).to.equal("buffer")
		data.Settings.Input.Keyboard.Views.Tint.Set(Color3.fromRGB(200, 100, 50))
		expect(typeof(data.Settings.Input.Keyboard.Views.Tint.Get())).to.equal("Color3")

		-- bounded nested int clamps
		data.Settings.Audio.Master.Set(999)
		expect(data.Settings.Audio.Master.Get()).to.equal(100)

		-- scalar array
		data.Quests.Insert(1)
		data.Quests.Insert(2)
		expect(data.Quests.Has(2)).to.equal(true)
		expect(data.Quests.Count()).to.equal(2)

		-- array of tables
		data.History.Insert({ Score = 10, Name = "a" })
		data.History.Insert({ Score = 20, Name = "b" })
		expect(data.History.Count()).to.equal(2)
		expect(data.History[2].Score.Get()).to.equal(20)

		-- dynamic dict of tables
		data.Inventory.Sword.Set({ Dmg = 5, Level = 2 })
		expect(data.Inventory.Sword.Dmg.Get()).to.equal(5)
		expect(data.Inventory.Sword.Level.Get()).to.equal(2)
		-- dynamic dict of scalars
		data.Flags.Beta.Set(true)
		expect(data.Flags.Beta.Get()).to.equal(true)
		expect(data.Inventory.Count()).to.equal(1)

		harness.Cleanup()
	end)

	itRunning("replicates the full nested tree to the client at every depth (Init + post-Init diffs)", function()
		local harness = TestCtx.make({ AutoPump = false, Template = makeTemplate() })
		local player, entry, serverData = harness.Join(7004)
		harness.Transport.LocalPlayer = player

		-- Mutate at every depth BEFORE the handshake, so it lands in the Init snapshot.
		serverData.Coins.Set(500)
		serverData.Settings.Input.Keyboard.Forward.Set(Vector3.new(3, 3, 3)) -- datatype 3 deep
		serverData.Settings.Input.Keyboard.Views.Home.Set(CFrame.new(9, 9, 9)) -- datatype 4 deep
		serverData.Settings.Audio.Master.Set(11)
		serverData.Inventory.Bow.Set({ Dmg = 7, Level = 1 }) -- dynamic dict key created pre-Init
		serverData.Quests.Insert(42)
		serverData.Spawn.Set(Vector3.new(2, 2, 2))

		local clientData = Client.new(harness.Options, harness.Compiled)
		harness.Transport:PumpToServer() -- Hello -> Init snapshot
		harness.Transport:PumpToClient()

		-- Init snapshot applied at every depth, datatypes unpacked on the mirror.
		expect(clientData.Coins.Get()).to.equal(500)
		expect(clientData.Settings.Input.Keyboard.Forward.Get().X).to.equal(3)
		expect(typeof(clientData.Settings.Input.Keyboard.Views.Home.Get())).to.equal("CFrame")
		expect(clientData.Settings.Audio.Master.Get()).to.equal(11)
		expect(clientData.Inventory.Bow.Dmg.Get()).to.equal(7)
		expect(clientData.Quests.Has(42)).to.equal(true)
		expect(clientData.Spawn.Get().X).to.equal(2)
		-- ServerOnly never reaches the client mirror.
		expect(clientData.Raw.Secret.Flagged.Get()).to.equal(nil)

		-- Post-Init diffs at depth replicate too.
		serverData.Settings.Input.Keyboard.Forward.Set(Vector3.new(6, 6, 6))
		serverData.Settings.Audio.Master.Set(22)
		serverData.Inventory.Bow.Level.Set(9) -- deep dict-of-table leaf
		serverData.Inventory.Axe.Set({ Dmg = 3, Level = 1 }) -- new dynamic key via diff
		harness.Ctx.Replication.FlushEntry(entry)
		harness.Transport:PumpToClient()

		expect(clientData.Settings.Input.Keyboard.Forward.Get().X).to.equal(6)
		expect(clientData.Settings.Audio.Master.Get()).to.equal(22)
		expect(clientData.Inventory.Bow.Level.Get()).to.equal(9)
		expect(clientData.Inventory.Axe.Dmg.Get()).to.equal(3)

		harness.Cleanup()
	end)

	itRunning("fires a nested-container Observe/Changed on the client when a deep leaf changes", function()
		local harness = TestCtx.make({ AutoPump = false, Template = makeTemplate() })
		local player, entry, serverData = harness.Join(7005)
		harness.Transport.LocalPlayer = player
		local clientData = Client.new(harness.Options, harness.Compiled)

		local leaf, container = {}, 0
		clientData.Settings.Input.Keyboard.Forward.Observe(function(v)
			table.insert(leaf, typeof(v) == "Vector3" and v.X or "nil")
		end)
		clientData.Settings.Input.Keyboard.Changed(function()
			container += 1
		end)

		harness.Transport:PumpToServer()
		harness.Transport:PumpToClient()

		serverData.Settings.Input.Keyboard.Forward.Set(Vector3.new(4, 0, 0))
		harness.Ctx.Replication.FlushEntry(entry)
		harness.Transport:PumpToClient()

		-- leaf Observe saw default then the change; the container Changed fired.
		expect(leaf[#leaf]).to.equal(4)
		expect(container >= 1).to.equal(true)
		harness.Cleanup()
	end)

	itRunning("sets, extends, reads, and sweeps NESTED Scribe.Timed fields", function()
		local harness = TestCtx.make({ Template = makeTemplate() })
		local _p, entry, data = harness.Join(7006)
		local boostKey = "Powers" .. string.char(31) .. "Boost" -- the nested field's pathKey

		-- A nested Timed field's pathKey embeds \31; SetTimed used to throw
		-- routing that key through the accessor tree. It must now work.
		data.Powers.Boost.SetTimed(true, 60)
		expect(data.Powers.Boost.Get()).to.equal(true)
		local active, remaining = data.Powers.Boost.Active()
		expect(active).to.equal(true)
		expect(remaining ~= nil and remaining > 0).to.equal(true)

		-- The expiry is recorded in the server-only store under the full pathKey.
		expect(type(entry.LiveData._Scribe.Timed[boostKey])).to.equal("number")

		-- ExtendTimed stacks onto the running nested timer.
		local _, before = data.Powers.Boost.Active()
		data.Powers.Boost.ExtendTimed(60)
		local _, after = data.Powers.Boost.Active()
		expect((after :: number) >= (before :: number)).to.equal(true)

		-- A second nested Timed field (numeric leaf) is independent.
		data.Powers.Charges.SetTimed(3, 60)
		expect(data.Powers.Charges.Get()).to.equal(3)
		expect((data.Powers.Charges.Active())).to.equal(true)

		-- An expired nested timer sweeps the value back to its default and clears
		-- the record (write the expiry into the past, then run the sweep).
		entry.LiveData._Scribe.Timed[boostKey] = os.time() - 5
		harness.Ctx.Timed.OnLoad(entry)
		expect(data.Powers.Boost.Get()).to.equal(false) -- back to the template default
		expect(entry.LiveData._Scribe.Timed[boostKey]).to.equal(nil)

		harness.Cleanup()
	end)

	itRunning("container-level reads return real datatypes, never packed buffers (Get + Clone)", function()
		local harness = TestCtx.make({ Template = makeTemplate() })
		local _p, _e, data = harness.Join(7007)

		-- Reading a CONTAINER that holds datatype descendants must convert every
		-- nested buffer back to the datatype, at any depth (Node used to leak the
		-- packed buffer for container-level reads).
		local kb = data.Settings.Input.Keyboard.Get()
		expect(typeof(kb.Forward)).to.equal("Vector3")
		expect(kb.Forward.X).to.equal(1)
		expect(typeof(kb.Back)).to.equal("Vector3")
		expect(typeof(kb.Views.Home)).to.equal("CFrame") -- one level deeper
		expect(typeof(kb.Views.Tint)).to.equal("Color3")

		-- Reading a whole subtree from higher up unpacks at every depth too.
		local settings = data.Settings.Get()
		expect(typeof(settings.Input.Keyboard.Forward)).to.equal("Vector3")
		expect(typeof(settings.HudAnchor)).to.equal("UDim2")

		-- Clone returns an independent copy that is also buffer-free.
		local clone = data.Settings.Input.Keyboard.Clone()
		expect(typeof(clone.Forward)).to.equal("Vector3")
		expect(typeof(clone.Views.Home)).to.equal("CFrame")
		clone.Forward = Vector3.new(0, 0, 0) -- mutating the clone leaves stored data intact
		expect(data.Settings.Input.Keyboard.Forward.Get().X).to.equal(1)

		-- A container with NO datatypes below still reads back as a plain table.
		expect(typeof(data.Settings.Graphics.Get())).to.equal("table")
		expect(data.Settings.Graphics.Get().Render).to.equal(32000)

		harness.Cleanup()
	end)

	itRunning("unpacks datatype fields inside a Shared root on the receiving client", function()
		local harness = TestCtx.make({ AutoPump = false, Template = makeTemplate() })
		-- Player A owns the Shared data; the local client is player B and reads it.
		local _playerA, entryA, dataA = harness.Join(7008)
		dataA.Pub.Home.Set(Vector3.new(4, 5, 6))

		local playerB = harness.Join(7009)
		harness.Transport.LocalPlayer = playerB
		local clientB = Client.new(harness.Options, harness.Compiled)

		-- Broadcast A's shared state, then flush so B receives the SharedInit/Diff
		-- carrying A's Pub root.
		harness.Ctx.Replication.FlushEntry(entryA)
		harness.Transport:PumpToServer() -- B's Hello
		harness.Transport:PumpToClient()

		local sharedA = clientB.GetShared(7008)
		expect(sharedA ~= nil).to.equal(true)
		-- The datatype field must arrive as a real Vector3, not the wire buffer.
		expect(typeof((sharedA :: any).Pub.Home)).to.equal("Vector3")
		expect((sharedA :: any).Pub.Home.X).to.equal(4)

		harness.Cleanup()
	end)

	itRunning("rolls back Timed writes (value AND expiry) when a transaction aborts", function()
		local harness = TestCtx.make({ Template = makeTemplate() })
		local player, entry, data = harness.Join(7010)

		expect((data.Booster.Active())).to.equal(false) -- baseline: inactive

		local ok = harness.Data.Transaction(player, function()
			data.Booster.SetTimed(true, 3600)
			error("abort") -- force rollback
		end)
		expect(ok).to.equal(false)

		-- Value AND expiry must both revert. They used to diverge: the value rolled
		-- back via the accessor snapshot while the raw _Scribe.Timed write persisted.
		expect(data.Booster.Get()).to.equal(false)
		expect((data.Booster.Active())).to.equal(false)
		expect(entry.LiveData._Scribe.Timed["Booster"]).to.equal(nil)

		-- A COMMITTED transaction keeps the timer.
		local ok2 = harness.Data.Transaction(player, function()
			data.Booster.SetTimed(true, 3600)
		end)
		expect(ok2).to.equal(true)
		expect(data.Booster.Get()).to.equal(true)
		expect((data.Booster.Active())).to.equal(true)

		harness.Cleanup()
	end)

	itRunning("unpacks ROOT-level datatype fields on a whole-data Get()/Clone()", function()
		local harness = TestCtx.make({ Template = makeTemplate() })
		local _p, _e, data = harness.Join(7011)

		-- Spawn/Zone are datatype fields at the ROOT; reading the whole root must
		-- convert them, not leak the packed buffer (root.HasDatatype must be set).
		local whole = data.Get()
		expect(typeof(whole.Spawn)).to.equal("Vector3")
		expect(typeof(whole.Zone)).to.equal("NumberRange")
		expect(whole.Spawn.Y).to.equal(5)

		local cloned = data.Clone()
		expect(typeof(cloned.Spawn)).to.equal("Vector3")

		harness.Cleanup()
	end)

	itRunning("Clone() of a datatype-bearing container returns an independent (copied) buffer", function()
		local harness = TestCtx.make({ Template = makeTemplate() })
		local _p, entry, data = harness.Join(7012)

		-- The root holds Spawn (datatype) AND Blob (raw buffer), so root.HasDatatype
		-- routes Clone through cloneUnpack. The raw buffer must be COPIED, not aliased.
		local cloned = data.Clone()
		expect(buffer.tostring(cloned.Blob)).to.equal("XYZ")
		buffer.writeu8(cloned.Blob, 0, string.byte("Z")) -- mutate the clone
		expect(buffer.readu8(entry.LiveData.Blob, 0)).to.equal(string.byte("X")) -- stored intact

		harness.Cleanup()
	end)

	itRunning("Default() and Remove() convert datatypes at the boundary like the other reads", function()
		local harness = TestCtx.make({ Template = makeTemplate() })
		local _p, _e, data = harness.Join(7013)

		-- Default() on a datatype-bearing container must unpack, not leak packed buffers.
		local kbDefault = data.Settings.Input.Keyboard.Default()
		expect(typeof(kbDefault.Forward)).to.equal("Vector3")
		expect(typeof(kbDefault.Views.Home)).to.equal("CFrame")
		-- A nested datatype leaf's own Default() still unpacks (regression check).
		expect(typeof(data.Settings.Input.Keyboard.Forward.Default())).to.equal("Vector3")

		-- Remove() on a static datatype leaf returns the real datatype, not the buffer.
		local removed = data.Settings.Input.Keyboard.Remove("Forward")
		expect(typeof(removed)).to.equal("Vector3")

		harness.Cleanup()
	end)
end
