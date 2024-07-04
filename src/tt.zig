const std = @import("std");
const position = @import("position.zig");
const search = @import("search.zig");
const uci = @import("uci.zig");

const Move = position.Move;

const MATE_VALUE = search.MATE_VALUE;
const MAX_PLY = search.MAX_PLY;

const AGE_INC: u6 = 1;
const MB: u64 = 1 << 20;

pub const perftEntry = packed struct {
    hash_key: u64,
    nodes: u60,
    depth: u4,

    pub fn new(k: u64, d: u4, c: u64) perftEntry {
        return perftEntry{
            .hash_key = k,
            .nodes = c,
            .depth = d,
        };
    }
};

pub const Bound = enum(u2) {
    BOUND_NONE = 0,
    BOUND_EXACT = 1,
    BOUND_UPPER = 2,
    BOUND_LOWER = 3,
};

pub const scoreEntry = packed struct {
    hash_key: u64,
    move: Move, // 16-bits
    score: i32,
    bound: Bound, // 2-bits
    depth: i8,
    age: u6,

    pub fn new(k: u64, m: Move, s: i32, b: Bound, d: i8, a: u6) scoreEntry {
        return scoreEntry{
            .hash_key = k,
            .move = m,
            .score = s,
            .bound = b,
            .depth = d,
            .age = a,
        };
    }
};

pub var tt_allocator = std.heap.c_allocator;

pub const TranspositionTable = struct {
    ttArray: []u128,
    size: u64,
    mask: u64,
    age: u6,

    pub fn init(self: *TranspositionTable, size_mb: u64) !void {
        tt_allocator.free(self.ttArray);

        const size: usize = @as(usize, 1) << (std.math.log2_int(usize, size_mb * MB / @sizeOf(scoreEntry)));

        if (uci.debug) {
            std.debug.print("Hash size in item numbers: {}\n", .{size});
            std.debug.print("Hash size in MB: {}\n", .{size * @sizeOf(scoreEntry) / MB});
            std.debug.print("Hash size in bytes: {}\n", .{size * @sizeOf(scoreEntry)});
        }

        // const tt = TranspositionTable{
        //     .ttArray = tt_allocator.alloc(u128, size) catch unreachable,
        //     .size = size,
        //     .mask = size - 1,
        //     .age = 0,
        // };

        // self.* = tt;
        self.ttArray = try tt_allocator.alloc(u128, size);
        self.size = size;
        self.mask = size - 1;
        self.age = 0;

        self.clear();
    }

    pub inline fn clear(self: *TranspositionTable) void {
        for (self.ttArray) |*e| {
            e.* = 0;
        }
        self.age = 0;
    }

    pub inline fn index(self: *TranspositionTable, hash: u64) u64 {
        //return hash % self.size;
        return hash & self.mask;
        //return ((hash & 0xFFFFFFFF) * self.size) >> 32;
    }

    pub inline fn increase_age(self: *TranspositionTable) void {
        self.age +%= 1;
    }

    pub inline fn clear_age(self: *TranspositionTable) void {
        self.age = 0;
    }

    pub inline fn hash_full(self: *TranspositionTable) u16 {
        var count: u16 = 0;
        for (0..1000) |idx| {
            // For modern win arhitectures
            //var raw = @atomicLoad(u128, &self.ttArray.items[(idx * 1000) & self.mask], .Acquire);
            //var entry = @as(*scoreEntry, @ptrCast(&raw)).*;
            // For Linux binaries
            const entry = @as(*scoreEntry, @as(*scoreEntry, @ptrCast(&self.ttArray[(idx * 1000) & self.mask]))).*;

            if (entry.bound != Bound.BOUND_NONE and entry.age == self.age) {
                count += 1;
            }
        }
        return count;
    }

    inline fn set(self: *TranspositionTable, entry: scoreEntry) void {
        // For modern win arhitectures
        //_ = @atomicRmw(u128, &self.ttArray[self.index(entry.hash_key)], .Xchg, @as(*const u128, @ptrCast(&entry)).*, .acquire);
        // For Linux binaries
        const p = &self.ttArray[self.index(entry.hash_key)];
        _ = @atomicRmw(u64, @as(*u64, @ptrFromInt(@intFromPtr(p))), .Xchg, @as(*u64, @ptrFromInt(@intFromPtr(&entry))).*, .acquire);
        _ = @atomicRmw(u64, @as(*u64, @ptrFromInt(@intFromPtr(p) + 8)), .Xchg, @as(*u64, @ptrFromInt(@intFromPtr(&entry) + 8)).*, .acquire);
    }

    pub inline fn store(self: *TranspositionTable, entry: scoreEntry) void {
        const probe_entry = self.get(entry.hash_key);
        if (probe_entry.hash_key == 0 or entry.bound == Bound.BOUND_EXACT or probe_entry.age != self.age or probe_entry.hash_key != entry.hash_key or (entry.depth + 4) > probe_entry.depth) {
            self.set(entry);
        }
    }

    pub inline fn prefetch(self: *TranspositionTable, hash: u64) void {
        @prefetch(&self.ttArray[self.index(hash)], .{
            .rw = .read,
            .locality = 1,
            .cache = .data,
        });
    }

    pub inline fn prefetch_write(self: *TranspositionTable, hash: u64) void {
        @prefetch(&self.ttArray[self.index(hash)], .{
            .rw = .write,
            .locality = 1,
            .cache = .data,
        });
    }

    inline fn get(self: *TranspositionTable, hash: u64) scoreEntry {
        // For modern win arhitectures
        //var raw = @atomicLoad(u128, &self.ttArray[self.index(hash)], .acquire);
        //return @as(*scoreEntry, @ptrCast(&raw)).*;
        // For Linux binaries
        return @as(*scoreEntry, @as(*scoreEntry, @ptrCast(&self.ttArray[self.index(hash)]))).*;
    }

    pub inline fn fetch(self: *TranspositionTable, hash: u64) ?scoreEntry {
        //_ = self;
        //_ = hash;
        const entry = self.get(hash);
        if (entry.hash_key == hash and entry.bound != Bound.BOUND_NONE) return entry;
        return null;
    }

    pub inline fn adjust_hash_score(self: *TranspositionTable, score: i32, ply: u16) i32 {
        _ = self;
        if (score >= MATE_VALUE - MAX_PLY) {
            return score - @as(i32, ply);
        } else if (score <= -MATE_VALUE + MAX_PLY) {
            return score + @as(i32, ply);
        }
        return score;
    }

    pub inline fn to_hash_score(self: *TranspositionTable, score: i32, ply: u16) i32 {
        _ = self;
        if (score >= MATE_VALUE - MAX_PLY) {
            return score + ply;
        } else if (score <= -MATE_VALUE + MAX_PLY) {
            return score - ply;
        }
        return score;
    }
};

pub var TT: TranspositionTable = undefined;
