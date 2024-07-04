const std = @import("std");
const bb = @import("bitboard.zig");
const position = @import("position.zig");

const Square = position.Square;
const PieceType = position.PieceType;
const File = position.File;
const Color = position.Color;
const Direction = position.Direction;

const rank_of_iter = position.rank_of_iter;
const file_of_iter = position.file_of_iter;
const diagonal_of_iter = position.diagonal_of_iter;
const anti_diagonal_of_iter = position.anti_diagonal_of_iter;
const shift = position.shift;

const sq_iter = position.sq_iter;
const SQUARE_BB = bb.SQUARE_BB;
const MASK_RANK = bb.MASK_RANK;
const MASK_FILE = bb.MASK_FILE;
const MASK_DIAGONAL = bb.MASK_DIAGONAL;
const MASK_ANTI_DIAGONAL = bb.MASK_ANTI_DIAGONAL;

pub const KING_ATTACKS = [_]u64{
    0x302,              0x705,              0xe0a,              0x1c14,
    0x3828,             0x7050,             0xe0a0,             0xc040,
    0x30203,            0x70507,            0xe0a0e,            0x1c141c,
    0x382838,           0x705070,           0xe0a0e0,           0xc040c0,
    0x3020300,          0x7050700,          0xe0a0e00,          0x1c141c00,
    0x38283800,         0x70507000,         0xe0a0e000,         0xc040c000,
    0x302030000,        0x705070000,        0xe0a0e0000,        0x1c141c0000,
    0x3828380000,       0x7050700000,       0xe0a0e00000,       0xc040c00000,
    0x30203000000,      0x70507000000,      0xe0a0e000000,      0x1c141c000000,
    0x382838000000,     0x705070000000,     0xe0a0e0000000,     0xc040c0000000,
    0x3020300000000,    0x7050700000000,    0xe0a0e00000000,    0x1c141c00000000,
    0x38283800000000,   0x70507000000000,   0xe0a0e000000000,   0xc040c000000000,
    0x302030000000000,  0x705070000000000,  0xe0a0e0000000000,  0x1c141c0000000000,
    0x3828380000000000, 0x7050700000000000, 0xe0a0e00000000000, 0xc040c00000000000,
    0x203000000000000,  0x507000000000000,  0xa0e000000000000,  0x141c000000000000,
    0x2838000000000000, 0x5070000000000000, 0xa0e0000000000000, 0x40c0000000000000,
};

//A lookup table for knight move bitboards
pub const KNIGHT_ATTACKS = [_]u64{
    0x20400,            0x50800,            0xa1100,            0x142200,
    0x284400,           0x508800,           0xa01000,           0x402000,
    0x2040004,          0x5080008,          0xa110011,          0x14220022,
    0x28440044,         0x50880088,         0xa0100010,         0x40200020,
    0x204000402,        0x508000805,        0xa1100110a,        0x1422002214,
    0x2844004428,       0x5088008850,       0xa0100010a0,       0x4020002040,
    0x20400040200,      0x50800080500,      0xa1100110a00,      0x142200221400,
    0x284400442800,     0x508800885000,     0xa0100010a000,     0x402000204000,
    0x2040004020000,    0x5080008050000,    0xa1100110a0000,    0x14220022140000,
    0x28440044280000,   0x50880088500000,   0xa0100010a00000,   0x40200020400000,
    0x204000402000000,  0x508000805000000,  0xa1100110a000000,  0x1422002214000000,
    0x2844004428000000, 0x5088008850000000, 0xa0100010a0000000, 0x4020002040000000,
    0x400040200000000,  0x800080500000000,  0x1100110a00000000, 0x2200221400000000,
    0x4400442800000000, 0x8800885000000000, 0x100010a000000000, 0x2000204000000000,
    0x4020000000000,    0x8050000000000,    0x110a0000000000,   0x22140000000000,
    0x44280000000000,   0x0088500000000000, 0x0010a00000000000, 0x20400000000000,
};

