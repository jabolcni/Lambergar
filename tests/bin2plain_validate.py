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

def debug_move_decoding(raw_move_int: int, board: chess.Board, position_index: int):
    """Debug the move decoding process in detail"""
    print(f"\n=== MOVE DECODING DEBUG for position {position_index} ===")
    print(f"Raw move integer: 0x{raw_move_int:04x} ({raw_move_int})")
    
    # Decode individual fields
    to_sq = raw_move_int & 0x3F
    from_sq = (raw_move_int >> 6) & 0x3F
    promotion = (raw_move_int >> 12) & 0x3
    flags = (raw_move_int >> 14) & 0x3
    
    print(f"From square: {from_sq} = {chess.square_name(from_sq)}")
    print(f"To square: {to_sq} = {chess.square_name(to_sq)}")
    print(f"Promotion code: {promotion}")
    print(f"Flags: {flags}")
    
    # Show what piece is at from_square
    from_piece = board.piece_at(from_sq)
    to_piece = board.piece_at(to_sq)
    print(f"Piece at from_square: {from_piece}")
    print(f"Piece at to_square: {to_piece}")
    
    # Generate the UCI move
    move_uci = decode_move_to_uci(raw_move_int, board)
    print(f"Generated UCI: {move_uci}")
    
    # Show all legal moves for comparison
    print("All legal moves from current position:")
    legal_moves = list(board.legal_moves)
    for move in legal_moves:
        print(f"  {move.uci()}")
    
    # Try to find a move that matches the from/to squares
    matching_moves = [move for move in legal_moves 
                     if move.from_square == from_sq and move.to_square == to_sq]
    if matching_moves:
        print(f"Matching legal moves: {[move.uci() for move in matching_moves]}")
    else:
        print("No legal moves match the from/to squares!")
        
        # Find moves from the same from_square
        from_square_moves = [move for move in legal_moves if move.from_square == from_sq]
        if from_square_moves:
            print(f"Legal moves from {chess.square_name(from_sq)}: {[move.uci() for move in from_square_moves]}")
    
    print("==============================\n")

def process_bin_file(filename: str):
    output_filename = filename.replace('.bin', '.plain2')
    position_index = 0
    stats = {
        'total': 0,
        'normal_moves': 0,
        'promotions': 0,
        'castling': 0,
        'en_passant': 0,
        'errors': 0
    }
    
    with open(filename, 'rb') as f, open(output_filename, 'w') as out_f:
        while True:
            pos_data = f.read(32)
            if not pos_data:
                break
            data = np.frombuffer(pos_data, dtype=np.uint8)
            board = decode_position(data)

            extra_data_bytes = f.read(8)
            if not extra_data_bytes:
                break
            extra_data = np.frombuffer(extra_data_bytes, dtype=[
                ('score', np.int16),
                ('move', np.uint16),
                ('ply', np.uint16),
                ('result', np.int8),
                ('padding', np.uint8)
            ])

            raw_move_int = extra_data['move'][0]
            move_uci = decode_move_to_uci(raw_move_int, board)
            
            # Count move types
            flags = (raw_move_int >> 14) & 0x3
            if flags == 0:
                stats['normal_moves'] += 1
            elif flags == 1:
                stats['promotions'] += 1
            elif flags == 2:
                stats['en_passant'] += 1
            elif flags == 3:
                stats['castling'] += 1
            
            # Validate the move
            try:
                move = board.parse_uci(move_uci)
                if not board.is_legal(move):
                    print(f"✗ Invalid move: {move_uci} at index {position_index}")
                    debug_move_decoding(raw_move_int, board, position_index)
                    stats['errors'] += 1
            except ValueError as e:
                print(f"✗ Invalid move UCI: {move_uci} at index {position_index}: {str(e)}")
                debug_move_decoding(raw_move_int, board, position_index)
                stats['errors'] += 1

            score = extra_data['score'][0]
            ply = extra_data['ply'][0]
            result = extra_data['result'][0]
            fen = board.fen(shredder=False)

            out_f.write(f"fen {fen}\n")
            out_f.write(f"move {move_uci}\n")
            out_f.write(f"score {score}\n")
            out_f.write(f"ply {ply}\n")
            out_f.write(f"result {result}\n")
            out_f.write("e\n")
            
            position_index += 1
            stats['total'] += 1
            
            # Print progress every 1000 positions
            if position_index % 1000 == 0:
                print(f"Progress: {position_index} positions validated")
                print(f"  Move statistics:")
                print(f"    Normal moves: {stats['normal_moves']} ({stats['normal_moves']/stats['total']*100:.1f}%)")
                print(f"    Promotions: {stats['promotions']} ({stats['promotions']/stats['total']*100:.1f}%)")
                print(f"    Castling: {stats['castling']} ({stats['castling']/stats['total']*100:.1f}%)")
                print(f"    En passant: {stats['en_passant']} ({stats['en_passant']/stats['total']*100:.1f}%)")
                print(f"    Total errors: {stats['errors']}")
                print("---")
    
    # Final statistics
    print("\n=== FINAL STATISTICS ===")
    print(f"Total positions processed: {stats['total']}")
    print(f"Move type distribution:")
    print(f"  Normal moves: {stats['normal_moves']} ({stats['normal_moves']/stats['total']*100:.1f}%)")
    print(f"  Promotions: {stats['promotions']} ({stats['promotions']/stats['total']*100:.1f}%)")
    print(f"  Castling: {stats['castling']} ({stats['castling']/stats['total']*100:.1f}%)")
    print(f"  En passant: {stats['en_passant']} ({stats['en_passant']/stats['total']*100:.1f}%)")
    print(f"Total errors: {stats['errors']}")
    
    if stats['errors'] == 0:
        print("✓ All moves validated successfully!")
    else:
        print(f"✗ Found {stats['errors']} invalid moves")

