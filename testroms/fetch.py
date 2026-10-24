#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Download the test ROMs in manifest.toml and check their SHA-256 sums.

usage: testroms/fetch.py [--dest DIR]

DIR defaults to $RS_TESTROMS, else ~/.cache/retro-silicon/testroms. Files land
in DIR/<source>/<path>. A file already there with the right sum is kept; a sum
mismatch is an error. Exit codes: 0 all present, 1 a download or sum failed.
"""

import argparse
import hashlib
import os
import sys
import tomllib
import urllib.request
from pathlib import Path

MANIFEST = Path(__file__).with_name("manifest.toml")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def files(manifest):
    """(source, path, sha256) for every ROM and reference file."""
    for rom in manifest["rom"]:
        yield rom["source"], rom["path"], rom["sha256"]
        if "trace" in rom:
            yield rom["source"], rom["trace"]["path"], rom["trace"]["sha256"]


def main():
    default = os.environ.get("RS_TESTROMS", Path.home() / ".cache/retro-silicon/testroms")
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dest", type=Path, default=Path(default))
    args = parser.parse_args()

    manifest = tomllib.loads(MANIFEST.read_text())
    failed = 0
    for source, path, want in files(manifest):
        out = args.dest / source / path
        if out.exists() and sha256(out) == want:
            continue
        url = manifest["sources"][source]["url"] + path
        out.parent.mkdir(parents=True, exist_ok=True)
        tmp = out.with_suffix(out.suffix + ".part")
        try:
            urllib.request.urlretrieve(url, tmp)
        except OSError as e:
            print(f"fetch: {url}: {e}", file=sys.stderr)
            failed += 1
            continue
        got = sha256(tmp)
        if got != want:
            tmp.unlink()
            print(f"fetch: {path}: SHA-256 {got}, expected {want}", file=sys.stderr)
            failed += 1
            continue
        tmp.replace(out)
        print(f"fetched {source}/{path}")
    print(f"{args.dest}: {'all files present' if not failed else f'{failed} failed'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
