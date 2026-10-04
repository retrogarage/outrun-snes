; Variables shared between S-CPU and SA-1 (I-RAM $3700-$37FF, visible to both)
.ifndef SHARED_INC
SHARED_INC = 1

SH_FRAME   = $3700      ; word  frame counter (S-CPU NMI increments)
SH_JOY     = $3702      ; word  joypad 1 (S-CPU writes each NMI)
SH_READY   = $3704      ; word  SA-1 sets 1 when back buffer complete; S-CPU clears on swap
SH_BUILD   = $3706      ; word  HDMA table set offset the SA-1 builds into (0/HT_SETSZ)
SH_DISP    = $3708      ; word  displayed set offset
SH_BRIGHT  = $370A      ; word  INIDISP value
SH_QN      = $370C      ; word  upload queue entry count (applied with the next swap)
SH_BOOT    = $370E      ; word  SA-1 sets $55AA when running
SH_Q       = $406E00    ; swap-time upload queue in BW-RAM: 128 entries x 8 bytes
SH_QMAX    = 128
SH_PROF    = $3790      ; profiling marks (frame, vcount) x 16 ($3790-$37CF)
SH_UQW     = $37D0      ; word: streaming upload FIFO write index (SA-1)
SH_UQR     = $37D2      ; word: FIFO read index (S-CPU)
SH_UQT     = $37D4      ; word: FIFO index that must be reached before the ready swap
SH_OAMSRC  = $37D6      ; word: BW-RAM (bank $40) address of the OAM buffer to show
SH_LASTSW  = $37D8      ; word: SH_FRAME at last swap
SH_PACE    = $37DA      ; word: minimum frames between swaps (2 = 30 fps)
SH_UQDONE  = $37DC      ; word: count of FIFO entries processed (debug)
SH_SWAPS   = $37DE      ; word: number of swaps (debug)
SH_BLOCKED = $37E0      ; word: swap checks blocked by pending uploads (debug)
SH_QBYTES  = $37E2      ; word: bytes in the swap queue (SA-1 accumulates)
SH_VMODE   = $37E4      ; word: 0 road view (HDMA split), 1 page (Mode 1 BG1 picture)
SH_LOAD    = $37E6      ; word: bulk load list address, 0 = none (S-CPU clears when done)
SH_LOADB   = $37E8      ; word: bulk load list bank
SH_BG1VOFS = $37EA      ; word: page mode BG1 vertical scroll
SH_PALQ    = $37EC      ; word: unused
SH_BRIGHTN = $37EE      ; word: INIDISP value that comes with the next swap (NEWGAME)
SH_MREQ    = $37F0      ; word: mark request sequence (SA-1 increments)
SH_MSLOT   = $37F2      ; word: slot*4 for the pending mark
SH_MACK    = $37F4      ; word: last acknowledged sequence (S-CPU)

; Road hand-over (NEWGAME, rrender.s RoadRender -> sroad.s on the S-CPU):
; the SA-1 fills SH_RLN..SH_RSCR, sets SH_RPEND and SH_RBUSY and raises the
; S-CPU IRQ (SCNT).  The S-CPU IRQ handler (runs with the S-CPU I flag clear
; since boot, WRAM $7F code) copies the inputs to WRAM (GP-DMA channel 7),
; clears SH_RPEND (the SA-1 may run the next logic tick: ngmain
; RoadSnapWait), builds the HDMA tables of set SH_BUILD and clears SH_RBUSY
; (TrySwap does not swap before that).  S-CPU resources of the road path:
; IRQ, DMA channel 7, HDMA channels 1-5 (indirect), WRAM bank $7F, the PPU
; multiplier (M7A / M7B: the road view never uses Mode 7).
SH_RLN     = $3710      ; word: source of the line words (bank $41: road_y + road_p2 + $640)
SH_RCO     = $3712      ; 2 words: rd_co (car offset per road)
SH_RINV    = $3716      ; 2 words: rd_inv
SH_RCTL    = $371A      ; word: rd_hwctl
SH_RPH     = $371C      ; word: rd_colph
SH_RSCR    = $371E      ; 4 words: sc_fgh, sc_fgv, sc_bgh, sc_bgv
SH_RPEND   = $3726      ; word: 1 = inputs not copied yet (SA-1 sets, S-CPU clears)
SH_RBUSY   = $3728      ; word: 1 = tables not built yet (SA-1 sets, S-CPU clears)
SH_MENUN   = $3732      ; settings mode for next frame
SH_MENU    = $3734      ; settings mode on screen (swap-latched)
SH_RPARN   = 11         ; words SH_RLN..SH_RSCR+6
SH_RSA     = $372A      ; word: first line the SA-1 builds itself (224: none; see SR_STG)
SH_RSAD    = $372C      ; word: 1 = the SA-1's lines are in SR_STG
SH_OHBN    = $372E      ; [W1c] word: lines SH_OHBS..n-1 take the SA-1's per-line
                        ; HOFS / VOFS and window data from SR_STG SG_BG1 / SG_WIN
                        ; (overhead structures, sprv3.s ohb.inc): BG1 on the top
                        ; solid run's lines, BG2 on the road lines (0: none)
