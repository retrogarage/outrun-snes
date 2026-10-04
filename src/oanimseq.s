; OAnimSeq: animation sequences - port of the original CannonBall engine
; (engine/oanimseq.cpp, classic arcade): the man waving the start flag, the
; Ferrari and passengers driving in at the start line, and the five end
; sequences (Ferrari, car door, interior, passengers, shadows, trophy
; presenter, after effects) timed by the global sequence position.
;
; oanimsprite objects are BSS records with the AS_* layout of ogame.inc; an
; oanimsprite* argument is the bank 0 address of the record in Y.
; Animation blocks (rom0) are 8-byte frames: +0 palette, +1 bit 7 negate x /
; bits 4-6 sprite priority / bits 0-3 top of the frame address, +2 frame
; address, +4 x, +5 y, +6 road priority, +7 bit 7 load the next block,
; bit 6 h-flip, bits 0-5 frame delay.
;
; Imported 1-byte variables are read as the low byte of their word and
; written with 8-bit stores (right whether the owner keeps a byte or a word
; with a zero high byte), except oferrari.car_state (int8, -1 =
; CAR_ANIM_SEQ): written as a sign-extended word.
.ifdef NEWGAME
.p816
.smart
.include "sa1.inc"
.include "globals.inc"
.include "ogame.inc"

.import MapPalette, DoSprOrderShadows, sprite_scroll_speed
.import R0Set, R0Byte, SMul16, UMul16, RoadYAt, HEval
.importzp rp0, mres
.import FerInitIngame, car_state, fer_state, ferrari_pal, auto_brake, sprite_ai_x
.import car_increment, bonus_control, game_state, SndQueueSound
.import steering_adjust, brake_adjust

.export AnimSeqInit, AnimFlagSeq, AnimFerrariSeq, AnimSeqIntro
.export AnimInitEndSeq, AnimTickEndSeq
.export anim_flag, anim_ferrari, anim_pass1, anim_pass2
.export anim_obj1, anim_obj2, anim_obj3, anim_obj4
.export anim_obj5, anim_obj6, anim_obj7, anim_obj8
.export end_seq, seq_pos, end_seq_state, ferrari_stopped

; OFerrari / OBonus enums
FERRARI_SEQ2    = 1
FERRARI_END_SEQ = 4
CAR_NORMAL      = 0
CAR_ANIM_SEQ    = $FFFF         ; -1
BONUS_DISABLE   = 0

; the end sequence tables are all in rom0 bank 1 (ReadEndPair, ReadAnimData)
.assert ^ADR_anim_endseq_obj1 = 1 && ^ADR_anim_endseq_obj2 = 1, error
.assert ^ADR_anim_endseq_obj3 = 1 && ^ADR_anim_endseq_obj4 = 1, error
.assert ^ADR_anim_endseq_obj5 = 1 && ^ADR_anim_endseq_obj6 = 1, error
.assert ^ADR_anim_endseq_obj7 = 1 && ^ADR_anim_endseq_obj8 = 1, error
.assert ^ADR_anim_endseq_objA = 1 && ^ADR_anim_endseq_objB = 1, error

.segment "BSS"
anim_flag:       .res AS_SIZE   ; man at the line with the start flag
anim_ferrari:    .res AS_SIZE   ; Ferrari
anim_pass1:      .res AS_SIZE   ; passengers
anim_pass2:      .res AS_SIZE
anim_obj1:       .res AS_SIZE   ; end sequence objects
anim_obj2:       .res AS_SIZE
anim_obj3:       .res AS_SIZE
anim_obj4:       .res AS_SIZE
anim_obj5:       .res AS_SIZE
anim_obj6:       .res AS_SIZE
anim_obj7:       .res AS_SIZE
anim_obj8:       .res AS_SIZE
end_seq:         .res 2         ; uint8: end sequence to display (0-4)
seq_pos:         .res 2         ; int16: end sequence animation position
end_seq_state:   .res 2         ; uint8: 0 init, 1 tick
ferrari_stopped: .res 2         ; bool
; locals
an_rec:     .res 2              ; record being processed
an_par:     .res 2              ; parent record (anim_seq_shadow)
an_gs:      .res 2              ; game_state (sign-extended)
an_z16:     .res 2
an_pr:      .res 2              ; sprite priority
an_zs:      .res 2              ; zoom shift
an_pov:     .res 2              ; anim_seq_outro pal_override
an_pov_on:  .res 2              ; 0: pal_override = -1
an_t:       .res 4
an_m:       .res 4
fr_ix:      .res 4              ; index = anim_addr_curr + (anim_frame << 3)
fr_addr:    .res 4              ; read32(index) & $FFFFF
fr_b0:      .res 2              ; read8(index + n)
fr_b1:      .res 2
fr_b4:      .res 2
fr_b5:      .res 2
fr_b6:      .res 2
fr_b7:      .res 2
fr_b15:     .res 2
rp_rec:     .res 2              ; ReadPair / DelayCurr record
rp_t:       .res 2
rd_rec:     .res 2              ; ReadAnimData
rd_id:      .res 2
rd_t:       .res 2
rd_start:   .res 2
rd_end:     .res 2
rd_pos:     .res 2

