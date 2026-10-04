; ---------------------------------------------------------------------------
; OutRun SNES sound driver (SPC700)
;
; Music is played by interpreting the arcade Z80 driver's sequence format
; (converted by tools/mksound.py: pointers relocated, patch / sample ids
; remapped to SNES instruments).  Each arcade channel is a "track".  The 8
; DSP voices are allocated per note by priority (alloc): a track keeps its
; voice while it owns it, else takes a free voice (its home voice first), a
; finished one (released, envelope down), or steals the lowest-priority
; sounding voice below its own priority.  Sound effects are short sequences
; in the same format played on tracks 13-15 (slots); they take a voice at
; their start with a priority above all music and keep it until they end.
; Voice 7 belongs to the engine tone during races; passing traffic gets a
; voice only below the music's priorities.
;
; Tick rate 125 Hz (timer 0, 8 kHz / 64), like the arcade's YM2151 timer A.
;
; S-CPU interface ($2140-$2143 = ports 0-3):
;   port 1 = command, port 2/3 = parameters, port 0 = sequence number
;   (written last).  The driver echoes port 0 when the command is done.
; ---------------------------------------------------------------------------

; ---- hardware ----
CONTROL = $F1
DSPA    = $F2
DSPD    = $F3
PORT0   = $F4
PORT1   = $F5
PORT2   = $F6
PORT3   = $F7
T0DIV   = $FA
T0OUT   = $FD

; ---- memory map ----
NTRK    = 16
NMUS    = 13                ; music tracks 0-12, sfx tracks 13-15
T_FLAGS = $0200             ; bit7 active, bit6 sample track, bit5 sfx track
T_PTRL  = $0210
T_PTRH  = $0220
T_DURL  = $0230
T_DURH  = $0240
T_TEMPO = $0250
T_TRANS = $0260
T_INST  = $0270
T_PAN   = $0280
T_VOLL  = $0290
T_VOLR  = $02A0
T_MARK  = $02B0
T_SP    = $02C0
T_VOICE = $02D0             ; home voice
T_VSC   = $02F0
T_MEM   = $0300             ; 8 bytes per track: loop counters + call stack
T_NOTE  = $0380
T_SFXID = $0390
T_SPRIO = $03A0
V_OWNER = $03B0             ; 8 voices: track, $FE engine, $FD traffic, $FF free
V_PRIO  = $03B8             ; priority of the voice's current use
V_REL   = $03C8             ; 1: the owner released the note (free once quiet)
T_CURV  = $03D0             ; 16 tracks: voice the track owns ($FF none)
T_PRIO  = $03E0             ; 16 tracks: priority of the track's notes
T_MUTE  = $03F0             ; 13 music tracks: bit 7 arcade YM channel 6/7,
                            ; bit 6 channel 7, bit 0 broken envelope (m_end)
DIRPAGE = $10               ; sample directory at $1000
FMI     = $1100             ; FM instruments, 32 x 8
SMI     = $1200             ; sample instruments, 64 x 8 ($1200-$13FF)
SONGH   = $1400             ; song header: count, 13 x 8 bytes
SFXT    = $1480             ; sfx table, 32 x 4 bytes
; FMI entry: +0 srcn +1 adsr1 +2 adsr2 +3 release gain (0 = key off) +4 volume
;            +5 pitch shift (log2(samples per period / 16), bits 0-2) and
;            the patch's L/R bits (6-7: a patch load sets the pan)
;            +6/+7 adsr1/2 with the arcade's broken envelope (see m_end)
; SMI entry: +0 srcn +1 adsr1 (0 = gain $7F) +2 adsr2 +3 release gain +4 volume
;            +5/+6 pitch +7 priority (drum hits)
; song track entry: +0/+1 start +2 tempo +3 transpose +4 flags (bit6 sample,
;            bit 5 arcade YM channel 6 or 7, bit 4 channel 7)
;            +5 home voice +6 priority +7 volume scale (128 = 1.0)
; sfx entry: +0/+1 start +2 slot (0-2) / flags (bit6 sample) +3 priority
; priorities: effects $80 + priority * $10, music $30-$7F (drum hits: SMI
; +7), passing traffic below $30

; ---- direct page ----
ptr     = $00               ; word: sequence read pointer
ip      = $02               ; word: instrument entry pointer
trk     = $04
voice   = $05
vbase   = $06               ; voice * 16
kon     = $07
koff    = $08
aprio   = $09               ; alloc: requested priority
lastseq = $0A
nte     = $0B
oct     = $0C
pl      = $0D               ; word: pitch
tmp     = $0F
tmp2    = $10
sid     = $11
vol     = $12
cmd_p1  = $13
cmd_p2  = $14
npk     = $15               ; word: upload packet count
eng_on  = $17
eng_p   = $18               ; word: engine pitch
eng_v   = $1A
eng_new = $1B
mvol    = $1C
tickcnt = $1D
cnt     = $1E
tr_idx  = $1F               ; traffic: nearest car distance index, pan
tr_pan  = $20
tr_on   = $21
tr_vl   = $22
tr_vr   = $23
tr_p    = $24
tr_div  = $25
tr_v    = $26               ; traffic voice
bestc   = $27               ; alloc: best cost / voice
bestv   = $28

        .org $0400
