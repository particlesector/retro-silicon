# 0001: FuseSoC CAPI2 manifests for every component

**Status:** accepted, October 2026

**Context:** components should be easy to reuse outside this repo, with their dependencies resolved automatically. The options were FuseSoC `.core` files, plain file lists, or this repo's CMake only.

**Decision:** every component and system has a FuseSoC CAPI2 manifest named `retro-silicon:<group>:<name>:<version>`, listing its RTL and dependencies. The CMake build stays the way to run the tests; ctest lints each system through FuseSoC, so the manifests can't drift from the RTL unnoticed.

**Consequences:** each RTL file is listed twice, in the `.core` file and in CMakeLists.txt. Parameters go only on a core's `lint` target, because FuseSoC passes a dependency's default-target parameters to the top level that uses it.
