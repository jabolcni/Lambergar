const std = @import("std");
const position = @import("position.zig");
const bb = @import("bitboard.zig");

const Position = position.Position;
const Square = position.Square;
const Piece = position.Piece;
const PieceType = position.PieceType;
const Color = position.Color;

pub const TEMPO = 15;

// pawns, knights, bishops, rooks, queens, kings
const material_mg = [6]i32{ 82, 337, 365, 477, 1025, 0 };
const material_eg = [6]i32{ 94, 281, 297, 512, 936, 0 };

const mg_pawn_table = [64]i32{
    0,   0,   0,   0,   0,   0,   0,  0,
    98,  134, 61,  95,  68,  126, 34, -11,
    -6,  7,   26,  31,  65,  56,  25, -20,
    -14, 13,  6,   21,  23,  12,  17, -23,
    -27, -2,  -5,  12,  17,  6,   10, -25,
    -26, -4,  -4,  -10, 3,   3,   33, -12,
    -35, -1,  -20, -23, -15, 24,  38, -22,
    0,   0,   0,   0,   0,   0,   0,  0,
};

const eg_pawn_table = [64]i32{
    0,   0,   0,   0,   0,   0,   0,   0,
    178, 173, 158, 134, 147, 132, 165, 187,
    94,  100, 85,  67,  56,  53,  82,  84,
    32,  24,  13,  5,   -2,  4,   17,  17,
    13,  9,   -3,  -7,  -7,  -8,  3,   -1,
    4,   7,   -6,  1,   0,   -5,  -1,  -8,
    13,  8,   8,   10,  13,  0,   2,   -7,
    0,   0,   0,   0,   0,   0,   0,   0,
};

const mg_knight_table = [64]i32{
    -167, -89, -34, -49, 61,  -97, -15, -107,
    -73,  -41, 72,  36,  23,  62,  7,   -17,
    -47,  60,  37,  65,  84,  129, 73,  44,
    -9,   17,  19,  53,  37,  69,  18,  22,
    -13,  4,   16,  13,  28,  19,  21,  -8,
    -23,  -9,  12,  10,  19,  17,  25,  -16,
    -29,  -53, -12, -3,  -1,  18,  -14, -19,
    -105, -21, -58, -33, -17, -28, -19, -23,
};

const eg_knight_table = [64]i32{
    -58, -38, -13, -28, -31, -27, -63, -99,
    -25, -8,  -25, -2,  -9,  -25, -24, -52,
    -24, -20, 10,  9,   -1,  -9,  -19, -41,
    -17, 3,   22,  22,  22,  11,  8,   -18,
    -18, -6,  16,  25,  16,  17,  4,   -18,
    -23, -3,  -1,  15,  10,  -3,  -20, -22,
    -42, -20, -10, -5,  -2,  -20, -23, -44,
    -29, -51, -23, -15, -22, -18, -50, -64,
};

const mg_bishop_table = [64]i32{
    -29, 4,  -82, -37, -25, -42, 7,   -8,
    -26, 16, -18, -13, 30,  59,  18,  -47,
    -16, 37, 43,  40,  35,  50,  37,  -2,
    -4,  5,  19,  50,  37,  37,  7,   -2,
    -6,  13, 13,  26,  34,  12,  10,  4,
    0,   15, 15,  15,  14,  27,  18,  10,
    4,   15, 16,  0,   7,   21,  33,  1,
    -33, -3, -14, -21, -13, -12, -39, -21,
};

const eg_bishop_table = [64]i32{
    -14, -21, -11, -8,  -7, -9,  -17, -24,
    -8,  -4,  7,   -12, -3, -13, -4,  -14,
    2,   -8,  0,   -1,  -2, 6,   0,   4,
    -3,  9,   12,  9,   14, 10,  3,   2,
    -6,  3,   13,  19,  7,  10,  -3,  -9,
    -12, -3,  8,   10,  13, 3,   -7,  -15,
    -14, -18, -7,  -1,  4,  -9,  -15, -27,
    -23, -9,  -23, -5,  -9, -16, -5,  -17,
};

const mg_rook_table = [64]i32{
    32,  42,  32,  51,  63, 9,  31,  43,
    27,  32,  58,  62,  80, 67, 26,  44,
    -5,  19,  26,  36,  17, 45, 61,  16,
    -24, -11, 7,   26,  24, 35, -8,  -20,
    -36, -26, -12, -1,  9,  -7, 6,   -23,
    -45, -25, -16, -17, 3,  0,  -5,  -33,
    -44, -16, -20, -9,  -1, 11, -6,  -71,
    -19, -13, 1,   17,  16, 7,  -37, -26,
};

