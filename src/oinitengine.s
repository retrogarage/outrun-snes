; OInitEngine: core game engine routines - port of the original CannonBall
; engine/oinitengine.cpp (classic arcade): stage / road progression (road
; width, height and curve triggers from the track data), the road split
; state machine (forks, merge, checkpoint, next stage, bonus road), the car
; engine block (update_engine), the granular / fine road position and the
; crash / bonus sequence checks.
;
; Classic configuration: time trial and continuous mode code is omitted,
; init() always runs with level = 0 (A is ignored).
;
; 1-byte C++ members are stored as words (int8: sign-extended, uint8/bool:
; high byte 0).  1-byte members of other modules are read through their
; low byte and written with byte stores.
.ifdef NEWGAME
.p816
.smart
.include "sa1.inc"
.include "globals.inc"
.include "ogame.inc"

; ostats
.import StatsClearStageTimes, StatsClearRouteInfo, StatsInitNextLevel
.import game_completed, cur_stage, score, extend_play_timer, route_info, routes
; oroad (stage_lookup_off: registry oroad data, not defined by oroad.s;
; camera_x_off: the debug camera offset member, owned by oroad.s, unused here)
.import road_pos, road_width, road_ctrl, road_load_split, tilemap_h_target
.import height_lookup, pos_fine, stage_lookup_off, camera_x_off
; trackloader
.import TrkInitTrack, TrkInitTrackSplit, TrkInitTrackBonus, TrkReadCurve
.import TrkReadWidthHeight, trk_wh_off, trk_curve_off
; opalette / otiles / osprites
.import OPalSetupStage, SetupSkyCycle, ResetTilesPal
.import CopyPaletteData, ClearPaletteData, shadow_offset, sprite_scroll_speed
; oferrari
.import FerResetCar, FerMove, FerSetCurveAdjust, FerSetX, FerDoSkid
.import FerCheckWheels, FerSetBounds, FerDoSoundScoreSlip, car_ctrl_active
; ocrash
.import CrashClearState, CrashEnable, skid_counter, skid_counter_bak
.import spin_control1, spin_control2, coll_count1, coll_count2
; otraffic / osmoke / oanimseq / obonus / olevelobjs / oinputs / outrun
.import TrafficSetMax, traffic_split, bonus_lhs, collision_traffic, collision_mask
.import SmokeSetup, load_smoke_data
.import AnimInitEndSeq, end_seq
.import BonusDoText, bonus_control, bonus_state
.import spray_counter, sprite_collision_counter
.import gear, game_state
; ohud / osoundint / outils / math
.import HudBlitSpeed, HudBlitText1, HudBlitTextNew, HudDoMiniMap, hud_col
.import SndSetEngineData, SndReset
.import Random, SMul16
.importzp mres

.export IeInit, IeInitCrashBonus, IeSetGranularPosition, IeUpdateEngine, IeUpdateRoad
.export IeInitRoadSegMaster, IeUpdateShadowOffset, IeSetFinePosition, IeInitBonus
.export car_increment, car_x_old, car_x_pos, checkpoint_marker, end_stage_props
.export ingame_counter, ingame_engine, rd_split_state, road_curve, road_curve_next
.export road_remove_split, road_type, road_type_next, route_selected, change_width

; rd_split_state values
SPLIT_NONE    = 0
SPLIT_INIT    = 1
SPLIT_CHOICE1 = 2
SPLIT_CHOICE2 = 3
; ORoad::road_ctrl values
RCTL_BOTH_P0     = 3
RCTL_BOTH_P0_INV = 5
RCTL_R0_SPLIT    = 7
RCTL_R1_SPLIT    = 8
IE_ROAD_END    = $079C          ; globals.hpp ROAD_END
RD_WIDTH_MERGE = $D4
BONUS_SEQ0     = $0C            ; OBonus::BONUS_SEQ0
BONUS_END      = $1C            ; OBonus::BONUS_END

