# Tuner Scripts Reference

This directory contains training scripts and utilities for HCE (Hand-Crafted Evaluation) parameter tuning.

---

## 📋 Quick Reference

### Active Scripts (Used by Automation Pipeline)

| Script | Purpose |
|--------|---------|
| `train_hce_torch.py` | Full HCE training (all 584 feature types / 1168 parameters) |
| `binhce_loader_fast.py` | Fast Zig-based data loader |
| `binhce_reader.py` | Python fallback data loader |

### Analysis Utilities

| Script | Purpose | Usage |
|--------|---------|-------|
| `validate_material_psqt.py` | Validate material/PSQT values | `python validate_material_psqt.py` |
| `convert_pgn_to_fen_with_result.py` | Convert PGN games to FEN+result | `python convert_pgn_to_fen_with_result.py <games.pgn> <output.txt>` |

---

## 🔧 Installation

### Prerequisites

- **Python 3.8 or higher**
- **PyTorch** (with CUDA support recommended for GPU acceleration)
- **Additional packages**: numpy, chess, matplotlib

### Quick Install

**CPU-only version** (simpler, but slower):
```bash
pip install torch numpy chess matplotlib
```

**GPU version** (recommended, 10-100x faster):
```bash
# Visit https://pytorch.org/get-started/locally/ for your specific CUDA version
# Example for CUDA 11.8:
pip install torch --index-url https://download.pytorch.org/whl/cu118
pip install numpy chess matplotlib
```

### Verify Installation

```bash
# Check PyTorch
python -c "import torch; print(f'PyTorch {torch.__version__} installed')"

# Check CUDA availability (for GPU)
python -c "import torch; print(f'CUDA available: {torch.cuda.is_available()}')"

# Check other dependencies
python -c "import chess; print('python-chess OK')"
python -c "import numpy; print('NumPy OK')"
```

### GPU Support

**Benefits of GPU training**:
- 10-100x faster than CPU
- Can handle larger batch sizes (4096-8192)
- Recommended for datasets > 100k positions

**Requirements**:
- NVIDIA GPU with CUDA support
- CUDA Toolkit installed
- Appropriate PyTorch version for your CUDA version

The training scripts automatically detect and use GPU if available, otherwise fall back to CPU.

---

## 🎓 Training Scripts

### train_hce_torch.py

**Purpose**: Train all HCE parameters (full evaluation function).

**Features**:
- 1168 trainable parameters (584 MG/EG feature types)
- Used in Stage 2 and Stage 3 of automation pipeline
- Supports all feature types: mobility, threats, pawn structure (passed, isolated, backward, candidate), king safety (shield, storm), etc.
- Includes latest features: blockade passer, connected rooks, piece outposts.

**Usage**:
```bash
python train_hce_torch.py \
  --binhce data/dataset.binhce \
  --epochs 250 \
  --lr 0.1 \
  --alpha 1.0 \
  --k-factor 0.006 \
  --device cuda
```

**Arguments**:
- `--binhce`: Path to training dataset
- `--epochs`: Number of training epochs (default: 250)
- `--lr`: Learning rate (default: 0.1)
- `--alpha`: Result vs score blend (default: 1.0)
- `--k-factor`: Sigmoid scaling factor (default: 0.006)
- `--lambda-l2`: L2 regularization (default: 1e-5)
- `--device`: Training device (cuda/cpu/auto)
- `--lambda-l2`: L2 regularization (default: 1e-5)
- `--device`: Training device (cuda/cpu/auto)
- `--resume`: Resume from checkpoint
- `--no-phase-balancing`: Disable phase balancing (use all data)

**Output**:
- `tuned_hce_params.zig` - Zig parameter file
- `hce_model.pth` - PyTorch checkpoint
- `hce_model_epoch_*.pth` - Periodic checkpoints (every 50 epochs)
- `hce_params_epoch_*.zig` - Periodic Zig exports

---

## 🔧 Data Loaders

### binhce_loader_fast.py

**Purpose**: Fast Zig-based data loader for training.

**Features**:
- Written in Zig, compiled to shared library
- 10-100x faster than Python loader
- Automatically built by `build_loader.sh`

**Usage**: Automatically used by training scripts when available.

**Manual Build**:
```bash
bash build_loader.sh  # Linux/macOS
build_loader.bat      # Windows
```

### binhce_reader.py

