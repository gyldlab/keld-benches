#!/usr/bin/env python3
"""Shared result.v3 helpers for high-volume block-corpus benchmarks."""

from __future__ import annotations

import hashlib
from typing import Any


def ns_to_us(value: int | float) -> float:
    return round(float(value) / 1000.0, 6)


def block_bootstrap_metadata(*, resamples: int, method: str, seed: int, rng: str) -> dict[str, Any]:
    if resamples < 1000:
        raise ValueError("block bootstrap requires at least 1000 resamples")
    return {
        "unit": "block",
        "resamples": resamples,
        "method": method,
        "seed": seed,
        "rng": rng,
    }


def block_corpus(
    raw_files: list[dict[str, Any]],
    *,
    tier: str,
    block_unit: str,
    observations_per_block: int,
    bootstrap: dict[str, Any],
    arm: str | None = None,
) -> dict[str, Any]:
    """Build one ordered valid-block ledger from campaign raw-file receipts."""

    selected = [
        item
        for item in raw_files
        if item.get("tier") == tier and (arm is None or item.get("arm") == arm)
    ]
    selected.sort(key=lambda item: item.get("block", 0))
    if not selected:
        raise ValueError(f"no raw files for tier={tier!r} arm={arm!r}")
    block_ids = [item.get("block") for item in selected]
    expected = list(range(1, len(selected) + 1))
    if block_ids != expected:
        raise ValueError(f"block ids {block_ids!r} are not contiguous {expected!r}")
    if observations_per_block < 1:
        raise ValueError("observations_per_block must be positive")

    blocks: list[dict[str, Any]] = []
    digest = hashlib.sha256()
    seen_paths: set[str] = set()
    for item in selected:
        path = item.get("path")
        sha = item.get("sha256")
        size = item.get("bytes")
        if not isinstance(path, str) or path in seen_paths:
            raise ValueError(f"invalid or duplicate raw path: {path!r}")
        seen_paths.add(path)
        if not isinstance(sha, str) or len(sha) != 64:
            raise ValueError(f"invalid raw sha256 for {path}")
        try:
            digest.update(bytes.fromhex(sha))
        except ValueError as error:
            raise ValueError(f"invalid raw sha256 for {path}") from error
        if not isinstance(size, int) or isinstance(size, bool) or size < 1:
            raise ValueError(f"invalid raw byte count for {path}")
        blocks.append(
            {
                "block": int(item["block"]),
                "valid": True,
                "observations": observations_per_block,
                "raw_file": {"path": path, "sha256": sha, "bytes": size},
                "reject_reason": None,
            }
        )
    return {
        "block_unit": block_unit,
        "blocks": blocks,
        "digest_chain_sha256": digest.hexdigest(),
        "bootstrap": bootstrap,
    }


def ipc_statistics_us(stats_ns: dict[str, Any], *, bootstrap_method: str) -> dict[str, Any]:
    """Map campaign ns statistics into the shared IPC-RTT microsecond contract."""

    required = (
        "sessions",
        "pooled_timed_calls",
        "p50_ns",
        "p90_ns",
        "p99_ns",
        "max_ns",
        "bootstrap_ci95_p50_ns",
        "bootstrap_ci95_p99_ns",
    )
    missing = [name for name in required if name not in stats_ns]
    if missing:
        raise ValueError(f"missing IPC statistics: {missing}")
    p50_ci = stats_ns["bootstrap_ci95_p50_ns"]
    p99_ci = stats_ns["bootstrap_ci95_p99_ns"]
    if not (isinstance(p50_ci, list) and len(p50_ci) == 2):
        raise ValueError("bootstrap_ci95_p50_ns must be a [lower, upper] pair")
    if not (isinstance(p99_ci, list) and len(p99_ci) == 2):
        raise ValueError("bootstrap_ci95_p99_ns must be a [lower, upper] pair")
    return {
        "valid_samples": int(stats_ns["sessions"]),
        "observations": int(stats_ns["pooled_timed_calls"]),
        "median": ns_to_us(stats_ns["p50_ns"]),
        "p90": ns_to_us(stats_ns["p90_ns"]),
        "p99": ns_to_us(stats_ns["p99_ns"]),
        "max": ns_to_us(stats_ns["max_ns"]),
        "confidence_intervals": {
            "median": {
                "lower": ns_to_us(p50_ci[0]),
                "upper": ns_to_us(p50_ci[1]),
                "resamples": int(stats_ns.get("bootstrap_resamples", 2000)),
                "method": bootstrap_method,
            },
            "p99": {
                "lower": ns_to_us(p99_ci[0]),
                "upper": ns_to_us(p99_ci[1]),
                "resamples": int(stats_ns.get("bootstrap_resamples", 2000)),
                "method": bootstrap_method,
            },
        },
    }


