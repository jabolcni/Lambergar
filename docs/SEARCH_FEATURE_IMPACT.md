# Search Feature Impact

This file tracks search-feature ablations and their measured Elo impact against the current baseline engine.

## How We Will Use This

For each feature:

1. Keep the current engine as the baseline.
2. Disable exactly one feature or one tightly related micro-feature.
3. Run `fastchess` against the baseline.
4. Paste the result here.
5. Record the estimated Elo drop and a short interpretation.

Important: the measured number is the strength loss of the modified engine relative to the current baseline, not the standalone value of the feature in isolation.

## QSearch

### Current Behavior

Relevant code:

- [src/search.zig](/home/student/tuner/Lambergar-1/src/search.zig:1401)
- [src/position.zig](/home/student/tuner/Lambergar-1/src/position.zig:3151)
- [src/movescorer.zig](/home/student/tuner/Lambergar-1/src/movescorer.zig:97)

What the current qsearch does:

- It is entered from main search when remaining depth is `<= 0`, unless the side to move is in check, in which case the main search keeps one ply to search evasions first.
- It uses TT lookup and can return immediately on exact or bounding hits.
- When not in check, it uses a stand-pat static evaluation as the initial lower bound.
- It generates noisy legal moves only.
- In check, `generate_noisy_legals()` returns all legal evasions, not just captures.
- It orders moves with `score_noisy_moves()`.
- It applies delta pruning for captures.
- It applies SEE pruning to reject clearly losing tactical moves.
- It stores qsearch results back into TT.

### QSearch Features To Test

These are the cleanest first ablations inside the current qsearch:

| ID | Feature | Code area | Expected impact | Elo |
|---|---|---|---|---|
| QS-1 | Entire qsearch versus immediate static eval at horizon | `pvs()` / `quiescence()` entry | Very large | TBD |
| QS-2 | Stand-pat evaluation | `quiescence()` stand-pat block | Large | TBD |
| QS-3 | QSearch TT cutoffs and storage | `quiescence()` TT block | Medium | TBD |
| QS-4 | Noisy-only move expansion / in-check evasions behavior | `generate_noisy_legals()` use | Large | TBD |
| QS-5 | Delta pruning | `qsearch_delta_margin` block | Small to medium | TBD |
| QS-6 | SEE pruning in qsearch | `see_value()` gate | Small to medium | TBD |
| QS-7 | Noisy move ordering quality | `score_noisy_moves()` | Small to medium | TBD |

### Recommended Test Order

Recommended order for stable learning:

1. `QS-5` delta pruning
2. `QS-6` SEE pruning
3. `QS-3` TT cutoffs/storage
4. `QS-7` noisy move ordering
5. `QS-2` stand-pat
6. `QS-4` qsearch move-set behavior
7. `QS-1` entire qsearch

This order starts with local heuristics and leaves the structurally huge changes for later, where the Elo losses may be large and less diagnostic.

### Experiment Log

Use one row per test run.

| ID | Change made | Fastchess result | Estimated Elo drop | Notes |
|---|---|---|---|---|
| QS-5 | Disabled qsearch delta pruning | Elo: -1.74 +/- 5.97, LOS 28.42%, 4000 games | Small or insignificant so far | Early result suggests little standalone impact in this engine; more games would be needed to claim near-zero confidently |
| QS-6 | Disabled qsearch SEE pruning | 2+0.02: Elo -46.95 +/- 14.01; 5+0.05: Elo -55.65 +/- 12.27 | Large | Strong, consistent loss at both time controls; qsearch SEE pruning is an important tactical and efficiency filter in this engine |
| QS-3 | Disabled qsearch TT reuse/storage | Isolated 2+0.02: Elo -21.06 +/- 10.88; earlier cumulative runs: -106.78 +/- 20.42 and -69.76 +/- 8.80 | Medium, with stronger upside possible | Clean isolation says qsearch TT is a real contributor, but much smaller than the earlier cumulative estimate; likely still worth rechecking with more games and perhaps at a slower TC |
| QS-7 | Disabled qsearch noisy move ordering | 2+0.02: Elo -9.03 +/- 5.35 | Small | Likely a modest strength contributor; far smaller than qsearch SEE pruning and probably smaller than qsearch TT |
| QS-2 | Not tested yet | - | TBD | Stand-pat still enabled |
| QS-4 | Quiet qsearch nodes restricted to captures only (quiet promotions removed) | 2+0.02: Elo -10.56 +/- 4.78 | Small to medium | Quiet promotions in qsearch appear worth some Elo, but the effect is far smaller than SEE pruning and likely smaller than TT |
| QS-1 | Replaced quiet-horizon qsearch with immediate static eval | 2+0.02: Elo -118.77 +/- 5.28 | Very large | Full qsearch is one of the biggest search contributors tested so far; this is a clear, stable result |

