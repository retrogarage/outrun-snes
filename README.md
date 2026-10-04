# OutRun SNES — early prototype

An experimental, unofficial OutRun engine port for the Super Nintendo, using
the SA-1 coprocessor. **This is an early prototype, not a finished release.**
Expect bugs, visual and audio differences, and performance limitations. Real
hardware compatibility has not been established. Use an emulator with SA-1
and 8 MiB ROM support; development testing has used Mesen.

This is a **source-only project**. No playable ROM, arcade ROMs, music,
samples, fonts, graphics, screenshots, save states, or converted game assets
are included in the source release. You supply the supported arcade ROM set
locally; the tools extract and convert its assets and build the SNES ROM on
your computer. There is no game-asset downloader and no bundled MAME binary.

## Build locally

Supported build environment: macOS or Linux (Windows users can use WSL).
Required tools: Python 3.10+, `make`, a C++17 compiler, and the `ca65` / `ld65`
tools from [cc65](https://cc65.github.io/). Python dependencies are NumPy and
Pillow. The small YM2151 synthesis library needed for conversion is included
as licensed source under `third_party/ymfm/`.

For example, on macOS install the command-line developer tools, then
`brew install cc65 python`. On Debian/Ubuntu, install `build-essential`,
`cc65`, `python3`, and `python3-venv` through your package manager.

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements.txt
python tools/build.py --mame-roms /path/to/outrun.zip
```

Supply your own **MAME `outrun` set: Out Run (sitdown/upright, Rev B)**.
The argument accepts `outrun.zip`, a directory of extracted chips, or a MAME
ROM directory containing `outrun.zip` or an `outrun/` subdirectory. ZIP members
may be inside subdirectories. Chips are identified by content, so renamed
chips work when their bytes match. Other revisions, enhanced editions,
bootlegs, incomplete sets, and 7z archives are not supported. The 31 required
chips and their sizes/checksums are listed in `tools/rom_manifest.json`.
Unneeded chips in a complete MAME set are ignored.

To validate a set without extracting or building anything:

```sh
python tools/rom_assets.py /path/to/outrun.zip
```

MAME itself does not provide the game ROMs. Obtain and use input files only
where you have the necessary rights. This project provides neither those
files nor a license to them; see [MAME's explanation](https://www.mamedev.org/about.html).

The build validates every chip before importing it into `build/input/`, then
generates graphics, fonts, palettes, level data, music and sound locally.
Conversion can take several minutes. The resulting ROM is
**`build/outrun_ng.sfc`**. Everything in `build/` is local output and excluded
from the source release. The ROM also embeds original arcade program/data
bytes; the source license does **not** grant permission to distribute it.

Subsequent `python tools/build.py` or `make` calls reuse the verified local
input and asset cache. Changes to converter code, dependencies, or generated
files invalidate the cache. Use `--rebuild-assets` to force conversion.
No network access is needed after installing prerequisites. `CXX`, `CA65`,
and `LD65` can select alternative build tools.

## Playing

Use the D-pad to steer and navigate menus, Start to begin, and Select to open
settings where available. The settings menu shows and remaps acceleration,
braking, and gear buttons, and offers Relaxed, Easy, Normal, and Hard modes.
This prototype includes local adaptations for the SNES sprite and scanline
limits; it is not an arcade-perfect reproduction.

## Source releases

```sh
python tools/release.py --check
python -m unittest discover -s tests -v
python tools/release.py
```

Only files explicitly listed in `release-files.txt` are packaged into
`dist/outrun-snes-prototype-source.zip`, with a SHA-256 sidecar. The packager
rejects missing files, symlinks, binary content, unsafe paths, and unexpected
files in the source directories. When run in a Git repository, it also
rejects tracked files outside the allowlist. Review changes to the allowlist
before adding new files. `.gitignore` and `.gitattributes` provide additional
protection; they do not erase files from an existing Git history.

Publish the generated **source ZIP only**. Do not attach your working tree,
`build/`, ROMs, generated assembly/data, media, traces, or old release folders.
There is deliberately no ROM, binary patch, or downloadable game-asset release.
This audit covers the present source tree; it is not a legal clearance opinion.

## Development and credits

The engine is a 65816/SA-1 port derived from
[CannonBall](https://github.com/djyt/cannonball) and
[CannonBall DX](https://github.com/Endprodukt/cannonball-dx), with SNES-specific
rendering, audio conversion, and console integration. Their copyright notices
and noncommercial/source-disclosure conditions are retained in `LICENSE` and
`licenses/CannonBall.txt`. This is not an MIT-licensed project. See
`THIRD_PARTY.md` for the separately licensed library and data provenance.

Release verification: a clean build from the source ZIP and a locally supplied
MAME ZIP reproduced the previously tested ROM byte-for-byte. The 13 synthetic
input/packaging tests and Mesen console/race smoke checks passed. This checks
build reproducibility and basic operation, not complete game correctness.

Engine source lives in `src/`; asset converters and regression tools are in
`tools/`. After generating assets, `make assemble` rebuilds engine code only;
`make assemble LSINPUT=1` and `make assemble LOCKSTEP=1` produce test variants.
The `tools/check_*.py` regressions require a separately installed Mesen and
locally built ROM/symbol files; use each script's `--help`. Development notes
are in `docs/`. Reference emulators, captures, and old engine prototypes are
not part of this release.

OutRun and its game assets belong to their respective rights holders.
This project is not affiliated with or endorsed by SEGA or Nintendo.
