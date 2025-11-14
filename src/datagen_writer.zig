const std = @import("std");
const position = @import("position.zig");

const Position = position.Position;
const Move = position.Move;
const Piece = position.Piece;
// Pack the current Position into a 32-byte PackedSfen buffer (NNUE format)
pub fn pack_sfen32(pos: *Position, out: *[32]u8) void {
    const data = out[0..];
    @memset(data, 0);
    var bit_cursor: usize = 0;
    // Side to move: W=0, B=1
    bs_write_one(data, &bit_cursor, pos.side_to_play == position.Color.Black);
    // King squares (6 bits each)
    var wk: i32 = -1;
    var bk: i32 = -1;
    var idx: usize = 0;
    while (idx < 64) : (idx += 1) {
        const pc = pos.board[idx];
        if (pc == Piece.WHITE_KING) wk = @intCast(idx);
        if (pc == Piece.BLACK_KING) bk = @intCast(idx);
    }
    bs_write_n(data, &bit_cursor, @as(u32, @intCast(wk)), 6);
    bs_write_n(data, &bit_cursor, @as(u32, @intCast(bk)), 6);
    // Pieces excluding kings: rank8..rank1, fileA..fileH
    var r: i32 = 7;
    while (r >= 0) : (r -= 1) {
        var f: usize = 0;
        while (f < 8) : (f += 1) {
            const sq: usize = @as(usize, @intCast(r)) * 8 + f;
            const pc = pos.board[sq];
            if (pc == Piece.WHITE_KING or pc == Piece.BLACK_KING) continue;
            huff_write_piece(data, &bit_cursor, pc);
        }
    }
    // Castling: Wk, Wq, Bk, Bq (1 bit each)
    const cr_mask: u8 = pos.history[pos.game_ply].castling;
    bs_write_one(data, &bit_cursor, (cr_mask & position.Castling.WK.toU4()) != 0);
    bs_write_one(data, &bit_cursor, (cr_mask & position.Castling.WQ.toU4()) != 0);
    bs_write_one(data, &bit_cursor, (cr_mask & position.Castling.BK.toU4()) != 0);
    bs_write_one(data, &bit_cursor, (cr_mask & position.Castling.BQ.toU4()) != 0);
    // EP presence + 6 bits
    const epsq = pos.history[pos.game_ply].epsq;
    if (epsq == position.Square.NO_SQUARE) {
        bs_write_one(data, &bit_cursor, false);
    } else {
        bs_write_one(data, &bit_cursor, true);
        bs_write_n(data, &bit_cursor, @as(u32, epsq.toU6()), 6);
    }
    // rule50 low6, fullmove low8, fullmove high8, rule50 high1
    const rule50: u16 = pos.history[pos.game_ply].fifty;
    const fm: u16 = @intCast(pos.fullmove_number);
    bs_write_n(data, &bit_cursor, @as(u32, rule50 & 0x3F), 6);
    bs_write_n(data, &bit_cursor, @as(u32, fm & 0xFF), 8);
    bs_write_n(data, &bit_cursor, @as(u32, (fm >> 8) & 0xFF), 8);
    bs_write_n(data, &bit_cursor, @as(u32, (rule50 >> 6) & 0x1), 1);
}

inline fn bs_write_one(data: []u8, bit_cursor_ptr: *usize, b: bool) void {
    const byte_index: usize = bit_cursor_ptr.* / 8;
    const bit_index: u3 = @intCast(bit_cursor_ptr.* & 7);
    if (b) data[byte_index] |= (@as(u8, 1) << bit_index);
    bit_cursor_ptr.* += 1;
}

inline fn bs_write_n(data: []u8, bit_cursor_ptr: *usize, d: u32, n: u5) void {
    var i: u5 = 0;
    while (i < n) : (i += 1) {
        bs_write_one(data, bit_cursor_ptr, (d & (@as(u32, 1) << i)) != 0);
    }
}

inline fn huff_write_piece(data: []u8, bit_cursor_ptr: *usize, pc: Piece) void {
    // Empty
    if (pc == Piece.NO_PIECE) {
        bs_write_n(data, bit_cursor_ptr, 0, 1);
        return;
    }
    const pt = pc.type_of();
    var code: u32 = 0;
    switch (pt) {
        .Pawn => code = 0b0001,
        .Knight => code = 0b0011,
        .Bishop => code = 0b0101,
        .Rook => code = 0b0111,
        .Queen => code = 0b1001,
        .King => return, // kings handled separately
        else => {
            // unknown => empty
            bs_write_n(data, bit_cursor_ptr, 0, 1);
            return;
        },
    }
    bs_write_n(data, bit_cursor_ptr, code, 4);
    // color bit: White=0, Black=1
    const black = pc.color() == position.Color.Black;
    bs_write_one(data, bit_cursor_ptr, black);
}

