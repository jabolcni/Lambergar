const std = @import("std");

const position = @import("position.zig");
const bb = @import("bitboard.zig");

const Position = position.Position;
const Move = position.Move;
const Color = position.Color;
const Piece = position.Piece;
const PieceType = position.PieceType;
const Square = position.Square;

const L1 = 128;
const L2 = 16;
const L3 = 16;

const NNUE_FILE = "cop.nnue";

const fileNNUE = @embedFile(NNUE_FILE);

pub var engine_loaded_net: bool = true;
pub var engine_using_nnue: bool = true;

pub const Accumulator = struct {
    accumulation: [2][L1]i16 = undefined,
    eval: i32 = undefined,
    computed_accumulation: bool = false,
    computed_score: bool = false,
};

pub const DeltaPieces = struct {
    count: usize = 0,
    pieces: [3]u4 = undefined,
    from: [3]?u6 = undefined,
    to: [3]?u6 = undefined,

    pub fn reset(self: *DeltaPieces) void {
        self.count = 0;
    }

    pub fn move_piece_quiet(self: *DeltaPieces, pc: Piece, from: u6, to: u6) void {
        self.pieces[self.count] = pc.toU4();
        self.from[self.count] = from;
        self.to[self.count] = to;
        self.count += 1;
    }

    pub fn remove_piece(self: *DeltaPieces, pc: Piece, sq: u6) void {
        self.pieces[self.count] = pc.toU4();
        self.from[self.count] = sq;
        self.to[self.count] = null;
        self.count += 1;
    }

    pub fn put_piece(self: *DeltaPieces, pc: Piece, sq: u6) void {
        self.pieces[self.count] = pc.toU4();
        self.from[self.count] = null;
        self.to[self.count] = sq;
        self.count += 1;
    }

    pub fn move_piece(self: *DeltaPieces, from_pc: Piece, to_pc: Piece, from: u6, to: u6) void {
        self.move_piece_quiet(from_pc, from, to);
        self.remove_piece(to_pc, to);
    }

    pub fn debug_print(self: *DeltaPieces) void {
        std.debug.print("DeltaPieces (count = {}):\n", .{self.count});
        for (0..self.count) |i| {
            std.debug.print("  Piece: {}, From: {}, To: {}\n", .{ self.pieces[i], self.from[i], self.to[i] });
        }
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
var l1_weights: [L1_DIM * L1_SIZE]i8 align(32) = undefined;

const L2_DIM = L2;
const L2_SIZE = L2;
var l2_biases: [L2_DIM]i32 = undefined;
var l2_weights: [L2_DIM * L2_SIZE]i8 align(32) = undefined;

const OUT_DIM = 1;
const OUT_SIZE = L3;
var out_biases: [OUT_DIM]i32 = undefined;
var out_weights: [OUT_DIM * OUT_SIZE]i8 = undefined;

comptime {
    std.debug.assert(FT_HALF_DIM % L1 == 0);
    std.debug.assert(FT_OUT_DIM % (L2 * 2) == 0);
}

fn read_U32(data: []const u8, offset: usize) u32 {
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
    const hash = read_U32(nnue_data, 4);
    try std.testing.expectEqual(HASH, hash);
    const desc_len = read_U32(nnue_data, 8);
    try std.testing.expectEqual(DESCRIPTION_LENGTH, desc_len);
    const tf_hash = read_U32(nnue_data, TR_START);
    try std.testing.expectEqual(TRANSFORMER_HASH, tf_hash);
    const net_hash = read_U32(nnue_data, NN_START);
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

    const NNUE_FILESIZE: usize = 10_507_097;
    const nnue_data = try allocator.alloc(u8, NNUE_FILESIZE);
    defer allocator.free(nnue_data);

    const read_bytes = try file.readAll(nnue_data);

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
    const NNUE_FILESIZE: usize = 10_507_097; //10_507_097; //21_024_768;
    const nnue_data = try allocator.alloc(u8, NNUE_FILESIZE);
    defer allocator.free(nnue_data);

    const read_bytes = try file.readAll(nnue_data);

    try std.testing.expectEqual(NNUE_FILESIZE, read_bytes);

    try verify_integrity(nnue_data);
    try load_feature_layer(nnue_data);
    try load_layer1(nnue_data);
    try load_layer2(nnue_data);
    try load_output_layer(nnue_data);
}

fn orient(sq: u6, c: Color) u6 {
    return if (c == Color.White) sq else sq ^ 0x3F;
}

fn make_index(sq: u6, pc: u4, ksq: u6, color: Color) usize {
    const ret = orient(sq, color) +
        PieceToIndex[color.toU4()][@as(usize, @intCast(pc))] +
        @intFromEnum(PS.END) * @as(usize, @intCast(ksq));
    return @as(usize, @intCast(ret));
}

pub fn refresh_accumulator_side(pos: Position, accumulator: *Accumulator, comptime c: Color) void {
    var bitboard = pos.piece_bb[position.Piece.make_piece(c, PieceType.King).toU4()];
    const kingSquare = bb.pop_lsb(&bitboard);
    const orientedKingSquare = orient(kingSquare, c);

    std.mem.copyForwards(i16, accumulator.accumulation[c.toU4()][0..], &ft_bs);

    // Iterate over all pieces of the given color
    for (Piece.WHITE_PAWN.toU4()..Piece.BLACK_KING.toU4()) |pc| {
        //if (pc >= Piece.WHITE_KING.toU4() and pc < Piece.BLACK_PAWN.toU4()) continue;
        if (pc == Piece.WHITE_KING.toU4()) continue;

        bitboard = pos.piece_bb[pc];
        const ppc = @as(u4, @intCast(pc));

        while (bitboard != 0) {
            const square = bb.pop_lsb(&bitboard);

            // Compute index for the piece
            const index = make_index(square, ppc, orientedKingSquare, c);

            // Update accumulator with weights
            const offset = FT_HALF_DIM * index;
            for (0..FT_HALF_DIM) |j| {
                accumulator.accumulation[c.toU4()][j] += ft_ws[offset + j];
            }
        }
    }
}

pub fn refresh_accumulator(pos: Position) Accumulator {
    var accumulator = Accumulator{
        .computed_accumulation = false,
        .computed_score = false,
    };

    refresh_accumulator_side(pos, &accumulator, Color.White);
    refresh_accumulator_side(pos, &accumulator, Color.Black);

    accumulator.computed_accumulation = true;

    return accumulator;
}

pub fn incremental_update(pos: *Position) void {
    const accumulator: *Accumulator = &pos.history[pos.game_ply].accumulator;
    if (accumulator.computed_accumulation == true) {
        return;
    }

    if (pos.game_ply == 0) {
        // No history available, perform full refresh
        accumulator.* = refresh_accumulator(pos.*);
        return;
    }

    const prev_accu = &pos.history[pos.game_ply - 1].accumulator;
    if (!prev_accu.computed_accumulation) {
        // Previous accumulator invalid, fallback to full refresh
        accumulator.* = refresh_accumulator(pos.*);
        return;
    }

    const dp: *DeltaPieces = &pos.delta;
    if (dp.count == 0) { // we have null move, so we can just copy the accumulator
        std.mem.copyForwards(i16, accumulator.accumulation[0][0..], prev_accu.accumulation[0][0..]);
        std.mem.copyForwards(i16, accumulator.accumulation[1][0..], prev_accu.accumulation[1][0..]);
        accumulator.computed_accumulation = true;
        return;
    }

    const king_index: [2]u4 = .{ Piece.WHITE_KING.toU4(), Piece.BLACK_KING.toU4() };

    for (std.enums.values(Color)) |c| {
        const c_index = c.toU4();

        if (dp.pieces[0] == king_index[c_index]) {
            if (c == Color.White) {
                refresh_accumulator_side(pos.*, accumulator, Color.White);
            } else {
                refresh_accumulator_side(pos.*, accumulator, Color.Black);
            }
        } else {
            std.mem.copyForwards(i16, accumulator.accumulation[c_index][0..], prev_accu.accumulation[c_index][0..]);

            var bitboard = pos.piece_bb[position.Piece.make_piece(c, PieceType.King).toU4()];
            const kingSquare = bb.pop_lsb(&bitboard);
            const orientedKingSquare = orient(kingSquare, c);

            for (0..dp.count) |i| {
                const pc = dp.pieces[i];

                // Skip king pieces
                if (pc == king_index[0] or pc == king_index[1]) {
                    continue;
                }

                if (dp.from[i] != null) {
                    // This piece needs to be removed
                    const index = make_index(dp.from[i].?, pc, orientedKingSquare, c);

                    // Update accumulator with weights
                    const offset = FT_HALF_DIM * index;
                    for (0..FT_HALF_DIM) |j| {
                        accumulator.accumulation[c_index][j] -= ft_ws[offset + j];
                    }
                }

                if (dp.to[i] != null) {
                    // This piece needs to be added
                    const index = make_index(dp.to[i].?, pc, orientedKingSquare, c);

                    // Update accumulator with weights
                    const offset = FT_HALF_DIM * index;
                    for (0..FT_HALF_DIM) |j| {
                        accumulator.accumulation[c_index][j] += ft_ws[offset + j];
                    }
                }
            }
        }
    }

    accumulator.computed_accumulation = true;
}

pub fn load_layer1(nnue_data: []u8) !void {
    var offset: usize = NN_START + 4;
    for (0..l1_biases.len) |i| {
        l1_biases[i] = read_bias(nnue_data, offset);
        offset += @sizeOf(i32);
    }

    // Transpose weights[input][output] => weights[output][input]
    const L1_INPUTS = L1_SIZE; // typically 16 * 2 = 32
    const L1_OUTPUTS = L1_DIM; // 16
    for (0..L1_OUTPUTS) |d| {
        for (0..L1_INPUTS) |s| {
            l1_weights[d * L1_INPUTS + s] = read_weight(nnue_data, offset);
            offset += @sizeOf(i8);
        }
    }
}

pub fn load_layer2(nnue_data: []u8) !void {
    var offset: usize = NN_START + 4 +
        L1_DIM * @sizeOf(i32) +
        L1_DIM * L1_SIZE * @sizeOf(i8);

    for (0..l2_biases.len) |i| {
        l2_biases[i] = read_bias(nnue_data, offset);
        offset += @sizeOf(i32);
    }

    const L2_INPUTS = L2_SIZE; // 16
    const L2_OUTPUTS = L2_DIM; // 16
    for (0..L2_OUTPUTS) |d| {
        for (0..L2_INPUTS) |s| {
            l2_weights[d * L2_INPUTS + s] = read_weight(nnue_data, offset);
            offset += @sizeOf(i8);
        }
    }
}

fn propagate(
    input: []u8,
    biases: []const i32,
    weights: []const i8,
) i32 {
    var sum: i32 = biases[0];
    comptime var i = 0;
    inline while (i < 16) : (i += 1) {
        sum += @as(i32, input[i]) * @as(i32, weights[i]);
    }
    return sum;
}

// fn transform(
//     curr_accu: Accumulator,
//     player: Color,
//     output: []u8,
// ) void {
//     std.debug.assert(output.len == FT_OUT_DIM);
//     const Vec = @Vector(16, i16);
//     const VecU8 = @Vector(16, u8);
//     const accumulation = &(curr_accu.accumulation);

//     var i: usize = 0;
//     while (i + 16 <= FT_HALF_DIM) : (i += 16) {
//         var sum_vec: Vec = accumulation[player.toU4()][i..][0..16].*;
//         var clamped_vec: Vec = @min(@max(sum_vec, @as(Vec, @splat(@as(i16, 0)))), @as(Vec, @splat(@as(i16, 127))));
//         output[i..][0..16].* = @as(VecU8, @intCast(clamped_vec));

//         sum_vec = accumulation[player.change_side().toU4()][i..][0..16].*;
//         clamped_vec = @min(@max(sum_vec, @as(Vec, @splat(@as(i16, 0)))), @as(Vec, @splat(@as(i16, 127))));
//         output[FT_HALF_DIM + i ..][0..16].* = @as(VecU8, @intCast(clamped_vec));
//     }
// }

fn transform(
    curr_accu: Accumulator,
    comptime player: Color,
    output: []u8,
) void {
    std.debug.assert(output.len == FT_OUT_DIM);

    const Vec = @Vector(16, i16);
    const VecU8 = @Vector(16, u8);

    const zero = @as(Vec, @splat(0));
    const max127 = @as(Vec, @splat(@as(i16, 127)));

    const accumulation = &curr_accu.accumulation;
    //const p_idx = player.toU4();
    const p_idx = if (player == Color.White) Color.White.toU4() else Color.Black.toU4();

    //const opp_idx = player.change_side().toU4();
    const opp_idx = if (player == Color.White) Color.Black.toU4() else Color.White.toU4();

    var i: usize = 0;
    //comptime var i = 0;
    while (i + 16 <= FT_HALF_DIM) : (i += 16) {
        const v1: Vec = accumulation[p_idx][i..][0..16].*;
        const v2: Vec = accumulation[opp_idx][i..][0..16].*;

        const c1 = @min(@max(v1, zero), max127);
        const c2 = @min(@max(v2, zero), max127);

        output[i..][0..16].* = @as(VecU8, @intCast(c1));
        output[FT_HALF_DIM + i ..][0..16].* = @as(VecU8, @intCast(c2));
    }
}

// fn transform(
//     curr_accu: Accumulator,
//     player: Color,
//     output: []u8,
// ) void {
//     std.debug.assert(output.len == FT_OUT_DIM);

//     const Vec = @Vector(16, i16);
//     const VecU8 = @Vector(16, u8);

//     const zero = @as(Vec, @splat(0));
//     const max127 = @as(Vec, @splat(@as(i16, 127)));

//     const accumulation = &curr_accu.accumulation;
//     const p_idx = player.toU4();
//     const o_idx = player.change_side().toU4();

//     // Hoist slices for cleaner indexing
//     const p = accumulation[p_idx][0..FT_HALF_DIM];
//     const o = accumulation[o_idx][0..FT_HALF_DIM];

//     // Reasonable prefetch distance: 64 elements (== 128 bytes for i16),
//     // i.e. ~2 cachelines on x86. Tune if you benchmark different CPUs.
//     const PF_DIST: usize = 64;

//     var i: usize = 0;
//     const step = 16 * 4; // processing 4 blocks per iteration
//     while (i < FT_HALF_DIM) : (i += step) {
//         // Optionally prefetch the upcoming blocks
//         if (i + PF_DIST + step < FT_HALF_DIM) {
//             @prefetch(&p[i + PF_DIST], .{ .rw = .read, .locality = 3, .cache = .data });
//             @prefetch(&o[i + PF_DIST], .{ .rw = .read, .locality = 3, .cache = .data });
//         }

//         // Block 0
//         {
//             const v_p: Vec = p[i..][0..16].*;
//             const v_o: Vec = o[i..][0..16].*;
//             const c_p: Vec = @min(@max(v_p, zero), max127);
//             const c_o: Vec = @min(@max(v_o, zero), max127);
//             const u8_p: VecU8 = @as(VecU8, @intCast(c_p));
//             const u8_o: VecU8 = @as(VecU8, @intCast(c_o));
//             output[i..][0..16].* = u8_p;
//             output[FT_HALF_DIM + i ..][0..16].* = u8_o;
//         }
//         // Block 1 (i + 16)
//         {
//             const base = i + 16;
//             const v_p: Vec = p[base..][0..16].*;
//             const v_o: Vec = o[base..][0..16].*;
//             const c_p: Vec = @min(@max(v_p, zero), max127);
//             const c_o: Vec = @min(@max(v_o, zero), max127);
//             const u8_p: VecU8 = @as(VecU8, @intCast(c_p));
//             const u8_o: VecU8 = @as(VecU8, @intCast(c_o));
//             output[base..][0..16].* = u8_p;
//             output[FT_HALF_DIM + base ..][0..16].* = u8_o;
//         }
//         // Block 2 (i + 32)
//         {
//             const base = i + 32;
//             const v_p: Vec = p[base..][0..16].*;
//             const v_o: Vec = o[base..][0..16].*;
//             const c_p: Vec = @min(@max(v_p, zero), max127);
//             const c_o: Vec = @min(@max(v_o, zero), max127);
//             const u8_p: VecU8 = @as(VecU8, @intCast(c_p));
//             const u8_o: VecU8 = @as(VecU8, @intCast(c_o));
//             output[base..][0..16].* = u8_p;
//             output[FT_HALF_DIM + base ..][0..16].* = u8_o;
//         }
//         // Block 3 (i + 48)
//         {
//             const base = i + 48;
//             const v_p: Vec = p[base..][0..16].*;
//             const v_o: Vec = o[base..][0..16].*;
//             const c_p: Vec = @min(@max(v_p, zero), max127);
//             const c_o: Vec = @min(@max(v_o, zero), max127);
//             const u8_p: VecU8 = @as(VecU8, @intCast(c_p));
//             const u8_o: VecU8 = @as(VecU8, @intCast(c_o));
//             output[base..][0..16].* = u8_p;
//             output[FT_HALF_DIM + base ..][0..16].* = u8_o;
//         }
//     }
// }

inline fn affine(
    input: []const u8,
    output: []u8,
    biases: []const i32,
    weights: []const i8,
    input_len: usize,
    output_len: usize,
) void {
    std.debug.assert(output.len == output_len);
    std.debug.assert(weights.len == output_len * input_len);

    comptime var out_idx = 0;
    inline while (out_idx < output_len) : (out_idx += 1) {
        var sum = biases[out_idx];
        var vec_sum: @Vector(16, i32) = @splat(@as(i32, 0));
        var i: usize = 0;
        while (i + 16 <= input_len) : (i += 16) {
            const w_base = out_idx * input_len + i;
            const w_vec: @Vector(16, i32) = @as(@Vector(16, i32), weights[w_base..][0..16].*);
            const x_vec: @Vector(16, i32) = input[i..][0..16].*;
            vec_sum += x_vec * w_vec;
        }
        sum += @reduce(.Add, vec_sum);
        sum = std.math.clamp(sum >> 6, 0, 127);
        output[out_idx] = @intCast(sum);
    }
}

// inline fn affine(
//     input: []const u8,
//     output: []u8,
//     biases: []const i32,
//     weights: []const i8,
//     input_len: usize,
//     output_len: usize,
// ) void {
//     std.debug.assert(output.len == output_len);
//     std.debug.assert(weights.len == output_len * input_len);

//     const VecI16 = @Vector(16, i16);
//     const VecI32 = @Vector(16, i32);

//     comptime var out_idx = 0;
//     inline while (out_idx < output_len) : (out_idx += 1) {
//         var sum: VecI32 = @splat(0);

//         var i: usize = 0;
//         while (i < input_len) : (i += 16) {
//             const w_base = out_idx * input_len + i;

//             // Load 16 weights (i8 → i16)
//             const w_i16: VecI16 = @as(VecI16, weights[w_base..][0..16].*);

//             // Load 16 inputs (u8 → i16)
//             const x_i16: VecI16 = @as(VecI16, input[i..][0..16].*);

//             // Multiply-add: widen both to i32, then accumulate
//             sum += @as(VecI32, x_i16) * @as(VecI32, w_i16);
//         }

//         // Horizontal sum of 16 lanes
//         var total: i32 = biases[out_idx] + @reduce(.Add, sum);

//         // Quantize
//         total = std.math.clamp(total >> 6, 0, 127);
//         output[out_idx] = @intCast(total);
//     }
// }

// inline fn affine(
//     input: []const u8,
//     output: []u8,
//     biases: []const i32,
//     weights: []const i8,
//     input_len: usize,
//     output_len: usize,
// ) void {
//     std.debug.assert(output.len == output_len);
//     std.debug.assert(weights.len == output_len * input_len);
//     std.debug.assert(input_len % 16 == 0);

//     const VecI16 = @Vector(16, i16);
//     const VecI32 = @Vector(16, i32);

//     var out_idx: usize = 0;
//     while (out_idx < output_len) : (out_idx += 1) {
//         // SIMD accumulator (16 lanes -> i32)
//         var sum_vec: VecI32 = @splat(@as(i32, 0));

//         var i: usize = 0;
//         while (i < input_len) : (i += 16) {
//             const w_base = out_idx * input_len + i;
//             const x_i16: VecI16 = @as(VecI16, input[i..][0..16].*);
//             const w_i16: VecI16 = @as(VecI16, weights[w_base..][0..16].*);
//             sum_vec += @as(VecI32, x_i16) * @as(VecI32, w_i16);
//         }

//         var total: i32 = biases[out_idx] + @reduce(.Add, sum_vec);

//         total = std.math.clamp(total >> 6, 0, 127);
//         output[out_idx] = @intCast(total);
//     }
// }

pub fn evaluate(curr_accu: Accumulator, comptime player: Color) i32 {
    const FV_SCALE = 16;

    var input: [FT_OUT_DIM]u8 = undefined;
    var l1_out: [L2]u8 = undefined;
    var l2_out: [L2]u8 = undefined;

    transform(curr_accu, player, &input);
    affine(&input, &l1_out, &l1_biases, &l1_weights, FT_OUT_DIM, L1_DIM);
    affine(&l1_out, &l2_out, &l2_biases, &l2_weights, L1_DIM, L2_DIM);

    const out_value = propagate(&l2_out, &out_biases, &out_weights);
    const ret = @divTrunc(out_value, FV_SCALE);
    return @as(i32, @intCast(ret));
}
