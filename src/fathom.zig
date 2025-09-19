// fathom.zig
const std = @import("std");
const bb = @import("bitboard.zig");
const position = @import("position.zig");
const att = @import("attacks.zig");
const uci = @import("uci.zig");

const fathom = @cImport({
    @cInclude("tbprobe.h");
});

const printout = uci.printout;

pub const TB_BLESSED_LOSS = fathom.TB_BLESSED_LOSS;
pub const TB_LOSS = fathom.TB_LOSS;
pub const TB_DRAW = fathom.TB_DRAW;
pub const TB_CURSED_WIN = fathom.TB_CURSED_WIN;
pub const TB_WIN = fathom.TB_WIN;
pub const TB_RESULT_FAILED = fathom.TB_RESULT_FAILED;
pub const TB_RESULT_CHECKMATE = fathom.TB_RESULT_CHECKMATE;
pub const TB_RESULT_STALEMATE = fathom.TB_RESULT_STALEMATE;

const Square = position.Square;
const Color = position.Color;
const Position = position.Position;

pub const Move = c_uint; // Fathom's move type (unsigned int)

var tb_path: ?[]const u8 = null;
pub var tb_probe_depth: i8 = 1;
var tb_initialized: bool = false;

// pub fn init_tablebases(allocator: std.mem.Allocator, path: ?[]const u8) !void {
//     if (path) |p| {
//         tb_path = try allocator.dupe(u8, p);
//         //const null_terminated_path = try std.fmt.allocPrintZ(allocator, "{s}", .{p});
//         const null_terminated_path = try allocator.dupeZ(u8, p[0..p.len]);

//         defer allocator.free(null_terminated_path);

//         const success = fathom.tb_init(null_terminated_path.ptr);

//         if (success) {
//             tb_initialized = true;
//             std.debug.print(
//                 "info string fathom initialized. Largest TB: {} pieces\n",
//                 .{
//                     fathom.TB_LARGEST,
//                 },
//             ); // !!!!
//         } else {
//             std.debug.print("info string fathom tb_init failed for path: {s}\n", .{p});
//             tb_initialized = false;
//         }
//     } else {
//         std.debug.print("info string No tablebase path provided. Fathom not initialized.\n", .{});
//         tb_initialized = false;
//     }
// }

pub fn init_tablebases(allocator: std.mem.Allocator, path: ?[]const u8) !void {
    if (path) |p| {
        tb_path = try allocator.dupe(u8, p);
        const null_terminated_path = try allocator.dupeZ(u8, p[0..p.len]);
        defer allocator.free(null_terminated_path);

        // Verify directory exists
        std.fs.accessAbsolute(p, .{}) catch |err| {
            try printout(uci.stdout, "info string Failed to access tablebase directory: {s}, error: {}\n", .{ p, err });
            tb_initialized = false;
            return;
        };

        const success = fathom.tb_init(null_terminated_path.ptr);
        if (success) {
            tb_initialized = true;
            try printout(uci.stdout, "info string fathom initialized. Largest TB: {} pieces\n", .{fathom.TB_LARGEST});
        } else {
            try printout(uci.stdout, "info string fathom tb_init failed for path: {s}\n", .{p});
            tb_initialized = false;
        }
    } else {
        //try printout(uci.stdout, "info string No tablebase path provided. Fathom not initialized.\n", .{});
        tb_initialized = false;
    }
}

pub fn free_tablebases() void {
    fathom.tb_free();
    tb_initialized = false;
}

pub fn get_tb_largest() usize {
    return @intCast(fathom.TB_LARGEST);
}

