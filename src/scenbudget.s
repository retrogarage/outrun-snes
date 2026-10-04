; Console scenery density: omit repeated decorations at spawn time, so their
; collision entries disappear with them. Landmarks, people, continuous terrain,
; gameplay triggers and complete arch groups retain their original patterns.
.ifdef NEWGAME
.p816
.smart
.include "ogame.inc"
.include "shared.inc"
.export SceneKeep, SceneInit
.import seg_pos

; Reserved gap between the renderer's drop counters ($40E200..E2FF) and
; trap record ($40E7F0). 256 types x two road sides x a 16-bit road position.
.assert SCENE_LAST+SCENE_SIZE <= $40E7F0, error, "scenery history overlaps sprite traps"
.segment "BSS"
scene_prev: .res 2
scene_gap: .res 2
.segment "SA1CODE2"
.a16
.i16
SceneInit:
    jsr SceneReset
    rtl
SceneReset:
    phx
    lda #$8000
    ldx #SCENE_SIZE-2
:   sta f:SCENE_LAST,x
    dex
    dex
    bpl :-
    stz scene_prev
    plx
    rts

; A = source flags, X = engine entry byte offset. C set: omit decoration.
; A stage/split/ending resets its road position; reset the spacing history too.
SceneKeep:
    pha
    lda seg_pos
    cmp scene_prev
    bcs :+
    jsr SceneReset
:   lda seg_pos
    sta scene_prev
    pla
    and #$00F0
    beq @decor
    cmp #$0070
    beq @decor
    cmp #$0080
    beq @decor
    cmp #$0090
    bne @keep
@decor:
    phx
    LDE OE_TYPE
    lsr a
    tay
    phx
    tyx
    lda f:$CF0000+SceneSpacing,x
    plx
    beq @keepx
    sta scene_gap
    LDE OE_XW1
    bpl :+
    tya
    clc
    adc #512
    tay
:   tyx
    lda seg_pos
    sec
    sbc f:SCENE_LAST,x
    cmp scene_gap
    bcc @omit
    lda seg_pos
    sta f:SCENE_LAST,x
@keepx:
    plx
@keep:
    clc
    rtl
@omit:
    plx
    sec
    rtl
.include "scenspacing.inc"
.endif
