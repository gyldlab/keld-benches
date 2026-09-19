#!/usr/bin/env python3
"""Run the KEL-90 Linux shipping-Bun KIPC diagnostic campaign."""

from __future__ import annotations

import argparse
import bisect
import hashlib
import json
import math
import os
import platform
import random
import shutil
import subprocess
import sys
import time
from pathlib import Path

KELD_SHA = "0ea0780bb574ad242e9f1105fa4af5842872bad3"
FIXTURE = "kel90-linux-bun-kipc-echo"
RESULT_PREFIX = "linux/bench/results/ipc-rtt"
SESSIONS = 20
CALLS = 100_000
BOOTSTRAP_RESAMPLES = 2_000
BOOTSTRAP_SEED = 20260918
PILOT_P99_STOP_NS = 300_000
ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
BENCH_DIR = REPO / "linux" / "bench"
sys.path.insert(0, str(BENCH_DIR))
from thermal import (  # noqa: E402
    linux_thermal_snapshot,
    thermal_publication_reason,
    thermal_state_from_boundaries,
)

THERMAL_MODULE = BENCH_DIR / "thermal.py"
RUNNER = ROOT / "target/release/kel90-linux-bun-kipc-runner"
PRODUCT_HASHES = {
    "src/kipc.ts": "fb979d377fadfd2a9058dadf087f837444f17adc59c09acbe2daf24db0596e32",
    "src/kipc-transport.ts": "037b7fb3b2f277c28e7ccaf594200ecfba9bca9b19bc04b2234a15590f7b2901",
}
RESULT_MARKER = "KELD-90-BUN-IPC-RESULT"
FAILURE_MARKER = "KELD-90-BUN-IPC-EXPECTED-FAIL"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def checked(command: list[str], *, cwd: Path | None = None) -> str:
    completed = subprocess.run(command, cwd=cwd, text=True, capture_output=True, check=True)
    return completed.stdout.strip()


def percentile(sorted_values: list[int], q: float) -> int:
    if not sorted_values:
        raise ValueError("percentile requires at least one value")
    return sorted_values[max(0, math.ceil(q * len(sorted_values)) - 1)]
def weighted_kth(sessions: list[list[int]], weights: list[int], rank: int) -> int:
    lo = min(values[0] for values, weight in zip(sessions, weights) if weight)
    hi = max(values[-1] for values, weight in zip(sessions, weights) if weight)
    while lo < hi:
        mid = (lo + hi) // 2
        count = sum(
            weight * bisect.bisect_right(values, mid)
            for values, weight in zip(sessions, weights)
            if weight
        )
        if count >= rank:
            hi = mid
        else:
            lo = mid + 1
    return lo


def block_bootstrap_ci(sessions: list[list[int]], q: float) -> list[int]:
    rng = random.Random(BOOTSTRAP_SEED)
    session_count = len(sessions)
    total = sum(len(values) for values in sessions)
    rank = math.ceil(q * total)
    samples: list[int] = []
    for _ in range(BOOTSTRAP_RESAMPLES):
        weights = [0] * session_count
        for _ in range(session_count):
            weights[rng.randrange(session_count)] += 1
        samples.append(weighted_kth(sessions, weights, rank))
    samples.sort()
    return [percentile(samples, 0.025), percentile(samples, 0.975)]
def benchmark_environment(
    out_path: Path, tier: str, calls: int, fault: str, cache_state: str
) -> dict[str, str]:
    env = os.environ.copy()
    env.update(
        {
            "KELD_BENCH_PROJECT": str(ROOT),
            "KELD_BENCH_TIER": tier,
            "KELD_BENCH_CALLS": str(calls),
            "KELD_BENCH_OUT": str(out_path),
            "KELD_BENCH_KELD_SHA": KELD_SHA,
            "KELD_BENCH_FAULT": fault,
            "KELD_BENCH_MODE": cache_state,
        }
    )
    return env


