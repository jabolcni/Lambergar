const std = @import("std");
const position = @import("position.zig");
const ms = @import("movescorer.zig");
const tt = @import("tt.zig");

const Instant = std.time.Instant;

const Position = position.Position;
const Piece = position.Piece;
const Color = position.Color;
const Move = position.Move;

const DefaultPrng = std.rand.DefaultPrng;
const Random = std.rand.Random;

pub const MAX_DEPTH = 100;
pub const MAX_PLY = 129;
pub const MAX_MOVES = 256;
pub const MAX_MATE_PLY = 50;
pub const MAX_SCORE = 50_000;
pub const MATE_VALUE = 49_000;
pub const MATED_IN_MAX = MAX_PLY - MATE_VALUE;

const NullMovePruningDepth = 2;

pub fn start_search(search: *Search, pos: *Position) void {
    if (pos.side_to_play == Color.White) {
        search.iterative_deepening(pos, Color.White);
    } else {
        search.iterative_deepening(pos, Color.Black);
    }
}

pub inline fn _is_mate_score(score: i32) bool {
    return ((score <= -MATE_VALUE + MAX_MATE_PLY) or (score >= MATE_VALUE - MAX_MATE_PLY));
}

pub inline fn _mate_in(score: i32) i32 {
    return if (score > 0) @divFloor(MATE_VALUE - score + 1, 2) else @divFloor(-MATE_VALUE - score, 2);
}

