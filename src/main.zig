const std = @import("std");
const uci = @import("uci.zig");
const datagen = @import("datagen.zig");
const tuner = @import("tuner.zig");
const nnue = @import("nnue.zig");
const test_suite = @import("test_suite.zig");

const tune: bool = false;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var bench: bool = false;
    var use_nnue: bool = true;
    var perft_test: bool = false;
    var self_test: bool = false;
    var nnue_stats: bool = false;
    var nnue_microbench: bool = false;
    var bench_depth: u32 = 12;
    var nnue_microbench_iterations: usize = 100000;
    var do_datagen: bool = false;
    var dg_cfg: datagen.GenConfig = .{};

    // Skip the first argument (executable name)
    var i: usize = 1;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "bench")) {
            bench = true;
            use_nnue = true;

            // Check if there's a next argument that could be the depth
            if (i + 1 < args.len) {
                // Try to parse the next argument as a number
                if (std.fmt.parseInt(u32, args[i + 1], 10)) |depth| {
                    bench_depth = depth;
                    i += 1; // Skip the depth argument
                } else |_| {
                    // If parsing fails, it's not a number, so just continue
                }
            }
        } else if (std.mem.eql(u8, args[i], "benchhce")) {
            bench = true;
            use_nnue = false;

            // Check if there's a next argument that could be the depth
            if (i + 1 < args.len) {
                // Try to parse the next argument as a number
                if (std.fmt.parseInt(u32, args[i + 1], 10)) |depth| {
                    bench_depth = depth;
                    i += 1; // Skip the depth argument
                } else |_| {
                    // If parsing fails, it's not a number, so just continue
                }
            }
        } else if (std.mem.eql(u8, args[i], "perft")) {
            perft_test = true;
        } else if (std.mem.eql(u8, args[i], "selftest")) {
            self_test = true;
        } else if (std.mem.eql(u8, args[i], "nnuestats")) {
            nnue_stats = true;
        } else if (std.mem.eql(u8, args[i], "nnuemicrobench")) {
            nnue_microbench = true;
            if (i + 1 < args.len) {
                if (std.fmt.parseInt(usize, args[i + 1], 10)) |iters| {
                    nnue_microbench_iterations = iters;
                    i += 1;
                } else |_| {}
            }
        } else if (std.mem.eql(u8, args[i], "datagen")) {
            do_datagen = true;
            // parse flags until next non-flag or end
            var j: usize = i + 1;
            while (j < args.len) : (j += 1) {
                const a = args[j];
                if (std.mem.eql(u8, a, "games") and j + 1 < args.len) {
                    dg_cfg.games = std.fmt.parseInt(usize, args[j + 1], 10) catch dg_cfg.games;
                    j += 1;
                } else if (std.mem.eql(u8, a, "filename") and j + 1 < args.len) {
                    dg_cfg.filename = args[j + 1];
                    j += 1;
                } else if (std.mem.eql(u8, a, "depth") and j + 1 < args.len) {
                    dg_cfg.best_depth = std.fmt.parseInt(u32, args[j + 1], 10) catch dg_cfg.best_depth;
                    j += 1;
                } else if (std.mem.eql(u8, a, "plies") and j + 1 < args.len) {
                    dg_cfg.max_plies = std.fmt.parseInt(usize, args[j + 1], 10) catch dg_cfg.max_plies;
                    j += 1;
                } else if (std.mem.eql(u8, a, "random") and j + 2 < args.len) {
                    dg_cfg.first_random = std.fmt.parseInt(usize, args[j + 1], 10) catch dg_cfg.first_random;
                    dg_cfg.next_mixed = std.fmt.parseInt(usize, args[j + 2], 10) catch dg_cfg.next_mixed;
                    j += 2;
                } else if (std.mem.eql(u8, a, "debug")) {
                    dg_cfg.debug = true;
                } else if (std.mem.eql(u8, a, "strict")) {
                    dg_cfg.strict = true;
                } else if (std.mem.eql(u8, a, "skipnoisy")) {
                    dg_cfg.skip_noisy = true;
                } else if (std.mem.eql(u8, a, "random_min_ply") and j + 1 < args.len) {
                    dg_cfg.random_min_ply = std.fmt.parseInt(usize, args[j + 1], 10) catch dg_cfg.random_min_ply;
                    j += 1;
                } else if (std.mem.eql(u8, a, "random_50_ply") and j + 1 < args.len) {
                    dg_cfg.random_50_ply = std.fmt.parseInt(usize, args[j + 1], 10) catch dg_cfg.random_50_ply;
                    j += 1;
                } else if (std.mem.eql(u8, a, "random_10_ply") and j + 1 < args.len) {
                    dg_cfg.random_10_ply = std.fmt.parseInt(usize, args[j + 1], 10) catch dg_cfg.random_10_ply;
                    j += 1;
                } else if (std.mem.eql(u8, a, "random_move_count") and j + 1 < args.len) {
                    dg_cfg.random_move_count = std.fmt.parseInt(usize, args[j + 1], 10) catch dg_cfg.random_move_count;
                    j += 1;
                } else if (std.mem.eql(u8, a, "save_min_ply") and j + 1 < args.len) {
                    dg_cfg.save_min_ply = std.fmt.parseInt(usize, args[j + 1], 10) catch dg_cfg.save_min_ply;
                    j += 1;
                } else if (std.mem.eql(u8, a, "save_max_ply") and j + 1 < args.len) {
                    dg_cfg.save_max_ply = std.fmt.parseInt(usize, args[j + 1], 10) catch dg_cfg.save_max_ply;
                    j += 1;
                } else if (std.mem.eql(u8, a, "adjudicate_draws_by_score")) {
                    dg_cfg.adjudicate_draws_by_score = true;
                } else if (std.mem.eql(u8, a, "adjudicate_draws_by_insufficient_mating_material")) {
                    dg_cfg.adjudicate_draws_by_insufficient_mating_material = true;
                } else if (std.mem.eql(u8, a, "full_game")) {
                    dg_cfg.full_game = true;
                } else if (std.mem.eql(u8, a, "eval") and j + 1 < args.len) {
                    const mode = args[j + 1];
                    if (std.ascii.eqlIgnoreCase(mode, "hce")) {
                        dg_cfg.eval_mode = datagen.EvalMode.HCE;
                    } else {
                        dg_cfg.eval_mode = datagen.EvalMode.NNUE;
                    }
                    j += 1;
                } else if (std.mem.eql(u8, a, "format") and j + 1 < args.len) {
                    const fmt = args[j + 1];
                    if (std.ascii.eqlIgnoreCase(fmt, "binhce")) {
                        dg_cfg.format = datagen.BinFormat.binhce;
                    } else {
                        dg_cfg.format = datagen.BinFormat.bin40;
                    }
                    j += 1;
                } else if (std.mem.eql(u8, a, "std") and j + 1 < args.len) {
                    dg_cfg.dist.std_pc = std.fmt.parseFloat(f32, args[j + 1]) catch dg_cfg.dist.std_pc;
                    j += 1;
                } else if (std.mem.eql(u8, a, "frc") and j + 1 < args.len) {
                    dg_cfg.dist.frc_pc = std.fmt.parseFloat(f32, args[j + 1]) catch dg_cfg.dist.frc_pc;
                    j += 1;
                } else if (std.mem.eql(u8, a, "dfrc") and j + 1 < args.len) {
                    dg_cfg.dist.dfrc_pc = std.fmt.parseFloat(f32, args[j + 1]) catch dg_cfg.dist.dfrc_pc;
                    j += 1;
                } else if (std.mem.eql(u8, a, "dither") and j + 1 < args.len) {
                    dg_cfg.dither_depth = std.fmt.parseInt(u32, args[j + 1], 10) catch dg_cfg.dither_depth;
                    j += 1;
                } else if (std.mem.eql(u8, a, "phase_prob_opening") and j + 1 < args.len) {
                    dg_cfg.phase_prob_opening = std.fmt.parseFloat(f32, args[j + 1]) catch dg_cfg.phase_prob_opening;
                    j += 1;
                } else if (std.mem.eql(u8, a, "phase_prob_early_middlegame") and j + 1 < args.len) {
                    dg_cfg.phase_prob_early_middlegame = std.fmt.parseFloat(f32, args[j + 1]) catch dg_cfg.phase_prob_early_middlegame;
                    j += 1;
                } else if (std.mem.eql(u8, a, "phase_prob_middlegame") and j + 1 < args.len) {
                    dg_cfg.phase_prob_middlegame = std.fmt.parseFloat(f32, args[j + 1]) catch dg_cfg.phase_prob_middlegame;
                    j += 1;
                } else if (std.mem.eql(u8, a, "phase_prob_late_middlegame") and j + 1 < args.len) {
                    dg_cfg.phase_prob_late_middlegame = std.fmt.parseFloat(f32, args[j + 1]) catch dg_cfg.phase_prob_late_middlegame;
                    j += 1;
                } else if (std.mem.eql(u8, a, "phase_prob_endgame") and j + 1 < args.len) {
                    dg_cfg.phase_prob_endgame = std.fmt.parseFloat(f32, args[j + 1]) catch dg_cfg.phase_prob_endgame;
                    j += 1;
                } else if (std.mem.eql(u8, a, "min_nodes") and j + 1 < args.len) {
                    dg_cfg.min_nodes = std.fmt.parseInt(u64, args[j + 1], 10) catch dg_cfg.min_nodes;
                    j += 1;
                } else {
                    // stop parsing at unknown token to allow other modes
                    break;
                }
            }
            i = j - 1;
        }
        i += 1;
    }

    if (tune) {
        var tuner_instance = tuner.Tuner.new();
        tuner_instance.init();
        try tuner_instance.convertDataset();
    } else if (bench) {
        if (nnue_stats) nnue.reset_debug_stats();
        try uci.bench(allocator, bench_depth, use_nnue);
        if (nnue_stats and use_nnue) {
            const stdout_file = std.Io.File.stdout();
            var out_writer = stdout_file.writer(io, &.{});
            const out = &out_writer.interface;
            try nnue.print_debug_stats(out);
        }
    } else if (perft_test) {
        try uci.perft_test(allocator);
    } else if (self_test) {
        const stdout_file = std.Io.File.stdout();
        var out_writer = stdout_file.writer(io, &.{});
        const out = &out_writer.interface;
        _ = try test_suite.run_all_tests(out);
    } else if (nnue_microbench) {
        try nnue.embed_and_init();
        nnue.engine_loaded_net = true;
        nnue.engine_using_nnue = true;
        const stdout_file = std.Io.File.stdout();
        var out_writer = stdout_file.writer(io, &.{});
        const out = &out_writer.interface;
        try nnue.microbench(allocator, nnue_microbench_iterations, out);
    } else if (do_datagen) {
        try uci.run_datagen(allocator, dg_cfg);
    } else {
        try uci.uci_loop(allocator);
    }
}
