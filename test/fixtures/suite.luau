--!strict
-- Helper suite fixture not ending in `.spec` whose file-scoped hooks apply only to its own tests.
return function(sertMod: any, log: { string })
	sertMod.beforeEach(function() table.insert(log, "suite+") end)
	sertMod.test("in suite", function() table.insert(log, "suite") end)
end
