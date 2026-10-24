# harness

The C++ core of the test harness. Tests talk to a design through `rig::Link`, a byte pipe, so the same test runs against a Verilator model or a real board and gives directly comparable results.

| Header | Provides |
| --- | --- |
| `rig/link.hpp` | `Link`: `write`, `read` with a timeout, `baud`; and `RigError` for failures of the rig itself rather than the design |
| `rig/sim_link.hpp` | `SimLink`: any Verilated design with a UART (`SimModel`), driven bit by bit; timeouts are simulated time |
| `rig/sim_systems.hpp` | `make_uart_echo_sim()` and `make_shell_ram_sim()`: this repo's systems at 1.5 Mbaud, with the same build IDs as their bitstreams |
| `rig/shell.hpp` | The test-shell protocol: frame encoder, a parser that survives noise, and `Client` (PING, INFO, PEEK, POKE, with retries) |
| `rig/shell_test.hpp` | `shell_test`: random commands against `systems/shell-ram`, checked against a model of its RAM, optionally over a `FaultyLink` |
| `rig/faulty_link.hpp` | `FaultyLink`: wraps a `Link` and drops, corrupts or adds bytes at a seeded rate, to prove a protocol recovers |
| `rig/echo_test.hpp` | `echo_test`: streams seeded random data through an echo design and checks every byte, returning a `TestResult` with the CRC32 of what came back |
| `rig/uart_model.hpp` | Bit-level 8N1 `UartEncoder` and `UartDecoder` for driving and checking RTL one clock at a time |
| `rig/crc32.hpp` | Software CRC-32, matching `components/common/crc32` |
| `rig/test_result.hpp` | `TestResult`: pass or fail, the reason, notes, bytes checked, time and CRC32 |

CMake targets: `rs_harness` (everything but this repo's Verilated systems) and `rs_sim_link` (adds them). A board backend implements `Link` over a serial port; it isn't in this repo because it depends on the machine it runs on.

`golden/echo_crc32.txt` and `golden/shell_crc32.txt` hold the tests' CRC32 for given sizes and seeds. Every backend that passes must give these values; the shell test's CRC doesn't depend on injected faults.
