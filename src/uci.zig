const std = @import("std");
const perft = @import("perft.zig");
const position = @import("position.zig");
const evaluation = @import("evaluation.zig");
const tt = @import("tt.zig");
const attacks = @import("attacks.zig");
const zobrist = @import("zobrist.zig");
const search = @import("search.zig");
const ms = @import("movescorer.zig");
const nnue = @import("nnue.zig");
const bb = @import("bitboard.zig");
const lists = @import("lists.zig");
const fathom = @import("fathom.zig");

pub const use_tb = @import("config").use_tb;

const Position = position.Position;
const Color = position.Color;
const Move = position.Move;
const Piece = position.Piece;
const Search = search.Search;

const MoveList = lists.MoveList;

const UCI_COMMAND_MAX_LENGTH = 5000;

var buffer = [1]u8{0} ** UCI_COMMAND_MAX_LENGTH;
var stdout_buffer = [1]u8{0} ** UCI_COMMAND_MAX_LENGTH;
var stdin_reader: std.fs.File.Reader = undefined;
var stdout_writer: std.fs.File.Writer = undefined;
var stdin: *std.Io.Reader = undefined;
pub var stdout: *std.Io.Writer = undefined;

const HASH_SIZE_MIN = 1;
const HASH_SIZE_DEFAULT = 128;
const HASH_SIZE_MAX = 4096;

pub const empty_board = "8/8/8/8/8/8/8/8 w - - ";
pub const start_position = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 ";

pub var debug = false;

pub const MAX_THREADS = 32;
pub var num_threads: usize = 1;
pub var threads: [MAX_THREADS]?std.Thread = [_]?std.Thread{null} ** MAX_THREADS;
pub var thinkers: [MAX_THREADS]Search = undefined;
var pos: [MAX_THREADS]Position = undefined;

var syzygy_path: ?[]const u8 = null;

pub fn printout(writer: *std.Io.Writer, comptime str: []const u8, args: anytype) !void {
    try writer.print(str, args);
    try writer.flush();
}

fn u32_from_str(str: []const u8) !u32 {
    return std.fmt.parseInt(u32, str, 10);
}

fn usize_from_str(str: []const u8) !usize {
    return std.fmt.parseInt(usize, str, 10);
}

fn u64_from_str(str: []const u8) !u64 {
    return std.fmt.parseInt(u64, str, 10);
}

pub fn i8_from_str(str: []const u8) i8 {
    return std.fmt.parseInt(i8, std.mem.trim(u8, str, " "), 10) catch 0;
}

fn parse_and_apply_moves(curr_pos: *Position, moves_str: []const u8) !void {
    var moves = std.mem.splitScalar(u8, std.mem.trim(u8, moves_str, " "), ' ');
    while (moves.next()) |move_str| {
        const move = Move.parse_move(move_str, curr_pos) catch |err| {
            try printout(stdout, "info string Invalid move '{s}': {any}\n", .{ move_str, err });
            continue;
        };
        //const move = Move.parse_move(move_str, &pos[0]) catch continue;
        if (curr_pos.side_to_play == Color.White) {
            curr_pos.play(move, Color.White);
        } else {
            curr_pos.play(move, Color.Black);
        }
    }
}

pub fn init_all(allocator: std.mem.Allocator) !void {
    attacks.initialise_all_databases();
    zobrist.initialise_zobrist_keys();
    evaluation.init_eval();
    search.init_lmr();

    if (use_tb) {
        try fathom.init_tablebases(allocator, syzygy_path);
    }

    stdin_reader = std.fs.File.stdin().reader(&buffer);
    stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);

    stdin = &stdin_reader.interface;
    stdout = &stdout_writer.interface;
}

