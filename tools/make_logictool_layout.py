"""Generates the MyGUI layouts for the TobyWand.

    python3 tools/make_logictool_layout.py

Writes TobyWand/Gui/Layouts/LogicTool.layout, LogicTool_Label.layout and
LogicTool_Step.layout (the step debugger HUD).
Positions are position_real (0..1, relative to the parent widget).
"""
import os
from xml.sax.saxutils import quoteattr

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "TobyWand", "Gui", "Layouts")

PAD = 0.03          # left/right padding inside the panel
ROW_H = 0.040       # button row height
GAP = 0.008         # vertical gap between rows


def prop(key, value):
    value = str(value)
    # The game's XML reader rejects a layout with ' in an attribute ("XML file
    # contain incorrect attribute") and then shows an empty menu.
    assert "'" not in value, f"no apostrophes in layout text: {value!r}"
    return f'<Property key="{key}" value={quoteattr(value)}/>'


class W:
    def __init__(self, type_, skin, x, y, w, h, name=None, props=None, children=None):
        self.type, self.skin = type_, skin
        self.pos = (x, y, w, h)
        self.name = name
        self.props = props or []
        self.children = children or []

    def xml(self, depth=1):
        ind = "    " * depth
        name = f' name="{self.name}"' if self.name else ""
        pos = " ".join(f"{v:.4f}" for v in self.pos)
        head = f'{ind}<Widget type="{self.type}" skin="{self.skin}" position_real="{pos}"{name}>'
        inner = [ind + "    " + prop(k, v) for k, v in self.props]
        inner += [c.xml(depth + 1) for c in self.children]
        return "\n".join([head] + inner + [f"{ind}</Widget>"])


def text(x, y, w, h, caption, name=None, font="SM_TextLabel", align="Left VCenter", colour=None):
    props = [("Caption", caption), ("TextAlign", align), ("FontName", font)]
    if colour:
        props.append(("TextColour", colour))
    return W("TextBox", "TextBox", x, y, w, h, name, props)


def button(x, y, w, h, caption, name, skin="PrimaryButton", colour=None):
    props = [("Caption", caption), ("FontName", "SM_ButtonTiny"), ("TextAlign", "Center")]
    if colour:
        props.append(("TextColour", colour))
    return W("Button", skin, x, y, w, h, name, props)


# Buttons that stand out from the yellow ones (game styles)
CLOSE_SKIN = "SecondaryButton"          # dark with a white outline, like the game's Cancel/Back
RUN_SKIN = "SchematicbotButtonGreen"    # green: the script window's main action
SETTING_SKIN = "SchematicbotButtonBlue" # blue outline: buttons that cycle a mode instead of doing something


def overlay_caption(btn, skin, caption, name=None):
    """These game styles have no text of their own; like the game's dressbot
    menu, put a text box on top that lets clicks through to the button. Give
    it a name to change the caption from Lua."""
    btn.skin = skin
    btn.props = []
    btn.children.append(W("TextBox", "TextBox", 0, 0, 1, 1, name, [
        ("Caption", caption), ("FontName", "SM_ButtonTiny"), ("TextAlign", "Center"),
        ("TextColour", "1 1 1"), ("NeedMouse", "false"), ("NeedKey", "false"),
    ]))
    return btn


def blue(btn):
    """A blue button: its caption is the text box <name>Text."""
    caption = dict(btn.props).get("Caption", "")
    return overlay_caption(btn, SETTING_SKIN, caption, btn.name + "Text")


def dropdown(x, y, w, h, name):
    """An empty spot the game fills with its dropdown (createDropDown in Lua)."""
    return W("Widget", "PanelEmpty", x, y, w, h, name)


def as_dropdown(btn):
    """The same place as a button from button_row, as a dropdown."""
    return dropdown(*btn.pos, btn.name)


def button_row(y, items):
    """items: list of (name, caption). Spread evenly across the panel."""
    n = len(items)
    gap = 0.012
    w = (1 - 2 * PAD - gap * (n - 1)) / n
    return [button(PAD + i * (w + gap), y, w, ROW_H, cap, name) for i, (name, cap) in enumerate(items)]


