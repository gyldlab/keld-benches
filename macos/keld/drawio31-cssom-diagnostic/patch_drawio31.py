#!/usr/bin/env python3
"""Create an unscored, byte-pinned draw.io 31.7.0 CSSOM compatibility artifact."""
import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path

OLD_MIN = b'mxSvgCanvas2D.prototype.setCssText=function(a,b){null!=a&&"function"===typeof a.setAttribute&&a.setAttribute("style",b)}'
NEW_MIN = b'mxSvgCanvas2D.prototype.setCssText=function(a,b){null!=a&&"function"===typeof a.setAttribute&&(null!=a.style?a.style.cssText=b:a.setAttribute("style",b))}'
OLD_SRC = b"\t\telt.setAttribute('style', css);"
NEW_SRC = b"\t\tif (elt.style != null)\n\t\t{\n\t\t\telt.style.cssText = css;\n\t\t}\n\t\telse\n\t\t{\n\t\t\telt.setAttribute('style', css);\n\t\t}"
ORIGINAL = {'bundle': '53a391f90dd2d48d74de5e25b6991cdf47f9ed723f241db906c239b41e0c0c44',
            'readable': '0daef9812e3b8c530bc9556791ffaea53fe9a57091a86534bd909ca31e4485b3',
            'policy': '4cb350e624ad3093db06fd4a63c72047b0b2b1eda232b5c0b4a8745744500bf9'}
PATCHED_MIN_SHA = '744455ebd2c9f63db3fb9443201577f6465d99507cdcf8f61fe1a34222f5c13d'

def digest(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()

def load(path: Path, expected: str) -> bytes:
    if not path.is_file() or path.is_symlink():
        raise ValueError(f'Invalid or symlinked pinned input: {path}')
    content = path.read_bytes()
    if digest(content) != expected:
        raise ValueError(f'Pinned input SHA-256 mismatch: {path}')
    return content

def replace_one(payload: bytes, before: bytes, after: bytes) -> bytes:
    if payload.count(before) != 1 or payload.count(after) != 0:
        raise ValueError('Expected one original function and no patched copy')
    return payload.replace(before, after)

def write_once(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY | getattr(os, 'O_NOFOLLOW', 0)
    fd = os.open(path, flags, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(payload)

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--webroot', required=True, type=Path, help='Unmodified pinned draw.io 31.7.0 webapp directory')
    parser.add_argument('--policy', required=True, type=Path, help='Unmodified keld.permissions.jsonc')
    parser.add_argument('--output', required=True, type=Path, help='New, nonexistent artifact directory')
    opts = parser.parse_args()
    webroot = opts.webroot.resolve()
    original_min = load(webroot / 'js/app.min.js', ORIGINAL['bundle'])
    original_src = load(webroot / 'mxgraph/src/util/mxSvgCanvas2D.js', ORIGINAL['readable'])
    load(opts.policy, ORIGINAL['policy'])
    new_min = replace_one(original_min, OLD_MIN, NEW_MIN)
    new_src = replace_one(original_src, OLD_SRC, NEW_SRC)
    if digest(new_min) != PATCHED_MIN_SHA:
        raise ValueError('Unexpected patched bundle digest')
    # No modification of original app, Host, runtime, policy or resource grants.
    opts.output.mkdir(mode=0o700, parents=False, exist_ok=False)
    write_once(opts.output / 'js/app.min.js', new_min)
    write_once(opts.output / 'mxgraph/src/util/mxSvgCanvas2D.js', new_src)
    patch = ''.join(difflib.unified_diff(original_src.decode().splitlines(True), new_src.decode().splitlines(True),
              fromfile='a/mxgraph/src/util/mxSvgCanvas2D.js', tofile='b/mxgraph/src/util/mxSvgCanvas2D.js'))
    write_once(opts.output / 'readable-source.patch', patch.encode())
    record = {'schema': 'drawio31-cssom-candidate-v1', 'publication_eligible': False,
              'source_bundle_sha256': ORIGINAL['bundle'], 'patched_bundle_sha256': digest(new_min),
              'source_readable_sha256': ORIGINAL['readable'], 'patched_readable_sha256': digest(new_src),
              'unchanged_policy_sha256': ORIGINAL['policy'], 'bundle_function_replacements': 1,
              'source_function_replacements': 1}
    write_once(opts.output / 'receipt.json', (json.dumps(record, indent=2, sort_keys=True)+'\n').encode())
    print(json.dumps(record, sort_keys=True))

if __name__ == '__main__':
    main()
