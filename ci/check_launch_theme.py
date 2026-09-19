#!/usr/bin/env python3
"""Fail closed if an active benchmark launch surface can render non-black."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]

FROZEN_GENERATED_SNAPSHOTS = {
    Path("linux/keld/dev-hello/project/index.html"),
    Path("macos/keld/hello/index.html"),
    Path("windows/keld/hello/index.html"),
}

EMBEDDED_HTML_LAUNCHERS = {
    Path("macos/swift/appkit-wk/HelloAppKit.swift"),
    Path("macos/swift/swiftui-wk/HelloSwiftUI.swift"),
}

STYLE_BLOCK = re.compile(r"(?is)<style\b[^>]*>(.*?)</style>")
CSS_RULE = re.compile(r"(?s)([^{}]+)\{([^{}]*)\}")
ROOT_SELECTOR = re.compile(r"(?i)(?<![\w-])(html|body)(?![\w-])")
BACKGROUND_DECL = re.compile(
    r"(?i)(?:^|;)\s*(background(?:-color)?)\s*:\s*([^;]+)"
)
INLINE_ROOT_STYLE = re.compile(
    r"""(?is)<(?:html|body)\b[^>]*\bstyle\s*=\s*(['"])(.*?)\1"""
)


def _is_black(value: str) -> bool:
    value = re.sub(r"(?i)\s*!important\s*$", "", value.strip()).lower()
    return value in {"#000", "#000000"}


def _root_backgrounds(text: str) -> list[tuple[str, str]]:
    declarations: list[tuple[str, str]] = []
    for style in STYLE_BLOCK.findall(text):
        style = re.sub(r"(?s)/\*.*?\*/", "", style)
        for selector, block in CSS_RULE.findall(style):
            if not ROOT_SELECTOR.search(selector):
                continue
            for _property, value in BACKGROUND_DECL.findall(block):
                declarations.append((selector.strip(), value.strip()))
    for match in INLINE_ROOT_STYLE.finditer(text):
        for _property, value in BACKGROUND_DECL.findall(match.group(2)):
            declarations.append(("inline html/body style", value.strip()))
    return declarations


def _background_problems(text: str) -> list[str]:
    declarations = _root_backgrounds(text)
    problems = [
        f"{selector!r} declares non-black background {value!r}"
        for selector, value in declarations
        if not _is_black(value)
    ]
    if not any(_is_black(value) for _selector, value in declarations):
        problems.append("no explicit black html/body background declaration")
    return problems


def _load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def _check_linux_staged_renderer() -> list[str]:
    problems: list[str] = []
    harness = _load_module(
        "keld_bench_linux_harness_theme_check",
        ROOT / "linux" / "bench" / "harness.py",
    )
    source = b"<html><head><title>x</title></head><body>x</body></html>"
    beacon = (
        b'const u="http://127.0.0.1:__KELD_BENCH_PORT__/'
        b'__KELD_BENCH_NONCE__";'
    )
    rendered = harness.render_product_renderer(source, beacon, 12345, "0" * 32)
    if b"data-keld-bench-launch-theme" not in rendered:
        problems.append("Linux staged renderer omitted launch-theme marker")
    if rendered.find(b"data-keld-bench-launch-theme") > rendered.find(b"</head>"):
        problems.append("Linux staged renderer applied theme after </head>")
    problems.extend(
        f"Linux staged renderer: {problem}"
        for problem in _background_problems(rendered.decode("utf-8"))
    )
    if source != b"<html><head><title>x</title></head><body>x</body></html>":
        problems.append("Linux staged renderer mutated source fixture bytes")
    return problems


def _check_windows_staged_renderer() -> list[str]:
    problems: list[str] = []
    renderer = _load_module(
        "keld_bench_windows_launch_theme",
        ROOT / "windows" / "bench" / "render_launch_theme.py",
    )
    source = b"<html><head><title>x</title></head><body>x</body></html>"
    rendered = renderer.apply_black_launch_theme(source)
    if renderer.MARKER not in rendered:
        problems.append("Windows staged renderer omitted launch-theme marker")
    if rendered.find(renderer.MARKER) > rendered.find(b"</head>"):
        problems.append("Windows staged renderer applied theme after </head>")
    problems.extend(
        f"Windows staged renderer: {problem}"
        for problem in _background_problems(rendered.decode("utf-8"))
    )
    ps = (ROOT / "windows" / "bench" / "Measure-KeldPaint.ps1").read_text()
    invocation = r"(?m)^\s*& python \$themeRenderer \$idxPath\s*$"
    if not re.search(invocation, ps):
        problems.append("Measure-KeldPaint.ps1 does not invoke the tested renderer")
    return problems


# Negative controls: a later or more-specific white root rule must fail.
for bad in (
    "<style>body{background:#000}body{background:#fff}</style>",
    "<style>html,body{background:#000}html body{background:#fff!important}</style>",
    '<html><body style="background:#fff"><style>body{background:#000}</style></body></html>',
):
    if not _background_problems(bad):
        raise SystemExit("launch-theme negative control accepted a white override")

launch_html = sorted(
    {
        *Path(ROOT / "linux").rglob("*.html"),
        *Path(ROOT / "macos").rglob("*.html"),
        *Path(ROOT / "windows").rglob("*.html"),
        ROOT / "schema" / "canonical-payload.v1.html",
    }
)

failures: list[str] = []
for absolute in launch_html:
    relative = absolute.relative_to(ROOT)
    if relative in FROZEN_GENERATED_SNAPSHOTS:
        continue
    text = absolute.read_text(encoding="utf-8")
    failures.extend(
        f"{relative}: {problem}" for problem in _background_problems(text)
    )

for relative in sorted(EMBEDDED_HTML_LAUNCHERS):
    text = (ROOT / relative).read_text(encoding="utf-8")
    failures.extend(
        f"{relative}: {problem}" for problem in _background_problems(text)
    )

canonical = (ROOT / "schema" / "canonical-payload.v1.html").read_bytes()
windows_tauri = (ROOT / "windows" / "tauri" / "hello" / "src" / "index.html").read_bytes()
if canonical != windows_tauri:
    failures.append(
        "windows/tauri/hello/src/index.html must remain byte-identical to "
        "schema/canonical-payload.v1.html"
    )

failures.extend(_check_linux_staged_renderer())
failures.extend(_check_windows_staged_renderer())

if failures:
    for failure in failures:
        print(f"FAIL  {failure}")
    sys.exit(f"{len(failures)} launch-theme check(s) FAILED")

print(
    "PASS  active launch HTML is conflict-free #000 and Linux/Windows staged "
    "renderer transformations produce the black theme"
)
