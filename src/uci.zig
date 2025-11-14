const std = @import("std");
const perft = @import("perft.zig");
const position = @import("position.zig");
const evaluation = @import("evaluation.zig");
const tt = @import("tt.zig");
const attacks = @import("attacks.zig");
const zobrist = @import("zobrist.zig");
const search = @import("search.zig");
const ms = @import("movescorer.zig");
const datagen = @import("datagen.zig");
const nnue = @import("nnue.zig");
const bb = @import("bitboard.zig");
const lists = @import("lists.zig");
const fathom = @import("fathom.zig");
const search_params = @import("search_params.zig");

pub const use_tb = @import("config").use_tb;

const Position = position.Position;
const Color = position.Color;
const Move = position.Move;
const Piece = position.Piece;
const Rank = position.Rank;
const Square = position.Square;
const Castling = position.Castling;
const Search = search.Search;

const MoveList = lists.MoveList;

const UCI_COMMAND_MAX_LENGTH = 5000;

var buffer = [1]u8{0} ** UCI_COMMAND_MAX_LENGTH;
var stdout_buffer = [1]u8{0} ** UCI_COMMAND_MAX_LENGTH;
var stdin_reader: std.fs.File.Reader = undefined;
var stdout_writer: std.fs.File.Writer = undefined;
var stdin: *std.Io.Reader = undefined;
pub var stdout: *std.Io.Writer = undefined;

// UCI options
var uci_chess960: bool = false; // Advertised to GUI; engine supports Chess960 from FEN

pub inline fn is_chess960() bool {
    return uci_chess960;
}

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

// Tracks whether a main search is currently running.
pub var search_running: bool = false;

// Allow internal users (e.g., datagen) to toggle Chess960 formatting
// without requiring an external UCI setoption roundtrip.
pub fn set_chess960_enabled(val: bool) void {
    uci_chess960 = val;
}

fn sync_position_chess960_state(curr_pos: *Position) void {
    if (curr_pos.is_chess960 and !uci_chess960) {
        uci_chess960 = true;
    }
    curr_pos.is_chess960 = uci_chess960;
}

pub fn printout(writer: *std.Io.Writer, comptime str: []const u8, args: anytype) void {
    writer.print(str, args) catch io_error();
    writer.flush() catch io_error();
}

