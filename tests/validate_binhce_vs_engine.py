import argparse
import subprocess
import sys
import numpy as np
import chess

BINHCE_FEATURE_COUNT = 1168


def decode_bit(data: np.ndarray, pos: int) -> tuple[int, int]:
    byte_idx = pos // 8
    bit_offset = pos % 8
    value = (data[byte_idx] >> bit_offset) & 1
    return int(value), pos + 1


def decode_bits(data: np.ndarray, pos: int, nbits: int) -> tuple[int, int]:
    value = 0
    for i in range(nbits):
        bit, pos = decode_bit(data, pos)
        value |= (bit << i)
    return value, pos


def decode_piece_at(data: np.ndarray, pos: int):
    REVERSE_HUFFMAN = {
        (0, 1): 0,
        (1, 4): 1,
        (3, 4): 2,
        (5, 4): 3,
        (7, 4): 4,
        (9, 4): 5,
    }
    bit, pos = decode_bit(data, pos)
    if bit == 0:
        return None, None, pos
    code = bit
    for i in range(3):
        bit, pos = decode_bit(data, pos)
        code |= (bit << (i + 1))
    piece_type = REVERSE_HUFFMAN.get((code, 4), None)
    if piece_type is None:
        return None, None, pos
    color_bit, pos = decode_bit(data, pos)
    color = chess.WHITE if color_bit == 0 else chess.BLACK
    return piece_type, color, pos


def find_rooks(board, color):
    rank = 0 if color == chess.WHITE else 7
    king_file = chess.square_file(board.king(color))
    left_rooks = []
    right_rooks = []
    for file in range(8):
        sq = chess.square(file, rank)
        piece = board.piece_at(sq)
        if piece and piece.piece_type == chess.ROOK and piece.color == color:
            if file < king_file:
                left_rooks.append(file)
            elif file > king_file:
                right_rooks.append(file)
    left_rooks.sort()
    right_rooks.sort()
    return left_rooks, right_rooks


def decode_position(data: np.ndarray) -> chess.Board:
    board = chess.Board(None)
    board.chess960 = False
    pos = 0

    side, pos = decode_bit(data, pos)
    board.turn = chess.WHITE if side == 0 else chess.BLACK

    wk_sq, pos = decode_bits(data, pos, 6)
    bk_sq, pos = decode_bits(data, pos, 6)
    board.set_piece_at(wk_sq, chess.Piece(chess.KING, chess.WHITE))
    board.set_piece_at(bk_sq, chess.Piece(chess.KING, chess.BLACK))

    for r in reversed(range(8)):
        for f in range(8):
            sq = r * 8 + f
            if sq not in (wk_sq, bk_sq):
                piece_type, color, pos = decode_piece_at(data, pos)
                if piece_type:
                    board.set_piece_at(sq, chess.Piece(piece_type, color))

    wk_castle, pos = decode_bit(data, pos)
    wq_castle, pos = decode_bit(data, pos)
    bk_castle, pos = decode_bit(data, pos)
    bq_castle, pos = decode_bit(data, pos)

    castling_rights = 0
    w_left, w_right = find_rooks(board, chess.WHITE)
    b_left, b_right = find_rooks(board, chess.BLACK)

    def assign_castle(color, kingside, enabled, left_rooks, right_rooks):
        nonlocal castling_rights
        if not enabled:
            return
        king_sq = board.king(color)
        if king_sq is None:
            return
        rank = 0 if color == chess.WHITE else 7
        king_file = chess.square_file(king_sq)
        if kingside:
            rook_files = right_rooks
            rook_file = rook_files[0] if rook_files else None
            if rook_file is None:
                return
            rook_sq = chess.square(rook_file, rank)
            classical = (king_sq == (chess.E1 if color == chess.WHITE else chess.E8) and rook_sq == (chess.H1 if color == chess.WHITE else chess.H8))
            if classical:
                castling_rights |= chess.BB_H1 if color == chess.WHITE else chess.BB_H8
            else:
                castling_rights |= chess.BB_SQUARES[rook_sq]
                board.chess960 = True
        else:
            rook_files = left_rooks
            rook_file = rook_files[-1] if rook_files else None
            if rook_file is None:
                return
            rook_sq = chess.square(rook_file, rank)
            classical = (king_sq == (chess.E1 if color == chess.WHITE else chess.E8) and rook_sq == (chess.A1 if color == chess.WHITE else chess.A8))
            if classical:
                castling_rights |= chess.BB_A1 if color == chess.WHITE else chess.BB_A8
            else:
                castling_rights |= chess.BB_SQUARES[rook_sq]
                board.chess960 = True

    assign_castle(chess.WHITE, True, wk_castle, w_left, w_right)
    assign_castle(chess.WHITE, False, wq_castle, w_left, w_right)
    assign_castle(chess.BLACK, True, bk_castle, b_left, b_right)
    assign_castle(chess.BLACK, False, bq_castle, b_left, b_right)
    board.castling_rights = castling_rights

    def requires_chess960(color, kingside_enabled, queenside_enabled, left_rooks, right_rooks):
        king_sq = board.king(color)
        if king_sq is None:
            return False
        const_e = chess.E1 if color == chess.WHITE else chess.E8
        if king_sq != const_e:
            return True
        rank = 0 if color == chess.WHITE else 7
        if kingside_enabled:
            rook_file = right_rooks[0] if right_rooks else None
            if rook_file is None or rook_file != 7:
                return True
        if queenside_enabled:
            rook_file = left_rooks[-1] if left_rooks else None
            if rook_file is None or rook_file != 0:
                return True
        return False

    if requires_chess960(chess.WHITE, wk_castle, wq_castle, w_left, w_right):
        board.chess960 = True
    if requires_chess960(chess.BLACK, bk_castle, bq_castle, b_left, b_right):
        board.chess960 = True

    ep_flag, pos = decode_bit(data, pos)
    if ep_flag:
        ep_square, pos = decode_bits(data, pos, 6)
        board.ep_square = ep_square
    else:
        board.ep_square = None

    board.halfmove_clock, pos = decode_bits(data, pos, 6)
    fullmove_low, pos = decode_bits(data, pos, 8)
    fullmove_high, pos = decode_bits(data, pos, 8)
    high_bit, pos = decode_bit(data, pos)
    board.fullmove_number = fullmove_low | (fullmove_high << 8)
    board.halfmove_clock |= (high_bit << 6)
    return board