.segment "SA1CODE"
.a16
.i16

; SETPAIR: record anim_addr_curr / anim_addr_next = constants
.macro SETPAIR rec, curr, next
    lda #.loword(curr)
    sta rec+AS_ADDR_CURR
    lda #^(curr)
    sta rec+AS_ADDR_CURR+2
    lda #.loword(next)
    sta rec+AS_ADDR_NEXT
    lda #^(next)
    sta rec+AS_ADDR_NEXT+2
.endmacro

;============================================================================
; init (oanimseq.cpp 53): the jump table is JT
;============================================================================
AnimSeqInit:
    ; flag animation
    lda #EOFS(SPRITE_FLAG)
    sta anim_flag+AS_SPRITE
    stz anim_flag+AS_STATE
    tax
    lda #7
    STEB OE_SHADOW
    lda #DP_BOTTOM
    STEB OE_DRAW_PROPS
    jsr Enable
    lda #0                      ; z = 400 << 16
    STE OE_Z
    lda #400
    STE OE_Z+2
    ; Ferrari and passengers for the intro
    ldy #anim_ferrari
    lda #EOFS(SPRITE_FERRARI)
    jsr AsInit
    SETPAIR anim_ferrari, ADR_anim_ferrari_curr, ADR_anim_ferrari_next
    ldx #EOFS(SPRITE_FERRARI)
    jsr Enable
    lda #DP_BOTTOM
    STEB OE_DRAW_PROPS
    ldy #anim_pass1
    lda #EOFS(SPRITE_PASS1)
    jsr AsInit
    SETPAIR anim_pass1, ADR_anim_pass1_curr, ADR_anim_pass1_next
    ldx #EOFS(SPRITE_PASS1)
    lda #DP_BOTTOM
    STEB OE_DRAW_PROPS
    ldy #anim_pass2
    lda #EOFS(SPRITE_PASS2)
    jsr AsInit
    SETPAIR anim_pass2, ADR_anim_pass2_curr, ADR_anim_pass2_next
    ldx #EOFS(SPRITE_PASS2)
    lda #DP_BOTTOM
    STEB OE_DRAW_PROPS
    ; end sequence animation
    stz end_seq_state
    stz seq_pos
    stz ferrari_stopped
    ldy #anim_obj1
    lda #EOFS(SPRITE_CRASH)
    jsr AsInit
    ldy #anim_obj2
    lda #EOFS(SPRITE_CRASH_SHADOW)
    jsr AsInit
    ldy #anim_obj3
    lda #EOFS(SPRITE_SHADOW)
    jsr AsInit
    ldy #anim_obj4
    lda #EOFS(SPRITE_CRASH_PASS1)
    jsr AsInit
    ldy #anim_obj5
    lda #EOFS(SPRITE_CRASH_PASS1_S)
    jsr AsInit
    ldy #anim_obj6
    lda #EOFS(SPRITE_CRASH_PASS2)
    jsr AsInit
    ldy #anim_obj7
    lda #EOFS(SPRITE_CRASH_PASS2_S)
    jsr AsInit
    ldy #anim_obj8
    lda #EOFS(SPRITE_FLAG)
    ; fall into AsInit

; oanimsprite::init (oanimsprite.hpp 54): Y = record, A = entry offset
AsInit:
    sta AS_SPRITE,y
    tax
    lda #$FF
    STEB OE_FUNC                ; function_holder = -1
    lda #0
    sta AS_ADDR_CURR,y
    sta AS_ADDR_CURR+2,y
    sta AS_ADDR_NEXT,y
    sta AS_ADDR_NEXT+2,y
    sta AS_FRAME,y
    sta AS_DELAY,y
    sta AS_PROPS,y
    sta AS_STATE,y
    rts

;============================================================================
; flag_seq (oanimseq.cpp 113)
;============================================================================
AnimFlagSeq:
    ldx anim_flag+AS_SPRITE
    LDEB OE_CONTROL
    and #C_ENABLE
    bne :+
    rts
:   ; (outrun.tick_frame is always true)
    jsr LdGameState
    sta an_gs
    cmp #GS_START1              ; (int8 range: the N flag is the signed test)
    bmi @off
    cmp #GS_GAMEOVER+1
    bmi @on
@off:
    ldx anim_flag+AS_SPRITE
    jmp Disable
@on:
    ; init flag sequence
    cmp #GS_INGAME
    bpl @wave
    cmp anim_flag+AS_STATE
    beq @wave
    sta anim_flag+AS_STATE      ; anim_state = game_state
    sec
    sbc #9
    asl a
    asl a
    asl a                       ; (game_state - 9) << 3
    clc
    adc #.loword(ADR_anim_seq_flag)
    ldx #^ADR_anim_seq_flag
    bcc :+
    inx
