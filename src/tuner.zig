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
    passed_pawn: [2][64]u8 = undefined,
    isolated_pawn: [2][8]u8 = undefined,
    blocked_passer: [2][8]u8 = undefined,
    supported_pawn: [2][8]u8 = undefined,
    pawn_phalanx: [2][8]u8 = undefined,
    knight_mobility: [2][9]u8 = undefined,
    bishop_mobility: [2][14]u8 = undefined,
    rook_mobility: [2][15]u8 = undefined,
    queen_mobility: [2][28]u8 = undefined,
    pawn_attacking: [2][6]u8 = undefined,
    knight_attacking: [2][6]u8 = undefined,
    bishop_attacking: [2][6]u8 = undefined,
    rook_attacking: [2][6]u8 = undefined,
    queen_attacking: [2][6]u8 = undefined,
    doubled_pawns: [2]u8 = undefined,
    bishop_pair: [2]u8 = undefined,

    pub fn init(self: *Tuner) void {
        const tuner = Tuner{
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

        @memset(self.passed_pawn[0][0..64], @as(u8, 0));
        @memset(self.passed_pawn[1][0..64], @as(u8, 0));

        @memset(self.isolated_pawn[0][0..8], @as(u8, 0));
        @memset(self.isolated_pawn[1][0..8], @as(u8, 0));

        @memset(self.blocked_passer[0][0..8], @as(u8, 0));
        @memset(self.blocked_passer[1][0..8], @as(u8, 0));

        @memset(self.supported_pawn[0][0..8], @as(u8, 0));
        @memset(self.supported_pawn[1][0..8], @as(u8, 0));

        @memset(self.pawn_phalanx[0][0..8], @as(u8, 0));
        @memset(self.pawn_phalanx[1][0..8], @as(u8, 0));

        @memset(self.knight_mobility[0][0..9], @as(u8, 0));
        @memset(self.knight_mobility[1][0..9], @as(u8, 0));

        @memset(self.bishop_mobility[0][0..14], @as(u8, 0));
        @memset(self.bishop_mobility[1][0..14], @as(u8, 0));

        @memset(self.rook_mobility[0][0..15], @as(u8, 0));
        @memset(self.rook_mobility[1][0..15], @as(u8, 0));

        @memset(self.queen_mobility[0][0..28], @as(u8, 0));
        @memset(self.queen_mobility[1][0..28], @as(u8, 0));

        @memset(self.pawn_attacking[0][0..6], @as(u8, 0));
        @memset(self.pawn_attacking[1][0..6], @as(u8, 0));

        @memset(self.knight_attacking[0][0..6], @as(u8, 0));
        @memset(self.knight_attacking[1][0..6], @as(u8, 0));

        @memset(self.bishop_attacking[0][0..6], @as(u8, 0));
        @memset(self.bishop_attacking[1][0..6], @as(u8, 0));

        @memset(self.rook_attacking[0][0..6], @as(u8, 0));
        @memset(self.rook_attacking[1][0..6], @as(u8, 0));

        @memset(self.queen_attacking[0][0..6], @as(u8, 0));
        @memset(self.queen_attacking[1][0..6], @as(u8, 0));

        @memset(self.doubled_pawns[0..2], @as(u8, 0));

        @memset(self.bishop_pair[0..2], @as(u8, 0));
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

        for (0..64) |sq| {
            try writer.print("PASSED_{}_{},", .{ c, sq });
        }

        for (0..8) |f| {
            try writer.print("ISOLATED_{}_{},", .{ c, f });
        }

        for (0..8) |r| {
            try writer.print("BLOCKED_{}_{},", .{ c, r });
        }

        for (0..8) |r| {
            try writer.print("SUPPORTED_{}_{},", .{ c, r });
        }

        for (0..8) |r| {
            try writer.print("PHAL_{}_{},", .{ c, r });
        }

        for (0..9) |r| {
            try writer.print("KN_MOB_{}_{},", .{ c, r });
        }

        for (0..14) |r| {
            try writer.print("BISH_MOB_{}_{},", .{ c, r });
        }

        for (0..15) |r| {
            try writer.print("ROOK_MOB_{}_{},", .{ c, r });
        }

        for (0..28) |r| {
            try writer.print("QN_MOB_{}_{},", .{ c, r });
        }

        for (0..6) |pt| {
            try writer.print("P_ATT_{}_{},", .{ c, pt });
        }

        for (0..6) |pt| {
            try writer.print("KN_ATT_{}_{},", .{ c, pt });
        }

        for (0..6) |pt| {
            try writer.print("BISH_ATT_{}_{},", .{ c, pt });
        }

        for (0..6) |pt| {
            try writer.print("ROOK_ATT_{}_{},", .{ c, pt });
        }

        for (0..6) |pt| {
            try writer.print("QN_ATT_{}_{},", .{ c, pt });
        }

        try writer.print("DOUBL_{},", .{c});

        try writer.print("BISH_PAIR_{},", .{c});
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

        for (0..64) |sq| {
            try writer.print("{},", .{self.passed_pawn[c][sq]});
        }

        for (0..8) |f| {
            try writer.print("{},", .{self.isolated_pawn[c][f]});
        }

        for (0..8) |r| {
            try writer.print("{},", .{self.blocked_passer[c][r]});
        }

        for (0..8) |r| {
            try writer.print("{},", .{self.supported_pawn[c][r]});
        }

        for (0..8) |r| {
            try writer.print("{},", .{self.pawn_phalanx[c][r]});
        }

        for (0..9) |r| {
            try writer.print("{},", .{self.knight_mobility[c][r]});
        }

        for (0..14) |r| {
            try writer.print("{},", .{self.bishop_mobility[c][r]});
        }

        for (0..15) |r| {
            try writer.print("{},", .{self.rook_mobility[c][r]});
        }

        for (0..28) |r| {
            try writer.print("{},", .{self.queen_mobility[c][r]});
        }

        for (0..6) |pt| {
            try writer.print("{},", .{self.pawn_attacking[c][pt]});
        }

        for (0..6) |pt| {
            try writer.print("{},", .{self.knight_attacking[c][pt]});
        }

        for (0..6) |pt| {
            try writer.print("{},", .{self.bishop_attacking[c][pt]});
        }

        for (0..6) |pt| {
            try writer.print("{},", .{self.rook_attacking[c][pt]});
        }

        for (0..6) |pt| {
            try writer.print("{},", .{self.queen_attacking[c][pt]});
        }

        try writer.print("{},", .{self.doubled_pawns[c]});

        try writer.print("{},", .{self.bishop_pair[c]});
    }

    pub const NPOS: u32 = 1_428_000;
    //pub const NPOS: u32 = 9_999_740;
    //pub const NPOS: u32 = 5_052_234;

    pub fn convertDataset(self: *Tuner) !void {
        var file = try std.fs.cwd().openFile("quiet-labeled.epd", .{});
        //var file = try std.fs.cwd().openFile("big3.epd", .{});
        //var file = try std.fs.cwd().openFile("quiet-labeled.epd", .{});
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
            var it = std.mem.splitScalar(u8, line, "[");
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