def linux_ipc_environment(metadata: dict[str, Any]) -> dict[str, Any]:
    """Normalize the legacy flat KIPC environment receipt into result.v3 shape."""

    ac_power = metadata.get("ac_power")
    if not isinstance(ac_power, bool):
        raise ValueError("IPC result.v3 requires verified boolean ac_power")
    profile = metadata.get("power_profile")
    if profile not in {"power-saver", "balanced", "performance"}:
        raise ValueError(f"IPC result.v3 requires known power profile, got {profile!r}")
    ram_kib = metadata.get("ram_kib")
    if not isinstance(ram_kib, int) or isinstance(ram_kib, bool) or ram_kib < 0:
        raise ValueError("IPC result.v3 requires integer ram_kib")
    toolchains = []
    for name, key in (
        ("rustc", "rustc"),
        ("cargo", "cargo"),
        ("bun", "bun_version"),
        ("bun-revision", "bun_revision"),
    ):
        value = metadata.get(key)
        if isinstance(value, str) and value:
            toolchains.append({"name": name, "version": value})
    return {
        "os": {
            "name": "linux",
            "version": str(metadata.get("os", "unknown")),
            "build": str(metadata.get("kernel", "unknown")),
        },
        "hardware": {
            "cpu": str(metadata.get("cpu", "unknown")),
            "arch": str(metadata.get("arch", "unknown")),
            "ram_bytes": ram_kib * 1024,
        },
        "power": {
            "ac_power": ac_power,
            "low_power_mode": profile == "power-saver",
            "thermal_state": str(metadata.get("thermal_state", "unverified")),
        },
        "toolchains": toolchains,
    }


def ipc_arm(
    *,
    arm_id: str,
    framework: dict[str, str],
    fixture_path: str,
    lane: str,
    role: str,
    artifacts: list[dict[str, Any]],
    raw_files: list[dict[str, Any]],
    tier: str,
    block_unit: str,
    observations_per_block: int,
    bootstrap: dict[str, Any],
    stats_ns: dict[str, Any],
    bootstrap_method: str,
    raw_arm: str | None = None,
) -> dict[str, Any]:
    """Build one result.v3 IPC arm from already validated campaign outputs."""

    if role not in {"score", "diagnostic"}:
        raise ValueError(f"unknown arm role {role!r}")
    if not artifacts:
        raise ValueError("IPC result arm requires at least one measured artifact")
    return {
        "arm_id": arm_id,
        "framework": framework,
        "fixture_path": fixture_path,
        "artifacts": artifacts,
        "lane": lane,
        "role": role,
        "corpus": block_corpus(
            raw_files,
            tier=tier,
            arm=raw_arm,
            block_unit=block_unit,
            observations_per_block=observations_per_block,
            bootstrap=bootstrap,
        ),
        "statistics": ipc_statistics_us(stats_ns, bootstrap_method=bootstrap_method),
    }


def ipc_result_document(
    *,
    metric_registry_version: int,
    cache_state: str,
    started_utc: str,
    finished_utc: str,
    requested_blocks: int,
    interleaving: str,
    label: str,
    notes: str,
    payload_tier: str,
    payload_bytes: int,
    environment: dict[str, Any],
    bench_sha: str,
    keld_sha: str,
    harness_path: str,
    harness_sha256: str,
    harness_modules: list[dict[str, str]],
    fixtures: list[dict[str, str]],
    arms: list[dict[str, Any]],
    publication_codes: list[str],
    diagnostic_comparisons: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """Build one schema-v3 IPC-RTT result for exactly one payload tier."""

    if payload_bytes < 1:
        raise ValueError("payload_bytes must be positive")
    if requested_blocks < 1:
        raise ValueError("requested_blocks must be positive")
    if not arms:
        raise ValueError("IPC result requires at least one arm")
    document: dict[str, Any] = {
        "schema_version": 3,
        "metric": {
            "id": "IPC-RTT",
            "unit": "us",
            "registry_version": metric_registry_version,
            "parameters": {
                "payload_tier": payload_tier,
                "payload_bytes": payload_bytes,
                "handshake_included": False,
            },
        },
        "cache_state": cache_state,
        "session": {
            "started_utc": started_utc,
            "finished_utc": finished_utc,
            "requested_samples": requested_blocks,
            "interleaving": interleaving,
            "label": label,
            "notes": notes,
        },
        "environment": environment,
        "provenance": {
            "bench_sha": bench_sha,
            "bench_tree_state": "clean",
            "keld_sha": keld_sha,
            "harness": {
                "path": harness_path,
                "sha256": harness_sha256,
                "version": "3.0.0",
                "modules": harness_modules,
            },
            "fixtures": fixtures,
        },
        "arms": arms,
        "publication": {
            "policy_version": 3,
            "requested": False,
            "eligible": not publication_codes,
            "reasons": [{"code": code} for code in publication_codes],
        },
    }
    if diagnostic_comparisons:
        document["diagnostic_comparisons"] = diagnostic_comparisons
    return document


def validate_v3_shape(document: dict[str, Any], repo_root) -> None:
    """Fail closed on v3 schema/semantic errors before writing campaign output.

    This deliberately does not verify raw sidecar existence under the repository,
    because campaigns are staged outside Git first. The shared repository validator
    performs path/size/hash verification after promotion.
    """

    import json
    import pathlib
    import sys

    try:
        from jsonschema import Draft202012Validator
    except ImportError as error:  # pragma: no cover - setup failure, not a measurement
        raise RuntimeError("jsonschema is required to emit result.v3") from error

    root = pathlib.Path(repo_root)
    schema_path = root / "schema" / "result.v3.schema.json"
    registry_path = root / "schema" / "metrics.v1.json"
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    registry = json.loads(registry_path.read_text(encoding="utf-8"))
    validator = Draft202012Validator(schema)
    errors = sorted(validator.iter_errors(document), key=lambda item: item.json_path)
    if errors:
        raise ValueError(f"result.v3 schema error {errors[0].json_path}: {errors[0].message}")

    schema_dir = str(root / "schema")
    if schema_dir not in sys.path:
        sys.path.insert(0, schema_dir)
    from result_contract import semantic_problems  # noqa: PLC0415

    semantic = semantic_problems(document, registry)
    if semantic:
        raise ValueError(f"result.v3 semantic error: {semantic[0]}")
