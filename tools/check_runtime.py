#!/usr/bin/env python3
"""Mesen runtime regression probe (stock 100% SA-1 timing).

  python3 tools/check_runtime.py build/outrun_ng.sfc --scenario grid
  python3 tools/check_runtime.py build/outrun_ng.sfc --scenario race --song 2
  python3 tools/check_runtime.py build/outrun_ng.sfc --scenario overtake --song 0

The grid probe measures crowd visibility transitions, not individual limb
pixels. Audio checks track flags, moving sequence pointers and DSP envelopes;
these diagnose the driver but do not replace listening in the target emulator.
The overtake probe moves one active traffic car past the player at a logic
tick boundary, exercising the real overtake event and its sound command.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('rom', type=Path)
    ap.add_argument('--scenario', choices=['grid', 'race', 'overtake'], default='grid')
    ap.add_argument('--song', type=int, choices=[0, 1, 2], default=1)
    ap.add_argument('--frames', type=int, default=1800)
    ap.add_argument('--output', type=Path)
    ap.add_argument('--arcade', action='store_true', help='probe older coin-operated ROMs')
    args = ap.parse_args()
    if not 1200 <= args.frames <= 4500:
        ap.error('--frames must be 1200..4500 (before game-over can stop music)')
    rom = args.rom.resolve()
    syms = {p[2].lstrip('.'): int(p[1], 16) for line in rom.with_suffix('.sym').read_text().splitlines()
            if len(p := line.split()) == 3}
    mesen = os.environ.get('MESEN', str(Path.home() / 'Downloads/Mesen.app/Contents/MacOS/Mesen'))
    name = 'outrun_probe_' + uuid.uuid4().hex
    with tempfile.TemporaryDirectory(prefix=name) as tmp:
        tmp = Path(tmp)
        local_rom = tmp / (name + '.sfc')
        local_rom.write_bytes(rom.read_bytes())
        lua = r'''
local out=io.open(@OUT@,'w')
local n=0
local resets=0
local overtaken=false
local function r(a) return emu.read(a,emu.memType.sa1Memory) end
local function w(a) return r(a)+256*r(a+1) end
local function ar(a) return emu.read(a,emu.memType.spcRam) end
local function shown(ob)
 local s=w(0x40d200+2*ob)
 if (s & 255) ~= (w(@SV_FRAME@) & 255) then return 0 end
 return (s >> 8) & 1
end
emu.addEventCallback(function()
 local inp={}
 if n>=300 and n<360 then @ENTER@ end
 if n>=400 and n<760 then @STEER@ end
 if n>=700 and n<760 then inp.start=true end
 if n>=800 then @ACCEL@ end
 if n>=1100 and n<1110 then @GEAR@ end
 emu.setInput(inp,0)
end,emu.eventType.inputPolled)
emu.addMemoryCallback(function()
 if n<1000 then return end
 local mask=0
 for ob=48,67 do mask=mask | (shown(ob) << (ob-48)) end
 out:write(string.format('S %d %d %d %d\n',n,mask,shown(119),w(@SV_OAM@)))
end,emu.callbackType.exec,@RENDER_END@,@RENDER_END@,emu.cpuType.sa1,emu.memType.sa1Memory)
-- After SndQueueSound stores A in sp_t: count the real traffic RESET path.
emu.addMemoryCallback(function()
 if w(@COMMAND@)==128 and w(@GAME_STATE@)==12 then resets=resets+1 end
end,emu.callbackType.exec,@SOUND_COMMAND@,@SOUND_COMMAND@,emu.cpuType.sa1,emu.memType.sa1Memory)
emu.addMemoryCallback(function()
 if @OVERTAKE@ and n>=1200 and not overtaken and w(@GAME_STATE@)==12 then
  for ob=105,112 do
   local a=@JT@+ob*64
   if (r(a) & 136)==136 then
    -- Z is 16.16; $0300 is safely past the $0200 overtake boundary.
    emu.write(a+32,0,emu.memType.sa1Memory)
    emu.write(a+33,0,emu.memType.sa1Memory)
    emu.write(a+34,0,emu.memType.sa1Memory)
    emu.write(a+35,3,emu.memType.sa1Memory)
    overtaken=true
    break
   end
  end
 end
end,emu.callbackType.exec,@GAME_TICK@,@GAME_TICK@,emu.cpuType.sa1,emu.memType.sa1Memory)
emu.addEventCallback(function()
 n=n+1
 if n>=780 and n%60==0 then
  local active,voices,ptr=0,0,0
  for t=0,12 do
   if (ar(0x200+t) & 128) ~= 0 then active=active+1 end
   ptr=(ptr+ar(0x210+t)+256*ar(0x220+t)) & 65535
  end
  for v=0,7 do
   if ar(0x3b0+v)<13 and emu.read(v*16+8,emu.memType.spcDspRegisters)>0 then voices=voices+1 end
  end
  out:write(string.format('A %d %d %d %d\n',n,active,voices,ptr))
 end
 if n==1000 or n==@FRAMES@ then out:write(string.format('V %d %d\n',n,w(0x37de))) end
 if n==@FRAMES@ then out:write('R '..resets..'\n'); out:close(); emu.stop(0) end
end,emu.eventType.endFrame)
'''
        for k, v in {
            'OUT': json.dumps(str(tmp / 'trace.txt')),
            'ENTER': 'inp.select=true' if args.arcade else 'inp.start=true',
            'STEER': ['inp.left=true', '', 'inp.right=true'][args.song],
            'ACCEL': 'inp.b=true' if args.scenario != 'grid' else '',
            'GEAR': ('inp.a=true' if args.arcade else 'inp.y=true') if args.scenario == 'overtake' else '',
            'COMMAND': syms['sp_t'], 'GAME_STATE': syms['game_state'],
            'SOUND_COMMAND': 0xc10000 + syms['SndQueueSound'] + 6,
            'OVERTAKE': 'true' if args.scenario == 'overtake' else 'false',
            'JT': syms['JT'], 'GAME_TICK': 0xc10000 + syms['GameTick'],
            'SV_FRAME': syms['sv_frame'], 'SV_OAM': syms['sv_oam'],
            'RENDER_END': 0xc10000 + syms['PfRenderEnd'], 'FRAMES': args.frames,
        }.items():
            lua = lua.replace('@' + k + '@', str(v))
        (tmp / 'probe.lua').write_text(lua)
        try:
            subprocess.run([mesen, '--testrunner', '--timeout=180', '--doNotSaveSettings',
                            '--Debug.ScriptWindow.AllowIoOsAccess=true', str(local_rom), str(tmp / 'probe.lua')],
                           check=True, timeout=240, capture_output=True)
            rows = [line.split() for line in (tmp / 'trace.txt').read_text().splitlines()]
        finally:
            # Only this probe's UUID-named emulator artifacts.
            base = Path.home() / 'Library/Application Support/Mesen2'
            for folder, pattern in [('Saves', name + '.srm'), ('Debugger', name + '.cdl'),
                                    ('SaveStates', name + '_*.mss')]:
                for path in (base / folder).glob(pattern):
                    path.unlink()
    spr = [[int(v) for v in p[1:]] for p in rows if p[0] == 'S']
    aud = [[int(v) for v in p[1:]] for p in rows if p[0] == 'A']
    vbl = [[int(v) for v in p[1:]] for p in rows if p[0] == 'V']
    assert len(vbl) == 2 and vbl[-1][0] == args.frames, 'probe did not finish'
    assert spr and aud, 'missing renderer/audio samples'
    result = {
        'rom': str(rom), 'scenario': args.scenario, 'song': args.song,
        'window': [1000, args.frames], 'rendered_frames': len(spr),
        'fps': round(((vbl[1][1] - vbl[0][1]) & 65535) * 60 / (args.frames - 1000), 2),
        'crowd_mean_visible': round(sum(p[1].bit_count() for p in spr) / len(spr), 3),
        'crowd_toggles': sum((a[1] ^ b[1]).bit_count() for a, b in zip(spr, spr[1:])),
        'flag_frames_visible': sum(p[2] for p in spr),
        'max_oam': max(p[3] for p in spr), 'audio_samples': len(aud),
        'audio_active_tracks_min': min(p[1] for p in aud),
        'audio_music_voices_min': min(p[2] for p in aud),
        'audio_distinct_sequence_positions': len({p[3] for p in aud}),
        'overtake_reset_commands': next(int(p[1]) for p in rows if p[0] == 'R'),
    }
    print(json.dumps(result, indent=2))
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + '\n')
    assert result['max_oam'] <= 128, 'OAM overflow'
    assert result['audio_active_tracks_min'] > 0, 'music tracks stopped'
    assert result['audio_distinct_sequence_positions'] > 5, 'music sequencer stalled'
    if args.scenario == 'overtake':
        assert result['overtake_reset_commands'] > 0, 'script did not overtake any traffic'


if __name__ == '__main__':
    main()
