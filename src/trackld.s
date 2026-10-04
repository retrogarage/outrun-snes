; TrackLoader: CPU 0 track data access - port of trackloader.cpp (classic
; arcade tracks from rom0: TrkSections from tools/mkgame.py).  The road
; CPU side (paths) is in oroad.s.
.ifdef NEWGAME
.p816
.smart
.include "sa1.inc"
.include "globals.inc"
.include "ogame.inc"
.include "gametab.inc"

.importzp rp0
.import R0Set

.export TrkInitTrack, TrkInitTrackSplit, TrkInitTrackBonus, TrkReadWidthHeight
.export TrkReadCurve, TrkStageToLevel
.export trk_curve, trk_curve_off, trk_wh, trk_wh_off, trk_scenery, trk_scenery_off
.export trk_level

.segment "BSS"
trk_level:       .res 2     ; section index of current_level
trk_curve:       .res 4     ; rom0 address of the level's tables
trk_wh:          .res 4
trk_scenery:     .res 4
trk_curve_off:   .res 2
trk_wh_off:      .res 2
trk_scenery_off: .res 2

.segment "SA1CODE"
.a16
.i16

; TrkStageToLevel: A = stage lookup offset -> A = level (0-14)
TrkStageToLevel:
    pha
    lsr a
    lsr a
    lsr a
    and #7
    asl a
    tax
    pla
    and #7
    clc
    adc f:TrkIdOffset,x
    rts

; init_track: A = stage lookup offset
TrkInitTrack:
    jsr TrkStageToLevel
    bra SetSection
; init_track_split
TrkInitTrackSplit:
    lda #TRK_SPLIT
    bra SetSection
; init_track_bonus: A = end id (0-4)
TrkInitTrackBonus:
    clc
    adc #TRK_END0
SetSection:
    sta trk_level
    stz trk_curve_off
    stz trk_wh_off
    stz trk_scenery_off
    asl a
    sta rp0                 ; *12
    asl a
    clc
    adc rp0
    asl a
    tax
    lda f:TrkSections,x
    sta trk_curve
    lda f:TrkSections+2,x
    sta trk_curve+2
    lda f:TrkSections+4,x
    sta trk_wh
    lda f:TrkSections+6,x
    sta trk_wh+2
    lda f:TrkSections+8,x
    sta trk_scenery
    lda f:TrkSections+10,x
    sta trk_scenery+2
    rts

; read_width_height: A = addr (byte offset) -> A = word at wh + addr + wh_offset
TrkReadWidthHeight:
    clc
    adc trk_wh_off
    clc
    adc trk_wh
    pha
    lda trk_wh+2
    adc #0
    tay
    pla
    jsr R0Set
    lda [rp0]
    xba
    rts

; read_curve: A = addr -> A = word at curve + addr + curve_offset
TrkReadCurve:
    clc
    adc trk_curve_off
    clc
    adc trk_curve
    pha
    lda trk_curve+2
    adc #0
    tay
    pla
    jsr R0Set
    lda [rp0]
    xba
    rts

.segment "RODATA"
TrkIdOffset: .word 0, 1, 3, 6, 10, 10, 10, 10
.endif
