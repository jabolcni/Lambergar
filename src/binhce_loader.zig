const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");

// BinHCE record structure (must match datagen_writer.zig)
// Total: 40 bytes header + 1168 bytes features = 1208 bytes (extern struct padding)
// Using extern struct for C ABI compatibility
const FEATURE_SIZE = 1536;

const BinHCERecord = extern struct {
    sfen32: [32]u8, // Packed SFEN (32 bytes)
    score: i16, // Score in centipawns (2 bytes)
    move16: u16, // Encoded move (2 bytes)
    ply: u16, // Game ply (2 bytes)
    result: i8, // Game result from STM perspective (1 byte)
    padding: u8, // Padding (1 byte)
    features: [FEATURE_SIZE]u8, // HCE feature vector (1536 bytes)
};

// C API structures for Python
pub const LoadedData = extern struct {
    sfen32s: ?[*]u8, // Flattened SFEN32 (32 bytes each)
    scores: ?[*]i16,
    move16s: ?[*]u16,
    plies: ?[*]u16,
    results: ?[*]i8,
    features: ?[*]u8, // Flattened features (1536 bytes each)
    count: usize,
};

// Error codes for C API
pub const LoadError = enum(c_int) {
    Success = 0,
    FileNotFound = 1,
    OutOfMemory = 2,
    InvalidFormat = 3,
    ReadError = 4,
};

// Global allocator for C API
const allocator = std.heap.c_allocator;

fn file_read_all(file: compat.File, offset: u64, buffer: []u8) !void {
    try compat.fileReadAtAll(file, offset, buffer);
}

// Load binhce file and return data arrays
// Caller must call binhce_free() to release memory
export fn binhce_load(path: [*:0]const u8, load_features: bool, out_data: *LoadedData) LoadError {
    const path_slice = std.mem.span(path);

    // Open file
    const file = compat.cwdOpenFile(path_slice) catch |err| {
        std.debug.print("Failed to open file: {}\n", .{err});
        return LoadError.FileNotFound;
    };
    defer compat.closeFile(file);

    // Get file size
    const total_size = compat.fileStatSize(file) catch return LoadError.ReadError;
    const record_size = @sizeOf(BinHCERecord);
    const num_records = total_size / record_size;

    if (total_size % record_size != 0) {
        std.debug.print("Invalid file size: {} (not multiple of {})\n", .{ total_size, record_size });
        return LoadError.InvalidFormat;
    }

    std.debug.print("Loading {} records from {s}...\n", .{ num_records, path_slice });

    // Allocate output arrays
    const sfen32s = allocator.alloc(u8, num_records * 32) catch return LoadError.OutOfMemory;
    const scores = allocator.alloc(i16, num_records) catch return LoadError.OutOfMemory;
    const move16s = allocator.alloc(u16, num_records) catch return LoadError.OutOfMemory;
    const plies = allocator.alloc(u16, num_records) catch return LoadError.OutOfMemory;
    const results = allocator.alloc(i8, num_records) catch return LoadError.OutOfMemory;
    var features: []u8 = undefined;
    if (load_features) {
        features = allocator.alloc(u8, num_records * FEATURE_SIZE) catch return LoadError.OutOfMemory;
    } else {
        features = @as([*]u8, undefined)[0..0];
    }

    // Read file in chunks for better performance
    const chunk_size = 1024 * 1024; // 1MB chunks
    var buffer = allocator.alloc(u8, chunk_size) catch return LoadError.OutOfMemory;
    defer allocator.free(buffer);
    var records_read: usize = 0;
    var file_offset: usize = 0;

    while (file_offset < total_size) {
        const bytes_to_read = @min(chunk_size, total_size - file_offset);
        const bytes_read = compat.fileReadAtShort(file, file_offset, buffer[0..bytes_to_read]) catch return LoadError.ReadError;

        if (bytes_read == 0) break;

        // Parse records from buffer
        var offset: usize = 0;
        while (offset + record_size <= bytes_read) {
            const record_bytes = buffer[offset .. offset + record_size];
            const record: *const BinHCERecord = @ptrCast(@alignCast(record_bytes.ptr));

            // Copy data to output arrays
            const idx = records_read;
            @memcpy(sfen32s[idx * 32 ..][0..32], &record.sfen32);
            scores[idx] = record.score;
            move16s[idx] = record.move16;
            plies[idx] = record.ply;
            results[idx] = record.result;
            if (load_features) {
                @memcpy(features[idx * FEATURE_SIZE ..][0..FEATURE_SIZE], &record.features);
            }

            records_read += 1;
            offset += record_size;
        }

        // IMPORTANT: Only advance file_offset by the amount of data we actually PROCESSED.
        // Since record_size (1332) doesn't divide chunk_size (1MB) evenly, there will be
        // a partial record at the end of the buffer. We must not skip it.
        file_offset += offset;

        // Progress reporting every 100k records
        if (records_read % 100000 == 0) {
            std.debug.print("  Loaded {}/{} records...\n", .{ records_read, num_records });
        }
    }

    std.debug.print("Successfully loaded {} records\n", .{records_read});

    // Fill output structure
    out_data.sfen32s = sfen32s.ptr;
    out_data.scores = scores.ptr;
    out_data.move16s = move16s.ptr;
    out_data.plies = plies.ptr;
    out_data.results = results.ptr;
    out_data.features = if (load_features) features.ptr else null;
    out_data.count = records_read;

    return LoadError.Success;
}

