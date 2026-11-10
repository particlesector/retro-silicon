// SPDX-License-Identifier: Apache-2.0
#include "rig/sim_systems.hpp"

#include "Va2600_hdmi_sim.h"
#include "Va2600_sim.h"
#include "Vshell_ram_sim.h"
#include "Vnes_axi_sim.h"
#include "Vnes_ext_sim.h"
#include "Vnes_x16_hdmi_sim.h"
#include "Vnes_x16_sim.h"
#include "Vnes_hdmi_sim.h"
#include "Vnes_lean_sim.h"
#include "Vnes_sim.h"
#include "Vshell_axi_sim.h"
#include "Vshell_sdram_sim.h"
#include "Vshell_sdram_x16_sim.h"
#include "axi_memory_model.hpp"
#include "sdram_model.hpp"
#include "Vuart_echo_sim.h"

namespace rig {

namespace {

// Any Verilated top with clk, uart_rx and uart_tx ports.
template <class V> class Verilated : public SimModel {
public:
    bool tick(bool rx) override {
        m_.uart_rx = rx;
        m_.clk = 0;
        m_.eval();
        m_.clk = 1;
        m_.eval();
        return m_.uart_tx;
    }

private:
    V m_;
};

// A system with the SDRAM chip model on its pins. A timing violation throws,
// since the board would then fail in ways the sim can't predict.
template <class V> class WithSdram : public SimModel {
public:
    explicit WithSdram(double mhz = SimLink::kClockHz / 1e6) : sdram_(mhz) {}

    bool tick(bool rx) override {
        m_.uart_rx = rx;
        m_.clk = 0;
        m_.eval();
        m_.clk = 1;
        m_.eval();
        m_.sd_dq_i = sdram_.step({m_.sd_cs_n != 0, m_.sd_ras_n != 0, m_.sd_cas_n != 0, m_.sd_we_n != 0, m_.sd_ba,
                                  m_.sd_addr, m_.sd_dqm, m_.sd_dq_o, m_.sd_dq_oe != 0});
        if (!sdram_.errors.empty()) throw RigError("SDRAM model: " + sdram_.errors.front());
        return m_.uart_tx;
    }

private:
    V m_;
    SdramModel sdram_;
};

// Two 16-bit chips on the same pins (memory/sdram's RANKS=2), wired as on
// MiSTer's dual-chip boards: the second chip's CS is the first's inverted,
// and each chip's DQML and DQMH are A11 and A12. Only a chip with read data
// drives DQ; with none, chip 0's garbage stands for a floating bus.
class SdramPair {
public:
    SdramPair(double mhz, SdramModel::Geometry g) : sdram_{SdramModel(mhz, g), SdramModel(mhz, g)} {
        for (auto& c : sdram_) c.dqm_on_addr = true;
    }

