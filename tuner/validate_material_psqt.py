#!/usr/bin/env python3
"""
Validate material and PSQT features stored in a .binhce file.
For each record:
  - Reconstruct the board from SFEN/FEN.
  - Count material per color and compare to stored mat[2][6].
  - Build PSQT occupancy (black mirrored with sq^56) and compare to stored psqt[2][6][64].
Prints mismatches and a final summary.
"""

from __future__ import annotations

import argparse
from typing import List, Tuple

import numpy as np
import chess

import binhce_reader


PIECE_ORDER: List[chess.PieceType] = [
    chess.PAWN,
    chess.KNIGHT,
    chess.BISHOP,
    chess.ROOK,
    chess.QUEEN,
    chess.KING,
]

# Shapes in serialized feature vector
SHAPES: List[Tuple[str, Tuple[int, ...]]] = [
    ("mat", (2, 6)),
    ("psqt", (2, 6, 64)),
    ("passed_pawn", (2, 64)),
    ("isolated_pawn", (2, 8)),
    ("blocked_passer", (2, 8)),
    ("supported_pawn", (2, 8)),
    ("pawn_phalanx", (2, 8)),
    ("knight_mobility", (2, 9)),
    ("bishop_mobility", (2, 14)),
    ("rook_mobility", (2, 15)),
    ("queen_mobility", (2, 28)),
    ("pawn_attacking", (2, 6)),
    ("knight_attacking", (2, 6)),
    ("bishop_attacking", (2, 6)),
    ("rook_attacking", (2, 6)),
    ("queen_attacking", (2, 6)),
    ("doubled_pawns", (2,)),
    ("bishop_pair", (2,)),
]


def parse_features(vec: np.ndarray) -> dict:
    """Slice the flat feature vector into named arrays."""
    res = {}
    off = 0
    for name, shape in SHAPES:
        size = int(np.prod(shape))
        chunk = vec[off: off + size]
        res[name] = chunk.reshape(shape)
        off += size
    return res


def expected_material(board: chess.Board) -> np.ndarray:
    """Return mat[2][6] counts from the board."""
    out = np.zeros((2, 6), dtype=np.uint8)
    for idx, pt in enumerate(PIECE_ORDER):
        out[0, idx] = len(board.pieces(pt, chess.WHITE))
        out[1, idx] = len(board.pieces(pt, chess.BLACK))
    return out


def expected_psqt(board: chess.Board) -> np.ndarray:
    """Return psqt[2][6][64] occupancy (black mirrored with sq^56)."""
    out = np.zeros((2, 6, 64), dtype=np.uint8)
    for color_idx, color in enumerate((chess.WHITE, chess.BLACK)):
        for pt_idx, pt in enumerate(PIECE_ORDER):
            for sq in board.pieces(pt, color):
                s = sq if color == chess.WHITE else sq ^ 56  # mirror black
                out[color_idx, pt_idx, s] += 1
    return out


def main():
    ap = argparse.ArgumentParser(description="Validate material and PSQT in .binhce")
    ap.add_argument("binhce", help="Path to .binhce file")
    ap.add_argument("--max", type=int, default=None, help="Optional cap on positions to check")
    ap.add_argument("--limit-mismatches", type=int, default=20, help="Stop printing after this many mismatches")
    args = ap.parse_args()

    print(f"Loading {args.binhce} ...")
    total = 0
    mismatches = 0

    # Two-pass if max not provided: first count to know progress.
    target_count = args.max
    if target_count is None:
        target_count = sum(1 for _ in binhce_reader.iter_binhce(args.binhce, max_positions=None))
        print(f"Total positions to check: {target_count:,}")

    def render_progress(done: int, total: int, mism: int):
        pct = (done / total) * 100 if total else 0
        bar_len = 40
        filled = int(bar_len * pct / 100)
        bar = "█" * filled + "·" * (bar_len - filled)
        print(f"\r[{bar}] {pct:5.1f}%  checked {done:,}/{total:,}  mismatches {mism}", end="", flush=True)

    for rec in binhce_reader.iter_binhce(args.binhce, max_positions=args.max):
        total += 1
        if total % 10000 == 0:
            render_progress(total, target_count, mismatches)

        feats = parse_features(rec.features)
        board = chess.Board(rec.fen)

        mat_exp = expected_material(board)
        psqt_exp = expected_psqt(board)

        mat_ok = np.array_equal(mat_exp, feats["mat"])
        psqt_ok = np.array_equal(psqt_exp, feats["psqt"])

        if not mat_ok or not psqt_ok:
            mismatches += 1
            if mismatches <= args.limit_mismatches:
                print(f"Mismatch at pos {total} fen={rec.fen}")
                if not mat_ok:
                    print(f"  mat expected:\n{mat_exp}\n  mat found:\n{feats['mat']}")
                if not psqt_ok:
                    diff = np.nonzero(psqt_exp != feats["psqt"])
                    print(f"  psqt mismatch count={len(diff[0])}")
            if mismatches == args.limit_mismatches:
                print("... more mismatches omitted ...")

    # final progress line
    if target_count:
        render_progress(total, target_count, mismatches)
    print(f"\nChecked {total:,} positions.")
    if mismatches == 0:
        print("All material and PSQT features match.")
    else:
        print(f"Mismatches: {mismatches}")


if __name__ == "__main__":
    main()
