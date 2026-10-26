# 0002: Test link over an external USB-serial adapter at 1.5 Mbaud

**Status:** accepted, October 2026

**Context:** the board tests talk to the FPGA over a UART. On the Tang Nano 20K, the onboard BL616 USB bridge handles short exchanges, but it drops data in host-to-FPGA bursts longer than about 65 bytes, corrupts sustained FPGA-to-host streams at every rate tried, and then stops passing data until it's power-cycled. The serv project reports the same: use an external adapter for large transfers.

**Decision:** the BL616 is used only for JTAG. The test link is an external 3.3 V USB-serial adapter on header pins 41 (FPGA RX) and 42 (FPGA TX), at 1.5 Mbaud (27 MHz / 18, an exact divider). An FT232RL clone corrupts data at 3 Mbaud but passed 100 MB echoed at 1.5 Mbaud with no errors.

**Consequences:** the rate is the `CLKS_PER_BIT` parameter, so a faster adapter (an FT232H, say) only needs a rebuild. The harness's sim backend models the same rate, so sim and board runs compare directly.

**Update (Oct 25, 2026, milestone 6):** the adapter moved to header pins 71 (FPGA RX) and 72 (FPGA TX), in bank 1. HDMI's pairs are all true-LVDS pairs; their outputs set the I/O standard of banks 4 and 5, which pins 41 and 42 share, and the UART stopped working there.
