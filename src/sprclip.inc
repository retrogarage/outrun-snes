; Pixel-exact hill clipping for the last 16-row sprite band. The ordinary
; image cache stays immutable. Private cells alternate with the OAM frames,
; so neither the displayed frame nor another object can see a masked tile.
; One compound FIFO command copies and masks the private cell in vblank.
; Keep the previous admission charge so faster uploads do not change selection.
CL_MAX = 16
CL_COST = 128 + 6 * RUN_OVH
.segment "BSS"
w_arch:   .res 2                ; composite arch candidate (0 ordinary)
w_clip:   .res 2                ; visible rows in the partial last band (0: none)
cl_n:     .res 4                ; count per frame buffer
cl_cells: .res CL_MAX * 4
cl_side:  .res 2                ; count index (0 / 2)
cl_base:  .res 2                ; cell-list byte offset (0 / CL_MAX*2)
cl_i:     .res 2
cl_end:   .res 2
cl_cell:  .res 2
cl_dst:   .res 2
cl_zero:  .res 2
cl_src:   .res 2
cl_scan:  .res 2
cl_keys:  .res NCELL * 8          ; source, bank/block, band pieces, cut rows
w_lift:   .res 2                ; clipped arch pixels packed at the bottom of 8px tiles
cl_cutkey: .res 2
.ifndef HWLIST
cut_depth: .res 2
cut_base:  .res 2
cut_lo:    .res 2
cut_hi:    .res 2
cut_mid:   .res 2
w_road_cut: .res 2
.endif
.segment "SA1CODE"

.ifndef HWLIST
; The displayed road uses p2; the engine's p0 crest list can be flat
; while a crest is visible. Test the actual rendered road at the sprite's
; projected ground. Only hidden depths need the binary search (at most
; eight reads) for the first nearer road line. Flat-road contacts stay free
; of per-pixel masking and no full per-depth table is rebuilt each frame.
ClipRoadGeom:
    lda #224
    sta w_road_cut
    lda scn_pmode
    beq :+
    clc
    rts
:
    lda w_obj
    and #$007F
    asl a
    asl a
    asl a
    asl a
    asl a
    asl a
    tax
    lda f:JT+OE_ROAD_PRIORITY,x
    beq @done                 ; screen-space entries have no road depth
    cmp #512
    bcs @done
    sta cut_depth
    asl a
    clc
    adc road_p2
    tax
    lda f:RDB*$10000+RD_Y,x
    eor #$8000
    lsr a
    lsr a
    lsr a
    lsr a
    eor #$FFFF
    sec
    adc #223+$800-2           ; two rows above its natural ground contact
    bmi @done
    cmp #224
    bcc :+
    lda #223
:   sta cut_hi
    lda road_p2
    clc
    adc #RD_Y+$0320*2
    sta cut_base
    lda cut_hi
    jsr ClipRoadAt
    cmp cut_depth
    bcc @done
    beq @done
    stz cut_lo
@search:
    lda cut_lo
    cmp cut_hi
    bcs @found
    clc
    adc cut_hi
    lsr a
    sta cut_mid
    jsr ClipRoadAt
    cmp cut_depth
    bcc @far
    beq @far
    lda cut_mid
    sta cut_hi
    bra @search
@far:
    lda cut_mid
    inc a
    sta cut_lo
    bra @search
@found:
    lda cut_lo
    sta w_road_cut
    cmp w_vb
    bcs @done
    sta w_vb
@done:
    clc
    rts
ClipRoadAt:
    asl a
    clc
    adc cut_base
    tax
    lda f:RDB*$10000,x
    cmp #512
    bcc :+
    lda #0                    ; sky / solid fill carries no road depth
:   rts
.else
ClipRoadGeom:
    clc
    rts
.endif

; After CellMasks: recycle only the private cells from two frames ago.
ClipFrame:
    lda sv_frame
    and #1
    asl a
    sta cl_side
    tax
    lda cl_n,x
    asl a
    sta cl_end
    stz cl_n,x
    txa
    asl a
    asl a
    asl a
    asl a
    sta cl_base
    stz cl_i
@next:
    lda cl_i
    cmp cl_end
    bcs @done
    clc
    adc cl_base
    tax
    lda cl_cells,x
    pha
    lda #$FFFF
    sta cl_cells,x
    pla
    bmi @skip
    asl a
    tax
    lda f:CellRow2,x
    tay
    lda f:CellBit2,x
    ora av_free,y
    sta av_free,y
    inc sv_nfc
@skip:
    inc cl_i
    inc cl_i
    bra @next
@done:
    rts

