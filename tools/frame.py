#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""NES frames: render one to PNG, or compare two.

usage: tools/frame.py png FRAME OUT.png
       tools/frame.py diff A B [--png OUT.png]

A frame file is 240 lines of 256 hex values, the PPU's output for each pixel
({emphasis BGR, colour}, 0-1ff), as `rig-run --dump` and `tools/mesen/frames.py
--dump` write them. Colours come from a generated NTSC palette (Bisqwit's
method), close to a real NES but for viewing only: comparisons use the values.

diff prints how many pixels differ and where the first differences are, and
exits 1 if any do; --png writes A dimmed, with differing pixels in magenta.
"""

import argparse
import math
import struct
import sys
import zlib

W, H = 256, 240


def read_frame(path):
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                rows.append([int(v, 16) for v in line.split()])
    if len(rows) != H or any(len(r) != W for r in rows):
        sys.exit(f"{path}: not a {W}x{H} frame")
    return rows


def nes_rgb(pixel):
    """RGB of a PPU output value, from an NTSC signal model."""
    color, level, emphasis = pixel & 0x0F, (pixel >> 4) & 3, (pixel >> 6) & 7
    if color > 13:
        level = 1
    levels = [0.350, 0.518, 0.962, 1.550, 1.094, 1.506, 1.962, 1.962]
    black, white, attenuation = 0.518, 1.962, 0.746
    lo_hi = [levels[level + 4 * (color == 0)], levels[level + 4 * (color < 13)]]

    def wave(p, c):
        return (c + p + 8) % 12 < 6

    y = i = q = 0.0
    for p in range(12):
        spot = lo_hi[wave(p, color)]
        if (emphasis & 1 and wave(p, 12)) or (emphasis & 2 and wave(p, 4)) or (emphasis & 4 and wave(p, 8)):
            spot *= attenuation
        v = (spot - black) / (white - black) / 12
        y += v
        i += v * math.cos(math.pi * p / 6)
        q += v * math.sin(math.pi * p / 6)

    def gamma(x):
        x = max(0.0, min(1.0, x))
        return int(255 * x ** (1 / 1.13) + 0.5)

    return (gamma(y + 0.946882 * i + 0.623557 * q),
            gamma(y - 0.274788 * i - 0.635691 * q),
            gamma(y - 1.108545 * i + 1.709007 * q))


def write_png(path, pixels):
    """pixels: H rows of W (r, g, b), written at 2x so it's easier to see."""
    raw = bytearray()
    for row in pixels:
        line = bytearray([0])
        for r, g, b in row:
            line += bytes((r, g, b, r, g, b))
        raw += line + line
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2 * W, 2 * H, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("png")
    p.add_argument("frame")
    p.add_argument("out")
    d = sub.add_parser("diff")
    d.add_argument("a")
    d.add_argument("b")
    d.add_argument("--png")
    args = ap.parse_args()

    if args.cmd == "png":
        f = read_frame(args.frame)
        write_png(args.out, [[nes_rgb(v) for v in row] for row in f])
        return 0

    a, b = read_frame(args.a), read_frame(args.b)
    diffs = [(x, y) for y in range(H) for x in range(W) if a[y][x] != b[y][x]]
    lines = sorted({y for _, y in diffs})
    print(f"{len(diffs)} pixels differ, on {len(lines)} lines")
    for x, y in diffs[:10]:
        print(f"  ({x}, {y}): {a[y][x]:03x} vs {b[y][x]:03x}")
    if args.png:
        out = []
        for y in range(H):
            row = []
            for x in range(W):
                if a[y][x] != b[y][x]:
                    row.append((255, 0, 255))
                else:
                    r, g, bl = nes_rgb(a[y][x])
                    row.append((r // 3, g // 3, bl // 3))
            out.append(row)
        write_png(args.png, out)
    return 1 if diffs else 0


if __name__ == "__main__":
    sys.exit(main())
