#!/usr/bin/env python3
"""
HCE Feature Visualization Tool for Lambergar.
Parses the output of 'hcefeatures' command and presents a human-readable report.
"""

import argparse
import subprocess
import sys
import chess
from typing import List, Dict, Any, Tuple

# Feature definitions matching src/tuner.zig
# (name, shape)
# Shape dimensions: [colors, pieces/types, squares/buckets]
# colors: 2 (White, Black)
# pieces: 6 (P, N, B, R, Q, K)
# squares: 64
FEATURES_SCHEMA = [
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
    ("bishop_pair", (2,))
]

PIECE_NAMES = ["Pawn", "Knight", "Bishop", "Rook", "Queen", "King"]
COLOR_NAMES = ["White", "Black"]
FILE_NAMES = ["a", "b", "c", "d", "e", "f", "g", "h"]

def get_hce_features(engine_path: str, fen: str) -> List[int]:
    """Run engine and get raw feature vector"""
    try:
        proc = subprocess.Popen(
            [engine_path],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        
        commands = f"position fen {fen}\nhcefeatures\nquit\n"
        stdout, stderr = proc.communicate(input=commands, timeout=5)
        
        for line in stdout.splitlines():
            if "info string hce_features" in line:
                # Format: info string hce_features 1,0,0,...
                parts = line.split("hce_features ")
                if len(parts) > 1:
                    vector_str = parts[1].strip()
                    return [int(x) for x in vector_str.split(',')]
        
        print("Error: Could not find 'hcefeatures' output")
        return []
    except Exception as e:
        print(f"Error running engine: {e}")
        return []

def parse_features(raw_vector: List[int]) -> Dict[str, Any]:
    """Parse raw vector into structured dictionary based on schema"""
    parsed = {}
    offset = 0
    
    for name, shape in FEATURES_SCHEMA:
        # Calculate total size of this feature
        size = 1
        for dim in shape:
            size *= dim
            
        # Extract chunk
        if offset + size > len(raw_vector):
            print(f"Error: Vector too short for feature {name}")
            break
            
        chunk = raw_vector[offset : offset + size]
        offset += size
        
        # Reshape (simplified for now, just storing flat chunk and shape)
        parsed[name] = {
            "data": chunk,
            "shape": shape
        }
        
    return parsed

def print_report(parsed: Dict[str, Any], fen: str):
    """Print human-readable report"""
    board = chess.Board(fen)
    print(f"\nPosition: {fen}")
    
    # Pretty print board
    print("   +-----------------+")
    for rank in range(7, -1, -1):
        line = f" {rank+1} |"
        for file in range(8):
            piece = board.piece_at(chess.square(file, rank))
            symbol = piece.symbol() if piece else "."
            line += f" {symbol}"
        line += " |"
        print(line)
    print("   +-----------------+")
    print("     a b c d e f g h")
    
    # Material
    print("\n=== Material ===")
    mat = parsed["mat"]["data"]
    for c in range(2):
        pieces = []
        for p in range(6):
            count = mat[c * 6 + p]
            if count > 0:
                pieces.append(f"{count} {PIECE_NAMES[p]}")
        if pieces:
            print(f"{COLOR_NAMES[c]}: {', '.join(pieces)}")

    # PSQT (Skip detailed print, just summary)
    # print("\n=== PSQT (Active Pieces) ===")
    # ...

    # Pawn Structure
    print("\n=== Pawn Structure ===")
    
    # Define feature types
    # (name, label_type) where label_type is "square", "file", or "rank"
    pawn_features = [
        ("passed_pawn", "square"),
        ("isolated_pawn", "file"),
        ("blocked_passer", "rank"),
        ("supported_pawn", "rank"),
        ("pawn_phalanx", "rank")
    ]
    
    for feature, label_type in pawn_features:
        if feature not in parsed:
            continue
            
        data = parsed[feature]["data"]
        shape = parsed[feature]["shape"]
        
        active = []
        for c in range(2):
            items = []
            if label_type == "square":
                for sq in range(64):
                    if data[c * 64 + sq] > 0:
                        items.append(chess.square_name(sq))
            elif label_type == "file":
                for f in range(8):
                    if data[c * 8 + f] > 0:
                        items.append(FILE_NAMES[f])
            elif label_type == "rank":
                for r in range(8):
                    if data[c * 8 + r] > 0:
                        # Convert relative rank index back to board rank
                        # White: index r -> Rank r+1
                        # Black: index r -> Rank 8-r
                        if c == 0: # White
                            rank_label = f"Rank {r+1}"
                        else: # Black
                            rank_label = f"Rank {8-r}"
                        
                        items.append(rank_label)
            
            if items:
                active.append(f"{COLOR_NAMES[c]}: {', '.join(items)}")
        
        if active:
            print(f"{feature.replace('_', ' ').title()}:")
            for line in active:
                print(f"  {line}")

    # Mobility
    print("\n=== Mobility (Count of pieces with N moves) ===")
    for feature in ["knight_mobility", "bishop_mobility", "rook_mobility", "queen_mobility"]:
        data = parsed[feature]["data"]
        shape = parsed[feature]["shape"] # (2, buckets)
        buckets = shape[1]
        
        print(f"{feature.replace('_', ' ').title()}:")
        for c in range(2):
            moves = []
            for b in range(buckets):
                count = data[c * buckets + b]
                if count > 0:
                    moves.append(f"{count}x{b}mv")
            if moves:
                print(f"  {COLOR_NAMES[c]}: {', '.join(moves)}")

    # Attacking
    print("\n=== Attacking (Count of pieces attacking enemy X) ===")
    for feature in ["pawn_attacking", "knight_attacking", "bishop_attacking", "rook_attacking", "queen_attacking"]:
        data = parsed[feature]["data"]
        # Shape (2, 6) -> (Color, AttackedPieceType)
        
        print(f"{feature.replace('_', ' ').title()}:")
        for c in range(2):
            attacks = []
            for p in range(6): # Attacked piece type
                count = data[c * 6 + p]
                if count > 0:
                    attacks.append(f"{count}x{PIECE_NAMES[p]}")
            if attacks:
                print(f"  {COLOR_NAMES[c]} attacks: {', '.join(attacks)}")

    # Misc
    print("\n=== Misc ===")
    doubled = parsed["doubled_pawns"]["data"]
    bishop_pair = parsed["bishop_pair"]["data"]
    
    for c in range(2):
        if doubled[c] > 0:
            print(f"{COLOR_NAMES[c]} Doubled Pawns: {doubled[c]}")
        if bishop_pair[c] > 0:
            print(f"{COLOR_NAMES[c]} Bishop Pair: Yes")

def main():
    parser = argparse.ArgumentParser(description="Visualize HCE Features")
    parser.add_argument("--engine", required=True, help="Path to engine executable")
    parser.add_argument("--fen", default=chess.STARTING_FEN, help="FEN string to analyze")
    args = parser.parse_args()
    
    raw = get_hce_features(args.engine, args.fen)
    if not raw:
        sys.exit(1)
        
    parsed = parse_features(raw)
    print_report(parsed, args.fen)

if __name__ == "__main__":
    main()
