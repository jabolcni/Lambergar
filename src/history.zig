const std = @import("std");
const bb = @import("bitboard.zig");
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
const ContinuationEntry = *[position.NPIECES][64]i32;
pub const max_histroy = 1300;
const history_divider = 7000;

pub const CORRHIST_SIZE = 16384;
const MAX_CORRHIST = 16384;
const CORRHIST_GRAIN = 256;
const CORRHIST_WEIGHT_SCALE = 1024; // 2^10
const CONT_CORR_WEIGHT = 2;
const PAWN_CORR_WEIGHT = 4;
const NON_PAWN_CORR_WEIGHT = 6;
const MAJOR_CORR_WEIGHT = 4;
const MINOR_CORR_WEIGHT = 4;
const OPP_MOVE_CORR_WEIGHT = 2;
const CAPT_HISTORY_DIVIDER = 8192;
pub const MULTICUT_CORR_LIMIT = MAX_CORRHIST / 4;

pub const ContinuationSet = struct {
    cont1: ?ContinuationEntry = null,
    cont2: ?ContinuationEntry = null,
    cont4: ?ContinuationEntry = null,
    cont6: ?ContinuationEntry = null,
};

pub const QuietHistoryScores = struct {
    sc_hist: i32,
    cm_hist: i32,
    lmr_hist: i32,
    full_hist: i32,
};

const CorrIndexes = struct {
    side: usize,
    pawn: usize,
    white_non_pawn: usize,
    black_non_pawn: usize,
    major: usize,
    minor: usize,
};

pub fn histoy_bonus(_entry: *i32, bonus: i32) void {
    _entry.* += bonus - @divTrunc(_entry.* * @as(i32, @intCast(@abs(bonus))), history_divider);
}

inline fn move_threat_flags(opp_threats: u64, move: Move) struct { threat_from: usize, threat_to: usize } {
    return .{
        .threat_from = @intFromBool((opp_threats & bb.SQUARE_BB[move.from]) != 0),
        .threat_to = @intFromBool((opp_threats & bb.SQUARE_BB[move.to]) != 0),
    };
}

fn get_previous_countermove(search: *Search) ?struct { piece: u4, to: u6 } {
    if (search.ply == 0) return null;

    const prev_state = search.ns_stack[search.ply - 1];
    if (prev_state.is_null or prev_state.move.is_empty()) return null;

    return .{ .piece = prev_state.piece.toU4(), .to = prev_state.move.to };
}

fn previous_move_corr_index(search: *Search) ?struct { from: usize, to: usize } {
    if (search.ply == 0) return null;

    const prev_state = search.ns_stack[search.ply - 1];
    if (prev_state.is_null or prev_state.move.is_empty()) return null;

    return .{
        .from = @as(usize, @intCast(prev_state.move.from)),
        .to = @as(usize, @intCast(prev_state.move.to)),
    };
}

fn corr_update(_entry: *i16, err: i32, weight: i32) void {
    const curr: i32 = _entry.*;
    const interp: i32 = (curr * (CORRHIST_WEIGHT_SCALE - weight) + err * weight) >> 10;
    const clamped: i32 = std.math.clamp(interp, -MAX_CORRHIST, MAX_CORRHIST);
    _entry.* = @as(i16, @intCast(clamped));
}

inline fn corr_bonus_update(entry: *i16, bonus: i32) void {
    const curr: i32 = entry.*;
    entry.* = @as(i16, @intCast(std.math.clamp(curr + bonus, -MAX_CORRHIST, MAX_CORRHIST)));
}

inline fn capture_history_update(entry: *i16, bonus: i32) void {
    const curr: i32 = entry.*;
    const updated = curr + bonus - @divTrunc(curr * @as(i32, @intCast(@abs(bonus))), CAPT_HISTORY_DIVIDER);
    entry.* = @as(i16, @intCast(std.math.clamp(updated, -MAX_CORRHIST, MAX_CORRHIST)));
}