:   ldy #anim_flag
    jsr ReadPair                ; anim_addr_curr/next = read32(&index) x2
    ldy #anim_flag
    jsr DelayCurr               ; frame_delay = read8(7 + curr) & $3F
    stz anim_flag+AS_FRAME
@wave:
    ; wave flag
    lda an_gs
    cmp #GS_INGAME+1
    bmi :+
    jmp @order
:   ldy #anim_flag
    jsr FetchFrame
    ldx anim_flag+AS_SPRITE
    lda fr_addr
    STE OE_ADDR
    lda fr_addr+2
    STE OE_ADDR+2
    lda fr_b0
    STE OE_PAL_SRC
    ; z += rom0.read32(SPRITE_ZOOM_LOOKUP + (((z >> 16) << 2) | scroll speed))
    ; (z >> 16 < $200 here: the offset stays in the 64 KB bank)
    LDE OE_Z+2
    asl a
    asl a
    ora sprite_scroll_speed
    clc
    adc #.loword(SPRITE_ZOOM_LOOKUP)
    tax
    lda f:R0(SPRITE_ZOOM_LOOKUP & $FFFF0000),x
    xba
    sta an_t+2
    lda f:R0(SPRITE_ZOOM_LOOKUP & $FFFF0000)+2,x
    xba
    sta an_t
    ldx anim_flag+AS_SPRITE
    LDE OE_Z
    clc
    adc an_t
    STE OE_Z
    LDE OE_Z+2
    adc an_t+2
    STE OE_Z+2
    sta an_z16                  ; uint16 z16 = z >> 16
    cmp #$0200
    bcc :+
    jmp Disable                 ; z16 >= $200: disable and return
:   STE OE_PRIORITY
    lsr a
    lsr a
    STEB OE_ZOOM                ; z16 >> 2
    ; x = ((int16)((int8) read8(4 + index) - road0_h[z16]) * z16) >> 9,
    ; negated if bit 7 of read8(1 + index)
    lda an_z16
    ldx #0
    jsr HEval                   ; road0_h[z16]
    sta an_t
    lda fr_b4
    jsr Sext8
    sec
    sbc an_t
    ldx an_z16
    jsr SUMulShr9
    jsr NegB1
    ldx anim_flag+AS_SPRITE
    STE OE_X
    ; y = get_road_y(z16) - (int16)(((int8) read8(5 + index) * z16) >> 9)
    lda fr_b5
    jsr Sext8
    ldx an_z16
    jsr SUMulShr9
    sta an_t
    lda an_z16
    jsr RoadYAt
    sec
    sbc an_t
    ldx anim_flag+AS_SPRITE
    STE OE_Y
    jsr SetHFlip
    ; ready for next frame
    lda anim_flag+AS_DELAY
    dec a
    and #$00FF                  ; uint8 --frame_delay
    sta anim_flag+AS_DELAY
    bne @order
    lda fr_b7
    and #$0080
    beq @last
    ; load next block of animation data
    lda anim_flag+AS_ADDR_NEXT
    sta anim_flag+AS_ADDR_CURR
    lda anim_flag+AS_ADDR_NEXT+2
    sta anim_flag+AS_ADDR_CURR+2
    ldy #anim_flag
    jsr DelayCurr
    stz anim_flag+AS_FRAME
    bra @order
@last:
    lda fr_b15
    and #$003F
    sta anim_flag+AS_DELAY
    inc anim_flag+AS_FRAME
@order:
    ldx anim_flag+AS_SPRITE
    jsr MapPalette
    ldx anim_flag+AS_SPRITE
    jmp DoSprOrderShadows

;============================================================================
; ferrari_seq (oanimseq.cpp 211, source $6036)
;============================================================================
AnimFerrariSeq:
    ldx anim_ferrari+AS_SPRITE
    LDEB OE_CONTROL
    and #C_ENABLE
    bne :+
    rts
:   jsr LdGameState
    cmp #GS_MUSIC
    bne :+
    rts
:   ldx anim_pass1+AS_SPRITE
    jsr Enable
    ldx anim_pass2+AS_SPRITE
    jsr Enable
    jsr LdGameState
    cmp #GS_LOGO+1
    bpl :+
    jmp FerInitIngame           ; game_state <= GS_LOGO
:   ldy #anim_ferrari
    jsr DelayCurr
    ldy #anim_pass1
    jsr DelayCurr
    ldy #anim_pass2
    jsr DelayCurr
    lda #CAR_NORMAL
    sta car_state
    sep #$20
    .a8
    lda #FERRARI_SEQ2
    sta fer_state
    rep #$20
    .a16
    ldy #anim_ferrari
    ; fall into AnimSeqIntro

