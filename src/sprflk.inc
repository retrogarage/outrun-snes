; [W1b flicker] sprite flicker statistics (FLKSTAT builds only; included by
; sprv3.s).  Per rendered frame, per hardware entry: on screen (its exact
; rectangle overlaps the screen by 8+ px) and shown (OAM entries written).
; A toggle = an object (hw_ent value) on screen in two consecutive rendered
; frames whose shown status differs.  Counters in BW-RAM (read by
; w1b_tools/flk.py from snesrun SRAM dumps):
FLK_RING = $40E300      ; 32 events (word frame, word obj | why << 8, word area / 8, 0)
                        ; (fl_prev, BSS: per object (word): frame & $FF | state << 8)
FLK_CNT  = $40E700      ; 32-bit: +0 frames, +4 toggles, +8 frames with
                        ; toggles, +12 shown, +16 on screen, +20 shown->not,
                        ; +24 not->shown; 16-bit: +28 max per frame, +30 ring
                        ; index, +32 (set: counters valid)

.macro FLINC32 addr
    lda f:addr
    clc
    adc #1
    sta f:addr
    lda f:addr+2
    adc #0
    sta f:addr+2
.endmacro

.segment "BSS"
fl_st:      .res 128            ; per hw entry this frame: 1 on screen, 2 shown
fl_sz:      .res 128            ; ... size class * 4 (exact area / 8 < 8 / 64 / 512 / more)
fl_ar:      .res 256            ; ... exact area / 8
fl_n:       .res 2
fl_cnt:     .res 2
fl_buf:     .res 2              ; FLKREC: this frame's record buffer ($000 / $400)
fl_prev:    .res 512            ; per object (word): frame & $FF | state << 8
fl_ltg:     .res 512            ; per object: frame of its last toggle
fl_otg:     .res 512            ; per object: toggles (shown -> not by reason in fl_orw)
fl_ons:     .res 512            ; per object: frame its time on screen began
fl_orw:     .res 512            ; per object: last reason of a shown -> not
.ifdef FLKREC
fl_shi:     .res 256            ; per hw entry: image shown ($FFFF none)
fl_fb:      .res 128            ; ... its w_fb | 0
fl_nw:      .res 128            ; ... w_new when refused
fl_dq:      .res 16             ; objects asking for cells (sv_debt), 8 at most
fl_dn:      .res 2
.endif

