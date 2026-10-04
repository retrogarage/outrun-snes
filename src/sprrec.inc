; Sprite entry record (osprites.s -> sprv3.s), W3a fusion.
;
; Render builds: do_sprite does not build the arcade hardware sprite list;
; per hardware index i (dst_index) it writes a 16-byte record at
; sprite_entries + i * 16 with do_sprite's own values in the form sprv3's
; CandGeom uses them (no arcade word packing / unpacking, no hw_src, no
; pitch / priority words), and hw_ent / hw_pal as before.  A hidden entry
; gets RR_D0 = $4000 only.
; LOCKSTEP builds (and SPRCHECK) build the exact arcade list (HWLIST):
; lockstep compares it.  SPRCHECK builds (-D SPRCHECK, a render build) draw
; from the arcade list and also build every record, comparing CandGeom's
; results from both for each entry as it is written (SprChkEnt, sprv3.s).
RR_D0  = 0          ; data[0]: y + 256 (9 bits) | bank bits; hide bits $5000
RR_SRC = 2          ; frame descriptor address (rom0) bits 0-15
RR_FL  = 4          ; object (hw_ent) | address bits 16-17 << 8 | flags:
RR_RTL = $0400      ;   right to left (data[4] bit 13 clear)
RR_HWS = $0800      ;   hw shadow bit (data[3] bit 14: shadow value bit 2)
RR_MIR = $4000      ;   mirrored: h-flip (data[4] bits 14 / 13 differ)
RR_VZ  = 6          ; hw zoom (data[4] & $3FF)
RR_X   = 8          ; data[6]: x + 352 (+ width right to left)
RR_H   = 10         ; height byte (data[5] >> 8; bits 8-15 not used)
RR_D1  = 12         ; data[1] (source offset): only when data[0] y = $100
.ifndef NOHWLIST     ; (NOHWLIST: test builds, lockstep logic with the records)
.if .defined(LOCKSTEP) .or .defined(SPRCHECK)
HWLIST = 1          ; the arcade hardware sprite list is built
.endif
.endif
