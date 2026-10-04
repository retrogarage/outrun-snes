; Compound private-cell uploads. One FIFO entry / descriptor owns the whole
; copy and mask, so it is never published or acknowledged partway through.
; Admission still charges the legacy cost (sprclip.inc); the stream uses
; conservative transfer costs including handler setup and DRAM refresh.
; A packed cut duplicates its visible plane pairs into the unused lower
; tiles too, exactly matching the original zero-stride sprite-run uploads.
.segment "SBSS"
ex_cdst:    .res 2
ex_csrc:    .res 2
ex_cbank:   .res 2
ex_cstride: .res 2
ex_crows:   .res 2
ex_cpack:   .res 2
ex_csize:   .res 2
.segment "RODATA"
StreamBlank: .res 64, 0
.segment "NMICODE"

; [handler][EXB|FXB][dest][src][bank][band byte stride][rows|packed].
; 14 bytes: smaller than the existing maximum descriptor (18 bytes).
ConvClip:
    sta z:cv_t
    xba
    and #7
    sta z:cv_lblk
    ora #FXB_RESET << 8
    sta a:2,y
    lda f:UQ_BUF+UQ_DEST,x
    sta a:4,y
    lda f:UQ_BUF+UQ_SRC,x
    sta a:6,y
    lda z:cv_t
    and #$00FF
    sta a:8,y
    lda f:UQ_BUF+UQ_SIZE,x
    pha
    and #$FC00
    lsr a
    lsr a
    lsr a
    lsr a
    sta a:10,y
    pla
    and #$001F
    sta a:12,y
    asl a
    tax
    lda a:ClipCosts,x
    ldx #14
    stx z:cv_t
    ldx #H_CLIP-1
    jmp ConvFin

; The converter may be idle when a command reaches the NMI. Execute the
; same uploader directly, with a separate bound for Direct's extra setup.
DirectClip:
    lda f:UQ_BUF+UQ_SIZE,x
    and #$001F
    asl a
    tay
    lda a:ClipCosts,y
    clc
    adc #DIR_OVH
    sta z:cv_t
    phx
    jsr ReadAvail
    plx
    cmp z:cv_t
    bcs :+
    clc
    rts
:   lda z:ex_ch0
    bne :+
    inc z:ex_ch0
    lda #$0080
    sta VMAIN
    lda #<VMDATAL << 8 | $01
    sta DMAP0
:   lda f:UQ_BUF+UQ_BANK,x
    and #$00FF
    sta a:ex_cbank
    lda f:UQ_BUF+UQ_BANK,x
    xba
    and #7
    sta z:cv_lblk
    ora #FXB_RESET << 8
    sta EXB
    lda f:UQ_BUF+UQ_DEST,x
    sta a:ex_cdst
    lda f:UQ_BUF+UQ_SRC,x
    sta a:ex_csrc
    lda f:UQ_BUF+UQ_SIZE,x
    pha
    and #$FC00
    lsr a
    lsr a
    lsr a
    lsr a
    sta a:ex_cstride
    pla
    jsr ClipParams
    phd
    lda #$4300
    tcd
    ldx a:ex_trig
    jsr ClipUpload
    pld
    sec
    rts

H_CLIP:
    pla
    sta a:EXB
    pla
    sta a:ex_cdst
    pla
    sta a:ex_csrc
    pla
    sta a:ex_cbank
    pla
    sta a:ex_cstride
    pla
    ; Inline the two fields: do not push return addresses onto the stream's
    ; descriptor stack. ClipUpload returns straight to the next handler.
    sta a:ex_cpack
    and #15
    sta a:ex_crows
    jmp ClipUpload

; Direct helper (ordinary stack / D=0).
ClipParams:
    sta a:ex_cpack
    and #15
    sta a:ex_crows
    rts

; D=$4300; X=MDMAEN|HDMAEN. Uses only executor scratch: the converter can
; have been interrupted in the middle of a different FIFO command.
ClipUpload:
    lda a:ex_cpack
    bit #UQ_CLIP_PACK
    beq :+
    jmp @packed