def section(y, caption):
    return text(PAD, y, 1 - 2 * PAD, 0.03, caption, font="SM_HeaderTiny", colour="0.85 0.65 0.2")


def edit_box(x, y, w, h, name, read_only=False, caption=""):
    props = [
        ("MultiLine", "true"),
        ("WordWrap", "true"),
        ("TextAlign", "Left Top"),
        ("FontName", "SM_TextSmall"),
        ("TextColour", "1 1 1"),
        ("MaxTextLength", "100000"),
        ("VisibleVScroll", "true"),
        ("Caption", caption),
    ]
    if read_only:
        props.append(("ReadOnly", "true"))
    else:
        props.append(("TabPrinting", "true"))
    bg = W("Widget", "SearchBarBackground", x, y, w, h)
    bg.children.append(W("EditBox", "EditBoxStretch", 0.01, 0.02, 0.98, 0.96, name, props))
    return bg


def main_layout():
    """The menu (right) and the script window (left, hidden until opened)."""
    kids = []
    y = 0.015
    kids.append(text(PAD, y, 0.4, 0.045, "TOBYWAND", font="SM_Button"))
    kids.append(button(1 - PAD - 0.2, y + 0.005, 0.2, 0.035, "Close", "close", skin=CLOSE_SKIN))
    y += 0.055
    # windows that open on the left (one at a time)
    kids += [blue(b) for b in button_row(y, [("openScript", "< Script"), ("openModule", "< Module"),
                                             ("openDebug", "< Debug"), ("openSettings", "< Settings")])]
    y += ROW_H + GAP + 0.005

    # Groups
    kids.append(section(y, "GROUPS"))
    y += 0.032
    kids.append(dropdown(PAD, y, 0.28, ROW_H, "active"))
    kids.append(text(PAD + 0.30, y, 1 - 2 * PAD - 0.30, ROW_H, "A 0   B 0   C 0", name="groupInfo", align="Left VCenter"))
    y += ROW_H + GAP
    kids += button_row(y, [("clearActive", "Clear group"), ("clearAll", "Clear all groups")])
    y += ROW_H + GAP
    kids += button_row(y, [("sortX", "Sort X"), ("sortY", "Sort Y"), ("sortZ", "Sort Z"), ("reverse", "Reverse")])
    y += ROW_H + GAP + 0.005

    # Connect
    kids.append(section(y, "CONNECT   A  >  B"))
    y += 0.032
    row = button_row(y, [("wireMode", "Mode: Connect"), ("allToAll", "All > All"), ("zip", "Zip 1:1"), ("undo", "Undo")])
    row[0] = as_dropdown(row[0])
    kids += row
    y += ROW_H + GAP
    kids += button_row(y, [("chain", "Chain: A"), ("ring", "Ring: A"), ("selfWire", "Self: A")])
    y += ROW_H + GAP
    kids += button_row(y, [("clearIn", "Clear inputs: A"), ("clearOut", "Clear outputs: A")])
    y += ROW_H + GAP + 0.005

    # Bulk edit (rebuilds the creation, like Build LUT)
    kids.append(section(y, "EDIT   active group"))
    y += 0.032
    row = button_row(y, [("bulkMode", "Gate: XOR"), ("setGates", "Set gates: A")])
    row[0] = as_dropdown(row[0])
    kids += row
    y += ROW_H + GAP
    half = (1 - 2 * PAD - 0.012) / 2
    kids.append(text(PAD, y, 0.14, ROW_H, "Timer", font="SM_TextLabel"))
    kids.append(line_edit(PAD + 0.14, y, half - 0.14, ROW_H, "bulkTimer"))
    kids.append(button(PAD + half + 0.012, y, half, ROW_H, "Set timers: A", "setTimers"))
    y += ROW_H + GAP + 0.005

    # Results
    kids.append(section(y, "STANDARD OUTPUT"))
    y += 0.032
    result_h = 1 - y - 0.02
    kids.append(edit_box(PAD, y, 1 - 2 * PAD, result_h, "result", read_only=True,
                         caption="Select parts, then press a button."))

    panel = W("Widget", "HudBackgroundLarge", 0.62, 0.06, 0.36, 0.88, "panel", children=kids)

    # Script window
    sk = []
    y = 0.015
    sk.append(text(PAD, y, 0.4, 0.045, "SCRIPT", font="SM_Button"))
    sk.append(button(1 - PAD - 0.2, y + 0.005, 0.2, 0.035, "Hide", "closeScript", skin=CLOSE_SKIN))
    y += 0.055
    row = button_row(y, [("help", "Help"), ("format", "Format"), ("run", "Run")])
    # this game style has no text of its own; like the game's dressbot menu,
    # put a text box on top that lets clicks through to the button
    run = row[-1]
    run.skin = RUN_SKIN
    run.props = []
    run.children.append(W("TextBox", "TextBox", 0, 0, 1, 1, None, [
        ("Caption", "Run"), ("FontName", "SM_ButtonTiny"), ("TextAlign", "Center"),
        ("TextColour", "1 1 1"), ("NeedMouse", "false"), ("NeedKey", "false"),
    ]))
    sk += row
    y += ROW_H + GAP
    # the script library: < name > Save Delete (saved scripts, then the examples)
    sk.append(button(PAD, y, 0.08, ROW_H, "<", "libPrev"))
    sk.append(line_edit(PAD + 0.09, y, 0.38, ROW_H, "scriptName"))
    sk.append(button(PAD + 0.48, y, 0.08, ROW_H, ">", "libNext"))
    sk.append(button(PAD + 0.57, y, 0.18, ROW_H, "Save", "libSave"))
    sk.append(button(PAD + 0.76, y, 1 - 2 * PAD - 0.76, ROW_H, "Delete", "libDelete"))
    y += ROW_H + GAP + 0.005
    sk.append(edit_box(PAD, y, 1 - 2 * PAD, 1 - y - 0.02, "script"))
    script = W("Widget", "HudBackgroundLarge", 0.02, 0.06, 0.36, 0.88, "scriptWindow",
               props=[("Visible", "false")], children=sk)
    return [panel, script, settings_window(), module_window(), debug_window()]


