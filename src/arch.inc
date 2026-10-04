; One logical Gateway arch: one image/scale/origin owns both pillars and
; the roof. The engine's original four entries retain their collisions.
; The first pillar is its fixed representative, even outside the viewport.
; Roofs prefer a BG strip measured from the same image; a whole OBJ image
; is available where the road layers cannot share that strip.
.import arch_group, arch_root
.import road_width
.segment "BSS"
arc_fullh: .res 2            ; height including the BG roof
arc_yoff: .res 2             ; signed top offset; OBJ bands end exactly at the feet
arc_objmap: .res 2           ; selected the full OBJ map as a layer fallback
arc_bg: .res 2               ; selected image stores its roof on BG
arch_posted: .res 2          ; road inputs already handed to the S-CPU
arch_count: .res 2             ; selected groups
arch_ids:   .res 64*2
arch_active: .res 128          ; per hardware entry: 0 ordinary, 1 arch root
arc_rec:   .res 2
arc_pass:  .res 2
arc_group: .res 2
arc_oldw:  .res 2
arc_oldh:  .res 2
arc_oldtop: .res 2
arc_kind:  .res 2
arc_delta: .res 2
arc_center: .res 2
arc_span: .res 2
arc_zoom: .res 2
w_arch_min: .res 2
.segment "SA1CODE"

ArchPrepare:
    stz arch_posted
    stz arch_count
    ldx #126
:   stz arch_active,x
    dex
    dex
    bpl :-
    lda scn_pmode
    beq :+
    rts
:   lda sprite_count
    asl a
    asl a
    asl a
    asl a
    sta arc_rec
@entry:
    lda arc_rec
    sec
    sbc #16
    bmi @done
    sta arc_rec
    lsr a
    lsr a
    lsr a
    tax
    lda f:hw_ent,x
    and #$007F
    asl a
    tax
    lda arch_group,x
    beq @entry
    ; Slot reuse clears membership. All four collision parts stay in the
    ; engine, but only the first pillar can own geometry and cache history.
    lda arch_root,x
    beq @hide
    ldx arc_rec
    lda f:REC_BASE+RR_D0,x
    bit #$5000
    bne @entry
    lda f:REC_BASE+RR_FL,x
    bit #$0080
    bne @hide
    lda arc_rec
    lsr a
    lsr a
    lsr a
    lsr a
    tax
    sep #$20
    .a8
    lda #1
    sta arch_active,x
    rep #$20
    .a16
    inc arch_count
    bra @entry
@hide:
    ldx arc_rec
    lda f:REC_BASE+RR_D0,x
    ora #$4000
    sta f:REC_BASE+RR_D0,x
    bra @entry
@done:
    rts

; CandRaw has decoded the original part, including its offscreen top and
; hill clipping. Convert that anchor into the one composite's geometry.
ArchGeom:
    stz w_arch
    ldx w_i
    lda arch_active,x
    and #$00FF
    bne :+
    clc
    rts
:   sta arc_kind
    sta w_arch
    lda w_we
    sta arc_oldw
    lda w_he
    sta arc_oldh
    lda w_top
    sta arc_oldtop
    lda w_dsc
    sec
    sbc f:SPR_META+417*10
    ldx arc_kind
    cpx #1
    beq :+
    sec
    sbc #5*18
:   clc
    adc f:SPR_META+ARCH_D*10
    sta w_dsc
    lda w_i
    asl a
    tax
    lda f:hw_pal,x
    and #$00FF
    cmp #$A2
    bne :+
    lda w_dsc
    clc
    adc #5*18
    sta w_dsc
    bra @size
:   cmp #$C6
    bne @size
    lda w_dsc
    clc
    adc #10*18
    sta w_dsc
@size:
    lda w_dsc
    tax
    lda f:DR,x
    sta MAL
    lda w_k
    asl a
    tax
    lda f:SprKW,x
    sta MBL
    nop
    nop
    lda MR+1
    clc
    adc #63
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    sta w_we
    ldx w_dsc
    lda f:DR+2,x
    sta MAL
    lda w_k
    asl a
    tax
    lda f:SprKH,x
    sta MBL
    nop
    nop
    lda MR+1
    clc
    adc #31
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    sta w_he
    lda w_obj
    and #$007F
    .repeat 6
    asl a
    .endrepeat
    tax
    lda f:JT+OE_Y,x
    sec
    sbc w_he
    sta w_top
    lda #224
    sta w_vb               ; ClipRoadGeom applies the displayed road's crest
    jsr ArchCenter
    stz w_rtl
    stz w_mir
    stz w_cls
    stz w_pc
    ; Choose from the BG map first, then check the stored level's actual
    ; bounds. Exact-size estimates can straddle the road-layer boundary.
    stz arc_objmap
    lda ohb_res
    beq @objmap
