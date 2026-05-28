# Engine Validation & Testing Suite

Comprehensive testing and validation framework for the Lambergar chess engine.

## Overview

This suite provides multi-layered validation covering:
1. **Functional Correctness**: Perft, evaluation consistency, search determinism
2. **Performance Benchmarking**: Node counts, NPS tracking
3. **Data Quality**: Training data validation for HCE tuning

## Quick Start

### Prerequisites

- Compiled Lambergar engine (`lamb.exe` or `lambergar`)
- Python 3.7+ (for validation scripts)
- Zig 0.15.1 (for building with tests)

### Running Tests

#### 1. Engine Validation

```bash
# Run all validation tests (quick)
python tests/validate_engine.py --engine ./lamb.exe --suite all

# Run specific test suite
python tests/validate_engine.py --engine ./lamb.exe --suite perft
python tests/validate_engine.py --engine ./lamb.exe --suite perft-long  # Comprehensive perft
python tests/validate_engine.py --engine ./lamb.exe --suite bench
python tests/validate_engine.py --engine ./lamb.exe --suite eval
python tests/validate_engine.py --engine ./lamb.exe --suite compliance  # UCI protocol check
python tests/validate_engine.py --engine ./lamb.exe --suite tactics     # Tactical test (WAC)

# Visualize HCE features for a position
python tests/visualize_hce.py --engine ./lamb.exe --fen "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

# Export results to JSON
python tests/validate_engine.py --engine ./lamb.exe --output results.json
```

#### 2. Data Generation Validation

```bash
# Validate binhce training data
python tests/datagen_validator.py --binhce dataset.binhce --engine ./lamb.exe --sample 1000

**Baselines**: 
- **bench** (NNUE): 6,314,915 nodes @ depth 12
- **benchhce** (HCE): 7,703,679 nodes @ depth 12

**Metrics**:
- Total nodes (must match exactly)
- Nodes per second (NPS)
- Time to completion

**Acceptance**: Exact node count match, NPS within ±2% of baseline

### Evaluation Consistency

Tests evaluation function for:
- **Modes**: Both NNUE and HCE
- **Symmetry**: `eval(pos) == -eval(flip(pos))`
- **Bounds**: All evals within `[-MAX_SCORE, MAX_SCORE]`
- **Determinism**: Repeated evaluations produce identical results

**Acceptance**: Zero violations in either mode

### UCI Compliance

Verifies adherence to the UCI protocol (based on fastchess compliance tests).

**Checks (40 steps)**:
- Protocol handshake (`uci`, `isready`)
- Identity reporting (`id name`, `id author`)
- Position setup (`startpos`, `fen`)
- Search commands (`go wtime`, `go infinite`, etc.)
- Output formatting (valid `info` lines, `bestmove`)
- State management (`ucinewgame`)

**Acceptance**: All 40 steps passed successfully

### Tactical Test Suite

Tests the engine's ability to find tactical shots in standard positions (e.g., Win At Chess).

**Usage**:
```bash
# Run default sample (WAC) at depth 10
python tests/validate_engine.py --engine ./lamb.exe --suite tactics

# Run custom suite at depth 12
python tests/validate_engine.py --engine ./lamb.exe --suite tactics --epd tests/suites/my_suite.epd --depth 12
```

**Requirements**:
- `pip install python-chess` (recommended for robust EPD parsing)

**Acceptance**: High percentage of solved positions (e.g., >80% for WAC)

### HCE Visualization Tool

Debugs the Hand-Crafted Evaluation (HCE) by visualizing active features for a given position.

**Usage**:
```bash
python tests/visualize_hce.py --engine ./lamb.exe --fen "<FEN>"
```

**Output**:
- Material counts
- Pawn structure features (Passed, Isolated, Phalanx, etc.)
- Mobility stats (e.g., "2 Knights with 4 moves")
- Attacking stats
- Misc features (Bishop Pair, Doubled Pawns)

### Data Quality Validation

For binhce training data files:

**Checks**:
1. **HCE Feature Correctness**: Compare stored features with engine recomputation
2. **Score Distribution**: Detect outliers (|score| > 2500)
3. **Phase Balance**: Report opening/middlegame/endgame distribution
4. **Result Distribution**: White wins / draws / black wins

**Acceptance**:
- 100% feature match
- No score outliers
- Balanced phase distribution (recommended: 60% middlegame, 15% opening, 25% endgame)

## Validation Workflow

### After Major Development

```bash
# 1. Build engine
zig build

# 2. Run validation suite
python tests/validate_engine.py --engine ./lamb.exe --suite all

# 3. If all pass, proceed with testing
# If failures, investigate and fix
```

### Before Tuning HCE Parameters

```bash
# 1. Generate training data
./lamb.exe datagen --games 10000 --format binhce --eval-mode HCE --output train.binhce

