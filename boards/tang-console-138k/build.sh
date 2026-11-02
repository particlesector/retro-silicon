#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build a Tang Console 138K bitstream (GW5AST-138, 50 MHz oscillator) with
# Gowin EDA (../gowin-eda/build.sh; RS_GOWIN_EDA names its IDE directory). The
# open flow has no PLL for the GW5AST, so the board builds with Gowin's tools
# (decided Nov 1, Chris).
#
# usage: build.sh -t <top> -c <pins.cst> [-f <MHz>] [-k NET=MHz]... [-o <outdir>] [-g NAME=VALUE]... [-x OPTION=VALUE]... <sources...>
set -euo pipefail
exec "$(dirname "$0")/../gowin-eda/build.sh" -d GW5AST-LV138PG484AC1/I0 -F GW5AST-138C -f 50 "$@"
