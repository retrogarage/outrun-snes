#!/usr/bin/env python3
"""Check free Start, Select settings, B accelerator, A brake and Y/R gears in Mesen."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('rom', type=Path)
    args = ap.parse_args()
    rom = args.rom.resolve()
    syms = {p[2].lstrip('.'): int(p[1], 16) for line in rom.with_suffix('.sym').read_text().splitlines()
            if len(p := line.split()) == 3}
    mesen = os.environ.get('MESEN', str(Path.home() / 'Downloads/Mesen.app/Contents/MacOS/Mesen'))
    name = 'console_probe_' + uuid.uuid4().hex
    with tempfile.TemporaryDirectory(prefix=name) as td:
        td = Path(td)
        (td / (name + '.sfc')).write_bytes(rom.read_bytes())
        lua = r"""
local out=io.open(@OUT@,'w')
local n=0
local function r(a) return emu.read(a,emu.memType.sa1Memory) end
local function w(a) return r(a)+256*r(a+1) end
emu.addEventCallback(function()
 local inp={}
 if n>=100 and n<160 or n>=220 and n<260 then inp.select=true end
 if n>=300 and n<360 or n>=700 and n<760 then inp.start=true end
 if n>=800 and n<1400 then inp.b=true end
 if n>=1200 and n<1260 then inp.y=true end
 if n>=1400 and n<1500 then inp.a=true end
 if n>=1600 and n<1660 then inp.r=true end
 emu.setInput(inp,0)
end,emu.eventType.inputPolled)
emu.addEventCallback(function()
 n=n+1
 if n==200 or n==500 or n==1100 or n==1300 or n==1480 or n==1700 then
  out:write(string.format('%d %d %d %d %d %d %d %d\n',n,w(@game_state@),r(@credits@),r(@in_keys@+4),r(@in_keys@+5),w(@input_acc@),w(@input_brake@),w(@gear@)))
 end
 if n==1750 then out:close();emu.stop(0) end
end,emu.eventType.endFrame)
"""
        for key, value in syms.items():
            lua = lua.replace('@'+key+'@', str(value))
        lua = lua.replace('@OUT@', json.dumps(str(td/'trace.txt')))
        assert '@' not in lua, 'unresolved probe symbol'
        (td/'test.lua').write_text(lua)
        try:
            subprocess.run([mesen,'--testrunner','--timeout=180','--doNotSaveSettings',
                            '--Debug.ScriptWindow.AllowIoOsAccess=true',str(td/(name+'.sfc')),str(td/'test.lua')],
                           check=True,timeout=240,capture_output=True)
            lines=(td/'trace.txt').read_text().splitlines()
        finally:
            home=Path.home()/'Library/Application Support/Mesen2'
            for folder,pattern in [('Saves',name+'.srm'),('Debugger',name+'.cdl'),('SaveStates',name+'_*.mss')]:
                for f in (home/folder).glob(pattern): f.unlink()
    samples={int(f[0]):list(map(int,f[1:])) for line in lines if (f:=line.split())}
    assert samples[200][1]==0, 'Select added credit'
    assert samples[500][0]==7, 'Start did not enter music selection'
    assert samples[1100][0]==12 and samples[1100][1]==0, 'second Start did not start a free game'
    assert samples[1100][2:4]==[1,0] and samples[1100][4]>0, 'B did not accelerate'
    assert samples[1480][2:4]==[0,1] and samples[1480][5]>0, 'A did not brake'
    assert samples[1300][6]!=samples[1100][6], 'Y did not change gear'
    assert samples[1700][6]==samples[1100][6], 'R did not change gear back'
    print(json.dumps({'console_inputs':'PASS','samples':samples},indent=2))

if __name__=='__main__': main()
