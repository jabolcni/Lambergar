const std = @import("std");
const builtin = @import("builtin");
const compat_timer = @import("timer.zig");
const compat = @import("compat.zig");

const position = @import("position.zig");
const bb = @import("bitboard.zig");

const Position = position.Position;
const Move = position.Move;
const MoveFlags = position.MoveFlags;
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
const enable_debug_stats = builtin.mode == .Debug;

pub const DebugStats = struct {
    incremental_calls: u64 = 0,
    already_computed: u64 = 0,
    full_refresh_gameply0: u64 = 0,
    full_refresh_prev_invalid: u64 = 0,
    null_move_copies: u64 = 0,
    king_refreshes: [2]u64 = @splat(0),
    king_refresh_quiet: u64 = 0,
    king_refresh_capture: u64 = 0,
    king_refresh_castle: u64 = 0,
    king_refresh_other: u64 = 0,
    king_refresh_in_main_search: u64 = 0,
    king_refresh_in_qsearch: u64 = 0,
    king_refresh_outside_search: u64 = 0,
    king_refresh_depth_le_1: u64 = 0,
    king_refresh_depth_2_3: u64 = 0,
    king_refresh_depth_4_6: u64 = 0,
    king_refresh_depth_ge_7: u64 = 0,
    king_refresh_move_index_0: u64 = 0,
    king_refresh_move_index_1_3: u64 = 0,
    king_refresh_move_index_4_7: u64 = 0,
    king_refresh_move_index_ge_8: u64 = 0,
    king_refresh_in_pv: u64 = 0,
    king_refresh_in_nonpv: u64 = 0,
    incremental_side_updates: [2]u64 = @splat(0),
};

pub var debug_stats = DebugStats{};

pub fn reset_debug_stats() void {
    if (!enable_debug_stats) return;
    debug_stats = .{};
}

pub fn get_debug_stats() DebugStats {
    if (!enable_debug_stats) return .{};
    return debug_stats;
}

pub fn print_debug_stats(writer: anytype) !void {
    const stats = get_debug_stats();
    try writer.print("NNUE stats:\n", .{});
    try writer.print("  incremental_calls: {d}\n", .{stats.incremental_calls});
    try writer.print("  already_computed: {d}\n", .{stats.already_computed});
    try writer.print("  full_refresh_gameply0: {d}\n", .{stats.full_refresh_gameply0});
    try writer.print("  full_refresh_prev_invalid: {d}\n", .{stats.full_refresh_prev_invalid});
    try writer.print("  null_move_copies: {d}\n", .{stats.null_move_copies});
    try writer.print("  king_refreshes white/black: {d}/{d}\n", .{ stats.king_refreshes[Color.White.toU4()], stats.king_refreshes[Color.Black.toU4()] });
    try writer.print("  king_refresh_causes quiet/capture/castle/other: {d}/{d}/{d}/{d}\n", .{
        stats.king_refresh_quiet,
        stats.king_refresh_capture,
        stats.king_refresh_castle,
        stats.king_refresh_other,
    });
    try writer.print("  king_refresh_context main/qsearch/outside: {d}/{d}/{d}\n", .{
        stats.king_refresh_in_main_search,
        stats.king_refresh_in_qsearch,
        stats.king_refresh_outside_search,
    });
    try writer.print("  king_refresh_depth <=1/2-3/4-6/7+: {d}/{d}/{d}/{d}\n", .{
        stats.king_refresh_depth_le_1,
        stats.king_refresh_depth_2_3,
        stats.king_refresh_depth_4_6,
        stats.king_refresh_depth_ge_7,
    });
    try writer.print("  king_refresh_move_index 0/1-3/4-7/8+: {d}/{d}/{d}/{d}\n", .{
        stats.king_refresh_move_index_0,
        stats.king_refresh_move_index_1_3,
        stats.king_refresh_move_index_4_7,
        stats.king_refresh_move_index_ge_8,
    });
    try writer.print("  king_refresh_pv pv/nonpv: {d}/{d}\n", .{
        stats.king_refresh_in_pv,
        stats.king_refresh_in_nonpv,
    });
    try writer.print("  incremental_side_updates white/black: {d}/{d}\n", .{ stats.incremental_side_updates[Color.White.toU4()], stats.incremental_side_updates[Color.Black.toU4()] });
}

