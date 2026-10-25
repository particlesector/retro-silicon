# SPDX-License-Identifier: Apache-2.0
# perfect6502, a transistor-level simulation of the NMOS 6502, for the CPU's
# lockstep test. Its code is MIT-licensed, but its netlist data (from
# visual6502.org) is CC BY-NC-SA 3.0, so it's downloaded into the build tree
# at a pinned commit and checked against SHA-256 sums, never committed.
# Defines the target `perfect6502` when the download works; without network
# access the lockstep test is left out.

option(RS_PERFECT6502 "Fetch perfect6502 for the CPU lockstep test" ON)
if(NOT RS_PERFECT6502)
    return()
endif()

# Before April 2026's optimisation commits: 14983af left group_clear reading an
# uninitialised count and overrunning its buffer (found with AddressSanitizer).
set(commit 6c1f1a504f922c85c2fbbfd5c6752b69bd50f96c)
set(files
    perfect6502.c   cac56dab1d6a08852361870191d9d5f633450939c14b7e5505e26da78146bbbf
    perfect6502.h   15ab13035b71d5008bd14d993b34656df088d760d18308a7fb64d7b28c53d340
    netlist_sim.c   aad5cf8c108806d08cc184c081b2a872d36e0d44927e9e77a27e67be43fb5c72
    netlist_sim.h   fe483a7f43f973dfc388b02410a711ceb5b492ab08970429cc16a7cd0caf70bb
    netlist_6502.h  7a5a28f64a0d464d18faecd3d715d96549bc5da8f05e6f468ef3dae97ef0f340
    types.h         484747d5c63f0b4c1c8ed897ea52606bd7521b08f78a469582603e85a678f3bc
    LICENSE         29f44f6af3005961e76e712a8b0f36faf4d8c3d8e2592ca191876154adff2179)
set(dir ${CMAKE_BINARY_DIR}/_deps/perfect6502)

while(files)
    list(POP_FRONT files name sha)
    if(EXISTS ${dir}/${name})
        file(SHA256 ${dir}/${name} have)
        if(have STREQUAL sha)
            continue()
        endif()
    endif()
    file(DOWNLOAD https://raw.githubusercontent.com/mist64/perfect6502/${commit}/${name} ${dir}/${name}.part
         STATUS status)
    list(GET status 0 code)
    if(NOT code EQUAL 0)
        message(WARNING "perfect6502: can't download ${name} (${status}); the CPU lockstep test is left out")
        return()
    endif()
    file(SHA256 ${dir}/${name}.part have)
    if(NOT have STREQUAL sha)
        message(FATAL_ERROR "perfect6502: ${name} has SHA-256 ${have}, expected ${sha}")
    endif()
    file(RENAME ${dir}/${name}.part ${dir}/${name})
endwhile()

enable_language(C)
add_library(perfect6502 STATIC ${dir}/perfect6502.c ${dir}/netlist_sim.c)
target_compile_options(perfect6502 PRIVATE -w -O3)  # third-party code: no warnings, full speed
