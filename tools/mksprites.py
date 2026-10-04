"""Build SNES sprite source data for the SA-1 runtime scaler.

Outputs (build/gen):
  sprsrc.s       8bpp LOD source images packed into ROM banks (BANKnn segments)
  sprdir.s       SprFrameDir (32 bytes/frame), SprLevTab (3 bytes per frame*level),
                 SprZtoLev (256 bytes), SprPals (256 palettes, BGR555), fid tables
  sprites.inc    constants (NFRAMES, NLEV, frame ids of interest)
  sprframes.py   python-side metadata (for golden-model tests)

Frame directory entry (32 bytes):
  5 x LOD: +0 w (byte), +1 h (byte), +2 addr (word, $8000-$FFFF), +4 bank (byte), +5 0
           pixel rows (w*h bytes) are followed by h spans [first, last] (2 bytes each)
  +30: zmax level (byte), +31: 0
Level table entry (4 bytes) per (frame, level):
  +0 word: dst_w (SNES px, 0..511) | lod << 12
  +2 word: dst_h (lines)
"""
import os
import sys
import numpy as np
from orroms import Roms, pal_to_bgr15
from sprites import frame_lods, decode_lod
from sprzoom import sprite_size
import sprinv

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GEN = os.path.join(ROOT, "build", "gen")
SPR_PALS = 0x14ED8
PASS_FRAMES = 0xA6EC
SHADOW_DATA = 0x103B6
SHADOW_COLOR = 0x0842        # BGR555 dark grey used for shadows
FIRST_BANK = 64            # file bank (32KB units) -> LoROM $80
LAST_BANK = 127
XSCALE = 205 / 256          # arcade 320 px -> SNES 256 px
IMPORTANT_FRAMES = [0x106F4, 0x10726, 0x107A8, 0x1082A, 0x1085C, 0x1088E, 0x11AEA, 0x11B1C]
BANNER_FRAMES = [0x106F4, 0x10726, 0x1082A, 0x11AEA, 0x11B1C]
BANNER_LEFT = [0x106F4, 0x11AEA]        # halves meet at their inner edges
BANNER_RIGHT = [0x10726, 0x11B1C]
# crash animation tables in ROM0 (8-byte entries: frame address, 4 property bytes)
CRASH_BASE = 0x2294
CRASH_END = 0x26A0
CRASH_TABLES = [("SPIN1", 0x2294, 8), ("SPIN2", 0x22D4, 8), ("BUMP1", 0x2314, 3), ("BUMP2", 0x232C, 3),
                ("MAN1", 0x2344, 14), ("GIRL1", 0x23B4, 14), ("FLIP", 0x2424, 8),
                ("FLIPM1", 0x2464, 15), ("FLIPM2", 0x24DC, 10), ("FLIPG1", 0x255C, 15),
                ("FLIPG2", 0x25D4, 6), ("MAN2", 0x2604, 8), ("GIRL2", 0x2660, 8)]
DATA_MOVEMENT = 0x30800
# animation sequences (ROM0): pointer tables, timeline table, 8-byte frame entries
ANIM_BASE = 0x12382
ANIM_END = 0x14ED8
ANIM_END_TABLE = 0x123A2
ANIM_END_ENTRIES = (0x124B0 - 0x123A2) // 2
ANIM_PTR_TABS = [(0x12382, 8)] + [(a, 10) for a in (0x124B0, 0x124D8, 0x12500, 0x12528, 0x12550, 0x12578,
                                                   0x125A0, 0x125C8, 0x125F0, 0x12618)]
ANIM_NAMES = [("FLAG", 0x12382), ("END_TABLE", 0x123A2), ("OBJ1", 0x124B0), ("OBJ2", 0x124D8), ("OBJ3", 0x12500),
              ("OBJ4", 0x12528), ("OBJ5", 0x12550), ("OBJ6", 0x12578), ("OBJ7", 0x125A0), ("OBJ8", 0x125C8),
              ("OBJA", 0x125F0), ("OBJB", 0x12618), ("FER_CURR", 0x12970), ("FER_NEXT", 0x129C0),
              ("PASS1_CURR", 0x129C8), ("PASS1_NEXT", 0x12A18), ("PASS2_CURR", 0x12A20), ("PASS2_NEXT", 0x12A70)]


