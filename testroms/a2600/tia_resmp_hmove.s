; SPDX-License-Identifier: Apache-2.0
; RESMP1 released after an HMOVE that moved the locked missile and its player differently: while
; RESMP1 is set the chip puts missile 1 on player 1 each time the player's main copy passes its lock
; point, and the missile's counter otherwise runs on as any object's does, HMOVE's clocks included; so
; an HMOVE between the last put and the release leaves the missile moved by its own HM value, not the
; player's (Stella instead puts it on the player at the release). As Ice Hockey moves its stick
; (missile 1, HM 1) beside its player (HM 0) with late HMOVEs at cycle 70 and releases it at cycle 16.
;
; 48 groups of three lines from the picture's first. Group g: its first line locks missile 1 to
; player 1 (RESMP1 2), sets HMP1 0 and HMM1 TH[g] (HM 0, 1, 3, 7, -8, -7, -4, -1 in turn), places player 1 (RESP1 written at cycle 44,
; so the player's main copy passes the lock point on this line, the last put), and writes HMOVE at
; cycle 70 + g / 24; its second releases the missile (RESMP1 0) at cycle 12 + 4 x ((g / 8) mod 3);
; its third draws missile 1 (one pixel), whose column is the result. The other 48 lines are blank.
; Line cycles count from the CPU's first cycle after WSYNC, 0; a STA writes on its third.

.include "vcs.inc"

GROUPS = 48
NE = 24                 ; each sled: entering it at NE - D delays D + 3 cycles

group   = $80           ; the group being drawn
ptra    = $81           ; where its first line enters sled A
ptrb    = $83           ; where its second line enters sled B
hmm     = $85           ; its HMM1

.segment "CODE"
reset:  sei
        cld
        ldx #$FF
        txs
        ; Clear zero page: RAM and every TIA register.
        lda #0
        tax
@clr:   sta $00,x
        inx
        bne @clr
        lda #$0E
        sta COLUP1
        lda #>sleda
        sta ptra + 1
        lda #>sledb
        sta ptrb + 1

frame:  lda #2
        sta VSYNC
        sta WSYNC
        sta WSYNC
        sta WSYNC
        lda #0
        sta VSYNC
        lda #2
        sta VBLANK
        ldy #36
@vb:    sta WSYNC
        dey
        bne @vb
        lda #0
        sta group
        lda TA
        sta ptra
        lda TB
        sta ptrb
        lda TH
        sta hmm
        sta WSYNC
        lda #0
        sta VBLANK

groups: sta WSYNC               ; the group's first line, cycle 0
        lda #0                  ; 2
        sta HMP1                ; 5
        lda hmm                 ; 8
        sta HMM1                ; 11
        lda #2                  ; 13
        sta RESMP1              ; 16: locked
        ldx #5                  ; 18, then 24 cycles
@w:     dex
        bne @w
        sta RESP1               ; written at 44
        jmp (ptra)              ; at 45: HMOVE written at 55 + D
sleda:  .res NE, $C9            ; CMP #$C9 pairs: entered at NE - D, D + 3 cycles in all
        .byte $C5, $EA
        sta HMOVE
        sta WSYNC               ; the second line
        lda #0                  ; 2
        jmp (ptrb)              ; at 2: RESMP1 written at 12 + D
sledb:  .res NE, $C9
        .byte $C5, $EA
        sta RESMP1
        sta WSYNC               ; the third line
        lda #2
        sta ENAM1               ; written at 4
        inc group               ; 10
        ldy group               ; 13
        lda TA,y                ; 17
        sta ptra                ; 20
        lda TB,y                ; 24
        sta ptrb                ; 27
        lda TH,y                ; 31
        sta hmm                 ; 34
        ldx #3                  ; 36, then 14 cycles
@w2:    dex
        bne @w2
        lda #0                  ; 52
        sta ENAM1               ; written at 54, after missile 1 is drawn
        lda group
        cmp #GROUPS
        bne groups              ; 63

        ldy #48
@blank: sta WSYNC
        dey
        bne @blank
        lda #2
        sta VBLANK
        ldy #30
@os:    sta WSYNC
        dey
        bne @os
        jmp frame

; Each group's entry into the sleds, HMOVE at 70 + g / 24 (D = that - 55) and RESMP1 at
; 12 + 4 x ((g / 8) mod 3) (D = that - 12), and its HMM1. Group GROUPS's are never used.
TA:
.repeat GROUPS + 1, I
        .byte <(sleda + NE - (70 + I / 24 - 55))
.endrepeat
TB:
.repeat GROUPS + 1, I
        .byte <(sledb + NE - 4 * ((I / 8) .MOD 3))
.endrepeat
TH:                     ; HMV[g mod 8]: $00, $10, $30, $70, $80, $90, $C0, $F0
        .byte $00, $10, $30, $70, $80, $90, $C0, $F0, $00, $10, $30, $70, $80, $90, $C0, $F0
        .byte $00, $10, $30, $70, $80, $90, $C0, $F0, $00, $10, $30, $70, $80, $90, $C0, $F0
        .byte $00, $10, $30, $70, $80, $90, $C0, $F0, $00, $10, $30, $70, $80, $90, $C0, $F0
        .byte $00

.assert >sleda = >(sleda + NE + 2), error, "sled A crosses a page"
.assert >sledb = >(sledb + NE + 2), error, "sled B crosses a page"

.segment "VECTORS"
        .word reset, reset, reset
