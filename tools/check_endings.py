#!/usr/bin/env python3
"""Exercise complete endings in an AUTOPILOT/FREEZE_TIMER ROM using Mesen.

The fixture selects a final stage at normal stage initialization, then drives
through its goal, animation and exit. No animation or renderer state is forced.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid


LUA = r'''
local n,started,frames,maxpos=0,false,0,0
local errors,seen,staged,shots,actors={},{},{},{},{}
local banners,whole,interiors,extra,stands=0,0,0,0,0
local missing,visible={},{}
local function r(a) return emu.read(a,emu.memType.sa1Memory) end
local function w(a) return r(a)+256*r(a+1) end
local function wr(a,v) emu.write(a,v&255,emu.memType.sa1Memory);emu.write(a+1,(v>>8)&255,emu.memType.sa1Memory) end
local function ex(a,fn) emu.addMemoryCallback(fn,emu.callbackType.exec,a,a,emu.cpuType.sa1,emu.memType.sa1Memory) end
local function active() return r(@end_seq_state@)==1 and w(@game_state@)==14 end
local function bad(msg)
 if not seen[msg] and #errors<20 then seen[msg]=true;table.insert(errors,n..': '..msg) end
end
emu.addMemoryCallback(function(a)
 if w(@game_state@)~=14 then return end
 if (a&65535)<32768 then bad('image metadata read from unmapped LoROM: '..string.format('%06X',a)) end
end,emu.callbackType.read,0x8b0000,0x8f7fff,emu.cpuType.sa1,emu.memType.sa1Memory)
emu.addEventCallback(function()
 local i={};if n>=300 and n<360 or n>=700 and n<760 then i.start=true end;emu.setInput(i,0)
end,emu.eventType.inputPolled)
ex(@IeInitRoadSegMaster@,function()
 if w(@game_state@)==8 and not started then
  started=true;wr(@cur_stage@,4);wr(@stage_lookup_off@,32+@END@)
 end
end)
ex(@ArchPrepare@,function() staged={};visible={} end)
ex(@SprVisible@,function() visible[w(@w_obj@)]=true end)
ex(@ArchDraw@,function()
 if not active() then return end
 local ob=w(@w_obj@)
 if (w(@w_nst@)&1)==0 then return end
 local count=(w(@w_st@)-0xe000)//4-w(@w_prf@)
 staged[ob]=true
 local desc=(w(@w_dsc@)-w(0x808000))//18
 if w(@w_car@)>0 then
  whole=whole+1;actors[ob]=(actors[ob] or 0)+1
  if w(@w_skip@)>0 or count~=w(@w_noam@) then bad('fragmented ending actor '..ob) end
 end
 if desc>=592 and desc<597 then
  stands=stands+1
  if w(@w_skip@)>0 or count~=w(@w_noam@) then bad('disconnected grandstand') end
 end
 if ob==114 then
  interiors=interiors+1
  if w(@w_cls@)==1 or w(@w_car@)==0 then bad('car interior treated as a shadow') end
 end
 if ob==118 and @END@==4 then
  extra=extra+1
  if w(@w_cls@)==1 or w(@w_car@)==0 then bad('ending E actor treated as a shadow') end
 end
 if ob==115 and w(@w_cls@)~=1 then bad('ground shadow treated as character artwork') end
end)
ex(@PfRenderEnd@,function()
 if not active() then return end
 frames=frames+1
 local pos=w(@seq_pos@);maxpos=math.max(maxpos,pos)
 if r(@end_seq@)~=@END@ then bad('wrong ending selected') end
 if pos>=250 then
  local l,rr=w(0x4055e0),w(0x405600)
  if l~=65535 and rr~=65535 then
   banners=banners+1
   if w(@k2_img@)~=l or w(@k2_img@+2)~=rr then bad('GOAL banner stuck at an old scale') end
  end
 end
 for i=0,w(@sprite_count@)-1 do
  local ob=w(@hw_ent@+i*2)
  if ob==99 or ob==100 or ob==101 or ob==113 or ob==114 or ob==117 or (ob==118 and @END@==4) then
   if visible[ob] and not staged[ob] then
    missing[ob]=(missing[ob] or 0)+1
    bad('visible ending actor missing: '..ob..' reason '..r(@sv_why@+i))
   end
  end
 end
 -- Check the actual OAM submitted to the PPU, including offscreen wrapping.
 local src=0x400000+w(0x37d6)
 local objs,slivers={},{}
 for i=0,127 do
  local hi=r(src+512+(i>>2))>>((i&3)*2)
  local size=(hi&2)~=0 and 16 or 8
  local x=r(src+i*4)+((hi&1)*256)
  local y=r(src+i*4+1)
  for row=0,size-1 do
   local line=(y+row)&255
   if line<224 and (x<256 or x+size>512) then
    objs[line]=(objs[line] or 0)+1
    for dx=0,size-1,8 do
     local sx=(x+dx)&511
     if x==256 or sx<256 or sx+7>=512 then slivers[line]=(slivers[line] or 0)+1 end
    end
   end
  end
 end
 for y=0,223 do
  if (objs[y] or 0)>32 or (slivers[y] or 0)>34 then bad('hardware sprite overflow on row '..y) end
 end
end)
emu.addEventCallback(function()
 n=n+1
 if active() then
  local pos=w(@seq_pos@);local k=pos//100
  if @SHOTS@ and not shots[k] and pos%100>=6 then
   shots[k]=true;local f=io.open(@DIR@..'/ending-@END@-seq-'..k..'.png','wb');f:write(emu.takeScreenshot());f:close()
  end
 end
 if n>=15000 or (frames>0 and w(@game_state@)~=14) then
  local out=io.open(@OUT@,'w')
  out:write(frames..' '..maxpos..' '..banners..' '..whole..' '..interiors..' '..extra..' '..stands..' '..w(@game_state@)..'\n')
  for ob,count in pairs(actors) do out:write('ACTOR '..ob..' '..count..' '..(missing[ob] or 0)..'\n') end
  for _,e in ipairs(errors) do out:write('ERROR '..e..'\n') end
  out:close();emu.stop(0)
 end
end,emu.eventType.endFrame)
'''


def check(rom, ending, output):
    syms = {p[2].lstrip('.'): int(p[1], 16) for line in rom.with_suffix('.sym').read_text().splitlines()
            if len(p := line.split()) == 3}
    name = 'ending_probe_' + uuid.uuid4().hex
    mesen = os.environ.get('MESEN', str(Path.home() / 'Downloads/Mesen.app/Contents/MacOS/Mesen'))
    with tempfile.TemporaryDirectory(prefix=name) as directory:
        directory = Path(directory)
        local = directory / (name + '.sfc')
        local.write_bytes(rom.read_bytes())
        lua = LUA
        for key, value in syms.items():
            if key in ('IeInitRoadSegMaster', 'ArchPrepare', 'ArchDraw', 'PfRenderEnd', 'SprVisible'):
                value += 0xc10000
            lua = lua.replace('@' + key + '@', str(value))
        lua = lua.replace('@END@', str(ending)).replace('@SHOTS@', str(output is not None).lower())
        lua = lua.replace('@DIR@', json.dumps(str(output or directory)))
        lua = lua.replace('@OUT@', json.dumps(str(directory / 'result.txt')))
        assert '@' not in lua, 'unresolved symbol in ending fixture'
        (directory / 'test.lua').write_text(lua)
        try:
            subprocess.run([mesen, '--testrunner', '--timeout=180', '--doNotSaveSettings',
                            '--Debug.ScriptWindow.AllowIoOsAccess=true', str(local), str(directory / 'test.lua')],
                           check=True, timeout=240, capture_output=True)
            lines = (directory / 'result.txt').read_text().splitlines()
        finally:
            home = Path.home() / 'Library/Application Support/Mesen2'
            for folder, pattern in [('Saves', name + '.srm'), ('Debugger', name + '.cdl'),
                                    ('SaveStates', name + '_*.mss')]:
                for path in (home / folder).glob(pattern):
                    path.unlink()
    if output:
        (output / f'ending-{ending}.txt').write_text('\n'.join(lines) + '\n')
    errors = [line for line in lines if line.startswith('ERROR ')]
    assert not errors, '\n'.join(errors)
    frames, pos, banners, whole, interiors, extra, stands, state = map(int, lines[0].split())
    assert frames > 200 and pos >= (580, 580, 580, 400, 600)[ending] - 4, 'incomplete ending timeline'
    assert state != 14, 'ending did not exit bonus state'
    assert banners > 50 and interiors > 100 and whole > 500, 'insufficient renderer coverage'
    assert ending != 4 or extra > 100, 'ending E actor not exercised'
    actors = {int(p[1]): dict(shown=int(p[2]), missing=int(p[3])) for line in lines[1:]
              if (p := line.split())[0] == 'ACTOR'}
    return dict(ending=ending, rendered_frames=frames, last_position=pos, banner_frames=banners,
                complete_actor_frames=whole, complete_grandstands=stands, actors=actors, errors=0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('rom', type=Path)
    parser.add_argument('--ending', type=int, choices=range(5), help='default: all five endings')
    parser.add_argument('--output', type=Path, help='save timeline screenshots and probe results')
    args = parser.parse_args()
    output = args.output.resolve() if args.output else None
    if output:
        output.mkdir(parents=True, exist_ok=True)
    for ending in range(5) if args.ending is None else [args.ending]:
        print(json.dumps(check(args.rom.resolve(), ending, output), indent=2), flush=True)


if __name__ == '__main__':
    main()
