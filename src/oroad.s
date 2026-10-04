; ORoad: exact port of the arcade road CPU program as in CannonBall DX
; (engine/oroad_base.cpp, "complete port of the 68000 SUB CPU Program ROM").
; See docs/renderer.md.
;
; Per road tick (ORoadTick = do_road):
;   rotate_values   road_p0..p3 rotate over the four road_y buffers
;   setup_road_x    road_x[] curve (only when road_pos>>16 changes) and the
;                   road0_h[]/road1_h[] h-scroll per distance index
;   setup_road_y    height state machine
;   set_road_y      road_y[p1+0..1FF]: height per distance index
;   set_horizon_y   incline smoothing, horizon_y2
;   do_road_data    road_y[p1+2E0..3FF]: per scanline road data (solid colour
;                   or rom line/index), crest list at road_y[p1+280..]
; The road hardware shows road_p2's scanline data with this tick's h tables
; and colour table (pos_fine phase): RoadHdma builds the SNES HDMA from them.
;
; Word arrays live in BW-RAM bank $41; road_p0..p3 are byte offsets.
; Integer semantics follow the C++ (arithmetic shifts, int16 truncation).
;
; Speed: the hot loops keep their state in registers / direct page and touch
; BW-RAM (half speed for the SA-1) once per array entry.  The SA-1
; arithmetic unit is used beyond plain multiplies:
;   cumulative sum (MCNT = 2): set_y_2044 / set_y_horizon keep
;     total_height << 4 in MR (one MB write per road_y entry, see SyWrite),
;     set_horizon_y's (a+b+c)*0x5555 products and write loops, create_curve's
;     products;
;   divide (MCNT = 1): set_horizon_y / setup_x_data quotients, DivQ, UDiv16.
; Reuse (real-hardware timing: road_y is in BW-RAM, twice as slow as I-RAM):
; RdMemo skips the road_y writes of set_road_y / set_horizon_y /
; do_road_data when their inputs equal those of the last 5 ticks (road_p1
; then already holds the same data), and DtCache skips do_road_data's top
; fill when road_p1 holds the same one.  Both rely on the road_y buffers
; being written by these routines only (the renderer and the game only read
; them) and are reset by ORoadInit.
; Every routine leaves the unit in multiply mode (MCNT = 0).  MR is read at
; least 6 SA-1 cycles after the MBH write that starts an operation, and a
; new operation (or an MA write) is not started within 6 cycles of the
; previous one.  All fast paths are exact; operands outside their range
; (int16 wraps, divisors, ...) take the original software paths.
.p816
.smart
.include "sa1.inc"
.include "shared.inc"
.include "globals.inc"
.include "gamevars.inc"
.include "roaddata.inc"
.include "road.inc"
.include "road2.inc"

.importzp mres, dvd, dvs, drem
.import SMul16, UMul16, UDiv32_16

RDB    = $41                ; bank of the road arrays
RD_Y   = $D000              ; road_y[0x1000]  (4 buffers of 0x400 words)
RD_X   = $F000              ; road_x[0x200]
RD_H0  = $F400              ; road0_h[0x200] (ROADTEST only: see HEval)
RD_H1  = $F800              ; road1_h[0x200]
RD_UNK = $FC00              ; road_unk[0x200]
.export RD_Y, RD_X, RD_H0, RD_H1, RD_UNK, RDB

PATH_ENT = 4                ; raw path entry: x, y (int16)
MARK     = $3210            ; road_x "ignore car position" marker

; do_road_data output format
SOLID_FILL  = $0800
TRANSPARENT = $083F

.segment "ZEROPAGE"
; (all scratch, shared by the routines of one road tick through the aliases
; defined next to each routine, except or_hptr = height_addr)
or_t0:   .res 4
or_t1:   .res 4
or_t2:   .res 4
or_i:    .res 2
or_ptr:  .res 3             ; path table pointer (24-bit)
or_hptr: .res 3             ; height data pointer (height_addr)
or_a1:   .res 3             ; a1_lookup
or_inc:  .res 4
or_co:   .res 4
total_height:     .res 4
change_per_entry: .res 4
y_addr:           .res 2
xs_scan:          .res 2
xs_x:             .res 2
xs_inc:           .res 2
xs_cnt:           .res 2
or_sc:            .res 2

.segment "IRAMBSS"          ; (hot: SA-1 I-RAM is twice as fast as BW-RAM)
; ---- interface (same names as the previous road module) ----
.ifdef NEWGAME
; ORoad members that the old game kept in engine.s
stage_lookup_off:   .res 2
road_pos_change:    .res 4
.export stage_lookup_off, road_pos_change
.endif
road_pos:           .res 4
road_pos_old:       .res 2
pos_fine:           .res 2
pos_fine_old:       .res 2
pos_fine_diff:      .res 2
road_ctrl:          .res 2
road_load_split:    .res 2
road_load_end:      .res 2
road_width:         .res 4
road_width_bak:     .res 2
car_x_bak:          .res 2
camera_x_off:       .res 2
horizon_base:       .res 2
horizon_offset:     .res 2
horizon_set:        .res 2
horizon_y2:         .res 2
horizon_y_bak:      .res 2
tilemap_h_target:   .res 2
height_lookup:      .res 2
road_p0:            .res 2
road_p1:            .res 2
road_p2:            .res 2
road_p3:            .res 2
; ---- private ----
stage_loaded:       .res 2
path_base:          .res 3      ; current path table (24-bit)
height_lookup_wrk:  .res 2
height_ctrl:        .res 2
height_ctrl2:       .res 2
height_start:       .res 2
height_end:         .res 2
height_index:       .res 2
height_inc:         .res 2
height_step:        .res 2
height_delay:       .res 2
step_adjust:        .res 2
do_height_inc:      .res 2
elevation:          .res 2
up_mult:            .res 2
down_mult:          .res 2
horizon_mod:        .res 4
height_final:       .res 4
section_lengths:    .res 14
length_offset:      .res 2
counter:            .res 2
d5_o:               .res 4
a3_o:               .res 2
yl_scan:            .res 2      ; set_y_2044 scanline
; setup_x_data
cx_total:           .res 4
cy_total:           .res 4
cxd:                .res 2
cyd:                .res 2
xs_n:               .res 2
; render interface
rd_colph:           .res 2      ; pos_fine & $1F used for this tick's colours
rd_hwctl:           .res 2      ; hardware road control 0-3
sdq_d:              .res 2
rd_co:              .res 4      ; car_offset per road (lazy h)
rd_inv:             .res 4
rd_set:             .res 4
he_r:               .res 2
he_n:               .res 2
sdq_s:              .res 2
; road_y block memo (see RdMemo)
rm_key:             .res 20     ; inputs of set_road_y this tick
rm_cnt:             .res 2      ; consecutive ticks with these inputs
rx_valid:           .res 2     ; cached curve inputs match the current RD_X
rd_dry:             .res 2      ; nonzero: road_p1 already holds this tick's data

.ifdef NEWGAME
.import RoadKeySections
rx_keyptr:          .res 3
rx_keycount:        .res 2
rx_lastkey:         .res 2
.endif

.export road_pos, road_pos_old, pos_fine, road_ctrl, road_width, road_width_bak
.export car_x_bak, camera_x_off, horizon_base, horizon_offset, horizon_set
.export tilemap_h_target, height_lookup, horizon_y2, horizon_y_bak
.export road_load_split, road_load_end, road_p0, road_p1, road_p2, road_p3
.export rd_colph, rd_hwctl, pos_fine_diff
.export ORoadInit, ORoadTick, HEval, rd_co, rd_inv, MARK

.segment "BWBSS": far
; do_road_data top fill per road_y buffer: scanline, fill key ($FFFF: none)
rx_path:            .res 264    ; all 66 path vectors read by SetupXData
dt_key:             .res 16

.segment "SA1CODE"
.a16
.i16

; word access to the road arrays: set DB to the array bank for a block
.macro RDB_ON
    phb
    pea RDB * 257
    plb
    plb
.endmacro
.macro RDB_OFF
    plb
.endmacro

;============================================================================
; ORoadInit (ORoad::init without the hardware writes)
;============================================================================
ORoadInit:
    .ifdef NEWGAME
    lda #$FFFF
    sta rx_lastkey
    .endif
    stz rx_valid
    RDB_ON
    ldx #0
:   stz RD_Y,x
    inx
    inx
    cpx #$2000
    bne :-
    ldx #0
:   stz RD_X,x
    stz RD_H0,x
    stz RD_H1,x
    stz RD_UNK,x
    inx
    inx
    cpx #$0400
    bne :-
    RDB_OFF
    ldx #0
:   stz road_pos,x
    inx
    inx
    cpx #rd_hwctl+2-road_pos
    bcc :-
    lda #$FFFF
    sta stage_loaded
    stz rm_cnt              ; (road_y blocks cleared: no memo)
    stz rd_dry
    lda #$FFFF
    ldx #14
:   sta f:dt_key,x          ; (no top fill in any buffer)
    dex
    dex
    bpl :-
    stz horizon_set
    stz road_p0
    lda #$0800
    sta road_p1
    lda #$1000
    sta road_p2
    lda #$1800
    sta road_p3
    ; init_stage1
    lda #0
    jsr PathForOffset
    stz road_pos
    stz road_pos+2
    lda #RC_BOTH_P0
    sta road_ctrl
    rts

;----------------------------------------------------------------------------
; PathForOffset: A = stage lookup offset -> path_base (trackloader.init_path)
; level = [0,1,3,6,10][off >> 3] + (off & 7) = section index
;----------------------------------------------------------------------------
PathForOffset:
    pha
    lsr a
    lsr a
    lsr a
    and #$001F
    asl a
    tax
    pla
    and #7
    clc
    adc f:OrStageBase,x
    ; fall into PathForSection
PathForSection:
    sta or_t0
    asl a
    clc
    adc or_t0               ; *3 (24-bit pointers)
    tax
    lda f:RawSectionPath,x
    sta path_base
    lda f:RawSectionPath+1,x
    sta path_base+1
    .ifdef NEWGAME
    lda or_t0
    asl a
    asl a
    clc
    adc or_t0
    tax
    lda f:RoadKeySections,x
    sta rx_keyptr
    lda f:RoadKeySections+1,x
    sta rx_keyptr+1
    lda f:RoadKeySections+3,x
    sta rx_keycount
    .endif
    rts

;============================================================================
; ORoadTick (ORoad::do_road)
;============================================================================
ORoadTick:
    jsr RotateValues
    jsr SetupRoadX
    jsr SetupRoadY
    jsr RdMemo
    jsr SetRoadY
    jsr SetHorizonY
    jsr DoRoadData
    ; blit_roads: the hardware road control (unchanged when the roads are off)
    lda road_ctrl
    beq @off
    asl a
    tax
    lda f:HwCtl-2,x
    sta rd_hwctl
@off:
    ; copy_bg_color: colour table phase
    lda pos_fine
    and #$001F
    sta rd_colph
    rts

;----------------------------------------------------------------------------
; RdMemo: set_road_y's result (road_y[p1 + 0..$1FF] after set_horizon_y,
; road_unk) is a function of the inputs below and rom data only, and
; do_road_data's (road_y[p1 + $280..$3FF]) of that block.  The four road_y
; buffers rotate every tick and only these three routines write them, so
; when the inputs were the same for the last 5 ticks, road_p1 still holds
; exactly what this tick would write (4 ticks ago, same inputs): rd_dry = 1
; and the three routines skip their road_y writes (set_road_y still runs
; for road_unk and the height state, with the height sum in software).
;----------------------------------------------------------------------------
.macro RMK v, o
    lda v
    cmp rm_key+o
    beq :+
    sta rm_key+o
    stz rm_cnt
