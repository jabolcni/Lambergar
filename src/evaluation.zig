const std = @import("std");
const position = @import("position.zig");
const bb = @import("bitboard.zig");
const attacks = @import("attacks.zig");
const tuner = @import("tuner.zig");

const Position = position.Position;
const Square = position.Square;
const Piece = position.Piece;
const PieceType = position.PieceType;
const Color = position.Color;

pub const TEMPO = 15;
const mg_tempo = 15;
const eg_tempo = 0;

// pawns, knights, bishops, rooks, queens, kings

const material_mg = [6]i32{ 132, 503, 544, 854, 1486, 0 };
const material_eg = [6]i32{ 107, 254, 268, 483, 895, 0 };

const mg_pawn_table = [64]i32{ 0, 0, 0, 0, 0, 0, 0, 0, -27, -2, -7, 14, 21, 53, 69, 11, -45, -38, -14, -13, 4, -13, 23, -13, -49, -43, -13, 4, 2, 4, -18, -44, -29, -26, -26, -8, 0, 0, -11, -22, -44, -58, 7, 15, 48, 102, 36, 21, 60, -4, 12, 19, 36, 16, -17, -45, 0, 0, 0, 0, 0, 0, 0, 0 };
const eg_pawn_table = [64]i32{ 0, 0, 0, 0, 0, 0, 0, 0, -19, -22, -13, -17, -20, -28, -43, -47, -27, -27, -29, -24, -27, -29, -46, -45, -19, -15, -31, -37, -33, -41, -35, -38, -9, -19, -20, -37, -32, -37, -31, -31, 4, -1, -8, -38, -26, -50, -26, -32, 107, 119, 106, 90, 77, 88, 112, 108, 0, 0, 0, 0, 0, 0, 0, 0 };

const mg_knight_table = [64]i32{ 4, 55, 24, 53, 56, 55, 48, -12, 46, 28, 60, 90, 86, 71, 63, 63, 35, 56, 86, 77, 94, 87, 92, 44, 61, 58, 84, 85, 97, 111, 84, 48, 71, 90, 73, 131, 103, 118, 83, 104, 9, 44, 77, 128, 140, 216, 106, 50, -63, -6, 111, 46, 138, 126, 44, 20, -308, -32, -24, -8, 93, -137, -142, -160 };
const eg_knight_table = [64]i32{ -42, -16, -5, 7, -12, -4, -23, -23, -30, -16, -19, -17, -15, -10, -17, -30, -17, -6, -12, 10, 7, -9, -24, -27, -11, 0, 13, 18, 16, -3, -17, 1, -13, -3, 18, 16, 10, 6, -7, -22, -19, -11, 15, 3, -18, -22, -26, -19, -1, -3, -29, -7, -38, -42, -20, -32, 46, -35, -10, -9, -31, 1, -5, -50 };

const mg_bishop_table = [64]i32{ 71, 53, 66, 58, 48, 40, 77, 62, 45, 89, 67, 67, 77, 89, 110, 61, 73, 78, 73, 64, 71, 81, 54, 67, 34, 40, 58, 72, 81, 48, 56, 15, -2, 34, 43, 69, 54, 23, 53, 36, 17, 33, 83, 39, 110, 103, 100, 79, -15, 14, -11, 16, 4, 94, 3, 68, -15, 5, -19, -48, -96, -34, 66, -53 };
const eg_bishop_table = [64]i32{ -33, -15, -15, -8, -3, 0, -34, -22, -13, -31, -21, -12, -12, -17, -25, -30, -27, -11, -7, 0, 2, -8, -15, -20, -13, -5, 0, 0, -1, 3, -15, -11, 11, 5, 4, 5, 4, 3, -12, -11, 5, 0, -9, 8, -12, -1, -11, -15, 0, 3, 3, -10, 1, -24, 2, -35, 0, -18, -6, 5, 6, 2, -21, 9 };

const mg_rook_table = [64]i32{ 19, 33, 53, 62, 73, 54, 8, 36, -7, 7, 13, 35, 47, 38, 65, -29, -9, 5, 12, 39, 37, 43, 66, 34, -16, -24, -13, 7, 7, 7, 49, 9, -12, 18, 29, 49, 29, 57, 80, 73, 16, 33, 17, 62, 69, 113, 141, 122, 8, -5, 32, 111, 36, 128, 136, 81, 15, 42, 43, 36, 70, 137, 99, 6 };
const eg_rook_table = [64]i32{ 9, 3, -1, -2, -12, -3, 7, -21, 6, 4, 9, 2, -5, -2, -9, 6, 5, 7, 4, -2, 0, -9, -17, -9, 14, 13, 16, 13, 12, 5, -10, -3, 14, 5, 9, 0, 2, -2, -11, -11, 12, 8, 9, -1, -5, -14, -16, -20, 14, 26, 16, -6, 5, -10, -11, -7, 23, 14, 14, 12, 4, -15, -6, 14 };

const mg_queen_table = [64]i32{ 173, 182, 183, 192, 193, 168, 118, 169, 155, 162, 169, 187, 192, 204, 193, 176, 136, 163, 149, 158, 156, 167, 163, 145, 137, 122, 138, 130, 145, 151, 154, 142, 97, 132, 120, 117, 124, 138, 137, 169, 112, 111, 145, 141, 185, 224, 277, 223, 98, 69, 73, 41, 69, 290, 159, 358, 77, 111, 155, 185, 204, 258, 82, 136 };
const eg_queen_table = [64]i32{ -27, -38, -26, -34, -28, -22, -1, -39, 0, 1, -9, -21, -20, -46, -45, -14, -14, -35, 27, 3, 23, 24, 38, 17, 0, 39, 26, 58, 46, 35, 36, 29, 12, 25, 34, 66, 80, 79, 57, 24, 1, 21, 34, 40, 69, 24, -19, -10, 30, 42, 61, 112, 86, 24, 62, -98, 33, 26, 18, 22, 6, -6, 41, 37 };

const mg_king_table = [64]i32{ -84, 38, 5, -98, -9, -48, 47, 27, 45, -38, -48, -108, -85, -62, 14, 14, 8, 31, -79, -106, -110, -65, -25, -52, 59, 38, 8, -87, -48, -76, -36, -87, 7, 20, 36, 2, -17, -12, 14, -34, 75, 177, 35, 70, 27, 93, 93, -12, 51, 129, 108, 97, 75, 131, 15, -26, 93, 82, 130, 84, 127, 97, 73, 56 };
const eg_king_table = [64]i32{ -27, -31, -12, 5, -14, 0, -36, -60, -36, 1, 17, 35, 32, 29, 5, -17, -31, -7, 25, 40, 44, 35, 18, 5, -44, -6, 16, 38, 37, 40, 22, 11, -24, 0, 15, 24, 27, 34, 25, 15, -25, -11, 10, 6, 18, 21, 23, 15, -29, -9, -9, -7, 0, 6, 23, 13, -62, -27, -33, -20, -24, -9, -9, -36 };

