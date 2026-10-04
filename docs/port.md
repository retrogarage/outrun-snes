# Engine port: original CannonBall (classic OutRun) -> SA-1 65816

The LOCKSTEP build runs the classic arcade game logic tick for tick with
the reference. The playable console build keeps that engine with the
freeplay and scenery-density changes described below.  Reference source: `ref/cannonball/src/main/engine`
(djyt/cannonball, the classic port; CannonBall DX adds non-classic extras:
do NOT port DX-only behaviour).  Reference harness: `tools/cbref0` (headless
original CannonBall, classic config; `-g trace` per tick state).

The public prototype builds the NEWGAME engine by default. Run
`python3 tools/build.py --mame-roms /path/to/outrun.zip` to generate every
required asset and assemble the ROM. See the root README for prerequisites.
For engine-only edits after asset generation, use `make assemble`.

These notes retain historical references to private reference harnesses and
comparison captures. Those tools and the superseded engine are archived
outside the source release. They are not required by the public build.

## CPU / assembler conventions (SA-1 code)
- Code segment `SA1CODE` (HiROM bank $C1, linked at $0000: jsr/jmp are
  16-bit).  Every routine: entry and exit with A16/I16 (`rep #$30`,
  `.a16 .i16`), DB = $00, D = $0000.  `sep #$20` only locally, restore.
- Data: `BSS` (bank $00 window $6000-$7FFF = BW-RAM, absolute addressing),
  far arrays in `.segment "BWBSS": far` (bank $41, access with `f:`
  long addressing).  Do not add ZEROPAGE variables (ZP is full) except
  where [dp],y pointers are needed: use the shared ZP pointers rp0/rp1
  (3 bytes, caller-saved, outils.s) and ptr0-ptr2 (core.s; ptr0 is used by
  QueueUpload, ptr2 by osprites).
- Constant tables: `RODATA` (bank 0) or a `BANKxx` segment, read with `f:`.
  Never use `f:` on a label in SA1CODE (it resolves to bank $00): data goes
  in RODATA / BANKxx, jump tables (`jmp (tab,x)`) stay in SA1CODE.
- Branches are +-127 bytes: use `jmp` for long ones.
- `xba` swaps bytes: it is a shift by 8 only for values < $100
  (`and #$FF / xba` = `<< 8`).  To take bits 8-15: `xba / and #$FF`.
- SA-1 math unit (registers in bank 0, DB = 0): MAL/MAH, MBL/MBH (16-bit
  `sta MBL` starts a signed 16x16 multiply), result MR..MR+4 after 5
  cycles; math.s has SMul16 (signed) / UMul16 (unsigned) -> `mres` (32-bit,
  ZP), UDiv32_16 (dvd / dvs -> dvd, drem), SDiv16u, SDiv32_16.
- C++ integer semantics must be reproduced exactly: int16 truncation,
  arithmetic right shifts of signed values (`cmp #$8000 / ror a`), logical
  shifts of unsigned, uint8 wrap, int promotion in comparisons (compare as
  signed int when a signed operand is involved: `sec / sbc / bvc :+ / eor
  #$8000 / :` then N flag), truncating division.

