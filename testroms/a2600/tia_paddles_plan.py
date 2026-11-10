#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Plans tia_paddles.s's reads: for each group of 4 frames, the dump's length (D), and for each frame,
when it reads its paddle (E), so that each group's 4 reads straddle the capacitor's crossing: the
last two cycles before it and the first two after, in Stella's paddle circuit (its AnalogReadout's
equations, every paddle at the middle, 500 kohm). The dumps' lengths spread the crossings over a CPU
cycle's three colour clocks, so a read a colour clock early or late shows somewhere.

Prints the tables tia_paddles.s takes (DTAB, ETAB), and with --verbose each frame's crossing.
"""

import math
import sys

R0, C, R_POT, R_DUMP = 1.8e3, 68e-9, 1e6, 50
F = 60 * 228 * 262
TAU = (R_POT / 2 + R0) * C * F
TAU_DUMP = R_DUMP * C * F
UTH = -math.expm1(-379 * 228 / ((R_POT + R0) * C * F))

LINE = 76              # CPU cycles a line
FRAME = 262 * LINE
WARMUP = 2             # frames dumped throughout, before the first measured
GROUPS = 32            # 4 frames each
# Cycles within the frame (tia_paddles.s): the dump on line 4 at cycle 6, off at 30 + D; the read on
# line 193 at cycle 11 + E.
ON = 4 * LINE + 6
OFF = 4 * LINE + 30
READ = 193 * LINE + 11
ND, NE = 60, 128       # the sleds' lengths: D and E must be below them
# Dump lengths: 27 to 58 cycles (D 4 to 35), in an order that spreads the crossings.
DTAB = [4 + (g * 13) % 32 for g in range(GROUPS)]


def main():
    verbose = "--verbose" in sys.argv
    u = 0.0      # the capacitor
    t = 0        # colour clocks, at the last release
    etab = []
    fracs = []
    for frame in range(WARMUP + 4 * GROUPS):
        base = frame * FRAME
        if frame < WARMUP:   # dumped throughout, and on until the first measured frame's release
            continue
        f = frame - WARMUP
        d = DTAB[f // 4]
        on, off = 3 * (base + ON), 3 * (base + OFF + d)
        u = 1 - (1 - u) * math.exp(-(on - t) / TAU) if frame > WARMUP else u   # charging since the last release
        u *= math.exp(-(off - on) / TAU_DUMP)
        t = off
        cross = TAU * math.log((1 - u) / (1 - UTH))             # colour clocks after the release
        first = math.floor(cross / 3) + 1                       # the first read cycle that sees it
        delta = first - 2 + f % 4                               # cycles from the release to the read
        e = delta - (READ - OFF - d)
        assert 0 <= e < NE and d < ND, (f, d, e)
        etab.append(e)
        fracs.append(cross % 3)
        if verbose:
            print(f"frame {f:3}: D {d:2}, u0 {u:.3e}, crossing {cross:.3f} cc, E {e}, read {'1' if 3 * delta > cross else '0'}")
    # A read early by one colour clock shows where the crossing is in [2, 3) of a cycle; late, in [0, 1).
    early = sum(1 for x in fracs[::4] if x >= 2)
    late = sum(1 for x in fracs[::4] if x < 1)
    print(f"; groups whose crossing a read 1 colour clock early would miss: {early}, late: {late}", file=sys.stderr)
    print("DTAB:   .byte " + ", ".join(str(d) for d in DTAB))
    for i in range(0, len(etab), 16):
        print(("ETAB:   .byte " if i == 0 else "        .byte ") + ", ".join(str(e) for e in etab[i:i + 16]))


if __name__ == "__main__":
    main()
