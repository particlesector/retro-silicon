// SPDX-License-Identifier: Apache-2.0
// stella-frames: golden frame CRCs for the Atari 2600 from Stella, headless.
//
// usage: stella-frames --rom FILE --frames N[,N...] [--core SO] [--seed S] [--dump DIR] [--out FILE]
//
// Runs the cartridge from power-up in Stella's libretro core (Stella 7.0's src/os/libretro, built with
// make; --core, default the one CMake's RS_STELLA_DIR names), and for each frame N (N frames run, the
// first is 1) writes "<N> <crc32>", the zlib CRC-32 of the frame as TIA colour values: 160 x 228 bytes,
// line by line, each the colour register's value (bit 0 clear), as a NTSC TV shows it in Stella's window
// (from the 23rd line after VSYNC ends). --dump also writes <N>.tia (those bytes) and <N>.ppm (as
// Stella's standard palette shows them).
//
// The core gives RGB. Its palette is learnt at start-up by running a built-in colour-bar cartridge (our
// own, below) whose picture line x shows colour 2x, so no palette table is kept here. That runs in a
// child process: the core can't load a second game after unloading one (its video buffer goes stale).
//
// Stella starts RAM, the CPU's registers and the RIOT timer at random, from the clock. The test
// cartridges never read any of them before setting them, so their frames are the same from any start.
// A core patched to start them at 0 can take a seed for the rest: --seed sets RS_STELLA_SEED for it
// (default 1); an unpatched core ignores it.

#include <dlfcn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <zlib.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "libretro.h"

#ifndef RS_STELLA_CORE
#define RS_STELLA_CORE ""
#endif

namespace {

constexpr unsigned kWidth = 160;
constexpr unsigned kHeight = 228;

// Colour bars, assembled from this (ca65), at $F000 with the vectors at $FFFA:
//   reset: sei / cld / ldx #$FF / txs
//   frame: lda #2 / sta VSYNC / sta WSYNC x3 / lda #0 / sta VSYNC
//          lda #2 / sta VBLANK / ldx #37 / vb: sta WSYNC / dex / bne vb / lda #0 / sta VBLANK
//          ldx #0 / pic: txa / asl a / sta COLUBK / sta WSYNC / inx / cpx #192 / bne pic
//          lda #2 / sta VBLANK / ldx #30 / os: sta WSYNC / dex / bne os / jmp frame
const uint8_t kBars[] = {
    0x78, 0xd8, 0xa2, 0xff, 0x9a, 0xa9, 0x02, 0x85, 0x00, 0x85, 0x02, 0x85, 0x02, 0x85, 0x02, 0xa9,
    0x00, 0x85, 0x00, 0xa9, 0x02, 0x85, 0x01, 0xa2, 0x25, 0x85, 0x02, 0xca, 0xd0, 0xfb, 0xa9, 0x00,
    0x85, 0x01, 0xa2, 0x00, 0x8a, 0x0a, 0x85, 0x09, 0x85, 0x02, 0xe8, 0xe0, 0xc0, 0xd0, 0xf5, 0xa9,
    0x02, 0x85, 0x01, 0xa2, 0x1e, 0x85, 0x02, 0xca, 0xd0, 0xfb, 0x4c, 0x05, 0xf0,
};
// The bars' picture line 0 is this line of Stella's window: VBLANK ends 37 lines after VSYNC, the
// window starts 23 lines after it.
constexpr unsigned kBarsFirstLine = 37 - 23;

std::vector<uint32_t> g_frame;
bool g_got_frame = false;

bool environment(unsigned cmd, void* data) {
    switch (cmd) {
    case RETRO_ENVIRONMENT_GET_VARIABLE: {
        auto* var = static_cast<retro_variable*>(data);
        static const std::map<std::string, const char*> kOptions = {
            {"stella_console", "ntsc"},       {"stella_palette", "standard"},
            {"stella_filter", "disabled"},    {"stella_crop_hoverscan", "disabled"},
            {"stella_phosphor", "off"},
        };
        auto it = kOptions.find(var->key);
        var->value = it == kOptions.end() ? nullptr : it->second;
        return it != kOptions.end();
    }
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
        return *static_cast<const retro_pixel_format*>(data) == RETRO_PIXEL_FORMAT_XRGB8888;
    default:
        return false;
    }
}

void video(const void* data, unsigned width, unsigned height, size_t pitch) {
    if (!data) return;
    if (width != kWidth || height != kHeight) {
        std::fprintf(stderr, "stella-frames: the core gave a %ux%u frame, not %ux%u\n", width, height, kWidth,
                     kHeight);
        std::exit(2);
    }
    g_frame.resize(width * height);
    for (unsigned y = 0; y < height; y++)
        std::memcpy(&g_frame[y * width], static_cast<const char*>(data) + y * pitch, width * 4);
    g_got_frame = true;
}

size_t audio_batch(const int16_t*, size_t frames) { return frames; }
void audio_sample(int16_t, int16_t) {}
void input_poll() {}
int16_t input_state(unsigned, unsigned, unsigned, unsigned) { return 0; }

struct Core {
    void* lib = nullptr;
    bool (*load_game)(const retro_game_info*) = nullptr;
    void (*run)() = nullptr;

