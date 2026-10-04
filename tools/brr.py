"""BRR (SNES bit-rate-reduction) codec, bit-exact decoder model after fullsnes/blargg."""
import numpy as np

def _sext15(v):
    v &= 0x7FFF
    return v - 0x8000 if v & 0x4000 else v

def _clamp16(v):
    return -32768 if v < -32768 else (32767 if v > 32767 else v)

def _pred(filt, old, older):
    if filt == 0: return 0
    if filt == 1: return old + ((-old) >> 4)
    if filt == 2: return (old << 1) + ((-old * 3) >> 5) - older + (older >> 4)
    return (old << 1) + ((-old * 13) >> 6) - older + ((older * 3) >> 4)

def _dec(n, shift, filt, old, older):
    s = (n << shift) >> 1 if shift <= 12 else (-2048 if n < 0 else 0)
    s += _pred(filt, old, older)
    return _sext15(_clamp16(s))

def decode(data, old=0, older=0):
    out = []
    for b in range(0, len(data), 9):
        hdr = data[b]; shift = hdr >> 4; filt = (hdr >> 2) & 3
        for i in range(16):
            byte = data[b + 1 + i // 2]
            n = (byte >> 4) if i % 2 == 0 else (byte & 15)
            if n >= 8: n -= 16
            s = _dec(n, shift, filt, old, older)
            older, old = old, s
            out.append(s)
    return out

def _enc_block(x, old, older, filters):
    """x: 16 target samples (15-bit ints). returns (err, hdr_shift_filter, nibbles, old, older)"""
    best = None
    for filt in filters:
        for shift in range(13):
            o, oo = old, older
            err = 0
            nib = []
            step = (1 << shift) >> 1 if shift > 0 else 0
            for t in x:
                p = _pred(filt, o, oo)
                r = t - p
                if shift == 0:
                    n = (r * 2) if False else r * 2  # s = n >> 1 ... (n<<0)>>1
                    n = int(round(r * 2))
                else:
                    n = int(round(r / step)) if step else 0
                n = -8 if n < -8 else (7 if n > 7 else n)
                s = _dec(n, shift, filt, o, oo)
                # try neighbours for better rounding / avoid wrap
                for m in (n - 1, n + 1):
                    if -8 <= m <= 7:
                        s2 = _dec(m, shift, filt, o, oo)
                        if abs(s2 - t) < abs(s - t):
                            n, s = m, s2
                e = s - t
                err += e * e
                if best is not None and err >= best[0]:
                    break
                nib.append(n)
                oo, o = o, s
            else:
                if best is None or err < best[0]:
                    best = (err, (shift << 4) | (filt << 2), nib, o, oo)
    return best

def encode(samples, loop_start=None, end=True):
    """samples: iterable of ints in [-16384, 16383], length multiple of 16 (padded).
    loop_start: sample index (multiple of 16) or None.  Returns bytes."""
    x = [int(v) for v in samples]
    if len(x) % 16:
        x += [0] * (16 - len(x) % 16)
    nb = len(x) // 16
    out = bytearray()
    old = older = 0
    for b in range(nb):
        blk = x[b * 16:(b + 1) * 16]
        filters = (0,) if b == 0 or (loop_start is not None and b * 16 == loop_start) else (0, 1, 2, 3)
        err, hdr, nib, old, older = _enc_block(blk, old, older, filters)
        if b == nb - 1 and end:
            hdr |= 1
            if loop_start is not None:
                hdr |= 2
        out.append(hdr)
        for i in range(0, 16, 2):
            out.append(((nib[i] & 15) << 4) | (nib[i + 1] & 15))
    return bytes(out)

def to15(x, peak=0.97):
    """float array -> 15-bit ints scaled to `peak` of full scale (returns ints, scale)"""
    x = np.asarray(x, dtype=float)
    m = np.abs(x).max() or 1.0
    k = peak * 16383 / m
    return [int(round(v)) for v in x * k], k
