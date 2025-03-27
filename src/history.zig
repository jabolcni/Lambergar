const std = @import("std");
const searcher = @import("search.zig");
const position = @import("position.zig");
const lists = @import("lists.zig");

const Search = searcher.Search;
const Move = position.Move;
const Color = position.Color;
const Piece = position.Piece;
const PieceType = position.PieceType;
const Position = position.Position;

const MoveList = lists.MoveList;
const PieceList = lists.PieceList;

pub const max_histroy = 1300; //2600;
//const histry_multiplier = 32;
const history_divider = 8000; //16384;

pub inline fn histoy_bonus(_entry: *i32, bonus: i32) void {
    _entry.* += bonus - @divTrunc(_entry.* * @as(i32, @intCast(@abs(bonus))), history_divider);
}

pub fn update_all_history(search: *Search, move: Move, quet_moves: MoveList, quet_mv_pieces: PieceList, depth: i8, comptime color: Color) void {
    std.debug.assert(search.ply < searcher.MAX_PLY);

    const side: u4 = if (color == Color.White) Color.White.toU4() else Color.Black.toU4();

    const depth_i32: i32 = @as(i32, @intCast(depth));
    const bonus: i32 = @min(16 * depth_i32 * depth_i32 + 32 * depth_i32 + 16, max_histroy);

    if (!move.equal(search.mv_killer[search.ply][0])) {
        const tmp0 = search.mv_killer[search.ply][0];
        search.mv_killer[search.ply][0] = move;
        search.mv_killer[search.ply][1] = tmp0;
    }

    if (search.ply >= 1 and !search.ns_stack[search.ply - 1].is_null) {
        const parent = search.ns_stack[search.ply - 1].move;
        const pc = search.ns_stack[search.ply - 1].piece.toU4();
        if (!parent.is_empty()) {
            search.mv_counter[pc][parent.to] = move;
        }
    }

    if (depth <= 1) {
        return;
    }

    if (quet_moves.count == 0) {
        return;
    }

    const s = quet_moves.count;
    const piece = quet_mv_pieces.pieces[s - 1];

    var parent: Move = Move.empty();
    var p_piece: Piece = Piece.NO_PIECE;
    if (search.ply >= 1) {
        parent = search.ns_stack[search.ply - 1].move;
        p_piece = search.ns_stack[search.ply - 1].piece;
    }

    var gparent: Move = Move.empty();
    var gp_piece: Piece = Piece.NO_PIECE;
    if (search.ply >= 2) {
        gparent = search.ns_stack[search.ply - 2].move;
        gp_piece = search.ns_stack[search.ply - 2].piece;
    }

    for (0..(quet_moves.count - 1)) |i| {
        const mv = quet_moves.moves[i];
        const from = mv.from;
        const to = mv.to;
        const pc = quet_mv_pieces.pieces[i];

        histoy_bonus(&search.sc_history[side][from][to], -bonus);

        if (!parent.is_empty()) {
            histoy_bonus(&search.sc_counter_table[p_piece.toU4()][parent.to][pc.toU4()][to], -bonus);
        }

        if (!gparent.is_empty()) {
            histoy_bonus(&search.sc_follow_table[gp_piece.toU4()][gparent.to][pc.toU4()][to], -bonus);
        }
    }

    histoy_bonus(&search.sc_history[side][move.from][move.to], bonus);

    if (!parent.is_empty()) {
        histoy_bonus(&search.sc_counter_table[p_piece.toU4()][parent.to][piece.toU4()][move.to], bonus);
    }

    if (!gparent.is_empty()) {
        histoy_bonus(&search.sc_follow_table[gp_piece.toU4()][gparent.to][piece.toU4()][move.to], bonus);
    }
}

pub inline fn get_counter_move(search: *Search) Move {
    if (search.ply >= 1 and !search.ns_stack[search.ply - 1].is_null) {
        const parent = search.ns_stack[search.ply - 1].move;
        const pc = search.ns_stack[search.ply - 1].piece.toU4();
        if (!parent.is_empty()) {
            return search.mv_counter[pc][parent.to];
        }
    }

    return Move.empty();
}
