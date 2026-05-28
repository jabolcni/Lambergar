const std = @import("std");
const position = @import("position.zig");
const search = @import("search.zig");
const uci = @import("uci.zig");

const Move = position.Move;

const MATE_VALUE = search.MATE_VALUE;
const MAX_PLY = search.MAX_PLY;

const AGE_INC: u6 = 1;
const MAX_AGE: u6 = 63;
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

pub const scoreEntry = struct {
    hash_key: u64,
    move: Move, // 16-bits
    score: i32,
    bound: Bound, // 2-bits
    depth: i8,
    age: u6,
    // Publication flag: 0 = invalid/empty, 1 = published. Written last on store with release semantics.
    valid: u8,

    pub fn new(k: u64, m: Move, s: i32, b: Bound, d: i8, a: u6) scoreEntry {
        return scoreEntry{
            .hash_key = k,
            .move = m,
            .score = s,
            .bound = b,
            .depth = d,
            .age = a,
            .valid = if (b == Bound.BOUND_NONE) 0 else 1,
        };
    }
};

pub var tt_allocator = std.heap.smp_allocator;

const SpinLock = struct {
    locked: bool = false,

    fn lock(self: *SpinLock) void {
        while (@atomicRmw(bool, &self.locked, .Xchg, true, .acquire)) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinLock) void {
        @atomicStore(bool, &self.locked, false, .release);
    }
};

pub const BUCKET_SIZE = 2; // Number of entries per bucket

