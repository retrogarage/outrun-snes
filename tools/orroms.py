"""OutRun (Rev B, US) arcade ROM set loader and basic hardware-format decoders.

Loads verified MAME-style ROM files from OUTRUN_ROM_DIR (or build/input) and exposes the combined
program/graphics regions the way the arcade hardware sees them.
"""
import os
import struct
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROMDIR = os.environ.get("OUTRUN_ROM_DIR", os.path.join(ROOT, "build", "input"))


def _rd(name):
    with open(os.path.join(ROMDIR, name), "rb") as f:
        return f.read()


def _interleave2(dst, name, start):
    d = _rd(name)
    dst[start:start + len(d) * 2:2] = d


class Roms:
    def __init__(self):
        # Main (master) 68000
        self.rom0 = bytearray(0x40000)
        _interleave2(self.rom0, "epr-10380b.133", 0x00000)
        _interleave2(self.rom0, "epr-10382b.118", 0x00001)
        _interleave2(self.rom0, "epr-10381b.132", 0x20000)
        _interleave2(self.rom0, "epr-10383b.117", 0x20001)
        # Sub 68000 (road CPU)
        self.rom1 = bytearray(0x40000)
        _interleave2(self.rom1, "epr-10327a.76", 0x00000)
        _interleave2(self.rom1, "epr-10329a.58", 0x00001)
        _interleave2(self.rom1, "epr-10328a.75", 0x20000)
        _interleave2(self.rom1, "epr-10330a.57", 0x20001)
        # Tiles: 3 bitplanes, each 0x10000
        t = bytearray()
        for n in ["opr-10268.99", "opr-10232.102", "opr-10267.100",
                  "opr-10231.103", "opr-10266.101", "opr-10230.104"]:
            t += _rd(n)
        self.tiles = bytes(t)
        # Road (two identical copies)
        self.road = _rd("opr-10185.11") + _rd("opr-10186.47")
        # Sprites: 8 ROMs interleaved by 4 bytes
        spr = bytearray(0x100000)
        names = ["mpr-10371.9", "mpr-10373.10", "mpr-10375.11", "mpr-10377.12",
                 "mpr-10372.13", "mpr-10374.14", "mpr-10376.15", "mpr-10378.16"]
        for i, n in enumerate(names):
            d = _rd(n)
            base = 0 if i < 4 else 0x80000
            spr[base + (i & 3):base + (i & 3) + len(d) * 4:4] = d
        self.sprites_raw = bytes(spr)
        # 32-bit words, little-endian assembly as in the sprite chip
        self.sprites = np.frombuffer(self.sprites_raw, dtype="<u4")
        # Z80 sound program
        self.z80 = _rd("epr-10187.88")
        # SegaPCM samples: 6 x 32K at 64K strides
        pcm = bytearray(0x60000)
        for i, n in enumerate(["opr-10193.66", "opr-10192.67", "opr-10191.68",
                               "opr-10190.69", "opr-10189.70", "opr-10188.71"]):
            d = _rd(n)
            pcm[i * 0x10000:i * 0x10000 + len(d)] = d
        self.pcm = bytes(pcm)

    # --- big endian helpers (68000) ---
    def r8(self, rom, a):
        return rom[a]

    def s8(self, rom, a):
        v = rom[a]
        return v - 256 if v >= 128 else v

    def r16(self, rom, a):
        return (rom[a] << 8) | rom[a + 1]

    def s16(self, rom, a):
        v = self.r16(rom, a)
        return v - 65536 if v >= 32768 else v

    def r32(self, rom, a):
        return (rom[a] << 24) | (rom[a + 1] << 16) | (rom[a + 2] << 8) | rom[a + 3]

    def s32(self, rom, a):
        v = self.r32(rom, a)
        return v - (1 << 32) if v >= (1 << 31) else v


