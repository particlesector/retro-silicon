# Game Boy

The Game Boy (DMG) and the Game Boy Color (CGB): the SM83 (`cpu/sm83`) on the console's memory map, with its boot ROM, video RAM, work RAM, OAM, high RAM, timer, serial port, joypad, OAM DMA and interrupt registers, and the cartridge outside the core; and the cartridge's memory controllers (`gb_cart`).

Module `gameboy`. **In progress** (G8 of the rig's Game Boy roadmap; the Color, G7, is done): it draws its picture with the PPU (`gb_ppu`), a pixel at a time, and makes its sound with the APU ([`audio/apu-gb`](../../components/audio/apu-gb/)); `gb_cart` is the cartridge's MBC (none, MBC1 and its multicart wiring, MBC2, MBC3 with its clock, MBC5) and RAM. Built with `CGB` (the default), it is a Game Boy Color too, picked at reset (below). It runs from power-up through [SameBoy](https://github.com/LIJI32/SameBoy)'s open boot ROMs, and runs blargg's CPU, timing and sound ROMs, Mooneye's CPU, timer, interrupt, OAM DMA, PPU, MBC and Color tests, rtc3test, dmg-acid2 and cgb-acid2 to MesenCE's result and frame in the sim (below).

## Timing

The system steps one T-cycle per `ce` (4.194304 MHz on the console). An M-cycle is 4 of them, and the CPU takes one M-cycle per 4 T-cycles. Within an M-cycle, in order:

1. **The third T-cycle:** the timer's counter steps, along with TIMA's count and its reload.
2. **The fourth T-cycle:** the CPU's read sees everything as it stands then, the timer's step included.
3. **The M-cycle's end:** the CPU's write lands, with everything else that changes once an M-cycle (IF and IE, the serial port, the joypad, OAM DMA).

This order is what the hardware's tests measure. It is also what M-cycle emulators that pass them do: they step the timer, then make the access. With the timer stepping at the M-cycle's end instead, blargg's `instr_timing` measured opcodes one M-cycle off, and Mooneye's `tim00` and `intr_timing` failed.

An interrupt request lands in IF at the edge that makes it (`irq` outputs are combinational with their strobes), so a read of IF in the same M-cycle as a register's change sees both, at any clock ratio.

The CPU decides on an interrupt at an instruction's end, from IF as it is then. Halted, it sees a request made at an M-cycle's second or third T-cycle an M-cycle late, as SameBoy's DMG, which looks two T-cycles into each halted M-cycle, does; the Color (in normal speed) looks two T-cycles sooner, at each halted M-cycle's start, so it sees a request made at an M-cycle's first three T-cycles, or the last one before it, an M-cycle late (Mooneye's `vblank_stat_intr-C`, which passes on the Color and fails on the DMG). The M-cycle that sees a request is the dispatch's first, or the next opcode's fetch (`cpu/sm83`). Mooneye's HALT tests and its PPU interrupt tests (`intr_1_2_timing`, `vblank_stat_intr`, `hblank_ly_scx_timing`) need both: the VBlank request comes at an M-cycle's first T-cycle, mode 2's at its third, mode 0's anywhere.

`ce` must come at least 2 clocks apart. The read mux is registered, so a read's data is taken a clock before the M-cycle's last T-cycle ends: on any clock ratio, it is what the address held during that T-cycle.

## The memory map

| Address | Holds |
| --- | --- |
| `$0000-$00FF` | The boot ROM, until a non-zero write to `$FF50` (`boot_*` loads it); the Color's at `$0200-$08FF` too |
| `$0000-$7FFF`, `$A000-$BFFF` | The cartridge (`cart_*`) |
| `$8000-$9FFF` | Video RAM, 8 KB (the Color's: 2 banks, VBK) |
| `$C000-$DFFF` | Work RAM, 8 KB, echoed at `$E000-$FDFF` (the Color's: `$D000-$DFFF` one of 7 more 4 KB banks, SVBK) |
| `$FE00-$FE9F` | OAM; `$FEA0-$FEFF` read 0 |
| `$FF00-$FF7F` | I/O; unused registers read `$FF` |
| `$FF80-$FFFE` | High RAM |
| `$FFFF` | IE |

The cartridge and work RAM share the external bus; video RAM has its own.

## The parts

- **Timer (`gb_timer`):** DIV is the system counter's upper byte. TIMA counts the falling edges of TAC's enable ANDed with the counter bit TAC selects, so a write to DIV or TAC can add a count, as on the chip.
  - When TIMA overflows, it reads 0 for one M-cycle; it then takes TMA and requests the interrupt.
  - A write to TIMA during that M-cycle cancels both.
  - In the M-cycle after, a write to TIMA is lost, and a write to TMA goes to TIMA as well.
- **Serial port (`gb_serial`):** there is no cable, so each bit shifted in is 1.
  - The internal clock is SameBoy's model of the DMG's: a flip-flop that toggles on each falling edge of the system counter's bit 7, and shifts a bit when it falls (8,192 bits a second). It keeps the counter's phase from reset, not the SC write's.
  - A write to SC first gives the flip-flop its falling edge if it is high, then restarts the bit count.
  - With the external clock, a transfer never ends.
  - `ser_tx` is the byte in SB when SC is written with bits 7 and 0 set. This is the stream blargg's and Mooneye's ROMs report on, taken as MesenCE's test script takes it.
  - Why this model: with the clock on the counter's bit 8 instead, a byte of Mooneye's report sometimes got a running transfer's shift between its SB and SC writes. Mooneye's send loop gives up before a transfer's 8 bits are done, so its transfers overlap.
- **Joypad (`gb_joypad`):** P1 selects the direction keys (bit 4 low) or the buttons (bit 5 low). A selected line going low requests the joypad interrupt, and any selected key down wakes the CPU from STOP.
- **OAM DMA:** a write to `$FF46` starts a copy after one setup M-cycle: 160 bytes from `$XX00`, one an M-cycle, with `$E000` and above coming from work RAM. While it runs, a CPU access on the bus it reads from gets the DMA's byte, and a write there is lost. The Game Boy has two buses, video RAM and the rest (cartridge and work RAM); the Color has three, as MesenCE has them: video RAM, `$0000-$7FFF`, and `$A000-$FDFF` (work RAM on a bus of its own, which the DMA reads at its own address). So on the Color a DMA from work RAM leaves the ROM free, and games (Spirou, Snoopy Tennis, F.A. Premier League Stars 2001) wait for it in a loop in ROM, where on the Game Boy only high RAM works.
  - While the copy runs, the CPU reads OAM as `$FF` and can't write it.
  - A CPU access on the bus the DMA reads from gets the DMA's byte if it reads; if it writes, the write is lost.
  - A write to `$FF46` during a copy restarts it.
  - Mooneye's per-instruction timing tests (`call_timing`, `ret_timing` and the others) place a read one M-cycle either side of the copy's end, so they fix its length to the M-cycle.
- **PPU (`gb_ppu`):** the LCD's registers and its picture, dot by dot, as SameBoy models the DMG's (read for facts).
  - A line is 456 dots: mode 2 (the OAM scan, up to 10 objects) for 80, mode 3 for 172 or more, then mode 0. Lines 144-153 are VBlank; LY reads 153 for only the first dots of line 153, then 0. The first line after the LCD is turned on has no mode 2 and is 7 dots shorter.
  - Mode 3 runs the fetcher a step a dot into an 8-pixel background FIFO, and the object FIFO beside it, so its length comes out as on the chip: longer by SCX's low 3 bits, by the window's start and by each object's fetch.
  - The window starts where WX says on lines from WY's, with its own line counter. Objects are 8x8 or 8x16, flipped either way, the one with the lower X (then the lower OAM index) in front, behind the background's colours 1-3 when their priority bit says.
  - STAT's interrupt is requested when the OR of its enabled conditions rises, at the dots SameBoy updates it (mode 2's a dot before STAT shows it, except on line 0). Writing STAT on the DMG sets every condition for a dot first, which can request it.
  - Video RAM reads $FF and takes no writes in mode 3; OAM in modes 2 and 3 (on the DMG, from just before mode 2).
  - A write to SCX, SCY, LCDC, the palettes, LYC, WY, WX or STAT lands at the dot SameBoy's access conflicts put it at, which Mooneye's lcdon tests pin down. What the PPU draws with (the palettes, SCX, SCY, WX on the Game Boy, LCDC's bits but the LCD's switch) lands a dot before that against our M-cycle's phases, where Mealybug Tearoom's photos of the hardware have it: our pixels leave the FIFO a dot after SameBoy's against its own timing, so the PPU's state (STAT, its interrupts) keeps SameBoy's dots and these writes come a dot sooner (single speed; in double speed the Color's land as before). The LCD's first line starts at the same dot against the CPU on the Color at single speed as on the Game Boy, though the Color's LCDC write lands a dot later (the Game Boy's PPU waits a dot more as it turns on), so the Color's mid-line register writes land where Mealybug Tearoom's tests have them; in double speed it starts at the write's dot, as SameBoy's readings have it.
  - The Color's STAT differs from the Game Boy's at three edges (SameBoy's CGB-E, at single speed; `gb_test`'s probe ROM checks each against SameBoy's readings, `harness/golden/gb_cgb_stat_probe.txt`): while LY isn't compared, as each line starts, its LY=LYC bit keeps its value (the Game Boy's reads 0); after VBlank its mode reads 1 until line 0's mode 2 (the Game Boy's reads 0 for a dot between); and at line 153's start it compares LY with 153 two dots sooner and keeps 153 as LY turns 0, two dots later than the Game Boy's. Games poll STAT at these edges: Dragon Warrior Monsters 2 waits for mode 0 at VBlank's end. In double speed the Color takes the Game Boy's three edges, and a few of the probe's double-speed readings (line 0's mode 2, line 153, a mode 2 interrupt's dispatch) still come an M-cycle off SameBoy's: left for later.
  - Mode 3's finer points, each as SameBoy has it and Mealybug Tearoom's photos show: on the Game Boy, WX matching again with the window already on inserts a blank pixel (the Color's only at WX 0), and so does WX matching with the window triggered by WY but off in LCDC, as the fetcher waits to push on an empty FIFO (the Color has none; `win_off_pixel`); on the Color, the background's column is a position sooner except during an object's fetch, clearing TILE_SEL on the dot a bitplane is read from the old tile set reads the tile index instead (its CGB D differs; not modelled), and an object's high bitplane address takes LCDC's object size again two dots after the low one's.
  - It reads video RAM and OAM through ports of their own (OAM 16 bits wide).
- **Sound ([`audio/apu-gb`](../../components/audio/apu-gb/)):** the four channels and their registers, the DMG's or the Color's (its `cgb`).
  - Its 2 MHz ticks are each M-cycle's first and third T-cycles, so the CPU's reads (in the last) and writes (at its end) come between them.
  - Its frame sequencer steps as the system counter's bit 12 falls (`gb_timer`'s `fall12`, a DIV write's too), and its envelopes reload as the bit rises (`rise12`).
  - Its two mixes come out at each M-cycle's end (`aud_l`, `aud_r`).

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst`, `ce` | in | 1 | Clock, synchronous reset, one T-cycle |
| `cgb_hw_in` | in | 1 | The Game Boy Color (with `CGB`), steady from reset |
| `clearing` | out | 1 | Zeroing the RAM after a reset (below): `ce` must stay low until it ends |
| `dbl_speed` | out | 1 | The Color's double speed (KEY1), for counting blank frames as MesenCE does |
| `cart_addr` | out | 16 | The external bus's address: the CPU's, or a DMA's while it copies from there |
| `cart_rd` | out | 1 | This M-cycle (or the Color's DMA to video RAM) reads the cartridge |
| `cart_wr`, `cart_wdata` | out | 1, 8 | Write `cart_wdata` at `cart_addr` at this clock |
| `cart_rdata` | in | 8 | The cartridge's data, needed a clock before the M-cycle's last T-cycle ends |
| `boot_we`, `boot_addr`, `boot_wdata` | in | 1, 12, 8 | Write the boot ROM (256 bytes, the Color's 2,304) |
| `boot_q` | out | 8 | In reset, the boot ROM's byte at `boot_addr`, a clock later |
| `keys` | in | 8 | Keys down (1 pressed): Start, Select, B, A, down, up, left, right (bit 7 to 0) |
| `ser_tx`, `ser_tx_valid` | out | 8, 1 | A serial transfer of `ser_tx` starts |
| `m_end` | out | 1 | The clock that ends an M-cycle |
| `m_last` | out | 1 | The next T-cycle ends an access to the external bus: the M-cycle's last, or a byte of the Color's DMA to video RAM (from registers, for a hold on `ce`) |
| `cpu_sync`, `cpu_pc` | out | 1, 16 | This M-cycle fetches an opcode, at this PC (for traces) |
| `boot_on` | out | 1 | The boot ROM is mapped |
| `lcdc` | out | 8 | LCDC |
| `pix_we`, `pix_x`, `pix_y`, `pix_color` | out | 1, 8, 8, 15 | A pixel of the picture (a clock after its dot): the Color's 15-bit colour (red in bits 4-0), or the Game Boy's shade, 0 (white) to 3 |
| `frame_end` | out | 1 | VBlank starts: the frame is out |
| `frame_cut` | out | 1 | the LCD turns off outside VBlank: the frame is cut short |
| `aud_l`, `aud_r` | out | 10 | The APU's mixes, signed (-480 to 480), held from an M-cycle's end |

## The cartridge (`gb_cart`)

`gb_cart` is a cartridge's controller and RAM, the ROM outside it: it gives the address in the ROM a read of `$0000-$7FFF` reaches (`rom_addr`) and takes its byte back (`rom_q`) a clock later, as block RAM would, and keeps the RAM (up to 2^`RAM_AW` bytes) in block RAM. The host picks the controller from the cartridge's header, as MesenCE does (`rig::gb::cart_config()`): its type byte (`$147`) gives the MBC, the file's size (to a power of 2) the ROM's, `$149` the RAM's; an MBC1 with the boot logo at `$40104` as well as `$104` is a multicart (MBC1M). They're held while the system runs. Banks past the ROM's or RAM's size wrap around them.

| MBC | Banking |
| --- | --- |
| none | 32 KB of ROM; RAM, if the header has any, always there |
| MBC1 | RAM enable (`$0000`, `$xA`), BANK1 (`$2000`, 5 bits, 0 read as 1), BANK2 (`$4000`, 2 bits), mode (`$6000`): `$4000-$7FFF` is bank BANK2:BANK1; in mode 1, `$0000-$3FFF` is bank BANK2:0 and the RAM's bank is BANK2 |
| MBC1M | MBC1 wired for multicarts: BANK2 comes in at bank bit 4, BANK1's top bit left out (its 0-as-1 rule still on all 5) |
| MBC2 | From `$0000-$3FFF`: RAM enable with address bit 8 low, the bank (4 bits, 0 as 1) with it high. Its RAM is 512 4-bit cells, repeated through `$A000-$BFFF`, read with the top 4 bits set |
| MBC3 | RAM enable, the bank (`$2000`, 7 bits, 0 as 1; 8 on the MBC30, a cartridge with 64 KB of RAM or more), RAM banks 0-3 (0-7) or the clock's registers 8-`$C` (`$4000`), and the clock's latch (`$6000`) |
| MBC5 | RAM enable (exactly `$0A`), the bank's low 8 bits (`$2000`) and bit 8 (`$3000`), bank 0 allowed, RAM banks 0-15 (`$4000`; with rumble, 0-7, bit 3 the motor, which isn't here) |

Disabled RAM reads `$FF`. These are MesenCE's and SameBoy's behaviours, which agree with Pan Docs for all of it but two details no test here reaches: MBC1M's RAM bank in mode 1 (MesenCE BANK2, SameBoy 0; multicarts have no RAM) and MBC3's bank beyond 7 bits (MesenCE keeps 8, SameBoy 7, the same for every ROM up to 2 MB).

**MBC3's clock** (with `rtc`): seconds, minutes, hours and a 9-bit day count with halt and carry bits, counting emulated time as MesenCE does, so a board's clock is the sim's: a prescaler of 128 T-cycles (32,768 Hz from 4,194,304) that always counts, and a count of its ticks, held while the clock is halted, that adds a second at 32,768. A write to the seconds clears both. 59 seconds, 59 minutes and 23 hours carry; a register at its bits' limit wraps to 0 without a carry (seconds 63, say); past 511 days the count wraps and sets the carry bit, which stays until written. Only the registers' bits are kept (seconds and minutes 6, hours 5, the day's high byte bits 0, 6 and 7). Any write to `$6000-$7FFF` latches the registers, which the bus reads (as MesenCE and SameBoy both do; Pan Docs describes writing 0 then 1, which a game does either way). Neither the clock nor the RAM is cleared by `rst`: they'd keep a battery's charge, and the host loads both.

**The shell's port**, while the system is held in reset (when it has the RAM's port): the RAM's bytes, or the clock's 13 bytes (0-4 the registers, 5-9 the latched copy, 10-12 the tick count and prescaler), a clock after their address.

## The Game Boy Color

With `CGB` set (the default), `cgb_hw` makes the system a Game Boy Color from reset; with it clear the Color isn't built at all (the Tang Nano 20K's Game Boy, which hasn't the block RAM for it: G7), and the memories are the Game Boy's. What the Color adds:

- **Two modes.** Its boot ROM (SameBoy's, 2,304 bytes at `$0000-$00FF` and `$0200-$08FF`) reads the cartridge's header and writes KEY0 (`$FF4C`) before it unmaps itself: a Color game (header byte `$143` bit 7) runs in the Color's own mode, any other in its Game Boy mode, where the Color's registers mostly read `$FF` and the PPU colours the Game Boy's four shades through palettes the boot ROM chose. KEY0 can only be written while the boot ROM is mapped.
- **Memory.** 32 KB of work RAM, `$D000-$DFFF` banked by SVBK (`$FF70`, 0 picks 1), and 16 KB of video RAM in two banks (VBK, `$FF4F`), which the PPU reads together, 16 bits at a time: a tile's number from bank 0 and its attributes from bank 1 in one access, as SameBoy says the hardware does.
- **The PPU in the Color's mode.** A background or window tile's attributes give its palette (8), its bank, its flips and its priority over objects; an object's give its palette (8) and bank. LCDC bit 0 takes away the background's priority rather than the background, and objects overlap by OAM order (or by X, as the Game Boy's, with OPRI `$FF6C` bit 0, which the boot ROM sets for Game Boy games). The palettes' RAM (`$FF68-$FF6B`, 64 bytes each for the background and objects, with an index that can step itself) can't be reached in mode 3: reads give `$FF` and writes are lost, though the index still steps. Each pixel comes out as its 15-bit colour (`pix_color`) a clock after its dot, looked up in that RAM; on the Game Boy it is the shade.
- **The DMA to video RAM** (`$FF51-$FF55`). Written with bit 7 clear, a general DMA copies its blocks of 16 bytes at once; with bit 7 set, one block each HBlank (or one at once with the LCD off; HBlank is mode 0 that began as mode 3 ended, so the dot of mode 0 STAT shows as line 0 starts after VBlank, in double speed, isn't one, as MesenCE has it), until the length runs out or a write with bit 7 clear stops it. Each block stops the CPU: it starts at an M-cycle's end, takes 4 T-cycles to set up (2 in double speed), then 2 a byte, so the CPU's next M-cycle waits for it. The source is read on the external bus (`$8000-$9FFF` and `$E000` and above read `$FF`), and an HBlank block waits while the CPU is halted. This is MesenCE's model of it, but for starting at the M-cycle's end, where MesenCE stops the CPU mid-M-cycle.
- **Double speed** (KEY1, `$FF4D`, then STOP). The CPU, the timer, the serial port and OAM DMA run an M-cycle every 2 T-cycles (`phase` steps 1, 3), while the PPU, the APU and the DMA to video RAM keep their rate (dots); the APU's frame sequencer follows DIV's bit 13 instead of 12, so it keeps its rate too. The switch stops the CPU for 33,941 M-cycles at the old speed with DIV held at 0, as MesenCE times it (its own note says it's likely not exact; it matches its `speed_switch_timing_stat`), then the new speed starts at an M-cycle's end.
- **The APU** in its Color form (`audio/apu-gb`'s `cgb`), and PCM12 and PCM34 (`$FF76`, `$FF77`), the channels' levels.
- **Register writes' timing** follows SameBoy's map for the Color (its CGB-E): LCDC, SCX, SCY and WY land as the M-cycle ends (the Game Boy's land sooner), BGP, OBP0 and OBP1 2 T-cycles before, LYC and WX a T-cycle after; STAT's write has no all-ones T-cycle, but keeps its LYC interrupt's enable for one.
- **The registers** read and write as SameBoy has them where MesenCE differs (Mooneye's `boot_hwio-C` and `unused_hwio-C`, whose expected results come from SameBoy and the hardware): VBK, BCPS and OCPS read on the Color in either mode; SC's fast-clock bit, KEY1, SVBK, HDMA5 and RP only in its own mode; `$FF72`, `$FF73` and `$FF75` are plain registers (`$FF75` bits 7 and 3-0 read 1), `$FF74` only in the Color's mode.

Not here yet: the serial port's fast clock (SC bit 1 is kept and read back, but the clock's speed doesn't follow it), the infrared port beyond its register, the Color's timing differences in mode 3 (SameBoy's `cgb_wx_glitch`, the window's position on the Color, the tile-select glitch of LCDC bit 4), and the speed switch's exact length.

## gb_sys, under the test shell

`gb_sys` puts the Game Boy behind `debug/test-shell`, as `systems/atari-2600`'s `a2600_sys` does the 2600, so the host (`harness`'s `rig::gb`) can run a test ROM on a board or in the sim and check it over the link.

- **Cartridge:** `gb_cart`, set by register `50` from the cartridge's header, with room for 2^`CRAM_LOG2` bytes of RAM (default 32 KB, every Game Boy cartridge's but MBC5's largest) and 2^`ROM_LOG2` of ROM (up to 8 MB, the largest). The ROM is in block RAM, or with `ROM_EXT` in an outside memory on the `mem_*` port (`memory/sdram`'s byte port), from address 0.
- **ROM outside (`ROM_EXT`):** a ROM read's byte is fetched as its address comes and held. The M-cycle's last T-cycle waits (`clock_enable`'s hold) until the byte has been there a clock, since the console takes it a clock before that T-cycle ends (and OAM DMA at it). The address is there from the M-cycle's start, so a fetch has three T-cycles before anything waits: about 32 clocks at the boards' rates, against an SDRAM read's 8 or so, so a wait comes only when a refresh or a cache miss is in the way. Register `54` counts the clocks waited. The shell's accesses to the ROM take the port between fetches.
- **Wrappers:** `gb_sdram` is `gb_sys` with its ROM in an SDRAM (`memory/sdram`; the Tang Nano 20K's chip, or with the geometry parameters the Tang Console 138K's module). `gb_axi` has it behind an AXI slave, through a read cache (`memory/cache`, prefetching the next line after a miss) and `memory/axi-bridge`, as `systems/nes`'s `nes_axi` has the NES's: the PYNQ-Z2's DDR3 through HP0.
- **Boot ROM:** the host writes it, as it does the cartridge.
- **RAM at reset:** from reset's rising edge `gameboy` zeroes its work RAM, both video RAM banks, OAM, high RAM and the Color's palettes, a byte a clock through each memory's write port, for as many clocks as work RAM has bytes (32,768 with `CGB`, 8,192 without; `clearing` is high meanwhile). MesenCE powers up with its RAM zeroed, and the host runs game after game on one system: without it, a game started with the RAM the one before left. Every memory clears through its one write port, not all at once with `rst`, so that it can be a RAM: the palettes did clear with `rst`, and GowinSynthesis made them RAM anyway and dropped the clear without a warning (on the Tang Console 138K, Cubix and Spider-Man 2 differed from MesenCE only after another Color game). `gb_sys` doesn't run the system until it's done, and loading a cartridge holds the reset far longer anyway.
- **T-cycles:** at `T_NUM`/`T_DEN` of the clock (the console's 4.194304 MHz from 27 MHz is 65,536/421,875), only while it runs. It stops between T-cycles, so a run stopped and started again is the same as one left to run, on any board and in the sim.
- **Frames:** frames end as MesenCE ends them, so a frame's number means the same moment in both (and `gb_roms_test` counts them alike): as VBlank starts, as the LCD turns off outside VBlank (the PPU's `frame_cut`), and while the LCD is off, each time 70,226 dots have passed (70,225 at double speed) since power-up, since it went off or since the last such blank frame: MesenCE sends a blank frame once its count is more than 70,224 dots past the last frame, and its count steps 2 dots at a time at normal speed (1 at double speed). With 70,224, each blank frame came 2 dots before MesenCE's, and games that keep the LCD off for long (A Bug's Life, Cyber Tiger, Pooh and Tigger's Hunny Safari) ended 1 or 2 frames ahead. A count never runs on across the LCD going on: until G7 it did, and a game that turned the LCD off and on got an extra short frame each time, so Chris's Color games ended up 1 to 6 frames behind MesenCE at frame 600. The frame buffer holds each pixel's shade, or the Color's 15-bit colour, as the PPU last drew it (2 bits a pixel without `CGB`), and turns white as MesenCE's screen does: at a blank frame, and at the first frame to end after the LCD goes on (on the Color, only if it was off more than 5,000 dots); turning white takes about 23,000 clocks, between the PPU's writes. On the Game Boy (not the Color) a blank frame's white is the screen's blank white, lighter than shade 0, as MesenCE draws it: the frame buffer reads it as 31 (MesenCE's blue channel, which its CRC takes) until the PPU draws again, while HDMI shows shade 0; the first frame after the LCD goes on is shade 0, as MesenCE's is (Captain America and the Avengers turns the LCD on at its frame 600). MesenCE keeps two screens, so a frame cut short by the LCD going off shows the frame before last under the cut, where `gb_sys` shows the last.
- **Frame CRC:** when the system stops at a limit, it takes the CRC of the frame buffer (2 bytes a pixel, little-endian: the shade then 0, or the colour, as `gb_frames.py` takes MesenCE's), in about 23,000 clocks, before it runs again.
- **The Color:** with `CGB` (the default), register `50`'s bit 5 makes the system a Game Boy Color from the next reset, and register `2C`'s byte 2 reads 1.
- **Serial port:** every byte the game sends is kept (the last 2,048), with a count, for blargg's and Mooneye's reports.

| Address | What |
| --- | --- |
| `0x00000000-...` | The cartridge's ROM, 2^`ROM_LOG2` bytes (written and read only while the system is held in reset) |
| `0x01000000-0x0100007F` | Registers, below |
| `0x02000000-...` | The cartridge's RAM, 2^`CRAM_LOG2` bytes (written only while the system is held in reset; read then, or while it's stopped at a limit, from which it runs on: a battery game's save as it plays) |
| `0x03000000-0x03000FFF` | The boot ROM: 256 bytes, or the Color's 2,304 (written and read while held in reset) |
| `0x04000000-0x040007FF` | The serial port's bytes: byte n at n mod 2,048 |
| `0x05000000-0x0500B3FF` | The frame buffer: 2 bytes a pixel at 2 × (y × 160 + x), little-endian, a shade (0 white to 3) or the Color's colour |
| `0x06000000-0x0600000C` | The cartridge's clock (MBC3's): `gb_cart`'s 13 shell bytes (only while the system is held in reset) |

**HDMI (`VIDEO`, `gb_video`):** the picture at 720p, each pixel 5 display pixels each way (800 × 720, from x = 240), its shades grey (0 white, 1 `$AA`, 2 `$55`, 3 black) or the Color's colours corrected as SameBoy's "modern balanced" colour correction does (`gb_color`, from `tools/gb/color_table.py`: each channel through the Color LCD's curve, green mixed with some blue), and the sound: each mix through `audio/resampler` to 48 kHz (800 samples a frame of 17,556 M-cycles, against the 60 Hz display the system keeps pace with) and out in HDMI's audio packets, as the NES's. The video CRC counts the packets' symbols as 0, since which line's packet carries a sample depends on when it crossed to the pixel clock.

**Sound CRC:** register `30` is the CRC-32 of the APU's two mixes at each M-cycle's end since reset, each as a 16-bit little-endian word, left then right (`gb_roms_test` takes it the same way); with `VIDEO`, registers `48` and `4C` are the CRC and count of the sample pairs sent to HDMI.
- **What it shows:** the frame buffer itself, through a second port on the pixel clock, not a ring of lines as the 2600's and NES's: the Game Boy can turn its LCD off and draw nothing while its frames go on, and then the screen is the buffer as the PPU last left it, as the golden frames are.
- **Keeping pace:** with pacing on (register `34`), the system waits at each frame's end until the display asks for the next, at the start of its line 690. A frame starts as VBlank does, so its line y is whole 11 + y lines after the request; at 2% fast a line takes 4.8 display lines, so line 0 is whole 7 display lines before the display shows it, and each line after comes a little sooner than its turn.
- **Checks:** the display checks each line as it starts showing it: a count of lines whole, from the T-cycles, must have reached it, or it counts in `late`. A display frame whose system wasn't waiting at its request (stopped, or late) is drawn black, so the last lit picture a capture sees is the frame the system stopped on.
- **Video CRC:** as the 2600's: of the TMDS symbols of the display frame that shows frame `vcap_frame` + 1, with whether it showed it whole.

**Block RAM:** each memory's ports are written so Yosys maps them to the Gowin parts' block RAM at their size: with Yosys, an 8-bit memory whose writing port also reads takes twice as much, so the shell's port to the cartridge's ROM (in block RAM) only writes, and the shell reads the ROM and RAM through the system's port while the system is held in reset. The cartridge's RAM has one write port, the shell's in reset and the system's otherwise (two writers aren't mapped at all).

| Register | Bytes | Meaning |
| --- | --- | --- |
| `00` | 1 | Bit 0 run, bit 1 hold the system in reset (set at power-up) |
| `04` | 4 | Stop once this many T-cycles have run since reset; 0 never |
| `08` | 4 | T-cycles since reset (read-only) |
| `0C` | 1 | Status (read-only): bit 0 stopped at a limit, 1 running, 2 the frame CRC is taken, 3 taking it, 4 the video CRC asked for has come |
| `10` | 4 | Stop once this many frames have ended since reset; 0 never |
| `14` | 4 | Frames ended since reset (read-only) |
| `18` | 4 | The frame CRC (read-only) |
| `1C` | 4 | Frames ended when it was taken (read-only) |
| `20` | 4 | Bytes the serial port has sent since reset (read-only) |
| `24` | 1 | Keys down, as `keys` |
| `28` | 1 | LCDC (read-only) |
| `29` | 1 | Bit 0: the boot ROM is mapped (read-only) |
| `2A` | 2 | The CPU's PC (read-only) |
| `2C` | 1 | The room for the cartridge's ROM, log2 (read-only); byte 2 (`2E`): 1 if the Color is built |
| `2D` | 1 | ...and for its RAM (read-only) |
| `30` | 4 | The sound's CRC since reset (read-only) |
| `34` | 1 | With `VIDEO`: bit 0 keep pace with the display; write bit 1 to take the video CRC |
| `36` | 1 | Bit 0: the video CRC's display frame showed its frame whole (read-only) |
| `38` | 4 | The video CRC is of the display frame showing frame this + 1 |
| `3C` | 4 | The video CRC (read-only) |
| `40` | 2 | Display frames whose frame started on request (read-only) |
| `42` | 2 | Lines late (read-only) |
| `44` | 4 | Cartridge RAM's first 4 bytes as the system last wrote them, `$A000` in the low byte, `$FF` from reset (read-only): where blargg's newer ROMs report |
| `48` | 4 | With `VIDEO`: the CRC-32 of the sample pairs sent to HDMI, left then right, each 16-bit little-endian (read-only) |
| `4C` | 4 | With `VIDEO`: how many (read-only) |
| `50` | 3 | The cartridge: `gb_cart`'s `mbc` (bits 2-0: 0 none, 1 MBC1, 2 MBC1M, 3 MBC2, 4 MBC3, 5 MBC5), `rtc` (3), `rumble` (4), the Game Boy Color (5; with `CGB`), `rom_log2` (12-8) and `ram_log2` (20-16: 0 none, 9 MBC2's). 32 KB of ROM and no MBC or RAM at power-up |
| `54` | 4 | With `ROM_EXT`: clocks the system has waited on the ROM since reset (read-only) |
| `58` | 4 | T-cycles in which the system has written cartridge RAM since reset (read-only): a host keeping a battery game's saves sees it save when this changes |

## Tests

`gb_roms_test` runs the test ROMs of `testroms/manifest-gb.toml` that the system has the parts for, through SameBoy's DMG boot ROM, on `gameboy` with `gb_cart` (`sim/gb_cart_top.sv`; the test serves the ROM). These are the ROMs for the Game Boy (dmg) whose `needs` are among cpu, serial, timer, interrupts, boot, ppu, oam dma, apu, cart ram, mbc1, mbc2, mbc3, mbc5 and rtc. The cartridge is set from its header as the host sets it, its RAM starting as zeros, as MesenCE's does.

- **Results:** a ROM with a result of its own (blargg's text over the serial port or his code in cartridge RAM, or Mooneye's bytes) must end with MesenCE's (`harness/golden/gb_frames_crc32.txt`) within twice MesenCE's frames.
- **Frames:** its frame 30 frames after the result must be MesenCE's too, by CRC (2 bytes a pixel, the shade then 0, row by row, as `tools/mesen/gb_frames.py` takes it). A frame check (dmg-acid2) has its frame at the number the list gives. Frames end as MesenCE ends them (Frames, above).
- **Our own test ROMs:** `testroms/gb` (rgbds) has retro-silicon's own, for behaviour no public test covers, each from a game that showed it; its README lists them. Their golden frames are MesenCE's where SameBoy agrees.
- **The hardware's frames:** Mealybug Tearoom's tests come with the hardware's picture of each (a DMG-blob's, a CPU CGB C's and a CPU CGB D's), in the screen's own values; `tools/gb/mealybug.py` turns each into the frame the system takes and its CRC, which the manifest's `override` puts in place of MesenCE's where they differ. The tests the system draws as the hardware does are in the list (Status, below).
- **Expected fails:** MesenCE fails three Mooneye tests through SameBoy's boot ROM, which takes a different time from Nintendo's (`boot_div`, `boot_hwio` and `serial-boot_sclk_align`). The system must fail them too.
- **One frame not compared:** `serial-boot_sclk_align`'s fail screen shows counts that depend on the serial clock's phase from power-up, which nothing settles for this boot ROM. Ours differ from MesenCE's, and SameBoy's from ours by one (its DIV runs 4 T-cycles ahead).
- **Input:** a ROM's input script (the golden list's `input=`: the keys held from a frame on) is played at those frames' ends, as MesenCE's runner plays it; rtc3test's three suites are picked from its menu so.
- **Battery RAM:** a ROM with `again` runs twice, the second time from the cartridge RAM the first left (as MesenCE keeps a battery cartridge's), and its RAM at the end must have MesenCE's CRC (`savcrc=`); `sav=` powers it up with a file's.
- **Sound:** the sound's CRC to the checked frame (as register `30` takes it) must be `harness/golden/gb_audio_crc32.txt`'s, which `RS_GB_AUDIO_OUT=<file>` writes instead, after an intended change to the sound. MesenCE has no equivalent: the sound's second opinion is SameBoy's, M-cycle by M-cycle (`audio/apu-gb`'s README).
- **Options:** `RS_GB_ONLY=<id>,...` runs some of them, `RS_GB_JOBS=<n>` sets the threads (default up to 6), `RS_GB_TRACE=1` prints each opcode fetch and serial byte, `RS_GB_DUMP=<dir>` writes each ROM's checked frame there as a PGM, and `RS_GB_AUDIO_DUMP=<dir>` the mixes at each M-cycle as `<id>.mix`.

`harness`'s `harness_test` also runs the 20K's build with HDMI (`make_gb_hdmi_sim`): a receiver decodes every pixel clock as a sink does, and the display frame showing dmg-acid2's frame 300 and `ei_sequence`'s pass screen must show it, with the video CRC of `harness/golden/gb_hdmi_crc32.txt`, and every sample pair `gb_sys` sent must arrive in order; and a frame must take at most 98.7% of a display frame.

`gb_cart_test` checks `gb_cart` alone where Mooneye's MBC tests don't reach: MBC3's and MBC30's banks, MBC5's ninth bank bit and rumble, MBC1M, MBC2's address bit 8, and the clock: a second per 4,194,304 T-cycles from a write to the seconds, halting, the carries and the day count's overflow, the registers' bits and the latch.

`harness`'s `harness_test` runs some of them through `gb_sys`'s shell in the sim, as a board will (`rig::gb::rom_test`), each with its sound's CRC: `ei_sequence` (Mooneye's bytes), `instr_timing` (blargg's text), `dmg_sound-01` (blargg's code in cartridge RAM), dmg-acid2 (a frame) and `mbc2-ram` (run twice, its RAM's CRC MesenCE's); and an MBC5 cartridge on each board's build of the ROM's memory (block RAM, the 20K's SDRAM, the 138K's SDRAM module, the PYNQ-Z2's DDR3 through AXI and the read cache). It also runs ROMs in turn through one `gb_sys`, as a board runs ROM after ROM, each of which must end as if it ran alone: `dmg_sound-10` then `dmg_sound-11` (wave RAM, which powering the APU off leaves alone, clears on reset), and `mbc1-ram_64kb` then `dmg_sound-01` (the cartridge's setup comes from register 50 each time). The host steps the system a frame at a time, reading the serial port's bytes at each frame's end as `gb_roms_test` does, until the result; then it runs to the frame 30 on and checks the CRC the system took.

## Status

- **Passing:** 184 test ROMs end as they do in MesenCE (or the hardware, where the manifest overrides it), with its frame (one frame not compared, above), and with the sim's sound: 143 on the Game Boy and 41 on the Color.
  - blargg's `cpu_instrs` (all 11), `instr_timing`, `mem_timing` and `mem_timing-2` (all 3 of each), and `dmg_sound` (all 12).
  - Mooneye's CPU, interrupt, HALT, EI and DI tests, its per-instruction timing tests, all 13 of its timer tests, `bits` and `boot_regs`.
  - Mooneye's 12 PPU tests and 6 OAM DMA tests, `di_timing` and `halt_ime1_timing2`.
  - Mooneye's 28 MBC tests (MBC1, its multicart wiring, MBC2 and MBC5, up to 8 MB of ROM and 32 KB of RAM), two of them run twice with their RAM's CRC MesenCE's.
  - rtc3test's three suites (MBC3's clock), each pass and timing as MesenCE shows it.
  - dmg-acid2.
  - Mealybug Tearoom, frame for frame with the hardware's picture: 13 of its 24 tests on the Game Boy (`m2_win_en_toggle`, `m3_bgp_change`, `m3_bgp_change_sprites`, `m3_lcdc_win_en_change_multiple`, `m3_obp0_change`, `m3_scx_high_5_bits`, `m3_scx_low_3_bits`, `m3_window_timing`, `m3_window_timing_wx_0` and the four `m3_wx_` tests) and 21 of its 27 with a plain picture on the Color (all but those below; four of its pictures carry drawn notes and can't be compared). SameBoy, the second opinion, draws 15 and 20 of them.
  - Chris's Color games (G7's last check): `tools/games/golden_gb.py` in the rig writes, from MesenCE, a title frame (600) and a frame of play (1500) for each Color-only and dual game whose controller `gb_cart` has, and for a battery game the play check again from the RAM it left: 1,277 checks, of which 1,247 pass on the Tang Console 138K and the PYNQ-Z2, the same as in the sim. The 30 that fail, alike on both boards and in the sim, are timing, left for G8: 14 show MesenCE's picture exactly, 1 to 3 frames early or late; 15 show the same scene with an animation at another step (Pokémon Silver's Lugia, Mortal Kombat 4's fighters, Zelda DX's rain, Baby Felix's colour cycling), which no frame within 3 of MesenCE's matches; and in Scrabble's round trip the frame matches and only 4 bytes of its RAM differ, a value MesenCE itself saves differently on each run (its random seed).
  - On the Color: cgb-acid2; Mooneye's `boot_regs-cgb`, `boot_div-cgbABCDE`, `boot_hwio-C` and `unused_hwio-C` (these two with SameBoy's result, the hardware's, where MesenCE's is wrong) and `vblank_stat_intr-C`; blargg's `cgb_sound` (all 12) and `interrupt_time` (double speed).
- **Gaps:**
  - The sound's analogue side (`audio/apu-gb`'s README lists what it leaves out).
  - The Color's: its mode 3 timing where it differs from the Game Boy's, the serial port's fast clock, and the speed switch's exact length (above).
  - blargg's `oam_bug` ROMs: the OAM bug (`cpu/sm83`'s README).
  - MBC5's 128 KB of RAM on a board (the room is 32 KB; such a cartridge is skipped), HuC1, HuC3, MMM01, MBC6, MBC7 and the Camera.
  - Commercial games, beyond the test ROMs (G8). The rig's battery check on 45 battery games (each played to frame 1500, then powered up again with the RAM it left: its frame and RAM must be MesenCE's) passes 31 on every board, 14 of them with a save the game wrote. 14 fail alike on all three boards: 11 of those already differ from MesenCE on their title or play frame without a save (among them Pokémon Red and Blue, Link's Awakening, Super Mario Land 2, Wario Land and Metroid II), so the save isn't the cause; in Kirby's Dream Land 2, and likely Mario's Picross, the frames match and only a counter in the RAM differs (in Kirby's, 2 bytes: ours at frame 1500 is MesenCE's at 1499, a write landing a few T-cycles apart around VBlank's start). Which is right isn't settled: MesenCE is the reference, not the hardware. The plan for G8 is to run these games, with the same input scripts and saves, in SameBoy, the second opinion (`sameboy-frames` would need input scripts and cartridge RAM first): where SameBoy agrees with this core, MesenCE's line gets an override, as the test ROMs' do; where it agrees with MesenCE, SameBoy's trace finds the difference. A test with Nintendo's own boot ROM wouldn't settle it: MesenCE and this core both start from SameBoy's, so a different boot ROM shifts both alike, and there's no dump of the Game Boy's on hand.
  - Mealybug Tearoom's tests the system doesn't draw as the hardware does. On the Game Boy: `m3_lcdc_bg_en_change`, `m3_lcdc_bg_map_change`, `m3_lcdc_tile_sel_change`, `m3_lcdc_tile_sel_win_change`, `m3_lcdc_win_map_change` and `m3_scy_change`, which SameBoy draws as we do, the same pixels off; `m3_lcdc_obj_en_change` (2 pixels off), `m3_lcdc_obj_en_change_variant`, `m3_lcdc_obj_size_change` and `_scx` (objects turned off or resized as one is fetched, which SameBoy has nearer), and `m3_lcdc_win_en_change_multiple_wx`. On the Color: the four `m3_lcdc_tile_sel_` tests and `m3_scy_change2`, which SameBoy draws as we do (photos of a CPU CGB C, whose behaviour differs from SameBoy's CGB-E), and `m3_wx_4_change_sprites` (10 pixels, SameBoy's too).
  - The PPU's rarer edges: WX=166 on the Game Boy (SameBoy's quirks are modelled, unchecked against MesenCE; on the Color it's as any other WX, as both have it), writes to LCDC's object bit during an object's fetch, and OAM DMA's effect on the OAM scan beyond its bus.

## References

- Pan Docs (gbdev.io/pandocs): the memory map, I/O registers, timer, serial port, joypad and OAM DMA.
- Gekkio, *Game Boy: Complete Technical Reference*: the timer's overflow and reload.
- [SameBoy](https://github.com/LIJI32/SameBoy): the serial clock's flip-flop, the PPU's dot-by-dot timing (its `display.c`), the access conflicts on the PPU's registers and when a halted CPU sees an interrupt, read for facts; its traces, run beside the sim's, found where the timing parted.
- [dmg-acid2](https://github.com/mattcurrie/dmg-acid2) and [cgb-acid2](https://github.com/mattcurrie/cgb-acid2) (MIT): the PPU's rendering, against MesenCE's frame.
- MesenCE's Color (`Core/Gameboy`: `GbPpu`, `GbDmaController`, `GbMemoryManager`, `GbCpu`'s speed switch) and SameBoy's (`display.c`, `memory.c`, `sm83_cpu.c`'s conflict maps, its colour correction), read for facts.
- [Mooneye's test suite](https://github.com/Gekkio/mooneye-test-suite): what each test measures, read for facts.
- [rtc3test](https://github.com/aaaaaa123456789/rtc3test) (the Unlicense): MBC3's clock, its `tests.md`.
- MesenCE's and SameBoy's MBCs and MBC3 clock (`Core/Gameboy/Carts`, SameBoy's `memory.c` and `mbc.c`), read for facts.
