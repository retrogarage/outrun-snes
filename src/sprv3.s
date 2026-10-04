; SNES sprite backend v3 (engine port): draws the arcade hardware sprite
; list (osprites.s sprite_entries, 7-word arcade entries, with hw_ent /
; hw_src / hw_pal) with OBJ, from images pre-shrunk offline
; (tools/mksprv3.py): the SA-1 does no pixel work, the S-CPU DMAs the
; pieces straight from ROM to VRAM in vblank (main.s UqStream).
;
; - Image = one arcade frame descriptor (hw_src, rom0 $F236-$11ED1) at a
;   stored zoom level, horizontal scale 0.8, arcade colour indices, mode
;   0 normal / 1 shadow sprite (every opaque pixel = shadow) / 2 hw shadow
;   bit (colour 10 = shadow); shadow pixels = colour 15, checkerboard.
;   Descriptor record -> map (zoom index -> nearest stored level) -> image.
;   The image is centred horizontally / bottom-anchored on the exact size
;   (width npx * 512 / hz * 0.8, height rows * 512 / hz); mirrored frames
;   (read direction XOR draw direction) use the OBJ h-flip.
; - An image is cut into bands of 16 rows, a band into 16x16 pieces (x
;   offsets in the image's blob).  A piece lives in one VRAM cell (16x16,
;   128 cells); resident images have a slot with a piece -> cell map.
;   Missing pieces are allocated as runs of consecutive cells of one cell
;   row: one FIFO entry (two DMAs) per run.
; - [W1b] Placement by importance, not depth (temporal stability): the car
;   group first (the car itself first), then the others (seniors: shown
;   AGE_S frames in a row, landmarks, traffic; juniors: shown / loading the
;   last frame; then the rest) by key = visible
;   area / 8 (x4 landmark frames: START / GOAL / CHECK banners, signal
;   tower, gantries, road split signs (descriptor class); x4 traffic; /4
;   shadow sprites), x2 when shown (or loading) the last frame, /4 while
;   dropped (ScanPass: the last frame's keys in buckets of half octaves,
;   depth order inside).  All OAM entries are staged and copied in depth
;   order at the end (arcade draw order reversed = OAM order).  An entry is
;   shown while the budgets hold: OAM entries, 34 slivers per screen line
;   (exact per line, 16-line bucket bounds skip most checks), 8 OBJ
;   palettes (a missing one takes the least recently used slot not used
;   now), VRAM cells (the displayed frame's cells are protected, CELL_RES
;   kept for the car group), ROM -> VRAM bytes (DMA_VBL per vblank of the
;   frame; the car group always gets its pieces).  So what was shown keeps
;   its budgets before new objects take the rest; an object shown the last
;   frame and refused now uses a bounded retry delay;
;   lacking cells, an object makes the shown ones after it (at most half as
;   important) give theirs up (sv_debt: they are dropped); an image too big
;   for the frame's DMA budget loads over several frames (ST_LOAD).
; - An object keeps its last image while that is resident and within about
;   two levels of the exact one (hysteresis: fewer uploads); when the exact
;   image does not fit (cells, DMA, slot) it shows its last image if that
;   is resident and close (the car group: any; shown the last frame: any
;   frame of it within +-50%).
; - Vertical clipping: the arcade's top clip (addr past the frame start)
;   is undone (the image's top above the screen), its bottom clip (road
;   elevation) masks the final band's hidden rows in temporary VRAM cells.
; - OAM order = arcade draw order reversed (front-most first).
.ifdef NEWGAME
.p816
.smart
.include "sa1.inc"
.include "shared.inc"
.include "globals.inc"
.include "ogame.inc"
.include "sprdat3.inc"
.include "sprrec.inc"                   ; (W3a: entry records, see CandGeom)

.import sprite_entries: far, hw_pal: far, hw_ent: far, hw_src: far
.import sprite_count, QueueUpload, scn_pmode, grid_people, grid_decor, arch_root, grid_warm
.import SDiv16u, FifoWait
.import SprWidthOfs, SprHeightOfs, SprSizes
.import fer_state, end_seq
.importzp ptr0

.export SprV2Init, SprV2Frame           ; (entry points: ngmain.s, tools/mesenprof.sh)
.export sv_stat, sv_frame, sv_back, slot_pal, sv_txtd
.ifdef SPRCHECK
.export SprChkEnt
.import sprchk_rec: far, in_tick
REC_BASE = sprchk_rec
.else
REC_BASE = sprite_entries
.endif

NCELL    = 128
NSLOT    = 80           ; resident images
MAXBAND  = 24           ; bands per image (tools/mksprv3.py: 20)
SLIVERS  = 34
CELL_RES = 12           ; cells left free by all but the car group
DMA_VBL  = 2560         ; ROM -> VRAM bytes per vblank of the frame (all but the car group)
RUN_OVH  = 96           ; S-CPU cost of a FIFO entry in DMA byte units
RUN_MAX  = 4            ; cells per upload run (512 bytes: UqStream starts it up to line 255)
DR       = $800000      ; descriptor records (bank $80, SPR_META page)
PNONE    = $FF          ; slot map: piece without a cell
; ---- BW-RAM bank $40 work areas: $408000-$40F8FF (sprv2's; free in
; NEWGAME builds, see shared.inc).  $40F900-$40FFFF is the text layer's BG3
; map (textlayer.s TL_MAP); bank $41 $D000-$FFFF holds the road arrays ----
SL_MAP   = $408000      ; per slot (256 bytes): piece -> cell (PNONE none)
ST_OAM   = $40E000      ; OAM entries of the priority entries (staged; x bit 8
                        ; as attribute bit 15)
TRAP_REC = $40E7F0      ; (SPRTRAP builds: the trap record, 12 bytes)
VC_OWN   = $40E800      ; per cell: slot << 8 | piece (= SL_MAP offset), $FFFF free
SL_IMG   = $40EA00      ; per slot: image ($FFFF free)
SL_STAMP = $40EAA0      ; per slot: frame last used
SL_NRES  = $40EB40      ; per slot: pieces with a cell
SL_NEXT  = $40EBE0      ; per slot: next slot of the hash chain + 1 (0 end)
SL_HASH  = $40EC80      ; 256 buckets (image & $FF): first slot + 1 (0 none)
LAST_IMG = $40EF80      ; per object (hw_ent value): last image shown ($FFFF none)
LAST_DSC = $40F180      ; ... its descriptor record
SV_FREE  = $40F380      ; free slot stack
SL_NP    = $40F420      ; per slot: pieces of its image
PAL_MAP  = $40F4C0      ; per pal_src: palette slot * 2 | $80 (loaded), 0 not loaded
PAL_W    = $40F5C0      ; [W1b] per pal_src (words): keys of its entries this frame
PAL_M    = $40F7C0      ; [W1b] per pal_src (bytes): the largest of them / 256
OB_KEY   = $40D000      ; [W1b] per object (hw_ent value, word): its sort key for the next
                        ; frame (0: not in the first tier)
OB_ST    = $40D200      ; [W1b] ... its state: frame & $FF | ST_* << 8
OB_DROP  = $40D400      ; [W1b] ... frame it was dropped
OB_PIMG  = $40D600      ; [W1b] ... image being loaded ($FFFF none)
ST_SHOWN = $01          ; [W1b] state: shown
ST_LOAD  = $02          ; ... loading an image (OB_PIMG) over several frames
ST_DROP  = $04          ; ... waiting for its bounded retry delay
ST_BIG   = $08          ; ... a landmark frame, traffic or people
                        ; (bits 4-7: frames shown in a row, 15 at most)
AGE_S    = 8            ; [W1b] shown this many frames in a row: senior
T1_MAX   = 64           ; [W1b] first tier entries (sorted by key) at most
OB_DN    = $40E200      ; [W1b] per object (byte): drops while on screen (cooldown x 2^n)
.assert OB_DN+256 <= SCENE_LAST, error, "scenery history overlaps drop counters"
.assert SCENE_LAST+SCENE_SIZE <= TRAP_REC, error, "scenery history overlaps sprite traps"
LINE_M   = 4            ; [W1b] admission (not shown the last frame): slivers a line
                        ; keeps free, cells (CELL_ADM more than CELL_RES)
CELL_ADM = 8
LARGE_KEY = 2048        ; [W1b] entries not shown from this key on: first tier (x 1)
DEBT_KEY = 512          ; [W1b] entries lacking cells from this key on make less
                        ; important ones (lower buckets) give theirs up
.assert SL_MAP + NSLOT * 256 <= OB_KEY, error, "SL_MAP overlaps"
.assert OB_PIMG + 512 <= $40D800, error, "OB_* overlap"
.assert TRAP_REC + 16 <= VC_OWN, error, "TRAP_REC overlaps"
.assert PAL_M + 256 <= $40F900, error, "bank $40 areas overlap the text layer map"

.segment "ZEROPAGE"
ip:     .res 3              ; image record pointer
bp:     .res 3              ; image blob pointer (band cumulative first pieces, piece x)
mp:     .res 3              ; map pointer
w_i:    .res 2
w_t:    .res 4
w_u:    .res 4
w_v:    .res 4
w_d0:   .res 2
w_d4:   .res 2
w_obj:  .res 2
w_dsc:  .res 2              ; descriptor record address (bank $80)
w_k:    .res 2              ; zoom index
w_img:  .res 2
w_x:    .res 2              ; image left edge
w_y:    .res 2              ; image top
w_b0:   .res 2
w_b1:   .res 2
w_b:    .res 2
w_w:    .res 2              ; image width
w_h:    .res 2              ; image height
w_nb:   .res 2              ; image bands
w_xso:  .res 2              ; blob offset of the piece x offsets
w_mir:  .res 2              ; $4000 mirrored
w_xm:   .res 2              ; mirrored: x of a piece = w_xm - its offset
w_rs:   .res 2              ; resident slot ($FFFF none)
w_npc:  .res 2              ; BandPass: pieces on screen
w_new:  .res 2              ; ... without a cell
w_runs: .res 2              ; ... runs of them
w_xa:   .res 2              ; exact geometry (Candidate / PlaceImg)
w_rtl:  .res 2
w_we:   .res 2
w_he:   .res 2
w_top:  .res 2
w_vb:   .res 2
w_gmin: .res 2              ; lines [w_gmin, w_gmax] (LinesOver / LinesAdd)
w_gmax: .res 2
w_gn:   .res 2              ; slivers per line
w_kk:   .res 2              ; LinesOver / LinesAdd: per-byte constant
w_jmp:  .res 2              ; LinesOver / LinesAdd: unrolled entry
sv_fr:  .res 2              ; sv_frame (direct page copy)
w_cls:  .res 2              ; CandGeom: mode (0 normal, 1 shadow sprite, 2 hw shadow bit)
w_ne:   .res 2              ; ClaimPass: 1 loading (claims/uploads only), 0 complete draw
w_exi:  .res 2              ; exact image of the entry
w_car:  .res 2              ; 1: car group entry
w_hx:   .res 2              ; height of the exact image (hysteresis)
w_xo:   .res 2              ; ClaimPass: blob offset of the piece's x
w_oi:   .res 2              ; OAM entries written
w_key:  .res 2              ; [W1b] Process: key of the entry
w_big:  .res 2              ; ... 1: landmark, 2: traffic, 3: people (KeyOf)
w_ob2:  .res 2              ; ... object * 2
w_prf:  .res 2              ; ... its first staged entry
w_x9:   .res 2              ; [W1b] ClaimPass: a staged entry has x bit 8
w_ost:  .res 2              ; ... its state of the last frame (ST_*)
w_nst:  .res 2              ; ... this frame's
w_short: .res 2             ; current band's cached short-height flag
w_full:  .res 2             ; the current slot has every image piece
w_disc:  .res 2             ; LinesAdd: OBJ discount, one byte per line
w_dpair: .res 2             ; LinesAdd: discount replicated in both bytes

; Per-piece claim/emission state: the last twelve bytes of direct page.
w_attr:     .res 2              ; ClaimPass: OAM attributes << 8 of the candidate
w_st:       .res 2              ; OAM write offset (bank $40)
w_y8:       .res 2              ; ... band y << 8
w_lastmo:   .res 2              ; ... SL_MAP offset past the pieces allocated now
w_mend:     .res 2              ; ... SL_MAP offset past the band's pieces on screen
w_mo:       .res 2              ; ... SL_MAP offset of the piece

.segment "BSS"
sv_frame:   .res 2              ; frame stamp (starts at 2)
sv_back:    .res 2              ; OAM buffer being built
slot_pal:   .res 16             ; palette slot -> pal_src ($FFFF none)
slot_stamp: .res 16
sv_statl:   .res 18             ; debug: sv_stat of the last frame, + DMA bytes queued
sv_txtd:    .res 2              ; (always 0: ngmain.s runs the text layer)
sv_why:     .res 128            ; debug: per hardware entry why it was not shown: 3 DMA
                                ; budget, 4 OAM, 5 lines, 6 cells, 7 palette, 8 no slot,
                                ; 9 no piece on screen, 10 gave its cells up, 11 dropped,
                                ; $80 shown, $81 shown (fallback image), $82 (hysteresis)
sv_lastf:   .res 2              ; SH_FRAME at the last SprV2Frame
PC_MAX = 12                     ; car group entries placed first
pc_idx:     .res PC_MAX*2
pc_rk:      .res PC_MAX*2       ; [W1b] ... their rank (CarRank)
w_ncar:     .res 2
pr_st:      .res 256            ; [W1b] per hw entry: its OAM entries staged: first | count << 8
pr_size:    .res 256         ; per hardware entry: 1 all 8px, 2 all 16px, 3 mixed
st_small:   .res 128         ; staged entry uses 8x8 instead of 16x16
parent_shown: .res 128          ; staged main objects; shadow copies need a parent
                                ; ($80: some have x bit 8); zero means no staged entry
t1_idx:     .res T1_MAX*2       ; [W1b] ScanPass: first tier (shown / loading the last
t1_key:     .res T1_MAX*2       ; frame, landmarks, traffic, large ones): entry * 2, sort
t1_n:       .res 2              ; key (key / 4 x 4 / 2 / 1), descending
t2_idx:     .res 256            ; [W1b] ... the others (depth order): entry * 2
t2_n:       .res 2

PL_MAX = 48
pl_list:    .res PL_MAX*2       ; [W1b] palettes with a weight this frame (PAL_W offsets)
slot_w:     .res 16             ; [W1b] per slot: its palette's weight the last frame
slot_ob:    .res 16             ; ... the object with the largest key using it
pal_o:      .res 256            ; [W1b] per pal_src: object with the largest key this frame
pp_pal:     .res 2              ; [W1b] PalPick: palette to load at the next frame's start
pp_slot:    .res 2              ; ... into this slot * 2 ($FFFF none)
oam_hi:     .res 32
oam_used:   .res 4              ; per OAM buffer: entries shown when last built
.ifdef SPRCHECK
chk_c:      .res 2              ; (W3a SprChkEnt)
chk_val:    .res 24
.endif

.segment "IRAMBSS"              ; (hot: I-RAM is twice as fast as BW-RAM)
sv_oam:     .res 2              ; OAM entries used
sv_stat:    .res 16             ; debug: placed, shown, fallbacks, drops (pal, oam, line, cells, dma)
sv_dma:     .res 2              ; DMA bytes left this frame
sv_nok:     .res 2              ; cells usable (free or evictable) left
sv_nfree:   .res 2              ; free slots (SV_FREE stack)
sv_shand:   .res 2              ; cell row eviction hand
sv_slhand:  .res 2              ; slot eviction clock hand (slot * 2)
sv_up:      .res 2              ; debug: DMA bytes queued this frame
sv_nfc:     .res 2              ; free cells (av_free bits)
w_sizes:    .res 2              ; sizes emitted by this candidate: bit 0 small, bit 1 large
w_stg:      .res 2              ; ClaimPass: staging OAM entries
w_ck:       .res 2
sv_debt:    .res 2              ; [W1b] cells the entries placed so far lack
sv_dkey:    .res 2              ; ... the largest key asking (ones at most half of it give)
w_npl:      .res 2
pp_cool:    .res 2              ; ... frames before the next change
.segment "BSS"
ln_disc:    .res 224            ; tile fetches minus hardware objects per line
bs_obj:     .res MAXBAND*2
bs_short:   .res MAXBAND*2
bs_selfobj: .res 2
bs_limit:   .res 2
bs_max:     .res 2
.segment "IRAMBSS"
ln_sl:      .res 224            ; per screen line: OBJ slivers (8 px tiles)
av_free:    .res 16             ; per cell row: bit n = cell row * 8 + n free
av_ok:      .res 16             ; ... usable (free, or not displayed and not claimed)
av_now:     .res 16             ; ... claimed this frame
w_noam:     .res 2              ; hardware objects (short/narrow cells use 8px tiles)
w_small:    .res 2
copy_first: .res 2
bs_sl:      .res MAXBAND*2      ; exact fetched slivers after horizontal clipping
bs_ln:      .res MAXBAND*2      ; BandPass: per band first piece on screen | count << 8
bs_lin:     .res MAXBAND*2      ; ... lines on screen: first | last << 8 ($FFFF none)
w_hin:      .res 2              ; image inside the screen horizontally (SetHin)
ln_ub:      .res 14             ; per 16 lines: bound of their slivers (LinesOver)
w_skip:     .res 2              ; [W1b] BandPass: bands left out (over the line budget)
w_vis:      .res 2              ; ... bands with pieces on screen
w_lm:       .res 2              ; [W1b] BandPass: slivers a line must keep free (admission)
w_can_short: .res 2             ; this image can emit short-height bands
bs_y8:      .res MAXBAND*2      ; original (unclamped) band Y for OAM
w_fb:       .res 2              ; Accept: 1 the fallback image is tried
w_pc:       .res 2
w_j:        .res 2
w_jend:     .res 2
w_cum:      .res 2              ; first piece of the band
w_bn:       .res 2              ; pieces of the band
w_src:      .res 2              ; image pixel data: offset, bank | block << 8
w_srcb:     .res 2
w_last:     .res 2              ; previous piece had a cell (runs)
w_mapb:     .res 2              ; ClaimPass: SL_MAP page of the slot
w_cell:     .res 2              ; ClaimPass: cell * 2
w_rc:       .res 2              ; ... cells of the run left
w_why:      .res 2              ; Accept: why the exact image was refused

