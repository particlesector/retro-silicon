# Game Boy

The Game Boy (DMG): the SM83 (`cpu/sm83`) on the console's memory map, with its boot ROM, video RAM, work RAM, OAM, high RAM, timer, serial port, joypad, OAM DMA and interrupt registers, and the cartridge outside the core.

Module `gameboy`. **In progress** (G2 of the rig's Game Boy roadmap): the LCD and the sound are, until G3 and G5, their registers only (`gb_lcd_timing`, `gb_apu_regs`), so nothing is drawn or heard yet; the cartridge is a plain 32 KB ROM in the tests, with no MBC. It runs from power-up through [SameBoy](https://github.com/LIJI32/SameBoy)'s open DMG boot ROM, and runs blargg's CPU and timing ROMs and Mooneye's CPU, timer, interrupt and OAM DMA timing tests to MesenCE's result in the sim (below).

## Timing

The system steps one T-cycle per `ce` (4.194304 MHz on the console). An M-cycle is 4 of them, and the CPU takes one M-cycle per 4 T-cycles. Within an M-cycle, in order:

1. **The third T-cycle:** the timer's counter steps, along with TIMA's count and its reload.
2. **The fourth T-cycle:** the CPU's read sees everything as it stands then, the timer's step included.
3. **The M-cycle's end:** the CPU's write lands, with everything else that changes once an M-cycle (IF and IE, the serial port, the joypad, OAM DMA).

This order is what the hardware's tests measure. It is also what M-cycle emulators that pass them do: they step the timer, then make the access. With the timer stepping at the M-cycle's end instead, blargg's `instr_timing` measured opcodes one M-cycle off, and Mooneye's `tim00` and `intr_timing` failed.

An interrupt request lands in IF at the edge that makes it (`irq` outputs are combinational with their strobes), so a read of IF in the same M-cycle as a register's change sees both, at any clock ratio.

`ce` must come at least 2 clocks apart. The read mux is registered, so a read's data is taken a clock before the M-cycle's last T-cycle ends: on any clock ratio, it is what the address held during that T-cycle.

## The memory map

| Address | Holds |
| --- | --- |
| `$0000-$00FF` | The boot ROM, until a non-zero write to `$FF50` (`boot_*` loads it) |
| `$0000-$7FFF`, `$A000-$BFFF` | The cartridge (`cart_*`) |
| `$8000-$9FFF` | Video RAM, 8 KB |
| `$C000-$DFFF` | Work RAM, 8 KB, echoed at `$E000-$FDFF` |
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
- **OAM DMA:** a write to `$FF46` starts a copy after one setup M-cycle: 160 bytes from `$XX00`, one an M-cycle, with `$E000` and above coming from work RAM.
  - While the copy runs, the CPU reads OAM as `$FF` and can't write it.
  - A CPU access on the bus the DMA reads from gets the DMA's byte if it reads; if it writes, the write is lost.
  - A write to `$FF46` during a copy restarts it.
  - Mooneye's per-instruction timing tests (`call_timing`, `ret_timing` and the others) place a read one M-cycle either side of the copy's end, so they fix its length to the M-cycle.
- **LCD, for now (`gb_lcd_timing`):** its registers, and the line timing only.
  - With the LCD on, a line takes 456 T-cycles: mode 2 for 80, mode 3 for 172 (its length doesn't vary yet), then mode 0. Lines 144-153 are VBlank, and LY reaching 144 requests the VBlank interrupt.
  - STAT's interrupt is requested when the OR of its enabled conditions rises.
  - The boot ROM and the test ROMs' libraries wait on LY and VBlank, so they need this much. G3's PPU replaces it.
- **Sound, for now (`gb_apu_regs`):** its registers only.
  - They read back with the DMG's unreadable bits set, and NR52's power bit clears them.
  - The wave RAM reads and writes.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst`, `ce` | in | 1 | Clock, synchronous reset, one T-cycle |
| `cart_addr` | out | 16 | The external bus's address: the CPU's, or the DMA's while it copies from there |
| `cart_rd` | out | 1 | This M-cycle reads the cartridge |
| `cart_wr`, `cart_wdata` | out | 1, 8 | Write `cart_wdata` at `cart_addr` at this clock |
| `cart_rdata` | in | 8 | The cartridge's data, needed a clock before the M-cycle's last T-cycle ends |
| `boot_we`, `boot_addr`, `boot_wdata` | in | 1, 8, 8 | Write the boot ROM |
| `keys` | in | 8 | Keys down (1 pressed): Start, Select, B, A, down, up, left, right (bit 7 to 0) |
| `ser_tx`, `ser_tx_valid` | out | 8, 1 | A serial transfer of `ser_tx` starts |
| `m_end` | out | 1 | The clock that ends an M-cycle |
| `cpu_sync`, `cpu_pc` | out | 1, 16 | This M-cycle fetches an opcode, at this PC (for traces) |
| `boot_on` | out | 1 | The boot ROM is mapped |
| `lcdc` | out | 8 | LCDC |

## Tests

`gb_roms_test` runs the test ROMs of `testroms/manifest-gb.toml` that the system has the parts for, through SameBoy's DMG boot ROM. These are the ROMs for the Game Boy (dmg) whose `needs` are among cpu, serial, timer, interrupts and boot, and whose result comes over the serial port: blargg's text or Mooneye's bytes. Each must end with MesenCE's result (`harness/golden/gb_frames_crc32.txt`) within twice MesenCE's frames.

- **Expected fails:** MesenCE fails three Mooneye tests through SameBoy's boot ROM, which takes a different time from Nintendo's (`boot_div`, `boot_hwio` and `serial-boot_sclk_align`). The system must fail them too.
- **Options:** `RS_GB_ONLY=<id>,...` runs some of them, `RS_GB_JOBS=<n>` sets the threads (default up to 6), and `RS_GB_TRACE=1` prints each opcode fetch and serial byte.

## Status

- **Passing:** 61 test ROMs end as they do in MesenCE.
  - blargg's `cpu_instrs` (all 11), `instr_timing` and `mem_timing` (all 3).
  - Mooneye's CPU, interrupt, HALT, EI and DI tests, its per-instruction timing tests, all 13 of its timer tests, and `bits` and `boot_regs`.
- **Gaps:**
  - The PPU (G3): nothing is drawn yet.
    - Mooneye's `di_timing-GS` and `halt_ime1_timing2-GS` time themselves against LY, so they wait for it.
    - So do its OAM DMA tests, whose `needs` include the PPU.
  - The sound (G5).
  - MBCs and cartridge RAM (G6).
  - The OAM bug: the address on the CPU's internal M-cycles (`cpu/sm83`'s README).
  - The test shell's system and the harness's Game Boy console, which come with G3's frames.

## References

- Pan Docs (gbdev.io/pandocs): the memory map, I/O registers, timer, serial port, joypad and OAM DMA.
- Gekkio, *Game Boy: Complete Technical Reference*: the timer's overflow and reload.
- [SameBoy](https://github.com/LIJI32/SameBoy): the serial clock's flip-flop, read for facts.
- [Mooneye's test suite](https://github.com/Gekkio/mooneye-test-suite): what each test measures, read for facts.