def run_case(
    out_path: Path, tier: str, calls: int, fault: str, cache_state: str
) -> subprocess.CompletedProcess[str]:
    if out_path.exists():
        raise RuntimeError(f"refusing to overwrite {out_path}")
    completed = subprocess.run(
        [str(RUNNER)],
        cwd=ROOT,
        env=benchmark_environment(out_path, tier, calls, fault, cache_state),
        text=True,
        capture_output=True,
        timeout=120,
    )
    if fault == "none":
        if completed.returncode != 0 or completed.stdout.count(RESULT_MARKER) != 1:
            raise RuntimeError(
                f"live session failed rc={completed.returncode}\n"
                f"stdout={completed.stdout}\nstderr={completed.stderr}"
            )
        if not out_path.is_file():
            raise RuntimeError("successful session produced no output document")
    else:
        if completed.returncode == 0 or FAILURE_MARKER not in completed.stdout or out_path.exists():
            raise RuntimeError(
                f"negative control {fault} failed rc={completed.returncode}\n"
                f"stdout={completed.stdout}\nstderr={completed.stderr}"
            )
    return completed
def load_raw(path: Path, tier: str, calls: int, cache_state: str) -> dict:
    raw = path.read_bytes()
    if raw.count(b"\n") != 0:
        raise RuntimeError(f"{path} is not compact one-line JSON")
    document = json.loads(raw)
    expected_bytes = 6 if tier == "small" else 1024
    checks = {
        "fixture": document.get("fixture") == FIXTURE,
        "keld_sha": document.get("keld_sha") == KELD_SHA,
        "cache_state": document.get("cache_state") == cache_state,
        "tier": document.get("tier") == tier,
        "payload": document.get("payload_bytes") == expected_bytes,
        "calls_requested": document.get("calls_requested") == calls,
        "calls_timed": document.get("calls_timed") == calls,
        "deltas": len(document.get("deltas_ns", [])) == calls,
        "warmup_calls": document.get("warmup_calls") == (1_000 if cache_state == "warm-cache" else 0),
        "handshake_excluded": document.get("handshake_included_in_deltas") is False,
    }
    failed = [name for name, passed in checks.items() if not passed]
    if failed:
        raise RuntimeError(f"{path}: invariant failures {failed}")
    if any(not isinstance(value, int) or value < 0 for value in document["deltas_ns"]):
        raise RuntimeError(f"{path}: invalid RTT sample")
    return document
def tier_statistics(documents: list[dict]) -> dict:
    sessions = [sorted(document["deltas_ns"]) for document in documents]
    pooled = sorted(value for values in sessions for value in values)
    handshakes = sorted(int(document["handshake_ns"]) for document in documents)
    result = {
        "sessions": len(sessions),
        "calls_requested_per_session": CALLS,
        "calls_timed_per_session": CALLS,
        "pooled_timed_calls": len(pooled),
        "p50_ns": percentile(pooled, 0.50),
        "p90_ns": percentile(pooled, 0.90),
        "p99_ns": percentile(pooled, 0.99),
        "max_ns": pooled[-1],
        "bootstrap_ci95_p50_ns": block_bootstrap_ci(sessions, 0.50),
        "bootstrap_ci95_p99_ns": block_bootstrap_ci(sessions, 0.99),
        "handshake_ns": {
            "min": handshakes[0],
            "median": (handshakes[9] + handshakes[10]) / 2,
            "max": handshakes[-1],
        },
        "p99_budget_us": 100,
    }
    result["p99_ci_upper_headroom_x"] = round(
        100_000 / result["bootstrap_ci95_p99_ns"][1], 6
    )
    return result


def read_text(path: Path, default: str = "unknown") -> str:
    try:
        return path.read_text().strip()
    except OSError:
        return default
def publication_reasons_for_thermal(thermal_state: str, *, paired: bool) -> list[str]:
    """Stable raw-manifest blockers for one Linux KIPC campaign class."""
    reasons = []
    thermal_reason = thermal_publication_reason(thermal_state)
    if thermal_reason is not None:
        reasons.append(thermal_reason)
    reasons.append("RESULT_V2_SESSION_BLOCK_SCHEMA_GAP")
    reasons.append(
        "PRODUCT_CLIENT_VS_LIBRARY_FLOOR_DIAGNOSTIC"
        if paired
        else "NO_SAME_SESSION_PAIRED_RUST_ARM"
    )
    return reasons