pub const SearchContext = enum {
    outside,
    main_search,
    qsearch,
};

threadlocal var current_search_context: SearchContext = .outside;
threadlocal var current_search_depth: i8 = -128;
threadlocal var current_move_index: usize = 0;
threadlocal var current_pv_node: bool = false;

pub inline fn set_search_context(context: SearchContext) SearchContext {
    if (!enable_debug_stats) return context;
    const prev = current_search_context;
    current_search_context = context;
    return prev;
}

pub inline fn set_search_depth(depth: i8) i8 {
    if (!enable_debug_stats) return depth;
    const prev = current_search_depth;
    current_search_depth = depth;
    return prev;
}

pub inline fn set_move_index(move_index: usize) usize {
    if (!enable_debug_stats) return move_index;
    const prev = current_move_index;
    current_move_index = move_index;
    return prev;
}

pub inline fn set_pv_node(is_pv: bool) bool {
    if (!enable_debug_stats) return is_pv;
    const prev = current_pv_node;
    current_pv_node = is_pv;
    return prev;
}

inline fn record_king_refresh_cause(last_move: Move) void {
    if (!enable_debug_stats) return;
    switch (last_move.flags) {
        .QUIET, .DOUBLE_PUSH => debug_stats.king_refresh_quiet += 1,
        .CAPTURE, .EN_PASSANT, .PC_KNIGHT, .PC_BISHOP, .PC_ROOK, .PC_QUEEN => debug_stats.king_refresh_capture += 1,
        .OO, .OOO => debug_stats.king_refresh_castle += 1,
        else => debug_stats.king_refresh_other += 1,
    }

    switch (current_search_context) {
        .main_search => debug_stats.king_refresh_in_main_search += 1,
        .qsearch => debug_stats.king_refresh_in_qsearch += 1,
        .outside => debug_stats.king_refresh_outside_search += 1,
    }

    if (current_search_depth <= 1) {
        debug_stats.king_refresh_depth_le_1 += 1;
    } else if (current_search_depth <= 3) {
        debug_stats.king_refresh_depth_2_3 += 1;
    } else if (current_search_depth <= 6) {
        debug_stats.king_refresh_depth_4_6 += 1;
    } else {
        debug_stats.king_refresh_depth_ge_7 += 1;
    }

    if (current_move_index == 0) {
        debug_stats.king_refresh_move_index_0 += 1;
    } else if (current_move_index <= 3) {
        debug_stats.king_refresh_move_index_1_3 += 1;
    } else if (current_move_index <= 7) {
        debug_stats.king_refresh_move_index_4_7 += 1;
    } else {
        debug_stats.king_refresh_move_index_ge_8 += 1;
    }

    if (current_pv_node) {
        debug_stats.king_refresh_in_pv += 1;
    } else {
        debug_stats.king_refresh_in_nonpv += 1;
    }
}

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

const OrientedSquare: [2][64]u6 = blk: {
    var table: [2][64]u6 = undefined;
    for (0..64) |sq| {
        table[Color.White.toU4()][sq] = @as(u6, @intCast(sq));
        table[Color.Black.toU4()][sq] = @as(u6, @intCast(sq ^ 0x3F));
    }
    break :blk table;
};