:   lda a:ex_cbank
    sta z:<A1B0
    lda a:ex_cdst
    sta a:VMADDL
    lda a:ex_csrc
    sta z:<A1T0L
    lda #64
    sta z:<DAS0L
    stx a:MDMAEN
    lda a:ex_cdst
    clc
    adc #$100
    sta a:VMADDL
    lda a:ex_csrc
    clc
    adc a:ex_cstride
    sta z:<A1T0L
    lda #64
    sta z:<DAS0L
    stx a:MDMAEN
    ; All following transfers in the ordinary path read transparent ROM.
    stz z:<A1B0
    lda a:ex_crows
    cmp #9
    bcs @bottom
    lda a:ex_cdst
    clc
    adc #$100
    sta a:VMADDL
    lda #StreamBlank
    sta z:<A1T0L
    lda #64
    sta z:<DAS0L
    stx a:MDMAEN
    lda a:ex_crows
    cmp #8
    bne @partial
    jmp ClipUploadDone
@bottom:
    lda a:ex_cdst
    clc
    adc #$100
    sta a:ex_cdst
@partial:
    lda a:ex_crows
    and #7
    clc
    adc a:ex_cdst
    sta a:ex_cdst
    lda a:ex_crows
    and #7
    eor #$FFFF
    sec
    adc #8
    asl a
    sta a:ex_csize
    ldy #4
@zero:
    lda a:ex_cdst
    sta a:VMADDL
    lda #StreamBlank
    sta z:<A1T0L
    lda a:ex_csize
    sta z:<DAS0L
    stx a:MDMAEN
    lda a:ex_cdst
    clc
    adc #8
    sta a:ex_cdst
    dey
    bne @zero
    jmp ClipUploadDone
@packed:
    stz z:<A1B0
    lda a:ex_cdst
    sta a:VMADDL
    lda #StreamBlank
    sta z:<A1T0L
    lda #64
    sta z:<DAS0L
    stx a:MDMAEN
    lda a:ex_cdst
    clc
    adc #$100
    sta a:VMADDL
    lda #StreamBlank
    sta z:<A1T0L
    lda #64
    sta z:<DAS0L
    stx a:MDMAEN
    lda a:ex_cbank
    sta z:<A1B0
    lda #8
    sec
    sbc a:ex_crows
    clc
    adc a:ex_cdst
    sta a:ex_cdst
    lda a:ex_crows
    asl a
    sta a:ex_csize
    ldy #4
@plane:
    lda a:ex_cdst
    sta a:VMADDL
    lda a:ex_csrc
    sta z:<A1T0L
    lda a:ex_csize
    sta z:<DAS0L
    stx a:MDMAEN
    lda a:ex_cdst
    clc
    adc #$100
    sta a:VMADDL
    lda a:ex_csrc
    sta z:<A1T0L
    lda a:ex_csize
    sta z:<DAS0L
    stx a:MDMAEN
    lda a:ex_cdst
    clc
    adc #8
    sta a:ex_cdst
    lda a:ex_csrc
    clc
    adc #16
    sta a:ex_csrc
    dey
    bne @plane
    jmp ClipUploadDone
ClipUploadDone:              ; every DMA is complete; regression timing marker
    rts
ClipUploadEnd:               ; exclusive end; timing regression probe

ClipCosts:
    ; Mesen worst-case probes retain at least 50 units of handler margin.
    ; Ordinary cuts: copy (128 bytes), optional blank lower half (64),
    ; then four row patches. Handler overhead bounds include DMA startup.
    .word 0                 ; row zero is never queued
    .repeat 15, I
      .if I+1 < 8
        .word 300 + 60 + 4*55 + ((128+64+8*(7-I))*33+31)/32
      .elseif I+1 = 8
        .word 300 + 60 + (192*33+31)/32
      .else
        .word 300 + 4*55 + ((128+8*(15-I))*33+31)/32
      .endif
    .endrepeat
    .word 0                 ; packed row zero is never queued
    .repeat 7, I
      .word 714 + ((128+16*(I+1))*33+31)/32
    .endrepeat
    .res 16, 0              ; packed rows 8-15 are invalid
