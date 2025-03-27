const std = @import("std");
const position = @import("position.zig");
const searcher = @import("search.zig");
const attacks = @import("attacks.zig");
const bb = @import("bitboard.zig");
const history = @import("history.zig");
const lists = @import("lists.zig");

const Move = position.Move;
const Position = position.Position;
const Piece = position.Piece;
const PieceType = position.PieceType;
const Color = position.Color;
const MoveFlags = position.MoveFlags;
const Search = searcher.Search;

const MoveList = lists.MoveList;
const ScoreList = lists.ScoreList;

pub const SortHash = 9000000;
pub const QueenPromotionWithCapture = 1500000;
pub const KnightPromotionWithCapture = 1400000;
pub const SortCapture = 1200000;
pub const QueenPromotion = 1100000;
pub const KnightPromotion = 1000000;
pub const SortKiller1 = 900000;
pub const SortKiller2 = 800000;
pub const sortCounter = 700000;
pub const SortBadCapture = -900000;
pub const Badpromotion = -QueenPromotionWithCapture;

// pawns, knights, bishops, rooks, queens, kings
const piece_val = [7]i32{ 100, 300, 300, 500, 900, 20000, 0 };

pub inline fn score_move(pos: *Position, search: *Search, move_list: *MoveList, score_list: *ScoreList, hash_move: Move, comptime color: Color) void {
    for (0..move_list.count) |i| {
        const move = move_list.moves[i];
        var score: i32 = 0;
        if (move.equal(hash_move)) {
            score = SortHash;
        } else if (move.is_promotion_with_capture()) {
            switch (move.flags) {
                MoveFlags.PC_QUEEN => score = QueenPromotionWithCapture,
                MoveFlags.PC_KNIGHT => score = KnightPromotionWithCapture,
                else => score = Badpromotion,
            }
        } else if (move.is_capture()) {
            const captured = if (move.flags == MoveFlags.EN_PASSANT) 0 else pos.board[move.to].type_of().toU3();
            const capturer = pos.board[move.from].type_of().toU3();
            if (see(pos, move, -98)) {
                score = 10 * piece_val[captured] - piece_val[capturer] + SortCapture;
            } else {
                score = 10 * piece_val[captured] - piece_val[capturer] + SortBadCapture;
            }
        } else if (move.is_promotion_no_capture()) {
            switch (move.flags) {
                MoveFlags.PR_QUEEN => score = QueenPromotion,
                MoveFlags.PR_KNIGHT => score = KnightPromotion,
                else => score = Badpromotion,
            }
        } else {
            if (move.equal(search.mv_killer[search.ply][0])) {
                score = SortKiller1;
            } else if (move.equal(search.mv_killer[search.ply][1])) {
                score = SortKiller2;
            } else if (move.equal(history.get_counter_move(search))) {
                score = sortCounter;
            } else {
                const side: u4 = if (color == Color.White) Color.White.toU4() else Color.Black.toU4();
                var piece = pos.board[move.from];
                score = search.get_sh(side, move.from, move.to);
                if (search.ply >= 1) {
                    var parent = search.ns_stack[search.ply - 1].move;
                    var p_piece = search.ns_stack[search.ply - 1].piece;
                    if (!parent.is_empty()) {
                        score += search.get_ch(p_piece.toU4(), parent.to, piece.toU4(), move.to);
                    }
                }
                if (search.ply >= 2) {
                    var gparent = search.ns_stack[search.ply - 2].move;
                    var gp_piece = search.ns_stack[search.ply - 2].piece;
                    if (!gparent.is_empty()) {
                        score += search.get_fh(gp_piece.toU4(), gparent.to, piece.toU4(), move.to);
                    }
                }
            }
        }

        score_list.append(score);
    }
}

pub inline fn get_next_best(move_list: *MoveList, score_list: *ScoreList, i: usize) Move {
    var best_j = i;
    var max_score = score_list.scores[i];

    // Start from i+1 and iterate over the remaining elements
    for ((i + 1)..score_list.count) |j| {
        const score = score_list.scores[j];
        if (score > max_score) {
            best_j = j;
            max_score = score;
        }
    }

    // Swap if a better move is found
    if (best_j != i) {
        const best_move = move_list.moves[best_j];
        const best_score = score_list.scores[best_j];
        move_list.moves[best_j] = move_list.moves[i];
        score_list.scores[best_j] = score_list.scores[i];
        move_list.moves[i] = best_move;
        score_list.scores[i] = best_score;
    }

    return move_list.moves[i];
}

pub inline fn see(pos: *Position, move: Move, thr: i32) bool {
    if (move.is_promotion()) {
        return true;
    }

    const from = move.from;
    const to = move.to;

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

    var occupied: u64 = (pos.all_pieces(Color.White) | pos.all_pieces(Color.Black)) ^ bb.SQUARE_BB[from] ^ bb.SQUARE_BB[to];
    var attackers: u64 = pos.all_attackers(to, occupied);

    const bishops: u64 = pos.diagonal_sliders(Color.White) | pos.diagonal_sliders(Color.Black);
    const rooks: u64 = pos.orthogonal_sliders(Color.White) | pos.orthogonal_sliders(Color.Black);

    var side = attacker.color().change_side();

    while (true) {
        attackers &= occupied;

        var occ_side = if (side == Color.White) pos.all_pieces(Color.White) else pos.all_pieces(Color.Black);
        const my_attackers: u64 = attackers & occ_side;

        if (my_attackers == 0) {
            break;
        }

        var pt: u4 = undefined;
        for (PieceType.Pawn.toU3()..(PieceType.King.toU3() + 1)) |pc| {
            pt = @as(u4, @intCast(pc));
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

    const from = move.from;
    const to = move.to;

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

    const pqv = piece_val[move.flags.promote_type().toU3()] - piece_val[0];
    var occupied: u64 = (pos.all_pieces(Color.White) | pos.all_pieces(Color.Black)) ^ bb.SQUARE_BB[from];

    gain[0] = captured_value;
    if (move.is_promotion()) {
        pv += pqv;
        gain[0] += pqv;
    } else if (move.flags == MoveFlags.EN_PASSANT) {
        occupied ^= (@as(u64, 1) << (to ^ 8));
        gain[0] = piece_val[0];
    }

    const bq: u64 = pos.diagonal_sliders(Color.White) | pos.diagonal_sliders(Color.Black);
    const rq: u64 = pos.orthogonal_sliders(Color.White) | pos.orthogonal_sliders(Color.Black);

    var attackers: u64 = pos.all_attackers(to, occupied);

    var cnt: u5 = 1;

    var pt: u4 = @as(u4, @intCast(p.type_of().toU3()));

    while (attackers != 0 and cnt < 32) {
        attackers &= occupied;
        side = side.change_side();
        const occ_side = if (side == Color.White) pos.all_pieces(Color.White) else pos.all_pieces(Color.Black);
        const side_att = attackers & occ_side;

        if (attackers == 0 or cnt >= 32) {
            break;
        }

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

        occupied ^= bb.SQUARE_BB[bb.get_ls1b_index(pb)];

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
