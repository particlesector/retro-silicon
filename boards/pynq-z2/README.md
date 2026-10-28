# PYNQ-Z2

TUL PYNQ-Z2: AMD Zynq-7020 (XC7Z020-1CLG400C), a 125 MHz clock from the Ethernet PHY on pin H16, 512 MB of DDR3 on the processor's side, HDMI in and out, two PMOD sockets, and an FTDI FT2232 on the micro-USB port marked PROG UART for JTAG. Its USB UART goes to the processor, not the FPGA.

The library's first board outside Gowin's family, and its check that the components carry over to another vendor's FPGA with only `boards/` changed.

## Building

`build.sh` runs `../xilinx/build.sh` for this part with [openXC7](https://github.com/openXC7): Yosys's `synth_xilinx`, nextpnr-xilinx, and Project X-Ray's fasm2frames and xc7frames2bit. It needs those on PATH and two databases from the same openXC7 release: `RS_XC7_CHIPDB`, the directory holding `xc7z020clg400.bin`, and `RS_PRJXRAY_DB`, Project X-Ray's database.

nextpnr-xilinx's results vary a lot from seed to seed (the NES's system clock has come out anywhere from 38 to 52 MHz against 46.4), and now and then it routes through a tile Project X-Ray can't encode (`fasm2frames` stops on a tile name its grid lacks). So the build places with seeds 1 to 8 in turn and keeps the first placement that meets every constraint and assembles; if none does, the build fails.

```sh
boards/pynq-z2/build.sh -t <top> -c pins.xdc -o <outdir> [-g NAME=VALUE]... <sources...>
```

The CMake build runs it for each design below when nextpnr-xilinx is on PATH; bitstreams land in `build/fpga/pynq_<name>/`. Set the boot jumper to JTAG, then load one into the FPGA's configuration SRAM:

```sh
openFPGALoader -b pynq_z2 build/fpga/pynq_uart_echo/pynq_echo_top.bit
```

## Designs

| Target | Design | Top | Notes |
| --- | --- | --- | --- |
| `pynq_uart_echo_bitstream` | `systems/uart-echo` | `rtl/pynq_echo_top.sv` | 1.506 Mbaud (`CLKS_PER_BIT=83`), `pins.xdc` |
| `pynq_shell_ram_bitstream` | `systems/shell-ram` | `rtl/pynq_shell_ram_top.sv` | As echo; `BUILD_ID` from the RTL's SHA-256, the same as the Tang boards' |
| `pynq_nes_bitstream` | `systems/nes` through `nes_bram`, with HDMI | `rtl/pynq_nes_top.sv` | `nes.xdc`; its own clocks (below), 1.485 Mbaud (`CLKS_PER_BIT=25`), 32 KB of block RAM for the memory, paced by the display |

## Clocks

The echo and the shell run on the 125 MHz clock on H16, which the Ethernet PHY makes; it runs with the processor not booted. 83 clocks a bit is 1.506 Mbaud, 0.4% fast of the host's 1.5 Mbaud.

The NES makes the Tang Nano 20K's HDMI clocks, 371.25 MHz for the serializers and 74.25 MHz for the pixels, and 37.125 MHz for the system, where a UART bit is 25 clocks (1.485 Mbaud, 1% slow) and the PPU's dot rate 35/242 of the clock, exactly NTSC's. The system is slower than the 20K's 46.4 MHz because nextpnr-xilinx's placements of the NES reach anywhere from 38 to 52 MHz; it behaves the same at any clock. No integer PLL or MMCM setting makes 742.5 MHz from 125, and openXC7 sets an MMCM's fractional dividers wrong (measured on this board: a fractional multiplier gave about 11.8 MHz for 74.2, a fractional output divider no clock), so it takes two steps: a PLL makes 82.5 MHz (125 / 5 × 33 / 10), and an MMCM multiplies that by 9 to 742.5 MHz and divides it by 2, 10 and 20. The system's clock goes through a BUFGCE held off until the MMCM locks.

## Memory

`nes_bram` has 32 KB here, NROM's largest PRG ROM. Yosys builds anything deeper from pairs of cascaded block RAMs, and nextpnr-xilinx fails to place them; the mappers of milestone 9 will need a way round that, or the DDR3, which only the processor's side reaches.

## HDMI

HDMI OUT is driven as TMDS (`TMDS_33`) by `boards/xilinx/rtl/tmds_phy_xc7.sv`: a master and slave OSERDESE2 per channel, 10:1 at 371.25 MHz on both edges, into an OBUFDS. The picture is the same 720p as the Tang Nano 20K's, from the same `nes_video`: a desk monitor shows it, its video CRCs match the 20K's, and the capture dongle's picture of each test ROM's golden frame matches it (`rig-run --board pynqz2 --test hdmi`). `boards/xilinx/sim` checks which channel comes out on which pair.

## UART

Use an external 3.3 V USB-serial adapter on PMOD A (JA): FPGA TX on JA1P (Y18, the pin nearest the Raspberry Pi header in the column of Y pins) to the adapter's RX, the adapter's TX to JA1N (Y19, the next pin), and the adapter's ground to that column's GND (the 5th pin). PMOD A shares its pins with the Raspberry Pi header, so leave that empty.

While the FPGA configures, its pins float (no pull-ups), so the adapter's receiver sees whatever the loose line picks up. After some loads that leaves an FT232RL clone reporting errors without end, whatever design is then loaded, until it's reset; now and then the line itself stays noisy for a while. A 10 kΩ pull-up from JA1P to the socket's 3.3 V pin would hold the line high through configuration, as the Tang boards' own pull-ups do.

## LEDs

LD0 overflow and LD1 framing error (both sticky until reload), LD3 heartbeat, for the echo design. Active high.

## Status

On the board, with the same CRCs as the Tang boards: the UART echo (also 10 MB with no errors), the test shell with injected faults, nestest's bus trace, the save-state round trip, all 42 test ROMs with MesenCE's frame CRCs, and HDMI at 720p, both the video CRCs (full_palette's once `video/line-scaler` stopped using block RAM parity bits) and the captured picture.