def environment_metadata(
    thermal_state: str = "unverified", thermal_evidence: str | None = None
) -> dict:
    os_release: dict[str, str] = {}
    for line in Path("/etc/os-release").read_text().splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            os_release[key] = value.strip('"')
    cpu = "unknown"
    for line in Path("/proc/cpuinfo").read_text().splitlines():
        if line.startswith("model name"):
            cpu = line.split(":", 1)[1].strip()
            break
    ram_kib = int(Path("/proc/meminfo").read_text().split("MemTotal:", 1)[1].split()[0])
    power_profile = "unknown"
    if shutil.which("powerprofilesctl"):
        try:
            power_profile = checked(["powerprofilesctl", "get"])
        except subprocess.CalledProcessError:
            pass
    ac_power = None
    online = list(Path("/sys/class/power_supply").glob("*/online"))
    if online:
        ac_power = any(read_text(path) == "1" for path in online)
    return {
        "os": os_release.get("PRETTY_NAME", platform.platform()),
        "kernel": platform.release(),
        "arch": platform.machine(),
        "cpu": cpu,
        "cpu_logical": os.cpu_count(),
        "ram_kib": ram_kib,
        "ac_power": ac_power,
        "power_profile": power_profile,
        "thermal_state": thermal_state,
        "thermal_evidence": thermal_evidence,
        "rustc": checked(["rustc", "--version"]),
        "cargo": checked(["cargo", "--version"]),
        "bun_version": checked(["bun", "--version"]),
        "bun_revision": checked(["bun", "--revision"]),
    }
