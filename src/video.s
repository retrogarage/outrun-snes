; SA-1 side video: swap-time upload queue, frame setup
.p816
.smart
.include "sa1.inc"
.include "shared.inc"
.include "globals.inc"
.include "gamevars.inc"
.include "road.inc"

.export LoadLevelPalette, QueueUpload, VideoSa1Init, HiscorePalette
.import RRInit

QOVH = 96                   ; S-CPU cost of a queue entry in DMA byte units

.segment "SA1CODE"

;----------------------------------------------------------------------------
; VideoSa1Init: HDMA table sets, empty upload queue
;----------------------------------------------------------------------------
.a16
.i16
VideoSa1Init:
    jsr RRInit
    stz SH_QN
    stz SH_QBYTES
    rts

;----------------------------------------------------------------------------
; QueueUpload: A = type, X = dest, Y = size, ptr0 = 24-bit source
;----------------------------------------------------------------------------
QueueUpload:
    pha
    phx
    lda SH_QN
    cmp #SH_QMAX
    bcs @full
    asl a
    asl a
    asl a
    tax
    pla
    sta f:SH_Q+Q_DEST,x
    pla
    sep #$20
    .a8
    sta f:SH_Q+Q_TYPE,x
    rep #$20
    .a16
    lda ptr0
    sta f:SH_Q+Q_SRC,x
    sep #$20
    .a8
    lda ptr0+2
    sta f:SH_Q+Q_SRC+2,x
    rep #$20
    .a16
    tya
    sta f:SH_Q+Q_SIZE,x
    inc SH_QN
    ; S-CPU time: bytes + per-entry overhead (RunQueue setup ~0.6 line), so
    ; TrySwap only swaps when the whole queue ends inside vblank
    clc
    adc #QOVH
    clc
    adc SH_QBYTES
    sta SH_QBYTES
    rts
@full:
    plx
    pla
    rts

;----------------------------------------------------------------------------
; LoadLevelPalette / HiscorePalette: replaced by the arcade palette port
;----------------------------------------------------------------------------
LoadLevelPalette:
HiscorePalette:
    rts