    template <class T> T sym(const char* name) {
        void* p = dlsym(lib, name);
        if (!p) {
            std::fprintf(stderr, "stella-frames: the core has no %s\n", name);
            std::exit(2);
        }
        return reinterpret_cast<T>(p);
    }

    explicit Core(const std::string& path) {
        lib = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
        if (!lib) {
            std::fprintf(stderr, "stella-frames: %s\n", dlerror());
            std::exit(2);
        }
        sym<void (*)(retro_environment_t)>("retro_set_environment")(environment);
        sym<void (*)(retro_video_refresh_t)>("retro_set_video_refresh")(video);
        sym<void (*)(retro_audio_sample_batch_t)>("retro_set_audio_sample_batch")(audio_batch);
        sym<void (*)(retro_audio_sample_t)>("retro_set_audio_sample")(audio_sample);
        sym<void (*)(retro_input_poll_t)>("retro_set_input_poll")(input_poll);
        sym<void (*)(retro_input_state_t)>("retro_set_input_state")(input_state);
        sym<void (*)()>("retro_init")();
        load_game = sym<bool (*)(const retro_game_info*)>("retro_load_game");
        run = sym<void (*)()>("retro_run");
    }

    void load(const std::string& name, const std::vector<uint8_t>& rom) {
        retro_game_info info{name.c_str(), rom.data(), rom.size(), nullptr};
        if (!load_game(&info)) {
            std::fprintf(stderr, "stella-frames: the core didn't load %s\n", name.c_str());
            std::exit(2);
        }
    }

    void frame() {
        g_got_frame = false;
        run();
        if (!g_got_frame) {
            std::fprintf(stderr, "stella-frames: the core gave no frame\n");
            std::exit(2);
        }
    }
};

// RGB to colour value, from the bars.
std::map<uint32_t, uint8_t> learn_palette(Core& core) {
    std::vector<uint8_t> rom(4096, 0xff);
    std::memcpy(rom.data(), kBars, sizeof kBars);
    for (int v = 0; v < 3; v++) {  // NMI, reset and IRQ vectors: $F000
        rom[0xffa + 2 * v] = 0x00;
        rom[0xffb + 2 * v] = 0xf0;
    }
    core.load("bars.bin", rom);
    for (int i = 0; i < 10; i++) core.frame();
    std::map<uint32_t, uint8_t> palette;
    for (unsigned x = 0; x < 128; x++) {
        const unsigned line = kBarsFirstLine + x;
        const uint32_t rgb = g_frame[line * kWidth] & 0xffffff;
        for (unsigned i = 0; i < kWidth; i++) {
            if ((g_frame[line * kWidth + i] & 0xffffff) != rgb) {
                std::fprintf(stderr, "stella-frames: the colour bars' line %u isn't one colour\n", x);
                std::exit(2);
            }
        }
        palette[rgb] = static_cast<uint8_t>(2 * x);
    }
    if (palette.size() != 128) {
        std::fprintf(stderr, "stella-frames: the palette has %zu distinct colours, not 128\n", palette.size());
        std::exit(2);
    }
    return palette;
}

// learn_palette in a child process, with its own core.
std::map<uint32_t, uint8_t> learn_palette_apart(const std::string& core_path) {
    int fds[2];
    if (pipe(fds) != 0) {
        std::perror("pipe");
        std::exit(2);
    }
    const pid_t pid = fork();
    if (pid == 0) {
        close(fds[0]);
        Core core(core_path);
        for (const auto& [rgb, value] : learn_palette(core)) {
            const uint32_t entry = rgb << 8 | value;
            if (write(fds[1], &entry, sizeof entry) != sizeof entry) _exit(2);
        }
        _exit(0);
    }
    close(fds[1]);
    std::map<uint32_t, uint8_t> palette;
    uint32_t entry;
    while (read(fds[0], &entry, sizeof entry) == sizeof entry) palette[entry >> 8] = static_cast<uint8_t>(entry);
    close(fds[0]);
    int status = 0;
    waitpid(pid, &status, 0);
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0 || palette.size() != 128) {
        std::fprintf(stderr, "stella-frames: learning the palette failed\n");
        std::exit(2);
    }
    return palette;
}

