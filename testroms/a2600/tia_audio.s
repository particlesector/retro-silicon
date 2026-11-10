; SPDX-License-Identifier: Apache-2.0
; The TIA's sound: both channels' AUDC modes, dividers and volumes, and when writes to them land.
; Each frame (counter F, from 0):
;   - in vertical blank, channel 0 takes AUDC0 = F's low 4 bits (so every mode in 16 frames), AUDF0
;     = 5 x (F / 16), AUDV0 = 8 + (F / 4) mod 8, and plays through the frame;
;   - three bands of 46 lines toggle one of channel 1's registers on every line, at cycle 19 + D of
;     the line, where D = F mod 54 steps a cycle a frame: AUDV1 ($F, $5; AUDC1 0, which holds the
;     output at AUDV1), AUDF1 (2, 19; AUDC1 4, a square wave) and AUDC1 (3, 14; AUDF1 1);
;   - one line writes RSYNC at that cycle (with channel 1 a square wave at AUDF1 0), to see whether
;     cutting the line short moves the sound's clocks.
; The sound check is each sample's two channel sums (the 4-bit levels summed between the two clocks
; a line that make a sample), so it sees the colour clock each write lands on.

.include "vcs.inc"

N = 60                  ; the sled's length: entering it at N - D delays D + 3 cycles
DMAX = 54               ; D's range

frame   = $80           ; F
dly     = $81           ; D
cur     = $82           ; the value the band writes next
ptrs    = $83           ; 8 bytes: where each band jumps into its sled

.segment "CODE"
; A band: 46 lines, each writing `cur` to `reg` at cycle 19 + D, alternating `va` and `vb`.
.macro  BAND bk, reg, va, vb, sled, p
        .local loop
        sta WSYNC
        lda #bk
        sta COLUBK
        lda #va
        sta cur
        ldx #46
loop:   sta WSYNC
        lda cur                 ; 3
        eor #((va) ^ (vb))      ; 2
        sta cur                 ; 3
        jmp (p)                 ; 5
sled:   .res N, $C9             ; CMP #$C9 pairs: entered at N - D, D + 3 cycles in all
        .byte $C5, $EA
        sta reg                 ; lands on cycle 13 + D + 3 + 3
        dex
        bne loop
.endmacro

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

nextf:  lda #2
        sta VSYNC
        sta WSYNC
        sta WSYNC
        sta WSYNC
        lda #0
        sta VSYNC
        lda #2
        sta VBLANK

        ; Channel 0 for this frame.
        lda frame
        and #$0F
        sta AUDC0
        lda frame
        lsr
        lsr
        lsr
        lsr
        sta cur
        asl
        asl
        adc cur                 ; x 5 (carry clear: F / 16 < 16)
        and #$1F
        sta AUDF0
        lda frame
        lsr
        lsr
        and #7
        ora #8
        sta AUDV0

        ; Each band's sled entry: sled + N - D.
        .repeat 4, i
        lda #<(.ident(.sprintf("sled%d", i)) + N)
        sec
        sbc dly
        sta ptrs + 2 * i
        lda #>(.ident(.sprintf("sled%d", i)) + N)
        sbc #0
        sta ptrs + 2 * i + 1
        .endrep

        ldx #36
@vb:    sta WSYNC
        dex
        bne @vb
        sta WSYNC
        lda #0
        sta VBLANK

        ; Band 1: AUDV1, with AUDC1 0 (the output held at AUDV1).
        lda #0
        sta AUDC1
        sta AUDF1
        BAND $34, AUDV1, $0F, $05, sled0, ptrs
        ; Band 2: AUDF1, with AUDC1 4 (a square wave) at full volume.
        lda #4
        sta AUDC1
        lda #$0F
        sta AUDV1
        BAND $54, AUDF1, 2, 19, sled1, ptrs + 2
        ; Band 3: AUDC1, with AUDF1 1.
        lda #1
        sta AUDF1
        BAND $74, AUDC1, 3, 14, sled2, ptrs + 4

        ; RSYNC at cycle 19 + D, with channel 1 a square wave at AUDF1 0.
        sta WSYNC
        lda #$94
        sta COLUBK
        lda #4
        sta AUDC1
        lda #0
        sta AUDF1
        sta WSYNC
        lda cur                 ; the bands' 13 cycles before the jump
        eor #0
        sta cur
        jmp (ptrs + 6)
sled3:  .res N, $C9
        .byte $C5, $EA
        sta RSYNC
        ldx #50
@fill:  sta WSYNC
        dex
        bne @fill

        lda #2
        sta WSYNC
        sta VBLANK
        ldx #30
@os:    sta WSYNC
        dex
        bne @os

        inc frame
        ldx dly
        inx
        cpx #DMAX
        bne @d
        ldx #0
@d:     stx dly
        jmp nextf

wait12: rts

.segment "VECTORS"
        .word reset, reset, reset