    template <class V> void step(V& m) {
        uint32_t dq_i = 0;
        int driving = 0;
        for (int c = 0; c < 2; c++) {
            SdramPins p{(m.sd_cs_n != 0) != (c == 1), m.sd_ras_n != 0, m.sd_cas_n != 0, m.sd_we_n != 0,
                        m.sd_ba, m.sd_addr, m.sd_dqm, m.sd_dq_o, m.sd_dq_oe != 0};
            uint32_t v = sdram_[c].step(p);
            if (c == 0 || sdram_[c].drove) dq_i = v;
            driving += sdram_[c].drove;
            if (!sdram_[c].errors.empty())
                throw RigError("SDRAM model " + std::to_string(c) + ": " + sdram_[c].errors.front());
        }
        if (driving > 1) throw RigError("SDRAM models: both chips drive DQ");
        m.sd_dq_i = dq_i;
    }

private:
    SdramModel sdram_[2];
};

// The Tang Console 138K's SDRAM module: two W9825G6KH, 16M x 16.
constexpr SdramModel::Geometry kX16{2, 13, 9};

// A system with the 138K's SDRAM module on its pins.
template <class V> class WithSdramPair : public SimModel {
public:
    explicit WithSdramPair(double mhz) : sdram_(mhz, kX16) {}

    bool tick(bool rx) override {
        m_.uart_rx = rx;
        if constexpr (requires { m_.pclk; }) m_.pclk = 0;  // a system with a display: it isn't shown
        m_.clk = 0;
        m_.eval();
        m_.clk = 1;
        m_.eval();
        sdram_.step(m_);
        return m_.uart_tx;
    }

private:
    V m_;
    SdramPair sdram_;
};

// A system with an AXI master's ports (memory/axi-bridge's), with the AXI
// memory model on them: 8 MB from 0x10000000, as shell_axi's window.
template <class V> class WithAxiMemory : public SimModel {
public:
    bool tick(bool rx) override {
        m_.uart_rx = rx;
        m_.axi_ready = 1;
        if constexpr (requires { m_.pclk; }) m_.pclk = 0;  // a system with a display: it isn't shown
        mem_.drive(m_);
        m_.clk = 0;
        m_.eval();
        mem_.sample(m_);
        m_.clk = 1;
        m_.eval();
        mem_.after_edge();
        return m_.uart_tx;
    }

private:
    V m_;
    rs::AxiMemoryModel mem_{0x10000000, 8 << 20, 1};
};

// The NES as the Tang Nano 20K runs it with HDMI: the system at 46.40625 MHz
// with the SDRAM model, and the pixel clock at 74.25 MHz, both from one PLL,
// so 5 system clocks take as long as 8 pixel clocks. Time here is in units of
// 1/40 of that: a system clock every 8, a pixel clock every 5, rising together
// every 40. Each pixel clock's symbols go to `on_symbol`.
template <class V> class NesHdmiT : public SimModel {
public:
    explicit NesHdmiT(std::function<void(uint32_t)> on_symbol) : on_symbol_(std::move(on_symbol)) {}

    bool tick(bool rx) override {
        m_.uart_rx = rx;
        while (t_pix_ < t_sys_) pixel();
        bool both = t_pix_ == t_sys_;
        m_.clk = 0;
        if (both) m_.pclk = 0;
        m_.eval();
        m_.clk = 1;
        if (both) m_.pclk = 1;
        m_.eval();
        if (both) after_pixel();
        t_sys_ += 8;
        m_.sd_dq_i = sdram_.step({m_.sd_cs_n != 0, m_.sd_ras_n != 0, m_.sd_cas_n != 0, m_.sd_we_n != 0, m_.sd_ba,
                                  m_.sd_addr, m_.sd_dqm, m_.sd_dq_o, m_.sd_dq_oe != 0});
        if (!sdram_.errors.empty()) throw RigError("SDRAM model: " + sdram_.errors.front());
        return m_.uart_tx;
    }

private:
    void pixel() {
        m_.pclk = 0;
        m_.eval();
        m_.pclk = 1;
        m_.eval();
        after_pixel();
    }
    void after_pixel() {
        t_pix_ += 5;
        if (on_symbol_) on_symbol_(m_.tmds0 | m_.tmds1 << 10 | static_cast<uint32_t>(m_.tmds2) << 20);
    }

    V m_;
    SdramModel sdram_{kNesHdmiClockHz / 1e6};
    std::function<void(uint32_t)> on_symbol_;
    uint64_t t_sys_ = 0, t_pix_ = 0;
};

using NesHdmi = NesHdmiT<Vnes_hdmi_sim>;

// The 2600 with HDMI on the 20K's clocks: NesHdmiT's, without the SDRAM.
class A2600Hdmi : public SimModel {
public:
    explicit A2600Hdmi(std::function<void(uint32_t)> on_symbol) : on_symbol_(std::move(on_symbol)) {}

    bool tick(bool rx) override {
        m_.uart_rx = rx;
        while (t_pix_ < t_sys_) pixel();
        bool both = t_pix_ == t_sys_;
        m_.clk = 0;
        if (both) m_.pclk = 0;
        m_.eval();
        m_.clk = 1;
        if (both) m_.pclk = 1;
        m_.eval();
        if (both) after_pixel();
        t_sys_ += 8;
        return m_.uart_tx;
    }

private:
    void pixel() {
        m_.pclk = 0;
        m_.eval();
        m_.pclk = 1;
        m_.eval();
        after_pixel();
    }
    void after_pixel() {
        t_pix_ += 5;
        if (on_symbol_) on_symbol_(m_.tmds0 | m_.tmds1 << 10 | static_cast<uint32_t>(m_.tmds2) << 20);
    }

    Va2600_hdmi_sim m_;
    std::function<void(uint32_t)> on_symbol_;
    uint64_t t_sys_ = 0, t_pix_ = 0;
};
// The NES as the Tang Console 138K runs it with HDMI: its SDRAM module, the
// system clock at half the pixel clock, both from one PLL: a pixel clock on
// every system clock's edge, and one between.
class NesX16Hdmi : public SimModel {
public:
    explicit NesX16Hdmi(std::function<void(uint32_t)> on_symbol) : on_symbol_(std::move(on_symbol)) {}

