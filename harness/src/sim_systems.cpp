// SPDX-License-Identifier: Apache-2.0
#include "rig/sim_systems.hpp"

#include "Vshell_ram_sim.h"
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

} // namespace rig