const eg_rook_table = [64]i32{
    13, 10, 18, 15, 12, 12,  8,   5,
    11, 13, 13, 11, -3, 3,   8,   3,
    7,  7,  7,  5,  4,  -3,  -5,  -3,
    4,  3,  13, 1,  2,  1,   -1,  2,
    3,  5,  8,  4,  -5, -6,  -8,  -11,
    -4, 0,  -5, -1, -7, -12, -8,  -16,
    -6, -6, 0,  2,  -9, -9,  -11, -3,
    -9, 2,  3,  -1, -5, -13, 4,   -20,
};

const mg_queen_table = [64]i32{
    -28, 0,   29,  12,  59,  44,  43,  45,
    -24, -39, -5,  1,   -16, 57,  28,  54,
    -13, -17, 7,   8,   29,  56,  47,  57,
    -27, -27, -16, -16, -1,  17,  -2,  1,
    -9,  -26, -9,  -10, -2,  -4,  3,   -3,
    -14, 2,   -11, -2,  -5,  2,   14,  5,
    -35, -8,  11,  2,   8,   15,  -3,  1,
    -1,  -18, -9,  10,  -15, -25, -31, -50,
};

const eg_queen_table = [64]i32{
    -9,  22,  22,  27,  27,  19,  10,  20,
    -17, 20,  32,  41,  58,  25,  30,  0,
    -20, 6,   9,   49,  47,  35,  19,  9,
    3,   22,  24,  45,  57,  40,  57,  36,
    -18, 28,  19,  47,  31,  34,  39,  23,
    -16, -27, 15,  6,   9,   17,  10,  5,
    -22, -23, -30, -16, -16, -23, -36, -32,
    -33, -28, -22, -43, -5,  -32, -20, -41,
};

const mg_king_table = [64]i32{
    -65, 23,  16,  -15, -56, -34, 2,   13,
    29,  -1,  -20, -7,  -8,  -4,  -38, -29,
    -9,  24,  2,   -16, -20, 6,   22,  -22,
    -17, -20, -12, -27, -30, -25, -14, -36,
    -49, -1,  -27, -39, -46, -44, -33, -51,
    -14, -14, -22, -46, -44, -30, -15, -27,
    1,   7,   -8,  -64, -43, -16, 9,   8,
    -15, 36,  12,  -54, 8,   -28, 24,  14,
};

const eg_king_table = [64]i32{
    // zig fmt: off
    -74, -35, -18, -18, -11,  15,   4, -17,
    -12,  17,  14,  17,  17,  38,  23,  11,
     10,  17,  23,  15,  20,  45,  44,  13,
     -8,  22,  24,  27,  26,  33,  26,   3,
    -18,  -4,  21,  24,  27,  23,   9, -11,
    -19,  -3,  11,  21,  23,  16,   7,  -9,
    -27, -11,   4,  13,  14,   4,  -5, -17,
    -53, -34, -21, -11, -28, -14, -24, -43
    // zig fmt: on
};

const mg_pesto_table = [6][64]i32{
    mg_pawn_table,
    mg_knight_table,
    mg_bishop_table,
    mg_rook_table,
    mg_queen_table,
    mg_king_table,
};

const eg_pesto_table = [6][64]i32{
    eg_pawn_table,
    eg_knight_table,
    eg_bishop_table,
    eg_rook_table,
    eg_queen_table,
    eg_king_table,
};

const phaseValues = [6]u8{0, 3, 3, 5, 10, 0};

var midgame_table: [2][6][64]i32 = undefined;
var endgame_table: [2][6][64]i32 = undefined;


const KING_EDGE = [64]i32{
    // zig fmt: off
    -95,  -95,  -90,  -90,  -90,  -90,  -95,  -95,  
    -95,  -50,  -50,  -50,  -50,  -50,  -50,  -95,  
    -90,  -50,  -20,  -20,  -20,  -20,  -50,  -90,  
    -90,  -50,  -20,    0,    0,  -20,  -50,  -90,  
    -90,  -50,  -20,    0,    0,  -20,  -50,  -90,  
    -90,  -50,  -20,  -20,  -20,  -20,  -50,  -90,  
    -95,  -50,  -50,  -50,  -50,  -50,  -50,  -95,  
    -95,  -95,  -90,  -90,  -90,  -90,  -95,  -95
    // zig fmt: on
};

const CENTER = [64]i32{
    // zig fmt: off
    -30, -20, -10,   0,   0, -10, -20, -30,
    -20, -10,   0,  10,  10,   0, -10, -20,
    -10,   0,  10,  20,  20,  10,   0, -10,
      0,  10,  20,  30,  30,  20,  10,   0,
      0,  10,  20,  30,  30,  20,  10,   0,
    -10,   0,  10,  20,  20,  10,   0, -10,
    -20, -10,   0,  10,  10,   0, -10, -20,
    -30, -20, -10,   0,   0, -10, -20, -30
    // zig fmt: on
};

