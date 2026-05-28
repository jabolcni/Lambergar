const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");

const zig_is_016_or_newer = builtin.zig_version.order(.{ .major = 0, .minor = 16, .patch = 0 }) != .lt;

pub const Instant = struct {
    timestamp: if (zig_is_016_or_newer) std.Io.Clock.Timestamp else i128,

    pub fn now() !Instant {
        if (zig_is_016_or_newer) {
            return .{ .timestamp = std.Io.Clock.Timestamp.now(compat.default_io(), .awake) };
        }
        return .{ .timestamp = std.time.nanoTimestamp() };
    }

    pub fn since(self: Instant, earlier: Instant) u64 {
        if (zig_is_016_or_newer) {
            const duration = earlier.timestamp.durationTo(self.timestamp);
            return @intCast(duration.raw.nanoseconds);
        }
        return @intCast(self.timestamp - earlier.timestamp);
    }
};

pub const Timer = struct {
    started_at: Instant,

    pub fn start() !Timer {
        return .{ .started_at = try Instant.now() };
    }

    pub fn read(self: *const Timer) u64 {
        const now = Instant.now() catch unreachable;
        return now.since(self.started_at);
    }

    pub fn reset(self: *Timer) void {
        self.started_at = Instant.now() catch unreachable;
    }
};

pub fn nanoTimestamp() i128 {
    if (zig_is_016_or_newer) {
        return @intCast(std.Io.Clock.Timestamp.now(compat.default_io(), .awake).raw.nanoseconds);
    }
    return std.time.nanoTimestamp();
}
