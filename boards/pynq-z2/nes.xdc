# SPDX-License-Identifier: Apache-2.0
# PYNQ-Z2 (XC7Z020-1CLG400C) pins for the NES with HDMI, from TUL's PYNQ-Z2 v1.0 master XDC.

# 125 MHz from the Ethernet PHY; it runs without the processor booting.
set_property -dict { PACKAGE_PIN H16 IOSTANDARD LVCMOS33 } [get_ports { clk }]
create_clock -period 8.000 -name clk [get_ports { clk }]

# The data link: a 3.3 V USB-serial adapter on PMOD A's JA1P and JA1N.
set_property -dict { PACKAGE_PIN Y18 IOSTANDARD LVCMOS33 } [get_ports { uart_tx }]
set_property -dict { PACKAGE_PIN Y19 IOSTANDARD LVCMOS33 PULLUP true } [get_ports { uart_rx }]

# LD0-LD3, active high.
set_property -dict { PACKAGE_PIN R14 IOSTANDARD LVCMOS33 } [get_ports { led[0] }]
set_property -dict { PACKAGE_PIN P14 IOSTANDARD LVCMOS33 } [get_ports { led[1] }]
set_property -dict { PACKAGE_PIN N16 IOSTANDARD LVCMOS33 } [get_ports { led[2] }]
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 } [get_ports { led[3] }]

# HDMI OUT, driven as TMDS by OSERDESE2 and OBUFDS.
set_property -dict { PACKAGE_PIN L16 IOSTANDARD TMDS_33 } [get_ports { tmds_clk_p }]
set_property -dict { PACKAGE_PIN L17 IOSTANDARD TMDS_33 } [get_ports { tmds_clk_n }]
set_property -dict { PACKAGE_PIN K17 IOSTANDARD TMDS_33 } [get_ports { tmds_d_p[0] }]
set_property -dict { PACKAGE_PIN K18 IOSTANDARD TMDS_33 } [get_ports { tmds_d_n[0] }]
set_property -dict { PACKAGE_PIN K19 IOSTANDARD TMDS_33 } [get_ports { tmds_d_p[1] }]
set_property -dict { PACKAGE_PIN J19 IOSTANDARD TMDS_33 } [get_ports { tmds_d_n[1] }]
set_property -dict { PACKAGE_PIN J18 IOSTANDARD TMDS_33 } [get_ports { tmds_d_p[2] }]
set_property -dict { PACKAGE_PIN H18 IOSTANDARD TMDS_33 } [get_ports { tmds_d_n[2] }]
