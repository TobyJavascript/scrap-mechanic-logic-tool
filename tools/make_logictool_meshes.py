#!/usr/bin/env python3
"""Generate the TobyWand's wire and arrowhead meshes (.obj).

Units are blocks (1 block = 0.25 m), centred on the origin, long axis Y, like
the game's meshes (same convention as make_gears.py). Both fill a 1x1x1 block:

  logictool_wire.obj   smooth round tube, radius 0.5, y -0.5 .. 0.5, no caps
  logictool_arrow.obj  smooth cone, base radius 0.5 at y=-0.5, tip at y=0.5
  logictool_frame.obj  the 12 edges of a 1x1x1 box (selection frame)
  logictool_dot.obj    smooth sphere, radius 0.5 (wire mode dots)

The tool scales them per connection (ShapeRenderable scale s = s metres).

    python3 tools/make_logictool_meshes.py
"""
import math
import os

SIDES = 16
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "TobyWand", "Objects", "Mesh")


def write(path, verts, normals, uvs, faces, header):
    with open(path, "w") as fh:
        fh.write(header)
        for x, y, z in verts:
            fh.write(f"v {x:.5f} {y:.5f} {z:.5f}\n")
        for u, v in uvs:
            fh.write(f"vt {u:.5f} {v:.5f}\n")
        for x, y, z in normals:
            fh.write(f"vn {x:.5f} {y:.5f} {z:.5f}\n")
        for tri in faces:
            fh.write("f " + " ".join(f"{i}/{i}/{i}" for i in tri) + "\n")
    print("wrote", os.path.relpath(path), len(faces), "triangles")


def ring(i):
    a = 2 * math.pi * i / SIDES
    return math.cos(a), math.sin(a)


def wire():
    v, n, t, f = [], [], [], []
    for i in range(SIDES + 1):
        c, s = ring(i)
        for y in (-0.5, 0.5):
            v.append((0.5 * c, y, 0.5 * s))
            n.append((c, 0.0, s))           # smooth: radial normals
            t.append((i / SIDES, y + 0.5))
    for i in range(SIDES):
        a, b = 2 * i + 1, 2 * i + 2          # bottom, top of this column (1-based)
        c, d = a + 2, b + 2                  # next column
        # counter-clockwise seen from outside
        f.append((a, b, d))
        f.append((a, d, c))
    write(os.path.join(OUT, "logictool_wire.obj"), v, n, t, f,
          "# TobyWand wire: tube r=0.5, y -0.5..0.5 (blocks)\n")


def arrow():
    v, n, t, f = [], [], [], []
    slope = 0.5 / 1.0                        # radius / height
    ny = slope / math.sqrt(1 + slope * slope)
    nr = 1 / math.sqrt(1 + slope * slope)
    # side: one tip vertex per segment so the normals stay smooth
    for i in range(SIDES):
        c0, s0 = ring(i)
        c1, s1 = ring(i + 1)
        cm, sm = ring(i + 0.5)
        base = len(v)
        v += [(0.5 * c0, -0.5, 0.5 * s0), (0.0, 0.5, 0.0), (0.5 * c1, -0.5, 0.5 * s1)]
        n += [(c0 * nr, ny, s0 * nr), (cm * nr, ny, sm * nr), (c1 * nr, ny, s1 * nr)]
        t += [(i / SIDES, 0.0), ((i + 0.5) / SIDES, 1.0), ((i + 1) / SIDES, 0.0)]
        f.append((base + 1, base + 2, base + 3))
    # base cap, facing -Y
    centre = len(v) + 1
    v.append((0.0, -0.5, 0.0))
    n.append((0.0, -1.0, 0.0))
    t.append((0.5, 0.5))
    first = len(v) + 1
    for i in range(SIDES):
        c, s = ring(i)
        v.append((0.5 * c, -0.5, 0.5 * s))
        n.append((0.0, -1.0, 0.0))
        t.append((0.5 + 0.5 * c, 0.5 + 0.5 * s))
    for i in range(SIDES):
        a = first + i
        b = first + (i + 1) % SIDES
        f.append((centre, a, b))
    write(os.path.join(OUT, "logictool_arrow.obj"), v, n, t, f,
          "# TobyWand arrowhead: cone r=0.5 at y=-0.5, tip at y=0.5 (blocks)\n")


FRAME_EDGE = 0.07   # edge thickness, fraction of the box size


def frame():
    v, n, t, f = [], [], [], []

    def box(lo, hi):
        (x0, y0, z0), (x1, y1, z1) = lo, hi
        faces = [
            ((1, 0, 0), [(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)]),
            ((-1, 0, 0), [(x0, y0, z1), (x0, y1, z1), (x0, y1, z0), (x0, y0, z0)]),
            ((0, 1, 0), [(x0, y1, z0), (x0, y1, z1), (x1, y1, z1), (x1, y1, z0)]),
            ((0, -1, 0), [(x0, y0, z1), (x0, y0, z0), (x1, y0, z0), (x1, y0, z1)]),
            ((0, 0, 1), [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)]),
            ((0, 0, -1), [(x1, y0, z0), (x0, y0, z0), (x0, y1, z0), (x1, y1, z0)]),
        ]
        for normal, quad in faces:
            base = len(v) + 1
            for k, p in enumerate(quad):
                v.append(p)
                n.append(normal)
                t.append(((0, 0), (1, 0), (1, 1), (0, 1))[k])
            f.append((base, base + 1, base + 2))
            f.append((base, base + 2, base + 3))

    h, e = 0.5, FRAME_EDGE
    for a in (-1, 1):
        for b in (-1, 1):
            # edges along X (full length), Y and Z (between the X edges)
            box((-h, a * h - (e if a > 0 else 0), b * h - (e if b > 0 else 0)),
                (h, a * h + (0 if a > 0 else e), b * h + (0 if b > 0 else e)))
            box((a * h - (e if a > 0 else 0), -h + e, b * h - (e if b > 0 else 0)),
                (a * h + (0 if a > 0 else e), h - e, b * h + (0 if b > 0 else e)))
            box((a * h - (e if a > 0 else 0), b * h - (e if b > 0 else 0), -h + e),
                (a * h + (0 if a > 0 else e), b * h + (0 if b > 0 else e), h - e))
    write(os.path.join(OUT, "logictool_frame.obj"), v, n, t, f,
          "# TobyWand selection frame: 12 edges of a box -0.5..0.5 (blocks)\n")


DOT_RINGS = 8   # latitude bands; SIDES around


def dot():
    v, n, t, f = [], [], [], []
    for r in range(DOT_RINGS + 1):
        lat = math.pi * r / DOT_RINGS - math.pi / 2      # -90 .. 90 degrees
        y, rad = math.sin(lat), math.cos(lat)
        for i in range(SIDES + 1):
            c, s = ring(i)
            v.append((0.5 * rad * c, 0.5 * y, 0.5 * rad * s))
            n.append((rad * c, y, rad * s))            # smooth: points outward
            t.append((i / SIDES, r / DOT_RINGS))
    row = SIDES + 1
    for r in range(DOT_RINGS):
        for i in range(SIDES):
            a = r * row + i + 1                          # this band, 1-based
            b = a + row                                  # the band above
            # counter-clockwise seen from outside
            f.append((a, b, b + 1))
            f.append((a, b + 1, a + 1))
    write(os.path.join(OUT, "logictool_dot.obj"), v, n, t, f,
          "# TobyWand wire mode dot: sphere r=0.5 (blocks)\n")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    wire()
    arrow()
    frame()
    dot()