:
.endmacro
RdMemo:
    ; A zero-elevation segment produces one constant slope regardless of
    ; its seven section lengths. Canonicalize those inputs instead of
    ; rebuilding identical road arrays as height_start/end advance.
    lda height_ctrl2
    bne @general
    lda height_index
    asl a
    clc
    adc or_hptr
    sta or_a1
    sep #$20
    .a8
    lda or_hptr+2
    adc #0
    sta or_a1+2
    rep #$20
    .a16
    ldy #10                 ; six deltas read by ReadNextHeight
@flat:
    lda [or_a1],y
    bne @general
    dey
    dey
    bpl @flat
    lda #$8000              ; distinct from every non-flat height_ctrl2
    cmp rm_key
    beq @horizon
    sta rm_key
    stz rm_cnt
    bra @horizon
@general:
    RMK height_ctrl2, 0
    RMK height_end, 2
    RMK height_start, 4
    RMK height_index, 6
    RMK or_hptr, 8
    RMK or_hptr+1, 10           ; (bank byte in the high half)
@horizon:
    RMK horizon_base, 12
    RMK horizon_offset, 14
    RMK horizon_mod, 16
    RMK horizon_mod+2, 18
    lda rm_cnt
    cmp #5
    bcs :+
    inc a
    sta rm_cnt
:   ldx #0
    cmp #5
    bcc :+
    inx
:   stx rd_dry
    rts

;----------------------------------------------------------------------------
; rotate_values + check_load_road
;----------------------------------------------------------------------------
RotateValues:
    lda road_p0
    pha
    lda road_p1
    sta road_p0
    lda road_p2
    sta road_p1
    lda road_p3
    sta road_p2
    pla
    sta road_p3
    ; road_pos_change (shared with the car code, int32) = (road_pos >> 16)
    ; - road_pos_old
    lda road_pos+2
    sec
    sbc road_pos_old
    sta road_pos_change
    lda #0
    sbc #0                  ; borrow -> $FFFF for a negative difference
    sta road_pos_change+2
    lda road_pos+2
    sta road_pos_old
    ; check_load_road
    lda cur_stage
    cmp stage_loaded
    beq @split
    sta stage_loaded
    lda stage_lookup_off
    jmp PathForOffset
@split:
    lda road_load_split
    beq @end
    lda #SECTION_SPLIT
    jsr PathForSection
    stz road_load_split
    rts
@end:
    lda road_load_end
    beq :+
    lda #SECTION_END0
    jsr PathForSection
    stz road_load_end
:   rts

;============================================================================
; setup_road_x: curve data when the road position moved on, then h-scroll
;============================================================================
SetupRoadX:
    lda road_pos_change
    beq @hs
    ; path table entry for road_pos >> 16
    lda road_pos+2
    ldx #PATH_ENT
    jsr SMul16              ; (positions < $8000)
    lda mres
    clc
    adc path_base
    sta or_ptr
    sep #$20
    .a8
    lda path_base+2
    adc #0
    sta or_ptr+2
    rep #$20
    .a16
    jsr SetTilemapX
    jsr RxMatch
    bcc @hs
    jsr SetupXData
@hs:
    jmp SetupHScroll

; Generated keys identify exact SetupXData write results, including marker
; prefixes and untouched words. Reusing an equal consecutive result needs
; one ROM lookup instead of comparing/copying all 66 path vectors. Keys may
; also match when different vectors project identically. Unknown positions
; retain the complete-input comparison and the original computation.
RxMatch:
    .ifdef NEWGAME
    lda road_pos+2
    cmp rx_keycount
    bcs @legacy
    asl a
    tay
    lda rx_keyptr
    sta or_a1
    lda rx_keyptr+1
    sta or_a1+1
    lda [or_a1],y
    cmp rx_lastkey
    bne @newkey
    ldx rx_valid
    beq @newkey
    clc
    rts
@newkey:
    sta rx_lastkey
    lda #1
    sta rx_valid
    sec
    rts
@legacy:
    ; A legacy input snapshot is valid only after another legacy call.
    lda rx_lastkey
    cmp #$FFFF
    beq :+
    lda #$FFFF
    sta rx_lastkey
    stz rx_valid
:
    .endif
    lda rx_valid
    beq @copy
    ldy #0
@compare:
    lda [or_ptr],y
    tyx
    cmp f:rx_path,x
    bne @copy
    iny
    iny
    cpy #264
    bcc @compare
    clc
    rts
@copy:
    ldy #0
@word:
    lda [or_ptr],y
    tyx
    sta f:rx_path,x
    iny
    iny
    cpy #264
    bcc @word
    lda #1
    sta rx_valid
    sec
    rts

; setup_x_data locals (direct page scratch free while it runs)
curve_inc_old = xs_x
curve_start   = y_addr
curve_end     = change_per_entry
curve_inc     = change_per_entry+2
xs_p          = or_a1

;----------------------------------------------------------------------------
; setup_x_data: 33 samples of the path ahead -> road_x[0x1BF] downwards
; (xs_scan = byte offset 2 * scanline)
;----------------------------------------------------------------------------
SetupXData:
    jsr Heading
    ; (default straight: road_x[0..0x7F] = marker, done at the end for the
    ; entries no sample writes, see XsMark)
    stz cx_total
    stz cx_total+2
    stz cy_total
    stz cy_total+2
    stz curve_start
    stz curve_end
    stz curve_inc
    stz curve_inc_old
    lda #$01BF*2
    sta z:xs_scan
    stz xs_n                ; sample 0..32
    stz xs_p                ; byte offset of the sample (2 entries apart)
@sample:
    ldy xs_p
    lda [or_ptr],y          ; sx = x[p] + x[p+1]
    iny
    iny
    iny
    iny
    clc
    adc [or_ptr],y
    tax
    clc
    adc cx_total
    sta cx_total
    lda cx_total+2
    adc #0
    cpx #$8000
    bcc :+
    dec a                   ; (sign extension of sx)
:   sta cx_total+2
    ldy xs_p
    iny
    iny
    lda [or_ptr],y          ; sy = y[p] + y[p+1]
    iny
    iny
    iny
    iny
    clc
    adc [or_ptr],y
    tax
    clc
    adc cy_total
    sta cy_total
    lda cy_total+2
    adc #0
    cpx #$8000
    bcc :+
    dec a
:   sta cy_total+2
    jsr CreateCurve
    ; steps = curve_end - curve_start
    lda curve_end
    sec
    sbc curve_start
    bpl :+
    jmp @done
:   bne :+
    jmp @next
:   sta z:xs_cnt            ; curve_steps (> 0)
    ; xinc = (curve_inc - curve_inc_old) / curve_steps  (int32, truncated;
    ; only its low 16 bits matter: x += xinc is modulo 2^16)
    lda curve_inc
    sec
    sbc curve_inc_old
    beq @xz
    bvs @xs                 ; difference outside int16
    ldx z:xs_cnt
    ldy #1
    sty MCNT                ; divide
    sta MAL
    stx MBL
    cmp #$8000              ; C = negative dividend
    nop
    lda MR                  ; floor
    bcc :+
    ldy MR+2
    beq :+
    inc a                   ; truncation toward 0
:   stz MCNT
    bra @xz
@xs:
    sta dvd                 ; overflowed int16: high word 0 for a negative
    ldx #0                  ; low word, $FFFF for a positive one
    cmp #$8000
    bcs :+
    dex
:   stx dvd+2
    lda z:xs_cnt
    jsr SDivQ
    lda dvd
@xz:
    sta z:xs_inc
    ; pos = curve_start .. curve_end: x += xinc ; road_x[scanline--] = x
    ; Fast path: x0 = curve_inc_old and x_n = x0 + n * xinc (n = steps + 1,
    ; exact 32-bit) both within +-0x3200, so no x_k is out of range (or
    ; wraps): only the scanline limit remains.
    lda z:xs_cnt
    inc a
    bmi @slowj               ; (n = $8000)
    sta z:xs_np
    sta MAL
    lda z:xs_inc
    sta MBL                 ; n * xinc
    lda curve_inc_old
    clc
    adc #$3200
    cmp #$6401
    bcs @slowj               ; x0 out of range
    clc
    adc MR                  ; x_n + 0x3200 (32-bit)
    tay
    lda MR+2
    adc #0
    bne @slowj
    cpy #$6401
    bcs @slowj
    bra @fast
@slowj:
    jmp @slow
@fast:
    ; m = min(n, scanline + 1) positions
    lda z:xs_scan
    lsr a
    inc a                   ; scanline + 1
    cmp z:xs_np
    bcc :+
    lda z:xs_np
:   ; m stores, 8 per round with DB = $41, the first round entered at
    ; unit j0 = 7 - ((m - 1) & 7) with X = scan + 2 * j0 (Duff)
    asl a
    eor #$FFFF
    sec
    adc z:xs_scan
    sta z:xs_np             ; X at the end: scan - 2 * m
    lda z:xs_scan
    sec
    sbc z:xs_np             ; 2 * m
    dec a
    dec a
    and #14
    eor #14
    tax                     ; 2 * j0
    sta z:xs_cnt            ; (2 * j0; xs_cnt is free here)
    asl a
    adc z:xs_cnt            ; 6 * j0 (units of 6 bytes; C = 0)
    adc #.loword(@u0 - 1)
    phb
    pha                     ; (rts target)
    txa
    clc
    adc z:xs_scan
    tax
    pea RDB * 257
    plb
    plb
    lda curve_inc_old
    rts
@u0:
    clc
    adc z:xs_inc
    sta RD_X,x
    clc
    adc z:xs_inc
    sta RD_X-2,x
    clc
    adc z:xs_inc
    sta RD_X-4,x
    clc
    adc z:xs_inc
    sta RD_X-6,x
    clc
    adc z:xs_inc
    sta RD_X-8,x
    clc
    adc z:xs_inc
    sta RD_X-10,x
    clc
    adc z:xs_inc
    sta RD_X-12,x
    clc
    adc z:xs_inc
    sta RD_X-14,x
    tay
    txa
    sec
    sbc #16
    tax
    tya
    cpx z:xs_np
    bne @u0
    plb
    txa
    bmi @abort              ; scanline limit reached
    stx z:xs_scan
    jmp @sdone
@slow:
    ldy z:xs_cnt
    iny
    ldx z:xs_scan
    lda curve_inc_old
    clc
@pos:
    adc z:xs_inc            ; (C = 0)
    bmi @xneg
    cmp #$3201
    bcs @abort
@put:
    sta f:RDB*$10000+RD_X,x
    dex
    dex
    bmi @abort
    dey
    bne @pos
    stx z:xs_scan
@sdone:
    lda curve_inc
    sta curve_inc_old
    lda curve_end
    sta curve_start
@next:
    lda xs_p
    clc
    adc #PATH_ENT*2
    sta xs_p
    inc xs_n
    lda xs_n
    cmp #33
    bcs @done
    jmp @sample
@xneg:
    cmp #$CE00              ; >= -0x3200 ?
    bcc @abort
    clc
    bra @put
@done:
    ldx z:xs_scan
@abort:
    ; X = byte offset of the highest entry no sample wrote (< 0: none):
    ; road_x[0 .. min(X / 2, 0x7F)] = marker
    txa
    bmi @mk9
    cmp #$0100
    bcc :+
    lda #$00FE
:   tax
    lda #MARK
    phb
    pea RDB * 257
    plb
    plb
