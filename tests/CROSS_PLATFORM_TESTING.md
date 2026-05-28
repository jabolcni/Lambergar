# Cross-Platform Testing Guide

Guide for building and testing Lambergar on Linux from Windows using WSL.

## Building for Linux (from Windows)

### Build Command

```bash
zig build -Dtarget=x86_64-linux --release=fast -Dcpu=x86_64_v3 --prefix "lambergar-x86_64-linux-AVX2"
```

**Build Options:**
- `-Dtarget=x86_64-linux` - Target Linux x86_64
- `--release=fast` - Optimized build
- `-Dcpu=x86_64_v3` - AVX2 instruction set
- `--prefix "lambergar-x86_64-linux-AVX2"` - Output directory name

**Output Location:**
```
D:\Ostalo\LambergarTesting\gitea\Lambergar-1\lambergar-x86_64-linux-AVX2\bin\lambergar
```

### Other Build Variants

```bash
# Vintage (older CPUs, no AVX)
zig build -Dtarget=x86_64-linux --release=fast -Dcpu=x86_64 --prefix "lambergar-x86_64-linux-vintage"

# POPCNT (modern CPUs without AVX2)
zig build -Dtarget=x86_64-linux --release=fast -Dcpu=x86_64_v2 --prefix "lambergar-x86_64-linux-popcnt"

# AVX2 (best performance)
zig build -Dtarget=x86_64-linux --release=fast -Dcpu=x86_64_v3 --prefix "lambergar-x86_64-linux-AVX2"
```

## Deploying to WSL

### 1. Copy Binary to WSL

**From Windows PowerShell:**

```powershell
# Copy from build output to WSL filesystem
copy "D:\Ostalo\LambergarTesting\gitea\Lambergar-1\lambergar-x86_64-linux-AVX2\bin\lambergar" "\\wsl.localhost\Ubuntu\home\janezp\fastchess\fastchess-linux-x86-64\"
```

**Alternative using WSL path:**

```bash
# From WSL terminal
cp /mnt/d/Ostalo/LambergarTesting/gitea/Lambergar-1/lambergar-x86_64-linux-AVX2/bin/lambergar ~/fastchess/fastchess-linux-x86-64/
```

### 2. Make Executable

```bash
cd ~/fastchess/fastchess-linux-x86-64/
chmod +x lambergar
```

## UCI Compliance Testing

### Using fastchess

**Location:** `~/fastchess/fastchess-linux-x86-64/`

**Run Compliance Test:**

```bash
cd ~/fastchess/fastchess-linux-x86-64/
./fastchess --compliance lambergar
```

### Expected Output

```
 Passed Step 1: Start the engine
 Passed Step 2: Check if engine is ready
 Passed Step 3: Check id name
 Passed Step 4: Check id author
 Passed Step 5: Send ucinewgame
 Passed Step 6: Set position to startpos
 Passed Step 7: Check if engine is ready after startpos
 Passed Step 8: Set position to fen
 Passed Step 9: Check if engine is ready after fen
 Passed Step 10: Send go wtime 100
 Passed Step 11: Read bestmove
 Passed Step 12: Check if engine prints an info line
 Passed Step 13: Verify info line format is valid
 Passed Step 14: Verify info line contains score
 Passed Step 15: Set position to black to move
 Passed Step 16: Send go btime 100
 Passed Step 17: Read bestmove after go btime 100
 Passed Step 18: Check if engine prints an info line after go btime 100
 Passed Step 19: Verify info line format is valid after go btime 100
 Passed Step 20: Check if engine prints an info line with the score after go btime 100
 Passed Step 21: Send go wtime 100 winc 100 btime 100 binc 100
 Passed Step 22: Read bestmove after go wtime 100 winc 100 btime 100 binc 100
 Passed Step 23: Check if engine prints an info line after go wtime 100 winc 100
 Passed Step 24: Verify info line format is valid after go wtime 100 winc 100
 Passed Step 25: Check if engine prints an info line with the score after go wtime 100 winc 100
 Passed Step 26: Send go btime 100 binc 100 wtime 100 winc 100
 Passed Step 27: Read bestmove after go btime 100 binc 100 wtime 100 winc 100
 Passed Step 28: Check if engine prints an info line after go btime 100 binc 100
 Passed Step 29: Verify info line format is valid after go btime 100 binc 100
 Passed Step 30: Check if engine prints an info line with the score after go btime 100 binc 100
 Passed Step 31: Check if engine prints an info line after go btime 100 binc 100
 Passed Step 32: Send ucinewgame
 Passed Step 33: Set position to startpos
 Passed Step 34: Send go wtime 100
 Passed Step 35: Read bestmove after go wtime 100 btime 100
 Passed Step 36: Verify info line format is valid after go wtime 100 btime 100
 Passed Step 37: Set position to startpos moves e2e4 e7e5
 Passed Step 38: Send go wtime 100 btime 100
 Passed Step 39: Read bestmove after position startpos moves e2e4 e7e5
 Passed Step 40: Verify info line format is valid after position startpos moves e2e4 e7e5
Engine passed all compliance checks.
```