const KingBucketBase: [64]usize = blk: {
    var table: [64]usize = undefined;
    for (0..64) |sq| {
        table[sq] = @intFromEnum(PS.END) * sq;
    }
    break :blk table;
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
    const file = try compat.cwdOpenReadonlyFile(nnue_file_name);
    defer compat.closeFile(file);

    std.debug.print("NNUE file loaded: {s}\n", .{nnue_file_name});

    const NNUE_FILESIZE: usize = 10_507_097;
    const nnue_data = try allocator.alloc(u8, NNUE_FILESIZE);
    defer allocator.free(nnue_data);
    _ = try compat.fileReadAll(file, nnue_data);

    try std.testing.expectEqual(NNUE_FILESIZE, nnue_data.len);

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
    const file = try compat.cwdOpenReadonlyFile(NNUE_FILE);
    defer compat.closeFile(file);

    std.debug.print("NNUE file loaded: {s}\n", .{NNUE_FILE});
    const NNUE_FILESIZE: usize = 10_507_097; //10_507_097; //21_024_768;
    const nnue_data = try allocator.alloc(u8, NNUE_FILESIZE);
    defer allocator.free(nnue_data);
    _ = try compat.fileReadAll(file, nnue_data);

    try std.testing.expectEqual(NNUE_FILESIZE, nnue_data.len);

    try verify_integrity(nnue_data);
    try load_feature_layer(nnue_data);
    try load_layer1(nnue_data);
    try load_layer2(nnue_data);
    try load_output_layer(nnue_data);
}

fn orient(sq: u6, c: Color) u6 {
    return if (c == Color.White) sq else sq ^ 0x3F;
}

inline fn make_index_from_bases(oriented_sq: u6, piece_base: usize, king_base: usize) usize {
    return king_base + piece_base + @as(usize, oriented_sq);
}

fn make_index(sq: u6, pc: u4, ksq: u6, color: Color) usize {
    const ret = orient(sq, color) +
        PieceToIndex[color.toU4()][@as(usize, @intCast(pc))] +
        @intFromEnum(PS.END) * @as(usize, @intCast(ksq));
    return @as(usize, @intCast(ret));
}

// pub fn refresh_accumulator_side(pos: Position, accumulator: *Accumulator, comptime c: Color) void {
//     var bitboard = pos.piece_bb[position.Piece.make_piece(c, PieceType.King).toU4()];
//     const kingSquare = bb.pop_lsb(&bitboard);
//     const orientedKingSquare = orient(kingSquare, c);

//     std.mem.copyForwards(i16, accumulator.accumulation[c.toU4()][0..], &ft_bs);

//     // Iterate over all pieces of the given color
//     for (Piece.WHITE_PAWN.toU4()..Piece.BLACK_KING.toU4()) |pc| {
//         //if (pc >= Piece.WHITE_KING.toU4() and pc < Piece.BLACK_PAWN.toU4()) continue;
//         if (pc == Piece.WHITE_KING.toU4()) continue;

//         bitboard = pos.piece_bb[pc];
//         const ppc = @as(u4, @intCast(pc));

//         while (bitboard != 0) {
//             const square = bb.pop_lsb(&bitboard);

//             // Compute index for the piece
//             const index = make_index(square, ppc, orientedKingSquare, c);

//             // Update accumulator with weights
//             const offset = FT_HALF_DIM * index;

//             // for (0..FT_HALF_DIM) |j| {
//             //     accumulator.accumulation[c.toU4()][j] += ft_ws[offset + j];
//             // }
//             var j: usize = 0;
//             while (j + 16 <= FT_HALF_DIM) : (j += 16) {
//                 const acc_slice = accumulator.accumulation[c.toU4()][j..][0..16];
//                 const ws_slice = ft_ws[offset + j ..][0..16];
//                 const acc_vec: @Vector(16, i16) = acc_slice.*;
//                 const ws_vec: @Vector(16, i16) = ws_slice.*;
//                 (accumulator.accumulation[c.toU4()][j..][0..16]).* = acc_vec + ws_vec;
//             }
//         }
//     }
// }

