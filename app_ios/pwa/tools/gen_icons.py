"""生成 PWA 图标 PNG（纯标准库，无第三方依赖）。"""
import os, struct, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "icons")

BG = (11, 61, 145)        # 品牌蓝
BOLT = (255, 255, 255)    # 白闪电


def point_in_poly(x, y, poly):
    inside = False
    n = len(poly)
    for i in range(n):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % n]
        if ((y1 > y) != (y2 > y)) and (x < (x2 - x1) * (y - y1) / (y2 - y1) + x1):
            inside = not inside
    return inside


def make_icon(size):
    # 居中闪电多边形（相对中心方框 0.72*size）
    box = size * 0.72
    ox = (size - box) / 2
    oy = (size - box) / 2
    norm = [(0.58, 0.12), (0.30, 0.56), (0.46, 0.56),
            (0.38, 0.88), (0.72, 0.40), (0.55, 0.40)]
    poly = [(ox + nx * box, oy + ny * box) for nx, ny in norm]

    raw = bytearray()
    for y in range(size):
        raw.append(0)  # filter type 0
        for x in range(size):
            if point_in_poly(x + 0.5, y + 0.5, poly):
                raw += bytes(BOLT)
            else:
                raw += bytes(BG)
    return raw


def write_png(path, size, raw):
    def chunk(typ, data):
        c = struct.pack(">I", len(data)) + typ + data
        c += struct.pack(">I", zlib.crc32(typ + data) & 0xffffffff)
        return c
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)  # 8-bit RGBA
    idat = zlib.compress(bytes(raw), 9)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for s in (192, 512):
        raw = make_icon(s)
        write_png(os.path.join(OUT, f"icon-{s}.png"), s, raw)
        print("wrote icon-%d.png (%d bytes)" % (s, len(raw)))
