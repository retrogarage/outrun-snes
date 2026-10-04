#!/usr/bin/env python3
"""Execute the ROM's hill clipping at all 15 sub-tile cut positions in Mesen.

The fixture substitutes crest heights at PlaceImg's bottom-clip boundary.
It compares uploaded VRAM against original ROM pixels: visible rows must
match exactly, hidden rows must be transparent, including mirrored sprites.
For compound uploads it also checks measured S-CPU time against the stream
budget; --direct-stream exercises the fallback without background conversion.
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
    ap.add_argument('--frames', type=int, default=2200)
    ap.add_argument('--from-frame', type=int, default=1000)
    ap.add_argument('--require-packed', action='store_true')
    ap.add_argument('--trace', type=Path, help='save raw pixel samples and timing counters')
    ap.add_argument('--direct-stream', action='store_true',
                    help='disable background conversion in the temporary ROM; exercise NMI Direct')
    args = ap.parse_args()
    rom = args.rom.resolve()
    syms = {p[2].lstrip('.'): int(p[1], 16) for line in rom.with_suffix('.sym').read_text().splitlines()
            if len(p := line.split()) == 3}
    mesen = os.environ.get('MESEN', str(Path.home() / 'Downloads/Mesen.app/Contents/MacOS/Mesen'))
    name = 'clip_probe_' + uuid.uuid4().hex
    with tempfile.TemporaryDirectory(prefix=name) as td:
        td = Path(td)
        image = bytearray(rom.read_bytes())
        if args.direct_stream:
            # ConvAll runs from WRAM; patch its ROM load image, not production
            # source. An RTS leaves the FIFO for the NMI's Direct fallback.
            off = syms['__NMICODE_LOAD__'] - 0x8000 + syms['ConvAll'] - syms['__NMICODE_RUN__']
            image[off] = 0x60
        (td / (name + '.sfc')).write_bytes(image)
        lua = r"""
local out=io.open(@OUT@,'w')
local n=0
local pending={}
local reused=0
local protected=0
local retired=0
local violations=0
local stream={descriptor=0,direct=0,violations=0,max_units=0,min_margin=65535}
local stream_start,stream_mode=nil,nil
local stream_cases={}
local function r(a) return emu.read(a,emu.memType.sa1Memory) end
local function w(a) return r(a)+256*r(a+1) end
local function ww(a,v)
 emu.write(a,v & 255,emu.memType.sa1Memory)
 emu.write(a+1,(v >> 8) & 255,emu.memType.sa1Memory)