pub fn refresh_accumulator_side(pos: *const Position, accumulator: *Accumulator, comptime c: Color) void {
    const c_index = c.toU4();
    var bitboard = pos.piece_bb[position.Piece.make_piece(c, PieceType.King).toU4()];
    const kingSquare = bb.pop_lsb(&bitboard);
    const orientedKingSquare = OrientedSquare[c_index][kingSquare];
    const king_base = KingBucketBase[orientedKingSquare];
    const Vec16I16 = @Vector(16, i16);
    var i: usize = 0;
    while (i < FT_HALF_DIM) : (i += 16) {
        const bias_vec: Vec16I16 = ft_bs[i..][0..16].*;
        accumulator.accumulation[c_index][i..][0..16].* = bias_vec;
    }

    // Process pieces in batches where possible
    for (Piece.WHITE_PAWN.toU4()..Piece.BLACK_KING.toU4()) |pc| {
        if (pc == Piece.WHITE_KING.toU4()) continue;

        bitboard = pos.piece_bb[pc];
        const piece_base = PieceToIndex[c_index][pc];

        while (bitboard != 0) {
            const square = bb.pop_lsb(&bitboard);
            const index = make_index_from_bases(OrientedSquare[c_index][square], piece_base, king_base);
            const offset = FT_HALF_DIM * index;

            i = 0;
            while (i < FT_HALF_DIM) : (i += 16) {
                const acc_vec: Vec16I16 = accumulator.accumulation[c_index][i..][0..16].*;
                const ws_vec: Vec16I16 = ft_ws[offset + i ..][0..16].*;
                accumulator.accumulation[c_index][i..][0..16].* = acc_vec + ws_vec;
            }
        }
    }
}

pub fn refresh_accumulator(pos: *const Position) Accumulator {
    var accumulator = Accumulator{
        .computed_accumulation = false,
        .computed_score = false,
    };

    refresh_accumulator_side(pos, &accumulator, Color.White);
    refresh_accumulator_side(pos, &accumulator, Color.Black);

    accumulator.computed_accumulation = true;

    return accumulator;
}

inline fn apply_feature_delta(
    accumulation: *[L1]i16,
    piece_base: usize,
    from: ?u6,
    to: ?u6,
    king_base: usize,
    comptime c_index: usize,
) void {
    const Vec16I16 = @Vector(16, i16);
    if (piece_base == 0) return;

    if (from) |sq| {
        const index = make_index_from_bases(OrientedSquare[c_index][sq], piece_base, king_base);
        const offset = FT_HALF_DIM * index;
        var j: usize = 0;
        while (j < FT_HALF_DIM) : (j += 16) {
            const acc_vec: Vec16I16 = accumulation[j..][0..16].*;
            const ws_vec: Vec16I16 = ft_ws[offset + j ..][0..16].*;
            accumulation[j..][0..16].* = acc_vec - ws_vec;
        }
    }

    if (to) |sq| {
        const index = make_index_from_bases(OrientedSquare[c_index][sq], piece_base, king_base);
        const offset = FT_HALF_DIM * index;
        var j: usize = 0;
        while (j < FT_HALF_DIM) : (j += 16) {
            const acc_vec: Vec16I16 = accumulation[j..][0..16].*;
            const ws_vec: Vec16I16 = ft_ws[offset + j ..][0..16].*;
            accumulation[j..][0..16].* = acc_vec + ws_vec;
        }
    }
}

