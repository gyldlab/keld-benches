#!/usr/bin/env python3
"""Run the KEL-171 correctness matrix and emit raw, checksummed evidence."""

from __future__ import annotations

import argparse
import hashlib
import binascii
import json
import os
from pathlib import Path
import random
import secrets
import selectors
import shutil
import subprocess
import sys
import time
import zlib


BACKENDS = ("x11", "wayland")
STYLES = ("opaque", "transparent")
MITIGATIONS = ("off", "on")
FIXTURE = Path(__file__).resolve().parent
REPOSITORY = FIXTURE.parents[2]
sys.path.insert(0, str(REPOSITORY / "linux" / "bench"))

from harness import (  # noqa: E402
    BeaconServer,
    HarnessError,
    OwnedProcess,
    ProcessIdentity,
    read_keld_artifacts,
)


RENDERER_OVERRIDE_VARIABLES = (
    "LIBGL_ALWAYS_SOFTWARE",
    "LIBGL_DRI3_DISABLE",
    "MESA_LOADER_DRIVER_OVERRIDE",
    "DRI_PRIME",
    "__GLX_VENDOR_LIBRARY_NAME",
    "__NV_PRIME_RENDER_OFFLOAD",
    "VK_ICD_FILENAMES",
    "WEBKIT_DISABLE_COMPOSITING_MODE",
    "LD_PRELOAD",
)


def renderer_override_errors(environment: dict[str, str]) -> list[str]:
    return [name for name in RENDERER_OVERRIDE_VARIABLES if environment.get(name) is not None]


def matrix_schedule(
    backends: tuple[str, ...], samples: int, seed: int
) -> list[tuple[str, str, str, int]]:
    generator = random.Random(seed)
    schedule: list[tuple[str, str, str, int]] = []
    for repetition in range(1, samples + 1):
        cells = [(backend, style) for backend in backends for style in STYLES]
        generator.shuffle(cells)
        for backend, style in cells:
            mitigations = list(MITIGATIONS)
            generator.shuffle(mitigations)
            schedule.extend(
                (backend, style, mitigation, repetition) for mitigation in mitigations
            )
    return schedule


def matrix_completion(
    rows: list[dict[str, object]],
    backends: tuple[str, ...],
    samples: int,
    negative_valid: bool,
    census_errors: list[str],
) -> tuple[bool, bool, int]:
    expected = samples * len(backends) * len(STYLES) * len(MITIGATIONS)
    expected_keys = {
        (backend, style, mitigation, repetition)
        for backend in backends
        for style in STYLES
        for mitigation in MITIGATIONS
        for repetition in range(1, samples + 1)
    }
    observed_keys = {
        (row.get("backend"), row.get("style"), row.get("mitigation"), row.get("repetition"))
        for row in rows
    }
    selected = (
        observed_keys == expected_keys
        and all(
            any(
                row.get("valid") is True
                and (
                    row.get("backend"),
                    row.get("style"),
                    row.get("mitigation"),
                    row.get("repetition"),
                )
                == key
                for row in rows
            )
            for key in expected_keys
        )
        and negative_valid
        and not census_errors
    )
    return selected, selected and backends == BACKENDS, expected


def retryable_native_acquisition(row: dict[str, object]) -> bool:
    reasons = set(row.get("reject_reasons", []))
    oracle = row.get("compositor_oracle")
    capture = row.get("compositor_capture")
    marker_missing = (
        isinstance(oracle, dict)
        and oracle.get("error") == "unique magenta window marker not found"
    )
    capture_failed = isinstance(capture, dict) and capture.get("valid") is False
    return (reasons == {"compositor_oracle_failed"} and marker_missing) or (
        reasons == {"compositor_capture_failed", "compositor_oracle_failed"}
        and capture_failed
    )


def retryable_keld_focus(row: dict[str, object]) -> bool:
    reasons = set(row.get("reject_reasons", []))
    return reasons == {"beacon_not_accepted", "document_not_focused"}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def decode_png_oracle(path: Path, style: str) -> dict[str, object]:
    raw = path.read_bytes()
    if not raw.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("invalid PNG signature")
    cursor = 8
    width = height = bit_depth = color_type = interlace = None
    compressed = bytearray()
    while cursor < len(raw):
        if cursor + 12 > len(raw):
            raise ValueError("truncated PNG chunk")
        length = int.from_bytes(raw[cursor : cursor + 4], "big")
        kind = raw[cursor + 4 : cursor + 8]
        end = cursor + 12 + length
        if end > len(raw):
            raise ValueError("truncated PNG payload")
        payload = raw[cursor + 8 : cursor + 8 + length]
        expected_crc = int.from_bytes(raw[cursor + 8 + length : end], "big")
        if binascii.crc32(kind + payload) & 0xFFFFFFFF != expected_crc:
            raise ValueError("PNG chunk CRC mismatch")
        if kind == b"IHDR":
            if length != 13:
                raise ValueError("invalid PNG IHDR")
            width = int.from_bytes(payload[0:4], "big")
            height = int.from_bytes(payload[4:8], "big")
            bit_depth, color_type, compression, filter_method, interlace = payload[8:13]
            if compression != 0 or filter_method != 0:
                raise ValueError("unsupported PNG compression or filter method")
        elif kind == b"IDAT":
            compressed.extend(payload)
        elif kind == b"IEND":
            break
        cursor = end
    if width != 320 or height != 240 or bit_depth != 8 or color_type not in (2, 6):
        raise ValueError("unexpected PNG dimensions or pixel format")
    if interlace != 0:
        raise ValueError("interlaced PNG is unsupported")

    channels = 3 if color_type == 2 else 4
    scanline_bytes = width * channels
    inflated = zlib.decompress(bytes(compressed))
    if len(inflated) != height * (scanline_bytes + 1):
        raise ValueError("unexpected PNG data length")
    rows: list[bytearray] = []
    prior = bytearray(scanline_bytes)
    offset = 0
    for _row in range(height):
        filter_type = inflated[offset]
        encoded = inflated[offset + 1 : offset + 1 + scanline_bytes]
        offset += scanline_bytes + 1
        decoded = bytearray(scanline_bytes)
        for index, value in enumerate(encoded):
            left = decoded[index - channels] if index >= channels else 0
            above = prior[index]
            upper_left = prior[index - channels] if index >= channels else 0
            if filter_type == 0:
                predictor = 0
            elif filter_type == 1:
                predictor = left
            elif filter_type == 2:
                predictor = above
            elif filter_type == 3:
                predictor = (left + above) // 2
            elif filter_type == 4:
                estimate = left + above - upper_left
                distances = (
                    abs(estimate - left),
                    abs(estimate - above),
                    abs(estimate - upper_left),
                )
                predictor = (left, above, upper_left)[distances.index(min(distances))]
            else:
                raise ValueError("unsupported PNG filter")
            decoded[index] = (value + predictor) & 0xFF
        rows.append(decoded)
        prior = decoded

    def pixel(x: int, y: int) -> tuple[int, int, int, int]:
        start = x * channels
        values = tuple(rows[y][start : start + channels])
        if channels == 3:
            return values[0], values[1], values[2], 255
        return values[0], values[1], values[2], values[3]

    marker = pixel(16, 16)
    background = pixel(200, 120)
    expected_background = (32, 48, 64, 255) if style == "opaque" else (0, 0, 0, 0)
    return {
        "width": width,
        "height": height,
        "color_type": color_type,
        "marker_rgba": marker,
        "background_rgba": background,
        "oracle_pass": marker == (255, 0, 170, 255)
        and background == expected_background,
    }


