--!strict
--- Shared mutable state slot for zero-`getfenv` mutation switching and CLI runtime flags across sandboxed Luau modules.

export type Slot = {
	id: number,
	robloxGlobals: boolean,
	hits: { [number]: boolean }?,
	h: (key: number) -> boolean,
}

local slot: Slot
slot = {
	id = 0,
	robloxGlobals = false,
	hits = nil :: { [number]: boolean }?,
	h = function(key: number): boolean
		local active = slot.hits
		if active ~= nil then active[key] = true end
		return false
	end,
}

return slot :: Slot