def anim_blocks(R):
    """animation blocks reachable from the pointer tables: addr -> frame addresses"""
    ptrs = [R.r32(R.rom0, a + 4 * i) for a, n in ANIM_PTR_TABS for i in range(n)]
    ptrs += [a for nm, a in ANIM_NAMES if nm.startswith(("FER_", "PASS"))]
    blocks = {}
    for a in ptrs:
        if a in blocks:
            continue
        n = 0
        fr = []
        while True:
            fr.append(R.r32(R.rom0, a + 8 * n) & 0xFFFFF)
            e7 = R.rom0[a + 8 * n + 7]
            n += 1
            if e7 & 0x80 or n > 64:
                break
        assert ANIM_BASE <= a and a + 8 * n <= ANIM_END
        blocks[a] = fr
    return blocks
MUSIC_FRAMES = [0x118D8, 0x118CE, 0x11892, 0x1189C, 0x118A6, 0x118B0, 0x118BA, 0x118C4,
                0x118E2, 0x118EC, 0x118F6]


def level_set():
    """Zoom indices with an image each: every Z up to 16, then 8% / 12% / 16%
    steps (coarser for big images, which are expensive to re-render)."""
    zs = list(range(4, 17))
    z = 16
    while True:
        r = 1.08 if z < 64 else (1.12 if z < 128 else 1.16)
        n = max(z + 1, int(round(z * r)))
        if n > 255:
            break
        zs.append(n)
        z = n
    if zs[-1] != 255:
        zs.append(255)
    # exact full-size level ($7F: music select, logo, ... sprites drawn unscaled)
    zs = sorted(set(zs) | {127})
    return zs


LEVELS = level_set()
NLEV = len(LEVELS)


def z_to_level():
    """zoom index 0..255 -> level (largest level with Z_k <= z); z<4 -> 0 (caller hides)."""
    out = []
    for z in range(256):
        k = 0
        for i, zk in enumerate(LEVELS):
            if zk <= z:
                k = i
        out.append(k)
    return out