def read_binhce_records(path):
    with open(path, "rb") as f:
        while True:
            sfen_bytes = f.read(32)
            if not sfen_bytes or len(sfen_bytes) < 32:
                break
            extra = f.read(8)
            if not extra or len(extra) < 8:
                break
            feat_bytes = f.read(BINHCE_FEATURE_COUNT)
            if not feat_bytes or len(feat_bytes) < BINHCE_FEATURE_COUNT:
                break
            feat_vec = np.frombuffer(feat_bytes, dtype=np.uint8)
            yield sfen_bytes, feat_vec


def run_engine_sfen(engine_path: str, sfen_bytes: bytes) -> list[int]:
    hex_str = sfen_bytes.hex()
    proc = subprocess.Popen([engine_path], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    cmds = [
        "uci\n",
        "isready\n",
        f"hcefeatures_sfen32 {hex_str}\n",
        "quit\n",
    ]
    out, _ = proc.communicate("".join(cmds), timeout=10)
    for line in out.splitlines():
        if "info string hce_features" in line:
            _, vec_str = line.split("hce_features", 1)
            vec_str = vec_str.strip()
            return [int(x) for x in vec_str.split(",") if x]
    raise RuntimeError("hce_features line not found in engine output\nEngine output:\n" + out)


def main():
    ap = argparse.ArgumentParser(description="Compare binhce features vs engine hcefeatures output")
    ap.add_argument("binhce", help="path to .binhce file")
    ap.add_argument("engine", help="path to engine executable")
    args = ap.parse_args()

    mismatches = 0
    total = 0
    for sfen_bytes, feat_vec in read_binhce_records(args.binhce):
        total += 1
        engine_vec = run_engine_sfen(args.engine, sfen_bytes)
        if len(engine_vec) != len(feat_vec):
            print(f"Length mismatch at pos {total}: bin={len(feat_vec)} eng={len(engine_vec)}")
            mismatches += 1
            continue
        if any(int(a) != int(b) for a, b in zip(feat_vec, engine_vec)):
            mismatches += 1
            diff_indices = [i for i, (a, b) in enumerate(zip(feat_vec, engine_vec)) if int(a) != int(b)]
            print(f"Mismatch at pos {total}")
            print(f" First differing indices (up to 10): {diff_indices[:10]}")
            for idx in diff_indices[:10]:
                print(f" idx {idx}: bin={int(feat_vec[idx])} engine={int(engine_vec[idx])}")
            print(" SFEN32 hex:", sfen_bytes.hex())
            # helpful slices for pawn helpers
            supported_slice = slice(940, 956)
            phalanx_slice = slice(956, 972)
            print(" supported_pawn bin:", [int(x) for x in feat_vec[supported_slice]])
            print(" supported_pawn eng:", [int(x) for x in engine_vec[supported_slice]])
            print(" pawn_phalanx bin :", [int(x) for x in feat_vec[phalanx_slice]])
            print(" pawn_phalanx eng :", [int(x) for x in engine_vec[phalanx_slice]])
        if total % 100 == 0:
            print(f"Checked {total} positions; mismatches so far: {mismatches}")

    if mismatches == 0:
        print(f"All OK: {total} positions matched.")
    else:
        print(f"Done with {mismatches} mismatches out of {total} positions.")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)
