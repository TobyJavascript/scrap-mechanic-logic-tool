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
-- Offline simulation (used for truth tables)
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

-- Simulates the network tick by tick. `forced` = { [id] = bool } holds the
-- inputs. Timers are modelled as delay lines. Returns the state after
-- `ticks` ticks (or after it settles), and whether it settled.
function LogicGraph.simulate(graph, forced, ticks, initial)
	local state = {}
	local lines = {}
	for id, node in pairs(graph) do
		state[id] = initial and initial[id] or false
		if node.kind == "timer" then
			lines[id] = {}
			for i = 1, math.max(0, node.delay - 1) do lines[id][i] = false end
		end
	end
	for id, v in pairs(forced) do state[id] = v end

	local settled = false
	local stable = 0
	local timerInput = {}
	for _ = 1, ticks do
		local nextState = {}
		local changed = false
		for id, node in pairs(graph) do
			local v
			if forced[id] ~= nil then
				v = forced[id]
			elseif node.kind == "gate" then
				local ins = {}
				for i, p in ipairs(node.parents) do ins[i] = state[p] or false end
				v = gateOutput(node.mode, ins)
			elseif node.kind == "timer" then
				local inp = false
				for _, p in ipairs(node.parents) do if state[p] then inp = true break end end
				timerInput[id] = inp
				local line = lines[id]
				if #line == 0 then
					v = inp
				else
					v = line[1]
					table.remove(line, 1)
					line[#line + 1] = inp
				end
			elseif node.kind == "output" or node.kind == "script" then
				local inp = false
				for _, p in ipairs(node.parents) do if state[p] then inp = true break end end
				v = inp
			else
				v = state[id] or false
			end
			nextState[id] = v
			if v ~= state[id] then changed = true end
		end
		state = nextState
		if not changed then
			-- a timer is still busy while its delay line holds a change
			local busy = false
			for id, line in pairs(lines) do
				for _, b in ipairs(line) do
					if b ~= (timerInput[id] or false) then busy = true break end
				end
			end
			stable = busy and 0 or stable + 1
			if stable >= 2 then
				settled = true
				break
			end
		else
			stable = 0
		end
	end
	return state, settled
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