;============================================================================
; anim_seq_intro (oanimseq.cpp 240, source $60AE): Y = record
;============================================================================
AnimSeqIntro:
    sty an_rec
    jsr LdGameState
    cmp #GS_LOGO+1
    bpl :+
    jmp FerInitIngame           ; game_state <= GS_LOGO
:   ; (tick_frame)
    ldy an_rec
    lda AS_FRAME,y              ; anim_frame >= 1 (int16)
    beq :+
    bmi :+
    lda #CAR_ANIM_SEQ
    sta car_state
:   ldy an_rec
    jsr FetchFrame
    ldy an_rec
    ldx AS_SPRITE,y
    lda fr_addr
    STE OE_ADDR
    lda fr_addr+2
    STE OE_ADDR+2
    lda fr_b0                   ; pal_src: the Ferrari uses its own palette
    cpy #anim_ferrari
    bne :+
    lda ferrari_pal
:   STE OE_PAL_SRC
    lda #$7F
    STEB OE_ZOOM
    lda #$01FE
    STE OE_ROAD_PRIORITY
    jsr PrioBits
    eor #$FFFF
    sec
    adc #$01FE                  ; priority = $1FE - bits 4-6
    STE OE_PRIORITY
    sta an_pr
    ; x = ((int8) read8(4 + index) * priority) >> 9, negated if bit 7 of +1
    lda fr_b4
    jsr Sext8
    ldx an_pr
    jsr SUMulShr9
    jsr NegB1
    ldy an_rec
    ldx AS_SPRITE,y
    STE OE_X
    ; y = 221 - (int8) read8(5 + index)
    lda fr_b5
    jsr Sext8
    eor #$FFFF
    sec
    adc #221
    STE OE_Y
    jsr SetHFlip
    ; ready for next frame
    ldy an_rec
    lda AS_DELAY,y
    dec a
    and #$00FF                  ; uint8 --frame_delay
    sta AS_DELAY,y
    bne @order
    lda fr_b7
    and #$0080
    beq @last
    ; load next block: the last entry of passenger 2 ends the routine and
    ; sets up the Ferrari (view mode is never VIEW_INCAR)
    cpy #anim_pass2
    bne @next
    ldx AS_SPRITE,y
    jsr MapPalette
    ldx anim_pass2+AS_SPRITE
    jsr DoSprOrderShadows
    jmp FerInitIngame
@next:
    lda AS_ADDR_NEXT,y
    sta AS_ADDR_CURR,y
    lda AS_ADDR_NEXT+2,y
    sta AS_ADDR_CURR+2,y
    jsr DelayCurr
    ldy an_rec
    lda #0
    sta AS_FRAME,y
    bra @order
@last:
    lda fr_b15
    and #$003F
    sta AS_DELAY,y
    lda AS_FRAME,y
    inc a
    sta AS_FRAME,y
@order:
    ldy an_rec                  ; (view mode is never VIEW_INCAR)
    ldx AS_SPRITE,y
    jsr MapPalette
    ldy an_rec
    ldx AS_SPRITE,y
    jmp DoSprOrderShadows

;============================================================================
; init_end_seq (oanimseq.cpp 323, source $9978)
;============================================================================
AnimInitEndSeq:
    sep #$20
    .a8
    lda #FERRARI_END_SEQ
    sta fer_state
    rep #$20
    .a16
    ldx anim_ferrari+AS_SPRITE
    jsr Enable
    lda #0
    STEB OE_ID
    lda #DP_BOTTOM
    STEB OE_DRAW_PROPS
    stz anim_ferrari+AS_FRAME
    stz anim_ferrari+AS_DELAY
    stz seq_pos
    ; passenger sprites off: replaced by the animation sequence
    ; (oferrari.spr_pass1/2 = &jump_table[SPRITE_PASS1/2])
    ldx #EOFS(SPRITE_PASS1)
    jsr Disable
    ldx #EOFS(SPRITE_PASS2)
    jsr Disable
    sep #$20
    .a8
    lda bonus_control           ; obonus.bonus_control += 4 (int8)
    clc
    adc #4
    sta bonus_control
    rep #$20
    .a16
    rts

;============================================================================
; tick_end_seq (oanimseq.cpp 344)
;============================================================================
AnimTickEndSeq:
    lda end_seq_state
    and #$00FF
    beq @init
    cmp #1
    beq @tick
    rts
@init:
    jsr InitEndSprites          ; (tick_frame), then falls into case 1
@tick:
    jsr SeqOutroFerrari         ; Ferrari
    lda ferrari_pal
    ldy #anim_obj1
    jsr SeqOutroPal             ; car door opening
    ldy #anim_obj2
    jsr SeqOutro                ; interior of the Ferrari
    ldx #anim_ferrari
    ldy #anim_obj3
    jsr SeqShadow               ; car shadow
    ldy #anim_pass1
    jsr SeqOutro                ; man (fix_bugs = 0: palette kept)
    ldx #anim_pass1
    ldy #anim_obj4
    jsr SeqShadow               ; man shadow
    ldy #anim_pass2
    jsr SeqOutro                ; female
    ldx #anim_pass2
    ldy #anim_obj5
    jsr SeqShadow               ; female shadow
    ldy #anim_obj6
    jsr SeqOutro                ; man presenting trophy
    lda end_seq
    and #$00FF
    cmp #4
    bne :+
    ldy #anim_obj7
    jsr SeqOutro                ; varies
    bra :++