/// Probe the WDL (Win/Draw/Loss) tablebase for the current position.
pub fn probeWDL(curr_pos: *Position, depth: i8) c_uint {
    if (!tb_initialized) {
        return fathom.TB_RESULT_FAILED;
    }

    const has_castling_rights: bool = (curr_pos.history[curr_pos.game_ply].castling > 0);
    const just_zeroed: bool = (curr_pos.history[curr_pos.game_ply].fifty == 0);

    if (has_castling_rights or !just_zeroed) {
        return fathom.TB_RESULT_FAILED;
    }

    // Extract individual piece bitboards for White and Black
    const white_kings = curr_pos.bitboard_of_pt(Color.White, position.PieceType.King);
    const white_queens = curr_pos.bitboard_of_pt(Color.White, position.PieceType.Queen);
    const white_rooks = curr_pos.bitboard_of_pt(Color.White, position.PieceType.Rook);
    const white_bishops = curr_pos.bitboard_of_pt(Color.White, position.PieceType.Bishop);
    const white_knights = curr_pos.bitboard_of_pt(Color.White, position.PieceType.Knight);
    const white_pawns = curr_pos.bitboard_of_pt(Color.White, position.PieceType.Pawn);

    const black_kings = curr_pos.bitboard_of_pt(Color.Black, position.PieceType.King);
    const black_queens = curr_pos.bitboard_of_pt(Color.Black, position.PieceType.Queen);
    const black_rooks = curr_pos.bitboard_of_pt(Color.Black, position.PieceType.Rook);
    const black_bishops = curr_pos.bitboard_of_pt(Color.Black, position.PieceType.Bishop);
    const black_knights = curr_pos.bitboard_of_pt(Color.Black, position.PieceType.Knight);
    const black_pawns = curr_pos.bitboard_of_pt(Color.Black, position.PieceType.Pawn);

    const white = white_kings | white_queens | white_rooks | white_bishops | white_knights | white_pawns;
    const black = black_kings | black_queens | black_rooks | black_bishops | black_knights | black_pawns;

    const total_pieces = bb.pop_count(white | black);
    if (total_pieces > fathom.TB_LARGEST) {
        return fathom.TB_RESULT_FAILED;
    }
    if ((depth <= tb_probe_depth) and (total_pieces == fathom.TB_LARGEST)) {
        //std.debug.print("info string probeWDL: depth {} <= tb_probe_depth {} and total_pieces {} == TB_LARGEST {}\n", .{ depth, tb_probe_depth, total_pieces, fathom.TB_LARGEST });
        return fathom.TB_RESULT_FAILED;
    }

    // Side to move: 0 for White, 1 for Black (fathom convention)
    const turn: bool = (curr_pos.side_to_play == Color.White);
    // En passant square: 0 if none, otherwise the square index (0-63)
    const epsq = curr_pos.history[curr_pos.game_ply].epsq;
    const ep: c_uint = if (epsq != position.Square.NO_SQUARE) @intCast(epsq.toU6()) else 0;
    //const rule50: c_uint = @intCast(curr_pos.history[curr_pos.game_ply].fifty);

    const result = fathom.tb_probe_wdl(
        white,
        black,
        white_kings | black_kings,
        white_queens | black_queens,
        white_rooks | black_rooks,
        white_bishops | black_bishops,
        white_knights | black_knights,
        white_pawns | black_pawns,
        0,
        0,
        ep,
        turn,
    );

    if (result == fathom.TB_RESULT_FAILED) {
        return fathom.TB_RESULT_FAILED;
    }

    return @intCast(result);
}

