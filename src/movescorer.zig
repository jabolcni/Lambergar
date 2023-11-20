const std = @import("std");
const position = @import("position.zig");
const searcher = @import("search.zig");
const attacks = @import("attacks.zig");
const bb = @import("bitboard.zig");

const Move = position.Move;
const Position = position.Position;
const Piece = position.Piece;
const PieceType = position.PieceType;
const Color = position.Color;
const MoveFlags = position.MoveFlags;
const Search = searcher.Search;

pub const SortHash = 7000000;
pub const QueenPromotion = SortHash - 10;
pub const KnightPromotion = SortHash - 11;
pub const SortCapture = 6000000;
pub const SortKiller1 = 5000000;
pub const SortKiller2 = 4000000;
pub const SortBadCapture = -1000000;
pub const Badpromotion = -QueenPromotion;

// pawns, knights, bishops, rooks, queens, kings
const piece_val = [7]i32{ 100, 310, 330, 500, 1000, 20000, 0 };

pub inline fn score_move(pos: *Position, search: *Search, move_list: *std.ArrayList(Move), score_list: *std.ArrayList(i32), hash_move: Move, comptime color: Color) void {
    for (move_list.items) |move| {
        var score: i32 = 0;
        if (move.equal(hash_move)) {
            score = SortHash;
            //continue;
        } else if (move.is_promotion()) {
            switch (move.flags) {
                MoveFlags.PR_QUEEN => score = QueenPromotion,
                MoveFlags.PC_QUEEN => score = QueenPromotion,
                MoveFlags.PR_KNIGHT => score = KnightPromotion,
                MoveFlags.PC_KNIGHT => score = KnightPromotion,
                else => score = Badpromotion,
            }
        } else if (move.is_capture()) {
            if (see(pos, move, -98)) {
                score = 10 * piece_val[pos.board[move.to].type_of().toU3()] - piece_val[pos.board[move.from].type_of().toU3()] + SortCapture;
            } else {
                score = 10 * piece_val[pos.board[move.to].type_of().toU3()] - piece_val[pos.board[move.from].type_of().toU3()] + SortBadCapture;
            }
            //continue;
        } else {
            if (move.equal(search.mv_killer[search.ply][0])) {
                score = SortKiller1;
            } else if (move.equal(search.mv_killer[search.ply][1])) {
                score = SortKiller2;
            } else {
                comptime var side = if (color == Color.White) 0 else 1;
                score = search.sc_history[side][move.from][move.to];
            }
        }

        score_list.append(score) catch unreachable;
    }
}

pub inline fn get_next_best(move_list: *std.ArrayList(Move), score_list: *std.ArrayList(i32), i: usize) Move {
    var best_j = i;
    var max_score = score_list.items[i];

    for (score_list.items[i + 1 ..], i + 1..) |score, j| {
        if (score > max_score) {
            best_j = j;
            max_score = score;
        }
    }

    if (best_j != i) {
        std.mem.swap(Move, &move_list.items[i], &move_list.items[best_j]);
        std.mem.swap(i32, &score_list.items[i], &score_list.items[best_j]);
    }
    return move_list.items[i];
}

pub inline fn see(pos: *Position, move: Move, thr: i32) bool {
    if (move.is_promotion()) {
        return true;
    }

    var from = move.from;
    var to = move.to;

    var target = pos.board[to];
    var value: i32 = piece_val[target.type_of().toU3()] - thr;

    if (value < 0) {
        return false;
    }

    var attacker = pos.board[from];

    value -= piece_val[attacker.type_of().toU3()];

    if (value >= 0) {
        return true;
    }

    var occupied: u64 = (pos.all_pieces(Color.White) | pos.all_pieces(Color.Black)) ^ (@as(u64, 1) << from) ^ (@as(u64, 1) << to);
    var attackers: u64 = pos.all_attackers(to, occupied);

    var bishops: u64 = pos.diagonal_sliders(Color.White) | pos.diagonal_sliders(Color.Black);
    var rooks: u64 = pos.orthogonal_sliders(Color.White) | pos.orthogonal_sliders(Color.Black);

    var side = attacker.color().change_side();

    while (true) {
        attackers &= occupied;

        var occ_side = if (side == Color.White) pos.all_pieces(Color.White) else pos.all_pieces(Color.Black);
        var my_attackers: u64 = attackers & occ_side;

        if (my_attackers == 0) {
            break;
        }

        var pt: u3 = undefined;
        for (PieceType.Pawn.toU3()..(PieceType.King.toU3() + 1)) |pc| {
            pt = @as(u3, @intCast(pc));
            if ((my_attackers & (pos.bitboard_of_pc(Piece.make_piece(Color.White, PieceType.make(pt))) | pos.bitboard_of_pc(Piece.make_piece(Color.Black, PieceType.make(pt))))) != 0) {
                break;
            }
        }

        side = side.change_side();

        value = -value - 1 - piece_val[pt];

        if (value >= 0) {
            occ_side = if (side == Color.White) pos.all_pieces(Color.White) else pos.all_pieces(Color.Black);
            if ((PieceType.King.toU3() == pt) and ((attackers & occ_side) != 0)) {
                side = side.change_side();
            }
            break;
        }

        occupied ^= @as(u64, 1) << bb.get_ls1b_index(my_attackers & pos.piece_bb[Piece.make_piece(side.change_side(), PieceType.make(pt)).toU4()]);

        if (pt == PieceType.Pawn.toU3() or pt == PieceType.Bishop.toU3() or pt == PieceType.Queen.toU3()) {
            attackers |= (attacks.piece_attacks(to, occupied, PieceType.Bishop) & bishops);
        }
        if (pt == PieceType.Rook.toU3() or pt == PieceType.Queen.toU3()) {
            attackers |= (attacks.piece_attacks(to, occupied, PieceType.Rook) & rooks);
        }
    }

    return (side != attacker.color());
}
