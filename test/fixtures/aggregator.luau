--!nonstrict
-- An aggregator-style caller for Runner.spec: hooks registered with no `*.spec` file on the stack (here, on a
-- coroutine of their own, as when an aggregator is required by the entry script) are global.
return function(sert, before: () -> (), after: () -> ())
	coroutine.wrap(function()
		sert.beforeEach(before)
		sert.afterEach(after)
	end)()
end
