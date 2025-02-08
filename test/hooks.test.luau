local Sert = require "../src"

return {
	["execute in order"] = function()
		local actual = {}
		local expected = { "beforeEach", "case", "afterEach", "after" }

		Sert.run({
			after = function()
				table.insert(actual, "after")
			end,
			afterEach = function()
				table.insert(actual, "afterEach")
			end,
			beforeEach = function()
				table.insert(actual, "beforeEach")
			end,

			case = function()
				table.insert(actual, "case")
			end,
		}, nil, false, true)

		for i, name in expected do
			assert(table.find(actual, name), `"{name}" failed to execute`)
			assert(actual[i] == name, `"{name}" executed out of order at position "{i}"`)
		end
	end,

	["handles errors in hooks"] = function()
		local results = Sert.run({
			beforeEach = function()
				error("hook error")
			end,
			test = function() end,
		}, nil, false, true)
		assert(results.FAILED == 1, "hook error not reported")
	end,

	["records test timing"] = function()
		local results = Sert.run({
			test = function()
				Sert.wait(0.1)
			end,
		}, nil, false, true)
		assert(results.Test.test[Sert.TIME] >= 0.1, `timing not recorded, got {results.Test.test[Sert.TIME]}`)
	end,
}
