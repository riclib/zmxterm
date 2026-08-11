"""Draw a monogram on a rounded tile, as SVG, from real glyph outlines.

A pane icon renders at 14pt against whatever theme the user runs, so a white
glyph on transparency disappears on a light background. A tile never does, and
it makes the mark read as an app icon like the others beside it.

Glyphs are converted to paths so the file does not depend on the viewer having
the font. Letter spacing and the optical centring follow solidmon's own
docs/brand/make_logo.py, which is where the `s.` variant came from.

    ./venv/bin/python make-monogram-icon.py --text "s." --accent "#D71500"
    ./venv/bin/python make-monogram-icon.py --text "z." --accent "#3ddc97" \
        --bg "#0f1115" --size 512 --out appicon.svg
"""
import argparse
import os
import sys
import urllib.request

from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.boundsPen import BoundsPen

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--text", default="s.", help="the monogram; a trailing period takes the accent")
parser.add_argument("--accent", default="#D71500", help="colour of the period")
parser.add_argument("--ink", default="#fafafa", help="colour of the letters")
parser.add_argument("--bg", default="#0a0a0b", help="tile colour")
parser.add_argument("--size", type=int, default=64, help="tile edge in SVG units")
parser.add_argument("--corner", type=float, default=None, help="corner radius; defaults to 22%% of size")
parser.add_argument("--inset", type=float, default=None, help="padding; defaults to 11%% of size")
parser.add_argument("--out", default=None, help="output path; defaults to stdout")
args = parser.parse_args()

TEXT = args.text
ACCENT = args.accent
INK = args.ink
TILE_BG = args.bg
LETTER_SPACING_EM = -0.04   # solidmon's .hero-logo letter-spacing

SIZE = args.size
# 22% reads as an app-icon squircle at a glance; the inset stays small so the
# mark still carries at 14pt.
CORNER = args.corner if args.corner is not None else SIZE * 0.22
INSET = args.inset if args.inset is not None else SIZE * 0.11

FONT_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "JetBrainsMono-Bold.ttf")
FONT_URL = "https://github.com/JetBrains/JetBrainsMono/raw/master/fonts/ttf/JetBrainsMono-Bold.ttf"

if not os.path.exists(FONT_FILE):
    print(f"downloading {FONT_URL}", file=sys.stderr)
    urllib.request.urlretrieve(FONT_URL, FONT_FILE)

font = TTFont(FONT_FILE)
glyph_set = font.getGlyphSet()
cmap = font.getBestCmap()
upm = font["head"].unitsPerEm
spacing = LETTER_SPACING_EM * upm

# Position each glyph on the baseline, keeping the wordmark's tracking.
chars = []
pen_x = 0.0
for ch in TEXT:
    glyph = glyph_set[cmap[ord(ch)]]
    pen = SVGPathPen(glyph_set)
    glyph.draw(pen)
    chars.append({"char": ch, "d": pen.getCommands(), "x": pen_x})
    pen_x += glyph.width + spacing

# Tight ink box of the positioned pair, so the monogram is optically centred
# rather than centred on the font's metrics (which would sit it high).
min_x = min_y = float("inf")
max_x = max_y = float("-inf")
for c in chars:
    bounds_pen = BoundsPen(glyph_set)
    glyph_set[cmap[ord(c["char"])]].draw(bounds_pen)
    if bounds_pen.bounds is None:
        continue
    x0, y0, x1, y1 = bounds_pen.bounds
    min_x, max_x = min(min_x, x0 + c["x"]), max(max_x, x1 + c["x"])
    min_y, max_y = min(min_y, y0), max(max_y, y1)

ink_w, ink_h = max_x - min_x, max_y - min_y
content = SIZE - 2 * INSET
scale = min(content / ink_w, content / ink_h)
offset_x = (SIZE - ink_w * scale) / 2
offset_y = (SIZE - ink_h * scale) / 2

paths = "\n".join(
    f'    <path transform="translate({c["x"] - min_x:.1f},{-min_y:.1f})" '
    f'fill="{ACCENT if c["char"] == "." else INK}" d="{c["d"]}"/>'
    for c in chars if c["d"]
)

svg = (
    f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {SIZE} {SIZE}" '
    f'width="{SIZE}" height="{SIZE}">\n'
    f'  <rect width="{SIZE}" height="{SIZE}" rx="{CORNER:.1f}" ry="{CORNER:.1f}" fill="{TILE_BG}"/>\n'
    # Font coordinates are y-up; flip on the way out.
    f'  <g transform="translate({offset_x:.2f},{SIZE - offset_y:.2f}) scale({scale:.5f},{-scale:.5f})">\n'
    f'{paths}\n'
    f'  </g>\n'
    f'</svg>'
)

if args.out:
    with open(args.out, "w") as handle:
        handle.write(svg + "\n")
else:
    print(svg)