const mg_passed_score = [64]i32{ 0, 0, 0, 0, 0, 0, 0, 0, 0, -9, -1, -26, -7, 18, 81, -8, 4, 3, -1, -41, 1, 24, 34, 42, 30, 0, -15, -14, -22, -54, -87, 4, 33, 39, 33, 15, 8, 29, -2, -41, 79, 78, 2, -24, -37, -46, -71, -107, 60, -4, 12, 19, 36, 16, -17, -45, 0, 0, 0, 0, 0, 0, 0, 0 };
const eg_passed_score = [64]i32{ 0, 0, 0, 0, 0, 0, 0, 0, 7, 27, 5, -7, 14, 7, 11, 19, 18, 25, 11, 17, 13, 18, 31, 12, 38, 40, 35, 35, 32, 46, 66, 42, 72, 82, 58, 62, 50, 56, 80, 76, 147, 151, 141, 145, 116, 147, 152, 173, 107, 119, 106, 90, 77, 88, 112, 108, 0, 0, 0, 0, 0, 0, 0, 0 };

const mg_isolated_pawn_score = [8]i32{ -12, -14, -15, -24, -24, -20, -11, -12 };
const eg_isolated_pawn_score = [8]i32{ 0, -5, -5, -4, -1, -2, -7, 0 };

const mg_blocked_passer_score = [8]i32{ 0, -49, 0, 3, -9, 19, 45, 0 };
const eg_blocked_passer_score = [8]i32{ 0, 6, -17, -41, -59, -129, -165, 0 };

const mg_supported_pawn = [8]i32{ 0, 0, 22, 22, 28, 61, 495, 0 };
const eg_supported_pawn = [8]i32{ 0, 0, 14, 9, 17, 27, -97, 0 };

const mg_pawn_phalanx = [8]i32{ 0, 8, 21, 31, 62, 255, 122, 0 };
const eg_pawn_phalanx = [8]i32{ 0, -3, 4, 12, 42, 48, 384, 0 };

const mg_knigh_mobility = [9]i32{ 28, 72, 87, 97, 107, 113, 119, 121, 127 };
const eg_knigh_mobility = [9]i32{ -71, -38, -11, -3, -1, 7, 5, 5, -11 };

const mg_bishop_mobility = [14]i32{ 39, 57, 71, 82, 90, 95, 100, 107, 110, 122, 127, 152, 94, 205 };
const eg_bishop_mobility = [14]i32{ -51, -32, -21, -11, -2, 5, 12, 10, 18, 9, 13, 0, 32, -11 };

const mg_rook_mobility = [15]i32{ 5, 25, 30, 40, 41, 57, 67, 78, 86, 97, 105, 118, 128, 115, 180 };
const eg_rook_mobility = [15]i32{ -19, -14, -12, -12, -1, -2, -1, 1, 5, 7, 10, 13, 17, 23, 1 };

const mg_queen_mobility = [28]i32{ 253, 260, 267, 267, 275, 277, 280, 283, 289, 295, 297, 299, 304, 310, 315, 318, 304, 312, 323, 336, 338, 345, 351, 456, 351, 278, 214, 187 };
const eg_queen_mobility = [28]i32{ -35, -106, -83, -61, -61, -35, -25, -5, -1, 11, 15, 25, 23, 27, 28, 30, 54, 48, 50, 47, 46, 47, 32, -24, 31, 61, 89, 88 };

const mg_pawn_attacking = [6]i32{ 0, 43, 65, 53, 31, 0 };
const eg_pawn_attacking = [6]i32{ 0, -17, 18, -56, -34, 0 };

const mg_knight_attacking = [6]i32{ -14, 0, 15, 69, -3, 0 };
const eg_knight_attacking = [6]i32{ 9, 0, 31, -17, -11, 0 };

const mg_bishop_attacking = [6]i32{ -3, 19, 0, 31, 32, 0 };
const eg_bishop_attacking = [6]i32{ 10, 12, 0, -24, -1, 0 };

const mg_rook_attacking = [6]i32{ -17, 7, 20, 0, 62, 0 };
const eg_rook_attacking = [6]i32{ 16, 13, 8, 0, -63, 0 };

const mg_queen_attacking = [6]i32{ 3, 0, -2, 5, 0, 0 };
const eg_queen_attacking = [6]i32{ 0, 0, 28, -21, 0, 0 };

const mg_doubled_pawns = [1]i32{-4};
const eg_doubled_pawns = [1]i32{-9};

const mg_bishop_pair = [1]i32{48};
const eg_bishop_pair = [1]i32{44};

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

const phaseValues = [6]u8{ 0, 3, 3, 5, 10, 0 };

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
            midgame_table[Color.White.toU4()][piece][s_idx] = mg_pesto_table[piece][s_idx];
            endgame_table[Color.White.toU4()][piece][s_idx] = eg_pesto_table[piece][s_idx];
            midgame_table[Color.Black.toU4()][piece][s_idx] = mg_pesto_table[piece][s_idx^56];
            endgame_table[Color.Black.toU4()][piece][s_idx] = eg_pesto_table[piece][s_idx^56];         
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

    pub fn clean_eval(self: *Evaluation, pos: *Position) i32 { // TUNER OFF    
//    pub fn clean_eval(self: *Evaluation, pos: *Position, tnr: *tuner.Tuner) i32 { // TUNER ON
        var mat_white_mg: i32 = 0;
        var mat_white_eg: i32 = 0;
        var mat_black_mg: i32 = 0;
        var mat_black_eg: i32 = 0;

        var pos_white_mg: i32 = 0; 
        var pos_white_eg: i32 = 0;
        var pos_black_mg: i32 = 0; 
        var pos_black_eg: i32 = 0;

        var phase_white: u8 = 0;
        var phase_black: u8 = 0;

        for (Piece.WHITE_PAWN.toU4()..(Piece.WHITE_KING.toU4()+1)) |pc| {
            var b1 = pos.piece_bb[pc];
            var pc_count = bb.pop_count(b1);
            var pc_type_idx = pc;
            mat_white_mg += material_mg[pc_type_idx]*pc_count;
            mat_white_eg += material_eg[pc_type_idx]*pc_count;
            //tnr.mat[0][pc_type_idx] = @as(u8, @intCast(pc_count));

            while (b1 != 0) {
                var s_idx = bb.pop_lsb(&b1);
                pos_white_mg += midgame_table[Color.White.toU4()][pc_type_idx][s_idx];
                pos_white_eg += endgame_table[Color.White.toU4()][pc_type_idx][s_idx];
                //tnr.psqt[0][pc_type_idx][s_idx] += 1;
            }

            phase_white += phaseValues[pc_type_idx]*pc_count;

        }

        for (Piece.BLACK_PAWN.toU4()..(Piece.BLACK_KING.toU4()+1)) |pc| {
            var b1 = pos.piece_bb[pc];
            var pc_count = bb.pop_count(b1);
            var pc_type_idx = pc - 8;
            mat_black_mg += material_mg[pc_type_idx]*pc_count;
            mat_black_eg += material_eg[pc_type_idx]*pc_count;
            //tnr.mat[1][pc_type_idx] = @as(u8, @intCast(pc_count));

            while (b1 != 0) {
                var s_idx = bb.pop_lsb(&b1);
                pos_black_mg += midgame_table[Color.Black.toU4()][pc_type_idx][s_idx];
                pos_black_eg += endgame_table[Color.Black.toU4()][pc_type_idx][s_idx];
                //tnr.psqt[1][pc_type_idx][s_idx^56] += 1;
            }

            phase_black += phaseValues[pc_type_idx]*pc_count;            
        }

        self.eval_mg = mat_white_mg + pos_white_mg - mat_black_mg - pos_black_mg;
        self.eval_eg = mat_white_eg + pos_white_eg - mat_black_eg - pos_black_eg;
        self.phase[0] = phase_white;
        self.phase[1] = phase_black;

        var phase_bounded = @min(self.phase[Color.White.toU4()]+self.phase[Color.Black.toU4()], 64);

        var eval_mg = self.eval_mg;
        var eval_eg = self.eval_eg;   

//         var piece_scores = self.eval_pieces(pos, tnr); // TUNER ON
        var piece_scores = self.eval_pieces(pos); // TUNER OFF
        eval_mg += piece_scores[0];
        eval_eg += piece_scores[1];        

        var e: i32 = @divTrunc((eval_mg * phase_bounded + eval_eg * (64-phase_bounded)), 64);
        //const tempo = @divTrunc((mg_tempo * phase_bounded + eg_tempo * (64-phase_bounded)), 64);

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

        return e;// + tempo;             

    }    

    pub fn eval(self: *Evaluation, pos: *Position, comptime perspective_color: Color) i32 {

        var phase_bounded = @min(self.phase[Color.White.toU4()]+self.phase[Color.Black.toU4()], 64);
        const perspective = if (perspective_color == Color.White) @as(i32, 1) else @as(i32, -1);

        var eval_mg = self.eval_mg;
        var eval_eg = self.eval_eg;

        var pieces_score = self.eval_pieces(pos); // TUNER OFF
        eval_mg += pieces_score[0]; // TUNER OFF
        eval_eg += pieces_score[1]; // TUNER OFF

        var e: i32 = @divTrunc((eval_mg * phase_bounded + eval_eg * (64-phase_bounded)), 64);
        const tempo = @divTrunc((mg_tempo * phase_bounded + eg_tempo * (64-phase_bounded)), 64);

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

        return e * perspective + tempo;

    }

