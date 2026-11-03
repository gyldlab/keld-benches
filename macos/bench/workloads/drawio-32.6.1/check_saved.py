#!/usr/bin/env python3
"""Fail-closed, unscored file-state oracle for a synthetic draw.io workload."""

from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import json
from pathlib import Path
import re
import sys
from urllib.parse import unquote_to_bytes
import xml.etree.ElementTree as ET
import zlib

HERE = Path(__file__).resolve().parent
MAX_FILE_BYTES = 4 * 1024 * 1024
MAX_EXPANDED_BYTES = 16 * 1024 * 1024
MAX_PAGES = 16
MAX_CELLS = 10_000
_SHA256 = re.compile(r"[0-9a-f]{64}\Z")
_FORBIDDEN_XML = re.compile(rb"<!\s*(?:DOCTYPE|ENTITY)\b", re.IGNORECASE)


class OracleError(Exception):
    """A named, non-sensitive reason not to admit the saved-file evidence."""


def _read(path: Path, limit: int = MAX_FILE_BYTES) -> bytes:
    try:
        with path.open("rb") as stream:
            data = stream.read(limit + 1)
    except OSError as exc:
        raise OracleError("FILE_UNAVAILABLE") from exc
    if len(data) > limit:
        raise OracleError("FILE_TOO_LARGE")
    return data


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _xml(data: bytes) -> ET.Element:
    if _FORBIDDEN_XML.search(data):
        raise OracleError("XML_DTD_FORBIDDEN")
    try:
        return ET.fromstring(data)
    except (ET.ParseError, UnicodeError, ValueError) as exc:
        raise OracleError("INVALID_XML") from exc


def _decode_diagram(diagram: ET.Element) -> ET.Element:
    children = list(diagram)
    if len(children) == 1 and children[0].tag == "mxGraphModel":
        if (diagram.text and diagram.text.strip()) or (children[0].tail and children[0].tail.strip()):
            raise OracleError("UNSUPPORTED_DIAGRAM")
        return children[0]
    if children or not diagram.text or not diagram.text.strip():
        raise OracleError("UNSUPPORTED_DIAGRAM")
    try:
        compressed = base64.b64decode(diagram.text.strip(), validate=True)
        inflater = zlib.decompressobj(-zlib.MAX_WBITS)  # draw.io raw DEFLATE
        expanded = inflater.decompress(compressed, MAX_EXPANDED_BYTES + 1)
        if (
            len(expanded) > MAX_EXPANDED_BYTES
            or not inflater.eof
            or inflater.unconsumed_tail
            or inflater.unused_data
        ):
            raise OracleError("INVALID_COMPRESSION")
        model_bytes = unquote_to_bytes(expanded.decode("ascii"))
    except (ValueError, UnicodeError, zlib.error) as exc:
        raise OracleError("INVALID_COMPRESSION") from exc
    model = _xml(model_bytes)
    if model.tag != "mxGraphModel":
        raise OracleError("UNSUPPORTED_DIAGRAM")
    return model


def _canonical(node: ET.Element) -> dict:
    # Keep ordered children: changing cell order can change visual z-order.
    if node.tail and node.tail.strip():
        raise OracleError("UNSUPPORTED_CONTENT")
    return {
        "tag": node.tag,
        "attrs": dict(sorted(node.attrib.items())),
        "text": node.text if node.text and node.text.strip() else "",
        "children": [_canonical(child) for child in node],
    }


def _snapshot(data: bytes) -> dict:
    root = _xml(data)
    if root.tag != "mxfile" or not (1 <= len(root) <= MAX_PAGES):
        raise OracleError("UNSUPPORTED_DOCUMENT")
    if root.text and root.text.strip():
        raise OracleError("UNSUPPORTED_DOCUMENT")
    pages = []
    page_ids: set[str] = set()
    for diagram in root:
        if diagram.tail and diagram.tail.strip():
            raise OracleError("UNSUPPORTED_DOCUMENT")
        if diagram.tag != "diagram" or not diagram.get("id") or not diagram.get("name"):
            raise OracleError("UNSUPPORTED_DOCUMENT")
        page_id = diagram.attrib["id"]
        if page_id in page_ids:
            raise OracleError("DUPLICATE_PAGE")
        page_ids.add(page_id)
        model = _decode_diagram(diagram)
        if (len(model) != 1 or model[0].tag != "root"
                or (model.text and model.text.strip())
                or (model[0].tail and model[0].tail.strip())
                or (model[0].text and model[0].text.strip())):
            raise OracleError("UNSUPPORTED_GRAPH")
        cells = list(model[0])
        if not (3 <= len(cells) <= MAX_CELLS):
            raise OracleError("UNSUPPORTED_GRAPH")
        ids: set[str] = set()
        for cell in cells:
            cell_id = cell.get("id")
            if cell.tag != "mxCell" or not cell_id:
                # Objects/UserObjects and other advanced draw.io constructs need
                # their own independently reviewed canonicalization contract.
                raise OracleError("UNSUPPORTED_CELL")
            if cell_id in ids:
                raise OracleError("DUPLICATE_CELL")
            ids.add(cell_id)
        if not {"0", "1"}.issubset(ids):
            raise OracleError("MISSING_ROOT_CELL")
        for cell in cells:
            for attr in ("parent", "source", "target"):
                ref = cell.get(attr)
                if ref is not None and ref not in ids:
                    raise OracleError("BROKEN_REFERENCE")
        page = {
            "id": page_id,
            "name": diagram.attrib["name"],
            # dx/dy describe editor viewport displacement, not diagram state.
            "model_attrs": {k: v for k, v in sorted(model.attrib.items()) if k not in {"dx", "dy"}},
            "cells": [_canonical(cell) for cell in cells],
        }
        pages.append(page)
    return {"pages": pages}


