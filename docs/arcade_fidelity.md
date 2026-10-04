# Arcade fidelity checklist (review vs CannonBall DX classic path, 2026-09-28)

Scope: classic arcade OutRun only (DX config options at original defaults, no DX
extras). DX refs are `ref/cannonball-dx/src/main/engine/...`. Where DX and the Rev B
ROM disagree, the ROM wins (noted "ROM").

## Rendering (being redone: see docs/renderer.md)
- Road: exact port of oroad (road RAM per line) replaces the Mode 7 approximation
  (Bezier hills, polar knots). Fixes road/sprite mismatch (floating cars).
- pos_fine must advance 3x per tick (update_engine + two 60 Hz vint calls).
- horizon_y2 = 224 - (road_y[line0] >> 4); tilemap uses horizon_y_bak averaged per vint.
- Sprites: exact priority order (z16, later insert on top), hill-crest clipping
  (road_p0+0x280 crest list), shadows for traffic + flagged scenery, Ferrari/crash
  shadows priority 0, sprite height = h+1 rows, zoom rounding nearest, draw z16 1-3.
- Level objects: start lights routine (levelobj.s:145 ldy/beq bug), GOAL banner
  unsigned yw*z16 (UMul16), BEST screen routines 0/7/8 by index, stage-3 clouds
  (sprite_clouds), LO_MAX 79, anchors 3/$C.
- Stage change: palette/sky/horizon fade over $80 vints starting at the route
  decision (end_stage_props bit 0), H_SCROLL_TABLE horizon scroll, not instant.

## Player car (oferrari)
- Tyre smoke / off-road dust / water spray (osmoke) missing.
- Brake lights + wheel-rotation palette (pal = 2 + brake bit + wheel bit, speed!=0).
- Race-start drive-in (FERRARI_SEQ1/2, anim 0x12970/0x129C8/0x12A20).
- Off-road/skid shake(); passengers follow.
- Bonus: rev_shift=2; bonus sprite frame selection; speed score in all states but attract.
- Inputs converted after the car update (one tick latency); per-state zeroing.
- set_ferrari_x speed-0 early return (ROM); set_curve_adjust negate before asr.
- Hair frame 0 when stopped; animation counters on every logic tick.

## Traffic (otraffic)
- Catch-up ticks must run the full traffic update (collision etc.), no draw.
- Porsche class 8 zoom x1 (not x2).
- set_max_traffic at every checkpoint (3/4/5/6/7).
- Merge (split state 8): toggle T_RHS on all TICK cars (traffic_split).
- Cars at z16 1-3 counted/drawn; spawn gating (bonus_control, MAP, BEST2).
- Curvature term road_x[z]-road_x[z-8] in angle; incline frame set +$10 (ROM test).
- Rebound: don't set proximity $FF (ROM writes unused byte); frame choice for
  negative offsets (no inc); rebound sound only INGAME/ATTRACT; bonus_lhs.
- Traffic shadows (frame $1193C).

## Game flow / HUD / stats
- Time table Normal $E31A (not Easy $E342).
- Countdown: 31 ticks per BCD second, expire on borrow from 0 (decrement_timers $B736).
- Timers: attract $15, best1 5, logo 4, music $30, game over 3, best2 $30/5/2.
- Flag man at the start (flag_seq, AN_FLAG).
- Attract resumes (car_inc_bak) instead of restarting; BEST1/logo overlay the frozen
  demo scene (no world reset, no fade).
- Lap timer at 60 Hz (+2/tick, wrap 64, LAP_MS_64); live per-stage times incl. stage 5;
  RECORD column; bonus tenths from frame counters.
- Checkpoint LAP time overlay; HUD mini course map; STAGE digit changes at checkpoint.
- HUD gating: timer only START1..INGAME, speed/rev bar freeze, lap blank before INGAME,
  no TIME/SCORE/LAP labels in attract, copyright + flashing texts in attract/best1/logo,
  EXTENDED PLAY starts blank.
- Arcade RNG (outils random, seed $2A6D365A).
- YOUR SCORE without leading zeros; name-entry accumulator; START skips BEST2;
  logo START latched to timeout (ROM).

## Course map / attract / menus
- Map pieces: 28 steps per piece from ROM tables (BOT 0x386C / TOP 0x3784 / END 0x3954).
- Mini car first-piece offset (jmp StRoute).
- Bonus drive AI (check_road_bonus / set_steering_bonus), not attract AI.