inline fn capture_history_index(pos: *Position, opp_threats: u64, move: Move) ?struct {
    piece_type: usize,
    threat_from: usize,
    threat_to: usize,
    move_to: usize,
    captured_type: usize,
} {
    if (!move.is_capture()) return null;

    const piece_type = pos.board[move.from].type_of().toU3();
    const threat_flags = move_threat_flags(opp_threats, move);
    var captured_type: usize = if (move.flags == position.MoveFlags.EN_PASSANT)
        position.PieceType.Pawn.toU3()
    else
        pos.board[move.to].type_of().toU3();

    if (captured_type == position.PieceType.NoType.toU3()) {
        captured_type = position.PieceType.Pawn.toU3();
    }

    return .{
        .piece_type = piece_type,
        .threat_from = threat_flags.threat_from,
        .threat_to = threat_flags.threat_to,
        .move_to = move.to,
        .captured_type = captured_type,
    };
}

pub inline fn capture_history_score(search: *Search, pos: *Position, move: Move) i32 {
    const opp_threats = pos.attacked_squares(pos.side_to_play.change_side());
    if (capture_history_index(pos, opp_threats, move)) |idx| {
        return search.capt_history[idx.piece_type][idx.threat_from][idx.threat_to][idx.move_to][idx.captured_type];
    }
    return 0;
}

pub inline fn capture_history_score_with_threats(search: *Search, pos: *Position, opp_threats: u64, move: Move) i32 {
    if (capture_history_index(pos, opp_threats, move)) |idx| {
        return search.capt_history[idx.piece_type][idx.threat_from][idx.threat_to][idx.move_to][idx.captured_type];
    }
    return 0;
}

pub fn update_capture_history(search: *Search, pos: *Position, opp_threats: u64, best_move: Move, noisy_moves: MoveList, depth: i8) void {
    const depth_i32: i32 = @as(i32, @intCast(depth));
    const bonus = @min(16 * depth_i32 * depth_i32 + 32 * depth_i32 + 16, max_histroy);

    if (best_move.is_capture()) {
        if (capture_history_index(pos, opp_threats, best_move)) |idx| {
            capture_history_update(&search.capt_history[idx.piece_type][idx.threat_from][idx.threat_to][idx.move_to][idx.captured_type], bonus);
        }
    }

    for (0..noisy_moves.count) |i| {
        const move = noisy_moves.moves[i];
        if (move.equal(best_move)) continue;
        if (capture_history_index(pos, opp_threats, move)) |idx| {
            capture_history_update(&search.capt_history[idx.piece_type][idx.threat_from][idx.threat_to][idx.move_to][idx.captured_type], -bonus);
        }
    }
}

inline fn continuation_entry_score(entry: ?ContinuationEntry, piece_u4: u4, move_to: u6) i32 {
    if (entry) |cont_entry| {
        return cont_entry[piece_u4][move_to];
    }
    return 0;
}

inline fn update_continuation_entry(entry: ?ContinuationEntry, piece: Piece, move_to: u6, bonus: i32) void {
    if (entry) |cont_entry| {
        histoy_bonus(&cont_entry[piece.toU4()][move_to], bonus);
    }
}

inline fn update_continuation_offset(search: *Search, move: Move, piece: Piece, bonus: i32, comptime offset: usize) void {
    if (search.ply < offset) return;
    update_continuation_entry(search.continuation_entry(offset), piece, move.to, bonus);
}

inline fn get_corr_indexes(pos: *Position) CorrIndexes {
    const mask: u64 = CORRHIST_SIZE - 1;
    return .{
        .side = pos.side_to_play.toU4(),
        .pawn = @as(usize, @intCast(pos.pawn_hash & mask)),
        .white_non_pawn = @as(usize, @intCast(pos.non_pawn_hash[0] & mask)),
        .black_non_pawn = @as(usize, @intCast(pos.non_pawn_hash[1] & mask)),
        .major = @as(usize, @intCast(pos.major_hash & mask)),
        .minor = @as(usize, @intCast(pos.minor_hash & mask)),
    };
}

