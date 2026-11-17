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
--   Q                  switch Click: Select / Click: Wire; during a box drag: 3D box, or a flat XY / XZ / YZ layer
--   R                  open the menu

dofile("$SURVIVAL_DATA/Scripts/util.lua")            -- clamp() etc., needed by AnimationUtil
dofile("$GAME_DATA/Scripts/game/AnimationUtil.lua")
dofile("$CONTENT_DATA/Scripts/LogicScript.lua")
dofile("$CONTENT_DATA/Scripts/LogicGraph.lua")
dofile("$CONTENT_DATA/Scripts/LogicModule.lua")
dofile("$CONTENT_DATA/Scripts/LogicSettings.lua")

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
local DOT_UUID = sm.uuid.new("5b1e6c2a-8d4f-4b7e-9c3a-1f2e7d6a4c06")   -- round dot (wire mode)
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
local COLOR_RISE = sm.color.new("40ff60ff") -- step debugger: turned on this tick
local COLOR_FALL = sm.color.new("ff4040ff") -- step debugger: turned off this tick

local RANGE = 10
-- Frames are the part's size plus a padding (m) on every side (FRAME_PADS).
-- Frames are nested only where needed: a part's first group (A, B, C
-- order) gets the tightest frame, its second one the next size, and so on.
-- A part only in B or only in C gets the tight one.
local FRAME_PADS = { 0.015, 0.03, 0.045 }
local FLAG_PAD = 0.06
local LINE_THICK = 0.02       -- wire diameter (m)
local ARROW_LEN = 0.11        -- arrowhead length (m)
local ARROW_WIDTH = 0.07     -- arrowhead base diameter (m)
local ARROW_GAP = 0.13        -- arrow tip stops this far from the child's centre (m)
local MAX_LINES = 400
local MAX_GROUP = 2048
local OPS_PER_PACKET = 300
local NET_LIST_LIMIT = 400
local MODULE_MAX_OUTPUTS = 32
local LUT_STYLES = { "auto", "rom", "xor" }
local LUT_STYLE_NAMES = { auto = "Auto", rom = "ROM", xor = "XOR (PPRM)" }
-- buttons that open a window on the left (one at a time)
local LEFT_WINDOWS = { openScript = "script", openSettings = "settings", openModule = "module", openDebug = "debug", openLog = "log" }

-- What a left click on a part does: add it to the active group, or wire like
-- the game's connect tool (pick a source, then click the parts it feeds)
local CLICK_MODES = { "select", "wire" }
local CLICK_NAMES = { select = "Click: Select", wire = "Click: Wire" }
local LOG_HINT = "Every wire change you make with TobyWand is logged here: the buttons, scripts, Undo, "
	.. "and Click: Wire (which works like the game's connect tool, but logged). Wires made with the game's "
	.. "own connect tool are not.\n\n"
	.. "View log shows one entry at a time in the world: green arrows for wires it added, red for wires it "
	.. "removed. Left click goes to older entries, right click to newer, Q undoes the one shown (any entry, "
	.. "not only the last), R stops.\n\nThe log keeps the last 200 entries until you leave the world."
local MODULE_HINT = "Put the inputs in A and the outputs in B (in order), then press Load.\n\n"
	.. "The tool reads the logic between them and shows it as a table: every input combination "
	.. "and what the outputs do. Edit the outputs, then Build LUT rebuilds that logic as a clean LUT."
-- Step debugger
local DEBUG_SPEED_MIN, DEBUG_SPEED_MAX = 0.05, 10 -- Run: seconds per tick (typed)
local DEBUG_INPUT_MODES = { "hold", "pulse", "repeat", "free" }
local DEBUG_INPUT_NAMES = { hold = "Constant input", pulse = "1 tick pulse", ["repeat"] = "Pulse every N ticks", free = "Free after tick 0" }
local DEBUG_EVERY_MAX = 10000
local COLOR_STEADY = sm.color.new("d8b000ff") -- step debugger: on, but didn't change this tick
local COLOR_SOURCE = sm.color.new("ffffffff") -- Wire click mode: the picked source part
-- Click: Wire dots, like the connect tool's circles
local COLOR_DOT = sm.color.new("c8c8c8ff")        -- a part you can pick
local COLOR_DOT_HOVER = sm.color.new("ffd23cff")  -- the part you're aiming at
local COLOR_DOT_PICKED = sm.color.new("40ff60ff") -- the picked source
local DOT_MAX = 300       -- dots drawn at most, nearest first
local DOT_SIZE = 0.55     -- dot size as a fraction of its part (a logic gate: about 14 cm)
local DRAG_ARROW_GAP = 0.03 -- dragging: the arrow tip stops this close to the target's centre (m)
local DOT_HOVER_GROW = 1.5
local DOT_SNAP = 0.04     -- aim snaps to a dot this close to the crosshair (radians, about 2 degrees)
local DOT_REFRESH = 15    -- frames between re-reading which parts get dots
local WIRE_DRAG_TURN = 0.02 -- the view must turn this much (about 1 degree) for a press to count as a drag
local LOG_MAX = 200          -- wiring log entries kept per player (this session)
local LOG_DRAW_MAX = 300     -- wires of one entry sent to the client to draw

-- The game tick (40 a second), for "2 min ago"; nil if the game can't say.
local function nowTick()
	local ok, t = pcall(function() return sm.game.getCurrentTick() end)
	return ok and type(t) == "number" and t or nil
end

local function agoText(ticks)
	if not ticks then return "" end
	local s = math.floor(ticks / 40)
	if s < 60 then return s .. " s ago" end
	if s < 3600 then return math.floor(s / 60) .. " min ago" end
	return string.format("%d h %d min ago", math.floor(s / 3600), math.floor(s / 60) % 60)
end
local DEBUG_NET_LIMIT = 600     -- changed parts sent to the client per tick
local DEBUG_MAX_FRAMES = 300    -- changed parts framed in the world
local DEBUG_LOOKAHEAD = 64      -- countdown labels look this many ticks ahead
local DEBUG_LOOP_RISE = sm.vec3.new(0, 0, 0.4) -- an arrow into a part from itself starts this far above
local DEBUG_HINT = "Put the inputs in A and the outputs in B. Type the input values (A0 is the rightmost digit, "
	.. "missing digits are 0), or press From game and edit a digit. Then Start debug.\n\n"
	.. "The tool copies the logic between A and B as it is in the game now, sets your inputs, and lets you step "
	.. "that copy one tick at a time. The creation itself never changes.\n\n"
	.. "While stepping, with the tool in hand:\n"
	.. "  Left click    one tick forward\n"
	.. "  Right click   one tick back\n"
	.. "  Q             run / pause (at the run speed)\n"
	.. "  R             stop and open the menu\n\n"
	.. "Inputs:\n  Constant input: A stays at your values, like a switch.\n"
	.. "  1 tick pulse: A has them for one tick, then goes back, like a 1 tick button. A toggle memory needs this.\n"
	.. "  Pulse every N ticks: the inputs you set to 1 get a 1 tick pulse on tick 0, N, 2N ... (a clock). "
	.. "The ones set to 0 stay off.\n"
	.. "  Free after tick 0: A starts at them, then follows its own wiring (a loop or memory through A).\n\n"
	.. "Arrows show where each change goes next: #40ff60green#ffffff = turned on, #ff4040red#ffffff = turned off. "
	.. "A framed part changed on this tick. The number over a part is how many ticks until it changes next: "
	.. "it counts down as you step (1t, green, = next tick). Parts that will not change have none. "
	.. "An XOR wired to itself is a memory: its label says MEM on or MEM off. #d8b000Yellow#ffffff arrows are wires that are on but did not change."
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

local CONNECT_MODES = { allToAll = "All > All", zip = "Zip 1:1", chain = "Chain", ring = "Ring", selfWire = "Self" }
-- What the wiring buttons (All > All, Zip, Chain, Ring, Self) do: add wires, remove them, or toggle each pair.
local WIRE_MODES = { "connect", "cut", "flip" }
local WIRE_NAMES = { connect = "Mode: Connect", cut = "Mode: Cut", flip = "Mode: Flip" }
local WIRE_VERBS = { connect = "Connect", cut = "Cut", flip = "Flip" }