    bool tick(bool rx) override {
        m_.uart_rx = rx;
        m_.clk = 0;
        m_.pclk = 0;
        m_.eval();
        m_.clk = 1;
        m_.pclk = 1;
        m_.eval();
        symbol();
        sdram_.step(m_);
        m_.pclk = 0;
        m_.eval();
        m_.pclk = 1;
        m_.eval();
        symbol();
        return m_.uart_tx;
    }

private:
    void symbol() {
        if (on_symbol_) on_symbol_(m_.tmds0 | m_.tmds1 << 10 | static_cast<uint32_t>(m_.tmds2) << 20);
    }

    Vnes_x16_hdmi_sim m_;
    SdramPair sdram_{kNesX16ClockHz / 1e6, kX16};
    std::function<void(uint32_t)> on_symbol_;
};

} // namespace

std::unique_ptr<SimLink> make_a2600_sim() {
    return std::make_unique<SimLink>(std::make_unique<Verilated<Va2600_sim>>());
}

std::unique_ptr<SimLink> make_a2600_hdmi_sim(std::function<void(uint32_t)> on_symbol) {
    return std::make_unique<SimLink>(std::make_unique<A2600Hdmi>(std::move(on_symbol)), kNesHdmiClksPerBit, 64,
                                     kNesHdmiClockHz);
}

std::unique_ptr<SimLink> make_uart_echo_sim() {
    return std::make_unique<SimLink>(std::make_unique<Verilated<Vuart_echo_sim>>());
}

std::unique_ptr<SimLink> make_shell_ram_sim() {
    return std::make_unique<SimLink>(std::make_unique<Verilated<Vshell_ram_sim>>());
}

std::unique_ptr<SimLink> make_shell_sdram_sim() {
    return std::make_unique<SimLink>(std::make_unique<WithSdram<Vshell_sdram_sim>>(), SimLink::kClksPerBit, 64);
}

std::unique_ptr<SimLink> make_shell_sdram_x16_sim() {
    return std::make_unique<SimLink>(std::make_unique<WithSdramPair<Vshell_sdram_x16_sim>>(50.0), 33, 64,
                                     50'000'000);
}

std::unique_ptr<SimLink> make_shell_axi_sim() {
    return std::make_unique<SimLink>(std::make_unique<WithAxiMemory<Vshell_axi_sim>>(), SimLink::kClksPerBit, 64);
}

std::unique_ptr<SimLink> make_nes_axi_sim() {
    return std::make_unique<SimLink>(std::make_unique<WithAxiMemory<Vnes_axi_sim>>(), 25, 64, 37'125'000);
}

std::unique_ptr<SimLink> make_nes_sim() { return std::make_unique<SimLink>(std::make_unique<WithSdram<Vnes_sim>>(), SimLink::kClksPerBit, 64); }

std::unique_ptr<SimLink> make_nes_ext_sim() {
    return std::make_unique<SimLink>(std::make_unique<WithSdram<Vnes_ext_sim>>(kNesHdmiClockHz / 1e6),
                                     kNesHdmiClksPerBit, 64, kNesHdmiClockHz);
}

std::unique_ptr<SimLink> make_nes_x16_sim() {
    return std::make_unique<SimLink>(std::make_unique<WithSdramPair<Vnes_x16_sim>>(kNesX16ClockHz / 1e6), 25, 64,
                                     kNesX16ClockHz);
}

std::unique_ptr<SimLink> make_nes_x16_hdmi_sim(std::function<void(uint32_t)> on_symbol) {
    return std::make_unique<SimLink>(std::make_unique<NesX16Hdmi>(std::move(on_symbol)), 25, 64, kNesX16ClockHz);
}

std::unique_ptr<SimLink> make_nes_hdmi_sim(std::function<void(uint32_t)> on_symbol) {
    return std::make_unique<SimLink>(std::make_unique<NesHdmi>(std::move(on_symbol)), kNesHdmiClksPerBit, 64,
                                     kNesHdmiClockHz);
}

std::unique_ptr<SimLink> make_nes_lean_sim(std::function<void(uint32_t)> on_symbol) {
    return std::make_unique<SimLink>(std::make_unique<NesHdmiT<Vnes_lean_sim>>(std::move(on_symbol)),
                                     kNesHdmiClksPerBit, 64, kNesHdmiClockHz);
}

} // namespace rig