pub inline fn make_ordering_continuations(search: *Search) ContinuationSet {
    return .{
        .cont1 = search.continuation_entry(1),
        .cont2 = search.continuation_entry(2),
        .cont4 = search.continuation_entry(4),
    };
}

pub inline fn make_search_continuations(search: *Search) ContinuationSet {
    return .{
        .cont1 = search.continuation_entry(1),
        .cont2 = search.continuation_entry(2),
        .cont4 = search.continuation_entry(4),
    };
}

pub inline fn quiet_order_score(search: *Search, opp_threats: u64, color: u4, continuations: ContinuationSet, piece: Piece, move: Move) i32 {
    const piece_u4 = piece.toU4();
    const threat_flags = move_threat_flags(opp_threats, move);
    const threat_tiebreak: i32 = if (threat_flags.threat_from == 1 and threat_flags.threat_to == 0)
        16
    else if (threat_flags.threat_from == 0 and threat_flags.threat_to == 1)
        -16
    else
        0;
    return search.get_sh(color, threat_flags.threat_from, threat_flags.threat_to, move.from, move.to) +
        continuation_entry_score(continuations.cont1, piece_u4, move.to) +
        continuation_entry_score(continuations.cont2, piece_u4, move.to) +
        @divTrunc(continuation_entry_score(continuations.cont4, piece_u4, move.to), 2) +
        threat_tiebreak;
}

pub inline fn quiet_search_scores(search: *Search, opp_threats: u64, color: u4, continuations: ContinuationSet, piece: Piece, move: Move) QuietHistoryScores {
    const piece_u4 = piece.toU4();
    const threat_flags = move_threat_flags(opp_threats, move);
    const sc_hist = search.get_sh(color, threat_flags.threat_from, threat_flags.threat_to, move.from, move.to);
    const cont1 = continuation_entry_score(continuations.cont1, piece_u4, move.to);
    const cont2 = continuation_entry_score(continuations.cont2, piece_u4, move.to);
    const cont4 = continuation_entry_score(continuations.cont4, piece_u4, move.to);
    const cm_hist = cont1 + cont2;
    const lmr_hist = cm_hist + cont4;
    return .{
        .sc_hist = sc_hist,
        .cm_hist = cm_hist,
        .lmr_hist = lmr_hist,
        .full_hist = sc_hist + lmr_hist,
    };
}

pub inline fn update_quiet_continuation_history(search: *Search, move: Move, piece: Piece, bonus: i32) void {
    // RT-19 result: reducing the more distant cont4/cont6 updates looked a bit
    // worse than baseline, so long-range continuation learning does not seem
    // overweighted in the current engine.
    //
    // RT-20 result: making the more distant cont4/cont6 updates slightly stronger
    // also looked worse than baseline, so simple symmetric retuning of both
    // distant continuations does not look promising.
    //
    // RT-21 result: reducing only the furthest cont6 update also looked worse than
    // baseline, so the most distant continuation leg does not appear overweighted.
    //
    // RT-22 result: increasing only the furthest cont6 update produced mixed
    // results and no clear gain, so baseline is kept here while we move on to a
    // different subsystem.
    const cont4_bonus = @divTrunc(bonus, 2);
    const cont6_bonus = @divTrunc(bonus, 2);
    update_continuation_entry(search.continuation_entry(1), piece, move.to, bonus);
    update_continuation_entry(search.continuation_entry(2), piece, move.to, bonus);
    update_continuation_entry(search.continuation_entry(4), piece, move.to, cont4_bonus);
    update_continuation_entry(search.continuation_entry(6), piece, move.to, cont6_bonus);
}

inline fn continuation_corr_indexes(search: *Search) ?struct { prev1: usize, prev2: usize } {
    if (search.ply < 2) return null;

    const prev1 = search.ns_stack[search.ply - 1];
    const prev2 = search.ns_stack[search.ply - 2];
    if (prev1.is_null or prev2.is_null) return null;
    if (prev1.move.is_empty() or prev2.move.is_empty()) return null;
    if (prev1.piece == Piece.NO_PIECE or prev2.piece == Piece.NO_PIECE) return null;

    return .{
        .prev1 = prev1.piece.type_of().toU3(),
        .prev2 = prev2.piece.type_of().toU3(),
    };
}