pub fn uci_loop(allocator: std.mem.Allocator) !void {
    try init_all(allocator);

    if (nnue.engine_using_nnue) {
        //try nnue.init(allocator);
        try nnue.embed_and_init();
        nnue.engine_loaded_net = true;
        if (debug) {
            std.debug.print("NNUE loaded = {}\n", .{nnue.engine_loaded_net});
        }
    }

    try tt.TT.init(128 + 1);
    defer tt.TT.deinit();

    for (0..MAX_THREADS) |i| {
        pos[i] = Position.new();
        try pos[i].set(start_position);
        thinkers[i] = Search.new();
        thinkers[i].clear_for_new_game();
    }

    var main_search_thread: ?std.Thread = null;

    mainloop: while (true) {

        //std.time.sleep(20 * 1000 * 1000);
        //const input_full = (try stdin.readUntilDelimiter(&buffer, '\n'));
        const input_full = try stdin.takeDelimiterExclusive('\n');

        if (input_full.len == 0) continue :mainloop;
        const input = std.mem.trimRight(u8, input_full, "\r");
        if (input.len == 0) continue :mainloop;

        var words = std.mem.splitScalar(u8, input, ' ');
        const command = words.next().?;

        if (std.mem.eql(u8, command, "uci")) {
            std.debug.print("uci command\n", .{});
            try printout(stdout, "id name Lambergar 1.4\n", .{});
            try printout(stdout, "id author Janez Podobnik\n", .{});
            try printout(stdout, "option name Hash type spin default {d} min {d} max {d}\n", .{ HASH_SIZE_DEFAULT, HASH_SIZE_MIN, HASH_SIZE_MAX });
            try printout(stdout, "option name Threads type spin default {d} min {d} max {d}\n", .{ 1, 1, MAX_THREADS });
            try printout(stdout, "option name UseNNUE type check default {}\n", .{nnue.engine_using_nnue});
            //try printout(stdout,"option name EvalFile type string default \n", .{});
            try printout(stdout, "option name Debug type check default {}\n", .{debug});
            if (use_tb) {
                try printout(stdout, "option name SyzygyPath type string default <empty>\n", .{});
                try printout(stdout, "option name SyzygyProbeDepth type spin default {d} min {d} max {d}\n", .{ fathom.tb_probe_depth, 0, 127 });
            }
            try printout(stdout, "uciok\n", .{});
        } else if (std.mem.eql(u8, command, "go")) {
            if (main_search_thread) |thread| {
                @atomicStore(bool, &thinkers[0].stop, true, .seq_cst);
                thread.join();
                main_search_thread = null;
            }
            @atomicStore(bool, &thinkers[0].stop, false, .seq_cst);

            thinkers[0].manager = search.SearchManager.new();

            while (words.next()) |arg| {
                if (std.mem.eql(u8, arg, "ponder")) {
                    thinkers[0].manager.ponder = false;
                } else if (std.mem.eql(u8, arg, "wtime")) {
                    if (words.next()) |val| thinkers[0].manager.wtime = u64_from_str(val) catch continue;
                } else if (std.mem.eql(u8, arg, "btime")) {
                    if (words.next()) |val| thinkers[0].manager.btime = u64_from_str(val) catch continue;
                } else if (std.mem.eql(u8, arg, "winc")) {
                    if (words.next()) |val| thinkers[0].manager.winc = u32_from_str(val) catch continue;
                } else if (std.mem.eql(u8, arg, "binc")) {
                    if (words.next()) |val| thinkers[0].manager.binc = u32_from_str(val) catch continue;
                } else if (std.mem.eql(u8, arg, "movestogo")) {
                    if (words.next()) |val| thinkers[0].manager.movestogo = u32_from_str(val) catch continue;
                } else if (std.mem.eql(u8, arg, "depth")) {
                    if (words.next()) |val| thinkers[0].max_depth = u32_from_str(val) catch continue;
                } else if (std.mem.eql(u8, arg, "nodes")) {
                    if (words.next()) |val| thinkers[0].manager.max_nodes = u32_from_str(val) catch continue;
                } else if (std.mem.eql(u8, arg, "mate")) {
                    if (words.next()) |val| thinkers[0].manager.mate = u32_from_str(val) catch continue;
                } else if (std.mem.eql(u8, arg, "movetime")) {
                    if (words.next()) |val| thinkers[0].manager.movetime = u64_from_str(val) catch continue;
                } else if (std.mem.eql(u8, arg, "infinite") or std.mem.eql(u8, arg, "inf")) {
                    thinkers[0].manager.infinite = true;
                } else if (std.mem.eql(u8, arg, "searchmoves")) {
                    continue; // Unimplemented
                }
            }

            thinkers[0].manager.configure(&pos[0]);
            tt.TT.increase_age();

            for (1..num_threads) |i| {
                thinkers[i].manager.termination = search.Termination.INFINITE;
                pos[i] = pos[0].copy();
                const delta: i32 = @as(i32, 5 + @divFloor(@as(i32, @intCast(i)), 2) * 2);
                threads[i] = try std.Thread.spawn(.{}, search.start_search, .{ &thinkers[i], &pos[i], delta });
            }

            main_search_thread = try std.Thread.spawn(.{}, search.start_main_search, .{ &thinkers[0], &pos[0] });
        } else if (std.mem.eql(u8, command, "quit") or std.mem.eql(u8, command, "exit")) {
            @atomicStore(bool, &thinkers[0].stop, true, .seq_cst);
            break :mainloop;
        } else if (std.mem.eql(u8, command, "stop")) {
            //thinker.stop = true;
            @atomicStore(bool, &thinkers[0].stop, true, .seq_cst);
        } else if (std.mem.eql(u8, command, "isready")) {
            try printout(stdout, "readyok\n", .{});
        } else if (std.mem.eql(u8, command, "debug")) {
            const arg = words.next().?;
            if (std.mem.eql(u8, arg, "on")) {
                debug = true;
            } else if (std.mem.eql(u8, arg, "off")) {
                debug = false;
            } else continue;
        } else if (std.mem.eql(u8, command, "setoption")) {
            var arg = words.next().?;
            if (std.mem.eql(u8, arg, "name")) {
                arg = words.next().?;
                if (std.mem.eql(u8, arg, "Hash")) {
                    arg = words.next().?;
                    if (std.mem.eql(u8, arg, "value")) {
                        const hash_size = try u64_from_str(words.next() orelse continue);
                        tt.TT.deinit();
                        try tt.TT.init(hash_size);
                    } else continue;
                } else if ((std.mem.eql(u8, arg, "Clear")) and (std.mem.eql(u8, words.next().?, "Hash"))) {
                    tt.TT.clear();
                } else if (std.mem.eql(u8, arg, "Threads")) {
                    arg = words.next().?;
                    if (std.mem.eql(u8, arg, "value")) {
                        num_threads = try usize_from_str(words.next() orelse continue);
                        @atomicStore(bool, &thinkers[0].stop, true, .seq_cst);
                        try printout(stdout, "Threads set to: {}\n", .{num_threads});
                    } else continue;
                } else if (std.mem.eql(u8, arg, "UseNNUE")) {
                    arg = words.next().?;
                    if (std.mem.eql(u8, arg, "value")) {
                        arg = words.next().?;
                        if (std.mem.eql(u8, arg, "true")) {
                            nnue.engine_using_nnue = nnue.engine_loaded_net;
                        } else if (std.mem.eql(u8, arg, "false")) {
                            nnue.engine_using_nnue = false;
                        } else {
                            nnue.engine_using_nnue = true;
                        }
                        if (debug) {
                            std.debug.print("UseNNue = {}\n", .{nnue.engine_using_nnue});
                        }
                    } else continue;
                } else if (std.mem.eql(u8, arg, "EvalFile")) {
                    nnue.engine_loaded_net = false;
                    const nnue_file_name = words.next() orelse continue :mainloop;
                    try nnue.init_specific_net(allocator, nnue_file_name);
                    nnue.engine_loaded_net = true;
                    if (debug) {
                        std.debug.print("NNUE loaded = {}\n", .{nnue.engine_loaded_net});
                    }
                } else if (use_tb and std.mem.eql(u8, arg, "SyzygyPath")) {
                    arg = words.next().?;
                    if (std.mem.eql(u8, arg, "value")) {
                        if (syzygy_path) |old_path| {
                            allocator.free(old_path);
                        }

                        syzygy_path = words.next() orelse null;
                        if (syzygy_path.?.len == 0 or std.mem.eql(u8, syzygy_path.?, "<empty>")) {
                            syzygy_path = null; // Or could set to ""
                            _ = try printout(stdout, "info string SyzygyPath cleared.\n", .{});
                        } else {
                            _ = try printout(stdout, "info string SyzygyPath set to: {s}\n", .{syzygy_path.?});
                        }

                        fathom.free_tablebases();
                        fathom.init_tablebases(allocator, syzygy_path) catch |err| {
                            _ = try printout(stdout, "info string Failed to initialize Syzygy with new path: {any}\n", .{err});
                        };
                    } else continue;
                } else if (use_tb and std.mem.eql(u8, arg, "SyzygyProbeDepth")) {
                    arg = words.next().?;
                    if (std.mem.eql(u8, arg, "value")) {
                        const depth = i8_from_str(words.next() orelse continue);
                        if (depth < 0 or depth > 127) continue;
                        fathom.tb_probe_depth = depth;
                        _ = try printout(stdout, "info string SyzygyProbeDepth set to: {d}\n", .{fathom.tb_probe_depth});
                    } else continue;
                } else continue;
            } else continue;
        } else if (std.mem.eql(u8, command, "ucinewgame")) {
            for (0..MAX_THREADS) |i| {
                thinkers[i].clear_for_new_game();
            }
            tt.TT.clear();
            try pos[0].set(start_position);
        } else if (std.mem.eql(u8, command, "position")) {
            const pos_variant = words.next() orelse {
                try printout(stdout, "info string Missing position variant\n", .{});
                continue;
            };

            pos[0] = Position.new();
            if (std.mem.eql(u8, pos_variant, "fen")) {
                var parts = std.mem.splitSequence(u8, words.rest(), "moves");
                const fen = parts.next() orelse {
                    try printout(stdout, "info string Missing FEN string\n", .{});
                    continue;
                };
                //try pos[0].set(std.mem.trim(u8, fen, " "));
                pos[0].set(std.mem.trim(u8, fen, " ")) catch |err| {
                    try printout(stdout, "info string Invalid FEN: {s}\n", .{@errorName(err)});
                    continue; // or continue loop, depending on context
                };

                if (parts.rest().len > 0) {
                    try parse_and_apply_moves(&pos[0], parts.rest());
                }
            } else if (std.mem.eql(u8, pos_variant, "startpos")) {
                try pos[0].set(start_position);
                if (words.next()) |keyword| {
                    if (std.mem.eql(u8, keyword, "moves")) {
                        try parse_and_apply_moves(&pos[0], words.rest());
                    }
                }
            } else {
                try printout(stdout, "info string Unknown position variant '{s}'\n", .{pos_variant});
                continue;
            }
        } else if (std.mem.eql(u8, command, "board")) {
            pos[0].print_unicode();
        } else if (std.mem.eql(u8, command, "moves")) {
            var list: MoveList = .{};

            if (pos[0].side_to_play == Color.White) {
                pos[0].generate_legals(Color.White, &list);
            } else {
                pos[0].generate_legals(Color.Black, &list);
            }

            for (0..list.count) |i| {
                const move = list.moves[i];
                try printout(stdout, "\n{}. ", .{i});
                move.print();
            }
            try printout(stdout, "\n", .{});
        } else if (std.mem.eql(u8, command, "eval")) {
            try printout(stdout, "{d} (from white's perspective)\n", .{pos[0].eval.eval(&pos[0], Color.White)});
        } else if (std.mem.eql(u8, command, "perft")) {
            const depth = try u32_from_str(words.next() orelse "1");
            const report = perft.perft_test(&pos[0], @as(u4, @intCast(depth)));
            const elapsed_nanos = @as(f64, @floatFromInt(report.time_elapsed));
            const elapsed_seconds = elapsed_nanos / 1_000_000_000;

            try printout(stdout, "{d:.3}s elapsed\n", .{elapsed_seconds});
            try printout(stdout, "{} nodes explored\n", .{report.nodes});

            const nps = @as(f64, @floatFromInt(report.nodes)) / elapsed_seconds;
            if (nps < 1000) {
                try printout(stdout, "{d:.3}N/s\n", .{nps});
            } else if (nps < 1_000_000) {
                try printout(stdout, "{d:.3}KN/s\n", .{nps / 1000});
            } else {
                try printout(stdout, "{d:.3}MN/s\n", .{nps / 1_000_000});
            }
        } else if (std.mem.eql(u8, command, "seepos")) {
            var list: MoveList = .{};

            if (pos[0].side_to_play == Color.White) {
                pos[0].generate_legals(Color.White, &list);
            } else {
                pos[0].generate_legals(Color.Black, &list);
            }

            try printout(stdout, "SEE thresholds\n", .{});

            for (0..list.count) |i| {
                const move = list.moves[i];
                const thr = ms.see_value(&pos[0], move, false);
                try printout(stdout, "{}. ", .{i});
                move.print();
                try printout(stdout, " SEE result: {}\n", .{thr});
            }
        } else if (std.mem.eql(u8, command[0..3], "see")) {
            const move_str = command[4..];
            const move = Move.parse_move(move_str, &pos[0]) catch continue; // Parse UCI move
            if (move.is_empty()) {
                try printout(stdout, "Invalid move format\n", .{});
                continue;
            }
            const see_val = ms.see_value(&pos[0], move, false);
            try printout(stdout, "\nsee_value {}\n", .{see_val});
        } else if (use_tb and std.mem.eql(u8, command, "probe")) {
            const total_pieces = bb.pop_count(pos[0].all_pieces(Color.White) | pos[0].all_pieces(Color.Black));
            const has_castling_rights: bool = (pos[0].history[pos[0].game_ply].castling > 0);

            if (has_castling_rights) {
                _ = try printout(stdout, "info string Probe failed: Castling rights are still active.\n", .{});
            } else if (total_pieces > fathom.get_tb_largest()) {
                _ = try printout(stdout, "info string Probe failed: Too many pieces ({d}) for largest TB ({d}p).\n", .{ total_pieces, fathom.get_tb_largest() });
            } else {
                const wdl_result = fathom.probeWDL(&pos[0], fathom.tb_probe_depth + 1);
                if (wdl_result == fathom.TB_RESULT_FAILED) {
                    _ = try printout(stdout, "info string WDL Probe Result: Probe failed (position not found in tablebases or other error)\n", .{});
                } else {
                    var result_str: []const u8 = "";
                    if (wdl_result == 0) {
                        result_str = "Loss";
                    } else if (wdl_result == 1) {
                        result_str = "Draw: Loss (blessed)";
                    } else if (wdl_result == 2) {
                        result_str = "Draw";
                    } else if (wdl_result == 3) {
                        result_str = "Draw: Win (cursed)";
                    } else if (wdl_result == 4) {
                        result_str = "Win";
                    } else {
                        result_str = "Unknown Result Code";
                    }
                    _ = try printout(stdout, "info string WDL Probe Result: {s} (Code: {d})\n", .{ result_str, wdl_result });
                }
            }
        } else if (use_tb and std.mem.eql(u8, command, "probebest")) {
            const total_pieces = bb.pop_count(pos[0].all_pieces(Color.White) | pos[0].all_pieces(Color.Black));
            const has_castling_rights: bool = (pos[0].history[pos[0].game_ply].castling > 0);

            // Check if the position meets the criteria for probing
            if (has_castling_rights) {
                _ = try printout(stdout, "info string Probe failed: Castling rights are still active.\n", .{});
            } else if (total_pieces > fathom.get_tb_largest()) {
                _ = try printout(stdout, "info string Probe failed: Too many pieces ({d}) for largest TB ({d}p).\n", .{ total_pieces, fathom.get_tb_largest() });
            } else {
                const wdl_result = fathom.probeWDL(&pos[0], fathom.tb_probe_depth + 1);
                if (wdl_result == fathom.TB_RESULT_FAILED) {
                    _ = try printout(stdout, "info string WDL Probe Result: Probe failed (position not found in tablebases or other error)\n", .{});
                } else {
                    var result_str: []const u8 = "";
                    if (wdl_result == fathom.TB_LOSS) {
                        result_str = "Loss";
                    } else if (wdl_result == fathom.TB_BLESSED_LOSS) {
                        result_str = "Draw: Loss (blessed)";
                    } else if (wdl_result == fathom.TB_DRAW) {
                        result_str = "Draw";
                    } else if (wdl_result == fathom.TB_CURSED_WIN) {
                        result_str = "Draw: Win (cursed)";
                    } else if (wdl_result == fathom.TB_WIN) {
                        result_str = "Win";
                    } else {
                        result_str = "Unknown Result Code";
                    }
                    _ = try printout(stdout, "info string WDL Probe Result: {s} (Code: {d})\n", .{ result_str, wdl_result });

                    // Probe for best move
                    const TB_MAX_MOVES: usize = 64;
                    var results: [TB_MAX_MOVES]fathom.Move = undefined;
                    const probe_result = fathom.probeRoot(&pos[0], results[0..], fathom.tb_probe_depth + 1);
                    const dtz_result = probe_result.result;
                    const valid_move_count = probe_result.move_count;

                    if (dtz_result == fathom.TB_RESULT_FAILED) {
                        _ = try printout(stdout, "info string Best Move Probe: Failed (DTZ code: {d})\n", .{dtz_result});
                    } else if (dtz_result == fathom.TB_RESULT_CHECKMATE) {
                        _ = try printout(stdout, "info string Best Move: Checkmate\n", .{});
                        _ = try printout(stdout, "bestmove (none)\n", .{});
                    } else if (dtz_result == fathom.TB_RESULT_STALEMATE) {
                        _ = try printout(stdout, "info string Best Move: Stalemate\n", .{});
                        _ = try printout(stdout, "bestmove (none)\n", .{});
                    } else {
                        // Extract move details from the result
                        const from_sq = fathom.getFrom(dtz_result);
                        const to_sq = fathom.getTo(dtz_result);
                        const promo = fathom.getPromotes(dtz_result);
                        const ep = fathom.getEP(dtz_result);
                        const dtz = fathom.getDTZ(dtz_result);
                        const wdl = fathom.getWDL(dtz_result);

                        // Reconstruct the best move
                        var best_move: fathom.Move = @as(fathom.Move, from_sq) | (@as(fathom.Move, to_sq) << 6) | (@as(fathom.Move, promo) << 12);
                        if (ep != 0) {
                            best_move |= @as(fathom.Move, 1) << 19;
                        }

                        const best_move_uci = try fathom.moveToUCI(best_move, allocator);
                        defer allocator.free(best_move_uci);

                        var signed_dtz: i32 = @as(i32, @intCast(dtz));
                        // Apply sign based on WDL result
                        if (wdl == fathom.TB_LOSS or wdl == fathom.TB_BLESSED_LOSS) {
                            signed_dtz = -signed_dtz;
                        } else if (wdl == fathom.TB_WIN or wdl == fathom.TB_CURSED_WIN) {
                            signed_dtz = signed_dtz;
                        } else {
                            signed_dtz = 0; // draw
                        }

                        const dtz_str = try std.fmt.allocPrint(allocator, "{s}", .{if (signed_dtz > 0)
                            try std.fmt.allocPrint(allocator, "Win in {d} moves (DTZ)", .{signed_dtz})
                        else if (signed_dtz < 0)
                            try std.fmt.allocPrint(allocator, "Loss in {d} moves (DTZ)", .{-signed_dtz}) // Show positive number in text
                        else
                            try std.fmt.allocPrint(allocator, "Draw (DTZ=0)", .{})});
                        defer allocator.free(dtz_str);

                        var wdl_str: []const u8 = undefined;
                        if (wdl == fathom.TB_LOSS) {
                            wdl_str = "Loss";
                        } else if (wdl == fathom.TB_BLESSED_LOSS) {
                            wdl_str = "Draw: Loss (blessed)";
                        } else if (wdl == fathom.TB_DRAW) {
                            wdl_str = "Draw";
                        } else if (wdl == fathom.TB_CURSED_WIN) {
                            wdl_str = "Draw: Win (cursed)";
                        } else if (wdl == fathom.TB_WIN) {
                            wdl_str = "Win";
                        } else {
                            wdl_str = "Unknown";
                        }

                        _ = try printout(stdout, "info string Best Move: {s} ({s}, WDL: {s})\n", .{ best_move_uci, dtz_str, wdl_str });

                        // Print additional candidate moves
                        if (valid_move_count > 0) {
                            _ = try printout(stdout, "info string Additional moves ({d} total): ", .{valid_move_count});
                            var printed = false;
                            for (results[0..valid_move_count]) |cand_move| {
                                if (cand_move == best_move) continue; // Skip the best move
                                const cand_uci = try fathom.moveToUCI(cand_move, allocator);
                                defer allocator.free(cand_uci);
                                if (printed) _ = try printout(stdout, " ", .{});
                                _ = try printout(stdout, "{s}", .{cand_uci});
                                printed = true;
                            }
                            _ = try printout(stdout, "\n", .{});
                        }

                        // Output UCI-compliant best move
                        _ = try printout(stdout, "bestmove {s}\n", .{best_move_uci});
                    }
                }
            }
        }
    }

    if (main_search_thread != null) {
        @atomicStore(bool, &thinkers[0].stop, true, .seq_cst);
        main_search_thread.?.join();
    }
}

