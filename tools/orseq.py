"""OutRun Z80 music sequencer model (after cannonball's osound.cpp port).

Simulates the arcade driver's channels tick by tick (125 Hz) and reports
musical events.  Every sequence byte read is traced with its role so the
data can be relocated / remapped for the SNES driver."""
import os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
from orroms import _rd
Z = _rd('epr-10187.88')

def r8(a): return Z[a & 0xFFFF] if (a & 0xFFFF) < len(Z) else 0
def r16(a): return r8(a) | (r8(a + 1) << 8)

SONGS = {0x81: 0x0E26, 0x82: 0x20C8, 0x85: 0x3D5F, 0xA5: 0x5F2D}
SONG_NAMES = {0x81: 'breeze', 0x82: 'splash', 0x85: 'magical', 0xA5: 'lastwave'}
SFX_HDR = {0x84: 0x6A24, 0x86: 0x6A60, 0x94: 0x6A87, 0x95: 0x6AA7, 0x99: 0x6AC7,
           0xA0: 0x69A9, 0x8A: 0x69E6, 0x8F: 0x6C15, 0x90: 0x6CFF, 0x92: 0x6C8A,
           0x96: 0x6D61, 0x8D: 0x6F16, 0x9C: 0x6F53, 0x9D: 0x6F91, 0x9E: 0x6FCA,
           0x9F: 0x7003, 0xA4: 0x748B}
NOTE_TAB = 0x0AC9
PCM_INFO = 0x0DDD
# Rev B has fifteen 25-byte Z80 percussion handlers. Read their immediate
# operands; no sample descriptors, musical sequences or patches ship here.
PERC = [(r16(a + 1), r8(a + 12), r8(a + 16), r8(a + 20))
        for a in range(0x5B5, 0x5B5 + 15 * 25, 25)]

def pcm_info(idx):
    """SFX sample (0xD0 + idx): start, end hi, flags"""
    a = PCM_INFO + 4 * idx
    return r16(a), r8(a + 2), r8(a + 3)

def header(cmd):
    return SONGS.get(cmd) or SFX_HDR[cmd]

def song_tables(cmd):
    hdr = header(cmd)
    return r16(hdr), r16(hdr + 4), r16(hdr + 6)   # channel list, mod tables, patches

def patch_block(cmd, block):
    """register/value pairs of FM patch `block` (1-based)"""
    a = r16(song_tables(cmd)[2] + (block - 1) * 2)
    out = []
    while True:
        c = r8(a)
        if c == 2: return out
        if c == 3: a = r16(a + 1); continue
        out.append((c, r8(a + 1))); a += 2

class Chan:
    pass

