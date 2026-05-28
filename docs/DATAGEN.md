# Data Generation (Datagen)

Generate training data for NNUE or HCE tuning via self-play.

## Quick Start

```bash
# Generate 1000 games at depth 8, HCE evaluation, binhce format
datagen games 1000 depth 8 eval hce format binhce filename training.binhce

# Generate with phase-based sampling (25% opening, 50% endgame)
datagen games 1000 depth 9 phase_prob_opening 0.25 phase_prob_endgame 0.5
```

## Parameters

### Basic

| Parameter | Default | Description |
|-----------|---------|-------------|
| `games N` | 1 | Number of games to generate |
| `depth D` | 8 | Search depth for move selection |
| `plies P` | 400 | Maximum plies per game |
| `filename NAME` | `dataset.bin` | Output filename (extension auto-added) |

### Evaluation & Format

| Parameter | Values | Default | Description |
|-----------|--------|---------|-------------|
| `eval` | `nnue`/`hce` | `nnue` | Evaluation mode |
| `format` | `bin40`/`binhce` | `bin40` | Output format |

**Note:** Format is auto-determined from eval mode if not specified. Use `format binhce` with `eval hce` for HCE training data.

### Randomization

| Parameter | Default | Description |
|-----------|---------|-------------|
| `random_min_ply` | 2 | Start random move injection at this ply |
| `random_50_ply` | 6 | 100% random rate until this ply |
| `random_10_ply` | 16 | 50% random rate from `random_50_ply` to this ply, then 10% |
| `random_move_count` | 5 | Maximum number of random moves per game |

### Position Filtering

| Parameter | Default | Description |
|-----------|---------|-------------|
| `save_min_ply` | 5 | Don't save positions before this ply |
| `save_max_ply` | 400 | Don't save positions after this ply |
| `skipnoisy` | false | Skip positions where best move is capture/promotion |
| `min_nodes N` | 0 | Skip positions with fewer than N nodes searched |

### Phase-Based Sampling

Control the probability of saving positions from each game phase based on material count.

| Parameter | Default | Phase Range | Description |
|-----------|---------|-------------|-------------|
| `phase_prob_opening` | 1.0 | ≥40 | Opening save probability (0.0-1.0) |
| `phase_prob_early_middlegame` | 1.0 | 30-39 | Early middlegame save probability |
| `phase_prob_middlegame` | 1.0 | 20-29 | Middlegame save probability |
| `phase_prob_late_middlegame` | 1.0 | 10-19 | Late middlegame save probability |
| `phase_prob_endgame` | 1.0 | <10 | Endgame save probability |

### Phase Classification
Positions are classified into 5 phases using the existing `pos.eval.phase` value (0-64):
- **Opening** (≥40): Most pieces on board
- **Early Middlegame** (30-39): Light piece trades
- **Middlegame** (20-29): Moderate material
- **Late Middlegame** (10-19): Transitioning to endgame
- **Endgame** (<10): Minimal material

**Phase calculation:** Uses the engine's existing phase value which is based on piece values: Pawn=0, Knight/Bishop=3, Rook=5, Queen=10. This is much more efficient than recounting material.

**Example:**
```bash
# Save 25% of opening, 100% of middlegames, 75% of endgames
datagen games 1000 depth 9 phase_prob_opening 0.25 phase_prob_endgame 0.75
```

### Chess960 / DFRC

Control distribution of starting positions:

```bash
# 40% Standard, 33% Chess960, 27% DFRC (default)
datagen games 1000 std 0.4 frc 0.33 dfrc 0.27

# Standard chess only
datagen games 1000 std 1.0 frc 0.0 dfrc 0.0
```

### Advanced

| Parameter | Default | Description |
|-----------|---------|-------------|
| `dither D` | 0 | Randomize depth by +0 to +D per position |
| `strict` | false | Use strict TT clearing (slower, more deterministic) |
| `debug` | false | Print search info during generation |
| `adjudicate_draws_by_score` | true | Adjudicate draws after 8 plies with \|score\| < 50 |
| `adjudicate_draws_by_insufficient_mating_material` | true | Adjudicate KvK, KNvK, etc. |
| `full_game` | false | Save ALL plies (for validation, ignores filtering) |

## Output Formats

### bin40 (NNUE Format)
40 bytes per position:
- 32 bytes: Packed SFEN (position encoding)
- 2 bytes: Score (i16 centipawns)
- 2 bytes: Move (u16 encoded)
- 2 bytes: Ply (u16)
- 1 byte: Result (i8, from STM perspective: 1=win, 0=draw, -1=loss)
- 1 byte: Padding

### binhce (HCE Format)
1332 bytes per position:
- 40 bytes: Header (same as bin40)
- 1292 bytes: HCE feature vector

## Examples

### HCE Training Data (Recommended)
```bash
# Fast generation with HCE eval, phase-balanced
datagen games 5000 depth 9 eval hce format binhce \
  random_min_ply 4 random_move_count 8 \
  phase_prob_opening 0.3 phase_prob_endgame 0.6 \
  filename hce_training.binhce
```

### NNUE Training Data
```bash
# High-quality NNUE data
datagen games 10000 depth 10 eval nnue format bin40 \
  save_min_ply 8 skipnoisy \
  filename nnue_training.bin
```

### Endgame-Heavy Dataset
```bash
# Focus on endgames
datagen games 2000 depth 12 \
  phase_prob_opening 0.1 \
  phase_prob_early_middlegame 0.2 \
  phase_prob_middlegame 0.3 \
  phase_prob_late_middlegame 0.7 \
  phase_prob_endgame 1.0
```

### Validation Dataset
```bash
# Save every ply for validation
datagen games 100 depth 8 full_game filename validation.bin
```

## Performance

Typical generation speeds:
- **Depth 8 (HCE)**: ~0.7-1.0s per game, ~100-150 positions/game
- **Depth 10 (NNUE)**: ~3-5s per game, ~80-120 positions/game
- **Depth 12 (endgame)**: ~8-15s per game, ~40-80 positions/game

Memory usage: ~50-100MB for the engine, data written incrementally to disk.

## Converting bin40 to binhce

If you generated bin40 data but need HCE features:

```bash
zig-out/bin/bin_to_binhce input.bin output.binhce
```

See [BIN_CONVERTER.md](BIN_CONVERTER.md) for details.

## Validation

Validate generated data:

```bash
zig run src/datagen_validate.zig -- training.bin --csv report.csv
```

See [DataGen Validation.md](DataGenValidation.md) for details.