# 2. Validate data quality
python tests/datagen_validator.py --binhce train.binhce --engine ./lamb.exe --sample 1000

# 3. If validation passes, proceed with tuning
python tuner/train_hce.py --input train.binhce --output tuned_hce_params.zig

# 4. Validate tuned parameters (see below)
```

### After Parameter Tuning

```bash
# 1. Compile with new parameters
cp tuned_hce_params.zig src/hce_params.zig
zig build

# 2. Verify functional correctness (node count must match)
python tests/validate_engine.py --engine ./lamb.exe --suite bench

# 3. Test strength (self-play or tactical suites)
# Use external tools like fastchess for this
```

## File Structure

```
tests/
├── validate_engine.py       # Master validation script
├── datagen_validator.py     # Data quality validation
├── validate_binhce_vs_engine.py  # Existing binhce validator
├── bin2plain_validate.py    # Existing bin40 validator
├── binhce2plain.py          # Existing binhce reader
└── suites/                  # Test position suites (future)
    ├── perft_suite.epd
    └── tactical_suite.epd

src/
└── test_suite.zig           # Zig test harness (evaluation tests)
```

## Integration with CI/CD

### GitHub Actions Example

```yaml
name: Engine Validation

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      
      - name: Setup Zig
        uses: goto-bus-stop/setup-zig@v2
        with:
          version: 0.15.1
      
      - name: Build Engine
        run: zig build
      
      - name: Run Validation
        run: |
          python tests/validate_engine.py --engine ./zig-out/bin/lambergar --suite all --output results.json
      
      - name: Upload Results
        uses: actions/upload-artifact@v2
        with:
          name: validation-results
          path: results.json
```

## Acceptance Criteria Summary

| Test | Metric | Threshold |
|------|--------|-----------|
| Perft | Node count match | 100% |
| Perft-long | Completion | Success |
| Bench (NNUE) | Node count | 6,314,915 |
| BenchHCE | Node count | 7,703,679 |
| Bench | NPS | ±2% of baseline |
| Eval Symmetry | Violations | 0 |
| Eval Bounds | Out-of-bounds | 0 |
| UCI Compliance | Steps Passed | 40/40 |
| Tactics (WAC) | Solved % | >80% |
| Data HCE Features | Mismatches | 0 |
| Data Scores | Outliers (>\|2500\|) | 0 |

## Conclusion

This validation suite provides a comprehensive safety net for engine development. It covers:
1. **Correctness**: Perft and UCI compliance.
2. **Performance**: Benchmarks for both NNUE and HCE.
3. **Evaluation**: Consistency checks and feature visualization.
4. **Strength**: Tactical solving ability.

Run the full suite before every major commit or release! 🚀

## Troubleshooting

### Perft Failures

**Symptom**: Node count mismatch

**Causes**:
- Move generation bug
- Illegal move generation
- Missing move types (en passant, castling)

**Fix**: Use `perftdiv` command to isolate problematic move

### Bench Node Count Mismatch

**Symptom**: Different node count than baseline

**Causes**:
- Search algorithm change
- Evaluation change affecting move ordering
- TT size/behavior change

**Fix**: If intentional, update baseline. If not, bisect to find regression.

### HCE Feature Mismatches

**Symptom**: Features from binhce don't match engine recomputation

**Causes**:
- Bug in feature extraction during datagen
- Bug in sfen32 packing/unpacking
- HCE parameters changed between datagen and validation

**Fix**: Regenerate data with current engine version

## Future Enhancements

- [ ] Automated regression detection with bisect
- [ ] Performance tracking database (SQLite)
- [ ] HTML dashboard for metrics visualization
- [ ] Integration with OpenBench for distributed testing
- [ ] Tactical test suite runner (WAC, STS)
- [ ] Self-play strength testing framework

## Cross-Platform Testing

For building and testing on Linux from Windows, see:
- **[Cross-Platform Testing Guide](CROSS_PLATFORM_TESTING.md)** - Linux builds, WSL deployment, UCI compliance

## References

- [Validation Strategy](../C:/Users/janezp/.gemini/antigravity/brain/a8bede9b-addf-408a-9e89-d1b0a2707181/validation_strategy.md)
- [Implementation Plan](../C:/Users/janezp/.gemini/antigravity/brain/a8bede9b-addf-408a-9e89-d1b0a2707181/implementation_plan.md)
- [Cross-Platform Testing Guide](CROSS_PLATFORM_TESTING.md)
- [Chess Programming Wiki - Perft](https://www.chessprogramming.org/Perft)
- [Chess Programming Wiki - Engine Testing](https://www.chessprogramming.org/Engine_Testing)

## License

Same as Lambergar engine (MIT License)
