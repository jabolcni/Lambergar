#!/usr/bin/env python3
import argparse
import math
import re
import statistics
import subprocess
import sys
from dataclasses import dataclass


INFO_RE = re.compile(
    r"^info depth (\d+) seldepth (\d+) score (?:cp|mate) [^ ]+ nodes (\d+) nps (\d+) time (\d+).*"
)
BESTMOVE_RE = re.compile(r"^bestmove\s+(\S+)")


@dataclass
class SearchResult:
    depth: int
    seldepth: int
    nodes: int
    nps: int
    time_ms: int
    bestmove: str


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


def build_uci_input(fen: str, depth: int, setoptions: list[str]) -> str:
    lines = ["uci"]
    lines.extend(setoptions)
    lines.append("isready")
    if fen.strip().lower() == "startpos":
        lines.append("position startpos")
    else:
        lines.append(f"position fen {fen}")
    lines.append(f"go depth {depth}")
    lines.append("quit")
    return "\n".join(lines) + "\n"


def run_once(
    engine: str,
    fen: str,
    depth: int,
    taskset: str | None,
    setoptions: list[str],
) -> SearchResult:
    cmd: list[str] = []
    if taskset:
        cmd.extend(["taskset", "-c", taskset])
    cmd.append(engine)

    proc = subprocess.run(
        cmd,
        input=build_uci_input(fen, depth, setoptions),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )

    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        raise RuntimeError(f"command failed with exit code {proc.returncode}: {' '.join(cmd)}")

    last_info: tuple[int, int, int, int, int] | None = None
    bestmove: str | None = None

    for raw in proc.stdout.splitlines():
        line = raw.strip()
        m = INFO_RE.match(line)
        if m:
            info_depth = int(m.group(1))
            if info_depth <= depth:
                last_info = (
                    info_depth,
                    int(m.group(2)),
                    int(m.group(3)),
                    int(m.group(4)),
                    int(m.group(5)),
                )
            continue

        m = BESTMOVE_RE.match(line)
        if m:
            bestmove = m.group(1)

    if last_info is None or bestmove is None:
        raise RuntimeError(
            f"could not parse go depth output from: {' '.join(cmd)}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
        )

    return SearchResult(
        depth=last_info[0],
        seldepth=last_info[1],
        nodes=last_info[2],
        nps=last_info[3],
        time_ms=last_info[4],
        bestmove=bestmove,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Run repeated fixed go depth searches and summarize results.")
    parser.add_argument("--engine", default="./zig-out/bin/lambergar", help="Path to engine binary")
    parser.add_argument("--fen", default="startpos", help="FEN to search, or literal 'startpos'")
    parser.add_argument("--depth", type=int, required=True, help="Search depth")
    parser.add_argument("--runs", type=int, default=15, help="Measured runs")
    parser.add_argument("--warmup", type=int, default=2, help="Warmup runs discarded from stats")
    parser.add_argument("--taskset", default=None, help="Optional CPU set for taskset, e.g. 3")
    parser.add_argument(
        "--setoption",
        action="append",
        default=[],
        help="Extra UCI setoption command, e.g. 'setoption name Hash value 128'",
    )
    args = parser.parse_args()

    if args.runs <= 0:
        raise SystemExit("--runs must be positive")
    if args.warmup < 0:
        raise SystemExit("--warmup must be non-negative")

    print(f"engine: {args.engine}")
    print(f"depth: {args.depth}")
    print(f"fen: {args.fen}")
    print(f"warmup: {args.warmup}")
    print(f"runs: {args.runs}")
    if args.taskset:
        print(f"taskset: {args.taskset}")
    if args.setoption:
        print("setoptions:")
        for opt in args.setoption:
            print(f"  {opt}")
    print()

    for i in range(args.warmup):
        result = run_once(args.engine, args.fen, args.depth, args.taskset, args.setoption)
        print(
            f"warmup {i + 1:>2}: depth={result.depth} seldepth={result.seldepth} "
            f"nodes={result.nodes} nps={result.nps} time_ms={result.time_ms} bestmove={result.bestmove}"
        )

    measured: list[SearchResult] = []
    for i in range(args.runs):
        result = run_once(args.engine, args.fen, args.depth, args.taskset, args.setoption)
        measured.append(result)
        print(
            f"run    {i + 1:>2}: depth={result.depth} seldepth={result.seldepth} "
            f"nodes={result.nodes} nps={result.nps} time_ms={result.time_ms} bestmove={result.bestmove}"
        )

    print()
    nodes_stats = summarize([r.nodes for r in measured])
    nps_stats = summarize([r.nps for r in measured])
    time_stats = summarize([r.time_ms for r in measured])

    bestmoves: dict[str, int] = {}
    for r in measured:
        bestmoves[r.bestmove] = bestmoves.get(r.bestmove, 0) + 1

    print("nodes:")
    print(f"  mean   {nodes_stats['mean']:.2f}")
    print(f"  median {nodes_stats['median']:.2f}")
    print(f"  stdev  {nodes_stats['stdev']:.2f}")
    print(f"  95% CI +/- {nodes_stats['ci95']:.2f}")
    print(f"  min    {int(nodes_stats['min'])}")
    print(f"  max    {int(nodes_stats['max'])}")
    print()
    print("nps:")
    print(f"  mean   {nps_stats['mean']:.2f}")
    print(f"  median {nps_stats['median']:.2f}")
    print(f"  stdev  {nps_stats['stdev']:.2f}")
    print(f"  95% CI +/- {nps_stats['ci95']:.2f}")
    print(f"  min    {int(nps_stats['min'])}")
    print(f"  max    {int(nps_stats['max'])}")
    print()
    print("time_ms:")
    print(f"  mean   {time_stats['mean']:.2f}")
    print(f"  median {time_stats['median']:.2f}")
    print(f"  stdev  {time_stats['stdev']:.2f}")
    print(f"  95% CI +/- {time_stats['ci95']:.2f}")
    print(f"  min    {int(time_stats['min'])}")
    print(f"  max    {int(time_stats['max'])}")
    print()
    print("bestmove frequencies:")
    for move, count in sorted(bestmoves.items(), key=lambda kv: (-kv[1], kv[0])):
        print(f"  {move}: {count}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
