; OHud: heads-up display - port of the original CannonBall engine/ohud.cpp
; (classic arcade): HUD labels, mini map, timers, lap timer, score, stage
; number, rev counter, speed digits, the rom0 text blitters and the coin /
; credit / copyright texts.
;
; Every text / tile RAM access goes through the video adapters (vidport.s):
; an address is the LOW 16 BITS of the arcade address (text RAM
; $110000-$110FFF, tile RAM $100000-$10FFFF); video.cpp masks it (text & $FFF,
; tile & $FFFF), so 16-bit address arithmetic here is exact.  All HUD text
; data in rom0 is below $10000: it is read directly with `lda f:R0B0+n,x`
; (X = arcade address).
;
; Argument variables (owned here):
;   hud_v32  - 32-bit score for draw_score / draw_score_tile / draw_score_ingame
;   hud_addr - blit_large_digit's uint32_t* destination (low word, += 2 per call)
;   hud_col  - blit_text_new colour; HUD_GREY (the C++ default argument) is set
;              by HudInit and restored after every HudBlitTextNew call
.ifdef NEWGAME
.p816
.smart
.include "sa1.inc"
.include "globals.inc"
.include "ogame.inc"

.import VidWriteText16, VidWriteTile16, VidDirty
.import txt_ram: far
.import game_state, freeze_timer, tick_counter
.import credits, route_info
.import revs, rev_stop_flag, revs_post_stop, rev_pitch1, rev_pitch2
.import car_increment

.export HudInit, HudDrawMainHud, HudClearTimetrialText, HudDoMiniMap
.export HudSetupMiniMap, HudDrawTimer1, HudDrawTimer2, HudDrawLapTimer
.export HudDrawScoreIngame, HudDrawScore, HudDrawScoreTile, HudDrawStageNumber
.export HudDrawRevCounter, HudBlitSpeed, HudBlitLargeDigit, HudDrawCopyrightText
.export HudDrawInsertCoin, HudDrawCredits, HudBlitText1, HudBlitText1XY
.export HudBlitText2, HudBlitTextNew, HudTranslate
.export hud_v32, hud_addr, hud_col

R0B0         = R0BANK * $10000  ; rom0 $00000-$0FFFF, indexed by the address
DIGIT_BASE   = $30              ; OHud::DIGIT_BASE
TRANSLATE_BASE = $0030          ; translate() BASE_POS 0x110030 (low word)
MM_BASE      = $8B00            ; draw_mini_map
MM_DST       = $0CFA            ; 0x110CFA
TIMER_BASE   = $8C80            ; draw_timer1 BASE_TILE
OFF_PAL      = $8AA0            ; draw_timer1 "OFF" text
OFF_O        = ('O' - $41) * 2 + OFF_PAL
OFF_F        = ('F' - $41) * 2 + OFF_PAL
LT_BASE      = $8230            ; draw_lap_timer
LT_APOS1     = $835E
LT_APOS2     = $835F
SC_BLANK     = $8020            ; draw_score blank tile
REV_OFF      = $8120            ; draw_rev_counter
REV_ON1      = $81FE
REV_ON2      = $81FD
REV_GREEN    = $0200
REV_WHITE    = $0400
REV_RED      = $0600
SPD_BASE     = $8C60            ; blit_speed TILE_BASE

.segment "BSS"
hud_v32:    .res 4
hud_addr:   .res 2
hud_col:    .res 2
.segment "IRAMBSS"          ; (the blit loop variables: I-RAM is faster)
hu_src:     .res 2          ; rom0 source address (< $10000) / string address
hu_dst:     .res 2          ; text / tile RAM destination (low word)
hu_cnt:     .res 2          ; blit counter
hu_data:    .res 2          ; blit tile data / palette
hu_i:       .res 2          ; loop index
hu_t:       .res 2
.segment "BSS"
hu_row2:    .res 2          ; TxtAdv2 second row value
hu_base:    .res 2          ; base tile
hu_d1:      .res 2          ; blit_speed digits, lap timer digits[0..1]
hu_d2:      .res 2
hu_d3:      .res 2
hu_ms:      .res 2          ; draw_lap_timer ms_value
hu_tile:    .res 2          ; draw_score target: 0 text RAM, 1 tile RAM
hu_found:   .res 2
hu_dig:     .res 16         ; draw_score digits[8] (words)
hu_revs:    .res 2
hu_cv:      .res 2          ; Convert16DecHex