pub fn update_corr_history(search: *Search, pos: *Position, corr_eval: i32, score: i32, depth: i8) void {
    //const err = (score - corr_eval) * CORRHIST_GRAIN;
    var err = score - corr_eval;
    err = std.math.clamp(err, -400, 400); // 400 ≈ 4 pawns worth of error
    err *= CORRHIST_GRAIN;
    const depth_i32: i32 = @as(i32, @intCast(depth));
    // RT-7 result: lowering the maximum correction-history interpolation weight
    // from 128 to 112 scored about -20.12 +/- 12.15 Elo, so weaker correction
    // learning looks worse than baseline.
    //
    // RT-8 result: raising the maximum interpolation weight from 128 to 144 also
    // looked worse, so the baseline correction-history update strength may already
    // be near a local optimum.
    const weight: i32 = @min(depth_i32 * depth_i32 + 2 * depth_i32 + 1, 128);

    const idx = get_corr_indexes(pos);

    corr_update(&search.pawn_corr[idx.pawn][idx.side], err, weight);
    corr_update(&search.white_non_pawn_corr[idx.white_non_pawn][idx.side], err, weight);
    corr_update(&search.black_non_pawn_corr[idx.black_non_pawn][idx.side], err, weight);
    corr_update(&search.major_corr[idx.major][idx.side], err, weight);
    corr_update(&search.minor_corr[idx.minor][idx.side], err, weight);
    if (continuation_corr_indexes(search)) |cont_idx| {
        corr_update(&search.cont_corr[idx.side][cont_idx.prev1][cont_idx.prev2], err, weight);
    }
    if (previous_move_corr_index(search)) |prev_idx| {
        corr_update(&search.opp_move_corr[idx.side][prev_idx.from][prev_idx.to], err, weight);
    }
}

pub fn update_multicut_corr(search: *Search, pos: *Position, bonus: i32) void {
    const idx = get_corr_indexes(pos);

    corr_bonus_update(&search.pawn_corr[idx.pawn][idx.side], bonus);
    corr_bonus_update(&search.white_non_pawn_corr[idx.white_non_pawn][idx.side], bonus);
    corr_bonus_update(&search.black_non_pawn_corr[idx.black_non_pawn][idx.side], bonus);
    corr_bonus_update(&search.major_corr[idx.major][idx.side], bonus);
    corr_bonus_update(&search.minor_corr[idx.minor][idx.side], bonus);
    if (continuation_corr_indexes(search)) |cont_idx| {
        corr_bonus_update(&search.cont_corr[idx.side][cont_idx.prev1][cont_idx.prev2], bonus);
    }
    if (previous_move_corr_index(search)) |prev_idx| {
        corr_bonus_update(&search.opp_move_corr[idx.side][prev_idx.from][prev_idx.to], bonus);
    }
}

pub fn get_correction(search: *Search, pos: *Position) i32 {
    var corr_eval: i32 = 0;
    const idx = get_corr_indexes(pos);

    corr_eval += @as(i32, search.pawn_corr[idx.pawn][idx.side]) * PAWN_CORR_WEIGHT;
    corr_eval += @as(i32, search.white_non_pawn_corr[idx.white_non_pawn][idx.side]) * NON_PAWN_CORR_WEIGHT;
    corr_eval += @as(i32, search.black_non_pawn_corr[idx.black_non_pawn][idx.side]) * NON_PAWN_CORR_WEIGHT;
    corr_eval += @as(i32, search.major_corr[idx.major][idx.side]) * MAJOR_CORR_WEIGHT;
    corr_eval += @as(i32, search.minor_corr[idx.minor][idx.side]) * MINOR_CORR_WEIGHT;
    if (continuation_corr_indexes(search)) |cont_idx| {
        corr_eval += @as(i32, search.cont_corr[idx.side][cont_idx.prev1][cont_idx.prev2]) * CONT_CORR_WEIGHT;
    }
    if (previous_move_corr_index(search)) |prev_idx| {
        corr_eval += @as(i32, search.opp_move_corr[idx.side][prev_idx.from][prev_idx.to]) * OPP_MOVE_CORR_WEIGHT;
    }

    corr_eval = @divTrunc(corr_eval, 1024);
    return corr_eval;
}

