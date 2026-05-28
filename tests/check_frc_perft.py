#!/usr/bin/env python3
"""Run FRC/Chess960 perft positions from a CSV file and compare node counts."""

from __future__ import annotations

import argparse
import csv
import os
import pathlib
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import Dict, List


PERFT_RE = re.compile(r"^(\d+) nodes explored$")


@dataclass(frozen=True)
class PerftCase:
    position_id: str
    fen: str
    expected_by_depth: Dict[int, int]


def default_engine_path() -> str:
    if os.name == "nt":
        return str(pathlib.Path(__file__).resolve().parents[1] / "zig-out" / "bin" / "lambergar.exe")
    return str(pathlib.Path(__file__).resolve().parents[1] / "zig-out" / "bin" / "lambergar")


def default_csv_path() -> str:
    return str(pathlib.Path(__file__).with_name("frc_perft.csv"))


def read_until(proc: subprocess.Popen[str], predicate) -> str:
    while True:
        line = proc.stdout.readline()
        if line == "":
            raise RuntimeError("Engine terminated unexpectedly")
        line = line.rstrip("\r\n")
        if predicate(line):
            return line


def write(proc: subprocess.Popen[str], command: str) -> None:
    proc.stdin.write(command + "\n")
    proc.stdin.flush()


def ensure_ready(proc: subprocess.Popen[str]) -> None:
    write(proc, "isready")
    read_until(proc, lambda line: line == "readyok")


def load_cases(csv_path: pathlib.Path) -> List[PerftCase]:
    cases: List[PerftCase] = []
    with csv_path.open(newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh)
        if not reader.fieldnames:
            raise ValueError(f"{csv_path} has no header")

        depth_columns = []
        for name in reader.fieldnames:
            if name.startswith("Depth "):
                depth_columns.append((int(name.split()[1]), name))
            elif name.startswith("Depth") and name[len("Depth") :].isdigit():
                depth_columns.append((int(name[len("Depth") :]), name))

        for row_num, row in enumerate(reader, start=2):
            fen = (row.get("Shredder FEN") or row.get("Position") or "").strip()
            position_id = (row.get("Position ID") or row.get("#") or str(row_num)).strip()
            if not fen:
                continue

            expected_by_depth: Dict[int, int] = {}
            for depth, column in depth_columns:
                raw = (row.get(column) or "").strip()
                if raw:
                    expected_by_depth[depth] = int(raw)
            cases.append(PerftCase(position_id, fen, expected_by_depth))
    return cases


def set_position(proc: subprocess.Popen[str], fen: str) -> None:
    write(proc, f"position fen {fen}")
    # Invalid FEN is reported as "info string Invalid FEN: ..."; otherwise no
    # output is guaranteed, so synchronize with isready.
    write(proc, "isready")
    line = read_until(proc, lambda line: line == "readyok" or line.startswith("info string Invalid FEN:"))
    if line.startswith("info string Invalid FEN:"):
        raise ValueError(line)


def perft_nodes(proc: subprocess.Popen[str], depth: int) -> int:
    write(proc, f"perft {depth}")
    line = read_until(proc, lambda line: PERFT_RE.match(line) is not None)
    return int(PERFT_RE.match(line).group(1))


def run_cases(proc: subprocess.Popen[str], cases: List[PerftCase], max_depth: int, stop_on_fail: bool) -> int:
    failures = 0
    checks = 0
    for case_index, case in enumerate(cases, start=1):
        depths = [depth for depth in sorted(case.expected_by_depth) if depth <= max_depth]
        if not depths:
            continue

        print(f"[{case_index}/{len(cases)}] Position {case.position_id}", end="\r", flush=True)
        try:
            set_position(proc, case.fen)
        except ValueError as err:
            print(f"\nPosition {case.position_id}: {err}\n  FEN: {case.fen}", file=sys.stderr)
            failures += len(depths)
            if stop_on_fail:
                break
            continue

        for depth in depths:
            expected = case.expected_by_depth[depth]
            actual = perft_nodes(proc, depth)
            checks += 1
            if actual != expected:
                print(
                    f"\nPosition {case.position_id}, depth {depth}: expected {expected}, got {actual}\n"
                    f"  FEN: {case.fen}",
                    file=sys.stderr,
                )
                failures += 1
                if stop_on_fail:
                    print()
                    return failures

    print(f"Checked {checks} perft values across {len(cases)} positions.")
    return failures


def run(args: argparse.Namespace) -> int:
    csv_path = pathlib.Path(args.csv)
    if not csv_path.is_file():
        print(f"CSV file not found: {csv_path}", file=sys.stderr)
        return 1
    if not os.path.isfile(args.engine):
        print(f"Engine binary not found: {args.engine}", file=sys.stderr)
        return 1

    cases = load_cases(csv_path)
    if args.limit is not None:
        cases = cases[: args.limit]

    proc = subprocess.Popen(
        [args.engine],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    assert proc.stdin and proc.stdout

    try:
        write(proc, "uci")
        read_until(proc, lambda line: line == "uciok")
        write(proc, "setoption name UCI_Chess960 value true")
        ensure_ready(proc)

        failures = run_cases(proc, cases, args.max_depth, args.stop_on_fail)
        write(proc, "quit")
        proc.wait(timeout=5)

        if failures:
            print(f"{failures} FRC perft mismatches detected.", file=sys.stderr)
            return 1
        print(f"FRC perft CSV passed: {csv_path} (positions={len(cases)}, max_depth={args.max_depth}).")
        return 0
    finally:
        if proc.poll() is None:
            write(proc, "quit")
            proc.wait(timeout=5)


def main() -> int:
    parser = argparse.ArgumentParser(description="Run FRC perft checks from a CSV file.")
    parser.add_argument("--engine", default=default_engine_path(), help="Path to engine binary.")
    parser.add_argument("--csv", default=default_csv_path(), help="CSV containing Shredder FEN and depth columns.")
    parser.add_argument("--max-depth", type=int, default=4, help="Highest CSV depth to test.")
    parser.add_argument("--limit", type=int, default=None, help="Only test the first N positions.")
    parser.add_argument("--stop-on-fail", action="store_true", help="Stop at the first mismatch or invalid FEN.")
    return run(parser.parse_args())


if __name__ == "__main__":
    raise SystemExit(main())
