#!/usr/bin/env python3
"""Plan the smallest safe CI run from a Git tree comparison.

The command writes this stable GitHub-output contract, using lowercase JSON
booleans as values::

    planner_tests=true
    contract=false
    linux_unit=false
    linux_gtk=false
    windows=false
    macos=false

``planner_tests`` is always true on a successful invocation.  The remaining
outputs are the routed CI leaves.  If ``--output`` is omitted, ``GITHUB_OUTPUT``
is used when set; otherwise the same contract is printed to stdout.

Published benchmark results are append-only evidence.  Modifying or deleting
one is an error, while adding one schedules the contract checks.  An absent,
all-zero, or otherwise unusable base revision cannot safely narrow CI, so it
schedules every routed leaf.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import os
from pathlib import Path
import subprocess
import sys
from typing import Iterable, Mapping, Sequence


ROUTES = ("contract", "linux_unit", "linux_gtk", "windows", "macos")
ALL_ROUTES = {route: True for route in ROUTES}
LEGACY_WINDOWS_EVIDENCE = {
    "windows/bench/windows-first-paint.json",
    "windows/bench/windows-first-paint-kel65-direct-com.json",
    "windows/bench/windows-first-paint-kel65-baseline.json",
    "windows/bench/windows-first-paint-kel66-smartscreen-off.json",
}


@dataclass(frozen=True)
class Change:
    """One name-status record emitted by Git."""

    status: str
    path: str


class PlanError(Exception):
    """A change makes it unsafe to produce a CI plan."""


def _is_zero_revision(revision: str) -> bool:
    return bool(revision) and set(revision) == {"0"}


def _all_routes() -> dict[str, bool]:
    return dict(ALL_ROUTES)


def parse_name_status_z(output: bytes) -> list[Change]:
    """Parse ``git diff --name-status -z --no-renames`` without line splitting.

    Paths are decoded with Python's filesystem codec and surrogate escaping, so
    tabs, newlines, and non-UTF-8 bytes never become record delimiters.
    """

    if not output:
        return []

    fields = output.split(b"\0")
    if fields[-1] != b"":
        raise ValueError("git name-status output is not NUL terminated")
    fields.pop()
    if len(fields) % 2:
        raise ValueError("git name-status output has an incomplete record")

    changes: list[Change] = []
    for index in range(0, len(fields), 2):
        raw_status, raw_path = fields[index : index + 2]
        try:
            status = raw_status.decode("ascii")
        except UnicodeDecodeError as error:
            raise ValueError("git emitted a non-ASCII change status") from error
        if status not in {"A", "B", "D", "M", "T", "U", "X"}:
            raise ValueError(f"invalid git change status: {status!r}")
        if not raw_path:
            raise ValueError("git emitted an empty path")
        changes.append(Change(status=status, path=os.fsdecode(raw_path)))
    return changes


def git_changes(base: str, head: str, repo: Path) -> list[Change] | None:
    """Return changes, or ``None`` when the comparison cannot be trusted."""

    if not base or _is_zero_revision(base):
        return None

    command = [
        "git",
        "diff",
        "--name-status",
        "-z",
        "--no-renames",
        base,
        head,
        "--",
    ]
    try:
        result = subprocess.run(
            command,
            cwd=repo,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError:
        return None
    if result.returncode != 0:
        return None
    try:
        return parse_name_status_z(result.stdout)
    except ValueError:
        return None


def _parts(path: str) -> tuple[str, ...]:
    # Git paths always use '/', including on Windows runners.
    return tuple(path.split("/"))


def _is_result(path: str) -> bool:
    if path in LEGACY_WINDOWS_EVIDENCE:
        return True
    parts = _parts(path)
    return any(
        parts[index] == "bench" and parts[index + 1] == "results"
        for index in range(len(parts) - 1)
    )


def _forces_all(path: str) -> bool:
    parts = _parts(path)
    name = parts[-1]
    return (
        name == "AGENTS.md"
        or path == "HARNESS-CONTRACT.md"
        or path.startswith(".github/workflows/")
        or path.startswith("ci/")
        or name == ".gitattributes"
        or name == "requirements.txt"
        or (name.startswith("requirements-") and name.endswith(".txt"))
        or "requirements" in parts[:-1]
    )


def _is_prose_document(path: str) -> bool:
    return path.lower().endswith((".md", ".markdown", ".rst"))


def routes_for_path(path: str) -> set[str] | None:
    """Return explicit routes, or ``None`` for an unknown non-doc path."""

    routes: set[str] = set()

    if path.startswith("schema/"):
        routes.add("contract")

    if path in {
        "windows/bench/validate_result_v1.py",
        "windows/bench/test_validate_result_v1.py",
    }:
        routes.add("contract")

    if path in {
        "linux/bench/harness.py",
        "linux/bench/run.py",
        "linux/bench/test_harness.py",
        "linux/keld/hello/build.sh",
        "linux/keld/hello/index.html",
        "linux/keld/hello/keld-bench-url.patch",
        "schema/metrics.v1.json",
    }:
        routes.add("linux_unit")

    if path in {
        "linux/gtk4/hello/build.sh",
        "linux/gtk4/hello/main.c",
        "linux/gtk4/hello/test_fixture.py",
        "linux/bench/harness.py",
        "linux/keld/hello/index.html",
    }:
        routes.add("linux_gtk")

    if (
        (
            path.startswith("windows/bench/")
            and "/" not in path[len("windows/bench/") :]
            and path.endswith(".ps1")
        )
        or path == "windows/bench/hello.template.html"
        or path == "windows/bench/extract_tauri_payload.py"
        or path == "MEASUREMENTS.md"
        or path in LEGACY_WINDOWS_EVIDENCE
    ):
        routes.add("windows")

    if path.startswith("macos/swift/appkit-wk/") or path.startswith(
        "macos/swift/swiftui-wk/"
    ):
        routes.add("macos")

    if routes:
        return routes
    if _is_prose_document(path):
        return set()
    return None


def plan_changes(changes: Iterable[Change] | None) -> dict[str, bool]:
    """Build a route map; ``None`` means Git could not provide a safe diff."""

    if changes is None:
        return _all_routes()

    changes = list(changes)
    for change in changes:
        if _is_result(change.path) and not change.status.startswith("A"):
            raise PlanError(
                "published benchmark result must not be modified or deleted: "
                f"{change.status} {change.path!r}"
            )

    selected: set[str] = set()
    for change in changes:
        if _forces_all(change.path):
            return _all_routes()
        if _is_result(change.path):
            selected.add("contract")
            continue
        path_routes = routes_for_path(change.path)
        if path_routes is None:
            return _all_routes()
        selected.update(path_routes)

    return {route: route in selected for route in ROUTES}


def output_values(routes: Mapping[str, bool]) -> str:
    """Serialize the documented GitHub-output contract."""

    values = {"planner_tests": True}
    values.update((route, bool(routes[route])) for route in ROUTES)
    return "".join(
        f"{name}={'true' if enabled else 'false'}\n"
        for name, enabled in values.items()
    )


def emit_outputs(routes: Mapping[str, bool], output: str | None) -> None:
    rendered = output_values(routes)
    if output:
        with Path(output).open("a", encoding="utf-8", newline="\n") as stream:
            stream.write(rendered)
    else:
        sys.stdout.write(rendered)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True, help="base Git revision")
    parser.add_argument("--head", default="HEAD", help="head Git revision (default: HEAD)")
    parser.add_argument("--repo", type=Path, default=Path.cwd(), help="repository root")
    parser.add_argument(
        "--output",
        default=os.environ.get("GITHUB_OUTPUT"),
        help="GitHub output file (default: GITHUB_OUTPUT, or stdout)",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    changes = git_changes(args.base, args.head, args.repo)
    try:
        routes = plan_changes(changes)
    except PlanError as error:
        print(f"ci planner rejected change: {error}", file=sys.stderr)
        return 2
    try:
        emit_outputs(routes, args.output)
    except OSError as error:
        print(f"ci planner could not write outputs: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
