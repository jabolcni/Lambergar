# Lambergar

     __,    ____, __, _, ____   ____,  ____,  ____,   ____, ____, 
    (-|    (-/_| (-|\/| (-|__) (-|_,  (-|__) (-/ _,  (-/_| (-|__) 
     _|__, _/  |, _| _|, _|__)  _|__,  _|  \, _\__|  _/  |, _|  \,
     
<br/>
<p align="center">
<img src="DALL·E 2023-11-14 16.01.46 - two chess knights figures with knights sitting on them, fighting each other, pixel art.png" alt="Logo" width=128 height=128/>
</p>
<br/>

## Introduction

Lambergar is a chess engine developed in the Zig programming language. It uses UCI protocol and HCE (human crafted evaluation) for evaluating the chess positions to find the best move. I set out on this project with a defined set of specific objectives in mind:

- *Chess Engine Creation*: the desire to construct a chess engine from the ground up.
- *Resourceful Development*: while I aimed to build it independently, I also sought to leverage existing resources and learn from the codebase of other engines. I found that, at least in my case, resources from [Chess Programming Wiki](https://www.chessprogramming.org/) are great to understand the concepts, however the code from open-source engines actually tells you how to practically implement the concept, especially the more complex ones.
- *Learning Zig*: I saw this as an opportunity not only to build a chess engine but also to learn a new programming language, which will also be useful for my job as an engineer.

Inspiration was drawn from:

- YouTube tutorial series, "Bitboard CHESS ENGINE in C" by Code Monkey King (<https://www.youtube.com/playlist?list=PLmN0neTso3Jxh8ZIylk74JpwfiWNI76Cs>),
- YouTube tutorial series, "Programming A Chess Engine in C " by Bluefever Software (<https://www.youtube.com/watch?v=bGAfaepBco4&list=PLZ1QII7yudbc-Ky058TEaOstZHVbT-2hg&index=2&ab_channel=BluefeverSoftware>),
- Kaola Chess Engine by Wuelle (<https://github.com/Wuelle/Kaola/tree/main>),
- Avalanche Chess Engine by SnowballSH (<https://github.com/SnowballSH/Avalanche/tree/master>),
- surge, fast bitboard-based legal chess move generator written in C++ (<https://github.com/nkarve/surge>)
- Several open source chess engines written in C and C++ (Igel, Xipos, Ethereal, Alexandria, ...).

The name "Lambergar" is a nod to the Slovenian folk romance, Pegam and Lambergar, which recounts the epic struggle between Jan Vitovec and Krištof Lambergar (Lamberg). This narrative of fortitude and rivalry provided a fitting namesake for this chess engine.

## Compilation

If you want to compile code yourself, code can be compiled with Zig compiler version 0.13.0 (latest Zig version at the date of last release of the engine) (<https://ziglang.org/download/>).

Compile with command `zig build`. You can run python script `build_versions.py` which will compile different versions for windows and Linux. Currently, there are three basic build: *vintage*, *popcnt* and *AVX2*. Vintage version is for really old computers, popcnt is for modern computers, but for best performance use AVX2 release.

## Features and implemented algorithms

- Move generator is a translation of surge move generator in Zig with several bug fixes.
- Perft testing
- UCI protocol
- Evaluation using PSQT tables
- Tuner for material and PSQT values
- Mop-up evaluation for end-game from Greko engine
- PVS search
- Quiescence search
- Aspiration window
- Zobrist hashing
- Move ordering
  - Hashed move
  - MVV-LVA+SEE
  - Killer moves
  - Counter move
  - History heuristics
- Iterative deepening
- Collecting PV line
- Null move pruning
- Basic time controls
- Typical pruning algorithms, reductions and extensions

## Tuning

Tuning was introduced in version v0.4.0 for HCE parameters. Version v0.6.0 introduced NNUE as the default evaluation, but the HCE path is still maintained (`setoption name UseNNue value false`) and can be tuned independently.

The previous workflow loaded EPD files and produced CSV/pickle files. The new workflow keeps everything inside the engine:

### Datagen command reference

| Argument | Description |
| --- | --- |
| `games <N>` | Number of self-play games to generate. |
| `depth <D>` | Search depth used for move selection. |
| `plies <P>` | Maximum plies per game. |
| `random <F> <N>` | Legacy randomization knobs (kept for compatibility). |
| `random_min_ply`, `random_50_ply`, `random_10_ply`, `random_move_count` | Fine-grained control of when/ how often to play random moves. |
| `save_min_ply`, `save_max_ply` | Only store positions inside this window. |
| `skipnoisy` | Skip positions where the best move is a capture/promotion. |
| `filename <name>` | Base name for the BIN40 dataset (`.bin` appended automatically). |
| `hcefilename <name>` | Optional base name for the `.binhce` file; defaults to `<filename>.binhce`. |
| `save bin40|binhce|both` | Select which dataset(s) to write. |
| `usennue true|false|auto` | Force NNUE/ HCE evaluation during generation (`auto` uses current engine setting). |
| `adjudicate_draws_by_score`, `adjudicate_draws_by_insufficient_mating_material` | Early stopping rules. |
| `strict`, `debug` | Force single-threaded strict searches or verbose logging. |

Each `.binhce` record contains:

1. `i8` result from the side to move (white win/draw/loss → 1/0/-1).
2. `u8` phase values for White and Black.
3. `i16` clamped search score in centipawns.
4. 712 feature counters for White and 712 for Black. The fields follow the layout of `tuner.Tuner` (material counts, PSQT entries, pawn structures, mobility buckets, attack tables, king-ring statistics, etc.). The first 584 entries match the historical CSV exporter; the remaining slots capture the recently-added HCE heuristics.

### HCE tuning pipeline

1. **Generate data:** run `datagen` with `save binhce` or `save both`. Example:

   ```
   datagen games 20000 depth 8 filename dataset.bin save both usennue false
   ```

2. **Move the `.binhce` file** into `tuner/` and rename if desired (the notebook defaults to `data.binhce`).

3. **Notebook parameters:** open `tuner/tune_parameters.ipynb`. The first cell has two knobs:

   - `RESULT_SCORE_WEIGHT` (0 → pure game result, 1 → pure engine score, in-between blends both).
   - `SCORE_SCALE` (centipawn-to-probability mapping for the alignment term, default 400).

4. **Run the notebook:** it loads the binary, builds the logistic model, and exports `output_mg.txt`, `output_eg.txt`, and finally `merged_parameters.txt`. Copy the merged values into `src/evaluation.zig` and rebuild.

> **Note:** the classic CSV path (`tuner.py`, `data.csv`, `convert_to_pickle.py`) is kept for historical reference but isn’t required anymore.

### Personalities

#### Built-in presets

```
setoption name Personality value default
setoption name Personality value milan_vidmar
```

`default` uses the tuned evaluation unmodified. `milan_vidmar` biases the engine toward solid pawn structures and cautious king play.

#### Custom personalities via UCI

Switch to the custom profile and tweak individual multipliers/ offsets:

```
setoption name PersonalityPawnScale value 1.10
setoption name PersonalityMobilityScale value 0.95
setoption name PersonalityKingScale value 1.05
setoption name PersonalityThreatScale value 0.9
setoption name PersonalityMaterialScale value 1.02
setoption name PersonalityMgOffset value 5
setoption name PersonalityEgOffset value 10
setoption name Personality value custom
```

The custom persona stays active until you pick another preset.

#### Personality tuning script

`tools/personality_optimize.py` automates tuning against a PGN corpus (e.g., Milan Vidmar’s games). It:

1. Parses the PGN (`--pgn vidmar.pgn` by default).
2. Samples positions and runs `lambergar.exe` at a fixed depth.
3. Uses Optuna to optimize the personality parameters with a combined objective:
   - move-match rate (engine best move equals Vidmar’s move),
   - evaluation alignment (Vidmar move vs. engine best score gap),
   - a regularizer that penalizes large deviations from baseline multipliers.

Example:

```
pip install python-chess optuna
python tools/personality_optimize.py --engine ./lambergar.exe --pgn vidmar.pgn --depth 6 --limit 200 --trials 80
```

The script writes the best parameters to `persona_best.json` and prints the individual metrics. You can then apply the values via the custom `setoption` commands described above.

## Strength

In November 2023 version v0.3.1 was proposed for testing on CCRL Blitz list, where it currently stands at 2368 &plusmn; 20 Elo.

In February 2024 version v0.4.1 was proposed for testing on CCRL Blitz list, where it currently stands at 2687 &plusmn; 20 Elo.

In March 2024 version v0.5.0 was tested on CCRL Blitz list, where it currently stands at 2908 &plusmn; 20 Elo.

In June 2024 version v0.5.2 was listed on CCRL 40/15 list with score 2946 &plusmn; 35 Elo.

In late 2024 version v0.6.0 was listed on CCRL 40/15 list and CCRL Blitz list with score 3098 &plusmn; 17 Elo.

In January 2025 version 1.0 was listed on CCRL 40/15 list and CCRL Blitz list with score 3209 &plusmn; 19 Elo and 3208 &plusmn; 17 Elo.

On 27th of March 2025 version 1.1 was released, listed on CCRL 40/15 list and CCRL Blitz list with score 3308 &plusmn; 17 Elo and 3338 &plusmn; 16 Elo.

On 21th of May 2025 version 1.2 was released, listed on CCRL 40/15 list and CCRL Blitz list with score 3355 &plusmn; 18 Elo and 3364 &plusmn; 15 Elo.

On 19th of September 2025 version 1.3 was released, estimated at around 3420 Elo.


## Credits

- [Fathom library](https://github.com/jdart1/Fathom) by [Jon Dart](https://github.com/jdart1) for Syzygy tablebase probing
  
- [Chess Programming Wiki](https://www.chessprogramming.org/)

- [BitBoard Chess Engine in C YouTube playlist](https://www.youtube.com/playlist?list=PLmN0neTso3Jxh8ZIylk74JpwfiWNI76Cs) by [@maksimKorzh](https://github.com/maksimKorzh) in which the authors explain the development of [BBC](https://github.com/maksimKorzh/bbc) engine

- [Programming A Chess Engine in C](https://www.youtube.com/watch?v=bGAfaepBco4&list=PLZ1QII7yudbc-Ky058TEaOstZHVbT-2hg&index=2&ab_channel=BluefeverSoftware) by Bluefever Software in which the authors explain the development of Vice engine

- [surge](https://github.com/nkarve/surge) by [nkarve](https://github.com/nkarve). Move generator is a translation of surge move generator in Zig with several bug fixes.

- [Kaola Chess Engine](https://github.com/Wuelle/Kaola/tree/main) by [Wuelle](https://github.com/Wuelle). The UCI protocol implementation and FEN string parsing are directly derived from the Kaola chess engine. UCI protocol was later refractored, but it still retains a lot of code from Kaola chess engine.

- [Avalanche Chess Engine](https://github.com/SnowballSH/Avalanche/tree/master) by [SnowballSH](https://github.com/SnowballSH). Useful examples hot to program chess engine in Zig language.

- [Delilah Chess Engine](https://git.sr.ht/~voroskoi/delilah) by [VÖRÖSKŐI András](https://git.sr.ht/~voroskoi/). Useful example how to implement NNUE in Zig.

## License

Lambergar is licensed under the MIT License. Check out LICENSE for the full text. Feel free to use this program, but please credit this repository in your project if you use it.
