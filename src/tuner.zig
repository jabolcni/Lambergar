const std = @import("std");

pub const NPIECE_TYPES = 6;

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
    rook_open: [2]u8 = undefined,
    rook_semi_open: [2]u8 = undefined,
    knight_outpost: [2]u8 = undefined,
    backward_pawn: [2]u8 = undefined,
    king_pawn_shield: [2][4]u8 = undefined,
    king_virtual_mobility: [2][9]u8 = undefined,
    trapped_bishop: [2]u8 = undefined,
    trapped_rook: [2]u8 = undefined,
    tempo: [2]u8 = undefined,
    rook_behind_passer: [2]u8 = undefined,
    pawn_storm: [2][4]u8 = undefined,
    candidate_pawn: [2][64]u8 = undefined,
    connected_rooks: [2]u8 = undefined,
    blockade_passer: [2]u8 = undefined,
    bishop_outpost: [2]u8 = undefined,
    king_safety: [2][25]u8 = undefined,
    reserved: [134]u8 = undefined,

    pub fn init(self: *Tuner) void {
        self.* = Tuner{
            .pos_count = 0,
        };
        self.clear_probe_arrays();
    }

    pub fn clear_probe_arrays(self: *Tuner) void {
        @memset(self.mat[0][0..NPIECE_TYPES], 0);
        @memset(self.mat[1][0..NPIECE_TYPES], 0);

        for (0..NPIECE_TYPES) |pt| {
            @memset(self.psqt[0][pt][0..64], 0);
            @memset(self.psqt[1][pt][0..64], 0);
        }

        @memset(self.passed_pawn[0][0..64], 0);
        @memset(self.passed_pawn[1][0..64], 0);

        @memset(self.isolated_pawn[0][0..8], 0);
        @memset(self.isolated_pawn[1][0..8], 0);

        @memset(self.blocked_passer[0][0..8], 0);
        @memset(self.blocked_passer[1][0..8], 0);

        @memset(self.supported_pawn[0][0..8], 0);
        @memset(self.supported_pawn[1][0..8], 0);

        @memset(self.pawn_phalanx[0][0..8], 0);
        @memset(self.pawn_phalanx[1][0..8], 0);

        @memset(self.knight_mobility[0][0..9], 0);
        @memset(self.knight_mobility[1][0..9], 0);

        @memset(self.bishop_mobility[0][0..14], 0);
        @memset(self.bishop_mobility[1][0..14], 0);

        @memset(self.rook_mobility[0][0..15], 0);
        @memset(self.rook_mobility[1][0..15], 0);

        @memset(self.queen_mobility[0][0..28], 0);
        @memset(self.queen_mobility[1][0..28], 0);

        @memset(self.pawn_attacking[0][0..6], 0);
        @memset(self.pawn_attacking[1][0..6], 0);

        @memset(self.knight_attacking[0][0..6], 0);
        @memset(self.knight_attacking[1][0..6], 0);

        @memset(self.bishop_attacking[0][0..6], 0);
        @memset(self.bishop_attacking[1][0..6], 0);

        @memset(self.rook_attacking[0][0..6], 0);
        @memset(self.rook_attacking[1][0..6], 0);

        @memset(self.queen_attacking[0][0..6], 0);
        @memset(self.queen_attacking[1][0..6], 0);

        @memset(self.doubled_pawns[0..2], 0);
        @memset(self.bishop_pair[0..2], 0);
        @memset(self.rook_open[0..2], 0);
        @memset(self.rook_semi_open[0..2], 0);
        @memset(self.knight_outpost[0..2], 0);
        @memset(self.backward_pawn[0..2], 0);
        @memset(self.king_pawn_shield[0][0..4], 0);
        @memset(self.king_pawn_shield[1][0..4], 0);
        @memset(self.trapped_bishop[0..2], 0);
        @memset(self.trapped_rook[0..2], 0);
        @memset(self.tempo[0..2], 0);
        @memset(self.rook_behind_passer[0..2], 0);
        @memset(self.pawn_storm[0][0..4], 0);
        @memset(self.pawn_storm[1][0..4], 0);
        @memset(self.candidate_pawn[0][0..64], 0);
        @memset(self.candidate_pawn[1][0..64], 0);
        @memset(self.connected_rooks[0..2], 0);
        @memset(self.blockade_passer[0..2], 0);
        @memset(self.bishop_outpost[0..2], 0);
        for (0..2) |s| @memset(self.king_safety[s][0..25], 0);
        @memset(self.reserved[0..134], 0);

        for (0..2) |side| {
            @memset(self.king_virtual_mobility[side][0..9], 0);
        }
    }

    pub fn new() Tuner {
        var t = Tuner{};
        t.init();
        return t;
    }
};
