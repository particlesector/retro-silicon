#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Zynq-7000 DDR3 bring-up: the register writes that start a board's DDR, from
its description (a TOML file such as boards/pynq-z2/ps/ddr3.toml).

usage: ps7_ddr3.py BOARD.toml [--tcl OUT.tcl] [--list]
                   [--compare PS7_INIT.c]

Computed from AMD's Zynq 7000 SoC Technical Reference Manual (UG585): the DDR
clock, the DDR I/O buffers and their DCI calibration, the DDR controller's
registers, then the controller's enable, after which it resets and
initializes the DRAM and trains itself. Then the PS-PL level shifters and the
fabric's resets, so the fabric's HP ports can reach the DDR. Silicon
revision 3 (PS_VERSION 3), DDR3 at 1.5 V only.

A few values the manual leaves to AMD's tools (the I/O drive and slew
settings, the PHY's command-slave ratio, the controller's queue tuning) are as
those tools set them for DDR3 on comparable boards: they're marked "as AMD's
tools set it" below.

--tcl writes an OpenOCD script (procs ps7_ddr3_init and ps7_ddr3_check) to
run with the core halted; --list prints the writes. --compare decodes another
init file's DDR table (one of AMD's generated ps7_init files, for a board with
the same parameters) and prints where it differs, as a check of this code:
it's read, never copied.
"""

import argparse
import math
import re
import sys
import tomllib
from pathlib import Path

SLCR = 0xF8000000
DDRC = 0xF8006000

# UG585, PLL Frequency Control Settings: feedback divider -> (PLL_CP, PLL_RES, LOCK_CNT).
PLL_TABLE = {13: (2, 6, 750), 14: (2, 6, 700), 15: (2, 6, 650), 16: (2, 10, 625), 17: (2, 10, 575),
             18: (2, 10, 550), 19: (2, 10, 525), 20: (2, 12, 500), 21: (2, 12, 475), 22: (2, 12, 450),
             23: (2, 12, 425), 24: (2, 12, 400), 25: (2, 12, 400), 26: (2, 12, 375), 27: (2, 12, 350),
             28: (2, 12, 350), 29: (2, 12, 325), 30: (2, 12, 325), 31: (2, 2, 300), 32: (2, 2, 300),
             33: (2, 2, 300), 34: (2, 2, 275), 35: (2, 2, 275), 36: (2, 2, 275)}


def fields(*parts):
    """(value, hi, lo) triples into a register value and mask."""
    v = m = 0
    for val, hi, lo in parts:
        w = (1 << (hi - lo + 1)) - 1
        if not 0 <= val <= w:
            raise ValueError(f"{val} doesn't fit bits {hi}:{lo}")
        v |= val << lo
        m |= w << lo
    return v, m


class Seq:
    def __init__(self):
        self.ops = []

    def write(self, addr, value, mask=0xFFFFFFFF, note=""):
        self.ops.append(("write", addr, mask, value & mask, note))

    def reg(self, addr, note, *parts):
        v, m = fields(*parts)
        self.write(addr, v, m, note)

    def poll(self, addr, mask, note=""):
        self.ops.append(("poll", addr, mask, 0, note))

    def wait_us(self, us, note=""):
        self.ops.append(("wait", 0, 0, us, note))


def build(b):
    d, brd = b["dram"], b["board"]
    f_mhz = b["ps_clk_mhz"] * b["pll_fdiv"] / b["ddr_3x_div"]
    tck = 1000.0 / f_mhz

    def ck(ns, minimum=0):
        return max(minimum, math.ceil(ns / tck - 1e-9))

    cl, cwl, bl = d["cl"], d["cwl"], 8
    half = d["bus_width"] == 16
    lanes = 2 if half else 4
    t_wr = ck(d["t_wr_ns"])
    s = Seq()
    s.write(SLCR + 0x008, 0xDF0D, 0xFFFF, "SLCR_UNLOCK")

    # ---- The DDR clock (UG585: Clock Operating Frequencies, PLLs) ----
    cp, res, cnt = PLL_TABLE[b["pll_fdiv"]]
    s.reg(SLCR + 0x114, "DDR_PLL_CFG", (cnt, 21, 12), (cp, 11, 8), (res, 7, 4))
    s.reg(SLCR + 0x104, "DDR_PLL_CTRL: PLL_FDIV", (b["pll_fdiv"], 18, 12))
    s.reg(SLCR + 0x104, "DDR_PLL_CTRL: bypass, not by the strap", (1, 4, 4), (0, 3, 3))
    s.reg(SLCR + 0x104, "DDR_PLL_CTRL: reset", (1, 0, 0))
    s.reg(SLCR + 0x104, "DDR_PLL_CTRL: out of reset", (0, 0, 0))
    s.poll(SLCR + 0x10C, 0x2, "PLL_STATUS: DDR_PLL_LOCK")
    s.reg(SLCR + 0x104, "DDR_PLL_CTRL: out of bypass", (0, 4, 4))
    s.reg(SLCR + 0x124, "DDR_CLK_CTRL", (b["ddr_2x_div"], 31, 26), (b["ddr_3x_div"], 25, 20), (1, 1, 1), (1, 0, 0))
    # DCI's clock, about 10 MHz from the DDR PLL, through two dividers.
    pll_mhz = b["ps_clk_mhz"] * b["pll_fdiv"]
    div1 = 2
    div0 = round(pll_mhz / 10.0 / div1)
    s.reg(SLCR + 0x128, "DCI_CLK_CTRL", (div1, 25, 20), (div0, 13, 8), (1, 0, 0))

    # ---- The DDR I/O buffers (UG585: DDR IOB Configuration) ----
    # Address, control and clock: outputs, no DCI. Data and strobes: DCI
    # termination with its tri-state termination on, a VREF receiver (data)
    # or a differential one (strobes). Unused lanes: inputs off.
    # TERM_DISABLE_MODE and IBUF_DISABLE_MODE stay 0, as the manual requires
    # through init and training (they only save power).
    def iob(out, dci, inp, pullup=0):
        return fields((pullup, 11, 11), (out, 10, 9), (0, 8, 8), (0, 7, 7), (dci, 6, 5), (1 if dci == 3 else 0, 4, 4),
                      (0, 3, 3), (inp, 2, 1))
    for off, name, cfg in [
            (0xB40, "DDRIOB_ADDR0", iob(3, 0, 0)), (0xB44, "DDRIOB_ADDR1", iob(3, 0, 0)),
            (0xB48, "DDRIOB_DATA0", iob(3, 3, 1)),
            (0xB4C, "DDRIOB_DATA1", iob(3, 3, 1) if not half else iob(0, 0, 0, pullup=1)),
            (0xB50, "DDRIOB_DIFF0", iob(3, 3, 2)),
            (0xB54, "DDRIOB_DIFF1", iob(3, 3, 2) if not half else iob(0, 0, 0, pullup=1)),
            (0xB58, "DDRIOB_CLOCK", iob(3, 0, 0))]:
        s.write(SLCR + off, cfg[0], 0xFFF, name)
    # Drive and slew: values the manual says only AMD's tools compute, for
    # DDR3 (1.5 V) on silicon revision 3, as AMD's tools set it.
    s.write(SLCR + 0xB5C, 0x0018C61C, note="DDRIOB_DRIVE_SLEW_ADDR, as AMD's tools set it")
    s.write(SLCR + 0xB60, 0x00F9861C, note="DDRIOB_DRIVE_SLEW_DATA, as AMD's tools set it")
    s.write(SLCR + 0xB64, 0x00F9861C, note="DDRIOB_DRIVE_SLEW_DIFF, as AMD's tools set it")
    s.write(SLCR + 0xB68, 0x00F9861C, note="DDRIOB_DRIVE_SLEW_CLOCK, as AMD's tools set it")
    # VREF: external, for the lower 16 bits (and the upper with a 32-bit bus); VRP/VRN as DCI's reference.
    ext = brd["vref"] == "external"
    s.reg(SLCR + 0xB6C, "DDRIOB_DDR_CTRL", (1, 9, 9), (0 if not ext else (1 if half else 3), 6, 5),
          (0 if ext else 4, 4, 1), (0 if ext else 1, 0, 0))
    # DCI calibration (UG585: DDR IOB Impedance Calibration): reset toggled,
    # DDR3's NREF_OPT4 = 001, enabled; then wait for DONE.
    s.reg(SLCR + 0xB70, "DDRIOB_DCI_CTRL: reset", (1, 0, 0))
    s.reg(SLCR + 0xB70, "DDRIOB_DCI_CTRL: reset low", (1, 5, 5), (0, 0, 0))
    s.reg(SLCR + 0xB70, "DDRIOB_DCI_CTRL: DDR3, enabled", (0, 20, 20), (0, 19, 17), (0, 15, 14), (1, 13, 11),
          (0, 10, 8), (0, 7, 6), (1, 5, 5), (1, 1, 1), (1, 0, 0))
    s.poll(SLCR + 0xB74, 1 << 13, "DDRIOB_DCI_STATUS: DONE")

    # ---- The DDR controller (UG585: DDR Controller Register Programming; ddrc registers) ----
    bw = 1 if half else 0
    s.reg(DDRC + 0x000, "ddrc_ctrl: in reset, bus width", (0, 16, 16), (0, 15, 15), (0, 14, 14), (1, 13, 7),
          (0, 6, 4), (bw, 3, 2), (0, 1, 1), (0, 0, 0))
    s.reg(DDRC + 0x004, "Two_rank_cfg: tREFI", (0, 18, 14), (1, 13, 12),
          (math.floor(d["t_refi_ns"] / tck / 32), 11, 0))
    # Queue tuning, as AMD's tools set it.
    s.write(DDRC + 0x008, 0x03C0780F, 0x03FFFFFF, "HPR_reg, as AMD's tools set it")
    s.write(DDRC + 0x00C, 0x02001001, 0x03FFFFFF, "LPR_reg, as AMD's tools set it")
    s.write(DDRC + 0x010, 0x00014001, 0x03FFFFFF, "WR_reg, as AMD's tools set it")
    s.reg(DDRC + 0x014, "DRAM_param_reg0", (0x10, 20, 14), (ck(d["t_rfc_ns"]), 13, 6), (ck(d["t_rc_ns"]), 5, 0))
    t_cke = ck(d["t_cke_ns"], 3)
    s.reg(DDRC + 0x018, "DRAM_param_reg1", (t_cke + 1, 31, 28), (ck(d["t_ras_ns"]), 26, 22),
          (math.floor(9 * d["t_refi_ns"] / tck / 1024), 21, 16),  # tRAS(max) = 9 x tREFI
          (ck(d["t_faw_ns"]), 15, 10), (6, 9, 5), (cwl + bl // 2 + t_wr, 4, 0))
    t_rtp = ck(d["t_rtp_ns"], 4)
    t_wtr = ck(d["t_wtr_ns"], 4)
    s.reg(DDRC + 0x01C, "DRAM_param_reg2", (ck(d["t_rcd_ns"]), 31, 28), (t_rtp, 27, 23), (0, 22, 20),
          (ck(d["t_xp_ns"], 3), 19, 15), (cwl + t_wtr + bl // 2, 14, 10), (cl + bl // 2 + 2 - cwl, 9, 5),
          (cwl - 1, 4, 0))
    s.reg(DDRC + 0x020, "DRAM_param_reg3", (0, 30, 30), (1, 29, 29), (cl, 28, 24), (0, 23, 23), (0, 22, 22),
          (0, 21, 21), (8, 20, 16), (ck(d["t_rp_ns"]), 15, 12), (2, 11, 8), (ck(d["t_rrd_ns"], 4), 7, 5),
          (4, 4, 2))
    s.reg(DDRC + 0x024, "DRAM_param_reg4", (0, 27, 27), (0, 26, 26), (0, 24, 9), (0, 8, 7), (0, 1, 1), (0, 0, 0))
    s.reg(DDRC + 0x028, "DRAM_init_param", (4, 13, 11), (0, 10, 7), (7, 6, 0))
    # Mode registers (JEDEC DDR3): MR2's CWL, MR3 0; MR1: RTT_Nom RZQ/4,
    # drive RZQ/6, DLL on; MR0: BL8, CAS latency, write recovery, DLL reset.
    mr2 = (cwl - 5) << 3
    mr1 = 0x0004
    cas = {5: 0x10, 6: 0x20, 7: 0x30, 8: 0x40, 9: 0x50, 10: 0x60, 11: 0x70}[cl]
    wr = {5: 1, 6: 2, 7: 3, 8: 4, 10: 5, 12: 6, 14: 7, 16: 0}[t_wr]
    mr0 = (wr << 9) | 0x100 | cas
    s.reg(DDRC + 0x02C, "DRAM_EMR_reg: MR3, MR2", (0, 31, 16), (mr2, 15, 0))
    s.reg(DDRC + 0x030, "DRAM_EMR_MR_reg: MR1, MR0", (mr1, 31, 16), (mr0, 15, 0))
    # Init waits: CKE after at least 500 us (700 here), as the DDR3 spec asks.
    s.reg(DDRC + 0x034, "DRAM_burst8_rdwr", (0, 28, 28), (1, 25, 16), (math.ceil(700_000 / tck / 1024), 13, 4),
          (4, 3, 0))
    s.reg(DDRC + 0x038, "DRAM_disable_DQ", (0, 1, 1), (0, 0, 0))
    # Address map: byte address -> column, bank, row (UG585: Row/Bank/Column
    # Address Mapping; the ddrc addr_map registers' internal bases). Columns
    # from the lowest bits, then the banks, then the rows.
    col0 = 1 if half else 2           # the first address bit above the byte in a bus word
    bank0 = col0 + d["cols"]          # first bank address bit
    row0 = bank0 + 3                  # first row address bit
    # Field col_bN (internal base N + 3) maps column N+1 at full width, N+2
    # at half width, except that column 10 is auto-precharge: the field that
    # would map it maps column 11, and those after it go on from there. Column
    # c is the c-th column bit, not counting bit 10; one past the device's
    # columns is unused (15).
    colmap = {}
    for n in range(2, 12):
        column = n + (2 if half else 1)
        if column >= 10:
            column += 1
        packed = column - 1 if column > 10 else column
        colmap[n] = col0 + packed - (n + 3) if packed < d["cols"] else 15
    s.reg(DDRC + 0x03C, "DRAM_addr_map_bank", (colmap[6], 19, 16), (colmap[5], 15, 12), (bank0 + 2 - 7, 11, 8),
          (bank0 + 1 - 6, 7, 4), (bank0 - 5, 3, 0))
    s.reg(DDRC + 0x040, "DRAM_addr_map_col", (colmap[11], 31, 28), (colmap[10], 27, 24), (colmap[9], 23, 20),
          (colmap[8], 19, 16), (colmap[7], 15, 12), (colmap[4], 11, 8), (colmap[3], 7, 4), (colmap[2], 3, 0))
    rows = d["rows"]
    rowf = row0 - 9
    s.reg(DDRC + 0x044, "DRAM_addr_map_row", (rowf if rows > 15 else 15, 27, 24), (rowf if rows > 14 else 15, 23, 20),
          (rowf if rows > 13 else 15, 19, 16), (rowf, 15, 12), (rowf, 11, 8), (rowf, 7, 4), (rowf, 3, 0))
    # ODT, the PHY's command timeouts and training sample counts, as AMD's tools set them for DDR3.
    s.write(DDRC + 0x048, 0x0003C008, 0x0003F03F, "DRAM_ODT_reg, as AMD's tools set it")
    s.reg(DDRC + 0x050, "phy_cmd_timeout_rddata_cpt", (7, 31, 28), (7, 27, 24), (0, 19, 19), (0, 18, 18),
          (0, 17, 17), (1, 16, 16), (0, 15, 15), (8, 11, 8), (0, 7, 4), (0, 3, 0))
    s.reg(DDRC + 0x058, "DLL_calib", (0, 16, 16))
    s.write(DDRC + 0x05C, 0x00005003, 0x0000FFFF, "ODT_delay_hold, as AMD's tools set it")
    s.reg(DDRC + 0x060, "ctrl_reg1", (0, 12, 12), (0, 10, 10), (0, 9, 9), (0, 8, 8), (0, 7, 7), (0x1F, 6, 1),
          (0, 0, 0))
    s.reg(DDRC + 0x064, "ctrl_reg2", (1, 17, 17), (0, 12, 5))
    rl = cl
    s.reg(DDRC + 0x068, "ctrl_reg3", (0x28, 25, 16), (rl + 8 + 50, 15, 8), (rl + 8 + 50, 7, 0))
    s.reg(DDRC + 0x06C, "ctrl_reg4", (0x16, 15, 8), (0x10, 7, 0))
    cksre = ck(d["t_cksre_ns"], 5)
    s.reg(DDRC + 0x078, "ctrl_reg5", (t_cke + 1, 25, 20), (cksre, 19, 16), (cksre, 15, 12), (1, 11, 8),
          (1, 7, 4), (1, 3, 0))
    s.reg(DDRC + 0x07C, "ctrl_reg6", (3, 19, 16), (2, 15, 12), (2, 11, 8), (2, 7, 4), (2, 3, 0))
    # ZQ: ZQCS 64 clocks, ZQCL 512, tMOD 512, DDR3; reset held 200 us, ZQCS every 100 ms.
    s.reg(DDRC + 0x0A4, "CHE_T_ZQ", (64, 31, 22), (512, 21, 12), (512, 11, 2), (1, 1, 1), (0, 0, 0))
    s.reg(DDRC + 0x0A8, "CHE_T_ZQ_Short_Interval_Reg", (math.ceil(200_000 / tck / 1024), 27, 20),
          (math.floor(100e6 / tck / 1024), 19, 0))
    s.reg(DDRC + 0x0AC, "deep_pwrdwn_reg", (0xFF, 8, 1), (0, 0, 0))
    # Training: all three steps, with the longest timeouts.
    s.reg(DDRC + 0x0B0, "reg_2c: training", (1, 28, 28), (1, 27, 27), (1, 26, 26), (0, 25, 25), (0, 24, 24),
          (0xFFF, 23, 12), (0xFFF, 11, 0))
    s.reg(DDRC + 0x0B4, "reg_2d", (1, 9, 9))
    s.reg(DDRC + 0x0B8, "dfi_timing", (0x40, 24, 15), (3, 14, 5), (rl - 1, 4, 0))
    s.reg(DDRC + 0x0C4, "ECC: clear", (3, 1, 0))
    s.reg(DDRC + 0x0C4, "ECC: clear done", (0, 1, 0))
    s.reg(DDRC + 0x0C8, "ECC log", (0, 7, 0))
    s.reg(DDRC + 0x0DC, "ECC unrecoverable log", (0, 0, 0))
    s.reg(DDRC + 0x0F0, "ECC stats", (0, 15, 0))
    s.reg(DDRC + 0x0F4, "ECC_scrub: no ECC", (8, 3, 0))
    s.reg(DDRC + 0x114, "phy_rcvr_enable", (0, 7, 0))
    # The PHY's data slices: in use per the bus width; DQ 90 degrees after DQS.
    for i in range(4):
        s.reg(DDRC + 0x118 + 4 * i, f"PHY_Config{i}", (0x40, 30, 24), (1 if i < lanes else 0, 0, 0))
    # Training's starting points per lane, in 256ths of a clock (UG585: DRAM
    # Training). The clock to the DRAM is inverted (half a cycle later), as
    # the manual asks when DQS-to-CLK skew is too small to level against.
    def ratio(ns):
        return round(ns / tck * 256)
    for i in range(4):
        j = min(i, len(brd["board_delay_ns"]) - 1)
        wl_final = ratio(brd["dqs_to_clk_ns"][j]) + 128
        wl_init = max(0, wl_final - 128)
        gate_final = ratio(2 * brd["board_delay_ns"][j]) + 128
        gate_init = max(0, gate_final - 32)
        rd_dqs = 0x35
        s.reg(DDRC + 0x12C + 4 * i, f"phy_init_ratio{i}", (gate_init, 19, 10), (wl_init, 9, 0))
        s.reg(DDRC + 0x140 + 4 * i, f"phy_rd_dqs_cfg{i}", (0, 19, 11), (0, 10, 10), (rd_dqs, 9, 0))
        s.reg(DDRC + 0x154 + 4 * i, f"phy_wr_dqs_cfg{i}", (0, 19, 11), (0, 10, 10), (wl_final, 9, 0))
        s.reg(DDRC + 0x168 + 4 * i, f"phy_we_cfg{i}", (0, 20, 12), (0, 11, 11), (gate_final + rd_dqs, 10, 0))
        s.reg(DDRC + 0x17C + 4 * i, f"wr_data_slv{i}", (0, 19, 11), (0, 10, 10), (wl_final + 0x40, 9, 0))
    s.reg(DDRC + 0x190, "reg_64: clock out inverted; command slave ratio as AMD's tools set it", (0, 30, 30),
          (0, 29, 29), (0, 27, 21), (0, 20, 20), (0x100, 19, 10), (0, 9, 9), (1, 7, 7), (0, 1, 1))
    s.reg(DDRC + 0x194, "reg_65: use the training results", (0, 19, 18), (0, 17, 17), (1, 16, 16), (1, 15, 15),
          (1, 14, 14), (0xF, 13, 10), (max(1, rl - 3), 9, 5), (max(1, cwl - 4), 4, 0))
    s.reg(DDRC + 0x204, "page_mask", (0, 31, 0))
    for i in range(4):
        s.reg(DDRC + 0x208 + 4 * i, f"axi_priority_wr_port{i}", (0, 18, 18), (0, 17, 17), (0, 16, 16), (0x3FF, 9, 0))
        s.reg(DDRC + 0x218 + 4 * i, f"axi_priority_rd_port{i}", (0, 19, 19), (0, 18, 18), (0, 17, 17), (0, 16, 16),
              (0x3FF, 9, 0))
    s.write(DDRC + 0x2A8, 0x0, 0xFF5, "lpddr_ctrl0: not LPDDR2")
    s.write(DDRC + 0x2AC, 0x0, note="lpddr_ctrl1")
    s.write(DDRC + 0x2B0, 0x00005125, 0x003FFFFF, "lpddr_ctrl2, as AMD's tools set it")
    s.write(DDRC + 0x2B4, 0x000012A6, 0x0003FFFF, "lpddr_ctrl3, as AMD's tools set it")
    # Out of reset: the controller resets and initializes the DRAM and trains.
    s.reg(DDRC + 0x000, "ddrc_ctrl: out of reset", (1, 13, 7), (bw, 3, 2), (1, 0, 0))
    s.poll(DDRC + 0x054, 0x7, "mode_sts_reg: normal operation")

    # ---- The fabric: level shifters both ways, resets released ----
    s.reg(SLCR + 0x900, "LVL_SHFTR_EN: all", (0xF, 3, 0))
    s.write(SLCR + 0x240, 0x0, note="FPGA_RST_CTRL: released")
    s.write(SLCR + 0x004, 0x767B, 0xFFFF, "SLCR_LOCK")
    return s, f_mhz


def tcl(seq, f_mhz, source):
    out = [f"# SPDX-License-Identifier: Apache-2.0",
           f"# Generated by boards/xilinx/zynq7/ps7_ddr3.py from {source}: don't edit.",
           f"# Zynq-7000 DDR3 at {f_mhz:g} MHz. Run with the core halted.", "",
           "proc ps7_mask_write {addr mask value} {",
           "    set old [read_memory $addr 32 1]",
           "    write_memory $addr 32 [expr {($old & ~$mask & 0xFFFFFFFF) | ($value & $mask)}]",
           "}", "",
           "proc ps7_mask_poll {addr mask what} {",
           "    for {set i 0} {$i < 2000} {incr i} {",
           "        if {[read_memory $addr 32 1] & $mask} { return }",
           "        sleep 1",
           "    }",
           "    error \"ps7: timed out waiting for $what\"",
           "}", "",
           "proc ps7_ddr3_init {} {"]
    for op, addr, mask, value, note in seq.ops:
        if op == "write":
            out.append(f"    ps7_mask_write 0x{addr:08X} 0x{mask:08X} 0x{value:08X} ;# {note}")
        elif op == "poll":
            out.append(f"    ps7_mask_poll 0x{addr:08X} 0x{mask:08X} {{{note}}}")
        else:
            out.append(f"    sleep {max(1, value // 1000)} ;# {note}")
    out += ["}", "",
            "# A quick check from the core: a pattern written across the DDR reads back.",
            "proc ps7_ddr3_check {} {",
            "    set bad 0",
            "    foreach a {0x00100000 0x01000000 0x08000000 0x10000000 0x1FFFFF00} {",
            "        set v [expr {($a * 2654435761 + 0x5A5A5A5A) & 0xFFFFFFFF}]",
            "        write_memory $a 32 $v",
            "        write_memory [expr {$a + 4}] 32 [expr {~$v & 0xFFFFFFFF}]",
            "    }",
            "    foreach a {0x00100000 0x01000000 0x08000000 0x10000000 0x1FFFFF00} {",
            "        set v [expr {($a * 2654435761 + 0x5A5A5A5A) & 0xFFFFFFFF}]",
            "        if {[read_memory $a 32 1] != $v || [read_memory [expr {$a + 4}] 32 1] != (~$v & 0xFFFFFFFF)} {",
            "            echo [format \"ps7: DDR at 0x%08X reads wrong\" $a]",
            "            incr bad",
            "        }",
            "    }",
            "    return $bad",
            "}", ""]
    return "\n".join(out)


def compare(seq, path):
    """Each register this code writes, against the last masked write to it in
    another init file's tables (decoded, not copied)."""
    text = Path(path).read_text()
    ref = {}
    for m in re.finditer(r"EMIT_MASKWRITE\(\s*0[xX]([0-9A-Fa-f]+)\s*,\s*0[xX]([0-9A-Fa-f]+)U?\s*,\s*0[xX]([0-9A-Fa-f]+)U?\s*\)",
                         text[:text.find("_2_0[]")] if "_2_0[]" in text else text):
        a, mk, v = (int(x, 16) for x in m.groups())
        old = ref.get(a, (0, 0))
        ref[a] = ((old[0] & ~mk) | (v & mk), old[1] | mk)
    ours = {}
    for op, a, mk, v, note in seq.ops:
        if op == "write":
            old = ours.get(a, (0, 0, note))
            ours[a] = ((old[0] & ~mk) | v, old[1] | mk, note)
    diffs = 0
    for a in sorted(ours):
        if a not in ref:
            continue
        v, mk, note = ours[a]
        rv, rm = ref[a]
        both = mk & rm
        if (v ^ rv) & both:
            diffs += 1
            print(f"0x{a:08X} {note:50} ours 0x{v & both:08X} theirs 0x{rv & both:08X} (bits 0x{(v ^ rv) & both:08X})")
    print(f"{diffs} registers differ")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("board", type=Path)
    ap.add_argument("--tcl", type=Path)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--compare", type=Path)
    args = ap.parse_args()
    b = tomllib.loads(args.board.read_text())
    seq, f_mhz = build(b)
    if args.tcl:
        args.tcl.write_text(tcl(seq, f_mhz, args.board))
    if args.list:
        for op, a, mk, v, note in seq.ops:
            print(f"{op:5} 0x{a:08X} 0x{mk:08X} 0x{v:08X}  {note}")
    if args.compare:
        compare(seq, args.compare)
    return 0


if __name__ == "__main__":
    sys.exit(main())