SH_OHBS    = $3730      ; [W1c] word: the first of those lines

; bulk load list entry (8 bytes): +0 type (0 VRAM, 1 CGRAM, 2 VRAM zero fill,
; $FF end), +1 dest (VRAM word / CGRAM index), +3 24-bit source, +6 size (bytes)
BL_VRAM = 0
BL_CGRAM = 1
BL_FILL = 2
BL_COLUMN = 3           ; VRAM, increment 32 (map column)

; queue entry layout
Q_TYPE = 0              ; byte: 0 VRAM, 1 CGRAM, 2 VRAM (mode 7 low bytes), 3 VRAM high bytes,
                        ;       4 VRAM column (increment 32)
Q_DEST = 1              ; word: VRAM word address / CGRAM index
Q_SRC  = 3              ; 24-bit source address
Q_SIZE = 6              ; word: bytes

; Road view HDMA tables (BW-RAM bank $40, read by the S-CPU HDMA): two sets
; HT_SETSZ apart, SH_BUILD / SH_DISP hold the set offset (0 / HT_SETSZ).
; Each table: $FF + 127 lines x 4 bytes, $E1 + 97 lines x 4 bytes, $00.
HT_BASE  = $403000
HT_SETSZ = $1200
HT_BG1   = $0000        ; BG1HOFS, BG1VOFS (mode 3)
HT_BG2   = $0384        ; BG2HOFS, BG2VOFS (mode 3)
HT_WIN   = $0708        ; WH0-WH3 (mode 4)
HT_COL   = $0A8C        ; CGADD x2 (0), CGDATA x2: backdrop colour (mode 3)
HT_SC    = $0E10        ; BG1SC-BG4SC (mode 4)
HT_LEN   = $0384
PAL_BUF  = $405700      ; palette staging (up to 256 bytes)

; NEWGAME: the road view HDMA tables are built by the S-CPU (sroad.s) in WRAM
; bank $7F instead (HT_BASE is unused): two sets SR_SETSZ apart (SH_BUILD /
; SH_DISP != 0 selects the second), channels 1-5 in indirect mode (data
; bank $7F).  Entry tables per set:
SR_SETA  = $A000        ; set 0 (bank $7F)
SR_SETSZ = $1C20
SR_TBG1  = $1180        ; ch1 BG1HOFS/VOFS
SR_TBG2  = $1424        ; ch2 BG2HOFS/VOFS
SR_TWIN  = $16C8        ; ch3 WH0-WH3
SR_TSC   = $196C        ; ch5 BG1SC-BG4SC
SR_TCOL  = $1C10        ; ch4 CGADD x2 / CGDATA x2
SR_IRQ   = $8000        ; S-CPU IRQ handler (WRAM $7F:8000, sroad.s)
; SA-1 built lines SH_RSA..223 (the bottom of long road runs, rrender.s
; RrLines) in the set layout, BW-RAM (the freed HT_BASE area); the S-CPU DMAs
; them into the set.  4 bytes per line each:
.ifdef SRCHECK
SR_STG   = $40C000          ; (SRCHECK test builds, with -D NOSPR: HT_BASE holds
                            ; the reference tables; the sprite cells are unused)
.else
SR_STG   = $403000
.endif
SG_BG1   = $0000            ; BG1HOFS, BG1VOFS
SG_BG2   = $0380            ; BG2HOFS, BG2VOFS
SG_WIN   = $0700            ; WH0-WH3
SG_COL   = $0A80            ; 0, 0 (constant), backdrop colour

