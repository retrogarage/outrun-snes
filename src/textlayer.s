; Text layer (engine port): the arcade text RAM (vidport.s txt_ram: 64 x 32
; cells, screen columns 24-63) shown on BG3.  Arcade tiles are 3bpp with
; text palettes 0-7; tools/mktext.py packs the colour combinations the game
; shows into 8 BG3 palettes of 3 colours per layout class (race HUD states /
; the rest) and pre-converts every (tile, arcade palette) to 2bpp for the
; BG3 palette that shows it best (TxtTiles0-3, TxtSnPal).
;
; - The 40 arcade screen columns are remapped to the 32 SNES columns per
;   row: the race HUD rows get their own maps (small gaps removed), other
;   rows are centred (arcade columns 4-35); rows 25-27 drop the gaps of the
;   bottom line in every state.
; - Tiles: a cache of 255 BG3 VRAM slots (slot 0 = blank) keyed by
;   tile | palette << 9 (TL_SLOT); when it is full it is flushed and the
;   whole layer rebuilt.
; - Dirty rows (vidport txt_dirty) are rebuilt into TL_MAP and streamed to
;   the BG3 map with the tiles (FIFO, before the frame swap).
; - Palettes: BG3 colour k of palette p = the arcade palette RAM word
;   TxtRef[class][p][k-1] (words 0-63 tracked in tl_pal, initialised from
;   TxtPal0, updated by VidWritePal32).  A layout class change flushes the
;   tile cache (tile data and palettes depend on the class).
.ifdef NEWGAME
.p816
.smart
.include "sa1.inc"
.include "shared.inc"
.include "globals.inc"
.include "ogame.inc"
.include "textdat.inc"
.include "road2.inc"

.import txt_ram: far
.import txt_lo, txt_hi, VidMarkTextAll
.import txt_dirty, game_state, QueueUpload, FifoWait, cfg_active
.importzp ptr0
.export TextInit, TextRender, TextPalWrite, tl_pal

TL_SLOT  = $402000          ; 4096 bytes: slot of tile | pal << 9 (0 none)
TL_MAP   = $40F900          ; 28 rows x 32 BG3 map words
TL_ROWS  = 28
MAX_ROWS = 28               ; rows rebuilt per frame (blank rows are cheap)
MAX_NEW  = 64               ; new tiles per frame
MAP_MID  = 0
MAP_TOP  = 32
MAP_BOT  = 64

.segment "BSS"
tl_pal:     .res 128        ; text palettes (arcade words, palette RAM 0-63)
tl_pdirty:  .res 2
tl_next:    .res 2          ; next free tile slot
tl_class:   .res 2          ; HUD layout active (0/1)
tl_row:     .res 2
tl_col:     .res 2
tl_rows:    .res 2
tl_t:       .res 4
tl_slot:    .res 2
tl_new:     .res 2

.segment "IRAMBSS"
; BuildRow column loop
br_map:     .res 2          ; ColMap offset of the column
br_tro:     .res 2          ; text RAM offset of arcade column 0 of the row
br_mp:      .res 2          ; TL_MAP offset of the column
br_cls:     .res 2          ; TxtSnPal class offset
br_n:       .res 2          ; columns left
br_slot:    .res 2

.segment "BWBSS": far
tl_entry:   .res 512        ; complete BG3 map word for each cached tile slot
tl_cg:      .res 64         ; BG3 colours (CGRAM 0-31; DMA source in bank $41)

.segment "SA1CODE"
.a16
.i16

;----------------------------------------------------------------------------
; TextInit
;----------------------------------------------------------------------------
TextInit:
    ldx #0
:   lda f:TxtPal0,x
    sta tl_pal,x
    inx
    inx
    cpx #128
    bcc :-
    lda #1
    sta tl_pdirty
    stz tl_class
    jmp Flush

; Flush: forget every tile slot, rebuild all rows
Flush:
    ldx #0
    lda #0
:   sta f:TL_SLOT,x
    inx
    inx
    cpx #$1000
    bcc :-
    lda #1
    sta tl_next
    jmp VidMarkTextAll