pub fn bench(allocator: std.mem.Allocator, depth: u32) !void {
    const bench_pos = [_][]const u8{
        "r3qb1k/1b4p1/p2pr2p/3n4/Pnp1N1N1/6RP/1B3PP1/1B1QR1K1 w - - 0 1",
        "r4rk1/pp1n1p1p/1nqP2p1/2b1P1B1/4NQ2/1B3P2/PP2K2P/2R5 w - - 0 1",
        "r2qk2r/ppp1b1pp/2n1p3/3pP1n1/3P2b1/2PB1NN1/PP4PP/R1BQK2R w KQkq - 0 1",
        "r1b1kb1r/1p1n1ppp/p2ppn2/6BB/2qNP3/2N5/PPP2PPP/R2Q1RK1 w kq - 0 1",
        "r2qrb1k/1p1b2p1/p2ppn1p/8/3NP3/1BN5/PPP3QP/1K3RR1 w - - 0 1",
        "rnbqk2r/1p3ppp/p7/1NpPp3/QPP1P1n1/P4N2/4KbPP/R1B2B1R b kq - 0 1 ",
        "1r1bk2r/2R2ppp/p3p3/1b2P2q/4QP2/4N3/1B4PP/3R2K1 w k - 0 1",
        "r3rbk1/ppq2ppp/2b1pB2/8/6Q1/1P1B3P/P1P2PP1/R2R2K1 w - - 0 1",
        "r4r1k/4bppb/2n1p2p/p1n1P3/1p1p1BNP/3P1NP1/qP2QPB1/2RR2K1 w - - 0 1",
        "r1b2rk1/1p1nbppp/pq1p4/3B4/P2NP3/2N1p3/1PP3PP/R2Q1R1K w - - 0 1",
        "r1b3k1/p2p1nP1/2pqr1Rp/1p2p2P/2B1PnQ1/1P6/P1PP4/1K4R1 w - - 0 1",
        "1k1r4/pp1b1R2/3q2pp/4p3/2B5/4Q3/PPP2B2/2K5 b - - 0 1",
        "3r1k2/4npp1/1ppr3p/p6P/P2PPPP1/1NR5/5K2/2R5 w - - 0 1",
        "2q1rr1k/3bbnnp/p2p1pp1/2pPp3/PpP1P1P1/1P2BNNP/2BQ1PRK/7R b - - 0 1",
        "rnbqkb1r/p3pppp/1p6/2ppP3/3N4/2P5/PPP1QPPP/R1B1KB1R w KQkq - 0 1",
        "r1b2rk1/2q1b1pp/p2ppn2/1p6/3QP3/1BN1B3/PPP3PP/R4RK1 w - - 0 1",
        "2r3k1/pppR1pp1/4p3/4P1P1/5P2/1P4K1/P1P5/8 w - - 0 1",
        "1nk1r1r1/pp2n1pp/4p3/q2pPp1N/b1pP1P2/B1P2R2/2P1B1PP/R2Q2K1 w - - 0 1",
        "4b3/p3kp2/6p1/3pP2p/2pP1P2/4K1P1/P3N2P/8 w - - 0 1",
        "2kr1bnr/pbpq4/2n1pp2/3p3p/3P1P1B/2N2N1Q/PPP3PP/2KR1B1R w - - 0 1",
        "3rr1k1/pp3pp1/1qn2np1/8/3p4/PP1R1P2/2P1NQPP/R1B3K1 b - - 0 1",
        "2r1nrk1/p2q1ppp/bp1p4/n1pPp3/P1P1P3/2PBB1N1/4QPPP/R4RK1 w - - 0 1",
        "r3r1k1/ppqb1ppp/8/4p1NQ/8/2P5/PP3PPP/R3R1K1 b - - 0 1",
        "r2q1rk1/4bppp/p2p4/2pP4/3pP3/3Q4/PP1B1PPP/R3R1K1 w - - 0 1",
        "rnb2r1k/pp2p2p/2pp2p1/q2P1p2/8/1Pb2NP1/PB2PPBP/R2Q1RK1 w - - 0 1",
        "2r3k1/1p2q1pp/2b1pr2/p1pp4/6Q1/1P1PP1R1/P1PN2PP/5RK1 w - - 0 1",
        "r1bqkb1r/4npp1/p1p4p/1p1pP1B1/8/1B6/PPPN1PPP/R2Q1RK1 w kq - 0 1",
        "r2q1rk1/1ppnbppp/p2p1nb1/3Pp3/2P1P1P1/2N2N1P/PPB1QP2/R1B2RK1 b - - 0 1",
        "r1bq1rk1/pp2ppbp/2np2p1/2n5/P3PP2/N1P2N2/1PB3PP/R1B1QRK1 b - - 0 1",
        "3rr3/2pq2pk/p2p1pnp/8/2QBPP2/1P6/P5PP/4RRK1 b - - 0 1",
        "r4k2/pb2bp1r/1p1qp2p/3pNp2/3P1P2/2N3P1/PPP1Q2P/2KRR3 w - - 0 1",
        "3rn2k/ppb2rpp/2ppqp2/5N2/2P1P3/1P5Q/PB3PPP/3RR1K1 w - - 0 1",
        "2r2rk1/1bqnbpp1/1p1ppn1p/pP6/N1P1P3/P2B1N1P/1B2QPP1/R2R2K1 b - - 0 1",
        "r1bqk2r/pp2bppp/2p5/3pP3/P2Q1P2/2N1B3/1PP3PP/R4RK1 b kq - 0 1",
        "r2qnrnk/p2b2b1/1p1p2pp/2pPpp2/1PP1P3/PRNBB3/3QNPPP/5RK1 w - - 0 1",
        "rn1qkb1r/pp2pppp/5n2/3p1b2/3P4/2N1P3/PP3PPP/R1BQKBNR w KQkq - 0 1",
        "rn1qkb1r/pp2pppp/5n2/3p1b2/3P4/1QN1P3/PP3PPP/R1B1KBNR b KQkq - 1 1",
        "r1bqk2r/ppp2ppp/2n5/4P3/2Bp2n1/5N1P/PP1N1PP1/R2Q1RK1 b kq - 1 10",
        "r1bqrnk1/pp2bp1p/2p2np1/3p2B1/3P4/2NBPN2/PPQ2PPP/1R3RK1 w - - 1 12",
        "rnbqkb1r/ppp1pppp/5n2/8/3PP3/2N5/PP3PPP/R1BQKBNR b KQkq - 3 5",
        "rnbq1rk1/pppp1ppp/4pn2/8/1bPP4/P1N5/1PQ1PPPP/R1B1KBNR b KQ - 1 5",
        "r4rk1/3nppbp/bq1p1np1/2pP4/8/2N2NPP/PP2PPB1/R1BQR1K1 b - - 1 12",
        "rn1qkb1r/pb1p1ppp/1p2pn2/2p5/2PP4/5NP1/PP2PPBP/RNBQK2R w KQkq c6 1 6",
        "r1bq1rk1/1pp2pbp/p1np1np1/3Pp3/2P1P3/2N1BP2/PP4PP/R1NQKB1R b KQ - 1 9",
        "rnbqr1k1/1p3pbp/p2p1np1/2pP4/4P3/2N5/PP1NBPPP/R1BQ1RK1 w - - 1 11",
        "rnbqkb1r/pppp1ppp/5n2/4p3/4PP2/2N5/PPPP2PP/R1BQKBNR b KQkq f3 1 3",
        "r1bqk1nr/pppnbppp/3p4/8/2BNP3/8/PPP2PPP/RNBQK2R w KQkq - 2 6",
        "rnbq1b1r/ppp2kpp/3p1n2/8/3PP3/8/PPP2PPP/RNBQKB1R b KQ d3 1 5",
        "rnbqkb1r/pppp1ppp/3n4/8/2BQ4/5N2/PPP2PPP/RNB2RK1 b kq - 1 6",
        "r2q1rk1/2p1bppp/p2p1n2/1p2P3/4P1b1/1nP1BN2/PP3PPP/RN1QR1K1 w - - 1 12",
        "r1bqkb1r/2pp1ppp/p1n5/1p2p3/3Pn3/1B3N2/PPP2PPP/RNBQ1RK1 b kq - 2 7",
        "r2qkbnr/2p2pp1/p1pp4/4p2p/4P1b1/5N1P/PPPP1PP1/RNBQ1RK1 w kq - 1 8",
        "r1bqkb1r/pp3ppp/2np1n2/4p1B1/3NP3/2N5/PPP2PPP/R2QKB1R w KQkq e6 1 7",
        "rn1qk2r/1b2bppp/p2ppn2/1p6/3NP3/1BN5/PPP2PPP/R1BQR1K1 w kq - 5 10",
        "r1b1kb1r/1pqpnppp/p1n1p3/8/3NP3/2N1B3/PPP1BPPP/R2QK2R w KQkq - 3 8",
        "r1bqnr2/pp1ppkbp/4N1p1/n3P3/8/2N1B3/PPP2PPP/R2QK2R b KQ - 2 11",
        "r3kb1r/pp1n1ppp/1q2p3/n2p4/3P1Bb1/2PB1N2/PPQ2PPP/RN2K2R w KQkq - 3 11",
        "r1bq1rk1/pppnnppp/4p3/3pP3/1b1P4/2NB3N/PPP2PPP/R1BQK2R w KQ - 3 7",
        "r2qkbnr/ppp1pp1p/3p2p1/3Pn3/4P1b1/2N2N2/PPP2PPP/R1BQKB1R w KQkq - 2 6",
        "rn2kb1r/pp2pppp/1qP2n2/8/6b1/1Q6/PP1PPPBP/RNB1K1NR b KQkq - 1 6",
        "r2r2k1/pp1b1ppp/8/3p2P1/3N4/P3P3/1P3P1P/3RK2R b K - 0 1",
        "r3k2r/1b1nb1p1/p1q1pn1p/1pp3N1/4PP2/2N5/PPB3PP/R1BQ1RK1 w kq - 0 1",
        "r3k2r/1pqnnppp/p5b1/1PPp1p2/3P4/2N5/P2NB1PP/2RQ1RK1 b kq - 0 1",
        "r3k2r/p1q1nppp/1pn5/2P1p3/4P1Q1/P1P2P2/4N1PP/R1B2K1R b kq - 0 1",
        "r3k2r/pp2pp1p/6p1/2nP4/1R2PB2/4PK2/P5PP/5bNR w kq - 0 1",
        "r3k2r/ppp1bppp/2n5/3n4/3PB3/8/PP3PPP/RNB1R1K1 b kq - 0 1",
        "r3kb1r/pp3ppp/4bn2/3p4/P7/4N1P1/1P2PPBP/R1B1K2R w KQkq - 0 1",
        "r3kbnr/1pp3pp/p1p2p2/8/3qP3/5Q1P/PP3PP1/RNB2RK1 w kq - 0 1",
        "r3kr2/pppb1p2/2n3p1/3Bp2p/4P2N/2P5/PP3PPP/2KR3R b q - 0 1",
        "r3nrk1/pp2qpb1/3p1npp/2pPp3/2P1P2N/2N3Pb/PP1BBP1P/R2Q1RK1 w - - 0 1",
        "r3r1k1/1pqn1pbp/p2p2p1/2nP2B1/P1P1P3/2NB3P/5PP1/R2QR1K1 w - - 0 1",
        "r3r1k1/pp1q1ppp/2p5/P2n1p2/1b1P4/1B2PP2/1PQ3PP/R1B2RK1 w - - 0 1",
        "r3r1k1/pp3ppp/2ppqn2/5R2/2P5/2PQP1P1/P2P2BP/5RK1 w - - 0 1",
        "r3rbk1/p2b1p2/5p1p/1q1p4/N7/6P1/PP1BPPBP/3Q1RK1 w - - 0 1",
        "r4r1k/pp1bq1b1/n2p2p1/2pPp1Np/2P4P/P1N1BP2/1P1Q2P1/2KR3R w - - 0 1",
        "r4rk1/1bqp1ppp/pp2pn2/4b3/P1P1P3/2N2BP1/1PQB1P1P/2R2RK1 w - - 0 1",
        "r4rk1/1q2bppp/p1bppn2/8/3BPP2/3B2Q1/1PP1N1PP/4RR1K w - - 0 1",
        "r4rk1/pp2qpp1/2pRb2p/4P3/2p5/2Q1PN2/PP3PPP/4K2R w K - 0 1",
        "r7/3rq1kp/2p1bpp1/p1Pnp3/2B4P/PP4P1/1B1RQP2/2R3K1 b - - 0 1",
        "r7/pp1bpp2/1n1p2pk/1B3P2/4P1P1/2N5/PPP5/1K5R b - - 0 1",
        "rn1q1rk1/p4pbp/bp1p1np1/2pP4/8/P1N2NP1/1PQ1PPBP/R1B1K2R w KQ - 0 1",
        "rn1q1rk1/pb3p2/1p5p/3n2P1/3p4/P4P2/1P1Q1BP1/R3KBNR b KQ - 0 1",
        "rn1q1rk1/pp2bppp/1n2p1b1/8/2pPP3/1BN1BP2/PP2N1PP/R2Q1RK1 w - - 0 1",
        "rn1q1rk1/pp3ppp/4bn2/2bp4/5B2/2NBP1N1/PP3PPP/R2QK2R w KQ - 0 1",
        "rn1qkbnr/pp1b1ppp/8/1Bpp4/3P4/8/PPPNQPPP/R1B1K1NR b KQkq - 0 1",
        "r3kb1r/3n1pp1/p6p/2pPp2q/Pp2N3/3B2PP/1PQ2P2/R3K2R w KQkq - 0 1",
        "1k1r3r/pp2qpp1/3b1n1p/3pNQ2/2pP1P2/2N1P3/PP4PP/1K1RR3 b - - 0 1",
        "r6k/pp4p1/2p1b3/3pP3/7q/P2B3r/1PP2Q1P/2K1R1R1 w - - 0 1",
        "1nr5/2rbkppp/p3p3/Np6/2PRPP2/8/PKP1B1PP/3R4 b - - 0 1",
        "2r2rk1/1p1bq3/p3p2p/3pPpp1/1P1Q4/P7/2P2PPP/2R1RBK1 b - - 0 1",
        "3r1bk1/p4ppp/Qp2p3/8/1P1B4/Pq2P1P1/2r2P1P/R3R1K1 b - - 0 1",
        "r1b2r1k/pp2q1pp/2p2p2/2p1n2N/4P3/1PNP2QP/1PP2RP1/5RK1 w - - 0 1",
        "r2qrnk1/pp3ppb/3b1n1p/1Pp1p3/2P1P2N/P5P1/1B1NQPBP/R4RK1 w - - 0 1",
        "5nk1/Q4bpp/5p2/8/P1n1PN2/q4P2/6PP/1R4K1 w - - 0 1",
        "r3k2r/3bbp1p/p1nppp2/5P2/1p1NP3/5NP1/PPPK3P/3R1B1R b kq - 0 1",
        "bn6/1q4n1/1p1p1kp1/2pPp1pp/1PP1P1P1/3N1P1P/4B1K1/2Q2N2 w - - 0 1",
        "3r2k1/pp2npp1/2rqp2p/8/3PQ3/1BR3P1/PP3P1P/3R2K1 b - - 0 1",
        "1r2r1k1/4ppbp/B5p1/3P4/pp1qPB2/2n2Q1P/P4PP1/4RRK1 b - - 0 1",
        "r2qkb1r/1b3ppp/p3pn2/1p6/1n1P4/1BN2N2/PP2QPPP/R1BR2K1 w kq - 0 1",
        "1r4k1/1q2bp2/3p2p1/2pP4/p1N4R/2P2QP1/1P3PK1/8 w - - 0 1",
        "rn3rk1/pbppq1pp/1p2pb2/4N2Q/3PN3/3B4/PPP2PPP/R3K2R w KQ - 0 1",
        "4r1k1/3b1p2/5qp1/1BPpn2p/7n/r3P1N1/2Q1RPPP/1R3NK1 b - - 0 1",
        "2k2b1r/1pq3p1/2p1pp2/p1n1PnNp/2P2B2/2N4P/PP2QPP1/3R2K1 w - - 0 1",
        "2r2r2/3qbpkp/p3n1p1/2ppP3/6Q1/1P1B3R/PBP3PP/5R1K w - - 0 1",
        "2r1k2r/2pn1pp1/1p3n1p/p3PP2/4q2B/P1P5/2Q1N1PP/R4RK1 w q - 0 1",
        "2rr2k1/1b3ppp/pb2p3/1p2P3/1P2BPnq/P1N3P1/1B2Q2P/R4R1K b - - 0 1",
        "2b1r1k1/r4ppp/p7/2pNP3/4Q3/q6P/2P2PP1/3RR1K1 w - - 0 1",
        "6k1/5p2/3P2p1/7n/3QPP2/7q/r2N3P/6RK b - - 0 1",
        "rq2rbk1/6p1/p2p2Pp/1p1Rn3/4PB2/6Q1/PPP1B3/2K3R1 w - - 0 1",
        "rnbq2k1/p1r2p1p/1p1p1Pp1/1BpPn1N1/P7/2P5/6PP/R1B1QRK1 w - - 0 1",
        "r2qrb1k/1p1b2p1/p2ppn1p/8/3NP3/1BN5/PPP3QP/1K3RR1 w - - 0 1",
        "8/1p3pp1/7p/5P1P/2k3P1/8/2K2P2/8 w - - 0 1",
        "8/pp2r1k1/2p1p3/3pP2p/1P1P1P1P/P5KR/8/8 w - - 0 1",
        "8/3p4/p1bk3p/Pp6/1Kp1PpPp/2P2P1P/2P5/5B2 b - - 0 1",
        "5k2/7R/4P2p/5K2/p1r2P1p/8/8/8 b - - 0 1",
        "6k1/6p1/7p/P1N5/1r3p2/7P/1b3PP1/3bR1K1 w - - 0 1",
        "8/3b4/5k2/2pPnp2/1pP4N/pP1B2P1/P3K3/8 b - - 0 1",
        "6k1/4pp1p/3p2p1/P1pPb3/R7/1r2P1PP/3B1P2/6K1 w - - 0 1",
        "2k5/p7/Pp1p1b2/1P1P1p2/2P2P1p/3K3P/5B2/8 w - - 0 1",
        "8/5Bp1/4P3/6pP/1b1k1P2/5K2/8/8 w - - 0 1",
    };

    try init_all(allocator);

    //nnue.engine_using_nnue = false;
    if (nnue.engine_using_nnue) {
        try nnue.embed_and_init();
        nnue.engine_loaded_net = true;
    }

    try tt.TT.init(128 + 1);
    defer tt.TT.deinit();

    var curr_pos = Position.new();

    thinkers[0] = Search.new();
    thinkers[0].clear_for_new_game();
    thinkers[0].manager = search.SearchManager.new();
    thinkers[0].max_depth = depth;
    thinkers[0].manager.configure(&curr_pos);
    thinkers[0].manager.printout = false;

    var nodes: u64 = 0;
    var timer = std.time.Timer.start() catch unreachable;

    //for (bench_pos, 1..) |fen, i| {
    for (bench_pos) |fen| {
        // Set up position

        thinkers[0].clear_for_new_game();
        tt.TT.clear();
        try curr_pos.set(fen);
        thinkers[0].max_depth = depth;

        //std.debug.print("{d}: {s}\n", .{ i, fen });

        if (curr_pos.side_to_play == Color.White) {
            thinkers[0].iterative_deepening(&curr_pos, Color.White);
        } else {
            thinkers[0].iterative_deepening(&curr_pos, Color.Black);
        }

        nodes += thinkers[0].nodes;
    }

    const elapsed = timer.read();

    const elapsed_nanos = @as(f64, @floatFromInt(elapsed));
    const elapsed_seconds = elapsed_nanos / 1_000_000_000;
    const nps: u46 = @intFromFloat(@as(f64, @floatFromInt(nodes)) / elapsed_seconds);

    const elapsed_ms: u32 = @intFromFloat(elapsed_nanos / 1_000_000);
    try printout(stdout, "{} nodes {} nps {} elapsed\n", .{ nodes, nps, elapsed_ms });
    //try printout(stdout, "{} nodes {} nps\n", .{ nodes, nps });
}