//fn eval_pieces(self: *Evaluation, pos: *Position, tnr: *tuner.Tuner) [2]i32 { // TUNER ON
fn eval_pieces(self: *Evaluation, pos: *Position) [2]i32 { // TUNER OFF    

        _ = self;

        var white_pawns = pos.piece_bb[Piece.WHITE_PAWN.toU4()];
        var white_knight = pos.piece_bb[Piece.WHITE_KNIGHT.toU4()];
        var white_bishop = pos.piece_bb[Piece.WHITE_BISHOP.toU4()];
        var white_rook = pos.piece_bb[Piece.WHITE_ROOK.toU4()];
        var white_queen = pos.piece_bb[Piece.WHITE_QUEEN.toU4()];
        var white_pieces = pos.all_white_pieces();
        var white_pawn_attacks = attacks.pawn_attacks_from_bitboard(pos.piece_bb[Piece.WHITE_PAWN.toU4()], Color.White);
        var white_att: u64 = 0;
        var white_king_sq = bb.get_ls1b_index(pos.piece_bb[Piece.WHITE_KING.toU4()]);
        var white_king_zone = KingArea[white_king_sq];
        var white_danger_score: i32 = 0;
        var white_danger_pieces: u5 = 0;

        var black_pawns = pos.piece_bb[Piece.BLACK_PAWN.toU4()];
        var black_knight = pos.piece_bb[Piece.BLACK_KNIGHT.toU4()];
        var black_bishop = pos.piece_bb[Piece.BLACK_BISHOP.toU4()];
        var black_rook = pos.piece_bb[Piece.BLACK_ROOK.toU4()];
        var black_queen = pos.piece_bb[Piece.BLACK_QUEEN.toU4()];  
        var black_pieces = pos.all_black_pieces();
        var black_pawn_attacks = attacks.pawn_attacks_from_bitboard(pos.piece_bb[Piece.BLACK_PAWN.toU4()], Color.Black);
        var black_att: u64 = 0;
        var black_king_sq = bb.get_ls1b_index(pos.piece_bb[Piece.BLACK_KING.toU4()]);
        var black_king_zone = KingArea[black_king_sq];
        var black_danger_score: i32 = 0;
        var black_danger_pieces: u5 = 0;

        var occ = white_pieces | black_pieces;

        var pawn_structure_score = [_]i32{0,0};
        var threat_score = [_]i32{0,0};
        var king_score = [_]i32{0,0};
        var additional_material_score= [_]i32{0,0};
        var score = [_]i32{0,0};
        var mobility_score = [_]i32{0,0};

        // Pawns
        var pc_bb = white_pawns;
        while (pc_bb != 0) {
            var sq = bb.pop_lsb(&pc_bb);
            var file = position.file_of_u6(sq);
            var rank = position.rank_of_u6(sq);

            // Get attacks & update king danger scores
            var att = attacks.WHITE_PAWN_ATTACKS[sq] & ~white_pieces;
            white_att |= att;
            if ((black_king_zone & att) != 0) {
                black_danger_score += PieceDangers[PieceType.Pawn.toU3()];
                black_danger_pieces += 1;
            }

            // Isolated pawn evaluation
            if (pos.piece_bb[Piece.WHITE_PAWN.toU4()] & IsolatedPawnMask[file] == 0) {
                var tmp_sc = get_isolated_pawn_score(file);
                //tnr.isolated_pawn[0][file] += 1;
                pawn_structure_score[0] += tmp_sc[0];
                pawn_structure_score[1] += tmp_sc[1];
            }

            // Passed pawn evaluation
            if (((WhitePassedPawnMask[sq] & pos.piece_bb[Piece.BLACK_PAWN.toU4()]) == 0) and ((WhitePassedPawnFilter[sq] & pos.piece_bb[Piece.WHITE_PAWN.toU4()]) == 0)) {
                var tmp_sc = get_passed_pawn_score(sq);
                //var tmp_sc = get_passed_pawn_score_f(file);
                //tnr.passed_pawn[0][sq] += 1;

                pawn_structure_score[0] += tmp_sc[0];
                pawn_structure_score[1] += tmp_sc[1];
                if ((bb.SQUARE_BB[sq+8] & black_pieces) != 0) {
                    tmp_sc = get_blocked_passer_score(rank);
                    //tnr.blocked_passer[0][rank] += 1;
                    pawn_structure_score[0] += tmp_sc[0];
                    pawn_structure_score[1] += tmp_sc[1];
                }
            }

            // Threats
            var b1 = att & pos.piece_bb[Piece.BLACK_KNIGHT.toU4()];
            if (b1 != 0) {
                var tmp_sc = get_pawn_threat(PieceType.Knight);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count;
                //tnr.pawn_attacking[0][PieceType.Knight.toU3()] += tmp_count;
            }
            b1 = att & pos.piece_bb[Piece.BLACK_BISHOP.toU4()];
            if (b1 != 0) {
                var tmp_sc = get_pawn_threat(PieceType.Bishop);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count;    
                //tnr.pawn_attacking[0][PieceType.Bishop.toU3()] += tmp_count;            
            }     
            b1 = att & pos.piece_bb[Piece.BLACK_ROOK.toU4()];
            if (b1 != 0) {
                var tmp_sc = get_pawn_threat(PieceType.Rook);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count;
                //tnr.pawn_attacking[0][PieceType.Rook.toU3()] += tmp_count;                  
            }         
            b1 = att & pos.piece_bb[Piece.BLACK_QUEEN.toU4()];
            if (b1 != 0) {
                var tmp_sc = get_pawn_threat(PieceType.Queen);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count;
                //tnr.pawn_attacking[0][PieceType.Queen.toU3()] += tmp_count;                  
            }                      

            // Pawn is supported?
            if (white_pawn_attacks & bb.SQUARE_BB[sq] != 0) {
                var tmp_sc = get_supported_pawn_bonus(rank);
                //tnr.supported_pawn[0][rank] += 1;
                pawn_structure_score[0] += tmp_sc[0];
                pawn_structure_score[1] += tmp_sc[1];
            }

            // Pawn phalanx
            if ((file != 7) and (pos.board[sq+1] == Piece.WHITE_PAWN)) {
                var tmp_sc = get_phalanx_score(rank);
                //tnr.pawn_phalanx[0][rank] += 1;
                pawn_structure_score[0] += tmp_sc[0];
                pawn_structure_score[1] += tmp_sc[1];                
            }

        }

        pc_bb = black_pawns;
        while (pc_bb != 0) {
            var sq = bb.pop_lsb(&pc_bb);
            var file = position.file_of_u6(sq);
            var rank = position.rank_of_u6(sq);

            // Get attacks & update king danger scores
            var att = attacks.BLACK_PAWN_ATTACKS[sq] & ~black_pieces;
            black_att |= att;
            if ((white_king_zone & att) != 0) {
                white_danger_score += PieceDangers[PieceType.Pawn.toU3()];
                white_danger_pieces += 1;
            }

            // Isolated pawn evaluation
            if (pos.piece_bb[Piece.BLACK_PAWN.toU4()] & IsolatedPawnMask[file] == 0) {
                var tmp_sc = get_isolated_pawn_score(7-file);
                //tnr.isolated_pawn[1][7-file] += 1;
                pawn_structure_score[0] -= tmp_sc[0];
                pawn_structure_score[1] -= tmp_sc[1];                
            }

            // Passed pawn evaluation
            if (((BlackPassedPawnMask[sq] & pos.piece_bb[Piece.WHITE_PAWN.toU4()]) == 0) and ((BlackPassedPawnFilter[sq] & pos.piece_bb[Piece.BLACK_PAWN.toU4()]) == 0)) {
                var tmp_sc = get_passed_pawn_score(sq^56);
                //var tmp_sc = get_passed_pawn_score_f(7-file);
                //tnr.passed_pawn[1][sq^56] += 1;

                pawn_structure_score[0] -= tmp_sc[0];
                pawn_structure_score[1] -= tmp_sc[1];                
                if ((bb.SQUARE_BB[sq-8] & white_pieces) != 0) {
                    tmp_sc = get_blocked_passer_score(7-rank);
                    //tnr.blocked_passer[1][7-rank] += 1;
                    pawn_structure_score[0] -= tmp_sc[0];
                    pawn_structure_score[1] -= tmp_sc[1];                    
                }
            }

            // Threats
            var b1 = att & pos.piece_bb[Piece.WHITE_KNIGHT.toU4()];
            if (b1 != 0) {
                var tmp_sc = get_pawn_threat(PieceType.Knight);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count;  
                //tnr.pawn_attacking[1][PieceType.Knight.toU3()] += tmp_count;              
            }
            b1 = att & pos.piece_bb[Piece.WHITE_BISHOP.toU4()];
            if (b1 != 0) {
                var tmp_sc = get_pawn_threat(PieceType.Bishop);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count;   
                //tnr.pawn_attacking[1][PieceType.Bishop.toU3()] += tmp_count;              
            }     
            b1 = att & pos.piece_bb[Piece.WHITE_ROOK.toU4()];
            if (b1 != 0) {
                var tmp_sc = get_pawn_threat(PieceType.Rook);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                //tnr.pawn_attacking[1][PieceType.Rook.toU3()] += tmp_count;                
            }         
            b1 = att & pos.piece_bb[Piece.WHITE_QUEEN.toU4()];
            if (b1 != 0) {
                var tmp_sc = get_pawn_threat(PieceType.Queen);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                //tnr.pawn_attacking[1][PieceType.Queen.toU3()] += tmp_count;                
            }                      

            // Pawn is supported?
            if ((black_pawn_attacks & bb.SQUARE_BB[sq]) != 0) {
                var tmp_sc = get_supported_pawn_bonus(7-rank);
                //tnr.supported_pawn[1][7-rank] += 1;
                pawn_structure_score[0] -= tmp_sc[0];
                pawn_structure_score[1] -= tmp_sc[1];            
            }

            // Pawn phalanx
            if ((file != 7) and (pos.board[sq+1] == Piece.BLACK_PAWN)) {
                var tmp_sc = get_phalanx_score(7-rank);
                //tnr.pawn_phalanx[1][7-rank] += 1;
                pawn_structure_score[0] -= tmp_sc[0];
                pawn_structure_score[1] -= tmp_sc[1];                   
            }

        }   

        // Knights
        pc_bb = white_knight;
        while (pc_bb != 0) {
            var sq = bb.pop_lsb(&pc_bb);
            var att = attacks.KNIGHT_ATTACKS[sq];
            var mobility = att & ~white_pieces;
            white_att |= mobility;
            var index = bb.pop_count(mobility & ~black_pawn_attacks);
            var tmp_sc = get_knight_mobility_score(index);
            //tnr.knight_mobility[0][index] += 1;
            mobility_score[0] += tmp_sc[0];
            mobility_score[1] += tmp_sc[1];
            if ((black_king_zone & mobility) != 0) {
                black_danger_score += PieceDangers[PieceType.Knight.toU3()];
                black_danger_pieces += 1;
            }

            var b1 = mobility & black_pawns;
            if (b1 != 0) {
                var pt = PieceType.Pawn;
                tmp_sc = get_knight_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                //tnr.knight_attacking[0][pt.toU3()] += tmp_count;               
            }

            b1 = mobility & black_bishop;
            if (b1 != 0) {
                var pt = PieceType.Bishop;
                tmp_sc = get_knight_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                //tnr.knight_attacking[0][pt.toU3()] += tmp_count;               
            }    

            b1 = mobility & black_rook;
            if (b1 != 0) {
                var pt = PieceType.Rook;
                tmp_sc = get_knight_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                //tnr.knight_attacking[0][pt.toU3()] += tmp_count;               
            }      

            b1 = mobility & black_queen;
            if (b1 != 0) {
                var pt = PieceType.Queen;
                tmp_sc = get_knight_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                //tnr.knight_attacking[0][pt.toU3()] += tmp_count;               
            }                                

        }

        pc_bb = black_knight;
        while (pc_bb != 0) {
            var sq = bb.pop_lsb(&pc_bb);
            var att = attacks.KNIGHT_ATTACKS[sq];
            var mobility = att & ~black_pieces;
            black_att |= mobility;
            var index = bb.pop_count(mobility & ~white_pawn_attacks);
            var tmp_sc = get_knight_mobility_score(index);
            //tnr.knight_mobility[1][index] += 1;
            mobility_score[0] -= tmp_sc[0];
            mobility_score[1] -= tmp_sc[1];
            if ((white_king_zone & mobility) != 0) {
                white_danger_score += PieceDangers[PieceType.Knight.toU3()];
                white_danger_pieces += 1;
            }
                      
            var b1 = mobility & white_pawns;
            if (b1 != 0) {
                var pt = PieceType.Pawn;
                tmp_sc = get_knight_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                //tnr.knight_attacking[1][pt.toU3()] += tmp_count;               
            }

            b1 = mobility & white_bishop;
            if (b1 != 0) {
                var pt = PieceType.Bishop;
                tmp_sc = get_knight_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                //tnr.knight_attacking[1][pt.toU3()] += tmp_count;               
            }    

            b1 = mobility & white_rook;
            if (b1 != 0) {
                var pt = PieceType.Rook;
                tmp_sc = get_knight_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                //tnr.knight_attacking[1][pt.toU3()] += tmp_count;               
            }      

            b1 = mobility & white_queen;
            if (b1 != 0) {
                var pt = PieceType.Queen;
                tmp_sc = get_knight_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                //tnr.knight_attacking[1][pt.toU3()] += tmp_count;               
            }                                

        }

        pc_bb = white_bishop;
        while (pc_bb != 0) {
            var sq = bb.pop_lsb(&pc_bb);
            var att = attacks.get_bishop_attacks(sq, occ);
            var mobility = att & ~white_pieces;
            white_att |= mobility;
            var index = bb.pop_count(mobility & ~black_pawn_attacks);
            var tmp_sc = get_bishop_mobility_score(index);
            //tnr.bishop_mobility[0][index] += 1;
            mobility_score[0] += tmp_sc[0];
            mobility_score[1] += tmp_sc[1];
            if ((black_king_zone & mobility) != 0) {
                black_danger_score += PieceDangers[PieceType.Bishop.toU3()];
                black_danger_pieces += 1;
            }
            
            var b1 = mobility & black_pawns;
            if (b1 != 0) {
                var pt = PieceType.Pawn;
                tmp_sc = get_bishop_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                //tnr.bishop_attacking[0][pt.toU3()] += tmp_count;               
            }

            b1 = mobility & black_knight;
            if (b1 != 0) {
                var pt = PieceType.Knight;
                tmp_sc = get_bishop_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                //tnr.bishop_attacking[0][pt.toU3()] += tmp_count;               
            }    

            b1 = mobility & black_rook;
            if (b1 != 0) {
                var pt = PieceType.Rook;
                tmp_sc = get_bishop_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                //tnr.bishop_attacking[0][pt.toU3()] += tmp_count;               
            }      

            b1 = mobility & black_queen;
            if (b1 != 0) {
                var pt = PieceType.Queen;
                tmp_sc = get_bishop_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                //tnr.bishop_attacking[0][pt.toU3()] += tmp_count;               
            }   
        }    

        pc_bb = black_bishop;
        while (pc_bb != 0) {
            var sq = bb.pop_lsb(&pc_bb);
            var att = attacks.get_bishop_attacks(sq, occ);
            var mobility = att & ~black_pieces;
            black_att |= mobility;
            var index = bb.pop_count(mobility & ~white_pawn_attacks);
            var tmp_sc = get_bishop_mobility_score(index);
            //tnr.bishop_mobility[1][index] += 1;
            mobility_score[0] -= tmp_sc[0];
            mobility_score[1] -= tmp_sc[1];
            if ((white_king_zone & mobility) != 0) {
                white_danger_score += PieceDangers[PieceType.Bishop.toU3()];
                white_danger_pieces += 1;
            }
            
            var b1 = mobility & white_pawns;
            if (b1 != 0) {
                var pt = PieceType.Pawn;
                tmp_sc = get_bishop_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                //tnr.bishop_attacking[1][pt.toU3()] += tmp_count;               
            }

            b1 = mobility & white_knight;
            if (b1 != 0) {
                var pt = PieceType.Knight;
                tmp_sc = get_bishop_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                //tnr.bishop_attacking[1][pt.toU3()] += tmp_count;               
            }    

            b1 = mobility & white_rook;
            if (b1 != 0) {
                var pt = PieceType.Rook;
                tmp_sc = get_bishop_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                //tnr.bishop_attacking[1][pt.toU3()] += tmp_count;               
            }      

            b1 = mobility & white_queen;
            if (b1 != 0) {
                var pt = PieceType.Queen;
                tmp_sc = get_bishop_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                //tnr.bishop_attacking[1][pt.toU3()] += tmp_count;               
            }             

        }         

        pc_bb = white_rook;
        while (pc_bb != 0) {
            var sq = bb.pop_lsb(&pc_bb);
            // var file = position.file_of_u6(sq);
            // var mask_file = bb.MASK_FILE[file];            
            var att = attacks.get_rook_attacks(sq, occ);
            var mobility = att & ~white_pieces;
            white_att |= mobility;
            var index = bb.pop_count(mobility & ~black_pawn_attacks);
            var tmp_sc = get_rook_mobility_score(index);
            //tnr.rook_mobility[0][index] += 1;
            mobility_score[0] += tmp_sc[0];
            mobility_score[1] += tmp_sc[1];

            if ((black_king_zone & mobility) != 0) {
                black_danger_score += PieceDangers[PieceType.Rook.toU3()];
                black_danger_pieces += 1;
            }
            
            var b1 = mobility & black_pawns;
            if (b1 != 0) {
                var pt = PieceType.Pawn;
                tmp_sc = get_rook_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                //tnr.rook_attacking[0][pt.toU3()] += tmp_count;               
            }

            b1 = mobility & black_knight;
            if (b1 != 0) {
                var pt = PieceType.Knight;
                tmp_sc = get_rook_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                //tnr.rook_attacking[0][pt.toU3()] += tmp_count;               
            }    

            b1 = mobility & black_bishop;
            if (b1 != 0) {
                var pt = PieceType.Bishop;
                tmp_sc = get_rook_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                //tnr.rook_attacking[0][pt.toU3()] += tmp_count;               
            }      

            b1 = mobility & black_queen;
            if (b1 != 0) {
                var pt = PieceType.Queen;
                tmp_sc = get_rook_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                //tnr.rook_attacking[0][pt.toU3()] += tmp_count;               
            }             

        }   

        pc_bb = black_rook;
        while (pc_bb != 0) {
            var sq = bb.pop_lsb(&pc_bb);
            // var file = position.file_of_u6(sq);
            // var mask_file = bb.MASK_FILE[file];            
            var att = attacks.get_rook_attacks(sq, occ);
            var mobility = att & ~black_pieces;
            black_att |= mobility;
            var index = bb.pop_count(mobility & ~white_pawn_attacks);
            var tmp_sc = get_rook_mobility_score(index);
            //tnr.rook_mobility[1][index] += 1;
            mobility_score[0] -= tmp_sc[0];
            mobility_score[1] -= tmp_sc[1];

            if ((white_king_zone & mobility) != 0) {
                white_danger_score += PieceDangers[PieceType.Rook.toU3()];
                white_danger_pieces += 1;
            }
            
            var b1 = mobility & white_pawns;
            if (b1 != 0) {
                var pt = PieceType.Pawn;
                tmp_sc = get_rook_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                //tnr.rook_attacking[1][pt.toU3()] += tmp_count;               
            }

            b1 = mobility & white_knight;
            if (b1 != 0) {
                var pt = PieceType.Knight;
                tmp_sc = get_rook_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                //tnr.rook_attacking[1][pt.toU3()] += tmp_count;               
            }    

            b1 = mobility & white_bishop;
            if (b1 != 0) {
                var pt = PieceType.Bishop;
                tmp_sc = get_rook_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                //tnr.rook_attacking[1][pt.toU3()] += tmp_count;               
            }      

            b1 = mobility & white_queen;
            if (b1 != 0) {
                var pt = PieceType.Queen;
                tmp_sc = get_rook_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                //tnr.rook_attacking[1][pt.toU3()] += tmp_count;               
            }  

        }    

        pc_bb = white_queen;
        while (pc_bb != 0) {
            var sq = bb.pop_lsb(&pc_bb);
            var att = attacks.get_bishop_attacks(sq, occ) | attacks.get_rook_attacks(sq, occ);
            var mobility = att & ~white_pieces;
            white_att |= mobility;
            var index = bb.pop_count(mobility & ~black_pawn_attacks);
            var tmp_sc = get_queen_mobility_score(index);
            //tnr.queen_mobility[0][index] += 1;
            mobility_score[0] += tmp_sc[0];
            mobility_score[1] += tmp_sc[1];
            if ((black_king_zone & mobility) != 0) {
                black_danger_score += PieceDangers[PieceType.Queen.toU3()];
                black_danger_pieces += 1;
            }

            var b1 = mobility & black_pawns;
            if (b1 != 0) {
                var pt = PieceType.Pawn;
                tmp_sc = get_queen_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                //tnr.queen_attacking[0][pt.toU3()] += tmp_count;               
            }

            b1 = mobility & black_knight;
            if (b1 != 0) {
                var pt = PieceType.Knight;
                tmp_sc = get_queen_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                //tnr.queen_attacking[0][pt.toU3()] += tmp_count;               
            }    

            b1 = mobility & black_bishop;
            if (b1 != 0) {
                var pt = PieceType.Bishop;
                tmp_sc = get_queen_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                //tnr.queen_attacking[0][pt.toU3()] += tmp_count;               
            }      

            b1 = mobility & black_rook;
            if (b1 != 0) {
                var pt = PieceType.Rook;
                tmp_sc = get_queen_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                //tnr.queen_attacking[0][pt.toU3()] += tmp_count;               
            }                

        }  

        pc_bb = black_queen;
        while (pc_bb != 0) {
            var sq = bb.pop_lsb(&pc_bb);
            var att = attacks.get_bishop_attacks(sq, occ) | attacks.get_rook_attacks(sq, occ);
            var mobility = att & ~black_pieces;
            black_att |= mobility;
            var index = bb.pop_count(mobility & ~white_pawn_attacks);
            var tmp_sc = get_queen_mobility_score(index);
            //tnr.queen_mobility[1][index] += 1;
            mobility_score[0] -= tmp_sc[0];
            mobility_score[1] -= tmp_sc[1];
            if ((white_king_zone & mobility) != 0) {
                white_danger_score += PieceDangers[PieceType.Queen.toU3()];
                white_danger_pieces += 1;
            }

            var b1 = mobility & black_pawns;
            if (b1 != 0) {
                var pt = PieceType.Pawn;
                tmp_sc = get_queen_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                //tnr.queen_attacking[0][pt.toU3()] += tmp_count;               
            }

            b1 = mobility & black_knight;
            if (b1 != 0) {
                var pt = PieceType.Knight;
                tmp_sc = get_queen_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                //tnr.queen_attacking[0][pt.toU3()] += tmp_count;               
            }    

            b1 = mobility & black_bishop;
            if (b1 != 0) {
                var pt = PieceType.Bishop;
                tmp_sc = get_queen_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                //tnr.queen_attacking[0][pt.toU3()] += tmp_count;               
            }      

            b1 = mobility & black_rook;
            if (b1 != 0) {
                var pt = PieceType.Rook;
                tmp_sc = get_queen_threat(pt);
                var tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                //tnr.queen_attacking[0][pt.toU3()] += tmp_count;               
            }              

        }                              

        // King safety
        const white_king_safety_final = @divTrunc(white_danger_score * DangerMultipliers[@min(white_danger_pieces, 7)], 100);
        const black_king_safety_final = @divTrunc(black_danger_score * DangerMultipliers[@min(black_danger_pieces, 7)], 100);
        if (white_king_safety_final != 0 ) {
            var tmp_sc = king_safety[@min(@as(usize, @intCast(white_king_safety_final)), 24)];
            king_score[0] += tmp_sc;
            king_score[1] += tmp_sc;
        }
        if (black_king_safety_final != 0 ) {
            var tmp_sc = king_safety[@min(@as(usize, @intCast(black_king_safety_final)), 24)];
            king_score[0] -= tmp_sc;
            king_score[1] -= tmp_sc;
        }

        // Bishop pair bonus
        const bb_white_bishops = pos.piece_bb[Piece.WHITE_BISHOP.toU4()];
        if (bb.pop_count(bb_white_bishops) >= 2) {
            if ((bb_white_bishops & bb.WHITE_FIELDS != 0) and (bb_white_bishops & bb.BLACK_FIELDS != 0)) {
                additional_material_score[0] += mg_bishop_pair[0];
                additional_material_score[1] += eg_bishop_pair[0];
                //tnr.bishop_pair[0] += 1;
            }
        }
        const bb_black_bishops = pos.piece_bb[Piece.BLACK_BISHOP.toU4()];
        if (bb.pop_count(bb_black_bishops) >= 2) {
            if ((bb_black_bishops & bb.WHITE_FIELDS != 0) and (bb_black_bishops & bb.BLACK_FIELDS != 0)) {
                additional_material_score[0] -= mg_bishop_pair[0];
                additional_material_score[1] -= eg_bishop_pair[0];
                //tnr.bishop_pair[1] += 1;
            }
        }    

        for (0..8) |i| {
            const white_pawns_on_file = bb.pop_count(pos.piece_bb[Piece.WHITE_PAWN.toU4()] & bb.MASK_FILE[i]);
            const black_pawns_on_file = bb.pop_count(pos.piece_bb[Piece.BLACK_PAWN.toU4()] & bb.MASK_FILE[i]);            

            if (white_pawns_on_file >= 2) {
                pawn_structure_score[0] += mg_doubled_pawns[0];
                pawn_structure_score[1] += eg_doubled_pawns[0];
                //tnr.doubled_pawns[0] += 1; 
            } 
            if (black_pawns_on_file >= 2) {
                pawn_structure_score[0] -= mg_doubled_pawns[0];
                pawn_structure_score[1] -= eg_doubled_pawns[0];
                //tnr.doubled_pawns[1] += 1;
            } 

        }

        score[0] = pawn_structure_score[0] + threat_score[0] + king_score[0] + additional_material_score[0] + mobility_score[0];
        score[1] = pawn_structure_score[1] + threat_score[1] + king_score[1] + additional_material_score[1] + mobility_score[1];
    
        return score;
    
    }


};