; A = the int8 in the low byte of A, sign-extended
.macro SEXT8
    and #$00FF
    eor #$0080
    sec
    sbc #$0080
.endmacro

.segment "BSS"
ingame_engine:      .res 2      ; bool
ingame_counter:     .res 2      ; int16
rd_split_state:     .res 2      ; uint16
road_type:          .res 2      ; int16
road_type_next:     .res 2      ; int16
end_stage_props:    .res 2      ; uint8
car_increment:      .res 4      ; uint32
car_x_pos:          .res 2      ; int16
car_x_old:          .res 2      ; int16
checkpoint_marker:  .res 2      ; int8
road_curve:         .res 2      ; int16
road_curve_next:    .res 2      ; int16
road_remove_split:  .res 2      ; int8
route_selected:     .res 2      ; int8
change_width:       .res 2      ; int16
; private
road_width_next:    .res 2      ; int16
road_width_adj:     .res 2      ; int16
granular_rem:       .res 2      ; int16
pos_fine_old:       .res 2      ; uint16
road_width_orig:    .res 2      ; int16
road_width_merge:   .res 2      ; int16
route_updated:      .res 2      ; int8
; scratch
ie_t:               .res 2
ie_w:               .res 2
ie_c:               .res 2
ie_seg:             .res 2
ie_gp:              .res 2      ; set_granular_position result

.segment "SA1CODE"
.a16
.i16

;----------------------------------------------------------------------------
; init (oinitengine.cpp 51): level = 0 (classic)
;----------------------------------------------------------------------------
IeInit:
    stz game_completed
    stz ingame_engine
    stz ingame_counter
    stz cur_stage
    stz stage_lookup_off        ; level ? level : 0
    stz rd_split_state
    stz road_type
    stz road_type_next
    stz end_stage_props
    stz car_increment
    stz car_increment+2
    stz car_x_pos
    stz car_x_old
    stz checkpoint_marker
    stz road_curve
    stz road_curve_next
    stz road_remove_split
    stz route_selected
    stz road_width_next
    stz road_width_adj
    stz change_width
    stz granular_rem
    stz pos_fine_old
    stz road_width_orig
    stz road_width_merge
    stz route_updated
    jsr IeInitRoadSegMaster
    ; if (level) trackloader.init_path(): time trial only (and a no-op on
    ; the SNES: the road engine loads the paths itself)
    jsr OPalSetupStage          ; setup_sky_palette .. setup_road_colour
    ; otiles.setup_palette_hud(): no-op on the SNES
    jsr CopyPaletteData
    ; otiles.setup_palette_tilemap(): no-op on the SNES
    jsr SetupStage1
    jsr ResetTilesPal
    jsr CrashClearState
    ; if (level) { init_tilemap_palette, road_ctrl, road_width }: time trial
    jmp SndReset

;----------------------------------------------------------------------------
; setup_stage1 (oinitengine.cpp 112)
;----------------------------------------------------------------------------
SetupStage1:
    lda #$01C2                  ; road_width = 0x1C2 << 16
    sta road_width+2
    stz road_width
    stz score
    stz score+2
    jsr StatsClearStageTimes
    jsr FerResetCar
    ; outputs->set_digital(D_EXT_MUTE / D_SOUND): omitted
    ldx #S_ENGINE_VOL
    lda #$3F
    jsr SndSetEngineData
    stz extend_play_timer
    stz checkpoint_marker
    jsr TrafficSetMax
    jsr StatsClearRouteInfo
    lda #1
    jmp SmokeSetup

;----------------------------------------------------------------------------
; init_road_seg_master (oinitengine.cpp 135)
;----------------------------------------------------------------------------
IeInitRoadSegMaster:
    lda stage_lookup_off
    jmp TrkInitTrack

