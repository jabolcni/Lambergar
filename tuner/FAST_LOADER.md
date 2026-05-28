# Fast BinHCE Loader

## Overview

The fast BinHCE loader is a compiled Zig library that provides 5-10x faster data loading compared to the pure Python implementation.

## Building

Build the shared library using the standalone script:

**Windows:**
```bash
build_loader.bat
```

**Linux/macOS:**
```bash
chmod +x build_loader.sh
./build_loader.sh
```

Or build manually:
```bash
# Windows
zig build-lib src\binhce_loader.zig -dynamic -O ReleaseFast -femit-bin=zig-out\lib\binhce_loader.dll

# Linux
zig build-lib src/binhce_loader.zig -dynamic -O ReleaseFast -femit-bin=zig-out/lib/binhce_loader.so

# macOS
zig build-lib src/binhce_loader.zig -dynamic -O ReleaseFast -femit-bin=zig-out/lib/binhce_loader.dylib
```

This creates:
- Windows: `zig-out/lib/binhce_loader.dll`
- Linux: `zig-out/lib/libbinhce_loader.so`
- macOS: `zig-out/lib/libbinhce_loader.dylib`

## Usage

The training scripts automatically use the fast loader if available:

```python
# Automatically uses fast loader if built
python tuner/train_hce_torch.py --binhce dataset.binhce --epochs 100
```

You can also use it directly:

## Implementation

- **Zig library**: `src/binhce_loader.zig` - C API for Python
- **Python wrapper**: `tuner/binhce_loader_fast.py` - ctypes interface
- **Build config**: `build.zig` - Shared library build step