pub const WhitePassedPawnMask = [_]u64{
    0x0303030303030300, 0x0707070707070700, 0x0e0e0e0e0e0e0e00, 0x1c1c1c1c1c1c1c00, 0x3838383838383800, 0x7070707070707000, 0xe0e0e0e0e0e0e000, 0xc0c0c0c0c0c0c000,
    0x0303030303030000, 0x0707070707070000, 0x0e0e0e0e0e0e0000, 0x1c1c1c1c1c1c0000, 0x3838383838380000, 0x7070707070700000, 0xe0e0e0e0e0e00000, 0xc0c0c0c0c0c00000,
    0x0303030303000000, 0x0707070707000000, 0x0e0e0e0e0e000000, 0x1c1c1c1c1c000000, 0x3838383838000000, 0x7070707070000000, 0xe0e0e0e0e0000000, 0xc0c0c0c0c0000000,
    0x0303030300000000, 0x0707070700000000, 0x0e0e0e0e00000000, 0x1c1c1c1c00000000, 0x3838383800000000, 0x7070707000000000, 0xe0e0e0e000000000, 0xc0c0c0c000000000,
    0x0303030000000000, 0x0707070000000000, 0x0e0e0e0000000000, 0x1c1c1c0000000000, 0x3838380000000000, 0x7070700000000000, 0xe0e0e00000000000, 0xc0c0c00000000000,
    0x0303000000000000, 0x0707000000000000, 0x0e0e000000000000, 0x1c1c000000000000, 0x3838000000000000, 0x7070000000000000, 0xe0e0000000000000, 0xc0c0000000000000,
    0x0300000000000000, 0x0700000000000000, 0x0e00000000000000, 0x1c00000000000000, 0x3800000000000000, 0x7000000000000000, 0xe000000000000000, 0xc000000000000000,
    0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000,
};