@mk:
    sta RD_X,x
    dex
    dex
    bpl @mk
    plb
@mk9:
    rts

;----------------------------------------------------------------------------
; Heading: cxd/cyd = (x << 14) / isqrt(x*x + y*y) for the pair at or_ptr
; (x = x[p] + x[p+1], y = y[p] + y[p+1], int16)
;----------------------------------------------------------------------------
Heading:
    ldy #0
    lda [or_ptr],y
    ldy #4
    clc
    adc [or_ptr],y
    sta cxd                 ; (x for now)
    ldy #2
    lda [or_ptr],y
    ldy #6
    clc
    adc [or_ptr],y
    sta cyd                 ; (y for now)
    lda cxd
    tax
    jsr SMul16
    lda mres
    sta or_t0
    lda mres+2
    sta or_t0+2
    lda cyd
    tax
    jsr SMul16
    lda mres
    clc
    adc or_t0
    sta or_t0
    lda mres+2
    adc or_t0+2
    sta or_t0+2
    jsr ISqrt32             ; -> A = distance (uint16)
    sta or_t1
    beq @zero
    ; cxd = (x << 14) / distance  (int32 / uint16 -> truncate)
    lda cxd
    jsr Shl14Div
    pha
    lda cyd
    jsr Shl14Div
    sta cyd
    pla
    sta cxd
    rts
@zero:
    stz cxd
    stz cyd
    rts

; Shl14Div: A (int16) -> A = (A << 14) / or_t1 (distance, unsigned, > 0)
Shl14Div:
    tax
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    sta dvd+2               ; high word: A >> 2
    txa
    and #$0003
    clc
    ror a
    ror a
    ror a
    sta dvd                 ; low word: (A & 3) << 14
    lda or_t1
    jmp DivQ

;----------------------------------------------------------------------------
; ISqrt32: or_t0 (uint32, <= 2^31) -> A = floor(sqrt) (outils::isqrt)
; Bit by bit from bit 14: t = r | bit is kept when t * t <= n (SA-1
; multiplier, t < $8000).  n >= 2^30: r = $8000 + u, t^2 = 2^30 + u^2 +
; (u << 16), compared with n - 2^30.
;----------------------------------------------------------------------------
isq_r = or_t2               ; result (u in the high mode)
isq_b = or_t2+2             ; bit
ISqrt32:
    stz z:isq_r
    lda #$4000
    sta z:isq_b
    lda z:or_t0+2
    cmp #$4000
    bcs @hi
@l: lda z:isq_r
    ora z:isq_b
    sta MAL
    sta MBL                 ; t * t
    tax
    lda z:or_t0+2
    cmp MR+2
    bne :+
    lda z:or_t0
    cmp MR
:   bcc :+                  ; n < t * t
    stx z:isq_r
:   lsr z:isq_b
    bne @l
    lda z:isq_r
    rts
@hi:
    sbc #$4000              ; (C = 1) n - 2^30
    sta z:or_t0+2
@lh:
    lda z:isq_r
    ora z:isq_b
    sta MAL
    sta MBL                 ; u * u
    tax
    clc
    adc MR+2                ; + u (high word of u << 16)
    cmp z:or_t0+2
    bcc @keep
    bne @skip               ; > n - 2^30
    lda MR
    cmp z:or_t0
    beq @keep
    bcs @skip
@keep:
    stx z:isq_r
@skip:
    lsr z:isq_b
    bne @lh
    lda z:isq_r
    ora #$8000
    rts

;----------------------------------------------------------------------------
; set_tilemap_x: tilemap_h_target from the next 4 path vectors
;----------------------------------------------------------------------------
SetTilemapX:
    lda #0
    ldy #0
    clc
    adc [or_ptr],y
    ldy #4
    clc
    adc [or_ptr],y
    ldy #8
    clc
    adc [or_ptr],y
    ldy #12
    clc
    adc [or_ptr],y
    sta or_t1               ; x (int16)
    lda #0
    ldy #2
    clc
    adc [or_ptr],y
    ldy #6
    clc
    adc [or_ptr],y
    ldy #10
    clc
    adc [or_ptr],y
    ldy #14
    clc
    adc [or_ptr],y
    sta or_t1+2             ; y (int16)
    ; |x|, |y|
    lda or_t1
    bpl :+
    eor #$FFFF
    inc a
:   sta or_t2
    lda or_t1+2
    bpl :+
    eor #$FFFF
    inc a
:   sta or_t2+2
    ; y_abs > x_abs (signed int16 compare)
    lda or_t2+2
    sec
    sbc or_t2
    beq @xdom
    bvc :+
    eor #$8000
:   bmi @xdom
    ; scroll = (0x100 * x) / y
    lda or_t1
    jsr Shl8D
    lda or_t1+2
    bra @div
@xdom:
    ; scroll = (-0x100 * y) / x   (x = 0 -> 0)
    lda or_t1
    bne :+
    lda #0
    bra @turn
:   lda or_t1+2
    eor #$FFFF
    inc a
    jsr Shl8D
    lda or_t1
@div:
    jsr DivQ            ; divisor A (int16)
@turn:
    sta or_i
    ; turn right / left
    lda or_t1
    beq @x0
    bmi @xl
    lda #$0200
    bra @add
@xl:
    lda #$0600
    bra @add
@x0:
    lda or_t1+2
    bmi @xl
    lda #$0200
@add:
    clc
    adc or_i
    sta or_i
    ; y_abs > x_abs: d0 = x * y; >= 0: -0x200 else +0x200
    lda or_t2+2
    sec
    sbc or_t2
    beq @done
    bvc :+
    eor #$8000
:   bmi @done
    lda or_t1
    ldx or_t1+2
    jsr SMul16
    lda mres+2
    bmi @plus
    lda or_i
    sec
    sbc #$0200
    bra @st
@plus:
    lda or_i
    clc
    adc #$0200
@st:
    sta or_i
@done:
    lda or_i
    sta tilemap_h_target
    rts

; Shl8D: dvd = (int32)A << 8
Shl8D:
    pha
    xba
    and #$FF00
    sta dvd
    pla
    xba
    and #$00FF
    cmp #$0080
    bcc :+
    ora #$FF00
:   sta dvd+2
    rts

;----------------------------------------------------------------------------
; create_curve: from cx_total/cy_total and heading cxd/cyd
;   tx = cx_total>>5, ty = cy_total>>5
;   d0 = tx*cyd - ty*cxd ; d2 = (tx*cxd + ty*cyd) >> 7 ; d1 = (d2>>7) + $410
;   curve_inc = d0 / d1 ; curve_end = (d2 / d1) * 4   (int32 truncation)
; tx/ty are the low 16 bits of the shifts (|t| < $8000); the products are
; cumulative sums (|cxd|, |cyd| <= $4000, so -cxd fits).
;----------------------------------------------------------------------------
cc_tx = or_t1
cc_ty = or_t1+2
cc_d0 = or_t2               ; (32-bit)
cc_t  = or_inc              ; d2 << 1 (32-bit)
cc_d2 = or_co               ; d2 >> 7 (32-bit)
cc_d1 = or_i

CreateCurve:
    ; tx = bits 5-20 of cx_total, ty = bits 5-20 of cy_total
    lda cx_total+1
    asl a
    asl a
    asl a
    sta z:cc_tx
    lda cx_total
    and #$00E0
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    tsb z:cc_tx
    lda cy_total+1
    asl a
    asl a
    asl a
    sta z:cc_ty
    lda cy_total
    and #$00E0
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    tsb z:cc_ty
    ; d0 = tx*cyd + ty*(-cxd)
    lda #2
    sta MCNT                ; cumulative sum, sum = 0
    lda z:cc_tx
    sta MAL
    lda cyd
    sta MBL
    lda z:cc_ty
    sta MAL
    lda cxd
    eor #$FFFF
    inc a
    sta MBL
    nop
    nop
    lda MR
    sta dvd                 ; (d0, the dividend of curve_inc)
    lda MR+2
    sta dvd+2
    ; d2 = tx*cxd + ty*cyd
    lda #2
    sta MCNT                ; sum = 0
    lda z:cc_tx
    sta MAL
    lda cxd
    sta MBL
    lda z:cc_ty
    sta MAL
    lda cyd
    sta MBL
    nop
    nop
    lda MR
    asl a
    sta z:cc_t
    lda MR+2
    rol a
    sta z:cc_t+2            ; d2 << 1 (C = bit 31 of d2)
    ; d2 >>= 7: bytes 1-3 of d2 << 1, sign extended
    lda z:cc_t+1
    sta z:cc_d2
    lda z:cc_t+2
    xba
    and #$00FF
    bcc :+
    ora #$FF00
:   sta z:cc_d2+2
    ; d1 = (d2 >> 7) + $410 (low 16 bits: bits 14-29 of d2)
    lda z:cc_t
    asl a
    lda z:cc_t+2
    rol a
    clc
    adc #$0410
    sta z:cc_d1
    stz MCNT
    ; curve_inc = d0 / d1 (0 on a straight road without dividing)
    lda dvd
    ora dvd+2
    beq @ci
    lda z:cc_d1
    jsr DivQ
@ci:
    sta curve_inc
    ; curve_end = (d2 / d1) * 4
    jsr CurveEndQ
    asl a
    asl a
    sta curve_end
    rts

;----------------------------------------------------------------------------
; CurveEndQ: A = d2 / d1 (low 16 bits, as DivQ) for create_curve: d2 = cc_d2,
; d1 = cc_d1 = (d2 >> 7) + $410.  For 0 <= d2 < $3D0000, with v = d2 & $7F:
; d2 = 128 * d1 - W, W = $20800 - v, so d2 / d1 = 128 - ceil(W / d1).
; floor(W / d1) is estimated by the SA-1 divider, (W >> 3) / (d1 >> 3), then
; set exactly by one multiply and single steps (P = f * d1 <= W < P + d1).
; Other d2: DivQ.  (scratch: or_t0 = P, total_height = low word of W)
;----------------------------------------------------------------------------
cq_p = or_t0
cq_w = total_height

CurveEndQ:
    lda z:cc_d2+2
    cmp #$003D
    bcc :+
    lda z:cc_d2             ; (negative or large: DivQ)
    sta dvd
    lda z:cc_d2+2
    sta dvd+2
    lda z:cc_d1
    jmp DivQ
:   lda #1
    sta MCNT                ; divide
    lda z:cc_d2
    and #$007F              ; v
    tay
    clc
    adc #7
    lsr a
    lsr a
    lsr a
    eor #$FFFF
    sec
    adc #$4100              ; W >> 3 = $4100 - ((v + 7) >> 3)
    sta MAL
    lda z:cc_d1
    lsr a
    lsr a
    lsr a
    sta MBL                 ; (W >> 3) / (d1 >> 3)
    tya
    eor #$FFFF
    sec
    adc #$0800
    sta z:cq_w              ; W = $2:(0800 - v)
    nop
    ldx MR                  ; f (estimate)
    stz MCNT                ; multiply
    stx MAL
    lda z:cc_d1
    sta MBL                 ; P = f * d1
    nop
    lda MR
    sta z:cq_p
    lda MR+2
    sta z:cq_p+2
@dn:
    ; P > W: f--, P -= d1
    lda z:cq_p+2
    cmp #2
    bcc @up
    bne :+
    lda z:cq_p
    cmp z:cq_w
    beq @exact
    bcc @up
:   dex
    lda z:cq_p
    sec
    sbc z:cc_d1
    sta z:cq_p
    bcs @dn
    dec z:cq_p+2
    bra @dn
