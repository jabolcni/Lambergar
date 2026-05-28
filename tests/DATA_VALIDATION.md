# Data Format Validation

Comprehensive validation tools for binary training data formats used in Lambergar's HCE tuning pipeline.

## Overview

These scripts validate the integrity and correctness of binary training data files:
- **bin2plain_validate.py**: Validates `.bin` format (legacy binary format)
- **binhce2plain.py**: Converts `.binhce` format to human-readable plain text
- **datagen_validator.py**: Comprehensive validation of `.binhce` training data

## Scripts

### bin2plain_validate.py

**Purpose**: Validate legacy `.bin` format training data and convert to plain text.

**Usage**:
```bash
python tests/bin2plain_validate.py test.bin
```

**Features**:
- Decodes compressed position format (SFEN32)
- Validates move legality
- Counts move types (normal, promotions, castling, en passant)
- Detects illegal moves and position errors
- Outputs human-readable `.plain` file

**Output Statistics**:
```
=== FINAL STATISTICS ===
Total positions processed: 50000
Move type distribution:
  Normal moves: 42150 (84.3%)
  Promotions: 1250 (2.5%)
  Castling: 3200 (6.4%)
  En passant: 3400 (6.8%)
Total errors: 0
✓ All moves validated successfully!
```

**Output Format** (`.plain` file):
```
fen rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1
move e2e4
score 25
ply 1
result 1
e
```

### binhce2plain.py

**Purpose**: Convert `.binhce` format to human-readable plain text with HCE features.

**Usage**:
```bash
# Convert specific file
python tests/binhce2plain.py dataset.binhce

# Convert with command-line argument
python tests/binhce2plain.py path/to/dataset.binhce
```

**Features**:
- Decodes SFEN32 compressed positions
- Extracts HCE feature vectors (1168 features)
- Converts to FEN notation
- Decodes move encoding
- Preserves score, ply, and result information

**Output Format** (`.plainhce` file):
```
fen rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1
move e2e4
score 25
ply 1
result 1
hce 1,0,1,0,1,0,1,0,1,0,1,0,0,0,0,0,...
e
```

**Progress Output**:
```
Progress: 1000 positions processed
Progress: 2000 positions processed
...
Done. Positions processed: 50000
Output written to dataset.plainhce
```

### datagen_validator.py

**Purpose**: Comprehensive validation of `.binhce` training data quality and correctness.

**Usage**:
```bash
# Basic validation
python tests/datagen_validator.py --binhce dataset.binhce --engine ./lamb.exe --sample 1000

# Verbose output
python tests/datagen_validator.py --binhce dataset.binhce --engine ./lamb.exe --sample 1000 --verbose
```

**Arguments**:
- `--binhce`: Path to `.binhce` file to validate
- `--engine`: Path to Lambergar engine executable
- `--sample`: Number of positions to validate (default: 1000)
- `--verbose`: Enable verbose output

**Validation Checks**:

1. **HCE Feature Correctness**
   - Compares stored features with engine recomputation
   - Validates feature extraction accuracy
   - Reports mismatches

2. **Score Distribution**
   - Min/max/mean score analysis
   - Detects outliers (|score| > 2500 cp)
   - Identifies unrealistic evaluations

3. **Phase Balance**
   - Opening positions (< 20 ply)
   - Middlegame positions (20-60 ply)
   - Endgame positions (> 60 ply)
   - Reports percentage distribution

4. **Result Distribution**
   - White wins / Draws / Black wins
   - Percentage breakdown
   - Balance check

**Example Output**:
```
=== Validating binhce file: dataset.binhce ===

File size: 125.45 MB
Total entries: 50,000

Reading sample (1000 entries)...
Read 1000 entries

Validating HCE features (sample size: 100)...

HCE Feature Validation: 100 passed, 0 failed

=== Score Distribution ===
  Min: -450
  Max: 520
  Mean: 15.3
  Outliers (>2500): 0
  Outliers (<-2500): 0

=== Phase Distribution ===
  Opening (<20 ply):   150 (15.0%)
  Middlegame (20-60):  600 (60.0%)
  Endgame (>60):       250 (25.0%)

=== Result Distribution ===
  White wins:  420 (42.0%)
  Draws:       350 (35.0%)
  Black wins:  230 (23.0%)

=== Validation Summary ===
✓ All validation checks PASSED
```