def module_window():
    """Module (left, hidden until opened): load A > B and show it as a table."""
    mk = []
    y = 0.015
    mk.append(text(PAD, y, 0.4, 0.045, "MODULE", font="SM_Button"))
    mk.append(button(1 - PAD - 0.2, y + 0.005, 0.2, 0.035, "Hide", "closeModule", skin=CLOSE_SKIN))
    y += 0.055
    mk += button_row(y, [("loadModule", "Load A > B"), ("resetModule", "Reset table")])
    y += ROW_H + GAP
    mk += button_row(y, [("buildLut", "Build LUT"), ("cancelLut", "Cancel"), ("undoLut", "Undo build")])
    y += ROW_H + GAP + 0.005
    info_h = 0.30
    mk.append(edit_box(PAD, y, 1 - 2 * PAD, info_h, "moduleInfo", read_only=True))
    y += info_h + GAP
    mk.append(section(y, "TABLE   (edit the output digits)"))
    y += 0.032
    mk.append(edit_box(PAD, y, 1 - 2 * PAD, 1 - y - 0.02, "moduleTable"))
    return W("Widget", "HudBackgroundLarge", 0.02, 0.06, 0.36, 0.88, "moduleWindow",
             props=[("Visible", "false")], children=mk)


def settings_window():
    """Tool settings (left, hidden until opened). One row per setting:
    name on the left, a dropdown with the value on the right, and a
    short explanation under it."""
    st = []
    y = 0.015
    st.append(text(PAD, y, 0.4, 0.045, "SETTINGS", font="SM_Button"))
    st.append(button(1 - PAD - 0.2, y + 0.005, 0.2, 0.035, "Hide", "closeSettings", skin=CLOSE_SKIN))
    y += 0.07
    rows = [
        ("boxMode", "Box select (Q)", "3D box", "Shape of a drag select. Layers keep it one block thick, like block drag in the game."),
        ("pickBy", "F + click picks", "type + colour", "Which parts count as the same when you F + click one."),
        ("lines", "Wire lines", "Off", "Draw the wires of selected parts in the world, red when on."),
        ("labels", "Part labels", "Order", "Text over selected parts: order in group, type, or delay."),
        ("lutStyle", "LUT style", "Auto", "ROM: a row AND per 1, OR outputs. XOR: Reed-Muller terms, XOR outputs. Auto: the smaller."),
        ("lutCompress", "LUT gates", "Spread out", "Stacked puts each column of new LUT gates in one block."),
        ("lutEven", "LUT timing", "Even timing", "Even gives every path the same ticks, so nothing glitches. Fewer gates skips the extra gates."),
    ]
    split = 0.45
    for name, label, value, desc in rows:
        st.append(text(PAD, y, split - PAD, ROW_H, label, font="SM_TextLabel"))
        st.append(dropdown(split, y, 1 - PAD - split, ROW_H, name))
        y += ROW_H + 0.004
        # read-only EditBox: unlike TextBox it wraps long lines (same as the result box)
        st.append(W("EditBox", "EditBoxStretch", PAD, y, 1 - 2 * PAD, 0.05, None, [
            ("Caption", desc), ("TextAlign", "Left Top"), ("FontName", "SM_TextSmall"),
            ("TextColour", "0.7 0.7 0.7"), ("MultiLine", "true"), ("WordWrap", "true"),
            ("ReadOnly", "true"), ("NeedMouse", "false"), ("NeedKey", "false"),
        ]))
        y += 0.05 + GAP + 0.01
    return W("Widget", "HudBackgroundLarge", 0.02, 0.06, 0.36, 0.88, "settingsWindow",
             props=[("Visible", "false")], children=st)


