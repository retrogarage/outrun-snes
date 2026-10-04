# Renderer v2 (2026-09-28): CannonBall DX rendering pipeline on the SNES

Goal: the SNES shows what the arcade video hardware shows, driven by exact ports
of the DX engine code that produces the render state. Horizontal scale 0.8
(arcade 320 px -> SNES 256 px, keeps the 4:3 geometry and full field of view).

## Reference
- `tools/cbref/`: headless CannonBall DX (engine + hwvideo) with scripted
  inputs. `cbref -n N -o dir -s t1,t2 -d` dumps frame_T.ppm + state_T.bin
  (ROAD/RCTL/SPRT/TILE/TEXT/PAL_/PIXL/ENGN). `-O` road layers only. `-r/-R file`
  road trace: per road tick the inputs at do_road entry and road RAM (+arrays).
  Run in a dir with `roms/outrun.zip` (symlink) and an empty `res/`.
- `tools/snesroad2.py`: arcade road chip model (matches DX frames exactly) and
  the SNES road model (within ~1% edge rounding of the 0.8-scaled arcade).

## Road (replaces the Mode 7 road and the approximate road model)
- Arcade: per scanline road 0/1 data = solid colour (bit 11) or ROM line
  (idx>>1) + index idx for the per-index hscroll (0x200/0x400) and colour
  (0x600) tables; road_control 0-3 = R0 / both P0 / both P1 / R1.
- SNES Mode 1: BG1 = top road, BG2 = other road (both roads use the same
  tiles/map; road 0 and 1 palettes are identical in all levels). Road ROM
  lines resampled to 410 px, 4bpp colours 1-4 = pixel 0/1/2/7, 0 = exterior.
  64x64 map: rows 0-255 phase A palette, rows 256-511 phase B (colour bit).
  Per line (HDMA): BGnHOFS = round(0.8*((hpos-0x5F8)&0xFFF signed)),
  BGnVOFS = row - y, window n = [max(0,-S), min(255,409-S)] (mask outside),
  backdrop CGRAM 0 = exterior colour of the top road (0x420^bg) or the solid
  colour (0x780|c). Solid lines: BG1/BG2 switch to the scenery maps (BGnSC).
- Engine: exact port of DX ORoad (setup_road_x, setup_hscroll, height state
  machine, set_y_interpolate/2044, set_horizon_y, do_road_data, road_p0-p3
  rotation). HDMA built from road_p2 line data + this tick's h tables.
- Known arcade priority cases not reproduced by layer order: road 1 pixel 7
  over road 0 (ctl 1) and road 1 stripes under road 0 (ctl 2). Measure.
- Table build on the S-CPU (2026-10-01, src/sroad.s): the SA-1's RoadRender
  only posts the frame's inputs (shared I-RAM $3710-$372D, SH_RPEND /
  SH_RBUSY) and raises the SA-1 -> S-CPU IRQ.  The IRQ handler (code in WRAM
  $7F:8000) DMAs the inputs from BW-RAM into WRAM (channel 7), clears
  SH_RPEND (RoadSnapWait: the next tick waits for it) and builds the tables
  in WRAM $7F (HDMA channels 1-5 in indirect mode; sky runs are single
  records).  TrySwap waits for SH_RBUSY.  The SA-1 builds the bottom of long
  road runs itself (lines SH_RSA..223; the S-CPU takes 50 road lines) into
  BW-RAM $40:3000 (SR_STG), which the S-CPU copies in.  HDMA writes to
  BG1HOFS share the PPU's Mode 7 byte latch: M7A writes are read back and
  retried.  Checks: -D SRCHECK (the old SA-1 builder runs too, tables
  compared; needs -D NOSPR), -D SRFUZZ (rare cases forced).

## Scenery tile layers (src/otiles.s)
- Arcade FG / BG layers -> BG1 / BG2 maps (64x32) on solid lines. Stage
  pages pre-converted by tools/mkscenery2.py (512 -> 408 px, 51 columns).
- Visible columns are rebuilt when their key (page, column) changes; tiles
  come from a 523-slot VRAM cache streamed through the upload FIFO before
  the swap.  A slot released during the current build is protected (the
  displayed frame may still show it).  Cells without a tile this frame stay
  blank and the column is redone next frame (never stale content).
