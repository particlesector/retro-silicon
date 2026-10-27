#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build a PYNQ-Z2 bitstream (XC7Z020-1CLG400C) with ../xilinx/build.sh.
#
# usage: build.sh -t <top> -c <pins.xdc> [-o <outdir>] [-g NAME=VALUE]... <sources...>
set -euo pipefail
exec "$(dirname "$0")/../xilinx/build.sh" -p xc7z020clg400-1 "$@"