def line_edit(x, y, w, h, name, caption=""):
    """A one-line text field."""
    bg = W("Widget", "SearchBarBackground", x, y, w, h)
    bg.children.append(W("EditBox", "EditBoxStretch", 0.03, 0.05, 0.94, 0.9, name, [
        ("MultiLine", "false"), ("TextAlign", "Left VCenter"), ("FontName", "SM_TextLabel"),
        ("TextColour", "1 1 1"), ("MaxTextLength", "64"), ("Caption", caption),
    ]))
    return bg


def debug_window():
    """Debug (left, hidden until opened): the analysis buttons, and the tick
    debugger that steps the logic between A and B."""
    dk = []
    y = 0.015
    dk.append(text(PAD, y, 0.4, 0.045, "DEBUG", font="SM_Button"))
    dk.append(button(1 - PAD - 0.2, y + 0.005, 0.2, 0.035, "Hide", "closeDebug", skin=CLOSE_SKIN))
    y += 0.055

    dk.append(section(y, "ANALYSE   (output on the right)"))
    y += 0.032
    dk += button_row(y, [("timing", "Timing A > B"), ("truth", "Truth table"), ("lint", "Check creation")])
    y += ROW_H + GAP
    dk += button_row(y, [("probeFwd", "Delays from A"), ("probeBack", "Delays to A"), ("clearMarks", "Clear marks")])
    y += ROW_H + GAP + 0.01

    dk.append(section(y, "STEP   A  >  B, one tick at a time"))
    y += 0.032
    split = 0.3
    dk.append(text(PAD, y, split - PAD, ROW_H, "Inputs A", font="SM_TextLabel"))
    dk.append(line_edit(split, y, 0.38, ROW_H, "debugInputs"))
    dk.append(button(split + 0.4, y, 1 - PAD - split - 0.4, ROW_H, "From game", "debugFromGame"))
    y += ROW_H + GAP
    dk.append(text(PAD, y, split - PAD, ROW_H, "Run speed", font="SM_TextLabel"))
    dk.append(line_edit(split, y, 0.2, ROW_H, "debugSpeed"))
    dk.append(text(split + 0.22, y, 1 - PAD - split - 0.22, ROW_H, "seconds per tick (Q runs)", font="SM_TextSmall",
                   colour="0.7 0.7 0.7"))
    y += ROW_H + GAP
    dk.append(text(PAD, y, split - PAD, ROW_H, "Input mode", font="SM_TextLabel"))
    dk.append(dropdown(split, y, 1 - PAD - split, ROW_H, "debugHold"))
    y += ROW_H + GAP
    dk.append(text(PAD, y, split - PAD, ROW_H, "Pulse every", font="SM_TextLabel"))
    dk.append(line_edit(split, y, 0.2, ROW_H, "debugEvery"))
    dk.append(text(split + 0.22, y, 1 - PAD - split - 0.22, ROW_H, "ticks (Pulse every mode)", font="SM_TextSmall",
                   colour="0.7 0.7 0.7"))
    y += ROW_H + GAP
    dk += [overlay_caption(b, RUN_SKIN, "Start debug") for b in button_row(y, [("debugStart", "Start debug")])]
    y += ROW_H + GAP + 0.005
    dk.append(edit_box(PAD, y, 1 - 2 * PAD, 1 - y - 0.02, "debugInfo", read_only=True))
    return W("Widget", "HudBackgroundLarge", 0.02, 0.06, 0.36, 0.88, "debugWindow",
             props=[("Visible", "false")], children=dk)


