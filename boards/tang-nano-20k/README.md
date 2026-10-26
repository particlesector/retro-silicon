# Tang Nano 20K

Sipeed Tang Nano 20K: Gowin GW2AR-LV18QN88C8/I7 (family GW2A-18C), 27 MHz oscillator on pin 4, six LEDs on pins 15–20 (active low), 8 MB of SDRAM inside the FPGA package, an HDMI connector on pins 33–40, and an onboard BL616 USB bridge for JTAG and a UART.

## Building

`build.sh` runs `../gowin/build.sh` (Yosys, nextpnr-himbaechel and gowin_pack, with OSS CAD Suite on PATH) for this part at 27 MHz. A missed timing constraint fails the build.

```sh
boards/tang-nano-20k/build.sh -t <top> -c <pins.cst> -o <outdir> [-f <MHz>] [-k NET=MHz]... [-g NAME=VALUE]... <sources...>
```

`-f` constrains the oscillator's clock; `-k` constrains a clock the design makes itself, from a PLL or divider, whose rate nextpnr doesn't work out.

The CMake build runs it for each design below when nextpnr-himbaechel is on PATH (turn that off with `-DRS_BITSTREAMS=OFF`); bitstreams land in `build/fpga/<name>/`.

Load a bitstream into the FPGA's configuration SRAM, which is lost at power-off but doesn't wear the flash:

```sh
openFPGALoader -b tangnano20k build/fpga/uart_echo/uart_echo.fs
```

## Designs

| Target | Design | Pins file | Notes |
| --- | --- | --- | --- |
| `uart_echo_bitstream` | `systems/uart-echo` | `uart_echo.cst` | 1.5 Mbaud (`CLKS_PER_BIT=18`) |
| `shell_ram_bitstream` | `systems/shell-ram` | `uart_echo.cst` | 1.5 Mbaud; `BUILD_ID` from the RTL's SHA-256 |
| `shell_sdram_bitstream` | `systems/shell-sdram`, through `rtl/shell_sdram_top.sv` | `uart_echo.cst` | As shell-ram, with the SDRAM |
| `nes_bitstream` | `systems/nes` on the SDRAM (`nes_sdram`), through `rtl/nes_top.sv` | `nes.cst` | 46.40625 MHz from the PLL; HDMI at 720p (below) |

## SDRAM

The GW2AR-18's 2M × 32 SDRAM is wired inside the package to ports the toolchain recognises by name (`O_sdram_clk`, `O_sdram_addr`, `IO_sdram_dq` and so on), so a board top just declares them; they need no constraints. `rtl/*_top.sv` wrap a system that uses `memory/sdram`, drive the SDRAM's clock with the inverse of the system clock, and turn the controller's split data bus into the tristate `IO_sdram_dq`. nextpnr warns that it routes the clock to that inverter through general routing; at 27 MHz the half-cycle margin covers the extra delay, and a 1 MB and an 8 MB write-and-check pass.

## Clocks and HDMI

The NES makes its clocks with the one rPLL from the 27 MHz oscillator: 371.25 MHz (x55/4), the HDMI serializers' clock. `CLKDIV` divides that by 5 for the 74.25 MHz pixel clock, and the PLL's divided output, 371.25 / 8 = 46.40625 MHz, is the system clock. `DQCE` holds the system clock off until the PLL locks, so the SDRAM's power-up wait counts real time. The SDRAM's clock is the inverse of the PLL's output before `DQCE`, not after: with the open flow, an inverted `DQCE` output on `O_sdram_clk` leaves the SDRAM dead (every read is 0xFF, at 27 MHz as at 46), while either half alone works. At 46.40625 MHz a UART bit is 31 clocks (1.497 Mbaud, 0.2% slow of 1.5) and the PPU's dot rate is exactly NTSC's at 14/121 of the clock. The system clock leaves room for the SDRAM to serve the PPU's CHR reads too, when mappers need them.

`../gowin/rtl/tmds_phy.sv` serializes each 10-bit TMDS symbol (`OSER10`) onto the connector's pairs as true LVDS (`TLVDS_OBUF`, `LVDS25`). Every HDMI pair here is a true-LVDS pair, where the open flow doesn't allow emulated LVDS, and true LVDS outputs set their bank's I/O standard for the whole bank. So nothing else can share banks 4 and 5 with HDMI: the UART pins moved from 41/42, in bank 4, to 71/72.

## UART

Use an external 3.3 V USB-serial adapter for anything beyond short exchanges: FPGA pin 72 (TX) to the adapter's RX, the adapter's TX to FPGA pin 71 (RX), and a ground. Pins 71 and 72 are in bank 1, away from the HDMI pairs' banks. The onboard BL616's UART drops data in host-to-FPGA bursts over about 65 bytes, and corrupts sustained FPGA-to-host streams, after which it stops passing data until the board is power-cycled. See [docs/decisions/0002-uart-link.md](../../docs/decisions/0002-uart-link.md).