pub const Termination = enum(u2) { INFINITE, DEPTH, NODES, TIME };

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

    pub fn set_time_limits(self: *SearchManager, movestogo: ?u32, movetime: ?u64, rem_time: ?u64, time_inc: ?u32) void {
        const overhead: u6 = 50;

        if (self.termination == Termination.INFINITE or self.termination == Termination.DEPTH or self.termination == Termination.NODES) {
            self.max_ms = 1 << 63;
            self.early_ms = self.max_ms;
        } else if (self.termination == Termination.TIME) {
            if (movetime != null) {
                self.max_ms = movetime.? - overhead;
                self.early_ms = self.max_ms;
                return;
            } else if (rem_time != null) {
                var inc: u32 = if (time_inc != null) time_inc.? else 0;
                if (rem_time.? <= overhead) {
                    self.max_ms = @max(10, overhead - 10);
                    self.early_ms = self.max_ms;
                    return;
                }
                if (movestogo == null) {
                    self.max_ms = inc + (rem_time.? - overhead) / 30;
                    self.early_ms = 3 * self.max_ms / 4;
                } else {
                    self.max_ms = inc + ((2 * (rem_time.? - overhead)) / (2 * movestogo.? + 1));
                    self.early_ms = self.max_ms;
                }
                self.max_ms = @min(self.max_ms, rem_time.? - overhead);
                self.early_ms = @min(self.early_ms, rem_time.? - overhead);
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
};

pub const Search = struct {
    best_move: Move = undefined,
    stop_on_time: bool = false,
    stop: bool = false,
    timer: std.time.Timer = undefined,
    max_depth: u32 = MAX_DEPTH - 1,
    nodes: u64 = 0,
    ply: u16 = 0,

    pv_length: [MAX_PLY]u16 = undefined,
    pv_table: [MAX_PLY][MAX_PLY]Move = undefined,

    mv_killer: [MAX_PLY + 1][2]Move = undefined,
    sc_history: [2][64][64]i32 = undefined,
    sc_follow_table: [2][position.NPIECES][64][position.NPIECES][64]i32 = undefined,

    ns_stack: [MAX_PLY + 4]NodeState = undefined,
    move_stack: [MAX_PLY + 4]Move = undefined,
    piece_stack: [MAX_PLY + 4]Piece = undefined,

    manager: SearchManager = undefined,

    pub fn new() Search {
        var searcher = Search{};

        searcher.clear_for_new_search();
        return searcher;
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

    inline fn clear_sc_history(self: *Search) void {
        for (0..64) |i| {
            for (0..64) |j| {
                self.sc_history[0][i][j] = 0;
                self.sc_history[1][i][j] = 0;
            }
        }
    }

    inline fn clear_sc_follow_table(self: *Search) void {
        for (0..position.NPIECES) |i| {
            for (0..64) |j| {
                for (0..position.NPIECES) |k| {
                    for (0..64) |l| {
                        self.sc_follow_table[0][i][j][k][l] = 0;
                        self.sc_follow_table[1][i][j][k][l] = 0;
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
        }
    }

    inline fn clear_mv_pc_stacks(self: *Search) void {
        for (0..(MAX_PLY + 4)) |i| {
            self.move_stack[i] = Move.empty();
            self.piece_stack[i] = Piece.NO_PIECE;
        }
    }

    pub fn clear_for_new_search(self: *Search) void {
        self.clear_pv_table();
        self.clear_mv_killer();
        self.clear_sc_history();
        self.clear_node_state_stack();
        self.clear_mv_pc_stacks();
        self.clear_sc_follow_table();

        self.best_move = Move.empty();
        self.stop_on_time = false;
        self.stop = false;

        self.nodes = 0;
        self.ply = 0;
    }

    pub inline fn check_stop_conditions(self: *Search) bool {
        if (self.stop) return true;

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

    pub inline fn check_early_stop_conditions(self: *Search) bool {
        if (self.stop) return true;

        if ((self.timer.read() / std.time.ns_per_ms) >= self.manager.early_ms) return true;

        return false;
    }

    pub fn iterative_deepening(self: *Search, pos: *Position, comptime color: Color) void {
        const stdout = std.io.getStdOut().writer();
        const allocator = std.heap.c_allocator;

        self.clear_for_new_search();

        var alpha: i32 = -MAX_SCORE;
        var beta: i32 = MAX_SCORE;
        var score: i32 = 0;
        var delta: i32 = 12;

        var it_depth: i8 = 1;
        var depth = it_depth;

        self.timer = std.time.Timer.start() catch unreachable;

        mainloop: while (it_depth <= self.max_depth) {
            self.ply = 0;
            self.nodes = 0;
            depth = it_depth;

            if (depth >= 4) {
                alpha = @max(-MAX_SCORE, score - delta);
                beta = @min(score + delta, MAX_SCORE);
            }

            const start = Instant.now() catch unreachable;

            aspirationloop: while (delta <= MAX_SCORE) {
                score = self.pvs(depth, alpha, beta, pos, color);

                if (self.stop) {
                    break :mainloop;
                }

                if (score <= alpha) {
                    beta = @divTrunc(alpha + beta, 2);
                    alpha = @max(-MAX_SCORE, score - delta);
                    depth = it_depth;
                } else if (score >= beta) {
                    beta = @min(score + delta, MAX_SCORE);
                    depth = @max(depth - 1, it_depth - 5);
                } else {
                    break :aspirationloop;
                }

                delta += 2 + @divTrunc(delta, 2);
            }

            if (self.stop) {
                break :mainloop;
            }

            const now = Instant.now() catch unreachable;
            const time_elapsed = now.since(start);
            const elapsed_nanos = @as(f64, @floatFromInt(time_elapsed));
            const elapsed_seconds = elapsed_nanos / 1_000_000_000;
            const elapsed_ms: u32 = @intFromFloat(elapsed_nanos / 1_000_000);
            const nps: u46 = @intFromFloat(@as(f64, @floatFromInt(self.nodes)) / elapsed_seconds);

            self.best_move = self.pv_table[0][0];

            const est_hash_full = tt.TT.hash_full();

            _ = std.fmt.format(stdout, "info score ", .{}) catch unreachable;
            if (_is_mate_score(score)) {
                _ = std.fmt.format(stdout, "mate {} ", .{_mate_in(score)}) catch unreachable;
            } else {
                _ = std.fmt.format(stdout, "cp {} ", .{score}) catch unreachable;
            }
            _ = std.fmt.format(stdout, "depth {} nodes {} nps {d} time {d} hashfull {d} pv ", .{ depth, self.nodes, nps, elapsed_ms, est_hash_full }) catch unreachable;

            for (0..self.pv_length[0]) |next_ply| {
                var pv_move_str = self.pv_table[0][next_ply].to_str(allocator);
                defer allocator.free(pv_move_str);
                _ = std.fmt.format(stdout, "{s} ", .{pv_move_str}) catch unreachable;
            }
            _ = std.fmt.format(stdout, "\n", .{}) catch unreachable;

            if (self.stop or self.check_early_stop_conditions()) {
                self.stop = true;
                break :mainloop;
            }

            it_depth += 1;
        }
    }

    pub fn pvs(self: *Search, _depth: i8, _alpha: i32, _beta: i32, pos: *Position, comptime color: Color) i32 {
        comptime var opp = if (color == Color.White) Color.Black else Color.White;
        var depth = _depth;
        var qsearch: bool = if (depth <= 0) true else false;
        var is_root: bool = if (self.ply == 0) true else false;

        var alpha: i32 = _alpha;
        var beta: i32 = _beta;
        var r_alpha: i32 = undefined;
        var r_beta: i32 = undefined;

        var best_score: i32 = undefined;
        var score: i32 = undefined;

        if (qsearch) {
            return self.quiescence(alpha, beta, pos, color);
        }

        self.pv_length[self.ply] = 0;
        self.nodes += 1;

        if (!is_root) {
            if (pos.is_draw()) return 1 - (@as(i32, @intCast(self.nodes & 2)));

            if (self.ply >= MAX_PLY) return pos.eval.eval(pos, color);

            r_alpha = @max(alpha, -MATE_VALUE + @as(i32, self.ply));
            r_beta = @min(beta, MATE_VALUE - @as(i32, self.ply) - 1);

            if (r_alpha >= r_beta) return r_alpha;
        }

        if (self.check_stop_conditions()) {
            self.stop_on_time = true;
            return 0;
        }

        var is_pv: bool = if (alpha != beta - 1) true else false;
        var tt_move = Move.empty();
        var tt_score: i32 = -MATE_VALUE;
        var tt_bound = tt.Bound.BOUND_NONE;
        var tt_depth: u8 = 0;

        var entry = tt.TT.fetch(pos.hash);
        var tt_hit: bool = if (entry != null) true else false;

        if (tt_hit) {
            tt_move = entry.?.move;
            tt_bound = entry.?.bound;
            tt_score = tt.TT.adjust_hash_score(entry.?.score, self.ply);
            tt_depth = entry.?.depth;

            if (!is_pv and tt_depth >= depth) {
                if ((tt_bound == tt.Bound.BOUND_LOWER and tt_score >= beta) or
                    (tt_bound == tt.Bound.BOUND_UPPER and tt_score <= alpha) or
                    (tt_bound == tt.Bound.BOUND_EXACT))
                {
                    return tt_score;
                }
            }
        }

        var in_check = pos.in_check(color);
        var static_eval = pos.eval.eval(pos, color);
        best_score = static_eval;

        self.ns_stack[self.ply].eval = static_eval;

        var improving: u1 = if (self.ply >= 2 and static_eval > self.ns_stack[self.ply - 2].eval) 1 else 0;

        var prune: bool = true;
        if (prune and !in_check and !is_pv) {
            if (depth <= 2 and static_eval + 150 < alpha) {
                return self.quiescence(alpha, beta, pos, color);
            }

            if ((depth <= 8) and ((best_score - 85 * (depth - improving)) >= beta)) {
                return best_score;
            }

            if (static_eval >= beta and self.ply >= 1 and !self.ns_stack[self.ply - 1].is_null and depth >= NullMovePruningDepth and (pos.eval.phase[color.toU4()] > 0)) {
                var R = 3 + @divTrunc(depth, 4) + @as(i8, @intCast(@min(3, @divTrunc(static_eval - beta, 80))));

                // make null move
                self.ply += 1;
                pos.play_null_move();
                self.ns_stack[self.ply].is_null = true;
                self.ns_stack[self.ply].is_tactical = false;
                tt.TT.prefetch(pos.hash);
                // make move

                score = -self.pvs(depth - R, -beta, -beta + 1, pos, opp);

                // unmake move
                self.ply -= 1;
                pos.undo_null_move();
                // unmake move

                if (score >= beta) {
                    return if (_is_mate_score(score)) beta else score;
                }
            }
        }

        best_score = -MATE_VALUE + @as(i32, self.ply);
        var best_move = Move.empty();

        var move_list = std.ArrayList(Move).initCapacity(std.heap.c_allocator, 48) catch unreachable;
        defer move_list.deinit();

        pos.generate_legals(color, &move_list);

        if (move_list.items.len == 0) {
            if (in_check) {
                // Checkmate
                return -MATE_VALUE + @as(i32, self.ply);
            } else {
                // Stalemate
                return 0;
            }
        }

        var score_list = std.ArrayList(i32).initCapacity(std.heap.c_allocator, move_list.items.len) catch unreachable;
        defer score_list.deinit();
        ms.score_move(pos, self, &move_list, &score_list, tt_move, color);

        self.mv_killer[self.ply + 1][0] = Move.empty();
        self.mv_killer[self.ply + 1][1] = Move.empty();

        for (0..move_list.items.len) |mv_idx| {
            var move = ms.get_next_best(&move_list, &score_list, mv_idx);

            var mv_quiet = move.is_quiet();

            var new_depth = depth - 1;

            // make move
            self.ply += 1;
            pos.play(move, color);
            self.ns_stack[self.ply].is_null = false;
            self.ns_stack[self.ply].is_tactical = !mv_quiet;
            tt.TT.prefetch(pos.hash);
            // make move

            if (pos.in_check(color)) {
                new_depth += 1;
            }

            var reduction: i8 = 0;

            if (mv_idx > 0) {
                if (depth >= 3 and mv_quiet) {
                    if (improving == 0) reduction += 1;
                    if (reduction > 0 and is_pv) reduction -= 1;
                }
                reduction = @min(new_depth - 1, @max(reduction, 0));
            }

            if (reduction > 0) {
                score = -self.pvs(new_depth - reduction, -alpha - 1, -alpha, pos, opp);

                if (score > alpha) {
                    score = -self.pvs(new_depth, -alpha - 1, -alpha, pos, opp);
                }
            } else if (!is_pv or mv_idx > 0) {
                score = -self.pvs(new_depth, -alpha - 1, -alpha, pos, opp);
            }

            if (is_pv and (mv_idx == 0 or score > alpha)) { //
                score = -self.pvs(new_depth, -beta, -alpha, pos, opp);
            }

            // unmake move
            self.ply -= 1;
            pos.undo(move, color);
            tt.TT.prefetch_write(pos.hash);
            // unmake move

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
                    //hash_bound = tt.Bound.BOUND_EXACT;

                    if (alpha >= beta) {
                        //hash_bound = tt.Bound.BOUND_LOWER;
                        if (mv_quiet) {
                            self.update_mv_killer(move);
                            self.update_sc_history(pos, move, depth);
                        }
                        break;
                    }
                }
            }
        }

        tt_bound = if (best_score >= beta) tt.Bound.BOUND_LOWER else if (alpha != _alpha) tt.Bound.BOUND_EXACT else tt.Bound.BOUND_UPPER;
        tt.TT.store(tt.scoreEntry.new(pos.hash, best_move, tt.TT.to_hash_score(best_score, self.ply), tt_bound, @as(u8, @intCast(depth)), tt.TT.age));

        return best_score;
    }

    pub fn quiescence(self: *Search, _alpha: i32, _beta: i32, pos: *Position, comptime color: Color) i32 {
        comptime var opp = if (color == Color.White) Color.Black else Color.White;
        var alpha: i32 = _alpha;
        var beta: i32 = _beta;
        var best_score: i32 = undefined;
        var score: i32 = undefined;

        self.pv_length[self.ply] = 0;
        self.nodes += 1;

        if (alpha >= beta) return alpha;

        if (self.ply >= MAX_PLY) return pos.eval.eval(pos, color);

        if (self.check_stop_conditions()) {
            self.stop_on_time = true;
            return 0;
        }

        if (pos.is_draw()) return 1 - (@as(i32, @intCast(self.nodes & 2)));

        var entry = tt.TT.fetch(pos.hash);
        var tt_hit: bool = if (entry != null) true else false;

        var tt_move = Move.empty();
        var tt_score: i32 = 0;
        var tt_bound = tt.Bound.BOUND_NONE;
        var tt_depth: u8 = 0;

        if (tt_hit) {
            tt_move = entry.?.move;
            tt_bound = entry.?.bound;
            tt_score = tt.TT.adjust_hash_score(entry.?.score, self.ply);
            tt_depth = entry.?.depth;

            if ((tt_bound == tt.Bound.BOUND_LOWER and tt_score >= beta) or
                (tt_bound == tt.Bound.BOUND_UPPER and tt_score <= alpha) or
                (tt_bound == tt.Bound.BOUND_EXACT))
            {
                return tt_score;
            }
        }

        best_score = pos.eval.eval(pos, color);

        if (best_score >= beta) return best_score;

        if (best_score > alpha) {
            alpha = best_score;
        }
        //}

        var best_move = Move.empty();
        //hash_bound = tt.Bound.BOUND_UPPER;

        var move_list = std.ArrayList(Move).initCapacity(std.heap.c_allocator, 48) catch unreachable;
        defer move_list.deinit();
        pos.generate_captures(color, &move_list);

        var score_list = std.ArrayList(i32).initCapacity(std.heap.c_allocator, move_list.items.len) catch unreachable;
        defer score_list.deinit();
        ms.score_move(pos, self, &move_list, &score_list, tt_move, color);

        for (0..move_list.items.len) |mv_idx| {
            var move = ms.get_next_best(&move_list, &score_list, mv_idx);

            // make move
            self.ply += 1;
            pos.play(move, color);
            tt.TT.prefetch(pos.hash);
            // make move

            score = -self.quiescence(-beta, -alpha, pos, opp);

            // unmake move
            self.ply -= 1;
            pos.undo(move, color);
            tt.TT.prefetch_write(pos.hash);
            // unmake move

            if (score > best_score) {
                best_score = score;
                if (score > alpha) {
                    best_move = move;
                    self.update_pv(move);
                    alpha = score;
                    //hash_bound = tt.Bound.BOUND_EXACT;

                    if (alpha >= beta) {

                        //hash_bound = tt.Bound.BOUND_LOWER;
                        break;
                    }
                }
            }
        }

        tt_bound = if (best_score >= beta) tt.Bound.BOUND_LOWER else if (best_score > _alpha) tt.Bound.BOUND_EXACT else tt.Bound.BOUND_UPPER;
        tt.TT.store(tt.scoreEntry.new(pos.hash, best_move, tt.TT.to_hash_score(best_score, self.ply), tt_bound, 0, tt.TT.age));
        return best_score;
    }

    inline fn update_mv_killer(self: *Search, move: Move) void {
        if (!move.equal(self.mv_killer[self.ply][0])) {
            var tmp0 = self.mv_killer[self.ply][0];
            self.mv_killer[self.ply][0] = move;
            self.mv_killer[self.ply][1] = tmp0;
        }
    }

    inline fn update_pv(self: *Search, move: Move) void {
        self.pv_table[self.ply][0] = move;
        std.mem.copy(Move, self.pv_table[self.ply][1..(self.pv_length[self.ply + 1] + 1)], self.pv_table[self.ply + 1][0..(self.pv_length[self.ply + 1])]);
        self.pv_length[self.ply] = self.pv_length[self.ply + 1] + 1;
    }

    inline fn update_sc_history(self: *Search, pos: *Position, move: Move, depth: i8) void {
        self.sc_history[pos.side_to_play.toU4()][move.from][move.to] += depth * depth;
    }
};
