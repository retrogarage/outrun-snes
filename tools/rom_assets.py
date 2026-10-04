#!/usr/bin/env python3
"""Validate and import a locally supplied MAME Out Run Rev B set. No downloads."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import tempfile
import zipfile

MANIFEST = Path(__file__).with_name('rom_manifest.json')


def manifest():
    return json.loads(MANIFEST.read_text())['files']


def safe_member(info):
    name = info.filename.replace('\\', '/')
    path = PurePosixPath(name)
    if (path.is_absolute() or '..' in path.parts or ':' in name or
            stat.S_ISLNK(info.external_attr >> 16)):
        raise ValueError(f'Unsafe ZIP entry: {info.filename!r}')


def read_set(source, expected=None):
    """Return canonical-name -> bytes after validating every required chip.

    Names may differ between MAME versions; size and SHA-256 identify content.
    No ZIP paths are ever extracted. Unneeded PAL/security chips are ignored.
    """
    expected = manifest() if expected is None else expected
    source = Path(source).expanduser().resolve()
    if source.is_dir():
        if (source / 'outrun.zip').is_file():
            source = source / 'outrun.zip'
        elif (source / 'outrun').is_dir():
            source = source / 'outrun'
    sizes = {entry['size'] for entry in expected}
    wanted = {(entry['size'], entry['sha256']): entry for entry in expected}
    found = {}

    def accept(data):
        entry = wanted.get((len(data), hashlib.sha256(data).hexdigest()))
        if entry:
            found[entry['name']] = data
            # Some sets contain two physically distinct chips with equal data.
            for other in expected:
                if other['size'] == entry['size'] and other['sha256'] == entry['sha256']:
                    found[other['name']] = data

    if source.is_dir():
        # Loose sets are flat; accept an optional MAME set subdirectory above.
        for path in sorted(source.iterdir()):
            if path.is_file() and not path.is_symlink() and path.stat().st_size in sizes:
                accept(path.read_bytes())
    elif source.is_file() and zipfile.is_zipfile(source):
        with zipfile.ZipFile(source) as archive:
            members = archive.infolist()
            if len(members) > 4096:
                raise ValueError('Too many ZIP entries; supply the Out Run set only.')
            for info in members:
                safe_member(info)
            for info in members:
                if not info.is_dir() and info.file_size in sizes:
                    accept(archive.read(info))
    else:
        raise ValueError(f'Expected a local outrun.zip, chip directory, or MAME ROM directory: {source}')
    missing = [entry['name'] for entry in expected if entry['name'] not in found]
    if missing:
        raise ValueError('Missing or incorrect Rev B chips (checked by size and SHA-256):\n  ' +
                         '\n  '.join(missing) + '\nSee tools/rom_manifest.json for required checksums.')
    return found


def import_set(source, destination):
    """Validate before changing any cached input, then stage canonical files."""
    data = read_set(source)
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink():
        raise ValueError('The build input directory must not be a symlink.')
    if destination.exists():
        try:
            if read_set(destination) == data:
                return
        except ValueError:
            pass
    with tempfile.TemporaryDirectory(prefix='rom-import-', dir=destination.parent) as tmp:
        staged = Path(tmp) / 'input'
        staged.mkdir()
        for name, content in data.items():
            (staged / name).write_bytes(content)
        if destination.exists():
            shutil.rmtree(destination)
        os.replace(staged, destination)


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', help='Local ZIP, loose-chip directory, or MAME ROM directory')
    args = parser.parse_args()
    try:
        print(f'Validated {len(read_set(args.source))} Rev B chips. No files extracted.')
    except (ValueError, OSError, zipfile.BadZipFile) as exc:
        parser.exit(1, f'{exc}\n')
