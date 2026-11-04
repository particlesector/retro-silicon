// SPDX-License-Identifier: Apache-2.0
// The NES's clocks (rtl/nes_top.sv), from the 50 MHz oscillator through the
// PLL, as generated clocks of it: Gowin EDA then times every path between
// them with the clock tree's real delays, setup and hold. (Its own derivation
// of the PLL's outputs ignores the multiplier's fraction.) VCO 743.75 MHz =
// 50 x 119/8. The system clock is the one past its gate (DCE).
create_generated_clock -name fclk -source [get_ports {clk}] -master_clock clk -multiply_by 119 -divide_by 16 [get_pins {u_pll/CLKOUT0}]
create_generated_clock -name sclk_pll -source [get_ports {clk}] -master_clock clk -multiply_by 119 -divide_by 160 [get_pins {u_pll/CLKOUT2}]
create_generated_clock -name sclk -source [get_pins {u_pll/CLKOUT2}] -master_clock sclk_pll -divide_by 1 [get_pins {u_gate/CLKOUT}]
create_generated_clock -name pclk -source [get_pins {u_pll/CLKOUT0}] -master_clock fclk -divide_by 5 [get_pins {u_div/CLKOUT}]