### Control Notes

- Restored-baseline sanity check after reverting the broken stand-pat experiment: `2+0.02` scored `-1.70 +/- 4.89 Elo` over 7344 games. Treat this as confirmation that the current binary is back near baseline strength, not as a feature result.

### Notes For Interpretation

- If a feature scores near `0 Elo` over enough games, that does not always mean it is useless. It may overlap heavily with another feature already present in the engine.
- Large negative Elo after removing a feature usually means either direct tactical value or a search-efficiency gain that converts into strength.
- Qsearch features interact strongly with move ordering, SEE, TT behavior, and static evaluation quality, so some non-additivity is expected.
- For qsearch specifically, "in check" handling is part of correctness and tactical coverage, not just speed.

### QSearch Summary

Short takeaways from the current qsearch pass:

- Full qsearch is a major strength source in the engine, worth about `119 Elo` in the current fast test setup.
- Inside qsearch, SEE pruning is the biggest measured internal feature so far, costing about `47-56 Elo` when removed.
- Qsearch TT reuse/storage is clearly useful, but the clean isolated result (`~21 Elo`) is much smaller than the earlier cumulative estimate, so it is worth revisiting later with more games or a slower time control.
- Quiet promotions in qsearch and noisy move ordering both help, but they look like secondary contributors.
- Delta pruning appears close to insignificant in the current setup, at least as a standalone qsearch feature.

Practical ranking from strongest to weakest evidence so far:

1. Full qsearch
2. Qsearch SEE pruning
3. Qsearch TT reuse/storage
4. Quiet promotions in qsearch
5. Qsearch noisy move ordering
6. Qsearch delta pruning

## Razoring

Relevant code:

- [src/search.zig](/home/student/tuner/Lambergar-1/src/search.zig:1076)

Current result:

| ID | Change made | Fastchess result | Estimated Elo drop | Notes |
|---|---|---|---|---|
| RZ-1 | Disabled razoring | 2+0.02: Elo -10.65 +/- 5.71 | Small to medium | Razoring looks useful but not huge in the current engine; it likely saves work on poor frontier nodes without carrying the search by itself |

## Null Move Pruning

Relevant code:

- [src/search.zig](/home/student/tuner/Lambergar-1/src/search.zig:1092)

Current result:

| ID | Change made | Fastchess result | Estimated Elo drop | Notes |
|---|---|---|---|---|
| NMP-1 | Disabled null move pruning | 2+0.02: Elo -36.22 +/- 8.20 | Medium to large | Null move pruning is one of the stronger non-qsearch search features tested so far; it looks substantially more important than razoring |

## Reverse Futility Pruning

Relevant code:

- [src/search.zig](/home/student/tuner/Lambergar-1/src/search.zig:1085)

Current result:

| ID | Change made | Fastchess result | Estimated Elo drop | Notes |
|---|---|---|---|---|
| RFP-1 | Disabled reverse futility pruning | 2+0.02: Elo -72.60 +/- 12.57 | Large | Reverse futility pruning is one of the strongest non-qsearch pruning features measured so far in this engine |

## Late Move Reductions

Relevant code:

- [src/search.zig](/home/student/tuner/Lambergar-1/src/search.zig:1308)

Current result:

| ID | Change made | Fastchess result | Estimated Elo drop | Notes |
|---|---|---|---|---|
| LMR-1 | Disabled late move reductions | 2+0.02: Elo -89.82 +/- 16.75 | Large to very large | LMR is one of the strongest search features measured so far and clearly a top-tier speed/strength contributor in this engine |

## Main-Search SEE Pruning

Relevant code:

- [src/search.zig](/home/student/tuner/Lambergar-1/src/search.zig:1212)

Current result:

| ID | Change made | Fastchess result | Estimated Elo drop | Notes |
|---|---|---|---|---|
| MSEE-1 | Disabled main-search SEE pruning | 2+0.02: Elo -42.65 +/- 8.49 | Medium to large | Main-search SEE pruning is a strong tactical/filtering feature and looks clearly more important than razoring |