inline fn incremental_update_side(
    pos: *Position,
    accumulator: *Accumulator,
    prev_accu: *const Accumulator,
    dp: *const DeltaPieces,
    comptime c: Color,
) void {
    const c_index = c.toU4();
    const king_index = if (c == .White) Piece.WHITE_KING.toU4() else Piece.BLACK_KING.toU4();

    inline for (0..3) |i| {
        if (i < dp.count and dp.pieces[i] == king_index) {
            if (enable_debug_stats) debug_stats.king_refreshes[c_index] += 1;
            record_king_refresh_cause(pos.history[pos.game_ply].move);
            refresh_accumulator_side(pos, accumulator, c);
            return;
        }
    }

    if (enable_debug_stats) debug_stats.incremental_side_updates[c_index] += 1;
    std.mem.copyForwards(i16, accumulator.accumulation[c_index][0..], prev_accu.accumulation[c_index][0..]);
    var bitboard = pos.piece_bb[position.Piece.make_piece(c, PieceType.King).toU4()];
    const kingSquare = bb.pop_lsb(&bitboard);
    const orientedKingSquare = OrientedSquare[c_index][kingSquare];
    const king_base = KingBucketBase[orientedKingSquare];
    const accumulation = &accumulator.accumulation[c_index];

    switch (dp.count) {
        1 => {
            apply_feature_delta(accumulation, PieceToIndex[c_index][dp.pieces[0]], dp.from[0], dp.to[0], king_base, c_index);
        },
        2 => {
            apply_feature_delta(accumulation, PieceToIndex[c_index][dp.pieces[0]], dp.from[0], dp.to[0], king_base, c_index);
            apply_feature_delta(accumulation, PieceToIndex[c_index][dp.pieces[1]], dp.from[1], dp.to[1], king_base, c_index);
        },
        3 => {
            apply_feature_delta(accumulation, PieceToIndex[c_index][dp.pieces[0]], dp.from[0], dp.to[0], king_base, c_index);
            apply_feature_delta(accumulation, PieceToIndex[c_index][dp.pieces[1]], dp.from[1], dp.to[1], king_base, c_index);
            apply_feature_delta(accumulation, PieceToIndex[c_index][dp.pieces[2]], dp.from[2], dp.to[2], king_base, c_index);
        },
        else => unreachable,
    }
}