if __name__ == "__main__":
    process_bin_file("test8.bin")



# import numpy as np
# import chess
# import sys

# REVERSE_HUFFMAN = {
#     (0, 1): 0,    # None
#     (1, 4): 1,    # Pawn
#     (3, 4): 2,    # Knight
#     (5, 4): 3,    # Bishop
#     (7, 4): 4,    # Rook
#     (9, 4): 5     # Queen
# }

# def decode_bit(data: np.ndarray, pos: int) -> tuple:
#     byte_idx = pos // 8
#     bit_offset = pos % 8
#     value = (data[byte_idx] >> bit_offset) & 1
#     return value, pos + 1

# def decode_bits(data: np.ndarray, pos: int, nbits: int) -> tuple:
#     value = 0
#     for i in range(nbits):
#         bit, pos = decode_bit(data, pos)
#         value |= (bit << i)
#     return value, pos

# def decode_piece_at(data: np.ndarray, pos: int) -> tuple:
#     bit, pos = decode_bit(data, pos)
#     if bit == 0:
#         return None, None, pos
    
#     code = bit
#     for i in range(3):
#         bit, pos = decode_bit(data, pos)
#         code |= (bit << (i + 1))
#     piece_type = REVERSE_HUFFMAN.get((code, 4), None)
#     if piece_type is None:
#         return None, None, pos
    
#     color_bit, pos = decode_bit(data, pos)
#     color = chess.WHITE if color_bit == 0 else chess.BLACK
#     return piece_type, color, pos

# def find_rooks(board, color):
#     rank = 0 if color == chess.WHITE else 7
#     king_file = chess.square_file(board.king(color))
#     left_rooks = []
#     right_rooks = []
#     for file in range(8):
#         sq = chess.square(file, rank)
#         piece = board.piece_at(sq)
#         if piece and piece.piece_type == chess.ROOK and piece.color == color:
#             if file < king_file:
#                 left_rooks.append(file)
#             elif file > king_file:
#                 right_rooks.append(file)
#     left_rooks.sort()
#     right_rooks.sort()
#     return left_rooks, right_rooks

# def decode_position(data: np.ndarray) -> chess.Board:
#     board = chess.Board(None)
#     board.chess960 = True
#     pos = 0

#     side, pos = decode_bit(data, pos)
#     board.turn = chess.WHITE if side == 0 else chess.BLACK

#     wk_sq, pos = decode_bits(data, pos, 6)
#     bk_sq, pos = decode_bits(data, pos, 6)
#     board.set_piece_at(wk_sq, chess.Piece(chess.KING, chess.WHITE))
#     board.set_piece_at(bk_sq, chess.Piece(chess.KING, chess.BLACK))

#     for r in reversed(range(8)):
#         for f in range(8):
#             sq = r * 8 + f
#             if sq not in (wk_sq, bk_sq):
#                 piece_type, color, pos = decode_piece_at(data, pos)
#                 if piece_type:
#                     board.set_piece_at(sq, chess.Piece(piece_type, color))

