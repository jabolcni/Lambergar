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
const MoveScoreList = lists.MoveScoreList;

pub const SortHash = 9000000;
pub const QueenPromotionWithCapture = 1600000;
pub const KnightPromotionWithCapture = 1500000;
pub const SortBestCapture = 1300000;
pub const SortCapture = 1200000;
const SortCaptureNeedsSee = SortCapture - 30000;
pub const QueenPromotion = 1100000;
pub const KnightPromotion = 1000000;
pub const SortKiller1 = 900000;
pub const SortKiller2 = 800000;
pub const sortCounter = 750000;
pub const SortPendingQuiet = 100000;
pub const SortBadCapture = -900000;
pub const Badpromotion = -QueenPromotionWithCapture;

// pawns, knights, bishops, rooks, queens, kings
pub const piece_val = [7]i32{ 100, 300, 300, 500, 900, 20000, 0 };

inline fn promotion_score(flags: MoveFlags) i32 {
    return switch (flags) {
        MoveFlags.PR_QUEEN => QueenPromotion,
        MoveFlags.PR_KNIGHT => KnightPromotion,
        MoveFlags.PC_QUEEN => QueenPromotionWithCapture,
        MoveFlags.PC_KNIGHT => KnightPromotionWithCapture,
        else => Badpromotion,
    };
}

pub fn score_move(pos: *Position, search: *Search, opp_threats: u64, move_list: *MoveList, score_list: *MoveScoreList, hash_move: Move, comptime color: Color) void {
    const killer1 = search.mv_killer[search.ply][0];
    const killer2 = search.mv_killer[search.ply][1];
    const counter = history.get_counter_move(search);
    const salt_u32: u32 = ((@as(u32, @truncate(pos.hash))) ^ search.seed) & 31;
    const salt: i32 = @as(i32, @intCast(salt_u32)) - 16;
    const board = &pos.board;
    const side: u4 = if (color == Color.White) Color.White.toU4() else Color.Black.toU4();
    const continuations = history.make_ordering_continuations(search);

    for (0..move_list.count) |i| {
        const move = move_list.moves[i];
        var score: i32 = 0;
        if (move.equal(hash_move)) {
            score = SortHash;
        } else if (move.is_promotion_with_capture()) {
            score = promotion_score(move.flags);
        } else if (move.is_capture()) {
            const captured = if (move.flags == MoveFlags.EN_PASSANT) 0 else board[move.to].type_of().toU3();
            const see_val = see_value(pos, move, true);
            const victim_score = 16 * piece_val[captured];
            // CSC-1 result: disabling the SEE-based good/bad capture split scored about
            // -21.21 +/- 10.86 Elo in a 2+0.02 test, so this looks materially
            // stronger than the smaller move-ordering bonuses like killers/countermoves.
            if (see_val >= 0) {
                const capt_hist = history.capture_history_score_with_threats(search, pos, opp_threats, move);
                score = victim_score + SortCapture + capt_hist;
            } else {
                score = victim_score + SortBadCapture;
            }
        } else if (move.is_promotion()) {
            score = promotion_score(move.flags);
        } else {
            // KMO-1 result: disabling killer-move ordering scored about
            // -5.43 +/- 4.72 Elo in an 8000-game 2+0.02 test, so it looks
            // like a small but real contributor in the current engine.
            if (move.equal(killer1)) {
                score = SortKiller1;
            } else if (move.equal(killer2)) {
                score = SortKiller2;
            } else if (move.equal(counter)) {
                // CMO-1 result: disabling countermove ordering scored about
                // -5.04 +/- 4.66 Elo in an 8000-game 2+0.02 test, so it also
                // looks like a small but real contributor.
                score = sortCounter;
            } else {
                // HMO-1 result: disabling quiet history ordering lost about
                // 138.56 +/- 17.06 Elo in a 2+0.02 test, making it one of the
                // single strongest move-ordering features measured so far.
                const piece = board[move.from];
                score = history.quiet_order_score(search, opp_threats, side, continuations, piece, move);
            }

            // Tiny per-thread perturbation to diversify helper ordering (Lazy SMP)
            score += salt;
        }

        score_list.append(move, score);
    }
}