pub fn update_all_history(search: *Search, opp_threats: u64, move: Move, quet_moves: MoveList, quet_mv_pieces: PieceList, depth: i8, comptime color: Color) void {
    //std.debug.assert(search.ply < searcher.MAX_PLY);

    const side: u4 = if (color == Color.White) Color.White.toU4() else Color.Black.toU4();

    const depth_i32: i32 = @as(i32, @intCast(depth));
    const bonus: i32 = @min(16 * depth_i32 * depth_i32 + 32 * depth_i32 + 16, max_histroy);
    const malus: i32 = bonus;

    if (!move.equal(search.mv_killer[search.ply][0])) {
        const tmp0 = search.mv_killer[search.ply][0];
        search.mv_killer[search.ply][0] = move;
        search.mv_killer[search.ply][1] = tmp0;
    }

    if (get_previous_countermove(search)) |prev| {
        search.mv_counter[prev.piece][prev.to] = move;
    }

    if (depth < 1) {
        return;
    }

    if (quet_moves.count == 0) {
        return;
    }

    const s = quet_moves.count;
    const piece = quet_mv_pieces.pieces[s - 1];

    // HUP-CORE-1 result: disabling both quiet-history and continuation-history
    // updates lost about 331.05 +/- 30.47 Elo in a 2+0.02 test, so the core
    // history-learning component itself is enormously important in this engine.
    // HUP-CONT-1 result: disabling only continuation-history updates lost about
    // 45.89 +/- 10.30 Elo, so continuation history is clearly valuable.
    // HUP-MAIN-1 result: disabling only the main quiet-history table updates lost
    // about 26.38 +/- 5.76 Elo, so the main quiet-history table is also a real
    // contributor, though smaller than continuation history in this split.
    for (0..(quet_moves.count - 1)) |i| {
        const mv = quet_moves.moves[i];
        const pc = quet_mv_pieces.pieces[i];
        const threat_flags = move_threat_flags(opp_threats, mv);

        // RT-1 result: strengthening only the main quiet-history table updates by
        // 25% scored about -10.97 +/- 9.45 Elo, so the current engine does not
        // appear to want a blanket upward rescale there.
        //
        // RT-2 result: reducing continuation-history update strength by 25%
        // scored about -1.78 +/- 4.71 Elo, so that change looked close to neutral.
        //
        // RT-3 result: increasing continuation-history update strength by 25%
        // scored about -2.00 +/- 4.70 Elo, also close to neutral, so baseline is kept.
        //
        // RT-17 result: making the losing quiet malus smaller looked near-neutral
        // to somewhat worse, so history learning does not appear to want a softer
        // penalty in this simple form.
        //
        // RT-18 result: making the losing quiet malus larger also looked close to
        // neutral, so that asymmetry does not show a clear gain either.
        histoy_bonus(&search.sc_history[side][threat_flags.threat_from][threat_flags.threat_to][mv.from][mv.to], -malus);
        update_quiet_continuation_history(search, mv, pc, -malus);
    }

    const best_threat_flags = move_threat_flags(opp_threats, move);
    histoy_bonus(&search.sc_history[side][best_threat_flags.threat_from][best_threat_flags.threat_to][move.from][move.to], bonus);
    update_quiet_continuation_history(search, move, piece, bonus);
}

pub fn get_counter_move(search: *Search) Move {
    if (search.ply >= 1 and !search.ns_stack[search.ply - 1].is_null) {
        const parent = search.ns_stack[search.ply - 1].move;
        const pc = search.ns_stack[search.ply - 1].piece.toU4();
        if (!parent.is_empty()) {
            return search.mv_counter[pc][parent.to];
        }
    }

    return Move.empty();
}
