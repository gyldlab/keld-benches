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
from unittest import mock
from urllib.parse import quote
import xml.etree.ElementTree as ET
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_saved as oracle  # noqa: E402
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

    def _compressed_document(self, encoded: bytes) -> bytes:
        compressor = zlib.compressobj(wbits=-zlib.MAX_WBITS)
        payload = base64.b64encode(compressor.compress(encoded) + compressor.flush())
        return b'<mxfile><diagram id="main" name="Page-1">' + payload + b'</diagram></mxfile>'

    def test_compressed_uri_malformed_escape_rejected(self) -> None:
        model = ET.fromstring(self.saved.read_bytes()).find("diagram/mxGraphModel")
        encoded = quote(ET.tostring(model, encoding="unicode"), safe="").encode("ascii")
        for malformed in (b'%ZZ', b'%', b'%2'):
            with self.subTest(malformed=malformed):
                candidate = encoded.replace(b'dx%3D%221080%22', b'dx%3D%22' + malformed + b'%22')
                self.assertNotEqual(candidate, encoded)
                self.saved.write_bytes(self._compressed_document(candidate))
                self._reject("INVALID_COMPRESSION")

    def test_compressed_uri_invalid_utf8_rejected(self) -> None:
        model = ET.fromstring(self.saved.read_bytes()).find("diagram/mxGraphModel")
        encoded = quote(ET.tostring(model, encoding="unicode"), safe="").encode("ascii")
        candidate = encoded.replace(b'dx%3D%221080%22', b'dx%3D%22%FF%22')
        self.saved.write_bytes(self._compressed_document(candidate))
        self._reject("INVALID_COMPRESSION")

    def test_compressed_unicode_and_literal_percent_valid_path(self) -> None:
        doc = ET.fromstring(self.saved.read_bytes())
        model = doc.find("diagram/mxGraphModel")
        model.find("root/mxCell[@id='node-a']").set("value", "50% café λ")
        encoded = quote(ET.tostring(model, encoding="unicode"), safe="").encode("ascii")
        self.assertEqual(oracle._snapshot(self._compressed_document(encoded)),
                         oracle._snapshot(ET.tostring(doc, encoding="utf-8")))

    def test_compressed_xml_dtd_rejected(self) -> None:
        model = ET.fromstring(self.saved.read_bytes()).find("diagram/mxGraphModel")
        xml = '<!DOCTYPE mxGraphModel>' + ET.tostring(model, encoding="unicode")
        self.saved.write_bytes(self._compressed_document(quote(xml, safe="").encode("ascii")))
        self._reject("XML_DTD_FORBIDDEN")

    def test_representation_hints_do_not_change_graph(self) -> None:
        doc = ET.fromstring(self.saved.read_bytes())
        # The native reader selects the actual page content and diagram nodes,
        # not these editor/representation hints.
        doc.set("compressed", "false")
        doc.set("pages", "1")
        self.saved.write_bytes(ET.tostring(doc, encoding="utf-8"))
        self.assertEqual(verify(self.manifest, self.saved)["status"], "PASS")
        model = doc.find("diagram/mxGraphModel")
        encoded = quote(ET.tostring(model, encoding="unicode"), safe="").encode("ascii")
        self.saved.write_bytes(self._compressed_document(encoded).replace(
            b'<mxfile>', b'<mxfile compressed="true" pages="1">'))
        self.assertEqual(verify(self.manifest, self.saved)["status"], "PASS")

    def test_compressed_pages_share_expansion_budget(self) -> None:
        model = ET.fromstring(self.saved.read_bytes()).find("diagram/mxGraphModel")
        encoded = quote(ET.tostring(model, encoding="unicode"), safe="").encode("ascii")
        single = self._compressed_document(encoded)
        with mock.patch.object(oracle, "MAX_EXPANDED_BYTES", len(encoded)):
            self.assertEqual(len(oracle._snapshot(single)["pages"]), 1)
            doc = ET.fromstring(single)
            second = copy.deepcopy(doc[0])
            second.set("id", "other")
            doc.append(second)
            with self.assertRaisesRegex(OracleError, "^INVALID_COMPRESSION$"):
                oracle._snapshot(ET.tostring(doc))

    def test_metadata_and_editor_scroll_do_not_change_graph(self) -> None:
        doc = ET.fromstring(self.saved.read_bytes())
        doc.set("modified", "2026-11-04T00:00:00Z")
        doc.set("agent", "test")
        doc.set("userAgent", "old-editor-metadata")
        doc.set("editor", "old-editor-metadata")
        model = doc.find("diagram/mxGraphModel")
        model.set("dx", "800")
        model.set("dy", "300")
        self.saved.write_bytes(ET.tostring(doc, encoding="utf-8"))
        self.assertEqual(verify(self.manifest, self.saved)["status"], "PASS")

    def test_utf16_without_dtd_valid_path(self) -> None:
        doc = ET.fromstring(self.saved.read_bytes())
        self.saved.write_bytes(ET.tostring(doc, encoding="utf-16", xml_declaration=True))
        self.assertEqual(verify(self.manifest, self.saved)["status"], "PASS")

    def test_dtd_rejected_independently_of_byte_encoding(self) -> None:
        body = self.saved.read_text(encoding="utf-8").split("?>", 1)[1]
        for encoding in ("utf-8", "utf-16", "utf-16-le", "utf-16-be"):
            with self.subTest(encoding=encoding):
                declaration = "UTF-8" if encoding == "utf-8" else "UTF-16"
                candidate = (
                    f'<?xml version="1.0" encoding="{declaration}"?>'
                    '<!DOCTYPE mxfile [<!ENTITY label "Beta (edited)">]>'
                    + body.replace("Beta (edited)", "&label;")
                )
                self.saved.write_bytes(candidate.encode(encoding))
                self._reject("XML_DTD_FORBIDDEN")

    def test_deep_xml_rejected_before_recursive_snapshot(self) -> None:
        self._edit(self.saved, b'<mxCell id="0"/>',
                   b'<mxCell id="0">' + b'<a>' * 1200 + b'</a>' * 1200 + b'</mxCell>')
        self._reject("XML_COMPLEXITY_LIMIT")

    def test_xml_depth_boundary(self) -> None:
        with mock.patch.object(oracle, "MAX_XML_DEPTH", 8):
            self.assertEqual(oracle._xml(b'<a>' * 8 + b'</a>' * 8).tag, "a")
            with self.assertRaisesRegex(OracleError, "^XML_COMPLEXITY_LIMIT$"):
                oracle._xml(b'<a>' * 9 + b'</a>' * 9)

    def test_xml_node_boundary(self) -> None:
        with mock.patch.object(oracle, "MAX_XML_NODES", 32):
            self.assertEqual(len(oracle._xml(b'<a>' + b'<b/>' * 31 + b'</a>')), 31)
            with self.assertRaisesRegex(OracleError, "^XML_COMPLEXITY_LIMIT$"):
                oracle._xml(b'<a>' + b'<b/>' * 32 + b'</a>')

    def test_compressed_pages_share_node_budget(self) -> None:
        doc = ET.fromstring(self.saved.read_bytes())
        page = doc[0]
        model = page[0]
        page.remove(model)
        compressor = zlib.compressobj(wbits=-zlib.MAX_WBITS)
        encoded = quote(ET.tostring(model, encoding="unicode"), safe="").encode("ascii")
        page.text = base64.b64encode(compressor.compress(encoded) + compressor.flush()).decode("ascii")
        with mock.patch.object(oracle, "MAX_XML_NODES", 20):
            self.assertEqual(len(oracle._snapshot(ET.tostring(doc))["pages"]), 1)
            second = copy.deepcopy(page)
            second.set("id", "other")
            doc.append(second)
            with self.assertRaisesRegex(OracleError, "^XML_COMPLEXITY_LIMIT$"):
                oracle._snapshot(ET.tostring(doc))

    def test_file_data_attributes_are_not_editor_metadata(self) -> None:
        self._edit(self.saved, b'<mxfile ',
                   b'<mxfile vars="{&quot;project&quot;:&quot;changed&quot;}" ')
        self._reject("SAVED_GRAPH_MISMATCH")

    def test_page_data_attributes_are_preserved(self) -> None:
        self._edit(self.saved, b'<diagram ', b'<diagram custom-property="changed" ')
        self._reject("SAVED_GRAPH_MISMATCH")

    def test_graph_root_attributes_are_preserved(self) -> None:
        self._edit(self.saved, b'<root>', b'<root custom-property="changed">')
        self._reject("SAVED_GRAPH_MISMATCH")

    def test_unknown_xml_encoding_is_a_named_refusal(self) -> None:
        self._edit(self.saved, b'encoding="UTF-8"', b'encoding="invalid-encoding"')
        self._reject("INVALID_XML")

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

    def test_manifest_null_byte_path_rejected(self) -> None:
        manifest = self._manifest_data()
        manifest["input"] = "input\x00.drawio"
        self._rewrite_manifest(manifest)
        self._reject("INVALID_MANIFEST")

    def test_deep_manifest_is_a_named_refusal(self) -> None:
        self.manifest.write_bytes(b'[' * 1200 + b'0' + b']' * 1200)
        self._reject("INVALID_MANIFEST")

    def test_cli_deep_xml_emits_invalid_receipt_without_traceback(self) -> None:
        self._edit(self.saved, b'<mxCell id="0"/>',
                   b'<mxCell id="0">' + b'<a>' * 1200 + b'</a>' * 1200 + b'</mxCell>')
        result = subprocess.run(
            [sys.executable, str(HERE / "check_saved.py"), "--manifest", str(self.manifest),
             "--saved", str(self.saved)], capture_output=True, text=True, check=False, timeout=5,
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(json.loads(result.stdout)["reason"], "XML_COMPLEXITY_LIMIT")
        self.assertEqual(result.stderr, "")

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
