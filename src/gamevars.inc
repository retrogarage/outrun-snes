; Game-wide constants and variable declarations (SA-1 side)
.ifndef GAMEVARS_INC
GAMEVARS_INC = 1

; ---- game states (same numbering as the arcade) ----
GS_INIT          = 0
GS_ATTRACT       = 1
GS_INIT_BEST1    = 2
GS_BEST1         = 3
GS_INIT_LOGO     = 4
GS_LOGO          = 5
GS_INIT_MUSIC    = 6
GS_MUSIC         = 7
GS_INIT_GAME     = 8
GS_START1        = 9
GS_START2        = 10
GS_START3        = 11
GS_INGAME        = 12
GS_INIT_BONUS    = 13
GS_BONUS         = 14
GS_INIT_GAMEOVER = 15
GS_GAMEOVER      = 16
GS_INIT_MAP      = 17
GS_MAP           = 18
GS_INIT_BEST2    = 19
GS_BEST2         = 20
GS_REINIT        = 21

; ---- road types / controls ----
ROAD_NOCHANGE = 0
ROAD_STRAIGHT = 1
ROAD_RIGHT    = 2
ROAD_LEFT     = 3
RC_OFF = 0
RC_R0 = 1
RC_R1 = 2
RC_BOTH_P0 = 3
RC_BOTH_P1 = 4
RC_BOTH_P0_INV = 5
RC_BOTH_P1_INV = 6
RC_R0_SPLIT = 7
RC_R1_SPLIT = 8

ROAD_END      = $079C
RD_WIDTH_MERGE = $D4
CAR_BASE_INC  = $12F
MAX_SPEED_HI  = $0126       ; MAX_SPEED = $1260000

; ---- wheels ----
WHEELS_ON        = 0
WHEELS_LEFT_OFF  = 1
WHEELS_RIGHT_OFF = 2
WHEELS_OFF       = 3

; ---- joypad bits (SH_JOY = JOY1L/H) ----
PAD_B     = $8000
PAD_Y     = $4000
PAD_SEL   = $2000
PAD_START = $1000
PAD_UP    = $0800
PAD_DOWN  = $0400
PAD_LEFT  = $0200
PAD_RIGHT = $0100
PAD_A     = $0080
PAD_X     = $0040
PAD_L     = $0020
PAD_R     = $0010

; ---- engine.s ----
.global game_state, cur_stage, stage_lookup_off, rd_split_state
.global road_type, road_type_next, road_curve, road_curve_next
.global car_increment, car_x_pos, car_x_old, ingame_engine, ingame_counter
.global route_selected, route_info, checkpoint_marker, road_remove_split, routes
.global end_stage_props, sprite_scroll_speed, road_pos_change
.global spray_counter, sprite_collision_counter, collision_sprite
.global EngineInit, EngineUpdateRoad, EngineSetPositions, EngineSection, EngineGranular

; ---- inputs.s ----
.global steering_adjust, acc_adjust, brake_adjust, gear, crash_input
.global InputsInit, InputsTick

; ---- ferrari.s ----
.global FerInit, FerReset, FerMove, FerControl, FerSprites
.global car_ctrl_active, wheel_state, revs, fer_x, fer_y, fer_state

; ---- stats ----
.global time_counter, frame_counter

; ---- crash (stubs until crash.s exists) ----
.global crash_counter, spin_control1, skid_counter, coll_count1, coll_count2

.endif