; ClaimPass partial-band piece w_mo: X = private cell * 2, C clear.
; If resources run out, omit the piece rather than draw through the hill.
ClipPiece:
    lda w_lift
    xba
    ora w_clip
    sta cl_cutkey
    lda w_mo
    and #$00FF
    clc
    adc w_cum
    asl a
    asl a
    asl a
    asl a
    asl a
    asl a
    clc
    adc w_src
    sta cl_src
    ; Reuse an identical cut from the displayed frame without modifying
    ; its pixels. Transfer its lifetime to this frame's private-cell list.
    ldx cl_side
    lda cl_n,x
    cmp #CL_MAX
    bcc :+
    sec
    rts
:   lda cl_base
    eor #CL_MAX*2
    sta cl_scan
    pha
    lda cl_side
    eor #2
    tax
    lda cl_n,x
    asl a
    sta cl_end
    pla
    clc
    adc cl_end
    sta cl_end
ClipFind:
    ldx cl_scan
    cpx cl_end
    bcs ClipNew
    lda cl_cells,x
    bmi ClipMore
    sta cl_cell
    asl a
    asl a
    asl a
    tax
    lda cl_keys,x
    cmp cl_src
    bne ClipMore
    lda cl_keys+2,x
    cmp w_srcb
    bne ClipMore
    lda cl_keys+4,x
    cmp w_bn
    bne ClipMore
    lda cl_keys+6,x
    cmp cl_cutkey
    bne ClipMore
    ldx cl_scan
    lda #$FFFF
    sta cl_cells,x
ClipReused:                   ; regression marker; cache hit
    jsr ClipRemember
    lda cl_cell
    asl a
    tax
    clc
    rts
ClipMore:
    inc cl_scan
    inc cl_scan
    bra ClipFind
ClipNew:
    lda w_ne
    beq :+
    sec                        ; loading/partial fallback: no new uploads
    rts
:
    ldx cl_side
    lda cl_n,x
    cmp #CL_MAX
    bcc :+
    sec
    rts
:
    lda w_car
    ora w_arch
    bne :+
    lda sv_dma
    cmp #CL_COST
    bcs :+
    sec
    rts
:
    lda #1
    sta w_t
    jsr AllocRun
    bcc :+
    rts
:
    sta cl_cell
    asl a
    tax
    jsr EvictCell
    lda cl_cell
    asl a
    tax
    lda #$FFFF
    sta f:VC_OWN,x             ; private: never entered into SL_MAP
    lda cl_cell
    asl a
    asl a
    asl a
    tax
    lda cl_src
    sta cl_keys,x
    lda w_srcb
    sta cl_keys+2,x
    lda w_bn
    sta cl_keys+4,x
    lda cl_cutkey
    sta cl_keys+6,x
    jsr ClipRemember
    lda cl_cell
    asl a
    tax
    lda f:CellTile,x
    asl a
    asl a
    asl a
    asl a
    clc
    adc #OBJ_VRAM
    sta cl_dst
    jsr FifoWait
    jsr ClipQueueIndex
    lda cl_dst
    sta f:UQ_BUF+UQ_DEST,x
    lda cl_src
    sta f:UQ_BUF+UQ_SRC,x
    lda w_srcb
    ora #UQ_CLIP << 8
    sta f:UQ_BUF+UQ_BANK,x
    lda w_bn
    xba
    asl a
    asl a
    ora w_clip
    sta cl_zero
    lda w_lift
    beq :+
    lda #UQ_CLIP_PACK
    tsb cl_zero
:   lda cl_zero
    sta f:UQ_BUF+UQ_SIZE,x
    jsr ClipPublish
    lda w_lift
    beq ClipCharged
    ; Packed cuts retain the old extra reservation (selection is identical).
    lda sv_dma
    sec
    sbc #128
    bcs :+
    lda #0
:   sta sv_dma
    lda sv_up
    clc
    adc #128
    sta sv_up
ClipCharged:
    lda sv_dma
    sec
    sbc #CL_COST
    bcs :+
    lda #0
:   sta sv_dma
    lda sv_up
    clc
    adc #CL_COST
    sta sv_up
ClipReady:
    lda cl_cell
    asl a
    tax
    clc
    rts

ClipRemember:
    ldx cl_side
    lda cl_n,x
    inc cl_n,x
    asl a
    clc
    adc cl_base
    tax
    lda cl_cell
    sta cl_cells,x
    ; Reused cells bypass AllocRun, but remain part of the next OAM frame.
    ; Keep them protected until that frame has finished being displayed.
    asl a
    tax
    lda f:CellRow2,x
    tay
    lda f:CellBit2,x
    ora av_now,y
    sta av_now,y
    rts

ClipPublish:
    lda SH_UQW
    inc a
    and #UQ_MASK
    sta SH_UQW
    rts
ClipQueueIndex:
    lda SH_UQW
    asl a
    asl a
    asl a
    tax
    rts