def _manifest(path: Path) -> dict:
    def unique(pairs: list[tuple[str, object]]) -> dict:
        result = {}
        for key, value in pairs:
            if key in result:
                raise OracleError("DUPLICATE_MANIFEST_KEY")
            result[key] = value
        return result

    try:
        manifest = json.loads(_read(path).decode("utf-8"), object_pairs_hook=unique)
    except (UnicodeError, ValueError, TypeError) as exc:
        raise OracleError("INVALID_MANIFEST") from exc
    if not isinstance(manifest, dict) or manifest.get("format") != "drawio-file-oracle-v1":
        raise OracleError("INVALID_MANIFEST")
    for field in ("input", "expected"):
        name = manifest.get(field)
        digest = manifest.get(f"{field}_sha256")
        if (not isinstance(name, str) or name in {"", ".", ".."}
                or Path(name).name != name or "\\" in name
                or not isinstance(digest, str) or not _SHA256.fullmatch(digest)):
            raise OracleError("INVALID_MANIFEST")
    edit = manifest.get("required_edit")
    if (not isinstance(edit, dict)
            or set(edit) != {"page_id", "cell_id", "before", "after"}
            or any(not isinstance(v, str) for v in edit.values())
            or not edit["page_id"] or not edit["cell_id"]
            or edit["before"] == edit["after"]):
        raise OracleError("INVALID_MANIFEST")
    return manifest


def _edit_expected(source: dict, edit: dict) -> dict:
    result = copy.deepcopy(source)
    matches = [c for page in result["pages"] if page["id"] == edit["page_id"]
               for c in page["cells"] if c["attrs"].get("id") == edit["cell_id"]]
    if len(matches) != 1 or matches[0]["attrs"].get("value") != edit["before"]:
        raise OracleError("INVALID_REQUIRED_EDIT")
    matches[0]["attrs"]["value"] = edit["after"]
    return result


def verify(manifest_path: Path, saved_path: Path) -> dict:
    manifest = _manifest(manifest_path)
    source = _read(manifest_path.parent / manifest["input"])
    expected = _read(manifest_path.parent / manifest["expected"])
    saved = _read(saved_path)
    if _sha(source) != manifest["input_sha256"]:
        raise OracleError("INPUT_HASH_MISMATCH")
    if _sha(expected) != manifest["expected_sha256"]:
        raise OracleError("EXPECTED_HASH_MISMATCH")
    original = _snapshot(source)
    reference = _snapshot(expected)
    if _edit_expected(original, manifest["required_edit"]) != reference:
        raise OracleError("EXPECTED_EDIT_MISMATCH")
    candidate = _snapshot(saved)
    if candidate != reference:
        raise OracleError("SAVED_GRAPH_MISMATCH")
    semantic = json.dumps(candidate, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return {
        "status": "PASS",
        "oracle": "drawio-file-oracle-v1",
        "scope": "saved-file-graph-only",
        "input_sha256": _sha(source),
        "expected_sha256": _sha(expected),
        "saved_sha256": _sha(saved),
        "graph_sha256": _sha(semantic),
        "page_count": len(candidate["pages"]),
        "cell_count": sum(len(page["cells"]) for page in candidate["pages"]),
        "not_proved": ["GUI_open_edit_save_reopen", "cancel_discard_quit", "process_census", "performance"],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--saved", type=Path, required=True, help="Exported .drawio file from an observed app run")
    parser.add_argument("--manifest", type=Path, default=HERE / "manifest.json")
    args = parser.parse_args(argv)
    try:
        report = verify(args.manifest, args.saved)
    except OracleError as exc:
        report = {"status": "INVALID", "oracle": "drawio-file-oracle-v1", "reason": str(exc)}
        print(json.dumps(report, sort_keys=True))
        return 2
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
