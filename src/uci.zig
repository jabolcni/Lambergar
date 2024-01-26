//! Implements the Universal chess interface
const std = @import("std");
const perft = @import("perft.zig");
const position = @import("position.zig");
const evaluation = @import("evaluation.zig");
const tt = @import("tt.zig");
const search = @import("search.zig");

const Position = position.Position;
const Color = position.Color;
const Move = position.Move;

const fixedBufferStream = std.io.fixedBufferStream;
const peekStream = std.io.peekStream;
const Allocator = std.mem.Allocator;

const UCI_COMMAND_MAX_LENGTH = 10000;

pub const start_position = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 ";

fn u32_from_str(str: []const u8) u32 {
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

fn i32_from_str(str: []const u8) i32 {
    var x: i32 = 0;
    var is_negative = false;
    var start_index: usize = 0;

    if (str[0] == '-') {
        is_negative = true;
        start_index = 1;
    }

    for (str[start_index..]) |c| {
        std.debug.assert('0' <= c);
        std.debug.assert(c <= '9');
        x *= 10;
        x += c - '0';
    }

    if (is_negative) {
        x = -x;
    }

    return x;
}

fn u64_from_str(str: []const u8) u64 {
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

/// Reads a block of non-whitespace characters and skips any number of following whitespaces
pub fn read_word(comptime Reader: type, src: Reader) !?[]const u8 {
    var buffer = [1]u8{0} ** 20; // assume no word is longer than 20 bytes
    const word = try src.readUntilDelimiter(&buffer, ' ');

    // skip any number of spaces
    var peekable = peekStream(1, src);
    var b = try peekable.reader().readByte();
    while (b == ' ') {
        b = try peekable.reader().readByte();
    }
    try peekable.putBackByte(b);
    return word;
}

const FenError = error{
    missing_field,
};

/// Reads a block of non-whitespace characters and skips any number of following whitespaces
pub fn read_fen(comptime Reader: type, src: Reader, allocator: Allocator) ![]const u8 {
    return std.mem.concat(allocator, u8, &.{
        (try read_word(Reader, src)) orelse return FenError.missing_field,
        (try read_word(Reader, src)) orelse return FenError.missing_field,
        (try read_word(Reader, src)) orelse return FenError.missing_field,
        (try read_word(Reader, src)) orelse return FenError.missing_field,
        (try read_word(Reader, src)) orelse return FenError.missing_field,
    });
}

/// Note that these are not all uci commands, just the ones
/// that cannot be trivially handled by next_command
pub const GuiCommandTag = enum(u8) {
    // uci commands
    uci,
    isready,
    quit,
    newgame,
    position,
    debug,
    go,
    stop,
    // non-standard uci commands
    eval,
    board,
    moves,
    perft,
    see,
};

pub const EngineCommandTag = enum(u8) {
    uciok,
    id,
    option,
    readyok,
    bestmove,
    info,
    score,
    report_perft,
};

pub const GuiCommand = union(GuiCommandTag) {
    uci,
    isready,
    quit,
    newgame,
    position: Position,
    debug: bool,
    go: struct {
        ponder: bool,
        btime: ?u64,
        wtime: ?u64,
        binc: ?u32,
        winc: ?u32,
        depth: ?u32,
        nodes: ?u32,
        mate: ?u32,
        movetime: ?u64,
        movestogo: ?u32,
        infinite: bool,
    },
    stop,
    eval,
    board,
    moves,
    perft: u32,
    see,
};

pub const EngineCommand = union(EngineCommandTag) {
    uciok: void,
    id: struct { key: []const u8, value: []const u8 },
    option: struct {
        name: []const u8,
        option_type: []const u8,
        default: ?[]const u8 = null,
        min: ?[]const u8 = null,
        max: ?[]const u8 = null,
        option_var: ?[]const u8 = null,
    },
    readyok: void,
    bestmove: Move,
    info: []const u8,
    score: i32,
    report_perft: perft.PerftResult,
};

pub fn send_command(command: EngineCommand, allocator: Allocator) !void {
    const stdout = std.io.getStdOut().writer();
    switch (command) {
        EngineCommandTag.uciok => _ = try stdout.write("uciok\n"),
        EngineCommandTag.id => |keyvalue| _ = try std.fmt.format(stdout, "id {s} {s}\n", keyvalue),
        EngineCommandTag.readyok => {
            _ = try std.fmt.format(stdout, "readyok\n", .{});
        },
        EngineCommandTag.bestmove => |move| {
            const move_name = move.to_str(allocator);
            defer allocator.free(move_name);

            _ = try std.fmt.format(stdout, "bestmove {s}\n", .{move_name});
        },
        EngineCommandTag.info => |info| {
            _ = try std.fmt.format(stdout, "info {s}\n", .{info});
        },
        EngineCommandTag.score => |score| {
            _ = try std.fmt.format(stdout, "info score cp {} \n", .{score});
        },
        EngineCommandTag.option => |option| {
            _ = try std.fmt.format(stdout, "option name {s} type {s}", .{ option.name, option.option_type });
            if (option.default) |default| {
                _ = try std.fmt.format(stdout, " default {s}", .{default});
            }
            if (option.min) |min| {
                _ = try std.fmt.format(stdout, " min {s}", .{min});
            }
            if (option.max) |max| {
                _ = try std.fmt.format(stdout, " max {s}", .{max});
            }
            if (option.option_var) |option_var| {
                _ = try std.fmt.format(stdout, " var {s}", .{option_var});
            }
            _ = try stdout.write("\n");
        },
        EngineCommandTag.report_perft => |report| {
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
        },
    }
}

pub fn next_command(allocator: Allocator) !GuiCommand {
    _ = allocator;
    var buffer = [1]u8{0} ** UCI_COMMAND_MAX_LENGTH;
    const stdin = std.io.getStdIn().reader();

    read_command: while (true) {
        const input_full = (try stdin.readUntilDelimiter(&buffer, '\n'));
        if (input_full.len == 0) continue;
        const input = std.mem.trimRight(u8, input_full, "\r");
        if (input.len == 0) continue;

        var words = std.mem.split(u8, input, " ");
        const command = words.next().?;

        if (std.mem.eql(u8, command, "uci")) {
            return GuiCommand.uci;
        } else if (std.mem.eql(u8, command, "debug")) {
            const arg = words.next().?;
            if (std.mem.eql(u8, arg, "on")) {
                return GuiCommand{ .debug = true };
            } else if (std.mem.eql(u8, arg, "off")) {
                return GuiCommand{ .debug = false };
            } else continue;
        } else if (std.mem.eql(u8, command, "quit")) {
            return GuiCommand.quit;
        } else if (std.mem.eql(u8, command, "isready")) {
            return GuiCommand.isready;
        } else if (std.mem.eql(u8, command, "setoption")) {
            var arg = words.next().?;
            if (std.mem.eql(u8, arg, "name")) {
                arg = words.next().?;
                if (std.mem.eql(u8, arg, "Hash")) {
                    arg = words.next().?;
                    if (std.mem.eql(u8, arg, "value")) {
                        var hash_size = u64_from_str(words.next() orelse continue :read_command);
                        tt.TT.init(hash_size);
                    } else continue;
                } else if ((std.mem.eql(u8, arg, "Clear")) and (std.mem.eql(u8, words.next().?, "Hash"))) {
                    tt.TT.clear();
                } else if (std.mem.eql(u8, arg, "Threads")) {} else continue;
            } else continue;
        } else if (std.mem.eql(u8, command, "ucinewgame")) {
            return GuiCommand.newgame;
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
                // searchmoves

                if (std.mem.eql(u8, arg, "searchmoves")) {
                    unreachable; // unimplemented
                } else if (std.mem.eql(u8, arg, "ponder")) {
                    ponder = true;
                } else if (std.mem.eql(u8, arg, "wtime")) {
                    wtime = u64_from_str(words.next() orelse continue :read_command);
                } else if (std.mem.eql(u8, arg, "btime")) {
                    btime = u64_from_str(words.next() orelse continue :read_command);
                } else if (std.mem.eql(u8, arg, "winc")) {
                    winc = u32_from_str(words.next() orelse continue :read_command);
                } else if (std.mem.eql(u8, arg, "binc")) {
                    binc = u32_from_str(words.next() orelse continue :read_command);
                } else if (std.mem.eql(u8, arg, "movestogo")) {
                    movestogo = u32_from_str(words.next() orelse continue :read_command);
                } else if (std.mem.eql(u8, arg, "depth")) {
                    depth = u32_from_str(words.next() orelse continue :read_command);
                } else if (std.mem.eql(u8, arg, "nodes")) {
                    nodes = u32_from_str(words.next() orelse continue :read_command);
                } else if (std.mem.eql(u8, arg, "mate")) {
                    mate = u32_from_str(words.next() orelse continue :read_command);
                } else if (std.mem.eql(u8, arg, "movetime")) {
                    movetime = u64_from_str(words.next() orelse continue :read_command);
                } else if (std.mem.eql(u8, arg, "infinite")) {
                    infinite = true;
                }
            }

            return GuiCommand{
                .go = .{
                    .ponder = ponder,
                    .wtime = wtime,
                    .btime = btime,
                    .winc = winc,
                    .binc = binc,
                    .depth = depth,
                    .nodes = nodes,
                    .mate = mate,
                    .movetime = movetime,
                    .movestogo = movestogo,
                    .infinite = infinite,
                },
            };
        } else if (std.mem.eql(u8, command, "stop")) {
            return GuiCommand.stop;
        } else if (std.mem.eql(u8, command, "position")) {
            const pos_variant = words.next().?;
            var pos = Position.new();
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
            } else {
                continue;
            }

            if (maybe_moves_str) |moves_str| {
                var moves = std.mem.split(u8, std.mem.trim(u8, moves_str, " "), " ");
                while (moves.next()) |move_str| {
                    const move = Move.parse_move(move_str, &pos) catch continue :read_command;
                    if (pos.side_to_play == Color.White) {
                        pos.play(move, Color.White);
                    } else {
                        pos.play(move, Color.Black);
                    }
                }
            }
            return GuiCommand{ .position = pos };
        }
        // non-standard commands
        else if (std.mem.eql(u8, command, "eval")) {
            return GuiCommand.eval;
        } else if (std.mem.eql(u8, command, "board")) {
            return GuiCommand.board;
        } else if (std.mem.eql(u8, command, "moves")) {
            return GuiCommand.moves;
        } else if (std.mem.eql(u8, command, "perft")) {
            const depth = u32_from_str(words.next() orelse "1");
            return GuiCommand{ .perft = depth };
        } else if (std.mem.eql(u8, command, "see")) {
            return GuiCommand.see;
        }

        // ignore unknown commands
    }
}
