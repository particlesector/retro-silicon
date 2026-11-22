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
| `pynq_nes_bitstream` | `systems/nes` through `nes_axi`, with HDMI | `rtl/pynq_nes_top.sv` | `nes.xdc`; its own clocks (below), 1.485 Mbaud (`CLKS_PER_BIT=25`), PRG ROM in the DDR3 and 256 KB of CHR in block RAM, paced by the display |
| `pynq_a2600_bitstream` | `systems/atari-2600`'s `a2600_sys`, with HDMI | `rtl/pynq_a2600_top.sv` | `nes.xdc`; the NES's clocks, 1.485 Mbaud, 256 KB of cartridge ROM in block RAM, paced by the display; no DDR3 |
| `pynq_gb_bitstream` | `systems/game-boy`'s `gb_sys`, with HDMI | `rtl/pynq_gb_top.sv` | `nes.xdc`; the NES's clocks, T-cycles at 35/304 (the 20K's rate), the cartridge's ROM in the DDR3 from 0x10000000 (`gb_axi`: HP0 and `memory/cache`, as `nes_axi`), its RAM in block RAM, paced by the display; the Game Boy Color too (G7) |

## Clocks

The echo and the shell run on the 125 MHz clock on H16, which the Ethernet PHY makes; it runs with the processor not booted. 83 clocks a bit is 1.506 Mbaud, 0.4% fast of the host's 1.5 Mbaud.

The NES makes the Tang Nano 20K's HDMI clocks, 371.25 MHz for the serializers and 74.25 MHz for the pixels, and 37.125 MHz for the system, where a UART bit is 25 clocks (1.485 Mbaud, 1% slow) and the PPU's dot rate 9/61 of the clock, 2.0% faster than NTSC's. Keeping pace with the display, the NES waits at each frame's end, so it still makes 60 frames a second and its sound is unchanged; the 2% leaves room for the DDR3's waits. At NTSC's rate a frame takes 99.84% of a 60 Hz display frame, so a few hundred clocks of waits made a frame miss its display frame and wait for the next: Kirby's Adventure stuttered several times a second with enemies on screen (Nov 5). The system is slower than the 20K's 46.4 MHz because nextpnr-xilinx's placements of the NES reach anywhere from 38 to 52 MHz; it behaves the same at any clock. No integer PLL or MMCM setting makes 742.5 MHz from 125, and openXC7 sets an MMCM's fractional dividers wrong (measured on this board: a fractional multiplier gave about 11.8 MHz for 74.2, a fractional output divider no clock), so it takes two steps: a PLL makes 82.5 MHz (125 / 5 × 33 / 10), and an MMCM multiplies that by 9 to 742.5 MHz and divides it by 2, 10 and 20. The system's clock goes through a BUFGCE held off until the MMCM locks.

The Atari 2600 runs on the same clocks, its colour clock 35/356 of the system clock (3.65 MHz, 2% fast of NTSC's). The system clock is half the pixel clock, as on the Tang Console 138K, so that's the Tang Nano 20K's colour clock against its pixel clock: the 2600 keeps pace with its display as there, a frame of 262 lines taking 98.2% of a display frame, and its video CRCs are the 20K's. nextpnr-xilinx places it at 40.2 MHz, with the pixel clock at 86 MHz.

## Memory

`nes_axi` keeps PRG ROM in the DDR3 from 0x10000000, through HP0 and `memory/cache`, with HP0 and the AXI bridge on the 74.25 MHz pixel clock. CHR's 256 KB of block RAM is built in 32 KB banks: Yosys builds anything deeper from pairs of cascaded block RAMs, and nextpnr-xilinx fails to place them.

The Game Boy's memories are all 8 bits wide or less and none deeper than 32 KB, as openXC7 needs. Its first build read the boot ROM back wrong: the shell's 256-byte copy, written in block RAM's write-first form (a write gives its own byte), became a Yosys distributed RAM (`$__XILINX_LUTRAM_SP_`) that took each write's first clock at the bus's address before it, so every byte of a block landed an address low too. Written as a plain read-before-write memory, it reads back right; the memories in write-first form that became block RAMs (the frame buffer's port, video RAM's CPU port) are right as they are. nextpnr-xilinx places the system clock at 41.5 MHz with the cartridge's ROM in the DDR3 (G6), 12% over the 37.125 it runs at (41.3 with the APU in G5, 40.4 before it). With the Game Boy Color (G7) it first placed at 37.47 MHz, 0.9% over: the CPU's address ran through the memory map's decode into the PPU's register writes in one clock. The PPU takes the CPU's writes registered now, as the APU does (the address is steady from the clock after an M-cycle starts, and the PPU takes a write no sooner than its second T-cycle), and it placed at 41.9 MHz, 13% over, with 42 of 140 36 Kb block RAMs (21 before); at G7's end it places at 44.1 MHz, 19% over. Over all 129 test ROMs, about 2 billion T-cycles, the CPU waited 19 clocks in all for the DDR3. With the dongle's capture running, don't open its audio (`arecord`) as well: a capture taken while the recording started was torn (the frame's top 45 lines, then black), though the board's video CRC was right.

The 2600's cartridge ROM, 256 KB (`ROM_LOG2` 18), is in block RAM in 32 KB memories the same way (`ROM_BANK_LOG2` 15): 64 of the XC7Z020's 140 36 Kb block RAMs. 512 KB, as the Tang boards have, would take 128, with the rest of the system needing more than the 12 left; 256 KB holds every scheme `a2600_cart` has.

## HDMI

HDMI OUT is driven as TMDS (`TMDS_33`) by `boards/xilinx/rtl/tmds_phy_xc7.sv`: a master and slave OSERDESE2 per channel, 10:1 at 371.25 MHz on both edges, into an OBUFDS. The picture is the same 720p as the Tang Nano 20K's, from the same `nes_video`: a desk monitor shows it, its video CRCs match the 20K's, and the capture dongle's picture of each test ROM's golden frame matches it (`rig-run --board pynqz2 --test hdmi`). `boards/xilinx/sim` checks which channel comes out on which pair.

## UART

Use an external 3.3 V USB-serial adapter on PMOD A (JA): FPGA TX on JA1P (Y18, the pin nearest the Raspberry Pi header in the column of Y pins) to the adapter's RX, the adapter's TX to JA1N (Y19, the next pin), and the adapter's ground to that column's GND (the 5th pin). PMOD A shares its pins with the Raspberry Pi header, so leave that empty.

While the FPGA configures, its pins float (no pull-ups), so the adapter's receiver sees whatever the loose line picks up. After some loads that leaves an FT232RL clone reporting errors without end, whatever design is then loaded, until it's reset; now and then the line itself stays noisy for a while. A 10 kΩ pull-up from JA1P to the socket's 3.3 V pin would hold the line high through configuration, as the Tang boards' own pull-ups do.

## LEDs

LD0 overflow and LD1 framing error (both sticky until reload), LD3 heartbeat, for the echo design. Active high.

## Status

**Now (Nov 2026):** the NES (`nes_axi`, PRG ROM in the DDR3) passes all 190 golden ROMs, the HDMI checks and 63 checks of 29 commercial games, and the Atari 2600 (`pynq_a2600`) all 29 test cartridges, its HDMI checks and 892 checks of 446 commercial games, all with the Tang boards' CRCs.

At bring-up (Oct 27), on the board, with the same CRCs as the Tang boards: the UART echo (also 10 MB with no errors), the test shell with injected faults, nestest's bus trace, the save-state round trip, all 42 test ROMs with MesenCE's frame CRCs, and HDMI at 720p, both the video CRCs (full_palette's once `video/line-scaler` stopped using block RAM parity bits) and the captured picture.
