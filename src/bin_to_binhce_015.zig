const std = @import("std");
const position = @import("position.zig");
const tuner = @import("tuner.zig");
const datagen_writer = @import("datagen_writer.zig");
const evaluation = @import("evaluation.zig");
const compat = @import("compat.zig");

const Position = position.Position;

const Bin40Record = extern struct {
    sfen32: [32]u8,
    score: i16,
    move16: u16,
    ply: u16,
    result: i8,
    padding: u8,
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 3) {
        std.debug.print("Usage: {s} <input.bin> <output.binhce>\n", .{args[0]});
        std.debug.print("Converts bin40 format to binhce format by extracting HCE features\n", .{});
        return error.InvalidArgs;
    }

    try convertBinToBinhce(args[1], args[2]);
}

fn convertBinToBinhce(input_path: []const u8, output_path: []const u8) !void {
    const input_file = try compat.cwdOpenFile(input_path);
    defer compat.closeFile(input_file);

    const file_size = try compat.fileStatSize(input_file);
    const record_size = @sizeOf(Bin40Record);

    if (file_size % record_size != 0) {
        std.debug.print("Error: Invalid file size {} (not multiple of {})\n", .{ file_size, record_size });
        return error.InvalidFormat;
    }

    const num_records = file_size / record_size;
    std.debug.print("Converting {d} records from {s} to {s}\n", .{ num_records, input_path, output_path });

    var writer = try datagen_writer.BinHceWriter.open(output_path);
    defer writer.close();

    const TunerFields = std.meta.fields(tuner.Tuner);
    const feature_size = comptime blk: {
        var s: usize = 0;
        for (TunerFields) |f| {
            if (!std.mem.eql(u8, f.name, "pos_count")) s += @sizeOf(f.type);
        }
        break :blk s;
    };
    std.debug.print("HCE Record Size: {d} bytes (header: 40, features: {d})\n", .{ 40 + feature_size, feature_size });

    const attacks = @import("attacks.zig");
    attacks.initialise_all_databases();
    evaluation.init_eval();

    const chunk_size = 4096;
    var buffer = try std.heap.page_allocator.alloc(u8, chunk_size * record_size);
    defer std.heap.page_allocator.free(buffer);

    var records_processed: usize = 0;
    var file_offset: usize = 0;

    while (file_offset < file_size) {
        const bytes_to_read = @min(chunk_size * record_size, file_size - file_offset);
        const bytes_read = try compat.fileReadAtShort(input_file, file_offset, buffer[0..bytes_to_read]);
        if (bytes_read == 0) break;

        var offset: usize = 0;
        while (offset + record_size <= bytes_read) {
            const record_bytes = buffer[offset .. offset + record_size];
            const record: *const Bin40Record = @ptrCast(@alignCast(record_bytes.ptr));
            try processRecord(record, &writer);
            records_processed += 1;
            offset += record_size;

            if (records_processed % 10000 == 0) {
                std.debug.print("\rProcessed {}/{} records ({d:.1}%)...", .{
                    records_processed,
                    num_records,
                    @as(f64, @floatFromInt(records_processed)) * 100.0 / @as(f64, @floatFromInt(num_records)),
                });
            }
        }

        file_offset += offset;
    }

    std.debug.print("\nDone! Converted {} records\n", .{records_processed});
}

fn processRecord(record: *const Bin40Record, writer: *datagen_writer.BinHceWriter) !void {
    var pos = Position.new();
    datagen_writer.unpack_sfen32(&record.sfen32, &pos);

    var tnr = tuner.Tuner{};
    tnr.init();
    var eval_state = evaluation.Evaluation{};
    _ = eval_state.clean_eval(&pos, &tnr);

    try writer.write_packed(
        &record.sfen32,
        record.score,
        record.move16,
        record.ply,
        record.result,
        &tnr,
    );
}