// Free memory allocated by binhce_load
export fn binhce_free(data: *LoadedData) void {
    if (data.count == 0) return;

    if (data.sfen32s) |p| allocator.free(p[0 .. data.count * 32]);
    if (data.scores) |p| allocator.free(p[0..data.count]);
    if (data.move16s) |p| allocator.free(p[0..data.count]);
    if (data.plies) |p| allocator.free(p[0..data.count]);
    if (data.results) |p| allocator.free(p[0..data.count]);
    if (data.features) |p| allocator.free(p[0 .. data.count * FEATURE_SIZE]);

    data.count = 0;
}

// Load specific records from binhce file by index
// Caller must call binhce_free() to release memory
export fn binhce_load_selective(path: [*:0]const u8, indices: [*]const usize, index_count: usize, out_data: *LoadedData) LoadError {
    const path_slice = std.mem.span(path);

    // Open file
    const file = compat.cwdOpenFile(path_slice) catch |err| {
        std.debug.print("Failed to open file: {}\n", .{err});
        return LoadError.FileNotFound;
    };
    defer compat.closeFile(file);

    const record_size = @sizeOf(BinHCERecord);

    // Allocate output arrays for exactly index_count records
    const sfen32s = allocator.alloc(u8, index_count * 32) catch return LoadError.OutOfMemory;
    const scores = allocator.alloc(i16, index_count) catch return LoadError.OutOfMemory;
    const move16s = allocator.alloc(u16, index_count) catch return LoadError.OutOfMemory;
    const plies = allocator.alloc(u16, index_count) catch return LoadError.OutOfMemory;
    const results = allocator.alloc(i8, index_count) catch return LoadError.OutOfMemory;
    const features = allocator.alloc(u8, index_count * FEATURE_SIZE) catch return LoadError.OutOfMemory;

    var record: BinHCERecord = undefined;
    const record_bytes = std.mem.asBytes(&record);

    for (indices[0..index_count], 0..) |file_idx, out_idx| {
        const offset = file_idx * record_size;
        file_read_all(file, offset, record_bytes) catch return LoadError.ReadError;

        @memcpy(sfen32s[out_idx * 32 ..][0..32], &record.sfen32);
        scores[out_idx] = record.score;
        move16s[out_idx] = record.move16;
        plies[out_idx] = record.ply;
        results[out_idx] = record.result;
        @memcpy(features[out_idx * FEATURE_SIZE ..][0..FEATURE_SIZE], &record.features);

        if (out_idx % 100000 == 0 and out_idx > 0) {
            std.debug.print("  Loaded {}/{} selective records...\n", .{ out_idx, index_count });
        }
    }

    std.debug.print("Successfully loaded {} selective records\n", .{index_count});

    // Fill output structure
    out_data.sfen32s = sfen32s.ptr;
    out_data.scores = scores.ptr;
    out_data.move16s = move16s.ptr;
    out_data.plies = plies.ptr;
    out_data.results = results.ptr;
    out_data.features = features.ptr;
    out_data.count = index_count;

    return LoadError.Success;
}

// Get version string
export fn binhce_version() [*:0]const u8 {
    return "1.0.0";
}
