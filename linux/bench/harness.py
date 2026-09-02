#!/usr/bin/env python3
"""Linux implementation of the keld-benches metric-runner contract."""

from __future__ import annotations

import hashlib
import http.client
import json
import math
import os
import pathlib
import platform
import random
import re
import selectors
import signal
import statistics
import subprocess
import threading
import time
import urllib.parse
from dataclasses import dataclass
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[2]
REGISTRY_PATH = ROOT / "schema" / "metrics.v1.json"
SCHEMA_PATH = ROOT / "schema" / "result.v1.schema.json"
HARNESS_PATH = ROOT / "linux" / "bench" / "run.py"
MODULE_PATH = ROOT / "linux" / "bench" / "harness.py"
TEMPLATE_PATH = ROOT / "linux" / "keld" / "hello" / "index.html"
FIXTURE_PATH = "linux/keld/hello"
IMPLEMENTED_METRICS = ("PAINT-OPPORTUNITY", "DISK")
SUPPORTED_PAINT_STATES = ("fresh-process", "warm-cache")
NONCE_PATTERN = re.compile(r"^[0-9a-f]{32}$")
LABEL_PATTERN = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
ONE_PIXEL_GIF = bytes.fromhex(
    "47494638396101000100800000000000ffffff21f90401000000002c00000000010001000002024401003b"
)


