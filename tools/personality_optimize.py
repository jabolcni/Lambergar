#!/usr/bin/env python3

import argparse
import json
import math
import random
import statistics
import subprocess
import sys
from pathlib import Path
from typing import List, Optional, Tuple

import chess
import chess.pgn
import optuna


def load_positions(pgn_path: Path, limit: Optional[int], seed: int) -> List[Tuple[str, str]]:
    rng = random.Random(seed)
    positions: List[Tuple[str, str]] = []
    with pgn_path.open("r", encoding="utf-8") as handle:
        while True:
            game = chess.pgn.read_game(handle)
            if game is None:
                break
            board = game.board()
            for move in game.mainline_moves():
                fen = board.fen()
                positions.append((fen, move.uci()))
                board.push(move)
    if limit is not None and len(positions) > limit:
        positions = rng.sample(positions, limit)
    return positions


class UciEngine:
    def __init__(self, exe: Path) -> None:
        self.proc = subprocess.Popen(
            [str(exe)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        if self.proc.stdin is None or self.proc.stdout is None:
            raise RuntimeError("failed to launch engine")
        self._stdin = self.proc.stdin
        self._stdout = self.proc.stdout
        self._init()

    def _write(self, cmd: str) -> None:
        self._stdin.write(cmd + "\n")
        self._stdin.flush()

    def _readline(self) -> str:
        line = self._stdout.readline()
        if line == "":
            raise RuntimeError("engine terminated unexpectedly")
        return line.strip()

    def _expect(self, token: str) -> None:
        while True:
            if self._readline() == token:
                return

    def _init(self) -> None:
        self._write("uci")
        self._expect("uciok")
        self.is_ready()

    def quit(self) -> None:
        try:
            self._write("quit")
        except BrokenPipeError:
            pass
        self.proc.wait(timeout=2)

    def is_ready(self) -> None:
        self._write("isready")
        self._expect("readyok")

    def set_personality(self, params: dict) -> None:
        for name in (
            "PersonalityPawnScale",
            "PersonalityMobilityScale",
            "PersonalityKingScale",
            "PersonalityThreatScale",
            "PersonalityMaterialScale",
        ):
            self._write(f"setoption name {name} value {params[name]}")
        self._write(f"setoption name PersonalityMgOffset value {int(params['PersonalityMgOffset'])}")
        self._write(f"setoption name PersonalityEgOffset value {int(params['PersonalityEgOffset'])}")
        self._write("setoption name Personality value custom")
        self.is_ready()

    def search(self, fen: str, depth: int, searchmoves: Optional[List[str]] = None) -> Tuple[Optional[str], Optional[int]]:
        self._write(f"position fen {fen}")
        if searchmoves:
            cmd = f"go depth {depth} searchmoves {' '.join(searchmoves)}"
        else:
            cmd = f"go depth {depth}"
        self._write(cmd)
        best_move: Optional[str] = None
        last_score: Optional[int] = None
        while True:
            line = self._readline()
            if line.startswith("info "):
                parts = line.split()
                if "score" in parts:
                    idx = parts.index("score")
                    if idx + 2 < len(parts):
                        kind = parts[idx + 1]
                        value = parts[idx + 2]
                        if kind == "cp":
                            try:
                                last_score = int(value)
                            except ValueError:
                                pass
                        elif kind == "mate":
                            try:
                                mate_moves = int(value)
                                sign = 1 if mate_moves > 0 else -1
                                last_score = sign * (32000 - 100 * abs(mate_moves))
                            except ValueError:
                                pass
            elif line.startswith("bestmove"):
                tokens = line.split()
                if len(tokens) >= 2:
                    best_move = tokens[1]
                break
        return best_move, last_score


def evaluate_personality(
    engine: UciEngine,
    params: dict,
    positions: List[Tuple[str, str]],
    depth: int,
    align_cap: int,
) -> Tuple[float, float, float]:
    engine.set_personality(params)
    matches = 0
    usable = 0
    align_scores: List[float] = []
    for fen, target_move in positions:
        best_move, best_score = engine.search(fen, depth)
        if best_move is None or best_score is None:
            continue
        vidmar_score = engine.search(fen, depth, [target_move])[1]
        if vidmar_score is None:
            continue
        usable += 1
        if best_move == target_move:
            matches += 1
        diff = min(abs(best_score - vidmar_score), align_cap)
        align_scores.append(1.0 - diff / align_cap)
    if usable == 0:
        return 0.0, 0.0, 0.0
    match_rate = matches / usable
    alignment = statistics.fmean(align_scores) if align_scores else 0.0
    base_params = {
        "PersonalityPawnScale": 1.0,
        "PersonalityMobilityScale": 1.0,
        "PersonalityKingScale": 1.0,
        "PersonalityThreatScale": 1.0,
        "PersonalityMaterialScale": 1.0,
        "PersonalityMgOffset": 0.0,
        "PersonalityEgOffset": 0.0,
    }
    reg_sum = 0.0
    for key, base in base_params.items():
        reg_sum += abs(params[key] - base)
    regularizer = math.exp(-0.5 * reg_sum)
    return match_rate, alignment, regularizer


def main() -> None:
    parser = argparse.ArgumentParser(description="Optimize Lambergar personality parameters for Vidmar style.")
    parser.add_argument("--engine", type=Path, default=Path("lambergar.exe"), help="Path to engine executable")
    parser.add_argument("--pgn", type=Path, default=Path("vidmar.pgn"), help="Path to Vidmar PGN file")
    parser.add_argument("--depth", type=int, default=6, help="Search depth for comparisons")
    parser.add_argument("--limit", type=int, default=100, help="Maximum number of positions to sample")
    parser.add_argument("--trials", type=int, default=50, help="Optuna trial count")
    parser.add_argument("--align-cap", type=int, default=200, help="Centipawn cap for alignment loss")
    parser.add_argument("--weights", type=float, nargs=3, metavar=("MATCH", "ALIGN", "REG"), default=(0.6, 0.3, 0.1), help="Weights for objective terms")
    parser.add_argument("--seed", type=int, default=2025, help="Random seed")
    parser.add_argument("--output", type=Path, default=Path("persona_best.json"), help="Where to store best parameters")
    args = parser.parse_args()

    positions = load_positions(args.pgn, args.limit, args.seed)
    if not positions:
        print("No positions parsed from PGN.", file=sys.stderr)
        sys.exit(1)

    engine = UciEngine(args.engine)

    def objective(trial: optuna.Trial) -> float:
        params = {
            "PersonalityPawnScale": trial.suggest_float("PersonalityPawnScale", 0.6, 1.6),
            "PersonalityMobilityScale": trial.suggest_float("PersonalityMobilityScale", 0.6, 1.6),
            "PersonalityKingScale": trial.suggest_float("PersonalityKingScale", 0.6, 1.6),
            "PersonalityThreatScale": trial.suggest_float("PersonalityThreatScale", 0.6, 1.6),
            "PersonalityMaterialScale": trial.suggest_float("PersonalityMaterialScale", 0.8, 1.4),
            "PersonalityMgOffset": trial.suggest_int("PersonalityMgOffset", -40, 40),
            "PersonalityEgOffset": trial.suggest_int("PersonalityEgOffset", -60, 60),
        }
        match_rate, alignment, regularizer = evaluate_personality(
            engine,
            params,
            positions,
            args.depth,
            args.align_cap,
        )
        trial.set_user_attr("match_rate", match_rate)
        trial.set_user_attr("alignment", alignment)
        trial.set_user_attr("regularizer", regularizer)
        score = (
            args.weights[0] * match_rate
            + args.weights[1] * alignment
            + args.weights[2] * regularizer
        )
        return score

    study = optuna.create_study(direction="maximize", sampler=optuna.samplers.TPESampler(seed=args.seed))
    try:
        study.optimize(objective, n_trials=args.trials)
    finally:
        engine.quit()

    best = study.best_trial
    print(f"Best score: {best.value:.4f}")
    print(f"Match rate: {best.user_attrs.get('match_rate', 0):.3f}")
    print(f"Alignment: {best.user_attrs.get('alignment', 0):.3f}")
    print(f"Regularizer: {best.user_attrs.get('regularizer', 0):.3f}")
    print("Parameters:")
    for k, v in best.params.items():
        print(f"  {k} = {v}")
    args.output.write_text(json.dumps(best.params, indent=2))
    print(f"Saved best parameters to {args.output}")


if __name__ == "__main__":
    main()
