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

const Position = position.Position;
const Color = position.Color;
const Move = position.Move;
const Search = search.Search;

const MoveList = lists.MoveList;

const fixedBufferStream = std.io.fixedBufferStream;
const peekStream = std.io.peekStream;

const UCI_COMMAND_MAX_LENGTH = 10000;

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

pub fn u32_from_str(str: []const u8) u32 {
    var x: u32 = 0;

    if (str[0] == '-') {
        return x;
    }

    for (str) |c| {
        std.debug.assert('0' <= c);
        std.debug.assert(c <= '9');
        x *= 10;
        x += c - '0';
    }
    return x;
}

fn usize_from_str(str: []const u8) usize {
    var x: usize = 0;

    if (str[0] == '-') {
        return x;
    }

    for (str) |c| {
        std.debug.assert('0' <= c);
        std.debug.assert(c <= '9');
        x *= 10;
        x += c - '0';
    }
    return x;
}

pub fn u64_from_str(str: []const u8) u64 {
    var x: u64 = 0;

    if (str[0] == '-') {
        return x;
    }

    for (str) |c| {
        std.debug.assert('0' <= c);
        std.debug.assert(c <= '9');
        x *= 10;
        x += c - '0';
    }
    return x;
}

pub fn init_all() void {
    attacks.initialise_all_databases();
    zobrist.initialise_zobrist_keys();
    evaluation.init_eval();
    search.init_lmr();
}

