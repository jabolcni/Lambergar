const std = @import("std");
const bb = @import("bitboard.zig");
const zobrist = @import("zobrist.zig");
const attacks = @import("attacks.zig");
const evaluation = @import("evaluation.zig");
const nnue = @import("nnue.zig");
const lists = @import("lists.zig");

// Debug toggle for verbose Chess960/DFRC castling diagnostics
// Compile-time constant; resolved via local fallback file so `zig test` works,
// while build.zig can still override by generating the same file in the build graph.
pub const castling_debug: bool = @import("./build_options.zig").castling_debug;

//const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const Evaluation = evaluation.Evaluation;

const MoveList = lists.MoveList;

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

    pub fn toU(self: Square) usize {
        return @as(usize, @intFromEnum(self));
    }

    pub fn toU7(self: Square) u7 {
        return @as(u7, @intFromEnum(self));
    }

    pub fn toU6(self: Square) u6 {
        return @as(u6, @truncate(@intFromEnum(self)));
    }

    pub fn fromInt(square: usize) Square {
        return @enumFromInt(square);
    }

    pub fn fromU6(square: u6) Square {
        return @enumFromInt(square);
    }

    pub fn from_str(str: []const u8) Square {
        return @enumFromInt((str[1] - '1') * 8 + (str[0] - 'a'));
    }

    pub fn rank_of(self: Square) Rank {
        return @as(Rank, @enumFromInt(@intFromEnum(self) >> 3));
    }

    pub fn file_of(self: Square) File {
        return @as(File, @enumFromInt(@intFromEnum(self) & 0b111));
    }

    pub fn diagonal_of(self: Square) u4 {
        return (7 + @as(u4, @intCast(self.rank_of().toU3())) - @as(u4, @intCast(self.file_of().toU3())));
    }

    pub fn anti_diagonal_of(self: Square) u4 {
        return @as(u4, @intCast(self.rank_of().toU3())) + @as(u4, @intCast(self.file_of().toU3()));
    }

    pub fn create_square(f: File, r: Rank) Square {
        return @as(Square, @enumFromInt(@intFromEnum(f) | (@intFromEnum(r) << 3)));
    }
};

pub fn rank_of_iter(sq: usize) usize {
    return sq >> 3;
}

pub fn rank_of_isize(sq: usize) isize {
    return @as(isize, @intCast(sq >> 3));
}

pub fn rank_of_u6(sq: u6) u6 {
    return sq >> 3;
}

pub fn relative_rank_of_u6(sq: u6, comptime c: Color) u6 {
    const rank = rank_of_u6(sq);
    return if (c == Color.White) rank else 7 - rank;
}

pub fn file_of_iter(sq: usize) usize {
    return sq & 0b111;
}

pub fn file_of_isize(sq: usize) isize {
    return @as(isize, @intCast(sq & 0b111));
}

pub fn file_of_u6(sq: u6) u6 {
    return sq & 0b111;
}

pub fn diagonal_of_iter(sq: usize) usize {
    return 7 + rank_of_iter(sq) - file_of_iter(sq);
}

pub fn diagonal_of_u6(sq: u6) u6 {
    return 7 + rank_of_u6(sq) - file_of_u6(sq);
}

pub fn anti_diagonal_of_iter(sq: usize) usize {
    return rank_of_iter(sq) + file_of_iter(sq);
}

