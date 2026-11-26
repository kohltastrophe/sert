--!strict
-- Isolated headless Roblox environments (`sert.env.new()`): strict/deferred defaults, Instance fidelity,
-- scheduler/RunService frame order, per-world UI layout & input, and remote boundary serialization.

local sert = require("../src")

local describe = sert.describe
local test = sert.test

describe("sert.env.new() defaults: strict mode & Deferred signals", function()
	test(
		"defaults strict = true, rejecting unknown/read-only properties while allowing attributes and strict = false opt-out",
		function()
			local e = sert.env.new()
			sert.eq(e.strict, true)
			sert.eq(e.signalBehavior, "Deferred")

			local frame = e.Instance.new("Frame")
			local part = e.Instance.new("Part")

			sert.throws(function() local _ = (frame :: any).NonExistentProp end, "not a valid member")
			sert.throws(function() (frame :: any).NonExistentProp = 123 end, "not a valid member")
			sert.throws(function() local _ = (part :: any).BogusField end, "not a valid member")
			sert.throws(function() (part :: any).BogusField = true end, "not a valid member")
			sert.throws(function() (frame :: any).AbsoluteSize = e.Vector2.new(10, 10) end, "read only")

			frame:SetAttribute("Theme", "Midnight")
			part:SetAttribute("Damage", 42)
			sert.eq(frame:GetAttribute("Theme"), "Midnight")
			sert.eq(part:GetAttribute("Damage"), 42)

			local lenient = sert.env.new({ strict = false })
			sert.eq(lenient.strict, false)
			local lf = lenient.Instance.new("Frame");
			(lf :: any).CustomAdHoc = "allowed"
			sert.eq((lf :: any).CustomAdHoc, "allowed")
		end
	)

	test("queues Deferred signals by default, re-checks Connected on drain, and supports Immediate opt-in", function()
		local e = sert.env.new()
		local sig = e:signal()
		local log: { string } = {}

		local connB: any = nil
		sig:Connect(function(tag: string)
			table.insert(log, "A:" .. tag)
			if connB ~= nil then connB:Disconnect() end
		end)
		connB = sig:Connect(function(tag: string) table.insert(log, "B:" .. tag) end)

		sig:Fire("tick")
		-- Deferred: neither listener has run synchronously before flush/step
		sert.eq(log, {})
		e:flush()
		-- Listener A disconnected connB before connB drained, so connB MUST NOT fire
		sert.eq(log, { "A:tick" })

		local imm = sert.env.new({ signalBehavior = "Immediate" })
		sert.eq(imm.signalBehavior, "Immediate")
		local immSig = imm:signal()
		local immLog: { string } = {}
		immSig:Connect(function(v: string) table.insert(immLog, v) end)
		immSig:Fire("sync")
		sert.eq(immLog, { "sync" })
	end)
end)

