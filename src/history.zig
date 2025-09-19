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

pub const max_histroy = 1300;
const history_divider = 8000;

pub const CORRHIST_SIZE = 16384;
const MAX_CORRHIST = 16384;
const CORRHIST_GRAIN = 256;
const CORRHIST_WEIGHT_SCALE = 1024; // 2^10

pub inline fn histoy_bonus(_entry: *i32, bonus: i32) void {
    _entry.* += bonus - @divTrunc(_entry.* * @as(i32, @intCast(@abs(bonus))), history_divider);
}

inline fn corr_update(_entry: *i32, err: i32, weight: i32) void {
    const interp = (_entry.* * (CORRHIST_WEIGHT_SCALE - weight) + err * weight) >> 10;
    const clamped = std.math.clamp(interp, -MAX_CORRHIST, MAX_CORRHIST);
    _entry.* = @as(i32, @intCast(clamped));
}

pub fn update_corr_history(search: *Search, pos: *Position, corr_eval: i32, score: i32, depth: i8) void {
    const err = (score - corr_eval) * CORRHIST_GRAIN;
    const depth_i32: i32 = @as(i32, @intCast(depth));
    const weight: i32 = @min(depth_i32 * depth_i32 + 2 * depth_i32 + 1, 128);

    corr_update(&search.pawn_corr[pos.pawn_hash % CORRHIST_SIZE][pos.side_to_play.toU4()], err, weight);
    corr_update(&search.non_pawn_corr[pos.non_pawn_hash[0] % CORRHIST_SIZE][pos.side_to_play.toU4()][0], err, weight);
    corr_update(&search.non_pawn_corr[pos.non_pawn_hash[1] % CORRHIST_SIZE][pos.side_to_play.toU4()][1], err, weight);
    corr_update(&search.major_corr[pos.major_hash % CORRHIST_SIZE][pos.side_to_play.toU4()], err, weight);
    corr_update(&search.minor_corr[pos.minor_hash % CORRHIST_SIZE][pos.side_to_play.toU4()], err, weight);
}

pub fn get_correction(search: *Search, pos: *Position) i32 {
    var corr_eval: i32 = 0;
    corr_eval += search.pawn_corr[pos.pawn_hash % CORRHIST_SIZE][pos.side_to_play.toU4()] * 2;
    corr_eval += search.non_pawn_corr[pos.non_pawn_hash[0] % CORRHIST_SIZE][pos.side_to_play.toU4()][0];
    corr_eval += search.non_pawn_corr[pos.non_pawn_hash[1] % CORRHIST_SIZE][pos.side_to_play.toU4()][1];
    corr_eval += search.major_corr[pos.major_hash % CORRHIST_SIZE][pos.side_to_play.toU4()] * 2;
    corr_eval += search.minor_corr[pos.minor_hash % CORRHIST_SIZE][pos.side_to_play.toU4()] * 2;

    corr_eval = corr_eval >> 9;
    return corr_eval;
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

    // if (search.ply >= 1 and !search.ns_stack[search.ply - 1].is_null) {
    //     const parent = search.ns_stack[search.ply - 1].move;
    //     const pc = search.ns_stack[search.ply - 1].piece.toU4();
    //     if (!parent.is_empty()) {
    //         search.mv_counter[pc][parent.to] = move;
    //     }
    // }

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
            histoy_bonus(&search.sc_hist_table[p_piece.toU4()][parent.to][pc.toU4()][to], -bonus);
        }

        if (!gparent.is_empty()) {
            histoy_bonus(&search.sc_hist_table[gp_piece.toU4()][gparent.to][pc.toU4()][to], -@divTrunc(bonus, 2));
        }
    }

    histoy_bonus(&search.sc_history[side][move.from][move.to], bonus);

    if (!parent.is_empty()) {
        histoy_bonus(&search.sc_hist_table[p_piece.toU4()][parent.to][piece.toU4()][move.to], bonus);
    }

    if (!gparent.is_empty()) {
        histoy_bonus(&search.sc_hist_table[gp_piece.toU4()][gparent.to][piece.toU4()][move.to], @divTrunc(bonus, 2));
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
