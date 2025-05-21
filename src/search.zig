const std = @import("std");
const position = @import("position.zig");
const ms = @import("movescorer.zig");
const tt = @import("tt.zig");
const history = @import("history.zig");
const evaluation = @import("evaluation.zig");
const nnue = @import("nnue.zig");
const lists = @import("lists.zig");
const uci = @import("uci.zig");

const Instant = std.time.Instant;

const Position = position.Position;
const Piece = position.Piece;
const PieceType = position.PieceType;
const Color = position.Color;
const Move = position.Move;
const MoveFlags = position.MoveFlags;

const MoveList = lists.MoveList;
const ScoreList = lists.ScoreList;
const PieceList = lists.PieceList;
const PieceTypeList = lists.PieceTypeList;

pub const MAX_DEPTH = 100;
pub const MAX_PLY = 128;
pub const MAX_MOVES = 256;
pub const MAX_MATE_PLY = 50;
pub const MAX_SCORE = 50_000;
pub const MATE_VALUE = 49_000;
pub const MATED_IN_MAX = MAX_PLY - MATE_VALUE;

const null_move_depth = 2;

const histroy_depth = [_]i32{ 3, 2 };
const history_limit = [_]i32{ -1000, -2000 };
const cm_history_limit = [_]i32{ 0, -1000 };
const fm_history_limit = [_]i32{ -1000, -2000 }; //{ -2000, -4000 };
const futility_histroy_limit = [_]i32{ -500, -1000 };
const lmp_depth = 8;

// var lmp = [2][11]i8{
//     [_]i8{ 0, 2, 3, 5, 9, 13, 18, 25, 34, 45, 55 },
//     [_]i8{ 0, 5, 6, 9, 14, 21, 30, 41, 55, 69, 84 },
// };

// Testiraj še z daljšimi tc
var lmp = [2][11]i8{
    [_]i8{ 0, 2, 3, 4, 6, 8, 10, 13, 17, 22, 30 },
    [_]i8{ 0, 4, 5, 7, 10, 13, 17, 22, 29, 38, 50 },
};
var lmr: [MAX_DEPTH][MAX_MOVES]i8 = undefined;

inline fn depth_as_i32(depth: i8) i32 {
    return @as(i32, @intCast(depth));
}

pub inline fn _is_mate_score(score: i32) bool {
    return ((score <= -MATE_VALUE + MAX_MATE_PLY) or (score >= MATE_VALUE - MAX_MATE_PLY));
}

pub inline fn _mate_in(score: i32) i32 {
    return if (score > 0) @divFloor(MATE_VALUE - score + 1, 2) else @divFloor(-MATE_VALUE - score, 2);
}

pub inline fn init_lmr() void {
    lmr[0][0] = 1;
    lmr[0][1] = 1;
    lmr[1][0] = 1;

    for (1..MAX_DEPTH) |depth| {
        for (1..MAX_MOVES) |played| {
            lmr[depth][played] = @intFromFloat(1.0 + @log(@as(f32, @floatFromInt(depth))) * @log(@as(f32, @floatFromInt(played))) * 0.5);
        }
    }
}

pub fn start_main_search(search: *Search, pos: *Position) void {
    if (pos.side_to_play == Color.White) {
        search.iterative_deepening(pos, Color.White);
    } else {
        search.iterative_deepening(pos, Color.Black);
    }

    for (1..uci.num_threads) |i| {
        @atomicStore(bool, &uci.thinkers[i].stop, true, .seq_cst);
    }

    for (1..uci.num_threads) |i| {
        if (uci.threads[i]) |thread| {
            thread.join();
        }
    }
}

pub fn start_search(search: *Search, pos: *Position, _delta: i32) void {
    if (pos.side_to_play == Color.White) {
        search.iterative_deepening_thread(pos, _delta, Color.White);
    } else {
        search.iterative_deepening_thread(pos, _delta, Color.Black);
    }
}

pub const Termination = enum(u3) { INFINITE, DEPTH, NODES, TIME, MOVETIME };

pub const SearchManager = struct {
    termination: Termination = Termination.INFINITE,
    max_ms: u64 = 1000,
    early_ms: u64 = 1000,
    max_nodes: ?u32 = null,

    pub fn new() SearchManager {
        return SearchManager{
            .termination = Termination.INFINITE,
            .max_ms = 1000,
            .early_ms = 1000,
            .max_nodes = null,
        };
    }

    pub fn set_time_limits(self: *SearchManager, movestogo: ?u32, movetime: ?u64, _rem_time: ?u64, time_inc: ?u32) void {
        const overhead: u32 = 10;
        var rem_time = _rem_time;

        if (self.termination == Termination.INFINITE or self.termination == Termination.DEPTH or self.termination == Termination.NODES) {
            self.max_ms = 1 << 63;
            self.early_ms = self.max_ms;
        } else if (self.termination == Termination.TIME or self.termination == Termination.MOVETIME) {
            if (movetime != null) {
                self.max_ms = movetime.? - @as(u64, @intCast(overhead));
                self.early_ms = self.max_ms;
                return;
            } else if (rem_time != null) {
                const inc: u32 = if (time_inc != null) time_inc.? else 0;
                const mtg: u32 = if (movestogo != null) @min(movestogo.?, 50) else 50;
                if (inc > overhead) {
                    rem_time = rem_time.? + @as(u64, @intCast(mtg * (inc - overhead)));
                }
                if (rem_time.? <= overhead) {
                    self.max_ms = @max(2, overhead - 2);
                    self.early_ms = self.max_ms;
                    return;
                }
                if (movestogo == null) {
                    const scale_div: u64 = 50;
                    self.early_ms = @min(@divTrunc(rem_time.?, scale_div), @divTrunc(_rem_time.?, 5));
                    self.max_ms = @min(5 * self.early_ms, @divTrunc(4 * _rem_time.?, 5)); //inc + (rem_time.? - overhead) / 20;
                } else {
                    self.early_ms = @min(@divTrunc(7 * rem_time.?, 10 * mtg), @divTrunc(4 * _rem_time.?, 5));
                    self.max_ms = @min(5 * self.early_ms, @divTrunc(4 * _rem_time.?, 5)); //inc + (rem_time.? - overhead) / 20;
                }
                return;
            } else {
                self.max_ms = 1 << 63;
                self.early_ms = self.max_ms;
                return;
            }
        } else {
            unreachable;
        }
    }
};

