"""Convert YM2151 patches (from the OutRun sound ROM) into SNES instruments:
a looped BRR timbre sample + ADSR/release settings + volume."""
import os, subprocess, tempfile
import numpy as np
import brr
import snesdsp

HERE = os.path.dirname(os.path.abspath(__file__))
FMR = os.path.join(os.path.dirname(HERE), 'build', 'host', 'fmrender')
CLOCK = 4000000
NATIVE = CLOCK / 64.0          # ymfm OPM sample rate
F_A4 = 440.0 * CLOCK / 3579545.0

def note_freq(n):
    """frequency of note index n (index into the Z80 note/octave table)"""
    return F_A4 * 2.0 ** ((n - 56) / 12.0)

# carrier slots (register offsets 0=M1 8=M2 16=C1 24=C2) per connection
CARRIERS = {0: (24,), 1: (24,), 2: (24,), 3: (24,), 4: (16, 24), 5: (8, 16, 24), 6: (8, 16, 24), 7: (0, 8, 16, 24)}
DT2_RATIO = (1.0, 1.41, 1.57, 1.73)

def render(pairs, note, on_s, off_s, flatten=False):
    regs = dict(pairs)
    regs[0x20] = (regs.get(0x20, 0) & 0x3F) | 0xC0
    if flatten:
        for s in CARRIERS[regs[0x20] & 7]:
            regs[0x80 + s] = (regs.get(0x80 + s, 0) & 0xC0) | 31
            regs[0xA0 + s] = regs.get(0xA0 + s, 0) & 0x80
            regs[0xC0 + s] = regs.get(0xC0 + s, 0) & 0xC0
            regs[0xE0 + s] = regs.get(0xE0 + s, 0) & 0x0F
    kc = (note // 12) << 4 | (0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14)[note % 12]
    lines = ['W 1 0', 'W f 0', 'W 18 0', 'W 19 80', 'W 19 0', 'W 14 0']
    for r, v in sorted(regs.items()):
        lines.append('W %x %x' % (r, v))
    lines += ['W 28 %x' % kc, 'W 30 0', 'W 8 0', 'W 8 78', 'G %d' % int(on_s * NATIVE), 'W 8 0', 'G %d' % int(off_s * NATIVE)]
    fd, path = tempfile.mkstemp(suffix='.raw'); os.close(fd)
    subprocess.run([FMR, str(CLOCK), path], input='\n'.join(lines) + '\n', capture_output=True, text=True, check=True)
    x = np.fromfile(path, dtype=np.int16).astype(float)
    os.unlink(path)
    return x

def periods_needed(pairs):
    regs = dict(pairs)
    n = 1
    for s in (0, 8, 16, 24):
        mul = regs.get(0x40 + s, 0) & 15
        dt2 = regs.get(0xC0 + s, 0) >> 6
        if dt2: return 8
        if mul == 0: n = 2
    return n

# ---------------------------------------------------------------------------
# SNES envelope model
RATE = [0, 2048, 1536, 1280, 1024, 768, 640, 512, 384, 320, 256, 192, 160, 128, 96, 80,
        64, 48, 40, 32, 24, 20, 16, 12, 10, 8, 6, 5, 4, 3, 2, 1]
_E = [0x7FF]
while _E[-1] > 0:
    e = _E[-1]; _E.append(max(0, e - ((e - 1) >> 8) - 1))
EXPSEQ = np.array(_E, dtype=float)

def snes_env(ar, dr, sl, sr, t):
    """envelope level (0..1) at times t (seconds, numpy array) during key-on"""
    ns = t * 32000.0
    pa = RATE[ar * 2 + 1]
    n_att = 2 if ar == 15 else 63 * pa
    out = np.empty_like(ns)
    att = ns < n_att
    out[att] = (ns[att] / max(n_att, 1)) * 0x7E0
    pd = RATE[dr * 2 + 16]
    i_sl = int(np.argmax((EXPSEQ.astype(int) >> 8) == sl)) if sl < 7 else 0
    # after attack: exp decay at pd until index i_sl, then sustain at rate sr
    tt = ns[~att] - n_att
    idx = tt / pd
    if sr == 0:
        idx = np.minimum(idx, i_sl)
    else:
        ps = RATE[sr]
        over = idx > i_sl
        idx = np.where(over, i_sl + (tt - i_sl * pd) / ps, idx)
    idx = np.minimum(idx, len(EXPSEQ) - 1).astype(int)
    out[~att] = EXPSEQ[idx]
    return out / 2047.0

def db(x, floor=-60.0):
    return np.maximum(20 * np.log10(np.maximum(x, 1e-9)), floor)

def measure_env(x, f):
    win = max(int(NATIVE * 0.004), int(2 * NATIVE / f))
    hop = int(NATIVE * 0.002)
    t = []; v = []
    for i in range(0, len(x) - win, hop):
        t.append((i + win / 2) / NATIVE)
        v.append(np.sqrt(np.mean(np.square(x[i:i + win]))))
    return np.array(t), np.array(v)

def fit_adsr(t, lvl, on_s):
    """fit SNES ADSR to a measured level curve (linear, key-on until on_s)"""
    m = t < on_s
    tt = t[m]; ll = lvl[m] / lvl[m].max()
    target = db(ll, -50)
    w = np.where(tt < 0.4, 3.0, 1.0)          # early part matters most
    early = ll[tt < 0.3]
    tpk = tt[np.argmax(ll > 0.7 * early.max())]
    best = None
    for ar in range(16):
        n_att = 2 if ar == 15 else 63 * RATE[ar * 2 + 1]
        if abs(n_att / 32000.0 - tpk) > 0.02 + 0.5 * tpk:
            continue
        for dr in range(8):
            for sl in range(8):
                for sr in range(32):
                    e = db(snes_env(ar, dr, sl, sr, tt), -50)
                    err = np.sum(w * (e - target) ** 2)
                    if best is None or err < best[0]:
                        best = (err, ar, dr, sl, sr)
    return best

def fit_release(t, lvl, on_s):
    """exp-decrease GAIN rate matching the level slope after key-off (dB/s)"""
    m = (t > on_s + 0.004) & (t < on_s + 0.5)
    tt = t[m]; ll = db(lvl[m] / max(lvl.max(), 1e-9), -60)
    ok = ll > -45
    if ok.sum() < 3:
        return 31
    tt = tt[ok]; ll = ll[ok]
    slope = np.polyfit(tt, ll, 1)[0]            # dB/s (negative)
    best = None
    for r in range(1, 32):
        s = 20 * np.log10(255.0 / 256) * 32000.0 / RATE[r]
        if best is None or abs(np.log(s / slope)) < best[0]:
            best = (abs(np.log(s / slope)), r)
    return best[1]

def resample(x, ratio):
    """resample by ratio (out_rate/in_rate) with windowed-sinc interpolation"""
    n_out = int(len(x) * ratio)
    pos = np.arange(n_out) / ratio
    cutoff = min(1.0, ratio)
    taps = 16
    i0 = np.floor(pos).astype(int)
    out = np.zeros(n_out)
    for k in range(-taps + 1, taps + 1):
        idx = i0 + k
        d = pos - idx
        wv = np.sinc(d * cutoff) * cutoff * (0.5 + 0.5 * np.cos(np.pi * np.clip(d / taps, -1, 1)))
        valid = (idx >= 0) & (idx < len(x))
        out[valid] += x[idx[valid]] * wv[valid]
    return out

def smooth_beats(t, lvl, t0=0.06, w_s=0.3):
    """envelope with slow beating between carriers averaged out (power
    moving average over w_s after t0): the SNES loop cannot beat, its ADSR
    should follow the mean level"""
    out = lvl.copy()
    dt = t[1] - t[0] if len(t) > 1 else 0.002
    w = max(1, int(w_s / dt))
    p = np.convolve(lvl ** 2, np.ones(w) / w, mode='same')
    m = t > t0
    out[m] = np.sqrt(p[m])
    return out


def make_instrument(pairs, note_ref, note_max, max_attack=0.15, note_s=0.3):
    """returns dict(brr=bytes, loop=offset, spp_shift=k, adsr1, adsr2, rel, amp, vol);
    note_s: typical note length (level match window)"""
    f = note_freq(note_ref)
    on_s = 1.2
    a = render(pairs, note_ref, on_s, 0.5)
    t, lvl = measure_env(a, f)
    err, ar, dr, sl, sr = fit_adsr(t, smooth_beats(t, lvl), on_s)
    rel = fit_release(t, lvl, on_s)
    amp = np.abs(a[:int(0.3 * NATIVE)]).max()
    # timbre: the real render divided by its smoothed amplitude envelope (keeps the
    # balance between carriers with different envelopes, removes the envelope itself)
    on = a[:int(on_s * NATIVE)]
    w = max(int(NATIVE * 0.004), int(2 * NATIVE / f))
    env = np.sqrt(np.convolve(on ** 2, np.ones(w) / w, mode='same'))
    env = np.maximum(env, env.max() * 0.02)
    b = on / env
    # samples per period: power of two, rate at ref <= 24 kHz, top note P <= 0x3FFF
    spp = 16
    while spp * 2 * f <= 24000 and spp * 2 * note_freq(note_max) * 4096 / 32000 <= 0x3FFF and spp < 256:
        spp *= 2
    ratio = f * spp / NATIVE
    y = resample(b, ratio)
    nper = periods_needed(pairs)
    L = spp * nper
    # loop start: first period whose harmonic spectrum is close to the note's
    # "body" timbre (80-200 ms), after the envelope attack; capped at max_attack
    per = spp
    nper_tot = len(y) // per
    def harm(k):
        sp = np.abs(np.fft.rfft(y[k * per:(k + 1) * per]))[1:11]
        return np.maximum(20 * np.log10(sp / (sp.max() + 1e-9) + 1e-9), -40.0)
    k_lo, k_hi = int(0.08 * f), min(int(0.2 * f), nper_tot - nper - 1)
    target = np.mean([harm(k) for k in range(k_lo, max(k_hi, k_lo + 1))], axis=0)
    t_att = t[np.argmax(lvl > 0.7 * lvl[t < 0.3].max())]
    k_min = max(1, int(max(0.015, t_att) * f))
    k_max = max(k_min + 1, int(max_attack * f))
    k0 = k_max
    for k in range(k_min, k_max):
        if np.sqrt(np.mean((harm(k) - target) ** 2)) < 3.0:
            k0 = k
            break
    start = k0 * per
    start -= start % 16
    body = y[:start + L].copy()
    # make the loop seamless: crossfade the loop end towards the waveform just before loop start
    if start >= per:
        fade = np.linspace(0, 1, per)
        seg_end = body[start + L - per:start + L]
        seg_pre = y[start - per:start]
        body[start + L - per:start + L] = seg_end * (1 - fade) + seg_pre * fade
    # pre-emphasis: the DSP's gaussian interpolation loses highs by f / R
    # (R = spp * note frequency, the same for every note of the instrument):
    # the loop gets the inverse response per harmonic, the attack an FIR
    loop = snesdsp.emphasize_periodic(body[start:start + L])
    if start:
        att = snesdsp.emphasize(np.concatenate([body[:start], loop, loop]))[:start]
        body = np.concatenate([att, loop])
    else:
        body = loop
    s15, k = brr.to15(body, 0.9)
    data = brr.encode(s15, loop_start=start)
    # level: the SNES note (decoded BRR, gaussian playback, fitted envelope)
    # gets the arcade note's rms over a typical note length: vol (128 = 1.0) for
    # a DSP voice output = YM_GAIN * the YM output (the DSP doubles samples)
    win = min(max(note_s, 0.2), 1.0)
    n = int(win * 32000)
    P = int(round(4096 * spp * f / 32000.0))
    x = snesdsp.brr_loop_samples(data, start // 16 * 9, n * P // 4096 + 8)
    y = snesdsp.interp(x, P, n) * snes_env(ar, dr, sl, sr, np.arange(n) / 32000.0)
    a_rms = np.sqrt(np.mean(a[:int(win * NATIVE)] ** 2))
    s_rms = np.sqrt(np.mean(y ** 2))
    vol = 128.0 * 0.5 * a_rms / (2.0 * max(s_rms, 1e-6))
    # the arcade's end-of-effect quirk (driver m_end) writes D1L 15 / RR 15
    # to every operator of YM channels 6 and 7: the envelope of such notes
    pb = [(r, 0xFF if 0xE0 <= r < 0x100 else v) for r, v in pairs]
    ab = render(pb, note_ref, on_s, 0.5)
    tb, lb = measure_env(ab, f)
    _, ar2, dr2, sl2, sr2 = fit_adsr(tb, np.maximum(lb, lvl.max() * 1e-4), on_s)
    return dict(brr=data, loop=start // 16 * 9, spp=spp, adsr=(ar, dr, sl, sr), rel=rel,
                amp=amp, vol=vol, fiterr=err, start=start, L=L, f=f, adsr_brk=(ar2, dr2, sl2, sr2))