pub const BlackPassedPawnMask = [_]u64{
    0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000,
    0x0000000000000003, 0x0000000000000007, 0x000000000000000e, 0x000000000000001c, 0x0000000000000038, 0x0000000000000070, 0x00000000000000e0, 0x00000000000000c0,
    0x0000000000000303, 0x0000000000000707, 0x0000000000000e0e, 0x0000000000001c1c, 0x0000000000003838, 0x0000000000007070, 0x000000000000e0e0, 0x000000000000c0c0,
    0x0000000000030303, 0x0000000000070707, 0x00000000000e0e0e, 0x00000000001c1c1c, 0x0000000000383838, 0x0000000000707070, 0x0000000000e0e0e0, 0x0000000000c0c0c0,
    0x0000000003030303, 0x0000000007070707, 0x000000000e0e0e0e, 0x000000001c1c1c1c, 0x0000000038383838, 0x0000000070707070, 0x00000000e0e0e0e0, 0x00000000c0c0c0c0,
    0x0000000303030303, 0x0000000707070707, 0x0000000e0e0e0e0e, 0x0000001c1c1c1c1c, 0x0000003838383838, 0x0000007070707070, 0x000000e0e0e0e0e0, 0x000000c0c0c0c0c0,
    0x0000030303030303, 0x0000070707070707, 0x00000e0e0e0e0e0e, 0x00001c1c1c1c1c1c, 0x0000383838383838, 0x0000707070707070, 0x0000e0e0e0e0e0e0, 0x0000c0c0c0c0c0c0,
    0x0003030303030303, 0x0007070707070707, 0x000e0e0e0e0e0e0e, 0x001c1c1c1c1c1c1c, 0x0038383838383838, 0x0070707070707070, 0x00e0e0e0e0e0e0e0, 0x00c0c0c0c0c0c0c0,
};

