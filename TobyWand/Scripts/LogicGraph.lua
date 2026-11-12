-- LogicGraph: timing analysis and lint for a logic network.
-- Pure Lua (no game API), so it can be tested outside the game.
--
-- graph = {
--   [id] = { kind = "gate"|"timer"|"input"|"output"|"script",
--            mode = 0..5 or nil,  delay = ticks,
--            children = { id, ... }, parents = { id, ... } }
-- }
--
-- Delay model: a node's "delay" is how many ticks after its inputs change
-- its own output changes. Logic gates take 1 tick. A timer takes its set
-- time plus 1 tick. Buttons/switches/sensors (sources) and lights/engines
-- (sinks) count as 0.

LogicGraph = LogicGraph or {}

LogicGraph.MODE_NAMES = { [0] = "AND", "OR", "XOR", "NAND", "NOR", "XNOR" }
LogicGraph.TICKS_PER_SECOND = 40

function LogicGraph.timerDelay(seconds, ticks)
	return 1 + (seconds or 0) * LogicGraph.TICKS_PER_SECOND + (ticks or 0)
end

-- A timer's settings as the game's timer menu allows them
LogicGraph.TIMER_SECONDS_MAX = 59
LogicGraph.TIMER_TICKS_MAX = 40

-- "5" or "5t" (ticks), "2s", "1s 5t", "1s5t" -> seconds, ticks. More than
-- 40 ticks carry into seconds. Returns nil and why when it can't be set.
function LogicGraph.parseTimer(text)
	local s = tostring(text or ""):lower():gsub("%s+", "")
	if s == "" then return nil, "Type a timer setting first, like 5t or 1s 5t" end
	local seconds, ticks
	local a, b = s:match("^(%d+)s(%d+)t?$")
	if a then
		seconds, ticks = tonumber(a), tonumber(b)
	else
		local n, unit = s:match("^(%d+)([st]?)$")
		if not n then return nil, "Timer: write ticks (5 or 5t), seconds (2s) or both (1s 5t)" end
		if unit == "s" then seconds, ticks = tonumber(n), 0 else seconds, ticks = 0, tonumber(n) end
	end
	local total = seconds * LogicGraph.TICKS_PER_SECOND + ticks
	seconds, ticks = math.floor(total / LogicGraph.TICKS_PER_SECOND), total % LogicGraph.TICKS_PER_SECOND
	if seconds > LogicGraph.TIMER_SECONDS_MAX then
		return nil, "Timer: the game allows at most " .. LogicGraph.TIMER_SECONDS_MAX .. "s " .. LogicGraph.TIMER_TICKS_MAX .. "t"
	end
	return seconds, ticks
end

function LogicGraph.formatTicks(t)
	if t == nil then return "-" end
	return string.format("%d tick%s (%.3fs)", t, t == 1 and "" or "s", t / LogicGraph.TICKS_PER_SECOND)
end

---------------------------------------------------------------------------
-- Binary min-heap for Dijkstra
---------------------------------------------------------------------------

local function heapPush(h, key, val)
	local n = #h + 1
	h[n] = { key, val }
	while n > 1 do
		local p = math.floor(n / 2)
		if h[p][1] <= h[n][1] then break end
		h[p], h[n] = h[n], h[p]
		n = p
	end
end