std::vector<uint8_t> read_file(const std::string& path) {
    FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) {
        std::perror(path.c_str());
        std::exit(2);
    }
    std::vector<uint8_t> data;
    uint8_t buf[65536];
    size_t n;
    while ((n = std::fread(buf, 1, sizeof buf, f)) > 0) data.insert(data.end(), buf, buf + n);
    std::fclose(f);
    return data;
}

[[noreturn]] void usage() {
    std::fprintf(stderr,
                 "usage: stella-frames --rom FILE --frames N[,N...] [--core SO] [--seed S] [--dump DIR] "
                 "[--out FILE]\n");
    std::exit(2);
}

}  // namespace

int main(int argc, char** argv) {
    std::string core_path = RS_STELLA_CORE;
    std::string rom_path, dump_dir, out_path, seed = "1";
    std::set<unsigned> frames;
    for (int i = 1; i < argc; i++) {
        const std::string arg = argv[i];
        if (i + 1 >= argc) usage();
        const std::string val = argv[++i];
        if (arg == "--rom") rom_path = val;
        else if (arg == "--core") core_path = val;
        else if (arg == "--seed") seed = val;
        else if (arg == "--dump") dump_dir = val;
        else if (arg == "--out") out_path = val;
        else if (arg == "--frames") {
            for (size_t p = 0; p < val.size();) {
                size_t q = val.find(',', p);
                if (q == std::string::npos) q = val.size();
                const unsigned long n = std::strtoul(val.substr(p, q - p).c_str(), nullptr, 10);
                if (n == 0) usage();
                frames.insert(static_cast<unsigned>(n));
                p = q + 1;
            }
        } else usage();
    }
    if (rom_path.empty() || frames.empty() || core_path.empty()) usage();
    setenv("RS_STELLA_SEED", seed.c_str(), 1);

    const auto palette = learn_palette_apart(core_path);
    Core core(core_path);
    const std::string name = rom_path.substr(rom_path.find_last_of('/') + 1);
    core.load(name, read_file(rom_path));

    FILE* out = out_path.empty() ? stdout : std::fopen(out_path.c_str(), "w");
    if (!out) {
        std::perror(out_path.c_str());
        return 2;
    }
    std::vector<uint8_t> tia(kWidth * kHeight);
    for (unsigned n = 1; n <= *frames.rbegin(); n++) {
        core.frame();
        if (!frames.count(n)) continue;
        for (size_t i = 0; i < tia.size(); i++) {
            auto it = palette.find(g_frame[i] & 0xffffff);
            if (it == palette.end()) {
                std::fprintf(stderr, "stella-frames: frame %u has a colour not in the palette\n", n);
                return 2;
            }
            tia[i] = it->second;
        }
        const uLong crc = crc32(crc32(0, nullptr, 0), tia.data(), static_cast<uInt>(tia.size()));
        std::fprintf(out, "%u %08lx\n", n, crc);
        if (!dump_dir.empty()) {
            const std::string base = dump_dir + "/" + std::to_string(n);
            if (FILE* f = std::fopen((base + ".tia").c_str(), "wb")) {
                std::fwrite(tia.data(), 1, tia.size(), f);
                std::fclose(f);
            }
            if (FILE* f = std::fopen((base + ".ppm").c_str(), "wb")) {
                std::fprintf(f, "P6 %u %u 255\n", kWidth, kHeight);
                for (uint32_t p : g_frame) {
                    const uint8_t rgb[3] = {uint8_t(p >> 16), uint8_t(p >> 8), uint8_t(p)};
                    std::fwrite(rgb, 1, 3, f);
                }
                std::fclose(f);
            }
        }
    }
    if (out != stdout) std::fclose(out);
    return 0;
}