pub const NodeState = struct {
    eval: i32 = undefined,
    is_null: bool = false,
    is_tactical: bool = false,
    move: Move = Move.empty(),
    piece: Piece = Piece.NO_PIECE,
};

pub const Search = struct {
    best_move: Move = undefined,
    stop_on_time: bool = false,
    stop: bool = false,
    timer: std.time.Timer = undefined,
    max_depth: u32 = MAX_DEPTH - 1,
    nodes: u64 = 0,
    ply: u16 = 0,
    seldepth: u16 = 0,

    pv_length: [MAX_PLY]u16 = undefined,
    pv_table: [MAX_PLY][MAX_PLY]Move = undefined,

    mv_killer: [MAX_PLY + 1][2]Move = undefined,
    excluded: [MAX_PLY + 1]Move = undefined,
    dextension: [MAX_PLY + 1]i8 = undefined,
    mv_counter: [position.NPIECES][64]Move = undefined,
    sc_history: [2][64][64]i32 = undefined,
    sc_counter_table: [position.NPIECES][64][position.NPIECES][64]i32 = undefined,
    sc_follow_table: [position.NPIECES][64][position.NPIECES][64]i32 = undefined,

    ns_stack: [MAX_PLY + 4]NodeState = undefined,

    manager: SearchManager = undefined,

    non_terminal_nodes: u64 = 0, // Nodes with legal moves

    pub fn new() Search {
        return Search{};
    }

    inline fn clear_pv_table(self: *Search) void {
        for (0..MAX_PLY) |i| {
            for (0..MAX_PLY) |j| {
                self.pv_table[i][j] = Move.empty();
            }
            self.pv_length[i] = 0;
        }
    }

    inline fn clear_mv_killer(self: *Search) void {
        for (0..(MAX_PLY + 1)) |i| {
            self.mv_killer[i][0] = Move.empty();
            self.mv_killer[i][1] = Move.empty();
        }
    }

    inline fn clear_mv_counter(self: *Search) void {
        for (0..position.NPIECES) |pc| {
            for (0..64) |sq| {
                self.mv_counter[pc][sq] = Move.empty();
            }
        }
    }

    inline fn clear_sc_history(self: *Search) void {
        for (0..2) |pc| {
            for (0..64) |sq1| {
                for (0..64) |sq2| {
                    self.sc_history[pc][sq1][sq2] = 0;
                }
            }
        }
    }

    inline fn age_sc_history(self: *Search) void {
        for (0..2) |pc| {
            for (0..64) |sq1| {
                for (0..64) |sq2| {
                    self.sc_history[pc][sq1][sq2] = @divTrunc(self.sc_history[pc][sq1][sq2], 2);
                }
            }
        }
    }

    inline fn clear_sc_follow_table(self: *Search) void {
        for (0..position.NPIECES) |i| {
            for (0..64) |j| {
                for (0..position.NPIECES) |k| {
                    for (0..64) |l| {
                        self.sc_follow_table[i][j][k][l] = 0;
                        self.sc_counter_table[i][j][k][l] = 0;
                    }
                }
            }
        }
    }

    inline fn clear_node_state_stack(self: *Search) void {
        for (0..(MAX_PLY + 4)) |i| {
            self.ns_stack[i].eval = 0;
            self.ns_stack[i].is_null = false;
            self.ns_stack[i].is_tactical = false;
            self.ns_stack[i].move = Move.empty();
            self.ns_stack[i].piece = Piece.NO_PIECE;
        }
    }

    pub inline fn get_sh(self: *Search, color: u4, move_from: u6, move_to: u6) i32 {
        return (&self.sc_history)[color][move_from][move_to];
    }

    pub inline fn get_ch(self: *Search, p_piece: u4, parent_to: u6, piece: u4, move_to: u6) i32 {
        return (&self.sc_counter_table)[p_piece][parent_to][piece][move_to];
    }

    pub inline fn get_fh(self: *Search, gp_piece: u4, gparent_to: u6, piece: u4, move_to: u6) i32 {
        return (&self.sc_follow_table)[gp_piece][gparent_to][piece][move_to];
    }

    pub fn clear_for_new_game(self: *Search) void {
        self.clear_pv_table();
        self.clear_mv_killer();
        self.clear_mv_counter();
        self.clear_sc_history();
        self.clear_node_state_stack();
        self.clear_sc_follow_table();

        self.best_move = Move.empty();
        self.stop_on_time = false;
        self.stop = false;

        self.nodes = 0;
        self.non_terminal_nodes = 0;
        self.ply = 0;
        self.max_depth = MAX_DEPTH - 1;
        self.seldepth = 0;
    }

    pub fn clear_for_new_search(self: *Search) void {
        self.clear_pv_table();
        self.clear_mv_killer();
        self.clear_mv_counter();
        self.clear_sc_history();
        self.clear_node_state_stack();
        //self.clear_sc_follow_table();

        self.best_move = Move.empty();
        self.stop_on_time = false;
        self.stop = false;

        self.nodes = 0;
        self.non_terminal_nodes = 0;
        self.ply = 0;
    }

    pub inline fn check_stop_conditions(self: *Search) bool {
        if (self.stop) return true;

        if (self.manager.termination == Termination.INFINITE) {
            return false;
        }

        if (self.manager.termination == Termination.NODES and self.nodes >= self.manager.max_nodes.?) {
            self.stop = true;
            return true;
        }

        if (self.nodes & 1024 == 0 and ((self.timer.read() / std.time.ns_per_ms) >= self.manager.max_ms)) {
            self.stop = true;
            self.stop_on_time = true;
            return true;
        }

        return false;
    }

    pub inline fn check_early_stop_conditions(self: *Search, pos: *Position, stability: u8, improving: i16) bool {
        if (self.stop) return true;

        var early_adjusted_ms = self.manager.early_ms;

        if (self.manager.termination == Termination.TIME) {
            var factor: f32 = 1.0 - 0.04 * @as(f32, @floatFromInt(stability)) - 0.08 * @as(f32, @floatFromInt(improving));
            factor = @max(0.5, @min(1.25, factor));

            // const phase = pos.eval.phase[0] + pos.eval.phase[1];
            // if (phase >= 58) {
            //     factor *= 0.8;
            // }
            var factor_ph: f32 = 1.0;
            const phase = @as(f32, @floatFromInt(pos.eval.phase[0] + pos.eval.phase[1]));
            const fac_min: f32 = 0.6;
            const ph_min: f32 = 52;
            const k: f32 = (fac_min - 1) / (64 - ph_min);
            const n = 1 - k * ph_min;
            factor_ph = k * phase + n;
            if (factor_ph < fac_min) factor_ph = fac_min;
            if (factor_ph > 1) factor_ph = 1;
            factor *= factor_ph;
            early_adjusted_ms = @as(u64, @intFromFloat(@as(f32, @floatFromInt(early_adjusted_ms)) * factor));
        }
        if ((self.timer.read() / std.time.ns_per_ms) >= early_adjusted_ms) {
            return true;
        }

        return false;
    }

    pub fn iterative_deepening(self: *Search, pos: *Position, comptime color: Color) void {
        const stdout = std.io.getStdOut().writer();
        const allocator = std.heap.c_allocator;

        self.clear_for_new_search();
        pos.history[pos.game_ply].accumulator = nnue.refresh_accumulator(pos.*);
        pos.history[pos.game_ply].accumulator.eval = nnue.evaluate(pos.history[pos.game_ply].accumulator, color);
        pos.history[pos.game_ply].accumulator.computed_score = true;

        var alpha: i32 = -MAX_SCORE;
        var beta: i32 = MAX_SCORE;
        var score: i32 = 0;
        var delta: i32 = 16;

        var it_depth: i8 = 1;
        var depth = it_depth;

        var stability_counter: u8 = 0;
        var improving: i16 = 0;
        var prev_best_move: Move = Move.empty();
        var prev_score = score;

        self.timer = std.time.Timer.start() catch unreachable;

        const start = Instant.now() catch unreachable;
        self.nodes = 0;
        self.non_terminal_nodes = 0;

        mainloop: while (it_depth <= self.max_depth) {
            self.ply = 0;
            self.seldepth = 0;
            //self.nodes = 0;
            depth = it_depth;

            const start_nodes = self.nodes;
            const start_non_terminal = self.non_terminal_nodes;

            if (depth >= 4) {
                delta = 5;
            } else {
                delta = MAX_SCORE;
            }

            alpha = @max(-MAX_SCORE, score - delta);
            beta = @min(score + delta, MAX_SCORE);

            //const start = Instant.now() catch unreachable;

            aspirationloop: while (delta <= MAX_SCORE) {
                score = self.pvs(depth, alpha, beta, pos, false, color);

                if (self.stop) {
                    break :mainloop;
                }

                self.best_move = self.pv_table[0][0];

                delta += 2 + @divTrunc(delta, 2);

                if (@abs(score) > 2000) {
                    delta = MAX_SCORE;
                }

                if (score <= alpha) {
                    beta = @divTrunc(alpha + beta, 2);
                    alpha = @max(-MAX_SCORE, score - delta);
                    //depth = it_depth;
                } else if (score >= beta) {
                    beta = @min(score + delta, MAX_SCORE);
                } else {
                    break :aspirationloop;
                }

                if (delta > 500) {
                    delta = MAX_SCORE;
                }
            }

            if (self.pv_table[0][0].equal(prev_best_move)) {
                stability_counter = @min(10, stability_counter + 1);
            } else {
                stability_counter = 0;
            }
            prev_best_move = self.pv_table[0][0];

            if (score > prev_score + 20) {
                improving += 1;
                if (score > prev_score + 60) improving += 1;
            } else if (score < prev_score - 20) {
                improving -= 1;
                if (score < prev_score - 60) improving -= 1;
            }

            prev_score = score;

            if (self.stop) {
                break :mainloop;
            }
            var nodes = self.nodes;
            for (1..uci.num_threads) |i| {
                nodes += uci.thinkers[i].nodes;
            }
            const now = Instant.now() catch unreachable;
            const time_elapsed = now.since(start);
            const elapsed_nanos = @as(f64, @floatFromInt(time_elapsed));
            const elapsed_seconds = elapsed_nanos / 1_000_000_000;
            const elapsed_ms: u32 = @intFromFloat(elapsed_nanos / 1_000_000);
            const nps: u46 = @intFromFloat(@as(f64, @floatFromInt(nodes)) / elapsed_seconds);

            const nodes_used = self.nodes - start_nodes;
            const non_terminal_used = self.non_terminal_nodes - start_non_terminal;

            const mbf: f32 = if (non_terminal_used > 0)
                @as(f32, @floatFromInt(nodes_used)) / @as(f32, @floatFromInt(non_terminal_used))
            else
                0.0;

            //self.best_move = self.pv_table[0][0];

            const est_hash_full = tt.TT.hash_full();

            _ = std.fmt.format(stdout, "info score ", .{}) catch unreachable;
            if (_is_mate_score(score)) {
                _ = std.fmt.format(stdout, "mate {} ", .{_mate_in(score)}) catch unreachable;
            } else {
                _ = std.fmt.format(stdout, "cp {} ", .{score}) catch unreachable;
            }
            _ = std.fmt.format(stdout, "depth {} seldepth {} nodes {} nps {d} time {d} hashfull {d} mbf {d:.2} pv ", .{ it_depth, self.seldepth, self.nodes, nps, elapsed_ms, est_hash_full, mbf }) catch unreachable;

            var next_ply: usize = 0;
            while (!self.pv_table[0][next_ply].is_empty() and next_ply < self.pv_length[0]) : (next_ply += 1) {
                var pv_move = self.pv_table[0][next_ply];
                const pv_move_str = pv_move.to_str(allocator);
                defer allocator.free(pv_move_str);
                _ = std.fmt.format(stdout, "{s} ", .{pv_move_str}) catch unreachable;
            }

            _ = std.fmt.format(stdout, "\n", .{}) catch unreachable;

            if (self.stop or self.check_early_stop_conditions(pos, stability_counter, improving)) {
                self.stop = true;
                break :mainloop;
            }

            it_depth += 1;
        }

        if (self.best_move.is_empty()) {
            var move_list: MoveList = .{};
            const me = if (color == Color.White) Color.White else Color.Black;
            pos.generate_legals(me, &move_list);
            var score_list: ScoreList = .{};
            ms.score_move(pos, self, &move_list, &score_list, Move.empty(), me);
            self.best_move = ms.get_next_best(&move_list, &score_list, 0);
        }

        const move_name = self.best_move.to_str(allocator);
        defer allocator.free(move_name);
        _ = std.fmt.format(stdout, "bestmove {s}\n", .{move_name}) catch unreachable;
    }

    pub fn iterative_deepening_thread(self: *Search, pos: *Position, _delta: i32, comptime color: Color) void {
        self.clear_for_new_search();
        pos.history[pos.game_ply].accumulator = nnue.refresh_accumulator(pos.*);
        pos.history[pos.game_ply].accumulator.eval = nnue.evaluate(pos.history[pos.game_ply].accumulator, color);
        pos.history[pos.game_ply].accumulator.computed_score = true;

        var alpha: i32 = -MAX_SCORE;
        var beta: i32 = MAX_SCORE;
        var score: i32 = 0;
        var delta: i32 = 16;

        var it_depth: i8 = 1;
        var depth = it_depth;

        self.nodes = 0;

        mainloop: while (it_depth <= self.max_depth) {
            self.ply = 0;
            self.seldepth = 0;
            depth = it_depth;

            if (depth >= 4) {
                delta = _delta;
            } else {
                delta = MAX_SCORE;
            }

            alpha = @max(-MAX_SCORE, score - delta);
            beta = @min(score + delta, MAX_SCORE);

            aspirationloop: while (delta <= MAX_SCORE) {
                score = self.pvs(depth, alpha, beta, pos, false, color);

                if (self.stop) {
                    break :mainloop;
                }

                self.best_move = self.pv_table[0][0];

                delta += 2 + @divTrunc(delta, 2);

                if (@abs(score) > 2000) {
                    delta = MAX_SCORE;
                }

                if (score <= alpha) {
                    beta = @divTrunc(alpha + beta, 2);
                    alpha = @max(-MAX_SCORE, score - delta);
                    //depth = it_depth;
                } else if (score >= beta) {
                    beta = @min(score + delta, MAX_SCORE);
                } else {
                    break :aspirationloop;
                }

                if (delta > 500) {
                    delta = MAX_SCORE;
                }
            }

            if (self.stop) {
                self.stop = true;
                break :mainloop;
            }

            it_depth += 1;
        }
    }

    pub fn pvs(self: *Search, _depth: i8, _alpha: i32, _beta: i32, pos: *Position, cutnode: bool, comptime color: Color) i32 {
        const opp = color.change_side();
        const me = color;

        var depth = _depth;
        const qsearch: bool = if (_depth <= 0) true else false;
        const is_root: bool = if (self.ply == 0) true else false;
        const in_check = pos.in_check(me);
        var full_search: bool = false;

        var alpha: i32 = _alpha;
        const beta: i32 = _beta;
        const is_pv: bool = if (alpha != beta - 1) true else false;
        var r_alpha: i32 = undefined;
        var r_beta: i32 = undefined;

        var best_score: i32 = undefined;
        var score: i32 = undefined;

        var extension: i8 = 0;
        const skip_move: bool = !self.excluded[self.ply].is_empty();
        var is_null: bool = false;
        if (self.ply >= 1 and self.ns_stack[self.ply - 1].is_null) {
            is_null = true;
        }

        if (qsearch) {
            if (in_check) {
                depth = 1;
            } else {
                return self.quiescence(alpha, beta, pos, depth, me);
            }
        }

        self.pv_length[self.ply] = 0;
        self.seldepth = @max(self.ply, self.seldepth);
        //self.nodes += 1;

        if (self.check_stop_conditions()) {
            self.stop_on_time = true;
            return 0;
        }

        if (!is_root) {
            if (pos.upcoming_repetition() and alpha < 0) {
                alpha = 1 - (@as(i32, @intCast(self.nodes & 2)));
                if (alpha >= beta) return alpha;
            }

            if (pos.is_draw()) return 1 - (@as(i32, @intCast(self.nodes & 2)));

            if (self.ply >= MAX_PLY) {
                if (in_check) return 0 else return pos.eval.eval(pos, me);
            }

            r_alpha = @max(alpha, -MATE_VALUE + @as(i32, self.ply));
            r_beta = @min(beta, MATE_VALUE - @as(i32, self.ply) + 1);

            if (r_alpha >= r_beta) return r_alpha;
        }

        var tt_move = Move.empty();
        var tt_score: i32 = -MATE_VALUE;
        var tt_bound = tt.Bound.BOUND_NONE;
        var tt_depth: i8 = 0;

        const entry = tt.TT.fetch(pos.hash);
        const tt_hit: bool = !skip_move and (entry != null);

        if (tt_hit) {
            tt_move = entry.?.move;
            tt_bound = entry.?.bound;
            tt_score = tt.TT.adjust_hash_score(entry.?.score, self.ply);
            tt_depth = entry.?.depth;

            if ((!is_pv or depth == 0) and tt_depth >= depth and (cutnode or tt_score <= alpha)) {
                if ((tt_bound == tt.Bound.BOUND_LOWER and tt_score >= beta) or
                    (tt_bound == tt.Bound.BOUND_UPPER and tt_score <= alpha) or
                    (tt_bound == tt.Bound.BOUND_EXACT))
                {
                    if (tt_score >= beta and tt_move.is_quiet()) {
                        const depth_i32: i32 = @as(i32, @intCast(tt_depth));
                        const bonus: i32 = @min(depth_i32 * depth_i32, history.max_histroy);
                        history.histoy_bonus(&self.sc_history[color.toU4()][tt_move.from][tt_move.to], bonus);
                    }

                    return tt_score;
                }
            }

            if (!is_pv and (tt_depth >= depth - 1) and (tt_bound == tt.Bound.BOUND_UPPER) and (tt_score + 140 <= alpha) and (cutnode or tt_score <= alpha)) {
                return alpha;
            }
        }

        if (depth >= 4 and tt_bound == tt.Bound.BOUND_NONE and !is_root) {
            depth -= 1;
        }

        const static_eval = pos.eval.eval(pos, me);
        best_score = static_eval;

        self.ns_stack[self.ply].eval = static_eval;

        if (tt_hit and !in_check) {
            if ((tt_bound == tt.Bound.BOUND_LOWER and tt_score > static_eval) or
                (tt_bound == tt.Bound.BOUND_UPPER and tt_score < static_eval) or
                (tt_bound == tt.Bound.BOUND_EXACT))
            {
                best_score = tt_score;
            }
        }

        //const improving: u1 = if (self.ply >= 4 and static_eval > self.ns_stack[self.ply - 4].eval and !in_check) 1 else if (self.ply >= 2 and static_eval > self.ns_stack[self.ply - 2].eval and !in_check) 1 else 0;
        var improving: u1 = 0;
        if (!in_check) {
            if (self.ply >= 4 and static_eval > self.ns_stack[self.ply - 4].eval) {
                improving = 1;
            } else if (self.ply >= 2 and static_eval > self.ns_stack[self.ply - 2].eval) {
                improving = 1;
            }
        }

        const prune: bool = true;
        if (prune and !in_check and !is_pv and !skip_move) {
            const razor_depth = 2;
            const razor_margin = 150 + @as(i32, @intCast(improving)) * 75;

            if (depth <= razor_depth and static_eval + razor_margin <= alpha) {
                const raz_score = self.quiescence(alpha, beta, pos, depth, me);
                if (raz_score <= alpha) return raz_score;
            }

            if ((depth <= 8) and ((best_score - 85 * (@as(i32, @intCast(depth)) - improving)) >= beta)) {
                return best_score;
            }

            if (best_score >= beta and !is_null and depth >= 2 and (pos.eval.phase[me.toU4()] > 0) and (!tt_hit or !(tt_bound == tt.Bound.BOUND_UPPER) or tt_score >= beta)) {
                var R = 4 + @divTrunc(depth, 5) + @as(i8, @intCast(@min(3, @divTrunc(best_score - beta, 190))));
                R += if (self.ns_stack[self.ply - 1].is_tactical) 1 else 0;

                // make null move
                self.ns_stack[self.ply].is_null = true;
                self.ns_stack[self.ply].is_tactical = false;
                self.ns_stack[self.ply].move = Move.empty();
                self.ns_stack[self.ply].piece = Piece.NO_PIECE;
                self.ply += 1;
                pos.play_null_move();
                tt.TT.prefetch(pos.hash);
                // make move

                score = -self.pvs(depth - R, -beta, -beta + 1, pos, !cutnode, opp);

                // unmake move
                self.ply -= 1;
                pos.undo_null_move();
                // unmake move

                if (score >= beta) {
                    if (@abs(beta) < MATE_VALUE and depth < 14) {
                        return if (_is_mate_score(score)) beta else score;
                    }

                    score = self.pvs(depth - R, beta - 1, beta, pos, false, me);

                    if (score >= beta) return score;
                }
            }
        }

        best_score = -MATE_VALUE + @as(i32, self.ply);
        var best_move = Move.empty();

        var move_list: MoveList = .{};

        pos.generate_legals(me, &move_list);

        if (move_list.count == 0) {
            if (in_check) {
                // Checkmate
                return -MATE_VALUE + @as(i32, self.ply);
            } else {
                // Stalemate
                return 0;
            }
        }

        // Count as non-terminal node
        if (move_list.count > 0) {
            self.non_terminal_nodes += 1;
            //std.debug.print("Non-terminal node at depth {}, ply {}, moves {}\n", .{ depth, self.ply, move_list.count });
        }

        var score_list: ScoreList = .{};

        ms.score_move(pos, self, &move_list, &score_list, tt_move, me);

        self.mv_killer[self.ply + 1][0] = Move.empty();
        self.mv_killer[self.ply + 1][1] = Move.empty();
        self.excluded[self.ply + 1] = Move.empty();
        self.dextension[self.ply] = if (self.ply > 0) self.dextension[self.ply - 1] else 0;

        var quiet_list: MoveList = .{};
        var quet_mv_pieces: PieceList = .{};
        var quiets_tried: u8 = 0;
        var played: u8 = 0;
        var skip_quiets = false;

        for (0..move_list.count) |mv_idx| {
            const move = ms.get_next_best(&move_list, &score_list, mv_idx);

            if (move.equal(self.excluded[self.ply])) continue;

            const mv_quiet = move.is_quiet();
            const piece = pos.board[move.from];

            const sc_hist: i32 = self.get_sh(me.toU4(), move.from, move.to);
            var cm_hist: i32 = 0;
            var fm_hist: i32 = 0;

            if (self.ply >= 1) {
                const parent = self.ns_stack[self.ply - 1].move;
                const p_piece = self.ns_stack[self.ply - 1].piece;
                cm_hist += self.get_ch(p_piece.toU4(), parent.to, piece.toU4(), move.to);
            }

            if (self.ply >= 2) {
                const gparent = self.ns_stack[self.ply - 2].move;
                const gp_piece = self.ns_stack[self.ply - 2].piece;
                fm_hist += self.get_fh(gp_piece.toU4(), gparent.to, piece.toU4(), move.to);
            }
            const full_hist = sc_hist + cm_hist + fm_hist;

            if (!is_root and best_score > MATED_IN_MAX) {
                if (mv_quiet) {
                    if (skip_quiets) continue;

                    if (depth <= histroy_depth[improving] and (cm_hist + fm_hist) < cm_history_limit[improving]) {
                        continue;
                    }

                    // if (depth <= histroy_depth[improving] and fm_hist < fm_history_limit[improving]) {
                    //     continue;
                    // }

                    if (depth <= histroy_depth[improving] and sc_hist < (history_limit[improving] * depth)) {
                        continue;
                    }

                    const futilityMargin = static_eval + 90 * @as(i32, depth);
                    if (futilityMargin <= alpha and depth <= 8 and (sc_hist < futility_histroy_limit[improving])) {
                        skip_quiets = true;
                    }

                    if ((depth <= lmp_depth) and (quiets_tried >= lmp[improving][@min(11, @as(usize, @intCast(depth)))])) {
                        skip_quiets = true;
                    }
                }

                if (depth <= 8 and !in_check) {
                    const depth_i32 = depth_as_i32(depth);
                    const see_val: i32 = if (mv_quiet) -46 * depth_i32 else -10 * depth_i32 * depth_i32;
                    if (ms.see_value(pos, move, false) < see_val) continue;
                }
            }

            if (mv_quiet) {
                quiets_tried += 1;
                quiet_list.append(move);
                quet_mv_pieces.append(piece);
            }

            var new_depth = depth;

            // make move
            played += 1;
            self.ns_stack[self.ply].is_null = false;
            self.ns_stack[self.ply].is_tactical = !mv_quiet;
            self.ns_stack[self.ply].move = move;
            self.ns_stack[self.ply].piece = piece;
            self.ply += 1;
            pos.play(move, me);
            tt.TT.prefetch(pos.hash);
            self.nodes += 1;
            // make move

            if (pos.in_check(me)) {
                new_depth += 1;
            }

            const singular: bool = !is_root and !skip_move and depth >= 8 and move.equal(tt_move) and tt_depth >= depth - 3 and tt_bound == tt.Bound.BOUND_LOWER;

            extension = 0;
            if (singular) {
                r_beta = @max(tt_score - depth, -MATE_VALUE);

                // unmake move
                self.ply -= 1;
                pos.undo(move, me);
                // unmake move

                self.excluded[self.ply] = tt_move;
                score = self.pvs(@divTrunc(depth - 1, 2), r_beta - 1, r_beta, pos, cutnode, me);
                self.excluded[self.ply] = Move.empty();

                // make move
                // played += 1;
                self.ns_stack[self.ply].is_null = false;
                self.ns_stack[self.ply].is_tactical = !mv_quiet;
                self.ns_stack[self.ply].move = move;
                self.ns_stack[self.ply].piece = piece;
                self.ply += 1;
                pos.play(move, me);
                tt.TT.prefetch(pos.hash);
                // make move

                const double_extend = !is_pv and (score < r_beta - 10) and (self.dextension[self.ply] <= 6);

                if (double_extend) {
                    extension = 2;
                } else if (score < r_beta) {
                    extension = 1;
                } else if (tt_score >= beta or tt_score <= alpha) {
                    extension = -1;
                } else {
                    extension = 0;
                }
            }

            new_depth += extension;

            if (extension > 1) {
                self.dextension[self.ply] += 1;
            }

            var reduction: i8 = 0;

            if (mv_idx > 0 and depth > 2) {
                if (mv_quiet) {
                    reduction = lmr[@as(usize, @intCast(@min(depth, MAX_DEPTH - 1)))][@as(usize, @intCast(@min(mv_idx + 1, MAX_MOVES - 1)))];

                    if (improving == 0) reduction += 1;
                    if (is_pv) reduction -= 1;

                    if (move.equal(self.mv_killer[self.ply][0]) or move.equal(self.mv_killer[self.ply][1])) {
                        reduction -= 1;
                    }

                    reduction -= @as(i8, @intCast(@max(-4, @min(4, @divTrunc(full_hist, 4000)))));
                    reduction += @as(i8, @intCast(@min(2, @abs(@divTrunc(static_eval - alpha, 350)))));
                }

                reduction = @min(new_depth - 1, @max(reduction, 1));

                score = -self.pvs(new_depth - reduction, -alpha - 1, -alpha, pos, true, opp);

                full_search = (score > alpha) and (reduction != 1);
            } else {
                full_search = !is_pv or (played > 1);
            }

            if (full_search) {
                score = -self.pvs(new_depth - 1, -alpha - 1, -alpha, pos, !cutnode, opp);
            }

            if (is_pv and (played == 1 or score > alpha)) {
                score = -self.pvs(new_depth - 1, -beta, -alpha, pos, false, opp);
            }

            // unmake move
            self.ply -= 1;
            pos.undo(move, me);
            tt.TT.prefetch_write(pos.hash);
            // unmake move

            if (extension > 1) {
                self.dextension[self.ply] -= 1;
            }

            if (self.check_stop_conditions()) {
                self.stop_on_time = true;
                return 0;
            }

            if (score > best_score) {
                best_score = score;

                if (score > alpha) {
                    best_move = move;
                    self.update_pv(move);

                    alpha = score;

                    if (alpha >= beta) {
                        if (mv_quiet) {
                            history.update_all_history(self, move, quiet_list, quet_mv_pieces, depth, me);
                        }
                        break;
                    }
                }
            }
        }

        tt_bound = if (best_score >= beta) tt.Bound.BOUND_LOWER else if (alpha != _alpha) tt.Bound.BOUND_EXACT else tt.Bound.BOUND_UPPER;
        if (!skip_move) {
            tt.TT.store(tt.scoreEntry.new(pos.hash, best_move, tt.TT.to_hash_score(best_score, self.ply), tt_bound, depth, tt.TT.age));
        }

        return best_score;
    }

    // pub fn quiescence(self: *Search, _alpha: i32, _beta: i32, pos: *Position, depth: i8, comptime color: Color) i32 {
    //     const opp = if (color == Color.White) Color.Black else Color.White;
    //     const me = if (color == Color.White) Color.White else Color.Black;
    //     var alpha: i32 = @max(_alpha, -MATE_VALUE + @as(i32, self.ply));
    //     const beta: i32 = @min(_beta, MATE_VALUE - @as(i32, self.ply) + 1);
    //     var best_score: i32 = undefined;
    //     var score: i32 = undefined;
    //     const in_check = pos.in_check(color);

    //     self.pv_length[self.ply] = 0;
    //     self.seldepth = @max(self.ply, self.seldepth);

    //     if (alpha >= beta) return alpha;

    //     if (self.ply >= MAX_PLY) return pos.eval.eval(pos, me);

    //     if (self.check_stop_conditions()) {
    //         self.stop_on_time = true;
    //         return 0;
    //     }

    //     if (pos.is_draw()) return 1 - (@as(i32, @intCast(self.nodes & 2)));

    //     const entry = tt.TT.fetch(pos.hash);
    //     const tt_hit: bool = if (entry != null) true else false;

    //     var tt_move = Move.empty();
    //     var tt_score: i32 = 0;
    //     var tt_bound = tt.Bound.BOUND_NONE;
    //     const tt_depth: i8 = if (in_check or depth >= 0) 0 else -1;

    //     if (tt_hit) {
    //         tt_move = entry.?.move;
    //         tt_bound = entry.?.bound;
    //         tt_score = tt.TT.adjust_hash_score(entry.?.score, self.ply);
    //         //tt_depth = entry.?.depth;

    //         if ((tt_bound == tt.Bound.BOUND_LOWER and tt_score >= beta) or
    //             (tt_bound == tt.Bound.BOUND_UPPER and tt_score <= alpha) or
    //             (tt_bound == tt.Bound.BOUND_EXACT))
    //         {
    //             return tt_score;
    //         }
    //     }

    //     if (in_check) {
    //         best_score = -MATE_VALUE + @as(i32, self.ply);
    //     } else {
    //         best_score = pos.eval.eval(pos, me);

    //         if (tt_hit) {
    //             if ((tt_bound == tt.Bound.BOUND_LOWER and tt_score > best_score) or
    //                 (tt_bound == tt.Bound.BOUND_UPPER and tt_score < best_score) or
    //                 (tt_bound == tt.Bound.BOUND_EXACT))
    //             {
    //                 best_score = tt_score;
    //             }
    //         }

    //         if (best_score >= beta) return best_score;
    //         if (best_score > alpha) alpha = best_score;
    //     }

    //     var best_move = Move.empty();

    //     var move_list: MoveList = .{};
    //     pos.generate_captures_list(me, &move_list);
    //     var score_list: ScoreList = .{};
    //     ms.score_move(pos, self, &move_list, &score_list, tt_move, me);

    //     for (0..move_list.count) |mv_idx| {
    //         const move = ms.get_next_best(&move_list, &score_list, mv_idx);

    //         const see_val = ms.see_value(pos, move, false);

    //         if (!in_check and see_val < -1) continue;

    //         // make move
    //         self.ply += 1;
    //         pos.play(move, me);
    //         tt.TT.prefetch(pos.hash);
    //         self.nodes += 1;
    //         // make move

    //         score = -self.quiescence(-beta, -alpha, pos, depth - 1, opp);

    //         // unmake move
    //         self.ply -= 1;
    //         pos.undo(move, me);
    //         tt.TT.prefetch_write(pos.hash);
    //         // unmake move

    //         if (score > best_score) {
    //             best_score = score;
    //             if (score > alpha) {
    //                 best_move = move;
    //                 self.update_pv(move);
    //                 alpha = score;

    //                 if (alpha >= beta) break;
    //             }
    //         }
    //     }

    //     tt_bound = if (best_score >= beta) tt.Bound.BOUND_LOWER else if (best_score > _alpha) tt.Bound.BOUND_EXACT else tt.Bound.BOUND_UPPER;
    //     tt.TT.store(tt.scoreEntry.new(pos.hash, best_move, tt.TT.to_hash_score(best_score, self.ply), tt_bound, tt_depth, tt.TT.age));
    //     return best_score;
    // }

    pub fn quiescence(self: *Search, _alpha: i32, _beta: i32, pos: *Position, depth: i8, comptime color: Color) i32 {
        const opp = if (color == Color.White) Color.Black else Color.White;
        const me = if (color == Color.White) Color.White else Color.Black;
        var alpha: i32 = @max(_alpha, -MATE_VALUE + @as(i32, self.ply));
        const beta: i32 = @min(_beta, MATE_VALUE - @as(i32, self.ply) + 1);
        var best_score: i32 = undefined;
        var score: i32 = undefined;
        const in_check = pos.in_check(color);

        self.pv_length[self.ply] = 0;
        self.seldepth = @max(self.ply, self.seldepth);

        if (alpha >= beta) return alpha;

        if (self.ply >= MAX_PLY) return pos.eval.eval(pos, me);

        if (self.check_stop_conditions()) {
            self.stop_on_time = true;
            return 0;
        }

        if (pos.is_draw()) return 1 - (@as(i32, @intCast(self.nodes & 2)));

        const entry = tt.TT.fetch(pos.hash);
        const tt_hit: bool = if (entry != null) true else false;

        var tt_move = Move.empty();
        var tt_score: i32 = 0;
        var tt_bound = tt.Bound.BOUND_NONE;
        const tt_depth: i8 = if (in_check or depth >= 0) 0 else -1;

        if (tt_hit) {
            tt_move = entry.?.move;
            tt_bound = entry.?.bound;
            tt_score = tt.TT.adjust_hash_score(entry.?.score, self.ply);

            if ((tt_bound == tt.Bound.BOUND_LOWER and tt_score >= beta) or
                (tt_bound == tt.Bound.BOUND_UPPER and tt_score <= alpha) or
                (tt_bound == tt.Bound.BOUND_EXACT))
            {
                return tt_score;
            }
        }

        if (in_check) {
            best_score = -MATE_VALUE + @as(i32, self.ply);
        } else {
            best_score = pos.eval.eval(pos, me);

            if (tt_hit) {
                if ((tt_bound == tt.Bound.BOUND_LOWER and tt_score > best_score) or
                    (tt_bound == tt.Bound.BOUND_UPPER and tt_score < best_score) or
                    (tt_bound == tt.Bound.BOUND_EXACT))
                {
                    best_score = tt_score;
                }
            }

            if (best_score >= beta) return best_score;
            if (best_score > alpha) alpha = best_score;
        }

        var best_move = Move.empty();

        var move_list: MoveList = .{};
        if (in_check) {
            pos.generate_legals(me, &move_list);
        } else {
            pos.generate_captures_list(me, &move_list);
        }
        var score_list: ScoreList = .{};
        ms.score_move(pos, self, &move_list, &score_list, tt_move, me);

        const delta_margin: i32 = 500; // Margin for delta pruning

        for (0..move_list.count) |mv_idx| {
            const move = ms.get_next_best(&move_list, &score_list, mv_idx);

            // Delta pruning for captures
            if (!in_check and move.is_capture()) {
                const captured = if (move.flags == MoveFlags.EN_PASSANT) 0 else pos.board[move.to].type_of().toU3();
                const piece_value = ms.piece_val[captured];
                if (best_score + piece_value + delta_margin < alpha) {
                    continue;
                }
            }

            // SEE pruning with depth-dependent threshold
            const see_val = ms.see_value(pos, move, false);
            // if (!in_check and see_val < -depth * 50) {
            //     continue;
            // }
            if (!in_check and see_val < -1) continue;

            // make move
            self.ply += 1;
            pos.play(move, me);
            tt.TT.prefetch(pos.hash);
            self.nodes += 1;
            // make move

            score = -self.quiescence(-beta, -alpha, pos, depth - 1, opp);

            // unmake move
            self.ply -= 1;
            pos.undo(move, me);
            tt.TT.prefetch_write(pos.hash);
            // unmake move

            if (score > best_score) {
                best_score = score;
                if (score > alpha) {
                    best_move = move;
                    self.update_pv(move);
                    alpha = score;

                    if (alpha >= beta) break;
                }
            }
        }

        tt_bound = if (best_score >= beta) tt.Bound.BOUND_LOWER else if (best_score > _alpha) tt.Bound.BOUND_EXACT else tt.Bound.BOUND_UPPER;
        tt.TT.store(tt.scoreEntry.new(pos.hash, best_move, tt.TT.to_hash_score(best_score, self.ply), tt_bound, tt_depth, tt.TT.age));
        return best_score;
    }

    inline fn update_pv(self: *Search, move: Move) void {
        self.pv_table[self.ply][0] = move;
        std.mem.copyBackwards(Move, self.pv_table[self.ply][1..(self.pv_length[self.ply + 1] + 1)], self.pv_table[self.ply + 1][0..(self.pv_length[self.ply + 1])]);
        self.pv_length[self.ply] = self.pv_length[self.ply + 1] + 1;
    }
};
