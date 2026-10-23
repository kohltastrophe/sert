--!nonstrict
--!nolint DeprecatedApi
-- sert.roblox.Layout and sert.roblox.Flicker, headless.

local sert = require("../src")

sert.test("roblox.Layout · visible, settle and clippedBounds", function()
	local e = sert.env.new()
	local Layout = sert.roblox.Layout
	local UDim2 = e.globals.UDim2
	local Vector2 = e.globals.Vector2

	local screen = e.Instance.new("ScreenGui")
	screen.Enabled = true
	local container = e.Instance.new("Frame", screen)
	container.Name = "Container"
	container.Position = UDim2.fromOffset(10, 20)
	container.Size = UDim2.fromOffset(100, 80)
	container.ClipsDescendants = true

	local child = e.Instance.new("Frame", container)
	child.Name = "Child"
	child.Position = UDim2.fromOffset(50, 40)
	child.Size = UDim2.fromOffset(100, 100)

	sert.eq(Layout.visible(child), true)
	container.Visible = false
	sert.eq(Layout.visible(child), false)
	container.Visible = true
	screen.Enabled = false
	sert.eq(Layout.visible(child), false)
	screen.Enabled = true

	local low, high = Layout.clippedBounds(child)
	sert.eq(low, Vector2.new(60, 60)) -- the child sits at (10, 20) + (50, 40) inside its container
	sert.eq(high, Vector2.new(110, 100))

	local settled, why = Layout.settle(screen, {
		lead = 1,
		stable = 2,
		step = function() end,
	})
	sert.eq(settled, true)
	sert.eq(why, nil)

	local frameCount = 0
	local movingSettled, movingWhy = Layout.settle(screen, {
		lead = 0,
		stable = 2,
		maxFrames = 3,
		step = function()
			frameCount += 1
			child.Position = UDim2.fromOffset(50 + frameCount * 10, 40)
		end,
	})
	sert.eq(movingSettled, false)
	sert.contains(movingWhy, "Child")

	-- headless, the default step is one step() of the active env
	local start = e.now
	sert.eq(Layout.settle(screen, { lead = 1, stable = 2 }), true)
	sert(e.now > start, "the env's clock moved")
end)

sert.test("roblox.Layout · settle over several roots, a filter, a TextLabel and appearing children", function()
	local Layout = sert.roblox.Layout
	local e = sert.env.new()
	local UDim2 = e.globals.UDim2

	local sg = e.Instance.new("ScreenGui", e.game)
	sg.Enabled = true
	local root1 = e.Instance.new("Frame", sg)
	root1.Name = "Root1"
	local lbl = e.Instance.new("TextLabel", root1)
	lbl.Name = "Title"
	lbl.Text = "Header"
	local ignored = e.Instance.new("Frame", root1)
	ignored.Name = "Ignored"
	local root2 = e.Instance.new("Frame", sg)
	root2.Name = "Root2"

	local multiOk, multiWhy = Layout.settle({ root1, root2 }, {
		lead = 1,
		stable = 2,
		filter = function(node) return node.Name ~= "Ignored" end,
		step = function() ignored.Position = UDim2.fromOffset(math.random(1, 100), 0) end,
	})
	sert.eq(multiOk, true)
	sert.eq(multiWhy, nil)

	-- Child appearing between frames triggers before == nil branch
	local lateChild = e.Instance.new("Frame", root2)
	lateChild.Name = "LateChild"
	lateChild.Visible = false
	local appearStep = 0
	local appearOk, appearWhy = Layout.settle(root2, {
		lead = 0,
		stable = 2,
		maxFrames = 1,
		step = function()
			appearStep += 1
			if appearStep == 1 then lateChild.Visible = true end
		end,
	})
	sert.eq(appearOk, false)
	sert.contains(appearWhy, "LateChild")
end)

