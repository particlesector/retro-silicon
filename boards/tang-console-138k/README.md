# Tang Console 138K

Sipeed Tang Console with the Tang Mega 138K module: Gowin GW5AST-LV138PG484A (family `GW5AST-138C` in the open flow), a 50 MHz oscillator on pin V22, 1 GB of DDR3, two PMOD sockets, and an onboard BL616 for JTAG and a UART on the USB-C port marked MCU.

## Building

`build.sh` runs `../gowin/build.sh` (Yosys, nextpnr-himbaechel and gowin_pack) for this part at 50 MHz. A missed timing constraint fails the build.

```sh
boards/tang-console-138k/build.sh -t <top> -c <pins.cst> -o <outdir> [-f <MHz>] [-g NAME=VALUE]... <sources...>
```

The CMake build runs it for each design below; bitstreams land in `build/fpga/console_<name>/`. Load one into the FPGA's configuration SRAM, which is lost at power-off but doesn't wear the flash:

```sh
openFPGALoader -b tangconsole build/fpga/console_nes/nes_top.fs
```

## Designs

| Target | Design | Top | Notes |
| --- | --- | --- | --- |
| `console_uart_echo_bitstream` | `systems/uart-echo` | `rtl/echo_top.sv` | 1.515 Mbaud (`CLKS_PER_BIT=33`) |
| `console_shell_ram_bitstream` | `systems/shell-ram` | `rtl/shell_ram_top.sv` | As echo; `BUILD_ID` from the RTL's SHA-256, the same as the Tang Nano 20K's |
| `console_nes_bitstream` | `systems/nes` through `nes_bram` | `rtl/nes_top.sv` | As echo; 256 KB of block RAM for the memory; dots at 189/1760 of the clock |

All use `pins.cst`.

## Clock

The designs run on the 50 MHz oscillator directly. The open flow has no PLL sites for this part yet, so a design gets its rates from the clock with `common/clock-enable` and its parameters: 33 clocks a bit is 1.515 Mbaud, 1% fast of the host's 1.5 Mbaud and well within a UART's tolerance, and 189/1760 of 50 MHz is the NTSC dot rate exactly. Systems that stop and start only between their own cycles behave the same at any clock, so the NES gives the same CRCs here as on the Tang Nano 20K at 27 MHz.

## Memory

The DDR3 needs a controller the open flow doesn't have yet, so `systems/nes` runs on `nes_bram`: 256 KB of block RAM behind the same byte port as the Tang Nano 20K's SDRAM, enough for NROM. The shell's 8 MB memory window mirrors it.

## UART

Use an external 3.3 V USB-serial adapter on PMOD0, the socket furthest from the HDMI port: FPGA TX on IO1 (V19) to the adapter's RX, the adapter's TX to IO3 (G22), and the adapter's ground to the GND pin of the same row (the 5th from the signal end; the 6th is 3.3 V). Sipeed numbers the socket's pins in two interleaved rows, IO0/2/4/6 and IO1/3/5/7.

The onboard BL616's UART (V14 from it, U15 to it) behaves as the Tang Nano 20K's does: at 2 Mbaud it echoed 32 bytes and then garbage, and soon after, the BL616 stopped answering JTAG until the board was unplugged.

## Not working yet

- **User LEDs.** The two LEDs are on G11 and U12, the DONE and READY configuration pins. A blink built with `gowin_pack --done_as_gpio --ready_as_gpio` left both lit, so the designs here leave them alone.
- **PLLs:** the open flow's chip database has no PLL sites for this part yet, so nextpnr can't place one, and it has only one global clock buffer, so no design with two clocks places. Gowin's own tools (the free Education edition) drive the PLL: a UART echo on a 75 MHz clock from it (primitive `PLL`; `PLLA` is the GW5A-25's) passed the echo test. HDMI here will come from them.
- **DDR3:** needs a controller; HDMI isn't tried yet.

## Status

Every board test gives the Tang Nano 20K's result:
- `console_uart_echo`: the echo test's CRC; earlier, 4 MB echoed with no errors at 2 and 1 Mbaud.
- `console_shell_ram`: the shell test's CRC, with faults injected.
- `console_nes`: nestest's trace CRC; all 42 PPU test ROMs with MesenCE's frame CRCs; the save-state round trip; and states moved to and from the 20K mid-run, which finish with MesenCE's frames.

The sim runs the NES as this board does (`make_nes_bram_sim`). `console_nes` uses 12,600 LUTs (9%) and 157 of 340 block RAMs, with fmax 65 MHz against 50.
