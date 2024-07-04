/// This NNUE code is based on https://github.com/dshawul/nnue-probe
/// which is a modified version of the CFish nnue code.
const std = @import("std");

const position = @import("position.zig");
const bb = @import("bitboard.zig");

const Position = position.Position;
const Move = position.Move;
const Color = position.Color;
const Piece = position.Piece;
const Square = position.Square;

const L1 = 128;
const L2 = 16;
const L3 = 16;

const NNUE_FILE = "debevec.nnue";
const fileNNUE = @embedFile(NNUE_FILE);

pub var engine_loaded_net: bool = true;
pub var engine_using_nnue: bool = true;

// 2*(pawns(8), knights(2), bishops(2), rooks(2), queen, king)
// +1 for the ending empty piece that Stockfish nnue expects
pub const PIECE_COUNT = 2 * (8 + 2 + 2 + 2 + 1 + 1) + 1;
comptime {
    std.debug.assert(PIECE_COUNT == 33);
}

pub const Accumulator = struct {
    accumulation: [2][L1]i16 = undefined,
    computedAccumulation: bool = false,
};

pub const NNUEData = struct {
    accumulator: Accumulator = Accumulator{},
};

const IndexList = std.BoundedArray(usize, 30);

pub fn evaluate(curr_accu: Accumulator, player: Color) i32 {
    const FV_SCALE = 16;
    const NetData = struct {
        input: [FT_OUT_DIM]u8,
        l1_out: [L2]u8,
        l2_out: [L2]u8,
    };
    var buf: NetData = undefined;

    transform(curr_accu, player, &buf.input);

    affineTxfm(&buf.input, &buf.l1_out, &l1_biases, &l1_weights);

    affineTxfm(&buf.l1_out, &buf.l2_out, &l2_biases, &l2_weights);

    const out_value = affinePropagate(&buf.l2_out, &out_biases, &out_weights);

    const ret = @divTrunc(out_value, FV_SCALE);

    return @as(i32, @intCast(ret));
}

pub const NNUEPosition = struct {
    player: Color = undefined,
    pieces: [PIECE_COUNT]u4 = undefined, // NNUE_PIECES
    squares: [PIECE_COUNT]u6 = undefined, // NNUE_SQUARES

    pub fn calculate(bns: Position) NNUEPosition {
        var ret: NNUEPosition = undefined;

        var index: usize = 2; // 0 and 1 are reserved for the two kings

        for (Piece.WHITE_PAWN.toU4()..Piece.BLACK_KING.toU4() + 1) |pc| {
            var bitboard = bns.piece_bb[pc];

            while (bitboard != 0) {
                const square = bb.pop_lsb(&bitboard);

                switch (pc) {
                    5 => {
                        ret.pieces[0] = @as(u4, @intCast(pc));
                        ret.squares[0] = square;
                    },
                    13 => {
                        ret.pieces[1] = @as(u4, @intCast(pc));
                        ret.squares[1] = square;
                    },
                    6, 7, 14 => {},
                    else => {
                        ret.pieces[index] = @as(u4, @intCast(pc));
                        ret.squares[index] = square;
                        index += 1;
                    },
                }
            }
        }

        ret.pieces[index] = 14;
        ret.squares[index] = 0;

        ret.player = bns.side_to_play;

        return ret;
    }
};

const PS = enum(u10) {
    W_PAWN = 1, // 0 * 64 + 1
    B_PAWN = 1 * 64 + 1,
    W_KNIGHT = 2 * 64 + 1,
    B_KNIGHT = 3 * 64 + 1,
    W_BISHOP = 4 * 64 + 1,
    B_BISHOP = 5 * 64 + 1,
    W_ROOK = 6 * 64 + 1,
    B_ROOK = 7 * 64 + 1,
    W_QUEEN = 8 * 64 + 1,
    B_QUEEN = 9 * 64 + 1,
    END = 10 * 64 + 1,
};

