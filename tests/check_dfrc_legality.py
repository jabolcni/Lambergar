#!/usr/bin/env python3
"""Smoke-test DFRC move generation through the engine UCI interface.

DFRC has independent Chess960 back ranks for White and Black, so exhaustive
coverage is 960 * 960 positions. This script samples deterministic pairs and
then runs random legal walks from sampled DFRC starts.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import random
import re
import subprocess
import sys
from typing import List, Sequence, Tuple


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


def set_dfrc_position(proc: subprocess.Popen[str], white_idx: int, black_idx: int, moves: Sequence[str] = ()) -> None:
    suffix = "" if not moves else " moves " + " ".join(moves)
    write(proc, f"position startposdfrc {white_idx} {black_idx}{suffix}")
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


def sampled_pairs(count: int, seed: int) -> List[Tuple[int, int]]:
    rng = random.Random(seed)
    pairs = {(rng.randrange(960), rng.randrange(960)) for _ in range(count)}
    pairs.update((idx, idx) for idx in (0, 1, 3, 518, 959))
    pairs.update(((0, 959), (959, 0), (3, 518), (518, 3)))
    return sorted(pairs)


def check_pairs(proc: subprocess.Popen[str], pairs: Sequence[Tuple[int, int]]) -> int:
    failures = 0
    total = len(pairs)
    for count, (white_idx, black_idx) in enumerate(pairs, start=1):
        if count % 50 == 1:
            print(f"Checking DFRC starts: {count}/{total}", end="\r", flush=True)
        set_dfrc_position(proc, white_idx, black_idx)
        move_count = validate_position(proc)
        nodes = perft_nodes(proc, 1)
        if move_count != nodes:
            print(
                f"\nDFRC {white_idx}/{black_idx}: validate/perft-1 mismatch: {move_count}/{nodes}",
                file=sys.stderr,
            )
            failures += 1
    print(f"Checking DFRC starts: {total}/{total}")
    return failures


def random_walks(proc: subprocess.Popen[str], pairs: Sequence[Tuple[int, int]], count: int, plies: int, seed: int) -> int:
    rng = random.Random(seed)
    failures = 0
    for walk in range(1, count + 1):
        white_idx, black_idx = rng.choice(pairs)
        played: List[str] = []
        for ply in range(plies + 1):
            set_dfrc_position(proc, white_idx, black_idx, played)
            try:
                validate_position(proc)
            except AssertionError as err:
                print(f"Walk {walk}, DFRC {white_idx}/{black_idx}, ply {ply}: {err}", file=sys.stderr)
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

    pairs = sampled_pairs(args.pair_count, args.seed)
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

        failures = check_pairs(proc, pairs)
        failures += random_walks(proc, pairs, args.walk_count, args.walk_plies, args.seed + 1)

        write(proc, "quit")
        proc.wait(timeout=5)
        if failures:
            print(f"{failures} DFRC legality failures detected.", file=sys.stderr)
            return 1
        print(
            f"DFRC legality smoke test passed "
            f"(pairs={len(pairs)}, walks={args.walk_count}, plies={args.walk_plies}, seed={args.seed})."
        )
        return 0
    finally:
        if proc.poll() is None:
            write(proc, "quit")
            proc.wait(timeout=5)


def main() -> int:
    parser = argparse.ArgumentParser(description="Smoke-test DFRC legality.")
    parser.add_argument("--engine", default=default_engine_path(), help="Path to engine binary.")
    parser.add_argument("--pair-count", type=int, default=256, help="Number of random DFRC start pairs to sample.")
    parser.add_argument("--walk-count", type=int, default=64, help="Number of sampled random DFRC walks.")
    parser.add_argument("--walk-plies", type=int, default=24, help="Number of plies per random walk.")
    parser.add_argument("--seed", type=int, default=20260522, help="Random seed.")
    return run(parser.parse_args())


if __name__ == "__main__":
    raise SystemExit(main())
