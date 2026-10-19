"""Summarise the D samples (host clock, LastWindowClosed write -> Quit frame) per subset.

Usage: python -I analyze_d.py <samples.tsv of the idle runs> <samples.tsv of the load runs> <out.json>
Each samples.tsv row (run-cell.ps1): run<TAB>outcome<TAB>KELD_KEL270_H11 {json; the host evidence line is its "host"}
Only PASS runs with cause lifecycle-quit count as samples.
"""

import json
import statistics
import sys


def load(path, subset):
    rows = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            parts = line.rstrip("\r\n").split("\t", 2)
            if len(parts) != 3 or not parts[2].startswith("KELD_KEL270_H11 "):
                continue
            run, outcome, text = parts
            # The passing cell's record carries the host's evidence line as "host".
            record = json.loads(text[len("KELD_KEL270_H11 "):])["host"]
            rows.append(
                {
                    "subset": subset,
                    "run": int(run),
                    "outcome": outcome,
                    "cause": record["cause"],
                    "quit_wait_us": record["quit_wait_us"],
                    "ui_end_us": record["ui_end_us"],
                    "deadline_us": record["deadline_us"],
                }
            )
    return rows


def summarise(rows):
    samples = [r["quit_wait_us"] for r in rows if r["outcome"] == "PASS" and r["cause"] == "lifecycle-quit"]
    ui = [r["ui_end_us"] for r in rows if r["outcome"] == "PASS" and r["ui_end_us"] is not None]
    if not samples:
        return {"n": 0}
    return {
        "n": len(samples),
        "runs": len(rows),
        "quit_wait_us": {
            "min": min(samples),
            "median": statistics.median(samples),
            "p90": sorted(samples)[min(len(samples) - 1, int(0.9 * len(samples)))],
            "max": max(samples),
        },
        "ui_end_us": {"min": min(ui), "median": statistics.median(ui), "max": max(ui)} if ui else None,
    }


def main():
    idle = load(sys.argv[1], "idle")
    load_rows = load(sys.argv[2], "load")
    idle_summary = summarise(idle)
    load_summary = summarise(load_rows)
    overall_max = max(idle_summary["quit_wait_us"]["max"], load_summary["quit_wait_us"]["max"])
    floor_us = 10_000_000
    d_us = max(floor_us, 4 * overall_max)
    result = {
        "rule": "D = max(10 s, 4 x max over both subsets)",
        "idle": idle_summary,
        "load": load_summary,
        "max_us": overall_max,
        "four_times_max_us": 4 * overall_max,
        "floor_us": floor_us,
        "d_us": d_us,
        "samples": idle + load_rows,
    }
    with open(sys.argv[3], "w", encoding="utf-8") as out:
        json.dump(result, out, indent=1)
    print(
        f"D_SUMMARY idle_n={idle_summary['n']} idle_max_us={idle_summary['quit_wait_us']['max']} "
        f"idle_median_us={idle_summary['quit_wait_us']['median']} load_n={load_summary['n']} "
        f"load_max_us={load_summary['quit_wait_us']['max']} load_median_us={load_summary['quit_wait_us']['median']} "
        f"max_us={overall_max} four_times_max_us={4 * overall_max} d_us={d_us}"
    )


if __name__ == "__main__":
    main()