def process_gpu_receipts(members: tuple[ProcessIdentity, ...]) -> list[dict[str, object]]:
    receipts: list[dict[str, object]] = []
    for member in members:
        executable = ""
        process_class = "unknown"
        try:
            arguments = [
                value.decode("utf-8", errors="replace")
                for value in Path(f"/proc/{member.pid}/cmdline").read_bytes().split(b"\0")
                if value
            ]
            if arguments:
                executable = Path(arguments[0]).name
                lowered = executable.lower()
                if executable in {"bwrap", "bubblewrap"}:
                    process_class = "sandbox-wrapper"
                elif "webkitwebprocess" in lowered:
                    process_class = "webkit-web"
                elif "webkitnetworkprocess" in lowered:
                    process_class = "webkit-network"
                elif "webkitgpuprocess" in lowered:
                    process_class = "webkit-gpu"
                elif "keld-host" in executable:
                    process_class = "keld-host"
                else:
                    process_class = "fixture-host"
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            pass
        devices: list[dict[str, object]] = []
        try:
            descriptors = sorted(Path(f"/proc/{member.pid}/fd").iterdir(), key=lambda item: int(item.name))
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            descriptors = []
        for descriptor in descriptors:
            try:
                target = os.readlink(descriptor)
                status = descriptor.stat()
            except (FileNotFoundError, PermissionError, ProcessLookupError):
                continue
            if not os.path.exists(f"/sys/dev/char/{os.major(status.st_rdev)}:{os.minor(status.st_rdev)}"):
                continue
            driver_link = Path(
                f"/sys/dev/char/{os.major(status.st_rdev)}:{os.minor(status.st_rdev)}/device/driver"
            )
            try:
                driver = str(driver_link.resolve(strict=True))
            except (FileNotFoundError, PermissionError, RuntimeError):
                driver = ""
            if target.startswith("/dev/dri/") or target.startswith("/dev/nvidia"):
                devices.append(
                    {
                        "fd": int(descriptor.name),
                        "target": target,
                        "device": f"{os.major(status.st_rdev)}:{os.minor(status.st_rdev)}",
                        "driver": driver,
                        "nvidia": target.startswith("/dev/nvidia") or "nvidia" in driver.lower(),
                    }
                )
        receipts.append(
            {
                "pid": member.pid,
                "process_group": member.process_group,
                "start_ticks": member.start_ticks,
                "executable": executable,
                "process_class": process_class,
                "graphics_devices": devices,
            }
        )
    return receipts


def capture_mutter_compositor(destination: Path) -> dict[str, object]:
    """Capture one real Mutter compositor frame through its PipeWire stream."""

    try:
        import gi

        gi.require_version("Gio", "2.0")
        from gi.repository import Gio, GLib
    except (ImportError, ValueError) as error:
        return {"valid": False, "error": f"Gio unavailable: {error}"}

    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)

    def call(
        destination_name: str,
        path: str,
        interface: str,
        method: str,
        parameters: object,
        result_type: str | None,
    ) -> object:
        expected = GLib.VariantType.new(result_type) if result_type else None
        return bus.call_sync(
            destination_name,
            path,
            interface,
            method,
            parameters,
            expected,
            Gio.DBusCallFlags.NONE,
            5_000,
            None,
        )

    session: str | None = None
    subscription: int | None = None
    try:
        screen_result = call(
            "org.gnome.Shell.Introspect",
            "/org/gnome/Shell/Introspect",
            "org.freedesktop.DBus.Properties",
            "Get",
            GLib.Variant(
                "(ss)", ("org.gnome.Shell.Introspect", "ScreenSize")
            ),
            "(v)",
        )
        screen_width, screen_height = screen_result.unpack()[0]
        session = call(
            "org.gnome.Mutter.ScreenCast",
            "/org/gnome/Mutter/ScreenCast",
            "org.gnome.Mutter.ScreenCast",
            "CreateSession",
            GLib.Variant("(a{sv})", ({},)),
            "(o)",
        ).unpack()[0]
        stream = call(
            "org.gnome.Mutter.ScreenCast",
            session,
            "org.gnome.Mutter.ScreenCast.Session",
            "RecordArea",
            GLib.Variant(
                "(iiiia{sv})", (0, 0, screen_width, screen_height, {})
            ),
            "(o)",
        ).unpack()[0]
        nodes: list[int] = []
        loop = GLib.MainLoop()

        def stream_added(
            _connection: object,
            _sender: str,
            _path: str,
            _interface: str,
            _signal: str,
            parameters: object,
            _data: object,
        ) -> None:
            nodes.append(parameters.unpack()[0])
            loop.quit()

        subscription = bus.signal_subscribe(
            "org.gnome.Mutter.ScreenCast",
            "org.gnome.Mutter.ScreenCast.Stream",
            "PipeWireStreamAdded",
            stream,
            None,
            Gio.DBusSignalFlags.NONE,
            stream_added,
            None,
        )
        timeout_source = GLib.timeout_add(5_000, lambda: (loop.quit(), False)[1])
        call(
            "org.gnome.Mutter.ScreenCast",
            session,
            "org.gnome.Mutter.ScreenCast.Session",
            "Start",
            None,
            None,
        )
        loop.run()
        if nodes and timeout_source:
            GLib.source_remove(timeout_source)
        if len(nodes) != 1:
            return {"valid": False, "error": "Mutter did not publish one PipeWire node"}
        command = [
            "gst-launch-1.0",
            "-q",
            "pipewiresrc",
            f"path={nodes[0]}",
            "num-buffers=1",
            "!",
            "videoconvert",
            "!",
            "pngenc",
            "snapshot=true",
            "!",
            "filesink",
            f"location={destination}",
        ]
        completed = subprocess.run(
            command,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=10,
        )
        return {
            "valid": completed.returncode == 0 and destination.is_file(),
            "screen_size": [screen_width, screen_height],
            "pipewire_node": nodes[0],
            "argv": [
                f"location={destination.name}" if item.startswith("location=") else item
                for item in command
            ],
            "returncode": completed.returncode,
            "stdout": completed.stdout,
            "stderr": completed.stderr,
        }
    except (OSError, subprocess.TimeoutExpired, GLib.Error) as error:
        return {"valid": False, "error": str(error)}
    finally:
        if session is not None:
            try:
                call(
                    "org.gnome.Mutter.ScreenCast",
                    session,
                    "org.gnome.Mutter.ScreenCast.Session",
                    "Stop",
                    None,
                    None,
                )
            except GLib.Error:
                pass
        if subscription is not None:
            bus.signal_unsubscribe(subscription)


