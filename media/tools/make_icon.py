"""Draws icon.svg, the Godotite project icon: the LOD triangle cut in thirds, finer toward its
bottom-left corner, each triangle colored by its level as the level debug view does.

    python3 media/tools/make_icon.py icon.svg

Chosen from candidates on 2026-10-19 ("c2_thirds"). The output is deterministic: rerunning it
gives the same file byte for byte.
"""
import math
import sys

BG = "#1f2a44"                                         # deep blue backdrop and stroke
LEVEL_COLORS = {0: "#ffd166", 1: "#7bd389", 2: "#4ecdc4"}  # coarsest to finest
CORNER = (14, 112)       # detail grows toward this point
R_LEVEL1, R_LEVEL2 = 80, 46  # a triangle whose center is nearer than these is split again


def tri(a, b, c, fill):
    pts = " ".join(f"{x:.2f},{y:.2f}" for x, y in (a, b, c))
    return (f'<polygon points="{pts}" fill="{fill}" stroke="{BG}" stroke-width="1.4"'
            ' stroke-linejoin="round"/>')


def mid(p, q):
    return ((p[0] + q[0]) / 2, (p[1] + q[1]) / 2)


def thirds(a, b, c):
    """The triangle cut into nine on a 3-per-side lattice."""
    P = lambda i, j: (a[0] + (b[0] - a[0]) * i / 3 + (c[0] - a[0]) * j / 3,
                      a[1] + (b[1] - a[1]) * i / 3 + (c[1] - a[1]) * j / 3)
    tris = []
    for i in range(3):
        for j in range(3 - i):
            tris.append((P(i, j), P(i + 1, j), P(i, j + 1)))
            if i + j < 2:
                tris.append((P(i + 1, j), P(i + 1, j + 1), P(i, j + 1)))
    return tris


def icon():
    out = []

    def split(a, b, c, depth):
        cx = (a[0] + b[0] + c[0]) / 3
        cy = (a[1] + b[1] + c[1]) / 3
        dist = math.hypot(cx - CORNER[0], cy - CORNER[1])
        want = 2 if dist < R_LEVEL2 else 1 if dist < R_LEVEL1 else 0
        if depth >= want:
            out.append(tri(a, b, c, LEVEL_COLORS[depth]))
            return
        ab, bc, ca = mid(a, b), mid(b, c), mid(c, a)
        for t in ((a, ab, ca), (ab, b, bc), (ca, bc, c), (ab, bc, ca)):
            split(*t, depth + 1)

    for t in thirds((64, 14), (116, 110), (12, 110)):
        split(*t, 0)
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">'
            f'<rect width="128" height="128" rx="24" fill="{BG}"/>' + "".join(out) + "</svg>\n")


with open(sys.argv[1], "w") as f:
    f.write(icon())