.segment "SA1CODE"
.a16
.i16

;============================================================================
; SprV2Init
;============================================================================
SprV2Init:
    lda #.loword(OAM_BUF0)
    jsr OamClear
    lda #.loword(OAM_BUF1)
    jsr OamClear
    lda #.loword(OAM_BUF0)
    sta SH_OAMSRC
    lda #.loword(OAM_BUF1)
    sta sv_back
    stz SH_UQW
    stz SH_UQR
    stz SH_UQT
    stz sv_txtd
    stz oam_used
    stz oam_used+2
    lda #2
    sta SH_PACE
    sta sv_frame
    sta z:sv_fr
    ; cells free, slots free, hash empty, no last images, palettes free
    ldx #0
:   lda #$FFFF
    sta f:VC_OWN,x
    inx
    inx
    cpx #NCELL*2
    bcc :-
    ldx #0
:   lda #$FFFF
    sta f:SL_IMG,x
    lda #0
    sta f:SL_NRES,x
    sta f:SL_STAMP,x
    txa
    sta f:SV_FREE,x         ; (stack: slot * 2)
    inx
    inx
    cpx #NSLOT*2
    bcc :-
    lda #NSLOT
    sta sv_nfree
    stz sv_shand
    stz sv_slhand
    ldx #510                ; [W1b] objects: no key, no state, nothing loading
:   lda #0
    sta f:OB_KEY,x
    sta f:OB_ST,x
    sta f:OB_DROP,x
    lda #$FFFF
    sta f:OB_PIMG,x
    dex
    dex
    bpl :-
    ldx #254
    lda #0
:   sta f:OB_DN,x
    dex
    dex
    bpl :-
    stz w_npl               ; [W1b] palette weights
    lda #$FFFF
    sta pp_slot
    ldx #14
:   stz slot_w,x
    dex
    dex
    bpl :-
    ldx #510
    lda #0
:   sta f:PAL_W,x
    dex
    dex
    bpl :-
    ldx #254
:   sta f:PAL_M,x
    dex
    dex
    bpl :-
    ldx #254
    lda #$FFFF
:   sta pal_o,x
    dex
    dex
    bpl :-
    stz pp_cool
    lda #NCELL
    sta sv_nfc
    ldx #14
:   lda #$FFFF
    sta av_free,x
    sta av_ok,x
    stz av_now,x
    dex
    dex
    bpl :-
    ldx #0
:   lda #0
    sta f:SL_HASH,x
    lda #$FFFF
    sta f:LAST_IMG,x
    inx
    inx
    cpx #512
    bcc :-
    ldx #0
:   lda #$FFFF
    sta slot_pal,x
    stz slot_stamp,x
    inx
    inx
    cpx #16
    bcc :-
    ldx #0
    lda #0
:   sta f:PAL_MAP,x
    inx
    inx
    cpx #256
    bcc :-
    rts

; A recycled engine object must not inherit a different object's image,
; drop cooldown or sorting weight. Resident image data can still be shared.
.export SprForgetObject, SprForgetScene
SprForgetScene:
    ldx #254
@entry:
    jsr SprForgetObject
    dex
    dex
    bpl @entry
    rts
SprForgetObject:             ; X = engine object * 2, preserved
    lda #0
    sta f:OB_KEY,x
    sta f:OB_KEY+256,x
    sta f:OB_ST,x
    sta f:OB_ST+256,x
    sta f:OB_DROP,x
    sta f:OB_DROP+256,x
    lda #$FFFF
    sta f:OB_PIMG,x
    sta f:OB_PIMG+256,x
    sta f:LAST_IMG,x
    sta f:LAST_IMG+256,x
    sta f:LAST_DSC,x
    sta f:LAST_DSC+256,x
    phx
    txa
    lsr a
    tax
    sep #$20
    .a8
    lda #0
    sta f:OB_DN,x
    sta f:OB_DN+128,x
    rep #$20
    .a16
    plx
    rts

; A = OAM buffer (bank $40 offset): all sprites hidden (y = 224), small
OamClear:
    tax
    ldy #128
:   lda #$E000
    sta f:$400000,x
    lda #0
    sta f:$400002,x
    inx
    inx
    inx
    inx
    dey
    bne :-
    ldy #16
:   sta f:$400000,x
    inx
    inx
    dey
    bne :-
    rts

;============================================================================
; SprV2Frame: build the OBJ frame for the current hardware sprite list.
; [W1b] The entries are placed by importance (ScanPass: the car group, then
; key buckets, highest first), their OAM entries staged (pr_st), then copied
; in depth order (arcade draw order reversed: front-most first).
;============================================================================
SprV2Frame:
    jsr GridPalette
    stz sv_up
    stz sv_debt
    inc sv_frame
    lda sv_frame
    sta z:sv_fr
    .ifdef FLKSTAT
    jsr FlBegin
    .endif
    stz sv_oam
    ; DMA budget: DMA_VBL per vblank since the last frame (2-4)
    jsr GetFrame
    tax
    sec
    sbc sv_lastf
    stx sv_lastf
    cmp #2
    bcs :+
    lda #2
:   cmp #5
    bcc :+
    lda #4
