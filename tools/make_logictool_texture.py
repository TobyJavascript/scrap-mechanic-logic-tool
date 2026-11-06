"""Makes the red TobyWand texture from the game's connect tool texture.

    python3 tools/make_logictool_texture.py   (needs Pillow)

Reads the game's char_connecttool_dif.tga, turns the yellow parts red and
writes TobyWand/Objects/Textures/logictool_dif.tga. The mesh, the other
textures and the animations still come from the game files.
"""
import colorsys
import os
import sys

from PIL import Image

GAME = "/media/toby/HardDisk/SteamLibrary/steamapps/common/Scrap Mechanic/Data"
SRC = os.path.join(GAME, "Character/Char_Tools/Char_connecttool/char_connecttool_dif.tga")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "TobyWand", "Objects", "Textures", "logictool_dif.tga")

TARGET_HUE = 0.0 / 360     # red
DARKEN = 0.85              # red reads brighter than yellow at the same value


def recolor(img):
    px = img.load()
    w, h = img.size
    lut = {}
    for y in range(h):
        for x in range(w):
            rgb = px[x, y]
            out = lut.get(rgb)
            if out is None:
                r, g, b = (c / 255 for c in rgb)
                hh, s, v = colorsys.rgb_to_hsv(r, g, b)
                # yellow / orange paint: hue 20..75 degrees, clearly saturated
                if 20 / 360 <= hh <= 75 / 360 and s > 0.3:
                    r, g, b = colorsys.hsv_to_rgb(TARGET_HUE, min(1.0, s * 1.05), v * DARKEN)
                    out = (round(r * 255), round(g * 255), round(b * 255))
                else:
                    out = rgb
                lut[rgb] = out
            px[x, y] = out
    return img


def main():
    img = Image.open(SRC).convert("RGB")
    recolor(img)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    img.save(OUT, compression="tga_rle")
    print("wrote", os.path.relpath(OUT), img.size)
    if len(sys.argv) > 1:
        img.resize((768, 768)).save(sys.argv[1])


if __name__ == "__main__":
    main()
