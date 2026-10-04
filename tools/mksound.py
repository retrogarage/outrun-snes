#!/usr/bin/env python3
"""Build the SNES sound data from the OutRun sound ROMs.

Outputs (build/gen):
  sound.s / sound.inc   ROM data for the S-CPU uploader + ids
  snd_*.bin             upload streams (2-byte packets of whole 256-byte
                        pages, see tools/spc/driver.s c_upload)

ARAM layout (must match tools/spc/driver.s):
  $0400 driver, $1000 DIR, $1100 FM instruments, $1200 sample instruments,
  $1400 song header, $1480 sfx table, $1500 resident effects and the drum
  samples common to the three race songs, then the song bank.
"""
import os
import sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import orseq      # noqa: E402
import fminst     # noqa: E402
import brr        # noqa: E402
import spcasm     # noqa: E402
import snesdsp    # noqa: E402

ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, 'build', 'gen')

DRV_BASE = 0x0400
DIR = 0x1000
FMI = 0x1100
SMI = 0x1200
SONGH = 0x1400
SFXT = 0x1480
RES_BASE = 0x1500
ARAM_END = 0xFFC0
BRR_PEAK = 0.9 * 16383
MIX = 0.5                     # SNES output level / arcade output level (DSP doubles samples)
YM_GAIN = 0.5                 # cannonball's YM2151 mix level
FIRST_BANK = 0x2C             # ROM banks for the upload streams
LAST_BANK = 0x31

# ---------------------------------------------------------------------------
# PCM sample ROMs (SegaPCM, 8-bit unsigned, 64KB banks of which 32KB used)
PCM_ROMS = ['opr-10193.66', 'opr-10192.67', 'opr-10191.68', 'opr-10190.69', 'opr-10189.70', 'opr-10188.71']
from orroms import _rd
PCM = [_rd(r) for r in PCM_ROMS]


def pcm_data(bank, start, end_hi):
    b = PCM[bank]
    end = min((end_hi + 1) << 8, len(b))
    return np.frombuffer(b[start:end], dtype=np.uint8).astype(float) - 128.0


def pcm_rate(pitch):
    return 31250.0 * pitch / 256.0


# ---------------------------------------------------------------------------
# songs: arcade channel -> (home voice, priority, volume scale); order = track
# order.  Every channel is played; the driver allocates voices per note by
# priority (tools/spc/driver.s alloc): lead and bass first, chords next,
# unison doubles / extras only on free voices.  During races voice 7 is the
# engine's, so the home-7 channels mostly rest there.
V_NONE = 0xFF
SONG_ORDER = [0x85, 0x81, 0x82, 0xA5]        # SND song numbers 0-3
P_LEAD, P_LEAD2, P_BASS = 0x70, 0x64, 0x6C
P_CH1, P_CH2, P_CH3, P_CH4 = 0x54, 0x50, 0x4C, 0x44
P_DOUBLE, P_EXTRA = 0x38, 0x30
SONG_CFG = {
    # Magical Sound Shower: ch1 lead, ch2 its unison double, ch0 an octave below
    0x85: [(1, 0, P_LEAD, 128), (0, 1, P_LEAD2, 128), (3, 2, P_BASS, 128), (4, 3, P_CH1, 128),
           (5, 4, P_CH2, 128), (6, 5, P_CH3, 128), (2, 7, P_DOUBLE, 128), (7, 7, P_EXTRA, 128),
           (8, 6, 0, 128), (9, 6, 0, 128), (10, 6, 0, 128), (11, 6, 0, 128), (12, 6, 0, 128)],
    # Passing Breeze: lead ch0 / ch1 / ch2 in unison (ch1 = ch2's patches)
    0x81: [(1, 0, P_LEAD, 128), (0, 1, P_LEAD2, 128), (3, 2, P_BASS, 128), (4, 3, P_CH1, 128),
           (5, 4, P_CH2, 128), (6, 5, P_CH3, 128), (7, 7, P_CH4, 128), (2, 7, P_DOUBLE, 128),
           (8, 6, 0, 128), (9, 6, 0, 128), (10, 6, 0, 128), (11, 6, 0, 128)],
    # Splash Wave: lead ch0 / ch1 in unison, ch2 an octave above
    0x82: [(0, 0, P_LEAD, 128), (2, 1, P_LEAD2, 128), (3, 2, P_BASS, 128), (4, 3, P_CH1, 128),
           (5, 4, P_CH2, 128), (6, 5, P_CH3, 128), (7, 7, P_CH4, 128), (1, 7, P_DOUBLE, 128),
           (8, 6, 0, 128), (9, 6, 0, 128), (10, 6, 0, 128), (11, 6, 0, 128), (12, 6, 0, 128)],
    # Last Wave: 8 FM channels (a chorale), no drums
    0xA5: [(0, 0, 0x50, 128), (1, 1, 0x50, 128), (2, 2, 0x50, 128), (3, 3, 0x50, 128),
           (4, 4, 0x50, 128), (5, 5, 0x50, 128), (6, 6, 0x50, 128), (7, 7, 0x50, 128)],
}
# drum sample rate caps / truncation (seconds); hit priority (driver alloc)
DRUM_RATE = 12000
DRUM_MAXLEN = {0: 0.45, 9: 0.55, 13: 0.40}
# (by sound: 6 kick; 2, 5, 10-13 snares / claps; 3, 7, 8 toms; 1 closed hat;
# 0, 9 open hat / cymbal; 4 rim): the beat over the lower chord voices
DRUM_PRIO = {6: 0x60, 2: 0x5C, 5: 0x5C, 10: 0x5C, 11: 0x5C, 12: 0x5C, 13: 0x5C,
             3: 0x50, 7: 0x50, 8: 0x50, 1: 0x4C, 0: 0x48, 9: 0x48, 4: 0x44}