#     wk_castle, pos = decode_bit(data, pos)
#     wq_castle, pos = decode_bit(data, pos)
#     bk_castle, pos = decode_bit(data, pos)
#     bq_castle, pos = decode_bit(data, pos)

#     castling_rights = 0
#     w_left, w_right = find_rooks(board, chess.WHITE)
#     if wq_castle and w_left:
#         castling_rights |= chess.BB_SQUARES[chess.square(w_left[-1], 0)]
#     if wk_castle and w_right:
#         castling_rights |= chess.BB_SQUARES[chess.square(w_right[0], 0)]
#     b_left, b_right = find_rooks(board, chess.BLACK)
#     if bq_castle and b_left:
#         castling_rights |= chess.BB_SQUARES[chess.square(b_left[-1], 7)]
#     if bk_castle and b_right:
#         castling_rights |= chess.BB_SQUARES[chess.square(b_right[0], 7)]
#     board.castling_rights = castling_rights

#     ep_flag, pos = decode_bit(data, pos)
#     if ep_flag:
#         ep_square, pos = decode_bits(data, pos, 6)
#         board.ep_square = ep_square
#     else:
#         board.ep_square = None

#     board.halfmove_clock, pos = decode_bits(data, pos, 6)
#     fullmove_low, pos = decode_bits(data, pos, 8)
#     fullmove_high, pos = decode_bits(data, pos, 8)
#     high_bit, pos = decode_bit(data, pos)
#     board.fullmove_number = fullmove_low | (fullmove_high << 8)
#     board.halfmove_clock |= (high_bit << 6)

#     return board

# def decode_move_to_uci(move_int: int, board: chess.Board) -> str:
#     to_sq = move_int & 0x3F
#     from_sq = (move_int >> 6) & 0x3F
#     promotion = (move_int >> 12) & 0x3
#     flags = (move_int >> 14) & 0x3

#     from_str = chess.square_name(from_sq)
#     to_str = chess.square_name(to_sq)

#     if flags == 3:  # Castling
#         king_from = from_sq
#         king_to = to_sq
#         king_file = chess.square_file(king_from)
#         rank = chess.square_rank(king_from)
#         color = board.turn
        
#         # Get castling rights for this color
#         castling_rights = board.castling_rights
#         available_rooks = []
#         for sq in chess.SQUARES:
#             if castling_rights & chess.BB_SQUARES[sq] and chess.square_rank(sq) == rank:
#                 available_rooks.append(sq)
        
#         # Smart detection: try to determine the correct rook
#         king_to_file = chess.square_file(king_to)
        
#         # If king moves toward a rook, use that rook
#         possible_rooks = []
#         for rook_sq in available_rooks:
#             rook_file = chess.square_file(rook_sq)
#             if (king_to_file > king_file and rook_file > king_file) or \
#                (king_to_file < king_file and rook_file < king_file):
#                 possible_rooks.append(rook_sq)
        
#         if possible_rooks:
#             # Prefer the rook that's closer to the king's destination
#             rook_sq = min(possible_rooks, key=lambda rs: abs(chess.square_file(rs) - king_to_file))
#         else:
#             # Fallback: use the rook in the direction the king moved
#             if king_to_file > king_file:
#                 rook_sq = max(available_rooks, key=chess.square_file)
#             else:
#                 rook_sq = min(available_rooks, key=chess.square_file)
        
#         result = from_str + chess.square_name(rook_sq)
#         return result
#     elif flags == 1:  # Promotion
#         promo_map = {0: 'n', 1: 'b', 2: 'r', 3: 'q'}
#         return from_str + to_str + promo_map.get(promotion, '')
#     else:  # Normal move
#         return from_str + to_str

# def get_all_castling_options(move_int: int, board: chess.Board):
#     """Get all possible castling UCI moves for this position"""
#     from_sq = (move_int >> 6) & 0x3F
#     king_from_str = chess.square_name(from_sq)
#     rank = chess.square_rank(from_sq)
    
#     # Get castling rights for this color
#     castling_rights = board.castling_rights
#     available_rooks = []
#     for sq in chess.SQUARES:
#         if castling_rights & chess.BB_SQUARES[sq] and chess.square_rank(sq) == rank:
#             available_rooks.append(sq)
    
#     options = []
#     for rook_sq in available_rooks:
#         options.append(king_from_str + chess.square_name(rook_sq))
    
#     return options