def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", required=True, type=Path)
    parser.add_argument(
        "--cache-state",
        required=True,
        choices=("fresh-process", "warm-cache"),
    )
    args = parser.parse_args()
    out_dir = args.out_dir.resolve()
    if out_dir.exists():
        raise RuntimeError(f"refusing to overwrite existing campaign directory {out_dir}")

    if checked(["git", "-C", str(REPO), "status", "--porcelain"]):
        raise RuntimeError("keld-benches worktree must be clean before timing")
    bench_sha = checked(["git", "-C", str(REPO), "rev-parse", "HEAD"])
    for relative, expected in PRODUCT_HASHES.items():
        actual = sha256(ROOT / relative)
        if actual != expected:
            raise RuntimeError(f"shipping client drift for {relative}: {actual} != {expected}")

    subprocess.run(["cargo", "build", "--release", "--locked"], cwd=ROOT, check=True)
    if not RUNNER.is_file():
        raise RuntimeError("Release runner was not produced")

    out_dir.mkdir(parents=True)
    controls = out_dir / "controls"
    controls.mkdir()
    for fault in ("bad-token", "wrong-response"):
        run_case(
            controls / f"{fault}.must-not-exist.json",
            "small",
            100,
            fault,
            args.cache_state,
        )

    priming = {}
    if args.cache_state == "warm-cache":
        prime_dir = out_dir / "priming"
        prime_dir.mkdir()
        for tier in ("small", "representative"):
            path = prime_dir / f"prime-{tier}.raw.json"
            run_case(path, tier, CALLS, "none", args.cache_state)
            document = load_raw(path, tier, CALLS, args.cache_state)
            priming[tier] = {
                "calls": CALLS,
                "warmup_calls": document["warmup_calls"],
                "sha256": sha256(path),
            }

    pilots = out_dir / "pilots"
    pilots.mkdir()
    pilot_stats = {}
    for tier in ("small", "representative"):
        path = pilots / f"pilot-{tier}.raw.json"
        run_case(path, tier, CALLS, "none", args.cache_state)
        document = load_raw(path, tier, CALLS, args.cache_state)
        values = sorted(document["deltas_ns"])
        p99 = percentile(values, 0.99)
        pilot_stats[tier] = {"p99_ns": p99, "sha256": sha256(path)}
        if p99 > PILOT_P99_STOP_NS:
            raise RuntimeError(f"{tier} pilot p99 {p99} ns exceeds sanity stop")
    campaign = out_dir / "campaign"
    campaign.mkdir()
    thermal_start = linux_thermal_snapshot()
    started_utc = thermal_start.sampled_utc
    date = started_utc[:10]
    documents: dict[str, list[dict]] = {"small": [], "representative": []}
    raw_files = []

    for session in range(1, SESSIONS + 1):
        for tier in ("small", "representative"):
            name = (
                f"{date}.kel90-linux-bun-100k-{tier}."
                f"{args.cache_state}.s{session:02d}.raw.json"
            )
            path = campaign / name
            run_case(path, tier, CALLS, "none", args.cache_state)
            document = load_raw(path, tier, CALLS, args.cache_state)
            documents[tier].append(document)
            raw_files.append(
                {
                    "path": f"{RESULT_PREFIX}/{name}",
                    "sha256": sha256(path),
                    "bytes": path.stat().st_size,
                }
            )
        print(f"completed Bun session pair {session:02d}", flush=True)

    thermal_end = linux_thermal_snapshot()
    thermal_state, thermal_evidence = thermal_state_from_boundaries(
        thermal_start, thermal_end
    )
    finished_utc = thermal_end.sampled_utc
    raw_files.sort(key=lambda item: item["path"])
    digest_chain = hashlib.sha256(
        b"".join(bytes.fromhex(item["sha256"]) for item in raw_files)
    ).hexdigest()
    tiers = {}
    for tier in ("small", "representative"):
        stats = tier_statistics(documents[tier])
        stats["payload_bytes"] = 6 if tier == "small" else 1024
        tiers[tier] = stats

    manifest = {
        "format": "kel90-linux-bun-ipc-rtt-campaign/v1",
        "classification": "diagnostic-product-client-arm",
        "campaign": {
            "cache_state": args.cache_state,
            "sessions": SESSIONS,
            "calls_per_session": CALLS,
            "priming_process_pair_per_tier": args.cache_state == "warm-cache",
            "priming": priming,
            "started_utc": started_utc,
            "finished_utc": finished_utc,
            "pilot_stop_p99_ns": PILOT_P99_STOP_NS,
            "pilot": pilot_stats,
            "negative_controls": ["bad-token", "wrong-response"],
        },
        "provenance": {
            "bench_sha": bench_sha,
            "keld_sha": KELD_SHA,
            "runner_artifact_sha256": sha256(RUNNER),
            "campaign_sha256": sha256(Path(__file__)),
            "thermal_probe_sha256": sha256(THERMAL_MODULE),
            "main_ts_sha256": sha256(ROOT / "src/main.ts"),
            "runner_rs_sha256": sha256(ROOT / "src/runner.rs"),
            "product_client_sources": PRODUCT_HASHES,
            "raw_corpus_digest_chain_sha256": digest_chain,
        },
        "environment": environment_metadata(thermal_state, thermal_evidence),
        "statistics_method": {
            "percentile": "nearest-rank ceil(p*n), one-indexed",
            "bootstrap": "sample 20 whole session blocks with replacement; pool selected blocks; recompute nearest-rank percentile",
            "resamples": BOOTSTRAP_RESAMPLES,
            "seed": BOOTSTRAP_SEED,
            "rng": "Python random.Random (MT19937)",
        },
        "tiers": tiers,
        "raw_files": raw_files,
        "publication": {
            "eligible": False,
            "reasons": publication_reasons_for_thermal(thermal_state, paired=False),
        },
        "claim_boundary": {
            "proves": (
                "shipping Bun AppLinkSession plus HostOwnedHelloSession persistent echo RTT "
                f"for cache_state={args.cache_state} on this Linux machine"
            ),
            "does_not_prove": (
                "window/renderer latency, full keld-dev startup, or direct cross-session "
                "fresh-vs-warm / Rust-vs-Bun causal ratios"
            ),
        },
    }
    manifest_path = out_dir / (
        f"{date}.kel90-linux-bun-product-client.{args.cache_state}.manifest.raw.json"
    )
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"manifest": str(manifest_path), "tiers": tiers}, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Bun IPC campaign failed: {error}", file=sys.stderr)
        raise SystemExit(2)
