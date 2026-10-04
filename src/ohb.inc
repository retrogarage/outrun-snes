; [W1c] Overhead structures on BG1 / BG2 (OHB), included by sprv3.s.
;
; Wide structures above the road cannot be drawn with OBJ: one beam across
; the screen takes the whole 34 sliver line budget (the Gateway's tunnel of
; arches showed a few broken pieces of beams).  A BG layer shows them
; instead: on the sky lines BG1 (there the arcade FG tile layer, whose
; content is only the 3 map rows 29-31, the band just above the horizon,
; otiles.s VMAX_FG: above that band BG1 is free), on the road lines just
; below the horizon BG2 when the bottom road shows nothing there (no bottom
; road, or the same as the top road: outside the road splits the arcade
; keeps both roads identical).  The FG map's rows 0-5 hold the structures'
; map rows: with the FG scroll they are never on screen (they come right
; below the band, on road lines).
;
; K1 texture strips (tools/mkohb.py OhbSets): the Gateway arches' beams
; (frame descriptors 422-426, two mirrored halves per arch, drawn from the
; middle outwards) and the cloudy mountain's cloud ceiling (1065-1073) are
; rows of a texture (TW x TH tiles in scenery cache slots, otiles.s
; OtSlotGet; BG palette 6 colours 1-7 / 12-15 - the road uses 8-11).  Each half (piece) has its exact geometry (the two halves of
; an arch may differ in depth); per screen line the front-most piece
; covering it (the last in the hardware list): its texture row (VOFS: the
; piece's exact height, top clip undone), HOFS = its arch's left end (the
; texture is not scaled horizontally: stone); window = the extent of the
; piece and its partner half (square ends).  Sky
; lines above the FG band without a piece: BG1 masked; FG band lines
; without one: the FG layer; road lines without one: BG2 masked.
;
; OhbFrame runs before RoadRender: the per-line scroll and window words of
; lines 0..n-1 go to SR_STG (SG_BG1 / SG_WIN: lines the SA-1's own road
; lines never reach), n to SH_OHBN; sroad.s emits the top solid run's lines
; from them for BG1 and the road lines' for BG2 (OhbRoad).  The drawn
; pieces' entries get their records hidden (RR_D0 $4000), so the sprite
; pass leaves them out; sprites stay in front (OBJ priority 3, the
; texture's map entries priority 1: over the scenery and the roads).

.include "ohbdat.inc"
.import OtSlotGet, OtSlotPut, OtQuadGet, OtQuadPut, OtFreeHidden, sc_fgh, sc_fgv, road_p2, RD_Y
.import rd_hwctl, rd_co, rd_inv, bank_sid
.importzp RDB
.export OhbFrame, OhbInvalidate, OhbRoadLate

K1_LO    = SPR_D0 + 422*10      ; (the K1 sets' descriptor address bits 16-17)
K2_SL    = SPR_D0 + 531*10      ; K2 banner halves: START left 531-535, right 536-540,
K2_SR    = SPR_D0 + 536*10      ; GOAL left 1042-1046, right 1047-1051 (tools/mksprv3.py
K2_SE    = SPR_D0 + 541*10      ; BGPAIR: pieces on a 16 px grid)
K2_GL    = SPR_D0 + 1042*10
K2_GR    = SPR_D0 + 1047*10
K2_GE    = SPR_D0 + 1052*10
.assert ^K2_SL = ^K1_LO && ^(K2_SE - 1) = ^K1_LO && ^K2_GL = ^K1_LO && ^(K2_GE - 1) = ^K1_LO, error, "K2 descriptors"
.assert OHB_NSETS = 2 && OHB_S0HI <= .loword(K2_SL) && .loword(K2_GE) <= OHB_S1LO, error, "OhbFrame: the K1 / K2 ranges' order"
K2_MAXP  = 64                   ; pieces of a half loaded (those on screen) at most
K2_NPMAX = 160                  ; pieces of a half's image at most (its piece -> quad map)
K2_ROWS  = 10                   ; map rows (5 bands from the first one loaded)
K2_LOADP = 12                   ; pieces queued per frame (2.7 KB of the ~5 KB a frame: the
                                ; sprites keep the rest)
K2_BLKMAX = 30                  ; frames a loading set waits for VRAM before it goes (the
                                ; banner rising frees bands meanwhile)
K2_SCR   = 2*K2_ROWS*64         ; staging: screen 1's rows (both regions) after screen 0's
K2_CLRN  = 4                    ; rows cleared a frame when the banner went (2 x 256 bytes)
K2_HOLD  = 6                    ; frames a level that did not fit (VRAM, pieces) waits
K2_IDLE  = 30                   ; frames without the banner before its tiles go
OHB_MAXA = 32                   ; pieces (beam halves) per frame
OHB_MAXE = 64                   ; beam entries per frame
OHB_IDLE = 90                   ; frames without beams before the texture goes
OHB_RMAX = 224                  ; use the free BG2 through the first road run;
                                ; RrSplit keeps its staging clear of these roofs
OHB_MAPW = $1800 | $2000        ; map entry: palette 6, priority 1
OHB_W    = $404000              ; BW-RAM work area (HT_BASE area, unused in NEWGAME
                                ; builds beyond SR_STG $403000-$403DFF)
OHB_OWN  = OHB_W                ; per line (byte): piece number + 1, 0 none
OHB_SLOT = OHB_W + $100         ; per texture tile (word): its scenery cache slot
OHB_A    = OHB_W + $1C0         ; pieces (32 bytes), see the P_* fields
OHB_MAPB = OHB_W + $5C0         ; map rows staging: screen 0 rows, screen 1 rows (K1: 6
                                ; each; K2: regions 0 / 1, 10 rows each, K2_SCR apart)
OHB_PALB = OHB_W + $FC0         ; palette staging (16 colours)
OHB_ENT  = OHB_W + $FE0         ; this frame's beam entries (record offsets), OHB_MAXE
OHB_EA   = OHB_W + $1060        ; ... their piece offsets ($FFFF none)
OHB_KQ   = OHB_W + $10E0        ; K2: per set (S, N) and half (L, R) the piece -> quad
                                ; slot maps (K2_NPMAX words each; $FFFF: not loaded)
OHB_KG   = OHB_W + $15E0        ; K2: per half (32 bytes) this frame's geometry, K_*
P_TOP    = 0                    ; top line (unclipped, signed)
P_BOT    = 2                    ; bottom (clipped at ohb_lim; 0: not drawn)
P_X0     = 4                    ; extent (signed)
P_X1     = 6
P_STEP   = 8                    ; end (unclipped bottom), then texture rows * 256 / height
P_HOFS   = 10                   ; first entry, then HOFS
P_WIN    = 12                   ; window word (WH0 | WH1 << 8; $00FF empty)
P_DRAWN  = 14                   ; 1 drawn, 2 drawn with its partner (0 not drawn)
P_PART   = 16                   ; partner half ($FFFF none)
P_DSC    = 18                   ; descriptor record (pairing)
P_RTL    = 20                   ; drawn right to left (pairing)
P_RB     = 22                   ; texture row of its first map row (rows above: it)
P_VB     = 24                   ; VOFS base: its first map row's line - P_RB - 1
.assert OHB_SLOT >= OHB_OWN + 224, error, "OHB areas"
.assert OHB_A >= OHB_SLOT + OHB_TNMAX*2, error, "OHB areas"
.assert OHB_MAPB >= OHB_A + OHB_MAXA*32, error, "OHB areas"
.assert OHB_PALB >= OHB_MAPB + OHB_THMAX*64*2 && OHB_PALB >= OHB_MAPB + 2*K2_SCR, error, "OHB areas"
.assert OHB_ENT >= OHB_PALB + 32, error, "OHB areas"
.assert OHB_EA >= OHB_ENT + OHB_MAXE*2, error, "OHB areas"
.assert OHB_KQ >= OHB_EA + OHB_MAXE*2, error, "OHB areas"
.assert OHB_KG >= OHB_KQ + 4*K2_NPMAX*2, error, "OHB areas"
.assert OHB_KG + 64 <= $405700, error, "OHB areas (PAL_BUF)"
K_IMG    = 0                    ; K2 geometry: exact image
K_W      = 2                    ; its width / height
K_H      = 4
K_HE     = 6                    ; exact height
K_X      = 8                    ; image left edge (shown image: OhbK2Pos)
K_TOP    = 10                   ; top (top clip undone)
K_PAL    = 12                   ; pal_src
K_FL     = 14                   ; mirrored / right to left bits (w_mir | w_rtl)
K_XA     = 16                   ; anchor x (arcade x * 0.8)
K_Y      = 18                   ; image top (shown image: the arcade's, K_TOP)
.assert SR_STG + $E00 <= OHB_W, error, "OHB area overlaps SR_STG"

.segment "BSS"
ohb_res:  .res 2                ; 1: the K1 texture of set ohb_set is resident (slots, map rows)
ohb_set:  .res 2                ; its OhbSets offset; this frame's set (OhbFrame): ohb_fset
ohb_fset: .res 2
ohb_tn:   .res 2                ; the resident set: tiles, TW, TH, source rows, tiles
ohb_tw:   .res 2                ; address / bank, colour map address
ohb_th:   .res 2
ohb_trows: .res 2
ohb_tex:  .res 2
ohb_texb: .res 2
ohb_col:  .res 2
ohb_idle: .res 2                ; frames without beams
ohb_pal:  .res 2                ; pal_src in BG palette 6 ($FFFF none)
ohb_na:   .res 2                ; pieces this frame (* 32)
ohb_cnt:  .res 2                ; entries
ohb_hor:  .res 2                ; first road line
ohb_band: .res 2                ; first line of the FG layer's band
ohb_n:    .res 2                ; lines posted (s..n-1)
ohb_s:    .res 2
ohb_ne:   .res 2                ; beam entries (* 2)
ohb_hend: .res 2                ; end of the first road run
ohb_lim:  .res 2                ; lines the structures may use (0..lim-1)
ohb_rmax: .res 2                ; OhbLines: last texture row * 256
ohb_cent: .res 2                ; OhbLines: 1 = centred row sampling (the set's flag bit 0)
ohb_dma:  .res 2                ; ROM -> VRAM bytes queued this frame (SprV2Frame's budget)
k2_el:    .res 2                ; K2: this frame's left / right half (record offsets)
k2_er:    .res 2
k2_img:   .res 4                ; S (shown): per half its image ($FFFF none)
k2_nimg:  .res 4                ; N (loading; right after k2_img: k2_img + set * 4)
k2_nld:   .res 4                ; N: per half the next piece to scan
k2_cnt:   .res 4                ; N: per half the pieces loaded
k2_bank:  .res 2                ; scenery bank * 2 whose palette 2 + 2 * bank it uses ($FFFF)
k2_pal:   .res 2                ; ... pal_src loaded there
k2_idle:  .res 2                ; frames without the banner
k2_hold:  .res 2                ; frames before loading is tried again
k2_reg:   .res 2                ; S's map region (0 / 1: FG map rows 0-9 / 10-19); N the other
k2_pb0:   .res 4                ; per set (S, N): the first band in the map rows
k2_pcr:   .res 4                ; ... the right image's map column offset
k2_pdx:   .res 4                ; ... x shift (half the snapping error)
k2_ph:    .res 4                ; ... image rows (the taller half's)
k2_pnb:   .res 4                ; ... bands (the taller half's)
k2_pstep: .res 4                ; ... this frame's step (rows * 256 / exact height)
k2_srel:  .res 2                ; S's bands released (all below it)
k2_nrel:  .res 2                ; N's bands released (above the screen; all below it)
k2_ndone: .res 2                ; N's bands complete (all below it)
k2_blk:   .res 2                ; frames N could not load (VRAM)
k2_ysp:   .res 2                ; this frame's split line (N's complete bands above it)
k2_split: .res 2                ; 1: VRAM cannot hold N and S: N's complete bands shown
k2_dirty: .res 2                ; the regions' map rows hold entries
ohb_ymask: .res 2               ; OhbPaint: lines 0..ymask-1 posted (masked unless a piece's)
k2_maxrow: .res 2               ; the last FG map row the banner's regions hold ($FFFF none)
k2_clr:   .res 2                ; rows being cleared: the next one ($FFFF none)

.segment "SA1CODE"
.a16
.i16

;----------------------------------------------------------------------------
; OhbInvalidate (otiles.s ScnInvalidate: every scenery slot is free again,
; a BG page may have overwritten the map rows / palette 6): not resident
;----------------------------------------------------------------------------
OhbInvalidate:
    stz ohb_res
    stz ohb_idle
    lda #$FFFF
    sta ohb_pal
    sta ohb_set
    sta k2_img              ; (K2: nothing resident; the slots are free again,
    sta k2_img+2            ; the FG map was set up again)
    sta k2_nimg
    sta k2_nimg+2
    sta k2_bank
    stz k2_idle
    stz k2_hold
    stz k2_dirty
    lda #$FFFF
    sta k2_maxrow
    sta k2_clr
    rts

;----------------------------------------------------------------------------
; OhbFrame: the frame's overhead structures (before RoadRender, after
; ScnRender: sc_fgh / sc_fgv are this frame's)
;----------------------------------------------------------------------------
OhbFrame:
    jsr ArchPrepare
    stz SH_OHBN
    stz SH_OHBS
    .ifdef NOOHB
    stz ohb_dma             ; (test builds: no structure on BG)
    rts
    .endif
    lda scn_pmode           ; (a BG page shows: no road view)
    beq :+
    rts
:   stz ohb_ymask
    ; ---- the beam entries / banner halves (a quick test per entry) ----
    stz ohb_ne
    stz ohb_dma
    lda #$FFFF
    sta ohb_fset
    lda #$FFFF
    sta k2_el
    sta k2_er
    lda sprite_count
    cmp #127
    bcc :+
    lda #127
:   asl a
    asl a
    asl a
    asl a
    sta ohb_cnt             ; (record offset limit)
    ldx #0
    bra @ent
@nx:
    txa
    clc
    adc #16
    tax
@ent:
    cpx ohb_cnt
    bcc :+
    jmp @scanned
:   lda f:REC_BASE+RR_FL,x
    and #$0300
    cmp #(^K1_LO) << 8
    bne @nx
    lda f:REC_BASE+RR_SRC,x ; (the ranges in address order)
    cmp #OHB_S0LO           ; (K1 set 0: the beams)
    bcc @nx
    cmp #OHB_S0HI
    bcs :+
    ldy #0
    bra @k1
:   cmp #.loword(K2_SL)
    bcc @nx
    cmp #.loword(K2_SR)
    bcc @k2l
    cmp #.loword(K2_SE)
    bcc @k2r
    cmp #.loword(K2_GL)
    bcc @nx
    cmp #.loword(K2_GR)
    bcc @k2l
    cmp #.loword(K2_GE)
    bcc @k2r
    cmp #OHB_S1LO           ; (K1 set 1: the clouds)
    bcc @nx
    cmp #OHB_S1HI
    bcs @nx
    ldy #16
    bra @k1
@k2l:
    lda f:REC_BASE+RR_D0,x
    and #$5000
    bne @nx
    stx k2_el
    bra @nx
@k2r:
    lda f:REC_BASE+RR_D0,x
    and #$5000
    bne @nx2
    stx k2_er
@nx2:
    bra @nx
@k1:
    lda f:REC_BASE+RR_D0,x
    and #$5000
    bne @nx2
    lda ohb_fset            ; (one set a frame: the first one met; the
    bpl @k1s                ; others' entries stay sprites)
    sty ohb_fset
    bra @k1a
@k1s:
    sty w_t
    cmp w_t
    bne @nx2
@k1a:
    txa
    ldy ohb_ne
    cpy #OHB_MAXE*2
    bcs @nx2
    tyx
    sta f:OHB_ENT,x
    tax
    iny
    iny
    sty ohb_ne
    bra @nx2
@scanned:
    lda arch_count
    beq :+
    stz ohb_fset
    lda #2
    sta ohb_ne              ; the composite path owns the stone texture
:   lda ohb_ne
    bne @beams
    lda ohb_res             ; no beam: the texture stays a while
    beq :+
    inc ohb_idle
    lda ohb_idle
    cmp #OHB_IDLE
    bcc :+
    jsr OhbUnload
:   jmp OhbK2               ; (the banners)
@beams:
    lda k2_img              ; (the banner's quads / map rows go first; when
    and k2_img+2            ; the rows are cleared (the staging): the beams
    and k2_nimg             ; from the next frame)
    and k2_nimg+2
    cmp #$FFFF
    bne @k2f
    lda k2_dirty
    beq @k1go
@k2f:
    jsr OhbK2Free
    lda k2_dirty            ; (rows to clear: they go first, masked meanwhile)
    beq @k1go
    jmp K2Mask
@k1go:
    lda ohb_res             ; (another set's texture resident: it goes)
    beq :+
    lda ohb_set
    cmp ohb_fset
    beq :+
    jsr OhbUnload
:   jsr OhbHorizon
    stz ohb_idle
    jsr OhbSetPar
    jmp OhbK1

; OhbSetPar: the parameters of set ohb_fset -> ohb_tn.., ohb_rmax
OhbSetPar:
    ldx ohb_fset
    lda f:OhbSets+8,x
    sta ohb_tn
    lda f:OhbSets+10,x
    and #$00FF
    sta ohb_tw
    lda f:OhbSets+11,x
    and #$00FF
    sta ohb_th
    lda f:OhbSets+12,x
    and #$00FF
    sta ohb_trows
    xba
    dec a
    sta ohb_rmax            ; (last texture row * 256)
    lda f:OhbSets+13,x
    and #$0001
    sta ohb_cent
    lda f:OhbSets+6,x
    sta ohb_tex
    lda f:OhbSets+5,x
    and #$00FF
    sta ohb_texb
    lda f:OhbSets+14,x
    sta ohb_col
    rts

;----------------------------------------------------------------------------
; OhbHorizon: ohb_hor (first road line), ohb_lim (lines the structures may
; use), ohb_band (first line of the FG layer's band)
;----------------------------------------------------------------------------
OhbHorizon:
OhbHzn:                     ; (profiling marker)
    ; ---- the horizon: first road line (the lines above it are solid) ----
    lda road_p2
    clc
    adc #RD_Y + $0320*2
    tax
    ldy #0
@hz:
    lda f:RDB*$10000,x
    bit #$0800
    beq @hzd
    inx
    inx
    iny
    cpy #224
    bcc @hz
@hzd:
    sty ohb_hor
    ; below the horizon BG2, through the first continuous road run, when the
    ; bottom road shows nothing: none (rd_hwctl 0 / 3), or the same as the
    ; top road (both roads share the line words: the same car offset and
    ; inversion; the arcade keeps the two roads identical outside the splits)
    sty ohb_lim
    lda rd_hwctl
    and #3
    beq @free
    cmp #3
    beq @free
    lda rd_co
    cmp rd_co+2
    bne @lim
    lda rd_inv
    cmp rd_inv+2
    bne @lim
@free:
    tya
    clc
    adc #OHB_RMAX
    sta w_t
@he:
    cpy w_t
    bcs @hed
    cpy #224
    bcs @hed
    lda f:RDB*$10000,x
    bit #$0800
    bne @hed
    inx
    inx
    iny
    bra @he
@hed:
    sty ohb_lim
@lim:
    ; the FG layer's band: map row 29 (line 232) shows on line 232 - fgv
    lda #232
    sec
    sbc sc_fgv
    bpl :+
    lda #0
:   cmp ohb_hor
    bcc :+
    lda ohb_hor
:   sta ohb_band
    rts

;----------------------------------------------------------------------------
; OhbK1: the beams' pieces, back to front
;----------------------------------------------------------------------------
OhbK1:
    lda arch_count
    beq OhbPcs
    stz ohb_na              ; selected composites post roofs after OBJ admission
    lda ohb_res
    bne :+
    jsr OhbLoad
:   rts
OhbPcs:                     ; (profiling marker)
    stz ohb_na
    ldy #0
@pc:
    cpy ohb_ne
    bcs @pcd
    sty w_i
    tyx
    lda #$FFFF
    sta f:OHB_EA,x
    lda f:OHB_ENT,x
    tax
    jsr OhbGeom
    jsr OhbPiece            ; -> X = its piece offset ($FFFF none)
    txa
    ldx w_i
    sta f:OHB_EA,x
    ldy w_i
    iny
    iny
    bra @pc
@pcd:
    lda ohb_res
    bne @post
    jsr OhbLoad             ; (this frame's uploads: shown from this frame)
    bcc @post
    rts                     ; (no slots: the beams stay sprites)
@post:
    jsr OhbPrep             ; (the drawn pieces' records: the sprite pass leaves them out)
    lda ohb_na
    beq :+
    jsr OhbPal
:   jsr OhbPaint
    jmp OhbLines

;----------------------------------------------------------------------------
; OhbGeom: X = record offset of a beam half: its exact geometry (CandRaw's
; for these frames: mode 0, no image): w_dsc, w_we, w_he, w_xa, w_rtl,
; w_top (top clip undone), w_vb; w_k = the entry index (its palette)
;----------------------------------------------------------------------------
OhbGeom:
    stx w_v+2
    txa
    lsr a
    lsr a
    lsr a
    lsr a
    sta w_k                 ; (entry index)
    lda f:REC_BASE+RR_D0,x
    sta w_d0
    lda f:REC_BASE+RR_FL,x
    sta w_d4
    lda f:REC_BASE+RR_H,x
    and #$00FF
    inc a
    sta w_vb                ; (visible rows for now)
    lda f:REC_BASE+RR_SRC,x
    sec
    sbc #.loword(SPR_D0)    ; (descriptor * 10: the bank bits borrow)
    tay
    lda f:REC_BASE+RR_VZ,x
    and #$03FF
    tax
    lda f:HzIdx,x
    and #$00FF
    asl a
    sta w_t                 ; (zoom index * 2)
    tyx
    lda f:SPR_META,x
    sta w_dsc
    tax
    lda f:DR,x              ; We = npx * KW >> 14 (ceil)
    sta MAL
    ldx w_t
    lda f:SprKW,x
    sta MBL
    nop
    nop
    lda MR+1
    clc
    adc #63
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    sta w_we
    ldx w_dsc               ; He = rows * KH >> 13 (ceil)
    lda f:DR+2,x
    sta MAL
    ldx w_t
    lda f:SprKH,x
    sta MBL
    sta w_t+2               ; (KH)
    nop
    lda MR+1
    clc
    adc #31
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    sta w_he
    ; x: first drawn pixel (arcade), * 0.8; right to left: + $200 below $80
    stz w_rtl
    lda w_d4
    and #RR_RTL
    beq :+
    inc w_rtl
:   ldx w_v+2
    lda f:REC_BASE+RR_X,x
    ldy w_rtl
    beq @xpos
    cmp #$0080
    bcs @xpos
    adc #$0200              ; (C clear)
@xpos:
    and #$03FF
    asl a
    tax
    lda f:X08,x
    sta w_xa
    ; y: arcade top, unclipped (rows skipped * KH above the screen)
    lda w_d0
    and #$01FF
    sec
    sbc #$0100
    sta w_top
    clc
    adc w_vb
    cmp #224
    bcc :+
    lda #$7FFF
:   sta w_vb
    lda w_top
    bne @ytop
    ldx w_v+2
    lda f:REC_BASE+RR_D1,x
    sta w_u+2
    ldx w_dsc
    lda f:DR+4,x            ; pitch
    beq @ytop
    sta w_t
    lda w_u+2
    sec
    sbc f:DR+6,x
    cmp w_t
    bcc @ytop
    ldx w_t
    jsr SDiv16u             ; rows skipped
    sta MAL
    lda w_t+2
    sta MBL
    nop
    nop
    lda MR+1
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    eor #$FFFF
    inc a
    sta w_top
@ytop:
    rts

;----------------------------------------------------------------------------
; OhbPiece: beam half w_i (CandRaw geometry) -> a piece (X = its offset,
; $FFFF none); the partner of the last piece when it is the other half of
; the same arch (the same descriptor, the other direction, neighbours in
; the list)
;----------------------------------------------------------------------------
OhbPiece:
    ; bottom = min(top + He, vb, lim) (signed); not visible: no piece
    lda w_top
    clc
    adc w_he
    sta w_t
    lda w_vb
    sec
    sbc w_t
    bvc :+
    eor #$8000
:   bpl :+
    lda w_vb
    sta w_t
:   lda ohb_lim
    sec
    sbc w_t
    bvc :+
    eor #$8000
:   bpl :+
    lda ohb_lim
    sta w_t
:   lda w_t
    bmi @none
    bne :+
@none:
    ldx #$FFFF
    rts
:   ldx ohb_na
    cpx #OHB_MAXA*32
    bcs @none
    lda w_top
    sta f:OHB_A+P_TOP,x
    clc
    adc w_he
    sta f:OHB_A+P_STEP,x    ; (end)
    lda w_t
    sta f:OHB_A+P_BOT,x
    lda w_rtl               ; extent [x0, x1]
    sta f:OHB_A+P_RTL,x
    beq @ltr
    lda w_xa
    sta f:OHB_A+P_X1,x
    sec
    sbc w_we
    inc a
    sta f:OHB_A+P_X0,x
    bra @ext
@ltr:
    lda w_xa
    sta f:OHB_A+P_X0,x
    clc
    adc w_we
    dec a
    sta f:OHB_A+P_X1,x
@ext:
    lda w_dsc
    sta f:OHB_A+P_DSC,x
    lda w_k
    sta f:OHB_A+P_HOFS,x    ; (its entry: its palette)
    lda #$FFFF
    sta f:OHB_A+P_PART,x
    sta f:OHB_A+P_VB,x      ; (VOFS = row - y - 1)
    lda #0
    sta f:OHB_A+P_RB,x
    ; the other half of the last piece?
    txa
    beq @add
    lda f:OHB_A-32+P_PART,x
    cmp #$FFFF
    bne @add
    lda f:OHB_A-32+P_RTL,x  ; (the halves of an arch may use different
                            ; frames: their depths differ)
    cmp w_rtl
    beq @add
    txa
    sec
    sbc #32
    sta f:OHB_A+P_PART,x
    txa
    sta f:OHB_A-32+P_PART,x
@add:
    txa
    clc
    adc #32
    sta ohb_na
    rts                     ; (X = the piece)

;----------------------------------------------------------------------------
; OhbPrep: per piece whether it is drawn (its end within the lines the BG
; layers may show - else its entry stays a sprite), its step (texture rows
; per line), window words (its own, the union with a drawn partner), HOFS
; (the arch's left end: the halves' texture lines up); the drawn pieces'
; entries get their records hidden (RR_D0 $4000)
;----------------------------------------------------------------------------
OhbPrep:
    ldx #0
@a:
    cpx ohb_na
    bcc :+
    jmp @pair
:   lda f:OHB_A+P_HOFS,x    ; (first entry: its palette, for OhbPal)
    sta w_k
    ; drawn: end <= lim + 2, bottom > max(top, 0)
    lda ohb_lim
    inc a
    inc a
    sec
    sbc f:OHB_A+P_STEP,x
    bmi @no
    lda f:OHB_A+P_TOP,x
    bpl :+
    lda #0
:   cmp f:OHB_A+P_BOT,x
    bpl @no
    lda #1
    sta f:OHB_A+P_DRAWN,x
    lda f:OHB_A+P_STEP,x    ; step = texture rows * 256 / (end - top)
    sec
    sbc f:OHB_A+P_TOP,x
    bne :+
    inc a
:   phx
    pha
    lda ohb_trows
    xba
    plx
    jsr SDiv16u
    plx
    sta f:OHB_A+P_STEP,x
    lda f:OHB_A+P_X0,x
    sta w_u
    lda f:OHB_A+P_X1,x
    sta w_u+2
    jsr OhbWin
    sta f:OHB_A+P_WIN,x
    lda f:OHB_A+P_X0,x
    eor #$FFFF
    inc a
    and #$03FF
    sta f:OHB_A+P_HOFS,x
    bra @n
@no:
    lda #0                  ; (not drawn: no lines)
    sta f:OHB_A+P_DRAWN,x
    sta f:OHB_A+P_BOT,x
@n: txa
    clc
    adc #32
    tax
    jmp @a
@pair:
    ; pieces with a drawn partner: the union's window and HOFS (its left end)
    ldx #0
@p:
    cpx ohb_na
    bcs @ent
    lda f:OHB_A+P_DRAWN,x
    beq @pn
    lda f:OHB_A+P_PART,x
    bmi @pn
    tay                     ; (partner offset)
    phx
    tyx
    lda f:OHB_A+P_DRAWN,x
    beq @pq
    lda f:OHB_A+P_X0,x
    sta w_u
    lda f:OHB_A+P_X1,x
    sta w_u+2
    plx
    lda #2                  ; (drawn with its partner: OhbPaint's front pass)
    sta f:OHB_A+P_DRAWN,x
    lda f:OHB_A+P_X0,x      ; union: x0 the smaller, x1 the larger
    sec
    sbc w_u
    bvc :+
    eor #$8000
:   bpl :+
    lda f:OHB_A+P_X0,x
    sta w_u
:   lda f:OHB_A+P_X1,x
    sec
    sbc w_u+2
    bvc :+
    eor #$8000
:   bmi :+
    lda f:OHB_A+P_X1,x
    sta w_u+2
:   jsr OhbWin
    sta f:OHB_A+P_WIN,x
    lda w_u
    eor #$FFFF
    inc a
    and #$03FF
    sta f:OHB_A+P_HOFS,x
    bra @pn
@pq:
    plx
@pn:
    txa
    clc
    adc #32
    tax
    bra @p
@ent:
    ldy ohb_ne
@e:
    dey
    dey
    bmi @d
    tyx
    lda f:OHB_EA,x
    bmi @e                  ; (no piece)
    tax
    lda f:OHB_A+P_DRAWN,x
    beq @e
    tyx
    lda f:OHB_ENT,x
    tax
    lda f:REC_BASE+RR_D0,x
    ora #$4000
    sta f:REC_BASE+RR_D0,x
    bra @e
@d: rts

; OhbWin: extent [w_u, w_u+2] -> A = window word [max(x0, 0), min(x1, 255)]
; ($00FF: off screen); X kept
OhbWin:
    lda w_u+2
    bmi @off
    lda w_u
    cmp #256
    bpl @off
    cmp #0
    bpl :+
    lda #0
:   sta w_t
    lda w_u+2
    cmp #256
    bmi :+
    lda #255
:   xba
    ora w_t
    rts
@off:
    lda #$00FF
    rts

;----------------------------------------------------------------------------
; OhbPal: BG palette 6 colours 1-7 / 12-15 <- SprPal[pal_src of the last
; piece's entry][the set's colour map] when that palette changed (swap queue)
;----------------------------------------------------------------------------
OhbPal:
    lda w_k                 ; (OhbPrep: the last piece's first entry)
    asl a
    tax
    lda f:hw_pal,x
    and #$00FF
OhbPalSource:
    cmp ohb_pal
    bne :+
    rts
:   sta ohb_pal
    xba
    lsr a
    lsr a
    lsr a                   ; * 32
    sta w_t                 ; (SprPal offset)
    ldy #2                  ; BG colours 1-15
    lda ohb_col
    sta bp                  ; (the colour map through [bp],y)
    sep #$20
    .a8
    lda ohb_texb
    sta bp+2
    rep #$20
    .a16
@c:
    phy
    tya
    lsr a
    tay
    lda [bp],y
    ply
    and #$00FF
    beq @z
    asl a
    clc
    adc w_t
    tax
    lda f:SprPal,x
@z: tyx
    sta f:OHB_PALB,x
    iny
    iny
    cpy #32
    bcc @c
    lda #.loword(OHB_PALB)+2
    sta ptr0
    sep #$20
    .a8
    lda #^OHB_PALB
    sta ptr0+2
    rep #$20
    .a16
    lda #BL_CGRAM
    ldx #6*16+1
    ldy #14
    jsr QueueUpload         ; colours 1-7
    lda #.loword(OHB_PALB)+24
    sta ptr0
    lda #BL_CGRAM
    ldx #6*16+12
    ldy #8
    jmp QueueUpload         ; colours 12-15

;----------------------------------------------------------------------------
; OhbPaint: ohb_n = lines to post (the drawn pieces' bottoms); per line the
; front-most piece (painted back to front) -> OHB_OWN (piece number + 1)
;----------------------------------------------------------------------------
OhbPaint:
    stz ohb_n               ; n: the drawn pieces' bottoms, s: their first line
    lda #$7FFF
    sta ohb_s
    ldx #0
@b: cpx ohb_na
    bcs @c
    lda f:OHB_A+P_BOT,x
    beq @bn                 ; (not drawn)
    cmp ohb_n
    bcc :+
    sta ohb_n
:   lda f:OHB_A+P_TOP,x
    bpl :+
    lda #0
:   cmp ohb_s
    bcs @bn
    sta ohb_s
@bn:
    txa
    clc
    adc #32
    tax
    bra @b
@c: lda ohb_s
    cmp ohb_n
    bcc :+
    lda ohb_n
    sta ohb_s               ; (no piece)
:   lda ohb_ymask           ; (K2: lines 0..ymask-1 too: with the FG layer's
    beq @z0                 ; scroll the banner's map rows are on screen there)
    bmi @z0
    stz ohb_s
    cmp ohb_n
    bcc @z0
    sta ohb_n
@z0:
    ldx ohb_s               ; lines s..n-1: no piece yet (words: the byte
    lda #0                  ; after them too)
@z: cpx ohb_n
    bcs :+
    sta f:OHB_OWN,x
    inx
    inx
    bra @z
:
    ; two passes: first the pieces drawn without their partner (the other
    ; half of their arch is not there: the arcade shows the structures
    ; behind beside them, one BG line cannot - the whole width of a paired
    ; piece behind is the better picture), then the paired ones
    lda #1
    sta w_t+2               ; (pass: the P_DRAWN value painted)
@pass:
    ldx #0
    stz w_k                 ; (piece number)
@a:
    cpx ohb_na
    bcs @pd
    inc w_k
    lda f:OHB_A+P_DRAWN,x
    cmp w_t+2
    bne @nx
    lda f:OHB_A+P_BOT,x
    dec a
    sta w_u                 ; (its last line)
    lda f:OHB_A+P_TOP,x     ; (from line 0)
    bpl :+
    lda #0
:   cmp f:OHB_A+P_BOT,x
    bcs @nx                 ; (no line)
    phx
    tax
    lda w_k                 ; (piece number + 1 in both bytes: words)
    xba
    ora w_k
@l: cpx w_u
    bcs @t
    sta f:OHB_OWN,x
    inx
    inx
    bra @l
@t: bne @n                  ; (one line left: a byte)
    sep #$20
    .a8
    sta f:OHB_OWN,x
    rep #$20
    .a16
@n: plx
@nx:
    txa
    clc
    adc #32
    tax
    bra @a
@pd:
    lda w_t+2
    inc a
    sta w_t+2
    cmp #3
    bcc @pass
    rts

;----------------------------------------------------------------------------
; OhbLines: the per-line words of lines 0..ohb_n-1 -> SR_STG, SH_OHBN (runs
; of lines of one piece: the texture row stepped per line)
;----------------------------------------------------------------------------
OhbLines:
    lda ohb_n
    bne :+
    rts
:   sta w_kk                ; (n)
    lda ohb_hor
    sta w_jmp
    lda ohb_band
    sta w_xo
    lda ohb_rmax
    sta w_hx                ; (last texture row * 256)
    lda #.loword(OHB_OWN)
    sta bp                  ; (OHB_OWN through [bp],y)
    sep #$20
    .a8
    lda #^OHB_OWN
    sta bp+2
    rep #$20
    .a16
    lda ohb_s
    cmp ohb_n
    bcc :+
    rts                     ; (no line)
:   sta w_v                 ; y = s
    sta SH_OHBS
    asl a
    asl a
    tax                     ; 4 y
@l:
    ldy w_v
    lda [bp],y
    and #$00FF
    bne :+
    jmp @def
:   ; a run of lines of piece n - 1: its values
    sta w_gn
    dec a
    asl a
    asl a
    asl a
    asl a
    asl a
    tay                     ; (piece offset)
    phx
    tyx
    lda f:OHB_A+P_TOP,x
    sta w_t                 ; top
    lda f:OHB_A+P_STEP,x
    sta w_t+2               ; step
    lda f:OHB_A+P_HOFS,x
    sta w_u                 ; HOFS
    lda f:OHB_A+P_WIN,x
    sta w_u+2               ; window word
    lda f:OHB_A+P_RB,x
    sta w_vb                ; (texture row of its first map row)
    lda f:OHB_A+P_VB,x
    sta w_d0                ; (VOFS base)
    lda f:OHB_A+P_BOT,x     ; (the run ends at its bottom at the latest)
    cmp w_kk
    bcc :+
    lda w_kk
:   sta w_gmax
    plx
    stz w_k                 ; centred sampling: + (step - 256) / 2 (the
    lda ohb_cent            ; arcade's smaller frames of a strip are shrunk
    beq :+                  ; copies: their first row is not the edge's)
    lda w_t+2
    sec
    sbc #256
    bcc :+
    lsr a
    sta w_k
:
    ; texture row * 256 of this line: (y - top) * step, at most rows - 1
    lda w_v
    sec
    sbc w_t
    sta MAL
    lda w_t+2
    sta MBL
    nop
    nop
    lda MR+2
    bne @sat
    lda MR
    clc
    adc w_k
    bcs @sat
    cmp w_hx
    bcc :+
@sat:
    lda w_hx
:   sta w_gmin
@r:
    lda w_u
    sta f:SR_STG+SG_BG1,x
    lda w_u+2
    sta f:SR_STG+SG_WIN,x
    lda #$FF00
    sta f:SR_STG+SG_WIN+2,x
    lda w_gmin+1            ; (row)
    and #$00FF
    cmp w_vb                ; (K2: rows above its first map row: that one)
    bcs :+
    lda w_vb
:   clc                     ; VOFS = row + base - y (base: map row line - rb
    adc w_d0                ; - 1: line y shows the BG's line VOFS + y + 1,
    sec                     ; as the roads' RR_ROW)
    sbc w_v
    and #$03FF
    sta f:SR_STG+SG_BG1+2,x
    inx
    inx
    inx
    inx
    lda w_gmin
    clc
    adc w_t+2
    bcs :+
    cmp w_hx
    bcc :++
:   lda w_hx
:   sta w_gmin
    inc w_v
    lda w_v
    cmp w_gmax
    bcs @l2
    tay
    lda [bp],y
    and #$00FF
    cmp w_gn
    beq @r
@l2:
    lda w_v
    cmp w_kk
    bcs @done
    jmp @l
@def:
    lda w_v
    cmp w_jmp
    bcs @em                 ; (road lines: BG2 masked)
    cmp w_xo
    bcs @fg
@em:
    lda #$00FF              ; (window empty: masked)
    sta f:SR_STG+SG_WIN,x
    lda #$FF00
    sta f:SR_STG+SG_WIN+2,x
    bra @nl
@fg:
    lda sc_fgh              ; the FG layer
    sta f:SR_STG+SG_BG1,x
    lda sc_fgv
    sta f:SR_STG+SG_BG1+2,x
    lda #$FF00
    sta f:SR_STG+SG_WIN,x
    sta f:SR_STG+SG_WIN+2,x
@nl:
    inx
    inx
    inx
    inx
    inc w_v
    lda w_v
    cmp w_kk
    bcs @done
    jmp @l
@done:
    sta SH_OHBN
    rts

;----------------------------------------------------------------------------
; OhbK2: the START / GOAL banner (two halves) on BG when both halves are
; there, not mirrored, their images have at most K2_NPMAX pieces (K2_MAXP
; of them on screen) and a scenery bank is free (its palette 2 + 2 * bank
; takes the banner's colours: the images keep the arcade colour indices);
; else the halves stay sprites.
;
; Two sets of images: the shown one (S) and the one loading (N), a level
; nearer the arcade's zoom.  Only the pieces on screen load (16 px grid,
; tools/mksprv3.py BGPAIR; the near banner is mostly above the screen and
; beyond its sides) into quads of scenery cache slots, K2_LOADP a frame,
; band after band (both halves); each set's bands have their own map rows
; (FG map rows 0-9 / 10-19: two regions, both screens, the bands from the
; set's first one on screen, the halves side by side: the right image's
; columns snapped to the 8 px grid, the seam made opaque).  The lines show
; the images stretched to the arcade's exact top and height (the HDMA
; picks a map row per line): the lines of N's complete bands N (above the
; split line), the others S, whose bands above that go (VRAM holds a near
; level and a part of the next one, not two levels); N complete: it is S.
; The FG map rows of the regions are on screen with the FG layer's scroll
; above its band: the lines above the band are posted masked while the
; rows hold entries (k2_dirty), the rows cleared when the banner goes.
;----------------------------------------------------------------------------
OhbK2:
    lda k2_el
    cmp #$FFFF
    beq @none
    lda k2_er
    cmp #$FFFF
    bne @have
@none:
    lda k2_img              ; no banner: after K2_IDLE frames its tiles go
    and k2_img+2
    and k2_nimg
    and k2_nimg+2
    cmp #$FFFF
    beq @mask
    inc k2_idle
    lda k2_idle
    cmp #K2_IDLE
    bcc @mask
    jsr OhbK2Free
@mask:
    jmp K2Mask
@have:
    stz k2_idle
    jsr OhbHorizon
    jsr K2Bank
    bcs @mask
    ldx k2_el
    lda #0
    jsr K2Geom
    bcs @mask
    ldx k2_er
    lda #32
    jsr K2Geom
    bcs @mask
    lda f:OHB_KG+K_TOP      ; the halves' tops within 4 lines
    sec
    sbc f:OHB_KG+32+K_TOP
    clc
    adc #4
    cmp #9
    bcs @mask
    lda f:OHB_KG+K_TOP      ; the bottom within the lines BG may show
    clc
    adc f:OHB_KG+K_HE
    dec a
    dec a
    sec
    sbc ohb_lim
    bvc :+
    eor #$8000
:   bpl @mask
    lda #K2_LOADP
    sta w_k                 ; (pieces this frame may queue)
    lda k2_hold
    beq :+
    dec k2_hold
:   jsr K2Start
    jsr K2Load
    lda k2_img
    cmp #$FFFF
    beq @mask               ; (nothing shown yet: the halves stay sprites)
    jsr K2Release
    jsr K2Pal
    jmp K2Show

; K2Mask: (rows with entries, the banner not drawn) the lines above the FG
; layer's band masked
K2Mask:
    jsr K2Clear
    lda k2_dirty
    bne :+
    rts
:   jsr OhbHorizon
    stz ohb_na
    jsr K2YMask
    jsr OhbPaint
    jmp OhbLines

; K2YMask: ohb_ymask = the lines the FG layer's scroll shows the regions'
; reserved rows on: 16*K2_ROWS - sc_fgv - 1 (line y shows fgv + y + 1)
K2YMask:
    ; Both map regions are reserved for banners, including stale entries
    ; left by an earlier level/page. Neither may leak into the sky.
    lda #2*K2_ROWS
    asl a
    asl a
    asl a
    clc
    sbc sc_fgv
    sta ohb_ymask
    rts

; K2Show: the pieces of the frame: S (lines from its top), N's complete
; bands over it (lines above the split line); the halves' records hidden
K2Show:
    lda #0
    sta w_i
    jsr K2Piece
    lda #32
    sta ohb_na
    lda k2_nimg
    cmp #$FFFF
    beq @one
    lda k2_ysp
    dec a
    bmi @one                ; (no line of N on screen)
    lda #32
    sta w_i
    lda #2
    jsr K2Piece
    lda k2_ysp
    cmp f:OHB_A+P_BOT
    bcc :+
    lda f:OHB_A+P_BOT
:   sta f:OHB_A+32+P_BOT
    lda #2
    sta f:OHB_A+32+P_DRAWN  ; (painted over S)
    lda #64
    sta ohb_na
@one:
    lda k2_ph               ; (rows: the taller set's; K2Piece / OhbWin take w_t)
    ldx k2_nimg
    inx
    beq :+
    cmp k2_ph+2
    bcs :+
    lda k2_ph+2
:   xba
    dec a
    sta ohb_rmax
    stz ohb_cent
    ldx k2_el               ; (both halves: the sprite pass leaves them out)
    lda f:REC_BASE+RR_D0,x
    ora #$4000
    sta f:REC_BASE+RR_D0,x
    ldx k2_er
    lda f:REC_BASE+RR_D0,x
    ora #$4000
    sta f:REC_BASE+RR_D0,x
    jsr K2YMask             ; (the regions' rows on the lines above: hidden)
    jsr OhbPaint
    jmp OhbLines

; K2Piece: A = set * 2 (0 S, 2 N), w_i = piece offset: its lines' values
K2Piece:
    sta w_v
    asl a
    tax
    lda k2_img,x            ; (the set's left image)
    jsr K2Img
    lda f:OHB_KG+K_FL
    beq :+
    lda f:OHB_KG+K_XA
    sec                     ; (right to left: its right edge on the anchor)
    sbc w_w
    inc a
    bra :++
:   lda f:OHB_KG+K_XA
:   ldx w_v
    clc
    adc k2_pdx,x
    sta w_x                 ; (left image x)
    lda w_v
    asl a
    tax
    lda k2_img+2,x          ; (right image)
    jsr K2Img
    ldx w_v
    lda k2_pcr,x
    asl a
    asl a
    asl a
    clc
    adc w_x
    clc
    adc w_w
    dec a
    sta w_u+2               ; (the right image's right end)
    lda w_x
    sta w_u
    jsr OhbWin
    ldx w_i
    sta f:OHB_A+P_WIN,x
    lda w_x
    eor #$FFFF
    inc a
    and #$03FF
    sta f:OHB_A+P_HOFS,x    ; (the left image's column 0 at map column 0)
    lda f:OHB_KG+K_TOP
    sta f:OHB_A+P_TOP,x
    clc
    adc f:OHB_KG+K_HE
    sta w_t+2
    sec
    sbc ohb_lim
    bvc :+
    eor #$8000
:   bmi :+
    lda ohb_lim
    sta w_t+2
:   lda w_t+2
    bpl :+
    lda #0
:   sta f:OHB_A+P_BOT,x
    ldy w_v
    lda k2_pstep,y
    sta f:OHB_A+P_STEP,x
    lda k2_pb0,y
    asl a
    asl a
    asl a
    asl a
    sta f:OHB_A+P_RB,x      ; (rows above the first band: its first)
    sta w_t+2
    lda k2_reg              ; VOFS base: the region's first map row - rb - 1
    cpy #0
    beq :+
    eor #1
:   and #1
    beq :+
    lda #K2_ROWS*8
:   sec
    sbc w_t+2
    dec a
    sta f:OHB_A+P_VB,x
    lda #1
    sta f:OHB_A+P_DRAWN,x
    rts

; K2Bank: a scenery bank holding no stage (its palettes free) -> k2_bank
; (bank * 2); a new one: what is resident goes (the map entries carry the
; palette); C set: none
K2Bank:
    ldx k2_bank
    bmi @pick
    lda bank_sid,x
    and #$00FF
    cmp #$00FF
    beq @ok
@pick:
    ldx #0
@b: lda bank_sid,x
    and #$00FF
    cmp #$00FF
    beq @new
    inx
    inx
    cpx #4
    bcc @b
    jsr OhbK2Free
    sec
    rts
@new:
    phx
    jsr OhbK2Free
    plx
    stx k2_bank
    lda #$FFFF
    sta k2_pal
@ok:
    clc
    rts

; K2Geom: X = record offset, A = half (0 / 32): CandRaw's exact geometry
; -> OHB_KG; C set: not drawn / mirrored (not supported)
K2Geom:
    pha                     ; (half)
    phx                     ; (record offset)
    jsr CandRaw
    plx
    ply
    bcc :+
    rts
:   lda w_mir
    beq :+
    sec
    rts
:   txa                     ; (entry * 2: its palette)
    lsr a
    lsr a
    lsr a
    tax
    lda f:hw_pal,x
    and #$00FF
    tyx
    sta f:OHB_KG+K_PAL,x
    lda w_img
    sta f:OHB_KG+K_IMG,x
    lda w_he
    bne :+
    inc a
:   sta f:OHB_KG+K_HE,x
    lda w_top
    sta f:OHB_KG+K_TOP,x
    lda w_xa
    sta f:OHB_KG+K_XA,x
    lda w_rtl
    sta f:OHB_KG+K_FL,x
    clc
    rts

; K2Img: A = image -> ip (its record), bp (its blob: per band the first
; piece, then the pieces' x), w_nb, w_npc (pieces), w_xso, w_w, w_h,
; w_src / w_srcb (its pixels, as ClaimPass); X kept
K2Img:
    sta w_img
    xba
    lsr a
    lsr a
    lsr a
    and #$001F
    clc
    adc #SPR_IMGB
    sep #$20
    .a8
    sta ip+2
    rep #$20
    .a16
    lda w_img
    asl a
    asl a
    asl a
    asl a
    ora #$8000
    sta ip
    lda [ip]
    sta w_w
    ldy #2
    lda [ip],y
    sta w_h
    ldy #4
    lda [ip],y
    sta w_nb
    inc a
    asl a
    sta w_xso
    ldy #6
    lda [ip],y
    sta bp
    ldy #8
    lda [ip],y
    sep #$20
    .a8
    sta bp+2
    rep #$20
    .a16
    ldy #14
    lda [ip],y
    sta w_npc
    ldy #10
    lda [ip],y
    sta w_src
    ldy #12
    lda [ip],y
    and #$00FF
    sta w_srcb
    ldy #9
    lda [ip],y
    and #$0007
    ora #$0080
    xba
    tsb w_srcb
    rts

; K2Start: nothing loading, no hold: when both wanted images differ from
; the shown ones (the halves change levels together), set N: the images,
; rows and bands (the taller half's), the right image's map column offset
; and the x shift, the first band on screen; their scans from it.  Not
; when an image has more than K2_NPMAX pieces (S stays)
K2Start:
    lda k2_hold
    bne @r
    lda k2_clr              ; (no level while the rows are being cleared)
    bpl @r
    lda k2_nimg
    cmp #$FFFF
    bne @r                  ; (one loading)
    lda f:OHB_KG+K_IMG
    cmp k2_img
    beq @r
    lda f:OHB_KG+32+K_IMG
    cmp k2_img+2
    beq @r
    lda f:OHB_KG+32+K_IMG   ; the right image: width, rows, bands
    jsr K2Img
    lda w_npc
    cmp #K2_NPMAX+1
    bcs @r
    lda w_w
    sta w_we
    lda w_h
    sta w_he
    lda w_nb
    sta w_hx
    lda f:OHB_KG+K_IMG      ; the left one
    jsr K2Img
    lda w_npc
    cmp #K2_NPMAX+1
    bcc :+
@r: rts
:   lda w_h
    cmp w_he
    bcs :+
    lda w_he
:   sta k2_ph+2
    lda w_nb
    cmp w_hx
    bcs :+
    lda w_hx
:   sta k2_pnb+2
    ; x of the images (anchored as the landmark sprites) -> xr - xl
    lda f:OHB_KG+K_FL
    beq :+
    lda f:OHB_KG+K_XA
    sec
    sbc w_w
    inc a
    bra :++
:   lda f:OHB_KG+K_XA
:   sta w_x                 ; (xl)
    lda f:OHB_KG+32+K_FL
    beq :+
    lda f:OHB_KG+32+K_XA
    sec
    sbc w_we
    inc a
    bra :++
:   lda f:OHB_KG+32+K_XA
:   sec
    sbc w_x
    sta w_t                 ; (xr - xl)
    ; cR = round((xr - xl) / 8), at most the left image's last column - 1:
    ; the halves' edges at the seam are transparent (1-2 px; the arcade
    ; overlaps them); the left image is written over the right one but for
    ; its columns from its last one on (K2MapBand): no gap
    clc
    adc #4
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    sta w_gmin
    lda w_w
    dec a
    lsr a
    lsr a
    lsr a
    dec a
    sta w_gmax              ; (the left image's last column - 1)
    sec
    sbc w_gmin
    bvc :+
    eor #$8000
:   bpl :+
    lda w_gmax
    sta w_gmin
:   lda w_gmin
    sta k2_pcr+2
    asl a
    asl a
    asl a
    sta w_t+2
    lda w_t
    sec
    sbc w_t+2
    cmp #$8000
    ror a
    sta k2_pdx+2            ; (half the snapping error: the banner moves by it)
    ; the first band on screen
    lda k2_ph+2
    sta w_h
    lda f:OHB_KG+K_TOP
    sta w_y
    lda f:OHB_KG+K_HE
    sta w_hx
    stz w_b
@fv:
    lda w_b
    cmp k2_pnb+2
    bcs @fvn
    jsr K2BVis
    lda w_vb
    bne @fvd
    inc w_b
    bra @fv
@fvn:
    stz w_b                 ; (none: from band 0, all left out)
@fvd:
    lda w_b
    sta k2_pb0+2
    sta k2_ndone
    sta k2_nrel
    lda f:OHB_KG+K_IMG
    sta k2_nimg
    lda f:OHB_KG+32+K_IMG
    sta k2_nimg+2
    stz k2_cnt
    stz k2_cnt+2
    stz k2_blk
    stz k2_split
    lda #0
    jsr K2Seek
    lda #2
    jmp K2Seek

; K2Seek: A = half * 2: its N scan from the first piece of band k2_ndone
; (the pieces before it left out)
K2Seek:
    sta w_v
    tax
    lda k2_nimg,x
    jsr K2Img
    lda k2_ndone
    cmp w_nb
    bcc :+
    lda w_npc
    bra :++
:   asl a
    tay
    lda [bp],y
:   sta w_b0
    ldx w_v
    sta k2_nld,x
    lda K2Set+4,x
    sta w_t+2
    ldy w_b0
@f: dey
    bmi @r
    tya
    asl a
    clc
    adc w_t+2
    tax
    lda #$FFFF
    sta f:OHB_KQ,x
    bra @f
@r: rts

; K2Load: N's bands from k2_ndone on: per band both halves' pieces (those
; on screen load, the others left out), then its map rows; all complete
; (or beyond the region's rows): promoted.  It stops at the frame's budget
; or when VRAM is full (S's bands going make room; K2_BLKMAX frames
; without: N goes, K2_HOLD frames before the next one)
K2Load:
    lda k2_nimg
    cmp #$FFFF
    bne :+
    rts
:   lda k2_nimg             ; the images' x (as K2Piece)
    jsr K2Img
    lda f:OHB_KG+K_FL
    beq :+
    lda f:OHB_KG+K_XA
    sec
    sbc w_w
    inc a
    bra :++
:   lda f:OHB_KG+K_XA
:   clc
    adc k2_pdx+2
    sta w_gmax              ; (left image x)
    lda k2_pcr+2
    asl a
    asl a
    asl a
    clc
    adc w_gmax
    sta w_gmin              ; (right image x)
@band:
    lda f:OHB_KG+K_TOP      ; (K2BVis: K2MapBand takes w_hx)
    sta w_y
    lda f:OHB_KG+K_HE
    sta w_hx
    lda k2_ndone
    cmp k2_pnb+2
    bcs @all
    sec
    sbc k2_pb0+2
    cmp #K2_ROWS/2
    bcs @all                ; (beyond the region's rows: left out)
    lda k2_ndone
    sta w_b
    lda k2_ph+2
    sta w_h
    jsr K2BVis
    lda w_vb
    sta w_i                 ; (the band on screen)
    lda #0
    jsr K2Scan
    bcs @stop
    lda #2
    jsr K2Scan
    bcs @stop
    jsr K2MapBand
    inc k2_ndone
    bra @band
@stop:
    rts
@all:
    jmp K2Promote

; K2Scan: A = half * 2: N's pieces of band w_b (w_i: on screen) from
; k2_nld; C set: stopped (budget, VRAM)
K2Scan:
    sta w_v
    tax
    lda k2_nimg,x
    jsr K2Img
    lda #$7FFF              ; (the left image: its pieces from its last column
    ldx w_v                 ; on are not written: not loaded)
    bne :+
    lda w_w
    dec a
    lsr a
    lsr a
    lsr a
:   sta w_kk
    lda w_b                 ; (the band's end: the next one's first piece)
    inc a
    cmp w_nb
    beq :+
    bcc :+
    lda w_npc
    bra :++
:   asl a
    tay
    lda [bp],y
:   sta w_b1
    lda w_gmax
    ldx w_v
    beq :+
    lda w_gmin
:   sta w_x
@p: ldx w_v
    lda k2_nld,x
    cmp w_b1
    bcs @done
    sta w_b0
    lda w_i
    beq @off                ; (the band off screen)
    lda w_b0
    asl a
    clc
    adc w_xso
    tay
    lda [bp],y              ; (its x offset)
    pha
    lsr a
    lsr a
    lsr a
    cmp w_kk
    pla
    bcs @off
    clc
    adc w_x
    clc
    adc #23                 ; (x in [-23, 263]: 8 px margin)
    cmp #287
    bcs @off
    lda w_k                 ; on screen: loaded (this frame's budget)
    beq @stop
    ldx w_v
    lda k2_cnt,x
    cmp #K2_MAXP
    bcs @full
    jsr OtQuadGet
    bcs @full
    sta w_t                 ; (its quad)
    lda w_b0
    jsr K2Fifo              ; (piece w_b0 -> quad w_t)
    ldx w_v
    inc k2_cnt,x
    dec w_k
    stz k2_blk
    lda w_t
    bra @set
@off:
    lda #$FFFF
@set:
    pha
    lda w_b0
    asl a
    ldx w_v
    clc
    adc K2Set+4,x
    tax
    pla
    sta f:OHB_KQ,x
    ldx w_v
    inc k2_nld,x
    bra @p
@done:
    clc
    rts
@stop:
    sec
    rts
@full:
    lda #1                  ; (from now N's complete bands show, S's above go)
    sta k2_split
    inc k2_blk
    ; Single-tile scenery allocations can succeed while every aligned
    ; quad is fragmented. They won't trigger CacheGet's hidden-column
    ; eviction, so request it here when a stationary banner first stalls.
    lda game_state
    cmp #GS_BONUS
    bne :+
    lda k2_blk
    cmp #1
    bne :+
    jsr OtFreeHidden
:
    lda k2_blk
    cmp #K2_BLKMAX
    bcc @stop
    ; A stationary GOAL banner cannot scroll its old bands offscreen to
    ; free their quads. Release that held level too, otherwise every retry
    ; deadlocks on the same first band and the banner stays half-sized.
    ; Until the replacement is complete, the original halves use OBJ.
    lda game_state
    cmp #GS_BONUS
    bne :+
    jsr OhbK2Free
    bra @hold
:
    jsr K2AbortN
@hold:
    lda #K2_HOLD
    sta k2_hold
    sec
    rts

; K2BVis: band w_b of an image (w_h rows) stretched to the lines w_y + row
; * w_hx / w_h -> w_vb = 1 when they meet [0, ohb_lim)
K2BVis:
    stz w_vb
    lda w_b
    inc a
    asl a
    asl a
    asl a
    asl a
    jsr @line               ; (the line after its last row)
    beq @r
    bmi @r                  ; (above the screen)
    lda w_b
    asl a
    asl a
    asl a
    asl a
    jsr @line               ; (the line of its first row)
    sec
    sbc ohb_lim
    bvc :+
    eor #$8000
:   bpl @r                  ; (below the lines)
    inc w_vb
@r: rts
@line:
    sta MAL
    lda w_hx
    sta MBL
    nop
    nop
    lda MR
    ldx w_h
    jsr SDiv16u
    clc
    adc w_y
    rts

; K2MapBand: band k2_ndone of N -> its map rows (region 1 - k2_reg: FG map
; rows 10 R + 2 (b - b0), + 1, both screens), swap queue
K2MapBand:
    lda k2_reg
    eor #1
    sta w_t+2               ; (region)
    lda k2_ndone
    sec
    sbc k2_pb0+2
    xba
    lsr a                   ; (* 128: two rows)
    sta w_xo
    lda w_t+2
    beq :+
    lda #K2_ROWS*64
:   clc
    adc w_xo
    sta w_xo                ; (staging offset of the band's rows, screen 0)
    tax                     ; (cleared: both screens)
    ldy #64
    lda #0
:   sta f:OHB_MAPB,x
    sta f:OHB_MAPB+K2_SCR,x
    inx
    inx
    dey
    bne :-
    lda k2_bank             ; entry bits: palette 2 + bank * 2, priority 1
    clc
    adc #2
    xba
    asl a
    asl a
    ora #$2000
    sta w_xa
    lda k2_pcr+2            ; the right image (column offset cR), then the
    sta w_vb                ; left one over it
    lda #2
    jsr @img
    stz w_vb
    lda #0
    jsr @img
    lda #.loword(OHB_MAPB)  ; swap queue: screen 0 rows, screen 1 rows
    clc
    adc w_xo
    sta ptr0
    sep #$20
    .a8
    lda #^OHB_MAPB
    sta ptr0+2
    rep #$20
    .a16
    lda w_t+2
    beq :+
    lda #K2_ROWS*32
:   sta w_t
    lda k2_ndone
    sec
    sbc k2_pb0+2
    asl a
    asl a
    asl a
    asl a
    asl a
    asl a                   ; (* 64 words: two rows)
    clc
    adc w_t
    clc
    adc #VR_FGMAP
    sta w_t
    tax
    lda #BL_VRAM
    ldy #128
    jsr QueueUpload
    lda ptr0
    clc
    adc #K2_SCR
    sta ptr0
    lda w_t
    clc
    adc #$400
    tax
    lda #BL_VRAM
    ldy #128
    jsr QueueUpload
    lda #1
    sta k2_dirty
    lda w_t                 ; (the band's second row: (dest - VR_FGMAP) / 32 + 1)
    sec
    sbc #VR_FGMAP
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    inc a
    cmp k2_maxrow
    bmi :+
    beq :+
    sta k2_maxrow
:   rts
; @img: A = half * 2 of N: its pieces of band k2_ndone -> the staging
@img:
    sta w_v
    tax
    lda k2_nimg,x
    jsr K2Img
    lda w_w                 ; (the left image's last column: from it on not written)
    dec a
    lsr a
    lsr a
    lsr a
    sta w_kk
    ldx w_v
    lda K2Set+4,x
    sta w_top               ; (its quads)
    lda k2_ndone
    cmp w_nb
    bcc :+
    rts                     ; (no such band)
:   asl a
    tay
    lda [bp],y
    sta w_b0
    iny
    iny
    lda [bp],y
    sta w_b1
@pc:
    lda w_b0
    cmp w_b1
    bcs @ir
    asl a
    clc
    adc w_top
    tax
    lda f:OHB_KQ,x
    cmp #$FFFF
    beq @pn                 ; (not loaded: off screen)
    clc
    adc #VR_SCNT >> 4
    ora w_xa
    sta w_he                ; (its top-left map entry)
    lda w_b0
    asl a
    clc
    adc w_xso
    tay
    lda [bp],y              ; (its x: a multiple of 16)
    lsr a
    lsr a
    lsr a
    clc
    adc w_vb
    sta w_hx                ; (union column of its left tile)
    jsr @col
    inc w_hx
    inc w_he
    jsr @col
@pn:
    inc w_b0
    bra @pc
@ir:
    rts
@col:
    lda w_v
    bne :+
    lda w_hx
    cmp w_kk
    bpl @cr
:   lda w_hx
    and #63                 ; (map column)
    pha
    and #32
    beq :+
    lda #K2_SCR
:   sta w_t
    pla
    and #31
    asl a
    clc
    adc w_t
    clc
    adc w_xo
    tax
    lda w_he
    sta f:OHB_MAPB,x
    clc
    adc #16
    sta f:OHB_MAPB+64,x
@cr:
    rts

; K2Promote: N complete (the pieces not scanned left out): S's quads go,
; N is S (its region shown)
K2Promote:
    jsr K2FreeS
    lda #0
    jsr @half
    lda #2
    jsr @half
    lda k2_pb0+2
    sta k2_pb0
    lda k2_pcr+2
    sta k2_pcr
    lda k2_pdx+2
    sta k2_pdx
    lda k2_ph+2
    sta k2_ph
    lda k2_pnb+2
    sta k2_pnb
    lda k2_reg
    eor #1
    sta k2_reg
    lda k2_nrel             ; (N's bands above the screen went already)
    sta k2_srel
    stz k2_split
    lda #$FFFF
    sta k2_nimg
    sta k2_nimg+2
    rts
@half:
    sta w_v
    tax
    lda k2_nimg,x
    sta k2_img,x
    jsr K2Img
@f: ldx w_v                 ; (the pieces not scanned: left out)
    lda k2_nld,x
    cmp w_npc
    bcs @cp
    asl a
    clc
    adc K2Set+4,x
    tax
    lda #$FFFF
    sta f:OHB_KQ,x
    ldx w_v
    inc k2_nld,x
    bra @f
@cp:
    lda K2Set,x
    sta w_t
    lda K2Set+4,x
    sta w_t+2
    ldy w_npc
@c: dey
    bmi @r
    tya
    asl a
    tax
    phx
    clc
    adc w_t+2
    tax
    lda f:OHB_KQ,x
    plx
    pha
    txa
    clc
    adc w_t
    tax
    pla
    sta f:OHB_KQ,x
    bra @c
@r: rts

; K2FreeS: S's quads (those left) go
K2FreeS:
    lda #0
    jsr @h
    lda #2
@h: sta w_v
    tax
    lda k2_img,x
    cmp #$FFFF
    beq @r
    jsr K2Img
    ldx w_v
    lda K2Set,x
    sta w_t+2
    ldy w_npc
    jmp K2FreeQ
@r: rts

; K2AbortN: N's loaded quads go, no N
K2AbortN:
    lda #0
    jsr @h
    lda #2
    jsr @h
    lda #$FFFF
    sta k2_nimg
    sta k2_nimg+2
    stz k2_split
    rts
@h: sta w_v
    tax
    lda k2_nimg,x
    cmp #$FFFF
    beq @r
    lda K2Set+4,x
    sta w_t+2
    ldy k2_nld,x
    jmp K2FreeQ
@r: rts

; K2FreeQ: the quads of the pieces 0..Y-1 of the map at OHB_KQ + w_t+2 go
; ($FFFF after)
K2FreeQ:
@f: dey
    bmi @r
    phy
    tya
    asl a
    clc
    adc w_t+2
    tax
    lda f:OHB_KQ,x
    cmp #$FFFF
    beq :+
    pha
    lda #$FFFF
    sta f:OHB_KQ,x
    pla
    jsr OtQuadPut
:   ply
    bra @f
@r: rts

; K2Release: the steps (k2_pstep), the split line (k2_ysp: N's complete
; bands end there); S's bands whose rows no line shows any more (above the
; split line or the screen) go
K2Release:
    lda f:OHB_KG+K_HE
    tax
    lda k2_ph
    xba
    jsr SDiv16u
    sta k2_pstep
    lda f:OHB_KG+K_TOP
    sta k2_ysp
    lda k2_nimg
    cmp #$FFFF
    beq @rel
    lda f:OHB_KG+K_HE
    tax
    lda k2_ph+2
    xba
    jsr SDiv16u
    sta k2_pstep+2
    lda k2_split            ; (S shown whole until VRAM is short)
    beq @rel
    lda k2_ndone            ; split: top + ceil(16 done * HE / rows_N)
    asl a
    asl a
    asl a
    asl a
    sta MAL
    lda f:OHB_KG+K_HE
    sta MBL
    nop
    nop
    lda MR
    clc
    adc k2_ph+2
    dec a
    ldx k2_ph+2
    jsr SDiv16u
    clc
    adc f:OHB_KG+K_TOP
    sta k2_ysp
@rel:
    ; S's first row shown: (max(ysp, 0) - top) * step_S >> 8
    lda k2_ysp
    bpl :+
    lda #0
:   sec
    sbc f:OHB_KG+K_TOP
    bpl :+
    lda #0
:   sta MAL
    lda k2_pstep
    sta MBL
    nop
    nop
    lda MR+2
    beq :+
    lda #$7FFF
    bra :++
:   lda MR+1
:   sta w_t
@b: lda k2_srel
    cmp k2_pnb
    bcs @r
    inc a
    asl a
    asl a
    asl a
    asl a
    cmp w_t
    beq :+
    bcs @r                  ; (its rows still shown)
:   lda k2_srel
    ldx #0
    jsr K2RelBand
    inc k2_srel
    bra @b
@r:
    ; N's complete bands above the screen go too (VRAM for its next ones)
    lda k2_nimg
    cmp #$FFFF
    beq @rn
    lda f:OHB_KG+K_TOP
    eor #$FFFF
    inc a                   ; (- top: N's lines from 0)
    bmi @rn
    sta MAL
    lda k2_pstep+2
    sta MBL
    nop
    nop
    lda MR+2
    beq :+
    lda #$7FFF
    bra :++
:   lda MR+1
:   sta w_t                 ; (N's first row on screen)
@nb:
    lda k2_nrel
    cmp k2_ndone
    bcs @rn
    inc a
    asl a
    asl a
    asl a
    asl a
    cmp w_t
    beq :+
    bcs @rn
:   lda k2_nrel
    ldx #4
    jsr K2RelBand
    inc k2_nrel
    bra @nb
@rn:
    rts

; K2RelBand: A = band, X = set * 4 (0 S, 4 N): its pieces' quads go (both
; halves)
K2RelBand:
    sta w_b
    stx w_obj
    lda #0
    jsr @h
    lda #2
@h: sta w_v
    clc
    adc w_obj
    tax
    lda k2_img,x
    jsr K2Img
    lda w_b
    cmp w_nb
    bcs @r
    asl a
    tay
    lda [bp],y
    sta w_b0
    iny
    iny
    lda [bp],y
    sta w_b1
    lda w_v
    clc
    adc w_obj
    tax
    lda K2Set,x
    sta w_t+2
@f: lda w_b0
    cmp w_b1
    bcs @r
    asl a
    clc
    adc w_t+2
    tax
    lda f:OHB_KQ,x
    cmp #$FFFF
    beq :+
    pha
    lda #$FFFF
    sta f:OHB_KQ,x
    pla
    jsr OtQuadPut
:   inc w_b0
    bra @f
@r: rts

; K2Fifo: A = piece of the image in ip / bp, w_t = quad slot: one sprite run
; (top halves to the quad's first slot, bottom halves 16 tiles further)
K2Fifo:
    sta w_u                 ; (piece)
    ldy #2                  ; band: the first one whose next first piece > it
@b: lda [bp],y
    cmp w_u
    beq :+
    bcs @fb
:   iny
    iny
    bra @b
@fb:
    sta w_u+2               ; (next band's first piece)
    dey
    dey
    lda [bp],y              ; (this band's first piece)
    sta w_gn
    jsr FifoWait
    lda SH_UQW
    asl a
    asl a
    asl a
    tax
    lda w_t
    asl a
    asl a
    asl a
    asl a
    clc
    adc #VR_SCNT
    sta f:UQ_BUF+UQ_DEST,x
    lda w_gn                ; top halves: data + 64 * (band first + piece)
    clc
    adc w_u
    asl a
    asl a
    asl a
    asl a
    asl a
    asl a
    clc
    adc w_src
    sta f:UQ_BUF+UQ_SRC,x
    lda w_srcb
    sta f:UQ_BUF+UQ_BANK,x
    lda w_u+2
    sec
    sbc w_gn                ; band pieces << 10 | 64 bytes
    xba
    asl a
    asl a
    ora #64
    sta f:UQ_BUF+UQ_SIZE,x
    lda SH_UQW
    inc a
    and #UQ_MASK
    sta SH_UQW
    lda ohb_dma
    clc
    adc #128+RUN_OVH
    sta ohb_dma
    rts

; K2Pal: palette 2 + 2 * bank <- SprPal[the left half's pal_src] (swap queue)
K2Pal:
    lda f:OHB_KG+K_PAL
    cmp k2_pal
    bne :+
    rts
:   sta k2_pal
    xba
    lsr a
    lsr a
    lsr a                   ; * 32
    clc
    adc #.loword(SprPal)
    sta ptr0
    sep #$20
    .a8
    lda #^SprPal
    sta ptr0+2
    rep #$20
    .a16
    lda k2_bank
    asl a
    asl a
    asl a
    asl a
    adc #32                 ; (C = 0) CGRAM (2 + 2 * bank) * 16
    tax
    lda #BL_CGRAM
    ldy #32
    jmp QueueUpload

; OhbK2Free: the banner's quads released (S and N), the regions' map rows
; cleared (when they hold entries)
OhbK2Free:
    jsr K2AbortN
    jsr K2FreeS
    lda #$FFFF
    sta k2_img
    sta k2_img+2
    sta k2_bank
    stz k2_idle
    lda k2_dirty            ; (the rows: cleared K2_CLRN a frame, masked meanwhile -
    beq :+                  ; one swap of 2.5 KB would take a forced blank)
    lda k2_clr
    bpl :+
    stz k2_clr
:   rts

; K2Clear: (clearing) rows k2_clr..+K2_CLRN-1 of both screens cleared (swap
; queue); all of them: the regions hold nothing
K2Clear:
    lda k2_clr
    bpl :+
    rts
:   asl a
    asl a
    asl a
    asl a
    asl a
    asl a                   ; (row * 64: its staging offset)
    tax
    ldy #K2_CLRN*32
    lda #0
:   sta f:OHB_MAPB,x
    sta f:OHB_MAPB+K2_SCR,x
    inx
    inx
    dey
    bne :-
    lda k2_clr
    asl a
    asl a
    asl a
    asl a
    asl a
    asl a
    clc
    adc #.loword(OHB_MAPB)
    sta ptr0
    sep #$20
    .a8
    lda #^OHB_MAPB
    sta ptr0+2
    rep #$20
    .a16
    lda k2_clr
    asl a
    asl a
    asl a
    asl a
    asl a
    clc
    adc #VR_FGMAP
    pha
    tax
    lda #BL_VRAM
    ldy #K2_CLRN*64
    jsr QueueUpload
    lda ptr0
    clc
    adc #K2_SCR
    sta ptr0
    pla
    clc
    adc #$400
    tax
    lda #BL_VRAM
    ldy #K2_CLRN*64
    jsr QueueUpload
    lda k2_clr
    clc
    adc #K2_CLRN
    sta k2_clr
    cmp #2*K2_ROWS
    bcs :+
    dec a
    cmp k2_maxrow
    bmi @r
    beq @r
:   lda #$FFFF              ; (done)
    sta k2_clr
    sta k2_maxrow
    stz k2_dirty
@r: rts

;----------------------------------------------------------------------------
; OhbLoad: the texture of set ohb_fset (OhbSetPar's parameters): ohb_tn
; slots, their tiles (FIFO, ROM -> VRAM), the map rows (swap queue); C set
; when the slots are not there
;----------------------------------------------------------------------------
OhbLoad:
    lda ohb_tn
    asl a
    sta w_k                 ; (tiles * 2)
    ldy #0
@s:
    phy
    jsr OtSlotGet
    ply
    bcc :+
    jmp @fail
:   tyx
    sta f:OHB_SLOT,x
    iny
    iny
    cpy w_k
    bcc @s
    ; tiles
    ldy #0
@t:
    phy
    jsr FifoWait
    ply
    lda SH_UQW
    asl a
    asl a
    asl a
    tax
    phx
    tyx
    lda f:OHB_SLOT,x
    plx
    asl a
    asl a
    asl a
    asl a
    clc
    adc #VR_SCNT
    sta f:UQ_BUF+UQ_DEST,x
    tya
    asl a
    asl a
    asl a
    asl a                   ; tile * 32
    clc
    adc ohb_tex
    sta f:UQ_BUF+UQ_SRC,x
    lda ohb_texb
    sta f:UQ_BUF+UQ_BANK,x
    lda #32
    sta f:UQ_BUF+UQ_SIZE,x
    lda SH_UQW
    inc a
    and #UQ_MASK
    sta SH_UQW
    iny
    iny
    cpy w_k
    bcc @t
    ; map rows 0..TH-1 of both screens: tile (row, col mod TW)
    stz w_t                 ; row
@mr:
    stz w_t+2               ; column (0-63)
    stz w_u                 ; (column mod TW)
@mc:
    lda w_t                 ; texture tile = row * TW + col mod TW
    sta MAL
    lda ohb_tw
    sta MBL
    nop
    nop
    lda MR
    clc
    adc w_u
    asl a
    tax
    lda f:OHB_SLOT,x
    clc
    adc #(VR_SCNT >> 4) | OHB_MAPW
    pha
    ; screen (col >> 5) * TH * 64 + row * 64 + (col & 31) * 2
    lda w_t+2
    and #32
    beq :+
    lda ohb_th
    xba
    lsr a
    lsr a                   ; TH * 64
:   sta w_u+2
    lda w_t
    xba
    lsr a
    lsr a                   ; row * 64
    clc
    adc w_u+2
    sta w_u+2
    lda w_t+2
    and #31
    asl a
    adc w_u+2               ; (C = 0)
    tax
    pla
    sta f:OHB_MAPB,x
    inc w_u
    lda w_u
    cmp ohb_tw
    bcc :+
    stz w_u
:   inc w_t+2
    lda w_t+2
    cmp #64
    bcc @mc
    inc w_t
    lda w_t
    cmp ohb_th
    bcc @mr
    jsr OhbMapUp
    lda #1
    sta ohb_res
    lda ohb_fset
    sta ohb_set
    stz ohb_idle
    lda #$FFFF
    sta ohb_pal             ; (the palette is sent with the first pieces)
    clc
    rts
@fail:
    ; give the slots taken back
@fr:
    dey
    dey
    bmi :+
    phy
    tyx
    lda f:OHB_SLOT,x
    jsr OtSlotPut
    ply
    bra @fr
:   sec
    rts

; OhbMapUp: OHB_MAPB -> FG map rows 0..TH-1 of screens 0 / 1 (swap queue)
OhbMapUp:
    lda #.loword(OHB_MAPB)
    sta ptr0
    sep #$20
    .a8
    lda #^OHB_MAPB
    sta ptr0+2
    rep #$20
    .a16
    lda ohb_th
    xba
    lsr a
    lsr a
    sta w_k                 ; (TH * 64 bytes a screen)
    tay
    lda #BL_VRAM
    ldx #VR_FGMAP
    jsr QueueUpload
    lda #.loword(OHB_MAPB)
    clc
    adc w_k
    sta ptr0
    ldy w_k
    lda #BL_VRAM
    ldx #VR_FGMAP+$400
    jmp QueueUpload

;----------------------------------------------------------------------------
; OhbUnload: the texture goes: its slots released, the map rows cleared
;----------------------------------------------------------------------------
OhbUnload:
    lda ohb_tn
    asl a
    tay
:   dey
    dey
    bmi :+
    tyx
    lda f:OHB_SLOT,x
    phy
    jsr OtSlotPut
    ply
    bra :-
:   ldx #OHB_THMAX*64*2-2
    lda #0
:   sta f:OHB_MAPB,x
    dex
    dex
    bpl :-
    jsr OhbMapUp
    stz ohb_res
    stz ohb_idle
    lda #$FFFF
    sta ohb_pal
    sta ohb_set
    rts

.segment "RODATA"
K2Set:  .word 0, K2_NPMAX*2, 2*K2_NPMAX*2, 3*K2_NPMAX*2   ; K2 quad sets: shown L / R, loading L / R
.segment "SA1CODE"

OhbRoadLate:
    lda arch_posted
    bne @sent
    lda arch_count
    rts
@sent:
    lda #0
    rts
