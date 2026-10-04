"""Arcade sprite zoom model (OSprites::do_sprite width/height logic)."""
import os, re
from orroms import Roms

WH_TABLE = 0x20000
_ZL = None


from orroms import zoom_lookup


def sprite_size(R, addr, zoom, draw_props=0):
    """-> (width, height, lod_index, hzoom) as the arcade computes them."""
    ZL = zoom_lookup()
    idx = zoom * 4
    hz = ZL[idx]
    mask = ZL[idx + 1]
    lodoff = ZL[idx + 2]
    src = addr + lodoff
    lw = R.rom0[src + 1]
    lh = R.rom0[src + 3]
    d0 = (draw_props | (zoom << 8)) & 0xFFFF
    top = d0 & 0x8000
    d0 &= 0x7FFF
    if not top:
        if lodoff != 0:
            mask = (mask + 0x4000) & 0xFFFF
            d0 = mask
        w = R.rom0[WH_TABLE + ((d0 & 0xFF00) + lw)]
        h = R.rom0[WH_TABLE + ((d0 & 0xFF00) + lh)]
    else:
        d0 &= 0x7C00
        hh = d0
        w = R.rom0[WH_TABLE + ((d0 & 0xFF00) + lw)] + lw
        h = R.rom0[WH_TABLE + (hh | lh)] + lh
    return w, h, lodoff // 10, hz


if __name__ == "__main__":
    R = Roms()
    a = R.r32(R.rom0, 0x11ED2 + 0)
    for z in list(range(0, 256, 8)) + [255]:
        print(z, sprite_size(R, a, z))
