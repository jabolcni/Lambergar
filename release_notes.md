# Lambergar 1.0

## Builds

Currently there are four builds:

- x86-64-v3: AVX2 support, best for using with NN evaluation and should be a preffered choice for best performance.
- x86-64-v2: popcount support, suitable for moder computers.
- x86-64-v1: vintage version is for really old computers.
- aarch64-linux: version for Raspberry Pi 5.

## Release Notes

This is a major release. I believe the Lambergar chess engine has matured enough to warrant the release of version 1.0. I am also introducing slight changes to the naming convention by dropping the patch version and removing the letter "v" in front of the version number. While I am sure there are still some significant bugs in the engine, I believe the code has reached a level of maturity where these bugs are no longer critical to its core functionality.

- Added efficient updates (UE) to NN evaluation of positions. I expected a significant improvement in ELO, but the gain was only 20 ELO points.
- Introduced a new network, `zolnir.nnue`, which contributes the majority of the ELO improvement.
- Estimated engine strength is around 3180–3200 ELO.
- Fixed bug: `UseNNUE` was not working because the implementation for switching NNUE on/off did not follow the correct format. This has been fixed to comply with the UCI format: `setoption name UseNNUE value [value]`, where `[value]` is either `true` or `false`.
- Fixed bug: When the UCI command was issued, the line reporting the option name `UseNNUE type check default` always displayed `false`, because it was hardcoded. I had overlooked updating this line to reflect the actual value. This issue is now resolved.

# Lambergar v0.6.0

## Builds

Currently there are three builds:

- x86-64-v3: AVX2 support, best for using with NN evaluation and should be a preffered choice for best performance.
- x86-64-v2: popcount support, suitable for moder computers.
- x86-64-v1: vintage version is for really old computers.

## Release Notes

This is quite a major release, if the testing of this release goes well, next release will be version v1.0.0. This release brings several important changes:

