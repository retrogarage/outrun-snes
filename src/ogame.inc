; Conventions of the game engine port (original CannonBall classic engine,
; src/o*.s): object table, arcade ROM access, shared constants.
;
; Object entries (oentry): 64-byte records in the far table JT (bank $41),
; the same layout as tools/cbref0 packs them, so SNES and reference dumps
; compare directly.  Code addresses an entry by its byte offset (index*64),
; usually in X, and uses the E* macros (long indexed: DB stays $00).
;
; Arcade ROM: the main CPU ROM (rom0) is embedded 64 KB aligned: arcade
; address A is at SNES $D1 + (A >> 16) : A & $FFFF (big endian data).
.ifndef OGAME_INC
OGAME_INC = 1
.include "oaddr.inc"        ; arcade rom0 addresses, sound ids S_*

; ---- oentry fields ----
OE_CONTROL      = 0     ; byte
OE_JUMP_INDEX   = 1     ; byte
OE_FUNC         = 2     ; byte  function_holder (int8)
OE_ID           = 3     ; byte
OE_SHADOW       = 4     ; byte
OE_ZOOM         = 5     ; byte
OE_DRAW_PROPS   = 6     ; byte
OE_PAL_DST      = 7     ; byte
OE_PAL_SRC      = 8     ; word
OE_X            = 10    ; word  int16
OE_Y            = 12    ; word  int16
OE_WIDTH        = 14    ; word
OE_PRIORITY     = 16    ; word
OE_DST_INDEX    = 18    ; word
OE_ADDR         = 20    ; long  sprite frame (rom0 address)
OE_ROAD_PRIORITY = 24   ; word
OE_RELOAD       = 26    ; word  int16
OE_COUNTER      = 28    ; word
OE_XW1          = 30    ; word  int16
OE_Z            = 32    ; long  int32
OE_TRAFFIC_SPEED = 36   ; word  int16
OE_TYPE         = 38    ; word
OE_XW2          = 40    ; word  int16
OE_TRAFFIC_PROXIMITY = 42 ; byte
OE_TRAFFIC_FX   = 43    ; byte
OE_TRAFFIC_ORIG_SPEED = 44 ; word int16
OE_TRAFFIC_NEAR_SPEED = 46 ; word int16
OE_YW           = 48    ; word
OE_PASS_PROPS   = 50    ; word  int16
OE_SIZE         = 64

; control bits (OSprites enum)
C_HFLIP          = $01
C_WIDE_ROAD      = $04
C_TRAFFIC_SPRITE = $08
C_SHADOW         = $10
C_DRAW_SPRITE    = $20
C_TRAFFIC_RHS    = $40
C_ENABLE         = $80
; draw_props anchors
DP_CENTRE = 0
DP_LEFT   = 1
DP_RIGHT  = 2
DP_TOP    = 4
DP_BOTTOM = 8

; ---- jump table entries ----
SPRITE_ENTRIES      = $62
NO_SPRITES          = $4F       ; level objects in use (classic)
SPRITE_FERRARI      = SPRITE_ENTRIES + 1
SPRITE_PASS1        = SPRITE_ENTRIES + 2
SPRITE_PASS2        = SPRITE_ENTRIES + 3
SPRITE_SHADOW       = SPRITE_ENTRIES + 4
SPRITE_SMOKE1       = SPRITE_ENTRIES + 5
SPRITE_SMOKE2       = SPRITE_ENTRIES + 6
SPRITE_TRAFF1       = SPRITE_ENTRIES + 7
SPRITE_TRAFF8       = SPRITE_ENTRIES + 14
SPRITE_CRASH        = SPRITE_ENTRIES + 15
SPRITE_CRASH_SHADOW = SPRITE_ENTRIES + 16
SPRITE_CRASH_PASS1  = SPRITE_ENTRIES + 17
SPRITE_CRASH_PASS1_S = SPRITE_ENTRIES + 18
SPRITE_CRASH_PASS2  = SPRITE_ENTRIES + 19
SPRITE_CRASH_PASS2_S = SPRITE_ENTRIES + 20
SPRITE_FLAG         = SPRITE_ENTRIES + 21
JUMP_ENTRIES_TOTAL  = SPRITE_ENTRIES + 24
; NOTE ca65: a .define macro takes the rest of the line as its argument, so
; EOFS(a)+b means EOFS((a)+b): always write the macro LAST (b+EOFS(a)).
.define EOFS(i) ((i) * OE_SIZE)

.global JT: far

; E-macros: X = entry byte offset
.macro LDE f
    lda f:JT+f,x
.endmacro
.macro STE f
    sta f:JT+f,x
.endmacro
.macro ADCE f
    adc f:JT+f,x
.endmacro
.macro SBCE f
    sbc f:JT+f,x
.endmacro
.macro CMPE f
    cmp f:JT+f,x
.endmacro
.macro ANDE f
    and f:JT+f,x
.endmacro
.macro ORAE f
    ora f:JT+f,x
.endmacro
.macro EORE f
    eor f:JT+f,x
.endmacro
; byte fields: LDEB reads the word and masks (same result and flags as an
; 8-bit load; the extra byte read has no side effect), STEB stores 8 bits
.macro LDEB f
    lda f:JT+f,x
    and #$00FF
.endmacro
.macro STEB f
    sep #$20
    sta f:JT+f,x
    rep #$20
.endmacro

; ---- arcade rom0 ----
R0BANK = $D1
; R0(adr): SNES long address of constant arcade rom0 address adr
.define R0(adr) R0BANK * $10000 + ((adr) & $FFFF0000) + ((adr) & $FFFF)
; big endian word at a constant address
.macro R0W adr
    lda f:R0(adr)
    xba
.endmacro

; ---- oanimsprite records (BSS, owned by oanimseq.s; an oanimsprite*
; argument is the bank 0 address of the record, in Y) ----
AS_SPRITE    = 0        ; word: entry byte offset (oentry* sprite)
AS_ADDR_CURR = 2        ; long
AS_ADDR_NEXT = 6        ; long
AS_FRAME     = 10       ; word int16 anim_frame
AS_DELAY     = 12       ; word: uint8 frame_delay (high byte 0)
AS_PROPS     = 14       ; word anim_props
AS_STATE     = 16       ; word int16 anim_state
AS_SIZE      = 18

; ---- input keys (Input::presses): InIsPressed / InHasPressed /
; InIsPressedClear take A = key and return A = 0/1 (Z flag set when 0) ----
IN_LEFT  = 0
IN_RIGHT = 1
IN_UP    = 2
IN_DOWN  = 3
IN_ACCEL = 4
IN_BRAKE = 5
IN_GEAR1 = 6
IN_GEAR2 = 7
IN_START = 8
IN_COIN  = 9
IN_VIEWPOINT = 10

; ---- OHud colours ----
HUD_GREY  = $84
HUD_PINK  = $86
HUD_GREEN = $92

; ---- game states ----
.ifndef GS_INIT
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
.endif

.endif