## Main-Search Futility Pruning

Relevant code:

- [src/search.zig](/home/student/tuner/Lambergar-1/src/search.zig:1201)

Current result:

| ID | Change made | Fastchess result | Estimated Elo drop | Notes |
|---|---|---|---|---|
| FP-1 | Disabled quiet-move futility pruning | 2+0.02: Elo -2.22 +/- 5.61 | Tiny or insignificant | In this engine, the quiet futility skip looks close to negligible as a standalone feature at this time control |

## Late Move Pruning

Relevant code:

- [src/search.zig](/home/student/tuner/Lambergar-1/src/search.zig:1206)

Current result:

| ID | Change made | Fastchess result | Estimated Elo drop | Notes |
|---|---|---|---|---|
| LMP-1 | Disabled late move pruning | 2+0.02: Elo -17.19 +/- 9.38 | Small to medium | LMP helps, but its effect looks much smaller than LMR and the strongest pruning features in this engine |

## History-Based Quiet Pruning

Relevant code:

- [src/search.zig](/home/student/tuner/Lambergar-1/src/search.zig:1193)

Current result:

| ID | Change made | Fastchess result | Estimated Elo drop | Notes |
|---|---|---|---|---|
| HP-1 | Disabled history-based quiet pruning cutoffs | 2+0.02: Elo -1.48 +/- 4.65 | Tiny or insignificant | These history-score skip gates look close to negligible as a standalone feature in the current engine at this time control |

## Check Extension

Relevant code:

- [src/search.zig](/home/student/tuner/Lambergar-1/src/search.zig:1252)

Current result:

| ID | Change made | Fastchess result | Estimated Elo drop | Notes |
|---|---|---|---|---|
| CE-1 | Disabled check extension | 2+0.02: Elo -0.42 +/- 6.54; 10+0.1: Elo -4.67 +/- 10.20 | Tiny or insignificant | Check extension looks close to negligible as a standalone feature in the current engine across both tested time controls |

## Singular Extensions

Relevant code:

- [src/search.zig](/home/student/tuner/Lambergar-1/src/search.zig:1254)

Current result:

| ID | Change made | Fastchess result | Estimated Elo drop | Notes |
|---|---|---|---|---|
| SE-1 | Disabled singular extensions | 2+0.02: Elo -73.99 +/- 16.04; 10+0.1: Elo -56.47 +/- 26.30 | Large | Sample is still modest, but both time controls agree that singular extensions are one of the stronger search features in this engine |

## Internal Iterative Deepening

Relevant code:

- [src/search.zig](/home/student/tuner/Lambergar-1/src/search.zig:1039)

Current result:

| ID | Change made | Fastchess result | Estimated Elo drop | Notes |
|---|---|---|---|---|
| IID-1 | Disabled internal iterative deepening | 2+0.02: Elo -9.89 +/- 5.80 | Small to medium | IID helps, but its standalone effect looks much smaller than the strongest pruning and extension features in this engine |

## Main TT Cutoff Block

Relevant code:

- [src/search.zig](/home/student/tuner/Lambergar-1/src/search.zig:997)

Current result:

| ID | Change made | Fastchess result | Estimated Elo drop | Notes |
|---|---|---|---|---|
| TTCUT-1 | Disabled the main TT cutoff block | 2+0.02: Elo -78.82 +/- 10.21 | Large | The main TT cutoff block is one of the strongest search features measured so far, as expected for a core reuse mechanism |

## TT Move Ordering

Relevant code:

- [src/search.zig](/home/student/tuner/Lambergar-1/src/search.zig:991)
- [src/search.zig](/home/student/tuner/Lambergar-1/src/search.zig:1468)

Current result:

| ID | Change made | Fastchess result | Estimated Elo drop | Notes |
|---|---|---|---|---|
| TTMO-1 | Disabled TT move ordering while keeping TT cutoffs/storage | 2+0.02: Elo -122.03 +/- 10.47 | Very large | TT move ordering is one of the single strongest search features measured so far in this engine; surprisingly, its measured standalone effect is even larger than the main TT cutoff block in the current test set |
| TTMO-MAIN-1 | Disabled only main-search TT move ordering | 2+0.02: Elo -124.60 +/- 11.55; confirm 2+0.02: Elo -119.66 +/- 24.25; confirm 10+0.1: Elo -115.10 +/- 45.19 | Very large | The confirmation pass supports the same conclusion: the huge TT move-ordering effect overwhelmingly comes from the main search rather than qsearch |
| TTMO-QS-1 | Disabled only qsearch TT move ordering | 2+0.02: Elo -7.42 +/- 5.90 | Small | Qsearch TT ordering helps a bit, but the large TT move-ordering effect is overwhelmingly coming from the main search |

