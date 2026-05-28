const std = @import("std");
const position = @import("position.zig");
const ms = @import("movescorer.zig");
const tt = @import("tt.zig");
const history = @import("history.zig");
const evaluation = @import("evaluation.zig");
const nnue = @import("nnue.zig");
const lists = @import("lists.zig");
const uci = @import("uci.zig");
const fathom = @import("fathom.zig");
const search_params = @import("search_params.zig");
const compat_timer = @import("timer.zig");

pub const use_tb = @import("config").use_tb;

const Instant = compat_timer.Instant;

const Position = position.Position;
const Piece = position.Piece;
const PieceType = position.PieceType;
const Color = position.Color;
const Move = position.Move;
const MoveFlags = position.MoveFlags;
const Square = position.Square;

const MoveList = lists.MoveList;
const MoveScoreList = lists.MoveScoreList;
const PieceList = lists.PieceList;
const PieceTypeList = lists.PieceTypeList;
const MoveGenContext = position.Position.MoveGenContext;

const printout = uci.printout;

pub const MAX_DEPTH = 100; // Maximum search depth in plies.
pub const MAX_PLY = 128; // Maximum ply depth in the search tree. This is MAX_DEPTH + some buffer in case of extensions.
pub const MAX_MOVES = 256; // Maximum number of moves in a position.
pub const MAX_MATE_PLY = 50; // A reasonable maximum number of plies for a mate sequence.
pub const MAX_SCORE = 50_000; // An absolute score value, higher than any evaluation.
pub const MATE_VALUE = 49_000; // A score representing checkmate. It's less than MAX_SCORE to avoid overflows when calculating mate-in-X scores.
pub const TBWIN = 48_000; // A score representing a win from endgame tablebases.
pub const MATED_IN_MAX = MAX_PLY - MATE_VALUE; // Score for being mated in the maximum number of plies.

// Depth at which null move pruning is first considered.
const null_move_depth = 2;

// Pruning thresholds based on move history scores.
// histroy_depth: max depth for cm_hist pruning [not_improving, improving].
// cm_history_limit: threshold at shallow depths (≤3/≤2); cm_history_limit_deep at depths 4-6/3-4.
const histroy_depth = [_]i32{ 3, 2 };
const histroy_depth_deep = [_]i32{ 6, 4 };
const cm_history_limit = [_]i32{ 0, -1000 };
const cm_history_limit_deep = [_]i32{ -1000, -1000 };
const futility_histroy_limit = [_]i32{ -500, -1000 };

// Maximum depth for Late Move Pruning (LMP).
const lmp_depth = 8;

// Late Move Pruning (LMP) table. Defines how many quiet moves to search at a given depth.
// Indexed by [improving][depth]. 'improving' indicates if the static evaluation is improving for the side to move.
var lmp = [2][11]i8{
    [_]i8{ 0, 2, 3, 4, 6, 8, 10, 13, 17, 22, 30 },
    [_]i8{ 0, 4, 5, 7, 10, 13, 17, 22, 29, 38, 50 },
};

// Late Move Reductions (LMR) table. Stores the reduction amount for a given depth and move number.
var lmr: [MAX_DEPTH][MAX_MOVES]i8 = undefined;

fn depth_as_i32(depth: i8) i32 {
    return @as(i32, @intCast(depth));
}

// Checks if a score represents a checkmate.
pub fn _is_mate_score(score: i32) bool {
    return ((score <= -MATE_VALUE + MAX_MATE_PLY) or (score >= MATE_VALUE - MAX_MATE_PLY));
}

// Calculates the number of moves to mate from a mate score.
// Positive score means winning, negative means losing.
pub fn _mate_in(score: i32) i32 {
    return if (score > 0) @divFloor(MATE_VALUE - score + 1, 2) else @divFloor(-MATE_VALUE - score, 2);
}

// Initializes the Late Move Reductions (LMR) table.
// The reduction is based on the natural logarithm of depth and move number,
// which is a standard approach.
pub fn init_lmr() void {
    lmr[0][0] = 1;
    lmr[0][1] = 1;
    lmr[1][0] = 1;

    const params = search_params.params;
    const scale = @as(f32, @floatFromInt(params.lmr_log_scale)) / 100.0;
    const base_offset = @as(f32, @floatFromInt(params.lmr_base_offset));

    for (1..MAX_DEPTH) |depth| {
        for (1..MAX_MOVES) |played| {
            const depth_log = @log(@as(f32, @floatFromInt(depth)));
            const played_log = @log(@as(f32, @floatFromInt(played)));
            const reduction = 1.0 + depth_log * played_log * scale + base_offset;
            lmr[depth][played] = @intFromFloat(@max(1.0, reduction));
        }
    }
}

const MainMoveStage = enum {
    full,
    tt_quiet,
    good_noisy,
    killer1,
    killer2,
    counter,
    quiets,
    bad_noisy,
    done,
};

const PickedMove = struct {
    move: Move,
    score: i32,
    index: usize,
};

const MainMovePicker = struct {
    stage: MainMoveStage,
    tt_move: Move,
    killer1: Move,
    killer2: Move,
    counter: Move,

    noisy_scores: MoveScoreList = .{},
    noisy_index: usize = 0,
    noisy_generated: bool = false,

    quiet_scores: MoveScoreList = .{},
    quiet_index: usize = 0,
    quiet_generated: bool = false,

    tried_moves: [4]Move = [_]Move{Move.empty()} ** 4,
    tried_count: usize = 0,
    picked_count: usize = 0,

    fn init(self: *MainMovePicker, search: *Search, pos: *Position, ctx: MoveGenContext, tt_move: Move, counter_move: Move, use_staged: bool, in_check: bool, comptime color: Color) void {
        const staged = use_staged and !in_check;
        self.stage = if (staged) .tt_quiet else .full;
        self.tt_move = tt_move;
        self.killer1 = search.mv_killer[search.ply][0];
        self.killer2 = search.mv_killer[search.ply][1];
        self.counter = counter_move;

        self.noisy_scores.count = 0;
        self.noisy_index = 0;
        self.noisy_generated = false;

        self.quiet_scores.count = 0;
        self.quiet_index = 0;
        self.quiet_generated = false;

        self.tried_moves = [_]Move{Move.empty()} ** 4;
        self.tried_count = 0;
        self.picked_count = 0;

        if (!staged) {
            var move_list: MoveList = .{};
            pos.generate_legals_from_ctx(color, ctx, &move_list);
            ms.score_move_defer_quiets(pos, search, ctx.danger, &move_list, &self.quiet_scores, tt_move);
            self.quiet_generated = true;
        }
    }

    fn empty_full_list(self: *const MainMovePicker) bool {
        return self.stage == .full and self.quiet_scores.count == 0;
    }

    fn was_tried(self: *const MainMovePicker, move: Move) bool {
        for (0..self.tried_count) |i| {
            if (move.equal(self.tried_moves[i])) return true;
        }
        return false;
    }

    fn remember(self: *MainMovePicker, move: Move) void {
        if (move.is_empty() or self.was_tried(move) or self.tried_count >= self.tried_moves.len) return;
        self.tried_moves[self.tried_count] = move;
        self.tried_count += 1;
    }

    fn picked(self: *MainMovePicker, move: Move, score: i32) PickedMove {
        const idx = self.picked_count;
        self.picked_count += 1;
        return .{ .move = move, .score = score, .index = idx };
    }

    fn ensure_noisy(self: *MainMovePicker, search: *Search, pos: *Position, ctx: MoveGenContext, comptime color: Color) void {
        if (self.noisy_generated) return;
        var move_list: MoveList = .{};
        pos.generate_all_captures_no_evasion(color, ctx, &move_list);
        ms.score_move_defer_quiets(pos, search, ctx.danger, &move_list, &self.noisy_scores, self.tt_move);
        self.noisy_generated = true;
    }

    fn ensure_quiets(self: *MainMovePicker, search: *Search, pos: *Position, ctx: MoveGenContext, comptime color: Color) void {
        if (self.quiet_generated) return;
        var move_list: MoveList = .{};
        pos.generate_all_quiets_no_evasion(color, ctx, &move_list);
        const hash_move = if (self.was_tried(self.tt_move)) Move.empty() else self.tt_move;
        ms.score_move(pos, search, ctx.danger, &move_list, &self.quiet_scores, hash_move, color);
        self.quiet_generated = true;
    }

    fn try_direct_quiet(self: *MainMovePicker, pos: *Position, ctx: MoveGenContext, move: Move, score: i32, comptime color: Color) ?PickedMove {
        if (move.is_empty() or self.was_tried(move)) return null;
        if (!pos.is_legal_quiet_no_evasion_from_ctx(color, ctx, move)) return null;

        self.remember(move);
        return self.picked(move, score);
    }

    fn skip_remaining_quiets(self: *MainMovePicker) void {
        switch (self.stage) {
            .killer1, .killer2, .counter, .quiets => {
                self.quiet_index = self.quiet_scores.count;
                self.stage = .bad_noisy;
            },
            else => {},
        }
    }

    fn at_quiet_batch(self: *const MainMovePicker) bool {
        return self.stage == .quiets;
    }

    fn next(self: *MainMovePicker, search: *Search, pos: *Position, ctx: MoveGenContext, comptime color: Color) ?PickedMove {
        while (true) {
            switch (self.stage) {
                .full => {
                    while (self.quiet_index < self.quiet_scores.count) {
                        const idx = self.quiet_index;
                        var move = ms.get_next_best(&self.quiet_scores, idx);
                        var score = self.quiet_scores.items[idx].score;
                        if (score == ms.SortPendingQuiet) {
                            ms.score_deferred_quiets(pos, search, ctx.danger, &self.quiet_scores, idx, color);
                            move = ms.get_next_best(&self.quiet_scores, idx);
                            score = self.quiet_scores.items[idx].score;
                        }
                        self.quiet_index += 1;
                        return self.picked(move, score);
                    }
                    self.stage = .done;
                },
                .tt_quiet => {
                    self.stage = .good_noisy;
                    if (self.try_direct_quiet(pos, ctx, self.tt_move, ms.SortHash, color)) |picked_move| return picked_move;
                },
                .good_noisy => {
                    self.ensure_noisy(search, pos, ctx, color);
                    while (self.noisy_index < self.noisy_scores.count) {
                        const idx = self.noisy_index;
                        const move = ms.get_next_best(&self.noisy_scores, idx);
                        const score = self.noisy_scores.items[idx].score;
                        if (score <= ms.SortPendingQuiet) {
                            self.stage = .killer1;
                            break;
                        }
                        self.noisy_index += 1;
                        if (self.was_tried(move)) continue;
                        return self.picked(move, score);
                    } else {
                        self.stage = .killer1;
                    }
                },
                .killer1 => {
                    self.stage = .killer2;
                    if (self.try_direct_quiet(pos, ctx, self.killer1, ms.SortKiller1, color)) |picked_move| return picked_move;
                },
                .killer2 => {
                    self.stage = .counter;
                    if (self.try_direct_quiet(pos, ctx, self.killer2, ms.SortKiller2, color)) |picked_move| return picked_move;
                },
                .counter => {
                    self.stage = .quiets;
                    if (self.try_direct_quiet(pos, ctx, self.counter, ms.sortCounter, color)) |picked_move| return picked_move;
                },
                .quiets => {
                    self.ensure_quiets(search, pos, ctx, color);
                    while (self.quiet_index < self.quiet_scores.count) {
                        const idx = self.quiet_index;
                        const move = ms.get_next_best(&self.quiet_scores, idx);
                        const score = self.quiet_scores.items[idx].score;
                        self.quiet_index += 1;
                        if (self.was_tried(move)) continue;
                        return self.picked(move, score);
                    }
                    self.stage = .bad_noisy;
                },
                .bad_noisy => {
                    self.ensure_noisy(search, pos, ctx, color);
                    while (self.noisy_index < self.noisy_scores.count) {
                        const idx = self.noisy_index;
                        const move = ms.get_next_best(&self.noisy_scores, idx);
                        const score = self.noisy_scores.items[idx].score;
                        self.noisy_index += 1;
                        if (self.was_tried(move)) continue;
                        return self.picked(move, score);
                    }
                    self.stage = .done;
                },
                .done => return null,
            }
        }
    }
};

