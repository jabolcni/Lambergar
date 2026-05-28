const std = @import("std");
const position = @import("position.zig");
const binw = @import("datagen_writer.zig");
const tuner = @import("tuner.zig");
const attacks = @import("attacks.zig");
const zobrist = @import("zobrist.zig");
const MoveList = @import("lists.zig").MoveList;

const Position = position.Position;
const Move = position.Move;
const Color = position.Color;
const MoveFlags = position.MoveFlags;
const U6 = std.meta.Int(.unsigned, 6);
const Square = position.Square;
const Piece = position.Piece;
const PieceType = position.PieceType;
const Rank = position.Rank;
const AutoHashMap = std.AutoHashMap;

const BinEntry = struct {
    sfen32: [32]u8,
    move16: u16,
    ply: u16,
    score_cp: i32,
    stm_white: bool,
    game_result: i8,
};

fn move16_to_uci(code: u16, pos: *Position, buf: *[5]u8) []const u8 {
    const to_sq: U6 = @truncate(code & 0x3F);
    const from_sq: U6 = @truncate((code >> 6) & 0x3F);
    const promo: u16 = (code >> 12) & 0x3;
    const flags: u16 = (code >> 14) & 0x3;

    buf.* = [_]u8{0} ** 5;
    @memcpy(buf[0..2], position.sq_to_coord[from_sq]);
    @memcpy(buf[2..4], position.sq_to_coord[to_sq]);

    if (flags == 3) {
        // Castling: for classical output king-from -> target; for 960, emit king-from -> rook-from.
        const kingside = (to_sq & 7) > (from_sq & 7);
        if (pos.is_chess960) {
            const ci = pos.side_to_play.toU4();
            const rook_sq = if (kingside) pos.castle_rook_k_start[ci] else pos.castle_rook_q_start[ci];
            if (rook_sq != Square.NO_SQUARE) {
                @memcpy(buf[2..4], position.sq_to_coord[rook_sq.toU6()]);
            }
            return buf[0..4];
        } else {
            const king_target: Square = blk: {
                if (pos.side_to_play == Color.White) {
                    break :blk if (kingside) Square.g1 else Square.c1;
                } else {
                    break :blk if (kingside) Square.g8 else Square.c8;
                }
            };
            @memcpy(buf[2..4], position.sq_to_coord[king_target.toU6()]);
            return buf[0..4];
        }
    }

    if (flags == 1) {
        // Promotion: 0=N,1=B,2=R,3=Q
        var pc: u8 = 'q';
        switch (promo) {
            0 => pc = 'n',
            1 => pc = 'b',
            2 => pc = 'r',
            else => pc = 'q',
        }
        buf[4] = pc;
        return buf[0..5];
    }
    return buf[0..4];
}

fn move_to_csv_uci(mv: Move, pos: *Position, buf: *[5]u8) []const u8 {
    buf.* = [_]u8{0} ** 5;

    // For Chess960, emit king-from -> rook-from for castling so downstream tools
    // can disambiguate (matches move16 encoding / UCI-960 convention).
    if (pos.is_chess960 and (mv.flags == MoveFlags.OO or mv.flags == MoveFlags.OOO)) {
        const ci = pos.side_to_play.toU4();
        const rook_sq = if (mv.flags == MoveFlags.OO) pos.castle_rook_k_start[ci] else pos.castle_rook_q_start[ci];
        if (rook_sq != Square.NO_SQUARE) {
            @memcpy(buf[0..2], position.sq_to_coord[mv.from]);
            @memcpy(buf[2..4], position.sq_to_coord[rook_sq.toU6()]);
            return buf[0..4];
        }
    }

    @memcpy(buf[0..2], position.sq_to_coord[mv.from]);
    @memcpy(buf[2..4], position.sq_to_coord[mv.to]);
    if (mv.is_promotion()) {
        buf[4] = position.PROM_TYPESTR[mv.flags.toU4()][0];
        return buf[0..5];
    }
    return buf[0..4];
}