## Object entries (oentry) and the jump table
`src/ogame.inc`: field offsets OE_* (64-byte records, same layout as
cbref0's dumps), control bits C_*, anchors DP_*, entry indices SPRITE_*,
`EOFS(i)` = byte offset of entry i.  The table `JT` (osprites.s) is far:
X = entry offset, and the macros LDE/STE/ADCE/SBCE/CMPE/ANDE/ORAE/EORE
(word fields), LDEB/STEB (byte fields: A8 inside, returns A16 masked) do
`lda f:JT+field,x`.  There are no RMW long modes: `inc` a field = LDE /
inc a / STE.  A C++ `oentry* sprite` parameter is X (entry offset).

## Arcade ROM data
The main CPU ROM (rom0) is embedded: arcade address A is at
`$D1 + (A >> 16) : A & $FFFF` (HiROM view, big endian).
- constant address: `lda f:R0(ADDR)` then `xba` for a word (macro
  `R0W ADDR`); bytes: `lda f:R0(ADDR)` / `and #$FF`.
- variable 32-bit address (lo word in A, hi word in Y): `jsr R0Set`
  (outils.s) sets rp0 -> `ldy #n / lda [rp0],y / xba` (word at A+n).
  Helpers: R0Byte (A:Y -> A = byte), R0Word (-> A = word), R0Long
  (-> A = hi word, X = lo word).  A word never crosses a 64 KB bank at an
  even address; longs at +2 may: use R0Long.
- ROM1 (road CPU) data is not embedded (the road engine has its own tables).

## Naming registry (cross-module symbols)
Data = the C++ member name (`oferrari.revs` -> `revs`), except the names
listed with a prefix.  Functions = CamelCase with a module prefix.  Every
module `.export`s the symbols it owns and `.import`s the others.

The authoritative list (asm names and register conventions of every
cross-module routine and variable) is `docs/port_registry.txt`.  Module
files: oroad.s, osprites.s, olevelobjs.s, opalette.s, otiles.s, outils.s,
trackld.s, oferrari.s, ocrash.s, osmoke.s, otraffic.s, obonus.s,
oattractai.s, oinitengine.s, ostats.s, oanimseq.s, oinputs.s, ohud.s,
omap.s, ologo.s, ohiscore.s, omusic.s, outrun.s; SNES adapters: snesin.s
(Input), sndport.s (osoundint), vidport.s (video text/tile/palette RAM).
Porting brief for module ports: `docs/port_agents.md`.

## Testing

For the source release, build local assets first, then run the `check_*.py`
scripts described in the README. The lockstep/reference-capture procedures
below describe historical validation and require the private reference tools
which are not bundled with the public source release.

- Lockstep (logic exactness): `make assemble LOCKSTEP=1`
  (build/outrun_ls.sfc: one tick per frame, no rendering, scripted inputs
  patched into LsInput, stops at LsStopTick) and `tools/lockstep.py [-s
  script] N...` compares the BW-RAM state after N ticks with record N-1 of
  `tools/cbref0 -g` (32 variables, the jump table, the hardware sprite list).
  Gate: `lockstep.py 200 1600 3000 6000` and `lockstep.py -s tools/game1.txt
  1000 2000 3000` (scripts: cbref0 format, "start end KEY..." in ticks).
- Whole game: an autopilot build (`CAFLAGS="-D NEWGAME -D LOCKSTEP -D LSINPUT
  -D AUTOPILOT -D FREEZE_TIMER" OBJDIR=build/lapobj ROM=build/outrun_lsap.sfc`)
  lets the classic attract AI drive the race with the timer frozen (demo gear);
  `lockstep.py -a -r build/outrun_lsap -s script N...` compares it with
  `cbref0 -a` (the same, via a patched oferrari.cpp FORCE_AI hook): all five
  stages, goal, bonus, ending, course map, name entry, back to attract.
  `-D AP_ROUTE=n` picks the forks (bit k set = fork k right; 0 1 7 15 give
  endings A B D E, the default C).
- Pictures: `tools/cmpref.py [-s script] frame...` (LSINPUT build: scripted
  inputs by tick, rendering on) puts SNES frames next to cbref0 frames of the
  tick the SNES frame shows (disp_tick).
- Renderer regressions: `tools/rendergate.py save|check DIR [N...]` (ONETICK
  + RENDERGATE build: one tick per rendered frame, freeze after N rendered
  frames) compares all of VRAM, the OAM, the sprite palette slots and the
  BG3 colours - identical output for pure optimisations.
- Other debug defines: SPRSTOP=n (freeze after n rendered frames), FREEZE_TIMER.
- Real-hardware timing (Mesen 2 headless, ~/Downloads/Mesen.app; SA-1 BW-RAM
  and bus timing like bsnes; settings are never saved): `tools/mesenfps.sh
  [rom]` race fps (frames 1500-3000 / 1500-5500, play2 inputs);
  `tools/mesenprof.sh [rom]` SA-1 ms per tick / per frame by phase (markers
  GameTick, PfTickEnd, PfText, PfRenderEnd in ngmain.s); `tools/mesenpc.sh`
  per-instruction profile in snesrun -p format (`tools/sa1prof2.py`).
  snes9x does not charge BW-RAM wait states: quote Mesen numbers.
  -D NOSPR skips the sprites (speed ceiling of the rest).
- Runtime/audio regressions: `python3 tools/check_runtime.py
  build/outrun_ng.sfc --scenario overtake --song 0` (repeat with 1 and 2).
  The harness moves one active traffic car beyond the overtake boundary
  at a logic-tick boundary. The original ROM stops every music track;
  the corrected adapter treats arcade `S_RESET` ($80) as a no-op, as in
  `OSound::process_command`. `S_FM_RESET` still stops music. The default
  `--scenario grid` measures start-line crowd visibility and flag presence.
- bsnes: Settings > Enhancements overclocking must stay at 100% when judging
  speed or sound (401% made the audio break up).

## Deliberate deviations from CannonBall
- `InputsWheelRead` (oinputs.s, called by MusicEnable): the arcade only
  re-reads the wheel once it moved (adjust_inputs: |change| > 2); a real
  wheel at rest does that through its noise, a digital pad never does, so
  the attract AI's last steering stayed in force (music select showed the
  wrong track, the car drifted at the race start).  cbref0 does the same.
