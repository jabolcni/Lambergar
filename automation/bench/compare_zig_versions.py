#!/usr/bin/env python3
from __future__ import annotations

import argparse
import math
import re
import shutil
import statistics
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT_ROOT = REPO_ROOT / ".zig-version-compare"
BENCH_LINE_RE = re.compile(r"^\s*(\d+)\s+nodes\s+(\d+)\s+nps\s*$")
PERFT_ELAPSED_RE = re.compile(r"^\s*([0-9]+(?:\.[0-9]+)?)s elapsed\s*$")
PERFT_NODES_RE = re.compile(r"^\s*(\d+)\s+nodes explored\s*$")
PERFT_RATE_RE = re.compile(r"^\s*([0-9]+(?:\.[0-9]+)?)MN/s\s*$")


@dataclass(frozen=True)
class BuildSpec:
    zig: Path
    version: str
    label: str
    install_dir: Path
    cache_dir: Path
    global_cache_dir: Path
    binary: Path


@dataclass(frozen=True)
class BenchResult:
    nodes: int
    nps: int


@dataclass(frozen=True)
class BenchSummary:
    mode: str
    depth: int | None
    runs: int
    warmup: int
    nodes: int
    mean_nps: float
    stdev_nps: float
    min_nps: int
    max_nps: int
    ci95_nps: float


@dataclass(frozen=True)
class PerftResult:
    depth: int
    elapsed_seconds: float
    nodes: int
    mnps: float