# sound effects: name -> (arcade command, slot, priority)
SFX_LIST = [
    ('COIN', 0x84, 2, 2), ('CHECKPOINT', 0x86, 2, 2), ('SIGNAL1', 0x94, 2, 2), ('SIGNAL2', 0x95, 2, 2),
    ('CRASH1', 0x8F, 0, 3), ('CRASH2', 0x92, 0, 3), ('REBOUND', 0x90, 0, 3),
    ('SLIP', 0x8A, 0, 1), ('SAFETY', 0xA0, 0, 1), ('CHEERS', 0x8D, 0, 2),
    ('VOICE_CHECKPOINT', 0x9D, 1, 3), ('VOICE_CONGRATS', 0x9E, 1, 3), ('VOICE_GETREADY', 0x9F, 1, 3),
]
LOOPED_SFX = {'SLIP', 'SAFETY', 'CHEERS'}
# SFX samples: arcade index (0xD0 + i) -> (rate cap, max seconds or None, loop)
SFX_SAMPLE_CFG = {0: (8000, 0.8, False), 3: (11025, 0.55, False), 6: (11025, 0.4, False),
                  2: (8000, None, True), 9: (11025, None, True), 11: (8000, 0.9, True),
                  12: (8800, None, False), 13: (8800, None, False), 14: (8800, None, False)}


def resample(x, ratio):
    return fminst.resample(np.asarray(x, dtype=float), ratio) if abs(ratio - 1) > 1e-6 else np.asarray(x, dtype=float)


def fade_out(y, n):
    n = min(n, len(y))
    if n > 0:
        y[-n:] *= np.linspace(1, 0, n)
    return y


class Sample:
    def __init__(self, data, loop_off=None):
        self.data = data            # BRR bytes
        self.loop_off = loop_off    # byte offset of the loop block or None
        self.addr = None


def make_pcm_sample(x, arate, rate_cap, max_s=None, loop=False):
    """x: arcade samples played at arate -> (Sample, P, gain): gain = arcade
    sample units -> BRR (15-bit) units, so the SNES volume for arcade level
    v (0-$40) is 4096 * MIX * 2 / gain * v / 64 (DSP output = 2 x 15-bit)"""
    R = min(arate, rate_cap)
    y = resample(x, R / arate)
    if max_s and len(y) > max_s * R:
        y = fade_out(y[:int(max_s * R)].copy(), int(0.25 * max_s * R))
    if loop:
        # loop the whole sample: stretch to a multiple of 16 samples (pitch compensated)
        n = max(16, int(round(len(y) / 16.0)) * 16)
        R *= n / float(len(y))
        y = resample(y, n / float(len(y)))[:n]
        if len(y) < n:
            y = np.concatenate([y, np.zeros(n - len(y))])
        y = snesdsp.emphasize_periodic(y)       # gaussian interpolation compensation
    else:
        y = snesdsp.emphasize(np.concatenate([y, np.zeros(16)]))[:len(y)]
    s15, k = brr.to15(y, 0.9)
    data = brr.encode(s15, loop_start=0 if loop else None)
    P = int(round(4096 * R / 32000.0))
    return Sample(data, 0 if loop else None), P, k