const MATE_ON_A1_H8 = [64]i32{
    // zig fmt: off
    0, 10, 20, 30, 40, 50, 60, 70,
    10, 10, 20, 30, 40, 50, 60, 60,
    20, 20, 20, 30, 40, 50, 50, 50,
    30, 30, 30, 30, 40, 40, 40, 40,
    40, 40, 40, 40, 30, 30, 30, 30,
    50, 50, 50, 40, 30, 20, 20, 20,
    60, 60, 50, 40, 30, 20, 10, 10,
    70, 60, 50, 40, 30, 20, 10,  0
    // zig fmt: on
};

const MATE_ON_A8_H1 = [64]i32{
    // zig fmt: off
    70, 60, 50, 40, 30, 20, 10,  0,
    60, 60, 50, 40, 30, 20, 10, 10,
    50, 50, 50, 40, 30, 20, 20, 20,
    40, 40, 40, 40, 30, 30, 30, 30,
    30, 30, 30, 30, 40, 40, 40, 40,
    20, 20, 20, 30, 40, 50, 50, 50,
    10, 10, 20, 30, 40, 50, 60, 60,
    0, 10, 20, 30, 40, 50, 60, 70
    // zig fmt: on
    };


pub inline fn distance(sq1: u6, sq2: u6) u4 {

    const dist = [100]u4{
        // zig fmt: off
        0, 1, 1, 1, 2, 2, 2, 2, 2, 3,
        3, 3, 3, 3, 3, 3, 4, 4, 4, 4,
        4, 4, 4, 4, 4, 5, 5, 5, 5, 5,
        5, 5, 5, 5, 5, 5, 6, 6, 6, 6,
        6, 6, 6, 6, 6, 6, 6, 6, 6, 7,
        7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
        7, 7, 7, 7, 8, 8, 8, 8, 8, 8,
        8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
        8, 9, 9, 9, 9, 9, 9, 9, 9, 9,
        9, 9, 9, 9, 9, 9, 9, 9, 9, 9
        // zig fmt: on       
    };

    var drank:i8 = @as(i8,@intCast(position.rank_of_u6(sq1)))-@as(i8,@intCast(position.rank_of_u6(sq2)));
    var dfile = @as(i8,@intCast(position.file_of_u6(sq1)))-@as(i8,@intCast(position.file_of_u6(sq2)));
    return dist[@as(u7, (@intCast(drank*drank + dfile*dfile)))];

}


pub fn init_eval() void {
    init_pesto_tables();
}

pub fn init_pesto_tables() void {
    for (PieceType.Pawn.toU3() ..(PieceType.King.toU3()+1)) |piece| {
        for (Square.a1.toU7()..(Square.h8.toU7()+1)) |s_idx| {
            midgame_table[Color.White.toU4()][piece][s_idx] = mg_pesto_table[piece][s_idx^56];
            endgame_table[Color.White.toU4()][piece][s_idx] = eg_pesto_table[piece][s_idx^56];
            midgame_table[Color.Black.toU4()][piece][s_idx] = mg_pesto_table[piece][s_idx];
            endgame_table[Color.Black.toU4()][piece][s_idx] = eg_pesto_table[piece][s_idx];
        }
    }
}

