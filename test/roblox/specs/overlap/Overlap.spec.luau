--!strict
-- A `concurrent` server side: in a play session it runs after the server handed the client its request.
return function(context: any)
	local sert = context.sert
	local session = require(game:GetService("ReplicatedStorage").sert.roblox.Runner)._session

	sert.test("a concurrent side runs after the handoff in a play session, in order elsewhere", function()
		sert.expect(context.side).toBe("overlap")
		local run = workspace:GetAttribute(session.RUN_ATTRIBUTE)
		if context.request.mode == "play" then
			sert.eq(run, context.request.runId, "the client has its request")
		else
			sert.eq(run, nil, "no client to hand to")
		end
	end)
end
