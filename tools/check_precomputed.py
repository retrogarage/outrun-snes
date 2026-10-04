#!/usr/bin/env python3
"""Validate linked sprite sizes and every road-key equivalence class.

With --probe-rom, also execute SetupXData for every covered path position
in a NEWGAME / ROADKEYCHECK ROM and compare all 448 writes byte for byte.
"""
import argparse
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import uuid

from mkroadkeys import GEN, projection


def symbols(rom):
    return {p[2].lstrip('.'): int(p[1], 16) for line in rom.with_suffix('.sym').read_text().splitlines()
            if len(p := line.split()) == 3}


def probe(rom, td):
    syms = symbols(rom)
    name = 'roadkeys_' + uuid.uuid4().hex
    local = td / (name + '.sfc')
    local.write_bytes(rom.read_bytes())
    output = td / 'writes.bin'
    lua = '''local out=io.open(@OUT@,'wb')
local function r(a) return emu.read(a,emu.memType.sa1Memory) end
emu.addMemoryCallback(function()
 local bytes={r(@SEC@),r(@SEC@+1),r(@POS@),r(@POS@+1)}
 for i=0,895 do bytes[#bytes+1]=r(0x41F000+i) end
 out:write(string.char(table.unpack(bytes)))
end,emu.callbackType.exec,@SAMPLE@,@SAMPLE@,emu.cpuType.sa1,emu.memType.sa1Memory)
emu.addMemoryCallback(function()out:close();emu.stop(0)end,emu.callbackType.exec,
 @END@,@END@,emu.cpuType.sa1,emu.memType.sa1Memory)
'''
    for key, value in {'OUT': json.dumps(str(output)), 'SEC': syms['rk_section'],
                       'POS': syms['rk_pos'], 'SAMPLE': 0xC10000 + syms['RoadKeySample'],
                       'END': 0xC10000 + syms['RoadKeyEnd']}.items():
        lua = lua.replace('@' + key + '@', str(value))
    script = td / 'probe.lua'
    script.write_text(lua)
    mesen = os.environ.get('MESEN', str(Path.home() / 'Downloads/Mesen.app/Contents/MacOS/Mesen'))
    try:
        subprocess.run([mesen, '--testrunner', '--timeout=600', '--doNotSaveSettings',
                        '--Debug.ScriptWindow.AllowIoOsAccess=true', str(local), str(script)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=660)
        return output.read_bytes()
    finally:
        home = Path.home() / 'Library/Application Support/Mesen2'
        for sub, pattern in [('Saves', name + '.srm'), ('Debugger', name + '.cdl'),
                             ('SaveStates', name + '_*.mss')]:
            for file in (home / sub).glob(pattern):
                file.unlink(missing_ok=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('rom', type=Path)
    ap.add_argument('--probe-rom', type=Path)
    args = ap.parse_args()
    rom = args.rom.resolve()
    image, syms = rom.read_bytes(), symbols(rom)
    def word(off):
        return struct.unpack_from('<H', image, off)[0]
    meta, zoom = (GEN / 'sprmeta.bin').read_bytes(), (GEN / 'sprzt.bin').read_bytes()
    ndesc = int(re.search(r'SPR_DN = (\d+)', (GEN / 'sprdat3.inc').read_text())[1])
    sizes = 0
    for desc in range(ndesc):
        off = struct.unpack_from('<H', meta, desc*10)[0] - 0x8000
        for axis, (label, factoroff, shift) in enumerate([('SprWidthOfs', 0x400, 14),
                                                        ('SprHeightOfs', 0x500, 13)]):
            size = struct.unpack_from('<H', meta, off + axis*2)[0]
            ptr = word(0xF0000 + syms[label] + size*2)
            assert ptr != 0xFFFF
            for k in range(128):
                factor = struct.unpack_from('<H', zoom, factoroff + k*2)[0]
                # MR+1 discards eight product bits before adding the round
                # constant. In product units that bias is 2**shift - 256.
                expected = (size*factor + (1 << shift) - 256) >> shift
                actual = word(0xF0000 + ptr + k*2)
                assert actual == expected, ('size', desc, axis, k, actual, expected)
                sizes += 1
    sections = re.findall(r'\.faraddr RawPath_([0-9A-F]+)', (GEN / 'road2.s').read_text())
    data = {}
    expected_by_key = {}
    expected_by_position = {}
    positions = 0
    for section, name in enumerate(sections[:17]):
        raw = (GEN / f'road2_path_{name}.bin').read_bytes()
        words = struct.unpack(f'<{len(raw)//2}h', raw)
        data[section] = words
        off = syms['RoadKeySections'] - 0x8000 + section*5
        ptr = int.from_bytes(image[off:off+3], 'little')
        count = word(off+3)
        assert count == len(words)//2 - 65
        keyoff = (ptr >> 16)*0x8000 + (ptr & 0x7FFF)
        for pos in range(count):
            result = projection(words, pos)
            key = word(keyoff + pos*2)
            assert expected_by_key.setdefault(key, result) == result, ('road key collision', section, pos, key)
            expected_by_position[section, pos] = result
            positions += 1
    checked = 0
    if args.probe_rom:
        with tempfile.TemporaryDirectory(prefix='roadkey_check_') as td:
            records = probe(args.probe_rom.resolve(), Path(td))
        assert len(records) == positions*900, ('incomplete emulator probe', len(records), positions*900)
        for off in range(0, len(records), 900):
            section, pos = struct.unpack_from('<HH', records, off)
            expected = expected_by_position.pop((section, pos))
            actual = records[off+4:off+900]
            if actual != expected:
                index = next(i for i in range(448) if actual[i*2:i*2+2] != expected[i*2:i*2+2])
                raise AssertionError(('projection', section, pos, index,
                                      struct.unpack_from('<h', actual, index*2)[0],
                                      struct.unpack_from('<h', expected, index*2)[0]))
            checked += 1
        assert not expected_by_position
    print(json.dumps({'sprite_sizes_checked': sizes, 'road_positions': positions,
                      'road_equivalence_classes': len(expected_by_key),
                      'emulated_projections_checked': checked}, indent=2))


if __name__ == '__main__':
    main()
