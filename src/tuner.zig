const std = @import("std");
const fs = std.fs;
const io = std.io;

const position = @import("position.zig");
const evaluation = @import("evaluation.zig");
const bb = @import("bitboard.zig");

const Position = position.Position;
const Piece = position.Piece;
const PieceType = position.PieceType;
const Color = position.Color;
const Evaluation = evaluation.Evaluation;

const NPIECE_TYPES = position.NPIECE_TYPES;

pub const Tuner = struct {
    pos_count: u32 = 0,

    mat: [2][NPIECE_TYPES]u8 = undefined,
    psqt: [2][NPIECE_TYPES][64]u8 = undefined,

    pub fn init(self: *Tuner) void {
        var tuner = Tuner{
            .pos_count = 0,
        };

        self.* = tuner;
        self.clear_probe_arrays();
    }

    pub inline fn clear_probe_arrays(self: *Tuner) void {
        @memset(self.mat[0][0..NPIECE_TYPES], @as(u8, 0));
        @memset(self.mat[1][0..NPIECE_TYPES], @as(u8, 0));

        for (0..NPIECE_TYPES) |pt| {
            @memset(self.psqt[0][pt][0..64], @as(u8, 0));
            @memset(self.psqt[1][pt][0..64], @as(u8, 0));
        }
    }

    pub fn new() Tuner {
        return Tuner{
            .pos_count = 0,
        };
    }

    pub fn write_header(self: *Tuner, fileOut: fs.File, comptime color: Color) !void {
        _ = self;

        const c = if (color == Color.White) 0 else 1;
        const writer = fileOut.writer();

        for (0..NPIECE_TYPES) |p| {
            try writer.print("MAT_{}_{},", .{ c, p });
        }

        for (0..NPIECE_TYPES) |p| {
            for (0..64) |sq| {
                try writer.print("PSQT_{}_{}_{},", .{ c, p, sq });
            }
        }
    }

    pub fn write_params(self: *Tuner, fileOut: fs.File, comptime color: Color) !void {
        const c = if (color == Color.White) 0 else 1;
        const writer = fileOut.writer();

        for (0..NPIECE_TYPES) |p| {
            try writer.print("{},", .{self.mat[c][p]});
        }

        for (0..NPIECE_TYPES) |p| {
            for (0..64) |sq| {
                try writer.print("{},", .{self.psqt[c][p][sq]});
            }
        }
    }

    pub const NPOS: u32 = 1_428_000;
    //pub const NPOS: u32 = 5_052_234;
    //pub const NPOS: u32 = 9_999_740;

    pub fn convertDataset(self: *Tuner) !void {
        var file = try std.fs.cwd().openFile("quiet-labeled.epd", .{});
        //var file = try std.fs.cwd().openFile("big3.epd", .{});
        //var file = try std.fs.cwd().openFile("E12.33-1M-D12-Resolved.book", .{});

        defer file.close();

        var buf_reader = std.io.bufferedReader(file.reader());
        var in_stream = buf_reader.reader();

        var fileOut = try fs.cwd().createFile("data.csv", .{ .truncate = false });
        defer fileOut.close();

        const writer = fileOut.writer();

        var buf: [1024]u8 = undefined;
        self.pos_count = 0;

        std.debug.print("\nStarting conversion ...\n", .{});

        try writer.print("ID,", .{});
        try writer.print("FEN,", .{});
        try writer.print("RESULT,", .{});
        try writer.print("PHASE_0,PHASE_1,", .{});

        try self.write_header(fileOut, Color.White);
        //try writer.print(",", .{});
        try self.write_header(fileOut, Color.Black);
        try writer.print("\n", .{});

        while (try in_stream.readUntilDelimiterOrEof(&buf, '\n')) |line| {
            var it = std.mem.split(u8, line, "[");
            const fen = it.first();
            const result_str = it.next();

            if (@mod(self.pos_count, 100) == 0) {
                std.debug.print("\x1b[1G", .{});
                std.debug.print("\x1b[1;31mPosition id: {}/{} - {}%", .{ self.pos_count, NPOS, @divTrunc(self.pos_count * 100, NPOS) });
            }

            var results: i8 = 10;
            if (std.mem.eql(u8, result_str orelse "", "0.0]")) {
                results = -1;
            } else if (std.mem.eql(u8, result_str orelse "", "0.5]")) {
                results = 0;
            } else if (std.mem.eql(u8, result_str orelse "", "1.0]")) {
                results = 1;
            } else {
                std.debug.print("String does not match any known patterns.\n\n", .{});
            }

            var pos = Position.new();
            self.clear_probe_arrays();
            try pos.set(fen);
            _ = pos.eval.clean_eval(&pos, self);

            try writer.print("{},", .{self.pos_count});
            try writer.print("{s},", .{fen});
            try writer.print("{},", .{results});
            try writer.print("{},{},", .{ pos.eval.phase[0], pos.eval.phase[1] });

            try self.write_params(fileOut, Color.White);
            //try writer.print(",", .{});
            try self.write_params(fileOut, Color.Black);
            try writer.print("\n", .{});

            self.pos_count += 1;
        }

        std.debug.print("\n\x1b[0mFinished converting {} fen strings\n", .{self.pos_count});
    }
};
