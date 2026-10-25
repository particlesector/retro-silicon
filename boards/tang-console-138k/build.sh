#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build a Tang Console 138K bitstream (GW5AST-138, 50 MHz) with ../gowin/build.sh.
#
# usage: build.sh -t <top> -c <pins.cst> [-f <MHz>] [-o <outdir>] [-g NAME=VALUE]... <sources...>
set -euo pipefail
exec "$(dirname "$0")/../gowin/build.sh" -d GW5AST-LV138PG484AC1/I0 -F GW5AST-138C -f 50 "$@"
