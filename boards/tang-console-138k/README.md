# Tang Console 138K

Sipeed Tang Console with the Tang Mega 138K module: Gowin GW5AST-LV138PG484A (`GW5AST-138C`), a 50 MHz oscillator on pin V22, 1 GB of DDR3, two PMOD sockets, and an onboard BL616 for JTAG and a UART on the USB-C port marked MCU.

## Building

The board builds with Gowin EDA, Gowin's own tools (decided Nov 1): the open flow has no PLL for this part, and with one the NES runs on its PLL's clocks with HDMI. `build.sh` runs `../gowin-eda/build.sh` for this part, with the 50 MHz oscillator constrained; `RS_GOWIN_EDA` must name Gowin EDA's IDE directory (the one holding `bin/gw_sh`). Gowin EDA's free Education edition is enough, and it's closed and behind a login, so each user downloads it; it's never part of this library. The CMake build makes this board's bitstreams only when `RS_GOWIN_EDA` is set. Gowin's timing analysis covers setup and hold, and a miss fails the build.

### Setting up Gowin EDA

1. Download Gowin EDA's Education edition for your OS from Gowin's site (it needs a free account). Sipeed lists the Tang Console 138K among the boards it supports; this library is built and tested with 1.9.11.03 on Linux. The Education edition needs no license.
2. Unpack it anywhere and point `RS_GOWIN_EDA` at its `IDE` directory, the one holding `bin/gw_sh`.
3. On Linux, Gowin's bundled FreeType can clash with the system's fontconfig and stop `gw_sh` before it starts, even headless. If it does, set `RS_GOWIN_EDA_PRELOAD` to the system's FreeType (on Debian and Ubuntu `/usr/lib/x86_64-linux-gnu/libfreetype.so.6`); the build preloads it for `gw_sh`.
4. Configure the CMake build with those set, so it makes the `console_*_bitstream` targets:

```sh
export RS_GOWIN_EDA=/path/to/Gowin/IDE RS_GOWIN_EDA_PRELOAD=/usr/lib/x86_64-linux-gnu/libfreetype.so.6
cmake --preset default && cmake --build --preset default --target console_nes_bitstream
```

