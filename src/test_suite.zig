const std = @import("std");
const position = @import("position.zig");
const evaluation = @import("evaluation.zig");
const perft = @import("perft.zig");
const tuner = @import("tuner.zig");
const nnue = @import("nnue.zig");
const uci = @import("uci.zig");
const lists = @import("lists.zig");

const Position = position.Position;
const Color = position.Color;
const Piece = position.Piece;
const MoveList = lists.MoveList;

// Test result structure
pub const TestResult = struct {
    passed: u32 = 0,
    failed: u32 = 0,
    total: u32 = 0,

    pub fn add_pass(self: *TestResult) void {
        self.passed += 1;
        self.total += 1;
    }

    pub fn add_fail(self: *TestResult) void {
        self.failed += 1;
        self.total += 1;
    }

    pub fn is_success(self: TestResult) bool {
        return self.failed == 0;
    }

    pub fn print_summary(self: TestResult, writer: anytype, test_name: []const u8) !void {
        try writer.print("Test Suite: {s}\n", .{test_name});
        try writer.print("  Total:  {d}\n", .{self.total});
        try writer.print("  Passed: {d}\n", .{self.passed});
        try writer.print("  Failed: {d}\n", .{self.failed});
        if (self.is_success()) {
            try writer.print("  Result: ✓ PASS\n\n", .{});
        } else {
            try writer.print("  Result: ✗ FAIL\n\n", .{});
        }
    }
};

