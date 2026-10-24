# 0003: Test-shell protocol: stop-and-wait with idempotent commands

**Status:** accepted, October 2026

**Context:** the host needs reliable access to a core over a UART that can, in principle, drop, corrupt or add bytes. The choices were a stop-and-wait protocol with retries, a windowed protocol with acknowledgements, or trusting the link.

**Decision:** one command at a time. Each frame carries a sequence number, a length and a CRC-32. The shell drops a bad frame silently; the host resends after a silence longer than the shell's stall timeout (10 ms), which guarantees the shell has dropped any partial frame before the retry arrives. Every command is idempotent, so a resend after a lost response is harmless. Commands start with sync byte `A5`, responses with `5A`, so a loopback can't pass for a shell. The shell checks a frame's CRC by running the CRC over the frame and its CRC field and comparing against the fixed CRC-32 residue `2144DF1C`, which needs no separate comparison logic.

**Consequences:** throughput is lower than a windowed protocol: each command waits a round trip. At 1.5 Mbaud with 2 KB payloads that costs little, and it keeps the RTL small (about 900 LUTs). Commands like "run N more frames" are not allowed; they're written as "run until frame N" instead. A large frame is more likely to be hit by an error than a small one, so very noisy links should use smaller payloads.
