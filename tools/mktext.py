#!/usr/bin/env python3
"""Text layer data for the engine port (src/textlayer.s, NEWGAME builds).

The arcade text layer (8x8 tiles, 3 bitplanes, text palettes 0-7 = palette
RAM entries 0-63) is shown on the SNES BG3 (2 bitplanes: 8 palettes of 3
colours).  Tiles sharing one arcade palette often use different colours of
it (the race HUD's TIME / SCORE / LAP labels: orange / magenta / blue), so
the SNES palettes are not tied to the arcade ones: per screen class (0 = attract
/ menus, 1 = race HUD states) the colour combinations the game shows (COMBOS:
arcade palette, pixel values, weight - surveyed from reference runs) are
packed into 8 SNES palettes of 3 colours, each colour a reference to an
arcade palette entry (so palette RAM changes still reach the SNES).  Every
(arcade palette, tile) gets the SNES palette that shows it best and its 2bpp
data for that palette.

build/gen/textdat.s / textdat.inc:
  TxtTiles0-3  2bpp tiles: class c, arcade palettes 4h..4h+3 -> TxtTiles(2c+h),
               ((pal & 3) * 512 + tile) * 16; BANK0B-0E
  TxtSnPal     per class, (pal << 9 | tile): SNES palette (byte); BANK0F
  TxtRef       per class, SNES palette, colour 1-3: arcade palette RAM entry
  TxtPal0      the text palettes at boot (palette RAM words 0-63, arcade format)
"""
import os, sys, struct, glob, collections, itertools
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from orroms import Roms

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GEN = os.path.join(ROOT, 'build', 'gen')
# text palettes at boot / in game (palette RAM words 0-63, from the reference)
PAL0 = struct.unpack_from('>64H', Roms().rom0, 0x16ED8)
# (class, arcade palette, pixel values, weight): text RAM survey of cbref0
# runs (attract + a scripted game: race, course map, name entry)
COMBOS = [
    (0, 2, (1, 2, 3, 4, 5, 7), 1254),
    (0, 3, (1, 2, 3, 4, 5, 7), 765),
    (0, 5, (6, 7), 584),
    (0, 1, (1, 2, 3, 4, 5, 7), 532),
    (0, 7, (2, 5), 399),
    (0, 3, (1, 2, 3, 4, 5, 6, 7), 379),
    (0, 6, (6, 7), 210),
    (0, 3, (4, 5, 7), 102),
    (0, 0, (2,), 66),
    (0, 7, (1, 2, 3, 5), 58),
    (0, 7, (1, 2, 3, 4, 5), 50),
    (0, 6, (1, 2, 3, 5), 38),
    (0, 3, (1, 7), 31),
    (0, 6, (1, 4, 5, 6), 28),
    (0, 7, (1, 5, 6, 7), 22),
    (0, 6, (1, 2, 4, 5, 6), 19),
    (0, 6, (1, 4, 5, 7), 19),
    (0, 6, (1, 2, 5, 7), 19),
    (0, 7, (1, 4, 5, 6, 7), 19),
    (0, 7, (1, 2, 3, 5, 6, 7), 19),
    (0, 1, (4, 5, 7), 16),
    (0, 7, (1, 2, 3, 5, 7), 12),
    (0, 6, (1, 2, 3), 8),
    (0, 5, (5, 6), 8),
    (0, 6, (1, 5, 7), 7),
    (0, 7, (1, 2, 3, 4, 5, 6, 7), 7),
    (0, 3, (1, 2, 3, 4, 7), 5),
    (0, 3, (2, 3, 4, 5, 7), 1),
    (1, 6, (1, 7), 1528),
    (1, 4, (1, 2, 4), 1310),
    (1, 4, (1, 2, 3), 1048),
    (1, 4, (1, 2, 5), 1048),
    (1, 2, (1, 2, 3, 4, 5, 7), 793),
    (1, 5, (4, 6), 786),
    (1, 1, (1, 2, 3, 4, 5, 7), 751),
    (1, 6, (1, 2), 592),
    (1, 2, (1, 2, 4), 415),
    (1, 6, (7,), 262),
    (1, 5, (1, 2), 262),
    (1, 1, (1, 2, 7), 248),
    (1, 5, (1,), 131),
    (1, 5, (1, 2, 3), 131),
    (1, 6, (6, 7), 112),
    (1, 1, (1, 2, 4), 97),
    (1, 3, (1, 2, 4), 38),
]


def rgb(w):
    """arcade palette word -> (r, g, b) 0-31 (5 bits + low bit)"""
    r = ((w & 0x0f) << 1) | ((w >> 12) & 1)
    g = (((w >> 4) & 0x0f) << 1) | ((w >> 13) & 1)
    b = (((w >> 8) & 0x0f) << 1) | ((w >> 14) & 1)
    return (r, g, b)


def col(e):
    return rgb(PAL0[e])


def dist(a, b):
    return sum((x - y) ** 2 for x, y in zip(a, b))