;----------------------------------------------------------------------------
; update_road (oinitengine.cpp 153)
;----------------------------------------------------------------------------
IeUpdateRoad:
    jsr CheckRoadSplit
    ; road width / height section: d0 (uint16) <= road_pos >> 16
    lda #0
    jsr TrkReadWidthHeight
    sta ie_t
    lda road_pos+2
    cmp ie_t
    bcc @setw
    lda #2
    jsr TrkReadWidthHeight
    cmp #0
    bne @width
    ; skip_next_width: new height section
    lda height_lookup
    bne @next
    lda #4
    jsr TrkReadWidthHeight
    sta height_lookup
    bra @next
@width:
    lda #4
    jsr TrkReadWidthHeight
    sta ie_w                    ; width (int16)
    lda #6
    jsr TrkReadWidthHeight
    sta ie_c                    ; change (int16)
    lda ie_w
    cmp road_width+2
    beq @next                   ; width == (int16)(road_width >> 16)
    lda road_width+2            ; width <= hi (signed): change = -change
    sec
    sbc ie_w
    bvc :+
    eor #$8000
:   bmi :+
    lda ie_c
    eor #$FFFF
    inc a
    sta ie_c
:   lda ie_w
    sta road_width_next
    lda ie_c
    sta road_width_adj
    lda #$FFFF
    sta change_width
@next:
    lda trk_wh_off
    clc
    adc #8
    sta trk_wh_off
@setw:
    ; set_road_width: width changing and car moving
    lda change_width
    bne :+
    jmp @curve
:   lda car_increment+2
    bne :+
    jmp @curve
    ; d0 = (int32)(((car_increment >> 16) * road_width_adj) << 4) (uint32 maths)
:   ldx road_width_adj
    jsr SMul16
    lda car_increment+2         ; unsigned multiplicand: + adj << 16
    bpl :+
    lda mres+2
    clc
    adc road_width_adj
    sta mres+2
:   ldx #4
:   asl mres
    rol mres+2
    dex
    bne :-
    lda road_width
    clc
    adc mres
    sta road_width
    lda road_width+2
    adc mres+2
    sta road_width+2
    lda mres+2                  ; d0 > 0 ?
    bmi @dneg
    ora mres
    beq @dneg
    lda road_width_next         ; road_width_next < hi (signed)
    sec
    sbc road_width+2
    bvc :+
    eor #$8000
:   bpl @curve
    bra @wdone
@dneg:
    lda road_width_next         ; road_width_next >= hi (signed)
    sec
    sbc road_width+2
    bvc :+
    eor #$8000
:   bmi @curve
@wdone:
    stz change_width
    lda road_width_next         ; road_width = road_width_next << 16
    sta road_width+2
    stz road_width
@curve:
    ; set_road_type: curve section
    lda #0
    jsr TrkReadCurve
    cmp #$FFFF
    beq @done                   ; segment_pos == -1
    sta ie_seg
    sec
    sbc #$3C                    ; d1 = segment_pos - 0x3C (int16)
    sta ie_t
    lda road_pos+2              ; d1 <= (int16)(road_pos >> 16)
    sec
    sbc ie_t
    bvc :+
    eor #$8000
:   bmi :+
    lda #2
    jsr TrkReadCurve
    sta road_curve_next
    lda #4
    jsr TrkReadCurve
    sta road_type_next
:   lda road_pos+2              ; segment_pos <= (int16)(road_pos >> 16)
    sec
    sbc ie_seg
    bvc :+
    eor #$8000
:   bmi @done
    lda #2
    jsr TrkReadCurve
    sta road_curve
    lda #4
    jsr TrkReadCurve
    sta road_type
    lda trk_curve_off
    clc
    adc #6
    sta trk_curve_off
    stz road_type_next
    stz road_curve_next
@done:
    rts

