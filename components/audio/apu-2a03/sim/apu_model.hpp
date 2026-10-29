// SPDX-License-Identifier: Apache-2.0
#pragma once
// A cycle model of the 2A03's APU (NTSC), the reference apu_2a03 is checked
// against. It is written the way MesenCE structures its APU, unit by unit,
// rather than as the RTL's next-state logic, so the two meet only in what
// they do. Each call to cycle() is one CPU cycle: its register access, then
// the next tick, as the RTL takes them on one `ce`.

#include <array>
#include <cstdint>

namespace apu_model {

inline constexpr std::array<uint8_t, 32> kLengths = {
    10, 254, 20, 2,  40, 4,  80, 6,  160, 8,  60, 10, 14, 12, 26, 14,
    12, 16,  24, 18, 48, 20, 96, 22, 192, 24, 72, 26, 16, 28, 32, 30};
inline constexpr std::array<uint16_t, 16> kNoisePeriods = {
    4, 8, 16, 32, 64, 96, 128, 160, 202, 254, 380, 508, 762, 1016, 2034, 4068};
inline constexpr std::array<uint16_t, 16> kDmcPeriods = {
    428, 380, 340, 320, 286, 254, 226, 214, 190, 160, 142, 128, 106, 84, 72, 54};
inline constexpr uint8_t kDuty[4][8] = {
    {0, 0, 0, 0, 0, 0, 0, 1},
    {0, 0, 0, 0, 0, 0, 1, 1},
    {0, 0, 0, 0, 1, 1, 1, 1},
    {1, 1, 1, 1, 1, 1, 0, 0}};

// A down counter that fires when it passes 0 and reloads from its period.
struct Timer {
    uint16_t period = 0, value = 0;
    bool step() {
        if (value == 0) {
            value = period;
            return true;
        }
        value--;
        return false;
    }
};

struct Length {
    bool enabled = false, halt = false, new_halt = false;
    uint8_t counter = 0, reload = 0, previous = 0;

    void load(uint8_t index) {
        if (enabled) {
            reload = kLengths[index];
            previous = counter;
        }
    }
    void enable(bool on) {
        enabled = on;
        if (!on) counter = 0;
    }
    void half_frame() {
        if (counter > 0 && !halt) counter--;
    }
    // After the frame counter's clocks: a load lands only if the clock left
    // the counter alone.
    void apply_reload() {
        if (reload) {
            if (counter == previous) counter = reload;
            reload = 0;
        }
        halt = new_halt;
    }
};

struct Envelope {
    bool constant = false, start = false;
    uint8_t volume = 0, counter = 0;
    int divider = 0;

    void quarter_frame(bool loop) {
        if (start) {
            start = false;
            counter = 15;
            divider = volume;
        } else if (--divider < 0) {
            divider = volume;
            if (counter > 0)
                counter--;
            else if (loop)
                counter = 15;
        }
    }
    uint8_t level() const { return constant ? volume : counter; }
};

struct Pulse {
    bool ch1;
    Timer timer;
    Length length;
    Envelope env;
    uint8_t duty = 0, pos = 0;
    uint16_t period = 0;
    bool sweep_on = false, negate = false, sweep_reload = false;
    uint8_t shift = 0, sweep_period = 0, divider = 0;

    explicit Pulse(bool first) : ch1(first) {}

    uint32_t target() const {
        uint32_t d = period >> shift;
        return negate ? period - d - (ch1 ? 1 : 0) : period + d;
    }
    bool muted() const { return period < 8 || (!negate && target() > 0x7FF); }
    void set_period(uint16_t p) {
        period = p;
        timer.period = static_cast<uint16_t>(p * 2 + 1);
    }
    void write(int reg, uint8_t v) {
        switch (reg) {
        case 0:
            duty = v >> 6;
            length.new_halt = v & 0x20;
            env.constant = v & 0x10;
            env.volume = v & 0x0F;
            break;
        case 1:
            sweep_on = v & 0x80;
            sweep_period = ((v >> 4) & 7) + 1;
            negate = v & 0x08;
            shift = v & 7;
            sweep_reload = true;
            break;
        case 2:
            set_period(static_cast<uint16_t>((period & 0x700) | v));
            break;
        default:
            set_period(static_cast<uint16_t>((period & 0xFF) | ((v & 7) << 8)));
            length.load(v >> 3);
            env.start = true;
            pos = 0;
            break;
        }
    }
    void half_frame() {
        length.half_frame();
        divider--;
        if (divider == 0) {
            if (shift > 0 && sweep_on && period >= 8 && target() <= 0x7FF)
                set_period(static_cast<uint16_t>(target()));
            divider = sweep_period;
        }
        if (sweep_reload) {
            divider = sweep_period;
            sweep_reload = false;
        }
    }
    void run() {
        if (timer.step()) pos = (pos - 1) & 7;
    }
    uint8_t out() const {
        return (!muted() && length.counter > 0 && kDuty[duty][pos]) ? env.level() : 0;
    }
};

struct Triangle {
    Timer timer;
    Length length;
    uint8_t pos = 0, linear = 0, linear_load = 0;
    bool linear_reload = false, control = false;

