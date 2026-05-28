const std = @import("std");
const builtin = @import("builtin");

pub const zig_is_016_or_newer = builtin.zig_version.order(.{ .major = 0, .minor = 16, .patch = 0 }) != .lt;

pub const File = if (zig_is_016_or_newer) std.Io.File else std.fs.File;
pub const FileReader = if (zig_is_016_or_newer) std.Io.File.Reader else std.fs.File.Reader;
pub const FileWriter = if (zig_is_016_or_newer) std.Io.File.Writer else std.fs.File.Writer;

pub fn default_io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn stdinReader(buffer: []u8) FileReader {
    if (zig_is_016_or_newer) {
        return std.Io.File.stdin().reader(default_io(), buffer);
    }
    return std.fs.File.stdin().reader(buffer);
}

pub fn stdoutWriter(buffer: []u8) FileWriter {
    if (zig_is_016_or_newer) {
        return std.Io.File.stdout().writer(default_io(), buffer);
    }
    return std.fs.File.stdout().writer(buffer);
}

pub fn cwdOpenFile(path: []const u8) !File {
    if (zig_is_016_or_newer) {
        return std.Io.Dir.cwd().openFile(default_io(), path, .{});
    }
    return std.fs.cwd().openFile(path, .{});
}

pub fn cwdOpenReadonlyFile(path: []const u8) !File {
    return cwdOpenFile(path);
}

pub fn cwdCreateTruncateFile(path: []const u8) !File {
    if (zig_is_016_or_newer) {
        return std.Io.Dir.cwd().createFile(default_io(), path, .{ .read = false, .truncate = true });
    }
    return std.fs.cwd().createFile(path, .{ .read = false, .truncate = true });
}

pub fn closeFile(file: File) void {
    if (zig_is_016_or_newer) {
        file.close(default_io());
    } else {
        file.close();
    }
}

pub fn fileStatSize(file: File) !u64 {
    if (zig_is_016_or_newer) {
        return (try file.stat(default_io())).size;
    }
    return (try file.stat()).size;
}

pub fn fileReadAll(file: File, buffer: []u8) !usize {
    if (zig_is_016_or_newer) {
        var reader = file.reader(default_io(), &.{});
        try reader.interface.readSliceAll(buffer);
        return buffer.len;
    }
    return file.readAll(buffer);
}

pub fn fileReadAtAll(file: File, offset: u64, buffer: []u8) !void {
    if (zig_is_016_or_newer) {
        var reader = file.reader(default_io(), &.{});
        try reader.seekTo(offset);
        try reader.interface.readSliceAll(buffer);
    } else {
        _ = try file.preadAll(buffer, offset);
    }
}

pub fn fileReadAtShort(file: File, offset: u64, buffer: []u8) !usize {
    if (zig_is_016_or_newer) {
        var reader = file.reader(default_io(), &.{});
        try reader.seekTo(offset);
        return reader.interface.readSliceShort(buffer);
    }
    return file.pread(buffer, offset);
}

pub fn fileWriteAll(file: File, bytes: []const u8) !void {
    if (zig_is_016_or_newer) {
        var writer = file.writer(default_io(), &.{});
        try writer.interface.writeAll(bytes);
        try writer.interface.flush();
    } else {
        try file.writeAll(bytes);
    }
}

pub fn accessAbsolute(path: []const u8) !void {
    if (zig_is_016_or_newer) {
        try std.Io.Dir.accessAbsolute(default_io(), path, .{});
    } else {
        try std.fs.accessAbsolute(path, .{});
    }
}

pub fn takeDelimiter(reader: *std.Io.Reader, delimiter: u8) !?[]u8 {
    if (zig_is_016_or_newer) {
        return try reader.takeDelimiter(delimiter);
    }
    return reader.*.takeDelimiterExclusive(delimiter) catch |err| switch (err) {
        error.EndOfStream => null,
        else => return err,
    };
}
