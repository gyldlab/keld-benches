#!/usr/bin/env python3
"""Enforce the small, explicit always-loaded instruction inventory."""

from __future__ import annotations

from dataclasses import dataclass
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path, PurePosixPath
import sys
import tempfile

try:
    import tiktoken
except ImportError:
    tiktoken = None

try:
    TIKTOKEN_VERSION = version("tiktoken")
except PackageNotFoundError:
    TIKTOKEN_VERSION = None


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "ci" / "instruction_budget.tsv"
CLASSES = {"always", "routed", "evidence"}
REQUIRED_VISIBLE_MARKERS = (
    "## Atomic performance proof",
    "| Census |",
    "| Work |",
    "| Queue/copy |",
    "| Clock/oracle |",
    "| Statistic |",
    "| Artifact provenance |",
    "## Change discipline",
    "`HARNESS-CONTRACT.md` owns fixture layout, comparison, result immutability, and publication",
    "Unavailable OS evidence is **unverified**",
    "## Routed CI and publication",
    "`ci/plan.py` owns path classification and immutable-evidence rejection",
    "`ci/required.py` owns aggregate admission",
    "Agents MUST execute the planner for applicability",
    "Unknown executable inputs must fail safe through the planner owner",
    "Hosted CI MUST NOT generate, overwrite, re-emit, upload, or publish benchmark results",
)


@dataclass(frozen=True)
class Entry:
    path: str
    load_class: str
    max_bytes: int
    observed_bytes: int
    encoding: str
    implementation: str
    max_tokens: int
    observed_tokens: int
    owner: str
    trigger: str


def parse_manifest(path: Path) -> tuple[list[Entry], list[str]]:
    entries: list[Entry] = []
    problems: list[str] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        return [], [f"cannot read instruction manifest: {error}"]
    for line_number, line in enumerate(lines, start=1):
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 10:
            problems.append(f"manifest line {line_number} must have 10 tab-separated fields")
            continue
        try:
            entries.append(
                Entry(
                    path=fields[0],
                    load_class=fields[1],
                    max_bytes=int(fields[2]),
                    observed_bytes=int(fields[3]),
                    encoding=fields[4],
                    implementation=fields[5],
                    max_tokens=int(fields[6]),
                    observed_tokens=int(fields[7]),
                    owner=fields[8],
                    trigger=fields[9],
                )
            )
        except ValueError:
            problems.append(f"manifest line {line_number} has a non-integer budget")
    return entries, problems


def check(root: Path, manifest: Path) -> list[str]:
    entries, problems = parse_manifest(manifest)
    paths = [entry.path for entry in entries]
    owners = [entry.owner for entry in entries]
    if len(paths) != len(set(paths)):
        problems.append("instruction manifest contains a duplicate path")
    if len(owners) != len(set(owners)):
        problems.append("instruction manifest contains a duplicate owner")

    discovered: set[str] = set()
    for candidate in root.rglob("AGENTS*.md"):
        relative = candidate.relative_to(root).as_posix()
        if candidate.name == "AGENTS.override.md":
            problems.append(f"override instruction file is forbidden: {relative}")
        elif candidate.name == "AGENTS.md":
            discovered.add(relative)
            if candidate.is_symlink():
                problems.append(f"instruction file must not be a symlink: {relative}")
    unknown = discovered - set(paths)
    missing = set(paths) - discovered
    problems.extend(f"unknown instruction file: {path}" for path in sorted(unknown))
    problems.extend(f"manifest instruction file is missing: {path}" for path in sorted(missing))

    for entry in entries:
        pure = PurePosixPath(entry.path)
        if pure.is_absolute() or ".." in pure.parts:
            problems.append(f"instruction path is not repository-relative: {entry.path}")
            continue
        if entry.load_class not in CLASSES:
            problems.append(f"unknown load class for {entry.path}: {entry.load_class}")
        if not entry.owner or not entry.trigger:
            problems.append(f"instruction owner/trigger is empty: {entry.path}")
        if (
            entry.encoding != "o200k_base"
            or entry.implementation != "tiktoken@0.14.0"
            or TIKTOKEN_VERSION != "0.14.0"
        ):
            problems.append(f"instruction tokenizer pin drifted: {entry.path}")
        target = root / pure
        try:
            data = target.read_bytes()
            text = data.decode("utf-8")
        except (OSError, UnicodeDecodeError) as error:
            problems.append(f"cannot read UTF-8 instruction {entry.path}: {error}")
            continue
        if len(data) != entry.observed_bytes:
            problems.append(
                f"instruction byte record is stale for {entry.path}: "
                f"manifest={entry.observed_bytes} actual={len(data)}"
            )
        if len(data) > entry.max_bytes:
            problems.append(f"instruction byte budget exceeded: {entry.path}")
        if len(data) < 256:
            problems.append(f"instruction file is hollow: {entry.path}")
        if tiktoken is None:
            problems.append("tiktoken is required to verify the instruction token budget")
        else:
            try:
                token_encoding = tiktoken.get_encoding(entry.encoding)
            except ValueError:
                problems.append(
                    f"instruction tokenizer encoding is unsupported: {entry.encoding}"
                )
            else:
                actual_tokens = len(token_encoding.encode(text))
                if actual_tokens != entry.observed_tokens:
                    problems.append(
                        f"instruction token record is stale for {entry.path}: "
                        f"manifest={entry.observed_tokens} actual={actual_tokens}"
                    )
                if actual_tokens > entry.max_tokens:
                    problems.append(f"instruction token budget exceeded: {entry.path}")
        if "```" in text or "<!--" in text or any(
            line.lstrip().startswith(">") for line in text.splitlines()
        ):
            problems.append(f"instruction file contains hidden/quoted decoy syntax: {entry.path}")
        visible = " ".join(text.split())
        for marker in REQUIRED_VISIBLE_MARKERS:
            if marker not in visible:
                problems.append(f"instruction semantic marker is missing: {marker}")
    return problems