The open flow (Yosys and nextpnr's GW5AST-138C support through Apicula) can build this part's simple designs, but it has no PLL for it, so it can't make the NES's HDMI clocks; this board uses Gowin EDA only.

```sh
RS_GOWIN_EDA=/path/to/Gowin/IDE boards/tang-console-138k/build.sh -t <top> -c <pins.cst> -o <outdir> [-k NET=MHz]... [-g NAME=VALUE]... [-x OPTION=VALUE]... <sources...>
```

The CMake build runs it for each design below; bitstreams land in `build/fpga/console_<name>/`. Load one into the FPGA's configuration SRAM, which is lost at power-off but doesn't wear the flash:

```sh
openFPGALoader -b tangconsole build/fpga/console_nes/nes_top.fs
```

## Designs

| Target | Design | Top | Notes |
| --- | --- | --- | --- |
| `console_uart_echo_bitstream` | `systems/uart-echo` | `rtl/echo_top.sv` | On the 50 MHz oscillator: 1.515 Mbaud (`CLKS_PER_BIT=33`); `pins.cst` |
| `console_shell_ram_bitstream` | `systems/shell-ram` | `rtl/shell_ram_top.sv` | As echo; `BUILD_ID` from the RTL's SHA-256, the same as the Tang Nano 20K's |
| `console_shell_sdram_bitstream` | `systems/shell-sdram` | `rtl/shell_sdram_top.sv` | As echo, with the SDRAM module (below); `sdram.cst` |
| `console_nes_bitstream` | `systems/nes` through `nes_sdram` | `rtl/nes_top.sv` | Its PLL's clocks (below), PRG ROM in the SDRAM module, HDMI at 720p; `nes.cst` |
| `console_a2600_bitstream` | `systems/atari-2600`'s `a2600_sys` | `rtl/a2600_top.sv` | The NES's clocks, 512 KB of cartridge ROM in block RAM, HDMI at 720p; `a2600.cst` (`nes.cst` without the SDRAM module), `nes.sdc` |

## Clocks

Echo and the shell run on the 50 MHz oscillator. The NES's clocks come from the GW5A's `PLL`: its VCO at 743.75 MHz (50 x 14.875, its multiplier taking eighths; the VCO must be 650 to 1300 MHz) gives 371.875 MHz for the serializers (/2) and 37.1875 MHz for the system (/20), gated by `DCE` (the GW5A's `DQCE`) until the PLL locks, and `CLKDIV` makes the 74.375 MHz pixel clock (371.875 / 5) in phase with the serializers. The HDMI clocks are 0.17% above the Tang Nano 20K's, well inside HDMI's tolerance, and the system clock is half the pixel clock, as on the PYNQ-Z2: 25 clocks a bit (1.4875 Mbaud) and dots at 35/242 of the clock, so the NES keeps pace with its display as there. Gowin EDA places the NES at 37.7 to 41 MHz (with `timing_driven`, `place_option=2` and `route_option=2`; 33 MHz without), short of the 20K's 46.4.

The Atari 2600 runs on the same clocks, its colour clock 35/356 of the system clock (3.65625 MHz, 2% fast of NTSC's): that's the Tang Nano 20K's colour clock against its pixel clock, so the 2600 keeps pace with its display as there, a frame of 262 lines taking 98.2% of a display frame. Gowin EDA places it at 37.6 MHz, with the pixel clock at 74.6 MHz: both just above their constraints, the system's slowest path the CPU's address to the cartridge ROM's block RAMs, the pixel clock's `a2600_video`'s line logic.

## HDMI

The HDMI connector's pairs, as emulated LVDS (`tmds_phy`'s `ELVDS_OBUF`, `LVCMOS33D`): clock G15/G16, data 0 J14/H14, data 1 J15/H15, data 2 K17/J17.

## Memory

`systems/nes` runs on `nes_sdram`, with PRG ROM in the SDRAM module (below): the NES's 8 MB window is the module's first 8 MB. CHR, up to 256 KB, is in block RAM: CHR from the SDRAM (`CHR_EXT`) reads 32-bit words and needs 8 clocks a dot, and the module is 16 bits wide and this board's NES has 6.9 clocks a dot. The DDR3 needs a controller.

### SDRAM module

The console has two 40-pin SDRAM connectors in MiSTer's layout: SDRAM0 (J9, near the PCIe connector) and SDRAM1 (J10, near the PMOD sockets, which Sipeed's schematic gives to a GBA cartridge adapter and which shares pins with the configuration SPI). Sipeed's SDRAM module plugs into SDRAM0: two Winbond W9825G6KH (16M × 16, 32 MB each, 64 MB in all), wired as MiSTer's dual-chip boards are, both on the same pins with the second chip's CS inverted, so `memory/sdram` drives it with `RANKS=2`. The pins, from Sipeed's schematic (`Tang_Mega_138K_Console_32001C`), are in `sdram.cst`; DQM0 and DQM1 reach the connector's pins 29 and 30 through the board's 0-ohm links, and the controller also puts the byte masks on A11 and A12, where MiSTer's boards wire them. The module ties CKE high. `shell_sdram_top` runs it on the 50 MHz oscillator, its clock the oscillator's inverse, with a refresh every 7.5 µs (8192 rows in 64 ms); Gowin EDA places it at about 100 MHz. In `nes_top` it runs on the NES's 37.1875 MHz system clock (`FREQ_MHZ=38`, rounded up for the timings), its clock that clock's inverse.

## UART

Use an external 3.3 V USB-serial adapter on PMOD0, the socket furthest from the HDMI port: FPGA TX on IO1 (V19) to the adapter's RX, the adapter's TX to IO3 (G22), and the adapter's ground to the GND pin of the same row (the 5th from the signal end; the 6th is 3.3 V). Sipeed numbers the socket's pins in two interleaved rows, IO0/2/4/6 and IO1/3/5/7.

The onboard BL616's UART (V14 from it, U15 to it) behaves as the Tang Nano 20K's does: at 2 Mbaud it echoed 32 bytes and then garbage, and soon after, the BL616 stopped answering JTAG until the board was unplugged.

## Known Gowin synthesis issue

GowinSynthesis (1.9.11.03) can merge small arrays that are written at the same address into one register RAM (`<name>_RAMREG_*` cells in its netlist), and it then read a pair of bit-selects at one index, `{a[i][b], c[i][b]}`, from the wrong bits of the merged word. The PPU's sprite line buffers (`sl_lo`, `sl_hi`) hit this: a transparent sprite pixel read as opaque, giving a false sprite-0 hit, and 8 timing-sensitive test ROMs and the save-state round trip failed on this board while passing in the sim. The PPU now takes the pixel by shifting the whole bytes (`video/ppu-2c02`). It was found by simulating Gowin's post-route netlist of the PPU (`set_option -gen_verilog_sim_netlist 1`) beside the RTL and comparing them every clock; if a design passes in the sim and fails on this board, that's the way to look. Prefer whole-word reads to paired bit-selects of arrays in RTL this board builds.

## Not working yet

- **User LEDs.** The two LEDs are on G11 and U12, the DONE and READY configuration pins. Gowin EDA's build lets them be used as GPIO (`use_done_as_gpio`, `use_ready_as_gpio`), but no design drives them yet.
- **DDR3:** needs a controller.

## Status

Built with Gowin EDA, the board tests give the other boards' results: echo's and the shell's CRCs; nestest's trace CRC; the save-state round trip; all 190 golden ROMs with MesenCE's frame CRCs, SUROM's 512 KB of PRG and MMC3's 256 KB of CHR included, with PRG ROM in the SDRAM module; and on HDMI, the 20K's video CRCs for `oam_read` and `full_palette`, with no clock waiting for memory. The sim runs the NES as this board does, with a model for each of the module's chips, with HDMI (`make_nes_x16_hdmi_sim`) and without (`make_nes_x16_sim`). The SDRAM module passes the harness's SDRAM test over its 64 MB with the sim's CRC32, and a distinct byte at every power-of-two address up to bit 25 reads back. The Atari 2600 (`console_a2600`) gives the Tang Nano 20K's results: every test cartridge's frame and sound CRCs, all twelve bank-switching ones included, and on HDMI the 20K's video and sound CRCs for `tia_colours`, `tia_playfield` and `tia_audio`, with no line late; the sim runs it as this board does (`make_a2600_console_sim`). It uses 10,355 LUTs and ALUs (8%), 3,873 registers and 300 of 340 block RAMs (the cartridge's 512 KB takes 228). `console_nes` uses 19,335 of 138,240 LUTs and ALUs (14%), 7,373 registers, 165 of 340 block RAMs and 1 of 12 PLLs, and Gowin EDA places its system clock at 38.7 MHz.
