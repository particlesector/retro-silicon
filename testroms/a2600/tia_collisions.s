; SPDX-License-Identifier: Apache-2.0
; The TIA's collision latches, CXCLR, and the input ports. Three cases, each setting up under VBLANK,
; clearing the latches, drawing a few lines and reading CXM0P-CXPPMM (results 0-7, 8-15, 16-23):
;   A: all five objects and the playfield on the same pixels: every latch set.
;   B: player 0 and missile 1 over PF0's left copy, player 1 and the ball over its right copy,
;      missile 0 alone: only M1-P0, P0-PF, P1-PF, P1-BL and BL-PF.
;   C: the two players, quad width, side by side across the line's end, so each line starts mid-draw;
;      VBLANK is off only in the horizontal blank, where an HMOVE's movement steps check collisions:
;      P0-P1 only.
; Then INPT0-INPT5 (24-29), and INPT4 and INPT5 again with VBLANK's latch on (30, 31). Reads keep the
; bus's last value in bits 5-0. Results are drawn by show.inc.

.include "vcs.inc"

; Read the eight collision latches into RESULTS+base.
.macro  READCX base
        ldx #7
:       lda CXM0P,x
        sta RESULTS+base,x
        dex
        bpl :-
.endmacro

; Place an object (`reg`, a RES register) at cycle n of a line.
.macro  PLACE reg, n
        sta WSYNC
        DELAY n
        sta reg
.endmacro

.segment "CODE"
reset:  sei
        cld
        ldx #$FF
        txs
        lda #0
        ldx #$7F
@clr:   sta $80,x
        dex
        bpl @clr
        lda #2
        sta WSYNC
        sta VBLANK

        ; Case A: everything on the same pixels.
        lda #$FF
        sta GRP0
        sta GRP1
        sta PF1
        sta PF2
        sta PF0
        lda #2
        sta ENAM0
        sta ENAM1
        sta ENABL
        lda #$30
        sta NUSIZ0
        sta NUSIZ1
        sta CTRLPF
        PLACE RESP0, 30
        PLACE RESP1, 30
        PLACE RESM0, 30
        PLACE RESM1, 30
        PLACE RESBL, 30
        sta WSYNC
        sta CXCLR
        lda #0
        sta VBLANK
        sta WSYNC
        sta WSYNC
        sta WSYNC
        lda #2
        sta VBLANK
        READCX 0

        ; Case B: P0, M1 and PF; P1 and BL; M0 alone.
        lda #$F0
        sta PF0
        lda #0
        sta PF1
        sta PF2
        sta NUSIZ0
        sta NUSIZ1
        sta CTRLPF
        PLACE RESP0, 23
        PLACE RESM1, 24
        PLACE RESP1, 45
        PLACE RESBL, 46
        PLACE RESM0, 60
        sta WSYNC
        sta CXCLR
        lda #0
        sta VBLANK
        sta WSYNC
        sta WSYNC
        sta WSYNC
        lda #2
        sta VBLANK
        READCX 8

        ; Case C: the players across the line's end, checked only in the blank, by HMOVE.
        lda #0
        sta ENAM0
        sta ENAM1
        sta ENABL
        sta PF0
        sta HMCLR
        lda #7
        sta NUSIZ0
        sta NUSIZ1
        PLACE RESP0, 69
        PLACE RESP1, 69
        sta WSYNC
        sta CXCLR
        .repeat 4
        sta WSYNC
        lda #0
        sta VBLANK
        sta HMOVE
        lda #2
        DELAY 9
        sta VBLANK
        .endrep
        sta WSYNC
        READCX 16

        ; The input ports, then the fire buttons latched.
        ldx #5
:       lda INPT0,x
        sta RESULTS+24,x
        dex
        bpl :-
        lda #$42
        sta VBLANK
        lda INPT4
        sta RESULTS+30
        lda INPT5
        sta RESULTS+31
        lda #2
        sta VBLANK

        lda #0
        sta GRP0
        sta GRP1
        jmp show

wait12: rts

.include "show.inc"

.segment "VECTORS"
        .word reset, reset, reset
