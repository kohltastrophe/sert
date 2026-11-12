--!strict
-- Helper spec fixture invoked inside isolated runner tests so its hooks and tests bind to `Other`.
return function(sertMod: any, log: { string })
	sertMod.beforeEach(function() table.insert(log, "other+") end)
	sertMod.afterEach(function() table.insert(log, "other-") end)
	sertMod.test("other", function() table.insert(log, "other") end)
end