pub fn score_move_defer_quiets(pos: *Position, search: *Search, opp_threats: u64, move_list: *MoveList, score_list: *MoveScoreList, hash_move: Move) void {
    const killer1 = search.mv_killer[search.ply][0];
    const killer2 = search.mv_killer[search.ply][1];
    const counter = history.get_counter_move(search);
    const salt_u32: u32 = ((@as(u32, @truncate(pos.hash))) ^ search.seed) & 31;
    const salt: i32 = @as(i32, @intCast(salt_u32)) - 16;
    const board = &pos.board;

    for (0..move_list.count) |i| {
        const move = move_list.moves[i];
        var score: i32 = 0;
        if (move.equal(hash_move)) {
            score = SortHash;
        } else if (move.is_promotion_with_capture()) {
            score = promotion_score(move.flags);
        } else if (move.is_capture()) {
            const captured = if (move.flags == MoveFlags.EN_PASSANT) 0 else board[move.to].type_of().toU3();
            const see_val = see_value(pos, move, true);
            const victim_score = 16 * piece_val[captured];
            if (see_val >= 0) {
                const capt_hist = history.capture_history_score_with_threats(search, pos, opp_threats, move);
                score = victim_score + SortCapture + capt_hist;
            } else {
                score = victim_score + SortBadCapture;
            }
        } else if (move.is_promotion()) {
            score = promotion_score(move.flags);
        } else if (move.equal(killer1)) {
            score = SortKiller1 + salt;
        } else if (move.equal(killer2)) {
            score = SortKiller2 + salt;
        } else if (move.equal(counter)) {
            score = sortCounter + salt;
        } else {
            score = SortPendingQuiet;
        }

        score_list.append(move, score);
    }
}

pub fn score_deferred_quiets(pos: *Position, search: *Search, opp_threats: u64, score_list: *MoveScoreList, start: usize, comptime color: Color) void {
    const salt_u32: u32 = ((@as(u32, @truncate(pos.hash))) ^ search.seed) & 31;
    const salt: i32 = @as(i32, @intCast(salt_u32)) - 16;
    const board = &pos.board;
    const side: u4 = if (color == Color.White) Color.White.toU4() else Color.Black.toU4();
    const continuations = history.make_ordering_continuations(search);

    for (start..score_list.count) |i| {
        if (score_list.items[i].score != SortPendingQuiet) continue;
        const move = score_list.items[i].move;
        const piece = board[move.from];
        score_list.items[i].score = history.quiet_order_score(search, opp_threats, side, continuations, piece, move) + salt;
    }
}

pub fn score_noisy_moves(pos: *Position, search: *Search, opp_threats: u64, move_list: *MoveList, score_list: *MoveScoreList, hash_move: Move) void {
    const board = &pos.board;
    for (0..move_list.count) |i| {
        const move = move_list.moves[i];
        var score: i32 = 0;

        if (move.equal(hash_move)) {
            score = SortHash;
        } else if (move.is_capture()) {
            const captured = if (move.flags == MoveFlags.EN_PASSANT) 0 else board[move.to].type_of().toU3();
            const capturer = board[move.from].type_of().toU3();
            const capt_hist = history.capture_history_score_with_threats(search, pos, opp_threats, move);
            score = 10 * piece_val[captured] - piece_val[capturer] + SortCaptureNeedsSee + capt_hist;
        } else {
            score = switch (move.flags) {
                MoveFlags.PR_QUEEN => QueenPromotion,
                MoveFlags.PR_KNIGHT => KnightPromotion,
                else => Badpromotion,
            };
        }

        score_list.append(move, score);
    }
}

