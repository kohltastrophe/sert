local Sert = require "../src"

return {
	["silent"] = function()
		local output
		local fenv = getfenv(Sert.run)
		function fenv.print()
			output = true
		end
		setfenv(Sert.run, fenv)

		local test = {
			_skip = true,
		}

		Sert.run(test, nil, false, true)
		assert(not output, "not silent")

		Sert.run(test, nil, false, false)
		assert(output, "no output")

		fenv.print = print
		setfenv(Sert.run, fenv)
	end,
}