// Entry point for the main search thread.
// It starts the iterative deepening process and manages worker threads for parallel search.
pub fn start_main_search(search: *Search, pos: *Position) void {
    if (pos.side_to_play == Color.White) {
        search.iterative_deepening(pos, Color.White);
    } else {
        search.iterative_deepening(pos, Color.Black);
    }

    // Signal all worker threads to stop.
    for (1..uci.num_threads) |i| {
        @atomicStore(bool, &uci.thinkers[i].stop, true, .seq_cst);
    }

    for (1..uci.num_threads) |i| {
        // Wait for each worker thread to finish.
        if (uci.threads[i]) |thread| {
            thread.join();
        }
    }

    // Mark engine as idle: allow `isready` to reply after search completes.
    @atomicStore(bool, &uci.thinkers[0].stop, true, .seq_cst);
    @atomicStore(bool, &uci.search_running, false, .seq_cst);
}

// Entry point for a search worker thread in a parallel search.
// TODO: think about how to use only one function for iterative deepening instead of seperate functions for main and helper therads
pub fn start_search(search: *Search, pos: *Position, _delta: i32) void {
    if (pos.side_to_play == Color.White) {
        search.iterative_deepening_thread(pos, _delta, Color.White);
    } else {
        search.iterative_deepening_thread(pos, _delta, Color.Black);
    }
}

// Defines the conditions for terminating a search.
pub const Termination = enum(u3) { INFINITE, DEPTH, NODES, TIME, MOVETIME, MATE };

// Manages search parameters and time controls based on UCI commands.
pub const SearchManager = struct {
    termination: Termination = Termination.INFINITE,
    max_ms: u64 = 1000,
    early_ms: u64 = 1000,
    max_nodes: ?u32 = null,
    max_depth: ?u32 = null,
    ponder: bool = false,
    wtime: ?u64 = null,
    btime: ?u64 = null,
    winc: ?u32 = null,
    binc: ?u32 = null,
    movestogo: ?u32 = null,
    movetime: ?u64 = null,
    mate: ?u32 = null,
    infinite: bool = false,
    printout: bool = true,

    pub fn new() SearchManager {
        return SearchManager{
            .termination = Termination.INFINITE,
            .max_ms = 1000,
            .early_ms = 1000,
            .max_nodes = null,
            .ponder = false,
            .wtime = null,
            .btime = null,
            .winc = null,
            .binc = null,
            .movestogo = null,
            .movetime = null,
            .mate = null,
            .infinite = false,
            .printout = true,
        };
    }

    // Configures the search based on UCI options and the current position.
    pub fn configure(self: *SearchManager, pos: *Position) void {
        var rem_time: ?u64 = null;
        var rem_enemy_time: ?u64 = null;
        var time_inc: ?u32 = null;

        if (self.infinite) {
            self.termination = Termination.INFINITE;
        } else if (self.max_depth) |_| {
            self.termination = Termination.DEPTH;
        } else if (self.max_nodes) |_| {
            self.termination = Termination.NODES;
        } else if (self.mate) |m| {
            self.max_depth = m * 2; // Example: mate in N moves requires ~2N plies
            self.termination = Termination.MATE;
        }

        if (self.movetime) |_| {
            self.termination = Termination.MOVETIME;
        }
        if (self.movestogo) |_| {
            self.termination = Termination.TIME;
        }
        if (self.wtime) |wt| {
            self.termination = Termination.TIME;
            if (pos.side_to_play == Color.White) {
                rem_time = wt;
            } else {
                rem_enemy_time = wt;
            }
        }
        if (self.btime) |bt| {
            self.termination = Termination.TIME;
            if (pos.side_to_play == Color.Black) {
                rem_time = bt;
            } else {
                rem_enemy_time = bt;
            }
        }
        if (self.winc) |wi| {
            if (pos.side_to_play == Color.White) time_inc = wi;
        }
        if (self.binc) |bi| {
            if (pos.side_to_play == Color.Black) time_inc = bi;
        }

        self.set_time_limits(self.movestogo, self.movetime, rem_time, time_inc);
    }

    // Sets the time limits (max_ms, early_ms) for the search based on the time control.
    // max_ms is for hard limit, and early_ms is for soft limit.
    pub fn set_time_limits(self: *SearchManager, movestogo: ?u32, movetime: ?u64, rem_time: ?u64, time_inc: ?u32) void {
        const overhead: u32 = 10;

        if (self.termination == Termination.INFINITE or
            self.termination == Termination.DEPTH or
            self.termination == Termination.NODES or
            self.termination == Termination.MATE)
        {
            self.max_ms = 1 << 63;
            self.early_ms = self.max_ms;
        } else if (self.termination == Termination.TIME or self.termination == Termination.MOVETIME) {
            if (movetime) |mt| {
                self.max_ms = if (mt > overhead) mt - @as(u64, @intCast(overhead)) else 1;
                self.early_ms = self.max_ms;
                return;
            } else if (rem_time) |rt| {
                const inc: u32 = if (time_inc) |ti| ti else 0;
                const mtg: u32 = if (movestogo) |mg| @min(mg, 50) else 50;
                var adjusted_time = rt;
                if (inc > overhead) {
                    adjusted_time += @as(u64, @intCast(mtg * (inc - overhead)));
                }
                if (adjusted_time <= overhead) {
                    self.max_ms = @max(2, overhead - 2);
                    self.early_ms = self.max_ms;
                    return;
                }
                if (movestogo == null) {
                    const scale_div: u64 = 40;
                    self.early_ms = @min(@divTrunc(adjusted_time, scale_div), @divTrunc(rt, 5));
                    self.max_ms = @min(5 * self.early_ms, @divTrunc(4 * rt, 5));
                } else {
                    self.early_ms = @min(@divTrunc(7 * adjusted_time, 10 * mtg), @divTrunc(4 * rt, 5));
                    self.max_ms = @min(5 * self.early_ms, @divTrunc(4 * rt, 5));
                }
                return;
            } else {
                self.max_ms = 1 << 63;
                self.early_ms = self.max_ms;
                return;
            }
        } else {
            self.max_ms = 1 << 63;
            self.early_ms = self.max_ms;
        }
    }
};

