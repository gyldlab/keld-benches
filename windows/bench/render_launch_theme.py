#!/usr/bin/env python3
"""Apply the benchmark black launch theme to a staged HTML file."""

from __future__ import annotations

from pathlib import Path
import sys

MARKER = b"data-keld-bench-launch-theme"
LAUNCH_STYLE = (
    b'<style data-keld-bench-launch-theme>'
    b'html,body{background:#000!important;color:#fff;color-scheme:dark}'
    b'</style>\n'
)


def apply_black_launch_theme(html: bytes) -> bytes:
    """Return staged HTML with the launch theme inserted before </head>."""
    if html.count(b"</head>") != 1:
        raise ValueError("launch HTML must contain exactly one closing head tag")
    if MARKER in html:
        raise ValueError("launch HTML already contains the benchmark theme marker")
    return html.replace(b"</head>", LAUNCH_STYLE + b"</head>", 1)


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: render_launch_theme.py /absolute/index.html")
    path = Path(sys.argv[1])
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise SystemExit("launch HTML must be an existing absolute regular file")
    original = path.read_bytes()
    themed = apply_black_launch_theme(original)
    path.write_bytes(themed)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