const PieceToIndex: [2][15]usize = .{
    .{
        @intFromEnum(PS.W_PAWN),
        @intFromEnum(PS.W_KNIGHT),
        @intFromEnum(PS.W_BISHOP),
        @intFromEnum(PS.W_ROOK),
        @intFromEnum(PS.W_QUEEN),
        0,
        0,
        0,
        @intFromEnum(PS.B_PAWN),
        @intFromEnum(PS.B_KNIGHT),
        @intFromEnum(PS.B_BISHOP),
        @intFromEnum(PS.B_ROOK),
        @intFromEnum(PS.B_QUEEN),
        0,
        0,
    },
    .{
        @intFromEnum(PS.B_PAWN),
        @intFromEnum(PS.B_KNIGHT),
        @intFromEnum(PS.B_BISHOP),
        @intFromEnum(PS.B_ROOK),
        @intFromEnum(PS.B_QUEEN),
        0,
        0,
        0,
        @intFromEnum(PS.W_PAWN),
        @intFromEnum(PS.W_KNIGHT),
        @intFromEnum(PS.W_BISHOP),
        @intFromEnum(PS.W_ROOK),
        @intFromEnum(PS.W_QUEEN),
        0,
        0,
    },
};

const FT_HALF_DIM = L1;
const FT_IN_DIM = @as(u32, 64) * @intFromEnum(PS.END);
const FT_OUT_DIM = FT_HALF_DIM * 2; // two sides
const TR_START = 3 * @sizeOf(u32) + 177;
const NN_START = TR_START + 4 + FT_OUT_DIM + FT_OUT_DIM * FT_IN_DIM;

comptime {
    std.debug.assert(FT_HALF_DIM % L1 == 0);
    std.debug.assert(FT_OUT_DIM % (2 * L2) == 0);
}

var ft_bs: [FT_HALF_DIM]i16 = undefined;
var ft_ws: [FT_HALF_DIM * FT_IN_DIM]i16 = undefined;

const L1_DIM = L2;
const L1_SIZE = L1 * 2;
var l1_biases: [L1_DIM]i32 = undefined;
var l1_weights: [L1_DIM * L1_SIZE]i8 = undefined;

const L2_DIM = L2;
const L2_SIZE = L2;
var l2_biases: [L2_DIM]i32 = undefined;
var l2_weights: [L2_DIM * L2_SIZE]i8 = undefined;

const OUT_DIM = 1;
const OUT_SIZE = L3;
var out_biases: [OUT_DIM]i32 = undefined;
var out_weights: [OUT_DIM * OUT_SIZE]i8 = undefined;

comptime {
    std.debug.assert(FT_HALF_DIM % L1 == 0);
    std.debug.assert(FT_OUT_DIM % (L2 * 2) == 0);
}

fn readU32(data: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, @ptrCast(data[offset .. offset + @sizeOf(u32)]), .little);
}

fn read_ft(data: []const u8, offset: usize) i16 {
    return std.mem.readInt(i16, @ptrCast(data[offset .. offset + @sizeOf(i16)]), .little);
}

fn read_bias(data: []const u8, offset: usize) i32 {
    return std.mem.readInt(i32, @ptrCast(data[offset .. offset + @sizeOf(i32)]), .little);
}

fn read_weight(data: []const u8, offset: usize) i8 {
    return std.mem.readInt(i8, @ptrCast(data[offset .. offset + @sizeOf(i8)]), .little);
}

pub fn verify_integrity(nnue_data: []u8) !void {
    // verify NNUE_FILE integrity
    const NNUE_VERSION: u32 = 0x7AF32F16;
    const HASH: u32 = 0x3e5aa6ee;
    const DESCRIPTION_LENGTH: u32 = 177;
    const TRANSFORMER_HASH: u32 = 0x5d69d7b8;
    const NETWORK_HASH: u32 = 0x63337156;

    const version = std.mem.readInt(u32, nnue_data[0..4], .little);
    try std.testing.expectEqual(NNUE_VERSION, version);
    const hash = readU32(nnue_data, 4);
    try std.testing.expectEqual(HASH, hash);
    const desc_len = readU32(nnue_data, 8);
    try std.testing.expectEqual(DESCRIPTION_LENGTH, desc_len);
    const tf_hash = readU32(nnue_data, TR_START);
    try std.testing.expectEqual(TRANSFORMER_HASH, tf_hash);
    const net_hash = readU32(nnue_data, NN_START);
    try std.testing.expectEqual(NETWORK_HASH, net_hash);
}

