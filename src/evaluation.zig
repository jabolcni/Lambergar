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
const eg_tempo = 15;

// pawns, knights, bishops, rooks, queens, kings

const material_mg = [6]i32{ 92, 410, 448, 577, 1173, 0 };
const material_eg = [6]i32{ 141, 232, 258, 450, 870, 0 };

const mg_pawn_table = [64]i32{ 0, 0, 0, 0, 0, 0, 0, 0, -42, 0, -17, -22, -5, 25, 53, -7, -39, -11, -4, -10, 7, -13, 35, -9, -46, -8, -11, 9, 8, -1, 3, -42, -26, -3, -8, 4, 18, 1, 3, -29, -38, -15, 7, 1, 23, 57, -3, -27, 41, 26, 14, 44, 70, 57, -8, -49, 0, 0, 0, 0, 0, 0, 0, 0 };
const eg_pawn_table = [64]i32{ 0, 0, 0, 0, 0, 0, 0, 0, -30, -40, -38, -37, -47, -49, -56, -57, -41, -43, -59, -47, -54, -53, -56, -57, -33, -42, -56, -61, -61, -62, -53, -50, -13, -24, -36, -48, -58, -49, -37, -34, 54, 50, 36, 18, 2, -7, 25, 33, 120, 121, 104, 71, 59, 73, 116, 112, 0, 0, 0, 0, 0, 0, 0, 0 };

const mg_knight_table = [64]i32{ -44, -3, -35, -14, -14, 0, -7, -66, -7, -14, 12, 19, 19, 30, 12, 6, -2, 11, 35, 28, 38, 28, 38, -6, 5, 16, 32, 29, 40, 41, 22, -6, 29, 32, 30, 69, 38, 62, 19, 41, 10, 38, 40, 81, 110, 135, 81, 8, -55, -13, 85, 36, 96, 86, 11, 9, -229, -57, -33, -52, 44, -113, -114, -131 };
const eg_knight_table = [64]i32{ -55, -42, -16, -9, -18, -11, -43, -32, -33, -22, -16, -4, -7, -12, -24, -32, -24, -3, -8, 14, 11, -2, -16, -30, -14, 0, 17, 19, 21, 5, -9, -9, -18, 8, 14, 21, 19, 11, 8, -22, -28, -18, 11, 4, -20, -16, -28, -22, -29, -17, -30, -12, -35, -34, -32, -52, -16, -48, -21, -13, -37, -21, -25, -81 };

const mg_bishop_table = [64]i32{ 23, -5, 14, 0, -6, -3, 17, 7, 1, 45, 23, 20, 21, 45, 54, 24, 38, 33, 34, 27, 33, 34, 27, 31, 2, 24, 24, 46, 48, 28, 23, -9, -12, 12, 36, 41, 43, 18, 25, 6, 0, 22, 62, 35, 77, 65, 59, 51, -12, 27, 3, 8, 28, 72, 17, 35, -25, -27, -7, -43, -105, -28, 17, -64 };
const eg_bishop_table = [64]i32{ -47, -25, -44, -17, -19, -29, -40, -35, -23, -37, -25, -14, -10, -23, -28, -41, -34, -15, -9, -2, -1, -11, -27, -35, -21, -14, 0, -7, -6, -1, -21, -24, -6, 0, -7, 1, -1, -9, -13, -23, -12, -12, -14, -3, -21, -7, -18, -29, -29, -19, -14, -22, -16, -32, -16, -51, -21, -33, -31, -13, -6, -18, -34, -11 };

const mg_rook_table = [64]i32{ -3, 0, 17, 18, 23, 8, -11, 8, -29, -5, -6, 0, 4, 8, 27, -36, -21, -8, 6, 15, 13, 4, 37, 20, -18, -18, -14, 4, 9, 4, 23, 9, -15, 5, 31, 43, 22, 34, 58, 53, 15, 26, 26, 54, 70, 85, 103, 74, 25, 12, 54, 92, 53, 106, 113, 82, 62, 78, 89, 97, 128, 154, 105, 50 };
const eg_rook_table = [64]i32{ -3, 5, 3, 11, -2, -5, 0, -35, 0, -2, 5, 3, -1, -2, -11, -2, -5, -1, -2, -4, -2, -8, -22, -21, 3, 6, 10, 7, 3, -1, -12, -16, 7, 2, 3, -1, 0, -2, -13, -16, 6, 4, 4, -3, -10, -12, -15, -16, 6, 20, 8, -4, -2, -10, -15, -16, 8, 1, 0, -5, -14, -25, -16, -1 };

const mg_queen_table = [64]i32{ 21, 5, 16, 33, 10, -3, -32, 12, 0, 24, 27, 25, 30, 47, 51, 30, 4, 26, 14, 21, 17, 25, 27, 14, 3, 10, 8, 11, 21, 18, 25, 9, -10, 3, 10, 8, 11, 19, 5, 33, -2, 4, 23, 45, 53, 100, 134, 81, -5, -14, -13, -43, -24, 114, 31, 151, -32, 7, 49, 81, 108, 112, -1, -28 };
const eg_queen_table = [64]i32{ -32, -37, -36, -69, -21, -37, -26, -59, -15, -14, -25, -7, -17, -56, -65, -48, -37, -44, 14, -6, 11, 4, 7, -20, -15, 2, 6, 36, 22, 12, 9, -7, -16, 11, 7, 35, 55, 52, 36, 3, -26, -5, 21, 6, 50, -1, -33, -31, -5, 1, 26, 72, 55, 28, 37, -88, 3, 2, -5, -3, -24, -21, -2, 36 };

const mg_king_table = [64]i32{ -54, 23, -4, -75, -8, -44, 34, 28, 39, -14, -33, -88, -72, -40, 18, 19, 13, 21, -69, -85, -88, -63, -14, -39, 48, 34, 11, -66, -54, -75, -38, -88, 19, 21, 56, 0, -13, -7, 13, -42, 62, 157, 47, 76, 15, 79, 90, -15, 58, 137, 93, 69, 70, 132, 17, -26, 111, 82, 106, 92, 114, 95, 65, 61 };
const eg_king_table = [64]i32{ -22, -23, -9, 2, -21, -1, -29, -52, -27, 1, 18, 33, 32, 26, 4, -13, -26, -1, 26, 37, 40, 34, 16, 5, -32, -3, 16, 34, 36, 39, 22, 12, -21, 3, 10, 23, 24, 31, 23, 15, -15, -3, 11, 6, 19, 22, 27, 21, -19, -5, -3, -1, 2, 12, 27, 17, -59, -24, -26, -19, -18, -6, -6, -32 };

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
            // midgame_table[Color.White.toU4()][piece][s_idx] = mg_pesto_table[piece][s_idx^56];
            // endgame_table[Color.White.toU4()][piece][s_idx] = eg_pesto_table[piece][s_idx^56];
            // midgame_table[Color.Black.toU4()][piece][s_idx] = mg_pesto_table[piece][s_idx];
            // endgame_table[Color.Black.toU4()][piece][s_idx] = eg_pesto_table[piece][s_idx];
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

    pub fn clean_eval(self: *Evaluation, pos: *Position, tnr: *tuner.Tuner) i32 {
        _ = tnr; // TUNER OFF
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

};