pub const WhitePassedPawnFilter = [_]u64{
    0x0101010101010100, 0x0202020202020200, 0x0404040404040400, 0x0808080808080800, 0x1010101010101000, 0x2020202020202000, 0x4040404040404000, 0x8080808080808000,
    0x0101010101010000, 0x0202020202020000, 0x0404040404040000, 0x0808080808080000, 0x1010101010100000, 0x2020202020200000, 0x4040404040400000, 0x8080808080800000,
    0x0101010101000000, 0x0202020202000000, 0x0404040404000000, 0x0808080808000000, 0x1010101010000000, 0x2020202020000000, 0x4040404040000000, 0x8080808080000000,
    0x0101010100000000, 0x0202020200000000, 0x0404040400000000, 0x0808080800000000, 0x1010101000000000, 0x2020202000000000, 0x4040404000000000, 0x8080808000000000,
    0x0101010000000000, 0x0202020000000000, 0x0404040000000000, 0x0808080000000000, 0x1010100000000000, 0x2020200000000000, 0x4040400000000000, 0x8080800000000000,
    0x0101000000000000, 0x0202000000000000, 0x0404000000000000, 0x0808000000000000, 0x1010000000000000, 0x2020000000000000, 0x4040000000000000, 0x8080000000000000,
    0x0100000000000000, 0x0200000000000000, 0x0400000000000000, 0x0800000000000000, 0x1000000000000000, 0x2000000000000000, 0x4000000000000000, 0x8000000000000000,
    0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000,
};