## Killer-Move Ordering

Relevant code:

- [src/movescorer.zig](/home/student/tuner/Lambergar-1/src/movescorer.zig:46)

Current result:

| ID | Change made | Fastchess result | Estimated Elo drop | Notes |
|---|---|---|---|---|
| KMO-1 | Disabled killer-move ordering | 2+0.02: Elo -5.43 +/- 4.72 | Small | Killer ordering helps a bit, but it is much smaller than TT move ordering and below the stronger pruning features |

## Countermove Ordering

Relevant code:

- [src/movescorer.zig](/home/student/tuner/Lambergar-1/src/movescorer.zig:46)

Current result:

| ID | Change made | Fastchess result | Estimated Elo drop | Notes |
|---|---|---|---|---|
| CMO-1 | Disabled countermove ordering | 2+0.02: Elo -5.04 +/- 4.66 | Small | Countermove ordering looks very similar in size to killer ordering: useful, but much smaller than TT or history ordering |

## Quiet History Ordering

Relevant code:

- [src/movescorer.zig](/home/student/tuner/Lambergar-1/src/movescorer.zig:46)

Current result:

| ID | Change made | Fastchess result | Estimated Elo drop | Notes |
|---|---|---|---|---|
| HMO-1 | Disabled quiet history ordering | 2+0.02: Elo -138.56 +/- 17.06 | Very large | Quiet history ordering is one of the single strongest search features measured so far in this engine, even larger than TT move ordering in the current sample |

## Quiet History Update Bundle

Relevant code:

- [src/search.zig](/home/student/tuner/Lambergar-1/src/search.zig:1398)
- [src/history.zig](/home/student/tuner/Lambergar-1/src/history.zig:272)

Current result:

| ID | Change made | Fastchess result | Estimated Elo drop | Notes |
|---|---|---|---|---|
| HUP-1 | Disabled `history.update_all_history()` on quiet beta cutoffs | 2+0.02: Elo -489.89 +/- 55.22 | Enormous, but bundled | This is not just "quiet history update": the helper also updates killer moves, countermoves, and continuation history, so the huge loss reflects a whole learning/update bundle rather than one isolated mechanism |
| HUP-CORE-1 | Disabled only quiet-history and continuation-history updates inside `update_all_history()` | 2+0.02: Elo -331.05 +/- 30.47 | Enormous | The core quiet-history/continuation-history learning itself is carrying a huge amount of strength; killer/countermove updates alone explain only a minority of the bundled `HUP-1` result |
| HUP-CONT-1 | Disabled only continuation-history updates | 2+0.02: Elo -45.89 +/- 10.30 | Strong | Continuation history is clearly valuable, but it is not the main driver of the enormous bundled history-update result |
| HUP-MAIN-1 | Disabled only main quiet-history table updates | 2+0.02: Elo -26.38 +/- 5.76 | Medium | The main quiet-history table is also clearly valuable, though in this split it measures smaller than continuation history |

## Capture History Update

Relevant code:

- [src/search.zig](/home/student/tuner/Lambergar-1/src/search.zig:1403)

Current result:

| ID | Change made | Fastchess result | Estimated Elo drop | Notes |
|---|---|---|---|---|
| CHUP-1 | Disabled capture-history update on beta cutoffs | 2+0.02: Elo -1.77 +/- 5.50 | Tiny or insignificant | Capture-history learning looks close to negligible as a standalone feature in the current engine at this time control |

## Search Summary

### Biggest Takeaways

- The strongest search-side themes in this engine are move ordering, history-based learning, TT reuse, and a few major selective-pruning mechanisms.
- Quiet-history learning and quiet-history ordering are both enormous. They are not marginal heuristics here; they are central strength sources.
- TT is doing two different high-value jobs:
  - main TT cutoffs are very strong,
  - TT move ordering is even stronger in the current tests, and almost all of that ordering gain comes from the main search rather than qsearch.