// Probe the root position for the best move (DTZ-based).
pub fn probeRoot(curr_pos: *Position, results: []Move, depth: i8) struct { result: c_uint, move_count: u32 } {
    if (!tb_initialized) {
        return .{ .result = fathom.TB_RESULT_FAILED, .move_count = 0 };
    }

    const has_castling_rights: bool = (curr_pos.history[curr_pos.game_ply].castling > 0);
    const just_zeroed: bool = (curr_pos.history[curr_pos.game_ply].fifty == 0);

    if (has_castling_rights or !just_zeroed) {
        return .{ .result = fathom.TB_RESULT_FAILED, .move_count = 0 };
    }

    const white_kings = curr_pos.bitboard_of_pt(Color.White, position.PieceType.King);
    const white_queens = curr_pos.bitboard_of_pt(Color.White, position.PieceType.Queen);
    const white_rooks = curr_pos.bitboard_of_pt(Color.White, position.PieceType.Rook);
    const white_bishops = curr_pos.bitboard_of_pt(Color.White, position.PieceType.Bishop);
    const white_knights = curr_pos.bitboard_of_pt(Color.White, position.PieceType.Knight);
    const white_pawns = curr_pos.bitboard_of_pt(Color.White, position.PieceType.Pawn);

    const black_kings = curr_pos.bitboard_of_pt(Color.Black, position.PieceType.King);
    const black_queens = curr_pos.bitboard_of_pt(Color.Black, position.PieceType.Queen);
    const black_rooks = curr_pos.bitboard_of_pt(Color.Black, position.PieceType.Rook);
    const black_bishops = curr_pos.bitboard_of_pt(Color.Black, position.PieceType.Bishop);
    const black_knights = curr_pos.bitboard_of_pt(Color.Black, position.PieceType.Knight);
    const black_pawns = curr_pos.bitboard_of_pt(Color.Black, position.PieceType.Pawn);

    const white = white_kings | white_queens | white_rooks | white_bishops | white_knights | white_pawns;
    const black = black_kings | black_queens | black_rooks | black_bishops | black_knights | black_pawns;

    const total_pieces = bb.pop_count(white | black);
    if (total_pieces > fathom.TB_LARGEST) {
        return .{ .result = fathom.TB_RESULT_FAILED, .move_count = 0 };
    }
    if ((depth <= tb_probe_depth) and (total_pieces == fathom.TB_LARGEST)) {
        //std.debug.print("info string probeRoot: depth {} <= tb_probe_depth {} and total_pieces {} == TB_LARGEST {}\n", .{ depth, tb_probe_depth, total_pieces, fathom.TB_LARGEST });
        return .{ .result = fathom.TB_RESULT_FAILED, .move_count = 0 };
    }

    const turn: bool = (curr_pos.side_to_play == Color.White);
    const epsq = curr_pos.history[curr_pos.game_ply].epsq;
    const ep: c_uint = if (epsq != position.Square.NO_SQUARE) @intCast(epsq.toU6()) else 0;

    // Temporary array to capture raw results from tb_probe_root
    var raw_results: [64]c_uint = undefined;
    const result = fathom.tb_probe_root(
        white,
        black,
        white_kings | black_kings,
        white_queens | black_queens,
        white_rooks | black_rooks,
        white_bishops | black_bishops,
        white_knights | black_knights,
        white_pawns | black_pawns,
        0, // rule50
        0, // castling (handled by check above)
        ep,
        turn,
        &raw_results,
    );

    // Process raw_results to extract only move data (from, to, promo, ep)
    var move_count: u32 = 0;
    for (raw_results[0..@min(results.len, 64)], 0..) |raw_move, i| {
        if (raw_move == fathom.TB_RESULT_FAILED) break;
        const cand_from = getFrom(raw_move);
        const cand_to = getTo(raw_move);
        const cand_promo = getPromotes(raw_move);
        const cand_ep = getEP(raw_move);
        if (cand_from > 63 or cand_to > 63 or cand_promo > fathom.TB_PROMOTES_KNIGHT) break;
        // Reconstruct move in the same format as dtz_result
        var move: c_uint = @as(c_uint, cand_from) | (@as(c_uint, cand_to) << 6) | (@as(c_uint, cand_promo) << 12);
        if (cand_ep != 0) {
            move |= @as(c_uint, 1) << 19;
        }
        results[i] = move;
        move_count = @intCast(i + 1);
    }

    return .{ .result = result, .move_count = move_count };
}

// /// Probe the root position for the best move (DTZ-based).
// pub fn probeRoot(curr_pos: *Position, results: []Move, depth: i8) c_uint {
//     if (!tb_initialized) {
//         return fathom.TB_RESULT_FAILED;
//     }

//     const has_castling_rights: bool = (curr_pos.history[curr_pos.game_ply].castling > 0);
//     const just_zeroed: bool = (curr_pos.history[curr_pos.game_ply].fifty == 0);

//     if (has_castling_rights or !just_zeroed) {
//         return fathom.TB_RESULT_FAILED;
//     }

//     const white_kings = curr_pos.bitboard_of_pt(Color.White, position.PieceType.King);
//     const white_queens = curr_pos.bitboard_of_pt(Color.White, position.PieceType.Queen);
//     const white_rooks = curr_pos.bitboard_of_pt(Color.White, position.PieceType.Rook);
//     const white_bishops = curr_pos.bitboard_of_pt(Color.White, position.PieceType.Bishop);
//     const white_knights = curr_pos.bitboard_of_pt(Color.White, position.PieceType.Knight);
//     const white_pawns = curr_pos.bitboard_of_pt(Color.White, position.PieceType.Pawn);