    void write(int reg, uint8_t v) {
        switch (reg) {
        case 0:
            control = v & 0x80;
            length.new_halt = control;
            linear_load = v & 0x7F;
            break;
        case 2:
            timer.period = static_cast<uint16_t>((timer.period & 0x700) | v);
            break;
        case 3:
            timer.period = static_cast<uint16_t>((timer.period & 0xFF) | ((v & 7) << 8));
            length.load(v >> 3);
            linear_reload = true;
            break;
        default:
            break;
        }
    }
    void quarter_frame() {
        if (linear_reload)
            linear = linear_load;
        else if (linear > 0)
            linear--;
        if (!control) linear_reload = false;
    }
    void run() {
        if (timer.step() && length.counter > 0 && linear > 0) pos = (pos + 1) & 31;
    }
    uint8_t out() const { return pos & 0x10 ? pos & 0x0F : 15 - pos; }
};

struct Noise {
    Timer timer;
    Length length;
    Envelope env;
    uint16_t shifter = 1;
    bool mode = false;

    void write(int reg, uint8_t v) {
        switch (reg) {
        case 0:
            length.new_halt = v & 0x20;
            env.constant = v & 0x10;
            env.volume = v & 0x0F;
            break;
        case 2:
            mode = v & 0x80;
            timer.period = kNoisePeriods[v & 0x0F] - 1;
            break;
        case 3:
            length.load(v >> 3);
            env.start = true;
            break;
        default:
            break;
        }
    }
    void run() {
        if (timer.step()) {
            uint16_t fb = (shifter ^ (shifter >> (mode ? 6 : 1))) & 1;
            shifter = static_cast<uint16_t>((shifter >> 1) | (fb << 14));
        }
    }
    uint8_t out() const { return (!(shifter & 1) && length.counter > 0) ? env.level() : 0; }
};

struct Dmc {
    Timer timer;
    bool irq_enabled = false, loop = false, irq = false;
    uint16_t sample_addr = 0xC000, sample_length = 1, address = 0, remaining = 0;
    uint8_t level = 0, buffer = 0, shifter = 0, bits = 8;
    bool empty = true, silent = true;
    int start_delay = 0, stop_delay = 0;
    bool request = false, cancel = false;  // this cycle's DMA start and abort

    Dmc() {
        timer.period = kDmcPeriods[0] - 1;
        timer.value = timer.period;
    }
    void restart() {
        address = sample_addr;
        remaining = sample_length;
    }
    void start_transfer() {
        if (empty && remaining > 0) request = true;
    }
    void write(int reg, uint8_t v) {
        switch (reg) {
        case 0:
            irq_enabled = v & 0x80;
            loop = v & 0x40;
            timer.period = kDmcPeriods[v & 0x0F] - 1;
            if (!irq_enabled) irq = false;
            break;
        case 1: level = v & 0x7F; break;
        case 2: sample_addr = static_cast<uint16_t>(0xC000 | (v << 6)); break;
        default: sample_length = static_cast<uint16_t>((v << 4) | 1); break;
        }
    }
    void enable(bool on, bool odd) {
        if (!on) {
            if (stop_delay == 0) stop_delay = odd ? 3 : 2;
        } else if (remaining == 0) {
            restart();
            start_delay = odd ? 3 : 2;
        }
    }
    void dma_byte(uint8_t v) {
        if (remaining > 0) {
            buffer = v;
            empty = false;
            address = address == 0xFFFF ? 0x8000 : address + 1;
            if (--remaining == 0) {
                if (loop)
                    restart();
                else if (irq_enabled)
                    irq = true;
            }
        }
        if (sample_length == 1 && !loop && bits == 1 && timer.value < 2) {
            shifter = buffer;
            empty = false;
            restart();
            stop_delay = 3;
        }
    }
    void process_delays() {
        if (stop_delay && --stop_delay == 0) {
            remaining = 0;
            cancel = true;
        }
        if (start_delay && --start_delay == 0) start_transfer();
    }
    void run() {
        if (!timer.step()) return;
        if (!silent) {
            if (shifter & 1) {
                if (level <= 125) level += 2;
            } else if (level >= 2) {
                level -= 2;
            }
            shifter >>= 1;
        }
        if (--bits == 0) {
            bits = 8;
            if (empty) {
                silent = true;
            } else {
                silent = false;
                shifter = buffer;
                empty = true;
                if (start_delay == 0) start_transfer();
            }
        }
    }
};

struct Inputs {
    bool odd = false;
    bool wr = false;
    bool rd_status = false;
    uint8_t addr = 0, wdata = 0;
    bool dma_done = false;
    uint8_t dma_data = 0;
};

class Apu {
public:
    Pulse pulse1{true}, pulse2{false};
    Triangle triangle;
    Noise noise;
    Dmc dmc;

