// SPDX-License-Identifier: Apache-2.0
#pragma once
// This repo's systems in Verilator, at SimLink::kClksPerBit (1.5 Mbaud), the
// same parameters as their Tang Nano 20K bitstreams. Link with rs_sim_link.
// The SDRAM systems' links add jitter to the host's timing (see SimLink).

#include <cstdint>
#include <functional>
#include <memory>

#include "rig/sim_link.hpp"

namespace rig {

std::unique_ptr<SimLink> make_uart_echo_sim();
std::unique_ptr<SimLink> make_shell_ram_sim();    // reports RS_SHELL_RAM_BUILD_ID
std::unique_ptr<SimLink> make_shell_sdram_sim();  // reports RS_SHELL_SDRAM_BUILD_ID
// shell-axi with an AXI memory model (memory/axi-bridge's) as its memory.
std::unique_ptr<SimLink> make_shell_axi_sim();    // reports RS_SHELL_AXI_BUILD_ID
std::unique_ptr<SimLink> make_nes_sim();          // reports RS_NES_BUILD_ID
// The NES as the Tang Console 138K runs it: block RAM for its memory, and a
// 50 MHz clock (33 clocks a bit). Reports RS_NES_BRAM_BUILD_ID.
std::unique_ptr<SimLink> make_nes_bram_sim();
// The NES as the Tang Nano 20K runs it: 46.40625 MHz (31 clocks a bit, the
// dot rate at 14/121), and its HDMI output on a 74.25 MHz pixel clock from
// the same PLL, keeping pace with the display. Each pixel clock's TMDS symbols
// go to on_symbol, as {red, green, blue} in bits 29-20, 19-10, 9-0. A frame
// takes about 2 million clock edges, so it's slower than make_nes_sim().
// Reports RS_NES_BUILD_ID.
inline constexpr unsigned kNesHdmiClockHz = 46'406'250;
inline constexpr int kNesHdmiClksPerBit = 31;
std::unique_ptr<SimLink> make_nes_hdmi_sim(std::function<void(uint32_t)> on_symbol = {});
// The Tang Console 138K's system with HDMI: block RAM, the system clock at
// half the pixel clock (37.1875 and 74.375 MHz), keeping pace with the display.
std::unique_ptr<SimLink> make_nes_bram_hdmi_sim(std::function<void(uint32_t)> on_symbol = {});
// The Tang Nano 20K's system as make_nes_hdmi_sim() has it, CHR ROM from the
// SDRAM included, but without the display: no pacing, and no pixel clock.
// Reports RS_NES_BUILD_ID.
std::unique_ptr<SimLink> make_nes_ext_sim();
// The NES as the PYNQ-Z2 runs it: PRG ROM in its DDR3 (here an AXI memory
// model that stalls at random, memory/axi-bridge's), 37.125 MHz (25 clocks a
// bit, dots at 35/242), 256 KB of CHR in block RAM, without the display.
// Reports RS_NES_AXI_BUILD_ID.
std::unique_ptr<SimLink> make_nes_axi_sim();

} // namespace rig