start:
        clrp
        mov x,#$EF
        mov sp,x
        ; clear direct page and the track/voice arrays
        mov a,#0
        mov x,#0
.clr0:  mov (x)+,a
        cmp x,#$E0
        bne .clr0
        mov x,#0
.clr1:  mov !$0200+x,a
        mov !$0300+x,a
        inc x
        bne .clr1
        mov a,#$FF
        mov x,#15
.clr2:  mov !T_CURV+x,a
        cmp x,#8
        bcs .clr3
        mov !V_OWNER+x,a
.clr3:  dec x
        bpl .clr2
        ; DSP init
        mov DSPA,#$6C
        mov DSPD,#$E0           ; reset, mute, echo writes off
        mov DSPA,#$5C
        mov DSPD,#$FF           ; key off all
        mov x,#0
.dclr:  mov a,x
        and a,#$0F
        cmp a,#$0A
        bcs .dskip
        mov DSPA,x
        mov DSPD,#0             ; voice registers 0-9
.dskip: inc x
        cmp x,#$80
        bne .dclr
        mov DSPA,#$0C
        mov DSPD,#$7F           ; main volume
        mov DSPA,#$1C
        mov DSPD,#$7F
        mov mvol,#$7F
        mov DSPA,#$2C
        mov DSPD,#0             ; echo volume
        mov DSPA,#$3C
        mov DSPD,#0
        mov DSPA,#$0D
        mov DSPD,#0             ; echo feedback
        mov DSPA,#$2D
        mov DSPD,#0             ; pitch modulation off
        mov DSPA,#$3D
        mov DSPD,#0             ; noise off
        mov DSPA,#$4D
        mov DSPD,#0             ; echo off
        mov DSPA,#$5D
        mov DSPD,#DIRPAGE
        mov DSPA,#$6D
        mov DSPD,#$FF           ; echo buffer page (unused)
        mov DSPA,#$7D
        mov DSPD,#0             ; echo delay 0
        mov DSPA,#$5C
        mov DSPD,#0
        mov DSPA,#$6C
        mov DSPD,#$20           ; unmute, echo writes off
        ; timer 0: 8 kHz / 64 = 125 Hz
        mov T0DIV,#64
        mov CONTROL,#$31        ; clear input ports, timer 0 on, IPL ROM off
        mov lastseq,#0
        mov PORT1,#$DC
        mov PORT0,#$5A          ; ready signature
        mov a,T0OUT

main:
        mov a,PORT0
        cmp a,lastseq
        beq .nocmd
        call !do_cmd
.nocmd: mov a,T0OUT
        beq main
        mov tickcnt,a
.tl:    call !tick
        dbnz tickcnt,.tl
        bra main

; ---------------------------------------------------------------------------
; commands
; ---------------------------------------------------------------------------
do_cmd:
        mov lastseq,a
        mov cmd_p1,PORT2
        mov cmd_p2,PORT3
        mov a,PORT1
        cmp a,#9
        bcs cmd_ack
        asl a
        mov x,a
        jmp [!cmdtab+x]
cmd_ack:
        mov PORT0,lastseq
        ret

cmdtab: .word cmd_ack, c_play, c_stop, c_sfx, c_sfxstop, c_engine, c_upload, c_mvol, c_traffic

; ---- 1: start the song in the song area ----
c_play:
        call !music_off
        mov x,#0
        mov a,!SONGH
        mov cnt,a
        beq cmd_ack
        mov y,#0
.tr:    mov trk,x
        mov a,!SONGH+1+y
        mov !T_PTRL+x,a
        mov a,!SONGH+2+y
        mov !T_PTRH+x,a
        mov a,!SONGH+3+y
        mov !T_TEMPO+x,a
        mov a,!SONGH+4+y
        mov !T_TRANS+x,a
        mov a,!SONGH+5+y
        and a,#$40
        or a,#$80
        mov !T_FLAGS+x,a
        mov a,!SONGH+5+y
        asl a
        asl a
        and a,#$C0
        mov !T_MUTE+x,a
        mov a,!SONGH+6+y
        mov !T_VOICE+x,a
        mov a,!SONGH+7+y
        mov !T_PRIO+x,a
        mov a,!SONGH+8+y
        mov !T_VSC+x,a
        call !trk_reset
        mov a,y
        clrc
        adc a,#8
        mov y,a
        mov x,trk
        inc x
        dbnz cnt,.tr
        jmp !cmd_ack

; common track state reset (X = track)
trk_reset:
        mov a,#1
        mov !T_DURL+x,a
        mov a,#0
        mov !T_DURH+x,a
        mov !T_MARK+x,a
        mov !T_INST+x,a
        mov !T_VOLL+x,a
        mov !T_VOLR+x,a
        mov a,#8
        mov !T_SP+x,a
        mov a,#$C0
        mov !T_PAN+x,a
        mov a,#$FF
        mov !T_NOTE+x,a
        mov a,x
        asl a
        asl a
        asl a
        mov x,a
        mov a,#0
        mov !T_MEM+x,a
        mov !T_MEM+1+x,a
        mov !T_MEM+2+x,a
        mov !T_MEM+3+x,a
        mov !T_MEM+4+x,a
        mov !T_MEM+5+x,a
        mov !T_MEM+6+x,a
        mov !T_MEM+7+x,a
        mov x,trk
        ret

