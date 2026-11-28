#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""The golden frame CRCs of Mealybug Tearoom's tests, from the hardware's own pictures.

Matt Currie's Mealybug Tearoom tests (MIT) come with an expected image for each test, made from
photos of a Game Boy (DMG-blob) and of a Game Boy Color (CPU CGB C and CPU CGB D). The images use
the screen's own values: the Game Boy's four shades as greys 255, 170, 85 and 0, and the Color's
15-bit colours with each 5-bit channel c as the 8-bit (c << 3) | (c >> 2). So each image turns back
into the frame the core takes, exactly, and its CRC-32 is the golden one (the core's pixel format:
2 bytes a pixel, low first, row by row; the shade 0-3, or the 15-bit colour). A few of the Color's
images are drawn over with notes (colours no 15-bit colour gives); those are left out.

usage: tools/gb/mealybug.py REPO

REPO is a checkout of github.com/mattcurrie/mealybug-tearoom-tests (its `expected` folder). Prints
`name model revision crc` for each image: model dmg or cgb, revision DMG-blob, CGB-C or CGB-D, crc
the frame's CRC-32 or `annotated`. testroms/manifest-gb.toml's Mealybug entries take theirs from it.
"""

import struct
import sys
import zlib
from pathlib import Path

REVS = [("DMG-blob", "dmg", "DMG-blob"), ("CPU CGB C", "cgb", "CGB-C"), ("CPU CGB D", "cgb", "CGB-D")]


def read_png(path: Path):
    """A non-interlaced PNG's pixels as (r, g, b) rows: greyscale, palette, RGB or RGBA, any depth."""
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path}: not a PNG")
    pos, idat, plte = 8, b"", None
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
        elif kind == b"PLTE":
            plte = [tuple(body[i:i + 3]) for i in range(0, n, 3)]
        elif kind == b"IDAT":
            idat += body
        pos += 12 + n
    if interlace:
        raise ValueError(f"{path}: interlaced")
    chans = {0: 1, 2: 3, 3: 1, 6: 4}[ctype]
    bpp = max(1, chans * depth // 8)
    stride = (w * chans * depth + 7) // 8
    raw = zlib.decompress(idat)
    rows, prev = [], bytes(stride)
    for y in range(h):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1:
                line[i] = (line[i] + a) & 255
            elif f == 2:
                line[i] = (line[i] + b) & 255
            elif f == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        prev = bytes(line)
        if depth == 8:
            vals = list(line)
        else:
            per = 8 // depth
            vals = [(line[i // per] >> (8 - depth * (i % per + 1))) & ((1 << depth) - 1) for i in range(w * chans)]
        px = []
        for x in range(w):
            v = vals[x * chans:(x + 1) * chans]
            if ctype == 0:
                g = v[0] * 255 // ((1 << depth) - 1)
                px.append((g, g, g))
            elif ctype == 3:
                px.append(plte[v[0]])
            else:
                px.append(tuple(v[:3]))
        rows.append(px)
    return w, h, rows


def frame(rows, model: str):
    """The core's frame for an image, or None if a colour isn't one the screen gives."""
    out = []
    if model == "dmg":
        shade = {255: 0, 170: 1, 85: 2, 0: 3}
        for row in rows:
            for r, g, b in row:
                if not r == g == b or r not in shade:
                    return None
                out.append(shade[r])
    else:
        five = {(c << 3) | (c >> 2): c for c in range(32)}
        for row in rows:
            for r, g, b in row:
                if r not in five or g not in five or b not in five:
                    return None
                out.append(five[r] | five[g] << 5 | five[b] << 10)
    return struct.pack(f"<{len(out)}H", *out)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    expected = Path(sys.argv[1]) / "expected"
    for folder, model, rev in REVS:
        for png in sorted((expected / folder).glob("*.png")):
            w, h, rows = read_png(png)
            if (w, h) != (160, 144):
                raise SystemExit(f"{png}: {w}x{h}, not 160x144")
            f = frame(rows, model)
            print(f"{png.stem} {model} {rev} {'annotated' if f is None else f'0x{zlib.crc32(f):08x}'}")


if __name__ == "__main__":
    main()