fn decode_move(code: u16, pos: *Position) !Move {
    var uci_buf: [5]u8 = undefined;
    const uci = move16_to_uci(code, pos, &uci_buf);
    return Move.parse_move(uci, pos);
}

fn infer_castling_from_board(pos: *Position) void {
    // Derive king/rook start squares per color and mark 960 mode when non-classical.
    inline for (.{ Color.White, Color.Black }, 0..) |c, ci| {
        const king_pc = Piece.make_piece(c, PieceType.King);
        const rook_pc = Piece.make_piece(c, PieceType.Rook);
        var king_sq: Square = Square.NO_SQUARE;
        // locate king
        for (0..64) |idx| {
            if (pos.board[idx] == king_pc) {
                king_sq = Square.fromU6(@intCast(idx));
                break;
            }
        }
        pos.castle_king_start[ci] = king_sq;

        // locate rooks on back rank
        const back_rank: u6 = if (c == .White) Rank.RANK1.toU3() else Rank.RANK8.toU3();
        var rook_right: Square = Square.NO_SQUARE;
        var rook_left: Square = Square.NO_SQUARE;
        // scan to the right of king for first rook on the same rank
        if (king_sq != Square.NO_SQUARE) {
            const kfile: u6 = king_sq.file_of().toU3();
            const base: u6 = back_rank * 8;
            var f: u6 = kfile + 1;
            while (f < 8) : (f += 1) {
                const sq: u6 = base + f;
                if (pos.board[sq] == rook_pc) {
                    rook_right = Square.fromU6(sq);
                    break;
                }
            }
            var fi: i32 = @as(i32, kfile) - 1;
            while (fi >= 0) : (fi -= 1) {
                const f2: u6 = @intCast(fi);
                const sq2: u6 = base + f2;
                if (pos.board[sq2] == rook_pc) {
                    rook_left = Square.fromU6(sq2);
                    break;
                }
            }
        }
        pos.castle_rook_k_start[ci] = rook_right;
        pos.castle_rook_q_start[ci] = rook_left;

        const classical = if (c == Color.White)
            (king_sq == Square.e1 and rook_right == Square.h1 and rook_left == Square.a1)
        else
            (king_sq == Square.e8 and rook_right == Square.h8 and rook_left == Square.a8);
        pos.classical_variant[ci] = classical;
    }

    pos.is_chess960 = !(pos.classical_variant[0] and pos.classical_variant[1]);

    // Rebuild castle-rights clear table
    pos.castle_rights_clear_by_sq = @splat(0);
    if (pos.castle_king_start[Color.White.toU4()] != Square.NO_SQUARE) {
        const ks = pos.castle_king_start[Color.White.toU4()].toU6();
        pos.castle_rights_clear_by_sq[ks] |= (position.Castling.WK.toU4() | position.Castling.WQ.toU4());
    }
    if (pos.castle_rook_k_start[Color.White.toU4()] != Square.NO_SQUARE) {
        const rs = pos.castle_rook_k_start[Color.White.toU4()].toU6();
        pos.castle_rights_clear_by_sq[rs] |= position.Castling.WK.toU4();
    }
    if (pos.castle_rook_q_start[Color.White.toU4()] != Square.NO_SQUARE) {
        const rs = pos.castle_rook_q_start[Color.White.toU4()].toU6();
        pos.castle_rights_clear_by_sq[rs] |= position.Castling.WQ.toU4();
    }
    if (pos.castle_king_start[Color.Black.toU4()] != Square.NO_SQUARE) {
        const ks = pos.castle_king_start[Color.Black.toU4()].toU6();
        pos.castle_rights_clear_by_sq[ks] |= (position.Castling.BK.toU4() | position.Castling.BQ.toU4());
    }
    if (pos.castle_rook_k_start[Color.Black.toU4()] != Square.NO_SQUARE) {
        const rs = pos.castle_rook_k_start[Color.Black.toU4()].toU6();
        pos.castle_rights_clear_by_sq[rs] |= position.Castling.BK.toU4();
    }
    if (pos.castle_rook_q_start[Color.Black.toU4()] != Square.NO_SQUARE) {
        const rs = pos.castle_rook_q_start[Color.Black.toU4()].toU6();
        pos.castle_rights_clear_by_sq[rs] |= position.Castling.BQ.toU4();
    }
}