## File Formats

### .bin Format (Legacy)

**Structure**:
```
Position (32 bytes):
  - SFEN32 compressed position
  
Extra Data (8 bytes):
  - score (int16): Evaluation in centipawns
  - move (uint16): Best move encoding
  - ply (uint16): Game ply number
  - result (int8): Game result (-1/0/+1)
  - padding (uint8): Alignment
```

### .binhce Format (Current)

**Structure**:
```
Position (32 bytes):
  - SFEN32 compressed position
  
Extra Data (8 bytes):
  - score (int16): Evaluation in centipawns
  - move (uint16): Best move encoding
  - ply (uint16): Game ply number
  - result (int8): Game result (-1/0/+1)
  - padding (uint8): Alignment
  
HCE Features (1168 bytes):
  - Material counts (12 bytes)
  - PSQT features (768 bytes)
  - Pawn structure (160 bytes)
  - Mobility (132 bytes)
  - Attacking features (60 bytes)
  - Misc features (36 bytes)
```

**Total Entry Size**: 1208 bytes

### SFEN32 Encoding

Compressed position format (32 bytes):
- Side to move (1 bit)
- King squares (12 bits)
- Piece placement (variable, Huffman encoded)
- Castling rights (4 bits)
- En passant square (7 bits)
- Halfmove clock (7 bits)
- Fullmove number (17 bits)

## Validation Workflow

### Before Training

```bash
# 1. Generate training data
./lamb.exe datagen games 10000 depth 8 eval nnue format binhce filename dataset.binhce

# 2. Validate data quality
python tests/datagen_validator.py \
  --binhce dataset.binhce \
  --engine ./lamb.exe \
  --sample 1000

# 3. If validation passes, proceed with training
python tuner/train_hce_torch.py --binhce dataset.binhce --epochs 250
```

### Debugging Data Issues

```bash
# 1. Convert to plain text for inspection
python tests/binhce2plain.py dataset.binhce

# 2. Examine plain text file
head -n 50 dataset.plainhce

# 3. Validate specific positions
python tests/datagen_validator.py \
  --binhce dataset.binhce \
  --engine ./lamb.exe \
  --sample 100 \
  --verbose
```

## Acceptance Criteria

| Check | Metric | Threshold |
|-------|--------|-----------|
| HCE Features | Match rate | 100% |
| Score Outliers | Count | 0 |
| Phase Balance | Middlegame % | 50-70% |
| Result Balance | White wins % | 35-50% |
| Move Legality | Illegal moves | 0 |

## Troubleshooting

### "HCE feature mismatch"

**Causes**:
- Engine version mismatch between datagen and validation
- Corrupted `.binhce` file
- Bug in feature extraction

**Solutions**:
```bash
# Regenerate data with current engine
./lamb.exe datagen games 10000 depth 8 eval nnue format binhce filename new_dataset.binhce

# Validate with same engine
python tests/datagen_validator.py --binhce new_dataset.binhce --engine ./lamb.exe
```

### "Score outliers detected"

**Causes**:
- Mate scores included (normal if rare)
- Evaluation bug
- Corrupted data

**Solutions**:
- Check if outliers are mate scores (acceptable)
- If many outliers, regenerate data with `skipnoisy` flag
- Inspect outlier positions manually

### "Unbalanced phase distribution"

**Causes**:
- Too many short games (opening-heavy)
- Too many long games (endgame-heavy)
- Incorrect ply counting

**Solutions**:
- Adjust game length in datagen
- Use depth dithering for variety
- Filter by ply range if needed

## Dependencies

- **Python 3.7+**
- **python-chess**: For FEN parsing and move validation
  ```bash
  pip install chess
  ```
- **numpy**: For binary data handling
  ```bash
  pip install numpy
  ```

## See Also

- [tests/README.md](README.md) - Main testing documentation
- [automation/README.md](../automation/README.md) - Automated tuning pipeline
- [tuner/README.md](../tuner/README.md) - Training scripts reference
