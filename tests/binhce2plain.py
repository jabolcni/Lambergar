import numpy as np
import chess
import sys

REVERSE_HUFFMAN = {
    (0, 1): 0,    # None
    (1, 4): 1,    # Pawn
    (3, 4): 2,    # Knight
    (5, 4): 3,    # Bishop
    (7, 4): 4,    # Rook
    (9, 4): 5     # Queen
}

BINHCE_FEATURE_COUNT = 1168  # matches writer order/size


def decode_bit(data: np.ndarray, pos: int) -> tuple:
    byte_idx = pos // 8
    bit_offset = pos % 8
    value = (data[byte_idx] >> bit_offset) & 1
    return value, pos + 1


def decode_bits(data: np.ndarray, pos: int, nbits: int) -> tuple:
    value = 0
    for i in range(nbits):
        bit, pos = decode_bit(data, pos)
        value |= (bit << i)
    return value, pos


def decode_piece_at(data: np.ndarray, pos: int) -> tuple:
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


def decode_move_to_uci(move_int: int, board: chess.Board) -> str:
    to_sq = move_int & 0x3F
    from_sq = (move_int >> 6) & 0x3F
    promotion = (move_int >> 12) & 0x3
    flags = (move_int >> 14) & 0x3

    if flags == 3:  # Castling, stored as king square -> rook start square
        king_file = chess.square_file(from_sq)
        rook_file = chess.square_file(to_sq)
        rank = chess.square_rank(from_sq)
        kingside = rook_file > king_file
        if not board.chess960:
            target_file = 6 if kingside else 2  # file g or c
            to_sq = chess.square(target_file, rank)

    from_str = chess.square_name(from_sq)
    to_str = chess.square_name(to_sq)

    if flags == 1:  # Promotion
        promo_map = {0: 'n', 1: 'b', 2: 'r', 3: 'q'}
        return from_str + to_str + promo_map.get(promotion, '')
    else:
        return from_str + to_str


def process_bin_file(filename: str):
    output_filename = filename.replace('.binhce', '.plainhce')
    position_index = 0

    with open(filename, 'rb') as f, open(output_filename, 'w') as out_f:
        while True:
            pos_data = f.read(32)
            if not pos_data:
                break
            if len(pos_data) < 32:
                break
            data = np.frombuffer(pos_data, dtype=np.uint8)
            board = decode_position(data)

            extra_data_bytes = f.read(8)
            if not extra_data_bytes or len(extra_data_bytes) < 8:
                break
            extra_data = np.frombuffer(extra_data_bytes, dtype=[
                ('score', np.int16),
                ('move', np.uint16),
                ('ply', np.uint16),
                ('result', np.int8),
                ('padding', np.uint8)
            ])

            hce_bytes = f.read(BINHCE_FEATURE_COUNT)
            if not hce_bytes or len(hce_bytes) < BINHCE_FEATURE_COUNT:
                break
            hce = np.frombuffer(hce_bytes, dtype=np.uint8)

            raw_move_int = extra_data['move'][0]
            move_uci = decode_move_to_uci(raw_move_int, board)
            score = int(extra_data['score'][0])
            ply = int(extra_data['ply'][0])
            result = int(extra_data['result'][0])
            fen = board.fen(shredder=False)

            out_f.write(f"fen {fen}\n")
            out_f.write(f"move {move_uci}\n")
            out_f.write(f"score {score}\n")
            out_f.write(f"ply {ply}\n")
            out_f.write(f"result {result}\n")
            out_f.write("hce " + ",".join(str(int(v)) for v in hce.tolist()) + "\n")
            out_f.write("e\n")

            position_index += 1
            if position_index % 1000 == 0:
                print(f"Progress: {position_index} positions processed")

    print(f"Done. Positions processed: {position_index}")
    print(f"Output written to {output_filename}")


if __name__ == "__main__":
    fname = sys.argv[1] if len(sys.argv) > 1 else "dataset.binhce"
    process_bin_file(fname)
