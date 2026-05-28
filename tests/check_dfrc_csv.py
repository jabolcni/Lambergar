#!/usr/bin/env python3
"""Validate DFRC positions listed in dfrc.csv against the engine."""

from __future__ import annotations

import argparse
import csv
import os
import pathlib
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import List


PERFT_RE = re.compile(r"^(\d+) nodes explored$")
VALIDATE_RE = re.compile(r"^OK \((\d+) moves\)$")


@dataclass(frozen=True)
class DfrcCase:
    dfrc_id: str
    white_id: int
    black_id: int
    white: str
    black: str


def default_engine_path() -> str:
    if os.name == "nt":
        return str(pathlib.Path(__file__).resolve().parents[1] / "zig-out" / "bin" / "lambergar.exe")
    return str(pathlib.Path(__file__).resolve().parents[1] / "zig-out" / "bin" / "lambergar")


def default_csv_path() -> str:
    return str(pathlib.Path(__file__).with_name("dfrc.csv"))


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


def load_cases(csv_path: pathlib.Path) -> List[DfrcCase]:
    cases: List[DfrcCase] = []
    with csv_path.open(newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh)
        required = {"dfrc_id", "white_id", "black_id", "white", "black"}
        missing = required.difference(reader.fieldnames or ())
        if missing:
            raise ValueError(f"{csv_path} is missing required columns: {', '.join(sorted(missing))}")

        for row_num, row in enumerate(reader, start=2):
            try:
                cases.append(
                    DfrcCase(
                        dfrc_id=(row["dfrc_id"] or str(row_num)).strip(),
                        white_id=int(row["white_id"]),
                        black_id=int(row["black_id"]),
                        white=row["white"].strip(),
                        black=row["black"].strip(),
                    )
                )
            except (KeyError, ValueError) as err:
                raise ValueError(f"Invalid row {row_num}: {err}") from err
    return cases


def set_dfrc_position(proc: subprocess.Popen[str], case: DfrcCase) -> tuple[str, str]:
    write(proc, f"position startposdfrc {case.white_id} {case.black_id}")
    line = read_until(proc, lambda line: line.startswith("info string "))
    parts = line[len("info string ") :].split()
    if len(parts) != 2:
        raise AssertionError(f"unexpected startposdfrc response: {line}")
    return parts[0], parts[1]


def validate_position(proc: subprocess.Popen[str]) -> int:
    write(proc, "validate")
    line = read_until(proc, lambda line: line.startswith("OK (") or line.startswith("Found "))
    match = VALIDATE_RE.match(line)
    if not match:
        raise AssertionError(line)
    return int(match.group(1))


def perft_nodes(proc: subprocess.Popen[str], depth: int) -> int:
    write(proc, f"perft {depth}")
    line = read_until(proc, lambda line: PERFT_RE.match(line) is not None)
    return int(PERFT_RE.match(line).group(1))


def run_cases(proc: subprocess.Popen[str], cases: List[DfrcCase], perft_depth: int, stop_on_fail: bool) -> int:
    failures = 0
    checks = 0
    for case_index, case in enumerate(cases, start=1):
        print(f"[{case_index}/{len(cases)}] DFRC {case.dfrc_id}", end="\r", flush=True)
        try:
            actual_white, actual_black = set_dfrc_position(proc, case)
            if actual_white != case.white.upper() or actual_black != case.black.lower():
                print(
                    f"\nDFRC {case.dfrc_id}: expected ranks {case.white.upper()}/{case.black.lower()}, "
                    f"got {actual_white}/{actual_black}",
                    file=sys.stderr,
                )
                failures += 1
                if stop_on_fail:
                    return failures

            validate_count = validate_position(proc)
            perft_count = perft_nodes(proc, 1)
            checks += 1
            if validate_count != perft_count:
                print(
                    f"\nDFRC {case.dfrc_id}: validate/perft-1 mismatch {validate_count}/{perft_count}",
                    file=sys.stderr,
                )
                failures += 1
                if stop_on_fail:
                    return failures

            for depth in range(2, perft_depth + 1):
                _ = perft_nodes(proc, depth)
                checks += 1
        except AssertionError as err:
            print(f"\nDFRC {case.dfrc_id}: {err}", file=sys.stderr)
            failures += 1
            if stop_on_fail:
                return failures
    print(f"Checked {checks} DFRC perft/legality values across {len(cases)} positions.")
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

        failures = run_cases(proc, cases, args.perft_depth, args.stop_on_fail)
        write(proc, "quit")
        proc.wait(timeout=5)

        if failures:
            print(f"{failures} DFRC CSV failures detected.", file=sys.stderr)
            return 1
        print(f"DFRC CSV test passed: {csv_path} (positions={len(cases)}, perft_depth={args.perft_depth}).")
        return 0
    finally:
        if proc.poll() is None:
            write(proc, "quit")
            proc.wait(timeout=5)


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate DFRC positions from dfrc.csv.")
    parser.add_argument("--engine", default=default_engine_path(), help="Path to engine binary.")
    parser.add_argument("--csv", default=default_csv_path(), help="CSV containing DFRC metadata.")
    parser.add_argument("--perft-depth", type=int, default=1, help="Run perft through this depth for each position.")
    parser.add_argument("--limit", type=int, default=None, help="Only test the first N positions.")
    parser.add_argument("--stop-on-fail", action="store_true", help="Stop at the first failure.")
    return run(parser.parse_args())


if __name__ == "__main__":
    raise SystemExit(main())