pub const BlackPassedPawnFilter = [_]u64{
    0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000,
    0x0000000000000001, 0x0000000000000002, 0x0000000000000004, 0x0000000000000008, 0x0000000000000010, 0x0000000000000020, 0x0000000000000040, 0x0000000000000080,
    0x0000000000000101, 0x0000000000000202, 0x0000000000000404, 0x0000000000000808, 0x0000000000001010, 0x0000000000002020, 0x0000000000004040, 0x0000000000008080,
    0x0000000000010101, 0x0000000000020202, 0x0000000000040404, 0x0000000000080808, 0x0000000000101010, 0x0000000000202020, 0x0000000000404040, 0x0000000000808080,
    0x0000000001010101, 0x0000000002020202, 0x0000000004040404, 0x0000000008080808, 0x0000000010101010, 0x0000000020202020, 0x0000000040404040, 0x0000000080808080,
    0x0000000101010101, 0x0000000202020202, 0x0000000404040404, 0x0000000808080808, 0x0000001010101010, 0x0000002020202020, 0x0000004040404040, 0x0000008080808080,
    0x0000010101010101, 0x0000020202020202, 0x0000040404040404, 0x0000080808080808, 0x0000101010101010, 0x0000202020202020, 0x0000404040404040, 0x0000808080808080,
    0x0001010101010101, 0x0002020202020202, 0x0004040404040404, 0x0008080808080808, 0x0010101010101010, 0x0020202020202020, 0x0040404040404040, 0x0080808080808080,
};