## Sound
- Music select: wave ambience only (PCM_WAVE $A4), no preview; song at INIT_GAME.
- Engine: bank-0 recorded loops below revs $30..$51 crossfade (Z80 table $7956).
- Start-line rev one-shot (REVS effect) at revs >= $FA.
- Attract: effects allowed (Advertise Sound on), music blocked; FM_RESET at BEST1/logo.
- Stop music at BEST2 without hiscore; waves + Last Wave on hiscore.
- Traffic pass-by: single pitch drop, arcade-scale fade; table index distance-1;
  base pitch $60; pan from arcade x; only INGAME/ATTRACT; nearest 4 drawn cars.
- Game over: NEW_COMMAND stops all effects; SLIP/SAFETY share one stop.
- The end of an effect (END $84 / finalize $99) also writes the YM release
  block (D1L 15, RR 15) to YM channel (flags & 7): a PCM effect ($46/$47)
  hits channels 6 and 7, whose notes then decay at the patch's D1R and stop
  at once until the channel loads a patch again (Splash Wave's ch6 stays
  short after the race-start GET READY); an FM effect gives channel 7 its
  patch back.  A patch load also resets the channel's L/R bits to the
  patch's (both).

## Crashes / smoke (ocrash, osmoke)
- Smoke plumes: SMOKE_DATA $ACC6 (16 ptr), SPRAY_DATA $AD06 (4 ptr), smoke type
  tables $AC4E/$AC9E (per stage); gating/priority spray > slip > dust > CAR_SMOKE >
  crash smoke; is_slipping flag.
- Spray triggers from water/grass/debris level objects (spray_counter $0C, spray_type).
- Spin direction: negate branches use SPIN2 table ($22D4) (ROM; DX wrong).
- FnLights must Collide (checkpoint/start pillars); FnCheck no collision.
- mksprites FLIPM2 has 16 entries ($24DC).
- Spin slide dead zone (> 2 / < -2, ROM $14CC).
- Bonus check on spin-armed / pending-crash paths; no scenery crash while bonus_control.

## Goal / bonus / endings (oanimseq, obonus)
- mksprites anim blocks end at byte7 bit7 (not n > 64): ending E man, ending A woman,
  flag man block (96 entries).
- Hardware shadow pixels (colour 10) in ending sprites -> shadow palette variants.
- GS_BONUS: no AI/inputs; GoalTick values drive next FerMove (hard brake, screech);
  bonus steering = check_road_bonus/set_steering_bonus.
- Stage 5 time recorded at GS_INIT_BONUS; game_completed; bonus tenths from raw counters.
- Man's ending palette from data (-1), not forced 10 (trophy gold).
- HUD timer frozen after INGAME; traffic spawn stops while bonus_control;
  speed score in GS_BONUS; bonus Ferrari sprite routine; rev_shift 2; bonus_lhs;
  reset an_props+A_FER per game; FerSprites after GoalTick (one-frame double car).

## Scenery tilemaps / palettes (otiles, opalette, olevelobjs)
- Layer order: arcade BG drawn first, FG on top (SNES had them reversed).
- Scroll: visible x = screen x + ((0xC0 - xscroll) & 0x3FF) per page; page tables
  TILES_PAGE_FG1/BG1 (FF10,FF21,FF32,FF03): panorama order FG 0,3,2,1 / BG 0,2,1;
  fgx = (0xE0 - h) & 0x7FF, bgx = (0xE0 - hb) mod 1536, hb = ((h&0x7FF)*3)>>2
  (0xE0 = 0xC0 + 32 centres the SNES window); h = -scr when rd_split_state==0.
- Smoothing mod 2048 (otiles.cpp:554-557, $DAFA), 1/8 per 60 Hz vint (2x per tick).
- Stage change: at the route decision load the next tilemap into the other page set;
  H_SCROLL_TABLE[road_pos] ($30B00) target while rd_split_state < 6; freeze in
  states 1-4; no negation while rd_split_state != 0.
- Palette fades: ground/road 24 colours over 128 vints; sky 31 palettes one per
  2 vints after 65 ticks (opalette.cpp:56-360).
- Vertical: horizon averaged each vint; v-offset 10.
- Object drop shadows (frame $FF56, x += z16*shadow_offset >> 9); hardware shadow
  pen $A for routines 0,1,4-9,11,12; routine 14 wide-road rule; logic-only ticks
  must XPos + Collide (z16 >= $1B0); initial lo_x for start/hiscore objects;
  off-screen cull rules (keep old x, +-160); Yu Suzuki easter egg (opalette.cpp:79).
