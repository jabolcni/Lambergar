# Automated HCE Tuning Pipeline

This directory contains scripts for fully automating the tuning of Lambergar's HCE parameters.

## Prerequisites

- **OS**: Linux (scripts use `subprocess` and shell commands)
- **Hardware**: CUDA-capable GPU recommended for training
- **Dependencies**:
  - Python 3.8+
  - PyTorch with CUDA support
  - `fastchess` binary in project root
  - Zig compiler (for fast data loader)
  - `sqlite3` (standard library)

## Quick Start

Run any stage with verbose output to see detailed progress:

```bash
python -m automation.stage2_full_hce --verbose
python -m automation.stage3_hyperparam --verbose
```

## Pipeline Stages

### Stage 1: Material + PSQT Tuning
Bootstraps evaluation from scratch by tuning only material and piece-square tables.

### Stage 2: Full HCE Tuning
Tunes all HCE features using deeper search data.

```bash
python -m automation.stage2_full_hce --verbose
```

**Configuration:**
- **Loops**: 5 iterations
- **Games**: 140 per loop (10 games × 14 threads)
- **Search Depth**: 8
- **Dither**: 2 (adds randomness to search)
- **Min Nodes**: 5000 (ensures quality positions)
- **Training**: All HCE features (584 parameters)
- **Gauntlet**: Compares each loop against the previous version

### Stage 3: Hyperparameter Optimization
Grid search for optimal `alpha`, `k-factor`, and `lambda-l2` values.

```bash
# Auto-detect most recent Stage 2 dataset
python -m automation.stage3_hyperparam --verbose

# Or specify dataset manually
python -m automation.stage3_hyperparam --verbose --dataset data/stage2_loop5.binhce
```

**Configuration:**
- **Dataset**: Reuses existing dataset (auto-detect or manual via `--dataset`)
- **Strategy**: Infinite loop of grid search → gauntlet → update baseline
- **Grid**:
  - `alpha`: [0.2, 0.4, 0.6, 0.8, 1.0]
  - `k_factor`: [0.004, 0.005, 0.006, 0.007, 0.008]
  - `lambda_l2`: [0.0, 1e-5, 1e-4]
- **Total combinations**: 75 per session
- **Gauntlet**: Quick test (400 games) for each combination

**Parameters:**
- `--verbose` or `-v`: Enable verbose console output
- `--dataset PATH`: Specify .binhce dataset file (default: auto-detect most recent `stage2_*.binhce`)
  - `lambda_l2`: [0.0, 1e-5, 1e-4]
- **Selection**: Automatically adopts parameters that beat the baseline
- **Gauntlet**: 400 games per configuration (faster for selection)

## Key Features

### Verbose Progress Tracking
The `--verbose` flag provides detailed output:
- Data generation progress with percentage and elapsed time
- File sizes for generated datasets
- Training epoch progress
- Gauntlet results with Elo, error margins, and LOS%
- Win/Loss/Draw statistics

### Automatic Fast Loader Rebuild
The fast Zig-based data loader is automatically rebuilt after each `make clean` to ensure training never fails due to missing libraries.

### Robust Error Handling
- Validates all generated data files
- Checks for empty or missing outputs
- Provides detailed error logs when processes fail
- Automatic parameter backups before each update

## Configuration

Edit `automation/config.py` to adjust:

**Paths:**
- `ENGINE_BIN`: Path to `lamb` binary (default: `bin/lamb`)
- `OLD_ENGINE_BIN`: Path to baseline engine (default: `bin/old_lamb`)
- `FASTCHESS_BIN`: Path to fastchess (default: `./fastchess`)
- `OPENINGS_FILE`: Opening book for gauntlets

**Resources:**
- `CONCURRENCY`: Parallel data generation threads (default: 14)
- `DEVICE`: Training device (`cuda`, `cpu`, or `auto`)

## Results

**Backups:**
- `src/hce_params_backup_loop*.zig`: Parameter backups before each update
- `hce_model_epoch_*.pth`: PyTorch checkpoints every 50 epochs
- `hce_params_epoch_*.zig`: Zig parameter exports every 50 epochs

**Generated Files:**
- `tuned_hce_params.zig`: Latest trained parameters
- `hce_model.pth`: Final PyTorch model checkpoint
- `data/*.binhce`: Training datasets (merged from parallel chunks)

## Troubleshooting

**"fastchess not found"**
- Ensure `fastchess` binary is in the project root directory
- Or update `FASTCHESS_BIN` in `config.py`

**"Fast loader library not available"**
- The pipeline automatically rebuilds it, but you can manually build with:
  ```bash
  bash build_loader.sh
  ```

**"Engine binary does not exist: old_lamb"**
- Fixed automatically - the pipeline creates `old_lamb` before starting
- Ensure `make clean` doesn't delete it (it won't, as it only deletes `lamb*`)

**Data generation fails**
- Check `.binhce.log` files in the `data/` directory
- Ensure `lamb` binary is executable: `chmod +x bin/lamb`
- Verify engine compiles correctly: `make clean && make`

## Pipeline Architecture

```
Stage 2: Full HCE
├── Initial compilation
├── Create baseline (old_lamb)
├── For each loop:
│   ├── Generate data (parallel self-play)
│   ├── Merge datasets
│   ├── Train (material + PSQT only)
│   ├── Save current engine as baseline
│   ├── Recompile with new parameters
│   ├── Rebuild fast loader
│   └── Gauntlet (new vs previous)
└── Trains all 584 HCE parameters    

Stage 3: Hyperparameter Search
├── For each session:
│   ├── Generate fresh data
│   └── For each (alpha, k, lambda):
│       ├── Train with hyperparameters
│       ├── Save current as baseline
│       ├── Recompile
│       └── Quick gauntlet (400 games)
└── Adopt best configuration
```

## Advanced Usage

**Resume from checkpoint:**
```bash
python tuner/train_hce_mat_psqt_torch.py \
  --binhce data/dataset.binhce \
  --resume hce_model.pth
```

**Custom hyperparameters:**
```bash
python tuner/train_hce_torch.py \
  --binhce data/dataset.binhce \
  --alpha 0.5 \
  --k-factor 0.006 \
  --lambda-l2 1e-5 \
  --lr 0.1
```

**View training progress:**
```bash
tensorboard --logdir=runs
```

## Notes

- All stages use early stopping to prevent overfitting
- Learning rate is automatically reduced on plateau
- Phase distribution is balanced during data loading
- Positions are filtered by quality (min legal moves, material balance)
- The pipeline is designed to run unattended for hours/days

