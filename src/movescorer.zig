const std = @import("std");
const position = @import("position.zig");
const searcher = @import("search.zig");
const attacks = @import("attacks.zig");
const bb = @import("bitboard.zig");
const history = @import("history.zig");

const Move = position.Move;
const Position = position.Position;
const Piece = position.Piece;
const PieceType = position.PieceType;
const Color = position.Color;
const MoveFlags = position.MoveFlags;
const Search = searcher.Search;

pub const SortHash = 3_000_000;
pub const QueenPromotion = 71_000;
pub const KnightPromotion = 70_000;
pub const SortKiller1 = 69_001;
pub const SortKiller2 = 69_000;
pub const HistoryMax = 65_536;
pub const SortCapture = 2 * HistoryMax;
pub const sortCounter = 68_000;
pub const Badpromotion = -QueenPromotion;

// pawns, knights, bishops, rooks, queens, kings
const piece_val = [7]i32{ 100, 310, 330, 500, 1000, 20000, 0 };

// tale pristop k move scoringu se zdi boljši

pub inline fn score_move(pos: *Position, search: *Search, move_list: *std.ArrayList(Move), score_list: *std.ArrayList(i32), hash_move: Move, comptime color: Color) void {
    for (move_list.items) |move| {
        var score: i32 = 0;
        if (move.equal(hash_move)) {
            score = SortHash;
            //continue;
        } else if (move.is_promotion()) {
            switch (move.flags) {
                MoveFlags.PC_QUEEN => score = QueenPromotion,
                MoveFlags.PC_KNIGHT => score = KnightPromotion,
                else => score = Badpromotion,
            }
        } else if (move.is_capture()) {
            const captured = if (move.flags == MoveFlags.EN_PASSANT) 0 else pos.board[move.to].type_of().toU3();
            const capturer = pos.board[move.from].type_of().toU3();
            if (see(pos, move, 0)) {
                score = 8 * piece_val[captured] - piece_val[capturer] + SortCapture;
            } else {
                score = 8 * piece_val[captured] - piece_val[capturer];
            }
        } else {
            if (move.equal(search.mv_killer[search.ply][0])) {
                score = SortKiller1;
            } else if (move.equal(search.mv_killer[search.ply][1])) {
                score = SortKiller2;
            } else if (move.equal(history.get_counter_move(search))) {
                score = sortCounter;
            } else {
                comptime var side: u4 = if (color == Color.White) Color.White.toU4() else Color.Black.toU4();
                //var piece = pos.board[move.from];
                score = search.sc_history[side][move.from][move.to];
            }
        }

        score_list.append(score) catch unreachable;
    }
}

pub inline fn get_next_best(move_list: *std.ArrayList(Move), score_list: *std.ArrayList(i32), i: usize) Move {
    var best_j = i;
    var max_score = score_list.items[i];

    for (score_list.items[i + 1 ..], i + 1..) |score, j| {
        if (score > max_score) {
            best_j = j;
            max_score = score;
        }
    }

    if (best_j != i) {
        std.mem.swap(Move, &move_list.items[i], &move_list.items[best_j]);
        std.mem.swap(i32, &score_list.items[i], &score_list.items[best_j]);
    }
    return move_list.items[i];
}

pub inline fn see(pos: *Position, move: Move, thr: i32) bool {
    if (move.is_promotion()) {
        return true;
    }

    var from = move.from;
    var to = move.to;

    var target = pos.board[to];
    var value: i32 = piece_val[target.type_of().toU3()] - thr;

    if (value < 0) {
        return false;
    }

    var attacker = pos.board[from];

    value -= piece_val[attacker.type_of().toU3()];

    if (value >= 0) {
        return true;
    }

    //var occupied: u64 = (pos.all_pieces(Color.White) | pos.all_pieces(Color.Black)) ^ (@as(u64, 1) << from) ^ (@as(u64, 1) << to);
    var occupied: u64 = (pos.all_pieces(Color.White) | pos.all_pieces(Color.Black)) ^ bb.SQUARE_BB[from] ^ bb.SQUARE_BB[to];
    var attackers: u64 = pos.all_attackers(to, occupied);

    //var bishops: u6 = pos.piece_bb[Piece.WHITE_BISHOP.toU4()] | pos.piece_bb[Piece.WHITE_QUEEN.toU4()] | pos.piece_bb[Piece.BLACK_BISHOP.toU4()] | pos.piece_bb[Piece.BLACK_QUEEN.toU4()];
    var bishops: u64 = pos.diagonal_sliders(Color.White) | pos.diagonal_sliders(Color.Black);
    //var rooks: u6 = pos.piece_bb[Piece.WHITE_ROOK.toU4()] | pos.piece_bb[Piece.WHITE_QUEEN.toU4()] | pos.piece_bb[Piece.BLACK_ROOK.toU4()] | pos.piece_bb[Piece.BLACK_QUEEN.toU4()];
    var rooks: u64 = pos.orthogonal_sliders(Color.White) | pos.orthogonal_sliders(Color.Black);

    var side = attacker.color().change_side();

    while (true) {
        attackers &= occupied;

        var occ_side = if (side == Color.White) pos.all_pieces(Color.White) else pos.all_pieces(Color.Black);
        var my_attackers: u64 = attackers & occ_side;

        if (my_attackers == 0) {
            break;
        }

        var pt: u4 = undefined;
        for (PieceType.Pawn.toU3()..(PieceType.King.toU3() + 1)) |pc| {
            pt = @as(u4, @intCast(pc));
            //if ((my_attackers & (pos.bitboard_of_pt(Color.White, PieceType.make(pt)) | pos.bitboard_of_pt(Color.Black, PieceType.make(pt)))) != 0) {
            if ((my_attackers & (pos.piece_bb[pt] | pos.piece_bb[pt + 8])) != 0) {
                break;
            }
        }

        side = side.change_side();

        value = -value - 1 - piece_val[pt];

        if (value >= 0) {
            occ_side = if (side == Color.White) pos.all_pieces(Color.White) else pos.all_pieces(Color.Black);
            if ((PieceType.King.toU3() == pt) and ((attackers & occ_side) != 0)) {
                side = side.change_side();
            }
            break;
        }

        //occupied ^= @as(u64, 1) << bb.get_ls1b_index(my_attackers & pos.piece_bb[Piece.make_piece(side.change_side(), PieceType.make(pt)).toU4()]);
        //occupied ^= bb.SQUARE_BB[bb.get_ls1b_index(my_attackers & (pos.bitboard_of_pc(Piece.make_piece(Color.White, PieceType.make(pt))) | pos.bitboard_of_pc(Piece.make_piece(Color.Black, PieceType.make(pt)))))];
        occupied ^= bb.SQUARE_BB[bb.get_ls1b_index(my_attackers & (pos.piece_bb[pt] | pos.piece_bb[pt + 8]))];

        if (pt == PieceType.Pawn.toU3() or pt == PieceType.Bishop.toU3() or pt == PieceType.Queen.toU3()) {
            attackers |= (attacks.piece_attacks(to, occupied, PieceType.Bishop) & bishops);
        }
        if (pt == PieceType.Rook.toU3() or pt == PieceType.Queen.toU3()) {
            attackers |= (attacks.piece_attacks(to, occupied, PieceType.Rook) & rooks);
        }
    }

    return (side != attacker.color());
}

