-- Tests for LogicScript and LogicGraph. Returns the number of failures.
local failures = 0
local passed = 0

local function check(name, cond, detail)
	if cond then
		passed = passed + 1
	else
		failures = failures + 1
		print("FAIL: " .. name .. (detail and ("  -- " .. tostring(detail)) or ""))
	end
end

local function node(key, x, y, z)
	return { key = key, x = x or 0, y = y or 0, z = z or 0, order = 0 }
end

local function group(prefix, n, axisFn)
	local g = {}
	for i = 1, n do
		local x, y, z = 0, 0, 0
		if axisFn then x, y, z = axisFn(i) end
		g[i] = node(prefix .. i, x, y, z)
		g[i].order = i
	end
	return g
end

local function opsString(res)
	local parts = {}
	for _, op in ipairs(res.ops) do
		parts[#parts + 1] = op.kind .. " " .. op.p.key .. (op.c and (">" .. op.c.key) or "")
	end
	return table.concat(parts, ", ")
end

local function run(src, groups)
	local ok, res = LogicScript.run(src, groups)
	return ok, res
end

---------------------------------------------------------------------------
-- LogicScript (Lua)
---------------------------------------------------------------------------

do
	local A, B = group("a", 2), group("b", 2)
	local ok, res = run("connect(A, B)", { A = A, B = B })
	check("all-to-all ok", ok, res)
	check("all-to-all ops", ok and opsString(res) == "connect a1>b1, connect a1>b2, connect a2>b1, connect a2>b2", ok and opsString(res))
end

do
	local A, B = group("a", 3), group("b", 3)
	local ok, res = run('connect(A, B, "zip")', { A = A, B = B })
	check("zip", ok and opsString(res) == "connect a1>b1, connect a2>b2, connect a3>b3", ok and opsString(res) or res)
end

do
	local A = group("a", 3, function(i) return 10 - i, 0, 0 end)
	local B = group("b", 3, function(i) return i, 0, 0 end)
	local ok, res = run(LogicScript.examples[1].code, { A = A, B = B })
	check("sort zip example", ok and opsString(res) == "connect a3>b1, connect a2>b2, connect a1>b3", ok and opsString(res) or res)
	local ok2, res2 = run('sort(A, "-x")\nconnect(A, B, "zip")', { A = A, B = B })
	check("sort desc", ok2 and opsString(res2) == "connect a1>b1, connect a2>b2, connect a3>b3", ok2 and opsString(res2) or res2)
	check("groups not mutated", A[1].key == "a1")
	local ok3, res3 = run('sort(A, function(p, q) return p.x > q.x end) connect(A[1], B[1])', { A = A, B = B })
	check("sort with function", ok3 and opsString(res3) == "connect a1>b1", ok3 and opsString(res3) or res3)
end

do
	local A = group("a", 4)
	local ok, res = run("chain(A)", { A = A })
	check("chain", ok and opsString(res) == "connect a1>a2, connect a2>a3, connect a3>a4", ok and opsString(res) or res)
	local ok2, res2 = run("chain(slice(A, 2, -1))", { A = A })
	check("chain slice", ok2 and opsString(res2) == "connect a2>a3, connect a3>a4", ok2 and opsString(res2) or res2)
end

do
	local A, B = group("a", 4), group("b", 1)
	local ok, res = run("connect(A[#A], B[1])\ncut(A[1], B)", { A = A, B = B })
	check("last + cut", ok and opsString(res) == "connect a4>b1, cut a1>b1", ok and opsString(res) or res)
	ok, res = run("flip(A, B)\nflip(slice(A, 1, 1), B, \"zip\")", { A = A, B = B })
	check("flip", ok and opsString(res) == "flip a1>b1, flip a2>b1, flip a3>b1, flip a4>b1", ok and opsString(res) or res)
end

do
	local A, B = group("a", 4), group("b", 4)
	local ok, res = run(LogicScript.examples[4].code, { A = A, B = B })
	check("reverse loop", ok and opsString(res) == "connect a1>b4, connect a2>b3, connect a3>b2, connect a4>b1", ok and opsString(res) or res)
end

do
	local A, B, C = group("a", 2), group("b", 4), group("c", 2)
	local ok, res = run(LogicScript.examples[2].code, { A = A, B = B, C = C })
	check("decoder ok", ok, res)
	if ok then
		check("decoder ops", opsString(res) ==
			"connect c1>b1, connect c2>b1, connect a1>b2, connect c2>b2, connect c1>b3, connect a2>b3, connect a1>b4, connect a2>b4",
			opsString(res))
		check("decoder print", res.output[1] == "decoder for 2 bits, 4 outputs", res.output[1])
	end
end

do
	local A, B = group("a", 6), group("b", 2)
	local ok, res = run(LogicScript.examples[5].code, { A = A, B = B })
	check("every 2nd", ok and opsString(res) ==
		"connect a1>b1, connect a3>b1, connect a5>b1, connect a2>b2, connect a4>b2, connect a6>b2", ok and opsString(res) or res)
end

do
	local A, B = group("a", 3), group("b", 1)
	A[2].mode = "XOR"
	local ok, res = run(LogicScript.examples[6].code, { A = A, B = B })
	check("filter by mode", ok and opsString(res) == "connect a2>b1" and res.output[1] == "1 XOR gates connected", ok and (opsString(res) .. " | " .. tostring(res.output[1])) or res)
	for i, ex in ipairs(LogicScript.examples) do
		local okE, err = run(ex.code, { A = group("a", 4), B = group("b", 4), C = group("c", 4) })
		check("example " .. i .. " runs", okE, err)
		check("example " .. i .. " is formatted", LogicScript.format(ex.code) == ex.code, LogicScript.format(ex.code))
	end
end

-- the Lua language itself
do
	local function lua(src)
		local ok, res, partial = LogicScript.run(src, { A = group("a", 3) })
		if not ok then return "ERR " .. tostring(res) end
		return table.concat(res.output, "|")
	end
	check("arith", lua("print(1 + 2 * 3, 2 ^ 3 ^ 2, -2 ^ 2, 7 % 3, 7 / 2, 'a' .. 1 .. 'b')") == "7 512 -4 1 3.5 a1b", lua("print(1 + 2 * 3, 2 ^ 3 ^ 2, -2 ^ 2, 7 % 3, 7 / 2, 'a' .. 1 .. 'b')"))
	check("logic", lua("print(nil or 5, false and 1, not nil, 1 < 2, 'a' < 'b', 1 == 1.0, 2 ~= 2)") == "5 false true true true true false", lua("print(nil or 5, false and 1, not nil, 1 < 2, 'a' < 'b', 1 == 1.0, 2 ~= 2)"))
	check("locals/closures", lua([[
local function counter()
    local n = 0
    return function() n = n + 1 return n end
end
local c1, c2 = counter(), counter()
c1() c1()
print(c1(), c2())
]]) == "3 1", lua("local function counter() local n = 0 return function() n = n + 1 return n end end local c1, c2 = counter(), counter() c1() c1() print(c1(), c2())"))
	check("loop closures capture each i", lua([[
local fs = {}
for i = 1, 3 do fs[i] = function() return i end end
print(fs[1](), fs[2](), fs[3]())
]]) == "1 2 3")
	check("varargs", lua([[
local function f(...)
    local a, b = ...
    return select("#", ...), a, b
end
print(f(4, 5, 6))
local t = { f(1, 2) }
print(#t)
]]) == "3 4 5|3")
	check("tables/methods", lua([[
local obj = { n = 2 }
function obj:double() return self.n * 2 end
local t = { 10, 20, x = 1, [5] = "five" }
print(obj:double(), #t, t.x, t[5], ("ab"):upper(), string.format("%03d", 7))
]]) == "4 2 1 five AB 007")
	check("generic for + pairs order", lua([[
local s = 0
for i, p in ipairs(A) do s = s + i end
local keys = {}
for k in pairs({ a = 1, b = 2 }) do keys[#keys + 1] = k end
table.sort(keys)
print(s, table.concat(keys, ","))
]]) == "6 a,b")
	check("while/repeat/break", lua([[
local i = 0
while true do i = i + 1 if i == 5 then break end end
local j = 0
repeat local k = j j = j + 1 until k >= 3
print(i, j)
]]) == "5 4")
	check("if/elseif", lua([[
for i = 1, 3 do
    if i == 1 then print("one") elseif i == 2 then print("two") else print("many") end
end
]]) == "one|two|many")
	check("numeric for step", lua("for i = 10, 1, -3 do print(i) end") == "10|7|4|1")
	check("recursion", lua("local function fib(n) if n < 2 then return n end return fib(n-1) + fib(n-2) end print(fib(15))") == "610")
	check("multiple assign swap", lua("local a, b = 1, 2 a, b = b, a print(a, b)") == "2 1")
	check("long strings/comments", lua("--[[ block\ncomment ]] print([[x\ny]], \"q\\tz\")") == "x\ny q\tz")
	check("no metatables in the game", lua("print(setmetatable, getmetatable, rawget)") == "nil nil nil")
	check("pcall", lua("local ok, e = pcall(function() error('boom') end) print(ok, e)") == "false boom")
	check("bit + getbit", lua("print(getbit(5, 0), getbit(5, 1), bit.band(6, 3))") == "1 0 2", lua("print(getbit(5, 0), getbit(5, 1), bit.band(6, 3))"))
	-- shown from 0: A[1] is A0, and p.index is 0-based too
	check("parts print as names", lua("print(A[1], A[3].group, A[2].index)") == "A0 A 1", lua("print(A[1], A[3].group, A[2].index)"))
	check("globals", lua("x = 5 function add(a) return a + x end print(add(1))") == "6")
	check("no sandbox escape", lua("print(os, io, load, loadstring, dofile, require, debug)") == "nil nil nil nil nil nil nil")
end

-- errors
local function expectError(name, src, pattern, groups)
	local ok, err = LogicScript.run(src, groups or { A = group("a", 3), B = group("b", 2) })
	check(name, not ok and type(err) == "string" and err:find(pattern, 1, true) ~= nil, err)
end

expectError("nil part", "connect(A[5], B)", "line 1: connect needs a part or a list of parts, got nil")
expectError("unknown function", "\n\nconect(A, B)", "line 3: attempt to call a nil value (variable 'conect')")
expectError("missing end", "for i = 1, 3 do\n connect(A[i], B)", "missing 'end' for the 'for' on line 1")
expectError("bad char", "connect(A, B) $", "unexpected character '$'")
expectError("arith on table", "local x = A + 1", "line 1: can't do '+' with a table value")
expectError("old syntax", "A -> B", "'->' is the old script language")
expectError("infinite loop", "while true do end", "ran too long")
expectError("index nil", "local t = nil\nprint(t.x)", "line 2: can't index a nil value (variable 't')")
expectError("bad mode", 'connect(A, B, "zap")', "mode must be \"all\" or \"zip\"")
expectError("error()", "\nerror('my message')", "line 2: my message")
expectError("break outside", "break", "'break' is only allowed inside a loop")
expectError("deep recursion", "local function f() return f() + 1 end f()", "too many nested calls")
expectError("not equal", "if 1 != 2 then end", "use ~= for 'not equal'")
expectError("for syntax", "for i = 1..3 do end", "Lua writes: for i = 1, 10 do")

-- editor helpers
do
	local h = LogicScript.highlight("-- hi #1\nconnect(A, B) local s = \"x\"", nil)
	check("highlight comment", h:find("#6a9955-- hi ##1", 1, true), h)
	check("highlight group colour", h:find("#ff9900A", 1, true) and h:find("#00c8ffB", 1, true), h)
	check("highlight api", h:find("#dcdcaaconnect", 1, true), h)
	check("highlight keyword", h:find("#c586c0local", 1, true), h)
	check("highlight string", h:find('#ce9178"x"', 1, true), h)
	local plain = h:gsub("##", "\0"):gsub("#%x%x%x%x%x%x", ""):gsub("%z", "#")
	check("highlight keeps text", plain == "-- hi #1\nconnect(A, B) local s = \"x\"", plain)
	local he = LogicScript.highlight("a = 1\nb = 2\nc = 3", 2)
	check("highlight error line", he:find("#ff5050b = 2", 1, true), he)
	check("highlight unfinished", type(LogicScript.highlight("x = \"abc\nfor --[[ open")) == "string")
	check("editor raw text cleaned", LogicScript.editorToSource(LogicScript.highlight("print(#A) -- ##")) == "print(#A) -- ##")
	check("backslash", LogicScript.editorToSource(LogicScript.highlight("'\\n'"):gsub("#%x%x%x%x%x%x", "")) == "'\\n'")

	local messy = "for i = 1, 3 do\nif i == 2 then\nconnect(A[i], B)\nelse\nprint(i)   \nend\nend\nlocal f = filter(A, function(p)\nreturn p.x > 0\nend)\nlocal t = {\n1,\n2\n}"
	local want = "for i = 1, 3 do\n    if i == 2 then\n        connect(A[i], B)\n    else\n        print(i)\n    end\nend\nlocal f = filter(A, function(p)\n    return p.x > 0\nend)\nlocal t = {\n    1,\n    2\n}"
	check("format", LogicScript.format(messy) == want, "\n" .. LogicScript.format(messy))
	check("format idempotent", LogicScript.format(want) == want)
	check("format keeps long strings", LogicScript.format("print([[\n  keep\n]])") == "print([[\n  keep\n]])", LogicScript.format("print([[\n  keep\n]])"))
end

---------------------------------------------------------------------------
-- LogicGraph
---------------------------------------------------------------------------

local function mkgraph(spec)
	-- spec: { id = {kind, mode/delay}, ... }, edges: { {from, to}, ... }
	local g = {}
	for id, s in pairs(spec.nodes) do
		local delay = s.delay
		if delay == nil then
			delay = (s.kind == "gate") and 1 or 0
		end
		g[id] = { kind = s.kind, mode = s.mode, delay = delay, children = {}, parents = {} }
	end
	for _, e in ipairs(spec.edges) do
		table.insert(g[e[1]].children, e[2])
		table.insert(g[e[2]].parents, e[1])
	end
	return g
end

do
	-- in -> g1 -> g2 -> g3 -> out ; in -> g3 (shortcut)
	local g = mkgraph({
		nodes = { i = { kind = "input" }, g1 = { kind = "gate", mode = 1 }, g2 = { kind = "gate", mode = 1 },
			g3 = { kind = "gate", mode = 0 }, o = { kind = "output" } },
		edges = { { "i", "g1" }, { "g1", "g2" }, { "g2", "g3" }, { "i", "g3" }, { "g3", "o" } }
	})
	local r = LogicGraph.timing(g, { "i" }, { "g3" })
	check("min path", r.min == 1, r.min)
	check("max path", r.max == 3, r.max)
	check("critical path", table.concat(r.path, ",") == "i,g1,g2,g3", table.concat(r.path, ","))
	check("glitch at g3", #r.glitch == 1 and r.glitch[1] == "g3", table.concat(r.glitch, ","))
	check("no loops", r.loops == 0)
end

do
	-- timer delay: 1 + 40*s + t
	check("timer delay", LogicGraph.timerDelay(1, 5) == 46)
	local g = mkgraph({
		nodes = { i = { kind = "input" }, t = { kind = "timer", delay = LogicGraph.timerDelay(0, 10) }, g = { kind = "gate", mode = 1 } },
		edges = { { "i", "t" }, { "t", "g" } }
	})
	local r = LogicGraph.timing(g, { "i" }, { "g" })
	check("timer path", r.min == 12 and r.max == 12, tostring(r.min) .. "/" .. tostring(r.max))
end

do
	-- SR latch style loop: i -> a <-> b -> o
	local g = mkgraph({
		nodes = { i = { kind = "input" }, a = { kind = "gate", mode = 4 }, b = { kind = "gate", mode = 4 }, o = { kind = "output" } },
		edges = { { "i", "a" }, { "a", "b" }, { "b", "a" }, { "b", "o" } }
	})
	local r = LogicGraph.timing(g, { "i" }, { "o" })
	check("loop min", r.min == 2, r.min)
	check("loop max finite", r.max == 2, r.max)
	check("loop counted", r.loops == 1, r.loops)
end

do
	local g = mkgraph({
		nodes = { i = { kind = "input" }, x = { kind = "gate", mode = 1 }, o = { kind = "output" } },
		edges = { { "i", "x" } }
	})
	local r = LogicGraph.timing(g, { "i" }, { "o", "x" })
	check("unreachable", r.unreachable == 1 and r.min == 1, r.unreachable)
end

do
	local g = mkgraph({
		nodes = { lonely = { kind = "gate", mode = 0 }, x3 = { kind = "gate", mode = 2 },
			a = { kind = "input" }, b = { kind = "input" }, c = { kind = "input" } },
		edges = { { "a", "x3" }, { "b", "x3" }, { "c", "x3" } }
	})
	local issues, counts = LogicGraph.lint(g)
	local text = {}
	for _, it in ipairs(issues) do text[#text + 1] = it.id .. ":" .. it.msg end
	text = table.concat(text, "\n")
	check("lint no inputs", text:find("lonely:AND has no inputs", 1, true), text)
	check("lint xor 3", text:find("x3:XOR has 3 inputs", 1, true), text)
	check("lint counts", counts.gates == 2 and counts.inputs == 3 and counts.modes.XOR == 1)
end

do
	-- truth table of a half adder: s = a XOR b, c = a AND b
	local g = mkgraph({
		nodes = { a = { kind = "input" }, b = { kind = "input" }, s = { kind = "gate", mode = 2 }, c = { kind = "gate", mode = 0 } },
		edges = { { "a", "s" }, { "b", "s" }, { "a", "c" }, { "b", "c" } }
	})
	local rows = LogicGraph.truthTable(g, { "a", "b" }, { "s", "c" })
	local out = {}
	for _, r in ipairs(rows) do
		out[#out + 1] = (r.ins[1] and 1 or 0) .. (r.ins[2] and 1 or 0) .. ">" .. (r.outs[1] and 1 or 0) .. (r.outs[2] and 1 or 0)
		check("settled", r.settled)
	end
	check("half adder", table.concat(out, " ") == "00>00 10>10 01>10 11>01", table.concat(out, " "))
end

do
	-- timer as delay line in the simulator: input on -> output on after delay
	local g = mkgraph({
		nodes = { i = { kind = "input" }, t = { kind = "timer", delay = 5 } },
		edges = { { "i", "t" } }
	})
	local s4 = LogicGraph.simulate(g, { i = true }, 4)
	local s5 = LogicGraph.simulate(g, { i = true }, 5)
	check("timer sim not yet", s4.t == false)
	check("timer sim on", s5.t == true)
	local _, settled = LogicGraph.simulate(g, { i = true }, 100)
	check("timer held on settles", settled == true)
end

do
	-- a NOT-loop clock never settles
	local g = mkgraph({ nodes = { n = { kind = "gate", mode = 3 }, i = { kind = "input" } }, edges = { { "n", "n" }, { "i", "n" } } })
	local _, settled = LogicGraph.simulate(g, { i = true }, 100)
	check("clock never settles", settled == false)
end

do
	-- probe: i -> g1 -> g2 -> g3 ; i -> g3 ; g3 -> o ; timer i -> t(5) -> g3
	local g = mkgraph({
		nodes = { i = { kind = "input" }, g1 = { kind = "gate", mode = 1 }, g2 = { kind = "gate", mode = 1 },
			g3 = { kind = "gate", mode = 0 }, o = { kind = "output" } },
		edges = { { "i", "g1" }, { "g1", "g2" }, { "g2", "g3" }, { "i", "g3" }, { "g3", "o" } }
	})
	local p = LogicGraph.probe(g, { "i" }, false)
	local by = {}
	for _, e in ipairs(p) do by[e.id] = e end
	check("probe count", #p == 4, #p)
	check("probe no source", by.i == nil)
	check("probe g1", by.g1.min == 1 and by.g1.max == 1)
	check("probe g3 range", by.g3.min == 1 and by.g3.max == 3, tostring(by.g3.min) .. "-" .. tostring(by.g3.max))
	check("probe g3 glitch", by.g3.glitch and not by.g2.glitch)
	check("probe o inherits", by.o.min == 1 and by.o.max == 3 and not by.o.glitch)
	check("probe sorted", p[1].min <= p[2].min and p[2].min <= p[3].min)
	check("probe text", LogicGraph.probeText(by.g3) == "1-3t" and LogicGraph.probeText(by.g1) == "1t", LogicGraph.probeText(by.g3))

	-- reverse from o: ticks from a part changing until o changes
	local r = LogicGraph.probe(g, { "o" }, true)
	local rb = {}
	for _, e in ipairs(r) do rb[e.id] = e end
	check("reverse count", #r == 4, #r)
	check("reverse g3", rb.g3.min == 0 and rb.g3.max == 0, tostring(rb.g3.min))
	check("reverse g1", rb.g1.min == 2 and rb.g1.max == 2, tostring(rb.g1.min))
	check("reverse i", rb.i.min == 1 and rb.i.max == 3, tostring(rb.i.min) .. "-" .. tostring(rb.i.max))
	check("reverse no glitch", not rb.i.glitch)
end

do
	-- probe loop marking: i -> a <-> b -> o, plus a -> c -> b (cross edge into the loop)
	local g = mkgraph({
		nodes = { i = { kind = "input" }, a = { kind = "gate", mode = 4 }, b = { kind = "gate", mode = 4 },
			c = { kind = "gate", mode = 1 }, o = { kind = "output" }, n = { kind = "gate", mode = 3 } },
		edges = { { "i", "a" }, { "a", "b" }, { "b", "a" }, { "a", "c" }, { "c", "b" }, { "b", "o" }, { "i", "n" }, { "n", "n" } }
	})
	local p = LogicGraph.probe(g, { "i" }, false)
	local by = {}
	for _, e in ipairs(p) do by[e.id] = e end
	check("loop a", by.a.loop and by.b.loop and by.c.loop)
	check("loop o not", not by.o.loop)
	check("self loop", by.n.loop)
	check("loop text", LogicGraph.probeText(by.a) == "1t+ loop", LogicGraph.probeText(by.a))
	local r = LogicGraph.probe(g, { "o" }, true)
	local rb = {}
	for _, e in ipairs(r) do rb[e.id] = e end
	check("reverse loop", rb.a.loop and rb.c.loop and not rb.i.loop)
end

do
	-- timing unchanged by the reverse refactor
	local g = mkgraph({
		nodes = { i = { kind = "input" }, t = { kind = "timer", delay = 7 }, x = { kind = "gate", mode = 1 } },
		edges = { { "i", "t" }, { "t", "x" } }
	})
	local p = LogicGraph.probe(g, { "i" }, false)
	check("probe timer", p[1].id == "t" and p[1].min == 7 and p[2].min == 8)
end

---------------------------------------------------------------------------
-- LogicModule
---------------------------------------------------------------------------

do
	-- half adder between inputs a, b and outputs s, c; x is an outside part
	-- that also feeds s, and s also drives a lamp outside B
	local g = mkgraph({
		nodes = {
			a = { kind = "input" }, b = { kind = "input" }, x = { kind = "input" },
			n1 = { kind = "gate", mode = 2 }, n2 = { kind = "gate", mode = 0 },
			s = { kind = "gate", mode = 1 }, c = { kind = "gate", mode = 1 }, lamp = { kind = "output" },
		},
		edges = { { "a", "n1" }, { "b", "n1" }, { "a", "n2" }, { "b", "n2" },
			{ "n1", "s" }, { "n2", "c" }, { "x", "n1" }, { "n1", "lamp" } }
	})
	local ins = LogicModule.inside(g, { "a", "b" }, { "s", "c" })
	check("module inside", table.concat(ins.parts, ",") == "n1,n2", table.concat(ins.parts, ","))
	check("module extra in", table.concat(ins.extraIn, ",") == "x", table.concat(ins.extraIn, ","))
	check("module extra out", table.concat(ins.extraOut, ",") == "n1", table.concat(ins.extraOut, ","))

	local m = LogicModule.fromTruth(LogicGraph.truthTable(g, { "a", "b" }, { "s", "c" }), 2, 2)
	-- A1 (a) is the low bit: row 1 = a on, row 2 = b on
	local function outs(addr) return table.concat(m.rows[addr + 1].outs) end
	check("module rows", outs(0) == "00" and outs(1) == "10" and outs(2) == "10" and outs(3) == "01",
		outs(0) .. " " .. outs(1) .. " " .. outs(2) .. " " .. outs(3))
	check("module names", table.concat(m.inputs, ",") == "A0,A1" and table.concat(m.outputs, ",") == "B0,B1")
	check("address bits", table.concat(LogicModule.addressBits(m, 2)) == "01" and table.concat(LogicModule.addressBits(m, 1)) == "10")
	local size = LogicModule.lutSize(m)
	check("lut size", size.inverters == 2 and size.rows == 3 and size.outputs == 2 and size.total == 7, size.total)

	local text, unsettled = LogicModule.tableText(m)
	local lines = {}
	for l in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
	check("table header", lines[1]:find("^10   |   10") ~= nil, lines[1])
	-- row 2 = A2 on; outputs B2 B1 = 0 1 (sum on, carry off)
	check("table row", lines[4] == "10   |   01      2", lines[4])
	check("table row 1", lines[3] == "01   |   01      1", lines[3])
	check("table settled", unsettled == 0 and #lines == 5, #lines)
	local coloured = LogicModule.tableText(m, { colors = { A = "ff9900", B = "00c8ff", one = "ffffff", zero = "707070", text = "ffffff" } })
	check("table colours", coloured:find("#ff990010#ffffff", 1, true) ~= nil and coloured:find("#ffffff1#7070700", 1, true) ~= nil, coloured)
end

do
	-- a loop inside (NOR latch fed back on itself) never settles from all-off? a lone NOT loop does
	local g = mkgraph({
		nodes = { a = { kind = "input" }, n = { kind = "gate", mode = 4 }, o = { kind = "gate", mode = 1 } },
		edges = { { "a", "o" }, { "n", "n" }, { "n", "o" } }
	})
	local m = LogicModule.fromTruth(LogicGraph.truthTable(g, { "a" }, { "o" }, 50), 1, 1)
	local _, unsettled = LogicModule.tableText(m)
	check("unsettled rows counted", unsettled >= 1, unsettled)
end

do
	-- parse the table back, with colour codes and edits
	local m = { inputs = { "A1", "A2" }, outputs = { "B1", "B2" }, rows = {} }
	for a = 1, 4 do m.rows[a] = { outs = { 0, 0 }, settled = true } end
	local text = "#ff990012#ffffff   |   #00c8ff12#ffffff      row\n00   |   #ffffff10      0\n11 | 01  3\n\nnotes are fine"
	local rows, info = LogicModule.parseTable(m, text)
	-- outputs are written B2 B1: "10" is B2 on
	check("parse rows", rows and table.concat(rows[1].outs) == "01" and table.concat(rows[4].outs) == "10"
		and table.concat(rows[2].outs) == "00", rows and "" or info)
	check("parse missing", info and info.listed == 2 and info.missing == 2)
	local r, line, msg = LogicModule.parseTable(m, "00 | 1")
	check("parse short output", r == nil and line == 1 and msg:find("2 output bit", 1, true), msg)
	r, line, msg = LogicModule.parseTable(m, "x\n00 | 10\n00 | 11")
	check("parse duplicate", r == nil and line == 3 and msg:find("twice", 1, true), msg)
	r, line, msg = LogicModule.parseTable(m, "0a | 10")
	check("parse junk", r == nil and line == 1, msg)

	-- LUT plan for a half adder: B1 = XOR (rows 01, 10), B2 = AND (row 11)
	m.rows = { { outs = { 0, 0 } }, { outs = { 1, 0 } }, { outs = { 1, 0 } }, { outs = { 0, 1 } } }
	local plan = LogicModule.lutPlan(m, { bIsGate = { true, false } })
	local c = plan.counts
	check("plan counts", c.buffers == 2 and c.inverters == 2 and c.rows == 3 and c.ors == 1 and c.gates == 8,
		c.buffers .. c.inverters .. c.rows .. c.ors)
	check("plan ticks", plan.ticks == 3)
	local wires = {}
	for _, w in ipairs(plan.wires) do wires[w.from .. ">" .. w.to] = true end
	check("plan row 1 = A1 and not A2", wires["buf1>row1"] and wires["inv2>row1"] and not wires["buf2>row1"])
	check("plan row 11", wires["buf1>row3"] and wires["buf2>row3"])
	check("plan B1 is the OR", plan.modes.B1 == LogicModule.MODE.OR and wires["row1>B1"] and wires["row2>B1"] and not wires["row3>B1"])
	check("plan B2 gets an OR", plan.modes.B2 == nil and wires["row3>or2"] and wires["or2>B2"])
	local moved = {}
	for _, mv in ipairs(plan.moves) do moved[mv.ref] = mv end
	check("plan A line", moved.A1.x == 0 and moved.A1.y == 0 and moved.A2.y == 1)
	check("plan B column after the ORs", moved.B1.x == 4 and moved.B2.y == 1)

	local fewer = LogicModule.lutPlan(m, { even = false, compress = true, bIsGate = { true, true } })
	check("plan fewer gates", fewer.counts.gates == 5 and fewer.ticks == "2-3", fewer.counts.gates .. " " .. tostring(fewer.ticks))
	local same = true
	for _, p in ipairs(fewer.parts) do if p.y ~= 0 or p.z ~= 0 then same = false end end
	check("plan stacked", same and fewer.columns == 2, fewer.columns)
	check("plan text", LogicModule.planText(fewer, true) == "ROM: 2 inverter(s) + 3 row AND(s) = 5 new gate(s), 2-3 ticks, stacked in 2 block(s)",
		LogicModule.planText(fewer, true))

	-- wrapping: 20 rows in one column go 16 high, then one layer up
	local big = { inputs = {}, outputs = { "B1" }, rows = {} }
	for k = 1, 5 do big.inputs[k] = "A" .. k end
	for a = 1, 32 do big.rows[a] = { outs = { a <= 20 and 1 or 0 } } end
	local bp = LogicModule.lutPlan(big, { bIsGate = { true } })
	local maxY, maxZ = 0, 0
	for _, p in ipairs(bp.parts) do
		if p.x == 2 then maxY = math.max(maxY, p.y) maxZ = math.max(maxZ, p.z) end
	end
	check("plan wraps", bp.counts.rows == 20 and maxY == 15 and maxZ == 1, maxY .. " " .. maxZ)

	-- nothing on: no rows, outputs just stay off
	local off = { inputs = { "A1" }, outputs = { "B1" }, rows = { { outs = { 0 } }, { outs = { 0 } } } }
	local op = LogicModule.lutPlan(off, { bIsGate = { true } })
	check("plan empty", op.counts.gates == 0 and #op.wires == 0)
end

do
	-- cells of rotated parts, bounds, placement
	check("cell default", table.concat(LogicModule.cellOf({ pos = { x = 3, y = 4, z = 5 }, xaxis = 1, zaxis = 3 }), ",") == "3,4,5")
	check("cell x backwards", table.concat(LogicModule.cellOf({ pos = { x = 3, y = 4, z = 5 }, xaxis = -1, zaxis = 3 }), ",") == "2,3,5",
		table.concat(LogicModule.cellOf({ pos = { x = 3, y = 4, z = 5 }, xaxis = -1, zaxis = 3 }), ","))
	check("cell block", table.concat(LogicModule.cellOf({ pos = { x = 1, y = 1, z = 1 }, bounds = { x = 4, y = 1, z = 1 } }), ",") == "1,1,1")
	local body = { childs = {
		{ pos = { x = 0, y = 0, z = 0 }, bounds = { x = 6, y = 3, z = 1 }, shapeId = "block" },
		{ pos = { x = 2, y = 1, z = 1 }, xaxis = 1, zaxis = 3, shapeId = "x" },
	} }
	local lo, hi = LogicModule.bodyBounds(body)
	check("bounds", table.concat(lo, ",") == "0,0,0" and table.concat(hi, ",") == "5,2,1", table.concat(hi, ","))
	check("place on top", table.concat(LogicModule.placeOnTop(body), ",") == "0,0,2")

	-- a blueprint: switches s1 s2 -> old XOR gate -> output gate o; the old gate also feeds lamp l (outside)?
	-- no: o is B, x is the old logic, n feeds an outside lamp and must stay
	local function gate(id, x, mode, wires)
		local ctrl = { active = false, id = id, mode = mode }
		if wires then ctrl.controllers = {} for _, w in ipairs(wires) do ctrl.controllers[#ctrl.controllers + 1] = { id = w } end end
		return { pos = { x = x, y = 0, z = 0 }, xaxis = 1, zaxis = 3, shapeId = LogicModule.GATE_UUID, color = "222222", controller = ctrl }
	end
	local s1 = gate(1, 0, nil, { 3, 9 })
	local s2 = gate(2, 1, nil, { 3 })
	local x = gate(3, 2, 2, { 4 })
	local o = gate(4, 3, 0, { 5 })
	local after = gate(5, 4, 1)              -- outside, driven by B: keeps that wire
	local other = gate(9, 5, 1)              -- outside, fed by s1: keeps that wire
	local bp = { bodies = { { childs = {
		{ pos = { x = 0, y = 0, z = 0 }, bounds = { x = 8, y = 1, z = 1 }, shapeId = "block" },
		s1, s2, x, o, after, other } } }, joints = { { id = 40, controller = { id = 50 } } } }
	local m = { inputs = { "A1", "A2" }, outputs = { "B1" }, rows = {
		{ outs = { 0 } }, { outs = { 1 } }, { outs = { 1 } }, { outs = { 0 } } } }
	local plan = LogicModule.lutPlan(m, { bIsGate = { true } })
	local origin = LogicModule.placeOnTop(bp.bodies[1])
	local childOf = LogicModule.applyLut(bp, plan, { body = 1, A = { s1, s2 }, B = { o }, remove = { [x] = true } }, origin)
	local childs = bp.bodies[1].childs
	local present = {}
	for _, c in ipairs(childs) do if c.controller then present[c.controller.id] = c end end
	check("old gate removed", present[3] == nil)
	check("new gates added", #childs == 6 + plan.counts.gates, #childs)
	local function wiresOf(c)
		local t = {}
		for _, w in ipairs(c.controller.controllers or {}) do t[#t + 1] = w.id end
		table.sort(t)
		return table.concat(t, ",")
	end
	check("A1 keeps its outside wire", wiresOf(s1):find("^9,") ~= nil, wiresOf(s1))
	check("A1 feeds its buffer and inverter", wiresOf(s1) == "9," .. childOf.buf1.controller.id .. "," .. childOf.inv1.controller.id, wiresOf(s1))
	check("B keeps its output wire", wiresOf(o) == "5", wiresOf(o))
	check("B is OR", o.controller.mode == LogicModule.MODE.OR)
	check("new ids above joints", childOf.buf1.controller.id == 51, childOf.buf1.controller.id)
	-- row 1 = A1 on, A2 off: fed by A1's buffer and A2's inverter
	check("row 1 wires", wiresOf(childOf.buf1):find(tostring(childOf.row1.controller.id), 1, true) ~= nil
		and wiresOf(childOf.inv2):find(tostring(childOf.row1.controller.id), 1, true) ~= nil
		and wiresOf(childOf.row1) == tostring(o.controller.id), wiresOf(childOf.row1))
	-- the module runs along +Y (A, inputs, rows, B), each column along X
	check("A moved into line on top", s1.pos.x == 0 and s1.pos.y == 0 and s1.pos.z == 1 and s2.pos.x == 1 and s2.pos.y == 0 and s2.pos.z == 1,
		s2.pos.x .. "," .. s2.pos.y .. "," .. s2.pos.z)
	check("B moved to its column", o.pos.x == 0 and o.pos.y == 3 and o.pos.z == 1, o.pos.x .. "," .. o.pos.y .. "," .. o.pos.z)
	check("new gate placed", childOf.row1.pos.y == 2 and childOf.row1.pos.x == 0 and childOf.row1.pos.z == 1 and childOf.row1.shapeId == LogicModule.GATE_UUID)
	check("unwired part has no empty list", childOf.row1.controller.controllers ~= nil and present[5].controller.controllers == nil)

	-- new gates turned like B (a gate), landing exactly in their planned cells
	local function turned(id, x, xa, za, wires)
		local c = gate(id, x, 1, wires)
		c.xaxis, c.zaxis = xa, za
		c.pos = LogicModule.posFor({ x, 0, 0 }, xa, za)
		return c
	end
	local t1, t2 = gate(11, 0, nil, {}), gate(12, 1, nil, {})
	local tb = turned(14, 3, -2, -1)
	local bp2 = { bodies = { { childs = { { pos = { x = 0, y = 0, z = -1 }, bounds = { x = 8, y = 1, z = 1 }, shapeId = "block" }, t1, t2, tb } } } }
	local plan2 = LogicModule.lutPlan(m, { bIsGate = { true } })
	local origin2 = LogicModule.placeOnTop(bp2.bodies[1])
	local c2 = LogicModule.applyLut(bp2, plan2, { body = 1, A = { t1, t2 }, B = { tb }, remove = {} }, origin2)
	local allTurned, allPlaced = true, true
	for _, p in ipairs(plan2.parts) do
		local child = c2[p.ref]
		if child.xaxis ~= -2 or child.zaxis ~= -1 then allTurned = false end
		local cell, want = LogicModule.cellOf(child), LogicModule.toBody(origin2, p.x, p.y, p.z)
		if cell[1] ~= want[1] or cell[2] ~= want[2] or cell[3] ~= want[3] then allPlaced = false end
	end
	check("new gates turned like B", allTurned)
	check("turned gates land in their cells", allPlaced)
	check("B itself lands in its cell", table.concat(LogicModule.cellOf(tb), ",") == table.concat(LogicModule.toBody(origin2, 3, 0, 0), ","),
		table.concat(LogicModule.cellOf(tb), ","))
	-- every rotation round-trips
	local roundTrip = true
	for _, xa in ipairs({ 1, -1, 2, -2, 3, -3 }) do
		for _, za in ipairs({ 1, -1, 2, -2, 3, -3 }) do
			if math.abs(xa) ~= math.abs(za) then
				local c = LogicModule.cellOf({ pos = LogicModule.posFor({ 5, 6, 7 }, xa, za), xaxis = xa, zaxis = za })
				if c[1] ~= 5 or c[2] ~= 6 or c[3] ~= 7 then roundTrip = false end
			end
		end
	end
	check("posFor reverses cellOf for all 24 turns", roundTrip)

	-- the old circuit, all or nothing. q also drives a lamp that isn't B,
	-- so the whole circuit is still in use
	local g = mkgraph({
		nodes = { a = { kind = "input" }, p = { kind = "gate", mode = 0 }, q = { kind = "gate", mode = 0 },
			r = { kind = "gate", mode = 0 }, b = { kind = "gate", mode = 1 }, lamp = { kind = "output" } },
		edges = { { "a", "p" }, { "p", "q" }, { "q", "b" }, { "a", "r" }, { "r", "b" }, { "q", "lamp" } }
	})
	local ins = LogicModule.inside(g, { "a" }, { "b" })
	local oc = LogicModule.oldCircuit(g, ins, { "a" }, { "b" })
	check("old circuit is all of it", table.concat(oc.parts, ",") == "p,q,r", table.concat(oc.parts, ","))
	check("old circuit still used by the lamp", table.concat(oc.usedOutside, ",") == "lamp", table.concat(oc.usedOutside, ","))

	-- a ROM with a dead row (d, feeds nothing) and an unused output (u, not in
	-- B, drives nothing): all of it goes; logic only fed by A (s) is not part of it
	local g2 = mkgraph({
		nodes = { a = { kind = "input" }, inv = { kind = "gate", mode = 4 }, r1 = { kind = "gate", mode = 0 },
			d = { kind = "gate", mode = 0 }, u = { kind = "gate", mode = 1 }, b = { kind = "gate", mode = 1 },
			s = { kind = "gate", mode = 1 }, lamp = { kind = "output" } },
		edges = { { "a", "inv" }, { "inv", "r1" }, { "r1", "b" }, { "inv", "d" }, { "r1", "u" }, { "a", "s" }, { "s", "lamp" } }
	})
	local oc2 = LogicModule.oldCircuit(g2, LogicModule.inside(g2, { "a" }, { "b" }), { "a" }, { "b" })
	check("whole old ROM found", table.concat(oc2.parts, ",") == "d,inv,r1,u", table.concat(oc2.parts, ","))
	check("nothing outside uses it", #oc2.usedOutside == 0)

	-- a compressed ROM's input layer: dead gates fed only by A (and an
	-- input-less gate feeding one) belong to the old circuit; logic fed by A
	-- that lights a lamp elsewhere does not, nor does a dead gate that
	-- other live logic also feeds
	local g4 = mkgraph({
		nodes = { a = { kind = "input" }, b = { kind = "gate", mode = 1 }, row = { kind = "gate", mode = 0 },
			dead1 = { kind = "gate", mode = 0 }, dead2 = { kind = "gate", mode = 4 }, const = { kind = "gate", mode = 0 },
			live = { kind = "gate", mode = 1 }, lamp = { kind = "output" },
			other = { kind = "gate", mode = 1 }, sw = { kind = "input" }, otherDead = { kind = "gate", mode = 0 } },
		edges = { { "a", "row" }, { "row", "b" }, { "a", "dead1" }, { "dead1", "dead2" }, { "const", "dead2" },
			{ "a", "live" }, { "live", "lamp" },
			{ "sw", "other" }, { "other", "lamp" }, { "other", "otherDead" }, { "a", "otherDead" } }
	})
	local oc4 = LogicModule.oldCircuit(g4, LogicModule.inside(g4, { "a" }, { "b" }), { "a" }, { "b" })
	check("dead logic off A is part of the old circuit", table.concat(oc4.parts, ",") == "const,dead1,dead2,row", table.concat(oc4.parts, ","))
	check("live logic fed by A is not", #oc4.usedOutside == 0)

	-- unwired gates stacked in a removed block go too; elsewhere, or wired, they stay
	local function g5(id, x, wires) return gate(id, x, 0, wires) end
	local r1, s1, s2, w1 = g5(31, 4, { 99 }), g5(32, 4), g5(33, 5), g5(34, 4, { 35 })
	local w2 = g5(35, 9)
	local bp5 = { bodies = { { childs = { r1, s1, s2, w1, w2 } } } }
	local strays = LogicModule.strayInCells(bp5, { [r1] = true })
	check("stray in the removed block", #strays == 1 and strays[1] == s1, #strays)

	-- helpers: k (constant-on trick: an AND with no inputs feeding the NAND
	-- input) and its own helper h move with A0; t also drives a lamp, so it
	-- stays; s feeds both inputs and serves the first one
	local g3 = mkgraph({
		nodes = { a0 = { kind = "gate", mode = 3 }, a1 = { kind = "gate", mode = 1 }, k = { kind = "gate", mode = 0 },
			h = { kind = "gate", mode = 1 }, t = { kind = "gate", mode = 1 }, lamp = { kind = "output" },
			s = { kind = "gate", mode = 1 }, sw = { kind = "input" } },
		edges = { { "h", "k" }, { "k", "a0" }, { "t", "a1" }, { "t", "lamp" }, { "s", "a0" }, { "s", "a1" }, { "sw", "h" } }
	})
	local hs = LogicModule.helpers(g3, { "a0", "a1" })
	local got = {}
	for _, h in ipairs(hs) do got[#got + 1] = h.id .. ":" .. h.input .. ":" .. h.depth end
	check("helpers", table.concat(got, ",") == "k:1:1,s:1:1,h:1:2", table.concat(got, ","))
	local hx = LogicModule.helpers(g3, { "a0", "a1" }, { k = true })
	local gotx = {}
	for _, h in ipairs(hx) do gotx[#gotx + 1] = h.id end
	check("excluded part and what only feeds it stay", table.concat(gotx, ",") == "s", table.concat(gotx, ","))

	-- helpers are moved in front of their A, on its line
	local ha, hb = gate(21, 0, 3, {}), gate(22, 1, 1, {})
	local hk, hh = gate(23, 6, 0, { 21 }), gate(24, 7, 1, { 23 })
	local bp3 = { bodies = { { childs = { { pos = { x = 0, y = 0, z = -1 }, bounds = { x = 8, y = 1, z = 1 }, shapeId = "block" }, ha, hb, hk, hh } } } }
	local m3 = { inputs = { "A0" }, outputs = { "B0" }, rows = { { outs = { 0 } }, { outs = { 1 } } } }
	local plan3 = LogicModule.lutPlan(m3, { bIsGate = { true } })
	local o3 = LogicModule.placeOnTop(bp3.bodies[1])
	local _, moves3 = LogicModule.applyLut(bp3, plan3, { body = 1, A = { ha }, B = { hb }, remove = {},
		helpers = { { child = hk, input = 1 }, { child = hh, input = 1 } } }, o3)
	local function cell(c) return table.concat(LogicModule.cellOf(c), ",") end
	check("helper 1 block before A", cell(hk) == table.concat(LogicModule.toBody(o3, -1, 0, 0), ","), cell(hk))
	check("helper 2 blocks before A", cell(hh) == table.concat(LogicModule.toBody(o3, -2, 0, 0), ","), cell(hh))
	check("helper keeps its wire", hh.controller.controllers[1].id == 23 and hk.controller.controllers[1].id == 21)
	check("helpers listed in the moves", #moves3 == 4, #moves3)
end

do
	-- the built LUT does what the table says: wire up a graph from a plan and
	-- simulate it. 3 inputs; only row 1 (A1 alone) and row 6 (A2 + A3) turn B1 on,
	-- and row 4 (A3 alone) turns B2 on.
	local m = { inputs = { "A1", "A2", "A3" }, outputs = { "B1", "B2" }, rows = {} }
	for a = 0, 7 do m.rows[a + 1] = { outs = { (a == 1 or a == 6) and 1 or 0, a == 4 and 1 or 0 } } end
	for _, even in ipairs({ true, false }) do
		local plan = LogicModule.lutPlan(m, { even = even, bIsGate = { true, true } })
		local nodes = { A1 = { kind = "input" }, A2 = { kind = "input" }, A3 = { kind = "input" },
			B1 = { kind = "gate", mode = plan.modes.B1 }, B2 = { kind = "gate", mode = plan.modes.B2 } }
		for _, p in ipairs(plan.parts) do nodes[p.ref] = { kind = "gate", mode = p.mode } end
		local edges = {}
		for _, w in ipairs(plan.wires) do edges[#edges + 1] = { w.from, w.to } end
		local g = mkgraph({ nodes = nodes, edges = edges })
		local rows = LogicGraph.truthTable(g, { "A1", "A2", "A3" }, { "B1", "B2" })
		local built = LogicModule.fromTruth(rows, 3, 2)
		check("built LUT matches its table (even=" .. tostring(even) .. ")", LogicModule.sameRows(built.rows, m.rows))
		local only1 = rows[2] -- truthTable row 2 = A1 on only
		check("A1 alone turns B1 on (even=" .. tostring(even) .. ")", only1.ins[1] and not only1.ins[2] and only1.outs[1] and not only1.outs[2])
	end
	local text = LogicModule.tableText(m)
	check("row 1 shows as 001", text:find("\n001   |   01      1", 1, true) ~= nil, text)
	check("row 4 shows as 100", text:find("\n100   |   10      4", 1, true) ~= nil, text)
end

do
	-- XOR style (PPRM)
	local function mod(nIn, nOut, f)
		local m = { inputs = {}, outputs = {}, rows = {} }
		for k = 1, nIn do m.inputs[k] = "A" .. (k - 1) end
		for k = 1, nOut do m.outputs[k] = "B" .. (k - 1) end
		for a = 0, 2 ^ nIn - 1 do
			local o = {}
			for j = 1, nOut do o[j] = f(a, j) end
			m.rows[a + 1] = { outs = o }
		end
		return m
	end
	-- half adder: B0 = A0 xor A1, B1 = A0 and A1
	local ha = mod(2, 2, function(a, j)
		local x, y = a % 2, math.floor(a / 2) % 2
		if j == 1 then return (x + y) % 2 end
		return x * y
	end)
	local coef = LogicModule.pprm(ha)
	check("pprm sum = A0 + A1", table.concat(coef[1]) == "0110", table.concat(coef[1]))
	check("pprm carry = A0A1", table.concat(coef[2]) == "0001", table.concat(coef[2]))
	local xp = LogicModule.lutPlan(ha, { style = "xor", bIsGate = { true, true } })
	check("xor plan", xp.style == "xor" and xp.counts.terms == 3 and xp.counts.gates == 3 and xp.ticks == 2 and #xp.problems == 0,
		xp.counts.terms .. " " .. tostring(xp.ticks))
	check("xor B modes", xp.modes.B1 == LogicModule.MODE.XOR and xp.modes.B2 == LogicModule.MODE.XOR)
	local fx = LogicModule.lutPlan(ha, { style = "xor", even = false, bIsGate = { true, true } })
	check("xor fewer gates: single terms wired straight", fx.counts.terms == 1 and fx.ticks == "1-2", fx.counts.terms .. " " .. tostring(fx.ticks))
	local auto = LogicModule.lutPlan(ha, { style = "auto", bIsGate = { true, true } })
	check("auto picks the smaller", auto.style == "xor" and auto.auto.rom == 7 and auto.auto.xor == 3, auto.style)
	check("auto text", LogicModule.planText(auto) == "Auto picked XOR (ROM 7, XOR 3 gates): 3 term AND(s) = 3 new gate(s), 2 ticks",
		LogicModule.planText(auto))

	-- NOR of 2: row 0 is 1, so the constant term makes B an XNOR
	local nor = mod(2, 1, function(a) return a == 0 and 1 or 0 end)
	local np = LogicModule.lutPlan(nor, { style = "xor", bIsGate = { true } })
	check("xnor for a constant term", np.modes.B1 == LogicModule.MODE.XNOR, np.modes.B1)

	-- always on: XOR can't, ROM can; auto picks ROM
	local on = mod(2, 1, function() return 1 end)
	local op = LogicModule.lutPlan(on, { style = "xor", bIsGate = { true } })
	check("xor can't build constant 1", #op.problems == 1 and op.problems[1]:find("B0 is always on", 1, true), op.problems[1])
	check("auto avoids it", LogicModule.lutPlan(on, { style = "auto", bIsGate = { true } }).style == "rom")

	-- the game's 255 limit: an 8-input ROM output that is on in every row
	local all = mod(8, 1, function() return 1 end)
	local ap = LogicModule.lutPlan(all, { style = "rom", bIsGate = { true } })
	check("255 limit found", #ap.problems == 1 and ap.problems[1] == "B0 would get 256 inputs (the game allows 255)", ap.problems[1])

	-- every style and timing builds exactly its table: wire a graph from the
	-- plan and simulate it, for random tables (fixed seed)
	local seed = 12345
	local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648 return seed end
	local allOk, tried = true, 0
	for _, nIn in ipairs({ 1, 2, 3, 4 }) do
		for _ = 1, 6 do
			local m = mod(nIn, 2, function() return math.floor(rnd() / 65536) % 2 end)
			for _, style in ipairs({ "rom", "xor" }) do
				for _, even in ipairs({ true, false }) do
					local plan = LogicModule.lutPlan(m, { style = style, even = even, bIsGate = { true, false } })
					if #plan.problems == 0 then
						tried = tried + 1
						local nodes, ins = {}, {}
						for k = 1, nIn do nodes["A" .. k] = { kind = "input" } ins[k] = "A" .. k end
						nodes.B1 = { kind = "gate", mode = plan.modes.B1 }
						nodes.B2 = { kind = "output" }
						for _, p in ipairs(plan.parts) do nodes[p.ref] = { kind = "gate", mode = p.mode } end
						local edges = {}
						for _, w in ipairs(plan.wires) do edges[#edges + 1] = { w.from, w.to } end
						local rows = LogicGraph.truthTable(mkgraph({ nodes = nodes, edges = edges }), ins, { "B1", "B2" })
						if not LogicModule.sameRows(LogicModule.fromTruth(rows, nIn, 2).rows, m.rows) then
							allOk = false
							print("  mismatch: style " .. style .. " even " .. tostring(even) .. " inputs " .. nIn)
						end
					end
				end
			end
		end
	end
	check("every plan builds its table (" .. tried .. " plans)", allOk and tried > 80, tried)
end

do
	-- a player's 3-in / 7-out table driving lamps: never-on outputs need no
	-- gate, and with Fewer gates a one-term output is wired straight to its lamp
	local rows = { "0001110", "0001000", "0000010", "0001010", "0100000", "0101001", "0100010", "0101011" }
	local m = { inputs = { "A0", "A1", "A2" }, outputs = {}, rows = {} }
	for k = 1, 7 do m.outputs[k] = "B" .. (k - 1) end
	for a, r in ipairs(rows) do
		local o = {}
		for k = 1, 7 do o[k] = tonumber(r:sub(8 - k, 8 - k)) end
		m.rows[a] = { outs = o }
	end
	local lamps = { false, false, false, false, false, false, false }
	local xf = LogicModule.lutPlan(m, { style = "xor", even = false, bIsGate = lamps })
	check("lamps, XOR, fewer gates: 7 gates", xf.counts.gates == 7 and xf.counts.terms == 4 and xf.counts.outs == 3,
		LogicModule.planText(xf))
	local xe = LogicModule.lutPlan(m, { style = "xor", even = true, bIsGate = lamps })
	check("lamps, XOR, even: 12 gates", xe.counts.gates == 12, LogicModule.planText(xe))
	local rf = LogicModule.lutPlan(m, { style = "rom", even = false, bIsGate = lamps })
	check("lamps, ROM, fewer gates: 15 gates", rf.counts.gates == 15, LogicModule.planText(rf))
	local wires = {}
	for _, w in ipairs(xf.wires) do wires[w.from .. ">" .. w.to] = true end
	check("B5 = A2, wired straight", wires["A3>B6"] == true)
	check("B0 = A0 A2, its AND wired straight", wires["term5>B1"] == true)
	local feedsB4 = false
	for _, w in ipairs(xf.wires) do if w.to == "B5" or w.to == "B7" then feedsB4 = true end end
	check("never-on outputs get nothing", not feedsB4)
	check("ticks measured from the wiring", xf.ticks == "0-2" and xe.ticks == 2, tostring(xf.ticks) .. " " .. tostring(xe.ticks))
	check("ticks with no bIsGate given", LogicModule.lutPlan(m, { style = "rom" }).ticks == 3)
end

---------------------------------------------------------------------------
-- Tick debugger
---------------------------------------------------------------------------

do
	-- the player's test: a = AND with no inputs; a -> or1 -> and1 -> and2 -> or1
	-- (a loop); a -> xor (wired to itself); or1, xor -> b (OR)
	local g = mkgraph({
		nodes = { a = { kind = "gate", mode = 0 }, or1 = { kind = "gate", mode = 1 }, and1 = { kind = "gate", mode = 0 },
			and2 = { kind = "gate", mode = 0 }, xor = { kind = "gate", mode = 2 }, b = { kind = "gate", mode = 1 } },
		edges = { { "a", "or1" }, { "or1", "and1" }, { "and1", "and2" }, { "and2", "or1" }, { "a", "xor" },
			{ "xor", "xor" }, { "or1", "b" }, { "xor", "b" } }
	})
	local parts = { "a", "b", "or1", "and1", "and2", "xor" }
	local held = LogicGraph.debugStart(g, parts, {}, { "a" }, { true })
	local xs = {}
	for _ = 1, 6 do LogicGraph.debugForward(held) xs[#xs + 1] = held.state.values.xor and "1" or "0" end
	check("debug held: xor with a held on flips every tick", table.concat(xs) == "101010", table.concat(xs))
	local pulse = LogicGraph.debugStart(g, parts, {}, { "a" }, { true }, { mode = "pulse" })
	local bs = {}
	xs = {}
	for _ = 1, 8 do
		LogicGraph.debugForward(pulse)
		xs[#xs + 1] = pulse.state.values.xor and "1" or "0"
		bs[#bs + 1] = pulse.state.values.b and "1" or "0"
	end
	check("debug pulse: a back off after 1 tick", pulse.state.values.a == false and pulse.changes[1][1] ~= nil)
	check("debug pulse: xor toggles once and stays on", table.concat(xs) == "11111111", table.concat(xs))
	check("debug pulse: b stays on", table.concat(bs) == "01111111", table.concat(bs))

	-- countdown: at tick 0 of Held, or1 changes next tick, and1 in 2, and2 in 3, b in 2
	local d = LogicGraph.debugStart(g, parts, {}, { "a" }, { true })
	local ahead = LogicGraph.debugLookahead(d, parts, 64)
	check("lookahead: ticks until each part changes", ahead.or1 == 1 and ahead.and1 == 2 and ahead.and2 == 3
		and ahead.b == 2 and ahead.xor == 1 and ahead.a == nil,
		string.format("%s %s %s %s", tostring(ahead.or1), tostring(ahead.and1), tostring(ahead.and2), tostring(ahead.b)))
	LogicGraph.debugForward(d)
	ahead = LogicGraph.debugLookahead(d, parts, 64)
	check("lookahead counts down", ahead.and1 == 1 and ahead.and2 == 2 and ahead.b == 1 and ahead.or1 == nil)
	check("lookahead leaves the session alone", d.tick == 1 and d.state.values.and1 == false)
	check("xor memory found", LogicGraph.isXorMemory(g, "xor") and not LogicGraph.isXorMemory(g, "or1")
		and not LogicGraph.isXorMemory(g, "b"))
end

do
	-- repeat: inputs "101" every 3 ticks; a0 and a2 pulse, a1 stays off
	local g = mkgraph({
		nodes = { a0 = { kind = "input" }, a1 = { kind = "input" }, a2 = { kind = "input" },
			b0 = { kind = "gate", mode = 1 }, b1 = { kind = "gate", mode = 1 }, b2 = { kind = "gate", mode = 1 } },
		edges = { { "a0", "b0" }, { "a1", "b1" }, { "a2", "b2" } }
	})
	local parts = { "a0", "a1", "a2", "b0", "b1", "b2" }
	local d = LogicGraph.debugStart(g, parts, { a1 = true }, { "a0", "a1", "a2" }, { true, false, true },
		{ mode = "repeat", every = 3 })
	local a0, a1, b0 = { "1" }, { "0" }, { "0" }
	for _ = 1, 7 do
		LogicGraph.debugForward(d)
		local v = d.state.values
		a0[#a0 + 1], a1[#a1 + 1], b0[#b0 + 1] = v.a0 and "1" or "0", v.a1 and "1" or "0", v.b0 and "1" or "0"
	end
	check("repeat: a0 pulses every 3", table.concat(a0) == "10010010", table.concat(a0))
	check("repeat: a1 (0) stays off", table.concat(a1) == "00000000", table.concat(a1))
	check("repeat: b0 follows 1 tick later", table.concat(b0) == "01001001", table.concat(b0))
	check("repeat never settles", not LogicGraph.debugSettled(d))
	LogicGraph.debugBack(d)
	LogicGraph.debugBack(d)
	LogicGraph.debugForward(d)
	check("repeat: replay matches", d.tick == 6 and d.state.values.a0 == true and d.state.values.b0 == false)
	local ahead = LogicGraph.debugLookahead(d, parts, 64)
	check("repeat: countdown knows the next pulse", ahead.b0 == 1 and ahead.a0 == 1 and ahead.a2 == 1 and ahead.b1 == nil)
end

do
	-- a change blocked by an AND never arrives: no countdown there
	local g = mkgraph({
		nodes = { a = { kind = "input" }, off = { kind = "input" }, x = { kind = "gate", mode = 0 }, y = { kind = "gate", mode = 1 } },
		edges = { { "a", "x" }, { "off", "x" }, { "a", "y" } }
	})
	local d = LogicGraph.debugStart(g, { "a", "x", "y" }, {}, { "a" }, { true })
	local ahead = LogicGraph.debugLookahead(d, { "a", "x", "y" }, 64)
	check("lookahead: blocked AND gets none", ahead.x == nil and ahead.y == 1)
end

do
	-- a clock beside the circuit: clk (NOR wired to itself) -> x (AND) <- a; x -> b
	local g = mkgraph({
		nodes = { a = { kind = "input" }, clk = { kind = "gate", mode = 4 }, x = { kind = "gate", mode = 0 },
			b = { kind = "gate", mode = 1 } },
		edges = { { "clk", "clk" }, { "clk", "x" }, { "a", "x" }, { "x", "b" } }
	})
	local d = LogicGraph.debugStart(g, { "a", "x", "b" }, { clk = true }, { "a" }, { true })
	local seen = {}
	for _ = 1, 6 do
		LogicGraph.debugForward(d)
		seen[#seen + 1] = d.state.values.b and "1" or "0"
	end
	check("debug: clock beside keeps running", d.graph.clk ~= nil and table.concat(seen):find("1010", 1, true) ~= nil,
		table.concat(seen))
	check("debug: a clock never settles", not LogicGraph.debugSettled(d))
end

do
	-- a loop through the input: a (OR) <- loop (OR) <- a ; a -> b. One kick at
	-- tick 0 keeps going round (the game does the same): b blinks every 2 ticks.
	local g = mkgraph({
		nodes = { a = { kind = "gate", mode = 1 }, loop = { kind = "gate", mode = 1 }, b = { kind = "gate", mode = 1 } },
		edges = { { "a", "loop" }, { "loop", "a" }, { "a", "b" } }
	})
	local held = LogicGraph.debugStart(g, { "a", "b" }, {}, { "a" }, { true })
	local once = LogicGraph.debugStart(g, { "a", "b" }, {}, { "a" }, { true }, { mode = "free" })
	check("debug: held input cuts the loop upstream", held.graph.loop == nil and once.graph.loop ~= nil)
	local bs = {}
	for _ = 1, 6 do
		LogicGraph.debugForward(once)
		bs[#bs + 1] = once.state.values.b and "1" or "0"
	end
	check("debug: set once, the kick goes round the loop", table.concat(bs) == "101010", table.concat(bs))
	-- a self-wired OR keeps itself on once kicked
	local latch = LogicGraph.debugStart(mkgraph({ nodes = { a = { kind = "gate", mode = 1 }, b = { kind = "gate", mode = 1 } },
		edges = { { "a", "a" }, { "a", "b" } } }), { "a", "b" }, {}, { "a" }, { true }, { mode = "free" })
	for _ = 1, 4 do LogicGraph.debugForward(latch) end
	check("debug: set once, a self-wired OR stays on", latch.state.values.a and latch.state.values.b and LogicGraph.debugSettled(latch))
	local pulse = LogicGraph.debugStart(mkgraph({ nodes = { a = { kind = "gate", mode = 1 }, b = { kind = "gate", mode = 1 } },
		edges = { { "a", "b" } } }), { "a", "b" }, {}, { "a" }, { true }, { mode = "free" })
	for _ = 1, 3 do LogicGraph.debugForward(pulse) end
	check("debug: set once with no inputs = a 1 tick pulse", pulse.state.values.a == false and pulse.state.values.b == false
		and LogicGraph.debugChangeCounts(pulse, { "b" }).b == 2)
end

local function sorted(list)
	local o = {}
	for i, v in ipairs(list) do o[i] = v end
	table.sort(o)
	return table.concat(o, ",")
end

do
	-- a -> n1 (NOR) -> n2 (NOR) -> b ; a -> x (AND) -> b (OR) ; ext -> x
	-- In the game now: a off, so n1 on, n2 off, x off, b off. ext (outside) is on.
	local g = mkgraph({
		nodes = { a = { kind = "input" }, n1 = { kind = "gate", mode = 4 }, n2 = { kind = "gate", mode = 4 },
			x = { kind = "gate", mode = 0 }, b = { kind = "gate", mode = 1 }, ext = { kind = "input" },
			after = { kind = "gate", mode = 1 } },
		edges = { { "a", "n1" }, { "n1", "n2" }, { "n2", "b" }, { "a", "x" }, { "ext", "x" }, { "x", "b" }, { "b", "after" } }
	})
	local snap = { a = false, n1 = true, n2 = false, x = false, b = false, ext = true }
	local d = LogicGraph.debugStart(g, { "a", "n1", "n2", "x", "b" }, snap, { "a" }, { true })
	check("debug: tick 0 is the input change", d.tick == 0 and sorted(d.changes[0]) == "a")
	check("debug: what feeds it runs along", d.graph.ext ~= nil and d.forced.ext == nil and d.state.values.ext == true
		and d.graph.after == nil)
	check("debug: not settled at start", not LogicGraph.debugSettled(d))
	LogicGraph.debugForward(d)
	check("debug: tick 1 = n1 off, x on", sorted(d.changes[1]) == "n1,x", sorted(d.changes[1]))
	LogicGraph.debugForward(d)
	check("debug: tick 2 = n2 on, b on", sorted(d.changes[2]) == "b,n2", sorted(d.changes[2]))
	LogicGraph.debugForward(d)
	check("debug: tick 3 quiet", #d.changes[3] == 0 and LogicGraph.debugSettled(d))
	check("debug: last change at 2", LogicGraph.debugLastChange(d) == 2)
	check("debug: b on", d.state.values.b == true)

	LogicGraph.debugBack(d)
	LogicGraph.debugBack(d)
	check("debug: back to tick 1", d.tick == 1 and d.state.values.n1 == false and d.state.values.x == true
		and d.state.values.n2 == false and d.state.values.b == false)
	LogicGraph.debugBack(d)
	check("debug: back to the start", d.tick == 0 and d.state.values.n1 == true and d.state.values.a == true)
	check("debug: can't go before 0", LogicGraph.debugBack(d) == false and d.tick == 0)
	LogicGraph.debugForward(d)
	LogicGraph.debugForward(d)
	check("debug: replay gives the same", d.tick == 2 and d.last == 3 and d.state.values.b == true and d.state.values.n2 == true)
	check("debug: b changed once", LogicGraph.debugChangeCounts(d, { "b" }).b == 1)
end

do
	-- glitch: a -> b (XOR) directly and through a NOT: b pulses for 1 tick
	local g = mkgraph({
		nodes = { a = { kind = "input" }, n = { kind = "gate", mode = 4 }, buf = { kind = "gate", mode = 1 },
			b = { kind = "gate", mode = 2 } },
		edges = { { "a", "n" }, { "a", "buf" }, { "n", "b" }, { "buf", "b" } }
	})
	-- settled with a off: n on, buf off, b on
	local d = LogicGraph.debugStart(g, { "a", "n", "buf", "b" }, { n = true, b = true }, { "a" }, { true })
	for _ = 1, 4 do LogicGraph.debugForward(d) end
	check("debug: even paths, no glitch", LogicGraph.debugChangeCounts(d, { "b" }).b == 0 and d.state.values.b == true)

	local g2 = mkgraph({
		nodes = { a = { kind = "input" }, n = { kind = "gate", mode = 4 }, b = { kind = "gate", mode = 2 } },
		edges = { { "a", "n" }, { "a", "b" }, { "n", "b" } }
	})
	local d2 = LogicGraph.debugStart(g2, { "a", "n", "b" }, { n = true, b = true }, { "a" }, { true })
	for _ = 1, 4 do LogicGraph.debugForward(d2) end
	check("debug: uneven paths glitch", LogicGraph.debugChangeCounts(d2, { "b" }).b == 2)
end

do
	-- timer: delay line starts full of its current value, so a settled timer
	-- stays quiet until the change reaches it
	local g = mkgraph({
		nodes = { a = { kind = "input" }, t = { kind = "timer", delay = 3 }, b = { kind = "gate", mode = 1 } },
		edges = { { "a", "t" }, { "t", "b" } }
	})
	local d = LogicGraph.debugStart(g, { "a", "t", "b" }, { a = true, t = true, b = true }, { "a" }, { false })
	LogicGraph.debugForward(d)
	check("debug timer: not out yet", #d.changes[1] == 0 and not LogicGraph.debugSettled(d))
	LogicGraph.debugForward(d)
	LogicGraph.debugForward(d)
	check("debug timer: out after 3 ticks", sorted(d.changes[3]) == "t", sorted(d.changes[3]))
	LogicGraph.debugForward(d)
	check("debug timer: b after 4", sorted(d.changes[4]) == "b")
	LogicGraph.debugBack(d)
	LogicGraph.debugBack(d)
	LogicGraph.debugForward(d)
	LogicGraph.debugForward(d)
	check("debug timer: replay", d.state.values.b == false and d.state.values.t == false)
	LogicGraph.debugForward(d)
	check("debug timer: then settled", LogicGraph.debugSettled(d))

	local same = LogicGraph.debugStart(g, { "a", "t", "b" }, { a = true, t = true, b = true }, { "a" }, { true })
	check("debug: same inputs = settled at once", #same.changes[0] == 0 and LogicGraph.debugSettled(same))
end

print(string.format("%d passed, %d failed", passed, failures))
return failures
