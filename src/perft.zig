const std = @import("std");
const position = @import("position.zig");
const tt = @import("tt.zig");
const zobrist = @import("zobrist.zig");

const DefaultPrng = std.rand.DefaultPrng;
const Random = std.rand.Random;

const Color = position.Color;
const Position = position.Position;
const Move = position.Move;
const MoveFlags = position.MoveFlags;

pub const PerftResult = struct {
    time_elapsed: u64,
    nodes: u64,
};

const perft_stats = struct {
    captures: u64,
    en_passant: u64,
    castles: u64,
    promotions: u64,
    nodes: u64,
    checks: u64,
    checkmate: u64,

    pub fn init() perft_stats {
        var this: perft_stats = undefined;
        this.captures = 0;
        this.en_passant = 0;
        this.castles = 0;
        this.promotions = 0;
        this.nodes = 0;
        this.checks = 0;
        this.checkmate = 0;

        return this;
    }

    pub fn add(self: *perft_stats, other: perft_stats) void {
        self.captures += other.captures;
        self.en_passant += other.en_passant;
        self.castles += other.castles;
        self.promotions += other.promotions;
        self.nodes += other.nodes;
        self.checks += other.checks;
        self.checkmate += other.checkmate;
    }

    pub fn print_perft_stats(self: perft_stats) void {
        std.debug.print("Nodes: {}\n", .{self.nodes});
        std.debug.print("captures: {}\n", .{self.captures});
        std.debug.print("en_passant: {}\n", .{self.en_passant});
        std.debug.print("castles: {}\n", .{self.castles});
        std.debug.print("promotions: {}\n", .{self.promotions});
        std.debug.print("checks: {}\n", .{self.checks});
        std.debug.print("checkmate: {}\n", .{self.checkmate});
    }
};

// Perft resources
// https://github.com/elcabesa/vajolet/blob/master/tests/perft.txt
// https://www.chessprogramming.org/Perft_Results
// http://www.talkchess.com/forum3/viewtopic.php?f=7&t=47318

pub fn perft_with_stats(comptime color: Color, pos: *Position, depth: u4) perft_stats {
    var ps = perft_stats.init();

    if (depth == 0) {
        ps.nodes = 1;
        return ps;
    }

    const opp = if (color == Color.White) Color.Black else Color.White;

    var list = std.ArrayList(Move).initCapacity(std.heap.c_allocator, 48) catch unreachable;
    defer list.deinit();

    pos.generate_legals(color, &list);
    if (depth == 1) {
        for (list.items) |m| {
            ps.nodes += 1;
            switch (m.flags) {
                MoveFlags.QUIET => {},
                MoveFlags.DOUBLE_PUSH => {},
                MoveFlags.OO => {
                    ps.castles += 1;
                },
                MoveFlags.OOO => {
                    ps.castles += 1;
                },
                MoveFlags.EN_PASSANT => {
                    ps.en_passant += 1;
                    ps.captures += 1;
                },
                MoveFlags.PR_KNIGHT => {
                    ps.promotions += 1;
                },
                MoveFlags.PR_BISHOP => {
                    ps.promotions += 1;
                },
                MoveFlags.PR_ROOK => {
                    ps.promotions += 1;
                },
                MoveFlags.PR_QUEEN => {
                    ps.promotions += 1;
                },
                MoveFlags.PC_KNIGHT => {
                    ps.promotions += 1;
                    ps.captures += 1;
                },
                MoveFlags.PC_BISHOP => {
                    ps.promotions += 1;
                    ps.captures += 1;
                },
                MoveFlags.PC_ROOK => {
                    ps.promotions += 1;
                    ps.captures += 1;
                },
                MoveFlags.PC_QUEEN => {
                    ps.promotions += 1;
                    ps.captures += 1;
                },
                MoveFlags.CAPTURE => {
                    ps.captures += 1;
                },
                else => {},
            }

            pos.play(m, color);
            if (pos.in_check(color.change_side())) {
                ps.checks += 1;

                var list2 = std.ArrayList(Move).initCapacity(std.heap.c_allocator, 48) catch unreachable;
                defer list2.deinit();
                pos.generate_legals(color.change_side(), &list2);
                if (list2.items.len == 0) ps.checkmate += 1;
            }
            pos.undo(m, color);
        }
    } else {
        for (list.items) |move| {
            pos.play(move, color);
            const ps_ret = perft_with_stats(opp, pos, depth - 1);
            ps.add(ps_ret);

            pos.undo(move, color);
        }
    }

    return ps;
}

