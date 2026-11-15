; SPDX-License-Identifier: Apache-2.0
; The RIOT's RAM at power-up. The cartridge never clears it: before anything else it folds the 128
; bytes into the 32 at RESULTS ($C0-$DF), result n becoming the OR of $80 + n, $A0 + n, $C0 + n and
; $E0 + n, and then shows them (show.inc), which uses no RAM. From Stella's power-up (RAM all 0, with the rig's
; determinism patch) every byte is 0. Run after a cartridge that leaves the RAM written (riot_ram),
; it checks that a power-up (a2600_sys's reset) gives the next cartridge the same RAM.

.include "vcs.inc"


.segment "CODE"
reset:  sei
        cld
        ldx #$FF
        txs
        ldx #31
@fold:  lda $80,x
        ora $A0,x
        ora $C0,x
        ora $E0,x
        sta RESULTS,x
        dex
        bpl @fold
        jmp show

.include "show.inc"

.segment "VECTORS"
        .word reset, reset, reset