- Introduction of NN for evaluation. It uses halfKP NNUE arhitecture, although half of the size typically used. While the arhitecture of NN is of NNUE type, the engine code for evaluation is actually mising the UE part. This is planned for next release.
- Engine code can now be compiled with latest version of zig, which is version `0.13.0`. The major problem in the past was that the engine code was written in such a manner that newer releases of zig when compiled intorducede many calls of memcpy which significantly reduced the speed of the engine (see discussion on [Ziggit](https://ziggit.dev/t/slow-execution-of-the-program-with-newest-zig-version/3976)). By using profiler I was able to identify the problematic parts of code and refractor it.
- Engine code can now be compiled into Debug mode. While this seems obvious and trivial requirement and good coding practice, zig compiler is pretty robust and produces in most cases normally working executables, so this was not my main priority at the start of the programming the engine. However, later it become obvious that I need to fix the bugs to be able to keep the code in "good shape".
- Several bug fixes, the major one being related how the time for a single move is calculated in time format with "moves to go". This has now been fixed and all time controls should work correctly. The rest of the bugs were mainly related to integer overflows, etc.
- Estimated engine strenght is around 3040-3060 ELO.
  
# Lambergar v0.5.2

## Release Notes

- This release brings some minor bug fixes.
- UCI interface has been reorganized and is now smaller in terms of code size, but has same functionality.
- Some code refactoring so that the project can be compiled with newer zig versions. However, zig versions newer than `0.12.0-dev.1536+6b9f7e26c` make engine really slow.
- Improved time controls.
- Strength of the engine remains the same as in version v0.5.1.

# Lambergar v0.5.1

## Release Notes

This release brings several bug fixes, with the major one addressing a flaw in the calculation formula for determining the new history value. The previous formula did not limit the history value, leading to an integer overflow issue at certain points, resulting in negative values. Consequently, during move sorting, the best quiet moves were erroneously placed last. This issue was more pronounced during longer time controls, where there were more opportunities to increase the history value. At lower time controls (up to 10 seconds per move), the new formula may actually reduce the engine's strength by 10-20 ELO points. However, at longer time controls, version v0.5.1 demonstrates improvement in engine strength over the previous version. At approximately 1 minute per move, the new version is approximately 50 ELO points stronger, with even more significant gains observed at longer time controls.

# Lambergar v0.5.0

## Builds

Currently there are two basic builds: vintage and popcnt. The vintage version is for really old computers, while popcnt is for modern computers.

## Release Notes

Main Features:

- Improved evaluation function: Now includes tuned:
  - Piece values
  - PSQT (Positional Square Table)
  - Pawn evaluation:
    - Passers
    - Isolated pawns
    - Blocked pawns
    - Supported pawns
    - Evaluation of pawn phalanx
  - Piece mobility
  - Piece attacking evaluation
  - Basic king safety
- Some minor improvements: Search function, history heuristics, and move sorting.
- Time controls: improved time controls.

# Lambergar v0.4.1

## Release Notes

This release includes two bug fixes:

- **Excessive Memory Usage**: We resolved an issue with excessive memory usage. The problem originated from the use of an incorrect memory allocator. Previously, we used the Arena memory allocator, which, according to a discussion on [Ziggit](https://ziggit.dev/t/ram-memory-use-and-proper-aloccation-of-array/3053), does not release memory. We have now switched to using the c_allocator directly.

- **Engine Unresponsiveness**: We fixed an issue where the engine would get stuck in search mode and not respond to commands from the interface. This was due to the use of a single thread, and interfacing was only possible once the search had finished. We have now resolved this by using a separate thread for the search routine. This improvement also lays the groundwork for implementing a multi-threaded search in the future.

Please note that these changes do not improve the engine's strength.

# Lambergar v0.4.0

## Builds

Currently there are two basic build: vintage and popcnt. Vintage version is for really old computers, popcnt is for modern computers.

## Release Notes

Main features

- New evaluation parameters
- Tuner for evaluation parameters
- Changed history heuristics and move sorting
- Improved apiration window algorithm
- Changes in prunings and reductions
- I have been changing and massaging the code quite a bit, so I lost the track of all the changes, but the improvements are quite substantial

```sh
Time controls 30s+0.5s

Score of Lambergar vs Lamb031: 706 - 67 - 207  [0.826] 980
...      Lambergar playing White: 379 - 21 - 91  [0.865] 491
...      Lambergar playing Black: 327 - 46 - 116  [0.787] 489
...      White vs Black: 425 - 348 - 207  [0.539] 980
Elo difference: 270.6 +/- 22.9, LOS: 100.0 %, DrawRatio: 21.1 %
```

# Lambergar v0.3.1c

## Release Notes

- Release with different x86-64 microarchitecture levels:
  - x86-64 is baseline microarchitecture
  - x86-64-v2 supports vector instructions up to Streaming SIMD Extensions 4.2 (SSE4.2) and Supplemental Streaming SIMD Extensions 3 (SSSE3), the POPCNT instruction.
  - x86-64-v3 adds vector instructions up to AVX2, MOVBE, and additional bit-manipulation instructions.
  - x86-64-v4 includes vector instructions from some of the AVX-512 variants.

(source: [https://developers.redhat.com/blog/2021/01/05/building-red-hat-enterprise-linux-9-for-the-x86-64-v2-microarchitecture-level#background_of_the_x86_64_microarchitecture_levels](https://developers.redhat.com/blog/2021/01/05/building-red-hat-enterprise-linux-9-for-the-x86-64-v2-microarchitecture-level#background_of_the_x86_64_microarchitecture_levels))

# Lambergar v0.3.1b

## Release Notes

- Fixed issues with UCI commands requiring space after command to work on Windows.
- Compiled for two Intel architectures

# Lambergar v0.3.1

## Release Notes

This is the first public release of Lambergar chess engine.