test "perft for positions" {
    // Initialize required databases
    attacks.initialise_all_databases();
    zobrist.initialise_zobrist_keys();

    const test_cases = [_][]const u8{
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1,20,400,8902,197281,4865609,119060324",
        "8/6b1/7r/Pk2p3/1n4Np/K1P1P3/1B6/1b6 b - - 0 1,33,377,10572,125127,3449824,41620286",
        "8/6b1/5N1r/Pk2p3/1n5p/K1P1P3/1B6/1b6 w - - 0 1,15,418,5061,133804,1609522,42418189",
        "rnbqkbnr/1ppppppp/8/p7/2P5/P7/1P1PPPPP/RNBQKBNR b KQkq - 0 1,21,441,10227,242685,6164778,161038368",
        "2bqkbnr/rppppppp/n7/p7/2P5/PP6/3PPPPP/RNBQKBNR w KQk - 0 1,19,398,8820,204573,5072498,129375227",
        "2bqkbnr/rpp1pppp/n2p4/p7/2P3P1/PP5P/3PPP2/RNBQKBNR b KQk - 0 1,26,470,13090,284308,8296635,202882781",
        "2kq4/4Q3/1n1p3b/r1NP1bpp/pPP2PP1/p3P2P/4K3/2R1NBR1 b - - 0 1,33,1452,43353,1829511,55661262,2275321404",
        "8/8/6P1/8/1kb4P/8/1K6/8 w - - 0 1,6,100,649,10016,77697,1114696",
        "8/8/6P1/8/2b4P/2k5/8/3K4 b - - 0 1,16,73,1091,6579,97531,769922",
        "8/8/4b1P1/7P/8/3k4/8/3K4 w - - 0 1,4,66,359,5458,42728,620333",
        "8/8/5k2/p1q1N1N1/PP1rp1P1/3P4/2RKp3/7r b - - 0 1,47,934,36151,744017,28368703,600039464",
        "8/6kN/8/2q1N3/Pp1rp1P1/3P4/2RKp3/7r w - - 0 1,19,861,15432,656842,12401507,507590831",
        "6B1/8/8/8/6k1/1p1p4/6K1/8 b - - 0 1,7,89,720,8957,80437,1023277",
        "6B1/8/8/8/7k/1p1p1K2/8/8 w - - 0 1,11,56,730,5198,69538,634670",
        "8/8/8/6k1/8/1B1p2K1/8/8 b - - 0 1,6,95,631,9412,74180,1036141",
        "k7/3K4/8/6n1/6p1/8/7r/8 w - - 0 1,7,163,801,17800,93543,2076111",
        "3k4/3P4/8/2P5/7R/1K6/8/4b1b1 w - - 0 1,21,298,5635,84820,1583235,24946858",
        "3Q4/4k3/8/2P5/1R6/1K6/8/4b1b1 b - - 0 1,3,96,1197,38271,515558,16572719",
        "3n4/2k2b2/8/3p2p1/8/3K4/8/1N6 w - - 0 1,9,152,1463,25573,252916,4522589",
        "8/5bk1/8/2Pp4/8/1K6/8/8 w - d6 0 1,8,104,736,9287,62297,824064",
        "8/8/1k6/8/2pP4/8/5BK1/8 b - d3 0 1,8,104,736,9287,62297,824064",
        "8/8/1k6/2b5/2pP4/8/5K2/8 b - d3 0 1,15,126,1928,13931,206379,1440467",
        "8/5k2/8/2Pp4/2B5/1K6/8/8 w - d6 0 1,15,126,1928,13931,206379,1440467",
        "5k2/8/8/8/8/8/8/4K2R w K - 0 1,,,,,,661072",
        "4k2r/8/8/8/8/8/8/5K2 b k - 0 1,,,,,,661072",
        "3k4/8/8/8/8/8/8/R3K3 w Q - 0 1,,,,,,803711",
        "r3k3/8/8/8/8/8/8/3K4 b q - 0 1,,,,,,803711",
        "r3k2r/1b4bq/8/8/8/8/7B/R3K2R w KQkq - 0 1,,,,1274206",
        "r3k2r/7b/8/8/8/8/1B4BQ/R3K2R b KQkq - 0 1,,,,1274206",
        "r3k2r/8/3Q4/8/8/5q2/8/R3K2R b KQkq - 0 1,,,,1720476",
        "r3k2r/8/5Q2/8/8/3q4/8/R3K2R w KQkq - 0 1,,,,1720476",
        "2K2r2/4P3/8/8/8/8/8/3k4 w - - 0 1,,,,,,3821001",
        "3K4/8/8/8/8/8/4p3/2k2R2 b - - 0 1,,,,,,3821001",
        "8/8/1P2K3/8/2n5/1q6/8/5k2 b - - 0 1,,,,,1004658",
        "5K2/8/1Q6/2N5/8/1p2k3/8/8 w - - 0 1,,,,,1004658",
        "4k3/1P6/8/8/8/8/K7/8 w - - 0 1,,,,,,217342",
        "8/k7/8/8/8/8/1p6/4K3 b - - 0 1,,,,,,217342",
        "8/P1k5/K7/8/8/8/8/8 w - - 0 1,,,,,,92683",
        "8/8/8/8/8/k7/p1K5/8 b - - 0 1,,,,,,92683",
        "K1k5/8/P7/8/8/8/8/8 w - - 0 1,,,,,,2217",
        "8/8/8/8/8/p7/8/k1K5 b - - 0 1,,,,,,2217",
        "8/k1P5/8/1K6/8/8/8/8 w - - 0 1,,,,,,,567584",
        "8/8/8/8/1k6/8/K1p5/8 b - - 0 1,,,,,,,567584",
        "8/8/2k5/5q2/5n2/8/5K2/8 b - - 0 1,,,,23527",
        "8/5k2/8/5N2/5Q2/2K5/8/8 w - - 0 1,,,,23527",
    };

    std.debug.print("\n", .{});

    // Iterate over each test case
    for (test_cases) |test_case| {
        // Parse the test case
        var parts = std.mem.splitScalar(u8, test_case, ',');
        const fen = parts.next() orelse return error.InvalidTestCase;
        var expected_nodes: [7]?u64 = .{null} ** 7;

        // Parse node counts for depths 1 to 7
        inline for (0..7) |i| {
            if (parts.next()) |node_str| {
                if (node_str.len > 0) {
                    expected_nodes[i] = try std.fmt.parseInt(u64, node_str, 10);
                }
            }
        }

        // Set up position
        var curr_pos = Position.new();
        try curr_pos.set(fen);
        std.debug.print("Testing: {s}\n", .{fen});

        // Run perft for each depth with non-null expected nodes
        inline for (1..8) |depth| {
            if (expected_nodes[depth - 1]) |expected| {
                const report = perft.perft_test(&curr_pos, @as(u4, @intCast(depth)));
                if (report.nodes != expected) {
                    std.debug.print(
                        "Perft failed for FEN: {s}, depth: {d}, expected: {d}, got: {d}\n",
                        .{ fen, depth, expected, report.nodes },
                    );
                    try std.testing.expectEqual(expected, report.nodes);
                }
            }
        }
    }
}