// Stores state information for a single node in the search tree.
// TODO: since NodeState is array of MAX_PLY, you could actually put all arrays of MAX_PLY in search struct into this NodeState struct.
pub const NodeState = struct {
    eval: i32 = undefined,
    reduction: i8 = 0,
    is_null: bool = false,
    is_noisy: bool = false,
    move: Move = Move.empty(),
    piece: Piece = Piece.NO_PIECE,
    cont_hist_entry: ?*[position.NPIECES][64]i32 = null,
};

// The main search structure, containing all state needed for a search instance.
pub const Search = struct {
    best_move: Move = undefined,
    stop_on_time: bool = false,
    stop: bool = false,
    timer: compat_timer.Timer = undefined,
    max_depth: u32 = MAX_DEPTH - 1,
    nodes: u64 = 0,
    ply: u16 = 0,
    seldepth: u16 = 0,
    tbhits: u64 = 0,
    root_score: i32 = 0,

    // Principal Variation (PV) tables.
    pv_length: [MAX_PLY]u16 = undefined,
    pv_table: [MAX_PLY][MAX_PLY]Move = undefined,

    mv_killer: [MAX_PLY + 1][2]Move = undefined, // Killer moves for each ply.
    excluded: [MAX_PLY + 1]Move = undefined, // Move to exclude in singular search.
    dextension: [MAX_PLY + 1]i8 = undefined, // Double extension count per ply.
    mv_counter: [position.NPIECES][64]Move = undefined, // Countermove for a given piece and square.
    sc_history: [2][2][2][64][64]i32 = undefined, // Main history heuristic table [color][threat_from][threat_to][from][to].
    sc_hist_table: [position.NPIECES][64][position.NPIECES][64]i32 = undefined, // Continuation history table [parent_piece][parent_to][piece][to].
    // Static Evaluation Correction History tables.
    pawn_corr: [history.CORRHIST_SIZE][2]i16 = undefined,
    major_corr: [history.CORRHIST_SIZE][2]i16 = undefined,
    minor_corr: [history.CORRHIST_SIZE][2]i16 = undefined,
    white_non_pawn_corr: [history.CORRHIST_SIZE][2]i16 = undefined,
    black_non_pawn_corr: [history.CORRHIST_SIZE][2]i16 = undefined,
    cont_corr: [2][position.NPIECE_TYPES + 1][position.NPIECE_TYPES + 1]i16 = undefined,
    opp_move_corr: [2][64][64]i16 = undefined,
    capt_history: [position.NPIECE_TYPES + 1][2][2][64][position.NPIECE_TYPES + 1]i16 = undefined,

    ns_stack: [MAX_PLY + 4]NodeState = undefined,

    manager: SearchManager = undefined,

    non_terminal_nodes: u64 = 0,

    // Per-thread identifiers for Lazy SMP diversification
    thread_id: u8 = 0,
    seed: u32 = 0,

    pub fn new() Search {
        return Search{};
    }

    // Prints a move in UCI format, handling Chess960 castling.
    fn print_uci_move(self: *Search, pos: *Position, mv: Move, side: Color) void {
        _ = self;
        // Fast-path: check castling flag first; only then consider 960 formatting
        if ((mv.flags == MoveFlags.OO or mv.flags == MoveFlags.OOO) and uci.is_chess960() and pos.is_chess960) {
            const ci = side.toU4();
            const rook_sq = if (mv.flags == MoveFlags.OO)
                pos.castle_rook_k_start[ci]
            else
                pos.castle_rook_q_start[ci];
            if (rook_sq != Square.NO_SQUARE) {
                const k_from = position.sq_to_coord[mv.from];
                const r_from = position.sq_to_coord[rook_sq.toU()];
                printout(uci.stdout, "{s}{s} ", .{ k_from, r_from });
                return;
            }
        }
        const repr = mv.to_str();
        const s = if (mv.is_promotion()) repr[0..5] else repr[0..4];
        printout(uci.stdout, "{s} ", .{s});
    }

    // Clears the Principal Variation (PV) table.
    fn clear_pv_table(self: *Search) void {
        for (0..MAX_PLY) |i| {
            for (0..MAX_PLY) |j| {
                self.pv_table[i][j] = Move.empty();
            }
            self.pv_length[i] = 0;
        }
    }

    // Clears the killer move table.
    fn clear_mv_killer(self: *Search) void {
        for (0..(MAX_PLY + 1)) |i| {
            self.mv_killer[i][0] = Move.empty();
            self.mv_killer[i][1] = Move.empty();
        }
    }

    // Clears the countermove table.
    fn clear_mv_counter(self: *Search) void {
        @memset(std.mem.asBytes(&self.mv_counter), 0);
    }

    // Clears the main history heuristic table.
    fn clear_sc_history(self: *Search) void {
        @memset(std.mem.asBytes(&self.sc_history), 0);
    }

    // Clears all static evaluation correction history tables.
    fn clear_corr_history(self: *Search) void {
        @memset(std.mem.asBytes(&self.pawn_corr), 0);
        @memset(std.mem.asBytes(&self.major_corr), 0);
        @memset(std.mem.asBytes(&self.minor_corr), 0);
        @memset(std.mem.asBytes(&self.white_non_pawn_corr), 0);
        @memset(std.mem.asBytes(&self.black_non_pawn_corr), 0);
        @memset(std.mem.asBytes(&self.cont_corr), 0);
        @memset(std.mem.asBytes(&self.opp_move_corr), 0);
        @memset(std.mem.asBytes(&self.capt_history), 0);
    }

    // Ages the history scores by dividing them by two. This gives more weight to recent information.
    // TODO: test a stronger decay
    fn age_sc_history(self: *Search) void {
        for (0..2) |side| {
            for (0..2) |threat_from| {
                for (0..2) |threat_to| {
                    for (0..64) |sq1| {
                        for (0..64) |sq2| {
                            self.sc_history[side][threat_from][threat_to][sq1][sq2] = @divTrunc(self.sc_history[side][threat_from][threat_to][sq1][sq2], 2);
                        }
                    }
                }
            }
        }
    }

    // Clears the continuation history table.
    fn clear_sc_follow_table(self: *Search) void {
        @memset(std.mem.asBytes(&self.sc_hist_table), 0);
    }

    // Clears the node state stack.
    fn clear_node_state_stack(self: *Search) void {
        for (0..(MAX_PLY + 4)) |i| {
            self.ns_stack[i].eval = 0;
            self.ns_stack[i].reduction = 0;
            self.ns_stack[i].is_null = false;
            self.ns_stack[i].is_noisy = false;
            self.ns_stack[i].move = Move.empty();
            self.ns_stack[i].piece = Piece.NO_PIECE;
            self.ns_stack[i].cont_hist_entry = null;
        }
    }

    // Gets the score from the main history table.
    pub fn get_sh(self: *Search, color: u4, threat_from: usize, threat_to: usize, move_from: u6, move_to: u6) i32 {
        return (&self.sc_history)[color][threat_from][threat_to][move_from][move_to];
    }

    // Gets the score from the continuation history table.
    pub fn get_ch(self: *Search, p_piece: u4, parent_to: u6, piece: u4, move_to: u6) i32 {
        return (&self.sc_hist_table)[p_piece][parent_to][piece][move_to];
    }

    pub inline fn continuation_entry(self: *Search, comptime offset: usize) ?*[position.NPIECES][64]i32 {
        if (self.ply < offset) return null;
        return self.ns_stack[self.ply - offset].cont_hist_entry;
    }

    pub inline fn set_current_node_move(self: *Search, move: Move, piece: Piece, is_noisy: bool) void {
        self.ns_stack[self.ply].is_null = false;
        self.ns_stack[self.ply].is_noisy = is_noisy;
        self.ns_stack[self.ply].reduction = 0;
        self.ns_stack[self.ply].move = move;
        self.ns_stack[self.ply].piece = piece;
        self.ns_stack[self.ply].cont_hist_entry = &self.sc_hist_table[piece.toU4()][move.to];
    }

    pub inline fn set_current_node_null(self: *Search) void {
        self.ns_stack[self.ply].is_null = true;
        self.ns_stack[self.ply].is_noisy = false;
        self.ns_stack[self.ply].reduction = 0;
        self.ns_stack[self.ply].move = Move.empty();
        self.ns_stack[self.ply].piece = Piece.NO_PIECE;
        self.ns_stack[self.ply].cont_hist_entry = null;
    }

    // Resets all search-related tables and states for a new game.
    pub fn clear_for_new_game(self: *Search) void {
        self.clear_pv_table();
        self.clear_mv_killer();
        self.clear_mv_counter();
        self.clear_sc_history();
        self.clear_node_state_stack();
        self.clear_sc_follow_table();
        self.clear_corr_history();

        self.best_move = Move.empty();
        self.stop_on_time = false;
        self.stop = false;

        self.nodes = 0;
        self.non_terminal_nodes = 0;
        self.ply = 0;
        self.max_depth = MAX_DEPTH - 1;
        self.seldepth = 0;
        self.tbhits = 0;
    }

    // Resets the state for a new search
    pub fn clear_for_new_search(self: *Search) void {
        // self.age_sc_history();
        self.clear_mv_killer();
        self.clear_mv_counter();

        self.best_move = Move.empty();
        self.stop_on_time = false;
        self.stop = false;

        self.nodes = 0;
        self.non_terminal_nodes = 0;
        self.ply = 0;
        self.tbhits = 0;
    }

    // Checks for search termination conditions like stop command, node limits, or time limits.
    pub fn check_stop_conditions(self: *Search) bool {
        if (self.stop) return true;

        if (self.manager.termination == Termination.INFINITE) {
            return false;
        }

        if (self.manager.termination == Termination.NODES and self.nodes >= self.manager.max_nodes.?) {
            self.stop = true;
            return true;
        }

        if ((self.nodes & 1023 == 0) and (self.timer.read() / std.time.ns_per_ms >= self.manager.max_ms)) {
            self.stop = true;
            self.stop_on_time = true;
            return true;
        }

        return false;
    }

    // Checks for early termination based on time management heuristics.
    // This allows the engine to stop searching earlier if the position seems stable or improving with each new searched depth.
    pub fn check_early_stop_conditions(self: *Search, pos: *Position, stability: u8, improving: i16) bool {
        if (self.stop) return true;

        var early_adjusted_ms = self.manager.early_ms;

        if (self.manager.termination == Termination.TIME) {
            // Adjust the thinking time based on search stability and evaluation trends.
            // - 'stability': If the best move hasn't changed for several depths, the search is stable.
            //   We can reduce thinking time.
            // - 'improving': If the evaluation is getting better for us, we might be confident and can
            //   reduce time. If it's getting worse, we should think longer to find a defense.
            var factor: f32 = 1.0 - 0.02 * @as(f32, @floatFromInt(stability)) - 0.04 * @as(f32, @floatFromInt(improving));
            // Clamp the factor to a reasonable range [0.5, 1.25] to avoid extreme adjustments.
            factor = @max(0.5, @min(1.25, factor));

            // Further adjust the time factor based on the game phase.
            // In the endgame (low material), we should generally think longer.
            // In early phases the game is mostly equal and open, so we can save time for thinking longer in the endgame.
            var factor_ph: f32 = 1.0;
            const phase = @as(f32, @floatFromInt(pos.eval.phase[0] + pos.eval.phase[1]));
            const fac_min: f32 = 0.6; // Minimum factor
            const ph_min: f32 = 52; // Phase value threshold to start applying the endgame factor.
            const k: f32 = (fac_min - 1.0) / (64.0 - ph_min); // Slope of the linear interpolation.
            const n = 1.0 - k * ph_min; // y-intercept of the linear interpolation.
            factor_ph = k * phase + n; // Calculate the phase factor using y = kx + n.
            factor_ph = @max(fac_min, @min(1.0, factor_ph)); // Clamp the phase factor.
            factor *= factor_ph; // Apply the phase adjustment to the main factor.

            // Apply the final calculated factor to the early stop time.
            early_adjusted_ms = @as(u64, @intFromFloat(@as(f32, @floatFromInt(early_adjusted_ms)) * factor));

            if ((self.timer.read() / std.time.ns_per_ms) >= early_adjusted_ms) {
                return true;
            }
        } else if (self.manager.termination == Termination.NODES) {
            if (self.nodes >= self.manager.max_nodes.?) {
                return true;
            }
        }

        return false;
    }

    // The main iterative deepening loop.
    // It performs a series of searches with increasing depth, using aspiration windows
    // to narrow the search range around the score from the previous iteration.
    pub fn iterative_deepening(self: *Search, pos: *Position, comptime color: Color) void {
        //const allocator = std.heap.c_allocator;

        self.clear_for_new_search();
        pos.history[pos.game_ply].accumulator = nnue.refresh_accumulator(pos);
        pos.history[pos.game_ply].accumulator.eval = nnue.evaluate(pos.history[pos.game_ply].accumulator, color);
        pos.history[pos.game_ply].accumulator.computed_score = true;

        var alpha: i32 = -MAX_SCORE;
        var beta: i32 = MAX_SCORE;
        var score: i32 = 0;
        var delta: i32 = 16;

        var it_depth: i8 = 1;
        var depth = it_depth;
        var fails: i8 = 0;

        var stability_counter: u8 = 0;
        var improving: i16 = 0;
        var prev_best_move: Move = Move.empty();
        var prev_score = score;
        var prev_non_terminal_nodes: u64 = 0;

        self.timer = compat_timer.Timer.start() catch |err| {
            std.debug.print("Warning: Timer failed to start: {any}\n", .{err});
            return;
        };

        const start = Instant.now() catch |err| {
            std.debug.print("Warning: Timer failed to start: {any}\n", .{err});
            return;
        };
        self.nodes = 0;
        self.non_terminal_nodes = 0;

        // Main search loop, increasing depth with each iteration.
        mainloop: while (it_depth <= self.max_depth) {
            self.ply = 0;
            self.seldepth = 0;
            //self.nodes = 0;
            depth = it_depth;
            fails = 0;
            if (depth >= 4) {
                delta = 12;
            } else {
                delta = MAX_SCORE;
            }

            alpha = @max(-MAX_SCORE, score - delta);
            beta = @min(score + delta, MAX_SCORE);

            //const start = Instant.now() catch unreachable;

            // Aspiration window loop.
            aspirationloop: while (delta <= MAX_SCORE) {
                var reduced_depth: i8 = depth - @divTrunc(fails, 2);
                if (reduced_depth < 1) {
                    reduced_depth = 1;
                }
                score = self.pvs(reduced_depth, alpha, beta, pos, false, color);

                if (self.stop) {
                    break :mainloop;
                }

                self.best_move = self.pv_table[0][0];
                self.root_score = score;

                delta += 2 + @divTrunc(delta, 2);

                if (@abs(score) > 2000) {
                    delta = MAX_SCORE;
                }

                // If the score falls outside the window, adjust the window and re-search.
                if (score <= alpha) {
                    beta = @divTrunc(alpha + beta, 2);
                    alpha = @max(-MAX_SCORE, score - delta);
                } else if (score >= beta) {
                    beta = @min(score + delta, MAX_SCORE);
                    // If the score is within the window, the search for this depth is successful.
                    fails += 1;
                } else {
                    break :aspirationloop;
                }

                if (delta > 500) {
                    delta = MAX_SCORE;
                }
            }

            // Update stability and improving metrics for time management.
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

            // Print UCI info string for the completed depth.
            if (self.manager.printout) {
                var nodes = self.nodes;
                var tbhits = self.tbhits;
                for (1..uci.num_threads) |i| {
                    nodes += uci.thinkers[i].nodes;
                    tbhits += uci.thinkers[i].tbhits;
                }
                const now = Instant.now() catch |err| {
                    std.debug.print("Warning: Timer failed to start: {any}\n", .{err});
                    return;
                };
                const time_elapsed = now.since(start);
                const elapsed_nanos = @as(f64, @floatFromInt(time_elapsed));
                const elapsed_seconds = elapsed_nanos / 1_000_000_000;
                const elapsed_ms: u32 = @intFromFloat(elapsed_nanos / 1_000_000);
                const nps: u46 = @intFromFloat(@as(f64, @floatFromInt(nodes)) / elapsed_seconds);

                const ebf: f32 = if (it_depth > 1 and prev_non_terminal_nodes > 0)
                    @as(f32, @floatFromInt(self.non_terminal_nodes)) / @as(f32, @floatFromInt(prev_non_terminal_nodes))
                else
                    0.0;

                const est_hash_full = tt.TT.hash_full();

                printout(uci.stdout, "info depth {} seldepth {} score ", .{ it_depth, self.seldepth });
                if (_is_mate_score(score)) {
                    printout(uci.stdout, "mate {} ", .{_mate_in(score)});
                } else {
                    printout(uci.stdout, "cp {} ", .{score});
                }
                printout(uci.stdout, "nodes {} nps {d} time {d} hashfull {d} ebf {d:.2} ", .{ self.nodes, nps, elapsed_ms, est_hash_full, ebf });
                if (use_tb and self.thread_id == 0) {
                    printout(uci.stdout, "tbhits {d} ", .{tbhits});
                }
                printout(uci.stdout, "pv ", .{});

                var next_ply: usize = 0;
                var pv_side = color;
                var pv_pos = pos.copy();
                while (!self.pv_table[0][next_ply].is_empty() and next_ply < self.pv_length[0]) : (next_ply += 1) {
                    // Avoid printing PV moves that continue past a repeatable draw node.
                    if (pv_pos.upcoming_repetition()) break;

                    const pv_move = self.pv_table[0][next_ply];
                    self.print_uci_move(&pv_pos, pv_move, pv_side);
                    if (pv_side == Color.White) {
                        pv_pos.play(pv_move, Color.White);
                    } else {
                        pv_pos.play(pv_move, Color.Black);
                    }
                    pv_side = pv_side.change_side();
                }

                printout(uci.stdout, "\n", .{});
            }

            if (self.stop or self.check_early_stop_conditions(pos, stability_counter, improving)) {
                self.stop = true;
                break :mainloop;
            }

            prev_non_terminal_nodes = self.non_terminal_nodes;

            it_depth += 1;
        }

        // If no best move was found (e.g., search stopped early), pick the first legal move.
        // Safety fallback
        if (self.best_move.is_empty()) {
            var move_list: MoveList = .{};
            const me = if (color == Color.White) Color.White else Color.Black;
            const ctx = pos.computeMoveGenContext(me);
            pos.generate_legals_from_ctx(me, ctx, &move_list);
            var score_list: MoveScoreList = .{};
            ms.score_move(pos, self, ctx.danger, &move_list, &score_list, Move.empty(), me);
            self.best_move = ms.get_next_best(&score_list, 0);
        }

        // Print the final 'bestmove' UCI command.
        if (self.manager.printout) {
            // Print bestmove: check castling flag first, then 960 formatting
            // TODO: not very happy with this part, it is correct, but could probably be streamlined a bit
            if ((self.best_move.flags == MoveFlags.OO or self.best_move.flags == MoveFlags.OOO) and uci.is_chess960() and pos.is_chess960) {
                const ci = color.toU4();
                const rook_sq = if (self.best_move.flags == MoveFlags.OO)
                    pos.castle_rook_k_start[ci]
                else
                    pos.castle_rook_q_start[ci];
                if (rook_sq != Square.NO_SQUARE) {
                    const k_from = position.sq_to_coord[self.best_move.from];
                    const r_from = position.sq_to_coord[rook_sq.toU()];
                    printout(uci.stdout, "bestmove {s}{s}\n", .{ k_from, r_from });
                } else {
                    const repr = self.best_move.to_str();
                    const move_name = if (self.best_move.is_promotion()) repr[0..5] else repr[0..4];
                    printout(uci.stdout, "bestmove {s}\n", .{move_name});
                }
            } else {
                const repr = self.best_move.to_str();
                const move_name = if (self.best_move.is_promotion()) repr[0..5] else repr[0..4];
                printout(uci.stdout, "bestmove {s}\n", .{move_name});
            }
        }
    }

    // The iterative deepening loop for worker threads in a parallel search.
    pub fn iterative_deepening_thread(self: *Search, pos: *Position, _delta: i32, comptime color: Color) void {
        self.clear_for_new_search();
        pos.history[pos.game_ply].accumulator = nnue.refresh_accumulator(pos);
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

    // Principal Variation Search (PVS), also known as NegaScout.
    // This is the core recursive function of the chess engine's search algorithm. It's an
    // enhancement of the alpha-beta algorithm that achieves faster cutoffs by making the
    // assumption that the first move is the best (part of the Principal Variation).
    //
    // The function first searches the best move (from the transposition table or move ordering)
    // with a full (alpha, beta) window. All subsequent moves are then searched with a minimal
    // "null" window (`-alpha - 1`, `-alpha`). If any of these null-window searches return a
    // score greater than alpha, it means the move is better than any found so far, and it
    // must be re-searched with the full window to get an accurate score.
    //
    // This function integrates numerous search techniques, including:
    // - Transposition Table (TT) lookups to reuse previous calculations.
    // - Endgame Tablebase (TB) probing for perfect play in endgames.
    // - Quiescence search to stabilize the evaluation at leaf nodes.
    // - Pruning techniques: Null Move Pruning (NMP), Razoring, Futility Pruning, Late Move Pruning (LMP), SEE pruning.
    // - Search extensions: Check extensions, Singular extensions.
    // - Late Move Reductions (LMR) to reduce the search depth of less promising moves.
    //
    // @param _depth The remaining depth to search.
    // @param _alpha The lower bound of the search window (alpha).
    // @param _beta The upper bound of the search window (beta).
    // @param pos The current board position.
    // @param cutnode A flag indicating if this is a "cut-node" (a node where a beta-cutoff is likely).
    // @param color The side to move.
    pub fn pvs(self: *Search, _depth: i8, _alpha: i32, _beta: i32, pos: *Position, cutnode: bool, comptime color: Color) i32 {
        const prev_nnue_context = nnue.set_search_context(.main_search);
        defer _ = nnue.set_search_context(prev_nnue_context);
        const prev_nnue_depth = nnue.set_search_depth(_depth);
        defer _ = nnue.set_search_depth(prev_nnue_depth);
        const opp = color.change_side();
        const me = color;

        var depth = _depth;
        const qsearch: bool = if (_depth <= 0) true else false;
        const is_root: bool = if (self.ply == 0) true else false;
        const in_check = pos.in_check(me);
        const tuned = search_params.params;
        var full_search: bool = false;

        var alpha: i32 = _alpha;
        const beta: i32 = _beta;
        const is_pv: bool = if (alpha != beta - 1) true else false;
        const prev_nnue_pv = nnue.set_pv_node(is_pv);
        defer _ = nnue.set_pv_node(prev_nnue_pv);
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

        // --- Initialization and Termination Checks ---
        self.pv_length[self.ply] = 0;
        self.seldepth = @max(self.ply, self.seldepth);
        //self.nodes += 1;

        if (self.check_stop_conditions()) {
            self.stop_on_time = true;
            return 0;
        }

        // Check for draw conditions (repetitions, 50-move rule).
        if (!is_root) {
            // Repetition is a terminal draw in non-root nodes.
            if (pos.upcoming_repetition()) return 0;

            if (pos.is_draw()) return 0;

            if (self.ply >= MAX_PLY) {
                if (in_check) return 0 else return pos.eval.eval(pos, me);
            }

            // Mate Distance Pruning
            r_alpha = @max(alpha, -MATE_VALUE + @as(i32, self.ply));
            r_beta = @min(beta, MATE_VALUE - @as(i32, self.ply) + 1);

            if (r_alpha >= r_beta) return r_alpha;
        }

        // --- Transposition Table (TT) Lookup ---
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

            // TTCUT-1 result: disabling the main TT cutoff block lost about
            // 78.82 +/- 10.21 Elo in a 2+0.02 test, so this is one of the
            // strongest core search mechanisms measured so far.
            if ((!is_pv or depth == 0) and tt_depth >= depth) {
                if (tt_bound == tt.Bound.BOUND_EXACT or
                    (tt_bound == tt.Bound.BOUND_LOWER and tt_score >= beta) or
                    (tt_bound == tt.Bound.BOUND_UPPER and tt_score <= alpha))
                {
                    return tt_score;
                }
            }

            // TTUB-1 result: disabling the TT upper-bound alpha shortcut scored
            // -2.30 +/- 4.75 Elo in an 8000-game 2+0.02 test, so it looks tiny
            // or insignificant as a standalone feature in the current engine.
            if (!is_pv and (tt_depth >= depth - 1) and (tt_bound == tt.Bound.BOUND_UPPER) and (tt_score + 140 <= alpha)) {
                return tt_score;
            }

            // TTMO-1 / TTMO-MAIN-1 result: disabling TT move ordering lost about
            // 115-125 Elo across current confirmation runs, and almost all of that
            // comes from the main-search TT ordering hint rather than qsearch.
        }

        // --- Endgame Tablebase (TB) Probing ---
        if (use_tb and self.thread_id == 0) {
            if (!is_root and !skip_move) {
                const wdl_result = fathom.probeWDL(pos, depth);
                if ((wdl_result >= 0) and (wdl_result <= 4)) {
                    tt.TT.prefetch_write(pos.hash);
                    self.tbhits += 1;
                    //self.new_tbhits += 1;

                    var tb_bound = tt.Bound.BOUND_NONE;
                    var tb_score: i32 = -MATE_VALUE;
                    if (wdl_result == 2) { // Draw
                        tb_score = 0;
                        tb_bound = tt.Bound.BOUND_EXACT;
                    }

                    if ((tb_bound == tt.Bound.BOUND_LOWER and tb_score >= beta) or
                        (tb_bound == tt.Bound.BOUND_UPPER and tb_score <= alpha) or
                        (tb_bound == tt.Bound.BOUND_EXACT))
                    {
                        tt.TT.store(tt.scoreEntry.new(pos.hash, Move.empty(), tb_score, tb_bound, MAX_DEPTH, tt.TT.age));
                        return tb_score;
                    }
                }
            }
        }

        // IID-1 result: disabling internal iterative deepening scored about
        // -9.89 +/- 5.80 Elo in a 2+0.02 test, so it looks useful but modest
        // compared with the strongest pruning and extension features here.
        if (depth >= 4 and tt_bound == tt.Bound.BOUND_NONE and !is_root) {
            depth -= 1;
        }

        // --- Static Evaluation and Pruning Heuristics ---
        var static_eval = pos.eval.eval(pos, me) + history.get_correction(self, pos);
        static_eval = pos.eval.adjust_eval(pos, static_eval);
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

        // Check if evaluation is improving, which can affect pruning decisions.
        var improving: u1 = 0;
        if (!in_check) {
            if (self.ply >= 4 and static_eval > self.ns_stack[self.ply - 4].eval) {
                improving = 1;
            } else if (self.ply >= 2 and static_eval > self.ns_stack[self.ply - 2].eval) {
                improving = 1;
            }
        }

        if (!in_check and !is_pv and !skip_move) {
            // RZ-1 result: disabling razoring scored -10.65 +/- 5.71 Elo in a 2+0.02 test,
            // so it looks like a modest but real search feature in the current engine.
            const razor_margin = tuned.razor_margin_offset + @as(i32, @intCast(improving)) * tuned.razor_margin_scale;
            if (depth <= tuned.razor_depth and static_eval + razor_margin <= alpha) {
                const raz_score = self.quiescence(alpha, beta, pos, depth, me);
                if (raz_score <= alpha) return raz_score;
            }

            // RFP-1 result: disabling reverse futility pruning lost about
            // 72.60 +/- 12.57 Elo in a 2+0.02 test, so this is one of the
            // strongest non-qsearch pruning features measured so far.
            if ((depth <= tuned.futility_prune_depth) and ((best_score - tuned.futility_prune_slope * (@as(i32, @intCast(depth)) - improving)) >= beta)) {
                return best_score;
            }

            // NMP-1 result: disabling null move pruning lost about 36.22 +/- 8.20 Elo
            // in a 2+0.02 test, so this is one of the stronger search features measured so far.
            //
            // RT-13 result: making the beta-based extra reduction slightly less aggressive
            // by raising NullMoveBetaDiv looked near-neutral to slightly worse, so there
            // is no evidence that baseline is too aggressive on that side.
            //
            // RT-14 result: making the beta-based extra reduction slightly more aggressive
            // by lowering NullMoveBetaDiv also looked near-neutral, so that term seems
            // locally flat around the current baseline.
            //
            // RT-15 result: making the base null-move reduction slightly more aggressive
            // through NullMoveBase looked worse than baseline, so that direction does
            // not appear promising.
            //
            // RT-16 result: making the base null-move reduction slightly less aggressive
            // also looked worse than baseline in the reported run, so baseline is kept.
            if (static_eval >= beta and !is_null and depth >= tuned.null_move_min_depth and (pos.eval.phase[me.toU4()] > 0) and (!tt_hit or !(tt_bound == tt.Bound.BOUND_UPPER) or tt_score >= beta)) {
                var R: i8 = tuned.null_move_base + @divTrunc(depth, tuned.null_move_depth_divisor);
                const beta_term = @divTrunc(static_eval - beta, tuned.null_move_beta_divisor);
                if (beta_term > 0) {
                    R += @intCast(@min(3, beta_term));
                }
                R += if (self.ns_stack[self.ply - 1].is_noisy) 1 else 0;

                // make null move
                self.set_current_node_null();
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
                    var verified = true;

                    // Verification search for low material endgames.
                    if (pos.eval.phase[me.toU4()] < tuned.null_move_verify_phase and depth < tuned.null_move_verify_depth) {
                        const verification_depth = depth - R - 2;
                        if (verification_depth > 0) {
                            const v_score = self.pvs(verification_depth, beta - 1, beta, pos, false, me);
                            if (v_score < beta) {
                                verified = false;
                            }
                        }
                    }

                    if (verified) return score; // Prune
                }
            }
        }

        // --- Move Generation and Iteration ---
        best_score = -MATE_VALUE + @as(i32, self.ply);
        var best_move = Move.empty();

        const ctx = pos.computeMoveGenContext(me);
        const opp_threats = ctx.danger;
        const continuations = history.make_search_continuations(self);
        const counter_move = history.get_counter_move(self);

        // RT-4 result: restricting TT move ordering to exact/lower-bound entries
        // scored about -27.57 +/- 20.32 Elo, so baseline keeps using upper-bound
        // TT entries as ordering hints too.
        //
        // RT-23 result: requiring a reasonably fresh TT depth for the main-search
        // hash move looked somewhat worse than baseline, so broad TT move usage is kept.
        //
        // RT-24 result: differentiating main-search TT move ordering by bound
        // looked worse than baseline, so the current uniform top TT move priority
        // is kept while TT experiments move to the storage/replacement side.
        const use_staged_picker = !in_check;
        var picker: MainMovePicker = undefined;
        picker.init(self, pos, ctx, tt_move, counter_move, use_staged_picker, in_check, me);

        if (picker.empty_full_list()) {
            return if (in_check) -MATE_VALUE + @as(i32, self.ply) else 0;
        }

        self.mv_killer[self.ply + 1][0] = Move.empty();
        self.mv_killer[self.ply + 1][1] = Move.empty();
        self.excluded[self.ply + 1] = Move.empty();
        self.dextension[self.ply] = if (self.ply > 0) self.dextension[self.ply - 1] else 0;

        var quiet_list: MoveList = .{};
        var quet_mv_pieces: PieceList = .{};
        var noisy_list: MoveList = .{};
        var quiets_tried: u8 = 0;
        var played: u8 = 0;
        var saw_legal_move = false;
        var skip_quiets = false;
        const depth_i32 = depth_as_i32(depth);
        const lmp_limit_idx: usize = @min(10, @as(usize, @intCast(depth)));
        const lmp_limit = lmp[improving][lmp_limit_idx];
        const scaled_cm_limit = @divTrunc(cm_history_limit[improving] * tuned.history_limit_scale, 100);
        const scaled_cm_limit_deep = @divTrunc(cm_history_limit_deep[improving] * tuned.history_limit_scale, 100);

        while (true) {
            if (!skip_quiets and picker.at_quiet_batch() and !is_root and best_score > MATED_IN_MAX) {
                if (depth <= lmp_depth and quiets_tried >= lmp_limit) {
                    skip_quiets = true;
                }
            }
            if (skip_quiets) {
                picker.skip_remaining_quiets();
            }

            const picked = picker.next(self, pos, ctx, me) orelse break;
            const mv_idx = picked.index;
            const prev_nnue_move_index = nnue.set_move_index(mv_idx);
            const move = picked.move;
            const move_score = picked.score;

            if (!saw_legal_move) {
                saw_legal_move = true;
                self.non_terminal_nodes += 1;
            }

            if (move.equal(self.excluded[self.ply])) continue;

            const mv_quiet = move.is_quiet();
            const piece = pos.board[move.from];
            var sc_hist: i32 = 0;
            var cm_hist: i32 = 0;
            var full_hist: i32 = 0;
            if (mv_quiet) {
                const hist_scores = history.quiet_search_scores(self, opp_threats, me.toU4(), continuations, piece, move);
                sc_hist = hist_scores.sc_hist;
                cm_hist = hist_scores.cm_hist;
                full_hist = hist_scores.full_hist;
            }
            // --- Pruning based on move history and futility ---
            if (!is_root and best_score > MATED_IN_MAX) {
                if (mv_quiet) {
                    if (skip_quiets) continue;

                    // HP-1 result: disabling history-based quiet pruning cutoffs scored
                    // -1.48 +/- 4.65 Elo in an 8000-game 2+0.02 test, so these gates
                    // look tiny or insignificant as standalone search features here.
                    if (depth <= histroy_depth[improving] and cm_hist < scaled_cm_limit) {
                        continue;
                    }

                    if (depth <= histroy_depth_deep[improving] and cm_hist < scaled_cm_limit_deep) {
                        continue;
                    }

                    // FP-1 result: disabling the quiet-move futility skip scored
                    // -2.22 +/- 5.61 Elo in a 2+0.02 test, so it looks tiny or
                    // insignificant as a standalone feature in the current engine.
                    const futilityMargin = static_eval + tuned.futility_margin_slope * depth_i32;
                    if (futilityMargin <= alpha and depth <= tuned.futility_prune_depth and (sc_hist < futility_histroy_limit[improving])) {
                        skip_quiets = true;
                        picker.skip_remaining_quiets();
                        continue;
                    }

                    // LMP-1 result: disabling late move pruning lost about
                    // 17.19 +/- 9.38 Elo in a 2+0.02 test, so it looks useful
                    // but much smaller than LMR in the current engine.
                    if ((depth <= lmp_depth) and (quiets_tried >= lmp_limit)) {
                        skip_quiets = true;
                        picker.skip_remaining_quiets();
                    }
                }

                // MSEE-1 result: disabling main-search SEE pruning lost about
                // 42.65 +/- 8.49 Elo in a 2+0.02 test, so this is a strong
                // tactical/filtering feature in the current engine.
                //
                // RT-10 result: loosening only the quiet-move SEE threshold through
                // SeeQuietCoeff looked somewhat worse than baseline, so baseline is kept.
                //
                // RT-11 result: loosening only the capture SEE threshold through
                // SeeCaptureCoeff looked clearly worse than baseline, so baseline is not
                // too aggressive there.
                //
                // RT-12 result: tightening only the capture SEE threshold also looked
                // worse than baseline, so the current main-search SEE thresholds appear
                // reasonably well tuned locally.
                if (depth <= 8 and !in_check) {
                    const see_val: i32 = if (mv_quiet)
                        -(tuned.see_quiet_coeff * depth_i32)
                    else
                        -(tuned.see_capture_coeff * depth_i32 * depth_i32);
                    const see_ok = if (ms.score_implies_nonnegative_capture_see(move, move_score))
                        true
                    else
                        ms.see_ge(pos, move, see_val);
                    if (!see_ok) continue;
                }
            }

            if (mv_quiet) {
                quiets_tried += 1;
                quiet_list.append(move);
                quet_mv_pieces.append(piece);
            } else {
                noisy_list.append(move);
            }

            var new_depth = depth;

            // make move
            played += 1;
            self.set_current_node_move(move, piece, !mv_quiet);
            self.ply += 1;
            pos.play(move, me);
            tt.TT.prefetch(pos.hash);
            self.nodes += 1;
            // make move

            // CE-1 result: disabling the check extension scored about
            // -0.42 +/- 6.54 Elo at 2+0.02 and -4.67 +/- 10.20 Elo at 10+0.1,
            // so it looks tiny or insignificant as a standalone feature here.
            if (mv_quiet and depth <= 6 and pos.in_check(opp)) {
                new_depth += 1;
            }

            // Singular Extension Search
            // SE-1 result: disabling singular extensions lost about
            // 56-74 Elo in current tests, so this looks like one of the
            // stronger selective-search features in the engine.
            const singular: bool = !is_root and !skip_move and depth >= 8 and move.equal(tt_move) and tt_depth >= depth - 3 and tt_bound == tt.Bound.BOUND_LOWER and !_is_mate_score(tt_score);

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
                self.set_current_node_move(move, piece, !mv_quiet);
                self.ply += 1;
                pos.play(move, me);
                tt.TT.prefetch(pos.hash);
                // make move

                const double_extend = !is_pv and (score < r_beta - 10) and (self.dextension[self.ply] <= 6);

                if (double_extend) {
                    extension = 2;
                } else if (score < r_beta) {
                    extension = 1;
                } else if (score >= beta and !_is_mate_score(score)) {
                    // ideas: if the singular verification itself still fails high, keep
                    // the TT lower-bound result instead of forcing a normal search.
                    if (!in_check and score > static_eval) {
                        const singular_depth = @divTrunc(depth - 1, 2);
                        const bonus = std.math.clamp(@divTrunc((score - static_eval) * singular_depth, 4), -history.MULTICUT_CORR_LIMIT, history.MULTICUT_CORR_LIMIT);
                        history.update_multicut_corr(self, pos, bonus);
                    }
                    self.ply -= 1;
                    pos.undo(move, me);
                    tt.TT.prefetch_write(pos.hash);
                    _ = nnue.set_move_index(prev_nnue_move_index);
                    return score;
                } else if (tt_score >= beta or cutnode) {
                    extension = -2;
                } else if (tt_score <= alpha) {
                    extension = -1;
                } else {
                    extension = 0;
                }
            }

            new_depth += extension;

            if (extension > 1) {
                self.dextension[self.ply] += 1;
            }

            // --- Search the move (with reductions) ---
            var reduction: i8 = 0;
            if (mv_idx > 0 and depth > 2) {
                // LMR-1 result: disabling late move reductions lost about
                // 89.82 +/- 16.75 Elo in a 2+0.02 test, so LMR is one of the
                // strongest search features measured so far.
                if (mv_quiet) {
                    reduction = lmr[@as(usize, @intCast(@min(depth, MAX_DEPTH - 1)))][@as(usize, @intCast(@min(mv_idx + 1, MAX_MOVES - 1)))];

                    if (cutnode) reduction += 1;
                    if (improving == 0) reduction += 1;
                    if (is_pv) reduction -= 1;

                    if (!is_pv and depth <= 3 and piece.type_of() == PieceType.King and move.flags != MoveFlags.OO and move.flags != MoveFlags.OOO) {
                        reduction += 1;
                    }

                    if (move.equal(self.mv_killer[self.ply][0]) or move.equal(self.mv_killer[self.ply][1])) {
                        reduction -= 1;
                    }

                    if (depth >= 4 and move.equal(counter_move)) {
                        reduction -= 1;
                    }

                    reduction -= @as(i8, @intCast(@max(-4, @min(4, @divTrunc(full_hist, 4000)))));
                    reduction += @as(i8, @intCast(@min(2, @abs(@divTrunc(static_eval - alpha, tuned.reduction_eval_scale)))));
                }

                reduction = @min(new_depth - 1, @max(reduction, 1));
                self.ns_stack[self.ply].reduction = reduction;

                score = -self.pvs(new_depth - reduction, -alpha - 1, -alpha, pos, true, opp);

                full_search = (score > alpha) and (reduction != 1);
            } else {
                self.ns_stack[self.ply].reduction = 0;
                full_search = !is_pv or (played > 1);
            }

            // Re-search with a full window if the null-window search failed high.
            if (full_search) {
                score = -self.pvs(new_depth - 1, -alpha - 1, -alpha, pos, !cutnode, opp);
            }

            // Full PV search for the first move or if a previous move raised alpha.
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
                _ = nnue.set_move_index(prev_nnue_move_index);
                return 0;
            }

            // --- Update best move and alpha ---
            if (score > best_score) {
                best_score = score;

                if (score > alpha) {
                    best_move = move;
                    self.update_pv(move);

                    alpha = score;

                    // Beta cutoff: this move is too good, the opponent won't allow it.
                    if (alpha >= beta) {
                        // HUP-1 result: disabling history.update_all_history() on quiet beta
                        // cutoffs lost about 489.89 +/- 55.22 Elo, but this is a bundled
                        // result because the helper updates killer moves, countermoves, and
                        // continuation history in addition to the main quiet-history tables.
                        if (mv_quiet) {
                            history.update_all_history(self, opp_threats, move, quiet_list, quet_mv_pieces, depth, me);
                        }
                        // CHUP-1 result: disabling the capture-history update scored
                        // -1.77 +/- 5.50 Elo in a 2+0.02 test, so it looks tiny or
                        // insignificant as a standalone learning feature here.
                        history.update_capture_history(self, pos, opp_threats, move, noisy_list, depth);
                        _ = nnue.set_move_index(prev_nnue_move_index);
                        break;
                    }
                }
            }

            _ = nnue.set_move_index(prev_nnue_move_index);
        }

        if (!saw_legal_move and !in_check) {
            return 0;
        }

        // --- Store result in Transposition Table ---
        tt_bound = if (best_score >= beta) tt.Bound.BOUND_LOWER else if (alpha != _alpha) tt.Bound.BOUND_EXACT else tt.Bound.BOUND_UPPER;
        if (!skip_move) {
            // CORR-1 result: disabling correction-history updates lost about
            // 102.74 +/- 18.95 Elo in a 2+0.02 test, so this learned eval-correction
            // path is one of the strongest search-side learning features in the engine.
            if (!in_check and best_move.is_quiet() and !(tt_bound == tt.Bound.BOUND_LOWER and best_score <= static_eval) and !(tt_bound == tt.Bound.BOUND_UPPER and best_score >= static_eval)) {
                history.update_corr_history(self, pos, static_eval, best_score, depth);
            }

            tt.TT.store(tt.scoreEntry.new(pos.hash, best_move, tt.TT.to_hash_score(best_score, self.ply), tt_bound, depth, tt.TT.age));
        }

        return best_score;
    }

    // Quiescence search (q-search) to stabilize the evaluation at the search horizon.
    // In normal positions it searches only noisy moves, while in-check nodes search all legal evasions.
    //
    // Search-feature notes for Elo ablation work:
    // - TT qsearch cutoffs: Elo TBD
    // - Stand-pat static eval: Elo TBD
    // - Noisy-only move generation / check evasions: Elo TBD
    // - Delta pruning: Elo TBD
    // - SEE pruning: Elo TBD
    pub fn quiescence(self: *Search, _alpha: i32, _beta: i32, pos: *Position, depth: i8, comptime color: Color) i32 {
        const prev_nnue_context = nnue.set_search_context(.qsearch);
        defer _ = nnue.set_search_context(prev_nnue_context);
        const prev_nnue_depth = nnue.set_search_depth(depth);
        defer _ = nnue.set_search_depth(prev_nnue_depth);
        const opp = if (color == Color.White) Color.Black else Color.White;
        const me = if (color == Color.White) Color.White else Color.Black;
        const tuned = search_params.params;
        var alpha: i32 = @max(_alpha, -MATE_VALUE + @as(i32, self.ply));
        const beta: i32 = @min(_beta, MATE_VALUE - @as(i32, self.ply) + 1);
        const prev_nnue_pv = nnue.set_pv_node(alpha != beta - 1);
        defer _ = nnue.set_pv_node(prev_nnue_pv);
        var best_score: i32 = undefined;
        var score: i32 = undefined;
        const ctx = pos.computeMoveGenContext(me);
        const in_check = ctx.check_count > 0;

        self.pv_length[self.ply] = 0;
        self.seldepth = @max(self.ply, self.seldepth);

        if (alpha >= beta) return alpha;

        if (self.ply >= MAX_PLY) return pos.eval.eval(pos, me);

        if (self.check_stop_conditions()) {
            self.stop_on_time = true;
            return 0;
        }

        if (pos.is_draw()) return 0;

        var tt_move = Move.empty();
        var tt_score: i32 = 0;
        var tt_bound = tt.Bound.BOUND_NONE;
        const entry = tt.TT.fetch(pos.hash);

        // QS-3 result: disabling qsearch TT reuse/storage lost about 21 Elo in an isolated
        // 2+0.02 run, while earlier cumulative runs looked much larger. So qsearch TT is
        // clearly useful, but the clean standalone effect is more moderate than first thought.
        if (entry) |e| {
            tt_move = e.move;
            tt_bound = e.bound;
            tt_score = tt.TT.adjust_hash_score(e.score, self.ply);
            const tt_qs_covers = if (e.depth > 0) true else e.depth <= depth;

            if (tt_qs_covers and
                ((tt_bound == tt.Bound.BOUND_LOWER and tt_score >= beta) or
                    (tt_bound == tt.Bound.BOUND_UPPER and tt_score <= alpha) or
                    (tt_bound == tt.Bound.BOUND_EXACT)))
            {
                return tt_score;
            }

            // TTMO-QS-1 result: disabling only qsearch TT move ordering scored
            // -7.42 +/- 5.90 Elo in a 2+0.02 test, so qsearch TT ordering helps
            // a bit, but the large TT ordering effect overwhelmingly comes from
            // the main search.
        }

        // QS-2 note: fully removing stand-pat fail-high / alpha-raising made the engine
        // dramatically slower in bench mode, so that ablation should be revisited with
        // a narrower toggle or a different testing protocol.
        if (in_check) {
            if (nnue.engine_using_nnue and !pos.history[pos.game_ply].accumulator.computed_accumulation) {
                nnue.incremental_update(pos);
            }
            best_score = -MATE_VALUE + @as(i32, self.ply);
        } else {
            best_score = pos.eval.eval(pos, me) + history.get_correction(self, pos);
            best_score = pos.eval.adjust_eval(pos, best_score);

            if (best_score >= beta) return best_score;
            if (best_score > alpha) alpha = best_score;
        }

        var best_move = Move.empty();

        // QS-4 result: restricting quiet qsearch nodes to captures only lost about
        // 10.56 +/- 4.78 Elo, so quiet promotions contribute some strength but are
        // not among the largest qsearch features in this engine.
        var move_list: MoveList = .{};
        pos.generate_noisy_legals_from_ctx(me, ctx, &move_list);
        var score_list: MoveScoreList = .{};
        ms.score_noisy_moves(pos, self, ctx.danger, &move_list, &score_list, tt_move);

        // QS-7 result: disabling qsearch noisy move ordering scored -9.03 +/- 5.35 Elo,
        // so ordering matters, but much less than SEE pruning and likely less than TT.
        const delta_margin: i32 = tuned.qsearch_delta_margin;

        for (0..move_list.count) |mv_idx| {
            const prev_nnue_move_index = nnue.set_move_index(mv_idx);
            const move = ms.get_next_best(&score_list, mv_idx);
            const move_score = score_list.items[mv_idx].score;

            // QS-5 result: disabling delta pruning scored -1.74 +/- 5.97 Elo in 4000 games,
            // so its standalone impact looks small or insignificant so far.
            if (!in_check and move.is_capture()) {
                const captured = if (move.flags == MoveFlags.EN_PASSANT) 0 else pos.board[move.to].type_of().toU3();
                const piece_value = ms.piece_val[captured];
                if (best_score + piece_value + delta_margin < alpha) {
                    continue;
                }
            }

            // QS-6 result: disabling SEE pruning lost about 47-56 Elo in a near-isolated test,
            // so this is a major qsearch feature in the current engine.
            //
            // RT-9 result: loosening the qsearch SEE threshold from see_val < -1 to
            // see_val < -20 looked neutral in both fast and slower tests, so baseline
            // is kept for now.
            const see_ok = if (ms.score_implies_nonnegative_capture_see(move, move_score))
                true
            else
                ms.see_ge(pos, move, -1);

            if (!in_check and !see_ok) continue;

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

                    if (alpha >= beta) {
                        _ = nnue.set_move_index(prev_nnue_move_index);
                        break;
                    }
                }
            }

            _ = nnue.set_move_index(prev_nnue_move_index);
        }

        const tt_depth: i8 = @max(depth, -3);
        tt_bound = if (best_score >= beta) tt.Bound.BOUND_LOWER else if (best_score > _alpha) tt.Bound.BOUND_EXACT else tt.Bound.BOUND_UPPER;
        const stored_move = if (best_move.is_noisy()) best_move else Move.empty();
        tt.TT.store(tt.scoreEntry.new(pos.hash, stored_move, tt.TT.to_hash_score(best_score, self.ply), tt_bound, tt_depth, tt.TT.age));
        return best_score;
    }

    // Updates the Principal Variation (PV) table for the current ply.
    fn update_pv(self: *Search, move: Move) void {
        self.pv_table[self.ply][0] = move;
        const child_pv_length = self.pv_length[self.ply + 1];
        if (child_pv_length > 0) {
            @memcpy(
                self.pv_table[self.ply][1 .. 1 + child_pv_length],
                self.pv_table[self.ply + 1][0..child_pv_length],
            );
        }
        self.pv_length[self.ply] = child_pv_length + 1;
    }
};

