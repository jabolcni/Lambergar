#!/usr/bin/env python3
"""Verify a sample of DFRC (Double Fischer Random) start positions."""

from __future__ import annotations

import argparse
import csv
import os
import pathlib
import random
import subprocess
import sys
from typing import Dict, Iterable, List, Tuple


def default_engine_path() -> str:
    if os.name == "nt":
        return str(pathlib.Path(__file__).resolve().parents[1] / "lamb.exe")
    return str(pathlib.Path(__file__).resolve().parents[1] / "lambergar-x86_64-linux-AVX2")


def read_until(proc: subprocess.Popen[str], predicate) -> str:
    while True:
        line = proc.stdout.readline()
        if line == "":
            raise RuntimeError("Engine terminated unexpectedly")
        line = line.rstrip("\r\n")
        if predicate(line):
            return line


def ensure_ready(proc: subprocess.Popen[str]) -> None:
    proc.stdin.write("isready\n")
    proc.stdin.flush()
    read_until(proc, lambda l: l == "readyok")


def fetch_rank_line(proc: subprocess.Popen[str], white_idx: int, black_idx: int) -> str:
    proc.stdin.write(f"position startposdfrc {white_idx} {black_idx}\n")
    proc.stdin.flush()
    return read_until(proc, lambda l: l.startswith("info string "))[len("info string ") :]


def parse_csv(csv_path: pathlib.Path) -> Dict[int, Tuple[str, str]]:
    mapping: Dict[int, Tuple[str, str]] = {}
    with csv_path.open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh, delimiter=";")
        for row in reader:
            idx = int(row["SP"])
            mapping[idx] = (row["White"], row["Black"])
    if len(mapping) != 960:
        print(f"Warning: expected 960 entries in {csv_path}, found {len(mapping)}", file=sys.stderr)
    return mapping


def run_check(
    engine_path: str,
    mapping: Dict[int, Tuple[str, str]],
    pairs: Iterable[Tuple[int, int]],
) -> int:
    pair_list = list(pairs)
    proc = subprocess.Popen(
        [engine_path],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    assert proc.stdin and proc.stdout

    try:
        proc.stdin.write("uci\n")
        proc.stdin.flush()
        read_until(proc, lambda l: l == "uciok")
        ensure_ready(proc)

        mismatches = 0
        total = len(pair_list)
        for index, (white_idx, black_idx) in enumerate(pair_list, start=1):
            print(f"[{index}/{total}] Checking w={white_idx} b={black_idx}...", end="\r", flush=True)
            ensure_ready(proc)
            actual = fetch_rank_line(proc, white_idx, black_idx)
            parts = actual.split()
            if len(parts) != 2:
                print(f"\nUnexpected info string '{actual}' for w={white_idx} b={black_idx}", file=sys.stderr)
                mismatches += 1
                continue
            white_rank, black_rank = parts
            exp_white, _ = mapping.get(white_idx, ("", ""))
            _, exp_black = mapping.get(black_idx, ("", ""))
            # print(
            #     f"\nTest for w={white_idx} b={black_idx}: "
            #     f"expected {exp_white}/{exp_black}, got {white_rank}/{black_rank}",
            #     file=sys.stderr,
            # )            
            if white_rank != exp_white or black_rank != exp_black:
                print(
                    f"\nMismatch for w={white_idx} b={black_idx}: "
                    f"expected {exp_white}/{exp_black}, got {white_rank}/{black_rank}",
                    file=sys.stderr,
                )
                mismatches += 1
        print()
        proc.stdin.write("quit\n")
        proc.stdin.flush()
        return mismatches
    finally:
        proc.wait(timeout=5)


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate sampled DFRC starting positions.")
    parser.add_argument(
        "--engine",
        default=default_engine_path(),
        help="Path to the engine binary (default: %(default)s)",
    )
    parser.add_argument(
        "--csv",
        default=str(pathlib.Path(__file__).with_name("startposfrc.csv")),
        help="CSV file containing Chess960 reference positions (default: %(default)s)",
    )
    parser.add_argument(
        "--count",
        type=int,
        default=100,
        help="Number of DFRC pairs to test (default: %(default)s)",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=42,
        help="Random seed for pair generation (default: %(default)s)",
    )
    args = parser.parse_args()

    csv_path = pathlib.Path(args.csv)
    if not csv_path.is_file():
        print(f"CSV file not found: {csv_path}", file=sys.stderr)
        return 1
    if not os.path.isfile(args.engine):
        print(f"Engine binary not found: {args.engine}", file=sys.stderr)
        return 1

    mapping = parse_csv(csv_path)
    rng = random.Random(args.seed)
    pairs = [(rng.randrange(960), rng.randrange(960)) for _ in range(args.count)]

    print(f"Engine: {args.engine}")
    print(f"CSV: {csv_path}")
    print(f"Testing {len(pairs)} DFRC pairs (seed={args.seed})")
    mismatches = run_check(args.engine, mapping, pairs)
    if mismatches:
        print(f"{mismatches} mismatches detected.", file=sys.stderr)
        return 1
    print("All sampled DFRC starting positions match the reference.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
