const std = @import("std");
const position = @import("position.zig");

pub const PRNG = struct {
    s: u64,

    pub fn init(seed: u64) PRNG {
        return PRNG{ .s = seed };
    }

    pub fn rand64(self: *PRNG) u64 {
        self.s ^= self.s >> 12;
        self.s ^= self.s << 25;
        self.s ^= self.s >> 27;
        //return self.s *% 2685821657736338717;
        return self.s *% 0x2545F4914F6CDD1;
    }

    pub fn sparse_rand64(self: *PRNG) u64 {
        return self.rand64() & self.rand64() & self.rand64();
    }

    // Generate pseudorandom number
    pub fn rand(self: *PRNG, comptime T: type) T {
        return @as(T, @intCast(self.rand64()));
    }

    // Generate pseudorandom number with only a few set bits
    pub fn sparse_rand(self: *PRNG, comptime T: type) T {
        return @as(T, @intCast(self.rand64() & self.rand64() & self.rand64()));
    }
};

pub var zobrist_table: [position.NPIECES][64]u64 = std.mem.zeroes([position.NPIECES][64]u64);
pub var enpassant_keys: [8]u64 = std.mem.zeroes([8]u64);
pub var castling_keys: [16]u64 = std.mem.zeroes([16]u64);
pub var side_key: u64 = 0;

pub fn initialise_zobrist_keys() void {
    var rng = PRNG.init(14974698296094900119);

    side_key = rng.rand64();

    for (0..8) |file| {
        enpassant_keys[file] = rng.rand64();
    }

    for (0..16) |i| {
        castling_keys[i] = rng.rand64();
    }

    for (0..6) |piece| {
        for (0..64) |square| {
            zobrist_table[piece][square] = rng.rand64();
        }
    }

    for (8..14) |piece| {
        for (0..64) |square| {
            zobrist_table[piece][square] = rng.rand64();
        }
    }
}
