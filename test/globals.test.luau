local Sert = require "../src"

return {
	["globals"] = function()
		local ok
		Sert.run({
			function()
				print(true)
			end,
		}, {
			print = function(value)
				ok = value
			end,
		}, false, true)
		assert(ok, "failed to mock")
	end,
}
