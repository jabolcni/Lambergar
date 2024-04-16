const std = @import("std");
const uci = @import("uci.zig");
const tuner = @import("tuner.zig");

const tune: bool = false;

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    
    if (tune) {
        var tuner_instance = tuner.Tuner.new();
        tuner_instance.init();
        try tuner_instance.convertDataset();
    } else {
        try uci.uci_loop(allocator);
    }

}