const BIN40_SIZE = 40;
const BINHCE_FEATURE_BYTES = blk: {
    const dummy = tuner.Tuner{};
    break :blk @sizeOf(@TypeOf(dummy.mat)) +
        @sizeOf(@TypeOf(dummy.psqt)) +
        @sizeOf(@TypeOf(dummy.passed_pawn)) +
        @sizeOf(@TypeOf(dummy.isolated_pawn)) +
        @sizeOf(@TypeOf(dummy.blocked_passer)) +
        @sizeOf(@TypeOf(dummy.supported_pawn)) +
        @sizeOf(@TypeOf(dummy.pawn_phalanx)) +
        @sizeOf(@TypeOf(dummy.knight_mobility)) +
        @sizeOf(@TypeOf(dummy.bishop_mobility)) +
        @sizeOf(@TypeOf(dummy.rook_mobility)) +
        @sizeOf(@TypeOf(dummy.queen_mobility)) +
        @sizeOf(@TypeOf(dummy.pawn_attacking)) +
        @sizeOf(@TypeOf(dummy.knight_attacking)) +
        @sizeOf(@TypeOf(dummy.bishop_attacking)) +
        @sizeOf(@TypeOf(dummy.rook_attacking)) +
        @sizeOf(@TypeOf(dummy.queen_attacking)) +
        @sizeOf(@TypeOf(dummy.doubled_pawns)) +
        @sizeOf(@TypeOf(dummy.bishop_pair));
};
const BINHCE_SIZE = BIN40_SIZE + BINHCE_FEATURE_BYTES;

fn read_records(io: std.Io, allocator: std.mem.Allocator, path: []const u8, force_binhce: bool) !std.ArrayListUnmanaged(BinEntry) {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const total_size = (try file.stat(io)).size;
    var rec_size: u64 = BIN40_SIZE;
    if (force_binhce) {
        if (total_size % BINHCE_SIZE != 0) return error.UnexpectedRecordSize;
        rec_size = BINHCE_SIZE;
    } else if (total_size % BIN40_SIZE == 0 and total_size % BINHCE_SIZE != 0) {
        rec_size = BIN40_SIZE;
    } else if (total_size % BINHCE_SIZE == 0 and total_size % BIN40_SIZE != 0) {
        rec_size = BINHCE_SIZE;
    } else if (total_size % BIN40_SIZE == 0 and total_size % BINHCE_SIZE == 0) {
        // Ambiguous: default to BIN40 unless user forces binhce
        rec_size = BIN40_SIZE;
    } else {
        return error.UnexpectedRecordSize;
    }
    if (total_size % rec_size != 0) return error.UnexpectedRecordSize;

    var entries = std.ArrayListUnmanaged(BinEntry){};
    var offset: u64 = 0;
    while (offset < total_size) {
        var buf: [BIN40_SIZE]u8 = undefined;
        var reader = file.reader(io, &.{});
        const n = try reader.interface.readSliceShort(&buf);
        if (n == 0) break;
        if (n != BIN40_SIZE) return error.PartialRecord;

        var sfen: [32]u8 = undefined;
        @memcpy(&sfen, buf[0..32]);
        const score_cp: i16 = @bitCast(@as(u16, buf[32] | (@as(u16, buf[33]) << 8)));
        const move16 = @as(u16, buf[34]) | (@as(u16, buf[35]) << 8);
        const ply = @as(u16, buf[36]) | (@as(u16, buf[37]) << 8);
        const gr: i8 = @bitCast(buf[38]);
        const stm_white: bool = (gr >= 0); // preserved for completeness

        try entries.append(allocator, .{
            .sfen32 = sfen,
            .move16 = move16,
            .ply = ply,
            .score_cp = score_cp,
            .stm_white = stm_white,
            .game_result = gr,
        });

        if (rec_size > BIN40_SIZE) {
            const skip: u64 = rec_size - BIN40_SIZE;
            try file.seekBy(@as(i64, @intCast(skip)));
        }
        offset += rec_size;
    }

    return entries;
}