def self_test() -> list[str]:
    failures: list[str] = []
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        (root / "ci").mkdir()
        source = (ROOT / "AGENTS.md").read_bytes()
        (root / "AGENTS.md").write_bytes(source)

        def manifest_line(
            *, max_bytes: int = 4096, observed_bytes: int | None = None,
            max_tokens: int = 1024, observed_tokens: int = 681,
            encoding: str = "o200k_base",
        ) -> str:
            actual = len(source) if observed_bytes is None else observed_bytes
            return (
                f"AGENTS.md\talways\t{max_bytes}\t{actual}\t{encoding}\t"
                f"tiktoken@0.14.0\t{max_tokens}\t{observed_tokens}\t"
                "benchmark-evidence-floor\talways\n"
            )

        manifest = root / "ci" / "instruction_budget.tsv"
        manifest.write_text(manifest_line(), encoding="utf-8")
        if check(root, manifest):
            failures.append("canonical instruction fixture did not pass")

        manifest.write_text(
            manifest_line(max_bytes=len(source) - 1), encoding="utf-8"
        )
        if not any("byte budget exceeded" in item for item in check(root, manifest)):
            failures.append("max+1 byte instruction did not fail")
        manifest.write_text(manifest_line(), encoding="utf-8")

        nested = root / "nested" / "AGENTS.md"
        nested.parent.mkdir()
        nested.write_bytes(source)
        if not any("unknown instruction file" in item for item in check(root, manifest)):
            failures.append("unknown nested instruction did not fail")
        nested.unlink()

        override = root / "AGENTS.override.md"
        override.write_text("override\n", encoding="utf-8")
        if not any("override instruction file" in item for item in check(root, manifest)):
            failures.append("override instruction did not fail")
        override.unlink()

        manifest.write_text(
            manifest_line(observed_bytes=len(source) + 1), encoding="utf-8"
        )
        if not any("byte record is stale" in item for item in check(root, manifest)):
            failures.append("stale byte record did not fail")

        manifest.write_text(
            manifest_line(max_tokens=680, observed_tokens=681), encoding="utf-8"
        )
        if not any("token budget exceeded" in item for item in check(root, manifest)):
            failures.append("token max+1 record did not fail")

        manifest.write_text(
            manifest_line(observed_tokens=680), encoding="utf-8"
        )
        if not any("token record is stale" in item for item in check(root, manifest)):
            failures.append("stale token record did not fail")

        manifest.write_text(
            manifest_line(encoding="not-an-encoding"), encoding="utf-8"
        )
        current = check(root, manifest)
        if not any("encoding is unsupported" in item for item in current):
            failures.append("unsupported tokenizer encoding did not fail cleanly")

        (root / "AGENTS.md").write_text("# hollow\n", encoding="utf-8")
        manifest.write_text(manifest_line(observed_bytes=9), encoding="utf-8")
        current = check(root, manifest)
        if not any("hollow" in item for item in current) or not any(
            "semantic marker" in item for item in current
        ):
            failures.append("hollow/semantic instruction mutation did not fail")
    return failures


def main(arguments: list[str]) -> int:
    if arguments == ["test"]:
        problems = self_test()
    elif arguments == ["check"]:
        problems = check(ROOT, MANIFEST)
    else:
        print("usage: check_instructions.py check|test", file=sys.stderr)
        return 2
    if problems:
        for problem in problems:
            print(f"instruction check failed: {problem}", file=sys.stderr)
        return 1
    print(f"instruction {arguments[0]} passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
