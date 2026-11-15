--!strict
-- Dual-target conformance harness (`sert.roblox.conformance`) tests and end-to-end specs running on both
-- isolated headless `sert.env` (`[portable]`) and Roblox Studio (`[roblox]` / `[client]`).

local registry = require("../src/core/registry")
local robloxTypes = require("../src/roblox")
local sert = require("../src")

type ConformanceContext = robloxTypes.ConformanceContext
type ConformanceOptions = robloxTypes.ConformanceOptions

local conformance = sert.roblox.conformance
local describe = sert.describe
local test = sert.test
local Layout = sert.roblox.Layout

local function runIsolated(register: () -> (), opts: sert.RunOptions?): sert.Results
	local sub = registry.newState()
	registry.isolateDepth += 1
	local ok, res = pcall(function(): sert.Results
		return registry.withState(sub, function(): sert.Results
			register()
			local merged: sert.RunOptions = if opts ~= nil then table.clone(opts) else {}
			if merged.quiet == nil and merged.silent == nil then merged.quiet = true end
			if merged.raise == nil then merged.raise = false end
			return sert.run(merged)
		end)
	end)
	registry.isolateDepth -= 1
	if not ok then error(res, 0) end
	return res
end

describe("sert.roblox.conformance harness behavior", function()
	test(
		"registers dual [portable] and [roblox]/[client] specs, honors skip/focus/guards, and sweeps containers",
		function()
			local targetsSeen: { string } = {}
			local containersSeen: { any } = {}
			local envsSeen: { any } = {}

			sert.eq(robloxTypes.conformance, conformance, "re-exports same conformance table")

			local res = runIsolated(function()
				conformance("default workspace spec", function(root: Instance, ctx: ConformanceContext)
					local tgt: string = ctx.target
					table.insert(targetsSeen, tgt)
					table.insert(containersSeen, root)
					table.insert(envsSeen, ctx.env)
					sert.eq(ctx.isRoblox, false)
					sert.eq(root.Parent, ctx.workspace)
					local p: any = ctx.Instance.new("Part")
					p.Name = "ConformingPart"
					p.Parent = root
					sert.eq(root:FindFirstChild("ConformingPart"), p)
				end)

				local clientOpts: ConformanceOptions = { target = "client", container = "PlayerGui", tags = { "ui" } }
				conformance("client gui spec", function(root: Instance, ctx: ConformanceContext)
					local tgt: string = ctx.target
					table.insert(targetsSeen, tgt)
					sert.eq(ctx.isRoblox, false)
					sert.ok(root:IsA("ScreenGui"))
					local lp = ctx.getService("Players").LocalPlayer
					sert.eq(root.Parent, lp:FindFirstChildOfClass("PlayerGui"))
					local frame: any = ctx.Instance.new("Frame")
					frame.Size = ctx.UDim2.fromOffset(120, 48)
					frame.Parent = root
					ctx.step(1 / 60)
					Layout.fitsParent(frame)
				end, clientOpts)

				conformance.skip("skipped dual spec", function() sert.fail("skipped spec must not execute") end)
			end)

			sert.eq(res.passed, 2)
			sert.eq(res.failed, 0)
			if not sert.isRoblox then
				sert.eq(res.skipped, 4)
				sert.eq(res.skippedRoblox, 3)
			else
				sert.eq(res.skipped, 1)
			end
			sert.eq(targetsSeen, { "portable", "portable" })
			for _, root in containersSeen do
				sert.eq((root :: any).Parent, nil)
			end
			for _, e in envsSeen do
				if e ~= nil then sert.ok((e :: any)._destroyed == true) end
			end

			-- Focus mode filters to focused conformance specs only
			local focusLog: { string } = {}
			local focusRes = runIsolated(function()
				conformance("unfocused spec", function()
					table.insert(focusLog, "unfocused")
					sert.eq(focusLog[#focusLog], "unfocused")
				end)
				conformance.focus("focused spec", function()
					table.insert(focusLog, "focused")
					sert.eq(focusLog[#focusLog], "focused")
				end)
			end)
			sert.eq(focusRes.passed, 1)
			sert.eq(focusLog, { "focused" })

			-- Validation guards
			sert.throws(function()
				conformance("", function() end)
			end, "non-empty test name")
			sert.throws(function() conformance("bad fn", "nope" :: any) end, "callback function")
			sert.throws(function()
				conformance("bad opts", function() end, "nope" :: any)
			end, "options must be a table")
			sert.throws(function()
				conformance("unknown opt", function() end, { bogus = true } :: any)
			end, "unknown option")
			sert.throws(function()
				conformance("bad target", function() end, { target = "server" } :: any)
			end, "target must be")
			sert.throws(function()
				conformance("bad container", function() end, { container = "ReplicatedStorage" } :: any)
			end, "container must be")
		end
	)
end)

conformance(
	"3D spatial raycast, rotated OBB SAT, and Shapecast conformance",
	function(root: Instance, ctx: ConformanceContext)
		local box: any = ctx.Instance.new("Part")
		box.Size = ctx.Vector3.new(4, 2, 4)
		box.CFrame = ctx.CFrame.new(0, 5, 0) * ctx.CFrame.Angles(0, math.rad(45), 0)
		box.Anchored = true
		box.Parent = root

		local params: any = ctx.RaycastParams.new()
		params.FilterType = ctx.Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { box }

		local hit = ctx.workspace:Raycast(ctx.Vector3.new(0, 10, 0), ctx.Vector3.new(0, -10, 0), params)
		sert.ok(hit ~= nil)
		sert.eq(hit.Instance, box)
		sert.near(hit.Distance, 4, 1e-3)
		sert.near(hit.Normal, ctx.Vector3.new(0, 1, 0), 1e-3)

		local probe: any = ctx.Instance.new("Part")
		probe.Size = ctx.Vector3.new(2, 2, 2)
		probe.CFrame = ctx.CFrame.new(0, 12, 0)
		probe.Parent = root

		local sweep = ctx.workspace:Shapecast(probe, ctx.Vector3.new(0, -10, 0), params)
		sert.ok(sweep ~= nil)
		sert.eq(sweep.Instance, box)
		sert.near(sweep.Distance, 5, 1e-2)
		sert.near(sweep.Normal, ctx.Vector3.new(0, 1, 0), 1e-2)
	end
)

local guiConformanceOpts: ConformanceOptions = { target = "client", container = "PlayerGui" }
conformance("PlayerGui UIPageLayout and RichText layout conformance", function(root: Instance, ctx: ConformanceContext)
	local host: any = ctx.Instance.new("Frame")
	host.Size = ctx.UDim2.fromOffset(300, 180)
	host.Parent = root

	local pages: any = ctx.Instance.new("UIPageLayout")
	pages.Padding = ctx.UDim.new(0, 12)
	pages.Parent = host

	local p1: any = ctx.Instance.new("TextLabel")
	p1.Name = "Page1"
	p1.Size = ctx.UDim2.fromScale(1, 1)
	p1.RichText = true
	p1.Text = "<b>Hello</b>&amp;<i>World</i><br/>Line 2"
	p1.Parent = host

	local p2: any = ctx.Instance.new("Frame")
	p2.Name = "Page2"
	p2.Size = ctx.UDim2.fromScale(1, 1)
	p2.Parent = host

	ctx.step(1 / 60)
	sert.eq(pages.CurrentPage, p1)
	sert.eq(p1.ContentText, "Hello&World\nLine 2")
	Layout.fitsParent(p1)
end, guiConformanceOpts)