def tilepix(R, n):
    t = R.tiles
    px = [[0] * 8 for _ in range(8)]
    for r in range(8):
        b0, b1, b2 = t[n * 8 + r], t[0x10000 + n * 8 + r], t[0x20000 + n * 8 + r]
        for c in range(8):
            bit = 7 - c
            px[r][c] = ((b0 >> bit) & 1) | (((b1 >> bit) & 1) << 1) | (((b2 >> bit) & 1) << 2)
    return px


def reduce3(entries, weights):
    """3 of the entries (arcade palette RAM indices) minimising the weighted
    nearest-colour error of all"""
    if len(entries) <= 3:
        return list(entries)
    best = None
    for reps in itertools.combinations(entries, 3):
        err = sum(weights.get(e, 1) * min(dist(col(e), col(r)) for r in reps) for e in entries)
        if best is None or err < best[0]:
            best = (err, list(reps))
    return best[1]


def cost(entries, weights, slots):
    return sum(weights.get(e, 1) * min(dist(col(e), col(s)) for s in slots) for e in entries)


def build_set(combos):
    """combos [(pal, values, weight)] -> 8 SNES palettes (lists of <= 3
    arcade entries)"""
    pals = []
    for p, vs, w in sorted(combos, key=lambda c: -c[2]):
        entries = [p * 8 + v for v in vs]
        weights = {e: w for e in entries}
        # colours already present (same RGB) in a palette count as present
        best = None
        for i, sl in enumerate(pals):
            have = [e for e in entries if any(col(e) == col(s) for s in sl)]
            miss = [e for e in entries if e not in have]
            # distinct colours to add
            add = []
            for e in miss:
                if not any(col(e) == col(a) for a in add):
                    add.append(e)
            if len(sl) + len(add) <= 3 and (best is None or len(add) < best[0]):
                best = (len(add), i, add)
        if best is not None:
            pals[best[1]] += best[2]
            continue
        if len(pals) < 8:
            uniq = []
            for e in entries:
                if not any(col(e) == col(u) for u in uniq):
                    uniq.append(e)
            pals.append(reduce3(uniq, weights))
            continue
        # no room: shown by the closest palette
    while len(pals) < 8:
        pals.append([0])
    for sl in pals:
        while len(sl) < 3:
            sl.append(sl[-1])
    return pals


def main():
    R = Roms()
    npix = {}
    tp = {}
    for t in range(512):
        px = tilepix(R, t)
        tp[t] = px
        cnt = collections.Counter(v for row in px for v in row if v)
        npix[t] = cnt
    tiles = bytearray()
    snpal = bytearray()
    refs = []
    for cls in (0, 1):
        pals = build_set([(p, vs, w) for c, p, vs, w in COMBOS if c == cls])
        refs.append(pals)
        print('class %d palettes: %s' % (cls, ['/'.join('%d.%d' % (e >> 3, e & 7) for e in sl) for sl in pals]))
        data = bytearray()
        for p in range(8):
            for t in range(512):
                cnt = npix[t]
                entries = {p * 8 + v: n for v, n in cnt.items()}
                if entries:
                    k = min(range(8), key=lambda i: cost(entries, entries, pals[i]))
                else:
                    k = 0
                snpal.append(k)
                sl = pals[k]
                cls_of = [0] * 8
                for v in range(1, 8):
                    cls_of[v] = 1 + min(range(3), key=lambda i: dist(col(p * 8 + v), col(sl[i])))
                for row in tp[t]:
                    lo = hi = 0
                    for c, v in enumerate(row):
                        q = cls_of[v] if v else 0
                        lo |= (q & 1) << (7 - c)
                        hi |= (q >> 1) << (7 - c)
                    data += bytes([lo, hi])
        tiles += data
    assert len(tiles) == 0x20000 and len(snpal) == 8192
    for i in range(4):
        open(os.path.join(GEN, 'txttiles%d.bin' % i), 'wb').write(tiles[i * 0x8000:(i + 1) * 0x8000])
    open(os.path.join(GEN, 'txtsnpal.bin'), 'wb').write(bytes(snpal))
    asm = ['; generated by tools/mktext.py', '.p816']
    for i, b in enumerate(('0B', '0C', '0D', '0E')):
        asm += ['.segment "BANK%s"' % b, '.export TxtTiles%d' % i, 'TxtTiles%d: .incbin "txttiles%d.bin"' % (i, i)]
    asm += ['.segment "BANK0F"', '.export TxtSnPal', 'TxtSnPal: .incbin "txtsnpal.bin"',
            '.segment "RODATA"', '.export TxtRef, TxtPal0', 'TxtRef:']
    for pals in refs:
        asm += ['    .byte %s' % ', '.join(str(e) for e in sl) for sl in pals]
    asm += ['TxtPal0:'] + ['    .word %s' % ', '.join('$%04X' % v for v in PAL0[i:i + 8]) for i in range(0, 64, 8)]
    open(os.path.join(GEN, 'textdat.s'), 'w').write('\n'.join(asm) + '\n')
    open(os.path.join(GEN, 'textdat.inc'), 'w').write(
        '; generated by tools/mktext.py\n.global TxtTiles0, TxtTiles1, TxtTiles2, TxtTiles3, TxtSnPal, TxtRef, TxtPal0\n')


if __name__ == '__main__':
    main()
