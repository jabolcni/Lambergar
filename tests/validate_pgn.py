#!/usr/bin/env python3
"""
Validate PGN games for legal play.
Assumes movetext is in UCI (not SAN). Handles Chess960/DFRC castling by using chess960=True.
Reports the first illegal move per game, otherwise prints success.
"""
import sys
import pathlib
import subprocess
import shlex
import chess

VERBOSE = False


def is_result_token(tok: str) -> bool:
    return tok in ("1-0", "0-1", "1/2-1/2", "*")


def parse_pgn_blocks(path: pathlib.Path):
    with path.open("r", encoding="utf-8") as fh:
        headers = {}
        moves = []
        for line in fh:
            stripped = line.strip()
            if stripped.startswith("[") and stripped.endswith("]"):
                if stripped.startswith("[Event"):
                    if headers or moves:
                        # Emit previous game before starting a new one
                        if moves:
                            yield headers, moves
                        headers, moves = {}, []
                try:
                    name, rest = stripped[1:-1].split(maxsplit=1)
                    value = rest.strip().strip('"')
                    headers[name] = value
                except ValueError:
                    continue
            elif stripped.startswith("%"):
                continue
            else:
                if stripped == "":
                    if moves:
                        yield headers, moves
                        headers, moves = {}, []
                    continue
                moves.extend(stripped.split())
        if moves:
            yield headers, moves


class EngineProbe:
    """
    Optional external engine probe used as a fallback when python-chess rejects a move.
    Command should start a UCI-capable engine. For each query we feed:
        uci
        isready
        ucinewgame
        position fen <fen>
        moves
        quit
    The engine is expected to print legal moves in UCI form on the 'moves' line (or anywhere).
    """

    def __init__(self, cmd: str | None):
        self.cmd_parts = shlex.split(cmd) if cmd else None

    def available(self) -> bool:
        return self.cmd_parts is not None

    def legal_moves(self, fen: str) -> set[str]:
        if not self.cmd_parts:
            return set()
        const_lines = [
            "uci",
            "setoption name UCI_Chess960 value true",
            "isready",
            "ucinewgame",
            f"position fen {fen}",
            "moves",
            "quit",
            "",
        ]
        input_script = "\n".join(const_lines)
        if VERBOSE:
            print(f"[ENGINE] exec: {' '.join(self.cmd_parts)}")
            print(f"[ENGINE] stdin:\n{input_script}")
        try:
            proc = subprocess.run(
                self.cmd_parts,
                input=input_script,
                check=False,
                capture_output=True,
                text=True,
                timeout=5,
            )
        except Exception as exc:  # noqa: BLE001
            if VERBOSE:
                print(f"[DEBUG] Engine probe failed: {exc}")
            return set()
        text = (proc.stdout or "") + (proc.stderr or "")
        if VERBOSE:
            print(f"[ENGINE] exit={proc.returncode}")
            if text:
                print(f"[ENGINE] output:\n{text}")
        tokens: list[str] = []
        for line in text.splitlines():
            lower = line.lower()
            if "moves" in lower or "legal" in lower:
                tokens.extend(line.replace(",", " ").split())
        if not tokens:
            tokens = text.replace(",", " ").split()
        ucis: set[str] = set()
        files = "abcdefgh"
        ranks = "12345678"
        for tok in tokens:
            t = tok.strip()
            if len(t) in (4, 5) and t[0] in files and t[2] in files and t[1] in ranks and t[3] in ranks:
                ucis.add(t.lower())
        return ucis


