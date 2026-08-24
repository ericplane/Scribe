--!nonstrict
-- The shared key space every simulated server reads and writes.
--
-- This is the only thing all the servers have in common, and it is what makes the
-- simulation worth running: two servers contending for one player's key is the
-- shape of nearly every high-CCU failure in a persistence layer.
--
-- NOTHING HERE YIELDS. Every function completes on the caller's stack, which is
-- what makes a commit atomic under a cooperative scheduler without needing a
-- lock. All the waiting -- read latency, write latency, budget queuing -- happens
-- in Store, deliberately OUTSIDE the commit. Adding a yield to this file would
-- silently turn every write into a window another server can interleave into,
-- and the resulting "bugs" would be artefacts of the model.

local Keyspace = {}
Keyspace.__index = Keyspace

export type Record = {
	Value: any,
	Version: number, -- monotonic per key; the CAS token
	VersionId: string,
	UserIds: { number },
	Metadata: { [string]: any },
	CreatedTime: number,
	UpdatedTime: number,
	Backups: { { VersionId: string, Value: any, UpdatedTime: number, Hour: number } },
}

function Keyspace.new()
	return setmetatable({
		-- keys[storeName][keyName] = Record
		_keys = {},
		-- Every version id ever minted, so a stale one can be told apart from a
		-- fabricated one -- ProfileStore's error text differs and Scribe's
		-- version-restore path branches on it.
		_minted = {},
	}, Keyspace)
end

local function bucket(self, store: string)
	local existing = self._keys[store]
	if existing == nil then
		existing = {}
		self._keys[store] = existing
	end
	return existing
end

--- The record for a key, or nil. Returned BY REFERENCE for internal use; callers
--- that hand data outward must copy (see Store's deep-copy invariants).
function Keyspace.Read(self, store: string, key: string): Record?
	return bucket(self, store)[key]
end

--- The CAS token for a key. Zero when the key has never been written, which is
--- distinct from "written then removed" -- a tombstone keeps its version so a
--- concurrent writer still sees a change.
function Keyspace.Version(self, store: string, key: string): number
	local record = bucket(self, store)[key]
	return if record then record.Version else 0
end

--- Write a key. The caller has already checked the version and paid the latency;
--- this is the atomic part.
---
--- `value` is stored AS GIVEN. Store is responsible for having deep-copied it --
--- the copy is done there because that is where the aliasing hazard lives, and
--- copying in both places would double the cost of the hottest path in the model.
function Keyspace.Commit(self, store: string, key: string, value: any, opts): Record
	local records = bucket(self, store)
	local record = records[key]
	local now = opts.Now

	if record == nil then
		record = {
			Value = nil,
			Version = 0,
			VersionId = "",
			UserIds = {},
			Metadata = {},
			CreatedTime = now,
			UpdatedTime = now,
			Backups = {},
		}
		records[key] = record
	end

	record.Value = value
	record.Version += 1
	record.VersionId = opts.VersionId
	record.UpdatedTime = now
	if opts.UserIds ~= nil then
		record.UserIds = opts.UserIds
	end
	if opts.Metadata ~= nil then
		record.Metadata = opts.Metadata
	end
	self._minted[opts.VersionId] = true

	-- Versioning is per UTC hour, not per write: the FIRST write in an hour
	-- creates the recoverable backup and later writes in that hour overwrite it
	-- permanently. Modelled because it is what makes "not every write is
	-- recoverable" true, which is the premise of Scribe's version-restore path.
	local hour = math.floor(now / 3600)
	local latest = record.Backups[#record.Backups]
	if latest == nil or latest.Hour ~= hour then
		table.insert(record.Backups, { VersionId = opts.VersionId, Value = value, UpdatedTime = now, Hour = hour })
		-- Bounded, matching what FakeProfileStore already keeps. The real 30-day
		-- retention window is not modelled: no bounded run reaches it.
		if #record.Backups > 8 then
			table.remove(record.Backups, 1)
		end
	else
		latest.VersionId = opts.VersionId
		latest.Value = value
		latest.UpdatedTime = now
	end

	return record
end

--- Delete a key, keeping its version line.
---
--- The version keeps counting rather than resetting, so a writer holding a stale
--- token still loses its CAS after a remove. Resetting to zero would let a
--- delayed write silently resurrect deleted data -- and "the erase came back" is
--- a bug worth being able to find, not one to make unrepresentable.
function Keyspace.Remove(self, store: string, key: string, opts): any
	local records = bucket(self, store)
	local record = records[key]
	if record == nil then
		return nil
	end
	local previous = record.Value
	record.Value = nil
	record.Version += 1
	record.VersionId = opts.VersionId
	record.UpdatedTime = opts.Now
	self._minted[opts.VersionId] = true
	return previous
end

--- Every backup for a key, newest first.
function Keyspace.Versions(self, store: string, key: string)
	local record = bucket(self, store)[key]
	if record == nil then
		return {}
	end
	local out = {}
	for index = #record.Backups, 1, -1 do
		table.insert(out, record.Backups[index])
	end
	return out
end

function Keyspace.WasMinted(self, versionId: string): boolean
	return self._minted[versionId] == true
end

--- Every (store, key) currently holding a value. For invariant checks and digests.
function Keyspace.Each(self)
	local out = {}
	for storeName, records in self._keys do
		for keyName, record in records do
			table.insert(out, { Store = storeName, Key = keyName, Record = record })
		end
	end
	-- Sorted so a digest over the result is stable; `pairs` order is not.
	table.sort(out, function(a, b)
		if a.Store ~= b.Store then
			return a.Store < b.Store
		end
		return a.Key < b.Key
	end)
	return out
end

return Keyspace
