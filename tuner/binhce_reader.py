"""
Utilities for reading .binhce files (bin40 + HCE feature vector).
Exports `iter_binhce` (streaming generator) and `load_binhce` (materialize to list).
The layout matches `src/datagen_writer.zig`:
- 32 bytes packed SFEN
- 2 bytes score (i16), 2 bytes move16 (u16), 2 bytes ply (u16), 1 byte result (i8), 1 byte padding
- 1168 bytes HCE feature vector (u8)
"""
from __future__ import annotations

import dataclasses
from typing import Generator, Iterable, Optional
import numpy as np
import chess

BINHCE_FEATURE_COUNT = 1536

REVERSE_HUFFMAN = {
    (0, 1): 0,    # None
    (1, 4): 1,    # Pawn
    (3, 4): 2,    # Knight
    (5, 4): 3,    # Bishop
    (7, 4): 4,    # Rook
    (9, 4): 5,    # Queen
}


def _decode_bit(data: np.ndarray, pos: int) -> tuple[int, int]:
    byte_idx = pos // 8
    bit_offset = pos % 8
    value = (data[byte_idx] >> bit_offset) & 1
    return int(value), pos + 1


def _decode_bits(data: np.ndarray, pos: int, nbits: int) -> tuple[int, int]:
    value = 0
    for i in range(nbits):
        bit, pos = _decode_bit(data, pos)
        value |= (bit << i)
    return value, pos


def _decode_piece_at(data: np.ndarray, pos: int):
    bit, pos = _decode_bit(data, pos)
    if bit == 0:
        return None, None, pos
    code = bit
    for i in range(3):
        bit, pos = _decode_bit(data, pos)
        code |= (bit << (i + 1))
    piece_type = REVERSE_HUFFMAN.get((code, 4), None)
    if piece_type is None:
        return None, None, pos
    color_bit, pos = _decode_bit(data, pos)
    color = chess.WHITE if color_bit == 0 else chess.BLACK
    return piece_type, color, pos


def _find_rooks(board: chess.Board, color: chess.Color):
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


def _decode_position(data: np.ndarray) -> chess.Board:
    board = chess.Board(None)
    board.chess960 = False
    pos = 0

    side, pos = _decode_bit(data, pos)
    board.turn = chess.WHITE if side == 0 else chess.BLACK

    wk_sq, pos = _decode_bits(data, pos, 6)
    bk_sq, pos = _decode_bits(data, pos, 6)
    board.set_piece_at(wk_sq, chess.Piece(chess.KING, chess.WHITE))
    board.set_piece_at(bk_sq, chess.Piece(chess.KING, chess.BLACK))

    for r in reversed(range(8)):
        for f in range(8):
            sq = r * 8 + f
            if sq not in (wk_sq, bk_sq):
                piece_type, color, pos = _decode_piece_at(data, pos)
                if piece_type:
                    board.set_piece_at(sq, chess.Piece(piece_type, color))

    wk_castle, pos = _decode_bit(data, pos)
    wq_castle, pos = _decode_bit(data, pos)
    bk_castle, pos = _decode_bit(data, pos)
    bq_castle, pos = _decode_bit(data, pos)

    castling_rights = 0
    w_left, w_right = _find_rooks(board, chess.WHITE)
    b_left, b_right = _find_rooks(board, chess.BLACK)

    def assign_castle(color, kingside, enabled, left_rooks, right_rooks):
        nonlocal castling_rights
        if not enabled:
            return
        king_sq = board.king(color)
        if king_sq is None:
            return
        rank = 0 if color == chess.WHITE else 7
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

    ep_flag, pos = _decode_bit(data, pos)
    if ep_flag:
        ep_square, pos = _decode_bits(data, pos, 6)
        board.ep_square = ep_square
    else:
        board.ep_square = None

    board.halfmove_clock, pos = _decode_bits(data, pos, 6)
    fullmove_low, pos = _decode_bits(data, pos, 8)
    fullmove_high, pos = _decode_bits(data, pos, 8)
    high_bit, pos = _decode_bit(data, pos)
    board.fullmove_number = fullmove_low | (fullmove_high << 8)
    board.halfmove_clock |= (high_bit << 6)
    return board


@dataclasses.dataclass
class BinhceRecord:
    """One record from a .binhce file."""
    sfen32: bytes
    score: int
    move16: int
    ply: int
    result: int
    features: np.ndarray
    fen: str


def iter_binhce(path: str, max_positions: Optional[int] = None) -> Generator[BinhceRecord, None, None]:
    """Stream records from a .binhce file.

    Args:
        path: path to the .binhce file.
        max_positions: optional cap for early stopping.
    Yields:
        BinhceRecord with SFEN32 bytes, metadata, full feature vector, and FEN.
    """
    count = 0
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

            sfen_arr = np.frombuffer(sfen_bytes, dtype=np.uint8)
            board = _decode_position(sfen_arr)
            fen = board.fen(shredder=False)

            extra_arr = np.frombuffer(extra, dtype=[
                ("score", np.int16),
                ("move", np.uint16),
                ("ply", np.uint16),
                ("result", np.int8),
                ("padding", np.uint8),
            ])
            feat_vec = np.frombuffer(feat_bytes, dtype=np.uint8)

            yield BinhceRecord(
                sfen32=sfen_bytes,
                score=int(extra_arr["score"][0]),
                move16=int(extra_arr["move"][0]),
                ply=int(extra_arr["ply"][0]),
                result=int(extra_arr["result"][0]),
                features=feat_vec.copy(),
                fen=fen,
            )
            count += 1
            if max_positions is not None and count >= max_positions:
                break


def load_binhce(path: str, max_positions: Optional[int] = None) -> list[BinhceRecord]:
    return list(iter_binhce(path, max_positions=max_positions))