//A lookup table for white pawn move bitboards
pub const WHITE_PAWN_ATTACKS = [_]u64{
    0x200,              0x500,              0xa00,              0x1400,
    0x2800,             0x5000,             0xa000,             0x4000,
    0x20000,            0x50000,            0xa0000,            0x140000,
    0x280000,           0x500000,           0xa00000,           0x400000,
    0x2000000,          0x5000000,          0xa000000,          0x14000000,
    0x28000000,         0x50000000,         0xa0000000,         0x40000000,
    0x200000000,        0x500000000,        0xa00000000,        0x1400000000,
    0x2800000000,       0x5000000000,       0xa000000000,       0x4000000000,
    0x20000000000,      0x50000000000,      0xa0000000000,      0x140000000000,
    0x280000000000,     0x500000000000,     0xa00000000000,     0x400000000000,
    0x2000000000000,    0x5000000000000,    0xa000000000000,    0x14000000000000,
    0x28000000000000,   0x50000000000000,   0xa0000000000000,   0x40000000000000,
    0x200000000000000,  0x500000000000000,  0xa00000000000000,  0x1400000000000000,
    0x2800000000000000, 0x5000000000000000, 0xa000000000000000, 0x4000000000000000,
    0x0,                0x0,                0x0,                0x0,
    0x0,                0x0,                0x0,                0x0,
};

//A lookup table for black pawn move bitboards
pub const BLACK_PAWN_ATTACKS = [_]u64{
    0x0,              0x0,              0x0,              0x0,
    0x0,              0x0,              0x0,              0x0,
    0x2,              0x5,              0xa,              0x14,
    0x28,             0x50,             0xa0,             0x40,
    0x200,            0x500,            0xa00,            0x1400,
    0x2800,           0x5000,           0xa000,           0x4000,
    0x20000,          0x50000,          0xa0000,          0x140000,
    0x280000,         0x500000,         0xa00000,         0x400000,
    0x2000000,        0x5000000,        0xa000000,        0x14000000,
    0x28000000,       0x50000000,       0xa0000000,       0x40000000,
    0x200000000,      0x500000000,      0xa00000000,      0x1400000000,
    0x2800000000,     0x5000000000,     0xa000000000,     0x4000000000,
    0x20000000000,    0x50000000000,    0xa0000000000,    0x140000000000,
    0x280000000000,   0x500000000000,   0xa00000000000,   0x400000000000,
    0x2000000000000,  0x5000000000000,  0xa000000000000,  0x14000000000000,
    0x28000000000000, 0x50000000000000, 0xa0000000000000, 0x40000000000000,
};

pub inline fn reverse(_b: u64) u64 {
    var b = _b;
    b = (b & 0x5555555555555555) << 1 | ((b >> 1) & 0x5555555555555555);
    b = (b & 0x3333333333333333) << 2 | ((b >> 2) & 0x3333333333333333);
    b = (b & 0x0f0f0f0f0f0f0f0f) << 4 | ((b >> 4) & 0x0f0f0f0f0f0f0f0f);
    b = (b & 0x00ff00ff00ff00ff) << 8 | ((b >> 8) & 0x00ff00ff00ff00ff);

    return (b << 48) | ((b & 0xffff0000) << 16) |
        ((b >> 16) & 0xffff0000) | (b >> 48);
}

pub inline fn sliding_attacks(sq_idx: u6, occ: u64, mask: u64) u64 {
    return (((mask & occ) -% SQUARE_BB[sq_idx] *% 2) ^
        reverse(reverse(mask & occ) -% reverse(SQUARE_BB[sq_idx]) *% 2)) & mask;
}

pub inline fn get_rook_attacks_for_init(square: Square, occ: u64) u64 {
    const sq_idx = square.toU6();
    return sliding_attacks(sq_idx, occ, MASK_FILE[square.file_of().toU3()]) | sliding_attacks(sq_idx, occ, MASK_RANK[square.rank_of().toU3()]);
}

var ROOK_ATTACK_MASKS: [64]u64 = std.mem.zeroes([64]u64);
var ROOK_ATTACK_SHIFTS: [64]i32 = std.mem.zeroes([64]i32);
var ROOK_ATTACKS: [64][4096]u64 = std.mem.zeroes([64][4096]u64);

