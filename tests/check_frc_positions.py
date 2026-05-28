#!/usr/bin/env python3
"""Verify Chess960 start positions against a CSV reference by driving the engine over UCI."""

from __future__ import annotations

import argparse
import csv
import os
import pathlib
import subprocess
import sys
from typing import Iterable, List, Tuple


def default_engine_path() -> str:
    """Return a reasonable default engine binary path based on platform."""
    if os.name == "nt":
        return str(pathlib.Path(__file__).resolve().parents[1] / "lamb.exe")
    return str(pathlib.Path(__file__).resolve().parents[1] / "lambergar-x86_64-linux-AVX2")


def read_until(proc: subprocess.Popen[str], predicate) -> str:
    """Read lines from engine stdout until predicate(line) is true; return matching line."""
    while True:
        line = proc.stdout.readline()
        if line == "":
            raise RuntimeError("Engine terminated unexpectedly")
        line = line.rstrip("\r\n")
        if predicate(line):
            return line


def ensure_ready(proc: subprocess.Popen[str]) -> None:
    """Send `isready` and wait for `readyok` to ensure synchronization."""
    proc.stdin.write("isready\n")
    proc.stdin.flush()
    read_until(proc, lambda l: l == "readyok")


def fetch_rank_line(proc: subprocess.Popen[str], idx: int) -> str:
    """Issue startposfrc command and capture the emitted rank string."""
    print(f"position startposfrc {idx}")
    proc.stdin.write(f"position startposfrc {idx}\n")
    proc.stdin.flush()
    line = read_until(proc, lambda l: l.startswith("info string "))
    return line[len("info string ") :]


def parse_csv(csv_path: pathlib.Path) -> List[Tuple[int, str, str]]:
    """Load the CSV mapping of indices to rank strings."""
    entries: List[Tuple[int, str, str]] = []
    with csv_path.open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh, delimiter=";")
        for row in reader:
            entries.append((int(row["SP"]), row["White"], row["Black"]))
    return entries


def run_check(engine_path: str, entries: Iterable[Tuple[int, str, str]]) -> int:
    """Run through each entry, verifying engine output. Returns mismatch count."""
    entry_list = list(entries)
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
        total = len(entry_list)
        for index, (idx, exp_white, exp_black) in enumerate(entry_list, start=1):
            print(f"[{index}/{total}] Checking index {idx}...", end="\r", flush=True)
            ensure_ready(proc)  # keep command boundaries clean
            actual = fetch_rank_line(proc, idx)
            parts = actual.split()
            if len(parts) != 2:
                print(f"Index {idx}: unexpected info string '{actual}'", file=sys.stderr)
                mismatches += 1
                continue
            white_rank, black_rank = parts
            print(
                f"Index {idx}: expected {exp_white}/{exp_black}, got {white_rank}/{black_rank}",
                file=sys.stderr,
            )            
            if white_rank != exp_white or black_rank != exp_black:
                print(
                    f"Index {idx}: expected {exp_white}/{exp_black}, got {white_rank}/{black_rank}",
                    file=sys.stderr,
                )
                mismatches += 1
        print()  # newline after progress carriage returns
        proc.stdin.write("quit\n")
        proc.stdin.flush()
        return mismatches
    finally:
        proc.wait(timeout=5)


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate Chess960 start positions.")
    parser.add_argument(
        "--engine",
        default=default_engine_path(),
        help="Path to the engine binary (default: %(default)s)",
    )
    parser.add_argument(
        "--csv",
        default=str(pathlib.Path(__file__).with_name("startposfrc.csv")),
        help="CSV file containing reference positions (default: %(default)s)",
    )
    args = parser.parse_args()

    csv_path = pathlib.Path(args.csv)
    if not csv_path.is_file():
        print(f"CSV file not found: {csv_path}", file=sys.stderr)
        return 1
    if not os.path.isfile(args.engine):
        print(f"Engine binary not found: {args.engine}", file=sys.stderr)
        return 1

    entries = parse_csv(csv_path)
    print(f"Engine: {args.engine}")
    print(f"CSV: {csv_path}")
    mismatches = run_check(args.engine, entries)
    if mismatches:
        print(f"{mismatches} mismatches detected.", file=sys.stderr)
        return 1
    print("All Chess960 starting positions match the reference.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