pub fn load_feature_layer(nnue_data: []u8) !void {
    var offset: usize = TR_START + 4;
    for (0..ft_bs.len) |i| {
        ft_bs[i] = read_ft(nnue_data, offset);
        offset += @sizeOf(i16);
    }

    offset = TR_START + 4 + FT_OUT_DIM;
    for (0..ft_ws.len) |i| {
        ft_ws[i] = read_ft(nnue_data, offset);
        offset += @sizeOf(i16);
    }
}

pub fn load_layer1(nnue_data: []u8) !void {
    var offset: usize = NN_START + 4;
    for (0..l1_biases.len) |i| {
        l1_biases[i] = read_bias(nnue_data, offset);
        offset += @sizeOf(i32);
    }

    for (0..L1_DIM) |d| {
        for (0..L1_SIZE) |s| {
            l1_weights[s * L1_DIM + d] = read_weight(nnue_data, offset);
            offset += @sizeOf(i8);
        }
    }
}

pub fn load_layer2(nnue_data: []u8) !void {
    var offset: usize = NN_START + 4 + L1_DIM * @sizeOf(i32) +
        L1_DIM * L1_SIZE * @sizeOf(i8);
    for (0..l2_biases.len) |i| {
        l2_biases[i] = read_bias(nnue_data, offset);
        offset += @sizeOf(i32);
    }

    for (0..L2_DIM) |d| {
        for (0..L2_SIZE) |s| {
            l2_weights[s * L2_DIM + d] = read_weight(nnue_data, offset);
            offset += @sizeOf(i8);
        }
    }
}

pub fn load_output_layer(nnue_data: []u8) !void {
    const OUTPUT_START = NN_START + 4 +
        L1_DIM * @sizeOf(i32) +
        L1_DIM * L1_SIZE * @sizeOf(i8) +
        L2_DIM * @sizeOf(i32) +
        L2_DIM * L2_SIZE * @sizeOf(i8);
    var offset: usize = OUTPUT_START;
    for (0..OUT_DIM) |i| {
        out_biases[i] = read_bias(nnue_data, offset);
        offset += @sizeOf(i32);
    }

    for (0..OUT_DIM) |d| {
        for (0..OUT_SIZE) |s| {
            out_weights[s * OUT_DIM + d] = read_weight(nnue_data, offset);
            offset += @sizeOf(i8);
        }
    }
}

pub fn init_specific_net(allocator: std.mem.Allocator, nnue_file_name: []const u8) !void {
    const file = try std.fs.cwd().openFile(nnue_file_name, .{ .mode = .read_only });
    defer file.close();

    std.debug.print("NNUE file loaded: {s}\n", .{nnue_file_name});

    const nnue_data = try allocator.alloc(u8, 22 << 20);
    defer allocator.free(nnue_data);

    const read_bytes = try file.readAll(nnue_data);

    const NNUE_FILESIZE: usize = 10_507_097;
    try std.testing.expectEqual(NNUE_FILESIZE, read_bytes);

    try verify_integrity(nnue_data);
    try load_feature_layer(nnue_data);
    try load_layer1(nnue_data);
    try load_layer2(nnue_data);
    try load_output_layer(nnue_data);
}

pub fn embed_and_init() !void {
    const nnue_data = @as([]u8, @constCast(fileNNUE));

    try verify_integrity(nnue_data);
    try load_feature_layer(nnue_data);
    try load_layer1(nnue_data);
    try load_layer2(nnue_data);
    try load_output_layer(nnue_data);
}