- Qsearch is a major source of strength overall, and qsearch SEE pruning is one of its most important internal pieces.
- Several classic heuristics that often sound important turned out to be small or near-zero in this engine when isolated: qsearch delta pruning, quiet futility skip, history-based quiet skip gates, check extension, and the small TT upper-bound alpha shortcut.

### Approximate Ranking

This is a practical first-pass ranking based on current tests, not a mathematically exact ordering.

Top tier:

- Quiet history update bundle: `HUP-1`, huge bundled effect
- Quiet-history plus continuation-history core learning: `HUP-CORE-1`
- Quiet history ordering: `HMO-1`
- TT move ordering in main search: `TTMO-MAIN-1`
- Full qsearch: `QS-1`
- Correction-history updates: `CORR-1`

Very strong:

- LMR: `LMR-1`
- Main TT cutoff block: `TTCUT-1`
- Reverse futility pruning: `RFP-1`
- Singular extensions: `SE-1`

Strong:

- Qsearch SEE pruning: `QS-6`
- Main-search SEE pruning: `MSEE-1`
- Null move pruning: `NMP-1`
- Continuation-history updates: `HUP-CONT-1`

Medium:

- Qsearch TT reuse/storage: `QS-3`
- Main quiet-history table updates: `HUP-MAIN-1`
- SEE-based good/bad capture ordering split: `CSC-1`

Small to medium:

- Razoring: `RZ-1`
- LMP: `LMP-1`
- IID: `IID-1`
- Quiet promotions in qsearch: `QS-4`
- Qsearch TT ordering only: `TTMO-QS-1`

Small:

- Qsearch noisy move ordering: `QS-7`
- Killer ordering: `KMO-1`
- Countermove ordering: `CMO-1`
- Capture-history ordering: `CHO-1`

Tiny or insignificant so far:

- Qsearch delta pruning: `QS-5`
- Quiet-move futility skip: `FP-1`
- History-based quiet pruning cutoffs: `HP-1`
- Check extension: `CE-1`
- TT upper-bound alpha shortcut: `TTUB-1`
- Capture-history update: `CHUP-1`

### Important Interpretation Notes

- Some tests are clean isolated ablations and some are bundle splits. The history-related results especially should be read in that context.
- The very large values on ordering and learning features suggest your engine is heavily dependent on getting promising moves searched first and on reinforcing successful quiet patterns over time.
- A feature with low standalone Elo is not necessarily useless. It may be redundant with another mechanism or mostly help in edge cases.
- Where sample size was smaller, the exact rank inside a tier should be treated as approximate rather than final.

### Recommended Next Steps

If continuing search analysis, the most valuable next steps are probably:

1. Freeze the current search results and treat them as the first-pass baseline map.
2. Re-run a few especially important features at a slower time control for stability:
   - `TTMO-MAIN-1`
   - `HMO-1`
   - `CORR-1`
   - `LMR-1`
   - `RFP-1`
3. Move on to evaluation-side features, where the same methodology should now work well.

## Overall Search Summary

### Main Conclusions

- Search strength in this engine is dominated by a few major systems rather than by dozens of small heuristics.
- The biggest themes are:
  - history-based learning,
  - move ordering,
  - transposition-table reuse,
  - qsearch quality,
  - and a handful of major selective-search mechanisms.
- Many famous "classic" heuristics turned out to be only modest or tiny once isolated.

### Strongest Search Features Seen So Far

These are the biggest measured contributors from the current pass:

- Quiet-history/continuation-history learning:
  - `HUP-CORE-1`: `-331.05 +/- 30.47 Elo`
  - bundled helper `HUP-1`: `-489.89 +/- 55.22 Elo`
- Quiet history ordering:
  - `HMO-1`: `-138.56 +/- 17.06 Elo`
- Main TT move ordering:
  - `TTMO-MAIN-1`: roughly `-115` to `-125 Elo` across runs
- Full qsearch:
  - `QS-1`: `-118.77 +/- 5.28 Elo`
- Correction-history updates:
  - `CORR-1`: `-102.74 +/- 18.95 Elo`
- LMR:
  - `LMR-1`: `-89.82 +/- 16.75 Elo`
- Main TT cutoff block:
  - `TTCUT-1`: `-78.82 +/- 10.21 Elo`
- Reverse futility pruning:
  - `RFP-1`: `-72.60 +/- 12.57 Elo`
- Singular extensions:
  - `SE-1`: around `-56` to `-74 Elo`

### What Matters Most Inside Ordering

