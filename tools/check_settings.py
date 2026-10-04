#!/usr/bin/env python3
"""Exercise settings navigation, remapping, difficulty, pause and SRAM reload in Mesen."""
import json, os, subprocess, tempfile, uuid
from pathlib import Path
import argparse


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('rom',type=Path);args=ap.parse_args();rom=args.rom.resolve()
    s={p[2].lstrip('.'):int(p[1],16) for l in rom.with_suffix('.sym').read_text().splitlines() if len(p:=l.split())==3}
    name='settings_'+uuid.uuid4().hex;mesen=os.environ.get('MESEN',str(Path.home()/'Downloads/Mesen.app/Contents/MacOS/Mesen'));home=Path.home()/'Library/Application Support/Mesen2'
    with tempfile.TemporaryDirectory(prefix=name) as td:
        td=Path(td);local=td/(name+'.sfc');local.write_bytes(rom.read_bytes())
        def run(body,tag):
            lua='''local n=0;local errors={}
local function r(a) return emu.read(a,emu.memType.sa1Memory) end
local function w(a) return r(a)+256*r(a+1) end
local function check(ok,msg) if not ok then table.insert(errors,n..': '..msg) end end
local function finish() local o=io.open(OUT,'w');o:write('checks completed\\n');for _,x in ipairs(errors) do o:write(x..'\\n') end;o:close();emu.stop(0) end
'''.replace('OUT',json.dumps(str(td/(tag+'.txt'))))+body
            for k,v in s.items():lua=lua.replace('@'+k+'@',str(v+(0xc10000 if k=='InFrameDone' else 0xcf0000 if k=='SettingsTick' else 0)))
            assert '@' not in lua
            script=td/(tag+'.lua');script.write_text(lua)
            proc=subprocess.run([mesen,'--testrunner','--timeout=180','--doNotSaveSettings','--Debug.ScriptWindow.AllowIoOsAccess=true',str(local),str(script)],capture_output=True,timeout=240)
            assert proc.returncode==0,proc.stdout.decode(errors='replace')[-1000:]+proc.stderr.decode(errors='replace')[-1000:]
            lines=(td/(tag+'.txt')).read_text().splitlines();assert len(lines)==1,'\n'.join(lines[1:])
        try:
            run(r'''
local presses={[100]='select',[140]='left',[180]='right',[220]='right',[260]='right',[300]='right',[340]='left',[380]='left',[420]='left',[460]='down',[500]='a',[540]='x',[580]='down',[620]='a',[660]='x',[700]='down',[740]='right',[780]='left',[820]='a',[860]='l',[900]='a',[940]='start',[980]='select',[1100]='start',[1500]='start',[1800]='l',[2100]='select',[2140]='left',[2200]='start'}
local gearBefore
local saved,pausedTick,pausedTime,pausedRoad,oldActive=nil,nil,nil,nil,false
local function text() local b={};for i=0,4095 do b[i+1]=string.char(r(@txt_ram@+i)) end;return table.concat(b) end
emu.addMemoryCallback(function()
 if w(@cfg_active@)==0 and (w(0x3702)&0x2000)~=0 then saved=text() end
 oldActive=w(@cfg_active@)==1
end,emu.callbackType.exec,@SettingsTick@,@SettingsTick@,emu.cpuType.sa1,emu.memType.sa1Memory)
emu.addMemoryCallback(function()
 if oldActive and w(@cfg_active@)==0 then check(text()==saved,'pause did not restore the original text RAM');oldActive=false end
end,emu.callbackType.exec,@InFrameDone@,@InFrameDone@,emu.cpuType.sa1,emu.memType.sa1Memory)
emu.addEventCallback(function()
 local i={};for f,k in pairs(presses) do if n>=f and n<f+12 then i[k]=true end end
 if n>=1550 and n<2070 then i.a=true end
 if n>=2320 and n<2430 then i.x=true end
 emu.setInput(i,0)
end,emu.eventType.inputPolled)
emu.addEventCallback(function()
 n=n+1
 if n==130 then check(w(@cfg_active@)==1 and w(@cfg_diff@)==1,'default Easy/menu');check(w(@cfg_masks@)==0x8000 and w(@cfg_masks@+2)==0x80,'default adjacent B/A') end
 local diffs={[170]=0,[210]=1,[250]=2,[290]=3,[330]=0,[370]=3,[410]=2,[450]=1}
 if diffs[n] then check(w(@cfg_diff@)==diffs[n],'difficulty navigation/wrap') end
 if n==530 then check(w(@cfg_capture@)==1,'A did not open capture') end
 if n==690 then check(w(@cfg_keys@)==1 and w(@cfg_keys@+2)==3,'conflict did not swap actions') end
 if n==770 then check(w(@cfg_keys@+4)==3 and w(@cfg_keys@+2)==2,'right cycling/swap') end
 if n==810 then check(w(@cfg_keys@+4)==2 and w(@cfg_keys@+2)==3,'left cycling/swap') end
 if n==970 then check(w(@cfg_capture@)==0 and w(@cfg_active@)==1,'cancel closed settings') end
 if n==1030 then check(w(@cfg_active@)==0 and w(0x407a80)==0x534f,'settings did not save');check(w(@cfg_masks@)==0x80 and w(@cfg_masks@+2)==0x40 and w(@cfg_masks@+4)==0x20,'remapped masks') end
 if n==1700 then check(w(@race_diff@)==1 and w(@max_traffic@)==2,'Easy initial traffic');check(w(@time_counter@)>0x90,'Easy initial time');check(w(@input_acc@)>0,'A remap does not accelerate') end
 if n==1760 then gearBefore=w(@gear@) end
 if n==1850 then check(w(@gear@)~=gearBefore,'L remap does not change gear') end
 if n==2125 then pausedTick=w(@tick_counter@);pausedTime=w(@time_counter@);pausedRoad=w(@road_pos@) end
 if n==2180 then check(w(@tick_counter@)==pausedTick and w(@time_counter@)==pausedTime and w(@road_pos@)==pausedRoad,'game advanced while paused');check(w(@cfg_diff@)==0 and w(@race_diff@)==1,'difficulty changed the active race') end
 if n==2400 then check(w(@input_brake@)>0,'X remap does not brake') end
 if n==2500 then finish() end
end,emu.eventType.endFrame)
''','navigation')
            run(r'''
emu.addEventCallback(function() local i={};if n>=300 and n<320 or n>=700 and n<720 then i.start=true end;emu.setInput(i,0) end,emu.eventType.inputPolled)
local t
emu.addEventCallback(function()
 n=n+1
 if n==200 then check(w(@cfg_diff@)==0 and w(@cfg_keys@)==1 and w(@cfg_keys@+2)==3 and w(@cfg_keys@+4)==4,'saved settings did not reload') end
 if n==1200 then t=w(@time_counter@);check(w(@freeze_timer@)==1 and w(@max_traffic@)==2,'Relaxed not applied') end
 if n==1800 then check(w(@time_counter@)==t,'Relaxed timer counted down');finish() end
end,emu.eventType.endFrame)
''','reload-relaxed')
            save=home/'Saves'/(name+'.srm');data=bytearray(save.read_bytes());data[0x7a8c]^=1;save.write_bytes(data)
            run(r'''
emu.addEventCallback(function() n=n+1;if n==200 then check(w(@cfg_diff@)==1 and w(@cfg_keys@)==0 and w(@cfg_keys@+2)==1 and w(@cfg_keys@+4)==2,'corrupt SRAM did not restore safe defaults');finish() end end,emu.eventType.endFrame)
''','corrupt-save')
            # Fresh valid SRAM presets independently check each timed difficulty.
            for diff,start,traffic in [(2,0x75,3),(3,0x72,4)]:
                import struct
                data=bytearray(0x20000);struct.pack_into('<7H',data,0x7a80,0x534f,1,diff,0,1,2,0xa591^diff^0^1^2);save.write_bytes(data)
                run(r'''
local checked=false
emu.addEventCallback(function() local i={};if n>=300 and n<320 or n>=700 and n<720 then i.start=true end;emu.setInput(i,0) end,emu.eventType.inputPolled)
emu.addEventCallback(function()
 n=n+1
 if not checked and w(@game_state@)==9 then checked=true;check(w(@time_counter@)==START,'starting time');check(w(@max_traffic@)==TRAFFIC,'initial traffic');check(w(@race_diff@)==DIFF,'race difficulty') end
 if n==1200 then check(checked,'race did not start');finish() end
end,emu.eventType.endFrame)
'''.replace('START',str(start)).replace('TRAFFIC',str(traffic)).replace('DIFF',str(diff)),f'difficulty-{diff}')
        finally:
            for folder,pattern in [('Saves',name+'.srm'),('Debugger',name+'.cdl'),('SaveStates',name+'_*.mss')]:
                for p in (home/folder).glob(pattern):p.unlink()
    print(json.dumps(dict(menu=True,remap_and_conflicts=True,pause_restores_text=True,sram_reload=True,corrupt_save_defaults=True,difficulties=['Relaxed','Easy','Normal','Hard']),indent=2))
if __name__=='__main__':main()