;----------------------------------------------------------------------------
; TextPalWrite: X = palette RAM entry (0-63), A = arcade colour
;----------------------------------------------------------------------------
TextPalWrite:
    pha
    txa
    asl a
    tax
    pla
    sta tl_pal,x
    lda #1
    sta tl_pdirty
    rts

;----------------------------------------------------------------------------
; TextRender: palettes, dirty rows
;----------------------------------------------------------------------------
TextRender:
    ; layout class: race HUD in the race / bonus / game over states
    ldx #0
    lda cfg_active
    bne @class
    lda game_state
    and #$00FF
    cmp #GS_START1
    bcc :+
    cmp #GS_GAMEOVER+1
    bcs :+
    ldx #1
:
@class:
    cpx tl_class
    beq :+
    stx tl_class
    jsr Flush               ; new column maps, palettes and tile data
    lda #1
    sta tl_pdirty
:   lda tl_pdirty
    beq @rows
    stz tl_pdirty
    jsr Palettes
@rows:
    stz tl_rows
    stz tl_row
    stz tl_new
@r: lda tl_row
    cmp #TL_ROWS
    bcs @done
    ; dirty bit
    cmp #16
    bcs :+
    asl a
    tax
    lda f:Bit16,x
    and txt_dirty
    beq @n
    bra @do
:   and #$000F
    asl a
    tax
    lda f:Bit16,x
    and txt_dirty+2
    beq @n
@do:
    lda tl_rows
    cmp #MAX_ROWS
    bcs @done
    lda tl_new
    cmp #MAX_NEW - 32
    bcs @done               ; (a row may need up to 32 new tiles)
    inc tl_rows
    jsr BuildRow
    bcs @flush
    lda tl_row
    asl a
    tax
    lda #128
    sta txt_lo,x
    stz txt_hi,x
    ; clear the dirty bit
    lda tl_row
    cmp #16
    bcs :+
    asl a
    tax
    lda f:Bit16,x
    trb txt_dirty
    bra @n
:   and #$000F
    asl a
    tax
    lda f:Bit16,x
    trb txt_dirty+2
@n: inc tl_row
    bra @r
@done:
    rts
@flush:
    jmp Flush               ; (slots exhausted: start over next frame)

;----------------------------------------------------------------------------
; BuildRow: tl_row -> TL_MAP row, FIFO uploads (new tiles, the row).
; C set when the tile slots ran out.
;----------------------------------------------------------------------------
BuildRow:
    ; column map of this row
    ; rows 25-27 (race HUD / CREDIT, (C) SEGA): MAP_BOT in every state
    ldy #MAP_MID
    lda cfg_active
    bne @map
    ldy #MAP_BOT
    lda tl_row
    cmp #25
    bcs @map
    ldy #MAP_MID
    lda tl_class
    beq @map
    lda tl_row
    cmp #3
    bcs @map
    ldy #MAP_TOP
@map:
    sty br_map              ; ColMap offset of SNES column 0
    tya
    asl a
    asl a
    sta br_cls              ; inverse-map page (128 bytes per layout)
    lda tl_row
    asl a
    tax
    lda txt_hi,x
    clc
    adc br_cls
    tay
    lda a:DirtyCols+1,y
    and #$00FF
    sta br_n               ; one past the last affected SNES column
    lda txt_lo,x
    cmp #128
    bcc :+
    jmp @row               ; no displayed cells changed
:   clc
    adc br_cls
    tay
    lda a:DirtyCols,y
    and #$00FF
    sta tl_col
    lda br_n
    sec
    sbc tl_col
    bne :+
    jmp @row
:   sta br_n
    lda br_map
    clc
    adc tl_col
    sta br_map
    ; text RAM word (arcade order) of arcade screen column 0 of the row:
    ; (row * 64 + 24) * 2
    lda tl_row
    xba
    lsr a
    clc
    adc #48
    sta br_tro
    ; TL_MAP offset of the row: row * 64
    lda tl_row
    xba
    lsr a
    lsr a
    sta br_mp
    lda tl_col
    asl a
    clc
    adc br_mp
    sta br_mp
    ; TxtSnPal class offset
    lda tl_class
    beq :+
    lda #$1000