    // Frame counter
    int mode = 0, step = 0, block = 0, new_value = -1, write_delay = 0, clear_wait = 0;
    uint32_t count = 0;
    bool inhibit = false, irq_flag = false, irq_line = false;

    // Power-on: as if $4017 had been written with 0, 3 cycles before.
    Apu() {
        new_value = 0;
        write_delay = 3;
    }

    uint8_t status() const {
        return static_cast<uint8_t>((pulse1.length.counter > 0) | (pulse2.length.counter > 0) << 1 |
                                    (triangle.length.counter > 0) << 2 | (noise.length.counter > 0) << 3 |
                                    (dmc.remaining > 0) << 4 | irq_flag << 6 | dmc.irq << 7);
    }
    bool irq() const { return irq_line || dmc.irq; }

    void cycle(const Inputs& in) {
        dmc.request = dmc.cancel = false;
        if (in.rd_status) {
            irq_line = false;
            if (irq_flag && clear_wait == 0) clear_wait = in.odd ? 2 : 1;
        }
        if (in.wr) write(in.addr, in.wdata, in.odd);
        if (in.dma_done) dmc.dma_byte(in.dma_data);
        tick();
    }

private:
    static constexpr uint32_t kSteps[2][6] = {
        {7457, 14913, 22371, 29828, 29829, 29830},
        {7457, 14913, 22371, 29829, 37281, 37282}};
    enum Clock { None, Quarter, Half };
    static constexpr Clock kClocks[6] = {Quarter, Half, Quarter, None, Half, None};  // both modes

    void write(uint8_t addr, uint8_t v, bool odd) {
        if (addr < 0x04)
            pulse1.write(addr & 3, v);
        else if (addr < 0x08)
            pulse2.write(addr & 3, v);
        else if (addr < 0x0C)
            triangle.write(addr & 3, v);
        else if (addr < 0x10)
            noise.write(addr & 3, v);
        else if (addr < 0x14)
            dmc.write(addr & 3, v);
        else if (addr == 0x15) {
            dmc.irq = false;
            pulse1.length.enable(v & 1);
            pulse2.length.enable(v & 2);
            triangle.length.enable(v & 4);
            noise.length.enable(v & 8);
            dmc.enable(v & 16, odd);
        } else if (addr == 0x17) {
            new_value = v;
            write_delay = odd ? 4 : 3;
            inhibit = v & 0x40;
            if (inhibit) {
                irq_line = irq_flag = false;
                clear_wait = 0;
            }
        }
    }

    void frame_clock(Clock c) {
        pulse1.env.quarter_frame(pulse1.length.halt);
        pulse2.env.quarter_frame(pulse2.length.halt);
        noise.env.quarter_frame(noise.length.halt);
        triangle.quarter_frame();
        if (c == Half) {
            pulse1.half_frame();
            pulse2.half_frame();
            triangle.length.half_frame();
            noise.length.half_frame();
        }
    }

    void run_frame_counter() {
        if (clear_wait && --clear_wait == 0) irq_flag = false;
        count++;
        if (count >= kSteps[mode][step]) {
            if (mode == 0 && step >= 3) {
                irq_flag = true;
                clear_wait = 0;
                if (!inhibit)
                    irq_line = true;
                else if (step == 5)
                    irq_flag = false;
            }
            if (kClocks[step] != None && !block) {
                frame_clock(kClocks[step]);
                block = 2;
            }
            if (++step == 6) step = 0, count = 0;
        }
        if (new_value >= 0 && --write_delay == 0) {
            mode = new_value & 0x80 ? 1 : 0;
            step = 0;
            count = 0;
            new_value = -1;
            if (mode && !block) {
                frame_clock(Half);
                block = 2;
            }
        }
        if (block > 0) block--;
    }

    void tick() {
        run_frame_counter();
        pulse1.length.apply_reload();
        pulse2.length.apply_reload();
        triangle.length.apply_reload();
        noise.length.apply_reload();
        dmc.process_delays();
        pulse1.run();
        pulse2.run();
        triangle.run();
        noise.run();
        dmc.run();
    }
};

} // namespace apu_model