end
emu.addEventCallback(function()
 local inp={}
 if n>=300 and n<360 or n>=700 and n<760 then inp.start=true end
 emu.setInput(inp,0)
end,emu.eventType.inputPolled)
emu.addMemoryCallback(function()
 if n<@FROM@ then return end
 local y=w(@w_y@)
 if y>0 and y<180 and w(@w_h@)>=16 then
  local rows=((w(@sv_frame@) // 4) % 16)
  -- Zero visible rows exercises the wholly-hidden boundary too.
  ww(@w_vb@,y+rows)
 end
end,emu.callbackType.exec,@ClipBottom@,@ClipBottom@,emu.cpuType.sa1,emu.memType.sa1Memory)
local uploaded=0
local function pixels(dst,p)
 out:write(string.format('%d %d %d %d %d %d %d %d ',dst,table.unpack(p)))
 for _,off in ipairs({0,512}) do
  for j=0,63 do out:write(string.format('%02x',emu.read(2*dst+off+j,emu.memType.snesVideoRam))) end
 end
 out:write(' '..n..'\n')
end
@STREAM_PROBE@
local function capture()
 local cell=w(@cl_cell@)
 local dst=0x6000+((cell & 7)*2+(cell>>3)*32)*16
 local bank=w(@w_srcb@)
 pending[dst]={w(@w_clip@),(bank>>8)&7,bank & 255,w(@cl_src@),w(@w_bn@),w(@w_mir@),w(@w_lift@)}
end
emu.addMemoryCallback(capture,emu.callbackType.exec,@ClipReady@,@ClipReady@,emu.cpuType.sa1,emu.memType.sa1Memory)
emu.addMemoryCallback(function() capture();reused=reused+1 end,emu.callbackType.exec,@ClipReused@,@ClipReused@,emu.cpuType.sa1,emu.memType.sa1Memory)
-- Validate ownership at the completed frame, not only newly uploaded
-- pixels. A cache hit must remain protected throughout its displayed life.
emu.addMemoryCallback(function()
 local side=w(@cl_side@)
 local base=w(@cl_base@)
 for i=0,w(@cl_n@+side)-1 do
  local c=w(@cl_cells@+base+i*2)
  if c<128 then
   protected=protected+1
   if (r(@av_now@+(c>>3)) & (1<<(c&7)))==0 or w(0x40e800+c*2)~=65535 then
    violations=violations+1
   end
  end
 end
end,emu.callbackType.exec,@PfRenderEnd@,@PfRenderEnd@,emu.cpuType.sa1,emu.memType.sa1Memory)
-- A saturated FIFO may stay nonempty for many rendered frames. Samples
-- from a retired private cell are then stale: normal allocations can reuse
-- it and later leave VC_OWN=$FFFF again. Only the two live OAM generations
-- still own clipped pixels; the frame-end callback checks their protection.
local function livePrivate(cell)
 for side=0,1 do
  for i=0,w(@cl_n@+side*2)-1 do
   if w(@cl_cells@+side*32+i*2)==cell then return true end
  end
 end
 return false
end
emu.addEventCallback(function()
 n=n+1
 if w(0x37d0)==w(0x37d2) then
  for dst,p in pairs(pending) do
   local cell=((dst-0x6000)>>9)*8+((dst>>5)&7)
   if w(0x40e800+cell*2)==65535 and livePrivate(cell) then
   pixels(dst,p)
   else
    retired=retired+1
   end
  end
  pending={}
 end
 if n==@FRAMES@ then out:write('N '..uploaded..'\nL '..retired..'\nR '..reused..'\nP '..protected..' '..violations..'\n');out:write('S '..stream.descriptor..' '..stream.direct..' '..stream.violations..' '..stream.max_units..' '..stream.min_margin..'\n');for k,v in pairs(stream_cases) do out:write('T '..k..' '..v..'\n') end;out:close();emu.stop(0) end
end,emu.eventType.endFrame)
"""
        probe = ""
        if 'ClipUploadDone' in syms:
            probe = r"""
local function cw(a)
 return emu.read(a,emu.memType.snesMemory)+256*emu.read(a+1,emu.memType.snesMemory)
end
local function begin(mode)
 stream_start=emu.getState()["masterClock"];stream_mode=mode
end
emu.addMemoryCallback(function() begin('descriptor') end,emu.callbackType.exec,@H_CLIP@,@H_CLIP@)
emu.addMemoryCallback(function() begin('direct') end,emu.callbackType.exec,@DirectClip@,@DirectClip@)
-- Check every new upload immediately after its last DMA, independently
-- of FIFO drain latency; frame-boundary samples additionally cover reuse.
local upload_dst,upload_pixels
emu.addMemoryCallback(function()
 upload_dst=cw(@ex_cdst@)
 local cell=((upload_dst-0x6000)>>9)*8+((upload_dst>>5)&7)
 local rows=cw(@ex_crows@)
 local lift=0
 if (cw(@ex_cpack@)&16)~=0 then lift=8-rows end
 local bank=w(@cl_keys@+cell*8+2)
 upload_pixels={rows,(bank>>8)&7,cw(@ex_cbank@),cw(@ex_csrc@),cw(@ex_cstride@)//64,0,lift}
end,emu.callbackType.exec,@ClipUpload@,@ClipUpload@)
emu.addMemoryCallback(function()
 pixels(upload_dst,upload_pixels)
 uploaded=uploaded+1
 local units=math.ceil((emu.getState()["masterClock"]-stream_start+48)/8)
 local cut=cw(@ex_cpack@)&31
 local budget=cw(@ClipCosts@+2*cut)
 local key=stream_mode..':'..cut
 stream_cases[key]=math.max(stream_cases[key] or 0,units)
 if stream_mode=='direct' then budget=budget+250 end
 stream[stream_mode]=stream[stream_mode]+1
 stream.max_units=math.max(stream.max_units,units)
 stream.min_margin=math.min(stream.min_margin,budget-units)
 if units>budget then stream.violations=stream.violations+1 end
end,emu.callbackType.exec,@ClipUploadDone@,@ClipUploadDone@)
"""
        lua = lua.replace('@STREAM_PROBE@', probe)
        for key, value in syms.items():
            if key in ['ClipBottom','ClipReady','ClipReused','PfRenderEnd']:
                value += 0xc10000
            lua = lua.replace('@'+key+'@', str(value))
        lua = lua.replace('@FROM@',str(args.from_frame)).replace('@FRAMES@',str(args.frames))
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
    if args.trace:
        args.trace.write_text('\n'.join(lines) + '\n')
    uploaded=int(next(line.split()[1] for line in lines if line.startswith('N ')))
    retired=int(next(line.split()[1] for line in lines if line.startswith('L ')))
    reused=int(next(line.split()[1] for line in lines if line.startswith('R ')))
    protected,violations=map(int,next(line.split()[1:] for line in lines if line.startswith('P ')))
    assert protected>0 and violations==0, f'private-cell ownership: {violations} violations in {protected} samples'
    stream = list(map(int, next(line.split()[1:] for line in lines if line.startswith('S '))))
    cases = {line.split()[1]:int(line.split()[2]) for line in lines if line.startswith('T ')}
    if 'ClipUploadDone' in syms:
        assert sum(stream[:2]) > 0, 'compound upload not exercised'
        assert uploaded == sum(stream[:2]), 'missing completed-upload pixel samples'
        assert stream[2] == 0, f'upload exceeded its deadline reservation: {stream}; cases={cases}'
        if args.direct_stream:
            assert stream[0] == 0 and stream[1] > 0, 'Direct-only fixture did not use Direct'
    lines=[line for line in lines if line[0] not in 'LNRPST']
    assert reused>0, 'fixture did not exercise the clipped-cell cache'
    data=rom.read_bytes()
    covered=set()
    mirrored=0
    packed=set()
    for line in lines:
        fields=line.split()
        dst,rows,block,bank,src,pieces,mirror,lift=map(int,fields[:8])
        base=block*0x100000+(bank & 15)*0x10000+src
        expected=bytearray(data[base:base+64]+data[base+pieces*64:base+pieces*64+64])
        for y in range(rows,16):
            for x in range(2):
                off=(y//8)*64+x*32+(y%8)*2
                for plane in [0,1,16,17]: expected[off+plane]=0
        if lift:
            assert 1<=rows<=7 and lift==8-rows
            source=expected
            expected=bytearray(128)
            for plane in range(4):
                part=source[plane*16:plane*16+rows*2]
                for half in [0,64]:
                    off=half+plane*16+lift*2
                    expected[off:off+len(part)]=part
            packed.add(rows)
        actual=bytes.fromhex(fields[8])
        assert actual==expected, (f'bad masked cell at ${dst:04x}, visible rows={rows}, '
                                 f'frame={fields[9]}, source={block}:{bank:02x}:{src:04x}, '
                                 f'pieces={pieces}, lift={lift}, '
                                 f'differences={[(i, a, b) for i, (a, b) in enumerate(zip(actual, expected)) if a != b][:16]}')
        covered.add(rows)
        mirrored+=bool(mirror)
    assert covered==set(range(1,16)), f'missing cut positions: {set(range(1,16))-covered}'
    if args.require_packed:
        assert packed==set(range(1,8)), f'missing packed cut positions: {set(range(1,8))-packed}'
    print(json.dumps({'stream_cases_max_units':cases,'stream_descriptors':stream[0],'stream_direct':stream[1],'stream_budget_violations':stream[2],'stream_max_units':stream[3],'stream_min_margin':stream[4],'packed_cut_positions':sorted(packed),'protected_cell_samples':protected,'cache_reuses':reused,'completed_uploads_checked':uploaded,'retired_samples_discarded':retired,'masked_pieces_checked':len(lines),'cut_positions':sorted(covered),'mirrored_pieces':mirrored},indent=2))

if __name__=='__main__': main()
