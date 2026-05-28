const std = @import("std");
const position = @import("position.zig");
const bb = @import("bitboard.zig");
const attacks = @import("attacks.zig");
const tuner = @import("tuner.zig");
const nnue = @import("nnue.zig");
const hce_params = @import("hce_params.zig");

const Position = position.Position;
pub const PawnHashEntry = position.PawnHashEntry;
const Square = position.Square;
const Piece = position.Piece;
const PieceType = position.PieceType;
const File = position.File;
const Color = position.Color;

const mg_tempo = hce_params.mg_tempo;
const eg_tempo = hce_params.eg_tempo;

// Import all HCE parameters from hce_params module
const material_mg = hce_params.material_mg;
const material_eg = hce_params.material_eg;

const mg_pawn_table = hce_params.mg_pawn_table;
const eg_pawn_table = hce_params.eg_pawn_table;

const mg_knight_table = hce_params.mg_knight_table;
const eg_knight_table = hce_params.eg_knight_table;

const mg_bishop_table = hce_params.mg_bishop_table;
const eg_bishop_table = hce_params.eg_bishop_table;

const mg_rook_table = hce_params.mg_rook_table;
const eg_rook_table = hce_params.eg_rook_table;

const mg_queen_table = hce_params.mg_queen_table;
const eg_queen_table = hce_params.eg_queen_table;

const mg_king_table = hce_params.mg_king_table;
const eg_king_table = hce_params.eg_king_table;

const mg_passed_score = hce_params.mg_passed_score;
const eg_passed_score = hce_params.eg_passed_score;

const mg_isolated_pawn_score = hce_params.mg_isolated_pawn_score;
const eg_isolated_pawn_score = hce_params.eg_isolated_pawn_score;

const mg_blocked_passer_score = hce_params.mg_blocked_passer_score;
const eg_blocked_passer_score = hce_params.eg_blocked_passer_score;

const mg_supported_pawn = hce_params.mg_supported_pawn;
const eg_supported_pawn = hce_params.eg_supported_pawn;

const mg_pawn_phalanx = hce_params.mg_pawn_phalanx;
const eg_pawn_phalanx = hce_params.eg_pawn_phalanx;

const mg_knight_mobility = hce_params.mg_knight_mobility;
const eg_knight_mobility = hce_params.eg_knight_mobility;

const mg_bishop_mobility = hce_params.mg_bishop_mobility;
const eg_bishop_mobility = hce_params.eg_bishop_mobility;

const mg_rook_mobility = hce_params.mg_rook_mobility;
const eg_rook_mobility = hce_params.eg_rook_mobility;

const mg_queen_mobility = hce_params.mg_queen_mobility;
const eg_queen_mobility = hce_params.eg_queen_mobility;

const mg_pawn_attacking = hce_params.mg_pawn_attacking;
const eg_pawn_attacking = hce_params.eg_pawn_attacking;

const mg_knight_attacking = hce_params.mg_knight_attacking;
const eg_knight_attacking = hce_params.eg_knight_attacking;

const mg_bishop_attacking = hce_params.mg_bishop_attacking;
const eg_bishop_attacking = hce_params.eg_bishop_attacking;

const mg_rook_attacking = hce_params.mg_rook_attacking;
const eg_rook_attacking = hce_params.eg_rook_attacking;

const mg_queen_attacking = hce_params.mg_queen_attacking;
const eg_queen_attacking = hce_params.eg_queen_attacking;

const mg_doubled_pawns = hce_params.mg_doubled_pawns;
const eg_doubled_pawns = hce_params.eg_doubled_pawns;

const mg_bishop_pair = hce_params.mg_bishop_pair;
const eg_bishop_pair = hce_params.eg_bishop_pair;

const mg_rook_open = hce_params.mg_rook_open;
const eg_rook_open = hce_params.eg_rook_open;
const mg_rook_semi_open = hce_params.mg_rook_semi_open;
const eg_rook_semi_open = hce_params.eg_rook_semi_open;

const mg_knight_outpost = hce_params.mg_knight_outpost;
const eg_knight_outpost = hce_params.eg_knight_outpost;

const mg_backward_pawn = hce_params.mg_backward_pawn;
const eg_backward_pawn = hce_params.eg_backward_pawn;

const mg_king_pawn_shield = hce_params.mg_king_pawn_shield;
const eg_king_pawn_shield = hce_params.eg_king_pawn_shield;

const mg_rook_behind_passer = hce_params.mg_rook_behind_passer;
const eg_rook_behind_passer = hce_params.eg_rook_behind_passer;

const mg_pawn_storm = hce_params.mg_pawn_storm;
const eg_pawn_storm = hce_params.eg_pawn_storm;

const mg_candidate_pawn = hce_params.mg_candidate_pawn;
const eg_candidate_pawn = hce_params.eg_candidate_pawn;

const mg_connected_rooks = hce_params.mg_connected_rooks;
const eg_connected_rooks = hce_params.eg_connected_rooks;

const mg_blockade_passer = hce_params.mg_blockade_passer;
const eg_blockade_passer = hce_params.eg_blockade_passer;

const mg_bishop_outpost = hce_params.mg_bishop_outpost;
const eg_bishop_outpost = hce_params.eg_bishop_outpost;

const mg_king_virtual_mobility = hce_params.mg_king_virtual_mobility;
const eg_king_virtual_mobility = hce_params.eg_king_virtual_mobility;

const mg_trapped_bishop = hce_params.mg_trapped_bishop;
const eg_trapped_bishop = hce_params.eg_trapped_bishop;
const mg_trapped_rook = hce_params.mg_trapped_rook;
const eg_trapped_rook = hce_params.eg_trapped_rook;

const mg_king_safety = hce_params.mg_king_safety;
const eg_king_safety = hce_params.eg_king_safety;

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

