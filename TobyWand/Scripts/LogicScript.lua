-- LogicScript: TobyWand's script engine. Scripts are written in Lua.
--
-- Scrap Mechanic's sandbox has no load/loadstring, so a mod can't run Lua
-- typed in game. This file is a small Lua 5.1 interpreter written in Lua:
-- the script is tokenised, parsed, and compiled into Lua closures that run
-- in a sandbox with a step limit. Script functions are real Lua functions,
-- so table.sort, pcall, string.gsub etc. can call them.
--
-- Not supported: goto, coroutines, os/io, load. Everything else in Lua 5.1
-- (locals, closures, varargs, tables, metatables, methods) works.
--
-- Also here: syntax highlighting and formatting for the editor.
--
-- Pure Lua (no game API), so it can be tested outside the game.

LogicScript = LogicScript or {}

local MAX_STEPS = 2000000
local MAX_OPS = 20000
local MAX_OUTPUT = 400

-- The game's sandbox has no setmetatable/getmetatable/rawget/rawset, so
-- this file must not use them. Objects get their methods copied in.
local unpack = unpack or table.unpack
local function pack(...) return { n = select("#", ...), ... } end
local function new(class, obj)
	for k, v in pairs(class) do obj[k] = v end
	return obj
end

---------------------------------------------------------------------------
-- Lexer
---------------------------------------------------------------------------

local KEYWORDS = {}
for w in ("and break do else elseif end false for function if in local nil not or repeat return then true until while"):gmatch("%a+") do
	KEYWORDS[w] = true
end