pub fn init(allocator: std.mem.Allocator) !void {
    const file = try std.fs.cwd().openFile(NNUE_FILE, .{ .mode = .read_only });
    defer file.close();

    std.debug.print("NNUE file loaded: {s}\n", .{NNUE_FILE});

    const nnue_data = try allocator.alloc(u8, 22 << 20);
    defer allocator.free(nnue_data);

    const read_bytes = try file.readAll(nnue_data);

    const NNUE_FILESIZE: usize = 10_507_097;
    try std.testing.expectEqual(NNUE_FILESIZE, read_bytes);

    try verify_integrity(nnue_data);
    try load_feature_layer(nnue_data);
    try load_layer1(nnue_data);
    try load_layer2(nnue_data);
    try load_output_layer(nnue_data);
}

inline fn orient(sq: u6, c: Color) u6 {
    return if (c == Color.White) sq else sq ^ 0x3F;
}

inline fn makeIndex(sq: u6, pc: u4, ksq: u6, color: Color) usize {
    const ret = orient(sq, color) +
        PieceToIndex[color.toU4()][@as(usize, @intCast(pc))] +
        @intFromEnum(PS.END) * @as(usize, @intCast(ksq));
    return @as(usize, @intCast(ret));
}

fn halfkpAppendActiveIndices(pos: NNUEPosition, color: Color, active: *IndexList) void {
    const ksq = orient(pos.squares[color.toU4()], color);

    var i: usize = 2;
    while (pos.pieces[i] != 14) : (i += 1) {
        active.appendAssumeCapacity(makeIndex(pos.squares[i], pos.pieces[i], ksq, color));
    }
}

fn affineTxfm(
    input: []u8,
    output: []u8,
    biases: []i32,
    weights: []i8,
) void {
    const SHIFT = 6;
    std.debug.assert(biases.len == L2);
    std.debug.assert(output.len == L2);

    var tmp: [L2]i32 = undefined;
    for (0..L2) |i| {
        tmp[i] = biases[i];
    }

    for (0..input.len) |idx| {
        if (input[idx] == 0) continue; // performance boost
        for (0..L2) |i| {
            const t = @as(i32, @intCast(input[idx])) * weights[output.len * idx + i];
            tmp[i] += t;
        }
    }

    for (0..output.len) |i| {
        output[i] = @as(u8, @intCast(std.math.clamp(tmp[i] >> SHIFT, 0, 127)));
    }
}

fn affinePropagate(
    input: []u8,
    biases: []i32,
    weights: []i8,
) i32 {
    var sum: i32 = biases[0];

    for (0..weights.len) |i| {
        const tmp = @as(i32, @intCast(weights[i])) * input[i];
        sum += tmp;
    }

    return sum;
}

/// Enumerates all the active pieces with `halfkpAppendActiveIndices` for both colors
/// and fills in the accumulator. This is an expensive function.
pub fn refreshAccumulator(pos: NNUEPosition) Accumulator {
    var accumulator = Accumulator{};

    var activeIndices: [2]IndexList = undefined;
    activeIndices[0] = IndexList.init(0) catch unreachable;
    activeIndices[1] = IndexList.init(0) catch unreachable;

    for (std.enums.values(Color)) |c| {
        halfkpAppendActiveIndices(pos, c, &activeIndices[c.toU4()]);

        for (&accumulator.accumulation[c.toU4()], 0..) |*item, idx| {
            item.* = ft_bs[idx];
        }

        for (activeIndices[c.toU4()].constSlice()) |index| {
            const offset = FT_HALF_DIM * index;
            for (0..FT_HALF_DIM) |j| {
                accumulator.accumulation[c.toU4()][j] += ft_ws[offset + j];
            }
        }
    }

    accumulator.computedAccumulation = true;

    return accumulator;
}

// Convert input features
fn transform(
    curr_accu: Accumulator,
    player: Color,
    output: []u8,
) void {
    std.debug.assert(output.len == FT_OUT_DIM);

    const accumulation = &(curr_accu.accumulation);

    const perspectives: [2]u4 = .{ player.toU4(), player.change_side().toU4() };
    for (0..2) |p| {
        const offset: usize = FT_HALF_DIM * p;

        for (0..FT_HALF_DIM) |i| {
            const sum: i16 = accumulation[perspectives[p]][i];
            const tmp = @as(u8, @intCast(std.math.clamp(sum, 0, 127)));
            output[offset + i] = tmp;
        }
    }
}
