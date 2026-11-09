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
--   inputs    { "A0", "A1", ... }      names, in group order (shown from 0)
--   outputs   { "B0", ... }
--   rows      rows[address + 1] = { outs = { 0/1, ... }, settled = bool }
--             address = the inputs as a binary number with the first input
--             (A0) the LOW bit: A0 = 1, A1 = 2, A2 = 4 ...; outs[k] is the
--             k-th output. The table shows bits like a binary number:
--             highest on the left, A0 and B0 on the right.
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
	for k = 1, nIn do m.inputs[k] = "A" .. (k - 1) end
	for k = 1, nOut do m.outputs[k] = "B" .. (k - 1) end
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

-- Input bits of a row: bits[k] is the k-th input (the first = the low bit).
function LogicModule.addressBits(m, address)
	local bits = {}
	for k = 1, #m.inputs do bits[k] = math.floor(address / 2 ^ (k - 1)) % 2 end
	return bits
end

-- bits[k] written highest first, like a binary number: { A0, A1, A2 } -> "A2A1A0"
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
		for k = n, 1, -1 do s[#s + 1] = tostring((k - 1) % 10) end
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
			-- written highest first: the last digit is B0
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

LogicModule.MODE = { AND = 0, OR = 1, XOR = 2, NOR = 4, XNOR = 5 }
LogicModule.WRAP = 16   -- a column longer than this continues one layer up
LogicModule.MAX_WIRES = 255  -- the game's limit on a part's inputs, and on its outputs

local function hasBit(a, b) return math.floor(a / 2 ^ b) % 2 == 1 end

-- A plan for module `m`: which gates to build, where, and how they are
-- wired. Only data: the server turns it into real parts later. Coordinates
-- are the module's own grid, in blocks: x = column (A, gates..., B),
-- y = along the column, z = layer.
--
-- opts.style    "rom" (default), "xor" or "auto" (whichever needs fewer gates)
-- opts.even     (default true) every path gets the same number of ticks, so
--               nothing can glitch; false saves gates
-- opts.compress stack each gate column in one block
-- opts.bIsGate  { bool per output }: a gate B becomes the output gate itself;
--               any other B (lamp, ...) gets a gate in front of it
--
-- plan.style    "rom" or "xor" (what was built; "auto" picks one)
-- plan.parts = { { ref, mode, x, y, z } }         new gates
-- plan.moves = { { ref = "A1", x, y, z } }        existing A/B parts, moved
-- plan.modes = { ["B1"] = mode }                  existing B gates, new mode
-- plan.wires = { { from = ref, to = ref } }
-- plan.counts, plan.ticks, plan.columns
-- plan.problems = { "..." }  reasons it can't be built as it is (empty = fine)
--
-- ROM: a decoder and an OR plane. One inverter per input (and a buffer, for
-- even timing), one AND per row that turns an output on, B = OR of its rows.
-- XOR: positive-polarity Reed-Muller (PPRM). Each output is the XOR of AND
-- terms of plain inputs (no inverters); a constant 1 term makes it XNOR.
-- A game XOR gate with many inputs is parity, so it is one gate per output.
local romPlan, xorPlan

-- Fastest and slowest ticks from an input changing to an output showing it:
-- every gate on the way takes 1 tick (a B gate too), A and a non-gate B 0.
local function planTicks(plan)
	local parents = {}
	for _, w in ipairs(plan.wires) do
		parents[w.to] = parents[w.to] or {}
		table.insert(parents[w.to], w.from)
	end
	local memo = {}
	local function arrive(ref)
		if memo[ref] then return memo[ref][1], memo[ref][2] end
		if ref:match("^A%d+$") then return 0, 0 end
		local own = 1
		local k = ref:match("^B(%d+)$")
		if k and not plan.bIsGate[tonumber(k)] then own = 0 end
		local lo, hi
		for _, p in ipairs(parents[ref] or {}) do
			local a, b = arrive(p)
			if a then
				lo = lo and math.min(lo, a) or a
				hi = hi and math.max(hi, b) or b
			end
		end
		if lo then memo[ref] = { lo + own, hi + own } else memo[ref] = {} end
		return memo[ref][1], memo[ref][2]
	end
	local lo, hi
	for j = 1, plan.nOut do
		local a, b = arrive("B" .. j)
		if a then
			lo = lo and math.min(lo, a) or a
			hi = hi and math.max(hi, b) or b
		end
	end
	if not lo then return 0 end
	return lo == hi and lo or (lo .. "-" .. hi)
end

local function finishPlan(plan)
	plan.ticks = planTicks(plan)
	-- blocks used by the new gates when stacked: one per gate column
	local columns = {}
	for _, p in ipairs(plan.parts) do columns[p.x] = true end
	plan.columns = 0
	for _ in pairs(columns) do plan.columns = plan.columns + 1 end
	-- the game's wire limits, for the wires this plan adds
	local fanIn, fanOut = {}, {}
	for _, w in ipairs(plan.wires) do
		fanIn[w.to] = (fanIn[w.to] or 0) + 1
		fanOut[w.from] = (fanOut[w.from] or 0) + 1
	end
	for ref, n in pairs(fanIn) do
		if n > LogicModule.MAX_WIRES then
			plan.problems[#plan.problems + 1] = string.format("%s would get %d inputs (the game allows %d)",
				LogicModule.refName(ref), n, LogicModule.MAX_WIRES)
		end
	end
	for ref, n in pairs(fanOut) do
		if n > LogicModule.MAX_WIRES then
			plan.problems[#plan.problems + 1] = string.format("%s would drive %d parts (the game allows %d)",
				LogicModule.refName(ref), n, LogicModule.MAX_WIRES)
		end
	end
	table.sort(plan.problems)
	return plan
end

-- A plan ref as the player knows it: "A1" (the first input) is shown as A0.
function LogicModule.refName(ref)
	local kind, k = ref:match("^(%a+)(%d+)$")
	k = tonumber(k)
	if kind == "A" or kind == "B" then return kind .. (k - 1) end
	if kind == "buf" then return "A" .. (k - 1) .. "'s buffer" end
	if kind == "inv" then return "A" .. (k - 1) .. "'s inverter" end
	if kind == "row" then return "row " .. k .. "'s AND" end
	if kind == "term" then return "term " .. k .. "'s AND" end
	if kind == "or" then return "B" .. (k - 1) .. "'s OR" end
	if kind == "xo" then return "B" .. (k - 1) .. "'s XOR" end
	return ref
end

function LogicModule.lutPlan(m, opts)
	opts = opts or {}
	local style = opts.style or "rom"
	if style == "rom" then return finishPlan(romPlan(m, opts)) end
	if style == "xor" then return finishPlan(xorPlan(m, opts)) end
	-- auto: whichever can be built with fewer gates (a tie goes to XOR: 2 ticks)
	local rom, xor = finishPlan(romPlan(m, opts)), finishPlan(xorPlan(m, opts))
	local pick
	if #xor.problems > 0 and #rom.problems == 0 then
		pick = rom
	elseif #rom.problems > 0 and #xor.problems == 0 then
		pick = xor
	else
		pick = xor.counts.gates <= rom.counts.gates and xor or rom
	end
	pick.auto = { rom = rom.counts.gates, xor = xor.counts.gates }
	return pick
end

function romPlan(m, opts)
	local even = opts.even ~= false
	local compress = opts.compress == true
	local bIsGate = opts.bIsGate or {}
	local MODE = LogicModule.MODE
	local n, nOut = #m.inputs, #m.outputs
	local plan = { style = "rom", bIsGate = opts.bIsGate or {}, nOut = #m.outputs, parts = {}, moves = {}, modes = {}, wires = {}, problems = {},
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
	-- A non-gate B (lamp ...) needs an OR in front only for 2+ rows, or for
	-- 1 row with even timing (the OR keeps every path the same length). A B
	-- that is never on needs nothing: with no input it stays off.
	local rowsFor, needGate, anyPart = {}, {}, false
	for j = 1, nOut do
		local list = {}
		for _, address in ipairs(used) do
			if m.rows[address + 1].outs[j] == 1 then list[#list + 1] = "row" .. address end
		end
		rowsFor[j] = list
		needGate[j] = not bIsGate[j] and (#list >= 2 or (#list == 1 and even))
		if needGate[j] then anyPart = true end
	end
	local bColumn = anyPart and 4 or 3
	local orCount = 0
	for j = 1, nOut do
		local b = "B" .. j
		local x, y, z = pos(bColumn, j, false)
		plan.moves[#plan.moves + 1] = { ref = b, x = x, y = y, z = z }
		local target = b
		if bIsGate[j] then
			plan.modes[b] = MODE.OR
		elseif needGate[j] then
			orCount = orCount + 1
			target = "or" .. j
			addPart(target, MODE.OR, 3, orCount, "ors")
			wire(target, b)
		end
		for _, src in ipairs(rowsFor[j]) do wire(src, target) end
	end
	return plan
end

-- PPRM coefficients of every output: coef[j][address + 1] = 1 when the AND
-- of the inputs set in `address` is one of output j's XOR terms (address 0 =
-- the constant 1). The usual in-place transform over the truth table.
function LogicModule.pprm(m)
	local n, size = #m.inputs, #m.rows
	local coef = {}
	for j = 1, #m.outputs do
		local f = {}
		for a = 0, size - 1 do f[a] = m.rows[a + 1].outs[j] end
		for b = 0, n - 1 do
			for a = 0, size - 1 do
				if hasBit(a, b) then
					local lower = a - 2 ^ b
					f[a] = (f[a] + f[lower]) % 2
				end
			end
		end
		local c = {}
		for a = 0, size - 1 do c[a + 1] = f[a] end
		coef[j] = c
	end
	return coef
end

function xorPlan(m, opts)
	local even = opts.even ~= false
	local compress = opts.compress == true
	local bIsGate = opts.bIsGate or {}
	local MODE = LogicModule.MODE
	local n, nOut = #m.inputs, #m.outputs
	local plan = { style = "xor", bIsGate = opts.bIsGate or {}, nOut = #m.outputs, parts = {}, moves = {}, modes = {}, wires = {}, problems = {},
		counts = { terms = 0, outs = 0, gates = 0 } }
	local function pos(column, i)
		if compress then return column, 0, 0 end
		local w = LogicModule.WRAP
		return column, (i - 1) % w, math.floor((i - 1) / w)
	end
	local function addPart(ref, mode, column, i, kind)
		local x, y, z = pos(column, i)
		plan.parts[#plan.parts + 1] = { ref = ref, mode = mode, x = x, y = y, z = z }
		plan.counts[kind] = plan.counts[kind] + 1
		plan.counts.gates = plan.counts.gates + 1
	end
	local function wire(from, to) plan.wires[#plan.wires + 1] = { from = from, to = to } end

	local coef = LogicModule.pprm(m)

	-- column 0: the inputs, in a line
	for k = 1, n do
		plan.moves[#plan.moves + 1] = { ref = "A" .. k, x = 0, y = (k - 1) % LogicModule.WRAP, z = math.floor((k - 1) / LogicModule.WRAP) }
	end

	-- column 1: one AND per term any output uses, shared between outputs.
	-- A one-input term is just that input: with even timing it still gets an
	-- AND (as a buffer), so every path is 2 ticks.
	local src = {}
	local used = 0
	for a = 1, #m.rows - 1 do
		local wanted = false
		for j = 1, nOut do if coef[j][a + 1] == 1 then wanted = true break end end
		if wanted then
			local bits = {}
			for k = 1, n do if hasBit(a, k - 1) then bits[#bits + 1] = k end end
			if #bits == 1 and not even then
				src[a] = "A" .. bits[1]
			else
				used = used + 1
				local ref = "term" .. a
				addPart(ref, MODE.AND, 1, used, "terms")
				for _, k in ipairs(bits) do wire("A" .. k, ref) end
				src[a] = ref
			end
		end
	end

	-- column 2 (and 3): outputs. A gate B is the XOR (or XNOR) itself.
	-- A non-gate B needs an XOR/XNOR in front for 2+ terms, for a constant
	-- term (XNOR), or for 1 term with even timing; otherwise the one term
	-- is wired straight to B, and a B with no terms needs nothing.
	local termsFor, needGate, anyPart = {}, {}, false
	for j = 1, nOut do
		local list = {}
		for a = 1, #m.rows - 1 do
			if coef[j][a + 1] == 1 then list[#list + 1] = src[a] end
		end
		termsFor[j] = list
		local constant = coef[j][1] == 1
		if constant and #list == 0 then
			-- a gate with no inputs is off in the game, XNOR too
			plan.problems[#plan.problems + 1] = string.format("B%d is always on, which XOR style can't build (use ROM)", j - 1)
		end
		needGate[j] = not bIsGate[j] and (#list >= 2 or (#list == 1 and (even or constant)))
		if needGate[j] then anyPart = true end
	end
	local bColumn = anyPart and 3 or 2
	local outCount = 0
	for j = 1, nOut do
		local b = "B" .. j
		plan.moves[#plan.moves + 1] = { ref = b, x = bColumn, y = (j - 1) % LogicModule.WRAP, z = math.floor((j - 1) / LogicModule.WRAP) }
		local mode = coef[j][1] == 1 and MODE.XNOR or MODE.XOR
		local target = b
		if bIsGate[j] then
			plan.modes[b] = mode
		elseif needGate[j] then
			outCount = outCount + 1
			target = "xo" .. j
			addPart(target, mode, 2, outCount, "outs")
			wire(target, b)
		end
		for _, from in ipairs(termsFor[j]) do wire(from, target) end
	end
	return plan
end

-- One line describing a plan, for the module window.
function LogicModule.planText(plan, compress)
	local c = plan.counts
	local parts = {}
	local style
	if plan.style == "xor" then
		style = "XOR (PPRM)"
		parts[#parts + 1] = c.terms .. " term AND(s)"
		if c.outs > 0 then parts[#parts + 1] = c.outs .. " XOR(s) for non-gate outputs" end
	else
		style = "ROM"
		if c.buffers > 0 then parts[#parts + 1] = c.buffers .. " buffer(s)" end
		if c.inverters > 0 then parts[#parts + 1] = c.inverters .. " inverter(s)" end
		parts[#parts + 1] = c.rows .. " row AND(s)"
		if c.ors > 0 then parts[#parts + 1] = c.ors .. " OR(s) for non-gate outputs" end
	end
	if plan.auto then
		style = string.format("Auto picked %s (ROM %d, XOR %d gates)", plan.style == "xor" and "XOR" or "ROM", plan.auto.rom, plan.auto.xor)
	end
	local where = compress and string.format(", stacked in %d block(s)", plan.columns) or ""
	return string.format("%s: %s = %d new gate(s), %s ticks%s", style, table.concat(parts, " + "), c.gates, tostring(plan.ticks), where)
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
-- refs.helpers = { { child =, input = k } }: gates that only feed A, moved
-- in front of their A.
-- Returns { [ref] = child } for A1.., B1.., every new gate and helper, and
-- the list of moves made (A, B and helpers, in plan coordinates).
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

	-- helpers go in front of the A they serve, on its line: the first one
	-- block before A, the next two blocks before ...
	local moves = {}
	for _, mv in ipairs(plan.moves) do moves[#moves + 1] = mv end
	local aPos, count = {}, {}
	for _, mv in ipairs(plan.moves) do aPos[mv.ref] = mv end
	for _, h in ipairs(refs.helpers or {}) do
		local a = aPos["A" .. h.input]
		count[h.input] = (count[h.input] or 0) + 1
		local ref = "H" .. h.input .. "_" .. count[h.input]
		childOf[ref] = h.child
		moves[#moves + 1] = { ref = ref, x = a.x - count[h.input], y = a.y, z = a.z }
	end

	-- move A, B and the helpers into their lines
	for _, mv in ipairs(moves) do
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
	return childOf, moves
end

-- Parts in a blueprint that break the game's wire limits: more than 255
-- inputs or outputs. Counts every wire, the module's and the rest of the
-- creation's. Returns { { child =, ins =, outs = } }.
function LogicModule.wireLimits(bp)
	local ins, byId = {}, {}
	for _, body in ipairs(bp.bodies) do
		for _, child in ipairs(body.childs or {}) do
			local ctrl = child.controller
			if ctrl and ctrl.id then
				byId[ctrl.id] = child
				for _, w in ipairs(ctrl.controllers or {}) do ins[w.id] = (ins[w.id] or 0) + 1 end
			end
		end
	end
	local out = {}
	for id, child in pairs(byId) do
		local nIn, nOut = ins[id] or 0, #(child.controller.controllers or {})
		if nIn > LogicModule.MAX_WIRES or nOut > LogicModule.MAX_WIRES then
			out[#out + 1] = { child = child, ins = nIn, outs = nOut }
		end
	end
	return out
end

-- The old circuit between A and B, all or nothing. Starts at the parts
-- between A and B (inside.parts) plus the dead logic hanging off A (gates
-- fed only by A or other dead logic that reach nothing: no lamp, no other
-- logic, no way back into A; a compressed ROM's unused input gates), and
-- follows wires both ways to every gate or timer it is connected to, but
-- never through A, B, or other parts (switches, lamps ...). Returns:
--   parts        ids of the whole old circuit
--   usedOutside  ids of parts outside it that it drives (not B). When there
--                are any, the circuit is still in use and must stay whole.
-- isLogic(id) says which ids are gates/timers (default: graph kind).
function LogicModule.oldCircuit(graph, inside, inputs, outputs, isLogic)
	isLogic = isLogic or function(id)
		local k = graph[id] and graph[id].kind
		return k == "gate" or k == "timer"
	end
	local stop = {}
	for _, id in ipairs(inputs) do stop[id] = true end
	for _, id in ipairs(outputs) do stop[id] = true end
	local inCircuit, queue = {}, {}
	local function add(id)
		if not inCircuit[id] then inCircuit[id] = true queue[#queue + 1] = id end
	end
	for _, id in ipairs(inside.parts) do add(id) end

	-- dead logic hanging off A: everything downstream of A (not past B) that
	-- can't reach a "live" part: a non-logic part (lamp ...) or an A again
	local isA = {}
	for _, id in ipairs(inputs) do isA[id] = true end
	local isB = {}
	for _, id in ipairs(outputs) do isB[id] = true end
	local down, order = {}, {}
	for _, a in ipairs(inputs) do
		for _, c in ipairs(graph[a] and graph[a].children or {}) do
			if graph[c] and not down[c] and not isA[c] and not isB[c] then down[c] = true order[#order + 1] = c end
		end
	end
	local k = 1
	while k <= #order do
		local u = order[k]
		k = k + 1
		for _, c in ipairs(graph[u].children) do
			if graph[c] and not down[c] and not isA[c] and not isB[c] then down[c] = true order[#order + 1] = c end
		end
	end
	local live, back = {}, {}
	for _, id in ipairs(order) do
		local sink = not isLogic(id)
		for _, c in ipairs(graph[id].children) do
			if isA[c] or (graph[c] and not down[c] and not isB[c]) then sink = true end
		end
		if sink then live[id] = true back[#back + 1] = id end
	end
	k = 1
	while k <= #back do
		local u = back[k]
		k = k + 1
		for _, p in ipairs(graph[u].parents) do
			if down[p] and not live[p] then live[p] = true back[#back + 1] = p end
		end
	end
	-- dead = downstream of A, not live, a gate/timer, fed only by A or other
	-- dead logic (so logic of something else that merely ends here stays)
	local dead = {}
	for _, id in ipairs(order) do
		if not live[id] and isLogic(id) then dead[id] = true end
	end
	local changed = true
	while changed do
		changed = false
		for id in pairs(dead) do
			for _, p in ipairs(graph[id].parents) do
				if not isA[p] and not dead[p] and not inCircuit[p] then
					-- a parent from elsewhere: allowed only if it is dead logic too
					-- (it gets checked in its own turn) or an input-less helper of it
					local pn = graph[p]
					if not (pn and #pn.parents == 0 and isLogic(p)) then
						dead[id] = nil
						changed = true
						break
					end
				end
			end
		end
	end
	for _, id in ipairs(order) do
		if dead[id] then add(id) end
	end
	local i = 1
	while i <= #queue do
		local u = queue[i]
		i = i + 1
		for _, field in ipairs({ "children", "parents" }) do
			for _, v in ipairs(graph[u][field]) do
				if graph[v] and not inCircuit[v] and not stop[v] and isLogic(v) then
					inCircuit[v] = true
					queue[#queue + 1] = v
				end
			end
		end
	end
	local isOut = {}
	for _, id in ipairs(outputs) do isOut[id] = true end
	local parts, used, seenUse = {}, {}, {}
	for _, id in ipairs(queue) do
		parts[#parts + 1] = id
		for _, c in ipairs(graph[id].children) do
			if not inCircuit[c] and not isOut[c] and not seenUse[c] then
				seenUse[c] = true
				used[#used + 1] = c
			end
		end
	end
	table.sort(parts)
	table.sort(used)
	return { parts = parts, usedOutside = used }
end

-- Unwired gates/timers (no inputs, no outputs) stacked in the same block as
-- a part in `removeSet` (a set of blueprint childs): leftovers inside a
-- compressed cluster. They do nothing, so they go with it.
LogicModule.TIMER_UUID = "8f7fd0e7-c46e-4944-a414-7ce2437bb30f"
function LogicModule.strayInCells(bp, removeSet)
	local cells = {}
	for child in pairs(removeSet) do cells[table.concat(LogicModule.cellOf(child), ",")] = true end
	local fed = {}
	for _, body in ipairs(bp.bodies) do
		for _, child in ipairs(body.childs or {}) do
			for _, w in ipairs(child.controller and child.controller.controllers or {}) do fed[w.id] = true end
		end
	end
	local out = {}
	for _, body in ipairs(bp.bodies) do
		for _, child in ipairs(body.childs or {}) do
			local ctrl = child.controller
			if ctrl and not removeSet[child] and (child.shapeId == LogicModule.GATE_UUID or child.shapeId == LogicModule.TIMER_UUID)
				and #(ctrl.controllers or {}) == 0 and not fed[ctrl.id]
				and cells[table.concat(LogicModule.cellOf(child), ",")] then
				out[#out + 1] = child
			end
		end
	end
	return out
end

-- Helpers of the inputs: gates/timers whose only job is feeding A parts
-- (everything they drive is an A part or another helper), found walking
-- back from each A. They move along with A. Returns a list of
-- { id =, input = k (the A they serve, the first one if several), depth = 1.. }.
-- exclude[id] = true keeps a part out (the old circuit); ok(id) can refuse
-- one (e.g. on another body).
function LogicModule.helpers(graph, inputs, exclude, ok)
	exclude = exclude or {}
	ok = ok or function() return true end
	local inputOf = {}
	for k, id in ipairs(inputs) do inputOf[id] = inputOf[id] or k end
	local helper = {}   -- id -> { input =, depth = }
	local list = {}
	local function candidate(id)
		local node = graph[id]
		if not node or inputOf[id] or helper[id] or exclude[id] then return nil end
		if node.kind ~= "gate" and node.kind ~= "timer" then return nil end
		if not ok(id) then return nil end
		local serves, depth
		for _, c in ipairs(node.children) do
			local into = inputOf[c] and { input = inputOf[c], depth = 0 } or helper[c]
			if not into then return nil end
			if not serves or into.input < serves then serves = into.input end
			depth = math.max(depth or 0, into.depth + 1)
		end
		if not serves then return nil end
		return { input = serves, depth = depth }
	end
	-- grow until nothing changes: a parent only qualifies once all it drives does
	local changed = true
	while changed do
		changed = false
		local frontier = {}
		for id in pairs(inputOf) do frontier[#frontier + 1] = id end
		for id in pairs(helper) do frontier[#frontier + 1] = id end
		for _, id in ipairs(frontier) do
			for _, p in ipairs(graph[id].parents) do
				local h = candidate(p)
				if h then
					helper[p] = h
					list[#list + 1] = { id = p, input = h.input, depth = h.depth }
					changed = true
				end
			end
		end
	end
	table.sort(list, function(a, b)
		if a.input ~= b.input then return a.input < b.input end
		if a.depth ~= b.depth then return a.depth < b.depth end
		return tostring(a.id) < tostring(b.id)
	end)
	return list
end
