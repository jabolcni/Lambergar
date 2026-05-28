# Bin to BinHCE Converter

Converts bin40 format (NNUE training data) to binhce format (HCE training data) by extracting HCE features from positions.

## Purpose

Optimizes HCE training data generation:
1. Generate bin40 files quickly using HCE self-play at depth 9
2. Convert bin40 → binhce offline by extracting HCE features
3. Reuse bin40 data when adding new HCE features - just reconvert

## Build

```bash
zig build bin-converter
```

This creates `zig-out/bin/bin_to_binhce.exe` (or `bin_to_binhce` on Linux/Mac).

## Usage

```bash
bin_to_binhce <input.bin> <output.binhce>
```

**Example:**
```bash
zig-out/bin/bin_to_binhce data/selfplay.bin data/training.binhce
```

## What It Does

For each position in the bin40 file:
1. Unpacks the sfen32 (compressed position)
2. Runs HCE evaluation to extract all features
3. Writes 40-byte header + 1292-byte feature vector to binhce

## Performance

- Processes in 4096-record chunks for efficiency
- Shows progress every 10,000 positions
- Typical speed: ~50k-100k positions/second

## File Formats

**Input (bin40):** 40 bytes per record
- 32 bytes: packed sfen (position)
- 2 bytes: score (i16)
- 2 bytes: move (u16)
- 2 bytes: ply (u16)
- 1 byte: result (i8)
- 1 byte: padding

**Output (binhce):** 1332 bytes per record
- 40 bytes: header (same as bin40)
- 1292 bytes: HCE feature vector