@up:
    ; (P < W) P + d1 <= W: f++, P += d1
    lda z:cq_p
    clc
    adc z:cc_d1
    tay
    lda z:cq_p+2
    adc #0
    cmp #2
    bcc @inc
    bne @ceil
    cpy z:cq_w
    bcc @inc
    bne @ceil
    inx                     ; P + d1 = W
@exact:
    txa                     ; ceil = f
    bra @q
@inc:
    inx
    sty z:cq_p
    sta z:cq_p+2
    bra @up
@ceil:
    inx                     ; ceil = f + 1
    txa
@q: eor #$FFFF
    sec
    adc #128                ; 128 - ceil
    rts

;----------------------------------------------------------------------------
; DivQ: dvd (int32) / A (int16, != 0) -> A = low 16 bits of the quotient
; truncated toward 0 (as SDivQ's dvd low word).  Divisor > 0: SA-1 divider
; when the dividend fits int16, else 16-step restoring division of
; (|dvd| mod (d << 16)) (the SA-1 divider gives the high word's remainder);
; divisor <= 0 or dividend -2^31: SDivQ.
;----------------------------------------------------------------------------
dq_lo = or_t0               ; |dividend| low word -> quotient
dq_s  = or_t0+2             ; bit 15: negative dividend
dq_r  = total_height        ; (callers keep values in or_t1, or_t2, or_i, or_co)
dq_t  = total_height+2

DivQ:
    tax
    beq @soft
    bmi @soft
    lda dvd+2
    beq @p
    inc a
    bne @long               ; high word not 0 / $FFFF
    lda dvd
    bpl @long               ; < -$8000
    bra @hw
@p: lda dvd
    bmi @long               ; >= $8000
@hw:
    ldy #1
    sty MCNT                ; divide
    sta MAL
    stx MBL
    cmp #$8000              ; C = negative dividend
    nop
    lda MR                  ; floor
    bcc :+
    ldy MR+2
    beq :+
    inc a                   ; truncation toward 0
:   stz MCNT
    rts
@soft0:
    txa
@soft:
    jsr SDivQ
    lda dvd
    rts
@long:
    stx dvs
    lda dvd+2
    sta z:dq_s
    bpl @mp
    lda dvd
    eor #$FFFF
    clc
    adc #1
    sta z:dq_lo
    lda dvd+2
    eor #$FFFF
    adc #0
    bra @mh
@mp:
    lda dvd
    sta z:dq_lo
    lda dvd+2
@mh:
    cmp dvs
    bcc @div                ; high word < d: remainder = high word
    cmp #$8000
    bcs @soft0              ; |dividend| = 2^31
    ldy #1
    sty MCNT
    sta MAL
    stx MBL
    nop
    nop
    lda MR+2                ; high word mod d
    stz MCNT
@div:
    ; A = remainder r (< d <= $7FFF), dq_lo = low word.  Quotient < 256
    ; (r * 256 + (low word >> 8) < d): 8 steps on the low byte.
    cmp #$0100
    bcs @s16
    sta z:dq_r
    xba                     ; r << 8
    cmp dvs
    bcs @s16r               ; >= d: quotient >= 256
    sta z:dq_t
    lda z:dq_lo
    xba
    tax                     ; (low byte << 8) | high byte
    and #$00FF
    ora z:dq_t              ; r * 256 + (low word >> 8)
    cmp dvs
    bcs @s16r
    stx z:dq_lo             ; the low byte first
    asl z:dq_lo
    rol a
    cmp dvs
    bcc :+
    sbc dvs
:
    rol z:dq_lo
    rol a
    cmp dvs
    bcc :+
    sbc dvs
:
    rol z:dq_lo
    rol a
    cmp dvs
    bcc :+
    sbc dvs
:
    rol z:dq_lo
    rol a
    cmp dvs
    bcc :+
    sbc dvs
:
    rol z:dq_lo
    rol a
    cmp dvs
    bcc :+
    sbc dvs
:
    rol z:dq_lo
    rol a
    cmp dvs
    bcc :+
    sbc dvs
:
    rol z:dq_lo
    rol a
    cmp dvs
    bcc :+
    sbc dvs
:
    rol z:dq_lo
    rol a
    cmp dvs
    bcc :+
    sbc dvs
:
    rol z:dq_lo
    lda z:dq_lo
    and #$00FF
    bit z:dq_s
    bpl :+
    eor #$FFFF
    inc a
:   rts
@s16r:
    lda z:dq_r
@s16:
    ; 16 steps, quotient bits rotated into dq_lo
    asl z:dq_lo
    rol a
    cmp dvs
    bcc :+
    sbc dvs
:
    rol z:dq_lo
    rol a
    cmp dvs
    bcc :+
    sbc dvs
:
    rol z:dq_lo
    rol a
    cmp dvs
    bcc :+
    sbc dvs
:
    rol z:dq_lo
    rol a
    cmp dvs
    bcc :+
    sbc dvs
:
    rol z:dq_lo
    rol a
    cmp dvs
    bcc :+
    sbc dvs
:
    rol z:dq_lo
    rol a
    cmp dvs
    bcc :+
    sbc dvs
:
    rol z:dq_lo
    rol a
    cmp dvs
    bcc :+
    sbc dvs
:
    rol z:dq_lo
    rol a
    cmp dvs
    bcc :+
    sbc dvs
:
    rol z:dq_lo
    rol a
    cmp dvs
    bcc :+
    sbc dvs
:
    rol z:dq_lo
    rol a
    cmp dvs
    bcc :+
    sbc dvs
:
    rol z:dq_lo
    rol a
    cmp dvs
    bcc :+
    sbc dvs
:
    rol z:dq_lo
    rol a
    cmp dvs
    bcc :+
    sbc dvs
:
    rol z:dq_lo
    rol a
    cmp dvs
    bcc :+
    sbc dvs
:
    rol z:dq_lo
    rol a
    cmp dvs
    bcc :+
    sbc dvs
:
    rol z:dq_lo
    rol a
    cmp dvs
    bcc :+
    sbc dvs
:
    rol z:dq_lo
    rol a
    cmp dvs
    bcc :+
    sbc dvs
:
    rol z:dq_lo
    lda z:dq_lo
    bit z:dq_s
    bpl :+
    eor #$FFFF
    inc a
:   rts

;============================================================================
; setup_hscroll / do_road_offset
;============================================================================
SetupHScroll:
    lda road_ctrl
    asl a
    tax
    jmp (HsTab,x)
HsTab:
    .addr HsOff, HsR0, HsR1, HsBoth, HsBoth, HsBothInv, HsBothInv, HsR0, HsR1Split
HsOff:
    rts
HsR0:
    lda road_width_bak
    eor #$FFFF
    inc a
    ldx #RD_H0
    ldy #0
    jmp RoadOffset
HsR1:
    lda road_width_bak
    ldx #RD_H1
    ldy #0
    jmp RoadOffset
HsBoth:
    jsr HsR0
    bra HsR1
HsBothInv:
    jsr HsR0
    ; fall into HsR1Split
HsR1Split:
    lda road_width_bak
    ldx #RD_H1
    ldy #1
    ; fall into RoadOffset

;----------------------------------------------------------------------------
; RoadOffset: A = width, X = destination array, Y = invert (0/1)
; do_road_offset, evaluated lazily: records car_offset and the invert flag
; for the road; HEval gives road0_h[i] / road1_h[i] on demand:
;   car_offset = car_x_bak + width + camera_x_off
;   != 0: h[i] = ((i * car_offset) >> 9) +- (road_x[i] >> 6)
;         marker entries: 0 +- (MARK >> 6)
;   == 0: h[i] = road_x[i] >> 6   (invert: (-road_x[i]) >> 6)
;----------------------------------------------------------------------------
RoadOffset:
    cpx #RD_H0
    beq :+
    ldx #2
    bra :++
:   ldx #0
:   clc
    adc car_x_bak
    clc
    adc camera_x_off
    sta rd_co,x
    tya
    sta rd_inv,x
    lda #1
    sta rd_set,x
    rts

;----------------------------------------------------------------------------
; HEval: X = road*2 (0 road 0, 2 road 1), A = index (0-511) -> A = h[i]
; x >> 6 (arithmetic) is computed as ((x ^ $8000) >> 6) - $200.
;----------------------------------------------------------------------------
he_t = or_t0

HEval:
    and #$01FF
    txy                     ; Y = road*2
    sta MAL                 ; i
    asl a
    tax
    lda rd_co,y
    beq @centred
    sta MBL                 ; i * car_offset
    lda f:RDB*$10000+RD_X,x
    cmp #MARK
    beq @mark
    eor #$8000
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    sta z:he_t              ; (x >> 6) + $200
    ; base = (i * car_offset) >> 9: bits 9-24 of the product
    lda MR+3
    lsr a                   ; C = bit 24
    lda MR+1
    ror a
    ldx rd_inv,y
    bne @inv
    clc
    adc z:he_t
    sec
    sbc #$0200
    rts
@inv:
    sec
    sbc z:he_t
    clc
    adc #$0200
    rts
@mark:
    lda rd_inv,y
    bne :+
    lda #MARK >> 6
    rts
:   lda #($10000 - (MARK >> 6)) & $FFFF
    rts
@centred:
    ; car centred: h = x >> 6 (invert: (-x) >> 6)
    lda f:RDB*$10000+RD_X,x
    ldx rd_inv,y
    beq :+
    eor #$FFFF
    inc a
:   eor #$8000
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    sec
    sbc #$0200
    rts

    .ifdef ROADTEST
;----------------------------------------------------------------------------
; RoadFillH (test only): road0_h/road1_h arrays for the roads set this tick
;----------------------------------------------------------------------------
.export RoadFillH
RoadFillH:
    ldx #0
    jsr @fill
    ldx #2
@fill:
    lda rd_set,x
    bne :+
    rts
:   stz rd_set,x
    stx he_r
    stz he_n
@l: ldx he_r
    lda he_n
    jsr HEval
    pha
    lda he_n
    asl a
    ldy he_r
    beq :+
    clc
    adc #RD_H1-RD_H0
:   tax
    pla
    sta f:RDB*$10000+RD_H0,x
    inc he_n
    lda he_n
    cmp #$0200
    bcc @l
    rts
    .endif

;============================================================================
; setup_road_y: height state machine
;============================================================================
SetupRoadY:
    lda pos_fine
    sec
    sbc pos_fine_old
    sta pos_fine_diff
    lda pos_fine
    sta pos_fine_old
    lda horizon_set
    bne :+
    lda #$0240
    sta horizon_base
    lda #1
    sta horizon_set
:   lda height_ctrl
    asl a
    tax
    jmp (HcTab,x)
HcTab:
    .addr HcClear, InitHeightSeg, DoElevation, DoElevationDelay, DoElevationMixed, DoHorizonAdjust
HcClear:
    stz height_lookup
    ; fall into InitHeightSeg

InitHeightSeg:
    stz height_index
    stz height_inc
    stz elevation
    lda #1
    sta height_step
    lda height_lookup
    sta height_lookup_wrk
    ; h_addr = HeightPtrs[height_lookup_wrk] (24-bit)
    sta or_t0
    asl a
    clc
    adc or_t0
    tax
    lda f:HeightPtrs,x
    sta or_hptr
    lda f:HeightPtrs+1,x
    sta or_hptr+1
    lda [or_hptr]
    and #$00FF
    sta height_ctrl2
    ldy #1
    lda [or_hptr],y
    and #$00FF
    sta step_adjust
    lda #2
    jsr HAdvance
    lda height_ctrl2
    asl a
    tax
    jmp (IhTab,x)
IhTab:
    .addr InitElevation, InitElevationDelay, InitElevationDelay, InitElevationMixed, InitHorizonAdjust

; HAdvance: or_hptr += A
HAdvance:
    clc
    adc or_hptr
    sta or_hptr
    bcc :+
    sep #$20
    .a8
    inc or_hptr+2
    rep #$20
    .a16
:   rts

; read a big-endian word at [or_hptr],y
.macro HREAD ofs
    ldy #ofs
    lda [or_hptr],y
    xba
.endmacro

InitElevation:
    lda [or_hptr]
    and #$00FF
    cmp #$0080              ; int8
    bcc :+
    ora #$FF00
:   sta down_mult
    ldy #1
    lda [or_hptr],y
    and #$00FF
    cmp #$0080
    bcc :+
    ora #$FF00
:   sta up_mult
    lda #2
    jsr HAdvance
    lda #2
    sta height_ctrl
    ; fall into DoElevation

DoElevation:
    ; height_step += pos_fine_diff * 12
    jsr StepAdd12
    ; d3 = step_adjust (* up_mult / * down_mult)
    lda step_adjust
    ldx elevation
    beq @d3
    cpx #1
    beq @up
    ldx down_mult
    bra @mul
@up:
    ldx up_mult
@mul:
    jsr SMul16
    lda mres                ; uint16 result of the product
@d3:
    sta or_t0
    ; d1 = height_step / d3 (unsigned 16)
    lda height_step
    ldx or_t0
    jsr UDiv16
    cmp #$0100
    bcc :+
    lda #$00FF
:   clc
    adc #$0100
    sta height_start
    sta height_end
    lda height_index
    clc
    adc height_inc
    sta height_index
    stz height_inc
    lda height_start
    cmp #$01FF
    bne @ck
    lda #1
    sta height_step
    sta height_inc
    stz elevation
    rts
@ck:
    lda height_lookup
    beq :+
    lda height_lookup_wrk
    bne :+
    lda #1
    sta height_ctrl
:   rts

; height_step += pos_fine_diff * 12 (16-bit wrap)
StepAdd12:
    lda pos_fine_diff
    asl a
    asl a
    sta or_t0
    asl a
    clc
    adc or_t0               ; *12
    clc
    adc height_step
    sta height_step
    rts

InitElevationDelay:
    HREAD 0
    sta height_delay
    lda #2
    jsr HAdvance
    lda #1
    sta do_height_inc
    stz height_inc
    lda #$0100
    sta height_end
    lda #3
    sta height_ctrl
    ; fall into DoElevationDelay

DoElevationDelay:
    ; d1 = pos_fine_diff * 12 (int16)
    lda pos_fine_diff
    asl a
    asl a
    sta or_t0
    asl a
    clc
    adc or_t0
    sta or_t1               ; d1
    lda height_index
    clc
    adc height_inc
    sta height_index
    stz height_inc
    lda height_index
    beq @p13
    lda do_height_inc
    bne @p2
@p13:
    lda height_step
    clc
    adc or_t1
    sta height_step
    ; d1 = height_step / step_adjust (int16 = uint16/uint16)
    ldx step_adjust
    jsr UDiv16
    cmp #$0100
    bcc :+
    lda #$00FF
:   sta or_t1
    sta height_start
    cmp #$00FF
    bcc @p3
    lda #$00FF
    sta height_start
    lda #1
    sta height_step
    sta height_inc
    stz elevation
@p3:
    lda height_index
    beq :+
    lda #$00FF
    sec
    sbc height_start
    sta or_t1
:   lda or_t1
    clc
    adc #$0100
    sta height_start
    rts
@p2:
    ; height_delay -= d1 / step_adjust (int16 / uint16 -> int, truncate)
    lda or_t1
    ldx step_adjust
    jsr SDiv16T
    eor #$FFFF
    sec
    adc height_delay
    sta height_delay
    lda #$01FF
    sta height_start
    lda height_delay
    bpl :+
    stz do_height_inc
:   rts

InitElevationMixed:
    HREAD 0
    sta height_delay
    lda #2
    jsr HAdvance
    lda #1
    sta do_height_inc
    stz height_inc
    lda #4
    sta height_ctrl
    ; fall into DoElevationMixed

DoElevationMixed:
    ; d1 = pos_fine_diff * 12 (uint16)
    lda pos_fine_diff
    asl a
    asl a
    sta or_t0
    asl a
    clc
    adc or_t0
    sta or_t1
    lda height_index
    clc
    adc height_inc
    sta height_index
    stz height_inc
    lda height_index
    cmp #6
    bcc @part1
    bmi @part1
    lda do_height_inc
    beq @part3
    ; part 2: delay on the sixth entry
    lda or_t1
    ldx step_adjust
    jsr UDiv16              ; (d1 / d3, both uint16)
    eor #$FFFF
    sec
    adc height_delay
    sta height_delay
    lda #$01FF
    sta height_start
    lda #$0100
    sta height_end
    lda height_delay
    bpl :+
    lda #12
    jsr HAdvance            ; height_addr += 12
    stz do_height_inc
:   rts
@part3:
    lda height_step
    clc
    adc or_t1
    sta height_step
    ldx step_adjust
    jsr UDiv16
    cmp #$0100
    bcc :+
    lda #$00FF
:   sta or_t1
    lda #$01FF
    sec
    sbc or_t1
    sta height_start
    cmp #$0100
    bne :+
    lda #1
    sta height_step
    sta height_inc
    stz elevation
:   rts
@part1:
    lda height_step
    clc
    adc or_t1
    sta height_step
    lsr a
    lsr a                   ; height_step / 4
    cmp #$0100
    bcc :+
    lda #$00FF
:   clc
    adc #$0100
    sta height_start
    sta height_end
    cmp #$01FF
    bcc :+
    lda #$01FF
    sta height_start
    sta height_end
    lda #1
    sta height_step
    sta height_inc
    stz elevation
:   rts

InitHorizonAdjust:
    ; horizon_mod = read16(h_addr) - horizon_base (uint32)
    HREAD 0
    sta or_t0
    sec
    sbc horizon_base
    sta horizon_mod
    ; high word: sext(value) - sext(horizon_base) - borrow
    lda or_t0
    and #$8000
    beq :+
    lda #$FFFF
:   sta or_t0+2
    lda horizon_base
    and #$8000
    beq :+
    lda #$FFFF
:   sta or_t1
    lda or_t0
    cmp horizon_base        ; carry = no borrow of the low word
    lda or_t0+2
    sbc or_t1
    sta horizon_mod+2
    lda #5
    sta height_ctrl
    ; fall into DoHorizonAdjust

DoHorizonAdjust:
    jsr StepAdd12
    ldx step_adjust
    jsr UDiv16
    cmp #$0100
    bcc :+
    lda #$00FF
:   clc
    adc #$0100
    sta height_start
    sta height_end
    rts

;----------------------------------------------------------------------------
; SDivQ: dvd (int32) / A (int16, != 0) -> dvd = quotient (int32, truncated
; toward 0). 16-step division when the quotient fits 16 bits.
;----------------------------------------------------------------------------
SDivQ:
    sta sdq_d
    eor dvd+2
    sta sdq_s               ; bit 15 = sign of the result
    lda sdq_d
    bpl :+
    eor #$FFFF
    inc a
:   sta dvs                 ; |divisor|
    lda dvd+2
    bpl @pos
    lda dvd
    eor #$FFFF
    clc
    adc #1
    sta dvd
    lda dvd+2
    eor #$FFFF
    adc #0
    sta dvd+2
@pos:
    lda dvd+2
    cmp dvs
    bcs @slow
    ldx #16                 ; remainder in A (= high word < divisor)
@l: asl dvd
    rol a
    bcs @sub
    cmp dvs
    bcc @n
@sub:
    sbc dvs
    inc dvd
@n: dex
    bne @l
    stz dvd+2
    bra @sign
@slow:
    jsr UDiv32_16
@sign:
    lda sdq_s
    bpl @done
    lda dvd
    eor #$FFFF
    clc
    adc #1
    sta dvd
    lda dvd+2
    eor #$FFFF
    adc #0
    sta dvd+2
@done:
    rts

;----------------------------------------------------------------------------
; UDiv16: A / X (unsigned 16) -> A (quotient). X = 0 -> $FFFF.
; A < $8000: SA-1 divider (floor = unsigned quotient for A >= 0).
;----------------------------------------------------------------------------
UDiv16:
    cpx #0
    beq UDiv16s
    cmp #$8000
    bcs UDiv16s
    ldy #1
    sty MCNT                ; divide mode
    sta MAL
    stx MBL
    nop
    nop
    lda MR
    stz MCNT
    rts
UDiv16s:
    stx or_t2
    sta or_t2+2
    lda #0
    ldx #16
:   asl or_t2+2
    rol a
    cmp or_t2
    bcc :+
    sbc or_t2
    inc or_t2+2
:   dex
    bne :--
    lda or_t2+2
    rts

;----------------------------------------------------------------------------
; SDiv16T: A (int16) / X (uint16, > 0) -> A = quotient truncated toward 0
;----------------------------------------------------------------------------
SDiv16T:
    cmp #$8000
    bcc UDiv16
    eor #$FFFF
    inc a
    jsr UDiv16
    eor #$FFFF
    inc a
    rts

;============================================================================
; set_road_y
;============================================================================
SetRoadY:
    lda height_ctrl2
    cmp #4
    bne SetYInterpolate
    jmp SetYHorizon

; SyWrite state (direct page; the xs_* scratch of setup_x_data)
sy_sw  = xs_scan            ; nonzero: software total_height (see SyWrite)
sy_n   = xs_x
sy_r   = xs_inc
sy_t   = xs_cnt
sy_end = or_sc
xs_np  = or_sc              ; (setup_x_data: positions of the sample)

;----------------------------------------------------------------------------
; set_y_interpolate: section lengths, then set_y_2044 x7 (loop form of the
; set_y_2044 -> read_next_height -> set_elevation -> set_y_2044 recursion)
; total_height << 4 is kept in the arithmetic unit (cumulative sum mode)
; from here to the end of the last section, see SyWrite.
;----------------------------------------------------------------------------
SetYInterpolate:
    lda height_end
    sta or_t0               ; d2
    lda #$01FF
    sec
    sbc or_t0
    sta section_lengths+0   ; d1
    sta or_t1
    lda or_t0
    lsr a
    sta section_lengths+2   ; d2 >>= 1
    sta or_t0
    ; d3 = 0x200 - d1 - d2
    lda #$0200
    sec
    sbc or_t1
    sec
    sbc or_t0
    sta section_lengths+6
    lsr a
    sta section_lengths+4
    lda section_lengths+6
    sec
    sbc section_lengths+4
    sta section_lengths+6
    ldx #6
:   lda section_lengths,x
    sta section_lengths+2,x
    lsr a
    sta section_lengths,x
    lda section_lengths+2,x
    sec
    sbc section_lengths,x
    sta section_lengths+2,x
    inx
    inx
    cpx #12
    bcc :-
    stz length_offset
    ; a1_lookup = height_index*2 + height_addr
    lda height_index
    asl a
    clc
    adc or_hptr
    sta or_a1
    sep #$20
    .a8
    lda or_hptr+2
    adc #0
    sta or_a1+2
    rep #$20
    .a16
    ; y_addr = 0x200 + road_p1 (byte offset of the element after the block)
    lda road_p1
    clc
    adc #$0400
    sta y_addr
    ; road_unk[0] = 0x1FF, road_unk[1] = 0, a3_o = 2
    lda #$01FF
    sta f:RDB*$10000+RD_UNK
    lda #0
    sta f:RDB*$10000+RD_UNK+2
    lda #4
    sta a3_o                ; (byte offset)
    stz counter
    ; height_final = (next_height * (height_start - 0x100)) >> 4
    lda [or_a1]
    xba
    tax
    lda height_start
    sec
    sbc #$0100
    jsr SMul16
    lda mres+2
    cmp #$8000
    ror a
    sta height_final+2
    lda mres
    ror a
    tax
    lda height_final+2
    cmp #$8000
    ror a
    sta height_final+2
    txa
    ror a
    tax
    lda height_final+2
    cmp #$8000
    ror a
    sta height_final+2
    txa
    ror a
    tax
    lda height_final+2
    cmp #$8000
    ror a
    sta height_final+2
    txa
    ror a
    sta height_final
    ; horizon_copy = (horizon_base + horizon_offset) << 4
    jsr HorizonShift        ; -> or_t2 (32-bit)
    lda height_ctrl2
    cmp #2
    bne :+
    lda or_t2
    clc
    adc height_final
    sta or_t2
    lda or_t2+2
    adc height_final+2
    sta or_t2+2
:   lda or_t2
    sta change_per_entry
    lda or_t2+2
    sta change_per_entry+2
    lda #$0200
    sta yl_scan
    ; total_height = 0: cumulative sum mode (clears the sum)
    lda #2
    sta MCNT
    stz z:sy_sw
SetY2044:
    ; if change_per_entry > 0x10000: = 0x10000 (signed compare)
    lda change_per_entry+2
    bmi @keep
    cmp #1
    bcc @keep
    bne @clamp
    lda change_per_entry
    beq @keep
@clamp:
    stz change_per_entry
    lda #1
    sta change_per_entry+2
@keep:
    lda change_per_entry
    sta d5_o
    lda change_per_entry+2
    sta d5_o+2
    ; section_length = section_lengths[length_offset++] - 1
    ldx length_offset
    lda section_lengths,x
    dec a
    sta or_i
    inx
    inx
    stx length_offset
    lda yl_scan
    sec
    sbc or_i
    sta yl_scan
    lda or_i
    bmi @nowrite
    ; write section_length + 1 entries downwards
    inc a
    jsr SyWrite
@nowrite:
    lda counter
    inc a
    sta counter
    cmp #7
    beq @last
    jmp ReadNextHeight
@last:
    stz MCNT                ; arithmetic unit back to multiply mode
    ; road_unk[a3_o] = 0
    ldx a3_o
    lda #0
    sta f:RDB*$10000+RD_UNK,x
    ; end of height section data?
    lda [or_a1]
    cmp #$FFFF
    bne :+
    lda height_lookup
    cmp height_lookup_wrk
    bne @nx
    stz height_lookup
@nx:
    lda #1
    sta height_ctrl
:   rts

;----------------------------------------------------------------------------
; SyWrite: A (>= 1) entries downwards from y_addr (byte offset of the
; element after them): total_height += change_per_entry,
; road_y[--y_addr] = (total_height << 4) >> 16.
; The arithmetic unit is in cumulative sum mode and MR holds
; total_height << 4 (mod 2^32 in its low 32 bits): every entry adds
; MA * MB = change_per_entry * 16, with MA = change_per_entry >> s and
; MB = 16 << s.  A change_per_entry that cannot be written so (odd and
; outside int16, ...) moves the sum to total_height and sets sy_sw: software
; sum until the end of the block.
;----------------------------------------------------------------------------
SyWrite:
    sta z:sy_n
    ldx rd_dry
    beq :+
    jmp SyDry
:   lda z:sy_sw
    beq :+
    jmp SyWriteSoft
:   lda change_per_entry
    ldx change_per_entry+2
    ldy #16
@fit:
    cmp #$8000
    bcs @neg
    cpx #0
    beq @ok
    bra @shift
@neg:
    cpx #$FFFF
    beq @ok
@shift:
    ; MA / 2, MB * 2 (only for an even MA and MB < $8000)
    bit #1
    bne @soft
    cpy #$4000
    bcs @soft
    sta z:sy_t
    tya
    asl a
    tay
    txa
    cmp #$8000
    ror a
    tax
    lda z:sy_t
    ror a
    bra @fit
@soft:
    ; software sum from here: total_height = MR
    lda MR
    sta total_height
    lda MR+2
    sta total_height+2
    lda #1
    sta z:sy_sw
    jmp SyWriteSoft
@ok:
    sta MAL
    ldx y_addr
    lda z:sy_n
    and #3
    beq @q4
    sta z:sy_r
    ; single entries (MR is read 7 cycles after the MBH write)
@s1:
    sty MBL
    dex
    dex
    lda MR+2
    sta f:RDB*$10000+RD_Y,x
    dec z:sy_r
    bne @s1
@q4:
    ; start the next sum before storing the previous entry (MR read
    ; >= 11 cycles after the MBH write)
    lda z:sy_n
    and #4
    beq @q8
    sty MBL
    txa
    sec
    sbc #8
    tax
    lda MR+2
    sty MBL
    sta f:RDB*$10000+RD_Y+6,x
    lda MR+2
    sty MBL
    sta f:RDB*$10000+RD_Y+4,x
    lda MR+2
    sty MBL
    sta f:RDB*$10000+RD_Y+2,x
    lda MR+2
    sta f:RDB*$10000+RD_Y,x
@q8:
    lda z:sy_n
    lsr a
    lsr a
    lsr a
    beq @done
    asl a
    asl a
    asl a
    asl a
    sta z:sy_t
    txa
    sec
    sbc z:sy_t
    sta z:sy_end            ; (C = 1)
@g8:
    sty MBL
    txa
    sbc #16                 ; (C = 1)
    tax
    lda MR+2
    sty MBL
    sta f:RDB*$10000+RD_Y+14,x
    lda MR+2
    sty MBL
    sta f:RDB*$10000+RD_Y+12,x
    lda MR+2
    sty MBL
    sta f:RDB*$10000+RD_Y+10,x
    lda MR+2
    sty MBL
    sta f:RDB*$10000+RD_Y+8,x
    lda MR+2
    sty MBL
    sta f:RDB*$10000+RD_Y+6,x
    lda MR+2
    sty MBL
    sta f:RDB*$10000+RD_Y+4,x
    lda MR+2
    sty MBL
    sta f:RDB*$10000+RD_Y+2,x
    lda MR+2
    sta f:RDB*$10000+RD_Y,x
    cpx z:sy_end
    bne @g8
@done:
    stx y_addr
    rts

; SyDry: SyWrite without the road_y writes (rd_dry): total_height (in
; software from here, sy_sw) += n * (change_per_entry << 4), y_addr -= 2n
SyDry:
    lda z:sy_sw
    bne @sw
    lda MR                  ; (the arithmetic unit's sum so far)
    sta total_height
    lda MR+2
    sta total_height+2
    lda #1
    sta z:sy_sw
@sw:
    stz MCNT                ; multiply mode (MR is not read again this block)
    lda change_per_entry+2
    sta or_t2+2
    lda change_per_entry
    asl a
    rol or_t2+2
    asl a
    rol or_t2+2
    asl a
    rol or_t2+2
    asl a
    rol or_t2+2
    sta or_t2               ; or_t2 = change_per_entry << 4
    ldx z:sy_n
    jsr UMul16              ; n * low word (unsigned)
    lda mres
    clc
    adc total_height
    sta total_height
    lda mres+2
    adc total_height+2
    sta total_height+2
    lda or_t2+2
    ldx z:sy_n
    jsr SMul16              ; n * high word (low 16 bits)
    lda mres
    clc
    adc total_height+2
    sta total_height+2
    lda z:sy_n
    asl a
    eor #$FFFF
    sec
    adc y_addr
    sta y_addr
    rts

; SyWriteSoft: SyWrite with the sum in total_height
SyWriteSoft:
    lda change_per_entry
    sta or_t2
    lda change_per_entry+2
    asl or_t2
    rol a
    asl or_t2
    rol a
    asl or_t2
    rol a
    asl or_t2
    rol a
    sta or_t2+2             ; or_t2 = change_per_entry << 4
    ldx y_addr
@wr:
    lda total_height
    clc
    adc or_t2
    sta total_height
    lda total_height+2
    adc or_t2+2
    sta total_height+2
    dex
    dex
    sta f:RDB*$10000+RD_Y,x
    dec z:sy_n
    bne @wr
    stx y_addr
    rts

; HorizonShift: or_t2 = (horizon_base + horizon_offset) << 4 (32-bit signed)
HorizonShift:
    lda horizon_base
    clc
    adc horizon_offset
    sta or_t2
    and #$8000
    beq :+
    lda #$FFFF
:   sta or_t2+2
    ldx #4
:   asl or_t2
    rol or_t2+2
    dex
    bne :-
    rts

;----------------------------------------------------------------------------
; read_next_height / set_elevation (continue the set_y_2044 loop)
;----------------------------------------------------------------------------
ReadNextHeight:
    lda height_ctrl2
    beq @flag
    cmp #1
    bne @c2
    jsr AddHFinal
    jmp SetElevation
@c2:
    cmp #2
    bne :+
    jmp SetElevation
:
    cmp #3
    bne @flag
    lda height_index
    cmp #6
    bcc @flag
    bmi @flag
    jsr AddHFinal
    bra SetElevation
@flag:
    ; change_per_entry = read16(a1_lookup) << 4 ; a1_lookup += 2
    lda [or_a1]
    xba
    tax
    asl a
    asl a
    asl a
    asl a
    sta change_per_entry
    txa
    xba
    and #$00F0
    lsr a
    lsr a
    lsr a
    lsr a                   ; bits 12-15
    cpx #$8000
    bcc :+
    ora #$FFF0
:   sta change_per_entry+2
    lda or_a1
    clc
    adc #2
    sta or_a1
    bcc :+
    sep #$20
    .a8
    inc or_a1+2
    rep #$20
    .a16
:   ; change_per_entry += d5_o
    lda change_per_entry
    clc
    adc d5_o
    sta change_per_entry
    lda change_per_entry+2
    adc d5_o+2
    sta change_per_entry+2
    lda counter
    cmp #1
    bne SetElevation
    ; first part: change_per_entry -= height_final; compare with horizon
    lda change_per_entry
    sec
    sbc height_final
    sta change_per_entry
    lda change_per_entry+2
    sbc height_final+2
    sta change_per_entry+2
    jsr HorizonShift
    lda change_per_entry
    cmp or_t2
    bne @ne
    lda change_per_entry+2
    cmp or_t2+2
    beq SetElevation
@ne:
    ; signed 32-bit compare change_per_entry > horizon_shift
    lda change_per_entry
    cmp or_t2
    lda change_per_entry+2
    sbc or_t2+2
    bvc :+
    eor #$8000
:   bmi @down
    lda #1
    sta elevation
    bra SetElevation
@down:
    lda #$FFFF
    sta elevation
    ; fall into SetElevation

SetElevation:
    ; d5_o -= change_per_entry
    lda d5_o
    sec
    sbc change_per_entry
    sta d5_o
    lda d5_o+2
    sbc change_per_entry+2
    sta d5_o+2
    ora d5_o
    bne :+
    jmp SetY2044
:   ; (d5_o only matters as a zero test from here on)
    ; road_unk[a3_o++] = scanline
    ldx a3_o
    lda yl_scan
    sta f:RDB*$10000+RD_UNK,x
    ; road_unk[a3_o++] = (|total| << 4) >> 16 = high word of |total_height|
    lda z:sy_sw
    bne @sw
    lda MR                  ; total_height << 4 from the arithmetic unit
    sta total_height
    lda MR+2
    sta total_height+2
@sw:
    lda total_height+2
    bpl @sh
    lda total_height
    eor #$FFFF
    clc
    adc #1
    lda total_height+2
    eor #$FFFF
    adc #0
@sh:
    sta f:RDB*$10000+RD_UNK+2,x
    inx
    inx
    inx
    inx
    stx a3_o
    jmp SetY2044

AddHFinal:
    lda change_per_entry
    clc
    adc height_final
    sta change_per_entry
    lda change_per_entry+2
    adc height_final+2
    sta change_per_entry+2
    rts

;----------------------------------------------------------------------------
; set_y_horizon (stage 2 Gateway): straight road_y ramp from the horizon
;----------------------------------------------------------------------------
SetYHorizon:
    ; d1 = (horizon_mod * (height_start - 0x100)) >> 4  (uint32 product and
    ; logical shift, as the C++); horizon_mod fits 16 bits signed
    lda height_start
    sec
    sbc #$0100
    tax
    lda horizon_mod
    jsr SMul16              ; low 32 bits of the product = uint32 product
    lda mres+2
    sta or_t1+2
    lda mres
    ldx #4
:   lsr or_t1+2
    ror a
    dex
    bne :-
    sta or_t1               ; d1
    ; d2 = ((horizon_base + horizon_offset) << 4) + d1
    jsr HorizonShift
    lda or_t2
    clc
    adc or_t1
    sta change_per_entry
    lda or_t2+2
    adc or_t1+2
    sta change_per_entry+2
    ; 0x200 entries: total_height (from 0) += d2
    lda road_p1
    clc
    adc #$0400
    sta y_addr
    lda #2
    sta MCNT                ; cumulative sum mode, sum = 0
    stz z:sy_sw
    lda #$0200
    jsr SyWrite
    stz MCNT
    lda #0
    sta f:RDB*$10000+RD_UNK
    lda height_start
    cmp #$01FF
    bne :+
    HREAD 0
    sta horizon_base
    lda height_lookup
    cmp height_lookup_wrk
    bne @nx
    stz height_lookup
@nx:
    lda #1
    sta height_ctrl
:   rts

;============================================================================
; set_horizon_y: smooth the inclines listed in road_unk, set horizon_y2
;
; The three ((a + b + c) * 0x5555) >> 16 products are cumulative sums in
; the arithmetic unit (exact 40-bit sum: the int32 result fits int16, so
; it is MR+2).  The (x << 2) / d6 quotients use the hardware divider when
; x << 2 fits int16 (floor quotient, +1 for a negative dividend with a
; remainder = truncation), else SDivQ.
;============================================================================
hz_i  = or_i                ; road_unk byte offset
hz_a  = or_t0               ; d0
hz_d7 = or_t0+2
hz_d6 = or_t1
hz_t  = or_t1+2
hz_c  = or_t2               ; byte offset of road_y[p1 + d2]
hz_a2 = or_t2+2             ; byte offset of road_y[p1 + d5]
hz_y0 = or_inc              ; road_y[p1 + d0..d4]
hz_y1 = or_inc+2
hz_y2 = or_co
hz_y3 = or_co+2
hz_y4 = total_height
hz_l1 = total_height+2      ; (int16) d1l, d2l, d3l
hz_l2 = change_per_entry
hz_l3 = change_per_entry+2
hz_q0 = xs_scan             ; d0..d3 after the division
hz_q1 = xs_x
hz_q2 = xs_inc
hz_q3 = xs_cnt
hz_v  = or_sc               ; d5 in the write loops
hz_t2 = y_addr
hz_end = or_a1
hz_ri  = total_height+2      ; run * 2 (d1l is consumed by then)
hz_cnt = change_per_entry    ; (d2l is consumed by then)

; HZDIV: A = x (int16) -> A = (x << 2) / d6 (C++ int division, int16 result)
; with MCNT = 1.  Out of range: HzSlowS.
.macro HZDIV
.local fast, done
    clc
    adc #$2000
    cmp #$4000
    bcc fast
    jsr HzSlowS             ; (A = x + $2000)
    bra done
fast:
    sbc #$1FFF              ; (C = 0) x
    asl a
    asl a                   ; x << 2 (fits int16)
    sta MAL
    ldx z:hz_d6
    stx MBL                 ; signed / unsigned division (floor, remainder >= 0)
    cmp #$8000              ; C = negative dividend
    nop
    lda MR
    bcc done
    ldy MR+2
    beq done
    inc a                   ; truncation toward 0
done:
.endmacro

SetHorizonY:
    lda rd_dry
    beq :+
    jmp HzDone              ; (road_y already smoothed: horizon_y2 only)
:   ldx #0
HzNext:
    stx z:hz_i
    lda f:RDB*$10000+RD_UNK,x
    bne :+
    jmp HzDone
:   sta z:hz_a              ; d0
    ; d7 = d0 >> 3 ; d6 = (d7 + d0) - 0x1FF
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    sta z:hz_d7
    clc
    adc z:hz_a
    sec
    sbc #$01FF
    beq HzS1
    bmi HzS1
    ; d7 = ((d7 + d7) - d6) >> 1 ; d0 = 0x1FF - d7
    sta z:hz_t
    lda z:hz_d7
    asl a
    sec
    sbc z:hz_t
    cmp #$8000
    ror a
    sta z:hz_d7
    eor #$FFFF
    sec
    adc #$01FF
    sta z:hz_a
HzS1:
    ; d6 = d7 >> 1 ; if d6 <= 2 break
    lda z:hz_d7
    cmp #$8000
    ror a
    sta z:hz_d6
    bmi HzDone2
    cmp #3
    bcs :+
HzDone2:
    jmp HzDone
:   ; road_y[p1 + d] for d0 - d7, d0 - d6, d0, d0 + d6, d0 + d7
    ; (byte offsets p1 + 2 * d, 16-bit, as the element indices)
    asl a
    sta z:hz_t              ; 2 * d6
    lda z:hz_d7
    asl a
    sta z:hz_t2             ; 2 * d7
    lda z:hz_a
    asl a
    clc
    adc road_p1
    sta z:hz_c
    tax
    lda f:RDB*$10000+RD_Y,x
    sta z:hz_y2
    txa
    sec
    sbc z:hz_t2
    sta z:hz_a2             ; a2 = road_y_addr + d5 (d5 = d0 - d7)
    tax
    lda f:RDB*$10000+RD_Y,x
    sta z:hz_y0
    lda z:hz_c
    sec
    sbc z:hz_t
    tax
    lda f:RDB*$10000+RD_Y,x
    sta z:hz_y1
    lda z:hz_c
    clc
    adc z:hz_t
    tax
    lda f:RDB*$10000+RD_Y,x
    sta z:hz_y3
    lda z:hz_c
    clc
    adc z:hz_t2
    tax
    lda f:RDB*$10000+RD_Y,x
    sta z:hz_y4
    ; d2l = ((d2 + d0 + d4) * 0x5555) >> 16
    lda #2
    sta MCNT                ; cumulative sum, sum = 0
    lda #$5555
    sta MAL
    lda z:hz_y2
    sta MBL
    lda z:hz_y0
    sta MBL
    lda z:hz_y4
    sta MBL
    lda #$5502              ; (MCNT = 2: clear the sum; MAL = $55)
    nop
    ldx MR+2
    stx z:hz_l2
    ; d1l = ((d1 + d0 + (int16)d2l) * 0x5555) >> 16
    sta MCNT
    lda z:hz_y1
    sta MBL
    lda z:hz_y0
    sta MBL
    nop
    stx MBL
    lda #$5502
    nop
    ldy MR+2
    sty z:hz_l1
    ; d3l = ((d3 + d4 + (int16)d2l) * 0x5555) >> 16
    sta MCNT
    lda z:hz_y3
    sta MBL
    lda z:hz_y4
    sta MBL
    nop
    stx MBL
    lda #1                  ; (division mode below)
    nop
    ldy MR+2
    sty z:hz_l3
    sta MCNT
    ; d0 = ((int16)(d0 - (int16)d1l) << 2) / d6
    lda z:hz_y0
    sec
    sbc z:hz_l1
    HZDIV
    sta z:hz_q0
    ; d1 = ((d1l - (int16)d2l) << 2) / d6   (int32 difference)
    lda z:hz_l1
    sec
    sbc z:hz_l2
    bvc :+
    jsr HzSlowV
    bra :++
:   HZDIV
:   sta z:hz_q1
    ; d2 = ((d2l - (int16)d3l) << 2) / d6
    lda z:hz_l2
    sec
    sbc z:hz_l3
    bvc :+
    jsr HzSlowV
    bra :++
:   HZDIV
:   sta z:hz_q2
    ; d3 = ((d3l - d4) << 2) / d6
    lda z:hz_l3
    sec
    sbc z:hz_y4
    bvc :+
    jsr HzSlowV
    bra :++
:   HZDIV
:   sta z:hz_q3
    stz MCNT
    ; 4 x d6 entries from a2: road_y[a2++] = d5 >> 2 ; d5 -= d0..d3
    ; Cumulative sum: MR = d5 << 14, so MR+2 = d5 >> 2 as long as d5 fits
    ; int16; every entry adds d * -$4000 (Y = $C000).  After each run, MR
    ; = (d5 - d6 * d) << 14 must still be an int16 d5 (d5 is linear within
    ; the run, so then no entry wrapped), else HzSlowRuns.
    lda #2
    sta MCNT                ; cumulative sum, sum = 0
    lda z:hz_y0
    asl a
    asl a                   ; d5 <<= 2
    sta z:hz_v
    sta MAL
    lda #$4000
    sta MBL                 ; MR = d5 << 14
    ldx z:hz_a2
    stz z:hz_ri
HzRun:
    ldy z:hz_ri
    lda a:hz_q0,y           ; d0..d3
    sta MAL
    txa
    clc
    adc z:hz_t              ; + 2 * d6
    sta z:hz_end
    ; d6 (>= 3) entries, 4 per round, the first round entered at unit
    ; j0 = (-d6) & 3 with X - 2 * j0 (Duff; units of 10 bytes)
    lda z:hz_d6
    eor #$FFFF
    inc a
    and #3
    asl a
    sta z:hz_cnt            ; 2 * j0
    txa
    sec
    sbc z:hz_cnt
    tax
    lda z:hz_cnt
    asl a
    asl a
    adc z:hz_cnt            ; 10 * j0 (C = 0)
    adc #.loword(@u0 - 1)
    pha
    ldy #$C000
    rts
@u0:
    lda MR+2
    sty MBL
    sta f:RDB*$10000+RD_Y,x
    lda MR+2
    sty MBL
    sta f:RDB*$10000+RD_Y+2,x
    lda MR+2
    sty MBL
    sta f:RDB*$10000+RD_Y+4,x
    lda MR+2
    sty MBL
    sta f:RDB*$10000+RD_Y+6,x
    txa
    clc
    adc #8
    tax
    cpx z:hz_end
    bne @u0
    lda MR+3                ; bits 24-39: bits 29-39 must be equal
    clc
    adc #$0020
    cmp #$0040
    bcs HzSlowRuns
    lda z:hz_ri
    inc a
    inc a
    sta z:hz_ri
    cmp #8
    bcc HzRun
    stz MCNT
    ldx z:hz_i
    inx
    inx
    inx
    inx
    jmp HzNext
HzDone:
    ; horizon_y2 = -(road_y[road_p3] >> 4) + 224
    ldx road_p3
    lda f:RDB*$10000+RD_Y,x
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    eor #$FFFF
    sec
    adc #224
    sta horizon_y2
    rts

; HzSlowRuns: an int16 d5 wrapped in the write loops: redo them in software
HzSlowRuns:
    stz MCNT
    ldx z:hz_a2
    stz z:hz_ri
    lda z:hz_v              ; d5
@run:
    ldy z:hz_d6
    sty z:hz_cnt
@w: sta z:hz_v
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    sta f:RDB*$10000+RD_Y,x
    ldy z:hz_ri
    lda z:hz_v
    sec
    sbc a:hz_q0,y
    inx
    inx
    dec z:hz_cnt
    bne @w
    iny
    iny
    sty z:hz_ri
    cpy #8
    bcc @run
    ldx z:hz_i
    inx
    inx
    inx
    inx
    jmp HzNext

; HzSlowV: A = low word of an int32 difference that overflowed int16 (so
; the high word is 0 for a negative A, $FFFF for a positive one)
HzSlowV:
    ldx #0
    cmp #$8000
    bcs HzSlow
    dex
    bra HzSlow
; HzSlowS: A = x + $2000 (x int16)
HzSlowS:
    sec
    sbc #$2000
    ldx #0
    cmp #$8000
    bcc HzSlow
    dex
; HzSlow: X:A = int32 x -> A = (x << 2) / d6 (truncated, low 16 bits)
HzSlow:
    sta dvd
    stx dvd+2
    asl dvd
    rol dvd+2
    asl dvd
    rol dvd+2
    lda z:hz_d6
    jsr SDivQ
    lda dvd
    rts

;============================================================================
; do_road_data: per scanline road data + crest list
;
; road_y >> 4 comparisons are done on road_y & $FFF0 (same order and
; equality), signed compares as unsigned compares of the values ^ $8000.
; The scan has one copy per road_p1 value (0/$800/$1000/$1800), so the
; source/destination arrays are plain absolute,X/Y operands:
;   X = source index (see DRD_SCAN), Y = destination byte offset from
;   road_y[p1] (scanline = Y / 2 - $301), DB = $41.
; The scan reads 4 source entries per round; a round may read up to 3
; entries below rom_line_select 1 (never acted upon).
;============================================================================
dr_this = or_t0             ; src_this & $FFF0
dr_thx  = or_t0+2           ; dr_this ^ $8000
dr_wp   = or_t1             ; write_priority (0 / nonzero = -1)
dr_prio = or_t1+2           ; priority list pointer (bank $41 address)
dr_tmp  = or_t2
dr_sc   = or_t2+2
dr_p1   = or_i
dr_lim  = or_inc

DoRoadData:
    lda rd_dry
    beq :+
    rts                     ; (road_p1 already holds this data)
:   lda road_p1             ; 0, $800, $1000, $1800
    sta z:dr_p1
    tax
    xba
    lsr a
    lsr a
    tay
    phb
    pea RDB * 257
    plb
    plb
    ; src_this = road_y[p1 + $1FF] >> 4
    lda RD_Y+$1FF*2,x
    and #$FFF0
    sta z:dr_this
    eor #$8000
    sta z:dr_thx
    ; road_y[p1 + $3FF] = rom_line_select ($1FF)
    lda #$01FF
    sta RD_Y+$3FF*2,x
    txa
    clc
    adc #RD_Y+$280*2
    sta z:dr_prio
    stz z:dr_wp
    tyx
    ldy #$3FF*2             ; scanline 254
    jmp (DrdTab,x)
DrdTab:
    .addr Drd0, Drd1, Drd2, Drd3

; DRD_SCAN P1: the rom_line_select loop for road_p1 = P1
; X = 2 * r - 2 where r = rom_line_select of the first entry of the next
; round of 4 (entries r, r-1, r-2, r-3 at RD_Y+P1+2*r ...).
.macro DRD_SCAN P1
.local grp, ne0, ne1, ne2, ne3, neh, less, hill, hrun, endp, top1, top2
    ldx #$1FE*2-2           ; first round: r = $1FE
    ; ---- equal entries: 4 per round ----
grp:
    lda RD_Y+P1+2,x         ; r
    and #$FFF0
    cmp z:dr_this
    bne ne0
    lda RD_Y+P1,x           ; r - 1
    and #$FFF0
    cmp z:dr_this
    bne ne1
    lda RD_Y+P1-2,x         ; r - 2
    and #$FFF0
    cmp z:dr_this
    bne ne2
    lda RD_Y+P1-4,x         ; r - 3
    and #$FFF0
    cmp z:dr_this
    bne ne3
    txa
    sbc #8                  ; (C = 1: equal)
    tax
    bcs grp                 ; next round starts at r - 4 >= 1
    jmp DrdTop
    ; ---- a different entry: X = 2 * its rom_line_select (e) ----
ne0:
    inx
    inx
    bra neh
ne1:
    cpx #0
    bne neh
top1:
    jmp DrdTop              ; e = 0: past the end of the loop
ne3:
    dex
    dex
ne2:
    dex
    dex
    beq top1                ; e <= 0: past the end
    bmi top1
neh:
    eor #$8000
    cmp z:dr_thx
    bcc hill                ; src_next < src_this (signed)
less:
    ; src_this < src_next: next scanline (A = src_next ^ $8000, C = 1)
    sta z:dr_thx
    eor #$8000
    sta z:dr_this
    dey
    dey
    cpy #$301*2             ; --scanline <= 0: end
    beq endp
    txa
    lsr a                   ; rom_line_select (C = 0)
    sta RD_Y+P1,y
    sta z:dr_wp             ; write_priority = -1
    txa
    sbc #3                  ; (C = 0) X - 4: next round starts at e - 1
    tax
    bcs grp
top2:
    jmp DrdTop
hill:
    ; src_next < src_this: crest (priority) entry once after a scanline
    lda z:dr_wp
    beq hrun
    jsr DrdPrio
hrun:
    ; entries below src_this (single steps)
    dex
    dex
    beq top2                ; rom_line_select reached 0
    lda RD_Y+P1,x
    and #$FFF0
    eor #$8000
    cmp z:dr_thx
    bcc hrun
    bne less
    txa                     ; equal: back to rounds of 4 at e - 1
    sbc #4                  ; (C = 1)
    tax
    bcc top2
    jmp grp
endp:
    jmp DrdEndInv
.endmacro

Drd0: DRD_SCAN $0000
Drd1: DRD_SCAN $0800
Drd2: DRD_SCAN $1000
Drd3: DRD_SCAN $1800

; DrdPrio: priority entry (rom_line_select X / 2, src_this), write_priority = 0
DrdPrio:
    stz z:dr_wp
    txa
    lsr a
    sta (dr_prio)           ; road_y[addr_priority++] = rom_line_select
    lda z:dr_this
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    phy
    ldy #2
    sta (dr_prio),y         ; road_y[addr_priority++] = src_this
    ply
    lda z:dr_prio
    clc
    adc #4
    sta z:dr_prio
    rts

; DtCache: A = fill key (colour d7 | SOLID_FILL, or $FFFF: transparent) ->
; C set when road_p1's scanlines 0..dr_sc already hold this fill (the last
; fill of this buffer had the same scanline and key: only do_road_data
; writes there, and the road part stops above dr_sc); else the key is
; recorded (C clear).  A kept.  DB = $41.
DtCache:
    sta z:dr_tmp
    lda z:dr_p1
    xba
    lsr a
    tax                     ; 4 * buffer
    lda z:dr_sc
    cmp a:.loword(dt_key),x
    bne @miss
    lda z:dr_tmp
    cmp a:.loword(dt_key)+2,x
    bne @miss2
    sec
    rts
@miss:
    sta a:.loword(dt_key),x
    lda z:dr_tmp
@miss2:
    sta a:.loword(dt_key)+2,x
    clc
    rts

; DrdTop: rom_line_select reached 0: fill the scanlines above the road
; (Y = destination offset from road_y[p1])
DrdTop:
    tya
    lsr a
    sec
    sbc #$0301
    sta z:dr_sc             ; scanline (>= 1)
    tya
    clc
    adc z:dr_p1
    tay                     ; (Y from road_y[0] from here)
    lda z:dr_p1
    clc
    adc #$301*2
    sta z:dr_lim            ; Y of scanline 0
    ; src_next = road_y[p1 + 1] >> 4
    ldx z:dr_p1
    lda RD_Y+2,x
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    ; d7 = 255 - src_next - scanline
    clc
    adc z:dr_sc
    eor #$FFFF
    sec
    adc #255
    bmi @deflt
    cmp #$0040
    bcc :+
    lda #$FFFF              ; (fill key: all transparent)
    jsr DtCache
    bcs @hit
    jmp @transp
:   ora #SOLID_FILL
    bra @solid
@deflt:
    lda #SOLID_FILL
@solid:
    jsr DtCache
    bcc :+
@hit:
    jmp DrdEnd              ; road_p1 already holds this fill
:   ; colours d7, d7, d7+1, d7+1 .. TRANSPARENT: n = $840 - d7 pairs
    sta z:dr_tmp
    eor #$FFFF
    sec
    adc #TRANSPARENT+1
    asl a                   ; 2n
    cmp z:dr_sc
    beq :+
    bcs @case_b             ; scanline < 2n: runs out inside the pairs
:   lsr a
    tax                     ; n pairs, then TRANSPARENT to scanline 0
    lda z:dr_tmp
@pairs:
    sta RD_Y-2,y
    sta RD_Y-4,y
    inc a
    dey
    dey
    dey
    dey
    dex
    bne @pairs
@transp:
    ; TRANSPARENT down to road_y[p1 + $301] (scanline 0)
    cpy z:dr_lim
    beq DrdEnd
    tya
    sec
    sbc z:dr_lim
    and #2
    beq @tf1                ; even count
    lda #TRANSPARENT        ; odd count: one entry first
    sta RD_Y-2,y
    dey
    dey
    cpy z:dr_lim
    bne @tf2
    bra DrdEnd
@tf1:
    lda #TRANSPARENT
@tf2:
    sta RD_Y-2,y
    sta RD_Y-4,y
    dey
    dey
    dey
    dey
    cpy z:dr_lim
    bne @tf2
    bra DrdEnd
@case_b:
    ; scanline + 1 entries: (scanline + 1) / 2 pairs, and one more entry
    ; when scanline is even
    lda z:dr_sc
    inc a
    lsr a
    tax
    lda z:dr_tmp
@pairs_b:
    sta RD_Y-2,y
    sta RD_Y-4,y
    inc a
    dey
    dey
    dey
    dey
    dex
    bne @pairs_b
    lsr z:dr_sc
    bcs DrdEnd
    sta RD_Y-2,y
DrdEndInv:
    ; the road reached scanline 0: no fill above it in this buffer
    lda z:dr_p1
    xba
    lsr a
    tax
    lda #$FFFF
    sta a:.loword(dt_key),x
DrdEnd:
    ; end of the priority list
    lda #0
    sta (dr_prio)
    ldy #2
    sta (dr_prio),y
    plb
    rts

.segment "RODATA"
OrStageBase: .word 0, 1, 3, 6, 10
; blit_roads: road_ctrl 1..8 -> hardware road control
HwCtl: .word 0, 3, 1, 2, 1, 2, 0, 3

.include "roadkeys-test.inc"