class Song:
    """Simulate a song / effect.  events: list of (tick, chan, kind, args...);
    trace: {addr: set of (chan, role)}"""
    def __init__(self, cmd):
        self.cmd = cmd
        self.events = []
        self.unknown = {}
        self.trace = {}
        lst, _, _ = song_tables(cmd)
        n = r8(lst)
        self.ch = []
        for i in range(n):
            a = r16(lst + 1 + 2 * i)
            c = Chan()
            c.idx = i
            c.flags = r8(a); c.fmflags = r8(a + 1); c.tempo = r8(a + 2)
            c.seq_pos = r16(a + 3); c.seq_end = r16(a + 5); c.cmdp = r16(a + 7)
            c.start = c.cmdp
            c.transpose = r8(a + 9); c.sp = r8(a + 10); c.modtbl = r8(a + 11)
            c.block = r8(a + 12); c.marker = r8(a + 13)
            c.mem = [0] * 0x20
            c.note = 0; c.vol = (0, 0); c.pitch = 0; c.semi = 0; c.dur = 0
            c.pcm = bool(c.fmflags & 0x40)
            c.pan = 0xC0
            c.note_new = False
            c.loop_forever = []
            self.ch.append(c)
        self.pcm_flags = [1] * 6
        self.tick_no = 0

    def ev(self, c, kind, *args):
        self.events.append((self.tick_no, c.idx, kind) + args)

    def rd(self, c, role):
        a = self.pos & 0xFFFF
        self.trace.setdefault(a, set()).add((c.idx, role))
        self.pos += 1
        return r8(a)

    def tick(self):
        for c in self.ch:
            if c.flags & 0x80:
                self.process_channel(c)
        self.tick_no += 1

    def process_channel(self, c):
        c.seq_pos = (c.seq_pos + 1) & 0xFFFF
        if c.seq_pos == c.seq_end:
            self.pos = c.cmdp
            c.note_new = False
            self.section(c)
            if not (c.flags & 0x80) or c.pcm:
                return
            if c.note_new:
                if c.note == 0xFF:
                    self.ev(c, 'off')
                else:
                    self.ev(c, 'on', c.note, c.modtbl, c.block, c.pan, c.dur, c.semi)

    def section(self, c):
        while True:
            cmd = self.rd(c, 'op')
            if cmd >= 0x80:
                if cmd >= 0xBF:
                    self.trace[(self.pos - 1) & 0xFFFF].discard((c.idx, 'op'))
                    self.trace[(self.pos - 1) & 0xFFFF].add((c.idx, 'smp'))
                    self.play_pcm(c, cmd)
                    return
                op = cmd & 0x3F
                if op == 0x02:          # SAMPLE_LEVEL
                    if c.pcm:
                        vl = self.rd(c, 'par'); vr = self.rd(c, 'par')
                        c.vol = (0 if vl > 0x40 else vl, 0 if vr > 0x40 else vr)
                    else:
                        c.marker = self.rd(c, 'par')
                elif op == 0x04 or op == 0x19:   # END
                    c.flags = 0; self.ev(c, 'end'); return
                elif op == 0x07:
                    c.modtbl = self.rd(c, 'par')
                elif op == 0x08:        # CALL
                    lo = self.rd(c, 'plo'); hi = self.rd(c, 'phi')
                    ret = self.pos
                    c.sp -= 2
                    c.mem[c.sp] = ret & 0xFF; c.mem[c.sp + 1] = ret >> 8
                    self.pos = lo | hi << 8
                elif op == 0x09:        # RET
                    self.pos = c.mem[c.sp] | (c.mem[c.sp + 1] << 8); c.sp += 2
                elif op == 0x0A:        # LOOP_FOREVER
                    lo = self.rd(c, 'plo'); hi = self.rd(c, 'phi')
                    c.loop_forever.append((self.tick_no, lo | hi << 8))
                    self.pos = lo | hi << 8
                elif op == 0x0B:
                    c.transpose = (c.transpose + self.rd(c, 'par')) & 0xFF
                elif op == 0x0C:        # LOOP n, count, adr
                    off = (self.rd(c, 'par') + 0x18) & 0x1F
                    cnt = self.rd(c, 'par')
                    if c.mem[off] == 0:
                        c.mem[off] = cnt
                    c.mem[off] = v = (c.mem[off] - 1) & 0xFF
                    if v != 0:
                        lo = self.rd(c, 'plo'); hi = self.rd(c, 'phi')
                        self.pos = lo | hi << 8
                    else:
                        self.trace.setdefault(self.pos & 0xFFFF, set()).add((c.idx, 'plo'))
                        self.trace.setdefault((self.pos + 1) & 0xFFFF, set()).add((c.idx, 'phi'))
                        self.pos += 2
                elif op == 0x0E:
                    c.flags &= ~0x20
                elif op == 0x11:        # LOAD_PATCH
                    c.block = self.rd(c, 'patch')
                    if c.block: self.ev(c, 'patch', c.block)
                elif op == 0x13:
                    p = self.rd(c, 'par')
                    if c.pcm: c.pitch = p
                elif op == 0x14:
                    c.marker |= 2
                elif op == 0x15:
                    c.marker |= 1
                elif op in (0x16, 0x17, 0x18):
                    c.pan = {0x16: 0x80, 0x17: 0x40, 0x18: 0xC0}[op]
                    self.ev(c, 'pan', c.pan)
                else:
                    self.unknown[cmd] = self.unknown.get(cmd, 0) + 1
                    self.rd(c, 'par')
                continue
            # note / rest
            c.note_new = True
            if cmd:
                tr = c.transpose if c.transpose < 0x80 else c.transpose - 256
                c.semi = cmd - 1 + tr
                c.note = r8(NOTE_TAB + (c.semi & 0xFFFF))
            elif not c.pcm:
                c.note = 0xFF
            self.end_marker(c)
            return

    def end_marker(self, c):
        m = self.rd(c, 'dur')
        if c.marker & 2:
            if c.marker & 1:
                c.marker &= ~1
                m += self.rd(c, 'dur') << 8
        else:
            m = (c.tempo * m) & 0xFFFF
        c.seq_end = m
        c.cmdp = self.pos
        c.seq_pos = 0
        c.dur = m

    def play_pcm(self, c, cmd):
        if cmd >= 0xD0:
            self.ev(c, 'sfx', cmd - 0xD0, c.vol, c.pitch)
        else:
            e = PERC[cmd - 0xC0]
            flags = e[3]
            hw = None
            if flags & 4:
                for i in range(6):
                    f = self.pcm_flags[i]
                    if (f & 0x84) == 0x84 and not (f & 1):
                        hw = i; break
            if hw is None:
                for i in range(6):
                    if self.pcm_flags[i] & 1:
                        hw = i; break
            if hw is None:
                for i in range(6):
                    if self.pcm_flags[i] & 0x80:
                        hw = i; break
            if hw is not None:
                self.pcm_flags[hw] = flags
            self.ev(c, 'drum', cmd - 0xC0, c.vol, hw)
        self.end_marker(c)

    def run(self, ticks):
        for _ in range(ticks):
            self.tick()
        return self.events
