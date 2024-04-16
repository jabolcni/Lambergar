const std = @import("std");
const position = @import("position.zig");
const Square = position.Square;

//Precomputed file masks
pub const MASK_FILE = [_]u64{
    0x101010101010101,  0x202020202020202,  0x404040404040404,  0x808080808080808,
    0x1010101010101010, 0x2020202020202020, 0x4040404040404040, 0x8080808080808080,
};

//Precomputed rank masks
pub const MASK_RANK = [_]u64{
    0xff,         0xff00,         0xff0000,         0xff000000,
    0xff00000000, 0xff0000000000, 0xff000000000000, 0xff00000000000000,
};

//Precomputed diagonal masks
pub const MASK_DIAGONAL = [_]u64{
    0x80,               0x8040,             0x804020,
    0x80402010,         0x8040201008,       0x804020100804,
    0x80402010080402,   0x8040201008040201, 0x4020100804020100,
    0x2010080402010000, 0x1008040201000000, 0x804020100000000,
    0x402010000000000,  0x201000000000000,  0x100000000000000,
};

//Precomputed anti-diagonal masks
pub const MASK_ANTI_DIAGONAL = [_]u64{
    0x1,                0x102,              0x10204,
    0x1020408,          0x102040810,        0x10204081020,
    0x1020408102040,    0x102040810204080,  0x204081020408000,
    0x408102040800000,  0x810204080000000,  0x1020408000000000,
    0x2040800000000000, 0x4080000000000000, 0x8000000000000000,
};

//Precomputed square masks
pub const SQUARE_BB = [_]u64{
    0x1,                0x2,                0x4,                0x8,
    0x10,               0x20,               0x40,               0x80,
    0x100,              0x200,              0x400,              0x800,
    0x1000,             0x2000,             0x4000,             0x8000,
    0x10000,            0x20000,            0x40000,            0x80000,
    0x100000,           0x200000,           0x400000,           0x800000,
    0x1000000,          0x2000000,          0x4000000,          0x8000000,
    0x10000000,         0x20000000,         0x40000000,         0x80000000,
    0x100000000,        0x200000000,        0x400000000,        0x800000000,
    0x1000000000,       0x2000000000,       0x4000000000,       0x8000000000,
    0x10000000000,      0x20000000000,      0x40000000000,      0x80000000000,
    0x100000000000,     0x200000000000,     0x400000000000,     0x800000000000,
    0x1000000000000,    0x2000000000000,    0x4000000000000,    0x8000000000000,
    0x10000000000000,   0x20000000000000,   0x40000000000000,   0x80000000000000,
    0x100000000000000,  0x200000000000000,  0x400000000000000,  0x800000000000000,
    0x1000000000000000, 0x2000000000000000, 0x4000000000000000, 0x8000000000000000,
    0x0,
};

pub const WHITE_FIELDS: u64 = 0xaa55aa55aa55aa55;
pub const BLACK_FIELDS: u64 = 0x55aa55aa55aa55aa;

///////////

pub inline fn get_bit(bitboard: u64, square: Square) bool {
    //var one64: u64 = 1;
    const mask = @as(u64, 1) << square.toU6();
    return (bitboard & mask) != 0;
}

pub fn print_bitboard(bitboard: u64) void {
    std.debug.print("\n", .{});

    for (0..8) |rank_index| {
        std.debug.print("  {} ", .{8 - rank_index});
        for (0..8) |file_index| {
            const square = (7 - rank_index) * 8 + file_index;
            const bitState: u1 = if (get_bit(bitboard, Square.fromInt(square))) 1 else 0;
            std.debug.print(" {}", .{bitState});
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("\n     a b c d e f g h\n\n", .{});
    std.debug.print(" Bitboard: 0x{0x}\n", .{bitboard});
    std.debug.print(" Bitboard: 0b{b}\n\n", .{bitboard});
}

///////////

pub const k1: u64 = 0x5555555555555555;
pub const k2: u64 = 0x3333333333333333;
pub const k4: u64 = 0x0f0f0f0f0f0f0f0f;
pub const kf: u64 = 0x0101010101010101;

pub inline fn pop_count(bitboard: u64) u7 {
    return @popCount(bitboard);
}

pub inline fn get_ls1b_index(bitboard: u64) u6 {
    std.debug.assert(bitboard != 0);
    return @as(u6, @truncate(@ctz(bitboard)));
}

pub inline fn pop_lsb_Sq(bitboard: *u64) Square {
    const lsb = get_ls1b_index(bitboard.*);
    bitboard.* &= bitboard.* - 1;
    return @as(Square, @enumFromInt(lsb));
}

pub inline fn pop_lsb(bitboard: *u64) u6 {
    const lsb = get_ls1b_index(bitboard.*);
    bitboard.* &= bitboard.* - 1;
    return lsb;
}

// pub inline fn pop_bit(bitboard: *u64, square: Square) void {
//     if (get_bit(bitboard.*, square)) {
//         bitboard.* ^= @as(u64, 1) << square.toU6();
//     }
// }

// pub inline fn pop_lsb(bitboard: *u64) void {
//     bitboard.* &= bitboard.* - 1;
// }