;----------------------------------------------------------------------------
; update_engine (oinitengine.cpp 251)
;----------------------------------------------------------------------------
IeUpdateEngine:
    jsr IeUpdateShadowOffset
    jsr FerMove
    lda car_ctrl_active
    and #$00FF
    beq :+
    jsr FerSetCurveAdjust
    jsr FerSetX
    jsr FerDoSkid
    jsr FerCheckWheels
    jsr FerSetBounds
:   jsr FerDoSoundScoreSlip
    jsr IeSetGranularPosition
    jsr IeSetFinePosition
    ; speed and HUD (GS_START1 .. GS_BONUS)
    lda game_state
    and #$00FF
    cmp #GS_START1
    bcc @nohud
    cmp #GS_BONUS+1
    bcs @nohud
    lda #$0CB6                  ; 0x110CB6
    ldx car_increment+2
    jsr HudBlitSpeed
    lda #HUD_KPH1
    jsr HudBlitText1
    lda #HUD_KPH2
    jsr HudBlitText1
    ; high / low gear (GEAR_BUTTON, no smartypi)
    lda gear
    and #$00FF
    beq @low
    sep #$20
    lda #HUD_GREEN
    sta hud_col
    rep #$20
    ldy #.loword(StrHigh)
    bra @gear
@low:
    sep #$20
    lda #HUD_GREY
    sta hud_col
    rep #$20
    ldy #.loword(StrLow)
@gear:
    lda #9
    ldx #26
    jsr HudBlitTextNew
    ; (layout_debug: draw_debug_info omitted)
@nohud:
    lda spray_counter           ; uint16 > 0
    beq :+
    dec spray_counter
:   lda sprite_collision_counter ; int16 > 0
    beq :+
    bmi :+
    dec sprite_collision_counter
:   jmp SetupSkyCycle

;----------------------------------------------------------------------------
; update_shadow_offset (oinitengine.cpp 316)
;----------------------------------------------------------------------------
IeUpdateShadowOffset:
    lda tilemap_h_target
    and #$03FF
    cmp #$0200
    bcc :+
    eor #$FFFF                  ; -shadow_off + 0x3FF
    clc
    adc #$0400
:   lsr a
    lsr a
    sta ie_t
    lda tilemap_h_target
    and #$0400                  ; BIT_A: reverse direction
    beq :+
    lda ie_t
    eor #$FFFF
    inc a
    sta ie_t
:   lda ie_t
    sta shadow_offset
    rts

;----------------------------------------------------------------------------
; check_road_split (oinitengine.cpp 333)
;----------------------------------------------------------------------------
CheckRoadSplit:
    jsr StatsInitNextLevel
    lda rd_split_state
    cmp #$19
    bcs @r
    asl a
    tax
    jmp (SplitTab,x)
@r: rts

SplitTab:
    .word Split0, InitSplit1, Split2, InitSplit2, InitSplit3, Split5
    .word InitSplit5, InitSplit6, Split8, Split9, InitSplit9, InitSplit10
    .word InitSplit10, InitSplit10, InitSplit10, InitSplit10, Split10
    .word Bonus1, Bonus2, Bonus3, Bonus4, Bonus5, Bonus6, Bonus6, Bonus6

; state 0: road_pos >> 16 > ROAD_END -> check_stage
Split0:
    lda road_pos+2
    cmp #IE_ROAD_END+1
    bcs :+
    rts
:   jmp CheckStage
; state 2
Split2:
    lda road_pos+2
    cmp #$3F
    bcc :+
    jmp InitSplit2
:   rts
; state 5: falls into state 6 when the curve has ended
Split5:
    lda road_curve
    beq :+
    rts
:   lda #6
    sta rd_split_state
    jmp InitSplit5
; state 8
Split8:
    sep #$20
    lda #$FF                    ; traffic_split = -1
    sta traffic_split
    rep #$20
    lda #9
    sta rd_split_state
    rts
; state 9 (falls into state A)
Split9:
    sep #$20
    stz traffic_split
    rep #$20
    jmp InitSplit9
; state $10
Split10:
    lda stage_lookup_off
    sec
    sbc #$20
    jmp IeInitBonus

