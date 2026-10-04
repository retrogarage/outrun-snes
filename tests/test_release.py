"""Source release / input boundary tests. Fixtures contain no game assets."""
import hashlib
import json
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import rom_assets
import release


class RomImportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.data = b'SYNTHETIC TEST CHIP - NOT A GAME ROM'
        self.expected = [{'name': 'chip.test', 'size': len(self.data),
                          'sha256': hashlib.sha256(self.data).hexdigest()}]

    def zip(self, entries):
        path = self.root / 'outrun.zip'
        with zipfile.ZipFile(path, 'w') as archive:
            for name, data in entries:
                archive.writestr(name, data)
        return path

    def test_renamed_chip_in_merged_zip(self):
        source = self.zip([('outrun/renamed.test', self.data), ('extra.txt', b'extra')])
        self.assertEqual(rom_assets.read_set(source, self.expected), {'chip.test': self.data})

    def test_mame_directory_and_loose_directory(self):
        self.zip([('chip.test', self.data)])
        self.assertEqual(rom_assets.read_set(self.root, self.expected)['chip.test'], self.data)
        (self.root / 'outrun.zip').unlink()
        (self.root / 'outrun').mkdir()
        (self.root / 'outrun/renamed.test').write_bytes(self.data)
        self.assertEqual(rom_assets.read_set(self.root, self.expected)['chip.test'], self.data)

    def test_equal_chips_are_both_materialized(self):
        expected = self.expected + [{**self.expected[0], 'name': 'duplicate.test'}]
        source = self.zip([('chip.test', self.data)])
        self.assertEqual(set(rom_assets.read_set(source, expected)), {'chip.test', 'duplicate.test'})

    def test_corrupt_or_incomplete_set_rejected(self):
        source = self.zip([('chip.test', self.data[:-1] + b'!')])
        with self.assertRaisesRegex(ValueError, 'Missing or incorrect'):
            rom_assets.read_set(source, self.expected)

    def test_unsafe_zip_paths_and_symlinks_rejected(self):
        for name in ['../escape', '/escape', 'C:/escape', '..\\escape']:
            with self.subTest(name=name):
                source = self.zip([('chip.test', self.data), (name, b'unused')])
                with self.assertRaisesRegex(ValueError, 'Unsafe ZIP'):
                    rom_assets.read_set(source, self.expected)
        link = zipfile.ZipInfo('link')
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        source = self.zip([('chip.test', self.data), (link, b'/tmp/target')])
        with self.assertRaisesRegex(ValueError, 'Unsafe ZIP'):
            rom_assets.read_set(source, self.expected)

    def test_failed_import_does_not_replace_cached_inputs(self):
        destination = self.root / 'build/input'
        destination.mkdir(parents=True)
        (destination / 'chip.test').write_bytes(self.data)
        source = self.zip([('chip.test', b'bad')])
        with patch.object(rom_assets, 'manifest', return_value=self.expected):
            with self.assertRaises(ValueError):
                rom_assets.import_set(source, destination)
        self.assertEqual((destination / 'chip.test').read_bytes(), self.data)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'src').mkdir()
        (self.root / 'src/main.s').write_text('; synthetic source\n')
        (self.root / 'release-files.txt').write_text('release-files.txt\nsrc/main.s\n')

    def test_local_roms_are_never_packaged(self):
        (self.root / 'build/gen').mkdir(parents=True)
        (self.root / 'build/gen/copied.s').write_bytes(b'PRIVATE ASSET DATA')
        (self.root / 'build/local.sfc').write_bytes(b'PRIVATE ROM')
        target = self.root / 'dist/source.zip'
        first = release.package(release.audit(self.root), target)
        second = release.package(release.audit(self.root), target)
        self.assertEqual(first, second)
        with zipfile.ZipFile(target) as archive:
            self.assertEqual(sorted(archive.namelist()), [
                'outrun-snes-prototype/release-files.txt', 'outrun-snes-prototype/src/main.s'])

    def test_unlisted_media_is_rejected(self):
        (self.root / 'src/screenshot.png').write_bytes(b'fake media')
        with self.assertRaisesRegex(ValueError, 'not reviewed'):
            release.audit(self.root)

    def test_binary_disguised_as_source_is_rejected(self):
        (self.root / 'src/main.s').write_bytes(b'\x00\xffROM')
        with self.assertRaisesRegex(ValueError, 'Binary'):
            release.audit(self.root)

    def test_source_symlink_is_rejected(self):
        (self.root / 'src/main.s').unlink()
        (self.root / 'src/main.s').symlink_to(self.root / 'release-files.txt')
        with self.assertRaisesRegex(ValueError, 'Symlink'):
            release.audit(self.root)

    def test_missing_source_is_rejected(self):
        (self.root / 'src/main.s').unlink()
        with self.assertRaisesRegex(ValueError, 'Missing release'):
            release.audit(self.root)

    def test_forbidden_allowlist_paths_are_rejected(self):
        for name in ['build/gen/data.s', '../outside.py', '/absolute.py', 'src/rom.sfc']:
            with self.subTest(name=name):
                (self.root / 'release-files.txt').write_text('release-files.txt\n' + name + '\n')
                with self.assertRaises(ValueError):
                    release.audit(self.root)

    def test_already_tracked_rom_is_rejected(self):
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        (self.root / 'build').mkdir()
        (self.root / 'build/rom.sfc').write_bytes(b'fake ROM')
        subprocess.run(['git', '-C', str(self.root), 'add', 'build/rom.sfc'], check=True)
        with self.assertRaisesRegex(ValueError, 'Tracked files outside'):
            release.audit(self.root)


if __name__ == '__main__':
    unittest.main()