- Map bands (the rows a layer uses) are mirrored in BW-RAM shadows; up to 6
  changed columns per screen go as column uploads, more as the whole band.
- BG pages (tools/mkpages2.py, scn_page): full-screen pictures on BG1 while
  the road is off - the music select tilemap (page 1) and the course map
  backdrop (page 2: sand fill + map pieces 26-60; the sprite backend
  skips those entries).  Palettes 2-7 (tools/tilepal.py packing), tiles in the scenery
  slots and road tiles 1.. (restored from RoadTiles when the page goes).
  The screen is blanked from the page switch to the next swap (SH_BRIGHTN:
  brightness that comes with a swap).

## Sprites (src/sprv3.s, 2026-10-01)
- Pre-shrunk images (tools/mksprv3.py, run by hand; delete sprdat3.o after
  it - the Makefile does not track build/gen/*.bin): every arcade frame
  descriptor at the hardware zooms seen in traces (tools/sprv3use.txt:
  attract, 16 autopilot routes, random steering) plus sparse levels, 0.8
  horizontal scale, arcade colour indices, 16-row bands cut into 16x16
  pieces; mirrored frames use the OBJ h-flip.  5.5 MB of 4bpp data in an
  8 MB SA-1 ROM (Makefile forces NBANKS=256): metadata in file banks $40..
  (LoROM $80:8000, fixed block 2), pixels DMA'd by the S-CPU through the
  HiROM $E0-$EF window with EXB switched per run.  Landmark frames (START /
  GOAL / CHECK banners, signal tower, gantry, split signs) are marked in
  the descriptor records.
- Entries: normal builds get one 16-byte record per hardware index from
  osprites.s (src/sprrec.inc) instead of the arcade list; LOCKSTEP builds
  keep the exact arcade list (lockstep compares it); -D SPRCHECK builds both
  and compares CandGeom's results per entry.
- Per frame: the car group first, then objects shown last frame, landmarks
  and traffic by visible area (shown 8+ frames x4, last frame x2), then the
  rest by depth (tried every other frame pair).  A shown object keeps its
  cells, palette and lines first, and its previous picture (+-50% size)
  while a new level loads; a refused object stays dropped for a while
  instead of blinking; new objects must leave margins.  Objects that exceed the 34
  slivers per line are withheld as complete shapes; bands are never dropped
  from an admitted object.  8 OBJ palettes re-weighted every 2nd
  frame, changed at most once per 8 frames.  OAM entries are staged and
  copied in depth order (front-most first).
- Budgets: OAM 128, 34 slivers / 32 sprites per line, 128 VRAM cells (the
  displayed frame's protected), DMA_VBL ROM -> VRAM bytes per vblank of the
  frame.  Hard SNES limits still show in dense scenes (palms on the START
  banner's rows, the crowd, long palm rows).
- Debug builds: -D SPRTRAP (integrity traps, record at $40E7F0), -D FLKSTAT
  (flicker statistics, src/sprflk.inc), -D RGFIXDMA (DMA budget independent
  of timing, so tools/rendergate.py compares renderer output again).
- [W1c] The START / GOAL crowds' people and the START's towers are class 3
  (key x 8: small, but what the scene is about); an entry whose palette has
  no OBJ slot may use a loaded palette with the same colours in every index
  its frame uses (PalSubst, tools/mksprv3.py PalSubT; the crowd's palettes
  stand in for each other).

### 2026-10-03: start-line stability and CPU work

- Class 3 also receives landmark admission/palette priority. Once admitted,
  people retain their cells through pose changes instead of yielding them
  to newly loading scenery. A displayed image originally kept its resident pieces
  when newly visible bands could not be uploaded. The complete-object admission
  policy below supersedes that partial fallback.
- Palette weights use the current object's car-group status. BandPass
  restores its band index after LinesOver's clipped, odd-height path.
- At 64+ arcade entries, duplicated scenery shadows are omitted before
  the expensive renderer passes; vehicle/flag shadows and the explicit
  Ferrari shadow remain. The record-building path also uses the previous
  list's count as an early culling hint. HWLIST/LOCKSTEP stays unchanged.
- Staged OAM is copied by a descending hardware-index scan, replacing the
  insertion sort. Hot budget counters live in I-RAM. S-CPU APU polling
  runs from WRAM to reduce cartridge-bus contention with the SA-1.
- Runtime regression: `python3 tools/check_runtime.py build/outrun_ng.sfc`
  measures frames 1000-1800 of a stationary start. It reports object
  visibility, not pixel-perfect completeness; the hardware limits above
  still apply. `--scenario overtake --song 0|1|2` puts one active traffic
  car beyond the overtake boundary and verifies music keeps sequencing.

### Ending rendering (2026-10-03)

- Ending animations reuse crash slots. Shadow conversion now follows the
  actual shadow frame descriptors, and ending-specific admission ranks keep
  the car interior and ending E's extra actor in the visible character group.
  Reused objects discard their previous images and loading/rejection history.
- Ending actors and grandstands require complete visible bands. A cached
  scale of the current actor frame is allowed, but an older animation frame
  cannot be mixed with the new pose. The former partial-resident fallback
  (and its image-pointer repair) has been removed: cached images must now
  pass the same complete-object checks as new images.
- Stationary GOAL banners can stall on scenery-cache fragmentation or on
  their own older, smaller image. A stalled bonus-scene upload releases
  offscreen scenery references; after the bounded retry it also frees the
  held banner. The normal OBJ fallback bridges the replacement.
- `tools/check_endings.py` drives each final stage in an
  `AUTOPILOT/FREEZE_TIMER` build through the full ending and its exit. It
  checks shadow/actor classification, complete admitted shapes, banner scale,
  invalid metadata reads during bonus/ending scenes and the actual hardware
  OAM limits. `--output DIR`
  saves timeline screenshots and visibility counts. The earlier whole-game
  lockstep check also covers ticks 13000, 13500, 14000 and 14500.
- The course-budget adaptation below thins repeated grandstands and reframes
  the cast to fit complete actors. The ending regression now fails on missing
  visible actors; an actor intentionally outside the view is excluded using
  the renderer's geometry key before resource admission. Complete scenery can
  still be withheld when budgets are exhausted.

## Overhead structures on BG (src/ohb.inc, 2026-10-01)
Structures across the road cannot be OBJ (one beam across the screen takes a
line's whole sliver budget: the Gateway's arches showed broken pieces, the
cloud ceiling fragments).  They are drawn on BG1 on the sky lines (the arcade
FG layer only uses map rows 29-31 there) and on BG2 on the road lines just
below the horizon when the bottom road shows nothing (no bottom road, or the
same as the top one).  OhbFrame (SA-1, before RoadRender) writes the per-line
HOFS / VOFS / window words of lines SH_OHBS..SH_OHBN-1 into SR_STG; sroad.s
emits those lines as types 2 (sky: BG1 from the staging) and 3 (road: BG2
from it).  The drawn entries' records are hidden, so the sprite pass leaves
them out; sprites stay in front (map priority 1, OBJ priority 3).
- Line y shows BG line VOFS + y + 1 (as the roads' RR_ROW): VOFS = row - y - 1.
- K1 texture sets (tools/mkohb.py OhbSets): the Gateway beams (frames
  422-426, 15 x 6 tiles) and the cloudy mountain's cloud ceiling (1065-1073,
  6 x 4 tiles, rows sampled centred: the smaller frames are shrunk copies;
  the gaps of a strip's bottom rows filled, the strip behind shows there in
  the arcade).  Per arch half (piece) its exact geometry; per line the
  front-most piece (the halves of an arch paired: the union's window, HOFS
  its left end; halves whose other half is not there are painted behind the
  paired ones), its texture row per line, palette 6 colours 1-7 / 12-15.
- K2 banners (START 531-540, GOAL 1042-1051): the exact images (16 px grid
  pieces, tools/mksprv3.py BGPAIR) in quads of scenery cache slots
  (OtQuadGet: aligned quads only), the map rows in FG map rows 0-9 / 10-19
  (two regions), palette 2 + 2 * a free scenery bank.  Only the pieces on
  screen load (the near banner is mostly above the screen and beyond its
  sides), 12 a frame; the images are stretched to the arcade's exact top
  and height per line.  The next level loads band by band while the shown
  one stays; when VRAM cannot hold both, the next level's complete bands
  show above a split line and the shown level's bands above it go.  The
  seam of the halves (transparent edge columns the arcade overlaps): the
  left image over the right one but for its last column.  While the regions
  hold entries the lines above the FG band are posted masked (with the FG
  scroll the rows 10-19 are on screen there).
- Costs: ~1.75 ms SA-1 in the tunnel; the K2 loads share the frame's DMA
  budget with the sprites (SprV2Frame's budget less ohb_dma).

## Uploads (src/main.s, 2026-10-01)
FIFO entries (sprite runs, scenery / text tiles) are turned into DMA
descriptors outside vblank by V-timer IRQs (lines 96, 150, 196, 216;
NMITIMEN $A1, the IRQ handler also dispatches the road IRQ).  In vblank the
NMI only loads DMA registers from the descriptors against a deadline model
(uploads end before line 261); a complete frame swaps first, and a frame's
last uploads and its swap share a vblank when they fit.  About 3.4 KB per
full vblank (5400 units of 8 master cycles; a sprite run costs bytes x 33/32
+ ~96).

## Text layer (src/textlayer.s)
Arcade text RAM -> BG3 (2bpp): tools/mktext.py packs the colour combinations
used per screen class (race HUD / others) into 8 palettes of 3 colours;
every (tile, arcade palette) is converted for the palette that fits it.
40 -> 32 column maps per row (race HUD rows and the bottom line drop gaps).


## v6: crest clipping, arches and logo (2026-10-03)

Hill clipping retains the final partial 16-pixel band and zeros only its
hidden rows. `src/sprclip.inc` allocates up to 16 private cells per frame;
shared cached images remain untouched. Identical source/cut combinations
reuse the displayed frame's masked cell without another upload. Cell
ownership transfers between the two frame lists to protect displayed data. Entirely hidden images are rejected using signed
height arithmetic. `tools/check_clipping.py ROM` forces every 1..15-row cut
and compares uploaded VRAM with the original pixels, including mirrored OBJ.

The v6 arch joins and density were superseded by v7 below.

The logo is page 3 from `tools/mkpages2.py`, stored in bank $34: 178 tiles,
six BG palettes, zero palette-quantization error. All seven original parts
are composed once. This page uses solid road lines over all 224 scanlines
and suppresses OBJ; road palette flushes wait until page mode ends. Its
static presentation avoids depending on sprite cache, palette, OAM or
per-scanline limits for the lettering and oval to coexist.

## v7: clipped-cell ownership and composite arches (2026-10-03)

Reusing a private clipped cell must claim its bit in `av_now`, just like a
fresh allocation. Transferring it between frame lists alone left it open to
eviction while OAM still referenced it, producing unrelated scenery pixels
under the car. `ClipRemember` now claims both new and reused cells. The
clipping probe checks this ownership invariant rather than skipping cells
whose ownership changed before pixel comparison.

The console spawner keeps alternate complete arches (one in two), assigns
each retained four-part group an identity, and still retains its original
collision objects. `src/arch.inc` selects one visible representative per
identity and hides the other render entries. `tools/mksprv3.py` builds a
single silhouette containing both pillars and the roof, with five distance
descriptors for each of the three stone palettes. Images up to 256 pixels
wide contain the entire arch in OBJ; larger images contain both pillars,
and their roof is painted on BG using the selected image's exact origin,
width and height. Cached fallback levels therefore move every part together.
Unused large levels of the old separate parts are removed to fit the same
8 MB cartridge; sparse originals remain for diagnostic builds.

An arch never admits only some of its visible bands. A wide image whose
roof cannot use the available BG lines falls back as a whole. Arch OBJ uses
priority 2 so nearer BG roofs can occlude complete farther arches. Roofs
are sorted into depth order after sprite admission, before road HDMA is
posted. `tools/check_arches.py` drives an AUTOPILOT/FREEZE_TIMER build and
checks shared roof geometry, complete band admission, missing roofs, depth
order and clipped-cell ownership during Gateway passes.

The composite's centre is projected from the road at its representative's
depth, including road separation. Image selection enforces a minimum span
between the original roadside anchors; smaller cached fallbacks cannot
bring a pillar into a driving lane. Cached images are centred as a whole.

The additional terrain cut reads the displayed `road_p2` scanlines rather
than relying solely on the engine's `road_p0` crest list. A cheap ground
contact check skips ordinary flat-road sprites. Occluded depths use a
binary search for the first nearer road line, at most eight further reads.
The resulting bound applies to traffic, scenery and shadow copies, as well
as the composite roofs. `CopyStaged` also rejects a shadow whose main object
has no staged pieces in the same frame. The arch probe checks terrain cuts
against an independent linear scan of the displayed road, and audits the
shadow-to-parent link before OAM copying.

## v9: scenery capacity and rendering cost

Thin distant images use 8px columns; images no more than eight pixels high
omit the empty lower tile row. Admission accounts for both the 32-object
and 34-tile scanline limits. `ln_disc` records the difference between tile
fetches and object count. The usual tile-limit check bounds most object
counts; nearly full lines get an exact object check. New scenery is tried
from far to near on alternating frame pairs, with shorter bounded retry
waits; already admitted objects retain the first tier.

For a hill-clipped arch with one to seven rows left, private tiles pack the
visible rows at their bottom and lift OAM by the same amount. Screen pixels
stay unchanged, while transparent padding no longer extends below the hill
cut into the car's scanlines. The budget includes overlap with the preceding
band. Cache keys include this packing offset; shared image cells remain
immutable. The clipping probe checks all fifteen cuts and all seven packed
offsets against the source pixels.

The arch silhouette, roadside span, fixed anchor and one-in-two quantity
remain unchanged. Non-anchor parts still update movement and collisions,
but do not build redundant render records. Roadside shadow copies are
omitted before sorting; vehicle and flag shadows retain the parent check.
Once roofs are final, the S-CPU road build overlaps OAM copying and HUD work.
Identical full curve inputs reuse the projected horizontal road table, and
the text tile cache stores complete map entries for repeated HUD updates.

These changes do not make every arcade object fit. Dense scenes, especially
crash animations among arches, can still exhaust cells, OAM or scanlines.
`tools/measure_scenery.py` reports admission and frame timing; its visibility
metrics are approximate and include partial objects. The arch probe fails
on visibility gaps by default. `--report-visibility` measures those gaps for
stress comparisons, while geometry, ownership and hardware overflow remain
hard failures. See the release notes for measurements and remaining limits.

## v10: start scene after the green light

The start-scene lock must retain entries 46/47 explicitly: the START banner
uses BG1 and therefore has no staged OBJ pieces. Inferring the entire scene
from OBJ admission alone removed it at reveal. The tower palette update
continues into gameplay while the original tower is enabled, including the
green palette 125. It replaces the existing tower slot, synchronizes both
towers, and cancels only a queued replacement of that same slot. It stops
when the tower is passed or its entry is recycled. This preserves the palms'
palette without interfering with later roadside palette scheduling.

The asset generator walks all flag animation blocks, including the terminal
idle loop. Driving traces did not include poses 711–713; their missing mode-2
images previously fell back to ordinary colour-10 pixels, producing a green
patch. These poses now have their own converted, dithered shadow images.
The start regression checks every visible frame through a stationary wait,
requires both banner halves on BG, and inspects the actual selected flag
image tiles for unconverted shadow pixels. These changes do not alter arch
geometry, placement, density or admission rules.


## v11: complete banner supports and eight start palms

The starting-grid cohort is now palm entries 6/7, 8/9, 12/13 and 19/20.
The original placement is staggered: 19 is the right banner support and 20
is the left one. Trees 16/17 sit inside the ropes and cannot support them.
Choosing smaller inner pairs leaves room for the actual supports and both
sign towers, four spectators, the flag animation and the player's car.

Five additional descriptors hold start-only palm art with colour-10 ground
shadows removed. Tree pixels, descriptor geometry and world positions stay
unchanged. CandRaw selects these copies only for tagged initial palms;
recycled road objects still select the original art. All 1,157 original
sprite/arch descriptors retain identical zoom maps, piece layouts and pixels.

Keep the initial residents' ground contact unclipped after green as well as
through the countdown. Their quantized feet do not need private tile copies
on the flat starting grid. ClipRoadGeom still applies actual displayed-road
occlusion. START banner geometry remains with its BG renderer. The BG banner
mask covers both reserved map regions, preventing leftover map entries from
appearing in the sky above it.

`tools/check_start_grid.py` now requires the eight trees, both towers, four
spectators, flag and Ferrari/passengers to be complete through the visible
countdown and stationary race. It also audits actual final OAM against the
32-object/34-tile scanline limits, checks the car has reached its current
pose, and checks the entire flag idle loop for unconverted shadow pixels.

## Rendering hot paths (2026-10-03)

`BandPass` checks `SL_NRES == SL_NP` once per image to skip missing-piece
scans for complete cached slots. Partial hill bands still reserve private
cells. `ClaimWideBand` uses a compact loop for every ordinary 16x16 band,
including partly resident images; `ClaimNewRun` supplies missing runs to
both it and the general loop. Resident counts are committed once per run,
after eviction. The current slot is stamped before this pass, preventing
its removal if its resident count temporarily reaches zero during eviction.
The loop retains cell ownership, the OAM limit and the ninth X bit. Mirrored
padding can extend left of the screen even when the image bounds are inside
it, so this loop must not infer the X bit from those bounds. The current
band's short-height flag lives in direct page instead of being looked up
again for each piece. `LinesAddBoth` updates slivers and OBJ discounts in
one traversal, including clipped ranges with an odd number of rows.

`sprclip.inc` now queues one compound command per new private cell instead
of up to six commands. `streamclip.inc` implements both background-converted
descriptors and the NMI's Direct fallback. The command copies the source
and masks its hidden rows before acknowledging the FIFO entry. Packed cuts
retain the same lifted pixels and duplicated lower tiles. No staging buffer
or SA-1 pixel work is needed. The original sprite-admission charges remain
unchanged; separate, measured S-CPU costs bound the vblank work. The new path
uses fourteen S-CPU scratch bytes. Six per-piece sprite variables move
from I-RAM to direct page, saving address-fetch cycles in the inner loops.
That pass used 255/256 direct-page bytes and 1,203/1,280 I-RAM bytes.

`RdMemo` canonicalizes flat interpolation inputs when `height_ctrl2 == 0`
and all six upcoming elevation deltas are zero. Advancing the section
lengths or interpolation counters then produces the same constant-slope
road. The existing five-tick guard still warms all four rotating buffers;
horizon changes and transitions to non-flat data invalidate the memo. The
height state machine and crest metadata still run every tick.

The text adapter tracks the first and last changed native columns per row
(128 bytes in BW-RAM). `BuildRow` resolves only that span through the active
SNES column map; it still uploads the same complete 64-byte row. Clear,
cache flush, layout changes and settings restoration invalidate all columns.
Both cells of a 32-bit write are marked. Forward and inverse column maps
are assembled from one definition, with monotonicity assertions.

Mesen at stock timing, compared with v11 using identical input scripts:

| Measurement | v11 | First pass | Final |
| --- | ---: | ---: | ---: |
| Driving, vblanks 1500–3000 | 22.68 FPS | 23.52 FPS | 25.64 FPS |
| Normal difficulty, vblanks 1500–5500 | 23.31 FPS | 24.12 FPS | 26.11 FPS |
| Logic, short driving run | 12.01 ms/tick | 12.05 ms/tick | 11.00 ms/tick |
| Sprite phase, short driving run | 23.02 ms/frame | 22.11 ms/frame | 21.65 ms/frame |
| Text phase, short driving run | 1.37 ms/frame | 1.38 ms/frame | 0.49 ms/frame |

The final improvement is 13.1% in the short run and 12.0% in the longer
run. Reproduce with `tools/mesenprof.sh ROM 1500 3000` and
`python3 tools/measure_scenery.py ROM`. These retain stock SA-1 timing and
the existing image levels, palettes, object limits and admission charges.

These are scenario measurements, not a locked 30 FPS result. Logic remains
at 30 Hz. With normal adaptive timing, faster rendering samples different
logic ticks and can change frame-dependent admission histories; fixed-tick
comparisons isolate renderer equivalence from that scheduling effect.

The regression gate matches v11 byte-for-byte in VRAM, displayed OAM,
sprite-palette slots and BG3 colours at rendered frames 20, 60, 120, 200,
300, 420, 560, 700, 1000 and 1600. Build both reference and candidate with
`NEWGAME`, `LSINPUT`, `ONETICK`, `RENDERGATE` and `RGFIXDMA`; the last flag
fixes the admission budget so CPU timing cannot change the comparison.
Use `tools/rendergate.py save DIR ...` before the change and `check DIR ...`
afterwards.

`tools/check_clipping.py ROM` also measures compound uploads against their
stream cost reservations. `--direct-stream` patches only the temporary
probe ROM to disable background conversion and exercise the NMI fallback.
For all seven packed cuts, use an `AUTOPILOT` / `FREEZE_TIMER` build with
`--from-frame 5500 --frames 9000 --require-packed`, with and without
`--direct-stream`. The start-grid and arch probes continue checking complete
objects, geometry, cell protection and hardware scanline limits.

Clipping probes check every completed compound upload immediately after
its final DMA and sample cached cells again when the FIFO drains. Only
live private cells in the two OAM generations are valid cached samples:
a retired cell can have been reused and freed while the FIFO stayed busy.
`--trace PATH` saves pixel samples, frame numbers and timing counters.

`python3 tools/check_text.py ROM` checks all 6,240 possible dirty spans and
compares every clean text-map row with a full rebuild through attract,
settings, race and pause/restore. The final run checked 960,928 map cells.
Settings navigation/remapping/SRAM tests pass, as do engine lockstep checks
against CannonBall at ticks 300, 700, 1600, 3000 and 6000. The start-grid
probe retains the complete crowd, palms, towers and flag. The 11,000-frame
Normal arch run has no geometry, ownership or scanline errors; it records
one single-frame capacity dropout, so these speed gains do not remove all
existing scene-capacity limits.

### Exact ROM tables and OAM batches (follow-up)

The next pass trades unused ROM space for exact runtime results, with no
changes to source artwork, zoom levels, palettes or admission budgets:

- `tools/mksprgeom.py` interns the 128 zoom results for each distinct source
  width and height. `ExactSpriteSize` reads these fixed-bank-CF tables instead
  of multiplying and shifting twice per candidate. The tables reproduce the
  original `MR+1` truncation before rounding, rather than a mathematical
  ceiling that would differ by a pixel for some sizes. Top clipping still
  computes its own exact skipped-row height.
- `tools/mkroadkeys.py` assigns collision-free IDs to the complete write
  results of `SetupXData`. Keys include marker prefixes and untouched entries.
  A ROM lookup replaces comparison/copying of 66 path vectors, and also
  permits reuse when different vectors produce identical results. The
  81,467-byte index covers 40,681 positions in all 17 distinct paths, with
  21,289 result classes. Consecutive reusable positions increase from 12,405
  to 15,945. Positions outside the generated range retain the original input
  comparison and projection. Changing between that fallback and the indexed
  path invalidates the appropriate memo.
- Uniform 8x8 OAM groups clear their size bits in batches. Groups of up to
  four entries use one mask; larger groups handle their boundary bytes and
  interior separately. Mixed-size groups and ninth-X bits retain explicit
  handling, including a short sprite's right half crossing X=256.
- `BandPass` computes short-band eligibility once per image and retains each
  band's unclamped OAM Y. `ClaimPass` reuses that Y and skips pixel-source and
  band-stride setup when no uploads are required.

Both generated tables rebuild automatically through `make assemble` when
their metadata inputs change. The ROM remains 8 MiB. This build uses
255/256 direct-page bytes and 1,260/1,280 I-RAM bytes; OAM size classification
adds 256 bytes in ordinary BW-RAM.

| Stock-timing measurement | Previous pass | Follow-up |
| --- | ---: | ---: |
| Driving, vblanks 1500–3000 | 25.64 FPS | 26.04 FPS |
| Normal, longer scenery run | 26.11 FPS | 26.48 FPS |
| Logic, short run | 11.00 ms/tick | 10.83 ms/tick |
| Sprite phase, short run | 21.65 ms/frame | 21.25 ms/frame |

The additional FPS gain is 1.4–1.6%, and remains workload-dependent. The
short-run gain over v11 is 14.8%. Renderer speed changes the sequence of
sampled ticks and resource-admission histories, so small instruction savings
do not map directly to a proportional FPS increase. This is still not a
locked 30 FPS result.

`tools/check_precomputed.py ROM` checks every linked sprite-size entry and
every road-key equivalence class. To compare the generated road model with
the actual 65816 implementation at every covered position:

```sh
make assemble CAFLAGS='-D NEWGAME -D ROADKEYCHECK' \
  OBJDIR=build/roadcheck-obj ROM=build/roadcheck.sfc
python3 tools/check_precomputed.py build/outrun_ng.sfc \
  --probe-rom build/roadcheck.sfc
```

The diagnostic build calls the original projection at all 40,681 positions;
all 448 output words per position match byte-for-byte. It also validates
297,472 sprite dimensions. The ten v11 render-gate snapshots remain identical,
and CannonBall lockstep passes through tick 6000. Settings, SRAM, start-grid
and text checks pass. The 11,000-frame Normal arch probe reports no geometry,
ownership or hardware-limit errors; it records two single-frame capacity
dropouts. Capacity limits therefore remain, and adaptive runs do not promise
identical dropout histories.

Clipping checks cover all 15 ordinary and seven packed cuts, including
mirrors and cached reuse: 21,404 completed uploads pass across normal and
forced-Direct runs, with zero stream-budget violations.

Experimental endpoint-only scanline counters, lazy discount counters and
per-slot ownership bitmaps were measured and removed: their reconstruction
or cache-maintenance costs erased the expected gain. Measurements and probe
outputs for this pass are in `build/perf-next/`. The instruction profiler now
uses the same Start-button sequence as the phase benchmark.

### Course sprite budgets (2026-10-04)

- `scenbudget.s` adapts repeating scenery at spawn time. Normal decorations
  and the alternate anchoring/zoom routines have a deterministic minimum distance
  per type and road side, derived from source dimensions (16–40 road units;
  grandstands 48). This reduces both renderer work and active engine entries.
  Removed objects have their enable/zoom/depth cleared, so they leave no
  invisible collision boxes. Start residents, landmarks, people, goal supports,
  continuous ground/water/clouds, spray triggers and grouped arches retain their
  existing policies. The history resets with road-position resets and new games.
  `python3 tools/mkscenspacing.py --check` verifies the generated table.
- Every object requires all of its visible bands and OAM pieces. Normal screen
  and hill clipping still apply. A complete cached scale may bridge an upload,
  but a partially resident image cannot be displayed. Allocation failures after
  preflight roll back staged OAM and its 8x8 size flags; conservative line/cell
  reservations remain until the next frame. Thus unexpected cache pressure
  cannot publish a fragmented object or overbook the frame.
- Ending cast layers share a fixed 9/16 transform around (128, 200), including
  shadows and clip boundaries. The arcade-sized overlapping car/characters
  exceed the line budget by themselves; thinning grandstands alone cannot fix
  them. This changes the ending framing, while race camera geometry and the
  animation simulation remain unchanged. Frame/zoom quantization means a larger
  transform is not always cheaper: 5/8 still loses the female actor in ending E.
- This is a density/framing adaptation, not an exact arcade-visual match.
  The final renderer can still withhold whole decorations when traffic, hills,
  palette pressure or overlapping structures exhaust the available resources.
  Limits remain 128 OAM entries, 32 OBJs and 34 8-pixel tiles per scanline,
  eight palettes and 128 cached VRAM cells.
- `tools/check_scene_budget.py` selects and drives all 15 courses through the
  split/goal and audits every completed frame's actual OAM, including negative
  coordinates and vertical wrapping. It checks every admitted object's piece
  count and reports rejected draw attempts separately. `--stress-allocation
  --course 0` forces cell exhaustion after preflight and checks atomic rollback.
  Use an `AUTOPILOT/FREEZE_TIMER/AP_ROUTE=0` build. `check_endings.py` additionally
  rejects missing visible ending actors across all five complete timelines.
- Validation: all 15 courses passed over 38,501 rendered frames and 426,585
  complete object draws. All five endings passed another 2,697 frames with
  zero missing visible actors. The allocation test passed 146 forced failures;
  clipping checked 10,778 uploads / 29,963 masked pieces, all 15 cuts and seven
  packed cuts, with zero stream-budget violations. The production start-grid
  check passed 830 frames. Logs and ROM hashes are in
  `build/scene-budget/final/verification.json`.
