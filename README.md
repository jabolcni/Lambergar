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

Tuning was introduced in version v0.4.0 for tuning HCE evaluation parameters (material values and PSQT values). Version v0.6.0 introduced evaluation based on neural network and newer version use NNUE as a default option for evaluation. However, HCE evaluation is still an option with setting `setoption name UseNNue value false`, so code for tuning of HCE parameters has been kept as part of the project. 

Go into directory `tuner`. Run python script `python tuner.py --mode on` which will change the mode of the Zig code of the Lamberger engine for tuning. Compile the engine with `zig build` command. In `tuner.zig` line `var file = try std.fs.cwd().openFile("quiet-labeled.epd", .{});` write the name of the file with position and results of the game. File with positions should have fen position followed with either `[1.0]` for white won, `[0.5]` draw or `[0.0]` for black won.
Example:

```bash
2r2rk1/ppN1nppp/5q2/8/3p4/3B4/PPPQ1PPP/3R2K1 w - - [0.0]
8/5R2/5K2/8/4r3/5k2/8/8 w - - [0.5]
rnb1k2r/2p1bppp/1p2pn2/pP6/3NP3/P1NB4/5PPP/R1BQK2R b KQkq - [1.0]
```

Output file `data.csv` will contain flags which evaluation parameters contribute to position evaluation. When conversion ends, you can quit the engine and run command `python tuner.py --mode off`, which will change the mode of the Zig code of the Lamberger engine into normal mode. Compile the engine with `zig build` command.

Now run python script `convert_to_pickle.py` which will convert `data.csv` into pickle files. Then you can open Jupyter notebook `tune_parameters.ipynb`, which contains the code for optimization which finds the best evaluation parameters. Code saves the parameters into file `merged_parameters.txt`, which can be directly copied into `evaluation.zig`. Of course then you need to compile the Zig code with `zig build` so that new evaluation values are used in newly compiled engine.

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

- [Chess Programming Wiki](https://www.chessprogramming.org/)

- [BitBoard Chess Engine in C YouTube playlist](https://www.youtube.com/playlist?list=PLmN0neTso3Jxh8ZIylk74JpwfiWNI76Cs) by [@maksimKorzh](https://github.com/maksimKorzh) in which the authors explain the development of [BBC](https://github.com/maksimKorzh/bbc) engine

- [Programming A Chess Engine in C](https://www.youtube.com/watch?v=bGAfaepBco4&list=PLZ1QII7yudbc-Ky058TEaOstZHVbT-2hg&index=2&ab_channel=BluefeverSoftware) by Bluefever Software in which the authors explain the development of Vice engine

- [surge](https://github.com/nkarve/surge) by [nkarve](https://github.com/nkarve). Move generator is a translation of surge move generator in Zig with several bug fixes.

- [Kaola Chess Engine](https://github.com/Wuelle/Kaola/tree/main) by [Wuelle](https://github.com/Wuelle). The UCI protocol implementation and FEN string parsing are directly derived from the Kaola chess engine. UCI protocol was later refractored, but it still retains a lot of code from Kaola chess engine.

- [Avalanche Chess Engine](https://github.com/SnowballSH/Avalanche/tree/master) by [SnowballSH](https://github.com/SnowballSH). Useful examples hot to program chess engine in Zig language.

- [Delilah Chess Engine](https://git.sr.ht/~voroskoi/delilah) by [VÖRÖSKŐI András](https://git.sr.ht/~voroskoi/). Useful example how to implement NNUE in Zig.

## License

Lambergar is licensed under the MIT License. Check out LICENSE for the full text. Feel free to use this program, but please credit this repository in your project if you use it.