; ---- 2: stop music ----
c_stop:
        call !music_off
        jmp !cmd_ack

; stop all music tracks, key off the voices they own
music_off:
        mov x,#0
.m1:    mov a,#0
        mov !T_FLAGS+x,a
        mov a,#$FF
        mov !T_CURV+x,a
        inc x
        cmp x,#NMUS
        bne .m1
        mov x,#7
.m2:    mov a,!V_OWNER+x
        cmp a,#NMUS
        bcs .m3
        mov a,#$FF
        mov !V_OWNER+x,a
        mov a,!BIT+x
        or a,koff
        mov koff,a
.m3:    dec x
        bpl .m2
        ; apply now
        mov DSPA,#$5C
        mov DSPD,koff
        mov koff,#0
        ret

; ---- 3: start sound effect p1 ----
c_sfx:
        mov a,cmd_p1
        call !sfx_start
        jmp !cmd_ack

sfx_start:
        mov sid,a
        asl a
        asl a
        mov y,a
        mov a,!SFXT+2+y         ; slot
        and a,#3
        clrc
        adc a,#NMUS
        mov x,a
        mov trk,x
        ; priority check against a running effect on this slot
        mov a,!T_FLAGS+x
        bpl .free
        mov a,!SFXT+3+y
        cmp a,!T_SPRIO+x
        bcs .free
        ret
.free:  mov a,!SFXT+3+y
        mov !T_SPRIO+x,a
        mov a,sid
        mov !T_SFXID+x,a
        mov a,!SFXT+y
        mov !T_PTRL+x,a
        mov a,!SFXT+1+y
        mov !T_PTRH+x,a
        mov a,!SFXT+2+y
        and a,#$40
        or a,#$A0
        mov !T_FLAGS+x,a
        mov a,#1
        mov !T_TEMPO+x,a
        mov a,#0
        mov !T_TRANS+x,a
        mov a,#128
        mov !T_VSC+x,a
        call !trk_reset
        ; voice: the slot's own if it still has it, else a new one (above
        ; every music priority); the note sounding on it stops
        mov a,!SFXT+3+y
        xcn a
        or a,#$80
        mov !T_PRIO+x,a
        call !route
        bpl .own
        mov a,!T_PRIO+x
        call !alloc
        bpl .own
        mov x,trk               ; no voice: the effect does not play
        mov a,#0
        mov !T_FLAGS+x,a
        ret
.own:   mov y,a
        mov x,trk
        mov a,!T_PRIO+x
        mov !V_PRIO+y,a
        mov a,!BIT+y
        or a,koff
        mov koff,a
        ret

; ---- 4: stop sound effect p1 ($FF: all) ----
c_sfxstop:
        mov x,#NMUS
.s1:    mov a,!T_FLAGS+x
        bpl .s2
        mov a,cmd_p1
        cmp a,#$FF              ; $FF: every effect (arcade FM_RESET /
        beq .s3                 ; NEW_COMMAND: new_command())
        mov a,!T_SFXID+x
        cmp a,cmd_p1
        bne .s2
.s3:    mov trk,x
        call !sfx_end
        mov x,trk
.s2:    inc x
        cmp x,#NTRK
        bne .s1
        mov DSPA,#$5C
        mov DSPD,koff
        mov koff,#0
        jmp !cmd_ack

; end the sfx on track X: key off, release the voice claim
sfx_end:
        mov a,#0
        mov !T_FLAGS+x,a
        call !route
        bmi .x
        mov y,a
        mov a,!BIT+y
        or a,koff
        mov koff,a
        mov a,#$FF
        mov !V_OWNER+y,a
.x:     mov x,trk
        mov a,#$FF
        mov !T_CURV+x,a
        ret

; ---- 5: engine: p1 = pitch (arcade PCM delta), p2 = volume (0-127, 0 = off) ----
c_engine:
        mov eng_p,cmd_p1
        mov eng_v,cmd_p2
        mov eng_new,#1
        jmp !cmd_ack

; ---- 8: traffic: p1 = distance index (0-31, 0 = none), p2 = pan (0-6) ----
c_traffic:
        mov tr_idx,cmd_p1
        mov tr_pan,cmd_p2
        jmp !cmd_ack

; ---- 7: main volume ----
c_mvol:
        mov a,cmd_p1
        mov mvol,a
        mov DSPA,#$0C
        mov DSPD,a
        mov DSPA,#$1C
        mov DSPD,a
        jmp !cmd_ack

; ---- 6: upload ----
; after the ack, packets arrive as (port2, port3) with port0 = previous + 1,
; echoed once both ports are read (the S-CPU writes the next packet while
; the bytes are stored).  Runs of whole pages: header (first page, page
; count), then the count * 128 data packets; page count 0 ends the upload.
c_upload:
        ; the music stops (its data is replaced); effects, engine and traffic
        ; use resident data and keep their voices (their sequences pause)
        call !music_off
        mov PORT0,lastseq       ; ack: ready for packets
        mov x,lastseq
.blk:   inc x
.w1:    cmp x,PORT0
        bne .w1
        mov a,PORT2             ; first page
        mov y,PORT3             ; page count
        mov PORT0,x
        cmp y,#0
        beq .done
        mov !.s1+2,a            ; the stores below write into the page
        mov !.s2+2,a
        mov npk,y
        mov y,#0
