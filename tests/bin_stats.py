import numpy as np
import chess
from typing import Tuple, Optional, List, Dict
import matplotlib.pyplot as plt
import chess.polyglot

HUFFMAN_TABLE = [np.uint8(0), np.uint8(1), np.uint8(3), np.uint8(5), np.uint8(7), np.uint8(9)]
REVERSE_HUFFMAN = {
    (0, 1): 0,    # None
    (1, 4): 1,    # Pawn
    (3, 4): 2,    # Knight
    (5, 4): 3,    # Bishop
    (7, 4): 4,    # Rook
    (9, 4): 5     # Queen
}

piece_symbols = ['P', 'N', 'B', 'R', 'Q', 'K', 'p', 'n', 'b', 'r', 'q', 'k']

def decode_bit(data: np.ndarray, pos: int) -> Tuple[int, int]:
    byte_idx = pos // 8
    bit_offset = pos % 8
    value = (data[byte_idx] >> bit_offset) & 1
    return value, pos + 1

def decode_bits(data: np.ndarray, pos: int, nbits: int) -> Tuple[int, int]:
    value = 0
    for i in range(nbits):
        bit, pos = decode_bit(data, pos)
        value |= (bit << i)
    return value, pos

def decode_piece_at(data: np.ndarray, pos: int) -> Tuple[Optional[int], Optional[bool], int]:
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

def decode_position(data: np.ndarray) -> chess.Board:
    board = chess.Board(None)
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
    board.castling_rights = (
        (chess.BB_H1 if wk_castle else 0) |
        (chess.BB_A1 if wq_castle else 0) |
        (chess.BB_H8 if bk_castle else 0) |
        (chess.BB_A8 if bq_castle else 0)
    )

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
    flags = (move_int >> 14) & 0x3
    promotion = (move_int >> 12) & 0x3

    from_str = chess.square_name(from_sq)
    to_str = chess.square_name(to_sq)

    if flags == 3:
        if board.turn == chess.WHITE:
            if to_sq == 7: return "e1g1"
            elif to_sq == 0: return "e1c1"
        else:
            if to_sq == 63: return "e8g8"
            elif to_sq == 56: return "e8c8"
    if flags == 1:
        promo_map = {0: 'n', 1: 'b', 2: 'r', 3: 'q'}
        return from_str + to_str + promo_map.get(promotion, '')
    return from_str + to_str