:   ldx #anim_obj6
    ldy #anim_obj7
    jsr SeqShadow
:   ldy #anim_obj8
    jmp SeqOutro                ; effects

;----------------------------------------------------------------------------
; init_end_sprites (oanimseq.cpp 375, source $588A)
;----------------------------------------------------------------------------
InitEndSprites:
    .ifndef LOCKSTEP
    .import SprForgetObject
    ; These slots now represent different layers/characters. Discard old
    ; crash/driver images, pending loads and rejection cooldowns.
    ldx #SPRITE_FERRARI*2
@forgetcar:
    jsr SprForgetObject
    inx
    inx
    cpx #(SPRITE_SHADOW+1)*2
    bcc @forgetcar
    ldx #SPRITE_CRASH*2
@forgetactors:
    jsr SprForgetObject
    inx
    inx
    cpx #(SPRITE_FLAG+1)*2
    bcc @forgetactors
    .endif
    ; Ferrari object [$5B12 entry point]
    lda #.loword(ADR_anim_endseq_obj1)
    ldy #anim_ferrari
    jsr ReadEndPair
    stz ferrari_stopped
    ; $58A4: car door opening animation
    ldy #anim_obj1
    lda #1
    jsr SeqSpriteEntry
    lda #3
    STEB OE_SHADOW
    lda #.loword(ADR_anim_endseq_obj2)
    ldy #anim_obj1
    jsr ReadEndPair
    ; $58EC: interior of the Ferrari
    ldy #anim_obj2
    lda #2
    jsr SeqSpriteEntry
    lda #.loword(ADR_anim_endseq_obj3)
    ldy #anim_obj2
    jsr ReadEndPair
    ; $592A: car shadow
    ldy #anim_obj3
    lda #3
    jsr SeqSpriteEntry
    jsr ShadowAddr
    ; $5960: man sprite
    ldy #anim_pass1
    lda #4
    jsr SeqSpriteEntry
    lda #.loword(ADR_anim_endseq_obj4)
    ldy #anim_pass1
    jsr ReadEndPair
    ; $5998: man shadow
    ldy #anim_obj4
    lda #5
    jsr SeqSpriteEntry
    lda #C_ENABLE
    STEB OE_CONTROL             ; control = ENABLE
    lda #7
    STEB OE_SHADOW
    jsr ShadowAddr
    ; $59BE: female sprite
    ldy #anim_pass2
    lda #6
    jsr SeqSpriteEntry
    lda #.loword(ADR_anim_endseq_obj5)
    ldy #anim_pass2
    jsr ReadEndPair
    ; $59F6: female shadow
    ldy #anim_obj5
    lda #7
    jsr SeqSpriteEntry
    lda #C_ENABLE
    STEB OE_CONTROL             ; control = ENABLE
    lda #7
    STEB OE_SHADOW
    jsr ShadowAddr
    ; $5A2C: person presenting trophy
    ldy #anim_obj6
    lda #8
    jsr SeqSpriteEntry
    lda #.loword(ADR_anim_endseq_obj6)
    ldy #anim_obj6
    jsr ReadEndPair
    ; alternate use based on the end sequence
    ldy #anim_obj7
    lda #9
    jsr SeqSpriteEntry
    lda end_seq
    and #$00FF
    cmp #4
    bne @tshadow
    lda #.loword(ADR_anim_endseq_objB)
    ldy #anim_obj7
    jsr ReadEndPair
    bra @fx
@tshadow:
    lda #7                      ; trophy shadow (X = entry)
    STEB OE_SHADOW
    jsr ShadowAddr
@fx:
    ; $5AD0: after effects (e.g. cloud of smoke for the genie)
    ldy #anim_obj8
    lda #10
    jsr SeqSpriteEntry
    lda #$FF00
    sta anim_obj8+AS_PROPS
    lda #.loword(ADR_anim_endseq_obj7)
    ldy #anim_obj8
    jsr ReadEndPair
    lda #1
    sta end_seq_state
    rts

; SeqSpriteEntry: Y = record, A = id: sprite control |= ENABLE, id, draw
; props = BOTTOM; anim_frame = frame_delay = anim_props = 0 -> X = entry
SeqSpriteEntry:
    pha
    lda #0
    sta AS_FRAME,y
    sta AS_DELAY,y
    sta AS_PROPS,y
    ldx AS_SPRITE,y
    pla
    STEB OE_ID
    jsr Enable
    lda #DP_BOTTOM
    STEB OE_DRAW_PROPS
    rts

