"""Generates the MyGUI layouts for the TobyWand.

    python3 tools/make_logictool_layout.py

Writes TobyWand/Gui/Layouts/LogicTool.layout and LogicTool_Label.layout.
Positions are position_real (0..1, relative to the parent widget).
"""
import os
from xml.sax.saxutils import quoteattr

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "TobyWand", "Gui", "Layouts")

PAD = 0.03          # left/right padding inside the panel
ROW_H = 0.040       # button row height
GAP = 0.008         # vertical gap between rows


def prop(key, value):
    return f'<Property key="{key}" value={quoteattr(str(value))}/>'


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
    kids.append(button(1 - PAD - 0.2 - 0.012 - 0.26, y + 0.005, 0.26, 0.035, "< Script", "openScript"))
    kids.append(button(1 - PAD - 0.2, y + 0.005, 0.2, 0.035, "Close", "close", skin=CLOSE_SKIN))
    y += 0.055

    # Groups
    kids.append(section(y, "GROUPS"))
    y += 0.032
    kids.append(button(PAD, y, 0.28, ROW_H, "Active: A", "active"))
    kids.append(text(PAD + 0.30, y, 1 - 2 * PAD - 0.30, ROW_H, "A 0   B 0   C 0", name="groupInfo", align="Left VCenter"))
    y += ROW_H + GAP
    kids += button_row(y, [("clearActive", "Clear group"), ("clearAll", "Clear all groups")])
    y += ROW_H + GAP
    kids += button_row(y, [("sortX", "Sort X"), ("sortY", "Sort Y"), ("sortZ", "Sort Z"), ("reverse", "Reverse")])
    y += ROW_H + GAP + 0.005

    # Connect
    kids.append(section(y, "CONNECT   A  >  B"))
    y += 0.032
    kids += button_row(y, [("allToAll", "All > All"), ("zip", "Zip 1:1"), ("chain", "Chain: A"), ("undo", "Undo")])
    y += ROW_H + GAP
    kids += button_row(y, [("wireMode", "Mode: Connect"), ("clearIn", "Clear inputs: A"), ("clearOut", "Clear outputs: A")])
    y += ROW_H + GAP + 0.005

    # Analyse
    kids.append(section(y, "ANALYSE"))
    y += 0.032
    kids += button_row(y, [("timing", "Timing A > B"), ("truth", "Truth table"), ("lint", "Check creation")])
    y += ROW_H + GAP
    kids += button_row(y, [("probeFwd", "Delays from A"), ("probeBack", "Delays to A"), ("clearMarks", "Clear marks")])
    y += ROW_H + GAP + 0.005

    # Tool settings
    kids.append(section(y, "SETTINGS"))
    y += 0.032
    kids += button_row(y, [("boxMode", "Box (Q): 3D box"), ("pickBy", "F: type + colour")])
    y += ROW_H + GAP
    kids += button_row(y, [("lines", "Lines: off"), ("labels", "Labels: off")])
    y += ROW_H + GAP + 0.005

    # Results
    kids.append(section(y, "RESULT"))
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
    row = button_row(y, [("help", "Help"), ("example", "Example"), ("format", "Format"), ("run", "Run")])
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
    y += ROW_H + GAP + 0.005
    sk.append(edit_box(PAD, y, 1 - 2 * PAD, 1 - y - 0.02, "script"))
    script = W("Widget", "HudBackgroundLarge", 0.02, 0.06, 0.36, 0.88, "scriptWindow",
               props=[("Visible", "false")], children=sk)
    return [panel, script]


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
