# zynq7

The Zynq-7000's processing system, for designs that use it from the fabric.

## DDR3 bring-up: `ps7_ddr3.py`

Starts a board's DDR3 and opens the fabric's way to it, with no boot loader and no operating system: the register writes, computed from a board description (`boards/<board>/ps/ddr3.toml`) and AMD's *Zynq 7000 SoC Technical Reference Manual* (UG585):

1. the DDR PLL and clocks (and DCI's 10 MHz clock);
2. the DDR I/O buffers, VREF, and the DCI impedance calibration;
3. the DDR controller's registers: timings in clocks from the DRAM's nanoseconds, the DDR3 mode registers, the address map for the bus width, the PHY's data slices, and training's starting points from the board's per-lane delays;
4. the controller's enable, after which it resets and initializes the DRAM and runs write leveling, read gate and read data eye training itself;
5. the PS–PL level shifters and the fabric's resets, so the HP ports can reach the DDR.

```
boards/xilinx/zynq7/ps7_ddr3.py boards/pynq-z2/ps/ddr3.toml --tcl ddr3.tcl   # an OpenOCD script
boards/xilinx/zynq7/ps7_ddr3.py boards/pynq-z2/ps/ddr3.toml --list           # the writes, annotated
```

The OpenOCD script has `ps7_ddr3_init` and `ps7_ddr3_check` (a pattern across the DDR). Run them on a target that reaches the system bus: best the DAP's AHB access port (a `mem_ap` target on AP 0), which leaves the cores alone, or a halted core. Before the fabric is configured again, run `ps7_fabric_off`: the fabric's signals float while it configures, so it turns the PS–PL level shifters off and holds the fabric's resets, as AMD's boot flow does. Without it, on the PYNQ-Z2, loading other bitstreams over a running HP0 design jammed the processor side's interconnect: a read of the DDR controller never finished. `ps7_ddr3_init` turns them on again. `ps7_ddr3_init` leaves DDR that's already running alone and only redoes the fabric's part: changing the DDR clock under a running controller hangs the bus, and a core waiting on it then can't be debugged until the PS is reset (the SLCR's `PSS_RST_CTRL`, written through the AHB port, recovers it).

A few values the manual leaves to AMD's tools (the I/O drive and slew settings, which it says only those tools compute, the PHY's command slave ratio, the controller's queue tuning and ODT) are as AMD's tools set them for DDR3 on comparable boards, read from their generated files for facts. `--compare` decodes such a file and lists where this code differs: for the Zybo's DDR3 at the same speed, every timing, mode, address-map, PHY and clock register matches, and only the board-delay-dependent training values (and the power-saving I/O modes those tools set after training) differ.

Silicon revision 3 (the PYNQ-Z2's: `PS_VERSION` 3), DDR3 at 1.5 V.

## Status

On the PYNQ-Z2 (Oct 30), over JTAG with OpenOCD: the controller reaches normal operation, all three training steps finish without a timeout, and a pattern written at five places across the 512 MB reads back. From the fabric, through HP0 (`systems/shell-axi`), the harness's SDRAM test passes on 8 MB with the same CRC as the Tang Nano 20K's SDRAM.
