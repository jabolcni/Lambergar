const std = @import("std");
const uci = @import("uci.zig");
//const datagen = @import("datagen.zig");
const tuner = @import("tuner.zig");

const tune: bool = false;

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    var bench: bool = false;
    var perft_test: bool = false;
    var bench_depth: u32 = 12;
    // var do_datagen: bool = false;
    // var dg_cfg: datagen.GenConfig = .{};

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Skip the first argument (executable name)
    var i: usize = 1;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "bench")) {
            bench = true;

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
            // } else if (std.mem.eql(u8, args[i], "datagen")) {
            //     do_datagen = true;
            //     // parse flags until next non-flag or end
            //     var j: usize = i + 1;
            //     while (j < args.len) : (j += 1) {
            //         const a = args[j];
            //         if (std.mem.eql(u8, a, "games") and j + 1 < args.len) {
            //             dg_cfg.games = std.fmt.parseInt(usize, args[j + 1], 10) catch dg_cfg.games; j += 1;
            //         } else if (std.mem.eql(u8, a, "filename") and j + 1 < args.len) {
            //             dg_cfg.filename = args[j + 1]; j += 1;
            //         } else if (std.mem.eql(u8, a, "depth") and j + 1 < args.len) {
            //             dg_cfg.best_depth = std.fmt.parseInt(u32, args[j + 1], 10) catch dg_cfg.best_depth; j += 1;
            //         } else if (std.mem.eql(u8, a, "plies") and j + 1 < args.len) {
            //             dg_cfg.max_plies = std.fmt.parseInt(usize, args[j + 1], 10) catch dg_cfg.max_plies; j += 1;
            //         } else if (std.mem.eql(u8, a, "random") and j + 2 < args.len) {
            //             dg_cfg.first_random = std.fmt.parseInt(usize, args[j + 1], 10) catch dg_cfg.first_random;
            //             dg_cfg.next_mixed = std.fmt.parseInt(usize, args[j + 2], 10) catch dg_cfg.next_mixed;
            //             j += 2;
            //         } else if (std.mem.eql(u8, a, "debug")) {
            //             dg_cfg.debug = true;
            //         } else if (std.mem.eql(u8, a, "strict")) {
            //             dg_cfg.strict = true;
            //         } else if (std.mem.eql(u8, a, "skipnoisy")) {
            //             dg_cfg.skip_noisy = true;
            //         } else if (std.mem.eql(u8, a, "random_min_ply") and j + 1 < args.len) {
            //             dg_cfg.random_min_ply = std.fmt.parseInt(usize, args[j + 1], 10) catch dg_cfg.random_min_ply; j += 1;
            //         } else if (std.mem.eql(u8, a, "random_50_ply") and j + 1 < args.len) {
            //             dg_cfg.random_50_ply = std.fmt.parseInt(usize, args[j + 1], 10) catch dg_cfg.random_50_ply; j += 1;
            //         } else if (std.mem.eql(u8, a, "random_10_ply") and j + 1 < args.len) {
            //             dg_cfg.random_10_ply = std.fmt.parseInt(usize, args[j + 1], 10) catch dg_cfg.random_10_ply; j += 1;
            //         } else if (std.mem.eql(u8, a, "random_move_count") and j + 1 < args.len) {
            //             dg_cfg.random_move_count = std.fmt.parseInt(usize, args[j + 1], 10) catch dg_cfg.random_move_count; j += 1;
            //         } else if (std.mem.eql(u8, a, "save_min_ply") and j + 1 < args.len) {
            //             dg_cfg.save_min_ply = std.fmt.parseInt(usize, args[j + 1], 10) catch dg_cfg.save_min_ply; j += 1;
            //         } else if (std.mem.eql(u8, a, "save_max_ply") and j + 1 < args.len) {
            //             dg_cfg.save_max_ply = std.fmt.parseInt(usize, args[j + 1], 10) catch dg_cfg.save_max_ply; j += 1;
            //         } else if (std.mem.eql(u8, a, "adjudicate_draws_by_score")) {
            //             dg_cfg.adjudicate_draws_by_score = true;
            //         } else if (std.mem.eql(u8, a, "adjudicate_draws_by_insufficient_mating_material")) {
            //             dg_cfg.adjudicate_draws_by_insufficient_mating_material = true;
            //         } else {
            //             // stop parsing at unknown token to allow other modes
            //             break;
            //         }
            //     }
            //     i = j - 1;
        }
        i += 1;
    }

    if (tune) {
        var tuner_instance = tuner.Tuner.new();
        tuner_instance.init();
        try tuner_instance.convertDataset();
    } else if (bench) {
        try uci.bench(allocator, bench_depth);
    } else if (perft_test) {
        try uci.perft_test(allocator);
        // } else if (do_datagen) {
        //     try uci.run_datagen(allocator, dg_cfg);
    } else {
        try uci.uci_loop(allocator);
    }
}