pub const KingArea = [_]u64{
    0x0000000000000303, 0x0000000000000707, 0x0000000000000e0e, 0x0000000000001c1c, 0x0000000000003838, 0x0000000000007070, 0x000000000000e0e0, 0x000000000000c0c0,
    0x0000000000030303, 0x0000000000070707, 0x00000000000e0e0e, 0x00000000001c1c1c, 0x0000000000383838, 0x0000000000707070, 0x0000000000e0e0e0, 0x0000000000c0c0c0,
    0x0000000003030300, 0x0000000007070700, 0x000000000e0e0e00, 0x000000001c1c1c00, 0x0000000038383800, 0x0000000070707000, 0x00000000e0e0e000, 0x00000000c0c0c000,
    0x0000000303030000, 0x0000000707070000, 0x0000000e0e0e0000, 0x0000001c1c1c0000, 0x0000003838380000, 0x0000007070700000, 0x000000e0e0e00000, 0x000000c0c0c00000,
    0x0000030303000000, 0x0000070707000000, 0x00000e0e0e000000, 0x00001c1c1c000000, 0x0000383838000000, 0x0000707070000000, 0x0000e0e0e0000000, 0x0000c0c0c0000000,
    0x0003030300000000, 0x0007070700000000, 0x000e0e0e00000000, 0x001c1c1c00000000, 0x0038383800000000, 0x0070707000000000, 0x00e0e0e000000000, 0x00c0c0c000000000,
    0x0303030000000000, 0x0707070000000000, 0x0e0e0e0000000000, 0x1c1c1c0000000000, 0x3838380000000000, 0x7070700000000000, 0xe0e0e00000000000, 0xc0c0c00000000000,
    0x0303000000000000, 0x0707000000000000, 0x0e0e000000000000, 0x1c1c000000000000, 0x3838000000000000, 0x7070000000000000, 0xe0e0000000000000, 0xc0c0000000000000,
};

pub const IsolatedPawnMask = [_]u64{
    0x0202020202020202, 0x0505050505050505, 0x0a0a0a0a0a0a0a0a, 0x1414141414141414, 0x2828282828282828, 0x5050505050505050, 0xa0a0a0a0a0a0a0a0, 0x4040404040404040,
};

pub const Outpost = [_]bool{
    false, false, false, false, false, false, false, false,
    false, false, false, false, false, false, false, false,
    false, false, false, false, false, false, false, false,
    false, false, true,  true,  true,  true,  false, false,
    false, false, true,  true,  true,  true,  false, false,
    false, false, false, false, false, false, false, false,
    false, false, false, false, false, false, false, false,
    false, false, false, false, false, false, false, false,
};

pub const DangerMultipliers = [_]i32{ 0, 50, 70, 80, 90, 95, 98, 100 };
pub const PieceDangers = [_]i32{ 1, 2, 2, 3, 5, 4 };

pub const rook_file_open = [2][2]i32{
    [_]i32{ 29, 13 },
    [_]i32{ 12, 9 },
};

pub const pawn_attacking_major_minor_pieces = [2][2]i32{
    [_]i32{ 51, 56 },
    [_]i32{ 28, 32 },
};

pub const king_safety = [25]i32{
    -5, -5, -20, -25, -36, -56, -72, -90, -133, -190, -222, -252, -255, -178, -322, -332, -350, -370, -400, -422, -425, -430, -435, -440, -445,
};

pub inline fn get_passed_pawn_score(sq: u6) [2]i32 {
    var score = [_]i32{ 0, 0 };
    score[0] = mg_passed_score[sq];
    score[1] = eg_passed_score[sq];
    return score;
}

// pub inline fn get_passed_pawn_score_f(file: u6) [2]i32 {
//     var score = [_]i32{ 0, 0 };
//     score[0] = mg_passed_score[file];
//     score[1] = eg_passed_score[file];
//     return score;
// }

pub inline fn get_isolated_pawn_score(file: u6) [2]i32 {
    var score = [_]i32{ 0, 0 };
    score[0] += mg_isolated_pawn_score[file];
    score[1] += eg_isolated_pawn_score[file];
    return score;
}

pub inline fn get_blocked_passer_score(rank: u6) [2]i32 {
    var score = [_]i32{ 0, 0 };
    score[0] = mg_blocked_passer_score[rank];
    score[1] = eg_blocked_passer_score[rank];
    return score;
}

pub inline fn get_pawn_threat(piece_type: PieceType) [2]i32 {
    var score = [_]i32{ 0, 0 };
    var pt = piece_type.toU3();
    score[0] = mg_pawn_attacking[pt];
    score[1] = eg_pawn_attacking[pt];
    return score;
}

pub inline fn get_knight_threat(piece_type: PieceType) [2]i32 {
    var score = [_]i32{ 0, 0 };
    var pt = piece_type.toU3();
    score[0] = mg_knight_attacking[pt];
    score[1] = eg_knight_attacking[pt];
    return score;
}

pub inline fn get_bishop_threat(piece_type: PieceType) [2]i32 {
    var score = [_]i32{ 0, 0 };
    var pt = piece_type.toU3();
    score[0] = mg_bishop_attacking[pt];
    score[1] = eg_bishop_attacking[pt];
    return score;
}

pub inline fn get_rook_threat(piece_type: PieceType) [2]i32 {
    var score = [_]i32{ 0, 0 };
    var pt = piece_type.toU3();
    score[0] = mg_rook_attacking[pt];
    score[1] = eg_rook_attacking[pt];
    return score;
}

pub inline fn get_queen_threat(piece_type: PieceType) [2]i32 {
    var score = [_]i32{ 0, 0 };
    var pt = piece_type.toU3();
    score[0] = mg_queen_attacking[pt];
    score[1] = eg_queen_attacking[pt];
    return score;
}

pub inline fn get_supported_pawn_bonus(rank: u6) [2]i32 {
    var score = [_]i32{ 0, 0 };
    score[0] = mg_supported_pawn[rank];
    score[1] = eg_supported_pawn[rank];
    return score;
}

pub inline fn get_phalanx_score(rank: u6) [2]i32 {
    var score = [_]i32{ 0, 0 };
    score[0] = mg_pawn_phalanx[rank];
    score[1] = eg_pawn_phalanx[rank];
    return score;
}

pub inline fn get_knight_mobility_score(index: u7) [2]i32 {
    var score = [_]i32{ 0, 0 };
    score[0] = mg_knigh_mobility[index];
    score[1] = eg_knigh_mobility[index];
    return score;
}

pub inline fn get_bishop_mobility_score(index: u7) [2]i32 {
    var score = [_]i32{ 0, 0 };
    score[0] = mg_bishop_mobility[index];
    score[1] = eg_bishop_mobility[index];
    return score;
}

pub inline fn get_rook_mobility_score(index: u7) [2]i32 {
    var score = [_]i32{ 0, 0 };
    score[0] = mg_rook_mobility[index];
    score[1] = eg_rook_mobility[index];
    return score;
}

pub inline fn get_queen_mobility_score(index: u7) [2]i32 {
    var score = [_]i32{ 0, 0 };
    score[0] = mg_queen_mobility[index];
    score[1] = eg_queen_mobility[index];
    return score;
}