sert.test("roblox.Flicker & Layout · mid-recording blink detection and stopAt visibility", function()
	local Flicker = sert.roblox.Flicker
	local Layout = sert.roblox.Layout
	local e = sert.env.new()

	-- Flicker.judge rejects a sample sequence that blinks hidden after first appearing
	local blinked = Flicker.judge({
		samples = {
			{ frame = 1, shown = true, x = 10, y = 10, width = 50, height = 20 },
			{ frame = 2, shown = false, x = 10, y = 10, width = 50, height = 20 },
			{ frame = 3, shown = true, x = 10, y = 10, width = 50, height = 20 },
			{ frame = 4, shown = true, x = 10, y = 10, width = 50, height = 20 },
		},
		steady = true,
		ok = true,
		motion = 0,
	})
	sert.eq(blinked.ok, false)
	sert.eq(blinked.problem, "blinks hidden at frame 2")

	-- Layout.visible checks stopAt itself (e.g. disabled ScreenGui or hidden root Frame)
	local disabledScreen = e.Instance.new("ScreenGui")
	disabledScreen.Enabled = false
	local inner = e.Instance.new("Frame", disabledScreen)
	inner.Name = "Inner"
	inner.Visible = true
	sert.eq(Layout.visible(inner, disabledScreen), false)

	local hiddenRoot = e.Instance.new("Frame")
	hiddenRoot.Name = "HiddenRoot"
	hiddenRoot.Visible = false
	local sub = e.Instance.new("Frame", hiddenRoot)
	sub.Name = "Sub"
	sub.Visible = true
	sert.eq(Layout.visible(sub, hiddenRoot), false)
	sert.eq(Layout.visible(hiddenRoot, hiddenRoot), false)
	sert.eq(Layout.visible(sub, sub), true)
	local subInDisabled = e.Instance.new("Frame", disabledScreen)
	subInDisabled.Visible = true
	sert.eq(Layout.visible(subInDisabled, subInDisabled), true)

	-- Layout.settle reports GetFullName() when a visible descendant disappears
	local liveRoot = e.Instance.new("Frame")
	liveRoot.Name = "LiveRoot"
	local vanishing = e.Instance.new("Frame", liveRoot)
	vanishing.Name = "Vanishing"
	local stepCount = 0
	local ok, changed = Layout.settle(liveRoot, {
		lead = 0,
		stable = 2,
		maxFrames = 1,
		step = function()
			stepCount += 1
			if stepCount == 1 then vanishing.Visible = false end
		end,
	})
	sert.eq(ok, false)
	sert.eq(changed, "LiveRoot.Vanishing")
end)

sert.test("roblox.Flicker · visible follows ancestors, ScreenGui.Enabled and parenting", function()
	local Flicker = sert.roblox.Flicker
	local e = sert.env.new()

	local sg = e.Instance.new("ScreenGui", e.game)
	sg.Enabled = true
	local parentFrame = e.Instance.new("Frame", sg)
	local childFrame = e.Instance.new("Frame", parentFrame)
	sert.eq(Flicker.visible(childFrame), true)

	parentFrame.Visible = false
	sert.eq(Flicker.visible(childFrame), false)
	parentFrame.Visible = true

	sg.Enabled = false
	sert.eq(Flicker.visible(childFrame), false)
	sg.Enabled = true

	local orphan = e.Instance.new("Frame")
	sert.eq(Flicker.visible(orphan), false)
end)

