#!/usr/bin/env python3
"""Run a same-machine paired Rust-floor vs shipping-Bun KIPC RTT campaign."""

from __future__ import annotations

import argparse
import bisect
import hashlib
import json
import math
import random
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

import campaign as bun_campaign

KELD_SHA = bun_campaign.KELD_SHA
SESSIONS = 20
SCORED_CALLS = 100_000
RUST_REQUESTED_CALLS = SCORED_CALLS + 1
BOOTSTRAP_RESAMPLES = 2_000
BOOTSTRAP_SEED = 20260919
PILOT_P99_STOP_NS = 300_000

BUN_ROOT = Path(__file__).resolve().parent
REPO = BUN_ROOT.parents[2]
RUST_ROOT = BUN_ROOT.parent / "kipc-rust-echo"
BUN_RUNNER = BUN_ROOT / "target/release/kel90-linux-bun-kipc-runner"
RUST_SERVER = RUST_ROOT / "target/release/kel90-linux-echo-server"
RUST_CLIENT = RUST_ROOT / "target/release/kel90-linux-echo-client"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def percentile(sorted_values: list[float | int], q: float):
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
    count = len(sessions)
    total = sum(len(values) for values in sessions)
    rank = math.ceil(q * total)
    samples: list[int] = []
    for _ in range(BOOTSTRAP_RESAMPLES):
        weights = [0] * count
        for _ in range(count):
            weights[rng.randrange(count)] += 1
        samples.append(weighted_kth(sessions, weights, rank))
    samples.sort()
    return [percentile(samples, 0.025), percentile(samples, 0.975)]


def paired_bootstrap(
    rust_sessions: list[list[int]],
    bun_sessions: list[list[int]],
    q: float,
) -> dict:
    if len(rust_sessions) != len(bun_sessions):
        raise ValueError("paired arms must have the same number of rounds")
    rng = random.Random(BOOTSTRAP_SEED)
    count = len(rust_sessions)
    rust_total = sum(len(values) for values in rust_sessions)
    bun_total = sum(len(values) for values in bun_sessions)
    if rust_total != bun_total:
        raise ValueError("paired arms must have the same scored sample count")
    rank = math.ceil(q * rust_total)
    ratios: list[float] = []
    deltas: list[int] = []
    for _ in range(BOOTSTRAP_RESAMPLES):
        weights = [0] * count
        for _ in range(count):
            weights[rng.randrange(count)] += 1
        rust_value = weighted_kth(rust_sessions, weights, rank)
        bun_value = weighted_kth(bun_sessions, weights, rank)
        if rust_value <= 0:
            raise ValueError("Rust bootstrap percentile must be positive")
        ratios.append(bun_value / rust_value)
        deltas.append(bun_value - rust_value)
    ratios.sort()
    deltas.sort()
    return {
        "ratio_ci95": [
            round(percentile(ratios, 0.025), 6),
            round(percentile(ratios, 0.975), 6),
        ],
        "delta_ns_ci95": [
            int(percentile(deltas, 0.025)),
            int(percentile(deltas, 0.975)),
        ],
    }


