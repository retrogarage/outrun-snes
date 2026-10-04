; Diagnostic only: exercise the original projection at every keyed position.
; tools/check_precomputed.py compares each write against the generated model.
.ifdef NEWGAME
.ifdef ROADKEYCHECK
.segment "BSS"
rk_section: .res 2
rk_pos:     .res 2
.segment "SA1CODE"
.export RoadKeyTest, RoadKeySample, RoadKeyEnd, rk_section, rk_pos
RoadKeyTest:
    jsr ORoadInit
    stz rk_section
RkSection:
    lda rk_section
    jsr PathForSection
    stz rk_pos
RkPosition:
    ldx #446*2+2
    lda #$8000
@clear:
    sta f:RDB*$10000+RD_X,x
    dex
    dex
    bpl @clear
    lda rk_pos
    asl a
    asl a
    clc
    adc path_base
    sta or_ptr
    sep #$20
    .a8
    lda path_base+2
    adc #0
    sta or_ptr+2
    rep #$20
    .a16
    jsr SetupXData
RoadKeySample:
    inc rk_pos
    lda rk_pos
    cmp rx_keycount
    bcc RkPosition
    inc rk_section
    lda rk_section
    cmp #17                 ; the other ending sections share path 16
    bcc RkSection
RoadKeyEnd:
    bra RoadKeyEnd
.endif
.endif