sert.test("roblox.Flicker · judge branches, describe truncation and expect", function()
	local Flicker = sert.roblox.Flicker

	local neverVis = Flicker.judge({
		samples = { { frame = 1, shown = false, x = 0, y = 0, width = 10, height = 10 } },
		steady = false,
		ok = true,
		motion = 0,
	})
	sert.eq(neverVis.ok, false)
	sert.eq(neverVis.problem, "never visible")

	local unsteady = Flicker.judge({
		samples = { { frame = 1, shown = true, x = 10, y = 10, width = 50, height = 20 } },
		steady = false,
		ok = true,
		motion = 0,
	})
	sert.eq(unsteady.ok, false)
	sert.contains(unsteady.problem, "never held still")

	local diffSize = Flicker.judge({
		samples = {
			{ frame = 1, shown = true, x = 10, y = 10, width = 30, height = 20 },
			{ frame = 2, shown = true, x = 10, y = 10, width = 50, height = 20 },
		},
		steady = true,
		ok = true,
		motion = 0,
	})
	sert.eq(diffSize.ok, false)
	sert.contains(diffSize.problem, "has another size")

	local resizeAllowed = Flicker.judge({
		samples = {
			{ frame = 1, shown = true, x = 10, y = 10, width = 30, height = 20 },
			{ frame = 2, shown = true, x = 10, y = 10, width = 50, height = 20 },
		},
		steady = true,
		ok = true,
		motion = 0,
	}, { positionOnly = true })
	sert.eq(resizeAllowed.ok, true)

	local resizedSlice = Flicker.judge({
		samples = {
			{ frame = 1, shown = true, x = 99, y = 99, width = 20, height = 20 },
			{ frame = 2, shown = true, x = 10, y = 10, width = 50, height = 20 },
			{ frame = 3, shown = true, x = 10, y = 10, width = 50, height = 20 },
		},
		steady = true,
		ok = true,
		motion = 0,
	}, { fromSettledSize = true })
	sert.eq(resizedSlice.ok, true)

	local tooFar = Flicker.judge({
		samples = {
			{ frame = 1, shown = true, x = 50, y = 10, width = 50, height = 20 },
			{ frame = 2, shown = true, x = 10, y = 10, width = 50, height = 20 },
		},
		steady = true,
		ok = true,
		motion = 10,
	}, { motion = 10 })
	sert.eq(tooFar.ok, false)
	sert.contains(tooFar.problem, "is 40 px from its place")

	local smoothMotion = Flicker.judge({
		samples = {
			{ frame = 1, shown = true, x = 30, y = 10, width = 50, height = 20 },
			{ frame = 2, shown = true, x = 20, y = 10, width = 50, height = 20 },
			{ frame = 3, shown = true, x = 10, y = 10, width = 50, height = 20 },
		},
		steady = true,
		ok = true,
		motion = 25,
	}, { motion = 25 })
	sert.eq(smoothMotion.ok, true)
	sert.eq(smoothMotion.first, smoothMotion.samples[1])
	sert.eq(smoothMotion.settled, smoothMotion.samples[3])

	local offLine = Flicker.judge({
		samples = {
			{ frame = 1, shown = true, x = 30, y = 10, width = 50, height = 20 },
			{ frame = 2, shown = true, x = 10, y = 25, width = 50, height = 20 },
			{ frame = 3, shown = true, x = 10, y = 10, width = 50, height = 20 },
		},
		steady = true,
		ok = true,
		motion = 30,
	}, { motion = 30 })
	sert.eq(offLine.ok, false)
	sert.contains(offLine.problem, "moves off its motion's line")

	local jumpsAfterInPlace = Flicker.judge({
		samples = {
			{ frame = 1, shown = true, x = 10, y = 10, width = 50, height = 20 },
			{ frame = 2, shown = true, x = 25, y = 10, width = 50, height = 20 },
			{ frame = 3, shown = true, x = 10, y = 10, width = 50, height = 20 },
		},
		steady = true,
		ok = true,
		motion = 30,
	}, { motion = 30 })
	sert.eq(jumpsAfterInPlace.ok, false)
	sert.contains(jumpsAfterInPlace.problem, "jumps after it was in place")

	local movesAway = Flicker.judge({
		samples = {
			{ frame = 1, shown = true, x = 20, y = 10, width = 50, height = 20 },
			{ frame = 2, shown = true, x = 30, y = 10, width = 50, height = 20 },
			{ frame = 3, shown = true, x = 10, y = 10, width = 50, height = 20 },
		},
		steady = true,
		ok = true,
		motion = 30,
	}, { motion = 30 })
	sert.eq(movesAway.ok, false)
	sert.contains(movesAway.problem, "moves away")

	local maxStepOk = Flicker.judge({
		samples = {
			{ frame = 1, shown = true, x = 40, y = 10, width = 50, height = 20 },
			{ frame = 2, shown = true, x = 25, y = 10, width = 50, height = 20 },
			{ frame = 3, shown = true, x = 10, y = 10, width = 50, height = 20 },
		},
		steady = true,
		ok = true,
		motion = 0,
	}, { maxStep = 16 })
	sert.eq(maxStepOk.ok, true)

	local maxStepFail = Flicker.judge({
		samples = {
			{ frame = 1, shown = true, x = 40, y = 10, width = 50, height = 20 },
			{ frame = 2, shown = true, x = 10, y = 10, width = 50, height = 20 },
		},
		steady = true,
		ok = true,
		motion = 0,
	}, { maxStep = 10 })
	sert.eq(maxStepFail.ok, false)
	sert.contains(maxStepFail.problem, "jumps 30 px in one frame")

	-- Flicker.describe (>= 24 visible samples truncates with "  …") and Flicker.expect
	local samples23 = {}
	for i = 1, 23 do
		table.insert(samples23, { frame = i, shown = true, x = 10, y = 10, width = 50, height = 20 })
	end
	local desc23 = Flicker.describe({
		label = "s23",
		samples = samples23,
		steady = true,
		ok = true,
		motion = 0,
	})
	sert.contains(desc23, "  f23 ")
	sert.eq(string.find(desc23, "  …", 1, true), nil)

	local samples24 = table.clone(samples23)
	table.insert(samples24, { frame = 24, shown = true, x = 10, y = 10, width = 50, height = 20 })
	local desc24 = Flicker.describe({
		label = "s24",
		samples = samples24,
		steady = true,
		ok = true,
		motion = 0,
	})
	sert.contains(desc24, "  f24 ")
	sert.contains(desc24, "  …")

	local manySamples = {
		{ frame = 1, shown = false, x = 0, y = 0, width = 0, height = 0 },
	}
	for i = 2, 30 do
		table.insert(manySamples, { frame = i, shown = true, x = 10, y = 10, width = 50, height = 20 })
	end
	local desc = Flicker.describe({
		label = "many",
		samples = manySamples,
		steady = true,
		ok = true,
		motion = 0,
	})
	sert.contains(desc, "(1 hidden frames first)")
	sert.contains(desc, "  f25 ")
	sert.eq(string.find(desc, "  f26 ", 1, true), nil)
	sert.contains(desc, "  …")

	Flicker.expect(smoothMotion, "smoothDialog")
	sert.fails(function() Flicker.expect(tooFar, "badDialog") end, "badDialog")
end)