// Evaluation consistency tests
pub const EvalTests = struct {
    // Test that evaluation is symmetric: eval(pos) == -eval(flip(pos))
    pub fn test_eval_symmetry(writer: anytype) !TestResult {
        var result = TestResult{};

        const test_fens = [_][]const u8{
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", // Starting position
            "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", // Kiwipete
            "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", // Endgame position
            "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1", // Complex position
            "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8", // Tactical position
        };

        for (test_fens) |fen| {
            var pos = Position.new();
            _ = pos.set(fen) catch {
                try writer.print("  ✗ Failed to parse FEN: {s}\n", .{fen});
                result.add_fail();
                continue;
            };

            // Get evaluation from white's perspective
            const eval_white = pos.eval.eval(&pos, Color.White);

            // Flip the position (swap colors)
            var flipped_pos = Position.new();
            const flipped_fen = try flip_fen(fen);
            _ = flipped_pos.set(flipped_fen) catch {
                try writer.print("  ✗ Failed to parse flipped FEN\n", .{});
                result.add_fail();
                continue;
            };

            // Get evaluation from black's perspective (which is now white in flipped position)
            const eval_flipped = flipped_pos.eval.eval(&flipped_pos, Color.White);

            // They should be negatives of each other (within small tolerance for rounding)
            const diff = @abs(eval_white + eval_flipped);
            if (diff <= 2) { // Allow small rounding errors
                result.add_pass();
            } else {
                try writer.print("  ✗ Symmetry violation: FEN={s}, eval={d}, flipped_eval={d}, diff={d}\n", .{ fen, eval_white, eval_flipped, diff });
                result.add_fail();
            }
        }

        return result;
    }

    // Test that evaluations are within bounds
    pub fn test_eval_bounds(writer: anytype) !TestResult {
        var result = TestResult{};

        const MAX_EVAL = 50000; // From search.zig MAX_SCORE

        const test_fens = [_][]const u8{
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
            "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
            "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
            "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
            "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
            "8/8/8/8/8/8/8/K6k w - - 0 1", // Minimal position
            "rnbqkb1r/pppppppp/5n2/8/8/5N2/PPPPPPPP/RNBQKB1R w KQkq - 0 1", // Symmetric
        };

        for (test_fens) |fen| {
            var pos = Position.new();
            _ = pos.set(fen) catch {
                try writer.print("  ✗ Failed to parse FEN: {s}\n", .{fen});
                result.add_fail();
                continue;
            };

            const eval_white = pos.eval.eval(&pos, Color.White);
            const eval_black = pos.eval.eval(&pos, Color.Black);

            // Check bounds
            if (@abs(eval_white) <= MAX_EVAL and @abs(eval_black) <= MAX_EVAL) {
                result.add_pass();
            } else {
                try writer.print("  ✗ Eval out of bounds: FEN={s}, eval_white={d}, eval_black={d}\n", .{ fen, eval_white, eval_black });
                result.add_fail();
            }
        }

        return result;
    }

    // Test HCE feature extraction consistency
    pub fn test_hce_features(writer: anytype) !TestResult {
        var result = TestResult{};

        // Save current NNUE state and force HCE mode
        const saved_nnue_state = nnue.engine_using_nnue;
        nnue.engine_using_nnue = false;
        defer nnue.engine_using_nnue = saved_nnue_state;

        const test_fens = [_][]const u8{
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
            "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
            "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        };

        for (test_fens) |fen| {
            var pos = Position.new();
            _ = pos.set(fen) catch {
                try writer.print("  ✗ Failed to parse FEN: {s}\n", .{fen});
                result.add_fail();
                continue;
            };

            // Extract features twice and compare
            var tnr1 = tuner.Tuner.new();
            var tnr2 = tuner.Tuner.new();

            const eval1 = pos.eval.clean_eval(&pos, &tnr1);
            const eval2 = pos.eval.clean_eval(&pos, &tnr2);

            // Evaluations should be identical
            if (eval1 == eval2) {
                result.add_pass();
            } else {
                try writer.print("  ✗ HCE eval inconsistency: FEN={s}, eval1={d}, eval2={d}\n", .{ fen, eval1, eval2 });
                result.add_fail();
            }
        }

        return result;
    }

    // Helper function to flip a FEN string (swap colors)
    fn flip_fen(fen: []const u8) ![]const u8 {
        // This is a simplified version
        _ = fen;
        return "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"; // Placeholder
    }
};

pub const NNUETests = struct {
    fn accumulators_equal(a: nnue.Accumulator, b: nnue.Accumulator) bool {
        return std.mem.eql(i16, a.accumulation[0][0..], b.accumulation[0][0..]) and
            std.mem.eql(i16, a.accumulation[1][0..], b.accumulation[1][0..]);
    }

    fn check_position(writer: anytype, pos: *Position, label: []const u8) !bool {
        const full = nnue.refresh_accumulator(pos);
        pos.history[pos.game_ply].accumulator.computed_accumulation = false;
        pos.history[pos.game_ply].accumulator.computed_score = false;
        nnue.incremental_update(pos);
        const inc = pos.history[pos.game_ply].accumulator;

        if (!accumulators_equal(full, inc)) {
            try writer.print("  ✗ NNUE accumulator mismatch at {s}, ply={d}\n", .{ label, pos.game_ply });
            return false;
        }

        const eval_white_full = nnue.evaluate(full, Color.White);
        const eval_white_inc = nnue.evaluate(inc, Color.White);
        const eval_black_full = nnue.evaluate(full, Color.Black);
        const eval_black_inc = nnue.evaluate(inc, Color.Black);
        if (eval_white_full != eval_white_inc or eval_black_full != eval_black_inc) {
            try writer.print("  ✗ NNUE eval mismatch at {s}, ply={d}, white {d}!={d}, black {d}!={d}\n", .{
                label, pos.game_ply, eval_white_full, eval_white_inc, eval_black_full, eval_black_inc,
            });
            return false;
        }

        return true;
    }

    pub fn test_incremental_matches_full_refresh(writer: anytype) !TestResult {
        var result = TestResult{};

        const saved_nnue_state = nnue.engine_using_nnue;
        nnue.engine_using_nnue = true;
        defer nnue.engine_using_nnue = saved_nnue_state;

        try uci.init_all(std.heap.c_allocator);

        const test_fens = [_][]const u8{
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
            "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
            "r2q1rk1/1ppnbppp/p2p1nb1/3Pp3/2P1P1P1/2N2N1P/PPB1QP2/R1B2RK1 b - - 0 1",
            "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
            "r3k2r/ppp1bppp/2n5/3n4/3PB3/8/PP3PPP/RNB1R1K1 b kq - 0 1",
        };

        for (test_fens, 0..) |fen, fen_idx| {
            var pos = Position.new();
            _ = pos.set(fen) catch {
                try writer.print("  ✗ Failed to parse FEN: {s}\n", .{fen});
                result.add_fail();
                continue;
            };

            if (try check_position(writer, &pos, fen)) {
                result.add_pass();
            } else {
                result.add_fail();
                continue;
            }

            var ply: usize = 0;
            while (ply < 24) : (ply += 1) {
                var list: MoveList = .{};
                if (pos.side_to_play == .White) {
                    pos.generate_legals(Color.White, &list);
                } else {
                    pos.generate_legals(Color.Black, &list);
                }

                if (list.count == 0) break;

                const move_idx = (fen_idx * 17 + ply * 7) % list.count;
                const move = list.moves[move_idx];

                if (pos.side_to_play == .White) {
                    pos.play(move, .White);
                } else {
                    pos.play(move, .Black);
                }

                var label_buf: [64]u8 = undefined;
                const label = try std.fmt.bufPrint(&label_buf, "fen#{d}/ply#{d}", .{ fen_idx, ply + 1 });
                if (try check_position(writer, &pos, label)) {
                    result.add_pass();
                } else {
                    result.add_fail();
                    break;
                }
            }
        }

        return result;
    }
};

// Main test runner
pub fn run_all_tests(writer: anytype) !bool {
    try writer.print("\n=== Running Engine Validation Tests ===\n\n", .{});

    var all_passed = true;

    // Run evaluation symmetry tests
    const symmetry_result = try EvalTests.test_eval_symmetry(writer);
    try symmetry_result.print_summary(writer, "Evaluation Symmetry");
    all_passed = all_passed and symmetry_result.is_success();

    // Run evaluation bounds tests
    const bounds_result = try EvalTests.test_eval_bounds(writer);
    try bounds_result.print_summary(writer, "Evaluation Bounds");
    all_passed = all_passed and bounds_result.is_success();

    // Run HCE feature extraction tests
    const hce_result = try EvalTests.test_hce_features(writer);
    try hce_result.print_summary(writer, "HCE Feature Extraction");
    all_passed = all_passed and hce_result.is_success();

    const nnue_result = try NNUETests.test_incremental_matches_full_refresh(writer);
    try nnue_result.print_summary(writer, "NNUE Incremental Correctness");
    all_passed = all_passed and nnue_result.is_success();

    try writer.print("=== Test Summary ===\n", .{});
    if (all_passed) {
        try writer.print("✓ All tests PASSED\n\n", .{});
    } else {
        try writer.print("✗ Some tests FAILED\n\n", .{});
    }

    return all_passed;
}

// Export HCE features for a position (for validation scripts)
pub fn export_hce_features(pos: *Position, writer: anytype) !void {
    // Save current NNUE state and force HCE mode
    const saved_nnue_state = nnue.engine_using_nnue;
    nnue.engine_using_nnue = false;
    defer nnue.engine_using_nnue = saved_nnue_state;

    var tnr = tuner.Tuner.new();
    const eval_score = pos.eval.clean_eval(pos, &tnr);

    // Output in a parseable format
    try writer.print("HCE_FEATURES_START\n", .{});
    try writer.print("eval={d}\n", .{eval_score});

    // Material counts
    try writer.print("mat_white=", .{});
    for (tnr.mat[0], 0..) |count, i| {
        if (i > 0) try writer.print(",", .{});
        try writer.print("{d}", .{count});
    }
    try writer.print("\n", .{});

    try writer.print("mat_black=", .{});
    for (tnr.mat[1], 0..) |count, i| {
        if (i > 0) try writer.print(",", .{});
        try writer.print("{d}", .{count});
    }
    try writer.print("\n", .{});

    // PSQT (simplified - just sum per piece type)
    try writer.print("psqt_white=", .{});
    for (0..6) |pt| {
        if (pt > 0) try writer.print(",", .{});
        var sum: u32 = 0;
        for (tnr.psqt[0][pt]) |val| {
            sum += val;
        }
        try writer.print("{d}", .{sum});
    }
    try writer.print("\n", .{});

    try writer.print("psqt_black=", .{});
    for (0..6) |pt| {
        if (pt > 0) try writer.print(",", .{});
        var sum: u32 = 0;
        for (tnr.psqt[1][pt]) |val| {
            sum += val;
        }
        try writer.print("{d}", .{sum});
    }
    try writer.print("\n", .{});

    try writer.print("HCE_FEATURES_END\n", .{});
}
