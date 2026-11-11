--!strict
-- Registers hooks on a fresh coroutine with no spec file on the call stack so they attach as global hooks.
return function(sertMod: any, before: () -> (), after: () -> ())
	coroutine.wrap(function()
		sertMod.beforeEach(before)
		sertMod.afterEach(after)
	end)()
end