pub const ROOK_MAGICS = [_]u64{
    0x0080001020400080, 0x0040001000200040, 0x0080081000200080, 0x0080040800100080,
    0x0080020400080080, 0x0080010200040080, 0x0080008001000200, 0x0080002040800100,
    0x0000800020400080, 0x0000400020005000, 0x0000801000200080, 0x0000800800100080,
    0x0000800400080080, 0x0000800200040080, 0x0000800100020080, 0x0000800040800100,
    0x0000208000400080, 0x0000404000201000, 0x0000808010002000, 0x0000808008001000,
    0x0000808004000800, 0x0000808002000400, 0x0000010100020004, 0x0000020000408104,
    0x0000208080004000, 0x0000200040005000, 0x0000100080200080, 0x0000080080100080,
    0x0000040080080080, 0x0000020080040080, 0x0000010080800200, 0x0000800080004100,
    0x0000204000800080, 0x0000200040401000, 0x0000100080802000, 0x0000080080801000,
    0x0000040080800800, 0x0000020080800400, 0x0000020001010004, 0x0000800040800100,
    0x0000204000808000, 0x0000200040008080, 0x0000100020008080, 0x0000080010008080,
    0x0000040008008080, 0x0000020004008080, 0x0000010002008080, 0x0000004081020004,
    0x0000204000800080, 0x0000200040008080, 0x0000100020008080, 0x0000080010008080,
    0x0000040008008080, 0x0000020004008080, 0x0000800100020080, 0x0000800041000080,
    0x00FFFCDDFCED714A, 0x007FFCDDFCED714A, 0x003FFFCDFFD88096, 0x0000040810002101,
    0x0001000204080011, 0x0001000204000801, 0x0001000082000401, 0x0001FFFAABFAD1A2,
};

pub inline fn initialise_rook_attacks() void {
    var edges: u64 = undefined;
    var subset: u64 = undefined;
    var index: u64 = undefined;

    for (sq_iter) |sq| {
        edges = ((MASK_RANK[File.AFILE.toU3()] | MASK_RANK[File.HFILE.toU3()]) & ~MASK_RANK[rank_of_iter(sq)]) |
            ((MASK_FILE[File.AFILE.toU3()] | MASK_FILE[File.HFILE.toU3()]) & ~MASK_FILE[file_of_iter(sq)]);

        ROOK_ATTACK_MASKS[sq] = (MASK_RANK[rank_of_iter(sq)] ^ MASK_FILE[file_of_iter(sq)]) & ~edges;

        ROOK_ATTACK_SHIFTS[sq] = 64 - bb.pop_count(ROOK_ATTACK_MASKS[sq]);

        subset = 0;
        index = subset;
        index = index *% ROOK_MAGICS[sq];
        index = index >> @as(u6, @intCast(ROOK_ATTACK_SHIFTS[sq]));
        ROOK_ATTACKS[sq][index] = get_rook_attacks_for_init(Square.fromInt(sq), subset);
        subset = (subset -% ROOK_ATTACK_MASKS[sq]) & ROOK_ATTACK_MASKS[sq];

        while (subset != 0) {
            index = subset;
            index = index *% ROOK_MAGICS[sq];
            index = index >> @as(u6, @intCast(ROOK_ATTACK_SHIFTS[sq]));
            ROOK_ATTACKS[sq][index] = get_rook_attacks_for_init(Square.fromInt(sq), subset);
            subset = (subset -% ROOK_ATTACK_MASKS[sq]) & ROOK_ATTACK_MASKS[sq];
        }
    }
}

//Returns the attacks bitboard for a rook at a given square, using the magic lookup table
pub inline fn get_rook_attacks(square: u6, occ: u64) u64 {
    return ROOK_ATTACKS[square][((occ & ROOK_ATTACK_MASKS[square]) *% ROOK_MAGICS[square]) >> @as(u6, @intCast(ROOK_ATTACK_SHIFTS[square]))];
}