;----------------------------------------------------------------------------
; check_stage (oinitengine.cpp 453): classic mode part
;----------------------------------------------------------------------------
CheckStage:
    lda cur_stage               ; stages 0-3 (int8 <= 3): road split
    SEXT8
    sec
    sbc #4
    bpl :+
    lda #SPLIT_INIT
    sta rd_split_state
    jmp InitSplit1
:   lda game_state              ; stage 5: bonus
    and #$00FF
    cmp #GS_INGAME
    bne :+
    lda stage_lookup_off
    sec
    sbc #$20
    jmp IeInitBonus
:   jmp ReloadStage1            ; stage 5 attract mode: back to stage 1

;----------------------------------------------------------------------------
; reload_stage1 (oinitengine.cpp 565)
;----------------------------------------------------------------------------
ReloadStage1:
    stz road_pos
    stz road_pos+2
    stz tilemap_h_target
    lda #$FFFF
    sta cur_stage               ; -1
    lda #$FFF8
    sta stage_lookup_off        ; -8
    jsr StatsClearRouteInfo
    lda end_stage_props
    ora #$000E                  ; BIT_1 | BIT_2 | BIT_3
    sta end_stage_props
    lda #1
    jsr SmokeSetup
    jmp InitSplitNextLevel

;----------------------------------------------------------------------------
; init_split1 (oinitengine.cpp 586)
;----------------------------------------------------------------------------
InitSplit1:
    lda #SPLIT_CHOICE1
    sta rd_split_state
    lda #$FFFF
    sta road_load_split         ; -1
    lda #RCTL_BOTH_P0_INV
    sta road_ctrl
    lda road_width+2
    sta road_width_orig
    stz road_pos
    stz road_pos+2
    stz tilemap_h_target
    jmp TrkInitTrackSplit

; SplitPos: A = base -> A = pos = (((road_pos >> 16) - base) << 3)
; + road_width_orig (int16), also stored in the high word of road_width
SplitPos:
    sta ie_t
    lda road_pos+2
    sec
    sbc ie_t
    asl a
    asl a
    asl a
    clc
    adc road_width_orig
    sta road_width+2
    rts

;----------------------------------------------------------------------------
; init_split2 (oinitengine.cpp 601)
;----------------------------------------------------------------------------
InitSplit2:
    lda #SPLIT_CHOICE2
    sta rd_split_state
    lda #$3F
    jsr SplitPos
    sec                         ; pos > 0xFF (signed)
    sbc #$0100
    bvc :+
    eor #$8000
:   bmi :+
    lda route_updated
    and #$FFFE                  ; route_updated &= ~BIT_0
    sta route_updated
    jmp InitSplit3
:   rts

;----------------------------------------------------------------------------
; init_split3 (oinitengine.cpp 618)
;----------------------------------------------------------------------------
InitSplit3:
    lda #4
    sta rd_split_state
    lda #$3F
    jsr SplitPos
    sta ie_t                    ; pos
    lda route_updated           ; route_updated & BIT_0 || pos <= 0x168
    and #1
    bne @split4
    lda ie_t
    sec
    sbc #$0169
    bvc :+
    eor #$8000
:   bmi @split4
    lda route_updated
    ora #1                      ; route info updated
    sta route_updated
    stz route_selected
    lda car_x_pos               ; car_x_pos > 0: go left
    beq @right
    bmi @right
    lda #$FFFF
    sta route_selected
    lda cur_stage               ; inc = (uint8)(1 << (3 - cur_stage))
    SEXT8
    eor #$FFFF
    sec
    adc #3
    and #$001F
    tax
    lda #1
    cpx #0
    beq :++
:   asl a
    dex
    bne :-
:   and #$00FF
    clc
    adc route_info
    sta route_info
    inc stage_lookup_off
