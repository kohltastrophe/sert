--!nonstrict
-- A second "spec file" for Runner.spec: what it registers belongs to the file "Other", hooks included. Not required
-- by test/run.luau; Runner.spec calls it inside sert.isolate.
return function(sert, log: { string })
	sert.beforeEach(function() table.insert(log, "other+") end)
	sert.afterEach(function() table.insert(log, "other-") end)
	sert.test("other", function() table.insert(log, "other") end)
end