fn sfen_equal(a: *const [32]u8, b: *const [32]u8) bool {
    return std.mem.eql(u8, a[0..], b[0..]);
}

fn default_io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn writeFmt(out: *std.Io.File, comptime fmt: []const u8, args: anytype) !void {
    var buf: [512]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, fmt, args);
    var writer = out.writer(default_io(), &.{});
    try writer.interface.writeAll(s);
    try writer.interface.flush();
}

fn write_csv_header(out: *std.Io.File) !void {
    try writeFmt(out, "game,record,ply,stm,chess960,fen,move16_hex,uci,score_cp,result,decode_ok,legal_ok,next_ok,notes\n", .{});
}

fn write_csv_row(out: *std.Io.File, game_idx: usize, rec_idx: usize, ply: u16, stm: Color, chess960: bool, fen: []const u8, move_hex: u16, uci: []const u8, score: i32, result: i8, decode_ok: bool, legal_ok: bool, next_ok: ?bool, notes: []const u8) !void {
    const stm_ch: u8 = if (stm == Color.White) 'w' else 'b';
    const res_str: []const u8 = if (result > 0) "1-0" else if (result < 0) "0-1" else "1/2-1/2";
    const next_str: []const u8 = if (next_ok) |b| (if (b) "yes" else "no") else "n/a";
    try writeFmt(out, "{d},{d},{d},{c},{s},\"{s}\",0x{X:0>4},{s},{d},{s},{s},{s},{s},{s}\n", .{
        game_idx,
        rec_idx,
        ply,
        stm_ch,
        if (chess960) "true" else "false",
        fen,
        move_hex,
        uci,
        score,
        res_str,
        if (decode_ok) "yes" else "no",
        if (legal_ok) "yes" else "no",
        next_str,
        notes,
    });
}