pub fn uci_loop(allocator: std.mem.Allocator) !void {
    init_all();

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

    var buffer = [1]u8{0} ** UCI_COMMAND_MAX_LENGTH;
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    mainloop: while (true) {

        //std.time.sleep(20 * 1000 * 1000);
        const input_full = (try stdin.readUntilDelimiter(&buffer, '\n'));
        if (input_full.len == 0) continue :mainloop;
        const input = std.mem.trimRight(u8, input_full, "\r");
        if (input.len == 0) continue :mainloop;

        var words = std.mem.splitScalar(u8, input, ' ');
        const command = words.next().?;

        if (std.mem.eql(u8, command, "uci")) {
            _ = try std.fmt.format(stdout, "id name Lambergar 1.3\n", .{});
            _ = try std.fmt.format(stdout, "id author Janez Podobnik\n", .{});
            _ = try std.fmt.format(stdout, "option name Hash type spin default {d} min {d} max {d}\n", .{ HASH_SIZE_DEFAULT, HASH_SIZE_MIN, HASH_SIZE_MAX });
            _ = try std.fmt.format(stdout, "option name Threads type spin default {d} min {d} max {d}\n", .{ 1, 1, MAX_THREADS });
            _ = try std.fmt.format(stdout, "option name UseNNUE type check default {}\n", .{nnue.engine_using_nnue});
            //_ = try std.fmt.format(stdout, "option name EvalFile type string default \n", .{});
            _ = try std.fmt.format(stdout, "option name Debug type check default {}\n", .{debug});
            _ = try std.fmt.format(stdout, "uciok\n", .{});
        } else if (std.mem.eql(u8, command, "go")) {

            // If a previous search is running, stop it and wait
            if (main_search_thread != null) {
                @atomicStore(bool, &thinkers[0].stop, true, .seq_cst);
                main_search_thread.?.join();
                main_search_thread = null;
            }

            // Reset stop flag for new search
            @atomicStore(bool, &thinkers[0].stop, false, .seq_cst);

            var ponder = false;
            var btime: ?u64 = null;
            var wtime: ?u64 = null;
            var binc: ?u32 = 0;
            var winc: ?u32 = 0;
            var depth: ?u32 = null;
            var nodes: ?u32 = null;
            var mate: ?u32 = null;
            var movetime: ?u64 = null;
            var movestogo: ?u32 = null;
            var infinite: bool = false;

            while (words.next()) |arg| {
                if (std.mem.eql(u8, arg, "searchmoves")) {
                    continue :mainloop; // unimplemented
                } else if (std.mem.eql(u8, arg, "ponder")) {
                    ponder = false;
                } else if (std.mem.eql(u8, arg, "wtime")) {
                    wtime = u64_from_str(words.next() orelse continue :mainloop);
                } else if (std.mem.eql(u8, arg, "btime")) {
                    btime = u64_from_str(words.next() orelse continue :mainloop);
                } else if (std.mem.eql(u8, arg, "winc")) {
                    winc = u32_from_str(words.next() orelse continue :mainloop);
                } else if (std.mem.eql(u8, arg, "binc")) {
                    binc = u32_from_str(words.next() orelse continue :mainloop);
                } else if (std.mem.eql(u8, arg, "movestogo")) {
                    movestogo = u32_from_str(words.next() orelse continue :mainloop);
                } else if (std.mem.eql(u8, arg, "depth")) {
                    depth = u32_from_str(words.next() orelse continue :mainloop);
                } else if (std.mem.eql(u8, arg, "nodes")) {
                    nodes = u32_from_str(words.next() orelse continue :mainloop);
                } else if (std.mem.eql(u8, arg, "mate")) {
                    mate = u32_from_str(words.next() orelse continue :mainloop);
                } else if (std.mem.eql(u8, arg, "movetime")) {
                    movetime = u64_from_str(words.next() orelse continue :mainloop);
                } else if (std.mem.eql(u8, arg, "infinite")) {
                    infinite = true;
                }
            }

            var rem_time: ?u64 = null;
            var rem_enemy_time: ?u64 = null;
            var time_inc: ?u32 = null;

            if (infinite) {
                thinkers[0].manager.termination = search.Termination.INFINITE;
            } else if (depth != null) {
                thinkers[0].max_depth = depth.?;
                thinkers[0].manager.termination = search.Termination.DEPTH;
            } else if (nodes != null) {
                thinkers[0].manager.max_nodes = nodes;
                thinkers[0].manager.termination = search.Termination.NODES;
            }

            if (movetime != null) {
                movetime = movetime;
                thinkers[0].manager.termination = search.Termination.MOVETIME;
            }
            if (movestogo != null) {
                movestogo = movestogo;
                thinkers[0].manager.termination = search.Termination.TIME;
            }
            if (wtime != null) {
                thinkers[0].manager.termination = search.Termination.TIME;
                if (pos[0].side_to_play == Color.White) {
                    rem_time = wtime;
                } else {
                    rem_enemy_time = wtime;
                }
            }
            if (btime != null) {
                thinkers[0].manager.termination = search.Termination.TIME;
                if (pos[0].side_to_play == Color.Black) {
                    rem_time = btime;
                } else {
                    rem_enemy_time = btime;
                }
            }
            if (winc != null and pos[0].side_to_play == Color.White) {
                time_inc = winc;
            }
            if (binc != null and pos[0].side_to_play == Color.Black) {
                time_inc = binc;
            }

            thinkers[0].manager.set_time_limits(movestogo, movetime, rem_time, time_inc);
            tt.TT.increase_age();

            for (1..num_threads) |i| {
                thinkers[i].manager.termination = search.Termination.INFINITE;
                pos[i] = pos[0].copy();
            }
            for (1..num_threads) |i| {
                const _delta: i32 = @as(i32, 5 + @divFloor(@as(i32, @intCast(i)), 2) * 2);
                //const _delta: i32 = @as(i32, 9); //2 + @as(i32, @intCast(i)));
                threads[i] = std.Thread.spawn(.{}, search.start_search, .{ &thinkers[i], &pos[i], _delta }) catch |e| {
                    _ = try std.fmt.format(stdout, "Error spawning thread {}: {}\n", .{ i, e });
                    unreachable;
                };
            }

            main_search_thread = try std.Thread.spawn(.{}, search.start_main_search, .{ &thinkers[0], &pos[0] });
            //main_search_thread.detach();
        } else if (std.mem.eql(u8, command, "quit")) {
            @atomicStore(bool, &thinkers[0].stop, true, .seq_cst);
            break :mainloop;
        } else if (std.mem.eql(u8, command, "exit")) {
            @atomicStore(bool, &thinkers[0].stop, true, .seq_cst);
            break :mainloop;
        } else if (std.mem.eql(u8, command, "stop")) {
            //thinker.stop = true;
            @atomicStore(bool, &thinkers[0].stop, true, .seq_cst);
        } else if (std.mem.eql(u8, command, "isready")) {
            _ = try std.fmt.format(stdout, "readyok\n", .{});
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
                        const hash_size = u64_from_str(words.next() orelse continue);
                        tt.TT.deinit();
                        try tt.TT.init(hash_size);
                    } else continue;
                } else if ((std.mem.eql(u8, arg, "Clear")) and (std.mem.eql(u8, words.next().?, "Hash"))) {
                    tt.TT.clear();
                } else if (std.mem.eql(u8, arg, "Threads")) {
                    arg = words.next().?;
                    if (std.mem.eql(u8, arg, "value")) {
                        num_threads = usize_from_str(words.next() orelse continue);
                        @atomicStore(bool, &thinkers[0].stop, true, .seq_cst);
                        _ = try std.fmt.format(stdout, "Threads set to: {}\n", .{num_threads});
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
                } else continue;
            } else continue;
        } else if (std.mem.eql(u8, command, "ucinewgame")) {
            for (0..MAX_THREADS) |i| {
                thinkers[i].clear_for_new_game();
            }
            tt.TT.clear();
            try pos[0].set(start_position);
        } else if (std.mem.eql(u8, command, "position")) {
            const pos_variant = words.next().?;
            pos[0] = Position.new();
            var maybe_moves_str: ?[]const u8 = null;
            if (std.mem.eql(u8, pos_variant, "fen")) {
                var parts = std.mem.splitSequence(u8, words.rest(), "moves");
                const fen = std.mem.trim(u8, parts.next().?, " ");
                try pos[0].set(fen);

                const remaining = parts.rest();
                if (remaining.len != 0) {
                    maybe_moves_str = remaining;
                }
            } else if (std.mem.eql(u8, pos_variant, "startpos")) {
                try pos[0].set(start_position);
                if (words.next()) |keyword| {
                    if (std.mem.eql(u8, keyword, "moves")) {
                        maybe_moves_str = words.rest();
                    }
                }
            } else continue;

            if (maybe_moves_str) |moves_str| {
                var moves = std.mem.splitScalar(u8, std.mem.trim(u8, moves_str, " "), ' ');
                while (moves.next()) |move_str| {
                    const move = Move.parse_move(move_str, &pos[0]) catch continue;
                    if (pos[0].side_to_play == Color.White) {
                        pos[0].play(move, Color.White);
                    } else {
                        pos[0].play(move, Color.Black);
                    }
                }
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
                _ = try std.fmt.format(stdout, "\n{}. ", .{i});
                move.print();
            }
            _ = try std.fmt.format(stdout, "\n", .{});
        } else if (std.mem.eql(u8, command, "eval")) {
            _ = try std.fmt.format(stdout, "{d} (from white's perspective)\n", .{pos[0].eval.eval(&pos[0], Color.White)});
        } else if (std.mem.eql(u8, command, "perft")) {
            const depth = u32_from_str(words.next() orelse "1");
            const report = perft.perft_test(&pos[0], @as(u4, @intCast(depth)));
            const elapsed_nanos = @as(f64, @floatFromInt(report.time_elapsed));
            const elapsed_seconds = elapsed_nanos / 1_000_000_000;

            _ = try std.fmt.format(stdout, "{d:.3}s elapsed\n", .{elapsed_seconds});
            _ = try std.fmt.format(stdout, "{} nodes explored\n", .{report.nodes});

            const nps = @as(f64, @floatFromInt(report.nodes)) / elapsed_seconds;
            if (nps < 1000) {
                _ = try std.fmt.format(stdout, "{d:.3}N/s\n", .{nps});
            } else if (nps < 1_000_000) {
                _ = try std.fmt.format(stdout, "{d:.3}KN/s\n", .{nps / 1000});
            } else {
                _ = try std.fmt.format(stdout, "{d:.3}MN/s\n", .{nps / 1_000_000});
            }
        } else if (std.mem.eql(u8, command, "seepos")) {
            var list: MoveList = .{};

            if (pos[0].side_to_play == Color.White) {
                pos[0].generate_legals(Color.White, &list);
            } else {
                pos[0].generate_legals(Color.Black, &list);
            }

            _ = try std.fmt.format(stdout, "SEE thresholds\n", .{});

            for (0..list.count) |i| {
                const move = list.moves[i];
                const thr = ms.see_value(&pos[0], move, false);
                _ = try std.fmt.format(stdout, "{}. ", .{i});
                move.print();
                _ = try std.fmt.format(stdout, " SEE result: {}\n", .{thr});
            }
        } else if (std.mem.eql(u8, command[0..3], "see")) {
            const move_str = command[4..];
            const move = Move.parse_move(move_str, &pos[0]) catch continue; // Parse UCI move
            if (move.is_empty()) {
                _ = try std.fmt.format(stdout, "Invalid move format\n", .{});
                continue;
            }
            const see_val = ms.see_value(&pos[0], move, false);
            _ = try std.fmt.format(stdout, "\nsee_value {}\n", .{see_val});
        }
    }

    if (main_search_thread != null) {
        @atomicStore(bool, &thinkers[0].stop, true, .seq_cst);
        main_search_thread.?.join();
    }
}