- Quiet history ordering is huge.
- TT move ordering is huge, and the large TT-ordering effect comes almost entirely from the main search.
- SEE-based capture ordering is materially important:
  - `CSC-1`: `-21.21 +/- 10.86 Elo`
- Killer, countermove, and capture-history ordering are all much smaller:
  - `KMO-1`: `-5.43 +/- 4.72 Elo`
  - `CMO-1`: `-5.04 +/- 4.66 Elo`
  - `CHO-1`: `-6.56 +/- 4.68 Elo`

### What Matters Most Inside Learning

- The update-side learning story is dominated by quiet-history and continuation-history updates.
- Split results:
  - `HUP-CONT-1`: `-45.89 +/- 10.30 Elo`
  - `HUP-MAIN-1`: `-26.38 +/- 5.76 Elo`
  - `HUP-KC-1`: `-1.66 +/- 6.88 Elo`
  - `CHUP-1`: `-1.77 +/- 5.50 Elo`
- So the huge bundled history-update effect is overwhelmingly coming from quiet-history plus continuation-history learning, not from killer/countermove updates or capture-history updates.

### What Looks Strong But Not Top Tier

- Qsearch SEE pruning:
  - `QS-6`: around `-47` to `-56 Elo`
- Main-search SEE pruning:
  - `MSEE-1`: `-42.65 +/- 8.49 Elo`
- Null move pruning:
  - `NMP-1`: `-36.22 +/- 8.20 Elo`
- Qsearch TT reuse/storage:
  - `QS-3`: `-21.06 +/- 10.88 Elo`

### What Looks Modest

- Razoring:
  - `RZ-1`: `-10.65 +/- 5.71 Elo`
- IID:
  - `IID-1`: `-9.89 +/- 5.80 Elo`
- Qsearch quiet promotions:
  - `QS-4`: `-10.56 +/- 4.78 Elo`
- LMP:
  - `LMP-1`: `-17.19 +/- 9.38 Elo`
- Qsearch-only TT ordering:
  - `TTMO-QS-1`: `-7.42 +/- 5.90 Elo`

### What Looks Tiny Or Near-Zero

- Qsearch delta pruning:
  - `QS-5`: `-1.74 +/- 5.97 Elo`
- Quiet-move futility skip:
  - `FP-1`: `-2.22 +/- 5.61 Elo`
- History-based quiet pruning cutoffs:
  - `HP-1`: `-1.48 +/- 4.65 Elo`
- Check extension:
  - `CE-1`: near zero at both tested time controls
- TT upper-bound alpha shortcut:
  - `TTUB-1`: `-2.30 +/- 4.75 Elo`

### Practical Interpretation

- This engine appears to get much more strength from:
  - learning which quiet moves are good,
  - ordering promising moves very early,
  - and avoiding expensive search with a few high-value selective mechanisms,
  than from stacking lots of small local pruning rules.
- If time is limited, future tuning effort should probably focus more on:
  - history-learning quality,
  - TT integration and ordering,
  - LMR/selective mechanisms,
  - and qsearch quality,
  rather than on micro-optimizing the tiny standalone heuristics.

## Next 10 Experiments

These are the most promising next experiments if the goal is to gain Elo efficiently from the current search architecture.

### Priority Order

1. Retune main quiet-history bonus/malus scaling.
   Why: quiet-history learning and quiet-history ordering were among the biggest measured strength sources in the whole search.

2. Retune continuation-history weights and blending.
   Why: continuation history was clearly strong on its own and likely interacts heavily with both ordering and pruning quality.

3. Retune TT move-ordering trust and replacement quality.
   Why: main-search TT move ordering was one of the single biggest measured search effects.

4. Retune LMR schedule.
   Why: LMR was top-tier in Elo impact, so even a modest improvement here could be very valuable.

5. Retune reverse futility pruning margins.
   Why: reverse futility pruning measured much larger than expected and is clearly a major pruning lever.

6. Retune correction-history update conditions and weights.
   Why: correction-history learning measured as a very large strength source.

7. Retune qsearch SEE pruning thresholds.
   Why: qsearch SEE pruning was one of the strongest internal qsearch features.

8. Retune main-search SEE pruning thresholds.
   Why: main-search SEE pruning was also clearly strong and should be tunable.

9. Retune null move pruning reduction formula and verification conditions.
   Why: null move pruning was important, but still below the very top tier, which makes it a good second-wave target.

