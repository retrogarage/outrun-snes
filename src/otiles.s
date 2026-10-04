; OTiles: arcade tilemap control (scenery FG / BG tile layers) - port of
; CannonBall DX engine/otiles.cpp (classic arcade behaviour), and the SNES
; backend that shows the arcade tile layers (docs/renderer.md).
;
; Arcade model: the stage FG layer (4 name-table pages) and BG layer (3
; pages) are copied into tile RAM bank A (pages 0-3 / 8-10) or bank B
; (pages 4-7 / 11-13); per layer the hardware shows a 1024x512 area of four
; pages chosen by the page-select register (fg_psel / bg_psel nibbles:
; top-left, top-right, bottom-left, bottom-right) with the h/v scroll
; registers.  The road chip covers the tile layers on road lines, so the
; SNES shows them on solid lines only (RoadRender switches BG1/BG2 to the
; scenery maps there): BG1 = FG layer, BG2 = BG layer.
;
; SNES backend (ScnRender, once per rendered frame): pages are resampled to
; 51 tiles (tools/mkscenery2.py); per layer the 33 visible columns of the
; 64x32 map must show the right (page, column); columns that changed are
; rebuilt through a VRAM tile cache (523 slots, reference counted by the
; map cells) and queued for the swap.  HOFS keeps a continuous position so
; page flips and scroll register wraps do not move the map columns.
.p816
.smart
.include "sa1.inc"
.include "shared.inc"
.include "globals.inc"
.include "gamevars.inc"
.include "road.inc"
.include "scenery2.inc"
.include "road2.inc"
.ifdef NEWGAME
.include "pages2.inc"
.import pal_rdirty
.endif

.import QueueUpload, RunLoad, FifoWait
.import sc_fgh, sc_fgv, sc_bgh, sc_bgv
.import SetupSkyChange, pal_manip_ctrl

.export OTilesInit, UpdateTilemaps, WriteTilemapHw, ResetTilesPal
.export SetVerticalSwap, FillTilemapColor, SetTileScroll, ScnRender, ScnPrime
.export ScnInvalidate, scn_page, scn_pmode
.export OtSlotGet, OtSlotPut, OtQuadGet, OtQuadPut, bank_sid   ; [W1c] (overhead structures: sprv3.s ohb.inc)
.export OtFreeHidden
.ifdef NEWGAME
.import OhbInvalidate
.endif
.export HorizonInit, HorizonStage, HorizonLoadNow, HorizonTick

TILEMAP_CLEAR  = 0
TILEMAP_SCROLL = 1
TILEMAP_INIT   = 2
TILEMAP_SPLIT  = 3
SETUP_TILES    = 0
SETUP_PAL      = 1
VSWAP_OFF        = 0
VSWAP_SCROLL_OFF = 1
VSWAP_SCROLL_ON  = 2