@right:
    lda end_stage_props
    ora #1                      ; BIT_0: road splitting
    sta end_stage_props
    sep #$20
    lda load_smoke_data         ; load_smoke_data |= BIT_0
    ora #1
    sta load_smoke_data
    rep #$20
    inc routes                  ; routes[0]++
    lda routes
    asl a
    tax
    lda route_info
    sta routes,x                ; routes[routes[0]] = route_info
@split4:
    lda road_width+2            ; road_width >> 16 > 0x300 (signed)
    sec
    sbc #$0301
    bvc :+
    eor #$8000
:   bmi :+
    jmp InitSplit4
:   rts

;----------------------------------------------------------------------------
; init_split4 (oinitengine.cpp 667)
;----------------------------------------------------------------------------
InitSplit4:
    lda #5
    sta rd_split_state
    lda route_selected
    and #$00FF
    beq :+
    lda #RCTL_R0_SPLIT
    bra :++
:   lda #RCTL_R1_SPLIT
:   sta road_ctrl
    lda road_remove_split
    ora #1
    sta road_remove_split
    lda road_curve
    bne :+
    jmp InitSplit5
:   rts

;----------------------------------------------------------------------------
; init_split5 (oinitengine.cpp 688)
;----------------------------------------------------------------------------
InitSplit5:
    lda #6
    sta rd_split_state
    lda road_curve
    beq :+
    jmp InitSplit6
:   rts

;----------------------------------------------------------------------------
; init_split6 (oinitengine.cpp 698)
;----------------------------------------------------------------------------
InitSplit6:
    lda #7
    sta rd_split_state
    lda road_curve
    bne :+
    jmp InitSplit7
:   rts

;----------------------------------------------------------------------------
; init_split7 (oinitengine.cpp 709)
;----------------------------------------------------------------------------
InitSplit7:
    lda #8
    sta rd_split_state
    lda #RCTL_BOTH_P0
    sta road_ctrl
    lda route_selected          ; route_selected = ~route_selected
    SEXT8
    eor #$FFFF
    sta route_selected
    lda road_width+2            ; width2 = (int16)((road_width >> 16) << 1)
    asl a
    sta ie_t
    lda route_selected
    and #$00FF
    bne :+
    lda ie_t
    eor #$FFFF
    inc a
    sta ie_t
:   lda car_x_pos
    clc
    adc ie_t
    sta car_x_pos
    lda car_x_old
    clc
    adc ie_t
    sta car_x_old
    lda road_pos+2
    sta road_width_orig
    lda road_width+2            ; road_width >> 19 (arithmetic)
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    sta road_width_merge
    lda road_remove_split
    and #$FFFE
    sta road_remove_split
    rts

;----------------------------------------------------------------------------
; init_split9 (oinitengine.cpp 728)
;----------------------------------------------------------------------------
InitSplit9:
    lda #10
    sta rd_split_state
    lda road_pos+2              ; d0 = (uint16)((merge - (pos - orig)) << 3)
    sec
    sbc road_width_orig
    sta ie_t
    lda road_width_merge
    sec
    sbc ie_t
    asl a
    asl a
    asl a
    cmp #RD_WIDTH_MERGE+1       ; d0 <= RD_WIDTH_MERGE (unsigned)
    bcs :+
    lda #RD_WIDTH_MERGE
    sta road_width+2
    jmp InitSplit10
:   sta road_width+2
    rts

;----------------------------------------------------------------------------
; init_split10 (oinitengine.cpp 748)
;----------------------------------------------------------------------------
InitSplit10:
    lda #11
    sta rd_split_state
    lda road_pos+2
    cmp #$0181
    bcs :+
    rts
:   stz rd_split_state
    jmp InitSplitNextLevel