; VRAM layout of the road view (word addresses)
VR_ROADT   = $0000      ; road tiles 0-244 (BG1/BG2 character base $0000)
VR_SCNT    = $0F50      ; scenery tile slots (tile 245-767)
VR_FGMAP   = $3000      ; arcade FG tile layer, 64x32 (BG1 above the horizon)
VR_BGMAP   = $3800      ; arcade BG tile layer, 64x32 (BG2 above the horizon)
VR_ROADMAP = $4000      ; road map 64x64 (BG1 / BG2 on road lines)
VR_BG3T    = $5000      ; HUD tiles (BG3 character base)
VR_BG3MAP  = $5C00      ; HUD map 32x32
SC_FG      = $31        ; BGnSC values
SC_BG      = $39
SC_ROAD    = $43
SC_BG3     = $5C

; debug readback area (DEBUG_BW builds; ROADTEST marker at +$E00)
DBG_AREA = $402000

; SNES colours (BGR555) of arcade palette entries $400-$7FF (road, ground,
; sky / solid colours), bank $41; PALAR = the arcade words
PALSN    = $41C000
PALAR    = $41C800
OAM_BUF0 = $405800      ; OAM buffers (544 bytes each)
OAM_BUF1 = $405A40
UQ_BUF   = $406000      ; streaming upload FIFO: 256 entries x 8 bytes
UQ_MASK  = $FF
; FIFO entry: +0 dest (VRAM word), +2 src (window $6000-$7FFF), +4 bank ($00),
;             +5 BW-RAM block for BMAPS, +6 size
; [W1 sprv3] UQ_TYPE bit 7 set: a sprite run (src/sprv3.s): src / bank =
; ROM through the HiROM $E0-$EF window, UQ_TYPE & 7 = its 1 MB block (the
; S-CPU sets EXB), UQ_SIZE = bytes per half (bits 0-9) | band pieces << 10:
; two DMAs, top halves to dest, bottom halves (src + pieces * 64) to dest +
; $100 (main.s UqStream)
; UQ_TYPE bits 7+6: one pixel-exact clipped cell. UQ_SIZE holds the
; band stride as above, visible rows in bits 0-3, and bit 4 for packing
; 1-7 rows at the bottom of 8px tiles. Only the S-CPU touches ROM mapping.
UQ_CLIP = $40
UQ_CLIP_PACK = $10
UQ_DEST = 0
UQ_SRC  = 2
UQ_BANK = 4
UQ_TYPE = 5
UQ_SIZE = 6
; NEWGAME scenery spacing history: 256 types x 2 sides x 16-bit road pos.
; Between sprv3 OB_DN ($40E200..E2FF) and TRAP_REC ($40E7F0).
SCENE_LAST = $40E300
SCENE_SIZE = 1024

CANVAS_BW  = $408000    ; OBJ canvas, packed 4bpp bitmap 128 x 256 (16KB) = image of OBJ VRAM
CANVAS_BMP = $610000    ; SA-1 virtual bitmap view of the canvas (1 byte per pixel)
OBJ_VRAM   = $6000      ; OBJ tiles at VRAM word $6000 (OBSEL base 3)
SKY_TMAX = 351

; sound command queue (SA-1 -> S-CPU), BW-RAM: 64 entries of (command, parameter)
SND_Q      = $407800
SND_QW     = $407880    ; word: write index (SA-1)
SND_QR     = $407882    ; word: read index (S-CPU)
SND_ENGP   = $407884    ; byte: engine tone pitch (arcade PCM delta), 0 = off
SND_ENGV   = $407885    ; byte: engine tone volume (0-127)
SND_TRAFI  = $407886    ; byte: nearest traffic car distance index (0-31, 0 none)
SND_TRAFP  = $407887    ; byte: its pan (0 left - 6 right)
SND_QMASK  = $7E
SQ_PLAY    = 1          ; parameter: song (loads the bank when needed)
SQ_STOP    = 2
SQ_SFX     = 3          ; parameter: effect id (SFX_*)
SQ_SFXOFF  = 4
SQ_MVOL    = 7          ; parameter: main volume

.endif