:   sta br_cls
@c: ldx br_map
    lda f:ColMap,x
    and #$00FF
    cmp #$00FF
    beq @blank
    asl a                   ; (C clear)
    adc br_tro
    tax
    lda f:txt_ram,x
    xba                     ; code
    sta tl_t
    and #$01FF
    beq @blank
    ; slot of tile | pal << 9
    lda tl_t
    and #$0FFF
    tax
    lda f:TL_SLOT,x
    and #$00FF
    bne @have
    ; new slot
    lda tl_next
    cmp #256
    bcc :+
    sec
    rts
:   inc tl_next
    sep #$20
    .a8
    sta f:TL_SLOT,x
    rep #$20
    .a16
    pha
    inc tl_new
    jsr UploadTile          ; A = slot, tl_t = code
    pla
    sta br_slot
    ; entry = slot | SNES palette << 10 | priority (TxtSnPal: per class,
    ; arcade palette and tile)
    lda tl_t
    and #$0FFF
    ora br_cls
    tax
    lda f:TxtSnPal,x
    and #$0007
    xba
    asl a
    asl a                   ; << 10
    ora #$2000
    ora br_slot
    pha
    lda br_slot
    asl a
    tax
    pla
    sta f:tl_entry,x
    bra @put
@have:
    asl a
    tax
    lda f:tl_entry,x
    bra @put
@blank:
    lda #0
@put:
    ldx br_mp
    sta f:TL_MAP,x
    inx
    inx
    stx br_mp
    inc br_map
    dec br_n
    beq @row
    jmp @c
@row:
    ; stream the row: 64 bytes to VR_BG3MAP + row * 32
    lda tl_row
    xba
    lsr a
    lsr a
    clc
    adc #.loword(TL_MAP)
    tay                     ; source offset in bank $40
    lda tl_row
    asl a
    asl a
    asl a
    asl a
    asl a
    clc
    adc #VR_BG3MAP
    tax
    lda #64
    jsr FifoBw
    clc
    rts

; UploadTile: A = slot, tl_t = code: the 2bpp tile (16 bytes) of tile | pal
UploadTile:
    asl a
    asl a
    asl a                   ; slot * 8 words
    clc
    adc #VR_BG3T
    tax                     ; VRAM word address
    ; source: TxtTiles(2 * class + pal / 4) + ((pal & 3) * 512 + tile) * 16
    lda tl_t
    and #$07FF              ; (pal & 3) << 9 | tile
    asl a
    asl a
    asl a
    asl a                   ; * 16 (< 32K)
    sta ptr0
    lda tl_t
    and #$0800
    beq :+
    lda #2
:   ora tl_class            ; (0 / 1) -> index * 2
    asl a
    phx
    tax
    lda f:TxtBank,x
    tay
    plx
    lda #$8000              ; (every TxtTiles bank starts at $8000)
    clc
    adc ptr0
    ; FIFO entry: ROM source
    pha
    phx
    jsr FifoWait
    lda SH_UQW
    asl a
    asl a
    asl a
    tax
    pla
    sta f:UQ_BUF+UQ_DEST,x
    pla
    sta f:UQ_BUF+UQ_SRC,x
    tya
    and #$00FF              ; bank, BMAPS unused (0)
    sta f:UQ_BUF+UQ_BANK,x
    lda #16
    sta f:UQ_BUF+UQ_SIZE,x
    lda SH_UQW
    inc a
    and #UQ_MASK
    sta SH_UQW
    rts

