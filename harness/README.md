# harness

The C++ core of the test harness. Tests talk to a design through `rig::Link`, a byte pipe, so the same test runs against a Verilator model or a real board and gives directly comparable results.

| Header | Provides |
| --- | --- |
| `rig/link.hpp` | `Link`: `write`, `read` with a timeout, `baud`; and `RigError` for failures of the rig itself rather than the design |
| `rig/sim_link.hpp` | `SimLink`: `systems/uart-echo` in Verilator at 1.5 Mbaud timing; timeouts are simulated time |
| `rig/echo_test.hpp` | `echo_test`: streams seeded random data through an echo design and checks every byte, returning a `TestResult` with the CRC32 of what came back |
| `rig/uart_model.hpp` | Bit-level 8N1 `UartEncoder` and `UartDecoder` for driving and checking RTL one clock at a time |
| `rig/crc32.hpp` | Software CRC-32, matching `components/common/crc32` |

CMake targets: `rs_harness` (everything but the sim backend) and `rs_sim_link` (adds `SimLink`). A board backend implements `Link` over a serial port; it isn't in this repo because it depends on the machine it runs on.

`golden/echo_crc32.txt` holds the echo test's CRC32 for given sizes and seeds. Every backend that passes must give these values.