pub fn incremental_update(pos: *Position) void {
    const accumulator: *Accumulator = &pos.history[pos.game_ply].accumulator;
    if (enable_debug_stats) debug_stats.incremental_calls += 1;
    if (accumulator.computed_accumulation == true) {
        if (enable_debug_stats) debug_stats.already_computed += 1;
        return;
    }

    if (pos.game_ply == 0) {
        // No history available, perform full refresh
        if (enable_debug_stats) debug_stats.full_refresh_gameply0 += 1;
        accumulator.* = refresh_accumulator(pos);
        return;
    }

    const prev_accu = &pos.history[pos.game_ply - 1].accumulator;
    if (!prev_accu.computed_accumulation) {
        // Previous accumulator invalid, fallback to full refresh
        if (enable_debug_stats) debug_stats.full_refresh_prev_invalid += 1;
        accumulator.* = refresh_accumulator(pos);
        return;
    }

    const dp: *DeltaPieces = &pos.delta;
    if (dp.count == 0) { // we have null move, so we can just copy the accumulator
        if (enable_debug_stats) debug_stats.null_move_copies += 1;
        std.mem.copyForwards(i16, accumulator.accumulation[0][0..], prev_accu.accumulation[0][0..]);
        std.mem.copyForwards(i16, accumulator.accumulation[1][0..], prev_accu.accumulation[1][0..]);
        accumulator.computed_accumulation = true;
        return;
    }

    incremental_update_side(pos, accumulator, prev_accu, dp, .White);
    incremental_update_side(pos, accumulator, prev_accu, dp, .Black);

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

fn transform(
    curr_accu: Accumulator,
    comptime player: Color,
    output: []u8,
) void {
    //std.debug.assert(output.len == FT_OUT_DIM);

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

inline fn affine(
    input: []const u8,
    output: []u8,
    biases: []const i32,
    weights: []const i8,
    comptime input_len: usize,
    comptime output_len: usize,
) void {
    if (comptime input_len >= 32 and input_len % 32 == 0) {
        // Fast path: VPMADDUBSW + VPMADDWD, processes 32 elements per iteration.
        // VPMADDUBSW: 32 (u8 × i8) pairs → 16 i16, adds adjacent products.
        //   No saturation: max pair sum = 127×127 + 127×127 = 32 258 < 32 767.
        // VPMADDWD × kOnes: 16 i16 → 8 i32, sums adjacent pairs.
        // Avoids explicit widening to i32 and uses ~3 instructions per 32 elements
        // instead of the ~12 that the scalar-extend + VPMULLD path would need.
        const kOnes: @Vector(16, i16) = @splat(1);
        comptime var out_idx: usize = 0;
        inline while (out_idx < output_len) : (out_idx += 1) {
            var sum = biases[out_idx];
            var vec_sum: @Vector(8, i32) = @splat(0);
            const w_base = comptime out_idx * input_len;
            var i: usize = 0;
            while (i + 32 <= input_len) : (i += 32) {
                const x_chunk: @Vector(32, u8) = input[i..][0..32].*;
                const w_chunk: @Vector(32, i8) = weights[w_base + i ..][0..32].*;
                const maddubs: @Vector(16, i16) = asm volatile (
                    "vpmaddubsw %[w], %[x], %[r]"
                    : [r] "=x" (-> @Vector(16, i16))
                    : [x] "x" (x_chunk), [w] "x" (w_chunk)
                );
                vec_sum += asm volatile (
                    "vpmaddwd %[ones], %[a], %[r]"
                    : [r] "=x" (-> @Vector(8, i32))
                    : [a] "x" (maddubs), [ones] "x" (kOnes)
                );
            }
            sum += @reduce(.Add, vec_sum);
            sum = std.math.clamp(sum >> 6, 0, 127);
            output[out_idx] = @intCast(sum);
        }
    } else {
        // Fallback for inputs not divisible by 32 (e.g. affine_l2 with 16 inputs).
        comptime var out_idx: usize = 0;
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
}

// pub fn evaluate(curr_accu: Accumulator, comptime player: Color) i32 {
//     const FV_SCALE = 16;

//     var input: [FT_OUT_DIM]u8 = undefined;
//     var l1_out: [L2]u8 = undefined;
//     var l2_out: [L2]u8 = undefined;

//     transform(curr_accu, player, &input);
//     affine(&input, &l1_out, &l1_biases, &l1_weights, FT_OUT_DIM, L1_DIM);
//     affine(&l1_out, &l2_out, &l2_biases, &l2_weights, L1_DIM, L2_DIM);

//     const out_value = propagate(&l2_out, &out_biases, &out_weights);
//     const ret = @divTrunc(out_value, FV_SCALE);
//     return @as(i32, @intCast(ret));
// }

pub fn evaluate(curr_accu: Accumulator, comptime player: Color) i32 {
    const FV_SCALE = 16;
    //const QA = 127;

    var input: [FT_OUT_DIM]u8 align(32) = undefined;
    var l1_out: [L2]u8 align(32) = undefined;
    var l2_out: [L2]u8 align(32) = undefined;

    transform(curr_accu, player, &input);
    affine(&input, &l1_out, &l1_biases, &l1_weights, FT_OUT_DIM, L1_DIM);
    affine(&l1_out, &l2_out, &l2_biases, &l2_weights, L2_SIZE, L2_DIM);

    var sum: i32 = out_biases[0];
    var i: usize = 0;
    while (i < OUT_SIZE) : (i += 1) {
        sum += @as(i32, l2_out[i]) * @as(i32, out_weights[i]);
    }

    return @divTrunc(sum, FV_SCALE);
}

fn print_microbench_result(writer: anytype, name: []const u8, total_ops: usize, nanos: u64, checksum: i64) !void {
    const ns_per_op = @as(f64, @floatFromInt(nanos)) / @as(f64, @floatFromInt(total_ops));
    const ops_per_sec = (@as(f64, @floatFromInt(total_ops)) * 1_000_000_000.0) / @as(f64, @floatFromInt(nanos));
    try writer.print("{s}: {d} ops, {d} ns total, {d:.2} ns/op, {d:.2} ops/s, checksum {d}\n", .{
        name,
        total_ops,
        nanos,
        ns_per_op,
        ops_per_sec,
        checksum,
    });
}

const MicrobenchPhase = enum {
    opening,
    middlegame,
    endgame,
};

fn phase_name(phase: MicrobenchPhase) []const u8 {
    return switch (phase) {
        .opening => "opening",
        .middlegame => "middlegame",
        .endgame => "endgame",
    };
}

pub fn microbench(allocator: std.mem.Allocator, iterations: usize, writer: anytype) !void {
    const fens = [_][]const u8{
        "r3k2r/pp1n1ppp/2pbpn2/q2p4/3P4/2N1PN2/PPQ1BPPP/R1B2RK1 w kq - 0 10",
        "2r2rk1/1p1bq3/p3p2p/3pPpp1/1P1Q4/P7/2P2PPP/2R1RBK1 b - - 0 1",
        "rnbq2k1/p1r2p1p/1p1p1Pp1/1BpPn1N1/P7/2P5/6PP/R1B1QRK1 w - - 0 1",
        "4r1k1/3b1p2/5qp1/1BPpn2p/7n/r3P1N1/2Q1RPPP/1R3NK1 b - - 0 1",
        "8/pp2r1k1/2p1p3/3pP2p/1P1P1P1P/P5KR/8/8 w - - 0 1",
        "5k2/7R/4P2p/5K2/p1r2P1p/8/8/8 b - - 0 1",
        "r2qrnk1/pp3ppb/3b1n1p/1Pp1p3/2P1P2N/P5P1/1B1NQPBP/R4RK1 w - - 0 1",
        "2rr2k1/1b3ppp/pb2p3/1p2P3/1P2BPnq/P1N3P1/1B2Q2P/R4R1K b - - 0 1",
    };
    const phases = [_]MicrobenchPhase{
        .opening,
        .middlegame,
        .middlegame,
        .middlegame,
        .endgame,
        .endgame,
        .opening,
        .middlegame,
    };

    const positions = try allocator.alloc(Position, fens.len);
    defer allocator.free(positions);
    const accumulators = try allocator.alloc(Accumulator, fens.len);
    defer allocator.free(accumulators);
    const transformed = try allocator.alignedAlloc([FT_OUT_DIM]u8, .fromByteUnits(32), fens.len);
    defer allocator.free(transformed);
    const l1_bufs = try allocator.alignedAlloc([L1_DIM]u8, .fromByteUnits(32), fens.len);
    defer allocator.free(l1_bufs);
    var opening_idx: [fens.len]usize = undefined;
    var middlegame_idx: [fens.len]usize = undefined;
    var endgame_idx: [fens.len]usize = undefined;
    var opening_count: usize = 0;
    var middlegame_count: usize = 0;
    var endgame_count: usize = 0;

    for (fens, 0..) |fen, idx| {
        positions[idx] = Position.new();
        try positions[idx].set(fen);
        accumulators[idx] = refresh_accumulator(&positions[idx]);

        if (positions[idx].side_to_play == .White) {
            transform(accumulators[idx], .White, &transformed[idx]);
        } else {
            transform(accumulators[idx], .Black, &transformed[idx]);
        }

            affine(&transformed[idx], &l1_bufs[idx], &l1_biases, &l1_weights, FT_OUT_DIM, L1_DIM);

        switch (phases[idx]) {
            .opening => {
                opening_idx[opening_count] = idx;
                opening_count += 1;
            },
            .middlegame => {
                middlegame_idx[middlegame_count] = idx;
                middlegame_count += 1;
            },
            .endgame => {
                endgame_idx[endgame_count] = idx;
                endgame_count += 1;
            },
        }
    }

    try writer.print("NNUE microbench: {d} positions x {d} iterations\n", .{ fens.len, iterations });

    const total_ops: usize = iterations * fens.len;

    var checksum: i64 = 0;
    var timer = try compat_timer.Timer.start();
    for (0..iterations) |_| {
        for (positions) |pos| {
            const acc = refresh_accumulator(&pos);
            checksum += acc.accumulation[0][0] + acc.accumulation[1][0];
            std.mem.doNotOptimizeAway(acc);
        }
    }
    try print_microbench_result(writer, "refresh_accumulator", total_ops, timer.read(), checksum);

    const phase_runs = [_]struct {
        phase: MicrobenchPhase,
        idxs: []const usize,
    }{
        .{ .phase = .opening, .idxs = opening_idx[0..opening_count] },
        .{ .phase = .middlegame, .idxs = middlegame_idx[0..middlegame_count] },
        .{ .phase = .endgame, .idxs = endgame_idx[0..endgame_count] },
    };

    for (phase_runs) |phase_run| {
        checksum = 0;
        var phase_timer = try compat_timer.Timer.start();
        for (0..iterations) |_| {
            for (phase_run.idxs) |idx| {
                const acc = refresh_accumulator(&positions[idx]);
                checksum += acc.accumulation[0][0] + acc.accumulation[1][0];
                std.mem.doNotOptimizeAway(acc);
            }
        }
        var buf: [64]u8 = undefined;
        const label = try std.fmt.bufPrint(&buf, "refresh_accumulator_{s}", .{phase_name(phase_run.phase)});
        try print_microbench_result(writer, label, iterations * phase_run.idxs.len, phase_timer.read(), checksum);
    }

    checksum = 0;
    timer = try compat_timer.Timer.start();
    for (0..iterations) |_| {
        for (positions, 0..) |pos, idx| {
            var out: [FT_OUT_DIM]u8 align(32) = undefined;
            if (pos.side_to_play == .White) {
                transform(accumulators[idx], .White, &out);
            } else {
                transform(accumulators[idx], .Black, &out);
            }
            checksum += out[(idx * 17) % FT_OUT_DIM];
            std.mem.doNotOptimizeAway(out);
        }
    }
    try print_microbench_result(writer, "transform", total_ops, timer.read(), checksum);

    checksum = 0;
    timer = try compat_timer.Timer.start();
    for (0..iterations) |_| {
        for (transformed) |input| {
            var out: [L1_DIM]u8 align(32) = undefined;
            affine(&input, &out, &l1_biases, &l1_weights, FT_OUT_DIM, L1_DIM);
            checksum += out[3] + out[11];
            std.mem.doNotOptimizeAway(out);
        }
    }
    try print_microbench_result(writer, "affine_l1", total_ops, timer.read(), checksum);

    checksum = 0;
    timer = try compat_timer.Timer.start();
    for (0..iterations) |_| {
        for (l1_bufs) |input| {
            var out: [L2_DIM]u8 align(32) = undefined;
            affine(&input, &out, &l2_biases, &l2_weights, L2_SIZE, L2_DIM);
            checksum += out[5] + out[13];
            std.mem.doNotOptimizeAway(out);
        }
    }
    try print_microbench_result(writer, "affine_l2", total_ops, timer.read(), checksum);

    checksum = 0;
    timer = try compat_timer.Timer.start();
    for (0..iterations) |_| {
        for (positions, 0..) |pos, idx| {
            const score = if (pos.side_to_play == .White)
                evaluate(accumulators[idx], .White)
            else
                evaluate(accumulators[idx], .Black);
            checksum += score;
            std.mem.doNotOptimizeAway(score);
        }
    }
    try print_microbench_result(writer, "evaluate", total_ops, timer.read(), checksum);
}
