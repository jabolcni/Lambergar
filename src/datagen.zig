const std = @import("std");
const position = @import("position.zig");
const search = @import("search.zig");
const nnue = @import("nnue.zig");
const uci = @import("uci.zig");
const tt = @import("tt.zig");
const binw = @import("datagen_writer.zig");

const Position = position.Position;
const Move = position.Move;
const MoveList = @import("lists.zig").MoveList;
const Color = position.Color;

pub const StartVariant = enum { Standard, Chess960, DFRC };

pub const PositionRecord = struct {
    fen: []u8,
    bm_uci: []u8, // best move from search
    acm_uci: []u8, // actual move played
    score_cp: i32, // eval from side to move
    acd: u32, // analysis depth used for bm
    acn: u64, // nodes at bm search
    dm: i32, // mate in fullmoves if known else 0
    hmvc: u16, // game ply at this record
    rc: u16, // repetition count for this position
};

const BinEntry = struct {
    sfen32: [32]u8,
    move16: u16,
    score_cp: i32,
    ply: u16,
    stm_white: bool,
};

pub const Game = struct {
    variant: StartVariant,
    start_desc: [16]u8 = [_]u8{0} ** 16, // e.g. "std", "960:idx", "dfrc:w-b"
    records: std.ArrayList(PositionRecord),

    pub fn init(allocator: std.mem.Allocator) !Game {
        return Game{
            .variant = .Standard,
            .records = try std.ArrayList(PositionRecord).initCapacity(allocator, 0),
        };
    }

    pub fn deinit(self: *Game, allocator: std.mem.Allocator) void {
        for (self.records.items) |rec| {
            allocator.free(rec.fen);
            allocator.free(rec.bm_uci);
            allocator.free(rec.acm_uci);
        }
        self.records.deinit(allocator);
        // allocator used above
    }
};

fn to_uci_str(m: Move, buf: *[5]u8) []const u8 {
    const all = m.to_str();
    buf.* = all;
    return if (m.is_promotion()) buf[0..5] else buf[0..4];
}

fn pick_random_legal(rng: anytype, pos: *Position) ?Move {
    var list: MoveList = .{};
    if (pos.side_to_play == Color.White) pos.generate_legals(Color.White, &list) else pos.generate_legals(Color.Black, &list);
    if (list.count == 0) return null;
    const idx = rng.intRangeAtMost(usize, 0, list.count - 1);
    return list.moves[idx];
}

const BestInfo = struct { mv: Move, nodes: u64, score: i32, dm: i32 };

fn compute_dm_from_score(sc: i32) i32 {
    return if (search._is_mate_score(sc)) search._mate_in(sc) else 0;
}

fn pick_best_move(pos: *Position, depth: u32, debug: bool) BestInfo {
    var s = search.Search.new();
    // Initialize for a fresh search
    s.clear_for_new_game();
    s.clear_for_new_search();
    s.manager = search.SearchManager.new();
    s.manager.termination = search.Termination.DEPTH;
    s.manager.printout = debug; // when true, emits UCI-like info depth lines
    s.manager.max_depth = depth;
    s.max_depth = depth;
    // Match a cold 'go depth' run: clear TT to avoid cross-position contamination,
    // then configure time/windows and age TT like UCI.
    tt.TT.clear();
    s.manager.configure(pos);
    tt.TT.increase_age();
    pos.history[pos.game_ply].accumulator = nnue.refresh_accumulator(pos.*);
    // Seed accumulator eval for the correct side (nnue.evaluate requires comptime Color)
    if (pos.side_to_play == Color.White) {
        pos.history[pos.game_ply].accumulator.eval = nnue.evaluate(pos.history[pos.game_ply].accumulator, Color.White);
    } else {
        pos.history[pos.game_ply].accumulator.eval = nnue.evaluate(pos.history[pos.game_ply].accumulator, Color.Black);
    }
    pos.history[pos.game_ply].accumulator.computed_score = true;

    s.nodes = 0;
    s.ply = 0;
    s.seldepth = 0;

    if (pos.side_to_play == Color.White) {
        s.iterative_deepening(pos, Color.White);
    } else {
        s.iterative_deepening(pos, Color.Black);
    }

    var mv = if (!s.best_move.is_empty()) s.best_move else s.pv_table[0][0];
    if (mv.is_empty()) {
        // Fallback to first legal
        var list: MoveList = .{};
        if (pos.side_to_play == Color.White) pos.generate_legals(Color.White, &list) else pos.generate_legals(Color.Black, &list);
        if (list.count > 0) mv = list.moves[0] else mv = Move.empty();
    }
    const sc = s.root_score;
    const dm = compute_dm_from_score(sc);
    if (debug) {
        var mbuf: [5]u8 = undefined;
        const bm_str = to_uci_str(mv, &mbuf);
        uci.printout(uci.stdout, "info string datagen bm {s} nodes {} score {}\n", .{ bm_str, s.nodes, sc });
    }
    return .{ .mv = mv, .nodes = s.nodes, .score = sc, .dm = dm };
}

