local Sert = require "../src"

return {
	["handles invalid test cases"] = function()
		local results = Sert.run({
			invalidCase = "not a function",
			validCase = function() end,
		}, nil, false, true)
		assert(results.FAILED == 1, "invalid test not marked as failure")
	end,
}