def decode_tiles(roms):
    """Return array [ntiles, 8, 8] of 3bpp pixel values."""
    t = np.frombuffer(roms.tiles, dtype=np.uint8)
    p0 = t[0x00000:0x10000]
    p1 = t[0x10000:0x20000]
    p2 = t[0x20000:0x30000]
    bits = np.arange(7, -1, -1)
    px = (((p0[:, None] >> bits) & 1) |
          (((p1[:, None] >> bits) & 1) << 1) |
          (((p2[:, None] >> bits) & 1) << 2))
    return px.reshape(-1, 8, 8).astype(np.uint8)


def decode_road(roms):
    """Return array [512, 512] of 2bpp road pixels (rows 0-255 road0, 256-511 road1)."""
    r = roms.road
    out = np.zeros((512, 512), dtype=np.uint8)
    for y in range(512):
        src = (y & 0xff) * 0x40 + (y >> 8) * 0x8000
        row0 = np.frombuffer(r[src:src + 0x40], dtype=np.uint8)
        row1 = np.frombuffer(r[src + 0x4000:src + 0x4040], dtype=np.uint8)
        bits = np.arange(7, -1, -1)
        b0 = ((row0[:, None] >> bits) & 1).reshape(-1)
        b1 = ((row1[:, None] >> bits) & 1).reshape(-1)
        out[y] = b0 | (b1 << 1)
    return out


def pal_to_rgb(w):
    """Sega OutRun palette word -> (r,g,b) 8-bit. Ignores shade bit."""
    r = ((w >> 0) & 0x0f) << 1 | ((w >> 12) & 1)
    g = ((w >> 4) & 0x0f) << 1 | ((w >> 13) & 1)
    b = ((w >> 8) & 0x0f) << 1 | ((w >> 14) & 1)
    return (r * 255 // 31, g * 255 // 31, b * 255 // 31)


def pal_to_bgr15(w):
    """Sega palette word -> SNES BGR555 word."""
    r = ((w >> 0) & 0x0f) << 1 | ((w >> 12) & 1)
    g = ((w >> 4) & 0x0f) << 1 | ((w >> 13) & 1)
    b = ((w >> 8) & 0x0f) << 1 | ((w >> 14) & 1)
    return r | (g << 5) | (b << 10)


def sprite_line(roms, bank, addr, backwards=False, maxwords=64):
    """Decode one sprite line starting at word address (bank, addr).
    Returns list of pixel nibbles (including 0 = transparent, excluding end markers).
    """
    base = bank * 0x10000
    pix = []
    a = addr
    for _ in range(maxwords):
        w = int(roms.sprites[base + (a & 0xffff)])
        if not backwards:
            nib = [(w >> s) & 0xf for s in (28, 24, 20, 16, 12, 8, 4, 0)]
            pix.extend(nib)
            if (w & 0x000000f0) == 0x000000f0:
                break
            a += 1
        else:
            nib = [(w >> s) & 0xf for s in (0, 4, 8, 12, 16, 20, 24, 28)]
            pix.extend(nib)
            if (w & 0x0f000000) == 0x0f000000:
                break
            a -= 1
    return pix


if __name__ == "__main__":
    R = Roms()
    print("rom0 %x rom1 %x tiles %x road %x sprites %x z80 %x pcm %x" % (
        len(R.rom0), len(R.rom1), len(R.tiles), len(R.road), len(R.sprites_raw), len(R.z80), len(R.pcm)))
    print("rom0 reset SSP %08x PC %08x" % (R.r32(R.rom0, 0), R.r32(R.rom0, 4)))
    print("rom1 reset SSP %08x PC %08x" % (R.r32(R.rom1, 0), R.r32(R.rom1, 4)))


def zoom_lookup(roms=None):
    """Rev B zoom table, with the two CannonBall zoom corrections."""
    roms = roms or Roms()
    values = list(struct.unpack_from('>1024H', roms.rom0, 0x30000))
    values[67 * 4] = 0x03C2
    values[68 * 4] = 0x03B6
    return values
