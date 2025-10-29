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

const BinEntry = struct {
    sfen32: [32]u8,
    move16: u16,
    score_cp: i32,
    ply: u16,
    stm_white: bool,
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

// move16 encoding centralized in datagen_writer.encode_move16

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
    var save_ns: i128 = 0;
    var play_ns: i128 = 0;

    for (0..cfg.games) |_| {
        var pos = Position.new();
        const variant: StartVariant = sample_variant(rng, cfg.dist); //.Standard; //
        set_start_position(rng, &pos, variant);

        // Preallocate a larger buffer to reduce reallocations when saving positions.
        var entries = try std.ArrayList(BinEntry).initCapacity(allocator, 512);
        defer entries.deinit(allocator);

        var ply: usize = 0;
        var random_used: usize = 0;
        var low_score_streak: usize = 0;
        var force_draw: bool = false;
        while (ply < cfg.max_plies and !is_terminal(&pos)) : (ply += 1) {
            const ply_start = std.time.nanoTimestamp();
            var this_save_ns: i128 = 0;
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
                const ts0 = std.time.nanoTimestamp();
                var s32: [32]u8 = undefined;
                binw.pack_sfen32(&pos, &s32);
                const be = BinEntry{
                    .sfen32 = s32,
                    .move16 = binw.Bin40Writer.encode_move16(bm), // BIN stores best move
                    .score_cp = best.score,
                    .ply = @intCast(pos.game_ply),
                    .stm_white = (pos.side_to_play == Color.White),
                };
                try entries.append(allocator, be);
                const ts1 = std.time.nanoTimestamp();
                this_save_ns += ts1 - ts0;
            }

            if (pos.side_to_play == Color.White) pos.play(mv, Color.White) else pos.play(mv, Color.Black);
            const ply_end = std.time.nanoTimestamp();
            save_ns += this_save_ns;
            play_ns += (ply_end - ply_start) - this_save_ns;
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
        const ws0 = std.time.nanoTimestamp();
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
        const ws1 = std.time.nanoTimestamp();
        save_ns += ws1 - ws0;

        games_count += 1;
    }

    const elapsed_ns2 = std.time.nanoTimestamp() - start_ns;
    const elapsed_s2: f64 = @as(f64, @floatFromInt(elapsed_ns2)) / 1_000_000_000.0;
    const avg_per_k2: f64 = if (total_positions > 0)
        elapsed_s2 / (@as(f64, @floatFromInt(total_positions)) / 1000.0)
    else
        0.0;
    uci.printout(uci.stdout, "info string datagen summary games={} positions={} time {d:.3}s avg_per_1k {d:.3}s\n", .{ games_count, total_positions, elapsed_s2, avg_per_k2 });
    const total_ns: i128 = elapsed_ns2;
    const other_ns: i128 = total_ns - (play_ns + save_ns);
    const play_pct: f64 = if (total_ns > 0) (@as(f64, @floatFromInt(play_ns)) * 100.0) / @as(f64, @floatFromInt(total_ns)) else 0.0;
    const save_pct: f64 = if (total_ns > 0) (@as(f64, @floatFromInt(save_ns)) * 100.0) / @as(f64, @floatFromInt(total_ns)) else 0.0;
    const other_pct: f64 = if (total_ns > 0) (@as(f64, @floatFromInt(other_ns)) * 100.0) / @as(f64, @floatFromInt(total_ns)) else 0.0;
    const play_s: f64 = @as(f64, @floatFromInt(play_ns)) / 1_000_000_000.0;
    const save_s: f64 = @as(f64, @floatFromInt(save_ns)) / 1_000_000_000.0;
    const other_s: f64 = @as(f64, @floatFromInt(other_ns)) / 1_000_000_000.0;
    uci.printout(uci.stdout, "info string datagen time_split play={d:.2}% ({d:.3}s) save={d:.2}% ({d:.3}s) other={d:.2}% ({d:.3}s)\n", .{ play_pct, play_s, save_pct, save_s, other_pct, other_s });
}

// SFEN recording removed for performance; we only pack directly to BIN now.

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
    skip_noisy: bool = false, // skip saving positions where best move is capture or promotion
    // Output filename (BIN). If no extension, .bin is appended.
    filename: []const u8 = "dataset.bin",
    random_min_ply: usize = 2,
    random_50_ply: usize = 6,
    random_10_ply: usize = 16,
    random_move_count: usize = 5,
    save_min_ply: usize = 5,
    save_max_ply: usize = 400,
    adjudicate_draws_by_score: bool = true,
    adjudicate_draws_by_insufficient_mating_material: bool = true,
};
