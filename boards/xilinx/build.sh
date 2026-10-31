#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build a Xilinx 7-series bitstream with openXC7: Yosys -> nextpnr-xilinx ->
# fasm2frames -> xc7frames2bit. Each board's build.sh calls this with its
# part. Any failure stops the build, including a missed timing constraint.
#
# usage: build.sh -p <part> -t <top> -c <pins.xdc> [-o <outdir>] [-s <seeds>] [-g NAME=VALUE]... <sources...>
# -p is the part with its speed grade (xc7z020clg400-1). -g sets a top-level
# parameter. nextpnr-xilinx's placement varies a lot from seed to seed, and
# some placements use tiles Project X-Ray can't encode, so it places with
# seeds 1, 2, ... up to -s (default 8) and keeps the first that meets every
# constraint and assembles; if none does, the build fails. Clocks are constrained in the XDC (create_clock). Needs
# nextpnr-xilinx, fasm2frames and xc7frames2bit on PATH, RS_XC7_CHIPDB set to
# the directory holding nextpnr-xilinx's chip databases (<part>.bin, without
# the speed grade) and RS_PRJXRAY_DB to Project X-Ray's database (the one
# holding zynq7/, artix7/ and so on). Writes <outdir>/<top>.bit plus
# synth.log and pnr.log.
set -euo pipefail

out=build/fpga
seeds=8
params=()

while getopts "p:t:c:o:s:g:" opt; do
  case $opt in
    p) part=$OPTARG ;;
    t) top=$OPTARG ;;
    c) xdc=$OPTARG ;;
    o) out=$OPTARG ;;
    s) seeds=$OPTARG ;;
    g) params+=("$OPTARG") ;;
    *) sed -n 's/^# usage: //p' "$0" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
if [[ -z ${part:-} || -z ${top:-} || -z ${xdc:-} || $# -eq 0 ]]; then
  sed -n 's/^# usage: //p' "$0" >&2
  exit 2
fi

for tool in yosys nextpnr-xilinx fasm2frames xc7frames2bit; do
  command -v "$tool" >/dev/null || { echo "build.sh: $tool isn't on PATH (openXC7)" >&2; exit 2; }
done
base=${part%-*}
case $base in
  xc7z*) family=zynq7 ;;
  xc7a*) family=artix7 ;;
  xc7s*) family=spartan7 ;;
  xc7k*) family=kintex7 ;;
  *) echo "build.sh: unknown part $part" >&2; exit 2 ;;
esac
chipdb=${RS_XC7_CHIPDB:?set RS_XC7_CHIPDB to nextpnr-xilinx\'s chip databases}/$base.bin
db=${RS_PRJXRAY_DB:?set RS_PRJXRAY_DB to Project X-Ray\'s database}/$family
[[ -f $chipdb ]] || { echo "build.sh: no chip database $chipdb" >&2; exit 2; }
[[ -d $db/$part ]] || { echo "build.sh: no Project X-Ray database for $part in $db" >&2; exit 2; }
mkdir -p "$out"

chparams=""
for p in "${params[@]}"; do
  chparams+="chparam -set ${p%%=*} ${p#*=} $top; "
done

yosys -q -l "$out/synth.log" \
  -p "read_verilog -sv $*; $chparams synth_xilinx -flatten -abc9 -arch xc7 -top $top; write_json $out/$top.json"

# nextpnr-xilinx reports a missed constraint but still exits 0. Only the
# report after routing counts; the one after placement is an estimate.
for seed in $(seq 1 "$seeds"); do
  log=$out/pnr.log
  if ! nextpnr-xilinx --seed "$seed" --chipdb "$chipdb" --xdc "$xdc" --json "$out/$top.json" \
      --fasm "$out/$top.fasm" > "$log" 2>&1; then
    # Some placements pack a LUT-RAM with flip-flops on the other clock edge
    # in one half-slice, which can't be configured: another seed may not.
    if grep -q "control-set contention" "$log"; then
      echo "seed $seed: this placement mixes clock edges in a slice (see $log)" >&2
      continue
    fi
    # Some put a clock buffer where the router finds no dedicated path to it
    # from its MMCM or PLL: another seed may place it where it can.
    if grep -q "ERROR: Failed to route arc" "$log"; then
      echo "seed $seed: the router found no path for a net (see $log)" >&2
      continue
    fi
    tail -20 "$log" >&2
    exit 1
  fi
  routed=$(sed -n '/^Info: Running post-routing legalisation/,$p' "$log" | grep "Max frequency for clock" || true)
  if [[ -z $routed ]]; then
    echo "build.sh: no timing report after routing (see $log)" >&2
    exit 1
  fi
  if grep -q "FAIL at" <<< "$routed"; then
    echo "seed $seed: timing failed" >&2
    continue
  fi
  if ! fasm2frames --part "$part" --db-root "$db" "$out/$top.fasm" > "$out/$top.frames" 2> "$out/fasm2frames.log"; then
    echo "seed $seed: Project X-Ray can't encode this placement (see $out/fasm2frames.log)" >&2
    continue
  fi
  echo "seed $seed"
  sed 's/^Info: //' <<< "$routed"
  xc7frames2bit --part_file "$db/$part/part.yaml" --part_name "$part" \
    --frm_file "$out/$top.frames" --output_file "$out/$top.bit"
  echo "$out/$top.bit"
  exit 0
done
echo "build.sh: no seed of $seeds met timing and assembled (see $out/pnr.log)" >&2
exit 1