def trim_ropes(img, left):
    """Blank the thin ropes at the outer end of a banner half: they cost whole
    OBJ columns against the 34 slivers/line limit for a few pixels."""
    img = img.copy()
    h, w = img.shape
    cols = range(w) if left else range(w - 1, -1, -1)
    thr = max(2, h // 5)
    for c in cols:
        if np.count_nonzero(img[:, c]) > thr:
            break
        img[:, c] = 0
    return img


def lod_image(R, lod):
    """8bpp image exactly lod.w x lod.h (0 = transparent)."""
    w, h = lod["w"], lod["h"]
    img = decode_lod(R, lod)
    out = np.zeros((h, w), dtype=np.uint8)
    hh = min(h, img.shape[0])
    ww = min(w, img.shape[1])
    out[:hh, :ww] = img[:hh, :ww]
    return out


def scale_image(src, dw, dh):
    """Nearest-neighbour scale, same mapping as the SA-1 renderer."""
    sh, sw = src.shape
    if dw <= 0 or dh <= 0 or sw == 0 or sh == 0:
        return np.zeros((max(dh, 0), max(dw, 0)), dtype=np.uint8)
    xs = [(((2 * x + 1) * sw * 256) // (2 * dw)) >> 8 for x in range(dw)]
    ys = [(((2 * y + 1) * sh * 256) // (2 * dh)) >> 8 for y in range(dh)]
    xs = [min(v, sw - 1) for v in xs]
    ys = [min(v, sh - 1) for v in ys]
    return src[np.ix_(ys, xs)]


class Builder:
    def __init__(self):
        self.R = Roms()
        self.frames = []          # arcade addresses in fid order
        self.fid = {}
        self.zmax = {}

    def add_frame(self, fa, zmax=255):
        if fa not in self.fid:
            self.fid[fa] = len(self.frames)
            self.frames.append(fa)
            self.zmax[fa] = zmax
        else:
            self.zmax[fa] = max(self.zmax[fa], zmax)
        return self.fid[fa]

    def collect(self):
        inv = sprinv.collect()
        for fa in sorted(inv):
            self.add_frame(fa, min(inv[fa]["zmax"], 255))
        R = self.R
        # player passengers (hair frames) and the car shadow
        self.pass_fids = [self.add_frame(R.r32(R.rom0, PASS_FRAMES + 4 * i), 255) for i in range(4)]
        self.shadow_fid = self.add_frame(SHADOW_DATA, 255)
        self.flags = {self.shadow_fid: 1}      # bit0: render dithered (shadow)
        # music select screen: radio, EQ, FM readout L/C/R, dial L/C/R, hand L/C/R
        self.music_fids = [self.add_frame(a, 0x7F) for a in MUSIC_FRAMES]
        # course map mini car: right, up, down
        self.map_fids = [self.add_frame(a, 0x7F) for a in (0x10C58, 0x10C62, 0x10C6C)]
        # attract logo: oval, car, bird1, bird2, road base, text, palm1-3
        self.logo_fids = [self.add_frame(a, 0x7F) for a in
                          (0x11162, 0x1128E, 0x112C0, 0x112F2, 0x1125C, 0x11194, 0x111C6, 0x111F8, 0x1122A)]
        # animation sequences (flag man, intro, 5 end sequences)
        self.anim_blocks = anim_blocks(R)
        for a, fr in sorted(self.anim_blocks.items()):
            for fa in fr:
                self.add_frame(fa, 255)
                # end sequence objects are few but big: OBJ VRAM first
                self.flags[self.fid[fa]] = self.flags.get(self.fid[fa], 0) | 2
        # crash sequences: car spin/bump/flip frames, thrown passengers
        self.crash_frames = set()
        for name, a, n in CRASH_TABLES:
            for i in range(n):
                fa = R.r32(R.rom0, a + 8 * i)
                self.add_frame(fa, 255)
                self.crash_frames.add(fa)
                if name in ("SPIN1", "SPIN2", "BUMP1", "BUMP2", "FLIP"):
                    self.flags[self.fid[fa]] = self.flags.get(self.fid[fa], 0) | 2
        # bit1: important (road-spanning gantries/banners get OBJ VRAM first)
        # bit2: banner (reserves before the other important frames)
        for fa in IMPORTANT_FRAMES:
            if fa in self.fid:
                self.flags[self.fid[fa]] = self.flags.get(self.fid[fa], 0) | 2 | (4 if fa in BANNER_FRAMES else 0) | \
                    (8 if fa in BANNER_LEFT else 0) | (16 if fa in BANNER_RIGHT else 0)

    def build(self):
        R = self.R
        banks = []                # list of bytearrays
        cur = bytearray()
        dir_entries = []
        placed = {}               # (bank, off) cache by (fa, lod)
        for fa in self.frames:
            lods = frame_lods(R, fa)
            ent = []
            for li, lod in enumerate(lods):
                key = (lod["bank"], lod["off"], lod["w"], lod["h"], lod["pitch"])
                if key in placed:
                    ent.append(placed[key])
                    continue
                img = lod_image(R, lod)
                if fa in BANNER_LEFT or fa in BANNER_RIGHT:
                    img = trim_ropes(img, fa in BANNER_LEFT)
                # pixel rows followed by per-row opaque span [first, last] (first > last = empty)
                spans = bytearray()
                for row in img:
                    nz = np.nonzero(row)[0]
                    if len(nz):
                        spans += bytes([int(nz[0]), int(nz[-1])])
                    else:
                        spans += bytes([255, 0])
                blob = img.tobytes() + bytes(spans)
                if len(blob) > 0x8000:
                    raise ValueError("LOD too big %x" % fa)
                if len(cur) + len(blob) > 0x8000:
                    banks.append(cur)
                    cur = bytearray()
                addr = 0x8000 + len(cur)
                bank = FIRST_BANK + len(banks)
                cur += blob
                e = (lod["w"], lod["h"], addr, bank)
                placed[key] = e
                ent.append(e)
            dir_entries.append(ent)
        banks.append(cur)
        if FIRST_BANK + len(banks) - 1 > LAST_BANK:
            raise ValueError("sprite sources overflow ROM")
        self.banks = banks
        self.dir = dir_entries
        # level table
        lev = []
        for fa in self.frames:
            row = []
            for z in LEVELS:
                w, h, lodi, hz = sprite_size(R, fa, z)
                dw = max(1, int(round(w * XSCALE))) if w else 0
                row.append((dw, h, lodi))
            lev.append(row)
        self.lev = lev

    def snes_bank(self, b):
        return b if b < 64 else 0x80 + (b - 64)

    def write(self):
        os.makedirs(GEN, exist_ok=True)
        # sources
        with open(os.path.join(GEN, "sprsrc.s"), "w") as f:
            for i, blob in enumerate(self.banks):
                fn = "sprsrc_%02x.bin" % (FIRST_BANK + i)
                open(os.path.join(GEN, fn), "wb").write(bytes(blob))
                f.write('.segment "BANK%02X"\n.incbin "%s"\n' % (FIRST_BANK + i, fn))
        # directory, levels, palettes
        d = bytearray()
        for fi, ent in enumerate(self.dir):
            for (w, h, addr, bank) in ent:
                d += bytes([w, h, addr & 0xFF, addr >> 8, self.snes_bank(bank), 0])
            zm = self.zmax[self.frames[fi]]
            kmax = max(i for i, z in enumerate(LEVELS) if z <= zm)
            d += bytes([kmax, getattr(self, "flags", {}).get(fi, 0)])
        open(os.path.join(GEN, "sprdir.bin"), "wb").write(bytes(d))
        lv = bytearray()
        for row in self.lev:
            for (dw, dh, lodi) in row:
                # 3 bytes: dst_w (9 bits) | lod << 9 | dst_h << 12
                assert dw < 512 and dh < 4096
                v = dw | (lodi << 9) | (dh << 12)
                lv += bytes([v & 0xFF, (v >> 8) & 0xFF, v >> 16])
        open(os.path.join(GEN, "sprlev.bin"), "wb").write(bytes(lv))
        z2l = bytes(z_to_level())
        open(os.path.join(GEN, "sprz2l.bin"), "wb").write(z2l)
        pals = bytearray()
        R = self.R
        for p in range(256):
            for c in range(16):
                w = R.r16(R.rom0, SPR_PALS + p * 32 + c * 2)
                v = pal_to_bgr15(w)
                pals += bytes([v & 0xFF, v >> 8])
        # palette 256: shadow (all entries dark)
        pals += bytes([0, 0]) + bytes([SHADOW_COLOR & 0xFF, SHADOW_COLOR >> 8]) * 15
        open(os.path.join(GEN, "sprpals.bin"), "wb").write(bytes(pals))
        R = self.R
        tf = bytearray()
        for t in range(256):
            fa = R.r32(R.rom0, sprinv.TYPE_TABLE + t * 4)
            v = self.fid.get(fa, 0xFFFF)
            tf += bytes([v & 0xFF, v >> 8])
        open(os.path.join(GEN, "sprtypefid.bin"), "wb").write(bytes(tf))
        with open(os.path.join(GEN, "sprdir.s"), "w") as f:
            f.write('.export SprFrameDir, SprZtoLev, SprPals, SprTypeFid\n')
            f.write('.segment "BANK08"\n')
            f.write('SprFrameDir: .incbin "sprdir.bin"\n')
            f.write('SprZtoLev: .incbin "sprz2l.bin"\n')
            f.write('SprPals: .incbin "sprpals.bin"\n')
            f.write('SprTypeFid: .incbin "sprtypefid.bin"\n')
            # FirstFit[wu-1][mask]: first column c with wu free units at c..c+wu-1, $FF none
            ff = bytearray()
            for wu in range(1, 9):
                run = (1 << wu) - 1
                for m in range(256):
                    col = 0xFF
                    for c in range(0, 9 - wu):
                        if (m >> c) & run == 0:
                            col = c
                            break
                    ff.append(col)
            open(os.path.join(GEN, "firstfit.bin"), "wb").write(bytes(ff))
            f.write('.segment "BANK08"\n.export FirstFit\nFirstFit: .incbin "firstfit.bin"\n')
            f.write('.segment "RODATA"\n.export PassFid, ShadowFid\n')
            f.write('PassFid: .word %s\n' % ",".join(str(v) for v in self.pass_fids))
            f.write('ShadowFid: .word %d\n' % self.shadow_fid)
            f.write('.export MusicFid\nMusicFid: .word %s\n' % ",".join(str(v) for v in self.music_fids))
            f.write('.export MapFid\nMapFid: .word %s\n' % ",".join(str(v) for v in self.map_fids))
            f.write('.export LogoFid\nLogoFid: .word %s\n' % ",".join(str(v) for v in self.logo_fids))
            f.write('.export LogoMove\nLogoMove: .byte %s\n' % ",".join("$%02X" % b for b in self.R.rom0[DATA_MOVEMENT:DATA_MOVEMENT + 256]))
            # crash tables: ROM0 $2294-$269F with frame addresses replaced by frame ids
            R = self.R
            blob = bytearray(R.rom0[CRASH_BASE:CRASH_END])
            for name, a, n in CRASH_TABLES:
                for i in range(n):
                    o = a - CRASH_BASE + 8 * i
                    fid = self.fid[R.r32(R.rom0, a + 8 * i)]
                    blob[o:o + 4] = bytes([fid & 0xFF, fid >> 8, 0, 0])
            open(os.path.join(GEN, "crashdata.bin"), "wb").write(bytes(blob))
            mv = bytes(R.rom0[DATA_MOVEMENT + 8 * i] for i in range(16))
            f.write('.segment "BANK08"\n.export CrashData, CrashMove\n')
            f.write('CrashData: .incbin "crashdata.bin"\n')
            f.write('CrashMove: .byte %s\n' % ",".join("$%02X" % b for b in mv))
            # animation data: ROM0 ANIM_BASE..ANIM_END, pointers -> offsets, frames -> ids
            ab = bytearray(R.rom0[ANIM_BASE:ANIM_END])
            for a, n in ANIM_PTR_TABS:
                for i in range(n):
                    o = a - ANIM_BASE + 4 * i
                    t = R.r32(R.rom0, a + 4 * i) - ANIM_BASE
                    ab[o:o + 4] = bytes([t & 0xFF, t >> 8, 0, 0])
            for i in range(ANIM_END_ENTRIES):            # timeline: big endian -> little endian
                o = ANIM_END_TABLE - ANIM_BASE + 2 * i
                ab[o], ab[o + 1] = ab[o + 1], ab[o]
            for a, fr in self.anim_blocks.items():
                for k, fa in enumerate(fr):
                    o = a - ANIM_BASE + 8 * k
                    fid = self.fid[fa]
                    ab[o + 1] &= 0xF0
                    ab[o + 2] = fid & 0xFF
                    ab[o + 3] = fid >> 8
            open(os.path.join(GEN, "animdata.bin"), "wb").write(bytes(ab))
            f.write('.segment "BANK09"\n.export AnimData\nAnimData: .incbin "animdata.bin"\n')
            # level table spans file banks 4-5 = HiROM view $C2:0000 (64KB linear)
            assert len(lv) <= 0x10000
            f.write('.segment "BANK04"\n')
            f.write('.incbin "sprlev.bin", 0, %d\n' % min(len(lv), 0x8000))
            if len(lv) > 0x8000:
                f.write('.segment "BANK05"\n')
                f.write('.incbin "sprlev.bin", $8000\n')
            f.write('SprLevTab = $C20000\n')
        with open(os.path.join(GEN, "sprites.inc"), "w") as f:
            f.write("NFRAMES = %d\nNLEV = %d\n" % (len(self.frames), NLEV))
            f.write(".global SprFrameDir, SprZtoLev, SprPals, SprTypeFid, FirstFit\nSprLevTab = $C20000\n")
            f.write(".global CrashData, CrashMove, AnimData\n")
            for name, a in ANIM_NAMES:
                f.write("AN_%s = $%04X\n" % (name, a - ANIM_BASE))
            for name, a, n in CRASH_TABLES:
                f.write("CR_%s = $%04X\n" % (name, a - CRASH_BASE))
        with open(os.path.join(GEN, "sprframes.py"), "w") as f:
            f.write("FRAMES = %r\nLEVELS = %r\n" % (self.frames, LEVELS))
        tot = sum(len(b) for b in self.banks)
        print("frames %d, levels %d, source bytes %d (%d banks), levtab %d bytes" %
              (len(self.frames), NLEV, tot, len(self.banks), len(lv)))


if __name__ == "__main__":
    B = Builder()
    B.collect()
    B.build()
    B.write()
