#!/usr/bin/env python3
"""Fixture-local source provenance tests; NOT a benchmark runner or result oracle."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import unittest
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


if __name__ == '__main__':
    unittest.main()