//     const black_kings = curr_pos.bitboard_of_pt(Color.Black, position.PieceType.King);
//     const black_queens = curr_pos.bitboard_of_pt(Color.Black, position.PieceType.Queen);
//     const black_rooks = curr_pos.bitboard_of_pt(Color.Black, position.PieceType.Rook);
//     const black_bishops = curr_pos.bitboard_of_pt(Color.Black, position.PieceType.Bishop);
//     const black_knights = curr_pos.bitboard_of_pt(Color.Black, position.PieceType.Knight);
//     const black_pawns = curr_pos.bitboard_of_pt(Color.Black, position.PieceType.Pawn);

//     const white = white_kings | white_queens | white_rooks | white_bishops | white_knights | white_pawns;
//     const black = black_kings | black_queens | black_rooks | black_bishops | black_knights | black_pawns;

//     const total_pieces = bb.pop_count(white | black);
//     if (total_pieces > fathom.TB_LARGEST) {
//         return fathom.TB_RESULT_FAILED;
//     }
//     if ((depth <= tb_probe_depth) and (total_pieces == fathom.TB_LARGEST)) {
//         std.debug.print("info string probeRoot: depth {} <= tb_probe_depth {} and total_pieces {} == TB_LARGEST {}\n", .{ depth, tb_probe_depth, total_pieces, fathom.TB_LARGEST });
//         return fathom.TB_RESULT_FAILED;
//     }

//     const turn: bool = (curr_pos.side_to_play == Color.White);
//     const epsq = curr_pos.history[curr_pos.game_ply].epsq;
//     const ep: c_uint = if (epsq != position.Square.NO_SQUARE) @intCast(epsq.toU6()) else 0;

//     const result = fathom.tb_probe_root(
//         white,
//         black,
//         white_kings | black_kings,
//         white_queens | black_queens,
//         white_rooks | black_rooks,
//         white_bishops | black_bishops,
//         white_knights | black_knights,
//         white_pawns | black_pawns,
//         0, // rule50
//         0, // castling (handled by check above)
//         ep,
//         turn,
//         results.ptr,
//     );

//     return result;
// }

/// Convert a Fathom Move (unsigned int) to UCI notation (e.g., "e2e4" or "d7d8q").
pub fn moveToUCI(move: Move, allocator: std.mem.Allocator) ![]u8 {
    const from_sq = @as(u32, move & 0x3F); // Bits 0-5
    const to_sq = @as(u32, (move >> 6) & 0x3F); // Bits 6-11
    const promo = (move >> 12) & 0x7; // Bits 12-14

    const from_str = [_]u8{ file_char(from_sq), rank_char(from_sq) };
    const to_str = [_]u8{ file_char(to_sq), rank_char(to_sq) };

    if (promo == fathom.TB_PROMOTES_NONE) {
        return try std.mem.join(allocator, "", &[_][]const u8{ from_str[0..], to_str[0..] });
    } else {
        const promo_chars = [_]u8{ 0, 'q', 'r', 'b', 'n' }; // 1=queen, 2=rook, 3=bishop, 4=knight
        const promo_char = promo_chars[promo];
        return try std.mem.join(allocator, "", &[_][]const u8{ from_str[0..], to_str[0..], &[_]u8{promo_char} });
    }
}

fn file_char(sq: u32) u8 {
    return @as(u8, 'a' + @as(u8, @intCast(sq % 8)));
}
fn rank_char(sq: u32) u8 {
    return @as(u8, '1' + @as(u8, @intCast(sq / 8)));
}

pub fn getWDL(res: c_uint) u32 {
    return (res & fathom.TB_RESULT_WDL_MASK) >> fathom.TB_RESULT_WDL_SHIFT;
}

pub fn getDTZ(res: c_uint) u32 {
    return (res & fathom.TB_RESULT_DTZ_MASK) >> fathom.TB_RESULT_DTZ_SHIFT;
}

pub fn getFrom(res: c_uint) u32 {
    return (res & fathom.TB_RESULT_FROM_MASK) >> fathom.TB_RESULT_FROM_SHIFT;
}

pub fn getTo(res: c_uint) u32 {
    return (res & fathom.TB_RESULT_TO_MASK) >> fathom.TB_RESULT_TO_SHIFT;
}

pub fn getPromotes(res: c_uint) u32 {
    return (res & fathom.TB_RESULT_PROMOTES_MASK) >> fathom.TB_RESULT_PROMOTES_SHIFT;
}

pub fn getEP(res: c_uint) u32 {
    return (res & fathom.TB_RESULT_EP_MASK) >> fathom.TB_RESULT_EP_SHIFT;
}
