--!nonstrict
-- A suite file that is not named `*.spec` (as z's are), for Modifiers.spec: its hooks belong to it, so they wrap only
-- its own tests, not every test of the run.
return function(sert, log: { string })
	sert.beforeEach(function() table.insert(log, "suite+") end)
	sert.test("in suite", function() table.insert(log, "suite") end)
end