- DsYAdj (osprites.s) keeps the 32-bit product of the 68000 code where the
  C++ truncates to int16 (only differs for (256 - y1) * width >= $8000).
- Music select uses tick_original (the arcade's steering selection);
  CannonBall with 3 configured tracks uses its cursor-based tick_enhanced.
- Music select preview (omusic.s): on, like CannonBall's default config
  (sound.preview = 1): the selected song plays 10 ticks after the selection
  changed.  The original arcade (and cbref0, preview = 0) plays only the wave
  noise there, a sample the SNES sound bank does not hold; -D NO_PREVIEW
  queues the arcade's commands.  Sound commands are not engine state, so
  lockstep is unaffected.


## Console controls and presentation (v9, 2026-10-03)

- Start enters music selection without coins; press Start again to race.
  The blinking prompt is `PRESS START TO PLAY`; credit counters are hidden
  and Select has no coin action. The engine's credit variable is retained
  only as an internal one-game freeplay token. LOCKSTEP retains the arcade
  coin path so reference comparisons remain meaningful.
- B accelerates; the adjacent A button brakes. Y, L or R toggles gear.
  Select opens Settings and pauses the game, including the race timer.
  D-pad moves/changes an option; A captures a replacement button for
  accelerator, brake or gear. B/Start/Select saves and returns. Remapping
  swaps conflicting assignments; unassigned shoulders remain shortcuts
  when gear is mapped to Y. Settings persist in cartridge SRAM.
  `tools/check_console.py ROM`
  tests real joypad input, the free Start flow and pedal/gear state in Mesen.
- Easy is the default: 99 seconds, extra checkpoint time and light traffic.
  Relaxed removes the race time limit; Normal uses arcade timing/traffic;
  Hard uses harder timing and heavier traffic. Difficulty changes apply
  to the next race. `tools/check_settings.py ROM` checks menu navigation,
  remapping, pause restoration, all four modes and SRAM validation/reload.
- Gateway retains one complete stone arch in two (50% fewer groups, v7).
  Groups are kept or removed together, including their collision objects;
  lone pillar groups without beams are omitted. LOCKSTEP preserves the
  original scenery tables and spawn behaviour.
  Each arch is one composite with a shared origin and scale. Small arches
  are complete OBJ images; large roofs use BG to stay within sprite limits.
- The attract logo is a static composition of all seven original parts on
  a dedicated BG page, with a blue background and live Start prompt. It
  avoids the OBJ limits that previously dropped either the oval or text.
  The road resumes when the logo interval ends.
- Eight complete start palms frame the banner and the roadside avenue (v11).
  The nearest two support the banner ropes; three smaller pairs lead down
  the road. Start-only art omits the palms' wide ground shadows to fit the
  full trees, two sign towers, crowd and animated car within the sprite
  budget. Ordinary roadside palm art is unchanged. Both
  start towers share the changing signal palette, so the signal change
  cannot evict every palm's palette, including the final green light and
  a prolonged wait before accelerating. Palette protection ends when the
  tower leaves the screen. The prepared scene retains its BG START banner
  as well as its OBJ decorations. Every flag pose, including the final
  idle loop, has converted black shadow pixels. `tools/check_start_grid.py`
  checks the visible countdown and stationary race, not just the countdown.
- Regenerate changed ROM-derived data with `python3 tools/mksprv3.py` and
  `python3 tools/mkpages2.py`, then `make assemble`. They use the locally
  supplied arcade data, as do the other asset generators.