pub fn anti_diagonal_of_u6(sq: u6) u6 {
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

    pub inline fn toU6(self: PieceType) u6 {
        return @intCast(@intFromEnum(self));
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

    pub inline fn mass(self: Piece) u4 {
        if (self == Piece.WHITE_PAWN or self == Piece.BLACK_PAWN) return 0;
        if (self == Piece.WHITE_KNIGHT or self == Piece.BLACK_KNIGHT) return 1;
        if (self == Piece.WHITE_BISHOP or self == Piece.BLACK_BISHOP) return 1;
        if (self == Piece.WHITE_ROOK or self == Piece.BLACK_ROOK) return 2;
        if (self == Piece.WHITE_QUEEN or self == Piece.BLACK_QUEEN) return 2;
        if (self == Piece.WHITE_KING or self == Piece.BLACK_KING) return 3;
        return 0;
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

    pub inline fn promote_type_str(self: MoveFlags) ?u8 {
        return switch (self) {
            MoveFlags.PR_KNIGHT => 'n',
            MoveFlags.PR_BISHOP => 'b',
            MoveFlags.PR_ROOK => 'r',
            MoveFlags.PR_QUEEN => 'q',
            MoveFlags.PC_KNIGHT => 'n',
            MoveFlags.PC_BISHOP => 'b',
            MoveFlags.PC_ROOK => 'r',
            MoveFlags.PC_QUEEN => 'q',            
            else => null,
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

    pub fn to_str(self: Move) [5]u8 {
        var result: [5]u8 = undefined;
        @memcpy(result[0..2], sq_to_coord[self.from]);
        @memcpy(result[2..4], sq_to_coord[self.to]);
        if (self.is_promotion()) {
            result[4] = PROM_TYPESTR[self.flags.toU4()][0];
        }
        return result;
    }    

    // pub fn to_str(self: Move, allocator: Allocator) []const u8 {
    //     if (self.is_promotion()) {
    //         var move_str = allocator.alloc(u8, 5) catch unreachable;

    //         @memcpy(move_str[0..2], sq_to_coord[self.from]);
    //         @memcpy(move_str[2..4], sq_to_coord[self.to]);
    //         move_str[4] = PROM_TYPESTR[self.flags.toU4()][0];
    //         return move_str;
    //     } else {
    //         var move_str = allocator.alloc(u8, 4) catch unreachable;
    //         @memcpy(move_str[0..2], sq_to_coord[self.from]);
    //         @memcpy(move_str[2..4], sq_to_coord[self.to]);
    //         return move_str;
    //     }

    // }

    pub fn parse_move(move_str: []const u8, pos: *Position) !Move {
        const from = Square.from_str(move_str[0..2]).toU6();
        const to = Square.from_str(move_str[2..4]).toU6();

        //var list = std.ArrayList(Move).initCapacity(std.heap.c_allocator, 48) catch unreachable;
        //defer list.deinit();
        var list2: MoveList = .{};

        if (pos.side_to_play == Color.White) {
            pos.generate_legals(Color.White, &list2);
        } else {
            pos.generate_legals(Color.Black, &list2);
        }

        // Chess960 UCI castling fast-path: if input encodes castling as king-from + rook-from,
        // map the destination to the king's target square and require the matching castle flag.
        const adj_from: u6 = from;
        var adj_to: u6 = to;
        var require_flag: ?MoveFlags = null;
        if (pos.is_chess960) {
            const side = pos.side_to_play;
            const king_bb = pos.bitboard_of_pc(Piece.make_piece(side, PieceType.King));
            if (king_bb != 0) {
                const ks: u6 = bb.get_ls1b_index(king_bb);
                if (from == ks) {
                    const ci: usize = side.toU4();
                    const rk = pos.castle_rook_k_start[ci];
                    const rq = pos.castle_rook_q_start[ci];
                    if (rk != Square.NO_SQUARE and to == rk.toU6()) {
                        // King target file is g-file in 960 UCI
                        adj_to = (if (side == Color.White) Square.g1 else Square.g8).toU6();
                        require_flag = MoveFlags.OO;
                    } else if (rq != Square.NO_SQUARE and to == rq.toU6()) {
                        // King target file is c-file in 960 UCI
                        adj_to = (if (side == Color.White) Square.c1 else Square.c8).toU6();
                        require_flag = MoveFlags.OOO;
                    }
                }
            }
        }

        for (0..list2.count) |i| {
            const move = list2.moves[i];
            if (move.from == adj_from and move.to == adj_to and (require_flag == null or move.flags == require_flag.?)) {
                if (move.is_promotion()) {
                    if (PROM_TYPESTR[move.flags.toU4()][0] != move_str[4])
                        continue;
                }
                return move;
            }
        }
        // Fallback: compare UCI strings of legals against input (handles any internal encoding quirks)
        for (0..list2.count) |i| {
            const m = list2.moves[i];
            const u = m.to_str();
            const u_slice = if (m.is_promotion()) u[0..5] else u[0..4];
            if (u_slice.len == move_str.len and std.mem.eql(u8, u_slice, move_str)) {
                return m;
            }
        }
        return MoveParseError.IllegalMove;
    }

    pub fn parse_alg_move(move_str: []const u8, pos: *Position) !Move {
        const uci_move = try algebraic_to_uci(move_str, pos);
        defer std.testing.allocator.free(uci_move);  
        const move = try Move.parse_move(uci_move, pos);
        return move;     
    }

    fn algebraic_to_uci(move_str: []const u8, curr_pos: *Position) ![]const u8 {
        // Buffer for UCI string (max 5 chars: e.g., "e7e8q")
        var uci_buf: [5]u8 = undefined;
        var uci_len: usize = 0;

        // Handle castling (Chess960-aware: king from current square to g/c file)
        if (std.mem.eql(u8, move_str, "O-O")) {
            // side_to_play is runtime; use bitboard_of_pc, not comptime-only bitboard_of_pt
            const king_bb = curr_pos.bitboard_of_pc(Piece.make_piece(curr_pos.side_to_play, PieceType.King));
            const ks = bb.get_ls1b_index(king_bb);
            const kd = if (curr_pos.side_to_play == .White) Square.g1.toU6() else Square.g8.toU6();
            @memcpy(uci_buf[0..2], sq_to_coord[ks]);
            @memcpy(uci_buf[2..4], sq_to_coord[kd]);
            uci_len = 4;
            return try std.testing.allocator.dupe(u8, uci_buf[0..uci_len]);
        } else if (std.mem.eql(u8, move_str, "O-O-O")) {
            const king_bb = curr_pos.bitboard_of_pc(Piece.make_piece(curr_pos.side_to_play, PieceType.King));
            const ks = bb.get_ls1b_index(king_bb);
            const kd = if (curr_pos.side_to_play == .White) Square.c1.toU6() else Square.c8.toU6();
            @memcpy(uci_buf[0..2], sq_to_coord[ks]);
            @memcpy(uci_buf[2..4], sq_to_coord[kd]);
            uci_len = 4;
            return try std.testing.allocator.dupe(u8, uci_buf[0..uci_len]);
        }

        // Parse algebraic move
        var piece: u8 = 'P'; // Default to pawn
        var src_file: ?u8 = null;
        var src_rank: ?u8 = null;
        var dest_square: []const u8 = undefined;
        var promotion: ?u8 = null;
        var is_cap = false;
        var move_idx: usize = 0;

        // Check for piece identifier (N, B, R, Q, K)
        if (move_idx < move_str.len and move_str[move_idx] >= 'A' and move_str[move_idx] <= 'Z') {
            piece = move_str[move_idx];
            move_idx += 1;
        }

        // Parse source file/rank, capture, or destination
        while (move_idx < move_str.len) {
            const c = move_str[move_idx];
            // Check for destination square (file + rank)
            if (move_idx + 2 <= move_str.len and
                move_str[move_idx] >= 'a' and move_str[move_idx] <= 'h' and
                move_str[move_idx + 1] >= '1' and move_str[move_idx + 1] <= '8')
            {
                dest_square = move_str[move_idx .. move_idx + 2];
                move_idx += 2;
                break;
            }
            if (c == 'x') {
                is_cap = true;
                move_idx += 1;
            } else if (c >= 'a' and c <= 'h') {
                src_file = c;
                move_idx += 1;
            } else if (c >= '1' and c <= '8') {
                src_rank = c;
                move_idx += 1;
            } else {
                return error.InvalidAlgebraicMove;
            }
        }

        //std.debug.print("\nmove: {s}, move_idx={d}, dest_square={s}\n", .{ move_str, move_idx, dest_square });

        // Validate destination square
        if (dest_square.len != 2 or dest_square[0] < 'a' or dest_square[0] > 'h' or
            dest_square[1] < '1' or dest_square[1] > '8')
        {
            return error.InvalidDestinationSquare;
        }

        // Promotion (e.g., "=Q")
        if (move_idx < move_str.len and move_str[move_idx] == '=') {
            move_idx += 1;
            if (move_idx < move_str.len) {
                promotion = std.ascii.toLower(move_str[move_idx]);
                if (promotion != 'q' and promotion != 'r' and promotion != 'b' and promotion != 'n') {
                    return error.InvalidPromotion;
                }
                move_idx += 1;
            } else {
                return error.InvalidPromotion;
            }
        }

        // Convert destination to square index (0-63)
        const dest_file = dest_square[0] - 'a';
        const dest_rank = dest_square[1] - '1';
        const dest_idx = dest_rank * 8 + dest_file;

        // Debug: Print legal moves
        var move_list: MoveList = .{};
        if (curr_pos.side_to_play == Color.White) {
            curr_pos.generate_legals(Color.White, &move_list);
        } else {
            curr_pos.generate_legals(Color.Black, &move_list);
        }

        // Find source square by checking legal moves
        var src_square: ?u64 = null;
        for (0..move_list.count) |i| {
            const move = move_list.moves[i];
            if (move.to == dest_idx and
                (promotion == null or move.flags.promote_type_str() == promotion) and
                (is_cap == move.is_capture()))
            {
                // Check piece type
                const piece_type = curr_pos.board[move.from];
                const expected_piece = switch (piece) {
                    'P' => if (curr_pos.side_to_play == .White) Piece.WHITE_PAWN else Piece.BLACK_PAWN,
                    'N' => if (curr_pos.side_to_play == .White) Piece.WHITE_KNIGHT else Piece.BLACK_KNIGHT,
                    'B' => if (curr_pos.side_to_play == .White) Piece.WHITE_BISHOP else Piece.BLACK_BISHOP,
                    'R' => if (curr_pos.side_to_play == .White) Piece.WHITE_ROOK else Piece.BLACK_ROOK,
                    'Q' => if (curr_pos.side_to_play == .White) Piece.WHITE_QUEEN else Piece.BLACK_QUEEN,
                    'K' => if (curr_pos.side_to_play == .White) Piece.WHITE_KING else Piece.BLACK_KING,
                    else => return error.InvalidPiece,
                };
                if (piece_type == expected_piece) {
                    // Check source file/rank if specified
                    const src_file_idx = @as(u8, @intCast(move.from % 8));
                    const src_rank_idx = @as(u8, @intCast(move.from / 8));
                    if ((src_file == null or src_file_idx == src_file.? - 'a') and
                        (src_rank == null or src_rank_idx == src_rank.? - '1'))
                    {
                        src_square = move.from;
                        break;
                    }
                }
            }
        }

        if (src_square == null) {
            return error.NoMatchingMove;
        }

        // Build UCI string
        uci_buf[0] = @as(u8, 'a') + @as(u8, @intCast(src_square.? % 8));
        uci_buf[1] = @as(u8, '1') + @as(u8, @intCast(src_square.? / 8));
        uci_buf[2] = dest_square[0];
        uci_buf[3] = dest_square[1];
        uci_len = 4;
        if (promotion) |p| {
            uci_buf[4] = p;
            uci_len = 5;
        }

        // Return allocated string
        return try std.testing.allocator.dupe(u8, uci_buf[0..uci_len]);
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

pub inline fn make_list(sq_from: Square, to: u64, comptime flag: MoveFlags, move_list: *MoveList) void {
    var b = to;
    while (b != 0) {
        move_list.append(Move.new(sq_from, Square.fromU6(bb.pop_lsb(&b)), flag));
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
    pawn_hash: u64 = undefined, // for correction history
    non_pawn_hash: [2]u64 = undefined, // for correction history
    major_hash: u64 = undefined, // for correction history
    minor_hash: u64 = undefined, // for correction history

    history: [2048]UndoInfo = undefined,

    eval: Evaluation = undefined,
    delta: nnue.DeltaPieces = nnue.DeltaPieces{},

    // Chess960/FRC castling: track starting squares for king and rooks per color
    // Initialized from FEN and constant during the game
    castle_king_start: [2]Square = .{ Square.NO_SQUARE, Square.NO_SQUARE },
    castle_rook_k_start: [2]Square = .{ Square.NO_SQUARE, Square.NO_SQUARE },
    castle_rook_q_start: [2]Square = .{ Square.NO_SQUARE, Square.NO_SQUARE },
    // Precomputed per-square table: which castling rights to clear if a move
    // involves this square (either as from or to). Built after FEN initialization.
    castle_rights_clear_by_sq: [64]u4 = .{0} ** 64,

    // Whether this position should export castling rights using Shredder-FEN letters (Chess960/DFRC mode)
    is_chess960: bool = false,

    // Last FEN parse diagnostic message (if any)
    fen_error: [128]u8 = undefined,
    fen_error_len: usize = 0,

    // Fullmove number from input FEN (defaults to 1)
    fullmove_number: u32 = 1,

    pub fn new() Position {
        var pos = Position{};

        @memset(pos.piece_bb[0..NPIECES], @as(u64, 0));
        pos.side_to_play = Color.White;
        pos.game_ply = 0;
        @memset(pos.board[0..64], Piece.NO_PIECE);
        pos.hash = 0;
        pos.pawn_hash = 0;
        pos.non_pawn_hash = .{0} ** 2;
        pos.major_hash = 0;
        pos.minor_hash = 0;
        pos.history[0] = UndoInfo.new();
        pos.eval.eval_mg = 0;
        pos.eval.eval_eg = 0;
        pos.eval.phase = [1]u8{0} ** 2;
        pos.delta = nnue.DeltaPieces{};

        pos.castle_king_start = .{ Square.NO_SQUARE, Square.NO_SQUARE };
        pos.castle_rook_k_start = .{ Square.NO_SQUARE, Square.NO_SQUARE };
        pos.castle_rook_q_start = .{ Square.NO_SQUARE, Square.NO_SQUARE };
        pos.castle_rights_clear_by_sq = .{0} ** 64;

        pos.is_chess960 = false;
        pos.fullmove_number = 1;

        pos.fen_error_len = 0;

        return pos;
    }

    pub fn copy(from: Position) Position {
        return Position{
            .piece_bb = from.piece_bb,
            .board = from.board,
            .side_to_play = from.side_to_play,
            .game_ply = from.game_ply,
            .hash = from.hash,
            .pawn_hash = from.pawn_hash,
            .non_pawn_hash = from.non_pawn_hash,
            .major_hash = from.major_hash,
            .minor_hash = from.minor_hash,
            .history = from.history,
            .eval = from.eval,
            .delta = nnue.DeltaPieces{},
            .castle_king_start = from.castle_king_start,
            .castle_rook_k_start = from.castle_rook_k_start,
            .castle_rook_q_start = from.castle_rook_q_start,
            .castle_rights_clear_by_sq = from.castle_rights_clear_by_sq,
            .is_chess960 = from.is_chess960,
            .fullmove_number = from.fullmove_number,
        };
    }

    pub const MoveGenContext = struct {
        us_bb: u64,
        them_bb: u64,
        all_bb: u64,
        our_king: u6,
        their_king: u6,
        our_diag_sliders: u64,
        their_diag_sliders: u64,
        our_orth_sliders: u64,
        their_orth_sliders: u64,
        danger: u64,
        checkers: u64,
        pinned: u64,
        not_pinned: u64,
        check_count: u7 = 0,
    };

    pub fn computeMoveGenContext(self: *Position, comptime Us: Color) MoveGenContext {
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

        var danger: u64 = 0;
        var checkers: u64 = 0;
        var pinned: u64 = 0;

        danger |= attacks.pawn_attacks_from_bitboard(self.bitboard_of_pt(Them, PieceType.Pawn), Them) | attacks.piece_attacks(their_king, all_bb, PieceType.King);

        b1 = self.bitboard_of_pt(Them, PieceType.Knight);

        while (b1 != 0) {
            danger |= attacks.piece_attacks(bb.pop_lsb(&b1), all_bb, PieceType.Knight);
        }

        b1 = their_diag_sliders;
        while (b1 != 0) {
            danger |= attacks.piece_attacks(bb.pop_lsb(&b1), all_bb ^ SQUARE_BB[our_king], PieceType.Bishop);
        }

        b1 = their_orth_sliders;
        while (b1 != 0) {
            danger |= attacks.piece_attacks(bb.pop_lsb(&b1), all_bb ^ SQUARE_BB[our_king], PieceType.Rook);
        }             

        checkers = (attacks.piece_attacks(our_king, all_bb, PieceType.Knight) & self.bitboard_of_pt(Them, PieceType.Knight)) | (attacks.pawn_attacks_from_square(our_king, Us) & self.bitboard_of_pt(Them, PieceType.Pawn));

        var candidates = (attacks.piece_attacks(our_king, them_bb, PieceType.Rook) & their_orth_sliders) | (attacks.piece_attacks(our_king, them_bb, PieceType.Bishop) & their_diag_sliders);
        
        pinned = 0;

        while (candidates != 0) {
            const s = bb.pop_lsb(&candidates);
            b1 = attacks.SQUARES_BETWEEN_BB[our_king][s] & us_bb;

            if (b1 == 0) {
                checkers ^= SQUARE_BB[s];
            }
            else if ((b1 & b1-1) == 0) {
                pinned ^= b1;
            }
        }

        const not_pinned = ~pinned;

        return .{
            .us_bb = us_bb,
            .them_bb = them_bb,
            .all_bb = all_bb,
            .our_king = our_king,
            .their_king = their_king,
            .our_diag_sliders = our_diag_sliders,
            .their_diag_sliders = their_diag_sliders,
            .our_orth_sliders = our_orth_sliders,
            .their_orth_sliders = their_orth_sliders,
            .danger = danger,
            .checkers = checkers,
            .pinned = pinned,
            .not_pinned = not_pinned,
            .check_count = bb.pop_count(checkers),
        };
    }

    pub inline fn add_piece_to_board(self: *Position, pc: Piece, s_idx: u6) void {
        const pc_idx = pc.toU4();

        self.board[s_idx] = pc;
        self.piece_bb[pc_idx] |= SQUARE_BB[s_idx];

        self.hash ^= zobrist.zobrist_table[pc_idx][s_idx];
        if (pc.type_of() == PieceType.Pawn) {
            self.pawn_hash ^= zobrist.zobrist_table[pc_idx][s_idx];
        } else {
            self.non_pawn_hash[pc.color().toU4()] ^= zobrist.zobrist_table[pc_idx][s_idx];
        }
        if (pc.type_of() == PieceType.Rook or pc.type_of() == PieceType.Queen) {
            self.major_hash ^= zobrist.zobrist_table[pc_idx][s_idx];
        } else if (pc.type_of() == PieceType.Bishop or pc.type_of() == PieceType.Knight) {
            self.minor_hash ^= zobrist.zobrist_table[pc_idx][s_idx];
        }
        // if (pc.type_of() == PieceType.King) {
        //     self.pawn_hash ^= zobrist.zobrist_table[pc_idx][s_idx];
        //     self.major_hash ^= zobrist.zobrist_table[pc_idx][s_idx];
        //     self.minor_hash ^= zobrist.zobrist_table[pc_idx][s_idx];
        // }

        self.eval.put_piece(pc, s_idx);
    } 

    pub inline fn put_piece(self: *Position, pc: Piece, s_idx: u6) void {
        const pc_idx = pc.toU4();

        // Debug: track rook bitboard changes caused by this put
        var wr_before: u64 = 0;
        var br_before: u64 = 0;
        if (castling_debug) {
            wr_before = self.piece_bb[Piece.WHITE_ROOK.toU4()];
            br_before = self.piece_bb[Piece.BLACK_ROOK.toU4()];
        }

        self.board[s_idx] = pc;
        self.piece_bb[pc_idx] |= SQUARE_BB[s_idx];

        self.hash ^= zobrist.zobrist_table[pc_idx][s_idx];
        if (pc.type_of() == PieceType.Pawn) {
            self.pawn_hash ^= zobrist.zobrist_table[pc_idx][s_idx];
        } else {
            self.non_pawn_hash[pc.color().toU4()] ^= zobrist.zobrist_table[pc_idx][s_idx];
        }         
        if (pc.type_of() == PieceType.Rook or pc.type_of() == PieceType.Queen) {
            self.major_hash ^= zobrist.zobrist_table[pc_idx][s_idx];
        } else if (pc.type_of() == PieceType.Bishop or pc.type_of() == PieceType.Knight) {
            self.minor_hash ^= zobrist.zobrist_table[pc_idx][s_idx];
        }
        // if (pc.type_of() == PieceType.King) {
        //     self.pawn_hash ^= zobrist.zobrist_table[pc_idx][s_idx];
        //     self.major_hash ^= zobrist.zobrist_table[pc_idx][s_idx];
        //     self.minor_hash ^= zobrist.zobrist_table[pc_idx][s_idx];
        // }

        if (nnue.engine_using_nnue) {        
            self.eval.put_piece_update_phase(pc);
            //self.eval.put_piece(pc, s_idx);
        } else {
            self.eval.put_piece(pc, s_idx);
        } 

        if (castling_debug) {
            const wr_after = self.piece_bb[Piece.WHITE_ROOK.toU4()];
            const br_after = self.piece_bb[Piece.BLACK_ROOK.toU4()];
            if (wr_after != wr_before) {
                std.debug.print("[rookbb-change put] {s} pc={c} WR before=0x{X} after=0x{X}\n",
                    .{ sq_to_coord[s_idx], piece_sym(pc), wr_before, wr_after });
            }
            if (br_after != br_before) {
                std.debug.print("[rookbb-change put] {s} pc={c} BR before=0x{X} after=0x{X}\n",
                    .{ sq_to_coord[s_idx], piece_sym(pc), br_before, br_after });
            }
        }
    }

    pub inline fn remove_piece(self: *Position, s_idx: u6) void {
        const pc = self.board[s_idx];
        const pc_idx = pc.toU4();

        // Debug: track rook bitboard changes caused by this remove
        var wr_before: u64 = 0;
        var br_before: u64 = 0;
        if (castling_debug) {
            wr_before = self.piece_bb[Piece.WHITE_ROOK.toU4()];
            br_before = self.piece_bb[Piece.BLACK_ROOK.toU4()];
        }

        self.piece_bb[pc_idx] &= ~SQUARE_BB[s_idx];
        self.board[s_idx] = Piece.NO_PIECE;

        self.hash ^= zobrist.zobrist_table[pc_idx][s_idx];
        if (pc.type_of() == PieceType.Pawn) {
            self.pawn_hash ^= zobrist.zobrist_table[pc_idx][s_idx];
        } else {
            self.non_pawn_hash[pc.color().toU4()] ^= zobrist.zobrist_table[pc_idx][s_idx];
        }         
        if (pc.type_of() == PieceType.Rook or pc.type_of() == PieceType.Queen) {
            self.major_hash ^= zobrist.zobrist_table[pc_idx][s_idx];
        } else if (pc.type_of() == PieceType.Bishop or pc.type_of() == PieceType.Knight) {
            self.minor_hash ^= zobrist.zobrist_table[pc_idx][s_idx];
        }
        // if (pc.type_of() == PieceType.King) {
        //     self.pawn_hash ^= zobrist.zobrist_table[pc_idx][s_idx];
        //     self.major_hash ^= zobrist.zobrist_table[pc_idx][s_idx];
        //     self.minor_hash ^= zobrist.zobrist_table[pc_idx][s_idx];
        // }

        if (nnue.engine_using_nnue) {        
            self.eval.remove_piece_update_phase(pc);
            //self.eval.remove_piece(pc, s_idx);
        } else {
            self.eval.remove_piece(pc, s_idx);
        }    

        if (castling_debug) {
            const wr_after = self.piece_bb[Piece.WHITE_ROOK.toU4()];
            const br_after = self.piece_bb[Piece.BLACK_ROOK.toU4()];
            if (wr_after != wr_before) {
                std.debug.print("[rookbb-change remove] {s} pc={c} WR before=0x{X} after=0x{X}\n",
                    .{ sq_to_coord[s_idx], piece_sym(pc), wr_before, wr_after });
            }
            if (br_after != br_before) {
                std.debug.print("[rookbb-change remove] {s} pc={c} BR before=0x{X} after=0x{X}\n",
                    .{ sq_to_coord[s_idx], piece_sym(pc), br_before, br_after });
            }
        }
    }

    pub inline fn move_piece(self: *Position, from: u6, to: u6) void {
        if (castling_debug and self.board[from] == Piece.NO_PIECE) {
            std.debug.print("[warn] move_piece called with empty from square {s}\n", .{ sq_to_coord[from] });
        }

        var from_pc = self.board[from];
        const from_idx = from_pc.toU4();
        var to_pc = self.board[to];
        const to_idx = to_pc.toU4();

        if (castling_debug and to_pc == Piece.NO_PIECE) {
            std.debug.print("[warn] move_piece capture with empty to square {s}\n", .{ sq_to_coord[to] });
        }

        const rook_idx: u4 = Piece.WHITE_ROOK.toU4();
        const rook_bb_before = self.piece_bb[rook_idx];

        self.hash ^= zobrist.zobrist_table[from_idx][from] ^ zobrist.zobrist_table[from_idx][to] ^ zobrist.zobrist_table[to_idx][to];

        if (from_pc.type_of() == PieceType.Pawn) {
            self.pawn_hash ^= zobrist.zobrist_table[from_idx][from] ^ zobrist.zobrist_table[from_idx][to];
        } else {
            self.non_pawn_hash[from_pc.color().toU4()] ^= zobrist.zobrist_table[from_idx][from] ^ zobrist.zobrist_table[from_idx][to];
        } 
        if (from_pc.type_of() == PieceType.Rook or from_pc.type_of() == PieceType.Queen) {
            self.major_hash ^= zobrist.zobrist_table[from_idx][from] ^ zobrist.zobrist_table[from_idx][to];
        } else if (from_pc.type_of() == PieceType.Bishop or from_pc.type_of() == PieceType.Knight) {
            self.minor_hash ^= zobrist.zobrist_table[from_idx][from] ^ zobrist.zobrist_table[from_idx][to];
        }  

        if (to_pc.type_of() == PieceType.Pawn) {
            self.pawn_hash ^= zobrist.zobrist_table[to_idx][to];
        } else {
            self.non_pawn_hash[to_pc.color().toU4()] ^= zobrist.zobrist_table[to_idx][to];
        } 
        if (to_pc.type_of() == PieceType.Rook or to_pc.type_of() == PieceType.Queen) {
            self.major_hash ^= zobrist.zobrist_table[to_idx][to];
        } else if (to_pc.type_of() == PieceType.Bishop or to_pc.type_of() == PieceType.Knight) {
            self.minor_hash ^= zobrist.zobrist_table[to_idx][to];
        }  

        // if (from_pc.type_of() == PieceType.King) {
        //     self.pawn_hash ^= zobrist.zobrist_table[from_idx][from] ^ zobrist.zobrist_table[from_idx][to] ^ zobrist.zobrist_table[to_idx][to];
        //     self.major_hash ^= zobrist.zobrist_table[from_idx][from] ^ zobrist.zobrist_table[from_idx][to] ^ zobrist.zobrist_table[to_idx][to];
        //     self.minor_hash ^= zobrist.zobrist_table[from_idx][from] ^ zobrist.zobrist_table[from_idx][to] ^ zobrist.zobrist_table[to_idx][to];
        // }      

        const mask = SQUARE_BB[from] | SQUARE_BB[to];
        self.piece_bb[from_idx] ^= mask;
        self.piece_bb[to_idx] &= ~mask;
        self.board[to] = self.board[from];
        self.board[from] = Piece.NO_PIECE;

        if (castling_debug) {
            const rook_bb_after = self.piece_bb[rook_idx];
            if (rook_bb_after != rook_bb_before) {
                std.debug.print("[rookbb-change move_piece] {s}->{s} from_idx={} to_idx={} before=0x{X} after=0x{X} mask=0x{X}\n",
                    .{ sq_to_coord[from], sq_to_coord[to], from_idx, to_idx, rook_bb_before, rook_bb_after, mask });
            }
        }

        if (nnue.engine_using_nnue) {        
            self.eval.move_piece_update_phase(to_pc);
            //self.eval.move_piece(from_pc, to_pc, from, to);
        } else {
            self.eval.move_piece(from_pc, to_pc, from, to);
        }           
    }

    pub inline fn move_piece_quiet(self: *Position, from: u6, to: u6) void {
        if (castling_debug and self.board[from] == Piece.NO_PIECE) {
            std.debug.print("[warn] move_piece_quiet with empty from at {s}\n", .{ sq_to_coord[from] });
        }
        var from_pc = self.board[from];
        const from_idx = from_pc.toU4();
        
        self.hash ^= zobrist.zobrist_table[from_idx][from] ^ zobrist.zobrist_table[from_idx][to];

        if (from_pc.type_of() == PieceType.Pawn) {
            self.pawn_hash ^= zobrist.zobrist_table[from_idx][from] ^ zobrist.zobrist_table[from_idx][to];
        } else {
            self.non_pawn_hash[from_pc.color().toU4()] ^= zobrist.zobrist_table[from_idx][from] ^ zobrist.zobrist_table[from_idx][to];
        } 
        if (from_pc.type_of() == PieceType.Rook or from_pc.type_of() == PieceType.Queen) {
            self.major_hash ^= zobrist.zobrist_table[from_idx][from] ^ zobrist.zobrist_table[from_idx][to];
        } else if (from_pc.type_of() == PieceType.Bishop or from_pc.type_of() == PieceType.Knight) {
            self.minor_hash ^= zobrist.zobrist_table[from_idx][from] ^ zobrist.zobrist_table[from_idx][to];
        } 
        // if (from_pc.type_of() == PieceType.King) {
        //     self.pawn_hash ^= zobrist.zobrist_table[from_idx][from] ^ zobrist.zobrist_table[from_idx][to];
        //     self.major_hash ^= zobrist.zobrist_table[from_idx][from] ^ zobrist.zobrist_table[from_idx][to];
        //     self.minor_hash ^= zobrist.zobrist_table[from_idx][from] ^ zobrist.zobrist_table[from_idx][to];
        // }

        const rook_idx_q: u4 = Piece.WHITE_ROOK.toU4();
        const rook_bb_before_q = self.piece_bb[rook_idx_q];
        const toggle_mask = (SQUARE_BB[from] | SQUARE_BB[to]);
        self.piece_bb[from_idx] ^= toggle_mask;
        self.board[to] = self.board[from];
        self.board[from] = Piece.NO_PIECE;

        if (castling_debug) {
            const rook_bb_after_q = self.piece_bb[rook_idx_q];
            if (rook_bb_after_q != rook_bb_before_q) {
                std.debug.print("[rookbb-change quiet] {s}->{s} from_idx={} before=0x{X} after=0x{X} mask=0x{X}\n",
                    .{ sq_to_coord[from], sq_to_coord[to], from_idx, rook_bb_before_q, rook_bb_after_q, toggle_mask });
            }
        }

        if (nnue.engine_using_nnue) {        
             //self.delta.move_piece_quiet(from_pc, from, to);
             //self.eval.move_piece_quiet(from_pc, from, to);
        } else {
            self.eval.move_piece_quiet(from_pc, from, to);
        } 

    }

    fn piece_sym(pc: Piece) u8 {
        return PIECE_STR[@intFromEnum(pc)];
    }

    pub fn debug_print_move(self: *Position, where: []const u8, m: Move, comptime c: Color) void {
        if (!castling_debug) return;
        const from_sq = sq_to_coord[m.from];
        const to_sq = sq_to_coord[m.to];
        const from_pc = self.board[m.from];
        const to_pc = self.board[m.to];
        std.debug.print("[move-{s}] {s} {s}{s} flags={d} from_pc={c} to_pc={c}\n",
            .{
                where,
                if (c == Color.White) "W" else "B",
                from_sq,
                to_sq,
                m.flags.toU4(),
                piece_sym(from_pc),
                if (to_pc == Piece.NO_PIECE) '.' else piece_sym(to_pc),
            });
    }

    pub fn debug_verify_integrity(self: *Position, where: []const u8) void {
        if (!castling_debug) return;
        var rebuilt: [NPIECES]u64 = .{0} ** NPIECES;
        var white_kings: u8 = 0;
        var black_kings: u8 = 0;
        for (0..64) |s| {
            const pc = self.board[s];
            if (pc == Piece.NO_PIECE) continue;
            rebuilt[pc.toU4()] |= SQUARE_BB[s];
            if (pc == Piece.WHITE_KING) white_kings += 1;
            if (pc == Piece.BLACK_KING) black_kings += 1;
        }
        var ok = true;
        for (0..NPIECES) |i| {
            if (rebuilt[i] != self.piece_bb[i]) {
                ok = false;
                std.debug.print("[integrity] mismatch bb idx {} at {s}: expected 0x{X}, have 0x{X}\n", .{ i, where, rebuilt[i], self.piece_bb[i] });
                const diff = rebuilt[i] ^ self.piece_bb[i];
                if (diff != 0) {
                    std.debug.print("[integrity]   diff squares:", .{});
                    var d = diff;
                    while (d != 0) {
                        const bsq = bb.pop_lsb(&d);
                        std.debug.print(" {s}", .{ sq_to_coord[bsq] });
                    }
                    std.debug.print("\n", .{});
                }
            }
        }
        if (white_kings != 1 or black_kings != 1) {
            ok = false;
            std.debug.print("[integrity] kings count W={}, B={} at {s}\n", .{ white_kings, black_kings, where });
        }
        if (!ok) {
            // Dump a quick map for debugging
            std.debug.print("[integrity] side to move: {s}\n", .{ if (self.side_to_play == Color.White) "w" else "b" });
            // Also print rook bitboards explicitly
            std.debug.print("[integrity] WR=0x{X} BR=0x{X} at {s}\n", .{ self.piece_bb[Piece.WHITE_ROOK.toU4()], self.piece_bb[Piece.BLACK_ROOK.toU4()], where });
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

    pub inline fn bitboard_of_pt(self: *Position, comptime c: Color, comptime pt: PieceType) u64 {
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

        if (fifty < 2) {
            return false;
        }

        var index = @as(isize, self.game_ply) - 2;
        const min_index = @as(isize, self.game_ply) - @as(isize, fifty);

        while (index >= min_index and index >= 0) {
            if (self.hash == self.history[@as(usize,@intCast(index))].hash_key) {
                    return true;
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
        const white_king_sq = self.bitboard_of_pt(Color.White, PieceType.King);
        const black_king_sq = self.bitboard_of_pt(Color.Black, PieceType.King);

        if (white_king_sq == 0 or black_king_sq == 0) return false;

        // Count all pieces on both sides
        const total_pieces = bb.pop_count(self.all_pieces(Color.White) | self.all_pieces(Color.Black));
        if (total_pieces == 2) return true; // K vs K

        const white_pawns = self.bitboard_of_pt(Color.White, PieceType.Pawn);
        const black_pawns = self.bitboard_of_pt(Color.Black, PieceType.Pawn);
        const white_knights = self.bitboard_of_pt(Color.White, PieceType.Knight);
        const black_knights = self.bitboard_of_pt(Color.Black, PieceType.Knight);
        const white_bishops = self.bitboard_of_pt(Color.White, PieceType.Bishop);
        const black_bishops = self.bitboard_of_pt(Color.Black, PieceType.Bishop);

        // If any pawns exist, not insufficient material
        if (white_pawns != 0 or black_pawns != 0) return false;

        // K vs K + N/B
        if (total_pieces == 3) {
            const minor_present = (white_knights | black_knights | white_bishops | black_bishops) != 0;
            return minor_present;
        }

        // K + N vs K + N
        if (total_pieces == 4 and white_knights != 0 and black_knights != 0 and
            white_bishops == 0 and black_bishops == 0)
        {
            return true;
        }

        // K + B vs K + B (same color bishops)
        if (white_bishops != 0 and black_bishops != 0 and
            white_knights == 0 and black_knights == 0 and
            white_pawns == 0 and black_pawns == 0)
        {
            const white_bishop_square = bb.get_ls1b_index(white_bishops);
            const black_bishop_square = bb.get_ls1b_index(black_bishops);

            // Check if both bishops are on the same color square
            const white_bishop_color = (white_bishop_square % 8) + (white_bishop_square / 8);
            const black_bishop_color = (black_bishop_square % 8) + (black_bishop_square / 8);

            if ((white_bishop_color % 2) == (black_bishop_color % 2)) {
                return true;
            }
        }

        // K + B vs K + N
        if (total_pieces == 4 and
            ((white_bishops != 0 and black_knights != 0) or
            (black_bishops != 0 and white_knights != 0)) and
            white_pawns == 0 and black_pawns == 0)
        {
            return true;
        }

        // K + 2N vs K
        if (total_pieces == 4 and
            ((white_knights != 0 and bb.pop_count(white_knights) == 2 and black_knights == 0) or
            (black_knights != 0 and bb.pop_count(black_knights) == 2 and white_knights == 0)))
        {
            return true;
        }

        return false;
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
            var new_rights: u4 = self.history[self.game_ply].castling;
            const to_clear: u4 = self.castle_rights_clear_by_sq[m.from] | self.castle_rights_clear_by_sq[m.to];
            if (to_clear != 0) {
                new_rights &= ~to_clear;
                if (new_rights != self.history[self.game_ply].castling) {
                    self.history[self.game_ply].castling = new_rights;
                    self.hash ^= zobrist.castling_keys[self.history[self.game_ply-1].castling] ^ zobrist.castling_keys[self.history[self.game_ply].castling];
                }
            }
        }

        var epsq = self.history[self.game_ply - 1].epsq;
        if ( epsq != Square.NO_SQUARE) {
            self.hash ^= zobrist.enpassant_keys[epsq.file_of().toU3()];
        }

        if (self.board[m.from].type_of() == PieceType.Pawn or m.is_capture()) {
            self.history[self.game_ply].fifty = 0;
        }

        // Debug-only sanity checks to catch misuse of flags leading to corruption
        if (castling_debug) {
            const to_pc_dbg = self.board[m.to];
            const from_pc_dbg = self.board[m.from];
            // Ensure from square contains a piece of the moving side
            if (from_pc_dbg == Piece.NO_PIECE or from_pc_dbg.color() != C) {
                std.debug.print("[error] move from empty/wrong-color square {s} (pc={c}) for side {s}, flags={d}\n",
                    .{ sq_to_coord[m.from], if (from_pc_dbg == Piece.NO_PIECE) '.' else PIECE_STR[@intFromEnum(from_pc_dbg)], if (C==.White) "W" else "B", m.flags.toU4() });
                @panic("move from empty or wrong-color square");
            }
            // Quiet-like moves must not overwrite an occupied square (except within castling branches which handle overlaps)
            if (m.flags == MoveFlags.QUIET or m.flags == MoveFlags.DOUBLE_PUSH or
                m.flags == MoveFlags.PR_KNIGHT or m.flags == MoveFlags.PR_BISHOP or m.flags == MoveFlags.PR_ROOK or m.flags == MoveFlags.PR_QUEEN)
            {
                if (to_pc_dbg != Piece.NO_PIECE) {
                    std.debug.print("[error] QUIET-like move overwrites occupied square {s} by {c}, flags={d}\n", .{
                        sq_to_coord[m.to], PIECE_STR[@intFromEnum(from_pc_dbg)], m.flags.toU4(),
                    });
                    @panic("quiet move overwriting occupied square");
                }
            }
            // Capture must capture a piece (EN_PASSANT handled in its own branch)
            if (m.flags == MoveFlags.CAPTURE or m.flags == MoveFlags.PC_KNIGHT or m.flags == MoveFlags.PC_BISHOP or m.flags == MoveFlags.PC_ROOK or m.flags == MoveFlags.PC_QUEEN) {
                if (m.flags != MoveFlags.CAPTURE and (m.flags == MoveFlags.PC_KNIGHT or m.flags == MoveFlags.PC_BISHOP or m.flags == MoveFlags.PC_ROOK or m.flags == MoveFlags.PC_QUEEN)) {
                    // promotion with capture: destination must have a piece
                    if (to_pc_dbg == Piece.NO_PIECE) {
                        std.debug.print("[error] PROMOTION capture to empty square {s} from {s}\n", .{ sq_to_coord[m.to], sq_to_coord[m.from] });
                        @panic("promotion capture to empty square");
                    }
                } else if (m.flags == MoveFlags.CAPTURE) {
                    if (to_pc_dbg == Piece.NO_PIECE) {
                        std.debug.print("[error] CAPTURE to empty square {s} from {s}\n", .{ sq_to_coord[m.to], sq_to_coord[m.from] });
                        @panic("capture to empty square");
                    }
                }
            }
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
                if (castling_debug) {
                    const ci_dbg: usize = C.toU4();
                    const kd_dbg: u6 = if (C == .White) Square.g1.toU6() else Square.g8.toU6();
                    const rs_dbg: u6 = self.castle_rook_k_start[ci_dbg].toU6();
                    const rd_dbg: u6 = if (C == .White) Square.f1.toU6() else Square.f8.toU6();
                    std.debug.print("[castling-play OO] {s} from={s} kd={s} rs={s} rd={s}\n",
                        .{ if (C==.White) "W" else "B",
                           sq_to_coord[m.from], sq_to_coord[kd_dbg], sq_to_coord[rs_dbg], sq_to_coord[rd_dbg] });
                }
                const ci: usize = C.toU4();
                const kd: u6 = if (C == .White) Square.g1.toU6() else Square.g8.toU6();
                const rs: u6 = self.castle_rook_k_start[ci].toU6();
                const rd: u6 = if (C == .White) Square.f1.toU6() else Square.f8.toU6();
                if (rs == kd) {
                    // Rook occupies king destination: remove rook, move king, then place rook at rd
                    const rook_pc = self.board[rs];
                    self.remove_piece(rs);
                    if (m.from != kd) self.move_piece_quiet(m.from, kd);
                    self.put_piece(rook_pc, rd);
                    if (nnue.engine_using_nnue) {
                        self.delta.remove_piece(rook_pc, rs);
                        const kpc = if (C == .White) Piece.WHITE_KING else Piece.BLACK_KING;
                        self.delta.move_piece_quiet(kpc, m.from, kd);
                        self.delta.put_piece(rook_pc, rd);
                    }
                } else if (rs == rd) {
                    // Rook already on its destination square; only move the king
                    if (m.from != kd) self.move_piece_quiet(m.from, kd);
                    if (nnue.engine_using_nnue) {
                        const kpc = if (C == .White) Piece.WHITE_KING else Piece.BLACK_KING;
                        if (m.from != kd) self.delta.move_piece_quiet(kpc, m.from, kd);
                    }
                } else {
                    if (m.from != kd) self.move_piece_quiet(m.from, kd);
                    self.move_piece_quiet(rs, rd);
                    if (nnue.engine_using_nnue) {
                        const kpc = if (C == .White) Piece.WHITE_KING else Piece.BLACK_KING;
                        const rpc = if (C == .White) Piece.WHITE_ROOK else Piece.BLACK_ROOK;
                        if (m.from != kd) self.delta.move_piece_quiet(kpc, m.from, kd);
                        self.delta.move_piece_quiet(rpc, rs, rd);
                    }
                }
            },     
            MoveFlags.OOO => {
                if (castling_debug) {
                    const ci_dbg: usize = C.toU4();
                    const kd_dbg: u6 = if (C == .White) Square.c1.toU6() else Square.c8.toU6();
                    const rs_dbg: u6 = self.castle_rook_q_start[ci_dbg].toU6();
                    const rd_dbg: u6 = if (C == .White) Square.d1.toU6() else Square.d8.toU6();
                    std.debug.print("[castling-play OOO] {s} from={s} kd={s} rs={s} rd={s}\n",
                        .{ if (C==.White) "W" else "B",
                           sq_to_coord[m.from], sq_to_coord[kd_dbg], sq_to_coord[rs_dbg], sq_to_coord[rd_dbg] });
                }
                const ci: usize = C.toU4();
                const kd: u6 = if (C == .White) Square.c1.toU6() else Square.c8.toU6();
                const rs: u6 = self.castle_rook_q_start[ci].toU6();
                const rd: u6 = if (C == .White) Square.d1.toU6() else Square.d8.toU6();
                if (rs == kd) {
                    const rook_pc = self.board[rs];
                    self.remove_piece(rs);
                    if (m.from != kd) self.move_piece_quiet(m.from, kd);
                    self.put_piece(rook_pc, rd);
                    if (nnue.engine_using_nnue) {
                        self.delta.remove_piece(rook_pc, rs);
                        const kpc = if (C == .White) Piece.WHITE_KING else Piece.BLACK_KING;
                        self.delta.move_piece_quiet(kpc, m.from, kd);
                        self.delta.put_piece(rook_pc, rd);
                    }
                } else if (rs == rd) {
                    // Rook already on its destination square; only move the king
                    if (m.from != kd) self.move_piece_quiet(m.from, kd);
                    if (nnue.engine_using_nnue) {
                        const kpc = if (C == .White) Piece.WHITE_KING else Piece.BLACK_KING;
                        if (m.from != kd) self.delta.move_piece_quiet(kpc, m.from, kd);
                    }
                } else {
                    if (m.from != kd) self.move_piece_quiet(m.from, kd);
                    self.move_piece_quiet(rs, rd);
                    if (nnue.engine_using_nnue) {
                        const kpc = if (C == .White) Piece.WHITE_KING else Piece.BLACK_KING;
                        const rpc = if (C == .White) Piece.WHITE_ROOK else Piece.BLACK_ROOK;
                        if (m.from != kd) self.delta.move_piece_quiet(kpc, m.from, kd);
                        self.delta.move_piece_quiet(rpc, rs, rd);
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
                if (castling_debug) {
                    const ci_dbg: usize = C.toU4();
                    const kd_dbg: u6 = if (C == .White) Square.g1.toU6() else Square.g8.toU6();
                    const rs_dbg: u6 = self.castle_rook_k_start[ci_dbg].toU6();
                    const rd_dbg: u6 = if (C == .White) Square.f1.toU6() else Square.f8.toU6();
                    std.debug.print("[castling-undo OO] {s} to={s} kd={s} rs={s} rd={s}\n",
                        .{ if (C==.White) "W" else "B",
                           sq_to_coord[m.to], sq_to_coord[kd_dbg], sq_to_coord[rs_dbg], sq_to_coord[rd_dbg] });
                    std.debug.print("  BKbb=0x{X} BRbb=0x{X}\n", .{ self.piece_bb[Piece.BLACK_KING.toU4()], self.piece_bb[Piece.BLACK_ROOK.toU4()] });
                    const pc_kd = self.board[kd_dbg];
                    const pc_rd = self.board[rd_dbg];
                    const pc_rs = self.board[rs_dbg];
                    std.debug.print("  before: kd={s}({c}) rd={s}({c}) rs={s}({c})\n",
                        .{ sq_to_coord[kd_dbg], if (pc_kd==Piece.NO_PIECE) '.' else PIECE_STR[@intFromEnum(pc_kd)],
                           sq_to_coord[rd_dbg], if (pc_rd==Piece.NO_PIECE) '.' else PIECE_STR[@intFromEnum(pc_rd)],
                           sq_to_coord[rs_dbg], if (pc_rs==Piece.NO_PIECE) '.' else PIECE_STR[@intFromEnum(pc_rs)] });
                }
                const ci: usize = C.toU4();
                const kd: u6 = if (C == .White) Square.g1.toU6() else Square.g8.toU6();
                const rs: u6 = self.castle_rook_k_start[ci].toU6();
                const rd: u6 = if (C == .White) Square.f1.toU6() else Square.f8.toU6();
                // Overlap-safe undo: remove rook from its castled square (if it moved),
                // move king back, then restore rook to its starting square.
                const rook_moved: bool = (rs != rd);
                var rook_pc: Piece = Piece.NO_PIECE;
                if (rook_moved) {
                    rook_pc = self.board[rd];
                    if (rook_pc != Piece.NO_PIECE) self.remove_piece(rd);
                }
                if (m.from != kd) self.move_piece_quiet(kd, m.from);
                if (rook_moved) self.put_piece(rook_pc, rs);
                if (castling_debug) {
                    std.debug.print("  after: BKbb=0x{X} BRbb=0x{X}\n", .{ self.piece_bb[Piece.BLACK_KING.toU4()], self.piece_bb[Piece.BLACK_ROOK.toU4()] });
                }
            },     
            MoveFlags.OOO => {
                if (castling_debug) {
                    const ci_dbg: usize = C.toU4();
                    const kd_dbg: u6 = if (C == .White) Square.c1.toU6() else Square.c8.toU6();
                    const rs_dbg: u6 = self.castle_rook_q_start[ci_dbg].toU6();
                    const rd_dbg: u6 = if (C == .White) Square.d1.toU6() else Square.d8.toU6();
                    std.debug.print("[castling-undo OOO] {s} to={s} kd={s} rs={s} rd={s}\n",
                        .{ if (C==.White) "W" else "B",
                           sq_to_coord[m.to], sq_to_coord[kd_dbg], sq_to_coord[rs_dbg], sq_to_coord[rd_dbg] });
                    std.debug.print("  BKbb=0x{X} BRbb=0x{X}\n", .{ self.piece_bb[Piece.BLACK_KING.toU4()], self.piece_bb[Piece.BLACK_ROOK.toU4()] });
                    const pc_kd = self.board[kd_dbg];
                    const pc_rd = self.board[rd_dbg];
                    const pc_rs = self.board[rs_dbg];
                    std.debug.print("  before: kd={s}({c}) rd={s}({c}) rs={s}({c})\n",
                        .{ sq_to_coord[kd_dbg], if (pc_kd==Piece.NO_PIECE) '.' else PIECE_STR[@intFromEnum(pc_kd)],
                           sq_to_coord[rd_dbg], if (pc_rd==Piece.NO_PIECE) '.' else PIECE_STR[@intFromEnum(pc_rd)],
                           sq_to_coord[rs_dbg], if (pc_rs==Piece.NO_PIECE) '.' else PIECE_STR[@intFromEnum(pc_rs)] });
                }
                const ci: usize = C.toU4();
                const kd: u6 = if (C == .White) Square.c1.toU6() else Square.c8.toU6();
                const rs: u6 = self.castle_rook_q_start[ci].toU6();
                const rd: u6 = if (C == .White) Square.d1.toU6() else Square.d8.toU6();
                // Overlap-safe undo: same sequence as OO
                const rook_moved_q: bool = (rs != rd);
                var rook_pc_q: Piece = Piece.NO_PIECE;
                if (rook_moved_q) {
                    rook_pc_q = self.board[rd];
                    if (rook_pc_q != Piece.NO_PIECE) self.remove_piece(rd);
                }
                if (m.from != kd) self.move_piece_quiet(kd, m.from);
                if (rook_moved_q) self.put_piece(rook_pc_q, rs);
                if (castling_debug) {
                    std.debug.print("  after: BKbb=0x{X} BRbb=0x{X}\n", .{ self.piece_bb[Piece.BLACK_KING.toU4()], self.piece_bb[Piece.BLACK_ROOK.toU4()] });
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

    pub fn calculate_hash(self: Position) u64 {
        var hash: u64 = 0;

        for (0..64) |s_idx| {
            const pc = self.board[s_idx];
            const pc_idx = pc.toU4();
            const zh = zobrist.zobrist_table[pc_idx][s_idx];
            if (zh != 0) {
                hash ^= zh;

                if (pc.type_of() == PieceType.Pawn) {
                    self.pawn_hash ^= zh;
                } else {
                    self.non_pawn_hash[pc.color().toU4()] ^= zh;
                }         
                if (pc.type_of() == PieceType.Rook or pc.type_of() == PieceType.Queen) {
                    self.major_hash ^= zh;
                } else if (pc.type_of() == PieceType.Bishop or pc.type_of() == PieceType.Knight) {
                    self.minor_hash ^= zh;
                }

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
        std.debug.print("Pawn hash: 0x{x}\n", .{self.pawn_hash});
        std.debug.print("Non-pawn hash: 0x{x}, 0x{x}\n", .{self.non_pawn_hash[0], self.non_pawn_hash[1]});
        std.debug.print("Major hash: 0x{x}\n", .{self.major_hash});
        std.debug.print("Minor hash: 0x{x}\n", .{self.minor_hash});
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
        std.debug.print("Pawn hash: 0x{x}\n", .{self.pawn_hash});
        std.debug.print("Non-pawn hash: 0x{x}, 0x{x}\n", .{self.non_pawn_hash[0], self.non_pawn_hash[1]});
        std.debug.print("Major hash: 0x{x}\n", .{self.major_hash});
        std.debug.print("Minor hash: 0x{x}\n", .{self.minor_hash});        
        std.debug.print("Position eval: {}\n", .{self.eval.eval(self, Color.White)});
        std.debug.print("Phase white: {}, phase black: {}\n", .{self.eval.phase[Color.White.toU4()], self.eval.phase[Color.Black.toU4()]});
    }    

    const FenParseError = error{
        MissingField,
        MissingCastlingRights,
        InvalidPosition,
        InvalidActiveColor,
        InvalidCastlingRights,
        InvalidEnPassant,
        InvalidHalfMoveCounter,
        InvalidFullMoveCounter,
    };

    pub fn set(self: *Position, fen: []const u8) !void {

        self.* = Position.new();
        self.fen_error_len = 0;
        var parts = std.mem.splitScalar(u8, fen, ' ');
        const fen_position = parts.next().?;

        var ranks = std.mem.splitScalar(u8, fen_position, '/');
        var rank: u6 = 0;
        while (ranks.next()) |entry| {
            var file: u6 = 0;
            for (entry) |c| {
                const sq_u6: u6 = (7 - rank) * 8 + file;
                const square = Square.fromU6(sq_u6);
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
                        // Record clearer diagnostic: unexpected piece letter and its square
                        var buf: [128]u8 = undefined;
                        const coord = sq_to_coord[sq_u6];
                        const msg = std.fmt.bufPrint(&buf, "Unexpected piece '{c}' at {s}", .{ c, coord }) catch "";
                        const mlen = @min(msg.len, self.fen_error.len);
                        @memcpy(self.fen_error[0..mlen], msg[0..mlen]);
                        self.fen_error_len = mlen;
                        return FenParseError.InvalidPosition;
                    },
                };
                self.add_piece_to_board(piece, square.toU6());
                file += 1;
            }
            if (file != 8) {
                // Record rank width issue
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Invalid rank width at rank {} (saw {} files)", .{ 8 - rank, file }) catch "";
                const mlen = @min(msg.len, self.fen_error.len);
                @memcpy(self.fen_error[0..mlen], msg[0..mlen]);
                self.fen_error_len = mlen;
                return FenParseError.InvalidPosition;
            }
            rank += 1;
        }
        if (rank != 8) {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Invalid position: expected 8 ranks, got {}", .{ rank }) catch "";
            const mlen = @min(msg.len, self.fen_error.len);
            @memcpy(self.fen_error[0..mlen], msg[0..mlen]);
            self.fen_error_len = mlen;
            return FenParseError.InvalidPosition;
        }

        const active_color_fen = parts.next().?;
        if (std.mem.eql(u8, active_color_fen, "w")) {
            self.side_to_play = Color.White;
        } else if (std.mem.eql(u8, active_color_fen, "b")) {
            self.side_to_play = Color.Black;
            self.hash ^= zobrist.side_key;
        } else {
            return FenParseError.InvalidActiveColor;
        }

        const castling_fen = parts.next() orelse return FenParseError.MissingCastlingRights;

        // Initialize Chess960 castling starts from current board
        inline for (.{ Color.White, Color.Black }, 0..) |c, ci| {
            const king_bb = self.bitboard_of_pt(c, PieceType.King);
            if (king_bb == 0) {
                self.castle_king_start[ci] = Square.NO_SQUARE;
            } else {
                self.castle_king_start[ci] = Square.fromU6(bb.get_ls1b_index(king_bb));
            }
            const rook_bb_rank = self.bitboard_of_pt(c, PieceType.Rook) & bb.MASK_RANK[if (c == .White) Rank.RANK1.toU3() else Rank.RANK8.toU3()];
            if (rook_bb_rank != 0 and king_bb != 0) {
                const ks = self.castle_king_start[ci].toU6();
                const kfile: u3 = @truncate(ks & 7);
                // kingside rook: closest rook with file > king
                var found_k: bool = false;
                // Ensure addition happens in a wider type than u3
                var f: u6 = @as(u6, @intCast(kfile)) + 1;
                const rrank: u6 = @truncate(ks >> 3);
                while (f < 8) : (f += 1) {
                    const sq: u6 = (rrank * 8) + f;
                    if ((rook_bb_rank & SQUARE_BB[sq]) != 0) { self.castle_rook_k_start[ci] = Square.fromU6(sq); found_k = true; break; }
                }
                if (!found_k) self.castle_rook_k_start[ci] = Square.NO_SQUARE;
                // queenside rook: closest rook with file < king
                var found_q: bool = false;
                var f2i: i32 = @as(i32, kfile) - 1;
                const rrank2: u6 = @truncate(ks >> 3);
                while (f2i >= 0) : (f2i -= 1) {
                    const f2: u6 = @truncate(@as(u6, @intCast(f2i)));
                    const sq2: u6 = (rrank2 * 8) + f2;
                    if ((rook_bb_rank & SQUARE_BB[sq2]) != 0) { self.castle_rook_q_start[ci] = Square.fromU6(sq2); found_q = true; break; }
                }
                if (!found_q) self.castle_rook_q_start[ci] = Square.NO_SQUARE;
            } else {
                self.castle_rook_k_start[ci] = Square.NO_SQUARE;
                self.castle_rook_q_start[ci] = Square.NO_SQUARE;
            }
        }

        // Debug: dump initial 960 king/rook start squares
        if (castling_debug) {
            std.debug.print("[960-start] W: K={s} Rk={s} Rq={s}\n", .{
                sq_to_coord[self.castle_king_start[Color.White.toU4()].toU()],
                if (self.castle_rook_k_start[Color.White.toU4()] == Square.NO_SQUARE) "--" else sq_to_coord[self.castle_rook_k_start[Color.White.toU4()].toU()],
                if (self.castle_rook_q_start[Color.White.toU4()] == Square.NO_SQUARE) "--" else sq_to_coord[self.castle_rook_q_start[Color.White.toU4()].toU()],
            });
            std.debug.print("[960-start] B: K={s} Rk={s} Rq={s}\n", .{
                sq_to_coord[self.castle_king_start[Color.Black.toU4()].toU()],
                if (self.castle_rook_k_start[Color.Black.toU4()] == Square.NO_SQUARE) "--" else sq_to_coord[self.castle_rook_k_start[Color.Black.toU4()].toU()],
                if (self.castle_rook_q_start[Color.Black.toU4()] == Square.NO_SQUARE) "--" else sq_to_coord[self.castle_rook_q_start[Color.Black.toU4()].toU()],
            });
        }

        // Build dynamic entry mask from tracked squares; then clear bits for allowed rights
        var dynamic_all_castle_mask: u64 = 0;
        if (self.castle_king_start[Color.White.toU4()] != Square.NO_SQUARE and self.castle_rook_k_start[Color.White.toU4()] != Square.NO_SQUARE)
            dynamic_all_castle_mask |= SQUARE_BB[self.castle_king_start[Color.White.toU4()].toU6()] | SQUARE_BB[self.castle_rook_k_start[Color.White.toU4()].toU6()];
        if (self.castle_king_start[Color.White.toU4()] != Square.NO_SQUARE and self.castle_rook_q_start[Color.White.toU4()] != Square.NO_SQUARE)
            dynamic_all_castle_mask |= SQUARE_BB[self.castle_king_start[Color.White.toU4()].toU6()] | SQUARE_BB[self.castle_rook_q_start[Color.White.toU4()].toU6()];
        if (self.castle_king_start[Color.Black.toU4()] != Square.NO_SQUARE and self.castle_rook_k_start[Color.Black.toU4()] != Square.NO_SQUARE)
            dynamic_all_castle_mask |= SQUARE_BB[self.castle_king_start[Color.Black.toU4()].toU6()] | SQUARE_BB[self.castle_rook_k_start[Color.Black.toU4()].toU6()];
        if (self.castle_king_start[Color.Black.toU4()] != Square.NO_SQUARE and self.castle_rook_q_start[Color.Black.toU4()] != Square.NO_SQUARE)
            dynamic_all_castle_mask |= SQUARE_BB[self.castle_king_start[Color.Black.toU4()].toU6()] | SQUARE_BB[self.castle_rook_q_start[Color.Black.toU4()].toU6()];
        self.history[self.game_ply].entry = dynamic_all_castle_mask;

        for (castling_fen) |cf| {
            switch (cf) {
                'K' =>  {
                    if (self.castle_king_start[Color.White.toU4()] != Square.NO_SQUARE and self.castle_rook_k_start[Color.White.toU4()] != Square.NO_SQUARE) {
                        self.history[self.game_ply].entry &= ~(SQUARE_BB[self.castle_king_start[Color.White.toU4()].toU6()] | SQUARE_BB[self.castle_rook_k_start[Color.White.toU4()].toU6()]);
                        self.history[self.game_ply].castling |= Castling.WK.toU4();
                    }
                },
                'Q' => {
                    if (self.castle_king_start[Color.White.toU4()] != Square.NO_SQUARE and self.castle_rook_q_start[Color.White.toU4()] != Square.NO_SQUARE) {
                        self.history[self.game_ply].entry &= ~(SQUARE_BB[self.castle_king_start[Color.White.toU4()].toU6()] | SQUARE_BB[self.castle_rook_q_start[Color.White.toU4()].toU6()]);
                        self.history[self.game_ply].castling |= Castling.WQ.toU4();
                    }
                },
                'k' => {
                    if (self.castle_king_start[Color.Black.toU4()] != Square.NO_SQUARE and self.castle_rook_k_start[Color.Black.toU4()] != Square.NO_SQUARE) {
                        self.history[self.game_ply].entry &= ~(SQUARE_BB[self.castle_king_start[Color.Black.toU4()].toU6()] | SQUARE_BB[self.castle_rook_k_start[Color.Black.toU4()].toU6()]);
                        self.history[self.game_ply].castling |= Castling.BK.toU4();
                    }
                },
                'q' => {
                    if (self.castle_king_start[Color.Black.toU4()] != Square.NO_SQUARE and self.castle_rook_q_start[Color.Black.toU4()] != Square.NO_SQUARE) {
                        self.history[self.game_ply].entry &= ~(SQUARE_BB[self.castle_king_start[Color.Black.toU4()].toU6()] | SQUARE_BB[self.castle_rook_q_start[Color.Black.toU4()].toU6()]);
                        self.history[self.game_ply].castling |= Castling.BQ.toU4();
                    }
                },
                // Shredder-FEN letters for rooks allowed to castle
                'A'...'H' => {
                    self.is_chess960 = true;
                    // White rook file
                    if (self.castle_king_start[Color.White.toU4()] != Square.NO_SQUARE) {
                        const kf: u3 = self.castle_king_start[Color.White.toU4()].file_of().toU3();
                        const rf: u3 = @truncate(@as(u8, cf - 'A'));
                        if (rf > kf) {
                            // kingside
                            if (self.castle_rook_k_start[Color.White.toU4()] != Square.NO_SQUARE) {
                                self.history[self.game_ply].entry &= ~(SQUARE_BB[self.castle_king_start[Color.White.toU4()].toU6()] | SQUARE_BB[self.castle_rook_k_start[Color.White.toU4()].toU6()]);
                                self.history[self.game_ply].castling |= Castling.WK.toU4();
                            }
                        } else if (rf < kf) {
                            // queenside
                            if (self.castle_rook_q_start[Color.White.toU4()] != Square.NO_SQUARE) {
                                self.history[self.game_ply].entry &= ~(SQUARE_BB[self.castle_king_start[Color.White.toU4()].toU6()] | SQUARE_BB[self.castle_rook_q_start[Color.White.toU4()].toU6()]);
                                self.history[self.game_ply].castling |= Castling.WQ.toU4();
                            }
                        }
                    }
                },
                'a'...'h' => {
                    self.is_chess960 = true;
                    if (self.castle_king_start[Color.Black.toU4()] != Square.NO_SQUARE) {
                        const kf: u3 = self.castle_king_start[Color.Black.toU4()].file_of().toU3();
                        const rf: u3 = @truncate(@as(u8, cf - 'a'));
                        if (rf > kf) {
                            if (self.castle_rook_k_start[Color.Black.toU4()] != Square.NO_SQUARE) {
                                self.history[self.game_ply].entry &= ~(SQUARE_BB[self.castle_king_start[Color.Black.toU4()].toU6()] | SQUARE_BB[self.castle_rook_k_start[Color.Black.toU4()].toU6()]);
                                self.history[self.game_ply].castling |= Castling.BK.toU4();
                            }
                        } else if (rf < kf) {
                            if (self.castle_rook_q_start[Color.Black.toU4()] != Square.NO_SQUARE) {
                                self.history[self.game_ply].entry &= ~(SQUARE_BB[self.castle_king_start[Color.Black.toU4()].toU6()] | SQUARE_BB[self.castle_rook_q_start[Color.Black.toU4()].toU6()]);
                                self.history[self.game_ply].castling |= Castling.BQ.toU4();
                            }
                        }
                    }
                },
                '-' => break,
                else => return FenParseError.InvalidCastlingRights,
            }
        }

        // En passant: optional in many FEN strings used by UCI "position fen".
        // Accept missing field and default to no en passant square.
        if (parts.next()) |en_passant_fen| {
            if (!std.mem.eql(u8, en_passant_fen, "-")) {
                self.history[self.game_ply].epsq = Square.from_str(en_passant_fen);
                self.hash ^= zobrist.enpassant_keys[self.history[self.game_ply].epsq.file_of().toU3()];
            }
        } else {
            // No en passant field provided; leave default (no EP)
        }

        self.hash ^= zobrist.castling_keys[self.history[self.game_ply].castling];
        // Build per-square castling-rights clear table based on detected starts
        self.rebuild_castle_rights_clear_table();
        self.history[self.game_ply].hash_key = self.hash;

        // Parse optional halfmove and fullmove numbers
        if (parts.next()) |halfmove_fen| {
            self.history[self.game_ply].fifty = std.fmt.parseInt(u16, halfmove_fen, 10) catch self.history[self.game_ply].fifty;
        }
        if (parts.next()) |fullmove_fen| {
            self.fullmove_number = std.fmt.parseInt(u32, fullmove_fen, 10) catch self.fullmove_number;
        }
  
        // Tole je novo
        self.delta.reset();
        self.history[0].accumulator = nnue.refresh_accumulator(self.*);
        self.history[0].accumulator.computed_accumulation = true;
        self.history[0].accumulator.computed_score = false;   
        // Tole je novo     

    }

    fn rebuild_castle_rights_clear_table(self: *Position) void {
        // Reset
        self.castle_rights_clear_by_sq = .{0} ** 64;
        // White
        if (self.castle_king_start[Color.White.toU4()] != Square.NO_SQUARE) {
            const ks = self.castle_king_start[Color.White.toU4()].toU6();
            self.castle_rights_clear_by_sq[ks] |= (Castling.WK.toU4() | Castling.WQ.toU4());
        }
        if (self.castle_rook_k_start[Color.White.toU4()] != Square.NO_SQUARE) {
            const rs = self.castle_rook_k_start[Color.White.toU4()].toU6();
            self.castle_rights_clear_by_sq[rs] |= Castling.WK.toU4();
        }
        if (self.castle_rook_q_start[Color.White.toU4()] != Square.NO_SQUARE) {
            const rs = self.castle_rook_q_start[Color.White.toU4()].toU6();
            self.castle_rights_clear_by_sq[rs] |= Castling.WQ.toU4();
        }
        // Black
        if (self.castle_king_start[Color.Black.toU4()] != Square.NO_SQUARE) {
            const ks = self.castle_king_start[Color.Black.toU4()].toU6();
            self.castle_rights_clear_by_sq[ks] |= (Castling.BK.toU4() | Castling.BQ.toU4());
        }
        if (self.castle_rook_k_start[Color.Black.toU4()] != Square.NO_SQUARE) {
            const rs = self.castle_rook_k_start[Color.Black.toU4()].toU6();
            self.castle_rights_clear_by_sq[rs] |= Castling.BK.toU4();
        }
        if (self.castle_rook_q_start[Color.Black.toU4()] != Square.NO_SQUARE) {
            const rs = self.castle_rook_q_start[Color.Black.toU4()].toU6();
            self.castle_rights_clear_by_sq[rs] |= Castling.BQ.toU4();
        }
    }

    /// Converts the current state of a `Position` struct into a FEN string.
    /// The caller is responsible for freeing the returned string using `allocator`.
    pub fn get_fen(self: *Position, allocator: std.mem.Allocator) ![]u8 {
        var fen_parts = try std.ArrayList(u8).initCapacity(allocator, 128);
        defer fen_parts.deinit(allocator);

        // --- 1. Piece placement ---
        var rank: i8 = 7; // Start from rank 8 (index 7)
        while (rank >= 0) : (rank -= 1) {
            var file: u8 = 0;
            var empty_count: u8 = 0;

            while (file < 8) : (file += 1) {
                const sq_index = @as(u6, @intCast((@as(u8, @intCast(rank)) * 8) + file));
                const piece = self.board[sq_index];

                if (piece == Piece.NO_PIECE) {
                    empty_count += 1;
                } else {
                    // If we were counting empty squares, add the count to the FEN
                    if (empty_count > 0) {
                        try fen_parts.append(allocator, '0' + empty_count);
                        empty_count = 0;
                    }
                    // Add the piece character
                    // Assuming PIECE_STR exists and maps pieces correctly
                    // Adjust indexing if your Piece enum or PIECE_STR is different
                    const piece_char = PIECE_STR[@intFromEnum(piece)];
                    try fen_parts.append(allocator, piece_char);
                }
            }
            // After processing a rank, add any trailing empty squares
            if (empty_count > 0) {
                try fen_parts.append(allocator, '0' + empty_count);
            }
            // Add rank separator, except after the last rank (rank 1)
            if (rank > 0) {
                try fen_parts.append(allocator, '/');
            }
        }

        // --- 2. Active color ---
        try fen_parts.append(allocator, ' ');
        if (self.side_to_play == Color.White) {
            try fen_parts.append(allocator, 'w');
        } else {
            try fen_parts.append(allocator, 'b');
        }

        // --- 3. Castling availability (Shredder-FEN aware) ---
        try fen_parts.append(allocator, ' ');
        var has_castling = false;
        const castling_rights = self.history[self.game_ply].castling;

        if (self.is_chess960) {
            // Always output Shredder letters for 960/DFRC
            if ((castling_rights & Castling.WK.toU4()) != 0) {
                has_castling = true;
                const rs = self.castle_rook_k_start[Color.White.toU4()];
                if (rs != Square.NO_SQUARE) {
                    const base: u8 = 'A';
                    const f: u8 = @as(u8, @intCast(rs.file_of().toU3()));
                    try fen_parts.append(allocator, base + f);
                }
            }
            if ((castling_rights & Castling.WQ.toU4()) != 0) {
                has_castling = true;
                const rs = self.castle_rook_q_start[Color.White.toU4()];
                if (rs != Square.NO_SQUARE) {
                    const base: u8 = 'A';
                    const f: u8 = @as(u8, @intCast(rs.file_of().toU3()));
                    try fen_parts.append(allocator, base + f);
                }
            }
            if ((castling_rights & Castling.BK.toU4()) != 0) {
                has_castling = true;
                const rs = self.castle_rook_k_start[Color.Black.toU4()];
                if (rs != Square.NO_SQUARE) {
                    const base: u8 = 'a';
                    const f: u8 = @as(u8, @intCast(rs.file_of().toU3()));
                    try fen_parts.append(allocator, base + f);
                }
            }
            if ((castling_rights & Castling.BQ.toU4()) != 0) {
                has_castling = true;
                const rs = self.castle_rook_q_start[Color.Black.toU4()];
                if (rs != Square.NO_SQUARE) {
                    const base: u8 = 'a';
                    const f: u8 = @as(u8, @intCast(rs.file_of().toU3()));
                    try fen_parts.append(allocator, base + f);
                }
            }
        } else {
            // Determine classical layout per right (K on e-file, rook on h/a for that side)
            const wK_classical = (self.castle_king_start[Color.White.toU4()] == Square.e1 and self.castle_rook_k_start[Color.White.toU4()] == Square.h1);
            const wQ_classical = (self.castle_king_start[Color.White.toU4()] == Square.e1 and self.castle_rook_q_start[Color.White.toU4()] == Square.a1);
            const bK_classical = (self.castle_king_start[Color.Black.toU4()] == Square.e8 and self.castle_rook_k_start[Color.Black.toU4()] == Square.h8);
            const bQ_classical = (self.castle_king_start[Color.Black.toU4()] == Square.e8 and self.castle_rook_q_start[Color.Black.toU4()] == Square.a8);

            // White rights
            if ((castling_rights & Castling.WK.toU4()) != 0) {
                has_castling = true;
                if (wK_classical) {
                    try fen_parts.append(allocator, 'K');
                } else {
                    const rs = self.castle_rook_k_start[Color.White.toU4()];
                    if (rs != Square.NO_SQUARE) {
                        const base: u8 = 'A';
                        const f: u8 = @as(u8, @intCast(rs.file_of().toU3()));
                        try fen_parts.append(allocator, base + f);
                    }
                }
            }
            if ((castling_rights & Castling.WQ.toU4()) != 0) {
                has_castling = true;
                if (wQ_classical) {
                    try fen_parts.append(allocator, 'Q');
                } else {
                    const rs = self.castle_rook_q_start[Color.White.toU4()];
                    if (rs != Square.NO_SQUARE) {
                        const base: u8 = 'A';
                        const f: u8 = @as(u8, @intCast(rs.file_of().toU3()));
                        try fen_parts.append(allocator, base + f);
                    }
                }
            }
            // Black rights
            if ((castling_rights & Castling.BK.toU4()) != 0) {
                has_castling = true;
                if (bK_classical) {
                    try fen_parts.append(allocator, 'k');
                } else {
                    const rs = self.castle_rook_k_start[Color.Black.toU4()];
                    if (rs != Square.NO_SQUARE) {
                        const base: u8 = 'a';
                        const f: u8 = @as(u8, @intCast(rs.file_of().toU3()));
                        try fen_parts.append(allocator, base + f);
                    }
                }
            }
            if ((castling_rights & Castling.BQ.toU4()) != 0) {
                has_castling = true;
                if (bQ_classical) {
                    try fen_parts.append(allocator, 'q');
                } else {
                    const rs = self.castle_rook_q_start[Color.Black.toU4()];
                    if (rs != Square.NO_SQUARE) {
                        const base: u8 = 'a';
                        const f: u8 = @as(u8, @intCast(rs.file_of().toU3()));
                        try fen_parts.append(allocator, base + f);
                    }
                }
            }
        }

        if (!has_castling) {
            try fen_parts.append(allocator, '-');
        }

        // --- 4. En passant target square ---
        try fen_parts.append(allocator, ' ');
        const ep_square = self.history[self.game_ply].epsq; // Assuming Square enum
        if (ep_square != Square.NO_SQUARE) {
            // Assuming sq_to_coord array exists as in your provided code
            const ep_str = sq_to_coord[ep_square.toU()]; // Use toU() which returns usize
            try fen_parts.appendSlice(allocator, ep_str);
        } else {
            try fen_parts.append(allocator, '-');
        }

        // --- 5. Halfmove clock (50-move counter) ---
        try fen_parts.append(allocator, ' ');
        // Assuming fifty_move_counter or similar field exists in history
        const halfmove_clock = self.history[self.game_ply].fifty; // Adjust field name if needed
        var halfmove_buf: [10]u8 = undefined; // Buffer for integer to string conversion
        const halfmove_str = try std.fmt.bufPrint(&halfmove_buf, "{}", .{halfmove_clock});
        try fen_parts.appendSlice(allocator, halfmove_str);

        // --- 6. Fullmove number ---
        try fen_parts.append(allocator, ' ');
        // Output fullmove number parsed from FEN (tracked on Position)
        const fullmove_number: u32 = self.fullmove_number;
        var fullmove_buf: [10]u8 = undefined;
        const fullmove_str = try std.fmt.bufPrint(&fullmove_buf, "{}", .{fullmove_number});
        try fen_parts.appendSlice(allocator, fullmove_str);

        // Null-terminate the string
        try fen_parts.append(allocator, 0);
        // Resize to exclude the null terminator for the returned slice
        const fen_string = try fen_parts.toOwnedSlice(allocator);
        return fen_string[0 .. fen_string.len - 1]; // Exclude the null terminator
    }

    // Generate only evasions
    fn generate_evasions(self: *Position, comptime Us: Color, ctx: MoveGenContext, list: *MoveList) void {

        const Them = Us.change_side();
        var capture_mask: u64 = undefined;
        var quiet_mask: u64 = undefined;

        // Always generate king evasions (escapes + captures)
        self.generate_all_king_moves(ctx, list);
        
        if (ctx.check_count >= 2) return; // Double check: only king moves

        const checker_square = bb.get_ls1b_index(ctx.checkers);
        switch (self.board[checker_square]) {
            Piece.new(Them, PieceType.Pawn) => {
                // Check for en passant capture if checker is a pawn that just double-pushed
                self.generate_pawn_checker_moves(Us, ctx, list, checker_square);
                return;
            },
            Piece.new(Them, PieceType.King) => {
                self.generate_king_checker_moves(Us, ctx, list, checker_square);
                return;
            },
            else => {
                // Must capture the checking piece or block it (slider)
                capture_mask = ctx.checkers;
                quiet_mask = attacks.SQUARES_BETWEEN_BB[ctx.our_king][checker_square];
            },
        }

        self.generate_noisy_moves(Us, ctx, list, capture_mask, quiet_mask);
        self.generate_quiet_moves(Us, ctx, list, quiet_mask);
    }


    pub fn generate_all_no_evasion(self: *Position, comptime Us: Color, ctx: MoveGenContext, list: *MoveList) void {
        const capture_mask = ctx.them_bb;
        const quiet_mask = ~ctx.all_bb;

        self.generate_en_passant_moves(Us, ctx, list);
        self.generate_all_pinned_slider_moves(Us, ctx, list, quiet_mask, capture_mask);
        self.generate_all_pinned_pawn_moves(Us, ctx, list, capture_mask);
        self.generate_noisy_moves(Us, ctx, list, capture_mask, quiet_mask);        
        self.generate_all_king_moves(ctx, list);
        self.generate_castling_moves(Us, ctx, list);
        self.generate_quiet_moves(Us, ctx, list, quiet_mask);

        return;        
    }

    pub fn generate_all_captures_no_evasion(self: *Position, comptime Us: Color, ctx: MoveGenContext, list: *MoveList) void {
        const capture_mask = ctx.them_bb;
        const quiet_mask = ~ctx.all_bb;

        self.generate_en_passant_moves(Us, ctx, list);
        self.generate_pinned_slider_moves(Us, ctx, list, quiet_mask, capture_mask, true);
        self.generate_noisy_pinned_pawn_moves(Us, ctx, list, capture_mask);
        self.generate_noisy_moves(Us, ctx, list, capture_mask, quiet_mask);
        self.generate_king_moves(ctx, list, true);

        return;
    }

    pub fn generate_all_quiets_no_evasion(self: *Position, comptime Us: Color, ctx: MoveGenContext, list: *MoveList) void {

        const quiet_mask = ~ctx.all_bb;

        self.generate_castling_moves(Us, ctx, list);
        self.generate_quiet_pinned_pawn_moves(Us, ctx, list);
        self.generate_pinned_slider_moves(Us, ctx, list, quiet_mask, 0, false);                
        self.generate_quiet_moves(Us, ctx, list, quiet_mask);
        self.generate_king_moves(ctx, list, false);

        return;
    }

    pub fn debug_castling(self: *Position, comptime Us: Color) void {
        const ctx = self.computeMoveGenContext(Us);
        const ci: usize = Us.toU4();
        const wk = (self.history[self.game_ply].castling & (if (Us == .White) Castling.WK.toU4() else Castling.BK.toU4())) != 0;
        const wq = (self.history[self.game_ply].castling & (if (Us == .White) Castling.WQ.toU4() else Castling.BQ.toU4())) != 0;
        const ks = ctx.our_king;
        const kd_oo: u6 = if (Us == .White) Square.g1.toU6() else Square.g8.toU6();
        const kd_ooo: u6 = if (Us == .White) Square.c1.toU6() else Square.c8.toU6();
        const rs_k = self.castle_rook_k_start[ci];
        const rs_q = self.castle_rook_q_start[ci];
        std.debug.print("Castling debug ({s}): rights K={}, Q={}\n", .{
            if (Us == .White) "White" else "Black", wk, wq,
        });
        std.debug.print("King sq: {s}  KD_OO: {s}  KD_OOO: {s}\n", .{
            sq_to_coord[ks], sq_to_coord[kd_oo], sq_to_coord[kd_ooo],
        });
        std.debug.print("RookK start: {s}  RookQ start: {s}\n", .{
            if (rs_k != Square.NO_SQUARE) sq_to_coord[rs_k.toU6()] else "--",
            if (rs_q != Square.NO_SQUARE) sq_to_coord[rs_q.toU6()] else "--",
        });
        // Kingside 960 check snapshot
        if (wk and rs_k != Square.NO_SQUARE and self.board[rs_k.toU6()] == Piece.new(Us, PieceType.Rook)) {
            const k_path = attacks.SQUARES_BETWEEN_BB[ks][kd_oo];
            const occ_after_k = ctx.all_bb ^ SQUARE_BB[ks];
            const k_blockers = occ_after_k & (k_path & ~SQUARE_BB[rs_k.toU6()]);
            const danger_mask = k_path | SQUARE_BB[kd_oo];
            const rd = (if (Us == .White) Square.f1.toU6() else Square.f8.toU6());
            const rook_path = attacks.SQUARES_BETWEEN_BB[rs_k.toU6()][rd];
            std.debug.print("OO: k_path=0x{x}, k_blockers=0x{x}, danger&mask=0x{x}, rook_path=0x{x}, occ_after_k&rd=0x{x}\n", .{
                k_path, k_blockers, (ctx.danger & danger_mask), rook_path, (occ_after_k & SQUARE_BB[rd]),
            });
        } else {
            std.debug.print("OO: preconditions failed (wk={}, rs_k set={}, rook present={})\n", .{
                wk, rs_k != Square.NO_SQUARE, if (rs_k != Square.NO_SQUARE) self.board[rs_k.toU6()] == Piece.new(Us, PieceType.Rook) else false,
            });
        }
        // Queenside 960 check snapshot
        if (wq and rs_q != Square.NO_SQUARE and self.board[rs_q.toU6()] == Piece.new(Us, PieceType.Rook)) {
            const k_path = attacks.SQUARES_BETWEEN_BB[ks][kd_ooo];
            const occ_after_k = ctx.all_bb ^ SQUARE_BB[ks];
            const k_blockers = occ_after_k & (k_path & ~SQUARE_BB[rs_q.toU6()]);
            const danger_mask = k_path | SQUARE_BB[kd_ooo];
            const rd = (if (Us == .White) Square.d1.toU6() else Square.d8.toU6());
            const rook_path = attacks.SQUARES_BETWEEN_BB[rs_q.toU6()][rd];
            std.debug.print("OOO: k_path=0x{x}, k_blockers=0x{x}, danger&mask=0x{x}, rook_path=0x{x}, occ_after_k&rd=0x{x}\n", .{
                k_path, k_blockers, (ctx.danger & danger_mask), rook_path, (occ_after_k & SQUARE_BB[rd]),
            });
        } else {
            std.debug.print("OOO: preconditions failed (wq={}, rs_q set={}, rook present={})\n", .{
                wq, rs_q != Square.NO_SQUARE, if (rs_q != Square.NO_SQUARE) self.board[rs_q.toU6()] == Piece.new(Us, PieceType.Rook) else false,
            });
        }
    }

    pub fn generate_king_moves(self: *Position, ctx: MoveGenContext, list: *MoveList, comptime noisy: bool) void {
        _ = self;
        const b1 = attacks.piece_attacks(ctx.our_king, ctx.all_bb, PieceType.King) & ~(ctx.us_bb | ctx.danger);

        if (noisy) {
            make_list(Square.fromU6(ctx.our_king), b1 & ctx.them_bb, MoveFlags.CAPTURE, list);   
        } else {  
            make_list(Square.fromU6(ctx.our_king), b1 & ~ctx.them_bb, MoveFlags.QUIET, list);
        }
    }

    pub fn generate_all_king_moves(self: *Position, ctx: MoveGenContext, list: *MoveList) void {
        _ = self;
        const b1 = attacks.piece_attacks(ctx.our_king, ctx.all_bb, PieceType.King) & ~(ctx.us_bb | ctx.danger);

        make_list(Square.fromU6(ctx.our_king), b1 & ctx.them_bb, MoveFlags.CAPTURE, list);   
        make_list(Square.fromU6(ctx.our_king), b1 & ~ctx.them_bb, MoveFlags.QUIET, list);
    }    

    pub fn generate_quiet_moves(self: *Position, comptime Us: Color, ctx: MoveGenContext, list: *MoveList, quiet_mask: u64) void {

        // Non-pinned knights
        var b1 = self.bitboard_of_pt(Us, PieceType.Knight) & ctx.not_pinned;
        while (b1 != 0) {
            const s1 = bb.pop_lsb(&b1);
            const b2 = attacks.piece_attacks(s1, ctx.all_bb, PieceType.Knight);
            make_list(Square.fromU6(s1), b2 & quiet_mask, MoveFlags.QUIET, list);
        }

        // Non-pinned bishops and queens
        b1 = ctx.our_diag_sliders & ctx.not_pinned;
        while (b1 != 0) {
            const s1 = bb.pop_lsb(&b1);
            const targets = attacks.piece_attacks(s1, ctx.all_bb, PieceType.Bishop) & quiet_mask;
            // Filter line-of-sight safety to avoid x-ray beyond first blocker
            var filtered: u64 = 0;
            var tmp = targets;
            while (tmp != 0) {
                const t = bb.pop_lsb(&tmp);
                if ((attacks.SQUARES_BETWEEN_BB[s1][t] & ctx.all_bb) == 0) filtered |= SQUARE_BB[t];
            }
            make_list(Square.fromU6(s1), filtered, MoveFlags.QUIET, list);
        }

        // Non-pinned rooks and queens
        b1 = ctx.our_orth_sliders & ctx.not_pinned;
        while (b1 != 0) {
            const s1 = bb.pop_lsb(&b1);
            const targets = attacks.piece_attacks(s1, ctx.all_bb, PieceType.Rook) & quiet_mask;
            var filtered: u64 = 0;
            var tmp = targets;
            while (tmp != 0) {
                const t = bb.pop_lsb(&tmp);
                if ((attacks.SQUARES_BETWEEN_BB[s1][t] & ctx.all_bb) == 0) filtered |= SQUARE_BB[t];
            }
            make_list(Square.fromU6(s1), filtered, MoveFlags.QUIET, list);
        }

        // Non-pinned pawns not on the last rank
        b1 = self.bitboard_of_pt(Us, PieceType.Pawn) & ctx.not_pinned & ~bb.MASK_RANK[Rank.RANK7.relative_rank(Us).toU3()];
        var b2 = shift(b1, Direction.NORTH.relative_dir(Us)) & ~ctx.all_bb;
        var b3 = shift(b2 & bb.MASK_RANK[Rank.RANK3.relative_rank(Us).toU3()], Direction.NORTH.relative_dir(Us)) & quiet_mask;
        b2 &= quiet_mask;

        while (b2 != 0) {
            const s1 = bb.pop_lsb(&b2);
            list.append(Move.new(Square.fromU6(@as(u6, @intCast(@as(i8, @intCast(s1)) - Direction.NORTH.relative_dir(Us).toI8()))), Square.fromU6(s1), MoveFlags.QUIET));
        }

        while (b3 != 0) {
            const s1 = bb.pop_lsb(&b3);
            list.append(Move.new(Square.fromU6(@as(u6, @intCast(@as(i8, @intCast(s1)) - Direction.NORTH_NORTH.relative_dir(Us).toI8()))), Square.fromU6(s1), MoveFlags.DOUBLE_PUSH));
        }

    }

    pub fn generate_noisy_moves(self: *Position, comptime Us: Color, ctx: MoveGenContext, list: *MoveList, capture_mask: u64, quiet_mask: u64) void {

        // Non-pinned knights
        var b1 = self.bitboard_of_pt(Us, PieceType.Knight) & ctx.not_pinned;
        while (b1 != 0) {
            const s1 = bb.pop_lsb(&b1);
            const b2 = attacks.piece_attacks(s1, ctx.all_bb, PieceType.Knight);
            make_list(Square.fromU6(s1), b2 & capture_mask, MoveFlags.CAPTURE, list);
        }

        // Non-pinned bishops and queens
        b1 = ctx.our_diag_sliders & ctx.not_pinned;
        while (b1 != 0) {
            const s1 = bb.pop_lsb(&b1);
            const targets = attacks.piece_attacks(s1, ctx.all_bb, PieceType.Bishop) & capture_mask;
            var filtered: u64 = 0;
            var tmp = targets;
            while (tmp != 0) {
                const t = bb.pop_lsb(&tmp);
                if ((attacks.SQUARES_BETWEEN_BB[s1][t] & ctx.all_bb) == 0) filtered |= SQUARE_BB[t];
            }
            make_list(Square.fromU6(s1), filtered, MoveFlags.CAPTURE, list);
        }

        // Non-pinned rooks and queens
        b1 = ctx.our_orth_sliders & ctx.not_pinned;
        while (b1 != 0) {
            const s1 = bb.pop_lsb(&b1);
            const targets = attacks.piece_attacks(s1, ctx.all_bb, PieceType.Rook) & capture_mask;
            var filtered: u64 = 0;
            var tmp = targets;
            while (tmp != 0) {
                const t = bb.pop_lsb(&tmp);
                if ((attacks.SQUARES_BETWEEN_BB[s1][t] & ctx.all_bb) == 0) filtered |= SQUARE_BB[t];
            }
            make_list(Square.fromU6(s1), filtered, MoveFlags.CAPTURE, list);
        }

        // Non-pinned pawns not on the last rank
        b1 = self.bitboard_of_pt(Us, PieceType.Pawn) & ctx.not_pinned & ~bb.MASK_RANK[Rank.RANK7.relative_rank(Us).toU3()];
        var b2 = shift(b1, Direction.NORTH_WEST.relative_dir(Us)) & capture_mask;
        var b3 = shift(b1, Direction.NORTH_EAST.relative_dir(Us)) & capture_mask;

        while (b2 != 0) {
            const s1 = bb.pop_lsb(&b2);
            list.append(Move.new(Square.fromU6(@as(u6, @intCast(@as(i8, @intCast(s1)) - Direction.NORTH_WEST.relative_dir(Us).toI8()))), Square.fromU6(s1), MoveFlags.CAPTURE));
        }

        while (b3 != 0) {
            const s1 = bb.pop_lsb(&b3);
            list.append(Move.new(Square.fromU6(@as(u6, @intCast(@as(i8, @intCast(s1)) - Direction.NORTH_EAST.relative_dir(Us).toI8()))), Square.fromU6(s1), MoveFlags.CAPTURE));
        }

        // Non-pinned pawns on the last rank (promotions)
        b1 = self.bitboard_of_pt(Us, PieceType.Pawn) & ctx.not_pinned & bb.MASK_RANK[Rank.RANK7.relative_rank(Us).toU3()];
        if (b1 != 0) {
            // Quiet promotions
            b2 = shift(b1, Direction.NORTH.relative_dir(Us)) & quiet_mask;
            while (b2 != 0) {
                const s1 = bb.pop_lsb(&b2);
                const sq2 = Square.fromU6(@as(u6, @intCast(@as(i8, @intCast(s1)) - Direction.NORTH.relative_dir(Us).toI8())));
                const sq1 = Square.fromU6(s1);

                list.append(Move.new(sq2, sq1, MoveFlags.PR_KNIGHT));
                list.append(Move.new(sq2, sq1, MoveFlags.PR_BISHOP));
                list.append(Move.new(sq2, sq1, MoveFlags.PR_ROOK));
                list.append(Move.new(sq2, sq1, MoveFlags.PR_QUEEN));
            }

            // Promotion captures
            b2 = shift(b1, Direction.NORTH_WEST.relative_dir(Us)) & capture_mask;
            b3 = shift(b1, Direction.NORTH_EAST.relative_dir(Us)) & capture_mask;
            while (b2 != 0) {
                const s1 = bb.pop_lsb(&b2);
                const sq2 = Square.fromU6(@as(u6, @intCast(@as(i8, @intCast(s1)) - Direction.NORTH_WEST.relative_dir(Us).toI8())));
                const sq1 = Square.fromU6(s1);

                list.append(Move.new(sq2, sq1, MoveFlags.PC_KNIGHT));
                list.append(Move.new(sq2, sq1, MoveFlags.PC_BISHOP));
                list.append(Move.new(sq2, sq1, MoveFlags.PC_ROOK));
                list.append(Move.new(sq2, sq1, MoveFlags.PC_QUEEN));
            }

            while (b3 != 0) {
                const s1 = bb.pop_lsb(&b3);
                const sq2 = Square.fromU6(@as(u6, @intCast(@as(i8, @intCast(s1)) - Direction.NORTH_EAST.relative_dir(Us).toI8())));
                const sq1 = Square.fromU6(s1);

                list.append(Move.new(sq2, sq1, MoveFlags.PC_KNIGHT));
                list.append(Move.new(sq2, sq1, MoveFlags.PC_BISHOP));
                list.append(Move.new(sq2, sq1, MoveFlags.PC_ROOK));
                list.append(Move.new(sq2, sq1, MoveFlags.PC_QUEEN));
            }
        }

    }

    fn generate_king_checker_moves(self: *Position, comptime Us: Color, ctx: MoveGenContext, list: *MoveList, checker_square: u6) void { // generates only noisy moves
        var b1 = self.attackers_from(checker_square, ctx.all_bb, Us) & ctx.not_pinned;
        while (b1 != 0) {
            list.append(Move.new(bb.pop_lsb_Sq(&b1), Square.fromU6(checker_square), MoveFlags.CAPTURE));
        }        
    }

    fn generate_pawn_checker_moves(self: *Position, comptime Us: Color, ctx: MoveGenContext, list: *MoveList, checker_square: u6) void { // generates only noisy moves
        const Them = Us.change_side();
        const sq_idx = self.history[self.game_ply].epsq.toU6();
        if (ctx.checkers == shift(SQUARE_BB[sq_idx], Direction.relative_dir(Direction.SOUTH, Us))) {
            var b1 = attacks.pawn_attacks_from_square(sq_idx, Them) & self.bitboard_of_pt(Us, PieceType.Pawn) & ctx.not_pinned;
            while (b1 != 0) {
                list.append(Move.new(bb.pop_lsb_Sq(&b1), self.history[self.game_ply].epsq, MoveFlags.EN_PASSANT));
            }
        }
        var b1 = self.attackers_from(checker_square, ctx.all_bb, Us) & ctx.not_pinned;
        while (b1 != 0) {
            list.append(Move.new(bb.pop_lsb_Sq(&b1), Square.fromU6(checker_square), MoveFlags.CAPTURE));
        }
    }

    fn generate_castling_moves(self: *Position, comptime Us: Color, ctx: MoveGenContext, list: *MoveList) void { // captures are quiet moves
        const ci: usize = Us.toU4();
        const std_ks = if (Us == .White) Square.e1.toU6() else Square.e8.toU6();
        const std_rk = if (Us == .White) Square.h1.toU6() else Square.h8.toU6();
        const std_rq = if (Us == .White) Square.a1.toU6() else Square.a8.toU6();
        // Classical when king/rook are on standard squares (use board presence to be robust)
        const classical_oo = (self.board[std_ks] == Piece.new(Us, PieceType.King)) and (self.board[std_rk] == Piece.new(Us, PieceType.Rook));
        const classical_ooo = (self.board[std_ks] == Piece.new(Us, PieceType.King)) and (self.board[std_rq] == Piece.new(Us, PieceType.Rook));

        // Classical kingside
        if (classical_oo and ((self.history[self.game_ply].castling & (if (Us == .White) Castling.WK.toU4() else Castling.BK.toU4())) != 0)) {
            // Classical: rely on rights + empty/unattacked path; entry gate not needed
            if ((((ctx.all_bb | ctx.danger) & oo_blockers_mask(Us))) == 0) {
                if (Us == Color.White) {
                    list.append(Move.new(Square.e1, Square.g1, MoveFlags.OO));
                } else {
                    list.append(Move.new(Square.e8, Square.g8, MoveFlags.OO));
                }
            }
        }
        // Classical queenside
        if (classical_ooo and ((self.history[self.game_ply].castling & (if (Us == .White) Castling.WQ.toU4() else Castling.BQ.toU4())) != 0)) {
            if ((((ctx.all_bb | (ctx.danger & ~ignore_ooo_danger(Us))) & ooo_blockers_mask(Us))) == 0) {
                if (Us == Color.White) {
                    list.append(Move.new(Square.e1, Square.c1, MoveFlags.OOO));
                } else {
                    list.append(Move.new(Square.e8, Square.c8, MoveFlags.OOO));
                }
            }
        }

        // Chess960 path (for sides not handled by classical above)
        // Helper: compute rank-only between mask (exclusive) for squares on same rank
        const rank_between = struct {
            fn mask(a: u6, b: u6) u64 {
                const ra = rank_of_u6(a);
                const rb = rank_of_u6(b);
                if (ra != rb) return 0;
                var fa: i32 = @intCast(file_of_u6(a));
                var fb: i32 = @intCast(file_of_u6(b));
                if (fa > fb) {
                    const tmp = fa; fa = fb; fb = tmp;
                }
                var m: u64 = 0;
                var f: i32 = fa + 1;
                while (f < fb) : (f += 1) {
                    const sq: u6 = @intCast(@as(i32, @intCast(ra)) * 8 + f);
                    m |= SQUARE_BB[sq];
                }
                return m;
            }
        };
        // Kingside (OO)
        if (@import("build_options").chess960) {
        if (!classical_oo and (self.history[self.game_ply].castling & (if (Us == .White) Castling.WK.toU4() else Castling.BK.toU4())) != 0 and self.castle_rook_k_start[ci] != Square.NO_SQUARE) {
            const ks = ctx.our_king;
            const kd: u6 = if (Us == .White) Square.g1.toU6() else Square.g8.toU6();
            const rs = self.castle_rook_k_start[ci].toU6();
            const rook_present = (self.bitboard_of_pt(Us, PieceType.Rook) & SQUARE_BB[rs]) != 0;
            if (rook_present) {
                const occ_after_k = ctx.all_bb ^ SQUARE_BB[ks];
                const k_path = rank_between.mask(ks, kd);
                const danger_mask = k_path | SQUARE_BB[kd];
                const k_blockers_ok = (occ_after_k & (k_path & ~SQUARE_BB[rs])) == 0;
                const danger_ok = (ctx.danger & danger_mask) == 0;
                // King path (excluding rook square) must be empty and not attacked
                // if (castling_debug) {
                //     std.debug.print("CASTLE DBG 960-OO {s}: ks={s} kd={s} rs={s} k_blockers_ok={} danger_ok={}\n",
                //         .{
                //             if (Us == .White) "W" else "B",
                //             sq_to_coord[ks], sq_to_coord[kd], sq_to_coord[rs], k_blockers_ok, danger_ok,
                //         }
                //     );
                // }
                if (k_blockers_ok and danger_ok) {
                    // Destination square may be occupied by the participating rook in Chess960
                    if (ks != kd) {
                        const kd_occ = (occ_after_k & SQUARE_BB[kd]) != 0;
                        if (kd_occ and kd != rs) {
                            // kd occupied by non-participating piece -> cannot castle
                            // skip
                        } else {
                            const rd: u6 = if (Us == .White) Square.f1.toU6() else Square.f8.toU6();
                            const rook_path = rank_between.mask(rs, rd);
                            const rook_path_clear = (rs == rd) or (((occ_after_k & rook_path) == 0) and ((occ_after_k & SQUARE_BB[rd]) == 0));
                            // if (castling_debug) {
                            //     std.debug.print("CASTLE DBG 960-OO {s}: kd_occ={} rd={s} rook_path_clear={} -> {s}\n",
                            //         .{
                            //             if (Us == .White) "W" else "B",
                            //             kd_occ, sq_to_coord[rd], rook_path_clear,
                            //             if (rook_path_clear) "ADD" else "NOADD",
                            //         }
                            //     );
                            // }
                            if (rook_path_clear) {
                                const to_sq = if (ks == kd) Square.fromU6(rs) else Square.fromU6(kd);
                                list.append(Move.new(Square.fromU6(ks), to_sq, MoveFlags.OO));
                            }
                        }
                    } else {
                        const rd: u6 = if (Us == .White) Square.f1.toU6() else Square.f8.toU6();
                        const rook_path = rank_between.mask(rs, rd);
                        const rook_path_clear = (rs == rd) or (((occ_after_k & rook_path) == 0) and ((occ_after_k & SQUARE_BB[rd]) == 0));
                        // if (castling_debug) {
                        //     std.debug.print("CASTLE DBG 960-OO {s}: ks==kd rd={s} rook_path_clear={} -> {s}\n",
                        //         .{ if (Us == .White) "W" else "B", sq_to_coord[rd], rook_path_clear, if (rook_path_clear) "ADD" else "NOADD" }
                        //     );
                        // }
                        if (rook_path_clear) {
                            const to_sq = if (ks == kd) Square.fromU6(rs) else Square.fromU6(kd);
                            list.append(Move.new(Square.fromU6(ks), to_sq, MoveFlags.OO));
                        }
                    }
                }
            // } else if (castling_debug) {
            //     std.debug.print("CASTLE DBG 960-OO {s}: rs={s} rook_present=false\n",
            //         .{ if (Us == .White) "W" else "B", sq_to_coord[rs] });
            }
        }
        }
        // Queenside (OOO)
        if (@import("build_options").chess960) {
        if (!classical_ooo and (self.history[self.game_ply].castling & (if (Us == .White) Castling.WQ.toU4() else Castling.BQ.toU4())) != 0 and self.castle_rook_q_start[ci] != Square.NO_SQUARE) {
            const ks = ctx.our_king;
            const kd: u6 = if (Us == .White) Square.c1.toU6() else Square.c8.toU6();
            const rs = self.castle_rook_q_start[ci].toU6();
            const rook_present = (self.bitboard_of_pt(Us, PieceType.Rook) & SQUARE_BB[rs]) != 0;
            if (rook_present) {
                const occ_after_k = ctx.all_bb ^ SQUARE_BB[ks];
                const k_path = rank_between.mask(ks, kd);
                const danger_mask = k_path | SQUARE_BB[kd];
                const k_blockers_ok = (occ_after_k & (k_path & ~SQUARE_BB[rs])) == 0;
                const danger_ok = (ctx.danger & danger_mask) == 0;
                // if (castling_debug) {
                //     std.debug.print("CASTLE DBG 960-OOO {s}: ks={s} kd={s} rs={s} k_blockers_ok={} danger_ok={}\n",
                //         .{
                //             if (Us == .White) "W" else "B",
                //             sq_to_coord[ks], sq_to_coord[kd], sq_to_coord[rs], k_blockers_ok, danger_ok,
                //         }
                //     );
                // }
                if (k_blockers_ok and danger_ok) {
                    if (ks != kd) {
                        const kd_occ = (occ_after_k & SQUARE_BB[kd]) != 0;
                        if (kd_occ and kd != rs) {
                            // kd occupied by non-participating piece -> cannot castle
                        } else {
                            const rd: u6 = if (Us == .White) Square.d1.toU6() else Square.d8.toU6();
                            const rook_path = rank_between.mask(rs, rd);
                            const rook_path_clear = (rs == rd) or (((occ_after_k & rook_path) == 0) and ((occ_after_k & SQUARE_BB[rd]) == 0));
                            // if (castling_debug) {
                            //     std.debug.print("CASTLE DBG 960-OOO {s}: kd_occ={} rd={s} rook_path_clear={} -> {s}\n",
                            //         .{
                            //             if (Us == .White) "W" else "B",
                            //             kd_occ, sq_to_coord[rd], rook_path_clear,
                            //             if (rook_path_clear) "ADD" else "NOADD",
                            //         }
                            //     );
                            // }
                            if (rook_path_clear) {
                                const to_sq = if (ks == kd) Square.fromU6(rs) else Square.fromU6(kd);
                                list.append(Move.new(Square.fromU6(ks), to_sq, MoveFlags.OOO));
                            }
                        }
                    } else {
                        const rd: u6 = if (Us == .White) Square.d1.toU6() else Square.d8.toU6();
                        const rook_path = rank_between.mask(rs, rd);
                        const rook_path_clear = (rs == rd) or (((occ_after_k & rook_path) == 0) and ((occ_after_k & SQUARE_BB[rd]) == 0));
                        // if (castling_debug) {
                        //     std.debug.print("CASTLE DBG 960-OOO {s}: ks==kd rd={s} rook_path_clear={} -> {s}\n",
                        //         .{ if (Us == .White) "W" else "B", sq_to_coord[rd], rook_path_clear, if (rook_path_clear) "ADD" else "NOADD" }
                        //     );
                        // }
                        if (rook_path_clear) {
                            const to_sq = if (ks == kd) Square.fromU6(rs) else Square.fromU6(kd);
                            list.append(Move.new(Square.fromU6(ks), to_sq, MoveFlags.OOO));
                        }
                    }
                }
            // } else if (castling_debug) {
            //     std.debug.print("CASTLE DBG 960-OOO {s}: rs={s} rook_present=false\n",
            //         .{ if (Us == .White) "W" else "B", sq_to_coord[rs] });
            }
        }
        }
    }

    // Helper: fill the q-th empty (0-based) with given piece
    fn place_qth_empty(back_rank: *[8]u8, q: u16, ch: u8) void {
        var count: u16 = 0;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            if (back_rank[i] == ' ') {
                if (count == q) {
                    back_rank[i] = ch;
                    return;
                }
                count += 1;
            }
        }
    }

    /// Build a Chess960 back rank (array of 8 chars) for a given index (0..959).
    fn build_chess960_backrank(index: u16) ![8]u8 {
        if (index >= 960) return FenParseError.InvalidPosition;

        var back: [8]u8 = [_]u8{' ', ' ', ' ', ' ', ' ', ' ', ' ', ' '};
        var n: u16 = index;

        // 1) Bishops on opposite colors
        const dark_slot = n % 4; // 0..3 -> files 0,2,4,6
        back[2 * dark_slot] = 'B';
        n /= 4;

        const light_slot = n % 4; // 0..3 -> files 1,3,5,7
        back[2 * light_slot + 1] = 'B';
        n /= 4;

        // 2) Queen in one of the 6 remaining squares
        const q_index = n % 6;
        place_qth_empty(&back, q_index, 'Q');
        n /= 6;

        // 3) Two knights among the 5 remaining squares using combinadic index 0..9
        var k_idx: u16 = n % 10;
        n /= 10;

        // Gather indices of empty squares
        var empty: [5]u8 = undefined;
        var ec: usize = 0;
        for (0..8) |i| {
            if (back[i] == ' ') { empty[ec] = @as(u8, @intCast(i)); ec += 1; }
        }

        // Map k_idx to combination (i<j) over 5 elements in lexicographic order
        var first: usize = 0;
        while (true) {
            const cnt: u16 = @intCast(4 - first); // choices for second
            if (k_idx >= cnt) {
                k_idx -%= cnt;
                first += 1;
            } else break;
        }
        const second: usize = first + 1 + @as(usize, @intCast(k_idx));
        back[empty[first]] = 'N';
        back[empty[second]] = 'N';

        // 4) Remaining 3 squares: R K R with king between rooks
        var rem: [3]u8 = undefined;
        var rc: usize = 0;
        for (0..8) |i| {
            if (back[i] == ' ') { rem[rc] = @as(u8, @intCast(i)); rc += 1; }
        }
        back[rem[0]] = 'R';
        back[rem[1]] = 'K';
        back[rem[2]] = 'R';

        return back;
    }

    /// Set this position to the Chess960 start position corresponding to `index` (0..959).
    /// Places pieces on rank 1 for White and the same files on rank 8 for Black, with pawns on rank 2/7.
    /// Side to move is White and all castling rights are enabled (KQkq).
    pub fn set_chess960_start(self: *Position, index: u16) !void {
        const back = try build_chess960_backrank(index);
        var back_black: [8]u8 = undefined;
        for (0..8) |i| back_black[i] = std.ascii.toLower(back[i]);

        var fen_buf: [80]u8 = undefined;
        const fen = try std.fmt.bufPrint(
            &fen_buf,
            "{s}/pppppppp/8/8/8/8/PPPPPPPP/{s} w KQkq - 0 1",
            .{ back_black[0..], back[0..] },
        );

        try self.set(fen);
        self.is_chess960 = true;
    }

    /// Set this position to a Double Fischer Random (DFRC) start with independent indices.
    /// White uses `white_index` (0..959) for rank 1; Black uses `black_index` (0..959) for rank 8.
    pub fn set_dfrc_start(self: *Position, white_index: u16, black_index: u16) !void {
        const back_w = try build_chess960_backrank(white_index);
        const back_b_upper = try build_chess960_backrank(black_index);

        // Convert black's back rank to lowercase
        var back_b: [8]u8 = undefined;
        for (0..8) |i| back_b[i] = std.ascii.toLower(back_b_upper[i]);

        var fen_buf: [80]u8 = undefined;
        const fen = try std.fmt.bufPrint(
            &fen_buf,
            "{s}/pppppppp/8/8/8/8/PPPPPPPP/{s} w KQkq - 0 1",
            .{ back_b[0..], back_w[0..] },
        );

        try self.set(fen);
        self.is_chess960 = true;
    }

    fn generate_en_passant_moves(self: *Position, comptime Us: Color, ctx: MoveGenContext, list: *MoveList) void { // en passant moves are noisy moves
        const Them = Us.change_side();
        var s: u6 = undefined;
        if (self.history[self.game_ply].epsq != Square.NO_SQUARE) {
            const sq_idx = self.history[self.game_ply].epsq.toU6();
            const b2 = attacks.pawn_attacks_from_square(sq_idx, Them) & self.bitboard_of_pt(Us, PieceType.Pawn);
            var b1 = b2 & ctx.not_pinned;
            while (b1 != 0) {
                s = bb.pop_lsb(&b1);
                const b4 = ctx.all_bb ^ SQUARE_BB[s] ^ shift(SQUARE_BB[sq_idx], Direction.SOUTH.relative_dir(Us));
                const mr = bb.MASK_RANK[rank_of_u6(ctx.our_king)];
                const md = bb.MASK_DIAGONAL[diagonal_of_u6(ctx.our_king)];
                const mad = bb.MASK_ANTI_DIAGONAL[anti_diagonal_of_u6(ctx.our_king)];

                const cond1 = attacks.sliding_attacks(ctx.our_king, b4, mr) & ctx.their_orth_sliders;
                const cond2 = attacks.sliding_attacks(ctx.our_king, b4, md) & ctx.their_diag_sliders;
                const cond3 = attacks.sliding_attacks(ctx.our_king, b4, mad) & ctx.their_diag_sliders;

                if ((cond1 | cond2 | cond3) == 0) {
                    list.append(Move.new(Square.fromU6(s), self.history[self.game_ply].epsq, MoveFlags.EN_PASSANT));
                }
            }

            // Pinned pawns en passant
            b1 = b2 & ctx.pinned & attacks.LINE[sq_idx][ctx.our_king];
            if (b1 != 0) {
                list.append(Move.new(Square.fromU6(bb.get_ls1b_index(b1)), self.history[self.game_ply].epsq, MoveFlags.EN_PASSANT));
            }
        }
    }

    fn generate_pinned_slider_moves(self: *Position, comptime Us: Color, ctx: MoveGenContext, list: *MoveList, quiet_mask: u64, capture_mask: u64, comptime noisy: bool) void {
        var b1 = ~(ctx.not_pinned | self.bitboard_of_pt(Us, PieceType.Knight) | self.bitboard_of_pt(Us, PieceType.Pawn));
        while (b1 != 0) {
            const s1 = bb.pop_lsb(&b1);
            var pc = self.board[s1];
            const b2 = attacks.piece_attacks(s1, ctx.all_bb, pc.type_of()) & attacks.LINE[ctx.our_king][s1];
            if (noisy) {
                make_list(Square.fromU6(s1), b2 & capture_mask, MoveFlags.CAPTURE, list);            
            } else {
                make_list(Square.fromU6(s1), b2 & quiet_mask, MoveFlags.QUIET, list);
            }
        }        
    }

    fn generate_all_pinned_slider_moves(self: *Position, comptime Us: Color, ctx: MoveGenContext, list: *MoveList, quiet_mask: u64, capture_mask: u64) void {
        var b1 = ~(ctx.not_pinned | self.bitboard_of_pt(Us, PieceType.Knight) | self.bitboard_of_pt(Us, PieceType.Pawn));
        while (b1 != 0) {
            const s1 = bb.pop_lsb(&b1);
            var pc = self.board[s1];
            const b2 = attacks.piece_attacks(s1, ctx.all_bb, pc.type_of()) & attacks.LINE[ctx.our_king][s1];
            make_list(Square.fromU6(s1), b2 & capture_mask, MoveFlags.CAPTURE, list);            
            make_list(Square.fromU6(s1), b2 & quiet_mask, MoveFlags.QUIET, list);
        }        
    }    

    fn generate_pinned_pawn_moves(self: *Position, comptime Us: Color, ctx: MoveGenContext, list: *MoveList, capture_mask: u64, comptime only_captures: bool) void {
        var b1 = ~ctx.not_pinned & self.bitboard_of_pt(Us, PieceType.Pawn);
        while (b1 != 0) {
            const s = bb.pop_lsb(&b1);
            if (rank_of_u6(s) == Rank.RANK7.relative_rank(Us).toU6() and !only_captures) {
                var b2 = attacks.pawn_attacks_from_square(s, Us) & capture_mask & attacks.LINE[ctx.our_king][s];
                const sq_from = Square.fromU6(s);
                while (b2 != 0) {
                    const sq_to = Square.fromU6(bb.pop_lsb(&b2));
                    list.append(Move.new(sq_from, sq_to, MoveFlags.PC_KNIGHT));
                    list.append(Move.new(sq_from, sq_to, MoveFlags.PC_BISHOP));
                    list.append(Move.new(sq_from, sq_to, MoveFlags.PC_ROOK));
                    list.append(Move.new(sq_from, sq_to, MoveFlags.PC_QUEEN));
                }
            } else {
                var b2 = attacks.pawn_attacks_from_square(s, Us) & ctx.them_bb & attacks.LINE[s][ctx.our_king];
                make_list(Square.fromU6(s), b2, MoveFlags.CAPTURE, list);
                b2 = shift(SQUARE_BB[s], Direction.NORTH.relative_dir(Us)) & ~ctx.all_bb & attacks.LINE[ctx.our_king][s];
                const b3 = shift(b2 & bb.MASK_RANK[Rank.RANK3.relative_rank(Us).toU3()], Direction.NORTH.relative_dir(Us)) & ~ctx.all_bb & attacks.LINE[ctx.our_king][s];
                if (!only_captures) {
                    make_list(Square.fromU6(s), b2, MoveFlags.QUIET, list);
                    make_list(Square.fromU6(s), b3, MoveFlags.DOUBLE_PUSH, list);
                }
            }
        }
    }

    fn generate_all_pinned_pawn_moves(self: *Position, comptime Us: Color, ctx: MoveGenContext, list: *MoveList, capture_mask: u64) void {
        var b1 = ~ctx.not_pinned & self.bitboard_of_pt(Us, PieceType.Pawn);
        while (b1 != 0) {
            const s = bb.pop_lsb(&b1);
            if (rank_of_u6(s) == Rank.RANK7.relative_rank(Us).toU6()) {
                var b2 = attacks.pawn_attacks_from_square(s, Us) & capture_mask & attacks.LINE[ctx.our_king][s];
                const sq_from = Square.fromU6(s);
                while (b2 != 0) {
                    const sq_to = Square.fromU6(bb.pop_lsb(&b2));
                    list.append(Move.new(sq_from, sq_to, MoveFlags.PC_KNIGHT));
                    list.append(Move.new(sq_from, sq_to, MoveFlags.PC_BISHOP));
                    list.append(Move.new(sq_from, sq_to, MoveFlags.PC_ROOK));
                    list.append(Move.new(sq_from, sq_to, MoveFlags.PC_QUEEN));
                }
            } else {
                var b2 = attacks.pawn_attacks_from_square(s, Us) & ctx.them_bb & attacks.LINE[s][ctx.our_king];
                make_list(Square.fromU6(s), b2, MoveFlags.CAPTURE, list);
                b2 = shift(SQUARE_BB[s], Direction.NORTH.relative_dir(Us)) & ~ctx.all_bb & attacks.LINE[ctx.our_king][s];
                const b3 = shift(b2 & bb.MASK_RANK[Rank.RANK3.relative_rank(Us).toU3()], Direction.NORTH.relative_dir(Us)) & ~ctx.all_bb & attacks.LINE[ctx.our_king][s];
                make_list(Square.fromU6(s), b2, MoveFlags.QUIET, list);
                make_list(Square.fromU6(s), b3, MoveFlags.DOUBLE_PUSH, list);
            }
        }
    }    

    fn generate_noisy_pinned_pawn_moves(self: *Position, comptime Us: Color, ctx: MoveGenContext, list: *MoveList, capture_mask: u64) void {
        var b1 = ~ctx.not_pinned & self.bitboard_of_pt(Us, PieceType.Pawn);
        while (b1 != 0) {
            const s = bb.pop_lsb(&b1);
            if (rank_of_u6(s) == Rank.RANK7.relative_rank(Us).toU6()) {
                var b2 = attacks.pawn_attacks_from_square(s, Us) & capture_mask & attacks.LINE[ctx.our_king][s];
                const sq_from = Square.fromU6(s);
                while (b2 != 0) {
                    const sq_to = Square.fromU6(bb.pop_lsb(&b2));
                    list.append(Move.new(sq_from, sq_to, MoveFlags.PC_KNIGHT));
                    list.append(Move.new(sq_from, sq_to, MoveFlags.PC_BISHOP));
                    list.append(Move.new(sq_from, sq_to, MoveFlags.PC_ROOK));
                    list.append(Move.new(sq_from, sq_to, MoveFlags.PC_QUEEN));
                }
            } else {
                const b2 = attacks.pawn_attacks_from_square(s, Us) & ctx.them_bb & attacks.LINE[s][ctx.our_king];
                make_list(Square.fromU6(s), b2, MoveFlags.CAPTURE, list);
            }
        }
    }    

    fn generate_quiet_pinned_pawn_moves(self: *Position, comptime Us: Color, ctx: MoveGenContext, list: *MoveList) void {
        var b1 = ~ctx.not_pinned & self.bitboard_of_pt(Us, PieceType.Pawn);
        while (b1 != 0) {
            const s = bb.pop_lsb(&b1);
            const b2 = shift(SQUARE_BB[s], Direction.NORTH.relative_dir(Us)) & ~ctx.all_bb & attacks.LINE[ctx.our_king][s];
            const b3 = shift(b2 & bb.MASK_RANK[Rank.RANK3.relative_rank(Us).toU3()], Direction.NORTH.relative_dir(Us)) & ~ctx.all_bb & attacks.LINE[ctx.our_king][s];
            make_list(Square.fromU6(s), b2, MoveFlags.QUIET, list);
            make_list(Square.fromU6(s), b3, MoveFlags.DOUBLE_PUSH, list);
        }
    }    


    pub fn generate_legals(self: *Position, comptime Us: Color, list: *MoveList) void {

        const ctx = self.computeMoveGenContext(Us);

        if (ctx.check_count > 0) {
            self.generate_evasions(Us, ctx, list);
            return;
        }

        //self.generate_all_captures_no_evasion(Us, ctx, list);
        //self.generate_all_quiets_no_evasion(Us, ctx, list);
        self.generate_all_no_evasion(Us, ctx, list);
        return;
    }  

    pub fn generate_noisy_legals(self: *Position, comptime Us: Color, list: *MoveList) void {

        const ctx = self.computeMoveGenContext(Us);

        if (ctx.check_count > 0) {
            self.generate_evasions(Us, ctx, list);
            return;
        }

        self.generate_all_captures_no_evasion(Us, ctx, list);
        return;
    }          

    pub fn generate_legals2(self: *Position, comptime Us: Color, list: *MoveList) void {

        generate_captures_list(self, Us, list);
        generate_quiets_list(self, Us, list);

        return;
    }

    pub fn generate_quiets_list(self: *Position, comptime Us: Color, list: *MoveList) void {
        const ctx = self.computeMoveGenContext(Us);

        generate_king_moves(ctx, list, false);

        var quiet_mask: u64 = undefined;
        const Them = Us.change_side();

        switch (bb.pop_count(ctx.checkers)) {
            2 => return,
            1 => {
                const checker_square = bb.get_ls1b_index(ctx.checkers);
                const checker_piece = self.board[checker_square];
                if (checker_piece == Piece.new(Them, PieceType.Pawn) or checker_piece == Piece.new(Them, PieceType.King)) {
                    return;
                }
                quiet_mask = attacks.SQUARES_BETWEEN_BB[ctx.our_king][checker_square];
                // Add pinned quiet generations here to fix potential issues
            },
            else => {
                quiet_mask = ~ctx.all_bb;
                generate_castling_moves(self, Us, ctx, list);
                generate_quiet_pinned_pawn_moves(self, Us, ctx, list);
                generate_pinned_slider_moves(self, Us, ctx, list, quiet_mask, 0, false);                
            },
        }

        generate_quiet_moves(self, Us, ctx, list, quiet_mask);
        return;
    }

    pub fn generate_captures_list(self: *Position, comptime Us: Color, list: *MoveList) void {
        const ctx = self.computeMoveGenContext(Us);

        const Them = Us.change_side();

        var capture_mask: u64 = undefined;
        var quiet_mask: u64 = undefined;

        // King captures
        generate_king_moves(ctx, list, true);

        switch (bb.pop_count(ctx.checkers)) {
            // Double check: only king moves are legal
            2 => return,
            1 => {
                // Single check
                const checker_square = bb.get_ls1b_index(ctx.checkers);
                switch (self.board[checker_square]) {
                    Piece.new(Them, PieceType.Pawn) => {
                        // En passant capture for pawn checker
                        generate_pawn_checker_moves(self, Us, ctx, list, checker_square);
                        return;
                    },
                    Piece.new(Them, PieceType.King) => {
                        generate_king_checker_moves(self, Us, ctx, list, checker_square);
                        return;
                    },
                    else => {
                        // Capture the checking piece (slider)
                        capture_mask = ctx.checkers;
                        quiet_mask = attacks.SQUARES_BETWEEN_BB[ctx.our_king][checker_square];
                    },
                }
            },
            else => {
                // No checks: capture any enemy piece
                capture_mask = ctx.them_bb;
                quiet_mask = ~ctx.all_bb;

                // En passant captures
                generate_en_passant_moves(self, Us, ctx, list);

                // Pinned rooks, bishops, or queens
                generate_pinned_slider_moves(self, Us, ctx, list, quiet_mask, capture_mask, true);

                // Pinned pawns
                //generate_pinned_pawn_moves(self, Us, ctx, list, capture_mask, true);
                generate_noisy_pinned_pawn_moves(self, Us, ctx, list, capture_mask);


            },
        }

        generate_noisy_moves(self, Us, ctx, list, capture_mask, quiet_mask);

        return;
    }

};

test "three-fold repetition: multiple positions" {
    attacks.initialise_all_databases();
    zobrist.initialise_zobrist_keys();

    const fens = [_][]const u8{
        "r5k1/pbN2rp1/4Q1Np/2pn1pB1/8/P7/1PP2PPP/6K1 b - - 0 25", // Original: knight and king
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", // Knight shuffle in opening
        "r1bqkb1r/pppp1ppp/5n2/4p3/4P3/5N2/PPPP1PPP/R1BQKB1R w KQkq - 0 1", // Queen and bishop in middlegame
        "8/5k2/5p2/5P2/5K2/8/8/8 w - - 0 50", // King shuffle in endgame
    };

    const moves_strs = [_][]const u8{
        "d5c7 g6e7 g8f8 e7g6 f8g8 g6e7 g8f8 e7g6 f8g8", // Original
        "g1f3 g8f6 f3g1 f6g8 g1f3 g8f6 f3g1 f6g8", // Knight shuffle
        "f3h4 d7d6 d1f3 c8e6 f3d1 e6c8 d1f3 c8e6 f3d1 e6c8", // Queen and bishop
        "f4e4 f7e7 e4f4 e7f7 f4e4 f7e7 e4f4 e7f7", // King shuffle
    };

    const test_names = [_][]const u8{
        "knight and king",
        "knight shuffle in opening",
        "queen and bishop in middlegame",
        "king shuffle in endgame",
    };

    // Iterate over each test case
    for (fens, moves_strs, test_names) |fen, moves_str, test_name| {
        std.debug.print("\nTesting: {s}\n", .{test_name});
        var pos = Position.new();

        // Set position from FEN
        try pos.set(fen);
        pos.print_unicode();

        var moves = std.mem.splitScalar(u8, std.mem.trim(u8, moves_str, " "), ' ');

        // Apply moves
        while (moves.next()) |move_str| {
            std.debug.print("|{s}|", .{move_str});
            const move = try Move.parse_move(move_str, &pos);
            if (pos.side_to_play == Color.White) {
                pos.play(move, Color.White);
            } else {
                pos.play(move, Color.Black);
            }
        }
        std.debug.print("\n", .{});

        // Verify three-fold repetition
        if (!pos.is_repetition()) {
            std.debug.print("Repetition test failed for {s}\n", .{test_name});
            try std.testing.expect(false);
        }
    }
}

test "Algebraic to UCI conversion Nxe5" {
    attacks.initialise_all_databases();
    zobrist.initialise_zobrist_keys();

    var curr_pos = Position.new();
    try curr_pos.set("rnbqkbnr/pppp1ppp/5n2/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 0 1");
    const uci = try Move.algebraic_to_uci("Nxe5", &curr_pos);
    defer std.testing.allocator.free(uci);
    try std.testing.expectEqualStrings("f3e5", uci);
}

test "Algebraic to UCI conversion f8=Q" {
    attacks.initialise_all_databases();
    zobrist.initialise_zobrist_keys();

    var curr_pos = Position.new();
    try curr_pos.set("6RR/4bP2/8/8/5r2/3K4/5p2/4k3 w - - 0 1");
    const uci = try Move.algebraic_to_uci("f8=Q", &curr_pos);
    //std.debug.print("\nuci move: {s}", .{uci});
    defer std.testing.allocator.free(uci);
    try std.testing.expectEqualStrings("f7f8q", uci);
}

test "Algebraic to UCI conversion O-O" {
    attacks.initialise_all_databases();
    zobrist.initialise_zobrist_keys();

    var curr_pos = Position.new();
    try curr_pos.set("r1bqk1nr/pppp1ppp/2n5/1B2p3/1b2P3/5N2/PPPP1PPP/RNBQK2R w KQkq -");
    const uci = try Move.algebraic_to_uci("O-O", &curr_pos);
    //std.debug.print("\nuci move: {s}", .{uci});
    defer std.testing.allocator.free(uci);
    try std.testing.expectEqualStrings("e1g1", uci);
}

test "Test in_check function for white" {

    attacks.initialise_all_databases();
    zobrist.initialise_zobrist_keys();

    const test_cases = [_]struct { fen: []const u8, in_check: bool}{
        .{ .fen = "8/3k4/8/3q4/8/5K2/8/8 w - - 1 1", .in_check = true},
        .{ .fen = "8/3k4/8/2q5/8/1Q3K2/8/8 w - - 1 1", .in_check = false},
        .{ .fen = "8/1b1k4/8/2q5/8/1Q3K2/8/8 w - - 1 1", .in_check = true},
        .{ .fen = "8/1b1k4/8/2q5/4B3/1Q3K2/8/8 w - - 1 1", .in_check = false},
        .{ .fen = "8/1b1k4/8/2q3n1/4B3/1Q3K2/8/8 w - - 1 1", .in_check = true},
        .{ .fen = "8/1b1k4/5n2/2q5/4B3/1Q3K2/8/8 w - - 1 1", .in_check = false},
        .{ .fen = "8/1b1k4/5n2/2q5/4B1p1/1Q3K2/8/8 w - - 1 1", .in_check = true},
        .{ .fen = "8/1b1k4/5n2/2q3p1/4B3/1Q3K2/8/5r2 w - - 1 1", .in_check = true},
        .{ .fen = "8/1b1k4/5n2/2q3p1/4B3/1Q3K2/5P2/5r2 w - - 1 1", .in_check = false},
    };

    const me = Color.White;

    std.debug.print("\n", .{});
    
    for (test_cases) |test_case| {
        // Set up position
        var curr_pos = Position.new();
        try curr_pos.set(test_case.fen);
        const in_check = curr_pos.in_check(me);

        // Compare with expected
        if (in_check != test_case.in_check) {
            std.debug.print(
                "in_check failed for FEN: {s}, expected: {}, got: {}\n",
                .{ test_case.fen, test_case.in_check, in_check },
            );
            try std.testing.expectEqual(test_case.in_check, in_check);
        }        

    }
}

test "Test in_check function for black" {

    attacks.initialise_all_databases();
    zobrist.initialise_zobrist_keys();

    const test_cases = [_]struct { fen: []const u8, in_check: bool}{
        .{ .fen = "8/1b1k4/5n2/2q3p1/Q3B3/5K2/5P2/5r2 b - - 1 1", .in_check = true},
        .{ .fen = "8/1b1k4/2p2n2/2q3p1/Q3B3/5K2/5P2/5r2 b - - 1 1", .in_check = false},
        .{ .fen = "8/1b1k3R/2p2n2/2q3p1/Q3B3/5K2/5P2/5r2 b - - 1 1", .in_check = true},
        .{ .fen = "8/1b1k1b1R/2p2n2/2q3p1/Q3B3/5K2/5P2/5r2 b - - 1 1", .in_check = false},
        .{ .fen = "8/1b1k1b1R/2p1Pn2/2q3p1/Q3B3/5K2/5P2/5r2 b - - 1 1", .in_check = true},
        .{ .fen = "8/1b1k1b1R/2p2n2/2q1P1p1/Q3B3/5K2/5P2/5r2 b - - 1 1", .in_check = false},
        .{ .fen = "8/1b1k1b1R/1Np2n2/2q1P1p1/Q3B3/5K2/5P2/5r2 b - - 1 1", .in_check = true},
        .{ .fen = "8/1b1k1b1R/2p2n2/2q1P1p1/Q3B1B1/N4K2/5P2/5r2 b - - 1 1", .in_check = true},
        .{ .fen = "4k3/1b3b1R/2p2n2/2q1P1p1/Q3B1B1/N4K2/5P2/5r2 b - - 1 1", .in_check = false},
        .{ .fen = "3q4/1b2kb1R/2p2n2/4P1p1/Q2B2B1/N4K2/5P2/5r2 b - - 1 1", .in_check = false},
    };

    const me = Color.Black;

    std.debug.print("\n", .{});
    
    for (test_cases) |test_case| {
        // Set up position
        var curr_pos = Position.new();
        try curr_pos.set(test_case.fen);
        const in_check = curr_pos.in_check(me);

        // Compare with expected
        if (in_check != test_case.in_check) {
            std.debug.print(
                "in_check failed for FEN: {s}, expected: {}, got: {}\n",
                .{ test_case.fen, test_case.in_check, in_check },
            );
            try std.testing.expectEqual(test_case.in_check, in_check);
        }        

    }

}

// run with: zig test --test-filter "Test get_fen" -lc .\src\position.zig
test "Test get_fen" {

    attacks.initialise_all_databases();
    zobrist.initialise_zobrist_keys();

    const test_cases = [_][]const u8{
        "r3qb1k/1b4p1/p2pr2p/3n4/Pnp1N1N1/6RP/1B3PP1/1B1QR1K1 w - - 0 1",
        "r4rk1/pp1n1p1p/1nqP2p1/2b1P1B1/4NQ2/1B3P2/PP2K2P/2R5 w - - 0 1",
        "r2qk2r/ppp1b1pp/2n1p3/3pP1n1/3P2b1/2PB1NN1/PP4PP/R1BQK2R w KQkq - 0 1",
        "r1b1kb1r/1p1n1ppp/p2ppn2/6BB/2qNP3/2N5/PPP2PPP/R2Q1RK1 w kq - 0 1",
        "r2qrb1k/1p1b2p1/p2ppn1p/8/3NP3/1BN5/PPP3QP/1K3RR1 w - - 0 1",
        "rnbqk2r/1p3ppp/p7/1NpPp3/QPP1P1n1/P4N2/4KbPP/R1B2B1R b kq - 0 1", // Removed trailing Ă”Ă‰Ă˘
        "1r1bk2r/2R2ppp/p3p3/1b2P2q/4QP2/4N3/1B4PP/3R2K1 w k - 0 1",
        "r3rbk1/ppq2ppp/2b1pB2/8/6Q1/1P1B3P/P1P2PP1/R2R2K1 w - - 0 1",
        "r4r1k/4bppb/2n1p2p/p1n1P3/1p1p1BNP/3P1NP1/qP2QPB1/2RR2K1 w - - 0 1",
        "r1b2rk1/1p1nbppp/pq1p4/3B4/P2NP3/2N1p3/1PP3PP/R2Q1R1K w - - 0 1",
        "r1b3k1/p2p1nP1/2pqr1Rp/1p2p2P/2B1PnQ1/1P6/P1PP4/1K4R1 w - - 0 1",
        "1k1r4/pp1b1R2/3q2pp/4p3/2B5/4Q3/PPP2B2/2K5 b - - 0 1",
        "3r1k2/4npp1/1ppr3p/p6P/P2PPPP1/1NR5/5K2/2R5 w - - 0 1",
        "2q1rr1k/3bbnnp/p2p1pp1/2pPp3/PpP1P1P1/1P2BNNP/2BQ1PRK/7R b - - 0 1",
        "rnbqkb1r/p3pppp/1p6/2ppP3/3N4/2P5/PPP1QPPP/R1B1KB1R w KQkq - 0 1",
        "r1b2rk1/2q1b1pp/p2ppn2/1p6/3QP3/1BN1B3/PPP3PP/R4RK1 w - - 0 1",
        "2r3k1/pppR1pp1/4p3/4P1P1/5P2/1P4K1/P1P5/8 w - - 0 1",
        "1nk1r1r1/pp2n1pp/4p3/q2pPp1N/b1pP1P2/B1P2R2/2P1B1PP/R2Q2K1 w - - 0 1",
        "4b3/p3kp2/6p1/3pP2p/2pP1P2/4K1P1/P3N2P/8 w - - 0 1",
        "2kr1bnr/pbpq4/2n1pp2/3p3p/3P1P1B/2N2N1Q/PPP3PP/2KR1B1R w - - 0 1",
        "3rr1k1/pp3pp1/1qn2np1/8/3p4/PP1R1P2/2P1NQPP/R1B3K1 b - - 0 1",
        "8/5Bp1/4P3/6pP/1b1k1P2/5K2/8/8 w - - 0 1",
        "1qnrkbbr/1pppppp1/p1n4p/8/P7/1P1N1P2/2PPP1PP/QN1RKBBR w HDhd - 0 9",
        "qn1rkrbb/pp1p1ppp/2p1p3/3n4/4P2P/2NP4/PPP2PP1/Q1NRKRBB w FDfd - 1 9",
        "bb1qnrkr/pp1p1pp1/1np1p3/4N2p/8/1P4P1/P1PPPP1P/BBNQ1RKR w HFhf - 0 9",
        "bnqbnr1r/p1p1ppkp/3p4/1p4p1/P7/3NP2P/1PPP1PP1/BNQB1RKR w HF - 0 9",
        "bnqnrbkr/1pp2pp1/p7/3pP2p/4P1P1/8/PPPP3P/BNQNRBKR w HEhe d6 0 9",
        "b1qnrrkb/ppp1pp1p/n2p1Pp1/8/8/P7/1PPPP1PP/BNQNRKRB w GE - 0 9",
        "n1bqnrkr/pp1ppp1p/2p5/6p1/2P2b2/PN6/1PNPPPPP/1BBQ1RKR w HFhf - 2 9",
        "n1bb1rkr/qpnppppp/2p5/p7/P1P5/5P2/1P1PPRPP/NQBBN1KR w Hhf - 1 9",
        "nqb1rbkr/pppppp1p/4n3/6p1/4P3/1NP4P/PP1P1PP1/1QBNRBKR w HEhe - 1 9",
        "n1bnrrkb/pp1pp2p/2p2p2/6p1/5B2/3P4/PPP1PPPP/NQ1NRKRB w GE - 2 9",
        "nbqnbrkr/2ppp1p1/pp3p1p/8/4N2P/1N6/PPPPPPP1/1BQ1BRKR w HFhf - 0 9",
        "nq1bbrkr/pp2nppp/2pp4/4p3/1PP1P3/1B6/P2P1PPP/NQN1BRKR w HFhf - 2 9",
        "nqnrb1kr/2pp1ppp/1p1bp3/p1B5/5P2/3N4/PPPPP1PP/NQ1R1BKR w HDhd - 0 9",
        "nqn2krb/p1prpppp/1pbp4/7P/5P2/8/PPPPPKP1/NQNRB1RB w g - 3 9",
        "nb1n1kbr/ppp1rppp/3pq3/P3p3/8/4P3/1PPPRPPP/NBQN1KBR w Hh - 1 9",
        "nqnbrkbr/1ppppp1p/p7/6p1/6P1/P6P/1PPPPP2/NQNBRKBR w HEhe - 1 9",
        "nq1rkb1r/pp1pp1pp/1n2bp1B/2p5/8/5P1P/PPPPP1P1/NQNRKB1R w HDhd - 2 9",
        "nqnrkrb1/pppppp2/7p/4b1p1/8/PN1NP3/1PPP1PPP/1Q1RKRBB w FDfd - 1 9",
        "bb1nqrkr/1pp1ppp1/pn5p/3p4/8/P2NNP2/1PPPP1PP/BB2QRKR w HFhf - 0 9",
        "bnn1qrkr/pp1ppp1p/2p5/b3Q1p1/8/5P1P/PPPPP1P1/BNNB1RKR w HFhf - 2 9",
        "b1nqrkrb/2pppppp/p7/1P6/1n6/P4P2/1P1PP1PP/BNNQRKRB w GEge - 0 9",
        "n1bnqrkr/3ppppp/1p6/pNp1b3/2P3P1/8/PP1PPP1P/NBB1QRKR w HFhf - 1 9",
        "n2bqrkr/p1p1pppp/1pn5/3p1b2/P6P/1NP5/1P1PPPP1/1NBBQRKR w HFhf - 3 9",
        "nnbqrbkr/1pp1p1p1/p2p4/5p1p/2P1P3/N7/PPQP1PPP/N1B1RBKR w HEhe - 0 9",
        "nnbqrkr1/pp1pp2p/2p2b2/5pp1/1P5P/4P1P1/P1PP1P2/NNBQRKRB w GEge - 1 9",
        "nb1qbrkr/p1pppp2/1p1n2pp/8/1P6/2PN3P/P2PPPP1/NB1QBRKR w HFhf - 0 9",
        "nnq1brkr/pp1pppp1/8/2p4P/8/5K2/PPPbPP1P/NNQBBR1R w hf - 0 9",
        "nnqrbb1r/pppppk2/5pp1/7p/1P6/3P2PP/P1P1PP2/NNQRBBKR w HD - 0 9",
        "nnqr1krb/p1p1pppp/2bp4/8/1p1P4/4P3/PPP2PPP/NNQRBKRB w GDgd - 0 9",
        "nbnqrkbr/p2ppp2/1p4p1/2p4p/3P3P/3N4/PPP1PPPR/NB1QRKB1 w Ehe - 0 9",
        "n1qbrkbr/p1ppp2p/2n2pp1/1p6/1P6/2P3P1/P2PPP1P/NNQBRKBR w HEhe - 0 9",      
        "rnbqkbnr/1ppppppp/8/p7/2P5/P7/1P1PPPPP/RNBQKBNR b KQkq - 0 1",
        "2bqkbnr/rppppppp/n7/p7/2P5/PP6/3PPPPP/RNBQKBNR w KQk - 0 1",
        "2bqkbnr/rpp1pppp/n2p4/p7/2P3P1/PP5P/3PPP2/RNBQKBNR b KQk - 0 1",
        "r3k2r/1b4bq/8/8/8/8/7B/R3K2R w KQkq - 0 1",
        "r3k2r/7b/8/8/8/8/1B4BQ/R3K2R b KQkq - 0 1",
        "r3k2r/8/3Q4/8/8/5q2/8/R3K2R b KQkq - 0 1",
        "r3k2r/8/5Q2/8/8/3q4/8/R3K2R w KQkq - 0 1",   
        "rnbqkb1r/p3pppp/1p6/2ppP3/3N4/2P5/PPP1QPPP/R1B1KB1R w KQkq - 0 1",
        "r1bqkb1r/4npp1/p1p4p/1p1pP1B1/8/1B6/PPPN1PPP/R2Q1RK1 w kq - 0 1",
        "r1bqk2r/pp2bppp/2p5/3pP3/P2Q1P2/2N1B3/1PP3PP/R4RK1 b kq - 0 1",   
        "rn1qkb1r/pp2pppp/5n2/3p1b2/3P4/2N1P3/PP3PPP/R1BQKBNR w KQkq - 0 1",
        "rn1qkb1r/pp2pppp/5n2/3p1b2/3P4/1QN1P3/PP3PPP/R1B1KBNR b KQkq - 1 1",
        "r1bqk2r/ppp2ppp/2n5/4P3/2Bp2n1/5N1P/PP1N1PP1/R2Q1RK1 b kq - 1 10",
        "rnbqkb1r/ppp1pppp/5n2/8/3PP3/2N5/PP3PPP/R1BQKBNR b KQkq - 3 5",
        "rnbq1rk1/pppp1ppp/4pn2/8/1bPP4/P1N5/1PQ1PPPP/R1B1KBNR b KQ - 1 5",
        "rn1qkb1r/pb1p1ppp/1p2pn2/2p5/2PP4/5NP1/PP2PPBP/RNBQK2R w KQkq c6 1 6",
        "r1bq1rk1/1pp2pbp/p1np1np1/3Pp3/2P1P3/2N1BP2/PP4PP/R1NQKB1R b KQ - 1 9",
        "rnbqkb1r/pppp1ppp/5n2/4p3/4PP2/2N5/PPPP2PP/R1BQKBNR b KQkq f3 1 3",
        "r1bqk1nr/pppnbppp/3p4/8/2BNP3/8/PPP2PPP/RNBQK2R w KQkq - 2 6",
        "rnbq1b1r/ppp2kpp/3p1n2/8/3PP3/8/PPP2PPP/RNBQKB1R b KQ d3 1 5",
        "rnbqkb1r/pppp1ppp/3n4/8/2BQ4/5N2/PPP2PPP/RNB2RK1 b kq - 1 6",
        "r1bqkb1r/2pp1ppp/p1n5/1p2p3/3Pn3/1B3N2/PPP2PPP/RNBQ1RK1 b kq - 2 7",
        "r2qkbnr/2p2pp1/p1pp4/4p2p/4P1b1/5N1P/PPPP1PP1/RNBQ1RK1 w kq - 1 8",
        "r1bqkb1r/pp3ppp/2np1n2/4p1B1/3NP3/2N5/PPP2PPP/R2QKB1R w KQkq e6 1 7",
        "rn1qk2r/1b2bppp/p2ppn2/1p6/3NP3/1BN5/PPP2PPP/R1BQR1K1 w kq - 5 10",
        "r1b1kb1r/1pqpnppp/p1n1p3/8/3NP3/2N1B3/PPP1BPPP/R2QK2R w KQkq - 3 8",
        "r1bqnr2/pp1ppkbp/4N1p1/n3P3/8/2N1B3/PPP2PPP/R2QK2R b KQ - 2 11",
        "r3kb1r/pp1n1ppp/1q2p3/n2p4/3P1Bb1/2PB1N2/PPQ2PPP/RN2K2R w KQkq - 3 11",
        "r1bq1rk1/pppnnppp/4p3/3pP3/1b1P4/2NB3N/PPP2PPP/R1BQK2R w KQ - 3 7",
        "r2qkbnr/ppp1pp1p/3p2p1/3Pn3/4P1b1/2N2N2/PPP2PPP/R1BQKB1R w KQkq - 2 6",
        "rn2kb1r/pp2pppp/1qP2n2/8/6b1/1Q6/PP1PPPBP/RNB1K1NR b KQkq - 1 6", 
        "r3kb1r/3n1pp1/p6p/2pPp2q/Pp2N3/3B2PP/1PQ2P2/R3K2R w KQkq - 0 1",
        "1k1r3r/pp2qpp1/3b1n1p/3pNQ2/2pP1P2/2N1P3/PP4PP/1K1RR3 b - - 0 1",
        "r6k/pp4p1/2p1b3/3pP3/7q/P2B3r/1PP2Q1P/2K1R1R1 w - - 0 1",
        "1nr5/2rbkppp/p3p3/Np6/2PRPP2/8/PKP1B1PP/3R4 b - - 0 1",
        "2r2rk1/1p1bq3/p3p2p/3pPpp1/1P1Q4/P7/2P2PPP/2R1RBK1 b - - 0 1",
        "3r1bk1/p4ppp/Qp2p3/8/1P1B4/Pq2P1P1/2r2P1P/R3R1K1 b - - 0 1",
        "r1b2r1k/pp2q1pp/2p2p2/2p1n2N/4P3/1PNP2QP/1PP2RP1/5RK1 w - - 0 1",
        "r2qrnk1/pp3ppb/3b1n1p/1Pp1p3/2P1P2N/P5P1/1B1NQPBP/R4RK1 w - - 0 1",
        "5nk1/Q4bpp/5p2/8/P1n1PN2/q4P2/6PP/1R4K1 w - - 0 1",
        "r3k2r/3bbp1p/p1nppp2/5P2/1p1NP3/5NP1/PPPK3P/3R1B1R b kq - 0 1",
        "bn6/1q4n1/1p1p1kp1/2pPp1pp/1PP1P1P1/3N1P1P/4B1K1/2Q2N2 w - - 0 1",
        "3r2k1/pp2npp1/2rqp2p/8/3PQ3/1BR3P1/PP3P1P/3R2K1 b - - 0 1",
        "1r2r1k1/4ppbp/B5p1/3P4/pp1qPB2/2n2Q1P/P4PP1/4RRK1 b - - 0 1",
        "r2qkb1r/1b3ppp/p3pn2/1p6/1n1P4/1BN2N2/PP2QPPP/R1BR2K1 w kq - 0 1",
        "1r4k1/1q2bp2/3p2p1/2pP4/p1N4R/2P2QP1/1P3PK1/8 w - - 0 1",
        "rn3rk1/pbppq1pp/1p2pb2/4N2Q/3PN3/3B4/PPP2PPP/R3K2R w KQ - 0 1",
        "4r1k1/3b1p2/5qp1/1BPpn2p/7n/r3P1N1/2Q1RPPP/1R3NK1 b - - 0 1",
        "2k2b1r/1pq3p1/2p1pp2/p1n1PnNp/2P2B2/2N4P/PP2QPP1/3R2K1 w - - 0 1",
        "2r2r2/3qbpkp/p3n1p1/2ppP3/6Q1/1P1B3R/PBP3PP/5R1K w - - 0 1",
        "2rr2k1/1b3ppp/pb2p3/1p2P3/1P2BPnq/P1N3P1/1B2Q2P/R4R1K b - - 0 1",
        "2b1r1k1/r4ppp/p7/2pNP3/4Q3/q6P/2P2PP1/3RR1K1 w - - 0 1",
        "6k1/5p2/3P2p1/7n/3QPP2/7q/r2N3P/6RK b - - 0 1",
        "rq2rbk1/6p1/p2p2Pp/1p1Rn3/4PB2/6Q1/PPP1B3/2K3R1 w - - 0 1",
        "rnbq2k1/p1r2p1p/1p1p1Pp1/1BpPn1N1/P7/2P5/6PP/R1B1QRK1 w - - 0 1",
        "r2qrb1k/1p1b2p1/p2ppn1p/8/3NP3/1BN5/PPP3QP/1K3RR1 w - - 0 1",
        "8/1p3pp1/7p/5P1P/2k3P1/8/2K2P2/8 w - - 0 1",
        "8/pp2r1k1/2p1p3/3pP2p/1P1P1P1P/P5KR/8/8 w - - 0 1",
        "8/3p4/p1bk3p/Pp6/1Kp1PpPp/2P2P1P/2P5/5B2 b - - 0 1",
        "5k2/7R/4P2p/5K2/p1r2P1p/8/8/8 b - - 0 1",
        "6k1/6p1/7p/P1N5/1r3p2/7P/1b3PP1/3bR1K1 w - - 0 1",
        "8/3b4/5k2/2pPnp2/1pP4N/pP1B2P1/P3K3/8 b - - 0 1",
        "6k1/4pp1p/3p2p1/P1pPb3/R7/1r2P1PP/3B1P2/6K1 w - - 0 1",
        "2k5/p7/Pp1p1b2/1P1P1p2/2P2P1p/3K3P/5B2/8 w - - 0 1",
        "8/5Bp1/4P3/6pP/1b1k1P2/5K2/8/8 w - - 0 1", 
        "r3qb1k/1b4p1/p2pr2p/3n4/Pnp1N1N1/6RP/1B3PP1/1B1QR1K1 w - - 0 1",
        "r4rk1/pp1n1p1p/1nqP2p1/2b1P1B1/4NQ2/1B3P2/PP2K2P/2R5 w - - 0 1",
        "r2qk2r/ppp1b1pp/2n1p3/3pP1n1/3P2b1/2PB1NN1/PP4PP/R1BQK2R w KQkq - 0 1",
        "r1b1kb1r/1p1n1ppp/p2ppn2/6BB/2qNP3/2N5/PPP2PPP/R2Q1RK1 w kq - 0 1",
        "r2qrb1k/1p1b2p1/p2ppn1p/8/3NP3/1BN5/PPP3QP/1K3RR1 w - - 0 1",
        "rnbqk2r/1p3ppp/p7/1NpPp3/QPP1P1n1/P4N2/4KbPP/R1B2B1R b kq - 0 1",
        "1r1bk2r/2R2ppp/p3p3/1b2P2q/4QP2/4N3/1B4PP/3R2K1 w k - 0 1",
        "r3rbk1/ppq2ppp/2b1pB2/8/6Q1/1P1B3P/P1P2PP1/R2R2K1 w - - 0 1",
        "r4r1k/4bppb/2n1p2p/p1n1P3/1p1p1BNP/3P1NP1/qP2QPB1/2RR2K1 w - - 0 1",
        "r1b2rk1/1p1nbppp/pq1p4/3B4/P2NP3/2N1p3/1PP3PP/R2Q1R1K w - - 0 1",
        "r1b3k1/p2p1nP1/2pqr1Rp/1p2p2P/2B1PnQ1/1P6/P1PP4/1K4R1 w - - 0 1",  
        "8/8/p1p5/1p5p/1P5p/8/PPP2K1p/4R1rk w - - 0 1",
        "1q1k4/2Rr4/8/2Q3K1/8/8/8/8 w - - 0 1",
        "7k/5K2/5P1p/3p4/6P1/3p4/8/8 w - - 0 1",
        "8/6B1/p5p1/Pp4kp/1P5r/5P1Q/4q1PK/8 w - - 0 32",
        "8/8/1p1r1k2/p1pPN1p1/P3KnP1/1P6/8/3R4 b - - 0 1",     
        "1kr5/3n4/q3p2p/p2n2p1/PppB1P2/5BP1/1P2Q2P/3R2K1 w - - 0 1",
        "1n5k/3q3p/pp1p2pB/5r2/1PP1Qp2/P6P/6P1/2R3K1 w - - 0 1",
        "1n6/4bk1r/1p2rp2/pP2pN1p/K1P1N2P/8/P5R1/3R4 w - - 0 1",
        "1nr5/1k5r/p3pqp1/3p4/1P1P1PP1/R4N2/3Q1PK1/R7 w - - 0 1",
        "1q2r1k1/1b2bpp1/p2ppn1p/2p5/P3PP1B/2PB1RP1/2P1Q2P/2KR4 b - - 0 1",
        "1q4k1/5p1p/p1rprnp1/3R4/N1P1P3/1P6/P5PP/3Q1R1K w - - 0 1",
        "1qr1k2r/1p2bp2/pBn1p3/P2pPbpp/5P2/2P1QBPP/1P1N3R/R4K2 b k - 0 1",
        "1r1b2k1/2r2ppp/p1qp4/3R1NPP/1pn1PQB1/8/PPP3R1/1K6 w - - 0 1",
        "1r1qk1nr/p3ppbp/3p2p1/1pp5/2bPP3/4B1P1/2PQNPBP/R2R2K1 w k - 0 1",
        "1r1r2k1/p3n2p/b1nqpbp1/2pp4/1p3PP1/2PP1N2/PPN3BP/R1BRQ2K w - - 0 1",
        "1r2n1rk/pP2q2p/P2p4/4pQ2/2P2p2/5B1P/3R1P1K/3R4 w - - 0 1",
        "1r3bk1/7p/pp1q2p1/P1pPp3/2P3b1/4B3/1P1Q2BP/R6K w - - 0 1",
        "1r3rk1/3n1pbp/1q1pp1p1/p1p5/2PnPP2/PPB1N1PP/6B1/1R1Q1RK1 b - - 0 1",
        "1r3rk1/p5bp/6p1/q1pPppn1/7P/1B1PQ1P1/PB3P2/R4RK1 b - - 0 1",
        "1r4k1/1rq2pp1/3b1nn1/pBpPp3/P1N4p/2PP1Q1P/6PB/2R2RK1 w - - 0 1",
        "1r4k1/p1rqbp1p/b1p1p1p1/NpP1P3/3PB3/3Q2P1/P4P1P/3RR1K1 w - - 0 1",
        "2r3k1/p2q1pp1/Pbrp3p/6n1/1BP1PpP1/R4P2/2QN2KP/1R6 b - - 0 1",
        "1r6/2q2pk1/2n1p1pp/p1Pr4/P1RP4/1p1RQ2P/1N3PP1/7K b - - 0 1",
        "1r6/R1nk1p2/1p4pp/pP1p1P2/P2P3P/5PN1/5K2/8 w - - 0 1",
        "1rb3k1/2pn2pp/p2p4/4p3/1pP4q/1P1PBP1P/1PQ2P2/R3R1K1 w - - 0 1",
        "1rbqnrk1/6bp/pp3np1/2pPp3/P1P1N3/2N1B3/1P2Q1BP/R4R1K w - - 0 1",
        "1rr3k1/1q3pp1/pnbQp2p/1p2P3/3B1P2/2PB4/P1P2RPP/R5K1 w - - 0 1",
        "2kr2r1/1bpnqp2/1p1ppn2/p5pp/P1PP4/4PP2/1P1NBBPP/R2Q1RK1 w - - 0 1",
        "2b1k2r/5p2/pq1pNp1b/1p6/2r1PPBp/3Q4/PPP3PP/1K1RR3 w k - 0 1",
        "2b1r1k1/1p6/pQ1p1q1p/P2P3P/2P1pPpN/6P1/4R1K1/8 w - - 0 1",
        "2b2rk1/2qn1p2/p2p2pp/2pPP3/8/4NN1P/P1Q2PP1/bB2R1K1 w - - 0 1",
        "2bq2k1/1pr3bp/1Qpr2p1/P2pNp2/3P1P1P/6P1/5PB1/1RR3K1 w - - 0 1",
        "rr6/8/2pbkp2/ppp1p1p1/P3P3/1P1P1PB1/R1P2PK1/R7 b - - 0 1",
        "2r2rk1/pb2q2p/1pn1p2p/5p1Q/3P4/P1NB4/1P3PPP/R4RK1 w - - 0 1",
        "2kr4/ppqnbp1r/2n1p1p1/P2pP3/3P2P1/3BBN2/1P1Q1PP1/R4RK1 w - - 0 1",
        "2q5/1pb2r1k/p1b3pB/P1Pp3p/3P4/3B1pPP/1R3P1K/2Q5 b - - 0 1",
        "2r1kb1r/1bqn1pp1/p3p3/1p2P1P1/3Np3/P1N1B3/1PP1Q2P/R4RK1 w k - 0 1",
        "2r1rb2/1bq2p1k/3p1np1/p1p5/1pP1P1P1/PP2BPN1/2Q3P1/R2R1BK1 b - - 0 1",
        "2r2bk1/pq3r1p/6p1/2ppP1P1/P7/BP1Q4/2R3P1/3R3K b - - 0 1",
        "2r2rk1/1bb2ppp/p2ppn2/1p4q1/1PnNP3/P1N4P/2P1QPPB/3RRBK1 w - - 0 1",
        "2r2rk1/3q3p/p3pbp1/1p1pp3/4P3/2P5/PPN1QPPP/3R1RK1 b - - 0 1",
        "2r4k/pp3q1b/5PpQ/3p4/3Bp3/1P6/P5RP/6K1 w - - 0 1",
        "2r3k1/1b2b2p/r2p1pp1/pN1Pn3/1pPB2P1/1P5P/P3R1B1/5RK1 w - - 0 1",
        "2r3k1/5pp1/1pq4p/p7/P1nR4/2P2P2/Q5PP/4B1K1 b - - 0 1",
        "6k1/6pp/4r3/p1qpp3/Pp6/1n1P1B1P/1B2Q1P1/3R1K2 w - - 0 1",
        "r2qkb1r/1b1n1ppp/p3pn2/1pp5/3PP3/2NB1N2/PP3PPP/R1BQ1RK1 w kq - 0 1",
        "r3r1k1/pn1bnpp1/1p2p2p/1q1pPP2/1BpP3N/2P2BP1/2P3QP/R4RK1 w - - 0 1",
        "2r5/p3kpp1/1pn1p2p/8/1PP2P2/PB1R1KP1/7P/8 b - - 0 1",
        "2rq1rk1/1b2bppp/p2p1n2/1p1Pp3/1Pn1P3/5N1P/P1B2PP1/RNBQR1K1 w - - 0 1",
        "2rqr1k1/1b2bp1p/ppn1p1pB/3n4/3P3P/P1NQ1N2/1PB2PP1/3RR1K1 w - - 0 1",
        "3Rb3/5ppk/2r1r3/p5Pp/1pN2P1P/1P5q/P4Q2/K2R4 b - - 0 1",
        "3Rbrk1/4Q2p/6q1/pp3p2/4p2P/1P4P1/8/5R1K w - - 0 1",
        "3bn3/3r1p1k/3Pp1p1/1q6/Np2BP1P/3R2PK/8/3Q4 w - - 0 1",
        "3k1r1r/p2n1p1p/q2p2pQ/1p2P3/2pP4/P4N2/5PPP/2R1R1K1 w - - 0 1",
        "3r1bk1/1p2qp1p/p5p1/P1pPp3/2QnP3/3BB3/1P3PPP/2R3K1 w - - 0 1",
        "3r1bkr/2q3pp/1p1Npp2/pPn1P3/5B2/1P6/2P2PPP/R2QR1K1 w - - 0 1",
        "3r2k1/p2q1pp1/1p2n1p1/2p1P2n/P4P2/2B1Q1P1/7P/1R3BK1 w - - 0 1",
        "3r4/8/pq3kr1/3Bp3/7p/1P3P2/P5PP/3RQ2K b - - 0 1",
        "3r4/pk1p3p/1p2pp2/1N6/2P1KP2/6P1/3R3P/8 w - - 0 1",
        "4k2r/1b2b3/p3pp1p/1p1p4/3BnpP1/P1P4R/1KP4P/5BR1 w k - 0 1",
        "4k3/r2bbprp/3p1p1N/2qBpP2/ppP1P1P1/1P1R3P/P7/1KR1Q3 w - - 0 1",
        "4q1k1/pb5p/Nbp1p1r1/3r1p2/PP1Pp1pP/4P1P1/1BR1QP2/2R3K1 w - - 0 1",
        "4r1k1/1pb3qp/p1b1r1p1/P1Pp4/3P1p2/2BB4/1R1Q1PPP/1R4K1 b - - 0 1",
        "4r1k1/5p1p/p2q2p1/3p4/3Qn3/2P1RN2/Pr3PPP/R5K1 w - - 0 1",
        "4rr1k/pp1n2bp/7n/1Pp1pp1q/2Pp3N/1N1P1PP1/P5QP/2B1RR1K b - - 0 1",
        "4rrk1/p6p/2q2pp1/1p6/2pP1BQP/5N2/P4PP1/2R3K1 w - - 0 1",
        "5nk1/1bp1rnp1/pp1p4/4p1P1/2PPP3/NBP5/P2B4/4R1K1 w - - 0 1",
        "5r2/1p1k4/2bp4/r3pp1p/PRP4P/2P2PP1/2B2K2/7R b - - 0 1",
        "5r2/5p1Q/4pkp1/p7/1pb2q1P/5P2/P4RP1/3R2K1 w - - 0 1",
        "5rk1/1Q3pp1/p2p3p/4p1b1/N3PqP1/1N1K4/PP6/3R4 b - - 0 1",
        "7r/3nkpp1/4p3/p1pbP3/1r3P1p/1P2B2P/P2RBKP1/7R b - - 0 1",
        "8/1r1rq2k/2p3p1/3b1p1p/4p2P/1N1nP1P1/2Q2PK1/RR3B2 b - - 0 1",
        "8/1r2k3/4p2p/R3K2P/1p1P1P2/1P6/8/8 w - - 0 1",
        "8/3r1pp1/p7/2k2PpP/rp1pB3/2pK1P2/P1R5/1R6 w - - 0 1",
        "8/6k1/3P1bp1/2B1p3/1P6/1Q3P1q/7r/1K2R3 b - - 0 1",
        "b2rrbk1/2q2p1p/pn1p2p1/1p4P1/2nNPB1P/P1N3Q1/1PP3B1/1K1RR3 w - - 0 1",
        "b7/2pr1kp1/1p3p2/p2p3p/P1nP1N2/4P1P1/P1R2P1P/2R3K1 w - - 0 1",
        "k1qbr1n1/1p4p1/p1p1p1Np/2P2p1P/3P4/R7/PP2Q1P1/1K1R4 w - - 0 1",
        "r1b1rnk1/pp3pq1/2p3p1/6P1/2B2P1R/2P5/PP1Q2P1/2K4R w - - 0 1",
        "r1bq1rk1/pp3pbp/3Pp1p1/2p5/4PP2/2P5/P2QB1PP/1RB1K2R b K - 0 1",
        "r1bqr2k/pppn2bp/4n3/2P1p1p1/1P2Pp2/5NPB/PBQN1P1P/R4RK1 w - - 0 1",
        "r1br1k2/1pq2pb1/1np1p1pp/2N1N3/p2P1P1P/P3P1R1/1PQ3P1/1BR3K1 w - - 0 1",
        "r1n2k1r/5pp1/2R5/pB2pPq1/P2pP3/6Pp/1P2Q2P/5RK1 w - - 0 1",
        "r1r2bk1/pp1n1p1p/2pqb1p1/3p4/1P1P4/1QN1PN2/P3BPPP/2RR2K1 w - - 0 1",
        "r2q1r2/pp1b2kp/2n1p1p1/3p4/3P1P1P/2PB1N2/6P1/R3QRK1 w - - 0 1",
        "r2q1rk1/pp2b1pp/1np1b3/4pp2/1P6/P1NP1BP1/2Q1PP1P/1RB2RK1 w - - 0 1",
        "r2q4/6k1/r1p3p1/np1p1p2/3P4/4P1P1/R2QBPK1/7R w - - 0 1",
        "r2qr1k1/pp3pbp/5np1/2p2b2/8/2PP1Q2/PPB3PP/RNB2RK1 b - - 0 1",
        "r3k2r/1bq1bpp1/p4n2/2p1pP2/2NpP2p/3B4/PPP3PP/R1B1QR1K b k - 0 1",
        "r3k2r/2q2p2/p2bpPpp/1b1p4/1p1B1PPP/8/PPPQ4/1K1R1B1R w kq - 0 1",
        "r3k2r/ppq2p1p/2n1p1p1/3pP3/5PP1/2P1Q3/PP2N2P/3R1RK1 b k - 0 1",
        "r3r1k1/1pp1np1p/1b1p1p2/pP2p3/2PP2b1/P3PN2/1B3PPP/R3KB1R w KQ - 0 1",
        "r3r1k1/1pq2pbp/p1ppbnp1/4n3/2P1PB2/1NN2P2/PP1Q2PP/R3RBK1 w - - 0 1",
        "r3r1k1/bpp1np1p/3p1p2/pPP1p3/3P2b1/P3PN2/1B3PPP/R3KB1R w KQ - 0 1",
        "r3r1k1/pp2q3/2b1pp2/6pN/Pn1P4/6R1/1P3PP1/3QRBK1 w - - 0 1",
        "r4r2/1p2pbk1/1np1qppp/p7/3PP2P/P1Q2NP1/1P3PB1/2R1R1K1 w - - 0 1",
        "r4r2/2p2kb1/1p1p2p1/qPnPp2n/2B1PP2/pP6/P1Q1N2R/1KB4R w - - 0 1",
        "r4rk1/2p5/p2p1n2/1p1P3p/2P1p1pP/1P4B1/1P3PP1/3RR1K1 w - - 0 1",
        "r4rk1/2qnb1pp/4p3/ppPb1p2/3Pp3/1PB3P1/R1QNPPBP/R5K1 b - - 0 1",
        "r4rk1/p5pp/1p2b3/2Pn1p2/P2Pp2P/4P1Pq/2Q1BP2/R1BR2K1 w - - 0 1",
        "r4rk1/pbq2p2/2p2np1/1p2b2p/4P3/2N1BPP1/PPQ1B2P/R2R2K1 b - - 0 1",
        "r4rk1/pp1b2b1/n2p1nq1/2pP1p1p/2P1pP2/PP4PP/1BQ1N1B1/R3RNK1 b - - 0 1",
        "rn3rk1/p1p1qp2/1pbppn1p/6p1/P1PP4/2PBP1B1/3N1P1P/R2QK1R1 w Q - 0 1",
        "rnbq1rk1/2p1p1bp/p3pnp1/1p6/3P4/1QN1BN2/PP3PPP/R3KB1R w KQ - 0 1",
        "rr3n1k/q3bpn1/2p1p1p1/2PpP2p/pP1P1N1P/2BB1NP1/P2Q1P2/6RK w - - 0 1",
        "rnbqkb1r/pppp1ppp/8/4P3/6n1/7P/PPPNPPP1/R1BQKBNR b KQkq - 0 1",
        "r1b1kb1r/3q1ppp/pBp1pn2/8/Np3P2/5B2/PPP3PP/R2Q1RK1 w kq - 0 1",
        "r2qkb1r/1ppb1ppp/p7/4p3/P1Q1P3/2P5/5PPP/R1B2KNR b kq - 0 1",
        "r1bqk2r/ppp1nppp/4p3/n5N1/2BPp3/P1P5/2P2PPP/R1BQK2R w KQkq - 0 1",
        "r1bqr1k1/pp1nb1p1/4p2p/3p1p2/3P4/P1N1PNP1/1PQ2PP1/3RKB1R w K - 0 1",
        "r3kr2/1pp4p/1p1p4/7q/4P1n1/2PP2Q1/PP4P1/R1BB2K1 b q - 0 1",
        "r1bqk2r/pppp1ppp/5n2/2b1n3/4P3/1BP3Q1/PP3PPP/RNB1K1NR b KQkq - 0 1",
        "r3k2r/pbp2pp1/3b1n2/1p6/3P3p/1B2N1Pq/PP1PQP1P/R1B2RK1 b kq - 0 1",
        "r1b1k1nr/pp3pQp/4pq2/3pn3/8/P1P5/2P2PPP/R1B1KBNR w KQkq - 0 1",
        "rn2k1nr/pbp2ppp/3q4/1p2N3/2p5/QP6/PB1PPPPP/R3KB1R b KQkq - 0 1",
        "rnbqkb1r/1p3ppp/5N2/1p2p1B1/2P5/8/PP2PPPP/R2QKB1R b KQkq - 0 1",
        "r1b1k2r/1pp1q2p/p1n3p1/3QPp2/8/1BP3B1/P5PP/3R1RK1 w kq - 0 1",
        "r2r2k1/ppqbppbp/2n2np1/2pp4/6P1/1P1PPNNP/PBP2PB1/R2QK2R b KQ - 0 1",
        "r3kbnr/p4ppp/2p1p3/8/Q1B3b1/2N1B3/PP3PqP/R3K2R w KQkq - 0 1",
        "r3r1k1/5pp1/p1p4p/2Pp4/8/q1NQP1BP/5PP1/4K2R b K - 0 1",
        "r3k2r/pb1q1p2/8/2p1pP2/4p1p1/B1P1Q1P1/P1P3K1/R4R2 b kq - 0 1",
        "r1q2rk1/p3bppb/3p1n1p/2nPp3/1p2P1P1/6NP/PP2QPB1/R1BNK2R b KQ - 0 1",
        "r3k2r/2p2p2/p2p1n2/1p2p3/4P2p/1PPPPp1q/1P5P/R1N2QRK b kq - 0 1",
        "r1b2rk1/ppqn1p1p/2n1p1p1/2b3N1/2N5/PP1BP3/1B3PPP/R2QK2R w KQ - 0 1",
        "r3k3/ppp2Npp/4Bn2/2b5/1n1pp3/N4P2/PPP3qP/R2QKR2 b Qq - 0 1",
        "rr4k1/p1pq2pp/Q1n1pn2/2bpp3/4P3/2PP1NN1/PP3PPP/R1B1K2R b KQ - 0 1",
        "4kb1r/2q2p2/r2p4/pppBn1B1/P6P/6Q1/1PP5/2KRR3 w k - 0 1",
        "r3kb1r/1pp3p1/p3bp1p/5q2/3QN3/1P6/PBP3P1/3RR1K1 w kq - 0 1",
        "r3k3/P5bp/2N1bp2/4p3/2p5/6NP/1PP2PP1/3R2K1 w q - 0 1",
        "r1bqk2r/pp3ppp/5n2/8/1b1npB2/2N5/PP1Q2PP/1K2RBNR w kq - 0 1",
        "rnbqr2k/pppp1Qpp/8/b2NN3/2B1n3/8/PPPP1PPP/R1B1K2R w KQ - 0 1",
        "2r1k2r/2pn1pp1/1p3n1p/p3PP2/4q2B/P1P5/2Q1N1PP/R4RK1 w k - 0 1",
        "2r1kb1r/pp3ppp/2n1b3/1q1N2B1/1P2Q3/8/P4PPP/3RK1NR w Kk - 0 1",
        "2kr2nr/pp1n1ppp/2p1p3/q7/1b1P1B2/P1N2Q1P/1PP1BPP1/R3K2R w KQ - 0 1",
        "r2qkb1r/pppb2pp/2np1n2/5pN1/2BQP3/2N5/PPP2PPP/R1B1K2R w KQkq - 0 1",
    };       

    std.debug.print("\n", .{});

    for (test_cases) |test_case| {
        // Set up position
        var curr_pos = Position.new();
        try curr_pos.set(test_case);

        const fen = try curr_pos.get_fen(std.heap.c_allocator);
        defer std.heap.c_allocator.free(fen);
        std.debug.print("FEN: {s}\n", .{fen});
        try std.testing.expectEqualStrings(test_case, fen); // Use expectEqualStrings for string comparison
    }

}

test "test_movegen_speed" {

    const Timer = std.time.Timer;

    const test_pos = [_][]const u8{
        "r3qb1k/1b4p1/p2pr2p/3n4/Pnp1N1N1/6RP/1B3PP1/1B1QR1K1 w - - 0 1",
        "r4rk1/pp1n1p1p/1nqP2p1/2b1P1B1/4NQ2/1B3P2/PP2K2P/2R5 w - - 0 1",
        "r2qk2r/ppp1b1pp/2n1p3/3pP1n1/3P2b1/2PB1NN1/PP4PP/R1BQK2R w KQkq - 0 1",
        "r1b1kb1r/1p1n1ppp/p2ppn2/6BB/2qNP3/2N5/PPP2PPP/R2Q1RK1 w kq - 0 1",
        "r2qrb1k/1p1b2p1/p2ppn1p/8/3NP3/1BN5/PPP3QP/1K3RR1 w - - 0 1",
        "rnbqk2r/1p3ppp/p7/1NpPp3/QPP1P1n1/P4N2/4KbPP/R1B2B1R b kq - 0 1 ",
        "1r1bk2r/2R2ppp/p3p3/1b2P2q/4QP2/4N3/1B4PP/3R2K1 w k - 0 1",
        "r3rbk1/ppq2ppp/2b1pB2/8/6Q1/1P1B3P/P1P2PP1/R2R2K1 w - - 0 1",
        "r4r1k/4bppb/2n1p2p/p1n1P3/1p1p1BNP/3P1NP1/qP2QPB1/2RR2K1 w - - 0 1",
        "r1b2rk1/1p1nbppp/pq1p4/3B4/P2NP3/2N1p3/1PP3PP/R2Q1R1K w - - 0 1",
        "r1b3k1/p2p1nP1/2pqr1Rp/1p2p2P/2B1PnQ1/1P6/P1PP4/1K4R1 w - - 0 1",
        "1k1r4/pp1b1R2/3q2pp/4p3/2B5/4Q3/PPP2B2/2K5 b - - 0 1",
        "3r1k2/4npp1/1ppr3p/p6P/P2PPPP1/1NR5/5K2/2R5 w - - 0 1",
        "2q1rr1k/3bbnnp/p2p1pp1/2pPp3/PpP1P1P1/1P2BNNP/2BQ1PRK/7R b - - 0 1",
        "rnbqkb1r/p3pppp/1p6/2ppP3/3N4/2P5/PPP1QPPP/R1B1KB1R w KQkq - 0 1",
        "r1b2rk1/2q1b1pp/p2ppn2/1p6/3QP3/1BN1B3/PPP3PP/R4RK1 w - - 0 1",
        "2r3k1/pppR1pp1/4p3/4P1P1/5P2/1P4K1/P1P5/8 w - - 0 1",
        "1nk1r1r1/pp2n1pp/4p3/q2pPp1N/b1pP1P2/B1P2R2/2P1B1PP/R2Q2K1 w - - 0 1",
        "4b3/p3kp2/6p1/3pP2p/2pP1P2/4K1P1/P3N2P/8 w - - 0 1",
        "2kr1bnr/pbpq4/2n1pp2/3p3p/3P1P1B/2N2N1Q/PPP3PP/2KR1B1R w - - 0 1",
        "3rr1k1/pp3pp1/1qn2np1/8/3p4/PP1R1P2/2P1NQPP/R1B3K1 b - - 0 1",
        "2r1nrk1/p2q1ppp/bp1p4/n1pPp3/P1P1P3/2PBB1N1/4QPPP/R4RK1 w - - 0 1",
        "r3r1k1/ppqb1ppp/8/4p1NQ/8/2P5/PP3PPP/R3R1K1 b - - 0 1",
        "r2q1rk1/4bppp/p2p4/2pP4/3pP3/3Q4/PP1B1PPP/R3R1K1 w - - 0 1",
        "rnb2r1k/pp2p2p/2pp2p1/q2P1p2/8/1Pb2NP1/PB2PPBP/R2Q1RK1 w - - 0 1",
        "2r3k1/1p2q1pp/2b1pr2/p1pp4/6Q1/1P1PP1R1/P1PN2PP/5RK1 w - - 0 1",
        "r1bqkb1r/4npp1/p1p4p/1p1pP1B1/8/1B6/PPPN1PPP/R2Q1RK1 w kq - 0 1",
        "r2q1rk1/1ppnbppp/p2p1nb1/3Pp3/2P1P1P1/2N2N1P/PPB1QP2/R1B2RK1 b - - 0 1",
        "r1bq1rk1/pp2ppbp/2np2p1/2n5/P3PP2/N1P2N2/1PB3PP/R1B1QRK1 b - - 0 1",
        "3rr3/2pq2pk/p2p1pnp/8/2QBPP2/1P6/P5PP/4RRK1 b - - 0 1",
        "r4k2/pb2bp1r/1p1qp2p/3pNp2/3P1P2/2N3P1/PPP1Q2P/2KRR3 w - - 0 1",
        "3rn2k/ppb2rpp/2ppqp2/5N2/2P1P3/1P5Q/PB3PPP/3RR1K1 w - - 0 1",
        "2r2rk1/1bqnbpp1/1p1ppn1p/pP6/N1P1P3/P2B1N1P/1B2QPP1/R2R2K1 b - - 0 1",
        "r1bqk2r/pp2bppp/2p5/3pP3/P2Q1P2/2N1B3/1PP3PP/R4RK1 b kq - 0 1",
        "r2qnrnk/p2b2b1/1p1p2pp/2pPpp2/1PP1P3/PRNBB3/3QNPPP/5RK1 w - - 0 1",
        "rn1qkb1r/pp2pppp/5n2/3p1b2/3P4/2N1P3/PP3PPP/R1BQKBNR w KQkq - 0 1",
        "rn1qkb1r/pp2pppp/5n2/3p1b2/3P4/1QN1P3/PP3PPP/R1B1KBNR b KQkq - 1 1",
        "r1bqk2r/ppp2ppp/2n5/4P3/2Bp2n1/5N1P/PP1N1PP1/R2Q1RK1 b kq - 1 10",
        "r1bqrnk1/pp2bp1p/2p2np1/3p2B1/3P4/2NBPN2/PPQ2PPP/1R3RK1 w - - 1 12",
        "rnbqkb1r/ppp1pppp/5n2/8/3PP3/2N5/PP3PPP/R1BQKBNR b KQkq - 3 5",
        "rnbq1rk1/pppp1ppp/4pn2/8/1bPP4/P1N5/1PQ1PPPP/R1B1KBNR b KQ - 1 5",
        "r4rk1/3nppbp/bq1p1np1/2pP4/8/2N2NPP/PP2PPB1/R1BQR1K1 b - - 1 12",
        "rn1qkb1r/pb1p1ppp/1p2pn2/2p5/2PP4/5NP1/PP2PPBP/RNBQK2R w KQkq c6 1 6",
        "r1bq1rk1/1pp2pbp/p1np1np1/3Pp3/2P1P3/2N1BP2/PP4PP/R1NQKB1R b KQ - 1 9",
        "rnbqr1k1/1p3pbp/p2p1np1/2pP4/4P3/2N5/PP1NBPPP/R1BQ1RK1 w - - 1 11",
        "rnbqkb1r/pppp1ppp/5n2/4p3/4PP2/2N5/PPPP2PP/R1BQKBNR b KQkq f3 1 3",
        "r1bqk1nr/pppnbppp/3p4/8/2BNP3/8/PPP2PPP/RNBQK2R w KQkq - 2 6",
        "rnbq1b1r/ppp2kpp/3p1n2/8/3PP3/8/PPP2PPP/RNBQKB1R b KQ d3 1 5",
        "rnbqkb1r/pppp1ppp/3n4/8/2BQ4/5N2/PPP2PPP/RNB2RK1 b kq - 1 6",
        "r2q1rk1/2p1bppp/p2p1n2/1p2P3/4P1b1/1nP1BN2/PP3PPP/RN1QR1K1 w - - 1 12",
        "r1bqkb1r/2pp1ppp/p1n5/1p2p3/3Pn3/1B3N2/PPP2PPP/RNBQ1RK1 b kq - 2 7",
        "r2qkbnr/2p2pp1/p1pp4/4p2p/4P1b1/5N1P/PPPP1PP1/RNBQ1RK1 w kq - 1 8",
        "r1bqkb1r/pp3ppp/2np1n2/4p1B1/3NP3/2N5/PPP2PPP/R2QKB1R w KQkq e6 1 7",
        "rn1qk2r/1b2bppp/p2ppn2/1p6/3NP3/1BN5/PPP2PPP/R1BQR1K1 w kq - 5 10",
        "r1b1kb1r/1pqpnppp/p1n1p3/8/3NP3/2N1B3/PPP1BPPP/R2QK2R w KQkq - 3 8",
        "r1bqnr2/pp1ppkbp/4N1p1/n3P3/8/2N1B3/PPP2PPP/R2QK2R b KQ - 2 11",
        "r3kb1r/pp1n1ppp/1q2p3/n2p4/3P1Bb1/2PB1N2/PPQ2PPP/RN2K2R w KQkq - 3 11",
        "r1bq1rk1/pppnnppp/4p3/3pP3/1b1P4/2NB3N/PPP2PPP/R1BQK2R w KQ - 3 7",
        "r2qkbnr/ppp1pp1p/3p2p1/3Pn3/4P1b1/2N2N2/PPP2PPP/R1BQKB1R w KQkq - 2 6",
        "rn2kb1r/pp2pppp/1qP2n2/8/6b1/1Q6/PP1PPPBP/RNB1K1NR b KQkq - 1 6",
        "r2r2k1/pp1b1ppp/8/3p2P1/3N4/P3P3/1P3P1P/3RK2R b K - 0 1",
        "r3k2r/1b1nb1p1/p1q1pn1p/1pp3N1/4PP2/2N5/PPB3PP/R1BQ1RK1 w kq - 0 1",
        "r3k2r/1pqnnppp/p5b1/1PPp1p2/3P4/2N5/P2NB1PP/2RQ1RK1 b kq - 0 1",
        "r3k2r/p1q1nppp/1pn5/2P1p3/4P1Q1/P1P2P2/4N1PP/R1B2K1R b kq - 0 1",
        "r3k2r/pp2pp1p/6p1/2nP4/1R2PB2/4PK2/P5PP/5bNR w kq - 0 1",
        "r3k2r/ppp1bppp/2n5/3n4/3PB3/8/PP3PPP/RNB1R1K1 b kq - 0 1",
        "r3kb1r/pp3ppp/4bn2/3p4/P7/4N1P1/1P2PPBP/R1B1K2R w KQkq - 0 1",
        "r3kbnr/1pp3pp/p1p2p2/8/3qP3/5Q1P/PP3PP1/RNB2RK1 w kq - 0 1",
        "r3kr2/pppb1p2/2n3p1/3Bp2p/4P2N/2P5/PP3PPP/2KR3R b q - 0 1",
        "r3nrk1/pp2qpb1/3p1npp/2pPp3/2P1P2N/2N3Pb/PP1BBP1P/R2Q1RK1 w - - 0 1",
        "r3r1k1/1pqn1pbp/p2p2p1/2nP2B1/P1P1P3/2NB3P/5PP1/R2QR1K1 w - - 0 1",
        "r3r1k1/pp1q1ppp/2p5/P2n1p2/1b1P4/1B2PP2/1PQ3PP/R1B2RK1 w - - 0 1",
        "r3r1k1/pp3ppp/2ppqn2/5R2/2P5/2PQP1P1/P2P2BP/5RK1 w - - 0 1",
        "r3rbk1/p2b1p2/5p1p/1q1p4/N7/6P1/PP1BPPBP/3Q1RK1 w - - 0 1",
        "r4r1k/pp1bq1b1/n2p2p1/2pPp1Np/2P4P/P1N1BP2/1P1Q2P1/2KR3R w - - 0 1",
        "r4rk1/1bqp1ppp/pp2pn2/4b3/P1P1P3/2N2BP1/1PQB1P1P/2R2RK1 w - - 0 1",
        "r4rk1/1q2bppp/p1bppn2/8/3BPP2/3B2Q1/1PP1N1PP/4RR1K w - - 0 1",
        "r4rk1/pp2qpp1/2pRb2p/4P3/2p5/2Q1PN2/PP3PPP/4K2R w K - 0 1",
        "r7/3rq1kp/2p1bpp1/p1Pnp3/2B4P/PP4P1/1B1RQP2/2R3K1 b - - 0 1",
        "r7/pp1bpp2/1n1p2pk/1B3P2/4P1P1/2N5/PPP5/1K5R b - - 0 1",
        "rn1q1rk1/p4pbp/bp1p1np1/2pP4/8/P1N2NP1/1PQ1PPBP/R1B1K2R w KQ - 0 1",
        "rn1q1rk1/pb3p2/1p5p/3n2P1/3p4/P4P2/1P1Q1BP1/R3KBNR b KQ - 0 1",
        "rn1q1rk1/pp2bppp/1n2p1b1/8/2pPP3/1BN1BP2/PP2N1PP/R2Q1RK1 w - - 0 1",
        "rn1q1rk1/pp3ppp/4bn2/2bp4/5B2/2NBP1N1/PP3PPP/R2QK2R w KQ - 0 1",
        "rn1qkbnr/pp1b1ppp/8/1Bpp4/3P4/8/PPPNQPPP/R1B1K1NR b KQkq - 0 1",
        "r3kb1r/3n1pp1/p6p/2pPp2q/Pp2N3/3B2PP/1PQ2P2/R3K2R w KQkq - 0 1",
        "1k1r3r/pp2qpp1/3b1n1p/3pNQ2/2pP1P2/2N1P3/PP4PP/1K1RR3 b - - 0 1",
        "r6k/pp4p1/2p1b3/3pP3/7q/P2B3r/1PP2Q1P/2K1R1R1 w - - 0 1",
        "1nr5/2rbkppp/p3p3/Np6/2PRPP2/8/PKP1B1PP/3R4 b - - 0 1",
        "2r2rk1/1p1bq3/p3p2p/3pPpp1/1P1Q4/P7/2P2PPP/2R1RBK1 b - - 0 1",
        "3r1bk1/p4ppp/Qp2p3/8/1P1B4/Pq2P1P1/2r2P1P/R3R1K1 b - - 0 1",
        "r1b2r1k/pp2q1pp/2p2p2/2p1n2N/4P3/1PNP2QP/1PP2RP1/5RK1 w - - 0 1",
        "r2qrnk1/pp3ppb/3b1n1p/1Pp1p3/2P1P2N/P5P1/1B1NQPBP/R4RK1 w - - 0 1",
        "5nk1/Q4bpp/5p2/8/P1n1PN2/q4P2/6PP/1R4K1 w - - 0 1",
        "r3k2r/3bbp1p/p1nppp2/5P2/1p1NP3/5NP1/PPPK3P/3R1B1R b kq - 0 1",
        "bn6/1q4n1/1p1p1kp1/2pPp1pp/1PP1P1P1/3N1P1P/4B1K1/2Q2N2 w - - 0 1",
        "3r2k1/pp2npp1/2rqp2p/8/3PQ3/1BR3P1/PP3P1P/3R2K1 b - - 0 1",
        "1r2r1k1/4ppbp/B5p1/3P4/pp1qPB2/2n2Q1P/P4PP1/4RRK1 b - - 0 1",
        "r2qkb1r/1b3ppp/p3pn2/1p6/1n1P4/1BN2N2/PP2QPPP/R1BR2K1 w kq - 0 1",
        "1r4k1/1q2bp2/3p2p1/2pP4/p1N4R/2P2QP1/1P3PK1/8 w - - 0 1",
        "rn3rk1/pbppq1pp/1p2pb2/4N2Q/3PN3/3B4/PPP2PPP/R3K2R w KQ - 0 1",
        "4r1k1/3b1p2/5qp1/1BPpn2p/7n/r3P1N1/2Q1RPPP/1R3NK1 b - - 0 1",
        "2k2b1r/1pq3p1/2p1pp2/p1n1PnNp/2P2B2/2N4P/PP2QPP1/3R2K1 w - - 0 1",
        "2r2r2/3qbpkp/p3n1p1/2ppP3/6Q1/1P1B3R/PBP3PP/5R1K w - - 0 1",
        "2r1k2r/2pn1pp1/1p3n1p/p3PP2/4q2B/P1P5/2Q1N1PP/R4RK1 w q - 0 1",
        "2rr2k1/1b3ppp/pb2p3/1p2P3/1P2BPnq/P1N3P1/1B2Q2P/R4R1K b - - 0 1",
        "2b1r1k1/r4ppp/p7/2pNP3/4Q3/q6P/2P2PP1/3RR1K1 w - - 0 1",
        "6k1/5p2/3P2p1/7n/3QPP2/7q/r2N3P/6RK b - - 0 1",
        "rq2rbk1/6p1/p2p2Pp/1p1Rn3/4PB2/6Q1/PPP1B3/2K3R1 w - - 0 1",
        "rnbq2k1/p1r2p1p/1p1p1Pp1/1BpPn1N1/P7/2P5/6PP/R1B1QRK1 w - - 0 1",
        "r2qrb1k/1p1b2p1/p2ppn1p/8/3NP3/1BN5/PPP3QP/1K3RR1 w - - 0 1",
        "8/1p3pp1/7p/5P1P/2k3P1/8/2K2P2/8 w - - 0 1",
        "8/pp2r1k1/2p1p3/3pP2p/1P1P1P1P/P5KR/8/8 w - - 0 1",
        "8/3p4/p1bk3p/Pp6/1Kp1PpPp/2P2P1P/2P5/5B2 b - - 0 1",
        "5k2/7R/4P2p/5K2/p1r2P1p/8/8/8 b - - 0 1",
        "6k1/6p1/7p/P1N5/1r3p2/7P/1b3PP1/3bR1K1 w - - 0 1",
        "8/3b4/5k2/2pPnp2/1pP4N/pP1B2P1/P3K3/8 b - - 0 1",
        "6k1/4pp1p/3p2p1/P1pPb3/R7/1r2P1PP/3B1P2/6K1 w - - 0 1",
        "2k5/p7/Pp1p1b2/1P1P1p2/2P2P1p/3K3P/5B2/8 w - - 0 1",
        "8/5Bp1/4P3/6pP/1b1k1P2/5K2/8/8 w - - 0 1",
    };

     // Create timer for overall measurement
    var total_time_ns: u64 = 0;
    const num_repeats: u32 = 100000;

    attacks.initialise_all_databases();
    zobrist.initialise_zobrist_keys();

    for (test_pos) |fen| {
        var curr_pos = Position.new();
        try curr_pos.set(fen);
        //std.debug.print("Testing FEN: {s},\n", .{fen});

        var pos_timer = try Timer.start();
        var elapsed_pos: u64 = undefined;
        
        // do 1000 loops
        // measure time from here 
        if (curr_pos.side_to_play == Color.White) {
            const _us = Color.White;
            var i: u64 = 0;

            var ctx: Position.MoveGenContext = undefined;
            //var move_list: MoveList = .{};

            const start_pos = pos_timer.read();
            while (i < num_repeats) : (i+=1) {
                ctx = curr_pos.computeMoveGenContext(_us);

                //move_list.count = 0;
                // curr_pos.generate_legals(_us, &move_list);
                //curr_pos.generate_noisy_legals(_us, &move_list);
            }
            const end_pos = pos_timer.read();
            elapsed_pos = end_pos - start_pos;
        } else {
            const _us = Color.Black;
            var i: u64 = 0;

            var ctx: Position.MoveGenContext = undefined;
            //var move_list: MoveList = .{};

            const start_pos = pos_timer.read();
            while (i < num_repeats) : (i+=1) {
                ctx = curr_pos.computeMoveGenContext(_us);

                //move_list.count = 0;
                // curr_pos.generate_legals(_us, &move_list);
                //curr_pos.generate_noisy_legals(_us, &move_list);
            }
            const end_pos = pos_timer.read();
            elapsed_pos = end_pos - start_pos;
        }

        
        total_time_ns += elapsed_pos;

        //std.debug.print("  Time: {d} ns\n", .{elapsed_pos});

        // measure time to here

    }

    // Print summary statistics
    const num_positions = test_pos.len;
    const avg_time_per_position = @divFloor(total_time_ns, num_positions*num_repeats);
    
    std.debug.print("\n--- Performance Summary ---\n", .{});
    std.debug.print("Total positions tested: {d}\n", .{num_positions});
    std.debug.print("Total time (all positions): {d} ns\n", .{total_time_ns});
    std.debug.print("Average time per position: {d} ns\n", .{avg_time_per_position});
    //std.debug.print("Average time per position (Âµs): {d:.2} Âµs\n", .{@as(f64, @floatFromInt(avg_time_per_position)) / 1000.0});

}
