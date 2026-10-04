# Brief: porting CannonBall engine modules to SA-1 65816 assembly

You are porting one or more modules of the classic OutRun engine (the C++
CannonBall source in `ref/cannonball/src/main/engine`, plus
`ref/cannonball/src/main/trackloader.cpp`) to 65816 assembly for the SNES
SA-1 port in this repository.  The port must be EXACT: the SNES engine is
tested in lockstep against the C++ reference (`tools/cbref0`), tick by tick,
comparing every variable, the object table and the sprite list.  Reproduce
every branch, table read, integer width, sign, truncation and wrap of the
C++ code.  Do not "improve", simplify or re-derive behaviour.

## Read first
- `docs/port.md` - CPU/assembler conventions, object table, ROM access.
- `docs/port_registry.txt` - the asm name of every cross-module symbol and
  the register calling convention of every routine.  Use these names.
- `src/ogame.inc` (included by every module; it includes `src/oaddr.inc`
  = all `oaddresses.hpp` constants plus the sound ids as `S_<NAME>`).
- Example ports in the same style: `src/osprites.s`, `src/olevelobjs.s`,
  `src/outils.s`, `src/trackld.s`; helpers `src/math.s` (SMul16 signed /
  UMul16 unsigned 16x16 -> `mres` 32-bit ZP; UDiv32_16 `dvd`(32) / `dvs`(16)
  -> `dvd` quotient, `drem`; SDiv32_16 `dvd` / A signed; SDiv16u).

## Classic configuration (constant-fold every `config.*` test)
Original arcade behaviour only (no CannonBall enhancements):
engine.fix_bugs = 0, fix_timer = 0, new_attract = 0, freeplay = 0,
freeze_timer = 0, disable_traffic = 0, jap = 0, prototype = 0,
randomgen = 1, level_objects = 0, layout_debug = 0, hiscore_delete = 0,
hiscore_timer = $30, grippy_tyres = 0, offroad = 0, bumper = 0, turbo = 0,
car_pal = 0, dip_time = 1, dip_traffic = 1; controls.gear = GEAR_BUTTON (0),
steer_speed = 3, pedal_speed = 4, analog = 0, rumble/haptic = 0;
smartypi.enabled = 0; sound.advertise = 1, sound.preview = 0,
sound.music_timer = the ROM default (see omusic); fps = 30, tick_fps = 30
(`config.tick_fps == 60` is false; `config.fps == 60` false);
video.fps_count = 0, s16_x_off = 0, widescreen = 0;
outrun.cannonball_mode = MODE_ORIGINAL (time trial / continuous mode code:
omit), outrun.service_mode = false, outrun.custom_traffic = 0.
`outrun.adr.X` = the constant `ADR_X` (oaddr.inc, USA rev B values).
`tick_frame` / `outrun.tick_frame` is always true at 30 fps: code under
`if (!tick_frame)` is dead (omit it), `if (tick_frame)` always runs.
Omit: outputs (ooutputs/motor/lamps), force feedback, rumble, time trial,
debug displays, `cannonball::` fps counters.

## Rules
- Create ONLY the files you are assigned (`src/<module>.s`), wrapped in
  `.ifdef NEWGAME` ... `.endif`, `.p816` `.smart`, include "sa1.inc",
  "globals.inc", "ogame.inc" (and "shared.inc" if needed).  Do not edit
  any other file.  Code in segment `SA1CODE`, variables in `BSS`, arrays
  of more than ~200 bytes in `.segment "BWBSS"` (far: `f:` addressing),
  constant tables in `RODATA` (read with `f:`).  No new ZEROPAGE
  variables: use BSS scratch; the shared ZP scratch `tmp0`-`tmp7` (2 bytes
  each), `ptr0`-`ptr2` (3 bytes), `rp0`/`rp1` (outils) are clobbered by
  any call (never keep a value in them across a jsr).
- Each C++ member variable becomes a BSS variable with the C++ name (width
  = the C++ type: 1-byte types may be stored as bytes (access with
  `sep #$20`) or words; 32-bit = 4 bytes little endian).  Export every
  variable and routine listed for your module in the registry; import the
  others with `.import` / `.importzp` using the registry names.
- A C++ `oentry*` / `oentry&` is an entry byte offset in X (use LDE/STE etc.).
  Arrays of oentry (e.g. `osprites.jump_table.entries[i]`) = `EOFS(i)`.
  `oanimsprite` objects: BSS records with the AS_* layout of ogame.inc,
  owned and exported by oanimseq.s (anim_flag, anim_ferrari, anim_pass1,
  anim_pass2, anim_obj1-anim_obj8); an `oanimsprite*` argument is the
  record's bank 0 address in Y (fields: `lda AS_FRAME,y` etc.).
- Routines: entry/exit A16/I16, DB = 0, D = 0.  Arguments in A, X, Y as
  the registry says; all registers are clobbered by calls (callers save X
  etc. themselves).  Return values in A (bool: A = 0/1).
