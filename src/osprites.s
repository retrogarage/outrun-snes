; OSprites: sprite handling - port of the original CannonBall engine
; (engine/osprites.cpp, classic arcade): jump table (object entries),
; level sprite spawning control, palette mapping, sprite ordering by
; priority, shadows, hill-crest clipping and conversion to the hardware
; sprite list (sprite_entries, the arcade's 7-word format).
;
; Render builds (not LOCKSTEP): the display side of do_sprite is fused with
; the SNES backend's entry decoding (sprrec.inc): instead of the arcade
; words (and hw_src), each hardware index gets a record with do_sprite's
; own values in the form sprv3.s CandGeom uses them (data[0], frame
; address, flags, zoom, x, height; the source offset only when clipped);
; hw_ent / hw_pal (object, palette source) as before.  Everything the game
; logic reads (oentry width, control DRAW_SPRITE, dst_index, the ordering,
; sprite_order2, the counts) is the same in every build.  LOCKSTEP builds
; (HWLIST) build the arcade list; SPRCHECK builds build both and compare
; (sprv3.s SprChkEnt).
;
; Speed notes (the sprite module is the hottest part of the logic; an SA-1
; BW-RAM byte costs about 3-4x an I-RAM / ROM byte in real-hardware timing):
; - do_sprite reads each oentry field once, keeps its work in an I-RAM direct
;   page block and writes every output word once.  The hot code (do_sprite,
;   do_spr_order_shadows, sprite_copy) runs with D = DPG, the page of that
;   block (dsp), and addresses it through the d_* names (= <ds_*: 1 cycle
;   less than absolute); calls out of it (math.s, traffic) restore D = 0.
; - ZOOM_LOOKUP is read from the split bank-0 tables of ozoomtab.s (index
;   zoom * 2): no size-1 special case, no mask arithmetic.  The shadow copy of
;   do_spr_order_shadows passes its substituted fields (shadow 7, pal_dst 0,
;   x, frame address) directly instead of patching and restoring the entry:
;   the entry ends up exactly as the C++ leaves it.
; - sprite_order: 16 bytes per priority as the C++ (count at +0), but the
;   jump indices from +1 (the C++ +2) and sp_bm (I-RAM) flags the priority
;   slots whose count is nonzero: do_spr_order_shadows tests the flag instead
;   of the count (a visited slot keeps a stale count, never read),
;   sprite_copy visits only the flagged slots (same order, same results) and
;   calls do_sprite while copying.
.ifdef NEWGAME
.p816
.smart
.include "sa1.inc"
.include "shared.inc"
.include "globals.inc"
.include "ogame.inc"
.include "road.inc"
.include "gametab.inc"
.include "sprrec.inc"

.import RD_Y
.importzp RDB
.import FerInit, CrashInit, AnimSeqInit, LevelObjSetupSprites
.import TrafficLogic, TrafficSound, trk_scenery, trk_scenery_off
.importzp mres, dvd, dvs
.import UMul16, UDiv32_16
.import ZVz, ZOff, ZWh
.ifdef SPRCHECK
.import SprChkEnt
.export sprchk_rec
.endif
.ifdef SPRCHECK
REC_BASE = sprchk_rec                   ; (one record, compared as it is built)
.else
REC_BASE = sprite_entries
.endif

.export OSpritesInit, OSpritesTick, DisableSprites, ClearPaletteData  ; (JT: .global in ogame.inc)
.export CopyPaletteData, MapPalette, DoSprOrderShadows, SpriteCopy, DoSprite
.export MoveSprite, UpdateSprites
.export hw_ent, sprite_entries, hw_src, hw_pal, sprite_count, spr_cnt_main, spr_cnt_shadow, sprite_order, sprite_order2
.export sprite_scroll_speed, shadow_offset, do_sprite_swap, pal_addresses, pal_copy_count
.export seg_pos, seg_total_sprites, seg_sprite_freq, seg_spr_offset1, seg_spr_offset2, seg_spr_addr

SHADOW_FRAMES      = $7862      ; outrun.adr.shadow_frames
SCENERYMAP_TABLE   = $1A43C     ; SPRITE_MASTER_TABLE
PAL_LOOKUP_LENGTH  = 256
HW_SIZE            = 16         ; sprite_entries record: data[0..6] + pad
SP_GROUPS          = 32         ; sprite_order: 32 groups of 16 priority slots

; long bases: WH_TABLE (width / height lookup) and SPRITE_ZOOM_LOOKUP banks
; of the embedded rom0, and road_y[road_p0 + 0x280] (X = road_p0)
WHB = R0BANK * $10000 + (WH_TABLE & $FFFF0000)
ZLB = R0BANK * $10000 + (SPRITE_ZOOM_LOOKUP & $FFFF0000)
RDY = RDB * $10000 + RD_Y + $0280 * 2

.segment "BWBSS": far
JT:             .res JUMP_ENTRIES_TOTAL * OE_SIZE
sprite_entries: .res (JUMP_ENTRIES_TOTAL + 1) * HW_SIZE
hw_src:         .res (JUMP_ENTRIES_TOTAL + 1) * 4
hw_pal:         .res (JUMP_ENTRIES_TOTAL + 1) * 2
hw_ent:         .res (JUMP_ENTRIES_TOTAL + 1) * 2   ; SNES backend: entry index (| $80 shadow copy)
sprite_order:   .res $2000
sprite_order2:  .res 128
pal_lookup:     .res PAL_LOOKUP_LENGTH
pal_addresses:  .res $100 * 2
.ifdef SPRCHECK
sprchk_rec:     .res 16                 ; (the record of the entry being checked)
.endif

.segment "BSS"              ; (once per tick)
seg_pos:            .res 2
seg_total_sprites:  .res 2
seg_sprite_freq:    .res 2
seg_spr_offset2:    .res 2
seg_spr_offset1:    .res 2
seg_spr_addr:       .res 4
do_sprite_swap:     .res 2

.segment "IRAMBSS"          ; (hot: SA-1 I-RAM is 3-4x as fast as BW-RAM)
; ---- direct page block: the hot code runs with D = DPG and addresses these
; as "<name" (keep it within one page: checked at link time) ----
dsp:
spr_cnt_main:       .res 2
spr_cnt_shadow:     .res 2
shadow_offset:      .res 2
; do_sprite: inputs
ds_in:       .res 2          ; input entry offset
ds_out:      .res 2          ; output entry offset (dst_index * 16)
ds_ent:      .res 2          ; hw_ent value: entry index (| $80 shadow copy)
ds_sz:       .res 2          ; shadow | zoom << 8
ds_dp:       .res 2          ; draw_props | pal_dst << 8
ds_h:        .res 2          ; height (must follow ds_dp: d_dp+1 = data[5] word)
ds_xs:       .res 2          ; x
ds_addr:     .res 4          ; frame address (rom0)
; do_sprite: work
ds_src:      .res 4          ; src_offsets as a SNES long pointer ([d_src],y)
ds_srchi:    .res 2          ; src_offsets bits 16-31
ds_vz:       .res 2          ; hardware zoom (ZOOM_LOOKUP)
ds_w:        .res 2
ds_y1:       .res 2
ds_y2:       .res 2
ds_x1:       .res 2          ; output x (data[6])
ds_d0:       .res 2          ; output data[0]
ds_off:      .res 2          ; output data[1]
ds_pals:     .res 2          ; pal_src
ds_road:     .res 2          ; road_y at road_p0 + 0x280: 0 flat, 1 elevated, $FFFF not known
ds_t:        .res 2
; sprite_copy
ds_k:        .res 2          ; sprite_order2 index
ds_gb:       .res 2          ; sprite_order offset of the sp_bm word's first slot
ds_p:        .res 2          ; sprite_order offset of the entry being copied
ds_bytes:    .res 2          ; entries of the slot left (low byte)
ds_mask:     .res 2          ; sp_bm flags of the word not visited yet
ds_wx:       .res 2          ; its index * 2
ds_o2p:      .res 4          ; sprite_order2 pointer
ds_sfa:      .res 4          ; rom0.read32(shadow_frames + 0x3C) (lo, hi)
; render builds: the sprite entry record (DsRec)
ds_fl:       .res 2          ; RR_FL
.ifdef SPRCHECK
ds_chkv:     .res 2          ; 1: visible (the record is built), 0: hidden
.endif
dspe:
DPG = dsp & $FF00
.assert (dspe - 1) & $FF00 = DPG, lderror, "osprites: the direct page block crosses a page"
; direct page names (D = DPG)
d_main = <spr_cnt_main
d_shad = <spr_cnt_shadow
d_shoff = <shadow_offset
d_in = <ds_in
d_out = <ds_out
d_ent = <ds_ent
d_sz = <ds_sz
d_dp = <ds_dp
d_h = <ds_h
d_xs = <ds_xs
d_addr = <ds_addr
d_src = <ds_src
d_srchi = <ds_srchi
d_vz = <ds_vz
d_w = <ds_w
d_y1 = <ds_y1
d_y2 = <ds_y2
d_x1 = <ds_x1
d_d0 = <ds_d0
d_off = <ds_off
d_pals = <ds_pals
d_rp = <ds_t                    ; (DsElev: dead when d_t is set)
d_road = <ds_road
d_t = <ds_t
d_cj = <ds_x1                   ; (do_spr_order_shadows, before do_sprite)
d_k = <ds_k
d_gb = <ds_gb
d_p = <ds_p
d_bytes = <ds_bytes
d_mask = <ds_mask
d_wx = <ds_wx
d_o2p = <ds_o2p
d_sfa = <ds_sfa
d_fl = <ds_fl
.ifdef SPRCHECK
d_chkv = <ds_chkv
.endif

sp_bm:      .res SP_GROUPS * 2  ; bit k of word g: priority slot g * 16 + k has entries
sprite_scroll_speed: .res 2
sprite_count:       .res 2
spr_col_pal:        .res 2
pal_copy_count:     .res 2
; init / palettes / move_sprite
os_e:       .res 2          ; entry
os_i:       .res 2
os_t:       .res 4

.segment "SA1CODE"
.a16
.i16

;----------------------------------------------------------------------------
; EntryInit: X = entry offset, A = index (oentry.init)
;----------------------------------------------------------------------------
EntryInit:
    phx
    sta os_t
    txa
    clc
    adc #OE_SIZE
    sta os_t+2
    lda #0
:   sta f:JT,x
    inx
    inx
    cpx os_t+2
    bne :-
    plx
    sep #$20
    .a8
    lda os_t
    sta f:JT+OE_JUMP_INDEX,x
    lda #$FF
    sta f:JT+OE_FUNC,x
    lda #3
    sta f:JT+OE_SHADOW,x
    rep #$20
    .a16
    rts

; RomLong: A = rom0 address lo, Y = hi (bits 16-17) -> ptr2 (24-bit)
; (SNES address of an arcade rom0 byte)
RomPtr:
    sta ptr2
    tya
    clc
    adc #R0BANK
    sep #$20
    .a8
    sta ptr2+2
    rep #$20
    .a16
    rts

;============================================================================
; init
;============================================================================
OSpritesInit:
    ; palette lookup, ordering tables, hardware entries
    ldx #0
    lda #0
:   sta f:pal_lookup,x
    inx
    inx
    cpx #PAL_LOOKUP_LENGTH
    bne :-
    ldx #0
:   sta f:sprite_order,x
    inx
    inx
    cpx #$2000
    bne :-
    ldx #0
:   sta sp_bm,x
    inx
    inx
    cpx #SP_GROUPS * 2
    bne :-
    ldx #0
:   sta f:sprite_order2,x
    inx
    inx
    cpx #128
    bne :-
    ldx #0
:   sta f:sprite_entries,x
    inx
    inx
    cpx #(JUMP_ENTRIES_TOTAL + 1) * HW_SIZE
    bne :-
    ; level object entries
    stz os_i
:   lda os_i
    xba
    lsr a
    lsr a                   ; *64
    tax
    lda os_i
    jsr EntryInit
    inc os_i
    lda os_i
    cmp #SPRITE_ENTRIES
    bne :-
    ; Ferrari, passengers, shadow, smoke
    lda #SPRITE_FERRARI
    jsr InitIdx
    lda #SPRITE_PASS1
    jsr InitIdx
    lda #SPRITE_PASS2
    jsr InitIdx
    lda #SPRITE_SHADOW
    jsr InitIdx
    lda #7
    sta f:JT+OE_SHADOW+EOFS(SPRITE_SHADOW)   ; (shadow is a byte: the next byte is zoom = 0)
    lda #SPRITE_SMOKE1
    jsr InitIdx
    lda #SPRITE_SMOKE2
    jsr InitIdx
    jsr FerInit
    ; traffic in the right hand lane at the start of stage 1
    lda #SPRITE_TRAFF1
    sta os_i
@traf:
    lda os_i
    jsr InitIdx             ; X = entry
    LDEB OE_CONTROL
    ora #C_SHADOW
    STEB OE_CONTROL
    lda #.loword(SPRITE_PORSCHE)
    STE OE_ADDR
    lda #^SPRITE_PORSCHE
    STE OE_ADDR+2
    inc os_i
    lda os_i
    cmp #SPRITE_TRAFF8+1
    bne @traf
    ; crash sprites
    lda #SPRITE_CRASH
    sta os_i
:   lda os_i
    jsr InitIdx
    inc os_i
    lda os_i
    cmp #SPRITE_CRASH_PASS2_S+1
    bne :-
    sep #$20
    .a8
    lda #DP_BOTTOM
    sta f:JT+OE_DRAW_PROPS+EOFS(SPRITE_CRASH_PASS1)
    sta f:JT+OE_DRAW_PROPS+EOFS(SPRITE_CRASH_PASS2)
    sta f:JT+OE_DRAW_PROPS+EOFS(SPRITE_CRASH_PASS2_S)
    sta f:JT+OE_DRAW_PROPS+EOFS(SPRITE_CRASH_SHADOW)
    lda #7
    sta f:JT+OE_SHADOW+EOFS(SPRITE_CRASH_PASS1_S)
    sta f:JT+OE_SHADOW+EOFS(SPRITE_CRASH_PASS2_S)
    sta f:JT+OE_SHADOW+EOFS(SPRITE_CRASH_SHADOW)
    lda #$80
    sta f:JT+OE_ZOOM+EOFS(SPRITE_CRASH_SHADOW)
    rep #$20
    .a16
    lda #.loword(SPRITE_SHADOW_DATA)
    sta f:JT+OE_ADDR+EOFS(SPRITE_CRASH_PASS1_S)
    sta f:JT+OE_ADDR+EOFS(SPRITE_CRASH_PASS2_S)
    sta f:JT+OE_ADDR+EOFS(SPRITE_CRASH_SHADOW)
    lda #^SPRITE_SHADOW_DATA
    sta f:JT+OE_ADDR+2+EOFS(SPRITE_CRASH_PASS1_S)
    sta f:JT+OE_ADDR+2+EOFS(SPRITE_CRASH_PASS2_S)
    sta f:JT+OE_ADDR+2+EOFS(SPRITE_CRASH_SHADOW)
    jsr CrashInit
    ; animation sequence sprites
    lda #SPRITE_FLAG
    jsr InitIdx
    jsr AnimSeqInit
    stz seg_pos
    stz seg_total_sprites
    stz seg_sprite_freq
    stz seg_spr_offset2
    stz seg_spr_offset1
    stz seg_spr_addr
    stz seg_spr_addr+2
    stz do_sprite_swap
    stz sprite_scroll_speed
    stz shadow_offset
    stz sprite_count
    stz spr_cnt_main
    stz spr_cnt_shadow
    stz spr_col_pal
    stz pal_copy_count
    lda #$FFFF
    sta ds_road
    R0W SHADOW_FRAMES + $3E     ; (shadow frame for do_spr_order_shadows)
    sta ds_sfa
    R0W SHADOW_FRAMES + $3C
    sta ds_sfa+2
    rts

; InitIdx: A = entry index -> entry initialised, X = its offset
InitIdx:
    pha
    xba
    lsr a
    lsr a
    tax
    pla
    phx
    jsr EntryInit
    plx
    rts

;----------------------------------------------------------------------------
; UpdateSprites (vint): swap sprite RAM, copy mapped palettes
;----------------------------------------------------------------------------
UpdateSprites:
    lda do_sprite_swap
    bne :+
    rts
:   stz do_sprite_swap
    jmp CopyPaletteData

; disable_sprites: level objects off
DisableSprites:
    ldx #0
:   LDEB OE_CONTROL
    and #$FF7F
    STEB OE_CONTROL
    txa
    clc
    adc #OE_SIZE
    tax
    cpx #EOFS(SPRITE_ENTRIES)
    bne :-
    rts

;============================================================================
; tick: sprite_control (level sprite spawning)
;============================================================================
OSpritesTick:
    ; populate the next road segment
    jsr SceneryPos
    sta os_t
    cmp road_pos+2
    beq @load
    bcs @run                ; pos > road_pos >> 16 (unsigned)
@load:
    lda os_t
    sta seg_pos
    ldy #2
    lda [ptr2],y            ; total sprites (byte +2), pattern index (+3)
    pha
    and #$00FF
    sta seg_total_sprites
    pla
    xba
    and #$00FF              ; pattern index
    pha
    lda trk_scenery_off
    clc
    adc #4
    sta trk_scenery_off
    ; a0 = scenerymap table[pattern]
    pla
    asl a
    asl a
    clc
    adc #.loword(SCENERYMAP_TABLE)
    ldy #^SCENERYMAP_TABLE
    jsr RomPtr
    lda [ptr2]              ; hi word (big endian)
    xba
    sta os_t+2
    ldy #2
    lda [ptr2],y
    xba                     ; lo word
    ; a0 (32-bit): os_t+2 : A
    sta os_t
    ldy os_t+2
    jsr RomPtr
    lda [ptr2]
    xba
    sta seg_sprite_freq
    ldy #2
    lda [ptr2],y
    xba
    sta seg_spr_offset2
    lda os_t                ; seg_spr_addr = a0 + 4 (rom0 address)
    clc
    adc #4
    sta seg_spr_addr
    lda os_t+2
    adc #0
    sta seg_spr_addr+2
    stz seg_spr_offset1
@run:
    lda seg_total_sprites
    bne :+
    rts
:   lda seg_pos
    cmp road_pos+2
    beq :+
    bcc :+
    rts                     ; seg_pos > road_pos >> 16
:   ; sprite 1
    asl seg_sprite_freq     ; rotate left (carry = old bit 15)
    bcc :+
    inc seg_sprite_freq
    jsr NextSprite
    lda #$0400
    ldx #$0001              ; olevelobjs.setup_sprites(0x10400)
    jsr LevelObjSetupSprites
:   lda seg_total_sprites
    bne :+
    inc seg_pos
    rts
:   ; sprite 2: slightly set back
    asl seg_sprite_freq
    bcc :+
    inc seg_sprite_freq
    jsr NextSprite
    lda #$0000
    ldx #$0001              ; setup_sprites(0x10000)
    jsr LevelObjSetupSprites
:   inc seg_pos
    rts

NextSprite:
    dec seg_total_sprites
    lda seg_spr_offset1
    sec
    sbc #8
    bpl :+
    lda seg_spr_offset2
:   sta seg_spr_offset1
    rts

; SceneryPos: A = trackloader.read_scenery_pos(), ptr2 -> the scenery entry
SceneryPos:
    lda trk_scenery
    clc
    adc trk_scenery_off
    pha
    lda trk_scenery+2
    adc #0
    tay
    pla
    jsr RomPtr
    lda [ptr2]
    xba
    rts

;============================================================================
; palettes
;============================================================================
ClearPaletteData:
    stz spr_col_pal
    ldx #0
    lda #0
:   sta f:pal_lookup,x
    inx
    inx
    cpx #PAL_LOOKUP_LENGTH
    bne :-
    rts

; copy_palette_data: sprite palettes mapped this tick -> palette RAM mirror
; (the SNES backend reads the colours through hw_pal: nothing to do here
; but the bookkeeping)
CopyPaletteData:
    stz pal_copy_count
    rts

; map_palette: X = entry
MapPalette:
    LDE OE_PAL_SRC
    and #$00FF
    sta os_t
    phx
    tax
    lda f:pal_lookup,x
    plx
    and #$00FF
    beq :+
    STEB OE_PAL_DST         ; cached
    rts
:   lda spr_col_pal         ; (uint8) ++spr_col_pal > $7F: no palette
    inc a
    and #$00FF
    sta spr_col_pal
    cmp #$80
    bcc :+
    rts
:   STEB OE_PAL_DST
    phx
    ldx os_t
    sep #$20
    .a8
    sta f:pal_lookup,x
    rep #$20
    .a16
    lda pal_copy_count
    asl a
    asl a
    tax
    lda os_t
    sta f:pal_addresses,x
    lda spr_col_pal
    sta f:pal_addresses+2,x
    inc pal_copy_count
    plx
    rts

;============================================================================
; do_spr_order_shadows: X = entry (returned unchanged)
; sprite_order[priority << 4]: count, then the jump indices from +1 (the C++
; has them from +2); the slots whose count is nonzero are the set bits of
; sp_bm (bit p & 15 of word p >> 4), so a count is only read when its bit is
; set (a visited slot keeps a stale count byte that is never read).
;============================================================================
DoSprOrderShadows:
    .ifndef HWLIST
    ; The composite arch owns all visible parts. Its other engine entries
    ; keep movement/collisions but need no duplicate render-list records.
    phx
    txa
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    tax
    lda arch_group,x
    beq @ordered
    lda arch_root,x
    bne @ordered
    plx
    rts
@ordered:
    plx
    .endif
    lda #DPG
    tcd
    lda d_main
    clc
    adc d_shad
    cmp #JUMP_ENTRIES_TOTAL
    bcc :+
    jmp DsoEnd
:   stx d_in
    lda f:JT+OE_CONTROL,x       ; control | jump_index << 8
    sta d_cj
    lda f:JT+OE_PRIORITY,x
    and #$01FF
    asl a
    tay                         ; Y = priority * 2
    ldx PWord,y                 ; X = sp_bm word of the slot
    lda PMask,y
    ora sp_bm,x
    cmp sp_bm,x
    beq @used                   ; (flag already set)
    sta sp_bm,x                 ; empty slot: flag it
    tya
    asl a
    asl a
    asl a
    tax                         ; priority << 4: sprite_order slot
    lda d_cj
    and #$FF00
    inc a                       ; bytes_to_copy = 1, jump_index at +1
    sta f:sprite_order,x
    inc d_main
    bra @shadow
@used:
    tya
    asl a
    asl a
    asl a
    tax
    sep #$20
    .a8
    lda f:sprite_order,x        ; bytes_to_copy
    cmp #$0E
    bcs @full                   ; (at most 14 entries)
    inc a                       ; (C clear)
    sta f:sprite_order,x
    rep #$20
    .a16
    and #$00FF
    stx d_t
    adc d_t
    tax
    sep #$20
    .a8
    lda d_cj+1                  ; sprite_order[priority + bytes] = jump_index
    sta f:sprite_order,x
    rep #$20
    .a16
    inc d_main
    bra @shadow
@full:
    .a8
    rep #$20
    .a16
@shadow:
    ldx d_in
    .ifndef HWLIST
    ; Roadside shadows were omitted by the renderer anyway. Avoid building
    ; their geometry and sorting/culling empty records every tick.
    cpx #EOFS(SPRITE_ENTRIES)
    bcc DsoEnd
    .endif
    lda d_cj
    and #C_SHADOW
    beq DsoEnd
    lda d_main
    clc
    adc d_shad
    cmp #JUMP_ENTRIES_TOTAL
    bcs DsoEnd
    lda d_cj
    and #C_TRAFFIC_SPRITE
    bne @traffic
    ; x += (road_priority * shadow_offset) >> 9 (signed multiply)
    lda f:JT+OE_ROAD_PRIORITY,x
    sta MAL
    lda d_shoff
    sta MBL
    lda d_sfa                   ; addr = rom0.read32(shadow_frames + 0x3C)
    sta d_addr
    lda d_sfa+2
    sta d_addr+2
    lda MR+3
    lsr a                       ; C = bit 24
    lda MR+1
    ror a                       ; bits 9-24
    clc
    adc f:JT+OE_X,x
    sta d_xs
    bra @go
@traffic:
    lda f:JT+OE_X,x             ; (x restored: unchanged)
    sta d_xs
    lda #.loword(SPRITE_SHDW_SMALL)
    sta d_addr
    lda #^SPRITE_SHDW_SMALL
    sta d_addr+2
@go:
    lda d_shad         ; input->dst_index = spr_cnt_shadow++
    inc d_shad
    jsr DsShadow
DsoEnd:
    lda #0
    tcd
    rts

;============================================================================
; sprite_copy: ordered sprites -> hardware entries (after the shadows)
;============================================================================
SpriteCopy:
    lda spr_cnt_main
    bne :+
    jmp FinaliseSprites
:   clc
    adc spr_cnt_shadow
    cmp #$80
    bcc :+
    stz spr_cnt_main
    stz spr_cnt_shadow
    jmp FinaliseSprites
:   lda #DPG
    tcd
    ldx a:road_p0               ; the road does not change during sprite_copy:
    lda f:RDY,x                 ; is the elevation priority list empty?
    ora f:RDY+2,x
    beq :+
    lda #1
:   sta d_road
    lda #.loword(sprite_order2)
    sta d_o2p
    lda #^sprite_order2
    sta d_o2p+2
    stz d_k                     ; sprite_order2 index
    ldx #0                      ; X = sp_bm word * 2
@w: lda sp_bm,x
    bne @word
@wn:
    inx
    inx
    cpx #SP_GROUPS * 2
    bcc @w
    jmp @end
@word:                          ; A = the word's slot flags
    stx d_wx
    sta d_mask
    stz sp_bm,x                 ; (visited slots are emptied)
    txa
    xba
    lsr a
    sta d_gb                    ; sprite_order offset of the word's first slot
@bit:                           ; lowest flag of d_mask (nonzero): its slot
    lda d_mask
    and #$00FF
    beq @hi
    asl a
    tay
    lda LsbOfs,y
    bra @have
@hi:
    lda d_mask
    xba
    and #$00FF
    asl a
    tay
    lda LsbOfs,y
    ora #$0080
@have:
    ora d_gb
    tax                         ; X = slot
    lda d_mask
    dec a
    and d_mask
    sta d_mask                  ; (flag cleared)
    lda f:sprite_order,x        ; bytes_to_copy | first jump index << 8
    bit #$00FE
    bne @multi                  ; (more than one entry)
    xba
    ldy d_k
    sep #$20
    .a8
    sta [d_o2p],y               ; sprite_order2[dst_index++] = jump index
    rep #$20
    .a16
    and #$00FF
    sta d_ent                   ; (SNES backend: hw_ent[dst] = entry index)
    xba
    lsr a
    lsr a
    tax                         ; entry (C clear)
    tya
    adc d_shad                  ; entry->dst_index = cnt_shadow_copy++
    iny
    sty d_k
    jsr DsMainSet               ; do_sprite(entry)
    ldy d_k
    cpy d_main
    beq @last
@slotend:
    lda d_mask
    bne @bit
    ldx d_wx
    jmp @wn
@multi:
    sep #$20
    .a8
    sta d_bytes                 ; bytes_to_copy
    ldy d_k
@ent:
    inx
    lda f:sprite_order,x        ; jump index
    sta [d_o2p],y               ; sprite_order2[dst_index++]
    stx d_p
    rep #$20
    .a16
    and #$00FF
    sta d_ent
    xba
    lsr a
    lsr a
    tax                         ; entry (C clear)
    tya
    adc d_shad                  ; entry->dst_index = cnt_shadow_copy++
    iny
    sty d_k
    jsr DsMainSet               ; do_sprite(entry)
    ldy d_k
    cpy d_main
    beq @last
    ldx d_p
    sep #$20
    .a8
    dec d_bytes
    bne @ent
    rep #$20
    .a16
    bra @slotend
@last:                          ; all main sprites copied: the slots after
    lda d_mask                  ; this one keep their entries
    ldx d_wx
    sta sp_bm,x
@end:
    lda #0
    tcd
    ; (falls into FinaliseSprites)

; finalise_sprites: end marker, traffic logic / sound, ready to swap
FinaliseSprites:
    lda #$FFFF
    sta ds_road                 ; (do_sprite outside sprite_copy: not known)
    lda spr_cnt_main
    clc
    adc spr_cnt_shadow
    sta sprite_count
    asl a
    asl a
    asl a
    asl a
    tax
    lda #$FFFF
    sta f:sprite_entries,x
    sta f:sprite_entries+2,x
    jsr TrafficLogic
    jsr TrafficSound
    stz spr_cnt_main
    stz spr_cnt_shadow
    lda #1
    sta do_sprite_swap
    rts

.segment "RODATA"
; priority p (index p * 2): sp_bm word offset (p >> 4) * 2 and bit 1 << (p & 15)
PWord:
    .repeat 512, I
    .word (I >> 4) * 2
    .endrepeat
PMask:
    .repeat 512, I
    .word 1 << (I & 15)
    .endrepeat
; LsbOfs[b] (index b * 2): sprite_order offset (k * 16) of the lowest set bit k of b
LsbOfs:
    .word 0
    .repeat 255, I
    .word ((I + 1) & -(I + 1) & $F0 <> 0) * 64 + ((I + 1) & -(I + 1) & $CC <> 0) * 32 + ((I + 1) & -(I + 1) & $AA <> 0) * 16
    .endrepeat
RendLtr:    .word $E000, $A000  ; set_render(props | $80): props $60, $20
RendRtl:    .word $8000, $C000  ; props 0, $40
.segment "SA1CODE"

;============================================================================
; do_sprite: input entry -> hardware entry [dst_index]
; Entry points (D = DPG): DsMainSet (X = entry, A = dst_index, stored in the
; entry), DsMain (the same, not stored) and DsShadow (the shadow copy of
; do_spr_order_shadows: X = entry, A = dst_index, d_xs / d_addr = the x and
; frame to use, shadow 7, pal_dst 0).  DoSprite: X = entry, its dst_index
; (D = 0, external).  Return with X = entry.
; hw_ent (SNES backend: entry index | $80 shadow copy) is written on every
; path, hw_src / hw_pal where the C++ sets the palette.
;============================================================================
DsShadow:                       ; (d_in = X set by do_spr_order_shadows)
    sta f:JT+OE_DST_INDEX,x
    asl a
    asl a
    asl a
    asl a
    sta d_out                   ; dst * 16
    txa
    asl a
    asl a
    xba                         ; entry index
    ora #$0080                  ; (shadow copy)
    sta d_ent
    .ifndef HWLIST
    ; Keep this guard for explicit calls as well as the early ordering
    ; cull. Vehicle/flag shadows and reference hardware lists are retained.
    cpx #EOFS(SPRITE_ENTRIES)
    bcs :+
    jmp DsHide0
:
    .endif
    lda f:JT+OE_DRAW_PROPS,x
    and #$00FF                  ; pal_dst = 0
    sta d_dp
    lda f:JT+OE_SHADOW,x
    and #$FF00
    ora #$0007                  ; shadow = 7
    sta d_sz
    xba                         ; (N: zoom top bit)
    bmi @top
    and #$00FF
    bne :+
    jmp DsHide0                 ; zoom 0
:   asl a
    tay                         ; Y = zoom * 2
    lda ZOff,y                  ; src_offsets = addr + size offset
    clc
    adc d_addr
    sta d_src
    lda d_addr+2
    adc #0
    jmp DsCore
@top:
    and #$00FF
    asl a
    tay
    lda ZOff,y
    clc
    adc d_addr
    sta d_src
    lda d_addr+2
    adc #0
    jmp DsTop

DsMainTop:                      ; (DsMain, zoom top bit set)
    and #$00FF
    asl a
    tay
    lda ZOff,y
    clc
    adc f:JT+OE_ADDR,x
    sta d_src
    lda f:JT+OE_ADDR+2,x
    adc #0
    jmp DsTop

DoSprite:
    lda #DPG
    tcd
    txa
    asl a
    asl a
    xba                         ; SNES backend: hw_ent[dst] = entry index
    sta d_ent
    lda f:JT+OE_DST_INDEX,x
    jsr DsMain
    lda #0
    tcd
    rts

; DsMainSet / DsMain: d_ent = entry index (set by the caller)
DsMainSet:
    sta f:JT+OE_DST_INDEX,x
DsMain:
    stx d_in
    asl a
    asl a
    asl a
    asl a
    sta d_out                   ; dst * 16
    lda f:JT+OE_DRAW_PROPS,x    ; draw_props | pal_dst << 8
    sta d_dp
    lda f:JT+OE_X,x
    sta d_xs
    lda f:JT+OE_SHADOW,x        ; shadow | zoom << 8
    sta d_sz
    xba                         ; (N: zoom top bit)
    bmi DsMainTop
    and #$00FF
    bne :+
    jmp DsHide0                 ; zoom 0
:   asl a
    tay                         ; Y = zoom * 2
    lda ZOff,y                  ; src_offsets = addr + size offset
    clc
    adc f:JT+OE_ADDR,x
    sta d_src
    lda f:JT+OE_ADDR+2,x
    adc #0
    ; (falls into DsCore)

; DsCore: A = src_offsets bits 16-31 (d_src = bits 0-15), Y = zoom * 2 (zoom
; 1-$7F): hw zoom, width, height
DsCore:
    sta d_srchi
    adc #R0BANK                 ; (C clear)
    sta d_src+2
    lda ZVz,y
    sta d_vz                    ; set_vzoom / set_hzoom value
    lda ZWh,y                   ; d0 = lookup_mask + $4000 or zoom << 8
    sep #$20                    ; (B = d0 >> 8: TAX takes B:A)
    .a8
    ldy #3
    lda [d_src],y               ; d0 = (d0 & $FF00) + src[3]
    tax
    lda f:WHB,x
    sta d_h                     ; height = WH[d0]
    stz d_h+1
    ldy #1
    lda [d_src],y               ; d0 = (d0 & $FF00) + src[1]
    tax
    lda f:WHB,x                 ; width = WH[d0]
    rep #$20
    .a16
    and #$00FF
    sta d_w
DsWH:                           ; A = width
    ldx d_in
    sta f:JT+OE_WIDTH,x         ; input->width
    .ifndef HWLIST
    ; The complete arch remains visible after its reference pillar leaves
    ; the viewport. Do not clip that logical object by one pillar's bounds.
    .import render_skip, game_state
    lda a:render_skip
    beq :+
    lda a:game_state
    cmp #GS_INGAME
    bne :+
    ; Width, world positions and depth order still update for collisions
    ; and traffic logic. A guaranteed later tick replaces this render list.
    ldx d_out
    jmp DsHwEnt
:
    .import arch_root, arch_group, grid_decor, grid_people
    lda d_ent
    bit #$0080
    bne :+
    asl a
    tax
    lda arch_root,x
    beq @part
    jmp DsArch
@part:
    lda arch_group,x
    bne @skip
    lda grid_decor,x
    cmp #2
    beq @skip
    lda grid_people,x
    cmp #2
    bne :+
@skip:
    ldx d_out
    lda #$4000
    sta f:sprite_entries+RR_D0,x
    jmp DsHwEnt
:   ldx d_in
    .endif
    ; ---- set_sprite_xy: set_y(y + 256) ----
    lda d_dp
    tay                         ; (Y = draw_props)
    and #$000C
    cmp #$0008
    bne @ynb
    lda f:JT+OE_Y,x             ; bottom: y1 = y - height (+256), y2 = y (+256)
    clc
    adc #256
    sta d_y2
    cmp #256
    bmi @hidey2                 ; y2 < 256
    sec
    sbc d_h
    sta d_y1
    cmp #480
    bpl @hidey                  ; y1 > 479
@x: ; ---- set_x(x + 352) ----
    tya
    and #$0003
    bne @xnc
@xc:
    lda d_w                    ; centre: x -= width >> 1
    lsr a
    eor #$FFFF
    sec
    adc d_xs
@xset:
    clc
    adc #352
    sta d_x1
    cmp #513
    bpl @hide                   ; x1 > 512
    clc
    adc d_w
    cmp #192
    bpl DsVis                   ; x2 >= 192: visible
@hide:
    jmp DsHide1
@xnc:
    cmp #$0003
    beq @xc
    cmp #$0002
    bne @xleft
    lda d_xs                   ; right: x -= width
    sec
    sbc d_w
    bra @xset
@xleft:
    lda d_xs
    bra @xset
@hidey2:
    sec
    sbc d_h
    sta d_y1
@hidey:
    .ifdef HWLIST
    jsr DsX                     ; (x is set before hiding)
    .endif
    jmp DsHide1
@ynb:
    cmp #$0004
    beq @ytop
    lda d_h                    ; centre: y -= height >> 1
    lsr a
    eor #$FFFF
    sec
    adc f:JT+OE_Y,x
    bra @yadd
@ytop:
    lda f:JT+OE_Y,x
@yadd:
    clc
    adc #256
    sta d_y1
    clc
    adc d_h
    sta d_y2
    cmp #256
    bmi @hidey                  ; y2 < 256
    lda d_y1
    cmp #480
    bmi @x
    bra @hidey

 .ifndef HWLIST
DsArch:
    jsr DsX
    ldx d_in
    lda f:JT+OE_Y,x
    clc
    adc #256
    sta d_y2
    sec
    sbc d_h
    sta d_y1
    and #$01FF
    sta d_d0
    lda f:JT+OE_PAL_SRC,x
    sta d_pals
    ldy #6
    lda [d_src],y
    and #$7F00
    asl a
    ora d_d0
    sta d_d0
    jmp DsHR
 .endif

; visible: X = entry
DsVis:
    lda f:JT+OE_PAL_SRC,x
    sta d_pals                 ; (SNES backend: hw_pal)
    ldy #6
    lda [d_src],y              ; src[6] | src[7] << 8
    and #$7F00
    asl a                       ; set_bank((uint8) (src[7] << 1))
    ora d_y1
    sta d_d0
    .ifdef HWLIST
    ldy #8
    lda [d_src],y
    xba
    sta d_off                  ; set_offset(read16(src + 8))
    .endif
    ; ---- set_height (d_h from here: the output height, low byte) ----
    lda d_y1
    cmp #256
    bpl :+
    .ifndef HWLIST
    ldy #8                      ; (render builds: the offset only when clipped)
    lda [d_src],y
    xba
    sta d_off
    .endif
    jsr DsYAdj                  ; top clipped: height = y2
:
    ; ---- clipping by the road elevation (road_y[road_p0 + 0x280]) ----
    lda d_road
    beq @flat                   ; (known flat)
    bpl @elev                   ; (known elevated)
    ldx a:road_p0
    lda f:RDY,x
    ora f:RDY+2,x
    beq @flat
@elev:
    ldx a:road_p0
    jsr DsElev
    bcc DsHR
    jmp DsHide2                 ; behind the hill
@flat:
    lda d_y2
    cmp #$01E0
    bmi DsHR
    eor #$FFFF                  ; sub_height(y2 - 0x1DF)
    sec
    adc #$01DF
    clc
    adc d_h
    sta d_h
; ---- set_hrender, pitch, priority; output entry ----
DsHR:
    ldx d_in
    sep #$20
    .a8
    lda f:JT+OE_CONTROL,x
    ora #C_DRAW_SPRITE          ; input->control |= DRAW_SPRITE
    sta f:JT+OE_CONTROL,x
    rep #$20
    .a16
    .ifndef HWLIST
    jmp DsRec                   ; (render builds: the sprv3 record)
    .else
    .ifdef SPRCHECK
    ldy #1
    sty d_chkv
    .endif
    and #C_HFLIP
    asl a
    tay                         ; Y = H-flip * 2
    ldx d_out
    lda d_dp
    lsr a
    bcs @ltr                    ; anchor left: props $60
    lsr a
    bcs @rtl                    ; anchor right: props 0
    lda d_xs
    bpl @ltr                    ; x < 0: props 0
@rtl:
    lda d_x1                   ; right to left: inc_x(width)
    clc
    adc d_w
    sta f:sprite_entries+12,x
    lda RendRtl,y               ; props 0 / $40 (flip) | $80
    ora d_vz
    sta f:sprite_entries+8,x
    tya
    bne @noinc                  ; backwards (props $40)
@inc:
    ldy #4                      ; inc_offset(read16(src + 4) - 1)
    lda [d_src],y
    xba
    dec a
    clc
    adc d_off
    bra @off
@ltr:
    lda d_x1
    sta f:sprite_entries+12,x
    lda RendLtr,y               ; props $60 / $20 (flip) | $80
    ora d_vz
    sta f:sprite_entries+8,x
    tya
    bne @inc                    ; forwards (props $20)
@noinc:
    lda d_off
@off:
    sta f:sprite_entries+2,x
    lda d_d0
    sta f:sprite_entries,x
    ldy #4
    lda [d_src],y              ; src[4] | src[5] << 8
    and #$7F00
    asl a                       ; set_pitch(src[5] << 1) (data[2] & $1FF is always 0)
    sta f:sprite_entries+4,x
    lda d_sz-1               ; (shadow in the high byte)
    and #$0F00
    asl a
    asl a
    asl a
    asl a                       ; set_priority(shadow << 4)
    ora d_vz
    sta f:sprite_entries+6,x
    lda d_dp+1               ; set_pal(pal_dst), set_height (d_h follows d_dp)
    sta f:sprite_entries+10,x
DsHwSrc:                        ; X = dst * 16: SNES backend hw_src / hw_pal / hw_ent
    txa
    lsr a
    lsr a
    tax
    lda d_src
    sta f:hw_src,x
    lda d_srchi
    sta f:hw_src+2,x
    txa
    lsr a
    tax
    lda d_pals
    sta f:hw_pal,x
    lda d_ent
    sta f:hw_ent,x
    .ifdef SPRCHECK
    jsr DsChk
    .endif
    ldx d_in
    rts
    .endif                      ; (HWLIST)

; hide_hwsprite with zoom 0: only data[0] changes.  X = entry
DsHide0:
    sep #$20
    .a8
    lda f:JT+OE_CONTROL,x
    and #$FF-C_DRAW_SPRITE
    sta f:JT+OE_CONTROL,x
    rep #$20
    .a16
    ldx d_out
    .ifdef HWLIST
    lda f:sprite_entries,x
    ora #$4000
    and #$7FFF
    sta f:sprite_entries,x
    .else
    lda #$4000                  ; (render builds: record "not drawn")
    sta f:sprite_entries+RR_D0,x
    .endif
    bra DsHwEnt

; off screen: zoom, y and x were set, then hidden
DsHide1:
    ldx d_in
    sep #$20
    .a8
    lda f:JT+OE_CONTROL,x
    and #$FF-C_DRAW_SPRITE
    sta f:JT+OE_CONTROL,x
    rep #$20
    .a16
    ldx d_out
    .ifdef HWLIST
    lda d_vz
    sta f:sprite_entries+6,x
    sta f:sprite_entries+8,x
    lda d_x1
    sta f:sprite_entries+12,x
    lda d_y1
    ora #$4000
    and #$7FFF
    sta f:sprite_entries,x
    .else
    lda #$4000                  ; (render builds: record "not drawn")
    sta f:sprite_entries+RR_D0,x
    .endif
DsHwEnt:                        ; X = dst * 16: hw_ent only
    txa
    lsr a
    lsr a
    lsr a
    tax
    lda d_ent
    sta f:hw_ent,x
    .ifdef SPRCHECK
    stz d_chkv
    jsr DsChk
    .endif
    ldx d_in
    rts

; DsX: d_x1 = x + 352 adjusted for the anchor (hidden by y)
DsX:
    lda d_dp
    and #$0003
    beq @c
    cmp #$0003
    beq @c
    cmp #$0002
    bne @l
    lda d_xs
    sec
    sbc d_w
    bra @s
@c: lda d_w
    lsr a
    eor #$FFFF
    sec
    adc d_xs
    bra @s
@l: lda d_xs
@s: clc
    adc #352
    sta d_x1
    rts

; hidden by the road: palette, bank, offset and height were set
DsHide2:
    ldx d_in
    sep #$20
    .a8
    lda f:JT+OE_CONTROL,x
    and #$FF-C_DRAW_SPRITE
    sta f:JT+OE_CONTROL,x
    rep #$20
    .a16
    ldx d_out
    .ifdef HWLIST
    lda d_vz
    sta f:sprite_entries+6,x
    sta f:sprite_entries+8,x
    lda d_x1
    sta f:sprite_entries+12,x
    lda d_off
    sta f:sprite_entries+2,x
    lda d_d0
    ora #$4000
    and #$7FFF
    sta f:sprite_entries,x
    lda d_dp+1               ; pal_dst | height << 8
    sta f:sprite_entries+10,x
    .ifdef SPRCHECK
    stz d_chkv
    .endif
    jmp DsHwSrc
    .else
    lda #$4000                  ; (render builds: record "not drawn", hw_pal, hw_ent)
    sta f:sprite_entries+RR_D0,x
    txa
    lsr a
    lsr a
    lsr a
    tax
    lda d_pals
    sta f:hw_pal,x
    lda d_ent
    sta f:hw_ent,x
    ldx d_in
    rts
    .endif

;----------------------------------------------------------------------------
; Render builds: the sprite entry record (sprrec.inc) of a visible entry:
; do_sprite's values as sprv3's CandGeom uses them.
; DSRAW: A = control (h-flip bit) -> record at REC_BASE + X (RECX)
;----------------------------------------------------------------------------
.macro RECX
    .ifdef SPRCHECK
    ldx #0
    .else
    ldx d_out
    .endif
.endmacro
.macro DSRAW
    .local nofl, hws, rtl, ltr, xs, noclip, offr, noinc, d1
    and #C_HFLIP
    beq nofl
    lda #RR_MIR                 ; mirrored = h-flip (read direction XOR draw direction)
nofl:
    ora d_ent
    sta d_fl
    lda d_srchi                 ; (frame address bits 16-17)
    xba
    ora d_fl
    sta d_fl
    lda d_sz
    and #$0004                  ; hw shadow: shadow bit 2 (data[3] bit 14)
    beq hws
    lda d_fl
    ora #RR_HWS
    sta d_fl
hws:
    ; set_hrender: right to left when anchored right or at x < 0 (not left)
    lda d_dp
    lsr a
    bcs ltr
    lsr a
    bcs rtl
    lda d_xs
    bpl ltr
rtl:
    lda d_fl
    ora #RR_RTL
    sta d_fl
    lda d_x1                    ; data[6] = x1 + width
    clc
    adc d_w
    bra xs
ltr:
    lda d_x1
xs:
    RECX
    sta f:REC_BASE+RR_X,x
    lda d_d0
    sta f:REC_BASE+RR_D0,x
    lda d_src
    sta f:REC_BASE+RR_SRC,x
    lda d_fl
    sta f:REC_BASE+RR_FL,x
    lda d_vz
    sta f:REC_BASE+RR_VZ,x
    lda d_h
    sta f:REC_BASE+RR_H,x
    ; top clipped (data[0] y = $100): data[1] (rows skipped)
    lda d_d0
    and #$01FF
    cmp #$0100
    bne noclip
    .ifndef HWLIST
    lda d_y1                    ; (render builds: DsVis read the offset only when clipped)
    cmp #256
    bmi offr
    ldy #8
    lda [d_src],y
    xba
    sta d_off
offr:
    .endif
    lda d_fl                    ; read forwards (right to left unflipped, left
    and #RR_RTL + RR_MIR        ; to right flipped): + read16(src + 4) - 1
    beq noinc
    cmp #RR_RTL + RR_MIR
    beq noinc
    ldy #4
    lda [d_src],y
    xba
    dec a
    clc
    adc d_off
    bra d1
noinc:
    lda d_off
d1: sta f:REC_BASE+RR_D1,x
noclip:
.endmacro

.ifndef HWLIST
; DsRec: visible entry (DsHR, A = control): the record, hw_pal, hw_ent
DsRec:
    DSRAW
    lda d_out
    lsr a
    lsr a
    lsr a
    tax
    lda d_pals
    sta f:hw_pal,x
    lda d_ent
    sta f:hw_ent,x
    ldx d_in
    rts
.endif

.ifdef SPRCHECK
; DsChk: the arcade entry d_out / 16 was written: build its record
; (sprchk_rec: "not drawn" when hidden) and let sprv3 compare
DsChk:
    lda d_chkv
    bne :+
    jmp DsChkS
:   lda f:$402E10               ; (visible entries checked: CHK_RES + 16)
    inc a
    sta f:$402E10
    ldx d_in
    lda f:JT+OE_CONTROL,x
    DSRAW
    bra DsChkC
DsChkS:
    lda #$4000
    sta f:sprchk_rec+RR_D0
DsChkC:
    lda d_out
    lsr a
    lsr a
    lsr a
    lsr a
    pha
    lda #0
    tcd
    pla
    jsr SprChkEnt
    lda #DPG
    tcd
    rts
.endif

; zoom with the top bit set: A = src_offsets bits 16-31 (d_src = bits 0-15),
; Y = zoom * 2
DsTop:
    sta d_srchi
    adc #R0BANK                 ; (C clear)
    sta d_src+2
    lda ZVz,y
    sta d_vz                    ; set_vzoom / set_hzoom value
    lda d_sz
    and #$7C00                  ; d0 = h = (d0 & $7FFF) & $7C00 (B: TAX takes B:A)
    sep #$20
    .a8
    ldy #3
    lda [d_src],y
    tax                         ; h |= src[3]
    clc
    adc f:WHB,x
    sta d_h                     ; height = WH[h] + src[3]
    lda #0
    rol a
    sta d_h+1
    ldy #1
    lda [d_src],y
    tax                         ; d0 = (d0 & $FF00) + src[1]
    clc
    adc f:WHB,x
    sta d_w                     ; width = WH[d0] + src[1]
    lda #0
    rol a
    sta d_w+1
    rep #$20
    .a16
    lda d_w
    jmp DsWH

; DsYAdj: sprite above the screen top (y1 < 256): offset += y_adj, data[0]
; = (data[0] & $FF00) | $100, output height = y2.  The product before the
; divide is kept 32-bit as the 68000 code does (mulu.w / divu.w); the C++
; truncates it to int16, which only differs when (256 - y1) * width >= $8000
; (not reached in the tested runs).  (math.s works on the zero page: D = 0
; around the calls.)
DsYAdj:
    ldy #4
    lda [d_src],y
    xba
    pha                         ; read16(src + 4)
    ldy #2
    lda [d_src],y
    xba
    pha                         ; read16(src + 2)
    lda d_h
    pha                         ; height
    lda #256
    sec
    sbc d_y1
    tax                         ; rows above the screen
    lda #0
    tcd
    pla
    sta z:dvs                   ; / height (unsigned)
    pla                         ; * read16(src + 2) (unsigned)
    jsr UMul16
    lda z:mres
    sta z:dvd
    lda z:mres+2
    sta z:dvd+2
    jsr UDiv32_16
    ldx z:dvd
    pla                         ; * read16(src + 4)
    jsr UMul16
    lda #DPG
    tcd
    lda a:mres
    clc
    adc d_off
    sta d_off                  ; inc_offset(y_adj)
    lda d_d0
    and #$FF00
    ora #$0100
    sta d_d0
    lda d_y2                   ; set_height((uint8) y2)
    sta d_h
    rts

; DsElev: priority list populated (elevated road), X = road_p0.
; C set: the road hides the sprite; else the height is clipped (d_h).
DsElev:
    ldy #0                      ; height_entry
@count:
    iny
    inx
    inx
    inx
    inx
    lda f:RDY,x
    beq :+
    lda f:RDY+2,x
    bne @count
:   dey
    phx
    ldx d_in
    lda f:JT+OE_ROAD_PRIORITY,x
    sta d_rp
    plx
@back:
    dex
    dex
    dex
    dex
    dey
    beq @last
    bmi @last
    lda d_rp                   ; input->road_priority > road_y[i] (int)
    sec
    sbc f:RDY,x
    bvc :+
    eor #$8000
:   bmi @last
    bne @back
@last:
    lda d_rp
    sec
    sbc f:RDY,x
    bvc :+
    eor #$8000
:   bmi @clip
    beq @clip
    ; the sprite has priority: clip at the bottom of the screen
    lda d_y2
    cmp #$01E0
    bmi @ok
@sub:                           ; sub_height(y2 - 0x1DF)
    lda d_h
    clc
    adc #$01DF
    sec
    sbc d_y2
    sta d_h
@ok:
    clc
    rts
@clip:
    lda #$01DF                  ; road elevation = 0x1DF - road_y[i + 1]
    sec
    sbc f:RDY+2,x
    sta d_t
    lda d_y1
    cmp d_t
    beq :+
    bpl @hide
:   lda d_y2
    cmp d_t
    beq :+
    bpl @part
:   cmp #$01E0
    bmi @ok
    bra @sub
@part:
    lda d_h                    ; sub_height(y2 - road elevation)
    clc
    adc d_t
    sec
    sbc d_y2
    sta d_h
    clc
    rts
@hide:
    sec
    rts

;----------------------------------------------------------------------------
; MoveSprite: X = entry, A = shift: z += SPRITE_ZOOM_LOOKUP[(z >> 16) << 2 |
; sprite_scroll_speed] >> shift  (long table in rom0).  Returns X = entry,
; A = the new z >> 16.
;----------------------------------------------------------------------------
MoveSprite:
    tay                         ; shift
    bne @shift
    txy                         ; (Y = entry)
    lda f:JT+OE_Z+2,x
    sta os_t
    asl a
    asl a
    ora sprite_scroll_speed
    clc
    adc #.loword(SPRITE_ZOOM_LOOKUP)
    tax
    lda f:ZLB,x
    xba
    sta os_t+2                  ; hi
    lda f:ZLB+2,x
    xba                         ; lo
    tyx
    clc
    adc f:JT+OE_Z,x
    sta f:JT+OE_Z,x
    lda os_t
    adc os_t+2
    sta f:JT+OE_Z+2,x
    rts
@shift:
    stx os_e
    lda f:JT+OE_Z+2,x
    sta os_i
    asl a
    asl a
    ora sprite_scroll_speed
    clc
    adc #.loword(SPRITE_ZOOM_LOOKUP)
    tax
    lda f:ZLB+2,x
    xba
    sta os_t                    ; lo
    lda f:ZLB,x
    xba
    sta os_t+2                  ; hi
:   lsr os_t+2
    ror os_t
    dey
    bne :-
    ldx os_e
    lda f:JT+OE_Z,x
    clc
    adc os_t
    sta f:JT+OE_Z,x
    lda os_i
    adc os_t+2
    sta f:JT+OE_Z+2,x
    rts
.endif
