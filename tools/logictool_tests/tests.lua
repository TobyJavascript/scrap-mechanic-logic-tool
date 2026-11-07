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
	check("parts print as names", lua("print(A[1], A[3].group, A[2].index)") == "A1 A 2")
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

print(string.format("%d passed, %d failed", passed, failures))
return failures
