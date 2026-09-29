#!/usr/bin/env python3
# Generate a crisp 8x16 bitmap font (ASCII 32..126) from Consolas.
# Each glyph = 16 bytes (one per row), bit7 = leftmost pixel.
import sys
from PIL import Image, ImageFont, ImageDraw

FONT = "C:/Windows/Fonts/consola.ttf"
CW, CH = 8, 16
FIRST, LAST = 32, 126

def build(size, thresh):
    font = ImageFont.truetype(FONT, size)
    glyphs = {}
    ascent, descent = font.getmetrics()
    # Draw EVERY glyph from the same origin so they share one baseline.
    # baseline row = ascent - top_pad; nudge so caps fit and descenders show.
    top_pad = 1
    dx = 1
    for code in range(FIRST, LAST + 1):
        ch = chr(code)
        cell = Image.new("L", (CW, CH), 0)
        ImageDraw.Draw(cell).text((dx, top_pad), ch, fill=255, font=font)
        rows = []
        for y in range(CH):
            b = 0
            for x in range(CW):
                if cell.getpixel((x, y)) >= thresh:
                    b |= (1 << (7 - x))
            rows.append(b)
        glyphs[code] = rows
    return glyphs

def preview(g, chars):
    for ch in chars:
        print(f"--- '{ch}' ---")
        for row in g[ord(ch)]:
            print("".join('#' if row & (1 << (7 - x)) else '.' for x in range(8)))

def emit(g, path):
    with open(path, "w") as f:
        f.write("; 8x16 font, ASCII 32..126, generated from Consolas\n")
        f.write("font8x16:\n")
        for code in range(FIRST, LAST + 1):
            rows = g[code]
            # comment carries only the code number -- never the raw glyph char,
            # so a '\' (or other) can't become a NASM line-continuation.
            f.write("    db " + ",".join(f"0x{r:02X}" for r in rows) + f"   ; code {code}\n")

if __name__ == "__main__":
    g = build(size=15, thresh=110)
    if "--emit" in sys.argv:
        emit(g, "C:/Users/Hunter_admin/Desktop/NovaKernel/font8x16.inc")
        print("wrote font8x16.inc")
    else:
        preview(g, ['H', 'e', 'N', 'A', 'o', 'g', 'm', '5', 'B', 'p'])
