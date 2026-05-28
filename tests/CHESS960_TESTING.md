# Chess960 (Fischer Random Chess) Testing

Validation scripts for Chess960/FRC support in Lambergar chess engine.

## Overview

Chess960 (also known as Fischer Random Chess) randomizes the starting position while maintaining certain constraints. These scripts validate that Lambergar correctly handles all 960 possible starting positions.

**Scripts**:
- **check_frc_positions.py**: Validates standard Chess960 positions
- **check_dfrc_positions.py**: Validates Double Fischer Random Chess positions
- **check_frc_perft.py**: Runs FRC perft positions from `frc_perft.csv`
- **check_frc_legality.py**: Smoke-tests Chess960 legal move generation and random walks
- **check_dfrc_csv.py**: Validates curated DFRC positions from `dfrc.csv`
- **check_dfrc_json.py**: Validates combined DFRC analysis PV lines from `dfrc_positions.json`
- **check_dfrc_legality.py**: Smoke-tests sampled DFRC legal move generation and random walks
- **startposfrc.csv**: Reference data for all 960 starting positions

## Scripts

### check_frc_positions.py

**Purpose**: Verify that the engine correctly generates all 960 Chess960 starting positions.

**Usage**:
```bash
# Use default engine and CSV
python tests/check_frc_positions.py

# Specify custom engine
python tests/check_frc_positions.py --engine ./lamb.exe

# Specify custom CSV reference
python tests/check_frc_positions.py --engine ./lamb.exe --csv tests/startposfrc.csv
```

**How It Works**:
1. Loads reference positions from `startposfrc.csv`
2. Connects to engine via UCI
3. For each index (0-959):
   - Sends `position startposfrc <index>` command
   - Engine responds with `info string <white_rank> <black_rank>`
   - Compares against expected position from CSV
4. Reports any mismatches

**Example Output**:
```
Engine: ./lamb.exe
CSV: tests/startposfrc.csv
[1/960] Checking index 0...
[2/960] Checking index 1...
...
[960/960] Checking index 959...

All Chess960 starting positions match the reference.
```

**On Mismatch**:
```
Index 42: expected RNBQKBNR/RNBQKBNR, got RNBKQBNR/RNBKQBNR
1 mismatches detected.
```

### check_dfrc_positions.py

**Purpose**: Validate Double Fischer Random Chess (DFRC) positions where both sides have independent random setups.

**Usage**:
```bash
# Use default engine
python tests/check_dfrc_positions.py

# Specify custom engine
python tests/check_dfrc_positions.py --engine ./lamb.exe
```

**How It Works**:
- Tests all 960 × 960 = 921,600 possible DFRC positions
- Validates that white and black can have different starting positions
- Ensures castling rights are correctly set for asymmetric positions

**Note**: This is a much longer test (can take several minutes).

### check_frc_perft.py

**Purpose**: Run FRC/Chess960 perft positions from `frc_perft.csv` and compare engine node counts with expected values.

**Usage**:
```bash
# Quick check, low depth
python tests/check_frc_perft.py --engine ./zig-out/bin/lambergar.exe --max-depth 2

# Run more deeply; depth 5+ can take much longer
python tests/check_frc_perft.py --engine ./zig-out/bin/lambergar.exe --max-depth 4

# Stop at the first mismatch while debugging
python tests/check_frc_perft.py --engine ./zig-out/bin/lambergar.exe --max-depth 3 --stop-on-fail
```

**How It Works**:
1. Loads `Position ID`, `Shredder FEN`, and `Depth N` columns from CSV
2. Enables `UCI_Chess960`
3. Sends `position fen <Shredder FEN>`
4. Runs `perft <depth>` for each selected depth
5. Reports mismatched node counts and invalid FEN rows

### check_frc_legality.py

**Purpose**: Validate Chess960 legal move generation without any third-party Python dependencies.

