; SPDX-License-Identifier: Apache-2.0
; The TIA's players: their copies and sizes, positioning, reflection and vertical delay. Eight bands of
; 24 lines, band k with NUSIZ0 = k (and NUSIZ1 = k + 3), each starting with a line that sets it up:
;   GRP0 $C5 (player 0, red), REFP0 on in odd bands; player 1 (blue) is placed once per band, and
;   written $81, then $3C after GRP0's write, so with VDELP1 on (bands 4-7) it shows $81, else $3C.
; On each of the band's other 23 lines RESP0 lands a cycle later than on the line before, from the
; blank before the picture (bands 0, 3, 6), the picture's left (1, 4, 7) or its middle (2, 5).

.include "vcs.inc"

; DELAY that takes 1 as 2.
.macro  DELAY_ n
        .if (n) = 1
        DELAY 2
        .else
        DELAY (n)
        .endif
.endmacro

.macro  BAND k, base
        sta WSYNC
        lda #k
        sta NUSIZ0
        lda #((k + 3) .mod 8)
        sta NUSIZ1
        lda #((k .mod 2) * 8)
        sta REFP0
        lda #((k / 4) .mod 2)
        sta VDELP1
        lda #(k .mod 2) * 2
        sta COLUBK
        lda #$81
        sta GRP1
        lda #$C5
        sta GRP0
        lda #$3C
        sta GRP1
        sta RESP1
        .repeat 23, i
        sta WSYNC
        DELAY_ base + i
        sta RESP0
        .endrep
.endmacro

.segment "CODE"
reset:  sei
        cld
        ldx #$FF
        txs
        lda #$46
        sta COLUP0
        lda #$86
        sta COLUP1

frame:  lda #2
        sta VSYNC
        sta WSYNC
        sta WSYNC
        sta WSYNC
        lda #0
        sta VSYNC
        lda #2
        sta VBLANK
        ldx #37
@vb:    sta WSYNC
        dex
        bne @vb
        lda #0
        sta VBLANK

        BAND 0, 0
        BAND 1, 20
        BAND 2, 30
        BAND 3, 0
        BAND 4, 20
        BAND 5, 30
        BAND 6, 0
        BAND 7, 20

        lda #2
        sta WSYNC
        sta VBLANK
        lda #0
        sta GRP0
        sta GRP1
        ldx #29
@os:    sta WSYNC
        dex
        bne @os
        jmp frame

wait12: rts

.segment "VECTORS"
        .word reset, reset, reset
