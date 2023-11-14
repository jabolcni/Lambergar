const std = @import("std");
const position = @import("position.zig");
const search = @import("search.zig");

const Move = position.Move;

const MATE_VALUE = search.MATE_VALUE;
const MAX_PLY = search.MAX_PLY;

const NB_BITS: u8 = 23; // 23...128 MB, 22...64 MB, 21...32 MB, 20...16 MB, 19...8 MB, 18...4 MB, 17...2 MB
pub const HASH_SIZE: u64 = 1 << NB_BITS;
const HASH_MASK: u64 = HASH_SIZE - 1;
const AGE_INC: u6 = 1;

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
    depth: u8,
    age: u6,

    pub fn new(k: u64, m: Move, s: i32, b: Bound, d: u8, a: u6) scoreEntry {
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

pub var tt_allocator = std.heap.ArenaAllocator.init(std.heap.c_allocator);

pub const TranspositionTable = struct {
    ttArray: std.ArrayList(u128),
    size: u64,
    mask: u64,
    age: u6,

    pub fn new() TranspositionTable {
        return TranspositionTable{
            .ttArray = std.ArrayList(u128).init(tt_allocator.allocator()),
            .size = HASH_SIZE,
            .mask = HASH_MASK,
            .age = 0,
        };
    }

    pub fn init(self: *TranspositionTable, size_mb: u64) void {
        self.ttArray.deinit();

        var size: u64 = 1 << NB_BITS;
        const MB: u64 = 1 << 20;
        var nb_bits: u5 = 16;
        if (size_mb > 0) {
            while (((@as(u64, 1) << nb_bits) * @sizeOf(scoreEntry) <= size_mb * MB / 2) and (nb_bits < 29)) : (nb_bits += 1) {}
            size = @as(u64, 1) << nb_bits;
        }

        var tt = TranspositionTable{
            .ttArray = std.ArrayList(u128).init(tt_allocator.allocator()),
            .size = size,
            .mask = size - 1,
            .age = 0,
        };

        tt.ttArray.ensureTotalCapacity(tt.size) catch {};
        tt.ttArray.expandToCapacity();

        self.* = tt;
        self.clear();
    }

    pub inline fn clear(self: *TranspositionTable) void {
        for (self.ttArray.items) |*e| {
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
            var raw = @atomicLoad(u128, &self.ttArray.items[(idx * 1000) & self.mask], .Acquire);
            var entry = @as(*scoreEntry, @ptrCast(&raw)).*;
            if (entry.bound != Bound.BOUND_NONE and entry.age == self.age) {
                count += 1;
            }
        }
        return count;
    }

    inline fn set(self: *TranspositionTable, entry: scoreEntry) void {
        _ = @atomicRmw(u128, &self.ttArray.items[self.index(entry.hash_key)], .Xchg, @as(*const u128, @ptrCast(&entry)).*, .AcqRel);
    }

    pub inline fn store(self: *TranspositionTable, entry: scoreEntry) void {
        var probe_entry = self.get(entry.hash_key);
        if (probe_entry.hash_key == 0 or entry.bound == Bound.BOUND_EXACT or probe_entry.age != self.age or probe_entry.hash_key != entry.hash_key or (entry.depth + 4) > probe_entry.depth) {
            self.set(entry);
        }
    }

    pub inline fn prefetch(self: *TranspositionTable, hash: u64) void {
        @prefetch(&self.ttArray.items[self.index(hash)], .{
            .rw = .read,
            .locality = 1,
            .cache = .data,
        });
    }

    pub inline fn prefetch_write(self: *TranspositionTable, hash: u64) void {
        @prefetch(&self.ttArray.items[self.index(hash)], .{
            .rw = .write,
            .locality = 1,
            .cache = .data,
        });
    }

    inline fn get(self: *TranspositionTable, hash: u64) scoreEntry {
        var raw = @atomicLoad(u128, &self.ttArray.items[self.index(hash)], .Acquire);
        return @as(*scoreEntry, @ptrCast(&raw)).*;
    }

    pub inline fn fetch(self: *TranspositionTable, hash: u64) ?scoreEntry {
        var entry = self.get(hash);
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

pub var TT = TranspositionTable.new();
