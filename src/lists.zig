const std = @import("std");
const position = @import("position.zig");
const search = @import("search.zig");

const MAX_MOVES = search.MAX_MOVES;

const Move = position.Move;
const Piece = position.Piece;
const PieceType = position.PieceType;

pub const MoveList = struct {
    moves: [MAX_MOVES]Move = undefined,
    count: usize = 0,

    pub fn append(self: *MoveList, move: Move) void {
        //if (self.count >= MAX_MOVES) return error.Overflow;
        self.moves[self.count] = move;
        self.count += 1;
    }
};

pub const PieceList = struct {
    pieces: [MAX_MOVES]Piece = undefined,
    count: usize = 0,

    pub fn append(self: *PieceList, piece: Piece) void {
        //if (self.count >= MAX_MOVES) return error.Overflow;
        self.pieces[self.count] = piece;
        self.count += 1;
    }
};

pub const PieceTypeList = struct {
    pieces: [MAX_MOVES]PieceType = undefined,
    count: usize = 0,

    pub fn append(self: *PieceTypeList, piece: PieceType) void {
        //if (self.count >= MAX_MOVES) return error.Overflow;
        self.pieces[self.count] = piece;
        self.count += 1;
    }
};

pub const ScoreList = struct {
    scores: [MAX_MOVES]i32 = undefined,
    count: usize = 0,

    pub fn append(self: *ScoreList, score: i32) void {
        //if (self.count >= position.MAX_MOVES) return error.Overflow;
        self.scores[self.count] = score;
        self.count += 1;
    }
};

pub const MoveScoreList = struct {
    moves: [MAX_MOVES]Move = undefined,
    scores: [MAX_MOVES]i32 = undefined,
    count: usize = 0,

    pub fn append(self: *MoveScoreList, move: Move, score: i32) void {
        //if (self.count >= position.MAX_MOVES) return error.Overflow;
        self.moves[self.count] = move;
        self.scores[self.count] = score;
        self.count += 1;
    }
};
