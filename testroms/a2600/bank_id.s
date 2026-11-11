; SPDX-License-Identifier: Apache-2.0
; A data slice of a sliced cartridge (E0, 3F, E7): its ID ($40 + its number, -D SLICE=k) first, the
; rest $FF.
.segment "CODE"
        .byte $40 + SLICE
