"""Offline tests for the TobyWand's pure-Lua modules, run in LuaJIT (the
same Lua the game uses) through lupa.

    python3 -m venv venv && venv/bin/pip install lupa
    venv/bin/python tools/logictool_tests/run_tests.py
"""
import os
import sys

import lupa.luajit21 as lupa

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.join(HERE, "..", "..", "TobyWand", "Scripts")

# Functions Scrap Mechanic's sandbox doesn't have. Removed so the tests fail
# like the game would (game log: "attempt to call global 'setmetatable'").
SANDBOX = "setmetatable, getmetatable, rawget, rawset, rawequal, load, loadstring, dofile, require, debug, os.execute, io = nil"

lua = lupa.LuaRuntime(unpack_returned_tuples=True)
lua.execute("os = { clock = os.clock, time = os.time }; " + SANDBOX.replace("os.execute, ", ""))
for name in ("LogicScript.lua", "LogicGraph.lua", "LogicModule.lua", "LogicSettings.lua"):
    with open(os.path.join(SCRIPTS, name), encoding="utf-8") as f:
        lua.execute(f.read())

with open(os.path.join(HERE, "tests.lua"), encoding="utf-8") as f:
    failures = lua.execute(f.read())

# smoke test of the tool script against a mocked game API (fresh runtime)
smoke_rt = lupa.LuaRuntime(unpack_returned_tuples=True)
with open(os.path.join(HERE, "smoke.lua"), encoding="utf-8") as f:
    smoke = smoke_rt.execute(f.read(), os.path.abspath(SCRIPTS))  # smoke.lua strips the sandbox globals itself

sys.exit(1 if (failures or smoke) else 0)