; FifoBw: Y = source offset in bank $40, X = VRAM word address, A = bytes
; (the S-CPU reads bank $40 through the $6000 window: BMAPS block)
FifoBw:
    sta tl_t
    phx
    jsr FifoWait
    lda SH_UQW
    asl a
    asl a
    asl a
    tax
    pla
    sta f:UQ_BUF+UQ_DEST,x
    tya
    and #$1FFF
    ora #$6000
    sta f:UQ_BUF+UQ_SRC,x
    tya
    xba
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    and #$0007              ; block
    xba                     ; hi = BMAPS block, lo = bank $00
    sta f:UQ_BUF+UQ_BANK,x
    lda tl_t
    sta f:UQ_BUF+UQ_SIZE,x
    lda SH_UQW
    inc a
    and #UQ_MASK
    sta SH_UQW
    rts

;----------------------------------------------------------------------------
; Palettes: BG3 colours from the text palettes (CGRAM 1-31, queued)
;----------------------------------------------------------------------------
Palettes:
    ldx #0
@p: stx tl_row              ; palette p
    txa
    asl a
    asl a
    asl a
    tax
    lda #0
    sta f:tl_cg,x           ; colour 0 (transparent)
    ldy #1
@k: sty tl_col              ; colour k
    ; arcade palette entry TxtRef[class * 24 + p * 3 + k - 1]
    lda tl_row
    asl a
    clc
    adc tl_row
    clc
    adc tl_col
    dec a
    ldx tl_class
    beq :+
    clc
    adc #24
:   tax
    lda f:TxtRef,x
    and #$00FF
    asl a
    tax
    lda tl_pal,x            ; arcade colour of that palette RAM word
    jsr ArcToSnes
    pha
    lda tl_row
    asl a
    asl a
    asl a
    clc
    adc tl_col
    adc tl_col
    tax
    pla
    sta f:tl_cg,x
    ldy tl_col
    iny
    cpy #4
    bcc @k
    ldx tl_row
    inx
    cpx #8
    bcc @p
    ; queue CGRAM 1-31 (swap time)
    lda #.loword(tl_cg+2)
    sta ptr0
    sep #$20
    .a8
    lda #^tl_cg
    sta ptr0+2
    rep #$20
    .a16
    lda #1                  ; CGRAM
    ldx #1
    ldy #62
    jmp QueueUpload

; ArcToSnes: A = arcade colour word -> A = BGR555
ArcToSnes:
    sta tl_t+2
    and #$00FF
    asl a
    tax
    lda f:ArcSnLo,x
    sta tl_t
    lda tl_t+2
    xba
    and #$00FF
    asl a
    tax
    lda f:ArcSnHi,x
    ora tl_t
    rts

.segment "RODATA"
TxtBank:    .word ^TxtTiles0, ^TxtTiles2, ^TxtTiles1, ^TxtTiles3   ; [pal / 4 * 2 + class]
Bit16:
    .repeat 16, I
    .word 1 << I
    .endrepeat
; Define each layout once; derive its forward map and dirty-span inverse.
; The inverse relies on increasing source columns (asserted below).
.macro TextColumn result, column, layout
    .if layout = 0
        result .set column + 4
    .elseif layout = 1
        result .set .mid(2*column, 1, {2, 3, 4, 5, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 30, 31, 32, 33, 34, 35, 36})
    .else
        result .set .mid(2*column, 1, {2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39})
    .endif
.endmacro
; Native byte-column -> first mapped column at/after it, first after it.
; Dirty spans omit no mapped cells; unmapped columns need no tile lookup.
DirtyCols:
.repeat 3, Layout
    .repeat 64, Native
        First .set 0
        After .set 0
        .repeat 32, Column
            TextColumn Source, Column, Layout
            .if Source + 24 < Native
                First .set First + 1
            .endif
            .if Source + 24 <= Native
                After .set After + 1
            .endif
        .endrepeat
        .byte First, After
    .endrepeat
.endrepeat
; SNES column -> arcade screen column. MID is centred; TOP removes the
; race HUD gaps; BOT removes the speed/revs and credit-line gaps.
ColMap:
.repeat 3, Layout
    Previous .set -1
    .repeat 32, Column
        TextColumn Source, Column, Layout
        .assert Source > Previous, error, "text columns must be increasing"
        .byte Source
        Previous .set Source
    .endrepeat
.endrepeat
.endif
