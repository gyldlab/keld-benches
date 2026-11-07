#!/usr/bin/env python3
"""Fixture-local source provenance tests; NOT a benchmark runner or result oracle."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
EXPECTED_SHA256 = '236ffe4a7936e1d541b50e26f070177085dcdf5779055e67de6ba379801ba7a3'
EXPECTED_BYTES = 1040
EXPECTED_GEOMETRY = {
    'keld-test-rectangle': (190, 80, 220, 100),
    'x54JlCnLDrUjkCjbq0Pr-1': (320, 210, 60, 30),
}


def check_xml_geometry(raw: bytes) -> None:
    try:
        root = ET.fromstring(raw)
    except ET.ParseError as error:
        raise ValueError('malformed XML source document') from error
    if root.tag != 'mxfile' or len(root.findall('diagram')) != 1:
        raise ValueError('expected one original draw.io mxfile diagram')
    for cell_id, expected in EXPECTED_GEOMETRY.items():
        matches = root.findall(f".//mxCell[@id='{cell_id}']")
        if len(matches) != 1:
            raise ValueError(f'expected exactly one geometry cell {cell_id}')
        geom = matches[0].find('mxGeometry')
        if geom is None:
            raise ValueError(f'missing geometry for {cell_id}')
        try:
            found = tuple(int(geom.get(k, '')) for k in ('x', 'y', 'width', 'height'))
        except ValueError as error:
            raise ValueError(f'invalid geometry for {cell_id}') from error
        if found != expected:
            raise ValueError(f'changed initial scene geometry for {cell_id}')


def check_fixture(raw: bytes, manifest: dict) -> None:
    if len(raw) != EXPECTED_BYTES:
        raise ValueError('unexpected fixture byte count')
    if hashlib.sha256(raw).hexdigest() != EXPECTED_SHA256:
        raise ValueError('source bytes differ from immutable staged input')
    check_xml_geometry(raw)
    if manifest.get('scene_file') != 'scene.drawio':
        raise ValueError('wrong source file identity')
    if manifest.get('scene_bytes') != EXPECTED_BYTES:
        raise ValueError('wrong declared source byte count')
    if manifest.get('scene_sha256') != EXPECTED_SHA256:
        raise ValueError('wrong declared source digest')
    if manifest.get('source_kind') != 'retained_original_editor_application_created_pre_edit_backup':
        raise ValueError('source provenance was changed')
    if manifest.get('historical_prelaunch_input_verified') is not False:
        raise ValueError('app-created backups are not independent historical prelaunch inputs')
    if manifest.get('ready_for_scored_performance_comparison') is not False:
        raise ValueError('source fixture is not a scored original-editor comparison')
    rows = manifest.get('expected_pre_edit_geometry')
    if not isinstance(rows, list) or len(rows) != len(EXPECTED_GEOMETRY):
        raise ValueError('manifest geometry set drift')
    observed = {}
    for row in rows:
        if not isinstance(row, dict) or row.get('cell_id') in observed:
            raise ValueError('invalid or duplicate source geometry row')
        observed[row.get('cell_id')] = (row.get('x'), row.get('y'), row.get('width'), row.get('height'))
    if observed != EXPECTED_GEOMETRY:
        raise ValueError('manifest geometry no longer matches original source')


def read_regular_file_no_follow(path: Path, maximum_bytes: int) -> tuple[bytes, os.stat_result]:
    """Pin one opened regular inode and reject in-read replacement/mutation."""
    prior = path.lstat()
    if not stat.S_ISREG(prior.st_mode):
        raise ValueError('not a regular non-symlink file')
    if not hasattr(os, 'O_NOFOLLOW'):
        raise ValueError('native no-follow open is required')
    fd = os.open(
        path, os.O_RDONLY | os.O_NOFOLLOW
        | getattr(os, 'O_CLOEXEC', 0) | getattr(os, 'O_NONBLOCK', 0),
    )
    try:
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode):
            raise ValueError('opened file is not a regular file')
        if opened.st_size > maximum_bytes:
            raise ValueError('file larger than allowed byte bound')
        raw = os.read(fd, maximum_bytes + 1)
        after = os.fstat(fd)
    finally:
        os.close(fd)
    final_path = path.lstat()
    stable = (
        prior.st_dev == opened.st_dev == after.st_dev == final_path.st_dev
        and prior.st_ino == opened.st_ino == after.st_ino == final_path.st_ino
        and prior.st_size == opened.st_size == after.st_size == final_path.st_size
        and prior.st_mtime_ns == opened.st_mtime_ns == after.st_mtime_ns == final_path.st_mtime_ns
        and prior.st_ctime_ns == opened.st_ctime_ns == after.st_ctime_ns == final_path.st_ctime_ns
    )
    if not stable:
        raise ValueError('file changed during prelaunch read')
    return raw, opened


def attest_before_launch(arm: str, attempt_id: str) -> dict:
    """Bound one intended attempt to current source bytes; never attest app work."""
    if arm not in ('baseline', 'candidate', 'electron'):
        raise ValueError('unknown measurement arm')
    try:
        if str(uuid.UUID(attempt_id)) != attempt_id:
            raise ValueError('noncanonical attempt ID')
    except (TypeError, ValueError) as error:
        raise ValueError('attempt ID must be a canonical UUID') from error

    source = HERE / 'scene.drawio'
    manifest_path = HERE / 'source-manifest.json'
    started_utc = datetime.now(timezone.utc).isoformat()
    started_monotonic_ns = time.monotonic_ns()
    raw, opened = read_regular_file_no_follow(source, EXPECTED_BYTES)
    manifest_bytes, _ = read_regular_file_no_follow(manifest_path, 65536)
    manifest = json.loads(manifest_bytes)
    if not isinstance(manifest, dict):
        raise ValueError('manifest must be a JSON object')
    check_fixture(raw, manifest)
    finished_monotonic_ns = time.monotonic_ns()
    return {
        'schema': 'keld31-source-prelaunch-custody-v1',
        'status': 'source_bytes_verified_only',
        'attempt_id': attempt_id,
        'arm': arm,
        'checked_utc': started_utc,
        'source_path': str(source.absolute()),
        'source_sha256': hashlib.sha256(raw).hexdigest(),
        'source_bytes': len(raw),
        'manifest_sha256': hashlib.sha256(manifest_bytes).hexdigest(),
        'source_device': opened.st_dev,
        'source_inode': opened.st_ino,
        'source_mtime_ns': opened.st_mtime_ns,
        'read_started_monotonic_ns': started_monotonic_ns,
        'read_finished_monotonic_ns': finished_monotonic_ns,
        'app_launched_by_check': False,
        'app_loaded_source_verified': False,
        'equivalent_work_verified': False,
        'performance_admitted': False,
    }


class SourceFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.raw = (HERE / 'scene.drawio').read_bytes()
        cls.manifest = json.loads((HERE / 'source-manifest.json').read_text(encoding='utf-8'))

    def test_unmodified_original_real_bytes(self) -> None:
        check_fixture(self.raw, self.manifest)

    def test_tampered_byte_rejected(self) -> None:
        altered = bytearray(self.raw)
        altered[-17] ^= 1
        with self.assertRaises(ValueError):
            check_fixture(bytes(altered), self.manifest)

    def test_truncated_file_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, 'byte count'):
            check_fixture(self.raw[:-1], self.manifest)

    def test_geometry_change_rejected_even_without_digest_check(self) -> None:
        modified = self.raw.replace(b'x="190"', b'x="200"', 1)
        self.assertNotEqual(modified, self.raw)
        with self.assertRaisesRegex(ValueError, 'geometry'):
            check_xml_geometry(modified)

    def test_malformed_xml_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, 'malformed XML'):
            check_xml_geometry(b'<mxfile><diagram>')

    def test_false_historical_prelaunch_assertion_rejected(self) -> None:
        wrong = dict(self.manifest, historical_prelaunch_input_verified=True)
        with self.assertRaisesRegex(ValueError, 'historical prelaunch'):
            check_fixture(self.raw, wrong)

    def test_false_scored_measurement_assertion_rejected(self) -> None:
        wrong = dict(self.manifest, ready_for_scored_performance_comparison=True)
        with self.assertRaisesRegex(ValueError, 'not a scored'):
            check_fixture(self.raw, wrong)

    def test_modified_manifest_digest_rejected(self) -> None:
        wrong = dict(self.manifest, scene_sha256='0'*64)
        with self.assertRaisesRegex(ValueError, 'declared source digest'):
            check_fixture(self.raw, wrong)

    def test_geometry_row_change_rejected(self) -> None:
        wrong = dict(self.manifest, expected_pre_edit_geometry=[dict(x) for x in self.manifest['expected_pre_edit_geometry']])
        wrong['expected_pre_edit_geometry'][0]['x'] += 1
        with self.assertRaisesRegex(ValueError, 'manifest geometry'):
            check_fixture(self.raw, wrong)


class PrelaunchInputTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        for name in ('scene.drawio', 'source-manifest.json'):
            shutil.copyfile(HERE / name, self.directory / name)
        self.override = patch.dict(globals(), {'HERE': self.directory})
        self.override.start()
        self.addCleanup(self.override.stop)
        self.attempt_id = 'bdac769b-a4cd-4ef9-b5c6-cd9f6157019f'

    def test_exact_pinned_bytes_attest_source_but_not_app_work(self) -> None:
        receipt = attest_before_launch('baseline', self.attempt_id)
        self.assertEqual(receipt['source_sha256'], EXPECTED_SHA256)
        self.assertEqual(receipt['source_bytes'], EXPECTED_BYTES)
        self.assertEqual(receipt['status'], 'source_bytes_verified_only')
        self.assertLessEqual(
            receipt['read_started_monotonic_ns'], receipt['read_finished_monotonic_ns'],
        )
        self.assertFalse(receipt['app_loaded_source_verified'])
        self.assertFalse(receipt['performance_admitted'])
        json.dumps(receipt, allow_nan=False)

    def test_mutated_source_fails_before_attestation(self) -> None:
        path = self.directory / 'scene.drawio'
        path.write_bytes(path.read_bytes()[:-1] + b'X')
        with self.assertRaisesRegex(ValueError, 'source bytes differ'):
            attest_before_launch('candidate', self.attempt_id)

    def test_symlinked_source_is_rejected(self) -> None:
        path = self.directory / 'scene.drawio'
        backing = self.directory / 'old.drawio'
        path.rename(backing)
        path.symlink_to(backing)
        with self.assertRaisesRegex(ValueError, 'not a regular'):
            attest_before_launch('baseline', self.attempt_id)

    def test_non_regular_source_is_rejected_without_blocking(self) -> None:
        path = self.directory / 'scene.drawio'
        path.unlink()
        os.mkfifo(path)
        with self.assertRaisesRegex(ValueError, 'not a regular'):
            attest_before_launch('baseline', self.attempt_id)

    def test_changed_manifest_fails_before_attestation(self) -> None:
        path = self.directory / 'source-manifest.json'
        altered = json.loads(path.read_text())
        altered['historical_prelaunch_input_verified'] = True
        path.write_text(json.dumps(altered))
        with self.assertRaisesRegex(ValueError, 'historical prelaunch'):
            attest_before_launch('baseline', self.attempt_id)

    def test_symlinked_manifest_is_rejected(self) -> None:
        path = self.directory / 'source-manifest.json'
        backing = self.directory / 'old-manifest.json'
        path.rename(backing)
        path.symlink_to(backing)
        with self.assertRaisesRegex(ValueError, 'not a regular'):
            attest_before_launch('candidate', self.attempt_id)

    def test_oversized_manifest_is_rejected(self) -> None:
        (self.directory / 'source-manifest.json').write_bytes(b' ' * 65537)
        with self.assertRaisesRegex(ValueError, 'larger than allowed'):
            attest_before_launch('baseline', self.attempt_id)

    def test_source_inode_swap_during_read_is_rejected(self) -> None:
        real_read = os.read
        path = self.directory / 'scene.drawio'
        swapped = self.directory / 'replacement.drawio'
        def swap_before_read(fd: int, count: int) -> bytes:
            path.rename(swapped)
            shutil.copyfile(swapped, path)
            return real_read(fd, count)
        with patch.object(os, 'read', side_effect=swap_before_read):
            with self.assertRaisesRegex(ValueError, 'file changed during prelaunch read'):
                attest_before_launch('baseline', self.attempt_id)

    def test_missing_source_and_bad_attempt_refused(self) -> None:
        with self.assertRaisesRegex(ValueError, 'canonical UUID'):
            attest_before_launch('baseline', 'attempt-1')
        (self.directory / 'scene.drawio').unlink()
        with self.assertRaises(FileNotFoundError):
            attest_before_launch('baseline', self.attempt_id)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--attest-before-launch':
        parser = argparse.ArgumentParser(
            description='Read-only fixture-source proof for one future native launch',
        )
        parser.add_argument('--attest-before-launch', action='store_true')
        parser.add_argument('--arm', required=True, choices=('baseline', 'candidate', 'electron'))
        parser.add_argument('--attempt-id', required=True)
        arguments = parser.parse_args()
        try:
            receipt = attest_before_launch(arguments.arm, arguments.attempt_id)
        except (OSError, ValueError, json.JSONDecodeError) as error:
            print(f'prelaunch source NOT VERIFIED: {error}', file=sys.stderr)
            raise SystemExit(2) from error
        print(json.dumps(receipt, sort_keys=True, allow_nan=False))
    else:
        unittest.main()