@bgmap:
    ldx w_dsc
    lda f:DR+12,x
    sta mp
    lda f:DR+16,x
    bra @mapbank
@objmap:
    inc arc_objmap
    ldx w_dsc
    lda f:DR+8,x
    sta mp
    lda f:DR+14,x
@mapbank:
    sep #$20
    .a8
    sta mp+2
    rep #$20
    .a16
    lda w_k
    sta arc_zoom
@level:
    ldy arc_zoom
    lda [mp],y
    and #$00FF
    asl a
    clc
    adc #128
    tay
    lda [mp],y
    sta w_img
    ; The opening must span the actual roadside anchors. A smaller cached
    ; image cannot be allowed to pull a pillar into the driving lanes.
    xba
    lsr a
    lsr a
    lsr a
    and #$001F
    clc
    adc #SPR_IMGB
    sep #$20
    .a8
    sta ip+2
    rep #$20
    .a16
    lda w_img
    asl a
    asl a
    asl a
    asl a
    ora #$8000
    sta ip
    lda [ip]
    cmp w_arch_min
    bcs @chosen
    lda arc_zoom
    beq @chosen
    dec arc_zoom
    bra @level
@chosen:
    lda arc_objmap
    bne @ready
    ldy #2
    lda [ip],y
    sta arc_fullh
    jsr ArchHeight
    clc
    adc w_top
    clc
    adc w_he
    sec
    sbc arc_fullh           ; same bottom anchor as PlaceImg
    bmi @ready
    cmp ohb_lim
    bcc @ready
    beq @ready
    jmp @objmap
@ready:
    clc
    rts

; Project the road centre at this representative's depth. The original
; pillars sit at world x +/-320; a positive road width separates the roads.
; This works even when only one original part remains inside the viewport.
ArchCenter:
    lda w_obj
    and #$007F
    asl a
    asl a
    asl a
    asl a
    asl a
    asl a
    tax
    stz arc_delta
    lda f:JT+OE_CONTROL,x
    and #C_WIDE_ROAD
    bne :+
    lda road_width+2
    sta arc_delta
:   lda f:JT+OE_XW1,x
    bpl :+
    eor #$FFFF
    inc a
:   clc
    adc arc_delta
    sta MAL
    lda f:JT+OE_ROAD_PRIORITY,x
    sta MBL
    nop
    nop
    lda MR+1
    lsr a
    sta arc_center
    lda f:JT+OE_XW1,x
    bmi @left
    lda f:JT+OE_X,x
    sec
    sbc arc_center
    bra @centre
@left:
    lda f:JT+OE_X,x
    clc
    adc arc_center
@centre:
    clc
    adc #162
    jsr ArchX08
    sta arc_center
    lda arc_delta
    clc
    adc #320
    sta MAL
    lda f:JT+OE_ROAD_PRIORITY,x
    sta MBL
    nop
    nop
    lda MR+1              ; twice the half-span: product >> 8
    jsr ArchX08
    sta arc_span
    lda w_we
    sta MAL
    lda #88
    sta MBL
    nop
    nop
    lda MR
    ldx #ARCH_W
    jsr SDiv16u           ; pillar width at the exact projected scale
    clc
    adc arc_span
    sta w_arch_min
    lda w_we
    lsr a
    sta arc_delta
    lda arc_center
    sec
    sbc arc_delta
    sta w_xa
    rts
ArchX08:
    sta MAL
    lda #3277
    sta MBL
    nop
    nop
    lda MR+1
    .repeat 4
    cmp #$8000
    ror a
    .endrepeat
    rts

; Admit a wide composite only if its entire visible roof can use BG. This
; is checked for every fallback too, before committing any OBJ pieces.
ArchFits:
    lda w_arch
    beq @yes
    lda w_w
    cmp w_arch_min
    bcc @no
    lda arc_bg
    beq @yes
    jsr ArchHeight
    clc
    adc w_y
    sec
    sbc arc_yoff
    bmi @yes                ; roof has already passed above the viewport
    cmp w_vb
    bcc :+
    lda w_vb