pub const Evaluation = struct {
    eval_mg: i32 = 0,
    eval_eg: i32 = 0,
    phase: [2]u8 = [1]u8{0} ** 2,

    pub inline fn put_piece(self: *Evaluation, pc: Piece, s_idx: u6) void {

        const pc_type_idx = pc.type_of().toU3();

        if (pc.color() == Color.White) {
            self.eval_mg += material_mg[pc_type_idx];
            self.eval_eg += material_eg[pc_type_idx];
            
            self.eval_mg += midgame_table[Color.White.toU4()][pc_type_idx][s_idx];
            self.eval_eg += endgame_table[Color.White.toU4()][pc_type_idx][s_idx];            

            self.phase[Color.White.toU4()] += phaseValues[pc_type_idx];
        } else {
            self.eval_mg -= material_mg[pc_type_idx];
            self.eval_eg -= material_eg[pc_type_idx];

            self.eval_mg -= midgame_table[Color.Black.toU4()][pc_type_idx][s_idx];
            self.eval_eg -= endgame_table[Color.Black.toU4()][pc_type_idx][s_idx];            

            self.phase[Color.Black.toU4()] += phaseValues[pc_type_idx];
        }
    }

    pub inline fn remove_piece(self: *Evaluation, pc: Piece, s_idx: u6) void {

        const pc_type_idx = pc.type_of().toU3();

        if (pc != Piece.NO_PIECE) {
            if (pc.color() == Color.White) {
                self.eval_mg -= material_mg[pc_type_idx];
                self.eval_eg -= material_eg[pc_type_idx];
                
                self.eval_mg -= midgame_table[Color.White.toU4()][pc_type_idx][s_idx];
                self.eval_eg -= endgame_table[Color.White.toU4()][pc_type_idx][s_idx];            

                self.phase[Color.White.toU4()] -= phaseValues[pc_type_idx];
            } else {
                self.eval_mg += material_mg[pc_type_idx];
                self.eval_eg += material_eg[pc_type_idx];

                self.eval_mg += midgame_table[Color.Black.toU4()][pc_type_idx][s_idx];
                self.eval_eg += endgame_table[Color.Black.toU4()][pc_type_idx][s_idx];            

                self.phase[Color.Black.toU4()] -= phaseValues[pc_type_idx];
            }   
        }     
    }

    pub inline fn move_piece_quiet(self: *Evaluation, pc: Piece, from: u6, to: u6) void {
        const pc_type_idx = pc.type_of().toU3();

        if (pc != Piece.NO_PIECE) {
            if (pc.color() == Color.White) {
                self.eval_mg -= midgame_table[Color.White.toU4()][pc_type_idx][from];
                self.eval_eg -= endgame_table[Color.White.toU4()][pc_type_idx][from];            
 
                self.eval_mg += midgame_table[Color.White.toU4()][pc_type_idx][to];
                self.eval_eg += endgame_table[Color.White.toU4()][pc_type_idx][to];            
            } else {
                self.eval_mg += midgame_table[Color.Black.toU4()][pc_type_idx][from];
                self.eval_eg += endgame_table[Color.Black.toU4()][pc_type_idx][from];            

                self.eval_mg -= midgame_table[Color.Black.toU4()][pc_type_idx][to];
                self.eval_eg -= endgame_table[Color.Black.toU4()][pc_type_idx][to];            
            }   
        } 

    }

    pub inline fn move_piece(self: *Evaluation, from_pc: Piece, to_pc: Piece, from: u6, to: u6) void {

        self.remove_piece(to_pc, to);
        self.move_piece_quiet(from_pc, from, to);

    }

    pub fn eval(self: *Evaluation, pos: *Position, comptime perspective_color: Color) i32 {

        var phase_bounded = @min(self.phase[Color.White.toU4()]+self.phase[Color.Black.toU4()], 64);
        const perspective = if (perspective_color == Color.White) @as(i32, 1) else @as(i32, -1);
        var e: i32 = @divTrunc((self.eval_mg * phase_bounded + self.eval_eg * (64-phase_bounded)), 64);

            if (self.phase[Color.White.toU4()] > 3 and self.phase[Color.Black.toU4()] == 0 and pos.piece_count(Piece.BLACK_PAWN) == 0) {

                // White is stronger
                const white_king = bb.get_ls1b_index(pos.piece_bb[Piece.WHITE_KING.toU4()]);
                const black_king = bb.get_ls1b_index(pos.piece_bb[Piece.BLACK_KING.toU4()]);
                if(self.phase[Color.White.toU4()] == 6 and pos.piece_count(Piece.WHITE_BISHOP) == 1 and pos.piece_count(Piece.WHITE_KNIGHT) == 1) {
                    if ((pos.piece_bb[Piece.WHITE_BISHOP.toU4()] & bb.WHITE_FIELDS) != 0) {
                        e += MATE_ON_A8_H1[black_king];
                    } else {
                        e += MATE_ON_A1_H8[black_king];
                    }
                } else {
                    e -= CENTER[black_king];
                }
                e -= distance(white_king, black_king);

            } else if (self.phase[Color.Black.toU4()] > 3 and self.phase[Color.White.toU4()] == 0 and pos.piece_count(Piece.WHITE_PAWN) == 0) {

                // Black is stronger
                const white_king = bb.get_ls1b_index(pos.piece_bb[Piece.WHITE_KING.toU4()]);
                const black_king = bb.get_ls1b_index(pos.piece_bb[Piece.BLACK_KING.toU4()]);
                if(self.phase[Color.Black.toU4()] == 6 and pos.piece_count(Piece.BLACK_BISHOP) == 1 and pos.piece_count(Piece.BLACK_KNIGHT) == 1) {
                    if ((pos.piece_bb[Piece.BLACK_BISHOP.toU4()] & bb.WHITE_FIELDS) != 0) {
                        e -= MATE_ON_A8_H1[white_king];
                    } else {
                        e -= MATE_ON_A1_H8[white_king];
                    }
                } else {
                    e += CENTER[white_king];

                }
                e += distance(white_king, black_king);      
            }

        return e * perspective + TEMPO;

    }

};