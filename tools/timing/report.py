#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Size and speed of every component, on each FPGA family the boards use.

usage: tools/timing/report.py [--components build/components.json] [--family F]... [--only NAME]...
                              [--jobs N] [--out FILE] [--work DIR]

Each top module in the CMake build's component list (build/components.json)
goes into a wrapper that keeps every timing path between registers and needs
three pins: all its clock inputs (1-bit inputs named *clk) on one clock pin,
its other inputs fed from a shift chain on a data pin, and its outputs
registered and XOR-folded onto another. The wrapper is synthesised and placed
for each family at a clock target it can't meet, so the router works for
speed, and the result is what that placement achieves: the fastest clock, the
logic it takes, and its critical path's two ends.

Families (the boards that use them): gw2a (Tang Nano 20K, GW2A-18C), gw5a
(Tang Console 138K, GW5AST-138C), xc7 (PYNQ-Z2, XC7Z020; openXC7, needs
RS_XC7_CHIPDB). nextpnr runs with --timing-allow-fail here: this measures, and
builds no bitstream. A placement is one seed of many, so speeds move by a few
percent from run to run; compare the same component across changes, not
components with each other to the last MHz.

Writes the results as JSON (default build/timing/results.json) and prints them
as a Markdown table; each run's files are in --work (default build/timing/work).
"""

import argparse
import concurrent.futures
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

FAMILIES = {
    "gw2a": {"board": "Tang Nano 20K", "synth": "synth_gowin", "device": "GW2AR-LV18QN88C8/I7",
             "family": "GW2A-18C", "pins": ("4", "15", "16")},
    "gw5a": {"board": "Tang Console 138K", "synth": "synth_gowin -family gw5a", "device": "GW5AST-LV138PG484AC1/I0",
             "family": "GW5AST-138C", "pins": ("V22", "V19", "G22")},
    "xc7": {"board": "PYNQ-Z2", "synth": "synth_xilinx -flatten -abc9 -arch xc7", "chipdb": "xc7z020clg400.bin",
            "pins": ("H16", "Y18", "Y19")},
}
TARGET_MHZ = 500  # beyond any of them, so the router works for speed


def run(cmd, cwd, log):
    with open(log, "w") as f:
        return subprocess.run(cmd, cwd=cwd, stdout=f, stderr=subprocess.STDOUT).returncode


def ports(files, top, work):
    """The top module's ports: [(name, direction, width)]."""
    out = work / "ports.json"
    rc = run(["yosys", "-q", "-p", f"read_verilog -sv {' '.join(files)}; hierarchy -top {top}; proc; write_json {out}"],
             work, work / "ports.log")
    if rc:
        raise RuntimeError(f"yosys couldn't read {top} (see {work / 'ports.log'})")
    mod = json.loads(out.read_text())["modules"][top]
    return [(n, p["direction"], len(p["bits"])) for n, p in mod["ports"].items()]


def wrapper(top, plist):
    clocks = [n for n, d, w in plist if d == "input" and w == 1 and n.endswith("clk")]
    ins = [(n, w) for n, d, w in plist if d == "input" and n not in clocks]
    outs = [(n, w) for n, d, w in plist if d == "output"]
    n_in = max(1, sum(w for _, w in ins))
    n_out = max(1, sum(w for _, w in outs))
    conns, lo = [], 0
    for n, w in ins:
        conns.append(f".{n}(in_sr[{lo + w - 1}:{lo}])")
        lo += w
    lo = 0
    for n, w in outs:
        conns.append(f".{n}(outs[{lo + w - 1}:{lo}])")
        lo += w
    conns += [f".{c}(clk)" for c in clocks]
    return f"""module timing_wrap (input logic clk, input logic din, output logic dout);
    logic [{n_in - 1}:0] in_sr;
    logic [{n_out - 1}:0] outs, out_q;
    always_ff @(posedge clk) begin
        in_sr <= {{in_sr, din}};
        out_q <= outs;
        dout  <= ^out_q;
    end
    {"assign outs = '0;" if not outs else ""}
    {top} u ({", ".join(conns)});
endmodule
"""


def parse_log(text):
    """The routed fmax, utilisation and critical path ends from a nextpnr log."""
    routed = text
    if "Running post-routing legalisation" in text:  # nextpnr-xilinx: only the report after routing counts
        routed = text[text.index("Running post-routing legalisation"):]
    fmax = [float(m) for m in re.findall(r"Max frequency for clock '[^']*clk[^']*': ([0-9.]+) MHz", routed)]
    util = {}
    block = re.search(r"Device utilisation:\n((?:Info:\s+\S+:\s+\d+/\s*\d+\s+\d+%\n)+)", text)
    if block:
        for name, used in re.findall(r"Info:\s+(\S+):\s+(\d+)/", block.group(1)):
            if int(used):
                util[name] = int(used)
    path = re.findall(r"(?:Source|Sink) (\S+)", routed[routed.rfind("Critical path report for clock"):] if
                      "Critical path report for clock" in routed else "")
    return (min(fmax) if fmax else None), util, (path[0] if path else ""), (path[-1] if path else "")


