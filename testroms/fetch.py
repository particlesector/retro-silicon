#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Download or build the test ROMs in manifest.toml and check their SHA-256 sums.

usage: testroms/fetch.py [--dest DIR]

The NES's ROMs are in manifest.toml, the Atari 2600's in manifest-2600.toml,
the Game Boy's (and its boot ROMs and the SM83's tests) in manifest-gb.toml.
DIR defaults to $RS_TESTROMS, else ~/.cache/retro-silicon/testroms. Files land
in DIR/<source>/<path>. A file already there with the right sum is kept; a sum
mismatch is an error. A source with `url` is downloaded; one with `git`,
`commit` and `build` is cloned at that commit into DIR/<source> and built
there (homebrew from source; the build needs the tools its README names, such
as ca65 and Pillow); one with `dir` and `build` is our own, in testroms/<dir>,
copied into DIR/<source> and built there the same way; a `git` source without
`build` is only checked out. One with `archive` (a .tar.xz, .tar.gz or .zip URL)
and its `sha256` is downloaded and unpacked into DIR/<source>, dropping its first
`strip` folders. A `[[boot]]` entry is a boot ROM, checked as a ROM is; a
`[[tree]]` entry is a folder of a source, checked as a whole: its sha256 is that
of the sorted lines `<sha256>  <path>` for every file under it (sha256sum's
format, paths relative to the folder). A ROM whose sha256 is empty is built and its sum printed,
to put in the manifest, and counts as a failure until it's there. Exit codes:
0 all present, 1 a download, build or sum failed.
"""

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

HERE = Path(__file__).parent
MANIFESTS = [HERE / "manifest.toml", HERE / "manifest-2600.toml", HERE / "manifest-gb.toml"]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def tree_sha256(folder):
    """The sum a [[tree]] entry gives: of `<sha256>  <path>` lines, sorted by path."""
    lines = sorted(f"{sha256(f)}  {f.relative_to(folder).as_posix()}\n"
                   for f in folder.rglob("*") if f.is_file())
    return hashlib.sha256("".join(lines).encode()).hexdigest()


def files(manifest):
    """(source, path, sha256) for every ROM, boot ROM and reference file."""
    for boot in manifest["boot"]:
        yield boot["source"], boot["path"], boot["sha256"]
    for rom in manifest["rom"]:
        yield rom["source"], rom["path"], rom["sha256"]
        if "trace" in rom:
            yield rom["source"], rom["trace"]["path"], rom["trace"]["sha256"]
        if "sav" in rom:
            yield rom["source"], rom["sav"]["path"], rom["sav"]["sha256"]


def build(dest, source, spec):
    """Checks out a git source at its commit in dest/source, or copies our own, and runs its build."""
    work = dest / source
    if "dir" in spec:
        shutil.copytree(HERE / spec["dir"], work, dirs_exist_ok=True)
        subprocess.run(spec["build"], cwd=work, check=True)
        return

    def git(*a):
        return subprocess.run(["git", "-C", str(work), *a], check=True, capture_output=True, text=True).stdout

    if "archive" in spec:
        unpack(work, spec)
        return
    if not (work / ".git").exists():
        work.mkdir(parents=True, exist_ok=True)
        git("init", "-q")
        git("remote", "add", "origin", spec["git"])
    head = subprocess.run(["git", "-C", str(work), "rev-parse", "--verify", "-q", "HEAD"],
                          capture_output=True, text=True).stdout.strip()
    if head != spec["commit"]:
        git("fetch", "-q", "--depth", "1", "origin", spec["commit"])
        git("checkout", "-q", "--force", spec["commit"])
    if "build" in spec:
        subprocess.run(spec["build"], cwd=work, check=True)


def unpack(work, spec):
    """Downloads an archive source, checks its sum and unpacks it into work."""
    with tempfile.TemporaryDirectory() as tmp:
        archive = Path(tmp) / Path(urllib.parse.urlparse(spec["archive"]).path).name
        urllib.request.urlretrieve(spec["archive"], archive)
        got = sha256(archive)
        if got != spec["sha256"]:
            raise OSError(f"{spec['archive']}: SHA-256 {got}, expected {spec['sha256']}")
        out = Path(tmp) / "out"
        if archive.suffix == ".zip":
            with zipfile.ZipFile(archive) as z:
                z.extractall(out)
        else:
            with tarfile.open(archive) as t:
                t.extractall(out, filter="data")
        top = out
        for _ in range(spec.get("strip", 0)):
            (top,) = top.iterdir()
        shutil.copytree(top, work, dirs_exist_ok=True)


def main():
    default = os.environ.get("RS_TESTROMS", Path.home() / ".cache/retro-silicon/testroms")
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dest", type=Path, default=Path(default))
    args = parser.parse_args()

    manifest = {"sources": {}, "rom": [], "boot": [], "tree": []}
    for path in MANIFESTS:
        part = tomllib.loads(path.read_text())
        manifest["sources"].update(part.get("sources", {}))
        for kind in ("rom", "boot", "tree"):
            manifest[kind] += part.get(kind, [])
    failed = 0
    built = set()
    for source, path, want in files(manifest):
        out = args.dest / source / path
        if want and out.exists() and sha256(out) == want:
            continue
        spec = manifest["sources"][source]
        if "git" in spec or "dir" in spec or "archive" in spec:
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
        url = spec["url"] + urllib.parse.quote(path)
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
    for tree in manifest["tree"]:
        source, want = tree["source"], tree["sha256"]
        folder = args.dest / source / tree["path"]
        if not folder.is_dir() or (got := tree_sha256(folder)) != want:
            if source not in built:
                built.add(source)
                try:
                    build(args.dest, source, manifest["sources"][source])
                except (OSError, subprocess.CalledProcessError) as e:
                    print(f"fetch: building {source}: {e}", file=sys.stderr)
                    failed += 1
                    continue
            got = tree_sha256(folder) if folder.is_dir() else None
            if got != want:
                print(f"fetch: {source}/{tree['path']}/: tree SHA-256 {got}" +
                      (f", expected {want}" if want else "; put that sum in the manifest"), file=sys.stderr)
                failed += 1
                continue
            print(f"fetched {source}/{tree['path']}/")
    print(f"{args.dest}: {'all files present' if not failed else f'{failed} failed'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