:
    .ifdef RGFIXDMA
    lda #2                  ; (test builds: DMA budget independent of the timing)
    .endif
    asl a
    tax
    lda f:DmaBudget-4,x     ; (x2: word per vblank count)
    .ifndef HWLIST
    sec                     ; [W1c] (less the overhead structures' uploads)
    sbc ohb_dma
    bcs :+
    lda #0
:
    .endif
    sta sv_dma
    ldx #14
:   stz sv_stat,x
    dex
    dex
    bpl :-
    lda grid_warm
    beq :+
    ldx #126
@gridclear:
    stz grid_full,x
    dex
    dex
    bpl @gridclear
:   jsr CellMasks
    jsr ClipFrame
    jsr ClearLines
    ldx pp_slot             ; [W1b] the palette PalPick chose (applied at this
    bmi :+                  ; frame's swap, with this frame's entries)
    stx w_u+2
    lda #$FFFF
    sta slot_w,x            ; (not free, nobody else's)
    sta slot_ob,x
    lda pp_pal
    jsr LoadPal
    lda #$FFFF
    sta pp_slot
:   jsr ScanPass            ; [W1b] the car group, the others' key buckets
    ; ---- the entries by importance, their OAM entries staged ----
    lda #.loword(ST_OAM)
    sta w_st
    sta w_stg
    stz w_oi
    ldx #126
:   stz st_small,x
    dex
    dex
    bpl :-
    ldx #254
:   stz pr_st,x
    dex
    dex
    bpl :-
    ldx #0                  ; the car group (the car itself first)
@pc:
    cpx w_ncar
    bcs @pb
    stx w_ck
    lda pc_idx,x
    sta w_i
    jsr Process
    ldx w_ck
    inx
    inx
    bra @pc
@pb:
    ldx #0                  ; the first tier by key
@p1:
    cpx t1_n
    bcs @p2
    stx w_ck
    lda t1_idx,x
    lsr a
    sta w_i
    jsr Process
    ldx w_ck
    inx
    inx
    bra @p1
@p2:
    ; Admit new scenery from the horizon towards the camera. Small distant
    ; images fit early, then retain their place as they grow. Retry new
    ; candidates on alternating frame pairs and only with allocation room.
    ldx t2_n
@q2:
    dex
    dex
    bmi @pe
    stx w_ck
    lda t2_idx,x
    tay
    lsr a
    sta w_i
    tyx
    lda f:hw_ent,x
    sta w_obj
    lda z:sv_fr
    lsr a
    clc
    adc w_obj
    lsr a
    bcs @skipnew
    lda sv_nok
    cmp #CELL_RES+1
    bcc @skipnew
    lda sv_dma
    cmp #128+RUN_OVH
    bcc @skipnew
    jsr Process
    bra @newnext
@skipnew:
    jsr ProcSkip
@newnext:
    ldx w_ck
    bra @q2
@pe:
    jsr ArchFinish
    .ifndef HWLIST
    ; Roof admission is final. Start the S-CPU road work while the SA-1
    ; copies OAM and renders the HUD; the road uses the same final geometry.
    lda arch_count
    beq :+
    .import RoadRender, PalFlushRoad
    jsr RoadRender
    jsr PalFlushRoad
    lda #1
    sta arch_posted
:
    .endif
    ; Admission can hide a traffic car while its cheap shadow still fits.
    ; Match against this frame's actual staged parents, including hill culls.
    ldx #126
:   stz parent_shown,x
    dex
    dex
    bpl :-
    lda sprite_count
    asl a
    tax
@parents:
    dex
    dex
    bmi @copystart
    lda pr_st,x
    beq @parents
    lda f:hw_ent,x
    bit #$0080
    bne @parents
    and #$007F
    tay
    sep #$20
    .a8
    lda #1
    sta parent_shown,y
    rep #$20
    .a16
    bra @parents
@copystart:
    stz w_stg
    ; ---- the OAM buffer: the staged entries in depth order ----
    lda sv_back
    sta w_st
    stz w_oi
    ldx #30
    lda #$AAAA              ; 16x16 by default, narrow pieces clear their bit
:   sta oam_hi,x
    dex
    dex
    bpl :-
    ; Stage by hardware index, then visit the indexes in reverse depth
    ; order. This replaces the quadratic insertion sort of sh_idx.
    lda sprite_count
    asl a
    tax
@cp:
    dex
    dex
    bmi @done
    stx w_ck
    lda pr_st,x
    beq @cn
    jsr CopyStaged
@cn:
    ldx w_ck
    bra @cp
@done:
    ldx #14                 ; (debug: the stats of the last complete frame)
:   lda sv_stat,x
    sta sv_statl,x
    dex
    dex
    bpl :-
    lda sv_up
    sta sv_statl+16
    .ifdef FLKSTAT
    jsr FlEnd
    .endif
    lda z:sv_fr             ; ([W1b] palettes: every 2nd frame)
    and #1
    bne :+
    jsr PalPick
:   jmp FinishOam

;----------------------------------------------------------------------------
; [W1b] Process: entry w_i: CandGeom, its key (OB_KEY, for the next frame's
; order), its state (OB_ST): dropped ones wait for their DropT delay, shown /
; loading ones give their cells up while a more important entry lacks cells
; (sv_debt; they are dropped), then Show (its OAM entries staged: pr_st)
;----------------------------------------------------------------------------
Process:
    jsr CandGeom
    bcc :+
    rts
:
    .ifdef FLKSTAT
    jsr FlOs
    .endif
    jsr KeyOf               ; -> A = key (0 off screen)
    sta w_key
    lda w_obj
    asl a
    sta w_ob2
    tax
    stz w_nst
    lda f:OB_ST,x           ; (the last frame's state)
    tay
    and #$00FF
    inc a
    eor z:sv_fr
    and #$00FF
    bne @os0
    tya
    xba
    and #$00FF
    bra :+
@os0:
    lda #0
:   sta w_ost
    lda w_key
    bne @on
    lda w_obj               ; (off screen: state and drop count cleared)
    tax
    sep #$20
    .a8
    lda #0
    sta f:OB_DN,x
    rep #$20
    .a16
    jmp @st
@on:
    ; PalAdd needs this entry's priority, not the previous Process call's.
    jsr SetCar
    lda z:sv_fr             ; [W1b] (palette weights, every 2nd frame: not
    and #1                  ; shadow sprites)
    bne :+
    ldx w_cls
    cpx #1
    beq :+
    lda w_key
    jsr PalAdd
:   lda w_car
    beq :+
    jmp @go
:   ; dropped: wait for the per-object retry delay
    lda w_ost
    and #ST_DROP
    beq @nd
    ldx w_ob2
    lda sv_frame
    sec
    sbc f:OB_DROP,x
    sta w_t
    lda w_obj
    tax
    lda f:OB_DN,x           ; (DropT by drops, traffic: short)
    and #$0003
    tax
    lda f:DropT,x
    and #$00FF
    cmp w_t
    bcc :+
    beq :+
    lda #ST_DROP
    sta w_nst
    lda #11
    jmp @why
:   stz w_ost               ; (its time is over: a new candidate)
@nd:
    ; a more important entry lacks cells: the shown / loading ones after it
    ; give theirs up (dropped)
    lda w_big
    cmp #3
    bne :+
    lda w_ost
    and #ST_SHOWN
    bne @nde                ; keep admitted people stable through pose changes
:
    ldx w_ob2
    cpx #128*2
    bcs :+
    lda grid_decor,x
    cmp #1
    beq @nde
:
    lda sv_debt
    beq @nde
    lda w_key
    asl a
    bcs @nde
    cmp sv_dkey
    beq :+
    bcs @nde                ; (not at most half as important)
:   lda w_ost
    and #ST_SHOWN | ST_LOAD
    beq @nde
    jsr ResCells
    sta w_t
    lda sv_debt
    sec
    sbc w_t
    bcs :+
    lda #0
:   sta sv_debt
    lda #ST_DROP
    sta w_nst
    jsr DropNow
    lda #10
    jmp @why
@nde:
    ; nothing shown / loading, not a landmark / traffic: refused at once
    ; without cells / DMA (the others are placed last: none would give theirs)
    lda w_ost
    and #ST_SHOWN | ST_LOAD
    bne @go
    lda w_big
    bne @go
    jsr Hopeless
    bcc @go
    lda #6
    jmp @why
@go:
    ; palette slot (pal_src; shadow sprites: slot 0)
    lda w_pc
    cmp #$FFFF
    bne :+
    lda #0
    bra @pal
:   lda w_i
    asl a
    tax
    lda f:hw_pal,x
    and #$00FF
    sta w_u                 ; (PalSlot inline: loaded -> its slot)
    tax
    lda f:PAL_MAP,x
    bit #$0080
    beq :+
    and #$000F
    lsr a
    bra @pal
:   jsr PalSubst            ; [W1c] (not loaded: a loaded one with the colours the
    bcc @pal                ; frame uses, tools/mksprv3.py PalSubT)
    jsr PalFree             ; (not loaded: the least recently used slot not used now)
    bcc @pal
    inc sv_stat+6
    jsr Refused             ; (shown the last frame: dropped)
    lda #7
    jmp @why
@pal:
    pha
    asl a
    tax
    lda sv_frame
    sta slot_stamp,x        ; (used this frame)
    pla
    xba
    asl a                   ; slot << 9
    ora w_mir
    ora #$3000
    sta w_attr              ; (priority 3, palette, h-flip)
    lda w_arch
    beq :+
    lda w_attr
    and #$CFFF
    ora #$2000              ; nearer BG roofs occlude the complete far arch
    sta w_attr
:
    lda w_st                ; (first staged entry)
    sec
    sbc #.loword(ST_OAM)
    lsr a
    lsr a
    sta w_prf
    stz w_x9
    stz w_sizes
    lda w_img
    sta w_exi
    jsr PlaceImg
    bcc :+
    lda #9
    bra @why
:   jsr Show                ; -> w_nst
    jsr ArchDraw
    lda w_st
    sec
    sbc #.loword(ST_OAM)
    lsr a
    lsr a
    sec
    sbc w_prf
    beq @st
    pha
    lda grid_warm
    beq @grid_done
    lda w_obj
    cmp #NO_SPRITES
    bcs @grid_done
    tax
    lda w_skip
    bne @grid_done
    lda w_st
    sec
    sbc #.loword(ST_OAM)
    lsr a
    lsr a
    sec
    sbc w_prf
    cmp w_noam
    bne @grid_done
    sep #$20
    .a8
    lda #1
    sta grid_full,x
    rep #$20
    .a16
@grid_done:
    pla
    xba                     ; staged count and first OAM index
    ora w_prf
    ldx w_x9
    bne @highbits
    ldx w_sizes
    cpx #3
    bne :+
@highbits:
    ora #$0080
:   pha
    lda w_i
    asl a
    tax
    lda w_sizes
    sta pr_size,x
    pla
    sta pr_st,x
    bra @st
@why:
    ldx w_i
    sep #$20
    .a8
    sta sv_why,x
    rep #$20
    .a16
@st:
    lda w_nst               ; (state: ST_* | ST_BIG, frames shown in a row << 4)
    ldx w_big
    beq :+
    ora #ST_BIG
:   bit #ST_SHOWN
    beq @s1
    tay
    lda w_ost
    and #ST_SHOWN
    beq @a1
    lda w_ost
    and #$00F0
    cmp #$00F0
    beq :+
    adc #$0010              ; (C clear)
:   sta w_t
    tya
    ora w_t
    bra @s1
@a1:
    tya
    ora #$0010
@s1:
    sta w_t+2
    ; the next frame's order (OB_KEY): first tier (not dropped: shown /
    ; loading, landmarks, traffic, LARGE_KEY on) key / 4 x 4 (seniors: shown
    ; AGE_S frames in a row, landmarks, traffic) / x 2 (shown, loading) / x 1,
    ; at least 1; 0 the others
    ldy #0
    bit #ST_DROP
    bne @sk
    lda w_key
    beq @sk
    lsr a
    lsr a
    bne :+
    inc a
:   tay
    lda w_t+2
    bit #ST_BIG
    bne @k4
    bit #ST_SHOWN | ST_LOAD
    beq @kl
    bit #ST_SHOWN
    beq @k2
    and #$00F0
    cmp #AGE_S << 4
    bcc @k2
@k4:
    tya
    asl a
    asl a
    tay
    bra @sk
@k2:
    tya
    asl a
    tay
    bra @sk
@kl:
    lda w_key
    cmp #LARGE_KEY
    bcs @sk
    ldy #0
@sk:
    ldx w_ob2
    tya
    sta f:OB_KEY,x
    lda w_t+2
    xba
    sta w_t
    lda z:sv_fr
    and #$00FF
    ora w_t
    sta f:OB_ST,x
    rts

; Probe: positive geometry key, before palette/resource admission.
SprVisible = @on
.export SprVisible

; DropNow: object w_obj dropped now (OB_DROP; OB_DN + 1, 3 at most)
DropNow:
    lda w_obj
    asl a
    tax
    lda sv_frame
    sta f:OB_DROP,x
    lda w_obj
    tax
    sep #$20
    .a8
    lda w_big               ; (traffic: the short time, OB_DN 0)
    cmp #2
    bne :+
    lda #0
    bra :++
:   lda f:OB_DN,x
    cmp #3
    bcs :++
    inc a
:   sta f:OB_DN,x
:   rep #$20
    .a16
    rts

; [W1b] ProcSkip: entry w_i of the others not placed this frame (every other
; frame pair): not shown, its object's state kept (the stamp renewed)
ProcSkip:
    lda w_obj
    and #$00FF
    sta w_obj
    asl a
    tax
    lda f:OB_ST,x
    tay
    and #$00FF
    inc a
    eor z:sv_fr
    and #$00FF
    bne @x                  ; (not placed the last frame: nothing to keep)
    tya
    and #$FF00
    sta w_t
    lda z:sv_fr
    and #$00FF
    ora w_t
    sta f:OB_ST,x
    .ifdef FLKSTAT
    jsr FlSkip
    .endif
@x: rts

; SetCar: w_car = 1 for the car group (Ferrari, passengers, shadow, crash
; objects, flag man; their shadow copies; not the smoke)
SetCar:
    stz w_car
    lda w_obj
    bit #$0080
    bne @rank
    asl a
    tax
    lda grid_people,x
    cmp #1
    bne @rank
    inc w_car
    rts
@rank:
    lda w_obj
    and #$007F
    tax
    jsr EntryRank
    cmp #4                  ; ([W1b] smoke: placed with the car group, dropped
    bcs :+                  ; like the others)
    inc w_car
:   rts

; The outro repurposes crash objects: 114 is the car interior, 115 is a
; ground shadow, and 118 is visible animation in ending E only.
EntryRank:
    lda fer_state
    and #$00FF
    cmp #4
    bne @normal
    cpx #SPRITE_CRASH_SHADOW
    beq @car
    cpx #SPRITE_CRASH_PASS1
    beq @shadow
    cpx #SPRITE_CRASH_PASS2_S
    bne @normal
    lda end_seq
    and #$00FF
    cmp #4
    bne @shadow
    lda #1
    rts
@car:
    lda #0
    rts
@shadow:
    lda #5
    rts
@normal:
    lda f:CarRank,x
    and #$00FF
    rts

; ResCells: A = cells of the images of object w_obj (its last one, the one
; being loaded; shared ones counted too)
ResCells:
    lda w_obj
    asl a
    tax
    lda f:OB_PIMG,x
    pha
    lda f:LAST_IMG,x
    jsr SlotRes
    sta w_v+2
    pla
    jsr SlotRes
    clc
    adc w_v+2
    rts
; SlotRes: A = image -> A = its slot's pieces with a cell (0: none)
SlotRes:
    cmp #$FFFF
    beq @z
    jsr FindSlot
    cmp #$FFFF
    beq @z
    asl a
    tax
    lda f:SL_NRES,x
    rts
@z: lda #0
    rts

;----------------------------------------------------------------------------
; [W1b] KeyOf: exact geometry (CandGeom) -> A = importance key: the visible
; area / 8 (x4 landmark frames: descriptor class; x4 traffic; /4 shadow
; sprites), at least 1; 0 when off screen
;----------------------------------------------------------------------------
KeyOf:
    stz w_big
    lda w_xa
    ldx w_rtl
    beq :+
    sec
    sbc w_we
    inc a                   ; (right to left: x0 = xa - We + 1)
:   tax                     ; x0
    bmi @xl
    clc
    adc w_we
    cmp #257
    bcs @xr
    lda w_we                ; (inside: the width)
    bra @xw
@xl:
    clc                     ; (left cut: x1)
    adc w_we
    bmi @z
    beq @z
    cmp #257
    bcc @xw
    lda #256
    bra @xw
@z: lda #0
    rts
@xr:
    txa                     ; (right cut: 256 - x0)
    eor #$FFFF
    sec
    adc #256
    bmi @z
    beq @z
@xw:
    sta MAL                 ; visible width
    lda w_top
    bmi @yt
    cmp #224
    bcs @z
    clc
    adc w_he
    ldx w_vb
    cpx #$7FFF
    beq :+
    cmp w_vb
    bcc :+
    lda w_vb
:   cmp #225
    bcc :+
    lda #224
:   sec
    sbc w_top               ; visible height
    beq :+
    bpl @yh
:   jmp @off
@yt:
    clc                     ; (top cut: y1)
    adc w_he
    ldx w_vb
    cpx #$7FFF
    beq :+
    cmp w_vb
    bmi :+
    lda w_vb
:   cmp #225
    bmi :+
    lda #224
:   tax
    bmi @off
    beq @off
@yh:
    sta MBL
    nop
    nop
    lda MR
    lsr a
    lsr a
    lsr a
    bne :+
    inc a
:   ldx w_cls               ; (shadow sprite: / 4)
    cpx #1
    bne :+
    lsr a
    lsr a
    bne :+
    inc a
:   sta w_t
    lda w_obj               ; (landmark frame or traffic: x 4; not shadow copies,
    bit #$0080              ; not shadow sprites)
    bne @k
    ldx w_cls
    cpx #1
    beq @k
    lda w_obj
    asl a
    tax
    lda grid_decor,x
    cmp #1
    beq @x4                ; admitted grid palms may reclaim an unused palette
    ldx w_dsc
    lda f:DR+17,x
    and #$00FF
    beq :+
    cmp #3                  ; [W1c] (class 3: people, key x 8)
    bne @x4
    sta w_big               ; people need landmark admission/palette protection too
    asl w_t
    asl w_t
    asl w_t
    bra @k
:   lda w_obj
    cmp #SPRITE_TRAFF1
    bcc @k
    cmp #SPRITE_TRAFF8 + 1
    bcs @k
    inc w_big               ; (traffic: 2)
@x4:
    asl w_t
    asl w_t
    inc w_big               ; (landmark: 1)
@k: lda w_t
    rts
@off:
    lda #0
    rts


;----------------------------------------------------------------------------
; CellMasks: the cells claimed last frame (av_now) are displayed now
; (protected), the others usable (av_ok); av_free (no owner) is kept up to
; date by AllocRun / DropSlot; sv_nok = usable cells
;----------------------------------------------------------------------------
CellMasks:
    stz sv_nok
    ldy #15
@r: sep #$20
    .a8
    lda av_now,y
    eor #$FF
    sta av_ok,y
    lda #0
    sta av_now,y
    rep #$20
    .a16
    lda av_ok,y
    and #$00FF
    tax
    lda f:PopCnt,x
    and #$00FF
    clc
    adc sv_nok
    sta sv_nok
    dey
    bpl @r
    rts

ClearLines:
    ldx #12
:   stz ln_ub,x
    dex
    dex
    bpl :-
    ldx #224 - 16
:   stz ln_disc+0,x
    stz ln_sl+0,x
    stz ln_disc+2,x
    stz ln_sl+2,x
    stz ln_disc+4,x
    stz ln_sl+4,x
    stz ln_disc+6,x
    stz ln_sl+6,x
    stz ln_disc+8,x
    stz ln_sl+8,x
    stz ln_disc+10,x
    stz ln_sl+10,x
    stz ln_disc+12,x
    stz ln_sl+12,x
    stz ln_disc+14,x
    stz ln_sl+14,x
    txa
    sec
    sbc #16
    tax
    bpl :-
    rts

;----------------------------------------------------------------------------
; CandGeom: hardware entry w_i -> object w_obj, descriptor w_dsc, exact
; image w_img, its exact geometry (w_xa, w_rtl, w_we, w_he, w_top, w_vb),
; w_mir, w_pc ($FFFF: shadow sprite).  C set: not drawn.
; ---- W3a (entry input side): render builds take the entry's values from
; its record (osprites.s DsRec, sprrec.inc: CandRaw); HWLIST builds
; (LOCKSTEP, SPRCHECK) decode the arcade hardware entry (below) ----
;----------------------------------------------------------------------------
; Dimension tables reproduce MR+1, rounding and 16-bit shifts exactly.
; Identical widths/heights across descriptors share one 128-word table.
.macro ExactSpriteSize
    lda w_k
    asl a
    sta w_t
    ldx w_dsc
    lda f:DR,x
    asl a
    tax
    lda f:$CF0000+SprWidthOfs,x
    clc
    adc w_t
    tax
    lda f:$CF0000,x
    sta w_we
    ldx w_dsc
    lda f:DR+2,x
    asl a
    tax
    lda f:$CF0000+SprHeightOfs,x
    clc
    adc w_t
    tax
    lda f:$CF0000,x
    sta w_he
.endmacro

; Ending animations reuse crash-shadow slots for visible artwork (the car
; interior and, in ending E, a character). Conversely, their real shadows
; occupy former passenger slots. Classify the current frame, not its slot.
.macro GroundShadow target
    lda w_obj
    bit #$0080
    bne target
    lda w_dsc
    cmp f:SPR_META+(SPRITE_SHADOW_DATA-SPR_D0)
    bcc :+
    cmp f:SPR_META+(SPRITE_SHADOW_DATA-SPR_D0)+5*10
    bcc target
:
.endmacro

CandGeom:
    stz w_arch
    lda scn_pmode
    cmp #3                  ; title page contains the complete logo
    bne :+
    sec
    rts
:
    .ifndef HWLIST
    lda w_i
    asl a
    asl a
    asl a
    asl a
    tax
    jmp CandRaw
    .else
    lda w_i
    asl a
    tay                     ; (hw_ent offset)
    asl a
    asl a
    asl a
    tax                     ; sprite_entries offset
    lda f:sprite_entries,x
    bit #$5000
    beq :+
@skip:
    sec
    rts
:   sta w_d0
    stx w_v+2               ; (sprite_entries offset)
    tya
    asl a
    tax
    lda f:hw_src,x          ; frame descriptor (rom0)
    sec
    sbc #.loword(SPR_D0)
    tay
    lda f:hw_src+2,x
    sbc #^SPR_D0
    bne @skip
    cpy #SPR_DN * 10
    bcs @skip
    tyx
    lda f:SPR_META,x
    sta w_dsc               ; descriptor record
    tax
    lda f:DR+2,x            ; (rows: an empty frame is not drawn)
    beq @skip
    lda w_i
    asl a
    tax
    lda f:hw_ent,x
    and #$00FF
    sta w_obj               ; object entry | $80 (shadow copy)
    lda scn_pmode           ; course map page: the backdrop pieces (entries
    cmp #2                  ; 26-60) are on BG1
    beq @pm
@pgok:
    ldx w_v+2
    lda f:sprite_entries+8,x
    sta w_d4
    lda f:sprite_entries+12,x
    sta w_xa                ; (arcade x for now)
    lda f:sprite_entries+10,x
    xba
    and #$00FF
    inc a
    sta w_vb                ; (visible rows for now)
    lda f:sprite_entries+2,x
    sta w_u+2               ; (d1: source address)
    lda f:sprite_entries+6,x
    sta w_t+2               ; (d3: hw shadow bit)
    ; ---- mode: 1 shadow sprite (shadow copies and the Ferrari / crash
    ; shadow objects), 2 hw shadow bit (colour 10 = shadow), 0 normal ----
    GroundShadow @m1
    stz w_pc
    lda w_t+2
    and #$4000
    beq @m0
    ldy #2
    bra @md
@pm:
    lda w_obj
    cmp #26
    bcc @pgok
    cmp #61
    bcs @pgok
    sec
    rts
@m0:
    ldy #0
    bra @md
@m1:
    ldy #1
    lda #$FFFF
    sta w_pc                ; pal_src $FFFF for mode 1 (Show)
@md:
    sty w_cls               ; (mode)
    ; ---- map of the mode -> image ----
    lda w_cls
    asl a
    adc w_dsc               ; (C clear)
    tax
    lda f:DR+8,x
    sta mp
    txa
    sec
    sbc w_cls               ; record + mode
    tax
    lda f:DR+14,x
    and #$00FF
    bne :+
    jmp @skip               ; (no image of this mode)
:   sep #$20
    .a8
    sta mp+2
    rep #$20
    .a16
    lda w_d4
    and #$03FF
    tax
    lda f:HzIdx,x
    and #$00FF
    sta w_k
    tay
    lda [mp],y              ; level
    and #$00FF
    asl a
    adc #128                ; (C clear)
    tay
    lda [mp],y
    sta w_img               ; image
    ExactSpriteSize
    ; ---- x: first drawn pixel (arcade), * 0.8; right to left when d4 bit
    ; 13 is clear; mirrored when the read direction (bit 14) differs ----
    lda w_d4
    xba
    lsr a
    lsr a
    lsr a
    lsr a
    and #$0006
    tax                     ; (bits 14-13) * 2
    lda f:MirTab,x
    sta w_mir
    lda f:RtlTab,x
    sta w_rtl
    lda w_xa
    ldy w_rtl
    beq @xpos               ; (left to right)
    cmp #$0080
    bcs @xpos
    adc #$0200              ; (C clear)
@xpos:
    and #$03FF
    asl a
    tax
    lda f:X08,x
    sta w_xa                ; x * 0.8 (signed 16)
    ; ---- y: arcade top, unclipped (addr past the frame start: rows
    ; skipped * 512 / hz above the screen); visible rows -> bottom cut ----
    lda w_d0
    and #$01FF
    sec
    sbc #$0100
    sta w_top
    clc
    adc w_vb
    cmp #224
    bcc :+
    lda #$7FFF              ; (the screen bottom cuts it)
:   sta w_vb
    lda w_top
    bne @ytop
    ldx w_dsc
    lda f:DR+4,x            ; pitch
    beq @ytop
    sta w_t
    lda w_u+2
    sec
    sbc f:DR+6,x            ; d1 - frame offset (16-bit wrap)
    cmp w_t
    bcc @ytop               ; (less than a row: not clipped)
    ldx w_t
    jsr SDiv16u             ; rows skipped
    sta MAL
    lda w_k
    asl a
    tax
    lda f:SprKH,x
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
    clc
    rts
    .endif                  ; (HWLIST)

; CandRaw (W3a): CandGeom from the entry record at REC_BASE + X (the same
; steps as the arcade entry decode above, from do_sprite's values)
CandRaw:
    lda f:REC_BASE+RR_D0,x
    bit #$5000
    beq :+
@skip:
    sec
    rts
:   sta w_d0
    stx w_v+2               ; (record offset)
    lda f:REC_BASE+RR_FL,x
    sta w_d4                ; (flags)
    lda f:REC_BASE+RR_SRC,x ; frame descriptor (rom0)
    sec
    sbc #.loword(SPR_D0)
    tay
    lda w_d4
    xba
    and #$0003
    sbc #^SPR_D0
    bne @skip
    cpy #SPR_DN * 10
    bcs @skip
    ; The selected start palms use tree-only copies, saving the wide
    ; baked ground shadows' OBJ/cell cost without changing roadside art.
    cpy #245*10
    bcc @desc
    cpy #250*10
    bcs @desc
    lda w_d4
    and #$00FF
    cmp #44
    bcs @desc
    asl a
    tax
    lda grid_decor,x
    cmp #1
    bne @desc
    tya
    clc
    adc #(START_PALM_D-245)*10
    tay
@desc:
    tyx
    lda f:SPR_META,x
    sta w_dsc               ; descriptor record
    tax
    lda f:DR+2,x            ; (rows: an empty frame is not drawn)
    beq @skip
    lda w_d4
    and #$00FF
    sta w_obj               ; object entry | $80 (shadow copy)
    lda scn_pmode           ; course map page: the backdrop pieces (entries
    cmp #2                  ; 26-60) are on BG1
    beq @pm
@pgok:
    ldx w_v+2
    lda f:REC_BASE+RR_H,x
    and #$00FF
    inc a
    sta w_vb                ; (visible rows for now)
    ; ---- mode: 1 shadow sprite (shadow copies and the Ferrari / crash
    ; shadow objects), 2 hw shadow bit (colour 10 = shadow), 0 normal ----
    GroundShadow @m1
    stz w_pc
    lda w_d4
    and #RR_HWS
    beq @m0
    ldy #2
    bra @md
@pm:
    lda w_obj
    cmp #26
    bcc @pgok
    cmp #61
    bcs @pgok
    sec
    rts
@m0:
    ldy #0
    bra @md
@m1:
    ldy #1
    lda #$FFFF
    sta w_pc                ; pal_src $FFFF for mode 1 (Show)
@md:
    sty w_cls               ; (mode)
    ; ---- map of the mode -> image ----
    lda w_cls
    asl a
    adc w_dsc               ; (C clear)
    tax
    lda f:DR+8,x
    sta mp
    txa
    sec
    sbc w_cls               ; record + mode
    tax
    lda f:DR+14,x
    and #$00FF
    bne :+
    jmp @skip               ; (no image of this mode)
:   sep #$20
    .a8
    sta mp+2
    rep #$20
    .a16
    ldx w_v+2
    lda f:REC_BASE+RR_VZ,x
    and #$03FF
    tax
    lda f:HzIdx,x
    and #$00FF
    sta w_k
    tay
    lda [mp],y              ; level
    and #$00FF
    asl a
    adc #128                ; (C clear)
    tay
    lda [mp],y
    sta w_img               ; image
    ExactSpriteSize
    ; ---- x: first drawn pixel (arcade), * 0.8; right to left: + $200
    ; below $80; mirrored = h-flip ----
    lda w_d4
    and #RR_MIR
    sta w_mir
    stz w_rtl
    lda w_d4
    and #RR_RTL
    beq :+
    inc w_rtl
:   ldx w_v+2
    lda f:REC_BASE+RR_X,x
    ldy w_rtl
    beq @xpos               ; (left to right)
    cmp #$0080
    bcs @xpos
    adc #$0200              ; (C clear)
@xpos:
    and #$03FF
    asl a
    tax
    lda f:X08,x
    sta w_xa                ; x * 0.8 (signed 16)
    ; ---- y: arcade top, unclipped (addr past the frame start: rows
    ; skipped * 512 / hz above the screen); visible rows -> bottom cut ----
    lda w_d0
    and #$01FF
    sec
    sbc #$0100
    sta w_top
    clc
    adc w_vb
    cmp #224
    bcc :+
    lda #$7FFF              ; (the screen bottom cuts it)
:   sta w_vb
    lda w_top
    bne @ytop
    ldx w_v+2
    lda f:REC_BASE+RR_D1,x
    sta w_u+2               ; (d1: source address)
    ldx w_dsc
    lda f:DR+4,x            ; pitch
    beq @ytop
    sta w_t
    lda w_u+2
    sec
    sbc f:DR+6,x            ; d1 - frame offset (16-bit wrap)
    cmp w_t
    bcc @ytop               ; (less than a row: not clipped)
    ldx w_t
    jsr SDiv16u             ; rows skipped
    sta MAL
    lda w_k
    asl a
    tax
    lda f:SprKH,x
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
    jsr ArchGeom
    jsr GridCarGeom
    jsr ClipRoadGeom
    jsl $CF0000+EndCarGeom
    rts

.ifdef SPRCHECK
;----------------------------------------------------------------------------
; SprChkEnt (W3a, SPRCHECK builds): A = hardware index just written by
; osprites (arcade entry + its record in sprchk_rec): CandGeom on the arcade
; entry and CandRec on the record must agree.  Mismatches counted at
; CHK_RES (+0 count, +2 in_tick, +4 index, +6 field (chk_list offset, $FF:
; drawn / not drawn), +8 arcade, +10 record value of the first one; +12
; entries checked, +14 of them drawn, +16 visible ones (osprites), 16-bit
; wrapping counts).
;----------------------------------------------------------------------------
CHK_RES = $402E00
SprChkEnt:
    sta w_i
    lda f:CHK_RES+12
    inc a
    sta f:CHK_RES+12
    jsr CandGeom
    lda #0
    rol a
    sta chk_c               ; (C: not drawn)
    bne :+
    lda f:CHK_RES+14
    inc a
    sta f:CHK_RES+14
:   ldx #0
@sv:
    ldy chk_list,x
    bmi @sd
    lda a:0,y
    sta chk_val,x
    inx
    inx
    bra @sv
@sd:
    ldx #0
    jsr CandRaw
    lda #0
    rol a
    cmp chk_c
    beq :+
    ldy #$FF                ; (drawn / not drawn differ)
    bra @bad
:   lda chk_c
    bne @ok                 ; (not drawn either way)
    ldx #0
@cmp:
    ldy chk_list,x
    bmi @ok
    lda a:0,y
    cmp chk_val,x
    bne @badf
    inx
    inx
    bra @cmp
@badf:
    txy
@bad:
    lda f:CHK_RES
    bne @cnt
    lda in_tick
    sta f:CHK_RES+2
    lda w_i
    sta f:CHK_RES+4
    tya
    sta f:CHK_RES+6
    cpy #$FF
    beq @cnt
    lda chk_val,y
    sta f:CHK_RES+8
    ldx chk_list,y
    lda a:0,x
    sta f:CHK_RES+10
@cnt:
    lda f:CHK_RES
    inc a
    sta f:CHK_RES
@ok:
    rts
.endif

;----------------------------------------------------------------------------
; PlaceImg: A = image, exact geometry w_xa / w_rtl / w_we / w_he / w_top /
; w_vb -> image record (ip, bp, w_w, w_h, w_nb, w_xso), w_x / w_y (image
; left / top), visible bands [w_b0, w_b1).  C set: nothing on screen.
;----------------------------------------------------------------------------
PlaceImg:
    stz w_clip
    stz w_lift
    sta w_img
    ; image record: bank SPR_IMGB + (img >> 11), $8000 + (img & $7FF) * 16
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
    ldy #13
    lda [ip],y
    and #2
    sta w_small
    lda [ip],y
    and #1
    .ifndef HWLIST
    sta arc_bg
    .endif
    ldy #4
    lda [ip],y
    .ifndef HWLIST
    xba
    and #$00FF
    cmp #$0080
    bcc :+
    ora #$FF00
:   sta arc_yoff
    lda w_h
    sta arc_fullh
    sec
    sbc arc_yoff
    sta w_h
    lda [ip],y
    .endif
    and #$00FF
    sta w_nb
    inc a
    asl a
    sta w_xso               ; (cumulative firsts: NB + 1 words, then x)
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
    ; x: centred on the exact width; right to left: x = X - W + 1 - dx
    ; ([W1b] landmark frames, traffic: anchored on the arcade x, dx = 0: the
    ; halves of a banner stay joined whatever their levels)
    lda w_arch
    bne @centered
    lda w_big
    beq :+
    lda #0
    bra :++
:   
@centered:
    lda w_we
    sec
    sbc w_w
    cmp #$8000
    ror a
:   sta w_t                 ; dx = (We - W) / 2
    lda w_rtl
    beq @ltr
    lda w_xa
    sec
    sbc w_w
    inc a
    sec
    sbc w_t
    bra @xs
@ltr:
    lda w_xa
    clc
    adc w_t
@xs:
    sta w_x
    ; y: bottom anchored on the exact height
    lda w_top
    clc
    adc w_he
    sec
    sbc w_h
    sta w_y
    ; first band: y < 0: (-y) >> 4
    stz w_b0
    bpl :+
    eor #$FFFF
    inc a
    lsr a
    lsr a
    lsr a
    lsr a
    sta w_b0
:   ; last band + 1: min(NB, (224 - y + 15) >> 4)
    lda #224 + 15
    sec
    sbc w_y
    bmi ClipOff
    lsr a
    lsr a
    lsr a
    lsr a
    cmp w_nb
    bcc :+
    lda w_nb
:   sta w_b1
    ; Exact bottom cut: keep the partial band and mask its hidden pixels.
ClipBottom:                    ; emulator regression marker
    lda w_vb
    cmp #$7FFF
    beq @nocut
    sec
    sbc w_y
    bpl :+
    jmp ClipOff
:   beq ClipOff
    cmp w_h
    bcs @nocut
    pha
    and #15
    sta w_clip
    pla
    clc
    adc #15
    bmi ClipOff
    lsr a
    lsr a
    lsr a
    lsr a
    cmp w_b1
    bcs @nocut
    sta w_b1
@nocut:
    lda w_arch
    beq @unpacked
    lda w_clip
    beq @unpacked
    cmp #8
    bcs @unpacked
    eor #$FFFF
    sec
    adc #8
    sta w_lift
@unpacked:
    lda w_b1
    sec
    sbc w_b0
    beq ClipOff
    bmi ClipOff
    ; horizontal (the pieces are tested one by one later)
    lda w_x
    cmp #256
    bpl ClipOff
    clc
    adc w_w
    bmi ClipOff
    beq ClipOff
    clc
    rts
ClipOff:
    sec
    rts

;============================================================================
; Show: the entry w_i placed with its exact image (w_exi, PlaceImg done),
; w_ost its state of the last frame, w_car set.  Budgets: OAM, lines, VRAM
; cells, DMA bytes, resident slot, palette slot.  On success the pieces get
; cells (missing ones allocated in runs and queued for upload) and their OAM
; entries are written (staged), w_nst |= ST_SHOWN; when the exact image does
; not fit for cells / DMA / slot, the object's last image is shown if it is
; resident and close (the fallback).  [W1b] Lacking cells: sv_debt += the
; missing ones (the shown entries after this one give theirs up); lacking
; DMA budget: the pieces the budget allows are loaded now (ST_LOAD,
; OB_PIMG: the next frames load the rest, then it shows); shown the last
; frame and refused now (not for being off screen): dropped (ST_DROP).
;============================================================================
Show:
    stz w_fb
    stz w_lm                ; [W1b] (admission of small entries: margins on
    lda w_car               ; lines, cells)
    ora w_arch
    bne :+
    lda w_ost
    and #ST_SHOWN
    bne :+
    lda w_key
    cmp #DEBT_KEY
    bcs :+
    lda #LINE_M
    sta w_lm
:   lda w_obj
    asl a
    tax
    ; Arch geometry uses the current scale. A held level made the roof
    ; move down as the ground rose, then jump back up on the next level.
    lda w_arch
    beq :+
    jmp @try
:   lda w_car
    beq :+
    lda fer_state
    and #$00FF
    cmp #4
    beq @hy
:   ; [W1b] the image being loaded: kept while within about two levels
    lda w_ost
    and #ST_LOAD
    beq @hy
    lda f:OB_PIMG,x
    cmp w_exi
    beq @hy
    cmp #$FFFF
    beq @hy
    sta w_v
    jsr FindSlot
    cmp #$FFFF
    beq @hy0
    ldx w_h
    stx w_hx                ; (height of the exact image)
    lda w_v
    jsr PlaceImg
    bcs @hx
    jsr NearHx
    bcs @hx
    lda #3
    sta w_fb
    bra @try
@hy0:
    lda w_obj
    asl a
    tax
@hy:
    ; hysteresis: the object's last image when it is about one level off
    ; (and resident: else the exact one after all)
    lda w_dsc
    cmp f:LAST_DSC,x
    bne @try
    lda f:LAST_IMG,x
    cmp w_exi
    beq @try
    cmp #$FFFF
    beq @try
    sta w_v                 ; (resident with all its pieces, else not worth it)
    jsr FindSlot
    cmp #$FFFF
    beq @try
    asl a
    tax
    lda f:SL_NRES,x
    cmp f:SL_NP,x
    bne @try
    ldx w_h
    stx w_hx                ; (height of the exact image)
    lda w_v
    jsr PlaceImg
    bcs @hx
    jsr NearHx
    bcs @hx
    lda #2
    sta w_fb
    bra @try
@hx:
    lda w_exi               ; (the exact image again)
    jsr PlaceImg
@try:
    lda w_img
    jsr FindSlot
    sta w_rs
    ; not resident at all and no DMA budget / cells left: the fallback
    ; directly (not for landmarks / traffic not shown the last frame: they
    ; may ask for cells)
    cmp #$FFFF
    bne @pass
    lda w_fb
    bne @pass
    lda w_car
    bne @pass
    lda w_big
    beq :+
    lda w_ost
    and #ST_SHOWN
    beq @pass
:   lda sv_dma
    cmp #128 + RUN_OVH
    bcs :+
    inc sv_stat+14
    lda #3
    jmp @fb
:   lda sv_nok
    cmp #CELL_RES + 1
    bcs @pass
    inc sv_stat+12
    lda #6
    jmp @fb
@pass:
    jsr ArchFits
    bcc @archok
    lda w_fb
    cmp #2
    bcc :+
    ; A cached level that is now too narrow must try the new level first.
    ; Retrying that same cached level made arches alternate on/off.
    stz w_fb
    lda w_exi
    jsr PlaceImg
    jmp @try
:   lda #5
    jmp @fb
@archok:
    jsr BandPass
    lda w_npc
    bne :+
    lda w_skip              ; ([W1b] no piece: off screen, or all over the lines)
    bne @lrj
    lda #9
    jmp @rej
:   ; OAM
    lda w_noam
    clc
    adc sv_oam
    cmp #129
    bcc :+
    inc sv_stat+8
    lda #4
    jmp @rej
:   ; Admit all visible bands together. Screen/road clipping is geometric;
    ; a resource shortage must never carve holes through an object.
    lda w_skip
    beq @lok
    lda #5
    jmp @fb
@lrj:
    inc sv_stat+10
    lda #5
    jmp @rej
@lok:
    lda w_new
    bne :+
    jmp @fits
:   lda w_fb
    cmp #2
    bne @exact              ; ([W1b] the exact image, the one being loaded,
                            ; the fallback: its missing pieces loaded)
    stz w_fb                ; (hysteresis image not resident: the exact one)
    lda w_exi
    jsr PlaceImg
    jmp @try
@exact:   ; VRAM cells: all but the car group leave CELL_RES
    lda sv_nok
    sec
    sbc w_new
    bcc @cfj
    ldx w_car
    bne @dok                ; (the car group: no reserve, no DMA budget)
    ldx w_arch
    beq :+
    cmp #4                  ; car already admitted; keep four spare cells
    bcs @dok                ; complete a new arch level at the next swap
    bra @cfj
:   ldx w_lm
    beq :+
    sec                     ; [W1b] (admission: CELL_ADM more)
    sbc #CELL_ADM
    bcc @cfj
:   cmp #CELL_RES
    bcs :+
@cfj:
    jmp @cfail
:   ; DMA bytes: pieces * 128 + entries * RUN_OVH
    lda w_new
    xba
    lsr a                   ; * 128
    sta w_t
    lda w_runs
    sta MAL
    lda #RUN_OVH
    sta MBL
    nop
    nop
    lda MR
    clc
    adc w_t
    cmp sv_dma
    bcc @dok
    beq @dok
    jmp @dfail
@dok:
    ; a slot for the image
    lda w_rs
    cmp #$FFFF
    bne @fits
    jsr SlotNew
    bcc @fits
    lda #8
    jmp @fb
@fits:
    ; ---- commit ----
    lda w_rs
    asl a
    tax
    lda z:sv_fr
    sta f:SL_STAMP,x
    lda w_noam
    clc
    adc sv_oam
    sta sv_oam
    .ifdef SPRTRAP
    lda w_oi
    clc
    adc w_npc
    pha
    .endif
    jsr ClaimPass           ; cells claimed / uploaded, OAM entries
    stz w_ne
    .ifdef SPRTRAP
    pla
    cmp w_oi
    bcs :+                  ; (fewer: pieces left without a cell)
    ldx #4
    jmp Trap
:
    .endif
    ; Allocation can still fail after preflight (private clipping cells or
    ; protected-cell fragmentation). Roll back the staged object atomically.
    ; Keep its claimed cells/line reservations until next frame: conservative
    ; accounting cannot overbook hardware that has already been admitted.
    lda w_oi
    sec
    sbc w_prf
    cmp w_noam
    beq :+
    ldx w_prf
    sep #$20
    .a8
@undo_size:
    cpx w_oi
    bcs @undo_done
    stz st_small,x
    inx
    bra @undo_size
@undo_done:
    rep #$20
    .a16
    lda w_prf
    sta w_oi
    asl a
    asl a
    clc
    adc #.loword(ST_OAM)
    sta w_st
    lda sv_oam
    sec
    sbc w_noam
    sta sv_oam
    lda #6
    jmp @rej
:
    .ifdef FLKSTAT
    jsr FlSh
    .endif
    inc sv_stat+2
    lda #ST_SHOWN
    tsb w_nst
    lda w_fb
    beq @last
    cmp #3
    beq @last               ; (the loaded image: the last one now)
    cmp #2
    beq @why0               ; (hysteresis: shown as the last image)
    inc sv_stat+4
    lda #$81
    bra @why
@why0:
    lda #$82
    bra @why
@last:
    ; the object's last shown image (its fallback while newer ones load)
    lda w_obj
    asl a
    tax
    lda w_dsc
    sta f:LAST_DSC,x
    lda w_img
    sta f:LAST_IMG,x
    lda #$80
@why:
    ldx w_i
    sep #$20
    .a8
    sta sv_why,x
    rep #$20
    .a16
    rts
@cfail:
    inc sv_stat+12
    ; [W1b] the shown entries after this one (at most half as important) give
    ; their cells up (asked by landmarks / traffic of DEBT_KEY on not shown
    ; the last frame; not shadow sprites): sv_debt += w_new - usable ones
    lda w_car
    bne @cf6
    lda w_cls
    cmp #1
    beq @cf6
    lda w_big               ; (landmarks, traffic only)
    beq @cf6
    lda w_key
    cmp #DEBT_KEY
    bcc @cf6
    lda w_ost               ; (shown the last frame: its last image meanwhile)
    and #ST_SHOWN
    bne @cf6
    lda sv_debt
    bne :+
    stz sv_dkey
:   lda w_key
    cmp sv_dkey
    bcc :+
    sta sv_dkey
:   lda sv_nok
    sec
    sbc #CELL_RES
    bcs :+
    lda #0
:   eor #$FFFF
    sec
    adc w_new
    bmi @cf6
    .ifdef FLKREC
    pha
    lda w_obj
    ldx fl_dn
    cpx #16
    bcs :+
    sta fl_dq,x
    inx
    inx
    stx fl_dn
:   pla
    .endif
    clc
    adc sv_debt
    sta sv_debt
@cf6:
    lda #6
    jmp @fb
@dfail:
    inc sv_stat+14
    ; [W1b] the image loads over several frames: now the pieces the DMA
    ; budget allows (not shown yet; meanwhile the last image if any)
    lda sv_dma
    cmp #128 + RUN_OVH
    bcc @df3
    lda w_rs
    cmp #$FFFF
    bne :+
    jsr SlotNew
    bcs @df3
:   lda w_rs
    asl a
    tax
    lda z:sv_fr
    sta f:SL_STAMP,x
    inc w_ne
    jsr ClaimPass           ; (claims, uploads; no OAM entries, no lines)
    stz w_ne
    lda w_obj
    asl a
    tax
    lda w_img
    sta f:OB_PIMG,x
    lda #ST_LOAD
    tsb w_nst
@df3:
    lda #3
; refused (A = reason) for cells / DMA / slot: the fallback image
@fb:
    sta w_why               ; (reason)
    lda w_fb
    cmp #1
    bne @fb2
    jmp @rej0              ; a fallback must also be complete
@fb2:
    lda w_obj
    asl a
    tax
    ; A previous animation pose does not match the other ending layers.
    ; A complete cached scale of this same descriptor is still usable.
    lda fer_state
    and #$00FF
    cmp #4
    bne :+
    lda w_car
    beq :+
    lda w_dsc
    cmp f:LAST_DSC,x
    bne @rej0
:
    lda w_car               ; (the car group: any last image, it must show)
    bne @fl
    lda w_ost               ; [W1b] (shown the last frame: any frame of it)
    and #ST_SHOWN
    bne @fl
    lda w_dsc
    cmp f:LAST_DSC,x        ; (the same frame)
    bne @rej0
@fl:
    lda f:LAST_IMG,x
    cmp #$FFFF
    beq @rej0
    cmp w_img
    bne @oldimg
    jmp @rej0              ; never submit only its resident pieces
@oldimg:
    jsr PlaceImg            ; (the exact geometry is still there)
    bcs @rej0
    lda w_car
    bne @fbok
    ; close in size: |H - He| <= He / 4 ([W1b] shown the last frame: He / 2)
    lda w_h
    sec
    sbc w_he
    bpl :+
    eor #$FFFF
    inc a
:   asl a
    sta w_t
    lda w_ost
    and #ST_SHOWN
    bne :+
    asl w_t
:   lda w_t
    cmp w_he
    beq @fbok
    bcs @rej0
@fbok:
    lda #1
    sta w_fb
    jmp @try
@rej0:
    lda w_why
@rej:
    ldx w_i
    sep #$20
    .a8
    sta sv_why,x
    .ifdef FLKREC
    pha
    lda w_new
    sta fl_nw,x
    lda w_fb
    sta fl_fb,x
    pla
    .endif
    rep #$20
    .a16
    cmp #9                  ; (not off screen)
    beq :+
    jmp Refused
:   rts

; [W1b] Refused: entry refused now: shown the last frame (not the car group,
; not loading its next image; not landmarks, traffic, entries of DEBT_KEY
; on: they try again) -> dropped for its bounded retry delay
Refused:
    lda w_car
    bne @rx
    lda w_big
    cmp #1
    beq @rx                 ; (landmarks: try again)
    cmp #2
    beq :+                  ; (traffic: dropped a short time, see DropNow)
    lda w_key
    cmp #DEBT_KEY
    bcs @rx
:
    lda w_nst
    and #ST_LOAD
    bne @rx
    lda w_ost
    and #ST_SHOWN
    beq @rx
    lda #ST_DROP
    tsb w_nst
    jsr DropNow
@rx:
    rts

; NearHx: C clear when the placed image's height w_h is about two levels
; from the exact one's (w_hx): |H - Hx| * 6 <= Hx
NearHx:
    lda w_h
    sec
    sbc w_hx
    bpl :+
    eor #$FFFF
    inc a
:   asl a
    sta w_t
    asl a
    adc w_t                 ; (C clear)
    cmp w_hx
    beq :+
    bcs @no
:   clc
    rts
@no:
    sec
    rts

;----------------------------------------------------------------------------
; BandPass: image w_img at w_x / w_y, bands [w_b0, w_b1), slot w_rs: per
; band the pieces with their 16 columns on screen (bs_ln), totals
; w_npc, w_new (without a cell), w_runs (runs of those); the line budget:
; [W1b] a band over it is left out (bs_ln count 0: as if hidden by what
; holds those lines), w_skip of the w_vis bands with pieces on screen
;----------------------------------------------------------------------------
BandPass:
    stz w_can_short
    lda w_h
    cmp #9
    bcc @shorts
    lda w_arch
    ora w_small
    bne @shorts
    lda w_obj
    cmp #44
    beq @shorts
    cmp #45
    bne @start
@shorts:
    inc w_can_short
@start:
    jsr SlotComplete
    jsr SetHin
    lda w_x
    clc
    adc w_w
    sec
    sbc #16
    sta w_xm
    stz w_npc
    stz w_noam
    stz w_new
    stz w_runs
    stz w_skip
    stz w_vis
    stz bs_selfobj
    lda w_b0
    sta w_b
@band:
    lda w_b
    cmp w_b1
    bcc :+
    rts
:   lda w_can_short
    beq @shortflag
    jsr ComputeShort
    lda #0
    rol a
@shortflag:
    pha
    lda w_b
    asl a
    tax
    pla
    sta bs_short,x
    sta z:w_short
    jsr BandRange           ; -> bs_ln of band w_b, A = count
    bne :+
    jmp @next
:   inc w_vis
    sta w_pc
    ; ---- line budget: 2 slivers per piece on the band's lines ----
    ldx w_small
    bne :+
    asl a
:   sta w_gn
    jsr BandSlivers
    lda w_b
    asl a
    asl a
    asl a
    asl a
    clc
    adc w_y
    sta w_gmin              ; first line
    lda w_b
    inc a
    cmp w_b1
    bne :+
    lda w_gmin
    sec
    sbc w_lift
    sta w_gmin
:   lda w_gmin
    xba
    and #$FF00
    sta bs_y8,x             ; BandSlivers left X = band * 2
    lda w_gmin
    clc
    adc #15
    sta w_gmax              ; last line
    lda z:w_short
    lsr a
    bcc :+
    lda w_gmin
    clc
    adc #7
    sta w_gmax
:
    lda w_b
    asl a
    tax
    lda w_pc
    ldy w_small
    bne @objcount
    ldy bs_short,x
    beq @objcount
    lda bs_sl,x            ; each visible 8px tile is one hardware object
@objcount:
    sta bs_obj,x
    lda w_gmin
    bpl :+
    lda #0
:   cmp #224
    bpl @nol
    sta w_gmin
    lda w_gmax
    bmi @nol
    cmp #224
    bmi :+
    lda #223
:   sta w_gmax
    xba
    ora w_gmin
    sta bs_lin,x            ; (the band's lines: ClaimPass adds them)
    lda #SLIVERS
    sec
    sbc w_gn
    bcc @over               ; (wider than a whole line)
    sec
    sbc w_lm                ; [W1b] (admission: a margin kept)
    bcc @over
    jsr BandLinesOver       ; include overlap with this image's previous band
    bcs @over
    lda w_b
    asl a
    tax
    lda bs_sl,x
    sec
    sbc bs_obj,x
    cmp #2
    bcs @cnt               ; 34 tiles minus >=2 wide cells is at most 32 OBJs
    lda #32
    sec
    sbc bs_obj,x
    bcc @over
    sbc bs_selfobj
    bcc @over
    sta obj_limit
    jsr LinesOver           ; slivers bound OBJ count, so most bands exit here
    bcc @cnt
    jsr ObjLinesOver
    bcc @cnt
    bra @over
@nol:
    lda #$FFFF
    sta bs_lin,x
    bra @cnt
@over:
    inc w_skip              ; [W1b] (left out: no pieces, no lines)
    lda w_b
    asl a
    tay
    lda #0
    sta bs_ln,y
    lda #$FFFF
    sta bs_lin,y
    jmp @next
@cnt:
    lda z:w_short
    lsr a
    lda w_pc
    bcs @short_count
    ldx w_small
    beq @oam_count
    asl a                  ; two stacked 8x8s per narrow, full-height cell
    bra @oam_count
@short_count:
    ldx w_small
    bne @oam_count
    asl a                  ; two horizontal 8x8s per wide, short-height cell
@oam_count:
    clc
    adc w_noam
    sta w_noam
    lda w_pc
    clc
    adc w_npc
    sta w_npc
    lda w_clip
    beq @cached
    lda w_b
    inc a
    cmp w_b1
    bne @cached
    ; Partial bands use private cells: never modify a shared cached image.
    lda w_new
    clc
    adc w_pc
    sta w_new
    lda w_pc
    asl a
    adc w_pc
    asl a                   ; full upload plus at most five zero-row patches
    clc
    adc w_runs
    sta w_runs
    jmp @next
@cached:
    ; A complete slot cannot contain PNONE. Partial hill bands above still
    ; reserve private cells; all admission/scanline checks remain unchanged.
    lda z:w_full
    bne @next
    ; ---- cells: pieces without one, runs of them ----
    lda w_rs
    cmp #$FFFF
    bne @res
    lda w_pc                ; (no slot: all new, one run per 8)
    clc
    adc w_new
    sta w_new
    lda w_pc
    clc
    adc #7
    lsr a
    lsr a
    lsr a
    clc
    adc w_runs
    sta w_runs
    bra @next
@res:
    xba
    sta w_t
    ; LinesOver's clipped, odd-height path uses Y as scratch.
    lda w_b
    asl a
    tay
    lda bs_ln,y
    and #$00FF
    ora w_t
    tax                     ; SL_MAP offset of the first
    lda #1
    sta w_last              ; (previous piece resident / band start)
    ldy w_pc
@p: lda f:SL_MAP,x
    and #$00FF
    cmp #PNONE
    bne @r
    inc w_new
    lda w_last
    beq :+
    stz w_last
    inc w_runs
:   bra @pn
@r: lda #1
    sta w_last
@pn:
    inx
    dey
    bne @p
@next:
    inc w_b
    jmp @band

; BandRange: band w_b of image w_img at w_x (w_xm mirrored) -> the pieces
; with their 16 columns on screen: bs_ln[band] = first | count << 8, A =
; count (Z: none), Y = band * 2.  w_hin set (SetHin): the image is inside
; the screen horizontally, all pieces count.
BandRange:
    lda w_b
    asl a
    tay
    lda [bp],y              ; first piece of the band
    sta w_j
    iny
    iny
    lda [bp],y
    sta w_jend              ; last + 1
    dey
    dey
    sec
    sbc w_j
    bne :+
    jmp @none
:   ldx w_hin
    beq :+
    xba                     ; (all on screen)
    ora w_j
    sta bs_ln,y
    xba
    and #$00FF
    rts
:   lda w_mir
    bne @m
    ; x = w_x + offset (ascending): skip x <= -16 from the start, x >= 256
    ; from the end
@lo:
    lda w_j
    asl a
    adc w_xso               ; (C clear)
    tay
    lda [bp],y
    clc
    adc w_x
    clc
    adc #16
    bmi :+
    bne @hi
:   inc w_j
    lda w_j
    cmp w_jend
    bne @lo
    bra @none
@hi:
    lda w_jend
    cmp w_j
    beq @none
    dec a
    asl a
    adc w_xso               ; (C clear)
    tay
    lda [bp],y
    clc
    adc w_x
    cmp #256
    bmi @cnt
    dec w_jend
    bra @hi
    ; mirrored: x = w_xm - offset (descending): skip x >= 256 from the start,
    ; x <= -16 from the end
@m:
@mlo:
    lda w_j
    asl a
    adc w_xso               ; (C clear)
    tay
    lda w_xm
    sec
    sbc [bp],y
    cmp #256
    bmi @mhi
    inc w_j
    lda w_j
    cmp w_jend
    bne @mlo
    bra @none
@mhi:
    lda w_jend
    cmp w_j
    beq @none
    dec a
    asl a
    adc w_xso               ; (C clear)
    tay
    lda w_xm
    sec
    sbc [bp],y
    clc
    adc #16
    bmi :+
    bne @cnt
:   dec w_jend
    bra @mhi
@cnt:
    lda w_b
    asl a
    tay
    lda w_jend
    sec
    sbc w_j
    xba
    ora w_j
    sta bs_ln,y
    xba
    and #$00FF
    rts
@none:
    lda w_b
    asl a
    tay
    lda #0
    sta bs_ln,y
    rts

; A 16px OBJ at x <= -8 or x >= 248 fetches only one 8px sliver.
; Charge the actual hardware fetches, including a padded last image piece.
BandSlivers:
    lda w_small
    bne @save               ; narrow columns already charge one sliver
    lda w_x
    bmi @edges
    clc
    adc w_w
    cmp #242
    bcc @save
@edges:
    lda w_j
    jsr BandEdge
    lda w_jend
    dec a
    cmp w_j
    beq @save
    jsr BandEdge
@save:
    lda w_b
    asl a
    tax
    lda w_gn
    sta bs_sl,x
    rts
BandEdge:
    asl a
    clc
    adc w_xso
    tay
    lda w_mir
    beq @ltr
    lda w_xm
    sec
    sbc [bp],y
    bra @test
@ltr:
    lda [bp],y
    clc
    adc w_x
@test:
    bmi @left
    cmp #248
    bcc @done
    dec w_gn
    rts
@left:
    cmp #$FFF9              ; -7: both slivers still touch the viewport
    bcs @done
    dec w_gn
@done:
    rts

; SetHin: w_hin = 1 when the image (w_x, w_w) is inside the screen
; horizontally (every piece of every band visible)
SetHin:
    stz w_hin
    lda w_x
    bmi :+
    clc
    adc w_w
    cmp #257
    bcs :+
    inc w_hin
:   rts

; LinesPairs: lines [w_gmin, w_gmax] (1-16): X = w_gmin + 2 * pairs, w_u =
; 8 - pairs (the first unrolled word operation), C = odd line count
LinesPairs:
    lda w_gmax
    sec
    sbc w_gmin
    inc a
    lsr a                   ; pairs, C = odd
    php
    sta w_u+2
    asl a
    adc w_gmin              ; (C clear)
    tax
    lda #8
    sec
    sbc w_u+2
    sta w_u
    plp
    rts

; Packed final bands overlap the preceding band's transparent padding.
; Admission has not committed either band yet: include that self-overlap
; on its actual shared rows before testing against already placed objects.
BandLinesOver:
    ldx w_lift
    bne :+
    jmp LinesOver
:   sta bs_limit
    stz bs_selfobj
    lda w_b
    inc a
    cmp w_b1
    bne @normal
    lda w_b
    cmp w_b0
    beq @normal
    asl a
    tax
    lda bs_ln-2,x
    and #$FF00
    beq @normal
    lda bs_short-2,x
    bne @normal              ; a preceding short band does not overlap
    lda bs_obj-2,x
    sta bs_selfobj
    lda bs_limit
    sec
    sbc bs_sl-2,x
    bcc @over
    pha
    lda w_gmax
    sta bs_max
    lda w_b
    asl a
    asl a
    asl a
    asl a
    clc
    adc w_y
    dec a
    sta w_gmax
    pla
    jsr LinesOver
    php
    lda bs_max
    sta w_gmax
    plp
    bcs @over
@normal:
    lda bs_limit
    jmp LinesOver
@over:
    sec
    rts

; LinesOver: A = limit (0-34): C set if a line in [w_gmin, w_gmax] holds
; more slivers.  Two lines per word: byte + (127 - limit) sets bit 7 iff
; the byte is over (ln_sl bytes are <= 34: no carry between the bytes).
LinesOver:
    ; bucket bounds (16 lines each): none over the limit, no line is
    sta z:w_kk
    lda w_gmin
    lsr a
    lsr a
    lsr a
    lsr a
    tax
    lda ln_ub,x
    and #$00FF
    cmp z:w_kk
    beq :+
    bcs @exact
:   lda w_gmax
    lsr a
    lsr a
    lsr a
    lsr a
    tax
    lda ln_ub,x
    and #$00FF
    cmp z:w_kk
    beq :+
    bcs @exact
:   clc
    rts
@exact:
    lda z:w_kk
    eor #$007F
    sta z:w_kk
    xba
    ora z:w_kk
    sta z:w_kk              ; 127 - limit in both bytes
    lda w_gmax
    sec
    sbc w_gmin
    cmp #15
    bne @gen
    lda w_gmin              ; 16 lines: all 8 words
    adc #15                 ; (C set: + 16)
    tax
    clc
    bra @chk
@gen:
    jsr LinesPairs
    bcc :+
    txy
    ldx w_gmax
    lda ln_sl,x             ; (the odd last line)
    tyx
    and #$00FF
    clc
    adc z:w_kk
    and #$0080
    bne @ov
:   lda w_u
    asl a
    asl a
    adc w_u
    asl a                   ; 10 * (8 - pairs)
    adc #.loword(@chk)
    sta z:w_jmp
    clc
    jmp (w_jmp)
@chk:
    .repeat 8, I
    lda a:ln_sl-16+2*I,x
    adc z:w_kk
    and #$8080
    bne @ov
    .endrepeat
@chke:
    clc
    rts
@ov:
    sec
    rts
.assert @chke - @chk = 80, error, "LinesOver step"

; LinesAdd: lines [w_gmin, w_gmax] += w_gn slivers (and their buckets'
; bounds, saturated); w_disc is the tile-fetch minus OBJ-count increment.
LinesAdd:
    lda w_gmax
    lsr a
    lsr a
    lsr a
    lsr a
    sta z:w_kk              ; (last bucket)
    lda w_gmin
    lsr a
    lsr a
    lsr a
    lsr a
    tax
@ub:
    sep #$20
    .a8
    lda ln_ub,x
    clc
    adc w_gn
    bcc :+
    lda #$FF
:   sta ln_ub,x
    rep #$20
    .a16
    cpx z:w_kk
    inx
    bcc @ub
    lda z:w_disc
    beq :+
    jmp LinesAddBoth
:   lda w_gn
    xba
    ora w_gn
    sta z:w_kk              ; slivers in both bytes
    lda w_gmax
    sec
    sbc w_gmin
    cmp #15
    bne @gen
    lda w_gmin              ; 16 lines: all 8 words
    adc #15                 ; (C set: + 16)
    tax
    clc
    bra @add
@gen:
    jsr LinesPairs
    bcc :+
    txy
    ldx w_gmax
    sep #$20
    .a8
    lda ln_sl,x             ; (the odd last line)
    clc
    adc w_gn
    sta ln_sl,x
    rep #$20
    .a16
    tyx
:   lda w_u
    asl a
    asl a
    asl a                   ; 8 * (8 - pairs)
    adc #.loword(@add)
    sta z:w_jmp
    clc
    jmp (w_jmp)
@add:
    .repeat 8, I
    lda a:ln_sl-16+2*I,x
    adc z:w_kk
    sta a:ln_sl-16+2*I,x
    .endrepeat
@adde:
    rts
.assert @adde - @add = 64, error, "LinesAdd step"

; The discount only changes for wide 16px sprites. Tiny objects cost no
; counter updates, and only nearly-full lines need an exact OBJ check.
.segment "BSS"
obj_limit: .res 2
.segment "SA1CODE"
ObjLinesOver:
    ldx w_gmin
    sep #$20
    .a8
@line:
    lda ln_sl,x
    sec
    sbc ln_disc,x
    cmp obj_limit
    beq @next
    bcs @over
@next:
    inx
    cpx w_gmax
    bcc @line
    beq @line
    rep #$20
    .a16
    clc
    rts
@over:
    rep #$20
    .a16
    sec
    rts
; Update slivers and OBJ discounts in one traversal, including odd-height
; clips. Counts stay below 128, so packed byte additions cannot carry.
LinesAddBoth:
    lda z:w_disc
    xba
    ora z:w_disc
    sta z:w_dpair
    lda w_gn
    xba
    ora w_gn
    sta z:w_kk
    lda w_gmax
    sec
    sbc w_gmin
    cmp #15
    bne @gen
    lda w_gmin
    adc #15                 ; C set: +16
    tax
    clc
    bra @add
@gen:
    jsr LinesPairs
    bcc :+
    txy
    ldx w_gmax
    sep #$20
    .a8
    lda ln_sl,x
    clc
    adc w_gn
    sta ln_sl,x
    lda ln_disc,x
    clc
    adc z:w_disc
    sta ln_disc,x
    rep #$20
    .a16
    tyx
:   lda w_u
    asl a
    asl a
    asl a
    asl a                   ; 16 * (8 - pairs)
    adc #.loword(@add)
    sta z:w_jmp
    clc
    jmp (w_jmp)
@add:
    .repeat 8, I
    lda a:ln_sl-16+2*I,x
    adc z:w_kk
    sta a:ln_sl-16+2*I,x
    lda a:ln_disc-16+2*I,x
    adc z:w_dpair
    sta a:ln_disc-16+2*I,x
    .endrepeat
@adde:
    rts
.assert @adde - @add = 128, error, "LinesAddBoth step"

;----------------------------------------------------------------------------
; Hopeless (main pass, before PlaceImg): C set when Show would refuse the
; entry anyway for cells / DMA (not the car group, the exact image not
; resident, no resident last image of the same frame to fall back on)
;----------------------------------------------------------------------------
Hopeless:
    lda sv_nok
    cmp #CELL_RES + 1
    bcc @low
    lda sv_dma
    cmp #128 + RUN_OVH
    bcs @ok
@low:
    lda w_obj               ; (the car group: see Show)
    and #$007F
    cmp #SPRITE_FERRARI
    bcc :+
    cmp #SPRITE_TRAFF1
    bcc @ok
    cmp #SPRITE_CRASH
    bcc :+
    cmp #JUMP_ENTRIES_TOTAL
    bcc @ok
:   lda w_img
    jsr FindSlot
    cmp #$FFFF
    bne @ok
    lda w_obj
    asl a
    tax
    lda w_dsc
    cmp f:LAST_DSC,x
    bne @no
    lda f:LAST_IMG,x
    cmp #$FFFF
    beq @no
    jsr FindSlot
    cmp #$FFFF
    bne @ok
@no:
    inc sv_stat+12
    sec
    rts
@ok:
    clc
    rts

; No allocations occur between this check and claiming a complete slot's
; ordinary bands. A clipped final band can allocate only after those bands.
SlotComplete:
    stz z:w_full
    lda w_rs
    cmp #$FFFF
    beq @done
    asl a
    tax
    lda f:SL_NRES,x
    cmp f:SL_NP,x
    bne @done
    inc z:w_full
@done:
    rts


;----------------------------------------------------------------------------
; ClaimPass: entry w_i accepted with image w_img, slot w_rs, bands
; [w_b0, w_b1) (bs_ln, bs_lin): per band its lines get the slivers; per
; piece on screen: resident -> its cell claimed (used this frame: protected
; next frame), missing -> runs of cells + FIFO uploads (one entry per run);
; then its OAM entry is written (w_st / w_oi: the next one)
;----------------------------------------------------------------------------
ClaimPass:
    lda w_new
    beq @resident
    ldy #10
    lda [ip],y
    sta w_src               ; pixel data offset
    ldy #12
    lda [ip],y
    and #$00FF
    sta w_srcb
    ldy #9
    lda [ip],y
    and #$0007
    ora #$0080
    xba
    tsb w_srcb              ; bank | ($80 | block) << 8 (FIFO UQ_BANK / UQ_TYPE)
@resident:
    ; x of a piece = w_xo + (its offset ^ w_hx): w_x + offset, mirrored
    ; (w_x + w_w - 16) - offset = (w_x + w_w - 15) + ~offset
    lda w_mir
    beq :+
    lda w_x
    clc
    adc w_w
    sec
    sbc #15
    sta w_xo
    lda #$FFFF
    bra :++
:   lda w_x
    sta w_xo
    lda #0
:   sta w_hx
    ; SL_MAP page of the slot; the piece x offsets by SL_MAP offset:
    ; [ip],y with y = SL_MAP offset * 2 (ip = bp + w_xso - page * 2, 24-bit)
    lda w_rs
    xba
    sta w_mapb
    asl a
    sta w_t
    sep #$20
    .a8
    lda bp+2
    sta ip+2
    rep #$20
    .a16
    lda bp
    clc
    adc w_xso
    bcc :+
    sep #$20
    .a8
    inc ip+2
    rep #$20
    .a16
:   sec
    sbc w_t
    sta ip
    bcs :+
    sep #$20
    .a8
    dec ip+2
    rep #$20
    .a16
:   ; OAM write offset limit (w_xm): 128 entries at most (safety net)
    lda #128
    sec
    sbc w_oi
    bcs :+
    lda #0
:   asl a
    asl a
    clc
    adc w_st
    sta w_xm
    lda w_b0
    sta w_b
@band:
    lda w_b
    cmp w_b1
    bcc :+
    jmp @done
:   asl a
    tay
    lda bs_short,y
    sta z:w_short
    lda bs_ln,y
    and #$00FF
    sta w_j
    lda bs_ln+1,y
    and #$00FF
    bne :+
    jmp @next
:   sta w_gn
    clc
    adc w_j
    sta w_jend
    lda w_ne                ; [W1b] (loading: no lines)
    cmp #1
    beq @nolines
    lda bs_lin,y            ; lines on screen: + 2 slivers per piece
    cmp #$FFFF
    beq @nolines
    phy
    tax
    and #$00FF
    sta w_gmin
    txa
    xba
    and #$00FF
    sta w_gmax
    lda bs_sl,y
    sta w_gn
    sec
    sbc bs_obj,y
    sta z:w_disc
    jsr LinesAdd
    ply
@nolines:
    lda w_new
    beq @bandxy
    lda [bp],y
    sta w_cum               ; first piece of the band
    iny
    iny
    lda [bp],y
    sec
    sbc w_cum
    sta w_bn                ; pieces of the band
@bandxy:
    lda w_b
    asl a
    tax
    lda bs_y8,x
    sta w_y8
    lda w_j                 ; SL_MAP offsets of the pieces
    ora w_mapb
    sta w_mo
    sta w_lastmo            ; (pieces before it were allocated now: no claim)
    lda w_xm                ; (the OAM room left: (w_xm - w_st) / 4)
    sec
    sbc w_st
    lsr a
    lsr a
    clc
    adc w_mo
    sta w_t
    lda w_jend
    ora w_mapb
    cmp w_t
    bcc :+
    lda w_t
:   sta w_mend
    ; Every ordinary 16x16 band can use the compact piece loop, including
    ; a partly resident image. Missing runs share the general allocator.
    lda w_ne
    cmp #1
    beq @p
    lda w_small
    ora z:w_short
    bne @p
    lda w_clip
    beq @fast
    lda w_b
    inc a
    cmp w_b1
    beq @p
@fast:
    jsr ClaimWideBand
    jmp @next
@p: ldx w_mo
    cpx w_mend
    bcc :+
    jmp @next
:   lda w_clip
    beq @cached
    lda w_b
    inc a
    cmp w_b1
    bne @cached
    jsr ClipPiece
    bcc @emit
    jmp @ne
@cached:
    ldx w_mo
    lda f:SL_MAP,x
    and #$00FF
    cmp #PNONE
    bne :+
    jmp @nw
:   asl a
    cpx w_lastmo
    tax                     ; (cell * 2)
    bcc @emit               ; (allocated now: claimed already)
    ; claim: used this frame (displayed next frame, not usable any more)
    lda f:CellRow2,x
    tay
    lda f:CellBit2,x
    sta w_t
    ora av_now,y
    sta av_now,y
    lda w_t
    and av_ok,y
    beq @emit
    eor av_ok,y
    sta av_ok,y
    dec sv_nok
@emit:
    lda w_ne                ; [W1b] (loading: no OAM entry)
    cmp #1
    beq @ne
    ; ---- the OAM entry: x, y, tile, attributes ----
    lda f:CellTile,x
    ora w_attr
    ldx w_st
    sta f:$400002,x
    lda w_mo
    asl a
    tay
    lda [ip],y
    eor w_hx
    clc
    adc w_xo
    ldy w_small
    beq :+
    ldy w_mir
    beq :+
    clc
    adc #8                  ; mirrored left-half pixels occupy the right half
:
    bit #$0100
    bne @x9
@xb:
    and #$00FF
    ora w_y8
    sta f:$400000,x
    lda w_small
    beq @wide
    jsr EmitNarrow
    bra @emitted
@wide:
    lda z:w_short
    lsr a
    bcc @regular
    jsr EmitShort
    bra @emitted
@regular:
    lda #2
    tsb w_sizes
    txa
    clc
    adc #4
    sta w_st
@emitted:
    inc w_mo
    jmp @p
@ne:
    inc w_mo
    jmp @p
@nx:
    jmp @next
@nw:
    jmp @new
@x9:
    pha
    ldy w_stg
    bne @xst
    stx w_t                 ; (index: 128 - (w_xm - w_st) / 4)
    lda w_xm
    sec
    sbc w_t
    lsr a
    lsr a
    eor #$FFFF
    sec
    adc #128
    jsr OamHiX              ; (x bit 8)
    pla
    bra @xb
@xst:
    sty w_x9                ; [W1b] (the entry has some: CopyStaged looks)
    lda f:$400002,x         ; (staged: x bit 8 as attribute bit 15, see
    ora #$8000              ; CopyStaged)
    sta f:$400002,x
    pla
    bra @xb
@new:
    jsr ClaimNewRun
    jmp @p
@next:
    inc w_b
    jmp @band
@done:
    lda w_xm                ; OAM entries written: 128 - (w_xm - w_st) / 4
    sec
    sbc w_st
    lsr a
    lsr a
    eor #$FFFF
    sec
    adc #128
    sta w_oi
    rts

; Ordinary wide bands. w_mend enforces the general loop's OAM limit.
; Even an image wholly on screen can have a mirrored padding cell at x<0;
; preserve the ninth X bit for those cells as well as off-screen images.
ClaimWideBand:
    lda #2
    tsb w_sizes
@piece:
    ldx w_mo
    cpx w_mend
    bcc :+
    rts
:   lda f:SL_MAP,x
    and #$00FF
    cmp #PNONE
    bne :+
    jsr ClaimNewRun
    jmp @piece
:   asl a
    cpx w_lastmo
    tax
    bcc @emit               ; AllocRun has already claimed these cells
    lda f:CellRow2,x
    tay
    lda f:CellBit2,x
    sta w_t
    ora av_now,y
    sta av_now,y
    lda w_t
    and av_ok,y
    beq @emit
    eor av_ok,y
    sta av_ok,y
    dec sv_nok
@emit:
    lda f:CellTile,x
    ora w_attr
    ldx w_st
    sta f:$400002,x
    lda w_mo
    asl a
    tay
    lda [ip],y
    eor w_hx
    clc
    adc w_xo
    bit #$0100
    beq @xy
    pha
    ldy w_stg
    beq @direct
    sty w_x9
    lda f:$400002,x
    ora #$8000
    sta f:$400002,x
    bra @restore
@direct:
    stx w_t
    lda w_xm
    sec
    sbc w_t
    lsr a
    lsr a
    eor #$FFFF
    sec
    adc #128
    jsr OamHiX
@restore:
    pla
@xy:
    and #$00FF
    ora w_y8
    sta f:$400000,x
    txa
    clc
    adc #4
    sta w_st
    inc w_mo
    jmp @piece

ClaimNewRun:
    ; a run of missing pieces (at most RUN_MAX, in one cell row)
    lda w_mo
    and #$00FF
    sta w_j
    ldy #1
@rl:
    tya
    clc
    adc w_j
    cmp w_jend
    bcs @rd
    inx
    lda f:SL_MAP,x
    and #$00FF
    cmp #PNONE
    bne @rd
    iny
    cpy #RUN_MAX
    bcc @rl
@rd:
    sty w_t
    lda w_ne                ; loading: the runs the DMA budget allows
    beq @ra
    lda sv_dma
    sec
    sbc #RUN_OVH
    bcc @rn
    asl a
    xba
    and #$01FF              ; (budget - RUN_OVH) / 128 pieces
    beq @rn
    cmp w_t
    bcs @ra
    sta w_t
@ra:
    jsr AllocRun            ; -> A = first cell, w_t = cells
    bcc :+
@rn:
    inc w_mo                ; (none: the piece stays without a cell)
    rts
:   sta w_pc
    asl a
    sta w_cell              ; cell * 2
    lda w_t
    sta w_rc
    lda w_mo
    clc
    adc w_t
    sta w_lastmo            ; (these are claimed by AllocRun)
    lda w_j
    pha
@o: ldx w_cell
    jsr EvictCell           ; (its old owner)
    lda w_rs
    xba
    ora w_j
    sta w_u+2               ; SL_MAP offset of the piece
    ldx w_cell
    sta f:VC_OWN,x
    txa
    lsr a                   ; cell
    ldx w_u+2
    sep #$20
    .a8
    sta f:SL_MAP,x
    rep #$20
    .a16
    inc w_cell
    inc w_cell
    inc w_j
    dec w_rc
    bne @o
    ; Commit the run's resident count once. The slot is stamped for this
    ; frame before ClaimPass, so EvictCell cannot free it mid-run even if
    ; an old cell of this same image was evicted.
    lda w_rs
    asl a
    tax
    lda f:SL_NRES,x
    clc
    adc w_t
    sta f:SL_NRES,x
    ; FIFO: top halves of the run's cells from the pieces' top halves
    jsr FifoWait
    lda SH_UQW
    asl a
    asl a
    asl a
    tax
    lda w_pc
    asl a
    tay
    lda CellTile,y
    asl a
    asl a
    asl a
    asl a                   ; * 16 words
    clc
    adc #OBJ_VRAM
    sta f:UQ_BUF+UQ_DEST,x
    pla                     ; (first piece of the run)
    sta w_j
    clc
    adc w_cum               ; top halves: data + 128 * first + 64 * (j - first)
    asl a
    asl a
    asl a
    asl a
    asl a
    asl a                   ; * 64
    clc
    adc w_src
    sta f:UQ_BUF+UQ_SRC,x
    lda w_srcb
    sta f:UQ_BUF+UQ_BANK,x
    lda w_bn
    xba
    asl a
    asl a                   ; band pieces << 10
    sta w_u
    lda w_t
    xba
    lsr a
    lsr a                   ; cells * 64
    ora w_u
    sta f:UQ_BUF+UQ_SIZE,x
    lda SH_UQW
    inc a
    and #UQ_MASK
    sta SH_UQW
    ; DMA budget
    lda w_t
    xba
    lsr a                   ; * 128
    clc
    adc #RUN_OVH
    sta w_u
    clc
    adc sv_up
    sta sv_up
    lda sv_dma
    sec
    sbc w_u
    bcs :+
    lda #0
:   sta sv_dma
    rts                     ; caller emits the newly resident pieces

; ClaimCell: A = cell: used this frame (stamp, no longer usable)
ClaimCell:
    phx
    pha
    lsr a
    lsr a
    lsr a
    tay                     ; row
    pla
    and #$0007
    tax
    sep #$20
    .a8
    lda f:BitMask,x
    ora av_now,y
    sta av_now,y            ; (claimed: displayed next frame)
    lda f:BitMask,x
    and av_ok,y
    beq :+
    eor av_ok,y
    sta av_ok,y             ; (it was usable)
    rep #$20
    .a16
    dec sv_nok
    plx
    rts
:   rep #$20
    .a16
    plx
    rts

; EvictCell: X = cell * 2: its owner piece loses it (a slot left without
; cells and not used this frame is freed)
EvictCell:
    lda f:VC_OWN,x
    cmp #$FFFF
    beq @d
    tax
    sep #$20
    .a8
    lda #PNONE
    sta f:SL_MAP,x
    rep #$20
    .a16
    txa
    xba
    and #$00FF
    asl a
    tax                     ; slot * 2
    lda f:SL_NRES,x
    dec a
    sta f:SL_NRES,x
    bne @d
    lda f:SL_STAMP,x
    cmp z:sv_fr
    beq @d
    txa
    lsr a
    jmp FreeSlot
@d: rts

;----------------------------------------------------------------------------
; AllocRun: w_t = cells wanted (1-8) -> A = the first of a run of w_t
; consecutive usable cells of one cell row (free ones first, else evictable
; ones from a rotating row); w_t is reduced to the longest run left when
; no row has w_t; C set: none at all
;----------------------------------------------------------------------------
AllocRun:
    lda sv_nfc              ; (free cells: only when enough)
    cmp w_t
    bcc @ok0
    ldy #15
@f: lda av_free,y
    and #$00FF
    tax
    lda f:MaxRun,x
    and #$00FF
    cmp w_t
    bcs @hitf
    dey
    bpl @f
@ok0:
    stz w_v+2               ; (longest run seen)
    lda sv_shand            ; (evictable: from a rotating row)
    and #$000F
    tay
    lda #16
    sta w_v
@o: lda av_ok,y
    and #$00FF
    tax
    lda f:MaxRun,x
    and #$00FF
    cmp w_t
    bcs @hito
    cmp w_v+2
    bcc :+
    sta w_v+2
:   iny
    tya
    and #$000F
    tay
    dec w_v
    bne @o
    lda w_v+2
    bne :+
    sec
    rts
:   sta w_t                 ; (shorter: the longest left)
    bra AllocRun
@hito:
    tya
    inc a
    sta sv_shand
    lda av_ok,y
    bra @pos
@hitf:
    lda av_free,y
@pos:
    ; position p of the run in the row mask
    and #$00FF
    asl a
    asl a
    asl a
    clc
    adc w_t
    dec a
    tax
    lda f:RunAt,x
    and #$00FF
    ; first cell = row * 8 + p; the run's bits: claimed, not free / usable
    sta w_u
    tya
    asl a
    asl a
    asl a
    ora w_u
    pha
    ldx w_t
    lda f:RunBits-1,x       ; k low bits set
    and #$00FF
    ldx w_u
    beq :++
:   asl a
    dex
    bne :-
:   sta w_u+2               ; (the run's bits)
    lda av_free,y           ; free cells taken: fewer free
    and w_u+2
    and #$00FF
    tax
    lda f:PopCnt,x
    and #$00FF
    eor #$FFFF
    sec
    adc sv_nfc
    sta sv_nfc
    lda w_u+2
    sep #$20
    .a8
    pha
    ora av_now,y
    sta av_now,y
    pla
    eor #$FF
    pha
    and av_free,y
    sta av_free,y
    pla
    and av_ok,y
    sta av_ok,y
    rep #$20
    .a16
    lda sv_nok
    sec
    sbc w_t
    sta sv_nok
    pla
    clc
    rts

;----------------------------------------------------------------------------
; Resident image slots: SL_HASH buckets (image & $FF) chain the slots
;----------------------------------------------------------------------------
; FindSlot: A = image -> A = slot ($FFFF none)
FindSlot:
    sta w_u+2
    and #$00FF
    asl a
    tax
    lda f:SL_HASH,x
@l: beq @no
    dec a
    asl a
    tax
    lda f:SL_IMG,x
    cmp w_u+2
    beq @y
    lda f:SL_NEXT,x
    bra @l
@y: txa
    lsr a
    rts
@no:
    lda #$FFFF
    rts

; SlotNew: image w_img -> w_rs = a new slot (a free one, else the least
; recently used one not displayed / used now, its cells freed); C set none
SlotNew:
    lda sv_nfree
    bne @pop
    ; evict: the next slot (from the hand) last used before the displayed frame
    ldy #NSLOT
    ldx sv_slhand
@e: inx
    inx
    cpx #NSLOT*2
    bcc :+
    ldx #0
:   lda z:sv_fr
    sec
    sbc f:SL_STAMP,x
    cmp #2
    bcs @ev
    dey
    bne @e
    sec
    rts
@ev:
    stx sv_slhand
    txa
    lsr a
    jsr DropSlot
@pop:
    dec sv_nfree
    lda sv_nfree
    asl a
    tax
    lda f:SV_FREE,x
    sta w_rs                ; slot * 2
    tax
    lda w_img
    sta f:SL_IMG,x
    lda #0
    sta f:SL_NRES,x
    lda z:sv_fr
    sta f:SL_STAMP,x
    ; hash: at the head of the image's bucket
    lda w_img
    and #$00FF
    asl a
    tay
    tyx
    lda f:SL_HASH,x
    ldx w_rs
    sta f:SL_NEXT,x
    txa
    lsr a
    inc a
    tyx
    sta f:SL_HASH,x
    ; map: the image's pieces without a cell
    ldy #14
    lda [ip],y              ; pieces
    ldx w_rs
    sta f:SL_NP,x
    inc a
    lsr a
    tay
    lda w_rs
    lsr a
    sta w_rs                ; (slot)
    xba
    tax
    lda #PNONE | PNONE << 8
:   sta f:SL_MAP,x
    inx
    inx
    dey
    bne :-
    clc
    rts

; DropSlot: A = slot (not displayed, not used now): its cells freed (its
; map's pieces), the slot freed
DropSlot:
    sta w_u
    asl a
    tax
    lda f:SL_NP,x
    sta w_v                 ; pieces
    lda w_u
    xba
    tax                     ; SL_MAP offset of piece 0
@c: lda f:SL_MAP,x
    and #$00FF
    cmp #PNONE
    beq @n
    phx
    asl a
    tax
    lda #$FFFF
    sta f:VC_OWN,x
    ; usable already (not displayed): now also free
    txa
    lsr a
    pha
    lsr a
    lsr a
    lsr a
    tay
    pla
    and #$0007
    tax
    sep #$20
    .a8
    lda f:BitMask,x
    ora av_free,y
    sta av_free,y
    rep #$20
    .a16
    inc sv_nfc
    plx
@n: inx
    dec w_v
    bne @c
    lda w_u
; FreeSlot: A = slot: unlinked from its hash chain, pushed on the free stack
FreeSlot:
    asl a
    sta w_u                 ; slot * 2
    tax
    lda f:SL_IMG,x
    and #$00FF
    asl a
    sta w_u+2               ; bucket * 2
    tax
    lda f:SL_HASH,x         ; first slot + 1
    beq @free               ; (not linked: should not happen)
    dec a
    asl a
    cmp w_u
    bne @walk
    ldx w_u                 ; (the head)
    lda f:SL_NEXT,x
    ldx w_u+2
    sta f:SL_HASH,x
    bra @free
@walk:                      ; A = slot * 2 of a chain member before ours
    tax
    lda f:SL_NEXT,x
    beq @free               ; (not linked)
    dec a
    asl a
    cmp w_u
    bne @walk
    phx                     ; (X = the predecessor)
    ldx w_u
    lda f:SL_NEXT,x
    plx
    sta f:SL_NEXT,x
@free:
    ldx w_u
    lda #$FFFF
    sta f:SL_IMG,x
    lda sv_nfree
    asl a
    tax
    lda w_u
    sta f:SV_FREE,x
    inc sv_nfree
    rts

;----------------------------------------------------------------------------
; [W1b] ScanPass (start of the frame): the car group entries (pc_idx, by
; rank: CarRank), the first tier (t1: not dropped, shown / loading the last
; frame, landmarks, traffic, very large ones: key from LARGE_KEY on) sorted by key
; x 4 (seniors: shown AGE_S frames in a row, landmarks, traffic) / x 2 (shown
; or loading) / x 1, the others (t2) in depth order
;----------------------------------------------------------------------------
ScanPass:
    stz w_ncar
    stz t1_n
    stz t2_n
    lda sprite_count
    cmp #127
    bcc :+
    lda #127
:   sta w_i
@e: dec w_i
    bpl :+
    rts
:   lda w_i                 ; (hidden: left out.  [W1b] the same test as
    asl a                   ; CandGeom's first one: sprite_entries word 0, $5000)
    tay
    asl a
    asl a
    asl a
    tax
    lda f:sprite_entries,x
    and #$5000
    bne @e
    tyx
    lda f:hw_ent,x
    and #$00FF
    sta w_t                 ; (object)
    bit #$0080
    beq @main
    ; Dense scenes need the OBJ lines/cells for people and vehicles.
    ; Omit duplicated scenery shadows, keeping vehicle/flag shadows and
    ; the explicit Ferrari shadow. Do this before geometry/cache work.
    and #$007F
    cmp #SPRITE_ENTRIES
    bcs @nc
    lda sprite_count
    cmp #64
    bcc @nc
    jmp @e
@main:
    lda w_t
    tax
    jsr EntryRank
    cmp #4
    bcs @nc
    sta w_u                 ; car group: by rank (car, passengers, shadows,
    ldx w_ncar              ; flag man, smoke), depth order inside
    cpx #PC_MAX*2
    bcs @nc
@ci:
    cpx #0
    beq @cs
    lda pc_rk-2,x
    cmp w_u
    beq @cs
    bcc @cs
    sta pc_rk,x
    lda pc_idx-2,x
    sta pc_idx,x
    dex
    dex
    bra @ci
@cs:
    lda w_u
    sta pc_rk,x
    lda w_i
    sta pc_idx,x
    lda w_ncar
    inc a
    inc a
    sta w_ncar
    jmp @e
@nc:
    lda w_t
    cmp #SPRITE_SMOKE1
    beq @effect
    cmp #SPRITE_SMOKE2
    bne :+
@effect:
    lda #$8000              ; smoke follows complete people, arches and grid
    sta w_u+2
    jmp @ins
:   lda w_t
    bit #$0080
    bne @history
    asl a
    tax
    lda arch_root,x
    beq :+
    txa
    .repeat 5
    asl a
    .endrepeat
    tax
    lda f:JT+OE_ROAD_PRIORITY,x
    ora #$A000              ; complete near arches before distant decorations
    sta w_u+2
    jmp @ins
:   lda w_t
    asl a
    tax
    lda grid_people,x
    beq @history
    cmp #2
    bne :+
    jmp @e
:   txa
    ora #$C000              ; stable nearest-first crowd before decorations
    sta w_u+2
    jmp @ins
@history:
    lda w_t
    and #$007F
    asl a
    tax
    lda grid_decor,x
    cmp #2
    bne :+
    jmp @e
:   cmp #1
    bne :+
    lda #$9000
    sta w_u+2
    jmp @ins
:   lda w_t
    asl a
    tax
    lda f:OB_ST,x
    and #$00FF
    inc a
    eor z:sv_fr
    and #$00FF
    bne @t2                 ; (not placed the last frame)
    lda f:OB_KEY,x          ; (first tier: its sort key, Process)
    beq @t2
    sta w_u+2
@ins:
    ldx t1_n                ; (insertion, descending; equal keys: depth order)
    cpx #T1_MAX*2
    bcs @t2
@il:
    cpx #0
    beq @ip
    lda t1_key-2,x
    cmp w_u+2
    bcs @ip
    sta t1_key,x
    lda t1_idx-2,x
    sta t1_idx,x
    dex
    dex
    bra @il
@ip:
    lda w_u+2
    sta t1_key,x
    lda w_i
    asl a
    sta t1_idx,x
    lda t1_n
    inc a
    inc a
    sta t1_n
    jmp @e
@t2:
    ldx t2_n
    lda w_i
    asl a
    sta t2_idx,x
    inx
    inx
    stx t2_n
    jmp @e

; [W1b] PalAdd: A = key of entry w_i (on screen, not a shadow sprite): its
; palette's weight += key (the car group: $4000), listed in pl_list
PalAdd:
    sta w_t
    lda w_car
    beq :+
    lda #$FF00
    sta w_t
:   lda w_i
    asl a
    tax
    lda f:hw_pal,x
    and #$00FF
    tax
    lda w_t+1               ; (the largest key / 256, its object)
    sep #$20
    .a8
    cmp f:PAL_M,x
    bcc :+
    sta f:PAL_M,x
    lda w_obj
    sta pal_o,x
:   rep #$20
    .a16
    txa
    asl a
    tax
    lda f:PAL_W,x
    bne @a
    ldy w_npl
    cpy #PL_MAX*2
    bcs @r
    txa
    sta pl_list,y
    iny
    iny
    sty w_npl
    lda #0
@a: clc
    adc w_t
    bcc :+
    lda #$FFFF
:   sta f:PAL_W,x
@r: rts

; [W1b] PalPick (end of the frame): the slots' weights (slot_w: the largest
; key of the palette's entries + their keys / 4); the heaviest palette not
; loaded replaces the lightest slot's at the next frame's start (pp_pal /
; pp_slot) when more than twice as heavy (+16), at most every 8 frames;
; weights cleared
PalPick:
    ldy #14
@s: lda #$FFFF
    sta slot_ob,y
    ldx slot_pal,y
    cpx #$FFFF
    beq @z
    lda pal_o,x
    and #$00FF
    sta slot_ob,y
    jsr PalWt
    bra :+
@z: lda #0
:   sta slot_w,y
    dey
    dey
    bpl @s
    stz w_t                 ; (the heaviest not loaded: weight, pal_src)
    ldy #0
@b: cpy w_npl
    bcs @bd
    lda pl_list,y
    lsr a
    tax
    jsr PalWt
    cmp w_t
    bcc @bn
    beq @bn
    sta w_t+2
    lda f:PAL_MAP,x
    bit #$0080
    bne @bn                 ; (loaded)
    lda w_t+2
    sta w_t
    stx w_u
@bn:
    iny
    iny
    bra @b
@bd:
    lda pp_cool             ; (a change at most every 8 frames: 4 times here)
    beq :+
    dec pp_cool
    bra @clr
:   lda w_t
    beq @clr
    ldx #14                 ; (the lightest slot: weight, slot * 2)
    lda #$FFFF
    sta w_v
@m: lda slot_w,x
    cmp w_v
    bcs :+
    sta w_v
    stx w_v+2
:   dex
    dex
    bpl @m
    lda w_v                 ; heavier than 2 * lightest + 16: replaced next frame
    cmp #$7FF0
    bcs @clr
    asl a
    adc #16
    cmp w_t
    bcs @clr
    lda w_u
    sta pp_pal
    lda w_v+2
    sta pp_slot
    lda #3
    sta pp_cool
@clr:
    ldy #0                  ; (weights cleared)
@c: cpy w_npl
    bcs @cd
    ldx pl_list,y
    lda #0
    sta f:PAL_W,x
    txa
    lsr a
    tax
    sep #$20
    .a8
    lda #0
    sta f:PAL_M,x
    rep #$20
    .a16
    iny
    iny
    bra @c
@cd:
    stz w_npl
    rts

; PalWt: X = pal_src -> A = its weight: the largest key * 256 / 256 + the
; keys / 4 (saturated); keeps X, Y
PalWt:
    phx
    txa
    asl a
    tax
    lda f:PAL_W,x
    lsr a
    lsr a
    sta w_v
    plx
    lda f:PAL_M,x
    and #$00FF
    xba
    clc
    adc w_v
    bcc :+
    lda #$FFFF
:   rts

; LoadPal: A = pal_src, w_u+2 = slot * 2: the slot gets the palette (CGRAM
; 128 + slot * 16 <- SprPal[pal_src], 32 bytes, applied at the swap)
LoadPal:
    sta w_u
    ldx w_u+2
    lda slot_pal,x          ; (its old palette: no longer loaded)
    cmp #$FFFF
    beq :+
    tax
    sep #$20
    .a8
    lda #0
    sta f:PAL_MAP,x
    rep #$20
    .a16
:   ldx w_u+2
    lda w_u
    sta slot_pal,x
    tax
    lda w_u+2
    ora #$0080
    sep #$20
    .a8
    sta f:PAL_MAP,x
    rep #$20
    .a16
    lda w_u
    and #$00FF
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
    lda w_u+2               ; slot * 2
    asl a
    asl a
    asl a
    clc
    adc #128
    tax
    lda #1                  ; CGRAM
    ldy #32
    jmp QueueUpload

; [W1c] PalSubst: pal_src w_u of entry w_i (not loaded) -> A = the slot of a
; loaded substitute (PalSubT: equal in every colour index the entry's frame
; uses, DescIdx + 2), C clear; C set: none
PalSubst:
    lda w_i
    asl a
    asl a
    asl a
    asl a
    tax
    lda f:REC_BASE+RR_SRC,x
    sec
    sbc #.loword(SPR_D0)
    tax
    lda f:SPR_META+2,x
    sta w_t                 ; (colours used)
    lda w_u
    asl a
    adc w_u                 ; (C = 0)
    asl a                   ; pal_src * 6
    tax
    lda f:PalSubT,x         ; first substitute
    and #$00FF
    cmp #$00FF
    beq @no
    tay
    lda f:PalSubT+2,x
    and w_t
    bne @s2
    phx
    tyx
    lda f:PAL_MAP,x
    plx
    bit #$0080
    bne @ok
@s2:
    lda f:PalSubT+1,x       ; second one
    and #$00FF
    cmp #$00FF
    beq @no
    tay
    lda f:PalSubT+4,x
    and w_t
    bne @no
    tyx
    lda f:PAL_MAP,x
    bit #$0080
    beq @no
@ok:
    and #$000F
    lsr a
    clc
    rts
@no:
    sec
    rts

; PalFree: pal_src w_u (PalSlot) -> A = [W1b] the least recently used slot
; not used this frame (not the car group, landmarks, traffic: whose palette
; nobody used the last frame, or the requester's own), loaded with it (C set:
; none)
PalFree:
    lda #$FFFF
    sta w_t                 ; (its stamp)
    sta w_t+2               ; (slot * 2)
    ldx #14
@l: lda slot_stamp,x
    cmp sv_frame
    beq @n
    ldy w_car               ; (not the car group, landmarks, traffic: a palette
    bne :+                  ; nobody used the last frame, or its own: palette
    ldy w_big               ; animation)
    bne :+
    ldy slot_w,x
    beq :+
    ldy slot_ob,x
    cpy w_obj
    bne @n
:   cmp w_t
    bcs @n
    sta w_t
    stx w_t+2
@n: dex
    dex
    bpl @l
    ldx w_t+2
    bpl :+
    sec
    rts
:   stx w_u+2
    lda w_u
    jsr LoadPal
    lda w_u+2
    lsr a
    clc
    rts

; PalSlot: A = pal_src ($FFFF shadow: slot 0) -> A = its slot, C set if its
; palette is not loaded (w_u = pal_src)
PalSlot:
    cmp #$FFFF
    bne :+
    lda #0
    clc
    rts
:   sta w_u
    tax
    lda f:PAL_MAP,x         ; (slot * 2 | $80 when loaded)
    bit #$0080
    beq :+
    and #$000F
    lsr a
    clc
    rts
:   sec
    rts

.ifdef SPRTRAP
; Trap: X = code, A = value: debug stop (BW-RAM TRAP_REC: $DEAD, code, value,
; w_i, sv_oam, w_oi)
Trap:
    sta f:TRAP_REC+4
    txa
    sta f:TRAP_REC+2
    lda #$DEAD
    sta f:TRAP_REC
    lda w_i
    sta f:TRAP_REC+6
    lda sv_oam
    sta f:TRAP_REC+8
    lda w_oi
    sta f:TRAP_REC+10
:   bra :-
.endif

;============================================================================
; FinishOam: the entries past the ones written (w_oi) hidden, the high
; table; the buffer published (shown at the next swap)
;============================================================================
FinishOam:
    ; hide the rest (the entries this buffer showed last time past them)
    ldx w_st
    lda sv_back
    cmp #.loword(OAM_BUF0)
    beq :+
    lda #2
:   and #2
    tay
    lda oam_used,y
    sec
    sbc w_oi
    bcc @hs                 ; (fewer shown last time)
    beq @hs
    phy
    tay
@hh:
    lda #$E000
    sta f:$400000,x
    lda #0
    sta f:$400002,x
    inx
    inx
    inx
    inx
    dey
    bne @hh
    ply
@hs:
    lda w_oi
    sta oam_used,y
    ; high table (after the 128 entries)
    lda sv_back
    clc
    adc #512
    tax
    ldy #0
:   lda oam_hi,y
    sta f:$400000,x
    inx
    inx
    iny
    iny
    cpy #32
    bcc :-
    ; publish: this buffer at the next swap, build into the other one next
    lda sv_back
    sta SH_OAMSRC
    cmp #.loword(OAM_BUF0)
    bne :+
    lda #.loword(OAM_BUF1)
    bra :++
:   lda #.loword(OAM_BUF0)
:   sta sv_back
    rts

; CopyStaged: X = priority entry * 2: its staged OAM entries (pr_st) into
; the OAM buffer (w_st, w_oi)
CopyStaged:
    lda f:hw_ent,x
    bit #$0080
    beq CopyParentOK
    and #$007F
    tay
    lda parent_shown,y
    and #$00FF
    bne CopyParentOK
    rts
CopyParentOK:                    ; regression marker: only attached shadows pass
    .ifdef SPRTRAP
    lda pr_st,x
    xba
    and #$00FF
    clc
    adc w_oi
    cmp #129
    bcc :+
    ldx #3
    jmp Trap
:
    .endif
    lda #128                ; (safety net: at most the entries left)
    sec
    sbc w_oi
    beq @cs0
    bcc @cs0
    sta w_t
    lda pr_st,x
    xba
    and #$00FF
    bne :+
@cs0:
    rts
:   cmp w_t
    bcs :+
    sta w_t                 ; count
:
    lda pr_size,x
    sta w_sizes
    lda pr_st,x
    pha
    and #$007F
    sta copy_first
    asl a
    asl a
    clc
    adc #.loword(ST_OAM)
    tax                     ; first staged entry
    lda w_t
    asl a
    asl a
    dec a
    ldy w_st
    phb
    .byte $54, $40, $40     ; mvn (dest $40, source $40)
    plb
    lda w_sizes
    cmp #1
    bne :+
    phy
    jsr OamSmallRange
    ply
:   pla                     ; [W1b] (none with x bit 8: no look)
    and #$0080
    bne :+
    lda w_t
    clc
    adc w_oi
    sta w_oi
    sty w_st                ; (mvn: Y past the copy)
    rts
:   ; high table: x bit 8 (staged as attribute bit 15, never set otherwise)
    ldx w_st
    ldy w_t
@h:
    lda w_sizes
    cmp #3
    bne @sizeok
    phx
    ldx copy_first
    lda st_small,x
    and #$00FF
    beq :+
    lda w_oi
    phy
    jsr OamSmall
    ply
:   plx
@sizeok:
    inc copy_first
    lda f:$400002,x
    bpl :+
    and #$7FFF
    sta f:$400002,x
    lda w_oi
    phy
    jsr OamHiX              ; (keeps X)
    ply
:   inc w_oi
    inx
    inx
    inx
    inx
    dey
    bne @h
    stx w_st
    rts

; X is a freshly staged 8px-wide cell's first OAM entry. Its bottom
; half is tile +16; two 8x8 objects fetch one sliver on each of 16 lines.
EmitNarrow:
    phx
    txa
    sec
    sbc #.loword(ST_OAM)
    lsr a
    lsr a
    tax
    sep #$20
    .a8
    lda #1
    sta st_small,x
    rep #$20
    .a16
    lda #1
    tsb w_sizes
    lda z:w_short
    lsr a
    bcc @both
    plx
    txa
    clc
    adc #4
    sta w_st
    rts
@both:
    sep #$20
    .a8
    lda #1
    sta st_small+1,x
    rep #$20
    .a16
    plx
    lda f:$400000,x
    clc
    adc #$0800
    sta f:$400004,x
    lda f:$400002,x
    clc
    adc #16
    sta f:$400006,x
    txa
    clc
    adc #8
    sta w_st
    rts
ComputeShort:
    lda w_h
    cmp #9
    bcc @height              ; distant scenery uses only its top tile row
    ; Taller ordinary images keep 16px pieces. Arches, narrow images and
    ; start towers can omit an empty lower half; BandPass checks both limits.
    lda w_arch
    ora w_small
    bne @height
    lda w_obj
    cmp #44
    beq @height
    cmp #45
    bne @full
@height:
    lda w_b
    asl a
    asl a
    asl a
    asl a
    clc
    adc #8
    cmp w_h
    bcs @short
    clc
    adc w_y
    cmp w_vb
    bcc @full
@short:
    sec
    rts
@full:
    clc
    rts
; A short band needs only the top-left and top-right 8x8 tiles. This
; avoids charging eight empty rows against nearby cars/characters.
EmitShort:
    phx
    txa
    sec
    sbc #.loword(ST_OAM)
    lsr a
    lsr a
    tax
    lda #$0101
    sta st_small,x
    lda #1
    tsb w_sizes
    plx
    lda f:$400002,x
    bit #$4000
    beq @normal
    inc a                  ; mirrored: TR is left, TL is right
    sta f:$400002,x
    dec a
    bra @tile
@normal:
    inc a
@tile:
    and #$7FFF             ; set the right tile's ninth X bit below
    sta f:$400006,x
    lda f:$400000,x
    and #$00FF
    sta w_t
    lda f:$400002,x
    bpl :+
    lda w_t
    ora #$0100
    sta w_t
:   lda w_t
    clc
    adc #8
    and #$01FF
    sta w_t
    and #$00FF
    ora w_y8
    sta f:$400004,x
    lda w_t
    bit #$0100
    beq :+
    lda #1
    sta w_x9
    lda f:$400006,x
    ora #$8000
    sta f:$400006,x
:   txa
    clc
    adc #8
    sta w_st
    rts
; Uniform 8x8 objects clear size bits a byte at a time. Preserve the
; neighbouring objects and all ninth-X bits in the first and last bytes.
OamSmallRange:
    lda w_t
    cmp #5
    bcs @large
    dec a
    asl a
    asl a
    sta w_u
    lda w_oi
    and #3
    ora w_u
    asl a
    tax
    lda f:SmallMasks,x
    sta w_u
    lda w_oi
    lsr a
    lsr a
    tax
    lda oam_hi,x
    and w_u
    sta oam_hi,x
    rts
@large:
    lda w_oi
    and #3
    tax
    lda f:SmallLeft,x
    and #$00FF
    sta w_u
    lda w_oi
    clc
    adc w_t
    dec a
    pha
    and #3
    tax
    lda f:SmallRight,x
    and #$00FF
    sta w_u+2
    pla
    lsr a
    lsr a
    sta w_v                 ; last high-table byte
    lda w_oi
    lsr a
    lsr a
    tax
    cmp w_v
    bne @many
    sep #$20
    .a8
    lda w_u
    ora w_u+2
    and oam_hi,x
    sta oam_hi,x
    rep #$20
    .a16
    rts
@many:
    sep #$20
    .a8
    lda oam_hi,x
    and w_u
    sta oam_hi,x
@middle:
    inx
    cpx w_v
    bcs @last
    lda oam_hi,x
    and #$55
    sta oam_hi,x
    bra @middle
@last:
    lda oam_hi,x
    and w_u+2
    sta oam_hi,x
    rep #$20
    .a16
    rts
.segment "RODATA"
SmallMasks:
    .repeat 4, N
    .repeat 4, P
    .word $FFFF ^ ($AAAA & (((1 << (2*(N+1))) - 1) << (2*P)))
    .endrepeat
    .endrepeat
SmallLeft:  .byte $55, $57, $5F, $7F
SmallRight: .byte $FD, $F5, $D5, $55
.segment "SA1CODE"

OamSmall:
    pha
    lsr a
    lsr a
    tax
    pla
    and #3
    asl a
    tay
    lda HiBit,y
    asl a
    eor #$FFFF
    sep #$20
    .a8
    and oam_hi,x
    sta oam_hi,x
    rep #$20
    .a16
    rts

; OamHiX: A = OAM index: set its x bit 8 without changing the size
OamHiX:
    .ifdef SPRTRAP
    cmp #128
    bcc :+
    ldx #1
    jmp Trap
:
    .endif
    cmp #128                ; (safety net: past the table ignored)
    bcc :+
    rts
:   phx
    pha
    lsr a
    lsr a
    tax                     ; byte
    pla
    and #3
    asl a
    tay
    lda HiBit,y
    sep #$20
    .a8
    ora oam_hi,x
    sta oam_hi,x
    rep #$20
    .a16
    plx
    rts

.ifdef FLKSTAT
.include "sprflk.inc"
.segment "SA1CODE"
.endif

.export SprGridLock
SprGridLock:
    ldx #NO_SPRITES*2-2
    lda #2
:   sta grid_decor,x
    dex
    dex
    bpl :-
    ; The START halves are drawn on BG1, so they have no staged OBJ
    ; entries for the loop below. Keep their engine records available
    ; to OhbK2 after the countdown scene is revealed.
    lda #1
    sta grid_decor+46*2
    sta grid_decor+47*2
    lda sprite_count
    asl a
    tax
@entry:
    dex
    dex
    bmi @done
    lda pr_st,x
    beq @entry
    lda f:hw_ent,x
    cmp #NO_SPRITES
    bcs @entry
    tay
    lda grid_full,y
    and #$00FF
    beq @entry
    tya
    asl a
    tay
    lda #1
    sta grid_decor,y
    bra @entry
@done:
    rts

.include "grid.inc"
.include "endgeom.inc"
.include "sprclip.inc"

; [W1c] overhead structures on BG1 (render builds drawing from the records)
.ifndef HWLIST
.include "ohb.inc"
.include "arch.inc"
.else
.export OhbFrame, OhbInvalidate, OhbRoadLate
OhbRoadLate:
    lda #0
    rts
ArchGeom:
ArchFits:
    clc
    rts
ArchDraw:
ArchFinish:
OhbFrame:
OhbInvalidate:
    rts
.endif
.segment "SA1CODE"

.segment "RODATA"
.ifdef SPRCHECK
chk_list: .word w_obj, w_dsc, w_img, w_we, w_he, w_xa, w_rtl, w_mir, w_top, w_vb, w_pc, $FFFF
.endif
HiBit:  .word $01, $04, $10, $40
; by d4 bits 14-13 (read forwards, drawn left to right): mirrored ($4000:
; OBJ h-flip) when they differ; right to left when bit 13 is clear
MirTab: .word 0, $4000, $4000, 0
RtlTab: .word 1, 0, 1, 0
DropT:    .byte 4, 15, 30, 60  ; bounded retries; traffic uses the shortest wait
DmaBudget: .word 2 * DMA_VBL, 3 * DMA_VBL, 4 * DMA_VBL    ; per vblanks 2 / 3 / 4 (index * 2)
BitMask:  .byte $01, $02, $04, $08, $10, $20, $40, $80
; PopCnt: set bits of a byte
PopCnt:
    .repeat 256, V
    .byte (V & 1) + (V >> 1 & 1) + (V >> 2 & 1) + (V >> 3 & 1) + (V >> 4 & 1) + (V >> 5 & 1) + (V >> 6 & 1) + (V >> 7 & 1)
    .endrepeat
; per cell: row (av_* byte), bit in it (word tables)
CellRow2:
    .repeat NCELL, C
    .word C >> 3
    .endrepeat
CellBit2:
    .repeat NCELL, C
    .word 1 << (C & 7)
    .endrepeat
RunBits:  .byte $01, $03, $07, $0F, $1F, $3F, $7F, $FF
; [W1b] CarRank: per object entry: car group placement rank (0 the car, 1
; passengers/flag, 4 smoke (after essential art), 5 ordinary/shadows)
CarRank:
    .repeat 128, E
    .if E = SPRITE_FERRARI || E = SPRITE_CRASH
    .byte 0
    .elseif E = SPRITE_PASS1 || E = SPRITE_PASS2 || E = SPRITE_CRASH_PASS1 || E = SPRITE_CRASH_PASS2
    .byte 1
    .elseif E = SPRITE_SHADOW || E = SPRITE_CRASH_SHADOW || E = SPRITE_CRASH_PASS1_S || E = SPRITE_CRASH_PASS2_S
    .byte 5                ; shadows follow the complete characters
    .elseif E = SPRITE_SMOKE1 || E = SPRITE_SMOKE2
    .byte 4
    .elseif E >= SPRITE_CRASH && E < JUMP_ENTRIES_TOTAL
    .byte 1                ; flag man before shadows and decorations
    .else
    .byte 5
    .endif
    .endrepeat
; per VRAM cell: OBJ tile (c & 7) * 2 + (c >> 3) * 32 (bit 8: attr bit 0)
CellTile:
    .repeat NCELL, C
    .word (C & 7) * 2 + (C >> 3) * 32
    .endrepeat
.endif