fn pick_best_move_strict(pos: *Position, depth: u32, debug: bool) BestInfo {
    var s = &uci.thinkers[0];
    s.* = search.Search.new();
    s.clear_for_new_game();
    s.clear_for_new_search();
    s.manager = search.SearchManager.new();
    s.manager.termination = search.Termination.DEPTH;
    s.manager.max_depth = depth;
    s.manager.printout = debug;
    s.max_depth = depth;

    // Fresh TT per position to mimic a dedicated 'go depth' run
    tt.TT.clear();
    s.manager.configure(pos);
    tt.TT.increase_age();

    pos.history[pos.game_ply].accumulator = nnue.refresh_accumulator(pos.*);
    if (pos.side_to_play == Color.White) {
        pos.history[pos.game_ply].accumulator.eval = nnue.evaluate(pos.history[pos.game_ply].accumulator, Color.White);
    } else {
        pos.history[pos.game_ply].accumulator.eval = nnue.evaluate(pos.history[pos.game_ply].accumulator, Color.Black);
    }
    pos.history[pos.game_ply].accumulator.computed_score = true;

    s.nodes = 0;
    s.ply = 0;
    s.seldepth = 0;

    if (pos.side_to_play == Color.White) {
        s.iterative_deepening(pos, Color.White);
    } else {
        s.iterative_deepening(pos, Color.Black);
    }

    var mv = if (!s.best_move.is_empty()) s.best_move else s.pv_table[0][0];
    if (mv.is_empty()) {
        var list: MoveList = .{};
        if (pos.side_to_play == Color.White) pos.generate_legals(Color.White, &list) else pos.generate_legals(Color.Black, &list);
        if (list.count > 0) mv = list.moves[0] else mv = Move.empty();
    }
    const sc = s.root_score;
    const dm = compute_dm_from_score(sc);
    return .{ .mv = mv, .nodes = s.nodes, .score = sc, .dm = dm };
}

fn repetition_count(pos: *Position) u16 {
    const fifty = pos.history[pos.game_ply].fifty;
    const min_index: isize = @as(isize, pos.game_ply) - @as(isize, fifty);
    var count: u16 = 0;
    var i: isize = @max(0, min_index);
    while (i <= @as(isize, pos.game_ply)) : (i += 2) {
        const idx: usize = @intCast(i);
        if (pos.hash == pos.history[idx].hash_key) count +%= 1;
    }
    return if (count == 0) 0 else count - 1;
}

fn encode_move16(mv: Move) u16 {
    // Stockfish move: to in low 6, from in next 6, promo high 4 bits
    var code: u16 = 0;
    code |= @as(u16, mv.to & 0x3F);
    code |= (@as(u16, mv.from & 0x3F)) << 6;
    var promo: u16 = 0;
    if (mv.is_promotion()) {
        const pt = mv.flags.promote_type();
        promo = switch (pt) {
            .Knight => 1,
            .Bishop => 2,
            .Rook => 3,
            .Queen => 4,
            else => 0,
        };
    }
    code |= (promo & 0xF) << 12;
    return code;
}