def run_command(
    cmd: list[str],
    *,
    cwd: Path | None = None,
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(
        cmd,
        cwd=cwd,
        input=input_text,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        if proc.stdout:
            sys.stderr.write(proc.stdout)
        if proc.stderr:
            sys.stderr.write(proc.stderr)
        raise RuntimeError(f"command failed with exit code {proc.returncode}: {' '.join(cmd)}")
    return proc


def get_zig_version(zig: Path) -> str:
    proc = run_command([str(zig), "version"])
    return proc.stdout.strip()


def sanitize_label(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "-", text).strip("-") or "zig"


def build_binary(
    spec: BuildSpec,
    *,
    target: str,
    cpu: str,
    extra_build_args: list[str],
) -> None:
    spec.install_dir.mkdir(parents=True, exist_ok=True)
    spec.cache_dir.mkdir(parents=True, exist_ok=True)
    spec.global_cache_dir.mkdir(parents=True, exist_ok=True)

    cmd = [
        str(spec.zig),
        "build",
        f"-Dtarget={target}",
        f"-Dcpu={cpu}",
        "--prefix",
        str(spec.install_dir),
        "--cache-dir",
        str(spec.cache_dir),
        "--global-cache-dir",
        str(spec.global_cache_dir),
        *extra_build_args,
    ]

    print(f"[build:{spec.label}] {' '.join(cmd)}")
    run_command(cmd, cwd=REPO_ROOT)


def run_bench_once(engine: Path, mode: str, depth: int | None, taskset: str | None) -> BenchResult:
    cmd: list[str] = []
    if taskset:
        cmd.extend(["taskset", "-c", taskset])
    cmd.extend([str(engine), mode])
    if depth is not None:
        cmd.append(str(depth))

    proc = run_command(cmd, cwd=REPO_ROOT)
    lines = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
    for line in reversed(lines):
        match = BENCH_LINE_RE.match(line)
        if match:
            return BenchResult(nodes=int(match.group(1)), nps=int(match.group(2)))

    raise RuntimeError(
        f"could not parse {mode} output from {' '.join(cmd)}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
    )


def summarize_bench(
    engine: Path,
    mode: str,
    depth: int | None,
    warmup: int,
    runs: int,
    taskset: str | None,
) -> BenchSummary:
    for _ in range(warmup):
        run_bench_once(engine, mode, depth, taskset)

    results = [run_bench_once(engine, mode, depth, taskset) for _ in range(runs)]
    node_set = {result.nodes for result in results}
    if len(node_set) != 1:
        raise RuntimeError(f"{mode} node count changed across runs: {sorted(node_set)}")

    nps_values = [result.nps for result in results]
    if len(nps_values) >= 2:
        stdev_nps = statistics.stdev(nps_values)
        ci95_nps = 1.96 * stdev_nps / math.sqrt(len(nps_values))
    else:
        stdev_nps = 0.0
        ci95_nps = 0.0

    return BenchSummary(
        mode=mode,
        depth=depth,
        runs=runs,
        warmup=warmup,
        nodes=results[0].nodes,
        mean_nps=statistics.fmean(nps_values),
        stdev_nps=stdev_nps,
        min_nps=min(nps_values),
        max_nps=max(nps_values),
        ci95_nps=ci95_nps,
    )


def run_perft(engine: Path, depth: int, taskset: str | None) -> PerftResult:
    cmd: list[str] = []
    if taskset:
        cmd.extend(["taskset", "-c", taskset])
    cmd.append(str(engine))

    proc = run_command(cmd, cwd=REPO_ROOT, input_text=f"perft {depth}\nquit\n")
    elapsed: float | None = None
    nodes: int | None = None
    mnps: float | None = None

    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        if elapsed is None:
            match = PERFT_ELAPSED_RE.match(line)
            if match:
                elapsed = float(match.group(1))
                continue
        if nodes is None:
            match = PERFT_NODES_RE.match(line)
            if match:
                nodes = int(match.group(1))
                continue
        if mnps is None:
            match = PERFT_RATE_RE.match(line)
            if match:
                mnps = float(match.group(1))
                continue

    if elapsed is None or nodes is None or mnps is None:
        raise RuntimeError(f"could not parse perft {depth} output from {engine}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")

    return PerftResult(depth=depth, elapsed_seconds=elapsed, nodes=nodes, mnps=mnps)


def percent_delta(current: float, baseline: float) -> float:
    return ((current / baseline) - 1.0) * 100.0


def print_bench_comparison(left: BuildSpec, left_summary: BenchSummary, right: BuildSpec, right_summary: BenchSummary) -> None:
    slowdown = percent_delta(right_summary.mean_nps, left_summary.mean_nps)
    print(
        f"{left_summary.mode:<8} nodes={left_summary.nodes} "
        f"{left.label} mean={left_summary.mean_nps:,.0f} nps "
        f"{right.label} mean={right_summary.mean_nps:,.0f} nps "
        f"delta={slowdown:+.2f}%"
    )
    print(
        f"          {left.label} stdev={left_summary.stdev_nps:,.0f} ci95=+/-{left_summary.ci95_nps:,.0f} "
        f"{right.label} stdev={right_summary.stdev_nps:,.0f} ci95=+/-{right_summary.ci95_nps:,.0f}"
    )


def print_perft_comparison(left: BuildSpec, left_result: PerftResult, right: BuildSpec, right_result: PerftResult) -> None:
    node_note = ""
    if left_result.nodes != right_result.nodes:
        node_note = f" node-mismatch {left_result.nodes} vs {right_result.nodes}"
    delta = percent_delta(right_result.mnps, left_result.mnps)
    print(
        f"perft {left_result.depth:<2} "
        f"{left.label} {left_result.mnps:,.3f} MN/s "
        f"{right.label} {right_result.mnps:,.3f} MN/s "
        f"delta={delta:+.2f}%{node_note}"
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build the current tree with two Zig binaries and compare benchmark throughput."
    )
    parser.add_argument("--zig-a", required=True, help="Path to first Zig executable, typically 0.15.1")
    parser.add_argument("--zig-b", required=True, help="Path to second Zig executable, typically 0.16.0")
    parser.add_argument("--label-a", default=None, help="Optional label for first build")
    parser.add_argument("--label-b", default=None, help="Optional label for second build")
    parser.add_argument("--target", default="x86_64-linux", help="Zig target triple for both builds")
    parser.add_argument("--cpu", default="x86_64_v3", help="CPU target for both builds")
    parser.add_argument("--output-root", default=str(DEFAULT_OUTPUT_ROOT), help="Directory for install/cache output")
    parser.add_argument("--bench-runs", type=int, default=5, help="Measured runs for bench and benchhce")
    parser.add_argument("--bench-warmup", type=int, default=1, help="Warmup runs discarded from stats")
    parser.add_argument("--bench-depth", type=int, default=None, help="Optional depth passed to bench/benchhce")
    parser.add_argument("--skip-build", action="store_true", help="Reuse existing binaries under output-root")
    parser.add_argument("--skip-bench", action="store_true", help="Skip bench/benchhce runs")
    parser.add_argument("--skip-benchhce", action="store_true", help="Run bench only")
    parser.add_argument("--perft-depth", type=int, action="append", default=[], help="Perft depth to compare; repeatable")
    parser.add_argument("--taskset", default=None, help="Optional Linux CPU set, for example 3")
    parser.add_argument(
        "--extra-build-arg",
        action="append",
        default=[],
        help="Extra argument passed through to both zig build invocations",
    )
    return parser.parse_args()


def make_build_spec(zig_path: str, label: str | None, output_root: Path, target: str) -> BuildSpec:
    zig = Path(zig_path).expanduser().resolve()
    if not zig.exists():
        raise SystemExit(f"zig executable not found: {zig}")

    version = get_zig_version(zig)
    resolved_label = label or f"zig-{version}"
    resolved_label = sanitize_label(resolved_label)
    binary_name = "lambergar.exe" if "windows" in target else "lambergar"
    build_root = output_root / resolved_label
    return BuildSpec(
        zig=zig,
        version=version,
        label=resolved_label,
        install_dir=build_root / "install",
        cache_dir=build_root / "cache",
        global_cache_dir=build_root / "global-cache",
        binary=build_root / "install" / "bin" / binary_name,
    )


def main() -> int:
    args = parse_args()
    output_root = Path(args.output_root).expanduser().resolve()
    output_root.mkdir(parents=True, exist_ok=True)

    left = make_build_spec(args.zig_a, args.label_a, output_root, args.target)
    right = make_build_spec(args.zig_b, args.label_b, output_root, args.target)

    print(f"repo: {REPO_ROOT}")
    print(f"target: {args.target}")
    print(f"cpu: {args.cpu}")
    print("note: build.zig currently pins ReleaseFast in source, so this script does not inject an optimize flag.")
    print()
    print(f"{left.label}: zig {left.version} -> {left.binary}")
    print(f"{right.label}: zig {right.version} -> {right.binary}")
    print()

    if not args.skip_build:
        for spec in (left, right):
            if spec.install_dir.exists():
                shutil.rmtree(spec.install_dir)
            if spec.cache_dir.exists():
                shutil.rmtree(spec.cache_dir)
            if spec.global_cache_dir.exists():
                shutil.rmtree(spec.global_cache_dir)
            build_binary(spec, target=args.target, cpu=args.cpu, extra_build_args=args.extra_build_arg)
            if not spec.binary.exists():
                raise RuntimeError(f"expected built binary is missing: {spec.binary}")
        print()

    if not args.skip_bench:
        left_bench = summarize_bench(left.binary, "bench", args.bench_depth, args.bench_warmup, args.bench_runs, args.taskset)
        right_bench = summarize_bench(right.binary, "bench", args.bench_depth, args.bench_warmup, args.bench_runs, args.taskset)
        print_bench_comparison(left, left_bench, right, right_bench)

        if not args.skip_benchhce:
            left_benchhce = summarize_bench(
                left.binary,
                "benchhce",
                args.bench_depth,
                args.bench_warmup,
                args.bench_runs,
                args.taskset,
            )
            right_benchhce = summarize_bench(
                right.binary,
                "benchhce",
                args.bench_depth,
                args.bench_warmup,
                args.bench_runs,
                args.taskset,
            )
            print_bench_comparison(left, left_benchhce, right, right_benchhce)

        print()

    for depth in args.perft_depth:
        left_perft = run_perft(left.binary, depth, args.taskset)
        right_perft = run_perft(right.binary, depth, args.taskset)
        print_perft_comparison(left, left_perft, right, right_perft)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
