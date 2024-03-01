const std = @import("std");
const bb = @import("bitboard.zig");
const position = @import("position.zig");
const attacks = @import("attacks.zig");
const zobrist = @import("zobrist.zig");
const perft = @import("perft.zig");
const tt = @import("tt.zig");
const evaluation = @import("evaluation.zig");
const search = @import("search.zig");
const uci = @import("uci.zig");
const ms = @import("movescorer.zig");
const tuner = @import("tuner.zig");

const Instant = std.time.Instant;

const Position = position.Position;
const Square = position.Square;
const Move = position.Move;
const MoveFlags = position.MoveFlags;
const Color = position.Color;
const Search = search.Search;
const PieceType = position.PieceType;
const Piece = position.Piece;

const GuiCommand = uci.GuiCommand;
const EngineCommand = uci.EngineCommand;
const send_command = uci.send_command;

const UCI_COMMAND_MAX_LENGTH = 1024;

pub const empty_board = "8/8/8/8/8/8/8/8 w - - ";
pub const start_position = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 ";

pub fn init_all() void {
    attacks.initialise_all_databases();
    zobrist.initialise_zobrist_keys();
    evaluation.init_eval();
    search.init_lmr();
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    init_all();
    tt.TT.init(128 + 1);
    defer tt.tt_allocator.free(tt.TT.ttArray);

    var pos = Position.new();
    try pos.set(start_position);
    var thinker = Search.new();
    var main_search_thread: std.Thread = undefined;

//        var tuner_instance = tuner.Tuner.new(); // TUNER ON
//        tuner_instance.init(); // TUNER ON
//        try tuner_instance.convertDataset(); // TUNER ON

    mainloop: while (true) {
        //std.time.sleep(20 * 1000 * 1000);
        const command = try uci.next_command(allocator);
        try switch (command) {
            GuiCommand.uci => {
                try send_command(EngineCommand{ .id = .{ .key = "name", .value = "Lambergar v0.5.0" } }, allocator);
                try send_command(EngineCommand{ .id = .{ .key = "author", .value = "Janez Podobnik" } }, allocator);
                try send_command(EngineCommand{ .option = .{ .name = "Hash", .option_type = "spin", .default = "128", .min = "1", .max = "4096" } }, allocator);
                //try send_command(EngineCommand{ .option = .{ .name = "Threads", .option_type = "spin", .default = "1", .min = "1", .max = "1" } }, allocator);
                try send_command(EngineCommand.uciok, allocator);
            },
            GuiCommand.isready => send_command(EngineCommand.readyok, allocator),
            GuiCommand.debug => {},
            GuiCommand.newgame => {
                thinker = Search.new();
                tt.TT.clear();
                try pos.set(start_position);
            },
            GuiCommand.position => {
                var bb_temp = command.position.piece_bb[Piece.WHITE_BISHOP.toU4()];
                bb_temp = command.position.piece_bb[Piece.WHITE_KING.toU4()];
                bb_temp = command.position.piece_bb[Piece.WHITE_KNIGHT.toU4()];
                bb_temp = command.position.piece_bb[Piece.WHITE_PAWN.toU4()];
                bb_temp = command.position.piece_bb[Piece.WHITE_QUEEN.toU4()];
                bb_temp = command.position.piece_bb[Piece.WHITE_ROOK.toU4()];
                bb_temp = command.position.piece_bb[Piece.BLACK_BISHOP.toU4()];
                bb_temp = command.position.piece_bb[Piece.BLACK_KING.toU4()];
                bb_temp = command.position.piece_bb[Piece.BLACK_KNIGHT.toU4()];
                bb_temp = command.position.piece_bb[Piece.BLACK_PAWN.toU4()];
                bb_temp = command.position.piece_bb[Piece.BLACK_QUEEN.toU4()];
                bb_temp = command.position.piece_bb[Piece.BLACK_ROOK.toU4()];

                pos = command.position;
            },
            GuiCommand.go => {
                var movetime: ?u64 = null;
                var movestogo: ?u32 = null;
                var rem_time: ?u64 = null;
                var rem_enemy_time: ?u64 = null;
                var time_inc: ?u32 = null;

                if (command.go.infinite) {
                    thinker.manager.termination = search.Termination.INFINITE;
                } else if (command.go.depth != null) {
                    thinker.max_depth = command.go.depth.?;
                    thinker.manager.termination = search.Termination.DEPTH;
                } else if (command.go.nodes != null) {
                    thinker.manager.max_nodes = command.go.nodes;
                    thinker.manager.termination = search.Termination.NODES;
                }
                if (command.go.movetime != null) {
                    movetime = command.go.movetime;
                    thinker.manager.termination = search.Termination.MOVETIME;
                }
                if (command.go.movestogo != null) {
                    movestogo = command.go.movestogo;
                    thinker.manager.termination = search.Termination.TIME;
                }
                if (command.go.wtime != null) {
                    thinker.manager.termination = search.Termination.TIME;
                    if (pos.side_to_play == Color.White) {
                        rem_time = command.go.wtime;
                    } else {
                        rem_enemy_time = command.go.wtime;
                    }
                }
                if (command.go.btime != null) {
                    thinker.manager.termination = search.Termination.TIME;
                    if (pos.side_to_play == Color.Black) {
                        rem_time = command.go.btime;
                    } else {
                        rem_enemy_time = command.go.btime;
                    }
                }
                if (command.go.winc != null and pos.side_to_play == Color.White) {
                    time_inc = command.go.winc;
                }
                if (command.go.binc != null and pos.side_to_play == Color.Black) {
                    time_inc = command.go.binc;
                }

                thinker.manager.set_time_limits(movestogo, movetime, rem_time, time_inc);
                tt.TT.increase_age();

                main_search_thread = try std.Thread.spawn(.{}, search.start_search, .{ &thinker, &pos });
                main_search_thread.detach();
            },
            GuiCommand.stop => {
                thinker.stop = true;
            },
            GuiCommand.board => {
                pos.print_unicode();
            },
            GuiCommand.eval => {
                std.debug.print("{d} (from white's perspective)\n", .{pos.eval.eval(&pos, Color.White)});
            },
            GuiCommand.moves => {
                var list = std.ArrayList(Move).initCapacity(std.heap.c_allocator, 48) catch unreachable;
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
            },
            GuiCommand.perft => |depth| {
                const report = perft.perft_test(&pos, @as(u4, @intCast(depth)));
                try send_command(EngineCommand{ .report_perft = report }, allocator);
            },
            GuiCommand.see => {
                var list = std.ArrayList(Move).initCapacity(std.heap.c_allocator, 48) catch unreachable;
                defer list.deinit();

                if (pos.side_to_play == Color.White) {
                    pos.generate_legals(Color.White, &list);
                } else {
                    pos.generate_legals(Color.Black, &list);
                }

                std.debug.print("SEE thresholds\n", .{});

                for (list.items, 1..) |move, i| {
                    for (0..2400) |j| {
                        var thr = @as(i32, 1200) - @as(i32, @intCast(j));
                        if (ms.see(&pos, move, thr)) {
                            std.debug.print("{}. ", .{i});
                            move.print();
                            std.debug.print(" SEE result: {}\n", .{thr});
                            break;
                        }
                    }
                }
            },
            GuiCommand.quit => {
                break :mainloop;
            },
        };
    }
}
