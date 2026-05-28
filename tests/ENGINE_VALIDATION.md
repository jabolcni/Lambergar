# Engine Validation Scripts

Comprehensive testing and validation scripts for the Lambergar chess engine.

## Overview

These scripts validate engine correctness, UCI compliance, and data generation accuracy:
- **validate_engine.py**: Master validation script with multiple test suites
- **validate_binhce_vs_engine.py**: Verifies data generation accuracy
- **validate_pgn.py**: PGN output validation
- **uci_compliance.py**: UCI protocol compliance testing

## Scripts

### validate_engine.py

**Purpose**: Master validation script with comprehensive test suites.

**Usage**:
```bash
# Run all tests
python tests/validate_engine.py --engine ./lamb.exe --suite all

# Run specific test suite
python tests/validate_engine.py --engine ./lamb.exe --suite perft
python tests/validate_engine.py --engine ./lamb.exe --suite bench
python tests/validate_engine.py --engine ./lamb.exe --suite eval
python tests/validate_engine.py --engine ./lamb.exe --suite compliance
python tests/validate_engine.py --engine ./lamb.exe --suite tactics

# Export results to JSON
python tests/validate_engine.py --engine ./lamb.exe --suite all --output results.json
```

**Test Suites**:

1. **perft** - Move generation validation
   - Quick perft tests (depth 1-6)
   - Validates node counts against known values
   - Detects move generation bugs

2. **perft-long** - Comprehensive perft
   - Extended perft tests (depth 7-8)
   - Longer running but more thorough
   - Catches edge cases

3. **bench** - Performance benchmark
   - NNUE: 6,314,915 nodes @ depth 12
   - HCE: 7,703,679 nodes @ depth 12
   - NPS measurement
   - Must match exactly for regression testing

4. **eval** - Evaluation consistency
   - Tests both NNUE and HCE modes
   - Symmetry: eval(pos) == -eval(flip(pos))
   - Bounds checking
   - Determinism verification

5. **compliance** - UCI protocol
   - 40-step UCI compliance test
   - Protocol handshake
   - Position setup
   - Search commands
   - Output formatting

6. **tactics** - Tactical solving
   - Win At Chess (WAC) test suite
   - Depth 10 search
   - Reports solve percentage

**Example Output**:
```
=== Running Test Suite: all ===

[PERFT] Testing move generation...
✓ Position 1: 20 nodes (depth 1)
✓ Position 2: 400 nodes (depth 2)
...
✓ All perft tests passed

[BENCH] Running benchmark...
✓ NNUE: 6,314,915 nodes (expected: 6,314,915)
✓ HCE: 7,703,679 nodes (expected: 7,703,679)
✓ NPS: 1,850,000 (baseline: 1,800,000 ±2%)

[EVAL] Testing evaluation consistency...
✓ Symmetry: 0 violations
✓ Bounds: 0 out-of-bounds
✓ Determinism: 100% consistent

[COMPLIANCE] UCI protocol validation...
✓ 40/40 steps passed

[TACTICS] Solving tactical positions...
✓ Solved: 85/100 (85%)

=== SUMMARY ===
✓ All validation checks PASSED
```

### validate_binhce_vs_engine.py

**Purpose**: Verify that data generation produces correct HCE features.

**Usage**:
```bash
python tests/validate_binhce_vs_engine.py \
  --binhce dataset.binhce \
  --engine ./lamb.exe \
  --sample 1000
```

**Validation**:
- Reads positions from `.binhce` file
- Recomputes HCE features using engine
- Compares stored vs computed features
- Reports mismatches

**Example Output**:
```
Validating 1000 positions...
Progress: 100/1000 (10%)
Progress: 200/1000 (20%)
...
✓ Feature match: 1000/1000 (100%)
✗ Mismatches: 0
```

### validate_pgn.py

**Purpose**: Validate PGN output from the engine.

**Usage**:
```bash
# Validate PGN file
python tests/validate_pgn.py games.pgn

# Validate with detailed output
python tests/validate_pgn.py games.pgn --verbose
```

**Checks**:
- PGN format correctness
- Header completeness
- Move legality
- Result consistency
- FEN validation

**Example Output**:
```
Validating PGN file: games.pgn
Games found: 1000

Checking game 1/1000...
Checking game 100/1000...
...

=== VALIDATION SUMMARY ===
Total games: 1000
Valid games: 998
Invalid games: 2
  - Game 234: Illegal move e2e5
  - Game 567: Missing result header

✓ 99.8% games valid
```

### uci_compliance.py

**Purpose**: Comprehensive UCI protocol compliance testing.