; ShadowAddr: X = entry: addr = outrun.adr.shadow_data
ShadowAddr:
    lda #.loword(ADR_shadow_data)
    STE OE_ADDR
    lda #^ADR_shadow_data
    STE OE_ADDR+2
    rts

; ReadEndPair: A = low word of an ANIM_ENDSEQ table (rom0 bank 1), Y =
; record: anim_addr_curr/next = read32(&addr) x2, addr = table + (end_seq << 3)
ReadEndPair:
    sta rp_t
    lda end_seq
    and #$00FF
    asl a
    asl a
    asl a
    clc
    adc rp_t
    ldx #1
    bcc :+
    inx
:   jmp ReadPair

;----------------------------------------------------------------------------
; anim_seq_outro_ferrari (oanimseq.cpp 506, source $5B12)
;----------------------------------------------------------------------------
SeqOutroFerrari:
    lda ferrari_stopped
    bne @outro
    lda car_increment+2         ; car_increment >> 16: moving, brake on
    beq @stop
    sep #$20
    .a8
    lda #1
    sta auto_brake
    rep #$20
    .a16
    lda #$00FF
    sta brake_adjust
    bra @outro
@stop:
    lda #S_VOICE_CONGRATS
    jsr SndQueueSound
    lda #1
    sta ferrari_stopped
@outro:
    lda ferrari_pal
    ldy #anim_ferrari
    ; fall into SeqOutroPal

;----------------------------------------------------------------------------
; anim_seq_outro (oanimseq.cpp 527, source $5B42): Y = record
; SeqOutroPal: A = pal_override; SeqOutro: pal_override = -1
;----------------------------------------------------------------------------
SeqOutroPal:
    sta an_pov
    lda #1
    sta an_pov_on
    bra SeqOutroGo
SeqOutro:
    stz an_pov_on
SeqOutroGo:
    sty an_rec
    stz steering_adjust
    jsr ReadAnimData            ; no animation data to process: return
    bne :+
    rts
:   ldy an_rec
    jsr FetchFrame
    ldy an_rec
    ldx AS_SPRITE,y
    lda fr_addr
    STE OE_ADDR
    lda fr_addr+2
    STE OE_ADDR+2
    lda fr_b0                   ; pal_src (override: Ferrari recolour)
    ldy an_pov_on
    beq :+
    lda an_pov
:   STE OE_PAL_SRC
    lda fr_b6
    lsr a
    STEB OE_ZOOM                ; read8(6 + index) >> 1
    lda fr_b6
    asl a
    STE OE_ROAD_PRIORITY        ; read8(6 + index) << 1
    sta an_t
    jsr PrioBits
    eor #$FFFF
    sec
    adc an_t                    ; priority = road_priority - bits 4-6 (uint16)
    STE OE_PRIORITY
    sta an_pr
    ; x = (read8(4 + index) * priority) >> 9 (unsigned byte), negated if
    ; bit 7 of read8(1 + index)
    lda fr_b4
    ldx an_pr
    jsr UMul16
    jsr Shr9
    jsr NegB1
    ldy an_rec
    ldx AS_SPRITE,y
    STE OE_X
    ; y = get_road_y(priority) - (int16)(((int8) read8(5 + index) * priority) >> 9)
    lda fr_b5
    jsr Sext8
    ldx an_pr
    jsr SUMulShr9
    sta an_t
    lda an_pr
    jsr RoadYAt
    sec
    sbc an_t
    ldy an_rec
    ldx AS_SPRITE,y
    STE OE_Y
    jsr SetHFlip
    ; ready for next frame (tick_frame)
    ldy an_rec
    lda AS_DELAY,y
    dec a
    and #$00FF                  ; uint8 --frame_delay
    sta AS_DELAY,y
    bne @order
    lda fr_b7
    and #$0080
    beq @last
    ; load next block of animation data
    lda AS_PROPS,y
    ora #$00FF
    sta AS_PROPS,y
    lda AS_ADDR_NEXT,y
    sta AS_ADDR_CURR,y
    lda AS_ADDR_NEXT+2,y
    sta AS_ADDR_CURR+2,y
    jsr DelayCurr
    ldy an_rec
    lda #0
    sta AS_FRAME,y
    bra @order
@last:
    lda fr_b15
    and #$003F
    sta AS_DELAY,y
    lda AS_FRAME,y
    inc a
    sta AS_FRAME,y
@order:
    ldy an_rec
    ldx AS_SPRITE,y
    jsr MapPalette
    ldy an_rec
    ldx AS_SPRITE,y
    jmp DoSprOrderShadows

;----------------------------------------------------------------------------
; anim_seq_shadow (oanimseq.cpp 588, source $5C48): X = parent record,
; Y = record
;----------------------------------------------------------------------------
SeqShadow:
    stx an_par
    sty an_rec
    jsr ReadAnimData            ; no animation data to process: return
    bne :+
    rts