.segment "SA1CODE"
FlBegin:
    .ifdef FLKREC
    lda sv_frame                ; (entry records: this frame's buffer cleared)
    and #1
    xba
    asl a
    asl a                       ; $400 * parity
    sta fl_buf
    clc
    adc #$3FE
    tax
    ldy #$200
    lda #$FFFF
:   sta f:FLK_ENT,x
    dex
    dex
    dey
    bne :-
    .endif
    lda f:FLK_CNT+32
    cmp #$F1C0
    beq :+
    ldx #30                     ; (first frame: counters cleared)
    lda #0
@c: sta f:FLK_CNT,x
    dex
    dex
    bpl @c
    sta f:FLK_CNT+36
    sta f:FLK_CNT+38
    ldx #62
@w: sta f:$40E760,x
    dex
    dex
    bpl @w
    ldx #18
@z: sta f:$40E7A0,x
    dex
    dex
    bpl @z
    ldx #510
@g: sta fl_ltg,x
    sta fl_ons,x
    sta fl_otg,x
    sta fl_orw,x
    dex
    dex
    bpl @g
    ldx #510
@p: sta fl_prev,x
    dex
    dex
    bpl @p
    lda #$F1C0
    sta f:FLK_CNT+32
:   ldx #126
:   stz fl_st,x
    .ifdef FLKREC
    stz fl_fb,x
    stz fl_nw,x
    .endif
    dex
    dex
    bpl :-
    .ifdef FLKREC
    ldx #254
    lda #$FFFF
:   sta fl_shi,x
    dex
    dex
    bpl :-
    stz fl_dn
    ldx #14
:   sta fl_dq,x
    dex
    dex
    bpl :-
    .endif
    rts

; FlOs: entry w_i after CandGeom: on screen?  (+ its record at FLK_ENT)
FLK_ENT = $40D800       ; FLKREC: per hw entry (8 bytes): obj | (rtl | mir << 1 | mode << 2) << 8,
                        ; img, xa, top; two buffers ($000 / $400 by frame parity); $40E740: frame,
                        ; buffer of the last complete frame; $40E600 / $40E680: its fl_st / sv_why
FlOs:
    .ifdef FLKREC
    lda w_i
    asl a
    asl a
    asl a
    ora fl_buf
    tax
    lda w_cls
    asl a
    asl a
    ora w_rtl
    ldy w_mir
    beq :+
    ora #2
:   xba
    ora w_obj
    sta f:FLK_ENT,x
    lda w_img
    sta f:FLK_ENT+2,x
    lda w_xa
    sta f:FLK_ENT+4,x
    lda w_top
    sta f:FLK_ENT+6,x
    .endif
    lda w_xa
    ldx w_rtl
    beq :+
    sec
    sbc w_we
    inc a                       ; (right to left: x0 = xa - We + 1)
:   cmp #240
    bpl @no
    clc
    adc w_we
    cmp #17
    bmi @no
    lda w_top
    cmp #216
    bpl @no
    clc
    adc w_he
    ldx w_vb
    cpx #$7FFF
    beq :+
    cmp w_vb
    bmi :+
    lda w_vb
:   cmp #9
    bmi @no
    lda w_we                    ; (size class)
    sta MAL
    lda w_he
    sta MBL
    nop
    nop
    lda MR
    pha
    lsr a
    lsr a
    lsr a
    pha
    lda w_i
    asl a
    tax
    pla
    sta fl_ar,x
    pla
    ldy #0
    cmp #64
    bcc :+
    ldy #4
    cmp #512
    bcc :+
    ldy #8
    cmp #4096
    bcc :+
    ldy #12
:   ldx w_i
    tya
    sep #$20
    .a8
    sta fl_sz,x
    lda fl_st,x
    ora #1
    sta fl_st,x
    rep #$20
    .a16
@no:
    rts

; FlSkip: entry w_i not placed this frame (ProcSkip): on screen as the last
; frame (its object's FLK state), not shown
FlSkip:
    lda w_obj
    asl a
    tax
    lda fl_prev,x
    inc a
    eor sv_frame
    and #$00FF
    bne :+                      ; (not seen the last frame)
    lda fl_prev,x
    xba
    and #$0001                  ; (on screen then: on screen now, not shown)
    beq :+
    ldx w_i
    sep #$20
    .a8
    lda fl_st,x
    ora #1
    sta fl_st,x
    rep #$20
    .a16
:   rts

; FlSh: entry w_i shown
FlSh:
    ldx w_i
    sep #$20
    .a8
    lda fl_st,x
    ora #2
    sta fl_st,x
    .ifdef FLKREC
    lda w_fb
    sta fl_fb,x
    .endif
    rep #$20
    .a16
    .ifdef FLKREC
    txa
    asl a
    tax
    lda w_img
    sta fl_shi,x
    .endif
    rts

; FlEnd: toggles vs the last rendered frame
FlEnd:
    stz fl_n
    lda sprite_count
    cmp #127
    bcc :+
    lda #127
:   sta fl_cnt
    ldy #0
@e: cpy fl_cnt
    bcc :+
    jmp @done
:   lda fl_st,y
    and #$00FF
    bit #1
    bne :+
    jmp @nx
:   sta w_t                     ; state: 1 | 2 shown
    phy
    FLINC32 FLK_CNT+16
    lda w_t
    and #2
    beq :+
    FLINC32 FLK_CNT+12
:   ply
    phy
    tya
    asl a
    tax
    lda f:hw_ent,x
    and #$00FF
    sta w_v                     ; (object)
    asl a
    tax
    stx w_u+2                   ; (FLK_PREV offset)
    lda fl_prev,x
    sta w_u
    inc a
    eor sv_frame
    and #$00FF
    beq :+
    lda sv_frame                ; (not on screen last frame: on screen since now)
    sta fl_ons,x
    bra @upd0
:   lda w_u                     ; (on screen last frame? else since now)
    xba
    and #1
    bne :+
    lda sv_frame
    sta fl_ons,x
    bra @upd0
:
    lda w_u
    xba
    eor w_t
    and #2
    bne :+
@upd0:
    jmp @upd
:
    inc fl_n                    ; toggle
    FLINC32 FLK_CNT+4
    ldx w_u+2
    inc fl_otg,x
    ply                         ; (by size: area / 8 < 8 / 64 / 512 / more)
    phy
    lda fl_sz,y
    and #$000C
    tax
    lda f:$40E7A0,x
    clc
    adc #1
    sta f:$40E7A0,x
    lda f:$40E7A2,x
    adc #0
    sta f:$40E7A2,x
    ldx w_u+2                   ; (a blink: toggled within 8 frames)
    lda sv_frame
    sec
    sbc fl_ltg,x
    cmp #9
    bcs :+
    FLINC32 FLK_CNT+36
:   ldx w_u+2
    lda sv_frame
    sta fl_ltg,x
    lda w_t
    and #2
    bne :+
    FLINC32 FLK_CNT+20
    ply                         ; (shown -> not: by reason)
    phy
    lda sv_why,y
    and #$00FF
    ldx w_u+2
    sta fl_orw,x
    and #$000F
    asl a
    asl a
    tax
    lda f:$40E760,x
    clc
    adc #1
    sta f:$40E760,x
    lda f:$40E762,x
    adc #0
    sta f:$40E762,x
    bra :++
:   FLINC32 FLK_CNT+24
    ldx w_u+2                   ; (not -> shown within 8 frames of coming on
    lda sv_frame                ; screen: entering, $40E7B0)
    sec
    sbc fl_ons,x
    cmp #9
    bcs :+
    lda f:$40E7B0
    clc
    adc #1
    sta f:$40E7B0
    lda f:$40E7B2
    adc #0
    sta f:$40E7B2
:
:   lda f:FLK_CNT+30            ; (event)
    and #$00F8
    tax
    lda sv_frame
    sta f:FLK_RING,x
    ply
    phy
    lda sv_why,y
    and #$00FF
    xba
    ora w_v
    sta f:FLK_RING+2,x
    tya
    asl a
    tay
    lda fl_ar,y
    sta f:FLK_RING+4,x
    ply
    phy
    lda f:FLK_CNT+30
    clc
    adc #8
    sta f:FLK_CNT+30
@upd:
    lda sv_frame
    and #$00FF
    sta w_u
    lda w_t
    xba
    ora w_u
    ldx w_u+2
    sta fl_prev,x
    ply
@nx:
    iny
    jmp @e
@done:
    .ifdef FLKREC
    lda sv_frame
    sta f:$40E740
    lda fl_buf
    sta f:$40E742
    ldx #126
:   lda fl_st,x
    sta f:$40E600,x
    lda sv_why,x
    sta f:$40E680,x
    lda fl_fb,x
    sta f:$40E580,x
    lda fl_nw,x
    sta f:$40E500,x
    dex
    dex
    bpl :-
    ldx #254
:   lda fl_shi,x
    sta f:$40E400,x
    dex
    dex
    bpl :-
    ldx #14
:   lda fl_dq,x
    sta f:$40E750,x
    dex
    dex
    bpl :-
    .endif
    FLINC32 FLK_CNT
    lda fl_n
    beq :+
    FLINC32 FLK_CNT+8
:   lda fl_n
    cmp f:FLK_CNT+28
    bcc :+
    sta f:FLK_CNT+28
:   rts
