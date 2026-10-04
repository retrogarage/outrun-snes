#!/usr/bin/env python3
"""Pre-shrunk sprite images for the SNES sprite backend v3 (src/sprv3.s).

Every arcade sprite frame (the 1142 frame descriptors of rom0 $F236-$11ED1,
10 bytes each: +2 rows, +4 pitch in words, +7 bank, +8 offset) is rendered
offline at a set of hardware zooms (hz = vz, 128 values $100-$3F0 from
ZOOM_LOOKUP), horizontal scale 0.8, arcade colour indices kept (palette
independent).  Draw modes: 0 normal, 1 shadow sprite (every opaque pixel
is shadow), 2 hw shadow bit (colour 10 is shadow); shadow pixels -> colour
15 (black in every palette), checkerboard dithered.  Images are stored in
normal orientation (mirrored frames use the OBJ h-flip), cut into bands of
16 rows, a band into 16x16 pieces covering its opaque columns (greedy from
the left, any x); at most MAXPC pieces (a bigger level is not stored).

Levels per variant (descriptor, mode):
  - zooms seen in the traces (tools/sprv3use.txt, made from cbref0 traces
    of attract, the 16 autopilot routes and 12 random-steering games):
    covered with ratio QN (hz >= $200, up to 1:1) / QE (hz < $200,
    enlarged); the stored zoom of a group is the seen zoom nearest to the
    group's geometric middle;
  - all descriptors: sparse levels (ratio QS) over $200-$3F0, so that any
    request has an image nearby (modes not seen use the mode 0 / 2 map);
  - a zoom without its level shows the nearest stored level (log scale),
    centred / bottom-anchored on the exact size by the backend.

ROM layout (8 MB SA-1 cartridge, Super MMC, file banks of 32 KB):
  metadata  file banks $40.. = LoROM $80:8000.. (fixed block 2: the SA-1
            reads it while EXB is switched)
  pixels    64 KB banks after the metadata up to 8 MB, and the free 64 KB
            banks EXTRA_FB of blocks 0-1 (first-fit decreasing: an image
            never crosses a 64 KB bank); the S-CPU DMAs them through the
            HiROM $E0-$EF window with EXB = the 1 MB block (main.s UqStream)
  SprPal / tables: file banks $06 / $07 (LoROM $06:8000 / $07:8000)

Band data: [top halves: TL TR of each piece][bottom halves: BL BR of each
piece] (4bpp planar tiles): a run of pieces in consecutive VRAM cells of one
cell row (tiles 2c.., 2c+16..) uploads with two DMAs.

Metadata (words little endian):
  DescIdx  (page 0, SPR_META): word at byte offset x = src - $F236 (x = 10 i):
           the descriptor record's address (bank $80)
  DescRec  (page 0, DREC bytes): npx (arcade px width of the widest row),
           rows, pitch, offset, map address per mode 0/1/2 (3 words), map
           bank per mode (3 bytes, 0 none), class (1: landmark, [W1b])
  maps     per variant: 128 bytes (zoom index -> level), then per level the
           image number (word)
  images   16 bytes each, 2048 per page from SPR_IMGB: W, full H,
           NB | signed leading-row offset << 8, blob address, blob bank,
           pixel block (EXB), pixel offset, pixel bank ($E0-$EF), flags,
           NP. Flags: bit 0 roof on BG, bit 1 pieces use only their left 8px.
           The signed offset crops/pads the top of BG arches to align their feet.
  blobs    per image: (NB + 1) words cumulative first piece per band, then
           NP words piece x offsets
  tables   HzIdx (hw zoom -> zoom index), SprKW / SprKH (exact size factors),
           AreaLog, RunAt / MaxRun (cell runs), X08 (x * 0.8)
Output: build/gen/sprdat3.s / sprdat3.inc, sprmeta.bin, sprpix.bin,
sprpal.bin, sprzt.bin.  Prints the statistics.  ROM-derived: stays local.
"""
import math, os, sys, hashlib, collections
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from orroms import Roms, pal_to_bgr15

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GEN = os.path.join(ROOT, 'build', 'gen')
QN = float(os.environ.get('SPR3_QN', '1.08'))
QE = float(os.environ.get('SPR3_QE', '1.12'))
QS = float(os.environ.get('SPR3_QS', '1.30'))
D0, D1 = 0xF236, 0x11ED2
ARCH_D = (D1 - D0) // 10
START_PALM_D = ARCH_D + 15
ND = START_PALM_D + 5
D1 = D0 + ND * 10
ARCH_W, ARCH_H, ARCH_CAP, ARCH_BEAM = 608, 152, 31, 47
ARCH_OBJ_W = 256               # complete OBJ image; wider roofs use BG
ARCH_PALS = ((0x5F, 0x61), (0xA1, 0xA2), (0xC4, 0xC6))
META_FB = 0x40                  # first metadata file bank (LoROM $80:8000)
ROM_END = 0x800000
PAGE = 0x8000
DREC = 18                       # descriptor record size
# [W1b] landmark frames (class byte of the descriptor record: the backend
# places them before other objects of the same size): the START / GOAL /
# CHECK banners, the signal tower, the checkpoint gantry pillars, the
# billboard tower of the start, the road split signs (5 frames of each, by
# distance)
LANDMARK = set(range(531, 541)) | set(range(1042, 1052)) | set(range(562, 567)) | \
    set(range(572, 577)) | set(range(481, 486)) | set(range(417, 422))
