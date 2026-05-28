#!/usr/bin/env python3
"""Validate DFRC analysis JSON move lines against the engine."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import subprocess
import sys
from typing import Any, Iterable, List, Sequence, Tuple


MOVE_RE = re.compile(r"\b([a-h][1-8][a-h][1-8][nbrq]?)\b")
VALIDATE_RE = re.compile(r"^OK \((\d+) moves\)$")


def default_engine_path() -> str:
    if os.name == "nt":
        return str(pathlib.Path(__file__).resolve().parents[1] / "zig-out" / "bin" / "lambergar.exe")
    return str(pathlib.Path(__file__).resolve().parents[1] / "zig-out" / "bin" / "lambergar")


def default_json_path() -> str:
    return str(pathlib.Path(__file__).with_name("dfrc_positions.json"))


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


def set_dfrc_position(proc: subprocess.Popen[str], white_id: int, black_id: int, moves: Sequence[str] = ()) -> None:
    suffix = "" if not moves else " moves " + " ".join(moves)
    write(proc, f"position startposdfrc {white_id} {black_id}{suffix}")
    read_until(proc, lambda line: line.startswith("info string "))


def validate_position(proc: subprocess.Popen[str]) -> int:
    write(proc, "validate")
    line = read_until(proc, lambda line: line.startswith("OK (") or line.startswith("Found "))
    match = VALIDATE_RE.match(line)
    if not match:
        raise AssertionError(line)
    return int(match.group(1))


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


def load_positions(path: pathlib.Path) -> List[dict[str, Any]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, list):
        raise ValueError(f"{path} must contain a JSON array")
    return data


def iter_tree_paths(node: dict[str, Any], prefix: Sequence[str] = ()) -> Iterable[List[str]]:
    children = node.get("children") or []
    for child in children:
        move = child.get("move")
        if not isinstance(move, str) or move == "root":
            continue
        path = [*prefix, move]
        yield path
        yield from iter_tree_paths(child, path)


def candidate_lines(position: dict[str, Any], include_tree: bool) -> List[Tuple[str, List[str]]]:
    tree = position.get("analysis_tree") or {}
    lines: List[Tuple[str, List[str]]] = []

    if include_tree:
        for path in iter_tree_paths(tree):
            lines.append(("tree", path))

    pv = ((tree.get("analysis") or {}).get("pv") or [])
    if isinstance(pv, list) and all(isinstance(move, str) for move in pv):
        lines.append(("root-pv", list(pv)))

    return lines


def check_line(
    proc: subprocess.Popen[str],
    white_id: int,
    black_id: int,
    line: Sequence[str],
    context: str,
) -> Tuple[bool, str]:
    played: List[str] = []
    for ply, move in enumerate(line, start=1):
        set_dfrc_position(proc, white_id, black_id, played)
        moves = set(legal_moves(proc))
        if move not in moves:
            return False, f"{context}: illegal move at ply {ply}: {move}; legal count={len(moves)}"
        played.append(move)
        set_dfrc_position(proc, white_id, black_id, played)
        validate_position(proc)
    return True, ""


def run_positions(proc: subprocess.Popen[str], positions: List[dict[str, Any]], args: argparse.Namespace) -> int:
    failures = 0
    checked_lines = 0
    checked_moves = 0

    for index, position in enumerate(positions, start=1):
        params = position.get("params") or {}
        white_id = int(params["white_id"])
        black_id = int(params["black_id"])
        dfrc_id = str(position.get("dfrc_id") or f"{white_id}/{black_id}")
        lines = candidate_lines(position, args.include_tree)
        if args.max_lines_per_position is not None:
            lines = lines[: args.max_lines_per_position]

        print(f"[{index}/{len(positions)}] DFRC {dfrc_id}", end="\r", flush=True)
        set_dfrc_position(proc, white_id, black_id)
        validate_position(proc)

        for kind, line in lines:
            if not line:
                continue
            if args.max_plies is not None:
                line = line[: args.max_plies]
            context = f"DFRC {dfrc_id} {kind}"
            ok, message = check_line(proc, white_id, black_id, line, context)
            checked_lines += 1
            checked_moves += len(line)
            if not ok:
                print(f"\n{message}", file=sys.stderr)
                failures += 1
                if args.stop_on_fail:
                    print()
                    return failures

    print(f"Checked {checked_lines} DFRC JSON lines and {checked_moves} moves across {len(positions)} positions.")
    return failures


def run(args: argparse.Namespace) -> int:
    json_path = pathlib.Path(args.json)
    if not json_path.is_file():
        print(f"JSON file not found: {json_path}", file=sys.stderr)
        return 1
    if not os.path.isfile(args.engine):
        print(f"Engine binary not found: {args.engine}", file=sys.stderr)
        return 1

    positions = load_positions(json_path)
    if args.limit is not None:
        positions = positions[: args.limit]

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

        failures = run_positions(proc, positions, args)
        write(proc, "quit")
        proc.wait(timeout=5)

        if failures:
            print(f"{failures} DFRC JSON failures detected.", file=sys.stderr)
            return 1
        print(f"DFRC JSON test passed: {json_path} (positions={len(positions)}).")
        return 0
    finally:
        if proc.poll() is None:
            write(proc, "quit")
            proc.wait(timeout=5)


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate DFRC JSON analysis move lines.")
    parser.add_argument("--engine", default=default_engine_path(), help="Path to engine binary.")
    parser.add_argument("--json", default=default_json_path(), help="Combined DFRC JSON fixture.")
    parser.add_argument("--include-tree", action="store_true", help="Also validate raw analysis_tree child paths.")
    parser.add_argument("--max-plies", type=int, default=None, help="Limit checked plies per line.")
    parser.add_argument("--max-lines-per-position", type=int, default=None, help="Limit checked lines per DFRC position.")
    parser.add_argument("--limit", type=int, default=None, help="Only test the first N positions.")
    parser.add_argument("--stop-on-fail", action="store_true", help="Stop at the first illegal move.")
    return run(parser.parse_args())


if __name__ == "__main__":
    raise SystemExit(main())