def read_bin_file(filename: str, startpos: int = 0, endpos: int = float('inf')) -> Dict:
    position_size = 40
    positions: List[Dict] = []
    stats = {
        "white_wins": 0, "black_wins": 0, "draws": 0, "total": 0,
        "scores": [], "plies": [], "material_counts": [],
        "piece_counts_by_ply": {0: {}, 10: {}, 20: {}, 30: {}, 40: {}, 50: {}, 60: {}, 70: {}, 80: {}, 90: {}, 100: {}, 110: {}, 120: {}, 130: {}, 140: {}, 150: {}, 160: {}, 170: {}, 180: {}},
        "white_to_move": 0, "unique_hashes": set(), "legal_moves_count": [],
        "white_king_positions": np.zeros((8, 8), dtype=int),
        "black_king_positions": np.zeros((8, 8), dtype=int),
        "unique_pawn_structures": set(),
        "num_games": 0
    }

    for ply_group in stats["piece_counts_by_ply"]:
        stats["piece_counts_by_ply"][ply_group] = {symbol: 0 for symbol in piece_symbols}

    prev_ply = float('inf')

    with open(filename, 'rb') as f:
        f.seek(startpos * position_size)
        pos_index = startpos
        
        while pos_index < endpos:
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

            side_to_move = "White" if board.turn == chess.WHITE else "Black"
            move_uci = decode_move_to_uci(extra_data['move'][0], board)
            try:
                move = chess.Move.from_uci(move_uci)
                is_legal = move in board.legal_moves
            except ValueError:
                is_legal = False

            position = {
                "index": pos_index,
                "board": board.copy(),
                "fen": board.fen(),
                "side_to_move": side_to_move,
                "move": move_uci,
                "move_legal": is_legal,
                "score": extra_data['score'][0],
                "ply": extra_data['ply'][0],
                "result": extra_data['result'][0],
                "raw_move_int": extra_data['move'][0]
            }
            positions.append(position)

            result = extra_data['result'][0]
            stats["total"] += 1
            if result == 1:
                stats["white_wins"] += 1
            elif result == -1:
                stats["black_wins"] += 1
            elif result == 0:
                stats["draws"] += 1

            current_ply = extra_data['ply'][0]
            if current_ply < prev_ply:
                stats["num_games"] += 1
            prev_ply = current_ply

            stats["scores"].append(extra_data['score'][0])
            stats["plies"].append(extra_data['ply'][0])
            stats["white_to_move"] += 1 if board.turn == chess.WHITE else 0
            stats["unique_hashes"].add(chess.polyglot.zobrist_hash(board))
            stats["legal_moves_count"].append(len(list(board.legal_moves)))

            wk_sq = board.king(chess.WHITE)
            bk_sq = board.king(chess.BLACK)
            wk_rank, wk_file = chess.square_rank(wk_sq), chess.square_file(wk_sq)
            bk_rank, bk_file = chess.square_rank(bk_sq), chess.square_file(bk_sq)
            stats["white_king_positions"][7 - wk_rank, wk_file] += 1
            stats["black_king_positions"][7 - bk_rank, bk_file] += 1

            pawn_fen = board.fen().split(" ")[0]
            pawn_fen = ''.join(
                '.' if c in 'KQRBNkqrbn' else
                '.' * int(c) if c in '12345678' else
                c for c in pawn_fen
            )
            stats["unique_pawn_structures"].add(pawn_fen)

            material = sum(
                1 * len(board.pieces(piece_type, color))
                for piece_type, value in [(chess.PAWN, 1), (chess.KNIGHT, 3), (chess.BISHOP, 3),
                                        (chess.ROOK, 5), (chess.QUEEN, 9)]
                for color in [chess.WHITE, chess.BLACK]
            )
            stats["material_counts"].append(material)

            ply_group = (extra_data['ply'][0] // 10) * 10
            if ply_group > 180:
                ply_group = 180
            for square in chess.SQUARES:
                piece = board.piece_at(square)
                if piece:
                    stats["piece_counts_by_ply"][ply_group][piece.symbol()] += 1

            pos_index += 1

    return {"positions": positions, "stats": stats}

def combine_results(results: List[Dict]) -> Dict:
    if not results:
        return {"positions": [], "stats": {}}

    combined = {"positions": [], "stats": {}}

    for result in results:
        combined["positions"].extend(result["positions"])

    combined["stats"] = {key: 0 if isinstance(val, (int, np.integer)) else 
                        [] if isinstance(val, list) else 
                        set() if isinstance(val, set) else 
                        np.zeros_like(val) if isinstance(val, np.ndarray) else 
                        {} for key, val in results[0]["stats"].items()}

    for result in results:
        for key, val in result["stats"].items():
            if isinstance(val, (int, np.integer)):
                combined["stats"][key] += val
            elif isinstance(val, list):
                combined["stats"][key].extend(val)
            elif isinstance(val, set):
                combined["stats"][key] |= val
            elif isinstance(val, np.ndarray):
                combined["stats"][key] += val
            elif isinstance(val, dict):
                for ply_group, counts in val.items():
                    if ply_group not in combined["stats"][key]:
                        combined["stats"][key][ply_group] = {}
                    for piece, count in counts.items():
                        combined["stats"][key][ply_group][piece] = combined["stats"][key][ply_group].get(piece, 0) + count

    return combined

def print_stats(stats):
    print("Statistics:")
    print(f"Total positions: {stats['total']}")
    print(f"Number of games: {stats['num_games']}")
    print(f"White wins: {stats['white_wins']} ({stats['white_wins']/stats['total']*100:.1f}%)")
    print(f"Black wins: {stats['black_wins']} ({stats['black_wins']/stats['total']*100:.1f}%)")
    print(f"Draws: {stats['draws']} ({stats['draws']/stats['total']*100:.1f}%)")

    scores = np.array(stats['scores'])
    plt.figure(figsize=(10, 6))
    plt.hist(scores, bins=20, range=(-1000, 1000), color='blue', alpha=0.7, weights=np.ones(len(scores)) / stats['total'] * 100)
    plt.title("Score Distribution (centipawns)")
    plt.xlabel("Score")
    plt.ylabel("Frequency (%)")
    plt.grid(True)
    score_quartiles = np.percentile(scores, [25, 50, 75])
    for q, label in zip(score_quartiles, ['Q1', 'Median', 'Q3']):
        plt.axvline(q, color='red', linestyle='--', label=f'{label}={q:.0f}')
    plt.legend()
    plt.show()
    print(f"Score Quartiles: Q1={score_quartiles[0]:.0f}, Median={score_quartiles[1]:.0f}, Q3={score_quartiles[2]:.0f}")

    plies = np.array(stats['plies'])
    plt.figure(figsize=(10, 6))
    plt.hist(plies, bins=18, range=(0, 180), color='green', alpha=0.7, weights=np.ones(len(plies)) / stats['total'] * 100)
    plt.title("Ply Distribution")
    plt.xlabel("Ply")
    plt.ylabel("Frequency (%)")
    plt.grid(True)
    ply_quartiles = np.percentile(plies, [25, 50, 75])
    for q, label in zip(ply_quartiles, ['Q1', 'Median', 'Q3']):
        plt.axvline(q, color='red', linestyle='--', label=f'{label}={q:.0f}')
    plt.legend()
    plt.show()
    print(f"Ply Quartiles: Q1={ply_quartiles[0]:.0f}, Median={ply_quartiles[1]:.0f}, Q3={ply_quartiles[2]:.0f}")

    material = np.array(stats['material_counts'])
    plt.figure(figsize=(10, 6))
    plt.hist(material, bins=20, range=(0, 40), color='purple', alpha=0.7, weights=np.ones(len(material)) / stats['total'] * 100)
    plt.title("Material Distribution (pawn units)")
    plt.xlabel("Material")
    plt.ylabel("Frequency (%)")
    plt.grid(True)
    material_quartiles = np.percentile(material, [25, 50, 75])
    for q, label in zip(material_quartiles, ['Q1', 'Median', 'Q3']):
        plt.axvline(q, color='red', linestyle='--', label=f'{label}={q:.0f}')
    plt.legend()
    plt.show()
    print(f"Material Quartiles: Q1={material_quartiles[0]:.0f}, Median={material_quartiles[1]:.0f}, Q3={material_quartiles[2]:.0f}")
    print("Game Phase Distribution:")
    opening = sum(1 for m in material if m > 28)
    middlegame = sum(1 for m in material if 12 <= m <= 28)
    endgame = sum(1 for m in material if m < 12)
    print(f"Opening (>28): {opening} ({opening/stats['total']*100:.1f}%)")
    print(f"Middlegame (12-28): {middlegame} ({middlegame/stats['total']*100:.1f}%)")
    print(f"Endgame (<12): {endgame} ({endgame/stats['total']*100:.1f}%)")

    ply_groups = sorted(stats["piece_counts_by_ply"].keys())
    white_pawn_counts = []
    black_pawn_counts = []
    labels = []
    for ply_group in ply_groups:
        total_positions = sum(1 for p in stats['plies'] if ply_group <= p < ply_group + 10) if ply_group < 180 else sum(1 for p in stats['plies'] if p >= 180)
        if total_positions > 0:
            white_pawn_counts.append(stats["piece_counts_by_ply"][ply_group]['P'] / total_positions)
            black_pawn_counts.append(stats["piece_counts_by_ply"][ply_group]['p'] / total_positions)
            labels.append(f"{ply_group}-{ply_group+9 if ply_group < 180 else '+180'}")
    if labels:
        plt.figure(figsize=(10, 6))
        x = np.arange(len(labels))
        plt.bar(x - 0.2, white_pawn_counts, 0.4, label='White Pawns', color='lightblue')
        plt.bar(x + 0.2, black_pawn_counts, 0.4, label='Black Pawns', color='salmon')
        plt.xticks(x, labels, rotation=45)
        plt.title("Average Pawn Count by Ply Group")
        plt.xlabel("Ply Group")
        plt.ylabel("Average Pawns per Position")
        plt.legend()
        plt.grid(True)
        plt.show()

    piece_counts = {piece: [] for piece in piece_symbols}
    for ply_group in ply_groups:
        total_positions = sum(1 for p in stats['plies'] if ply_group <= p < ply_group + 10) if ply_group < 180 else sum(1 for p in stats['plies'] if p >= 180)
        if total_positions > 0:
            for piece in piece_symbols:
                piece_counts[piece].append(stats["piece_counts_by_ply"][ply_group][piece] / total_positions)
    if labels:
        plt.figure(figsize=(12, 8))
        for piece in piece_symbols:
            if max(piece_counts[piece]) > 0:
                plt.plot(labels, piece_counts[piece], label=piece, marker='o')
        plt.title("Average Piece Count by Ply Group")
        plt.xlabel("Ply Group")
        plt.ylabel("Average Pieces per Position")
        plt.legend(bbox_to_anchor=(1.05, 1), loc='upper left')
        plt.grid(True)
        plt.xticks(rotation=45)
        plt.tight_layout()
        plt.show()

    legal_moves = np.array(stats["legal_moves_count"])
    plt.figure(figsize=(10, 6))
    plt.hist(legal_moves, bins=20, range=(0, 80), color='orange', alpha=0.7, weights=np.ones(len(legal_moves)) / stats['total'] * 100)
    plt.title("Legal Moves Count Distribution")
    plt.xlabel("Number of Legal Moves")
    plt.ylabel("Frequency (%)")  # Changed to % as per your style
    plt.grid(True)
    legal_quartiles = np.percentile(legal_moves, [25, 50, 75])
    for q, label in zip(legal_quartiles, ['Q1', 'Median', 'Q3']):
        plt.axvline(q, color='red', linestyle='--', label=f'{label}={q:.0f}')
    plt.legend()
    plt.show()
    print(f"Legal Moves Quartiles: Q1={legal_quartiles[0]:.0f}, Median={legal_quartiles[1]:.0f}, Q3={legal_quartiles[2]:.0f}")

    plt.figure(figsize=(8, 8))
    plt.imshow(stats["white_king_positions"] / stats["total"] * 100, cmap='coolwarm', interpolation='nearest')
    plt.title("White King Position Heatmap")
    plt.xlabel("File (a-h)")
    plt.ylabel("Rank (1-8)")
    plt.xticks(np.arange(8), ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'])
    plt.yticks(np.arange(8), ['8', '7', '6', '5', '4', '3', '2', '1'])
    plt.colorbar(label='Frequency (%)')
    for i in range(8):
        for j in range(8):
            if stats["white_king_positions"][i, j] > 0:
                plt.text(j, i, f"{stats['white_king_positions'][i, j] / stats['total'] * 100:.1f}", ha='center', va='center', color='black')
    plt.show()

    plt.figure(figsize=(8, 8))
    plt.imshow(stats["black_king_positions"] / stats["total"] * 100, cmap='coolwarm', interpolation='nearest')
    plt.title("Black King Position Heatmap")
    plt.xlabel("File (a-h)")
    plt.ylabel("Rank (1-8)")
    plt.xticks(np.arange(8), ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'])
    plt.yticks(np.arange(8), ['8', '7', '6', '5', '4', '3', '2', '1'])
    plt.colorbar(label='Frequency (%)')
    for i in range(8):
        for j in range(8):
            if stats["black_king_positions"][i, j] > 0:
                plt.text(j, i, f"{stats['black_king_positions'][i, j] / stats['total'] * 100:.1f}", ha='center', va='center', color='black')
    plt.show()

    print(f"\nSide-to-Move Balance:")
    print(f"White to move: {stats['white_to_move']} ({stats['white_to_move']/stats['total']*100:.1f}%)")
    print(f"Black to move: {stats['total'] - stats['white_to_move']} ({(stats['total'] - stats['white_to_move'])/stats['total']*100:.1f}%)")

    print(f"\nUnique Positions: {len(stats['unique_hashes'])} ({len(stats['unique_hashes'])/stats['total']*100:.1f}%)")

    print(f"\nPawn Structure Diversity:")
    print(f"Unique pawn structures: {len(stats['unique_pawn_structures'])} ({len(stats['unique_pawn_structures'])/stats['total']*100:.1f}%)")

if __name__ == "__main__":
    #files = ["ser7_15_0.bin", "ser7_15_1.bin", "ser7_15_2.bin", "ser7_15_3.bin", "ser7_15_4.bin", "ser7_15_5.bin", "ser7_15_6.bin", "ser7_15_7.bin", "ser7_15_8.bin", "ser7_15_9.bin", "ser7_15_10.bin", "ser7_15_11.bin"]
    files = ["test4.bin"]
    results = [read_bin_file(file, startpos=0, endpos=float('inf')) for file in files]
    #files = ["ser7_16_0.bin"]
    #results = [read_bin_file(file, startpos=0, endpos=3_000_000) for file in files]    
    combined_result = combine_results(results)
    print_stats(combined_result["stats"])
    
    # Optional: Access combined data
    print("\nFirst position FEN from combined data:", combined_result["positions"][0]["fen"])
    print("Total positions from combined data:", combined_result["stats"]["total"])