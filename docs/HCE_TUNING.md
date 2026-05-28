# HCE Tuning Guide

Comprehensive guide for tuning Hand-Crafted Evaluation (HCE) parameters in Lambergar chess engine.

## Table of Contents

1. [Overview](#overview)
2. [Quick Start](#quick-start)
3. [Data Generation](#data-generation)
4. [Training Methods](#training-methods)
5. [Error Analysis](#error-analysis)
6. [Advanced Topics](#advanced-topics)
7. [Troubleshooting](#troubleshooting)

---

## Overview

### Key Improvements

This tuning system implements several critical improvements over basic approaches:

1. **Blended Loss Function**: Combines game results with search scores for better gradients
2. **PyTorch Acceleration**: GPU-enabled mini-batch training (10-100x faster)
3. **Quality Datagen**: Depth dithering and node filtering for cleaner training data
4. **Error Analysis**: Diagnostic tools to identify evaluation weaknesses

### Architecture

```
┌─────────────────┐
│  Self-Play      │ → Generate positions with search scores
│  (datagen)      │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  .binhce File   │ → Binary format with features + scores
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Training       │ → Optimize parameters (PyTorch or NumPy)
│  (train_hce)    │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  hce_params.zig │ → Export to engine
└─────────────────┘
```

---

## Quick Start

### Prerequisites

```bash
# Python dependencies
pip install numpy chess torch matplotlib

# Build the engine
zig build -Doptimize=ReleaseFast
```

### Basic Workflow

```bash
# 1. Generate training data (10k games, depth 8)
./zig-out/bin/Lambergar.exe
> datagen games 10000 depth 8 eval hce format binhce filename dataset.binhce

# 2. Train HCE parameters (PyTorch, fast)
python tuner/train_hce_torch.py --binhce dataset.binhce --epochs 100 --batch-size 4096

# 3. Copy parameters to engine
cp tuned_hce_params.zig src/hce_params.zig

# 4. Rebuild and test
zig build -Doptimize=ReleaseFast
./zig-out/bin/Lambergar.exe
> bench 12
```

---

## Data Generation

### Basic Usage

```bash
datagen games <N> depth <D> eval <MODE> format <FORMAT> filename <FILE>
```

**Key Parameters:**

| Parameter | Description | Recommended |
|-----------|-------------|-------------|
| `games` | Number of games to play | 10,000-50,000 |
| `depth` | Search depth per move | 8-10 |
| `eval` | Evaluation mode (`nnue` or `hce`) | `nnue` (stronger) |
| `format` | Output format | `binhce` |
| `skipnoisy` | Skip captures/checks | **Always use** |

### Quality Improvements

#### Depth Dithering

Randomizes search depth to avoid horizon effects:

```bash
datagen games 10000 depth 8 dither 2 ...
```

This searches depth 8, 9, or 10 randomly, preventing the engine from being "blind" to tactics at exactly depth 9.

#### Node Filtering

Skips positions where search finished too quickly (unreliable scores):

```bash
datagen games 10000 depth 8 min_nodes 5000 ...
```

Ensures each saved position had at least 5,000 nodes searched (thoughtful evaluation).

### Recommended Command

```bash
datagen games 20000 depth 8 dither 2 min_nodes 5000 skipnoisy eval nnue format binhce filename dataset_hq.binhce
```

**Why these settings?**
- `depth 8 dither 2`: Varied depth prevents horizon artifacts
- `min_nodes 5000`: Filters instant hash cutoffs
- `skipnoisy`: Critical for HCE (no tactical noise)
- `eval nnue`: Stronger scores than HCE during datagen

### Data Conversion & Fixing
If you have data with missing features, use the `bin-converter` to regenerate the `binhce` file using the latest engine evaluation logic.

```bash
# 1. Build the converter
zig build bin-converter -Doptimize=ReleaseFast

# 2. Convert old .bin (moves) to new .binhce (features)
./zig-out/bin/bin_to_binhce input_games.bin output_fixed.binhce
```
This is the **recommended way** to fix data issues caused by engine bugs during the original self-play generation.

## Training Methods

### PyTorch

**Usage:**

```bash
python tuner/train_hce_torch.py \
  --binhce dataset.binhce \
  --epochs 100 \
  --batch-size 4096 \
  --lr 0.01 \
  --alpha 0.5 \
  --lambda-l2 1e-5 \
  --device cuda

python3.12 tuner/train_hce_torch.py --binhce dataset4.binhce --epochs 5000 --batch-size 4096 --lr 0.01 --alpha 1.0 --lambda-l2 0


python tuner/train_hce_torch.py --binhce dataset3.binhce --epochs 5000 --batch-size 4096 --lr 0.01 --alpha 1.0 --lambda-l2 0 --device cuda


```

**Parameters:**

| Flag | Description | Default | Tuning Tips |
|------|-------------|---------|-------------|
| `--epochs` | Training iterations | 100 | More for large datasets |
| `--batch-size` | Samples per update | 4096 | Larger = faster, needs more RAM |
| `--lr` | Learning rate | 0.01 | Reduce if loss oscillates |
| `--alpha` | Blending factor | 0.5 | 0.0=score only, 1.0=result only |
| `--lambda-l2` | Regularization | 1e-5 | Increase to prevent overfitting |
| `--k-factor` | Score scaling | 0.004 | Usually don't change |
| `--min-legal-moves` | Min legal moves filter | 0 | Skip forced positions (e.g., 10) |
| `--max-material-imbalance` | Max material imbalance | 999 | Skip unbalanced positions (e.g., 3) |
| `--no-phase-balancing` | Disable phase balancing | False | Use all data (good for small datasets) |

**Output:**
- `tuned_hce_params.zig`: Engine parameters
- `hce_model.pth`: PyTorch checkpoint (for analysis)
- `runs/hce_training`: TensorBoard logs

### TensorBoard Monitoring

Training automatically logs to TensorBoard for real-time monitoring:

```bash
# Start training (in one terminal)
python tuner/train_hce_torch.py --binhce dataset.binhce --epochs 100

# View TensorBoard (in another terminal)
tensorboard --logdir=runs
```

Then open http://localhost:6006 in your browser.

**Metrics logged:**
- Training loss per epoch
- Validation loss per epoch
- Learning rate changes

**Benefits:**
- Real-time loss curves
- Compare multiple training runs
- Identify overfitting early
- Monitor learning rate schedule

### NumPy (Baseline)

Slower but no GPU required:

```bash
python tuner/train_hce.py \
  --binhce dataset.binhce \
  --epochs 5000 \
  --lr 0.005 \
  --alpha 0.5
```

### Understanding the Blended Loss

**Problem:** Game results (W/D/L) are noisy. A position might be +0.5 pawns but the game was lost due to a blunder 20 moves later.

**Solution:** Blend game result with search score:

```
Target = α × Result + (1 - α) × Sigmoid(Score)
```

- `α = 1.0`: Pure supervised learning (noisy, needs huge datasets)
- `α = 0.0`: Pure score regression (ignores actual outcomes)
- `α = 0.5`: **Recommended balance**

**Example:**

| Position | Result | Score | α=1.0 Target | α=0.5 Target | α=0.0 Target |
|----------|--------|-------|--------------|--------------|--------------|
| Winning  | 1.0    | +200  | 1.0          | 0.87         | 0.73         |
| Equal    | 0.5    | +10   | 0.5          | 0.51         | 0.52         |
| Losing   | 0.0    | -150  | 0.0          | 0.18         | 0.36         |

The blended target provides smoother gradients than pure results.

## Incremental Training

### Resuming from Checkpoint

Continue training from a previous session without losing progress:

```bash
# Initial training
python tuner/train_hce_torch.py --binhce dataset.binhce --epochs 50

# Continue for 50 more epochs
python tuner/train_hce_torch.py --binhce dataset.binhce --epochs 50 --resume hce_model.pth
```

**Use Cases:**

1. **Adding New Data**: Train on initial dataset, then add more games and continue
2. **Fine-Tuning**: Start with broad learning, then resume with lower LR for refinement
3. **Interrupted Training**: Resume if training was stopped (power loss, etc.)

**What's Preserved:**
- Model weights (all parameters)
- Optimizer state (momentum, adaptive learning rates)
- Feature scaling factors

**Example Workflow:**

```bash
# Stage 1: Initial training (100k positions)
python tuner/train_hce_torch.py --binhce data_v1.binhce --epochs 100

# Stage 2: Add more data and continue (200k total)
python tuner/train_hce_torch.py --binhce data_v2.binhce --epochs 50 --resume hce_model.pth --lr 0.005

# Stage 3: Final fine-tuning with reduced LR
python tuner/train_hce_torch.py --binhce data_v2.binhce --epochs 25 --resume hce_model.pth --lr 0.001
```

> **Note:** When resuming, the scale factors from the checkpoint are used. Ensure the new dataset has compatible features.

---

## Advanced Topics

### Feature Engineering

Current features (see `src/tuner.zig`):

- Material (6 pieces × 2 phases)
- Piece-Square Tables (6 pieces × 64 squares × 2 phases)
- Passed pawns (64 squares × 2 phases)
- Isolated pawns (8 files × 2 phases)
- Mobility (4 pieces × variable bins × 2 phases)
- Threats (5 attackers × 6 targets × 2 phases)
- Bishop pair, doubled pawns
- Backward pawn, blockade passer
- Connected rooks, rook on open/semi-open file
- King safety (pawn shield, storm, virtual mobility)
- Knight/Bishop outposts
- Trapped pieces (Bishop, Rook)
- Candidate pawns, rook behind passer

**Adding New Features:**

1. Update `src/tuner.zig` to count the feature
2. Update `tuner/train_hce.py` SHAPES list
3. Regenerate dataset
4. Retrain


## Appendix

### File Formats

#### .binhce Format

Binary format storing:
- FEN (32 bytes, compressed)
- Best move (2 bytes)
- Search score (4 bytes, centipawns)
- Game result (1 byte: -1/0/+1)
- Ply number (2 bytes)
- HCE features (variable, ~1KB)

**Reading:**
```python
import binhce_reader

for record in binhce_reader.iter_binhce("dataset.binhce"):
    print(record.fen, record.score, record.result)
```

### Parameter Export Format

`tuned_hce_params.zig` example:

```zig
// Auto-generated HCE parameters
pub const TEMPO = 15;
pub const mg_tempo = 15;
pub const eg_tempo = 0;

pub const material_mg = [6]i32{ 100, 320, 330, 500, 900, 0 };
pub const material_eg = [6]i32{ 100, 320, 330, 500, 900, 0 };

pub const mg_pawn_table = [64]i32{ /* ... */ };
// ... etc
```

Values are in centipawns (cp), scaled by 100 internally.

### Performance Benchmarks

**Training Speed** (50k positions, 100 epochs):

| Method | Hardware | Time |
|--------|----------|------|
| NumPy | CPU (8 cores) | ~2 hours |
| PyTorch (CPU) | CPU (8 cores) | ~20 min |
| PyTorch (GPU) | RTX 3080 | ~2 min |