local function heapPop(h)
	local top = h[1]
	local last = h[#h]
	h[#h] = nil
	if #h > 0 then
		h[1] = last
		local i = 1
		local n = #h
		while true do
			local l, r = i * 2, i * 2 + 1
			local m = i
			if l <= n and h[l][1] < h[m][1] then m = l end
			if r <= n and h[r][1] < h[m][1] then m = r end
			if m == i then break end
			h[i], h[m] = h[m], h[i]
			i = m
		end
	end
	return top[1], top[2]
end

---------------------------------------------------------------------------
-- Timing
---------------------------------------------------------------------------

-- Walking direction. Forward: from u to its children, stepping onto child c
-- costs c's delay. Reverse: from u to its parents, and the step costs u's
-- own delay (the time u takes to pass the change on).
local function neighbours(graph, u, reverse)
	return reverse and graph[u].parents or graph[u].children
end

local function stepCost(graph, u, v, reverse)
	return reverse and graph[u].delay or graph[v].delay
end

-- Shortest arrival time from any source to every reachable node.
local function shortest(graph, sources, reverse)
	local dist = {}
	local heap = {}
	for _, s in ipairs(sources) do
		if graph[s] and dist[s] == nil then
			dist[s] = 0
			heapPush(heap, 0, s)
		end
	end
	while #heap > 0 do
		local d, u = heapPop(heap)
		if d == dist[u] then
			for _, c in ipairs(neighbours(graph, u, reverse)) do
				local node = graph[c]
				if node then
					local nd = d + stepCost(graph, u, c, reverse)
					if dist[c] == nil or nd < dist[c] then
						dist[c] = nd
						heapPush(heap, nd, c)
					end
				end
			end
		end
	end
	return dist
end

-- Longest arrival time from the sources. Feedback loops (memory cells,
-- clocks) would make this infinite, so like a hardware timing analyser we
-- break each loop at the edge that closes it (a DFS back edge).
local function longest(graph, sources, reverse)
	local state = {}   -- nil = unseen, 1 = on stack, 2 = done
	local back = {}    -- back[u][c] = true for loop-closing edges
	local backCount = 0
	local order = {}   -- reverse post-order = topological order w/o back edges

	for _, s in ipairs(sources) do
		if graph[s] and not state[s] then
			-- iterative DFS
			local stack = { { s, 1 } }
			state[s] = 1
			while #stack > 0 do
				local top = stack[#stack]
				local u, i = top[1], top[2]
				local children = neighbours(graph, u, reverse)
				if i <= #children then
					top[2] = i + 1
					local c = children[i]
					if graph[c] then
						if state[c] == nil then
							state[c] = 1
							stack[#stack + 1] = { c, 1 }
						elseif state[c] == 1 then
							back[u] = back[u] or {}
							if not back[u][c] then
								back[u][c] = true
								backCount = backCount + 1
							end
						end
					end
				else
					state[u] = 2
					order[#order + 1] = u
					stack[#stack] = nil
				end
			end
		end
	end

	local best, pred = {}, {}
	for _, s in ipairs(sources) do
		if graph[s] then best[s] = 0 end
	end
	for k = #order, 1, -1 do
		local u = order[k]
		local bu = best[u]
		if bu then
			for _, c in ipairs(neighbours(graph, u, reverse)) do
				local node = graph[c]
				if node and not (back[u] and back[u][c]) then
					local nd = bu + stepCost(graph, u, c, reverse)
					if best[c] == nil or nd > best[c] then
						best[c] = nd
						pred[c] = u
					end
				end
			end
		end
	end
	return best, pred, backCount, back
end

-- Nodes from which at least one target can be reached.
local function reachesTargets(graph, targets)
	local seen = {}
	local stack = {}
	for _, t in ipairs(targets) do
		if graph[t] and not seen[t] then
			seen[t] = true
			stack[#stack + 1] = t
		end
	end
	while #stack > 0 do
		local u = stack[#stack]
		stack[#stack] = nil
		for _, p in ipairs(graph[u].parents) do
			if graph[p] and not seen[p] then
				seen[p] = true
				stack[#stack + 1] = p
			end
		end
	end
	return seen
end

-- Timing from the source set to the target set.
-- Returns {
--   min, max                 overall best/worst case ticks (nil if unreachable)
--   perTarget = { [id] = { min = , max = } }
--   unreachable = count
--   path = { id, ... }       the slowest path (source ... target)
--   loops = number of feedback edges that were cut for the max
--   glitch = { id, ... }     gates whose inputs settle at different times
-- }
function LogicGraph.timing(graph, sources, targets)
	local dist = shortest(graph, sources)
	local best, pred, loops = longest(graph, sources)

	local res = { perTarget = {}, unreachable = 0, loops = loops, path = {}, glitch = {} }
	local worstTarget

	local isSource = {}
	for _, s in ipairs(sources) do isSource[s] = true end

	for _, t in ipairs(targets) do
		local lo, hi = dist[t], best[t]
		if lo == nil then
			res.unreachable = res.unreachable + 1
		else
			hi = hi or lo
			if hi < lo then hi = lo end
			res.perTarget[t] = { min = lo, max = hi }
			if res.min == nil or lo < res.min then res.min = lo end
			if res.max == nil or hi > res.max then
				res.max = hi
				worstTarget = t
			end
		end
	end

	if worstTarget then
		local path = {}
		local u = worstTarget
		local guard = 0
		while u ~= nil and guard < 100000 do
			table.insert(path, 1, u)
			if isSource[u] then break end
			u = pred[u]
			guard = guard + 1
		end
		res.path = path
	end

	-- Glitch hazards: a gate (on the way to a target) with 2+ inputs that are
	-- driven from the sources but arrive at different ticks. When the sources
	-- change together the gate can see a wrong combination for a few ticks.
	local useful = reachesTargets(graph, targets)
	for id, node in pairs(graph) do
		if useful[id] and not isSource[id] and node.kind == "gate" and dist[id] then
			local earliest, latest
			local driven = 0
			for _, p in ipairs(node.parents) do
				if dist[p] then
					driven = driven + 1
					local lo = dist[p]
					local hi = best[p] or lo
					if earliest == nil or lo < earliest then earliest = lo end
					if latest == nil or hi > latest then latest = hi end
				end
			end
			if driven >= 2 and latest > earliest then
				res.glitch[#res.glitch + 1] = id
			end
		end
	end
	table.sort(res.glitch, function(a, b) return tostring(a) < tostring(b) end)

	return res
end

---------------------------------------------------------------------------
-- Delay probe
---------------------------------------------------------------------------

-- Nodes that are part of a feedback loop (strongly connected component of
-- 2+ nodes, or wired to themselves), among those reachable from `starts`.
-- Iterative Tarjan.
local function loopNodes(graph, starts, reverse)
	local index, low, onStack, inLoop = {}, {}, {}, {}
	local stack, counter = {}, 0
	local function visit(v)
		counter = counter + 1
		index[v], low[v] = counter, counter
		stack[#stack + 1] = v
		onStack[v] = true
	end
	for _, s in ipairs(starts) do
		if graph[s] and not index[s] then
			visit(s)
			local work = { { s, 1 } }
			while #work > 0 do
				local top = work[#work]
				local u, i = top[1], top[2]
				local list = neighbours(graph, u, reverse)
				if i <= #list then
					top[2] = i + 1
					local v = list[i]
					if graph[v] then
						if v == u then inLoop[u] = true end
						if not index[v] then
							visit(v)
							work[#work + 1] = { v, 1 }
						elseif onStack[v] and index[v] < low[u] then
							low[u] = index[v]
						end
					end
				else
					work[#work] = nil
					if #work > 0 then
						local p = work[#work][1]
						if low[u] < low[p] then low[p] = low[u] end
					end
					if low[u] == index[u] then
						local comp = {}
						repeat
							local w = stack[#stack]
							stack[#stack] = nil
							onStack[w] = nil
							comp[#comp + 1] = w
						until w == u
						if #comp > 1 then
							for _, w in ipairs(comp) do inLoop[w] = true end
						end
					end
				end
			end
		end
	end
	return inLoop
end

-- Delay of every part after the sources (or, with reverse, before them).
-- Forward: ticks from a source changing until that part's output changes.
-- Reverse: ticks from that part changing until a source (then the end
-- point) changes.
-- Returns a list of { id =, min =, max =, loop = bool, glitch = bool },
-- sorted by min, max; sources are not included. `glitch` (forward only):
-- a gate whose own inputs arrive at different ticks.
function LogicGraph.probe(graph, sources, reverse)
	local dist = shortest(graph, sources, reverse)
	local best = longest(graph, sources, reverse)
	local inLoop = loopNodes(graph, sources, reverse)
	local isSource = {}
	for _, s in ipairs(sources) do isSource[s] = true end

	local out = {}
	for id, lo in pairs(dist) do
		if not isSource[id] then
			local hi = best[id] or lo
			if hi < lo then hi = lo end
			local e = { id = id, min = lo, max = hi, loop = inLoop[id] == true, glitch = false }
			local node = graph[id]
			if not reverse and node.kind == "gate" then
				local earliest, latest, driven = nil, nil, 0
				for _, p in ipairs(node.parents) do
					if dist[p] then
						driven = driven + 1
						local plo, phi = dist[p], best[p] or dist[p]
						if earliest == nil or plo < earliest then earliest = plo end
						if latest == nil or phi > latest then latest = phi end
					end
				end
				e.glitch = driven >= 2 and latest > earliest
			end
			out[#out + 1] = e
		end
	end
	table.sort(out, function(a, b)
		if a.min ~= b.min then return a.min < b.min end
		if a.max ~= b.max then return a.max < b.max end
		return tostring(a.id) < tostring(b.id)
	end)
	return out
end

-- Label text for a probe entry: "5t", "3-7t", "3t+ loop".
function LogicGraph.probeText(e)
	if e.loop then return e.min .. "t+ loop" end
	if e.min == e.max then return e.min .. "t" end
	return e.min .. "-" .. e.max .. "t"
end

---------------------------------------------------------------------------
-- Lint
---------------------------------------------------------------------------

-- Returns a list of { id = , level = "warn"|"info", msg = } and a summary.
function LogicGraph.lint(graph)
	local issues = {}
	local counts = { gates = 0, timers = 0, inputs = 0, outputs = 0, other = 0, modes = {} }

	local function add(id, level, msg)
		issues[#issues + 1] = { id = id, level = level, msg = msg }
	end

	local ids = {}
	for id in pairs(graph) do ids[#ids + 1] = id end
	table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)

	for _, id in ipairs(ids) do
		local node = graph[id]
		local nIn, nOut = #node.parents, #node.children
		local kind = node.kind

		if kind == "gate" then
			counts.gates = counts.gates + 1
			local name = LogicGraph.MODE_NAMES[node.mode] or "gate"
			counts.modes[name] = (counts.modes[name] or 0) + 1

			if nIn == 0 then
				add(id, "warn", name .. " has no inputs (it stays off)")
			end
			if nOut == 0 then
				add(id, "info", name .. " output goes nowhere")
			end
			if (node.mode == 2 or node.mode == 5) and nIn > 2 then
				add(id, "warn", name .. " has " .. nIn .. " inputs; check it does what you expect with more than 2")
			end
		elseif kind == "timer" then
			counts.timers = counts.timers + 1
			if nIn == 0 then add(id, "warn", "timer has no input") end
			if nOut == 0 then add(id, "info", "timer output goes nowhere") end
			if nIn > 1 then
				add(id, "info", "timer has " .. nIn .. " inputs")
			end
		elseif kind == "input" then
			counts.inputs = counts.inputs + 1
			if nOut == 0 then add(id, "info", "input is not connected to anything") end
		elseif kind == "output" then
			counts.outputs = counts.outputs + 1
			if nIn == 0 then add(id, "info", "output has no input") end
		else
			counts.other = counts.other + 1
		end
	end

	-- Feedback loops found from every node (memory cells, clocks...)
	local all = {}
	for _, id in ipairs(ids) do all[#all + 1] = id end
	local _, _, loops = longest(graph, all)
	counts.loops = loops

	return issues, counts
end

---------------------------------------------------------------------------
-- Offline simulation (truth tables, tick debugger)
---------------------------------------------------------------------------

local function gateOutput(mode, inputs)
	local n = #inputs
	if n == 0 then return false end
	local on = 0
	for i = 1, n do if inputs[i] then on = on + 1 end end
	if mode == 0 then return on == n
	elseif mode == 1 then return on > 0
	elseif mode == 2 then return on % 2 == 1
	elseif mode == 3 then return on ~= n
	elseif mode == 4 then return on == 0
	elseif mode == 5 then return on % 2 == 0
	end
	return false
end
LogicGraph.gateOutput = gateOutput

-- One tick of the network. A state is { values = { [id] = bool },
-- lines = { [timerId] = { bool ... } } } (a timer's delay line, oldest
-- first). `forced` = { [id] = bool } holds inputs. Every part computes its
-- next value from the previous tick's values, like the game. Returns the new
-- state (the old one is left as it was), the ids that changed, and whether
-- a timer still holds a change that has yet to come out.
function LogicGraph.step(graph, s, forced)
	local values, lines = s.values, s.lines
	local nextValues, nextLines = {}, {}
	local changed = {}
	local busy = false
	for id, node in pairs(graph) do
		local v
		if forced[id] ~= nil then
			v = forced[id]
		elseif node.kind == "gate" then
			local ins = {}
			for i, p in ipairs(node.parents) do ins[i] = values[p] or false end
			v = gateOutput(node.mode, ins)
		elseif node.kind == "timer" then
			local inp = false
			for _, p in ipairs(node.parents) do if values[p] then inp = true break end end
			local line = lines[id] or {}
			if #line == 0 then
				v = inp
				nextLines[id] = line
			else
				v = line[1]
				local nl = {}
				for i = 2, #line do nl[#nl + 1] = line[i] end
				nl[#nl + 1] = inp
				nextLines[id] = nl
				for _, b in ipairs(nl) do
					if b ~= inp then busy = true break end
				end
			end
		elseif node.kind == "output" or node.kind == "script" then
			local inp = false
			for _, p in ipairs(node.parents) do if values[p] then inp = true break end end
			v = inp
		else
			v = values[id] or false
		end
		nextValues[id] = v
		if v ~= (values[id] or false) then changed[#changed + 1] = id end
	end
	return { values = nextValues, lines = nextLines }, changed, busy
end

-- A starting state: `initial` values (default off), `forced` on top. With
-- `fill`, a timer's delay line is full of its own current value (a timer
-- that has been in that state for a while), else all off.
function LogicGraph.newState(graph, initial, forced, fill)
	local values, lines = {}, {}
	for id, node in pairs(graph) do
		values[id] = initial and initial[id] or false
		if node.kind == "timer" then
			local line = {}
			local b = fill and values[id] or false
			for i = 1, math.max(0, node.delay - 1) do line[i] = b end
			lines[id] = line
		end
	end
	for id, v in pairs(forced or {}) do values[id] = v end
	return { values = values, lines = lines }
end

-- Simulates the network tick by tick. `forced` = { [id] = bool } holds the
-- inputs. Timers are modelled as delay lines. Returns the state after
-- `ticks` ticks (or after it settles), and whether it settled.
function LogicGraph.simulate(graph, forced, ticks, initial)
	local s = LogicGraph.newState(graph, initial, forced, false)
	local stable = 0
	for _ = 1, ticks do
		local changed, busy
		s, changed, busy = LogicGraph.step(graph, s, forced)
		if #changed == 0 then
			-- a timer is still busy while its delay line holds a change
			stable = busy and 0 or stable + 1
			if stable >= 2 then return s.values, true end
		else
			stable = 0
		end
	end
	return s.values, false
end

---------------------------------------------------------------------------
-- Tick debugger: step a copy of the logic between inputs and outputs one
-- tick at a time, forward and back.
---------------------------------------------------------------------------

LogicGraph.DEBUG_MAX_TICKS = 10000

-- `parts` = the ids being looked at (the inputs, the outputs and what is
-- between them). Everything that can feed them is simulated too, so a clock
-- or a loop beside them keeps running. `snapshot` = { [id] = bool }: the
-- values in the game right now. `inputs`/`inputValues`: set to new values at
-- tick 0. opts.mode:
--   "hold"  (default) the inputs stay at those values
--   "pulse" for 1 tick only, then back to what they were (a button tap:
--           what a toggle memory or an edge detector needs)
--   "free"  set at tick 0, then they follow their own wiring (to kick a
--           loop or a memory cell that runs through an input)
--   "repeat" every opts.every ticks (0, N, 2N ...) the inputs set to 1 get
--           a 1 tick pulse, off in between; the ones set to 0 stay off
function LogicGraph.debugStart(graph, parts, snapshot, inputs, inputValues, opts)
	local mode = opts and opts.mode or "hold"
	local hold = mode ~= "free"
	local isInput = {}
	for _, id in ipairs(inputs) do isInput[id] = true end

	-- parts and everything upstream (not past a held input: it doesn't listen)
	local sub, queue = {}, {}
	for _, id in ipairs(parts) do
		if graph[id] and not sub[id] then
			sub[id] = graph[id]
			queue[#queue + 1] = id
		end
	end
	local i = 1
	while i <= #queue do
		local u = queue[i]
		i = i + 1
		if not (hold and isInput[u]) then
			for _, p in ipairs(graph[u].parents) do
				if graph[p] and not sub[p] then
					sub[p] = graph[p]
					queue[#queue + 1] = p
				end
			end
		end
	end

	local start, forced = {}, {}
	local changed0 = {}
	for k, id in ipairs(inputs) do
		if sub[id] then
			local v = inputValues[k] or false
			start[id] = v
			if mode == "hold" then
				forced[id] = v
			elseif mode == "pulse" then
				forced[id] = snapshot[id] or false
			elseif mode == "repeat" then
				forced[id] = false
			end
			if v ~= (snapshot[id] or false) then changed0[#changed0 + 1] = id end
		end
	end
	local initial = {}
	for id in pairs(sub) do initial[id] = snapshot[id] or false end
	for id, v in pairs(start) do initial[id] = v end
	-- `initial` already has the inputs' tick 0 values (`forced` is for tick 1 on)
	local s = LogicGraph.newState(sub, initial, nil, true)
	-- repeat: the inputs on a pulse tick
	local pulseForced
	if mode == "repeat" then
		pulseForced = {}
		for id, v in pairs(forced) do pulseForced[id] = start[id] or v end
	end
	return {
		graph = sub, forced = forced, state = s,
		mode = mode, every = math.max(1, math.floor(opts and opts.every or 1)), pulseForced = pulseForced,
		tick = 0, last = 0,
		changes = { [0] = changed0 },
		lines = { [0] = s.lines },
		busy = { [0] = #changed0 > 0 },
	}
end

-- The values at the current tick are toggles away from the neighbouring
-- ticks (a change flips a bool), so moving through history needs no copies.
local function flip(values, ids)
	for _, id in ipairs(ids) do values[id] = not values[id] end
end

-- The inputs on tick t (t >= 1).
local function forcedAt(d, t)
	if d.pulseForced and t % d.every == 0 then return d.pulseForced end
	return d.forced
end

-- One tick forward. Returns false (and a reason) when it can't.
function LogicGraph.debugForward(d)
	if d.tick < d.last then
		d.tick = d.tick + 1
		flip(d.state.values, d.changes[d.tick])
		d.state.lines = d.lines[d.tick]
		return true
	end
	if d.tick >= LogicGraph.DEBUG_MAX_TICKS then return false, "limit" end
	local nextState, changed, busy = LogicGraph.step(d.graph, d.state, forcedAt(d, d.tick + 1))
	d.tick = d.tick + 1
	d.last = d.tick
	d.state = nextState
	d.changes[d.tick] = changed
	d.lines[d.tick] = nextState.lines
	d.busy[d.tick] = busy
	return true
end

function LogicGraph.debugBack(d)
	if d.tick == 0 then return false end
	flip(d.state.values, d.changes[d.tick])
	d.tick = d.tick - 1
	d.state.lines = d.lines[d.tick]
	return true
end

-- Looks ahead from the current tick (on a copy): in how many ticks each of
-- `ids` changes next, { [id] = n }, n = 1 for the next tick. Parts that won't
-- change within `maxTicks` (or before everything settles) aren't in it.
function LogicGraph.debugLookahead(d, ids, maxTicks)
	local want, left = {}, 0
	for _, id in ipairs(ids) do
		if d.graph[id] and not want[id] then want[id] = true left = left + 1 end
	end
	local values = {}
	for id, v in pairs(d.state.values) do values[id] = v end
	local s = { values = values, lines = d.state.lines }
	local out = {}
	local quiet = 0
	for n = 1, maxTicks or 64 do
		local changed, busy
		s, changed, busy = LogicGraph.step(d.graph, s, forcedAt(d, d.tick + n))
		for _, id in ipairs(changed) do
			if want[id] and not out[id] then
				out[id] = n
				left = left - 1
			end
		end
		if left == 0 then break end
		if #changed == 0 and not busy and not d.pulseForced then
			quiet = quiet + 1
			if quiet >= 2 then break end
		else
			quiet = 0
		end
	end
	return out
end

-- XOR gates wired to themselves: the community's 1-bit memory (a 1 tick
-- pulse in flips it, and it holds).
function LogicGraph.isXorMemory(graph, id)
	local node = graph[id]
	if not (node and node.kind == "gate" and node.mode == 2) then return false end
	for _, p in ipairs(node.parents) do
		if p == id then return true end
	end
	return false
end

-- Nothing changed this tick and no timer is still holding a change.
function LogicGraph.debugSettled(d)
	if d.pulseForced then return false end -- the next pulse is always coming
	return #d.changes[d.tick] == 0 and not d.busy[d.tick]
end

-- The last tick where something changed, up to now (nil if none).
function LogicGraph.debugLastChange(d)
	for t = d.tick, 0, -1 do
		if #d.changes[t] > 0 then return t end
	end
end

-- How often each of `ids` changed in ticks 1..now (the inputs' own change at
-- tick 0 doesn't count). More than once = a glitch.
function LogicGraph.debugChangeCounts(d, ids)
	local want, counts = {}, {}
	for _, id in ipairs(ids) do want[id] = true counts[id] = 0 end
	for t = 1, d.tick do
		for _, id in ipairs(d.changes[t]) do
			if want[id] then counts[id] = counts[id] + 1 end
		end
	end
	return counts
end

-- Truth table of outputs for every combination of inputs (max 10 inputs).
-- Returns rows = { { ins = {bool...}, outs = {bool...}, settled = bool } }
function LogicGraph.truthTable(graph, inputs, outputs, maxTicks)
	local rows = {}
	local n = #inputs
	if n > 10 then return nil, "too many inputs for a truth table (max 10)" end
	for combo = 0, 2 ^ n - 1 do
		local forced = {}
		local ins = {}
		for k = 1, n do
			local v = math.floor(combo / 2 ^ (k - 1)) % 2 == 1
			forced[inputs[k]] = v
			ins[k] = v
		end
		local state, settled = LogicGraph.simulate(graph, forced, maxTicks or 2000)
		local outs = {}
		for k, o in ipairs(outputs) do outs[k] = state[o] or false end
		rows[#rows + 1] = { ins = ins, outs = outs, settled = settled }
	end
	return rows
end