def song_drums(cmd):
    """percussion samples (PERC indexes) the song's kept channels play"""
    keep = [c for c, _, _, _ in SONG_CFG[cmd]]
    ev = orseq.Song(cmd).run(60000)
    return sorted(set(e[3] for e in ev if e[1] in keep and e[2] == 'drum'))


def make_drum(d):
    """PERC sample d -> (Sample, P, gain)"""
    st, eh, pitch, fl = orseq.PERC[d]
    x = pcm_data((fl >> 4) & 7, st, eh)
    return make_pcm_sample(x, pcm_rate(pitch), DRUM_RATE, DRUM_MAXLEN.get(d))


# ---------------------------------------------------------------------------
def build_driver():
    src = open(os.path.join(HERE, 'spc', 'driver.s')).read()
    pt = []
    for s in range(12):
        f = fminst.note_freq(84 + s)
        pt.append('PT%d = %d' % (s, int(round(4 * 4096 * f * 16 / 32000.0))))
    src = '\n'.join(pt) + '\n' + src
    trv = orseq.Z[0x7CEF:0x7CEF + 32]          # traffic volume by distance (arcade table)
    src += '\nTRV:    .byte ' + ', '.join('$%02X' % b for b in trv) + '\n'
    a = spcasm.Assembler()
    base, img = a.assemble(src)
    assert base == DRV_BASE, hex(base)
    assert base + len(img) <= DIR, 'driver too large'
    return img, a.syms


def fmi_entry(srcn, inst, pairs, vsc_amp=1.0):
    ar, dr, sl, sr = inst['adsr']
    vol = int(round(inst['vol'] * vsc_amp))      # rms matched (fminst.make_instrument)
    vol = max(1, min(127, vol))
    k = {16: 0, 32: 1, 64: 2, 128: 3, 256: 4}[inst['spp']]
    rel = 0xA0 | inst['rel']
    ar2, dr2, sl2, sr2 = inst['adsr_brk']
    pan = dict(pairs).get(0x20, 0xC0) & 0xC0      # a patch load sets the channel's L/R bits
    return bytes([srcn, (dr << 4) | ar, (sl << 5) | sr, rel, vol, k | pan, (dr2 << 4) | ar2, (sl2 << 5) | sr2])


def smi_entry(srcn, P, vol, prio=0x3C, adsr=None):
    vol = max(1, min(127, int(round(vol))))
    a1, a2 = (0, 0) if adsr is None else adsr
    return bytes([srcn, a1, a2, 0, vol, P & 0xFF, P >> 8, prio])


# ---------------------------------------------------------------------------
class Image:
    """ARAM model; blocks become upload streams"""
    def __init__(self):
        self.mem = bytearray(0x10000)
        self.blocks = []

    def put(self, addr, data):
        self.mem[addr:addr + len(data)] = data
        self.blocks.append((addr, len(data)))


def stream_pages(blocks):
    """the 256-byte ARAM pages touched by blocks [(addr, len)]"""
    pages = set()
    for addr, n in blocks:
        if n:
            pages.update(range(addr >> 8, ((addr + n - 1) >> 8) + 1))
    assert min(pages) >= DIR >> 8, 'stream would overwrite the driver'
    return sorted(pages)


def stream(img, blocks, pages=None):
    """upload stream for blocks [(addr, len)] (or the given pages): the
    256-byte pages they touch (the image's own contents fill the rest of each
    page), as runs of (first page, page count) headers + data; (0, 0) ends
    the stream.  The driver takes 2 bytes per handshake."""
    if pages is None:
        pages = stream_pages(blocks)
    out = bytearray()
    for pg in sorted(pages):
        if out and pg == run_start + run_n and run_n < 255:
            run_n += 1
            out[hdr + 1] = run_n
        else:
            run_start, run_n, hdr = pg, 1, len(out)
            out += bytes([pg, 1])
        out += img.mem[pg << 8:(pg + 1) << 8]
    out += bytes(2)
    return bytes(out)