const expect = std.testing.expect;

const TestSimpleSearch = struct {
    pv_table: [MAX_DEPTH][MAX_DEPTH]Move,
    pv_length: [MAX_DEPTH]u8,
    ply: usize,
};

// Just old versions of update_pv, for release they should be deleted
// Original function with std.mem.copyBackwards
fn update_pv1(self: *TestSimpleSearch, move: Move) void {
    self.pv_table[self.ply][0] = move;
    std.mem.copyBackwards(Move, self.pv_table[self.ply][1..(self.pv_length[self.ply + 1] + 1)], self.pv_table[self.ply + 1][0..(self.pv_length[self.ply + 1])]);
    self.pv_length[self.ply] = self.pv_length[self.ply + 1] + 1;
}

fn update_pv2(self: *TestSimpleSearch, move: Move) void {
    self.pv_table[self.ply][0] = move;
    const child_pv_length = self.pv_length[self.ply + 1];
    if (child_pv_length > 0) {
        @memcpy(
            self.pv_table[self.ply][1 .. 1 + child_pv_length],
            self.pv_table[self.ply + 1][0..child_pv_length],
        );
    }
    self.pv_length[self.ply] = child_pv_length + 1;
}

fn update_pv3(self: *TestSimpleSearch, move: Move) void {
    self.pv_table[self.ply][0] = move;
    const child_pv_length = self.pv_length[self.ply + 1];
    if (child_pv_length > 0) {
        @memmove(
            self.pv_table[self.ply][1 .. 1 + child_pv_length],
            self.pv_table[self.ply + 1][0..child_pv_length],
        );
    }
    self.pv_length[self.ply] = child_pv_length + 1;
}