def compositor_oracle(
    full_frame: Path, cropped_frame: Path, style: str
) -> dict[str, object]:
    try:
        import gi

        gi.require_version("GdkPixbuf", "2.0")
        from gi.repository import GdkPixbuf, GLib
    except (ImportError, ValueError) as error:
        return {"oracle_pass": False, "error": f"GdkPixbuf unavailable: {error}"}
    try:
        frame = GdkPixbuf.Pixbuf.new_from_file(str(full_frame))
    except GLib.Error as error:
        return {"oracle_pass": False, "error": str(error)}
    channels = frame.get_n_channels()
    if channels not in (3, 4) or frame.get_bits_per_sample() != 8:
        return {"oracle_pass": False, "error": "unsupported compositor pixel format"}
    width = frame.get_width()
    height = frame.get_height()
    rowstride = frame.get_rowstride()
    pixels = bytes(frame.get_pixels())
    marker = bytes((255, 0, 170))
    first: tuple[int, int] | None = None
    marker_count = 0
    for y in range(height):
        row = pixels[y * rowstride : y * rowstride + width * channels]
        for x in range(width):
            start = x * channels
            if row[start : start + 3] == marker:
                marker_count += 1
                if first is None:
                    first = (x, y)
    if first is None or not 3_500 <= marker_count <= 4_500:
        return {
            "oracle_pass": False,
            "error": "unique magenta window marker not found",
            "marker_pixels": marker_count,
        }
    crop_x, crop_y = first
    if crop_x + 320 > width or crop_y + 240 > height:
        return {"oracle_pass": False, "error": "marked window crop exceeds compositor frame"}
    crop = GdkPixbuf.Pixbuf.new_subpixbuf(frame, crop_x, crop_y, 320, 240)
    crop.savev(str(cropped_frame), "png", [], [])
    crop_channels = crop.get_n_channels()
    crop_stride = crop.get_rowstride()
    crop_pixels = bytes(crop.get_pixels())
    sample_start = 120 * crop_stride + 200 * crop_channels
    sample = tuple(crop_pixels[sample_start : sample_start + crop_channels])
    sample_rgba = sample if crop_channels == 4 else (*sample, 255)
    expected = (32, 48, 64, 255) if style == "opaque" else (0, 204, 68, 255)
    matching_background = 0
    for y in range(112, 128):
        for x in range(192, 208):
            start = y * crop_stride + x * crop_channels
            value = tuple(crop_pixels[start : start + crop_channels])
            rgba = value if crop_channels == 4 else (*value, 255)
            if all(
                abs(actual - wanted) <= 2
                for actual, wanted in zip(rgba, expected)
            ):
                matching_background += 1
    return {
        "oracle_pass": matching_background >= 240,
        "frame_size": [width, height],
        "crop_origin": [crop_x, crop_y],
        "crop_size": [320, 240],
        "marker_pixels": marker_count,
        "sample_rgba": sample_rgba,
        "expected_rgba": expected,
        "matching_background_pixels": matching_background,
        "minimum_background_pixels": 240,
    }


def run_command(argv: list[str]) -> dict[str, object]:
    timeout_seconds = 15
    try:
        completed = subprocess.run(
            argv,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout_seconds,
        )
    except subprocess.TimeoutExpired as error:
        stdout = (
            error.stdout.decode(errors="replace")
            if isinstance(error.stdout, bytes)
            else error.stdout or ""
        )
        stderr = (
            error.stderr.decode(errors="replace")
            if isinstance(error.stderr, bytes)
            else error.stderr or ""
        )
        return {
            "argv": argv,
            "returncode": None,
            "stdout": stdout,
            "stderr": stderr,
            "timeout_seconds": timeout_seconds,
            "timed_out": True,
        }
    except OSError as error:
        return {
            "argv": argv,
            "returncode": None,
            "stdout": "",
            "stderr": str(error),
            "timeout_seconds": timeout_seconds,
            "timed_out": False,
        }
    return {
        "argv": argv,
        "returncode": completed.returncode,
        "stdout": completed.stdout,
        "stderr": completed.stderr,
        "timeout_seconds": timeout_seconds,
        "timed_out": False,
    }