test "SEE for positions" {
    // Initialize required databases
    attacks.initialise_all_databases();
    zobrist.initialise_zobrist_keys();

    // Define test cases: {fen, move, expected_see}
    const test_cases = [_]struct { fen: []const u8, move: []const u8, expected_see: i32 }{
        .{ .fen = "4R3/2r3p1/5bk1/1p1r3p/p2PR1P1/P1BK1P2/1P6/8 b - -", .move = "hxg4", .expected_see = 0 },
        .{ .fen = "4R3/2r3p1/5bk1/1p1r1p1p/p2PR1P1/P1BK1P2/1P6/8 b - -", .move = "hxg4", .expected_see = 0 },
        .{ .fen = "4r1k1/5pp1/nbp4p/1p2p2q/1P2P1b1/1BP2N1P/1B2QPPK/3R4 b - -", .move = "Bxf3", .expected_see = 0 },
        .{ .fen = "2r1r1k1/pp1bppbp/3p1np1/q3P3/2P2P2/1P2B3/P1N1B1PP/2RQ1RK1 b - -", .move = "dxe5", .expected_see = 100 },
        .{ .fen = "7r/5qpk/p1Qp1b1p/3r3n/BB3p2/5p2/P1P2P2/4RK1R w - -", .move = "Re8", .expected_see = 0 },
        .{ .fen = "6rr/6pk/p1Qp1b1p/2n5/1B3p2/5p2/P1P2P2/4RK1R w - -", .move = "Re8", .expected_see = -500 },
        .{ .fen = "7r/5qpk/2Qp1b1p/1N1r3n/BB3p2/5p2/P1P2P2/4RK1R w - -", .move = "Re8", .expected_see = -500 },
        .{ .fen = "6RR/4bP2/8/8/5r2/3K4/5p2/4k3 w - -", .move = "f8=Q", .expected_see = 200 },
        .{ .fen = "6RR/4bP2/8/8/5r2/3K4/5p2/4k3 w - -", .move = "f8=N", .expected_see = 200 },
        .{ .fen = "7R/4bP2/8/8/1q6/3K4/5p2/4k3 w - -", .move = "f8=R", .expected_see = -100 },
        .{ .fen = "8/4kp2/2npp3/1Nn5/1p2PQP1/7q/1PP1B3/4KR1r b - -", .move = "Rxf1+", .expected_see = 0 },
        .{ .fen = "8/4kp2/2npp3/1Nn5/1p2P1P1/7q/1PP1B3/4KR1r b - -", .move = "Rxf1+", .expected_see = 0 },
        .{ .fen = "2r2r1k/6bp/p7/2q2p1Q/3PpP2/1B6/P5PP/2RR3K b - -", .move = "Qxc1", .expected_see = 100 },
        .{ .fen = "r2qk1nr/pp2ppbp/2b3p1/2p1p3/8/2N2N2/PPPP1PPP/R1BQR1K1 w kq -", .move = "Nxe5", .expected_see = 100 },
        .{ .fen = "6r1/4kq2/b2p1p2/p1pPb3/p1P2B1Q/2P4P/2B1R1P1/6K1 w - -", .move = "Bxe5", .expected_see = 0 },
        .{ .fen = "3q2nk/pb1r1p2/np6/3P2Pp/2p1P3/2R4B/PQ3P1P/3R2K1 w - h6", .move = "gxh6", .expected_see = 0 },
        .{ .fen = "3q2nk/pb1r1p2/np6/3P2Pp/2p1P3/2R1B2B/PQ3P1P/3R2K1 w - h6", .move = "gxh6", .expected_see = 100 },
        .{ .fen = "2r4r/1P4pk/p2p1b1p/7n/BB3p2/2R2p2/P1P2P2/4RK2 w - -", .move = "Rxc8", .expected_see = 500 },
        .{ .fen = "2r5/1P4pk/p2p1b1p/5b1n/BB3p2/2R2p2/P1P2P2/4RK2 w - -", .move = "Rxc8", .expected_see = 500 },
        .{ .fen = "2r4k/2r4p/p7/2b2p1b/4pP2/1BR5/P1R3PP/2Q4K w - -", .move = "Rxc5", .expected_see = 300 },
        .{ .fen = "8/pp6/2pkp3/4bp2/2R3b1/2P5/PP4B1/1K6 w - -", .move = "Bxc6", .expected_see = -200 },
        .{ .fen = "4q3/1p1pr1k1/1B2rp2/6p1/p3PP2/P3R1P1/1P2R1K1/4Q3 b - -", .move = "Rxe4", .expected_see = -400 },
        .{ .fen = "4q3/1p1pr1kb/1B2rp2/6p1/p3PP2/P3R1P1/1P2R1K1/4Q3 b - -", .move = "Rxe4", .expected_see = 100 },
        .{ .fen = "6k1/1pp4p/p1pb4/6q1/3P1pRr/2P4P/PP1Br1P1/5RKN w - -", .move = "Rfxf4", .expected_see = -100 },
        .{ .fen = "5rk1/1pp2q1p/p1pb4/8/3P1NP1/2P5/1P1BQ1P1/5RK1 b - -", .move = "Bxf4", .expected_see = 0 },
        .{ .fen = "3r3k/3r4/2n1n3/8/3p4/2PR4/1B1Q4/3R3K w - -", .move = "Rxd4", .expected_see = -100 },
        .{ .fen = "1k1r4/1ppn3p/p4b2/4n3/8/P2N2P1/1PP1R1BP/2K1Q3 w - -", .move = "Nxe5", .expected_see = 100 },
        .{ .fen = "1k1r3q/1ppn3p/p4b2/4p3/8/P2N2P1/1PP1R1BP/2K1Q3 w - -", .move = "Nxe5", .expected_see = -200 },
        .{ .fen = "rnb2b1r/ppp2kpp/5n2/4P3/q2P3B/5R2/PPP2PPP/RN1QKB2 w Q -", .move = "Bxf6", .expected_see = 100 },
        .{ .fen = "r2q1rk1/2p1bppp/p2p1n2/1p2P3/4P1b1/1nP1BN2/PP3PPP/RN1QR1K1 b - -", .move = "Bxf3", .expected_see = 0 },
        .{ .fen = "r1bqkb1r/2pp1ppp/p1n5/1p2p3/3Pn3/1B3N2/PPP2PPP/RNBQ1RK1 b kq -", .move = "Nxd4", .expected_see = 0 },
        .{ .fen = "r1bq1r2/pp1ppkbp/4N1p1/n3P1B1/8/2N5/PPP2PPP/R2QK2R w KQ -", .move = "Nxg7", .expected_see = 0 },
        .{ .fen = "r1bq1r2/pp1ppkbp/4N1pB/n3P3/8/2N5/PPP2PPP/R2QK2R w KQ -", .move = "Nxg7", .expected_see = 300 },
        .{ .fen = "rnq1k2r/1b3ppp/p2bpn2/1p1p4/3N4/1BN1P3/PPP2PPP/R1BQR1K1 b kq -", .move = "Bxh2+", .expected_see = -200 },
        .{ .fen = "rn2k2r/1bq2ppp/p2bpn2/1p1p4/3N4/1BN1P3/PPP2PPP/R1BQR1K1 b kq -", .move = "Bxh2+", .expected_see = 100 },
        .{ .fen = "r2qkbn1/ppp1pp1p/3p1rp1/3Pn3/4P1b1/2N2N2/PPP2PPP/R1BQKB1R b KQq -", .move = "Bxf3", .expected_see = 100 },
        .{ .fen = "rnbq1rk1/pppp1ppp/4pn2/8/1bPP4/P1N5/1PQ1PPPP/R1B1KBNR b KQ -", .move = "Bxc3+", .expected_see = 0 },
        .{ .fen = "r4rk1/3nppbp/bq1p1np1/2pP4/8/2N2NPP/PP2PPB1/R1BQR1K1 b - -", .move = "Qxb2", .expected_see = -800 },
        .{ .fen = "r4rk1/1q1nppbp/b2p1np1/2pP4/8/2N2NPP/PP2PPB1/R1BQR1K1 b - -", .move = "Nxd5", .expected_see = -200 },
        .{ .fen = "1r3r2/5p2/4p2p/2k1n1P1/2PN1nP1/1P3P2/8/2KR1B1R b - -", .move = "Rxb3", .expected_see = -400 },
        .{ .fen = "1r3r2/5p2/4p2p/4n1P1/kPPN1nP1/5P2/8/2KR1B1R b - -", .move = "Rxb4", .expected_see = 100 },
        .{ .fen = "2r2rk1/5pp1/pp5p/q2p4/P3n3/1Q3NP1/1P2PP1P/2RR2K1 b - -", .move = "Rxc1", .expected_see = 0 },
        .{ .fen = "5rk1/5pp1/2r4p/5b2/2R5/6Q1/R1P1qPP1/5NK1 b - -", .move = "Bxc2", .expected_see = -100 },
        .{ .fen = "1r3r1k/p4pp1/2p1p2p/qpQP3P/2P5/3R4/PP3PP1/1K1R4 b - -", .move = "Qxa2+", .expected_see = -800 },
        .{ .fen = "1r5k/p4pp1/2p1p2p/qpQP3P/2P2P2/1P1R4/P4rP1/1K1R4 b - -", .move = "Qxa2+", .expected_see = 100 },
        .{ .fen = "r2q1rk1/1b2bppp/p2p1n2/1ppNp3/3nP3/P2P1N1P/BPP2PP1/R1BQR1K1 w - -", .move = "Nxe7+", .expected_see = 0 },
        .{ .fen = "rnbqrbn1/pp3ppp/3p4/2p2k2/4p3/3B1K2/PPP2PPP/RNB1Q1NR w - -", .move = "Bxe4+", .expected_see = 100 },
        .{ .fen = "rnb1k2r/p3p1pp/1p3p1b/7n/1N2N3/3P1PB1/PPP1P1PP/R2QKB1R w KQkq -", .move = "Nd6+", .expected_see = -200 },
        .{ .fen = "r1b1k2r/p4npp/1pp2p1b/7n/1N2N3/3P1PB1/PPP1P1PP/R2QKB1R w KQkq -", .move = "Nd6+", .expected_see = 0 },
        .{ .fen = "2r1k2r/pb4pp/5p1b/2KB3n/4N3/2NP1PB1/PPP1P1PP/R2Q3R w k -", .move = "Bc6+", .expected_see = -300 },
        .{ .fen = "2r1k2r/pb4pp/5p1b/2KB3n/1N2N3/3P1PB1/PPP1P1PP/R2Q3R w k -", .move = "Bc6+", .expected_see = 0 },
        .{ .fen = "2r1k3/pbr3pp/5p1b/2KB3n/1N2N3/3P1PB1/PPP1P1PP/R2Q3R w - -", .move = "Bc6+", .expected_see = -300 },
        .{ .fen = "5k2/p2P2pp/8/1pb5/1Nn1P1n1/6Q1/PPP4P/R3K1NR w KQ -", .move = "d8=Q", .expected_see = 800 },
        .{ .fen = "r4k2/p2P2pp/8/1pb5/1Nn1P1n1/6Q1/PPP4P/R3K1NR w KQ -", .move = "d8=Q", .expected_see = -100 },
        .{ .fen = "5k2/p2P2pp/1b6/1p6/1Nn1P1n1/8/PPP4P/R2QK1NR w KQ -", .move = "d8=Q", .expected_see = 200 },
        .{ .fen = "4kbnr/p1P1pppp/b7/4q3/7n/8/PP1PPPPP/RNBQKBNR w KQk -", .move = "c8=Q", .expected_see = -100 },
        .{ .fen = "4kbnr/p1P1pppp/b7/4q3/7n/8/PPQPPPPP/RNB1KBNR w KQk -", .move = "c8=Q", .expected_see = 200 },
        .{ .fen = "4kbnr/p1P4p/b1q5/5pP1/4n3/5Q2/PP1PPP1P/RNB1KBNR w KQk f6", .move = "gxf6", .expected_see = 0 },
        .{ .fen = "1n2kb1r/p1P4p/2qb4/5pP1/4n2Q/8/PP1PPP1P/RNB1KBNR w KQk -", .move = "cxb8=Q", .expected_see = 200 },
        .{ .fen = "rnbqk2r/pp3ppp/2p1pn2/3p4/3P4/N1P1BN2/PPB1PPPb/R2Q1RK1 w kq -", .move = "Kxh2", .expected_see = 300 },
        .{ .fen = "3N4/2K5/2n5/1k6/8/8/8/8 b - -", .move = "Nxd8", .expected_see = 0 },
        .{ .fen = "3N4/2P5/2n5/1k6/8/8/8/4K3 b - -", .move = "Nxd8", .expected_see = -800 },
        .{ .fen = "3n3r/2P5/8/1k6/8/8/3Q4/4K3 w - -", .move = "Qxd8", .expected_see = 300 },
        .{ .fen = "3n3r/2P5/8/1k6/8/8/3Q4/4K3 w - -", .move = "cxd8=Q", .expected_see = 700 },
        .{ .fen = "r2n3r/2P1P3/4N3/1k6/8/8/8/4K3 w - -", .move = "Nxd8", .expected_see = 300 },
        .{ .fen = "8/8/8/1k6/6b1/4N3/2p3K1/3n4 w - -", .move = "Nxd1", .expected_see = -800 },
        .{ .fen = "8/8/1k6/8/8/2N1N3/2p1p1K1/3n4 w - -", .move = "Ncxd1", .expected_see = -800 },
        .{ .fen = "8/8/1k6/8/8/2N1N3/4p1K1/3n4 w - -", .move = "Ncxd1", .expected_see = 100 },
        .{ .fen = "r1bqk1nr/pppp1ppp/2n5/1B2p3/1b2P3/5N2/PPPP1PPP/RNBQK2R w KQkq -", .move = "O-O", .expected_see = 0 },
    };

    std.debug.print("\n", .{});
    // Iterate over each test case
    for (test_cases) |test_case| {
        // Set up position
        var curr_pos = Position.new();
        try curr_pos.set(test_case.fen);

        // const uci_move = try algebraic_to_uci(test_case.move, &curr_pos);
        // defer std.testing.allocator.free(uci_move);
        // //std.debug.print("algebraic: {s}, uci: {s}\n", .{ test_case.move, uci_move });

        // Parse the UCI move
        const move = Move.parse_alg_move(test_case.move, &curr_pos) catch {
            std.debug.print("Invalid move format for FEN: {s}, move: {s}\n", .{ test_case.fen, test_case.move });
            return error.InvalidMove;
        };
        if (move.is_empty()) {
            std.debug.print("Empty move for FEN: {s}, move: {s}\n", .{ test_case.fen, test_case.move });
            return error.EmptyMove;
        }

        // Compute SEE
        const see_val = ms.see_value(&curr_pos, move, false);

        // Compare with expected
        if (see_val != test_case.expected_see) {
            std.debug.print(
                "SEE failed for FEN: {s}, move: {s}, expected: {d}, got: {d}\n",
                .{ test_case.fen, test_case.move, test_case.expected_see, see_val },
            );
            try std.testing.expectEqual(test_case.expected_see, see_val);
        }
    }
}
