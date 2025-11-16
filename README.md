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

1. Use the UCI `datagen` command to create self-play positions **and** an HCE dataset. The regular BIN40 file is still produced for NNUE, while a new `.binhce` file stores the handcrafted evaluation features. Example:

   ```
   datagen games 20000 depth 8 filename dataset.bin hcefilename hce_dataset save both usennue false
   ```

   The engine appends the `.bin` and `.binhce` suffixes automatically. Each entry in the `.binhce` file contains:

   - result from the side to move (`i8`, values -1/0/1),
   - the NN/score evaluation in centipawns (`i16`, clamped to ±32000),
   - the white and black phase values (`u8` each),
   - 584 feature counters for White followed by the same 584 counters for Black (material counts, PSQT occurrences, pawn structure probes, mobility buckets, attack tables, doubled/bishop-pair flags). Fields are stored in the same order as defined in `tuner.Tuner`.

   - `save bin40|binhce|both` decides which files are written.
   - `usennue true|false|auto` forces NNUE/HCE evaluation during self-play (default is to use whatever the engine is currently configured with).

2. Copy the produced `.binhce` file next to the tuning scripts (the notebook looks for `tuner/data.binhce` by default, but you can edit the path inside the first cell).

3. Open `tuner/tune_parameters.ipynb`. The first cell now streams the binary file directly, constructs the `pos`, `phase`, and blended training targets, and then the rest of the notebook is unchanged. Two knobs are exposed at the top of the first cell:

   - `RESULT_SCORE_WEIGHT` (0 → purely game result, 1 → purely engine score, values in-between blend both),
   - `SCORE_SCALE` (controls how aggressively the raw score in centipawns is mapped to a probability through a sigmoid).

   Running the notebook produces `output_mg.txt`, `output_eg.txt`, and ultimately `merged_parameters.txt`.

4. Copy the parameters from `merged_parameters.txt` into `src/evaluation.zig`, rebuild (`zig build`), and the engine will use the tuned values.

The helper scripts `tuner.py` and `convert_to_pickle.py` are kept for historical reference but are no longer required for the default HCE tuning pipeline.

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
