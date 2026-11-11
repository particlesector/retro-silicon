; SPDX-License-Identifier: Apache-2.0
; Bank switching by 4 KB banks: Atari's F8, F6 and F4 (with or without the Superchip's RAM), CBS's FA
; and Dynacom's F0. Assembled once per bank (-D BANK=k, with the scheme's NB banks from the hotspot
; HOT), each bank the same program, so it runs on through a switch; only its ID ($FE00, $40 + k) and
; the bytes at the hotspots ($FFF0-$FFFB: k x $10 + the address's low nibble) differ. RAM = 128 or 256
; adds the Superchip's or FA's RAM, written at $1000 and read at $1000 + RAM; the program starts at
; $1200, clear of both. F0 = 1 for F0's single hotspot, which steps to the next bank.
; Results (show.inc):
;   0: the ID at reset: the bank it starts in
; Not F0, for each bank k:
;   1 + 2k: the byte read from hotspot k (the new bank's: k x $10 + its low nibble)
;   2 + 2k: the ID after it
;   1 + 2 NB + k: the ID after a write to hotspot k
; F0: 1-16: the ID after each of 16 reads of $1FF0; 17-24: the byte the first 8 read; 25, 26: the ID
;   after two writes to it
; With RAM, from byte 32 - 6 = 26:
;   26: RAM byte 0 at reset (0), 27: its last (0)
;   28: errors reading back every byte after writing n x 7 + $5A to byte n
;   29: byte 5 after switching to bank 0 (5 x 7 + $5A = $7D), 30: after switching to the last bank
;   31: errors reading back after writing through the read port (which mustn't write)

.include "vcs.inc"

.ifndef F0
F0 = 0
.endif
.ifndef RAM
RAM = 0
.endif

ID      = $FE00
.if F0
HOT     = $FFF0
.endif

.segment "CODE"
        .res $200, $FF          ; $1000-$11FF: the RAM's ports in the schemes that have them

reset:  sei
        cld
        ldx #$FF
        txs
        lda #0
        ldx #$7F
@clr:   sta $80,x
        dex
        bpl @clr

        lda ID
        sta RESULTS+0

.if F0
        .repeat 16, k
        lda HOT
        .if k < 8
        sta RESULTS+17+k
        .endif
        lda ID
        sta RESULTS+1+k
        .endrepeat
        sta HOT
        lda ID
        sta RESULTS+25
        sta HOT
        lda ID
        sta RESULTS+26
.else
        .repeat NB, k
        lda HOT+k
        sta RESULTS+1+2*k
        lda ID
        sta RESULTS+2+2*k
        .endrepeat
        .repeat NB, k
        sta HOT+k
        lda ID
        sta RESULTS+1+2*NB+k
        .endrepeat
.endif

.if RAM
        lda $F000+RAM
        sta RESULTS+26
        lda $F000+RAM+RAM-1
        sta RESULTS+27
        ; Write byte n = n x 7 + $5A, then read them back.
        ldx #0
        lda #$5A
@w:     sta $F000,x
        clc
        adc #7
        inx
        cpx #RAM & $FF
        bne @w
        ldx #0
        lda #$5A
@r:     cmp $F000+RAM,x
        beq :+
        inc RESULTS+28
:       clc
        adc #7
        inx
        cpx #RAM & $FF
        bne @r
        ; The RAM stays through a switch.
        lda HOT
        lda $F000+RAM+5
        sta RESULTS+29
        lda HOT+NB-1
        lda $F000+RAM+5
        sta RESULTS+30
        ; A write to the read port goes nowhere.
        ldx #0
        lda #$EE
@n:     sta $F000+RAM,x
        inx
        cpx #RAM & $FF
        bne @n
        ldx #0
        lda #$5A
@c:     cmp $F000+RAM,x
        beq :+
        inc RESULTS+31
:       clc
        adc #7
        inx
        cpx #RAM & $FF
        bne @c
.endif

        lda #2
        sta VBLANK
        jmp show

.include "show.inc"

.segment "ID"
        .byte $40 + BANK

.segment "MARKS"
        .repeat 12, n
        .byte BANK * $10 + n
        .endrepeat

.segment "VECTORS"
        .word reset, reset