.segment "SA1CODE"
.a16
.i16

; TxtAdv: video.write_text16(&hu_dst, A)
TxtAdv:
    xba                     ; (VidWriteText16 inline: arcade byte order)
    pha
    lda hu_dst
    and #$0FFF
    tax
    pla
    cmp f:txt_ram,x
    beq :+
    sta f:txt_ram,x
    txa
    jsr VidDirty
:   lda hu_dst
    clc
    adc #2
    sta hu_dst
    rts

; TxtAdv2: video.write_text16(&hu_dst, A); video.write_text16(0x7E + hu_dst, X)
; (a character of the two row fonts)
TxtAdv2:
    stx hu_row2
    jsr TxtAdv
    lda hu_dst
    clc
    adc #$7E
    ldx hu_row2
    jmp VidWriteText16

;----------------------------------------------------------------------------
; HudInit (SNES only; the OHud constructor, ohud.cpp 25, is empty): hud_col =
; GREY, the default colour argument of blit_text_new (BSS starts at 0)
;----------------------------------------------------------------------------
HudInit:
    lda #HUD_GREY
    sta hud_col
    rts

;----------------------------------------------------------------------------
; draw_main_hud (ohud.cpp 37): HUD labels (MODE_ORIGINAL)
;----------------------------------------------------------------------------
HudDrawMainHud:
    lda #HUD_LAP1
    jsr HudBlitText1
    lda #HUD_LAP2
    jsr HudBlitText1
    lda #HUD_TIME1
    jsr HudBlitText1
    lda #HUD_TIME2
    jsr HudBlitText1
    lda #HUD_SCORE1
    jsr HudBlitText1
    lda #HUD_SCORE2
    jsr HudBlitText1
    lda #HUD_STAGE1
    jsr HudBlitText1
    lda #HUD_STAGE2
    jsr HudBlitText1
    lda #HUD_ONE
    jsr HudBlitText1
    jmp HudDoMiniMap
    ; (MODE_TTRIAL / MODE_CONT branches: not classic, omitted)

;----------------------------------------------------------------------------
; clear_timetrial_text (ohud.cpp 73)
;----------------------------------------------------------------------------
HudClearTimetrialText:
    ; blit_text_big(4, "            "): not classic, omitted
    lda #HUD_GREY           ; default colour
    sta hud_col
    lda #16
    ldx #7
    ldy #StrBlank12
    jmp HudBlitTextNew

; draw_fps_counter (ohud.cpp 79): CannonBall fps display, not classic: omitted

;----------------------------------------------------------------------------
; do_mini_map (ohud.cpp 89)
;----------------------------------------------------------------------------
HudDoMiniMap:
    lda game_state          ; (int8)
    and #$00FF
    cmp #GS_ATTRACT
    bne :+
    rts
:   jsr HudSetupMiniMap
    jmp DrawMiniMap         ; (A = tile_addr; the high word X is 0)

;----------------------------------------------------------------------------
; setup_mini_map (ohud.cpp 103): -> A = tile address low word, X = high word
;----------------------------------------------------------------------------
HudSetupMiniMap:
    lda route_info          ; (uint16) route_info > 0x4F: clamp
    cmp #$0050
    bcc :+
    lda #$004F
    sta route_info
:   tax
    lda f:RouteMapping,x
    and #$00FF
    asl a
    asl a
    clc
    adc #.loword(TILES_MINIMAP)
    ldx #.hiword(TILES_MINIMAP) ; (no carry: at most TILES_MINIMAP + $78)
    rts

;----------------------------------------------------------------------------
; draw_mini_map (ohud.cpp 121): A = tile_addr (rom0, < $10000)
;----------------------------------------------------------------------------
DrawMiniMap:
    sta hu_src
    tax
    lda f:R0B0,x            ; BASE | read8(&tile_addr)
    and #$00FF
    ora #MM_BASE
    tax
    lda #MM_DST
    jsr VidWriteText16
    ldx hu_src
    lda f:R0B0+1,x
    and #$00FF
    ora #MM_BASE
    tax
    lda #MM_DST + 2
    jsr VidWriteText16
    ldx hu_src
    lda f:R0B0+2,x
    and #$00FF
    ora #MM_BASE
    tax
    lda #MM_DST + $80
    jsr VidWriteText16
    ldx hu_src
    lda f:R0B0+3,x
    and #$00FF
    ora #MM_BASE
    tax
    lda #MM_DST + $82
    jmp VidWriteText16

