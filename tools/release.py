#!/usr/bin/env python3
"""Audit and package an explicit source-only allowlist. Never package build/."""
import argparse
import hashlib
from pathlib import Path, PurePosixPath
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
IGNORED_ROOTS = {'build', 'dist', '.venv', '.git'}
SOURCE_SUFFIXES = {'.s', '.inc', '.py', '.cpp', '.h', '.ipp', '.md', '.txt', '.json'}
SPECIAL_FILES = {'LICENSE', 'Makefile', '.gitignore', '.gitattributes',
                 'third_party/ymfm/LICENSE'}
# The user-approved README preview is the sole binary documentation exception.
DOCUMENTATION_IMAGES = {
    'docs/screenshots/start-line.png': 'fa848a76baa05f16e004a5c8d83fbdec2cd42a32eea91a27afc4bc13993ae134',
}


def audit(root=ROOT):
    root = Path(root).resolve()
    manifest = root / 'release-files.txt'
    names = [line.strip() for line in manifest.read_text().splitlines()
             if line.strip() and not line.startswith('#')]
    if len(names) != len(set(names)):
        raise ValueError('Duplicate release allowlist entries')
    files = {}
    for name in names:
        relative = PurePosixPath(name)
        if (relative.is_absolute() or '..' in relative.parts or '\\' in name or
                ':' in name or relative.as_posix() != name or
                relative.parts[0] in IGNORED_ROOTS):
            raise ValueError(f'Unsafe release path: {name}')
        if (relative.suffix not in SOURCE_SUFFIXES and name not in SPECIAL_FILES
                and name not in DOCUMENTATION_IMAGES):
            raise ValueError(f'Not a permitted source file: {name}')
        if name.startswith('src/asset_') or name == 'src/scenspacing.inc':
            raise ValueError(f'Locally generated data cannot be released: {name}')
        path = root / name
        if any(p.is_symlink() for p in [path, *path.parents] if p != root.parent):
            raise ValueError(f'Symlink cannot be released: {name}')
        if not path.is_file():
            raise ValueError(f'Missing release source: {name}')
        data = path.read_bytes()
        if name in DOCUMENTATION_IMAGES:
            if hashlib.sha256(data).hexdigest() != DOCUMENTATION_IMAGES[name]:
                raise ValueError(f'Documentation image differs from approved screenshot: {name}')
            files[name] = data
            continue
        try:
            text = data.decode('utf-8')
        except UnicodeDecodeError as exc:
            raise ValueError(f'Binary content in source allowlist: {name}') from exc
        if any(ord(c) < 32 and c not in '\n\r\t\f' for c in text):
            raise ValueError(f'Binary/control content in source allowlist: {name}')
        files[name] = data
    # Do not silently omit newly added source/media from a tree being published.
    def walk(directory):
        for path in sorted(directory.iterdir()):
            rel = path.relative_to(root)
            if rel.parts[0] in IGNORED_ROOTS or path.name == '__pycache__':
                continue
            if path.is_symlink():
                raise ValueError(f'Unapproved symlink: {rel}')
            if path.is_dir():
                walk(path)
            elif rel.as_posix() not in files:
                raise ValueError(f'File not reviewed for release: {rel}')
    walk(root)
    # .gitignore never protects files that have already been tracked.
    if (root / '.git').exists():
        tracked = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z'])
        unexpected = {n.decode() for n in tracked.split(b'\0') if n} - files.keys()
        if unexpected:
            raise ValueError('Tracked files outside source allowlist: ' + ', '.join(sorted(unexpected)))
    return files


def package(files, destination):
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix('.tmp')
    try:
        with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for name, data in sorted(files.items()):
                info = zipfile.ZipInfo('outrun-snes-prototype/' + name, (2026, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = 0o100644 << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, data)
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)
    checksum = hashlib.sha256(destination.read_bytes()).hexdigest()
    destination.with_suffix(destination.suffix + '.sha256').write_text(f'{checksum}  {destination.name}\n')
    return checksum


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Audit only; do not create a ZIP')
    parser.add_argument('--output', type=Path, default=ROOT / 'dist/outrun-snes-prototype-source.zip')
    args = parser.parse_args()
    try:
        if args.output.suffix.lower() != '.zip':
            raise ValueError('Source release output must have a .zip extension')
        files = audit()
        print(f'Source audit passed: {len(files)} approved files, {sum(map(len, files.values())):,} bytes.')
        if not args.check:
            checksum = package(files, args.output)
            print(f'{args.output.resolve()}\nSHA-256: {checksum}')
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f'Release refused: {exc}\n')


if __name__ == '__main__':
    main()
