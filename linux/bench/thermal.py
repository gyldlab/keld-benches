#!/usr/bin/env python3
"""Fail-closed Linux thermal/throttle boundary evidence for benchmark sessions."""

from __future__ import annotations

import pathlib
import shutil
import subprocess
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any


@dataclass(frozen=True)
class LinuxThermalSnapshot:
    """One Linux thermal/throttle boundary observation."""

    sampled_utc: str
    cpu_counters: tuple[tuple[str, int], ...]
    cpu_packages: tuple[tuple[str, int, int], ...]
    nvidia_detected: bool
    nvidia_gpus: tuple[tuple[int, int, bool, bool], ...]
    errors: tuple[str, ...]


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _read_int(path: pathlib.Path) -> int | None:
    try:
        value = int(path.read_text(encoding="ascii").strip())
    except (OSError, ValueError):
        return None
    return value if value >= 0 else None


def cpu_thermal_throttle_counters(
    cpu_root: pathlib.Path = pathlib.Path("/sys/devices/system/cpu"),
) -> tuple[tuple[str, int], ...]:
    """Read cumulative Linux CPU thermal-throttle counters.

    Names include the logical CPU because sysfs may expose duplicated package
    counters through several CPUs. The verdict only asks whether any exact
    counter advanced; it never sums those values into a physical-duration claim.
    """

    counters: list[tuple[str, int]] = []
    for cpu in sorted(cpu_root.glob("cpu[0-9]*"), key=lambda path: path.name):
        throttle = cpu / "thermal_throttle"
        if not throttle.is_dir():
            continue
        for name in (
            "core_throttle_count",
            "core_throttle_total_time_ms",
            "package_throttle_count",
            "package_throttle_total_time_ms",
        ):
            path = throttle / name
            if not path.is_file():
                continue
            value = _read_int(path)
            if value is not None:
                counters.append((f"{cpu.name}/{name}", value))
    return tuple(counters)


def cpu_package_temperatures(
    hwmon_root: pathlib.Path = pathlib.Path("/sys/class/hwmon"),
) -> tuple[tuple[str, int, int], ...]:
    """Return hardware-reported package temperature and critical limit in mC."""

    packages: list[tuple[str, int, int]] = []
    for hwmon in sorted(hwmon_root.glob("hwmon*"), key=lambda path: path.name):
        name_path = hwmon / "name"
        try:
            name = name_path.read_text(encoding="ascii").strip()
        except OSError:
            continue
        if name != "coretemp":
            continue
        for label_path in sorted(hwmon.glob("temp*_label"), key=lambda path: path.name):
            try:
                label = label_path.read_text(encoding="ascii").strip()
            except OSError:
                continue
            if not label.startswith("Package id "):
                continue
            prefix = label_path.name.removesuffix("_label")
            current = _read_int(hwmon / f"{prefix}_input")
            critical = _read_int(hwmon / f"{prefix}_crit")
            if current is None or critical is None or critical <= 0:
                continue
            packages.append((label, current, critical))
    return tuple(packages)


