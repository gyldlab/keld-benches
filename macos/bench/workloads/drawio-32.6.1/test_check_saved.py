#!/usr/bin/env python3
"""Deterministic valid-path and mutation controls; no application launch."""

from __future__ import annotations

import base64
import copy
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import quote
import xml.etree.ElementTree as ET
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_saved import OracleError, verify  # noqa: E402

HERE = Path(__file__).resolve().parent


class SavedDrawioOracleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ("input.drawio", "expected.drawio", "manifest.json"):
            shutil.copyfile(HERE / name, self.root / name)
        self.manifest = self.root / "manifest.json"
        self.saved = self.root / "saved.drawio"
        self.saved.write_bytes((self.root / "expected.drawio").read_bytes())

    def _edit(self, src: Path, old: bytes, new: bytes) -> None:
        raw = src.read_bytes()
        self.assertIn(old, raw)
        src.write_bytes(raw.replace(old, new, 1))

    def _reject(self, reason: str) -> None:
        with self.assertRaises(OracleError) as caught:
            verify(self.manifest, self.saved)
        self.assertEqual(str(caught.exception), reason)

    def _manifest_data(self) -> dict:
        return json.loads(self.manifest.read_text())

    def _rewrite_manifest(self, data: dict) -> None:
        self.manifest.write_text(json.dumps(data, indent=2) + "\n")

    def test_uncompressed_valid_path(self) -> None:
        result = verify(self.manifest, self.saved)
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(result["page_count"], 1)
        self.assertEqual(result["cell_count"], 5)
        self.assertIn("performance", result["not_proved"])

    def test_compressed_drawio_valid_path(self) -> None:
        doc = ET.fromstring(self.saved.read_bytes())
        diagram = doc.find("diagram")
        self.assertIsNotNone(diagram)
        model = diagram[0]
        diagram.remove(model)
        compressed = zlib.compressobj(level=9, wbits=-zlib.MAX_WBITS)
        encoded = quote(ET.tostring(model, encoding="unicode"), safe="")
        diagram.text = base64.b64encode(compressed.compress(encoded.encode("ascii")) + compressed.flush()).decode("ascii")
        doc.set("host", "KELD-output")  # Non-scoring file metadata may differ.
        self.saved.write_bytes(ET.tostring(doc, encoding="utf-8", xml_declaration=True))
        self.assertEqual(verify(self.manifest, self.saved)["status"], "PASS")

    def test_metadata_and_editor_scroll_do_not_change_graph(self) -> None:
        doc = ET.fromstring(self.saved.read_bytes())
        doc.set("modified", "2026-11-04T00:00:00Z")
        doc.set("agent", "test")
        model = doc.find("diagram/mxGraphModel")
        model.set("dx", "800")
        model.set("dy", "300")
        self.saved.write_bytes(ET.tostring(doc, encoding="utf-8"))
        self.assertEqual(verify(self.manifest, self.saved)["status"], "PASS")

    def test_unedited_save_rejected(self) -> None:
        self.saved.write_bytes((self.root / "input.drawio").read_bytes())
        self._reject("SAVED_GRAPH_MISMATCH")

    def test_wrong_label_rejected(self) -> None:
        self._edit(self.saved, b'Beta (edited)', b'Wrong edit')
        self._reject("SAVED_GRAPH_MISMATCH")

    def test_wrong_geometry_rejected(self) -> None:
        self._edit(self.saved, b'x="340"', b'x="341"')
        self._reject("SAVED_GRAPH_MISMATCH")

    def test_wrong_page_rejected(self) -> None:
        self._edit(self.saved, b'name="Page-1"', b'name="Other page"')
        self._reject("SAVED_GRAPH_MISMATCH")

    def test_reordered_cells_rejected_for_z_order(self) -> None:
        doc = ET.fromstring(self.saved.read_bytes())
        root = doc.find("diagram/mxGraphModel/root")
        root[2], root[3] = root[3], root[2]
        self.saved.write_bytes(ET.tostring(doc, encoding="utf-8"))
        self._reject("SAVED_GRAPH_MISMATCH")

    def test_missing_cell_rejected(self) -> None:
        doc = ET.fromstring(self.saved.read_bytes())
        root = doc.find("diagram/mxGraphModel/root")
        root.remove(root[-1])
        self.saved.write_bytes(ET.tostring(doc, encoding="utf-8"))
        self._reject("SAVED_GRAPH_MISMATCH")

    def test_duplicate_cell_identity_rejected(self) -> None:
        doc = ET.fromstring(self.saved.read_bytes())
        root = doc.find("diagram/mxGraphModel/root")
        root.append(copy.deepcopy(root[-1]))
        self.saved.write_bytes(ET.tostring(doc, encoding="utf-8"))
        self._reject("DUPLICATE_CELL")

    def test_foreign_reference_rejected(self) -> None:
        self._edit(self.saved, b'target="node-b"', b'target="missing"')
        self._reject("BROKEN_REFERENCE")

    def test_unsupported_wrapper_rejected(self) -> None:
        self._edit(self.saved, b'<mxCell id="node-b"', b'<UserObject id="node-b"')
        self._reject("INVALID_XML")  # Mismatched close is not silently repaired.

    def test_external_entity_rejected(self) -> None:
        self.saved.write_bytes(b'<!DOCTYPE mxfile [<!ENTITY leak SYSTEM "file:///etc/passwd">]>\n'
                               + self.saved.read_bytes())
        self._reject("XML_DTD_FORBIDDEN")

    def test_malformed_or_trailing_compression_rejected(self) -> None:
        self.saved.write_bytes(b'<mxfile><diagram id="main" name="Page-1">bogus%%</diagram></mxfile>')
        self._reject("INVALID_COMPRESSION")

    def test_compression_bomb_rejected(self) -> None:
        source = b'A' * (16 * 1024 * 1024 + 1)
        compressor = zlib.compressobj(level=9, wbits=-zlib.MAX_WBITS)
        payload = base64.b64encode(compressor.compress(source) + compressor.flush())
        self.saved.write_bytes(b'<mxfile><diagram id="main" name="Page-1">' + payload + b'</diagram></mxfile>')
        self._reject("INVALID_COMPRESSION")

    def test_well_formed_unsupported_wrapper_rejected(self) -> None:
        doc = ET.fromstring(self.saved.read_bytes())
        root = doc.find("diagram/mxGraphModel/root")
        cell = root[3]
        cell.tag = "UserObject"
        self.saved.write_bytes(ET.tostring(doc, encoding="utf-8"))
        self._reject("UNSUPPORTED_CELL")

    def test_significant_page_tail_rejected(self) -> None:
        doc = ET.fromstring(self.saved.read_bytes())
        doc.find("diagram").tail = "unexpected extra text"
        self.saved.write_bytes(ET.tostring(doc, encoding="utf-8"))
        self._reject("UNSUPPORTED_DOCUMENT")

    def test_significant_model_tail_rejected(self) -> None:
        doc = ET.fromstring(self.saved.read_bytes())
        doc.find("diagram/mxGraphModel").tail = "unexpected extra text"
        self.saved.write_bytes(ET.tostring(doc, encoding="utf-8"))
        self._reject("UNSUPPORTED_DIAGRAM")

    def test_significant_graph_root_text_rejected(self) -> None:
        doc = ET.fromstring(self.saved.read_bytes())
        doc.find("diagram/mxGraphModel/root").text = "unexpected extra text"
        self.saved.write_bytes(ET.tostring(doc, encoding="utf-8"))
        self._reject("UNSUPPORTED_GRAPH")

    def test_modified_input_hash_rejected(self) -> None:
        self._edit(self.root / "input.drawio", b'Alpha', b'Tampered')
        self._reject("INPUT_HASH_MISMATCH")

    def test_modified_reference_hash_rejected(self) -> None:
        self._edit(self.root / "expected.drawio", b'Alpha', b'Tampered')
        self._reject("EXPECTED_HASH_MISMATCH")

    def test_edit_contract_rejects_a_rehashed_wrong_reference(self) -> None:
        self._edit(self.root / "expected.drawio", b'Alpha', b'Tampered')
        manifest = self._manifest_data()
        manifest["expected_sha256"] = hashlib.sha256((self.root / "expected.drawio").read_bytes()).hexdigest()
        self._rewrite_manifest(manifest)
        self._reject("EXPECTED_EDIT_MISMATCH")

    def test_manifest_path_traversal_rejected(self) -> None:
        manifest = self._manifest_data()
        manifest["input"] = "../input.drawio"
        self._rewrite_manifest(manifest)
        self._reject("INVALID_MANIFEST")

    def test_manifest_duplicate_keys_rejected(self) -> None:
        self.manifest.write_text('{"format":"drawio-file-oracle-v1","format":"drawio-file-oracle-v1"}')
        self._reject("DUPLICATE_MANIFEST_KEY")

    def test_unavailable_output_rejected(self) -> None:
        self.saved.unlink()
        self._reject("FILE_UNAVAILABLE")

    def test_cli_exit_codes_and_non_scoring_receipt(self) -> None:
        cmd = [sys.executable, str(HERE / "check_saved.py"), "--manifest", str(self.manifest),
               "--saved", str(self.saved)]
        ok = subprocess.run(cmd, capture_output=True, text=True, check=False)
        self.assertEqual(ok.returncode, 0, ok.stderr)
        self.assertEqual(json.loads(ok.stdout)["scope"], "saved-file-graph-only")
        self._edit(self.saved, b'Beta (edited)', b'Not same')
        bad = subprocess.run(cmd, capture_output=True, text=True, check=False)
        self.assertEqual(bad.returncode, 2, bad.stderr)
        self.assertEqual(json.loads(bad.stdout)["reason"], "SAVED_GRAPH_MISMATCH")


if __name__ == "__main__":
    unittest.main()