;----------------------------------------------------------------------------
; draw_timer1 (ohud.cpp 145): A = time (uint16)
;----------------------------------------------------------------------------
HudDrawTimer1:
    sta hu_t
    lda game_state          ; return if < GS_START1 or > GS_INGAME (int8)
    and #$00FF
    sec
    sbc #GS_START1
    cmp #GS_INGAME - GS_START1 + 1
    bcc :+
    rts
:   lda freeze_timer        ; (bool)
    and #$00FF
    bne @off
    lda hu_t                ; time > 0x99 ? 0x99 : time
    cmp #$009A
    bcc :+
    lda #$0099
:   ldx #$00BE              ; 0x1100BE
    ldy #TIMER_BASE
    jsr HudDrawTimer2
    ; blank out the OFF text area (the C++ address is 0x110C2 (sic):
    ; & $FFF = $0C2, the same text RAM word as 0x1100C2)
    lda #$00C2
    ldx #0
    jsr VidWriteText16
    lda #$0142              ; 0x110C2 + 0x80
    ldx #0
    jmp VidWriteText16
@off:
    ; timer frozen: "OFF"
    lda #7
    ldx #1
    jsr HudTranslate
    sta hu_dst
    lda #OFF_O
    ldx #OFF_O + 1
    jsr TxtAdv2
    lda #OFF_F
    ldx #OFF_F + 1
    jsr TxtAdv2
    lda #OFF_F
    ldx #OFF_F + 1
    jmp TxtAdv2

;----------------------------------------------------------------------------
; draw_timer2 (ohud.cpp 178): A = time_counter, X = addr, Y = base_tile
;----------------------------------------------------------------------------
HudDrawTimer2:
    stx hu_dst
    sty hu_base
    sta hu_t
    and #$00F0              ; digit2 = (time & 0xF0) >> 4
    lsr a
    lsr a
    lsr a
    lsr a
    sta hu_d2
    lda hu_t                ; low digit: value = (digit1 << 1) + base_tile
    and #$000F
    asl a
    clc
    adc hu_base
    sta hu_t
    tax
    lda hu_dst
    clc
    adc #2
    jsr VidWriteText16
    ldx hu_t
    inx
    lda hu_dst
    clc
    adc #$82
    jsr VidWriteText16
    lda hu_d2               ; high digit: value = digit2 << 1
    asl a
    beq @blank
    clc
    adc hu_base
    sta hu_t
    tax
    lda hu_dst
    jsr VidWriteText16
    ldx hu_t
    inx
    lda hu_dst
    clc
    adc #$80
    jmp VidWriteText16
@blank:
    ldx #0
    lda hu_dst
    jsr VidWriteText16
    ldx #0
    lda hu_dst
    clc
    adc #$80
    jmp VidWriteText16

;----------------------------------------------------------------------------
; draw_lap_timer (ohud.cpp 204): A = addr, X = bank 0 address of digits[]
; (3 BCD bytes), Y = ms_value
;----------------------------------------------------------------------------
HudDrawLapTimer:
    sta hu_dst
    tya
    and #$00FF              ; (uint8)
    sta hu_ms
    lda a:0,x               ; digits[0]
    and #$00FF
    sta hu_d1
    lda a:1,x               ; digits[1]
    and #$00FF
    sta hu_d2
    lda hu_d1               ; minute digit
    ora #LT_BASE
    jsr TxtAdv
    lda #LT_APOS1
    jsr TxtAdv
    lda hu_d2               ; seconds
    and #$00F0
    lsr a
    lsr a
    lsr a
    lsr a
    ora #LT_BASE
    jsr TxtAdv
    lda hu_d2
    and #$000F
    ora #LT_BASE
    jsr TxtAdv
    lda #LT_APOS2
    jsr TxtAdv
    lda hu_ms               ; milliseconds
    and #$00F0
    lsr a
    lsr a
    lsr a
    lsr a
    ora #LT_BASE
    jsr TxtAdv
    lda hu_ms
    and #$000F
    ora #LT_BASE
    jmp TxtAdv

;----------------------------------------------------------------------------
; draw_score_ingame (ohud.cpp 227): score in hud_v32
;----------------------------------------------------------------------------
HudDrawScoreIngame:
    lda game_state          ; return if < GS_START1 or > GS_BONUS (int8)
    and #$00FF
    sec
    sbc #GS_START1
    cmp #GS_BONUS - GS_START1 + 1
    bcc :+
    rts