pub fn generate_binary(allocator: std.mem.Allocator, bin_path: []const u8, cfg: GenConfig) !void {
    const start_ns: i128 = std.time.nanoTimestamp();
    const now_bits: u128 = @bitCast(start_ns);
    const seed: u64 = @truncate(now_bits);
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var bw = try binw.Bin40Writer.open(bin_path);
    defer bw.close();

    var total_positions: usize = 0;
    var games_count: usize = 0;

    for (0..cfg.games) |_| {
        var pos = Position.new();
        const variant = sample_variant(rng, cfg.dist);
        set_start_position(rng, &pos, variant);

        var entries = try std.ArrayList(BinEntry).initCapacity(allocator, 128);
        defer entries.deinit(allocator);

        var ply: usize = 0;
        var random_used: usize = 0;
        var low_score_streak: usize = 0;
        var force_draw: bool = false;
        while (ply < cfg.max_plies and !is_terminal(&pos)) : (ply += 1) {
            const best = if (cfg.strict)
                pick_best_move_strict(&pos, cfg.best_depth, false)
            else
                pick_best_move(&pos, cfg.best_depth, false);
            const bm = best.mv;

            // Adjudications
            if (cfg.adjudicate_draws_by_score and pos.game_ply >= 80) {
                if (@abs(best.score) < 50) low_score_streak += 1 else low_score_streak = 0;
                if (low_score_streak >= 8) {
                    force_draw = true;
                    break;
                }
            }
            if (cfg.adjudicate_draws_by_insufficient_mating_material and pos.is_insufficient_material()) {
                force_draw = true;
                break;
            }
            if (pos.game_ply > cfg.save_max_ply) {
                force_draw = true;
                break;
            }

            // Random policy with caps
            var chosen: ?Move = null;
            const curr_ply: usize = pos.game_ply;
            var rand_prob: u8 = 0; // percentage
            if (curr_ply >= cfg.random_min_ply and random_used < cfg.random_move_count) {
                if (curr_ply < cfg.random_50_ply) rand_prob = 100 else if (curr_ply < cfg.random_10_ply) rand_prob = 50 else rand_prob = 10;
            }
            if (rand_prob > 0 and rng.intRangeAtMost(u8, 0, 99) < rand_prob) {
                const rnd = pick_random_legal(rng, &pos);
                if (rnd) |rv| {
                    chosen = rv;
                    random_used += 1;
                } else {
                    chosen = bm;
                }
            } else {
                chosen = bm;
            }
            const mv = chosen orelse break;

            // Save only within window; skip noisy, in-check, or mate-in-N positions
            if (pos.game_ply >= cfg.save_min_ply and pos.game_ply <= cfg.save_max_ply and !(cfg.skip_noisy and bm.is_tactical()) and !is_any_check(&pos) and best.dm == 0) {
                var s32: [32]u8 = undefined;
                binw.pack_sfen32(&pos, &s32);
                const be = BinEntry{
                    .sfen32 = s32,
                    .move16 = encode_move16(bm), // BIN stores best move
                    .score_cp = best.score,
                    .ply = @intCast(pos.game_ply),
                    .stm_white = (pos.side_to_play == Color.White),
                };
                try entries.append(allocator, be);
            }

            if (pos.side_to_play == Color.White) pos.play(mv, Color.White) else pos.play(mv, Color.Black);
        }

        var list_end: MoveList = .{};
        if (pos.side_to_play == Color.White) pos.generate_legals(Color.White, &list_end) else pos.generate_legals(Color.Black, &list_end);
        var result_white: f32 = 0.5;
        if (list_end.count == 0) {
            const stm = pos.side_to_play;
            const in_chk = if (stm == Color.White) pos.in_check(Color.White) else pos.in_check(Color.Black);
            if (in_chk) {
                result_white = if (stm == Color.White) 0.0 else 1.0;
            } else result_white = 0.5;
        } else if (pos.is_draw() or force_draw) {
            result_white = 0.5;
        } else {
            result_white = 0.5;
        }

        var i: usize = 0;
        while (i < entries.items.len) : (i += 1) {
            const e = entries.items[i];
            var gr: i8 = 0;
            if (result_white >= 0.75) gr = if (e.stm_white) 1 else -1 else if (result_white <= 0.25) gr = if (e.stm_white) -1 else 1 else gr = 0;
            try bw.write_packed(&e.sfen32, e.score_cp, e.move16, e.ply, gr);
            total_positions += 1;
            if (total_positions % 1000 == 0) {
                const elapsed_ns = std.time.nanoTimestamp() - start_ns;
                const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
                const avg_per_k: f64 = if (total_positions > 0)
                    elapsed_s / (@as(f64, @floatFromInt(total_positions)) / 1000.0)
                else
                    0.0;
                uci.printout(uci.stdout, "info string datagen progress games={} positions={} time {d:.3}s avg_per_1k {d:.3}s\n", .{ games_count, total_positions, elapsed_s, avg_per_k });
            }
        }

        games_count += 1;
    }

    const elapsed_ns2 = std.time.nanoTimestamp() - start_ns;
    const elapsed_s2: f64 = @as(f64, @floatFromInt(elapsed_ns2)) / 1_000_000_000.0;
    const avg_per_k2: f64 = if (total_positions > 0)
        elapsed_s2 / (@as(f64, @floatFromInt(total_positions)) / 1000.0)
    else
        0.0;
    uci.printout(uci.stdout, "info string datagen summary games={} positions={} time {d:.3}s avg_per_1k {d:.3}s\n", .{ games_count, total_positions, elapsed_s2, avg_per_k2 });
}