10. Retune singular-extension trigger conditions.
   Why: singular extensions were strong, but likely more sensitive and noisier than the ordering/history levers above.

### Suggested Form

For each experiment:

1. Change one tightly scoped part only.
2. Test against the current baseline.
3. Record:
   - exact code change,
   - fastchess result,
   - whether the effect looks clean, noisy, or bundled,
   - whether the change should be kept, split further, or retuned.

### Concrete First Pass

If we want the highest-probability immediate search improvements, the best first sequence is:

1. Main quiet-history formula
2. Continuation-history formula
3. TT move-ordering quality
4. LMR schedule
5. Reverse futility margins

### What Not To Prioritize

Unless they are nearly free, these should be lower-priority for Elo work right now:

- qsearch delta pruning
- quiet-move futility skip
- history-based quiet skip gates
- check extension
- TT upper-bound alpha shortcut
- capture-history update alone

### Why This Order

- The plan starts with features that already tested as huge, because they offer the biggest upside and the clearest signal.
- It favors tunable systems over binary on/off heuristics.
- It postpones the near-zero features because even perfect tuning there is unlikely to return much Elo.

## Search Retune Experiments

These are tuning experiments on top of the baseline engine, not feature-removal ablations.

| ID | Change made | Fastchess result | Interpretation |
|---|---|---|---|
| RT-1 | Increase only main quiet-history table updates by 25% | 2+0.02: Elo -10.97 +/- 9.45 | This looks worse than baseline, so the main quiet-history table likely does not want a blanket upward rescale in its current form |
| RT-2 | Decrease only continuation-history update strength by 25% | 2+0.02: Elo -1.78 +/- 4.71 | This looks close to neutral, so the current continuation-history update scale may already be near a flat region locally |
| RT-3 | Increase only continuation-history update strength by 25% | 2+0.02: Elo -2.00 +/- 4.70 | This also looks close to neutral, which reinforces the view that continuation-history update strength is already in a locally flat region |
| RT-4 | Use TT move ordering only for EXACT/LOWER entries in main search | 2+0.02: Elo -27.57 +/- 20.32 | This looks worse than baseline so far, which suggests upper-bound TT entries still help enough as ordering hints to keep them |
| RT-5 | Reduce default `LMRScale` from 50 to 46 | 2+0.02: Elo -24.86 +/- 13.03 | This looks worse than baseline, so the current engine likely does not want a blanket reduction in LMR aggressiveness |
| RT-6 | Lower `FutilityPruneSlope` from 85 to 78 | 2+0.02: Elo -18.78 +/- 7.77 | This looks worse than baseline, so making reverse futility pruning more aggressive in this simple way appears harmful |
| RT-7 | Lower max correction-history update weight from 128 to 112 | 2+0.02: Elo -20.12 +/- 12.15 | This looks worse than baseline, so the engine likely prefers stronger correction-history learning rather than weaker |
| RT-8 | Raise max correction-history update weight from 128 to 144 | 2+0.02: Elo -29.75 +/- 18.65 | This also looks worse than baseline, which suggests the current correction-history update strength may already be near a local optimum |
| RT-9 | Loosen qsearch SEE pruning from `see_val < -1` to `see_val < -20` | 2+0.02: Elo -1.67 +/- 10.35; 10+0.1: Elo +0.28 +/- 10.90 | This looks neutral, so the current qsearch SEE threshold is not obviously better than a slightly looser version |
| RT-10 | Increase `SeeQuietCoeff` from `46` to `50` | 2+0.02: Elo -4.88 +/- 5.24; 10+0.1: Elo -28.54 +/- 31.05 | This looks somewhat worse than baseline, so loosening quiet-move SEE pruning does not appear promising |
| RT-11 | Increase `SeeCaptureCoeff` from `10` to `11` | 2+0.02: Elo -48.44 +/- 23.92 | This looks clearly worse than baseline, so loosening capture SEE pruning appears harmful |
| RT-12 | Decrease `SeeCaptureCoeff` from `10` to `9` | 2+0.02: Elo -37.91 +/- 24.57 | This also looks worse than baseline, so the current capture SEE threshold appears reasonably well tuned already |
| RT-13 | Increase `NullMoveBetaDiv` from `230` to `250` | 2+0.02: Elo -5.18 +/- 7.45; 10+0.1: Elo -4.04 +/- 22.57 | This looks near-neutral to slightly worse, so making the beta-based null-move add-on weaker does not appear helpful |
| RT-14 | Decrease `NullMoveBetaDiv` from `230` to `210` | 2+0.02: Elo -4.22 +/- 11.69; 10+0.1: Elo -1.20 +/- 15.59 | This also looks near-neutral, so the beta-based null-move add-on seems locally flat around the current baseline |
| RT-15 | Increase `NullMoveBase` from `5` to `6` | 2+0.02: Elo -16.04 +/- 12.90 | This looks worse than baseline, so making the base null-move reduction more aggressive does not appear promising |
| RT-16 | Decrease `NullMoveBase` from `5` to `4` | 2+0.02: Elo -16.04 +/- 12.90 | As reported, this also looks worse than baseline, so the base null-move reduction does not seem like an easy improvement lever either |
| RT-17 | Keep quiet-history bonus unchanged but reduce failed-quiet malus to 3/4 of baseline | 2+0.02: Elo -8.69 +/- 13.04 | This looks near-neutral to somewhat worse, so history learning does not appear to want softer quiet maluses in this simple form |
| RT-18 | Keep quiet-history bonus unchanged but increase failed-quiet malus to 5/4 of baseline | 2+0.02: Elo -1.26 +/- 11.21 | This looks close to neutral, so stronger quiet maluses do not show a clear gain either |
| RT-19 | Reduce distant continuation updates so `cont4/cont6` get `bonus / 3` instead of `bonus / 2` | 2+0.02: Elo -4.73 +/- 4.71 | This looks somewhat worse than baseline, so long-range continuation learning does not appear overweighted |
| RT-20 | Increase distant continuation updates so `cont4/cont6` get `2 * bonus / 3` instead of `bonus / 2` | 2+0.02: Elo -8.51 +/- 9.58 | This also looks worse than baseline, so simply making distant continuation learning stronger is not promising either |
| RT-21 | Keep `cont4` at `bonus / 2`, but reduce `cont6` to `bonus / 3` | 2+0.02: Elo -6.86 +/- 4.67 | This looks somewhat worse than baseline, so the furthest continuation leg does not appear overweighted either |
| RT-22 | Keep `cont4` at `bonus / 2`, but increase `cont6` to `2 * bonus / 3` | 2+0.02: Elo +1.10 +/- 7.15; 10+0.1: Elo -5.07 +/- 19.20 | This looks inconclusive overall, with no clear improvement signal strong enough to keep over baseline |
| RT-23 | Use main-search TT move for ordering only when `tt_depth >= depth - 2` | 2+0.02: Elo -6.73 +/- 7.00 | This looks somewhat worse than baseline, so broad TT move usage still appears preferable |
| RT-24 | Differentiate main-search TT move ordering by bound quality | 2+0.02: Elo -23.83 +/- 20.14 | This looks worse than baseline, so the current uniform top TT-move priority seems better than this bound-aware split |
| RT-25 | Increase exact-entry replacement bonus from `8` to `16` | 2+0.02: Elo -8.79 +/- 10.24 | This looks somewhat worse than baseline, so stronger exact-entry protection does not appear helpful in this simple form |
| RT-26 | Reduce TT replacement age penalty from `age_diff * 4` to `age_diff * 3` | 2+0.02: Elo +1.10 +/- 9.50; 10+0.1: Elo +2.00 +/- 4.09 | This is the first retune so far that looks plausibly beneficial, especially at longer time control, so it is worth keeping for now |
| RT-27 | Do not preserve a stale move when replacing a different TT key with an entry that has no move | 2+0.02: Elo -7.15 +/- 8.35 | This looks somewhat worse than baseline, so preserving an old move in that case still seems to help more than it hurts |
| RT-28 | Add a small replacement bonus for TT entries that already contain a move | 2+0.02: Elo -10.06 +/- 10.74 | This looks somewhat worse than baseline, so explicit move-carrying preference in replacement does not appear helpful on top of the current policy |
| RT-29 | Reduce TT replacement age penalty further from `age_diff * 3` to `age_diff * 2` | 2+0.02: Elo -0.00 +/- 5.21 | This looks neutral, so there is no clear reason yet to prefer it over the milder `age_diff * 3` change |
| RT-30 | Reduce exact-entry replacement bonus from `8` to `4` | 2+0.02: Elo -0.00 +/- 5.21 | This also looks neutral, so there is no clear reason to prefer it over the current kept policy |