# def process_bin_file(filename: str):
#     output_filename = filename.replace('.bin', '.plain2')
#     position_index = 0
#     stats = {
#         'total': 0,
#         'normal_moves': 0,
#         'promotions': 0,
#         'castling': 0,
#         'en_passant': 0,
#         'errors': 0,
#         'castling_errors': 0,
#         'castling_fixed_smart': 0,
#         'castling_fixed_alternative': 0
#     }
    
#     with open(filename, 'rb') as f, open(output_filename, 'w') as out_f:
#         while True:
#             pos_data = f.read(32)
#             if not pos_data:
#                 break
#             data = np.frombuffer(pos_data, dtype=np.uint8)
#             board = decode_position(data)

#             extra_data_bytes = f.read(8)
#             if not extra_data_bytes:
#                 break
#             extra_data = np.frombuffer(extra_data_bytes, dtype=[
#                 ('score', np.int16),
#                 ('move', np.uint16),
#                 ('ply', np.uint16),
#                 ('result', np.int8),
#                 ('padding', np.uint8)
#             ])

#             raw_move_int = extra_data['move'][0]
#             original_move_uci = decode_move_to_uci(raw_move_int, board)
#             move_uci = original_move_uci
            
#             # Count move types
#             flags = (raw_move_int >> 14) & 0x3
#             if flags == 0:
#                 stats['normal_moves'] += 1
#             elif flags == 1:
#                 stats['promotions'] += 1
#             elif flags == 2:
#                 stats['en_passant'] += 1
#             elif flags == 3:
#                 stats['castling'] += 1
            
#             castling_debug_printed = False
            
#             try:
#                 # Try to parse the move as UCI
#                 move = board.parse_uci(move_uci)
#                 if not board.is_legal(move):
#                     # If castling move fails, try alternative castling moves
#                     if flags == 3:
#                         stats['castling_errors'] += 1
#                         king_from = (raw_move_int >> 6) & 0x3F
                        
#                         # First try: use smart detection to find alternative
#                         castling_options = get_all_castling_options(raw_move_int, board)
#                         smart_fixed = False
                        
#                         for option in castling_options:
#                             if option == original_move_uci:
#                                 continue  # Skip the original since it already failed
#                             try:
#                                 alt_move = board.parse_uci(option)
#                                 if board.is_legal(alt_move):
#                                     if not castling_debug_printed:
#                                         print_castling_debug(position_index, raw_move_int, board, original_move_uci, castling_options)
#                                         castling_debug_printed = True
#                                     print(f"✓ SMART CASTLING FIX: {original_move_uci} -> {option}")
#                                     move_uci = option
#                                     move = alt_move
#                                     stats['castling_fixed_smart'] += 1
#                                     smart_fixed = True
#                                     break
#                             except:
#                                 continue
                        
#                         # If smart detection failed, try all alternatives systematically
#                         if not smart_fixed:
#                             if not castling_debug_printed:
#                                 print_castling_debug(position_index, raw_move_int, board, original_move_uci, castling_options)
#                                 castling_debug_printed = True
                            
#                             print("Smart detection failed, testing all alternatives:")
#                             found_legal = False
#                             for i, option in enumerate(castling_options):
#                                 print(f"  Testing option {i+1}: {option}")
#                                 try:
#                                     test_move = board.parse_uci(option)
#                                     if board.is_legal(test_move):
#                                         print(f"  ✓ ALTERNATIVE CASTLING WORKED: {option}")
#                                         move_uci = option
#                                         move = test_move
#                                         found_legal = True
#                                         stats['castling_fixed_alternative'] += 1
#                                         break
#                                     else:
#                                         print(f"  ✗ Invalid: {option}")
#                                 except ValueError as e:
#                                     print(f"  ✗ Invalid: {option} - {str(e)}")
                            
#                             if not found_legal:
#                                 print(f"✗ No legal castling move found")
#                                 stats['errors'] += 1
#                     else:
#                         print(f"✗ Invalid move: {move_uci} at index {position_index}")
#                         stats['errors'] += 1
#             except ValueError as e:
#                 # Handle parsing errors (like the b1e1 case)
#                 if flags == 3 and "illegal uci" in str(e):
#                     stats['castling_errors'] += 1
#                     if not castling_debug_printed:
#                         castling_options = get_all_castling_options(raw_move_int, board)
#                         print_castling_debug(position_index, raw_move_int, board, original_move_uci, castling_options)
#                         castling_debug_printed = True
                    
#                     print(f"✗ Parsing error: {original_move_uci}")
#                     print("Testing all alternatives:")
                    
