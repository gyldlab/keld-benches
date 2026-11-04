#!/usr/bin/env python3
"""Create an unscored, byte-pinned draw.io 31.7.0 CSSOM compatibility artifact."""
import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path, PurePosixPath

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

def open_new_output(webroot: Path, policy: Path, output: Path) -> int:
    """Create new output pinned to its parent descriptor, never inside source."""
    resolved_webroot = webroot.resolve(strict=True)
    resolved_policy = policy.resolve(strict=True)
    # Both source inputs remain protected even for a relocated renderer tree.
    protected = [resolved_webroot, resolved_policy.parent]
    if output.name in {"", ".", ".."} or output.parent.is_symlink():
        raise ValueError("Invalid or symlinked output directory parent")
    parent = output.parent.resolve(strict=True)
    destination = parent / output.name
    if any(destination.is_relative_to(root) for root in protected):
        raise ValueError("Output directory must be outside the pinned app source tree")
    flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0)
    parent_before = parent.stat()
    parent_fd = os.open(output.parent, flags)
    try:
        parent_open = os.fstat(parent_fd)
        if (parent_open.st_dev, parent_open.st_ino) != (parent_before.st_dev, parent_before.st_ino):
            raise ValueError("Output parent directory changed during validation")
        os.mkdir(output.name, mode=0o700, dir_fd=parent_fd)
        return os.open(output.name, flags, dir_fd=parent_fd)
    finally:
        os.close(parent_fd)


def write_once_at(root_fd: int, relative: str, payload: bytes) -> None:
    """Write only below the new output directory's pinned descriptor."""
    relpath = PurePosixPath(relative)
    pieces = relpath.parts
    if relpath.is_absolute() or not pieces or any(piece in {"", ".", ".."} for piece in pieces):
        raise ValueError("Output path must be relative and non-traversing")
    flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.dup(root_fd)
    try:
        for part in pieces[:-1]:
            try:
                os.mkdir(part, mode=0o700, dir_fd=fd)
            except FileExistsError:
                pass
            next_fd = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        write_flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY | getattr(os, "O_NOFOLLOW", 0)
        file_fd = os.open(pieces[-1], write_flags, 0o600, dir_fd=fd)
        with os.fdopen(file_fd, "wb") as stream:
            stream.write(payload)
    finally:
        os.close(fd)

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
    root_fd = open_new_output(webroot, opts.policy, opts.output)
    try:
        write_once_at(root_fd, 'js/app.min.js', new_min)
        write_once_at(root_fd, 'mxgraph/src/util/mxSvgCanvas2D.js', new_src)
        patch = ''.join(difflib.unified_diff(original_src.decode().splitlines(True), new_src.decode().splitlines(True),
                  fromfile='a/mxgraph/src/util/mxSvgCanvas2D.js', tofile='b/mxgraph/src/util/mxSvgCanvas2D.js'))
        write_once_at(root_fd, 'readable-source.patch', patch.encode())
        record = {'schema': 'drawio31-cssom-candidate-v1', 'publication_eligible': False,
                  'source_bundle_sha256': ORIGINAL['bundle'], 'patched_bundle_sha256': digest(new_min),
                  'source_readable_sha256': ORIGINAL['readable'], 'patched_readable_sha256': digest(new_src),
                  'unchanged_policy_sha256': ORIGINAL['policy'], 'bundle_function_replacements': 1,
                  'source_function_replacements': 1}
        write_once_at(root_fd, 'receipt.json', (json.dumps(record, indent=2, sort_keys=True)+'\n').encode())
    finally:
        os.close(root_fd)
    print(json.dumps(record, sort_keys=True))

if __name__ == '__main__':
    main()