sert.test("roblox.Flicker · drive, record and around", function()
	local Flicker = sert.roblox.Flicker
	local e = sert.env.new()
	local UDim2 = e.globals.UDim2

	local sg = e.Instance.new("ScreenGui", e.game)
	sg.Enabled = true
	local parentFrame = e.Instance.new("Frame", sg)
	local childFrame = e.Instance.new("Frame", parentFrame)
	local rs = e.game:GetService("RunService")
	-- Give PreRender and PreAnimation distinct signals so order is controlled
	local preRenderSig = e:signal()
	local preAnimSig = e:signal()
	rs._props.PreRender = preRenderSig
	rs._props.PreAnimation = preAnimSig

	Flicker.drive(function()
		preRenderSig:Fire(1 / 60)
		preAnimSig:Fire(1 / 60)
	end)
	sert.defer(function() Flicker.drive(nil) end)

	-- PreAnimation when frame == 0 is ignored; also test recorder.stop() and recorder.samples
	local earlyRec = Flicker.record(function() error("finder error handled") end, { runService = rs, stable = 2 })
	sert.eq(#earlyRec.samples, 0)
	preAnimSig:Fire(1 / 60) -- frame == 0
	sert.eq(#earlyRec.samples, 0)
	preRenderSig:Fire(1 / 60)
	preAnimSig:Fire(1 / 60) -- frame == 1, target errors -> hidden sample
	sert.eq(#earlyRec.samples, 1)
	earlyRec.stop()
	earlyRec.stop()
	-- Firing after stop() must not record more samples because connections were disconnected
	preRenderSig:Fire(1 / 60)
	preAnimSig:Fire(1 / 60)
	sert.eq(#earlyRec.samples, 1)
	local earlyRes = earlyRec.result()
	sert.eq(earlyRes.ok, false)
	sert.eq(#earlyRes.samples, 1)
	sert.eq(earlyRec.samples, earlyRes.samples)

	-- Flicker.around without opts.shown (opts.shown == nil)
	local defaultShownRes = Flicker.around(function() return childFrame end, function() end, {
		runService = rs,
		stable = 2,
	})
	sert.eq(defaultShownRes.ok, true)
	sert.eq(defaultShownRes.steady, true)
	local preConns = preRenderSig:connections()
	sert.fails(function()
		Flicker.around(function() return childFrame end, function() error("open boom") end, {
			runService = rs,
			stable = 2,
		})
	end, "open boom")
	sert.eq(preRenderSig:connections(), preConns)

	-- Flicker.around with shown callback returning false on frame 1 then true on later frames, plus busy callback
	local busyCalls = 0
	local shownChecks = 0
	childFrame.BackgroundTransparency = 1
	local aroundRes = Flicker.around(function() return childFrame end, function() end, {
		runService = rs,
		stable = 2,
		shown = function(obj)
			shownChecks += 1
			if shownChecks == 1 then
				obj.BackgroundTransparency = 0
				return false
			end
			return obj.BackgroundTransparency < 1
		end,
		busy = function()
			busyCalls += 1
			return busyCalls <= 2
		end,
	})
	sert.eq(aroundRes.samples[1].shown, false)
	sert.eq(aroundRes.samples[2].shown, true)
	sert.eq(aroundRes.ok, true)
	sert.eq(aroundRes.steady, true)

	-- sameRect positionOnly (true vs false) when size changes every frame while position stays fixed
	local growFrameA = 0
	childFrame.Position = UDim2.fromOffset(10, 10)
	local resizeSteadyRes = Flicker.around(function()
		growFrameA += 1
		childFrame.Size = UDim2.fromOffset(20 + growFrameA * 10, 20)
		return childFrame
	end, function() end, {
		runService = rs,
		stable = 2,
		timeout = 0.05,
		positionOnly = true,
	})
	sert.eq(resizeSteadyRes.steady, true)
	sert.eq(resizeSteadyRes.ok, true)

	local growFrameB = 0
	local noResizeUnsteadyRes = Flicker.around(function()
		growFrameB += 1
		childFrame.Size = UDim2.fromOffset(20 + growFrameB * 10, 20)
		return childFrame
	end, function() end, {
		runService = rs,
		stable = 2,
		timeout = 0.05,
		positionOnly = false,
	})
	sert.eq(noResizeUnsteadyRes.steady, false)
	sert.eq(noResizeUnsteadyRes.ok, false)
end)

sert.test("roblox.Flicker · record outside Roblox needs a RunService", function()
	sert.fails(function()
		sert.roblox.Flicker.record(function() return nil end)
	end, "Flicker.record: no RunService outside Roblox; pass options.runService")
end)

return {}