:   lda #$0150              ; draw_score(0x110150, score, 2)
    ldy #2
    ; fall into HudDrawScore

;----------------------------------------------------------------------------
; draw_score (ohud.cpp 241): A = addr, Y = font, hud_v32 = score
;----------------------------------------------------------------------------
HudDrawScore:
    ldx #0                  ; text RAM
    bra DrawScoreAny

;----------------------------------------------------------------------------
; draw_score_tile (ohud.cpp 282): the same, written to tile RAM
;----------------------------------------------------------------------------
HudDrawScoreTile:
    ldx #1
DrawScoreAny:
    stx hu_tile
    sta hu_dst
    tya
    and #$00FF              ; (uint8) font
    xba
    asl a                   ; (font << 9) & $FFFF
    ora #$8130              ; BASE = 0x30 | (font << 9) | 0x8100
    sta hu_base
    ; digits[0..7] = the score's nibbles, most significant first
    ldx #0
    ldy #3
@nib:
    lda hud_v32,y
    and #$00F0
    lsr a
    lsr a
    lsr a
    lsr a
    sta hu_dig,x
    lda hud_v32,y
    and #$000F
    sta hu_dig+2,x
    inx
    inx
    inx
    inx
    dey
    bpl @nib
    ; blank tiles until the first non-zero digit, then digits
    stz hu_found
    stz hu_i
@loop:
    lda hu_i
    asl a
    tax
    lda hu_found
    bne @dig
    lda hu_dig,x
    bne @dig
    lda #SC_BLANK
    bra @w
@dig:
    lda #1
    sta hu_found
    lda hu_dig,x
    clc
    adc hu_base
@w: jsr ScoreWrite
    inc hu_i
    lda hu_i
    cmp #7
    bcc @loop
    lda hu_dig+14           ; always draw the last digit
    clc
    adc hu_base
    ; fall into ScoreWrite

; ScoreWrite: A = tile: write_text16 / write_tile16(&hu_dst, A)
ScoreWrite:
    tax
    lda hu_tile
    bne @tile
    lda hu_dst
    jsr VidWriteText16
    bra @adv
@tile:
    lda hu_dst
    jsr VidWriteTile16
@adv:
    lda hu_dst
    clc
    adc #2
    sta hu_dst
    rts

;----------------------------------------------------------------------------
; draw_stage_number (ohud.cpp 324): A = addr, X = digit, Y = col
;----------------------------------------------------------------------------
HudDrawStageNumber:
    sta hu_dst
    tya
    and #$00FF
    xba                     ; (col << 8) & $FFFF
    clc
    adc #DIGIT_BASE
    sta hu_base             ; (col << 8) + DIGIT_BASE
    txa
    and #$00FF              ; (uint8) digit
    cmp #10
    bcs @two
    clc
    adc hu_base
    tax
    lda hu_dst
    jmp VidWriteText16
@two:
    jsr Convert16DecHex     ; hex
    sta hu_t
    and #$000F
    clc
    adc hu_base
    tax
    lda hu_dst
    clc
    adc #2
    jsr VidWriteText16
    lda hu_t                ; hex >> 4
    lsr a
    lsr a
    lsr a
    lsr a
    clc
    adc hu_base
    tax
    lda hu_dst
    jmp VidWriteText16

;----------------------------------------------------------------------------
; draw_rev_counter (ohud.cpp 342)
;----------------------------------------------------------------------------
HudDrawRevCounter:
    lda game_state          ; return if <= GS_INIT_GAME (int8)
    and #$00FF
    sec
    sbc #GS_INIT_GAME + 1
    cmp #$80 - (GS_INIT_GAME + 1)
    bcc :+
    rts
:   lda rev_stop_flag       ; revs = rev_stop_flag ? revs_post_stop : revs >> 16
    beq :+
    lda revs_post_stop
    bra :++
:   lda revs+2
:   sta hu_revs
    lda car_increment+2     ; car_increment >> 16 == 0: boost (countdown)
    bne :+
    lda hu_revs
    lsr a
    lsr a
    clc
    adc hu_revs
    sta hu_revs
