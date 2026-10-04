#!/usr/bin/env python3
"""Drive an AUTOPILOT/FREEZE_TIMER ROM through Gateway in Mesen.

Check the final roof geometry against its admitted composite sprite, after
sorting, and check clipped-cell ownership throughout the driven sequence.
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
    ap.add_argument('--frames', type=int, default=11000)
    ap.add_argument('--difficulty', type=int, default=2, choices=range(4))
    ap.add_argument('--report-visibility', action='store_true', help='report capacity dropouts as metrics; all geometry and hardware checks still fail on errors')
    args = ap.parse_args()
    rom = args.rom.resolve()
    syms = {p[2].lstrip('.'): int(p[1], 16) for line in rom.with_suffix('.sym').read_text().splitlines()
            if len(p := line.split()) == 3}
    name = 'arch_probe_' + uuid.uuid4().hex
    mesen = os.environ.get('MESEN', str(Path.home()/'Downloads/Mesen.app/Contents/MacOS/Mesen'))
    with tempfile.TemporaryDirectory(prefix=name) as td:
        td=Path(td)
        local=td/(name+'.sfc');local.write_bytes(rom.read_bytes())
        lua=r'''
local n=0
local seen={}
local roofs,near,offscreen,protected,complete,crests=0,0,0,0,0,0
local shadows,orphans=0,0
local errors={}
local owners={}
local history={}
local gaps=0
local visibility={}
local smallObjects=0
local function r(a) return emu.read(a,emu.memType.sa1Memory) end
local function w(a) return r(a)+r(a+1)*256 end
local function signed(a) local v=w(a);if v>=32768 then return v-65536 else return v end end
local function bad(msg) if #errors<10 then table.insert(errors,n..': '..msg) end end
local function shadowParent()
 local ob=w(@hw_ent@+w(@w_ck@))
 if (ob&128)==0 then return nil end
 for i=0,w(@sprite_count@)-1 do
  if w(@hw_ent@+i*2)==(ob&127) and (w(@pr_st@+i*2)>>8)>0 then return true end
 end
 return false
end
emu.addMemoryCallback(function()
 if shadowParent()==false then orphans=orphans+1 end
end,emu.callbackType.exec,@CopyStaged@,@CopyStaged@,emu.cpuType.sa1,emu.memType.sa1Memory)
emu.addMemoryCallback(function()
 local parent=shadowParent()
 if parent==false then bad('orphan shadow reached OAM copy') end
 if parent==true then shadows=shadows+1 end
end,emu.callbackType.exec,@CopyParentOK@,@CopyParentOK@,emu.cpuType.sa1,emu.memType.sa1Memory)
emu.addEventCallback(function()
 local i={};if n>=300 and n<360 or n>=700 and n<760 then i.start=true end;emu.setInput(i,0)
end,emu.eventType.inputPolled)
emu.addMemoryCallback(function() seen={} end,emu.callbackType.exec,@ArchPrepare@,@ArchPrepare@,emu.cpuType.sa1,emu.memType.sa1Memory)
emu.addMemoryCallback(function()
 if w(@w_arch@)==0 then return end
 local shown=(w(@w_nst@)&1)~=0
 local ob=w(@w_obj@)&127
 local group=w(@arch_group@+ob*2)
 if owners[group] and owners[group]~=ob then bad('arch changed its anchor object') end
 owners[group]=ob
 local h=history[group] or {first=false,pending=0}
 if shown then
  if h.first then
   gaps=gaps+h.pending
   if h.pending>0 and #visibility<20 then table.insert(visibility,n..": returned after "..h.pending.." rejected frames; last: "..(h.last or "unknown")) end
  end
  h.first=true;h.pending=0
 elseif h.first and w(@w_w@)>=20 and r(@sv_why@+w(@w_i@))~=9 then h.pending=h.pending+1;h.last=n.." group "..group.." width "..w(@w_w@).." reason "..r(@sv_why@+w(@w_i@)).." cells "..w(@sv_nok@).." new "..w(@w_new@).." skip "..w(@w_skip@) end
 h.width=w(@w_w@)
 history[group]=h
 seen[w(@w_i@)]={signed(@w_x@),signed(@w_y@)-signed(@arc_yoff@),w(@w_w@),w(@arc_fullh@),w(@w_vb@),shown,w(@arc_bg@)}
 if shown and w(@w_skip@)~=0 then bad('admitted a disconnected composite band') end
 if shown and (w(@w_st@)-0xe000)//4-w(@w_prf@)~=w(@w_noam@) then bad('admitted composite lost pieces during allocation') end
 if shown and w(@arc_bg@)==0 then complete=complete+1 end
 if shown and w(@w_w@)<w(@w_arch_min@) then bad('arch opening shrank into the road') end
 local rp=w(@JT@+(w(@w_obj@)&127)*64+24)
 if shown and rp>0 and rp<512 then
  local cut=w(@w_road_cut@)
  local base=0x41d000+w(@road_p2@)
  local ground=223-(signed(base+rp*2)>>4)
  local expected=224
  for y=0,math.min(223,ground-2) do
   local z=w(base+0x640+y*2)
   if z<512 and z>rp then expected=y;break end
  end
  if cut~=expected then bad('road clipping differs from displayed-depth reference') end
  if cut<224 and w(@w_vb@)>cut then bad('arch ignores the displayed road depth') end
  if cut<224 and cut<signed(@w_y@)+w(@w_h@) and cut>signed(@w_y@) then crests=crests+1 end
 end
end,emu.callbackType.exec,@ArchDraw@,@ArchDraw@,emu.cpuType.sa1,emu.memType.sa1Memory)
emu.addMemoryCallback(function()
 if w(@arch_count@)==0 then return end
 local previous=-1
 local posted={}
 for off=0,w(@ohb_na@)-1,32 do
  local a=0x4041c0+off
  local id=w(a+18)
  posted[id]=true
  if id<=previous then bad('roof depth order or duplicate representative') end
  previous=id
  local s=seen[id]
  if not s then bad('roof without a composite sprite') else
   local x,y,ww,hh,vb=table.unpack(s)
   local bottom=math.min(y+math.ceil(hh*47/152),vb)
   if signed(a)~=y or w(a+2)~=bottom or signed(a+4)~=x or signed(a+6)~=x+ww-1 then
    bad('roof detached from its composite origin/scale')
   end
   if bottom<=0 or bottom>224 or y>=bottom or w(a+8)==0 then bad('invalid roof bounds') end
   roofs=roofs+1
   if ww>=200 then near=near+1 end
   if x<0 or x+ww>256 or y<0 then offscreen=offscreen+1 end
  end
 end
 for id,s in pairs(seen) do
  local x,y,ww,hh,vb,shown,bg=table.unpack(s)
  if shown and bg~=0 and math.min(y+math.ceil(hh*47/152),vb)>0 and not posted[id] then
   bad('admitted pillars without their visible roof')
  end
 end
end,emu.callbackType.exec,@OhbLines@,@OhbLines@,emu.cpuType.sa1,emu.memType.sa1Memory)
emu.addMemoryCallback(function()
 -- Palette/cell rejection before ArchDraw must count too.
 for i=0,w(@sprite_count@)-1 do
  if r(@arch_active@+i)==1 and not seen[i] then
   local ob=w(@hw_ent@+i*2)&127
   local h=history[w(@arch_group@+ob*2)]
   local why=r(@sv_why@+i)
   if h and h.first and h.width>=20 and why>=3 and why<=8 then h.pending=h.pending+1;h.last=n.." pre-draw reason "..why end
  end
 end
 local src=0x400000+w(0x37d6)
 local objs,slivers={},{}
 for i=0,127 do
  local hi=r(src+512+(i>>2))>>((i&3)*2)
  local size=(hi&2)~=0 and 16 or 8
  local x=r(src+i*4)+((hi&1)*256)
  local y=r(src+i*4+1)
  if size==8 and y<224 then smallObjects=smallObjects+1 end
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
 local base=w(@cl_base@)
 for i=0,w(@cl_n@+w(@cl_side@))-1 do
  local c=w(@cl_cells@+base+i*2)
  if c<128 then
   protected=protected+1
   if (r(@av_now@+(c>>3)) & (1<<(c&7)))==0 or w(0x40e800+c*2)~=65535 then bad('clipped cell lost ownership') end
  end
 end
end,emu.callbackType.exec,@PfRenderEnd@,@PfRenderEnd@,emu.cpuType.sa1,emu.memType.sa1Memory)
emu.addEventCallback(function()
 n=n+1
 @NORMAL@
 if n==@FRAMES@ then
  local out=io.open(@OUT@,'w')
  out:write(roofs..' '..near..' '..offscreen..' '..protected..' '..complete..' '..crests..' '..shadows..' '..orphans..' '..smallObjects..' '..gaps..'\n')
  for _,e in ipairs(errors) do out:write(e..'\n') end
  for _,e in ipairs(visibility) do out:write('VIS '..e..'\n') end
  out:close();emu.stop(0)
 end
end,emu.eventType.endFrame)
'''
        lua=lua.replace('@NORMAL@',f"if n==200 then emu.write({syms['cfg_diff']},{args.difficulty},emu.memType.sa1Memory) end" if 'cfg_diff' in syms else '')
        code=['ArchPrepare' ,'ArchDraw','OhbLines','PfRenderEnd','CopyStaged','CopyParentOK']
        for k,v in syms.items():
            lua=lua.replace('@'+k+'@',str(v+0xc10000 if k in code else v))
        lua=lua.replace('@FRAMES@',str(args.frames)).replace('@OUT@',json.dumps(str(td/'result.txt')))
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
    visibility=[line[4:] for line in lines[1:] if line.startswith('VIS ')]
    errors=[line for line in lines[1:] if not line.startswith('VIS ')]
    assert not errors, '\n'.join(errors)
    roofs,near,offscreen,protected,complete,crests,shadows,orphans,smallObjects,gaps=map(int,lines[0].split())
    if not args.report_visibility:
        assert gaps==0, f'{gaps} arch visibility gaps between admitted frames: '+ '; '.join(visibility)
    assert roofs>100 and near>10 and offscreen>10 and protected>0 and crests>10 and shadows>100 and orphans>0, 'insufficient scenario coverage'
    print(json.dumps(dict(bg_roofs=roofs,near=near,offscreen=offscreen,protected_cells=protected,complete_obj_arches=complete,road_clipped_arches=crests,attached_shadows=shadows,orphan_shadows_suppressed=orphans,narrow_objects=smallObjects,stable_anchors=True,interior_arch_dropouts=gaps,visibility_details=visibility,errors=0),indent=2))

if __name__=='__main__':main()