.pkt:   inc x
.w3:    cmp x,PORT0
        bne .w3
        mov a,PORT2
.s1:    mov !$0000+y,a
        inc y
        mov a,PORT3
        mov PORT0,x
.s2:    mov !$0000+y,a
        inc y
        bne .pkt
        inc !.s1+2              ; next page
        inc !.s2+2
        dbnz npk,.pkt
        bra .blk
.done:  mov lastseq,x
        mov a,T0OUT             ; drop the ticks missed while loading
        ret

; ---------------------------------------------------------------------------
; tick: sequence all tracks, update voices
; ---------------------------------------------------------------------------
tick:
        mov kon,#0
        mov x,#0
.t:     mov a,!T_FLAGS+x
        bpl .n
        mov trk,x
        call !track_tick
        mov x,trk
.n:     inc x
        cmp x,#NTRK
        bne .t
        call !engine_tick
        call !traffic_tick
        ; key off / key on
        mov a,kon
        eor a,#$FF
        and a,koff
        mov DSPA,#$5C
        mov DSPD,a
        mov koff,#0
        mov DSPA,#$4C
        mov DSPD,kon
        mov kon,#0              ; (commands between ticks: nothing keyed on)
        ret

; ---------------------------------------------------------------------------
; one track (X = trk)
; ---------------------------------------------------------------------------
track_tick:
        mov a,!T_DURL+x
        bne .nb
        mov a,!T_DURH+x
        dec a
        mov !T_DURH+x,a
        mov a,#0
.nb:    dec a
        mov !T_DURL+x,a
        or a,!T_DURH+x
        beq .exp
        ret
.exp:   mov a,!T_PTRL+x
        mov ptr,a
        mov a,!T_PTRH+x
        mov ptr+1,a
seq_next:
        call !getb
        cmp a,#$80
        bcs seq_cmd
        ; note or rest
        mov x,trk
        mov tmp,a
        mov a,!T_FLAGS+x
        and a,#$40
        bne seq_dur             ; sample tracks: plain wait
        mov a,tmp
        beq .rest
        dec a
        clrc
        adc a,!T_TRANS+x
        mov !T_NOTE+x,a
        call !fm_keyon
        bra seq_dur
.rest:  mov a,#$FF
        mov !T_NOTE+x,a
        call !fm_release
seq_dur:
        mov x,trk
        call !read_dur
        mov a,ptr
        mov !T_PTRL+x,a
        mov a,ptr+1
        mov !T_PTRH+x,a
        ret
seq_cmd:
        cmp a,#$BF
        bcs .smp
        and a,#$3F
        asl a
        mov x,a
        jmp [!mmltab+x]
.smp:   setc
        sbc a,#$C0
        bcc seq_dur             ; $BF: rest
        call !smp_keyon
        bra seq_dur

getb:   mov y,#0
        mov a,[ptr]+y
        incw ptr
        or a,#0
        ret

; duration: byte * tempo, or raw (fixed tempo), 16-bit when 'long' is pending
read_dur:
        call !getb
        mov tmp,a
        mov a,!T_MARK+x
        and a,#2
        beq .tempo
        mov a,!T_MARK+x
        and a,#1
        beq .fix8
        mov a,!T_MARK+x
        and a,#$FE
        mov !T_MARK+x,a
        call !getb
        mov !T_DURH+x,a
        mov a,tmp
        mov !T_DURL+x,a
        ret
.fix8:  mov a,tmp
        mov !T_DURL+x,a
        mov a,#0
        mov !T_DURH+x,a
        ret
.tempo: mov a,!T_TEMPO+x
        mov y,a
        mov a,tmp
        mul ya
        mov !T_DURL+x,a
        mov a,y
        mov !T_DURH+x,a
        ret

; ---- MML command handlers (enter with X garbage; trk valid) ----
mmltab:
        .word m_skip1, m_skip1, m_level, m_skip1, m_end, m_skip1, m_skip1, m_skip1
        .word m_call, m_ret, m_jump, m_trans, m_loop, m_skip1, m_none, m_skip1
        .word m_skip1, m_patch, m_skip1, m_skip1, m_fixed, m_long, m_right, m_left
        .word m_both, m_end, m_skip1, m_skip1, m_skip1, m_skip1, m_skip1, m_skip1
        .word m_skip1, m_skip1, m_skip1, m_skip1, m_skip1, m_skip1, m_skip1, m_skip1
        .word m_skip1, m_skip1, m_skip1, m_skip1, m_skip1, m_skip1, m_skip1, m_skip1
        .word m_skip1, m_skip1, m_skip1, m_skip1, m_skip1, m_skip1, m_skip1, m_skip1
        .word m_skip1, m_skip1, m_skip1, m_skip1, m_skip1, m_skip1, m_skip1, m_skip1

m_skip1:
        call !getb
m_none:
        jmp !seq_next

m_level:
        mov x,trk
        call !getb
        mov tmp,a
        mov a,!T_FLAGS+x
        and a,#$40
        bne .pcm
        mov a,tmp
        mov !T_MARK+x,a
        jmp !seq_next
.pcm:   mov a,tmp
        cmp a,#$41
        bcc .l1
        mov a,#0
.l1:    mov !T_VOLL+x,a
        call !getb
        cmp a,#$41
        bcc .l2
        mov a,#0
.l2:    mov !T_VOLR+x,a
        jmp !seq_next

