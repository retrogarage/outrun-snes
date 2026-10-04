#!/usr/bin/env python3
"""Check sparse BG3 updates against a full rebuild of every clean text row.

Also exhaustively check every possible dirty span in all three column maps.
The runtime probe covers attract, settings, the race HUD and pause/restore.
"""
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
    syms = {p[2].lstrip('.'): int(p[1], 16)
            for line in rom.with_suffix('.sym').read_text().splitlines()
            if len(p := line.split()) == 3}
    data = rom.read_bytes()
    cols = data[syms['ColMap'] - 0x8000:syms['ColMap'] - 0x8000 + 96]
    inverse = data[syms['DirtyCols'] - 0x8000:syms['DirtyCols'] - 0x8000 + 384]
    spans = 0
    for layout in range(3):
        source = [c + 24 for c in cols[layout * 32:layout * 32 + 32]]
        for lo in range(64):
            for hi in range(lo, 64):
                actual = list(range(inverse[layout * 128 + lo * 2],
                                    inverse[layout * 128 + hi * 2 + 1]))
                expected = [i for i, c in enumerate(source) if lo <= c <= hi]
                assert actual == expected, (layout, lo, hi, actual, expected)
                spans += 1
    name = 'text_probe_' + uuid.uuid4().hex
    mesen = os.environ.get('MESEN', str(Path.home() / 'Downloads/Mesen.app/Contents/MacOS/Mesen'))
    with tempfile.TemporaryDirectory(prefix=name) as td:
        td = Path(td)
        local = td / (name + '.sfc')
        local.write_bytes(data)
        out = td / 'result.json'
        lua = r'''
local n,frames,rows,cells,menus,races=0,0,0,0,0,0
local failures={}
local function r(a) return emu.read(a,emu.memType.sa1Memory) end
local function w(a) return r(a)+256*r(a+1) end
local function checkRows()
 frames=frames+1
 local cls=w(@tl_class@)
 local menu=w(@cfg_active@)~=0
 if menu then menus=menus+1 end
 if cls==1 and not menu then races=races+1 end
 for row=0,27 do
  local dirty=w(@txt_dirty@+(row//16)*2)
  if (dirty & (1 << (row%16)))==0 then
   rows=rows+1
   local layout=0
   if not menu then
    if row>=25 then layout=2 elseif cls==1 and row<3 then layout=1 end
   end
   for col=0,31 do
    local source=r(@ColMap@+layout*32+col)
    local code=w(@txt_ram@+(row*64+24+source)*2)
    code=((code&255)<<8)|(code>>8)
    local expected=0
    if (code&511)~=0 then
     local key=code&4095
     local slot=r(0x402000+key)
     expected=slot|((r(@TxtSnPal@+cls*4096+key)&7)<<10)|0x2000
     if slot==0 and #failures<10 then
      table.insert(failures,string.format('%d: clean row %d has an uncached tile',n,row))
     end
    end
    local actual=w(0x40f900+row*64+col*2)
    if actual~=expected and #failures<10 then
     table.insert(failures,string.format('%d: row %d col %d: %04x != %04x',n,row,col,actual,expected))
    end
    cells=cells+1
   end
  end
 end
end
emu.addMemoryCallback(checkRows,emu.callbackType.exec,@PfRenderEnd@,@PfRenderEnd@,emu.cpuType.sa1,emu.memType.sa1Memory)
local presses={[100]='select',[160]='down',[200]='right',[260]='select',[400]='start',[800]='start',[1700]='select',[1760]='right',[1850]='select'}
emu.addEventCallback(function()
 local i={}
 for frame,key in pairs(presses) do if n>=frame and n<frame+12 then i[key]=true end end
 if n>=1000 then i.b=true end
 emu.setInput(i,0)
end,emu.eventType.inputPolled)
emu.addEventCallback(function()
 n=n+1
 if n==2600 then
  local o=io.open(@OUT@,'w')
  o:write(string.format('{"frames":%d,"clean_rows":%d,"cells":%d,"menu_frames":%d,"race_frames":%d,"errors":[',frames,rows,cells,menus,races))
  for i,e in ipairs(failures) do if i>1 then o:write(',') end;o:write(string.format('%q',e)) end
  o:write(']}');o:close();emu.stop(0)
 end
end,emu.eventType.endFrame)
'''
        lua = lua.replace('@OUT@', json.dumps(str(out)))
        for key in ('tl_class', 'cfg_active', 'txt_dirty', 'txt_ram', 'ColMap', 'TxtSnPal', 'PfRenderEnd'):
            value = syms[key] + (0xC10000 if key == 'PfRenderEnd' else 0)
            lua = lua.replace('@' + key + '@', str(value))
        assert '@' not in lua
        script = td / 'probe.lua'
        script.write_text(lua)
        try:
            proc = subprocess.run([mesen, '--testrunner', '--timeout=300', '--doNotSaveSettings',
                                   '--Debug.ScriptWindow.AllowIoOsAccess=true', str(local), str(script)],
                                  capture_output=True, timeout=360)
            assert proc.returncode == 0, (proc.stdout + proc.stderr).decode(errors='replace')[-2000:]
            result = json.loads(out.read_text())
            assert result['menu_frames'] > 0 and result['race_frames'] > 0, result
            assert not result['errors'], result
            result['dirty_spans'] = spans
            print(json.dumps(result, indent=2))
        finally:
            home = Path.home() / 'Library/Application Support/Mesen2'
            for folder, pattern in [('Saves', name + '.srm'), ('Debugger', name + '.cdl'),
                                    ('SaveStates', name + '_*.mss')]:
                for path in (home / folder).glob(pattern):
                    path.unlink()


if __name__ == '__main__':
    main()
