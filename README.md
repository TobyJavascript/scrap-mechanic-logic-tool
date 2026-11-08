# TobyWand

A handheld logic tool for Scrap Mechanic, made for building **vanilla** logic
creations faster.

## Features

- **Groups**: select logic parts into groups A, B, C… by clicking or box
  dragging. Press Q to switch the box between full 3D and an XY, XZ or YZ layer,
  like the game's block drag. Parts show their order number in the group.
- **Bulk wiring**: wire A to B all-to-all or zip (A0→B0, A1→B1…), or chain
  the active group. A mode setting picks whether those buttons connect, cut or
  flip (toggle) the wires. You can also clear the active group's inputs or
  outputs, and Undo reverts the last action.
- **Sorting**: sort a group by X, Y or Z, or reverse it.
- **Pick similar**: F + click selects every matching part, by type, colour,
  gate mode or timer setting.
- **Analysis**:
  - timing (min/max ticks from inputs to outputs);
  - loop detection, and glitch risks (a gate whose inputs arrive on different ticks);
  - truth tables;
  - a delay probe that numbers every gate after (or before) a part.
- **Modules and LUTs**: load the logic between A (inputs) and B (outputs) as
  a table in the module window. Edit the outputs, and **Build LUT** rebuilds
  that logic as a clean lookup table: A in a line, inverters, one AND per row,
  B as the ORs. You see a ghost preview first; afterwards the tool reloads the
  module and checks it against your table. Undo build puts the creation back.
  Two styles: **ROM** (a decoder and an OR plane) and **XOR** (positive-polarity
  Reed–Muller: XORs of shared AND terms, often much smaller); **Auto** picks
  the one with fewer gates. Settings also choose stacked or spread-out gates,
  and even timing (no glitches) or fewer gates. Builds that would break the
  game's 255 inputs/outputs per part are refused before anything changes.
- **Lua scripting**: a built-in editor with syntax highlighting, formatting and
  examples. Groups are Lua lists of parts, so wiring a decoder or a shift
  register takes a few lines:

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
| `TobyWand/Scripts/LogicGraph.lua` | Logic graph analysis: timing, loops, truth tables, delay probe |
| `TobyWand/Scripts/LogicScript.lua` | Lua interpreter, scripting API, highlighter and formatter |
| `TobyWand/Scripts/LogicModule.lua` | Modules: truth table, editing, LUT plan, blueprint rebuild |
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