def collect_census() -> dict[str, object]:
    relevant_environment = {
        name: os.environ.get(name)
        for name in (
            "DISPLAY",
            "WAYLAND_DISPLAY",
            "XDG_SESSION_TYPE",
            "XDG_SESSION_ID",
            "GDK_BACKEND",
            *RENDERER_OVERRIDE_VARIABLES,
        )
    }
    commands = [
        ["uname", "-srmo"],
        ["cat", "/etc/os-release"],
        ["gnome-shell", "--version"],
        ["pkg-config", "--modversion", "gtk+-3.0"],
        ["pkg-config", "--modversion", "webkit2gtk-4.1"],
        ["lspci", "-nnk"],
        [
            "nvidia-smi",
            "--query-gpu=index,name,pci.bus_id,driver_version,vbios_version,display_active",
            "--format=csv,noheader",
        ],
        ["modinfo", "-F", "filename", "nvidia"],
        ["modinfo", "-F", "version", "nvidia"],
        ["modinfo", "-F", "license", "nvidia"],
        ["cat", "/proc/driver/nvidia/version"],
        ["cat", "/sys/module/nvidia/taint"],
        ["cat", "/proc/sys/kernel/tainted"],
        ["lsmod"],
        ["dpkg-query", "-W", "nvidia-driver-*", "libwebkit2gtk-4.1-0"],
        ["loginctl", "show-user", str(os.getuid()), "-p", "Display"],
    ]
    display_result = run_command(commands[-1])
    session_id = os.environ.get("XDG_SESSION_ID")
    if not session_id:
        display_value = str(display_result.get("stdout", "")).strip()
        if display_result.get("returncode") == 0 and display_value.startswith("Display="):
            session_id = display_value.removeprefix("Display=") or None
    command_results = [run_command(command) for command in commands[:-1]]
    command_results.append(display_result)
    if session_id:
        command_results.append(
            run_command(
                [
                    "loginctl",
                    "show-session",
                    session_id,
                    "-p",
                    "Type",
                    "-p",
                    "Class",
                    "-p",
                    "State",
                    "-p",
                    "Active",
                    "-p",
                    "Service",
                    "-p",
                    "Desktop",
                    "-p",
                    "VTNr",
                ]
            )
        )
    return {
        "captured_at_unix_ns": time.time_ns(),
        "environment": relevant_environment,
        "resolved_logind_session": session_id,
        "commands": command_results,
    }


def validate_census(census: dict[str, object]) -> list[str]:
    raw_commands = census.get("commands")
    if not isinstance(raw_commands, list):
        return ["missing_command_receipts"]
    commands = {
        tuple(receipt.get("argv", [])): receipt
        for receipt in raw_commands
        if isinstance(receipt, dict)
    }
    errors: list[str] = []

    def require(prefix: tuple[str, ...], contains: str | None = None) -> None:
        matching = [
            receipt
            for argv, receipt in commands.items()
            if argv[: len(prefix)] == prefix
        ]
        if len(matching) != 1:
            errors.append("missing_" + "_".join(prefix).replace("/", "_"))
            return
        receipt = matching[0]
        if receipt.get("returncode") != 0 or receipt.get("timed_out") is not False:
            errors.append("failed_" + "_".join(prefix).replace("/", "_"))
            return
        if contains is not None and contains.lower() not in str(receipt.get("stdout", "")).lower():
            errors.append("mismatch_" + "_".join(prefix).replace("/", "_"))

    require(("cat", "/etc/os-release"), "ubuntu")
    require(("pkg-config", "--modversion", "gtk+-3.0"))
    require(("pkg-config", "--modversion", "webkit2gtk-4.1"))
    require(("lspci", "-nnk"), "Kernel driver in use: nvidia")
    require(("nvidia-smi",), "NVIDIA")
    require(("modinfo", "-F", "filename", "nvidia"), "nvidia.ko")
    require(("modinfo", "-F", "version", "nvidia"))
    require(("modinfo", "-F", "license", "nvidia"))
    require(("cat", "/proc/driver/nvidia/version"), "NVIDIA UNIX")
    require(("loginctl", "show-session"), "Type=wayland")
    environment = census.get("environment")
    if not isinstance(environment, dict) or not environment.get("WAYLAND_DISPLAY"):
        errors.append("missing_wayland_display")
    for name in RENDERER_OVERRIDE_VARIABLES:
        if isinstance(environment, dict) and environment.get(name) is not None:
            errors.append(f"renderer_override_{name}")
    return errors


def committed_runner_provenance(expected_commit: str) -> dict[str, object]:
    environment = {
        **os.environ,
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_OPTIONAL_LOCKS": "0",
    }

    def git(*arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *arguments],
            cwd=REPOSITORY,
            env=environment,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    revision = git("rev-parse", "--verify", "HEAD^{commit}")
    if revision.returncode != 0:
        raise ValueError(f"cannot resolve fixture commit: {revision.stderr.strip()}")
    commit = revision.stdout.strip()
    if commit != expected_commit:
        raise ValueError(
            f"runner commit {commit} does not match artifact fixture commit {expected_commit}"
        )
    paths = (
        "linux/webkitgtk/dmabuf-matrix/audit.c",
        "linux/webkitgtk/dmabuf-matrix/build.sh",
        "linux/webkitgtk/dmabuf-matrix/probe.c",
        "linux/webkitgtk/dmabuf-matrix/run_matrix.py",
        "linux/bench/harness.py",
        "linux/keld/hello/index.html",
    )
    files: dict[str, str] = {}
    for relative in paths:
        for arguments in (
            ("diff", "--quiet", "HEAD", "--", relative),
            ("diff", "--cached", "--quiet", "HEAD", "--", relative),
        ):
            check = git(*arguments)
            if check.returncode != 0:
                raise ValueError(f"{relative} differs from committed fixture bytes")
        content = git("show", f"{commit}:{relative}")
        if content.returncode != 0:
            raise ValueError(f"{relative} is absent from the fixture commit")
        files[relative] = hashlib.sha256(content.stdout.encode()).hexdigest()
    return {"fixture_commit": commit, "files": files}


