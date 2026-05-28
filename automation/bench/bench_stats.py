#!/usr/bin/env python3
import argparse
import math
import re
import statistics
import subprocess
import sys
from dataclasses import dataclass


LINE_RE = re.compile(r"^\s*(\d+)\s+nodes\s+(\d+)\s+nps\s*$")


@dataclass
class BenchResult:
    nodes: int
    nps: int


def run_once(engine: str, mode: str, depth: int | None, taskset: str | None) -> BenchResult:
    cmd: list[str] = []
    if taskset:
        cmd.extend(["taskset", "-c", taskset])

    cmd.append(engine)
    cmd.append(mode)
    if depth is not None:
        cmd.append(str(depth))

    proc = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )

    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        raise RuntimeError(f"command failed with exit code {proc.returncode}: {' '.join(cmd)}")

    lines = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
    for line in reversed(lines):
        m = LINE_RE.match(line)
        if m:
            return BenchResult(nodes=int(m.group(1)), nps=int(m.group(2)))

    raise RuntimeError(f"could not parse bench output from: {' '.join(cmd)}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")


def summarize(values: list[int]) -> dict[str, float]:
    mean = statistics.fmean(values)
    median = statistics.median(values)
    minimum = min(values)
    maximum = max(values)
    if len(values) >= 2:
        stdev = statistics.stdev(values)
        ci95 = 1.96 * stdev / math.sqrt(len(values))
    else:
        stdev = 0.0
        ci95 = 0.0
    return {
        "mean": mean,
        "median": median,
        "min": float(minimum),
        "max": float(maximum),
        "stdev": stdev,
        "ci95": ci95,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Run lambergar bench repeatedly and summarize results.")
    parser.add_argument("--engine", default="./zig-out/bin/lambergar", help="Path to engine binary")
    parser.add_argument("--mode", choices=["bench", "benchhce"], default="bench", help="Benchmark mode")
    parser.add_argument("--depth", type=int, default=None, help="Optional bench depth")
    parser.add_argument("--runs", type=int, default=15, help="Measured runs")
    parser.add_argument("--warmup", type=int, default=2, help="Warmup runs discarded from stats")
    parser.add_argument("--taskset", default=None, help="Optional CPU set for taskset, e.g. 3")
    args = parser.parse_args()

    if args.runs <= 0:
        raise SystemExit("--runs must be positive")
    if args.warmup < 0:
        raise SystemExit("--warmup must be non-negative")

    print(f"engine: {args.engine}")
    print(f"mode: {args.mode}")
    print(f"depth: {args.depth if args.depth is not None else 'default'}")
    print(f"warmup: {args.warmup}")
    print(f"runs: {args.runs}")
    if args.taskset:
        print(f"taskset: {args.taskset}")
    print()

    for i in range(args.warmup):
        result = run_once(args.engine, args.mode, args.depth, args.taskset)
        print(f"warmup {i + 1:>2}: nodes={result.nodes} nps={result.nps}")

    measured: list[BenchResult] = []
    for i in range(args.runs):
        result = run_once(args.engine, args.mode, args.depth, args.taskset)
        measured.append(result)
        print(f"run    {i + 1:>2}: nodes={result.nodes} nps={result.nps}")

    print()
    node_values = [r.nodes for r in measured]
    nps_values = [r.nps for r in measured]
    node_stats = summarize(node_values)
    nps_stats = summarize(nps_values)

    print("nodes:")
    print(f"  mean   {node_stats['mean']:.2f}")
    print(f"  median {node_stats['median']:.2f}")
    print(f"  stdev  {node_stats['stdev']:.2f}")
    print(f"  95% CI +/- {node_stats['ci95']:.2f}")
    print(f"  min    {int(node_stats['min'])}")
    print(f"  max    {int(node_stats['max'])}")
    print()
    print("nps:")
    print(f"  mean   {nps_stats['mean']:.2f}")
    print(f"  median {nps_stats['median']:.2f}")
    print(f"  stdev  {nps_stats['stdev']:.2f}")
    print(f"  95% CI +/- {nps_stats['ci95']:.2f}")
    print(f"  min    {int(nps_stats['min'])}")
    print(f"  max    {int(nps_stats['max'])}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
