; OBonus: bonus points on completing the game - port of the original
; CannonBall engine/obonus.cpp (classic arcade): bonus seconds from the time
; remaining and the lap milliseconds, countdown adding 100K points per step,
; large yellow seconds display (text layer).
;
; Text RAM addresses are the low 16 bits of the arcade address ($110000+);
; the text pointer passed to HudBlitLargeDigit is hud_addr.
.ifdef NEWGAME
.p816
.smart
.include "sa1.inc"
.include "globals.inc"
.include "ogame.inc"

.import HudBlitText1, HudBlitText2, HudBlitLargeDigit, hud_addr
.import VidWriteText16, SndQueueSound, StatsUpdateScore
.import BcdAdd, bcd_a, bcd_b, SDiv16u
.import time_counter, stage_times

.export BonusInit, BonusDoText
.export bonus_control, bonus_state, bonus_timer, bonus_secs, bonus_counter

BONUS_DISABLE      = 0      ; bonus_control
BONUS_TEXT_INIT    = 0      ; bonus_state
BONUS_TEXT_SECONDS = 1
BONUS_TEXT_CLEAR   = 2
BONUS_TEXT_DONE    = 3
COL2      = $80             ; blit_bonus_secs
TILE_DOT  = $8C2E
TILE_ZERO = $8420

.segment "BSS"
bonus_control: .res 2       ; int8 (BONUS_DISABLE .. BONUS_END)
bonus_state:   .res 2       ; int8 (BONUS_TEXT_*)
bonus_timer:   .res 2       ; int16: bonus mode logic timer (rev. A)
bonus_secs:    .res 2       ; int16: bonus seconds
bonus_counter: .res 2       ; int16: timing counter
bn_tc:     .res 2           ; time_counter_bak
bn_total:  .res 2           ; total_time
bn_i:      .res 2
bn_n:      .res 2
bn_t:      .res 4
bn_d1:     .res 2
bn_d2:     .res 2
bn_d3:     .res 2

.segment "SA1CODE"
.a16
.i16

;----------------------------------------------------------------------------
; init (obonus.cpp 25)
;----------------------------------------------------------------------------
BonusInit:
    stz bonus_control       ; BONUS_DISABLE
    stz bonus_state         ; BONUS_TEXT_INIT
    stz bonus_counter
    rts

;----------------------------------------------------------------------------
; do_bonus_text (obonus.cpp 35): text and countdown time (source $99E0)
;----------------------------------------------------------------------------
BonusDoText:
    lda bonus_state         ; (int8)
    and #$00FF
    cmp #BONUS_TEXT_INIT
    bne :+
    jmp InitBonusText
:   cmp #BONUS_TEXT_SECONDS
    bne :+
    jmp DecrementBonusSecs
:   cmp #BONUS_TEXT_CLEAR
    beq :+
    cmp #BONUS_TEXT_DONE
    bne @ret
:   lda bonus_counter       ; bonus_counter < 60 (int16)
    sec
    sbc #60
    bvc :+
    eor #$8000
:   bpl :+
    inc bonus_counter
    rts
:   lda #TEXT2_BONUS_CLEAR1
    jsr HudBlitText2
    lda #TEXT2_BONUS_CLEAR2
    jsr HudBlitText2
    lda #TEXT2_BONUS_CLEAR3
    jmp HudBlitText2
@ret:
    rts

;----------------------------------------------------------------------------
; init_bonus_text (obonus.cpp 65): bonus seconds from the seconds remaining
; and the lap milliseconds; bonus text (source $9A9C)
;----------------------------------------------------------------------------
InitBonusText:
    lda #BONUS_TEXT_SECONDS
    sta bonus_state
    lda time_counter        ; time_counter_bak = (int16)(time_counter << 8)
    and #$00FF
    xba
    sta bn_tc
    lda #$30
    sta time_counter
    ; add the milliseconds remaining from the stage times (MODE_ORIGINAL)
    stz bn_total
    stz bn_i                ; i * 3
@ms:
    ldx bn_i
    lda f:stage_times+2,x   ; stage_times[i][2] (uint8 [15][3])
    and #$00FF
    tax
    lda f:DecToHex,x
    and #$00FF
    sta bcd_a
    stz bcd_a+2
    lda bn_total
    sta bcd_b
    stz bcd_b+2
    jsr BcdAdd              ; bcd_add(DEC_TO_HEX[ms], total_time)
    sta bn_total            ; (uint16)
    lda bn_i
    clc
    adc #3
    sta bn_i
    cmp #5 * 3
    bcc @ms
    lda bn_total            ; mask on the top digit of the lap milliseconds
    and #$00F0
    beq :+
    lsr a                   ; time_counter_bak |= 10 - (total_time >> 4)
    lsr a
    lsr a
    lsr a
    eor #$FFFF
    sec
    adc #10
    ora bn_tc
    sta bn_tc
