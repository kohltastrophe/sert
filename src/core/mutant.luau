--!strict
--- Shared mutable state slot for zero-`getfenv` mutation switching and CLI runtime flags across sandboxed Luau modules.

return {
	id = 0,
	robloxGlobals = false,
}
