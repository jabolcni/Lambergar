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

Lambergar is a chess engine developed in the Zig programming language. The project stemmed from a series of specific objectives:

- *Chess Engine Creation*: the desire to construct a chess engine from the ground up.
- *Resourceful Development*: while I aimed to build it independently, I also sought to leverage existing resources and learn from the codebase of other engines.
- *Learning Zig*: I saw this as an opportunity not only to build a chess engine but also to learn a new programming language, which will also be usefull for my job as an engineer.



Inspiration and learning were drawn from:

- YouTube tutorial series, "Bitboard CHESS ENGINE in C" by Code Monkey King (https://www.youtube.com/playlist?list=PLmN0neTso3Jxh8ZIylk74JpwfiWNI76Cs),
- YouTube tutorial series, "Programming A Chess Engine in C " by Bluefever Software (https://www.youtube.com/watch?v=bGAfaepBco4&list=PLZ1QII7yudbc-Ky058TEaOstZHVbT-2hg&index=2&ab_channel=BluefeverSoftware),
- Koala Chess Engine by Wuelle (https://github.com/Wuelle/Kaola/tree/main),
- Avalanche Chess Engine by SnowballSH (https://github.com/SnowballSH/Avalanche/tree/master),
- surge, fast bitboard-based legal chess move generator written in C++ (https://github.com/nkarve/surge)
- Several opensource chess engines written in C and C++ (igel, xipos, ...).

The name "Lambergar" is a nod to the Slovenian folk romance, Pegam and Lambergar, which recounts the epic struggle between Jan Vitovec and Krištof Lambergar (Lamberg). This narrative of fortitude and rivalry provided a fitting namesake for this chess engine.

This code aims to provide insights into Lambergar's architecture, algorithms, and usage. It offers fellow enthusiasts and developers an understanding of the intricacies of this chess engine. Your feedback and contributions are valued.

## Features and implemented algorithms

- Move generator is a translation of surge move generator in zig with several bug fixes.
- Perft testing
- UCI protocol
- Evaluation using PESTO tables
- Mop-up evaluation for end-game from Greko engine
- PVS search
- Quiescence search
- Aspiration window
- Zobrist hashing
- Move ordering
  - Hashed move
  - MVV-LVA+SEE
  - Killer moves
  - Very basic history heuristics
- Iterative deepening
- Collecting PV line
- Null move pruning
- Very basic pruning (just to test a concept for future implementation)
  - Reverse futility pruning
  - Razoring
- Basic time controls
- Very basic reduction and extensions (just to test a concept for future implementation)
  - Reduction for quiet moves when score is improving
  - Check extension

## Planed features
  - [ ] LMR
  - [ ] LMP
  - [ ] Better time controls
  - [ ] Major refractoring of code and performance optimization
  - [ ] Better history heuristics: history moves, counter moves, follow moves
  - [ ] Improvements in evaluation
    - [ ] Pawn structure evaluation
      - [ ] Double pawns
      - [ ] Isolated pawns
      - [ ] Passed pawn
      - [ ] Promotion candidates
      - [ ] Backward pawns
    - [ ] King safety
    - [ ] Bishop pair
    - [ ] Mobility
    - [ ] Center control
    - [ ] NNUE sometime in far future
  - [ ] Various extensions and reductions
  - [ ] Layz SMP


## Strenght

Engine was not yet proposed for testing on the CCRL (Computer Chess Rating Lists), but by playing against rated chess engines, the estimated strength is around 2400 &plusmn; 50 CCRL Blitz ELO. 

## Credits

-  [BitBoard Chess Engine in C YouTube playlist](https://www.youtube.com/playlist?list=PLmN0neTso3Jxh8ZIylk74JpwfiWNI76Cs) by [@maksimKorzh](https://github.com/maksimKorzh) in which the authors explains the developement of [BBC](https://github.com/maksimKorzh/bbc) engine

-  [Programming A Chess Engine in C](https://www.youtube.com/watch?v=bGAfaepBco4&list=PLZ1QII7yudbc-Ky058TEaOstZHVbT-2hg&index=2&ab_channel=BluefeverSoftware) by Bluefever Software in which the authors explains the developement of Vice engine

- [surge](https://github.com/nkarve/surge) by [nkarve](https://github.com/nkarve). Move generator is a translation of surge move generator in zig with several bug fixes.

- [Koala Chess Engine](https://github.com/Wuelle/Kaola/tree/main) by [Wuelle](https://github.com/Wuelle). The UCI protocol implementation and FEN string parsing are directly derived from the Koala chess engine and slightly updated.

- [Chess Programming Wiki](https://www.chessprogramming.org/)

- [Avalanche Chess Engine](https://github.com/SnowballSH/Avalanche/tree/master) by [SnowballSH](https://github.com/SnowballSH). Usefull examples hot to programm chess engine in Zig langugae.

## License

Lambergar is licensed under the MIT License. Check out LICENSE.txt for the full text. Feel free to use this program, but please credit this repository in your project if you use it.