def nvidia_thermal_rows() -> tuple[
    bool, tuple[tuple[int, int, bool, bool], ...], str | None
]:
    """Read NVIDIA temperature plus software/hardware thermal slowdown flags."""

    driver_present = pathlib.Path("/proc/driver/nvidia/version").is_file()
    nvidia_smi = shutil.which("nvidia-smi")
    if not driver_present and nvidia_smi is None:
        return False, (), None
    if nvidia_smi is None:
        return True, (), "nvidia_driver_without_nvidia_smi"
    command = [
        nvidia_smi,
        (
            "--query-gpu=index,temperature.gpu,"
            "clocks_throttle_reasons.sw_thermal_slowdown,"
            "clocks_throttle_reasons.hw_thermal_slowdown"
        ),
        "--format=csv,noheader,nounits",
    ]
    try:
        completed = subprocess.run(
            command,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return True, (), "nvidia_smi_thermal_query_failed"
    if completed.returncode != 0:
        return True, (), "nvidia_smi_thermal_query_failed"

    rows: list[tuple[int, int, bool, bool]] = []
    for raw in completed.stdout.splitlines():
        fields = [field.strip() for field in raw.split(",")]
        if len(fields) != 4:
            return True, (), "nvidia_smi_thermal_row_malformed"
        try:
            index = int(fields[0])
            temperature = int(fields[1])
        except ValueError:
            return True, (), "nvidia_smi_thermal_row_malformed"
        flags: list[bool] = []
        for field in fields[2:]:
            if field == "Active":
                flags.append(True)
            elif field == "Not Active":
                flags.append(False)
            else:
                return True, (), "nvidia_smi_thermal_flag_unknown"
        rows.append((index, temperature, flags[0], flags[1]))
    if not rows:
        return True, (), "nvidia_smi_thermal_rows_empty"
    rows.sort(key=lambda item: item[0])
    return True, tuple(rows), None


def linux_thermal_snapshot() -> LinuxThermalSnapshot:
    """Capture one fail-closed thermal boundary."""

    errors: list[str] = []
    counters = cpu_thermal_throttle_counters()
    if not counters:
        errors.append("cpu_thermal_throttle_counters_unavailable")

    packages = cpu_package_temperatures()
    if not packages:
        errors.append("cpu_package_temperature_unavailable")

    nvidia_detected, nvidia_gpus, nvidia_error = nvidia_thermal_rows()
    if nvidia_error is not None:
        errors.append(nvidia_error)

    return LinuxThermalSnapshot(
        sampled_utc=_utc_now(),
        cpu_counters=counters,
        cpu_packages=packages,
        nvidia_detected=nvidia_detected,
        nvidia_gpus=nvidia_gpus,
        errors=tuple(errors),
    )


def thermal_state_from_boundaries(
    start: LinuxThermalSnapshot,
    end: LinuxThermalSnapshot,
) -> tuple[str, str]:
    """Return nominal/throttled/unverified plus a compact evidence receipt."""

    problems = [*start.errors, *end.errors]
    start_counters = dict(start.cpu_counters)
    end_counters = dict(end.cpu_counters)
    advanced_counters: list[tuple[str, int]] = []

    if set(start_counters) != set(end_counters):
        problems.append("cpu_thermal_counter_set_changed")
    else:
        for name in sorted(start_counters):
            delta = end_counters[name] - start_counters[name]
            if delta < 0:
                problems.append(f"cpu_thermal_counter_reset:{name}")
            elif delta > 0:
                advanced_counters.append((name, delta))

    start_packages = {
        label: (current, critical) for label, current, critical in start.cpu_packages
    }
    end_packages = {
        label: (current, critical) for label, current, critical in end.cpu_packages
    }
    if set(start_packages) != set(end_packages):
        problems.append("cpu_package_sensor_set_changed")
    else:
        for label in sorted(start_packages):
            if start_packages[label][1] != end_packages[label][1]:
                problems.append(f"cpu_package_critical_changed:{label}")

    for label, (current, critical) in (*start_packages.items(), *end_packages.items()):
        if current >= critical:
            problems.append(f"cpu_package_at_or_above_critical:{label}")

    if start.nvidia_detected != end.nvidia_detected:
        problems.append("nvidia_detection_changed")
    start_gpu = {row[0]: row[1:] for row in start.nvidia_gpus}
    end_gpu = {row[0]: row[1:] for row in end.nvidia_gpus}
    if start.nvidia_detected:
        if set(start_gpu) != set(end_gpu):
            problems.append("nvidia_gpu_set_changed")
        for _index, (_temperature, sw_thermal, hw_thermal) in (
            *start_gpu.items(),
            *end_gpu.items(),
        ):
            if sw_thermal:
                problems.append("nvidia_sw_thermal_slowdown_active")
            if hw_thermal:
                problems.append("nvidia_hw_thermal_slowdown_active")

    throttled = bool(advanced_counters) or any(
        problem.startswith("cpu_package_at_or_above_critical:")
        or problem
        in {
            "nvidia_sw_thermal_slowdown_active",
            "nvidia_hw_thermal_slowdown_active",
        }
        for problem in problems
    )
    structural = [
        problem
        for problem in problems
        if not problem.startswith("cpu_package_at_or_above_critical:")
        and problem
        not in {
            "nvidia_sw_thermal_slowdown_active",
            "nvidia_hw_thermal_slowdown_active",
        }
    ]
    if throttled:
        state = "throttled"
    elif structural:
        state = "unverified"
    else:
        state = "nominal"

    package_start = ",".join(
        f"{label}:{current}/{critical}"
        for label, current, critical in start.cpu_packages
    ) or "none"
    package_end = ",".join(
        f"{label}:{current}/{critical}"
        for label, current, critical in end.cpu_packages
    ) or "none"
    gpu_start = ",".join(
        f"gpu{index}:{temp}C:sw={int(sw)}:hw={int(hw)}"
        for index, temp, sw, hw in start.nvidia_gpus
    ) or ("none" if not start.nvidia_detected else "unavailable")
    gpu_end = ",".join(
        f"gpu{index}:{temp}C:sw={int(sw)}:hw={int(hw)}"
        for index, temp, sw, hw in end.nvidia_gpus
    ) or ("none" if not end.nvidia_detected else "unavailable")

    evidence = (
        "thermal-boundary-v1"
        f";state={state}"
        f";cpu_counter_advances={len(advanced_counters)}"
        + (
            ";cpu_advanced="
            + ",".join(f"{name}:+{delta}" for name, delta in advanced_counters)
            if advanced_counters
            else ""
        )
        + f";cpu_start={package_start}"
        + f";cpu_end={package_end}"
        + f";nvidia_start={gpu_start}"
        + f";nvidia_end={gpu_end}"
    )
    if problems:
        evidence += ";problems=" + ",".join(sorted(set(problems)))
    return state, evidence


def finalize_thermal_environment(
    environment: dict[str, Any],
    power_evidence: str,
    start: LinuxThermalSnapshot,
) -> tuple[str, str]:
    """Close a session boundary, mutate thermal_state, and return evidence/time."""

    end = linux_thermal_snapshot()
    state, thermal_evidence = thermal_state_from_boundaries(start, end)
    environment["power"]["thermal_state"] = state
    return power_evidence + ";" + thermal_evidence, end.sampled_utc


def thermal_publication_reason(state: str) -> str | None:
    """Map a measured state to the stable publication blocker code."""

    if state == "nominal":
        return None
    if state == "throttled":
        return "THERMAL_THROTTLED"
    return "THERMAL_STATE_UNVERIFIED"