:   ; (tick_frame)
    lda #3
    sta an_zs                   ; zoom_shift
    ldy an_rec
    ldx AS_SPRITE,y
    LDEB OE_ID
    cmp #3
    bne @xy
    lda #1                      ; car shadow
    sta an_zs
    ldy an_par
    lda AS_PROPS,y
    and #$00FF
    bne @xy
    lda sprite_ai_x             ; oferrari.sprite_ai_x <= 5 (int16)
    sec
    sbc #6
    bvc :+
    eor #$8000
:   bpl @xy
    inc an_zs
@xy:
    ; $5C88 set_sprite_xy
    ldy an_par
    ldx AS_SPRITE,y
    LDE OE_X
    sta an_t
    LDE OE_ROAD_PRIORITY
    sta an_pr
    ldy an_rec
    ldx AS_SPRITE,y
    lda an_t
    STE OE_X
    lda an_pr                   ; uint16 priority = road_priority >> zoom_shift
    ldy an_zs
:   lsr a
    dey
    bne :-
    sta an_t
    lsr a
    lsr a
    eor #$FFFF
    sec
    adc an_t
    STEB OE_ZOOM                ; priority - (priority >> 2)
    lda an_pr
    jsr RoadYAt
    ldy an_rec
    ldx AS_SPRITE,y
    STE OE_Y
    lda an_pr
    STE OE_ROAD_PRIORITY        ; road_priority = parent road_priority
    jmp DoSprOrderShadows

;----------------------------------------------------------------------------
; read_anim_data (oanimseq.cpp 622, source $5CC4): Y = record
; -> A = 1 process, 0 nothing to do (Z flag set)
;----------------------------------------------------------------------------
ReadAnimData:
    sty rd_rec
    ldx AS_SPRITE,y
    LDEB OE_ID
    sta rd_id
    ; addr = anim_end_table + (end_seq << 2) + (id << 2) + (id << 4)
    asl a
    asl a
    sta rd_t
    asl a
    asl a
    clc
    adc rd_t
    sta rd_t
    lda end_seq
    and #$00FF
    asl a
    asl a
    clc
    adc rd_t
    clc
    adc #.loword(ADR_anim_end_table)
    ldy #^ADR_anim_end_table
    bcc :+
    iny
:   jsr R0Set
    lda [rp0]
    xba
    sta rd_start                ; int16 start_pos
    ldy #2
    lda [rp0],y
    xba
    sta rd_end                  ; int16 end_pos
    lda seq_pos
    sta rd_pos                  ; pos = seq_pos
    ; global sequence position: advance (tick_frame)
    ldy rd_rec
    lda AS_PROPS,y
    and #$FF00
    beq :+
    inc seq_pos
:   ; sequence over: course map
    lda bonus_control
    and #$00FF
    beq @check                  ; BONUS_DISABLE
    lda end_seq
    and #$00FF
    asl a
    tax
    lda f:EndSeqLengths,x
    cmp seq_pos
    bne @check
    sep #$20
    .a8
    lda #BONUS_DISABLE
    sta bonus_control
    lda #GS_INIT_MAP            ; (MODE_ORIGINAL)
    sta game_state
    rep #$20
    .a16
@check:
    ; check_seq_pos: start position
    lda rd_pos
    cmp rd_start
    bne @notstart
    ldy rd_rec
    lda AS_ADDR_CURR,y          ; current block set: extract the frame delay
    ora AS_ADDR_CURR+2,y
    beq :+
    jsr DelayCurr
:   lda #1
    rts
@notstart:
    lda rd_pos                  ; pos < start_pos: nothing
    sec
    sbc rd_start
    bvc :+
    eor #$8000
:   bmi @nothing
    lda rd_end                  ; pos > end_pos: nothing
    sec
    sbc rd_pos
    bvc :+
    eor #$8000
:   bmi @nothing
    lda rd_pos                  ; pos < end_pos: in progress
    sec
    sbc rd_end
    bvc :+
    eor #$8000
:   bmi @process
    ; end position: end of animation data
    lda rd_id
    cmp #8
    bne :+
    lda #11                     ; trophy person
    ldx #.loword(ADR_anim_endseq_obj8)
    bra @switch
:   cmp #10                     ; ($5E14)
    bne @process
    lda #12
    ldx #.loword(ADR_anim_endseq_objA)
@switch:
    stx rd_t
    ldy rd_rec
    ldx AS_SPRITE,y
    STEB OE_ID
    lda end_seq
    and #$00FF
    cmp #2
    bcc :+
    lda #7
    STEB OE_SHADOW
:   lda end_seq
    and #$00FF
    asl a
    asl a
    asl a
    clc
    adc rd_t
    ldx #1                      ; (bank 1: see the asserts)
    bcc :+
    inx
:   ldy rd_rec
    jsr ReadPair
    ldy rd_rec
    lda #0
    sta AS_FRAME,y
@nothing:
    lda #0
    rts
@process:
    lda #1
    rts

