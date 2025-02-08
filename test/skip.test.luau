local Sert = require "../src"

return {
	["skip"] = function()
		local results = Sert.run({
			function()
				return "SKIP"
			end,
		}, nil, false, true)
		assert(results.SKIPPED == 1, "case not skipped")

		local results2 = Sert.run({
			_skip = true,
			test = function() end,
		}, nil, false, true)
		assert(results2.SKIPPED == 1, "test not skipped")
	end,
}