# [W1c] (the START's signal / billboard towers 567-571 / 549-553 no longer
# landmarks: the palms and the people near the camera matter as much there)
# people of the START / GOAL crowds and the START's towers: class 3 (the
# backend's key x 8: small, but what the scene is about)
PEOPLE = set(range(1057, 1065)) | set(range(567, 572)) | set(range(549, 554))
MAXPC = 256                     # pieces per image (the backend's piece -> cell maps)
# [W1c] overhead banners the backend can also show on a BG layer (src/ohb.inc
# K2: the START and GOAL banners, two halves): class 2 (also a landmark), their
# pieces on a 16 px grid from the image's left edge (the piece tiles are then
# BG tiles of one map)
BGPAIR = set(range(531, 541)) | set(range(1042, 1052))
# [W1c] palette substitution (src/sprv3.s PalSubst): an entry whose palette
# has no OBJ slot may use a loaded one that has the same colours in every
# index its frame uses (DescIdx + 2: the frame's colour mask); per palette two
# candidates (most equal colours, at least SUBMIN) with their difference masks.
# The START crowd's people palettes stand in for each other (mask 0: their
# clothes take another person's colours rather than nobody showing).
SUBMIN = 8
PEOPLE_PALS = [0xBE, 0xBF, 0xC0, 0xC1]
EXTRA_FB = (0x04, 0x08, 0x2A, 0x3E)   # free 64 KB banks of blocks 0-1 (file banks) for pixel data


def zoom_lookup():
    from orroms import zoom_lookup as read_zoom
    return read_zoom()[::4]


