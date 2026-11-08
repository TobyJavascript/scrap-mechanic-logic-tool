-- TobyWand: multi-select, multi-connect, scripted wiring and timing analysis
-- for Scrap Mechanic logic.
--
-- Controls (while held):
--   Left click         add/remove the part you look at in the active group
--   Left drag          box-select into the active group
--   F + left click     select every matching part (filter set in the menu)
--   Right click        switch active group (A > B > C)
--   F + right click    delay numbers on every part after the one you look at
--                      (again: parts before it, again: off)
--   Q                  box select mode: 3D box, or a flat XY / XZ / YZ layer
--   R                  open the menu

dofile("$SURVIVAL_DATA/Scripts/util.lua")            -- clamp() etc., needed by AnimationUtil
dofile("$GAME_DATA/Scripts/game/AnimationUtil.lua")
dofile("$CONTENT_DATA/Scripts/LogicScript.lua")
dofile("$CONTENT_DATA/Scripts/LogicGraph.lua")

LogicTool = class()

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------

local LOGIC = sm.interactable.connectionType.logic

local UUID_GATE = "9f0f56e8-2c31-4d83-996c-d00a9b296c3f"
local UUID_TIMER = "8f7fd0e7-c46e-4944-a414-7ce2437bb30f"
local KIND_BY_UUID = {
	[UUID_GATE] = "gate",
	[UUID_TIMER] = "timer",
	["1e8d93a4-506b-470d-9ada-9c0a321e2db5"] = "input", -- button
	["7cf717d7-d167-4f2d-a6e7-6b2c70aa3986"] = "input", -- switch
	["add3acc6-a6fd-44e8-a384-a7a16ce13c81"] = "input", -- sensor
}
local NAME_BY_UUID = {
	["1e8d93a4-506b-470d-9ada-9c0a321e2db5"] = "Button",
	["7cf717d7-d167-4f2d-a6e7-6b2c70aa3986"] = "Switch",
	["add3acc6-a6fd-44e8-a384-a7a16ce13c81"] = "Sensor",
	[UUID_TIMER] = "Timer",
}

local FRAME_UUID = sm.uuid.new("5b1e6c2a-8d4f-4b7e-9c3a-1f2e7d6a4c05") -- glowing box frame (markers)
local WIRE_UUID = sm.uuid.new("5b1e6c2a-8d4f-4b7e-9c3a-1f2e7d6a4c03")  -- round wire
local ARROW_UUID = sm.uuid.new("5b1e6c2a-8d4f-4b7e-9c3a-1f2e7d6a4c04") -- arrowhead
local PLASTIC_UUID = sm.uuid.new("628b2d61-5ceb-43e9-8334-a4135566df7a")

local GROUPS = { "A", "B", "C" }
local GROUP_COLOR = {
	A = sm.color.new("ff9900ff"),
	B = sm.color.new("00c8ffff"),
	C = sm.color.new("d040ffff"),
}
local GROUP_HEX = { A = "#ff9900", B = "#00c8ff", C = "#d040ff" }
local COLOR_WARN = sm.color.new("ff2020ff")
local COLOR_GLITCH = sm.color.new("ffee00ff")
local COLOR_PATH = sm.color.new("ffffffff")
local COLOR_ON = sm.color.new("ff2a2aff")   -- wire carrying an on signal
local COLOR_OFF = sm.color.new("7a1010ff")  -- wire carrying an off signal

local RANGE = 10
-- Frames are the part's size plus a padding (m) on every side. Each group
-- has its own padding so a part in several groups shows nested frames.
local GROUP_PAD = { A = 0.015, B = 0.03, C = 0.045 }
local FLAG_PAD = 0.06
local LINE_THICK = 0.02       -- wire diameter (m)
local ARROW_LEN = 0.11        -- arrowhead length (m)
local ARROW_WIDTH = 0.07     -- arrowhead base diameter (m)
local ARROW_GAP = 0.13        -- arrow tip stops this far from the child's centre (m)
local MAX_LINES = 400
local MAX_GROUP = 2048
local OPS_PER_PACKET = 300
local NET_LIST_LIMIT = 400
local MAX_GRAPH_NODES = 20000
local PROBE_NET_LIMIT = 1500   -- probe results sent to the client
local MAX_LABELS = 200         -- world labels shown at once (nearest first)
local LABEL_REFRESH = 0.25     -- seconds between "which labels are nearest" updates
-- Type labels come from the server. Ask again soon when a selected part has
-- none yet, and now and then anyway so a changed gate mode shows up.
local TYPE_ASK_MISSING = 0.5
local TYPE_ASK_REFRESH = 3
local BOX_MARGIN = 0.15
local DRAG_START = 0.3

-- Box select modes (Q). A plane mode keeps the box one layer thick, through
-- the centre of the part you started on, like the game's block drag.
-- Axes are the creation's own (Z is up when it stands as built).
local BOX_MODES = { "3d", "xy", "xz", "yz" }
local BOX_NAMES = { ["3d"] = "3D box", xy = "XY layer (flat)", xz = "XZ layer (wall)", yz = "YZ layer (wall)" }
local BOX_SHORT = { ["3d"] = "3D box", xy = "XY layer", xz = "XZ layer", yz = "YZ layer" }
local BOX_NORMAL = { xy = "z", xz = "y", yz = "x" }

local LABEL_MODES = { "off", "index", "type", "delay" }
local LABEL_NAMES = { off = "Off", index = "Order", type = "Type", delay = "Delay" }

local CONNECT_MODES = { allToAll = "All > All", zip = "Zip 1:1", chain = "Chain" }
-- What All > All / Zip / Chain do: add wires, remove them, or toggle each pair.
local WIRE_MODES = { "connect", "cut", "flip" }
local WIRE_NAMES = { connect = "Mode: Connect", cut = "Mode: Cut", flip = "Mode: Flip" }
local WIRE_VERBS = { connect = "Connect", cut = "Cut", flip = "Flip" }

-- what F+click picks: parts in the creation that match the one clicked
local PICK_MODES = { "typeColor", "type", "color", "setting", "settingColor" }
local PICK_NAMES = {
	typeColor = "type + colour", type = "type", color = "colour",
	setting = "mode/time", settingColor = "mode/time + colour",
}
local PICK_ALERT = {
	typeColor = "same type and colour", type = "same type", color = "same colour",
	setting = "same type and gate mode / timer time", settingColor = "same gate mode / timer time and colour",
}

local HELP_TEXT = [[CONTROLS
  Click / drag      add to the active group / box select
  Right click       next group
  F + click         pick every matching part (filter: the F: button)
  F + right click   delays from that part; again: delays to it; again: off
  Q                 box select mode: 3D / XY / XZ / YZ layer

SCRIPTS ARE LUA
A, B, C are lists of the parts you selected, in order.
A part p has: p.x p.y p.z (blocks), p.group, p.index,
  p.kind ("gate" "timer" "input" "output"),
  p.mode ("AND" "OR" "XOR" "NAND" "NOR" "XNOR"),
  p.delay (ticks), p.color ("df7f00")

Wiring (a and b can be one part or a list):
  connect(a, b)          every a to every b
  connect(a, b, "zip")   a[1]>b[1], a[2]>b[2] ...
  cut(a, b)              remove connections
  flip(a, b)             connect if not wired, cut if wired
  chain(list)            list[1]>list[2]>list[3] ...
  clearInputs(a)  clearOutputs(a)

Lists:
  sort(list, "x")        "x" "y" "z" "-x" ... or function(p, q)
  reverse(list)  slice(list, 2, -1)  join(A, B)
  filter(list, function(p) return p.mode == "XOR" end)
  getbit(n, k)           bit k of n (0 or 1)

Plus normal Lua: local, if, for, while, functions, tables,
math, string, table, bit, print.
Nothing is wired unless the whole script runs without errors.
Format re-indents the script and refreshes the colours.
Undo reverts the last button or script run.]]

local function isLogicCapable(inter)
	if not inter or not sm.exists(inter) then return false end
	local okIn, inType = pcall(inter.getConnectionInputType, inter)
	local okOut, outType = pcall(inter.getConnectionOutputType, inter)
	return (okIn and bit.band(inType, LOGIC) ~= 0) or (okOut and bit.band(outType, LOGIC) ~= 0)
end

local function kindOf(inter, shape)
	local uuid = tostring(shape.uuid)
	local kind = KIND_BY_UUID[uuid]
	if kind then return kind end
	local inType = inter:getConnectionInputType()
	local outType = inter:getConnectionOutputType()
	local hasIn = bit.band(inType, LOGIC) ~= 0
	local hasOut = bit.band(outType, LOGIC) ~= 0
	if hasIn and hasOut then return "script" end
	if hasOut then return "input" end
	return "output"
end

-- Scale for a frame around `shape` (its bounding box, in metres) plus `pad`.
local function frameScale(shape, pad)
	local size = sm.vec3.new(0.25, 0.25, 0.25)
	if shape and sm.exists(shape) then
		local ok, bb = pcall(shape.getBoundingBox, shape)
		if ok and bb then size = bb end
	end
	return size + sm.vec3.new(pad, pad, pad) * 2
end

local function chat(msg)
	sm.gui.chatMessage("#ff9900[TobyWand]#ffffff " .. msg)
end

local function containsInter(list, inter)
	for _, x in ipairs(list) do
		if x == inter then return true end
	end
	return false
end

---------------------------------------------------------------------------
-- SERVER
---------------------------------------------------------------------------

function LogicTool:server_onCreate()
	self.sv = { undo = {}, pending = {} }
end

