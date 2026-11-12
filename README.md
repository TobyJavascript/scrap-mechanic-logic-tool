# TobyWand

A handheld logic tool for Scrap Mechanic, made for building **vanilla** logic
creations faster.

## Features

- **Groups**: select logic parts into groups A, B, C… by clicking or box
  dragging. Press Q to switch the box between full 3D and an XY, XZ or YZ layer,
  like the game's block drag. Parts show their order number in the group.
- **Bulk wiring**: wire A to B all-to-all or zip (A0→B0, A1→B1…), or chain
  the active group. Ring chains it and closes the loop (3+ parts), and Self
  wires each part to itself, which turns a group of XORs into memory cells.
  A mode dropdown picks whether those buttons connect, cut or flip (toggle)
  the wires. You can also clear the active group's inputs or outputs, and
  Undo reverts the last action.
- **Bulk edit**: set every gate in the active group to one mode (AND, XOR…)
  or every timer to one delay (`5t`, `2s`, `1s 5t`). The creation is rebuilt
  from its blueprint, stays on the lift, keeps your groups, and Undo puts it
  back.
- **Sorting**: sort a group by X, Y or Z, or reverse it.
- **Pick similar**: F + click selects every matching part, by type, colour,
  gate mode or timer setting.
- **Analysis** (Debug window):
  - timing (min/max ticks from inputs to outputs);
  - loop detection, and glitch risks (a gate whose inputs arrive on different ticks);
  - truth tables;
  - a delay probe that numbers every gate after (or before) a part.
- **Step debugger**: step the logic between A and B one tick at a time,
  forward and back, like a code debugger. It runs on a copy of the circuit
  (taken from the game as it is now), so the creation never changes. Arrows
  show this tick's changes (green on, red off) and wires that stay on
  (yellow); a countdown over each part says how many ticks until it changes
  next, and self-wired XOR memories read MEM on / off. Inputs can be constant, a
  1 tick pulse, a pulse every N ticks (per input), or free after tick 0.
  Controls stay on the mouse (a HUD panel, not a menu), so you can walk
  around while stepping; Q runs it at a typed speed (seconds per tick).
- **Modules and LUTs**: load the logic between A (inputs) and B (outputs) as
  a table in the module window. Edit the outputs, and **Build LUT** rebuilds
  that logic as a clean lookup table: A in a line, inverters, one AND per row,
  B as the ORs. The old circuit is removed as a whole (or kept whole when
  something else still uses it), and gates that only feed A move along with
  it. You see a ghost preview first; afterwards the tool reloads the
  module and checks it against your table. Undo build puts the creation back.
  Two styles: **ROM** (a decoder and an OR plane) and **XOR** (positive-polarity
  Reed–Muller: XORs of shared AND terms, often much smaller); **Auto** picks
  the one with fewer gates. Settings also choose stacked or spread-out gates,
  and even timing (no glitches) or fewer gates. Builds that would break the
  game's 255 inputs/outputs per part are refused before anything changes.
- **Lua scripting**: a built-in editor with syntax highlighting, formatting and
  a script library (your own scripts saved by name, next to the examples).
  Groups are Lua lists of parts, so wiring a decoder or a shift register takes
  a few lines:

  ```lua
  -- zip A to B by position
  connect(sort(A, "x"), sort(B, "x"), "zip")

  -- only the XOR gates in A drive B
  connect(filter(A, function(p) return p.mode == "XOR" end), B)
  ```
  
## Layout

| Path | What |
| --- | --- |
| `TobyWand/` | The mod. Copy it into your Scrap Mechanic `Mods` folder |
| `TobyWand/Scripts/LogicTool.lua` | The tool: input, selection, wiring, GUI |
| `TobyWand/Scripts/LogicGraph.lua` | Logic graph analysis: timing, loops, truth tables, delay probe, tick simulation and step debugger |
| `TobyWand/Scripts/LogicScript.lua` | Lua interpreter, scripting API, highlighter and formatter |
| `TobyWand/Scripts/LogicModule.lua` | Modules: truth table, editing, LUT plan, blueprint rebuild |
| `TobyWand/Scripts/LogicSettings.lua` | What is remembered between sessions: settings and the script library |
| `tools/` | Python generators for the meshes, texture, icon and GUI layouts |
| `tools/logictool_tests/` | Offline tests, run in LuaJIT through lupa |

## Tests

```sh
python3 -m venv venv && venv/bin/pip install lupa
venv/bin/python tools/logictool_tests/run_tests.py
```

The tests remove the globals the game's sandbox doesn't have (`setmetatable`,
`load`, …), so code that would break in game also fails offline.

## Install

Copy `TobyWand/` into
`%APPDATA%/Axolot Games/Scrap Mechanic/User/User_<id>/Mods/`. If you update an
installed copy, delete its `Cache` folder.

Settings and saved scripts are kept next to the mod, in `settings.json` and
`scripts.json`; keep those two files when you update.
