#!/usr/bin/env python3
"""Drive every course in an AUTOPILOT/FREEZE_TIMER ROM and audit sprite budgets.

Selects each course at normal race initialization, drives it through its split
or goal, and inspects actual OAM at every completed renderer frame. Complete
admission, clipping, 128 OAM entries, 32 objects/line and 34 tiles/line are hard
assertions. Omitted decorations are reported separately, never counted as a
successful draw. Use check_endings.py for the subsequent animation timelines.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

LUA = r'''
local n,started,frames,whole,omitted=0,false,0,0,0
local peakOam,peakObj,peakTile,maxpos=0,0,0,0
local errors,seen,shots={},{},{}
local injected,pending=0,nil
local function r(a) return emu.read(a,emu.memType.sa1Memory) end
local function w(a) return r(a)+r(a+1)*256 end
local function wr(a,v) emu.write(a,v&255,emu.memType.sa1Memory);emu.write(a+1,(v>>8)&255,emu.memType.sa1Memory) end
local function ex(a,f) emu.addMemoryCallback(f,emu.callbackType.exec,a,a,emu.cpuType.sa1,emu.memType.sa1Memory) end
local function bad(msg)
 if not seen[msg] and #errors<20 then seen[msg]=true;table.insert(errors,n..': '..msg) end
end
emu.addEventCallback(function()
 local i={};if n>=300 and n<360 or n>=700 and n<760 then i.start=true end;emu.setInput(i,0)
end,emu.eventType.inputPolled)
ex(@IeInitRoadSegMaster@,function()
 if w(@game_state@)==8 and not started then
  started=true;wr(@cur_stage@,@DEPTH@);wr(@stage_lookup_off@,@LOOKUP@)
 end
end)
ex(@ClaimPass@,function()
 if not @STRESS@ or not started or pending or w(@sv_frame@)%16~=0 then return end
 if w(@w_ne@)~=0 or w(@w_car@)~=0 or w(@w_arch@)~=0 or w(@w_clip@)~=0 or w(@w_new@)==0 then return end
 pending={w(@w_st@),w(@w_oi@),w(@sv_nfc@),{}};injected=injected+1
 for i=0,15 do pending[4][i]=r(@av_ok@+i);emu.write(@av_ok@+i,0,emu.memType.sa1Memory) end
 wr(@sv_nok@,0);wr(@sv_nfc@,0)
end)
ex(@ArchDraw@,function()
 if pending then
  if (w(@w_nst@)&1)~=0 or w(@w_st@)~=pending[1] or w(@w_oi@)~=pending[2] then bad('failed allocation was not rolled back atomically') end
  for i=pending[2],127 do if r(@st_small@+i)~=0 then bad('rollback left stale OAM size flags') end end
  local usable=0
  for i=0,15 do
   local mask=pending[4][i]&(~r(@av_now@+i))&255
   emu.write(@av_ok@+i,mask,emu.memType.sa1Memory)
   for bit=0,7 do if (mask&(1<<bit))~=0 then usable=usable+1 end end
  end
  wr(@sv_nok@,usable);wr(@sv_nfc@,pending[3])
  pending=nil
 end
 if not started then return end
 if (w(@w_nst@)&1)==0 then omitted=omitted+1;return end
 whole=whole+1
 local count=(w(@w_st@)-0xe000)//4-w(@w_prf@)
 if w(@w_skip@)~=0 or count~=w(@w_noam@) then
  bad('incomplete object '..w(@w_obj@)..' count '..count..' expected '..w(@w_noam@)..' missing bands '..w(@w_skip@))
 end
end)
ex(@PfRenderEnd@,function()
 if not started then return end
 frames=frames+1
 local count=w(@w_oi@)
 peakOam=math.max(peakOam,count)
 if count>128 then bad('OAM entry overflow') end
 -- Read the submitted OAM, including signed X and vertical wraparound.
 local src=0x400000+w(0x37d6)
 local objs,tiles={},{}
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
     if sx<256 or sx+7>=512 then tiles[line]=(tiles[line] or 0)+1 end
    end
   end
  end
 end
 for y=0,223 do
  local ob,ti=objs[y] or 0,tiles[y] or 0
  peakObj=math.max(peakObj,ob);peakTile=math.max(peakTile,ti)
  if ob>32 or ti>34 then bad('scanline '..y..' overflow: '..ob..' objects, '..ti..' tiles') end
 end
end)
emu.addEventCallback(function()
 n=n+1
 if started and w(@cur_stage@)==@DEPTH@ and w(@game_state@)==12 then
  local pos=w(@road_pos@+2);maxpos=math.max(maxpos,pos)
  local k=pos//512
  if @SHOTS@ and not shots[k] and pos%512>=128 then
   shots[k]=true;local f=io.open(@DIR@..'/course-@LOOKUP@-section-'..k..'.png','wb');f:write(emu.takeScreenshot());f:close()
  end
 end
 local done=started and frames>200 and (w(@cur_stage@)>@DEPTH@ or w(@game_state@)==14)
 if done or n>=18000 then
  if not done then bad('course did not reach its split/goal') end
  if @STRESS@ and injected<10 then bad('insufficient allocation-failure coverage') end
  local f=io.open(@OUT@,'w')
  f:write(frames..' '..whole..' '..omitted..' '..peakOam..' '..peakObj..' '..peakTile..' '..maxpos..' '..injected..'\n')
  for _,msg in ipairs(errors) do f:write('ERROR '..msg..'\n') end
  f:close();emu.stop(0)
 end
end,emu.eventType.endFrame)
'''


def check(rom, depth, branch, output, stress=False):
    lookup = depth * 8 + branch
    syms = {p[2].lstrip('.'): int(p[1], 16) for line in rom.with_suffix('.sym').read_text().splitlines()
            if len(p := line.split()) == 3}
    name = 'scene_probe_' + uuid.uuid4().hex
    mesen = os.environ.get('MESEN', str(Path.home()/'Downloads/Mesen.app/Contents/MacOS/Mesen'))
    with tempfile.TemporaryDirectory(prefix=name) as directory:
        directory = Path(directory)
        local = directory / (name + '.sfc')
        local.write_bytes(rom.read_bytes())
        lua = LUA
        for key, value in syms.items():
            if key in ('IeInitRoadSegMaster', 'ArchDraw', 'PfRenderEnd', 'ClaimPass'):
                value += 0xc10000
            lua = lua.replace('@' + key + '@', str(value))
        for key, value in dict(DEPTH=depth, LOOKUP=lookup, STRESS=str(stress).lower(), SHOTS=str(output is not None).lower(),
                               DIR=json.dumps(str(output or directory)), OUT=json.dumps(str(directory/'result.txt'))).items():
            lua = lua.replace('@' + key + '@', str(value))
        assert '@' not in lua, 'unresolved symbol in course probe'
        (directory/'test.lua').write_text(lua)
        try:
            subprocess.run([mesen, '--testrunner', '--timeout=240', '--doNotSaveSettings',
                            '--Debug.ScriptWindow.AllowIoOsAccess=true', str(local), str(directory/'test.lua')],
                           check=True, timeout=300, capture_output=True)
            lines = (directory/'result.txt').read_text().splitlines()
        finally:
            home = Path.home()/'Library/Application Support/Mesen2'
            for folder, pattern in [('Saves', name+'.srm'), ('Debugger', name+'.cdl'), ('SaveStates', name+'_*.mss')]:
                for path in (home/folder).glob(pattern):
                    path.unlink()
    if output:
        (output/f'course-{lookup}.txt').write_text('\n'.join(lines)+'\n')
    errors = [line for line in lines if line.startswith('ERROR')]
    assert not errors, f'course {lookup}: ' + '\n'.join(errors)
    frames, whole, omitted, oam, objs, tiles, pos, injected = map(int, lines[0].split())
    assert frames > 500 and whole > 1000 and pos > 1000, 'insufficient course coverage'
    return dict(course=lookup, rendered_frames=frames, complete_objects=whole,
                rejected_draw_attempts=omitted, peak_oam=oam, peak_objects_per_line=objs,
                peak_tiles_per_line=tiles, road_position=pos, forced_allocation_failures=injected, errors=0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('rom', type=Path)
    parser.add_argument('--course', type=int, help='depth * 8 + branch; default: all 15 courses')
    parser.add_argument('--stress-allocation', action='store_true', help='exhaust allocatable cells after preflight to verify atomic rollback')
    parser.add_argument('--jobs', type=int, default=3)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    courses = [(d,b) for d in range(5) for b in range(d+1) if args.course is None or args.course == 8*d+b]
    assert courses, 'invalid course'
    if args.output:
        args.output.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        checks = [pool.submit(check, args.rom.resolve(), d, b, args.output.resolve() if args.output else None, args.stress_allocation) for d,b in courses]
        for result in checks:
            print(json.dumps(result.result()), flush=True)


if __name__ == '__main__':
    main()
