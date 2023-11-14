const std = @import("std");
const position = @import("position.zig");
const searcher = @import("search.zig");

const Move = position.Move;
const Position = position.Position;
const Piece = position.Piece;
const PieceType = position.PieceType;
const Color = position.Color;
const Search = searcher.Search;

pub const SortHash = 7000000;
pub const SortCapture = 6000000;
pub const SortKiller1 = 5000000;
pub const SortKiller2 = 4000000;

// pawns, knights, bishops, rooks, queens, kings
const piece_val = [7]i32{ 100, 310, 330, 500, 1000, 20000, 0 };

pub inline fn score_move(pos: *Position, search: *Search, move_list: *std.ArrayList(Move), score_list: *std.ArrayList(i32), hash_move: Move, comptime color: Color) void {
    for (move_list.items) |move| {
        var score: i32 = 0;
        if (move.equal(hash_move)) {
            score = SortHash;
        } else if (move.is_tactical()) {
            score = 10 * (piece_val[pos.board[move.to].type_of().toU3()] + piece_val[move.flags.promote_type().toU3()]) - piece_val[pos.board[move.from].type_of().toU3()] + SortCapture;
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
