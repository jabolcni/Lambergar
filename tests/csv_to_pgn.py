import argparse
import csv
import sys
from pathlib import Path

import chess
import chess.pgn


def detect_chess960(fen: str) -> bool:
    # Heuristic: any castling field that isn't a subset of {K,Q,k,q,-} is FRC.
    parts = fen.split()
    if len(parts) < 3:
        return False
    castling = parts[2]
    allowed = set("KQkq-")
    return any(ch not in allowed for ch in castling)


def build_games(rows):
    games = {}
    for row in rows:
        try:
            game_idx = int(row["game"])
            ply = int(row["ply"])
            move_uci = row["uci"]
            fen = row["fen"].strip().strip('"')
            result = row.get("result", "*")
        except Exception as exc:  # noqa: BLE001
            print(f"[WARN] skipping row due to parse error: {exc} row={row}", file=sys.stderr)
            continue
        games.setdefault(game_idx, []).append(
            {"ply": ply, "uci": move_uci, "fen": fen, "result": result}
        )
    return games


def write_pgn(games, out_path: Path):
    written = 0
    skipped = []
    with out_path.open("w", encoding="utf-8") as fh:
        for game_idx in sorted(games.keys()):
            rows = sorted(games[game_idx], key=lambda r: r["ply"])
            if not rows:
                continue
            start_fen = rows[0]["fen"]
            chess960 = detect_chess960(start_fen)
            board = chess.Board(fen=start_fen, chess960=chess960)
            pgn_game = chess.pgn.Game()
            pgn_game.headers["Event"] = f"datagen game {game_idx}"
            pgn_game.headers["SetUp"] = "1"
            pgn_game.headers["FEN"] = start_fen
            pgn_game.headers["Result"] = rows[-1]["result"] if rows[-1].get("result") else "*"
            node = pgn_game
            ok = True
            for row in rows:
                try:
                    move = board.parse_uci(row["uci"])
                    san = board.san(move)
                    board.push(move)
                    node = node.add_variation(move)
                    node.comment = f"{row['uci']} (ply {row['ply']})"
                except Exception as exc:  # noqa: BLE001
                    print(
                        f"[WARN] game {game_idx} ply {row['ply']} illegal move {row['uci']} on fen {board.fen()}: {exc}",
                        file=sys.stderr,
                    )
                    ok = False
                    break
            if not ok:
                skipped.append(game_idx)
                continue
            fh.write(pgn_game.accept(chess.pgn.StringExporter(columns=None, headers=True, variations=False, comments=False)))
            fh.write("\n\n")
            written += 1
    print(f"wrote PGN with {written} game(s) to {out_path} (skipped {len(skipped)} games: {skipped})")


def main():
    parser = argparse.ArgumentParser(description="Convert validation CSV (from datagen_validate) into PGN.")
    parser.add_argument("csv", help="input CSV produced by datagen_validate.zig")
    parser.add_argument("pgn", help="output PGN path")
    args = parser.parse_args()

    with open(args.csv, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        games = build_games(list(reader))

    write_pgn(games, Path(args.pgn))
    print(f"wrote PGN with {len(games)} game(s) to {args.pgn}")


if __name__ == "__main__":
    main()