:   cmp ohb_lim
    bcc @resident
    beq @resident
    sec
    rts
@resident:
    lda ohb_res
    beq @no
@yes:
    clc
    rts
@no:
    sec
    rts

ArchHeight:
    lda arc_fullh
    sta MAL
    lda #ARCH_BEAM
    sta MBL
    nop
    nop
    lda MR
    clc
    adc #ARCH_H-1
    ldx #ARCH_H
    jmp SDiv16u

; Called after Show: add the wide roof only when the composite pillars were
; admitted together, or both pillars are outside the viewport. No roof
; geometry comes from a separately scaled/cached engine sprite.
ArchDraw:
    lda w_arch
    bne :+
    rts
:
    lda arc_bg
    bne :+
    rts                     ; this selected image contains its own roof
:
    lda ohb_res
    bne :+
    rts
:
    lda w_nst
    and #ST_SHOWN
    bne @draw
    lda w_npc
    beq :+
    rts
:
    lda w_skip
    beq :+
    rts
:
@draw:
    jsr ArchHeight
    sta arc_delta            ; roof height at the SELECTED image level
    clc
    adc w_y
    sec
    sbc arc_yoff
    bpl :+
    rts
:
    cmp w_vb
    bcc :+
    lda w_vb
:   cmp ohb_lim
    bcc :+
    beq :+
    rts
:
    cmp #0
    bne :+
    rts                     ; roof has just passed above the first line
:   sta w_t
    ldx ohb_na
    cpx #OHB_MAXA*32
    bcc :+
    rts
:
    lda w_y
    sec
    sbc arc_yoff
    sta f:OHB_A+P_TOP,x
    lda w_t
    sta f:OHB_A+P_BOT,x
    lda w_x
    sta f:OHB_A+P_X0,x
    sta w_u
    clc
    adc w_w
    dec a
    sta f:OHB_A+P_X1,x
    sta w_u+2
    jsr OhbWin
    sta f:OHB_A+P_WIN,x
    lda w_x
    eor #$FFFF
    inc a
    and #$03FF
    sta f:OHB_A+P_HOFS,x
    lda #1
    sta f:OHB_A+P_DRAWN,x
    lda #0
    sta f:OHB_A+P_RB,x
    sta f:OHB_A+P_RTL,x
    lda #$FFFF
    sta f:OHB_A+P_PART,x
    sta f:OHB_A+P_VB,x
    phx
    ldx arc_delta
    lda #47*256
    jsr SDiv16u
    plx
    sta f:OHB_A+P_STEP,x
    ; OhbPaint walks far to near; store the hardware index for sorting.
    lda w_i
    sta f:OHB_A+P_DSC,x
    asl a
    tax
    lda f:hw_pal,x
    and #$00FF
    cmp #$61
    bne :+
    lda #$5F
    bra @pal
:   cmp #$A2
    bne :+
    lda #$A1
    bra @pal
:   cmp #$C6
    bne @pal
    lda #$C4
@pal:
    jsr OhbPalSource
    lda ohb_na
    clc
    adc #32
    sta ohb_na
@done:
    rts

ArchFinish:
    lda arch_count
    beq @done
    ; Sprite admission is by importance. Restore depth order for BG paint.
    ldx #0
@outer:
    cpx ohb_na
    bcs @paint
    stx arc_rec
    txa
    clc
    adc #32
    tay
@inner:
    cpy ohb_na
    bcs @next
    tyx
    lda f:OHB_A+P_DSC,x
    ldx arc_rec
    cmp f:OHB_A+P_DSC,x
    bcs @inext
    ; Swap all sixteen words; use a separate counter (w_i).
    sty arc_delta
    lda #16
    sta w_i
@swap:
    ldx arc_rec
    lda f:OHB_A,x
    sta w_t
    tyx
    lda f:OHB_A,x
    ldx arc_rec
    sta f:OHB_A,x
    tyx
    lda w_t
    sta f:OHB_A,x
    iny
    iny
    inc arc_rec
    inc arc_rec
    dec w_i
    bne @swap
    lda arc_rec
    sec
    sbc #32
    sta arc_rec
    ldy arc_delta
@inext:
    tya
    clc
    adc #32
    tay
    bra @inner
@next:
    lda arc_rec
    clc
    adc #32
    tax
    bra @outer
@paint:
    jsr OhbPaint
    jsr OhbLines
@done:
    rts