:   lda hu_revs             ; revs >>= 4
    lsr a
    lsr a
    lsr a
    lsr a
    sta hu_revs
    ; 20 writes, two per cell ($110DB4 + 2 * (i >> 1)): the cell keeps the
    ; odd index's value; the even one only matters for the dirty row mark
    ; (they differ only in the pair holding index revs, i.e. revs < 20)
    cmp #20
    bcc :+
    lda #20
:   sta hu_t                ; min(revs, 20) * 20: RevCells row
    asl a
    asl a
    adc hu_t                ; (C = 0)
    asl a
    asl a
    tay                     ; (Y survives VidWriteText16)
    lda #$0DB4
@loop:
    pha
    tyx
    lda f:RevCells,x
    tax
    lda 1,s
    jsr VidWriteText16
    iny
    iny
    pla
    inc a
    inc a
    cmp #$0DB4 + 20
    bcc @loop
    sta hu_dst              ; (the loop's final values)
    lda #$14
    sta hu_i
    lda hu_revs
    cmp #20
    bcs :+
    lda #$0DB4
    jsr VidDirty            ; even value != odd value in the pair of revs
:   lda rev_pitch1
    sta rev_pitch2
    rts

;----------------------------------------------------------------------------
; blit_speed (ohud.cpp 399): A = dst_addr, X = speed
;----------------------------------------------------------------------------
HudBlitSpeed:
    sta hu_dst
    txa
    jsr Convert16DecHex
    sta hu_t
    and #$000F
    sta hu_d1               ; digit1
    lda hu_t
    and #$00F0
    lsr a
    lsr a
    lsr a
    lsr a
    sta hu_d2               ; digit2
    lda hu_t
    and #$0F00
    xba                     ; digit3
    asl a                   ; digit3 <<= 1
    bne @d3
    sta hu_d3
    lda hu_d2
    asl a                   ; digit2 <<= 1
    beq :+
    clc
    adc #SPD_BASE
:   sta hu_d2
    bra @d1
@d3:
    clc
    adc #SPD_BASE
    sta hu_d3
    lda hu_d2
    asl a
    clc
    adc #SPD_BASE
    sta hu_d2
@d1:
    lda hu_d1
    asl a
    clc
    adc #SPD_BASE
    sta hu_d1
    lda hu_d3               ; top line of tiles
    jsr TxtAdv
    lda hu_d2
    jsr TxtAdv
    ldx hu_d1
    lda hu_dst
    jsr VidWriteText16
    lda hu_dst              ; next horizontal line of number tiles
    clc
    adc #$7C
    sta hu_dst
    lda hu_d3               ; bottom line of tiles
    beq :+
    inc hu_d3
:   lda hu_d2
    beq :+
    inc hu_d2
:   inc hu_d1
    lda hu_d3
    jsr TxtAdv
    lda hu_d2
    jsr TxtAdv
    ldx hu_d1
    lda hu_dst
    jmp VidWriteText16

;----------------------------------------------------------------------------
; blit_large_digit (ohud.cpp 444): A = digit, destination hud_addr (+= 2)
;----------------------------------------------------------------------------
HudBlitLargeDigit:
    and #$00FF              ; (uint8) digit
    sta hu_t
    clc
    adc #$80
    ora #$8C00
    tax
    lda hud_addr
    jsr VidWriteText16
    lda hu_t
    clc
    adc #$81
    ora #$8C00
    tax
    lda hud_addr
    clc
    adc #$80
    jsr VidWriteText16
    lda hud_addr
    clc
    adc #2
    sta hud_addr
    rts

;----------------------------------------------------------------------------
; draw_copyright_text (ohud.cpp 458)
;----------------------------------------------------------------------------
HudDrawCopyrightText:
    lda #TEXT1_1986_SEGA
    jsr HudBlitText1
    lda #TEXT1_COPYRIGHT
    jmp HudBlitText1

;----------------------------------------------------------------------------
; draw_insert_coin (ohud.cpp 467)
;----------------------------------------------------------------------------
HudDrawInsertCoin:
    .ifndef LOCKSTEP
    ; Console prompt: this row is cleared when the race starts.
    lda tick_counter
    dec a
    eor tick_counter
    and #$0010
    beq @console_done
    ldy #ConsoleStart
    lda tick_counter
    and #$0010
    bne :+
    ldy #ConsoleStartBlank
:   lda #HUD_GREY
    sta hud_col
    lda #11
    ldx #21
    jsr HudBlitTextNew
    ldy #ConsoleSettings
    lda #12
    ldx #23
    jmp HudBlitTextNew
@console_done:
    rts
    .else
    lda tick_counter        ; (tick_counter ^ (tick_counter - 1)) & BIT_4
    dec a
    eor tick_counter
    and #$0010
    bne :+
    rts
:   lda credits             ; (uint8)
    and #$00FF
    beq @coins
    lda tick_counter        ; flash press start
    and #$0010
    beq :+
    lda #TEXT1_PRESS_START  ; (outputs->set_digital(D_START_LAMP): omitted)
    jmp HudBlitText1
:   lda #TEXT1_CLEAR_START  ; (outputs->clear_digital(D_START_LAMP): omitted)
    jmp HudBlitText1
@coins:
    ; flash insert coins (config.engine.freeplay = 0: the freeplay
    ; PRESS START tiles branch is omitted)
    lda tick_counter
    and #$0010
    beq :+
    lda #TEXT1_INSERT_COINS
    jmp HudBlitText1
:   lda #TEXT1_CLEAR_COINS
    jmp HudBlitText1
    .endif

;----------------------------------------------------------------------------
; draw_credits (ohud.cpp 515) (config.engine.freeplay = 0: TEXT1_FREEPLAY
; branch omitted)
;----------------------------------------------------------------------------
HudDrawCredits:
    .ifndef LOCKSTEP
    rts                     ; no credit counter or FREE PLAY label
    .else
    lda credits             ; blit digit: credits | 0x8630 at 0x110D44
    and #$00FF
    ora #$8630
    tax
    lda #$0D44
    jsr VidWriteText16
    lda credits
    and #$00FF
    cmp #2
    bcc :+
    lda #TEXT1_CREDITS
    jmp HudBlitText1
:   lda #TEXT1_CREDIT
    jmp HudBlitText1
    .endif

;----------------------------------------------------------------------------
; blit_text1 (ohud.cpp 556): A = rom0 address of the text
;   long: destination, word: counter, word: tile data (high byte), then one
;   tile byte per tile (counter + 1 tiles)
;----------------------------------------------------------------------------
HudBlitText1:
    tax
    lda f:R0B0+2,x          ; dst_addr = read32(): low word (big endian)
    xba
    sta hu_dst
    lda f:R0B0+4,x          ; counter = read16()
    xba
    sta hu_cnt
    lda f:R0B0+6,x          ; data = read16()
    xba
    sta hu_data
    txa
    clc
    adc #8
    sta hu_src
BlitText1Loop:
    stz hu_i
@loop:
    ldx hu_src              ; data = (data & 0xFF00) | read8(&src_addr)
    lda f:R0B0,x
    inc hu_src
    and #$00FF
    sta hu_t
    lda hu_data
    and #$FF00
    ora hu_t
    sta hu_data
    jsr TxtAdv
    inc hu_i                ; for (uint16 i = 0; i <= counter; i++)
    lda hu_i
    cmp hu_cnt
    bcc @loop
    beq @loop
    rts

;----------------------------------------------------------------------------
; blit_text1 (ohud.cpp 570): A = x, X = y, Y = rom0 address of the text
;----------------------------------------------------------------------------
HudBlitText1XY:
    sty hu_src
    and #$00FF              ; (uint8) x
    pha
    txa
    and #$00FF              ; (uint8) y
    tax
    pla
    jsr HudTranslate
    sta hu_dst
    ldx hu_src              ; src_addr += 4
    lda f:R0B0+4,x          ; counter
    xba
    sta hu_cnt
    lda f:R0B0+6,x          ; data
    xba
    sta hu_data
    txa
    clc
    adc #8
    sta hu_src
    jmp BlitText1Loop

;----------------------------------------------------------------------------
; blit_text2 (ohud.cpp 600): A = rom0 address of the text (double row font)
;   word: text RAM offset, byte: palette, byte: counter, then characters
;----------------------------------------------------------------------------
HudBlitText2:
    tax
    lda f:R0B0,x            ; dst_addr = 0x110000 + read16()
    xba
    sta hu_dst
    lda f:R0B0+2,x          ; pal = read8()
    and #$00FF
    xba                     ; pal << 8
    asl a                   ; (pal << 9) & $FFFF, C = pal bit 7
    adc #0                  ; | (pal >> 7) & 1
    ora #$80A0
    sta hu_data
    lda f:R0B0+3,x          ; counter = read8()
    and #$00FF
    sta hu_cnt
    txa
    clc
    adc #4
    sta hu_src
    stz hu_i
@loop:
    ldx hu_src              ; data = read8(&src_addr)
    lda f:R0B0,x
    inc hu_src
    and #$00FF
    cmp #$20
    bne @chr
    lda #0                  ; blank space (both rows)
    tax
    bra @w
@chr:
    sec
    sbc #$41                ; character -> index (A = 0)
    asl a
    clc
    adc hu_data             ; (data * 2) + pal
    tax
    inx                     ; second row: data + 1
@w: jsr TxtAdv2
    inc hu_i
    lda hu_i
    cmp hu_cnt
    bcc @loop
    beq @loop
    rts

; draw_debug_info (ohud.cpp 637): CannonBall debug display, not classic: omitted
; blit_text_big (ohud.cpp 651): CannonBall big text (time trial, calibration),
; not classic: omitted

;----------------------------------------------------------------------------
; blit_text_new (ohud.cpp 720): A = x, X = y, Y = bank 0 address of a
; 0-terminated string, hud_col = colour (reset to HUD_GREY on exit)
;----------------------------------------------------------------------------
HudBlitTextNew:
    sty hu_src
    jsr HudTranslate
    sta hu_dst
    lda hud_col             ; (pal << 8) & $FFFF
    and #$00FF
    xba
    sta hu_base
@loop:
    ldx hu_src              ; c = *text++
    lda a:0,x
    and #$00FF
    beq @done
    inc hu_src
    cmp #'a'                ; lowercase -> uppercase
    bcc @nlc
    cmp #'z' + 1
    bcs @nlc
    sec
    sbc #$20
    bra @w
@nlc:
    cmp #$A9                ; Latin-1 copyright sign -> $10
    bne :+
    lda #$10
    bra @w
:   cmp #'.'                ; '.' -> $5B ('-' -> $2D: unchanged)
    bne @w
    lda #$5B
@w: cmp #$80                ; (pal << 8) | c with c a signed char
    bcc :+
    ora #$FF00
:   ora hu_base
    jsr TxtAdv
    bra @loop
@done:
    lda #HUD_GREY           ; default colour for the next call
    sta hud_col
    rts

;----------------------------------------------------------------------------
; translate (ohud.cpp 745): A = x, X = y -> A = text RAM address (low word)
; (BASE_POS = the default 0x110030)
;----------------------------------------------------------------------------
HudTranslate:
    cmp #64                 ; x > 63: 63
    bcc :+
    lda #63
:   pha
    txa
    cmp #28                 ; y > 27: 27
    bcc :+
    lda #27
:   asl a                   ; y * 64
    asl a
    asl a
    asl a
    asl a
    asl a
    clc
    adc 1,s                 ; + x
    asl a
    clc
    adc #TRANSLATE_BASE
    plx
    rts

;----------------------------------------------------------------------------
; outils::convert16_dechex (outils.cpp 215), local port: A = value -> A
;----------------------------------------------------------------------------
Convert16DecHex:
    ldx #$FFFF              ; top_byte = -1
:   inx                     ; top_byte++
    sec
    sbc #100                ; lookup -= 100 (int16)
    bpl :-                  ; while (lookup >= 0)
    clc
    adc #100
    phx
    tax
    lda f:DecToHex,x
    and #$00FF
    sta hu_cv
    pla                     ; (top_byte << 8) | DEC_TO_HEX[lookup]
    xba
    and #$FF00
    ora hu_cv
    rts

.segment "RODATA"
; RevCells: draw_rev_counter cell values (odd index 2k+1 of each pair) for
; min(revs, 20) = 0..20, 10 words per row
RevCells:
    .include "asset_RevCells.inc"
; setup_mini_map ROUTE_MAPPING: route_info -> mini map tile block
RouteMapping:
    .include "asset_RouteMapping.inc"
; outils::DEC_TO_HEX: 0-99 -> BCD
DecToHex:
    .repeat 100, n
    .byte ((n / 10) << 4) | (n .mod 10)
    .endrepeat
; clear_timetrial_text
StrBlank12:
    .byte "            ", 0
ConsoleSettings: .asciiz "SELECT: SETTINGS"
ConsoleStart:
    .byte "PRESS START TO PLAY", 0
ConsoleStartBlank:
    .res .strlen("PRESS START TO PLAY"), ' '
    .byte 0
.endif
