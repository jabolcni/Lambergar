const std = @import("std");
const bb = @import("bitboard.zig");
const zobrist = @import("zobrist.zig");
const attacks = @import("attacks.zig");
const evaluation = @import("evaluation.zig");
const nnue = @import("nnue.zig");

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const Evaluation = evaluation.Evaluation;

const SQUARE_BB = bb.SQUARE_BB;

const get_ls1b_index = bb.get_ls1b_index;

pub const sq_iter = [_]usize{
    0,  1,  2,  3,  4,  5,  6,  7,
    8,  9,  10, 11, 12, 13, 14, 15,
    16, 17, 18, 19, 20, 21, 22, 23,
    24, 25, 26, 27, 28, 29, 30, 31,
    32, 33, 34, 35, 36, 37, 38, 39,
    40, 41, 42, 43, 44, 45, 46, 47,
    48, 49, 50, 51, 52, 53, 54, 55,
    56, 57, 58, 59, 60, 61, 62, 63,
};

pub const sq_to_coord = [65][:0]const u8{
    // zig fmt: off
    "a1", "b1", "c1", "d1", "e1", "f1", "g1", "h1",
    "a2", "b2", "c2", "d2", "e2", "f2", "g2", "h2",
    "a3", "b3", "c3", "d3", "e3", "f3", "g3", "h3",
    "a4", "b4", "c4", "d4", "e4", "f4", "g4", "h4",
    "a5", "b5", "c5", "d5", "e5", "f5", "g5", "h5",
    "a6", "b6", "c6", "d6", "e6", "f6", "g6", "h6",
    "a7", "b7", "c7", "d7", "e7", "f7", "g7", "h7",
    "a8", "b8", "c8", "d8", "e8", "f8", "g8", "h8",
    "None",
    // zig fmt: on
}; 

pub const Square = enum(u7) {
    // zig fmt: off
    a1, b1, c1, d1, e1, f1, g1, h1,
    a2, b2, c2, d2, e2, f2, g2, h2,
    a3, b3, c3, d3, e3, f3, g3, h3,
    a4, b4, c4, d4, e4, f4, g4, h4,
    a5, b5, c5, d5, e5, f5, g5, h5,
    a6, b6, c6, d6, e6, f6, g6, h6,
    a7, b7, c7, d7, e7, f7, g7, h7,
    a8, b8, c8, d8, e8, f8, g8, h8,
    NO_SQUARE,
    // zig fmt: on

    pub inline fn toU(self: Square) usize {
        return @as(usize, @intFromEnum(self));
    }

    pub inline fn toU7(self: Square) u7 {
        return @as(u7, @intFromEnum(self));
    }

    pub inline fn toU6(self: Square) u6 {
        return @as(u6, @truncate(@intFromEnum(self)));
    }

    pub inline fn fromInt(square: usize) Square {
        return @enumFromInt(square);
    }

    pub inline fn fromU6(square: u6) Square {
        return @enumFromInt(square);
    }

    pub inline fn from_str(str: []const u8) Square {
        return @enumFromInt((str[1] - '1') * 8 + (str[0] - 'a'));
    }

    pub inline fn rank_of(self: Square) Rank {
        return @as(Rank, @enumFromInt(@intFromEnum(self) >> 3));
    }

    pub inline fn file_of(self: Square) File {
        return @as(File, @enumFromInt(@intFromEnum(self) & 0b111));
    }

    pub inline fn diagonal_of(self: Square) u4 {
        return (7 + @as(u4, @intCast(self.rank_of().toU3())) - @as(u4, @intCast(self.file_of().toU3())));
    }

    pub inline fn anti_diagonal_of(self: Square) u4 {
        return @as(u4, @intCast(self.rank_of().toU3())) + @as(u4, @intCast(self.file_of().toU3()));
    }

    pub inline fn create_square(f: File, r: Rank) Square {
        return @as(Square, @enumFromInt(@intFromEnum(f) | (@intFromEnum(r) << 3)));
    }
};

pub inline fn rank_of_iter(sq: usize) usize {
    return sq >> 3;
}

pub inline fn rank_of_isize(sq: usize) isize {
    return @as(isize, @intCast(sq >> 3));
}

pub inline fn rank_of_u6(sq: u6) u6 {
    return sq >> 3;
}

pub inline fn relative_rank_of_u6(sq: u6, comptime c: Color) u6 {
    const rank = rank_of_u6(sq);
    return if (c == Color.White) rank else 7 - rank;
}

pub inline fn file_of_iter(sq: usize) usize {
    return sq & 0b111;
}

pub inline fn file_of_isize(sq: usize) isize {
    return @as(isize, @intCast(sq & 0b111));
}

pub inline fn file_of_u6(sq: u6) u6 {
    return sq & 0b111;
}

pub inline fn diagonal_of_iter(sq: usize) usize {
    return 7 + rank_of_iter(sq) - file_of_iter(sq);
}

pub inline fn diagonal_of_u6(sq: u6) u6 {
    return 7 + rank_of_u6(sq) - file_of_u6(sq);
}

pub inline fn anti_diagonal_of_iter(sq: usize) usize {
    return rank_of_iter(sq) + file_of_iter(sq);
}

pub inline fn anti_diagonal_of_u6(sq: u6) u6 {
    return rank_of_u6(sq) + file_of_u6(sq);
}

pub inline fn shift(b: u64, comptime d: Direction) u64 {
    return switch (d) {
        Direction.NORTH => b << 8,
        Direction.SOUTH => b >> 8,
        Direction.NORTH_NORTH => b << 16,
        Direction.SOUTH_SOUTH => b >> 16,
        Direction.EAST => (b & ~bb.MASK_FILE[File.HFILE.toU3()]) << 1,
        Direction.WEST => (b & ~bb.MASK_FILE[File.AFILE.toU3()]) >> 1,
        Direction.NORTH_EAST => (b & ~bb.MASK_FILE[File.HFILE.toU3()]) << 9,
        Direction.NORTH_WEST => (b & ~bb.MASK_FILE[File.AFILE.toU3()]) << 7,
        Direction.SOUTH_EAST => (b & ~bb.MASK_FILE[File.HFILE.toU3()]) >> 7,
        Direction.SOUTH_WEST => (b & ~bb.MASK_FILE[File.AFILE.toU3()]) >> 9,
    };
}

pub const MOVE_TYPESTR = [_][:0]const u8{ "", "", " O-O", " O-O-O", "N", "B", "R", "Q", " (capture)", "", " e.p.", "", "N", "B", "R", "Q" };
pub const PROM_TYPESTR = [_][:0]const u8{ "", "", "", "", "n", "b", "r", "q", "", "", "", "", "n", "b", "r", "q" };

pub const NCOLORS: usize = 2;
pub const Color = enum(u4) {
    White,
    Black,

    pub inline fn change_side(self: Color) Color {
        return @as(Color, @enumFromInt(@intFromEnum(self) ^ 1));
        //return if (self == Color.White) Color.Black else Color.White;
    }

    pub inline fn toU4(self: Color) u4 {
        return @as(u4, @truncate(@intFromEnum(self)));
    }
};

pub const NDIRS: usize = 8;
pub const Direction = enum(i8) {
    NORTH = 8,
    NORTH_EAST = 9,
    EAST = 1,
    SOUTH_EAST = -7,
    SOUTH = -8,
    SOUTH_WEST = -9,
    WEST = -1,
    NORTH_WEST = 7,

    // Double Push
    NORTH_NORTH = 16,
    SOUTH_SOUTH = -16,

    pub inline fn relative_dir(self: Direction, comptime c: Color) Direction {
        return if (c == Color.White) self else @as(Direction, @enumFromInt(-@intFromEnum(self)));
    }

    pub inline fn toI8(self: Direction) i8 {
        return @intFromEnum(self);
    }
};

pub const NPIECE_TYPES: usize = 6;
pub const PieceType = enum(u3) {
    Pawn,
    Knight,
    Bishop,
    Rook,
    Queen,
    King,
    NoType,

    pub inline fn toU3(self: PieceType) u3 {
        return @intFromEnum(self);
    }

    pub inline fn make(pt: u3) PieceType {
        return @as(PieceType, @enumFromInt(pt));
    }
};

pub const PIECE_STR = "PNBRQK~>pnbrqk.";
pub const unicodePIECE_STR = &[_][]const u8{
    // zig fmt: off
    "♟︎", "♞", "♝", "♜", "♛", "♚", "~", ">",
    "♙", "♘", "♗", "♖", "♕", "♔", ".",
    // zig fmt: on
};

pub const NPIECES: usize = 15;
pub const Piece = enum(u4) {
    WHITE_PAWN,
    WHITE_KNIGHT,
    WHITE_BISHOP,
    WHITE_ROOK,
    WHITE_QUEEN,
    WHITE_KING,
    BLACK_PAWN = 8,
    BLACK_KNIGHT,
    BLACK_BISHOP,
    BLACK_ROOK,
    BLACK_QUEEN,
    BLACK_KING,
    NO_PIECE,

    pub inline fn make_piece(c: Color, pt: PieceType) Piece {
        return @as(Piece, @enumFromInt((@intFromEnum(c) << 3) + @intFromEnum(pt)));
    }

    pub inline fn new(comptime c: Color, comptime pt: PieceType) Piece {
        return @as(Piece, @enumFromInt((@intFromEnum(c) << 3) + @intFromEnum(pt)));
    }

    pub inline fn type_of(self: Piece) PieceType {
        return @as(PieceType, @enumFromInt(@intFromEnum(self) & 0b111));
    }

    pub inline fn color(self: Piece) Color {
        return @as(Color, @enumFromInt((@intFromEnum(self) & 0b1000) >> 3));
    }

    pub inline fn toU4(self: Piece) u4 {
        return @as(u4, @intFromEnum(self));
    }
};

pub const File = enum(u3) {
    AFILE,
    BFILE,
    CFILE,
    DFILE,
    EFILE,
    FFILE,
    GFILE,
    HFILE,

    pub inline fn toU3(self: File) u3 {
        return @intFromEnum(self);
    }
};

pub const Rank = enum(u3) {
    RANK1,
    RANK2,
    RANK3,
    RANK4,
    RANK5,
    RANK6,
    RANK7,
    RANK8,

    pub inline fn toU3(self: Rank) u3 {
        return @intFromEnum(self);
    }

    pub inline fn toU6(self: Rank) u6 {
        return @intFromEnum(self);
    }
    

    pub inline fn relative_rank(self: Rank, comptime c: Color) Rank {
        return if (c == Color.White) self else @as(Rank, @enumFromInt(Rank.RANK8.toU3() - self.toU3()));
    }
};

