#!/usr/bin/env python3
"""Make TobyWand's inventory icon: the game's own connect tool inventory icon, with the
yellow turned red (same recolour as the tool texture).

Writes TobyWand/Gui/IconMap.png and IconMap.xml (96x96 icons, MyGUI image
set, same layout as the Gears mod). Needs Pillow.

    python3 tools/make_tobywand_icon.py [preview.png]
"""
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_logictool_texture import recolor  # noqa: E402

GAME = "/media/toby/HardDisk/SteamLibrary/steamapps/common/Scrap Mechanic/Data"
TOOL_ICONS = os.path.join(GAME, "Gui/IconMap.png")
CONNECT_TOOL_FRAME = (1728, 768, 1728 + 96, 768 + 96)   # connect tool (8c7efc37-...) in Gui/IconMap.xml
MOD = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "TobyWand")
TOOL_UUID = "5b1e6c2a-8d4f-4b7e-9c3a-1f2e7d6a4c01"
ICON = 96


def main():
    src = Image.open(TOOL_ICONS).convert("RGBA").crop(CONNECT_TOOL_FRAME)
    rgb, alpha = src.convert("RGB"), src.getchannel("A")
    recolor(rgb)
    icon = rgb.convert("RGBA")
    icon.putalpha(alpha)
    icon = icon.resize((ICON, ICON), Image.LANCZOS)

    # 2x1 map: "Empty" at (0,0), the tool at (96,0)
    sheet = Image.new("RGBA", (ICON * 2, ICON), (0, 0, 0, 0))
    sheet.paste(icon, (ICON, 0))
    gui = os.path.join(MOD, "Gui")
    sheet.save(os.path.join(gui, "IconMap.png"))
    xml = f'''﻿<?xml version="1.0" encoding="UTF-8"?>
<MyGUI type="Resource" version="1.1">
    <Resource type="ResourceImageSet" name="ItemIconsSet0">
        <Group name="ItemIcons" texture="IconMap.png" size="{ICON} {ICON}">
            <Index name="Empty">
                <Frame point="0 0"/>
            </Index>
            <Index name="{TOOL_UUID}">
                <Frame point="{ICON} 0"/>
            </Index>
        </Group>
    </Resource>
</MyGUI>
'''
    with open(os.path.join(gui, "IconMap.xml"), "w", encoding="utf-8") as f:
        f.write(xml)
    print("wrote TobyWand/Gui/IconMap.png and IconMap.xml")
    if len(sys.argv) > 1:
        bg = Image.new("RGBA", (ICON * 2, ICON), (40, 40, 48, 255))
        bg.alpha_composite(icon, (0, 0))
        orig = Image.open(TOOL_ICONS).convert("RGBA").crop(CONNECT_TOOL_FRAME).resize((ICON, ICON), Image.LANCZOS)
        bg.alpha_composite(orig, (ICON, 0))
        bg.resize((ICON * 6, ICON * 3), Image.NEAREST).save(sys.argv[1])


if __name__ == "__main__":
    main()