pub const TranspositionTable = struct {
    ttArray: [][BUCKET_SIZE]scoreEntry, // Array of buckets, each holding BUCKET_SIZE entries
    size: u64, // Number of buckets
    mask: u64,
    age: u6,
    locks: []SpinLock, // One lock per group of buckets
    bucket_size: usize, // Used for locking granularity, not bucket size
    lookups: u64 = 0, // Total fetch attempts
    hits: u64 = 0, // Successful fetch hits

    pub fn init(self: *TranspositionTable, size_mb: u64) !void {
        tt_allocator.free(self.ttArray);
        const total_entries = size_mb * MB / @sizeOf(scoreEntry);
        var size = total_entries / BUCKET_SIZE; // Number of buckets
        if (size == 0) size = 1;
        // Round down to the nearest power of two for proper masking
        var v = size;
        v |= v >> 1;
        v |= v >> 2;
        v |= v >> 4;
        v |= v >> 8;
        v |= v >> 16;
        v |= v >> 32;
        const pow2 = (v + 1) >> 1;
        if (uci.debug) {
            std.debug.print("Hash size in buckets: {} (pow2 adjusted)\n", .{pow2});
            std.debug.print("Total entries: {}\n", .{pow2 * BUCKET_SIZE});
            std.debug.print("Hash size in MB: {}\n", .{pow2 * BUCKET_SIZE * @sizeOf(scoreEntry) / MB});
        }
        self.ttArray = try tt_allocator.alloc([BUCKET_SIZE]scoreEntry, pow2);
        self.bucket_size = 4096; // Lock granularity (buckets per lock)
        const num_locks = (pow2 + self.bucket_size - 1) / self.bucket_size;
        self.locks = try tt_allocator.alloc(SpinLock, num_locks);
        for (self.locks) |*lock| lock.* = SpinLock{};
        self.size = pow2;
        self.mask = pow2 - 1;
        self.age = 0;
        self.clear();
    }

    pub fn clear(self: *TranspositionTable) void {
        // Zeroing the array is safe: valid=0 is the "invalid" sentinel checked first
        // in fetch(), so zeroed entries are always skipped without being used.
        @memset(std.mem.sliceAsBytes(self.ttArray), 0);
        self.age = 0;
        self.reset_counters();
    }

    pub fn index(self: *TranspositionTable, hash: u64) u64 {
        return hash & self.mask;
    }

    // pub  fn lock_idx(self: *TranspositionTable, hash: u64) usize {
    //     return self.index(hash) / self.bucket_size;
    // }

    pub fn increase_age(self: *TranspositionTable) void {
        self.locks[0].lock();
        defer self.locks[0].unlock();
        self.age +%= 1;
    }

    pub fn clear_age(self: *TranspositionTable) void {
        self.locks[0].lock();
        defer self.locks[0].unlock();
        self.age = 0;
    }

    pub fn hash_full(self: *TranspositionTable) u16 {
        var count: u16 = 0;
        for (0..1000) |idx| {
            const hash_idx = (idx * 1000) & self.mask;
            const lock_idx = hash_idx / self.bucket_size;
            self.locks[lock_idx].lock();
            defer self.locks[lock_idx].unlock();
            for (self.ttArray[hash_idx]) |entry| {
                if (entry.bound != Bound.BOUND_NONE and entry.age == self.age) {
                    count += 1;
                    break;
                }
            }
        }
        return count;
    }

    pub fn get_hit_rate(self: *TranspositionTable) u64 {
        if (self.lookups == 0) return 0.0;
        //return @as(f32, @floatFromInt(self.hits)) / @as(f32, @floatFromInt(self.lookups)) * 100.0;
        return @divTrunc(self.hits * 1000, self.lookups);
    }

    pub fn reset_counters(self: *TranspositionTable) void {
        self.lookups = 0;
        self.hits = 0;
    }

    pub fn store(self: *TranspositionTable, entry: scoreEntry) void {
        const idx = self.index(entry.hash_key);
        const key = entry.hash_key;
        const current_age = self.age;

        const bucket_ptr = &self.ttArray[idx];

        // Try update in-place if key matches
        var i: usize = 0;
        while (i < BUCKET_SIZE) : (i += 1) {
            const e_ptr = &bucket_ptr.*[i];
            if (e_ptr.hash_key == key) {
                // Invalidate before write
                @atomicStore(u8, &e_ptr.valid, 0, .seq_cst);
                if (!entry.move.is_empty()) e_ptr.move = entry.move;
                e_ptr.hash_key = key;
                e_ptr.score = entry.score;
                e_ptr.depth = entry.depth;
                e_ptr.bound = entry.bound;
                e_ptr.age = current_age;
                // Publish
                const v: u8 = if (entry.bound == Bound.BOUND_NONE) 0 else 1;
                @atomicStore(u8, &e_ptr.valid, v, .release);
                return;
            }
        }

        // Select replacement slot
        var replace_idx: usize = 0;
        var best_value: i32 = std.math.maxInt(i32);
        i = 0;
        while (i < BUCKET_SIZE) : (i += 1) {
            const e = bucket_ptr.*[i];
            const age_diff: i32 = @as(i32, current_age -% e.age);
            // RT-25 result: stronger exact-entry protection looked somewhat worse
            // than baseline, so exact entries do not appear underprotected here.
            //
            // RT-30 result: weaker exact-entry protection looked neutral, so the
            // current baseline exact bonus is kept while the softer age penalty
            // from RT-26 remains active.
            const prefer_exact: i32 = if (e.bound == Bound.BOUND_EXACT) 8 else 0;
            // RT-28 result: explicitly preferring entries that already carry a
            // move looked somewhat worse than baseline, so that extra bonus is
            // not kept.
            // RT-26 result: reducing the replacement age penalty slightly looked
            // promising, especially at longer time control, so that softer age
            // pressure is kept for now.
            //
            // RT-29 result: reducing the age penalty further to age_diff * 2
            // looked neutral, so the milder age_diff * 3 change is kept for now.
            const value = @as(i32, e.depth) - age_diff * 3 + prefer_exact; // lower is worse
            if (value < best_value or e.valid == 0) {
                best_value = value;
                replace_idx = i;
            }
        }

        const tgt = &bucket_ptr.*[replace_idx];
        // Invalidate target then write and publish
        @atomicStore(u8, &tgt.valid, 0, .seq_cst);
        // RT-27 result: dropping stale-move preservation looked somewhat worse than
        // baseline, so the old behavior is kept while replacement scoring is tuned.
        if (!entry.move.is_empty() or tgt.hash_key == key) {
            tgt.move = entry.move;
        }
        tgt.hash_key = key;
        tgt.score = entry.score;
        tgt.depth = entry.depth;
        tgt.bound = entry.bound;
        tgt.age = current_age;
        const v2: u8 = if (entry.bound == Bound.BOUND_NONE) 0 else 1;
        @atomicStore(u8, &tgt.valid, v2, .release);
    }

    // pub  fn store(self: *TranspositionTable, entry: scoreEntry) void {
    //     const idx = self.index(entry.hash_key);
    //     const lock_idx = idx / self.bucket_size;
    //     self.locks[lock_idx].lock();
    //     defer self.locks[lock_idx].unlock();

    //     var bucket = &self.ttArray[idx];
    //     const key = entry.hash_key;
    //     const current_age = self.age;

    //     // Find the best entry to replace (or update if key matches)
    //     var replace_idx: usize = 0;
    //     var best_value: i32 = std.math.maxInt(i32); // Lower value = less valuable

    //     for (bucket, 0..) |*e, i| {
    //         if (e.hash_key == key) {
    //             // If key matches, update this entry directly
    //             if (entry.move.is_empty()) e.move = e.move else e.move = entry.move;
    //             if (entry.bound == Bound.BOUND_EXACT or
    //                 key != e.hash_key or
    //                 entry.depth + 5 > e.depth or
    //                 e.age != current_age)
    //             {
    //                 e.* = entry;
    //             }
    //             return;
    //         }

    //         // Calculate "value" of this entry (lower is less valuable)
    //         //const age_diff = @as(i32, MAX_AGE + current_age - e.age) & MAX_AGE;
    //         const age_diff: i32 = @as(i32, current_age -% e.age);
    //         const value = @as(i32, e.depth) - age_diff * 4;
    //         if (value < best_value) {
    //             best_value = value;
    //             replace_idx = i;
    //         }
    //     }

    //     // Preserve existing move if no new move provided and key differs
    //     if (entry.move.is_empty() and key != bucket[replace_idx].hash_key) {
    //         bucket[replace_idx].move = bucket[replace_idx].move;
    //     } else {
    //         bucket[replace_idx].move = entry.move;
    //     }

    //     // Overwrite if new entry is more valuable
    //     if (entry.bound == Bound.BOUND_EXACT or
    //         key != bucket[replace_idx].hash_key or
    //         entry.depth + 5 > bucket[replace_idx].depth or
    //         bucket[replace_idx].age != current_age)
    //     {
    //         bucket[replace_idx] = entry;
    //     }
    // }

    // pub  fn store(self: *TranspositionTable, entry: scoreEntry) void {
    //     const idx = self.index(entry.hash_key);
    //     const lock_idx = idx / self.bucket_size;
    //     self.locks[lock_idx].lock();
    //     defer self.locks[lock_idx].unlock();
    //     var bucket = &self.ttArray[idx];
    //     var replace_idx: usize = 0;
    //     var min_depth: i8 = 127; // Max i8 value

    //     // Look for empty slot or matching hash key
    //     for (bucket, 0..) |*e, i| {
    //         if (e.hash_key == 0) { // Empty slot
    //             e.* = entry;
    //             return;
    //         }
    //         if (e.hash_key == entry.hash_key) { // Update existing entry
    //             e.* = entry;
    //             return;
    //         }
    //         // Track shallowest depth for replacement
    //         if (e.depth < min_depth) {
    //             min_depth = e.depth;
    //             replace_idx = i;
    //         }
    //     }
    //     // Replace shallowest depth entry if bucket is full
    //     bucket[replace_idx] = entry;
    // }

    pub fn prefetch(self: *TranspositionTable, hash: u64) void {
        @prefetch(&self.ttArray[self.index(hash)], .{
            .rw = .read,
            .locality = 1,
            .cache = .data,
        });
    }

    pub fn prefetch_write(self: *TranspositionTable, hash: u64) void {
        @prefetch(&self.ttArray[self.index(hash)], .{
            .rw = .write,
            .locality = 1,
            .cache = .data,
        });
    }

    pub fn fetch(self: *TranspositionTable, hash: u64) ?scoreEntry {
        const idx = self.index(hash);
        // Lock-free read with publish flag: acquire on valid to see a fully published entry.
        _ = @atomicRmw(u64, &self.lookups, .Add, 1, .seq_cst);

        const bucket_ptr = &self.ttArray[idx];
        var i: usize = 0;
        while (i < BUCKET_SIZE) : (i += 1) {
            const e_ptr = &bucket_ptr.*[i];
            const published = @atomicLoad(u8, &e_ptr.valid, .acquire);
            if (published == 0) continue;

            const snap = e_ptr.*; // snapshot after acquire
            // Recheck publication after snapshot to reduce race effects
            const still_published = @atomicLoad(u8, &e_ptr.valid, .acquire);
            if (still_published == 0) continue;

            if (snap.hash_key == hash and snap.bound != Bound.BOUND_NONE) {
                _ = @atomicRmw(u64, &self.hits, .Add, 1, .seq_cst);
                return snap;
            }
        }
        return null;
    }

    pub fn adjust_hash_score(self: *TranspositionTable, score: i32, ply: u16) i32 {
        _ = self;
        if (score >= MATE_VALUE - MAX_PLY) return score - @as(i32, ply);
        if (score <= -MATE_VALUE + MAX_PLY) return score + @as(i32, ply);
        return score;
    }

    pub fn to_hash_score(self: *TranspositionTable, score: i32, ply: u16) i32 {
        _ = self;
        if (score >= MATE_VALUE - MAX_PLY) return score + @as(i32, ply);
        if (score <= -MATE_VALUE + MAX_PLY) return score - @as(i32, ply);
        return score;
    }

    pub fn deinit(self: *TranspositionTable) void {
        tt_allocator.free(self.ttArray);
        tt_allocator.free(self.locks);
    }
};

pub var TT: TranspositionTable = undefined;