pub const MoveFlags = enum(u4) {
    QUIET = 0b0000, // 0
    DOUBLE_PUSH = 0b0001, // 1
    OO = 0b0010, // 2 
    OOO = 0b0011, // 3
    CAPTURE = 0b1000, // 8
    CAPTURES = 0b1011, // 11
    EN_PASSANT = 0b1010, // 10

    PR_KNIGHT = 0b0100, // 4
    PR_BISHOP = 0b0101, // 5
    PR_ROOK =   0b0110, // 6
    PR_QUEEN =  0b0111, // 7
    PC_KNIGHT = 0b1100, // 12
    PC_BISHOP = 0b1101, // 13
    PC_ROOK =   0b1110, // 14
    PC_QUEEN =  0b1111, // 15

    pub inline fn toU4(self: MoveFlags) u4 {
        return @intFromEnum(self);
    }

    pub inline fn fromU4(from_u4: u4) MoveFlags {
        return @enumFromInt(from_u4);
    }

    pub inline fn promote_type(self: MoveFlags) PieceType {
        return switch (self) {
            MoveFlags.PR_KNIGHT => PieceType.Knight,
            MoveFlags.PR_BISHOP => PieceType.Bishop,
            MoveFlags.PR_ROOK => PieceType.Rook,
            MoveFlags.PR_QUEEN => PieceType.Queen,
            MoveFlags.PC_KNIGHT => PieceType.Knight,
            MoveFlags.PC_BISHOP => PieceType.Bishop,
            MoveFlags.PC_ROOK => PieceType.Rook,
            MoveFlags.PC_QUEEN => PieceType.Queen,            
            else => PieceType.NoType,
        };
    }
};

const MoveParseError = error{
    IllegalMove,
};

pub const Move = packed struct {
    from: u6,
    to: u6,
    flags: MoveFlags,

    pub inline fn empty() Move {
        return Move{
            .from = 0,
            .to = 0,
            .flags = MoveFlags.QUIET,
        };
    }

    pub fn new(from: Square, to: Square, flags: MoveFlags) Move {
        return Move{
            .from = from.toU6(),
            .to = to.toU6(),
            .flags = flags,
        };
    }

    pub inline fn is_capture(self: Move) bool {
        const flag: u4 = self.flags.toU4();
        //std.debug.print("flag = {}\n", .{flag}); 
        const is_not_capture: bool = flag & MoveFlags.CAPTURE.toU4() == 0;
        //std.debug.print("is_capture = {}\n", .{!is_not_capture});
        return if (is_not_capture) false else true;
    }

    pub inline fn is_promotion(self: Move) bool {
        //return ( (self.flags.toU4() >= MoveFlags.PR_KNIGHT.toU4() and self.flags.toU4() <= MoveFlags.PR_QUEEN.toU4()) or (self.flags.toU4() >= MoveFlags.PC_KNIGHT.toU4() and self.flags.toU4() <= MoveFlags.PC_QUEEN.toU4()) );
        return (self.flags.promote_type() != PieceType.NoType);
    }

    pub inline fn is_promotion_with_capture(self: Move) bool {
        return ( self.flags.toU4() >= MoveFlags.PC_KNIGHT.toU4() and self.flags.toU4() <= MoveFlags.PC_QUEEN.toU4() );
    }    

    pub inline fn is_promotion_no_capture(self: Move) bool {
        return ( self.flags.toU4() >= MoveFlags.PR_KNIGHT.toU4() and self.flags.toU4() <= MoveFlags.PR_QUEEN.toU4() );
    } 

    pub inline fn is_tactical(self: Move) bool {
        //std.debug.print("is_tactical\n", .{});
        return (self.is_capture() or self.is_promotion());
        //return if (self.is_capture()) true else false;
    }

    pub inline fn is_quiet(self: Move) bool {
        //std.debug.print("is_quiet\n", .{});
        return if (self.is_tactical()) false else true;
    }

    pub inline fn equal(self: Move, a: Move) bool {
        return std.meta.eql(self, a);
    }

    pub inline fn is_empty(self: Move) bool {
        return self.equal(Move.empty());
    }

    pub fn to_str(self: Move, allocator: Allocator) []const u8 {
        if (self.is_promotion()) {
            var move_str = allocator.alloc(u8, 5) catch unreachable;

            //std.mem.copyBackwards(comptime T: type, dest: []T, source: []const T)

            std.mem.copyBackwards(u8, move_str[0..2], sq_to_coord[self.from]);
            std.mem.copyBackwards(u8, move_str[2..4], sq_to_coord[self.to]);
            move_str[4] = PROM_TYPESTR[self.flags.toU4()][0];
            return move_str;
        } else {
            var move_str = allocator.alloc(u8, 4) catch unreachable;
            std.mem.copyBackwards(u8, move_str[0..2], sq_to_coord[self.from]);
            std.mem.copyBackwards(u8, move_str[2..4], sq_to_coord[self.to]);
            return move_str;
        }

    }

    pub fn parse_move(move_str: []const u8, pos: *Position) !Move {
        const from = Square.from_str(move_str[0..2]).toU6();
        const to = Square.from_str(move_str[2..4]).toU6();

        var list = std.ArrayList(Move).initCapacity(std.heap.c_allocator, 48) catch unreachable;
        defer list.deinit();

        if (pos.side_to_play == Color.White) {
            pos.generate_legals(Color.White, &list);
        } else {
            pos.generate_legals(Color.Black, &list);
        }

        for (list.items) |move| {
            if (move.from == from and move.to == to) {
                if (move.is_promotion()) {
                    if (PROM_TYPESTR[move.flags.toU4()][0] != move_str[4])
                        continue;
                }
                return move;
            }
        }
        return MoveParseError.IllegalMove;
    }


    pub fn print(self: Move) void {
        std.debug.print("{s}{s}{s}", .{
            sq_to_coord[self.from],
            sq_to_coord[self.to],
            MOVE_TYPESTR[self.flags.toU4()]
        });
        // std.debug.print("{s}{s}", .{
        //     sq_to_coord[self.from],
        //     sq_to_coord[self.to]
        // });        
    }

};

pub inline fn make(sq_from: Square, to: u64, comptime flag: MoveFlags, move_list: *ArrayList(Move)) void {
    var b = to;
    while (b != 0) {
        move_list.append(Move.new(sq_from, Square.fromU6(bb.pop_lsb(&b)), flag)) catch unreachable;
    }
}

pub const Castling = enum(u4) {
    WK = 1,
    WQ = 2,
    BK = 4,
    BQ = 8,
    ALL = 15, 

    pub inline fn toU4(self: Castling) u4 {
        return @as(u4, @intFromEnum(self));
    }       
};

pub const WHITE_OO_MASK: u64 = 0x90;
pub const WHITE_OOO_MASK: u64 = 0x11;

pub const WHITE_OO_BLOCKERS_AND_ATTACKERS_MASK: u64 = 0x60;
pub const WHITE_OOO_BLOCKERS_AND_ATTACKERS_MASK: u64 = 0xe;

pub const BLACK_OO_MASK: u64 = 0x9000000000000000;
pub const BLACK_OOO_MASK: u64 = 0x1100000000000000;

pub const BLACK_OO_BLOCKERS_AND_ATTACKERS_MASK: u64 = 0x6000000000000000;
pub const BLACK_OOO_BLOCKERS_AND_ATTACKERS_MASK: u64 = 0xe00000000000000;

pub const ALL_CASTLING_MASK: u64 = 0x9100000000000091;

pub inline fn oo_mask(comptime c: Color) u64 {
    return if (c == Color.White) WHITE_OO_MASK else BLACK_OO_MASK;
}

pub inline fn ooo_mask(comptime c: Color) u64 {
    return if (c == Color.White) WHITE_OOO_MASK else BLACK_OOO_MASK;
}

pub inline fn oo_blockers_mask(comptime c: Color) u64 {
    return if (c == Color.White) WHITE_OO_BLOCKERS_AND_ATTACKERS_MASK else BLACK_OO_BLOCKERS_AND_ATTACKERS_MASK;
}

pub inline fn ooo_blockers_mask(comptime c: Color) u64 {
    return if (c == Color.White) WHITE_OOO_BLOCKERS_AND_ATTACKERS_MASK else BLACK_OOO_BLOCKERS_AND_ATTACKERS_MASK;
}

pub inline fn ignore_ooo_danger(comptime c: Color) u64 {
    return if (c == Color.White) 0x2 else 0x200000000000000;
}

//Stores position information which cannot be recovered on undo-ing a move
//pub const UndoInfo = packed struct {
pub const UndoInfo = struct {
    entry: u64,
    captured: Piece,
    epsq: Square,
    fifty: u16,
    castling: u4,
    hash_key: u64,
    accumulator: nnue.Accumulator,

    pub fn new() UndoInfo {
        return UndoInfo{
            .entry = 0,
            .captured = Piece.NO_PIECE,
            .epsq = Square.NO_SQUARE,
            .fifty = 0,
            .castling = 0,
            .hash_key = 0,
            .accumulator = nnue.Accumulator{.computed_accumulation = false, .computed_score = false,},
        };
    }

    pub fn copy(prev: UndoInfo) UndoInfo {
        return UndoInfo{
            .entry = prev.entry,
            .captured = Piece.NO_PIECE,
            .epsq = Square.NO_SQUARE,
            .fifty = prev.fifty + 1,
            .castling = prev.castling,
            .hash_key = prev.hash_key,
            .accumulator = nnue.Accumulator{.computed_accumulation = false, .computed_score = false,},
        };
    }
};