def wait_for_file(path: Path, timeout: float = 5.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.is_file() and path.stat().st_size > 0:
            return
        time.sleep(0.005)
    raise RuntimeError(f"timed out waiting for {path}")


def rust_paths(tag: str) -> tuple[Path, Path, Path, Path]:
    safe = "".join(ch for ch in tag if ch.isalnum() or ch in "-_")[:48]
    temp_dir = Path(tempfile.mkdtemp(prefix=f"k90p-{safe}-"))
    return (
        temp_dir,
        temp_dir / "session.sock",
        temp_dir / "app-link.txt",
        temp_dir / "server.err",
    )


def run_rust_case(out_path: Path, tier: str, tag: str) -> subprocess.CompletedProcess[str]:
    if out_path.exists():
        raise RuntimeError(f"refusing to overwrite {out_path}")
    temp_dir, socket_path, link_path, err_path = rust_paths(tag)
    with err_path.open("w", encoding="utf-8") as error_file:
        server = subprocess.Popen(
            [str(RUST_SERVER), str(socket_path), str(link_path)],
            cwd=RUST_ROOT,
            text=True,
            stdout=subprocess.DEVNULL,
            stderr=error_file,
        )
    try:
        wait_for_file(link_path)
        completed = subprocess.run(
            [
                str(RUST_CLIENT),
                str(link_path),
                tier,
                str(RUST_REQUESTED_CALLS),
                str(out_path),
            ],
            cwd=RUST_ROOT,
            text=True,
            capture_output=True,
            timeout=120,
        )
        try:
            server_rc = server.wait(timeout=15)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait(timeout=5)
            raise RuntimeError(f"Rust server did not exit for {tag}")
        if completed.returncode != 0 or server_rc != 0 or not out_path.is_file():
            detail = err_path.read_text(encoding="utf-8", errors="replace")
            raise RuntimeError(
                f"Rust session failed tag={tag} client={completed.returncode} "
                f"server={server_rc}\nstdout={completed.stdout}\nstderr={completed.stderr}\n"
                f"server_stderr={detail}"
            )
        return completed
    finally:
        if server.poll() is None:
            server.kill()
            server.wait(timeout=5)
        shutil.rmtree(temp_dir, ignore_errors=True)


def rust_negative_control(out_dir: Path) -> dict:
    out_path = out_dir / "rust-bad-token.must-not-exist.json"
    out_path.unlink(missing_ok=True)
    temp_dir, socket_path, link_path, err_path = rust_paths("negative")
    with err_path.open("w", encoding="utf-8") as error_file:
        server = subprocess.Popen(
            [str(RUST_SERVER), str(socket_path), str(link_path)],
            cwd=RUST_ROOT,
            text=True,
            stdout=subprocess.DEVNULL,
            stderr=error_file,
        )
    try:
        wait_for_file(link_path)
        client = subprocess.run(
            [
                str(RUST_CLIENT),
                str(link_path),
                "small",
                "101",
                str(out_path),
                "--bad-token",
            ],
            cwd=RUST_ROOT,
            text=True,
            capture_output=True,
            timeout=30,
        )
        server_rc = server.wait(timeout=15)
        server_error = err_path.read_text(encoding="utf-8", errors="replace")
        passed = (
            client.returncode == 0
            and server_rc != 0
            and "KELD-IPC-007" in server_error
            and not out_path.exists()
        )
        if not passed:
            raise RuntimeError(
                f"Rust bad-token control failed client={client.returncode} server={server_rc} "
                f"server_stderr={server_error}"
            )
        return {
            "passed": True,
            "client_returncode": client.returncode,
            "server_returncode": server_rc,
            "server_marker": "KELD-IPC-007",
            "no_result_file": True,
        }
    finally:
        if server.poll() is None:
            server.kill()
            server.wait(timeout=5)
        shutil.rmtree(temp_dir, ignore_errors=True)
        out_path.unlink(missing_ok=True)


def load_rust(path: Path, tier: str) -> dict:
    raw = path.read_bytes()
    if raw.count(b"\n") != 0:
        raise RuntimeError(f"{path} is not compact JSON")
    doc = json.loads(raw)
    expected_payload = 6 if tier == "small" else 1024
    checks = {
        "fixture": doc.get("fixture") == "kel90-linux-kipc-rust-echo",
        "keld_sha": doc.get("keld_sha") == KELD_SHA,
        "tier": doc.get("tier") == tier,
        "payload": doc.get("payload_bytes") == expected_payload,
        "calls_requested": doc.get("calls_requested") == RUST_REQUESTED_CALLS,
        "calls_timed": doc.get("calls_timed") == SCORED_CALLS,
        "deltas": len(doc.get("deltas_ns", [])) == SCORED_CALLS,
        "handshake_excluded": doc.get("handshake_included_in_deltas") is False,
    }
    failed = [name for name, passed in checks.items() if not passed]
    if failed:
        raise RuntimeError(f"{path}: Rust invariant failures {failed}")
    return doc


def load_bun(path: Path, tier: str) -> dict:
    raw = path.read_bytes()
    if raw.count(b"\n") != 0:
        raise RuntimeError(f"{path} is not compact JSON")
    doc = json.loads(raw)
    expected_payload = 6 if tier == "small" else 1024
    checks = {
        "fixture": doc.get("fixture") == "kel90-linux-bun-kipc-echo",
        "keld_sha": doc.get("keld_sha") == KELD_SHA,
        "cache_state": doc.get("cache_state") == "fresh-process",
        "tier": doc.get("tier") == tier,
        "payload": doc.get("payload_bytes") == expected_payload,
        "calls_requested": doc.get("calls_requested") == SCORED_CALLS,
        "calls_timed": doc.get("calls_timed") == SCORED_CALLS,
        "deltas": len(doc.get("deltas_ns", [])) == SCORED_CALLS,
        "warmup": doc.get("warmup_calls") == 0,
        "handshake_excluded": doc.get("handshake_included_in_deltas") is False,
    }
    failed = [name for name, passed in checks.items() if not passed]
    if failed:
        raise RuntimeError(f"{path}: Bun invariant failures {failed}")
    return doc


def arm_statistics(documents: list[dict]) -> dict:
    sessions = [sorted(document["deltas_ns"]) for document in documents]
    pooled = sorted(value for values in sessions for value in values)
    handshakes = sorted(int(document["handshake_ns"]) for document in documents)
    return {
        "sessions": len(sessions),
        "calls_timed_per_session": SCORED_CALLS,
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
    }


def run_bun_case(out_path: Path, tier: str) -> subprocess.CompletedProcess[str]:
    return bun_campaign.run_case(
        out_path,
        tier,
        SCORED_CALLS,
        "none",
        "fresh-process",
    )


def run_arm(arm: str, out_path: Path, tier: str, tag: str) -> None:
    if arm == "rust":
        run_rust_case(out_path, tier, tag)
        load_rust(out_path, tier)
    elif arm == "bun":
        run_bun_case(out_path, tier)
        load_bun(out_path, tier)
    else:
        raise ValueError(f"unknown arm {arm}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", required=True, type=Path)
    args = parser.parse_args()
    out_dir = args.out_dir.resolve()
    try:
        out_dir.relative_to(REPO.resolve())
    except ValueError:
        pass
    else:
        raise RuntimeError("paired campaign output must be outside the repository")
    if out_dir.exists():
        raise RuntimeError(f"refusing to overwrite existing output directory {out_dir}")
    if bun_campaign.checked(["git", "-C", str(REPO), "status", "--porcelain"]):
        raise RuntimeError("keld-benches worktree must be clean before timing")

    bench_sha = bun_campaign.checked(["git", "-C", str(REPO), "rev-parse", "HEAD"])
    if bun_campaign.checked(["git", "-C", str(REPO), "rev-parse", "--verify", "HEAD"]) != bench_sha:
        raise RuntimeError("could not resolve benchmark commit")

    for relative, expected in bun_campaign.PRODUCT_HASHES.items():
        actual = sha256(BUN_ROOT / relative)
        if actual != expected:
            raise RuntimeError(f"shipping Bun client drift for {relative}: {actual} != {expected}")

    subprocess.run(["cargo", "build", "--release", "--locked"], cwd=BUN_ROOT, check=True)
    subprocess.run(["cargo", "build", "--release", "--locked"], cwd=RUST_ROOT, check=True)
    for binary in (BUN_RUNNER, RUST_SERVER, RUST_CLIENT):
        if not binary.is_file():
            raise RuntimeError(f"missing release artifact {binary}")

    out_dir.mkdir(parents=True)
    controls_dir = out_dir / "controls"
    controls_dir.mkdir()
    rust_control = rust_negative_control(controls_dir)
    bun_controls = {}
    for fault in ("bad-token", "wrong-response"):
        completed = bun_campaign.run_case(
            controls_dir / f"bun-{fault}.must-not-exist.json",
            "small",
            100,
            fault,
            "fresh-process",
        )
        bun_controls[fault] = {
            "passed": True,
            "runner_returncode": completed.returncode,
            "failure_marker_seen": bun_campaign.FAILURE_MARKER in completed.stdout,
            "no_result_file": True,
        }

    pilots_dir = out_dir / "pilots"
    pilots_dir.mkdir()
    pilot = {}
    for tier_index, tier in enumerate(("small", "representative")):
        pilot[tier] = {}
        arm_order = ("rust", "bun") if tier_index == 0 else ("bun", "rust")
        for arm in arm_order:
            path = pilots_dir / f"pilot-{tier}-{arm}.raw.json"
            run_arm(arm, path, tier, f"pilot-{tier}-{arm}")
            doc = load_rust(path, tier) if arm == "rust" else load_bun(path, tier)
            values = sorted(doc["deltas_ns"])
            p99 = percentile(values, 0.99)
            if p99 > PILOT_P99_STOP_NS:
                raise RuntimeError(f"{tier}/{arm} pilot p99 {p99} ns exceeds sanity stop")
            pilot[tier][arm] = {"p99_ns": p99, "sha256": sha256(path)}

    campaign_dir = out_dir / "campaign"
    campaign_dir.mkdir()
    started = datetime.now(timezone.utc)
    date = started.date().isoformat()

    documents: dict[str, dict[str, list[dict]]] = {
        "small": {"rust": [], "bun": []},
        "representative": {"rust": [], "bun": []},
    }
    raw_files = []
    schedule = []

    for round_number in range(1, SESSIONS + 1):
        tier_order = (
            ("small", "representative")
            if round_number % 2 == 1
            else ("representative", "small")
        )
        for tier in tier_order:
            tier_offset = 0 if tier == "small" else 1
            arm_order = (
                ("rust", "bun")
                if (round_number + tier_offset) % 2 == 1
                else ("bun", "rust")
            )
            schedule.append(
                {"round": round_number, "tier": tier, "arm_order": list(arm_order)}
            )
            for arm in arm_order:
                name = (
                    f"{date}.kel90-linux-paired-{arm}-100k-{tier}."
                    f"fresh-process.r{round_number:02d}.raw.json"
                )
                path = campaign_dir / name
                run_arm(arm, path, tier, f"r{round_number:02d}-{tier}-{arm}")
                doc = load_rust(path, tier) if arm == "rust" else load_bun(path, tier)
                documents[tier][arm].append(doc)
                raw_files.append(
                    {
                        "path": f"linux/bench/results/ipc-rtt/{name}",
                        "sha256": sha256(path),
                        "bytes": path.stat().st_size,
                        "round": round_number,
                        "tier": tier,
                        "arm": arm,
                    }
                )
        print(f"completed paired round {round_number:02d}", flush=True)

    finished = datetime.now(timezone.utc)
    raw_files.sort(key=lambda item: item["path"])
    digest_chain = hashlib.sha256(
        b"".join(bytes.fromhex(item["sha256"]) for item in raw_files)
    ).hexdigest()

    tiers = {}
    for tier in ("small", "representative"):
        rust_docs = documents[tier]["rust"]
        bun_docs = documents[tier]["bun"]
        rust_stats = arm_statistics(rust_docs)
        bun_stats = arm_statistics(bun_docs)
        rust_pooled = sorted(value for doc in rust_docs for value in doc["deltas_ns"])
        bun_pooled = sorted(value for doc in bun_docs for value in doc["deltas_ns"])
        rust_p99 = percentile(rust_pooled, 0.99)
        bun_p99 = percentile(bun_pooled, 0.99)
        rust_p50 = percentile(rust_pooled, 0.50)
        bun_p50 = percentile(bun_pooled, 0.50)
        rust_sessions = [sorted(doc["deltas_ns"]) for doc in rust_docs]
        bun_sessions = [sorted(doc["deltas_ns"]) for doc in bun_docs]
        paired_p99 = paired_bootstrap(rust_sessions, bun_sessions, 0.99)
        paired_p50 = paired_bootstrap(rust_sessions, bun_sessions, 0.50)
        tiers[tier] = {
            "payload_bytes": 6 if tier == "small" else 1024,
            "rust_library_floor": rust_stats,
            "bun_product_client": bun_stats,
            "paired_comparison": {
                "ratio_definition": "Bun product-client percentile / Rust library-floor percentile",
                "central_p50_ratio": round(bun_p50 / rust_p50, 6),
                "central_p99_ratio": round(bun_p99 / rust_p99, 6),
                "central_p50_delta_ns": bun_p50 - rust_p50,
                "central_p99_delta_ns": bun_p99 - rust_p99,
                "p50": paired_p50,
                "p99": paired_p99,
                "bootstrap_unit": "paired round; resample identical round indices for both arms",
            },
        }

    provenance_files = [
        BUN_ROOT / "campaign.py",
        Path(__file__),
        BUN_ROOT / "src/main.ts",
        BUN_ROOT / "src/runner.rs",
        BUN_ROOT / "src/kipc.ts",
        BUN_ROOT / "src/kipc-transport.ts",
        RUST_ROOT / "src/client.rs",
        RUST_ROOT / "src/server.rs",
        RUST_ROOT / "Cargo.toml",
    ]
    manifest = {
        "format": "kel90-linux-bun-rust-paired-ipc-rtt/v1",
        "classification": "diagnostic-paired-product-vs-library-arm",
        "campaign": {
            "cache_state": "fresh-process",
            "paired_rounds": SESSIONS,
            "scored_calls_per_arm_per_round": SCORED_CALLS,
            "rust_requested_calls_per_round": RUST_REQUESTED_CALLS,
            "rust_request_note": (
                "Rust call 1 contains HELLO plus first CALL and is excluded; requesting "
                "100001 yields exactly 100000 scored post-handshake echo_invoke calls"
            ),
            "started_utc": started.isoformat().replace("+00:00", "Z"),
            "finished_utc": finished.isoformat().replace("+00:00", "Z"),
            "order_policy": (
                "tier order alternates by round; arm order alternates within tier/round "
                "so each arm runs first equally often"
            ),
            "schedule": schedule,
            "pilot_stop_p99_ns": PILOT_P99_STOP_NS,
            "pilot": pilot,
            "negative_controls": {
                "rust_bad_token": rust_control,
                "bun": bun_controls,
            },
        },
        "provenance": {
            "bench_sha": bench_sha,
            "keld_sha": KELD_SHA,
            "bun_runner_artifact_sha256": sha256(BUN_RUNNER),
            "rust_server_artifact_sha256": sha256(RUST_SERVER),
            "rust_client_artifact_sha256": sha256(RUST_CLIENT),
            "source_sha256": {
                str(path.relative_to(REPO)): sha256(path) for path in provenance_files
            },
            "raw_corpus_digest_chain_sha256": digest_chain,
        },
        "environment": bun_campaign.environment_metadata(),
        "statistics_method": {
            "percentile": "nearest-rank ceil(p*n), one-indexed",
            "per_arm_bootstrap": (
                "sample 20 whole session blocks with replacement; pool selected blocks; "
                "recompute nearest-rank percentile"
            ),
            "paired_bootstrap": (
                "sample 20 round indices with replacement and apply identical weights to "
                "Rust and Bun arms before recomputing percentile ratio/delta"
            ),
            "resamples": BOOTSTRAP_RESAMPLES,
            "seed": BOOTSTRAP_SEED,
            "rng": "Python random.Random (MT19937)",
        },
        "tiers": tiers,
        "raw_files": raw_files,
        "publication": {
            "eligible": False,
            "reasons": [
                "THERMAL_STATE_UNVERIFIED",
                "RESULT_V2_SESSION_BLOCK_SCHEMA_GAP",
                "PRODUCT_CLIENT_VS_LIBRARY_FLOOR_DIAGNOSTIC",
            ],
        },
        "claim_boundary": {
            "proves": (
                "same-machine balanced paired fresh-process RTT comparison between the "
                "shipping Bun AppLinkSession/HostOwnedHelloSession slice and the direct "
                "Rust keld-ipc library floor at one Keld SHA and matched payload/sample counts"
            ),
            "does_not_prove": (
                "pure language/runtime tax, identical host orchestration cost, renderer/window "
                "latency, full keld-dev startup, or causal attribution of the entire ratio to Bun"
            ),
        },
    }
    manifest_path = out_dir / (
        f"{date}.kel90-linux-bun-rust-paired.fresh-process.manifest.raw.json"
    )
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"manifest": str(manifest_path), "tiers": tiers}, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"paired Bun/Rust IPC campaign failed: {error}", file=sys.stderr)
        raise SystemExit(2)
