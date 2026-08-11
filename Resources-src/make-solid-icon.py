"""Generate the `solid.` pane icon: the wordmark's monogram, `s.`, on a tile.

Follows solidmon's docs/brand/make_logo.py — same font, same letter spacing,
same accent — but takes only the first glyph and the period, and sets them on
the dark tile from logo.png rather than leaving them on transparency. A pane
icon renders at 14pt against whatever theme the user runs, and a white glyph on
transparency disappears on a light background; a tile never does.

Usage:
    python3 -m venv venv && ./venv/bin/pip install fonttools
    ./venv/bin/python make-solid-icon.py > ../Sources/zmxterm/Resources/icons/solid.svg
"""
import os
import sys
import urllib.request

from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.boundsPen import BoundsPen

TEXT = "s."
ACCENT = "#D71500"          # --accent-primary
INK = "#fafafa"             # --text-primary
TILE_BG = "#0a0a0b"         # --bg-primary
LETTER_SPACING_EM = -0.04   # .hero-logo letter-spacing

SIZE = 64                   # tile edge, in SVG units
CORNER = 14                 # ~22% — an app-icon squircle at a glance
INSET = 7                   # padding around the monogram; small, so the mark still reads at 14pt

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

print(
    f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {SIZE} {SIZE}" '
    f'width="{SIZE}" height="{SIZE}">\n'
    f'  <rect width="{SIZE}" height="{SIZE}" rx="{CORNER}" ry="{CORNER}" fill="{TILE_BG}"/>\n'
    # Font coordinates are y-up; flip on the way out.
    f'  <g transform="translate({offset_x:.2f},{SIZE - offset_y:.2f}) scale({scale:.5f},{-scale:.5f})">\n'
    f'{paths}\n'
    f'  </g>\n'
    f'</svg>'
)
