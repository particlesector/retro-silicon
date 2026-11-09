; SPDX-License-Identifier: Apache-2.0
; The TIA's playfield, background and VBLANK, and when writes to them land. Eight bands of 24 lines,
; each starting with a line that sets it up:
;   1-4: a fixed playfield (PF0 $50, PF1 $C3, PF2 $A5) with CTRLPF 0 (normal), 1 (reflected),
;        2 (score: COLUP0's colour on the left half, COLUP1's on the right) and 6 (score with priority,
;        which drops score's colours)
;   5-8: on each line one write lands a CPU cycle later than on the line before, so its 23 lines show it
;        landing at every pixel phase: PF2 to $FF, COLUBK to $0E, VBLANK on, CTRLPF's reflection on
;        (which the playfield takes only at pixels 0 and 79)

.include "vcs.inc"

VBLANK_ON = 2

; One band's set-up line.
.macro  SETUP ctrl, bk, pf, p0, p1, p2
        sta WSYNC
        lda #bk
        sta COLUBK
        lda #pf
        sta COLUPF
        lda #p0
        sta PF0
        lda #p1
        sta PF1
        lda #p2
        sta PF2
        lda #ctrl
        sta CTRLPF
.endmacro

; A fixed band: set up, then 23 more lines.
.macro  STATIC ctrl, bk, pf
        SETUP ctrl, bk, pf, $50, $C3, $A5
        ldx #23
:       sta WSYNC
        dex
        bne :-
.endmacro

; A sliding band: each of 23 lines sets `reg` to `base` at its start, then to `value` d0 + i cycles
; later (its write's last cycle is the line's cycle d0 + i + 9).
.macro  SLIDE reg, base, value, d0
        .repeat 23, i
        sta WSYNC
        lda #base
        sta reg
        lda #value
        DELAY d0 + i
        sta reg
        .endrep
.endmacro

.segment "CODE"
reset:  sei
        cld
        ldx #$FF
        txs
        lda #$46
        sta COLUP0
        lda #$C6
        sta COLUP1

frame:  lda #2
        sta VSYNC
        sta WSYNC
        sta WSYNC
        sta WSYNC
        lda #0
        sta VSYNC
        lda #VBLANK_ON
        sta VBLANK
        ldx #37
@vb:    sta WSYNC
        dex
        bne @vb
        lda #0
        sta VBLANK

        STATIC 0, $00, $1E
        STATIC 1, $90, $2E
        STATIC 2, $02, $1E
        STATIC 6, $04, $5E

        SETUP 0, $80, $3E, $00, $00, $00
        SLIDE PF2, $00, $FF, 27
        SETUP 0, $00, $3E, $00, $00, $00
        SLIDE COLUBK, $00, $0E, 14
        SETUP 0, $A4, $3E, $F0, $00, $00
        SLIDE VBLANK, 0, VBLANK_ON, 30
        lda #0
        sta VBLANK
        SETUP 0, $00, $7E, $10, $01, $80
        SLIDE CTRLPF, 0, 1, 40

        lda #VBLANK_ON
        sta WSYNC
        sta VBLANK
        lda #0
        sta CTRLPF
        ldx #29
@os:    sta WSYNC
        dex
        bne @os
        jmp frame

wait12: rts

.segment "VECTORS"
        .word reset, reset, reset