**Usage**:
```bash
python tests/uci_compliance.py --engine ./lamb.exe
```

**Test Steps** (40 total):
1. Protocol handshake (`uci`, `isready`)
2. Identity reporting (`id name`, `id author`)
3. Option reporting (`option name`)
4. Position setup (`position startpos`, `position fen`)
5. Search commands (`go`, `stop`)
6. Time controls (`go wtime`, `go btime`, `go movetime`)
7. Depth/nodes limits (`go depth`, `go nodes`)
8. Infinite search (`go infinite`)
9. Output validation (`info`, `bestmove`)
10. State management (`ucinewgame`)

**Example Output**:
```
=== UCI COMPLIANCE TEST ===

Step 1/40: Send 'uci' command
✓ Received 'uciok'

Step 2/40: Send 'isready' command
✓ Received 'readyok'

Step 3/40: Check 'id name'
✓ Engine name: Lambergar

...

Step 40/40: Test 'ucinewgame'
✓ Engine resets state

=== SUMMARY ===
✓ 40/40 steps passed
✓ Engine is UCI compliant
```

## Validation Workflow

### After Code Changes

```bash
# 1. Build engine
zig build -Doptimize=ReleaseFast

# 2. Run quick validation
python tests/validate_engine.py --engine ./lamb.exe --suite perft
python tests/validate_engine.py --engine ./lamb.exe --suite bench

# 3. If passed, run full validation
python tests/validate_engine.py --engine ./lamb.exe --suite all
```

### Before Release

```bash
# 1. Full validation suite
python tests/validate_engine.py --engine ./lamb.exe --suite all --output validation_results.json

# 2. UCI compliance
python tests/uci_compliance.py --engine ./lamb.exe

# 3. Data generation validation
./lamb.exe datagen games 1000 depth 8 eval nnue format binhce filename test.binhce
python tests/validate_binhce_vs_engine.py --binhce test.binhce --engine ./lamb.exe --sample 500

# 4. PGN output validation (if applicable)
python tests/validate_pgn.py output_games.pgn
```

## Acceptance Criteria

| Test | Metric | Threshold |
|------|--------|-----------|
| Perft | Node count match | 100% |
| Bench (NNUE) | Nodes | 6,314,915 (exact) |
| Bench (HCE) | Nodes | 7,703,679 (exact) |
| Bench | NPS | ±2% of baseline |
| Eval Symmetry | Violations | 0 |
| Eval Bounds | Out-of-bounds | 0 |
| UCI Compliance | Steps passed | 40/40 |
| Tactics (WAC) | Solve rate | ≥80% |
| HCE Features | Match rate | 100% |
| PGN Validity | Valid games | ≥99% |

## Troubleshooting

### Perft Failures

**Symptom**: Node count mismatch

**Debug**:
```bash
# Use perftdiv to isolate problematic move
./lamb.exe
> position startpos
> perftdiv 5
```

**Common Causes**:
- Move generation bug
- Illegal move generation
- Missing move types (en passant, castling, promotions)

### Bench Node Count Mismatch

**Symptom**: Different node count than baseline

**Causes**:
- Search algorithm change (intentional)
- Evaluation change affecting move ordering
- TT size/behavior change
- Bug in search or evaluation

**Action**:
- If intentional, update baseline in test script
- If unintentional, bisect to find regression

### UCI Compliance Failures

**Symptom**: Failed UCI compliance steps

**Common Issues**:
- Missing `uciok` or `readyok` responses
- Incorrect `info` line format
- Missing `bestmove` after search
- Not responding to `stop` command

**Debug**:
```bash
# Manual UCI testing
./lamb.exe
uci
isready
position startpos
go depth 10
stop
quit
```

### HCE Feature Mismatches

**Symptom**: Features don't match between file and engine

**Causes**:
- Engine version mismatch
- Bug in feature extraction
- Corrupted data file

**Solution**:
```bash
# Regenerate data with current engine
./lamb.exe datagen games 1000 depth 8 eval nnue format binhce filename new_test.binhce
python tests/validate_binhce_vs_engine.py --binhce new_test.binhce --engine ./lamb.exe
```

## Dependencies

- **Python 3.7+**
- **python-chess**: For move validation and PGN parsing
  ```bash
  pip install chess
  ```

## See Also

- [tests/README.md](README.md) - Main testing documentation
- [tests/DATA_VALIDATION.md](DATA_VALIDATION.md) - Data format validation
- [tests/TABLEBASE_TESTING.md](TABLEBASE_TESTING.md) - Tablebase testing
- [tests/CROSS_PLATFORM_TESTING.md](CROSS_PLATFORM_TESTING.md) - Cross-platform testing
