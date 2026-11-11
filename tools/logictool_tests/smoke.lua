-- Smoke test: loads LogicTool.lua against a mocked `sm` API and drives the
-- main flows. Catches nil errors, typos and accidental globals. It does NOT
-- prove the game API behaves like the mock.
local SCRIPTS = ...
-- the mocks need these; the mod's scripts must not (the game doesn't have them)
local setmetatable, getmetatable, rawset = setmetatable, getmetatable, rawset
local failures = 0
local function check(name, cond, detail)
	if not cond then
		failures = failures + 1
		print("FAIL: " .. name .. (detail and ("  -- " .. tostring(detail)) or ""))
	end
end

---------------------------------------------------------------------------
-- math types
---------------------------------------------------------------------------
local V = {}
V.__index = V
local function vec(x, y, z) return setmetatable({ x = x, y = y, z = z }, V) end
V.__add = function(a, b) return vec(a.x + b.x, a.y + b.y, a.z + b.z) end
V.__sub = function(a, b) return vec(a.x - b.x, a.y - b.y, a.z - b.z) end
V.__unm = function(a) return vec(-a.x, -a.y, -a.z) end
V.__mul = function(a, b)
	if type(a) == "number" then a, b = b, a end
	if type(b) == "number" then return vec(a.x * b, a.y * b, a.z * b) end
	return vec(a.x * b.x, a.y * b.y, a.z * b.z)
end
V.__div = function(a, b) return vec(a.x / b, a.y / b, a.z / b) end
V.__eq = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
function V:length() return math.sqrt(self.x ^ 2 + self.y ^ 2 + self.z ^ 2) end
function V:dot(b) return self.x * b.x + self.y * b.y + self.z * b.z end
function V:min(b) return vec(math.min(self.x, b.x), math.min(self.y, b.y), math.min(self.z, b.z)) end
function V:max(b) return vec(math.max(self.x, b.x), math.max(self.y, b.y), math.max(self.z, b.z)) end
V.__tostring = function(a) return string.format("(%g,%g,%g)", a.x, a.y, a.z) end

local Q = {}
Q.__index = Q
local function quat() return setmetatable({ q = true }, Q) end
Q.__mul = function(a, b)
	if getmetatable(b) == V then return vec(b.x, b.y, b.z) end
	return quat()
end

---------------------------------------------------------------------------
-- game objects
---------------------------------------------------------------------------
local nextId = 100
local function newId() nextId = nextId + 1 return nextId end