//Returns the 'x-ray attacks' for a rook at a given square. X-ray attacks cover squares that are not immediately
//accessible by the rook, but become available when the immediate blockers are removed from the board
pub inline fn get_xray_rook_attacks(square: Square, occ: u64, _blockers: u64) u64 {
    var blockers = _blockers;
    const sq_idx = square.toU6();
    const attcks = get_rook_attacks(sq_idx, occ);
    blockers &= attcks;
    return attcks ^ get_rook_attacks(sq_idx, occ ^ blockers);
}

//Returns bishop attacks from a given square, using the Hyperbola Quintessence Algorithm. Only used to initialize
//the magic lookup table
pub inline fn get_bishop_attacks_for_init(square: Square, occ: u64) u64 {
    const sq_idx = square.toU6();
    return sliding_attacks(sq_idx, occ, MASK_DIAGONAL[square.diagonal_of()]) |
        sliding_attacks(sq_idx, occ, MASK_ANTI_DIAGONAL[square.anti_diagonal_of()]);
}

var BISHOP_ATTACK_MASKS: [64]u64 = std.mem.zeroes([64]u64);
var BISHOP_ATTACK_SHIFTS: [64]i32 = std.mem.zeroes([64]i32);
var BISHOP_ATTACKS: [64][512]u64 = std.mem.zeroes([64][512]u64);

pub const BISHOP_MAGICS = [_]u64{
    0x0002020202020200, 0x0002020202020000, 0x0004010202000000, 0x0004040080000000,
    0x0001104000000000, 0x0000821040000000, 0x0000410410400000, 0x0000104104104000,
    0x0000040404040400, 0x0000020202020200, 0x0000040102020000, 0x0000040400800000,
    0x0000011040000000, 0x0000008210400000, 0x0000004104104000, 0x0000002082082000,
    0x0004000808080800, 0x0002000404040400, 0x0001000202020200, 0x0000800802004000,
    0x0000800400A00000, 0x0000200100884000, 0x0000400082082000, 0x0000200041041000,
    0x0002080010101000, 0x0001040008080800, 0x0000208004010400, 0x0000404004010200,
    0x0000840000802000, 0x0000404002011000, 0x0000808001041000, 0x0000404000820800,
    0x0001041000202000, 0x0000820800101000, 0x0000104400080800, 0x0000020080080080,
    0x0000404040040100, 0x0000808100020100, 0x0001010100020800, 0x0000808080010400,
    0x0000820820004000, 0x0000410410002000, 0x0000082088001000, 0x0000002011000800,
    0x0000080100400400, 0x0001010101000200, 0x0002020202000400, 0x0001010101000200,
    0x0000410410400000, 0x0000208208200000, 0x0000002084100000, 0x0000000020880000,
    0x0000001002020000, 0x0000040408020000, 0x0004040404040000, 0x0002020202020000,
    0x0000104104104000, 0x0000002082082000, 0x0000000020841000, 0x0000000000208800,
    0x0000000010020200, 0x0000000404080200, 0x0000040404040400, 0x0002020202020200,
};

//Initializes the magic lookup table for bishops
pub inline fn initialise_bishop_attacks() void {
    var edges: u64 = undefined;
    var subset: u64 = undefined;
    var index: u64 = undefined;

    for (sq_iter) |sq| {
        edges = ((MASK_RANK[File.AFILE.toU3()] | MASK_RANK[File.HFILE.toU3()]) & ~MASK_RANK[rank_of_iter(sq)]) |
            ((MASK_FILE[File.AFILE.toU3()] | MASK_FILE[File.HFILE.toU3()]) & ~MASK_FILE[file_of_iter(sq)]);

        BISHOP_ATTACK_MASKS[sq] = (MASK_DIAGONAL[diagonal_of_iter(sq)] ^ MASK_ANTI_DIAGONAL[anti_diagonal_of_iter(sq)]) & ~edges;

        BISHOP_ATTACK_SHIFTS[sq] = 64 - bb.pop_count(BISHOP_ATTACK_MASKS[sq]);

        subset = 0;
        index = subset;
        index = index *% BISHOP_MAGICS[sq];
        index = index >> @as(u6, @intCast(BISHOP_ATTACK_SHIFTS[sq]));
        BISHOP_ATTACKS[sq][index] = get_bishop_attacks_for_init(Square.fromInt(sq), subset);
        subset = (subset -% BISHOP_ATTACK_MASKS[sq]) & BISHOP_ATTACK_MASKS[sq];

        while (subset != 0) {
            index = subset;
            index = index *% BISHOP_MAGICS[sq];
            index = index >> @as(u6, @intCast(BISHOP_ATTACK_SHIFTS[sq]));
            BISHOP_ATTACKS[sq][index] = get_bishop_attacks_for_init(Square.fromInt(sq), subset);
            subset = (subset -% BISHOP_ATTACK_MASKS[sq]) & BISHOP_ATTACK_MASKS[sq];
        }
    }
}