pub fn perft(comptime color: Color, pos: *Position, depth: u4) u64 {
    var nodes: u64 = 0;

    const opp = if (color == Color.White) Color.Black else Color.White;

    var list = std.ArrayList(Move).initCapacity(std.heap.c_allocator, 48) catch unreachable;
    defer list.deinit();

    pos.generate_legals(color, &list);

    if (depth == 1) {
        return @as(u64, @intCast(list.items.len));
    }

    for (list.items) |move| {
        pos.play(move, color);
        nodes += perft(opp, pos, depth - 1);
        pos.undo(move, color);
    }

    return nodes;
}

pub fn perft_test_div(pos: *Position, depth: u4) void {
    std.debug.print("\n\n", .{});
    pos.print_unicode();
    std.debug.print("Running Perft {}:\n\n", .{depth});

    if (pos.side_to_play == Color.White) {
        perft_div(Color.White, pos, depth);
    } else {
        perft_div(Color.Black, pos, depth);
    }
}

pub fn perft_div(comptime color: Color, pos: *Position, depth: u4) void {
    var nodes: u64 = 0;
    var branch: u64 = 0;
    const opp = if (color == Color.White) Color.Black else Color.White;

    var list = std.ArrayList(Move).initCapacity(std.heap.c_allocator, 48) catch unreachable;
    defer list.deinit();

    pos.generate_legals(color, &list);

    for (list.items) |move| {
        pos.play(move, color);
        branch = perft(opp, pos, depth - 1);
        nodes += branch;
        pos.undo(move, color);

        move.print();
        std.debug.print(" {}\n", .{branch});
    }

    std.debug.print("\nMoves: {}\n", .{list.items.len});
    std.debug.print("Nodes: {}\n", .{nodes});
}

pub fn perft_test_with_print(pos: *Position, depth: u4) void {
    std.debug.print("\n\n", .{});
    pos.print_unicode();

    std.debug.print("Running Perft {}:\n", .{depth});

    var timer = std.time.Timer.start() catch unreachable;
    var nodes: u64 = 0;

    if (pos.side_to_play == Color.White) {
        nodes = perft(Color.White, pos, depth);
    } else {
        nodes = perft(Color.Black, pos, depth);
    }

    const elapsed = timer.read();
    std.debug.print("\n", .{});
    std.debug.print("Nodes: {}\n", .{nodes});
    const mcs = @as(f64, @floatFromInt(elapsed)) / 1000.0;
    std.debug.print("Elapsed: {d:.2} microseconds (or {d:.6} seconds)\n", .{ mcs, mcs / 1000.0 / 1000.0 });
    const nps = @as(f64, @floatFromInt(nodes)) / (@as(f64, @floatFromInt(elapsed)) / 1000.0 / 1000.0 / 1000.0);
    std.debug.print("NPS: {d:.2} nodes/s (or {d:.4} mn/s)\n", .{ nps, nps / 1000.0 / 1000.0 });
}

pub fn perft_test(pos: *Position, depth: u4) PerftResult {
    var timer = std.time.Timer.start() catch unreachable;
    var nodes: u64 = 0;

    if (pos.side_to_play == Color.White) {
        nodes = perft(Color.White, pos, depth);
    } else {
        nodes = perft(Color.Black, pos, depth);
    }

    const elapsed = timer.read();

    return PerftResult{
        .time_elapsed = elapsed,
        .nodes = nodes,
    };
}

pub fn perft_test_with_stats(pos: *Position, depth: u4) void {
    std.debug.print("\n\n", .{});
    pos.print_unicode();
    var ps = perft_stats.init();

    std.debug.print("Running Perft {}:\n", .{depth});

    var timer = std.time.Timer.start() catch unreachable;

    if (pos.side_to_play == Color.White) {
        ps = perft_with_stats(Color.White, pos, depth);
    } else {
        ps = perft_with_stats(Color.Black, pos, depth);
    }

    const elapsed = timer.read();
    std.debug.print("\n", .{});
    ps.print_perft_stats();
    const mcs = @as(f64, @floatFromInt(elapsed)) / 1000.0;
    std.debug.print("Elapsed: {d:.2} microseconds (or {d:.6} seconds)\n", .{ mcs, mcs / 1000.0 / 1000.0 });
    const nps = @as(f64, @floatFromInt(ps.nodes)) / (@as(f64, @floatFromInt(elapsed)) / 1000.0 / 1000.0 / 1000.0);
    std.debug.print("NPS: {d:.2} nodes/s (or {d:.4} mn/s)\n", .{ nps, nps / 1000.0 / 1000.0 });
}