pub const Position = struct {
    piece_bb: [NPIECES]u64 = undefined,
    board: [64]Piece = undefined,
    side_to_play: Color = undefined,
    game_ply: u16 = undefined,
    hash: u64 = undefined,

    history: [2048]UndoInfo = undefined,
    checkers: u64 = undefined,
    pinned: u64 = undefined,

    eval: Evaluation = undefined,
    delta: nnue.DeltaPieces = nnue.DeltaPieces{},

    pub fn new() Position {
        var pos = Position{};

        @memset(pos.piece_bb[0..NPIECES], @as(u64, 0));
        pos.side_to_play = Color.White;
        pos.game_ply = 0;
        @memset(pos.board[0..64], Piece.NO_PIECE);
        pos.hash = 0;
        pos.pinned = 0;
        pos.checkers = 0;
        pos.history[0] = UndoInfo.new();
        pos.eval.eval_mg = 0;
        pos.eval.eval_eg = 0;
        pos.eval.phase = [1]u8{0} ** 2;
        pos.delta = nnue.DeltaPieces{};

        return pos;
    }

    pub fn copy(from: Position) Position {
        return Position{
            .piece_bb = from.piece_bb,
            .board = from.board,
            .side_to_play = from.side_to_play,
            .game_ply = from.game_ply,
            .hash = from.hash,
            .history = from.history,
            .checkers = from.checkers,
            .pinned = from.pinned,
            .eval = from.eval,
            .delta = nnue.DeltaPieces{},
        };
    }

    pub inline fn add_piece_to_board(self: *Position, pc: Piece, s_idx: u6) void {
        const pc_idx = pc.toU4();

        self.board[s_idx] = pc;
        self.piece_bb[pc_idx] |= SQUARE_BB[s_idx];

        self.hash ^= zobrist.zobrist_table[pc_idx][s_idx];
        self.eval.put_piece(pc, s_idx);
    } 

    pub inline fn put_piece(self: *Position, pc: Piece, s_idx: u6) void {
        const pc_idx = pc.toU4();

        self.board[s_idx] = pc;
        self.piece_bb[pc_idx] |= SQUARE_BB[s_idx];

        self.hash ^= zobrist.zobrist_table[pc_idx][s_idx];

        if (nnue.engine_using_nnue) {        
            self.eval.put_piece_update_phase(pc);
        } else {
            self.eval.put_piece(pc, s_idx);
        } 
    }

    pub inline fn remove_piece(self: *Position, s_idx: u6) void {
        const pc = self.board[s_idx];
        const pc_idx = pc.toU4();

        self.piece_bb[pc_idx] &= ~SQUARE_BB[s_idx];
        self.board[s_idx] = Piece.NO_PIECE;

        self.hash ^= zobrist.zobrist_table[pc_idx][s_idx];

        if (nnue.engine_using_nnue) {        
            self.eval.remove_piece_update_phase(pc);
        } else {
            self.eval.remove_piece(pc, s_idx);
        }    
    }

    pub inline fn move_piece(self: *Position, from: u6, to: u6) void {
        
        var from_pc = self.board[from];
        const from_idx = from_pc.toU4();
        var to_pc = self.board[to];
        const to_idx = to_pc.toU4();

        self.hash ^= zobrist.zobrist_table[from_idx][from] ^ zobrist.zobrist_table[from_idx][to] ^ zobrist.zobrist_table[to_idx][to];
        const mask = SQUARE_BB[from] | SQUARE_BB[to];
        self.piece_bb[from_idx] ^= mask;
        self.piece_bb[to_idx] &= ~mask;
        self.board[to] = self.board[from];
        self.board[from] = Piece.NO_PIECE;

        if (nnue.engine_using_nnue) {        
            self.eval.move_piece_update_phase(to_pc);
        } else {
            self.eval.move_piece(from_pc, to_pc, from, to);
        }           
    }

    pub inline fn move_piece_quiet(self: *Position, from: u6, to: u6) void {
        var from_pc = self.board[from];
        const from_idx = from_pc.toU4();
        
        self.hash ^= zobrist.zobrist_table[from_idx][from] ^ zobrist.zobrist_table[from_idx][to];

        self.piece_bb[from_idx] ^= (SQUARE_BB[from] | SQUARE_BB[to]);
        self.board[to] = self.board[from];
        self.board[from] = Piece.NO_PIECE;

        if (nnue.engine_using_nnue) {        
             //self.delta.move_piece_quiet(from_pc, from, to);
        } else {
            self.eval.move_piece_quiet(from_pc, from, to);
        } 

    }

    pub inline fn move_promote_capture(self: *Position, from: u6, to: u6, prom_pc: Piece) void {

        const captured = self.board[to];
        const capturer = self.board[from];
        self.remove_piece(from);
        self.history[self.game_ply].captured = captured;
        self.remove_piece(to);

        //self.put_piece(Piece.new(C, PieceType.Queen), m.to);
                
        self.put_piece(prom_pc, to);

        if (nnue.engine_using_nnue) {
            self.delta.remove_piece(capturer, from);
            self.delta.remove_piece(captured, to);
            self.delta.put_piece(prom_pc, to);
        }         

    } 

    pub inline fn bitboard_of_pc(self: *Position, pc: Piece) u64 {
        return self.piece_bb[pc.toU4()];
    }

    pub inline fn bitboard_of_pt(self: *Position, comptime c: Color, pt: PieceType) u64 {
        return self.piece_bb[Piece.new(c, pt).toU4()];
    }

    //Returns the bitboard of all bishops and queens of a given color
    pub inline fn diagonal_sliders(self: *Position, comptime C: Color) u64 {
        return if (C == Color.White) self.piece_bb[Piece.WHITE_BISHOP.toU4()] | self.piece_bb[Piece.WHITE_QUEEN.toU4()] else
        self.piece_bb[Piece.BLACK_BISHOP.toU4()] | self.piece_bb[Piece.BLACK_QUEEN.toU4()];    
    }

    //Returns the bitboard of all rooks and queens of a given color
    pub inline fn orthogonal_sliders(self: *Position, comptime C: Color) u64 {
        return if (C == Color.White) self.piece_bb[Piece.WHITE_ROOK.toU4()] | self.piece_bb[Piece.WHITE_QUEEN.toU4()] else
        self.piece_bb[Piece.BLACK_ROOK.toU4()] | self.piece_bb[Piece.BLACK_QUEEN.toU4()];    
    }   

    //Returns a bitboard containing all the pieces of a given color
    pub inline fn all_pieces(self: *Position, comptime C: Color) u64 {
        return if (C == Color.White) self.piece_bb[Piece.WHITE_PAWN.toU4()] | self.piece_bb[Piece.WHITE_KNIGHT.toU4()] | self.piece_bb[Piece.WHITE_BISHOP.toU4()] | self.piece_bb[Piece.WHITE_ROOK.toU4()] | self.piece_bb[Piece.WHITE_QUEEN.toU4()] | self.piece_bb[Piece.WHITE_KING.toU4()] else
        self.piece_bb[Piece.BLACK_PAWN.toU4()] | self.piece_bb[Piece.BLACK_KNIGHT.toU4()] | self.piece_bb[Piece.BLACK_BISHOP.toU4()] | self.piece_bb[Piece.BLACK_ROOK.toU4()] | self.piece_bb[Piece.BLACK_QUEEN.toU4()] | self.piece_bb[Piece.BLACK_KING.toU4()];    
    }  

    pub inline fn all_white_pieces(self: *Position) u64 {
        return self.piece_bb[Piece.WHITE_PAWN.toU4()] | self.piece_bb[Piece.WHITE_KNIGHT.toU4()] | self.piece_bb[Piece.WHITE_BISHOP.toU4()] | self.piece_bb[Piece.WHITE_ROOK.toU4()] | self.piece_bb[Piece.WHITE_QUEEN.toU4()] | self.piece_bb[Piece.WHITE_KING.toU4()];    
    } 

    pub inline fn all_black_pieces(self: *Position) u64 {
        return self.piece_bb[Piece.BLACK_PAWN.toU4()] | self.piece_bb[Piece.BLACK_KNIGHT.toU4()] | self.piece_bb[Piece.BLACK_BISHOP.toU4()] | self.piece_bb[Piece.BLACK_ROOK.toU4()] | self.piece_bb[Piece.BLACK_QUEEN.toU4()] | self.piece_bb[Piece.BLACK_KING.toU4()];    
    }        

    pub inline fn attackers_from(self: *Position, s: u6, occ: u64, comptime C: Color) u64 {
        return if (C == Color.White) 
        (attacks.pawn_attacks_from_square(s, Color.Black) & self.piece_bb[Piece.WHITE_PAWN.toU4()]) | 
        (attacks.piece_attacks(s, occ, PieceType.Knight) & self.piece_bb[Piece.WHITE_KNIGHT.toU4()]) | 
        (attacks.piece_attacks(s, occ, PieceType.Bishop) & (self.piece_bb[Piece.WHITE_BISHOP.toU4()] | self.piece_bb[Piece.WHITE_QUEEN.toU4()])) | 
        (attacks.piece_attacks(s, occ, PieceType.Rook) & (self.piece_bb[Piece.WHITE_ROOK.toU4()] | self.piece_bb[Piece.WHITE_QUEEN.toU4()]))
        else 
        (attacks.pawn_attacks_from_square(s, Color.White) & self.piece_bb[Piece.BLACK_PAWN.toU4()]) | 
        (attacks.piece_attacks(s, occ, PieceType.Knight) & self.piece_bb[Piece.BLACK_KNIGHT.toU4()]) | 
        (attacks.piece_attacks(s, occ, PieceType.Bishop) & (self.piece_bb[Piece.BLACK_BISHOP.toU4()] | self.piece_bb[Piece.BLACK_QUEEN.toU4()])) | 
        (attacks.piece_attacks(s, occ, PieceType.Rook) & (self.piece_bb[Piece.BLACK_ROOK.toU4()] | self.piece_bb[Piece.BLACK_QUEEN.toU4()]));        
    } 

    // pub inline fn all_attackers(self: *Position, s: u6, occ: u64) u64 {
    //     return self.attackers_from(s, occ, Color.White) | self.attackers_from(s, occ, Color.Black);
    // }

    pub inline fn all_attackers(self: *Position, s: u6, occ: u64) u64 {
        //return self.attackers_from(s, occ, Color.White) | self.attackers_from(s, occ, Color.Black);
        //return self.attackers_plus_king_from(s, occ, Color.White) | self.attackers_plus_king_from(s, occ, Color.Black);
        return         
        (attacks.pawn_attacks_from_square(s, Color.Black) & self.piece_bb[Piece.WHITE_PAWN.toU4()]) | 
        (attacks.piece_attacks(s, occ, PieceType.Knight) & self.piece_bb[Piece.WHITE_KNIGHT.toU4()]) | 
        (attacks.piece_attacks(s, occ, PieceType.Bishop) & (self.piece_bb[Piece.WHITE_BISHOP.toU4()] | self.piece_bb[Piece.WHITE_QUEEN.toU4()])) | 
        (attacks.piece_attacks(s, occ, PieceType.Rook) & (self.piece_bb[Piece.WHITE_ROOK.toU4()] | self.piece_bb[Piece.WHITE_QUEEN.toU4()])) |
        (attacks.piece_attacks(s, occ, PieceType.King) & self.piece_bb[Piece.WHITE_KING.toU4()]) |
        (attacks.pawn_attacks_from_square(s, Color.White) & self.piece_bb[Piece.BLACK_PAWN.toU4()]) | 
        (attacks.piece_attacks(s, occ, PieceType.Knight) & self.piece_bb[Piece.BLACK_KNIGHT.toU4()]) | 
        (attacks.piece_attacks(s, occ, PieceType.Bishop) & (self.piece_bb[Piece.BLACK_BISHOP.toU4()] | self.piece_bb[Piece.BLACK_QUEEN.toU4()])) | 
        (attacks.piece_attacks(s, occ, PieceType.Rook) & (self.piece_bb[Piece.BLACK_ROOK.toU4()] | self.piece_bb[Piece.BLACK_QUEEN.toU4()])) |
        (attacks.piece_attacks(s, occ, PieceType.King) & self.piece_bb[Piece.BLACK_KING.toU4()]);  
    }    

    pub inline fn in_check(self: *Position, comptime C: Color) bool {
        const oC = if (C == Color.White) Color.Black else Color.White;
        const square = Square.fromU6(bb.get_ls1b_index(self.piece_bb[Piece.new(C, PieceType.King).toU4()]));
        return (self.attackers_from(square.toU6(), (self.all_pieces(Color.White) | self.all_pieces(Color.Black)), oC) != 0);
    }

    pub inline fn is_repetition(self: *Position) bool {
        // repeatition test: position fen r5k1/pbN2rp1/4Q1Np/2pn1pB1/8/P7/1PP2PPP/6K1 b - - 0 25 moves d5c7 g6e7 g8f8 e7g6 f8g8 g6e7 g8f8 e7g6 f8g8

        const fifty = self.history[self.game_ply].fifty;

        if (fifty < 4) {
            return false;
        }

        var index = @as(isize, self.game_ply) - 2;
        const min_index = @as(isize, self.game_ply) - @as(isize, fifty);
        var count: u2 = 0;

        while (index >= min_index and index >= 0) {
            if (self.hash == self.history[@as(usize,@intCast(index))].hash_key) {
                count += 1;
                if (count >= 2) {
                    return true;
                }
            }  
            index -= 2;    
        }

        return false;

    }

    pub inline fn upcoming_repetition(self: *Position) bool {
        // repeatition test: position fen r5k1/pbN2rp1/4Q1Np/2pn1pB1/8/P7/1PP2PPP/6K1 b - - 0 25 moves d5c7 g6e7 g8f8 e7g6 f8g8 g6e7 g8f8 e7g6 f8g8

        const fifty = self.history[self.game_ply].fifty;

        if (fifty < 3) {
            return false;
        }

        var index = @as(isize, self.game_ply) - 2;
        const min_index = @as(isize, self.game_ply) - @as(isize, fifty);
        var count: u2 = 0;

        while (index >= min_index and index >= 0) {
            if (self.hash == self.history[@as(usize,@intCast(index))].hash_key) {
                count += 1;
                if (count >= 1) {
                    return true;
                }
            }  
            index -= 2;    
        }

        return false;

    }    

    pub inline fn is_fifty(self: *Position) bool {
        if (self.history[self.game_ply].fifty >= 100) {
            return true;
        }
        return false;
    }

    pub inline fn pawns_count(self: *Position) u7 {
        const pawns = self.piece_bb[Piece.WHITE_PAWN.toU4()] | self.piece_bb[Piece.BLACK_PAWN.toU4()];
        return bb.pop_count(pawns);
    }

    pub inline fn piece_count(self: *Position, pc: Piece) u7 {
        const pieces = self.piece_bb[pc.toU4()];
        return bb.pop_count(pieces);
    }

    pub inline fn is_insufficient_material(self: *Position) bool {
        const remaining_pieces = self.all_pieces(Color.White) | self.all_pieces(Color.Black);
        const white_bishop = self.piece_bb[Piece.WHITE_BISHOP.toU4()];
        const black_bishop = self.piece_bb[Piece.BLACK_BISHOP.toU4()];
        const white_knight = self.piece_bb[Piece.WHITE_KNIGHT.toU4()];
        const black_knight = self.piece_bb[Piece.BLACK_KNIGHT.toU4()];

        const piece_cnt = bb.pop_count(remaining_pieces);

        if (piece_cnt == 2) {
            return true;
        }

        return (piece_cnt == 3 and ((remaining_pieces & (white_bishop | black_bishop | white_knight | black_knight)) != 0));

    }

    pub inline fn is_draw(self: *Position) bool {

        if (self.is_fifty() or self.is_insufficient_material() or self.is_repetition()) {
            return true;
        }

        return false;

    }

    pub fn play(self: *Position, m: Move, comptime C: Color) void {

        self.side_to_play = self.side_to_play.change_side();
        self.hash ^= zobrist.side_key;
        self.game_ply += 1;
        self.history[self.game_ply] = UndoInfo.copy(self.history[self.game_ply-1]);

        const update_entry = SQUARE_BB[m.to] | SQUARE_BB[m.from];
        self.history[self.game_ply].entry |= update_entry;

        self.delta.reset();
        self.history[self.game_ply].accumulator.computed_accumulation = false;
        self.history[self.game_ply].accumulator.computed_score = false;

        if ((self.history[self.game_ply].castling > 0) ){
            if (update_entry & 0x10 != 0) { // King move
                self.history[self.game_ply].castling &= ~Castling.WK.toU4() & ~Castling.WQ.toU4();
            }
            else if (update_entry & 0x1 != 0) { // White queen side rook
                self.history[self.game_ply].castling &= ~Castling.WQ.toU4();
            }
            else if (update_entry & 0x80 != 0) { // White king side rook
                self.history[self.game_ply].castling &= ~Castling.WK.toU4();
            }
            else if (update_entry & 0x1000000000000000 != 0) {
                self.history[self.game_ply].castling &= ~Castling.BK.toU4() & ~Castling.BQ.toU4();
            }
            else if (update_entry & 0x100000000000000 != 0) {
                self.history[self.game_ply].castling &= ~Castling.BQ.toU4();
            }
            else if (update_entry & 0x8000000000000000 != 0) {
                self.history[self.game_ply].castling &= ~Castling.BK.toU4();
            }

            self.hash ^= zobrist.castling_keys[self.history[self.game_ply-1].castling] ^ zobrist.castling_keys[self.history[self.game_ply].castling];
            //}
        }

        var epsq = self.history[self.game_ply - 1].epsq;
        if ( epsq != Square.NO_SQUARE) {
            self.hash ^= zobrist.enpassant_keys[epsq.file_of().toU3()];
        }

        if (self.board[m.from].type_of() == PieceType.Pawn or m.is_capture()) {
            self.history[self.game_ply].fifty = 0;
        }

        switch (m.flags) {
            MoveFlags.QUIET => {
                const pc = self.board[m.from];
                self.move_piece_quiet(m.from, m.to);

                if (nnue.engine_using_nnue) {
                    self.delta.move_piece_quiet(pc, m.from, m.to);
                }                
            },
            MoveFlags.DOUBLE_PUSH => {
                const pc = self.board[m.from];
                self.move_piece_quiet(m.from, m.to);

                if (nnue.engine_using_nnue) {
                    self.delta.move_piece_quiet(pc, m.from, m.to);
                }

                self.history[self.game_ply].epsq = Square.fromU6(@as(u6, @intCast(@as(i8, @intCast(m.from)) + Direction.NORTH.relative_dir(C).toI8())));
                self.hash ^= zobrist.enpassant_keys[self.history[self.game_ply].epsq.file_of().toU3()];
            },
            MoveFlags.OO => {
                if (C == Color.White) {
                    self.move_piece_quiet(Square.e1.toU6(), Square.g1.toU6());
                    self.move_piece_quiet(Square.h1.toU6(), Square.f1.toU6());

                    if (nnue.engine_using_nnue) {
                        self.delta.move_piece_quiet(Piece.WHITE_KING, Square.e1.toU6(), Square.g1.toU6());
                        self.delta.move_piece_quiet(Piece.WHITE_ROOK, Square.h1.toU6(), Square.f1.toU6());
                    }
                } else {
                    self.move_piece_quiet(Square.e8.toU6(), Square.g8.toU6());
                    self.move_piece_quiet(Square.h8.toU6(), Square.f8.toU6());

                    if (nnue.engine_using_nnue) {
                        self.delta.move_piece_quiet(Piece.BLACK_KING, Square.e8.toU6(), Square.g8.toU6());
                        self.delta.move_piece_quiet(Piece.BLACK_ROOK, Square.h8.toU6(), Square.f8.toU6());
                    }                    
                 }
            },
            MoveFlags.OOO => {
                if (C == Color.White) {
                    self.move_piece_quiet(Square.e1.toU6(), Square.c1.toU6());
                    self.move_piece_quiet(Square.a1.toU6(), Square.d1.toU6());

                    if (nnue.engine_using_nnue) {
                        self.delta.move_piece_quiet(Piece.WHITE_KING, Square.e1.toU6(), Square.c1.toU6());
                        self.delta.move_piece_quiet(Piece.WHITE_ROOK, Square.a1.toU6(), Square.d1.toU6());
                    }                    
                 } else {
                    self.move_piece_quiet(Square.e8.toU6(), Square.c8.toU6());
                    self.move_piece_quiet(Square.a8.toU6(), Square.d8.toU6());

                    if (nnue.engine_using_nnue) {
                        self.delta.move_piece_quiet(Piece.BLACK_KING, Square.e8.toU6(), Square.c8.toU6());
                        self.delta.move_piece_quiet(Piece.BLACK_ROOK, Square.a8.toU6(), Square.d8.toU6());
                    }                     
                }                
            },
            MoveFlags.EN_PASSANT => {
                const pc = self.board[m.from];
                self.move_piece_quiet(m.from, m.to);
                const s_idx = @as(u6, @intCast(@as(i8, @intCast(m.to)) + Direction.SOUTH.relative_dir(C).toI8()));
                const removed_pc = self.board[s_idx];
                self.remove_piece(s_idx);

                if (nnue.engine_using_nnue) {
                    self.delta.move_piece_quiet(pc, m.from, m.to);
                    self.delta.remove_piece(removed_pc, s_idx);
                }                
            },
            MoveFlags.PR_KNIGHT => {
                const removed_pc = self.board[m.from];
                self.remove_piece(m.from);
                const pc = Piece.new(C, PieceType.Knight);
                self.put_piece(pc, m.to);

                if (nnue.engine_using_nnue) {
                    self.delta.remove_piece(removed_pc, m.from);
                    self.delta.put_piece(pc, m.to);
                }                 
            },
            MoveFlags.PR_BISHOP => {
                const removed_pc = self.board[m.from];
                self.remove_piece(m.from);
                const pc = Piece.new(C, PieceType.Bishop);
                self.put_piece(pc, m.to);

                if (nnue.engine_using_nnue) {
                    self.delta.remove_piece(removed_pc, m.from);
                    self.delta.put_piece(pc, m.to);
                }                 
            },
            MoveFlags.PR_ROOK => {
                const removed_pc = self.board[m.from];
                self.remove_piece(m.from);
                const pc = Piece.new(C, PieceType.Rook);
                self.put_piece(pc, m.to);

                if (nnue.engine_using_nnue) {
                    self.delta.remove_piece(removed_pc, m.from);
                    self.delta.put_piece(pc, m.to);
                }                 
            },
            MoveFlags.PR_QUEEN => {
                const pc = Piece.new(C, PieceType.Queen);
                const removed_pc = self.board[m.from];
                self.remove_piece(m.from);
                self.put_piece(pc, m.to);

                if (nnue.engine_using_nnue) {
                    self.delta.remove_piece(removed_pc, m.from);
                    self.delta.put_piece(pc, m.to);
                } 
            },
            MoveFlags.PC_KNIGHT => {
                const pc = Piece.new(C, PieceType.Knight);
                self.move_promote_capture(m.from, m.to, pc);
            },
            MoveFlags.PC_BISHOP => {
                const pc = Piece.new(C, PieceType.Bishop);
                self.move_promote_capture(m.from, m.to, pc);
            },
            MoveFlags.PC_ROOK => {
                const pc = Piece.new(C, PieceType.Rook);
                self.move_promote_capture(m.from, m.to, pc);
            },
            MoveFlags.PC_QUEEN => {
                const pc = Piece.new(C, PieceType.Queen);
                self.move_promote_capture(m.from, m.to, pc);
            }, 
            MoveFlags.CAPTURE => {
                const captured = self.board[m.to];
                const capturer = self.board[m.from];
                self.history[self.game_ply].captured = captured;
                self.move_piece(m.from, m.to);

                if (nnue.engine_using_nnue) {
                    self.delta.move_piece(capturer, captured, m.from, m.to);
                } 
            },
            else => {},
        }

        self.history[self.game_ply].hash_key = self.hash;

    }

    pub fn play_null_move(self: *Position) void {
        
        self.side_to_play = self.side_to_play.change_side();
        self.hash ^= zobrist.side_key;
        self.game_ply += 1;
        self.history[self.game_ply] = UndoInfo.copy(self.history[self.game_ply-1]);

        var epsq = self.history[self.game_ply - 1].epsq;
        if ( epsq != Square.NO_SQUARE) {
            self.hash ^= zobrist.enpassant_keys[epsq.file_of().toU3()];
        }

        self.history[self.game_ply].hash_key = self.hash;

        self.delta.reset();
        self.history[self.game_ply].accumulator.computed_accumulation = false;
        self.history[self.game_ply].accumulator.computed_score = false;

    }

    pub fn undo(self: *Position, m: Move, comptime C: Color) void {
        
        switch (m.flags) {
            MoveFlags.QUIET => {
                self.move_piece_quiet(m.to, m.from);
            },
            MoveFlags.DOUBLE_PUSH => {
                self.move_piece_quiet(m.to, m.from);
                self.hash ^= zobrist.enpassant_keys[self.history[self.game_ply].epsq.file_of().toU3()];
            },    
            MoveFlags.OO => {
                if (C == Color.White) {
                    self.move_piece_quiet(Square.g1.toU6(), Square.e1.toU6());
                    self.move_piece_quiet(Square.f1.toU6(), Square.h1.toU6());
                } else {
                    self.move_piece_quiet(Square.g8.toU6(), Square.e8.toU6());
                    self.move_piece_quiet(Square.f8.toU6(), Square.h8.toU6());
                }
            },     
            MoveFlags.OOO => {
                if (C == Color.White) {
                    self.move_piece_quiet(Square.c1.toU6(), Square.e1.toU6());
                    self.move_piece_quiet(Square.d1.toU6(), Square.a1.toU6());
                } else {
                    self.move_piece_quiet(Square.c8.toU6(), Square.e8.toU6());
                    self.move_piece_quiet(Square.d8.toU6(), Square.a8.toU6());
                 }                
            },          
            MoveFlags.EN_PASSANT => {
                self.move_piece_quiet(m.to, m.from);
                self.put_piece(Piece.new(C.change_side(),PieceType.Pawn), @as(u6, @intCast(@as(i8, @intCast(m.to)) + Direction.SOUTH.relative_dir(C).toI8())));
            },      
            MoveFlags.PR_KNIGHT, MoveFlags.PR_BISHOP, MoveFlags.PR_ROOK, MoveFlags.PR_QUEEN => {
                self.remove_piece(m.to);
                self.put_piece(Piece.new(C, PieceType.Pawn), m.from);
            },
            MoveFlags.PC_KNIGHT, MoveFlags.PC_BISHOP, MoveFlags.PC_ROOK, MoveFlags.PC_QUEEN => {
                self.remove_piece(m.to);
                self.put_piece(Piece.new(C, PieceType.Pawn), m.from);
                self.put_piece(self.history[self.game_ply].captured, m.to);
            },
            MoveFlags.CAPTURE => {
                self.move_piece_quiet(m.to, m.from);
                self.put_piece(self.history[self.game_ply].captured, m.to);
            },
            else => {},
        }
        self.side_to_play = self.side_to_play.change_side();
        self.hash ^= zobrist.side_key;
        self.game_ply -= 1;

        var epsq = self.history[self.game_ply].epsq;
        if ( epsq != Square.NO_SQUARE) {
            self.hash ^= zobrist.enpassant_keys[epsq.file_of().toU3()];
        }
        
        if (self.history[self.game_ply+1].castling != self.history[self.game_ply].castling) {
            self.hash ^= zobrist.castling_keys[self.history[self.game_ply+1].castling] ^ zobrist.castling_keys[self.history[self.game_ply].castling];
        }
    }

    pub fn undo_null_move(self: *Position) void {
        self.side_to_play = self.side_to_play.change_side();
        self.hash ^= zobrist.side_key;
        self.game_ply -= 1;

        var epsq = self.history[self.game_ply].epsq;
        if ( epsq != Square.NO_SQUARE) {
            self.hash ^= zobrist.enpassant_keys[epsq.file_of().toU3()];
        }
    }    

    pub fn generate_legals(self: *Position, comptime Us: Color, list: *std.ArrayList(Move)) void {
        const Them = Us.change_side();

        const us_bb = self.all_pieces(Us);
        const them_bb = self.all_pieces(Them);
        const all_bb = us_bb | them_bb;

        const our_king = bb.get_ls1b_index(self.bitboard_of_pt(Us, PieceType.King));
        const their_king = bb.get_ls1b_index(self.bitboard_of_pt(Them, PieceType.King));

        const our_diag_sliders = self.diagonal_sliders(Us);
        const their_diag_sliders = self.diagonal_sliders(Them);
        const our_orth_sliders = self.orthogonal_sliders(Us);
        const their_orth_sliders = self.orthogonal_sliders(Them);

        var b1: u64 = 0;
        var b2: u64 = 0;
        var b3: u64 = 0;        

        var danger: u64 = 0;

        //For each enemy piece, add all of its attacks to the danger bitboard
        danger |= attacks.pawn_attacks_from_bitboard(self.bitboard_of_pt(Them, PieceType.Pawn), Them) | attacks.piece_attacks(their_king, all_bb, PieceType.King);

        b1 = self.bitboard_of_pt(Them, PieceType.Knight);

        while (b1 != 0) {
            danger |= attacks.piece_attacks(bb.pop_lsb(&b1), all_bb, PieceType.Knight);
        }

        b1 = their_diag_sliders;
        //all ^ SQUARE_BB[our_king] is written to prevent the king from moving to squares which are 'x-rayed'
        //by enemy bishops and queens
        while (b1 != 0) {
            danger |= attacks.piece_attacks(bb.pop_lsb(&b1), all_bb ^ SQUARE_BB[our_king], PieceType.Bishop);
        }

        b1 = their_orth_sliders;
        //all ^ SQUARE_BB[our_king] is written to prevent the king from moving to squares which are 'x-rayed'
        //by enemy rooks and queens   
        while (b1 != 0) {
            danger |= attacks.piece_attacks(bb.pop_lsb(&b1), all_bb ^ SQUARE_BB[our_king], PieceType.Rook);
        }             

        //The king can move to all of its surrounding squares, except ones that are attacked, and
        //ones that have our own pieces on them
        b1 = attacks.piece_attacks(our_king, all_bb, PieceType.King) & ~(us_bb | danger);
        make(Square.fromU6(our_king), b1 & ~them_bb, MoveFlags.QUIET, list);
        make(Square.fromU6(our_king), b1 & them_bb, MoveFlags.CAPTURE, list);

        //The capture mask filters destination squares to those that contain an enemy piece that is checking the 
        //king and must be captured
        var capture_mask: u64 = undefined;

        //The quiet mask filter destination squares to those where pieces must be moved to block an incoming attack 
        //to the king        
        var quiet_mask: u64 = undefined;

        //A general purpose square for storing destinations, etc.
        var s: u6 = undefined;

        //Checkers of each piece type are identified by:
        //1. Projecting attacks FROM the king square
        //2. Intersecting this bitboard with the enemy bitboard of that piece type
        self.checkers = (attacks.piece_attacks(our_king, all_bb, PieceType.Knight) & self.bitboard_of_pt(Them, PieceType.Knight)) | (attacks.pawn_attacks_from_square(our_king, Us) & self.bitboard_of_pt(Them, PieceType.Pawn)); // Bug in original code //piece_bb[Piece.new(Them, PieceType.Knight).toU4()]  //self.piece_bb[Piece.new(Them, PieceType.Pawn).toU4()]

        //Here, we identify slider checkers and pinners simultaneously, and candidates for such pinners 
        //and checkers are represented by the bitboard <candidates>
        var candidates = (attacks.piece_attacks(our_king, them_bb, PieceType.Rook) & their_orth_sliders) | (attacks.piece_attacks(our_king, them_bb, PieceType.Bishop) & their_diag_sliders); // Possible bug in original code
        
        self.pinned = 0;

        while (candidates != 0) {
            s = bb.pop_lsb(&candidates);
            b1 = attacks.SQUARES_BETWEEN_BB[our_king][s] & us_bb;

            //Do the squares in between the enemy slider and our king contain any of our pieces?
            //If not, add the slider to the checker bitboard   
            if (b1 == 0) {
                self.checkers ^= SQUARE_BB[s];
            }
            //If there is only one of our pieces between them, add our piece to the pinned bitboard 
            else if ((b1 & b1-1) == 0) {
                self.pinned ^= b1;
            }
        }

        //This makes it easier to mask pieces
        const not_pinned = ~self.pinned;

        switch (bb.pop_count(self.checkers)) {
            //If there is a double check, the only legal moves are king moves out of check
            2 => return,
            1 => {
                //It's a single check!

                const checker_square = bb.get_ls1b_index(self.checkers);
                switch (self.board[checker_square]) {
                    Piece.new(Them, PieceType.Pawn) => {
                        //If the checker is a pawn, we must check for e.p. moves that can capture it
                        //This evaluates to true if the checking piece is the one which just double pushed                        
                        const sq_idx = self.history[self.game_ply].epsq.toU6();
                        if (self.checkers == shift(SQUARE_BB[sq_idx], Direction.relative_dir(Direction.SOUTH, Us))) {
                            b1 = attacks.pawn_attacks_from_square(sq_idx, Them) & self.bitboard_of_pt(Us, PieceType.Pawn) & not_pinned;
                            while (b1 != 0) {
                                list.append(Move.new(bb.pop_lsb_Sq(&b1), self.history[self.game_ply].epsq, MoveFlags.EN_PASSANT)) catch unreachable;
                            }
                        }
                        b1 = self.attackers_from(checker_square, all_bb, Us) & not_pinned;
                        while (b1 != 0) {
                            list.append(Move.new(bb.pop_lsb_Sq(&b1), Square.fromU6(checker_square), MoveFlags.CAPTURE)) catch unreachable;
                        }
                        return;                        
                    },
                    Piece.new(Them, PieceType.King) => {
                        b1 = self.attackers_from(checker_square, all_bb, Us) & not_pinned;
                        while (b1 != 0) {
                            list.append(Move.new(bb.pop_lsb_Sq(&b1), Square.fromU6(checker_square), MoveFlags.CAPTURE)) catch unreachable;
                        }
                        return;                           
                    },
                    else => {
                        //We must capture the checking piece
                        capture_mask = self.checkers;     

                        //...or we can block it since it is guaranteed to be a slider
                        quiet_mask = attacks.SQUARES_BETWEEN_BB[our_king][checker_square];     
                    },
                }
            },
            else => {
                //We can capture any enemy piece
                capture_mask = them_bb;

                //...and we can play a quiet move to any square which is not occupied
                quiet_mask = ~all_bb;                

                if (self.history[self.game_ply].epsq != Square.NO_SQUARE) {
                    //b1 contains our pawns that can perform an e.p. capture
                    const sq_idx = self.history[self.game_ply].epsq.toU6();
                    b2 = attacks.pawn_attacks_from_square(sq_idx, Them) & self.bitboard_of_pt(Us, PieceType.Pawn);
                    b1 = b2 & not_pinned;
                    while (b1 != 0) {
                        s = bb.pop_lsb(&b1);

                        const b4 = all_bb ^ SQUARE_BB[s] ^ shift(SQUARE_BB[self.history[self.game_ply].epsq.toU6()], Direction.SOUTH.relative_dir(Us));
                        const mr = bb.MASK_RANK[rank_of_u6(our_king)]; // pozor
                        const md = bb.MASK_DIAGONAL[diagonal_of_u6(our_king)];
                        const mad = bb.MASK_ANTI_DIAGONAL[anti_diagonal_of_u6(our_king)];

                        const cond1 = attacks.sliding_attacks(our_king, b4, mr) & their_orth_sliders;
                        const cond2 = attacks.sliding_attacks(our_king, b4, md) & their_diag_sliders;
                        const cond3 = attacks.sliding_attacks(our_king, b4, mad) & their_diag_sliders;

                        if ((cond1 | cond2 | cond3 ) == 0) {
                            list.append(Move.new(Square.fromU6(s), self.history[self.game_ply].epsq, MoveFlags.EN_PASSANT)) catch unreachable;
                        }

                    }

                    //Pinned pawns can only capture e.p. if they are pinned diagonally and the e.p. square is in line with the king 
                    b1 = b2 & self.pinned & attacks.LINE[sq_idx][our_king];
                    if (b1 != 0) {
                        list.append(Move.new(Square.fromU6(bb.get_ls1b_index(b1)), self.history[self.game_ply].epsq, MoveFlags.EN_PASSANT)) catch unreachable;     
                    }
                }

                //Only add castling if:
                //1. The king and the rook have both not moved
                //2. No piece is attacking between the the rook and the king
                //3. The king is not in check
                if (((self.history[self.game_ply].entry & oo_mask(Us)) | ((all_bb | danger) & oo_blockers_mask(Us))) == 0) {
                    if (Us == Color.White ) {
                        list.append(Move.new(Square.e1, Square.g1, MoveFlags.OO)) catch unreachable; //Bug in original code - castling is done to wrong square
                    } else {
                        list.append(Move.new(Square.e8, Square.g8, MoveFlags.OO)) catch unreachable; //Bug in original code - castling is done to wrong square
                    }
                }

                if (((self.history[self.game_ply].entry & ooo_mask(Us)) | ((all_bb | (danger & ~ignore_ooo_danger(Us))) & ooo_blockers_mask(Us))) == 0) {
                    if (Us == Color.White ) {
                        list.append(Move.new(Square.e1, Square.c1, MoveFlags.OOO)) catch unreachable;
                    } else {
                        list.append(Move.new(Square.e8, Square.c8, MoveFlags.OOO)) catch unreachable;
                    }
                }      

                //For each pinned rook, bishop or queen...
                b1 = ~(not_pinned | self.bitboard_of_pt(Us, PieceType.Knight) | self.bitboard_of_pt(Us, PieceType.Pawn));
                while (b1 != 0) {
                    const s1 = bb.pop_lsb(&b1);

                    //...only include attacks that are aligned with our king, since pinned pieces
                    //are constrained to move in this direction only
                    var pc = self.board[s1];                    
                    b2 = attacks.piece_attacks(s1, all_bb, pc.type_of()) & attacks.LINE[our_king][s1];
                    make(Square.fromU6(s1), b2 & quiet_mask, MoveFlags.QUIET, list);
                    make(Square.fromU6(s1), b2 & capture_mask, MoveFlags.CAPTURE, list);
                }

                //For each pinned pawn...
                b1 = ~not_pinned & self.bitboard_of_pt(Us, PieceType.Pawn);
                while (b1 != 0) {
                    s = bb.pop_lsb(&b1);

                    if (rank_of_u6(s) == Rank.RANK7.relative_rank(Us).toU6()) {
                        //Quiet promotions are impossible since the square in front of the pawn will
                        //either be occupied by the king or the pinner, or doing so would leave our king
                        //in check  
                        b2 = attacks.pawn_attacks_from_square(s, Us) & capture_mask & attacks.LINE[our_king][s];

                        const sq_from = Square.fromU6(s);

                        while (b2 != 0) {
                            const sq_to = Square.fromU6(bb.pop_lsb(&b2));

                            list.append(Move.new(sq_from, sq_to, MoveFlags.PC_KNIGHT)) catch unreachable;
                            list.append(Move.new(sq_from, sq_to, MoveFlags.PC_BISHOP)) catch unreachable;
                            list.append(Move.new(sq_from, sq_to, MoveFlags.PC_ROOK)) catch unreachable;
                            list.append(Move.new(sq_from, sq_to, MoveFlags.PC_QUEEN)) catch unreachable;
                        }

                    } else {
                        b2 = attacks.pawn_attacks_from_square(s, Us) & them_bb & attacks.LINE[s][our_king]; // pozor
                        make(Square.fromU6(s), b2, MoveFlags.CAPTURE, list);

                        //Single pawn pushes
                        b2 = shift(SQUARE_BB[s], Direction.NORTH.relative_dir(Us)) & ~all_bb & attacks.LINE[our_king][s];
                        //Double pawn pushes (only pawns on rank 3/6 are eligible)
                        b3 = shift( b2 & bb.MASK_RANK[Rank.RANK3.relative_rank(Us).toU3()], Direction.NORTH.relative_dir(Us)) & ~all_bb & attacks.LINE[our_king][s];
                        make(Square.fromU6(s), b2, MoveFlags.QUIET, list);
                        make(Square.fromU6(s), b3, MoveFlags.DOUBLE_PUSH, list);
                    }
                }
            },
        }

        //Non-pinned knight moves
        b1 = self.bitboard_of_pt(Us, PieceType.Knight) & not_pinned;
        while (b1 != 0) {
            const s1 = bb.pop_lsb(&b1);
            b2 = attacks.piece_attacks(s1, all_bb, PieceType.Knight);
            make(Square.fromU6(s1), b2 & quiet_mask, MoveFlags.QUIET, list);
            make(Square.fromU6(s1), b2 & capture_mask, MoveFlags.CAPTURE, list);
        }

        //Non-pinned bishops and queens
        b1 = our_diag_sliders & not_pinned;
        while (b1 != 0) {
            const s1 = bb.pop_lsb(&b1);
            b2 = attacks.piece_attacks(s1, all_bb, PieceType.Bishop);
            make(Square.fromU6(s1), b2 & quiet_mask, MoveFlags.QUIET, list);
            make(Square.fromU6(s1), b2 & capture_mask, MoveFlags.CAPTURE, list);
        }

        //Non-pinned rooks and queens
        b1 = our_orth_sliders & not_pinned;
        while (b1 != 0) {
            const s1 = bb.pop_lsb(&b1);
            b2 = attacks.piece_attacks(s1, all_bb, PieceType.Rook);
            make(Square.fromU6(s1), b2 & quiet_mask, MoveFlags.QUIET, list);
            make(Square.fromU6(s1), b2 & capture_mask, MoveFlags.CAPTURE, list);
        }

        //b1 contains non-pinned pawns which are not on the last rank
        b1 = self.bitboard_of_pt(Us, PieceType.Pawn) & not_pinned & ~bb.MASK_RANK[Rank.RANK7.relative_rank(Us).toU3()];

        //Single pawn pushes
        b2 = shift(b1, Direction.NORTH.relative_dir(Us)) & ~all_bb;

        //Double pawn pushes (only pawns on rank 3/6 are eligible)
        b3 = shift(b2 & bb.MASK_RANK[Rank.RANK3.relative_rank(Us).toU3()], Direction.NORTH.relative_dir(Us)) & quiet_mask;

        //We & this with the quiet mask only later, as a non-check-blocking single push does NOT mean that the 
        //corresponding double push is not blocking check either.        
        b2 &= quiet_mask;

        while (b2 != 0) {
            const s1 = bb.pop_lsb(&b2);
            list.append(Move.new(Square.fromU6(@as(u6, @intCast(@as(i8, @intCast(s1)) - Direction.NORTH.relative_dir(Us).toI8()))), Square.fromU6(s1), MoveFlags.QUIET)) catch unreachable;
        }

        while (b3 != 0) {
            const s1 = bb.pop_lsb(&b3);
            list.append(Move.new(Square.fromU6(@as(u6, @intCast(@as(i8, @intCast(s1)) - Direction.NORTH_NORTH.relative_dir(Us).toI8()))), Square.fromU6(s1), MoveFlags.DOUBLE_PUSH)) catch unreachable;
        }

        //Pawn captures
        b2 = shift(b1, Direction.NORTH_WEST.relative_dir(Us)) & capture_mask;
        b3 = shift(b1, Direction.NORTH_EAST.relative_dir(Us)) & capture_mask;

        while (b2 != 0) {
            const s1 = bb.pop_lsb(&b2);
            list.append(Move.new(Square.fromU6(@as(u6, @intCast(@as(i8, @intCast(s1)) - Direction.NORTH_WEST.relative_dir(Us).toI8()))), Square.fromU6(s1), MoveFlags.CAPTURE)) catch unreachable;
        }

        while (b3 != 0) {
            const s1 = bb.pop_lsb(&b3);
            list.append(Move.new(Square.fromU6(@as(u6, @intCast(@as(i8, @intCast(s1)) - Direction.NORTH_EAST.relative_dir(Us).toI8()))), Square.fromU6(s1), MoveFlags.CAPTURE)) catch unreachable;
        }

        //b1 now contains non-pinned pawns which ARE on the last rank (about to promote)    
        b1 = self.bitboard_of_pt(Us, PieceType.Pawn) & not_pinned & bb.MASK_RANK[Rank.RANK7.relative_rank(Us).toU3()];
        if (b1 != 0) {
            //Quiet promotions
            b2 = shift(b1, Direction.NORTH.relative_dir(Us)) & quiet_mask;
            while (b2 != 0) {
                const s1 = bb.pop_lsb(&b2);
                const Sq2 = Square.fromU6(@as(u6, @intCast(@as(i8, @intCast(s1)) - Direction.NORTH.relative_dir(Us).toI8())));
                const Sq1 = Square.fromU6(s1);

                list.append(Move.new(Sq2, Sq1, MoveFlags.PR_KNIGHT)) catch unreachable;
                list.append(Move.new(Sq2, Sq1, MoveFlags.PR_BISHOP)) catch unreachable;
                list.append(Move.new(Sq2, Sq1, MoveFlags.PR_ROOK)) catch unreachable;
                list.append(Move.new(Sq2, Sq1, MoveFlags.PR_QUEEN)) catch unreachable;

            }

            //Promotion captures
            b2 = shift(b1, Direction.NORTH_WEST.relative_dir(Us)) & capture_mask;
            b3 = shift(b1, Direction.NORTH_EAST.relative_dir(Us)) & capture_mask; 
            while (b2 != 0) {
                const s1 = bb.pop_lsb(&b2);
                //One move is added for each promotion piece
                const Sq2 = Square.fromU6(@as(u6, @intCast(@as(i8, @intCast(s1)) - Direction.NORTH_WEST.relative_dir(Us).toI8())));
                const Sq1 = Square.fromU6(s1);

                list.append(Move.new(Sq2, Sq1, MoveFlags.PC_KNIGHT)) catch unreachable;
                list.append(Move.new(Sq2, Sq1, MoveFlags.PC_BISHOP)) catch unreachable;
                list.append(Move.new(Sq2, Sq1, MoveFlags.PC_ROOK)) catch unreachable;
                list.append(Move.new(Sq2, Sq1, MoveFlags.PC_QUEEN)) catch unreachable;
            }  

            while (b3 != 0) {
                const s1 = bb.pop_lsb(&b3);
                //One move is added for each promotion piece
                const Sq2 = Square.fromU6(@as(u6, @intCast(@as(i8, @intCast(s1)) - Direction.NORTH_EAST.relative_dir(Us).toI8())));
                const Sq1 = Square.fromU6(s1);

                list.append(Move.new(Sq2, Sq1, MoveFlags.PC_KNIGHT)) catch unreachable;
                list.append(Move.new(Sq2, Sq1, MoveFlags.PC_BISHOP)) catch unreachable;
                list.append(Move.new(Sq2, Sq1, MoveFlags.PC_ROOK)) catch unreachable;
                list.append(Move.new(Sq2, Sq1, MoveFlags.PC_QUEEN)) catch unreachable;
            }                      
        }

        return;
    }

    pub fn generate_captures(self: *Position, comptime Us: Color, list: *std.ArrayList(Move)) void {
        //comptime var Them = Us.change_side();
        const Them = Us.change_side();

        const us_bb = self.all_pieces(Us);
        const them_bb = self.all_pieces(Them);
        const all_bb = us_bb | them_bb;

        const our_king = bb.get_ls1b_index(self.bitboard_of_pt(Us, PieceType.King));
        const their_king = bb.get_ls1b_index(self.bitboard_of_pt(Them, PieceType.King));

        const our_diag_sliders = self.diagonal_sliders(Us);
        const their_diag_sliders = self.diagonal_sliders(Them);
        const our_orth_sliders = self.orthogonal_sliders(Us);
        const their_orth_sliders = self.orthogonal_sliders(Them);

        var b1: u64 = 0;
        var b2: u64 = 0;
        var b3: u64 = 0;

        var danger: u64 = 0;

        //For each enemy piece, add all of its attacks to the danger bitboard
        danger |= attacks.pawn_attacks_from_bitboard(self.bitboard_of_pt(Them, PieceType.Pawn), Them) | attacks.piece_attacks(their_king, all_bb, PieceType.King);

        b1 = self.bitboard_of_pt(Them, PieceType.Knight);

        while (b1 != 0) {
            danger |= attacks.piece_attacks(bb.pop_lsb(&b1), all_bb, PieceType.Knight);
        }

        b1 = their_diag_sliders;
        //all ^ SQUARE_BB[our_king] is written to prevent the king from moving to squares which are 'x-rayed'
        //by enemy bishops and queens
        while (b1 != 0) {
            danger |= attacks.piece_attacks(bb.pop_lsb(&b1), all_bb ^ SQUARE_BB[our_king], PieceType.Bishop);
        }

        b1 = their_orth_sliders;
        //all ^ SQUARE_BB[our_king] is written to prevent the king from moving to squares which are 'x-rayed'
        //by enemy rooks and queens
        while (b1 != 0) {
            danger |= attacks.piece_attacks(bb.pop_lsb(&b1), all_bb ^ SQUARE_BB[our_king], PieceType.Rook);
        }

        //The king can move to all of its surrounding squares, except ones that are attacked, and
        //ones that have our own pieces on them
        b1 = attacks.piece_attacks(our_king, all_bb, PieceType.King) & ~(us_bb | danger);
        //make(Square.fromU6(our_king), b1 & ~them_bb, MoveFlags.QUIET, list);
        make(Square.fromU6(our_king), b1 & them_bb, MoveFlags.CAPTURE, list);

        //The capture mask filters destination squares to those that contain an enemy piece that is checking the
        //king and must be captured
        var capture_mask: u64 = undefined;

        //The quiet mask filter destination squares to those where pieces must be moved to block an incoming attack
        //to the king
        var quiet_mask: u64 = undefined;

        //A general purpose square for storing destinations, etc.
        var s: u6 = undefined;

        //Checkers of each piece type are identified by:
        //1. Projecting attacks FROM the king square
        //2. Intersecting this bitboard with the enemy bitboard of that piece type
        self.checkers = (attacks.piece_attacks(our_king, all_bb, PieceType.Knight) & self.bitboard_of_pt(Them, PieceType.Knight)) | (attacks.pawn_attacks_from_square(our_king, Us) & self.bitboard_of_pt(Them, PieceType.Pawn)); // Bug in original code //piece_bb[Piece.new(Them, PieceType.Knight).toU4()]  //self.piece_bb[Piece.new(Them, PieceType.Pawn).toU4()]

        //Here, we identify slider checkers and pinners simultaneously, and candidates for such pinners
        //and checkers are represented by the bitboard <candidates>
        var candidates = (attacks.piece_attacks(our_king, them_bb, PieceType.Rook) & their_orth_sliders) | (attacks.piece_attacks(our_king, them_bb, PieceType.Bishop) & their_diag_sliders); // Possible bug in original code

        self.pinned = 0;

        while (candidates != 0) {
            s = bb.pop_lsb(&candidates);
            b1 = attacks.SQUARES_BETWEEN_BB[our_king][s] & us_bb;

            //Do the squares in between the enemy slider and our king contain any of our pieces?
            //If not, add the slider to the checker bitboard
            if (b1 == 0) {
                self.checkers ^= SQUARE_BB[s];
            }
            //If there is only one of our pieces between them, add our piece to the pinned bitboard
            else if ((b1 & b1 - 1) == 0) {
                self.pinned ^= b1;
            }
        }

        //This makes it easier to mask pieces
        const not_pinned = ~self.pinned;

        switch (bb.pop_count(self.checkers)) {
            //If there is a double check, the only legal moves are king moves out of check
            2 => return,
            1 => {
                //It's a single check!

                const checker_square = bb.get_ls1b_index(self.checkers);
                switch (self.board[checker_square]) {
                    Piece.new(Them, PieceType.Pawn) => {
                        //If the checker is a pawn, we must check for e.p. moves that can capture it
                        //This evaluates to true if the checking piece is the one which just double pushed
                        const sq_idx = self.history[self.game_ply].epsq.toU6();
                        if (self.checkers == shift(SQUARE_BB[sq_idx], Direction.relative_dir(Direction.SOUTH, Us))) {
                            b1 = attacks.pawn_attacks_from_square(sq_idx, Them) & self.bitboard_of_pt(Us, PieceType.Pawn) & not_pinned;
                            while (b1 != 0) {
                                list.append(Move.new(bb.pop_lsb_Sq(&b1), self.history[self.game_ply].epsq, MoveFlags.EN_PASSANT)) catch unreachable;
                            }
                        }
                        b1 = self.attackers_from(checker_square, all_bb, Us) & not_pinned;
                        while (b1 != 0) {
                            list.append(Move.new(bb.pop_lsb_Sq(&b1), Square.fromU6(checker_square), MoveFlags.CAPTURE)) catch unreachable;
                        }
                        return;
                    },
                    Piece.new(Them, PieceType.King) => {
                        b1 = self.attackers_from(checker_square, all_bb, Us) & not_pinned;
                        while (b1 != 0) {
                            list.append(Move.new(bb.pop_lsb_Sq(&b1), Square.fromU6(checker_square), MoveFlags.CAPTURE)) catch unreachable;
                        }
                        return;
                    },
                    else => {
                        //We must capture the checking piece
                        capture_mask = self.checkers;

                        //...or we can block it since it is guaranteed to be a slider
                        quiet_mask = attacks.SQUARES_BETWEEN_BB[our_king][checker_square];
                    },
                }
            },
            else => {
                //We can capture any enemy piece
                capture_mask = them_bb;

                //...and we can play a quiet move to any square which is not occupied
                quiet_mask = ~all_bb;

                if (self.history[self.game_ply].epsq != Square.NO_SQUARE) {
                    //b1 contains our pawns that can perform an e.p. capture
                    const sq_idx = self.history[self.game_ply].epsq.toU6();
                    b2 = attacks.pawn_attacks_from_square(sq_idx, Them) & self.bitboard_of_pt(Us, PieceType.Pawn);
                    b1 = b2 & not_pinned;
                    while (b1 != 0) {
                        s = bb.pop_lsb(&b1);

                        const b4 = all_bb ^ SQUARE_BB[s] ^ shift(SQUARE_BB[self.history[self.game_ply].epsq.toU6()], Direction.SOUTH.relative_dir(Us));
                        const mr = bb.MASK_RANK[rank_of_u6(our_king)]; // pozor
                        const md = bb.MASK_DIAGONAL[diagonal_of_u6(our_king)];
                        const mad = bb.MASK_ANTI_DIAGONAL[anti_diagonal_of_u6(our_king)];

                        const cond1 = attacks.sliding_attacks(our_king, b4, mr) & their_orth_sliders;
                        const cond2 = attacks.sliding_attacks(our_king, b4, md) & their_diag_sliders;
                        const cond3 = attacks.sliding_attacks(our_king, b4, mad) & their_diag_sliders;

                        if ((cond1 | cond2 | cond3) == 0) {
                            list.append(Move.new(Square.fromU6(s), self.history[self.game_ply].epsq, MoveFlags.EN_PASSANT)) catch unreachable;
                        }
                    }

                    //Pinned pawns can only capture e.p. if they are pinned diagonally and the e.p. square is in line with the king
                    b1 = b2 & self.pinned & attacks.LINE[sq_idx][our_king];
                    if (b1 != 0) {
                        list.append(Move.new(Square.fromU6(bb.get_ls1b_index(b1)), self.history[self.game_ply].epsq, MoveFlags.EN_PASSANT)) catch unreachable;
                    }
                }

                //For each pinned rook, bishop or queen...
                b1 = ~(not_pinned | self.bitboard_of_pt(Us, PieceType.Knight) | self.bitboard_of_pt(Us, PieceType.Pawn));
                while (b1 != 0) {
                    const s1 = bb.pop_lsb(&b1);

                    //...only include attacks that are aligned with our king, since pinned pieces
                    //are constrained to move in this direction only
                    var pc = self.board[s1];
                    b2 = attacks.piece_attacks(s1, all_bb, pc.type_of()) & attacks.LINE[our_king][s1];
                    make(Square.fromU6(s1), b2 & capture_mask, MoveFlags.CAPTURE, list);
                }

                //For each pinned pawn...
                b1 = ~not_pinned & self.bitboard_of_pt(Us, PieceType.Pawn);
                while (b1 != 0) {
                    s = bb.pop_lsb(&b1);

                    if (rank_of_u6(s) == Rank.RANK7.relative_rank(Us).toU6()) {
                        //Quiet promotions are impossible since the square in front of the pawn will
                        //either be occupied by the king or the pinner, or doing so would leave our king
                        //in check
                        b2 = attacks.pawn_attacks_from_square(s, Us) & capture_mask & attacks.LINE[our_king][s];
                        //make(Square.fromU6(s), b2, MoveFlags.PROMOTION_CAPTURES, list);
                        const sq_from = Square.fromU6(s);

                        while (b2 != 0) {
                            const sq_to = Square.fromU6(bb.pop_lsb(&b2));

                            list.append(Move.new(sq_from, sq_to, MoveFlags.PC_KNIGHT)) catch unreachable;
                            list.append(Move.new(sq_from, sq_to, MoveFlags.PC_BISHOP)) catch unreachable;
                            list.append(Move.new(sq_from, sq_to, MoveFlags.PC_ROOK)) catch unreachable;
                            list.append(Move.new(sq_from, sq_to, MoveFlags.PC_QUEEN)) catch unreachable;
                        }                        
                    } else {
                        b2 = attacks.pawn_attacks_from_square(s, Us) & them_bb & attacks.LINE[s][our_king]; // pozor
                        make(Square.fromU6(s), b2, MoveFlags.CAPTURE, list);

                    }
                }
            },
        }

        //Non-pinned knight moves
        b1 = self.bitboard_of_pt(Us, PieceType.Knight) & not_pinned;
        while (b1 != 0) {
            const s1 = bb.pop_lsb(&b1);
            b2 = attacks.piece_attacks(s1, all_bb, PieceType.Knight);
            make(Square.fromU6(s1), b2 & capture_mask, MoveFlags.CAPTURE, list);
        }

        //Non-pinned bishops and queens
        b1 = our_diag_sliders & not_pinned;
        while (b1 != 0) {
            const s1 = bb.pop_lsb(&b1);
            b2 = attacks.piece_attacks(s1, all_bb, PieceType.Bishop);
            make(Square.fromU6(s1), b2 & capture_mask, MoveFlags.CAPTURE, list);
        }

        //Non-pinned rooks and queens
        b1 = our_orth_sliders & not_pinned;
        while (b1 != 0) {
            const s1 = bb.pop_lsb(&b1);
            b2 = attacks.piece_attacks(s1, all_bb, PieceType.Rook);
            make(Square.fromU6(s1), b2 & capture_mask, MoveFlags.CAPTURE, list);
        }

        //b1 contains non-pinned pawns which are not on the last rank
        b1 = self.bitboard_of_pt(Us, PieceType.Pawn) & not_pinned & ~bb.MASK_RANK[Rank.RANK7.relative_rank(Us).toU3()];

        //Pawn captures
        b2 = shift(b1, Direction.NORTH_WEST.relative_dir(Us)) & capture_mask;
        b3 = shift(b1, Direction.NORTH_EAST.relative_dir(Us)) & capture_mask;

        while (b2 != 0) {
            const s1 = bb.pop_lsb(&b2);
            list.append(Move.new(Square.fromU6(@as(u6, @intCast(@as(i8, @intCast(s1)) - Direction.NORTH_WEST.relative_dir(Us).toI8()))), Square.fromU6(s1), MoveFlags.CAPTURE)) catch unreachable;
        }

        while (b3 != 0) {
            const s1 = bb.pop_lsb(&b3);
            list.append(Move.new(Square.fromU6(@as(u6, @intCast(@as(i8, @intCast(s1)) - Direction.NORTH_EAST.relative_dir(Us).toI8()))), Square.fromU6(s1), MoveFlags.CAPTURE)) catch unreachable;
        }

        //b1 now contains non-pinned pawns which ARE on the last rank (about to promote)
        b1 = self.bitboard_of_pt(Us, PieceType.Pawn) & not_pinned & bb.MASK_RANK[Rank.RANK7.relative_rank(Us).toU3()];
        if (b1 != 0) {
            //Quiet promotions
            b2 = shift(b1, Direction.NORTH.relative_dir(Us)) & quiet_mask;
            while (b2 != 0) {
                const s1 = bb.pop_lsb(&b2);
                const Sq2 = Square.fromU6(@as(u6, @intCast(@as(i8, @intCast(s1)) - Direction.NORTH.relative_dir(Us).toI8())));
                const Sq1 = Square.fromU6(s1);

                list.append(Move.new(Sq2, Sq1, MoveFlags.PR_KNIGHT)) catch unreachable;
                list.append(Move.new(Sq2, Sq1, MoveFlags.PR_BISHOP)) catch unreachable;
                list.append(Move.new(Sq2, Sq1, MoveFlags.PR_ROOK)) catch unreachable;
                list.append(Move.new(Sq2, Sq1, MoveFlags.PR_QUEEN)) catch unreachable;

            }            

            //Promotion captures
            b2 = shift(b1, Direction.NORTH_WEST.relative_dir(Us)) & capture_mask;
            b3 = shift(b1, Direction.NORTH_EAST.relative_dir(Us)) & capture_mask;
            while (b2 != 0) {
                const s1 = bb.pop_lsb(&b2);
                //One move is added for each promotion piece
                const Sq2 = Square.fromU6(@as(u6, @intCast(@as(i8, @intCast(s1)) - Direction.NORTH_WEST.relative_dir(Us).toI8())));
                const Sq1 = Square.fromU6(s1);

                list.append(Move.new(Sq2, Sq1, MoveFlags.PC_KNIGHT)) catch unreachable;
                list.append(Move.new(Sq2, Sq1, MoveFlags.PC_BISHOP)) catch unreachable;
                list.append(Move.new(Sq2, Sq1, MoveFlags.PC_ROOK)) catch unreachable;
                list.append(Move.new(Sq2, Sq1, MoveFlags.PC_QUEEN)) catch unreachable;
            }

            while (b3 != 0) {
                const s1 = bb.pop_lsb(&b3);
                //One move is added for each promotion piece
                const Sq2 = Square.fromU6(@as(u6, @intCast(@as(i8, @intCast(s1)) - Direction.NORTH_EAST.relative_dir(Us).toI8())));
                const Sq1 = Square.fromU6(s1);

                list.append(Move.new(Sq2, Sq1, MoveFlags.PC_KNIGHT)) catch unreachable;
                list.append(Move.new(Sq2, Sq1, MoveFlags.PC_BISHOP)) catch unreachable;
                list.append(Move.new(Sq2, Sq1, MoveFlags.PC_ROOK)) catch unreachable;
                list.append(Move.new(Sq2, Sq1, MoveFlags.PC_QUEEN)) catch unreachable;
            }
        }

        return;
    }

    pub fn calculate_hash(self: Position) u64 {
        var hash: u64 = 0;

        for (0..64) |s_idx| {
            const pc_idx = self.board[s_idx].toU4();
            const zh = zobrist.zobrist_table[pc_idx][s_idx];
            if (zh != 0) {
                hash ^= zh;
            }
        }

        if (self.side_to_play == Color.Black) {
            hash ^= zobrist.side_key;
        }

        var epsq = self.history[self.game_ply].epsq;
        if ( epsq != Square.NO_SQUARE) { 
            hash ^= zobrist.enpassant_keys[epsq.file_of().toU3()];
        }
  
        hash ^= zobrist.castling_keys[self.history[self.game_ply].castling];

        return hash;
      
    }

    pub fn print(self: Position) void {
        const s = "   +---+---+---+---+---+---+---+---+\n";
        const t = "     A   B   C   D   E   F   G   H\n";
        std.debug.print("{s}", .{t});
        var i: isize = 56;
        while (i >= 0) : (i -= 8) {
            std.debug.print("{s} {} ", .{ s, @divTrunc(i, 8) + 1 });
            var j: usize = 0;
            while (j < 8) : (j += 1) {
                std.debug.print("| {c} ", .{PIECE_STR[self.board[(@as(usize, @intCast(i)) + j)].toU4()]});
            }
            std.debug.print("| {}\n", .{@divTrunc(i, 8) + 1});
        }
        std.debug.print("{s}", .{s});
        std.debug.print("{s}\n", .{t});

        std.debug.print("Hash: 0x{x}\n", .{self.hash});
    }

    /// To use unicode print, you have use command "chcp 65001" in terminal to switch to 
    /// Active code page: 65001, which properly shows the unicode characters
    pub fn print_unicode(self: *Position) void {
        const s = "    -----------------\n";
        const t = "     A B C D E F G H\n";
        std.debug.print("\n{s}", .{t});
        std.debug.print("{s}", .{s});
        var i: isize = 56;
        while (i >= 0) : (i -= 8) {
            std.debug.print(" {} |", .{ @divTrunc(i, 8) + 1 });
            var j: usize = 0;
            while (j < 8) : (j += 1) {
                std.debug.print(" {s}", .{unicodePIECE_STR[self.board[(@as(usize, @intCast(i)) + j)].toU4()]});
            }
            std.debug.print(" | {}\n", .{@divTrunc(i, 8) + 1});
        }
        std.debug.print("{s}", .{s});
        std.debug.print("{s}\n", .{t});

        const side = if (self.side_to_play == Color.White) "White" else "Black";
        const epsq = if (self.history[self.game_ply].epsq != Square.NO_SQUARE) sq_to_coord[self.history[self.game_ply].epsq.toU6()] else "no";

        std.debug.print("{s} to move\n", .{side});
        std.debug.print("Enpassant: {s}\n", .{epsq});
        std.debug.print("Entry: 0x{x}\n", .{self.history[self.game_ply].entry});
        std.debug.print("Castling: 0b{b:0>4}\n", .{self.history[self.game_ply].castling});
        std.debug.print("Hash: 0x{x}\n", .{self.hash});
        std.debug.print("Position eval: {}\n", .{self.eval.eval(self, Color.White)});
        std.debug.print("Phase white: {}, phase black: {}\n", .{self.eval.phase[Color.White.toU4()], self.eval.phase[Color.Black.toU4()]});
    }    

    const FenParseError = error{
        MissingField,
        InvalidPosition,
        InvalidActiveColor,
        InvalidCastlingRights,
        InvalidEnPassant,
        InvalidHalfMoveCounter,
        InvalidFullMoveCounter,
    };

    pub fn set(self: *Position, fen: []const u8) !void {
        self.* = Position.new();

        var parts = std.mem.split(u8, fen, " ");
        const fen_position = parts.next().?;

        var ranks = std.mem.split(u8, fen_position, "/");
        var rank: u6 = 0;
        while (ranks.next()) |entry| {
            var file: u6 = 0;
            for (entry) |c| {
                const square = Square.fromU6((7 - rank) * 8 + file);
                const piece = switch (c) {
                    'P' => Piece.WHITE_PAWN,
                    'N' => Piece.WHITE_KNIGHT,
                    'B' => Piece.WHITE_BISHOP,
                    'R' => Piece.WHITE_ROOK,
                    'Q' => Piece.WHITE_QUEEN,
                    'K' => Piece.WHITE_KING,
                    'p' => Piece.BLACK_PAWN,
                    'n' => Piece.BLACK_KNIGHT,
                    'b' => Piece.BLACK_BISHOP,
                    'r' => Piece.BLACK_ROOK,
                    'q' => Piece.BLACK_QUEEN,
                    'k' => Piece.BLACK_KING,
                    '1'...'8' => {
                        file += @truncate(c - '0');
                        continue;
                    },
                    else => {
                        return FenParseError.InvalidPosition;
                    },
                };
                self.add_piece_to_board(piece, square.toU6());
                file += 1;
            }
            if (file != 8) return FenParseError.InvalidPosition;
            rank += 1;
        }
        if (rank != 8) return FenParseError.InvalidPosition;

        const active_color_fen = parts.next().?;
        if (std.mem.eql(u8, active_color_fen, "w")) {
            self.side_to_play = Color.White;
        } else if (std.mem.eql(u8, active_color_fen, "b")) {
            self.side_to_play = Color.Black;
            self.hash ^= zobrist.side_key;
        } else {
            return FenParseError.InvalidActiveColor;
        }

        const castling_fen = parts.next().?;
        self.history[self.game_ply].entry = ALL_CASTLING_MASK;

        for (castling_fen) |c| {
            switch (c) {
                'K' =>  {
                    self.history[self.game_ply].entry &= ~WHITE_OO_MASK;
                    self.history[self.game_ply].castling |= Castling.WK.toU4();
                },
                'Q' => {
                    self.history[self.game_ply].entry &= ~WHITE_OOO_MASK;
                    self.history[self.game_ply].castling |= Castling.WQ.toU4();
                },
                'k' => {
                    self.history[self.game_ply].entry &= ~BLACK_OO_MASK;
                    self.history[self.game_ply].castling |= Castling.BK.toU4();
                },
                'q' => {
                    self.history[self.game_ply].entry &= ~BLACK_OOO_MASK;
                    self.history[self.game_ply].castling |= Castling.BQ.toU4();
                },
                '-' => break,
                else => return FenParseError.InvalidCastlingRights,
            }
        }

        // Possible bug in surge cpp source code? The original cpp code does not set en passant square from fen.
        const en_passant_fen = parts.next().?;

        if (!std.mem.eql(u8, en_passant_fen, "-")) {
            self.history[self.game_ply].epsq = Square.from_str(en_passant_fen);
            self.hash ^= zobrist.enpassant_keys[self.history[self.game_ply].epsq.file_of().toU3()];
        }

        self.hash ^= zobrist.castling_keys[self.history[self.game_ply].castling];
        self.history[self.game_ply].hash_key = self.hash;

    }

};