def step_hud():
    """The small panel shown while stepping (a HUD: no mouse, you keep
    looking around). Top middle of the screen."""
    def line(y, h, name, font, colour="1 1 1"):
        return W("TextBox", "TextBox", 0.04, y, 0.92, h, name, [
            ("Caption", ""), ("TextAlign", "Left VCenter"), ("FontName", font), ("TextColour", colour),
            ("TextShadow", "true"), ("TextShadowColour", "0 0 0"), ("NeedMouse", "false"), ("NeedKey", "false"),
        ])
    kids = [
        line(0.06, 0.26, "stepTick", "SM_Button"),
        line(0.32, 0.2, "stepOutputs", "SM_TextLabel"),
        line(0.52, 0.2, "stepInfo", "SM_TextSmall"),
        line(0.74, 0.2, "stepKeys", "SM_TextSmall", "0.75 0.75 0.75"),
    ]
    return W("Widget", "HudBackgroundLarge", 0.33, 0.02, 0.34, 0.13, "stepPanel",
             [("NeedMouse", "false"), ("NeedKey", "false")], kids)


def write(name, roots):
    os.makedirs(ROOT, exist_ok=True)
    if not isinstance(roots, list):
        roots = [roots]
    body = "\n".join(r.xml(1) for r in roots)
    out = f'<?xml version="1.0" encoding="UTF-8"?>\n<MyGUI type="Layout" version="3.2.0">\n{body}\n    <CodeGeneratorSettings/>\n</MyGUI>\n'
    path = os.path.join(ROOT, name)
    with open(path, "w", encoding="utf-8") as f:
        f.write(out)
    print("wrote", os.path.relpath(path))


def label_layout():
    # A world-space label. The ImageBox root has no visuals; the text has a shadow.
    t = W("TextBox", "TextBox", 0, 0, 1, 1, "Text", [
        ("Caption", ""),
        ("TextAlign", "Center"),
        ("FontName", "SM_TextLabel"),
        ("TextColour", "1 1 1"),
        ("TextShadow", "true"),
        ("TextShadowColour", "0 0 0"),
        ("NeedMouse", "false"),
        ("NeedKey", "false"),
    ])
    return W("Widget", "PanelEmpty", 0, 0, 1, 1, "Root", [("NeedMouse", "false"), ("NeedKey", "false")], [t])


if __name__ == "__main__":
    write("LogicTool.layout", main_layout())
    write("LogicTool_Label.layout", label_layout())
    write("LogicTool_Step.layout", step_hud())
