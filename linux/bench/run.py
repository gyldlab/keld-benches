#!/usr/bin/env python3
"""Command-line entry point for Linux keld-benches metrics."""

from __future__ import annotations

import argparse
import json
import sys

from harness import HarnessError, IMPLEMENTED_METRICS, load_registry, run_metric


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)
    commands.add_parser("list-metrics", help="list registry metrics implemented on Linux")
    run = commands.add_parser("run", help="run one Linux metric")
    run.add_argument("--metric", required=True, choices=IMPLEMENTED_METRICS)
    run.add_argument("--fixture", required=True, action="append")
    run.add_argument("--artifact-dir", required=True, action="append")
    run.add_argument("--samples", type=int, required=True)
    run.add_argument(
        "--cache-state",
        required=True,
        choices=("boot-cold", "fresh-process", "warm-cache", "renderer-warm"),
    )
    run.add_argument("--out", required=True)
    run.add_argument("--label", default="linux-keld")
    run.add_argument("--timeout-seconds", type=float, default=15.0)
    run.add_argument("--publish", action="store_true")
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        if args.command == "list-metrics":
            registry = load_registry()
            print(
                json.dumps(
                    {
                        "registry_version": registry["registry_version"],
                        "metrics": list(IMPLEMENTED_METRICS),
                    },
                    separators=(",", ":"),
                )
            )
            return 0
        if not 0 < args.timeout_seconds <= 120:
            raise HarnessError("--timeout-seconds must be in (0, 120]")
        document, failed = run_metric(args)
        valid = ",".join(
            f"{arm['arm_id']}={arm['statistics']['valid_samples']}/{args.samples}"
            for arm in document["arms"]
        )
        print(f"wrote {args.out}: {document['metric']['id']} valid={valid}")
        if failed:
            return 2
        if args.publish and not document["publication"]["eligible"]:
            return 3
        return 0
    except (HarnessError, OSError, ValueError) as error:
        print(f"linux benchmark failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
