#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Download or build the test ROMs in manifest.toml and check their SHA-256 sums.

usage: testroms/fetch.py [--dest DIR]

DIR defaults to $RS_TESTROMS, else ~/.cache/retro-silicon/testroms. Files land
in DIR/<source>/<path>. A file already there with the right sum is kept; a sum
mismatch is an error. A source with `url` is downloaded; one with `git`,
`commit` and `build` is cloned at that commit into DIR/<source> and built
there (homebrew from source; the build needs the tools its README names, such
as ca65 and Pillow). A ROM whose sha256 is empty is built and its sum printed,
to put in the manifest, and counts as a failure until it's there. Exit codes:
0 all present, 1 a download, build or sum failed.
"""

import argparse
import hashlib
import os
import subprocess
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


def build(dest, source, spec):
    """Checks out a git source at its commit in dest/source and runs its build."""
    work = dest / source

    def git(*a):
        return subprocess.run(["git", "-C", str(work), *a], check=True, capture_output=True, text=True).stdout

    if not (work / ".git").exists():
        work.mkdir(parents=True, exist_ok=True)
        git("init", "-q")
        git("remote", "add", "origin", spec["git"])
    head = subprocess.run(["git", "-C", str(work), "rev-parse", "--verify", "-q", "HEAD"],
                          capture_output=True, text=True).stdout.strip()
    if head != spec["commit"]:
        git("fetch", "-q", "--depth", "1", "origin", spec["commit"])
        git("checkout", "-q", "--force", spec["commit"])
    subprocess.run(spec["build"], cwd=work, check=True)


def main():
    default = os.environ.get("RS_TESTROMS", Path.home() / ".cache/retro-silicon/testroms")
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dest", type=Path, default=Path(default))
    args = parser.parse_args()

    manifest = tomllib.loads(MANIFEST.read_text())
    failed = 0
    built = set()
    for source, path, want in files(manifest):
        out = args.dest / source / path
        if want and out.exists() and sha256(out) == want:
            continue
        spec = manifest["sources"][source]
        if "git" in spec:
            if source not in built:
                built.add(source)
                try:
                    build(args.dest, source, spec)
                except (OSError, subprocess.CalledProcessError) as e:
                    print(f"fetch: building {source}: {e}", file=sys.stderr)
                    failed += 1
                    continue
            got = sha256(out) if out.exists() else None
            if got is None or got != want:
                print(f"fetch: {source}/{path}: built " + (f"SHA-256 {got}" if got else "nothing") +
                      (f", expected {want}" if want else "; put that sum in the manifest"), file=sys.stderr)
                failed += 1
            else:
                print(f"built {source}/{path}")
            continue
        url = spec["url"] + path
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
