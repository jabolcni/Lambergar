#!/usr/bin/env python3
"""
PGN to FEN Converter with Game Results

Converts PGN (Portable Game Notation) chess games into FEN (Forsyth-Edwards 
Notation) positions with game results. This tool is useful for creating 
training datasets from game databases.

Purpose:
    - Extract positions from PGN game files
    - Attach game results to each position ([1.0], [0.5], [0.0])
    - Skip opening moves to get more interesting positions
    - Generate training data for evaluation tuning

Usage:
    Basic conversion:
        python convert_pgn_to_fen_with_result.py games.pgn output.txt
    
    Skip first 5 moves (avoid book positions):
        python convert_pgn_to_fen_with_result.py games.pgn output.txt --skip_moves 5
    
    Skip first 10 moves (get middlegame positions):
        python convert_pgn_to_fen_with_result.py games.pgn output.txt --skip_moves 10

Arguments:
    pgn_file: Path to input PGN file containing chess games
    output_file: Path to output file for FEN positions with results
    --skip_moves: Number of opening moves to skip (default: 0)

Output Format:
    Each line contains a FEN position followed by the game result:
    
    rnbqkb1r/pp1ppppp/5n2/2p5/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - [1.0]
    r1bqkb1r/pp1ppppp/2n2n2/2p5/4P3/2N2N2/PPPP1PPP/R1BQKB1R w KQkq - [0.5]
    rnbqkbnr/pp1ppppp/8/2p5/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - [0.0]
    
    Result notation:
    - [1.0] = White won (1-0)
    - [0.5] = Draw (1/2-1/2)
    - [0.0] = Black won (0-1)

Use Cases:
    1. Creating evaluation training datasets from master games
    2. Generating test positions for engine testing
    3. Extracting middlegame/endgame positions for analysis
    4. Building opening book alternatives

Example:
    # Convert Lichess database, skip first 8 moves
    python convert_pgn_to_fen_with_result.py lichess_db.pgn training_data.txt --skip_moves 8
    
    # This creates positions starting from move 9 onwards
    # Each position labeled with the final game result

Dependencies:
    - python-chess: Chess library for PGN parsing
      Install: pip install chess

Notes:
    - All positions from a game get the same result label
    - Skipping moves helps avoid book positions
    - Output can be used with old HCE tuning methods
    - For modern tuning, use the automated pipeline instead

See Also:
    - automation/datagen.py: Modern self-play data generation
    - tuner/README.md: Complete tuning documentation
"""

import chess
import chess.pgn
import argparse

def convert_pgn_to_fen_with_result(pgn_file_path, output_file_path, skip_moves):
    with open(pgn_file_path, "r") as pgn_file, open(output_file_path, "w") as output_file:
        while True:
            game = chess.pgn.read_game(pgn_file)
            if game is None:
                break

            # Determine the result
            result = game.headers["Result"]
            if result == "1-0":
                game_result = "[1.0]"
            elif result == "0-1":
                game_result = "[0.0]"
            else:
                game_result = "[0.5]"

            # Iterate through each move in the game, skipping the first `skip_moves`
            board = game.board()
            move_count = 0
            for move in game.mainline_moves():
                board.push(move)
                move_count += 1
                if move_count > skip_moves:
                    fen_position = board.fen()
                    output_file.write(f"{fen_position} {game_result}\n")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Convert PGN games to FEN positions with results.")
    parser.add_argument("pgn_file", type=str, help="Path to the PGN input file.")
    parser.add_argument("output_file", type=str, help="Path to the output file for FEN positions.")
    parser.add_argument("--skip_moves", type=int, default=0, help="Number of starting moves to skip in each game.")

    args = parser.parse_args()
    convert_pgn_to_fen_with_result(args.pgn_file, args.output_file, args.skip_moves)
