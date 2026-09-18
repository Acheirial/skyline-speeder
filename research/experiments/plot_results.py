#!/usr/bin/env python3
import argparse
import csv
import math
import os
from collections import defaultdict
from statistics import mean, stdev

os.environ.setdefault("MPLCONFIGDIR", "/tmp/matplotlib-serverspeeder")
import matplotlib.pyplot as plt


def ci95(values):
    if len(values) < 2:
        return 0.0
    return 1.96 * stdev(values) / math.sqrt(len(values))


def load(path):
    groups = defaultdict(list)
    with open(path, newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            key = (row["cc"], float(row["rtt_ms"]), float(row["loss_pct"]))
            groups[key].append({
                "receiver_mbps": float(row["receiver_mbps"]),
                "retransmits": float(row["retransmits"]),
                "mean_rtt_ms": float(row["mean_rtt_ms"]),
                "sender_cpu_pct": float(row["sender_cpu_pct"]),
            })
    return groups


def plot_metric(groups, metric, ylabel, output):
    ccs = sorted({key[0] for key in groups})
    losses = sorted({key[2] for key in groups})
    rtts = sorted({key[1] for key in groups})
    fig, axes = plt.subplots(1, len(rtts), figsize=(5 * len(rtts), 4), sharey=False)
    if len(rtts) == 1:
        axes = [axes]
    markers = ["o", "s", "^", "D"]
    for axis, rtt in zip(axes, rtts):
        for index, cc in enumerate(ccs):
            ys, errors = [], []
            for loss in losses:
                values = [item[metric] for item in groups.get((cc, rtt, loss), [])]
                ys.append(mean(values) if values else float("nan"))
                errors.append(ci95(values) if values else 0)
            axis.errorbar(losses, ys, yerr=errors, label=cc.upper(),
                          marker=markers[index % len(markers)], capsize=3)
        axis.set_title(f"RTT={rtt:g} ms")
        axis.set_xlabel("Per-direction loss (%)")
        axis.grid(True, alpha=0.3)
    axes[0].set_ylabel(ylabel)
    axes[-1].legend()
    fig.suptitle("Rootless NetEm pilot (mean and 95% CI, n=5)")
    fig.tight_layout()
    fig.savefig(output, format="svg", bbox_inches="tight")
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("input")
    parser.add_argument("output_dir")
    args = parser.parse_args()
    os.makedirs(args.output_dir, exist_ok=True)
    groups = load(args.input)
    plot_metric(groups, "receiver_mbps", "Receiver goodput (Mbit/s)",
                os.path.join(args.output_dir, "pilot-goodput.svg"))
    plot_metric(groups, "retransmits", "Retransmissions per 3 s run",
                os.path.join(args.output_dir, "pilot-retransmits.svg"))
    plot_metric(groups, "mean_rtt_ms", "Sender mean RTT (ms)",
                os.path.join(args.output_dir, "pilot-rtt.svg"))
    plot_metric(groups, "sender_cpu_pct", "Sender CPU utilization (%)",
                os.path.join(args.output_dir, "pilot-cpu.svg"))


if __name__ == "__main__":
    main()

