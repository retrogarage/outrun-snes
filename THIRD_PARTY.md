# Third-party source and asset provenance

## CannonBall and CannonBall DX

The `src/o*.s` engine port and related road, sprite, track, HUD, input and
sound logic/models were developed from Chris White and the CannonBall
team's engine and the CannonBall DX fork. Source comments identify the
corresponding upstream functions. These are derivative source implementations,
not a claim of an independently authored or copyright-free engine.

- Upstream: <https://github.com/djyt/cannonball>
- DX fork: <https://github.com/Endprodukt/cannonball-dx>
- Applicable notice and terms: [licenses/CannonBall.txt](licenses/CannonBall.txt)

The license prohibits commercial use and requires complete source with
modified redistributions. This release preserves those conditions. They do
not grant rights to SEGA's ROMs or assets. Reference checkout history and
upstream bundled resources are intentionally absent from the release.

## ymfm

`third_party/ymfm/` contains the unmodified YM2151/OPM subset of Aaron Giles's
ymfm library: `ymfm.h`, `ymfm_fm.h`, `ymfm_fm.ipp`, `ymfm_opm.h`, and
`ymfm_opm.cpp`. Its BSD 3-Clause license and source notices are retained in
[third_party/ymfm/LICENSE](third_party/ymfm/LICENSE).

Upstream: <https://github.com/aaronsgiles/ymfm>. This is generic synthesis
source; it includes no OutRun recordings, instrument patches, or music.
The local `fmrender` helper is compiled from source during asset conversion.

## Local extraction and generated data

`tools/rom_manifest.json` contains filenames, sizes and hashes verified against
[MAME's Out Run driver](https://github.com/mamedev/mame/blob/master/src/mame/sega/segaorun.cpp).
It contains no ROM bytes. MAME is not included or required to run the build.

All arcade pixels, glyphs, palettes, instrument patches, samples, musical
sequences, maps, animations, zoom tables and copied gameplay tables are
read from the user's supplied Rev B ROMs. Converted data and the assembled
ROM stay under `build/` and are not eligible for the source package.

`tools/sprv3use.txt` holds descriptor/zoom usage metadata used to choose which
sprite sizes fit the cartridge. The text converter also has palette-index
usage counts. These are conversion policies and measurements, not stored
images, glyphs, palettes, music, or reference frame dumps.

The numeric Gaussian coefficients in `tools/snesdsp.py` describe the S-DSP's
interpolation response (documented by fullsnes and blargg's SPC_DSP); they are
hardware filter coefficients, not game sound samples. Other numeric constants
describe hardware registers, data layouts, algorithms and conversion policies.
The SPC700 driver in `tools/spc/driver.s` is source code; game audio is supplied
only at local build time.

Python packages, cc65, the C++ toolchain, and optional Mesen installation are
external prerequisites with their own licenses; no executables are bundled.