pub const Bin40Writer = struct {
    file: std.fs.File,
    buf: [4096]u8,
    buf_len: usize,

    pub fn open(path: []const u8) !Bin40Writer {
        const f = try std.fs.cwd().createFile(path, .{ .read = false, .truncate = true });
        return .{ .file = f, .buf = @splat(0), .buf_len = 0 };
    }

    fn flush(self: *Bin40Writer) !void {
        if (self.buf_len == 0) return;
        try self.file.writeAll(self.buf[0..self.buf_len]);
        self.buf_len = 0;
    }

    fn write_bytes(self: *Bin40Writer, bytes: []const u8) !void {
        if (bytes.len > self.buf.len) {
            // large write: flush and write directly
            try self.flush();
            try self.file.writeAll(bytes);
            return;
        }
        if (self.buf_len + bytes.len > self.buf.len) {
            try self.flush();
        }
        @memcpy(self.buf[self.buf_len .. self.buf_len + bytes.len], bytes);
        self.buf_len += bytes.len;
    }

    pub fn write_packed(self: *Bin40Writer, sfen32: *const [32]u8, score_cp: i32, move16: u16, game_ply: u16, game_result: i8) !void {
        var buf: [40]u8 = @splat(0);
        @memcpy(buf[0..32], sfen32);
        const cp = clamp_cp(score_cp);
        const cp_u16: u16 = @bitCast(cp);
        buf[32] = @as(u8, @truncate(cp_u16));
        buf[33] = @as(u8, @truncate(cp_u16 >> 8));
        buf[34] = @as(u8, @truncate(move16));
        buf[35] = @as(u8, @truncate(move16 >> 8));
        buf[36] = @as(u8, @truncate(game_ply));
        buf[37] = @as(u8, @truncate(game_ply >> 8));
        buf[38] = @bitCast(game_result);
        buf[39] = 0;
        try self.write_bytes(&buf);
    }

    pub fn close(self: *Bin40Writer) void {
        // Flush manual buffer before closing
        self.flush() catch {};
        self.file.close();
    }

    fn encode_piece_nibble(pc: Piece) u4 {
        // Use engine's internal 4-bit piece code directly (fits in 0..14),
        // leave 15 unused.
        return @as(u4, pc.toU4());
    }

    pub fn encode_move16(pos: *const Position, mv: Move) u16 {
        // Stockfish packed move: to in low 6, from in next 6, promo in bits 12-13, flags in bits 14-15
        var code: u16 = 0;
        const from_sq: u6 = mv.from;
        var to_sq: u6 = mv.to;

        if (mv.flags == position.MoveFlags.OO or mv.flags == position.MoveFlags.OOO) {
            const ci = pos.side_to_play.toU4();
            if (pos.is_chess960) {
                const rook_sq = if (mv.flags == position.MoveFlags.OO)
                    pos.castle_rook_k_start[ci]
                else
                    pos.castle_rook_q_start[ci];
                if (rook_sq != position.Square.NO_SQUARE) {
                    to_sq = rook_sq.toU6();
                }
            }
        }

        code |= @as(u16, to_sq & 0x3F);
        code |= (@as(u16, from_sq & 0x3F)) << 6;

        var promo: u16 = 0;
        var flags: u16 = 0;

        if (mv.is_promotion()) {
            const pt = mv.flags.promote_type();
            promo = switch (pt) {
                .Knight => 0,
                .Bishop => 1,
                .Rook => 2,
                .Queen => 3,
                else => 0,
            };
            flags = 1; // promotion flag
        } else if (mv.flags == position.MoveFlags.EN_PASSANT) {
            flags = 2; // en passant flag
        } else if (mv.flags == position.MoveFlags.OO or mv.flags == position.MoveFlags.OOO) {
            flags = 3; // castling flag
        }

        code |= (promo & 0x3) << 12;
        code |= (flags & 0x3) << 14;
        return code;
    }

    fn clamp_cp(score: i32) i16 {
        const lo: i32 = -32000;
        const hi: i32 = 32000;
        return @intCast(@max(lo, @min(hi, score)));
    }

    fn result_code(result_white: f32) u2 {
        // 0 = draw, 1 = white win, 2 = white loss
        if (result_white >= 0.75) return 1;
        if (result_white <= 0.25) return 2;
        return 0;
    }

    pub fn write_position(
        self: *Bin40Writer,
        pos: *Position,
        bm: Move,
        score_cp: i32,
        result_white: f32,
        game_ply: u16,
    ) !void {
        var buf: [40]u8 = @splat(0);

        // --- pack PackedSfen into first 32 bytes ---
        const data = buf[0..32];
        // bit stream (LSB-first within each byte)
        var bit_cursor: usize = 0;

        // Side to move: 1 bit (W=0,B=1)
        bs_write_one(data, &bit_cursor, pos.side_to_play == position.Color.Black);

        // King squares (6 bits each)
        var wk: i32 = -1;
        var bk: i32 = -1;
        var idx: usize = 0;
        while (idx < 64) : (idx += 1) {
            const pc = pos.board[idx];
            if (pc == Piece.WHITE_KING) wk = @intCast(idx);
            if (pc == Piece.BLACK_KING) bk = @intCast(idx);
        }
        bs_write_n(data, &bit_cursor, @as(u32, @intCast(wk)), 6);
        bs_write_n(data, &bit_cursor, @as(u32, @intCast(bk)), 6);

        var r: i32 = 7;
        while (r >= 0) : (r -= 1) {
            var f: usize = 0;
            while (f < 8) : (f += 1) {
                const sq: usize = @as(usize, @intCast(r)) * 8 + f;
                const pc = pos.board[sq];
                if (pc == Piece.WHITE_KING or pc == Piece.BLACK_KING) continue;
                huff_write_piece(data, &bit_cursor, pc);
            }
        }

        // Castling: 1 bit x 4 (W K, W Q, B K, B Q) in that order
        const cr_mask: u8 = pos.history[pos.game_ply].castling;
        bs_write_one(data, &bit_cursor, (cr_mask & position.Castling.WK.toU4()) != 0);
        bs_write_one(data, &bit_cursor, (cr_mask & position.Castling.WQ.toU4()) != 0);
        bs_write_one(data, &bit_cursor, (cr_mask & position.Castling.BK.toU4()) != 0);
        bs_write_one(data, &bit_cursor, (cr_mask & position.Castling.BQ.toU4()) != 0);

        // En passant square presence + 6 bits if present
        const epsq = pos.history[pos.game_ply].epsq;
        if (epsq == position.Square.NO_SQUARE) {
            bs_write_one(data, &bit_cursor, false);
        } else {
            bs_write_one(data, &bit_cursor, true);
            bs_write_n(data, &bit_cursor, @as(u32, epsq.toU6()), 6);
        }

        // Rule50 (6 bits low), Fullmove (8 bits), Fullmove high bits (8), Rule50 high (1)
        const rule50: u16 = pos.history[pos.game_ply].fifty;
        const fm: u16 = @intCast(pos.fullmove_number);
        bs_write_n(data, &bit_cursor, @as(u32, rule50 & 0x3F), 6);
        bs_write_n(data, &bit_cursor, @as(u32, fm & 0xFF), 8);
        bs_write_n(data, &bit_cursor, @as(u32, (fm >> 8) & 0xFF), 8);
        bs_write_n(data, &bit_cursor, @as(u32, (rule50 >> 6) & 0x1), 1);

        // --- trailing fields ---
        // score (i16)
        const cp = clamp_cp(score_cp);
        const cp_u16: u16 = @bitCast(cp);
        buf[32] = @as(u8, @truncate(cp_u16));
        buf[33] = @as(u8, @truncate(cp_u16 >> 8));

        // move16
        const m16 = encode_move16(pos, bm);
        buf[34] = @as(u8, @truncate(m16));
        buf[35] = @as(u8, @truncate(m16 >> 8));

        // gamePly (u16)
        buf[36] = @as(u8, @truncate(game_ply));
        buf[37] = @as(u8, @truncate(game_ply >> 8));

        // game_result (int8): from side-to-move perspective
        var gr: i8 = 0;
        if (result_white >= 0.75) {
            gr = if (pos.side_to_play == position.Color.White) 1 else -1;
        } else if (result_white <= 0.25) {
            gr = if (pos.side_to_play == position.Color.White) -1 else 1;
        } else {
            gr = 0;
        }
        buf[38] = @bitCast(gr);

        // padding (u8)
        buf[39] = 0;

        try self.file.writeAll(&buf);
    }
};