const KING_CENTER = [64]i32{
    -90, -80, -70, -60, -60, -70, -80, -90,
    -80, -60, -50, -40, -40, -50, -60, -80,
    -70, -50, -30, -20, -20, -30, -50, -70,
    -60, -40, -20,   0,   0, -20, -40, -60,
    -60, -40, -20,   0,   0, -20, -40, -60,
    -70, -50, -30, -20, -20, -30, -50, -70,
    -80, -60, -50, -40, -40, -50, -60, -80,
    -90, -80, -70, -60, -60, -70, -80, -90,
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


pub  fn distance(sq1: u6, sq2: u6) u4 {

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

    const drank = @as(i8,@intCast(position.rank_of_u6(sq1)))-@as(i8,@intCast(position.rank_of_u6(sq2)));
    const dfile = @as(i8,@intCast(position.file_of_u6(sq1)))-@as(i8,@intCast(position.file_of_u6(sq2)));
    return dist[@as(u7, (@intCast(drank*drank + dfile*dfile)))];

}


pub fn init_eval() void {
    init_pesto_tables();
}

pub fn init_pesto_tables() void {
    for (PieceType.Pawn.toU3() ..(PieceType.King.toU3()+1)) |piece| {
        for (Square.a1.toU7()..(Square.h8.toU7()+1)) |s_idx| {
           (&midgame_table)[Color.White.toU4()][piece][s_idx] = (&mg_pesto_table)[piece][s_idx];
           (&endgame_table)[Color.White.toU4()][piece][s_idx] = (&eg_pesto_table)[piece][s_idx];
           (&midgame_table)[Color.Black.toU4()][piece][s_idx] = (&mg_pesto_table)[piece][s_idx^56];
           (&endgame_table)[Color.Black.toU4()][piece][s_idx] = (&eg_pesto_table)[piece][s_idx^56];         
        }
    }
}

pub const Evaluation = struct {
    eval_mg: i32 = 0,
    eval_eg: i32 = 0,
    phase: [2]u8 = @splat(0),

    pub  fn put_piece(self: *Evaluation, pc: Piece, s_idx: u6) void {

        const pc_type_idx = pc.type_of().toU3();

        if (pc.color() == Color.White) {
            self.eval_mg += (&material_mg)[pc_type_idx];
            self.eval_eg += (&material_eg)[pc_type_idx];
            
            self.eval_mg += (&midgame_table)[Color.White.toU4()][pc_type_idx][s_idx];
            self.eval_eg += (&endgame_table)[Color.White.toU4()][pc_type_idx][s_idx];            

            self.phase[Color.White.toU4()] += phaseValues[pc_type_idx];
        } else {
            self.eval_mg -= (&material_mg)[pc_type_idx];
            self.eval_eg -= (&material_eg)[pc_type_idx];

            self.eval_mg -= (&midgame_table)[Color.Black.toU4()][pc_type_idx][s_idx];
            self.eval_eg -= (&endgame_table)[Color.Black.toU4()][pc_type_idx][s_idx];            

            self.phase[Color.Black.toU4()] += phaseValues[pc_type_idx];
        }
    }

    pub  fn remove_piece(self: *Evaluation, pc: Piece, s_idx: u6) void {

        const pc_type_idx = pc.type_of().toU3();

        if (pc != Piece.NO_PIECE) {
            if (pc.color() == Color.White) {
                self.eval_mg -= material_mg[pc_type_idx];
                self.eval_eg -= material_eg[pc_type_idx];
                
                self.eval_mg -= (&midgame_table)[Color.White.toU4()][pc_type_idx][s_idx];
                self.eval_eg -= (&endgame_table)[Color.White.toU4()][pc_type_idx][s_idx];            

                self.phase[Color.White.toU4()] -= phaseValues[pc_type_idx];
            } else {
                self.eval_mg += material_mg[pc_type_idx];
                self.eval_eg += material_eg[pc_type_idx];

                self.eval_mg += (&midgame_table)[Color.Black.toU4()][pc_type_idx][s_idx];
                self.eval_eg += (&endgame_table)[Color.Black.toU4()][pc_type_idx][s_idx];            

                self.phase[Color.Black.toU4()] -= phaseValues[pc_type_idx];
            }   
        }     
    }

    pub  fn move_piece_quiet(self: *Evaluation, pc: Piece, from: u6, to: u6) void {
        const pc_type_idx = pc.type_of().toU3();

        if (pc != Piece.NO_PIECE) {
            if (pc.color() == Color.White) {
                self.eval_mg -= (&midgame_table)[Color.White.toU4()][pc_type_idx][from];
                self.eval_eg -= (&endgame_table)[Color.White.toU4()][pc_type_idx][from];            
 
                self.eval_mg += (&midgame_table)[Color.White.toU4()][pc_type_idx][to];
                self.eval_eg += (&endgame_table)[Color.White.toU4()][pc_type_idx][to];            
            } else {
                self.eval_mg += (&midgame_table)[Color.Black.toU4()][pc_type_idx][from];
                self.eval_eg += (&endgame_table)[Color.Black.toU4()][pc_type_idx][from];            

                self.eval_mg -= (&midgame_table)[Color.Black.toU4()][pc_type_idx][to];
                self.eval_eg -= (&endgame_table)[Color.Black.toU4()][pc_type_idx][to];            
            }   
        } 

    }

    pub  fn move_piece(self: *Evaluation, from_pc: Piece, to_pc: Piece, from: u6, to: u6) void {

        self.remove_piece(to_pc, to);
        self.move_piece_quiet(from_pc, from, to);

    }

    pub  fn put_piece_update_phase(self: *Evaluation, pc: Piece) void {

        const pc_type_idx = pc.type_of().toU3();

        if (pc.color() == Color.White) {
            self.phase[Color.White.toU4()] += phaseValues[pc_type_idx];
        } else {
            self.phase[Color.Black.toU4()] += phaseValues[pc_type_idx];
        }
    }

    pub  fn remove_piece_update_phase(self: *Evaluation, pc: Piece) void {

        const pc_type_idx = pc.type_of().toU3();

        if (pc != Piece.NO_PIECE) {
            if (pc.color() == Color.White) {
                self.phase[Color.White.toU4()] -= phaseValues[pc_type_idx];
            } else {
                self.phase[Color.Black.toU4()] -= phaseValues[pc_type_idx];
            }   
        }     
    }

    pub  fn move_piece_update_phase(self: *Evaluation, to_pc: Piece) void {
        self.remove_piece_update_phase(to_pc);
    }    

    pub fn clean_eval(self: *Evaluation, pos: *Position, tnr: ?*tuner.Tuner) i32 {
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
            const pc_count = bb.pop_count(b1);
            const pc_type_idx = pc;
            mat_white_mg += material_mg[pc_type_idx]*pc_count;
            mat_white_eg += material_eg[pc_type_idx]*pc_count;
            if (tnr) |t| t.mat[0][pc_type_idx] = @as(u8, @intCast(pc_count));

            while (b1 != 0) {
                const s_idx = bb.pop_lsb(&b1);
                pos_white_mg += (&midgame_table)[Color.White.toU4()][pc_type_idx][s_idx];
                pos_white_eg += (&endgame_table)[Color.White.toU4()][pc_type_idx][s_idx];
                if (tnr) |t| t.psqt[0][pc_type_idx][s_idx] += 1;
            }

            phase_white += phaseValues[pc_type_idx]*pc_count;

        }

        for (Piece.BLACK_PAWN.toU4()..(Piece.BLACK_KING.toU4()+1)) |pc| {
            var b1 = pos.piece_bb[pc];
            const pc_count = bb.pop_count(b1);
            const pc_type_idx = pc - 8;
            mat_black_mg += material_mg[pc_type_idx]*pc_count;
            mat_black_eg += material_eg[pc_type_idx]*pc_count;
            if (tnr) |t| t.mat[1][pc_type_idx] = @as(u8, @intCast(pc_count));

            while (b1 != 0) {
                const s_idx = bb.pop_lsb(&b1);
                pos_black_mg += (&midgame_table)[Color.Black.toU4()][pc_type_idx][s_idx];
                pos_black_eg += (&endgame_table)[Color.Black.toU4()][pc_type_idx][s_idx];
                if (tnr) |t| t.psqt[1][pc_type_idx][s_idx ^ 56] += 1;
            }

            phase_black += phaseValues[pc_type_idx]*pc_count;            
        }

        self.eval_mg = mat_white_mg + pos_white_mg - mat_black_mg - pos_black_mg;
        self.eval_eg = mat_white_eg + pos_white_eg - mat_black_eg - pos_black_eg;
        self.phase[0] = phase_white;
        self.phase[1] = phase_black;

        const phase_bounded = @min(self.phase[Color.White.toU4()]+self.phase[Color.Black.toU4()], 64);

        var eval_mg = self.eval_mg;
        var eval_eg = self.eval_eg;   

        const piece_scores = self.eval_pieces(pos, tnr);
        eval_mg += piece_scores[0];
        eval_eg += piece_scores[1];        

        var e: i32 = @divTrunc((eval_mg * phase_bounded + eval_eg * (64-phase_bounded)), 64);

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

    fn end_game_eval(self: *Evaluation, pos: *Position, comptime perspective_color: Color) i32 {

        var e: i32 = 0;
        const perspective = if (perspective_color == Color.White) @as(i32, 1) else @as(i32, -1);

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

        return e * perspective;
    }

    pub fn adjust_eval(self: *Evaluation, pos: *Position, score: i32) i32 {

        if (nnue.engine_using_nnue) {
            const phase_bounded = @min(self.phase[Color.White.toU4()]+self.phase[Color.Black.toU4()], 64);
            const scale: i32 = 320 + 2 * @as(i32,@intCast(phase_bounded));
            var e = @divTrunc(score * scale, 448);
            e = @divTrunc(e * (150 - pos.history[pos.game_ply].fifty), 150);
            //curr_accu.eval = e;
            return e;
        } else {
            return score;
        }
    }

    pub fn eval(self: *Evaluation, pos: *Position, comptime perspective_color: Color) i32 {

        if (nnue.engine_using_nnue) {

            const curr_accu: *nnue.Accumulator = &pos.history[pos.game_ply].accumulator;
            if (curr_accu.computed_score) {
                return curr_accu.eval;
            }

            nnue.incremental_update(pos);
            curr_accu.eval = nnue.evaluate(curr_accu.*, perspective_color);
            curr_accu.computed_score = true;
            
            return curr_accu.eval;

        } else {
            return self.evalHCE(pos, perspective_color);
        }

    }

    pub fn evalHCE(self: *Evaluation, pos: *Position, comptime perspective_color: Color) i32 {

        const phase_bounded: i32 = @intCast(@min(self.phase[Color.White.toU4()]+self.phase[Color.Black.toU4()], 64));
        const perspective = if (perspective_color == Color.White) @as(i32, 1) else @as(i32, -1);

        var eval_mg = self.eval_mg;
        var eval_eg = self.eval_eg;

        const pieces_score = self.eval_pieces(pos, null);
        eval_mg += pieces_score[0];
        eval_eg += pieces_score[1];

        var e: i32 = @divTrunc((eval_mg * phase_bounded + eval_eg * (64 - phase_bounded)), 64);

        if (self.phase[Color.White.toU4()] > 3 and self.phase[Color.Black.toU4()] == 0 and pos.piece_count(Piece.BLACK_PAWN) == 0) {
            // White is stronger
            const white_king = bb.get_ls1b_index(pos.piece_bb[Piece.WHITE_KING.toU4()]);
            const black_king = bb.get_ls1b_index(pos.piece_bb[Piece.BLACK_KING.toU4()]);
            if (self.phase[Color.White.toU4()] == 6 and pos.piece_count(Piece.WHITE_BISHOP) == 1 and pos.piece_count(Piece.WHITE_KNIGHT) == 1) {
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
            if (self.phase[Color.Black.toU4()] == 6 and pos.piece_count(Piece.BLACK_BISHOP) == 1 and pos.piece_count(Piece.BLACK_KNIGHT) == 1) {
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

        return e * perspective;
    }


const pawn_hash_bits = 19;
const pawn_hash_size: usize = 1 << pawn_hash_bits;
const pawn_hash_mask: u64 = (@as(u64, 1) << pawn_hash_bits) - 1;
var pawn_hash_table = std.mem.zeroes([pawn_hash_size]PawnHashEntry);


fn pawn_hash_index(hash: u64) usize {
    return @as(usize, @intCast(hash & pawn_hash_mask));
}

fn get_pawn_hash_entry(pos: *Position, tnr: ?*tuner.Tuner) PawnHashEntry {
    const key = pos.pawn_hash;

    // When collecting tuner features, always recompute so counters are updated,
    // even if a cached entry exists from earlier evals without tuner context.
    if (tnr) |_| {
        const computed = compute_pawn_hash_entry(pos, tnr);
        const idx = pawn_hash_index(key);
        pawn_hash_table[idx] = computed;
        pos.pawn_entry = computed;
        pos.pawn_entry_valid = true;
        pos.pawn_entry_stack[pos.game_ply] = computed;
        pos.pawn_entry_valid_stack[pos.game_ply] = true;
        return computed;
    }

    if (pos.pawn_entry_valid and pos.pawn_entry.key == key) {
        return pos.pawn_entry;
    }

    const idx = pawn_hash_index(key);
    const entry = pawn_hash_table[idx];
    if (entry.valid and entry.key == key) {
        pos.pawn_entry = entry;
        pos.pawn_entry_valid = true;
        pos.pawn_entry_stack[pos.game_ply] = entry;
        pos.pawn_entry_valid_stack[pos.game_ply] = true;
        return entry;
    }

    const computed = compute_pawn_hash_entry(pos, null);
    pawn_hash_table[idx] = computed;
    pos.pawn_entry = computed;
    pos.pawn_entry_valid = true;
    pos.pawn_entry_stack[pos.game_ply] = computed;
    pos.pawn_entry_valid_stack[pos.game_ply] = true;
    return computed;
}

fn compute_pawn_hash_entry(pos: *Position, tnr: ?*tuner.Tuner) PawnHashEntry {
    const white_pawns = pos.piece_bb[Piece.WHITE_PAWN.toU4()];
    const black_pawns = pos.piece_bb[Piece.BLACK_PAWN.toU4()];

    const not_file_a: u64 = ~bb.MASK_FILE[File.AFILE.toU3()];
    const not_file_h: u64 = ~bb.MASK_FILE[File.HFILE.toU3()];

    const white_west_attacks = (white_pawns & not_file_a) << 7;
    const white_east_attacks = (white_pawns & not_file_h) << 9;
    const black_west_attacks = (black_pawns & not_file_a) >> 9;
    const black_east_attacks = (black_pawns & not_file_h) >> 7;

    var entry = PawnHashEntry{
        .key = pos.pawn_hash,
        .valid = true,
        .white_pawn_attacks = white_west_attacks | white_east_attacks,
        .black_pawn_attacks = black_west_attacks | black_east_attacks,
        .white_west_attacks = white_west_attacks,
        .white_east_attacks = white_east_attacks,
        .black_west_attacks = black_west_attacks,
        .black_east_attacks = black_east_attacks,
    };

    var pawn_score = [_]i32{ 0, 0 };

    var pawns = white_pawns;
    while (pawns != 0) {
        const sq = bb.pop_lsb(&pawns);
        const file = position.file_of_u6(sq);
        const rank = position.rank_of_u6(sq);
        const sq_idx = @as(usize, @intCast(sq));

        if ((white_pawns & IsolatedPawnMask[file]) == 0) {
            const tmp_sc = get_isolated_pawn_score(file);
            pawn_score[0] += tmp_sc[0];
            pawn_score[1] += tmp_sc[1];
            if (tnr) |t| t.isolated_pawn[0][file] += 1;
        }

        // Backward pawn check
        const neighborhood = (bb.MASK_FILE[file] | (if (file > 0) bb.MASK_FILE[file - 1] else 0) | (if (file < 7) bb.MASK_FILE[file + 1] else 0)) & RankBelowIncl[rank];
        if ((white_pawns & neighborhood) == bb.SQUARE_BB[sq_idx]) {
            const stop_sq = sq_idx + 8;
            if (stop_sq < 64 and (entry.black_pawn_attacks & bb.SQUARE_BB[stop_sq]) != 0) {
                if ((entry.white_pawn_attacks & bb.SQUARE_BB[stop_sq]) == 0) {
                    pawn_score[0] += mg_backward_pawn[0];
                    pawn_score[1] += eg_backward_pawn[0];
                    if (tnr) |t| t.backward_pawn[0] += 1;
                }
            }
        }

        const is_passed = ((WhitePassedPawnMask[sq] & black_pawns) == 0) and ((WhitePassedPawnFilter[sq] & white_pawns) == 0);
        if (is_passed) {
            const tmp_sc = get_passed_pawn_score(sq);
            pawn_score[0] += tmp_sc[0];
            pawn_score[1] += tmp_sc[1];
            entry.white_passers |= bb.SQUARE_BB[sq_idx];
            const forward_sq: usize = sq_idx + 8;
            if (forward_sq < 64) {
                entry.white_passed_front |= bb.SQUARE_BB[forward_sq];
            }
            if (tnr) |t| t.passed_pawn[0][sq_idx] += 1;
        } else {
            // Candidate Passed Pawn check (White)
            // Check if no enemy pawn on the same file in front
            if ((bb.MASK_FILE[file] & RankAboveIncl[rank] & ~bb.SQUARE_BB[sq_idx] & black_pawns) == 0) {
                pawn_score[0] += mg_candidate_pawn[sq_idx];
                pawn_score[1] += eg_candidate_pawn[sq_idx];
                if (tnr) |t| t.candidate_pawn[0][sq_idx] += 1;
            }
        }

        if ((entry.white_pawn_attacks & bb.SQUARE_BB[sq_idx]) != 0) {
            const tmp_sc = get_supported_pawn_bonus(rank);
            pawn_score[0] += tmp_sc[0];
            pawn_score[1] += tmp_sc[1];
            if (tnr) |t| t.supported_pawn[0][rank] += 1;
        }

        if (file != 7) {
            const east_sq = sq_idx + 1;
            if ((white_pawns & bb.SQUARE_BB[east_sq]) != 0) {
                const tmp_sc = get_phalanx_score(rank);
                pawn_score[0] += tmp_sc[0];
                pawn_score[1] += tmp_sc[1];
                if (tnr) |t| t.pawn_phalanx[0][rank] += 1;
            }
        }
    }

    pawns = black_pawns;
    while (pawns != 0) {
        const sq = bb.pop_lsb(&pawns);
        const file = position.file_of_u6(sq);
        const rank = position.rank_of_u6(sq);
        const sq_idx = @as(usize, @intCast(sq));

        if ((black_pawns & IsolatedPawnMask[file]) == 0) {
            const tmp_sc = get_isolated_pawn_score(7 - file);
            pawn_score[0] -= tmp_sc[0];
            pawn_score[1] -= tmp_sc[1];
            if (tnr) |t| t.isolated_pawn[1][7 - file] += 1;
        }

        // Backward pawn check
        const neighborhood = (bb.MASK_FILE[file] | (if (file > 0) bb.MASK_FILE[file - 1] else 0) | (if (file < 7) bb.MASK_FILE[file + 1] else 0)) & RankAboveIncl[rank];
        if ((black_pawns & neighborhood) == bb.SQUARE_BB[sq_idx]) {
            if (sq_idx >= 8) {
                const stop_sq = sq_idx - 8;
                if ((entry.white_pawn_attacks & bb.SQUARE_BB[stop_sq]) != 0) {
                    if ((entry.black_pawn_attacks & bb.SQUARE_BB[stop_sq]) == 0) {
                        pawn_score[0] -= mg_backward_pawn[0];
                        pawn_score[1] -= eg_backward_pawn[0];
                        if (tnr) |t| t.backward_pawn[1] += 1;
                    }
                }
            }
        }

        const is_passed = ((BlackPassedPawnMask[sq] & white_pawns) == 0) and ((BlackPassedPawnFilter[sq] & black_pawns) == 0);
        if (is_passed) {
            const tmp_sc = get_passed_pawn_score(sq ^ 56);
            pawn_score[0] -= tmp_sc[0];
            pawn_score[1] -= tmp_sc[1];
            entry.black_passers |= bb.SQUARE_BB[sq_idx];
            if (sq_idx >= 8) {
                const forward_sq = sq_idx - 8;
                entry.black_passed_front |= bb.SQUARE_BB[forward_sq];
            }
            if (tnr) |t| t.passed_pawn[1][sq_idx ^ 56] += 1;
        } else {
            // Candidate Passed Pawn check (Black)
            // Check if no enemy pawn on the same file in front
            if ((bb.MASK_FILE[file] & RankBelowIncl[rank] & ~bb.SQUARE_BB[sq_idx] & white_pawns) == 0) {
                pawn_score[0] -= mg_candidate_pawn[sq_idx ^ 56];
                pawn_score[1] -= eg_candidate_pawn[sq_idx ^ 56];
                if (tnr) |t| t.candidate_pawn[1][sq_idx ^ 56] += 1;
            }
        }

        if ((entry.black_pawn_attacks & bb.SQUARE_BB[sq_idx]) != 0) {
            const tmp_sc = get_supported_pawn_bonus(7 - rank);
            pawn_score[0] -= tmp_sc[0];
            pawn_score[1] -= tmp_sc[1];
            if (tnr) |t| t.supported_pawn[1][7 - rank] += 1;
        }

        if (file != 7) {
            const east_sq = sq_idx + 1;
            if ((black_pawns & bb.SQUARE_BB[east_sq]) != 0) {
                const tmp_sc = get_phalanx_score(7 - rank);
                pawn_score[0] -= tmp_sc[0];
                pawn_score[1] -= tmp_sc[1];
                if (tnr) |t| t.pawn_phalanx[1][7 - rank] += 1;
            }
        }
    }

    for (0..8) |i| {
        const white_pawns_on_file = bb.pop_count(white_pawns & bb.MASK_FILE[i]);
        if (white_pawns_on_file >= 2) {
            pawn_score[0] += mg_doubled_pawns[0];
            pawn_score[1] += eg_doubled_pawns[0];
            if (tnr) |t| t.doubled_pawns[0] += 1;
        }

        const black_pawns_on_file = bb.pop_count(black_pawns & bb.MASK_FILE[i]);
        if (black_pawns_on_file >= 2) {
            pawn_score[0] -= mg_doubled_pawns[0];
            pawn_score[1] -= eg_doubled_pawns[0];
            if (tnr) |t| t.doubled_pawns[1] += 1;
        }
    }

    entry.mg_score = pawn_score[0];
    entry.eg_score = pawn_score[1];
    return entry;
}

inline fn count_pawn_attacks(dir_west: u64, dir_east: u64, targets: u64) i32 {
    const west_hits = bb.pop_count(dir_west & targets);
    const east_hits = bb.pop_count(dir_east & targets);
    return @as(i32, @intCast(west_hits + east_hits));
}

inline fn count_white_pawns_attacking(zone: u64, pawns: u64) u32 {
    const not_file_a: u64 = ~bb.MASK_FILE[File.AFILE.toU3()];
    const not_file_h: u64 = ~bb.MASK_FILE[File.HFILE.toU3()];
    const attackers = pawns & ((not_file_a & (zone >> 7)) | (not_file_h & (zone >> 9)));
    return bb.pop_count(attackers);
}

inline fn count_black_pawns_attacking(zone: u64, pawns: u64) u32 {
    const not_file_a: u64 = ~bb.MASK_FILE[File.AFILE.toU3()];
    const not_file_h: u64 = ~bb.MASK_FILE[File.HFILE.toU3()];
    const attackers = pawns & ((not_file_a & (zone << 9)) | (not_file_h & (zone << 7)));
    return bb.pop_count(attackers);
}

fn eval_pieces(self: *Evaluation, pos: *Position, tnr: ?*tuner.Tuner) [2]i32 {

        _ = self;

        const white_pawns = pos.piece_bb[Piece.WHITE_PAWN.toU4()];
        const white_knight = pos.piece_bb[Piece.WHITE_KNIGHT.toU4()];
        const white_bishop = pos.piece_bb[Piece.WHITE_BISHOP.toU4()];
        const white_rook = pos.piece_bb[Piece.WHITE_ROOK.toU4()];
        const white_queen = pos.piece_bb[Piece.WHITE_QUEEN.toU4()];
        const white_pieces = pos.all_white_pieces();
        const black_pawns = pos.piece_bb[Piece.BLACK_PAWN.toU4()];
        const black_knight = pos.piece_bb[Piece.BLACK_KNIGHT.toU4()];
        const black_bishop = pos.piece_bb[Piece.BLACK_BISHOP.toU4()];
        const black_rook = pos.piece_bb[Piece.BLACK_ROOK.toU4()];
        const black_queen = pos.piece_bb[Piece.BLACK_QUEEN.toU4()];
        const black_pieces = pos.all_black_pieces();
        
        const white_pawn_files = get_pawn_file_mask(white_pawns);
        const black_pawn_files = get_pawn_file_mask(black_pawns);

        const pawn_entry = get_pawn_hash_entry(pos, tnr);
        const white_pawn_attacks = pawn_entry.white_pawn_attacks;
        const black_pawn_attacks = pawn_entry.black_pawn_attacks;
        const white_west_attacks = pawn_entry.white_west_attacks;
        const white_east_attacks = pawn_entry.white_east_attacks;
        const black_west_attacks = pawn_entry.black_west_attacks;
        const black_east_attacks = pawn_entry.black_east_attacks;

        var white_att: u64 = white_pawn_attacks & ~white_pieces;
        const white_king_sq = bb.get_ls1b_index(pos.piece_bb[Piece.WHITE_KING.toU4()]);
        const white_king_zone = KingArea[white_king_sq];
        var white_danger_score: i32 = 0;
        var white_danger_pieces: u5 = 0;

        var black_att: u64 = black_pawn_attacks & ~black_pieces;
        const black_king_sq = bb.get_ls1b_index(pos.piece_bb[Piece.BLACK_KING.toU4()]);
        const black_king_zone = KingArea[black_king_sq];
        var black_danger_score: i32 = 0;
        var black_danger_pieces: u5 = 0;

        var white_king_zone_attacks: u64 = 0;
        var black_king_zone_attacks: u64 = 0;

        var pawn_structure_score = [_]i32{ pawn_entry.mg_score, pawn_entry.eg_score };
        var white_blocked_passers = pawn_entry.white_passed_front & black_pieces;
        while (white_blocked_passers != 0) {
            const front_sq = bb.pop_lsb(&white_blocked_passers);
            const front_rank = position.rank_of_u6(front_sq);
            const pawn_rank = front_rank - 1;
            const tmp_sc = get_blocked_passer_score(pawn_rank);
            pawn_structure_score[0] += tmp_sc[0];
            pawn_structure_score[1] += tmp_sc[1];
            if (tnr) |t| t.blocked_passer[0][pawn_rank] += 1;
        }

        var black_blocked_passers = pawn_entry.black_passed_front & white_pieces;
        while (black_blocked_passers != 0) {
            const front_sq = bb.pop_lsb(&black_blocked_passers);
            const front_rank = position.rank_of_u6(front_sq);
            const pawn_rank = front_rank + 1;
            const tmp_sc = get_blocked_passer_score(7 - pawn_rank);
            pawn_structure_score[0] -= tmp_sc[0];
            pawn_structure_score[1] -= tmp_sc[1];
            if (tnr) |t| t.blocked_passer[1][7 - pawn_rank] += 1;
        }

        const occ = white_pieces | black_pieces;
        var threat_score = [_]i32{0,0};
        var king_score = [_]i32{0,0};
        var additional_material_score= [_]i32{0,0};
        var score = [_]i32{0,0};
        var mobility_score = [_]i32{0,0};

        const white_zone_attackers = count_white_pawns_attacking(black_king_zone, white_pawns);
        if (white_zone_attackers != 0) {
            const count_i32 = @as(i32, @intCast(white_zone_attackers));
            black_danger_score += count_i32 * PieceDangers[PieceType.Pawn.toU3()];
            black_danger_pieces += @as(u5, @intCast(white_zone_attackers));
        }

        const black_zone_attackers = count_black_pawns_attacking(white_king_zone, black_pawns);
        if (black_zone_attackers != 0) {
            const count_i32 = @as(i32, @intCast(black_zone_attackers));
            white_danger_score += count_i32 * PieceDangers[PieceType.Pawn.toU3()];
            white_danger_pieces += @as(u5, @intCast(black_zone_attackers));
        }

        var attack_count = count_pawn_attacks(white_west_attacks, white_east_attacks, black_knight);
        if (attack_count != 0) {
            const tmp_sc = get_pawn_threat(PieceType.Knight);
            threat_score[0] += tmp_sc[0] * attack_count;
            threat_score[1] += tmp_sc[1] * attack_count;
            if (tnr) |t| t.pawn_attacking[0][PieceType.Knight.toU3()] += @as(u8, @intCast(attack_count));
        }
        attack_count = count_pawn_attacks(white_west_attacks, white_east_attacks, black_bishop);
        if (attack_count != 0) {
            const tmp_sc = get_pawn_threat(PieceType.Bishop);
            threat_score[0] += tmp_sc[0] * attack_count;
            threat_score[1] += tmp_sc[1] * attack_count;
            if (tnr) |t| t.pawn_attacking[0][PieceType.Bishop.toU3()] += @as(u8, @intCast(attack_count));
        }
        attack_count = count_pawn_attacks(white_west_attacks, white_east_attacks, black_rook);
        if (attack_count != 0) {
            const tmp_sc = get_pawn_threat(PieceType.Rook);
            threat_score[0] += tmp_sc[0] * attack_count;
            threat_score[1] += tmp_sc[1] * attack_count;
            if (tnr) |t| t.pawn_attacking[0][PieceType.Rook.toU3()] += @as(u8, @intCast(attack_count));
        }
        attack_count = count_pawn_attacks(white_west_attacks, white_east_attacks, black_queen);
        if (attack_count != 0) {
            const tmp_sc = get_pawn_threat(PieceType.Queen);
            threat_score[0] += tmp_sc[0] * attack_count;
            threat_score[1] += tmp_sc[1] * attack_count;
            if (tnr) |t| t.pawn_attacking[0][PieceType.Queen.toU3()] += @as(u8, @intCast(attack_count));
        }

        attack_count = count_pawn_attacks(black_west_attacks, black_east_attacks, white_knight);
        if (attack_count != 0) {
            const tmp_sc = get_pawn_threat(PieceType.Knight);
            threat_score[0] -= tmp_sc[0] * attack_count;
            threat_score[1] -= tmp_sc[1] * attack_count;
            if (tnr) |t| t.pawn_attacking[1][PieceType.Knight.toU3()] += @as(u8, @intCast(attack_count));
        }
        attack_count = count_pawn_attacks(black_west_attacks, black_east_attacks, white_bishop);
        if (attack_count != 0) {
            const tmp_sc = get_pawn_threat(PieceType.Bishop);
            threat_score[0] -= tmp_sc[0] * attack_count;
            threat_score[1] -= tmp_sc[1] * attack_count;
            if (tnr) |t| t.pawn_attacking[1][PieceType.Bishop.toU3()] += @as(u8, @intCast(attack_count));
        }
        attack_count = count_pawn_attacks(black_west_attacks, black_east_attacks, white_rook);
        if (attack_count != 0) {
            const tmp_sc = get_pawn_threat(PieceType.Rook);
            threat_score[0] -= tmp_sc[0] * attack_count;
            threat_score[1] -= tmp_sc[1] * attack_count;
            if (tnr) |t| t.pawn_attacking[1][PieceType.Rook.toU3()] += @as(u8, @intCast(attack_count));
        }
        attack_count = count_pawn_attacks(black_west_attacks, black_east_attacks, white_queen);
        if (attack_count != 0) {
            const tmp_sc = get_pawn_threat(PieceType.Queen);
            threat_score[0] -= tmp_sc[0] * attack_count;
            threat_score[1] -= tmp_sc[1] * attack_count;
            if (tnr) |t| t.pawn_attacking[1][PieceType.Queen.toU3()] += @as(u8, @intCast(attack_count));
        }

        // Knights
        var pc_bb = white_knight;
        while (pc_bb != 0) {
            const sq = bb.pop_lsb(&pc_bb);
            const att = attacks.KNIGHT_ATTACKS[sq];
            const mobility = att & ~white_pieces;
            white_att |= mobility;
            const index = bb.pop_count(mobility & ~black_pawn_attacks);
            var tmp_sc = get_knight_mobility_score(index);
            if (tnr) |t| t.knight_mobility[0][index] += 1;
            mobility_score[0] += tmp_sc[0];
            mobility_score[1] += tmp_sc[1];
            if ((black_king_zone & mobility) != 0) {
                black_danger_score += PieceDangers[PieceType.Knight.toU3()];
                black_danger_pieces += 1;
                white_king_zone_attacks |= (mobility & black_king_zone);
            }

            // Knight outpost
            const rank = position.rank_of_u6(sq);
            if (rank >= 3 and rank <= 5) { // Ranks 4, 5, 6
                if ((white_pawn_attacks & bb.SQUARE_BB[sq]) != 0) {
                    mobility_score[0] += mg_knight_outpost[0];
                    mobility_score[1] += eg_knight_outpost[0];
                    if (tnr) |t| t.knight_outpost[0] += 1;
                }
            }

            // Blockade of passed pawn
            if ((pawn_entry.black_passed_front & bb.SQUARE_BB[sq]) != 0) {
                mobility_score[0] += mg_blockade_passer[0];
                mobility_score[1] += eg_blockade_passer[0];
                if (tnr) |t| t.blockade_passer[0] += 1;
            }
            


            var b1 = mobility & black_pawns;
            if (b1 != 0) {
                const pt = PieceType.Pawn;
                tmp_sc = get_knight_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.knight_attacking[0][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }

            b1 = mobility & black_bishop;
            if (b1 != 0) {
                const pt = PieceType.Bishop;
                tmp_sc = get_knight_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.knight_attacking[0][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }    

            b1 = mobility & black_rook;
            if (b1 != 0) {
                const pt = PieceType.Rook;
                tmp_sc = get_knight_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.knight_attacking[0][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }      

            b1 = mobility & black_queen;
            if (b1 != 0) {
                const pt = PieceType.Queen;
                tmp_sc = get_knight_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.knight_attacking[0][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }                                

        }

        pc_bb = black_knight;
        while (pc_bb != 0) {
            const sq = bb.pop_lsb(&pc_bb);
            const att = attacks.KNIGHT_ATTACKS[sq];
            const mobility = att & ~black_pieces;
            black_att |= mobility;
            const index = bb.pop_count(mobility & ~white_pawn_attacks);
            var tmp_sc = get_knight_mobility_score(index);
            if (tnr) |t| t.knight_mobility[1][index] += 1;
            mobility_score[0] -= tmp_sc[0];
            mobility_score[1] -= tmp_sc[1];
            if ((white_king_zone & mobility) != 0) {
                white_danger_score += PieceDangers[PieceType.Knight.toU3()];
                white_danger_pieces += 1;
                black_king_zone_attacks |= (mobility & white_king_zone);
            }

            // Knight outpost
            const rank = position.rank_of_u6(sq);
            if (rank >= 2 and rank <= 4) { // Ranks 4, 5, 6 for black
                if ((black_pawn_attacks & bb.SQUARE_BB[sq]) != 0) {
                    mobility_score[0] -= mg_knight_outpost[0];
                    mobility_score[1] -= eg_knight_outpost[0];
                    if (tnr) |t| t.knight_outpost[1] += 1;
                }
            }

            // Blockade of passed pawn
            if ((pawn_entry.white_passed_front & bb.SQUARE_BB[sq]) != 0) {
                mobility_score[0] -= mg_blockade_passer[0];
                mobility_score[1] -= eg_blockade_passer[0];
                if (tnr) |t| t.blockade_passer[1] += 1;
            }


                      
            var b1 = mobility & white_pawns;
            if (b1 != 0) {
                const pt = PieceType.Pawn;
                tmp_sc = get_knight_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.knight_attacking[1][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }

            b1 = mobility & white_bishop;
            if (b1 != 0) {
                const pt = PieceType.Bishop;
                tmp_sc = get_knight_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.knight_attacking[1][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }    

            b1 = mobility & white_rook;
            if (b1 != 0) {
                const pt = PieceType.Rook;
                tmp_sc = get_knight_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.knight_attacking[1][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }      

            b1 = mobility & white_queen;
            if (b1 != 0) {
                const pt = PieceType.Queen;
                tmp_sc = get_knight_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.knight_attacking[1][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }                                

        }

        pc_bb = white_bishop;
        while (pc_bb != 0) {
            const sq = bb.pop_lsb(&pc_bb);
            const att = attacks.get_bishop_attacks(sq, occ);
            const mobility = att & ~white_pieces;
            white_att |= mobility;
            const index = bb.pop_count(mobility & ~black_pawn_attacks);
            var tmp_sc = get_bishop_mobility_score(index);
            if (tnr) |t| t.bishop_mobility[0][index] += 1;
            mobility_score[0] += tmp_sc[0];
            mobility_score[1] += tmp_sc[1];
            if ((black_king_zone & mobility) != 0) {
                black_danger_score += PieceDangers[PieceType.Bishop.toU3()];
                black_danger_pieces += 1;
                white_king_zone_attacks |= (mobility & black_king_zone);
            }

            // Trapped Bishop
            if (index <= 1) { 
                 if ((sq == Square.a1.toU6() or sq == Square.h1.toU6() or sq == Square.a8.toU6() or sq == Square.h8.toU6())) {
                     mobility_score[0] += mg_trapped_bishop[0];
                     mobility_score[1] += eg_trapped_bishop[0];
                     if (tnr) |t| t.trapped_bishop[0] += 1;
                 }
            }

            // Bishop Outpost
            const rank = position.rank_of_u6(sq);
            if (rank >= 3 and rank <= 5) {
                if ((white_pawn_attacks & bb.SQUARE_BB[sq]) != 0) {
                    mobility_score[0] += mg_bishop_outpost[0];
                    mobility_score[1] += eg_bishop_outpost[0];
                    if (tnr) |t| t.bishop_outpost[0] += 1;
                }
            }
            
            var b1 = mobility & black_pawns;
            if (b1 != 0) {
                const pt = PieceType.Pawn;
                tmp_sc = get_bishop_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.bishop_attacking[0][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }

            b1 = mobility & black_knight;
            if (b1 != 0) {
                const pt = PieceType.Knight;
                tmp_sc = get_bishop_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.bishop_attacking[0][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }    

            b1 = mobility & black_rook;
            if (b1 != 0) {
                const pt = PieceType.Rook;
                tmp_sc = get_bishop_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.bishop_attacking[0][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }      

            b1 = mobility & black_queen;
            if (b1 != 0) {
                const pt = PieceType.Queen;
                tmp_sc = get_bishop_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.bishop_attacking[0][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }   


        }
    

        pc_bb = black_bishop;
        while (pc_bb != 0) {
            const sq = bb.pop_lsb(&pc_bb);
            const att = attacks.get_bishop_attacks(sq, occ);
            const mobility = att & ~black_pieces;
            black_att |= mobility;
            const index = bb.pop_count(mobility & ~white_pawn_attacks);
            var tmp_sc = get_bishop_mobility_score(index);
            if (tnr) |t| t.bishop_mobility[1][index] += 1;
            mobility_score[0] -= tmp_sc[0];
            mobility_score[1] -= tmp_sc[1];
            if ((white_king_zone & mobility) != 0) {
                white_danger_score += PieceDangers[PieceType.Bishop.toU3()];
                white_danger_pieces += 1;
                black_king_zone_attacks |= (mobility & white_king_zone);
            }

            // Trapped Bishop
            if (index <= 1) { 
                 if ((sq == Square.a1.toU6() or sq == Square.h1.toU6() or sq == Square.a8.toU6() or sq == Square.h8.toU6())) {
                     mobility_score[0] -= mg_trapped_bishop[0];
                     mobility_score[1] -= eg_trapped_bishop[0];
                     if (tnr) |t| t.trapped_bishop[1] += 1;
                 }
            }

            // Bishop Outpost
            const rank = position.rank_of_u6(sq);
            if (rank >= 2 and rank <= 4) {
                if ((black_pawn_attacks & bb.SQUARE_BB[sq]) != 0) {
                    mobility_score[0] -= mg_bishop_outpost[0];
                    mobility_score[1] -= eg_bishop_outpost[0];
                    if (tnr) |t| t.bishop_outpost[1] += 1;
                }
            }
            
            var b1 = mobility & white_pawns;
            if (b1 != 0) {
                const pt = PieceType.Pawn;
                tmp_sc = get_bishop_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.bishop_attacking[1][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }

            b1 = mobility & white_knight;
            if (b1 != 0) {
                const pt = PieceType.Knight;
                tmp_sc = get_bishop_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.bishop_attacking[1][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }    

            b1 = mobility & white_rook;
            if (b1 != 0) {
                const pt = PieceType.Rook;
                tmp_sc = get_bishop_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.bishop_attacking[1][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }      

            b1 = mobility & white_queen;
            if (b1 != 0) {
                const pt = PieceType.Queen;
                tmp_sc = get_bishop_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.bishop_attacking[1][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }   



        }         

        pc_bb = white_rook;
        while (pc_bb != 0) {
            const sq = bb.pop_lsb(&pc_bb);
            const att = attacks.get_rook_attacks(sq, occ);
            const mobility = att & ~white_pieces;
            white_att |= mobility;
            const index = bb.pop_count(mobility & ~black_pawn_attacks);
            var tmp_sc = get_rook_mobility_score(index);
            if (tnr) |t| t.rook_mobility[0][index] += 1;
            mobility_score[0] += tmp_sc[0];
            mobility_score[1] += tmp_sc[1];

            if ((black_king_zone & mobility) != 0) {
                black_danger_score += PieceDangers[PieceType.Rook.toU3()];
                black_danger_pieces += 1;
                white_king_zone_attacks |= (mobility & black_king_zone);
            }
            
            // Rook file and rank features
            const file = position.file_of_u6(sq);
            const file_bit = @as(u8, 1) << @intCast(file);
            const white_pawns_on_file = (white_pawn_files & file_bit) != 0;
            const black_pawns_on_file = (black_pawn_files & file_bit) != 0;

            if (!white_pawns_on_file and !black_pawns_on_file) {
                mobility_score[0] += mg_rook_open[0];
                mobility_score[1] += eg_rook_open[0];
                if (tnr) |t| t.rook_open[0] += 1;
            } else if (!white_pawns_on_file) {
                mobility_score[0] += mg_rook_semi_open[0];
                mobility_score[1] += eg_rook_semi_open[0];
                if (tnr) |t| t.rook_semi_open[0] += 1;
            }


            // Trapped Rook
            if (index == 0) { 
                 if ((sq == Square.a1.toU6() or sq == Square.h1.toU6() or sq == Square.a8.toU6() or sq == Square.h8.toU6())) {
                     mobility_score[0] += mg_trapped_rook[0];
                     mobility_score[1] += eg_trapped_rook[0];
                     if (tnr) |t| t.trapped_rook[0] += 1;
                 }
            }
            
            var b1 = mobility & black_pawns;
            if (b1 != 0) {
                const pt = PieceType.Pawn;
                tmp_sc = get_rook_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.rook_attacking[0][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }

            b1 = mobility & black_knight;
            if (b1 != 0) {
                const pt = PieceType.Knight;
                tmp_sc = get_rook_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.rook_attacking[0][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }    

            b1 = mobility & black_bishop;
            if (b1 != 0) {
                const pt = PieceType.Bishop;
                tmp_sc = get_rook_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.rook_attacking[0][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }      

            b1 = mobility & black_queen;
            if (b1 != 0) {
                const pt = PieceType.Queen;
                tmp_sc = get_rook_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.rook_attacking[0][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }             

            // Rook behind passed pawn
            if ((pawn_entry.white_passers & bb.MASK_FILE[file] & WhitePassedPawnFilter[sq]) != 0) {
                 mobility_score[0] += mg_rook_behind_passer[0];
                 mobility_score[1] += eg_rook_behind_passer[0];
                 if (tnr) |t| t.rook_behind_passer[0] += 1;
            }

            // Connected Rooks
            if ((att & pc_bb) != 0) {
                 const conn_count = bb.pop_count(att & pc_bb);
                 mobility_score[0] += mg_connected_rooks[0] * @as(i32, @intCast(conn_count));
                 mobility_score[1] += eg_connected_rooks[0] * @as(i32, @intCast(conn_count));
                 if (tnr) |t| t.connected_rooks[0] += @as(u8, @intCast(conn_count));
            }
        }

        pc_bb = black_rook;
        while (pc_bb != 0) {
            const sq = bb.pop_lsb(&pc_bb);
            const att = attacks.get_rook_attacks(sq, occ);
            const mobility = att & ~black_pieces;
            black_att |= mobility;
            const index = bb.pop_count(mobility & ~white_pawn_attacks);
            var tmp_sc = get_rook_mobility_score(index);
            if (tnr) |t| t.rook_mobility[1][index] += 1;
            mobility_score[0] -= tmp_sc[0];
            mobility_score[1] -= tmp_sc[1];

            if ((white_king_zone & mobility) != 0) {
                white_danger_score += PieceDangers[PieceType.Rook.toU3()];
                white_danger_pieces += 1;
                black_king_zone_attacks |= (mobility & white_king_zone);
            }

            // Rook file and rank features
            const file = position.file_of_u6(sq);
            const file_bit = @as(u8, 1) << @intCast(file);
            const white_pawns_on_file = (white_pawn_files & file_bit) != 0;
            const black_pawns_on_file = (black_pawn_files & file_bit) != 0;

            if (!white_pawns_on_file and !black_pawns_on_file) {
                mobility_score[0] -= mg_rook_open[0];
                mobility_score[1] -= eg_rook_open[0];
                if (tnr) |t| t.rook_open[1] += 1;
            } else if (!black_pawns_on_file) {
                mobility_score[0] -= mg_rook_semi_open[0];
                mobility_score[1] -= eg_rook_semi_open[0];
                if (tnr) |t| t.rook_semi_open[1] += 1;
            }


             // Trapped Rook
            if (index == 0) { 
                 if ((sq == Square.a1.toU6() or sq == Square.h1.toU6() or sq == Square.a8.toU6() or sq == Square.h8.toU6())) {
                     mobility_score[0] -= mg_trapped_rook[0];
                     mobility_score[1] -= eg_trapped_rook[0];
                     if (tnr) |t| t.trapped_rook[1] += 1;
                 }
            }
            
            var b1 = mobility & white_pawns;
            if (b1 != 0) {
                const pt = PieceType.Pawn;
                tmp_sc = get_rook_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.rook_attacking[1][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }

            b1 = mobility & white_knight;
            if (b1 != 0) {
                const pt = PieceType.Knight;
                tmp_sc = get_rook_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.rook_attacking[1][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }    

            b1 = mobility & white_bishop;
            if (b1 != 0) {
                const pt = PieceType.Bishop;
                tmp_sc = get_rook_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.rook_attacking[1][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }      

            b1 = mobility & white_queen;
            if (b1 != 0) {
                const pt = PieceType.Queen;
                tmp_sc = get_rook_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.rook_attacking[1][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }  

            // Rook behind passed pawn
            if ((pawn_entry.black_passers & bb.MASK_FILE[file] & BlackPassedPawnFilter[sq]) != 0) {
                 mobility_score[0] -= mg_rook_behind_passer[0];
                 mobility_score[1] -= eg_rook_behind_passer[0];
                 if (tnr) |t| t.rook_behind_passer[1] += 1;
            }

            // Connected Rooks
            if ((att & pc_bb) != 0) {
                 const conn_count = bb.pop_count(att & pc_bb);
                 mobility_score[0] -= mg_connected_rooks[0] * @as(i32, @intCast(conn_count));
                 mobility_score[1] -= eg_connected_rooks[0] * @as(i32, @intCast(conn_count));
                 if (tnr) |t| t.connected_rooks[1] += @as(u8, @intCast(conn_count));
            }
        }

        pc_bb = white_queen;
        while (pc_bb != 0) {
            const sq = bb.pop_lsb(&pc_bb);
            const att = attacks.get_bishop_attacks(sq, occ) | attacks.get_rook_attacks(sq, occ);
            const mobility = att & ~white_pieces;
            white_att |= mobility;
            const index = bb.pop_count(mobility & ~black_pawn_attacks);
            var tmp_sc = get_queen_mobility_score(index);
            if (tnr) |t| t.queen_mobility[0][index] += 1;
            mobility_score[0] += tmp_sc[0];
            mobility_score[1] += tmp_sc[1];
            if ((black_king_zone & mobility) != 0) {
                black_danger_score += PieceDangers[PieceType.Queen.toU3()];
                black_danger_pieces += 1;
                white_king_zone_attacks |= (mobility & black_king_zone);
            }

            var b1 = mobility & black_pawns;
            if (b1 != 0) {
                const pt = PieceType.Pawn;
                tmp_sc = get_queen_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.queen_attacking[0][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }

            b1 = mobility & black_knight;
            if (b1 != 0) {
                const pt = PieceType.Knight;
                tmp_sc = get_queen_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.queen_attacking[0][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }    

            b1 = mobility & black_bishop;
            if (b1 != 0) {
                const pt = PieceType.Bishop;
                tmp_sc = get_queen_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.queen_attacking[0][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }      

            b1 = mobility & black_rook;
            if (b1 != 0) {
                const pt = PieceType.Rook;
                tmp_sc = get_queen_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] += tmp_sc[0]*tmp_count;                
                threat_score[1] += tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.queen_attacking[0][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }                

        }  

        pc_bb = black_queen;
        while (pc_bb != 0) {
            const sq = bb.pop_lsb(&pc_bb);
            const att = attacks.get_bishop_attacks(sq, occ) | attacks.get_rook_attacks(sq, occ);
            const mobility = att & ~black_pieces;
            black_att |= mobility;
            const index = bb.pop_count(mobility & ~white_pawn_attacks);
            var tmp_sc = get_queen_mobility_score(index);
            if (tnr) |t| t.queen_mobility[1][index] += 1;
            mobility_score[0] -= tmp_sc[0];
            mobility_score[1] -= tmp_sc[1];
            if ((white_king_zone & mobility) != 0) {
                white_danger_score += PieceDangers[PieceType.Queen.toU3()];
                white_danger_pieces += 1;
                black_king_zone_attacks |= (mobility & white_king_zone);
            }

            var b1 = mobility & white_pawns;
            if (b1 != 0) {
                const pt = PieceType.Pawn;
                tmp_sc = get_queen_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.queen_attacking[1][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }

            b1 = mobility & white_knight;
            if (b1 != 0) {
                const pt = PieceType.Knight;
                tmp_sc = get_queen_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.queen_attacking[1][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }    

            b1 = mobility & white_bishop;
            if (b1 != 0) {
                const pt = PieceType.Bishop;
                tmp_sc = get_queen_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.queen_attacking[1][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }      

            b1 = mobility & white_rook;
            if (b1 != 0) {
                const pt = PieceType.Rook;
                tmp_sc = get_queen_threat(pt);
                const tmp_count = bb.pop_count(b1);
                threat_score[0] -= tmp_sc[0]*tmp_count;                
                threat_score[1] -= tmp_sc[1]*tmp_count; 
                if (tnr) |t| t.queen_attacking[1][pt.toU3()] += @as(u8, @intCast(tmp_count));
            }              


        }

        // King safety
        const white_king_safety_final = @divTrunc(white_danger_score * DangerMultipliers[@min(white_danger_pieces, 7)], 100);
        const black_king_safety_final = @divTrunc(black_danger_score * DangerMultipliers[@min(black_danger_pieces, 7)], 100);
        if (white_king_safety_final != 0 ) {
            const idx = @min(@as(usize, @intCast(white_king_safety_final)), 24);
            king_score[0] += mg_king_safety[idx];
            king_score[1] += eg_king_safety[idx];
            if (tnr) |t| t.king_safety[0][idx] += 1;
        }
        if (black_king_safety_final != 0 ) {
            const idx = @min(@as(usize, @intCast(black_king_safety_final)), 24);
            king_score[0] -= mg_king_safety[idx];
            king_score[1] -= eg_king_safety[idx];
            if (tnr) |t| t.king_safety[1][idx] += 1;
        }

        // King Pawn Shield
        const w_shield_sq = bb.get_ls1b_index(pos.bitboard_of_pt(Color.White, PieceType.King));
        const w_shield_count = count_king_pawn_shield(pos, Color.White, w_shield_sq);
        king_score[0] += mg_king_pawn_shield[w_shield_count];
        king_score[1] += eg_king_pawn_shield[w_shield_count];
        if (tnr) |t| t.king_pawn_shield[0][w_shield_count] += 1;

        const b_shield_sq = bb.get_ls1b_index(pos.bitboard_of_pt(Color.Black, PieceType.King));
        const b_shield_count = count_king_pawn_shield(pos, Color.Black, b_shield_sq);
        king_score[0] -= mg_king_pawn_shield[b_shield_count];
        king_score[1] -= eg_king_pawn_shield[b_shield_count];
        if (tnr) |t| t.king_pawn_shield[1][b_shield_count] += 1;

        // Pawn Storm
        const w_storm = get_pawn_storm_score(pos, Color.White, w_shield_sq, tnr);
        king_score[0] += w_storm[0];
        king_score[1] += w_storm[1];

        const b_storm = get_pawn_storm_score(pos, Color.Black, b_shield_sq, tnr);
        king_score[0] -= b_storm[0];
        king_score[1] -= b_storm[1];

        // King proximity (virtual mobility)
        const w_prox_bits = bb.pop_count(white_king_zone_attacks);
        const b_prox_bits = bb.pop_count(black_king_zone_attacks);
        
        king_score[0] += mg_king_virtual_mobility[w_prox_bits];
        king_score[1] += eg_king_virtual_mobility[w_prox_bits];
        if (tnr) |t| t.king_virtual_mobility[0][w_prox_bits] += 1;

        king_score[0] -= mg_king_virtual_mobility[b_prox_bits];
        king_score[1] -= eg_king_virtual_mobility[b_prox_bits];
        if (tnr) |t| t.king_virtual_mobility[1][b_prox_bits] += 1;

        // Bishop pair bonus
        const bb_white_bishops = pos.piece_bb[Piece.WHITE_BISHOP.toU4()];
        if (bb.pop_count(bb_white_bishops) >= 2) {
            if ((bb_white_bishops & bb.WHITE_FIELDS != 0) and (bb_white_bishops & bb.BLACK_FIELDS != 0)) {
                additional_material_score[0] += mg_bishop_pair[0];
                additional_material_score[1] += eg_bishop_pair[0];
                if (tnr) |t| t.bishop_pair[0] += 1;
            }
        }
        const bb_black_bishops = pos.piece_bb[Piece.BLACK_BISHOP.toU4()];
        if (bb.pop_count(bb_black_bishops) >= 2) {
            if ((bb_black_bishops & bb.WHITE_FIELDS != 0) and (bb_black_bishops & bb.BLACK_FIELDS != 0)) {
                additional_material_score[0] -= mg_bishop_pair[0];
                additional_material_score[1] -= eg_bishop_pair[0];
                if (tnr) |t| t.bishop_pair[1] += 1;
            }
        }    

        score[0] = pawn_structure_score[0] + threat_score[0] + king_score[0] + additional_material_score[0] + mobility_score[0];
        score[1] = pawn_structure_score[1] + threat_score[1] + king_score[1] + additional_material_score[1] + mobility_score[1];



        // Tempo
        if (pos.side_to_play == Color.White) {
            score[0] += mg_tempo[0];
            score[1] += eg_tempo[0];
            if (tnr) |t| t.tempo[0] += 1;
        } else {
            score[0] -= mg_tempo[0];
            score[1] -= eg_tempo[0];
            if (tnr) |t| t.tempo[1] += 1;
        }
    
        return score;
    
    }


};


const RankBelowIncl = init: {
    var masks: [8]u64 = undefined;
    var current: u64 = 0;
    for (0..8) |i| {
        current |= bb.MASK_RANK[i];
        masks[i] = current;
    }
    break :init masks;
};

const RankAboveIncl = init: {
    var masks: [8]u64 = undefined;
    var current: u64 = 0;
    for (0..8) |i| {
        current |= bb.MASK_RANK[7 - i];
        masks[7 - i] = current;
    }
    break :init masks;
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

pub const DangerMultipliers = [_]i32{ 0, 30, 60, 80, 90, 95, 100, 100 };
pub const PieceDangers = [_]i32{ 1, 2, 2, 3, 5, 4 };

pub const rook_file_open = [2][2]i32{
    [_]i32{ 29, 13 },
    [_]i32{ 12, 9 },
};

pub const pawn_attacking_major_minor_pieces = [2][2]i32{
    [_]i32{ 51, 56 },
    [_]i32{ 28, 32 },
};



pub  fn get_passed_pawn_score(sq: u6) [2]i32 {
    var score = [_]i32{ 0, 0 };
    score[0] = mg_passed_score[sq];
    score[1] = eg_passed_score[sq];
    return score;
}

pub  fn get_isolated_pawn_score(file: u6) [2]i32 {
    var score = [_]i32{ 0, 0 };
    score[0] += mg_isolated_pawn_score[file];
    score[1] += eg_isolated_pawn_score[file];
    return score;
}

pub  fn get_blocked_passer_score(rank: u6) [2]i32 {
    var score = [_]i32{ 0, 0 };
    score[0] = mg_blocked_passer_score[rank];
    score[1] = eg_blocked_passer_score[rank];
    return score;
}

pub  fn get_pawn_threat(piece_type: PieceType) [2]i32 {
    var score = [_]i32{ 0, 0 };
    const pt = piece_type.toU3();
    score[0] = mg_pawn_attacking[pt];
    score[1] = eg_pawn_attacking[pt];
    return score;
}

inline fn get_pawn_file_mask(b: u64) u8 {
    const f = (b | (b >> 8) | (b >> 16) | (b >> 24) | (b >> 32) | (b >> 40) | (b >> 48) | (b >> 56));
    return @as(u8, @truncate(f & 0xFF));
}

const AdjacentFilesMask = init: {
    var masks: [8]u8 = undefined;
    for (0..8) |f| {
        var m: u8 = 0;
        if (f > 0) m |= @as(u8, 1) << @intCast(f - 1);
        m |= @as(u8, 1) << @intCast(f);
        if (f < 7) m |= @as(u8, 1) << @intCast(f + 1);
        masks[f] = m;
    }
    break :init masks;
};

pub  fn get_knight_threat(piece_type: PieceType) [2]i32 {
    var score = [_]i32{ 0, 0 };
    const pt = piece_type.toU3();
    score[0] = mg_knight_attacking[pt];
    score[1] = eg_knight_attacking[pt];
    return score;
}

pub  fn get_bishop_threat(piece_type: PieceType) [2]i32 {
    var score = [_]i32{ 0, 0 };
    const pt = piece_type.toU3();
    score[0] = mg_bishop_attacking[pt];
    score[1] = eg_bishop_attacking[pt];
    return score;
}

pub  fn get_rook_threat(piece_type: PieceType) [2]i32 {
    var score = [_]i32{ 0, 0 };
    const pt = piece_type.toU3();
    score[0] = mg_rook_attacking[pt];
    score[1] = eg_rook_attacking[pt];
    return score;
}

pub  fn get_queen_threat(piece_type: PieceType) [2]i32 {
    var score = [_]i32{ 0, 0 };
    const pt = piece_type.toU3();
    score[0] = mg_queen_attacking[pt];
    score[1] = eg_queen_attacking[pt];
    return score;
}

pub  fn get_supported_pawn_bonus(rank: u6) [2]i32 {
    var score = [_]i32{ 0, 0 };
    score[0] = mg_supported_pawn[rank];
    score[1] = eg_supported_pawn[rank];
    return score;
}

pub  fn get_phalanx_score(rank: u6) [2]i32 {
    var score = [_]i32{ 0, 0 };
    score[0] = mg_pawn_phalanx[rank];
    score[1] = eg_pawn_phalanx[rank];
    return score;
}

pub  fn get_knight_mobility_score(index: u7) [2]i32 {
    var score = [_]i32{ 0, 0 };
    score[0] = mg_knight_mobility[index];
    score[1] = eg_knight_mobility[index];
    return score;
}

pub  fn get_bishop_mobility_score(index: u7) [2]i32 {
    var score = [_]i32{ 0, 0 };
    score[0] = mg_bishop_mobility[index];
    score[1] = eg_bishop_mobility[index];
    return score;
}

pub  fn get_rook_mobility_score(index: u7) [2]i32 {
    var score = [_]i32{ 0, 0 };
    score[0] = mg_rook_mobility[index];
    score[1] = eg_rook_mobility[index];
    return score;
}

pub  fn get_queen_mobility_score(index: u7) [2]i32 {
    var score = [_]i32{ 0, 0 };
    score[0] = mg_queen_mobility[index];
    score[1] = eg_queen_mobility[index];
    return score;
}


pub fn passed_pawn_support_bonus(pos: *Position, comptime color: Color) i32 {
    var score: i32 = 0;

    const their_color = color.change_side();
    const king_sq = bb.get_ls1b_index(pos.bitboard_of_pt(color, PieceType.King));
    //const all_pieces = pos.all_pieces(Color.White) | pos.all_pieces(Color.Black);

    // Select passed pawn mask and direction based on color
    const passed_mask = if (color == Color.White)
        WhitePassedPawnMask
    else
        BlackPassedPawnMask;

    const pawns = pos.bitboard_of_pt(color, PieceType.Pawn);
    var b = pawns;

    while (b != 0) {
        const sq = bb.pop_lsb(&b);
        // Check if it's a passed pawn
        if ((passed_mask[sq] & pos.bitboard_of_pt(their_color, PieceType.Pawn)) == 0) {
            // Distance from king to pawn
            const pawn_rank = position.rank_of_u6(sq);
            const pawn_file = position.file_of_u6(sq);
            const king_rank = position.rank_of_u6(king_sq);
            const king_file = position.file_of_u6(king_sq);

            const dist = @abs(king_rank - pawn_rank) + @abs(king_file - pawn_file);

            // Closer king gets more bonus
            const bonus: i32 = switch (dist) {
                1 => 40,
                2 => 30,
                3 => 20,
                4 => 10,
                else => 0,
            };

            score += bonus;
        }
    }

    return score;
}


pub fn evaluate_pawn_race(pos: *Position, perspective: Color) i32 {
    var score: i32 = 0;

    const white_king_sq = bb.get_ls1b_index(pos.bitboard_of_pt(Color.White, PieceType.King));
    const black_king_sq = bb.get_ls1b_index(pos.bitboard_of_pt(Color.Black, PieceType.King));

    // Find closest white and black pawns to promotion
    var min_white_dist: i32 = 8;
    var min_black_dist: i32 = 8;

    // Evaluate white pawns
    var w_pawns = pos.bitboard_of_pt(Color.White, PieceType.Pawn);
    while (w_pawns != 0) {
        const sq = bb.pop_lsb(&w_pawns);
        const r = position.rank_of_u6(sq);
        const dist = 7 - r; // distance to 8th rank
        if (dist < min_white_dist) {
            min_white_dist = dist;
        }
    }

    // Evaluate black pawns
    var b_pawns = pos.bitboard_of_pt(Color.Black, PieceType.Pawn);
    while (b_pawns != 0) {
        const sq = bb.pop_lsb(&b_pawns);
        const r = position.rank_of_u6(sq);
        const dist = r; // distance to 1st rank
        if (dist < min_black_dist) {
            min_black_dist = dist;
        }
    }

    // If no pawns on one or both sides, not a pawn race
    if (min_white_dist == 8 or min_black_dist == 8) return 0;

    // Tempo matters: side to move gets +1 advantage
    const tempo: i32 = if (pos.side_to_play == perspective) 1 else 0;

    // Calculate effective distances (king support)
    const wk_rank = position.rank_of_u6(white_king_sq);
    const wk_file = position.file_of_u6(white_king_sq);
    const bk_rank = position.rank_of_u6(black_king_sq);
    const bk_file = position.file_of_u6(black_king_sq);

    // Distance from kings to the target squares
    const white_king_to_target = @abs(wk_rank - 7) + @abs(wk_file - position.file_of_u6(bb.get_ls1b_index(pos.bitboard_of_pt(Color.White, PieceType.Pawn))));
    const black_king_to_target = @abs(bk_rank - 0) + @abs(bk_file - position.file_of_u6(bb.get_ls1b_index(pos.bitboard_of_pt(Color.Black, PieceType.Pawn))));

    // Adjusted race formula:
    // Positive score favors white, negative favors black
    const white_score = min_white_dist - ((white_king_to_target + 1) / 2) + tempo;
    const black_score = min_black_dist - ((black_king_to_target + 1) / 2);

    if (white_score < black_score) {
        score += 50; // White is ahead in race
    } else if (black_score < white_score) {
        score -= 50; // Black is ahead
    }

    return score;
}

fn distance_to_center(sq: u6) i32 {
    return @as(i32, distance(sq, @as(u6, 27)));
}

fn king_activity_in_bishop_knight_endings(pos: *Position) i32 {
    var score: i32 = 0;

    const white_king = bb.get_ls1b_index(pos.bitboard_of_pt(Color.White, PieceType.King));
    const black_king = bb.get_ls1b_index(pos.bitboard_of_pt(Color.Black, PieceType.King));

    const white_bishop = pos.bitboard_of_pt(Color.White, PieceType.Bishop);
    const black_bishop = pos.bitboard_of_pt(Color.Black, PieceType.Bishop);
    const white_knight = pos.bitboard_of_pt(Color.White, PieceType.Knight);
    const black_knight = pos.bitboard_of_pt(Color.Black, PieceType.Knight);

    // Helper to calculate king activity advantage
    const calc_king_activity = struct {
        fn eval(_white_king: u6, _black_king: u6, is_white_bishop_side: bool) i32 {
            const white_dist = distance_to_center(_white_king);
            const black_dist = distance_to_center(_black_king);
            const diff = if (is_white_bishop_side)
                black_dist - white_dist
            else
                white_dist - black_dist;
            return diff * 5;
        }
    }.eval;

    // Case 1: White has bishop, Black has knight
    if (white_bishop != 0 and black_knight != 0) {
        score += calc_king_activity(white_king, black_king, true);
    }

    // Case 2: Black has bishop, White has knight
    if (black_bishop != 0 and white_knight != 0) {
        score += calc_king_activity(white_king, black_king, false);
    }

    return score;
}

fn bishop_knight_pawn_evaluation(pos: *Position) i32 {
    var score: i32 = 0;

    const white_bishop = pos.bitboard_of_pt(Color.White, PieceType.Bishop);
    const black_bishop = pos.bitboard_of_pt(Color.Black, PieceType.Bishop);
    const white_knight = pos.bitboard_of_pt(Color.White, PieceType.Knight);
    const black_knight = pos.bitboard_of_pt(Color.Black, PieceType.Knight);

    // White bishop vs black knight scenario
    if (white_bishop != 0 and black_knight != 0) {
        const bishop_sq = bb.get_ls1b_index(white_bishop);
        const bishop_color = (position.rank_of_u6(bishop_sq) + position.file_of_u6(bishop_sq)) % 2;

        var pawns = pos.bitboard_of_pt(Color.Black, PieceType.Pawn);
        while (pawns != 0) {
            const sq = bb.pop_lsb(&pawns);
            const pawn_color = (position.rank_of_u6(sq) + position.file_of_u6(sq)) % 2;
            
            // Penalize bishop if enemy pawns are on same color
            if (pawn_color == bishop_color) {
                score += 40;
            }
        }
    }

    // Black bishop vs white knight scenario
    if (black_bishop != 0 and white_knight != 0) {
        const bishop_sq = bb.get_ls1b_index(black_bishop);
        const bishop_color = (position.rank_of_u6(bishop_sq) + position.file_of_u6(bishop_sq)) % 2;

        var pawns = pos.bitboard_of_pt(Color.White, PieceType.Pawn);
        while (pawns != 0) {
            const sq = bb.pop_lsb(&pawns);
            const pawn_color = (position.rank_of_u6(sq) + position.file_of_u6(sq)) % 2;
            
            if (pawn_color == bishop_color) {
                score -= 40;
            }
        }
    }

    return score;
}


fn compare_bishop_knight_mobility(pos: *Position) i32 {
    var score: i32 = 0;

    const white_bishop = pos.bitboard_of_pt(Color.White, PieceType.Bishop);
    const black_bishop = pos.bitboard_of_pt(Color.Black, PieceType.Bishop);
    const white_knight = pos.bitboard_of_pt(Color.White, PieceType.Knight);
    const black_knight = pos.bitboard_of_pt(Color.Black, PieceType.Knight);

    const white_king = pos.bitboard_of_pt(Color.White, PieceType.King);
    const black_king = pos.bitboard_of_pt(Color.Black, PieceType.King);

    // Helper to compute mobility difference in bishop vs knight scenario
    const bishop_knight_compare = struct {
        fn eval(
            pos2: *Position,
            bishop: u64,
            knight: u64,
            is_white: bool,
        ) i32 {
            const occ = pos2.all_pieces(Color.White) | pos2.all_pieces(Color.Black);
            const bishop_sq = bb.get_ls1b_index(bishop);
            const knight_sq = bb.get_ls1b_index(knight);

            const bishop_moves = attacks.get_bishop_attacks(bishop_sq, occ);
            const knight_moves = attacks.piece_attacks(knight_sq, occ, PieceType.Knight);

            const bishop_mob = bb.pop_count(bishop_moves);
            const knight_mob = bb.pop_count(knight_moves);

            const mobility_diff: i32 = @as(i32,bishop_mob) - @as(i32,knight_mob);
            return if (is_white) mobility_diff else -mobility_diff;
        }
    }.eval;

    // Case 1: White Bishop vs Black Knight
    if (white_bishop != 0 and black_knight != 0 and
        (pos.all_pieces(Color.White) == white_bishop | white_king) and
        (pos.all_pieces(Color.Black) == black_knight | black_king))
    {
        score += bishop_knight_compare(pos, white_bishop, black_knight, true) * 8;
    }

    // Case 2: Black Bishop vs White Knight
    if (black_bishop != 0 and white_knight != 0 and
        (pos.all_pieces(Color.White) == white_knight | white_king) and
        (pos.all_pieces(Color.Black) == black_bishop | black_king))
    {
        score += bishop_knight_compare(pos, black_bishop, white_knight, false) * 8;
    }

    return score;
}

fn count_king_pawn_shield(pos: *Position, color: Color, king_sq: u6) usize {
    const file = position.file_of_u6(king_sq);
    const pawns = pos.bitboard_of_pc(Piece.make_piece(color, PieceType.Pawn));
    const relevant_pawns = if (color == Color.White) (pawns & (bb.MASK_RANK[1] | bb.MASK_RANK[2])) else (pawns & (bb.MASK_RANK[6] | bb.MASK_RANK[5]));
    const files_with_pawns = get_pawn_file_mask(relevant_pawns);
    return bb.pop_count(@as(u64, AdjacentFilesMask[file] & files_with_pawns));
}

fn get_pawn_storm_score(pos: *Position, color: Color, king_sq: u6, tnr: ?*tuner.Tuner) [2]i32 {
    const file = position.file_of_u6(king_sq);
    const enemy_color = color.change_side();
    const enemy_pawns = pos.bitboard_of_pc(Piece.make_piece(enemy_color, PieceType.Pawn));
    var score = [_]i32{ 0, 0 };

    const f_min = if (file > 0) file - 1 else 0;
    const f_max = if (file < 7) file + 1 else 7;

    var f = f_min;
    const enemy_pawn_files = get_pawn_file_mask(enemy_pawns);
    const relevant_files = AdjacentFilesMask[file] & enemy_pawn_files;
    if (relevant_files == 0) return score;

    while (f <= f_max) : (f += 1) {
        if ((relevant_files & (@as(u8, 1) << @intCast(f))) == 0) continue;
        const file_bits = bb.MASK_FILE[f];
        const p = enemy_pawns & file_bits;
        if (p != 0) {
            const bucket = if (color == Color.White) blk: {
                const sq = bb.get_ls1b_index(p); // Lowest rank is closest for black pawns attacking white
                const r = position.rank_of_u6(sq);
                if (r <= 1) break :blk @as(usize, 0); // Promotion/Rank 2 (already there? No, Rank 2 is rank 1)
                break :blk @min(@as(usize, r) - 2, 3); // Rank 2 -> 0, Rank 3 -> 1, Rank 4 -> 2, Rank 5+ -> 3
            } else blk: {
                const sq = bb.get_ms1b_index(p); // Highest rank is closest for white pawns attacking black
                const r = position.rank_of_u6(sq);
                if (r >= 6) break :blk @as(usize, 0);
                break :blk @min(5 - @as(usize, r), 3); // Rank 5 -> 0, Rank 4 -> 1, Rank 3 -> 2, Rank 2- -> 3
            };

            score[0] += mg_pawn_storm[bucket];
            score[1] += eg_pawn_storm[bucket];
            if (tnr) |t| t.pawn_storm[@intFromEnum(color)][bucket] += 1;
        }
    }
    return score;
}