:   ; e.g. 60 seconds on the clock and 3 from the lap ms: $6003 -> 603 (60.3)
    lda bn_tc
    and #$000F
    sta bonus_secs          ; digit_bot
    lda bn_tc
    xba
    and #$000F              ; (time_counter_bak >> 8) & $0F
    asl a
    sta bn_t
    asl a
    asl a
    clc
    adc bn_t                ; digit_mid = * 10
    clc
    adc bonus_secs
    sta bonus_secs
    lda bn_tc
    xba
    lsr a
    lsr a
    lsr a
    lsr a
    and #$000F              ; (time_counter_bak >> 12) & $0F
    asl a
    asl a
    sta bn_t                ; * 4
    asl a
    asl a
    asl a
    sta bn_t+2              ; * 32
    asl a                   ; * 64
    clc
    adc bn_t+2
    clc
    adc bn_t                ; digit_top = * 100
    clc
    adc bonus_secs
    sta bonus_secs
    ; write to the text layer
    lda #TEXT2_BONUS_POINTS ; "BONUS POINTS"
    jsr HudBlitText2
    lda #TEXT1_BONUS_STOP   ; full stop after bonus points
    jsr HudBlitText1
    lda #TEXT1_BONUS_SEC    ; "SEC"
    jsr HudBlitText1
    lda #TEXT1_BONUS_X      ; 'X' after SEC
    jsr HudBlitText1
    lda #TEXT1_BONUS_PTS    ; "PTS"
    jsr HudBlitText1
    ; big 100K number: int8 count, then count + 1 ASCII digits
    lda #$065A              ; dst_addr = $11065A
    sta hud_addr
    lda f:R0(TEXT1_BONUS_100K)
    and #$00FF
    cmp #$0080
    bcs @secs               ; (count < 0: no digit)
    inc a
    sta bn_n
    stz bn_i
@dig:
    ldx bn_i
    lda f:R0(TEXT1_BONUS_100K + 1),x
    and #$00FF
    sec
    sbc #$30
    asl a
    and #$00FF              ; (uint8)
    jsr HudBlitLargeDigit
    inc bn_i
    lda bn_i
    cmp bn_n
    bcc @dig
@secs:
    jmp BlitBonusSecs

;----------------------------------------------------------------------------
; decrement_bonus_secs (obonus.cpp 120): blit the seconds remaining
; (source $9A08)
;----------------------------------------------------------------------------
DecrementBonusSecs:
    lda bonus_counter       ; bonus_counter < 60 (int16)
    sec
    sbc #60
    bvc :+
    eor #$8000
:   bpl :+
    inc bonus_counter
    rts
:   lda bonus_counter       ; play signal 1 sound in a steady fashion
    dec a
    eor bonus_counter
    and #$0004              ; BIT_2
    bne :+
    lda #S_SIGNAL1
    jsr SndQueueSound
:   lda #$0000              ; increment the score by 100K points
    ldx #$0010              ; (update_score($100000))
    jsr StatsUpdateScore
    jsr BlitBonusSecs
    dec bonus_secs          ; --bonus_secs < 0 (int16)
    bpl :+
    lda #$FFFF
    sta bonus_counter
    lda #BONUS_TEXT_CLEAR
    sta bonus_state
    rts
:   inc bonus_counter
    rts

;----------------------------------------------------------------------------
; blit_bonus_secs (obonus.cpp 150): large yellow seconds remaining e.g. 23.3
; (source $9B7C).  bonus_secs is 0-1665 here (never negative when blitted),
; where the C++ uint32 digit arithmetic gives the three digits * 2:
; d1 = ((secs / 100) & $F) * 2, d2 = (secs % 100 / 10) * 2, d3 = (secs % 10) * 2
;----------------------------------------------------------------------------
BlitBonusSecs:
    lda bonus_secs
    ldx #100
    jsr SDiv16u             ; A = secs / 100, X = secs % 100
    and #$000F              ; d1 = (d1 & $F00) >> 7
    asl a
    sta bn_d1
    txa
    ldx #10
    jsr SDiv16u             ; A = tens, X = units
    asl a                   ; d2 = (d1 & $F0) >> 3
    sta bn_d2
    txa
    asl a                   ; d3 = (d1 & $F) << 1
    sta bn_d3
    lda #$0644              ; text_addr = $110644
    sta hud_addr
    lda bn_d1               ; digit 1
    beq :+
    jsr HudBlitLargeDigit
    bra @d2
:   lda hud_addr            ; (zero: blank tiles)
    ldx #TILE_ZERO
    jsr VidWriteText16
    lda hud_addr
    ora #COL2
    ldx #TILE_ZERO
    jsr VidWriteText16
    jsr TextAdv2
@d2:
    lda bn_d2               ; digit 2
    jsr HudBlitLargeDigit
    lda hud_addr            ; dot
    ora #COL2
    ldx #TILE_DOT
    jsr VidWriteText16
    jsr TextAdv2
    lda bn_d3               ; digit 3
    jmp HudBlitLargeDigit

; TextAdv2: text_addr += 2
TextAdv2:
    lda hud_addr
    clc
    adc #2
    sta hud_addr
    rts

.segment "RODATA"
; outils::DEC_TO_HEX (ported locally)
DecToHex:
    .repeat 100, n
    .byte ((n / 10) << 4) | (n .mod 10)
    .endrepeat
.endif
