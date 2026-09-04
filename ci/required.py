#!/usr/bin/env python3
"""Fail unless every CI job has exactly the result selected by the route plan."""

from __future__ import annotations

import os
import sys
from collections.abc import Mapping


ROUTES = {
    "contract": ("CONTRACT_REQUESTED", "CONTRACT_RESULT"),
    "linux_unit": ("LINUX_UNIT_REQUESTED", "LINUX_UNIT_RESULT"),
    "linux_gtk": ("LINUX_GTK_REQUESTED", "LINUX_GTK_RESULT"),
    "windows": ("WINDOWS_REQUESTED", "WINDOWS_RESULT"),
    "macos": ("MACOS_REQUESTED", "MACOS_RESULT"),
}


def evidence_problems(environment: Mapping[str, str]) -> list[str]:
    """Return every missing, failed, cancelled, or unexpectedly skipped result."""

    problems: list[str] = []
    for name in ("PLAN_RESULT", "SECRETS_RESULT"):
        if environment.get(name) != "success":
            problems.append(f"{name.lower()} must be success; got {environment.get(name)!r}")

    for route, (requested_name, result_name) in ROUTES.items():
        requested = environment.get(requested_name)
        result = environment.get(result_name)
        if requested not in {"true", "false"}:
            problems.append(f"{route} has invalid requested value {requested!r}")
            continue
        expected = "success" if requested == "true" else "skipped"
        if result != expected:
            problems.append(
                f"{route} requested={requested} requires {expected}; got {result!r}"
            )
    return problems


def main() -> int:
    problems = evidence_problems(os.environ)
    if problems:
        for problem in problems:
            print(f"required CI rejected: {problem}", file=sys.stderr)
        return 1
    print("required CI evidence complete")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
