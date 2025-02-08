local Sert = require "../src"

return {
	["only run focused tests"] = function()
		local regularRan = false
		local focusedRan = false

		Sert.run({
			regular = {
				test = function()
					regularRan = true
				end,
			},
			focused = {
				_focus = true,
				test = function()
					focusedRan = true
				end,
			},
		}, nil, false, true)

		assert(focusedRan, "focused test not run")
		assert(not regularRan, "non-focused test should not run")
	end,
}
