#!/usr/bin/env python3
# Generate NovaOS's 8x16 bitmap font (ASCII 32..126) from DejaVu Sans Mono
# (a free font: Bitstream Vera / DejaVu licence -- fine to redistribute).
import sys, os
from PIL import Image, ImageFont, ImageDraw
import matplotlib
FONT = os.path.join(matplotlib.get_data_path(), "fonts", "ttf", "DejaVuSansMono.ttf")
CW, CH, FIRST, LAST = 8, 16, 32, 126

def build(size, thresh, top=1, dx=0):
    font = ImageFont.truetype(FONT, size)
    g = {}
    for code in range(FIRST, LAST + 1):
        cell = Image.new("L", (CW * 2, CH), 0)
        ImageDraw.Draw(cell).text((dx, top), chr(code), fill=255, font=font)
        rows = []
        for y in range(CH):
            b = 0
            for x in range(CW):
                if cell.getpixel((x, y)) >= thresh: b |= 1 << (7 - x)
            rows.append(b)
        g[code] = rows
    return g

def load_inc(path):
    g, code = {}, FIRST
    for line in open(path):
        line = line.strip()
        if line.startswith("db "):
            vals = [int(v, 16) for v in line[3:].split(";")[0].split(",")]
            g[code] = vals; code += 1
    return g

def render(g, text, scale=2):
    img = Image.new("RGB", (len(text) * CW * scale, CH * scale), (18, 24, 33))
    px = img.load()
    for i, ch in enumerate(text):
        rows = g.get(ord(ch), [0] * 16)
        for y, r in enumerate(rows):
            for x in range(8):
                if r & (1 << (7 - x)):
                    for a in range(scale):
                        for b in range(scale): px[(i * 8 + x) * scale + a, y * scale + b] = (230, 236, 242)
    return img

def emit(g, path):
    with open(path, "w") as f:
        f.write("; 8x16 font, ASCII 32..126, generated from DejaVu Sans Mono (free licence)\nfont8x16:\n")
        for code in range(FIRST, LAST + 1):
            f.write("    db " + ",".join(f"0x{r:02X}" for r in g[code]) + f"   ; code {code}\n")

if __name__ == "__main__":
    if "--emit" in sys.argv:
        size, th, top = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
        emit(build(size, th, top), sys.argv[5]); print("wrote", sys.argv[5])
    else:
        text = "Music Maker  Nova Terminal  Settings 12:45 AaBbGgQq"
        old = load_inc(os.path.join(os.path.dirname(__file__), "..", "font8x16.inc"))
        rows = [("old (Consolas)", render(old, text))]
        for size, th, top in ((13, 110, 1), (13, 140, 1), (14, 120, 0), (14, 150, 0), (12, 100, 2)):
            rows.append((f"DejaVu {size}px thr {th} top {top}", render(build(size, th, top), text)))
        W_ = max(im.width for _, im in rows) + 200
        out = Image.new("RGB", (W_, len(rows) * 40 + 10), (8, 10, 14))
        d = ImageDraw.Draw(out)
        for i, (lab, im) in enumerate(rows):
            d.text((6, i * 40 + 12), lab, fill=(150, 160, 175)); out.paste(im, (200, i * 40 + 5))
        out.save(sys.argv[1] if len(sys.argv) > 1 else "font_preview.png"); print("preview written")