describe("Instance fidelity, WaitForChild, Destroy, Clone, queries, and lexical require", function()
	test("fires 0-arg property/attribute signals while Changed passes property name", function()
		local e = sert.env.new({ signalBehavior = "Immediate" })
		local part = e.Instance.new("Part")

		local propArity = -1
		local attrArity = -1
		local changedArgs: { any } = {}

		part:GetPropertyChangedSignal("Name"):Connect(function(...) propArity = select("#", ...) end)
		part:GetAttributeChangedSignal("Foo"):Connect(function(...) attrArity = select("#", ...) end)
		part.Changed:Connect(function(...) changedArgs = { ... } end)

		part.Name = "Renamed"
		part:SetAttribute("Foo", 99)

		sert.eq(propArity, 0)
		sert.eq(attrArity, 0)
		sert.eq(changedArgs, { "Name" })
	end)

	test("yields in WaitForChild, returns nil on timeout, and warns after 5s when timeout is omitted", function()
		local e = sert.env.new()
		local folder = e.Instance.new("Folder", e.workspace)
		folder.Name = "Container"

		-- Resumes automatically when child is parented later
		e.task.delay(0.2, function()
			local child = e.Instance.new("Part")
			child.Name = "Later"
			child.Parent = folder
		end)
		local resolved = folder:WaitForChild("Later")
		sert.eq(resolved.Name, "Later")
		sert.near(e.now, 0.2, 0.05)

		-- Returns nil after explicit timeout
		local t0 = e.now
		local missing = folder:WaitForChild("Missing", 0.5)
		sert.eq(missing, nil)
		sert.near(e.now - t0, 0.5, 0.05)

		-- Emits 5s infinite-yield warning when timeout is omitted, then still resolves on late parenting
		local warnings: { string } = {}
		local logSvc = e:getService("LogService")
		logSvc.MessageOut:Connect(function(msg: string, msgType: any)
			if msgType == e.Enum.MessageType.MessageWarning then table.insert(warnings, msg) end
		end)

		local eventual: any = nil
		e.task.spawn(function() eventual = folder:WaitForChild("SlowChild") end)
		e:advance(5.1)
		sert.eq(#warnings, 1)
		sert.matches(warnings[1], "Infinite yield possible")
		sert.eq(eventual, nil)

		local slow = e.Instance.new("Part")
		slow.Name = "SlowChild"
		slow.Parent = folder
		e:flush()
		sert.eq(eventual, slow)
	end)

	test("Destroy disconnects all connections cleanly, locks Parent, and tolerates re-Destroy", function()
		local e = sert.env.new({ signalBehavior = "Immediate" })
		local root = e.Instance.new("Folder", e.workspace)
		local child = e.Instance.new("Part", root)
		local hits = 0
		local conn = child:GetPropertyChangedSignal("Name"):Connect(function()
			hits += 1
		end)

		child.Name = "Before"
		sert.eq(hits, 1)
		sert.eq(conn.Connected, true)

		root:Destroy()
		sert.eq(conn.Connected, false)
		sert.eq(root.Parent, nil)
		sert.eq(child.Parent, nil)

		-- Re-Destroy is a clean no-op and never throws locked-parent errors
		sert.doesNotThrow(function()
			root:Destroy()
			child:Destroy()
		end)

		-- Reparenting a destroyed instance throws
		sert.throws(function() child.Parent = e.workspace end, "locked")

		-- Services cannot be destroyed
		sert.throws(function() e.workspace:Destroy() end)
	end)

	test("Clone, hierarchy queries, QueryDescendants, and lexical function(_ENV) require work end-to-end", function()
		local e = sert.env.new()
		local model = e.Instance.new("Model", e.workspace)
		model.Name = "Hero"
		model:SetAttribute("Tier", 3)
		model:AddTag("Actor")

		local head = e.Instance.new("Part", model)
		head.Name = "Head"
		head:AddTag("Target")
		head:SetAttribute("Slot", "Head")

		local transient = e.Instance.new("Part", model)
		transient.Name = "Transient"
		transient.Archivable = false

		local copy = model:Clone()
		sert.ok(copy ~= nil and copy ~= model)
		sert.eq(copy.Parent, nil)
		sert.eq(copy:GetAttribute("Tier"), 3)
		sert.eq(copy:HasTag("Actor"), true)
		sert.ok(copy:FindFirstChild("Head") ~= nil and copy:FindFirstChild("Head") ~= head)
		sert.eq(copy:FindFirstChild("Transient"), nil)

		model.Archivable = false
		sert.eq(model:Clone(), nil)
		model.Archivable = true

		-- Hierarchy lookups & QueryDescendants
		sert.eq(e.workspace:FindFirstChild("Head", true), head)
		sert.eq(head:FindFirstAncestor("Hero"), model)
		sert.eq(head:FindFirstAncestorOfClass("Model"), model)
		sert.eq(head:IsDescendantOf(e.workspace), true)
		sert.eq(e.workspace:QueryDescendants('Model#Hero > Part.Target[$Slot = "Head"][Archivable = true]'), { head })

		-- Lexical function(_ENV) module staging & require
		local stage = {
			root = {
				name = "Pkg",
				className = "ModuleScript",
				file = "init.luau",
				children = {
					Math = { name = "Math", className = "ModuleScript", file = "Math.luau", children = {} },
				},
			},
			files = {
				["init.luau"] = function()
					return function(_ENV: any)
						local m = _ENV.require("@self/Math")
						return { doubled = m.add(21, 21), isServer = _ENV.game:GetService("RunService"):IsServer() }
					end
				end,
				["Math.luau"] = function()
					return function(_ENV: any)
						return {
							add = function(a: number, b: number): number return a + b end,
							origin = _ENV.Vector3.zero,
						}
					end
				end,
			},
		}
		local pkg = e:mount(stage, e:getService("ReplicatedStorage"))
		sert.eq(e:require(pkg), { doubled = 42, isServer = true })
	end)
end)

describe("Scheduler, task library & RunService frame pipeline", function()
	test(
		"integrates task.spawn, task.defer, task.delay, task.cancel, task.wait, and sert.waitFor with env:step",
		function()
			local e = sert.env.new({ dt = 0.05 })
			local events: { string } = {}

			e.task.spawn(function(tag: string)
				table.insert(events, tag .. ":spawn")
				local dt = e.task.wait(0.1)
				sert.near(dt, 0.1, 1e-4)
				table.insert(events, tag .. ":woke")
			end, "worker")

			e.task.defer(function() table.insert(events, "deferred") end)

			local cancelled = false
			local handle = e.task.delay(0.1, function() cancelled = true end)
			e.task.cancel(handle)

			local ready = false
			e.task.delay(0.15, function()
				table.insert(events, "delayed")
				ready = true
			end)

			-- task.spawn runs eagerly up to its first yield; task.defer waits for queue drain.
			sert.eq(events, { "worker:spawn" })
			e:step(0.05)
			sert.eq(events, { "worker:spawn", "deferred" })
			e:step(0.05)
			sert.eq(events, { "worker:spawn", "deferred", "worker:woke" })
			sert.eq(cancelled, false)

			-- sert.waitFor drives active env yield driver automatically until predicate turns truthy.
			sert.waitFor(function() return ready end, 1.0, 0.05)
			sert.eq(ready, true)
			sert.eq(events, { "worker:spawn", "deferred", "worker:woke", "delayed" })
		end
	)

	test(
		"fires BindToRenderStep, PreRender, RenderStepped, PreAnimation, PreSimulation, Stepped(elapsed, dt), PostSimulation, and Heartbeat in engine order and isolates yielding BindToRenderStep callbacks",
		function()
			local e = sert.env.new({ isClient = true, isServer = false, dt = 0.025 })
			local rs = e:getService("RunService")
			local order: { string } = {}
			local steppedElapsed = -1
			local steppedDt = -1
			local heartbeatDt = -1

			rs:BindToRenderStep("YieldPass", 50, function(_dt: number)
				table.insert(order, "YieldPass:start")
				e.task.wait(0.1)
				table.insert(order, "YieldPass:end")
			end)
			rs:BindToRenderStep(
				"CamPass",
				100,
				function(dt: number) table.insert(order, string.format("BindToRenderStep:%.3f", dt)) end
			)
			rs.PreRender:Connect(function(dt: number) table.insert(order, string.format("PreRender:%.3f", dt)) end)
			rs.RenderStepped:Connect(
				function(dt: number) table.insert(order, string.format("RenderStepped:%.3f", dt)) end
			)
			rs.PreAnimation:Connect(
				function(dt: number) table.insert(order, string.format("PreAnimation:%.3f", dt)) end
			)
			rs.PreSimulation:Connect(
				function(dt: number) table.insert(order, string.format("PreSimulation:%.3f", dt)) end
			)
			rs.Stepped:Connect(function(elapsed: number, dt: number)
				steppedElapsed = elapsed
				steppedDt = dt
				table.insert(order, "Stepped")
			end)
			rs.PostSimulation:Connect(
				function(dt: number) table.insert(order, string.format("PostSimulation:%.3f", dt)) end
			)
			rs.Heartbeat:Connect(function(dt: number)
				heartbeatDt = dt
				table.insert(order, "Heartbeat")
			end)

			e:step(0.025)
			-- Engine phase order: BindToRenderStep -> PreRender -> RenderStepped -> PreAnimation -> PreSimulation -> Stepped -> PostSimulation -> Heartbeat
			sert.eq(order, {
				"YieldPass:start",
				"BindToRenderStep:0.025",
				"PreRender:0.025",
				"RenderStepped:0.025",
				"PreAnimation:0.025",
				"PreSimulation:0.025",
				"Stepped",
				"PostSimulation:0.025",
				"Heartbeat",
			})
			sert.near(steppedElapsed, 0.025, 1e-6)
			sert.near(steppedDt, 0.025, 1e-6)
			sert.near(heartbeatDt, 0.025, 1e-6)

			rs:UnbindFromRenderStep("YieldPass")
			rs:UnbindFromRenderStep("CamPass")
			table.clear(order)
			e:step(0.025)
			sert.eq(order[1], "PreRender:0.025")
			sert.near(steppedElapsed, 0.050, 1e-6)
		end
	)
end)

describe("Per-world UI layout isolation, constraints & input driver", function()
	test("isolates layout dirtiness per env and computes List/Grid/Padding/Size/Aspect/Flex layouts", function()
		local e1 = sert.env.new({ isClient = true, isServer = false })
		local e2 = sert.env.new({ isClient = true, isServer = false })

		local sg1 = e1.Instance.new("ScreenGui")
		sg1.Parent = e1:getService("Players").LocalPlayer.PlayerGui
		local box1 = e1.Instance.new("Frame")
		box1.Size = e1.UDim2.fromOffset(300, 200)
		box1.Parent = sg1

		local sg2 = e2.Instance.new("ScreenGui")
		sg2.Parent = e2:getService("Players").LocalPlayer.PlayerGui
		local box2 = e2.Instance.new("Frame")
		box2.Size = e2.UDim2.fromOffset(500, 400)
		box2.Parent = sg2

		-- Reading geometry in e1 flushes only e1's layout state without touching e2's dirty queue.
		sert.eq(box1.AbsoluteSize, e1.Vector2.new(300, 200))
		local ls2: any = rawget(e2 :: any, "_layoutState")
		sert.ok(ls2 ~= nil and #ls2.dirtyOrder > 0)
		sert.eq(box2.AbsoluteSize, e2.Vector2.new(500, 400))
		sert.eq(#ls2.dirtyOrder, 0)

		-- UIPadding + UIListLayout + UIFlexItem (Grow & Shrink)
		local pad = e1.Instance.new("UIPadding")
		pad.PaddingLeft = e1.UDim.new(0, 10)
		pad.PaddingRight = e1.UDim.new(0, 10)
		pad.PaddingTop = e1.UDim.new(0, 5)
		pad.PaddingBottom = e1.UDim.new(0, 5)
		pad.Parent = box1

		local list = e1.Instance.new("UIListLayout")
		list.FillDirection = e1.Enum.FillDirection.Horizontal
		list.Padding = e1.UDim.new(0, 10)
		list.Parent = box1

		local c1 = e1.Instance.new("Frame")
		c1.LayoutOrder = 1
		c1.Size = e1.UDim2.fromOffset(50, 40)
		local flex1 = e1.Instance.new("UIFlexItem")
		flex1.FlexMode = e1.Enum.UIFlexMode.Grow
		flex1.Parent = c1
		c1.Parent = box1

		local c2 = e1.Instance.new("Frame")
		c2.LayoutOrder = 2
		c2.Size = e1.UDim2.fromOffset(50, 40)
		local flex2 = e1.Instance.new("UIFlexItem")
		flex2.FlexMode = e1.Enum.UIFlexMode.Grow
		flex2.Parent = c2
		c2.Parent = box1

		-- Inner width = 300 - 20 = 280; fixed + gap = 50 + 50 + 10 = 110; Grow mode splits remaining 170 1:1 (135 each).
		sert.near(c1.AbsoluteSize.X, 135, 1e-3)
		sert.near(c2.AbsoluteSize.X, 135, 1e-3)

		-- Custom mode honors GrowRatio 1:2!
		flex1.FlexMode = e1.Enum.UIFlexMode.Custom
		flex1.GrowRatio = 1
		flex2.FlexMode = e1.Enum.UIFlexMode.Custom
		flex2.GrowRatio = 2
		sert.near(c1.AbsoluteSize.X, 50 + 170 / 3, 1e-3)
		sert.near(c2.AbsoluteSize.X, 50 + 340 / 3, 1e-3)
		sert.near(c1.AbsolutePosition.X, 10, 1e-3)
		sert.near(c2.AbsolutePosition.X, 10 + c1.AbsoluteSize.X + 10, 1e-3)

		-- Shrink when base widths exceed available space (200 + 200 + 10 = 410 > 280 => 130 deficit)
		c1.Size = e1.UDim2.fromOffset(200, 40)
		c2.Size = e1.UDim2.fromOffset(200, 40)
		flex1.FlexMode = e1.Enum.UIFlexMode.Shrink
		flex1.ShrinkRatio = 1
		flex2.FlexMode = e1.Enum.UIFlexMode.Shrink
		flex2.ShrinkRatio = 1
		sert.near(c1.AbsoluteSize.X, 135, 1e-3)
		sert.near(c2.AbsoluteSize.X, 135, 1e-3)

		-- UIGridLayout + UISizeConstraint + UIAspectRatioConstraint (DominantAxis & AspectType)
		local gridHost = e2.Instance.new("Frame")
		gridHost.Size = e2.UDim2.fromOffset(220, 200)
		gridHost.Parent = sg2
		local grid = e2.Instance.new("UIGridLayout")
		grid.CellSize = e2.UDim2.fromOffset(60, 40)
		grid.CellPadding = e2.UDim2.fromOffset(10, 5)
		grid.Parent = gridHost
		for i = 1, 4 do
			local cell = e2.Instance.new("Frame")
			cell.LayoutOrder = i
			cell.Parent = gridHost
		end
		local cells = gridHost:GetChildren()
		-- 3 columns fit per row (60 + 10 + 60 + 10 + 60 = 200 <= 220), 4th wraps to row 2
		local fourth = cells[5]
		sert.eq(fourth.AbsolutePosition, e2.Vector2.new(0, 45))

		local constrained = e2.Instance.new("Frame")
		constrained.Size = e2.UDim2.fromOffset(400, 300)
		constrained.Parent = sg2
		local sc = e2.Instance.new("UISizeConstraint")
		sc.MaxSize = e2.Vector2.new(200, 180)
		sc.MinSize = e2.Vector2.new(80, 50)
		sc.Parent = constrained
		sert.eq(constrained.AbsoluteSize, e2.Vector2.new(200, 180))

		local ar = e2.Instance.new("UIAspectRatioConstraint")
		ar.AspectRatio = 2.0
		ar.AspectType = e2.Enum.AspectType.ScaleWithParentSize
		ar.DominantAxis = e2.Enum.DominantAxis.Height
		ar.Parent = constrained
		-- Height = 180 -> Width = 360, then clamped or scaled by aspect; with ScaleWithParentSize & DominantAxis.Height:
		sert.near(constrained.AbsoluteSize.X / constrained.AbsoluteSize.Y, 2.0, 1e-3)

		ar.AspectType = e2.Enum.AspectType.FitWithinMaxSize
		-- Max box 200x180 with ratio 2:1 fits at 200x100
		sert.near(constrained.AbsoluteSize.X, 200, 1e-3)
		sert.near(constrained.AbsoluteSize.Y, 100, 1e-3)
	end)

	test(
		"drives ScrollingFrame CanvasPosition hit-testing and env:input() click, move, press/release, and TextBox typing",
		function()
			local e = sert.env.new({ isClient = true, isServer = false })
			local sg = e.Instance.new("ScreenGui")
			sg.Parent = e:getService("Players").LocalPlayer.PlayerGui

			local scroll = e.Instance.new("ScrollingFrame")
			scroll.Position = e.UDim2.fromOffset(20, 20)
			scroll.Size = e.UDim2.fromOffset(200, 100)
			scroll.CanvasSize = e.UDim2.fromOffset(0, 400)
			scroll.Parent = sg

			local deepBtn = e.Instance.new("TextButton")
			deepBtn.Position = e.UDim2.fromOffset(10, 250)
			deepBtn.Size = e.UDim2.fromOffset(80, 30)
			deepBtn.Parent = scroll

			local clicks = 0
			deepBtn.Activated:Connect(function()
				clicks += 1
			end)

			local inp = e:input()
			-- Before scrolling, (50, 70) is canvas Y=50, missing deepBtn at canvas Y=250..280.
			inp:click(e.Vector2.new(50, 70))
			e:flush()
			sert.eq(clicks, 0)

			-- Scrolling CanvasPosition.Y = 210 brings deepBtn to screen Y = 20 + 250 - 210 = 60..90!
			scroll.CanvasPosition = e.Vector2.new(0, 210)
			inp:move(e.Vector2.new(50, 70))
			inp:click(e.Vector2.new(50, 70))
			e:flush()
			sert.eq(clicks, 1)

			-- Keyboard press/release & TextBox typing
			local uis = e:getService("UserInputService")
			local keysDown: { any } = {}
			local keysUp: { any } = {}
			uis.InputBegan:Connect(function(io: any)
				if io.UserInputType == e.Enum.UserInputType.Keyboard then table.insert(keysDown, io.KeyCode) end
			end)
			uis.InputEnded:Connect(function(io: any)
				if io.UserInputType == e.Enum.UserInputType.Keyboard then table.insert(keysUp, io.KeyCode) end
			end)

			inp:press(e.Enum.KeyCode.LeftShift)
			sert.eq(uis:IsKeyDown(e.Enum.KeyCode.LeftShift), true)
			inp:release(e.Enum.KeyCode.LeftShift)
			sert.eq(uis:IsKeyDown(e.Enum.KeyCode.LeftShift), false)
			e:flush()
			sert.eq(keysDown, { e.Enum.KeyCode.LeftShift })
			sert.eq(keysUp, { e.Enum.KeyCode.LeftShift })

			local tb = e.Instance.new("TextBox")
			tb.Position = e.UDim2.fromOffset(250, 20)
			tb.Size = e.UDim2.fromOffset(120, 30)
			tb.Text = ""
			tb.Parent = sg

			inp:click(tb)
			inp:type("sert_010")
			e:flush()
			sert.eq(tb.Text, "sert_010")
		end
	)
end)

describe("Remote boundary serialization (serialize.remote)", function()
	test(
		"strips OOP metatables, deep-copies tables/buffers, and rejects functions/threads/mixed/cyclic payloads",
		function()
			local w = sert.sim.new({ seed = 7, instant = true })
			local srv = w:server()
			local cli = srv:client(101)
			local sEnv = srv:env()
			local cEnv = cli:env()

			local sRem = sEnv.Instance.new("RemoteEvent")
			sRem.Name = "PayloadCheck"
			sRem.Parent = sEnv:getService("ReplicatedStorage")
			w:step()

			local cRem = cEnv:getService("ReplicatedStorage"):FindFirstChild("PayloadCheck") :: any
			sert.ok(cRem ~= nil)

			local receivedOnServer: any = nil
			local receivedBuf: buffer? = nil
			sRem.OnServerEvent:Connect(function(_plr: any, payload: any, buf: buffer)
				receivedOnServer = payload
				receivedBuf = buf
			end)

			local WalletMT = {
				__index = {
					steal = function() return 999999 end,
				},
			}
			local clientObj = setmetatable({ coins = 50, nested = { items = { "sword", "shield" } } }, WalletMT)
			local clientBuf = buffer.fromstring("packet")

			cRem:FireServer(clientObj, clientBuf)
			w:step()

			-- Metatable is stripped across the VM boundary, and mutating sender state cannot alias receiver state.
			sert.ok(receivedOnServer ~= nil)
			sert.eq(getmetatable(receivedOnServer), nil)
			sert.eq((receivedOnServer :: any).steal, nil)
			sert.eq(receivedOnServer.coins, 50)
			sert.eq(receivedOnServer.nested.items, { "sword", "shield" })

			clientObj.nested.items[1] = "corrupted"
			buffer.writeu8(clientBuf, 0, string.byte("X") or 88)
			sert.eq(receivedOnServer.nested.items[1], "sword")
			sert.eq(buffer.tostring(receivedBuf :: buffer), "packet")

			-- Same sanitization applies on FireClient (Server -> Client).
			local receivedOnClient: any = nil
			cRem.OnClientEvent:Connect(function(payload: any) receivedOnClient = payload end)
			local sPlr = sEnv:getService("Players"):GetPlayers()[1]
			sRem:FireClient(sPlr, setmetatable({ tag = "server" }, WalletMT))
			w:step()
			sert.ok(receivedOnClient ~= nil)
			sert.eq(getmetatable(receivedOnClient), nil)
			sert.eq(receivedOnClient.tag, "server")

			-- Default Roblox wire sanitization truncates sparse arrays at nil holes and drops non-array keys on mixed tables.
			local mixedOut: any = nil
			local sparseOut: any = nil
			local hole1Out: any = nil
			local sSan = sEnv.Instance.new("RemoteEvent")
			sSan.Name = "SanitizeCheck"
			sSan.Parent = sEnv:getService("ReplicatedStorage")
			w:step()
			local cSan = cEnv:getService("ReplicatedStorage"):FindFirstChild("SanitizeCheck") :: any
			sSan.OnServerEvent:Connect(function(_plr: any, kind: string, payload: any)
				if kind == "mixed" then
					mixedOut = payload
				elseif kind == "sparse" then
					sparseOut = payload
				else
					hole1Out = payload
				end
			end)
			cSan:FireServer("mixed", { [1] = "a", named = "b" })
			cSan:FireServer("sparse", { [1] = "a", [3] = "c" })
			cSan:FireServer("hole1", { [2] = "b" })
			w:step()
			sert.eq(mixedOut, { "a" })
			sert.eq(sparseOut, { "a" })
			sert.eq(hole1Out, {})

			-- Illegal remote payloads (and mixed/sparse under opt-in strictRemotes) throw cleanly.
			sert.throws(function()
				cRem:FireServer(function() end)
			end, "function")
			sert.throws(function()
				cRem:FireServer(coroutine.create(function() end))
			end, "thread")
			sert.throws(function()
				local cyc: any = {}
				cyc.self = cyc
				cRem:FireServer(cyc)
			end, "cyclic")

			local sw = sert.sim.new({ seed = 7, instant = true, strictRemotes = true })
			local ssrv = sw:server()
			local scli = ssrv:client(102)
			local strictRemS = ssrv:env().Instance.new("RemoteEvent")
			strictRemS.Name = "StrictCheck"
			strictRemS.Parent = ssrv:env():getService("ReplicatedStorage")
			sw:step()
			local strictRemC = scli:env():getService("ReplicatedStorage"):FindFirstChild("StrictCheck") :: any
			sert.throws(function() strictRemC:FireServer({ [1] = "a", named = "b" }) end, "mixed")
			sert.throws(function() strictRemC:FireServer({ [1] = "a", [3] = "c" }) end, "sparse")

			-- Standalone sert.env enforces 900B UnreliableRemoteEvent cap (including buffers) and hides ServerStorage instances from clients.
			local solo = sert.env.new()
			local soloUre = solo.Instance.new("UnreliableRemoteEvent", solo:getService("ReplicatedStorage"))
			local ureHits = 0
			soloUre.OnServerEvent:Connect(function()
				ureHits += 1
			end)
			soloUre:FireServer(buffer.create(1024))
			solo:step()
			sert.eq(ureHits, 0)
			soloUre:FireServer(buffer.create(128))
			solo:step()
			sert.eq(ureHits, 1)

			local soloRe = solo.Instance.new("RemoteEvent", solo:getService("ReplicatedStorage"))
			local gotSecretInst: any = "unset"
			soloRe.OnClientEvent:Connect(function(inst: any) gotSecretInst = inst end)
			local secretFolder = solo.Instance.new("Folder", solo:getService("ServerStorage"))
			soloRe:FireAllClients(secretFolder)
			solo:step()
			sert.eq(gotSecretInst, nil)
		end
	)
end)

describe("Instance subclasses: Model, BasePart, Humanoid, ValueBase, and hierarchy queries", function()
	test("exercises Model pivot/scale/extents and BasePart mass, impulse, and CFrame/Position coupling", function()
		local e = sert.env.new({ signalBehavior = "Immediate" })
		local model = e.Instance.new("Model", e.workspace)
		local root = e.Instance.new("Part", model)
		root.Name = "Root"
		root.Size = e.Vector3.new(2, 4, 6)
		root.CFrame = e.CFrame.new(10, 0, 0)

		local limb = e.Instance.new("Part", model)
		limb.Name = "Limb"
		limb.CFrame = e.CFrame.new(14, 2, 0)

		-- Without PrimaryPart, GetPivot reads WorldPivot; setting PrimaryPart delegates GetPivot to PrimaryPart.CFrame.
		sert.eq(model:GetPivot(), e.CFrame.identity)
		model.PrimaryPart = root
		sert.eq(model:GetPivot(), e.CFrame.new(10, 0, 0))

		-- PivotTo transforms PrimaryPart and all descendant BaseParts in object space relative to the prior pivot.
		model:PivotTo(e.CFrame.new(20, 5, -3))
		sert.eq(root.Position, e.Vector3.new(20, 5, -3))
		sert.eq(limb.Position, e.Vector3.new(24, 7, -3))

		-- MoveTo translates the model pivot while preserving rotation.
		model:MoveTo(e.Vector3.new(0, 10, 0))
		sert.eq(root.Position, e.Vector3.new(0, 10, 0))
		sert.eq(limb.Position, e.Vector3.new(4, 12, 0))

		sert.eq(model:GetScale(), 1)
		model:ScaleTo(2.5)
		sert.eq(model:GetScale(), 2.5)
		local bbCf, bbSize = model:GetBoundingBox()
		sert.eq(bbCf, e.CFrame.identity)
		sert.eq(bbSize, e.Vector3.new(4, 5, 2))
		sert.eq(model:GetExtentsSize(), e.Vector3.new(4, 5, 2))

		-- BasePart: GetMass, GetPivot/PivotTo, ApplyImpulse, network owner, and coupled CFrame <-> Position signals.
		sert.eq(root:GetMass(), 48)
		local posHits, cfHits = 0, 0
		root:GetPropertyChangedSignal("Position"):Connect(function()
			posHits += 1
		end)
		root:GetPropertyChangedSignal("CFrame"):Connect(function()
			cfHits += 1
		end)

		root.Position = e.Vector3.new(3, 6, 9)
		sert.eq(root.CFrame.Position, e.Vector3.new(3, 6, 9))
		sert.eq(posHits, 1)
		sert.eq(cfHits, 1)

		root:PivotTo(e.CFrame.new(-5, 2, 4))
		sert.eq(root:GetPivot(), e.CFrame.new(-5, 2, 4))
		sert.eq(root.Position, e.Vector3.new(-5, 2, 4))
		sert.eq(posHits, 2)
		sert.eq(cfHits, 2)

		root.Anchored = true
		root.CanCollide = false
		root.Orientation = e.Vector3.new(0, 90, 0)
		sert.eq(root.Anchored, true)
		sert.eq(root.CanCollide, false)
		sert.eq(root.Orientation, e.Vector3.new(0, 90, 0))

		root:ApplyImpulse(e.Vector3.new(5, 0, -2))
		root:ApplyImpulse(e.Vector3.new(1, 3, 2))
		sert.eq(root.AssemblyLinearVelocity, e.Vector3.new(6, 3, 0))
		root:SetNetworkOwner(nil)
		sert.eq(root:GetNetworkOwner(), nil)

		-- Unimplemented API dump methods fail explicitly rather than silently succeeding.
		sert.throws(function() model:TranslateBy(e.Vector3.one) end, "does not implement")
		sert.throws(function() root:ApplyAngularImpulse(e.Vector3.one) end, "does not implement")
		sert.throws(function() root:GetVelocityAtPosition(e.Vector3.zero) end, "does not implement")
	end)

	test(
		"clamps Humanoid Health/MaxHealth, fires HealthChanged/StateChanged/Died once, and manages accessories",
		function()
			local e = sert.env.new({ signalBehavior = "Immediate" })
			local rig = e.Instance.new("Model", e.workspace)
			local hum = e.Instance.new("Humanoid", rig)
			local targetPart = e.Instance.new("Part", e.workspace)

			local healthLog: { number } = {}
			local stateLog: { string } = {}
			local diedCount = 0
			local moveFinished: { boolean } = {}

			hum.HealthChanged:Connect(function(hp: number) table.insert(healthLog, hp) end)
			hum.StateChanged:Connect(
				function(oldState: any, newState: any) table.insert(stateLog, `{oldState.Name}->{newState.Name}`) end
			)
			hum.Died:Connect(function()
				diedCount += 1
			end)
			hum.MoveToFinished:Connect(function(reached: boolean) table.insert(moveFinished, reached) end)

			-- Over-healing clamps to MaxHealth; lowering MaxHealth clamps current Health and fires HealthChanged.
			hum.Health = 250
			sert.eq(hum.Health, 100)
			hum.MaxHealth = 80
			sert.eq(hum.Health, 80)
			sert.eq(healthLog, { 80 })

			hum:TakeDamage(30)
			sert.eq(hum.Health, 50)
			hum:MoveTo(e.Vector3.new(12, 0, -4), targetPart)
			sert.eq(hum.WalkToPoint, e.Vector3.new(12, 0, -4))
			sert.eq(hum.WalkToPart, targetPart)
			sert.eq(moveFinished, { true })

			hum:ChangeState(e.Enum.HumanoidStateType.Jumping)
			sert.eq(hum:GetState(), e.Enum.HumanoidStateType.Jumping)
			sert.eq(stateLog, { "Running->Jumping" })

			-- Dropping to 0 transitions to Dead and fires Died once; subsequent healing does not re-fire Died on next 0.
			hum:TakeDamage(999)
			sert.eq(hum.Health, 0)
			sert.eq(hum:GetState(), e.Enum.HumanoidStateType.Dead)
			sert.eq(diedCount, 1)
			sert.eq(stateLog, { "Running->Jumping", "Jumping->Dead" })

			hum.Health = 40
			hum:TakeDamage(40)
			sert.eq(diedCount, 1)

			-- Accessories & HumanoidDescription round-trip
			local hat = e.Instance.new("Accessory")
			hat.Name = "Crown"
			hum:AddAccessory(hat)
			sert.eq(hat.Parent, rig)
			sert.eq(hum:GetAccessories(), { hat })
			hum:RemoveAccessories()
			sert.eq(hat.Parent, nil)
			sert.eq(hum:GetAccessories(), {})

			local desc = hum:GetAppliedDescription()
			sert.eq(desc.ClassName, "HumanoidDescription")
			local accSpec = { { AssetId = 12345 } }
			desc:SetAccessories(accSpec, true)
			sert.eq(desc:GetAccessories(true), { { AssetId = 12345 } })
			local customDesc = e.Instance.new("HumanoidDescription")
			hum:ApplyDescription(customDesc)
			sert.eq(hum:GetAppliedDescription(), customDesc)
			hum:ApplyDescriptionReset(desc)
			sert.eq(hum:GetAppliedDescription(), desc)

			sert.throws(function() hum:Move(e.Vector3.xAxis, false) end, "does not implement")
			sert.throws(function() hum:EquipTool(e.Instance.new("Tool")) end, "does not implement")
			sert.throws(function() hum:UnequipTools() end, "does not implement")
		end
	)

	test("fires ValueBase.Changed with newValue (never property name) across all ValueBase classes", function()
		local e = sert.env.new({ signalBehavior = "Immediate" })
		local part = e.Instance.new("Part")
		local cases: { { className: string, nextVal: any } } = {
			{ className = "IntValue", nextVal = 42 },
			{ className = "NumberValue", nextVal = 3.25 },
			{ className = "StringValue", nextVal = "hello" },
			{ className = "BoolValue", nextVal = true },
			{ className = "ObjectValue", nextVal = part },
			{ className = "Vector3Value", nextVal = e.Vector3.new(1, 2, 3) },
			{ className = "CFrameValue", nextVal = e.CFrame.new(4, 5, 6) },
			{ className = "Color3Value", nextVal = e.Color3.fromRGB(10, 20, 30) },
			{ className = "BrickColorValue", nextVal = e.BrickColor.new("Bright red") },
			{ className = "RayValue", nextVal = e.Ray.new(e.Vector3.zero, e.Vector3.yAxis) },
		}

		for _, c in cases do
			local v = e.Instance.new(c.className)
			local received: { any } = {}
			local nameSignals = 0
			v.Changed:Connect(function(arg: any) table.insert(received, arg) end)
			v:GetPropertyChangedSignal("Name"):Connect(function()
				nameSignals += 1
			end)

			-- Renaming a ValueBase fires GetPropertyChangedSignal("Name") without firing ValueBase.Changed.
			v.Name = "Custom_" .. c.className
			sert.eq(nameSignals, 1)
			sert.eq(received, {})

			v.Value = c.nextVal
			sert.eq(#received, 1)
			sert.eq(received[1], c.nextVal)
		end
	end)

	test("supports full hierarchy queries, ClearAllChildren, Instance.fromExisting, attributes, and tags", function()
		local e = sert.env.new({ signalBehavior = "Immediate" })
		local folder = e.Instance.new("Folder", e.workspace)
		folder.Name = "WorldRoot"
		local model = e.Instance.new("Model", folder)
		model.Name = "Rig"
		local wedge = e.Instance.new("WedgePart", model)
		wedge.Name = "Slope"
		wedge:SetAttribute("Friction", 0.4)
		wedge:AddTag("Climbable")
		wedge:AddTag("A_First")

		sert.eq(wedge:GetFullName(), "Workspace.WorldRoot.Rig.Slope")
		sert.eq(folder:FindFirstChildWhichIsA("PVInstance"), model)
		sert.eq(folder:FindFirstChildWhichIsA("BasePart", true), wedge)
		sert.eq(folder:FindFirstChildOfClass("WedgePart", true), wedge)
		sert.eq(wedge:FindFirstAncestor("WorldRoot"), folder)
		sert.eq(wedge:FindFirstAncestorOfClass("Folder"), folder)
		sert.eq(wedge:FindFirstAncestorWhichIsA("WorldRoot"), e.workspace)
		sert.eq(folder:IsAncestorOf(wedge), true)
		sert.eq(wedge:IsAncestorOf(folder), false)
		sert.eq(wedge:IsDescendantOf(folder), true)
		sert.throws(function() folder:FindFirstDescendant("Slope") end, "does not implement")
		sert.throws(function() folder.Parent = wedge end, "circular reference")
		sert.throws(function() (wedge :: any).Parent = 123 end, "Instance expected")

		-- Selector combinators (:has, :not, comma union) and invalid selector rejection
		sert.eq(e.workspace:QueryDescendants("Model:has(> WedgePart.Climbable), Part:not(.Missing)"), { model })
		sert.throws(function() e.workspace:QueryDescendants("Model[unclosed") end, "invalid selector")

		-- Attribute validation, GetAttributes clone, and AttributeChanged signal
		local attrChanged: { string } = {}
		wedge.AttributeChanged:Connect(function(attr: string) table.insert(attrChanged, attr) end)
		wedge:SetAttribute("Speed", 16)
		sert.eq(wedge:GetAttributes(), { Friction = 0.4, Speed = 16 })
		wedge:SetAttribute("Friction", nil)
		sert.eq(wedge:GetAttributes(), { Speed = 16 })
		sert.eq(attrChanged, { "Speed", "Friction" })
		sert.throws(function() wedge:SetAttribute("RBXReserved", 1) end, "invalid")
		sert.throws(function() wedge:SetAttribute("Bad Type!", 1) end, "invalid")
		sert.throws(function()
			wedge:SetAttribute("BadVal", function() end)
		end, "not a supported attribute type")

		-- GetTags returns sorted tag list; Instance.fromExisting copies node props/tags/attrs without children.
		sert.eq(wedge:GetTags(), { "A_First", "Climbable" })
		local shallow = e.Instance.fromExisting(model)
		sert.eq(shallow.Name, "Rig")
		sert.eq(shallow.Parent, nil)
		sert.eq(#shallow:GetChildren(), 0)

		-- ClearAllChildren destroys all children while keeping parent intact.
		folder:ClearAllChildren()
		sert.eq(#folder:GetChildren(), 0)
		sert.eq(model.Parent, nil)
		sert.eq(wedge.Parent, nil)
	end)
end)

describe("Extended UI layout, UIScale, AutomaticSize, typography, UIPageLayout, Camera, Sound & TextChannel", function()
	test(
		"computes wrapped UIListLayout, vertical/flipped UIGridLayout, UIScale, AutomaticSize, AutomaticCanvasSize, and RichText/TextScaled bounds",
		function()
			local e = sert.env.new({ isClient = true, isServer = false, viewport = sert.env.Vector2.new(800, 600) })
			local pg = e.LocalPlayer.PlayerGui
			local sg = e.Instance.new("ScreenGui", pg)
			sert.eq(sg.AbsoluteSize, e.Vector2.new(800, 542))
			sg.IgnoreGuiInset = true
			sert.eq(sg.AbsoluteSize, e.Vector2.new(800, 600))

			-- Wrapped UIListLayout with Center/Top alignments and SortOrder.Name + AutomaticSize.Y container
			local wrapBox = e.Instance.new("Frame", sg)
			wrapBox.Size = e.UDim2.fromOffset(150, 0)
			wrapBox.AutomaticSize = e.Enum.AutomaticSize.Y
			local wrapList = e.Instance.new("UIListLayout", wrapBox)
			wrapList.FillDirection = e.Enum.FillDirection.Horizontal
			wrapList.Wraps = true
			wrapList.SortOrder = e.Enum.SortOrder.Name
			wrapList.HorizontalAlignment = e.Enum.HorizontalAlignment.Center
			wrapList.VerticalAlignment = e.Enum.VerticalAlignment.Top
			wrapList.Padding = e.UDim.new(0, 10)

			for _, name in { "C_Item", "A_Item", "B_Item" } do
				local item = e.Instance.new("Frame", wrapBox)
				item.Name = name
				item.Size = e.UDim2.fromOffset(60, 25)
			end
			-- Two 60px items + 10px gap = 130 <= 150 on line 1; 3rd wraps to line 2 => totalH = 25 + 10 + 25 = 60.
			sert.eq(wrapList.AbsoluteContentSize, e.Vector2.new(130, 60))
			sert.eq(wrapBox.AbsoluteSize, e.Vector2.new(150, 60))
			local itemA = wrapBox:FindFirstChild("A_Item") :: any
			local itemC = wrapBox:FindFirstChild("C_Item") :: any
			sert.near(itemA.AbsolutePosition.X, 10, 1e-3)
			sert.near(itemC.AbsolutePosition.X, 45, 1e-3)
			sert.near(itemC.AbsolutePosition.Y, 35, 1e-3)

			-- Vertical UIGridLayout with FillDirectionMaxCells & BottomRight StartCorner + UIScale child
			local gFrame = e.Instance.new("Frame", sg)
			gFrame.Size = e.UDim2.fromOffset(300, 200)
			local gLayout = e.Instance.new("UIGridLayout", gFrame)
			gLayout.FillDirection = e.Enum.FillDirection.Vertical
			gLayout.FillDirectionMaxCells = 2
			gLayout.StartCorner = e.Enum.StartCorner.BottomRight
			gLayout.HorizontalAlignment = e.Enum.HorizontalAlignment.Right
			gLayout.VerticalAlignment = e.Enum.VerticalAlignment.Bottom
			gLayout.CellSize = e.UDim2.fromOffset(50, 40)
			gLayout.CellPadding = e.UDim2.fromOffset(10, 10)

			local cell1 = e.Instance.new("Frame", gFrame)
			cell1.LayoutOrder = 1
			local uiScale = e.Instance.new("UIScale", cell1)
			uiScale.Scale = 1.5
			local cell2 = e.Instance.new("Frame", gFrame)
			cell2.LayoutOrder = 2
			local cell3 = e.Instance.new("Frame", gFrame)
			cell3.LayoutOrder = 3

			sert.eq(gLayout.AbsoluteCellCount, e.Vector2.new(2, 2))
			sert.eq(gLayout.AbsoluteContentSize, e.Vector2.new(110, 90))
			sert.eq(cell1.AbsoluteSize, e.Vector2.new(75, 60))
			-- BottomRight start corner places first cell at (col=1, row=1) inside right/bottom-aligned 110x90 content box
			sert.eq(cell1.AbsolutePosition, e.Vector2.new(300 - 50, 200 - 40))
			sert.eq(cell2.AbsolutePosition, e.Vector2.new(300 - 50, 200 - 90))
			sert.eq(cell3.AbsolutePosition, e.Vector2.new(300 - 110, 200 - 40))

			-- ScrollingFrame AutomaticCanvasSize + RichText, TextWrapped, TextScaled, and GetGuiObjectsAtPosition
			local scroll = e.Instance.new("ScrollingFrame", sg)
			scroll.Position = e.UDim2.fromOffset(0, 300)
			scroll.Size = e.UDim2.fromOffset(200, 80)
			scroll.CanvasSize = e.UDim2.fromOffset(0, 0)
			scroll.AutomaticCanvasSize = e.Enum.AutomaticSize.Y
			local sList = e.Instance.new("UIListLayout", scroll)
			sList.Padding = e.UDim.new(0, 5)
			for i = 1, 4 do
				local row = e.Instance.new("TextLabel", scroll)
				row.LayoutOrder = i
				row.Size = e.UDim2.fromOffset(180, 40)
				row.RichText = true
				row.Text = `<b>Row {i}</b>`
			end
			sert.eq(scroll.AbsoluteWindowSize, e.Vector2.new(200, 80))
			sert.eq(scroll.AbsoluteCanvasSize, e.Vector2.new(0, 175))
			local firstRow = scroll:FindFirstChildOfClass("TextLabel") :: any
			sert.eq(firstRow.ContentText, "Row 1")
			sert.ok(firstRow.TextBounds.X > 0 and firstRow.TextFits == true)

			local scaledLbl = e.Instance.new("TextLabel", sg)
			scaledLbl.Size = e.UDim2.fromOffset(60, 24)
			scaledLbl.TextWrapped = true
			scaledLbl.TextScaled = true
			scaledLbl.Text = "Long wrapped headline that scales down cleanly"
			sert.eq(scaledLbl.TextFits, true)
			sert.ok(scaledLbl.TextBounds.X <= 60 and scaledLbl.TextBounds.Y <= 24)

			local hits = pg:GetGuiObjectsAtPosition(50, 320)
			sert.ok(table.find(hits, scroll) ~= nil and table.find(hits, firstRow) ~= nil)
		end
	)

	test(
		"supports UIPageLayout, Camera projection, Sound, HapticEffect, TextChannel, and injected datatypes",
		function()
			local e = sert.env.new({ signalBehavior = "Immediate", isClient = true, isServer = false })
			local host = e.Instance.new("Frame", e.Instance.new("ScreenGui", e.LocalPlayer.PlayerGui))
			local pager = e.Instance.new("UIPageLayout", host)
			local p1 = e.Instance.new("Frame", host)
			p1.Name = "P1"
			local p2 = e.Instance.new("Frame", host)
			p2.Name = "P2"

			local pageEvents: { string } = {}
			pager.PageEnter:Connect(function(p: any) table.insert(pageEvents, "enter:" .. p.Name) end)
			pager.PageLeave:Connect(function(p: any) table.insert(pageEvents, "leave:" .. p.Name) end)

			pager:JumpToIndex(0)
			sert.eq(pager.CurrentPage, p1)
			pager:Next()
			sert.eq(pager.CurrentPage, p2)
			pager:Previous()
			sert.eq(pager.CurrentPage, p1)
			sert.eq(pageEvents, { "enter:P1", "leave:P1", "enter:P2", "leave:P2", "enter:P1" })

			-- Camera projection & rays after setViewport
			e:setViewport(e.Vector2.new(1000, 500))
			e.camera.CFrame = e.CFrame.new(0, 0, 10)
			local vpPt, onScreen = e.camera:WorldToViewportPoint(e.Vector3.new(0, 0, 0))
			sert.eq(onScreen, true)
			sert.eq(vpPt, e.Vector3.new(500, 250, 10))
			local scrPt, scrOn = e.camera:WorldToScreenPoint(e.Vector3.new(0, 0, 20))
			sert.eq(scrOn, false)
			sert.ok(scrPt.Z < 0)
			local ray = e.camera:ViewportPointToRay(10, 20, 5)
			sert.eq(ray.Origin, e.Vector3.new(10, 20, 15))

			-- Sound, HapticEffect, BindableEvent, BindableFunction, and TextChannel hooks
			local snd = e.Instance.new("Sound")
			snd.SoundId = "rbxassetid://99"
			local stoppedIds: { string } = {}
			snd.Stopped:Connect(function(id: string) table.insert(stoppedIds, id) end)
			snd:Play()
			sert.eq(snd.Playing, true)
			snd:Pause()
			sert.eq(snd.Playing, false)
			snd:Resume()
			sert.eq(snd.Playing, true)
			snd:Stop()
			sert.eq(snd.Playing, false)
			sert.eq(stoppedIds, { "rbxassetid://99" })

			local hap = e.Instance.new("HapticEffect")
			hap:SetWaveformKeys({ e.FloatCurveKey.new(0, 1) })
			hap:Play()
			sert.eq(hap.Playing, true)
			hap:Stop()
			sert.eq(hap.Playing, false)

			local be = e.Instance.new("BindableEvent")
			local bf = e.Instance.new("BindableFunction")
			local firedVal = 0
			be.Event:Connect(function(n: number) firedVal = n end)
			be:Fire(77)
			sert.eq(firedVal, 77)
			bf.OnInvoke = function(a: number, b: number) return a * b end
			sert.eq(bf:Invoke(6, 7), 42)

			local tcs = e:getService("TextChatService")
			local chan = e.Instance.new("TextChannel", tcs)
			local src, added = chan:AddUserAsync(e.LocalPlayer.UserId)
			sert.eq(added, true)
			sert.eq(src.UserId, e.LocalPlayer.UserId)
			chan:SetDirectChatRequester(e.LocalPlayer)
			sert.eq(chan:GetDirectChatRequester(), e.LocalPlayer)
			chan.OnIncomingMessage = function(msg: any)
				local props = e.Instance.new("TextChatMessageProperties")
				props.PrefixText = "[VIP]"
				props.Text = string.upper(msg.Text)
				return props
			end
			local receivedTexts: { string } = {}
			chan.MessageReceived:Connect(function(m: any) table.insert(receivedTexts, `{m.PrefixText}{m.Text}`) end)
			chan:SendAsync("gg", "meta")
			chan:DisplaySystemMessage("welcome")
			sert.eq(receivedTexts, { "[VIP]GG", "welcome" })

			-- Custom injected datatypes table exercises schemaDefaults + rebuildValue
			local customEnv = sert.env.new({ datatypes = { Vector3 = sert.env.Vector3 } })
			local cp = customEnv.Instance.new("Part")
			sert.eq(cp.Size, customEnv.Vector3.new(4, 1, 2))
		end
	)
end)

describe("Workspace spatial queries, TweenService, and CollectionService", function()
	test(
		"handles Workspace Raycast (Include/Exclude/CanQuery/CanCollide) and Box/Radius/Part overlap queries",
		function()
			local e = sert.env.new()
			local folder = e.Instance.new("Folder", e.workspace)

			local nearPart = e.Instance.new("Part", folder)
			nearPart.Name = "Near"
			nearPart.Size = e.Vector3.new(4, 4, 2)
			nearPart.CFrame = e.CFrame.new(0, 0, -10)
			nearPart.Material = e.Enum.Material.Neon

			local farPart = e.Instance.new("Part", folder)
			farPart.Name = "Far"
			farPart.Size = e.Vector3.new(4, 4, 2)
			farPart.CFrame = e.CFrame.new(0, 0, -20)
			farPart.CanCollide = false

			local ghost = e.Instance.new("Part", folder)
			ghost.Name = "Ghost"
			ghost.Size = e.Vector3.new(4, 4, 2)
			ghost.CFrame = e.CFrame.new(0, 0, -5)
			ghost.CanQuery = false

			-- Default raycast skips CanQuery=false ghost and hits closest surface of nearPart at Z = -9 with +Z normal.
			local hit = e.workspace:Raycast(e.Vector3.zero, e.Vector3.new(0, 0, -30))
			sert.ok(hit ~= nil)
			sert.eq(hit.Instance, nearPart)
			sert.eq(hit.Position, e.Vector3.new(0, 0, -9))
			sert.eq(hit.Normal, e.Vector3.new(0, 0, 1))
			sert.near(hit.Distance, 9, 1e-5)
			sert.eq(hit.Material, e.Enum.Material.Neon)

			-- Miss when ray points away
			sert.eq(e.workspace:Raycast(e.Vector3.zero, e.Vector3.new(0, 10, 0)), nil)

			-- Exclude nearPart -> hits farPart; RespectCanCollide = true skips farPart (CanCollide = false) -> nil!
			local exParams = e.RaycastParams.new()
			exParams.FilterType = e.Enum.RaycastFilterType.Exclude
			exParams.FilterDescendantsInstances = { nearPart }
			local hitFar = e.workspace:Raycast(e.Vector3.zero, e.Vector3.new(0, 0, -30), exParams)
			sert.ok(hitFar ~= nil and hitFar.Instance == farPart)

			exParams.RespectCanCollide = true
			sert.eq(e.workspace:Raycast(e.Vector3.zero, e.Vector3.new(0, 0, -30), exParams), nil)

			-- Include filter restricts candidates to listed subtree
			local incParams = e.RaycastParams.new()
			incParams.FilterType = e.Enum.RaycastFilterType.Include
			incParams.FilterDescendantsInstances = { farPart }
			local incHit = e.workspace:Raycast(e.Vector3.zero, e.Vector3.new(0, 0, -30), incParams)
			sert.ok(incHit ~= nil and incHit.Instance == farPart)

			-- Overlap queries: Box, Radius, GetPartsInPart (excludes self), and MaxParts cap
			local ov = e.OverlapParams.new()
			ov.MaxParts = 1
			local boxHits = e.workspace:GetPartBoundsInBox(e.CFrame.new(0, 0, -15), e.Vector3.new(10, 10, 20))
			sert.eq(#boxHits, 2)
			sert.eq(#e.workspace:GetPartBoundsInBox(e.CFrame.new(0, 0, -15), e.Vector3.new(10, 10, 20), ov), 1)

			local radHits = e.workspace:GetPartBoundsInRadius(e.Vector3.new(0, 0, -10), 3)
			sert.eq(radHits, { nearPart })

			local probe = e.Instance.new("Part", e.workspace)
			probe.Size = e.Vector3.new(6, 6, 6)
			probe.CFrame = e.CFrame.new(0, 0, -10)
			sert.eq(e.workspace:GetPartsInPart(probe), { nearPart })
			sert.ok(e.workspace:GetServerTimeNow() > 0)
		end
	)

	test(
		"drives TweenService Play/Pause/Cancel, DelayTime, Reverses/RepeatCount, conflict cancel, and GetValue",
		function()
			local e = sert.env.new()
			local ts = e:getService("TweenService")
			local frame = e.Instance.new("Frame")
			frame.Size = e.UDim2.fromOffset(0, 0)
			frame.BackgroundTransparency = 0

			-- Validation errors on unknown, non-tweenable, or mismatched goal types
			sert.throws(function() ts:Create(frame, e.TweenInfo.new(1), { Bogus = 1 }) end, "no property named")
			sert.throws(function() ts:Create(frame, e.TweenInfo.new(1), { Name = "x" }) end, "not a data type")
			sert.throws(function() ts:Create(frame, e.TweenInfo.new(1), { Rotation = "bad" }) end, "type mismatch")

			-- GetValue across EasingStyles & EasingDirections
			for _, style in
				{
					e.Enum.EasingStyle.Linear,
					e.Enum.EasingStyle.Sine,
					e.Enum.EasingStyle.Quad,
					e.Enum.EasingStyle.Cubic,
					e.Enum.EasingStyle.Quart,
					e.Enum.EasingStyle.Quint,
					e.Enum.EasingStyle.Exponential,
					e.Enum.EasingStyle.Circular,
					e.Enum.EasingStyle.Back,
					e.Enum.EasingStyle.Bounce,
					e.Enum.EasingStyle.Elastic,
				}
			do
				for _, dir in { e.Enum.EasingDirection.In, e.Enum.EasingDirection.Out, e.Enum.EasingDirection.InOut } do
					sert.near(ts:GetValue(0, style, dir), 0, 1e-4)
					sert.near(ts:GetValue(1, style, dir), 1, 1e-4)
					local mid = ts:GetValue(0.5, style, dir)
					sert.ok(mid == mid)
				end
			end

			-- Delayed + reversing + repeating tween, Pause/Play resume, and Completed signal
			local info = e.TweenInfo.new(0.2, e.Enum.EasingStyle.Linear, e.Enum.EasingDirection.Out, 1, true, 0.1)
			local tw = ts:Create(frame, info, {
				BackgroundTransparency = 1,
				Size = e.UDim2.fromOffset(100, 50),
			})
			local completedStates: { any } = {}
			tw.Completed:Connect(function(st: any) table.insert(completedStates, st) end)

			tw:Play()
			sert.eq(tw.PlaybackState, e.Enum.PlaybackState.Delayed)
			e:step(0.05)
			sert.eq(tw.PlaybackState, e.Enum.PlaybackState.Delayed)
			e:step(0.15)
			sert.eq(tw.PlaybackState, e.Enum.PlaybackState.Playing)
			sert.near(frame.BackgroundTransparency, 0.5, 1e-3)

			tw:Pause()
			sert.eq(tw.PlaybackState, e.Enum.PlaybackState.Paused)
			e:step(0.2)
			sert.near(frame.BackgroundTransparency, 0.5, 1e-3)

			tw:Play()
			-- 2 cycles of (0.1 delay + 0.4 forward/reverse) = 1.0s total; 0.2s elapsed so far -> 0.85s finishes cleanly at startVal!
			e:advance(0.85)
			e:flush()
			sert.eq(tw.PlaybackState, e.Enum.PlaybackState.Completed)
			sert.near(frame.BackgroundTransparency, 0, 1e-4)
			sert.eq(completedStates, { e.Enum.PlaybackState.Completed })

			-- Starting an overlapping tween on the same property cancels the active tween
			local twA = ts:Create(frame, e.TweenInfo.new(1.0), { Rotation = 90 })
			local twB = ts:Create(frame, e.TweenInfo.new(0.2), { Rotation = 180 })
			local aCancelled = false
			twA.Completed:Connect(function(st: any) aCancelled = st == e.Enum.PlaybackState.Cancelled end)
			twA:Play()
			e:step(0.1)
			twB:Play()
			e:flush()
			sert.eq(aCancelled, true)
			twB:Cancel()
			e:flush()
			sert.eq(twB.PlaybackState, e.Enum.PlaybackState.Cancelled)
		end
	)

	test("tracks CollectionService DataModel membership, ordering, and added/removed signals", function()
		local e = sert.env.new({ signalBehavior = "Immediate" })
		local cs = e:getService("CollectionService")
		local added: { any } = {}
		local removed: { any } = {}
		cs:GetInstanceAddedSignal("Loot"):Connect(function(inst: any) table.insert(added, inst) end)
		cs:GetInstanceRemovedSignal("Loot"):Connect(function(inst: any) table.insert(removed, inst) end)

		-- Unparented tagged instance is NOT in GetTagged until parented into game!
		local detached = e.Instance.new("Part")
		cs:AddTag(detached, "Loot")
		sert.eq(cs:HasTag(detached, "Loot"), true)
		sert.eq(cs:GetTags(detached), { "Loot" })
		sert.eq(cs:GetTagged("Loot"), {})
		sert.eq(added, {})

		detached.Parent = e.workspace
		sert.eq(cs:GetTagged("Loot"), { detached })
		sert.eq(added, { detached })

		detached.Parent = nil
		sert.eq(cs:GetTagged("Loot"), {})
		sert.eq(removed, { detached })

		detached.Parent = e.workspace
		cs:RemoveTag(detached, "Loot")
		sert.eq(cs:HasTag(detached, "Loot"), false)
		sert.eq(#removed, 2)
	end)
end)

describe("Players, HttpService, MarketplaceService, TeleportService, ProximityPrompts & peer services", function()
	test("manages Players lifecycle, character loading, group/friend queries, and BanAsync/Kick", function()
		local e = sert.env.new({ signalBehavior = "Immediate" })
		local players = e.Players
		local joined: { number } = {}
		local left: { number } = {}
		players.PlayerAdded:Connect(function(p: any) table.insert(joined, p.UserId) end)
		players.PlayerRemoving:Connect(function(p: any) table.insert(left, p.UserId) end)

		e:setGroupRank(501, 77, 200, "Admin")
		e.friends[501] = { [502] = true }

		local p1 = e:addPlayer(501, "Alice")
		local p2 = e:addPlayer({ UserId = 502, Name = "Bob", DisplayName = "Bobby", AccountAge = 900 })
		sert.eq(joined, { 501, 502 })
		sert.eq(#players:GetPlayers(), 2)
		sert.eq(players:GetPlayerByUserId(501), p1)
		sert.ok(p1.Character ~= nil)
		sert.eq(players:GetPlayerFromCharacter(p1.Character), p1)

		local shirt = e.Instance.new("Shirt", p1.Character)
		p1:ClearCharacterAppearance()
		sert.eq(shirt.Parent, nil)

		sert.eq(p1:GetRankInGroup(77), 200)
		sert.eq(p1:GetRoleInGroup(77), "Admin")
		sert.eq(p1:IsInGroup(77), true)
		sert.eq(p2:GetRoleInGroup(77), "Guest")
		sert.eq(p1:IsFriendsWith(502), true)
		sert.eq(players:GetNameFromUserIdAsync(501), "Alice")
		sert.eq(players:GetUserIdFromNameAsync("alice"), 501)
		local thumb, ready = players:GetUserThumbnailAsync(501)
		sert.ok(ready == true and string.find(thumb, "501") ~= nil)
		local friendPages = players:GetFriendsAsync(501)
		sert.eq(#friendPages:GetCurrentPage(), 1)

		players:BanAsync({ UserIds = { 502 }, DisplayReason = "Exploiting" })
		sert.eq(left, { 502 })
		sert.eq(#e.kicks, 1)
		sert.eq(e.kicks[1].message, "Exploiting")
		sert.ok(e.bans[502] ~= nil)

		e:removePlayer(p1)
		sert.eq(left, { 502, 501 })
		sert.eq(#players:GetPlayers(), 0)
	end)

	test("supports HttpService GUID/URL/JSON/mock HTTP, MarketplaceService, and TeleportService", function()
		local e = sert.env.new({ signalBehavior = "Immediate" })
		local http = e:getService("HttpService")

		local braced = http:GenerateGUID(true)
		local plain = http:GenerateGUID(false)
		sert.eq(string.sub(braced, 1, 1), "{")
		sert.eq(#plain, 36)
		sert.eq(http:UrlEncode("a b+c=1"), "a%20b%2Bc%3D1")

		local encoded = http:JSONEncode({ ok = true, nums = { 1, 2, 3 } })
		sert.eq(http:JSONDecode(encoded), { ok = true, nums = { 1, 2, 3 } })

		e:onHttp(function(req: any)
			if req.Url == "https://api.test/fail" then
				return { Success = false, StatusCode = 503, StatusMessage = "Unavailable", Body = "" }
			end
			return {
				Success = true,
				StatusCode = 200,
				StatusMessage = "OK",
				Headers = {},
				Body = `{req.Method}:{req.Body or "empty"}`,
			}
		end)
		sert.eq(http:GetAsync("https://api.test/ping"), "GET:empty")
		sert.eq(http:PostAsync("https://api.test/echo", "payload"), "POST:payload")
		sert.throws(function() http:GetAsync("https://api.test/fail") end, "HTTP 503")
		sert.throws(function() http.HttpEnabled = false end, "read only")

		local lenientHttp = sert.env.new({ strict = false }):getService("HttpService")
		lenientHttp.HttpEnabled = false
		sert.throws(function() lenientHttp:GetAsync("https://api.test/ping") end, "not enabled")

		-- MarketplaceService receipts, gamepasses, bundles, assets, subscriptions
		local mps = e:getService("MarketplaceService")
		local plr = e:addPlayer(700, "Buyer")
		e.marketplace.autoApprove = true
		e:setGamePass(700, 11, true)
		e:setProductInfo(99, { Name = "Coins100", PriceInRobux = 50 })
		sert.eq(mps:UserOwnsGamePassAsync(700, 11), true)
		sert.eq(mps:GetProductInfo(99).PriceInRobux, 50)

		local receipts: { any } = {}
		mps.ProcessReceipt = function(info: any)
			table.insert(receipts, info)
			return e.Enum.ProductPurchaseDecision.PurchaseGranted
		end
		local prodFinished = false
		mps.PromptProductPurchaseFinished:Connect(
			function(_uid: number, pid: number, bought: boolean) prodFinished = pid == 99 and bought == true end
		)
		mps:PromptProductPurchase(plr, 99)
		sert.eq(#receipts, 1)
		sert.eq(receipts[1].CurrencySpent, 50)
		sert.eq(prodFinished, true)

		mps:PromptGamePassPurchase(plr, 22)
		mps:PromptPurchase(plr, 33)
		mps:PromptBundlePurchase(plr, 44)
		mps:PromptSubscriptionPurchase(plr, "EXP-1")
		sert.eq(mps:UserOwnsGamePassAsync(plr, 22), true)
		sert.eq(mps:PlayerOwnsAsset(plr, 33), true)
		sert.eq(mps:PlayerOwnsBundle(plr, 44), true)
		sert.eq(mps:CheckUserSubscriptionStatusAsync(plr, "EXP-1").IsSubscribed, true)

		-- TeleportService ReserveServer, TeleportOptions, TeleportAsync, and local teleport data
		local tps = e:getService("TeleportService")
		local code, srvId = tps:ReserveServer(9001)
		sert.ok(#code > 0 and #srvId > 0)
		local opts = e.Instance.new("TeleportOptions")
		opts.ReservedServerAccessCode = code
		opts:SetTeleportData({ party = "alpha" })
		local tpRes = tps:TeleportAsync(9001, { plr }, opts)
		sert.eq(tpRes.ReservedServerAccessCode, code)
		sert.eq(tpRes.PrivateServerId, srvId)
		tps:Teleport(9002, plr, { solo = true })
		tps:TeleportToPrivateServer(9001, code, { plr }, "SpawnA", { priv = 1 })
		tps:TeleportToPlaceInstance(9003, "job-42", plr, "SpawnB", { inst = 2 })
		sert.eq(#e.teleports, 4)
		tps:SetTeleportData({ arrived = true })
		sert.eq(tps:GetLocalPlayerTeleportData(), { arrived = true })
	end)

	test(
		"covers ProximityPrompt triggering, ContextActionService, Teams, Lighting, Debris, and other services",
		function()
			local e = sert.env.new({ signalBehavior = "Immediate" })
			local plr = e:addPlayer(801, "Explorer")
			local pedestal = e.Instance.new("Part", e.workspace)
			pedestal.Position = e.Vector3.new(0, 0, 5)
			local prompt = e.Instance.new("ProximityPrompt", pedestal)
			prompt.MaxActivationDistance = 10
			prompt.HoldDuration = 0.5

			prompt.Enabled = false
			local okDisabled, reasonDisabled = e:triggerPrompt(prompt, plr)
			sert.eq(okDisabled, false)
			sert.eq(reasonDisabled, "disabled")
			prompt.Enabled = true

			plr.Character.PrimaryPart.Position = e.Vector3.new(0, 0, 50)
			local okFar, reasonFar = e:triggerPrompt(prompt, plr)
			sert.eq(okFar, false)
			sert.eq(reasonFar, "out_of_range")

			plr.Character.PrimaryPart.Position = e.Vector3.new(0, 0, 0)
			local okShort, reasonShort = e:triggerPrompt(prompt, plr, 0.1)
			sert.eq(okShort, false)
			sert.eq(reasonShort, "hold_too_short")

			local triggeredCount = 0
			e:getService("ProximityPromptService").PromptTriggered:Connect(function()
				triggeredCount += 1
			end)
			local okFull, reasonFull = e:triggerPrompt(prompt, plr)
			sert.eq(okFull, true)
			sert.eq(reasonFull, nil)
			sert.eq(triggeredCount, 1)

			-- ContextActionService, Teams, Lighting, SoundService, BadgeService, GroupService, PhysicsService, Debris
			local cas = e:getService("ContextActionService")
			cas:BindAction("Dash", function() end, false, e.Enum.KeyCode.Q)
			cas:BindActionAtPriority("Interact", function() end, true, 2000, e.Enum.KeyCode.E)
			sert.ok(cas:GetBoundActionInfo("Dash").fn ~= nil)
			sert.ok(cas:GetAllBoundActionInfo().Interact ~= nil)
			cas:UnbindAction("Dash")
			sert.eq(cas:GetBoundActionInfo("Dash").fn, nil)
			cas:UnbindAllActions()
			sert.eq(cas:GetAllBoundActionInfo(), {})

			local teams = e:getService("Teams")
			local red = e.Instance.new("Team", teams)
			red.Name = "Red"
			sert.eq(teams:GetTeams(), { red })
			sert.eq(e:getService("Lighting").ClockTime, 14)
			sert.eq(e:getService("SoundService").ClassName, "SoundService")

			local badges = e:getService("BadgeService")
			badges:AwardBadge(801, 55)
			sert.eq(badges:UserHasBadgeAsync(801, 55), true)
			sert.eq(badges:GetBadgeInfoAsync(55).IsEnabled, true)

			e:setGroupRank(801, 10, 5, "Scout")
			local groups = e:getService("GroupService"):GetGroupsAsync(801)
			sert.eq(#groups, 1)
			sert.eq(groups[1].Role, "Scout")
			sert.eq(e:getService("GroupService"):GetGroupInfoAsync(10).Id, 10)

			local phys = e:getService("PhysicsService")
			phys:RegisterCollisionGroup("Ghost")
			phys:CollisionGroupSetCollidable("Default", "Ghost", false)
			sert.eq(phys:IsCollisionGroupRegistered("Ghost"), true)
			sert.eq(phys:CollisionGroupsAreCollidable("Default", "Ghost"), false)
			phys:UnregisterCollisionGroup("Ghost")
			sert.eq(phys:IsCollisionGroupRegistered("Ghost"), false)

			e:onTextFilter(function(txt: string): string return (string.gsub(txt, "secret", "####")) end)
			local filtered = e:getService("TextService"):FilterStringAsync("my secret", 801)
			sert.eq(filtered:GetNonChatStringForBroadcastAsync(), "my ####")
			sert.eq(e:getService("Chat"):FilterStringAsync("my secret", plr), "my ####")

			local msgSvc = e:getService("MessagingService")
			local pubData: any = nil
			msgSvc:SubscribeAsync("Alert", function(pkt: any) pubData = pkt.Data end)
			msgSvc:PublishAsync("Alert", { code = 7 })
			sert.eq(pubData, { code = 7 })

			local starterGui = e:getService("StarterGui")
			starterGui:SetCore("TopbarEnabled", false)
			starterGui:SetCoreGuiEnabled(e.Enum.CoreGuiType.Backpack, false)
			sert.eq(starterGui:GetCore("TopbarEnabled"), false)
			sert.eq(starterGui:GetCoreGuiEnabled(e.Enum.CoreGuiType.Backpack), false)

			local refl = e:getService("ReflectionService")
			sert.eq(refl:GetClass("Part").Superclass, "FormFactorPart")
			sert.ok(#refl:GetPropertiesOfClass("Part") > 0)

			local scrap = e.Instance.new("Part", e.workspace)
			e:getService("Debris"):AddItem(scrap, 0.1)
			e:advance(0.15)
			sert.eq(scrap.Parent, nil)
		end
	)
end)

describe("env:mount, env:settle, extended input driver, client replication & RBXScriptSignal", function()
	test(
		"mounts DataModel trees with props/tags/attributes, resolves ./ and ../ requires, settles tweens, and shuts down",
		function()
			local e = sert.env.new({ isClient = true, isServer = false })
			local placeSpec = {
				className = "DataModel",
				children = {
					ReplicatedStorage = {
						className = "ReplicatedStorage",
						children = {
							Config = {
								className = "IntValue",
								value = 120,
								props = { Tags = { "ReplicatedCfg" } },
								attributes = { Env = "Prod" },
							},
							App = {
								className = "Folder",
								children = {
									Core = {
										className = "ModuleScript",
										factory = function(_ENV: any)
											local util = _ENV.require("./Util")
											return { tick = util.base + _ENV.game.ReplicatedStorage.Config.Value }
										end,
									},
									Sub = {
										className = "Folder",
										children = {
											Leaf = {
												className = "ModuleScript",
												factory = function(_ENV: any) return _ENV.require("../Core").tick + 5 end,
											},
										},
									},
									Util = {
										className = "ModuleScript",
										factory = function() return { base = 30 } end,
									},
								},
							},
						},
					},
				},
			}
			sert.throws(function() e:mount(placeSpec, e.workspace) end, "DataModel root")
			local mounted = e:mount(placeSpec)
			sert.eq(mounted, e.game)

			local cfg = e:getService("ReplicatedStorage"):FindFirstChild("Config") :: any
			sert.eq(cfg.Value, 120)
			sert.eq(cfg:HasTag("ReplicatedCfg"), true)
			sert.eq(cfg:GetAttribute("Env"), "Prod")
			sert.eq(e:require("ReplicatedStorage/App/Sub/Leaf"), 155)

			-- env:setAbsolute, env:frames, env:settle, env:run, game:BindToClose + env:shutdown
			local sg = e.Instance.new("ScreenGui", e.LocalPlayer.PlayerGui)
			local panel = e.Instance.new("Frame", sg)
			panel.Size = e.UDim2.fromOffset(40, 40)
			e:setAbsolute(panel, e.Vector2.new(90, 50), e.Vector2.new(12, 18))
			sert.eq(panel.AbsoluteSize, e.Vector2.new(90, 50))
			sert.eq(panel.AbsolutePosition, e.Vector2.new(12, 18))
			e:setAbsolute(panel, nil, nil)

			local tw = e:getService("TweenService")
				:Create(panel, e.TweenInfo.new(0.1), { Size = e.UDim2.fromOffset(200, 80) })
			tw:Play()
			local settledFrames = e:settle({ maxFrames = 30, dt = 0.05 })
			sert.ok(settledFrames >= 2 and settledFrames < 30)
			sert.eq(panel.AbsoluteSize, e.Vector2.new(200, 80))

			local elapsed = e:frames(3, 0.02)
			sert.near(elapsed, 0.06, 1e-6)

			local runOut = e:run(function(mult: number) return e.workspace.Gravity * mult end, 0.5)
			sert.near(runOut, 98.1, 1e-4)

			local closed = false
			e.game:BindToClose(function() closed = true end)
			e:shutdown()
			sert.eq(closed, true)
		end
	)

	test("drives ZIndex/Sibling/DisplayOrder hit-testing, MouseButton2 clicks, and Return focus submit", function()
		local e = sert.env.new({ isClient = true, isServer = false, signalBehavior = "Immediate" })
		local pg = e.LocalPlayer.PlayerGui
		local uis = e:getService("UserInputService")
		local inp = e:input()

		local sgLow = e.Instance.new("ScreenGui", pg)
		sgLow.DisplayOrder = 1
		local lowBtn = e.Instance.new("TextButton", sgLow)
		lowBtn.Size = e.UDim2.fromOffset(100, 100)

		local sgHigh = e.Instance.new("ScreenGui", pg)
		sgHigh.DisplayOrder = 5
		sgHigh.ZIndexBehavior = e.Enum.ZIndexBehavior.Sibling
		local backBtn = e.Instance.new("TextButton", sgHigh)
		backBtn.ZIndex = 1
		backBtn.Size = e.UDim2.fromOffset(100, 100)
		local frontBtn = e.Instance.new("TextButton", sgHigh)
		frontBtn.ZIndex = 10
		frontBtn.Size = e.UDim2.fromOffset(100, 100)

		local hits: { string } = {}
		lowBtn.Activated:Connect(function() table.insert(hits, "low") end)
		backBtn.Activated:Connect(function() table.insert(hits, "back") end)
		frontBtn.Activated:Connect(function() table.insert(hits, "front") end)
		frontBtn.MouseButton2Click:Connect(function() table.insert(hits, "front:mb2") end)

		inp:click(e.Vector2.new(30, 30))
		inp:click(e.Vector2.new(30, 30), e.Enum.UserInputType.MouseButton2)
		sert.eq(hits, { "front", "front:mb2" })

		-- Mouse button press/release state & hidden/disabled click errors
		inp:press(e.Enum.UserInputType.MouseButton1)
		sert.eq(uis:IsMouseButtonPressed(e.Enum.UserInputType.MouseButton1), true)
		sert.eq(#uis:GetMouseButtonsPressed(), 1)
		inp:release(e.Enum.UserInputType.MouseButton1)
		sert.eq(uis:IsMouseButtonPressed(e.Enum.UserInputType.MouseButton1), false)

		frontBtn.Visible = false
		sert.throws(function() inp:click(frontBtn) end, "not visible")
		backBtn.Interactable = false
		sert.throws(function() inp:click(backBtn) end, "not interactable")

		-- TextBox Return key submits FocusLost(true); clicking empty space releases with FocusLost(false)
		local box = e.Instance.new("TextBox", sgHigh)
		box.Position = e.UDim2.fromOffset(200, 20)
		box.Size = e.UDim2.fromOffset(100, 30)
		local submittedLog: { boolean } = {}
		box.FocusLost:Connect(function(enterPressed: boolean) table.insert(submittedLog, enterPressed) end)

		inp:click(box)
		sert.eq(box:IsFocused(), true)
		inp:type("cmd")
		inp:press(e.Enum.KeyCode.Return)
		inp:release(e.Enum.KeyCode.Return)
		sert.eq(box:IsFocused(), false)
		sert.eq(submittedLog, { true })

		inp:click(box)
		inp:click(e.Vector2.new(600, 500))
		sert.eq(submittedLog, { true, false })
	end)

	test(
		"replicates nested subtrees, Instance refs, props, attributes, tags, Destroy, RemoteFunction & UnreliableRemoteEvent",
		function()
			local w = sert.sim.new({ seed = 11, instant = true })
			local srv = w:server()
			local cli = srv:client(202)
			local sEnv = srv:env()
			local cEnv = cli:env()

			-- Build nested Model on server with PrimaryPart, Instance attribute, scalar attributes, and tags
			local sModel = sEnv.Instance.new("Model")
			sModel.Name = "Boss"
			sModel:SetAttribute("Phase", 1)
			local sCore = sEnv.Instance.new("Part", sModel)
			sCore.Name = "Core"
			sCore.Size = sEnv.Vector3.new(6, 6, 6)
			sModel.PrimaryPart = sCore
			local sRef = sEnv.Instance.new("ObjectValue", sModel)
			sRef.Name = "CoreRef"
			sRef.Value = sCore
			sModel.Parent = sEnv.workspace
			sModel:AddTag("Enemy")

			local cModel = cEnv.workspace:FindFirstChild("Boss") :: any
			sert.ok(cModel ~= nil and cModel ~= sModel)
			local cCore = cModel:FindFirstChild("Core") :: any
			local cRef = cModel:FindFirstChild("CoreRef") :: any
			sert.ok(cCore ~= nil and cCore ~= sCore)
			sert.eq(cModel.PrimaryPart, cCore)
			sert.eq(cRef.Value, cCore)
			sert.eq(cModel:GetAttribute("Phase"), 1)
			sert.eq(cModel:HasTag("Enemy"), true)
			sert.eq(cEnv:getService("CollectionService"):GetTagged("Enemy"), { cModel })

			-- Live property, attribute, and tag updates replicate to client
			sCore.Size = sEnv.Vector3.new(10, 10, 10)
			sModel:SetAttribute("Phase", 2)
			sModel:AddTag("Enraged")
			sModel:RemoveTag("Enemy")
			sert.eq(cCore.Size, cEnv.Vector3.new(10, 10, 10))
			sert.eq(cModel:GetAttribute("Phase"), 2)
			sert.eq(cModel:HasTag("Enraged"), true)
			sert.eq(cModel:HasTag("Enemy"), false)

			-- Moving referenced part to non-replicated ServerStorage clears client Instance refs cleanly
			sCore.Parent = sEnv:getService("ServerStorage")
			sert.eq(cCore.Parent, nil)
			sert.eq(cModel.PrimaryPart, nil)
			sert.eq(cRef.Value, nil)

			-- Destroying server instance destroys mirrored client instance
			sModel:Destroy()
			sert.eq(cModel.Parent, nil)

			-- RemoteFunction (Server <-> Client) and UnreliableRemoteEvent + dynamic rename
			local sRf = sEnv.Instance.new("RemoteFunction")
			sRf.Name = "QueryStats"
			sRf.Parent = sEnv:getService("ReplicatedStorage")
			sRf.OnServerInvoke = function(plr: any, key: string) return `{plr.UserId}:{key}`, 99 end

			local cRf = cEnv:getService("ReplicatedStorage"):FindFirstChild("QueryStats") :: any
			cRf.OnClientInvoke = function(ping: number) return ping * 2 end

			local tag: any, score: any = nil, nil
			cli:spawn(function()
				tag, score = cRf:InvokeServer("xp")
			end)
			w:run(0.5)
			sert.eq(tag, "202:xp")
			sert.eq(score, 99)

			local pong: any = nil
			local sPlr = sEnv.Players:GetPlayerByUserId(202)
			srv:spawn(function() pong = sRf:InvokeClient(sPlr, 21) end)
			w:run(0.5)
			sert.eq(pong, 42)

			local sUre = sEnv.Instance.new("UnreliableRemoteEvent", sEnv:getService("ReplicatedStorage"))
			sUre.Name = "FastState"
			local cUre = cEnv:getService("ReplicatedStorage"):FindFirstChild("FastState") :: any
			local srvTicks: { number } = {}
			local cliTicks: { number } = {}
			sUre.OnServerEvent:Connect(function(_p: any, seq: number) table.insert(srvTicks, seq) end)
			cUre.OnClientEvent:Connect(function(seq: number) table.insert(cliTicks, seq) end)

			cUre:FireServer(1)
			sUre:FireAllClients(2)
			w:step()
			sert.eq(srvTicks, { 1 })
			sert.eq(cliTicks, { 2 })
		end
	)

	test("handles RBXScriptSignal Once auto-disconnect, Wait multi-arg resume, and mid-fire Disconnect", function()
		local e = sert.env.new()
		local sig = e:signal()
		local onceHits = 0
		local onceConn = sig:Once(function(v: number)
			onceHits += v
		end)
		sert.eq(sig:connected(), true)
		sert.eq(sig:connections(), 1)

		sig:Fire(10)
		sig:Fire(20)
		e:flush()
		sert.eq(onceHits, 10)
		sert.eq(onceConn.Connected, false)
		sert.eq(sig:connected(), false)

		-- Wait on main thread steps virtual scheduler until delayed Fire delivers multiple args
		e.task.delay(0.1, function() sig:Fire("ready", 42, true) end)
		local a, b, c = sig:Wait()
		sert.eq(a, "ready")
		sert.eq(b, 42)
		sert.eq(c, true)

		-- Wait inside spawned coroutine + DisconnectAll
		local coTag = ""
		local coNum = 0
		e.task.spawn(function()
			local x, y = sig:Wait()
			coTag = x
			coNum = y
		end)
		sig:Fire("co", 7)
		e:flush()
		sert.eq(coTag, "co")
		sert.eq(coNum, 7)

		-- Immediate mode: disconnecting a sibling connection inside a callback skips the disconnected listener
		local imm = sert.env.new({ signalBehavior = "Immediate" })
		local iSig = imm:signal()
		local log: { string } = {}
		local secondConn: any = nil
		iSig:Connect(function()
			table.insert(log, "first")
			if secondConn ~= nil then secondConn:Disconnect() end
		end)
		secondConn = iSig:Connect(function() table.insert(log, "second") end)
		iSig:Fire()
		sert.eq(log, { "first" })

		iSig:DisconnectAll()
		sert.eq(iSig:connections(), 0)

		-- Pre-parenting tags replicate in exact insertion order when mounted into ReplicatedStorage
		local w = sert.sim.new()
		local srvNode = w:server()
		local cliNode = srvNode:client(55, { name = "TagPeer" })
		local srv = srvNode:env()
		local cli = cliNode:env()
		local preTagged = srv.Instance.new("Folder")
		preTagged.Name = "PreTagged"
		preTagged:AddTag("Zeta")
		preTagged:AddTag("Alpha")
		preTagged.Parent = srv.game:GetService("ReplicatedStorage")
		w:advance(0.05)
		local cliCopy = cli.game:GetService("ReplicatedStorage"):FindFirstChild("PreTagged")
		sert.ok(cliCopy ~= nil)
		sert.eq((cliCopy :: Instance):HasTag("Zeta"), true)
		sert.eq((cliCopy :: Instance):HasTag("Alpha"), true)

		-- Function modules via env:require, scheduler = false mode, standalone RemoteFunction, AutomaticSize raw children, and rebuildValue
		local calls = 0
		local fnMod = function(modEnv: any)
			calls += 1
			return { ws = modEnv.workspace, n = calls }
		end
		local r1 = e:require(fnMod)
		local r2 = e:require(fnMod)
		sert.eq(r1.ws, e.workspace)
		sert.eq(r1.n, 1)
		sert.eq(r2.n, 1)
		local nilMod = function(_modEnv: any): any return nil end
		sert.eq(e:require(nilMod), nil)
		sert.eq(e:require(nilMod), nil)
		sert.throws(function()
			e:require(function(_modEnv: any): (number, number) return 1, 2 end)
		end, "one value")

		-- External scheduler = false mode + active env service lookup
		local ext = sert.env.new({ scheduler = false })
		sert.gt(ext:step(1 / 60), 0)
		sert.eq(ext:advance(0.5), 0.5)
		sert.eq(sert.env.getService("Workspace"), ext.workspace)

		-- Standalone single-env RemoteFunction InvokeServer & InvokeClient
		local rf = e.Instance.new("RemoteFunction", e.game:GetService("ReplicatedStorage"))
		rf.OnServerInvoke = function(_plr: any, x: number, y: number?) return x * 10, y end
		local sRes1, sRes2 = rf:InvokeServer(4, nil)
		sert.eq(sRes1, 40)
		sert.eq(sRes2, nil)
		rf.OnClientInvoke = function(msg: string) return `{msg}:ack` end
		local fakePlr = e:addPlayer(88, "SoloPeer")
		sert.eq(rf:InvokeClient(fakePlr, "ping"), "ping:ack")

		-- AutomaticSize.XY container with raw positioned GuiObject children (no list/grid layout)
		local sg = e.Instance.new("ScreenGui", fakePlr:FindFirstChildOfClass("PlayerGui"))
		local autoBox = e.Instance.new("Frame", sg)
		autoBox.AutomaticSize = e.Enum.AutomaticSize.XY
		local rawChild = e.Instance.new("Frame", autoBox)
		rawChild.Position = e.UDim2.fromOffset(15, 20)
		rawChild.Size = e.UDim2.fromOffset(60, 30)
		e:step(1 / 60)
		sert.ge(autoBox.AbsoluteSize.X, 75)
		sert.ge(autoBox.AbsoluteSize.Y, 50)

		-- Custom datatypes table triggering rebuildValue across Sequence, Font, CFrame, BrickColor, Rect, NumberRange
		local Datatypes = require("../src/engine/datatypes")
		local customDt = table.clone(Datatypes :: any)
		local dtEnv = sert.env.new({ datatypes = customDt })
		local pe = dtEnv.Instance.new("ParticleEmitter")
		local grad = dtEnv.Instance.new("UIGradient")
		local lbl = dtEnv.Instance.new("TextLabel")
		local part = dtEnv.Instance.new("Part")
		sert.ok(pe ~= nil and grad ~= nil and lbl.FontFace ~= nil and part.BrickColor ~= nil)

		-- Attachment WorldPosition / Orientation / WorldOrientation under strict = true + loader string compile error surfacing
		local att = e.Instance.new("Attachment", part)
		att.WorldPosition = e.Vector3.new(3, 4, 5)
		att.Orientation = e.Vector3.new(0, 90, 0)
		sert.eq(att.WorldPosition, e.Vector3.new(3, 4, 5))
		sert.eq(att.Orientation, e.Vector3.new(0, 90, 0))
		local brokenMod: any = e.Instance.new("ModuleScript", e.game:GetService("ReplicatedStorage"))
		brokenMod.Name = "BrokenLexical"
		rawset(brokenMod, "_loader", function() return "syntax error: unexpected symbol" end)
		sert.throws(function() e:require(brokenMod) end, "failed to load: syntax error: unexpected symbol")
	end)
end)

describe("Wave 2 env features: 3D spatial SAT/casts, InputContext/Actions, Parallel Actors, Audio", function()
	test(
		"Workspace supports exact 3D OBB SAT, Ball/Cylinder raycasts, Blockcast/Spherecast/Shapecast, CollisionGroups, and BruteForceAllSlow",
		function()
			local e = sert.env.new()
			local ws = e.workspace
			local V3, CF, Enum = e.Vector3, e.CFrame, e.Enum
			local phys = e:getService("PhysicsService")

			-- 1) Rotated OBB 15-axis SAT: diagonally tilted thin slats whose world AABBs overlap yet are 3D disjoint vs intersecting
			local rotA = e.Instance.new("Part", ws)
			rotA.Name = "RotA"
			rotA.Size = V3.new(10, 1, 1)
			rotA.CFrame = CF.new(0, 5, 0) * CF.Angles(0, math.rad(45), 0)

			-- Parallel +45-deg slat offset perpendicular to its length along (+0.707, 0, +0.707): world AABBs overlap strongly, OBBs do NOT touch
			local rotDisjoint = e.Instance.new("Part", ws)
			rotDisjoint.Name = "RotDisjoint"
			rotDisjoint.Size = V3.new(10, 1, 1)
			rotDisjoint.CFrame = CF.new(2, 5, 2) * CF.Angles(0, math.rad(45), 0)

			local paramsA = e.RaycastParams.new()
			local ovParams = e.OverlapParams.new()
			ovParams.FilterType = Enum.RaycastFilterType.Include
			ovParams.FilterDescendantsInstances = { rotDisjoint }

			local hitsDisjoint = ws:GetPartsInPart(rotA, ovParams)
			sert.eq(hitsDisjoint, {})

			ovParams.FilterDescendantsInstances = { rotA, rotDisjoint }
			local rotTouch = e.Instance.new("Part", ws)
			rotTouch.Name = "RotTouch"
			rotTouch.Size = V3.new(2, 1, 2)
			rotTouch.CFrame = CF.new(0.4, 5, 0.4) * CF.Angles(0, math.rad(45), 0)
			ovParams.FilterDescendantsInstances = { rotA, rotDisjoint }
			sert.eq(ws:GetPartsInPart(rotTouch, ovParams), { rotA })

			-- 12-edge rotated probe intersecting RotA around corner
			local boxHits = ws:GetPartBoundsInBox(
				CF.new(0, 5, 0) * CF.Angles(math.rad(20), math.rad(45), 0),
				V3.new(2, 2, 2),
				ovParams
			)
			sert.eq(boxHits, { rotA })

			-- Closest-point radius query near rotated tip (diagonal corner around (3.535, 5, -3.535))
			local radHits = ws:GetPartBoundsInRadius(V3.new(4.2, 5, -4.2), 1.5, ovParams)
			sert.eq(radHits, { rotA })
			local radMiss = ws:GetPartBoundsInRadius(V3.new(6.5, 5, -6.5), 0.5, ovParams)
			sert.eq(radMiss, {})

			-- 2) Exact Ball & X-axis Cylinder Raycasts
			local ball = e.Instance.new("Part", ws)
			ball.Name = "SphereTarget"
			ball.Shape = Enum.PartType.Ball
			ball.Size = V3.new(6, 6, 6)
			ball.CFrame = CF.new(30, 3, 0)
			ball.Material = Enum.Material.Neon

			local ballParams = e.RaycastParams.new()
			ballParams.FilterType = Enum.RaycastFilterType.Include
			ballParams.FilterDescendantsInstances = { ball }
			local rBall = ws:Raycast(V3.new(20, 3, 0), V3.new(20, 0, 0), ballParams)
			sert.ok(rBall ~= nil)
			sert.eq(rBall.Instance, ball)
			sert.near(rBall.Distance, 7, 1e-4)
			sert.near(rBall.Position, V3.new(27, 3, 0), 1e-4)
			sert.near(rBall.Normal, V3.new(-1, 0, 0), 1e-4)
			sert.eq(rBall.Material, Enum.Material.Neon)
			-- Corners inside sphere's bounding box must still miss true sphere geometry
			sert.eq(ws:Raycast(V3.new(20, 5.9, 2.9), V3.new(20, 0, 0), ballParams), nil)

			-- X-axis Cylinder rotated 90 deg around Z so its flat endcaps face +/-Y and curved barrel lies in XZ!
			local cyl = e.Instance.new("Part", ws)
			cyl.Name = "CylTarget"
			cyl.Shape = Enum.PartType.Cylinder
			cyl.Size = V3.new(8, 4, 4) -- length 8 on local X (-> world Y), radius 2 on YZ (-> world XZ)
			cyl.CFrame = CF.new(50, 4, 0) * CF.Angles(0, 0, math.rad(90))
			cyl.Material = Enum.Material.Metal

			local cylParams = e.RaycastParams.new()
			cylParams.FilterType = Enum.RaycastFilterType.Include
			cylParams.FilterDescendantsInstances = { cyl }
			local rCylSide = ws:Raycast(V3.new(44, 4, 0), V3.new(12, 0, 0), cylParams)
			sert.ok(rCylSide ~= nil)
			sert.near(rCylSide.Distance, 4, 1e-4)
			sert.near(rCylSide.Position, V3.new(48, 4, 0), 1e-4)
			sert.near(rCylSide.Normal, V3.new(-1, 0, 0), 1e-4)

			local rCylCap = ws:Raycast(V3.new(50, 12, 0), V3.new(0, -10, 0), cylParams)
			sert.ok(rCylCap ~= nil)
			sert.near(rCylCap.Distance, 4, 1e-4)
			sert.near(rCylCap.Position, V3.new(50, 8, 0), 1e-4)
			sert.near(rCylCap.Normal, V3.new(0, 1, 0), 1e-4)
			-- Bounding-box corner of cylinder (x=-1.7, z=1.9 -> dist^2=6.5 > r^2=4) misses circular cross-section
			sert.eq(ws:Raycast(V3.new(48.3, 12, 1.9), V3.new(0, -10, 0), cylParams), nil)
			-- Cylinder vs Box SAT overlap
			ovParams.FilterDescendantsInstances = { cyl }
			sert.eq(ws:GetPartBoundsInBox(CF.new(52.5, 4, 0), V3.new(2, 2, 2), ovParams), { cyl })

			-- 3) Blockcast, Spherecast, and Shapecast (plus initial overlap returning nil)
			local floor = e.Instance.new("Part", ws)
			floor.Name = "CastWall"
			floor.Size = V3.new(6, 6, 6)
			floor.CFrame = CF.new(0, 20, 0)
			floor.Material = Enum.Material.Concrete

			local castParams = e.RaycastParams.new()
			castParams.FilterType = Enum.RaycastFilterType.Include
			castParams.FilterDescendantsInstances = { floor, ball, cyl }

			local bHit = ws:Blockcast(CF.new(-10, 20, 0), V3.new(2, 2, 2), V3.new(20, 0, 0), castParams)
			sert.ok(bHit ~= nil)
			sert.eq(bHit.Instance, floor)
			sert.near(bHit.Distance, 6, 1e-3)
			sert.near(bHit.Position, V3.new(-3, 20, 0), 1e-2)
			sert.near(bHit.Normal, V3.new(-1, 0, 0), 1e-3)

			-- Initial intersection returns nil
			sert.eq(ws:Blockcast(CF.new(0, 20, 0), V3.new(2, 2, 2), V3.new(5, 0, 0), castParams), nil)

			-- Spherecast hitting corner Voronoi sphere of CastWall
			local sCornerHit = ws:Spherecast(V3.new(-6, 26, -6), 1, V3.new(10, -10, 10), castParams)
			sert.ok(sCornerHit ~= nil)
			sert.eq(sCornerHit.Instance, floor)
			sert.near(sCornerHit.Position, V3.new(-3, 23, -3), 1e-2)
			sert.near(sCornerHit.Normal, V3.new(-1, 1, -1).Unit, 1e-2)

			-- Shapecast with a Ball probe against Ball target and a Cylinder probe against Box target
			local sphereProbe = e.Instance.new("Part", ws)
			sphereProbe.Shape = Enum.PartType.Ball
			sphereProbe.Size = V3.new(2, 2, 2)
			sphereProbe.CFrame = CF.new(20, 3, 0)
			local scBall = ws:Shapecast(sphereProbe, V3.new(20, 0, 0), ballParams)
			sert.ok(scBall ~= nil)
			sert.eq(scBall.Instance, ball)
			sert.near(scBall.Distance, 6, 1e-2)
			sert.near(scBall.Normal, V3.new(-1, 0, 0), 1e-2)

			local cylProbe = e.Instance.new("Part", ws)
			cylProbe.Shape = Enum.PartType.Cylinder
			cylProbe.Size = V3.new(2, 2, 2)
			cylProbe.CFrame = CF.new(-10, 20, 0)
			castParams.FilterDescendantsInstances = { floor }
			local scCyl = ws:Shapecast(cylProbe, V3.new(20, 0, 0), castParams)
			sert.ok(scCyl ~= nil)
			sert.eq(scCyl.Instance, floor)
			sert.near(scCyl.Distance, 6, 0.05)

			-- 4) PhysicsService CollisionGroup + BruteForceAllSlow
			phys:RegisterCollisionGroup("Heroes")
			phys:RegisterCollisionGroup("Lasers")
			phys:CollisionGroupSetCollidable("Heroes", "Lasers", false)
			sert.eq(phys:CollisionGroupsAreCollidable("Heroes", "Lasers"), false)

			local ghostPart = e.Instance.new("Part", ws)
			ghostPart.Size = V3.new(4, 4, 4)
			ghostPart.CFrame = CF.new(100, 0, 0)
			ghostPart.CollisionGroup = "Heroes"
			ghostPart.CanQuery = false

			paramsA.FilterType = Enum.RaycastFilterType.Include
			paramsA.FilterDescendantsInstances = { ghostPart }
			paramsA.CollisionGroup = "Lasers"
			-- Filtered by both CanQuery == false and non-collidable group
			sert.eq(ws:Raycast(V3.new(90, 0, 0), V3.new(20, 0, 0), paramsA), nil)

			paramsA.CollisionGroup = "Heroes" -- collidable with itself, still blocked by CanQuery == false
			sert.eq(ws:Raycast(V3.new(90, 0, 0), V3.new(20, 0, 0), paramsA), nil)

			paramsA.BruteForceAllSlow = true
			local bfHit = ws:Raycast(V3.new(90, 0, 0), V3.new(20, 0, 0), paramsA)
			sert.ok(bfHit ~= nil and bfHit.Instance == ghostPart)

			-- RenameCollisionGroup updates references; UnregisterCollisionGroup removes group
			phys:RenameCollisionGroup("Heroes", "Players")
			sert.ok(phys:IsCollisionGroupRegistered("Players"))
			sert.eq(phys:IsCollisionGroupRegistered("Heroes"), false)
			sert.eq(phys:CollisionGroupsAreCollidable("Players", "Lasers"), false)
			sert.ok(#phys:GetRegisteredCollisionGroups() >= 3)
			phys:UnregisterCollisionGroup("Players")
			phys:UnregisterCollisionGroup("Lasers")
		end
	)

	test(
		"env:input() evaluates InputContexts in Priority/Sink order for KeyCode, directional composites, and UIButton",
		function()
			local e = sert.env.new({ isClient = true, isServer = false })
			local starterGui = e:getService("StarterGui")
			local pg = e.LocalPlayer:FindFirstChildOfClass("PlayerGui")
			local sg = e.Instance.new("ScreenGui", pg)
			local btn = e.Instance.new("TextButton", sg)
			btn.Position = e.UDim2.fromOffset(10, 10)
			btn.Size = e.UDim2.fromOffset(100, 40)

			local menuCtx = e.Instance.new("InputContext", starterGui)
			menuCtx.Name = "Menu"
			menuCtx.Priority = 2000
			menuCtx.Sink = true
			menuCtx.Enabled = true

			local closeAct = e.Instance.new("InputAction", menuCtx)
			closeAct.Type = e.Enum.InputActionType.Bool
			local closeBind = e.Instance.new("InputBinding", closeAct)
			closeBind.KeyCode = e.Enum.KeyCode.Escape

			local gameCtx = e.Instance.new("InputContext", starterGui)
			gameCtx.Name = "Gameplay"
			gameCtx.Priority = 1000
			gameCtx.Sink = false
			gameCtx.Enabled = true

			local pauseAct = e.Instance.new("InputAction", gameCtx)
			pauseAct.Type = e.Enum.InputActionType.Bool
			local pauseBind = e.Instance.new("InputBinding", pauseAct)
			pauseBind.KeyCode = e.Enum.KeyCode.Escape

			local move2Act = e.Instance.new("InputAction", gameCtx)
			move2Act.Type = e.Enum.InputActionType.Direction2D
			local wasd = e.Instance.new("InputBinding", move2Act)
			wasd.Up = e.Enum.KeyCode.W
			wasd.Down = e.Enum.KeyCode.S
			wasd.Left = e.Enum.KeyCode.A
			wasd.Right = e.Enum.KeyCode.D
			wasd.Scale = 2

			local move3Act = e.Instance.new("InputAction", gameCtx)
			move3Act.Type = e.Enum.InputActionType.Direction3D
			local bind3 = e.Instance.new("InputBinding", move3Act)
			bind3.Forward = e.Enum.KeyCode.I
			bind3.Right = e.Enum.KeyCode.L
			bind3.Up = e.Enum.KeyCode.U

			local btnAct = e.Instance.new("InputAction", gameCtx)
			btnAct.Type = e.Enum.InputActionType.Bool
			local btnBind = e.Instance.new("InputBinding", btnAct)
			btnBind.UIButton = btn

			local fired: { string } = {}
			closeAct.Pressed:Connect(function() table.insert(fired, "close:down") end)
			pauseAct.Pressed:Connect(function() table.insert(fired, "pause:down") end)
			btnAct.Pressed:Connect(function() table.insert(fired, "btn:down") end)
			btnAct.Released:Connect(function() table.insert(fired, "btn:up") end)

			local inp = e:input()
			-- Menu context has higher priority + Sink = true: Escape hits Close, sinks Pause
			inp:press(e.Enum.KeyCode.Escape)
			e:flush()
			sert.eq(fired, { "close:down" })
			sert.eq(closeAct:GetState(), true)
			sert.eq(pauseAct:GetState(), false)
			inp:release(e.Enum.KeyCode.Escape)
			e:flush()

			-- Disable Menu context -> Escape flows to Gameplay Pause
			menuCtx.Enabled = false
			inp:press(e.Enum.KeyCode.Escape)
			e:flush()
			sert.eq(pauseAct:GetState(), true)
			sert.eq(fired, { "close:down", "pause:down" })
			inp:release(e.Enum.KeyCode.Escape)
			e:flush()

			-- 2D & 3D directional composite bindings normalize before multiplying Scale
			inp:press(e.Enum.KeyCode.W)
			inp:press(e.Enum.KeyCode.D)
			inp:press(e.Enum.KeyCode.I)
			inp:press(e.Enum.KeyCode.L)
			inp:press(e.Enum.KeyCode.U)
			e:flush()
			sert.near(move2Act:GetState(), e.Vector2.new(1, 1).Unit * 2, 1e-4)
			sert.near(move3Act:GetState(), e.Vector3.new(1, 1, -1).Unit, 1e-4)
			inp:release(e.Enum.KeyCode.W)
			inp:release(e.Enum.KeyCode.D)
			e:flush()
			sert.eq(move2Act:GetState(), e.Vector2.zero)

			-- UIButton binding via env:input():click(btn)
			inp:click(btn)
			e:flush()
			sert.eq(fired, { "close:down", "pause:down", "btn:down", "btn:up" })
		end
	)

	test(
		"SharedTableRegistry, Actor:GetActor(), and task.desynchronize/synchronize enforce strict parallel mutation safety",
		function()
			local e = sert.env.new()
			local reg = e:getService("SharedTableRegistry")
			local st = e.SharedTable.new({ count = 1 })
			reg:SetSharedTable("CombatStats", st)
			sert.eq(reg:GetSharedTable("CombatStats"), st)
			-- Calling GetSharedTable for an unregistered name auto-creates an empty SharedTable
			local autoCreated = reg:GetSharedTable("FreshTable")
			sert.eq(e.SharedTable.size(autoCreated), 0)

			local actor = e.Instance.new("Actor", e.workspace)
			local mod = e.Instance.new("ModuleScript", actor)
			local part = e.Instance.new("Part", actor)
			part.Name = "SafePart"
			sert.eq(mod:GetActor(), actor)
			sert.eq(part:GetActor(), actor)
			sert.eq(e.workspace:GetActor(), nil)

			-- Require a module whose script global has :GetActor() and exercises desynchronize()/synchronize()
			local parallelErr: any = nil
			rawset(mod :: any, "_factory", function(modEnv: any): boolean
				sert.eq(modEnv.script:GetActor(), actor)
				modEnv.task.desynchronize()
				-- Safe read + SharedTable mutations succeed while desynchronized
				sert.eq(part.Name, "SafePart")
				e.SharedTable.increment(st, "count", 4)
				-- Serial DOM mutation under strict = true raises parallel safety error
				local ok, err = pcall(function() part.Name = "MutatedInParallel" end)
				sert.eq(ok, false)
				parallelErr = err
				local okNew = pcall(function() e.Instance.new("Part") end)
				sert.eq(okNew, false)
				local okDestroy = pcall(function() part:Destroy() end)
				sert.eq(okDestroy, false)

				modEnv.task.synchronize()
				part.Name = "SynchronizedWrite"
				return true
			end)
			local modResult = e:require(mod)
			sert.eq(modResult, true)
			sert.matches(tostring(parallelErr), "not safe to write or call in parallel")
			sert.eq(st.count, 5)
			sert.eq(part.Name, "SynchronizedWrite")

			-- Non-strict env skips parallel write error
			local lenient = sert.env.new({ strict = false })
			local lp = lenient.Instance.new("Part", lenient.workspace)
			lenient.task.desynchronize()
			lp.Name = "LenientParallel"
			lenient.task.synchronize()
			sert.eq(lp.Name, "LenientParallel")
		end
	)

	test(
		"AudioPlayer advances on virtual clock with PlaybackRegion/Looped/Ended and feeds Fader/Analyzer/Emitter/Listener",
		function()
			local e = sert.env.new()
			local emitterHost = e.Instance.new("Part", e.workspace)
			emitterHost.CFrame = e.CFrame.new(0, 0, 0)
			local listenerHost = e.Instance.new("Part", e.workspace)
			listenerHost.CFrame = e.CFrame.new(0, 0, 10)

			local player = e.Instance.new("AudioPlayer", e.workspace)
			sert.eq(player.TimeLength, 1)
			sert.throws(function() (player :: any).TimeLength = 2 end, "read only")
			player.PlaybackRegion = e.NumberRange.new(0, 1.0)
			player.Volume = 0.8

			local fader = e.Instance.new("AudioFader", e.workspace)
			fader.Volume = 0.5

			local analyzer = e.Instance.new("AudioAnalyzer", e.workspace)
			local emitter = e.Instance.new("AudioEmitter", emitterHost)
			emitter.DistanceAttenuationBounds = e.NumberRange.new(0, 20)
			local listener = e.Instance.new("AudioListener", listenerHost)
			local outDev = e.Instance.new("AudioDeviceOutput", e.workspace)

			local w1 = e.Instance.new("Wire", e.workspace)
			w1.SourceInstance, w1.TargetInstance = player, fader
			local w2 = e.Instance.new("Wire", e.workspace)
			w2.SourceInstance, w2.TargetInstance = fader, analyzer
			local w3 = e.Instance.new("Wire", e.workspace)
			w3.SourceInstance, w3.TargetInstance = fader, emitter
			local w4 = e.Instance.new("Wire", e.workspace)
			w4.SourceInstance, w4.TargetInstance = listener, outDev
			sert.ok(w1.Connected and w2.Connected and w3.Connected and w4.Connected)

			local events: { string } = {}
			player.Looped:Connect(function() table.insert(events, "looped") end)
			player.Ended:Connect(function() table.insert(events, "ended") end)

			-- Play for 0.4s and sample AudioAnalyzer Peak/Rms/Spectrum + Emitter/Listener attenuation
			player:Play()
			sert.eq(player.IsPlaying, true)
			sert.near(analyzer.PeakLevel, 0.4, 1e-4)
			sert.near(analyzer.RmsLevel, 0.4 * 0.70710678, 1e-4)
			sert.near(analyzer:GetSpectrum()[1], 0.4, 1e-4)
			sert.near(emitter:GetAudibilityFor(listener), 0.5, 1e-4)
			sert.eq(emitter:GetInteractingListeners(), { listener })
			sert.eq(listener:GetInteractingEmitters(), { emitter })

			emitter:SetDistanceAttenuation({ [0] = 1, [20] = 0 })
			sert.eq(emitter:GetDistanceAttenuation()[20], 0)
			emitter:SetAngleAttenuation({ [0] = 1, [90] = 0.25 })
			sert.eq(emitter:GetAngleAttenuation()[90], 0.25)

			e:step(0.4)
			sert.near(player.TimePosition, 0.4, 1e-4)
			sert.eq(player.IsPlaying, true)

			-- Advance past TimeLength -> stops, sets TimePosition = 1.0, fires Ended
			e:step(0.7)
			e:flush()
			sert.eq(player.IsPlaying, false)
			sert.near(player.TimePosition, 1.0, 1e-4)
			sert.eq(events, { "ended" })
			sert.eq(analyzer.PeakLevel, 0)

			-- Looping playback fires Looped and wraps within LoopRegion
			player.Looping = true
			player.LoopRegion = e.NumberRange.new(0.2, 0.6)
			player:Play(0.3)
			e:step(0.5) -- 0.3 + 0.5 = 0.8 >= 0.6 -> wraps once to 0.4
			e:flush()
			sert.eq(player.IsPlaying, true)
			sert.near(player.TimePosition, 0.4, 1e-4)
			sert.eq(events, { "ended", "looped" })
			player:Stop()
			sert.eq(player.IsPlaying, false)

			-- Destroying target disconnects Wire automatically
			fader:Destroy()
			sert.eq(w1.Connected, false)
		end
	)
end)

describe("InputAction, Audio.hasPlaying, _immediateSignal, and mutant waitGuard", function()
	test("InputAction.PreferredBinding resolves dynamically from live child InputBindings", function()
		local e = sert.env.new({ isClient = true, isServer = false, signalBehavior = "Immediate" })
		local ctx = e.Instance.new("InputContext", e.workspace)
		local action = e.Instance.new("InputAction", ctx)
		action.Type = e.Enum.InputActionType.Bool
		local nonBinding = e.Instance.new("Folder", action)
		sert.eq(nonBinding.Parent, action)
		sert.eq(action.PreferredBinding, nil)

		local b1 = e.Instance.new("InputBinding", action)
		b1.KeyCode = e.Enum.KeyCode.E
		sert.eq(action.PreferredBinding, b1)

		local b2 = e.Instance.new("InputBinding", action)
		b2.KeyCode = e.Enum.KeyCode.F
		sert.eq(action.PreferredBinding, b1)

		b1:Destroy()
		sert.eq(action.PreferredBinding, b2)

		b2.Parent = nil
		sert.eq(action.PreferredBinding, nil)
	end)

	test("Audio.hasPlaying tracks active AudioPlayer state in env", function()
		local Audio = require("../src/engine/audio")
		local e = sert.env.new({ signalBehavior = "Immediate" })
		sert.eq(Audio.hasPlaying(e), false)

		local player = e.Instance.new("AudioPlayer", e.workspace)
		sert.eq(Audio.hasPlaying(e), false)

		player:Play()
		sert.eq(Audio.hasPlaying(e), true)

		player:Stop()
		sert.eq(Audio.hasPlaying(e), false)
	end)

	test("_immediateSignal delivers synchronously even when env signalBehavior is Deferred", function()
		local e = sert.env.new()
		sert.eq(e.signalBehavior, "Deferred")
		local sig = (e :: any):_immediateSignal()
		local seen: { string } = {}
		sig:Connect(function(tag: string) table.insert(seen, tag) end)
		sig:Fire("immediate")
		sert.eq(seen, { "immediate" })
	end)

	test("registry.mutant.waitGuard enforces wait limit only while mutant id is active", function()
		local registry = require("../src/core/registry")
		sert.defer(function() registry.mutant.set(nil) end)

		registry.mutant.set(nil)
		for _ = 1, 10 do
			registry.mutant.waitGuard()
		end

		registry.mutant.set(42)
		for _ = 1, 25000 do
			registry.mutant.waitGuard()
		end
		sert.throws(function() registry.mutant.waitGuard() end, "task.wait loop limit exceeded")

		registry.mutant.set(nil)
		registry.mutant.waitGuard()
	end)
end)

describe("M3b engine parity: Attributes, NaN, Destroy, Clone, WaitForChild, UI, Parallel & PluginSecurity", function()
	test(
		"SetAttribute rejects Instance, NaN->NaN suppresses redundant Changed signals, and Destroying runs synchronously before child teardown",
		function()
			local e = sert.env.new({ signalBehavior = "Deferred" })
			local parent = e.Instance.new("Folder", e.workspace)
			local child = e.Instance.new("Folder", parent)
			local refTarget = e.Instance.new("Part", e.workspace)

			sert.throws(function() parent:SetAttribute("Ref", refTarget) end, "not a supported attribute type")

			-- NaN -> NaN no-op on both Numeric property and attribute
			local numVal = e.Instance.new("NumberValue", parent)
			local propChanges = 0
			numVal:GetPropertyChangedSignal("Value"):Connect(function()
				propChanges += 1
			end)
			numVal.Value = 0 / 0
			e:flush()
			sert.eq(propChanges, 1)
			numVal.Value = 0 / 0
			e:flush()
			sert.eq(propChanges, 1)

			local attrChanges = 0
			parent:GetAttributeChangedSignal("Nano"):Connect(function()
				attrChanges += 1
			end)
			parent:SetAttribute("Nano", 0 / 0)
			e:flush()
			sert.eq(attrChanges, 1)
			parent:SetAttribute("Nano", 0 / 0)
			e:flush()
			sert.eq(attrChanges, 1)

			-- Destroying fires synchronously BEFORE Parent == nil and BEFORE child Destroy cascades under Deferred mode
			local events: { string } = {}
			parent.Destroying:Connect(
				function()
					table.insert(
						events,
						"parent:" .. tostring(parent.Parent ~= nil) .. ":" .. tostring(child.Parent == parent)
					)
				end
			)
			child.Destroying:Connect(function() table.insert(events, "child") end)
			parent:Destroy()
			sert.eq(events, { "parent:true:true", "child" })
		end
	)

	test(
		"Clone clears Archivable=false internal refs to nil and WaitForChild handles timeOut=0 and parent Destroying",
		function()
			local e = sert.env.new()
			local root = e.Instance.new("Folder", e.workspace)
			local ext = e.Instance.new("Part", e.workspace)
			local keepChild = e.Instance.new("Part", root)
			keepChild.Name = "Keep"
			local unarchivable = e.Instance.new("Part", root)
			unarchivable.Name = "Ephemeral"
			unarchivable.Archivable = false

			local ovKeep = e.Instance.new("ObjectValue", root)
			ovKeep.Name = "KeepRef"
			ovKeep.Value = keepChild
			local ovDrop = e.Instance.new("ObjectValue", root)
			ovDrop.Name = "DropRef"
			ovDrop.Value = unarchivable
			local ovExt = e.Instance.new("ObjectValue", root)
			ovExt.Name = "ExtRef"
			ovExt.Value = ext

			local cloned = root:Clone() :: any
			sert.ok(cloned ~= nil)
			sert.eq((cloned:FindFirstChild("KeepRef") :: any).Value, cloned:FindFirstChild("Keep"))
			sert.eq((cloned:FindFirstChild("DropRef") :: any).Value, nil)
			sert.eq((cloned:FindFirstChild("ExtRef") :: any).Value, ext)

			-- WaitForChild timeOut <= 0 returns nil immediately; waiting wakes and returns nil when parent is destroyed
			sert.eq(root:WaitForChild("NeverThere", 0), nil)
			local waitedResult: any = "unset"
			e.task.spawn(function() waitedResult = root:WaitForChild("NeverArrives") end)
			e:flush()
			sert.eq(waitedResult, "unset")
			root:Destroy()
			e:flush()
			sert.eq(waitedResult, nil)
		end
	)

	test(
		"GuiService:GetGuiInset, TextService:GetTextBoundsAsync, UIScale propagation, AbsoluteRotation & CollectionService:GetAllTags",
		function()
			local e = sert.env.new({ isClient = true, isServer = false, viewport = sert.env.Vector2.new(800, 600) })
			local gs = e:getService("GuiService")
			local topLeft, bottomRight = gs:GetGuiInset()
			sert.eq(topLeft, e.Vector2.new(0, 58))
			sert.eq(bottomRight, e.Vector2.zero)
			sert.eq(gs.TopbarInset, e.Rect.new(0, 0, 1280, 58))

			local cs = e:getService("CollectionService")
			local pA = e.Instance.new("Part", e.workspace)
			cs:AddTag(pA, "Zeta")
			cs:AddTag(pA, "Alpha")
			sert.eq(cs:GetAllTags(), { "Alpha", "Zeta" })
			cs:RemoveTag(pA, "Zeta")
			sert.eq(cs:GetAllTags(), { "Alpha" })
			pA:Destroy()
			sert.eq(cs:GetAllTags(), {})

			local sg = e.Instance.new("ScreenGui", e.LocalPlayer.PlayerGui)
			sg.IgnoreGuiInset = true
			local host = e.Instance.new("Frame", sg)
			host.Size = e.UDim2.fromOffset(200, 100)
			host.Rotation = 15
			local scale = e.Instance.new("UIScale", host)
			scale.Scale = 2
			local pad = e.Instance.new("UIPadding", host)
			pad.PaddingLeft = e.UDim.new(0, 10)
			pad.PaddingTop = e.UDim.new(0, 5)
			local childLbl = e.Instance.new("TextLabel", host)
			childLbl.Position = e.UDim2.fromOffset(10, 5)
			childLbl.Size = e.UDim2.fromOffset(80, 20)
			childLbl.Rotation = 30
			childLbl.TextSize = 14
			childLbl.Text = "Hello"

			sert.eq(host.AbsoluteSize, e.Vector2.new(400, 200))
			sert.eq(childLbl.AbsoluteSize, e.Vector2.new(160, 40))
			-- PaddingLeft(10*2=20) + Position.X(10*2=20) = 40; PaddingTop(5*2=10) + Position.Y(5*2=10) = 20
			sert.eq(childLbl.AbsolutePosition, e.Vector2.new(40, 20))
			sert.eq(childLbl.AbsoluteRotation, 45)

			-- Compare scaled TextLabel.TextBounds with TextService:GetTextBoundsAsync at matching effective fontSize (28)
			local ts = e:getService("TextService")
			local params = e.Instance.new("GetTextBoundsParams")
			params.Text = "Hello"
			params.Size = 28
			params.Width = 0
			sert.eq(childLbl.TextBounds, ts:GetTextBoundsAsync(params))

			local insetGui = e.Instance.new("ScreenGui", e.LocalPlayer.PlayerGui)
			sert.eq(insetGui.AbsoluteSize, e.Vector2.new(800, 542))
			insetGui.ScreenInsets = e.Enum.ScreenInsets.DeviceSafeInsets
			sert.eq(insetGui.IgnoreGuiInset, true)
			sert.eq(insetGui.AbsoluteSize, e.Vector2.new(800, 600))
			insetGui.ScreenInsets = e.Enum.ScreenInsets.None
			sert.eq(insetGui.IgnoreGuiInset, true)
			sert.eq(insetGui.AbsoluteSize, e.Vector2.new(800, 600))
			insetGui.ScreenInsets = e.Enum.ScreenInsets.TopbarSafeInsets
			sert.eq(insetGui.IgnoreGuiInset, false)
			sert.eq(insetGui.AbsoluteSize, e.Vector2.new(800, 542))
			insetGui.ScreenInsets = e.Enum.ScreenInsets.CoreUISafeInsets
			sert.eq(insetGui.IgnoreGuiInset, false)
			sert.eq(insetGui.AbsoluteSize, e.Vector2.new(800, 542))
			insetGui.IgnoreGuiInset = true
			sert.eq(insetGui.ScreenInsets, e.Enum.ScreenInsets.DeviceSafeInsets)
			insetGui.ScreenInsets = e.Enum.ScreenInsets.CoreUISafeInsets
			sert.eq(insetGui.IgnoreGuiInset, false)
			sert.eq(insetGui.AbsoluteSize, e.Vector2.new(800, 542))

			-- UIListLayout flex sizing must not double-apply child UIScale; negative UIScale clamps cleanly
			local flexHost = e.Instance.new("Frame", insetGui)
			flexHost.Size = e.UDim2.fromOffset(300, 100)
			local flexLayout = e.Instance.new("UIListLayout", flexHost)
			flexLayout.FillDirection = e.Enum.FillDirection.Horizontal
			flexLayout.HorizontalFlex = e.Enum.UIFlexAlignment.Fill
			local flexItem = e.Instance.new("Frame", flexHost)
			flexItem.Size = e.UDim2.fromOffset(50, 40)
			local flexScale = e.Instance.new("UIScale", flexItem)
			flexScale.Scale = 2
			sert.eq(flexItem.AbsoluteSize, e.Vector2.new(300, 80))

			local negScale = e.Instance.new("UIScale", flexHost)
			negScale.Scale = -1
			sert.eq(negScale.Scale, 0)
			local sizeBound = e.Instance.new("UISizeConstraint", flexItem)
			sizeBound.MinSize = e.Vector2.new(20, 20)
			sizeBound.MaxSize = e.Vector2.new(100, 100)
			sert.eq(flexItem.AbsoluteSize, e.Vector2.new(0, 0))
			insetGui:Destroy()
		end
	)

	test(
		"SharedTable key/value validation, Actor:SendMessage isolation, assertSerial & PluginSecurity parity",
		function()
			local e = sert.env.new()
			local st = e.SharedTable.new({ ok = 1, [2] = vector.create(1, 2, 3), c = e.Color3.new(1, 0, 0) })
			sert.eq(st[2], vector.create(1, 2, 3))
			sert.throws(function() (st :: any)[1.5] = 10 end, "invalid key")
			sert.throws(function() (st :: any)[math.huge] = 10 end, "invalid key")
			local spoofed = setmetatable({ x = 1 }, { __type = "Spoofed" })
			sert.throws(function() st.bad = spoofed end, "custom metatables")

			-- Actor:SendMessage deep-copies plain tables/buffers while sharing SharedTable & Instance
			local actor = e.Instance.new("Actor", e.workspace)
			local markerPart = e.Instance.new("Part", e.workspace)
			local payload = { count = 1, nested = { tag = "a" } }
			local buf = buffer.fromstring("ab")
			local gotPayload: any = nil
			local gotBuf: any = nil
			local gotShared: any = nil
			local gotInst: any = nil
			actor:BindToMessage("msg", function(t: any, b: buffer, s: any, inst: any)
				gotPayload, gotBuf, gotShared, gotInst = t, b, s, inst
			end)
			actor:SendMessage("msg", payload, buf, st, markerPart)
			payload.count = 99
			payload.nested.tag = "mutated"
			buffer.writeu8(buf, 0, 0x5A)
			e:flush()
			sert.eq(gotPayload, { count = 1, nested = { tag = "a" } })
			sert.eq(buffer.tostring(gotBuf), "ab")
			sert.eq(gotShared, st)
			sert.eq(gotInst, markerPart)

			-- Multi-listener Actor:SendMessage isolates listener 1 synchronous mutations from listener 2
			local multiActor = e.Instance.new("Actor", e.workspace)
			local secondSeen: { n: number, buf: string }? = nil
			multiActor:BindToMessage("iso", function(tbl: any, b: buffer)
				tbl.n = 999
				buffer.writeu8(b, 0, 0x58)
			end)
			multiActor:BindToMessage(
				"iso",
				function(tbl: any, b: buffer) secondSeen = { n = tbl.n, buf = buffer.tostring(b) } end
			)
			multiActor:SendMessage("iso", { n = 1 }, buffer.fromstring("ok"))
			e:flush()
			sert.eq(secondSeen, { n = 1, buf = "ok" })

			-- Parallel.assertSerial rejects TweenService:Create and Debris:AddItem while desynchronized
			local tweenPart = e.Instance.new("Part", e.workspace)
			e.task.desynchronize()
			sert.throws(
				function() e:getService("TweenService"):Create(tweenPart, e.TweenInfo.new(0.1), { Transparency = 0.5 }) end,
				"parallel"
			)
			sert.throws(function() e:getService("Debris"):AddItem(tweenPart, 1) end, "parallel")
			e.task.synchronize()

			-- PluginSecurity & Content datatype parity
			local mv = e.Instance.new("MaterialVariant", e.workspace)
			sert.eq(mv.BaseMaterial, e.Enum.Material.Plastic)
			sert.throws(function() mv.BaseMaterial = e.Enum.Material.Wood end, "lacking capability Plugin")
			sert.throws(function() return (tweenPart :: any):GetDebugId() end, "lacking capability Plugin")

			local img = e.Instance.new("ImageLabel")
			sert.eq(img.ImageContent, nil)
			img.ImageContent = "rbxassetid://12345"
			sert.eq(img.ImageContent, "rbxassetid://12345")
			sert.throws(function() (img :: any).ImageContent = true end, "string expected")

			local studioEnv = sert.env.new({ isStudio = true })
			local studioPart = studioEnv.Instance.new("Part", studioEnv.workspace)
			local studioMv = studioEnv.Instance.new("MaterialVariant", studioEnv.workspace)
			studioMv.BaseMaterial = studioEnv.Enum.Material.Wood
			sert.eq(studioMv.BaseMaterial, studioEnv.Enum.Material.Wood)
			sert.ok(type((studioPart :: any):GetDebugId()) == "string")

			-- sert.env.installGlobals populates explicit target table headlessly
			local sandbox: { [string]: any } = {}
			sert.env.installGlobals(sandbox)
			if not sert.isRoblox then
				sert.eq(type(sandbox.Vector3), "table")
				sert.eq(sandbox.Vector3.new(1, 2, 3), sert.env.Vector3.new(1, 2, 3))
				sert.eq(type(sandbox.Color3), "table")
				sert.eq(type(sandbox.CFrame), "table")
			end

			-- Destroying ScreenGuis prunes `_layerCollectorList` so repeated UI runs do not leak
			local uiEnv = sert.env.new({ isClient = true, isServer = false })
			for i = 1, 60 do
				local gui = uiEnv.Instance.new("ScreenGui", uiEnv.LocalPlayer.PlayerGui)
				gui.Name = `Transient_{i}`
				gui:Destroy()
			end
			sert.eq(#(uiEnv :: any)._layerCollectorList, 0)
			local liveGui = uiEnv.Instance.new("ScreenGui", uiEnv.LocalPlayer.PlayerGui)
			liveGui.IgnoreGuiInset = true
			sert.eq(#(uiEnv :: any)._layerCollectorList, 1)
			uiEnv:setViewport(uiEnv.Vector2.new(800, 600))
			sert.eq(liveGui.AbsoluteSize, uiEnv.Vector2.new(800, 600))
			liveGui:Destroy()
			sert.eq(#(uiEnv :: any)._layerCollectorList, 0)
		end
	)
end)