**Usage**:
```bash
python tests/check_frc_legality.py --engine ./zig-out/bin/lambergar.exe

# Longer sampled random-walk coverage
python tests/check_frc_legality.py --engine ./zig-out/bin/lambergar.exe --walk-count 256 --walk-plies 40
```

**How It Works**:
1. Enables `UCI_Chess960`
2. Checks all 960 `startposfrc` positions
3. Confirms `validate` legal-move count matches `perft 1`
4. Runs sampled random Chess960 move sequences using the engine legal move list
5. Validates every reached position with the engine's internal legality checker

### check_dfrc_legality.py

**Purpose**: Validate sampled DFRC legal move generation without any third-party Python dependencies.

**Usage**:
```bash
python tests/check_dfrc_legality.py --engine ./zig-out/bin/lambergar.exe

# Longer sampled random-walk coverage
python tests/check_dfrc_legality.py --engine ./zig-out/bin/lambergar.exe --pair-count 1000 --walk-count 256 --walk-plies 40
```

**How It Works**:
1. Enables `UCI_Chess960`
2. Samples deterministic `startposdfrc <white_idx> <black_idx>` pairs
3. Confirms `validate` legal-move count matches `perft 1`
4. Runs sampled random DFRC move sequences using the engine legal move list
5. Validates every reached position with the engine's internal legality checker

### check_dfrc_csv.py

**Purpose**: Validate curated DFRC positions listed in `dfrc.csv`.

**Usage**:
```bash
python tests/check_dfrc_csv.py --engine ./zig-out/bin/lambergar.exe

# Also run perft through a deeper depth for each listed DFRC start
python tests/check_dfrc_csv.py --engine ./zig-out/bin/lambergar.exe --perft-depth 3
```

**How It Works**:
1. Loads `white_id`, `black_id`, `white`, and `black` columns from `dfrc.csv`
2. Sends `position startposdfrc <white_id> <black_id>`
3. Confirms the engine-reported back ranks match the CSV
4. Confirms `validate` legal-move count matches `perft 1`
5. Optionally runs additional perft depths as a stress test

### check_dfrc_json.py

**Purpose**: Validate root PV move lines from the combined `dfrc_positions.json` analysis fixture.

**Usage**:
```bash
python tests/check_dfrc_json.py --engine ./zig-out/bin/lambergar.exe

# Limit checked plies while debugging
python tests/check_dfrc_json.py --engine ./zig-out/bin/lambergar.exe --max-plies 12
```

**How It Works**:
1. Loads combined DFRC analysis positions from `dfrc_positions.json`
2. Uses `params.white_id` and `params.black_id` with `position startposdfrc`
3. Replays each root `analysis.pv` move sequence
4. Confirms each move is present in the engine legal move list before applying it
5. Runs `validate` after each applied move

### startposfrc.csv

**Purpose**: Reference data for all 960 Chess960 starting positions.

**Format**:
```csv
SP;White;Black
0;BBQNNRKR;BBQNNRKR
1;BQNBNRKR;BQNBNRKR
2;BQNNRBKR;BQNNRBKR
...
959;RKRNNQBB;RKRNNQBB
```

**Fields**:
- `SP`: Starting Position index (0-959)
- `White`: White's back rank piece arrangement
- `Black`: Black's back rank piece arrangement

**Chess960 Rules**:
1. Bishops must be on opposite colors
2. King must be between the two rooks
3. All other pieces can be in any order

## UCI Commands

Lambergar supports Chess960 via UCI extensions:

```bash
# Set Chess960 mode
setoption name UCI_Chess960 value true

# Set position by index (0-959)
position startposfrc 518

# Set position by FEN (with chess960 flag)
position fen rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 chess960

# Standard FRC position setup
position startpos chess960
```

## Validation Workflow

### Quick Validation

```bash
# Test a sample of positions
python tests/check_frc_positions.py --engine ./lamb.exe
```

