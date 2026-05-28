#!/usr/bin/env python3
"""Smoke-test Chess960 move generation through the engine UCI interface.

This test deliberately has no third-party Python dependency. It verifies
invariants that should hold for every Chess960 start, then runs sampled random
walks using the engine's own legal move list and validates every reached node.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import random
import re
import subprocess
import sys
from typing import Iterable, List, Sequence


MOVE_RE = re.compile(r"\b([a-h][1-8][a-h][1-8][nbrq]?)\b")
PERFT_RE = re.compile(r"^(\d+) nodes explored$")
VALIDATE_RE = re.compile(r"^OK \((\d+) moves\)$")


def default_engine_path() -> str:
    if os.name == "nt":
        return str(pathlib.Path(__file__).resolve().parents[1] / "zig-out" / "bin" / "lambergar.exe")
    return str(pathlib.Path(__file__).resolve().parents[1] / "zig-out" / "bin" / "lambergar")


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


def set_frc_position(proc: subprocess.Popen[str], idx: int, moves: Sequence[str] = ()) -> None:
    suffix = "" if not moves else " moves " + " ".join(moves)
    write(proc, f"position startposfrc {idx}{suffix}")
    read_until(proc, lambda line: line.startswith("info string "))


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


def legal_moves(proc: subprocess.Popen[str]) -> List[str]:
    write(proc, "moves")
    write(proc, "isready")

    moves: List[str] = []
    while True:
        line = proc.stdout.readline()
        if line == "":
            raise RuntimeError("Engine terminated unexpectedly")
        line = line.rstrip("\r\n")
        if line == "readyok":
            break
        if line.startswith("is_chess960:"):
            continue
        moves.extend(MOVE_RE.findall(line))
    return moves


def check_all_starts(proc: subprocess.Popen[str], indices: Iterable[int]) -> int:
    failures = 0
    for count, idx in enumerate(indices, start=1):
        if count % 50 == 1:
            print(f"Checking FRC starts: {count}/960", end="\r", flush=True)
        set_frc_position(proc, idx)
        move_count = validate_position(proc)
        nodes = perft_nodes(proc, 1)
        if move_count != nodes:
            print(f"\nFRC {idx}: validate/perft-1 mismatch: {move_count}/{nodes}", file=sys.stderr)
            failures += 1
    print("Checking FRC starts: 960/960")
    return failures


def random_walks(proc: subprocess.Popen[str], count: int, plies: int, seed: int) -> int:
    rng = random.Random(seed)
    failures = 0
    for walk in range(1, count + 1):
        idx = rng.randrange(960)
        played: List[str] = []
        for ply in range(plies + 1):
            set_frc_position(proc, idx, played)
            try:
                validate_position(proc)
            except AssertionError as err:
                print(f"Walk {walk}, FRC {idx}, ply {ply}: {err}", file=sys.stderr)
                failures += 1
                break
            if ply == plies:
                break
            moves = legal_moves(proc)
            if not moves:
                break
            played.append(rng.choice(moves))
    return failures


def run(args: argparse.Namespace) -> int:
    if not os.path.isfile(args.engine):
        print(f"Engine binary not found: {args.engine}", file=sys.stderr)
        return 1

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

        failures = 0
        if not args.skip_all_starts:
            failures += check_all_starts(proc, range(960))
        failures += random_walks(proc, args.walk_count, args.walk_plies, args.seed)

        write(proc, "quit")
        proc.wait(timeout=5)
        if failures:
            print(f"{failures} FRC legality failures detected.", file=sys.stderr)
            return 1
        print(
            f"FRC legality smoke test passed "
            f"(all_starts={not args.skip_all_starts}, walks={args.walk_count}, plies={args.walk_plies}, seed={args.seed})."
        )
        return 0
    finally:
        if proc.poll() is None:
            write(proc, "quit")
            proc.wait(timeout=5)


def main() -> int:
    parser = argparse.ArgumentParser(description="Smoke-test Chess960/FRC legality.")
    parser.add_argument("--engine", default=default_engine_path(), help="Path to engine binary.")
    parser.add_argument("--skip-all-starts", action="store_true", help="Skip the all-960 start-position invariant check.")
    parser.add_argument("--walk-count", type=int, default=64, help="Number of sampled random FRC walks.")
    parser.add_argument("--walk-plies", type=int, default=24, help="Number of plies per random walk.")
    parser.add_argument("--seed", type=int, default=20260522, help="Random seed.")
    return run(parser.parse_args())


if __name__ == "__main__":
    raise SystemExit(main())
