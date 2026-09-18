#!/usr/bin/env python3
import argparse
import csv
import json
from pathlib import Path

from matrix_lib import expand_runs, load_manifest


CSV_FIELDS = [
    "case_id",
    "experiment",
    "execution_class",
    "performance_valid",
    "profile_id",
    "profile_kind",
    "cc",
    "modules",
    "tcp_recovery",
    "scenario_id",
    "rtt_ms",
    "rate_mbit",
    "queue_bdp",
    "queue_packets",
    "loss_model",
    "loss_pct",
    "loss_direction",
    "burst_length",
    "parallel",
    "offload",
    "warmup_s",
    "duration_s",
    "run_index",
    "seed",
]


def flatten(case, manifest):
    data = case.as_dict()
    return {
        "case_id": case.case_id,
        "experiment": case.experiment,
        "execution_class": manifest.execution_class,
        "performance_valid": manifest.performance_valid,
        "profile_id": case.profile.id,
        "profile_kind": case.profile.kind,
        "cc": case.profile.cc,
        "modules": ",".join(case.profile.modules),
        "tcp_recovery": case.profile.tcp_recovery,
        "scenario_id": case.scenario.id,
        "rtt_ms": case.scenario.rtt_ms,
        "rate_mbit": case.scenario.rate_mbit,
        "queue_bdp": case.scenario.queue_bdp,
        "queue_packets": data["queue_packets"],
        "loss_model": case.scenario.loss_model,
        "loss_pct": case.scenario.loss_pct,
        "loss_direction": case.scenario.loss_direction,
        "burst_length": case.scenario.burst_length,
        "parallel": case.scenario.parallel,
        "offload": case.scenario.offload,
        "warmup_s": case.warmup_s,
        "duration_s": case.duration_s,
        "run_index": case.run_index,
        "seed": case.seed,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest")
    parser.add_argument("output_prefix")
    args = parser.parse_args()
    manifest = load_manifest(args.manifest)
    cases = expand_runs(manifest)
    prefix = Path(args.output_prefix)
    csv_path = prefix.with_suffix(".csv")
    jsonl_path = prefix.with_suffix(".jsonl")
    for path in (csv_path, jsonl_path):
        if path.exists():
            raise SystemExit(f"Refusing to overwrite existing matrix: {path}")
        path.parent.mkdir(parents=True, exist_ok=True)
    with csv_path.open("x", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, CSV_FIELDS)
        writer.writeheader()
        writer.writerows(flatten(case, manifest) for case in cases)
    with jsonl_path.open("x", encoding="utf-8") as handle:
        for case in cases:
            handle.write(json.dumps(case.as_dict(), sort_keys=True) + "\n")
    print(f"wrote {len(cases)} runs to {csv_path} and {jsonl_path}")


if __name__ == "__main__":
    main()
