; SPDX-License-Identifier: Apache-2.0
; The TIA's missiles and ball: their copies and widths, positioning, RESMP, the ball's vertical delay,
; and how they stack with the players and the playfield. Eight bands of 24 lines; band k sets up on
; its first two lines:
;   NUSIZ0 = k with missile 0 (red) 1, 2, 4 or 8 wide (k mod 4); NUSIZ1 = k + 3 with missile 1 (blue)
;   the other way round; the ball (green) (k + 1) mod 4 wide; CTRLPF's priority normal, score or
;   playfield first (k mod 3), reflected in bands 4-7; VDELBL on in bands 4-7, with the ball's old
;   enable off in odd bands (so bands 5 and 7 have no ball); player 1 placed, and missile 1 placed by
;   RESM1 or, in bands 2 and 6, locked to player 1 by RESMP1 and released; band 5 leaves it locked,
;   hiding missile 1.
; On each of the band's other 22 lines RESM0 lands a cycle later than on the line before, and RESBL 3
; cycles after it, from the blank before the picture (bands 0, 3, 6), the picture's left (1, 4, 7) or
; its middle (2, 5).

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
        lda #(k | ((k .mod 4) << 4))
        sta NUSIZ0
        lda #(((k + 3) .mod 8) | ((3 - (k .mod 4)) << 4))
        sta NUSIZ1
        lda #((((k + 1) .mod 4) << 4) | (((k .mod 3) * 2) .bitand 6) | ((k / 4) .mod 2))
        sta CTRLPF
        lda #(k .mod 2) * 2
        sta COLUBK
        lda #((k / 4) .mod 2)
        sta VDELBL
        lda #((1 - (k .mod 2)) * 2)
        sta ENABL
        lda #$18
        sta GRP1
        lda #2
        sta ENABL
        sta WSYNC
        sta RESP1
        .if k = 2 || k = 5 || k = 6
        sta RESMP1
        .endif
        .if k = 2 || k = 6
        lda #0
        sta RESMP1
        .endif
        .if k <> 2 && k <> 5 && k <> 6
        DELAY 20
        sta RESM1
        .endif
        sta RESP0
        .repeat 22, i
        sta WSYNC
        DELAY_ base + i
        sta RESM0
        sta RESBL
        .endrep
        .if k = 5
        lda #0
        sta RESMP1
        .endif
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
        lda #$C6
        sta COLUPF
        lda #$0F
        sta PF1
        lda #$F0
        sta PF2
        lda #$81
        sta GRP0

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
        lda #2
        sta ENAM0
        sta ENAM1

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
        sta ENAM0
        sta ENAM1
        sta ENABL
        ldx #29
@os:    sta WSYNC
        dex
        bne @os
        jmp frame

wait12: rts

.segment "VECTORS"
        .word reset, reset, reset
