#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build a Gowin bitstream with Gowin's own tools (Gowin EDA, its free Education
# edition is enough for the boards here): GowinSynthesis, then its place and
# route, run headless through gw_sh. Gowin EDA is closed and behind a login:
# each user downloads it, and RS_GOWIN_EDA names its IDE directory (the one
# holding bin/gw_sh). The same arguments as ../gowin/build.sh (the open flow),
# so a board can use either.
#
# usage: build.sh -d <device> -F <family> -t <top> -c <pins.cst> [-f <MHz>] [-k NET=MHz]... [-o <outdir>] [-g NAME=VALUE]... [-x OPTION=VALUE]... <sources...>
# -g sets a top-level parameter: Gowin's Tcl can't, so the top module's file is
# copied with that parameter's default changed (a plain `parameter ... NAME =
# value`). -f constrains the top's `clk` port; -k NET=MHz constrains another
# clock, by net (a PLL's output). -x passes a Gowin option (set_option
# -OPTION VALUE), such as place_option=2. A missed timing constraint fails the build.
# Writes <outdir>/<top>.fs, the Tcl project (gowin.tcl), its log (gowin.log)
# and the timing report (timing.rpt).
set -euo pipefail

freq=27
out=build/fpga
params=()
clocks=()
options=()

while getopts "d:F:t:c:f:k:o:s:g:x:" opt; do
  case $opt in
    d) device=$OPTARG ;;
    F) family=$OPTARG ;;
    t) top=$OPTARG ;;
    c) cst=$OPTARG ;;
    f) freq=$OPTARG ;;
    k) clocks+=("$OPTARG") ;;
    o) out=$OPTARG ;;
    s) echo "build.sh: Gowin EDA has no placement seed" >&2; exit 2 ;;
    g) params+=("$OPTARG") ;;
    x) options+=("$OPTARG") ;;
    *) sed -n 's/^# usage: //p' "$0" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
if [[ -z ${device:-} || -z ${family:-} || -z ${top:-} || -z ${cst:-} || $# -eq 0 ]]; then
  sed -n 's/^# usage: //p' "$0" >&2
  exit 2
fi

gw_sh=${RS_GOWIN_EDA:-}/bin/gw_sh
[[ -x $gw_sh ]] || { echo "build.sh: set RS_GOWIN_EDA to Gowin EDA's IDE directory (holding bin/gw_sh)" >&2; exit 2; }
mkdir -p "$out"
out=$(cd "$out" && pwd)
proj=$out/gowin
rm -rf "$proj"
mkdir -p "$proj/src"

# The sources, with the top module's file copied and its -g parameters set.
sources=()
for f in "$@"; do
  f=$(cd "$(dirname "$f")" && pwd)/$(basename "$f")
  if (( ${#params[@]} )) && grep -qE "^\s*module\s+$top\b" "$f"; then
    copy=$proj/src/$(basename "$f")
    python3 - "$f" "$copy" "${params[@]}" <<'EOF'
import re, sys
src, dst, *params = sys.argv[1:]
text = open(src).read()
for p in params:
    name, value = p.split("=", 1)
    if value.lower().startswith("0x"):
        value = "32'h" + value[2:]
    text, n = re.subn(r"(\bparameter\b[^;=]*\b" + re.escape(name) + r"\s*=\s*)[^,)\n/]+",
                      lambda m: m.group(1) + value + " ", text, count=1)
    if n != 1:
        sys.exit(f"build.sh: no parameter {name} in {src}")
open(dst, "w").write(text)
EOF
    sources+=("$copy")
  else
    sources+=("$f")
  fi
done

# The clocks.
{
  echo "create_clock -name clk -period $(python3 -c "print(round(1000 / $freq, 3))") [get_ports {clk}]"
  for c in "${clocks[@]}"; do
    echo "create_clock -name ${c%%=*} -period $(python3 -c "print(round(1000 / ${c#*=}, 3))") [get_nets {${c%%=*}}]"
  done
} > "$proj/clocks.sdc"

{
  echo "set_device -name $family $device"
  for f in "${sources[@]}"; do echo "add_file -type verilog {$f}"; done
  echo "add_file -type cst {$(cd "$(dirname "$cst")" && pwd)/$(basename "$cst")}"
  echo "add_file -type sdc {$proj/clocks.sdc}"
  echo "set_option -top_module $top"
  echo "set_option -output_base_name $top"
  echo "set_option -verilog_std sysv2017"
  echo "set_option -gen_text_timing_rpt 1"
  # The 138K's LEDs and spare pins share the configuration pins.
  echo "set_option -use_sspi_as_gpio 1"
  echo "set_option -use_mspi_as_gpio 1"
  echo "set_option -use_done_as_gpio 1"
  echo "set_option -use_ready_as_gpio 1"
  echo "set_option -use_cpu_as_gpio 1"
  for o in "${options[@]}"; do echo "set_option -${o%%=*} ${o#*=}"; done
  echo "run all"
} > "$proj/gowin.tcl"
install -m 644 "$proj/gowin.tcl" "$out/gowin.tcl"

(cd "$proj" && QT_QPA_PLATFORM=offscreen LD_PRELOAD=${RS_GOWIN_EDA_PRELOAD:-} "$gw_sh" gowin.tcl) > "$out/gowin.log" 2>&1 || {
  tail -30 "$out/gowin.log" >&2
  echo "build.sh: Gowin EDA failed (see $out/gowin.log)" >&2
  exit 1
}
fs=$(find "$proj" -name "$top.fs" | head -1)
[[ -n $fs ]] || { tail -30 "$out/gowin.log" >&2; echo "build.sh: no bitstream (see $out/gowin.log)" >&2; exit 1; }
rpt=$(find "$proj" -name "$top.tr" -o -name "${top}_tr_content.html" | head -1)
[[ -n $rpt ]] && install -m 644 "$rpt" "$out/timing.rpt"
# Gowin's timing analysis covers setup and hold: any negative slack fails the build.
[[ -n $rpt ]] || { echo "build.sh: no timing report (see $out/gowin.log)" >&2; exit 1; }
python3 - "$out/timing.rpt" <<'PY'
import re, sys
rpt = open(sys.argv[1]).read()
def cells(row):
    return re.findall(r"<td[^>]*>([^<]*)</td>", row)
fmax = rpt.split("Max_Frequency_Report", 1)[1].split("</table>", 1)[0]
for row in fmax.split("<tr>")[1:]:
    c = cells(row)
    if len(c) >= 4:
        print(f"Max frequency for clock '{c[1]}': {c[3]} (constraint {c[2]})")
tns = rpt.split("Total_Negative_Slack_Report", 1)[1].split("</table>", 1)[0]
bad = [c for c in (cells(r) for r in tns.split("<tr>")[1:]) if len(c) >= 4 and (float(c[2]) != 0 or int(c[3]) != 0)]
for c in bad:
    print(f"ERROR: clock '{c[0]}' fails {c[1].lower()} timing: {c[3]} endpoints, total slack {c[2]} ns", file=sys.stderr)
sys.exit(1 if bad else 0)
PY
install -m 644 "$fs" "$out/$top.fs"
