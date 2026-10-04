; SA-1 CPU entry: memory setup, then GameMain
.p816
.smart
.include "sa1.inc"
.include "shared.inc"

.export SA1Entry
.import GameMain

.segment "CODE"

SA1Entry:
    sei
    clc
    xce
    ; I-RAM and BW-RAM start out write-protected for the SA-1: unlock them
    ; before the first stack push (long stores, DB is not known yet)
    sep #$20
    .a8
    lda #$FF
    sta f:CIWP
    lda #$80
    sta f:CBWE
    lda #$00
    sta f:BMAP              ; BW-RAM window $6000 = BW-RAM $0000
    rep #$38
    .a16
    .i16
    ldx #$06FF              ; SA-1 stack in I-RAM
    txs
    lda #$0000
    tcd                     ; direct page = I-RAM $0000
    sep #$20
    .a8
    lda #$00
    pha
    plb                     ; DB = $00
    stz MCNT                ; arithmetic unit: multiply
    .ifdef SA1_NMI_DBG
    lda #$10
    sta CIE                 ; NMI from the S-CPU
    .endif
    .ifdef DBG_DELAY
    ; debug: shift the SA-1 timing by a variable start-up delay
    rep #$10
    ldx #DBG_DELAY
:   dex
    bne :-
    .endif
    rep #$20
    .a16
    ; clear I-RAM $0000-$05FF (DP + SA-1 vars); stack page left alone
    ldx #0
:   stz $0000,x
    inx
    inx
    cpx #$0600
    bne :-
    ; clear BW-RAM $40:0000-$41:FFFF, except the battery-backed high score
    ; table ($40:7900-$40:7AFF, see hiscore.s)
    ldx #0
    lda #0
@clr:
    cpx #$7900
    bcc :+
    cpx #$7B00
    bcc :++
:   sta f:$400000,x
:   sta f:$410000,x
    inx
    inx
    bne @clr
    lda #$55AA
    sta SH_BOOT
    jml $C10000+GameMain    ; SA-1 code runs from HiROM bank $C1 (64KB)

