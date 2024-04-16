const std = @import("std");
const perft = @import("perft.zig");
const position = @import("position.zig");
const evaluation = @import("evaluation.zig");
const tt = @import("tt.zig");
const attacks = @import("attacks.zig");
const zobrist = @import("zobrist.zig");
const search = @import("search.zig");
const ms = @import("movescorer.zig");

const Position = position.Position;
const Color = position.Color;
const Move = position.Move;
const Search = search.Search;

const fixedBufferStream = std.io.fixedBufferStream;
const peekStream = std.io.peekStream;

const UCI_COMMAND_MAX_LENGTH = 10000;

const HASH_SIZE_MIN = 1;
const HASH_SIZE_DEFAULT = 128;
const HASH_SIZE_MAX = 4096;

pub const empty_board = "8/8/8/8/8/8/8/8 w - - ";
pub const start_position = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 ";

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

    var debug = false;

    init_all();
    tt.TT.init(128 + 1);
    defer tt.tt_allocator.free(tt.TT.ttArray);

    var pos = Position.new();
    try pos.set(start_position);
    var thinker = Search.new();
    thinker.clear_for_new_game();
    var main_search_thread: std.Thread = undefined;

    var buffer = [1]u8{0} ** UCI_COMMAND_MAX_LENGTH;
    const stdin = std.io.getStdIn().reader();        
    const stdout = std.io.getStdOut().writer();

    mainloop: while (true) {

        //std.time.sleep(20 * 1000 * 1000);
        const input_full = (try stdin.readUntilDelimiter(&buffer, '\n'));
        if (input_full.len == 0) continue :mainloop;
        const input = std.mem.trimRight(u8, input_full, "\r");
        if (input.len == 0) continue :mainloop;        

        var words = std.mem.split(u8, input, " ");
        const command = words.next().?;

        if (std.mem.eql(u8, command, "uci")) {
            _ = try std.fmt.format(stdout, "id name Lambergar v0.5.2\n", .{});
            _ = try std.fmt.format(stdout, "id author Janez Podobnik\n", .{});
            _ = try std.fmt.format(stdout, "option name Hash type spin default {d} min {d} max {d}\n", .{ HASH_SIZE_DEFAULT, HASH_SIZE_MIN, HASH_SIZE_MAX});  
            _ = try std.fmt.format(stdout, "uciok\n", .{});       
        } else if (std.mem.eql(u8, command, "go")) {            
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
                    ponder = true;
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
                thinker.manager.termination = search.Termination.INFINITE;
            } else if (depth != null) {
                thinker.max_depth = depth.?;
                thinker.manager.termination = search.Termination.DEPTH;
            } else if (nodes != null) {
                thinker.manager.max_nodes = nodes;
                thinker.manager.termination = search.Termination.NODES;
            }

            if (movetime != null) {
                movetime = movetime;
                thinker.manager.termination = search.Termination.MOVETIME;
            }
            if (movestogo != null) {
                movestogo = movestogo;
                thinker.manager.termination = search.Termination.TIME;
            }
            if (wtime != null) {
                thinker.manager.termination = search.Termination.TIME;
                if (pos.side_to_play == Color.White) {
                    rem_time = wtime;
                } else {
                    rem_enemy_time = wtime;
                }
            }
            if (btime != null) {
                thinker.manager.termination = search.Termination.TIME;
                if (pos.side_to_play == Color.Black) {
                    rem_time = btime;
                } else {
                    rem_enemy_time = btime;
                }
            }
            if (winc != null and pos.side_to_play == Color.White) {
                time_inc = winc;
            }
            if (binc != null and pos.side_to_play == Color.Black) {
                time_inc = binc;
            }

            thinker.manager.set_time_limits(movestogo, movetime, rem_time, time_inc);
            tt.TT.increase_age();

            main_search_thread = try std.Thread.spawn(std.Thread.SpawnConfig{}, search.start_search, .{ &thinker, &pos });
            main_search_thread.detach();               
        } else if (std.mem.eql(u8, command, "quit")) {
            @atomicStore(bool, &thinker.stop, true, std.builtin.AtomicOrder.Unordered);
            break :mainloop;
        } else if (std.mem.eql(u8, command, "exit")) {
            @atomicStore(bool, &thinker.stop, true, std.builtin.AtomicOrder.Unordered);
            break :mainloop;            
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
                        tt.TT.init(hash_size);
                    } else continue;
                } else if ((std.mem.eql(u8, arg, "Clear")) and (std.mem.eql(u8, words.next().?, "Hash"))) {
                    tt.TT.clear();
                } else if (std.mem.eql(u8, arg, "Threads")) {} else continue;
            } else continue;
        } else if (std.mem.eql(u8, command, "ucinewgame")) {
            thinker.clear_for_new_game();
            tt.TT.clear();
            try pos.set(start_position);
        } else if (std.mem.eql(u8, command, "position")) {
            const pos_variant = words.next().?;
            pos = Position.new();
            var maybe_moves_str: ?[]const u8 = null;
            if (std.mem.eql(u8, pos_variant, "fen")) {
                // this part gets a bit messy - we concatenate the rest of the uci line, then split it on "moves"
                var parts = std.mem.split(u8, words.rest(), "moves");
                const fen = std.mem.trim(u8, parts.next().?, " ");
                try pos.set(fen);

                const remaining = parts.rest();
                if (remaining.len != 0) {
                    maybe_moves_str = remaining;
                }
            } else if (std.mem.eql(u8, pos_variant, "startpos")) {
                try pos.set(start_position);
                if (words.next()) |keyword| {
                    if (std.mem.eql(u8, keyword, "moves")) {
                        maybe_moves_str = words.rest();
                    }
                }
            } else continue;

            if (maybe_moves_str) |moves_str| {
                var moves = std.mem.split(u8, std.mem.trim(u8, moves_str, " "), " ");
                while (moves.next()) |move_str| {
                    const move = Move.parse_move(move_str, &pos) catch continue;
                    if (pos.side_to_play == Color.White) {
                        pos.play(move, Color.White);
                    } else {
                        pos.play(move, Color.Black);
                    }
                }
            }
        } else if (std.mem.eql(u8, command, "stop")) {
            //thinker.stop = true;
            @atomicStore(bool, &thinker.stop, true, std.builtin.AtomicOrder.Unordered);
        } else if (std.mem.eql(u8, command, "board")) {
            pos.print_unicode();
        } else if (std.mem.eql(u8, command, "moves")) {
            var list = std.ArrayList(Move).initCapacity(allocator, 48) catch unreachable;
            defer list.deinit();

            if (pos.side_to_play == Color.White) {
                pos.generate_legals(Color.White, &list);
            } else {
                pos.generate_legals(Color.Black, &list);
            }

            for (list.items, 1..) |move, i| {
                std.debug.print("\n{}. ", .{i});
                move.print();
            }
            std.debug.print("\n", .{});
        } else if (std.mem.eql(u8, command, "eval")) {
            std.debug.print("{d} (from white's perspective)\n", .{pos.eval.eval(&pos, Color.White)});
        } else if (std.mem.eql(u8, command, "perft")) {
            const depth = u32_from_str(words.next() orelse "1");
            const report = perft.perft_test(&pos, @as(u4, @intCast(depth)));
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
        } else if (std.mem.eql(u8, command, "see")) {
            var list = std.ArrayList(Move).initCapacity(allocator, 48) catch unreachable;
            defer list.deinit();

            if (pos.side_to_play == Color.White) {
                pos.generate_legals(Color.White, &list);
            } else {
                pos.generate_legals(Color.Black, &list);
            }

            std.debug.print("SEE thresholds\n", .{});

            for (list.items, 1..) |move, i| {

                const thr = ms.see_value(&pos, move, false);
                std.debug.print("{}. ", .{i});
                move.print();
                std.debug.print(" SEE result: {}\n", .{thr});

                    // for (0..2400) |j| {
                    //     const thr = @as(i32, 1200) - @as(i32, @intCast(j));
                    //     if (ms.see(&pos, move, thr)) {
                    //         std.debug.print("{}. ", .{i});
                    //         move.print();
                    //         std.debug.print(" SEE result: {}\n", .{thr});
                    //         break;
                    //     }
                    // }
            }
        }
    }
}