pub fn get_next_best(score_list: *MoveScoreList, i: usize) Move {
    // Use local variables for better register allocation
    var best_j = i;
    var max_score = score_list.items[i].score;

    // Unroll the loop manually for better performance
    var j = i + 1;
    const loop_end = score_list.count - (score_list.count - j) % 4;

    // Process 4 elements at a time
    while (j < loop_end) : (j += 4) {
        const score0 = score_list.items[j].score;
        const score1 = score_list.items[j + 1].score;
        const score2 = score_list.items[j + 2].score;
        const score3 = score_list.items[j + 3].score;

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
        const score = score_list.items[j].score;
        if (score > max_score) {
            max_score = score;
            best_j = j;
        }
    }

    // Swap if needed
    if (best_j != i) {
        std.mem.swap(lists.MoveScore, &score_list.items[best_j], &score_list.items[i]);
    }

    return score_list.items[i].move;
}

pub inline fn score_implies_nonnegative_capture_see(move: Move, score: i32) bool {
    return move.is_capture() and !move.is_promotion_with_capture() and score >= SortCapture;
}

pub inline fn see_ge(pos: *Position, move: Move, threshold: i32) bool {
    const moving_piece = pos.board[move.from];
    const pawn_val = piece_val[PieceType.Pawn.toU3()];
    const moving_piece_value = piece_val[moving_piece.type_of().toU3()];
    const promotion_delta = if (move.is_promotion())
        piece_val[move.flags.promote_type().toU3()] - pawn_val
    else
        0;
    const moved_piece_value = moving_piece_value + promotion_delta;
    const gain = if (move.flags == MoveFlags.EN_PASSANT)
        pawn_val + promotion_delta
    else if (move.is_capture())
        piece_val[pos.board[move.to].type_of().toU3()] + promotion_delta
    else
        promotion_delta;

    // Cheap lower bound: even if the moved piece is immediately recaptured and
    // we never continue the exchange, the SEE cannot be worse than this.
    if (gain - moved_piece_value >= threshold) return true;

    return see_value(pos, move, false) >= threshold;
}

// pub fn see_value(pos: *Position, move: Move, prune_positive: bool) i32 {
//     //_ = prune_positive; // Unused parameter, but kept for compatibility
//     var gain: [32]i32 = undefined;

//     const from = move.from;
//     const to = move.to;

//     var p = pos.board[from];
//     var captured = pos.board[to];

//     var side = p.color();
//     var pv = piece_val[p.type_of().toU3()];
//     var captured_value: i32 = 0;

//     if (captured != Piece.NO_PIECE) {
//         captured_value = piece_val[captured.type_of().toU3()];
//         if (prune_positive and pv <= captured_value) {
//             return 0;
//         }
//     }

//     var pqv: i32 = 0;
//     var promote_to: u3 = PieceType.Pawn.toU3();
//     if (move.is_promotion()) {
//         promote_to = move.flags.promote_type().toU3();
//         pqv = piece_val[promote_to] - piece_val[PieceType.Pawn.toU3()];
//     }

//     var occupied: u64 = (pos.all_pieces(Color.White) | pos.all_pieces(Color.Black)) ^ bb.SQUARE_BB[from];

//     gain[0] = captured_value;
//     var pt: u4 = @as(u4, @intCast(p.type_of().toU3()));

//     if (move.is_promotion()) {
//         pv += pqv;
//         gain[0] += pqv;
//         pt = @as(u4, @intCast(promote_to)); // Update to promoted piece
//     } else if (move.flags == MoveFlags.EN_PASSANT) {
//         occupied ^= (@as(u64, 1) << (to ^ 8));
//         gain[0] = piece_val[PieceType.Pawn.toU3()];
//     }

//     const bq: u64 = pos.diagonal_sliders(Color.White) | pos.diagonal_sliders(Color.Black);
//     const rq: u64 = pos.orthogonal_sliders(Color.White) | pos.orthogonal_sliders(Color.Black);

//     var attackers: u64 = pos.all_attackers(to, occupied);

//     var cnt: u5 = 1;