//Returns the attacks bitboard for a bishop at a given square, using the magic lookup table
pub inline fn get_bishop_attacks(square: u6, occ: u64) u64 {
    return BISHOP_ATTACKS[square][
        ((occ & BISHOP_ATTACK_MASKS[square]) *% BISHOP_MAGICS[square]) >> @as(u6, @intCast(BISHOP_ATTACK_SHIFTS[square]))
    ];
}

//Returns the 'x-ray attacks' for a bishop at a given square. X-ray attacks cover squares that are not immediately
//accessible by the rook, but become available when the immediate blockers are removed from the board
pub inline fn get_xray_bishop_attacks(square: Square, occ: u64, _blockers: u64) u64 {
    var blockers = _blockers;
    const sq_idx = square.toU6();
    const attcks = get_bishop_attacks(sq_idx, occ);
    blockers &= attcks;
    return attcks ^ get_bishop_attacks(sq_idx, occ ^ blockers);
}

pub var SQUARES_BETWEEN_BB: [64][64]u64 = std.mem.zeroes([64][64]u64);

//Initializes the lookup table for the bitboard of squares in between two given squares (0 if the
//two squares are not aligned)
pub inline fn initialise_squares_between() void {
    var sqs: u64 = undefined;

    for (sq_iter) |sq1| {
        for (sq_iter) |sq2| {
            sqs = SQUARE_BB[sq1] | SQUARE_BB[sq2];
            if (file_of_iter(sq1) == file_of_iter(sq2) or rank_of_iter(sq1) == rank_of_iter(sq2)) {
                SQUARES_BETWEEN_BB[sq1][sq2] =
                    get_rook_attacks_for_init(Square.fromInt(sq1), sqs) & get_rook_attacks_for_init(Square.fromInt(sq2), sqs);
            } else if (diagonal_of_iter(sq1) == diagonal_of_iter(sq2) or anti_diagonal_of_iter(sq1) == anti_diagonal_of_iter(sq2)) {
                SQUARES_BETWEEN_BB[sq1][sq2] =
                    get_bishop_attacks_for_init(Square.fromInt(sq1), sqs) & get_bishop_attacks_for_init(Square.fromInt(sq2), sqs);
            }
        }
    }
}

pub var LINE: [64][64]u64 = std.mem.zeroes([64][64]u64);

//Initializes the lookup table for the bitboard of all squares along the line of two given squares (0 if the
//two squares are not aligned)
pub inline fn initialise_line() void {
    for (sq_iter) |sq1| {
        for (sq_iter) |sq2| {
            if ((file_of_iter(sq1) == file_of_iter(sq2)) or (rank_of_iter(sq1) == rank_of_iter(sq2))) {
                LINE[sq1][sq2] =
                    get_rook_attacks_for_init(Square.fromInt(sq1), @as(u64, 0)) & get_rook_attacks_for_init(Square.fromInt(sq2), @as(u64, 0)) | SQUARE_BB[sq1] | SQUARE_BB[sq2];
            } else if (diagonal_of_iter(sq1) == diagonal_of_iter(sq2) or anti_diagonal_of_iter(sq1) == anti_diagonal_of_iter(sq2)) {
                LINE[sq1][sq2] =
                    get_bishop_attacks_for_init(Square.fromInt(sq1), @as(u64, 0)) & get_bishop_attacks_for_init(Square.fromInt(sq2), @as(u64, 0)) | SQUARE_BB[sq1] | SQUARE_BB[sq2];
            }
        }
    }
}