# ---------------------------------------------------------------------------
def build_resident(img, common=()):
    """sound effects: samples (srcn 32+), FM instruments 16+, sample instruments 16+,
    sequences and the sfx table; plus the drum samples in `common` (shared by
    the songs: a song switch does not upload them again).
    Returns (end address, effect names, {drum: (srcn, P, gain)})"""
    samples = []                  # (srcn, Sample)
    smi = {}                      # smi id -> entry bytes
    fmi = {}
    # engine tone: bank 1 $0082-$06FF, looped; stored so that P = delta * 16
    x = pcm_data(1, 0x0082, 0x06)
    n = int(round(len(x) * 1.024 / 16)) * 16
    y = resample(x, n / len(x))[:n]
    s15, k = brr.to15(y, 0.9)
    eng = Sample(brr.encode(s15, loop_start=0), 0)
    samples.append((32, eng))
    next_srcn = 33
    next_smi = 16
    next_fmi = 16
    sfx_samples = {}              # arcade sample index -> smi id
    fm_patch = {}                 # (cmd, patch) -> fmi id
    seqs = []                     # (name, bytes, slot, flags, prio)
    for name, cmd, slot, prio in SFX_LIST:
        s = orseq.Song(cmd)
        ev = s.run(4000)
        is_pcm = s.ch[0].pcm
        if is_pcm:
            # the triggers of the (up to two) channels: channel 0's drive the
            # SNES voice; both channels' levels go into each trigger's level
            # (in step they add up, a few ticks apart (slip, crash, cheers)
            # their powers add)
            trig = {}
            for e in ev:
                if e[2] == 'sfx':
                    trig.setdefault(e[1], []).append(e)
            t0 = trig[0]
            idx, pitch = t0[0][3], t0[0][5]
            levels = []
            for k, e in enumerate(t0):
                pair = [e] + [trig[c][k] for c in trig if c != 0 and k < len(trig[c])]
                if len(set(f[0] for f in pair)) == 1:
                    vl = sum(f[4][0] for f in pair); vr = sum(f[4][1] for f in pair)
                else:
                    vl = np.sqrt(sum(f[4][0] ** 2 for f in pair)); vr = np.sqrt(sum(f[4][1] ** 2 for f in pair))
                levels.append((e[0], vl, vr))
            if idx not in sfx_samples:
                st, eh, fl = orseq.pcm_info(idx)
                bank = (fl >> 4) & 7
                x = pcm_data(bank, st, eh)
                cap, max_s, loop = SFX_SAMPLE_CFG[idx]
                smp, P, k = make_pcm_sample(x, pcm_rate(pitch), cap, max_s, loop)
                samples.append((next_srcn, smp))
                sfx_samples[idx] = (next_smi, next_srcn, P, k, smp)
                next_srcn += 1
                next_smi += 1
            sid, srcn, P, k, smp = sfx_samples[idx]
            m = max(max(vl, vr) for _, vl, vr in levels) or 1
            vol = 8192.0 * MIX * (m / 64.0) / k
            smi[sid] = smi_entry(srcn, P, vol, 0)
            def lvl(vl, vr):
                return bytes([0x82, int(round(vl * 64.0 / m)), int(round(vr * 64.0 / m))])
            seq = bytearray([0x94]) + lvl(*levels[0][1:])
            if name in LOOPED_SFX:
                # the sample loops by itself (the arcade retriggers it about
                # once per sample length)
                seq += bytes([0xC0 + sid, 0xFF])
                lp = len(seq)
                seq += bytes([0x01, 0xFF, 0x8A, lp & 0xFF, 0])   # relocated below
                seqs.append((name, seq, slot, 0x40, prio, [(lp, len(seq) - 2)]))
            else:
                # every trigger with its level (crashes: hits fading out)
                slen = int(len(smp.data) // 9 * 16 / (P / 4096.0 * 32000.0) * 125) + 4
                for i, (t, vl, vr) in enumerate(levels):
                    if i:
                        seq += lvl(vl, vr)
                    dur = (levels[i + 1][0] - t) if i + 1 < len(levels) else slen
                    seq += bytes([0x95, 0xC0 + sid, dur & 0xFF, dur >> 8])
                seq += bytes([0x84])
                seqs.append((name, seq, slot, 0x40, prio, []))
        else:
            seq = bytearray([0x94])
            t = 0
            cur = None
            evs = [e for e in ev if e[2] in ('on', 'off', 'end', 'patch')]
            for i, e in enumerate(evs):
                if e[2] == 'patch':
                    key = (cmd, e[3])
                    if key not in fm_patch:
                        fm_patch[key] = next_fmi
                        next_fmi += 1
                    seq += bytes([0x91, fm_patch[key]])
                    continue
                nxt = [f for f in evs[i + 1:] if f[2] in ('on', 'off', 'end')]
                dur = (nxt[0][0] - e[0]) if nxt else 1
                if e[2] == 'end':
                    break
                if dur <= 0:
                    continue
                nb = 1 + e[8] if e[2] == 'on' else 0
                if dur > 255:
                    seq += bytes([0x95, nb, dur & 0xFF, dur >> 8])
                else:
                    seq += bytes([nb, dur])
            seq += bytes([0x84])
            seqs.append((name, seq, slot, 0x00, prio, []))
            cur = cmd
    # common drums
    common_map = {}
    for d in common:
        smp, P, k = make_drum(d)
        samples.append((next_srcn, smp))
        common_map[d] = (next_srcn, P, k)
        next_srcn += 1
    # FM effect instruments
    for (cmd, patch), fid in sorted(fm_patch.items(), key=lambda kv: kv[1]):
        pairs = orseq.patch_block(cmd, patch)
        notes = [e[8] for e in orseq.Song(cmd).run(4000) if e[2] == 'on']
        med = sorted(notes)[len(notes) // 2]
        inst = fminst.make_instrument(pairs, med, max(notes))
        smp = Sample(inst['brr'], inst['loop'])
        samples.append((next_srcn, smp))
        fmi[fid] = fmi_entry(next_srcn, inst, pairs)
        next_srcn += 1
    assert next_srcn <= 64 and next_smi <= 64 and next_fmi <= 32
    # lay out: sequences then samples
    addr = RES_BASE
    sfxt = bytearray(128)
    for i, (name, seq, slot, flags, prio, relocs) in enumerate(seqs):
        for lp, at in relocs:
            v = addr + lp
            seq[at] = v & 0xFF
            seq[at + 1] = v >> 8
        img.put(addr, bytes(seq))
        sfxt[i * 4:i * 4 + 4] = bytes([addr & 0xFF, addr >> 8, slot | flags, prio])
        addr += len(seq)
    for srcn, smp in samples:
        smp.addr = addr
        img.mem[addr:addr + len(smp.data)] = smp.data
        addr += len(smp.data)
    res_end = addr
    img.blocks.append((RES_BASE, res_end - RES_BASE))
    # tables
    dirt = bytearray(128)
    for srcn, smp in samples:
        o = (srcn - 32) * 4
        lp = smp.addr + (smp.loop_off or 0)
        dirt[o:o + 4] = bytes([smp.addr & 0xFF, smp.addr >> 8, lp & 0xFF, lp >> 8])
    img.put(DIR + 128, bytes(dirt))
    fm = bytearray(128)
    for fid, e in fmi.items():
        fm[(fid - 16) * 8:(fid - 15) * 8] = e
    img.put(FMI + 128, bytes(fm))
    sm = bytearray(384)
    for sid, e in smi.items():
        sm[(sid - 16) * 8:(sid - 15) * 8] = e
    img.put(SMI + 128, bytes(sm))
    img.put(SFXT, bytes(sfxt))
    names = [s[0] for s in seqs]
    print('resident: $%04X-$%04X (%d bytes, %d samples, common drums %s)' % (
        RES_BASE, res_end, res_end - RES_BASE, len(samples), list(common)))
    return res_end, names, common_map


# ---------------------------------------------------------------------------
def build_song(img, cmd, base, common_map={}):
    cfg = SONG_CFG[cmd]
    keep = [c for c, _, _, _ in cfg]
    s = orseq.Song(cmd)
    ev = s.run(60000)
    # instruments: patches used for notes by kept FM tracks, note ranges
    notes = {}
    durs = {}
    loaded = set()
    for e in ev:
        if e[1] in keep and e[2] == 'on':
            notes.setdefault(e[5], []).append(e[8])
            durs.setdefault(e[5], []).append(e[7] / 125.0)
    for a, st in s.trace.items():
        for c, r in st:
            if c in keep and r == 'patch' and orseq.r8(a):
                loaded.add(orseq.r8(a))
    patches = sorted(set(notes) | loaded)
    drums = sorted(set(e[3] for e in ev if e[1] in keep and e[2] == 'drum'))
    assert len(patches) <= 15 and len(drums) <= 16
    patch_map = {p: i + 1 for i, p in enumerate(patches)}
    drum_map = {d: i for i, d in enumerate(drums)}
    # relocate the sequence data of the kept tracks
    used = sorted(a for a, st in s.trace.items() if any(c in keep for c, _ in st))
    newaddr = {}
    data = bytearray()
    for a in used:
        newaddr[a] = base + len(data)
        data.append(orseq.r8(a))
    for a in used:
        roles = set(r for c, r in s.trace[a] if c in keep)
        assert len(roles) == 1, (hex(a), roles)
        role = roles.pop()
        o = newaddr[a] - base
        if role == 'plo':
            tgt = orseq.r16(a)
            assert tgt in newaddr, 'target %04x not traced' % tgt
            data[o] = newaddr[tgt] & 0xFF
            data[o + 1] = newaddr[tgt] >> 8
            assert newaddr[a + 1] == newaddr[a] + 1
        elif role == 'patch':
            v = orseq.r8(a)
            data[o] = patch_map.get(v, 0)
        elif role == 'smp':
            v = orseq.r8(a)
            data[o] = 0xC0 + drum_map[v - 0xC0]
    # header
    hdr = bytearray([len(cfg)])
    for c, v, prio, vsc in cfg:
        ch = s.ch[c]
        st = newaddr[ch.start]
        fl = 0x40 if ch.pcm else 0
        if not ch.pcm and (ch.fmflags & 7) in (6, 7):
            fl |= 0x20 | (0x10 if (ch.fmflags & 7) == 7 else 0)     # see driver m_end
        hdr += bytes([st & 0xFF, st >> 8, ch.tempo, ch.transpose, fl, v, prio, vsc])
    addr = base + len(data)
    img.put(base, bytes(data))
    # samples: drums srcn 0-15, FM 16-31
    dirt = bytearray(128)
    smi = bytearray(128)
    fmi = bytearray(128)
    samp_bytes = bytearray()

    def add_sample(srcn, smp):
        nonlocal addr, samp_bytes
        smp.addr = addr
        lp = addr + (smp.loop_off or 0)
        dirt[srcn * 4:srcn * 4 + 4] = bytes([addr & 0xFF, addr >> 8, lp & 0xFF, lp >> 8])
        samp_bytes += smp.data
        addr += len(smp.data)
    dsz = 0
    for d, i in drum_map.items():
        if d in common_map:
            srcn, P, k = common_map[d]              # resident
        else:
            smp, P, k = make_drum(d)
            add_sample(i, smp)
            dsz += len(smp.data)
            srcn = i
        smi[i * 8:i * 8 + 8] = smi_entry(srcn, P, 8192.0 * MIX / k, DRUM_PRIO.get(d, 0x3C))
    fsz = 0
    for p, i in patch_map.items():
        ns = sorted(notes.get(p, [60]))
        ds = np.array(durs.get(p, [0.3]))
        # level match over the note length that carries most of the sound
        # (duration-weighted mean): long held notes dominate what is heard
        pairs = orseq.patch_block(cmd, p)
        inst = fminst.make_instrument(pairs, ns[len(ns) // 2], ns[-1],
                                      note_s=float(np.sum(ds ** 2) / np.sum(ds)))
        smp = Sample(inst['brr'], inst['loop'])
        add_sample(15 + i, smp)
        fsz += len(smp.data)
        fmi[i * 8:i * 8 + 8] = fmi_entry(15 + i, inst, pairs)
    img.mem[base + len(data):addr] = samp_bytes
    img.blocks[-1] = (base, addr - base)
    img.put(DIR, bytes(dirt))
    img.put(FMI, bytes(fmi))
    img.put(SMI, bytes(smi))
    img.put(SONGH, bytes(hdr))
    print('song %-8s: data %5d  drums %5d (%d)  fm %5d (%d)  end $%04X' % (
        orseq.SONG_NAMES[cmd], len(data), dsz, len(drums), fsz, len(patches), addr))
    assert addr <= ARAM_END, 'song does not fit'
    return addr


def main():
    os.makedirs(OUT, exist_ok=True)
    only = os.environ.get('SND_ONLY')        # test: "cmd:chan,chan" keeps these tracks
    if only:
        c, chs = only.split(':')
        keep = [int(v, 0) for v in chs.split(',')]
        SONG_CFG[int(c, 0)] = [e for e in SONG_CFG[int(c, 0)] if e[0] in keep]
    solo = os.environ.get('SND_SOLO')        # test: "cmd:chan" keeps one track on voice 0
    if solo:
        c, ch = [int(v, 0) for v in solo.split(':')]
        SONG_CFG[c] = [(ch, 0, 0x7F, 128)]
    drv, syms = build_driver()
    print('driver: $%04X-$%04X (%d bytes)' % (DRV_BASE, DRV_BASE + len(drv), len(drv)))
    # drums shared by the three race songs stay resident (music select song
    # switches upload less)
    sets = [set(song_drums(c)) for c in SONG_ORDER if c != 0xA5]
    common = sorted(set.intersection(*sets)) if os.environ.get('SND_NOCOMMON') is None else []
    res = Image()
    res_end, sfx_names, common_map = build_resident(res, common)
    song_base = (res_end + 0xFF) & ~0xFF
    # (one ROM bank per stream: the resident data goes in parts)
    rpages = stream_pages(res.blocks)
    res_streams = []
    while rpages:
        n = min(len(rpages), 0x7F00 // 0x100 - 2)
        res_streams.append(stream(res, None, rpages[:n]))
        rpages = rpages[n:]
    songs = []
    for cmd in SONG_ORDER:
        img = Image()
        img.mem[:] = res.mem
        build_song(img, cmd, song_base, common_map)
        songs.append(stream(img, img.blocks))
    # ROM data
    with open(os.path.join(OUT, 'snd_drv.bin'), 'wb') as f:
        f.write(drv)
    files = [('SndResident%d' % i, r) for i, r in enumerate(res_streams)] + \
        [('SndSong%d' % i, s) for i, s in enumerate(songs)]
    lines = ['; generated by tools/mksound.py', '.export SndDriver, SndStreams']
    # banks FIRST_BANK.. LAST_BANK (32 KB each), first fit, largest first
    fill = {FIRST_BANK: len(drv)}
    where = {}
    for name, data in sorted(files, key=lambda f: -len(f[1])):
        assert len(data) <= 0x8000
        for b in range(FIRST_BANK, LAST_BANK + 1):
            if fill.get(b, 0) + len(data) <= 0x8000:
                where[name] = b
                fill[b] = fill.get(b, 0) + len(data)
                break
        else:
            raise AssertionError('sound streams do not fit in banks $%02X-$%02X' % (FIRST_BANK, LAST_BANK))
    lines.append('.segment "BANK%02X"' % FIRST_BANK)
    lines.append('SndDriver: .incbin "snd_drv.bin"')
    tab = []
    for name, data in files:
        fn = 'snd_%s.bin' % name[3:].lower()
        with open(os.path.join(OUT, fn), 'wb') as f:
            f.write(data)
        lines.append('.segment "BANK%02X"' % where[name])
        lines.append('%s: .incbin "%s"' % (name, fn))
        tab.append((name, where[name], len(data) // 2))
    lines.append('.segment "RODATA"')
    lines.append('; stream table: address (word), bank, packets (word)')
    lines.append('SndStreams:')
    for name, b, npk in tab:
        lines.append('    .word .loword(%s)\n    .byte ^%s\n    .word %d' % (name, name, npk))
    open(os.path.join(OUT, 'sndgen.s'), 'w').write('\n'.join(lines) + '\n')
    inc = ['; generated by tools/mksound.py', 'SND_DRV_BASE = $%04X' % DRV_BASE, 'SND_DRV_ENTRY = $%04X' % syms['start'],
           'SND_DRV_LEN = %d' % len(drv)]
    for i, n in enumerate(sfx_names):
        inc.append('SFX_%s = %d' % (n, i))
    inc.append('SND_STREAM_RES = 0')
    inc.append('SND_NRES = %d                ; resident streams (0 - SND_NRES-1), then the songs' % len(res_streams))
    for i, cmd in enumerate(SONG_ORDER):
        inc.append('SND_SONG_%s = %d' % (orseq.SONG_NAMES[cmd].upper(), i))
    open(os.path.join(OUT, 'sound.inc'), 'w').write('\n'.join(inc) + '\n')
    print('streams:', ', '.join('%s %d' % (n, len(d)) for n, d in files))


if __name__ == '__main__':
    main()