;----------------------------------------------------------------------------
; init_split_next_level (oinitengine.cpp 762)
;----------------------------------------------------------------------------
InitSplitNextLevel:
    stz road_pos
    stz road_pos+2
    stz tilemap_h_target
    lda cur_stage               ; cur_stage++ (int8)
    SEXT8
    inc a
    SEXT8
    sta cur_stage
    lda stage_lookup_off
    clc
    adc #8
    sta stage_lookup_off
    lda route_info
    clc
    adc #$10
    sta route_info
    jsr HudDoMiniMap
    jsr IeInitRoadSegMaster
    lda cur_stage
    and #$00FF
    beq :+
    jmp ClearPaletteData
:   rts

;----------------------------------------------------------------------------
; init_bonus (oinitengine.cpp 783): A = seq (int16)
;----------------------------------------------------------------------------
IeInitBonus:
    sta ie_t
    lda #RCTL_BOTH_P0_INV
    sta road_ctrl
    stz road_pos
    stz road_pos+2
    stz tilemap_h_target
    sep #$20
    lda ie_t                    ; end_seq = (uint8) seq
    sta end_seq
    rep #$20
    lda ie_t
    and #$00FF
    jsr TrkInitTrackBonus
    sep #$20
    lda #GS_INIT_BONUS
    sta game_state
    rep #$20
    lda #$11
    sta rd_split_state
    jmp Bonus1

;----------------------------------------------------------------------------
; bonus1 (oinitengine.cpp 795)
;----------------------------------------------------------------------------
Bonus1:
    lda road_pos+2
    cmp #$5B
    bcs :+
    rts
:   sep #$20
    lda #1                      ; force traffic spawn on the LHS
    sta bonus_lhs
    rep #$20
    lda #$12
    sta rd_split_state
    jmp Bonus2

;----------------------------------------------------------------------------
; bonus2 (oinitengine.cpp 805)
;----------------------------------------------------------------------------
Bonus2:
    lda road_pos+2
    cmp #$B6
    bcs :+
    rts
:   sep #$20
    stz bonus_lhs
    rep #$20
    lda road_width+2
    sta road_width_orig
    lda #$13
    sta rd_split_state
    jmp Bonus3

;----------------------------------------------------------------------------
; bonus3 (oinitengine.cpp 817)
;----------------------------------------------------------------------------
Bonus3:
    lda #$B6
    jsr SplitPos
    sec                         ; pos > 0xFF (signed)
    sbc #$0100
    bvc :+
    eor #$8000
:   bmi @r
    stz route_selected
    lda car_x_pos               ; car_x_pos > 0: route_selected = ~0
    beq :+
    bmi :+
    lda #$FFFF
    sta route_selected
:   lda #$14
    sta rd_split_state
    jmp Bonus4
@r: rts

;----------------------------------------------------------------------------
; bonus4 (oinitengine.cpp 832)
;----------------------------------------------------------------------------
Bonus4:
    lda #$B6
    jsr SplitPos
    sec                         ; pos > 0x300 (signed)
    sbc #$0301
    bvc :+
    eor #$8000
:   bmi @r
    lda route_selected
    and #$00FF
    beq :+
    lda #RCTL_R0_SPLIT
    bra :++
:   lda #RCTL_R1_SPLIT
:   sta road_ctrl
    lda road_remove_split
    ora #1
    sta road_remove_split
    lda #$15
    sta rd_split_state
    jmp Bonus5
@r: rts

;----------------------------------------------------------------------------
; bonus5 (oinitengine.cpp 853)
;----------------------------------------------------------------------------
Bonus5:
    lda road_curve
    beq :+
    rts
:   lda #$16
    sta rd_split_state
    jmp Bonus6

;----------------------------------------------------------------------------
; bonus6 (oinitengine.cpp 863): bonus_control >= BONUS_END (int8)
;----------------------------------------------------------------------------
Bonus6:
    lda bonus_control
    SEXT8
    sec
    sbc #BONUS_END
    bmi :+
    stz rd_split_state
:   rts

