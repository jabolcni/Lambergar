const std = @import("std");
const uci = @import("uci.zig");
const tuner = @import("tuner.zig");

const tune: bool = false;

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    var bench: bool = false;
    var bench_depth: u32 = 12;

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
        }
        i += 1;
    }

    if (tune) {
        var tuner_instance = tuner.Tuner.new();
        tuner_instance.init();
        try tuner_instance.convertDataset();
    } else if (bench) {
        try uci.bench(allocator, bench_depth);
    } else {
        try uci.uci_loop(allocator);
    }
}