// Benchmark test for both functions
test "benchmark update_pv1 vs update_pv2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    //const allocator = arena.allocator();

    // Initialize TestSimpleSearch struct
    var simple_search = TestSimpleSearch{
        .pv_table = undefined,
        .pv_length = undefined,
        .ply = 0,
    };

    // Test with different PV lengths
    const pv_lengths = [_]u8{ 5, 10, 20, 30 };
    const iterations = 100000; // Number of iterations per test
    var timer = try compat_timer.Timer.start();

    std.debug.print("\n", .{});
    for (pv_lengths) |pv_len| {
        // Setup: Initialize pv_length and pv_table
        simple_search.ply = 0;
        simple_search.pv_length[1] = pv_len; // Child PV length
        for (0..pv_len) |i| {
            simple_search.pv_table[1][i] = Move.empty(); // Dummy moves
        }

        // Benchmark update_pv1
        timer.reset();
        for (0..iterations) |_| {
            update_pv1(&simple_search, Move.empty()); // Dummy move
        }
        const time_pv1 = timer.read();

        // Reset pv_table for fairness
        simple_search.pv_table[0] = undefined;

        // Benchmark update_pv2
        timer.reset();
        for (0..iterations) |_| {
            update_pv2(&simple_search, Move.empty()); // Same dummy move
        }
        const time_pv2 = timer.read();

        // Reset pv_table for fairness
        simple_search.pv_table[0] = undefined;

        // Benchmark update_pv2
        timer.reset();
        for (0..iterations) |_| {
            update_pv3(&simple_search, Move.empty()); // Same dummy move
        }
        const time_pv3 = timer.read();

        // Print results (nanoseconds per call)
        const ns_per_call_pv1 = @as(f64, @floatFromInt(time_pv1)) / @as(f64, @floatFromInt(iterations));
        const ns_per_call_pv2 = @as(f64, @floatFromInt(time_pv2)) / @as(f64, @floatFromInt(iterations));
        const ns_per_call_pv3 = @as(f64, @floatFromInt(time_pv3)) / @as(f64, @floatFromInt(iterations));
        std.debug.print("PV length {}: update_pv1 = {:.2} ns/call, update_pv2 = {:.2} ns/call, update_pv3 = {:.2} ns/call, speedup (pv1/pv2) = {:.2}x, speedup (pv2/pv3) = {:.2}x\n", .{ pv_len, ns_per_call_pv1, ns_per_call_pv2, ns_per_call_pv3, ns_per_call_pv1 / ns_per_call_pv2, ns_per_call_pv2 / ns_per_call_pv3 });

        // Verify correctness (all functions should produce identical results)
        var pv1 = TestSimpleSearch{ .pv_table = undefined, .pv_length = undefined, .ply = 0 };
        pv1.pv_length[1] = pv_len;
        for (0..pv_len) |i| {
            pv1.pv_table[1][i] = Move.empty();
        }
        var pv2 = pv1;
        var pv3 = pv1;
        update_pv1(&pv1, Move.empty());
        update_pv2(&pv2, Move.empty());
        update_pv3(&pv3, Move.empty());
        try expect(std.mem.eql(Move, pv1.pv_table[0][0..pv1.pv_length[0]], pv2.pv_table[0][0..pv2.pv_length[0]]));
        try expect(std.mem.eql(Move, pv1.pv_table[0][0..pv1.pv_length[0]], pv3.pv_table[0][0..pv3.pv_length[0]]));
        try expect(pv1.pv_length[0] == pv2.pv_length[0] and pv2.pv_length[0] == pv3.pv_length[0]);
    }
}