- Arcade ROM (`roms.rom0.read8/16/32(addr)`): see port.md (R0W / R0Set /
  R0Byte / R0Word / R0Long; data is big endian; 32-bit address in A (low)
  + Y (high)).  `roms.rom0.read16(&addr)` also advances addr by 2.
- Platform calls (implemented by the SNES adapters, just call them):
  - `input.is_pressed(Input::K)` -> `lda #IN_K` / `jsr InIsPressed`
    (A = 0/1); `has_pressed` -> InHasPressed; `is_pressed_clear` ->
    InIsPressedClear.
  - `osoundint.queue_sound(sound::X)` -> `lda #S_X` / `jsr SndQueueSound`;
    `osoundint.engine_data[sound::K] = v` -> `ldx #S_K` / `lda v` /
    `jsr SndSetEngineData`.
  - ohud: `HudBlitText1` / `HudBlitText2` (A = text address);
    `HudBlitSpeed` (A = dst address low word, X = speed);
    `HudDrawLapTimer` (A = dst low word, X = address (bank 0) of the 3-byte
    BCD array, Y = ms byte); `HudDrawScore` / `HudDrawScoreTile` (A = dst,
    Y = font, 32-bit value in `hud_v32`); `HudDrawScoreIngame` (value in
    `hud_v32`); `HudDrawTimer1` (A = time); `HudDrawTimer2` (A = time,
    X = dst, Y = font); `HudDrawStageNumber` (A = dst, X = number,
    Y = colour); `HudTranslate` (A = x, X = y -> A = low word of the text
    RAM address); `HudBlitLargeDigit` (A = digit; the destination is the
    word variable `hud_addr`, advanced like the C++ pointer);
    `HudDrawRevCounter`, `HudDoMiniMap`, `HudDrawMainHud`,
    `HudDrawCredits`, `HudDrawInsertCoin`, `HudDrawCopyrightText`,
    `HudClearTimetrialText` (no args); `HudBlitTextNew` (A = x, X = y,
    Y = bank 0 address of a 0-terminated ASCII string in RODATA, colour in
    `hud_col`).  Text/tile RAM addresses are passed as the LOW 16 BITS of
    the arcade address (text RAM $110000-$110FFF, tile RAM
    $100000-$10FFFF).  `hud_v32`, `hud_addr`, `hud_col` are imported.
  - video: `video.write_text16(a, v)` -> `lda #a` / `ldx #v` /
    `jsr VidWriteText16` (write_text8/32, read_text8, write_tile8/16/32,
    read_tile8 likewise: VidWriteText8, VidWriteText32 (A = addr, X = high
    word, Y = low word), VidReadText8 (A = addr -> A), VidWriteTile8/16/32,
    VidReadTile8, VidReadText16 / VidReadTile16 (A = addr -> A = word);
    `write_pal32(addr, v)` -> VidWritePal32 (A = palette RAM
    address low word, X = high word of the value, Y = low word);
    `video.clear_text_ram()` -> VidClearTextRam; `video.enabled = b` ->
    `lda #b` / `jsr VidSetEnabled`; the pointer-advancing forms
    (`write_text16(&adr, v)`) advance your own variable).
  - `video.sprite_layer->set_x_clip`, `video.tile_layer->set_x_clamp`,
    `patch_tiles`/`restore_tiles`, `setup_palette_widescreen`: omit
    (widescreen only), but keep a comment where they were.
- C++ integer semantics (see port.md): uint8/int8 arithmetic wraps in 8
  bits, int16 stores truncate, `>>` on signed values is arithmetic,
  comparisons of mixed signedness follow C promotion (int16 vs uint16 ->
  both int: sign matters; uint32 vs int -> unsigned), `/` truncates toward
  zero, `%` has the dividend's sign.  Be careful with `bool` and `int8_t`
  loaded from ROM (`(int8_t) read8()` needs sign extension).
- Keep the structure of the C++ (one asm routine per C++ function, same
  order, a one-line header comment `; name (C++ file line)` ), with short
  comments only where the asm is not obvious.

## Check
Assemble each file (must be warning-free):
`ca65 --cpu 65816 -D NEWGAME -I src -I build/gen -I build --bin-include-dir build/gen -o /tmp/x.o src/<module>.s`
Then re-read your port side by side with the C++ one function at a time
and fix discrepancies (width/sign errors are the usual bugs: every `lda`
of a byte field must be masked or use LDEB; every signed compare must use
the overflow-corrected form).

## Report (your final message)
1. Files written, routine count, approximate code size.
2. Exports (asm names) and imports you used that are NOT in the registry
   (with the C++ symbol they stand for and the calling convention you
   assumed), so the integrator can resolve them.
3. Anything omitted or uncertain (with C++ line numbers).
