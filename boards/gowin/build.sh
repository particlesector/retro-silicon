#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build a Gowin bitstream with the open flow: Yosys -> nextpnr-himbaechel ->
# gowin_pack. Each board's build.sh calls this with its part. Any failure stops
# the build, including a missed timing constraint (nextpnr exits non-zero
# unless --timing-allow-fail is passed, and it never is here).
#
# usage: build.sh -d <device> -F <family> -t <top> -c <pins.cst> [-f <MHz>] [-o <outdir>] [-g NAME=VALUE]... <sources...>
# -g sets a top-level parameter. Writes <outdir>/<top>.fs plus synth.log, pnr.log
# and report.json (achieved fmax).
set -euo pipefail

freq=27
out=build/fpga
params=()

while getopts "d:F:t:c:f:o:g:" opt; do
  case $opt in
    d) device=$OPTARG ;;
    F) family=$OPTARG ;;
    t) top=$OPTARG ;;
    c) cst=$OPTARG ;;
    f) freq=$OPTARG ;;
    o) out=$OPTARG ;;
    g) params+=("$OPTARG") ;;
    *) sed -n 's/^# usage: //p' "$0" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
if [[ -z ${device:-} || -z ${family:-} || -z ${top:-} || -z ${cst:-} || $# -eq 0 ]]; then
  sed -n 's/^# usage: //p' "$0" >&2
  exit 2
fi

command -v nextpnr-himbaechel >/dev/null || { echo "build.sh: put OSS CAD Suite on PATH first" >&2; exit 2; }
mkdir -p "$out"

chparams=""
for p in "${params[@]}"; do
  chparams+="chparam -set ${p%%=*} ${p#*=} $top; "
done

synth_family=""
[[ $family == GW5A* ]] && synth_family="-family gw5a"

yosys -q -l "$out/synth.log" \
  -p "read_verilog -sv $*; $chparams synth_gowin $synth_family -top $top -json $out/$top.json"

nextpnr-himbaechel -q -l "$out/pnr.log" \
  --json "$out/$top.json" --write "$out/$top.pnr.json" \
  --device "$device" --vopt family="$family" --vopt cst="$cst" \
  --freq "$freq" --report "$out/report.json"

# Apycula's bundled Python lacks numpy and friends; it only warns that it runs slower.
PYTHONWARNINGS=ignore::UserWarning gowin_pack -d "$family" -o "$out/$top.fs" "$out/$top.pnr.json"

python3 - "$out/report.json" <<'PY'
import json, sys
for clock, t in json.load(open(sys.argv[1]))["fmax"].items():
    print(f"{clock}: {t['achieved']:.1f} MHz (needs {t['constraint']})")
PY
echo "$out/$top.fs"
