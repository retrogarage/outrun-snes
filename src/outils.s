; OUtils: OutRun utility routines - port of engine/outils.cpp (classic),
; plus the arcade rom0 read helpers of the engine port (docs/port.md).
.ifdef NEWGAME
.p816
.smart
.include "sa1.inc"
.include "globals.inc"
.include "ogame.inc"

.export Random, ResetRandomSeed, BcdAdd, BcdSub, R0Set, R0Byte, R0Word, R0Long
.exportzp rp0, rp1
.export bcd_a, bcd_b, rnd_seed

.segment "ZEROPAGE"
rp0:    .res 3              ; rom0 pointers ([rp0],y), caller-saved
rp1:    .res 3

.segment "BSS"
rnd_seed: .res 4
rnd_s:    .res 4
bcd_a:    .res 4            ; BcdAdd / BcdSub operands (src, dst)
bcd_b:    .res 4

.segment "SA1CODE"
.a16
.i16

;----------------------------------------------------------------------------
; ResetRandomSeed / Random (source $6C8E): -> A = low word, X = high word
;   seed = rnd_seed ? rnd_seed : $2A6D365A;  S = seed * 41
;   result = seed.hi : (S.lo + S.hi);  new seed = (S.lo + S.hi) : S.lo
;----------------------------------------------------------------------------
ResetRandomSeed:
    stz rnd_seed
    stz rnd_seed+2
    rts

Random:
    lda rnd_seed
    ora rnd_seed+2
    bne :+
    lda #$365A
    sta rnd_seed
    lda #$2A6D
    sta rnd_seed+2
:   ; S = seed * 41 = ((seed << 2) + seed) << 3 + seed
    lda rnd_seed
    sta rnd_s
    lda rnd_seed+2
    sta rnd_s+2
    asl rnd_s
    rol rnd_s+2
    asl rnd_s
    rol rnd_s+2
    lda rnd_s
    clc
    adc rnd_seed
    sta rnd_s
    lda rnd_s+2
    adc rnd_seed+2
    sta rnd_s+2
    asl rnd_s
    rol rnd_s+2
    asl rnd_s
    rol rnd_s+2
    asl rnd_s
    rol rnd_s+2
    lda rnd_s
    clc
    adc rnd_seed
    sta rnd_s
    lda rnd_s+2
    adc rnd_seed+2
    sta rnd_s+2
    ; result hi = old seed hi
    ldx rnd_seed+2
    ; lo = S.lo + S.hi
    lda rnd_s
    clc
    adc rnd_s+2
    sta rnd_seed+2          ; new seed hi
    pha
    lda rnd_s
    sta rnd_seed            ; new seed lo
    pla
    rts

;----------------------------------------------------------------------------
; BcdAdd: bcd_b = bcd_a + bcd_b (32-bit packed BCD, as bcd_add(src, dst))
; BcdSub: bcd_b = bcd_b - bcd_a (bcd_sub(src, dst)); -> A = low word
;----------------------------------------------------------------------------
BcdAdd:
    sed
    clc
    lda bcd_a
    adc bcd_b
    sta bcd_b
    lda bcd_a+2
    adc bcd_b+2
    sta bcd_b+2
    cld
    lda bcd_b
    rts

BcdSub:
    sed
    sec
    lda bcd_b
    sbc bcd_a
    sta bcd_b
    lda bcd_b+2
    sbc bcd_a+2
    sta bcd_b+2
    cld
    lda bcd_b
    rts

;----------------------------------------------------------------------------
; rom0 access: A = address low word, Y = high word (arcade 32-bit address)
;----------------------------------------------------------------------------
; R0Set: rp0 -> the byte
R0Set:
    sta rp0
    tya
    clc
    adc #R0BANK
    sep #$20
    .a8
    sta rp0+2
    rep #$20
    .a16
    rts

; R0Byte: -> A = byte
R0Byte:
    sta rp0
    tya
    clc
    adc #R0BANK
    sep #$20
    .a8
    sta rp0+2
    rep #$20
    .a16
    lda [rp0]
    and #$00FF
    rts

; R0Word: -> A = big endian word
R0Word:
    sta rp0
    tya
    clc
    adc #R0BANK
    sep #$20
    .a8
    sta rp0+2
    rep #$20
    .a16
    lda [rp0]
    xba
    rts

; R0Long: -> A = high word, X = low word (the two words may be in different
; 64 KB banks: then word by word; Y ends as that path leaves it)
R0Long:
    cmp #$FFFE
    bcs @two
    sta rp0
    phy
    tya
    clc
    adc #R0BANK
    sep #$20
    .a8
    sta rp0+2
    rep #$20
    .a16
    ldy #2
    lda [rp0],y
    xba
    tax
    lda [rp0]
    xba
    ply
    rts
@two:
    pha
    phy
    jsr R0Word
    sta rnd_s               ; (scratch)
    ply
    pla
    clc
    adc #2
    bcc :+
    iny
:   jsr R0Word
    tax
    lda rnd_s
    rts
.endif
