# Release notes

## Lambergar 1.2

### Builds

Currently, there are five builds:

- x86-64-v3: AVX2 support, best for using with NN evaluation and should be a preferred choice for best performance.
- x86-64-v2: popcount support, suitable for modern computers.
- x86-64-v1: vintage version is for really old computers.
- aarch64-linux: version for Raspberry Pi 5,
- x86-64-v4: AVX-512 support.

### Release Notes

- New neural network called `cop.nnue`, which is slightly stronger.
-	Added support for multithreading (up to 32 threads).
-	Improvements in Transposition Table storage, now better optimized for multithreading. It uses concurrent access with locks with fairly high level of granularity (<https://www.chessprogramming.org/Shared_Hash_Table#Concurrent_Access>). These changes do not affect single-threaded performance.

```sh
Time controls 10s+0.1s

Score of Lambergar-1.2 vs Lambergar-1.1: 157 - 75 - 349  [0.571] 581
...      Lambergar-1.2 playing White: 105 - 23 - 163  [0.641] 291
...      Lambergar-1.2 playing Black: 52 - 52 - 186  [0.500] 290
...      White vs Black: 157 - 75 - 349  [0.571] 581
Elo difference: 49.4 +/- 17.7, LOS: 100.0 %, DrawRatio: 60.1 %
```

### Explanation of Additional Threads in Lambergar Chess Engine

While testing the Lambergar chess engine (written in Zig, running on Windows), you may notice that Process Explorer occasionally shows more threads than expected based on the UCI "Threads" setting (e.g., 3 threads with `Threads = 1`, or 5-7 with `Threads = 4`). These extra threads are not a bug or a resource leak in the engine but are a normal part of how Windows manages processes. Here’s what’s happening:

#### Key Findings

1. **Baseline Threads**
   - The engine always has:
     - **1 UCI Loop Thread**: The main thread, running `uci_loop`, which waits for UCI commands on `stdin` (stack trace shows `ntdll.dll!NtReadFile` when idle).
     - **N Search Threads**: One main search thread (`start_main_search`) plus `N-1` worker threads (`start_search`), where `N` is the UCI "Threads" setting (e.g., 1 for `Threads = 1`, 4 for `Threads = 4`). These show user-code addresses like `lambergar.exe+0x<offset>` during search.
   - Example: With `Threads = 1`, expect 2 threads (UCI + 1 search); with `Threads = 4`, expect 5 threads (UCI + 4 search).

2. **Additional Threads**
- **Windows Thread Pool Workers**: Extra threads occasionally appear with this stack trace:

    ```sh
    ntdll.dll!ZwWaitForWorkViaWorkerFactory+0x14
    ntdll.dll!TpReleaseCleanupGroupMembers+0x747
    KERNEL32.DLL!BaseThreadInitThunk+0x14
    ntdll.dll!RtlUserThreadStart+0x21
    ```

- These are not spawned by the engine but by the Windows operating system as part of its Thread Pool, a system-wide resource for handling I/O, timers, and other tasks.

3. **Behavior Over Time**

- **Startup**: Every Windows process, even a minimal one, starts with at least one Thread Pool worker. In Lambergar, this thread appears when the engine launches but disappears after ~10-30 seconds if unused (e.g., before "go" or in a minimal test with no I/O).
- **During Search**: After issuing "go", the search thread(s) start. About ~1 minute into the search, 1-2 Thread Pool workers may appear due to:
- **I/O**: Frequent `stdout` writes for "info" messages (e.g., depth, score, PV) in `iterative_deepening`.
- **Timers**: Regular checks of `std.time.Timer` for time management (e.g., `self.timer.read()`).
- **Long Run**: After ~8 minutes, these workers may disappear again if I/O or timer activity decreases (e.g., search stabilizes), only to reappear later if demand increases.
- **Post-"stop"**: Search threads terminate cleanly, leaving just the UCI thread (and occasionally workers if I/O persists).

4. **Examples**

- **Threads = 1, Initial "go"**: 2 threads (UCI + 1 search). After ~1 minute, up to 4 (add 2 workers). After 8 minutes, back to 2 if workers time out.
- **Threads = 4, "go depth 200"**: 5 threads (UCI + 4 search). Workers may appear later, raising it to 6-7 temporarily.
- **Minimal Test (no UCI)**: 1 thread (main) + 1 worker at start, dropping to 1 after timeout.

### Why These Threads Appear

- **Windows Thread Pool**: Windows allocates worker threads to every process for system tasks. In Lambergar, they’re triggered by:
- **Console I/O**: Writing search progress to `stdout` (UCI "info" messages) and reading from `stdin`.
- **Timer Checks**: Using `std.time.Timer` for time-based stopping conditions.
- **Dynamic Scaling**: The Thread Pool adds workers (1-2 typically) when it detects sustained activity (e.g., after a minute of searching) and removes them when idle (e.g., after 8 minutes of low demand).
- **Not Engine-Controlled**: These threads are OS-managed, not spawned by Zig’s `std.Thread.spawn` or the engine’s logic. They’re invisible to the `Threads` setting.

#### Why It’s Not a Concern

- **Correctness**: The engine adheres to the UCI "Threads" setting:
- `Threads = 1`: 1 search thread + UCI thread.
- `Threads = 4`: 4 search threads + UCI thread.
- Thread Pool workers don’t participate in the search or affect results; they’re just OS helpers.
- **Resource Usage**: When idle (most of the time, as seen by `ZwWaitForWorkViaWorkerFactory`), these threads use negligible CPU/memory. They only activate briefly for I/O or timer tasks.
- **Standard Behavior**: Many Windows console apps (e.g., C programs with `printf`) show similar Thread Pool threads. It’s a feature of the OS, not a flaw in Lambergar.
- **Clean Termination**: The "stop" command correctly terminates search threads (via `join()`), leaving only the UCI thread (and occasional workers that time out naturally).

#### Tester-Specific Notes

- **Thread Count Variability**: You might see 2, 3, 4, or more threads depending on timing:
- Right after startup: 2 (UCI + worker), then 1 (worker times out).
- After "go": 2 (UCI + search), then 3-4 (workers appear), then 2 again (workers time out).
- With `Threads = 4`: 5 (UCI + 4 search), then 6-7 (workers).
- This fluctuation is normal and tied to Windows’ Thread Pool management, not engine instability.
- **No Impact on Testing**: These extra threads don’t affect move generation, search accuracy, or UCI compliance. They’re benign OS artifacts.
- **Verification**: If concerned, monitor after "stop" (1 thread) or run a minimal Zig program (`while (true) std.time.sleep(1);`)—you’ll still see a worker thread initially, proving it’s OS-driven.

#### Conclusion

The additional threads are **Windows Thread Pool workers**, appearing due to I/O (`stdout` writes) and timer usage during search. They’re a standard part of Windows process management, not under Lambergar’s control, and don’t impact functionality or performance. Expect 1 UCI thread + N search threads (per "Threads" setting), with 0-2 extra workers depending on runtime activity. This is expected, harmless, and consistent with Windows behavior across applications.

## Lambergar 1.1

### Builds

Currently, there are five builds:

- x86-64-v3: AVX2 support, best for using with NN evaluation and should be a preferred choice for best performance.
- x86-64-v2: popcount support, suitable for modern computers.
- x86-64-v1: vintage version is for really old computers.
- aarch64-linux: version for Raspberry Pi 5,
- x86-64-v4: AVX-512 support.

### Release Notes

- Changed some conditions for quiet move pruning based on history.
- Updated the equation for calculating the bonus for history.
- Implemented SIMD for the most computationally demanding functions in NNUE calculation, increasing NPS by **45%**.
- Improved the speed of the move generator, increasing NPS by an additional **15%**.
- Overall, this results in a **60% increase in NPS**. At implemented time controls, this translates to **50% more nodes searched per move** and **10% more depth per move**.
- New net called `trstenjak.nnue`, same architecture as before, but stronger. Trained on 800M positions of self play.
- Compatible with zig version 0.14.0.

```sh
Time controls 10s+0.1s

Score of Lambergar-1.1 vs Lambergar_1.0: 575 - 91 - 462  [0.715] 1128
...      Lambergar-1.1 playing White: 352 - 32 - 180  [0.784] 564
...      Lambergar-1.1 playing Black: 223 - 59 - 282  [0.645] 564
...      White vs Black: 411 - 255 - 462  [0.569] 1128
Elo difference: 159.4 +/- 15.8, LOS: 100.0 %, DrawRatio: 41.0 %
```

## Lambergar 1.0

### Builds

Currently there are four builds:

- x86-64-v3: AVX2 support, best for using with NN evaluation and should be a preferred choice for best performance.
- x86-64-v2: popcount support, suitable for modern computers.
- x86-64-v1: vintage version is for really old computers.
- aarch64-linux: version for Raspberry Pi 5.

### Release Notes

This is a major release. I believe the Lambergar chess engine has matured enough to warrant the release of version 1.0. I am also introducing slight changes to the naming convention by dropping the patch version and removing the letter "v" in front of the version number. While I am sure there are still some significant bugs in the engine, I believe the code has reached a level of maturity where these bugs are no longer critical to its core functionality.

- Added efficient updates (UE) to NN evaluation of positions. I expected a significant improvement in ELO, but the gain was only 20 ELO points.
- Introduced a new network, `zolnir.nnue`, which contributes the majority of the ELO improvement.
- Estimated engine strength is around 3180–3200 ELO.
- Fixed bug: `UseNNUE` was not working because the implementation for switching NNUE on/off did not follow the correct format. This has been fixed to comply with the UCI format: `setoption name UseNNUE value [value]`, where `[value]` is either `true` or `false`.
- Fixed bug: When the UCI command was issued, the line reporting the option name `UseNNUE type check default` always displayed `false`, because it was hardcoded. I had overlooked updating this line to reflect the actual value. This issue is now resolved.

## Lambergar v0.6.0

### Builds

Currently, there are three builds:

- x86-64-v3: AVX2 support, best for using with NN evaluation and should be a preferred choice for best performance.
- x86-64-v2: popcount support, suitable for modern computers.
- x86-64-v1: vintage version is for really old computers.

### Release Notes

This is quite a major release, if the testing of this release goes well, next release will be version v1.0.0. This release brings several important changes:

- Introduction of NN for evaluation. It uses halfKP NNUE architecture, although half of the size typically used. While the architecture of NN is of NNUE type, the engine code for evaluation is actually missing the UE part. This is planned for next release.
- Engine code can now be compiled with latest version of zig, which is version `0.13.0`. The major problem in the past was that the engine code was written in such a manner that newer releases of zig when compiled introduced many calls of memcpy which significantly reduced the speed of the engine (see discussion on [Ziggit](https://ziggit.dev/t/slow-execution-of-the-program-with-newest-zig-version/3976)). By using profiler I was able to identify the problematic parts of code and refractor it.
- Engine code can now be compiled into Debug mode. While this seems obvious and trivial requirement and good coding practice, zig compiler is pretty robust and produces in most cases normally working executables, so this was not my main priority at the start of the programming the engine. However, later it becomes obvious that I need to fix the bugs to be able to keep the code in "good shape".
- Several bug fixes, the major one being related how the time for a single move is calculated in time format with "moves to go". This has now been fixed, and all time controls should work correctly. The rest of the bugs were mainly related to integer overflows, etc.
- Estimated engine strength is around 3040-3060 ELO.
  
## Lambergar v0.5.2

### Release Notes

- This release brings some minor bug fixes.
- UCI interface has been reorganized and is now smaller in terms of code size, but has same functionality.
- Some code refactoring so that the project can be compiled with newer zig versions. However, zig versions newer than `0.12.0-dev.1536+6b9f7e26c` make engine really slow.
- Improved time controls.
- Strength of the engine remains the same as in version v0.5.1.

## Lambergar v0.5.1

### Release Notes

This release brings several bug fixes, with the major one addressing a flaw in the calculation formula for determining the new history value. The previous formula did not limit the history value, leading to an integer overflow issue at certain points, resulting in negative values. Consequently, during move sorting, the best quiet moves were erroneously placed last. This issue was more pronounced during longer time controls, where there were more opportunities to increase the history value. At lower time controls (up to 10 seconds per move), the new formula may actually reduce the engine's strength by 10-20 ELO points. However, at longer time controls, version v0.5.1 demonstrates improvement in engine strength over the previous version. At approximately 1 minute per move, the new version is approximately 50 ELO points stronger, with even more significant gains observed at longer time controls.

## Lambergar v0.5.0

### Builds

Currently, there are two basic builds: vintage and popcnt. The vintage version is for really old computers, while popcnt is for modern computers.

### Release Notes

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

## Lambergar v0.4.1

### Release Notes

This release includes two bug fixes:

- **Excessive Memory Usage**: We resolved an issue with excessive memory usage. The problem originated from the use of an incorrect memory allocator. Previously, we used the Arena memory allocator, which, according to a discussion on [Ziggit](https://ziggit.dev/t/ram-memory-use-and-proper-aloccation-of-array/3053), does not release memory. We have now switched to using the c_allocator directly.

- **Engine Unresponsiveness**: We fixed an issue where the engine would get stuck in search mode and not respond to commands from the interface. This was due to the use of a single thread, and interfacing was only possible once the search had finished. We have now resolved this by using a separate thread for the search routine. This improvement also lays the groundwork for implementing a multi-threaded search in the future.

Please note that these changes do not improve the engine's strength.

## Lambergar v0.4.0

### Builds

Currently, there are two basic build: vintage and popcnt. Vintage version is for really old computers, popcnt is for modern computers.

### Release Notes

Main features

- New evaluation parameters
- Tuner for evaluation parameters
- Changed history heuristics and move sorting
- Improved aspiration window algorithm
- Changes in pruning and reductions
- I have been changing and massaging the code quite a bit, so I lost the track of all the changes, but the improvements are quite substantial

```sh
Time controls 30s+0.5s

Score of Lambergar vs Lamb031: 706 - 67 - 207  [0.826] 980
...      Lambergar playing White: 379 - 21 - 91  [0.865] 491
...      Lambergar playing Black: 327 - 46 - 116  [0.787] 489
...      White vs Black: 425 - 348 - 207  [0.539] 980
Elo difference: 270.6 +/- 22.9, LOS: 100.0 %, DrawRatio: 21.1 %
```

## Lambergar v0.3.1c

### Release Notes

- Release with different x86-64 microarchitecture levels:
  - x86-64 is baseline microarchitecture
  - x86-64-v2 supports vector instructions up to Streaming SIMD Extensions 4.2 (SSE4.2) and Supplemental Streaming SIMD Extensions 3 (SSSE3), the POPCNT instruction.
  - x86-64-v3 adds vector instructions up to AVX2, MOVBE, and additional bit-manipulation instructions.
  - x86-64-v4 includes vector instructions from some of the AVX-512 variants.

(source: [https://developers.redhat.com/blog/2021/01/05/building-red-hat-enterprise-linux-9-for-the-x86-64-v2-microarchitecture-level#background_of_the_x86_64_microarchitecture_levels](https://developers.redhat.com/blog/2021/01/05/building-red-hat-enterprise-linux-9-for-the-x86-64-v2-microarchitecture-level#background_of_the_x86_64_microarchitecture_levels))

## Lambergar v0.3.1b

### Release Notes

- Fixed issues with UCI commands requiring space after command to work on Windows.
- Compiled for two Intel architectures

## Lambergar v0.3.1

### Release Notes

This is the first public release of Lambergar chess engine.
