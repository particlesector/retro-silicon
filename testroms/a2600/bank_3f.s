; SPDX-License-Identifier: Apache-2.0
; Tigervision's 3F bank switching, 16 KB here: eight 2 KB banks. A write to $0000-$003F (the TIA's
; registers included) selects the bank $1000 shows by its value, modulo 8; $1800 always shows the
; last, which holds this program. Each bank's first byte is its ID ($40 + its number; bank_id.s for
; 0-6). Results (show.inc):
;   0: the ID at $1000 at reset ($40)
;   1-8: the ID after writing 0-7 to $3F
;   9-16: the ID after writing 8-15 ($40-$47 again)
;   17: the ID after writing 3 to $3E ($43)
;   18: the ID after writing 5 to $40, not a hotspot ($43)
;   19: the ID after reading $3F ($43)
;   20: the ID at $1800 ($47)
; In Stella a 3F cartridge takes all of $0000-$003F, so writes there don't reach the TIA (on the
; console they do): like Tigervision's games, this one writes the TIA through its mirror at $0040.

VSYNC   = $40
VBLANK  = $41
WSYNC   = $42
COLUBK  = $49
RESULTS = $C0

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
        .repeat 16, v
        lda #v
        sta $3F
        lda $F000
        sta RESULTS+1+v
        .endrepeat
        lda #3
        sta $3E
        lda $F000
        sta RESULTS+17
        lda #5
        sta $40                 ; VSYNC's mirror: 5 has bit 1 clear, so VSYNC stays off
        lda $F000
        sta RESULTS+18
        lda $3F
        lda $F000
        sta RESULTS+19
        lda $F800
        sta RESULTS+20

        lda #2
        sta VBLANK
        jmp show

.include "show.inc"

.segment "VECTORS"
        .word reset, reset
