#!/usr/bin/env python3
"""Check the complete start scene through countdown and a prolonged stationary wait."""
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
    ap.add_argument('--frames', type=int, default=2800)
    ap.add_argument('--difficulty', type=int, default=1, choices=range(4))
    args = ap.parse_args()
    rom = args.rom.resolve()
    syms = {p[2].lstrip('.'): int(p[1], 16) for line in rom.with_suffix('.sym').read_text().splitlines()
            if len(p := line.split()) == 3}
    name = 'grid_probe_' + uuid.uuid4().hex
    mesen = os.environ.get('MESEN', str(Path.home()/'Downloads/Mesen.app/Contents/MacOS/Mesen'))
    with tempfile.TemporaryDirectory(prefix=name) as td:
        td=Path(td)
        local=td/(name+'.sfc');local.write_bytes(rom.read_bytes())
        lua=r'''
local n,checks,waiting,banners=0,0,0,0
local errors,frames,images,decor={}, {}, {}, nil
local seen_errors={}
local pixels,banner={},false
-- Eight palms include the two nearer banner supports (19 right, 20 left).
-- The sign towers must survive admitting those supports too.
local cohort={6,7,8,9,12,13,19,20,44,45,48,58,62,67,99,100,101,119}
local function r(a) return emu.read(a,emu.memType.sa1Memory) end
local function w(a) return r(a)+r(a+1)*256 end
local function bad(msg)
 if #errors<10 and not seen_errors[msg] then
  seen_errors[msg]=true;table.insert(errors,n..': '..msg)
 end
end
emu.addEventCallback(function()
 local i={};if n>=300 and n<360 or n>=700 and n<760 then i.start=true end;emu.setInput(i,0)
end,emu.eventType.inputPolled)
emu.addMemoryCallback(function() frames={};banner=false end,emu.callbackType.exec,@ArchPrepare@,@ArchPrepare@,emu.cpuType.sa1,emu.memType.sa1Memory)
emu.addMemoryCallback(function() banner=true end,emu.callbackType.exec,@K2Show@,@K2Show@,emu.cpuType.sa1,emu.memType.sa1Memory)
emu.addMemoryCallback(function()
 local count=(w(@w_st@)-0xe000)//4-w(@w_prf@)
 frames[w(@w_obj@)]={count,w(@w_noam@),w(@w_skip@),w(@w_img@),w(@w_exi@)}
end,emu.callbackType.exec,@ArchDraw@,@ArchDraw@,emu.cpuType.sa1,emu.memType.sa1Memory)
emu.addMemoryCallback(function()
 -- ClaimPass starts with ip at the image record; it then reuses ip as a
 -- piece-offset cursor, so reading it at ArchDraw would inspect garbage.
 if w(@w_obj@)==119 then
  local p=w(@ip@)+r(@ip@+2)*65536
  local src=r(p+9)*0x100000+(r(p+12)&15)*65536+w(p+10)
  local desc=(w(@w_dsc@)-w(0x808000))//18
  pixels[w(@w_img@)]={desc,w(@w_cls@),src,w(p+14)}
 end
end,emu.callbackType.exec,@ClaimPass@,@ClaimPass@,emu.cpuType.sa1,emu.memType.sa1Memory)
emu.addMemoryCallback(function()
 local state=w(@game_state@)
 if state<9 or state>12 or w(@grid_warm@)>0 then return end
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
  if (objs[y] or 0)>32 or (slivers[y] or 0)>34 then bad('hardware sprite overflow at row '..y..' ('..(objs[y] or 0)..' objects, '..(slivers[y] or 0)..' tiles)') end
 end
 if state==12 then waiting=waiting+1 else checks=checks+1 end
 if banner then banners=banners+1 else bad('START banner missing') end
 for _,ob in ipairs(cohort) do
  local s=frames[ob]
  if not s or s[1]==0 or s[1]~=s[2] or s[3]~=0 then bad('incomplete start object '..ob) end
  if ob==99 and state==12 and s and s[4]~=s[5] then bad('player car stuck on a cached arrival pose') end
  if ob==119 and s then images[s[4]]=true end
 end
 local current={}
 for ob,s in pairs(frames) do
  if ob<68 and w(@grid_people@+ob*2)==0 and s[1]>0 then
   current[ob]=true
   if decor and not decor[ob] then bad('decoration popped into the start scene: '..ob) end
   if s[1]~=s[2] or s[3]~=0 then bad('partial start decoration '..ob) end
  end
 end
 if not decor then decor=current end
 for ob in pairs(decor) do if not current[ob] then bad('start decoration disappeared: '..ob) end end
end,emu.callbackType.exec,@PfRenderEnd@,@PfRenderEnd@,emu.cpuType.sa1,emu.memType.sa1Memory)
emu.addEventCallback(function()
 n=n+1
 if n==200 then emu.write(@cfg_diff@,@DIFFICULTY@,emu.memType.sa1Memory) end
 if n==@FRAMES@ then
  local count=0;for _ in pairs(images) do count=count+1 end
  local out=io.open(@OUT@,'w');out:write(checks..' '..waiting..' '..banners..' '..count..'\n')
  for _,p in pairs(pixels) do out:write('PIX '..table.concat(p,' ')..'\n') end
  for _,e in ipairs(errors) do out:write(e..'\n') end
  out:close();emu.stop(0)
 end
end,emu.eventType.endFrame)
'''
        code=['ArchPrepare','ArchDraw','PfRenderEnd','K2Show','ClaimPass']
        for k,v in syms.items():
            lua=lua.replace('@'+k+'@',str(v+0xc10000 if k in code else v))
        lua=lua.replace('@FRAMES@',str(args.frames)).replace('@OUT@',json.dumps(str(td/'result.txt')))
        lua=lua.replace('@DIFFICULTY@',str(args.difficulty))
        assert '@' not in lua
        (td/'test.lua').write_text(lua)
        try:
            subprocess.run([mesen,'--testrunner','--timeout=180','--doNotSaveSettings',
                            '--Debug.ScriptWindow.AllowIoOsAccess=true',str(local),str(td/'test.lua')],
                           check=True,timeout=240,capture_output=True)
            lines=(td/'result.txt').read_text().splitlines()
        finally:
            home=Path.home()/'Library/Application Support/Mesen2'
            for folder,pattern in [('Saves',name+'.srm'),('Debugger',name+'.cdl'),('SaveStates',name+'_*.mss')]:
                for p in (home/folder).glob(pattern):p.unlink()
    errors=[line for line in lines[1:] if not line.startswith('PIX ')]
    # Flag shadow colour 10 must be converted even in the final idle poses,
    # absent from driving traces. Check the actual selected ROM image tiles.
    data=rom.read_bytes()
    poses=set()
    bad_poses=set()
    tiles=0
    for line in lines[1:]:
        if not line.startswith('PIX '):
            continue
        desc,mode,src,pieces=map(int,line.split()[1:])
        poses.add(desc)
        assert mode==2, f'flag pose {desc}: hardware shadow disabled'
        assert src+pieces*128<=len(data), 'invalid image pixel span'
        for off in range(src,src+pieces*128,32):
            tile=data[off:off+32]
            for y in range(8):
                # 4bpp colour 10 is planes 1 and 3, with 0 and 2 clear.
                green=tile[y*2+1]&tile[y*2+17]&~(tile[y*2]|tile[y*2+16])
                if green and desc not in bad_poses:
                    bad_poses.add(desc)
                    errors.append(f'flag pose {desc}: unconverted green shadow')
                    break
            tiles+=1
    assert not errors, '\n'.join(errors[:12])
    checks,waiting,banners,animations=map(int,lines[0].split())
    assert checks>50 and waiting>500 and animations>2, 'insufficient countdown/wait coverage'
    assert {711,712,713}<=poses, 'final flag animation and idle loop not covered'
    assert banners==checks+waiting, 'banner missing from visible scene'
    print(json.dumps(dict(complete_countdown_frames=checks,stationary_race_frames=waiting,
                         banner_frames=banners,flag_frames=animations,shadow_tiles_checked=tiles,
                         restored_palms=8,banner_support_palms=2,late_appearances=0,errors=0),indent=2))

if __name__=='__main__':main()