;----------------------------------------------------------------------------
; set_granular_position (oinitengine.cpp 881)
;----------------------------------------------------------------------------
IeSetGranularPosition:
    lda car_increment+2
    and #$003F                  ; rem = car_inc16 % 0x40
    clc
    adc granular_rem
    sta granular_rem
    lda car_increment+2         ; result = car_inc16 / 0x40
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    sta ie_gp
    lda granular_rem            ; granular_rem >= 0x40 (signed)
    sec
    sbc #$40
    bvc :+
    eor #$8000
:   bmi :+
    lda granular_rem
    sec
    sbc #$40
    sta granular_rem
    inc ie_gp
:   lda pos_fine
    clc
    adc ie_gp
    sta pos_fine
    rts

;----------------------------------------------------------------------------
; set_fine_position (oinitengine.cpp 898)
;----------------------------------------------------------------------------
IeSetFinePosition:
    lda pos_fine
    sec
    sbc pos_fine_old
    cmp #$0010
    bcc :+
    lda #$000F
:   xba                         ; << 0xB
    asl a
    asl a
    asl a
    sta sprite_scroll_speed
    lda pos_fine
    sta pos_fine_old
    rts

;----------------------------------------------------------------------------
; init_crash_bonus (oinitengine.cpp 913)
;----------------------------------------------------------------------------
IeInitCrashBonus:
    lda game_state
    and #$00FF
    cmp #GS_MUSIC
    bne :+
    rts
:   lda skid_counter            ; skid_counter > 6 (int16)
    sec
    sbc #7
    bvc :+
    eor #$8000
:   bpl @skid
    lda skid_counter            ; skid_counter < -6
    clc
    adc #6
    bvc :+
    eor #$8000
:   bmi @skid
    lda spin_control2           ; spin_control2 == 1 ($9894)
    and #$00FF
    cmp #1
    bne @spin1
    sep #$20
    lda #2
    sta spin_control2
    rep #$20
    lda coll_count1
    cmp coll_count2
    bne :+
    jsr CrashEnable
:   lda #0
    jmp TestBonusMode
@spin1:
    lda spin_control1           ; spin_control1 == 1 ($98C0)
    and #$00FF
    cmp #1
    bne @c9924
    sep #$20
    lda #2
    sta spin_control1
    rep #$20
    jsr CrashEnable
    lda #0
    jmp TestBonusMode
@skid:
    lda collision_traffic       ; do_skid
    cmp #1
    bne @c9924
    lda #2
    sta collision_traffic
    jsr Random
    and collision_mask
    and #$00FF                  ; uint8 rnd
    cmp collision_mask
    bne @c9924
    lda coll_count1             ; try to launch the crash code and spin
    cmp coll_count2
    bne @true
    lda spin_control1
    and #$00FF
    bne @false
    sep #$20
    lda #1
    sta spin_control1
    rep #$20
    lda skid_counter
    sta skid_counter_bak
@true:
    lda #1
    jmp TestBonusMode
@false:
    lda #0
    jmp TestBonusMode
@c9924:
    lda coll_count1
    cmp coll_count2
    beq @true
    jsr CrashEnable
    lda #0
    jmp TestBonusMode

;----------------------------------------------------------------------------
; test_bonus_mode (oinitengine.cpp 980): A = do_bonus_check
;----------------------------------------------------------------------------
TestBonusMode:
    cmp #0
    beq @fin
    lda bonus_control
    and #$00FF
    beq @fin
    lda bonus_state             ; bonus_state < 3 (int8)
    and #$00FF
    cmp #3
    bcc :+
    cmp #$0080
    bcc :++
:   jsr BonusDoText
:   lda bonus_control
    and #$00FF
    cmp #BONUS_SEQ0
    bne @fin
    jsr AnimInitEndSeq
@fin:
    lda skid_counter            ; finalise_skid
    bne :+
    stz collision_traffic
:   rts

.segment "RODATA"
StrHigh: .byte "H", 0
StrLow:  .byte "L", 0
.endif
