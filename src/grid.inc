; Keep the arrival car within a console-sized footprint. The three layered
; animation objects share one transform, so passengers stay inside the car.
.import game_state
.segment "BSS"
grid_full: .res 128          ; warmup: complete on-screen pieces, not partial bands
grid_scale: .res 2
grid_cx: .res 2
grid_oldw: .res 2
.segment "SA1CODE"
GridCarGeom:
    lda game_state
    cmp #GS_START1
    bcc @done
    cmp #GS_INGAME+1
    bcs @done
    lda w_obj
    cmp #SPRITE_FLAG
    beq @flat
    cmp #68
    bcs @carcheck
    cmp #46
    beq @done               ; banner geometry belongs to the BG renderer
    cmp #47
    beq @done
    asl a
    tax
    lda grid_decor,x
    cmp #1
    beq @flat
    lda grid_warm
    beq :+
    cpx #44*2
    beq @flat
    cpx #45*2
    beq @flat
:   lda grid_people,x
    cmp #1
    bne @carcheck
@flat:
    ; Original start residents remain on flat ground until passed, even
    ; after green. Quantized feet are not hills: avoid private masks that
    ; duplicate their cached art while the player waits at the line.
    lda #224
    sta w_vb
    rts
@carcheck:
    lda game_state
    cmp #GS_START1
    bne @done
    lda w_obj
    cmp #SPRITE_FERRARI
    beq @car
    cmp #SPRITE_PASS1
    beq @apply
    cmp #SPRITE_PASS2
    beq @apply
@done:
    rts
@car:
    lda #256
    sta grid_scale
    lda w_we
    cmp #81
    bcc @done
    sta grid_oldw
    lsr a
    ldx w_rtl
    beq :+
    eor #$FFFF
    inc a
:   clc
    adc w_xa
    sta grid_cx
    lda #80*256
    ldx grid_oldw
    jsr SDiv16u
    sta grid_scale
@apply:
    lda grid_scale
    cmp #256
    beq @done
    lda w_k
    asl a
    tax
    ; Hz is inverse scale. KH is proportional to scale: find the nearest
    ; stored zoom at or below the desired scale, keeping all three layers.
    lda f:SprKH,x
    jsr GridMul
    sta grid_oldw
    ldx w_k
@zoom:
    cpx #127
    beq @found
    phx
    txa
    asl a
    tax
    lda f:SprKH,x
    plx
    cmp grid_oldw
    bcc @found
    inx
    bra @zoom
@found:
    stx w_k
    txy
    lda [mp],y
    and #$00FF
    asl a
    clc
    adc #128
    tay
    lda [mp],y
    sta w_img
    lda w_we
    jsr GridMul
    sta w_we
    lda w_he
    jsr GridMul
    sta w_he
    lda w_xa
    sec
    sbc grid_cx
    jsr GridMul
    clc
    adc grid_cx
    sta w_xa
    lda w_top
    sec
    sbc #200
    jsr GridMul
    clc
    adc #200
    sta w_top
    rts
GridMul:
    sta MAL
    lda grid_scale
    sta MBL
    nop
    nop
    lda MR+1
    rts

; Both start lights change together. Otherwise the one-tick arcade stagger
; needs a ninth OBJ palette and evicts every palm while a light changes.
GridPalette:
    lda game_state
    cmp #GS_START1
    bcc @done
    cmp #GS_GAMEOVER+1
    bcs @done
    ; Keep the shared tower palette through green and while waiting at
    ; the line. Stop once the original start object slot is recycled.
    lda f:JT+44*64+OE_CONTROL
    and #C_ENABLE
    beq @done
    lda grid_warm
    bne :+
    lda grid_decor+44*2
    cmp #1
    bne @done
:   lda f:JT+44*64+OE_PAL_SRC
    and #$FF
    sta grid_oldw
    ; A palette animation replaces the towers' existing slot at the swap.
    ; LRU replacement would evict the palms before finding the now-unused
    ; old light palette, despite both lights sharing one palette this frame.
    ldx #14
@slot:
    lda slot_pal,x
    cmp #122
    bcc @nextslot
    cmp #126
    bcs @nextslot
    cmp grid_oldw
    beq @ready
    stx w_u+2
    cpx pp_slot
    bne :+
    lda #$FFFF             ; discard only a pending reuse of this same slot
    sta pp_slot
:   lda grid_oldw
    jsr LoadPal
    bra @ready
@nextslot:
    dex
    dex
    bpl @slot
@ready:
    lda sprite_count
    asl a
    tax
@entry:
    dex
    dex
    bmi @done
    lda f:hw_ent,x
    cmp #44
    beq @sync
    cmp #45
    bne @entry
@sync:
    lda grid_oldw
    sta f:hw_pal,x
    bra @entry
@done:
    rts