pub inline fn see_value(pos: *Position, move: Move, prune_positive: bool) i32 {
    var gain: [16]i32 = undefined;

    const from: u6 = move.from;
    const to: u6 = move.to;
    const from_bb: u64 = bb.SQUARE_BB[from];
    const to_bb: u64 = bb.SQUARE_BB[to];
    const flags = move.flags;

    // Fetch moving piece once
    var p = pos.board[from];
    var side = p.color();

    // Cache piece values we’ll reuse
    const pawn_val: i32 = piece_val[PieceType.Pawn.toU3()];
    var pt_u3: u3 = p.type_of().toU3();
    var pv: i32 = piece_val[pt_u3];

    // Resolve captured piece once (EP-aware)
    var captured = if (flags == MoveFlags.EN_PASSANT)
        (if (side == Color.White) pos.board[to - 8] else pos.board[to + 8])
    else
        pos.board[to];

    // Compute captured value once (EP captured is always a pawn)
    var captured_value: i32 = switch (captured) {
        Piece.NO_PIECE => if (flags == MoveFlags.EN_PASSANT) pawn_val else 0,
        else => piece_val[captured.type_of().toU3()],
    };

    // Early non-losing-capture pruning (same logic, fewer table reads)
    if (prune_positive and captured_value != 0) {
        if (pv <= captured_value) return 0;
    }

    // Promotion delta once
    var pqv: i32 = 0;
    if (move.is_promotion()) {
        const promote_to: u3 = flags.promote_type().toU3();
        pqv = piece_val[promote_to] - pawn_val;
        pv += pqv;
        pt_u3 = promote_to; // attacker becomes promoted type for subsequent recaptures
        captured_value += pqv; // gain[0] includes promotion bump
    }

    // Initial gain
    gain[0] = captured_value;

    // Initial occupied after making the move
    // Start with current occupancy and remove the source square
    var occupied: u64 = (pos.all_pieces(Color.White) | pos.all_pieces(Color.Black)) ^ from_bb;

    // Remove captured piece from occupancy (EP removes the pawn behind 'to')
    if (flags == MoveFlags.EN_PASSANT) {
        const ep_sq: u6 = if (side == Color.White) to - 8 else to + 8;
        occupied ^= bb.SQUARE_BB[ep_sq];
    } else if (captured != Piece.NO_PIECE) {
        occupied ^= to_bb;
    }

    // Attacker now sits on 'to'
    occupied |= to_bb;

    // Precompute slider unions once; you reuse them later
    const bq: u64 = pos.diagonal_sliders(Color.White) | pos.diagonal_sliders(Color.Black);
    const rq: u64 = pos.orthogonal_sliders(Color.White) | pos.orthogonal_sliders(Color.Black);

    // Initial attacker set
    var attackers: u64 = pos.all_attackers(to, occupied);

    // Your variables expected by the loop
    var pt: u4 = @as(u4, @intCast(pt_u3));
    var cnt: u5 = 1;

    const white_occ = pos.all_pieces(Color.White);
    const black_occ = pos.all_pieces(Color.Black);
    const piece_bb = &pos.piece_bb;

    //if (captured == Piece.NO_PIECE) return 0;

    while (attackers != 0 and cnt < 16) {
        attackers &= occupied;
        side = side.change_side();
        //const occ_side = if (side == Color.White) pos.all_pieces(Color.White) else pos.all_pieces(Color.Black);
        //const side_att = attackers & occ_side;
        const side_att = attackers & if (side == Color.White) white_occ else black_occ;

        if (side_att == 0) {
            break;
        }

        var pb: u64 = undefined;
        for (PieceType.Pawn.toU3()..PieceType.King.toU3() + 1) |pc| {
            pt = @as(u4, @intCast(pc));
            pb = side_att & (piece_bb[pc] | piece_bb[pc + 8]);
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
    // while (cnt > 0) : (cnt -= 1) {
    //     if (gain[cnt - 1] > -gain[cnt]) {
    //         gain[cnt - 1] = -gain[cnt];
    //     }
    // }
    var i = cnt;
    while (i > 0) : (i -= 1) {
        const g = -gain[i];
        if (gain[i - 1] > g) gain[i - 1] = g;
    }

    return gain[0];
}