fn io_error() noreturn { // Idea borowed from Eric Lang
    @panic("io error");
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

fn i32_from_str(str: []const u8) !i32 {
    return std.fmt.parseInt(i32, str, 10);
}

pub fn i8_from_str(str: []const u8) i8 {
    return std.fmt.parseInt(i8, std.mem.trim(u8, str, " "), 10) catch 0;
}

fn parse_and_apply_moves(curr_pos: *Position, moves_str: []const u8) !void {
    var it = std.mem.tokenizeAny(u8, moves_str, " \t\r\n");

    while (it.next()) |raw_tok| {
        const move_tok = std.mem.trim(u8, raw_tok, " \t\r\n");
        if (move_tok.len == 0) continue;
        const move = Move.parse_move(move_tok, curr_pos) catch |err| {
            printout(stdout, "info string Invalid move '{s}': {any}\n", .{ move_tok, err });
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

fn collect_rank_string(source_pos: *const Position, rank: Rank) [8]u8 {
    var buf: [8]u8 = undefined;
    const base: usize = @as(usize, rank.toU3()) * 8;
    for (0..8) |file| {
        const piece = source_pos.board[base + file];
        buf[file] = position.PIECE_STR[@as(usize, piece.toU4())];
    }
    return buf;
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

// Only define the functions on Windows
const windows = if (@import("builtin").os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
}) else struct {};

pub fn uci_loop(allocator: std.mem.Allocator) !void {
    try init_all(allocator);

    if (@import("builtin").os.tag == .windows) {
        _ = windows.SetConsoleCP(windows.CP_UTF8);
        _ = windows.SetConsoleOutputCP(windows.CP_UTF8);
    }

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

    // Mark engine as idle at startup so `isready` replies.

    @atomicStore(bool, &thinkers[0].stop, true, .seq_cst);

    var main_search_thread: ?std.Thread = null;

    mainloop: while (true) {

        //std.time.sleep(20 * 1000 * 1000);
        //std.Thread.sleep(1000);
        //const input_full = (try stdin.readUntilDelimiter(&buffer, '\n'));
        const input_full = try stdin.takeDelimiterExclusive('\n');
        if (input_full.len == 0) continue :mainloop;
        const input = std.mem.trimRight(u8, input_full, "\r");
        if (input.len == 0) continue :mainloop;

        var words = std.mem.splitScalar(u8, input, ' ');
        const command = words.next().?;

        if (std.mem.eql(u8, command, "uci")) {
            std.debug.print("uci command\n", .{});
            printout(stdout, "id name Lambergar 1.4\n", .{});
            printout(stdout, "id author Janez Podobnik\n", .{});
            printout(stdout, "option name Hash type spin default {d} min {d} max {d}\n", .{ HASH_SIZE_DEFAULT, HASH_SIZE_MIN, HASH_SIZE_MAX });
            printout(stdout, "option name Threads type spin default {d} min {d} max {d}\n", .{ 1, 1, MAX_THREADS });
            printout(stdout, "option name UseNNUE type check default {}\n", .{nnue.engine_using_nnue});
            printout(stdout, "option name UCI_Chess960 type check default {}\n", .{uci_chess960});
            //printout(stdout,"option name EvalFile type string default \n", .{});
            printout(stdout, "option name Debug type check default {}\n", .{debug});
            inline for (search_params.parameter_defs) |def| {
                printout(stdout, "option name {s} type spin default {d} min {d} max {d}\n", .{ def.name, def.default_value, def.min, def.max });
            }
            if (use_tb) {
                printout(stdout, "option name SyzygyPath type string default <empty>\n", .{});
                printout(stdout, "option name SyzygyProbeDepth type spin default {d} min {d} max {d}\n", .{ fathom.tb_probe_depth, 0, 127 });
            }
            printout(stdout, "uciok\n", .{});
        } else if (std.mem.eql(u8, command, "go")) {
            if (main_search_thread) |thread| {
                @atomicStore(bool, &thinkers[0].stop, true, .seq_cst);
                thread.join();
                main_search_thread = null;
                @atomicStore(bool, &search_running, false, .seq_cst);
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
                thinkers[i].manager.printout = false; // helpers never print
                // tag helpers with id/seed for slight diversification
                thinkers[i].thread_id = @as(u8, @intCast(i));
                thinkers[i].seed = 0x9e3779b9 * @as(u32, @intCast(i));
                pos[i] = pos[0].copy();
                const delta: i32 = @as(i32, 5 + @divFloor(@as(i32, @intCast(i)), 2) * 2);
                threads[i] = try std.Thread.spawn(.{}, search.start_search, .{ &thinkers[i], &pos[i], delta });
            }

            // Mark search as running before spawning the main search thread.

            @atomicStore(bool, &search_running, true, .seq_cst);

            main_search_thread = try std.Thread.spawn(.{}, search.start_main_search, .{ &thinkers[0], &pos[0] });
        } else if (std.mem.eql(u8, command, "quit") or std.mem.eql(u8, command, "exit")) {
            @atomicStore(bool, &thinkers[0].stop, true, .seq_cst);
            break :mainloop;
        } else if (std.mem.eql(u8, command, "stop")) {
            //thinker.stop = true;
            @atomicStore(bool, &thinkers[0].stop, true, .seq_cst);
        } else if (std.mem.eql(u8, command, "isready")) {

            // Reply if engine is idle (no search running)

            // or if a stop was explicitly requested.

            const running = @atomicLoad(bool, &search_running, .seq_cst);

            const stopped = @atomicLoad(bool, &thinkers[0].stop, .seq_cst);

            if (!running or stopped or (main_search_thread == null)) {
                printout(stdout, "readyok\n", .{});
            }
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
                        printout(stdout, "Threads set to: {}\n", .{num_threads});
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
                } else if (std.mem.eql(u8, arg, "UCI_Chess960")) {
                    arg = words.next().?;

                    if (std.mem.eql(u8, arg, "value")) {
                        arg = words.next().?;

                        if (std.mem.eql(u8, arg, "true")) {
                            uci_chess960 = true;
                        } else if (std.mem.eql(u8, arg, "false")) {
                            uci_chess960 = false;
                        }
                        for (0..MAX_THREADS) |i| {
                            pos[i].is_chess960 = uci_chess960;
                        }

                        if (debug) {
                            std.debug.print("UCI_Chess960 = {}\n", .{uci_chess960});
                        }
                    } else continue;
                } else if (search_params.find_by_name(arg)) |param_id| {
                    arg = words.next().?;
                    if (std.mem.eql(u8, arg, "value")) {
                        const raw_token = words.next() orelse continue;
                        const raw_val = i32_from_str(raw_token) catch continue;
                        const result = search_params.set_by_id(param_id, raw_val);
                        if (result.changed and param_id == search_params.ParameterId.lmr_log_scale) {
                            search.init_lmr();
                        }
                        const def = search_params.parameter_defs[@intFromEnum(param_id)];
                        printout(stdout, "info string {s} = {d}\n", .{ def.name, result.value });
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

                        const new_path = words.next() orelse null;
                        if (new_path == null or std.mem.eql(u8, new_path.?, "<empty>")) {
                            syzygy_path = null;
                            _ = printout(stdout, "info string SyzygyPath cleared.\n", .{});
                        } else {
                            // Create a durable copy of the path
                            syzygy_path = try allocator.dupe(u8, new_path.?);
                            _ = printout(stdout, "info string SyzygyPath set to: {s}\n", .{syzygy_path.?});
                        }

                        fathom.free_tablebases();
                        fathom.init_tablebases(allocator, syzygy_path) catch |err| {
                            _ = printout(stdout, "info string Failed to initialize Syzygy with new path: {any}\n", .{err});
                        };
                    } else continue;
                } else if (use_tb and std.mem.eql(u8, arg, "SyzygyProbeDepth")) {
                    arg = words.next().?;
                    if (std.mem.eql(u8, arg, "value")) {
                        const depth = i8_from_str(words.next() orelse continue);
                        if (depth < 0 or depth > 127) continue;
                        fathom.tb_probe_depth = depth;
                        _ = printout(stdout, "info string SyzygyProbeDepth set to: {d}\n", .{fathom.tb_probe_depth});
                    } else continue;
                } else continue;
            } else continue;
        } else if (std.mem.eql(u8, command, "ucinewgame")) {
            for (0..MAX_THREADS) |i| {
                thinkers[i].clear_for_new_game();
            }
            tt.TT.clear();
            try pos[0].set(start_position);
            sync_position_chess960_state(&pos[0]);
        } else if (std.mem.eql(u8, command, "position")) {
            const pos_variant = words.next() orelse {
                printout(stdout, "info string Missing position variant\n", .{});
                continue;
            };

            pos[0] = Position.new();
            if (std.mem.eql(u8, pos_variant, "fen")) {
                var parts = std.mem.splitSequence(u8, words.rest(), "moves");
                const fen = parts.next() orelse {
                    printout(stdout, "info string Missing FEN string\n", .{});
                    continue;
                };

                const fen_trim = std.mem.trim(u8, fen, " ");

                pos[0].set(fen_trim) catch |err| {
                    printout(stdout, "info string Invalid FEN: {s}\n", .{@errorName(err)});
                    continue; // or continue loop, depending on context
                };
                sync_position_chess960_state(&pos[0]);

                if (parts.rest().len > 0) {
                    try parse_and_apply_moves(&pos[0], parts.rest());
                }
            } else if (std.mem.eql(u8, pos_variant, "startpos")) {
                try pos[0].set(start_position);
                sync_position_chess960_state(&pos[0]);
                if (words.next()) |keyword| {
                    if (std.mem.eql(u8, keyword, "moves")) {
                        try parse_and_apply_moves(&pos[0], words.rest());
                    }
                }
            } else if (std.mem.eql(u8, pos_variant, "startposfrc")) {
                const idx_token = words.next() orelse {
                    printout(stdout, "info string Missing Chess960 index for startposfrc\n", .{});
                    continue;
                };

                const idx = std.fmt.parseInt(u16, idx_token, 10) catch {
                    printout(stdout, "info string Invalid Chess960 index '{s}'\n", .{idx_token});
                    continue;
                };

                pos[0].set_chess960_start(idx) catch |err| {
                    printout(stdout, "info string Failed to set Chess960 start: {any}\n", .{err});
                    continue;
                };
                sync_position_chess960_state(&pos[0]);

                const rank1 = collect_rank_string(&pos[0], Rank.RANK1);
                const rank8 = collect_rank_string(&pos[0], Rank.RANK8);
                printout(stdout, "info string {s} {s}\n", .{ rank1[0..], rank8[0..] });

                if (words.next()) |keyword| {
                    if (std.mem.eql(u8, keyword, "moves")) {
                        try parse_and_apply_moves(&pos[0], words.rest());
                    }
                }
            } else if (std.mem.eql(u8, pos_variant, "startposdfrc")) {
                const white_token = words.next() orelse {
                    printout(stdout, "info string Missing white DFRC index for startposdfrc\n", .{});
                    continue;
                };
                const black_token = words.next() orelse {
                    printout(stdout, "info string Missing black DFRC index for startposdfrc\n", .{});
                    continue;
                };

                const white_idx = std.fmt.parseInt(u16, white_token, 10) catch {
                    printout(stdout, "info string Invalid white DFRC index '{s}'\n", .{white_token});
                    continue;
                };
                const black_idx = std.fmt.parseInt(u16, black_token, 10) catch {
                    printout(stdout, "info string Invalid black DFRC index '{s}'\n", .{black_token});
                    continue;
                };

                pos[0].set_dfrc_start(white_idx, black_idx) catch |err| {
                    printout(stdout, "info string Failed to set DFRC start: {any}\n", .{err});
                    continue;
                };
                sync_position_chess960_state(&pos[0]);

                const rank1 = collect_rank_string(&pos[0], Rank.RANK1);
                const rank8 = collect_rank_string(&pos[0], Rank.RANK8);
                printout(stdout, "info string {s} {s}\n", .{ rank1[0..], rank8[0..] });

                if (words.next()) |keyword| {
                    if (std.mem.eql(u8, keyword, "moves")) {
                        try parse_and_apply_moves(&pos[0], words.rest());
                    }
                }
            } else {
                printout(stdout, "info string Unknown position variant '{s}'\n", .{pos_variant});
                continue;
            }
        } else if (std.mem.eql(u8, command, "board")) {
            pos[0].print_unicode();
            //pos[0].print();

            const fen = try pos[0].get_fen(allocator);

            defer allocator.free(fen);

            std.debug.print("FEN: {s}\n", .{fen});
        } else if (std.mem.eql(u8, command, "moves")) {
            var list: MoveList = .{};
            printout(stdout, "is_chess960: {}, pos[0].is_chess960: {}\n", .{ is_chess960(), pos[0].is_chess960 });

            if (pos[0].side_to_play == Color.White) {
                pos[0].generate_legals(Color.White, &list);
            } else {
                pos[0].generate_legals(Color.Black, &list);
            }

            for (0..list.count) |i| {
                const move = list.moves[i];
                printout(stdout, "\n{}. ", .{i});

                // Print moves in UCI; for castling, check castling flag first then Chess960 formatting.
                if ((move.flags == position.MoveFlags.OO or move.flags == position.MoveFlags.OOO) and is_chess960() and pos[0].is_chess960) {
                    const ci = pos[0].side_to_play.toU4();
                    const rook_sq = if (move.flags == position.MoveFlags.OO)
                        pos[0].castle_rook_k_start[ci]
                    else
                        pos[0].castle_rook_q_start[ci];
                    if (rook_sq != position.Square.NO_SQUARE) {
                        const k_from = position.sq_to_coord[move.from];
                        const r_from = position.sq_to_coord[rook_sq.toU()];
                        printout(stdout, "{s}{s}{s}", .{ k_from, r_from, position.MOVE_TYPESTR[move.flags.toU4()] });
                        continue;
                    }
                }

                const repr = move.to_str();
                const s = if (move.is_promotion()) repr[0..5] else repr[0..4];
                printout(stdout, "{s}{s}", .{ s, position.MOVE_TYPESTR[move.flags.toU4()] });
            }

            printout(stdout, "\n", .{});
        } else if (std.mem.eql(u8, command, "eval")) {
            printout(stdout, "{d} (from white's perspective)\n", .{pos[0].eval.eval(&pos[0], Color.White)});
        } else if (std.mem.eql(u8, command, "perft")) {
            const depth = try u32_from_str(words.next() orelse "1");
            const report = perft.perft_test(&pos[0], @as(u4, @intCast(depth)));
            const elapsed_nanos = @as(f64, @floatFromInt(report.time_elapsed));
            const elapsed_seconds = elapsed_nanos / 1_000_000_000;

            printout(stdout, "{d:.3}s elapsed\n", .{elapsed_seconds});
            printout(stdout, "{} nodes explored\n", .{report.nodes});

            const nps = @as(f64, @floatFromInt(report.nodes)) / elapsed_seconds;
            if (nps < 1000) {
                printout(stdout, "{d:.3}N/s\n", .{nps});
            } else if (nps < 1_000_000) {
                printout(stdout, "{d:.3}KN/s\n", .{nps / 1000});
            } else {
                printout(stdout, "{d:.3}MN/s\n", .{nps / 1_000_000});
            }
        } else if (std.mem.eql(u8, command, "perftdiv")) {
            const depth = try u32_from_str(words.next() orelse "1");

            perft.perft_test_div(&pos[0], @as(u4, @intCast(depth)));
        } else if (std.mem.eql(u8, command, "validate")) {
            var list: MoveList = .{};

            const side = pos[0].side_to_play;

            if (side == Color.White) pos[0].generate_legals(Color.White, &list) else pos[0].generate_legals(Color.Black, &list);

            var illegal_count: usize = 0;

            for (0..list.count) |i| {
                const m = list.moves[i];

                if (side == Color.White) {
                    pos[0].play(m, Color.White);
                    if (pos[0].in_check(Color.White)) {
                        illegal_count += 1;
                        printout(stdout, "ILLEGAL: ", .{});
                        m.print();
                        printout(stdout, "\n", .{});
                    }
                    pos[0].undo(m, Color.White);
                } else {
                    pos[0].play(m, Color.Black);
                    if (pos[0].in_check(Color.Black)) {
                        illegal_count += 1;
                        printout(stdout, "ILLEGAL: ", .{});
                        m.print();
                        printout(stdout, "\n", .{});
                    }
                    pos[0].undo(m, Color.Black);
                }
            }

            if (illegal_count == 0) {
                printout(stdout, "OK ({} moves)\n", .{list.count});
            } else {
                printout(stdout, "Found {} illegal moves out of {}\n", .{ illegal_count, list.count });
            }
        } else if (std.mem.eql(u8, command, "perftchild")) {

            // Syntax: perftchild <move1> <move2> ... <depth>

            // Depth is the last token; preceding tokens are UCI moves applied from current position.

            // Build a temporary copy of the current position, apply moves, then run a quiet split at that node.

            const tail = words.rest();

            var toks = std.mem.splitScalar(u8, std.mem.trim(u8, tail, " "), ' ');

            // Collect tokens

            var tok_list = try std.ArrayList([]const u8).initCapacity(allocator, 8);

            defer tok_list.deinit(allocator);

            while (toks.next()) |t| {
                try tok_list.append(allocator, t);
            }

            if (tok_list.items.len == 0) {
                printout(stdout, "info string perftchild requires args: <moves...> <depth>\n", .{});
            } else {
                const depth_tok = tok_list.items[tok_list.items.len - 1];
                const depth_val = u32_from_str(depth_tok) catch 1;
                const d: u4 = @intCast(depth_val);

                // Build temp position
                var tmp = pos[0].copy();

                // Apply moves except last token (depth)
                var i: usize = 0;

                while (i + 1 < tok_list.items.len) : (i += 1) {
                    const mv_str = tok_list.items[i];
                    const mv = Move.parse_move(mv_str, &tmp) catch |err| {
                        printout(stdout, "info string Invalid move in perftchild '{s}': {any}\n", .{ mv_str, err });
                        break;
                    };
                    if (tmp.side_to_play == Color.White) tmp.play(mv, Color.White) else tmp.play(mv, Color.Black);
                }

                // Quiet split without board rendering
                var qlist: MoveList = .{};
                const side = tmp.side_to_play;
                if (side == Color.White) tmp.generate_legals(Color.White, &qlist) else tmp.generate_legals(Color.Black, &qlist);
                var total_nodes: u64 = 0;
                for (0..qlist.count) |mi| {
                    const m = qlist.moves[mi];
                    // Print move name
                    m.print();
                    printout(stdout, " ", .{});
                    // Compute branch nodes

                    var branch: u64 = 1;
                    if (d > 1) {
                        var tmp2 = tmp.copy();
                        if (side == Color.White) tmp2.play(m, Color.White) else tmp2.play(m, Color.Black);
                        if (side == Color.White) {
                            branch = perft.perft(Color.Black, &tmp2, d - 1);
                        } else {
                            branch = perft.perft(Color.White, &tmp2, d - 1);
                        }
                    }

                    total_nodes += branch;
                    printout(stdout, "{}\n", .{branch});
                }
                printout(stdout, "\nMoves: {}\n", .{qlist.count});
                printout(stdout, "Nodes: {}\n", .{total_nodes});
            }
        } else if (std.mem.eql(u8, command, "perftstats")) {
            const depth = try u32_from_str(words.next() orelse "1");

            perft.perft_test_with_stats(&pos[0], @as(u4, @intCast(depth)));
        } else if (std.mem.eql(u8, command, "datagen")) {
            // Usage: datagen games N [depth D] [plies P] [random FIRST NEXT] [debug] [strict] [skipnoisy] [filename NAME.bin]
            var cfg: datagen.GenConfig = .{};

            while (words.next()) |arg| {
                if (std.mem.eql(u8, arg, "games")) {
                    if (words.next()) |n_tok| cfg.games = usize_from_str(n_tok) catch cfg.games;
                } else if (std.mem.eql(u8, arg, "depth")) {
                    if (words.next()) |d_tok| cfg.best_depth = @as(u32, @intCast(usize_from_str(d_tok) catch cfg.best_depth));
                } else if (std.mem.eql(u8, arg, "plies")) {
                    if (words.next()) |p_tok| cfg.max_plies = usize_from_str(p_tok) catch cfg.max_plies;
                } else if (std.mem.eql(u8, arg, "random")) {
                    // random FIRST NEXT
                    if (words.next()) |f_tok| cfg.first_random = usize_from_str(f_tok) catch cfg.first_random;
                    if (words.next()) |n_tok| cfg.next_mixed = usize_from_str(n_tok) catch cfg.next_mixed;
                } else if (std.mem.eql(u8, arg, "debug")) {
                    cfg.debug = true;
                } else if (std.mem.eql(u8, arg, "strict")) {
                    cfg.strict = true;
                } else if (std.mem.eql(u8, arg, "skipnoisy")) {
                    cfg.skip_noisy = true;
                } else if (std.mem.eql(u8, arg, "filename")) {
                    if (words.next()) |nm| cfg.filename = nm;
                } else if (std.mem.eql(u8, arg, "random_min_ply")) {
                    if (words.next()) |v| cfg.random_min_ply = usize_from_str(v) catch cfg.random_min_ply;
                } else if (std.mem.eql(u8, arg, "random_50_ply")) {
                    if (words.next()) |v| cfg.random_50_ply = usize_from_str(v) catch cfg.random_50_ply;
                } else if (std.mem.eql(u8, arg, "random_10_ply")) {
                    if (words.next()) |v| cfg.random_10_ply = usize_from_str(v) catch cfg.random_10_ply;
                } else if (std.mem.eql(u8, arg, "random_move_count")) {
                    if (words.next()) |v| cfg.random_move_count = usize_from_str(v) catch cfg.random_move_count;
                } else if (std.mem.eql(u8, arg, "save_min_ply")) {
                    if (words.next()) |v| cfg.save_min_ply = usize_from_str(v) catch cfg.save_min_ply;
                } else if (std.mem.eql(u8, arg, "save_max_ply")) {
                    if (words.next()) |v| cfg.save_max_ply = usize_from_str(v) catch cfg.save_max_ply;
                } else if (std.mem.eql(u8, arg, "adjudicate_draws_by_score")) {
                    cfg.adjudicate_draws_by_score = true;
                } else if (std.mem.eql(u8, arg, "adjudicate_draws_by_insufficient_mating_material")) {
                    cfg.adjudicate_draws_by_insufficient_mating_material = true;
                }
            }

            // Normalize filename: ensure it ends with .bin
            var final_name = cfg.filename;
            if (!std.mem.endsWith(u8, final_name, ".bin")) {
                final_name = std.fmt.allocPrint(allocator, "{s}.bin", .{cfg.filename}) catch cfg.filename;
            }
            printout(stdout, "info string datagen start games={} depth={} plies={} bin={s}\n", .{ cfg.games, cfg.best_depth, cfg.max_plies, final_name });
            datagen.generate_binary(std.heap.c_allocator, final_name, cfg) catch |err| {
                printout(stdout, "info string datagen failed: {any}\n", .{err});
                continue;
            };
            printout(stdout, "info string datagen done\n", .{});
        } else if (std.mem.eql(u8, command, "seepos")) {
            var list: MoveList = .{};

            if (pos[0].side_to_play == Color.White) {
                pos[0].generate_legals(Color.White, &list);
            } else {
                pos[0].generate_legals(Color.Black, &list);
            }

            printout(stdout, "SEE thresholds\n", .{});

            for (0..list.count) |i| {
                const move = list.moves[i];
                const thr = ms.see_value(&pos[0], move, false);
                printout(stdout, "{}. ", .{i});
                move.print();
                printout(stdout, " SEE result: {}\n", .{thr});
            }
        } else if (std.mem.eql(u8, command[0..3], "see")) {
            const move_str = command[4..];
            const move = Move.parse_move(move_str, &pos[0]) catch continue; // Parse UCI move
            if (move.is_empty()) {
                printout(stdout, "Invalid move format\n", .{});
                continue;
            }
            const see_val = ms.see_value(&pos[0], move, false);
            printout(stdout, "\nsee_value {}\n", .{see_val});
        } else if (use_tb and std.mem.eql(u8, command, "probe")) {
            const total_pieces = bb.pop_count(pos[0].all_pieces(Color.White) | pos[0].all_pieces(Color.Black));
            const has_castling_rights: bool = (pos[0].history[pos[0].game_ply].castling > 0);

            if (has_castling_rights) {
                _ = printout(stdout, "info string Probe failed: Castling rights are still active.\n", .{});
            } else if (total_pieces > fathom.get_tb_largest()) {
                _ = printout(stdout, "info string Probe failed: Too many pieces ({d}) for largest TB ({d}p).\n", .{ total_pieces, fathom.get_tb_largest() });
            } else {
                const wdl_result = fathom.probeWDL(&pos[0], fathom.tb_probe_depth + 1);
                if (wdl_result == fathom.TB_RESULT_FAILED) {
                    _ = printout(stdout, "info string WDL Probe Result: Probe failed (position not found in tablebases or other error)\n", .{});
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
                    _ = printout(stdout, "info string WDL Probe Result: {s} (Code: {d})\n", .{ result_str, wdl_result });
                }
            }
        } else if (use_tb and std.mem.eql(u8, command, "probebest")) {
            const total_pieces = bb.pop_count(pos[0].all_pieces(Color.White) | pos[0].all_pieces(Color.Black));
            const has_castling_rights: bool = (pos[0].history[pos[0].game_ply].castling > 0);

            // Check if the position meets the criteria for probing
            if (has_castling_rights) {
                _ = printout(stdout, "info string Probe failed: Castling rights are still active.\n", .{});
            } else if (total_pieces > fathom.get_tb_largest()) {
                _ = printout(stdout, "info string Probe failed: Too many pieces ({d}) for largest TB ({d}p).\n", .{ total_pieces, fathom.get_tb_largest() });
            } else {
                const wdl_result = fathom.probeWDL(&pos[0], fathom.tb_probe_depth + 1);
                if (wdl_result == fathom.TB_RESULT_FAILED) {
                    _ = printout(stdout, "info string WDL Probe Result: Probe failed (position not found in tablebases or other error)\n", .{});
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
                    _ = printout(stdout, "info string WDL Probe Result: {s} (Code: {d})\n", .{ result_str, wdl_result });

                    // Probe for best move
                    const TB_MAX_MOVES: usize = 64;
                    var results: [TB_MAX_MOVES]fathom.Move = undefined;
                    const probe_result = fathom.probeRoot(&pos[0], results[0..], fathom.tb_probe_depth + 1);
                    const dtz_result = probe_result.result;
                    const valid_move_count = probe_result.move_count;

                    if (dtz_result == fathom.TB_RESULT_FAILED) {
                        _ = printout(stdout, "info string Best Move Probe: Failed (DTZ code: {d})\n", .{dtz_result});
                    } else if (dtz_result == fathom.TB_RESULT_CHECKMATE) {
                        _ = printout(stdout, "info string Best Move: Checkmate\n", .{});
                        _ = printout(stdout, "bestmove (none)\n", .{});
                    } else if (dtz_result == fathom.TB_RESULT_STALEMATE) {
                        _ = printout(stdout, "info string Best Move: Stalemate\n", .{});
                        _ = printout(stdout, "bestmove (none)\n", .{});
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

                        _ = printout(stdout, "info string Best Move: {s} ({s}, WDL: {s})\n", .{ best_move_uci, dtz_str, wdl_str });

                        // Print additional candidate moves
                        if (valid_move_count > 0) {
                            _ = printout(stdout, "info string Additional moves ({d} total): ", .{valid_move_count});
                            var printed = false;
                            for (results[0..valid_move_count]) |cand_move| {
                                if (cand_move == best_move) continue; // Skip the best move
                                const cand_uci = try fathom.moveToUCI(cand_move, allocator);
                                defer allocator.free(cand_uci);
                                if (printed) _ = printout(stdout, " ", .{});
                                _ = printout(stdout, "{s}", .{cand_uci});
                                printed = true;
                            }
                            _ = printout(stdout, "\n", .{});
                        }

                        // Output UCI-compliant best move
                        _ = printout(stdout, "bestmove {s}\n", .{best_move_uci});
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
    thinkers[0].thread_id = 0; // mark main
    thinkers[0].seed = 0;
    thinkers[0].manager = search.SearchManager.new();
    thinkers[0].max_depth = depth;
    thinkers[0].manager.configure(&curr_pos);
    thinkers[0].manager.printout = false;

    var nodes: u64 = 0;
    var timer = std.time.Timer.start() catch |err| {
        std.debug.print("Warning: Timer failed to start: {any}\n", .{err});
        return;
    };

    //for (bench_pos, 1..) |fen, i| {
    for (bench_pos) |fen| {
        // Set up position

        thinkers[0].clear_for_new_game();
        thinkers[0].thread_id = 0;
        thinkers[0].seed = 0;
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

    //const elapsed_ms: u32 = @intFromFloat(elapsed_nanos / 1_000_000);
    //printout(stdout, "{} nodes {} nps {} elapsed\n", .{ nodes, nps, elapsed_ms });
    printout(stdout, "{} nodes {} nps\n", .{ nodes, nps });
}

// pub fn perft_test(allocator: std.mem.Allocator) !void {
//     const test_cases = [_][]const u8{
//         "nnbqrkr1/pp1pp2p/2p2b2/5pp1/1P5P/4P1P1/P1PP1P2/NNBQRKRB w GEge - 1 9,32,1046,33721,1111186,36218182,1202830851",
//         "b1q1rrkb/pppppppp/3nn3/8/P7/1PPP4/4PPPP/BQNNRKRB w GE - 1 9,20,479,10471,273318,6417013,177654692",
//         "bnnqrbkr/pp1p2p1/2p1p2p/5p2/1P5P/1R6/P1PPPPP1/BNNQRBK1 w Ehe - 0 9,33,1022,32724,1024721,32898113,1047360456",
//         "bqnb1rkr/pp3ppp/3ppn2/2p5/5P2/P2P4/NPP1P1PP/BQ1BNRKR w HFhf - 2 9,21,528,12189,326672,8146062,227689589",
//         "2nnrbkr/p1qppppp/8/1ppb4/6PP/3PP3/PPP2P2/BQNNRBKR w HEhe - 1 9,21,807,18002,667366,16253601,590751109",
//         "qbbnnrkr/2pp2pp/p7/1p2pp2/8/P3PP2/1PPP1KPP/QBBNNR1R w hf - 0 9,22,593,13440,382958,9183776,274103539",
//         "1nbbnrkr/p1p1ppp1/3p4/1p3P1p/3Pq2P/8/PPP1P1P1/QNBBNRKR w HFhf - 0 9,28,1120,31058,1171749,34030312,1250970898",
//         "qnbnr1kr/ppp1b1pp/4p3/3p1p2/8/2NPP3/PPP1BPPP/QNB1R1KR w HEhe - 1 9,29,899,26578,824055,24851983,775718317",
//         "q1bnrkr1/ppppp2p/2n2p2/4b1p1/2NP4/8/PPP1PPPP/QNB1RRKB w ge - 1 9,30,860,24566,732757,21093346,649209803",
//         "qbn1brkr/ppp1p1p1/2n4p/3p1p2/P7/6PP/QPPPPP2/1BNNBRKR w HFhf - 0 9,25,635,17054,465806,13203304,377184252",
//         "qnnbbrkr/1p2ppp1/2pp3p/p7/1P5P/2NP4/P1P1PPP1/Q1NBBRKR w HFhf - 0 9,24,572,15243,384260,11110203,293989890",
//         "qn1rbbkr/ppp2p1p/1n1pp1p1/8/3P4/P6P/1PP1PPPK/QNNRBB1R w hd - 2 9,28,811,23175,679699,19836606,594527992",
//         "qnr1bkrb/pppp2pp/3np3/5p2/8/P2P2P1/NPP1PP1P/QN1RBKRB w GDg - 3 9,33,823,26895,713420,23114629,646390782",
//         "qb1nrkbr/1pppp1p1/1n3p2/p1B4p/8/3P1P1P/PPP1P1P1/QBNNRK1R w HEhe - 0 9,31,855,25620,735703,21796206,651054626",
//         "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1,20,400,8902,197281,4865609,119060324",
//         "8/6b1/7r/Pk2p3/1n4Np/K1P1P3/1B6/1b6 b - - 0 1,33,377,10572,125127,3449824,41620286",
//         "8/6b1/5N1r/Pk2p3/1n5p/K1P1P3/1B6/1b6 w - - 0 1,15,418,5061,133804,1609522,42418189",
//         "rnbqkbnr/1ppppppp/8/p7/2P5/P7/1P1PPPPP/RNBQKBNR b KQkq - 0 1,21,441,10227,242685,6164778,161038368",
//         "2bqkbnr/rppppppp/n7/p7/2P5/PP6/3PPPPP/RNBQKBNR w KQk - 0 1,19,398,8820,204573,5072498,129375227",
//         "2bqkbnr/rpp1pppp/n2p4/p7/2P3P1/PP5P/3PPP2/RNBQKBNR b KQk - 0 1,26,470,13090,284308,8296635,202882781",
//         "2kq4/4Q3/1n1p3b/r1NP1bpp/pPP2PP1/p3P2P/4K3/2R1NBR1 b - - 0 1,33,1452,43353,1829511,55661262,2275321404",
//         "8/8/6P1/8/1kb4P/8/1K6/8 w - - 0 1,6,100,649,10016,77697,1114696",
//         "8/8/6P1/8/2b4P/2k5/8/3K4 b - - 0 1,16,73,1091,6579,97531,769922",
//         "8/8/4b1P1/7P/8/3k4/8/3K4 w - - 0 1,4,66,359,5458,42728,620333",
//         "8/8/5k2/p1q1N1N1/PP1rp1P1/3P4/2RKp3/7r b - - 0 1,47,934,36151,744017,28368703,600039464",
//         "8/6kN/8/2q1N3/Pp1rp1P1/3P4/2RKp3/7r w - - 0 1,19,861,15432,656842,12401507,507590831",
//         "6B1/8/8/8/6k1/1p1p4/6K1/8 b - - 0 1,7,89,720,8957,80437,1023277",
//         "6B1/8/8/8/7k/1p1p1K2/8/8 w - - 0 1,11,56,730,5198,69538,634670",
//         "8/8/8/6k1/8/1B1p2K1/8/8 b - - 0 1,6,95,631,9412,74180,1036141",
//         "k7/3K4/8/6n1/6p1/8/7r/8 w - - 0 1,7,163,801,17800,93543,2076111",
//         "3k4/3P4/8/2P5/7R/1K6/8/4b1b1 w - - 0 1,21,298,5635,84820,1583235,24946858",
//         "3Q4/4k3/8/2P5/1R6/1K6/8/4b1b1 b - - 0 1,3,96,1197,38271,515558,16572719",
//         "3n4/2k2b2/8/3p2p1/8/3K4/8/1N6 w - - 0 1,9,152,1463,25573,252916,4522589",
//         "8/5bk1/8/2Pp4/8/1K6/8/8 w - d6 0 1,8,104,736,9287,62297,824064",
//         "8/8/1k6/8/2pP4/8/5BK1/8 b - d3 0 1,8,104,736,9287,62297,824064",
//         "8/8/1k6/2b5/2pP4/8/5K2/8 b - d3 0 1,15,126,1928,13931,206379,1440467",
//         "8/5k2/8/2Pp4/2B5/1K6/8/8 w - d6 0 1,15,126,1928,13931,206379,1440467",
//         "5k2/8/8/8/8/8/8/4K2R w K - 0 1,,,,,,661072",
//         "4k2r/8/8/8/8/8/8/5K2 b k - 0 1,,,,,,661072",
//         "3k4/8/8/8/8/8/8/R3K3 w Q - 0 1,,,,,,803711",
//         "r3k3/8/8/8/8/8/8/3K4 b q - 0 1,,,,,,803711",
//         "r3k2r/1b4bq/8/8/8/8/7B/R3K2R w KQkq - 0 1,,,,1274206",
//         "r3k2r/7b/8/8/8/8/1B4BQ/R3K2R b KQkq - 0 1,,,,1274206",
//         "r3k2r/8/3Q4/8/8/5q2/8/R3K2R b KQkq - 0 1,,,,1720476",
//         "r3k2r/8/5Q2/8/8/3q4/8/R3K2R w KQkq - 0 1,,,,1720476",
//         "2K2r2/4P3/8/8/8/8/8/3k4 w - - 0 1,,,,,,3821001",
//         "3K4/8/8/8/8/8/4p3/2k2R2 b - - 0 1,,,,,,3821001",
//         "8/8/1P2K3/8/2n5/1q6/8/5k2 b - - 0 1,,,,,1004658",
//         "5K2/8/1Q6/2N5/8/1p2k3/8/8 w - - 0 1,,,,,1004658",
//         "4k3/1P6/8/8/8/8/K7/8 w - - 0 1,,,,,,217342",
//         "8/k7/8/8/8/8/1p6/4K3 b - - 0 1,,,,,,217342",
//         "8/P1k5/K7/8/8/8/8/8 w - - 0 1,,,,,,92683",
//         "8/8/8/8/8/k7/p1K5/8 b - - 0 1,,,,,,92683",
//         "K1k5/8/P7/8/8/8/8/8 w - - 0 1,,,,,,2217",
//         "8/8/8/8/8/p7/8/k1K5 b - - 0 1,,,,,,2217",
//         "8/k1P5/8/1K6/8/8/8/8 w - - 0 1,,,,,,,567584",
//         "8/8/8/8/1k6/8/K1p5/8 b - - 0 1,,,,,,,567584",
//         "8/8/2k5/5q2/5n2/8/5K2/8 b - - 0 1,,,,23527",
//         "8/5k2/8/5N2/5Q2/2K5/8/8 w - - 0 1,,,,23527",
//         "qnnbrk1r/1p1ppbpp/2p5/p4p2/2NP3P/8/PPP1PPP1/Q1NBRKBR w HEhe - 0 9,26,790,21238,642367,17819770,544866674",
//         "1qnrkbbr/1pppppp1/p1n4p/8/P7/1P1N1P2/2PPP1PP/QN1RKBBR w HDhd - 0 9,37,883,32187,815535,29370838,783201510",
//         "qn1rkrbb/pp1p1ppp/2p1p3/3n4/4P2P/2NP4/PPP2PP1/Q1NRKRBB w FDfd - 1 9,24,585,14769,356950,9482310,233468620",
//         "bb1qnrkr/pp1p1pp1/1np1p3/4N2p/8/1P4P1/P1PPPP1P/BBNQ1RKR w HFhf - 0 9,29,864,25747,799727,24219627,776836316",
//         "bnqbnr1r/p1p1ppkp/3p4/1p4p1/P7/3NP2P/1PPP1PP1/BNQB1RKR w HF - 0 9,26,889,24353,832956,23701014,809194268",
//         "bnqnrbkr/1pp2pp1/p7/3pP2p/4P1P1/8/PPPP3P/BNQNRBKR w HEhe d6 0 9,31,984,28677,962591,29032175,1008880643",
//         "b1qnrrkb/ppp1pp1p/n2p1Pp1/8/8/P7/1PPPP1PP/BNQNRKRB w GE - 0 9,20,484,10532,281606,6718715,193594729",
//         "n1bqnrkr/pp1ppp1p/2p5/6p1/2P2b2/PN6/1PNPPPPP/1BBQ1RKR w HFhf - 2 9,23,732,17746,558191,14481581,457140569",
//         "n1bb1rkr/qpnppppp/2p5/p7/P1P5/5P2/1P1PPRPP/NQBBN1KR w Hhf - 1 9,27,697,18724,505089,14226907,400942568",
//         "nqb1rbkr/pppppp1p/4n3/6p1/4P3/1NP4P/PP1P1PP1/1QBNRBKR w HEhe - 1 9,28,641,18811,456916,13780398,354122358",
//         "n1bnrrkb/pp1pp2p/2p2p2/6p1/5B2/3P4/PPP1PPPP/NQ1NRKRB w GE - 2 9,28,606,16883,381646,10815324,254026570",
//         "nbqnbrkr/2ppp1p1/pp3p1p/8/4N2P/1N6/PPPPPPP1/1BQ1BRKR w HFhf - 0 9,26,626,17268,437525,12719546,339132046",
//         "nq1bbrkr/pp2nppp/2pp4/4p3/1PP1P3/1B6/P2P1PPP/NQN1BRKR w HFhf - 2 9,21,504,11812,302230,7697880,207028745",
//         "nqnrb1kr/2pp1ppp/1p1bp3/p1B5/5P2/3N4/PPPPP1PP/NQ1R1BKR w HDhd - 0 9,30,672,19307,465317,13454573,345445468",
//         "nqn2krb/p1prpppp/1pbp4/7P/5P2/8/PPPPPKP1/NQNRB1RB w g - 3 9,21,461,10608,248069,6194124,152861936",
//         "nb1n1kbr/ppp1rppp/3pq3/P3p3/8/4P3/1PPPRPPP/NBQN1KBR w Hh - 1 9,19,566,11786,358337,8047916,249171636",
//         "nqnbrkbr/1ppppp1p/p7/6p1/6P1/P6P/1PPPPP2/NQNBRKBR w HEhe - 1 9,20,382,8694,187263,4708975,112278808",
//         "nq1rkb1r/pp1pp1pp/1n2bp1B/2p5/8/5P1P/PPPPP1P1/NQNRKB1R w HDhd - 2 9,24,809,20090,673811,17647882,593457788",
//         "nqnrkrb1/pppppp2/7p/4b1p1/8/PN1NP3/1PPP1PPP/1Q1RKRBB w FDfd - 1 9,26,683,18102,473911,13055173,352398011",
//         "bb1nqrkr/1pp1ppp1/pn5p/3p4/8/P2NNP2/1PPPP1PP/BB2QRKR w HFhf - 0 9,29,695,21193,552634,17454857,483785639",
//         "bnn1qrkr/pp1ppp1p/2p5/b3Q1p1/8/5P1P/PPPPP1P1/BNNB1RKR w HFhf - 2 9,44,920,35830,795317,29742670,702867204",
//         "b1nqrkrb/2pppppp/p7/1P6/1n6/P4P2/1P1PP1PP/BNNQRKRB w GEge - 0 9,23,638,15744,446539,11735969,344211589",
//         "n1bnqrkr/3ppppp/1p6/pNp1b3/2P3P1/8/PP1PPP1P/NBB1QRKR w HFhf - 1 9,29,728,20768,532084,15621236,415766465",
//         "n2bqrkr/p1p1pppp/1pn5/3p1b2/P6P/1NP5/1P1PPPP1/1NBBQRKR w HFhf - 3 9,20,533,12152,325059,8088751,223068417",
//         "nnbqrbkr/1pp1p1p1/p2p4/5p1p/2P1P3/N7/PPQP1PPP/N1B1RBKR w HEhe - 0 9,27,619,18098,444421,13755384,357222394",
//         "nb1qbrkr/p1pppp2/1p1n2pp/8/1P6/2PN3P/P2PPPP1/NB1QBRKR w HFhf - 0 9,25,521,14021,306427,8697700,201455191",
//         "nnq1brkr/pp1pppp1/8/2p4P/8/5K2/PPPbPP1P/NNQBBR1R w hf - 0 9,23,724,18263,571072,15338230,484638597",
//         "nnqrbb1r/pppppk2/5pp1/7p/1P6/3P2PP/P1P1PP2/NNQRBBKR w HD - 0 9,30,717,21945,547145,17166700,450069742",
//         "nnqr1krb/p1p1pppp/2bp4/8/1p1P4/4P3/PPP2PPP/NNQRBKRB w GDgd - 0 9,25,873,20796,728628,18162741,641708630",
//         "nbnqrkbr/p2ppp2/1p4p1/2p4p/3P3P/3N4/PPP1PPPR/NB1QRKB1 w Ehe - 0 9,24,589,15190,382317,10630667,279474189",
//         "n1qbrkbr/p1ppp2p/2n2pp1/1p6/1P6/2P3P1/P2PPP1P/NNQBRKBR w HEhe - 0 9,22,592,14269,401976,10356818,301583306",
//         "2qrkbbr/ppn1pppp/n1p5/3p4/5P2/P1PP4/1P2P1PP/NNQRKBBR w HDhd - 1 9,27,750,20584,605458,16819085,516796736",
//         "1nqr1rbb/pppkp1pp/1n3p2/3p4/1P6/5P1P/P1PPPKP1/NNQR1RBB w - - 1 9,24,623,15921,429446,11594634,322745925",
//         "bbn1rqkr/pp1pp2p/4npp1/2p5/1P6/2BPP3/P1P2PPP/1BNNRQKR w HEhe - 0 9,23,730,17743,565340,14496370,468608864",
//         "bn1brqkr/pppp2p1/3npp2/7p/PPP5/8/3PPPPP/BNNBRQKR w HEhe - 0 9,25,673,17835,513696,14284338,434008567",
//         "bn1rqbkr/ppp1ppp1/1n6/2p4p/7P/3P4/PPP1PPP1/BN1RQBKR w HDhd - 0 9,25,776,20562,660217,18486027,616653869",
//         "bnnr1krb/ppp2ppp/3p4/3Bp3/q1P3PP/8/PP1PPP2/BNNRQKR1 w GDgd - 0 9,29,1040,30772,1053113,31801525,1075147725",
//         "1bbnrqkr/pp1ppppp/8/2p5/n7/3PNPP1/PPP1P2P/NBB1RQKR w HEhe - 1 9,24,598,15673,409766,11394778,310589129",
//         "nnbbrqkr/p2ppp1p/1pp5/8/6p1/N1P5/PPBPPPPP/N1B1RQKR w HEhe - 0 9,26,530,14031,326312,8846766,229270702",
//         "nnbrqbkr/2p1p1pp/p4p2/1p1p4/8/NP6/P1PPPPPP/N1BRQBKR w HDhd - 0 9,17,496,10220,303310,7103549,217108001",
//         "nnbrqk1b/pp2pprp/2pp2p1/8/3PP1P1/8/PPP2P1P/NNBRQRKB w d - 1 9,33,820,27856,706784,24714401,645835197",
//         "1bnrbqkr/ppnpp1p1/2p2p1p/8/1P6/4PPP1/P1PP3P/NBNRBQKR w HDhd - 0 9,27,705,19760,548680,15964771,464662032",
//         "n1rbbqkr/pp1pppp1/7p/P1p5/1n6/2PP4/1P2PPPP/NNRBBQKR w HChc - 0 9,22,631,14978,431801,10911545,320838556",
//         "n1rqb1kr/p1pppp1p/1pn4b/3P2p1/P7/1P6/2P1PPPP/NNRQBBKR w HChc - 0 9,24,477,12506,263189,7419372,165945904",
//         "nnrqbkrb/pppp1pp1/7p/4p3/6P1/2N2B2/PPPPPP1P/NR1QBKR1 w Ggc - 2 9,29,658,19364,476620,14233587,373744834",
//         "2rbqkbr/p1pppppp/1nn5/1p6/7P/P4P2/1PPPP1PB/NNRBQK1R w HChc - 2 9,27,647,18030,458057,13189156,354689323",
//         "nn1qkbbr/pp2ppp1/2rp4/2p4p/P2P4/1N5P/1PP1PPP1/1NRQKBBR w HCh - 1 9,24,738,18916,586009,16420659,519075930",
//         "nnrqk1bb/p1ppp2p/5rp1/1p3p2/1P4P1/5P1P/P1PPP3/NNRQKRBB w FCc - 1 9,25,795,20510,648945,17342527,556144017",
//         "1nnrkbqr/p1pp1ppp/4p3/1p6/1Pb1P3/6PB/P1PP1P1P/BNNRK1QR w HDhd - 0 9,27,776,22133,641002,19153245,562738257",
//         "nbbnrkqr/p1ppp1pp/1p3p2/8/2P5/4P3/PP1P1PPP/NBBNRKQR w HEhe - 1 9,25,624,15561,419635,10817378,311138112",
//         "nn1brkqr/pp1bpppp/8/2pp4/P4P2/1PN5/2PPP1PP/N1BBRKQR w HEhe - 1 9,23,659,16958,476567,13242252,373557073",
//         "n1brkbqr/ppp1pp1p/6pB/3p4/2Pn4/8/PP2PPPP/NN1RKBQR w HDhd - 0 9,32,1026,30360,978278,29436320,957904151",
//         "nnbrkqrb/p2ppp2/Q5pp/1pp5/4PP2/2N5/PPPP2PP/N1BRK1RB w GDgd - 0 9,36,843,29017,715537,24321197,630396940",
//         "nbnrbk1r/pppppppq/8/7p/8/1N2QPP1/PPPPP2P/NB1RBK1R w HDhd - 2 9,36,973,35403,1018054,37143354,1124883780",
//         "nnrbbkqr/2pppp1p/p7/6p1/1p2P3/4QPP1/PPPP3P/NNRBBK1R w HChc - 0 9,36,649,22524,489526,16836636,416139320",
//         "n1rkbqrb/pp1ppp2/2n3p1/2p4p/P5PP/1P6/2PPPP2/NNRKBQRB w GCgc - 0 9,24,804,20712,684001,18761475,617932151",
//         "nnr1kqbr/pp1pp1p1/2p5/b4p1p/P7/1PNP4/2P1PPPP/N1RBKQBR w HChc - 1 9,12,421,6530,227044,4266410,149176979",
//         "n1rkqbbr/p1pp1pp1/np2p2p/8/8/N4PP1/PPPPP1BP/N1RKQ1BR w HChc - 0 9,27,670,19119,494690,14708490,397268628",
//         "bbnnrkrq/ppp1pp2/6p1/3p4/7p/7P/PPPPPPP1/BBNNRRKQ w ge - 0 9,20,559,12242,355326,8427161,252274233",
//         "bn1rkbrq/1pppppp1/p6p/1n6/3P4/6PP/PPPRPP2/BNN1KBRQ w Ggd - 2 9,29,633,19278,455476,14333034,361900466",
//         "b1nrkrqb/1p1npppp/p2p4/2p5/5P2/4P2P/PPPP1RP1/BNNRK1QB w Dfd - 1 9,25,475,12603,270909,7545536,179579818",
//         "nnbbrkrq/2pp1pp1/1p5p/pP2p3/7P/N7/P1PPPPP1/N1BBRKRQ w GEge - 0 9,18,432,9638,242350,6131124,160393505",
//         "nnbrkbrq/1pppp1p1/p7/7p/1P2Pp2/BN6/P1PP1PPP/1N1RKBRQ w GDgd - 0 9,27,482,13441,282259,8084701,193484216",
//         "n1brkrqb/pppp3p/n3pp2/6p1/3P1P2/N1P5/PP2P1PP/N1BRKRQB w FDfd - 0 9,28,642,19005,471729,14529434,384837696",
//         "nbnrbk2/p1pppp1p/1p3qr1/6p1/1B1P4/1N6/PPP1PPPP/1BNR1RKQ w d - 2 9,30,796,22780,687302,20120565,641832725",
//         "nnrbbrkq/1pp2ppp/3p4/p3p3/3P1P2/1P2P3/P1P3PP/NNRBBKRQ w GC - 1 9,31,827,24538,663082,19979594,549437308",
//         "nnrkbbrq/1pp2p1p/p2pp1p1/2P5/8/8/PP1PPPPP/NNRKBBRQ w Ggc - 0 9,24,762,19283,624598,16838099,555230555",
//         "nnr1brqb/1ppkp1pp/8/p2p1p2/1P1P4/N1P5/P3PPPP/N1RKBRQB w FC - 1 9,23,640,15471,444905,11343507,334123513",
//         "nbnrkrbq/2ppp2p/p4p2/1P4p1/4PP2/8/1PPP2PP/NBNRKRBQ w FDfd - 0 9,31,826,26137,732175,23555139,686250413",
//         "1nrbkr1q/1pppp1pp/1n6/p4p2/N1b4P/8/PPPPPPPB/N1RBKR1Q w FCfc - 2 9,27,862,24141,755171,22027695,696353497",
//         "nnrkrbbq/pppp2pp/8/4pp2/4P3/P7/1PPPBPPP/NNKRR1BQ w c - 0 9,25,792,19883,636041,16473376,532214177",
//         "n1rk1qbb/pppprpp1/2n4p/4p3/2PP3P/8/PP2PPP1/NNRKRQBB w ECc - 1 9,25,622,16031,425247,11420973,321855685",
//         "bbq1rnkr/pnp1pp1p/1p1p4/6p1/2P5/2Q1P2P/PP1P1PP1/BB1NRNKR w HEhe - 2 9,36,870,30516,811047,28127620,799738334",
//         "bq1brnkr/1p1ppp1p/1np5/p5p1/8/1N5P/PPPPPPP1/BQ1BRNKR w HEhe - 0 9,22,588,13524,380068,9359618,273795898",
//         "bq1rn1kr/1pppppbp/Nn4p1/8/8/P7/1PPPPPPP/BQ1RNBKR w HDhd - 1 9,24,711,18197,542570,14692779,445827351",
//         "bqnr1kr1/pppppp1p/6p1/5n2/4B3/3N2PP/PbPPPP2/BQNR1KR1 w GDgd - 2 9,31,1132,36559,1261476,43256823,1456721391",
//         "qbb1rnkr/ppp3pp/4n3/3ppp2/1P3PP1/8/P1PPPN1P/QBB1RNKR w HEhe - 0 9,28,696,20502,541886,16492398,456983120",
//         "1nbrnbkr/p1ppp1pp/1p6/5p2/4q1PP/3P4/PPP1PP2/QNBRNBKR w HDhd - 1 9,30,1162,33199,1217278,36048727,1290346802",
//         "q1brnkrb/p1pppppp/n7/1p6/P7/3P1P2/QPP1P1PP/1NBRNKRB w GDgd - 0 9,32,827,26106,718243,23143989,673147648",
//         "qbnrb1kr/ppp1pp1p/3p4/2n3p1/1P6/6N1/P1PPPPPP/QBNRB1KR w HDhd - 2 9,29,751,23132,610397,19555214,530475036",
//         "q1rbbnkr/pppp1p2/2n3pp/2P1p3/3P4/8/PP1NPPPP/Q1RBBNKR w HChc - 2 9,29,806,24540,687251,21694330,619907316",
//         "q1r1bbkr/pnpp1ppp/2n1p3/1p6/2P2P2/2N1N3/PP1PP1PP/Q1R1BBKR w HChc - 2 9,32,1017,32098,986028,31204371,958455898",
//         "2rnbkrb/pqppppp1/1pn5/7p/2P5/P1R5/QP1PPPPP/1N1NBKRB w Ggc - 4 9,26,625,16506,434635,11856964,336672890",
//         "qbnr1kbr/p2ppppp/2p5/1p6/4n2P/P4N2/1PPP1PP1/QBNR1KBR w HDhd - 0 9,27,885,23828,767273,21855658,706272554",
//         "qnrbnk1r/pp1pp2p/5p2/2pbP1p1/3P4/1P6/P1P2PPP/QNRBNKBR w HChc - 0 9,26,954,24832,892456,24415089,866744329",
//         "qnrnk1br/p1p2ppp/8/1pbpp3/8/PP2N3/1QPPPPPP/1NR1KBBR w HChc - 0 9,26,783,20828,634267,17477825,539674275",
//         "qnrnkrbb/Bpppp2p/6p1/5p2/5P2/3PP3/PPP3PP/QNRNKR1B w FCfc - 1 9,28,908,25730,861240,25251641,869525254",
//         "bbnqrn1r/ppppp2k/5p2/6pp/7P/1QP5/PP1PPPP1/B1N1RNKR w HE - 0 9,33,643,21790,487109,16693640,410115900",
//         "b1qbrnkr/ppp1pp2/2np4/6pp/4P3/2N4P/PPPP1PP1/BQ1BRNKR w HEhe - 0 9,28,837,24253,745617,22197063,696399065",
//         "bnqr1bkr/pp1ppppp/2p5/4N3/5P2/P7/1PPPPnPP/BNQR1BKR w HDhd - 3 9,25,579,13909,341444,8601011,225530258",
//         "nbbqr1kr/1pppp1pp/8/p1n2p2/4P3/PN6/1PPPQPPP/1BB1RNKR w HEhe - 0 9,30,745,23416,597858,19478789,515473678",
//         "nqbbrn1r/p1pppp1k/1p4p1/7p/4P3/1R3B2/PPPP1PPP/NQB2NKR w H - 0 9,24,504,13512,317355,9002073,228726497",
//         "nqbr1bkr/p1p1ppp1/1p1n4/3pN2p/1P6/8/P1PPPPPP/NQBR1BKR w HDhd - 0 9,29,898,26532,809605,24703467,757166494",
//         "nb1r1nkr/ppp1ppp1/2bp4/7p/3P2qP/P6R/1PP1PPP1/NBQRBNK1 w Dhd - 1 9,38,1691,60060,2526992,88557078,3589649998",
//         "n1rbbnkr/1p1pp1pp/p7/2p1qp2/1B3P2/3P4/PPP1P1PP/NQRB1NKR w HChc - 0 9,24,913,21595,807544,19866918,737239330",
//         "nqrnbbkr/p2p1p1p/1pp5/1B2p1p1/1P3P2/4P3/P1PP2PP/NQRNB1KR w HChc - 0 9,33,913,30159,843874,28053260,804687975",
//         "nqr1bkrb/ppp1pp2/2np2p1/P6p/8/2P4P/1P1PPPP1/NQRNBKRB w GCgc - 0 9,24,623,16569,442531,12681936,351623879",
//         "nb1rnkbr/pqppppp1/1p5p/8/1PP4P/8/P2PPPP1/NBQRNKBR w HDhd - 1 9,31,798,24862,694386,22616076,666227466",
//         "nqrbnkbr/2p1p1pp/3p4/pp3p2/6PP/3P1N2/PPP1PP2/NQRB1KBR w HChc - 0 9,24,590,14409,383690,9698432,274064911",
//         "nqrnkbbr/pp1p1p1p/4p1p1/1p6/8/5P1P/P1PPP1P1/NQRNKBBR w HChc - 0 9,30,1032,31481,1098116,34914919,1233362066",
//         "bbnrqrk1/pp2pppp/4n3/2pp4/P7/1N5P/BPPPPPP1/B2RQNKR w HD - 2 9,23,708,17164,554089,14343443,481405144",
//         "bnr1qnkr/p1pp1p1p/1p4p1/4p1b1/2P1P3/1P6/PB1P1PPP/1NRBQNKR w HChc - 1 9,30,931,29249,921746,30026687,968109774",
//         "b1rqnbkr/ppp1ppp1/3p3p/2n5/P3P3/2NP4/1PP2PPP/B1RQNBKR w HChc - 0 9,24,596,15533,396123,11099382,294180723",
//         "bnrqnr1b/pp1pkppp/2p1p3/P7/2P5/7P/1P1PPPP1/BNRQNKRB w GC - 0 9,24,572,15293,390903,11208688,302955778",
//         "n1brq1kr/bppppppp/p7/8/4P1Pn/8/PPPP1P2/NBBRQNKR w HDhd - 0 9,20,570,13139,371247,9919113,284592289",
//         "1br1bnkr/ppqppp1p/1np3p1/8/1PP4P/4N3/P2PPPP1/NBRQB1KR w HChc - 1 9,32,798,24765,691488,22076141,670296871",
//         "nrqbb1kr/1p1pp1pp/2p3n1/p4p2/3PP3/P5N1/1PP2PPP/NRQBB1KR w HBhb - 0 9,32,791,26213,684890,23239122,634260266",
//         "nrqn1bkr/ppppp1pp/4b3/8/4P1p1/5P2/PPPP3P/NRQNBBKR w HBhb - 0 9,29,687,20223,506088,15236287,398759980",
//         "nbrq1kbr/Bp3ppp/2pnp3/3p4/5P2/2P4P/PP1PP1P1/NBRQNK1R w HChc - 0 9,40,1271,48022,1547741,56588117,1850696281",
//         "nrqbnkbr/1p2ppp1/p1p4p/3p4/1P6/8/PQPPPPPP/1RNBNKBR w HBhb - 0 9,28,757,23135,668025,21427496,650939962",
//         "nrqn1bbr/2ppkppp/4p3/pB6/8/2P1P3/PP1P1PPP/NRQNK1BR w HB - 1 9,27,642,17096,442653,11872805,327545120",
//         "nrqnkrb1/p1ppp2p/1p4p1/4bp2/4PP1P/4N3/PPPP2P1/NRQ1KRBB w FBfb - 1 9,27,958,27397,960350,28520172,995356563",
//         "1bnrnqkr/pbpp2pp/8/1p2pp2/P6P/3P1N2/1PP1PPP1/BBNR1QKR w HDhd - 0 9,27,859,23475,773232,21581178,732696327",
//         "b1rbnqkr/1pp1ppp1/2n4p/p2p4/5P2/1PBP4/P1P1P1PP/1NRBNQKR w HChc - 0 9,26,545,14817,336470,9537260,233549184",
//         "1nrnqbkr/p1pppppp/1p6/8/2b2P2/P1N5/1PP1P1PP/BNR1QBKR w HChc - 2 9,24,668,17716,494866,14216070,406225409",
//         "1nrnqkrb/2ppp1pp/p7/1p3p2/5P2/N5K1/PPPPP2P/B1RNQ1RB w gc - 0 9,33,725,23572,559823,18547476,471443091",
//         "nbbr1qkr/p1pppppp/8/1p1n4/3P4/1N3PP1/PPP1P2P/1BBRNQKR w HDhd - 1 9,28,698,20527,539625,16555068,458045505",
//         "1rbbnqkr/1pnppp1p/p5p1/2p5/2P4P/5P2/PP1PP1PR/NRBBNQK1 w Bhb - 1 9,24,554,14221,362516,9863080,269284081",
//         "nrb1qbkr/2pppppp/2n5/p7/2p5/4P3/PPNP1PPP/1RBNQBKR w HBhb - 0 9,23,618,15572,443718,12044358,360311412",
//     };

//     try init_all(allocator);

//     //nnue.engine_using_nnue = false;

//     if (nnue.engine_using_nnue) {
//         try nnue.embed_and_init();

//         nnue.engine_loaded_net = true;
//     }

//     try tt.TT.init(128 + 1);
//     defer tt.TT.deinit();

//     std.debug.print("\n", .{});

//     // Iterate over each test case
//     for (test_cases) |test_case| {
//         // Parse the test case
//         var parts = std.mem.splitScalar(u8, test_case, ',');
//         const fen = parts.next() orelse return error.InvalidTestCase;
//         var expected_nodes: [7]?u64 = .{null} ** 7;

//         // Parse node counts for depths 1 to 7
//         inline for (0..4) |i| {
//             if (parts.next()) |node_str| {
//                 if (node_str.len > 0) {
//                     expected_nodes[i] = try std.fmt.parseInt(u64, node_str, 10);
//                 }
//             }
//         }

//         // Set up position

//         var curr_pos = Position.new();
//         try curr_pos.set(fen);

//         std.debug.print("Testing: {s}\n", .{fen});
//         // Run perft for each depth with non-null expected nodes
//         inline for (1..8) |depth| {

//             //std.debug.print("Depth: {}: ", .{depth});

//             if (expected_nodes[depth - 1]) |expected| {
//                 const report = perft.perft_test(&curr_pos, @as(u4, @intCast(depth)));

//                 if (report.nodes != expected) {
//                     std.debug.print(
//                         "Perft failed for FEN: {s}, depth: {d}, expected: {d}, got: {d}\n",

//                         .{ fen, depth, expected, report.nodes },
//                     );

//                     try std.testing.expectEqual(expected, report.nodes);
//                 } else {
//                     std.debug.print(
//                         "Perft passed for depth: {d}, expected: {d}, got: {d}\n",

//                         .{ depth, expected, report.nodes },
//                     );
//                 }
//             }
//         }
//     }
// }

pub fn perft_test(allocator: std.mem.Allocator) !void {
    const test_cases = [_][]const u8{
        "nnbqrkr1/pp1pp2p/2p2b2/5pp1/1P5P/4P1P1/P1PP1P2/NNBQRKRB w GEge - 1 9,32,1046,33721,1111186,36218182,1202830851",
        "b1q1rrkb/pppppppp/3nn3/8/P7/1PPP4/4PPPP/BQNNRKRB w GE - 1 9,20,479,10471,273318,6417013,177654692",
        "bnnqrbkr/pp1p2p1/2p1p2p/5p2/1P5P/1R6/P1PPPPP1/BNNQRBK1 w Ehe - 0 9,33,1022,32724,1024721,32898113,1047360456",
        "bqnb1rkr/pp3ppp/3ppn2/2p5/5P2/P2P4/NPP1P1PP/BQ1BNRKR w HFhf - 2 9,21,528,12189,326672,8146062,227689589",
        "2nnrbkr/p1qppppp/8/1ppb4/6PP/3PP3/PPP2P2/BQNNRBKR w HEhe - 1 9,21,807,18002,667366,16253601,590751109",
        "qbbnnrkr/2pp2pp/p7/1p2pp2/8/P3PP2/1PPP1KPP/QBBNNR1R w hf - 0 9,22,593,13440,382958,9183776,274103539",
        "1nbbnrkr/p1p1ppp1/3p4/1p3P1p/3Pq2P/8/PPP1P1P1/QNBBNRKR w HFhf - 0 9,28,1120,31058,1171749,34030312,1250970898",
        "qnbnr1kr/ppp1b1pp/4p3/3p1p2/8/2NPP3/PPP1BPPP/QNB1R1KR w HEhe - 1 9,29,899,26578,824055,24851983,775718317",
        "q1bnrkr1/ppppp2p/2n2p2/4b1p1/2NP4/8/PPP1PPPP/QNB1RRKB w ge - 1 9,30,860,24566,732757,21093346,649209803",
        "qbn1brkr/ppp1p1p1/2n4p/3p1p2/P7/6PP/QPPPPP2/1BNNBRKR w HFhf - 0 9,25,635,17054,465806,13203304,377184252",
        "qnnbbrkr/1p2ppp1/2pp3p/p7/1P5P/2NP4/P1P1PPP1/Q1NBBRKR w HFhf - 0 9,24,572,15243,384260,11110203,293989890",
        "qn1rbbkr/ppp2p1p/1n1pp1p1/8/3P4/P6P/1PP1PPPK/QNNRBB1R w hd - 2 9,28,811,23175,679699,19836606,594527992",
        "qnr1bkrb/pppp2pp/3np3/5p2/8/P2P2P1/NPP1PP1P/QN1RBKRB w GDg - 3 9,33,823,26895,713420,23114629,646390782",
        "qb1nrkbr/1pppp1p1/1n3p2/p1B4p/8/3P1P1P/PPP1P1P1/QBNNRK1R w HEhe - 0 9,31,855,25620,735703,21796206,651054626",
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
        "qnnbrk1r/1p1ppbpp/2p5/p4p2/2NP3P/8/PPP1PPP1/Q1NBRKBR w HEhe - 0 9,26,790,21238,642367,17819770,544866674",
        "1qnrkbbr/1pppppp1/p1n4p/8/P7/1P1N1P2/2PPP1PP/QN1RKBBR w HDhd - 0 9,37,883,32187,815535,29370838,783201510",
        "qn1rkrbb/pp1p1ppp/2p1p3/3n4/4P2P/2NP4/PPP2PP1/Q1NRKRBB w FDfd - 1 9,24,585,14769,356950,9482310,233468620",
        "bb1qnrkr/pp1p1pp1/1np1p3/4N2p/8/1P4P1/P1PPPP1P/BBNQ1RKR w HFhf - 0 9,29,864,25747,799727,24219627,776836316",
        "bnqbnr1r/p1p1ppkp/3p4/1p4p1/P7/3NP2P/1PPP1PP1/BNQB1RKR w HF - 0 9,26,889,24353,832956,23701014,809194268",
        "bnqnrbkr/1pp2pp1/p7/3pP2p/4P1P1/8/PPPP3P/BNQNRBKR w HEhe d6 0 9,31,984,28677,962591,29032175,1008880643",
        "b1qnrrkb/ppp1pp1p/n2p1Pp1/8/8/P7/1PPPP1PP/BNQNRKRB w GE - 0 9,20,484,10532,281606,6718715,193594729",
        "n1bqnrkr/pp1ppp1p/2p5/6p1/2P2b2/PN6/1PNPPPPP/1BBQ1RKR w HFhf - 2 9,23,732,17746,558191,14481581,457140569",
        "n1bb1rkr/qpnppppp/2p5/p7/P1P5/5P2/1P1PPRPP/NQBBN1KR w Hhf - 1 9,27,697,18724,505089,14226907,400942568",
        "nqb1rbkr/pppppp1p/4n3/6p1/4P3/1NP4P/PP1P1PP1/1QBNRBKR w HEhe - 1 9,28,641,18811,456916,13780398,354122358",
        "n1bnrrkb/pp1pp2p/2p2p2/6p1/5B2/3P4/PPP1PPPP/NQ1NRKRB w GE - 2 9,28,606,16883,381646,10815324,254026570",
        "nbqnbrkr/2ppp1p1/pp3p1p/8/4N2P/1N6/PPPPPPP1/1BQ1BRKR w HFhf - 0 9,26,626,17268,437525,12719546,339132046",
        "nq1bbrkr/pp2nppp/2pp4/4p3/1PP1P3/1B6/P2P1PPP/NQN1BRKR w HFhf - 2 9,21,504,11812,302230,7697880,207028745",
        "nqnrb1kr/2pp1ppp/1p1bp3/p1B5/5P2/3N4/PPPPP1PP/NQ1R1BKR w HDhd - 0 9,30,672,19307,465317,13454573,345445468",
        "nqn2krb/p1prpppp/1pbp4/7P/5P2/8/PPPPPKP1/NQNRB1RB w g - 3 9,21,461,10608,248069,6194124,152861936",
        "nb1n1kbr/ppp1rppp/3pq3/P3p3/8/4P3/1PPPRPPP/NBQN1KBR w Hh - 1 9,19,566,11786,358337,8047916,249171636",
        "nqnbrkbr/1ppppp1p/p7/6p1/6P1/P6P/1PPPPP2/NQNBRKBR w HEhe - 1 9,20,382,8694,187263,4708975,112278808",
        "nq1rkb1r/pp1pp1pp/1n2bp1B/2p5/8/5P1P/PPPPP1P1/NQNRKB1R w HDhd - 2 9,24,809,20090,673811,17647882,593457788",
        "nqnrkrb1/pppppp2/7p/4b1p1/8/PN1NP3/1PPP1PPP/1Q1RKRBB w FDfd - 1 9,26,683,18102,473911,13055173,352398011",
        "bb1nqrkr/1pp1ppp1/pn5p/3p4/8/P2NNP2/1PPPP1PP/BB2QRKR w HFhf - 0 9,29,695,21193,552634,17454857,483785639",
        "bnn1qrkr/pp1ppp1p/2p5/b3Q1p1/8/5P1P/PPPPP1P1/BNNB1RKR w HFhf - 2 9,44,920,35830,795317,29742670,702867204",
        "b1nqrkrb/2pppppp/p7/1P6/1n6/P4P2/1P1PP1PP/BNNQRKRB w GEge - 0 9,23,638,15744,446539,11735969,344211589",
        "n1bnqrkr/3ppppp/1p6/pNp1b3/2P3P1/8/PP1PPP1P/NBB1QRKR w HFhf - 1 9,29,728,20768,532084,15621236,415766465",
        "n2bqrkr/p1p1pppp/1pn5/3p1b2/P6P/1NP5/1P1PPPP1/1NBBQRKR w HFhf - 3 9,20,533,12152,325059,8088751,223068417",
        "nnbqrbkr/1pp1p1p1/p2p4/5p1p/2P1P3/N7/PPQP1PPP/N1B1RBKR w HEhe - 0 9,27,619,18098,444421,13755384,357222394",
        "nb1qbrkr/p1pppp2/1p1n2pp/8/1P6/2PN3P/P2PPPP1/NB1QBRKR w HFhf - 0 9,25,521,14021,306427,8697700,201455191",
        "nnq1brkr/pp1pppp1/8/2p4P/8/5K2/PPPbPP1P/NNQBBR1R w hf - 0 9,23,724,18263,571072,15338230,484638597",
        "nnqrbb1r/pppppk2/5pp1/7p/1P6/3P2PP/P1P1PP2/NNQRBBKR w HD - 0 9,30,717,21945,547145,17166700,450069742",
        "nnqr1krb/p1p1pppp/2bp4/8/1p1P4/4P3/PPP2PPP/NNQRBKRB w GDgd - 0 9,25,873,20796,728628,18162741,641708630",
        "nbnqrkbr/p2ppp2/1p4p1/2p4p/3P3P/3N4/PPP1PPPR/NB1QRKB1 w Ehe - 0 9,24,589,15190,382317,10630667,279474189",
        "n1qbrkbr/p1ppp2p/2n2pp1/1p6/1P6/2P3P1/P2PPP1P/NNQBRKBR w HEhe - 0 9,22,592,14269,401976,10356818,301583306",
        "2qrkbbr/ppn1pppp/n1p5/3p4/5P2/P1PP4/1P2P1PP/NNQRKBBR w HDhd - 1 9,27,750,20584,605458,16819085,516796736",
        "1nqr1rbb/pppkp1pp/1n3p2/3p4/1P6/5P1P/P1PPPKP1/NNQR1RBB w - - 1 9,24,623,15921,429446,11594634,322745925",
        "bbn1rqkr/pp1pp2p/4npp1/2p5/1P6/2BPP3/P1P2PPP/1BNNRQKR w HEhe - 0 9,23,730,17743,565340,14496370,468608864",
        "bn1brqkr/pppp2p1/3npp2/7p/PPP5/8/3PPPPP/BNNBRQKR w HEhe - 0 9,25,673,17835,513696,14284338,434008567",
        "bn1rqbkr/ppp1ppp1/1n6/2p4p/7P/3P4/PPP1PPP1/BN1RQBKR w HDhd - 0 9,25,776,20562,660217,18486027,616653869",
        "bnnr1krb/ppp2ppp/3p4/3Bp3/q1P3PP/8/PP1PPP2/BNNRQKR1 w GDgd - 0 9,29,1040,30772,1053113,31801525,1075147725",
        "1bbnrqkr/pp1ppppp/8/2p5/n7/3PNPP1/PPP1P2P/NBB1RQKR w HEhe - 1 9,24,598,15673,409766,11394778,310589129",
        "nnbbrqkr/p2ppp1p/1pp5/8/6p1/N1P5/PPBPPPPP/N1B1RQKR w HEhe - 0 9,26,530,14031,326312,8846766,229270702",
        "nnbrqbkr/2p1p1pp/p4p2/1p1p4/8/NP6/P1PPPPPP/N1BRQBKR w HDhd - 0 9,17,496,10220,303310,7103549,217108001",
        "nnbrqk1b/pp2pprp/2pp2p1/8/3PP1P1/8/PPP2P1P/NNBRQRKB w d - 1 9,33,820,27856,706784,24714401,645835197",
        "1bnrbqkr/ppnpp1p1/2p2p1p/8/1P6/4PPP1/P1PP3P/NBNRBQKR w HDhd - 0 9,27,705,19760,548680,15964771,464662032",
        "n1rbbqkr/pp1pppp1/7p/P1p5/1n6/2PP4/1P2PPPP/NNRBBQKR w HChc - 0 9,22,631,14978,431801,10911545,320838556",
        "n1rqb1kr/p1pppp1p/1pn4b/3P2p1/P7/1P6/2P1PPPP/NNRQBBKR w HChc - 0 9,24,477,12506,263189,7419372,165945904",
        "nnrqbkrb/pppp1pp1/7p/4p3/6P1/2N2B2/PPPPPP1P/NR1QBKR1 w Ggc - 2 9,29,658,19364,476620,14233587,373744834",
        "2rbqkbr/p1pppppp/1nn5/1p6/7P/P4P2/1PPPP1PB/NNRBQK1R w HChc - 2 9,27,647,18030,458057,13189156,354689323",
        "nn1qkbbr/pp2ppp1/2rp4/2p4p/P2P4/1N5P/1PP1PPP1/1NRQKBBR w HCh - 1 9,24,738,18916,586009,16420659,519075930",
        "nnrqk1bb/p1ppp2p/5rp1/1p3p2/1P4P1/5P1P/P1PPP3/NNRQKRBB w FCc - 1 9,25,795,20510,648945,17342527,556144017",
        "1nnrkbqr/p1pp1ppp/4p3/1p6/1Pb1P3/6PB/P1PP1P1P/BNNRK1QR w HDhd - 0 9,27,776,22133,641002,19153245,562738257",
        "nbbnrkqr/p1ppp1pp/1p3p2/8/2P5/4P3/PP1P1PPP/NBBNRKQR w HEhe - 1 9,25,624,15561,419635,10817378,311138112",
        "nn1brkqr/pp1bpppp/8/2pp4/P4P2/1PN5/2PPP1PP/N1BBRKQR w HEhe - 1 9,23,659,16958,476567,13242252,373557073",
        "n1brkbqr/ppp1pp1p/6pB/3p4/2Pn4/8/PP2PPPP/NN1RKBQR w HDhd - 0 9,32,1026,30360,978278,29436320,957904151",
        "nnbrkqrb/p2ppp2/Q5pp/1pp5/4PP2/2N5/PPPP2PP/N1BRK1RB w GDgd - 0 9,36,843,29017,715537,24321197,630396940",
        "nbnrbk1r/pppppppq/8/7p/8/1N2QPP1/PPPPP2P/NB1RBK1R w HDhd - 2 9,36,973,35403,1018054,37143354,1124883780",
        "nnrbbkqr/2pppp1p/p7/6p1/1p2P3/4QPP1/PPPP3P/NNRBBK1R w HChc - 0 9,36,649,22524,489526,16836636,416139320",
        "n1rkbqrb/pp1ppp2/2n3p1/2p4p/P5PP/1P6/2PPPP2/NNRKBQRB w GCgc - 0 9,24,804,20712,684001,18761475,617932151",
        "nnr1kqbr/pp1pp1p1/2p5/b4p1p/P7/1PNP4/2P1PPPP/N1RBKQBR w HChc - 1 9,12,421,6530,227044,4266410,149176979",
        "n1rkqbbr/p1pp1pp1/np2p2p/8/8/N4PP1/PPPPP1BP/N1RKQ1BR w HChc - 0 9,27,670,19119,494690,14708490,397268628",
        "bbnnrkrq/ppp1pp2/6p1/3p4/7p/7P/PPPPPPP1/BBNNRRKQ w ge - 0 9,20,559,12242,355326,8427161,252274233",
        "bn1rkbrq/1pppppp1/p6p/1n6/3P4/6PP/PPPRPP2/BNN1KBRQ w Ggd - 2 9,29,633,19278,455476,14333034,361900466",
        "b1nrkrqb/1p1npppp/p2p4/2p5/5P2/4P2P/PPPP1RP1/BNNRK1QB w Dfd - 1 9,25,475,12603,270909,7545536,179579818",
        "nnbbrkrq/2pp1pp1/1p5p/pP2p3/7P/N7/P1PPPPP1/N1BBRKRQ w GEge - 0 9,18,432,9638,242350,6131124,160393505",
        "nnbrkbrq/1pppp1p1/p7/7p/1P2Pp2/BN6/P1PP1PPP/1N1RKBRQ w GDgd - 0 9,27,482,13441,282259,8084701,193484216",
        "n1brkrqb/pppp3p/n3pp2/6p1/3P1P2/N1P5/PP2P1PP/N1BRKRQB w FDfd - 0 9,28,642,19005,471729,14529434,384837696",
        "nbnrbk2/p1pppp1p/1p3qr1/6p1/1B1P4/1N6/PPP1PPPP/1BNR1RKQ w d - 2 9,30,796,22780,687302,20120565,641832725",
        "nnrbbrkq/1pp2ppp/3p4/p3p3/3P1P2/1P2P3/P1P3PP/NNRBBKRQ w GC - 1 9,31,827,24538,663082,19979594,549437308",
        "nnrkbbrq/1pp2p1p/p2pp1p1/2P5/8/8/PP1PPPPP/NNRKBBRQ w Ggc - 0 9,24,762,19283,624598,16838099,555230555",
        "nnr1brqb/1ppkp1pp/8/p2p1p2/1P1P4/N1P5/P3PPPP/N1RKBRQB w FC - 1 9,23,640,15471,444905,11343507,334123513",
        "nbnrkrbq/2ppp2p/p4p2/1P4p1/4PP2/8/1PPP2PP/NBNRKRBQ w FDfd - 0 9,31,826,26137,732175,23555139,686250413",
        "1nrbkr1q/1pppp1pp/1n6/p4p2/N1b4P/8/PPPPPPPB/N1RBKR1Q w FCfc - 2 9,27,862,24141,755171,22027695,696353497",
        "nnrkrbbq/pppp2pp/8/4pp2/4P3/P7/1PPPBPPP/NNKRR1BQ w c - 0 9,25,792,19883,636041,16473376,532214177",
        "n1rk1qbb/pppprpp1/2n4p/4p3/2PP3P/8/PP2PPP1/NNRKRQBB w ECc - 1 9,25,622,16031,425247,11420973,321855685",
        "bbq1rnkr/pnp1pp1p/1p1p4/6p1/2P5/2Q1P2P/PP1P1PP1/BB1NRNKR w HEhe - 2 9,36,870,30516,811047,28127620,799738334",
        "bq1brnkr/1p1ppp1p/1np5/p5p1/8/1N5P/PPPPPPP1/BQ1BRNKR w HEhe - 0 9,22,588,13524,380068,9359618,273795898",
        "bq1rn1kr/1pppppbp/Nn4p1/8/8/P7/1PPPPPPP/BQ1RNBKR w HDhd - 1 9,24,711,18197,542570,14692779,445827351",
        "bqnr1kr1/pppppp1p/6p1/5n2/4B3/3N2PP/PbPPPP2/BQNR1KR1 w GDgd - 2 9,31,1132,36559,1261476,43256823,1456721391",
        "qbb1rnkr/ppp3pp/4n3/3ppp2/1P3PP1/8/P1PPPN1P/QBB1RNKR w HEhe - 0 9,28,696,20502,541886,16492398,456983120",
        "1nbrnbkr/p1ppp1pp/1p6/5p2/4q1PP/3P4/PPP1PP2/QNBRNBKR w HDhd - 1 9,30,1162,33199,1217278,36048727,1290346802",
        "q1brnkrb/p1pppppp/n7/1p6/P7/3P1P2/QPP1P1PP/1NBRNKRB w GDgd - 0 9,32,827,26106,718243,23143989,673147648",
        "qbnrb1kr/ppp1pp1p/3p4/2n3p1/1P6/6N1/P1PPPPPP/QBNRB1KR w HDhd - 2 9,29,751,23132,610397,19555214,530475036",
        "q1rbbnkr/pppp1p2/2n3pp/2P1p3/3P4/8/PP1NPPPP/Q1RBBNKR w HChc - 2 9,29,806,24540,687251,21694330,619907316",
        "q1r1bbkr/pnpp1ppp/2n1p3/1p6/2P2P2/2N1N3/PP1PP1PP/Q1R1BBKR w HChc - 2 9,32,1017,32098,986028,31204371,958455898",
        "2rnbkrb/pqppppp1/1pn5/7p/2P5/P1R5/QP1PPPPP/1N1NBKRB w Ggc - 4 9,26,625,16506,434635,11856964,336672890",
        "qbnr1kbr/p2ppppp/2p5/1p6/4n2P/P4N2/1PPP1PP1/QBNR1KBR w HDhd - 0 9,27,885,23828,767273,21855658,706272554",
        "qnrbnk1r/pp1pp2p/5p2/2pbP1p1/3P4/1P6/P1P2PPP/QNRBNKBR w HChc - 0 9,26,954,24832,892456,24415089,866744329",
        "qnrnk1br/p1p2ppp/8/1pbpp3/8/PP2N3/1QPPPPPP/1NR1KBBR w HChc - 0 9,26,783,20828,634267,17477825,539674275",
        "qnrnkrbb/Bpppp2p/6p1/5p2/5P2/3PP3/PPP3PP/QNRNKR1B w FCfc - 1 9,28,908,25730,861240,25251641,869525254",
        "bbnqrn1r/ppppp2k/5p2/6pp/7P/1QP5/PP1PPPP1/B1N1RNKR w HE - 0 9,33,643,21790,487109,16693640,410115900",
        "b1qbrnkr/ppp1pp2/2np4/6pp/4P3/2N4P/PPPP1PP1/BQ1BRNKR w HEhe - 0 9,28,837,24253,745617,22197063,696399065",
        "bnqr1bkr/pp1ppppp/2p5/4N3/5P2/P7/1PPPPnPP/BNQR1BKR w HDhd - 3 9,25,579,13909,341444,8601011,225530258",
        "nbbqr1kr/1pppp1pp/8/p1n2p2/4P3/PN6/1PPPQPPP/1BB1RNKR w HEhe - 0 9,30,745,23416,597858,19478789,515473678",
        "nqbbrn1r/p1pppp1k/1p4p1/7p/4P3/1R3B2/PPPP1PPP/NQB2NKR w H - 0 9,24,504,13512,317355,9002073,228726497",
        "nqbr1bkr/p1p1ppp1/1p1n4/3pN2p/1P6/8/P1PPPPPP/NQBR1BKR w HDhd - 0 9,29,898,26532,809605,24703467,757166494",
        "nb1r1nkr/ppp1ppp1/2bp4/7p/3P2qP/P6R/1PP1PPP1/NBQRBNK1 w Dhd - 1 9,38,1691,60060,2526992,88557078,3589649998",
        "n1rbbnkr/1p1pp1pp/p7/2p1qp2/1B3P2/3P4/PPP1P1PP/NQRB1NKR w HChc - 0 9,24,913,21595,807544,19866918,737239330",
        "nqrnbbkr/p2p1p1p/1pp5/1B2p1p1/1P3P2/4P3/P1PP2PP/NQRNB1KR w HChc - 0 9,33,913,30159,843874,28053260,804687975",
        "nqr1bkrb/ppp1pp2/2np2p1/P6p/8/2P4P/1P1PPPP1/NQRNBKRB w GCgc - 0 9,24,623,16569,442531,12681936,351623879",
        "nb1rnkbr/pqppppp1/1p5p/8/1PP4P/8/P2PPPP1/NBQRNKBR w HDhd - 1 9,31,798,24862,694386,22616076,666227466",
        "nqrbnkbr/2p1p1pp/3p4/pp3p2/6PP/3P1N2/PPP1PP2/NQRB1KBR w HChc - 0 9,24,590,14409,383690,9698432,274064911",
        "nqrnkbbr/pp1p1p1p/4p1p1/1p6/8/5P1P/P1PPP1P1/NQRNKBBR w HChc - 0 9,30,1032,31481,1098116,34914919,1233362066",
        "bbnrqrk1/pp2pppp/4n3/2pp4/P7/1N5P/BPPPPPP1/B2RQNKR w HD - 2 9,23,708,17164,554089,14343443,481405144",
        "bnr1qnkr/p1pp1p1p/1p4p1/4p1b1/2P1P3/1P6/PB1P1PPP/1NRBQNKR w HChc - 1 9,30,931,29249,921746,30026687,968109774",
        "b1rqnbkr/ppp1ppp1/3p3p/2n5/P3P3/2NP4/1PP2PPP/B1RQNBKR w HChc - 0 9,24,596,15533,396123,11099382,294180723",
        "bnrqnr1b/pp1pkppp/2p1p3/P7/2P5/7P/1P1PPPP1/BNRQNKRB w GC - 0 9,24,572,15293,390903,11208688,302955778",
        "n1brq1kr/bppppppp/p7/8/4P1Pn/8/PPPP1P2/NBBRQNKR w HDhd - 0 9,20,570,13139,371247,9919113,284592289",
        "1br1bnkr/ppqppp1p/1np3p1/8/1PP4P/4N3/P2PPPP1/NBRQB1KR w HChc - 1 9,32,798,24765,691488,22076141,670296871",
        "nrqbb1kr/1p1pp1pp/2p3n1/p4p2/3PP3/P5N1/1PP2PPP/NRQBB1KR w HBhb - 0 9,32,791,26213,684890,23239122,634260266",
        "nrqn1bkr/ppppp1pp/4b3/8/4P1p1/5P2/PPPP3P/NRQNBBKR w HBhb - 0 9,29,687,20223,506088,15236287,398759980",
        "nbrq1kbr/Bp3ppp/2pnp3/3p4/5P2/2P4P/PP1PP1P1/NBRQNK1R w HChc - 0 9,40,1271,48022,1547741,56588117,1850696281",
        "nrqbnkbr/1p2ppp1/p1p4p/3p4/1P6/8/PQPPPPPP/1RNBNKBR w HBhb - 0 9,28,757,23135,668025,21427496,650939962",
        "nrqn1bbr/2ppkppp/4p3/pB6/8/2P1P3/PP1P1PPP/NRQNK1BR w HB - 1 9,27,642,17096,442653,11872805,327545120",
        "nrqnkrb1/p1ppp2p/1p4p1/4bp2/4PP1P/4N3/PPPP2P1/NRQ1KRBB w FBfb - 1 9,27,958,27397,960350,28520172,995356563",
        "1bnrnqkr/pbpp2pp/8/1p2pp2/P6P/3P1N2/1PP1PPP1/BBNR1QKR w HDhd - 0 9,27,859,23475,773232,21581178,732696327",
        "b1rbnqkr/1pp1ppp1/2n4p/p2p4/5P2/1PBP4/P1P1P1PP/1NRBNQKR w HChc - 0 9,26,545,14817,336470,9537260,233549184",
        "1nrnqbkr/p1pppppp/1p6/8/2b2P2/P1N5/1PP1P1PP/BNR1QBKR w HChc - 2 9,24,668,17716,494866,14216070,406225409",
        "1nrnqkrb/2ppp1pp/p7/1p3p2/5P2/N5K1/PPPPP2P/B1RNQ1RB w gc - 0 9,33,725,23572,559823,18547476,471443091",
        "nbbr1qkr/p1pppppp/8/1p1n4/3P4/1N3PP1/PPP1P2P/1BBRNQKR w HDhd - 1 9,28,698,20527,539625,16555068,458045505",
        "1rbbnqkr/1pnppp1p/p5p1/2p5/2P4P/5P2/PP1PP1PR/NRBBNQK1 w Bhb - 1 9,24,554,14221,362516,9863080,269284081",
        "nrb1qbkr/2pppppp/2n5/p7/2p5/4P3/PPNP1PPP/1RBNQBKR w HBhb - 0 9,23,618,15572,443718,12044358,360311412",
    };

    try init_all(allocator);

    //nnue.engine_using_nnue = false;

    if (nnue.engine_using_nnue) {
        try nnue.embed_and_init();

        nnue.engine_loaded_net = true;
    }

    try tt.TT.init(128 + 1);
    defer tt.TT.deinit();

    std.debug.print("\n", .{});

    // Iterate over each test case
    for (test_cases) |test_case| {

        // Parse the test case
        var parts = std.mem.splitScalar(u8, test_case, ',');
        const fen = parts.next() orelse return error.InvalidTestCase;
        var expected_nodes: [7]?u64 = .{null} ** 7;

        // Parse node counts for depths 1 to 7
        inline for (0..5) |i| {
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

            //std.debug.print("Depth: {}: ", .{depth});

            if (expected_nodes[depth - 1]) |expected| {
                const report = perft.perft_test(&curr_pos, @as(u4, @intCast(depth)));

                if (report.nodes != expected) {
                    std.debug.print(
                        "Perft failed for FEN: {s}, depth: {d}, expected: {d}, got: {d}\n",

                        .{ fen, depth, expected, report.nodes },
                    );

                    try std.testing.expectEqual(expected, report.nodes);
                } else {
                    std.debug.print(
                        "Perft passed for depth: {d}, expected: {d}, got: {d}\n",

                        .{ depth, expected, report.nodes },
                    );
                }
            }
        }
    }
}

pub fn run_datagen(allocator: std.mem.Allocator, cfg: datagen.GenConfig) !void {
    // For datagen, enable NNUE if available and initialize it explicitly
    // so that search/eval matches normal UCI runs.
    nnue.engine_using_nnue = true;
    try nnue.embed_and_init();
    nnue.engine_loaded_net = true;

    try init_all(allocator);

    try tt.TT.init(128 + 1);
    defer tt.TT.deinit();

    // Prepare a base position to ensure tables, etc., are sane
    var tmp = Position.new();
    try tmp.set(start_position);

    // Normalize filename and run binary generation
    var final_name = cfg.filename;
    if (!std.mem.endsWith(u8, final_name, ".bin")) {
        final_name = std.fmt.allocPrint(allocator, "{s}.bin", .{cfg.filename}) catch cfg.filename;
    }
    try datagen.generate_binary(allocator, final_name, cfg);
}

// Uncomment below for datagen support
// pub fn run_datagen(allocator: std.mem.Allocator, cfg: datagen.GenConfig) !void {
//     // For datagen, enable NNUE if available and initialize it explicitly
//     // so that search/eval matches normal UCI runs.
//     nnue.engine_using_nnue = true;
//     try nnue.embed_and_init();
//     nnue.engine_loaded_net = true;

//     try init_all(allocator);

//     try tt.TT.init(128 + 1);
//     defer tt.TT.deinit();

//     // Prepare a base position to ensure tables, etc., are sane
//     var tmp = Position.new();
//     try tmp.set(start_position);

//     // Normalize filename and run binary generation
//     var final_name = cfg.filename;
//     if (!std.mem.endsWith(u8, final_name, ".bin")) {
//         final_name = std.fmt.allocPrint(allocator, "{s}.bin", .{cfg.filename}) catch cfg.filename;
//     }
//     try datagen.generate_binary(allocator, final_name, cfg);
// }

test "perft for positions" {

    // Initialize required databases

    attacks.initialise_all_databases();

    zobrist.initialise_zobrist_keys();

    const test_cases = [_][]const u8{
        // "b1q1rrkb/pppppppp/3nn3/8/P7/1PPP4/4PPPP/BQNNRKRB w GE - 1 9,20,479,10471,273318,6417013,177654692",
        // "bnnqrbkr/pp1p2p1/2p1p2p/5p2/1P5P/1R6/P1PPPPP1/BNNQRBK1 w Ehe - 0 9,33,1022,32724,1024721,32898113,1047360456",
        // "bqnb1rkr/pp3ppp/3ppn2/2p5/5P2/P2P4/NPP1P1PP/BQ1BNRKR w HFhf - 2 9,21,528,12189,326672,8146062,227689589",
        // "2nnrbkr/p1qppppp/8/1ppb4/6PP/3PP3/PPP2P2/BQNNRBKR w HEhe - 1 9,21,807,18002,667366,16253601,590751109",
        // "qbbnnrkr/2pp2pp/p7/1p2pp2/8/P3PP2/1PPP1KPP/QBBNNR1R w hf - 0 9,22,593,13440,382958,9183776,274103539",
        // "1nbbnrkr/p1p1ppp1/3p4/1p3P1p/3Pq2P/8/PPP1P1P1/QNBBNRKR w HFhf - 0 9,28,1120,31058,1171749,34030312,1250970898",
        // "qnbnr1kr/ppp1b1pp/4p3/3p1p2/8/2NPP3/PPP1BPPP/QNB1R1KR w HEhe - 1 9,29,899,26578,824055,24851983,775718317",
        // "q1bnrkr1/ppppp2p/2n2p2/4b1p1/2NP4/8/PPP1PPPP/QNB1RRKB w ge - 1 9,30,860,24566,732757,21093346,649209803",
        // "qbn1brkr/ppp1p1p1/2n4p/3p1p2/P7/6PP/QPPPPP2/1BNNBRKR w HFhf - 0 9,25,635,17054,465806,13203304,377184252",
        // "qnnbbrkr/1p2ppp1/2pp3p/p7/1P5P/2NP4/P1P1PPP1/Q1NBBRKR w HFhf - 0 9,24,572,15243,384260,11110203,293989890",
        // "qn1rbbkr/ppp2p1p/1n1pp1p1/8/3P4/P6P/1PP1PPPK/QNNRBB1R w hd - 2 9,28,811,23175,679699,19836606,594527992",
        // "qnr1bkrb/pppp2pp/3np3/5p2/8/P2P2P1/NPP1PP1P/QN1RBKRB w GDg - 3 9,33,823,26895,713420,23114629,646390782",
        // "qb1nrkbr/1pppp1p1/1n3p2/p1B4p/8/3P1P1P/PPP1P1P1/QBNNRK1R w HEhe - 0 9,31,855,25620,735703,21796206,651054626",
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1,20,400,8902,197281,4865609,119060324",
        "8/6b1/7r/Pk2p3/1n4Np/K1P1P3/1B6/1b6 b - - 0 1,33,377,10572,125127,3449824,41620286",
        // "8/6b1/5N1r/Pk2p3/1n5p/K1P1P3/1B6/1b6 w - - 0 1,15,418,5061,133804,1609522,42418189",
        // "rnbqkbnr/1ppppppp/8/p7/2P5/P7/1P1PPPPP/RNBQKBNR b KQkq - 0 1,21,441,10227,242685,6164778,161038368",
        // "2bqkbnr/rppppppp/n7/p7/2P5/PP6/3PPPPP/RNBQKBNR w KQk - 0 1,19,398,8820,204573,5072498,129375227",
        // "2bqkbnr/rpp1pppp/n2p4/p7/2P3P1/PP5P/3PPP2/RNBQKBNR b KQk - 0 1,26,470,13090,284308,8296635,202882781",
        // "2kq4/4Q3/1n1p3b/r1NP1bpp/pPP2PP1/p3P2P/4K3/2R1NBR1 b - - 0 1,33,1452,43353,1829511,55661262,2275321404",
        // "8/8/6P1/8/1kb4P/8/1K6/8 w - - 0 1,6,100,649,10016,77697,1114696",
        // "8/8/6P1/8/2b4P/2k5/8/3K4 b - - 0 1,16,73,1091,6579,97531,769922",
        // "8/8/4b1P1/7P/8/3k4/8/3K4 w - - 0 1,4,66,359,5458,42728,620333",
        // "8/8/5k2/p1q1N1N1/PP1rp1P1/3P4/2RKp3/7r b - - 0 1,47,934,36151,744017,28368703,600039464",
        // "8/6kN/8/2q1N3/Pp1rp1P1/3P4/2RKp3/7r w - - 0 1,19,861,15432,656842,12401507,507590831",
        // "6B1/8/8/8/6k1/1p1p4/6K1/8 b - - 0 1,7,89,720,8957,80437,1023277",
        // "6B1/8/8/8/7k/1p1p1K2/8/8 w - - 0 1,11,56,730,5198,69538,634670",
        // "8/8/8/6k1/8/1B1p2K1/8/8 b - - 0 1,6,95,631,9412,74180,1036141",
        // "k7/3K4/8/6n1/6p1/8/7r/8 w - - 0 1,7,163,801,17800,93543,2076111",
        // "3k4/3P4/8/2P5/7R/1K6/8/4b1b1 w - - 0 1,21,298,5635,84820,1583235,24946858",
        // "3Q4/4k3/8/2P5/1R6/1K6/8/4b1b1 b - - 0 1,3,96,1197,38271,515558,16572719",
        // "3n4/2k2b2/8/3p2p1/8/3K4/8/1N6 w - - 0 1,9,152,1463,25573,252916,4522589",
        // "8/5bk1/8/2Pp4/8/1K6/8/8 w - d6 0 1,8,104,736,9287,62297,824064",
        // "8/8/1k6/8/2pP4/8/5BK1/8 b - d3 0 1,8,104,736,9287,62297,824064",
        // "8/8/1k6/2b5/2pP4/8/5K2/8 b - d3 0 1,15,126,1928,13931,206379,1440467",
        // "8/5k2/8/2Pp4/2B5/1K6/8/8 w - d6 0 1,15,126,1928,13931,206379,1440467",
        // "5k2/8/8/8/8/8/8/4K2R w K - 0 1,,,,,,661072",
        // "4k2r/8/8/8/8/8/8/5K2 b k - 0 1,,,,,,661072",
        // "3k4/8/8/8/8/8/8/R3K3 w Q - 0 1,,,,,,803711",
        // "r3k3/8/8/8/8/8/8/3K4 b q - 0 1,,,,,,803711",
        // "r3k2r/1b4bq/8/8/8/8/7B/R3K2R w KQkq - 0 1,,,,1274206",
        // "r3k2r/7b/8/8/8/8/1B4BQ/R3K2R b KQkq - 0 1,,,,1274206",
        // "r3k2r/8/3Q4/8/8/5q2/8/R3K2R b KQkq - 0 1,,,,1720476",
        // "r3k2r/8/5Q2/8/8/3q4/8/R3K2R w KQkq - 0 1,,,,1720476",
        // "2K2r2/4P3/8/8/8/8/8/3k4 w - - 0 1,,,,,,3821001",
        // "3K4/8/8/8/8/8/4p3/2k2R2 b - - 0 1,,,,,,3821001",
        // "8/8/1P2K3/8/2n5/1q6/8/5k2 b - - 0 1,,,,,1004658",
        // "5K2/8/1Q6/2N5/8/1p2k3/8/8 w - - 0 1,,,,,1004658",
        // "4k3/1P6/8/8/8/8/K7/8 w - - 0 1,,,,,,217342",
        // "8/k7/8/8/8/8/1p6/4K3 b - - 0 1,,,,,,217342",
        // "8/P1k5/K7/8/8/8/8/8 w - - 0 1,,,,,,92683",
        // "8/8/8/8/8/k7/p1K5/8 b - - 0 1,,,,,,92683",
        // "K1k5/8/P7/8/8/8/8/8 w - - 0 1,,,,,,2217",
        // "8/8/8/8/8/p7/8/k1K5 b - - 0 1,,,,,,2217",
        // "8/k1P5/8/1K6/8/8/8/8 w - - 0 1,,,,,,,567584",
        // "8/8/8/8/1k6/8/K1p5/8 b - - 0 1,,,,,,,567584",
        // "8/8/2k5/5q2/5n2/8/5K2/8 b - - 0 1,,,,23527",
        // "8/5k2/8/5N2/5Q2/2K5/8/8 w - - 0 1,,,,23527",
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

        //const uci_move = try algebraic_to_uci(test_case.move, &curr_pos);
        //defer std.testing.allocator.free(uci_move);
        std.debug.print("algebraic: {s}\n", .{test_case.move});

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
