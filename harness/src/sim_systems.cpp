// SPDX-License-Identifier: Apache-2.0
#include "rig/sim_systems.hpp"

#include "Vshell_ram_sim.h"
#include "Vnes_bram_sim.h"
#include "Vnes_hdmi_sim.h"
#include "Vnes_sim.h"
#include "Vshell_sdram_sim.h"
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
    SdramModel sdram_{SimLink::kClockHz / 1e6};
};

// The NES as the Tang Nano 20K runs it with HDMI: the system at 46.40625 MHz
// with the SDRAM model, and the pixel clock at 74.25 MHz, both from one PLL,
// so 5 system clocks take as long as 8 pixel clocks. Time here is in units of
// 1/40 of that: a system clock every 8, a pixel clock every 5, rising together
// every 40. Each pixel clock's symbols go to `on_symbol`.
class NesHdmi : public SimModel {
public:
    explicit NesHdmi(std::function<void(uint32_t)> on_symbol) : on_symbol_(std::move(on_symbol)) {}

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

    Vnes_hdmi_sim m_;
    SdramModel sdram_{kNesHdmiClockHz / 1e6};
    std::function<void(uint32_t)> on_symbol_;
    uint64_t t_sys_ = 0, t_pix_ = 0;
};

} // namespace

std::unique_ptr<SimLink> make_uart_echo_sim() {
    return std::make_unique<SimLink>(std::make_unique<Verilated<Vuart_echo_sim>>());
}

std::unique_ptr<SimLink> make_shell_ram_sim() {
    return std::make_unique<SimLink>(std::make_unique<Verilated<Vshell_ram_sim>>());
}

std::unique_ptr<SimLink> make_shell_sdram_sim() {
    return std::make_unique<SimLink>(std::make_unique<WithSdram<Vshell_sdram_sim>>(), SimLink::kClksPerBit, 64);
}

std::unique_ptr<SimLink> make_nes_sim() { return std::make_unique<SimLink>(std::make_unique<WithSdram<Vnes_sim>>(), SimLink::kClksPerBit, 64); }

std::unique_ptr<SimLink> make_nes_bram_sim() {
    return std::make_unique<SimLink>(std::make_unique<Verilated<Vnes_bram_sim>>(), 33, 64, 50'000'000);
}

std::unique_ptr<SimLink> make_nes_hdmi_sim(std::function<void(uint32_t)> on_symbol) {
    return std::make_unique<SimLink>(std::make_unique<NesHdmi>(std::move(on_symbol)), kNesHdmiClksPerBit, 64,
                                     kNesHdmiClockHz);
}

} // namespace rig