def validate_artifact_provenance(
    provenance: object, artifact: Path, artifact_digest: str
) -> str:
    if not isinstance(provenance, dict) or provenance.get("schema_version") != 1:
        raise ValueError("unsupported artifact provenance schema")
    if provenance.get("fixture_repository") != "github.com/gyldlab/keld-benches":
        raise ValueError("artifact provenance names a non-canonical fixture repository")
    fixture_commit = provenance.get("fixture_commit")
    if (
        not isinstance(fixture_commit, str)
        or len(fixture_commit) != 40
        or any(byte not in "0123456789abcdef" for byte in fixture_commit)
    ):
        raise ValueError("artifact provenance has an invalid fixture commit")
    artifact_record = provenance.get("artifact")
    if not isinstance(artifact_record, dict):
        raise ValueError("artifact provenance is missing its artifact record")
    if artifact.name != "kel171-webkitgtk-probe":
        raise ValueError("artifact executable has an unexpected basename")
    if artifact_record != {
        "basename": "kel171-webkitgtk-probe",
        "sha256": artifact_digest,
        "bytes": artifact.stat().st_size,
    }:
        raise ValueError("artifact provenance record does not match executable bytes")
    expected_files = {
        "linux/webkitgtk/dmabuf-matrix/audit.c",
        "linux/webkitgtk/dmabuf-matrix/build.sh",
        "linux/webkitgtk/dmabuf-matrix/probe.c",
    }
    fixture_files = provenance.get("fixture_files")
    if not isinstance(fixture_files, dict) or set(fixture_files) != expected_files:
        raise ValueError("artifact provenance has an invalid fixture file set")
    for relative, digest in fixture_files.items():
        if not isinstance(digest, str) or digest != sha256(REPOSITORY / relative):
            raise ValueError(f"artifact provenance hash mismatch: {relative}")
    audit = provenance.get("audit")
    audit_path = artifact.parent / "kel171-webkitgtk-audit.so"
    if not isinstance(audit, dict) or audit != {
        "basename": audit_path.name,
        "sha256": sha256(audit_path) if audit_path.is_file() else None,
        "bytes": audit_path.stat().st_size if audit_path.is_file() else None,
    }:
        raise ValueError("audit library provenance does not match its bytes")
    toolchains = provenance.get("toolchains")
    if (
        not isinstance(toolchains, dict)
        or set(toolchains) != {"cc", "gtk+-3.0", "webkit2gtk-4.1"}
        or not all(isinstance(value, str) and value for value in toolchains.values())
    ):
        raise ValueError("artifact provenance has incomplete toolchain identity")
    return fixture_commit


