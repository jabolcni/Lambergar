<p align="center">
  <img src="banner2.svg" alt="Lambergar Chess Engine"/>
</p>

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.15.1%20%7C%200.16.0-orange.svg)](https://ziglang.org/)
[![CCRL Rating](https://img.shields.io/badge/CCRL-3380%20Elo-blue.svg)](https://computerchess.org.uk/4040/cgi/compare_engines.cgi?family=Lambergar&print=Rating+list&print=Results+table&print=LOS+table&print=Ponder+hit+table&print=Eval+difference+table&print=Comopp+gamenum+table&print=Overlap+table&print=Score+with+common+opponents)

---

## Table of Contents

- [Introduction](#introduction)
- [Features](#features)
- [Quick Start](#quick-start)
- [Building from Source](#building-from-source)
- [HCE Tuning](#hce-tuning)
- [Strength](#strength)
- [Documentation](#documentation)
- [Contributing](#contributing)
- [Credits](#credits)
- [License](#license)

---

## Introduction

Lambergar is a UCI-compliant chess engine developed in the Zig programming language. It features both **NNUE (neural network)** and **HCE (hand-crafted evaluation)** options, with a fully automated tuning pipeline for HCE parameters.

### Project Goals

- **Chess Engine Creation**: Build a strong chess engine from the ground up
- **Resourceful Development**: while I aimed to build it independently, I also sought to leverage existing resources and learn from the codebase of other engines. I found that, at least in my case, resources from [Chess Programming Wiki](https://www.chessprogramming.org/) are great to understand the concepts, however the code from open-source engines actually tells you how to practically implement the concept, especially the more complex ones.
- **Learning Zig**: I saw this as an opportunity not only to build a chess engine but also to learn a new programming language, which will also be useful for my job as an engineer.


### Name Origin

The name "Lambergar" comes from the Slovenian folk romance *Pegam and Lambergar*, which recounts the epic struggle between Jan Vitovec and Krištof Lambergar (Lamberg). This narrative of fortitude and rivalry provides a fitting namesake for a chess engine.

### Inspiration

This project draws inspiration from:
- [Bitboard CHESS ENGINE in C](https://www.youtube.com/playlist?list=PLmN0neTso3Jxh8ZIylk74JpwfiWNI76Cs) by Code Monkey King
- [Programming A Chess Engine in C](https://www.youtube.com/watch?v=bGAfaepBco4&list=PLZ1QII7yudbc-Ky058TEaOstZHVbT-2hg) by Bluefever Software
- [Kaola Chess Engine](https://github.com/Wuelle/Kaola) by Wuelle
- [Avalanche Chess Engine](https://github.com/SnowballSH/Avalanche) by SnowballSH
- [surge](https://github.com/nkarve/surge) - Fast bitboard-based legal move generator
- Various open-source engines (Igel, Xipos, Ethereal, Alexandria, and others)

---

## Features

### Search & Evaluation

- **Move Generation**: Fast bitboard legal move generator with cached move-generation context, pinned-piece handling, en-passant legality, and Chess960 castling support
- **Evaluation Options**:
  - NNUE (default) - Neural network evaluation
  - HCE - Hand-crafted evaluation with tuned parameters and exportable feature counters
- **Search Algorithm**: Principal Variation Search (PVS) with iterative deepening and aspiration windows
- **Quiescence Search**: Tactical position evaluation with TT reuse, noisy move ordering, delta pruning, and SEE pruning
- **Move Ordering**:
  - Hash move
  - Capture history and SEE (Static Exchange Evaluation)
  - Killer moves
  - Countermoves
  - Threat-aware quiet history
  - Continuation history
- **Transposition Table**: Two-entry bucket TT with age tracking, prefetching, replacement scoring, and thread-safe publishing
- **Endgame Tablebases**: Experimental Syzygy support through Fathom, including WDL/root probing and UCI inspection commands
- **Chess Variants**: Standard chess, Chess960/FRC, and DFRC start positions

### Search optimizations

- Aspiration windows
- Zobrist hashing
- Null move pruning
- Futility pruning
- Razoring
- Late move pruning
- Late move reductions
- Singular extensions
- Correction history
- Lazy SMP search
- Tunable search parameters exposed as UCI options
- Iterative deepening
- Soft/hard time management

### Data Generation & HCE Tuning

- **Selfplay Datagen**: Standard, FRC, and DFRC selfplay generation
- **Output Formats**: bin40 and binhce training data formats
- **HCE Feature Export**: Packed HCE feature vectors for tuning and validation
- **Fast Zig/C Loader**: Efficient binhce loading for Python training tools
- **PyTorch Training**: GPU-accelerated parameter optimization
- **Validation Tools**: Datagen, binhce, UCI, FRC/DFRC, tablebase, and engine regression helpers

See [automation/README.md](automation/README.md) for details.

---

## How to use it

### Download Pre-built Binary

Download the latest release from the [Releases](https://github.com/yourusername/Lambergar/releases) page.

Choose the appropriate version:
- **AVX2**: Best performance (modern CPUs)
- **AVX-512**: Optional high-end x86-64-v4 build on supported CPUs

### Using with a GUI

Lambergar supports the UCI protocol and works with any UCI-compatible chess GUI:
- [Arena](http://www.playwitharena.de/)
- [Cute Chess](https://cutechess.com/)
- [BanksiaGUI](https://banksiagui.com/)

### Command Line Usage

```bash
# Start the engine
./lambergar

# Basic UCI commands
uci                    # Display engine info
isready                # Check if engine is ready
position startpos      # Set starting position
go depth 10            # Search to depth 10
quit                   # Exit engine
```

---

## Building from Source

### Prerequisites

- **Zig Compiler**: Version `0.15.1` or `0.16.0` ([Download](https://ziglang.org/download/))
- **Python 3.8+**: For tuning scripts (optional)
- **PyTorch**: For HCE tuning (optional)

Note: the engine currently builds with both Zig `0.15.1` and `0.16.0`, but Zig `0.15.1` is recommended for benchmarking and releases because Zig `0.16.0` is significantly slower on this codebase.

### Build Commands

```bash
# Simple build
zig build

# Build with an explicit Zig version
"C:\path\to\zig.exe" build -Dtarget=x86_64-windows -Dcpu=x86_64_v3

# Package release binaries with an explicit Zig executable
python build_versions.py --zig "C:\path\to\zig.exe"
```

### Build Targets

- **Windows AVX2**: `x86_64-windows`, `x86_64_v3`
- **Windows AVX-512**: `x86_64-windows`, `x86_64_v4`
- **Linux AVX2**: `x86_64-linux`, `x86_64_v3`
- **macOS AVX2**: `x86_64-macos`, `x86_64_v3`

Notes:
- NNUE currently uses x86-64 AVX2 inline assembly, so older x86-64 targets such as Vintage and POPCNT are not built.
- Apple Silicon and generic aarch64 release binaries are currently skipped for the same reason.

---

## Strength

Lambergar has been tested on the [CCRL](https://computerchess.org.uk/) rating lists:

| Version | Date | CCRL 40/15 | CCRL Blitz |
|---------|------|------------|------------|
| v0.3.1 | Nov 2023 | 2455 ± 20 | 2360 ± 18 |
| v0.4.1 | Feb 2024 | 2653 ± 19 | 2688 ± 17 |
| v0.5.0 | Mar 2024 | 2794 ± 20 | 2910 ± 17 |
| v0.5.2 | Jun 2024 | 2990 ± 20 | - |
| v0.6.0 | Late 2024 | 3099 ± 16 | 3092 ± 16 |
| v1.0 | Jan 2025 | 3206 ± 15 | 3202 ± 16 |
| v1.1 | Mar 2025 | 3306 ± 15 | 3338 ± 16 |
| v1.2 | May 2025 | 3355 ± 17 | 3365 ± 15 |
| v1.3 | Sep 2025 | 3380 ± 13 | 3443 ± 13 |

---

## Credits

### Special Thanks

- **Code Monkey King** - Bitboard chess engine tutorial series
- **Bluefever Software** - Chess programming tutorial series
- **Wuelle** - Kaola chess engine (Zig inspiration)
- **SnowballSH** - Avalanche chess engine
- **nkarve** - surge move generator
- **Open Source Community** - Igel, Xipos, Ethereal, Alexandria, and many others

### Resources

- [Chess Programming Wiki](https://www.chessprogramming.org/) - Invaluable reference
- [Zig Language](https://ziglang.org/) - Modern systems programming
- [PyTorch](https://pytorch.org/) - Machine learning framework
- [official-stockfish/nnue-pytorch](https://github.com/official-stockfish/nnue-pytorch/tree/nodchip_ft_init) - NNUE training

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
