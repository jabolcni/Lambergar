# Endgame Tablebase Testing

Comprehensive testing suite for Syzygy endgame tablebase integration in Lambergar.

## Overview

Lambergar supports Syzygy endgame tablebases using the Fathom library. This test suite validates:
- WDL (Win/Draw/Loss) probing accuracy
- DTZ (Distance to Zero) calculations
- Best move selection in tablebase positions
- Performance and correctness

## Test Scripts

### WDL Probing Tests

**`egtb_wdl_code.py`** - Basic WDL Probing
```bash
python tests/egtb_wdl_code.py --engine ./lamb.exe --syzygy-path /path/to/syzygy
```
- Tests WDL probing accuracy
- Verifies correct Win/Draw/Loss determination
- Compares engine probing with known tablebase results

**`egtb_wdl_from_random.py`** - Random Position WDL Testing
```bash
python tests/egtb_wdl_from_random.py --engine ./lamb.exe --syzygy-path /path/to/syzygy --positions 1000
```
- Generates random endgame positions
- Probes WDL for each position
- Validates consistency across multiple positions

### WDL + DTZ Testing

**`egtb_wdl_dtz_from_random.py`** - Combined WDL and DTZ Testing
```bash
python tests/egtb_wdl_dtz_from_random.py --engine ./lamb.exe --syzygy-path /path/to/syzygy
```
- Tests both WDL and DTZ probing
- Verifies distance-to-zero calculations
- Ensures optimal play in tablebase positions
- Validates 50-move rule handling

### Position Generation

**`egtb_generate_random_engame_positions.py`** - Test Position Generator
```bash
python tests/egtb_generate_random_engame_positions.py --output endgame_positions.epd --count 1000
```
- Generates random legal endgame positions
- Outputs in EPD format
- Configurable material combinations
- Used for creating custom test suites

### Position Analysis

**`egtb_analyze_random_engame_positions.py`** - Position Analyzer
```bash
python tests/egtb_analyze_random_engame_positions.py --epd endgame_positions.epd --syzygy-path /path/to/syzygy
```
- Analyzes positions from EPD file
- Reports WDL/DTZ statistics
- Identifies interesting positions (e.g., longest wins)
- Validates tablebase coverage

### Best Move Validation

**`egtb_bm.py`** - Best Move Testing
```bash
python tests/egtb_bm.py --engine ./lamb.exe --syzygy-path /path/to/syzygy --epd tb_sm.epd
```
- Tests engine's best move selection in tablebase positions
- Verifies optimal play according to tablebases
- Reports percentage of correct moves
- Identifies positions where engine deviates from tablebase

## Test Position Files

### endgame_positions.epd (73 KB)
- Collection of endgame positions for testing
- Various material configurations (KPK, KQKR, KBNK, etc.)
- Known WDL/DTZ results for validation
- Generated from master games and composed positions

### tb_sm.epd (17 KB)
- Curated tablebase test suite
- Positions requiring precise play
- Used for best move validation
- Includes difficult endgames (fortresses, zugzwang, etc.)

## UCI Commands

Lambergar supports standard UCI tablebase commands:

```bash
# Set tablebase path
setoption name SyzygyPath value /path/to/syzygy

# Set probe depth (default: 1)
# Engine will probe tablebases when remaining pieces <= this value
setoption name SyzygyProbeDepth value 6

# Non-standard: Probe current position for WDL
probe

# Non-standard: Get best move and full analysis from tablebase
probebest
```

## Example Workflow

### Complete Tablebase Validation

```bash
# 1. Generate test positions
python tests/egtb_generate_random_engame_positions.py \
  --output test_positions.epd \
  --count 500

# 2. Analyze positions
python tests/egtb_analyze_random_engame_positions.py \
  --epd test_positions.epd \
  --syzygy-path ./syzygy

# 3. Test WDL probing
python tests/egtb_wdl_from_random.py \
  --engine ./lamb.exe \
  --syzygy-path ./syzygy \
  --positions 500

# 4. Test best move selection
python tests/egtb_bm.py \
  --engine ./lamb.exe \
  --syzygy-path ./syzygy \
  --epd test_positions.epd

# 5. Full WDL+DTZ validation
python tests/egtb_wdl_dtz_from_random.py \
  --engine ./lamb.exe \
  --syzygy-path ./syzygy
```

### Quick Validation

```bash
# Run basic WDL test with existing positions
python tests/egtb_wdl_code.py \
  --engine ./lamb.exe \
  --syzygy-path ./syzygy

# Test best moves on standard suite
python tests/egtb_bm.py \
  --engine ./lamb.exe \
  --syzygy-path ./syzygy \
  --epd tests/tb_sm.epd
```

## Acceptance Criteria

| Test | Metric | Threshold |
|------|--------|-----------|
| WDL Probing | Accuracy | 100% |
| DTZ Calculation | Correctness | 100% |
| Best Move | Optimal selection | ≥95% |
| Probe Performance | Overhead | <5% of search time |
| Coverage | Supported pieces | Up to 6-man |

## Troubleshooting

### "Tablebase not found"

**Causes:**
- Incorrect `SyzygyPath` setting
- Missing tablebase files
- File permission issues

**Solutions:**
```bash
# Verify path
ls /path/to/syzygy/*.rtbw

# Set path in UCI
setoption name SyzygyPath value /correct/path/to/syzygy

# Check permissions
chmod 644 /path/to/syzygy/*
```

### "Incorrect WDL result"

**Causes:**
- Corrupted tablebase files
- Wrong piece configuration
- 50-move rule edge case

**Solutions:**
- Re-download tablebase files
- Verify position legality
- Check 50-move counter in FEN

### "Slow tablebase probing"

**Causes:**
- High `SyzygyProbeDepth` setting
- Slow disk I/O
- Insufficient RAM for caching

**Solutions:**
```bash
# Reduce probe depth for faster games
setoption name SyzygyProbeDepth value 4

# Use SSD for tablebase storage
# Ensure sufficient RAM (16GB+ recommended for 6-man)
```

### "Best move mismatch"

**Causes:**
- Engine search finds alternative optimal move
- DTZ tie-breaking differences
- Tablebase vs engine evaluation mismatch

**Solutions:**
- Check if both moves are optimal (same DTZ)
- Verify tablebase is up-to-date
- Compare with other engines

## Performance Notes

- **Probe Overhead**: Typically <1% when `SyzygyProbeDepth` is set appropriately
- **Cache Hit Rate**: ~80-90% in typical endgames
- **Disk I/O**: SSD recommended for 6-man tablebases
- **Memory Usage**: ~500MB per 6-man tablebase set

## References

- [Syzygy Tablebases](https://syzygy-tables.info/)
- [Fathom Library](https://github.com/jdart1/Fathom)
- [Chess Programming Wiki - Endgame Tablebases](https://www.chessprogramming.org/Endgame_Tablebases)

## See Also

- [tests/README.md](README.md) - Main testing documentation
- [tests/CROSS_PLATFORM_TESTING.md](CROSS_PLATFORM_TESTING.md) - Cross-platform testing guide
