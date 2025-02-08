local Sert = require "../src"

return {
	["runs tests async/sync"] = function()
		local async
		local test = {
			function()
				Sert.wait(0.1)
				async = true
			end,
			function()
				async = false
			end,
		}
		Sert.run(test, nil, true, true)
		assert(async, "async failing")
		Sert.run(test, nil, false, true)
		assert(not async, "sync failing")
	end,

	["handles errors in async tests"] = function()
		local results = Sert.run({
			function()
				Sert.wait(0.1)
				error("async error")
			end,
		}, nil, true, true)
		assert(results.FAILED == 1, "async error not caught")
	end,
}