local ESCAPES = { a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v", ["\\"] = "\\", ['"'] = '"', ["'"] = "'", ["\n"] = "\n" }

local function syntaxError(line, msg)
	error({ line = line, msg = msg }, 0)
end

-- Long bracket at position i ("[[", "[==[" ...): returns level or nil.
local function longOpen(src, i)
	local eq = src:match("^%[(=*)%[", i)
	return eq and #eq or nil
end

local function lex(src)
	local toks = {}
	local i, line, n = 1, 1, #src
	local function add(t, v, l) toks[#toks + 1] = { t = t, v = v, line = l or line } end
	while i <= n do
		local c = src:sub(i, i)
		if c == "\n" then
			line = line + 1
			i = i + 1
		elseif c:match("%s") then
			i = i + 1
		elseif src:sub(i, i + 1) == "--" then
			local lvl = longOpen(src, i + 2)
			if lvl then
				local close = "]" .. ("="):rep(lvl) .. "]"
				local s, e = src:find(close, i, true)
				if not s then syntaxError(line, "unfinished long comment") end
				for _ in src:sub(i, e):gmatch("\n") do line = line + 1 end
				i = e + 1
			else
				local e = src:find("\n", i, true) or n + 1
				i = e
			end
		elseif c:match("[%a_]") then
			local w = src:match("^[%w_]+", i)
			add(KEYWORDS[w] and "kw" or "name", w)
			i = i + #w
		elseif c:match("%d") or (c == "." and src:sub(i + 1, i + 1):match("%d")) then
			local num = src:match("^0[xX]%x+", i)
				or src:match("^%d*%.?%d*[eE][%+%-]?%d+", i)
				or src:match("^%d*%.?%d*", i)
			local v = tonumber(num)
			if not v then syntaxError(line, "malformed number '" .. num .. "'") end
			add("num", v)
			i = i + #num
		elseif c == '"' or c == "'" then
			local startLine = line
			local buf = {}
			local j = i + 1
			while true do
				local d = src:sub(j, j)
				if d == "" or d == "\n" then syntaxError(startLine, "unfinished string") end
				if d == c then break end
				if d == "\\" then
					local e = src:sub(j + 1, j + 1)
					if ESCAPES[e] then
						buf[#buf + 1] = ESCAPES[e]
						if e == "\n" then line = line + 1 end
						j = j + 2
					elseif e:match("%d") then
						local digits = src:match("^%d%d?%d?", j + 1)
						local code = tonumber(digits)
						if code > 255 then syntaxError(line, "escape sequence too large") end
						buf[#buf + 1] = string.char(code)
						j = j + 1 + #digits
					else
						syntaxError(line, "invalid escape sequence '\\" .. e .. "'")
					end
				else
					buf[#buf + 1] = d
					j = j + 1
				end
			end
			add("str", table.concat(buf), startLine)
			i = j + 1
		elseif c == "[" and longOpen(src, i) then
			local lvl = longOpen(src, i)
			local close = "]" .. ("="):rep(lvl) .. "]"
			local bodyStart = i + lvl + 2
			local s, e = src:find(close, bodyStart, true)
			if not s then syntaxError(line, "unfinished long string") end
			local body = src:sub(bodyStart, s - 1)
			if body:sub(1, 1) == "\n" then body = body:sub(2) end
			add("str", body)
			for _ in src:sub(i, e):gmatch("\n") do line = line + 1 end
			i = e + 1
		else
			local three = src:sub(i, i + 2)
			local two = src:sub(i, i + 1)
			if three == "..." then
				add("op", "...")
				i = i + 3
			elseif two == "==" or two == "~=" or two == "<=" or two == ">=" or two == ".." then
				add("op", two)
				i = i + 2
			elseif c:match("[%+%-%*/%%%^#<>=%(%){}%[%];:,%.]") then
				add("op", c)
				i = i + 1
			elseif c == "!" and src:sub(i + 1, i + 1) == "=" then
				syntaxError(line, "use ~= for 'not equal' in Lua")
			else
				syntaxError(line, "unexpected character '" .. c .. "'")
			end
		end
	end
	add("eof", "<eof>")
	return toks
end

---------------------------------------------------------------------------
-- Parser: tokens -> AST
---------------------------------------------------------------------------

local Parser = {}

function Parser:peek(k) return self.toks[self.i + (k or 0)] end
function Parser:next()
	local t = self.toks[self.i]
	self.i = self.i + 1
	return t
end
function Parser:is(t, v)
	local tok = self.toks[self.i]
	return tok.t == t and (v == nil or tok.v == v)
end
function Parser:isOp(v) return self:is("op", v) end
function Parser:isKw(v) return self:is("kw", v) end
function Parser:accept(t, v)
	if self:is(t, v) then return self:next() end
end
function Parser:describe(tok)
	if tok.t == "eof" then return "the end of the script" end
	if tok.t == "str" then return "a string" end
	return "'" .. tostring(tok.v) .. "'"
end
function Parser:expect(t, v, context)
	local tok = self:peek()
	if tok.t == t and (v == nil or tok.v == v) then return self:next() end
	local want = v and ("'" .. v .. "'") or t
	syntaxError(tok.line, "expected " .. want .. (context and (" " .. context) or "") .. " near " .. self:describe(tok))
end
function Parser:name()
	local tok = self:peek()
	if tok.t ~= "name" then
		if tok.t == "kw" then
			syntaxError(tok.line, "'" .. tok.v .. "' is a Lua keyword and can't be used as a name")
		end
		syntaxError(tok.line, "expected a name near " .. self:describe(tok))
	end
	return self:next().v
end

local function blockEnd(p)
	local tok = p:peek()
	return tok.t == "eof" or (tok.t == "kw" and (tok.v == "end" or tok.v == "else" or tok.v == "elseif" or tok.v == "until"))
end

function Parser:block()
	local stats = {}
	while not blockEnd(self) do
		if self:isKw("return") then
			local line = self:next().line
			local exprs = {}
			if not blockEnd(self) and not self:isOp(";") then exprs = self:exprList() end
			self:accept("op", ";")
			stats[#stats + 1] = { k = "Return", exprs = exprs, line = line }
			if not blockEnd(self) then
				syntaxError(self:peek().line, "'return' must be the last statement in a block")
			end
			break
		end
		local s = self:statement()
		if s then stats[#stats + 1] = s end
	end
	return stats
end

function Parser:closeBlock(opener, line)
	local tok = self:peek()
	if not (tok.t == "kw" and tok.v == "end") then
		syntaxError(tok.line, "missing 'end' for the '" .. opener .. "' on line " .. line)
	end
	self:next()
end

function Parser:funcBody(line, isMethod)
	local params, vararg = {}, false
	if isMethod then params[1] = "self" end
	self:expect("op", "(", "to start the parameters")
	if not self:isOp(")") then
		repeat
			if self:accept("op", "...") then
				vararg = true
				break
			end
			params[#params + 1] = self:name()
		until not self:accept("op", ",")
	end
	self:expect("op", ")", "after the parameters")
	local body = self:block()
	self:closeBlock("function", line)
	return { k = "Function", params = params, vararg = vararg, body = body, line = line }
end

function Parser:statement()
	local tok = self:peek()
	local line = tok.line
	if tok.t == "op" and tok.v == ";" then
		self:next()
		return nil
	end
	if tok.t == "kw" then
		local v = tok.v
		if v == "if" then
			self:next()
			local clauses = {}
			local cond = self:expr()
			self:expect("kw", "then", "after the 'if' condition")
			clauses[1] = { cond = cond, body = self:block() }
			local elseBody
			while true do
				if self:accept("kw", "elseif") then
					local c = self:expr()
					self:expect("kw", "then", "after the 'elseif' condition")
					clauses[#clauses + 1] = { cond = c, body = self:block() }
				elseif self:accept("kw", "else") then
					elseBody = self:block()
					self:closeBlock("if", line)
					break
				else
					self:closeBlock("if", line)
					break
				end
			end
			return { k = "If", clauses = clauses, elseBody = elseBody, line = line }
		elseif v == "while" then
			self:next()
			local cond = self:expr()
			self:expect("kw", "do", "after the 'while' condition")
			local body = self:block()
			self:closeBlock("while", line)
			return { k = "While", cond = cond, body = body, line = line }
		elseif v == "do" then
			self:next()
			local body = self:block()
			self:closeBlock("do", line)
			return { k = "Do", body = body, line = line }
		elseif v == "for" then
			self:next()
			local first = self:name()
			if self:accept("op", "=") then
				local start = self:expr()
				self:expect("op", ",", "in the 'for' loop (Lua writes: for i = 1, 10 do)")
				local stop = self:expr()
				local step
				if self:accept("op", ",") then step = self:expr() end
				self:expect("kw", "do", "after the 'for' range")
				local body = self:block()
				self:closeBlock("for", line)
				return { k = "NumFor", var = first, start = start, stop = stop, step = step, body = body, line = line }
			end
			local names = { first }
			while self:accept("op", ",") do names[#names + 1] = self:name() end
			self:expect("kw", "in", "in the 'for' loop")
			local exprs = self:exprList()
			self:expect("kw", "do", "after the 'for ... in' list")
			local body = self:block()
			self:closeBlock("for", line)
			return { k = "GenFor", names = names, exprs = exprs, body = body, line = line }
		elseif v == "repeat" then
			self:next()
			local body = self:block()
			local tk = self:peek()
			if not (tk.t == "kw" and tk.v == "until") then
				syntaxError(tk.line, "missing 'until' for the 'repeat' on line " .. line)
			end
			self:next()
			local cond = self:expr()
			return { k = "Repeat", body = body, cond = cond, line = line }
		elseif v == "function" then
			self:next()
			local target = { k = "Name", name = self:name(), line = line }
			local isMethod = false
			while self:isOp(".") or self:isOp(":") do
				local sep = self:next().v
				local key = self:name()
				target = { k = "Index", obj = target, key = { k = "Const", value = key }, line = line }
				if sep == ":" then
					isMethod = true
					break
				end
			end
			local fn = self:funcBody(line, isMethod)
			return { k = "Assign", targets = { target }, exprs = { fn }, line = line }
		elseif v == "local" then
			self:next()
			if self:accept("kw", "function") then
				local name = self:name()
				return { k = "LocalFunction", name = name, fn = self:funcBody(line), line = line }
			end
			local names = { self:name() }
			while self:accept("op", ",") do names[#names + 1] = self:name() end
			local exprs = {}
			if self:accept("op", "=") then exprs = self:exprList() end
			return { k = "Local", names = names, exprs = exprs, line = line }
		elseif v == "break" then
			self:next()
			return { k = "Break", line = line }
		end
	end

	-- assignment or call
	local e = self:suffixedExpr()
	if self:isOp("=") or self:isOp(",") then
		local targets = { e }
		while self:accept("op", ",") do targets[#targets + 1] = self:suffixedExpr() end
		for _, t in ipairs(targets) do
			if t.k ~= "Name" and t.k ~= "Index" then
				syntaxError(line, "can't assign to this (only to variables and table fields)")
			end
		end
		self:expect("op", "=", "in the assignment")
		return { k = "Assign", targets = targets, exprs = self:exprList(), line = line }
	end
	if e.k ~= "Call" and e.k ~= "Method" then
		local tk = self:peek()
		if e.k == "Name" and tk.t == "op" and tk.v == "-" and self:peek(1).t == "op" and self:peek(1).v == ">" then
			syntaxError(line, "'->' is the old script language; in Lua write connect(A, B)")
		end
		syntaxError(line, "this line does nothing: expected a function call or an assignment near " .. self:describe(tk))
	end
	return { k = "CallStat", call = e, line = line }
end

function Parser:exprList()
	local list = { self:expr() }
	while self:accept("op", ",") do list[#list + 1] = self:expr() end
	return list
end

function Parser:primaryExpr()
	local tok = self:peek()
	if tok.t == "name" then
		self:next()
		return { k = "Name", name = tok.v, line = tok.line }
	elseif tok.t == "op" and tok.v == "(" then
		self:next()
		local e = self:expr()
		self:expect("op", ")", "to close the '('")
		return { k = "Paren", expr = e, line = tok.line }
	end
	syntaxError(tok.line, "unexpected " .. self:describe(tok))
end

function Parser:callArgs()
	local tok = self:peek()
	if tok.t == "str" then
		self:next()
		return { { k = "Const", value = tok.v } }
	elseif tok.t == "op" and tok.v == "{" then
		return { self:tableCons() }
	end
	self:expect("op", "(", "for the function call")
	local args = {}
	if not self:isOp(")") then args = self:exprList() end
	self:expect("op", ")", "to close the function call")
	return args
end

function Parser:suffixedExpr()
	local e = self:primaryExpr()
	while true do
		local tok = self:peek()
		if tok.t == "op" and tok.v == "." then
			self:next()
			e = { k = "Index", obj = e, key = { k = "Const", value = self:name() }, line = tok.line }
		elseif tok.t == "op" and tok.v == "[" then
			self:next()
			local key = self:expr()
			self:expect("op", "]", "to close the '['")
			e = { k = "Index", obj = e, key = key, line = tok.line }
		elseif tok.t == "op" and tok.v == ":" then
			self:next()
			local name = self:name()
			e = { k = "Method", obj = e, name = name, args = self:callArgs(), line = tok.line }
		elseif (tok.t == "op" and (tok.v == "(" or tok.v == "{")) or tok.t == "str" then
			if tok.t == "op" and tok.v == "(" and tok.line ~= (self.toks[self.i - 1] or tok).line then
				syntaxError(tok.line, "ambiguous syntax: a '(' at the start of a line continues the line above")
			end
			e = { k = "Call", fn = e, args = self:callArgs(), line = tok.line }
		else
			return e
		end
	end
end

function Parser:tableCons()
	local line = self:expect("op", "{").line
	local items = {}
	while not self:isOp("}") do
		if self:isOp("[") then
			self:next()
			local key = self:expr()
			self:expect("op", "]", "in the table key")
			self:expect("op", "=", "after the table key")
			items[#items + 1] = { key = key, value = self:expr() }
		elseif self:is("name") and self:peek(1).t == "op" and self:peek(1).v == "=" then
			local key = self:next().v
			self:next()
			items[#items + 1] = { key = { k = "Const", value = key }, value = self:expr() }
		else
			items[#items + 1] = { value = self:expr() }
		end
		if not (self:accept("op", ",") or self:accept("op", ";")) then break end
	end
	self:expect("op", "}", "to close the table started on line " .. line)
	return { k = "Table", items = items, line = line }
end

function Parser:simpleExpr()
	local tok = self:peek()
	if tok.t == "num" then
		self:next()
		return { k = "Const", value = tok.v }
	elseif tok.t == "str" then
		self:next()
		return { k = "Const", value = tok.v }
	elseif tok.t == "kw" then
		if tok.v == "nil" then self:next() return { k = "Const", value = nil } end
		if tok.v == "true" then self:next() return { k = "Const", value = true } end
		if tok.v == "false" then self:next() return { k = "Const", value = false } end
		if tok.v == "function" then
			self:next()
			return self:funcBody(tok.line)
		end
	elseif tok.t == "op" then
		if tok.v == "..." then
			self:next()
			if not self.fnVararg[#self.fnVararg] then
				syntaxError(tok.line, "'...' can only be used inside a function that takes '...'")
			end
			return { k = "Vararg", line = tok.line }
		end
		if tok.v == "{" then return self:tableCons() end
	end
	return self:suffixedExpr()
end

-- binary operator priorities (left, right), as in Lua 5.1
local BINARY = {
	["or"] = { 1, 1 }, ["and"] = { 2, 2 },
	["<"] = { 3, 3 }, [">"] = { 3, 3 }, ["<="] = { 3, 3 }, [">="] = { 3, 3 }, ["~="] = { 3, 3 }, ["=="] = { 3, 3 },
	[".."] = { 5, 4 }, ["+"] = { 6, 6 }, ["-"] = { 6, 6 },
	["*"] = { 7, 7 }, ["/"] = { 7, 7 }, ["%"] = { 7, 7 },
	["^"] = { 10, 9 },
}
local UNARY_PRIORITY = 8

function Parser:expr(limit)
	limit = limit or 0
	local left
	local tok = self:peek()
	if (tok.t == "kw" and tok.v == "not") or (tok.t == "op" and (tok.v == "-" or tok.v == "#")) then
		self:next()
		local operand = self:expr(UNARY_PRIORITY)
		left = { k = "Unop", op = tok.v, expr = operand, line = tok.line }
	else
		left = self:simpleExpr()
	end
	while true do
		local op = self:peek()
		local prio = (op.t == "op" or op.t == "kw") and BINARY[op.v]
		if not prio or prio[1] <= limit then break end
		self:next()
		local right = self:expr(prio[2])
		left = { k = "Binop", op = op.v, left = left, right = right, line = op.line }
	end
	return left
end

local function parse(src)
	local p = new(Parser, { toks = lex(src), i = 1, fnVararg = { true } })
	-- funcBody pushes/pops vararg info
	local origFuncBody = p.funcBody
	p.funcBody = function(self, line, isMethod)
		local save = self.fnVararg
		-- peek the parameter list to know if it takes '...'
		local j, depth, va = self.i, 0, false
		while self.toks[j] and self.toks[j].t ~= "eof" do
			local t = self.toks[j]
			if t.t == "op" and t.v == "(" then depth = depth + 1 end
			if t.t == "op" and t.v == ")" then
				depth = depth - 1
				if depth == 0 then break end
			end
			if depth == 1 and t.t == "op" and t.v == "..." then va = true end
			j = j + 1
		end
		self.fnVararg = { va }
		local r = origFuncBody(self, line, isMethod)
		self.fnVararg = save
		return r
	end
	local body = p:block()
	local tok = p:peek()
	if tok.t ~= "eof" then
		syntaxError(tok.line, "unexpected '" .. tostring(tok.v) .. "' (an extra 'end'?)")
	end
	return body
end

LogicScript.parse = parse

---------------------------------------------------------------------------
-- Compiler: AST -> closures
--
-- Runtime scopes are tables { up = parentScope, [slot] = value }. Every
-- local gets a slot number at compile time, and the compiler knows how
-- many scopes up it lives, so lookups never search by name.
---------------------------------------------------------------------------

local BREAK, RETURN = 1, 2
local LIMIT = { msg = "the script ran too long (endless loop?)" } -- unique error value
local LIMIT_MSG = LIMIT.msg

local function runtimeError(line, msg)
	error({ line = line, msg = msg, runtime = true }, 0)
end

-- what a name refers to, for error messages ("global 'foo'", "field 'x'")
local function describeExpr(e)
	if e.k == "Name" then return " (variable '" .. e.name .. "')" end
	if e.k == "Index" and e.key.k == "Const" and type(e.key.value) == "string" then
		return " (field '" .. e.key.value .. "')"
	end
	if e.k == "Method" then return " (method '" .. e.name .. "')" end
	return ""
end

local Compiler = {}

function Compiler:pushScope()
	self.scope = { names = {}, parent = self.scope, slots = 0, fn = self.fnDepth }
end
function Compiler:popScope() self.scope = self.scope.parent end
function Compiler:declare(name)
	local sc = self.scope
	sc.slots = sc.slots + 1
	sc.names[name] = sc.slots
	return sc.slots
end
-- returns levels up, slot (or nil for a global)
function Compiler:resolve(name)
	local sc, up = self.scope, 0
	while sc do
		local slot = sc.names[name]
		if slot then return up, slot end
		sc = sc.parent
		up = up + 1
	end
end

local function getter(up, slot)
	if up == 0 then return function(s) return s[slot] end end
	if up == 1 then return function(s) return s.up[slot] end end
	if up == 2 then return function(s) return s.up.up[slot] end end
	return function(s)
		for _ = 1, up do s = s.up end
		return s[slot]
	end
end

local function setter(up, slot)
	if up == 0 then return function(s, v) s[slot] = v end end
	if up == 1 then return function(s, v) s.up[slot] = v end end
	return function(s, v)
		for _ = 1, up do s = s.up end
		s[slot] = v
	end
end

local function isMulti(e) return e.k == "Call" or e.k == "Method" or e.k == "Vararg" end

-- compile a list of expressions into a function returning all their values
function Compiler:exprListFn(exprs)
	local n = #exprs
	if n == 0 then return function() return end end
	local fns = {}
	for i = 1, n - 1 do fns[i] = self:expr(exprs[i]) end
	local last = exprs[n]
	local lastFn = isMulti(last) and self:multi(last) or self:expr(last)
	if n == 1 then return lastFn end
	if n == 2 then
		local a = fns[1]
		return function(s) return a(s), lastFn(s) end
	end
	return function(s)
		local vals = {}
		for i = 1, n - 1 do vals[i] = fns[i](s) end
		local rest = pack(lastFn(s))
		for i = 1, rest.n do vals[n - 1 + i] = rest[i] end
		return unpack(vals, 1, n - 1 + rest.n)
	end
end

-- expression that can return several values (calls, ...)
function Compiler:multi(e)
	if e.k == "Vararg" then
		local varargOf = self.varargOf -- the enclosing function's, fixed at compile time
		return function(s)
			local va = varargOf(s)
			return unpack(va, 1, va.n)
		end
	end
	return self:call(e)
end

function Compiler:call(e)
	local st = self.state
	local line = e.line
	local argsFn = self:exprListFn(e.args)
	if e.k == "Method" then
		local objFn = self:expr(e.obj)
		local name = e.name
		local desc = describeExpr(e)
		return function(s)
			local obj = objFn(s)
			if obj == nil then runtimeError(line, "can't call method '" .. name .. "' on a nil value" .. describeExpr(e.obj)) end
			local f = obj[name]
			if type(f) ~= "function" then
				runtimeError(line, "attempt to call a " .. type(f) .. " value" .. desc)
			end
			st.line = line
			return f(obj, argsFn(s))
		end
	end
	local fnFn = self:expr(e.fn)
	local desc = describeExpr(e.fn)
	return function(s)
		local f = fnFn(s)
		if type(f) ~= "function" then
			runtimeError(line, "attempt to call a " .. type(f) .. " value" .. desc)
		end
		st.line = line
		return f(argsFn(s))
	end
end

local ARITH = {
	["+"] = function(a, b) return a + b end,
	["-"] = function(a, b) return a - b end,
	["*"] = function(a, b) return a * b end,
	["/"] = function(a, b) return a / b end,
	["%"] = function(a, b) return a % b end,
	["^"] = function(a, b) return a ^ b end,
	[".."] = function(a, b) return a .. b end,
	["=="] = function(a, b) return a == b end,
	["~="] = function(a, b) return a ~= b end,
	["<"] = function(a, b) return a < b end,
	["<="] = function(a, b) return a <= b end,
	[">"] = function(a, b) return a > b end,
	[">="] = function(a, b) return a >= b end,
}

local function typeErr(op, a, b)
	local function ok(v)
		if op == ".." then return type(v) == "string" or type(v) == "number" end
		if op == "<" or op == "<=" or op == ">" or op == ">=" then return type(v) == "number" or type(v) == "string" end
		return type(v) == "number" or (type(v) == "string" and tonumber(v) ~= nil)
	end
	local bad = not ok(a) and a or b
	if op == ".." then return "can't join a " .. type(bad) .. " with '..' (use tostring)" end
	if op == "<" or op == "<=" or op == ">" or op == ">=" then
		return "can't compare " .. type(a) .. " with " .. type(b)
	end
	return "can't do '" .. op .. "' with a " .. type(bad) .. " value"
end

function Compiler:expr(e)
	local k = e.k
	local st = self.state
	if k == "Const" then
		local v = e.value
		return function() return v end
	elseif k == "Name" then
		local up, slot = self:resolve(e.name)
		if up then return getter(up, slot) end
		local env, name = self.env, e.name
		return function() return env[name] end
	elseif k == "Paren" then
		local f = isMulti(e.expr) and self:multi(e.expr) or self:expr(e.expr)
		return function(s) return (f(s)) end
	elseif k == "Vararg" then
		local f = self:multi(e)
		return function(s) return (f(s)) end
	elseif k == "Call" or k == "Method" then
		local f = self:call(e)
		return function(s) return (f(s)) end
	elseif k == "Index" then
		local objFn, keyFn = self:expr(e.obj), self:expr(e.key)
		local line, desc = e.line, describeExpr(e.obj)
		return function(s)
			local obj = objFn(s)
			local t = type(obj)
			if t ~= "table" and t ~= "string" then
				runtimeError(line, "can't index a " .. t .. " value" .. desc)
			end
			return obj[keyFn(s)]
		end
	elseif k == "Function" then
		return self:func(e)
	elseif k == "Table" then
		local items = {}
		local nPos = 0
		for i, it in ipairs(e.items) do
			if it.key then
				items[i] = { key = self:expr(it.key), value = self:expr(it.value) }
			else
				nPos = nPos + 1
				local multiLast = i == #e.items and isMulti(it.value)
				items[i] = { pos = nPos, multi = multiLast, value = multiLast and self:multi(it.value) or self:expr(it.value) }
			end
		end
		local line = e.line
		return function(s)
			local t = {}
			for _, it in ipairs(items) do
				if it.key then
					local key = it.key(s)
					if key == nil then runtimeError(line, "table key is nil") end
					t[key] = it.value(s)
				elseif it.multi then
					local vals = pack(it.value(s))
					for j = 1, vals.n do t[it.pos + j - 1] = vals[j] end
				else
					t[it.pos] = it.value(s)
				end
			end
			return t
		end
	elseif k == "Unop" then
		local f = self:expr(e.expr)
		local line = e.line
		if e.op == "not" then return function(s) return not f(s) end end
		if e.op == "-" then
			return function(s)
				local v = f(s)
				if type(v) ~= "number" then
					if type(v) == "string" and tonumber(v) then return -tonumber(v) end
					runtimeError(line, "can't negate a " .. type(v) .. " value")
				end
				return -v
			end
		end
		return function(s) -- #
			local v = f(s)
			if type(v) ~= "table" and type(v) ~= "string" then
				runtimeError(line, "can't get the length of a " .. type(v) .. " value" .. describeExpr(e.expr))
			end
			return #v
		end
	elseif k == "Binop" then
		local a, b = self:expr(e.left), self:expr(e.right)
		local op, line = e.op, e.line
		if op == "and" then return function(s) return a(s) and b(s) end end
		if op == "or" then return function(s) return a(s) or b(s) end end
		local f = ARITH[op]
		if op == "==" or op == "~=" then
			return function(s) return f(a(s), b(s)) end
		end
		return function(s)
			local x, y = a(s), b(s)
			local ok, r = pcall(f, x, y)
			if not ok then
				if r == LIMIT then error(LIMIT, 0) end
				if type(r) == "table" then error(r, 0) end
				runtimeError(line, typeErr(op, x, y))
			end
			return r
		end
	end
	error("compiler: unknown expression " .. tostring(k))
end

function Compiler:func(e)
	local st = self.state
	local params, vararg = e.params, e.vararg
	-- the function's own scope holds its parameters (and '...')
	local outerScope = self.scope
	self.scope = { names = {}, parent = outerScope, slots = 0 }
	local paramSlots = {}
	for i, p in ipairs(params) do paramSlots[i] = self:declare(p) end
	local vaSlot = vararg and self:declare("...") or nil
	local saveVa = self.varargOf
	if vararg then
		-- inner blocks are deeper: walk up to this function's scope
		local fnScope = self.scope
		self.varargOf = function(s)
			local sc = s
			while sc and sc.fnScope ~= fnScope do sc = sc.up end
			return sc[vaSlot]
		end
	end
	local fnScopeMarker = self.scope
	local saveLoops = self.loops
	self.loops = 0
	local body = self:block(e.body, true)
	self.loops = saveLoops
	self.varargOf = saveVa
	self.scope = outerScope
	local nParams = #params
	local line = e.line

	return function(s)
		local defScope = s
		return function(...)
			local steps = st.steps + 1
			st.steps = steps
			if steps > MAX_STEPS then error(LIMIT, 0) end
			st.depth = st.depth + 1
			if st.depth > 200 then
				st.depth = 0
				runtimeError(line, "too many nested calls (endless recursion?)")
			end
			local sc = { up = defScope, fnScope = fnScopeMarker }
			for i = 1, nParams do sc[paramSlots[i]] = (select(i, ...)) end
			if vaSlot then
				local all = pack(...)
				local rest = { n = math.max(0, all.n - nParams) }
				for i = 1, rest.n do rest[i] = all[nParams + i] end
				sc[vaSlot] = rest
			end
			local code, ret = body(sc)
			st.depth = st.depth - 1
			if code == RETURN then return unpack(ret, 1, ret.n) end
		end
	end
end

-- Compile a block. If sameScope, the statements run in the scope they are
-- given (function bodies); otherwise each run gets a fresh child scope.
function Compiler:block(stats, sameScope)
	if not sameScope then self:pushScope() end
	local fns, lines = {}, {}
	for i, s in ipairs(stats) do
		fns[i] = self:stat(s)
		lines[i] = s.line
	end
	if not sameScope then self:popScope() end
	local n = #fns
	local st = self.state
	local function run(s)
		for i = 1, n do
			st.line = lines[i]
			local code, ret = fns[i](s)
			if code then return code, ret end
		end
	end
	if sameScope then return run end
	return function(s) return run({ up = s }) end
end

function Compiler:loopBlock(stats, sameScope)
	self.loops = self.loops + 1
	local b = self:block(stats, sameScope)
	self.loops = self.loops - 1
	return b
end

function Compiler:assignTarget(t)
	if t.k == "Name" then
		local up, slot = self:resolve(t.name)
		if up then return setter(up, slot) end
		local env, name = self.env, t.name
		return function(_, v) env[name] = v end
	end
	local objFn, keyFn = self:expr(t.obj), self:expr(t.key)
	local line, desc = t.line, describeExpr(t.obj)
	return function(s, v)
		local obj = objFn(s)
		if type(obj) ~= "table" then runtimeError(line, "can't set a field on a " .. type(obj) .. " value" .. desc) end
		local key = keyFn(s)
		if key == nil then runtimeError(line, "table key is nil") end
		obj[key] = v
	end
end

function Compiler:stat(s)
	local k = s.k
	local st = self.state
	local line = s.line
	local function tick()
		local steps = st.steps + 1
		st.steps = steps
		if steps > MAX_STEPS then error(LIMIT, 0) end
	end

	if k == "Local" then
		local valuesFn = self:exprListFn(s.exprs)
		local slots = {}
		for i, name in ipairs(s.names) do slots[i] = self:declare(name) end
		local n = #slots
		if n == 1 then
			local slot = slots[1]
			return function(sc) sc[slot] = (valuesFn(sc)) end
		end
		return function(sc)
			local vals = pack(valuesFn(sc))
			for i = 1, n do sc[slots[i]] = vals[i] end
		end
	elseif k == "LocalFunction" then
		local slot = self:declare(s.name)
		local fnFn = self:func(s.fn)
		return function(sc) sc[slot] = fnFn(sc) end
	elseif k == "Assign" then
		local valuesFn = self:exprListFn(s.exprs)
		local setters = {}
		for i, t in ipairs(s.targets) do setters[i] = self:assignTarget(t) end
		local n = #setters
		if n == 1 then
			local set = setters[1]
			return function(sc) set(sc, (valuesFn(sc))) end
		end
		return function(sc)
			local vals = pack(valuesFn(sc))
			for i = 1, n do setters[i](sc, vals[i]) end
		end
	elseif k == "CallStat" then
		local f = self:call(s.call)
		return function(sc) tick() f(sc) end
	elseif k == "Do" then
		return self:block(s.body)
	elseif k == "If" then
		local conds, bodies = {}, {}
		for i, c in ipairs(s.clauses) do
			conds[i] = self:expr(c.cond)
			bodies[i] = self:block(c.body)
		end
		local elseBody = s.elseBody and self:block(s.elseBody)
		local n = #conds
		return function(sc)
			for i = 1, n do
				if conds[i](sc) then return bodies[i](sc) end
			end
			if elseBody then return elseBody(sc) end
		end
	elseif k == "While" then
		local cond = self:expr(s.cond)
		local body = self:loopBlock(s.body)
		return function(sc)
			while cond(sc) do
				tick()
				local code, ret = body(sc)
				if code == BREAK then break end
				if code then return code, ret end
			end
		end
	elseif k == "Repeat" then
		-- the condition can see the body's locals
		self:pushScope()
		local inner = {}
		self.loops = self.loops + 1
		for i, x in ipairs(s.body) do inner[i] = self:stat(x) end
		self.loops = self.loops - 1
		local cond = self:expr(s.cond)
		self:popScope()
		local n = #inner
		return function(sc)
			while true do
				tick()
				local scope = { up = sc }
				for i = 1, n do
					local code, ret = inner[i](scope)
					if code == BREAK then return end
					if code then return code, ret end
				end
				if cond(scope) then break end
			end
		end
	elseif k == "NumFor" then
		local startFn, stopFn = self:expr(s.start), self:expr(s.stop)
		local stepFn = s.step and self:expr(s.step) or function() return 1 end
		self:pushScope()
		local slot = self:declare(s.var)
		local body = self:loopBlock(s.body, true)
		self:popScope()
		return function(sc)
			local a, b, c = tonumber(startFn(sc)), tonumber(stopFn(sc)), tonumber(stepFn(sc))
			if not a then runtimeError(line, "'for' start value must be a number") end
			if not b then runtimeError(line, "'for' limit must be a number") end
			if not c then runtimeError(line, "'for' step must be a number") end
			if c == 0 then runtimeError(line, "'for' step is zero") end
			for i = a, b, c do
				tick()
				local code, ret = body({ up = sc, [slot] = i })
				if code == BREAK then break end
				if code then return code, ret end
			end
		end
	elseif k == "GenFor" then
		local listFn = self:exprListFn(s.exprs)
		self:pushScope()
		local slots = {}
		for i, name in ipairs(s.names) do slots[i] = self:declare(name) end
		local body = self:loopBlock(s.body, true)
		self:popScope()
		local n = #slots
		return function(sc)
			local f, state, var = listFn(sc)
			if type(f) ~= "function" then
				runtimeError(line, "'for ... in' needs a function like ipairs(list) or pairs(t), got a " .. type(f))
			end
			while true do
				tick()
				local vals = pack(f(state, var))
				if vals[1] == nil then break end
				var = vals[1]
				local scope = { up = sc }
				for i = 1, n do scope[slots[i]] = vals[i] end
				local code, ret = body(scope)
				if code == BREAK then break end
				if code then return code, ret end
			end
		end
	elseif k == "Return" then
		local valuesFn = self:exprListFn(s.exprs)
		return function(sc) return RETURN, pack(valuesFn(sc)) end
	elseif k == "Break" then
		if self.loops == 0 then runtimeError(line, "'break' is only allowed inside a loop") end
		return function() return BREAK end
	end
	error("compiler: unknown statement " .. tostring(k))
end

local function compile(ast, env, state)
	local c = new(Compiler, { env = env, state = state, scope = nil, loops = 0, varargOf = function(s)
		while s.up do s = s.up end
		return s.va or { n = 0 }
	end })
	c:pushScope()
	local body = c:block(ast, true)
	return function() return body({}) end
end

-- Runs Lua `src` with `env` as its globals. Returns ok, err ("line N: msg").
function LogicScript.exec(src, env, state)
	state = state or {}
	state.steps, state.depth, state.line = 0, 0, 1
	local ok, ast = pcall(parse, src)
	if not ok then
		if type(ast) == "table" then return false, "line " .. ast.line .. ": " .. ast.msg end
		return false, tostring(ast)
	end
	local okC, fn = pcall(compile, ast, env, state)
	if not okC then
		if type(fn) == "table" and fn.msg then return false, "line " .. fn.line .. ": " .. fn.msg end
		return false, "compile error: " .. tostring(fn)
	end
	local okR, err = pcall(fn)
	if okR then return true end
	if err == LIMIT then return false, "line " .. state.line .. ": " .. LIMIT_MSG end
	if type(err) == "table" and err.msg then
		return false, "line " .. (err.line or state.line) .. ": " .. err.msg
	end
	-- errors from Lua itself or from error(): drop the engine's file position
	local msg = tostring(err):gsub("^[^\n]-%.lua:%d+: ", "")
	return false, "line " .. state.line .. ": " .. msg
end

---------------------------------------------------------------------------
-- Sandbox + the wiring API
---------------------------------------------------------------------------

local function copyTable(t)
	local c = {}
	for k, v in pairs(t) do c[k] = v end
	return c
end

local GROUP_NAMES = { "A", "B", "C" }

-- groups: { A = {node...}, B = ..., C = ... }
-- node: { key = <unique>, x, y, z, order, [type, kind, mode, delay, color] }
-- returns: ok, { ops = { {kind, p = node, c = node}... }, output = {lines} }
--          or false, "line N: message", outputSoFar
function LogicScript.run(src, groups)
	local ops, output, seen = {}, {}, {}
	local partNode = {} -- part table -> node
	local state = {}

	local function out(line)
		if #output < MAX_OUTPUT then output[#output + 1] = line end
	end

	-- index is 0-based like the names the player sees (A[1] is A0)
	local function makePart(node, gname, index)
		local p = {
			group = gname, index = index - 1, id = node.key,
			x = node.x or 0, y = node.y or 0, z = node.z or 0,
			type = node.type, kind = node.kind, mode = node.mode, delay = node.delay, color = node.color,
		}
		partNode[p] = node
		return p
	end

	local env = {}
	local function fail(msg) runtimeError(state.line, msg) end

	-- a part or a list of parts -> list of parts
	local function parts(v, what)
		if type(v) == "table" then
			if partNode[v] then return { v } end
			local list = {}
			for i = 1, #v do
				if not partNode[v[i]] then
					fail(what .. ": item " .. i .. " is not a part")
				end
				list[i] = v[i]
			end
			return list
		end
		fail(what .. " needs a part or a list of parts, got " .. (v == nil and "nil" or ("a " .. type(v))))
	end

	local function emit(kind, p, c)
		local pn, cn = partNode[p], c and partNode[c]
		if c and pn == cn then return end -- no self connections
		local key = kind .. "|" .. tostring(pn.key) .. "|" .. tostring(cn and cn.key)
		if seen[key] then return end
		if #ops >= MAX_OPS then fail("too many operations (max " .. MAX_OPS .. ")") end
		seen[key] = true
		ops[#ops + 1] = { kind = kind, p = pn, c = cn, line = state.line }
	end

	local function pairUp(kind, from, to, mode, name)
		local A, B = parts(from, name), parts(to, name)
		mode = mode or "all"
		if mode == "zip" then
			if #A ~= #B then
				out(string.format("note (line %d): %s zip with %d and %d parts, pairing the first %d", state.line, name, #A, #B, math.min(#A, #B)))
			end
			for i = 1, math.min(#A, #B) do emit(kind, A[i], B[i]) end
		elseif mode == "all" then
			for _, a in ipairs(A) do
				for _, b in ipairs(B) do emit(kind, a, b) end
			end
		else
			fail(name .. ": mode must be \"all\" or \"zip\", got " .. tostring(mode))
		end
		return #A * #B
	end

	env.connect = function(from, to, mode) pairUp("connect", from, to, mode, "connect") end
	env.cut = function(from, to, mode) pairUp("cut", from, to, mode, "cut") end
	env.flip = function(from, to, mode) pairUp("flip", from, to, mode, "flip") end
	env.chain = function(list)
		local l = parts(list, "chain")
		for i = 1, #l - 1 do emit("connect", l[i], l[i + 1]) end
	end
	env.clearInputs = function(x) for _, p in ipairs(parts(x, "clearInputs")) do emit("clearIn", p) end end
	env.clearOutputs = function(x) for _, p in ipairs(parts(x, "clearOutputs")) do emit("clearOut", p) end end

	-- list helpers (lists are plain Lua tables of parts)
	env.sort = function(list, key)
		if type(list) ~= "table" then fail("sort needs a list") end
		local index = {}
		for i, p in ipairs(list) do index[p] = i end
		local cmp
		if type(key) == "function" then
			cmp = key
		else
			key = key or "x"
			if type(key) ~= "string" then fail("sort: key must be \"x\", \"-y\" ... or a function") end
			local desc = key:sub(1, 1) == "-"
			local field = desc and key:sub(2) or key
			if field ~= "x" and field ~= "y" and field ~= "z" and field ~= "index" and field ~= "delay" then
				fail("sort: unknown key \"" .. key .. "\" (use x y z -x -y -z)")
			end
			cmp = function(a, b)
				local va, vb = a[field] or 0, b[field] or 0
				if va ~= vb then
					if desc then return va > vb end
					return va < vb
				end
				return index[a] < index[b] -- keep the old order for ties
			end
		end
		table.sort(list, cmp)
		return list
	end
	env.reverse = function(list)
		if type(list) ~= "table" then fail("reverse needs a list") end
		local n = #list
		for i = 1, math.floor(n / 2) do list[i], list[n + 1 - i] = list[n + 1 - i], list[i] end
		return list
	end
	env.slice = function(list, i, j)
		if type(list) ~= "table" then fail("slice needs a list") end
		local n = #list
		i = i or 1
		j = j or n
		if i < 0 then i = n + 1 + i end
		if j < 0 then j = n + 1 + j end
		local out2 = {}
		for k = math.max(1, i), math.min(n, j) do out2[#out2 + 1] = list[k] end
		return out2
	end
	env.filter = function(list, fn)
		if type(list) ~= "table" or type(fn) ~= "function" then fail("filter needs a list and a function") end
		local out2 = {}
		for _, p in ipairs(list) do
			if fn(p) then out2[#out2 + 1] = p end
		end
		return out2
	end
	env.join = function(...)
		local out2 = {}
		for i = 1, select("#", ...) do
			local l = select(i, ...)
			for _, p in ipairs(parts(l, "join")) do out2[#out2 + 1] = p end
		end
		return out2
	end
	env.getbit = function(n, k) return math.floor(n / 2 ^ k) % 2 end

	env.print = function(...)
		local t = {}
		for i = 1, select("#", ...) do
			local v = select(i, ...)
			if type(v) == "table" and partNode[v] then
				v = v.group .. v.index
			end
			t[i] = tostring(v)
		end
		out(table.concat(t, " "))
	end

	-- standard library (safe parts only)
	local std = {
		pairs = pairs, ipairs = ipairs, next = next, type = type, tostring = tostring, tonumber = tonumber,
		select = select, unpack = unpack, assert = assert,
	}
	for name, f in pairs(std) do env[name] = f end
	env.error = function(msg) error(tostring(msg), 0) end
	env.pcall = function(f, ...)
		local depth = state.depth
		local r = pack(pcall(f, ...))
		state.depth = depth
		if not r[1] and r[2] == LIMIT then error(LIMIT, 0) end
		if not r[1] and type(r[2]) == "table" and r[2].msg then r[2] = "line " .. r[2].line .. ": " .. r[2].msg end
		return unpack(r, 1, r.n)
	end
	env.math = copyTable(math)
	env.table = copyTable(table)
	env.string = copyTable(string)
	env.string.rep = function(s, n, sep)
		if (#tostring(s) + #(sep or "")) * (tonumber(n) or 0) > 100000 then fail("string.rep: result too long") end
		return string.rep(s, n, sep)
	end
	env.string.dump = nil
	if bit then env.bit = copyTable(bit) end
	env._G = env

	-- the groups, as plain lists of parts
	for _, g in ipairs(GROUP_NAMES) do
		local list = {}
		for i, node in ipairs(groups[g] or {}) do list[i] = makePart(node, g, i) end
		env[g] = list
	end

	local ok, err = LogicScript.exec(src, env, state)
	if not ok then return false, err, output end
	return true, { ops = ops, output = output }
end

---------------------------------------------------------------------------
-- Editor: syntax highlighting and formatting
---------------------------------------------------------------------------

LogicScript.THEME = {
	text = "#d4d4d4", keyword = "#c586c0", value = "#569cd6", number = "#b5cea8",
	string = "#ce9178", comment = "#6a9955", api = "#dcdcaa", lib = "#4ec9b0",
	error = "#ff5050",
	A = "#ff9900", B = "#00c8ff", C = "#d040ff",
}
local API_NAMES = {}
for w in ("connect cut flip chain clearInputs clearOutputs sort reverse slice filter join getbit print"):gmatch("%S+") do
	API_NAMES[w] = true
end
local LIB_NAMES = {}
for w in ("pairs ipairs next type tostring tonumber select unpack assert error pcall math table string bit"):gmatch("%S+") do
	LIB_NAMES[w] = true
end

-- Splits source into spans { kind, text } without ever failing (the editor
-- text is often half-typed). kind: text keyword value number string comment
-- api lib group name.
local function scan(src)
	local spans = {}
	local i, n = 1, #src
	local function add(kind, s) spans[#spans + 1] = { kind, s } end
	while i <= n do
		local c = src:sub(i, i)
		if src:sub(i, i + 1) == "--" then
			local lvl = longOpen(src, i + 2)
			local e
			if lvl then
				local _, ce = src:find("]" .. ("="):rep(lvl) .. "]", i, true)
				e = ce or n
			else
				e = (src:find("\n", i, true) or n + 1) - 1
			end
			add("comment", src:sub(i, e))
			i = e + 1
		elseif c == '"' or c == "'" then
			local j = i + 1
			while j <= n do
				local d = src:sub(j, j)
				if d == "\\" then j = j + 2
				elseif d == c or d == "\n" then break
				else j = j + 1 end
			end
			if src:sub(j, j) == "\n" then j = j - 1 end
			add("string", src:sub(i, math.min(j, n)))
			i = j + 1
		elseif c == "[" and longOpen(src, i) then
			local lvl = longOpen(src, i)
			local _, ce = src:find("]" .. ("="):rep(lvl) .. "]", i + lvl + 2, true)
			local e = ce or n
			add("string", src:sub(i, e))
			i = e + 1
		elseif c:match("[%a_]") then
			local w = src:match("^[%w_]+", i)
			local prev = spans[#spans]
			local afterDot = prev and prev[1] == "text" and prev[2]:match("[%.:]%s*$")
			local kind = "name"
			if KEYWORDS[w] then
				kind = (w == "true" or w == "false" or w == "nil") and "value" or "keyword"
			elseif afterDot then
				kind = "name"
			elseif w == "A" or w == "B" or w == "C" then
				kind = "group"
			elseif API_NAMES[w] then
				kind = "api"
			elseif LIB_NAMES[w] then
				kind = "lib"
			end
			add(kind, w)
			i = i + #w
		elseif c:match("%d") then
			local num = src:match("^0[xX]%x*", i) or src:match("^%d+%.?%d*[eE][%+%-]?%d*", i) or src:match("^%d+%.?%d*", i)
			add("number", num)
			i = i + #num
		else
			local j = i
			while j <= n do
				local d = src:sub(j, j)
				if d:match("[%w_\"'%[]") or src:sub(j, j + 1) == "--" then
					if not (d == "[" and not longOpen(src, j)) then break end
				end
				j = j + 1
			end
			if j == i then j = i + 1 end
			add("text", src:sub(i, j - 1))
			i = j
		end
	end
	return spans
end
LogicScript.scan = scan

-- MyGUI text with colour codes. '#' must be doubled. Backslashes are shown
-- as a lookalike so MyGUI doesn't treat them as escapes; editorToSource()
-- turns them back.
local BACKSLASH = "\226\129\132" -- U+2044 fraction slash
LogicScript.BACKSLASH = BACKSLASH

local function escape(s) return (s:gsub("#", "##"):gsub("\\", BACKSLASH)) end

function LogicScript.highlight(src, errorLine)
	local th = LogicScript.THEME
	local out = {}
	local line = 1
	local current
	local function emit(colour, text)
		if text == "" then return end
		if colour ~= current then
			out[#out + 1] = colour
			current = colour
		end
		out[#out + 1] = escape(text)
	end
	for _, span in ipairs(scan(src)) do
		local kind, text = span[1], span[2]
		local colour = th.text
		if kind == "group" then colour = th[text]
		elseif kind ~= "name" and th[kind] then colour = th[kind] end
		-- split by line so an error line can be coloured
		local start = 1
		while true do
			local nl = text:find("\n", start, true)
			local piece = text:sub(start, nl and nl or #text)
			emit(line == errorLine and th.error or colour, piece)
			if not nl then break end
			line = line + 1
			start = nl + 1
		end
	end
	return table.concat(out)
end

function LogicScript.editorToSource(text)
	-- if the editor hands back our colour codes, strip them (## is a real #)
	local th = LogicScript.THEME
	if text:find(th.text, 1, true) or text:find(th.keyword, 1, true) or text:find(th.api, 1, true) then
		text = text:gsub("##", "\0"):gsub("#%x%x%x%x%x%x", ""):gsub("%z", "#")
	end
	return (text:gsub(BACKSLASH, "\\"))
end

-- Re-indents the script by its blocks (4 spaces per level) and trims
-- trailing spaces. Lines inside long strings/comments are kept as they are.
-- Several blocks opened on one line, like "filter(A, function(p)", only
-- indent once.
function LogicScript.format(src)
	local INDENT = "    "
	local OPEN = { ["then"] = true, ["do"] = true, ["function"] = true, ["repeat"] = true, ["("] = true, ["{"] = true }
	local CLOSE = { ["end"] = true, ["until"] = true, [")"] = true, ["}"] = true, ["else"] = true, ["elseif"] = true }
	local stack = {} -- line number each open block started on
	local function depth(n)
		local d, last = 0, nil
		for k = 1, n do
			if stack[k] ~= last then
				d = d + 1
				last = stack[k]
			end
		end
		return d
	end

	local lines = {}
	for l in (src .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = l end
	local out = {}
	local inLong = false
	for lineNo, raw in ipairs(lines) do
		if inLong then
			out[#out + 1] = raw
			if raw:find(inLong, 1, true) then inLong = false end
		else
			local code = raw:match("^%s*(.-)%s*$")
			-- the line's block words and brackets, ignoring strings and comments
			local toks = {}
			for _, span in ipairs(scan(code)) do
				local kind, text = span[1], span[2]
				if kind == "keyword" then
					toks[#toks + 1] = text
				elseif kind == "text" then
					for ch in text:gmatch("[%(%){}]") do toks[#toks + 1] = ch end
					if text:match("[^%s%(%){}]") then toks[#toks + 1] = "x" end
				elseif kind == "comment" or kind == "string" then
					local lvl = text:match("^%-%-%[(=*)%[") or text:match("^%[(=*)%[")
					if lvl then
						local close = "]" .. lvl .. "]"
						if not text:find(close, #lvl + 3, true) then inLong = close end
					end
					if kind == "string" then toks[#toks + 1] = "x" end
				else
					toks[#toks + 1] = "x"
				end
			end
			-- closers at the start of the line dedent it
			local leading = 0
			for _, t in ipairs(toks) do
				if CLOSE[t] then leading = leading + 1 else break end
			end
			local ind = depth(math.max(0, #stack - leading))
			out[#out + 1] = code == "" and "" or (INDENT:rep(ind) .. code)
			for _, t in ipairs(toks) do
				if CLOSE[t] and #stack > 0 then stack[#stack] = nil end
				if OPEN[t] or t == "else" then stack[#stack + 1] = lineNo end
			end
		end
	end
	-- no more than one blank line in a row, none at the end
	return (table.concat(out, "\n"):gsub("\n\n\n+", "\n\n"):gsub("%s+$", ""))
end

---------------------------------------------------------------------------
-- Examples
---------------------------------------------------------------------------

LogicScript.examples = {
	{
		name = "Zip by position",
		code = [[-- pair A and B by their position along X
sort(A, "x")
sort(B, "x")
connect(A, B, "zip")]]
	},
	{
		name = "Decoder",
		code = [[-- A = input bits (lowest bit first)
-- C = the same bits inverted (NOT gates)
-- B = AND gates, one per output value
for i, gate in ipairs(B) do
    for k = 1, #A do
        if getbit(i - 1, k - 1) == 1 then
            connect(A[k], gate)
        else
            connect(C[k], gate)
        end
    end
end
print("decoder for", #A, "bits,", #B, "outputs")]]
	},
	{
		name = "Shift / delay line",
		code = [[-- chain A in X order, then feed the last one into B
sort(A, "x")
chain(A)
connect(A[#A], B)]]
	},
	{
		name = "Reverse bus",
		code = [[-- A[1] -> B[n], A[2] -> B[n-1], ...
for i = 1, math.min(#A, #B) do
    connect(A[i], B[#B + 1 - i])
end]]
	},
	{
		name = "Every 2nd",
		code = [[-- odd A parts into B[1], even ones into B[2]
for i = 1, #A, 2 do
    connect(A[i], B[1])
end
for i = 2, #A, 2 do
    connect(A[i], B[2])
end]]
	},
	{
		name = "Only some gates",
		code = [[-- connect only the XOR gates of A to B
local xors = filter(A, function(p)
    return p.mode == "XOR"
end)
connect(xors, B)
print(#xors, "XOR gates connected")]]
	},
}
