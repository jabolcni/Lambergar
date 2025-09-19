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
pub const QueenPromotionWithCapture = 1600000;
pub const KnightPromotionWithCapture = 1500000;
pub const SortBestCapture = 1300000;
pub const SortCapture = 1200000;
pub const QueenPromotion = 1100000;
pub const KnightPromotion = 1000000;
pub const SortKiller1 = 900000;
pub const SortKiller2 = 800000;
pub const sortCounter = 700000;
pub const SortBadCapture = -900000;
pub const Badpromotion = -QueenPromotionWithCapture;

// pawns, knights, bishops, rooks, queens, kings
pub const piece_val = [7]i32{ 100, 300, 300, 500, 900, 20000, 0 };

pub fn score_move(pos: *Position, search: *Search, move_list: *MoveList, score_list: *ScoreList, hash_move: Move, comptime color: Color) void {
    for (0..move_list.count) |i| {
        const move = move_list.moves[i];
        var score: i32 = 0;
        if (move.equal(hash_move)) {
            score = SortHash;
        } else if (move.is_capture()) {
            const captured = if (move.flags == MoveFlags.EN_PASSANT) 0 else pos.board[move.to].type_of().toU3();
            const capturer = pos.board[move.from].type_of().toU3();
            //score = 10 * piece_val[captured] - piece_val[capturer] + SortCapture;
            const see_val = see_value(pos, move, true);
            if (see_val >= 0) {
                score = 10 * piece_val[captured] - piece_val[capturer] + SortCapture;
            } else {
                score = 10 * piece_val[captured] - piece_val[capturer] + SortBadCapture;
            }
        } else if (move.is_promotion()) {
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
                // } else if (move.equal(history.get_counter_move(search))) {
                //     score = sortCounter;
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
                        score += search.get_ch(gp_piece.toU4(), gparent.to, piece.toU4(), move.to);
                    }
                }
            }
        }

        score_list.append(score);
    }
}

pub fn get_next_best(move_list: *MoveList, score_list: *ScoreList, i: usize) Move {
    // Use local variables for better register allocation
    var best_j = i;
    var max_score = score_list.scores[i];

    // Unroll the loop manually for better performance
    var j = i + 1;
    const loop_end = score_list.count - (score_list.count - j) % 4;

    // Process 4 elements at a time
    while (j < loop_end) : (j += 4) {
        const score0 = score_list.scores[j];
        const score1 = score_list.scores[j + 1];
        const score2 = score_list.scores[j + 2];
        const score3 = score_list.scores[j + 3];

        if (score0 > max_score) {
            max_score = score0;
            best_j = j;
        }
        if (score1 > max_score) {
            max_score = score1;
            best_j = j + 1;
        }
        if (score2 > max_score) {
            max_score = score2;
            best_j = j + 2;
        }
        if (score3 > max_score) {
            max_score = score3;
            best_j = j + 3;
        }
    }

    // Process remaining elements
    while (j < score_list.count) : (j += 1) {
        const score = score_list.scores[j];
        if (score > max_score) {
            max_score = score;
            best_j = j;
        }
    }

    // Swap if needed
    if (best_j != i) {
        // Use swap functions that might be optimized better
        // std.mem.swap(Move, &move_list.moves[best_j], &move_list.moves[i]);
        // std.mem.swap(i32, &score_list.scores[best_j], &score_list.scores[i]);
        const best_move = move_list.moves[best_j];
        const best_score = score_list.scores[best_j];
        move_list.moves[best_j] = move_list.moves[i];
        score_list.scores[best_j] = score_list.scores[i];
        move_list.moves[i] = best_move;
        score_list.scores[i] = best_score;
    }

    return move_list.moves[i];
}

pub fn see_value(pos: *Position, move: Move, prune_positive: bool) i32 {
    //_ = prune_positive; // Unused parameter, but kept for compatibility
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

    var pqv: i32 = 0;
    var promote_to: u3 = PieceType.Pawn.toU3();
    if (move.is_promotion()) {
        promote_to = move.flags.promote_type().toU3();
        pqv = piece_val[promote_to] - piece_val[PieceType.Pawn.toU3()];
    }

    var occupied: u64 = (pos.all_pieces(Color.White) | pos.all_pieces(Color.Black)) ^ bb.SQUARE_BB[from];

    gain[0] = captured_value;
    var pt: u4 = @as(u4, @intCast(p.type_of().toU3()));

    if (move.is_promotion()) {
        pv += pqv;
        gain[0] += pqv;
        pt = @as(u4, @intCast(promote_to)); // Update to promoted piece
    } else if (move.flags == MoveFlags.EN_PASSANT) {
        occupied ^= (@as(u64, 1) << (to ^ 8));
        gain[0] = piece_val[PieceType.Pawn.toU3()];
    }

    const bq: u64 = pos.diagonal_sliders(Color.White) | pos.diagonal_sliders(Color.Black);
    const rq: u64 = pos.orthogonal_sliders(Color.White) | pos.orthogonal_sliders(Color.Black);

    var attackers: u64 = pos.all_attackers(to, occupied);

    var cnt: u5 = 1;

    while (attackers != 0 and cnt < 32) {
        attackers &= occupied;
        side = side.change_side();
        const occ_side = if (side == Color.White) pos.all_pieces(Color.White) else pos.all_pieces(Color.Black);
        const side_att = attackers & occ_side;

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

        // Check for pawn promotion (8th rank for White, 1st rank for Black)
        var is_promotion = false;
        if (pt == PieceType.Pawn.toU3()) {
            const rank = to >> 3;
            if ((side == Color.White and rank == 7) or (side == Color.Black and rank == 0)) {
                is_promotion = true;
                pt = PieceType.Queen.toU3(); // Assume queen for recaptures
                pqv = piece_val[PieceType.Queen.toU3()] - piece_val[PieceType.Pawn.toU3()];
            }
        }

        if (pt == PieceType.Pawn.toU3() or pt == PieceType.Bishop.toU3() or pt == PieceType.Queen.toU3()) {
            attackers |= (attacks.piece_attacks(to, occupied, PieceType.Bishop) & bq);
        }
        if (pt == PieceType.Rook.toU3() or pt == PieceType.Queen.toU3()) {
            attackers |= (attacks.piece_attacks(to, occupied, PieceType.Rook) & rq);
        }

        gain[cnt] = pv - gain[cnt - 1];
        if (is_promotion) {
            gain[cnt] += pqv; // Add promotion value
        }
        pv = piece_val[pt];
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