pub var PAWN_ATTACKS: [position.NCOLORS][64]u64 = std.mem.zeroes([position.NCOLORS][64]u64);
pub var PSEUDO_LEGAL_ATTACKS: [position.NPIECE_TYPES][64]u64 = std.mem.zeroes([position.NPIECE_TYPES][64]u64);

//Initializes the table containg pseudolegal attacks of each piece for each square. This does not include blockers
//for sliding pieces
pub inline fn initialise_pseudo_legal() void {
    std.mem.copyBackwards(u64, (&PAWN_ATTACKS)[0][0..64], WHITE_PAWN_ATTACKS[0..64]);
    std.mem.copyBackwards(u64, (&PAWN_ATTACKS)[1][0..64], BLACK_PAWN_ATTACKS[0..64]);
    std.mem.copyBackwards(u64, PSEUDO_LEGAL_ATTACKS[PieceType.Knight.toU3()][0..64], KNIGHT_ATTACKS[0..64]);
    std.mem.copyBackwards(u64, PSEUDO_LEGAL_ATTACKS[PieceType.King.toU3()][0..64], KING_ATTACKS[0..64]);
    for (sq_iter) |s| {
        PSEUDO_LEGAL_ATTACKS[PieceType.Rook.toU3()][s] = get_rook_attacks_for_init(Square.fromInt(s), 0);
        PSEUDO_LEGAL_ATTACKS[PieceType.Bishop.toU3()][s] = get_bishop_attacks_for_init(Square.fromInt(s), 0);
        PSEUDO_LEGAL_ATTACKS[PieceType.Queen.toU3()][s] = PSEUDO_LEGAL_ATTACKS[PieceType.Rook.toU3()][s] |
            PSEUDO_LEGAL_ATTACKS[PieceType.Bishop.toU3()][s];
    }
}

//Initializes lookup tables for rook moves, bishop moves, in-between squares, aligned squares and pseudolegal moves
pub inline fn initialise_all_databases() void {
    initialise_rook_attacks();
    initialise_bishop_attacks();
    initialise_squares_between();
    initialise_line();
    initialise_pseudo_legal();
}

pub inline fn piece_attacks(sq_idx: u6, occ: u64, P: PieceType) u64 {
    std.debug.assert(P != PieceType.Pawn);

    return switch (P) {
        PieceType.Rook => get_rook_attacks(sq_idx, occ),
        PieceType.Bishop => get_bishop_attacks(sq_idx, occ),
        PieceType.Queen => get_rook_attacks(sq_idx, occ) | get_bishop_attacks(sq_idx, occ),
        else => (&PSEUDO_LEGAL_ATTACKS)[P.toU3()][sq_idx],
    };
}

pub inline fn piece_attacks_Sq(s: Square, occ: u64, comptime P: PieceType) u64 {
    std.debug.assert(P != PieceType.Pawn);
    const sq_idx = s.toU6();

    return switch (P) {
        PieceType.Rook => get_rook_attacks(sq_idx, occ),
        PieceType.Bishop => get_bishop_attacks(sq_idx, occ),
        PieceType.Queen => get_rook_attacks(sq_idx, occ) | get_bishop_attacks(sq_idx, occ),
        else => PSEUDO_LEGAL_ATTACKS[P.toU3()][s.toU6()],
    };
}

pub inline fn pawn_attacks_from_bitboard(p: u64, comptime c: Color) u64 {
    return if (c == Color.White)
        shift(p, Direction.NORTH_WEST) | shift(p, Direction.NORTH_EAST)
    else
        shift(p, Direction.SOUTH_WEST) | shift(p, Direction.SOUTH_EAST);
}

pub inline fn pawn_attacks_from_square_Sq(s: Square, comptime c: Color) u64 {
    return (&PAWN_ATTACKS)[c.toU4()][s.toU6()];
}

pub inline fn pawn_attacks_from_square(s: u6, comptime c: Color) u64 {
    return (&PAWN_ATTACKS)[c.toU4()][s];
}