### Complete Validation

```bash
# Test all 960 standard FRC positions
python tests/check_frc_positions.py --engine ./lamb.exe

# Test DFRC (takes longer)
python tests/check_dfrc_positions.py --engine ./lamb.exe
```

### After Code Changes

```bash
# 1. Build engine
zig build -Doptimize=ReleaseFast

# 2. Validate Chess960 support
python tests/check_frc_positions.py --engine ./lamb.exe
python tests/check_frc_perft.py --engine ./lamb.exe --max-depth 3
python tests/check_frc_legality.py --engine ./lamb.exe

# 3. If all pass, run sampled DFRC setup and legality checks
python tests/check_dfrc_positions.py --engine ./lamb.exe --count 1000
python tests/check_dfrc_csv.py --engine ./lamb.exe
python tests/check_dfrc_json.py --engine ./lamb.exe
python tests/check_dfrc_legality.py --engine ./lamb.exe --pair-count 1000
```

## Acceptance Criteria

| Test | Metric | Threshold |
|------|--------|-----------|
| FRC Positions | Match rate | 960/960 (100%) |
| FRC Perft CSV | Node count match | 100% up to selected depth |
| DFRC Positions | Match rate | 100% |
| FRC Legality | `validate` vs `perft 1` | 960/960 (100%) |
| DFRC CSV | Rank match and legality | 100% |
| DFRC JSON | Legal root PV replay | 100% |
| DFRC Legality | `validate` vs `perft 1` | 100% of sampled pairs |
| Castling Rights | Correctness | 100% |
| Position Setup | Valid FEN | 100% |

## Troubleshooting

### "Engine binary not found"

**Solution**:
```bash
# Specify correct path
python tests/check_frc_positions.py --engine ./zig-out/bin/lamb.exe
```

### "CSV file not found"

**Solution**:
```bash
# Ensure startposfrc.csv exists in tests directory
ls tests/startposfrc.csv

# Or specify path explicitly
python tests/check_frc_positions.py --csv tests/startposfrc.csv
```

### Position Mismatches

**Causes**:
- Bug in Chess960 position generation
- Incorrect piece placement logic
- Castling rights calculation error

**Debug**:
```bash
# Test specific position manually
./lamb.exe
uci
position startposfrc 42
# Check output
```

### Castling Rights Issues

**Common Problems**:
- King not between rooks
- Rook positions not tracked correctly
- Chess960 flag not set

**Validation**:
- Ensure king is always between rooks in starting position
- Verify castling rights use correct rook squares
- Check that `UCI_Chess960` option is respected

## Chess960 Implementation Notes

**Key Differences from Standard Chess**:
1. **Castling**: King moves to c-file or g-file, rook jumps over
2. **Position Encoding**: Must track which rook is for which side
3. **FEN Notation**: Castling rights use file letters (e.g., `HAha`)

**Engine Requirements**:
- Support `UCI_Chess960` option
- Handle `position startposfrc <index>` command
- Correctly parse Chess960 FEN strings
- Implement Chess960 castling rules

## Dependencies

- **Python 3.7+**
- **subprocess**: For UCI communication (standard library)
- **csv**: For reading reference positions (standard library)

## Credits

- DFRC JSON analysis positions in `dfrc_positions.json` are credited to [Philipp Schoneville](https://github.com/pschonev).
- FRC perft positions in `frc_perft.csv` are based on the [Chess960 Perft Results](https://www.chessprogramming.org/Chess960_Perft_Results) resource. Credit to Andrew Grant for creating a set of Chess960 perft positions.

## See Also

- [tests/README.md](README.md) - Main testing documentation
- [tests/ENGINE_VALIDATION.md](ENGINE_VALIDATION.md) - Engine validation
- [Chess960 Rules](https://en.wikipedia.org/wiki/Fischer_random_chess)
- [UCI Protocol](https://www.chessprogramming.org/UCI)