;============================================================================
; helpers
;============================================================================
; LdGameState: A = outrun.game_state (int8, sign-extended)
LdGameState:
    lda game_state
    ; fall into Sext8

; Sext8: A = (int8) low byte, sign-extended (X, Y kept)
Sext8:
    and #$00FF
    eor #$0080
    sec
    sbc #$0080
    rts

; Enable / Disable: X = entry: control |= ENABLE / control &= ~ENABLE
Enable:
    LDEB OE_CONTROL
    ora #C_ENABLE
    STEB OE_CONTROL
    rts
Disable:
    LDEB OE_CONTROL
    and #$FFFF-C_ENABLE
    STEB OE_CONTROL
    rts

; SetHFlip: X = entry: h-flip from bit 6 of read8(7 + index)
SetHFlip:
    lda fr_b7
    and #$0040
    beq :+
    LDEB OE_CONTROL
    ora #C_HFLIP
    STEB OE_CONTROL
    rts
:   LDEB OE_CONTROL
    and #$FFFF-C_HFLIP
    STEB OE_CONTROL
    rts

; NegB1: A = -A if bit 7 of read8(1 + index) (X, Y kept)
NegB1:
    pha
    lda fr_b1
    and #$0080
    beq :+
    pla
    eor #$FFFF
    inc a
    rts
:   pla
    rts

; PrioBits: A = (read16(index) & $70) >> 4 (sprite to sprite priority)
PrioBits:
    lda fr_b1
    and #$0070
    lsr a
    lsr a
    lsr a
    lsr a
    rts

; SUMulShr9: A = (int16) A * (uint16) X (int product) >> 9, low 16 bits
; Shr9: A = low 16 bits of mres >> 9
SUMulShr9:
    sta an_m
    stx an_m+2
    jsr SMul16
    lda an_m+2
    bpl Shr9                    ; X < $8000: the signed product is right
    lda mres+2                  ; X >= $8000: + A << 16
    clc
    adc an_m
    sta mres+2
Shr9:
    sep #$20
    .a8
    lda mres+3
    lsr a                       ; carry = bit 24
    rep #$20
    .a16
    lda mres+1
    ror a                       ; bits 9-24
    rts

; FetchFrame: Y = record: fr_ix = anim_addr_curr + (anim_frame << 3) (the
; frame's index) and its 8-byte block (+ the next frame's byte 7): fr_addr =
; read32(index) & $FFFFF, fr_bN = read8(index + N)
FetchFrame:
    stz fr_ix+2
    lda AS_FRAME,y              ; (int) anim_frame << 3
    bpl :+
    dec fr_ix+2
:   asl a
    rol fr_ix+2
    asl a
    rol fr_ix+2
    asl a
    rol fr_ix+2
    clc
    adc AS_ADDR_CURR,y
    sta fr_ix
    lda fr_ix+2
    adc AS_ADDR_CURR+2,y
    sta fr_ix+2
    tay
    lda fr_ix
    jsr R0Set
    lda [rp0]                   ; b0 | b1 << 8
    pha
    and #$00FF
    sta fr_b0
    pla
    xba
    and #$00FF
    sta fr_b1
    lda [rp0]
    xba                         ; read16(index)
    and #$000F
    sta fr_addr+2
    ldy #2
    lda [rp0],y
    xba
    sta fr_addr
    ldy #4
    lda [rp0],y
    pha
    and #$00FF
    sta fr_b4
    pla
    xba
    and #$00FF
    sta fr_b5
    ldy #6
    lda [rp0],y
    pha
    and #$00FF
    sta fr_b6
    pla
    xba
    and #$00FF
    sta fr_b7
    ldy #15
    lda [rp0],y
    and #$00FF
    sta fr_b15
    rts

; DelayCurr: Y = record: frame_delay = read8(7 + anim_addr_curr) & $3F
DelayCurr:
    sty rp_rec
    lda AS_ADDR_CURR,y
    clc
    adc #7
    tax
    lda AS_ADDR_CURR+2,y
    adc #0
    tay
    txa
    jsr R0Byte
    and #$003F
    ldy rp_rec
    sta AS_DELAY,y
    rts

; ReadPair: A = rom0 address low word, X = high word, Y = record:
; anim_addr_curr = read32(addr), anim_addr_next = read32(addr + 4)
ReadPair:
    sty rp_rec
    phx
    ply
    jsr R0Set
    ldx rp_rec
    lda [rp0]
    xba
    sta AS_ADDR_CURR+2,x
    ldy #2
    lda [rp0],y
    xba
    sta AS_ADDR_CURR,x
    ldy #4
    lda [rp0],y
    xba
    sta AS_ADDR_NEXT+2,x
    ldy #6
    lda [rp0],y
    xba
    sta AS_ADDR_NEXT,x
    rts

.segment "RODATA"
EndSeqLengths: .word $244, $244, $244, $190, $258     ; END_SEQ_LENGTHS
.endif
