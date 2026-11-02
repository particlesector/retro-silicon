# Tang Console 138K

Sipeed Tang Console with the Tang Mega 138K module: Gowin GW5AST-LV138PG484A (`GW5AST-138C`), a 50 MHz oscillator on pin V22, 1 GB of DDR3, two PMOD sockets, and an onboard BL616 for JTAG and a UART on the USB-C port marked MCU.

## Building

The board builds with Gowin EDA, Gowin's own tools (decided Nov 1): the open flow has no PLL for this part, and with one the NES runs on its PLL's clocks with HDMI. `build.sh` runs `../gowin-eda/build.sh` for this part, with the 50 MHz oscillator constrained; `RS_GOWIN_EDA` must name Gowin EDA's IDE directory (the one holding `bin/gw_sh`). Gowin EDA's free Education edition is enough, and it's closed and behind a login, so each user downloads it; it's never part of this library. The CMake build makes this board's bitstreams only when `RS_GOWIN_EDA` is set. Gowin's timing analysis covers setup and hold, and a miss fails the build.

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
| `console_nes_bitstream` | `systems/nes` through `nes_bram` | `rtl/nes_top.sv` | Its PLL's clocks (below), HDMI at 720p; `nes.cst` |

## Clocks

Echo and the shell run on the 50 MHz oscillator. The NES's clocks come from the GW5A's `PLL`: its VCO at 1487.5 MHz (50 x 29.75, its multiplier taking eighths) gives 371.875 MHz for the serializers (/4) and 37.1875 MHz for the system (/40), gated by `DCE` (the GW5A's `DQCE`) until the PLL locks, and `CLKDIV` makes the 74.375 MHz pixel clock (371.875 / 5) in phase with the serializers. The HDMI clocks are 0.17% above the Tang Nano 20K's, well inside HDMI's tolerance, and the system clock is half the pixel clock, as on the PYNQ-Z2: 25 clocks a bit (1.4875 Mbaud) and dots at 35/242 of the clock, so the NES keeps pace with its display as there. Gowin EDA places the NES at about 41 MHz (with `timing_driven`, `place_option=2` and `route_option=2`; 33 MHz without), short of the 20K's 46.4.

## HDMI

The HDMI connector's pairs, as emulated LVDS (`tmds_phy`'s `ELVDS_OBUF`, `LVCMOS33D`): clock G15/G16, data 0 J14/H14, data 1 J15/H15, data 2 K17/J17.

## Memory

The DDR3 needs a controller, so `systems/nes` runs on `nes_bram`: 256 KB of PRG ROM and 128 KB of CHR in block RAM. The shell's 8 MB memory window mirrors it.

## UART

Use an external 3.3 V USB-serial adapter on PMOD0, the socket furthest from the HDMI port: FPGA TX on IO1 (V19) to the adapter's RX, the adapter's TX to IO3 (G22), and the adapter's ground to the GND pin of the same row (the 5th from the signal end; the 6th is 3.3 V). Sipeed numbers the socket's pins in two interleaved rows, IO0/2/4/6 and IO1/3/5/7.

The onboard BL616's UART (V14 from it, U15 to it) behaves as the Tang Nano 20K's does: at 2 Mbaud it echoed 32 bytes and then garbage, and soon after, the BL616 stopped answering JTAG until the board was unplugged.

## Not working yet

- **User LEDs.** The two LEDs are on G11 and U12, the DONE and READY configuration pins. Gowin EDA's build lets them be used as GPIO (`use_done_as_gpio`, `use_ready_as_gpio`), but no design drives them yet.
- **DDR3:** needs a controller.

## Status

Built with Gowin EDA, the board tests give the Tang Nano 20K's results: echo's CRC; nestest's trace CRC; every golden ROM that fits (186 of 188: SUROM's 512 KB of PRG and MMC3's 256 KB of CHR don't) with MesenCE's frame CRCs; and on HDMI, the 20K's video CRCs for `oam_read` and `full_palette`. The sim runs the NES with HDMI as this board does (`make_nes_bram_hdmi_sim`), and at the open flow's 50 MHz rates (`make_nes_bram_sim`). `console_nes` uses 18,753 of 138,240 LUTs (14%), 7,290 registers, 229 of 340 block RAMs and 1 of 12 PLLs.