-- Bulk edit: the gate mode the Set gates button gives the active group
-- (index i is the game's mode i - 1)
local BULK_MODES = { "AND", "OR", "XOR", "NAND", "NOR", "XNOR" }

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

-- Parts are numbered from 0 for the player (A0, A1 ...), like bits: A0 is
-- worth 1, A1 2, A2 4. Lists inside the code stay 1-based (Lua), so the k-th
-- part of a list is shown as k - 1. Every name goes through partName.
local function partName(g, k) return g .. (k - 1) end

local function speedText(seconds)
	return string.format("%g s per tick", seconds)
end

-- The typed run speed ("0.5", "2", "0,5") in seconds per tick, or nil.
local function parseSpeed(text)
	local n = tonumber((tostring(text or ""):gsub("%s", ""):gsub(",", ".")))
	if n and n >= DEBUG_SPEED_MIN and n <= DEBUG_SPEED_MAX then return n end
end

local HELP_TEXT = [[CONTROLS
  Click / drag      add to the active group / box select
  Right click       next group
  F + click         pick every matching part (filter: the F: button)
  F + right click   delays from that part; again: delays to it; again: off
  Q                 switch to Click: Wire
  Q while dragging  box select mode: 3D / XY / XZ / YZ layer

CLICK: WIRE (the dropdown next to Active)
  Drag              from a dot to a dot: wire them (cut if already wired)
  Click             pick the source, then click the parts it feeds
  Right click       drop the source
  Q                 back to Click: Select
  Dots: grey = can pick, yellow = aimed at, green = the source.
  Aiming near a dot is enough. With parts in A, wiring starts only
  on A; with parts in B, it ends only on B.

LOG (Log window, then View log)
  Left / right click   older / newer entry
  Q                    undo the entry shown
  R                    stop

STEP DEBUGGER (Debug window, then Start debug)
  Left / right click   one tick forward / back
  Q                    run / pause
  R                    stop

SCRIPTS ARE LUA
A, B, C are lists of the parts you selected, in order.
Parts are numbered from 0, but Lua lists start at 1:
  A[1] is A0, A[2] is A1 ... and A[#A] is the last one.
A part p has: p.x p.y p.z (blocks), p.group, p.index (0 = first),
  p.kind ("gate" "timer" "input" "output"),
  p.mode ("AND" "OR" "XOR" "NAND" "NOR" "XNOR"),
  p.delay (ticks), p.color ("df7f00")

Wiring (a and b can be one part or a list):
  connect(a, b)          every a to every b
  connect(a, b, "zip")   a[1]>b[1], a[2]>b[2] ...
  cut(a, b)              remove connections
  flip(a, b)             connect if not wired, cut if wired
  chain(list)            list[1]>list[2]>list[3] ...
  ring(list)             chain, then last>first (3+ parts)
  selfWire(a)            each part to itself (XOR = memory)
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
	self.sv = { undo = {}, pending = {}, lutUndo = {}, debug = {}, log = {} }
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
		local entry = #pending.changed > 0 and self:sv_logAdd(player, data.label or "Wire", data.mode, pending) or nil
		self.network:sendToClient(player, "cl_onOpsDone", {
			made = pending.made, cut = pending.cut, skipped = pending.skipped,
			failed = pending.failed, isUndo = pending.isUndo, label = data.label, mode = data.mode,
			entry = entry, undoneId = data.undoneId,
		})
	end
end

---------------------------------------------------------------------------
-- SERVER: wiring log (every wire change made with the tool, this session)
---------------------------------------------------------------------------

-- Adds a batch of changes; returns the summary the client keeps.
function LogicTool:sv_logAdd(player, label, mode, pending)
	local log = self.sv.log[player.id]
	if not log then
		log = { entries = {}, nextId = 1 }
		self.sv.log[player.id] = log
	end
	local changes = {}
	for i, ch in ipairs(pending.changed) do changes[i] = { kind = ch.kind, p = ch.p, c = ch.c } end
	local e = { id = log.nextId, label = label, mode = mode, tick = nowTick(), changes = changes,
		made = pending.made, cut = pending.cut }
	log.nextId = log.nextId + 1
	log.entries[#log.entries + 1] = e
	if #log.entries > LOG_MAX then table.remove(log.entries, 1) end
	return { id = e.id, label = e.label, mode = e.mode, tick = e.tick, made = e.made, cut = e.cut }
end

local function logEntry(self, player, id)
	local log = self.sv.log[player.id]
	for _, e in ipairs(log and log.entries or {}) do
		if e.id == id then return e end
	end
end

function LogicTool:sv_logClear(_, player)
	self.sv.log[player.id] = nil
end

-- The wires of one entry, to draw them.
function LogicTool:sv_logShow(data, player)
	local e = logEntry(self, player, data.id)
	if not e then
		self.network:sendToClient(player, "cl_onLogEntry", { id = data.id, missing = true })
		return
	end
	local wires, gone = {}, 0
	for _, ch in ipairs(e.changes) do
		if sm.exists(ch.p) and sm.exists(ch.c) then
			if #wires < LOG_DRAW_MAX then wires[#wires + 1] = { kind = ch.kind, p = ch.p, c = ch.c } end
		else
			gone = gone + 1
		end
	end
	self.network:sendToClient(player, "cl_onLogEntry", {
		id = e.id, wires = wires, total = #e.changes, gone = gone, now = nowTick(),
	})
end

-- Undoes one entry (any entry, not only the last): what it connected is cut,
-- what it cut is connected again. Wires already back the way they were are
-- left alone. The undo is itself a new entry.
function LogicTool:sv_logUndo(data, player)
	local e = logEntry(self, player, data.id)
	if not e then
		self.network:sendToClient(player, "cl_message", "That log entry is gone (the log keeps the last " .. LOG_MAX .. ")")
		return
	end
	local ops = {}
	for i = #e.changes, 1, -1 do
		local ch = e.changes[i]
		ops[#ops + 1] = { kind = ch.kind == "connect" and "cut" or "connect", p = ch.p, c = ch.c }
	end
	self:sv_applyOps({ ops = ops, first = true, last = true, label = "Undo of #" .. e.id, undoneId = e.id }, player)
end

function LogicTool:sv_undo(data, player)
	local stack = self.sv.undo[player.id]
	local batch = stack and stack[#stack]
	if not batch and self.sv.lutUndo[player.id] then
		-- no wiring left to undo since the last rebuild: undo the rebuild
		self:sv_lutUndo(data, player)
		return
	end
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
	self:sv_applyOps({ ops = ops, first = true, last = true, isUndo = true, label = "Undo button" }, player)
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

-- true when every part in the lists is on one creation (bodies joined by
-- bearings/pistons count as one creation, like the game's lift)
local function sameCreation(lists)
	local bodies
	for _, list in ipairs(lists) do
		for _, inter in ipairs(list or {}) do
			local shape = sm.exists(inter) and inter:getShape()
			if shape and sm.exists(shape) then
				if not bodies then
					bodies = {}
					for _, b in ipairs(shape.body:getCreationBodies()) do bodies[b.id] = true end
				elseif not bodies[shape.body.id] then
					return false
				end
			end
		end
	end
	return true
end

-- On or off in the game right now. isActive is what the game shows; vanilla
-- parts also report it as power (1/0), so either counts.
local function partIsOn(inter)
	if inter:isActive() then return true end
	local ok, power = pcall(function() return inter.power end)
	return ok and type(power) == "number" and power ~= 0
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

-- Load A (inputs) > B (outputs) as a module: its truth table, what is
-- inside, and where it leaks. Returns module, error, leak parts.
function LogicTool:sv_loadModule(graph, inters, labels, data, A, B)
	if #A == 0 or #B == 0 then
		return nil, "Load needs the inputs in A and the outputs in B"
	end
	if #A > LogicModule.MAX_INPUTS then
		return nil, string.format("A has %d inputs; a module can have at most %d", #A, LogicModule.MAX_INPUTS)
	end
	if #B > MODULE_MAX_OUTPUTS then
		return nil, string.format("B has %d outputs; a module can have at most %d", #B, MODULE_MAX_OUTPUTS)
	end
	local inA = {}
	for _, id in ipairs(A) do inA[id] = true end
	for _, id in ipairs(B) do
		if inA[id] then return nil, "A part can't be in both A (inputs) and B (outputs)" end
	end
	if not sameCreation({ data.A, data.B }) then
		return nil, "A and B must be on the same creation"
	end

	local rows, err = LogicGraph.truthTable(graph, A, B, 4000)
	if not rows then return nil, err end
	local m = LogicModule.fromTruth(rows, #A, #B)
	local inside = LogicModule.inside(graph, A, B)
	m.inside = #inside.parts
	m.extraIn = #inside.extraIn
	m.extraOut = #inside.extraOut
	m.inputTypes, m.outputTypes = {}, {}
	for k, id in ipairs(A) do m.inputTypes[k] = labels[id] or "?" end
	for k, id in ipairs(B) do m.outputTypes[k] = labels[id] or "?" end
	-- a gate B can become the LUT's OR itself; others need an OR in front
	m.outputGates = {}
	for k, id in ipairs(B) do m.outputGates[k] = graph[id] ~= nil and graph[id].kind == "gate" end
	return m, nil, limitedInters(inside.extraIn, inters, NET_LIST_LIMIT)
end

---------------------------------------------------------------------------
-- SERVER: build a module as a LUT (rebuilds the creation from its blueprint,
-- the same way Bingo's block editor does)
---------------------------------------------------------------------------

-- Blueprint child of every part on the creation of `body`, as
-- { [interactable id] = child }. Same matching as readControllers.
local function blueprintChilds(body, bp)
	local ordered = { body }
	for _, b in ipairs(body:getCreationBodies()) do
		if b.id ~= body.id then ordered[#ordered + 1] = b end
	end
	local byCtrlId = {}
	for _, bpBody in ipairs(bp.bodies or {}) do
		for _, child in ipairs(bpBody.childs or {}) do
			if child.controller and child.controller.id then byCtrlId[child.controller.id] = child end
		end
	end
	local out = {}
	for bi, b in ipairs(ordered) do
		local childs = bp.bodies[bi] and bp.bodies[bi].childs or {}
		for si, shape in ipairs(b:getShapes()) do
			local inter = shape.interactable
			if inter then
				local uuid = tostring(shape.uuid)
				local child = childs[si]
				if not (child and child.shapeId == uuid and child.controller) then
					child = byCtrlId[inter.id]
					if child and child.shapeId ~= uuid then child = nil end
				end
				out[inter.id] = child
			end
		end
	end
	return out
end

-- Works out the whole build without changing anything. Returns a context
-- table, or nil and an error for the player.
function LogicTool:sv_lutPrepare(data)
	local Ain, Bin = {}, {}
	for _, i in ipairs(data.A or {}) do if sm.exists(i) then Ain[#Ain + 1] = i end end
	for _, i in ipairs(data.B or {}) do if sm.exists(i) then Bin[#Bin + 1] = i end end
	local rows = data.rows or {}
	if #Ain == 0 or #Bin == 0 then return nil, "Build needs the inputs in A and the outputs in B" end
	if #Ain > LogicModule.MAX_INPUTS then return nil, "Too many inputs in A" end
	if #rows ~= 2 ^ #Ain or #(rows[1] or {}) ~= #Bin then
		return nil, "A or B changed since Load: press Load A > B again"
	end
	local home = Ain[1]:getShape().body
	for _, list in ipairs({ Ain, Bin }) do
		for _, inter in ipairs(list) do
			if inter:getShape().body.id ~= home.id then
				return nil, "For Build, all of A and B must be on one body (not split by bearings or pistons)"
			end
		end
	end

	local graph, inters = self:sv_buildGraph(Ain)
	local A, B = idsOf(Ain), idsOf(Bin)
	local inside = LogicModule.inside(graph, A, B)
	local function onHome(id)
		local inter = inters[id]
		return inter ~= nil and sm.exists(inter) and inter:getShape().body.id == home.id
	end

	-- the old circuit goes completely, or stays completely: half of it would
	-- only be clutter wired to A
	local circuit = LogicModule.oldCircuit(graph, inside, A, B)
	local inCircuit, otherBody = {}, false
	for _, id in ipairs(circuit.parts) do
		inCircuit[id] = true
		if not onHome(id) then otherBody = true end
	end
	local keepReason
	if #circuit.usedOutside > 0 then
		keepReason = string.format("it also drives %d other part(s)", #circuit.usedOutside)
	elseif otherBody then
		keepReason = "part of it is on another body"
	end

	-- gates whose only job is feeding A move along with A
	local helpers = LogicModule.helpers(graph, A, inCircuit, onHome)

	local lifted = home:isOnLift()
	local okExp, bp = pcall(sm.creation.exportToTable, home, true, lifted)
	if not (okExp and type(bp) == "table" and bp.bodies) then return nil, "Couldn't read the creation's blueprint" end
	local okOld, oldBp = pcall(sm.creation.exportToTable, home, true, lifted)
	if not okOld then return nil, "Couldn't read the creation's blueprint" end

	local childs = blueprintChilds(home, bp)
	local refs = { body = 1, A = {}, B = {}, remove = {}, helpers = {} }
	for k, id in ipairs(A) do refs.A[k] = childs[id] end
	for k, id in ipairs(B) do refs.B[k] = childs[id] end
	for k = 1, #A do if not refs.A[k] then return nil, "Couldn't find " .. partName("A", k) .. " in the blueprint" end end
	for k = 1, #B do if not refs.B[k] then return nil, "Couldn't find " .. partName("B", k) .. " in the blueprint" end end
	local removeInters, keptInters = {}, {}
	for _, id in ipairs(circuit.parts) do
		local child, inter = childs[id], inters[id]
		if keepReason or not child then
			if inter then keptInters[#keptInters + 1] = inter end
		else
			refs.remove[child] = true
			removeInters[#removeInters + 1] = inter
		end
	end
	for _, h in ipairs(helpers) do
		if childs[h.id] then refs.helpers[#refs.helpers + 1] = { child = childs[h.id], input = h.input } end
	end
	-- unwired gates hidden in the removed cluster's blocks go with it
	if not keepReason then
		local interOf = {}
		for id, child in pairs(childs) do interOf[child] = inters[id] end
		for _, child in ipairs(LogicModule.strayInCells(bp, refs.remove)) do
			local inter = interOf[child]
			if inter and onHome(inter.id) then
				refs.remove[child] = true
				removeInters[#removeInters + 1] = inter
			end
		end
	end

	local m = { kind = "lut", inputs = {}, outputs = {}, rows = {} }
	for k = 1, #A do m.inputs[k] = partName("A", k) end
	for k = 1, #B do m.outputs[k] = partName("B", k) end
	for i, outs in ipairs(rows) do
		local o = {}
		for k = 1, #B do o[k] = outs[k] == 1 and 1 or 0 end
		m.rows[i] = { outs = o, settled = true }
	end
	local bIsGate = {}
	for k, id in ipairs(B) do bIsGate[k] = graph[id] ~= nil and graph[id].kind == "gate" end
	local plan = LogicModule.lutPlan(m, { style = data.style, even = data.even ~= false, compress = data.compress == true, bIsGate = bIsGate })
	if #plan.problems > 0 then return nil, "Can't build: " .. plan.problems[1] end

	-- for the preview: a known part's cell and world position, to place the rest
	local refShape = Ain[1]:getShape()
	local refCell = LogicModule.cellOf(refs.A[1])
	local origin = LogicModule.placeOnTop(bp.bodies[1])
	local childOf, moves = LogicModule.applyLut(bp, plan, refs, origin)

	-- the game's wire limits, counting the rest of the creation's wires too
	local over = LogicModule.wireLimits(bp)
	if #over > 0 then
		local name = "a part outside the module"
		for ref, child in pairs(childOf) do
			if child == over[1].child then name = LogicModule.refName(ref) end
		end
		return nil, string.format("Can't build: %s would have %d inputs and %d outputs (the game allows %d each)",
			name, over[1].ins, over[1].outs, LogicModule.MAX_WIRES)
	end

	return {
		bp = bp, oldBp = oldBp, home = home, lifted = lifted, plan = plan, childOf = childOf, moves = moves,
		origin = origin, refCell = refCell, refPos = refShape.worldPosition, rot = home.worldRotation,
		removeInters = removeInters, keptInters = keptInters, keepReason = keepReason,
		helpers = #refs.helpers, nA = #A, nB = #B,
	}
end

-- A rebuilt creation comes back standing free; put it on the player's lift
-- again (Bingo's editor does the same). `lift` = { pos (m), level } from the
-- client. The lift is moved under the new creation's centre, so a creation
-- that grew doesn't jump; rotation 0 keeps it as it stands (the game's lift
-- tool also starts every pickup at 0).
function LogicTool:sv_relift(player, creation, lift)
	if not (lift and lift.pos and lift.level) then return false end
	local ok = pcall(function()
		local lowest, highest
		for _, b in ipairs(creation) do
			if sm.exists(b) then
				local lo, hi = b:getWorldAabb()
				lowest = lowest and lowest:min(lo) or lo
				highest = highest and highest:max(hi) or hi
			end
		end
		local base = lift.pos * 4 -- the lift's grid position (blocks)
		local pos = sm.vec3.new(base.x, base.y, base.z)
		if lowest then
			local diff = ((lowest + highest) * 0.5 - lift.pos) * 4
			local function snap(v)
				if v >= -1 and v <= 1 then return 0 end
				return math.floor(v + 0.5)
			end
			pos = sm.vec3.new(base.x + snap(diff.x), base.y + snap(diff.y), base.z)
		end
		sm.player.placeLift(player, creation, pos, lift.level, 0)
	end)
	return ok
end

function LogicTool:sv_lutBuild(data, player)
	local ok, err = pcall(function()
		local ctx, perr = self:sv_lutPrepare(data)
		if not ctx then
			self.network:sendToClient(player, "cl_onLutBuilt", { error = perr })
			return
		end

		if not data.apply then
			-- preview: where everything goes, as world positions
			local function world(c)
				local d = sm.vec3.new(c[1] - ctx.refCell[1], c[2] - ctx.refCell[2], c[3] - ctx.refCell[3]) * 0.25
				return ctx.refPos + ctx.rot * d
			end
			local cells = {}
			local o = ctx.origin
			for _, p in ipairs(ctx.plan.parts) do
				cells[#cells + 1] = { pos = world(LogicModule.toBody(o, p.x, p.y, p.z)), kind = "new" }
			end
			for _, mv in ipairs(ctx.moves) do
				-- helpers (H...) travel with A, so they get A's colour
				local kind = mv.ref:sub(1, 1)
				cells[#cells + 1] = { pos = world(LogicModule.toBody(o, mv.x, mv.y, mv.z)), kind = kind == "H" and "A" or kind }
			end
			self.network:sendToClient(player, "cl_onLutPreview", {
				cells = cells, rot = ctx.rot, remove = ctx.removeInters, keep = ctx.keptInters, keepReason = ctx.keepReason,
				helpers = ctx.helpers, gates = ctx.plan.counts.gates, lifted = ctx.lifted,
			})
			return
		end

		local creation = sm.creation.importFromString(sm.world.getCurrentWorld(), sm.json.writeJsonString(ctx.bp), nil, nil, true)
		if not creation or not creation[1] then
			self.network:sendToClient(player, "cl_onLutBuilt", { error = "The game refused the new blueprint; nothing was changed" })
			return
		end
		for _, shape in ipairs(ctx.home:getCreationShapes()) do
			if sm.exists(shape) then shape:destroyShape() end
		end
		local relifted = ctx.lifted and self:sv_relift(player, creation, data.lift) or false
		self.sv.lutUndo[player.id] = { json = sm.json.writeJsonString(ctx.oldBp), bodies = creation }
		self.sv.undo[player.id] = {} -- wire undo pointed at the old parts

		-- the new parts in blueprint order: find the new A and B
		-- (by blueprint order; if the game ordered them differently, by position)
		local function newInter(child)
			local body = creation[1]
			local shapes = body:getShapes()
			for si, c in ipairs(ctx.bp.bodies[1].childs) do
				if c == child then
					local shape = shapes[si]
					if shape and tostring(shape.uuid) == child.shapeId then return shape.interactable end
				end
			end
			for _, shape in ipairs(shapes) do
				local lp = shape.localPosition
				if lp and tostring(shape.uuid) == child.shapeId and lp.x == child.pos.x and lp.y == child.pos.y and lp.z == child.pos.z then
					return shape.interactable
				end
			end
		end
		local newA, newB = {}, {}
		for k = 1, ctx.nA do newA[k] = newInter(ctx.childOf["A" .. k]) end
		for k = 1, ctx.nB do newB[k] = newInter(ctx.childOf["B" .. k]) end
		local found = #newA == ctx.nA and #newB == ctx.nB
		self.network:sendToClient(player, "cl_onLutBuilt", {
			A = found and newA or nil, B = found and newB or nil,
			gates = ctx.plan.counts.gates, removed = #ctx.removeInters, lifted = ctx.lifted, relifted = relifted,
		})
	end)
	if not ok then
		self.network:sendToClient(player, "cl_onLutBuilt", { error = "Build failed: " .. tostring(err) })
	end
end

-- Where each part sits in a blueprint: { [interactable id] = { bi, si, uuid, pos } }
-- (body and shape index, as blueprintChilds matched them), to find the same
-- parts again after the creation is rebuilt from that blueprint.
local function partKeys(body, bp, inters)
	local childs = blueprintChilds(body, bp)
	local where = {}
	for bi, bpBody in ipairs(bp.bodies or {}) do
		for si, child in ipairs(bpBody.childs or {}) do where[child] = { bi, si } end
	end
	local keys = {}
	for _, inter in ipairs(inters) do
		local child = sm.exists(inter) and childs[inter.id]
		local w = child and where[child]
		if w then keys[inter.id] = { bi = w[1], si = w[2], uuid = child.shapeId, pos = child.pos } end
	end
	return keys
end

-- The part at `key` in a rebuilt creation (bodies in blueprint order): by
-- index first, then by type and position.
local function findRebuilt(creation, key)
	local function at(body)
		if not (body and sm.exists(body)) then return end
		local shape = body:getShapes()[key.si]
		if shape and tostring(shape.uuid) == key.uuid and shape.interactable then return shape.interactable end
	end
	local function byPos(body)
		if not (body and sm.exists(body)) then return end
		for _, shape in ipairs(body:getShapes()) do
			local lp = shape.localPosition
			if lp and shape.interactable and tostring(shape.uuid) == key.uuid
				and lp.x == key.pos.x and lp.y == key.pos.y and lp.z == key.pos.z then
				return shape.interactable
			end
		end
	end
	local found = at(creation[key.bi]) or byPos(creation[key.bi])
	if found then return found end
	for bi, body in ipairs(creation) do
		if bi ~= key.bi then
			found = byPos(body)
			if found then return found end
		end
	end
end

-- The player's groups ({ A = {inters}, ... }) moved onto the rebuilt parts.
local function remapGroups(groups, keys, creation)
	local out = {}
	for g, list in pairs(groups or {}) do
		out[g] = {}
		for _, inter in ipairs(list) do
			local key = keys[inter.id]
			local new = key and findRebuilt(creation, key)
			if new then out[g][#out[g] + 1] = new end
		end
	end
	return out
end

local function allGroupInters(groups)
	local all = {}
	for _, list in pairs(groups or {}) do
		for _, inter in ipairs(list) do all[#all + 1] = inter end
	end
	return all
end

-- The wiring log points at parts; a rebuild (bulk edit, or undoing one)
-- makes new ones. Before it: every part of the creation the log mentions,
-- and where it sits (logMark). After it: the log points at the new parts
-- (logFollow). Without this every older entry would have nothing to show.
local function logInters(self, onBodies)
	local out, seen = {}, {}
	for _, log in pairs(self.sv.log) do
		for _, e in ipairs(log.entries) do
			for _, ch in ipairs(e.changes) do
				for _, inter in ipairs({ ch.p, ch.c }) do
					if sm.exists(inter) and not seen[inter.id] and onBodies[inter:getShape().body.id] then
						seen[inter.id] = true
						out[#out + 1] = inter
					end
				end
			end
		end
	end
	return out
end

local function logMark(self, keys)
	for _, log in pairs(self.sv.log) do
		for _, e in ipairs(log.entries) do
			for _, ch in ipairs(e.changes) do
				ch.pKey = sm.exists(ch.p) and keys[ch.p.id] or nil
				ch.cKey = sm.exists(ch.c) and keys[ch.c.id] or nil
			end
		end
	end
end

local function logFollow(self, creation)
	for _, log in pairs(self.sv.log) do
		for _, e in ipairs(log.entries) do
			for _, ch in ipairs(e.changes) do
				if ch.pKey then ch.p = findRebuilt(creation, ch.pKey) or ch.p end
				if ch.cKey then ch.c = findRebuilt(creation, ch.cKey) or ch.c end
				ch.pKey, ch.cKey = nil, nil
			end
		end
	end
end

local function bodySet(body)
	local set = {}
	for _, b in ipairs(body:getCreationBodies()) do set[b.id] = true end
	return set
end

local function join(a, b)
	local out = {}
	for _, x in ipairs(a) do out[#out + 1] = x end
	for _, x in ipairs(b) do out[#out + 1] = x end
	return out
end

-- Bulk edit: every gate in data.inters gets data.mode, or every timer gets
-- data.seconds / data.ticks. Lua can't change these on a part, so the
-- creation is rebuilt from an edited blueprint (like Build LUT), goes back on
-- the lift, and can be undone. The groups follow the rebuilt parts.
function LogicTool:sv_bulkEdit(data, player)
	local function reply(r) self.network:sendToClient(player, "cl_onBulkEdit", r) end
	local ok, err = pcall(function()
		local targets = {}
		for _, inter in ipairs(data.inters or {}) do
			if sm.exists(inter) then targets[#targets + 1] = inter end
		end
		if #targets == 0 then reply({ error = "Select the parts to edit in the active group first" }) return end
		local want = data.mode ~= nil and "gate" or "timer"
		local home = targets[1]:getShape().body
		local onHome = {}
		for _, b in ipairs(home:getCreationBodies()) do onHome[b.id] = true end

		local lifted = home:isOnLift()
		local okExp, bp = pcall(sm.creation.exportToTable, home, true, lifted)
		if not (okExp and type(bp) == "table" and bp.bodies) then reply({ error = "Couldn't read the creation's blueprint" }) return end
		local oldJson = sm.json.writeJsonString(bp)
		local childs = blueprintChilds(home, bp)

		local changed, same, other, elsewhere, missing = 0, 0, 0, 0, 0
		for _, inter in ipairs(targets) do
			local shape = inter:getShape()
			local child = childs[inter.id]
			local ctrl = child and child.controller
			if not onHome[shape.body.id] then
				elsewhere = elsewhere + 1
			elseif kindOf(inter, shape) ~= want then
				other = other + 1
			elseif not ctrl then
				missing = missing + 1
			elseif want == "gate" then
				if ctrl.mode == data.mode then same = same + 1 else ctrl.mode = data.mode changed = changed + 1 end
			else
				if ctrl.seconds == data.seconds and ctrl.ticks == data.ticks then
					same = same + 1
				else
					ctrl.seconds, ctrl.ticks = data.seconds, data.ticks
					changed = changed + 1
				end
			end
		end
		local counts = { changed = changed, same = same, other = other, elsewhere = elsewhere, missing = missing, kind = want }
		if changed == 0 then reply(counts) return end

		local keys = partKeys(home, bp, join(allGroupInters(data.groups), logInters(self, onHome)))
		logMark(self, keys)
		local creation = sm.creation.importFromString(sm.world.getCurrentWorld(), sm.json.writeJsonString(bp), nil, nil, true)
		if not creation or not creation[1] then reply({ error = "The game refused the edited blueprint; nothing was changed" }) return end
		for _, shape in ipairs(home:getCreationShapes()) do
			if sm.exists(shape) then shape:destroyShape() end
		end
		counts.relifted = lifted and self:sv_relift(player, creation, data.lift) or false
		counts.lifted = lifted
		counts.groups = remapGroups(data.groups, keys, creation)
		logFollow(self, creation)
		self.sv.lutUndo[player.id] = { json = oldJson, bodies = creation, kind = "edit" }
		self.sv.undo[player.id] = {} -- wire undo pointed at the old parts
		reply(counts)
	end)
	if not ok then reply({ error = "Edit failed: " .. tostring(err) }) end
end

-- Puts back the creation as it was before the last build or bulk edit.
function LogicTool:sv_lutUndo(data, player)
	local u = self.sv.lutUndo[player.id]
	if not u then
		self.network:sendToClient(player, "cl_message", "No build to undo")
		return
	end
	local body
	for _, b in ipairs(u.bodies) do if sm.exists(b) then body = b break end end
	local lifted = body ~= nil and body:isOnLift()
	local creation = sm.creation.importFromString(sm.world.getCurrentWorld(), u.json, nil, nil, true)
	if not creation then
		self.network:sendToClient(player, "cl_message", "#ff4040Undo build failed: the game refused the old blueprint")
		return
	end
	-- a bulk edit moves nothing, so the groups and the log can follow the
	-- parts back
	local groups
	if u.kind == "edit" and body then
		local okExp, bp = pcall(sm.creation.exportToTable, body, true, lifted)
		if okExp and type(bp) == "table" and bp.bodies then
			local groupInters = allGroupInters(data and data.groups)
			local keys = partKeys(body, bp, join(groupInters, logInters(self, bodySet(body))))
			if data and data.groups then groups = remapGroups(data.groups, keys, creation) end
			logMark(self, keys)
			logFollow(self, creation)
		end
	end
	if body then
		for _, shape in ipairs(body:getCreationShapes()) do
			if sm.exists(shape) then shape:destroyShape() end
		end
	end
	local relifted = lifted and self:sv_relift(player, creation, data and data.lift) or false
	self.sv.lutUndo[player.id] = nil
	self.sv.undo[player.id] = {}
	self.network:sendToClient(player, "cl_onLutBuilt", { undone = true, kind = u.kind, groups = groups, lifted = lifted, relifted = relifted })
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
					-- like a binary number: highest first, so A0 and B0 are on the right
					reply.rows = {}
					for _, row in ipairs(rows) do
						local a, b = {}, {}
						for k = #row.ins, 1, -1 do a[#a + 1] = row.ins[k] and "1" or "0" end
						for k = #row.outs, 1, -1 do b[#b + 1] = row.outs[k] and "1" or "0" end
						reply.rows[#reply.rows + 1] = table.concat(a, " ") .. "  |  " .. table.concat(b, " ") .. (row.settled and "" or "   (never settles)")
					end
				end
			end
		elseif data.kind == "module" then
			reply.module, reply.error, reply.leaks = self:sv_loadModule(graph, inters, labels, data, A, B)
		end

		self.network:sendToClient(player, "cl_onAnalysis", reply)
	end)

	if not ok then
		self.network:sendToClient(player, "cl_message", "#ff4040Analysis failed: " .. tostring(err))
	end
end

---------------------------------------------------------------------------
-- SERVER: step debugger (a copy of the logic between A and B, stepped one
-- tick at a time; see LogicGraph.debugStart)
---------------------------------------------------------------------------

function LogicTool:sv_debugStart(data, player)
	local ok, err = pcall(function()
		local A, B = data.A or {}, data.B or {}
		if #A == 0 or #B == 0 then
			self.network:sendToClient(player, "cl_onDebug", { error = "Debug needs the inputs in A and the outputs in B" })
			return
		end
		local seeds = {}
		for _, list in ipairs({ A, B }) do
			for _, inter in ipairs(list) do seeds[#seeds + 1] = inter end
		end
		local graph, inters = self:sv_buildGraph(seeds)
		local Aid, Bid = idsOf(A), idsOf(B)
		local inside = LogicModule.inside(graph, Aid, Bid)
		local parts, seen = {}, {}
		for _, list in ipairs({ Aid, Bid, inside.parts }) do
			for _, id in ipairs(list) do
				if graph[id] and not seen[id] then
					seen[id] = true
					parts[#parts + 1] = id
				end
			end
		end
		-- what the game shows now
		local snapshot = {}
		for id, inter in pairs(inters) do
			if sm.exists(inter) then snapshot[id] = partIsOn(inter) end
		end
		local d = LogicGraph.debugStart(graph, parts, snapshot, Aid, data.inputs or {}, { mode = data.mode, every = data.every })
		d.inters, d.A, d.B = inters, Aid, Bid
		d.mems = {}
		for _, id in ipairs(parts) do
			if LogicGraph.isXorMemory(graph, id) then d.mems[#d.mems + 1] = id end
		end
		-- only what is between A and B is shown; what feeds it runs along unseen
		d.show = seen
		local simulated = 0
		for _ in pairs(d.graph) do simulated = simulated + 1 end
		self.sv.debug[player.id] = d

		-- gates whose mode couldn't be read never turn on in the copy
		local unknown = 0
		for _, id in ipairs(parts) do
			if graph[id].kind == "gate" and graph[id].mode == nil then unknown = unknown + 1 end
		end
		self:sv_debugReply(player, d, { start = true, size = #parts, between = #inside.parts, simulated = simulated,
			unknown = unknown })
	end)
	if not ok then
		self.network:sendToClient(player, "cl_onDebug", { error = "Debug failed: " .. tostring(err) })
	end
end

function LogicTool:sv_debugReply(player, d, r)
	r = r or {}
	local values = d.state.values
	local changed = d.changes[d.tick]
	r.tick, r.last = d.tick, d.last
	r.changedCount, r.otherCount = 0, 0
	r.changed = {}
	-- shown parts that are on and didn't change: their wires show yellow
	local didChange = {}
	for _, id in ipairs(changed) do didChange[id] = true end
	r.steady = {}
	for id in pairs(d.show) do
		if values[id] and not didChange[id] and #r.steady < DEBUG_NET_LIMIT then
			local inter = d.inters[id]
			if inter and sm.exists(inter) then r.steady[#r.steady + 1] = inter end
		end
	end
	for _, id in ipairs(changed) do
		if d.show[id] then
			r.changedCount = r.changedCount + 1
			local inter = d.inters[id]
			if #r.changed < DEBUG_NET_LIMIT and inter and sm.exists(inter) then
				r.changed[#r.changed + 1] = { inter = inter, on = values[id] or false }
			end
		else
			r.otherCount = r.otherCount + 1
		end
	end
	-- binary numbers, highest first: A0 and B0 are the rightmost digits
	local function bits(ids)
		local o = {}
		for k = #ids, 1, -1 do o[#o + 1] = values[ids[k]] and "1" or "0" end
		return table.concat(o)
	end
	r.inputs, r.outputs = bits(d.A), bits(d.B)
	r.settled = LogicGraph.debugSettled(d)
	r.lastChange = LogicGraph.debugLastChange(d)
	local counts = LogicGraph.debugChangeCounts(d, d.B)
	r.glitches = {}
	for k, id in ipairs(d.B) do
		if counts[id] > 1 then r.glitches[#r.glitches + 1] = { k = k, n = counts[id] } end
	end
	-- XOR memories: on or off right now
	r.mems = {}
	for _, id in ipairs(d.mems) do
		local inter = d.inters[id]
		if #r.mems < DEBUG_NET_LIMIT and inter and sm.exists(inter) then
			r.mems[#r.mems + 1] = { inter = inter, on = values[id] or false }
		end
	end
	-- countdown: in how many ticks each shown part changes next
	local showIds = {}
	for id in pairs(d.show) do showIds[#showIds + 1] = id end
	local ahead = LogicGraph.debugLookahead(d, showIds, DEBUG_LOOKAHEAD)
	r.next = {}
	r.soonest = nil
	for id, n in pairs(ahead) do
		local inter = d.inters[id]
		if #r.next < DEBUG_NET_LIMIT and inter and sm.exists(inter) then r.next[#r.next + 1] = { inter = inter, n = n } end
		if not r.soonest or n < r.soonest then r.soonest = n end
	end
	self.network:sendToClient(player, "cl_onDebug", r)
end

function LogicTool:sv_debugStep(data, player)
	local d = self.sv.debug[player.id]
	if not d then
		self.network:sendToClient(player, "cl_onDebug", { error = "The debug session has ended", stop = true })
		return
	end
	local ok, err = pcall(function()
		local moved, why
		if data.dir < 0 then
			moved = LogicGraph.debugBack(d)
		else
			moved, why = LogicGraph.debugForward(d)
		end
		self:sv_debugReply(player, d, { edge = not moved and (why or "start") or nil })
	end)
	if not ok then
		self.sv.debug[player.id] = nil
		self.network:sendToClient(player, "cl_onDebug", { error = "Debug failed: " .. tostring(err), stop = true })
	end
end

function LogicTool:sv_debugStop(_, player)
	self.sv.debug[player.id] = nil
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
		labelMode = 2,                         -- order numbers (A0, A1 ...) by default
		showLines = true,
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
		libPos = nil,                          -- index in the script library (< >) of the loaded script
		libLoaded = nil,                       -- the code as it was loaded/saved (to spot unsaved edits)
		library = {},                          -- saved scripts { name =, code = }
		scriptNameText = "",                   -- the library name box
		confirm = nil,                         -- an action waiting for a second press ("libNext", "libDelete" ...)
		saveIn = nil,                          -- seconds until the settings are saved (nil = nothing to save)
		script = "",
		leftWindow = nil,                      -- "script", "settings" or "module": the window shown on the left
		module = nil,                          -- the last loaded module (LogicModule table)
		moduleRows = nil,                      -- the edited table's rows, nil = as loaded
		moduleError = nil,                     -- "line 3: ..." when the edited table can't be read
		lutCompress = false,                   -- setting: stack each LUT gate column in one block
		lutEven = true,                        -- setting: buffers too, so every path is 3 ticks
		lutStyle = 1,                          -- setting: index in LUT_STYLES
		lutPreview = nil,                      -- { effects = {} } while a build preview is shown
		verifyRows = nil,                      -- while building: the table the new logic must match
		verify = nil,                          -- after a build: { rows, wait, tries } (see cl_updateVerify)
		debug = nil,                           -- while stepping: { view =, running =, timer =, pending = }
		debugSpeedText = "1",                  -- setting: Run speed, seconds per tick
		debugInputMode = 1,                    -- setting: index in DEBUG_INPUT_MODES
		debugEveryText = "4",                  -- setting: N for "Pulse every N ticks"
		debugInputText = "",                   -- the debug window's input digits
		bulkMode = 3,                          -- setting: index in BULK_MODES (XOR)
		clickMode = 1,                         -- setting: index in CLICK_MODES
		wireSource = nil,                      -- Click: Wire: { inter =, effect = } the picked source
		wireDrag = nil,                        -- Click: Wire: { dir = } while the button is held after picking
		wireList = nil,                        -- Click: Wire: the parts that get dots now
		wireAim = nil,                         -- Click: Wire: the part the crosshair snaps to
		wireCache = nil,                       -- Click: Wire: { asTarget, src, bodies, list, set, frames }
		dots = {},                             -- Click: Wire: pooled dot effects
		log = {},                              -- wiring log summaries { id, label, tick, made, cut, undone }, oldest first
		logView = nil,                         -- while browsing the log: { pos =, entry =, pending = }
		bulkTimerText = "0s 5t",               -- setting: what Set timers sets
		bulkBusy = false,                      -- a bulk edit is on its way to the server
		debugFrames = {},                      -- frames on the parts that changed this tick
		press = nil,
	}

	if not self.tool:isLocal() then return end

	-- the game's hover glow (part silhouette drawn on top), see Effects/
	self.cl.hover = sm.effect.createEffect("TobyWand-Hover")

	self.cl.box = sm.effect.createEffect("ShapeRenderable")
	self.cl.box:setParameter("uuid", PLASTIC_UUID)
	self.cl.box:setParameter("visualization", true)

	local gui = sm.gui.createGuiFromLayout("$CONTENT_DATA/Gui/Layouts/LogicTool.layout", false)
	for _, name in ipairs({ "close", "clearActive", "clearAll", "undo", "sortX", "sortY", "sortZ", "reverse",
		"allToAll", "zip", "chain", "ring", "selfWire", "clearOut", "clearIn", "timing", "truth", "lint",
		"clearMarks", "libPrev", "libNext", "libSave", "libDelete", "run", "help", "probeFwd", "probeBack", "openScript", "closeScript", "openSettings", "closeSettings", "openModule", "closeModule", "loadModule", "resetModule", "buildLut", "cancelLut", "undoLut", "format",
		"openDebug", "closeDebug", "debugFromGame", "debugStart", "openLog", "closeLog", "logView", "logClear", "setGates", "setTimers" }) do
		gui:setButtonCallback(name, "cl_onButton")
	end
	gui:setTextChangedCallback("script", "cl_onScriptChanged")
	gui:setTextChangedCallback("moduleTable", "cl_onModuleTableChanged")
	gui:setTextChangedCallback("debugInputs", "cl_onDebugInputsChanged")
	gui:setTextChangedCallback("debugEvery", "cl_onDebugEveryChanged")
	gui:setTextChangedCallback("debugSpeed", "cl_onDebugSpeedChanged")
	gui:setTextChangedCallback("scriptName", "cl_onScriptNameChanged")
	gui:setTextChangedCallback("bulkTimer", "cl_onBulkTimerChanged")
	self:cl_createDropDowns(gui)
	gui:setText("debugEvery", self.cl.debugEveryText)
	gui:setText("debugInfo", DEBUG_HINT)
	self.cl.gui = gui

	-- the step debugger panel: a HUD, so the mouse keeps turning the view
	self.cl.stepGui = sm.gui.createGuiFromLayout("$CONTENT_DATA/Gui/Layouts/LogicTool_Step.layout", false,
		{ isHud = true, isInteractive = false, needsCursor = false })

	self.cl.script = LogicScript.examples[1].code
	self:cl_loadSaved()
	gui:setText("scriptName", self.cl.scriptNameText)
	gui:setText("debugInputs", self.cl.debugInputText)
	gui:setText("debugEvery", self.cl.debugEveryText)
	gui:setText("debugSpeed", self.cl.debugSpeedText)
	gui:setText("bulkTimer", self.cl.bulkTimerText)
	self:cl_showScript()
	self:cl_showModuleInfo()
	self:cl_refreshGui()
end

function LogicTool:client_onDestroy()
	if not self.cl or not self.tool:isLocal() then return end
	self:cl_clearAllVisuals()
	self:cl_setWireSource(nil)
	self:cl_clearDebugFrames()
	for _, e in ipairs({ self.cl.hover, self.cl.box }) do
		if e and sm.exists(e) then e:destroy() end
	end
	for _, l in ipairs(self.cl.lines) do
		if sm.exists(l) then l:destroy() end
	end
	for _, lab in ipairs(self.cl.labels) do
		pcall(lab.destroy, lab)
	end
	if self.cl.saveIn then self:cl_saveSettings() end
	if self.cl.gui then pcall(self.cl.gui.destroy, self.cl.gui) end
	if self.cl.stepGui then pcall(self.cl.stepGui.destroy, self.cl.stepGui) end
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
		sm.gui.displayAlertText("TobyWand:  R = menu   Q = select / wire (while dragging: box mode)   F+click = pick matching   F+right click = delays", 5)
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
	if self.tool:isEquipped() then e:start() end
	markers[inter.id] = e
	self:cl_fitMarkers(inter.id)
end

function LogicTool:cl_removeMarker(g, interId)
	local e = self.cl.markers[g][interId]
	if e and sm.exists(e) then e:destroy() end
	self.cl.markers[g][interId] = nil
	self:cl_fitMarkers(interId)
end

-- Sizes the frames of one part: its groups in A, B, C order get the frames
-- from tightest to widest.
function LogicTool:cl_fitMarkers(interId)
	local k = 0
	for _, g in ipairs(GROUPS) do
		local e = self.cl.markers[g][interId]
		if e and sm.exists(e) then
			k = k + 1
			local shape
			for _, entry in ipairs(self.cl.groups[g]) do
				if entry.id == interId then shape = entry.shape break end
			end
			e:setScale(frameScale(shape, FRAME_PADS[k]))
		end
	end
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
	local ids = {}
	for id, e in pairs(self.cl.markers[g]) do
		if sm.exists(e) then e:destroy() end
		ids[#ids + 1] = id
	end
	self.cl.markers[g] = {}
	-- the same parts in the other groups may now get a tighter frame
	for _, id in ipairs(ids) do self:cl_fitMarkers(id) end
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

	if self.cl.debug then
		-- stepping: the mouse buttons move through the ticks
		self.cl.hoverInter = nil
		self.cl.press = nil
		sm.gui.setInteractionText("", sm.gui.getKeyBinding("Create", true), "Step",
			sm.gui.getKeyBinding("Attack", true), "Back")
		if primary == sm.tool.interactState.start then
			self.cl.debug.running = false
			self:cl_debugStep(1)
		elseif secondary == sm.tool.interactState.start then
			self.cl.debug.running = false
			self:cl_debugStep(-1)
		end
		return true, true
	end

	if self.cl.logView then
		-- browsing the log: the mouse buttons move through the entries
		self.cl.hoverInter = nil
		self.cl.press = nil
		sm.gui.setInteractionText("", sm.gui.getKeyBinding("Create", true), "Older",
			sm.gui.getKeyBinding("Attack", true), "Newer")
		if primary == sm.tool.interactState.start then
			self:cl_logStep(-1)
		elseif secondary == sm.tool.interactState.start then
			self:cl_logStep(1)
		end
		return true, true
	end

	local pos, shape, inter = self:cl_raycast()
	if shape and sm.exists(shape) then self.cl.lookShape = shape end -- Lines: whose wires to show
	local logicInter = inter and isLogicCapable(inter) and inter or nil
	self.cl.hoverInter = logicInter

	if CLICK_MODES[self.cl.clickMode] == "wire" and not forceBuild then
		-- like the game's connect tool: drag from a part to a part, or click a
		-- source and then click the parts it feeds; right click drops the source
		self.cl.press = nil
		local list = self:cl_wireCandidates(shape)
		local aim = self:cl_wireAimAt(list, logicInter)
		self.cl.wireList, self.cl.wireAim = list, aim
		self.cl.hoverInter = aim
		sm.gui.setInteractionText("", sm.gui.getKeyBinding("Create", true), self:cl_wireHint(aim),
			sm.gui.getKeyBinding("Attack", true), self:cl_wireSource() and "Drop source" or "")
		if primary == sm.tool.interactState.start then
			self:cl_wirePress(aim, logicInter)
		elseif primary == sm.tool.interactState.stop then
			self:cl_wireRelease(aim)
		end
		if secondary == sm.tool.interactState.start and self:cl_wireSource() then
			self.cl.wireDrag = nil
			self:cl_setWireSource(nil)
			sm.audio.play("ConnectTool - Released")
		end
		return true, true
	end
	self.cl.wireList, self.cl.wireAim, self.cl.wireDrag = nil, nil, nil

	local g = self.cl.active
	local hint
	if logicInter then
		local idx = self:cl_indexOf(g, logicInter)
		if idx then
			hint = "Remove " .. GROUP_HEX[g] .. partName(g, idx) .. "#ffffff"
		else
			hint = "Add as " .. GROUP_HEX[g] .. partName(g, #self.cl.groups[g] + 1) .. "#ffffff"
		end
	else
		hint = "Select into " .. GROUP_HEX[g] .. g .. "#ffffff (drag = " .. BOX_NAMES[BOX_MODES[self.cl.boxMode]] .. ")"
	end
	-- "Create" is the left mouse button (the game's tools use it for their main
	-- action), "Attack" the right one
	sm.gui.setInteractionText("", sm.gui.getKeyBinding("Create", true), hint,
		sm.gui.getKeyBinding("Attack", true), "Next group")

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
	if self.cl.logView then
		self:cl_stopLogView()
		self:cl_refreshGui()
		self.cl.gui:open()
		return true
	end
	if self.cl.debug then
		self:cl_stopDebug()
		self:cl_refreshGui()
		self.cl.gui:open()
		return true
	end
	if self.cl.gui:isActive() then
		self.cl.gui:close()
	else
		self:cl_refreshGui()
		self.cl.gui:open()
	end
	return true
end

-- Q: during a box drag the next box mode (like the game's block drag), else
-- switch between Click: Select and Click: Wire
function LogicTool:client_onToggle()
	if self.cl.logView then
		self:cl_logUndoShown()
		return true
	end
	self:cl_markDirty(1)
	if self.cl.debug then
		local d = self.cl.debug
		d.running = not d.running
		d.timer = 0
		if d.running and d.view and d.view.settled then
			sm.gui.displayAlertText("Settled: nothing more happens", 1.5)
			d.running = false
		end
		sm.audio.play("ConnectTool - Rotate")
		self:cl_showDebugHud()
		return true
	end
	if self.cl.press and CLICK_MODES[self.cl.clickMode] == "select" then
		-- the button is held (a box drag): next box mode, like the game's block drag
		self:cl_setBoxMode(self.cl.boxMode % #BOX_MODES + 1)
	else
		-- otherwise: switch between selecting and wiring
		self:cl_setDropDown("clickMode", self.cl.clickMode % #CLICK_MODES + 1)
		sm.audio.play("ConnectTool - Rotate")
	end
	return true
end

function LogicTool:cl_setBoxMode(i)
	self.cl.boxMode = i
	local mode = BOX_MODES[i]
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

-- `label` is what was pressed ("All > All", "Wire click" ...), `mode` the
-- wire mode it ran in ("connect", "cut", "flip"), if it has one.
function LogicTool:cl_sendOps(ops, label, mode)
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
		self.network:sendToServer("sv_applyOps", { ops = chunk, first = first, last = i > n, label = label, mode = mode })
		first = false
	end
end

function LogicTool:cl_connectMode(mode)
	local A, B = self:cl_inters("A"), self:cl_inters("B")
	local wire = WIRE_MODES[self.cl.wireMode]
	local ops = {}
	local label = CONNECT_MODES[mode]
	if mode == "chain" or mode == "ring" or mode == "selfWire" then
		local g = self.cl.active
		local list = self:cl_inters(g)
		if mode == "selfWire" then
			if #list == 0 then sm.gui.displayAlertText("Select parts in " .. g .. " first", 2) return end
			for _, p in ipairs(list) do ops[#ops + 1] = { kind = wire, p = p, c = p } end
		else
			-- a ring of 2 would be a two-way wire, which the game does not allow
			local min = mode == "ring" and 3 or 2
			if #list < min then sm.gui.displayAlertText(label .. " needs " .. min .. "+ parts in " .. g, 2) return end
			for i = 1, #list - 1 do ops[#ops + 1] = { kind = wire, p = list[i], c = list[i + 1] } end
			if mode == "ring" then ops[#ops + 1] = { kind = wire, p = list[#list], c = list[1] } end
		end
		label = label .. " " .. g
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
	self:cl_sendOps(ops, label, wire)
end

function LogicTool:cl_onOpsDone(r)
	if r.undoneId then
		for _, e in ipairs(self.cl.log) do if e.id == r.undoneId then e.undone = true end end
	end
	if r.entry then
		r.entry.clientTick = nowTick()
		self.cl.log[#self.cl.log + 1] = r.entry
		if #self.cl.log > LOG_MAX then table.remove(self.cl.log, 1) end
	end
	if self.cl.leftWindow == "log" then self:cl_showLogList() end
	if self.cl.logView then
		-- browsing: stay on the entry just undone and show it as it is now
		local lv = self.cl.logView
		if r.entry and not r.undoneId then lv.pos = #self.cl.log end
		self:cl_logFetch()
	end
	local parts = {}
	if r.made > 0 then parts[#parts + 1] = r.made .. " connected" end
	if r.cut > 0 then parts[#parts + 1] = r.cut .. " cut" end
	if r.skipped > 0 then parts[#parts + 1] = r.skipped .. " unchanged" end
	if r.failed > 0 then parts[#parts + 1] = "#ff6060" .. r.failed .. " not allowed#ffffff" end
	local msg = (r.mode and (WIRE_VERBS[r.mode] .. " ") or "") .. (r.label or "Done") .. ": "
		.. (#parts > 0 and table.concat(parts, ", ") or "no changes")
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
	self:cl_markDirty(2)
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
-- CLIENT: saved settings and the script library (files in the mod folder,
-- like Bingo's editor; see LogicSettings.lua)
---------------------------------------------------------------------------

local SETTINGS_PATH = "$CONTENT_DATA/settings.json"
local SCRIPTS_PATH = "$CONTENT_DATA/scripts.json"
local SETTINGS_SPEC = {
	enums = {
		boxMode = BOX_MODES, pickMode = PICK_MODES, labelMode = LABEL_MODES, wireMode = WIRE_MODES,
		lutStyle = LUT_STYLES, debugInputMode = DEBUG_INPUT_MODES, bulkMode = BULK_MODES, clickMode = CLICK_MODES,
	},
	bools = { "showLines", "lutCompress", "lutEven" },
	texts = { debugSpeedText = 16, debugEveryText = 16, debugInputText = 64, bulkTimerText = 16, scriptNameText = LogicSettings.NAME_MAX, script = 100000 },
}

local function readJson(path)
	local ok, data = pcall(function()
		if sm.json.fileExists(path) then return sm.json.open(path) end
	end)
	if ok then return data end
	return nil, data
end

function LogicTool:cl_loadSaved()
	local settings, err = readJson(SETTINGS_PATH)
	if err then chat("#ffcc40TobyWand: couldn't read the saved settings, using defaults (" .. tostring(err) .. ")") end
	if settings then LogicSettings.unpack(settings, SETTINGS_SPEC, self.cl) end
	local scripts = readJson(SCRIPTS_PATH)
	self.cl.library = LogicSettings.readScripts(scripts)
	-- the script as it was left; if it is a saved one, point < > at it
	local entries = LogicSettings.entries(self.cl.library, LogicScript.examples)
	for i, e in ipairs(entries) do
		if e.code == self.cl.script then
			self.cl.libPos = i
			self.cl.libLoaded = e.code
			break
		end
	end
	if not self.cl.libPos then self.cl.libLoaded = settings and settings.script or nil end
end

-- Settings are saved a moment after the last change (typing in the script
-- would otherwise write the file on every key).
function LogicTool:cl_markDirty(seconds)
	if not self.cl.saveIn or self.cl.saveIn > seconds then self.cl.saveIn = seconds end
end

local function writeJson(data, path)
	return pcall(sm.json.save, data, path)
end

function LogicTool:cl_saveSettings()
	self.cl.saveIn = nil
	local ok, err = writeJson(LogicSettings.pack(self.cl, SETTINGS_SPEC), SETTINGS_PATH)
	if not ok and not self.cl.saveFailed then
		self.cl.saveFailed = true
		chat("#ffcc40TobyWand: couldn't save the settings (" .. tostring(err) .. ")")
	end
end

function LogicTool:cl_onScriptNameChanged(_, text)
	self.cl.scriptNameText = text
	self:cl_markDirty(2)
end

function LogicTool:cl_libEntries()
	return LogicSettings.entries(self.cl.library, LogicScript.examples)
end

-- The script was changed since it was loaded or saved.
function LogicTool:cl_scriptEdited()
	return (self.cl.script or "") ~= (self.cl.libLoaded or "") and (self.cl.script or "") ~= ""
end

-- Asks for a second press before an action that loses something.
function LogicTool:cl_confirmed(action, warning)
	if self.cl.confirm == action then
		self.cl.confirm = nil
		return true
	end
	self.cl.confirm = action
	self:cl_setResult("#ffcc40" .. warning .. "#ffffff")
	sm.gui.displayAlertText(warning, 2.5)
	return false
end

function LogicTool:cl_libStep(dir, action)
	local entries = self:cl_libEntries()
	if #entries == 0 then return end
	if self:cl_scriptEdited() and not self:cl_confirmed(action, "Unsaved changes in the script: press again to load another anyway") then
		return
	end
	local pos = self.cl.libPos
	if not pos then
		pos = dir > 0 and 1 or #entries
	else
		pos = (pos - 1 + dir) % #entries + 1
	end
	local e = entries[pos]
	self.cl.libPos = pos
	self.cl.script = e.code
	self.cl.libLoaded = e.code
	self.cl.scriptNameText = e.name
	self.cl.gui:setText("scriptName", e.name)
	self:cl_showScript()
	self:cl_setResult(string.format("Script %d/%d: %s%s", pos, #entries, e.name,
		e.example and "  (example: Save keeps your own copy)" or ""))
end

function LogicTool:cl_saveScripts()
	local ok, err = writeJson(LogicSettings.packScripts(self.cl.library), SCRIPTS_PATH)
	if not ok then
		self:cl_setResult("#ff6060Couldn't save the script library: " .. tostring(err) .. "#ffffff")
	end
	return ok
end

function LogicTool:cl_libSave()
	local code = self.cl.script or ""
	local name, replaced = LogicSettings.saveScript(self.cl.library, self.cl.scriptNameText, code)
	if not name then
		self:cl_setResult("#ff6060" .. replaced .. "#ffffff")
		sm.gui.displayAlertText(replaced, 2)
		return
	end
	if not self:cl_saveScripts() then return end
	self.cl.libLoaded = code
	self.cl.libPos = LogicSettings.indexOf(self.cl.library, name)
	self.cl.scriptNameText = name
	self.cl.gui:setText("scriptName", name)
	self:cl_setResult((replaced and "Saved over " or "Saved as ") .. name)
	sm.gui.displayAlertText((replaced and "Saved over " or "Saved as ") .. name, 1.5)
end

function LogicTool:cl_libDelete()
	local name = self.cl.scriptNameText or ""
	if not LogicSettings.indexOf(self.cl.library, (name:gsub("^%s+", ""):gsub("%s+$", ""))) then
		self:cl_setResult("No saved script is called that (examples can't be deleted).")
		return
	end
	if not self:cl_confirmed("libDelete", "Press Delete again to delete " .. name) then return end
	LogicSettings.deleteScript(self.cl.library, name)
	if self:cl_saveScripts() then
		-- the script stays in the editor, now unsaved
		self.cl.libPos = nil
		self.cl.libLoaded = nil
		self:cl_setResult("Deleted " .. name .. ". It is still in the editor until you load another.")
	end
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
	if r.kind == "module" then
		self:cl_onModule(r)
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
		add("TRUTH TABLE  (A inputs  |  B outputs, A0 and B0 on the right)")
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
-- CLIENT: module window
---------------------------------------------------------------------------

local MODULE_COLORS = { A = GROUP_HEX.A:sub(2), B = GROUP_HEX.B:sub(2), one = "ffffff", zero = "707070", text = "ffffff" }

local function listText(prefix, types)
	local out = {}
	for k, t in ipairs(types or {}) do out[k] = partName(prefix, k) .. " " .. t end
	return table.concat(out, ",  ")
end

-- The module as it is now: the loaded one, with the edited rows if any.
function LogicTool:cl_currentModule()
	local m = self.cl.module
	if m and self.cl.moduleRows then return LogicModule.withRows(m, self.cl.moduleRows) end
	return m
end

function LogicTool:cl_showModuleTable()
	local m = self.cl.module
	local text = m and LogicModule.tableText(self:cl_currentModule(), { colors = MODULE_COLORS }) or ""
	self.cl.moduleTableText = text
	if self.cl.gui then self.cl.gui:setText("moduleTable", text) end
end

-- The info box: what was loaded, warnings, whether the edited table reads
-- fine, and what a LUT build would make.
function LogicTool:cl_showModuleInfo(errorText)
	local gui = self.cl.gui
	if not gui then return end
	local m = self.cl.module
	if errorText or not m then
		gui:setText("moduleInfo", (errorText and ("#ff6060" .. errorText .. "#ffffff\n\n") or "") .. MODULE_HINT)
		return
	end
	local cur = self:cl_currentModule()
	local lines = {}
	local function add(s) lines[#lines + 1] = s end
	add(string.format("%sInputs (A): %d#ffffff   %s", GROUP_HEX.A, #m.inputs, listText("A", m.inputTypes)))
	add(string.format("%sOutputs (B): %d#ffffff   %s", GROUP_HEX.B, #m.outputs, listText("B", m.outputTypes)))
	add(string.format("Inside now: %d part(s)", m.inside or 0))
	if (m.extraIn or 0) > 0 then
		add(string.format("#ffcc40! %d part(s) outside A also feed it (marked red). The table counts them as off.#ffffff", m.extraIn))
	end
	if (m.extraOut or 0) > 0 then
		add(string.format("#ffcc40! %d part(s) inside also drive things outside B.#ffffff", m.extraOut))
	end
	local _, unsettled = LogicModule.tableText(m)
	if unsettled > 0 and not self.cl.moduleRows then
		add(string.format("#ffcc40! %d row(s) never settle: a clock or memory loop inside.#ffffff", unsettled))
	end
	add("")
	if self.cl.moduleError then
		add("#ff6060Table: " .. self.cl.moduleError .. "#ffffff")
		add("Fix it to see the LUT again.")
	else
		add(self.cl.moduleRows and "#80ff80Table: edited#ffffff (Reset table goes back to the loaded one)" or "Table: as loaded")
		local plan = LogicModule.lutPlan(cur, { style = LUT_STYLES[self.cl.lutStyle], even = self.cl.lutEven,
			compress = self.cl.lutCompress, bIsGate = m.outputGates })
		add("As a LUT: " .. LogicModule.planText(plan, self.cl.lutCompress))
		for _, problem in ipairs(plan.problems) do add("#ff6060Can't build: " .. problem .. "#ffffff") end
		add("Build LUT shows a preview first. Nothing changes until Apply build; Undo build puts it back.")
	end
	add("")
	add(string.format("Rows are binary numbers: A%d..A0 | B%d..B0, so A0 and B0 are the rightmost digits. Edit the output digits.", #m.inputs - 1, #m.outputs - 1))
	self.cl.moduleInfoText = table.concat(lines, "\n")
	gui:setText("moduleInfo", self.cl.moduleInfoText)
end

function LogicTool:cl_onModuleTableChanged(_, text)
	local m = self.cl.module
	if not m then return end
	local rows, line, msg = LogicModule.parseTable(m, text)
	-- a preview is for the table it was made from
	if self.cl.lutPreview and text ~= self.cl.moduleTableText then self:cl_clearLutPreview() end
	if rows then
		-- same as loaded (also when the game reports our own setText) = not edited
		self.cl.moduleRows = not LogicModule.sameRows(m.rows, rows) and rows or nil
		self.cl.moduleError = nil
	else
		self.cl.moduleError = "line " .. line .. ": " .. msg
	end
	self.cl.moduleTableText = text
	self:cl_showModuleInfo()
end

-- After a build the new creation is reloaded and compared with the table it
-- was built from. The game may need a moment before the new wires read back,
-- so it waits, and tries again a few times if the result doesn't match.
local VERIFY_WAITS = { 0.5, 1, 2 }

function LogicTool:cl_updateVerify(dt)
	local v = self.cl.verify
	if not (v and v.wait) then return end
	v.wait = v.wait - dt
	if v.wait <= 0 then
		v.wait = nil
		v.tries = v.tries + 1
		self:cl_requestAnalysis("module")
	end
end

-- Handles a reload while verifying. Returns true when it took care of the reply.
function LogicTool:cl_verifyReply(r)
	local v = self.cl.verify
	if not v then return false end
	local ok = not r.error and r.module and LogicModule.sameRows(v.rows, r.module.rows)
	if ok then
		self.cl.verify = nil
		return false -- show it like any load, then say it matched (cl_onModule)
	end
	if v.tries < #VERIFY_WAITS then
		v.wait = VERIFY_WAITS[v.tries + 1]
		return true -- quietly try again
	end
	-- still different: keep the player's table on the new module, so the next
	-- Build builds what they wanted, never the (wrong) reloaded rows
	self.cl.verify = nil
	if r.module then
		self.cl.module = r.module
		self.cl.moduleRows = not LogicModule.sameRows(r.module.rows, v.rows) and v.rows or nil
		self.cl.moduleError = nil
		self:cl_showModuleTable()
	end
	self:cl_showModuleInfo()
	self:cl_message("#ffcc40Built, but reloading it gives a different table" .. (r.error and (" (" .. r.error .. ")") or "")
		.. ". Your table is kept. Check the creation, or press Undo build.")
	self:cl_refreshGui()
	return true
end

function LogicTool:cl_onModule(r)
	self.cl.leftWindow = "module"
	local verifying = self.cl.verify ~= nil
	if self:cl_verifyReply(r) then return end
	if r.error then
		sm.gui.displayAlertText(r.error, 2.5)
		self:cl_showModuleInfo(r.error)
		self:cl_refreshGui()
		return
	end
	local m = r.module
	self.cl.module = m
	self.cl.moduleRows, self.cl.moduleError = nil, nil
	self:cl_clearMarks()
	for _, inter in ipairs(r.leaks or {}) do self:cl_flag(inter, COLOR_WARN) end
	self:cl_showModuleTable()
	self:cl_showModuleInfo()
	self:cl_setResult(string.format("Loaded module: %d in, %d out, %d part(s) inside.", #m.inputs, #m.outputs, m.inside or 0))
	if verifying then
		self:cl_message("#80ff80Built. Reloaded it: the new logic matches your table.")
	end
	self:cl_refreshGui()
end

---------------------------------------------------------------------------
-- CLIENT: build a module as a LUT
---------------------------------------------------------------------------

local PREVIEW_COLORS = { new = sm.color.new("40ff60ff"), A = sm.color.new("ff9900ff"), B = sm.color.new("00c8ffff") }

-- First press: preview. Second press (while the preview shows): apply.
function LogicTool:cl_buildLut()
	local m = self.cl.module
	if not m then
		sm.gui.displayAlertText("Load A > B first", 2)
		return
	end
	if self.cl.moduleError then
		sm.gui.displayAlertText("Fix the table first: " .. self.cl.moduleError, 2.5)
		return
	end
	local rows = {}
	for i, row in ipairs(self:cl_currentModule().rows) do rows[i] = row.outs end
	local apply = self.cl.lutPreview ~= nil
	if apply then
		self.cl.verifyRows = self:cl_currentModule().rows
		self:cl_clearLutPreview()
	end
	self.network:sendToServer("sv_lutBuild", {
		A = self:cl_inters("A"), B = self:cl_inters("B"), rows = rows, style = LUT_STYLES[self.cl.lutStyle],
		even = self.cl.lutEven, compress = self.cl.lutCompress, apply = apply, lift = self:cl_liftInfo(),
	})
end

-- Where the player's lift is (only the client can ask), so a rebuilt
-- creation can go back on it.
function LogicTool:cl_liftInfo()
	local ok, lift = pcall(sm.localPlayer.getOwnedLift)
	if not (ok and lift and sm.exists(lift)) then return nil end
	local okp, pos = pcall(function() return lift.worldPosition end)
	local okl, level = pcall(function() return lift.level end)
	if okp and okl and pos and level then return { pos = pos, level = level } end
end

function LogicTool:cl_clearLutPreview(quiet)
	local p = self.cl.lutPreview
	if not p then return end
	for _, e in ipairs(p.effects) do
		if sm.exists(e) then e:destroy() end
	end
	self.cl.lutPreview = nil
	self:cl_clearMarks()
	if self.cl.gui and not quiet then self:cl_refreshGui() end
end

function LogicTool:cl_onLutPreview(r)
	self:cl_clearLutPreview()
	local p = { effects = {} }
	local size = sm.vec3.new(0.25, 0.25, 0.25) + sm.vec3.new(FLAG_PAD, FLAG_PAD, FLAG_PAD) * 2
	for _, c in ipairs(r.cells or {}) do
		local e = sm.effect.createEffect("ShapeRenderable")
		e:setParameter("uuid", FRAME_UUID)
		e:setParameter("color", PREVIEW_COLORS[c.kind] or PREVIEW_COLORS.new)
		e:setPosition(c.pos)
		e:setRotation(r.rot)
		e:setScale(size)
		e:start()
		p.effects[#p.effects + 1] = e
	end
	self.cl.lutPreview = p
	for _, inter in ipairs(r.remove or {}) do self:cl_flag(inter, COLOR_WARN) end
	for _, inter in ipairs(r.keep or {}) do self:cl_flag(inter, COLOR_GLITCH) end

	self:cl_showModuleInfo()
	local lines = {
		"",
		"#80ff80BUILD PREVIEW#ffffff (green = new gates, orange/blue = where A/B go, red = removed, yellow = kept)",
		string.format("%d new gate(s), %d old part(s) removed. The module goes on top of the creation.",
			r.gates or 0, #(r.remove or {})),
	}
	if r.keepReason then
		lines[#lines + 1] = string.format("#ffee00The old circuit (%d part(s)) stays whole: %s.#ffffff Its wires into B are cut.",
			#(r.keep or {}), r.keepReason)
	end
	if (r.helpers or 0) > 0 then
		lines[#lines + 1] = string.format("%d gate(s) that only feed A move along with A.", r.helpers)
	end
	lines[#lines + 1] = "Press Apply build to rebuild the creation, or Cancel."
	if (r.gates or 0) == 0 then
		lines[#lines + 1] = "#ff6060The table is all 0: this build only removes the old logic and builds nothing.#ffffff"
	end
	if r.lifted then
		lines[#lines + 1] = self:cl_liftInfo() and "It's on your lift: it goes back on the lift after the build."
			or "#ffcc40It's on a lift that isn't yours: after the build it stands free in the same spot.#ffffff"
	end
	self.cl.gui:setText("moduleInfo", (self.cl.moduleInfoText or "") .. table.concat(lines, "\n"))
	sm.gui.displayAlertText((r.gates or 0) == 0 and "#ff6060Table is all 0: Apply would only remove logic"
		or "Preview shown: Apply build to rebuild, or Cancel", 3)
	self:cl_refreshGui()
end

-- Every group as a list of interactables, for a rebuild to carry over.
function LogicTool:cl_allGroups()
	local out = {}
	for _, g in ipairs(GROUPS) do out[g] = self:cl_inters(g) end
	return out
end

-- Replaces the groups named in `groups` (after a rebuild made new parts).
function LogicTool:cl_setGroups(groups)
	for _, g in ipairs(GROUPS) do
		if groups[g] then
			self:cl_clearGroup(g)
			for _, inter in ipairs(groups[g]) do
				if sm.exists(inter) then self:cl_add(g, inter, inter:getShape()) end
			end
		end
	end
end

-- Set gates / Set timers: the active group's gates get the chosen mode, or
-- its timers the typed setting (server: sv_bulkEdit).
function LogicTool:cl_bulkEdit(kind)
	local g = self.cl.active
	local inters = self:cl_inters(g)
	if #inters == 0 then sm.gui.displayAlertText("Select the parts to edit in " .. g .. " first", 2) return end
	if self.cl.debug then sm.gui.displayAlertText("Stop the debugger first", 2) return end
	if self.cl.lutPreview then sm.gui.displayAlertText("Cancel or apply the LUT build first", 2) return end
	if self.cl.bulkBusy then return end
	local data = { inters = inters, groups = self:cl_allGroups(), lift = self:cl_liftInfo() }
	if kind == "gate" then
		data.mode = self.cl.bulkMode - 1
		data.label = BULK_MODES[self.cl.bulkMode]
	else
		local seconds, ticks = LogicGraph.parseTimer(self.cl.bulkTimerText)
		if not seconds then
			sm.gui.displayAlertText("#ff6060" .. ticks, 3)
			self:cl_setResult(ticks)
			return
		end
		data.seconds, data.ticks = seconds, ticks
		data.label = string.format("%ds %dt", seconds, ticks)
	end
	self.cl.bulkBusy = data.label
	self:cl_setResult("Editing " .. #inters .. " part(s) in " .. g .. " ...")
	self.network:sendToServer("sv_bulkEdit", data)
end

function LogicTool:cl_onBulkEdit(r)
	local label = self.cl.bulkBusy or ""
	self.cl.bulkBusy = false
	if r.error then
		self:cl_message("#ff6060" .. r.error)
		return
	end
	if r.groups then self:cl_setGroups(r.groups) end
	local what = r.kind == "gate" and "gate(s)" or "timer(s)"
	local lines = {}
	if r.changed > 0 then
		lines[#lines + 1] = string.format("Set %d %s to %s. Undo puts them back.", r.changed, what, label)
	else
		lines[#lines + 1] = string.format("No %s to change.", what)
	end
	if r.same > 0 then lines[#lines + 1] = string.format("%d already %s.", r.same, label) end
	if r.other > 0 then
		lines[#lines + 1] = string.format("%d other part(s) skipped (not a %s).", r.other, r.kind)
	end
	if r.elsewhere > 0 then
		lines[#lines + 1] = string.format("%d part(s) on another creation skipped: edit one creation at a time.", r.elsewhere)
	end
	if r.missing > 0 then lines[#lines + 1] = string.format("%d part(s) not found in the blueprint.", r.missing) end
	sm.gui.displayAlertText(lines[1], 3)
	sm.audio.play(r.changed > 0 and "ConnectTool" or "ConnectTool - Released")
	self:cl_setResult(table.concat(lines, "\n"))
	if r.lifted and not r.relifted then
		chat("The creation was on a lift; it now stands free. Put it back on the lift if you need to.")
	end
	-- type labels and the wire graph show the old settings until reloaded
	self.cl.typeLabels, self.cl.partInfo = {}, {}
	self:cl_refreshGui()
end

function LogicTool:cl_onLutBuilt(r)
	self:cl_clearLutPreview()
	if r.error then
		self.cl.verifyRows = nil
		self:cl_message("#ff6060" .. r.error)
		self:cl_showModuleInfo()
		return
	end
	if r.undone then
		self.cl.verifyRows = nil
		self.cl.verify = nil
		if r.groups then self:cl_setGroups(r.groups) end
		if r.kind == "edit" then
			self:cl_message("Edit undone: the parts are back as they were.")
		else
			self:cl_message("Build undone: the creation is back as it was before the build.")
		end
		if r.lifted and not r.relifted then
			chat("The creation was on a lift; it now stands free. Put it back on the lift if you need to.")
		end
		self:cl_refreshGui()
		return
	end
	if r.A and r.B then
		self:cl_setGroups({ A = r.A, B = r.B })
		self:cl_setResult(string.format("Built: %d new gate(s), %d old part(s) removed. Checking...", r.gates or 0, r.removed or 0))
		-- reload the new module a moment later and compare (cl_updateVerify)
		self.cl.verify = { rows = self.cl.verifyRows, wait = VERIFY_WAITS[1], tries = 0 }
		self.cl.verifyRows = nil
	else
		self.cl.verifyRows = nil
		self:cl_message("Built. Select A and B again to load the new module (couldn't find them after the rebuild).")
	end
	if r.lifted and not r.relifted then
		chat("The creation was on a lift; it now stands free. Put it back on the lift if you need to.")
	end
	self:cl_refreshGui()
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
	local parts = {}
	for _, name in ipairs(GROUPS) do
		parts[#parts + 1] = GROUP_HEX[name] .. name .. " #ffffff" .. #self.cl.groups[name]
	end
	gui:setText("groupInfo", table.concat(parts, "   "))
	-- group letter last and coloured, like "Active: A", so no colour reset is needed
	gui:setText("chain", "Chain: " .. GROUP_HEX[g] .. g)
	gui:setText("ring", "Ring: " .. GROUP_HEX[g] .. g)
	gui:setText("selfWire", "Self: " .. GROUP_HEX[g] .. g)
	gui:setText("setGates", "Set gates: " .. GROUP_HEX[g] .. g)
	gui:setText("setTimers", "Set timers: " .. GROUP_HEX[g] .. g)
	gui:setText("clearIn", "Clear inputs: " .. GROUP_HEX[g] .. g)
	gui:setText("clearOut", "Clear outputs: " .. GROUP_HEX[g] .. g)
	local left = self.cl.leftWindow
	-- the window buttons (blue) show their caption in a text box on top
	gui:setText("openScriptText", left == "script" and "Hide script" or "< Script")
	gui:setText("openSettingsText", left == "settings" and "Hide settings" or "< Settings")
	gui:setText("openModuleText", left == "module" and "Hide module" or "< Module")
	gui:setText("openDebugText", left == "debug" and "Hide debug" or "< Debug")
	gui:setText("openLogText", left == "log" and "Hide log" or "< Log")
	gui:setVisible("logWindow", left == "log")
	if left == "log" then self:cl_showLogList() end
	self:cl_syncDropDowns(gui)
	gui:setText("buildLut", self.cl.lutPreview and "Apply build" or "Build LUT")
	gui:setVisible("scriptWindow", left == "script")
	gui:setVisible("settingsWindow", left == "settings")
	gui:setVisible("moduleWindow", left == "module")
	gui:setVisible("debugWindow", left == "debug")
end

-- Dropdowns (the game's own, see GuiInterface:createDropDown). Each has its
-- options, which one is chosen now, and what choosing one does. The game
-- calls back with the chosen text only, so every dropdown gets its own
-- callback, cl_dd_<name>.
local function names(list, map, prefix)
	local out = {}
	for i, v in ipairs(list) do out[i] = (prefix or "") .. (map and map[v] or v) end
	return out
end
local function refreshModule(self)
	self:cl_clearLutPreview()
	self:cl_showModuleInfo()
end
local DROPDOWNS = {
	{ name = "active", options = names(GROUPS, nil, "Active: "),
		get = function(self) for i, g in ipairs(GROUPS) do if g == self.cl.active then return i end end return 1 end,
		set = function(self, i) self.cl.active = GROUPS[i] end },
	{ name = "clickMode", options = names(CLICK_MODES, CLICK_NAMES),
		get = function(self) return self.cl.clickMode end,
		set = function(self, i)
			self.cl.clickMode = i
			self.cl.press = nil
			self.cl.wireDrag = nil
			if CLICK_MODES[i] ~= "wire" then self:cl_setWireSource(nil) end
			sm.gui.displayAlertText(CLICK_MODES[i] == "wire" and "Click: Wire. Drag from a dot to a dot (Q: back to select)"
				or "Click: Select. Clicks add parts to the active group (Q: wire)", 2)
		end },
	{ name = "wireMode", options = names(WIRE_MODES, WIRE_NAMES),
		get = function(self) return self.cl.wireMode end,
		set = function(self, i)
			self.cl.wireMode = i
			local wire = WIRE_MODES[i]
			sm.gui.displayAlertText(wire == "connect" and "Buttons add wires"
				or wire == "cut" and "Buttons remove wires" or "Buttons toggle wires", 1.5)
		end },
	{ name = "bulkMode", options = names(BULK_MODES, nil, "Gate: "),
		get = function(self) return self.cl.bulkMode end,
		set = function(self, i) self.cl.bulkMode = i end },
	{ name = "boxMode", options = names(BOX_MODES, BOX_SHORT),
		get = function(self) return self.cl.boxMode end,
		set = function(self, i) self:cl_setBoxMode(i) end },
	{ name = "pickBy", options = names(PICK_MODES, PICK_NAMES),
		get = function(self) return self.cl.pickMode end,
		set = function(self, i)
			self.cl.pickMode = i
			self:cl_setResult("F + click now picks every logic part in the creation with the " .. PICK_ALERT[PICK_MODES[i]] .. " as the one you click.")
		end },
	{ name = "lines", options = { "Off", "On" },
		get = function(self) return self.cl.showLines and 2 or 1 end,
		set = function(self, i) self.cl.showLines = i == 2 end },
	{ name = "labels", options = names(LABEL_MODES, LABEL_NAMES),
		get = function(self) return self.cl.labelMode end,
		set = function(self, i)
			self.cl.labelMode = i
			if LABEL_MODES[i] == "type" then self:cl_requestAnalysis("info") end
		end },
	{ name = "debugHold", options = names(DEBUG_INPUT_MODES, DEBUG_INPUT_NAMES),
		get = function(self) return self.cl.debugInputMode end,
		set = function(self, i) self.cl.debugInputMode = i end },
	{ name = "lutStyle", options = names(LUT_STYLES, LUT_STYLE_NAMES),
		get = function(self) return self.cl.lutStyle end,
		set = function(self, i) self.cl.lutStyle = i refreshModule(self) end },
	{ name = "lutCompress", options = { "Spread out", "Stacked" },
		get = function(self) return self.cl.lutCompress and 2 or 1 end,
		set = function(self, i) self.cl.lutCompress = i == 2 refreshModule(self) end },
	{ name = "lutEven", options = { "Even timing", "Fewer gates" },
		get = function(self) return self.cl.lutEven and 1 or 2 end,
		set = function(self, i) self.cl.lutEven = i == 1 refreshModule(self) end },
}
local DROPDOWN_BY_NAME = {}
for _, dd in ipairs(DROPDOWNS) do
	DROPDOWN_BY_NAME[dd.name] = dd
	LogicTool["cl_dd_" .. dd.name] = function(self, value) self:cl_onDropDown(dd.name, value) end
end

function LogicTool:cl_createDropDowns(gui)
	self.cl.ddShown = {}
	for _, dd in ipairs(DROPDOWNS) do gui:createDropDown(dd.name, "cl_dd_" .. dd.name, dd.options) end
end

-- Shows the current choice in every dropdown (hotkeys change some of them).
function LogicTool:cl_syncDropDowns(gui)
	local shown = self.cl.ddShown or {}
	self.cl.ddShown = shown
	for _, dd in ipairs(DROPDOWNS) do
		local want = dd.options[dd.get(self)]
		if want and shown[dd.name] ~= want then
			shown[dd.name] = want
			gui:setSelectedDropDownItem(dd.name, want)
		end
	end
end

-- `value` is an option's text, or a number: pick that option.
function LogicTool:cl_setDropDown(name, value)
	local dd = DROPDOWN_BY_NAME[name]
	local i = type(value) == "number" and value or nil
	if not i then
		for k, text in ipairs(dd.options) do if text == value then i = k end end
	end
	if not i or i == dd.get(self) then return end
	if self.cl.confirm then self.cl.confirm = nil end
	dd.set(self, i)
	self:cl_markDirty(1)
	self:cl_refreshGui()
end

function LogicTool:cl_onDropDown(name, value)
	self.cl.ddShown[name] = value
	self:cl_setDropDown(name, value)
end

function LogicTool:cl_onButton(name)
	if self.cl.confirm and self.cl.confirm ~= name then self.cl.confirm = nil end
	self:cl_markDirty(1)
	if DROPDOWN_BY_NAME[name] then
		-- not buttons any more; a press steps to the next option
		local dd = DROPDOWN_BY_NAME[name]
		self:cl_setDropDown(name, dd.get(self) % #dd.options + 1)
		return
	end
	if name == "close" then
		self.cl.gui:close()
	elseif name == "clearActive" then
		self:cl_clearGroup(self.cl.active)
	elseif name == "clearAll" then
		for _, g in ipairs(GROUPS) do self:cl_clearGroup(g) end
		self:cl_clearMarks()
	elseif name == "undo" then
		self.network:sendToServer("sv_undo", { lift = self:cl_liftInfo(), groups = self:cl_allGroups() })
	elseif name == "setGates" then
		self:cl_bulkEdit("gate")
	elseif name == "setTimers" then
		self:cl_bulkEdit("timer")
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
	elseif name == "clearMarks" then
		self:cl_clearMarks()
		self:cl_setResult("")
	elseif name == "libPrev" or name == "libNext" then
		self:cl_libStep(name == "libNext" and 1 or -1, name)
	elseif name == "libSave" then
		self:cl_libSave()
	elseif name == "libDelete" then
		self:cl_libDelete()
	elseif name == "run" then
		self:cl_runScript()
	elseif name == "format" then
		self:cl_formatScript()
	elseif LEFT_WINDOWS[name] then
		-- one window on the left at a time; the same button again hides it
		local w = LEFT_WINDOWS[name]
		self.cl.leftWindow = self.cl.leftWindow ~= w and w or nil
	elseif name == "logView" then
		self:cl_startLogView()
	elseif name == "logClear" then
		if self:cl_confirmed("logClear", "Press Clear log again to forget every entry") then
			self.cl.log = {}
			self.network:sendToServer("sv_logClear")
			self:cl_showLogList()
		end
	elseif name == "closeScript" or name == "closeSettings" or name == "closeModule" or name == "closeDebug" or name == "closeLog" then
		self.cl.leftWindow = nil
	elseif name == "buildLut" then
		self:cl_buildLut()
	elseif name == "cancelLut" then
		if self.cl.lutPreview then
			self:cl_clearLutPreview()
			self:cl_showModuleInfo()
			sm.gui.displayAlertText("Build cancelled", 1.5)
		end
	elseif name == "undoLut" then
		self:cl_clearLutPreview()
		self.network:sendToServer("sv_lutUndo", { lift = self:cl_liftInfo(), groups = self:cl_allGroups() })
	elseif name == "loadModule" then
		self.cl.verify = nil
		self:cl_clearLutPreview()
		self.cl.gui:setText("moduleInfo", "Loading A > B ...")
		self:cl_requestAnalysis("module")
	elseif name == "resetModule" then
		if self.cl.module then
			self.cl.moduleRows, self.cl.moduleError = nil, nil
			self:cl_showModuleTable()
			self:cl_showModuleInfo()
		end
	elseif name == "probeFwd" or name == "probeBack" then
		self:cl_startProbe(self:cl_inters("A"), name == "probeBack", nil)
	elseif name == "help" then
		self:cl_setResult(HELP_TEXT)
	elseif name == "debugFromGame" then
		local digits = {}
		local A = self.cl.groups.A
		for k = #A, 1, -1 do
			digits[#digits + 1] = sm.exists(A[k].inter) and A[k].inter:isActive() and "1" or "0"
		end
		self.cl.debugInputText = table.concat(digits)
		self.cl.gui:setText("debugInputs", self.cl.debugInputText)
	elseif name == "debugStart" then
		self:cl_startDebug()
	end
	self:cl_refreshGui()
end

---------------------------------------------------------------------------
-- CLIENT: step debugger
---------------------------------------------------------------------------

-- "0101" -> { A0 = true, A1 = false, ... } as a list. A0 is the rightmost
-- digit; missing digits on the left are 0.
local function parseDebugInputs(text, n)
	local digits = text:gsub("[%s_]", "")
	if digits:find("[^01]") then return nil, "Inputs: use only 0 and 1" end
	if #digits > n then return nil, string.format("Inputs: %d digits, but A has %d part(s)", #digits, n) end
	digits = string.rep("0", n - #digits) .. digits
	local values = {}
	for k = 1, n do values[k] = digits:sub(n - k + 1, n - k + 1) == "1" end
	return values
end

function LogicTool:cl_onDebugInputsChanged(_, text)
	self.cl.debugInputText = text
	self:cl_markDirty(2)
end

function LogicTool:cl_onBulkTimerChanged(_, text)
	self.cl.bulkTimerText = text
	self:cl_markDirty(2)
end

function LogicTool:cl_onDebugSpeedChanged(_, text)
	self.cl.debugSpeedText = text
	self:cl_markDirty(2)
end

function LogicTool:cl_onDebugEveryChanged(_, text)
	self.cl.debugEveryText = text
	self:cl_markDirty(2)
end

function LogicTool:cl_setDebugInfo(text)
	if self.cl.gui then self.cl.gui:setText("debugInfo", text) end
end

function LogicTool:cl_startDebug()
	self:cl_stopLogView()
	local A, B = self:cl_inters("A"), self:cl_inters("B")
	local err
	if #A == 0 or #B == 0 then
		err = "Debug needs the inputs in A and the outputs in B"
	end
	local inputs
	if not err then inputs, err = parseDebugInputs(self.cl.debugInputText or "", #A) end
	if not err and not parseSpeed(self.cl.debugSpeedText) then
		err = string.format("Run speed: type the seconds per tick, from %g to %g (like 0.5)", DEBUG_SPEED_MIN, DEBUG_SPEED_MAX)
	end
	local mode = DEBUG_INPUT_MODES[self.cl.debugInputMode]
	local every = tonumber(((self.cl.debugEveryText or ""):gsub("%s", "")))
	if not err and mode == "repeat" and not (every and every >= 1 and every <= DEBUG_EVERY_MAX and every == math.floor(every)) then
		err = "Pulse every: type a whole number of ticks (1 or more)"
	end
	if err then
		self:cl_setDebugInfo("#ff6060" .. err .. "#ffffff\n\n" .. DEBUG_HINT)
		sm.gui.displayAlertText(err, 2.5)
		return
	end
	if self.cl.debug then self:cl_stopDebug() end
	self:cl_setDebugInfo("Starting ...")
	self.network:sendToServer("sv_debugStart", { A = A, B = B, inputs = inputs, mode = mode, every = every })
end

function LogicTool:cl_debugStep(dir)
	local d = self.cl.debug
	if not d or d.pending then return end
	d.pending = true
	self.network:sendToServer("sv_debugStep", { dir = dir })
end

function LogicTool:cl_clearDebugFrames()
	for _, e in ipairs(self.cl.debugFrames) do
		if sm.exists(e) then e:destroy() end
	end
	self.cl.debugFrames = {}
end

function LogicTool:cl_stopDebug()
	if not self.cl.debug then return end
	self.network:sendToServer("sv_debugStop")
	local view = self.cl.debug.view
	self.cl.debug = nil
	self:cl_clearDebugFrames()
	if self.cl.stepGui and self.cl.stepGui:isActive() then self.cl.stepGui:close() end
	if view then
		self:cl_setDebugInfo(string.format("Stopped at tick %d: B = %s%s#ffffff\n\n", view.tick, GROUP_HEX.B, view.outputs)
			.. DEBUG_HINT)
	end
end

function LogicTool:cl_onDebug(r)
	if r.error then
		sm.gui.displayAlertText(r.error, 2.5)
		self:cl_setDebugInfo("#ff6060" .. r.error .. "#ffffff\n\n" .. DEBUG_HINT)
		if r.stop then self:cl_stopDebug() end
		if self.cl.debug then self.cl.debug.pending = false end
		return
	end
	if r.start then
		self.cl.debug = { running = false, timer = 0, pending = false }
		if self.cl.gui:isActive() then self.cl.gui:close() end
		local extra = r.simulated - r.size
		self:cl_setDebugInfo(string.format("Showing %d part(s): A, B and %d between them.", r.size, r.between)
			.. (extra > 0 and string.format(" %d more part(s) feed them and run along unseen.", extra) or "")
			.. ((r.unknown or 0) > 0 and string.format("\n#ff6060%d gate(s) have an unknown mode and stay off in the copy.#ffffff", r.unknown) or "")
			.. "\n\n" .. DEBUG_HINT)
		if (r.unknown or 0) > 0 then
			sm.gui.displayAlertText(string.format("#ff6060%d gate(s) with unknown mode: they stay off", r.unknown), 4)
		end
		sm.gui.displayAlertText("Debug: left click = step, right click = back, Q = run, R = stop", 4)
	end
	local d = self.cl.debug
	if not d then return end
	d.pending = false
	d.view = r
	self.cl.labelTimer = 0 -- new countdown labels on the next frame
	if r.edge == "start" then
		sm.gui.displayAlertText("Already at tick 0", 1)
	elseif r.edge == "limit" then
		sm.gui.displayAlertText("Tick limit reached", 1.5)
		d.running = false
	end
	if r.settled and d.running then
		d.running = false
		sm.gui.displayAlertText("Settled", 1.5)
	end

	-- frames on the parts that changed this tick
	self:cl_clearDebugFrames()
	local show = self.tool:isEquipped()
	for _, c in ipairs(r.changed) do
		if #self.cl.debugFrames >= DEBUG_MAX_FRAMES then break end
		local inter = c.inter
		if sm.exists(inter) then
			local e = sm.effect.createEffect("ShapeRenderable", inter)
			e:setParameter("uuid", FRAME_UUID)
			e:setParameter("color", c.on and COLOR_RISE or COLOR_FALL)
			e:setScale(frameScale(inter:getShape(), FLAG_PAD))
			if show then e:start() end
			self.cl.debugFrames[#self.cl.debugFrames + 1] = e
		end
	end
	self:cl_showDebugHud()
end

function LogicTool:cl_showDebugHud()
	local gui, d = self.cl.stepGui, self.cl.debug
	if not (gui and d and d.view) then return end
	local v = d.view
	local state = d.running and ("#40ff60running#ffffff, " .. speedText(parseSpeed(self.cl.debugSpeedText) or 1)) or "paused"
	gui:setText("stepTick", string.format("Tick %d   #a0a0a0%s", v.tick, state))
	gui:setText("stepOutputs", string.format("%sA#ffffff %s     %sB#ffffff %s", GROUP_HEX.A, v.inputs, GROUP_HEX.B, v.outputs))
	local info
	if v.settled then
		if not v.lastChange then
			info = "#ffcc40Nothing changes: A already has these values in the game#ffffff"
		else
			info = string.format("#80ff80Settled#ffffff: last change on tick %d", v.lastChange)
		end
	elseif v.changedCount == 0 and v.otherCount > 0 then
		info = string.format("Nothing changed here (%d part(s) feeding it did)", v.otherCount)
	elseif v.changedCount == 0 then
		info = v.soonest and string.format("Nothing changed: next change in %dt", v.soonest)
			or "Nothing changed (a timer is still counting)"
	else
		info = string.format("%d part(s) changed", v.changedCount)
	end
	if #v.glitches > 0 then
		local names = {}
		for _, gl in ipairs(v.glitches) do names[#names + 1] = string.format("B%d (%dx)", gl.k - 1, gl.n) end
		info = info .. "   #ffee00Glitch: " .. table.concat(names, ", ") .. "#ffffff"
	end
	gui:setText("stepInfo", info)
	gui:setText("stepKeys", "Left click step   Right click back   Q run/pause   R stop")
end

-- The step panel shows while debugging with the tool in hand.
function LogicTool:cl_updateStepHud(equipped)
	local gui = self.cl.stepGui
	if not gui then return end
	local want = (self.cl.debug ~= nil or self.cl.logView ~= nil) and equipped
	if want and not gui:isActive() then
		if self.cl.logView then self:cl_showLogHud() else self:cl_showDebugHud() end
		gui:open()
	elseif not want and gui:isActive() then
		gui:close()
	end
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
	for _, e in ipairs(self.cl.debugFrames) do
		if sm.exists(e) and not e:isPlaying() then e:start() end
	end
	local src = self.cl.wireSource
	if src and sm.exists(src.effect) and not src.effect:isPlaying() then src.effect:start() end
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
	for _, e in ipairs(self.cl.debugFrames) do
		if sm.exists(e) then e:stop() end
	end
	local src = self.cl.wireSource
	if src and sm.exists(src.effect) then src.effect:stop() end
	for _, e in ipairs(self.cl.dots) do
		if sm.exists(e) then e:stop() end
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
	self:cl_clearLutPreview(true)
end

local UP = sm.vec3.new(0, 1, 0)
local HIDDEN_SCALE = sm.vec3.new(0.0001, 0.0001, 0.0001) -- an unused line piece

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
		e:setScale(HIDDEN_SCALE)
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
function LogicTool:cl_connection(i, from, to, color, gap)
	local d = to - from
	local len = d:length()
	if len < 0.01 then return i end
	local dir = d / len
	gap = math.min(gap or ARROW_GAP, len * 0.4)
	local arrowLen = math.min(ARROW_LEN, len * 0.3)
	local tip = to - dir * gap
	local base = tip - dir * arrowLen
	self:cl_line(i, WIRE_UUID, from, base, color, LINE_THICK)
	self:cl_line(i + 1, ARROW_UUID, base, tip, color, ARROW_WIDTH)
	return i + 2
end

function LogicTool:cl_updateLines()
	local n = 1
	local view = self.cl.debug and self.cl.debug.view
	if view then
		-- stepping: only this tick's changes, an arrow to every part each one
		-- feeds (where the change goes next). B is the end, so no arrows out of it.
		local isB = {}
		for _, e in ipairs(self.cl.groups.B) do isB[e.inter.id] = true end
		local function arrows(inter, color)
			if not sm.exists(inter) or isB[inter.id] then return end
			local from = inter:getShape().worldPosition
			for _, child in ipairs(inter:getChildren(LOGIC)) do
				if n > MAX_LINES - 1 then return end
				local cs = child:getShape()
				if cs and sm.exists(cs) then
					local to = cs.worldPosition
					local start = from
					-- wired to itself, or stacked in the same spot: come in from above
					if (to - from):length() < 0.05 then start = to + DEBUG_LOOP_RISE end
					n = self:cl_connection(n, start, to, color)
				end
			end
		end
		-- this tick's changes first (they matter most if the pool runs out)
		for _, c in ipairs(view.changed) do arrows(c.inter, c.on and COLOR_RISE or COLOR_FALL) end
		for _, inter in ipairs(view.steady or {}) do arrows(inter, COLOR_STEADY) end
	end
	local lv = self.cl.logView and self.cl.logView.entry
	if lv and not view then
		-- browsing the log: this entry's wires, green added, red removed
		for _, w in ipairs(lv.wires or {}) do
			if n > MAX_LINES - 1 then break end
			if sm.exists(w.p) and sm.exists(w.c) then
				local from, to = w.p:getShape().worldPosition, w.c:getShape().worldPosition
				if (to - from):length() < 0.05 then from = to + DEBUG_LOOP_RISE end
				n = self:cl_connection(n, from, to, w.kind == "connect" and COLOR_RISE or COLOR_FALL)
			end
		end
	end
	local src = not view and not lv and self:cl_wireSource()
	if src and self.cl.wireDrag then
		-- dragging: a line from the source to the dot you aim at, or the crosshair
		local from = src:getShape().worldPosition
		local aim = self.cl.wireAim
		local to
		if aim and sm.exists(aim) then
			to = aim:getShape().worldPosition
		else
			local cam = sm.camera.getPosition()
			to = cam + sm.camera.getDirection() * math.max(0.5, (from - cam):length())
		end
		n = self:cl_connection(n, from, to, aim and COLOR_DOT_HOVER or COLOR_DOT, DRAG_ARROW_GAP)
	end
	local done = {} -- wires already drawn, so Lines doesn't draw them again
	if src then
		-- Click: Wire: what the source feeds now
		local from = src:getShape().worldPosition
		for _, c in ipairs(src:getChildren(LOGIC)) do
			if n > MAX_LINES - 1 then break end
			local cs = c:getShape()
			done[src.id .. ">" .. c.id] = true
			if cs and sm.exists(cs) then
				local start = from
				if (cs.worldPosition - from):length() < 0.05 then start = cs.worldPosition + DEBUG_LOOP_RISE end
				n = self:cl_connection(n, start, cs.worldPosition, src:isActive() and COLOR_ON or COLOR_OFF)
			end
		end
	end
	if self.cl.showLines and not view and not lv then
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
		local any = false
		for _, g in ipairs(GROUPS) do
			for _, e in ipairs(self.cl.groups[g]) do
				any = true
				local inter = e.inter
				if sm.exists(inter) then
					for _, c in ipairs(inter:getChildren(LOGIC)) do draw(inter, c) end
					for _, p in ipairs(inter:getParents(LOGIC)) do draw(p, inter) end
				end
			end
		end
		if not any then
			-- no groups: every wire on the creation you look at (or last looked at)
			for _, w in ipairs(self:cl_allWires()) do draw(w[1], w[2]) end
		end
	end

	local path = view and {} or self.cl.path
	for i = 1, #path - 1 do
		if n > MAX_LINES - 1 then break end
		local a, b = path[i], path[i + 1]
		if sm.exists(a) and sm.exists(b) then
			local up = sm.vec3.new(0, 0, 0.02)
			n = self:cl_connection(n, a:getShape().worldPosition + up, b:getShape().worldPosition + up, COLOR_PATH)
		end
	end

	-- unused pieces are shrunk away, not stopped: an effect stopped and
	-- started again a frame later can stay hidden while it says it plays.
	-- They really stop only when the tool is put away (cl_hideWorldVisuals).
	for i = n, #self.cl.lines do
		local e = self.cl.lines[i]
		if e and sm.exists(e) and e:isPlaying() then e:setScale(HIDDEN_SCALE) end
	end
end

-- Lines with no groups: the wires of the creation last looked at, nearest
-- first, as many as the line pool can draw. Found again every few frames.
function LogicTool:cl_allWires()
	local c = self.cl.allWires
	local look = self.cl.lookShape
	local body = look and sm.exists(look) and look.body or nil
	if c and c.frames > 0 and (not body or c.bodyIds[body.id]) then
		c.frames = c.frames - 1
		return c.list
	end
	if not body then return c and c.list or {} end
	local bodyIds, pairs_ = {}, {}
	for _, b in ipairs(body:getCreationBodies()) do
		bodyIds[b.id] = true
		for _, inter in ipairs(b:getInteractables()) do
			if isLogicCapable(inter) then
				for _, ch in ipairs(inter:getChildren(LOGIC)) do pairs_[#pairs_ + 1] = { inter, ch } end
			end
		end
	end
	local keep = math.floor(MAX_LINES / 2)
	if #pairs_ > keep then
		local cam = sm.camera.getPosition()
		local dist = {}
		for _, w in ipairs(pairs_) do
			local ps, cs = w[1]:getShape(), w[2]:getShape()
			dist[w] = (ps and cs) and ((ps.worldPosition + cs.worldPosition) * 0.5 - cam):length() or math.huge
		end
		table.sort(pairs_, function(x, y) return dist[x] < dist[y] end)
		for i = #pairs_, keep + 1, -1 do pairs_[i] = nil end
	end
	self.cl.allWires = { list = pairs_, bodyIds = bodyIds, frames = DOT_REFRESH }
	return pairs_
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
	-- stepping: ticks until each part changes next (counts down every step)
	local view = self.cl.debug and self.cl.debug.view
	if view then
		local out, byId = {}, {}
		-- XOR memories always say what they hold, plus their countdown if any
		for _, m in ipairs(view.mems or {}) do
			local e = { inter = m.inter, text = m.on and "#d8b000MEM on" or "#909090MEM off" }
			out[#out + 1] = e
			byId[m.inter.id] = e
		end
		for _, e in ipairs(view.next or {}) do
			local t = (e.n == 1 and "#40ff60" or "#ffffff") .. e.n .. "t"
			local mem = byId[e.inter.id]
			if mem then
				mem.text = mem.text .. " " .. t
			else
				out[#out + 1] = { inter = e.inter, text = t }
			end
		end
		return out
	end
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
					text = GROUP_HEX[g] .. partName(g, i)
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
		return a.i < b.i -- same spot: keep group order, so stacked labels read A0 under A1
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
	self:cl_updateVerify(dt)
	if self.cl.saveIn then
		self.cl.saveIn = self.cl.saveIn - dt
		if self.cl.saveIn <= 0 then self:cl_saveSettings() end
	end

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
	self:cl_updateStepHud(equipped)
	if not equipped then return end

	local dbg = self.cl.debug
	if dbg and dbg.running and not dbg.pending then
		dbg.timer = dbg.timer + dt
		if dbg.timer >= (parseSpeed(self.cl.debugSpeedText) or 1) then
			dbg.timer = 0
			self:cl_debugStep(1)
		end
	end

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
	self:cl_drawDots()
	self:cl_updateLabels(dt)
end

---------------------------------------------------------------------------
-- CLIENT: Click: Wire (the game's connect tool, but logged)
---------------------------------------------------------------------------

function LogicTool:cl_setWireSource(inter)
	local s = self.cl.wireSource
	if s and sm.exists(s.effect) then s.effect:destroy() end
	self.cl.wireSource = nil
	if not (inter and sm.exists(inter)) then return end
	local e = sm.effect.createEffect("ShapeRenderable", inter)
	e:setParameter("uuid", FRAME_UUID)
	e:setParameter("color", COLOR_SOURCE)
	e:setScale(frameScale(inter:getShape(), FLAG_PAD))
	if self.tool:isEquipped() then e:start() end
	self.cl.wireSource = { inter = inter, effect = e }
end

function LogicTool:cl_wireSource()
	local s = self.cl.wireSource
	if s and sm.exists(s.inter) then return s.inter end
	if s then self:cl_setWireSource(nil) end
end

-- Which parts can be wired from (no source picked) or to (a source picked).
-- A with parts: wiring starts only on A. B with parts: it ends only on B.
function LogicTool:cl_wireAllowed(inter, asTarget)
	if not (inter and sm.exists(inter)) then return false end
	local g = asTarget and "B" or "A"
	if #self.cl.groups[g] > 0 then return self:cl_indexOf(g, inter) ~= nil end
	local ok, t
	if asTarget then
		ok, t = pcall(inter.getConnectionInputType, inter)
	else
		ok, t = pcall(inter.getConnectionOutputType, inter)
	end
	return ok and bit.band(t, LOGIC) ~= 0
end

-- The parts that get dots: group A or B when it has parts, else every logic
-- part on the creation you look at (and on the source's). Re-read every few
-- frames; looking at the sky keeps the last creation, so you can aim between dots.
function LogicTool:cl_wireCandidates(lookShape)
	local src = self:cl_wireSource()
	local asTarget = src ~= nil
	local c = self.cl.wireCache
	local lookBody = lookShape and sm.exists(lookShape) and lookShape.body or nil
	-- groups changed (A or B decide what may be picked)
	local A, B = self.cl.groups.A, self.cl.groups.B
	local groupKey = #A .. ":" .. #B .. ":" .. (A[1] and A[1].inter.id or "") .. ":" .. (B[1] and B[1].inter.id or "")
		.. ":" .. (A[#A] and A[#A].inter.id or "") .. ":" .. (B[#B] and B[#B].inter.id or "")
	local stale = not c or c.asTarget ~= asTarget or c.src ~= src or c.frames <= 0 or c.groupKey ~= groupKey
		or (lookBody and not c.bodyIds[lookBody.id])
	if not stale then
		c.frames = c.frames - 1
		return c.list
	end

	local bodies, bodyIds = {}, {}
	local function addCreation(body)
		if not (body and sm.exists(body)) or bodyIds[body.id] then return end
		for _, b in ipairs(body:getCreationBodies()) do
			if not bodyIds[b.id] then
				bodyIds[b.id] = true
				bodies[#bodies + 1] = b
			end
		end
	end
	if lookBody then
		addCreation(lookBody)
	elseif c then
		for _, b in ipairs(c.bodies) do addCreation(b) end
	end
	if src then addCreation(src:getShape().body) end

	local list = {}
	local g = asTarget and "B" or "A"
	if #self.cl.groups[g] > 0 then
		for _, e in ipairs(self.cl.groups[g]) do
			if sm.exists(e.inter) and e.inter ~= src then list[#list + 1] = e.inter end
		end
	else
		for _, b in ipairs(bodies) do
			if sm.exists(b) then
				for _, inter in ipairs(b:getInteractables()) do
					if inter ~= src and isLogicCapable(inter) and self:cl_wireAllowed(inter, asTarget) then
						list[#list + 1] = inter
					end
				end
			end
		end
	end
	if #list > DOT_MAX then
		local cam = sm.camera.getPosition()
		local dist = {}
		for _, inter in ipairs(list) do dist[inter] = (inter:getShape().worldPosition - cam):length() end
		table.sort(list, function(x, y) return dist[x] < dist[y] end)
		for i = #list, DOT_MAX + 1, -1 do list[i] = nil end
	end
	local set = {}
	for _, inter in ipairs(list) do set[inter] = true end
	self.cl.wireCache = { asTarget = asTarget, src = src, bodies = bodies, bodyIds = bodyIds,
		list = list, set = set, frames = DOT_REFRESH, groupKey = groupKey }
	return list
end

-- The part you're aiming at: the one under the crosshair if it may be picked,
-- else the dot nearest the crosshair (within DOT_SNAP; nearer parts win ties).
function LogicTool:cl_wireAimAt(list, lookInter)
	local c = self.cl.wireCache
	if lookInter and c and c.set[lookInter] and sm.exists(lookInter) then return lookInter end
	local cam, dir = sm.camera.getPosition(), sm.camera.getDirection()
	local best, bestOff, bestT
	for _, inter in ipairs(list) do
		if sm.exists(inter) then
			local v = inter:getShape().worldPosition - cam
			local t = v:dot(dir)
			if t > 0.1 and t < RANGE then
				local off = (v - dir * t):length() / t
				if off < DOT_SNAP and (not best or off < bestOff - 0.005 or (off < bestOff + 0.005 and t < bestT)) then
					best, bestOff, bestT = inter, off, t
				end
			end
		end
	end
	return best
end

-- Like the connect tool: wired already cuts it, and a wire the other way
-- (the game allows only one direction) is cut too.
function LogicTool:cl_wireTo(src, inter, label)
	if containsInter(inter:getChildren(LOGIC), src) then
		self:cl_sendOps({ { kind = "cut", p = inter, c = src } }, label)
	else
		self:cl_sendOps({ { kind = "flip", p = src, c = inter } }, label)
	end
end

-- Left button down. No source: pick the part you aim at (hold and drag to wire
-- it). A source picked (by an earlier click): wire it to the part you aim at,
-- or drop it when you click the source itself.
function LogicTool:cl_wirePress(aim, lookInter)
	local src = self:cl_wireSource()
	if src then
		if lookInter == src and not aim then
			self:cl_setWireSource(nil)
			sm.audio.play("ConnectTool - Released")
		elseif aim then
			self:cl_wireTo(src, aim, "Wire click")
		end
	elseif aim then
		self:cl_setWireSource(aim)
		self.cl.wireDrag = { dir = sm.camera.getDirection() }
		sm.audio.play("ConnectTool - Selected")
	end
end

-- Left button up after picking a source. Dragged: wire to the part you let go
-- on (nothing there cancels) and drop the source, like the connect tool. Not
-- dragged: it was a click, so the source stays picked for clicking targets.
function LogicTool:cl_wireRelease(aim)
	local drag = self.cl.wireDrag
	self.cl.wireDrag = nil
	local src = self:cl_wireSource()
	if not (drag and src) then return end
	if (sm.camera.getDirection() - drag.dir):length() < WIRE_DRAG_TURN then return end
	if aim then self:cl_wireTo(src, aim, "Wire drag") end
	self:cl_setWireSource(nil)
	if not aim then sm.audio.play("ConnectTool - Released") end
end

function LogicTool:cl_wireHint(aim)
	local src = self:cl_wireSource()
	local function verb()
		if containsInter(src:getChildren(LOGIC), aim) then return "#ff6060Cut#ffffff source > this" end
		if containsInter(aim:getChildren(LOGIC), src) then return "#ff6060Cut#ffffff this > source" end
		return "Connect source > this"
	end
	if self.cl.wireDrag then
		return aim and ("Let go: " .. verb()) or "Let go on a dot to wire (elsewhere cancels)"
	end
	if src then
		return aim and verb() or "Click a dot to wire the source to"
	end
	if aim then return "Wire from this part (click, or drag to a dot)" end
	return #self.cl.groups.A > 0 and ("Aim at a dot in " .. GROUP_HEX.A .. "A#ffffff to wire from")
		or "Aim at a dot to wire from"
end

-- Dots on the parts you can pick: grey, the one you aim at yellow (bigger), the
-- source green. Each sits on the side of its part that faces you and is sized
-- to its part, so it shrinks with distance like the parts do.
function LogicTool:cl_drawDots()
	local n = 0
	local src = self:cl_wireSource()
	local list = self.cl.wireList
	if list and not self.cl.debug and not self.cl.logView then
		local cam = sm.camera.getPosition()
		local aim = self.cl.wireAim
		local function dot(inter, color, grow)
			if not (inter and sm.exists(inter)) then return end
			local shape = inter:getShape()
			if not (shape and sm.exists(shape)) then return end
			n = n + 1
			local e = self.cl.dots[n]
			if not (e and sm.exists(e)) then
				e = sm.effect.createEffect("ShapeRenderable")
				e:setParameter("uuid", DOT_UUID)
				self.cl.dots[n] = e
			end
			local centre = shape.worldPosition
			local toCam = cam - centre
			local dist = toCam:length()
			local bb = shape:getBoundingBox()
			local push = math.max(bb.x, bb.y, bb.z) * 0.5 + 0.02
			local pos = dist > push + 0.05 and (centre + toCam * (push / dist)) or centre
			-- a fixed size in the world, like the parts: smaller on screen further away
			local size = math.min(bb.x, bb.y, bb.z) * DOT_SIZE * (grow or 1)
			e:setParameter("color", color)
			e:setPosition(pos)
			e:setScale(sm.vec3.new(size, size, size))
			if not e:isPlaying() then e:start() end
		end
		-- the source and the aim first, so the DOT_MAX limit never drops them
		dot(src, COLOR_DOT_PICKED, DOT_HOVER_GROW)
		if aim ~= src then dot(aim, COLOR_DOT_HOVER, DOT_HOVER_GROW) end
		for _, inter in ipairs(list) do
			if n >= DOT_MAX + 2 then break end
			if inter ~= aim and inter ~= src then dot(inter, COLOR_DOT) end
		end
	end
	for i = n + 1, #self.cl.dots do
		local e = self.cl.dots[i]
		if e and sm.exists(e) and e:isPlaying() then e:setScale(HIDDEN_SCALE) end
	end
end

---------------------------------------------------------------------------
-- CLIENT: wiring log
---------------------------------------------------------------------------

-- "#5  All > All, Flip mode: connected 2, cut 3  1 min ago": what was
-- pressed, in which wire mode, and what actually happened
local function logLine(e, now)
	local parts = {}
	if (e.made or 0) > 0 then parts[#parts + 1] = "#40ff60connected " .. e.made .. "#ffffff" end
	if (e.cut or 0) > 0 then parts[#parts + 1] = "#ff6060cut " .. e.cut .. "#ffffff" end
	local what = e.label .. (e.mode and (", " .. WIRE_VERBS[e.mode] .. " mode") or "")
	local ago = (now and e.clientTick) and ("  #909090" .. agoText(now - e.clientTick) .. "#ffffff") or ""
	return string.format("#%d  %s: %s%s%s", e.id, what, table.concat(parts, ", "), ago,
		e.undone and "  #909090(undone)#ffffff" or "")
end

function LogicTool:cl_showLogList()
	if not self.cl.gui then return end
	local lines = {}
	local now = nowTick()
	for i = #self.cl.log, 1, -1 do lines[#lines + 1] = logLine(self.cl.log[i], now) end
	local text = #lines > 0 and (#lines .. " entr" .. (#lines == 1 and "y" or "ies") .. ", newest first:\n\n" .. table.concat(lines, "\n"))
		or ("Nothing logged yet.\n\n" .. LOG_HINT)
	if text ~= self.cl.logText then
		self.cl.logText = text
		self.cl.gui:setText("logList", text)
	end
end

function LogicTool:cl_startLogView()
	if #self.cl.log == 0 then sm.gui.displayAlertText("The log is empty", 2) return end
	if self.cl.debug then sm.gui.displayAlertText("Stop the debugger first", 2) return end
	self:cl_setWireSource(nil)
	self.cl.logView = { pos = #self.cl.log, pending = false }
	if self.cl.gui:isActive() then self.cl.gui:close() end
	sm.gui.displayAlertText("Log: left click = older, right click = newer, Q = undo this, R = stop", 4)
	self:cl_logFetch()
end

function LogicTool:cl_logFetch()
	local lv = self.cl.logView
	local e = lv and self.cl.log[lv.pos]
	if not e then return end
	lv.pending = true
	self.network:sendToServer("sv_logShow", { id = e.id })
end

function LogicTool:cl_logStep(dir)
	local lv = self.cl.logView
	if not lv then return end
	local pos = lv.pos + dir
	if pos < 1 then sm.gui.displayAlertText("Oldest entry", 1) return end
	if pos > #self.cl.log then sm.gui.displayAlertText("Newest entry", 1) return end
	lv.pos = pos
	-- the entry shown stays drawn until the next one arrives, so the arrows
	-- never go away for a frame (see cl_updateLines)
	lv.loading = true
	self:cl_showLogHud()
	self:cl_logFetch()
end

function LogicTool:cl_logUndoShown()
	local lv = self.cl.logView
	local e = lv and self.cl.log[lv.pos]
	if not e then return end
	if e.undone then sm.gui.displayAlertText("Already undone (the undo is its own entry: undo that to redo)", 2.5) return end
	self.network:sendToServer("sv_logUndo", { id = e.id })
end

function LogicTool:cl_stopLogView()
	if not self.cl.logView then return end
	self.cl.logView = nil
	self:cl_clearDebugFrames()
	if self.cl.stepGui and self.cl.stepGui:isActive() then self.cl.stepGui:close() end
end

function LogicTool:cl_onLogEntry(r)
	local lv = self.cl.logView
	local e = lv and self.cl.log[lv.pos]
	if not (e and e.id == r.id) then return end -- moved on meanwhile
	lv.pending = false
	lv.loading = false
	lv.entry = r
	-- cubes on both ends of every wire
	self:cl_clearDebugFrames()
	local show = self.tool:isEquipped()
	local framed = {}
	for _, w in ipairs(r.wires or {}) do
		for _, inter in ipairs({ w.p, w.c }) do
			if #self.cl.debugFrames < DEBUG_MAX_FRAMES and not framed[inter.id] and sm.exists(inter) then
				framed[inter.id] = true
				local f = sm.effect.createEffect("ShapeRenderable", inter)
				f:setParameter("uuid", FRAME_UUID)
				f:setParameter("color", w.kind == "connect" and COLOR_RISE or COLOR_FALL)
				f:setScale(frameScale(inter:getShape(), FLAG_PAD))
				if show then f:start() end
				self.cl.debugFrames[#self.cl.debugFrames + 1] = f
			end
		end
	end
	self:cl_showLogHud()
end

function LogicTool:cl_showLogHud()
	local gui, lv = self.cl.stepGui, self.cl.logView
	if not (gui and lv) then return end
	local e = self.cl.log[lv.pos]
	if not e then return end
	gui:setText("stepTick", string.format("Log %d / %d   #a0a0a0#%d", lv.pos, #self.cl.log, e.id))
	gui:setText("stepOutputs", logLine(e, nowTick()))
	local r = lv.entry
	local info
	if not r or lv.loading then
		info = "Loading..."
	elseif r.missing then
		info = "#ff6060This entry is no longer kept#ffffff"
	else
		info = string.format("%d wire(s)", r.total)
		if r.total > 0 and r.gone == r.total then
			info = "#ffcc40Nothing to show: the parts of this entry are gone (removed, or replaced by Build LUT)#ffffff"
		elseif r.gone > 0 then
			info = info .. string.format("   #ffcc40%d gone (parts removed or replaced by Build LUT)#ffffff", r.gone)
		end
		if r.total - r.gone > #r.wires then info = info .. string.format("   showing %d", #r.wires) end
	end
	gui:setText("stepInfo", info)
	gui:setText("stepKeys", "Left click older   Right click newer   Q undo this   R stop")
end
