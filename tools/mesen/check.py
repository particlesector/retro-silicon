#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Run every blargg-style ROM in testroms/manifest.toml through MesenCE and
check it passes: a check of the reference, the ROMs and the fetch, before any
core is compared against them.

usage: tools/mesen/check.py [--mesen PATH] [--roms DIR]

Needs MesenCE and xvfb-run. --roms defaults like testroms/fetch.py's --dest.
Exit codes: 0 all passed, 1 a ROM failed, 2 a ROM is missing or Mesen didn't run.
"""

import argparse
import os
import subprocess
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def main():
    default = os.environ.get("RS_TESTROMS", Path.home() / ".cache/retro-silicon/testroms")
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--mesen", default="Mesen")
    parser.add_argument("--roms", type=Path, default=Path(default))
    args = parser.parse_args()

    manifest = tomllib.loads((ROOT / "testroms/manifest.toml").read_text())
    lua = ROOT / "tools/mesen/blargg.lua"
    worst = 0
    for rom in manifest["rom"]:
        if rom["check"] != "blargg":
            continue
        path = args.roms / rom["source"] / rom["path"]
        if not path.exists():
            print(f"MISSING {rom['id']}: {path}; run testroms/fetch.py")
            worst = 2
            continue
        try:
            p = subprocess.run(["xvfb-run", "-a", args.mesen, "--testrunner", str(path), str(lua)],
                               capture_output=True, text=True, timeout=600)
        except (OSError, subprocess.TimeoutExpired) as e:
            print(f"ERROR   {rom['id']}: {e}")
            worst = 2
            continue
        last = [l for l in p.stdout.splitlines() if l.startswith("result ") or l.startswith("no result")]
        summary = last[-1] if last else "no output"
        print(f"{'PASS' if p.returncode == 0 else 'FAIL':7} {rom['id']}: {summary}")
        if p.returncode != 0:
            worst = max(worst, 1)
    return worst


if __name__ == "__main__":
    sys.exit(main())
