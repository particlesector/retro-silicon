// SPDX-License-Identifier: Apache-2.0
#pragma once
// This repo's systems in Verilator, at SimLink::kClksPerBit (1.5 Mbaud), the
// same parameters as their Tang Nano 20K bitstreams. Link with rs_sim_link.
// The SDRAM systems' links add jitter to the host's timing (see SimLink).

#include <cstdint>
#include <functional>
#include <memory>

#include "rig/sdram_test.hpp"
#include "rig/sim_link.hpp"

namespace rig {

std::unique_ptr<SimLink> make_uart_echo_sim();
std::unique_ptr<SimLink> make_shell_ram_sim();    // reports RS_SHELL_RAM_BUILD_ID
std::unique_ptr<SimLink> make_shell_sdram_sim();  // reports RS_SHELL_SDRAM_BUILD_ID
// shell-sdram as the Tang Console 138K builds it: its SDRAM module's two 16M x
// 16 chips (64 MB; the address bit 25 picks one), at 50 MHz and 33 clocks a
// bit. Reports RS_SHELL_SDRAM_BUILD_ID; its layout is kSdramX16Layout.
std::unique_ptr<SimLink> make_shell_sdram_x16_sim();
inline constexpr SdramLayout kSdramX16Layout{64u << 20, 8};
// shell-axi with an AXI memory model (memory/axi-bridge's) as its memory.
std::unique_ptr<SimLink> make_shell_axi_sim();    // reports RS_SHELL_AXI_BUILD_ID
std::unique_ptr<SimLink> make_nes_sim();          // reports RS_NES_BUILD_ID
// The NES as the Tang Console 138K runs it: PRG ROM in its SDRAM module (two
// 16M x 16 chips on one bus, a model each), 256 KB of CHR in block RAM, at
// 37.1875 MHz (25 clocks a bit, dots at 35/242), without the display.
// Reports RS_NES_BUILD_ID.
inline constexpr unsigned kNesX16ClockHz = 37'187'500;
std::unique_ptr<SimLink> make_nes_x16_sim();
// The NES as the Tang Nano 20K runs it: 46.40625 MHz (31 clocks a bit, the
// dot rate at 13/110, 2% fast, for room to keep pace), and its HDMI output on
// a 74.25 MHz pixel clock from the same PLL, keeping pace with the display. Each pixel clock's TMDS symbols
// go to on_symbol, as {red, green, blue} in bits 29-20, 19-10, 9-0. A frame
// takes about 2 million clock edges, so it's slower than make_nes_sim().
// Reports RS_NES_BUILD_ID.
inline constexpr unsigned kNesHdmiClockHz = 46'406'250;
inline constexpr int kNesHdmiClksPerBit = 31;
std::unique_ptr<SimLink> make_nes_hdmi_sim(std::function<void(uint32_t)> on_symbol = {});
// The Tang Nano 20K's lean build (systems/nes's DEBUG=0, its nes_lean
// bitstream) as make_nes_hdmi_sim() has the test build: writes only, and its
// picture and sound only on HDMI. Reports RS_NES_BUILD_ID.
std::unique_ptr<SimLink> make_nes_lean_sim(std::function<void(uint32_t)> on_symbol = {});
// The Tang Console 138K's system with HDMI: make_nes_x16_sim() with the pixel
// clock at twice the system clock (74.375 MHz), keeping pace with the display.
std::unique_ptr<SimLink> make_nes_x16_hdmi_sim(std::function<void(uint32_t)> on_symbol = {});
// The Tang Nano 20K's system as make_nes_hdmi_sim() has it, CHR ROM from the
// SDRAM included, but without the display: no pacing, and no pixel clock.
// Reports RS_NES_BUILD_ID.
std::unique_ptr<SimLink> make_nes_ext_sim();
// The NES as the PYNQ-Z2 runs it: PRG ROM in its DDR3 (here an AXI memory
// model that stalls at random, memory/axi-bridge's), 37.125 MHz (25 clocks a
// bit, dots at 9/61, 2% fast), 256 KB of CHR in block RAM, without the display.
// Reports RS_NES_AXI_BUILD_ID.
std::unique_ptr<SimLink> make_nes_axi_sim();
// The Atari 2600 (systems/atari-2600's a2600_sys) as the Tang Nano 20K runs it: 27 MHz, 18 clocks a
// bit, colour clocks at 35/264 of the clock (NTSC's 3.579545 MHz). Reports RS_A2600_BUILD_ID.
std::unique_ptr<SimLink> make_a2600_sim();
// The 2600 as the Tang Nano 20K runs it with HDMI (boards/tang-nano-20k/rtl/a2600_top.sv): the
// NES's clocks, 46.40625 MHz for the system (31 clocks a bit, colour clocks at 7/89, 2% fast) and
// 74.25 MHz pixels, the cartridge's ROM in the SDRAM (a2600_sdram, with the SDRAM model), and its
// display (a2600_video), keeping pace with it when asked. Each pixel clock's TMDS symbols go to
// on_symbol, as make_nes_hdmi_sim()'s do. Reports RS_A2600_BUILD_ID.
std::unique_ptr<SimLink> make_a2600_hdmi_sim(std::function<void(uint32_t)> on_symbol = {});
// The same without the display: no pacing, and no pixel clock.
std::unique_ptr<SimLink> make_a2600_ext_sim();

} // namespace rig
