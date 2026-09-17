--!strict
-- Actions add-ons offer to the Studio plugin, by add-on name.

local Addons = {}

export type Action = { Run: (args: any) -> any, Writes: boolean? }
export type Actions = { [string]: Action }

local registered: { [string]: { Actions: Actions, Token: {} } } = {}

-- Set as the server bundle is built; read through Scribe.GetProfileKeyPrefix, which must
-- not require the Server module.
local profileKeyPrefix = "PLAYER_"

function Addons.SetProfileKeyPrefix(prefix: string)
	profileKeyPrefix = prefix
end

function Addons.ProfileKeyPrefix(): string
	return profileKeyPrefix
end

--- Registers under `name`, replacing an earlier one; the returned remover ignores a later one.
function Addons.Register(name: string, actions: Actions): () -> ()
	local token = {}
	registered[name] = { Actions = actions, Token = token }
	return function()
		local current = registered[name]
		if current ~= nil and current.Token == token then
			registered[name] = nil
		end
	end
end

--- Every add-on's actions and whether each needs writes.
function Addons.List(): { [string]: { [string]: { Writes: boolean } } }
	local out = {}
	for name, registration in registered do
		local summary = {}
		for action, entry in registration.Actions do
			summary[action] = { Writes = entry.Writes == true }
		end
		out[name] = summary
	end
	return out
end

--- Whether the action needs writes; nil when unregistered.
function Addons.Writes(name: string, action: string): boolean?
	local registration = registered[name]
	local entry = if registration then registration.Actions[action] else nil
	return if entry then entry.Writes == true else nil
end

--- Runs one action; false with a reason when it is not registered.
function Addons.Invoke(name: string, action: string, args: any): (boolean, any)
	local registration = registered[name]
	if registration == nil then
		return false, `no add-on named "{name}" is registered`
	end
	local entry = registration.Actions[action]
	if entry == nil then
		return false, `add-on "{name}" has no action "{action}"`
	end
	return true, entry.Run(args)
end

return Addons