fn record_position(
    allocator: std.mem.Allocator,
    game: *Game,
    pos: *Position,
    bm: Move,
    bm_nodes: u64,
    bm_score: i32,
    bm_dm: i32,
    actual: Move,
    acd_depth: u32,
) !void {
    const fen = try pos.get_fen(allocator);
    var mbuf: [5]u8 = undefined;
    const bm_str = to_uci_str(bm, &mbuf);
    const bm_copy = try allocator.dupe(u8, bm_str);
    const acm_str = to_uci_str(actual, &mbuf);
    const acm_copy = try allocator.dupe(u8, acm_str);
    const sc = if (search._is_mate_score(bm_score)) 0 else bm_score;
    const repc = repetition_count(pos);
    const hmvc_now: u16 = @intCast(pos.game_ply);
    try game.records.append(allocator, PositionRecord{
        .fen = fen,
        .bm_uci = bm_copy,
        .acm_uci = acm_copy,
        .score_cp = sc,
        .acd = acd_depth,
        .acn = bm_nodes,
        .dm = bm_dm,
        .hmvc = hmvc_now,
        .rc = repc,
    });
}

fn is_terminal(pos: *Position) bool {
    var list: MoveList = .{};
    if (pos.side_to_play == Color.White) pos.generate_legals(Color.White, &list) else pos.generate_legals(Color.Black, &list);
    if (list.count == 0) return true; // checkmate/stalemate
    if (pos.is_draw()) return true; // repetition/50-move
    return false;
}

fn is_any_check(pos: *Position) bool {
    // Skip saving positions when any king is currently in check
    return pos.in_check(Color.White) or pos.in_check(Color.Black);
}

fn set_start_position(rng: anytype, pos: *Position, variant: StartVariant) void {
    switch (variant) {
        .Standard => {
            pos.set(uci.start_position) catch {};
            // is_chess960 flag remains false on classic start
        },
        .Chess960 => {
            // Random index 0..959
            const idx = rng.intRangeAtMost(u16, 0, 959);
            pos.set_chess960_start(idx) catch {};
        },
        .DFRC => {
            const w = rng.intRangeAtMost(u16, 0, 959);
            const b = rng.intRangeAtMost(u16, 0, 959);
            pos.set_dfrc_start(w, b) catch {};
        },
    }
}

pub const Dist = struct { std_pc: f32 = 0.40, frc_pc: f32 = 0.33, dfrc_pc: f32 = 0.27 };

fn sample_variant(rng: anytype, dist: Dist) StartVariant {
    const r = rng.float(f32);
    if (r < dist.std_pc) return .Standard;
    if (r < dist.std_pc + dist.frc_pc) return .Chess960;
    return .DFRC;
}

pub const GenConfig = struct {
    games: usize = 1,
    max_plies: usize = 200,
    best_depth: u32 = 8,
    // randomization windows
    first_random: usize = 3, // legacy (unused by new policy)
    next_mixed: usize = 3, // legacy (unused by new policy)
    dist: Dist = .{},
    debug: bool = false,
    strict: bool = false,
    bin_path: ?[]const u8 = null,
    skip_noisy: bool = false, // skip saving positions where best move is capture or promotion
    // New policy and IO options
    output_file_name: []const u8 = "dataset",
    random_min_ply: usize = 2,
    random_50_ply: usize = 6,
    random_10_ply: usize = 16,
    random_move_count: usize = 5,
    save_min_ply: usize = 5,
    save_max_ply: usize = 400,
    adjudicate_draws_by_score: bool = true,
    adjudicate_draws_by_insufficient_mating_material: bool = true,
    bin_only: bool = false,
};