def run_row(
    artifact: Path,
    output: Path,
    backend: str,
    style: str,
    mitigation: str,
    repetition: int,
    fault_black_compositor: bool = False,
    attempt: int = 1,
    receipt_timeout_seconds: float = 20,
    exit_timeout_seconds: float = 5,
) -> dict[str, object]:
    nonce = secrets.token_hex(16)
    row_directory = output / "native" / backend / style / mitigation
    row_directory.mkdir(parents=True, exist_ok=True)
    png_name = f"{repetition:02d}.try-{attempt}.webkit.png"
    compositor_name = f"{repetition:02d}.try-{attempt}.compositor.png"
    if fault_black_compositor:
        row_directory = output / "controls"
        row_directory.mkdir(parents=True, exist_ok=True)
        png_name = "negative-control.black-compositor.webkit.png"
        compositor_name = "negative-control.black-compositor.png"
    png_path = row_directory / png_name
    compositor_path = row_directory / compositor_name
    environment = os.environ.copy()
    environment["GDK_BACKEND"] = backend
    environment["KEL171_NONCE"] = nonce
    environment["GTK_A11Y"] = "none"
    if mitigation == "on":
        environment["WEBKIT_DISABLE_DMABUF_RENDERER"] = "1"
    else:
        environment.pop("WEBKIT_DISABLE_DMABUF_RENDERER", None)
    if fault_black_compositor:
        environment["KEL171_FAULT_BLACK_COMPOSITOR"] = "1"
    else:
        environment.pop("KEL171_FAULT_BLACK_COMPOSITOR", None)

    started = time.monotonic_ns()
    process = subprocess.Popen(
        [str(artifact), "--style", style, "--output", str(png_path)],
        env=environment,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    owner = OwnedProcess(process)
    first_stdout = b""
    timed_out = False
    live_members: tuple[ProcessIdentity, ...] = ()
    gpu_receipts: list[dict[str, object]] = []
    compositor_capture: dict[str, object] = {"valid": False, "error": "not attempted"}
    compositor_captures: list[dict[str, object]] = []
    compositor_pixels: dict[str, object] = {"oracle_pass": False, "error": "not attempted"}
    if process.stdout is None:
        raise RuntimeError("probe stdout pipe is unavailable")
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        if selector.select(receipt_timeout_seconds):
            first_stdout = process.stdout.readline()
        else:
            timed_out = True
    if first_stdout and process.poll() is None:
        live_members = owner.members()
        gpu_receipts = process_gpu_receipts(live_members)
        for capture_attempt in range(1, 13):
            full_compositor_path = (
                row_directory / f".{compositor_name}.frame-{capture_attempt}.full"
            )
            compositor_capture = capture_mutter_compositor(full_compositor_path)
            compositor_captures.append(compositor_capture)
            if compositor_capture.get("valid") is True:
                compositor_pixels = compositor_oracle(
                    full_compositor_path, compositor_path, style
                )
            full_compositor_path.unlink(missing_ok=True)
            if compositor_path.is_file():
                break
        if process.stdin is None:
            raise RuntimeError("probe stdin pipe is unavailable")
        try:
            process.stdin.write(b"R")
            process.stdin.flush()
        except BrokenPipeError:
            pass
        process.stdin.close()
        process.stdin = None
    try:
        process.wait(timeout=exit_timeout_seconds if first_stdout else 0.1)
    except subprocess.TimeoutExpired:
        timed_out = True
    observed_returncode = process.poll()
    post_exit_members = owner.members()
    cleanup_error: str | None = None
    try:
        cleanup_owned_generation = owner.cleanup()
    except HarnessError as error:
        cleanup_owned_generation = False
        cleanup_error = str(error)
    if process.stdin is not None:
        process.stdin.close()
        process.stdin = None
    remaining_stdout = process.stdout.read()
    process.stdout.close()
    stdout = (first_stdout + remaining_stdout).decode("utf-8", errors="replace")
    if process.stderr is not None:
        stderr = process.stderr.read().decode("utf-8", errors="replace")
        process.stderr.close()
    else:
        stderr = ""
    cleanup_returncode = process.returncode
    ended = time.monotonic_ns()

    receipt: object | None = None
    receipt_error: str | None = None
    lines = stdout.splitlines()
    if len(lines) == 1:
        try:
            receipt = json.loads(lines[0])
        except json.JSONDecodeError as error:
            receipt_error = str(error)
    else:
        receipt_error = f"expected one stdout line, observed {len(lines)}"

    png_digest = sha256(png_path) if png_path.is_file() else None
    compositor_digest = sha256(compositor_path) if compositor_path.is_file() else None
    png_oracle: dict[str, object] | None = None
    png_error: str | None = None
    if png_digest is not None:
        try:
            png_oracle = decode_png_oracle(png_path, style)
        except (OSError, ValueError, zlib.error) as error:
            png_error = str(error)
    expected_display = {"x11": "GdkX11Display", "wayland": "GdkWaylandDisplay"}[backend]
    expected_flag: str | None = "1" if mitigation == "on" else None
    reject_reasons: list[str] = []
    if timed_out:
        reject_reasons.append("timeout")
    if observed_returncode != 0:
        reject_reasons.append(
            "missing_exit_status" if observed_returncode is None else f"process_exited_{observed_returncode}"
        )
    if cleanup_error is not None:
        reject_reasons.append("cleanup_failed")
    if receipt_error is not None or not isinstance(receipt, dict):
        reject_reasons.append("invalid_receipt")
    else:
        expected_surface = {
            "marker_argb": "ffff00aa",
            "background_argb": "ff203040" if style == "opaque" else "00000000",
            "type": 0,
            "format": 0,
            "width": 320,
            "height": 240,
        }
        if receipt.get("nonce") != nonce:
            reject_reasons.append("nonce_mismatch")
        if receipt.get("style") != style:
            reject_reasons.append("style_mismatch")
        if receipt.get("gdk_display_type") != expected_display:
            reject_reasons.append("backend_mismatch")
        if receipt.get("disable_dmabuf_renderer") != expected_flag:
            reject_reasons.append("mitigation_mismatch")
        if receipt.get("oracle_pass") is not True or receipt.get("png_status") != 0:
            reject_reasons.append("renderer_oracle_failed")
        if receipt.get("surface") != expected_surface:
            reject_reasons.append("surface_receipt_mismatch")
        for version_field in ("gtk_runtime", "gtk_headers", "webkit_runtime", "webkit_headers"):
            value = receipt.get(version_field)
            if not isinstance(value, str) or len(value.split(".")) != 3:
                reject_reasons.append(f"invalid_{version_field}")
    if png_digest is None:
        reject_reasons.append("missing_png")
    elif png_error is not None or png_oracle is None:
        reject_reasons.append("invalid_png")
    elif png_oracle.get("oracle_pass") is not True:
        reject_reasons.append("png_oracle_failed")
    direct_nvidia = any(
        device.get("nvidia") is True
        for process_receipt in gpu_receipts
        for device in process_receipt["graphics_devices"]
        if isinstance(device, dict)
    )
    if not direct_nvidia:
        reject_reasons.append("no_process_nvidia_device")
    if compositor_capture.get("valid") is not True:
        reject_reasons.append("compositor_capture_failed")
    if compositor_pixels.get("oracle_pass") is not True or compositor_digest is None:
        reject_reasons.append("compositor_oracle_failed")
    valid = not reject_reasons
    if fault_black_compositor:
        valid = (
            not timed_out
            and observed_returncode == 0
            and isinstance(receipt, dict)
            and receipt.get("oracle_pass") is True
            and receipt.get("fault_black_compositor") is True
            and cleanup_error is None
            and png_oracle is not None
            and png_oracle.get("oracle_pass") is True
            and compositor_capture.get("valid") is True
            and compositor_pixels.get("oracle_pass") is False
            and compositor_pixels.get("sample_rgba") == (0, 0, 0, 255)
        )
        reject_reasons = [] if valid else ["negative_control_not_rejected"]
    return {
        "backend": backend,
        "style": style,
        "mitigation": mitigation,
        "repetition": repetition,
        "attempt": attempt,
        "nonce": nonce,
        "argv": [
            artifact.name,
            "--style",
            style,
            "--output",
            png_path.relative_to(output).as_posix(),
        ],
        "started_monotonic_ns": started,
        "ended_monotonic_ns": ended,
        "timed_out": timed_out,
        "returncode": observed_returncode,
        "signal": -observed_returncode
        if observed_returncode is not None and observed_returncode < 0
        else None,
        "cleanup_returncode": cleanup_returncode,
        "cleanup_owned_generation": cleanup_owned_generation,
        "cleanup_error": cleanup_error,
        "live_process_group": [member.__dict__ for member in live_members],
        "post_exit_process_group": [member.__dict__ for member in post_exit_members],
        "process_gpu_receipts": gpu_receipts,
        "direct_nvidia_device": direct_nvidia,
        "stdout": stdout,
        "stderr": stderr,
        "receipt": receipt,
        "receipt_error": receipt_error,
        "png": png_path.relative_to(output).as_posix() if png_digest is not None else None,
        "png_sha256": png_digest,
        "png_oracle": png_oracle,
        "png_error": png_error,
        "compositor_png": compositor_path.relative_to(output).as_posix()
        if compositor_digest is not None
        else None,
        "compositor_sha256": compositor_digest,
        "compositor_capture": compositor_capture,
        "compositor_capture_attempts": compositor_captures,
        "compositor_oracle": compositor_pixels,
        "reject_reasons": reject_reasons,
        "valid": valid,
    }


def read_keld_audit(path: Path) -> tuple[dict[str, str] | None, str | None]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        return None, str(error)
    receipt: dict[str, str] = {}
    for line in lines:
        key, separator, value = line.partition("=")
        if not separator or not key or key in receipt:
            return None, "malformed or duplicate audit field"
        receipt[key] = value
    expected = {
        "schema_version",
        "pid",
        "uri",
        "gdk_display_type",
        "gdk_display_name",
        "gtk_runtime",
        "webkit_runtime",
        "disable_dmabuf_renderer",
    }
    if set(receipt) != expected:
        return None, "audit field set mismatch"
    return receipt, None


def run_keld_row(
    artifact: Path,
    audit_library: Path,
    output: Path,
    backend: str,
    mitigation: str,
    repetition: int,
    attempt: int = 1,
) -> dict[str, object]:
    server = BeaconServer((REPOSITORY / "linux" / "keld" / "hello" / "index.html").read_bytes())
    server.start()
    row_directory = output / "keld" / backend / "opaque" / mitigation
    row_directory.mkdir(parents=True, exist_ok=True)
    receipt_name = f"{repetition:02d}.try-{attempt}.audit"
    receipt_path = row_directory / receipt_name
    environment = os.environ.copy()
    environment["GDK_BACKEND"] = backend
    environment["KELD_BENCH_URL"] = server.page_url
    environment["KEL171_KELD_RECEIPT"] = str(receipt_path)
    environment["LD_PRELOAD"] = str(audit_library)
    if mitigation == "on":
        environment["WEBKIT_DISABLE_DMABUF_RENDERER"] = "1"
    else:
        environment.pop("WEBKIT_DISABLE_DMABUF_RENDERER", None)
        environment.pop("WAYLAND_DISPLAY", None)

    started = time.monotonic_ns()
    process = subprocess.Popen(
        [str(artifact), "--hello", "--title", f"KEL171-{server.nonce}"],
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    owner = OwnedProcess(process)
    beacon_accepted = False
    exited_before_beacon = False
    deadline = time.monotonic() + 20
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        if server.wait_for_beacon(min(remaining, 0.1)):
            beacon_accepted = True
            break
        if process.poll() is not None:
            exited_before_beacon = True
            break
    beacon = server.snapshot()
    live_members = owner.members()
    gpu_receipts = process_gpu_receipts(live_members)
    direct_nvidia = any(
        device.get("nvidia") is True
        for process_receipt in gpu_receipts
        for device in process_receipt["graphics_devices"]
        if isinstance(device, dict)
    )
    audit, audit_error = read_keld_audit(receipt_path)
    cleanup_error: str | None = None
    try:
        cleanup_owned_generation = owner.cleanup()
    except HarnessError as error:
        cleanup_owned_generation = False
        cleanup_error = str(error)
    stdout = (
        process.stdout.read().decode("utf-8", errors="replace")
        if process.stdout is not None
        else ""
    )
    stderr = (
        process.stderr.read().decode("utf-8", errors="replace")
        if process.stderr is not None
        else ""
    )
    if process.stdout is not None:
        process.stdout.close()
    if process.stderr is not None:
        process.stderr.close()
    server.close()
    ended = time.monotonic_ns()

    expected_backend = {"x11": "GdkX11Display", "wayland": "GdkWaylandDisplay"}[backend]
    expected_flag = "1" if mitigation == "on" else "<absent>"
    reject_reasons: list[str] = []
    if not beacon_accepted or beacon.accepted_ns is None:
        reject_reasons.append("beacon_not_accepted")
    if beacon.protocol_error is not None:
        reject_reasons.append(beacon.protocol_error)
    if beacon.rejections:
        reject_reasons.append(beacon.rejections[-1])
    if exited_before_beacon:
        reject_reasons.append(f"process_exited_{process.returncode}")
    if audit_error is not None or audit is None:
        reject_reasons.append("invalid_keld_audit")
    else:
        if audit.get("pid") != str(process.pid):
            reject_reasons.append("keld_audit_pid_mismatch")
        if audit.get("uri") != server.page_url:
            reject_reasons.append("keld_audit_uri_mismatch")
        if audit.get("gdk_display_type") != expected_backend:
            reject_reasons.append("keld_backend_mismatch")
        if audit.get("disable_dmabuf_renderer") != expected_flag:
            reject_reasons.append("keld_mitigation_mismatch")
    if not direct_nvidia:
        reject_reasons.append("no_process_nvidia_device")
    if cleanup_error is not None:
        reject_reasons.append("cleanup_failed")
    return {
        "backend": backend,
        "style": "opaque",
        "mitigation": mitigation,
        "repetition": repetition,
        "attempt": attempt,
        "nonce": server.nonce,
        "started_monotonic_ns": started,
        "ended_monotonic_ns": ended,
        "beacon": {
            "page_requests": beacon.page_requests,
            "beacon_requests": beacon.beacon_requests,
            "accepted_ns": beacon.accepted_ns,
            "protocol_error": beacon.protocol_error,
            "rejections": beacon.rejections,
        },
        "returncode_after_cleanup": process.returncode,
        "signal_after_cleanup": -process.returncode
        if process.returncode is not None and process.returncode < 0
        else None,
        "stdout": stdout,
        "stderr": stderr,
        "audit": audit,
        "audit_path": receipt_path.relative_to(output).as_posix(),
        "audit_error": audit_error,
        "live_process_group": [member.__dict__ for member in live_members],
        "process_gpu_receipts": gpu_receipts,
        "direct_nvidia_device": direct_nvidia,
        "cleanup_owned_generation": cleanup_owned_generation,
        "cleanup_error": cleanup_error,
        "reject_reasons": reject_reasons,
        "valid": not reject_reasons,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact", required=True, type=Path)
    parser.add_argument("--provenance", required=True, type=Path)
    parser.add_argument("--keld-artifact-dir", required=True, type=Path)
    parser.add_argument("--expected-keld-sha", required=True)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--samples", type=int, default=5)
    parser.add_argument("--seed", type=int, default=171)
    parser.add_argument("--backend", action="append", choices=BACKENDS)
    args = parser.parse_args()
    if args.samples < 1 or args.samples > 30:
        parser.error("--samples must be between 1 and 30")
    if (
        len(args.expected_keld_sha) != 40
        or any(byte not in "0123456789abcdef" for byte in args.expected_keld_sha)
    ):
        parser.error("--expected-keld-sha must be a full lowercase SHA-1 commit")
    if args.out.exists():
        parser.error("--out must not already exist")
    if not args.artifact.is_file() or not os.access(args.artifact, os.X_OK):
        parser.error("--artifact must be an executable file")
    if not args.provenance.is_file():
        parser.error("--provenance must be a file")

    try:
        provenance = json.loads(args.provenance.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        parser.error(f"invalid provenance document: {error}")
    artifact_digest = sha256(args.artifact)
    present_overrides = renderer_override_errors(dict(os.environ))
    if present_overrides:
        parser.error("renderer override environment must be absent: " + ", ".join(present_overrides))
    try:
        expected_commit = validate_artifact_provenance(
            provenance, args.artifact, artifact_digest
        )
        runner_provenance = committed_runner_provenance(expected_commit)
        keld_provenance, _keld_product, keld_adapter = read_keld_artifacts(
            args.keld_artifact_dir
        )
    except ValueError as error:
        parser.error(str(error))
    except HarnessError as error:
        parser.error(str(error))
    committed_files = runner_provenance["files"]
    if not isinstance(committed_files, dict) or provenance["fixture_files"] != {
        relative: committed_files.get(relative)
        for relative in provenance["fixture_files"]
    }:
        parser.error("artifact recipe hashes do not match committed fixture bytes")
    if keld_provenance["source_git_sha"] != args.expected_keld_sha:
        parser.error("Keld artifact source does not match --expected-keld-sha")
    if keld_provenance["recipe_commit"] != expected_commit:
        parser.error("Keld artifact recipe commit does not match matrix fixture commit")
    keld_payload = "linux/keld/hello/index.html"
    if keld_provenance["recipe_files"].get(keld_payload) != committed_files.get(
        keld_payload
    ):
        parser.error("Keld artifact payload does not match committed matrix runner bytes")

    args.out.mkdir(parents=True)
    binary_directory = args.out / "bin"
    binary_directory.mkdir()
    executed_artifact = binary_directory / "kel171-webkitgtk-probe.executed"
    shutil.copyfile(args.artifact, executed_artifact)
    executed_artifact.chmod(0o500)
    if sha256(executed_artifact) != artifact_digest:
        parser.error("private artifact copy failed verification")
    audit_digest = provenance["audit"]["sha256"]
    executed_audit = binary_directory / "kel171-webkitgtk-audit.executed.so"
    shutil.copyfile(args.artifact.parent / "kel171-webkitgtk-audit.so", executed_audit)
    executed_audit.chmod(0o500)
    if sha256(executed_audit) != audit_digest:
        parser.error("private audit-library copy failed verification")
    executed_keld = binary_directory / "keld-host-bench.executed"
    shutil.copyfile(keld_adapter, executed_keld)
    executed_keld.chmod(0o500)
    keld_digest = keld_provenance["artifacts"]["benchmark_adapter"]["sha256"]
    if sha256(executed_keld) != keld_digest:
        parser.error("private Keld artifact copy failed verification")
    selected_backends = tuple(dict.fromkeys(args.backend or BACKENDS))
    max_attempts_per_sample = 3
    rows: list[dict[str, object]] = []
    for backend, style, mitigation, repetition in matrix_schedule(
        selected_backends, args.samples, args.seed
    ):
        for attempt in range(1, max_attempts_per_sample + 1):
            row = run_row(
                executed_artifact,
                args.out,
                backend,
                style,
                mitigation,
                repetition,
                attempt=attempt,
            )
            rows.append(row)
            if row["valid"]:
                break
            if not retryable_native_acquisition(row):
                break

    negative = run_row(
        executed_artifact,
        args.out,
        selected_backends[0],
        "transparent",
        "off",
        0,
        True,
    )
    keld_rows: list[dict[str, object]] = []
    for backend, style, mitigation, repetition in matrix_schedule(
        selected_backends, args.samples, args.seed
    ):
        if style == "opaque":
            for attempt in range(1, max_attempts_per_sample + 1):
                row = run_keld_row(
                    executed_keld,
                    executed_audit,
                    args.out,
                    backend,
                    mitigation,
                    repetition,
                    attempt,
                )
                keld_rows.append(row)
                if row["valid"]:
                    break
                if not retryable_keld_focus(row):
                    break
    keld_expected = args.samples * len(selected_backends) * len(MITIGATIONS)
    keld_expected_keys = {
        (backend, mitigation, repetition)
        for backend in selected_backends
        for mitigation in MITIGATIONS
        for repetition in range(1, args.samples + 1)
    }
    keld_complete = all(
        any(
            row["valid"]
            and (row["backend"], row["mitigation"], row["repetition"]) == key
            for row in keld_rows
        )
        for key in keld_expected_keys
    )
    keld_unavailable = [
        {
            "backend": backend,
            "style": "transparent",
            "mitigation": mitigation,
            "repetition": repetition,
            "status": "unavailable",
            "reason": "current Keld WebviewSpec has no transparent-window contract",
        }
        for repetition in range(1, args.samples + 1)
        for backend in selected_backends
        for mitigation in MITIGATIONS
    ]
    census = collect_census()
    census_errors = validate_census(census)
    selected_complete, full_matrix_complete, expected_row_count = matrix_completion(
        rows,
        selected_backends,
        args.samples,
        negative["valid"] is True,
        census_errors,
    )
    selected_complete = selected_complete and keld_complete
    full_matrix_complete = full_matrix_complete and keld_complete
    document = {
        "schema_version": 1,
        "purpose": "KEL-171 WebKitGTK NVIDIA DMA-BUF correctness matrix",
        "process_gpu_receipt_schema_version": 1,
        "samples_requested_per_cell": args.samples,
        "random_seed": args.seed,
        "backends": selected_backends,
        "styles": STYLES,
        "mitigations": MITIGATIONS,
        "artifact": {
            "path_basename": executed_artifact.name,
            "sha256": artifact_digest,
            "provenance": provenance,
        },
        "keld_artifact": {
            "path_basename": executed_keld.name,
            "sha256": keld_digest,
            "provenance": keld_provenance,
        },
        "runner": runner_provenance,
        "census": census,
        "census_errors": census_errors,
        "matrix_scope": "full" if selected_backends == BACKENDS else "selected-diagnostic",
        "expected_row_count": expected_row_count,
        "max_attempts_per_sample": max_attempts_per_sample,
        "rows": rows,
        "keld_rows": keld_rows,
        "keld_expected_row_count": keld_expected,
        "keld_transparent_cells": keld_unavailable,
        "negative_control": negative,
        "selected_complete": selected_complete,
        "complete": full_matrix_complete,
    }
    manifest_path = args.out / "manifest.json"
    manifest_path.write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    checksum_paths = sorted(
        path
        for path in args.out.rglob("*")
        if path.is_file() and path.name != "SHA256SUMS"
    )
    checksums = "".join(
        f"{sha256(path)}  {path.relative_to(args.out).as_posix()}\n"
        for path in checksum_paths
    )
    (args.out / "SHA256SUMS").write_text(checksums, encoding="utf-8")
    print(
        json.dumps(
            {
                "complete": document["complete"],
                "selected_complete": selected_complete,
                "manifest": str(manifest_path),
            }
        )
    )
    return 0 if selected_complete else 2


if __name__ == "__main__":
    sys.exit(main())