-- Apply a chunk of connect/cut/clear operations from a client.
function LogicTool:sv_applyOps(data, player)
	local pid = player.id
	local pending = self.sv.pending[pid]
	if not pending or data.first then
		pending = { changed = {}, made = 0, cut = 0, skipped = 0, failed = 0, isUndo = data.isUndo }
		self.sv.pending[pid] = pending
	end

	local function connected(p, c)
		return containsInter(p:getChildren(LOGIC), c)
	end

	for _, op in ipairs(data.ops or {}) do
		local p, c, kind = op.p, op.c, op.kind
		if kind == "flip" and sm.exists(p) and c ~= nil and sm.exists(c) then
			kind = connected(p, c) and "cut" or "connect"
		end
		if not sm.exists(p) or (c ~= nil and not sm.exists(c)) then
			pending.failed = pending.failed + 1
		elseif kind == "connect" then
			if connected(p, c) then
				pending.skipped = pending.skipped + 1
			else
				local ok, res = pcall(p.connect, p, c)
				if ok and res ~= false and connected(p, c) then
					pending.made = pending.made + 1
					pending.changed[#pending.changed + 1] = { kind = "connect", p = p, c = c }
				else
					pending.failed = pending.failed + 1
				end
			end
		elseif kind == "cut" then
			if connected(p, c) then
				pcall(p.disconnect, p, c)
				pending.cut = pending.cut + 1
				pending.changed[#pending.changed + 1] = { kind = "cut", p = p, c = c }
			else
				pending.skipped = pending.skipped + 1
			end
		elseif kind == "clearOut" then
			for _, child in ipairs(p:getChildren(LOGIC)) do
				pcall(p.disconnect, p, child)
				pending.cut = pending.cut + 1
				pending.changed[#pending.changed + 1] = { kind = "cut", p = p, c = child }
			end
		elseif kind == "clearIn" then
			for _, parent in ipairs(p:getParents(LOGIC)) do
				pcall(parent.disconnect, parent, p)
				pending.cut = pending.cut + 1
				pending.changed[#pending.changed + 1] = { kind = "cut", p = parent, c = p }
			end
		end
	end

	if data.last then
		self.sv.pending[pid] = nil
		if #pending.changed > 0 and not pending.isUndo then
			local stack = self.sv.undo[pid] or {}
			stack[#stack + 1] = pending.changed
			if #stack > 20 then table.remove(stack, 1) end
			self.sv.undo[pid] = stack
		end
		self.network:sendToClient(player, "cl_onOpsDone", {
			made = pending.made, cut = pending.cut, skipped = pending.skipped,
			failed = pending.failed, isUndo = pending.isUndo, label = data.label
		})
	end
end

function LogicTool:sv_undo(_, player)
	local stack = self.sv.undo[player.id]
	local batch = stack and stack[#stack]
	if not batch then
		self.network:sendToClient(player, "cl_message", "Nothing to undo")
		return
	end
	stack[#stack] = nil
	local ops = {}
	for i = #batch, 1, -1 do
		local ch = batch[i]
		ops[#ops + 1] = { kind = ch.kind == "connect" and "cut" or "connect", p = ch.p, c = ch.c }
	end
	self:sv_applyOps({ ops = ops, first = true, last = true, isUndo = true, label = "Undo" }, player)
end

-- Gate modes and timer settings of every part in the creation of `body`,
-- as { [interactable id] = controller table }. Lua can't read them directly,
-- so they come from sm.creation.exportToTable. Blueprint bodies are in the
-- order: this body, then the other creation bodies in getCreationBodies()
-- order; shapes are matched by order, with the controller id as fallback.
local function readControllers(body, bodies)
	local controllers = {}
	local okExp, export = pcall(sm.creation.exportToTable, body, false, false)
	if not (okExp and type(export) == "table" and export.bodies) then return controllers end
	local ordered = { body }
	for _, b in ipairs(bodies) do
		if b.id ~= body.id then ordered[#ordered + 1] = b end
	end
	local byCtrlId = {}
	for _, bpBody in ipairs(export.bodies) do
		for _, child in ipairs(bpBody.childs or {}) do
			if child.controller and child.controller.id then
				byCtrlId[child.controller.id] = child
			end
		end
	end
	for bi, b in ipairs(ordered) do
		local bpBody = export.bodies[bi]
		local childs = bpBody and bpBody.childs or {}
		for si, shape in ipairs(b:getShapes()) do
			local inter = shape.interactable
			if inter then
				local child = childs[si]
				local uuid = tostring(shape.uuid)
				if not (child and child.shapeId == uuid and child.controller) then
					child = byCtrlId[inter.id]
					if child and child.shapeId ~= uuid then child = nil end
				end
				if child and child.controller then
					controllers[inter.id] = child.controller
				end
			end
		end
	end
	return controllers
end

-- Builds the logic graph of every creation the seed parts belong to (and
-- any creation they are wired to).
function LogicTool:sv_buildGraph(seeds)
	local graph = {}
	local inters = {}
	local labels = {}
	local visitedBody = {}
	local queue = {}
	local mapped, unmapped = 0, 0

	local function enqueue(inter)
		if not sm.exists(inter) then return end
		local shape = inter:getShape()
		if shape and sm.exists(shape) and not visitedBody[shape.body.id] then
			queue[#queue + 1] = shape.body
		end
	end
	for _, inter in ipairs(seeds) do enqueue(inter) end

	local tooBig = false
	local qi = 1
	while qi <= #queue do
		local body = queue[qi]
		qi = qi + 1
		if sm.exists(body) and not visitedBody[body.id] then
			local bodies = body:getCreationBodies()
			for _, b in ipairs(bodies) do visitedBody[b.id] = true end

			local controllers = readControllers(body, bodies)

			for _, b in ipairs(bodies) do
				for _, inter in ipairs(b:getInteractables()) do
					if isLogicCapable(inter) and not graph[inter.id] then
						local shape = inter:getShape()
						local kind = kindOf(inter, shape)
						local ctrl = controllers[inter.id]
						local node = { kind = kind, children = {}, parents = {}, delay = 0 }
						local label
						if kind == "gate" then
							node.delay = 1
							if ctrl and ctrl.mode ~= nil then
								node.mode = ctrl.mode
								label = LogicGraph.MODE_NAMES[ctrl.mode] or "Gate"
								mapped = mapped + 1
							else
								label = "Gate?"
								unmapped = unmapped + 1
							end
						elseif kind == "timer" then
							if ctrl and (ctrl.seconds or ctrl.ticks) then
								node.delay = LogicGraph.timerDelay(ctrl.seconds or 0, ctrl.ticks or 0)
								label = string.format("T %ds %dt", ctrl.seconds or 0, ctrl.ticks or 0)
								mapped = mapped + 1
							else
								node.delay = 1
								label = "Timer?"
								unmapped = unmapped + 1
							end
						elseif kind == "script" then
							node.delay = 1
							label = "Part (1t?)"
						else
							label = NAME_BY_UUID[tostring(shape.uuid)] or (kind == "input" and "Input" or "Output")
						end
						for _, c in ipairs(inter:getChildren(LOGIC)) do
							node.children[#node.children + 1] = c.id
							enqueue(c)
						end
						for _, p in ipairs(inter:getParents(LOGIC)) do
							node.parents[#node.parents + 1] = p.id
							enqueue(p)
						end
						graph[inter.id] = node
						inters[inter.id] = inter
						labels[inter.id] = label
					end
				end
			end

			local count = 0
			for _ in pairs(graph) do count = count + 1 end
			if count > MAX_GRAPH_NODES then
				tooBig = true
				break
			end
		end
	end

	-- drop edges to parts outside the graph (only possible when it was cut off)
	for _, node in pairs(graph) do
		local function keep(list)
			local out = {}
			for _, id in ipairs(list) do
				if graph[id] then out[#out + 1] = id end
			end
			return out
		end
		node.children = keep(node.children)
		node.parents = keep(node.parents)
	end

	return graph, inters, labels, { mapped = mapped, unmapped = unmapped, tooBig = tooBig }
end

local function idsOf(list)
	local ids = {}
	for _, inter in ipairs(list or {}) do
		if sm.exists(inter) then ids[#ids + 1] = inter.id end
	end
	return ids
end

local function limitedInters(ids, inters, limit)
	local out = {}
	for _, id in ipairs(ids) do
		if #out >= limit then break end
		if inters[id] then out[#out + 1] = inters[id] end
	end
	return out
end

function LogicTool:sv_analyze(data, player)
	local seeds = {}
	for _, g in ipairs({ data.A or {}, data.B or {}, data.C or {}, data.sources or {} }) do
		for _, inter in ipairs(g) do seeds[#seeds + 1] = inter end
	end
	if #seeds == 0 then
		self.network:sendToClient(player, "cl_message", "Select some parts first")
		return
	end

	local ok, err = pcall(function()
		local graph, inters, labels, stats = self:sv_buildGraph(seeds)
		local reply = { kind = data.kind, stats = stats, labels = {} }

		-- type labels and gate info for the selected parts
		reply.info = {}
		reply.runScript = data.runScript
		for _, inter in ipairs(seeds) do
			if sm.exists(inter) and labels[inter.id] then
				reply.labels[inter.id] = labels[inter.id]
				local node = graph[inter.id]
				if node then
					reply.info[inter.id] = {
						kind = node.kind, delay = node.delay,
						mode = node.mode ~= nil and LogicGraph.MODE_NAMES[node.mode] or nil,
					}
				end
			end
		end

		local A, B = idsOf(data.A), idsOf(data.B)

		if data.kind == "timing" then
			if #A == 0 or #B == 0 then
				reply.error = "Timing needs group A (start) and group B (end)"
			else
				local r = LogicGraph.timing(graph, A, B)
				reply.min, reply.max = r.min, r.max
				reply.unreachable = r.unreachable
				reply.loops = r.loops
				reply.perTarget = r.perTarget
				reply.path = limitedInters(r.path, inters, NET_LIST_LIMIT)
				reply.pathLabels = {}
				for i = 1, math.min(#r.path, 40) do
					reply.pathLabels[i] = labels[r.path[i]] or "?"
				end
				reply.pathLen = #r.path
				reply.glitch = limitedInters(r.glitch, inters, NET_LIST_LIMIT)
				reply.glitchCount = #r.glitch
			end
		elseif data.kind == "probe" then
			local sources = idsOf(data.sources)
			local entries = LogicGraph.probe(graph, sources, data.reverse)
			reply.reverse = data.reverse
			reply.sources = data.sources
			reply.total = #entries
			reply.probe = {}
			local loops, glitches = 0, 0
			for _, e in ipairs(entries) do
				if e.loop then loops = loops + 1 end
				if e.glitch then glitches = glitches + 1 end
				reply.maxDelay = math.max(reply.maxDelay or 0, e.max)
				if #reply.probe < PROBE_NET_LIMIT and inters[e.id] then
					reply.probe[#reply.probe + 1] = { inter = inters[e.id], min = e.min, max = e.max, loop = e.loop, glitch = e.glitch }
				end
			end
			reply.loops, reply.glitches = loops, glitches
		elseif data.kind == "lint" then
			local issues, counts = LogicGraph.lint(graph)
			reply.counts = counts
			reply.issues = {}
			reply.warn = {}
			for _, it in ipairs(issues) do
				if #reply.issues < 60 then
					reply.issues[#reply.issues + 1] = { level = it.level, msg = it.msg }
				end
				if it.level == "warn" and #reply.warn < NET_LIST_LIMIT then
					reply.warn[#reply.warn + 1] = inters[it.id]
				end
			end
			reply.issueCount = #issues
		elseif data.kind == "truth" then
			if #A == 0 or #B == 0 then
				reply.error = "Truth table needs inputs in A and outputs in B"
			else
				local rows, terr = LogicGraph.truthTable(graph, A, B, 4000)
				if not rows then
					reply.error = terr
				else
					reply.rows = {}
					for _, row in ipairs(rows) do
						local a, b = {}, {}
						for k, v in ipairs(row.ins) do a[k] = v and "1" or "0" end
						for k, v in ipairs(row.outs) do b[k] = v and "1" or "0" end
						reply.rows[#reply.rows + 1] = table.concat(a, " ") .. "  |  " .. table.concat(b, " ") .. (row.settled and "" or "   (never settles)")
					end
				end
			end
		end

		self.network:sendToClient(player, "cl_onAnalysis", reply)
	end)

	if not ok then
		self.network:sendToClient(player, "cl_message", "#ff4040Analysis failed: " .. tostring(err))
	end
end

-- F+click with the "same mode/time" filter: every part in the creation with
-- the same type and the same gate mode or timer time (and colour, if asked).
function LogicTool:sv_pickSame(data, player)
	local target = data.inter
	if not (target and sm.exists(target)) then return end
	local shape = target:getShape()
	local body = shape.body
	local bodies = body:getCreationBodies()
	local controllers = readControllers(body, bodies)
	local function setting(inter)
		local c = controllers[inter.id]
		if not c then return nil end
		if c.mode ~= nil then return "m" .. tostring(c.mode) end
		if c.seconds ~= nil or c.ticks ~= nil then return "t" .. tostring(c.seconds or 0) .. ":" .. tostring(c.ticks or 0) end
		return nil
	end
	local want = setting(target)
	local uuid, color = tostring(shape.uuid), tostring(shape.color)
	local out = {}
	for _, b in ipairs(bodies) do
		for _, s in ipairs(b:getShapes()) do
			local inter = s.interactable
			if inter and tostring(s.uuid) == uuid and (not data.matchColor or tostring(s.color) == color)
				and setting(inter) == want and #out < MAX_GROUP then
				out[#out + 1] = inter
			end
		end
	end
	self.network:sendToClient(player, "cl_onPicked", { inters = out, known = want ~= nil, group = data.group })
end

---------------------------------------------------------------------------
-- CLIENT: setup
---------------------------------------------------------------------------

function LogicTool:client_onCreate()
	self.cl = {
		groups = { A = {}, B = {}, C = {} },   -- lists of { inter =, shape = }
		active = "A",
		markers = { A = {}, B = {}, C = {} }, -- [interId] = effect
		flags = {},                            -- [interId] = { effect =, inter = }
		lines = {},                            -- effect pool
		lineUuid = {},                         -- mesh shown by each pooled effect
		labels = {},                           -- world gui pool
		labelMode = 2,                         -- order numbers (A1, A2 ...) by default
		showLines = false,
		typeLabels = {},                       -- [interId] = "AND"
		partInfo = {},                         -- [interId] = { kind, mode, delay } for scripts
		delayLabels = {},                      -- [interId] = "3t" / "2-5t"
		path = {},                             -- interactables on the critical path
		lastConnect = "allToAll",
		boxMode = 1,
		pickMode = 1,
		wireMode = 1,
		probe = nil,                           -- { entries =, reverse =, origin =, ... }
		labelShown = {},                       -- entries picked for labels
		labelTimer = 0,
		typeAge = 0,                           -- seconds since type labels were last asked for
		exampleIndex = 0,
		script = "",
		leftWindow = nil,                      -- "script" or "settings": the window shown on the left
		press = nil,
	}

	if not self.tool:isLocal() then return end

	-- the game's hover glow (part silhouette drawn on top), see Effects/
	self.cl.hover = sm.effect.createEffect("TobyWand-Hover")

	self.cl.box = sm.effect.createEffect("ShapeRenderable")
	self.cl.box:setParameter("uuid", PLASTIC_UUID)
	self.cl.box:setParameter("visualization", true)

	local gui = sm.gui.createGuiFromLayout("$CONTENT_DATA/Gui/Layouts/LogicTool.layout", false)
	for _, name in ipairs({ "close", "active", "clearActive", "clearAll", "undo", "sortX", "sortY", "sortZ", "reverse",
		"allToAll", "zip", "chain", "wireMode", "clearOut", "clearIn", "timing", "truth", "lint", "lines", "labels",
		"clearMarks", "example", "run", "help", "pickBy", "probeFwd", "probeBack", "openScript", "closeScript", "openSettings", "closeSettings", "boxMode", "format" }) do
		gui:setButtonCallback(name, "cl_onButton")
	end
	gui:setTextChangedCallback("script", "cl_onScriptChanged")
	self.cl.gui = gui

	self.cl.script = LogicScript.examples[1].code
	self:cl_showScript()
	self:cl_refreshGui()
end

function LogicTool:client_onDestroy()
	if not self.cl or not self.tool:isLocal() then return end
	self:cl_clearAllVisuals()
	for _, e in ipairs({ self.cl.hover, self.cl.box }) do
		if e and sm.exists(e) then e:destroy() end
	end
	for _, l in ipairs(self.cl.lines) do
		if sm.exists(l) then l:destroy() end
	end
	for _, lab in ipairs(self.cl.labels) do
		pcall(lab.destroy, lab)
	end
	if self.cl.gui then pcall(self.cl.gui.destroy, self.cl.gui) end
end

---------------------------------------------------------------------------
-- CLIENT: animations (game connect tool mesh + animations, our red texture)
---------------------------------------------------------------------------

local renderables = { "$CONTENT_DATA/Objects/Renderable/logictool_char.rend" } -- connect tool mesh, red texture
local renderablesTp = {
	"$GAME_DATA/Character/Char_Male/Animations/char_male_tp_connecttool.rend",
	"$GAME_DATA/Character/Char_Tools/Char_connecttool/char_connecttool_tp_animlist.rend"
}
local renderablesFp = { "$GAME_DATA/Character/Char_Tools/Char_connecttool/char_connecttool_fp_animlist.rend" }

sm.tool.preloadRenderables(renderables)
sm.tool.preloadRenderables(renderablesTp)
sm.tool.preloadRenderables(renderablesFp)

function LogicTool:cl_loadAnimations()
	self.tpAnimations = createTpAnimations(self.tool, {
		idle = { "connecttool_idle" },
		pickup = { "connecttool_pickup", { nextAnimation = "idle" } },
		putdown = { "connecttool_putdown" },
	})
	local movement = {
		idle = "connecttool_idle", idleRelaxed = "connecttool_idle_relaxed",
		sprint = "connecttool_sprint", runFwd = "connecttool_run_fwd", runBwd = "connecttool_run_bwd",
		jump = "connecttool_jump", jumpUp = "connecttool_jump_up", jumpDown = "connecttool_jump_down",
		land = "connecttool_jump_land", landFwd = "connecttool_jump_land_fwd", landBwd = "connecttool_jump_land_bwd",
		crouchIdle = "connecttool_crouch_idle", crouchFwd = "connecttool_crouch_fwd", crouchBwd = "connecttool_crouch_bwd"
	}
	for name, anim in pairs(movement) do
		self.tool:setMovementAnimation(name, anim)
	end
	setTpAnimation(self.tpAnimations, "idle", 5.0)

	if self.tool:isLocal() then
		self.fpAnimations = createFpAnimations(self.tool, {
			equip = { "connecttool_pickup", { nextAnimation = "idle" } },
			unequip = { "connecttool_putdown" },
			idle = { "connecttool_idle", { looping = true } },
			sprintInto = { "connecttool_sprint_into", { nextAnimation = "sprintIdle", blendNext = 5.0 } },
			sprintExit = { "connecttool_sprint_exit", { nextAnimation = "idle", blendNext = 0 } },
			sprintIdle = { "connecttool_sprint_idle", { looping = true } },
		})
	end
	self.blendTime = 0.2
end

function LogicTool:client_onEquip()
	if self.tool:isLocal() then
		sm.audio.play("ConnectTool - Equip")
	end
	self.wantEquipped = true

	local tp, fp = {}, {}
	for _, v in ipairs(renderablesTp) do tp[#tp + 1] = v end
	for _, v in ipairs(renderablesFp) do fp[#fp + 1] = v end
	for _, v in ipairs(renderables) do
		tp[#tp + 1] = v
		fp[#fp + 1] = v
	end
	self.tool:setTpRenderables(tp)
	self:cl_loadAnimations()
	setTpAnimation(self.tpAnimations, "pickup", 0.0001)

	if self.tool:isLocal() then
		self.tool:setFpRenderables(fp)
		swapFpAnimation(self.fpAnimations, "unequip", "equip", 0.2)
		sm.gui.displayAlertText("TobyWand:  R = menu   Q = box mode   F+click = pick matching   F+right click = delays", 5)
		self:cl_rebuildMarkers()
	end
end

function LogicTool:client_onUnequip()
	self.wantEquipped = false
	self.equipped = false
	if self.tool:isLocal() then
		-- keep the selection, hide everything in the world (first, so an
		-- animation problem can never leave frames and wires behind)
		self.cl.press = nil
		self:cl_hideWorldVisuals()
		sm.audio.play("ConnectTool - Unequip")
	end
	if sm.exists(self.tool) and self.tpAnimations then
		pcall(setTpAnimation, self.tpAnimations, "putdown")
		if self.tool:isLocal() and self.fpAnimations and self.fpAnimations.currentAnimation ~= "unequip" then
			pcall(swapFpAnimation, self.fpAnimations, "equip", "unequip", 0.2)
		end
	end
end

function LogicTool:cl_updateAnimations(dt)
	if not self.tpAnimations then return end
	if self.tool:isLocal() and self.fpAnimations then
		if self.equipped then
			local sprinting = self.tool:isSprinting()
			local cur = self.fpAnimations.currentAnimation
			if sprinting and cur ~= "sprintInto" and cur ~= "sprintIdle" then
				swapFpAnimation(self.fpAnimations, "sprintExit", "sprintInto", 0.0)
			elseif not sprinting and (cur == "sprintIdle" or cur == "sprintInto") then
				swapFpAnimation(self.fpAnimations, "sprintInto", "sprintExit", 0.0)
			end
		end
		updateFpAnimations(self.fpAnimations, self.equipped, dt)
	end

	if not self.equipped then
		if self.wantEquipped then
			self.wantEquipped = false
			self.equipped = true
		end
		return
	end

	for name, anim in pairs(self.tpAnimations.animations) do
		anim.time = anim.time + dt
		if name == self.tpAnimations.currentAnimation and anim.time >= anim.info.duration - self.blendTime then
			if name == "pickup" then
				setTpAnimation(self.tpAnimations, "idle", 0.001)
			elseif anim.nextAnimation and anim.nextAnimation ~= "" then
				setTpAnimation(self.tpAnimations, anim.nextAnimation, 0.001)
			end
		end
	end
end

---------------------------------------------------------------------------
-- CLIENT: selection
---------------------------------------------------------------------------

function LogicTool:cl_indexOf(g, inter)
	for i, e in ipairs(self.cl.groups[g]) do
		if e.inter == inter then return i end
	end
end

function LogicTool:cl_addMarker(g, inter)
	local markers = self.cl.markers[g]
	if markers[inter.id] and sm.exists(markers[inter.id]) then return end
	local e = sm.effect.createEffect("ShapeRenderable", inter)
	e:setParameter("uuid", FRAME_UUID)
	e:setParameter("color", GROUP_COLOR[g])
	e:setScale(frameScale(inter:getShape(), GROUP_PAD[g]))
	if self.tool:isEquipped() then e:start() end
	markers[inter.id] = e
end

function LogicTool:cl_removeMarker(g, interId)
	local e = self.cl.markers[g][interId]
	if e and sm.exists(e) then e:destroy() end
	self.cl.markers[g][interId] = nil
end

function LogicTool:cl_add(g, inter, shape)
	if self:cl_indexOf(g, inter) then return false end
	local list = self.cl.groups[g]
	if #list >= MAX_GROUP then return false end
	list[#list + 1] = { inter = inter, shape = shape, id = inter.id }
	self:cl_addMarker(g, inter)
	return true
end

function LogicTool:cl_toggle(g, inter, shape)
	local i = self:cl_indexOf(g, inter)
	if i then
		table.remove(self.cl.groups[g], i)
		self:cl_removeMarker(g, inter.id)
		sm.audio.play("ConnectTool - Released")
	else
		self:cl_add(g, inter, shape)
		sm.audio.play("ConnectTool - Selected")
	end
	self:cl_refreshGui()
end

function LogicTool:cl_clearGroup(g)
	self.cl.groups[g] = {}
	for id, e in pairs(self.cl.markers[g]) do
		if sm.exists(e) then e:destroy() end
	end
	self.cl.markers[g] = {}
end

-- Drop parts that were destroyed.
function LogicTool:cl_prune()
	local changed = false
	for _, g in ipairs(GROUPS) do
		local list = self.cl.groups[g]
		for i = #list, 1, -1 do
			local e = list[i]
			if not sm.exists(e.inter) or not sm.exists(e.shape) then
				table.remove(list, i)
				self:cl_removeMarker(g, e.id)
				changed = true
			end
		end
		for id, eff in pairs(self.cl.markers[g]) do
			if not sm.exists(eff) then self.cl.markers[g][id] = nil end
		end
	end
	if changed then self:cl_refreshGui() end
end

-- All logic parts in the creation of `body`.
local function creationLogicShapes(body)
	local out = {}
	for _, b in ipairs(body:getCreationBodies()) do
		for _, shape in ipairs(b:getShapes()) do
			local inter = shape.interactable
			if inter and isLogicCapable(inter) then
				out[#out + 1] = shape
			end
		end
	end
	return out
end

-- Position of a shape in the frame of `refBody`, in blocks.
local function localBlocks(refBody, worldPos)
	local p = sm.quat.inverse(refBody.worldRotation) * (worldPos - refBody.worldPosition)
	return p * 4
end

local function sortShapesInFrame(shapes, refBody)
	local keyed = {}
	for i, s in ipairs(shapes) do
		keyed[i] = { s = s, p = localBlocks(refBody, s.worldPosition) }
	end
	table.sort(keyed, function(a, b)
		if math.abs(a.p.x - b.p.x) > 0.01 then return a.p.x < b.p.x end
		if math.abs(a.p.y - b.p.y) > 0.01 then return a.p.y < b.p.y end
		if math.abs(a.p.z - b.p.z) > 0.01 then return a.p.z < b.p.z end
		-- parts inside each other: fall back to the part id (placement order)
		return a.s.interactable.id < b.s.interactable.id
	end)
	local out = {}
	for i, k in ipairs(keyed) do out[i] = k.s end
	return out
end

-- Add `shapes` (sorted by position) to group g and say what happened.
function LogicTool:cl_addPicked(g, shapes, refBody, what)
	shapes = sortShapesInFrame(shapes, refBody)
	local added = 0
	for _, s in ipairs(shapes) do
		if self:cl_add(g, s.interactable, s) then added = added + 1 end
	end
	sm.audio.play("ConnectTool - Selected")
	sm.gui.displayAlertText(string.format("Added %d parts to %s%s#ffffff (%s)", added, GROUP_HEX[g], g, what), 2.5)
	self:cl_refreshGui()
end

function LogicTool:cl_selectSimilar(shape)
	local mode = PICK_MODES[self.cl.pickMode]
	if mode == "setting" or mode == "settingColor" then
		-- gate modes / timer times can only be read on the server
		self.network:sendToServer("sv_pickSame", {
			inter = shape.interactable, matchColor = mode == "settingColor", group = self.cl.active
		})
		return
	end
	local uuid, color = tostring(shape.uuid), tostring(shape.color)
	local picked = {}
	for _, s in ipairs(creationLogicShapes(shape.body)) do
		local sameType = tostring(s.uuid) == uuid
		local sameColor = tostring(s.color) == color
		if (mode == "typeColor" and sameType and sameColor) or (mode == "type" and sameType)
			or (mode == "color" and sameColor) then
			picked[#picked + 1] = s
		end
	end
	self:cl_addPicked(self.cl.active, picked, shape.body, PICK_ALERT[mode])
end

function LogicTool:cl_onPicked(r)
	local shapes, ref = {}, nil
	for _, inter in ipairs(r.inters or {}) do
		if sm.exists(inter) then
			local s = inter:getShape()
			if s and sm.exists(s) then
				shapes[#shapes + 1] = s
				ref = ref or s.body
			end
		end
	end
	if #shapes == 0 then return end
	local what = PICK_ALERT[PICK_MODES[self.cl.pickMode]]
	if not r.known then what = "couldn't read its mode, picked the same type" end
	self:cl_addPicked(r.group or self.cl.active, shapes, ref, what)
end

function LogicTool:cl_boxBounds(press, endPos)
	local body = press.body
	local p1 = localBlocks(body, press.anchor) / 4
	local p2 = localBlocks(body, endPos) / 4
	local lo = { x = math.min(p1.x, p2.x), y = math.min(p1.y, p2.y), z = math.min(p1.z, p2.z) }
	local hi = { x = math.max(p1.x, p2.x), y = math.max(p1.y, p2.y), z = math.max(p1.z, p2.z) }
	local n = BOX_NORMAL[press.mode]
	if n then
		-- one layer: the start part's centre plane
		lo[n], hi[n] = p1[n], p1[n]
	end
	local m = BOX_MARGIN
	return sm.vec3.new(lo.x - m, lo.y - m, lo.z - m), sm.vec3.new(hi.x + m, hi.y + m, hi.z + m)
end

-- Where the drag is now. 3D: what you look at (or a point as far away as the
-- start). Layer modes: where your view ray crosses the start part's layer.
function LogicTool:cl_dragPoint(press, hitPos)
	local camPos, dir = sm.camera.getPosition(), sm.camera.getDirection()
	local n = BOX_NORMAL[press.mode]
	if not n then
		return hitPos or (camPos + dir * (press.anchor - camPos):length())
	end
	if not sm.exists(press.body) then return press.last end
	local axis = sm.vec3.new(n == "x" and 1 or 0, n == "y" and 1 or 0, n == "z" and 1 or 0)
	local normal = press.body.worldRotation * axis
	local denom = dir:dot(normal)
	if math.abs(denom) < 0.02 then return press.last end -- looking along the layer
	local t = (press.anchor - camPos):dot(normal) / denom
	if t <= 0 or t > RANGE * 4 then return press.last end
	return camPos + dir * t
end

function LogicTool:cl_boxSelect(press, endPos)
	local body = press.body
	if not sm.exists(body) then return end
	local mn, mx = self:cl_boxBounds(press, endPos)
	local picked = {}
	for _, s in ipairs(creationLogicShapes(body)) do
		local p = localBlocks(body, s.worldPosition) / 4
		if p.x >= mn.x and p.x <= mx.x and p.y >= mn.y and p.y <= mx.y and p.z >= mn.z and p.z <= mx.z then
			picked[#picked + 1] = s
		end
	end
	picked = sortShapesInFrame(picked, body)
	local added = 0
	for _, s in ipairs(picked) do
		if self:cl_add(self.cl.active, s.interactable, s) then added = added + 1 end
	end
	sm.audio.play("ConnectTool - Selected")
	sm.gui.displayAlertText(string.format("Box (%s): added %d parts to %s", BOX_NAMES[press.mode] or "3D box", added, self.cl.active), 2)
	self:cl_refreshGui()
end

function LogicTool:cl_drawBox(press, endPos)
	local body = press.body
	if not sm.exists(body) then
		self.cl.box:stop()
		return
	end
	local mn, mx = self:cl_boxBounds(press, endPos)
	local center = (mn + mx) * 0.5
	self.cl.box:setPosition(body.worldPosition + body.worldRotation * center)
	self.cl.box:setRotation(body.worldRotation)
	self.cl.box:setScale(mx - mn)
	if not self.cl.box:isPlaying() then self.cl.box:start() end
end

-- Group order is kept; sorting uses the frame of the group's first part.
function LogicTool:cl_sortActive(axis)
	local list = self.cl.groups[self.cl.active]
	if #list < 2 then return end
	local ref = list[1].shape.body
	local keyed = {}
	for i, e in ipairs(list) do
		keyed[i] = { e = e, p = localBlocks(ref, e.shape.worldPosition), i = i }
	end
	local others = axis == "x" and { "y", "z" } or axis == "y" and { "x", "z" } or { "x", "y" }
	table.sort(keyed, function(a, b)
		if math.abs(a.p[axis] - b.p[axis]) > 0.01 then return a.p[axis] < b.p[axis] end
		for _, o in ipairs(others) do
			if math.abs(a.p[o] - b.p[o]) > 0.01 then return a.p[o] < b.p[o] end
		end
		return a.i < b.i
	end)
	for i, k in ipairs(keyed) do list[i] = k.e end
	sm.gui.displayAlertText("Sorted " .. self.cl.active .. " by " .. axis:upper(), 1.5)
end

---------------------------------------------------------------------------
-- CLIENT: input
---------------------------------------------------------------------------

function LogicTool:cl_raycast()
	local hit, res = sm.localPlayer.getRaycast(RANGE)
	if hit and res.type == "body" then
		local shape = res:getShape()
		if shape and sm.exists(shape) then
			return res.pointWorld, shape, shape.interactable
		end
	end
	if hit then return res.pointWorld end
end

function LogicTool:client_onEquippedUpdate(primary, secondary, forceBuild)
	if not self.tool:isLocal() then return false, false end

	local pos, shape, inter = self:cl_raycast()
	local logicInter = inter and isLogicCapable(inter) and inter or nil
	self.cl.hoverInter = logicInter

	local g = self.cl.active
	local hint
	if logicInter then
		local idx = self:cl_indexOf(g, logicInter)
		if idx then
			hint = "Remove " .. GROUP_HEX[g] .. g .. idx .. "#ffffff"
		else
			hint = "Add as " .. GROUP_HEX[g] .. g .. (#self.cl.groups[g] + 1) .. "#ffffff"
		end
	else
		hint = "Select into " .. GROUP_HEX[g] .. g .. "#ffffff (drag = " .. BOX_NAMES[BOX_MODES[self.cl.boxMode]] .. ")"
	end
	sm.gui.setInteractionText("", sm.gui.getKeyBinding("Attack", true), hint,
		sm.gui.getKeyBinding("Create", true), "Next group")

	-- left mouse: click = toggle, drag = box
	if primary == sm.tool.interactState.start then
		if shape then
			local mode = BOX_MODES[self.cl.boxMode]
			self.cl.press = {
				pos = pos, body = shape.body, shape = shape, inter = logicInter, force = forceBuild, dragging = false,
				mode = mode,
				-- layers go through the centre of the part you started on
				anchor = mode == "3d" and pos or shape.worldPosition,
			}
		else
			self.cl.press = nil
		end
	elseif primary == sm.tool.interactState.hold and self.cl.press then
		local press = self.cl.press
		local endPos = self:cl_dragPoint(press, pos)
		if endPos and not press.dragging and (endPos - press.pos):length() > DRAG_START then
			press.dragging = true
		end
		if press.dragging and endPos then
			press.last = endPos
			self:cl_drawBox(press, endPos)
		end
	elseif primary == sm.tool.interactState.stop and self.cl.press then
		local press = self.cl.press
		self.cl.press = nil
		self.cl.box:stop()
		if press.dragging and press.last then
			self:cl_boxSelect(press, press.last)
		elseif press.inter and sm.exists(press.inter) then
			if press.force or forceBuild then
				self:cl_selectSimilar(press.shape)
			else
				self:cl_toggle(g, press.inter, press.shape)
			end
		end
	end

	if secondary == sm.tool.interactState.start and forceBuild then
		self:cl_probeHotkey(logicInter)
	elseif secondary == sm.tool.interactState.start then
		local idx = 1
		for i, name in ipairs(GROUPS) do
			if name == g then idx = i end
		end
		self.cl.active = GROUPS[idx % #GROUPS + 1]
		sm.audio.play("ConnectTool - Rotate")
		sm.gui.displayAlertText("Active group: " .. GROUP_HEX[self.cl.active] .. self.cl.active, 1.5)
		self:cl_refreshGui()
	end

	return true, true
end

function LogicTool:client_onReload()
	if self.cl.gui:isActive() then
		self.cl.gui:close()
	else
		self:cl_refreshGui()
		self.cl.gui:open()
	end
	return true
end

-- Q: next box select mode (also while dragging, like the game's block drag)
function LogicTool:client_onToggle()
	self.cl.boxMode = self.cl.boxMode % #BOX_MODES + 1
	local mode = BOX_MODES[self.cl.boxMode]
	local press = self.cl.press
	if press then
		press.mode = mode
		if sm.exists(press.shape) then
			press.anchor = mode == "3d" and press.pos or press.shape.worldPosition
		end
		press.last = nil
	end
	sm.audio.play("ConnectTool - Rotate")
	sm.gui.displayAlertText("Box select: " .. BOX_NAMES[mode], 1.5)
	self:cl_refreshGui()
	return true
end

---------------------------------------------------------------------------
-- CLIENT: operations
---------------------------------------------------------------------------

function LogicTool:cl_inters(g)
	local out = {}
	for _, e in ipairs(self.cl.groups[g]) do
		if sm.exists(e.inter) then out[#out + 1] = e.inter end
	end
	return out
end

function LogicTool:cl_hasSelection()
	for _, g in ipairs(GROUPS) do
		if #self.cl.groups[g] > 0 then return true end
	end
	return false
end

function LogicTool:cl_sendOps(ops, label)
	if #ops == 0 then
		sm.gui.displayAlertText("Nothing to do", 1.5)
		return
	end
	local n = #ops
	local i = 1
	local first = true
	while i <= n do
		local chunk = {}
		for k = i, math.min(n, i + OPS_PER_PACKET - 1) do
			local op = ops[k]
			chunk[#chunk + 1] = { kind = op.kind, p = op.p, c = op.c }
		end
		i = i + OPS_PER_PACKET
		self.network:sendToServer("sv_applyOps", { ops = chunk, first = first, last = i > n, label = label })
		first = false
	end
end

function LogicTool:cl_connectMode(mode)
	local A, B = self:cl_inters("A"), self:cl_inters("B")
	local wire = WIRE_MODES[self.cl.wireMode]
	local ops = {}
	local label = CONNECT_MODES[mode]
	if mode == "chain" then
		local g = self.cl.active
		local list = self:cl_inters(g)
		if #list < 2 then sm.gui.displayAlertText("Chain needs 2+ parts in " .. g, 2) return end
		for i = 1, #list - 1 do ops[#ops + 1] = { kind = wire, p = list[i], c = list[i + 1] } end
		label = "Chain " .. g
	else
		if #A == 0 or #B == 0 then
			sm.gui.displayAlertText("Select parts in A and B first", 2)
			return
		end
		if mode == "zip" then
			if #A ~= #B then
				chat(string.format("Zip: A has %d and B has %d parts; pairing the first %d", #A, #B, math.min(#A, #B)))
			end
			for i = 1, math.min(#A, #B) do ops[#ops + 1] = { kind = wire, p = A[i], c = B[i] } end
		else
			for _, a in ipairs(A) do
				for _, b in ipairs(B) do
					if a ~= b then ops[#ops + 1] = { kind = wire, p = a, c = b } end
				end
			end
		end
	end
	self.cl.lastConnect = mode
	self:cl_sendOps(ops, WIRE_VERBS[wire] .. " " .. label)
end

function LogicTool:cl_onOpsDone(r)
	local parts = {}
	if r.made > 0 then parts[#parts + 1] = r.made .. " connected" end
	if r.cut > 0 then parts[#parts + 1] = r.cut .. " cut" end
	if r.skipped > 0 then parts[#parts + 1] = r.skipped .. " unchanged" end
	if r.failed > 0 then parts[#parts + 1] = "#ff6060" .. r.failed .. " not allowed#ffffff" end
	local msg = (r.label or "Done") .. ": " .. (#parts > 0 and table.concat(parts, ", ") or "no changes")
	sm.gui.displayAlertText(msg, 3)
	sm.audio.play(r.failed > 0 and "ConnectTool - Released" or "ConnectTool")
	local text = (msg:gsub("#%x%x%x%x%x%x", ""))
	if r.label == "Script" and self.cl.scriptOutput and self.cl.scriptOutput ~= "" then
		text = text .. "\n" .. self.cl.scriptOutput
	end
	self:cl_setResult(text)
	if r.failed > 0 then
		self:cl_appendResult("Some connections were refused by the game (e.g. a part can't take that input, or a part's connection limit was reached).")
	end
end

function LogicTool:cl_message(msg)
	sm.gui.displayAlertText(msg, 3)
	self:cl_setResult((msg:gsub("#%x%x%x%x%x%x", "")))
end

---------------------------------------------------------------------------
-- CLIENT: scripts
---------------------------------------------------------------------------

function LogicTool:cl_scriptGroups()
	-- one frame for all groups so "sort by x" means the same thing everywhere
	local ref
	for _, g in ipairs(GROUPS) do
		local first = self.cl.groups[g][1]
		if first and sm.exists(first.shape) then
			ref = first.shape.body
			break
		end
	end
	local groups = {}
	for _, g in ipairs(GROUPS) do
		local list = {}
		for i, e in ipairs(self.cl.groups[g]) do
			if sm.exists(e.inter) and sm.exists(e.shape) then
				local p = ref and localBlocks(ref, e.shape.worldPosition) or sm.vec3.zero()
				local info = self.cl.partInfo[e.inter.id] or {}
				local okC, hex = pcall(function() return e.shape.color:getHexStr() end)
				list[#list + 1] = {
					key = e.inter.id, inter = e.inter, order = i,
					x = math.floor(p.x * 100 + 0.5) / 100,
					y = math.floor(p.y * 100 + 0.5) / 100,
					z = math.floor(p.z * 100 + 0.5) / 100,
					kind = info.kind, mode = info.mode, delay = info.delay,
					type = self.cl.typeLabels[e.inter.id],
					color = okC and type(hex) == "string" and hex:sub(1, 6):lower() or nil,
				}
			end
		end
		groups[g] = list
	end
	return groups
end

-- Run: first ask the server for gate modes / kinds (p.mode, p.kind), then run.
function LogicTool:cl_runScript()
	local any = #self.cl.groups.A + #self.cl.groups.B + #self.cl.groups.C > 0
	if not any then
		self:cl_runScriptNow()
		return
	end
	self:cl_setResult("Running...")
	self.network:sendToServer("sv_analyze", {
		kind = "info", runScript = true, A = self:cl_inters("A"), B = self:cl_inters("B"), C = self:cl_inters("C")
	})
end

function LogicTool:cl_runScriptNow()
	local ok, res, partial = LogicScript.run(self.cl.script or "", self:cl_scriptGroups())
	if not ok then
		local text = "Script error: " .. tostring(res)
		if partial and #partial > 0 then
			text = text .. "\n\nOutput so far:\n" .. table.concat(partial, "\n")
		end
		self:cl_setResult(text)
		self:cl_showScript(tonumber(tostring(res):match("^line (%d+):")))
		sm.gui.displayAlertText("#ff6060Script error#ffffff (see menu)", 2)
		return
	end
	self:cl_showScript()
	local ops = {}
	for _, op in ipairs(res.ops) do
		ops[#ops + 1] = { kind = op.kind, p = op.p.inter, c = op.c and op.c.inter or nil }
	end
	self.cl.scriptOutput = table.concat(res.output, "\n")
	local text = string.format("Script: %d operation%s", #ops, #ops == 1 and "" or "s")
	if #res.output > 0 then
		text = text .. "\n" .. self.cl.scriptOutput
	end
	self:cl_setResult(text)
	self:cl_sendOps(ops, "Script")
end

-- Shows the script in the editor with colours (and the error line in red).
-- The edit box understands MyGUI colour codes (#rrggbb, ## for a real #),
-- the same way ScrapComputers colours its code editor.
function LogicTool:cl_showScript(errorLine)
	local gui = self.cl.gui
	if not gui then return end
	local src = self.cl.script or ""
	local ok = pcall(function() gui:setText("script", LogicScript.highlight(src, errorLine)) end)
	if not ok then gui:setText("script", src) end
end

function LogicTool:cl_onScriptChanged(_, text)
	local src = LogicScript.editorToSource(text)
	local old = self.cl.script or ""
	self.cl.script = src
	-- typing at the end: recolour straight away. Editing in the middle is
	-- recoloured by Format / Run, so the cursor doesn't jump while typing.
	if #src > #old and src:sub(1, #old) == old then
		self:cl_showScript()
	end
end

function LogicTool:cl_formatScript()
	self.cl.script = LogicScript.format(self.cl.script or "")
	self:cl_showScript()
	self:cl_setResult("Formatted.")
end

---------------------------------------------------------------------------
-- CLIENT: analysis results
---------------------------------------------------------------------------

function LogicTool:cl_requestAnalysis(kind)
	if kind ~= "info" then self:cl_setResult("Analysing...") end
	self.network:sendToServer("sv_analyze", {
		kind = kind, A = self:cl_inters("A"), B = self:cl_inters("B"), C = self:cl_inters("C")
	})
end

function LogicTool:cl_flag(inter, color)
	if not sm.exists(inter) then return end
	local f = self.cl.flags[inter.id]
	if f and sm.exists(f.effect) then
		f.effect:setParameter("color", color)
		return
	end
	local e = sm.effect.createEffect("ShapeRenderable", inter)
	e:setParameter("uuid", FRAME_UUID)
	e:setParameter("color", color)
	e:setScale(frameScale(inter:getShape(), FLAG_PAD))
	if self.tool:isEquipped() then e:start() end
	self.cl.flags[inter.id] = { effect = e, inter = inter }
end

function LogicTool:cl_clearMarks()
	for _, f in pairs(self.cl.flags) do
		if sm.exists(f.effect) then f.effect:destroy() end
	end
	self.cl.flags = {}
	self.cl.path = {}
	self.cl.delayLabels = {}
	self:cl_clearProbe()
end

function LogicTool:cl_onAnalysis(r)
	for id, label in pairs(r.labels or {}) do
		self.cl.typeLabels[id] = label
	end

	for id, info in pairs(r.info or {}) do
		self.cl.partInfo[id] = info
	end

	if r.kind == "info" then
		if r.runScript then self:cl_runScriptNow() end
		return
	end
	if r.kind == "probe" then
		self:cl_onProbe(r)
		return
	end

	if r.error then
		self:cl_setResult(r.error)
		sm.gui.displayAlertText(r.error, 2.5)
		return
	end

	local lines = {}
	local stats = r.stats or {}
	local function add(s) lines[#lines + 1] = s end

	if r.kind == "timing" then
		self:cl_clearMarks()
		if r.min == nil then
			add("No path from A to B.")
			add("Check the wiring direction: A should be the inputs, B the outputs.")
		else
			add("TIMING  A > B")
			add("Fastest: " .. LogicGraph.formatTicks(r.min))
			add("Slowest: " .. LogicGraph.formatTicks(r.max))
			if r.min ~= r.max then
				add("Outputs can change at different times (spread " .. (r.max - r.min) .. " ticks).")
			end
			if r.unreachable > 0 then
				add(r.unreachable .. " part(s) in B can't be reached from A.")
			end
			if r.loops > 0 then
				add(r.loops .. " feedback loop(s) (memory/clock) were cut to compute the slowest path.")
			end
			if r.glitchCount > 0 then
				add(r.glitchCount .. " gate(s) get inputs at different times (yellow): they can output a short wrong pulse.")
			end
			if r.pathLen and r.pathLen > 0 then
				local names = {}
				for i, n in ipairs(r.pathLabels or {}) do names[i] = n end
				local s = table.concat(names, " > ")
				if r.pathLen > #names then s = s .. " > ... (" .. r.pathLen .. " parts)" end
				add("Slowest path (white wires): " .. s)
			end
			-- per-target delay labels
			for id, t in pairs(r.perTarget or {}) do
				self.cl.delayLabels[id] = t.min == t.max and (t.min .. "t") or (t.min .. "-" .. t.max .. "t")
			end
			self.cl.path = r.path or {}
			for _, inter in ipairs(r.glitch or {}) do self:cl_flag(inter, COLOR_GLITCH) end
			if self.cl.labelMode == 1 then
				self.cl.labelMode = 4 -- show delays straight away
			end
		end
		add("")
		add("Model: gate = 1 tick, timer = its time + 1 tick, 40 ticks = 1 s.")

	elseif r.kind == "lint" then
		self:cl_clearMarks()
		local c = r.counts or {}
		local modes = {}
		for name, n in pairs(c.modes or {}) do modes[#modes + 1] = name .. " " .. n end
		table.sort(modes)
		add(string.format("CHECK  %d gates, %d timers, %d inputs, %d outputs", c.gates or 0, c.timers or 0, c.inputs or 0, c.outputs or 0))
		if #modes > 0 then add("Gates: " .. table.concat(modes, ", ")) end
		if (c.loops or 0) > 0 then add(c.loops .. " feedback loop(s) (memory cells or clocks)") end
		if (r.issueCount or 0) == 0 then
			add("No problems found.")
		else
			add(r.issueCount .. " note(s); warnings are marked red:")
			for _, it in ipairs(r.issues or {}) do
				add((it.level == "warn" and "! " or "- ") .. it.msg)
			end
			if r.issueCount > #(r.issues or {}) then add("...") end
		end
		for _, inter in ipairs(r.warn or {}) do self:cl_flag(inter, COLOR_WARN) end

	elseif r.kind == "truth" then
		add("TRUTH TABLE  (A inputs  |  B outputs, in group order)")
		for _, row in ipairs(r.rows or {}) do add(row) end
		add("")
		add("Simulated from all-off for each row; memory circuits may differ in game.")
	end

	if (stats.unmapped or 0) > 0 then
		add(string.format("Note: couldn't read the mode of %d gate/timer(s); assumed 1 tick.", stats.unmapped))
	end
	if stats.tooBig then
		add("Note: creation too big, only part of it was analysed.")
	end

	self:cl_setResult(table.concat(lines, "\n"))
	if not self.cl.gui:isActive() then
		sm.gui.displayAlertText((lines[2] or lines[1] or "Done") .. "  (R for details)", 3)
	end
end

---------------------------------------------------------------------------
-- CLIENT: delay probe
---------------------------------------------------------------------------

-- F + right click: forward from the part you look at, then backward, then off.
function LogicTool:cl_probeHotkey(inter)
	local p = self.cl.probe
	if not inter then
		if p then
			self:cl_clearProbe()
			sm.gui.displayAlertText("Delays off", 1.5)
		else
			sm.gui.displayAlertText("Look at a logic part (F + right click)", 2)
		end
		return
	end
	local same = p and p.origin == inter
	if same and not p.reverse then
		self:cl_startProbe({ inter }, true, inter)
	elseif same then
		self:cl_clearProbe()
		sm.gui.displayAlertText("Delays off", 1.5)
	else
		self:cl_startProbe({ inter }, false, inter)
	end
end

function LogicTool:cl_startProbe(sources, reverse, origin)
	if #sources == 0 then
		sm.gui.displayAlertText("Select parts in A first", 2)
		return
	end
	self.cl.probeRequest = { reverse = reverse, origin = origin }
	sm.audio.play("ConnectTool - Selected")
	self.network:sendToServer("sv_analyze", { kind = "probe", sources = sources, reverse = reverse })
end

function LogicTool:cl_clearProbe()
	self.cl.probe = nil
	self.cl.labelTimer = 0
end

-- White for the first parts, turning red for the last ones.
local function delayHex(t, maxDelay)
	local f = maxDelay > 0 and math.min(1, t / maxDelay) or 0
	local gb = math.floor(255 - 200 * f + 0.5)
	return string.format("#ff%02x%02x", gb, gb)
end

function LogicTool:cl_onProbe(r)
	local req = self.cl.probeRequest or {}
	local maxDelay = r.maxDelay or 0
	local entries = {}
	for _, e in ipairs(r.probe or {}) do
		local colour
		if e.loop then colour = "#ff80ff"
		elseif e.glitch then colour = "#ffee00"
		else colour = delayHex(e.min, maxDelay) end
		entries[#entries + 1] = { inter = e.inter, text = colour .. LogicGraph.probeText(e) }
	end
	local tag = r.reverse and "#80c0ffend" or "#80ff80start"
	for _, inter in ipairs(r.sources or {}) do
		entries[#entries + 1] = { inter = inter, text = tag }
	end
	self.cl.probe = { entries = entries, reverse = r.reverse, origin = req.origin, total = r.total or 0 }
	self.cl.labelTimer = 0 -- pick the nearest labels on the next frame

	local lines = {}
	local function add(x) lines[#lines + 1] = x end
	local from = req.origin and "the part you looked at" or "group A"
	if r.reverse then
		add("DELAYS TO " .. from:upper())
		add("Each number: ticks from that part changing until " .. from .. " changes.")
	else
		add("DELAYS FROM " .. from:upper())
		add("Each number: ticks from " .. from .. " changing until that part changes.")
	end
	if (r.total or 0) == 0 then
		add(r.reverse and "Nothing is wired into it." or "Nothing is wired from it.")
	else
		add(string.format("%d part(s), up to %s.", r.total, LogicGraph.formatTicks(maxDelay)))
		add("3-7t = reached by paths of different length.")
		if (r.glitches or 0) > 0 then
			add(r.glitches .. " gate(s) in yellow get their inputs at different ticks: they can make a short wrong pulse.")
		end
		if (r.loops or 0) > 0 then
			add(r.loops .. " part(s) in pink are in a loop (memory/clock): they can change again after the number shown.")
		end
		if r.total > #(r.probe or {}) then
			add("Only the first " .. #r.probe .. " (fastest) have numbers.")
		end
		if r.total > MAX_LABELS then
			add("Labels show the " .. MAX_LABELS .. " nearest to you; walk around to see the rest.")
		end
		add("A number means a change CAN arrive there; a gate whose other inputs block it still gets one.")
	end
	add("F + right click: " .. (r.reverse and "off" or "parts before it") .. ".  Clear marks: off.")
	local stats = r.stats or {}
	if (stats.unmapped or 0) > 0 then
		add(string.format("Note: couldn't read the mode of %d gate/timer(s); assumed 1 tick.", stats.unmapped))
	end
	self:cl_setResult(table.concat(lines, "\n"))
	if not self.cl.gui:isActive() then
		sm.gui.displayAlertText(string.format("%s: %d part(s), up to %dt", r.reverse and "Delays to it" or "Delays from it", r.total or 0, maxDelay), 2.5)
	end
end

---------------------------------------------------------------------------
-- CLIENT: GUI
---------------------------------------------------------------------------

function LogicTool:cl_setResult(text)
	self.cl.resultText = text
	if self.cl.gui then self.cl.gui:setText("result", text) end
end

function LogicTool:cl_appendResult(text)
	self:cl_setResult((self.cl.resultText or "") .. "\n" .. text)
end

function LogicTool:cl_refreshGui()
	self.cl.labelTimer = 0 -- selection or order may have changed: relabel now
	local gui = self.cl.gui
	if not gui then return end
	local g = self.cl.active
	gui:setText("active", "Active: " .. GROUP_HEX[g] .. g)
	local parts = {}
	for _, name in ipairs(GROUPS) do
		parts[#parts + 1] = GROUP_HEX[name] .. name .. " #ffffff" .. #self.cl.groups[name]
	end
	gui:setText("groupInfo", table.concat(parts, "     "))
	gui:setText("lines", self.cl.showLines and "On" or "Off")
	gui:setText("labels", LABEL_NAMES[LABEL_MODES[self.cl.labelMode]])
	gui:setText("pickBy", PICK_NAMES[PICK_MODES[self.cl.pickMode]])
	gui:setText("wireMode", WIRE_NAMES[WIRE_MODES[self.cl.wireMode]])
	-- group letter last and coloured, like "Active: A", so no colour reset is needed
	gui:setText("chain", "Chain: " .. GROUP_HEX[g] .. g)
	gui:setText("clearIn", "Clear inputs: " .. GROUP_HEX[g] .. g)
	gui:setText("clearOut", "Clear outputs: " .. GROUP_HEX[g] .. g)
	gui:setText("boxMode", BOX_SHORT[BOX_MODES[self.cl.boxMode]])
	local left = self.cl.leftWindow
	gui:setText("openScript", left == "script" and "Hide script" or "< Script")
	gui:setText("openSettings", left == "settings" and "Hide settings" or "< Settings")
	gui:setVisible("scriptWindow", left == "script")
	gui:setVisible("settingsWindow", left == "settings")
end

function LogicTool:cl_onButton(name)
	if name == "close" then
		self.cl.gui:close()
	elseif name == "active" then
		local idx = 1
		for i, gname in ipairs(GROUPS) do if gname == self.cl.active then idx = i end end
		self.cl.active = GROUPS[idx % #GROUPS + 1]
	elseif name == "clearActive" then
		self:cl_clearGroup(self.cl.active)
	elseif name == "clearAll" then
		for _, g in ipairs(GROUPS) do self:cl_clearGroup(g) end
		self:cl_clearMarks()
	elseif name == "undo" then
		self.network:sendToServer("sv_undo")
	elseif name == "sortX" then
		self:cl_sortActive("x")
	elseif name == "sortY" then
		self:cl_sortActive("y")
	elseif name == "sortZ" then
		self:cl_sortActive("z")
	elseif name == "reverse" then
		local list = self.cl.groups[self.cl.active]
		local n = #list
		for i = 1, math.floor(n / 2) do list[i], list[n + 1 - i] = list[n + 1 - i], list[i] end
		sm.gui.displayAlertText("Reversed " .. self.cl.active, 1.5)
	elseif CONNECT_MODES[name] then
		self:cl_connectMode(name)
	elseif name == "wireMode" then
		self.cl.wireMode = self.cl.wireMode % #WIRE_MODES + 1
		local wire = WIRE_MODES[self.cl.wireMode]
		sm.gui.displayAlertText(wire == "connect" and "Buttons add wires"
			or wire == "cut" and "Buttons remove wires" or "Buttons toggle wires", 1.5)
	elseif name == "clearOut" or name == "clearIn" then
		local g = self.cl.active
		local list = self:cl_inters(g)
		if #list == 0 then
			sm.gui.displayAlertText("Group " .. g .. " is empty", 2)
			return
		end
		local ops = {}
		for _, p in ipairs(list) do ops[#ops + 1] = { kind = name, p = p } end
		self:cl_sendOps(ops, "Clear " .. g .. (name == "clearIn" and " inputs" or " outputs"))
	elseif name == "timing" or name == "lint" or name == "truth" then
		self:cl_requestAnalysis(name)
	elseif name == "lines" then
		self.cl.showLines = not self.cl.showLines
	elseif name == "labels" then
		self.cl.labelMode = self.cl.labelMode % #LABEL_MODES + 1
		if LABEL_MODES[self.cl.labelMode] == "type" then
			self:cl_requestAnalysis("info")
		end
	elseif name == "clearMarks" then
		self:cl_clearMarks()
		self:cl_setResult("")
	elseif name == "example" then
		local n = #LogicScript.examples
		self.cl.exampleIndex = self.cl.exampleIndex % n + 1
		local ex = LogicScript.examples[self.cl.exampleIndex]
		self.cl.script = ex.code
		self:cl_showScript()
		self:cl_setResult("Example " .. self.cl.exampleIndex .. "/" .. n .. ": " .. ex.name)
	elseif name == "run" then
		self:cl_runScript()
	elseif name == "format" then
		self:cl_formatScript()
	elseif name == "boxMode" then
		self:client_onToggle()
	elseif name == "openScript" or name == "openSettings" then
		-- one window on the left at a time; the same button again hides it
		local w = name == "openScript" and "script" or "settings"
		self.cl.leftWindow = self.cl.leftWindow ~= w and w or nil
	elseif name == "closeScript" or name == "closeSettings" then
		self.cl.leftWindow = nil
	elseif name == "pickBy" then
		self.cl.pickMode = self.cl.pickMode % #PICK_MODES + 1
		self:cl_setResult("F + click now picks every logic part in the creation with the " .. PICK_ALERT[PICK_MODES[self.cl.pickMode]] .. " as the one you click.")
	elseif name == "probeFwd" or name == "probeBack" then
		self:cl_startProbe(self:cl_inters("A"), name == "probeBack", nil)
	elseif name == "help" then
		self:cl_setResult(HELP_TEXT)
	end
	self:cl_refreshGui()
end

---------------------------------------------------------------------------
-- CLIENT: world visuals (lines, labels, markers)
---------------------------------------------------------------------------

function LogicTool:cl_rebuildMarkers()
	for _, g in ipairs(GROUPS) do
		for _, e in ipairs(self.cl.groups[g]) do
			if sm.exists(e.inter) then self:cl_addMarker(g, e.inter) end
		end
		for _, eff in pairs(self.cl.markers[g]) do
			if sm.exists(eff) and not eff:isPlaying() then eff:start() end
		end
	end
	for _, f in pairs(self.cl.flags) do
		if sm.exists(f.effect) and not f.effect:isPlaying() then f.effect:start() end
	end
end

function LogicTool:cl_hideWorldVisuals()
	for _, g in ipairs(GROUPS) do
		for _, eff in pairs(self.cl.markers[g]) do
			if sm.exists(eff) then eff:stop() end
		end
	end
	for _, f in pairs(self.cl.flags) do
		if sm.exists(f.effect) then f.effect:stop() end
	end
	if self.cl.hover then self.cl.hover:stop() end
	if self.cl.box then self.cl.box:stop() end
	for _, l in ipairs(self.cl.lines) do
		if sm.exists(l) then l:stop() end
	end
	for _, lab in ipairs(self.cl.labels) do
		lab:close()
	end
end

function LogicTool:cl_clearAllVisuals()
	for _, g in ipairs(GROUPS) do
		for _, eff in pairs(self.cl.markers[g]) do
			if sm.exists(eff) then eff:destroy() end
		end
		self.cl.markers[g] = {}
	end
	self:cl_clearMarks()
end

local UP = sm.vec3.new(0, 1, 0)

-- Pooled effect i, showing mesh `uuid` stretched from a to b.
function LogicTool:cl_line(i, uuid, a, b, color, width)
	local e = self.cl.lines[i]
	if e and sm.exists(e) and self.cl.lineUuid[i] ~= uuid then
		e:destroy()
		e = nil
	end
	if not e or not sm.exists(e) then
		e = sm.effect.createEffect("ShapeRenderable")
		e:setParameter("uuid", uuid)
		self.cl.lines[i] = e
		self.cl.lineUuid[i] = uuid
	end
	local d = b - a
	local len = d:length()
	if len < 0.001 then
		e:stop()
		return
	end
	e:setParameter("color", color)
	e:setPosition(a + d * 0.5)
	e:setRotation(sm.vec3.getRotation(UP, d / len))
	e:setScale(sm.vec3.new(width, len, width))
	if not e:isPlaying() then e:start() end
end

-- A connection: a wire from the parent, then an arrowhead pointing into the
-- child (the input side), stopping at the child's surface.
function LogicTool:cl_connection(i, from, to, color)
	local d = to - from
	local len = d:length()
	if len < 0.01 then return i end
	local dir = d / len
	local gap = math.min(ARROW_GAP, len * 0.4)
	local arrowLen = math.min(ARROW_LEN, len * 0.3)
	local tip = to - dir * gap
	local base = tip - dir * arrowLen
	self:cl_line(i, WIRE_UUID, from, base, color, LINE_THICK)
	self:cl_line(i + 1, ARROW_UUID, base, tip, color, ARROW_WIDTH)
	return i + 2
end

function LogicTool:cl_updateLines()
	local n = 1
	if self.cl.showLines then
		local done = {}
		local function draw(p, c)
			if n > MAX_LINES - 1 then return end
			local key = p.id .. ">" .. c.id
			if done[key] then return end
			done[key] = true
			local ps, cs = p:getShape(), c:getShape()
			if ps and cs and sm.exists(ps) and sm.exists(cs) then
				n = self:cl_connection(n, ps.worldPosition, cs.worldPosition, p:isActive() and COLOR_ON or COLOR_OFF)
			end
		end
		for _, g in ipairs(GROUPS) do
			for _, e in ipairs(self.cl.groups[g]) do
				local inter = e.inter
				if sm.exists(inter) then
					for _, c in ipairs(inter:getChildren(LOGIC)) do draw(inter, c) end
					for _, p in ipairs(inter:getParents(LOGIC)) do draw(p, inter) end
				end
			end
		end
	end

	local path = self.cl.path
	for i = 1, #path - 1 do
		if n > MAX_LINES - 1 then break end
		local a, b = path[i], path[i + 1]
		if sm.exists(a) and sm.exists(b) then
			local up = sm.vec3.new(0, 0, 0.02)
			n = self:cl_connection(n, a:getShape().worldPosition + up, b:getShape().worldPosition + up, COLOR_PATH)
		end
	end

	for i = n, #self.cl.lines do
		local e = self.cl.lines[i]
		if e and sm.exists(e) and e:isPlaying() then e:stop() end
	end
end

function LogicTool:cl_label(i, pos, text)
	local lab = self.cl.labels[i]
	if not lab then
		lab = sm.gui.createWorldIconGui(160, 32, "$CONTENT_DATA/Gui/Layouts/LogicTool_Label.layout", false)
		pcall(lab.setRequireLineOfSight, lab, false)
		pcall(lab.setMaxRenderDistance, lab, 30)
		self.cl.labels[i] = lab
	end
	lab:setWorldPosition(pos)
	if self.cl.labelTexts == nil then self.cl.labelTexts = {} end
	if self.cl.labelTexts[i] ~= text then
		lab:setText("Text", text)
		self.cl.labelTexts[i] = text
	end
	if not lab:isActive() then lab:open() end
end

-- Parts at the same spot (gates inside each other) get their labels stacked.
local function spotKey(pos)
	return string.format("%d,%d,%d", math.floor(pos.x * 20 + 0.5), math.floor(pos.y * 20 + 0.5), math.floor(pos.z * 20 + 0.5))
end
local LABEL_UP = 0.22    -- label height above the part (m)
local LABEL_STEP = 0.12  -- extra height per stacked label (m)

-- What could get a label: the probe numbers while the probe is on,
-- otherwise the selected parts in the current label mode.
-- Order numbers are the position in the group: the order you picked the
-- parts in, until you sort or reverse the group.
function LogicTool:cl_labelCandidates()
	if self.cl.probe then return self.cl.probe.entries end
	local mode = LABEL_MODES[self.cl.labelMode]
	local out = {}
	if mode == "off" then return out end
	local seen = {}
	for _, g in ipairs(GROUPS) do
		for i, e in ipairs(self.cl.groups[g]) do
			local inter = e.inter
			if sm.exists(inter) then
				local text
				if mode == "index" then
					text = GROUP_HEX[g] .. g .. i
					local d = self.cl.delayLabels[inter.id]
					if d and not seen[inter.id] then text = text .. " #ffffff" .. d end
				elseif not seen[inter.id] then
					if mode == "type" then
						text = self.cl.typeLabels[inter.id]
						if not text then
							text = "..."
							self.cl.typeMissing = true
						end
					else
						text = self.cl.delayLabels[inter.id]
					end
				end
				seen[inter.id] = true
				if text then out[#out + 1] = { inter = inter, text = text } end
			end
		end
	end
	return out
end

-- There can be thousands of candidates; label the nearest ones.
function LogicTool:cl_pickLabels()
	local camPos = sm.camera.getPosition()
	local near = {}
	for i, e in ipairs(self:cl_labelCandidates()) do
		if sm.exists(e.inter) then
			local shape = e.inter:getShape()
			if shape and sm.exists(shape) then
				local d = (shape.worldPosition - camPos):length()
				if d < 30 then near[#near + 1] = { e = e, d = d, i = i } end
			end
		end
	end
	table.sort(near, function(a, b)
		if math.abs(a.d - b.d) > 0.001 then return a.d < b.d end
		return a.i < b.i -- same spot: keep group order, so stacked labels read A1 under A2
	end)
	local shown = {}
	for k = 1, math.min(#near, MAX_LABELS) do shown[k] = near[k].e end
	self.cl.labelShown = shown
end

function LogicTool:cl_updateLabels(dt)
	self.cl.labelTimer = self.cl.labelTimer - (dt or 0)
	self.cl.typeAge = self.cl.typeAge + (dt or 0)
	if self.cl.labelTimer <= 0 then
		self.cl.labelTimer = LABEL_REFRESH
		self.cl.typeMissing = false
		self:cl_pickLabels()
		if LABEL_MODES[self.cl.labelMode] == "type" and not self.cl.probe then
			local age = self.cl.typeAge
			if (self.cl.typeMissing and age >= TYPE_ASK_MISSING) or (age >= TYPE_ASK_REFRESH and self:cl_hasSelection()) then
				self.cl.typeAge = 0
				self:cl_requestAnalysis("info")
			end
		end
	end

	local n = 1
	local stacks = {}
	local up = sm.vec3.new(0, 0, LABEL_UP)
	for _, e in ipairs(self.cl.labelShown) do
		if sm.exists(e.inter) then
			local shape = e.inter:getShape()
			if shape and sm.exists(shape) then
				local pos = shape.worldPosition
				local key = spotKey(pos)
				local k = stacks[key] or 0
				stacks[key] = k + 1
				self:cl_label(n, pos + up + sm.vec3.new(0, 0, LABEL_STEP * k), e.text)
				n = n + 1
			end
		end
	end

	for i = n, #self.cl.labels do
		local lab = self.cl.labels[i]
		if lab:isActive() then lab:close() end
	end
end

function LogicTool:client_onUpdate(dt)
	self:cl_updateAnimations(dt)
	if not self.tool:isLocal() then return end

	-- safety net: whatever happened in the equip callbacks, world visuals
	-- only show while the tool is in hand
	local equipped = self.tool:isEquipped()
	if equipped ~= self.cl.visualsShown then
		self.cl.visualsShown = equipped
		if equipped then
			self:cl_rebuildMarkers()
		else
			self:cl_hideWorldVisuals()
		end
	end
	if not equipped then return end

	self:cl_prune()

	local h = self.cl.hoverInter
	if h and sm.exists(h) then
		local shape = h:getShape()
		self.cl.hover:setPosition(shape.worldPosition)
		self.cl.hover:setRotation(shape.worldRotation)
		if self.cl.hoverShapeId ~= shape.id then
			self.cl.hoverShapeId = shape.id
			self.cl.hover:stop()
			if shape.isBlock then
				self.cl.hover:setParameter("uuid", PLASTIC_UUID)
				self.cl.hover:setScale(shape:getBoundingBox())
			else
				self.cl.hover:setParameter("uuid", shape.uuid)
				self.cl.hover:setScale(sm.vec3.one() / 4)
			end
		end
		if not self.cl.hover:isPlaying() then self.cl.hover:start() end
	elseif self.cl.hover:isPlaying() then
		self.cl.hover:stop()
	end

	self:cl_updateLines()
	self:cl_updateLabels(dt)
end