**All 40 steps should pass** ✅

### What the Compliance Test Checks

1. **Engine Startup**: UCI protocol initialization
2. **Identity**: `id name` and `id author` responses
3. **Ready State**: `isready` / `readyok` handling
4. **Position Setup**: `position startpos` and `position fen`
5. **Search Commands**: Various `go` command formats
6. **Time Controls**: `wtime`, `btime`, `winc`, `binc`
7. **Info Output**: Proper UCI info line formatting
8. **Score Reporting**: Score values in info lines
9. **Move Sequences**: Position with moves
10. **State Management**: `ucinewgame` handling

## Complete Testing Workflow

### 1. Build for Linux

```bash
# From Windows (in project root)
zig build -Dtarget=x86_64-linux --release=fast -Dcpu=x86_64_v3 --prefix "lambergar-x86_64-linux-AVX2"
```

### 2. Deploy to WSL

```powershell
# From Windows PowerShell
copy "D:\Ostalo\LambergarTesting\gitea\Lambergar-1\lambergar-x86_64-linux-AVX2\bin\lambergar" "\\wsl.localhost\Ubuntu\home\janezp\fastchess\fastchess-linux-x86-64\"
```

### 3. Test on Linux

```bash
# From WSL terminal
cd ~/fastchess/fastchess-linux-x86-64/
chmod +x lambergar

# Run UCI compliance test
./fastchess --compliance lambergar

# Optional: Run basic functionality test
./lambergar bench
./lambergar perft
```

### 4. Validate (Optional)

If you have Python in WSL:

```bash
# Run validation suite on Linux
python3 tests/validate_engine.py --engine ./lambergar --suite all
```

## Troubleshooting

### Binary Not Executable

**Symptom**: `Permission denied` when running `./lambergar`

**Fix**:
```bash
chmod +x lambergar
```

### Wrong Architecture

**Symptom**: `cannot execute binary file: Exec format error`

**Cause**: Built for wrong target (e.g., Windows binary on Linux)

**Fix**: Rebuild with correct `-Dtarget=x86_64-linux`

### Missing Libraries

**Symptom**: `error while loading shared libraries`

**Fix**: Zig builds static binaries by default, this shouldn't happen. If it does, check your build configuration.

### Compliance Test Failures

**Common Issues**:
- **Timeout**: Engine taking too long to respond
  - Check if engine is actually running
  - Verify no infinite loops in search
- **Invalid UCI Format**: Info lines not formatted correctly
  - Check UCI output formatting in `src/uci.zig`
- **Missing bestmove**: Engine not returning a move
  - Verify search completes properly
  - Check move generation

## Integration with CI/CD

### GitHub Actions Example

```yaml
name: Cross-Platform Build and Test

on: [push, pull_request]

jobs:
  linux-build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      
      - name: Setup Zig
        uses: goto-bus-stop/setup-zig@v2
        with:
          version: 0.15.1
      
      - name: Build for Linux
        run: zig build --release=fast -Dcpu=x86_64_v3
      
      - name: Run UCI Compliance
        run: |
          wget https://github.com/Disservin/fast-chess/releases/latest/download/fastchess-linux-x86-64
          chmod +x fastchess-linux-x86-64
          ./fastchess-linux-x86-64 --compliance ./zig-out/bin/lambergar
      
      - name: Run Validation
        run: |
          python tests/validate_engine.py --engine ./zig-out/bin/lambergar --suite all
```

## Performance Comparison

After building for Linux, you can compare performance:

```bash
# Windows
lamb.exe bench

# Linux (WSL)
./lambergar bench
```

**Expected**: Linux build may be slightly faster due to better compiler optimizations and native execution.

## References

- [Zig Cross-Compilation](https://ziglang.org/learn/overview/#cross-compiling-is-a-first-class-use-case)
- [UCI Protocol Specification](https://www.shredderchess.com/download/div/uci.zip)
- [fastchess Documentation](https://github.com/Disservin/fast-chess)
- [WSL Documentation](https://docs.microsoft.com/en-us/windows/wsl/)