#                     found_legal = False
#                     for i, option in enumerate(castling_options):
#                         print(f"  Testing option {i+1}: {option}")
#                         try:
#                             test_move = board.parse_uci(option)
#                             if board.is_legal(test_move):
#                                 print(f"  ✓ ALTERNATIVE CASTLING WORKED: {option}")
#                                 move_uci = option
#                                 move = test_move
#                                 found_legal = True
#                                 stats['castling_fixed_alternative'] += 1
#                                 break
#                             else:
#                                 print(f"  ✗ Invalid: {option}")
#                         except ValueError as e2:
#                             print(f"  ✗ Invalid: {option} - {str(e2)}")
                    
#                     if not found_legal:
#                         print(f"✗ No legal castling move found")
#                         stats['errors'] += 1
#                 else:
#                     print(f"✗ Invalid move UCI: {move_uci} at index {position_index}: {str(e)}")
#                     stats['errors'] += 1

#             score = extra_data['score'][0]
#             ply = extra_data['ply'][0]
#             result = extra_data['result'][0]
#             fen = board.fen(shredder=True)

#             out_f.write(f"fen {fen}\n")
#             out_f.write(f"move {move_uci}\n")
#             out_f.write(f"score {score}\n")
#             out_f.write(f"ply {ply}\n")
#             out_f.write(f"result {result}\n")
#             out_f.write("e\n")
            
#             position_index += 1
#             stats['total'] += 1
            
#             # Print progress every 1000 positions
#             if position_index % 1000 == 0:
#                 print(f"Progress: {position_index} positions validated")
#                 print(f"  Move statistics:")
#                 print(f"    Normal moves: {stats['normal_moves']} ({stats['normal_moves']/stats['total']*100:.1f}%)")
#                 print(f"    Promotions: {stats['promotions']} ({stats['promotions']/stats['total']*100:.1f}%)")
#                 print(f"    Castling: {stats['castling']} ({stats['castling']/stats['total']*100:.1f}%)")
#                 print(f"    En passant: {stats['en_passant']} ({stats['en_passant']/stats['total']*100:.1f}%)")
#                 print(f"    Castling errors: {stats['castling_errors']}")
#                 print(f"    Smart fixes: {stats['castling_fixed_smart']}")
#                 print(f"    Alternative fixes: {stats['castling_fixed_alternative']}")
#                 print(f"    Total errors: {stats['errors']}")
#                 print("---")
    
#     # Final statistics
#     print("\n=== FINAL STATISTICS ===")
#     print(f"Total positions processed: {stats['total']}")
#     print(f"Move type distribution:")
#     print(f"  Normal moves: {stats['normal_moves']} ({stats['normal_moves']/stats['total']*100:.1f}%)")
#     print(f"  Promotions: {stats['promotions']} ({stats['promotions']/stats['total']*100:.1f}%)")
#     print(f"  Castling: {stats['castling']} ({stats['castling']/stats['total']*100:.1f}%)")
#     print(f"  En passant: {stats['en_passant']} ({stats['en_passant']/stats['total']*100:.1f}%)")
#     print(f"Castling errors: {stats['castling_errors']}")
#     print(f"Smart castling fixes: {stats['castling_fixed_smart']}")
#     print(f"Alternative castling fixes: {stats['castling_fixed_alternative']}")
#     print(f"Total errors: {stats['errors']}")
    
#     if stats['errors'] == 0:
#         print("✓ All moves validated successfully!")
#     else:
#         print(f"✗ Found {stats['errors']} invalid moves")

# def print_castling_debug(position_index, raw_move_int, board, original_move_uci, castling_options):
#     """Print detailed debug information for castling positions"""
#     from_sq = (raw_move_int >> 6) & 0x3F
#     to_sq = raw_move_int & 0x3F
    
#     print(f"=== DEBUG FOR POSITION {position_index} ===")
#     print(f"FEN: {board.fen(shredder=True)}")
#     print(f"Raw move: 0x{raw_move_int:04x}")
#     print(f"From square: {from_sq} = {chess.square_name(from_sq)}")
#     print(f"To square: {to_sq} = {chess.square_name(to_sq)}")
#     print(f"Flags: {(raw_move_int >> 14) & 0x3}")
#     print(f"Original UCI: {original_move_uci}")
#     print(f"Castling options: {castling_options}")
#     print("Board:")
#     print(board)
#     print("All legal moves:")
#     for legal_move in board.legal_moves:
#         print(f"  {legal_move.uci()}")
#     print("================================")

# if __name__ == "__main__":
#     process_bin_file("test6.bin")
