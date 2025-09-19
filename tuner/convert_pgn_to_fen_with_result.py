import chess
import chess.pgn
import argparse

# python convert_pgn_to_fen_with_result.py games.pgn fen_positions.txt --skip_moves 5

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
            for move in game.ma_moves():
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