local Inter = {}
Inter.__index = Inter
function Inter:getConnectionInputType() return self.inType end
function Inter:getConnectionOutputType() return self.outType end
function Inter:getChildren() local o = {} for _, c in ipairs(self.children) do o[#o + 1] = c end return o end
function Inter:getParents() local o = {} for _, c in ipairs(self.parents) do o[#o + 1] = c end return o end
function Inter:getShape() return self.shape end
function Inter:getBody() return self.shape.body end
function Inter:isActive() return false end
local function removeFrom(list, x)
	for i, v in ipairs(list) do if v == x then table.remove(list, i) return true end end
end
function Inter:connect(c)
	assert(SERVER, "connect called on client")
	for _, x in ipairs(self.children) do if x == c then return false end end
	if c.inType == 0 then return false end
	self.children[#self.children + 1] = c
	c.parents[#c.parents + 1] = self
	return true
end
function Inter:disconnect(c)
	assert(SERVER, "disconnect called on client")
	removeFrom(self.children, c)
	removeFrom(c.parents, self)
	return true
end

local Body = {}
Body.__index = Body
function Body:getCreationBodies() return self.creation end
function Body:isOnLift() return self.lifted == true end
function Body:getWorldAabb()
	local lo, hi
	for _, s in ipairs(self.shapes) do
		local p = s.worldPosition
		lo = lo and vec(math.min(lo.x, p.x), math.min(lo.y, p.y), math.min(lo.z, p.z)) or p
		hi = hi and vec(math.max(hi.x, p.x), math.max(hi.y, p.y), math.max(hi.z, p.z)) or p
	end
	lo = lo or vec(0, 0, 0)
	return lo, hi or lo
end
function Body:getCreationShapes()
	local o = {}
	for _, b in ipairs(self.creation) do for _, s in ipairs(b.shapes) do o[#o + 1] = s end end
	return o
end
function Body:getShapes() return self.shapes end
function Body:getInteractables()
	local o = {}
	for _, s in ipairs(self.shapes) do if s.interactable then o[#o + 1] = s.interactable end end
	return o
end

local UUID_GATE = "9f0f56e8-2c31-4d83-996c-d00a9b296c3f"
local UUID_TIMER = "8f7fd0e7-c46e-4944-a414-7ce2437bb30f"
local UUID_SWITCH = "7cf717d7-d167-4f2d-a6e7-6b2c70aa3986"
local UUID_LIGHT = "ed27f5e2-cac5-4a32-a5d9-49f116acc6af"

local body = setmetatable({ id = 1, worldPosition = vec(0, 0, 0), worldRotation = quat(), shapes = {} }, Body)
body.creation = { body }

local function destroyShape(shape)
	shape.destroyed = true
	if shape.interactable then
		local inter = shape.interactable
		inter.destroyed = true
		for _, c in ipairs(inter.children) do removeFrom(c.parents, inter) end
		for _, p in ipairs(inter.parents) do removeFrom(p.children, inter) end
	end
	local b = shape.body
	removeFrom(b.shapes, shape)
	if #b.shapes == 0 then b.destroyed = true end
end

local function addPart(uuid, x, y, z, ctrl, color, onBody)
	local body = onBody or body
	local shape = {
		gx = x, gy = y, gz = z, destroyShape = destroyShape,
		uuid = setmetatable({ s = uuid }, { __tostring = function(t) return t.s end }),
		color = setmetatable({ s = color or "df7f00ff" }, { __tostring = function(t) return t.s end,
			__index = { getHexStr = function(t) return t.s end } }),
		worldPosition = vec(x * 0.25, y * 0.25, z * 0.25), worldRotation = quat(), body = body,
		isBlock = false, id = newId(),
		getBoundingBox = function(self) return vec(0.25, 0.25, 0.25) end,
	}
	local inter = setmetatable({ id = newId(), shape = shape, children = {}, parents = {},
		inType = (uuid == UUID_SWITCH) and 0 or 1, outType = (uuid == UUID_LIGHT) and 0 or 1, ctrl = ctrl }, Inter)
	shape.interactable = inter
	body.shapes[#body.shapes + 1] = shape
	return inter, shape
end

local switch1 = addPart(UUID_SWITCH, 0, 0, 0)
local switch2 = addPart(UUID_SWITCH, 0, 1, 0)
local gates = {}
for i = 1, 4 do gates[i] = addPart(UUID_GATE, 2, i, 0, { mode = (i % 2) }) end
local timer = addPart(UUID_TIMER, 4, 0, 0, { seconds = 0, ticks = 5 })
local light = addPart(UUID_LIGHT, 6, 0, 0)
-- a plain block (no interactable)
body.shapes[#body.shapes + 1] = { uuid = "block", color = "x", worldPosition = vec(9, 9, 9), worldRotation = quat(), body = body,
	gx = 0, gy = 0, gz = -1, bounds = { x = 8, y = 6, z = 1 }, destroyShape = destroyShape }

---------------------------------------------------------------------------
-- sm mock
---------------------------------------------------------------------------
local alerts, chats = {}, {}
local effects = {}
local Effect = {}
Effect.__index = Effect
for _, m in ipairs({ "setParameter", "setPosition", "setRotation", "setScale", "setOffsetPosition" }) do
	Effect[m] = function(self, ...) assert(not self.destroyed, "use of destroyed effect: " .. m) end
end
function Effect:setScale(v) assert(not self.destroyed, "use of destroyed effect: setScale") self.scale = v end
function Effect:start() assert(not self.destroyed) self.playing = true end
function Effect:stop() self.playing = false end
function Effect:isPlaying() return self.playing end
function Effect:destroy() self.destroyed = true end

local Gui = {}
-- like the game: using a GUI function that doesn't exist is an error
Gui.__index = function(_, k)
	local v = Gui[k]
	if v == nil then error("Unknown member '" .. tostring(k) .. "' in userdata", 2) end
	return v
end
function Gui:setButtonCallback(name, cb) self.buttons[name] = cb end
function Gui:setTextChangedCallback(name, cb) self.textCbs[name] = cb end
function Gui:setText(name, text) assert(type(text) == "string", "setText needs a string for " .. name) self.texts[name] = text end
function Gui:open() self.active = true end
function Gui:close() self.active = false end
function Gui:isActive() return self.active end
function Gui:destroy() self.destroyed = true end
function Gui:setVisible(name, v) assert(type(v) == "boolean") self.visible[name] = v end
function Gui:setWorldPosition() end
function Gui:setRequireLineOfSight() end
function Gui:setMaxRenderDistance() end
local function newGui() return setmetatable({ buttons = {}, textCbs = {}, texts = {}, visible = {}, active = false }, Gui) end

local raycast = { hit = false }
JSON_STORE, IMPORTS = {}, {}
LIFT, PLACED = nil, {}
CAM = { pos = vec(0, -2, 0), dir = vec(0, 1, 0) }

sm = {
	interactable = { connectionType = { logic = 1, power = 2 } },
	tool = { interactState = { null = 0, start = 1, hold = 2, stop = 3 }, preloadRenderables = function() end },
	uuid = { new = function(s) return setmetatable({ s = s }, { __tostring = function(t) return t.s end }) end },
	color = { new = function(s) return setmetatable({ s = s }, { __tostring = function(t) return t.s end }) end },
	vec3 = {
		new = vec, zero = function() return vec(0, 0, 0) end, one = function() return vec(1, 1, 1) end,
		getRotation = function() return quat() end
	},
	quat = { inverse = function() return quat() end, identity = function() return quat() end },
	exists = function(x) return x ~= nil and not x.destroyed end,
	effect = { createEffect = function(name, host)
		local e = setmetatable({ name = name, host = host }, Effect)
		effects[#effects + 1] = e
		return e
	end },
	gui = {
		createGuiFromLayout = function() return newGui() end,
		createWorldIconGui = function() return newGui() end,
		displayAlertText = function(t) alerts[#alerts + 1] = t end,
		chatMessage = function(t) chats[#chats + 1] = t end,
		setInteractionText = function(...) for i = 1, select("#", ...) do assert(type(select(i, ...)) == "string") end end,
		getKeyBinding = function(n) return "[" .. n .. "]" end,
	},
	audio = { play = function() end },
	localPlayer = { getRaycast = function() return raycast.hit, raycast.res end,
		getOwnedLift = function() return LIFT end },
	player = { placeLift = function(player, bodies, pos, level, rot)
		assert(SERVER, "placeLift on client")
		PLACED[#PLACED + 1] = { bodies = bodies, pos = pos, level = level, rot = rot }
		for _, b in ipairs(bodies) do b.lifted = true end
	end },
	camera = { getPosition = function() return CAM.pos end, getDirection = function() return CAM.dir end },
	creation = {
		exportToTable = function(b)
			assert(SERVER, "export on client")
			local childs = {}
			for _, s in ipairs(b.shapes) do
				local c = { shapeId = tostring(s.uuid), color = "df7f00" }
				if s.bounds then
					c.pos, c.bounds = { x = s.gx, y = s.gy, z = s.gz }, s.bounds
				else
					c.pos, c.xaxis, c.zaxis = { x = s.gx or 0, y = s.gy or 0, z = s.gz or 0 }, 1, 3
				end
				if s.interactable then
					c.controller = { id = s.interactable.id }
					for k, v in pairs(s.interactable.ctrl or {}) do c.controller[k] = v end
					if #s.interactable.children > 0 then
						c.controller.controllers = {}
						for _, ch in ipairs(s.interactable.children) do c.controller.controllers[#c.controller.controllers + 1] = { id = ch.id } end
					end
				end
				childs[#childs + 1] = c
			end
			return { bodies = { { childs = childs } }, joints = {}, version = 4 }
		end,
		importFromString = function(world, json, pos, rot, transforms)
			assert(SERVER, "import on client")
			assert(transforms == true, "import without transforms")
			local bp = JSON_STORE[json]
			local nb = setmetatable({ id = newId(), worldPosition = vec(0, 0, 0), worldRotation = quat(), shapes = {} }, Body)
			nb.creation = { nb }
			local byId = {}
			for _, c in ipairs(bp.bodies[1].childs) do
				if c.controller then
					local ctrl = { mode = c.controller.mode, seconds = c.controller.seconds, ticks = c.controller.ticks }
					local inter = addPart(c.shapeId, c.pos.x, c.pos.y, c.pos.z, ctrl, nil, nb)
					byId[c.controller.id] = inter
				else
					nb.shapes[#nb.shapes + 1] = { uuid = c.shapeId, gx = c.pos.x, gy = c.pos.y, gz = c.pos.z, bounds = c.bounds,
						color = "x", worldPosition = vec(0, 0, 0), worldRotation = quat(), body = nb, destroyShape = destroyShape }
				end
			end
			for _, c in ipairs(bp.bodies[1].childs) do
				for _, w in ipairs(c.controller and c.controller.controllers or {}) do
					assert(byId[w.id], "wire to unknown controller id " .. tostring(w.id))
					byId[c.controller.id]:connect(byId[w.id])
				end
			end
			IMPORTS[#IMPORTS + 1] = nb
			return { nb }
		end,
	},
	json = { save = function(t, path) assert(type(t) == "table" and path:find("$CONTENT_DATA", 1, true)) end, writeJsonString = function(t)
		-- deep copy, so later edits to `t` don't leak into the "string"
		local function copy(v)
			if type(v) ~= "table" then return v end
			local o = {}
			for k, x in pairs(v) do o[k] = copy(x) end
			return o
		end
		JSON_STORE[#JSON_STORE + 1] = copy(t)
		return #JSON_STORE
	end },
	world = { getCurrentWorld = function() return "world" end },
}

function class()
	local c = {}
	c.__index = c
	return c
end

createTpAnimations = function() return { animations = {}, currentAnimation = "idle" } end
setTpAnimation = function() end
createFpAnimations = function() return { animations = {}, currentAnimation = "idle" } end
swapFpAnimation = function() return clamp(0, 0, 1) end  -- the real one needs util.lua's clamp
updateFpAnimations = function() end

local realDofile = dofile
function dofile(path)
	if path:find("AnimationUtil") then return end
	if path:find("util.lua") then
		clamp = function(v, a, b) return math.max(a, math.min(b, v)) end
		return
	end
	local name = path:gsub("%$CONTENT_DATA/Scripts/", "")
	return realDofile(SCRIPTS .. "/" .. name)
end

for _, name in ipairs({ "setmetatable", "getmetatable", "rawget", "rawset", "rawequal", "load", "loadstring" }) do
	_G[name] = nil
end
dofile("$CONTENT_DATA/Scripts/LogicTool.lua")

-- no accidental globals from here on
local allowed = { CAM = true, LogicTool = true, LogicScript = true, LogicGraph = true, LogicModule = true, SERVER = true, clamp = true,
	JSON_STORE = true, IMPORTS = true, DBG = true, LIFT = true, PLACED = true }
setmetatable(_G, {
	__newindex = function(t, k, v)
		if not allowed[k] then error("global write: " .. tostring(k), 2) end
		rawset(t, k, v)
	end,
	__index = function(_, k) error("undefined global: " .. tostring(k), 2) end
})

---------------------------------------------------------------------------
-- drive it
---------------------------------------------------------------------------
local player = { id = 1 }
local tool = setmetatable({}, { __index = LogicTool })
tool.tool = {
	isLocal = function() return true end, isEquipped = function() return true end,
	isSprinting = function() return false end, setMovementAnimation = function() end,
	setTpRenderables = function() end, setFpRenderables = function() end,
}
tool.network = {
	sendToServer = function(_, name, data)
		SERVER = true
		local ok, err = pcall(tool[name], tool, data, player)
		SERVER = false
		if not ok then error("server " .. name .. ": " .. tostring(err), 0) end
	end,
	sendToClient = function(_, p, name, data)
		local ok, err = pcall(tool[name], tool, data)
		if not ok then error("client " .. name .. ": " .. tostring(err), 0) end
	end,
}
SERVER = false

local function step(name, fn)
	local ok, err = pcall(fn)
	check(name, ok, err)
end

local S = sm.tool.interactState
local function lookAt(inter)
	if inter then
		raycast.hit = true
		raycast.res = { type = "body", pointWorld = inter.shape.worldPosition, getShape = function() return inter.shape end }
	else
		raycast.hit = false
		raycast.res = nil
	end
end
local function click(inter, force)
	lookAt(inter)
	tool:client_onEquippedUpdate(S.start, S.null, force)
	tool:client_onEquippedUpdate(S.hold, S.null, force)
	tool:client_onEquippedUpdate(S.stop, S.null, force)
end
local function rightClick()
	tool:client_onEquippedUpdate(S.null, S.start, false)
end
local function press(name) tool:cl_onButton(name) end
local function result() return tool.cl.gui.texts.result or "" end

step("server create", function() SERVER = true tool:server_onCreate() SERVER = false end)
step("client create", function() tool:client_onCreate() end)
step("equip", function() tool:client_onEquip() end)
step("update empty", function() lookAt(nil) tool:client_onEquippedUpdate(S.null, S.null, false) tool:client_onUpdate(0.016) end)

-- A = two switches (click), B = gates (F+click = same type)
step("click select", function() click(switch1) click(switch2) end)
check("A has 2", #tool.cl.groups.A == 2, #tool.cl.groups.A)
step("toggle off/on", function() click(switch2) click(switch2) end)
check("A still 2", #tool.cl.groups.A == 2)
local function labelFor(inter)
	tool:client_onUpdate(0.016)
	for _, e in ipairs(tool.cl.labelShown) do
		if e.inter == inter then return e.text end
	end
end
-- switch2 was removed and re-added, so it is now after switch1
check("order labels on by default", labelFor(switch1) == "#ff9900A0" and labelFor(switch2) == "#ff9900A1",
	tostring(labelFor(switch1)) .. " " .. tostring(labelFor(switch2)))
step("reverse A", function() tool:cl_onButton("reverse") end)
check("order labels follow reverse", labelFor(switch2) == "#ff9900A0", tostring(labelFor(switch2)))
step("reverse A back", function() tool:cl_onButton("reverse") end)
step("right click", rightClick)
check("active B", tool.cl.active == "B")
step("select similar", function() click(gates[1], true) end)
check("B has 4 gates", #tool.cl.groups.B == 4, #tool.cl.groups.B)
local function frameSize(g, inter)
	local e = tool.cl.markers[g][inter.id]
	return e and e.scale and string.format("%.3f", e.scale.x) or "none"
end
check("frames: B alone is tight", frameSize("B", gates[2]) == "0.280", frameSize("B", gates[2]))
step("frames: gate2 into A too", function() tool:cl_add("A", gates[2], gates[2].shape) end)
check("frames: A tight, B hugs it", frameSize("A", gates[2]) == "0.280" and frameSize("B", gates[2]) == "0.310",
	frameSize("A", gates[2]) .. " " .. frameSize("B", gates[2]))
step("frames: gate2 out of A again", function() tool:cl_toggle("A", gates[2], gates[2].shape) end)
check("frames: B tight again", frameSize("B", gates[2]) == "0.280" and frameSize("A", gates[2]) == "none", frameSize("B", gates[2]))

-- box select into C
step("to C", rightClick)
step("box", function()
	lookAt(timer)
	tool:client_onEquippedUpdate(S.start, S.null, false)
	lookAt(light)
	tool:client_onEquippedUpdate(S.hold, S.null, false)
	tool:client_onEquippedUpdate(S.stop, S.null, false)
end)
check("C has timer+light", #tool.cl.groups.C == 2, #tool.cl.groups.C)

-- layer box select (Q): XY layer through the timer, dragged to where the view
-- ray (from (0,-2,0) along +Y) crosses z = 0 -- at y = 0, so the box only reaches
-- the timer row; then 3D again
step("Q to XY layer", function() tool:client_onToggle() end)
check("box mode xy", tool.cl.boxMode == 2 and alerts[#alerts]:find("XY", 1, true), alerts[#alerts])
step("layer drag", function()
	tool:cl_clearGroup("C")
	lookAt(timer)
	tool:client_onEquippedUpdate(S.start, S.null, false)
	-- look down at 45 degrees onto z = 0 at (1.5, 0, 0), the light; the raycast hits nothing
	CAM.pos, CAM.dir = vec(1.5, -1, 1), vec(0, 0.70710678, -0.70710678)
	lookAt(nil)
	tool:client_onEquippedUpdate(S.hold, S.null, false)
	tool:client_onEquippedUpdate(S.stop, S.null, false)
	CAM.pos, CAM.dir = vec(0, -2, 0), vec(0, 1, 0)
end)
check("layer drag was a box", alerts[#alerts]:find("Box (XY", 1, true), alerts[#alerts])
check("layer drag selects timer+light", #tool.cl.groups.C == 2, #tool.cl.groups.C)
step("layer drag along the layer is ignored", function()
	lookAt(timer)
	tool:client_onEquippedUpdate(S.start, S.null, false)
	lookAt(nil)
	tool:client_onEquippedUpdate(S.hold, S.null, false)
	tool:client_onEquippedUpdate(S.stop, S.null, false)
end)
step("Q cycles back to 3D", function() tool:client_onToggle() tool:client_onToggle() tool:client_onToggle() end)
check("box mode 3d", tool.cl.boxMode == 1)
step("restore C", function()
	tool:cl_clearGroup("C")
	lookAt(timer)
	tool:client_onEquippedUpdate(S.start, S.null, false)
	lookAt(light)
	tool:client_onEquippedUpdate(S.hold, S.null, false)
	tool:client_onEquippedUpdate(S.stop, S.null, false)
end)
check("C again", #tool.cl.groups.C == 2, #tool.cl.groups.C)

step("gui open", function() tool:client_onReload() end)
step("all to all", function() press("allToAll") end)
check("switch1 has 4 children", #switch1.children == 4, #switch1.children)
check("result says connected", result():find("8 connected", 1, true), result())
step("again = unchanged", function() press("allToAll") end)
check("unchanged", result():find("8 unchanged", 1, true), result())
step("undo", function() press("undo") end)
check("undo removed", #switch1.children == 0, #switch1.children)
step("zip", function() press("zip") end)
check("zip 2", #switch1.children == 1 and #switch2.children == 1)
step("chain A", function() tool.cl.active = "A" press("chain") end)
check("switch can't take input", result():find("not allowed", 1, true), result())
step("mode: cut", function() press("wireMode") press("allToAll") end)
check("cut mode removes", #switch1.children == 0, #switch1.children)
check("mode button says cut", tool.cl.wireMode == 2)
step("mode: flip on empty = connect", function() press("wireMode") press("allToAll") end)
check("flip connected", #switch1.children == 4, #switch1.children)
step("flip again = cut", function() press("allToAll") end)
check("flip cut", #switch1.children == 0, #switch1.children)
step("zip (connect) then all (flip) mixes", function()
	press("wireMode") press("zip")            -- back to connect
	press("wireMode") press("wireMode") press("allToAll") -- flip
end)
check("flip toggles each pair", #switch1.children == 3 and #switch2.children == 3, #switch1.children .. "/" .. #switch2.children)
step("undo flip", function() press("undo") end)
check("undo flip", #switch1.children == 1 and #switch2.children == 1, #switch1.children .. "/" .. #switch2.children)
step("cut all, back to connect", function() press("wireMode") press("wireMode") press("allToAll") press("wireMode") press("wireMode") end)
check("back to connect", tool.cl.wireMode == 1 and #switch1.children == 0 and #switch2.children == 0)
step("clear active outputs", function() press("allToAll") tool.cl.active = "A" press("clearOut") end)
check("A outputs cleared", #switch1.children == 0 and #switch2.children == 0, #switch1.children)
step("clear active inputs", function() press("allToAll") tool.cl.active = "B" press("clearIn") end)
check("B inputs cleared", #switch1.children == 0 and #switch2.children == 0, #switch1.children)
step("clear inputs on A keeps A outputs", function() press("allToAll") tool.cl.active = "A" press("clearIn") end)
check("A outputs kept", #switch1.children == 4, #switch1.children)
check("caption follows active", tool.cl.gui.texts.clearIn == "Clear inputs: #ff9900A", tool.cl.gui.texts.clearIn)
step("chain B caption", function() tool.cl.active = "B" tool:cl_refreshGui() end)
check("chain caption follows active", tool.cl.gui.texts.chain == "Chain: #00c8ffB", tool.cl.gui.texts.chain)
step("restore active A", function() tool.cl.active = "A" tool:cl_refreshGui() end)
step("tidy", function() press("clearOut") end)
step("sort/reverse", function() press("sortY") press("sortZ") press("reverse") press("reverse") press("sortX") press("active") end)

-- script: wire gates into the timer, timer into light
step("script", function()
	tool:cl_onScriptChanged("script", 'connect(A, B, "zip")\nconnect(slice(B, 1, 2), C[1])\nconnect(C[1], C[2])\nprint(#A, #B, #C, B[1].mode, B[1].kind)')
	press("run")
end)
check("script output", result():find("2 4 2 OR gate", 1, true), result())
check("timer has 2 parents", #timer.parents == 2, #timer.parents)
step("script error", function()
	tool:cl_onScriptChanged("script", "local x = 1\nconnect(A[9], B)")
	press("run")
end)
check("error shown", result():find("line 2: connect needs a part", 1, true), result())
check("error line red in editor", (tool.cl.gui.texts.script or ""):find("#ff5050connect", 1, true), tool.cl.gui.texts.script)
step("format", function()
	tool:cl_onScriptChanged("script", "for i = 1, 2 do\nprint(i)\nend")
	press("format")
end)
check("formatted", tool.cl.script == "for i = 1, 2 do\n    print(i)\nend", tool.cl.script)
check("highlighted", (tool.cl.gui.texts.script or ""):find("#c586c0for", 1, true), tool.cl.gui.texts.script)
step("typing at the end recolours", function()
	tool.cl.gui.texts.script = nil
	tool:cl_onScriptChanged("script", tool.cl.script .. "\nprint(1)")
end)
check("recoloured", tool.cl.gui.texts.script ~= nil)
step("typing in the middle does not", function()
	tool.cl.gui.texts.script = nil
	tool:cl_onScriptChanged("script", "x" .. tool.cl.script)
end)
check("not recoloured", tool.cl.gui.texts.script == nil)
check("script window hidden at start", tool.cl.gui.visible.scriptWindow == false)
step("open script window", function() press("openScript") end)
check("script window shown", tool.cl.gui.visible.scriptWindow == true and tool.cl.gui.texts.openScript == "Hide script")
step("hide script window", function() press("closeScript") end)
check("script window hidden", tool.cl.gui.visible.scriptWindow == false)
check("settings hidden at start", tool.cl.gui.visible.settingsWindow == false)
step("script then settings", function() press("openScript") press("openSettings") end)
check("settings replaces script", tool.cl.gui.visible.settingsWindow == true and tool.cl.gui.visible.scriptWindow == false
	and tool.cl.gui.texts.openSettings == "Hide settings" and tool.cl.gui.texts.openScript == "< Script")
step("settings button again hides", function() press("openSettings") end)
check("settings hidden", tool.cl.gui.visible.settingsWindow == false and tool.cl.gui.texts.openSettings == "< Settings")
step("settings then script", function() press("openSettings") press("openScript") end)
check("script replaces settings", tool.cl.gui.visible.scriptWindow == true and tool.cl.gui.visible.settingsWindow == false)
step("hide settings button", function() press("openSettings") press("closeSettings") end)
check("all left windows hidden", not tool.cl.gui.visible.scriptWindow and not tool.cl.gui.visible.settingsWindow)
check("setting captions are values", tool.cl.gui.texts.boxMode == "3D box" and tool.cl.gui.texts.lines ~= nil
	and not tool.cl.gui.texts.labels:find("Labels", 1, true), tool.cl.gui.texts.labels)
step("examples/help", function() for _ = 1, 6 do press("example") end press("help") end)

-- analysis: A switches -> C light
step("set B = light for timing", function()
	tool:cl_clearGroup("B")
	tool.cl.active = "B"
	click(light)
end)
step("timing", function() press("timing") end)
check("timing text", result():find("Fastest: 7 ticks", 1, true) and result():find("Slowest: 7 ticks", 1, true), result())
check("path lines", #tool.cl.path >= 3, #tool.cl.path)
step("lint", function() press("lint") end)
check("lint text", result():find("CHECK", 1, true), result())
step("truth", function() press("truth") end)
check("truth text", result():find("TRUTH TABLE", 1, true), result())
step("labels cycle", function() for _ = 1, 4 do press("labels") tool:client_onUpdate(0.016) end end)
step("type labels: missing ones are fetched", function()
	press("labels") -- order -> type
	tool.cl.typeLabels = {}  -- as if these parts were selected after switching to type
	tool:client_onUpdate(0.3) tool:client_onUpdate(0.3) tool:client_onUpdate(0.3)
end)
check("type label fetched", labelFor(switch1) ~= nil and labelFor(switch1) ~= "...", tostring(labelFor(switch1)))
step("type labels back to order", function() for _ = 1, 3 do press("labels") end tool:client_onUpdate(0.3) end)
step("lines on", function() press("lines") tool:client_onUpdate(0.016) end)
check("line effects drawn", (function()
	local n = 0
	for _, e in ipairs(tool.cl.lines) do if e.playing then n = n + 1 end end
	return n > 0
end)())
step("box mode button", function() press("boxMode") press("boxMode") press("boxMode") press("boxMode") end)

-- delay probe: F + right click on a switch, again (reverse), again (off)
local function fRightClick(inter)
	lookAt(inter)
	tool:client_onEquippedUpdate(S.null, S.start, true)
end
step("probe forward", function() fRightClick(switch1) tool:client_onUpdate(0.016) end)
check("probe on", tool.cl.probe ~= nil and not tool.cl.probe.reverse)
check("probe text", result():find("DELAYS FROM", 1, true), result())
check("probe labels", #tool.cl.labelShown > 0, #tool.cl.labelShown)
check("probe start label", (function()
	for _, e in ipairs(tool.cl.probe.entries) do if e.text:find("start", 1, true) then return true end end
end)())
step("probe reverse", function() fRightClick(switch1) tool:client_onUpdate(0.016) end)
check("probe reversed", tool.cl.probe ~= nil and tool.cl.probe.reverse)
step("probe off", function() fRightClick(switch1) end)
check("probe cleared", tool.cl.probe == nil)
step("probe from light (reverse via button)", function() press("probeBack") tool:client_onUpdate(0.016) end)
check("probe buttons", tool.cl.probe ~= nil and result():find("DELAYS TO", 1, true), result())
step("probe nothing", function() fRightClick(nil) end)
check("probe off by empty", tool.cl.probe == nil)
check("right click without F still switches group", (function()
	local before = tool.cl.active
	lookAt(nil)
	rightClick()
	return tool.cl.active ~= before
end)())

-- pick filters
step("pick modes cycle", function() for _ = 1, 5 do press("pickBy") end end)
check("pick back to type+colour", tool.cl.pickMode == 1)
step("pick by mode", function()
	tool:cl_clearGroup("A")
	tool.cl.active = "A"
	press("pickBy") press("pickBy") press("pickBy") -- setting
	click(gates[2], true) -- mode 0; gates 2 and 4 are mode 0
end)
check("same mode picked", #tool.cl.groups.A == 2, #tool.cl.groups.A)
step("pick by colour", function()
	tool:cl_clearGroup("A")
	press("pickBy") press("pickBy") press("pickBy") -- settingColor, typeColor, type
	press("pickBy") -- colour
	click(gates[2], true)
end)
check("same colour picked", #tool.cl.groups.A >= 6, #tool.cl.groups.A)
step("pick reset", function() press("pickBy") press("pickBy") press("pickBy") press("pickBy") end)

-- module window: load A (inputs) > B (outputs) as a table
local function setGroup(g, list)
	tool.cl.groups[g] = {}
	for _, inter in ipairs(list) do tool.cl.groups[g][#tool.cl.groups[g] + 1] = { inter = inter, shape = inter.shape } end
end
local function moduleText() return (tool.cl.gui.texts.moduleInfo or "") .. "\n" .. (tool.cl.gui.texts.moduleTable or "") end
local function moduleInfo() return tool.cl.gui.texts.moduleInfo or "" end
step("module window opens with a hint", function() press("openModule") end)
check("LUT style starts on Auto", tool.cl.gui.texts.lutStyle == "Auto", tool.cl.gui.texts.lutStyle)
step("LUT style: ROM for the next tests", function() press("lutStyle") end)
check("LUT style ROM", tool.cl.gui.texts.lutStyle == "ROM", tool.cl.gui.texts.lutStyle)
check("module window shown", tool.cl.gui.visible.moduleWindow == true and tool.cl.gui.visible.scriptWindow == false
	and tool.cl.gui.texts.openModule == "Hide module")
check("module hint", moduleText():find("press Load", 1, true), moduleText())
step("module wiring: switch1 > gate3 (OR) > gate4 (AND), switch2 > gate4", function()
	SERVER = true
	for _, g in ipairs(gates) do
		for _, c in ipairs(g:getChildren()) do g:disconnect(c) end
		for _, p in ipairs(g:getParents()) do p:disconnect(g) end
	end
	for _, sw in ipairs({ switch1, switch2 }) do
		for _, c in ipairs(sw:getChildren()) do sw:disconnect(c) end
	end
	gates[3].ctrl.mode = 1
	gates[4].ctrl.mode = 0
	switch1:connect(gates[3])
	gates[3]:connect(gates[4])
	switch2:connect(gates[4])
	SERVER = false
	setGroup("A", { switch1, switch2 })
	setGroup("B", { gates[4] })
	press("loadModule")
end)
check("module loaded", tool.cl.module ~= nil and #tool.cl.module.inputs == 2 and #tool.cl.module.outputs == 1)
check("module inside", tool.cl.module and tool.cl.module.inside == 1, tool.cl.module and tool.cl.module.inside)
-- B1 = (A1 OR nothing) AND A2: only row 11 (address 3) is on
check("module table", tool.cl.module and table.concat(tool.cl.module.rows[4].outs) == "1"
	and table.concat(tool.cl.module.rows[2].outs) == "0", moduleText())
check("module text shows the table", moduleText():find("Inside now: 1 part", 1, true) and moduleText():find("11   |   ", 1, true), moduleText())
check("module plan shown", moduleInfo():find("As a LUT: 2 buffer(s) + 0 inverter(s)", 1, true) == nil
	and moduleInfo():find("As a LUT: ROM: 2 buffer(s) + 1 row AND(s) = 3 new gate(s), 3 ticks", 1, true), moduleInfo())
-- edit: row 00 now also turns B1 on (the game sends the whole text, colour codes and all)
step("edit table", function()
	local t = tool.cl.gui.texts.moduleTable
	local edited = t:gsub("\n00   |   #7070700", "\n00   |   1", 1)
	tool:cl_onModuleTableChanged("moduleTable", edited)
end)
check("edit read", tool.cl.moduleRows and table.concat(tool.cl.moduleRows[1].outs) == "1" and tool.cl.moduleError == nil,
	tool.cl.moduleError)
check("edit plan", moduleInfo():find("Table: edited", 1, true)
	and moduleInfo():find("2 buffer(s) + 2 inverter(s) + 2 row AND(s) = 6 new gate(s), 3 ticks", 1, true), moduleInfo())
step("settings change the plan", function() press("lutEven") press("lutCompress") end)
check("fewer gates + stacked", moduleInfo():find("2 inverter(s) + 2 row AND(s) = 4 new gate(s), 2-3 ticks, stacked in 2 block(s)", 1, true)
	and tool.cl.gui.texts.lutEven == "Fewer gates" and tool.cl.gui.texts.lutCompress == "Stacked", moduleInfo())
step("settings back", function() press("lutEven") press("lutCompress") end)
step("bad edit", function() tool:cl_onModuleTableChanged("moduleTable", "12 | 1 row\n00 | 1\n0 | 1") end)
check("bad edit says the line", moduleInfo():find("line 3: needs 2 input bit(s), has 1", 1, true), moduleInfo())
step("own table text is not an edit", function()
	press("resetModule")
	tool:cl_onModuleTableChanged("moduleTable", tool.cl.gui.texts.moduleTable)
end)
check("unchanged table = as loaded", tool.cl.moduleRows == nil and moduleInfo():find("Table: as loaded", 1, true), moduleInfo())
step("reset table", function() press("resetModule") end)
check("reset", tool.cl.moduleRows == nil and tool.cl.moduleError == nil and moduleInfo():find("Table: as loaded", 1, true), moduleInfo())
check("module types", moduleText():find("A0 Switch", 1, true) and moduleText():find("B0 AND", 1, true), moduleText())
step("module needs A and B", function() setGroup("B", {}) press("loadModule") end)
check("module error shown", moduleText():find("Load needs the inputs in A", 1, true), moduleText())
-- a part on another creation
local body2 = setmetatable({ id = 2, worldPosition = vec(5, 0, 0), worldRotation = quat(), shapes = {} }, Body)
body2.creation = { body2 }
step("module on two creations", function()
	local other = addPart(UUID_GATE, 20, 0, 0, { mode = 1 })
	other.shape.body = body2
	body2.shapes[1] = other.shape
	table.remove(body.shapes) -- addPart put it on body 1
	setGroup("B", { other })
	press("loadModule")
end)
check("module same creation", moduleText():find("same creation", 1, true), moduleText())
-- build: XOR table, preview, apply, check, undo
step("build: load switch1, switch2 > gate4", function()
	setGroup("A", { switch1, switch2 })
	setGroup("B", { gates[4] })
	press("loadModule")
	local t = tool.cl.gui.texts.moduleTable
	t = t:gsub("\n01   |   #7070700", "\n01   |   1", 1):gsub("\n10   |   #7070700", "\n10   |   1", 1):gsub("\n11   |   #ffffff1", "\n11   |   0", 1)
	tool:cl_onModuleTableChanged("moduleTable", t)
end)
check("build: table is XOR", tool.cl.moduleRows and table.concat({ tool.cl.moduleRows[1].outs[1], tool.cl.moduleRows[2].outs[1],
	tool.cl.moduleRows[3].outs[1], tool.cl.moduleRows[4].outs[1] }) == "0110", tool.cl.moduleError)
local shapesBefore = #body.shapes
-- the old gate also drives a lamp that isn't B: the old circuit stays whole
step("build: preview with the old circuit still in use", function()
	SERVER = true gates[3]:connect(light) SERVER = false
	press("buildLut")
end)
check("build: kept whole", (tool.cl.gui.texts.moduleInfo or ""):find("stays whole: it also drives 1 other part", 1, true)
	and tool.cl.flags[gates[3].id] ~= nil, tool.cl.gui.texts.moduleInfo)
step("build: cancel, unhook the lamp", function()
	press("cancelLut")
	SERVER = true gates[3]:disconnect(light) SERVER = false
end)
step("build: preview", function() press("buildLut") end)
-- even timing: 2 buffers + 2 inverters + 2 rows = 6 new, plus 2 A and 1 B targets
check("build: preview frames", tool.cl.lutPreview and #tool.cl.lutPreview.effects == 9, tool.cl.lutPreview and #tool.cl.lutPreview.effects)
check("build: gate3 marked for removal", tool.cl.flags[gates[3].id] ~= nil)
check("build: apply caption", tool.cl.gui.texts.buildLut == "Apply build")
check("build: nothing changed yet", #IMPORTS == 0 and not switch1.destroyed)
step("build: apply", function() press("buildLut") end)
check("build: check waits a moment", result():find("Checking", 1, true) and tool.cl.verify ~= nil, result())
step("build: half a second later", function() tool:client_onUpdate(0.3) tool:client_onUpdate(0.3) end)
check("build: imported", #IMPORTS == 1 and switch1.destroyed and gates[4].destroyed, #IMPORTS)
local newA1, newB1 = tool.cl.groups.A[1] and tool.cl.groups.A[1].inter, tool.cl.groups.B[1] and tool.cl.groups.B[1].inter
check("build: groups point at the new parts", newA1 and newA1 ~= switch1 and not newA1.destroyed and newB1 and newB1.ctrl.mode == 1)
check("build: B driven by 2 rows", newB1 and #newB1.parents == 2, newB1 and #newB1.parents)
check("build: old gate3 gone", (function()
	for _, s in ipairs(IMPORTS[1].shapes) do if s.interactable and s.interactable.ctrl.mode == 2 then return false end end
	return true
end)())
-- the parts sit at z = 0 on a block at z = -1, so the top layer is z = 1
check("build: A on top in a line along X", newA1 and newA1.shape.gz == 1 and tool.cl.groups.A[2].inter.shape.gx == newA1.shape.gx + 1
	and tool.cl.groups.A[2].inter.shape.gy == newA1.shape.gy, newA1 and (newA1.shape.gz .. "," .. newA1.shape.gx))
check("build: B further along Y", newB1 and newB1.shape.gy > newA1.shape.gy and newB1.shape.gx == newA1.shape.gx,
	newB1 and (newB1.shape.gx .. "," .. newB1.shape.gy))
check("build: checked against the table", result():find("matches your table", 1, true), result())
check("build: preview gone", tool.cl.lutPreview == nil and tool.cl.gui.texts.buildLut == "Build LUT")
check("build: check done", tool.cl.verify == nil and tool.cl.moduleRows == nil)
-- a reload that reads back wrong (e.g. wires not ready yet): retry quietly,
-- and in the end keep the player's table instead of the wrong one
local xor = tool.cl.module.rows
local zero = { kind = "lut", inputs = { "A1", "A2" }, outputs = { "B1" }, inside = 0, extraIn = 0, extraOut = 0,
	inputTypes = {}, outputTypes = {}, outputGates = { true },
	rows = { { outs = { 0 }, settled = true }, { outs = { 0 }, settled = true }, { outs = { 0 }, settled = true }, { outs = { 0 }, settled = true } } }
step("build: wrong reload retries", function()
	tool.cl.verify = { rows = xor, tries = 1 }
	tool:cl_onModule({ kind = "module", module = zero })
end)
check("build: retry scheduled, table untouched", tool.cl.verify and tool.cl.verify.wait == 1 and tool.cl.module.rows == xor)
step("build: still wrong after the last try", function()
	tool.cl.verify.tries = 3
	tool:cl_onModule({ kind = "module", module = zero })
end)
check("build: player's table kept", tool.cl.verify == nil and tool.cl.moduleRows == xor and result():find("Your table is kept", 1, true), result())
check("build: next build would use the kept table", (function()
	local rows = tool:cl_currentModule().rows
	return rows[2].outs[1] == 1 and rows[3].outs[1] == 1
end)())
step("build: undo", function() press("undoLut") end)
check("build: undo restores", #IMPORTS == 2 and newA1.destroyed and result():find("Build undone", 1, true), result())
check("build: undo brings back every old part", #IMPORTS[2].shapes == shapesBefore, #IMPORTS[2].shapes .. " vs " .. shapesBefore)
-- the same XOR table built in XOR style (PPRM), on the restored creation
step("build xor: load the restored switches > gate", function()
	local sw, g4 = {}, nil
	for _, sh in ipairs(IMPORTS[2].shapes) do
		if sh.interactable and tostring(sh.uuid) == UUID_SWITCH then sw[#sw + 1] = sh.interactable end
		if sh.interactable and sh.gx == 2 and sh.gy == 4 then g4 = sh.interactable end
	end
	table.sort(sw, function(a, b) return a.shape.gy < b.shape.gy end)
	setGroup("A", sw)
	setGroup("B", { g4 })
	press("lutStyle") -- ROM -> XOR
	press("loadModule")
	local t = tool.cl.gui.texts.moduleTable
	t = t:gsub("\n01   |   #7070700", "\n01   |   1", 1):gsub("\n10   |   #7070700", "\n10   |   1", 1):gsub("\n11   |   #ffffff1", "\n11   |   0", 1)
	tool:cl_onModuleTableChanged("moduleTable", t)
end)
check("build xor: style", tool.cl.gui.texts.lutStyle == "XOR (PPRM)" and moduleInfo():find("XOR (PPRM): 2 term AND(s) = 2 new gate(s), 2 ticks", 1, true), moduleInfo())
-- this one is on the player's lift: it must go back on it
step("build xor: lift it", function()
	IMPORTS[2].lifted = true
	LIFT = { worldPosition = vec(0.5, 0.75, 0.25), level = 3 }
end)
step("build xor: preview", function() press("buildLut") end)
check("build xor: preview says back on the lift", moduleInfo():find("goes back on the lift", 1, true), moduleInfo())
check("build xor: preview frames", tool.cl.lutPreview and #tool.cl.lutPreview.effects == 5, tool.cl.lutPreview and #tool.cl.lutPreview.effects)
step("build xor: apply and check", function() press("buildLut") tool:client_onUpdate(0.3) tool:client_onUpdate(0.3) end)
local xB = tool.cl.groups.B[1] and tool.cl.groups.B[1].inter
check("build xor: B is an XOR with 2 terms", xB and xB.ctrl.mode == 2 and #xB.parents == 2, xB and (tostring(xB.ctrl.mode) .. " " .. #xB.parents))
check("build xor: checked against the table", result():find("matches your table", 1, true), result())
check("build xor: back on the lift", #PLACED == 1 and PLACED[1].bodies[1] == IMPORTS[3] and PLACED[1].level == 3
	and PLACED[1].rot == 0 and PLACED[1].pos.z == 1, #PLACED .. " " .. tostring(PLACED[1] and PLACED[1].pos))
check("build xor: no stands-free note", (function()
	for _, c in ipairs(chats) do if c:find("stands free", 1, true) then return false end end
	return true
end)())
LIFT = nil
step("build xor: back to Auto", function() press("lutStyle") end)
check("build xor: Auto again", tool.cl.gui.texts.lutStyle == "Auto")
step("build: cancel", function()
	setGroup("A", {}) setGroup("B", {})
	press("buildLut") press("cancelLut")
end)
step("build: all-0 table warns in the preview", function()
	tool:cl_onLutPreview({ cells = {}, rot = quat(), remove = {}, kept = 0, gates = 0 })
end)
check("build: all-0 warning", (tool.cl.gui.texts.moduleInfo or ""):find("only removes the old logic", 1, true), tool.cl.gui.texts.moduleInfo)
step("build: cancel all-0", function() press("cancelLut") end)
step("module window closes", function() press("closeModule") end)
check("module window hidden", tool.cl.gui.visible.moduleWindow == false)

-- step debugger: sw -> g1 (OR) -> out (OR), all off in the game
step("debug setup", function()
	press("clearAll")
	-- its own creation (the first one was rebuilt by the LUT tests)
	local nb = setmetatable({ id = newId(), worldPosition = vec(0, 0, 0), worldRotation = quat(), shapes = {} }, Body)
	nb.creation = { nb }
	local sw = addPart(UUID_SWITCH, 10, 0, 0, nil, nil, nb)
	local g1 = addPart(UUID_GATE, 11, 0, 0, { mode = 1 }, nil, nb)
	local out = addPart(UUID_GATE, 12, 0, 0, { mode = 1 }, nil, nb)
	SERVER = true
	sw:connect(g1)
	g1:connect(out)
	SERVER = false
	DBG = { sw = sw, g1 = g1, out = out }
	tool:cl_add("A", sw, sw.shape)
	tool:cl_add("B", out, out.shape)
end)
step("debug window", function() press("openDebug") end)
check("debug window shown", tool.cl.gui.visible.debugWindow == true and tool.cl.gui.texts.openDebug == "Hide debug")
check("debug speed default", tool.cl.gui.texts.debugSpeed == "1 s per tick", tool.cl.gui.texts.debugSpeed)
step("debug from game", function() press("debugFromGame") end)
check("from game = 0", tool.cl.gui.texts.debugInputs == "0", tool.cl.gui.texts.debugInputs)
step("debug bad inputs", function() tool:cl_onDebugInputsChanged(nil, "12") press("debugStart") end)
check("bad inputs refused", tool.cl.debug == nil and tool.cl.gui.texts.debugInfo:find("only 0 and 1", 1, true))
step("debug start", function()
	tool.cl.gui:open()
	tool:cl_onDebugInputsChanged(nil, "1")
	press("debugStart")
end)
check("debug running", tool.cl.debug ~= nil and tool.cl.debug.view.tick == 0 and not tool.cl.gui:isActive())
check("tick 0 = the input", tool.cl.debug and #tool.cl.debug.view.changed == 1 and tool.cl.debug.view.changed[1].inter == DBG.sw)
step("debug hud", function() tool:client_onUpdate(0.016) end)
check("hud open", tool.cl.stepGui:isActive() and tool.cl.stepGui.texts.stepTick:find("Tick 0", 1, true), tool.cl.stepGui.texts.stepTick)
local function arrows()
	local n = 0
	for _, e in ipairs(tool.cl.lines) do if e.playing then n = n + 1 end end
	return n
end
check("arrow from A", arrows() == 2, arrows())
check("countdown labels", (function()
	local t = {}
	for _, e in ipairs(tool.cl.labelShown) do t[e.inter] = e.text end
	return t[DBG.g1] == "#40ff601t" and t[DBG.out] == "#ffffff2t" and t[DBG.sw] == nil
end)())
step("debug xor memory label", function()
	tool:cl_onDebug({ tick = 0, changed = {}, steady = {}, changedCount = 0, otherCount = 0, inputs = "1", outputs = "0",
		settled = false, glitches = {}, mems = { { inter = DBG.g1, on = true } }, next = { { inter = DBG.g1, n = 2 } } })
	tool:client_onUpdate(0.016)
end)
check("MEM label with countdown", (function()
	for _, e in ipairs(tool.cl.labelShown) do
		if e.inter == DBG.g1 then return e.text == "#d8b000MEM on #ffffff2t" end
	end
end)())
step("debug step", function() tool:client_onEquippedUpdate(S.start, S.null, false) tool:client_onUpdate(0.016) end)
check("tick 1 = g1", tool.cl.debug.view.tick == 1 and tool.cl.debug.view.changed[1].inter == DBG.g1 and tool.cl.debug.view.outputs == "0")
check("g1 > out bright, sw > g1 faint", arrows() == 4 and #tool.cl.debugFrames == 1, arrows())
step("debug step 2", function() tool:client_onEquippedUpdate(S.start, S.null, false) tool:client_onUpdate(0.016) end)
check("tick 2: B on, no arrow out of B, the rest faint", tool.cl.debug.view.outputs == "1" and arrows() == 4, arrows())
step("debug back", function() tool:client_onEquippedUpdate(S.null, S.start, false) end)
check("back to tick 1", tool.cl.debug.view.tick == 1 and tool.cl.debug.view.outputs == "0")
step("debug run", function()
	tool:client_onToggle()
	for _ = 1, 4 do tool:client_onUpdate(0.6) end
end)
check("run stops when settled", tool.cl.debug.view.settled and not tool.cl.debug.running and tool.cl.debug.view.tick == 3,
	tostring(tool.cl.debug.view.tick))
check("hud says settled", tool.cl.stepGui.texts.stepInfo:find("Settled", 1, true) and tool.cl.stepGui.texts.stepInfo:find("tick 2", 1, true),
	tool.cl.stepGui.texts.stepInfo)
step("debug unequip hides hud", function()
	tool.tool.isEquipped = function() return false end
	tool:client_onUpdate(0.016)
	tool.tool.isEquipped = function() return true end
end)
check("hud closed when unequipped", not tool.cl.stepGui:isActive())
step("debug stop (R)", function() tool:client_onUpdate(0.016) tool:client_onReload() end)
check("debug stopped", tool.cl.debug == nil and tool.cl.gui:isActive() and not tool.cl.stepGui:isActive()
	and tool.sv.debug[player.id] == nil and #tool.cl.debugFrames == 0)
step("debug repeat mode", function()
	tool:client_onReload()
	press("debugHold") press("debugHold") -- Held > 1 tick pulse > Pulse every N
	tool:cl_onDebugEveryChanged(nil, "x")
	tool:cl_onDebugInputsChanged(nil, "1")
	press("debugStart")
end)
check("repeat: bad N refused", tool.cl.debug == nil and tool.cl.gui.texts.debugInfo:find("whole number", 1, true))
step("debug repeat start", function()
	tool:cl_onDebugEveryChanged(nil, "2")
	press("debugStart")
	tool:client_onUpdate(0.016)
	for _ = 1, 4 do tool:client_onEquippedUpdate(S.start, S.null, false) end
end)
check("repeat: sw pulses on even ticks", tool.cl.debug and tool.cl.debug.view.tick == 4 and tool.cl.debug.view.inputs == "1"
	and tool.sv.debug[player.id].every == 2 and not tool.cl.debug.view.settled)
step("debug repeat stop", function()
	tool:client_onReload()
	press("debugHold") press("debugHold") -- back to Held
end)
step("debug same inputs", function()
	tool:cl_onDebugInputsChanged(nil, "0")
	press("debugStart")
	tool:client_onUpdate(0.016)
end)
check("same inputs: nothing changes", tool.cl.stepGui.texts.stepInfo:find("Nothing changes", 1, true), tool.cl.stepGui.texts.stepInfo)
step("debug stop again", function() tool:client_onReload() tool.cl.gui:close() press("closeDebug") end)

-- destroyed part is pruned
step("prune", function()
	gates[1].destroyed = true
	gates[1].shape.destroyed = true
	tool:client_onUpdate(0.016)
end)
step("clear marks/all", function() press("clearMarks") press("clearAll") end)
check("all clear", #tool.cl.groups.A == 0 and #tool.cl.groups.B == 0 and #tool.cl.groups.C == 0)
step("unequip", function() tool:client_onUnequip() end)
check("hidden after unequip", (function()
	for _, g in ipairs({ "A", "B", "C" }) do
		for _, e in pairs(tool.cl.markers[g]) do if e.playing then return false end end
	end
	for _, e in ipairs(tool.cl.lines) do if e.playing then return false end end
	return true
end)())
step("update while unequipped", function()
	tool.tool.isEquipped = function() return false end
	tool:client_onUpdate(0.016)
end)
step("destroy", function() tool:client_onDestroy() end)

print(string.format("smoke: %d failure(s); %d alerts, %d effects", failures, #alerts, #effects))
return failures
