#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build a Xilinx 7-series bitstream with openXC7: Yosys -> nextpnr-xilinx ->
# fasm2frames -> xc7frames2bit. Each board's build.sh calls this with its
# part. Any failure stops the build, including a missed timing constraint.
#
# usage: build.sh -p <part> -t <top> -c <pins.xdc> [-o <outdir>] [-g NAME=VALUE]... <sources...>
# -p is the part with its speed grade (xc7z020clg400-1). -g sets a top-level
# parameter. Clocks are constrained in the XDC (create_clock). Needs
# nextpnr-xilinx, fasm2frames and xc7frames2bit on PATH, RS_XC7_CHIPDB set to
# the directory holding nextpnr-xilinx's chip databases (<part>.bin, without
# the speed grade) and RS_PRJXRAY_DB to Project X-Ray's database (the one
# holding zynq7/, artix7/ and so on). Writes <outdir>/<top>.bit plus
# synth.log and pnr.log.
set -euo pipefail

out=build/fpga
params=()

while getopts "p:t:c:o:g:" opt; do
  case $opt in
    p) part=$OPTARG ;;
    t) top=$OPTARG ;;
    c) xdc=$OPTARG ;;
    o) out=$OPTARG ;;
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

nextpnr-xilinx --chipdb "$chipdb" --xdc "$xdc" --json "$out/$top.json" --fasm "$out/$top.fasm" \
  > "$out/pnr.log" 2>&1 || { tail -20 "$out/pnr.log" >&2; exit 1; }

# nextpnr-xilinx reports a missed constraint but still exits 0.
grep -E "Max frequency for clock" "$out/pnr.log" | sed 's/^Info: //' | sort -u
if grep -q "FAIL at" "$out/pnr.log"; then
  echo "build.sh: timing failed (see $out/pnr.log)" >&2
  exit 1
fi

fasm2frames --part "$part" --db-root "$db" "$out/$top.fasm" > "$out/$top.frames"
xc7frames2bit --part_file "$db/$part/part.yaml" --part_name "$part" \
  --frm_file "$out/$top.frames" --output_file "$out/$top.bit"
echo "$out/$top.bit"
