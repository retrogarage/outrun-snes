#!/usr/bin/env python3
"""Build the prototype using user-supplied MAME assets, entirely offline."""
import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time
import zipfile
from rom_assets import import_set

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'build'
GEN = BUILD / 'gen'
STAMP = BUILD / 'assets.json'
GENERATORS = [
    'mkembedded', 'mkroaddata', 'mkscenery2', 'mkroad2', 'mkroadkeys',
    'mkrom0', 'mkgame', 'mksprv3', 'mksprgeom', 'mktext', 'mkpages2',
    'mkohb', 'mkscenspacing', 'mksound',
]


def run(command, **kwargs):
    print('+ ' + shlex.join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), cwd=ROOT, check=True, **kwargs)


def tool(value):
    parts = shlex.split(value)
    if not parts or not shutil.which(parts[0]):
        raise ValueError(f'Missing build tool: {value}. See README.md prerequisites.')
    return parts


def fingerprint(cxx):
    digest = hashlib.sha256()
    for directory in ['tools', 'third_party/ymfm']:
        for path in sorted((ROOT / directory).rglob('*')):
            if path.is_file() and path.suffix in {'.py', '.cpp', '.h', '.ipp', '.json', '.txt', '.s'}:
                digest.update(path.relative_to(ROOT).as_posix().encode())
                digest.update(path.read_bytes())
    versions = {name: importlib.metadata.version(name) for name in ['numpy', 'Pillow']}
    versions['python'] = sys.version
    versions['compiler'] = subprocess.check_output(cxx + ['--version'], text=True)
    versions['cxx'] = cxx
    digest.update(json.dumps(versions, sort_keys=True).encode())
    return digest.hexdigest(), versions


def outputs():
    return {p.relative_to(GEN).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(GEN.rglob('*')) if p.is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mame-roms', default=os.environ.get('MAME_ROMS'),
                        help='Local outrun.zip, loose-chip directory, or MAME ROM directory')
    parser.add_argument('--assets-only', action='store_true', help='Import and generate assets without assembling')
    parser.add_argument('--rebuild-assets', action='store_true', help='Ignore the verified asset cache')
    parser.add_argument('--jobs', type=int, default=os.cpu_count() or 1)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error('--jobs must be positive')
    try:
        cxx = tool(os.environ.get('CXX', 'c++'))
        make = tool(os.environ.get('MAKE', 'make'))
        if not args.assets_only:
            tool(os.environ.get('CA65', 'ca65'))
            tool(os.environ.get('LD65', 'ld65'))
        try:
            key, versions = fingerprint(cxx)
        except importlib.metadata.PackageNotFoundError as exc:
            raise ValueError('Install the Python dependencies: python3 -m pip install -r requirements.txt') from exc
        BUILD.mkdir(exist_ok=True)
        lock = BUILD / '.build-lock'
        try:
            lock.mkdir()
        except FileExistsError as exc:
            raise ValueError('Another build is active. If a previous build was killed, remove build/.build-lock after checking it has stopped.') from exc
        try:
            (lock / 'pid').write_text(str(os.getpid()))
            source = args.mame_roms or BUILD / 'input'
            if not args.mame_roms and not Path(source).exists():
                raise ValueError('No game assets supplied. Run: python3 tools/build.py --mame-roms /path/to/outrun.zip')
            import_set(source, BUILD / 'input')
            os.environ['OUTRUN_ROM_DIR'] = str(BUILD / 'input')
            try:
                previous = json.loads(STAMP.read_text()) if STAMP.exists() else {}
            except (ValueError, OSError):
                previous = {}
            if not isinstance(previous, dict):
                previous = {}
            if (not args.rebuild_assets and previous.get('fingerprint') == key and
                    previous.get('outputs') and previous['outputs'] == outputs()):
                print('Verified asset cache is current.', flush=True)
            else:
                STAMP.unlink(missing_ok=True)
                # No old generated files can satisfy a missing pipeline step.
                if GEN.exists():
                    shutil.rmtree(GEN)
                GEN.mkdir()
                for name in ['nobj', 'lobj', 'iobj']:
                    shutil.rmtree(BUILD / name, ignore_errors=True)
                host = BUILD / 'host'
                host.mkdir(exist_ok=True)
                run(cxx + ['-std=c++17', '-O2', '-Ithird_party/ymfm',
                           'tools/fmrender/fmrender.cpp', 'third_party/ymfm/ymfm_opm.cpp',
                           '-o', str(host / 'fmrender')])
                start = time.monotonic()
                for name in GENERATORS:
                    run([sys.executable, '-u', ROOT / 'tools' / f'{name}.py'])
                STAMP.write_text(json.dumps({'fingerprint': key, 'versions': versions,
                                            'outputs': outputs()}, indent=2) + '\n')
                print(f'Generated assets in {time.monotonic() - start:.1f}s.', flush=True)
            if not args.assets_only:
                # Ignore MAKEFLAGS inherited from the outer convenience Makefile.
                env = dict(os.environ)
                env.pop('MAKEFLAGS', None)
                env.pop('MFLAGS', None)
                run(make + ['assemble', f'-j{args.jobs}', f'PY={sys.executable}'], env=env)
                rom = BUILD / 'outrun_ng.sfc'
                print(f'Local ROM: {rom}\nSHA-256: {hashlib.sha256(rom.read_bytes()).hexdigest()}')
                print('Contains user-supplied game assets. Do not include in the source release.')
        finally:
            shutil.rmtree(lock)
    except (ValueError, OSError, subprocess.CalledProcessError, zipfile.BadZipFile) as exc:
        parser.exit(1, f'Build failed: {exc}\n')


if __name__ == '__main__':
    main()
