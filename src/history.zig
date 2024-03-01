const std = @import("std");
const searcher = @import("search.zig");
const position = @import("position.zig");

const Search = searcher.Search;
const Move = position.Move;
const Color = position.Color;
const Piece = position.Piece;
const PieceType = position.PieceType;
const Position = position.Position;

pub const max_histroy = 400;
const histry_multiplier = 32;
//const history_divider = 512;
const history_divider = 1200;

pub inline fn histoy_bonus(_entry: i32, bonus: i32) i32 {
    return _entry + histry_multiplier * bonus - @as(i32, @intCast(@divTrunc(@abs(_entry * bonus), history_divider)));
    //return _entry + histry_multiplier * bonus - _entry * @as(i32, @intCast(@divTrunc(@abs(bonus), history_divider)));
}

pub fn update_all_history(search: *Search, move: Move, quet_moves: std.ArrayList(Move), quet_mv_pieces: std.ArrayList(Piece), depth: i8, comptime color: Color) void {
    std.debug.assert(search.ply < searcher.MAX_PLY);

    comptime var side = if (color == Color.White) Color.White.toU4() else Color.Black.toU4();

    const depth_i32: i32 = @as(i32, @intCast(depth));
    const bonus: i32 = @min(depth_i32 * depth_i32, max_histroy);

    if (!move.equal(search.mv_killer[search.ply][0])) {
        var tmp0 = search.mv_killer[search.ply][0];
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

    if (quet_moves.items.len == 0) {
        return;
    }

    const s = quet_moves.items.len;
    const piece = quet_mv_pieces.items[s - 1];

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

    for (0..quet_moves.items.len - 1) |i| {
        const mv = quet_moves.items[i];
        const from = mv.from;
        const to = mv.to;
        const pc = quet_mv_pieces.items[i];

        search.sc_history[side][from][to] = histoy_bonus(search.sc_history[side][from][to], -bonus);

        if (!parent.is_empty()) {
            search.sc_counter_table[p_piece.toU4()][parent.to][pc.toU4()][to] = histoy_bonus(search.sc_counter_table[p_piece.toU4()][parent.to][pc.toU4()][to], -bonus);
        }

        if (!gparent.is_empty()) {
            search.sc_follow_table[gp_piece.toU4()][gparent.to][pc.toU4()][to] = histoy_bonus(search.sc_follow_table[gp_piece.toU4()][gparent.to][pc.toU4()][to], -bonus);
        }
    }

    search.sc_history[side][move.from][move.to] = histoy_bonus(search.sc_history[side][move.from][move.to], bonus);

    if (!parent.is_empty()) {
        search.sc_counter_table[p_piece.toU4()][parent.to][piece.toU4()][move.to] = histoy_bonus(search.sc_counter_table[p_piece.toU4()][parent.to][piece.toU4()][move.to], bonus);
    }

    if (!gparent.is_empty()) {
        search.sc_follow_table[gp_piece.toU4()][gparent.to][piece.toU4()][move.to] = histoy_bonus(search.sc_follow_table[gp_piece.toU4()][gparent.to][piece.toU4()][move.to], bonus);
    }
}

pub inline fn get_counter_move(search: *Search) Move { //, comptime color: Color) Move {
    if (search.ply >= 1 and !search.ns_stack[search.ply - 1].is_null) {
        const parent = search.ns_stack[search.ply - 1].move;
        const pc = search.ns_stack[search.ply - 1].piece.toU4();
        if (!parent.is_empty()) {
            return search.mv_counter[pc][parent.to];
        }
    }

    return Move.empty();
}
