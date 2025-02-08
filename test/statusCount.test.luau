local Sert = require "../src"

return {
	["pass/fail/skip count"] = function()
		local results = Sert.run({
			function()
				-- passes
			end,
			function()
				error("oops")
			end,
			function()
				return "SKIP"
			end,
		}, nil, false, true)
		assert(results.PASSED == 1, "no pass")
		assert(results.FAILED == 1, "no fail")
		assert(results.SKIPPED == 1, "no skip")
	end,
}