m_end:
        mov x,trk
        mov a,!T_FLAGS+x
        and a,#$20
        beq .mus
        ; an effect ends.  The arcade's end-of-track routine also writes the
        ; YM release block (D1L 15, RR 15) to hardware channel (flags & 7):
        ; for a PCM effect (channels $46/$47) YM channels 6 and 7, whose
        ; notes then decay at the patch's D1R and stop at once, until the
        ; channel loads a patch again (FMI +6/+7: that envelope); an FM effect
        ; (on channel 7) gives channel 7 back its patch.
        mov a,trk
        push a                  ; (the effect's track)
        mov a,!T_FLAGS+x
        and a,#$40
        beq .fm
        mov x,#NMUS-1
.p1:    mov a,!T_MUTE+x
        bpl .p2
        or a,#$01
        mov !T_MUTE+x,a
        mov trk,x               ; a sounding note gets the envelope too
        call !route
        bmi .p2
        mov y,a
        mov a,!V_REL+y
        bne .p2
        mov a,y
        call !setvoice
        call !inst_ip
        call !adsr_brk
        mov x,trk
.p2:    dec x
        bpl .p1
        bra .fx
.fm:    mov x,#NMUS-1
.f1:    mov a,!T_MUTE+x
        and a,#$40
        beq .f2
        mov a,!T_MUTE+x
        and a,#$FE
        mov !T_MUTE+x,a
.f2:    dec x
        bpl .f1
.fx:    pop a
        mov trk,a
        mov x,a
        jmp !sfx_end
.mus:   call !fm_release
        mov x,trk
        mov a,#0
        mov !T_FLAGS+x,a
        ret

m_call:
        call !getb
        mov tmp,a
        call !getb
        mov tmp2,a
        mov a,trk
        asl a
        asl a
        asl a
        mov x,trk
        clrc
        adc a,!T_SP+x
        mov x,a
        dec x
        mov a,ptr+1
        mov !T_MEM+x,a
        dec x
        mov a,ptr
        mov !T_MEM+x,a
        mov x,trk
        mov a,!T_SP+x
        setc
        sbc a,#2
        and a,#7
        mov !T_SP+x,a
        mov ptr,tmp
        mov ptr+1,tmp2
        jmp !seq_next

m_ret:
        mov a,trk
        asl a
        asl a
        asl a
        mov x,trk
        clrc
        adc a,!T_SP+x
        mov x,a
        mov a,!T_MEM+x
        mov ptr,a
        mov a,!T_MEM+1+x
        mov ptr+1,a
        mov x,trk
        mov a,!T_SP+x
        clrc
        adc a,#2
        mov !T_SP+x,a
        jmp !seq_next

m_jump:
        call !getb
        mov tmp,a
        call !getb
        mov ptr+1,a
        mov ptr,tmp
        jmp !seq_next

m_trans:
        call !getb
        mov x,trk
        clrc
        adc a,!T_TRANS+x
        mov !T_TRANS+x,a
        jmp !seq_next

m_loop:
        call !getb              ; counter number
        and a,#7
        mov tmp,a
        mov a,trk
        asl a
        asl a
        asl a
        clrc
        adc a,tmp
        mov x,a
        call !getb              ; count
        mov tmp,a
        mov a,!T_MEM+x
        bne .run
        mov a,tmp
.run:   dec a
        mov !T_MEM+x,a
        beq .fall
        call !getb
        mov tmp,a
        call !getb
        mov ptr+1,a
        mov ptr,tmp
        jmp !seq_next
.fall:  incw ptr
        incw ptr
        jmp !seq_next

m_patch:
        call !getb
        beq .p0
        mov x,trk
        mov !T_INST+x,a
        mov a,!T_MUTE+x         ; (a patch written: channel 6/7 sound again)
        and a,#$FE
        mov !T_MUTE+x,a
        call !inst_ip           ; the patch's L/R bits
        mov y,#5
        mov a,[ip]+y
        and a,#$C0
        mov x,trk
        mov !T_PAN+x,a
.p0:    jmp !seq_next

m_fixed:
        mov x,trk
        mov a,!T_MARK+x
        or a,#2
        mov !T_MARK+x,a
        jmp !seq_next

m_long:
        mov x,trk
        mov a,!T_MARK+x
        or a,#1
        mov !T_MARK+x,a
        jmp !seq_next

m_right:
        mov a,#$80
        bra m_pan
m_left: mov a,#$40
        bra m_pan
m_both: mov a,#$C0
m_pan:  mov x,trk
        mov !T_PAN+x,a
        jmp !seq_next

; ---------------------------------------------------------------------------
; route: X = track -> A = the voice it owns (N set if none); X kept
; ---------------------------------------------------------------------------
route:
        mov a,!T_CURV+x
        bmi .none
        mov y,a
        mov a,!V_OWNER+y
        cmp a,trk
        bne .none
        mov a,y
        ret
.none:  mov a,#$FF
        ret

; ---------------------------------------------------------------------------
; alloc: a voice for trk (track 0-15, or $FD traffic) at priority A
; -> A = voice (N set if none).  The voice is claimed (V_OWNER, V_PRIO,
; V_REL, T_CURV); a track or the traffic losing it forgets it.  Pool:
; voices 0-6, and 7 for music while the engine is off.  Cost (lowest wins):
; free 2, released and quiet (ENVX < 8) 4, one less on the track's home
; voice; the track's own sounding voice $7F; another sounding voice of a
; lower priority $80 + priority / 2.  Voices keyed on this tick are skipped.
; X, Y destroyed.
; ---------------------------------------------------------------------------
alloc:
        mov aprio,a
        mov bestc,#$FF
        mov bestv,#$FF
        mov x,#7
        mov a,eng_on
        bne .no7
        mov a,trk
        cmp a,#NMUS
        bcc .lp
.no7:   mov x,#6
.lp:    mov a,!BIT+x
        and a,kon
        bne .next               ; keyed on this tick
        mov a,!V_OWNER+x
        cmp a,#$FF
        bne .own
        mov a,#2                ; free
        bra .home
.own:   cmp a,#$FE
        beq .next               ; engine
        mov a,!V_REL+x
        beq .act
        mov a,x
        xcn a
        or a,#8
        mov DSPA,a
        mov a,DSPD              ; ENVX
        cmp a,#8
        bcs .act
        mov a,#4                ; released and quiet
.home:  mov tmp,a
        mov a,trk
        cmp a,#NTRK
        bcs .cost
        mov y,a
        mov a,!T_VOICE+y
        mov tmp2,a
        cmp x,tmp2
        bne .cost
        dec tmp
        bra .cost
.act:   mov a,!V_OWNER+x
        cmp a,trk
        bne .act2
        mov a,#$7F              ; the track's own (sounding) voice
        bra .act3
.act2:  mov a,!V_PRIO+x
        cmp a,aprio
        bcs .next               ; not below our priority
        lsr a
        or a,#$80
.act3:  mov tmp,a
.cost:  mov a,tmp
        cmp a,bestc
        bcs .next
        mov bestc,a
        mov bestv,x
.next:  dec x
        bpl .lp
        mov a,bestv
        bmi .ret                ; none: A = $FF
        mov x,a
        mov a,!V_OWNER+x
        cmp a,#NTRK
        bcs .clm
        mov y,a                 ; a track loses the voice
        mov a,#$FF
        mov !T_CURV+y,a
.clm:   mov a,!V_OWNER+x
        cmp a,#$FD
        bne .clm2
        mov tr_on,#0            ; the traffic loses it
.clm2:  mov a,trk
        mov !V_OWNER+x,a
        mov a,aprio
        mov !V_PRIO+x,a
        mov a,#0
        mov !V_REL+x,a
        mov a,trk
        cmp a,#NTRK
        bcs .clm3
        mov y,a
        mov a,x
        mov !T_CURV+y,a
.clm3:  mov a,x
.ret:   ret

setvoice:                       ; A = voice
        mov voice,a
        xcn a
        mov vbase,a
        ret

; ---------------------------------------------------------------------------
; FM note on: X = track, T_NOTE = note index
; ---------------------------------------------------------------------------
fm_keyon:
        mov a,!T_INST+x
        beq .ret
        call !route
        bpl .go
        mov a,trk
        cmp a,#NMUS
        bcs .ret                ; an effect without its voice
        mov a,!T_PRIO+x
        call !alloc
        bpl .go
.ret:   ret
.go:    call !setvoice
        mov x,trk
        mov a,!T_INST+x
        asl a
        asl a
        asl a
        mov ip,a
        mov ip+1,#>FMI
        mov a,!T_NOTE+x
        mov nte,a
        ; pitch = PTAB[n % 12] shifted by (pitch shift + n / 12 - 9)
        mov y,#0
        mov x,#12
        div ya,x
        mov oct,a
        mov a,y
        asl a
        mov y,a
        mov a,!PTAB+y
        mov pl,a
        mov a,!PTAB+1+y
        mov pl+1,a
        mov y,#5
        mov a,[ip]+y
        and a,#7
        clrc
        adc a,oct
        setc
        sbc a,#9
        beq .pw
        bmi .rs
.ls:    asl pl
        rol pl+1
        dec a
        bne .ls
        bra .pw
.rs:    lsr pl+1
        ror pl
        inc a
        bne .rs
.pw:    mov a,pl+1
        cmp a,#$40
        bcc .pok
        mov pl,#$FF
        mov pl+1,#$3F
.pok:   mov x,trk
        call !voice_common
        mov a,!T_MUTE+x
        lsr a
        bcc .vok
        call !adsr_brk          ; YM channel 6/7 after a PCM effect (m_end)
        mov x,trk
.vok:
        ; volume = inst vol * track scale >> 7, then pan
        mov y,#4
        mov a,[ip]+y
        mov y,a
        mov a,!T_VSC+x
        mul ya
        asl a
        mov a,y
        rol a
        bpl .v1
        mov a,#$7F
.v1:    mov vol,a
        mov a,!T_PAN+x
        mov tmp,a
        mov a,#0
        bbc tmp.6,.nl
        mov a,vol
.nl:    call !wvoll
        mov a,#0
        bbc tmp.7,.nr
        mov a,vol
.nr:    call !wvolr
        jmp !keyon_voice

wvoll:  push a
        mov a,vbase
        mov DSPA,a
        pop a
        mov DSPD,a
        ret
wvolr:  push a
        mov a,vbase
        or a,#1
        mov DSPA,a
        pop a
        mov DSPD,a
        ret

; srcn, envelope and pitch (pl) for the voice from [ip]
voice_common:
        mov a,vbase
        or a,#4
        mov DSPA,a
        mov y,#0
        mov a,[ip]+y
        mov DSPD,a              ; SRCN
        mov a,vbase
        or a,#5
        mov DSPA,a
        mov y,#1
        mov a,[ip]+y
        bne .adsr
        mov DSPD,#0             ; ADSR off: fixed gain
        mov a,vbase
        or a,#7
        mov DSPA,a
        mov DSPD,#$7F
        bra .pitch
.adsr:  or a,#$80
        mov DSPD,a
        mov a,vbase
        or a,#6
        mov DSPA,a
        mov y,#2
        mov a,[ip]+y
        mov DSPD,a
.pitch: mov a,vbase
        or a,#2
        mov DSPA,a
        mov DSPD,pl
        mov a,vbase
        or a,#3
        mov DSPA,a
        mov DSPD,pl+1
        ret

keyon_voice:
        mov y,voice
        mov a,!BIT+y
        or a,kon
        mov kon,a
        mov a,!BIT+y
        eor a,#$FF
        and a,koff
        mov koff,a
        mov a,trk
        mov !V_OWNER+y,a
        mov a,#0
        mov !V_REL+y,a
        ret

; ip = FMI entry of track trk's instrument
inst_ip:
        mov x,trk
        mov a,!T_INST+x
        asl a
        asl a
        asl a
        mov ip,a
        mov ip+1,#>FMI
        ret

; ADSR of the broken envelope (FMI +6/+7, [ip]) on the voice (vbase)
adsr_brk:
        mov a,vbase
        or a,#6
        mov DSPA,a
        mov y,#7
        mov a,[ip]+y
        mov DSPD,a
        mov a,vbase
        or a,#5
        mov DSPA,a
        mov y,#6
        mov a,[ip]+y
        or a,#$80
        mov DSPD,a
        ret

; ---------------------------------------------------------------------------
; FM note off: release the voice if this track owns it
; ---------------------------------------------------------------------------
fm_release:
        call !route
        bmi .x
        mov y,a
        call !setvoice
        mov a,#1
        mov !V_REL+y,a          ; free again once quiet
        mov a,!T_MUTE+x
        lsr a
        bcs .koff               ; (broken envelope: RR 15)
        mov a,!T_INST+x
        beq .koff
        asl a
        asl a
        asl a
        mov ip,a
        mov ip+1,#>FMI
        mov y,#3
        mov a,[ip]+y
        beq .koff
        mov tmp,a
        mov a,vbase
        or a,#7
        mov DSPA,a
        mov DSPD,tmp            ; exponential decrease (set before leaving ADSR)
        mov a,vbase
        or a,#5
        mov DSPA,a
        mov DSPD,#0             ; ADSR off -> gain mode
        ret
.koff:  mov y,voice
        mov a,!BIT+y
        or a,koff
        mov koff,a
.x:     ret

; ---------------------------------------------------------------------------
; sample on (drums / pcm effects): A = sample instrument id, X = track
; ---------------------------------------------------------------------------
smp_keyon:
        mov sid,a
        ; ip = SMI + id * 8
        mov y,#8
        mul ya
        clrc
        adc a,#<SMI
        mov ip,a
        mov a,y
        adc a,#>SMI
        mov ip+1,a
        mov x,trk
        mov a,trk
        cmp a,#NMUS
        bcc .mus
        call !route             ; an effect: its own voice
        bpl .go
        ret
.mus:   mov y,#7
        mov a,[ip]+y            ; drum hit priority
        call !alloc
        bpl .go
        ret
.go:    call !setvoice
        mov y,#5
        mov a,[ip]+y
        mov pl,a
        mov y,#6
        mov a,[ip]+y
        mov pl+1,a
        call !voice_common
        ; volume: track level (0-$40) * instrument volume >> 6
        mov y,#4
        mov a,[ip]+y
        mov vol,a
        mov x,trk
        mov a,!T_VOLL+x
        call !scalevol
        call !wvoll
        mov a,!T_VOLR+x
        call !scalevol
        call !wvolr
        call !keyon_voice
        mov a,trk
        cmp a,#NMUS
        bcs .x
        mov y,voice             ; a drum hit: free again once it has ended
        mov a,#1
        mov !V_REL+y,a
.x:     ret

scalevol:                       ; A = level 0-$40 -> A = level * vol >> 6
        mov y,vol
        mul ya
        mov tmp,y
        asl a
        rol tmp
        asl a
        rol tmp
        mov a,tmp
        bpl .ok
        mov a,#$7F
.ok:    ret

; ---------------------------------------------------------------------------
; engine tone on voice 7 (claimed while volume and pitch are non-zero)
; ---------------------------------------------------------------------------
ENG_SRCN = 32
engine_tick:
        mov a,eng_new
        beq .x
        mov eng_new,#0
        mov a,eng_v
        beq .off
        mov a,eng_p
        bne .on
.off:   mov a,eng_on
        beq .x
        mov eng_on,#0
        set1 koff.7
        mov a,#$FF
        mov !V_OWNER+7,a
.x:     ret
.on:    mov vbase,#$70
        mov a,eng_on
        bne .upd
        ; start: take voice 7 (a track playing on it loses it)
        mov a,!V_OWNER+7
        cmp a,#NTRK
        bcs .take
        mov y,a
        mov a,#$FF
        mov !T_CURV+y,a
.take:  mov a,#$FE
        mov !V_OWNER+7,a
        mov DSPA,#$74
        mov DSPD,#ENG_SRCN
        mov DSPA,#$75
        mov DSPD,#0
        mov DSPA,#$77
        mov DSPD,#$7F
        set1 kon.7
        clr1 koff.7
        mov eng_on,#1
.upd:   ; pitch = delta * 16 (the engine sample is stored at the arcade rate / 1.024)
        mov a,eng_p
        mov y,#16
        mul ya
        mov DSPA,#$72
        mov DSPD,a
        mov DSPA,#$73
        mov DSPD,y
        mov a,eng_v
        lsr a
        mov DSPA,#$70
        mov DSPD,a
        mov DSPA,#$71
        mov DSPD,a
        ret

; ---------------------------------------------------------------------------
; passing traffic (the engine sample), every other tick like the arcade, on
; a voice allocated below the music's priorities (louder = higher)
; ---------------------------------------------------------------------------
traffic_tick:
        inc tr_div
        mov a,tr_div
        and a,#1
        beq .go
        ret
.go:    mov a,tr_idx
        bne .near
        jmp !.pass
.near:  mov y,a
        mov a,!TRV+y            ; volume multiplier for the distance
        mov tmp,a
        mov a,tr_on
        beq .st0
        mov y,tr_v
        mov a,!V_OWNER+y
        cmp a,#$FD
        beq .vol
        mov tr_on,#0            ; taken by the music: start again
.st0:   mov a,tmp
        cmp a,#$10
        bcs .start
        ret                     ; too far away to start
.start: mov trk,#$FD
        mov a,tmp
        lsr a
        lsr a
        clrc
        adc a,#$10
        call !alloc
        bpl .got
        ret                     ; no voice
.got:   mov tr_v,a
        xcn a
        mov vbase,a
        or a,#4
        mov DSPA,a
        mov DSPD,#ENG_SRCN
        mov a,vbase
        or a,#5
        mov DSPA,a
        mov DSPD,#0
        mov a,vbase
        or a,#7
        mov DSPA,a
        mov DSPD,#$7F
        mov y,tr_v
        mov a,!BIT+y
        or a,kon
        mov kon,a
        mov a,!BIT+y
        eor a,#$FF
        and a,koff
        mov koff,a
        mov tr_on,#1
        mov y,tr_idx
        mov a,!TRV+y            ; (alloc used tmp)
        mov tmp,a
.vol:   mov y,tr_pan
        mov a,!TRPL+y
        mov y,tmp
        mul ya
        call !shr5
        mov tr_vl,a
        mov y,tr_pan
        mov a,!TRPR+y
        mov y,tmp
        mul ya
        call !shr5
        mov tr_vr,a
        ; pitch rises for the closest cars
        mov a,tr_idx
        setc
        sbc a,#$16
        bcc .p0
        mov y,a
        mov a,!TRP+y
        bra .p1
.p0:    mov a,#0
.p1:    clrc
        adc a,#$70
        mov tr_p,a
        bra .write
.pass:  ; the car went by: pitch falls and the volume fades, then key off
        mov a,tr_on
        beq .x
        mov y,tr_v
        mov a,!V_OWNER+y
        cmp a,#$FD
        beq .pas2
        mov tr_on,#0            ; taken by the music
        ret
.pas2:
        mov a,tr_p
        setc
        sbc a,#4
        mov tr_p,a
        mov a,tr_vl
        beq .l0
        dec tr_vl
.l0:    mov a,tr_vr
        beq .r0
        dec tr_vr
.r0:    mov a,tr_vl
        or a,tr_vr
        bne .write
        mov y,tr_v
        mov a,!BIT+y
        or a,koff
        mov koff,a
        mov a,#$FF
        mov !V_OWNER+y,a
        mov tr_on,#0
        ret
.write: mov a,tr_v
        xcn a
        mov vbase,a
        mov DSPA,a
        mov DSPD,tr_vl
        or a,#1
        mov DSPA,a
        mov DSPD,tr_vr
        mov a,tr_p
        mov y,#16
        mul ya
        mov tmp2,y
        mov y,a
        mov a,vbase
        or a,#2
        mov DSPA,a
        mov DSPD,y
        or a,#1
        mov DSPA,a
        mov DSPD,tmp2
.x:     ret

shr5:   ; YA >> 5 -> A (small values)
        mov tmp2,y
        lsr tmp2
        ror a
        lsr tmp2
        ror a
        lsr tmp2
        ror a
        lsr tmp2
        ror a
        lsr tmp2
        ror a
        ret

TRPL:   .byte 16, 16, 16, 16, 13, 8, 0
TRPR:   .byte 0, 8, 13, 16, 16, 16, 16
TRP:    .byte 0, 2, 4, 4, 0, $F8, $F8, $F8, $F8, $F8
BIT:    .byte $01, $02, $04, $08, $10, $20, $40, $80
; pitch for notes 84-95 (octave 7) at 16 samples per period, x4
PTAB:   .word PT0, PT1, PT2, PT3, PT4, PT5, PT6, PT7, PT8, PT9, PT10, PT11
end_of_driver:
