#!/usr/bin/env python3
"""Recover the HTML a built Tauri binary will actually render, from the binary.

WHY THIS EXISTS
---------------
On 2026-08-24 two committed paired documents cited a Tauri artifact that did
NOT embed the Tauri fixture page: it embedded a paint-beacon-instrumented page
left over from an earlier session, which fired an image request at a dead port
on every launch. Nothing caught it, because nothing verified what a measured
artifact RENDERS -- only that it built and showed a window.

A build succeeding says nothing about what it embedded. Tauri embeds
frontendDist into the executable at build time (proven: swapping the on-disk
page without rebuilding changes nothing, and deleting the whole src/ directory
still runs), so the only trustworthy source for "what will this exe render" is
the exe itself.

METHOD
------
tauri-codegen writes each embedded asset as a brotli blob under
target/<profile>/build/<crate>-<hash>/out/tauri-codegen-assets/. Those exact
bytes are copied into the executable. So: for every cached blob, test whether
its bytes occur inside the exe. Exactly one HTML blob should match; that is the
page this binary serves.

FAIL CLOSED. Zero matches, or more than one distinct HTML payload, is an error
and not a guess -- an unverifiable payload claim is the thing this script
exists to prevent.

Usage:
  extract_tauri_payload.py <exe> [--expect-sha256 HEX] [--write-html PATH]

Prints the sha256 of the decompressed HTML. Exit 0 on success (and on match
when --expect-sha256 is given), 2 on any verification failure, 3 on setup error.
"""
import argparse
import glob
import hashlib
import os
import sys

try:
    import brotli
except ImportError:
    print("FATAL: python module 'brotli' is required", file=sys.stderr)
    sys.exit(3)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("exe")
    ap.add_argument("--expect-sha256")
    ap.add_argument("--write-html")
    args = ap.parse_args()

    if not os.path.isfile(args.exe):
        print(f"FATAL: no such executable: {args.exe}", file=sys.stderr)
        return 3

    exe = open(args.exe, "rb").read()
    exe_sha = hashlib.sha256(exe).hexdigest()

    # target/<profile>/<exe> -> target/<profile>/build/*/out/tauri-codegen-assets/*
    profile_dir = os.path.dirname(os.path.abspath(args.exe))
    pattern = os.path.join(profile_dir, "build", "*", "out", "tauri-codegen-assets", "*")
    blobs = glob.glob(pattern)
    if not blobs:
        print(f"FATAL: no tauri-codegen-assets found under {profile_dir}", file=sys.stderr)
        print("       the build tree is required to recover embedded assets", file=sys.stderr)
        return 3

    found = {}
    for path in blobs:
        raw = open(path, "rb").read()
        if not raw or exe.find(raw) == -1:
            continue
        try:
            html = brotli.decompress(raw)
        except Exception:
            continue
        if b"<html" not in html.lower():
            continue
        found[hashlib.sha256(html).hexdigest()] = (html, os.path.basename(path), exe.find(raw))

    print(f"artifact        : {args.exe}")
    print(f"artifact sha256 : {exe_sha}")

    if not found:
        print("VERIFICATION FAILED: no embedded HTML asset from the build cache "
              "byte-matches this executable.", file=sys.stderr)
        return 2
    if len(found) > 1:
        print(f"VERIFICATION FAILED: {len(found)} distinct HTML payloads are embedded; "
              "cannot say which is rendered.", file=sys.stderr)
        for sha, (html, name, off) in found.items():
            print(f"  {sha}  {len(html)} B  {name[:24]} @ {off}", file=sys.stderr)
        return 2

    payload_sha, (html, name, off) = next(iter(found.items()))
    beacon = b"requestAnimationFrame" in html
    print(f"embedded asset  : {name[:32]} at offset {off}")
    print(f"payload bytes   : {len(html)}")
    print(f"payload sha256  : {payload_sha}")
    print(f"contains beacon : {beacon}")

    if args.write_html:
        open(args.write_html, "wb").write(html)
        print(f"wrote           : {args.write_html}")

    if args.expect_sha256:
        if payload_sha.lower() == args.expect_sha256.lower():
            print("MATCH: embedded payload equals the expected canonical page")
            return 0
        print(f"VERIFICATION FAILED: embedded payload {payload_sha} "
              f"!= expected {args.expect_sha256}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
