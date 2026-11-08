-- LogicModule: a piece of logic seen only through its inputs and outputs.
--
-- A module is loaded from the tool's groups: A = inputs, B = outputs, in
-- group order. The parts in between are its insides. Step 1 only reads a
-- module (its truth table); later steps rebuild it as a LUT and nest modules.
--
-- Pure Lua, no game API, so it can be tested offline.
--
-- Module table:
--   kind      "lut"
--   inputs    { "A1", "A2", ... }      names, in group order
--   outputs   { "B1", ... }
--   rows      rows[address + 1] = { outs = { 0/1, ... }, settled = bool }
--             address = the inputs as a binary number with A1 the LOW bit
--             (A1 = 1, A2 = 2, A3 = 4 ...); outs[k] is output Bk. The table
--             shows bits like a binary number: highest on the left, A1 and
--             B1 on the right.
--   inside    number of parts between inputs and outputs
--   extraIn   number of outside parts that feed the insides (not via A)
--   extraOut  number of inside parts that also drive something outside B

LogicModule = {}

LogicModule.MAX_INPUTS = 8   -- 256 rows; enough for a LUT/ROM to start with

-- Parts between `inputs` and `outputs` (lists of graph ids): reachable
-- forward from an input AND backward from an output. Also finds where the
-- module leaks: outside parts feeding in, inside parts feeding out.
function LogicModule.inside(graph, inputs, outputs)
	local isIn, isOut = {}, {}
	for _, id in ipairs(inputs) do isIn[id] = true end
	for _, id in ipairs(outputs) do isOut[id] = true end

	local function reach(starts, field)
		local seen, queue = {}, {}
		for _, id in ipairs(starts) do
			if graph[id] and not seen[id] then seen[id] = true queue[#queue + 1] = id end
		end
		local i = 1
		while i <= #queue do
			local u = queue[i]
			i = i + 1
			for _, v in ipairs(graph[u][field]) do
				if graph[v] and not seen[v] then seen[v] = true queue[#queue + 1] = v end
			end
		end
		return seen
	end
	local fwd = reach(inputs, "children")
	local back = reach(outputs, "parents")

	local parts, isInside = {}, {}
	for id in pairs(fwd) do
		if back[id] and not isIn[id] and not isOut[id] then
			parts[#parts + 1] = id
			isInside[id] = true
		end
	end
	table.sort(parts)

	-- leaks: who feeds the insides/outputs from outside, and which insides
	-- also drive something that isn't part of the module
	local extraIn, extraOut, seenIn = {}, {}, {}
	local function checkParents(id)
		for _, p in ipairs(graph[id].parents) do
			if not isInside[p] and not isIn[p] and not seenIn[p] then
				seenIn[p] = true
				extraIn[#extraIn + 1] = p
			end
		end
	end
	for _, id in ipairs(parts) do
		checkParents(id)
		for _, c in ipairs(graph[id].children) do
			if not isInside[c] and not isOut[c] then
				extraOut[#extraOut + 1] = id
				break
			end
		end
	end
	for _, id in ipairs(outputs) do
		if graph[id] then checkParents(id) end
	end
	table.sort(extraIn)
	return { parts = parts, extraIn = extraIn, extraOut = extraOut }
end

-- Builds a module from LogicGraph.truthTable rows (input 1 = low bit there too).
function LogicModule.fromTruth(truthRows, nIn, nOut)
	local m = { kind = "lut", inputs = {}, outputs = {}, rows = {} }
	for k = 1, nIn do m.inputs[k] = "A" .. k end
	for k = 1, nOut do m.outputs[k] = "B" .. k end
	for _, row in ipairs(truthRows) do
		local address = 0
		for k = 1, nIn do
			if row.ins[k] then address = address + 2 ^ (k - 1) end
		end
		local outs = {}
		for k = 1, nOut do outs[k] = row.outs[k] and 1 or 0 end
		m.rows[address + 1] = { outs = outs, settled = row.settled ~= false }
	end
	return m
end

-- Input bits of a row: bits[k] is input Ak (A1 = the low bit).
function LogicModule.addressBits(m, address)
	local bits = {}
	for k = 1, #m.inputs do bits[k] = math.floor(address / 2 ^ (k - 1)) % 2 end
	return bits
end

-- bits[k] written highest first, like a binary number: { A1, A2, A3 } -> "A3A2A1"
local function binary(bits)
	local s = {}
	for k = #bits, 1, -1 do s[#s + 1] = tostring(bits[k]) end
	return table.concat(s)
end

-- What a LUT for this module would cost: one inverter per input, one AND
-- per row that turns any output on, one OR per output.
function LogicModule.lutSize(m)
	local used = 0
	for _, row in ipairs(m.rows) do
		for _, v in ipairs(row.outs) do
			if v == 1 then used = used + 1 break end
		end
	end
	return { inverters = #m.inputs, rows = used, outputs = #m.outputs,
		total = #m.inputs + used + #m.outputs }
end

local function hex(c) return c and ("#" .. c) or "" end

-- The table as text for the module window. The game has no monospace font,
-- so the columns are digits only (digits are all the same width): the
-- header is the input/output numbers, coloured like the groups.
-- opts.colors = { A = "ff9900", B = "00c8ff", one = "ffffff", zero = "707070", text = "ffffff" }
function LogicModule.tableText(m, opts)
	local c = (opts and opts.colors) or {}
	local reset = hex(c.text)
	local nIn, nOut = #m.inputs, #m.outputs
	local lines = {}

	local function digits(n)
		local s = {}
		for k = n, 1, -1 do s[#s + 1] = tostring(k % 10) end
		return table.concat(s)
	end
	lines[1] = hex(c.A) .. digits(nIn) .. reset .. "   |   " .. hex(c.B) .. digits(nOut) .. reset .. "      row"

	local unsettled = 0
	for address = 0, #m.rows - 1 do
		local row = m.rows[address + 1]
		local ins = binary(LogicModule.addressBits(m, address))
		local outs = {}
		local last
		for k = #row.outs, 1, -1 do
			local v = row.outs[k]
			-- only switch colour when the bit changes, to keep the text short
			local want = v == 1 and c.one or c.zero
			if want ~= last then outs[#outs + 1] = hex(want) last = want end
			outs[#outs + 1] = tostring(v)
		end
		local line = ins .. "   |   " .. table.concat(outs) .. reset .. "      " .. address
		if not row.settled then
			line = line .. "  (never settles)"
			unsettled = unsettled + 1
		end
		lines[#lines + 1] = line
	end
	return table.concat(lines, "\n"), unsettled
end

---------------------------------------------------------------------------
-- Editing: read the table back from the window
---------------------------------------------------------------------------

-- Parses the table text (as LogicModule.tableText writes it, possibly edited)
-- into rows for module `m`. Lines without "|" and the header line ("row")
-- are skipped; rows that are not listed count as all 0.
-- Returns rows, { listed = n, missing = n }  or  nil, lineNumber, message.
function LogicModule.parseTable(m, text)
	local n, nOut = #m.inputs, #m.outputs
	text = text:gsub("#%x%x%x%x%x%x", "")
	local rows, seen = {}, {}
	local listed, lineNo = 0, 0
	for line in (text .. "\n"):gmatch("(.-)\r?\n") do
		lineNo = lineNo + 1
		if line:find("|", 1, true) and not line:find("row", 1, true) then
			local ins, outs = line:match("^%s*([01]+)%s*|%s*([01]+)")
			if not ins then
				return nil, lineNo, "write a row as input bits | output bits, e.g. 01 | 10"
			end
			if #ins ~= n then
				return nil, lineNo, string.format("needs %d input bit(s), has %d", n, #ins)
			end
			if #outs ~= nOut then
				return nil, lineNo, string.format("needs %d output bit(s), has %d", nOut, #outs)
			end
			local address = tonumber(ins, 2)
			if seen[address] then
				return nil, lineNo, "row " .. ins .. " is listed twice"
			end
			seen[address] = true
			-- written highest first: the last digit is B1
			local o = {}
			for k = 1, nOut do o[k] = tonumber(outs:sub(nOut - k + 1, nOut - k + 1)) end
			rows[address + 1] = { outs = o, settled = true }
			listed = listed + 1
		end
	end
	local total = 2 ^ n
	for address = 0, total - 1 do
		if not rows[address + 1] then
			local o = {}
			for k = 1, nOut do o[k] = 0 end
			rows[address + 1] = { outs = o, settled = true }
		end
	end
	return rows, { listed = listed, missing = total - listed }
end

-- True when two row lists have the same outputs.
function LogicModule.sameRows(a, b)
	if #a ~= #b then return false end
	for i = 1, #a do
		local x, y = a[i].outs, b[i].outs
		if #x ~= #y then return false end
		for k = 1, #x do if x[k] ~= y[k] then return false end end
	end
	return true
end

-- A copy of `m` with other rows (the edited table).
function LogicModule.withRows(m, rows)
	local c = {}
	for k, v in pairs(m) do c[k] = v end
	c.rows = rows
	return c
end

---------------------------------------------------------------------------
-- LUT plan: which gates to build, where, and how they are wired
---------------------------------------------------------------------------

LogicModule.MODE = { AND = 0, OR = 1, NOR = 4 }
LogicModule.WRAP = 16   -- a column longer than this continues one layer up

-- Builds the plan for module `m` as a LUT. Only data: the server turns it
-- into real parts later. Coordinates are the module's own grid, in blocks:
-- x = column (A, input gates, rows, outputs), y = along the column, z = layer.
--
-- opts.even     (default true) every input gets a buffer as well as an
--               inverter, so every path is 3 ticks and rows can't glitch
-- opts.compress stack each gate column in one block
-- opts.bIsGate  { bool per output }: a gate B becomes the OR itself; any
--               other B (lamp, ...) gets an OR gate in front of it
--
-- plan.parts = { { ref, mode, x, y, z } }         new gates
-- plan.moves = { { ref = "A1", x, y, z } }        existing A/B parts, moved
-- plan.modes = { ["B1"] = mode }                  existing B gates, new mode
-- plan.wires = { { from = ref, to = ref } }
-- plan.counts, plan.ticks
function LogicModule.lutPlan(m, opts)
	opts = opts or {}
	local even = opts.even ~= false
	local compress = opts.compress == true
	local bIsGate = opts.bIsGate or {}
	local MODE = LogicModule.MODE
	local n, nOut = #m.inputs, #m.outputs
	local plan = { parts = {}, moves = {}, modes = {}, wires = {},
		counts = { buffers = 0, inverters = 0, rows = 0, ors = 0, gates = 0 } }

	local function pos(column, i, stack)
		if stack then return column, 0, 0 end
		local w = LogicModule.WRAP
		return column, (i - 1) % w, math.floor((i - 1) / w)
	end
	local function addPart(ref, mode, column, i, kind)
		local x, y, z = pos(column, i, compress)
		plan.parts[#plan.parts + 1] = { ref = ref, mode = mode, x = x, y = y, z = z }
		plan.counts[kind] = plan.counts[kind] + 1
		plan.counts.gates = plan.counts.gates + 1
	end
	local function wire(from, to) plan.wires[#plan.wires + 1] = { from = from, to = to } end

	-- rows that turn any output on, and which input polarities they use
	local used, needOn, needOff = {}, {}, {}
	for address = 0, #m.rows - 1 do
		for _, v in ipairs(m.rows[address + 1].outs) do
			if v == 1 then
				used[#used + 1] = address
				local bits = LogicModule.addressBits(m, address)
				for k = 1, n do
					if bits[k] == 1 then needOn[k] = true else needOff[k] = true end
				end
				break
			end
		end
	end

	-- column 0: the inputs, in a line
	for k = 1, n do
		local x, y, z = pos(0, k, false)
		plan.moves[#plan.moves + 1] = { ref = "A" .. k, x = x, y = y, z = z }
	end

	-- column 1: buffer (OR) and inverter (NOR) per input, as needed
	local onSrc, offSrc = {}, {}
	local i = 0
	for k = 1, n do
		onSrc[k] = "A" .. k
		if needOn[k] and even then
			i = i + 1
			addPart("buf" .. k, MODE.OR, 1, i, "buffers")
			wire("A" .. k, "buf" .. k)
			onSrc[k] = "buf" .. k
		end
		if needOff[k] then
			i = i + 1
			addPart("inv" .. k, MODE.NOR, 1, i, "inverters")
			wire("A" .. k, "inv" .. k)
			offSrc[k] = "inv" .. k
		end
	end

	-- column 2: one AND per used row
	for r, address in ipairs(used) do
		local ref = "row" .. address
		addPart(ref, MODE.AND, 2, r, "rows")
		local bits = LogicModule.addressBits(m, address)
		for k = 1, n do wire(bits[k] == 1 and onSrc[k] or offSrc[k], ref) end
	end

	-- column 3 (and 4): outputs. A gate B is the OR; any other B gets one.
	local anyPart = false
	for j = 1, nOut do if not bIsGate[j] then anyPart = true end end
	local bColumn = anyPart and 4 or 3
	local orCount = 0
	for j = 1, nOut do
		local b = "B" .. j
		local x, y, z = pos(bColumn, j, false)
		plan.moves[#plan.moves + 1] = { ref = b, x = x, y = y, z = z }
		local target = b
		if bIsGate[j] then
			plan.modes[b] = MODE.OR
		else
			orCount = orCount + 1
			target = "or" .. j
			addPart(target, MODE.OR, 3, orCount, "ors")
			wire(target, b)
		end
		for _, address in ipairs(used) do
			if m.rows[address + 1].outs[j] == 1 then wire("row" .. address, target) end
		end
	end

	-- ticks from an input changing to the B gate (or the OR before B)
	-- (without buffers a direct input is 2 ticks and an inverted one 3)
	local inverted, direct = next(needOff) ~= nil, next(needOn) ~= nil
	if even or not direct then
		plan.ticks = 3
	elseif inverted then
		plan.ticks = "2-3"
	else
		plan.ticks = 2
	end
	-- blocks used by the new gates when stacked: one per gate column
	local columns = {}
	for _, p in ipairs(plan.parts) do columns[p.x] = true end
	plan.columns = 0
	for _ in pairs(columns) do plan.columns = plan.columns + 1 end
	return plan
end

-- One line describing a plan, for the module window.
function LogicModule.planText(plan, compress)
	local c = plan.counts
	local parts = {}
	if c.buffers > 0 then parts[#parts + 1] = c.buffers .. " buffer(s)" end
	if c.inverters > 0 then parts[#parts + 1] = c.inverters .. " inverter(s)" end
	parts[#parts + 1] = c.rows .. " row AND(s)"
	if c.ors > 0 then parts[#parts + 1] = c.ors .. " OR(s) for non-gate outputs" end
	local where = compress and string.format(", stacked in %d block(s)", plan.columns) or ""
	return string.format("%s = %d new gate(s), %s ticks%s", table.concat(parts, " + "), c.gates, tostring(plan.ticks), where)
end

---------------------------------------------------------------------------
-- Building: write a LUT plan into a blueprint table
-- (the format of sm.creation.exportToTable / blueprint.json)
---------------------------------------------------------------------------

LogicModule.GATE_UUID = "9f0f56e8-2c31-4d83-996c-d00a9b296c3f"
LogicModule.GATE_COLOR = "df7f00"

-- blueprint axis number (1 = x, 2 = y, 3 = z, negative = backwards) as a vector
local function axisVec(a)
	local v = { 0, 0, 0 }
	v[math.abs(a)] = a < 0 and -1 or 1
	return v
end

-- The block cell a blueprint child sits in (its lowest corner), for parts one
-- block big. "pos" is the corner the part grows from along its own axes, so
-- an axis pointing backwards puts the part one block lower on that axis.
function LogicModule.cellOf(child)
	local p = child.pos
	local c = { p.x, p.y, p.z }
	if child.bounds then return c end -- blocks: pos is already the low corner
	local X, Z = axisVec(child.xaxis or 1), axisVec(child.zaxis or 3)
	local Y = { Z[2] * X[3] - Z[3] * X[2], Z[3] * X[1] - Z[1] * X[3], Z[1] * X[2] - Z[2] * X[1] }
	for _, v in ipairs({ X, Y, Z }) do
		for i = 1, 3 do
			if v[i] < 0 then c[i] = c[i] - 1 end
		end
	end
	return c
end

-- The "pos" that puts a one-block part with these axes in `cell` (the
-- reverse of cellOf).
function LogicModule.posFor(cell, xaxis, zaxis)
	local probe = LogicModule.cellOf({ pos = { x = 0, y = 0, z = 0 }, xaxis = xaxis, zaxis = zaxis })
	return { x = cell[1] - probe[1], y = cell[2] - probe[2], z = cell[3] - probe[3] }
end

-- Low and high corner cells of everything in one blueprint body.
function LogicModule.bodyBounds(bpBody)
	local lo, hi
	for _, child in ipairs(bpBody.childs or {}) do
		local c = LogicModule.cellOf(child)
		local size = child.bounds and { child.bounds.x, child.bounds.y, child.bounds.z } or { 1, 1, 1 }
		if not lo then lo, hi = { c[1], c[2], c[3] }, { c[1], c[2], c[3] } end
		for i = 1, 3 do
			lo[i] = math.min(lo[i], c[i])
			hi[i] = math.max(hi[i], c[i] + size[i] - 1)
		end
	end
	return lo or { 0, 0, 0 }, hi or { 0, 0, 0 }
end

-- A plan cell (x = column, y = along the column, z = layer) as a cell in the
-- creation, from `origin`. The module runs along the creation's Y axis
-- (A, inputs, rows, B one after another in +Y) and each column along X.
function LogicModule.toBody(origin, x, y, z)
	return { origin[1] + y, origin[2] + x, origin[3] + z }
end

-- Where a module goes: on top of the body, from its low x/y corner.
function LogicModule.placeOnTop(bpBody)
	local lo, hi = LogicModule.bodyBounds(bpBody)
	return { lo[1], lo[2], hi[3] + 1 }
end

local function removeIds(list, ids)
	if not list then return nil end
	local out = {}
	for _, c in ipairs(list) do
		if not ids[c.id] then out[#out + 1] = c end
	end
	return out
end

-- Edits blueprint `bp` in place so it holds the LUT from `plan`.
-- refs.A / refs.B = blueprint childs of the module's inputs/outputs (all in
-- bp.bodies[refs.body]); refs.remove = set of childs to delete (the old logic
-- between A and B). origin = cell of the module's (0,0,0) in that body.
-- Every wire into B is cut first: B gets only the LUT's wires.
-- New gates are turned like the module's own parts: like the first gate in B
-- (the same part, so they look the same), else like A1.
-- Returns { [ref] = child } for A1.., B1.., and every new gate.
function LogicModule.applyLut(bp, plan, refs, origin)
	local home = bp.bodies[refs.body]
	local childOf = {}
	local bIds, removeId = {}, {}
	for k, child in ipairs(refs.A) do childOf["A" .. k] = child end
	for k, child in ipairs(refs.B) do
		childOf["B" .. k] = child
		bIds[child.controller.id] = true
	end
	for child in pairs(refs.remove or {}) do removeId[child.controller.id] = true end

	-- delete the old logic, every wire to it, and every wire into B
	local maxId = 0
	for _, body in ipairs(bp.bodies) do
		local keep = {}
		for _, child in ipairs(body.childs or {}) do
			local ctrl = child.controller
			if not (ctrl and removeId[ctrl.id]) then
				keep[#keep + 1] = child
				if ctrl then
					if ctrl.id and ctrl.id > maxId then maxId = ctrl.id end
					ctrl.controllers = removeIds(removeIds(ctrl.controllers, removeId), bIds)
				end
			end
		end
		body.childs = keep
	end

	-- joints (bearings, pistons) can have controllers too: new ids go above all
	for _, j in ipairs(bp.joints or {}) do
		if type(j.id) == "number" and j.id > maxId then maxId = j.id end
		if j.controller and type(j.controller.id) == "number" and j.controller.id > maxId then maxId = j.controller.id end
	end

	-- B gates become the ORs
	for ref, mode in pairs(plan.modes) do childOf[ref].controller.mode = mode end

	-- move A and B into their lines
	for _, mv in ipairs(plan.moves) do
		local child = childOf[mv.ref]
		local cell = LogicModule.cellOf(child)
		local target = LogicModule.toBody(origin, mv.x, mv.y, mv.z)
		child.pos = {
			x = child.pos.x + target[1] - cell[1],
			y = child.pos.y + target[2] - cell[2],
			z = child.pos.z + target[3] - cell[3],
		}
	end

	-- new gates, turned like the module's parts
	local turn = refs.A[1]
	for _, child in ipairs(refs.B) do
		if child.shapeId == LogicModule.GATE_UUID then turn = child break end
	end
	local xaxis, zaxis = turn.xaxis or 1, turn.zaxis or 3
	if turn.bounds then xaxis, zaxis = 1, 3 end
	for _, p in ipairs(plan.parts) do
		maxId = maxId + 1
		local child = {
			color = LogicModule.GATE_COLOR,
			shapeId = LogicModule.GATE_UUID,
			pos = LogicModule.posFor(LogicModule.toBody(origin, p.x, p.y, p.z), xaxis, zaxis),
			xaxis = xaxis, zaxis = zaxis,
			controller = { active = false, id = maxId, mode = p.mode },
		}
		home.childs[#home.childs + 1] = child
		childOf[p.ref] = child
	end

	-- wires
	for _, w in ipairs(plan.wires) do
		local from, to = childOf[w.from].controller, childOf[w.to].controller
		from.controllers = from.controllers or {}
		from.controllers[#from.controllers + 1] = { id = to.id }
	end
	-- the game writes an unwired part as "controllers": null, so leave empty lists out
	for _, body in ipairs(bp.bodies) do
		for _, child in ipairs(body.childs) do
			local ctrl = child.controller
			if ctrl and ctrl.controllers and #ctrl.controllers == 0 then ctrl.controllers = nil end
		end
	end
	return childOf
end

-- Which inside parts can go: the ones that only feed other removable parts
-- or B. A part that also drives something outside stays, and so does
-- everything inside that feeds it.
function LogicModule.removable(graph, inside, outputs)
	local isInside, isOut = {}, {}
	for _, id in ipairs(inside.parts) do isInside[id] = true end
	for _, id in ipairs(outputs) do isOut[id] = true end
	local keep, queue = {}, {}
	for _, id in ipairs(inside.extraOut) do
		if not keep[id] then keep[id] = true queue[#queue + 1] = id end
	end
	local i = 1
	while i <= #queue do
		local u = queue[i]
		i = i + 1
		for _, p in ipairs(graph[u].parents) do
			if isInside[p] and not keep[p] then keep[p] = true queue[#queue + 1] = p end
		end
	end
	local out = {}
	for _, id in ipairs(inside.parts) do
		if not keep[id] then out[#out + 1] = id end
	end
	return out, keep
end
