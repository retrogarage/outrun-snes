#!/usr/bin/env python3
"""Generate formerly inline arcade tables from the user's verified Rev B ROMs."""
from pathlib import Path
import struct
from orroms import Roms, zoom_lookup

GEN = Path(__file__).resolve().parents[1] / 'build/gen'


def emit(name, values, words=False):
    directive, width = ('word', 4) if words else ('byte', 2)
    lines = ['; Generated locally from user-supplied assets. Do not distribute.']
    for i in range(0, len(values), 8):
        lines.append('    .' + directive + ' ' + ', '.join(
            f'${v:0{width}X}' for v in values[i:i + 8]))
    (GEN / f'asset_{name}.inc').write_text('\n'.join(lines) + '\n')


def main():
    rom = Roms().rom0
    for name, address, size, words in [
        ('rev_inc_lookup', 0x30C80, 256, False),
        ('torque_lookup', 0x6C4E, 64, True),
        ('RouteMapping', 0x8BB4, 80, False),
        ('OnroadSmoke', 0xAC4E, 40, False),
        ('OffroadSmoke', 0xAC9E, 40, False),
        ('lap_ms', 0x8114, 64, False),
        ('TIME', 0xE31A, 40, False),
        ('Convert', 0xBF3E, 42, True),
        ('TrafficType', 0x4CBA, 64, False),
    ]:
        data = rom[address:address + size]
        emit(name, struct.unpack(f'>{size // 2}H', data) if words else data, words)

    # The console's Easy mode adds 20 BCD seconds, capped at 99.
    easy = []
    for value in rom[0xE342:0xE342 + 40]:
        decimal = min(99, (value >> 4) * 10 + (value & 15) + 20) if value else 0
        easy.append((decimal // 10) * 16 + decimal % 10)
    emit('CfgTimes', easy + list(rom[0xE31A:0xE31A + 40]) + list(rom[0xE36A:0xE36A + 40]))

    # Compile the HUD rev-counter algorithm into its compact ten-cell rows.
    cells = []
    for revs in range(21):
        for i in range(1, 20, 2):
            color = 0x600 if i >= 14 else 0x400 if i <= 9 else 0x200
            cells.append((0x81FD if revs > i else 0x81FE) | color
                         if revs >= i else 0x8520)
    emit('RevCells', cells, True)

    zoom = zoom_lookup()
    lines = ['; Generated locally; do not distribute.']
    for label, values in [('ZVz', zoom[::4]), ('ZOff', zoom[2::4]),
                          ('ZWh', [zoom[i * 4 + 1] + 0x4000 if zoom[i * 4 + 2]
                                   else i << 8 for i in range(256)])]:
        lines.append(label + ':')
        lines.extend('    .word ' + ','.join(f'${n:04X}' for n in values[i:i+8])
                     for i in range(0, 256, 8))
    (GEN / 'asset_zoom.inc').write_text('\n'.join(lines) + '\n')


if __name__ == '__main__':
    main()
