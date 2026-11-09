; SPDX-License-Identifier: Apache-2.0
; RESMP held only briefly: where in its player's drawing it moves the missile. Eight bands of 24 lines,
; player 1 (blue, GRP1 $FF) placed once per band, NUSIZ1 0 (one copy), 1 (two close copies), 5
; (double width) and 7 (quad width), two bands each. Each band's first two lines set it up and park
; missile 1 on the right; then 11 pairs of lines: on the first, RESMP1 is set and cleared 5 cycles
; later (15 colour clocks), a cycle later on each pair, so the window sweeps across the player's main
; copy (the first band of a width its left part, the second its right); on the second, the missile
; shows where that left it, and RESM1 late in the line parks it on the right again. A missile moves to
; its player only if RESMP is set while the player's drawing passes a certain point, so the window
; shows it moved only on the pairs where it covers that point.

.include "vcs.inc"

; DELAY that takes 1 as 2.
.macro  DELAY_ n
        .if (n) = 1
        DELAY 2
        .else
        DELAY (n)
        .endif
.endmacro

; A band: NUSIZ1 `nus`, the window's first write at cycle base + 4 on the first pair.
.macro  BAND nus, base
        sta WSYNC
        lda #nus
        sta NUSIZ1
        lda #2
        sta ENAM1
        lda #$FF
        sta GRP1
        sta WSYNC
        DELAY 39
        sta RESP1
        DELAY 18
        sta RESM1
        .repeat 11, i
        sta WSYNC
        lda #2
        DELAY_ base + i
        sta RESMP1
        lda #0
        sta RESMP1
        sta WSYNC
        jsr park
        .endrep
.endmacro

.segment "CODE"
reset:  sei
        cld
        ldx #$FF
        txs
        ; Clear zero page: RAM and every TIA register (RSYNC included).
        lda #0
        tax
@clr:   sta $00,x
        inx
        bne @clr
        lda #$86
        sta COLUP1
        lda #$04
        sta COLUBK

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

        BAND 0, 36
        BAND 0, 47
        BAND 1, 36
        BAND 1, 47
        BAND 5, 36
        BAND 5, 47
        BAND 7, 36
        BAND 7, 47

        lda #2
        sta WSYNC
        sta VBLANK
        ldx #30
@os:    sta WSYNC
        dex
        bne @os
        jmp frame

; RESM1 at the same cycle as the band's own (the JSR takes 6).
park:   DELAY 56
        sta RESM1
        rts

wait12: rts

.segment "VECTORS"
        .word reset, reset, reset