pub inline fn see_value(pos: *Position, move: Move, prune_positive: bool) i32 {
    // if (move.is_promotion()) {
    //     return true;
    // }
    var gain: [32]i32 = undefined;

    var from = move.from;
    var to = move.to;

    var p = pos.board[from];
    var captured = pos.board[to];

    var side = p.color();
    var pv = piece_val[p.type_of().toU3()];
    var captured_value: i32 = 0;

    if (captured != Piece.NO_PIECE) {
        captured_value = piece_val[captured.type_of().toU3()];
        if (prune_positive and pv <= captured_value) {
            return 0;
        }
    }

    //var is_promotion = move.is_promotion();
    var pqv = piece_val[move.flags.promote_type().toU3()] - piece_val[0];
    var occupied: u64 = (pos.all_pieces(Color.White) | pos.all_pieces(Color.Black)) ^ bb.SQUARE_BB[from];

    gain[0] = captured_value;
    if (move.is_promotion()) {
        pv += pqv;
        gain[0] += pqv;
    } else if (move.flags == MoveFlags.EN_PASSANT) {
        occupied ^= (@as(u64, 1) << (to ^ 8));
        gain[0] = piece_val[0];
    }

    var bq: u64 = pos.diagonal_sliders(Color.White) | pos.diagonal_sliders(Color.Black);
    var rq: u64 = pos.orthogonal_sliders(Color.White) | pos.orthogonal_sliders(Color.Black);

    var attackers: u64 = pos.all_attackers(to, occupied);
    //bb.print_bitboard(attackers);

    var cnt: u5 = 1;

    var pt: u4 = @as(u4, @intCast(p.type_of().toU3()));

    while (attackers != 0 and cnt < 32) {
        attackers &= occupied;
        side = side.change_side();
        var occ_side = if (side == Color.White) pos.all_pieces(Color.White) else pos.all_pieces(Color.Black);
        var side_att = attackers & occ_side;

        if (attackers == 0 or cnt >= 32) {
            break;
        }

        // if (((pos.checkers) & ~occupied) == 0) {
        //     side_att &= ~pos.pinned;
        // }

        if (side_att == 0) {
            break;
        }

        var pb: u64 = undefined;
        for (PieceType.Pawn.toU3()..PieceType.King.toU3() + 1) |pc| {
            pt = @as(u4, @intCast(pc));
            pb = side_att & (pos.piece_bb[pc] | pos.piece_bb[pc + 8]);
            if (pb != 0) {
                break;
            }
        }
        if (pb == 0) {
            pb = side_att;
        }

        //pb = pb & -pb;
        //occ ^= pb;
        occupied ^= bb.SQUARE_BB[bb.get_ls1b_index(pb)];
        //occupied ^= bb.SQUARE_BB[bb.get_ls1b_index(side_att & (pos.piece_bb[pt] | pos.piece_bb[pt + 8]))];

        if (pt == PieceType.Pawn.toU3() or pt == PieceType.Bishop.toU3() or pt == PieceType.Queen.toU3()) {
            attackers |= (attacks.piece_attacks(to, occupied, PieceType.Bishop) & bq);
        }
        if (pt == PieceType.Rook.toU3() or pt == PieceType.Queen.toU3()) {
            attackers |= (attacks.piece_attacks(to, occupied, PieceType.Rook) & rq);
        }

        gain[cnt] = pv - gain[cnt - 1];
        pv = piece_val[pt];
        if (move.is_promotion() and pt == 0) {
            pv += pqv;
            gain[cnt] += pqv;
        }
        cnt += 1;
    }

    cnt -= 1;
    while (cnt > 0) : (cnt -= 1) {
        if (gain[cnt - 1] > -gain[cnt]) {
            gain[cnt - 1] = -gain[cnt];
        }
    }

    return gain[0];
}