def measure(comp, top, fam, base):
    work = base / fam / top
    work.mkdir(parents=True, exist_ok=True)
    spec = FAMILIES[fam]
    files = comp["files"]
    (work / "wrap.sv").write_text(wrapper(top, ports(files, top, work)))
    netlist = work / "wrap.json"
    if run(["yosys", "-q", "-p", f"read_verilog -sv {' '.join(files)} wrap.sv; "
                                 f"{spec['synth']} -top timing_wrap; write_json {netlist}"], work, work / "synth.log"):
        return {"error": "synthesis failed"}
    clk, din, dout = spec["pins"]
    if fam == "xc7":
        (work / "wrap.xdc").write_text(
            "".join(f"set_property -dict {{ PACKAGE_PIN {p} IOSTANDARD LVCMOS33 }} [get_ports {{ {n} }}]\n"
                    for n, p in (("clk", clk), ("din", din), ("dout", dout)))
            + f"create_clock -period {1000 / TARGET_MHZ:.3f} -name clk [get_ports {{ clk }}]\n")
        chipdb = Path(os.environ["RS_XC7_CHIPDB"]) / spec["chipdb"]
        cmd = ["nextpnr-xilinx", "--chipdb", str(chipdb), "--xdc", "wrap.xdc", "--json", str(netlist),
               "--timing-allow-fail"]
    else:
        (work / "wrap.cst").write_text("".join(f'IO_LOC "{n}" {p};\n' for n, p in (("clk", clk), ("din", din),
                                                                                  ("dout", dout))))
        cmd = ["nextpnr-himbaechel", "--device", spec["device"], "--vopt", f"family={spec['family']}",
               "--vopt", "cst=wrap.cst", "--json", str(netlist), "--freq", str(TARGET_MHZ), "--timing-allow-fail"]
    rc = run(cmd, work, work / "pnr.log")
    fmax, util, src, sink = parse_log((work / "pnr.log").read_text(errors="replace"))
    if rc or fmax is None:
        return {"error": f"place and route failed (see {work / 'pnr.log'})"}
    # The wrapper's own registers: in_sr, out_q and dout.
    return {"fmax_mhz": round(fmax, 1), "utilisation": util, "critical_from": src, "critical_to": sink}


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--components", type=Path, default=ROOT / "build/components.json")
    ap.add_argument("--family", action="append", choices=sorted(FAMILIES))
    ap.add_argument("--only", action="append", help="a component name or top module")
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--out", type=Path, default=ROOT / "build/timing/results.json")
    ap.add_argument("--work", type=Path, default=ROOT / "build/timing/work")
    args = ap.parse_args()
    fams = args.family or list(FAMILIES)
    comps = json.loads(args.components.read_text())
    jobs = [(c, t, f) for c in comps for t in c["tops"] for f in fams
            if not args.only or c["name"] in args.only or t in args.only]
    base = args.work
    results = {}
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        futs = {pool.submit(measure, c, t, f, base): (c, t, f) for c, t, f in jobs}
        for fut in concurrent.futures.as_completed(futs):
            c, t, f = futs[fut]
            try:
                r = fut.result()
            except Exception as e:  # noqa: BLE001 - reported per entry
                r = {"error": str(e)}
            results.setdefault(t, {"component": c["dir"]})[f] = r
            print(f"{t} on {f}: {r.get('fmax_mhz', r.get('error'))}", file=sys.stderr)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(results, indent=2, sort_keys=True) + "\n")

    def cell(r, fam):
        if "error" in r:
            return "failed"
        u = r["utilisation"]
        if fam == "xc7":
            logic = sum(v for k, v in u.items() if k.startswith("SLICE_LUTX"))
            ram = u.get("RAMB18E1", 0) + 2 * u.get("RAMB36E1", 0)
        else:
            logic = u.get("LUT4", 0) + u.get("ALU", 0)
            ram = u.get("BSRAM", 0)
        return f"{r['fmax_mhz']:.0f} MHz, {logic} LUTs" + (f", {ram} BRAM" if ram else "")

    print("| Module | " + " | ".join(FAMILIES[f]["board"] for f in fams) + " |")
    print("| --- |" + " --- |" * len(fams))
    for t in sorted(results):
        print(f"| `{t}` | " + " | ".join(cell(results[t].get(f, {"error": ""}), f) for f in fams) + " |")
    print(f"\nwork files in {base}", file=sys.stderr)
    return 1 if any("error" in r for v in results.values() for k, r in v.items() if k != "component") else 0


if __name__ == "__main__":
    sys.exit(main())
