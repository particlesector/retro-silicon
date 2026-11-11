; SPDX-License-Identifier: Apache-2.0
; Parker Brothers' E0 bank switching: 8 KB in eight 1 KB slices. $1000, $1400 and $1800 show the
; slices that accesses to $1FE0-$1FE7, $1FE8-$1FEF and $1FF0-$1FF7 select; $1C00 always shows slice 7,
; which holds this program. Each slice's first byte is its ID ($40 + its number; bank_id.s for 0-6).
; Results (show.inc):
;   0-2: the IDs at $1000, $1400, $1800 at reset (slices 4, 5, 6: $44, $45, $46)
;   3-10: the ID at $1000 after selecting each slice 0-7 there
;   11-18: the same at $1400
;   19-26: the same at $1800
;   27: the ID at $1C00 ($47)
;   28: the ID at $1000 after selecting slice 2 there by a write ($42)

.include "vcs.inc"

.segment "CODE"
        .byte $47

reset:  sei
        cld
        ldx #$FF
        txs
        lda #0
        ldx #$7F
@clr:   sta $80,x
        dex
        bpl @clr

        lda $F000
        sta RESULTS+0
        lda $F400
        sta RESULTS+1
        lda $F800
        sta RESULTS+2
        .repeat 8, s
        lda $FFE0+s
        lda $F000
        sta RESULTS+3+s
        lda $FFE8+s
        lda $F400
        sta RESULTS+11+s
        lda $FFF0+s
        lda $F800
        sta RESULTS+19+s
        .endrepeat
        lda $FC00
        sta RESULTS+27
        sta $FFE2
        lda $F000
        sta RESULTS+28

        lda #2
        sta VBLANK
        jmp show

.include "show.inc"

.segment "VECTORS"
        .word reset, reset
