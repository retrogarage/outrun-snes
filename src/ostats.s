; OStats: in-game statistics - port of the original CannonBall
; engine/ostats.cpp (classic arcade): stage timers and lap times, route
; info, speed to score conversion, score (32-bit packed BCD), the extend
; play / checkpoint time bonus.
;
; Classic configuration: fix_timer = 0 (lap_ms = LAP_MS_64, 64 ticks per
; second), fix_bugs = 0, dip_time = 1, MODE_ORIGINAL (time trial and
; continuous mode code omitted).
;
; 1-byte C++ members are stored as words (int8: sign-extended, uint8/bool:
; high byte 0), except stage_times (uint8[15][3] byte array, bank 0: the
; HUD takes its address).  1-byte members of other modules are read
; through their low byte.
.ifdef NEWGAME
.p816
.smart
.include "sa1.inc"
.include "globals.inc"
.include "ogame.inc"

.import game_state, freeze_timer, checkpoint_marker, stage_lookup_off
.import BcdAdd, bcd_a, bcd_b
.import HudBlitText1, HudDrawLapTimer, HudDrawStageNumber, HudDrawScoreIngame
.import hud_v32
.import TrafficSetMax, SndQueueSound

.export StatsInit, StatsClearStageTimes, StatsClearRouteInfo, StatsDoTimers
.export StatsConvertSpeedScore, StatsUpdateScore, StatsInitNextLevel
.export credits, cur_stage, extend_play_timer, frame_counter, frame_reset
.export game_completed, lap_ms, route_info, routes, score, stage_counters
.export stage_times, time_counter, TIME

; A = the int8 in the low byte of A, sign-extended
.macro SEXT8
    and #$00FF
    eor #$0080
    sec
    sbc #$0080
.endmacro

.segment "BSS"
cur_stage:          .res 2      ; int8
score:              .res 4      ; uint32 (BCD)
route_info:         .res 2      ; uint16
routes:             .res 16     ; uint16[8]
frame_counter:      .res 2      ; int16
time_counter:       .res 2      ; int16 (BCD)
extend_play_timer:  .res 2      ; int16
stage_counters:     .res 30     ; int16[15]
game_completed:     .res 2      ; bool
credits:            .res 2      ; uint8
; stage_times[-1] is read at cur_stage 0 (checkpoint lap time): in the C++
; object these are the (zero) top bytes of the lap_ms pointer
st_neg:             .res 3
stage_times:        .res 45     ; uint8[15][3]: minutes, seconds (BCD), ms counter
ms_value:           .res 2      ; uint8
st_t:               .res 2

.segment "SA1CODE"
.a16
.i16

;----------------------------------------------------------------------------
; init (ostats.cpp 48): ttrial = false; lap_ms = LAP_MS_64 (the lap_ms table)
;----------------------------------------------------------------------------
StatsInit:
    stz credits
    rts

;----------------------------------------------------------------------------
; clear_stage_times (ostats.cpp 55)
;----------------------------------------------------------------------------
StatsClearStageTimes:
    ldx #0
:   stz stage_counters,x
    inx
    inx
    cpx #15*2
    bne :-
    ldx #0
    sep #$20
:   stz stage_times,x
    inx
    cpx #15*3
    bne :-
    rep #$20
    rts

;----------------------------------------------------------------------------
; clear_route_info (ostats.cpp 66)
;----------------------------------------------------------------------------
StatsClearRouteInfo:
    stz route_info
    ldx #0
:   stz routes,x
    inx
    inx
    cpx #8*2
    bne :-
    rts

; StageOfs: A = stage index (int16) -> X = A * 3 (stage_times row offset)
StageOfs:
    sta st_t
    asl a
    clc
    adc st_t
    tax
    rts

;----------------------------------------------------------------------------
; do_timers (ostats.cpp 76)
;----------------------------------------------------------------------------
StatsDoTimers:
    lda game_state
    and #$00FF
    cmp #GS_INGAME
    beq :+
    rts
:   jsr IncLapTimer
    lda cur_stage               ; stage_counters[cur_stage]++
    SEXT8
    asl a
    tax
    inc stage_counters,x
    lda cur_stage               ; draw_lap_timer(0x11016C, stage_times[cur_stage], ms_value)
    SEXT8
    jsr StageOfs
    txa
    clc
    adc #stage_times
    tax
    lda ms_value
    and #$00FF
    tay
    lda #$016C
    jmp HudDrawLapTimer

;----------------------------------------------------------------------------
; inc_lap_timer (ostats.cpp 100)
;----------------------------------------------------------------------------
IncLapTimer:
    lda cur_stage
    SEXT8
    jsr StageOfs
    sep #$20
    lda stage_times+2,x         ; ++stage_times[cur_stage][2] (uint8)
    inc a
    sta stage_times+2,x
    rep #$20
    and #$00FF
    cmp #$40
    bcc @ms
    sep #$20                    ; looped ms: add a second
    stz stage_times+2,x
    rep #$20
    lda stage_times+1,x
    jsr BcdInc
    sep #$20
    sta stage_times+1,x
    rep #$20
    and #$00FF
    cmp #$60
    bne @ms
    sep #$20                    ; looped seconds: add a minute
    stz stage_times+1,x
    rep #$20
    lda stage_times,x
    jsr BcdInc
    sep #$20
    sta stage_times,x
    rep #$20
@ms:
    lda stage_times+2,x         ; ms_value = lap_ms[stage_times[cur_stage][2]]
    and #$00FF
    tax
    lda f:lap_ms,x
    and #$00FF
    sta ms_value
    rts

