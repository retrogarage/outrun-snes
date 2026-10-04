; Ending poses layer several arcade sprites over the same car. Their combined
; scanline cost exceeds 34 tiles even with no scenery. Apply one fixed transform
; to the entire cast, including shadows, so positions and poses remain aligned.
; This does not alter the racing camera or the animation/collision simulation.
.ifndef END_SCALE
END_SCALE = 144               ; 9/16, 8.8 fixed point
.endif
.segment "BSS"
end_height: .res 2
.segment "SA1CODE2"
EndCarGeom:
    lda game_state
    cmp #GS_BONUS
    beq :+
    clc
    rtl
:
    lda fer_state
    and #$00FF
    cmp #4
    bne @done
    lda w_obj
    and #$007F
    cmp #SPRITE_FERRARI
    bcc @done
    cmp #SPRITE_FLAG+1
    bcs @done
    lda w_k
    asl a
    tax
    lda f:SprKH,x
    jsr EndMul
    sta end_height
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
    cmp end_height
    beq @found
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
    jsr EndMul
    sta w_we
    lda w_he
    jsr EndMul
    sta w_he
    lda w_xa
    sec
    sbc #128
    jsr EndMul
    clc
    adc #128
    sta w_xa
    lda w_top
    jsr EndY
    sta w_top
    lda w_vb
    cmp #224
    bcs @done
    jsr EndY
    sta w_vb
@done:
    clc
    rtl
EndY:
    sec
    sbc #200
    jsr EndMul
    clc
    adc #200
    rts
EndMul:
    sta MAL
    lda #END_SCALE
    sta MBL
    nop
    nop
    lda MR+1
    rts
.segment "SA1CODE"
