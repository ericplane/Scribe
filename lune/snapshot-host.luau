--!strict
-- Adapt Jest's snapshot filesystem calls to known local spec paths only.
local fs = require("@lune/fs")

local function normalize(path: string): string
	return (string.gsub(path, "\\", "/"))
end

return function(root: any, services: any, allowUpdates: boolean)
	local files: { [string]: boolean } = {}
	local directories: { [string]: boolean } = {}
	for _, node in root.Test:GetDescendants() do
		if node:IsA("ModuleScript") and string.sub(node.Name, -5) == ".spec" then
			local parent = string.match(normalize(node._source), "^(.*)/[^/]+$")
			local directory = parent .. "/__snapshots__"
			directories[directory] = true
			files[directory .. "/" .. node.Name .. ".snap.lua"] = true
		end
	end
	local function checkWrite(path: string, directory: boolean?)
		path = normalize(path)
		assert(allowUpdates, "Snapshot updates require SCRIBE_UPDATE_SNAPSHOTS=1 outside CI")
		assert(
			if directory then directories[path] else files[path],
			"Snapshot path is outside the known spec files: " .. path
		)
	end
	services.CoreScriptSyncService = {
		GetScriptFilePath = function(_self: any, node: any): string
			assert(node._source, "Snapshot test has no source path")
			return node._source
		end,
	}
	services.FileSystemService = {
		Exists = function(_self: any, path: string): boolean
			path = normalize(path)
			return fs.isDir(path) or fs.isFile(path)
		end,
		CreateDirectories = function(_self: any, path: string)
			path = normalize(path)
			checkWrite(path, true)
			fs.writeDir(path)
		end,
		WriteFile = function(_self: any, path: string, contents: string)
			path = normalize(path)
			checkWrite(path)
			fs.writeFile(path, contents)
		end,
		IsRegularFile = function(_self: any, path: string): boolean
			path = normalize(path)
			return files[path] == true and fs.isFile(path)
		end,
		Remove = function(_self: any, path: string)
			path = normalize(path)
			checkWrite(path)
			fs.removeFile(path)
		end,
	}
end
