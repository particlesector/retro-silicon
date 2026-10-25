#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build a Tang Nano 20K bitstream (GW2AR-18, 27 MHz) with ../gowin/build.sh.
#
# usage: build.sh -t <top> -c <pins.cst> [-f <MHz>] [-o <outdir>] [-g NAME=VALUE]... <sources...>
set -euo pipefail
exec "$(dirname "$0")/../gowin/build.sh" -d GW2AR-LV18QN88C8/I7 -F GW2A-18C -f 27 "$@"