NSLOT    = 523              ; VRAM tile cache slots (tiles 245-767)
SLOT_T0  = 245              ; tile number of slot 0
VMAX_FG  = 3                ; map rows written per column (max layer height)
VMAX_BG  = 18
MAXT     = 1200             ; stage tiles tracked per bank
BUD_TILES = 128             ; per frame: new tiles (streamed through the upload FIFO)
CHG_MAX  = 6                ; changed columns per map screen sent as column uploads
                            ; (more: the screen's whole band from the shadow map)
COL_STG  = $405C80          ; column staging: 4 screens x CHG_MAX x 36 bytes (bank $40)
; shadow of the map bands (rows 32-vmax..31 of each 32x32 screen, VRAM
; layout), bank $40; a band must not cross an 8KB block (swap DMA window)
SHD_FG   = $406800          ; FG: 2 screens x 3 rows x 64 bytes
SHD_BG0  = $407200          ; BG screen 0: 18 rows x 64 bytes
SHD_BG1  = $407B00          ; BG screen 1
BULK_LIST = $404400         ; unused
KEY_NONE  = $FFFF           ; map column holds nothing known
KEY_BLANK = $FFFE           ; map column is blank

.segment "BSS"
; ---- arcade state (otiles) ----
tilemap_ctrl:     .res 2
tilemap_setup:    .res 2
vswap_state:      .res 2
vswap_off:        .res 2
ot_page:          .res 2
fg_h_scroll:      .res 2
bg_h_scroll:      .res 2
fg_v_scroll:      .res 2
bg_v_scroll:      .res 2
fg_psel:          .res 2
bg_psel:          .res 2
tilemap_v_scr:    .res 2
tilemap_h_scr:    .res 4
fg_v_tiles:       .res 2
bg_v_tiles:       .res 2
tilemap_v_off:    .res 2
h_scroll_lookup:  .res 2
clear_name_tables: .res 2
page_split:       .res 2
; hardware registers (write_tilemap_hw)
hw_hs:            .res 4    ; FG, BG
hw_vs:            .res 4
hw_psel:          .res 4
; tile RAM banks: stage held by bank A / B ($FF none)
bank_sid:         .res 4
bank_new:         .res 4    ; bank content changed: SNES side must drop it
bank_pal:         .res 4    ; bank palettes to upload
fill_on:          .res 2    ; page 15 filled (fill_tilemap_color)
; ---- SNES backend ----
sn_prev:          .res 4    ; previous SNES x offset per layer
sn_hacc:          .res 4    ; continuous HOFS per layer
sn_tiles:         .res 2    ; tile budget left this frame
sn_cols:          .res 2
sn_clk:           .res 2    ; clock hand for slot allocation
sn_prime:         .res 2    ; 1: last ScnRender completed every column
sn_L:             .res 2    ; layer*2
sn_k:             .res 2
sn_sxd:           .res 2
sn_qv:            .res 2    ; vertical quadrant (0 top, 2 bottom)*2... nibble shift base
sn_key:           .res 2
sn_mcol:          .res 2
sn_vmax:          .res 2
sn_bank:          .res 2
sn_pi:            .res 2
sn_v:             .res 2
sn_r:             .res 2
sn_stg:           .res 2    ; staging write offset
sn_t:             .res 2
sn_qh:            .res 2    ; [W1c] OtQuadGet search hand (slot)
sn_w:             .res 2
sn_cell:          .res 2
sn_slotw:         .res 2
sn_tmp:           .res 4
sn_frame:         .res 2    ; ScnRender count (slot release stamps)
scn_page:         .res 2    ; tile layers show: 0 the stage scenery, else a BG
                            ; page (pages2.inc: PG_MUSIC, PG_COURSEMAP)
scn_pmode:        .res 2    ; ... as shown now
pg_ovf:           .res 2    ; road tiles 1.. the shown page overwrote
sn_fail:          .res 2    ; ColBuild: a cell got no slot
sn_ci:            .res 2    ; ColBuild: map screen index*2 (layer*2 + screen)
sn_shp:           .res 2    ; ColBuild: shadow map pointer (bank $40)
chg_cnt:          .res 8    ; per map screen: columns changed this frame
chg_col:          .res 4*CHG_MAX*2   ; their columns (0-31), the first CHG_MAX

.segment "IRAMBSS"
; ScnLayer column loop
sl_b0:     .res 2               ; key base of the left / right half page
sl_b1:     .res 2
sl_v:      .res 2               ; virtual column (0-101)
sl_m:      .res 2               ; map column (0-63)
sl_cb:     .res 2               ; col_key offset of the layer
sl_n:      .res 2               ; columns left
sl_t:      .res 2

.segment "BWBSS": far
col_key:   .res 2*64*2          ; per layer, per map column
col_slot:  .res 64*VMAX_FG*2 + 64*VMAX_BG*2   ; per layer, column, row: slot+1 (0 none)
slot_ref:  .res NSLOT*2
slot_own:  .res NSLOT*2         ; bank<<15 | stage tile, $FFFF none
slot_rel:  .res NSLOT*2         ; sn_frame when the last reference went: the
                                ; displayed frame may still show the slot
tmap:      .res MAXT*2*2        ; per bank, stage tile -> slot+1

COLS_FG = 0                     ; col_slot offsets
COLS_BG = 64*VMAX_FG*2

.segment "RODATA"
TilesPageFg1: .word $FF10, $FF21, $FF32, $FF03, $FF54, $FF65, $FF76, $FF47
TilesPageBg1: .word $FF98, $FFA9, $FF8A, $FFCB, $FFDC, $FFBD
TilesPageFg2: .word $FF10, $FF21, $FF32, $FF43, $FF54, $FF65, $FF76, $FF07
TilesPageBg2: .word $FF98, $FFA9, $FFBA, $FFCB, $FFDC, $FF8D
; page -> bank (0 A, 1 B, $FF none) and page index (FG 0-3, BG 4-6)
PageBank:  .byte 0,0,0,0, 1,1,1,1, 0,0,0, 1,1,1, $FF,$FF
PageIdx:   .byte 0,1,2,3, 0,1,2,3, 4,5,6, 4,5,6, 0,0
LayerMap:  .word VR_FGMAP, VR_BGMAP
LayerVmax: .word VMAX_FG, VMAX_BG
LayerCols: .word COLS_FG, COLS_BG
; per map screen (layer*2 + screen): shadow band, column staging, chg_col
ShdBand:   .word .loword(SHD_FG), .loword(SHD_FG) + 3*64, .loword(SHD_BG0), .loword(SHD_BG1)
StgBase:   .word .loword(COL_STG), .loword(COL_STG) + CHG_MAX*36
           .word .loword(COL_STG) + 2*CHG_MAX*36, .loword(COL_STG) + 3*CHG_MAX*36
ChgBase:   .word 0, CHG_MAX*2, 2*CHG_MAX*2, 3*CHG_MAX*2

.segment "SA1CODE"
.a16
.i16

;============================================================================
; Arcade logic
;============================================================================

; otiles.init
OTilesInit:
    stz vswap_off
    stz vswap_state
    rts

; set_vertical_swap
SetVerticalSwap:
    stz vswap_off
    lda #VSWAP_SCROLL_OFF
    sta vswap_state
    rts

; write_tilemap_hw (vertical interrupt): scroll / page registers
WriteTilemapHw:
    lda fg_h_scroll
    and #$01FF
    sta hw_hs
    lda bg_h_scroll
    and #$01FF
    sta hw_hs+2
    lda fg_v_scroll
    and #$01FF
    sta hw_vs
    lda bg_v_scroll
    and #$01FF
    sta hw_vs+2
    lda fg_psel
    sta hw_psel
    lda bg_psel
    sta hw_psel+2
    rts

; reset_tiles_pal
ResetTilesPal:
    stz tilemap_ctrl
    lda end_stage_props
    and #$FFFE
    sta end_stage_props
    stz pal_manip_ctrl
    rts

; update_tilemaps: A = page (cur_stage)
UpdateTilemaps:
    sta ot_page
    lda tilemap_ctrl
    and #3
    asl a
    tax
    jmp (UtTab,x)
UtTab:
    .addr ClearTileInfo, ScrollTilemaps, InitNextTilemap, SplitTilemaps

; clear_tile_info: default tilemap for the current stage
ClearTileInfo:
    stz fg_h_scroll
    stz bg_h_scroll
    stz fg_v_scroll
    stz bg_v_scroll
    stz fg_psel
    stz bg_psel
    stz tilemap_v_scr
    stz tilemap_h_scr
    stz tilemap_h_scr+2
    stz fg_v_tiles
    stz bg_v_tiles
    stz tilemap_v_off
    ; text RAM tilemap registers
    stz hw_hs
    stz hw_hs+2
    stz hw_vs
    stz hw_vs+2
    stz hw_psel
    stz hw_psel+2
    ; tile RAM cleared
    ldx #0
    jsr BankSet
    ldx #2
    jsr BankSet
    stz fill_on
    lda f:TilesPageFg1
    sta fg_psel
    sta hw_psel
    lda f:TilesPageBg1
    sta bg_psel
    sta hw_psel+2
    lda stage_lookup_off
    ; fall into InitTilemap

; init_tilemap: A = stage id; loads it into bank A
InitTilemap:
    pha
    jsr InitTilemapProps
    lda horizon_y2
    sta horizon_y_bak
    lda #$68
    sec
    sbc tilemap_v_off
    sta fg_v_scroll
    sta bg_v_scroll
    ldx vswap_state
    bne :+
    and #$01FF
    sta hw_vs
    sta hw_vs+2
:   pla
    ldx #0                  ; copy_fg_tiles / copy_bg_tiles -> bank A
    jsr BankSetA
    lda #TILEMAP_SCROLL
    sta tilemap_ctrl
    rts

; init_tilemap_props: A = stage id -> fg/bg heights, v offset
InitTilemapProps:
    jsr DirPtr
    lda f:ScnDir,x
    and #$00FF
    sta fg_v_tiles
    lda f:ScnDir+1,x
    and #$00FF
    sta bg_v_tiles
    lda f:ScnDir+2,x
    sta tilemap_v_off
    rts

; DirPtr: A = stage id -> X = ScnDir offset
DirPtr:
    and #$003F
    asl a
    asl a
    asl a
    asl a
    asl a                   ; * SCN_DIRSZ (32)
    tax
    rts

; BankSetA: A = stage id, X = bank*2 (tile RAM bank now holds that stage)
BankSetA:
    sta bank_sid,x
    lda #1
    sta bank_new,x
    sta bank_pal,x
    rts
; BankSet: X = bank*2 -> cleared
BankSet:
    lda #$FF
    sta bank_sid,x
    lda #1
    sta bank_new,x
    rts

; scroll_tilemaps
ScrollTilemaps:
    ; the arcade scrolls in attract, best outrunners, in game and bonus
    lda game_state
    cmp #GS_BEST1
    beq @go
    cmp #GS_ATTRACT
    beq @go
    cmp #GS_INGAME
    beq @go
    cmp #GS_BONUS
    beq @go
    rts
@go:
    lda end_stage_props
    bit #$0008
    beq @nloop
    and #$FFF7
    sta end_stage_props
    ; loop_to_stage1
    lda #1
    sta pal_manip_ctrl
    lda #0
    jsr InitTilemap
    jmp SetupSkyChange
@nloop:
    bit #$0001
    beq @vs
    jsr SetupSkyChange
    lda #TILEMAP_INIT
    sta tilemap_ctrl
    stz tilemap_setup
@vs:
    ; continuous mode vertical swap
    lda game_state
    cmp #GS_BEST1
    beq @upd
    lda vswap_state
    cmp #VSWAP_SCROLL_OFF
    bne @von
    inc vswap_off
    lda vswap_off
    cmp #$41
    bcc @upd
    lda #VSWAP_SCROLL_ON
    sta vswap_state
    jsr ClearTileInfo
    bra @upd                ; (init_tilemap_palette: part of the stage data)
@von:
    cmp #VSWAP_SCROLL_ON
    bne @upd
    dec vswap_off
    bne @upd
    stz vswap_state
@upd:
    lda clear_name_tables
    beq :+
    jsr ClearOldNameTable
:   jsr HScrollTilemaps
    lda rd_split_state
    bne :+
    stz page_split
:   jsr UpdateFgPage
    jsr UpdateBgPage
    jmp VScrollTilemaps

; clear_old_name_table: the previous stage's bank
ClearOldNameTable:
    stz clear_name_tables
    ldx #0
    lda ot_page
    and #1
    beq :+
    ldx #2
:   jmp BankSet

; h_scroll_tilemaps: tilemap_h_scr moves 1/8 of the way to the target
HScrollTilemaps:
    lda end_stage_props
    bit #$0001
    beq @normal
    ; road splitting: target from H_SCROLL_TABLE[road_pos >> 16]
    lda road_pos+2
    and #$01FF
    asl a
    tax
    lda f:HScrollTab,x
    sta h_scroll_lookup
    bra @move
@normal:
    lda rd_split_state
    beq :+
    cmp #5
    bcs :+
    rts
:   lda tilemap_h_target
@move:
    sta sn_tmp              ; target
    ; x = ((target << 5) << 16) - (tilemap_h_scr << 5)   (32-bit)
    lda tilemap_h_scr
    sta sn_tmp+2
    lda tilemap_h_scr+2
    ldx #5
:   asl sn_tmp+2
    rol a
    dex
    bne :-
    sta sn_w                ; hi word of h_scr << 5
    lda sn_tmp
    asl a
    asl a
    asl a
    asl a
    asl a                   ; (target << 5) & $FFFF
    sec
    sbc sn_w
    sta sn_w                ; hi word of x
    lda #0
    sec
    sbc sn_tmp+2
    sta sn_t                ; lo word of x
    lda sn_w
    sbc #0
    sta sn_w
    ora sn_t
    bne :+
    rts                     ; x == 0: no change
:   ; x >>= 8 (arithmetic)
    lda sn_t
    xba
    and #$00FF
    sta sn_t
    lda sn_w
    xba
    pha
    and #$FF00
    ora sn_t
    sta sn_t                ; lo word of x >> 8
    pla
    and #$00FF
    bit #$0080
    beq :+
    ora #$FF00
:   sta sn_w                ; hi word
    ora sn_t
    bne @add
    ; x >> 8 == 0: snap to the target
    lda sn_tmp
    sta tilemap_h_scr+2
    rts
@add:
    lda tilemap_h_scr
    clc
    adc sn_t
    sta tilemap_h_scr
    lda tilemap_h_scr+2
    adc sn_w
    sta tilemap_h_scr+2
    rts

; v_scroll_tilemaps: smoothed horizon
VScrollTilemaps:
    lda horizon_y_bak
    clc
    adc horizon_y2
    cmp #$8000
    ror a
    sta horizon_y_bak
    lda #$0100
    sec
    sbc horizon_y_bak
    sec
    sbc tilemap_v_off
    sec
    sbc vswap_off
    sta tilemap_v_scr
    sta fg_v_scroll
    sta bg_v_scroll
    bpl :+
    lda fg_psel
    xba
    sta fg_psel
    lda bg_psel
    xba
    sta bg_psel
:   rts

; update_fg_page / update_bg_page
UpdateFgPage:
    lda tilemap_h_scr+2
    ldx rd_split_state
    bne :+
    eor #$FFFF
    inc a
:   sta fg_h_scroll
    xba
    lsr a
    and #3                  ; bits 9-10
    asl a
    sta sn_t
    jsr CurPage
    asl a
    asl a
    asl a                   ; * 8
    clc
    adc sn_t
    tax
    lda f:TilesPageFg1,x
    sta fg_psel
    rts

UpdateBgPage:
    lda tilemap_h_scr+2
    ldx rd_split_state
    bne :+
    eor #$FFFF
    inc a
:   and #$07FF
    sta sn_t
    asl a
    clc
    adc sn_t
    lsr a
    lsr a
    sta bg_h_scroll
    xba
    lsr a
    and #3
    asl a
    sta sn_t
    jsr CurPage
    sta sn_w
    asl a
    clc
    adc sn_w                ; * 3
    asl a                   ; * 6
    clc
    adc sn_t
    tax
    lda f:TilesPageBg1,x
    sta bg_psel
    rts

; CurPage: A = (page_split ? page + 1 : page) & 1
CurPage:
    lda ot_page
    ldx page_split
    beq :+
    inc a
:   and #1
    rts

; init_next_tilemap (on level switch)
InitNextTilemap:
    stz h_scroll_lookup
    stz clear_name_tables
    stz page_split
    lda #1
    sta pal_manip_ctrl
    lda tilemap_setup
    and #1
    bne @pal
    ; SETUP_TILES: next stage into the other bank
    lda stage_lookup_off
    clc
    adc #8
    pha
    jsr InitTilemapProps
    pla
    ldx #2
    ldy ot_page
    tya
    and #1
    beq :+
    ldx #0
:   lda stage_lookup_off
    clc
    adc #8
    jsr BankSetA
    stz bank_pal,x          ; palettes follow at SETUP_PAL
    lda #SETUP_PAL
    sta tilemap_setup
    rts
@pal:
    ; SETUP_PAL (init_tilemap_palette): upload the new bank's palettes
    ldx #2
    lda ot_page
    and #1
    beq :+
    ldx #0
:   lda #1
    sta bank_pal,x
    lda #TILEMAP_SPLIT
    sta tilemap_ctrl
    rts

; split_tilemaps: both tilemaps scroll during the road split
SplitTilemaps:
    lda rd_split_state
    cmp #6
    bcs @merge
    jsr HScrollTilemaps
    ; update_fg_page_split
    lda tilemap_h_scr+2
    sta fg_h_scroll
    ldx #3*2
    lda ot_page
    and #1
    bne :+
    ldx #7*2
:   lda f:TilesPageFg2,x
    sta fg_psel
    ; update_bg_page_split
    lda tilemap_h_scr+2
    and #$0FFF
    sta sn_t
    asl a
    clc
    adc sn_t
    lsr a
    lsr a
    sta bg_h_scroll
    ldx #2*2
    lda ot_page
    and #1
    bne :+
    ldx #5*2
:   lda f:TilesPageBg2,x
    sta bg_psel
    jmp VScrollTilemaps
@merge:
    lda #TILEMAP_SCROLL
    sta tilemap_ctrl
    lda #1
    sta page_split
    lda end_stage_props
    and #$FFFE
    sta end_stage_props
    stz h_scroll_lookup
    lda #1
    sta clear_name_tables
    rts

; fill_tilemap_color: A = colour (0 black); page 15 filled, scroll reset
FillTilemapColor:
    sta fill_on
    lda #0
    ; fall into SetTileScroll (h = v = 0)
; set_scroll: A = v scroll (h = 0); pages off
SetTileScroll:
    pha
    lda #TILEMAP_SCROLL
    sta tilemap_ctrl
    stz fg_h_scroll
    stz bg_h_scroll
    pla
    sta fg_v_scroll
    sta bg_v_scroll
    lda #$FFFF
    sta fg_psel
    sta bg_psel
    rts

;============================================================================
; Previous interface (game flow): the tilemaps now follow the arcade logic
;============================================================================
HorizonInit:
    jsr OTilesInit
    jmp ResetTilesPal
HorizonStage:
HorizonTick:
    rts
HorizonLoadNow:
    rts

;============================================================================
; SNES backend
;============================================================================

; ScnInvalidate: forget the VRAM maps / tile cache (after a bulk load)
ScnInvalidate:
    ldx #0
    lda #KEY_NONE
:   sta f:col_key,x
    inx
    inx
    cpx #2*64*2
    bne :-
    ldx #0
    lda #0
:   sta f:col_slot,x
    inx
    inx
    cpx #64*VMAX_FG*2 + 64*VMAX_BG*2
    bne :-
    ldx #0
:   lda #0
    sta f:slot_ref,x
    lda #$FFFF
    sta f:slot_own,x
    sta f:slot_rel,x
    inx
    inx
    cpx #NSLOT*2
    bne :-
    ; shadow maps blank, every screen's band uploaded by the next ScnRender
    ldx #0
    lda #0
:   sta f:SHD_FG,x
    inx
    inx
    cpx #2*VMAX_FG*64
    bne :-
    ldx #0
:   sta f:SHD_BG0,x
    sta f:SHD_BG1,x
    inx
    inx
    cpx #VMAX_BG*64
    bne :-
    lda #CHG_MAX+1
    sta chg_cnt
    sta chg_cnt+2
    sta chg_cnt+4
    sta chg_cnt+6
    ldx #0
    lda #0
:   sta f:tmap,x
    inx
    inx
    cpx #MAXT*2*2
    bne :-
    stz sn_clk
    lda #$FFFF
    sta sn_prev
    sta sn_prev+2
    lda #1
    sta bank_pal
    sta bank_pal+2
    stz bank_new
    stz bank_new+2
    .ifdef NEWGAME
    jmp OhbInvalidate       ; [W1c] (its slots and map rows are gone too)
    .else
    rts
    .endif

; ScnPrime: build the visible scenery completely (screen blank): render
; and swap frames until a frame needed no deferred work
ScnPrime:
:   jsr ScnRender
    jsr FrameReady
    jsr WaitSwap
    lda sn_prime
    beq :-
    rts

;----------------------------------------------------------------------------
; ScnRender: per rendered frame
;----------------------------------------------------------------------------
ScnRender:
    lda #1
    sta sn_prime            ; cleared when work is deferred
    inc sn_frame
    lda #BUD_TILES
    sta sn_tiles
    .ifdef NEWGAME
    ; music select page: the tile slots and the FG map hold it instead of
    ; the stage scenery
    lda scn_page
    cmp scn_pmode
    beq @pm
    lda scn_pmode
    beq :+
    jsr PageClear           ; the page goes: map rows, road tiles / colours
:   lda scn_page
    sta scn_pmode
    jsr ScnInvalidate       ; (every cached column / tile dropped)
    lda scn_pmode
    beq @pm
    jsr PageLoad
@pm:
    lda scn_pmode
    beq @stage
    stz sc_fgh              ; the page at scroll 0 (row 0 on line 0), BG2 blank
    stz sc_bgh
    lda #$00FF
    sta sc_fgv
    sta sc_bgv
    jmp ScnFlush
@stage:
    .endif
    ; bank changes: drop their columns and cache entries
    ldx #0
    jsr BankDrop
    ldx #2
    jsr BankDrop
    ; bank palettes
    ldx #0
    jsr BankPalette
    ldx #2
    jsr BankPalette
    ; layers: FG -> BG1, BG -> BG2
    stz sn_L
    jsr ScnLayer
    lda #2
    sta sn_L
    jsr ScnLayer
    jmp ScnFlush

; BankDrop: X = bank*2
BankDrop:
    lda bank_new,x
    bne :+
    rts
:   stz bank_new,x
    stx sn_bank
    ; release every map column that shows a page of this bank
    stz sn_L
@lay:
    stz sn_mcol
@col:
    lda sn_L
    xba
    lsr a
    lsr a                   ; layer*2 * 64
    clc
    adc sn_mcol
    adc sn_mcol
    tax
    lda f:col_key,x
    cmp #KEY_BLANK
    bcs @next
    asl a
    asl a
    xba                     ; key >> 6 = page
    and #$000F
    tax
    lda f:PageBank,x
    and #$00FF
    asl a
    cmp sn_bank
    bne @next
    jsr ColRelease
@next:
    inc sn_mcol
    lda sn_mcol
    cmp #64
    bcc @col
    lda sn_L
    bne :+
    lda #2
    sta sn_L
    bra @lay
:   ; forget the bank's cached tiles
    ldx #0
@sl:
    lda f:slot_own,x
    cmp #$FFFF
    beq @sn
    asl a                   ; carry = bank bit (bank<<15)
    lda #0
    rol a
    asl a
    cmp sn_bank
    bne @sn
    lda #$FFFF
    sta f:slot_own,x
@sn:
    inx
    inx
    cpx #NSLOT*2
    bne @sl
    lda sn_bank
    beq :+
    lda #MAXT*2
:   tax
    ldy #MAXT
    lda #0
:   sta f:tmap,x
    inx
    inx
    dey
    bne :-
    rts

; ColRelease: sn_L, sn_mcol -> release the column's slots, key = NONE
ColRelease:
    jsr ColSlotPtr          ; X = col_slot offset, sn_vmax
    ldy sn_vmax
@r: lda f:col_slot,x
    beq :+
    dec a
    phx
    asl a
    tax
    lda f:slot_ref,x
    dec a
    sta f:slot_ref,x
    bne @rn
    lda sn_frame            ; unreferenced now, maybe still displayed
    sta f:slot_rel,x
@rn:
    plx
    lda #0
    sta f:col_slot,x
:   inx
    inx
    dey
    bne @r
    lda sn_L
    xba
    lsr a
    lsr a
    clc
    adc sn_mcol
    adc sn_mcol
    tax
    lda #KEY_NONE
    sta f:col_key,x
    rts

; ColSlotPtr: sn_L, sn_mcol -> X = offset of the column's slots in col_slot,
; sn_vmax = rows
ColSlotPtr:
    ldx sn_L
    lda f:LayerVmax,x
    sta sn_vmax
    lda sn_mcol
    asl a
    ldy sn_vmax
    cpy #VMAX_FG
    beq :+
    ; BG: mcol * 18 * 2 = mcol*36
    sta sn_t
    asl a
    asl a
    asl a
    asl a                   ; *32 (mcol*2*16)
    clc
    adc sn_t                ; *34
    adc sn_t                ; *36
    bra :++
:   ; FG: mcol * 3 * 2 = mcol*6
    sta sn_t
    asl a
    clc
    adc sn_t                ; *6
:   clc
    adc f:LayerCols,x
    tax
    rts

; BankPalette: X = bank*2 -> queue its two palettes when pending
BankPalette:
    lda bank_pal,x
    bne :+
    rts
:   stz bank_pal,x
    stx sn_bank
    lda bank_sid,x
    and #$00FF
    cmp #$00FF
    bne :+
    rts
:   jsr DirPtr
    lda f:ScnDir+8,x
    sta ptr0
    sep #$20
    .a8
    lda f:ScnDir+10,x
    sta ptr0+2
    rep #$20
    .a16
    lda sn_bank             ; CGRAM (2 + 2*bank) * 16
    asl a
    asl a
    asl a
    asl a
    clc
    adc #32
    tax
    ldy #64
    lda #BL_CGRAM
    jmp QueueUpload

;----------------------------------------------------------------------------
; ScnLayer: sn_L = layer*2
;----------------------------------------------------------------------------
ScnLayer:
    ldx sn_L
    ; SNES x offset: xdec = (192 - hs) & $3FF -> slot*408 + (px*51) >> 6
    lda #192
    sec
    sbc hw_hs,x
    and #$03FF
    pha
    and #$01FF
    sta MAL
    lda #51
    sta MBL
    nop
    lda MR
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    sta sn_sxd
    pla
    cmp #$0200
    bcc :+
    lda sn_sxd
    clc
    adc #408
    sta sn_sxd
:   ; continuous HOFS (congruent to sxd mod 8; the first frame takes sxd)
    lda sn_prev,x
    cmp #$FFFF
    bne :+
    lda sn_sxd
    sta sn_prev,x
    and #$01FF
    sta sn_hacc,x
:   lda sn_sxd
    sec
    sbc sn_prev,x
    cmp #408
    bmi :+
    sec
    sbc #816
    bra :++
:   cmp #$10000-408
    bpl :+
    clc
    adc #816
:   clc
    adc sn_hacc,x
    and #$01FF
    sta sn_hacc,x
    lda sn_sxd
    sta sn_prev,x
    ; scroll registers for RoadRender
    lda sn_hacc,x
    ldy sn_L
    bne :+
    sta sc_fgh
    bra :++
:   sta sc_bgh
:   lda hw_vs,x
    dec a                   ; the PPU shows BG row VOFS + 1 on line 0
    and #$00FF
    ldy sn_L
    bne :+
    sta sc_fgv
    bra :++
:   sta sc_bgv
:   ; vertical quadrant holding the visible scenery rows: bottom when the
    ; bottom band [512 - 8*vmax, 512) is on screen
    lda f:LayerVmax,x
    sta sn_vmax
    asl a
    asl a
    asl a
    eor #$FFFF
    inc a
    clc
    adc #512                ; band start
    sec
    sbc hw_vs,x
    and #$01FF
    cmp #224
    bcc @bot
    ; band end
    lda #511
    sec
    sbc hw_vs,x
    and #$01FF
    cmp #224
    bcc @bot
    stz sn_qv
    bra @cols
@bot:
    lda #8                  ; nibble shift for the bottom half
    sta sn_qv
@cols:
    ; the pages of the left / right half of the 102 virtual columns (for
    ; this vertical quadrant): key bases (page << 6) or KEY_BLANK
    lda sn_qv
    jsr SlPage
    sta sl_b0
    lda sn_qv
    clc
    adc #4                  ; right half: nibble shift +4
    jsr SlPage
    sta sl_b1
    ; column k = 0: virtual column (sxd >> 3), map column (hacc >> 3) & 63
    lda sn_sxd
    lsr a
    lsr a
    lsr a
    sta sl_v
    ldx sn_L
    lda sn_hacc,x
    lsr a
    lsr a
    lsr a
    and #63
    sta sl_m
    lda sn_L
    xba
    lsr a
    lsr a
    sta sl_cb               ; col_key offset of the layer (layer*2 * 64)
    lda #33
    sta sl_n
@kl:
    ; key = page << 6 | page column (blank: the page shows nothing here)
    lda sl_v
    cmp #51
    bcs @rh
    sta sl_t
    lda sl_b0
    bra @ky
@rh:
    sbc #51
    sta sl_t
    lda sl_b1
@ky:
    cmp #KEY_BLANK
    beq :+
    ora sl_t
:   sta sn_key
    lda sl_m
    sta sn_mcol
    asl a
    adc sl_cb               ; (C clear)
    tax
    lda f:col_key,x
    cmp sn_key
    beq @knext
    ; rebuild: cells whose tile is neither cached nor within this frame's
    ; budget stay blank (never stale) and the column is redone next frame
    jsr ColBuild
    bcc @knext
    stz sn_prime            ; not complete this frame
@knext:
    ; next column: virtual (mod 102), map (mod 64)
    lda sl_v
    inc a
    cmp #102
    bcc :+
    lda #0
:   sta sl_v
    lda sl_m
    inc a
    and #63
    sta sl_m
    dec sl_n
    bne @kl
@done:
    rts

; SlPage: A = nibble shift of the page select (sn_L's hw_psel) -> A = key
; base (page << 6) of that page, KEY_BLANK when it shows nothing for layer sn_L
SlPage:
    tay
    ldx sn_L
    lda hw_psel,x
:   cpy #0
    beq :+
    lsr a
    dey
    bra :-
:   and #$000F              ; page
    tax
    lda f:PageBank,x
    and #$00FF
    cmp #$00FF
    beq @blank
    asl a
    tay
    lda bank_sid,y
    and #$00FF
    cmp #$00FF
    beq @blank
    ; the page must belong to this layer (FG pages 0-7, BG 8-13)
    lda f:PageIdx,x
    and #$00FF
    cmp #4
    lda #0
    rol a                   ; 1 = BG page
    asl a
    cmp sn_L
    bne @blank
    txa
    xba
    lsr a
    lsr a                   ; page << 6
    rts
@blank:
    lda #KEY_BLANK
    rts

;----------------------------------------------------------------------------
.ifdef NEWGAME
; PageLoad: page scn_pmode (PgDesc, tools/mkpages2.py): tiles streamed to
; the scenery slots and road tiles 1.. beyond them (the swap waits for the
; FIFO), map rows 0-27 of FG map screen 0 and palettes 2.. queued for the
; swap.  PageClear: the map rows cleared, overwritten road tiles restored,
; road colours re-sent.
;----------------------------------------------------------------------------
PageLoad:
    stz SH_BRIGHT           ; black until the page's frame is swapped in (the
                            ; tiles overwrite what the screen shows now)
    lda scn_pmode
    dec a
    sta sn_t
    asl a
    asl a
    clc
    adc sn_t
    asl a                   ; * PG_DESCSZ (10)
    tax
    stx sn_w                ; descriptor offset
    lda f:PgDesc,x
    sta sn_tmp              ; tiles address
    lda f:PgDesc+2,x
    and #$00FF
    sta sn_bank             ; (bank)
    lda f:PgDesc+4,x
    sta sn_v                ; tile count
    ; tiles 1-523 -> slots, 524.. -> road tiles 1..
    stz pg_ovf
    cmp #NSLOT+1
    bcc :+
    sec
    sbc #NSLOT
    sta pg_ovf
    lda #NSLOT
:   asl a
    asl a
    asl a
    asl a
    asl a                   ; bytes
    sta sn_r
    lda #VR_SCNT
    sta sn_k
    stz sn_cell             ; source offset
    jsr PageStream
    lda pg_ovf
    beq @map
    asl a
    asl a
    asl a
    asl a
    asl a
    clc
    adc sn_cell
    sta sn_r
    lda #VR_ROADT+16        ; tile 1
    sta sn_k
    jsr PageStream
@map:
    ldx sn_w
    lda f:PgDesc+6,x
    sta ptr0
    sep #$20
    .a8
    lda sn_bank
    sta ptr0+2
    rep #$20
    .a16
    ldx #VR_FGMAP
    ldy #28*64
    lda #0                  ; VRAM
    jsr QueueUpload
    ldx sn_w
    lda f:PgDesc+8,x
    sta ptr0
    lda f:PgDesc+3,x        ; palettes
    and #$00FF
    xba
    lsr a
    lsr a
    lsr a                   ; * 32 bytes
    tay
    ldx #32                 ; CGRAM palettes 2..
    lda #BL_CGRAM
    jmp QueueUpload

; PageStream: source sn_tmp + sn_cell (bank sn_bank) up to offset sn_r ->
; VRAM word sn_k.. (FIFO, 512-byte entries); sn_cell advanced
PageStream:
@t: lda sn_cell
    cmp sn_r
    bcs @d
    jsr FifoWait
    lda SH_UQW
    asl a
    asl a
    asl a
    tax
    lda sn_k
    sta f:UQ_BUF+UQ_DEST,x
    lda sn_tmp
    clc
    adc sn_cell
    sta f:UQ_BUF+UQ_SRC,x
    lda sn_bank             ; bank; BMAPS byte 0 (unused for ROM)
    sta f:UQ_BUF+UQ_BANK,x
    lda sn_r
    sec
    sbc sn_cell
    cmp #512
    bcc :+
    lda #512
:   sta f:UQ_BUF+UQ_SIZE,x
    lsr a
    clc
    adc sn_k
    sta sn_k
    lda f:UQ_BUF+UQ_SIZE,x
    clc
    adc sn_cell
    sta sn_cell
    lda SH_UQW
    inc a
    and #UQ_MASK
    sta SH_UQW
    bra @t
@d: rts

PageClear:
    stz SH_BRIGHT           ; black until the next frame (tiles restored)
    lda #.loword(PgZero)
    sta ptr0
    sep #$20
    .a8
    lda #^PgZero
    sta ptr0+2
    rep #$20
    .a16
    ldx #VR_FGMAP
    ldy #29*64              ; rows 0-28 (29-31: the FG band, from the shadow)
    lda #0
    jsr QueueUpload
    lda #1
    sta pal_rdirty          ; road colours (palettes 6 / 7) re-sent
    lda pg_ovf
    beq @d
    asl a
    asl a
    asl a
    asl a
    asl a
    sta sn_r                ; RoadTiles tile 1.. -> VRAM tile 1..
    lda #.loword(RoadTiles) + 32
    sta sn_tmp
    lda #^RoadTiles
    sta sn_bank
    lda #VR_ROADT+16
    sta sn_k
    stz sn_cell
    jsr PageStream
    stz pg_ovf
@d: rts
.endif

;----------------------------------------------------------------------------
; ColBuild: map column sn_mcol of layer sn_L := content sn_key, written to
; the shadow map (and the column staging while its screen has at most
; CHG_MAX changes; ScnFlush uploads).  C set when a cell got no tile slot:
; the cell stays blank and the column key is KEY_NONE (redone next frame).
;----------------------------------------------------------------------------
ColBuild:
    jsr ColRelease
    jsr ColSlotPtr          ; X = slot list, sn_vmax
    stx sn_slotw
    stz sn_fail
    ; map screen: layer*2 + (mcol >= 32)
    lda sn_L
    asl a
    sta sn_ci
    lda sn_mcol
    and #32
    beq :+
    lda #2
    tsb sn_ci
:   ldx sn_ci
    lda sn_mcol
    and #31
    asl a
    clc
    adc f:ShdBand,x
    sta sn_shp
    ; column staging for the first CHG_MAX changes of the screen
    lda chg_cnt,x
    cmp #CHG_MAX
    bcs @nostg
    asl a
    asl a
    sta sn_t                ; cnt*4
    asl a
    asl a
    asl a                   ; cnt*32
    clc
    adc sn_t                ; cnt*36
    adc f:StgBase,x
    sta sn_stg
    lda chg_cnt,x
    asl a
    clc
    adc f:ChgBase,x
    tay
    lda sn_mcol
    and #31
    sta chg_col,y
    bra @cnt
@nostg:
    lda #$FFFF
    sta sn_stg
@cnt:
    inc chg_cnt,x
    lda sn_key
    cmp #KEY_BLANK
    bcc @data
    ; blank column
    stz sn_r
:   lda #0
    jsr ColPut
    inc sn_r
    lda sn_r
    cmp sn_vmax
    bcc :-
    jmp @key
@data:
    ; page (key >> 6), bank, stage, rows, map pointer
    asl a
    asl a
    xba
    and #$000F
    tax
    lda f:PageIdx,x
    and #$00FF
    sta sn_pi
    lda f:PageBank,x
    and #$00FF
    asl a
    sta sn_bank
    tax
    lda bank_sid,x
    jsr DirPtr
    ldy sn_pi
    cpy #4
    bcs :+
    lda f:ScnDir,x          ; fg_v_tiles
    bra :++
:   lda f:ScnDir+1,x
:   and #$00FF
    sta sn_v
    ; map pointer = page map + pcol * v * 2
    lda sn_pi
    asl a
    clc
    adc sn_pi               ; *3
    sta sn_t
    txa
    clc
    adc sn_t
    tax
    lda f:ScnDir+11,x
    sta ptr1
    sep #$20
    .a8
    lda f:ScnDir+13,x
    sta ptr1+2
    rep #$20
    .a16
    lda sn_key
    and #$003F
    sta MAL
    lda sn_v
    asl a
    sta MBL
    nop
    lda MR
    clc
    adc ptr1
    sta ptr1
    ; rows: r = 0..vmax-1, data row = r - (vmax - v)
    stz sn_r
@row:
    lda sn_r
    clc
    adc sn_v
    sec
    sbc sn_vmax
    bmi @zero
    asl a
    tay
    lda [ptr1],y
    sta sn_cell
    and #$1FFF
    beq @zero
    jsr CacheGet            ; A = stage tile -> A = slot, C set: no slot
    bcs @noslot
    pha
    ; col_slot entry
    ldx sn_slotw
    inc a
    sta f:col_slot,x
    pla
    clc
    adc #SLOT_T0
    sta sn_w
    lda sn_cell
    and #$2000              ; palette select
    xba
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a                   ; 0 / 1
    clc
    adc sn_bank             ; + 2*bank
    adc #2
    xba
    asl a
    asl a                   ; << 10
    ora sn_w
    sta sn_w
    lda sn_cell
    and #$C000
    ora sn_w
    bra @put
@noslot:
    inc sn_fail
@zero:
    lda #0
@put:
    jsr ColPut
    lda sn_slotw
    inc a
    inc a
    sta sn_slotw
    inc sn_r
    lda sn_r
    cmp sn_vmax
    bcc @row
@key:
    lda sn_L
    xba
    lsr a
    lsr a
    clc
    adc sn_mcol
    adc sn_mcol
    tax
    lda sn_key
    ldy sn_fail
    beq :+
    lda #KEY_NONE
:   sta f:col_key,x
    lda sn_fail
    cmp #1                  ; C = a cell got no slot
    rts

; ColPut: A = map word of row sn_r -> shadow (and column staging)
ColPut:
    ldx sn_shp
    sta f:$400000,x
    ldx sn_stg
    bmi :+
    sta f:$400000,x
    inx
    inx
    stx sn_stg
:   lda sn_shp
    clc
    adc #64
    sta sn_shp
    rts

;----------------------------------------------------------------------------
; ScnFlush: upload the changed map columns of each screen (as columns, or
; the whole band from the shadow when more than CHG_MAX changed)
;----------------------------------------------------------------------------
ScnFlush:
    ldx #0
@scr:
    stx sn_ci
    lda chg_cnt,x
    bne :+
    jmp @next
:   sta sn_r
    ; band VRAM address: layer map + screen * $400 + (32 - vmax) * 32
    txa
    and #4
    lsr a
    tax                     ; layer*2
    lda f:LayerVmax,x
    sta sn_vmax
    lda #32
    sec
    sbc sn_vmax
    asl a
    asl a
    asl a
    asl a
    asl a
    clc
    adc f:LayerMap,x
    sta sn_t
    ldx sn_ci
    txa
    and #2
    beq :+
    lda #$0400
    clc
    adc sn_t
    sta sn_t
:   lda sn_r
    cmp #CHG_MAX+1
    bcs @band
    ; columns
    lda f:StgBase,x
    sta sn_stg
    lda f:ChgBase,x
    sta sn_k
@col:
    ldx sn_k
    lda chg_col,x
    clc
    adc sn_t
    tax                     ; VRAM column
    lda sn_stg
    sta ptr0
    sep #$20
    .a8
    lda #^COL_STG
    sta ptr0+2
    rep #$20
    .a16
    lda sn_vmax
    asl a
    tay
    lda #4                  ; VRAM column (increment 32)
    jsr QueueUpload
    lda sn_stg
    clc
    adc #36
    sta sn_stg
    inc sn_k
    inc sn_k
    dec sn_r
    bne @col
    bra @done
@band:
    lda f:ShdBand,x
    sta ptr0
    sep #$20
    .a8
    lda #$40
    sta ptr0+2
    rep #$20
    .a16
    lda sn_vmax
    xba
    lsr a
    lsr a                   ; vmax * 64 bytes
    tay
    ldx sn_t
    lda #0                  ; VRAM, increment 1
    jsr QueueUpload
@done:
    ldx sn_ci
@next:
    stz chg_cnt,x
    inx
    inx
    cpx #8
    bcs :+
    jmp @scr
:   rts

;----------------------------------------------------------------------------
; CacheGet: A = stage tile (bank sn_bank) -> A = slot (reference taken);
; C set when no slot is free
;----------------------------------------------------------------------------
CacheGet:
    sta sn_t
    asl a
    ldx sn_bank
    beq :+
    clc
    adc #MAXT*2
:   tax
    stx sn_tmp              ; tmap offset
    lda f:tmap,x
    beq @miss
    dec a
    pha
    asl a
    tax
    lda f:slot_ref,x
    inc a
    sta f:slot_ref,x
    pla
    clc
    rts
@miss:
    lda sn_tiles
    bne :+
    sec
    rts
:   jsr AllocSlot
    bcc :++
    ; every slot is referenced: drop the map columns out of view, retry
    jsr EvictHidden
    jsr AllocSlot
    bcc :+
    rts
:
:   sta sn_tmp+2            ; slot
    ldx sn_tmp
    inc a
    sta f:tmap,x
    lda sn_tmp+2
    asl a
    tax
    lda #1
    sta f:slot_ref,x
    lda sn_bank
    beq :+
    lda #$8000
:   ora sn_t
    sta f:slot_own,x
    ; stream the tile: ROM (global tile tbase + t) -> VRAM slot through the
    ; upload FIFO (the slot is not on the displayed frame: see AllocSlot)
    ldx sn_bank
    lda bank_sid,x
    jsr DirPtr
    lda f:ScnDir+4,x        ; first global tile
    clc
    adc sn_t
    sta sn_w                ; global tile
    jsr FifoWait
    lda SH_UQW
    asl a
    asl a
    asl a
    tax
    lda sn_tmp+2
    asl a
    asl a
    asl a
    asl a
    clc
    adc #VR_SCNT
    sta f:UQ_BUF+UQ_DEST,x
    lda sn_w
    and #$03FF
    asl a
    asl a
    asl a
    asl a
    asl a                   ; *32
    ora #$8000
    sta f:UQ_BUF+UQ_SRC,x
    lda sn_w
    xba
    lsr a
    lsr a                   ; >> 10
    and #$003F
    clc
    adc #SCN_TBANK          ; bank; BMAPS byte 0 (unused for ROM)
    sta f:UQ_BUF+UQ_BANK,x
    lda #32
    sta f:UQ_BUF+UQ_SIZE,x
    lda SH_UQW
    inc a
    and #UQ_MASK
    sta SH_UQW
    dec sn_tiles
    lda sn_tmp+2
    clc
    rts

; EvictHidden: release the map columns of both layers that are not in view
; (keeps the ColBuild context: sn_L, sn_mcol, sn_vmax, sn_t, sn_tmp)
OtFreeHidden:
EvictHidden:
    lda sn_L
    pha
    lda sn_mcol
    pha
    lda sn_vmax
    pha
    lda sn_t
    pha
    lda sn_tmp
    pha
    stz sn_L
@lay:
    stz sn_mcol
@col:
    ldx sn_L
    lda sn_hacc,x
    lsr a
    lsr a
    lsr a
    eor #$FFFF
    sec
    adc sn_mcol             ; mcol - first visible column
    and #63
    cmp #33
    bcc @next               ; in view
    lda sn_L
    xba
    lsr a
    lsr a
    clc
    adc sn_mcol
    adc sn_mcol
    tax
    lda f:col_key,x
    cmp #KEY_NONE
    beq @next
    jsr ColRelease
@next:
    inc sn_mcol
    lda sn_mcol
    cmp #64
    bcc @col
    lda sn_L
    bne :+
    lda #2
    sta sn_L
    bra @lay
:   pla
    sta sn_tmp
    pla
    sta sn_t
    pla
    sta sn_vmax
    pla
    sta sn_mcol
    pla
    sta sn_L
    rts

; [W1c] OtSlotGet: -> A = a slot for the overhead structures (sprv3.s
; ohb.inc: held until OtSlotPut, never evicted), C set when none is free;
; OtSlotPut: A = such a slot, released (protected while the displayed frame
; may still show it)
OtSlotGet:
    jsr AllocSlot
    bcs :+
    pha
    asl a
    tax
    lda #$8000
    sta f:slot_ref,x
    lda #$FFFF
    sta f:slot_own,x
    pla
    clc
:   rts
OtSlotPut:
    asl a
    tax
    lda #0
    sta f:slot_ref,x
    lda sn_frame
    sta f:slot_rel,x
    rts

; [W1c] OtQuadGet: -> A = slot s of a free quad (slots s, s+1, s+16, s+17:
; tiles of a 16x16 piece as a sprite run uploads it), held like OtSlotGet's;
; C set when none (one pass over the cache from the search hand).  Only
; aligned quads (s mod 32 < 16, even): quads across two 32-slot blocks would
; leave single slots no quad can use (the cache fragments)
OtQuadGet:
    ldy #(NSLOT+31)/32*8+2
@try:
    lda sn_qh
    inc a
    inc a
    bit #16
    beq :+
    clc
    adc #16
:   cmp #NSLOT-17
    bcc :+
    lda #0
:   sta sn_qh
    asl a
    tax
    lda f:slot_ref,x
    ora f:slot_ref+2,x
    ora f:slot_ref+32,x
    ora f:slot_ref+34,x
    bne @busy
    lda sn_frame            ; (released during this build: maybe on screen)
    cmp f:slot_rel,x
    beq @busy
    cmp f:slot_rel+2,x
    beq @busy
    cmp f:slot_rel+32,x
    beq @busy
    cmp f:slot_rel+34,x
    beq @busy
    jsr QuadTake            ; (slot s)
    inx
    inx
    jsr QuadTake            ; (s + 1)
    txa
    clc
    adc #30
    tax
    jsr QuadTake            ; (s + 16)
    inx
    inx
    jsr QuadTake            ; (s + 17)
    lda sn_qh
    clc
    rts
@busy:
    dey
    bne @try
    sec
    rts
; QuadTake: X = slot * 2: held (its old tile unmapped); X kept
QuadTake:
    lda f:slot_own,x
    cmp #$FFFF
    beq :++
    phx
    asl a                   ; C = bank
    php
    lsr a
    plp
    bcc :+
    clc
    adc #MAXT
:   asl a
    tax
    lda #0
    sta f:tmap,x
    plx
:   lda #$8000
    sta f:slot_ref,x
    lda #$FFFF
    sta f:slot_own,x
    rts
; OtQuadPut: A = slot s of a quad: its four slots released
OtQuadPut:
    pha
    jsr OtSlotPut
    lda 1,s
    inc a
    jsr OtSlotPut
    lda 1,s
    clc
    adc #16
    jsr OtSlotPut
    pla
    clc
    adc #17
    jmp OtSlotPut

; AllocSlot: -> A = a slot with no references (its old tile unmapped), C set
; when every slot is referenced
AllocSlot:
    ldy #NSLOT
@scan:
    lda sn_clk
    inc a
    cmp #NSLOT
    bcc :+
    lda #0
:   sta sn_clk
    asl a
    tax
    lda f:slot_ref,x
    bne @busy
    lda f:slot_rel,x        ; released during this build: the displayed
    cmp sn_frame            ; frame may still show it
    bne @found
@busy:
    dey
    bne @scan
    sec
    rts
@found:
    lda f:slot_own,x
    cmp #$FFFF
    beq @free
    ; unmap the previous owner
    asl a                   ; C = bank
    php
    lsr a
    plp
    bcc :+
    clc
    adc #MAXT
:   asl a
    tax
    lda #0
    sta f:tmap,x
@free:
    lda sn_clk
    clc
    rts
