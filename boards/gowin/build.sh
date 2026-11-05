#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build a Gowin bitstream with the open flow: Yosys -> nextpnr-himbaechel ->
# gowin_pack. Each board's build.sh calls this with its part. Any failure stops
# the build, including a missed timing constraint (nextpnr exits non-zero
# unless --timing-allow-fail is passed, and it never is here).
#
# usage: build.sh -d <device> -F <family> -t <top> -c <pins.cst> [-f <MHz>] [-k NET=MHz]... [-o <outdir>] [-s <seed>] [-g NAME=VALUE]... <sources...>
# -g sets a top-level parameter. -f is the clock constraint for any clock not
# named by -k, which constrains one clock net (a PLL's or divider's output,
# whose rate nextpnr doesn't work out). Placement varies with nextpnr's seed:
# without -s the build tries seeds 1 to 8 and keeps the first that meets
# timing; -s pins one. nextpnr doesn't analyse hold for Gowin parts, so a
# placement that meets timing can still fail on the chip, and a board then
# pins a seed its tests passed with. Writes <outdir>/<top>.fs plus synth.log,
# pnr.log and report.json (achieved fmax).
#
# Synthesis maps no wide multiplexers (synth_gowin -nowidelut): the slices'
# MUX2_LUT5-8 take their inputs only from LUTs, so Yosys pads every mux input
# that isn't a LUT's output (constants, flip-flops) with a LUT1 of its own,
# and the 20K's NES spent over a thousand LUTs on them. In LUT4s alone it's
# smaller and faster: 15,915 LUT4s at 53 MHz became 14,341 at 62 MHz on the
# Tang Nano 20K, and 20,157 at 54 MHz became 16,924 at 56 MHz on the Tang
# Console 138K (Nov 4).
set -euo pipefail

freq=27
seed=""
out=build/fpga
params=()
clocks=()

while getopts "d:F:t:c:f:k:o:s:g:" opt; do
  case $opt in
    d) device=$OPTARG ;;
    F) family=$OPTARG ;;
    t) top=$OPTARG ;;
    c) cst=$OPTARG ;;
    f) freq=$OPTARG ;;
    k) clocks+=("$OPTARG") ;;
    o) out=$OPTARG ;;
    s) seed=$OPTARG ;;
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
  -p "read_verilog -sv $*; $chparams synth_gowin -nowidelut $synth_family -top $top -json $out/$top.json"

sdc=()
if (( ${#clocks[@]} )); then
  : > "$out/clocks.sdc"
  for c in "${clocks[@]}"; do
    echo "create_clock -period $(python3 -c "print(1000 / ${c#*=})") [get_nets {${c%%=*}}]" >> "$out/clocks.sdc"
  done
  sdc=(--sdc "$out/clocks.sdc")
fi

placed=""
for s in ${seed:-1 2 3 4 5 6 7 8}; do
  if nextpnr-himbaechel -q -l "$out/pnr.log" --seed "$s" \
      --json "$out/$top.json" --write "$out/$top.pnr.json" \
      --device "$device" --vopt family="$family" --vopt cst="$cst" \
      --freq "$freq" "${sdc[@]}" --report "$out/report.json"; then
    placed=$s
    break
  fi
  # A missed timing constraint can be another seed's luck; anything else stops the build.
  grep -q "FAIL at" "$out/pnr.log" || exit 1
  echo "seed $s: timing failed" >&2
done
[[ -n $placed ]] || { echo "build.sh: no seed met timing" >&2; exit 1; }
echo "seed $placed"

# Apycula's bundled Python lacks numpy and friends; it only warns that it runs slower.
PYTHONWARNINGS=ignore::UserWarning gowin_pack -d "$family" -o "$out/$top.fs" "$out/$top.pnr.json"

python3 - "$out/report.json" <<'PY'
import json, sys
for clock, t in json.load(open(sys.argv[1]))["fmax"].items():
    print(f"{clock}: {t['achieved']:.1f} MHz (needs {t['constraint']})")
PY
echo "$out/$top.fs"
