; SPDX-License-Identifier: Apache-2.0
; Activision's FE bank switching: 8 KB in two 4 KB banks, bank 0 at $F000 and bank 1 at $D000, chosen
; by the access after one of $01FE, by bit 5 of its data: a JSR with S = $FF pushes PCL to $01FE and
; then fetches the target's high byte ($Dx: bank 1, $Fx: bank 0), and an RTS to $01FF pulls PCL from
; $01FE and then PCH. Calls with S lower don't touch $01FE and stay in the bank. Assembled once per
; bank (-D BANK=k), each bank's ID ($40 + k) at $xE00. Results (show.inc):
;   0: the ID at reset (bank 0)
;   1: the ID in a routine in bank 1, called from bank 0 ($41)
;   2: the ID after it returns ($40)
;   3: the ID in a routine in bank 0, called from bank 0 ($40)
;   4: the ID after it returns ($40)
;   5: the ID in a routine bank 1 calls with S = $FD ($41: no switch)
;   6: the ID after that returns, still in bank 1 ($41)

.include "vcs.inc"

.segment "CODE"
.if BANK = 0
reset:  sei
        cld
        ldx #$FF
        txs
        lda #0
        ldx #$7F
@clr:   sta $80,x
        dex
        bpl @clr
        ldx #$FF
        txs

        lda $FE00
        sta RESULTS+0
        jsr $D000               ; bank 1's sub1
        lda $FE00
        sta RESULTS+2
        jsr sub0
        lda $FE00
        sta RESULTS+4

        lda #2
        sta VBLANK
        jmp show

sub0:   lda $FE00
        sta RESULTS+3
        rts

.include "show.inc"
.else
sub1:   lda $DE00               ; at $D000
        sta RESULTS+1
        jsr sub1b
        lda $DE00
        sta RESULTS+6
        rts

sub1b:  lda $DE00
        sta RESULTS+5
        rts
reset:
.endif

.segment "ID"
        .byte $40 + BANK

.segment "VECTORS"
        .word reset, reset