; BcdInc: A = uint8 v (low byte) -> A = (uint8) bcd_add(v, 1); X preserved
BcdInc:
    and #$00FF
    sta bcd_a
    stz bcd_a+2
    lda #1
    sta bcd_b
    stz bcd_b+2
    phx
    jsr BcdAdd
    plx
    lda bcd_b
    and #$00FF
    rts

;----------------------------------------------------------------------------
; convert_speed_score (ostats.cpp 122): A = speed
;----------------------------------------------------------------------------
StatsConvertSpeedScore:
    lsr a
    lsr a
    lsr a
    lsr a
    asl a
    tax
    lda f:Convert,x
    ldx #0
    ; fall into StatsUpdateScore

;----------------------------------------------------------------------------
; update_score (ostats.cpp 139): A = value low word, X = high word
;----------------------------------------------------------------------------
StatsUpdateScore:
    sta bcd_a                   ; score = bcd_add(value, score)
    stx bcd_a+2
    lda score
    sta bcd_b
    lda score+2
    sta bcd_b+2
    jsr BcdAdd
    lda bcd_b
    sta score
    lda bcd_b+2
    sta score+2
    cmp #$9999                  ; score > 0x99999999 (unsigned)
    bcc @draw
    bne @clamp
    lda score
    cmp #$999A
    bcc @draw
@clamp:
    lda #$9999
    sta score
    sta score+2
@draw:
    lda score
    sta hud_v32
    lda score+2
    sta hud_v32+2
    jmp HudDrawScoreIngame

;----------------------------------------------------------------------------
; init_next_level (ostats.cpp 163)
;----------------------------------------------------------------------------
StatsInitNextLevel:
    lda extend_play_timer
    bne :+
    jmp @checkpoint
:   dec a                       ; --extend_play_timer <= 0: clear the text
    sta extend_play_timer
    beq @clear
    bmi @clear
    dec a                       ; flash: ((t - 1) ^ t) & BIT_3
    eor extend_play_timer
    and #$0008
    beq @r
    lda extend_play_timer
    and #$0008
    beq @off
    lda #TEXT1_EXTEND1
    jsr HudBlitText1
    lda #TEXT1_EXTEND2
    jmp HudBlitText1
@off:
    lda #TEXT1_EXTEND_CLEAR1
    jsr HudBlitText1
    lda #TEXT1_EXTEND_CLEAR2
    jmp HudBlitText1
@clear:
    lda #TEXT1_EXTEND_CLEAR1
    jsr HudBlitText1
    lda #TEXT1_EXTEND_CLEAR2
    jsr HudBlitText1
    lda #TEXT1_LAPTIME_CLEAR1
    jsr HudBlitText1
    lda #TEXT1_LAPTIME_CLEAR2
    jmp HudBlitText1
@r: rts

@checkpoint:
    lda game_state              ; in-game and checkpoint passed
    and #$00FF
    cmp #GS_INGAME
    bne @r
    lda checkpoint_marker
    and #$00FF
    beq @r
    stz checkpoint_marker
    lda #$80
    sta extend_play_timer
    lda freeze_timer
    and #$00FF
    bne @lap
    ; time_counter = bcd_add(time_counter, TIME[dip_time * 40 + stage_lookup_off])
    lda time_counter
    sta bcd_a
    ldx #0                      ; (int16 -> uint32)
    cmp #$8000
    bcc :+
    dex
:   stx bcd_a+2
    .ifndef LOCKSTEP
    .import SettingsTime
    lda stage_lookup_off
    jsl $CF0000+SettingsTime
    .else
    ldx stage_lookup_off
    lda f:TIME,x
    and #$00FF
    .endif
    sta bcd_b
    stz bcd_b+2
    jsr BcdAdd
    lda bcd_b
    sta time_counter
    sec                         ; time_counter > 0x99 (int16)
    sbc #$009A
    bvc :+
    eor #$8000
:   bmi @lap
    lda #$0099
    sta time_counter
@lap:
    ; last lap time (fix_bugs = 0: the current ms value)
    lda #TEXT1_LAPTIME1
    jsr HudBlitText1
    lda #TEXT1_LAPTIME2
    jsr HudBlitText1
    lda cur_stage               ; draw_lap_timer(0x110554, stage_times[cur_stage-1], ms_value)
    SEXT8
    dec a
    jsr StageOfs
    txa
    clc
    adc #stage_times
    tax
    lda ms_value
    and #$00FF
    tay
    lda #$0554
    jsr HudDrawLapTimer
    jsr TrafficSetMax
    lda #S_YM_CHECKPOINT
    jsr SndQueueSound
    lda #S_VOICE_CHECKPOINT
    jsr SndQueueSound
    lda cur_stage               ; draw_stage_number(0x110D76, cur_stage + 1) (GREEN)
    SEXT8
    inc a
    and #$00FF
    tax
    ldy #HUD_GREEN
    lda #$0D76
    jmp HudDrawStageNumber

.segment "RODATA"
; ostats.frame_reset (const 30)
frame_reset:
    .word 30

; lap_ms = LAP_MS_64 (fix_timer = 0): 0-63 -> BCD hundredths
lap_ms:
    .include "asset_lap_ms.inc"

; TIME: the dip_time = 1 (Normal) row, C++ TIME[40 + stage_lookup_off].  The
; row is stored twice so that TIME + i and TIME + 40 + i (the full C++ table
; index) both give the classic value.
TIME:
    .repeat 2
    .include "asset_TIME.inc"
    .endrepeat

; convert_speed_score CONVERT[]
Convert:
    .include "asset_Convert.inc"
.endif