pub fn main(init: std.process.Init) !void {
    attacks.initialise_all_databases();
    zobrist.initialise_zobrist_keys();

    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        std.debug.print("usage: zig run src/datagen_validate.zig -- <bin file> [--csv out.csv] [--binhce]\n", .{});
        return;
    }

    const bin_path = args[1];
    var csv_path: []const u8 = "validation.csv";
    var force_binhce = false;
    var i: usize = 2;
    while (i < args.len) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--csv") and i + 1 < args.len) {
            csv_path = args[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, a, "--binhce")) {
            force_binhce = true;
            i += 1;
        } else {
            break;
        }
    }

    var entries = try read_records(io, allocator, bin_path, force_binhce);
    defer entries.deinit(allocator);
    if (entries.items.len == 0) {
        std.debug.print("no records found in {s}\n", .{bin_path});
        return;
    }

    var csv = try std.Io.Dir.cwd().createFile(io, csv_path, .{ .truncate = true });
    defer csv.close(io);
    try write_csv_header(&csv);

    var games: usize = 0;
    var idx_entries: usize = 0;
    var total_decode_fails: usize = 0;
    var total_legal_fails: usize = 0;
    var total_next_mismatch: usize = 0;
    var total_rt_sfen_mismatch: usize = 0;
    var total_repeat_hits: usize = 0;
    var total_result_issues: usize = 0;

    const GameStat = struct {
        game: usize,
        decode: usize = 0,
        legal: usize = 0,
        next: usize = 0,
        rt: usize = 0,
        repeats: usize = 0,
        result: usize = 0,
    };
    var game_stats = std.ArrayListUnmanaged(GameStat){};
    defer game_stats.deinit(allocator);

    while (idx_entries < entries.items.len) {
        games += 1;
        try game_stats.append(allocator, .{ .game = games });
        const gs = &game_stats.items[game_stats.items.len - 1];
        const start_idx = idx_entries;
        var pos = Position.new();
        binw.unpack_sfen32(&entries.items[start_idx].sfen32, &pos);
        infer_castling_from_board(&pos);
        var seen_sfen = AutoHashMap([32]u8, u32).init(allocator);
        defer seen_sfen.deinit();

        while (idx_entries < entries.items.len) : (idx_entries += 1) {
            const curr = entries.items[idx_entries];
            const has_next = (idx_entries + 1 < entries.items.len) and (entries.items[idx_entries + 1].ply > curr.ply);

            const stm_before = pos.side_to_play;
            var decode_ok = true;
            var legal_ok = true;
            var next_ok: ?bool = null;
            var notes = std.ArrayListUnmanaged(u8).empty;
            defer notes.deinit(allocator);

            var mv = Move{
                .from = 0,
                .to = 0,
                .flags = position.MoveFlags.QUIET,
            };
            const fen_opt = pos.get_fen(allocator) catch null;
            defer if (fen_opt) |f| allocator.free(f);
            const fen_slice = fen_opt orelse "<fen error>";

            // Round-trip SFEN check: pack current pos and compare to stored sfen.
            var rt_sfen: [32]u8 = undefined;
            binw.pack_sfen32(&pos, &rt_sfen);
            if (!sfen_equal(&rt_sfen, &curr.sfen32)) {
                if (notes.items.len > 0) try notes.append(allocator, ';');
                try notes.appendSlice(allocator, "rt_sfen_mismatch");
                total_rt_sfen_mismatch += 1;
                gs.rt += 1;
            }

            // Duplicate / repetition detection.
            const gp = try seen_sfen.getOrPut(curr.sfen32);
            if (!gp.found_existing) {
                gp.value_ptr.* = 1;
            } else {
                gp.value_ptr.* += 1;
                const new_count = gp.value_ptr.*;
                if (notes.items.len > 0) try notes.append(allocator, ';');
                try notes.appendSlice(allocator, if (new_count >= 3) "threefold_or_more" else "repeat");
                total_repeat_hits += 1;
                gs.repeats += 1;
            }
            const decoded = decode_move(curr.move16, &pos);
            if (decoded) |m| {
                mv = m;
            } else |_| {
                decode_ok = false;
                try notes.appendSlice(allocator, "decode_fail");
                total_decode_fails += 1;
                gs.decode += 1;
            }

            if (decode_ok) {
                const from_sq = mv.from;
                const pc = pos.board[from_sq];
                if (pc == Piece.NO_PIECE or pc.color() != pos.side_to_play) {
                    legal_ok = false;
                    try notes.appendSlice(allocator, "from_empty_or_wrong_color");
                    total_legal_fails += 1;
                    gs.legal += 1;
                } else {
                    var ml: MoveList = .{};
                    if (pos.side_to_play == Color.White) pos.generate_legals(Color.White, &ml) else pos.generate_legals(Color.Black, &ml);
                    var found = false;
                    var idx: usize = 0;
                    while (idx < ml.count) : (idx += 1) {
                        if (ml.moves[idx].from == mv.from and ml.moves[idx].to == mv.to and ml.moves[idx].flags == mv.flags) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        legal_ok = false;
                        if (notes.items.len > 0) try notes.append(allocator, ';');
                        try notes.appendSlice(allocator, "not_in_legals");
                        total_legal_fails += 1;
                        gs.legal += 1;
                    }
                }
            }

            var uci_buf: [5]u8 = undefined;
            const uci_slice = if (decode_ok) blk: {
                break :blk move_to_csv_uci(mv, &pos, &uci_buf);
            } else blk: {
                const s = move16_to_uci(curr.move16, &pos, &uci_buf);
                break :blk s;
            };

            if (decode_ok and legal_ok and has_next) {
                if (pos.side_to_play == Color.White) pos.play(mv, Color.White) else pos.play(mv, Color.Black);
                var check_sfen: [32]u8 = undefined;
                binw.pack_sfen32(&pos, &check_sfen);
                const next_sfen = &entries.items[idx_entries + 1].sfen32;
                const match_next = sfen_equal(&check_sfen, next_sfen);
                next_ok = match_next;
                if (!match_next) {
                    if (notes.items.len > 0) try notes.append(allocator, ';');
                    try notes.appendSlice(allocator, "next_sfen_mismatch");
                    total_next_mismatch += 1;
                    gs.next += 1;
                }
            } else if (decode_ok and legal_ok) {
                // still advance position even if no next? necessary for summary but fine
                if (pos.side_to_play == Color.White) pos.play(mv, Color.White) else pos.play(mv, Color.Black);
            }

            // If this is the last record of the game, check result consistency.
            if (!has_next) {
                var end_list: MoveList = .{};
                if (pos.side_to_play == Color.White) pos.generate_legals(Color.White, &end_list) else pos.generate_legals(Color.Black, &end_list);
                const no_moves = end_list.count == 0;
                const in_check = if (pos.side_to_play == Color.White) pos.in_check(Color.White) else pos.in_check(Color.Black);
                var observed: i8 = 2; // 2 = ongoing/unknown
                if (no_moves and in_check) {
                    observed = if (pos.side_to_play == Color.White) -1 else 1;
                } else if (no_moves) {
                    observed = 0;
                }
                if (observed != 2) {
                    const expected: i8 = blk: {
                        if (curr.game_result == 0) break :blk 0;
                        // Result is stored from the perspective of the side to move in the record:
                        // >0 means side-to-move wins, <0 means side-to-move loses.
                        if (curr.game_result > 0) {
                            break :blk if (stm_before == Color.White) 1 else -1;
                        } else {
                            break :blk if (stm_before == Color.White) -1 else 1;
                        }
                    };
                    if (observed != expected) {
                        if (notes.items.len > 0) try notes.append(allocator, ';');
                        const obs_str = if (observed > 0) "1-0" else if (observed < 0) "0-1" else "1/2-1/2";
                        const exp_str = if (expected > 0) "1-0" else if (expected < 0) "0-1" else "1/2-1/2";
                        var buf: [48]u8 = undefined;
                        const msg = try std.fmt.bufPrint(&buf, "result_mismatch(obs={s},exp={s})", .{ obs_str, exp_str });
                        try notes.appendSlice(allocator, msg);
                        total_result_issues += 1;
                        gs.result += 1;
                    }
                }
            }

            const note_str: []const u8 = if (notes.items.len > 0) notes.items else "ok";
            try write_csv_row(
                &csv,
                games,
                idx_entries,
                curr.ply,
                stm_before,
                pos.is_chess960,
                fen_slice,
                curr.move16,
                uci_slice,
                curr.score_cp,
                curr.game_result,
                decode_ok,
                legal_ok,
                next_ok,
                note_str,
            );

            // New game boundary?
            if (!has_next) {
                idx_entries += 1;
                break;
            }
        }
    }

    const ok_records = entries.items.len - (total_decode_fails + total_legal_fails + total_next_mismatch);
    std.debug.print(
        "csv written: {s}\n  games: {d}\n  records: {d}\n  ok: {d}\n  decode_fails: {d}\n  legal_fails: {d}\n  next_mismatch: {d}\n  rt_sfen_mismatch: {d}\n  repeats: {d}\n  result_issues: {d}\n",
        .{
            csv_path,
            games,
            entries.items.len,
            ok_records,
            total_decode_fails,
            total_legal_fails,
            total_next_mismatch,
            total_rt_sfen_mismatch,
            total_repeat_hits,
            total_result_issues,
        },
    );

    if (game_stats.items.len > 0) {
        std.debug.print("problematic games:\n", .{});
        var any = false;
        for (game_stats.items) |gs| {
            if (gs.decode + gs.legal + gs.next + gs.rt + gs.repeats + gs.result == 0) continue;
            any = true;
            std.debug.print(
                "  game {d}: decode={d}, legal={d}, next={d}, rt_sfen={d}, repeats={d}, result={d}\n",
                .{ gs.game, gs.decode, gs.legal, gs.next, gs.rt, gs.repeats, gs.result },
            );
        }
        if (!any) std.debug.print("  (none)\n", .{});
    }
}
