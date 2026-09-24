--!strict

export type ServerTemplate = {
	Wave: number,
	Status: string,
	Round: { Active: boolean },
}

local template: ServerTemplate = {
	Wave = 0,
	Status = "Lobby",
	Round = { Active = false },
}

return template