class Frames:
    def __init__(self, R):
        self.R = R
        self.sw = R.sprites.astype(np.uint32)
        self.cache = {}
        self.arch_pillars = {}

    def desc(self, i):
        if i >= START_PALM_D:
            return self.desc(245 + i - START_PALM_D)
        if i >= ARCH_D:
            h = self.desc(417 + (i - ARCH_D) % 5)['rows']
            return dict(rows=math.ceil(ARCH_H*h/121), pitch=0, bank=0, off=0)
        r = self.R.rom0
        a = D0 + 10 * i
        w = lambda o: (r[a + o] << 8) | r[a + o + 1]
        return dict(rows=w(2), pitch=w(4), bank=r[a + 7] & 3, off=w(8))

    def rows(self, i):
        if i in self.cache:
            return self.cache[i]
        if i >= START_PALM_D:
            # The selected start palms share a crowded scene with the banner,
            # towers and people. Drop only their baked ground shadows;
            # keep every tree pixel and all ordinary roadside palm art.
            self.cache[i] = [np.where(row == 10, 0, row).astype(np.uint8)
                             for row in self.rows(245 + i - START_PALM_D)]
            return self.cache[i]
        if i >= ARCH_D:
            # One silhouette owns the whole arch. A separate pillar-only
            # variant puts the roof on BG at the same origin and scale.
            pillar = self.rows(417)
            a = np.zeros((ARCH_H, ARCH_W), dtype=np.uint8)
            pillars = np.zeros_like(a)
            beam_pal, pillar_pal = ARCH_PALS[(i-ARCH_D)//5]
            def palette(p):
                r = self.R.rom0
                return np.array([[(v >> k) & 31 for k in (0, 5, 10)] for c in range(16)
                                 for v in [pal_to_bgr15((r[0x14ED8+p*32+c*2] << 8) |
                                                        r[0x14ED9+p*32+c*2])]])
            src, dst = palette(beam_pal), palette(pillar_pal)
            cmap = np.array([0] + [1 + np.argmin(((dst[1:15]-src[c])**2).sum(axis=1))
                                   for c in range(1, 16)], dtype=np.uint8)
            beam = self.rows(422)
            for y in range(ARCH_BEAM):
                row = beam[y][50:200] if y < 44 else beam[y][13:97]
                a[y] = cmap[row[np.arange(ARCH_W) % len(row)]]
            for y, row in enumerate(pillar):
                pillars[y+ARCH_CAP, :len(row)] = row
                pillars[y+ARCH_CAP, ARCH_W-len(row):] = row[::-1]
            a = np.where(pillars, pillars, a)
            h = self.desc(417+(i-ARCH_D)%5)['rows']
            hh, ww = self.desc(i)['rows'], math.ceil(ARCH_W*h/121)
            yy = np.minimum(np.arange(hh)*ARCH_H//hh,ARCH_H-1)[:,None]
            xx = np.minimum(np.arange(ww)*ARCH_W//ww,ARCH_W-1)
            a = a[yy, xx]
            self.arch_pillars[i] = list(pillars[yy, xx])
            self.cache[i] = list(a)
            return self.cache[i]
        d = self.desc(i)
        base = d['bank'] * 0x10000
        out = []
        for y in range(d['rows']):
            a = (d['off'] + y * d['pitch']) & 0xFFFF
            px = []
            for k in range(64):
                ww = int(self.sw[base + ((a + k) & 0xFFFF)])
                px.extend((ww >> s) & 15 for s in (28, 24, 20, 16, 12, 8, 4, 0))
                if (ww & 0xF0) == 0xF0:
                    break
            p = np.array(px, dtype=np.uint8)
            p[p == 15] = 0
            out.append(p)
        self.cache[i] = out
        return out

    def npx(self, i):
        return max((len(r) for r in self.rows(i)), default=0)

    def has10(self, i):
        return any((r == 10).any() for r in self.rows(i))

    def render(self, i, hz, mode):
        rows = self.rows(i)
        if ARCH_D <= i < START_PALM_D and (mode == 2 or math.ceil(len(rows[0])*409.6/hz) > ARCH_OBJ_W):
            rows = self.arch_pillars[i]
            mode = 0              # arch mode 2 means a shared BG roof
        n = len(rows)
        if n == 0:
            return np.zeros((0, 0), dtype=np.uint8)
        H = int(math.ceil(n * 512 / hz))
        h = hz * 1.25
        out = []
        for y in range(H):
            s = rows[min((y * hz) >> 9, n - 1)]
            nout = int(math.ceil(len(s) * 512 / h))
            k = np.arange(nout)
            out.append(s[np.minimum((k * h / 512).astype(int), len(s) - 1)])
        W = max(len(o) for o in out)
        a = np.zeros((H, W), dtype=np.uint8)
        for y, o in enumerate(out):
            a[y, :len(o)] = o
        if ARCH_D <= i < START_PALM_D and H > 224:
            # Objects are ground-anchored at or above line 223. These whole
            # bands are always above the viewport, even with a cached level.
            a[:((H-224)//16)*16] = 0
        if mode:
            # shadow pixels (mode 1: all opaque ones, mode 2: colour 10):
            # colour 15 (black), checkerboard dithered
            yy, xx = np.indices(a.shape)
            sh = (a != 0) if mode == 1 else (a == 10)
            a = np.where(sh, np.where(((xx + yy) & 1) == 0, 15, 0), a).astype(np.uint8)
        return a


def band_pieces(a, grid=False):
    """-> per band: piece x offsets (greedy cover of the opaque columns;
    [W1c] grid: the 16 px columns with an opaque pixel)"""
    H, W = a.shape
    bands = []
    for b in range(0, H, 16):
        cols = np.nonzero(a[b:b + 16].any(axis=0))[0]
        xs, j = [], 0
        if grid:
            xs = sorted(set(int(c) // 16 * 16 for c in cols))
            bands.append(xs)
            continue
        while j < len(cols):
            x0 = int(cols[j])
            xs.append(x0)
            while j < len(cols) and cols[j] < x0 + 16:
                j += 1
        bands.append(xs)
    return bands


def tiles4(blocks):
    """(N, 8, 8) pixel blocks -> N * 32 bytes SNES 4bpp"""
    blocks = np.asarray(blocks, dtype=np.uint8)
    pl = [np.packbits((blocks >> k) & 1, axis=2).reshape(-1, 8) for k in range(4)]
    out = np.zeros((len(blocks), 32), dtype=np.uint8)
    out[:, 0:16:2], out[:, 1:16:2] = pl[0], pl[1]
    out[:, 16:32:2], out[:, 17:32:2] = pl[2], pl[3]
    return out.tobytes()


def image_data(a, bands):
    """-> per band: [TL TR of each piece][BL BR of each piece]"""
    H, W = a.shape
    pad = np.zeros((len(bands) * 16, W + 32), dtype=np.uint8)
    pad[:H, :W] = a
    out = []
    for b, xs in enumerate(bands):
        y = b * 16
        top = [pad[y + r:y + r + 8, x + c:x + c + 8] for x in xs for (r, c) in ((0, 0), (0, 8))]
        bot = [pad[y + r:y + r + 8, x + c:x + c + 8] for x in xs for (r, c) in ((8, 0), (8, 8))]
        out.append(tiles4(top) + tiles4(bot) if xs else b'')
    return out


def cover(hzs, q):
    """groups of zooms within ratio q -> one stored zoom per group (the seen
    zoom nearest to the group's geometric middle)"""
    hzs = sorted(set(hzs))
    lv, i = [], 0
    while i < len(hzs):
        j = i
        while j < len(hzs) and hzs[j] <= hzs[i] * q:
            j += 1
        grp = hzs[i:j]
        g = math.sqrt(grp[0] * grp[-1])
        lv.append(min(grp, key=lambda v: abs(math.log(v / g))))
        i = j
    return lv


def main():
    R = Roms()
    F = Frames(R)
    ZL = zoom_lookup()
    HZS = sorted(set(z for z in ZL if z))
    assert len(HZS) == 128 and HZS[0] == 0x100 and HZS[-1] == 0x3F0
    use = collections.defaultdict(set)
    for line in open(os.path.join(ROOT, 'tools', 'sprv3use.txt')):
        t = line.split('#')[0].split()
        if len(t) >= 3:
            i, m = int(t[0]), int(t[1])
            if m == 2 and not F.has10(i):
                m = 0                   # (colour 10 unused: the normal image)
            use[(i, m)].add(int(t[2]))
    # Driving replays leave the flag man behind before his final idle
    # poses. Walk every start animation block, including its idle loop,
    # so colour 10 remains a dithered shadow when the player waits.
    for off in range(0, 24, 4):
        addr = R.r32(R.rom0, 0x12382 + off)  # ANIM_SEQ_FLAG
        for frame in range(128):
            p = addr + frame * 8
            src = R.r32(R.rom0, p) & 0xFFFFF
            assert D0 <= src < D0 + ARCH_D * 10 and (src-D0) % 10 == 0
            i = (src-D0) // 10
            use[(i, 2 if F.has10(i) else 0)].add(ZL[100])  # start z=400, zoom=z/4
            if R.rom0[p+7] & 0x80:
                break
        else:
            raise ValueError('unterminated flag animation')
    for k in range(15):
        use[(ARCH_D+k, 0)].update(use.get((417+k%5, 0), set()))
        use[(ARCH_D+k, 0)].update(use.get((417+k%5, 2), set()))
    for k in range(15):
        use[(ARCH_D+k, 2)].update(use[(ARCH_D+k, 0)])
    for k in range(5):
        use[(START_PALM_D+k, 0)].update(use.get((245+k, 0), set()))
        use[(START_PALM_D+k, 0)].update(use.get((245+k, 2), set()))
    # The separate arch pieces only need descriptor geometry now. Retain
    # sparse images for diagnostic builds, reclaiming their large unused
    # zoom levels for complete composites within the same 8 MB cartridge.
    for key in list(use):
        if 417 <= key[0] < 427:
            del use[key]
    # ---- levels per variant (descriptor, mode) ----
    variants = sorted(set(use) | set((i, 0) for i in range(ND) if not any((i, m) in use for m in (0, 2))))
    levels = {}
    nobs = nsp = 0
    for key in variants:
        seen = sorted(use.get(key, ()))
        lv = set(cover([v for v in seen if v >= 0x200], QN)) | set(cover([v for v in seen if v < 0x200], QE))
        near = lambda v: any(abs(math.log(v / l)) < math.log(QS) / 2 for l in lv)
        sp = cover([v for v in HZS if v >= 0x200 and not near(v)], QS)
        nobs += len(lv)
        nsp += len(sp)
        levels[key] = sorted(lv | set(sp))
    # ---- images (deduplicated) ----
    images = []                     # (W, H, bands, data per band)
    ihash = {}
    vmap = {}                       # key -> list of 128 image numbers
    for key in variants:
        i, mode = key
        ids = {}
        for hz in levels[key]:
            a = F.render(i, hz, mode)
            if a.size == 0 or not a.any():
                continue
            grid = i in BGPAIR
            bgroof = int(ARCH_D <= i < START_PALM_D and (mode == 2 or a.shape[1] > ARCH_OBJ_W))
            full_h = a.shape[0]
            yoff = int(np.nonzero(a.any(axis=1))[0][0]) if bgroof else 0
            a = a[yoff:]
            if bgroof:
                # Anchor tile bands to the feet. Padding below a short pillar
                # needlessly competes with the player car on lower scanlines.
                pad = (-a.shape[0]) % 8
                if pad:
                    a = np.pad(a, ((pad, 0), (0, 0)))
                    yoff -= pad
            hsh = hashlib.sha1(bytes([a.shape[0] & 255, a.shape[0] >> 8, a.shape[1] & 255, a.shape[1] >> 8, grid, bgroof, yoff & 255]) + a.tobytes()).digest()
            n = ihash.get(hsh)
            if n is None:
                bands = band_pieces(a, grid)
                if sum(len(xs) for xs in bands) > MAXPC:
                    continue            # (too many pieces: a smaller level is shown)
                if (bgroof or 776 <= i <= 800 or a.shape[1] <= 8) and all(not a[y:y+16, x+8:x+16].any()
                                  for y, xs in zip(range(0, a.shape[0], 16), bands) for x in xs):
                    bgroof |= 2  # narrow pillar/passenger or thin distant scenery
                n = len(images)
                images.append((a.shape[1], full_h, bands, image_data(a, bands), bgroof, yoff))
                ihash[hsh] = n
            ids[hz] = n
        if not ids:
            continue
        lv = sorted(ids)
        vmap[key] = ([lv.index(min(lv, key=lambda l: (abs(math.log(hz / l)), l))) for hz in HZS],
                     [ids[l] for l in lv])
    # ---- metadata pages ----
    meta = bytearray()

    def alloc(n, align=1):
        """n bytes inside one 32 KB page -> file offset in meta"""
        nonlocal meta
        o = (len(meta) + align - 1) // align * align
        if o // PAGE != (o + n - 1) // PAGE:
            o = (o // PAGE + 1) * PAGE
        meta += bytes(o + n - len(meta))
        return o

    def lorom(o):
        """meta offset -> (LoROM bank, address)"""
        return 0x80 + META_FB - 0x40 + o // PAGE, 0x8000 + o % PAGE

    desc_idx = alloc(D1 - D0 + 10, 2)
    desc_rec = alloc(ND * DREC, 8)
    assert lorom(desc_idx)[0] == lorom(desc_rec)[0] == 0x80
    maps = {}
    for key in variants:
        if key not in vmap:
            continue
        m, lst = vmap[key]
        o = alloc(128 + 2 * len(lst), 2)
        maps[key] = o
        meta[o:o + 128 + 2 * len(lst)] = bytes(m) + b''.join(v.to_bytes(2, 'little') for v in lst)
    img_rec = alloc(0, PAGE)
    img_page0 = img_rec // PAGE
    for k in range((len(images) * 16 + PAGE - 1) // PAGE):
        alloc(min(PAGE, len(images) * 16 - k * PAGE), PAGE)
    blobs = []
    for W, H, bands, data, bgroof, yoff in images:
        cum = [0]
        for xs in bands:
            cum.append(cum[-1] + len(xs))
        blob = b''.join(c.to_bytes(2, 'little') for c in cum) + b''.join(x.to_bytes(2, 'little') for xs in bands for x in xs)
        o = alloc(len(blob), 2)
        meta[o:o + len(blob)] = blob
        blobs.append(o)
    meta_end = (len(meta) + 0xFFFF) // 0x10000 * 0x10000
    meta += bytes(meta_end - len(meta))
    # descriptor index / records
    for i in range(ND):
        o = desc_idx + 10 * i
        meta[o:o + 2] = (desc_rec % PAGE + 0x8000 + DREC * i).to_bytes(2, 'little')
        # [W1c] the frame's colour mask (bit c: colour c used; 1-14)
        cm = 0
        for r in F.rows(i):
            for c in set(int(v) for v in np.unique(r)):
                if 1 <= c <= 14:
                    cm |= 1 << c
        meta[o + 2:o + 4] = cm.to_bytes(2, 'little')
        d = F.desc(i)
        # map per mode; a mode not seen uses the normal / colour 10 one
        m = {k: lorom(maps[(i, k)]) for k in (0, 1, 2) if (i, k) in maps}
        m.setdefault(0, m.get(2, (0, 0)))
        m.setdefault(2, m[0])
        m.setdefault(1, (0, 0))
        rec = b''.join(v.to_bytes(2, 'little') for v in (F.npx(i), d['rows'], d['pitch'], d['off'],
                                                          m[0][1], m[1][1], m[2][1])) + \
            bytes([m[0][0], m[1][0], m[2][0], 2 if i in BGPAIR else 1 if i in LANDMARK else 3 if i in PEOPLE else 4 if ARCH_D <= i < START_PALM_D else 0])
        assert len(rec) == DREC
        meta[desc_rec + DREC * i:desc_rec + DREC * (i + 1)] = rec
    # ---- pixel data: first-fit decreasing into 64 KB banks ----
    base = META_FB * PAGE + meta_end
    banks = [base + b * 0x10000 for b in range((ROM_END - base) // 0x10000)] + [fb * PAGE for fb in EXTRA_FB]
    nbank = len(banks)
    free = [0x10000] * nbank
    where = [None] * len(images)
    for n in sorted(range(len(images)), key=lambda n: -sum(len(d) for d in images[n][3])):
        size = sum(len(d) for d in images[n][3])
        for b in range(nbank):
            if free[b] >= size:
                where[n] = banks[b] + (0x10000 - free[b])
                free[b] -= size
                break
        else:
            raise SystemExit('sprite data does not fit (%d banks)' % nbank)
    used = [b for b in range(nbank) if free[b] < 0x10000]
    pix = bytearray(b'\xff' * (len(used) * 0x10000))
    slot = {banks[b]: k * 0x10000 for k, b in enumerate(used)}
    for n, (W, H, bands, data, bgroof, yoff) in enumerate(images):
        o = slot[where[n] & ~0xFFFF] + (where[n] & 0xFFFF)
        blob = b''.join(data)
        pix[o:o + len(blob)] = blob
        fo = where[n]
        bm, bo = lorom(blobs[n])
        rec = W.to_bytes(2, 'little') + H.to_bytes(2, 'little') + (len(bands) | (yoff & 255) << 8).to_bytes(2, 'little') + \
            bo.to_bytes(2, 'little') + bytes([bm, fo >> 20]) + (fo & 0xFFFF).to_bytes(2, 'little') + \
            bytes([0xE0 + ((fo >> 16) & 15), bgroof]) + sum(len(xs) for xs in bands).to_bytes(2, 'little')
        ro = img_rec + 16 * n
        meta[ro:ro + 16] = rec
    # ---- palettes, zoom tables ----
    r16 = lambda a: (R.rom0[a] << 8) | R.rom0[a + 1]
    pal = bytearray()
    for p in range(256):
        for c in range(16):
            v = 0 if c in (0, 15) else pal_to_bgr15(r16(0x14ED8 + p * 32 + c * 2))
            pal += v.to_bytes(2, 'little')
    hzi = bytearray(0x400)
    for z in range(0x400):
        hzi[z] = min(range(128), key=lambda k: abs(HZS[k] - max(z, 0x100)))
    # W_e = npx * KW >> 14 (SNES px), H_e = rows * KH >> 13 (lines)
    kw = b''.join(int(math.ceil(409.6 * 16384 / v)).to_bytes(2, 'little') for v in HZS)
    kh = b''.join(int(math.ceil(512 * 8192 / v)).to_bytes(2, 'little') for v in HZS)
    # AreaLog: v -> floor(2 * log2(v)) (0 for 0, 1); RunAt: [mask * 8 + k - 1] = first
    # bit position p with bits p .. p + k - 1 of mask set ($FF none)
    alog = bytes([0 if v < 2 else int(math.floor(2 * math.log2(v) + 1e-9)) for v in range(256)])
    runat = bytearray()
    for m in range(256):
        for k in range(1, 9):
            runat.append(next((p for p in range(9 - k) if all(m >> (p + q) & 1 for q in range(k))), 0xFF))
    maxrun = bytes([max((k for k in range(9) if any(all(m >> (p + q) & 1 for q in range(k)) for p in range(9 - k))), default=0) for m in range(256)])
    # X08: arcade sprite x ($000-$3FF, right-to-left ones below $80 already
    # moved up by $200) -> SNES x of the first drawn pixel: (x - $BE) * 0.8
    x08 = b''.join((((x - 0xBE) * 3277) >> 12 & 0xFFFF).to_bytes(2, 'little') for x in range(0x400))
    # [W1c] PalSubT: per palette two substitutes (pal_src, $FF none) and the
    # masks of the colours that differ
    P = [[r16(0x14ED8 + p * 32 + c * 2) for c in range(16)] for p in range(256)]
    sub = bytearray()
    for p in range(256):
        if p in PEOPLE_PALS:
            cand = [(0, q) for q in PEOPLE_PALS if q != p][:2]
        else:
            cand = sorted(((sum(1 for c in range(1, 15) if P[p][c] != P[q][c]), q) for q in range(256)
                           if q != p and any(P[q][1:15])), key=lambda t: (t[0], t[1]))
            cand = [(d, q) for d, q in cand if 14 - d >= SUBMIN][:2]
        ent = []
        for d, q in cand:
            m = 0 if p in PEOPLE_PALS else sum(1 << c for c in range(1, 15) if P[p][c] != P[q][c])
            ent.append((q, m))
        while len(ent) < 2:
            ent.append((0xFF, 0xFFFF))
        sub += bytes([ent[0][0], ent[1][0]]) + ent[0][1].to_bytes(2, 'little') + ent[1][1].to_bytes(2, 'little')
    zt = bytes(hzi) + kw + kh + alog + bytes(runat) + maxrun + x08 + bytes(sub)
    os.makedirs(GEN, exist_ok=True)
    open(os.path.join(GEN, 'sprmeta.bin'), 'wb').write(meta)
    open(os.path.join(GEN, 'sprpix.bin'), 'wb').write(pix)
    open(os.path.join(GEN, 'sprpal.bin'), 'wb').write(bytes(pal))
    open(os.path.join(GEN, 'sprzt.bin'), 'wb').write(zt)
    asm = ['; generated by tools/mksprv3.py', '.p816',
           '.segment "BANK06"', '.export SprPal', 'SprPal: .incbin "sprpal.bin"',
           '.segment "BANK07"', '.export HzIdx, SprKW, SprKH',
           'HzIdx: .incbin "sprzt.bin", 0, $400    ; hw zoom -> zoom index (0-127)',
           'SprKW: .incbin "sprzt.bin", $400, 256  ; per zoom index: 409.6 * 16384 / hz',
           'SprKH: .incbin "sprzt.bin", $500, 256  ; per zoom index: 512 * 8192 / hz',
           '.export AreaLog, RunAt',
           'AreaLog: .incbin "sprzt.bin", $600, 256 ; v -> floor(2 log2 v)',
           'RunAt: .incbin "sprzt.bin", $700, $800  ; [mask * 8 + k - 1]: first run of k set bits',
           '.export MaxRun',
           'MaxRun: .incbin "sprzt.bin", $F00, 256 ; mask -> longest run of set bits',
           '.export X08',
           'X08: .incbin "sprzt.bin", $1000, $800  ; arcade x -> (x - $BE) * 0.8 (SNES x)',
           '.export PalSubT',
           'PalSubT: .incbin "sprzt.bin", $1800, $600 ; [W1c] per palette: 2 substitutes, 2 difference masks']
    for k in range(len(meta) // PAGE):
        asm += ['.segment "BANK%02X"' % (META_FB + k), '.incbin "sprmeta.bin", $%X, $8000' % (k * PAGE)]
    for k, b in enumerate(used):
        for h in range(2):
            asm += ['.segment "BANK%02X"' % (banks[b] // PAGE + h), '.incbin "sprpix.bin", $%X, $8000' % (k * 0x10000 + h * PAGE)]
    open(os.path.join(GEN, 'sprdat3.s'), 'w').write('\n'.join(asm) + '\n')
    inc = ['; generated by tools/mksprv3.py',
           'SPR_D0 = $%X            ; first frame descriptor (rom0)' % D0,
           'SPR_META = $%02X8000    ; DescIdx (LoROM, fixed block 2)' % lorom(desc_idx)[0],
           'SPR_IMGB = $%02X        ; LoROM bank of image record page 0 (2048 records a page)' % (0x80 + img_page0),
           'SPR_NIMG = %d' % len(images),
           'SPR_DN = %d                ; frame descriptors' % ND,
           'ARCH_D = %d' % ARCH_D,
           'START_PALM_D = %d' % START_PALM_D,
           'ARCH_W = %d' % ARCH_W,
           'ARCH_H = %d' % ARCH_H,
           'ARCH_BEAM = %d' % ARCH_BEAM,
           'ARCH_OBJ_W = %d' % ARCH_OBJ_W,
           '.global SprPal, HzIdx, SprKW, SprKH, AreaLog, RunAt, MaxRun, X08, PalSubT']
    open(os.path.join(GEN, 'sprdat3.inc'), 'w').write('\n'.join(inc) + '\n')
    npc = sum(sum(len(xs) for xs in im[2]) for im in images)
    nb = sum(len(im[2]) for im in images)
    print('sprv3: %d variants, levels %d seen + %d sparse, %d images, %d bands, %d pieces (%.2f MB), '
          'metadata %d KB, pixel banks %d (to file offset $%X of $%X)'
          % (len(variants), nobs, nsp, len(images), nb, npc, npc * 128 / 2 ** 20, len(meta) // 1024,
             len(used), max(banks[b] for b in used) + 0x10000, ROM_END))
    print('max pieces per image %d, per band %d, max W %d, max H %d, max bands %d' % (
        max(sum(len(xs) for xs in im[2]) for im in images), max(len(xs) for im in images for xs in im[2]),
        max(im[0] for im in images), max(im[1] for im in images), max(len(im[2]) for im in images)))


if __name__ == '__main__':
    main()