**Purpose**: Python fallback data loader.

**Features**:
- Pure Python implementation
- Slower but always available
- Used when fast loader not built

**Usage**: Automatically used by training scripts as fallback.

---

## 📊 Analysis Utilities

### validate_material_psqt.py

**Purpose**: Validate material and PSQT values.

**Usage**:
```bash
python validate_material_psqt.py
```

**Output**:
- Material value validation
- PSQT sanity checks
- Comparison with standard values

### convert_pgn_to_fen_with_result.py

**Purpose**: Convert PGN game files to FEN positions with game results.

**Usage**:
```bash
# Basic conversion
python convert_pgn_to_fen_with_result.py games.pgn output.txt

# Skip first 5 moves (avoid opening book)
python convert_pgn_to_fen_with_result.py games.pgn output.txt --skip_moves 5
```

**Arguments**:
- `pgn_file`: Path to input PGN file
- `output_file`: Path to output FEN file
- `--skip_moves`: Number of opening moves to skip (default: 0)

**Output Format**:
```
rnbqkb1r/pp1ppppp/5n2/2p5/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - [1.0]
r1bqkb1r/pp1ppppp/2n2n2/2p5/4P3/2N2N2/PPPP1PPP/R1BQKB1R w KQkq - [0.5]
```

**Use Cases**:
- Creating training datasets from master games
- Extracting positions for analysis
- Alternative to self-play data generation

**Note**: For modern tuning, use the automated pipeline instead. This tool is useful for creating datasets from existing game databases.

---

## 📁 File Formats

### .binhce Format

Binary format for training data:

```
Header (8 bytes):
  - Magic number (4 bytes): "BHCE"
  - Version (4 bytes): 1

Record (variable size):
  - Position (FEN-like encoding)
  - Score (int16)
  - Result (float32)
  - Move (uint16)
  - Ply (uint16)
  - Features (extracted on-the-fly)
```

### tuned_hce_params.zig Format

Zig source file with parameter arrays:

```zig
pub const material_mg = [6]i32{ ... };
pub const material_eg = [6]i32{ ... };
pub const mg_pawn_table = [64]i32{ ... };
pub const eg_pawn_table = [64]i32{ ... };
// ... more parameters
```

---

## 🎯 Best Practices

### Data Quality

1. **Generate enough data**: At least 1000 games per training run
2. **Use appropriate depth**: Depth 5-8 for quality positions
3. **Filter noisy positions**: Use `skipnoisy` flag
4. **Balance game phases**: Training scripts do this automatically

### Training

1. **Start with material+PSQT**: Use Stage 1 before Stage 2
2. **Monitor validation loss**: Watch for overfitting
3. **Use early stopping**: Prevents overfitting automatically
4. **Save checkpoints**: Resume training if interrupted

### Hyperparameters

1. **Learning rate**: 0.1 is a good default
2. **Alpha**: 1.0 (pure result) to 0.0 (pure score)
3. **K-factor**: 0.006 is typical for chess
4. **Lambda**: 1e-5 for light regularization

---

## 🐛 Troubleshooting

### "Fast loader library not available"

**Solution**:
```bash
bash build_loader.sh
```

### "CUDA out of memory"

**Solutions**:
- Reduce batch size in training script
- Use CPU training: `--device cpu`
- Close other GPU applications

### "No positions loaded"

**Causes**:
- Empty or corrupted .binhce file
- Wrong file path
- Incompatible file format

**Solution**: Regenerate dataset with automation pipeline

### Training loss not decreasing

**Causes**:
- Learning rate too high/low
- Insufficient data
- Data quality issues

**Solutions**:
- Adjust learning rate
- Generate more data
- Check data quality with analysis scripts

---

## 📚 Related Documentation

- [automation/README.md](../automation/README.md) - Automated tuning pipeline
- [docs/HCE_TUNING.md](../docs/HCE_TUNING.md) - Detailed tuning guide
- [CONTRIBUTING.md](../CONTRIBUTING.md) - Development guidelines

---

## 🔗 External Resources

- [PyTorch Documentation](https://pytorch.org/docs/)
- [Chess Programming Wiki - Texel Tuning](https://www.chessprogramming.org/Texel%27s_Tuning_Method)
- [Stockfish Tuning](https://github.com/official-stockfish/Stockfish/wiki/Regression-Tests)