class HarnessError(RuntimeError):
    """A fail-closed benchmark setup, protocol, or measurement error."""


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_text(arguments: list[str], *, cwd: pathlib.Path | None = None) -> str:
    try:
        completed = subprocess.run(
            arguments,
            cwd=cwd,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise HarnessError(f"command failed: {arguments[0]}: {error}") from error
    return completed.stdout.strip()


def load_registry() -> dict[str, Any]:
    registry = json.loads(REGISTRY_PATH.read_text(encoding="utf-8"))
    known = {metric["id"] for metric in registry["metrics"]}
    missing = set(IMPLEMENTED_METRICS) - known
    if missing:
        raise HarnessError(f"implemented metric is absent from registry: {sorted(missing)}")
    return registry


def metric_contract(registry: dict[str, Any], metric_id: str) -> dict[str, Any]:
    matches = [metric for metric in registry["metrics"] if metric["id"] == metric_id]
    if len(matches) != 1:
        raise HarnessError(f"registry did not resolve exactly one {metric_id} contract")
    return matches[0]


def render_payload(template: bytes, port: int, nonce: str) -> bytes:
    if not (0 < port <= 65535) or not NONCE_PATTERN.fullmatch(nonce):
        raise HarnessError("payload renderer received an invalid port or nonce")
    rendered = template.replace(b"__KELD_BENCH_PORT__", str(port).encode("ascii"))
    rendered = rendered.replace(b"__KELD_BENCH_NONCE__", nonce.encode("ascii"))
    if b"__KELD_BENCH_" in rendered:
        raise HarnessError("payload contains an unresolved benchmark placeholder")
    if f"http://127.0.0.1:{port}".encode("ascii") not in rendered:
        raise HarnessError("payload did not bind the listener port")
    if nonce.encode("ascii") not in rendered:
        raise HarnessError("payload did not bind the launch nonce")
    return rendered


@dataclass
class BeaconSnapshot:
    accepted_ns: int | None
    page_requests: int
    beacon_requests: int
    rejections: tuple[str, ...]
    protocol_error: str | None


class _BeaconState:
    def __init__(self, nonce: str, port: int, payload: bytes) -> None:
        self.nonce = nonce
        self.port = port
        self.payload = payload
        self.accepted = threading.Event()
        self.lock = threading.Lock()
        self.accepted_ns: int | None = None
        self.page_requests = 0
        self.beacon_requests = 0
        self.rejections: list[str] = []
        self.protocol_error: str | None = None

    def snapshot(self) -> BeaconSnapshot:
        with self.lock:
            return BeaconSnapshot(
                accepted_ns=self.accepted_ns,
                page_requests=self.page_requests,
                beacon_requests=self.beacon_requests,
                rejections=tuple(self.rejections),
                protocol_error=self.protocol_error,
            )


class _BeaconHandler(BaseHTTPRequestHandler):
    server: "_BeaconHttpServer"

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def _reply(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def _reject(self, reason: str, status: int = 422) -> None:
        with self.server.state.lock:
            self.server.state.rejections.append(reason)
        self._reply(status, b"rejected\n", "text/plain; charset=utf-8")

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        state = self.server.state
        expected_host = f"127.0.0.1:{state.port}"
        if self.headers.get("Host") != expected_host:
            self._reject("host_mismatch", 400)
            return

        parsed = urllib.parse.urlsplit(self.path)
        page_path = f"/run/{state.nonce}/index.html"
        beacon_path = f"/run/{state.nonce}/paint.gif"
        if parsed.path == page_path and not parsed.query:
            with state.lock:
                state.page_requests += 1
            self._reply(200, state.payload, "text/html; charset=utf-8")
            return
        if not parsed.path.endswith("/paint.gif"):
            self._reply(404, b"not found\n", "text/plain; charset=utf-8")
            return

        with state.lock:
            state.beacon_requests += 1
        if parsed.path != beacon_path:
            self._reject("path_nonce_mismatch", 404)
            return
        try:
            query = urllib.parse.parse_qs(
                parsed.query, keep_blank_values=True, strict_parsing=True
            )
        except ValueError:
            self._reject("malformed_query", 400)
            return
        expected = {
            "nonce": [state.nonce],
            "phase": ["double-raf"],
            "visibility": ["visible"],
            "focus": ["1"],
        }
        if query != expected:
            if query.get("nonce") != [state.nonce]:
                reason = "query_nonce_mismatch"
            elif query.get("phase") != ["double-raf"]:
                reason = "wrong_phase"
            elif query.get("visibility") != ["visible"]:
                reason = "document_not_visible"
            elif query.get("focus") != ["1"]:
                reason = "document_not_focused"
            else:
                reason = "unexpected_query"
            self._reject(reason)
            return

        with state.lock:
            if state.accepted_ns is not None:
                state.protocol_error = "duplicate_beacon"
                duplicate = True
            else:
                state.accepted_ns = time.monotonic_ns()
                duplicate = False
        if duplicate:
            self._reply(409, b"duplicate\n", "text/plain; charset=utf-8")
            return
        state.accepted.set()
        self._reply(200, ONE_PIXEL_GIF, "image/gif")


class _BeaconHttpServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(self, address: tuple[str, int], state: _BeaconState) -> None:
        self.state = state
        super().__init__(address, _BeaconHandler)


class BeaconServer:
    """Nonce-bound loopback page + paint-beacon server."""

    def __init__(self, template: bytes, nonce: str | None = None) -> None:
        launch_nonce = nonce or os.urandom(16).hex()
        if not NONCE_PATTERN.fullmatch(launch_nonce):
            raise HarnessError("beacon nonce must be 32 lowercase hexadecimal characters")
        placeholder_state = _BeaconState(launch_nonce, 1, b"")
        self._server = _BeaconHttpServer(("127.0.0.1", 0), placeholder_state)
        port = int(self._server.server_address[1])
        self._server.state.port = port
        self._server.state.payload = render_payload(template, port, launch_nonce)
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)

    @property
    def nonce(self) -> str:
        return self._server.state.nonce

    @property
    def port(self) -> int:
        return self._server.state.port

    @property
    def page_url(self) -> str:
        return f"http://127.0.0.1:{self.port}/run/{self.nonce}/index.html"

    @property
    def payload(self) -> bytes:
        return self._server.state.payload

    def start(self) -> None:
        self._thread.start()

    def wait_for_beacon(self, timeout_seconds: float) -> bool:
        return self._server.state.accepted.wait(timeout_seconds)

    def snapshot(self) -> BeaconSnapshot:
        return self._server.state.snapshot()

    def close(self) -> None:
        self._server.shutdown()
        self._server.server_close()
        self._thread.join(timeout=2)
        if self._thread.is_alive():
            raise HarnessError("loopback beacon server did not stop")


@dataclass(frozen=True)
class ProcessIdentity:
    pid: int
    process_group: int
    start_ticks: int


def _proc_identity(pid: int) -> ProcessIdentity | None:
    try:
        raw = pathlib.Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
    except (FileNotFoundError, ProcessLookupError, PermissionError):
        return None
    if not raw:
        return None
    close = raw.rfind(")")
    if close < 0:
        return None
    fields = raw[close + 2 :].split()
    if len(fields) < 20:
        return None
    if fields[0] == "Z":
        return None
    return ProcessIdentity(pid=pid, process_group=int(fields[2]), start_ticks=int(fields[19]))


def _process_group_members(process_group: int) -> list[ProcessIdentity]:
    members: list[ProcessIdentity] = []
    for entry in pathlib.Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        identity = _proc_identity(int(entry.name))
        if identity is not None and identity.process_group == process_group:
            members.append(identity)
    return members


class OwnedProcess:
    """Linux process-group owner anchored by the leader's kernel generation."""

    def __init__(self, process: subprocess.Popen[bytes]) -> None:
        identity = _proc_identity(process.pid)
        if identity is None or identity.process_group != process.pid:
            raise HarnessError("spawned benchmark process did not own a fresh process group")
        try:
            self._leader_pidfd = os.pidfd_open(process.pid)
        except (AttributeError, OSError) as error:
            raise HarnessError(f"Linux pidfd_open is required for generation-bound cleanup: {error}") from error
        self.process = process
        self.identity = identity

    def _signal_group(self, requested_signal: int) -> None:
        current = _proc_identity(self.identity.pid)
        if current is not None and current.start_ticks != self.identity.start_ticks:
            raise HarnessError("benchmark leader PID was reused; refusing to signal its process group")
        try:
            os.killpg(self.identity.process_group, requested_signal)
        except ProcessLookupError:
            return

    def cleanup(self) -> None:
        try:
            self._signal_group(signal.SIGTERM)
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self._signal_group(signal.SIGKILL)
                try:
                    self.process.wait(timeout=2)
                except subprocess.TimeoutExpired as error:
                    raise HarnessError("benchmark leader survived SIGKILL") from error

            remaining = _process_group_members(self.identity.process_group)
            if remaining:
                self._signal_group(signal.SIGKILL)
                selector = selectors.DefaultSelector()
                descriptors: list[int] = []
                try:
                    for member in remaining:
                        try:
                            descriptor = os.pidfd_open(member.pid)
                        except ProcessLookupError:
                            continue
                        descriptors.append(descriptor)
                        selector.register(descriptor, selectors.EVENT_READ)
                    deadline = time.monotonic() + 2
                    while selector.get_map():
                        timeout = deadline - time.monotonic()
                        if timeout <= 0:
                            break
                        for key, _mask in selector.select(timeout):
                            selector.unregister(key.fd)
                finally:
                    selector.close()
                    for descriptor in descriptors:
                        os.close(descriptor)
            survivors = _process_group_members(self.identity.process_group)
            if survivors:
                raise HarnessError(
                    "generation-bound cleanup left process-group members: "
                    + ",".join(str(member.pid) for member in survivors)
                )
        finally:
            os.close(self._leader_pidfd)


def _paint_attempt(artifact: pathlib.Path, template: bytes, run_number: int, timeout: float) -> dict[str, Any]:
    server = BeaconServer(template)
    server.start()
    environment = os.environ.copy()
    environment["KELD_BENCH_URL"] = server.page_url
    started_ns = time.monotonic_ns()
    process: subprocess.Popen[bytes] | None = None
    owner: OwnedProcess | None = None
    exited_before_beacon = False
    cleanup_bound = False
    reject_reason: str | None = None
    value: float | None = None
    try:
        process = subprocess.Popen(
            [str(artifact), "--hello", "--title", "Keld Linux benchmark"],
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        owner = OwnedProcess(process)
        deadline = time.monotonic() + timeout
        accepted = False
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            if server.wait_for_beacon(min(remaining, 0.1)):
                accepted = True
                break
            if process.poll() is not None:
                exited_before_beacon = True
                break
        snapshot = server.snapshot()
        if accepted and snapshot.accepted_ns is not None and snapshot.protocol_error is None:
            value = round((snapshot.accepted_ns - started_ns) / 1_000_000, 3)
        elif snapshot.protocol_error is not None:
            reject_reason = snapshot.protocol_error
        elif exited_before_beacon:
            reject_reason = f"process_exited_{process.returncode}"
        elif snapshot.rejections:
            reject_reason = snapshot.rejections[-1]
        else:
            reject_reason = "beacon_timeout"
    finally:
        try:
            if owner is not None:
                owner.cleanup()
                cleanup_bound = True
            elif process is not None and process.poll() is None:
                process.kill()
                process.wait(timeout=2)
        finally:
            server.close()

    snapshot = server.snapshot()
    return {
        "run": run_number,
        "value": value,
        "valid": value is not None,
        "reject_reason": reject_reason,
        "diagnostics": {
            "page_requests": snapshot.page_requests,
            "beacon_requests": snapshot.beacon_requests,
            "process_exit_before_beacon": exited_before_beacon,
            "cleanup_generation_bound": cleanup_bound,
        },
    }


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    return ordered[max(0, math.ceil(fraction * len(ordered)) - 1)]


def summarize(samples: list[dict[str, Any]]) -> dict[str, Any]:
    values = [sample["value"] for sample in samples if sample["valid"]]
    if not values:
        return {"valid_samples": 0, "median": None, "min": None, "max": None}
    summary: dict[str, Any] = {
        "valid_samples": len(values),
        "median": statistics.median(values),
        "min": min(values),
        "max": max(values),
    }
    if len(values) >= 2:
        summary["p90"] = percentile(values, 0.90)
    if len(values) >= 100:
        summary["p99"] = percentile(values, 0.99)
    if len(values) >= 2:
        generator = random.Random(hashlib.sha256(repr(values).encode("ascii")).digest())
        medians = sorted(
            statistics.median(generator.choices(values, k=len(values)))
            for _ in range(10_000)
        )
        summary["bootstrap_ci95"] = {
            "lower": percentile(medians, 0.025),
            "upper": percentile(medians, 0.975),
            "resamples": 10_000,
        }
    return summary


def _read_artifacts(artifact_dir: pathlib.Path) -> tuple[dict[str, Any], pathlib.Path, pathlib.Path]:
    provenance_path = artifact_dir / "provenance.json"
    try:
        provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise HarnessError(f"could not read artifact provenance: {error}") from error
    if provenance.get("schema_version") != 1:
        raise HarnessError("unsupported artifact provenance schema")
    if provenance.get("source_repository") != "github.com/gyldlab/keld":
        raise HarnessError("artifact provenance names a non-canonical Keld source")
    if provenance.get("recipe_repository") != "github.com/gyldlab/keld-benches":
        raise HarnessError("artifact provenance names a non-canonical benchmark recipe")
    for field in ("source_git_sha", "recipe_commit"):
        value = provenance.get(field)
        if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{40}", value):
            raise HarnessError(f"artifact provenance has an invalid {field}")
    artifacts = provenance.get("artifacts", {})
    product = artifact_dir / "keld-host-product"
    adapter = artifact_dir / "keld-host-bench"
    for name, path in (("product", product), ("benchmark_adapter", adapter)):
        record = artifacts.get(name, {})
        if path.is_symlink() or not path.is_file() or not os.access(path, os.X_OK):
            raise HarnessError(f"artifact is missing or not executable: {path.name}")
        if record.get("basename") != path.name or record.get("sha256") != sha256_file(path):
            raise HarnessError(f"artifact provenance mismatch: {path.name}")
        if record.get("bytes") != path.stat().st_size:
            raise HarnessError(f"artifact size provenance mismatch: {path.name}")
    return provenance, product, adapter


def _power_state() -> tuple[bool, bool, str]:
    supplies = pathlib.Path("/sys/class/power_supply")
    online: list[bool] = []
    batteries = 0
    if supplies.is_dir():
        for entry in supplies.iterdir():
            kind_path = entry / "type"
            kind = kind_path.read_text(encoding="ascii").strip() if kind_path.is_file() else ""
            if kind == "Battery":
                batteries += 1
            online_path = entry / "online"
            if kind in {"Mains", "USB", "USB_C"} and online_path.is_file():
                online.append(online_path.read_text(encoding="ascii").strip() == "1")
    if online:
        ac_power = any(online)
        evidence = "sysfs-power-supply"
    elif batteries == 0:
        ac_power = True
        evidence = "mains-only-no-battery"
    else:
        raise HarnessError("could not determine AC power from Linux power-supply state")

    low_power: bool | None = None
    try:
        profile = run_text(["powerprofilesctl", "get"])
        low_power = profile == "power-saver"
        evidence += f";power-profile={profile}"
    except HarnessError:
        profile_path = pathlib.Path("/sys/firmware/acpi/platform_profile")
        if profile_path.is_file():
            profile = profile_path.read_text(encoding="ascii").strip()
            low_power = profile in {"low-power", "quiet"}
            evidence += f";platform-profile={profile}"
    if low_power is None:
        raise HarnessError("could not determine Linux low-power mode")
    return ac_power, low_power, evidence


def _environment(provenance: dict[str, Any], metric_id: str) -> tuple[dict[str, Any], str]:
    if metric_id == "PAINT-OPPORTUNITY" and not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        raise HarnessError("PAINT-OPPORTUNITY requires a reachable X11 or Wayland display")
    os_release: dict[str, str] = {}
    for line in pathlib.Path("/etc/os-release").read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            os_release[key] = value.strip().strip('"')
    cpu = "unknown"
    for line in pathlib.Path("/proc/cpuinfo").read_text(encoding="utf-8").splitlines():
        if line.lower().startswith("model name") and ":" in line:
            cpu = line.split(":", 1)[1].strip()
            break
    ram_bytes = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
    ac_power, low_power, power_evidence = _power_state()
    engine_version = run_text(["pkg-config", "--modversion", "webkit2gtk-4.1"])
    display = ";".join(
        part
        for part in (
            f"session={os.environ.get('XDG_SESSION_TYPE', 'unknown')}",
            f"desktop={os.environ.get('XDG_CURRENT_DESKTOP', 'unknown')}",
            f"display={os.environ.get('DISPLAY', 'unset')}",
            f"wayland={os.environ.get('WAYLAND_DISPLAY', 'unset')}",
        )
        if part
    )
    toolchains = provenance.get("toolchains", {})
    environment = {
        "os": {
            "name": "linux",
            "version": os_release.get("PRETTY_NAME", platform.system()),
            "build": platform.release(),
        },
        "hardware": {
            "cpu": cpu,
            "arch": platform.machine(),
            "ram_bytes": ram_bytes,
        },
        "power": {
            "ac_power": ac_power,
            "low_power_mode": low_power,
            "thermal_state": "unverified",
        },
        "engine": {"name": "WebKitGTK", "version": engine_version},
        "display": display,
        "toolchains": [
            {"name": "rustc", "version": str(toolchains.get("rustc", "unknown"))},
            {"name": "cargo", "version": str(toolchains.get("cargo", "unknown"))},
        ],
    }
    return environment, power_evidence


def _git_state() -> tuple[str, str, bool]:
    bench_sha = run_text(["git", "rev-parse", "HEAD"], cwd=ROOT)
    status = run_text(["git", "status", "--porcelain", "--untracked-files=all"], cwd=ROOT)
    tree_state = "clean" if not status else "dirty"
    advertised = False
    try:
        heads = run_text(["git", "ls-remote", "--heads", "origin"], cwd=ROOT)
        advertised = any(line.split()[0] == bench_sha for line in heads.splitlines() if line.split())
    except HarnessError:
        advertised = False
    return bench_sha, tree_state, advertised


def _publication_reasons(
    *,
    metric_id: str,
    requested_samples: int,
    valid_samples: int,
    tree_state: str,
    advertised: bool,
    environment: dict[str, Any],
    provenance: dict[str, Any],
    bench_sha: str,
) -> list[dict[str, str]]:
    reasons: list[dict[str, str]] = []

    def add(code: str, label: str) -> None:
        reasons.append({"code": code, "label": label})

    if tree_state != "clean":
        add("BENCH_TREE_DIRTY", "benchmark checkout was not clean before measurement")
    if not advertised:
        add("BENCH_SHA_UNPUBLISHED", "benchmark commit was not advertised by canonical origin")
    if provenance.get("recipe_commit") != bench_sha:
        add("ARTIFACT_RECIPE_MISMATCH", "artifact was not built from this benchmark commit")
    if valid_samples != requested_samples:
        add("INVALID_SAMPLES", "one or more requested measurements were rejected")
    minimum = 30
    if requested_samples < minimum:
        add("SAMPLES_BELOW_POLICY", f"{requested_samples} samples; policy requires {minimum}")
    power = environment["power"]
    if not power["ac_power"]:
        add("AC_POWER_REQUIRED", "measurement did not run on AC power")
    if power["low_power_mode"]:
        add("LOW_POWER_MODE_ENABLED", "Linux low-power mode was enabled")
    if power.get("thermal_state") != "nominal":
        add("THERMAL_STATE_UNVERIFIED", "Linux thermal state was not independently verified")
    if metric_id == "PAINT-OPPORTUNITY":
        add("NO_PAIRED_ARM", "Linux paint session currently contains only the Keld arm")
        add(
            "DIAGNOSTIC_HELLO_ONLY",
            "Linux no-flag app boot is unavailable; this measures keld-host --hello only",
        )
    if metric_id == "DISK":
        add("SINGLE_LANE_DIAGNOSTIC", "DISK records one raw host lane with no paired arm")
        add(
            "DETERMINISTIC_SINGLE_SAMPLE",
            "file size is deterministic and is recorded once rather than padded statistically",
        )
    return reasons


def validate_result(document: dict[str, Any]) -> None:
    try:
        from jsonschema import Draft202012Validator
    except ImportError as error:
        raise HarnessError("jsonschema is required to validate result.v1 output") from error
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    errors = sorted(Draft202012Validator(schema).iter_errors(document), key=lambda item: item.json_path)
    if errors:
        raise HarnessError(f"result.v1 validation failed at {errors[0].json_path}: {errors[0].message}")


def run_metric(args: Any) -> tuple[dict[str, Any], bool]:
    registry = load_registry()
    contract = metric_contract(registry, args.metric)
    if args.fixture != FIXTURE_PATH:
        raise HarnessError(f"Linux harness currently implements only --fixture {FIXTURE_PATH}")
    if args.samples < 1 or args.samples > 1000:
        raise HarnessError("--samples must be in 1..=1000")
    if not LABEL_PATTERN.fullmatch(args.label):
        raise HarnessError("--label must be lowercase kebab-case")
    if args.metric == "PAINT-OPPORTUNITY" and args.cache_state not in SUPPORTED_PAINT_STATES:
        raise HarnessError(
            "Linux PAINT-OPPORTUNITY currently supports fresh-process and warm-cache"
        )
    if args.metric == "DISK" and (args.cache_state != "fresh-process" or args.samples != 1):
        raise HarnessError("Linux DISK requires --cache-state fresh-process --samples 1")

    output = pathlib.Path(args.out).resolve()
    expected_root = (ROOT / "linux" / "bench" / "results" / args.metric.lower()).resolve()
    if output.parent != expected_root or output.suffix != ".json":
        raise HarnessError(f"--out must be a .json file directly under {expected_root}")
    expected_name = f"{datetime.now(timezone.utc).date()}.{args.label}.{args.cache_state}.json"
    if output.name != expected_name:
        raise HarnessError(f"--out must use the immutable result name {expected_name}")
    if output.exists() or output.is_symlink():
        raise HarnessError(f"refusing to overwrite immutable result: {output.name}")

    artifact_dir = pathlib.Path(args.artifact_dir).resolve()
    provenance, product_artifact, bench_artifact = _read_artifacts(artifact_dir)
    bench_sha, tree_state, advertised = _git_state()
    environment, power_evidence = _environment(provenance, args.metric)
    started_utc = utc_now()
    template = TEMPLATE_PATH.read_bytes()
    payload_sha = hashlib.sha256(template).hexdigest()
    expected_payload_sha = provenance.get("recipe_files", {}).get(FIXTURE_PATH + "/index.html")
    if expected_payload_sha != payload_sha:
        raise HarnessError("fixture payload does not match artifact build provenance")

    if args.metric == "PAINT-OPPORTUNITY":
        if args.cache_state == "warm-cache":
            priming = _paint_attempt(bench_artifact, template, 0, args.timeout_seconds)
            if not priming["valid"]:
                raise HarnessError(f"warm-cache priming launch failed: {priming['reject_reason']}")
        samples = [
            _paint_attempt(bench_artifact, template, run, args.timeout_seconds)
            for run in range(1, args.samples + 1)
        ]
        artifact = bench_artifact
        artifact_record = provenance["artifacts"]["benchmark_adapter"]
        role = "diagnostic"
        lane = "webkitgtk"
        notes = (
            "External monotonic spawn-to-double-rAF image-beacon proxy. Linux no-flag app boot "
            "is not implemented, so this is the keld-host --hello diagnostic window only. "
            f"Power evidence: {power_evidence}."
        )
    else:
        artifact = product_artifact
        artifact_record = provenance["artifacts"]["product"]
        samples = [
            {
                "run": 1,
                "value": artifact.stat().st_size,
                "valid": True,
                "reject_reason": None,
                "diagnostics": {"artifact_lane": "raw-host-binary"},
            }
        ]
        role = "diagnostic"
        lane = "raw-host-binary"
        notes = (
            "Byte count of the unpatched Release keld-host binary. This is a raw host lane, "
            f"not an installer or package. Power evidence: {power_evidence}."
        )

    summary = summarize(samples)
    reasons = _publication_reasons(
        metric_id=args.metric,
        requested_samples=args.samples,
        valid_samples=summary["valid_samples"],
        tree_state=tree_state,
        advertised=advertised,
        environment=environment,
        provenance=provenance,
        bench_sha=bench_sha,
    )
    finished_utc = utc_now()
    document = {
        "schema_version": 1,
        "metric": {
            "id": args.metric,
            "unit": contract["unit"],
            "registry_version": registry["registry_version"],
        },
        "cache_state": args.cache_state,
        "session": {
            "started_utc": started_utc,
            "finished_utc": finished_utc,
            "requested_samples": args.samples,
            "interleaving": "none",
            "label": args.label,
            "notes": notes,
        },
        "environment": environment,
        "provenance": {
            "bench_sha": bench_sha,
            "bench_tree_state": tree_state,
            "keld_sha": provenance["source_git_sha"],
            "harness": {
                "path": "linux/bench/run.py",
                "sha256": sha256_file(HARNESS_PATH),
                "version": "1.0.0",
                "modules": [
                    {
                        "path": "linux/bench/run.py",
                        "sha256": sha256_file(HARNESS_PATH),
                    },
                    {
                        "path": "linux/bench/harness.py",
                        "sha256": sha256_file(MODULE_PATH),
                    },
                ],
            },
            "fixtures": [{"path": FIXTURE_PATH, "sha": provenance["recipe_commit"]}],
            "payload_sha256": payload_sha,
        },
        "arms": [
            {
                "arm_id": "keld-linux-host",
                "framework": {
                    "name": "Keld",
                    "version": provenance["source_git_sha"][:12],
                },
                "fixture_path": FIXTURE_PATH,
                "artifact": {
                    "sha256": artifact_record["sha256"],
                    "basename": artifact.name,
                    "version": provenance["source_git_sha"][:12],
                },
                "lane": lane,
                "role": role,
                "samples": samples,
                "statistics": summary,
            }
        ],
        "publication": {
            "policy_version": 1,
            "requested": args.publish,
            "eligible": not reasons,
            "reasons": reasons,
        },
    }
    validate_result(document)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("x", encoding="utf-8", newline="\n") as destination:
        json.dump(document, destination, indent=2, sort_keys=True)
        destination.write("\n")
    failed = summary["valid_samples"] != args.samples
    return document, failed


def request(server: BeaconServer, path: str) -> int:
    connection = http.client.HTTPConnection("127.0.0.1", server.port, timeout=2)
    try:
        connection.request("GET", path, headers={"Host": f"127.0.0.1:{server.port}"})
        response = connection.getresponse()
        response.read()
        return response.status
    finally:
        connection.close()
