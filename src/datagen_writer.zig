const std = @import("std");
const position = @import("position.zig");

const Position = position.Position;
const Move = position.Move;
const Piece = position.Piece;

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

    pub fn open(path: []const u8) !Bin40Writer {
        const f = try std.fs.cwd().createFile(path, .{ .read = false, .truncate = true });
        return .{ .file = f };
    }

    pub fn close(self: *Bin40Writer) void {
        self.file.close();
    }

    fn encode_piece_nibble(pc: Piece) u4 {
        // Use engine's internal 4-bit piece code directly (fits in 0..14),
        // leave 15 unused.
        return @as(u4, pc.toU4());
    }

    fn encode_move16(mv: Move) u16 {
        // Stockfish move encoding expects: to in low 6, from in next 6, promo in high 4.
        // promo: 0 none, 1=N, 2=B, 3=R, 4=Q
        var code: u16 = 0;
        code |= @as(u16, mv.to & 0x3F);
        code |= (@as(u16, mv.from & 0x3F)) << 6;
        var promo: u16 = 0;
        if (mv.is_promotion()) {
            const pt = mv.flags.promote_type();
            promo = switch (pt) {
                .Knight => 1,
                .Bishop => 2,
                .Rook => 3,
                .Queen => 4,
                else => 0,
            };
        }
        code |= (promo & 0xF) << 12;
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
        var buf: [40]u8 = [_]u8{0} ** 40;

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
        const m16 = encode_move16(bm);
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