pub fn generate_to_sfen_text(
    allocator: std.mem.Allocator,
    out_path: []const u8,
    cfg: GenConfig,
) !void {
    const start_ns: i128 = std.time.nanoTimestamp();
    const now = std.time.nanoTimestamp();
    const now_bits: u128 = @bitCast(now);
    const seed: u64 = @truncate(now_bits);
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var file = try std.fs.cwd().createFile(out_path, .{ .read = false, .truncate = true, .mode = 0o666 });
    defer file.close();
    // We'll format each line into a small stack buffer and writeAll to the file.

    var total_positions: usize = 0;
    var games_count: usize = 0;

    var bin_writer: ?binw.Bin40Writer = null;
    if (cfg.bin_path) |bp| {
        bin_writer = try binw.Bin40Writer.open(bp);
    }
    defer if (bin_writer) |*bw| bw.close();

    for (0..cfg.games) |gi| {
        var pos = Position.new();
        const variant = sample_variant(rng, cfg.dist);
        set_start_position(rng, &pos, variant);

        var game = try Game.init(allocator);
        game.variant = variant;

        var ply: usize = 0;
        // play until terminal or max plies
        while (ply < cfg.max_plies and !is_terminal(&pos)) : (ply += 1) {
            // Always compute bestmove and nodes for bm/acn/acd
            if (cfg.debug) {
                const fen_dbg = try pos.get_fen(allocator);
                defer allocator.free(fen_dbg);
                var lm_dbg: MoveList = .{};
                if (pos.side_to_play == Color.White) pos.generate_legals(Color.White, &lm_dbg) else pos.generate_legals(Color.Black, &lm_dbg);
                uci.printout(uci.stdout, "info string datagen start depth {} side {s} ply {} legals {} fen {s}\n", .{ cfg.best_depth, if (pos.side_to_play == Color.White) "W" else "B", pos.game_ply, lm_dbg.count, fen_dbg });
            }
            const best = if (cfg.strict)
                pick_best_move_strict(&pos, cfg.best_depth, cfg.debug)
            else
                pick_best_move(&pos, cfg.best_depth, cfg.debug);
            const bm = best.mv;
            const bm_nodes = best.nodes;
            const bm_score = best.score;
            const bm_dm = best.dm;

            var chosen: ?Move = null;
            var chosen_src: []const u8 = "best";
            if (ply < cfg.first_random) {
                chosen = pick_random_legal(rng, &pos);
                chosen_src = "random";
            } else if (ply < cfg.first_random + cfg.next_mixed) {
                const coin = rng.intRangeAtMost(u8, 0, 1);
                if (coin == 0) {
                    chosen = pick_random_legal(rng, &pos);
                    chosen_src = "mixed-rand";
                } else {
                    chosen = bm;
                    chosen_src = "mixed-best";
                }
            } else {
                chosen = bm;
                chosen_src = "best";
            }

            const mv = chosen orelse break;
            // Conditionally save by ply window; skip noisy, in-check, or mate-in-N
            if (pos.game_ply >= cfg.save_min_ply and pos.game_ply <= cfg.save_max_ply and !(cfg.skip_noisy and bm.is_tactical()) and !is_any_check(&pos) and bm_dm == 0) {
                // record current position, bm and actual
                try record_position(allocator, &game, &pos, bm, bm_nodes, bm_score, bm_dm, mv, cfg.best_depth);
                total_positions += 1;
                if (total_positions % 1000 == 0) {

                    // Print summary with timing
                    const elapsed_ns = std.time.nanoTimestamp() - start_ns;
                    const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
                    const avg_per_k: f64 = if (total_positions > 0)
                        elapsed_s / (@as(f64, @floatFromInt(total_positions)) / 1000.0)
                    else
                        0.0;

                    uci.printout(uci.stdout, "info string datagen progress games={} positions={} time {d:.3}s avg_per_1k {d:.3}s\n", .{ games_count, total_positions, elapsed_s, avg_per_k });
                }
            }
            if (cfg.debug) {
                var mbuf: [5]u8 = undefined;
                const bm_str = to_uci_str(bm, &mbuf);
                const acm_str = to_uci_str(mv, &mbuf);
                const repc = repetition_count(&pos);
                uci.printout(uci.stdout, "info string datagen choose {s} bm {s} acm {s} ce {} dm {} acn {} hmvc {} rc {}\n", .{ chosen_src, bm_str, acm_str, if (search._is_mate_score(bm_score)) 0 else bm_score, bm_dm, bm_nodes, pos.game_ply, repc });
            }
            // play move
            if (pos.side_to_play == Color.White) pos.play(mv, Color.White) else pos.play(mv, Color.Black);
        }

        // Determine game result (from White's perspective)
        var list_end: MoveList = .{};
        if (pos.side_to_play == Color.White) pos.generate_legals(Color.White, &list_end) else pos.generate_legals(Color.Black, &list_end);
        var result: f32 = 0.5;
        if (list_end.count == 0) {
            const stm = pos.side_to_play;
            const in_chk = if (stm == Color.White) pos.in_check(Color.White) else pos.in_check(Color.Black);
            if (in_chk) {
                // Side to move is checkmated
                result = if (stm == Color.White) 0.0 else 1.0;
            } else {
                result = 0.5; // stalemate
            }
        } else if (pos.is_draw()) {
            result = 0.5;
        } else {
            // Non-terminal due to plies cap: treat as draw for training purposes
            result = 0.5;
        }

        // write one line per position in requested SFEN-like format:
        // FEN; bm <move played>; ce <cp (side-to-move)>; acd <depth>; acn <nodes>; dm <mate fullmoves>; hmvc <halfmove clock>; rc <repetition count>; result <game result (side-to-move: 1/-1/0)>
        for (game.records.items) |rec| {
            var line_buf: [512]u8 = undefined;
            // Determine side-to-move from FEN for correct perspective result
            var stm_white: bool = true;
            {
                // FEN format has active color as the token after board: " w " or " b "
                // Simple scan for " w " vs " b " in the small header part
                const fen_slice = rec.fen;
                const wpos = std.mem.indexOf(u8, fen_slice, " w ");
                const bpos = std.mem.indexOf(u8, fen_slice, " b ");
                if (bpos != null and (wpos == null or bpos.? < wpos.?)) stm_white = false;
            }
            var gr: i8 = 0;
            if (result >= 0.75) gr = if (stm_white) 1 else -1 else if (result <= 0.25) gr = if (stm_white) -1 else 1 else gr = 0;

            const line = try std.fmt.bufPrint(
                &line_buf,
                // bm = best move from search; acm = actual move played
                "{s}; bm {s}; acm {s}; ce {d}; acd {d}; acn {d}; dm {d}; hmvc {d}; rc {d}; result {d}\n",
                .{ rec.fen, rec.bm_uci, rec.acm_uci, rec.score_cp, rec.acd, rec.acn, rec.dm, rec.hmvc, rec.rc, gr },
            );
            try file.writeAll(line);

            if (bin_writer) |*bw| {
                // Parse bm from rec.bm_uci back to Move for encoding
                // We have original position 'pos' after playing all moves; to encode from the stored position,
                // re-build a temp Position from rec.fen to avoid drift.
                var temp = Position.new();
                // rec.fen is owned by game and freed later; make a copy to pass into set()
                const fen_copy = try allocator.dupe(u8, rec.fen);
                defer allocator.free(fen_copy);
                temp.set(fen_copy) catch continue;
                const move = Move.parse_move(rec.bm_uci, &temp) catch Move.empty();
                try bw.write_position(&temp, move, rec.score_cp, result, rec.hmvc);
            }
        }

        // Update summary counters
        games_count += 1;

        game.deinit(allocator);
        _ = gi; // unused id for now
    }

    // Print summary with timing
    const elapsed_ns = std.time.nanoTimestamp() - start_ns;
    const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const avg_per_k: f64 = if (total_positions > 0)
        elapsed_s / (@as(f64, @floatFromInt(total_positions)) / 1000.0)
    else
        0.0;
    uci.printout(uci.stdout, "info string datagen summary games={} positions={} time {d:.3}s avg_per_1k {d:.3}s\n", .{ games_count, total_positions, elapsed_s, avg_per_k });
}
