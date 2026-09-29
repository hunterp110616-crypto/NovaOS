#!/usr/bin/env python3
# Generate an 8x8 bitmap font (ASCII 32..126) from a TTF, emit NASM db lines.
# Each glyph = 8 bytes, one per row; bit7 = leftmost pixel.
import sys
from PIL import Image, ImageFont, ImageDraw

FONT = "C:/Windows/Fonts/consola.ttf"
CELL = 8
FIRST, LAST = 32, 126

def render(size, dx, dy, thresh):
    font = ImageFont.truetype(FONT, size)
    glyphs = {}
    for code in range(FIRST, LAST + 1):
        ch = chr(code)
        img = Image.new("L", (CELL, CELL), 0)
        d = ImageDraw.Draw(img)
        d.text((dx, dy), ch, fill=255, font=font)
        rows = []
        for y in range(CELL):
            b = 0
            for x in range(CELL):
                if img.getpixel((x, y)) >= thresh:
                    b |= (1 << (7 - x))
            rows.append(b)
        glyphs[code] = rows
    return glyphs

def preview(glyphs, chars):
    for ch in chars:
        print(f"--- '{ch}' ---")
        for row in glyphs[ord(ch)]:
            print("".join('#' if row & (1 << (7 - x)) else '.' for x in range(8)))

def emit(glyphs, path):
    with open(path, "w") as f:
        f.write("; 8x8 font, ASCII 32..126, generated from Consolas\n")
        f.write("font8x8:\n")
        for code in range(FIRST, LAST + 1):
            rows = glyphs[code]
            ch = chr(code) if code != 32 else "space"
            f.write("    db " + ",".join(f"0x{r:02X}" for r in rows) +
                    f"   ; {code} {ch}\n")

if __name__ == "__main__":
    # size 8, small offset, mid threshold -- tuned for an 8px cell
    g = render(size=8, dx=0, dy=-1, thresh=100)
    if "--emit" in sys.argv:
        emit(g, "C:/Users/Hunter_admin/Desktop/NovaKernel/font8x8.inc")
        print("wrote font8x8.inc")
    else:
        preview(g, ['A', 'N', 'o', 'v', 'a', 'O', 'S', '5', '>', ':'])