def validate_game(headers, move_tokens, index, engine: EngineProbe):
    setup = headers.get("SetUp")
    fen_tag = headers.get("FEN")
    chess960_flag = False
    if setup == "1" and fen_tag:
        try:
            piece_placement = fen_tag.split()[0] if fen_tag.split() else ""
            chess960_flag = piece_placement != "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR"
            board = chess.Board(fen_tag, chess960=True)
        except ValueError as exc:
            return f"Game {index}: invalid FEN '{fen_tag}': {exc}"
    else:
        board = chess.Board(chess960=True)

    ply = 0
    history: list[str] = []

    def castling_rook_from(move: chess.Move, color: chess.Color) -> str | None:
        k_from = move.from_square
        rank = chess.square_rank(k_from)
        rooks = [sq for sq in board.pieces(chess.ROOK, color) if chess.square_rank(sq) == rank]
        if not rooks:
            return None
        if move.to_square > k_from:
            rf = max(sq for sq in rooks if sq > k_from) if any(sq > k_from for sq in rooks) else max(rooks)
        else:
            rf = min(sq for sq in rooks if sq < k_from) if any(sq < k_from for sq in rooks) else min(rooks)
        return chess.square_name(rf)
    for tok in move_tokens:
        if is_result_token(tok):
            break
        # Skip move numbers and ellipses
        if "." in tok or tok.replace(".", "").isdigit():
            continue
        uci = tok.strip()
        ply += 1
        try:
            move = chess.Move.from_uci(uci)
        except ValueError:
            try:
                move = board.parse_san(uci)
            except Exception:
                if VERBOSE:
                    print(f"[DEBUG] Game {index} parse error at ply {ply} token '{uci}'")
                    print(f"  FEN: {board.fen()}")
                    print(f"  Headers: {headers}")
                    print(f"  Moves so far: {' '.join(history)}")
                    legals = " ".join(m.uci() for m in board.legal_moves)
                    print(f"  Legal moves: {legals}")
                return f"Game {index}: could not parse move '{uci}' at ply {ply} in position {board.fen()}"
        if move not in board.legal_moves:
            # Special-case 960-style castling encoded as king-from + rook-from
            if chess960_flag:
                for m in board.generate_legal_moves(chess.BB_ALL):
                    if board.is_castling(m):
                        r_from = castling_rook_from(m, board.turn)
                        if r_from is not None:
                            k_from = chess.square_name(m.from_square)
                            if uci == f"{k_from}{r_from}":
                                move = m
                                break
                if move not in board.legal_moves and len(uci) >= 4:
                    try:
                        from_sq = chess.parse_square(uci[0:2])
                        to_sq = chess.parse_square(uci[2:4])
                        king = board.piece_at(from_sq)
                        rook = board.piece_at(to_sq)
                        if king and rook and king.piece_type == chess.KING and rook.piece_type == chess.ROOK and king.color == board.turn:
                            for m in board.generate_legal_moves(chess.BB_ALL):
                                if board.is_castling(m):
                                    r_from = castling_rook_from(m, board.turn)
                                    if r_from and uci == f"{uci[0:2]}{r_from}":
                                        move = m
                                        break
                    except ValueError:
                        pass
        if move not in board.legal_moves:
            # Try a simple from-to match against legal moves
            for m in board.legal_moves:
                if m.from_square == move.from_square and m.to_square == move.to_square:
                    move = m
                    break
        if move not in board.legal_moves:
            # Try classical castling fix (king to g/c)
            if board.is_castling(move):
                kingside = chess.square_file(move.to_square) > chess.square_file(move.from_square)
                replacement = None
                for m in board.generate_legal_moves(chess.BB_ALL):
                    if board.is_castling(m):
                        ks = chess.square_file(m.to_square) > chess.square_file(m.from_square)
                        if ks == kingside:
                            replacement = m
                            break
                if replacement and replacement in board.legal_moves:
                    move = replacement
                else:
                    if VERBOSE:
                        print(f"[DEBUG] Game {index} illegal castling at ply {ply} token '{uci}'")
                        print(f"  FEN: {board.fen()}")
                        print(f"  Headers: {headers}")
                        print(f"  Moves so far: {' '.join(history)}")
                        legals = " ".join(m.uci() for m in board.legal_moves)
                        print(f"  Legal moves: {legals}")
                    return f"Game {index} ({headers.get('Event', '?')}): illegal castling '{uci}' at ply {ply} in position {board.fen()}"
            else:
                # Ask external engine if configured
                if engine.available():
                    legal_from_engine = engine.legal_moves(board.fen())
                    if uci in legal_from_engine:
                        print(f"[ENGINE] Game {index} ply {ply} '{uci}' accepted by engine probe")
                        # Push a matching legal move (by from/to) if possible
                        for m in board.legal_moves:
                            if m.from_square == move.from_square and m.to_square == move.to_square:
                                move = m
                                break
                        if move not in board.legal_moves:
                            # fall back to a raw push if engine insists it's legal
                            try:
                                board.push_uci(uci)
                                history.append(uci)
                                continue
                            except Exception:
                                pass
                    else:
                        print(f"[ENGINE] Game {index} ply {ply} '{uci}' NOT in engine legal set")
                        if VERBOSE:
                            print(f"[DEBUG] Engine probe legal moves: {' '.join(sorted(legal_from_engine))}")
                else:
                    if VERBOSE:
                        print(f"[DEBUG] Engine probe not configured; skipping external check")
                if VERBOSE:
                    print(f"[DEBUG] Game {index} illegal move at ply {ply} token '{uci}'")
                    print(f"  FEN: {board.fen()}")
                    print(f"  Headers: {headers}")
                    print(f"  Moves so far: {' '.join(history)}")
                    legals = " ".join(m.uci() for m in board.legal_moves)
                    print(f"  Legal moves: {legals}")
                return f"Game {index} ({headers.get('Event', '?')}): illegal move '{uci}' at ply {ply} in position {board.fen()}"
        board.push(move)
        history.append(uci)
    return None


def main():
    global VERBOSE
    raw_args = sys.argv[1:]
    engine_cmd = None

    remaining: list[str] = []
    i = 0
    while i < len(raw_args):
        arg = raw_args[i]
        if arg == "--debug":
            VERBOSE = True
            i += 1
            continue
        if arg == "--engine":
            if i + 1 >= len(raw_args):
                print("Usage: --engine \"<command>\"")
                sys.exit(1)
            engine_cmd = raw_args[i + 1]
            i += 2
            continue
        remaining.append(arg)
        i += 1

    if not remaining:
        print("Usage: python validate_pgn.py <pgn file> [--debug] [--engine \"cmd {fen}\"]")
        sys.exit(1)

    path = pathlib.Path(remaining[0])
    if not path.exists():
        print(f"PGN file not found: {path}")
        sys.exit(1)

    engine = EngineProbe(engine_cmd)
    errors = []
    idx = 1
    for headers, moves in parse_pgn_blocks(path):
        err = validate_game(headers, moves, idx, engine)
        if err:
            errors.append(err)
        idx += 1

    if errors:
        print(f"Found {len(errors)} issue(s):")
        for e in errors:
            print(e)
        sys.exit(1)
    else:
        print("All games legal.")


if __name__ == "__main__":
    main()
