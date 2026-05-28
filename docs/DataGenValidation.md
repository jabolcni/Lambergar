# Datagen Validation

This documents the Zig-based validator that checks `*.bin` / `*.binhce` datagen output and emits a CSV summary.

## Usage

```bash
zig run src/datagen_validate.zig -- <binfile> [--csv out.csv] [--binhce]
```

- `--csv out.csv`  : write results to this CSV (default `validation.csv`)
- `--binhce`       : force BINHCE record size if ambiguous

## What the validator does

For each record (game/ply):
1. **Decode** `move16` to a `Move` (Zig `position.Move`).
2. **Legality**: generate legal moves and ensure the decoded move is present.
3. **Next SFEN**: play the move and compare packed SFEN against the next record’s SFEN (if present).
4. **UCI output**:
   - Normal chess: standard UCI.
   - Chess960: castling is emitted as `king-from → rook-from` (UCI-960 convention).
5. **Notes**: reason(s) for any failure (`decode_fail`, `from_empty_or_wrong_color`, `not_in_legals`, `next_sfen_mismatch`), or `ok`.

## CSV columns

```
game,record,ply,stm,chess960,fen,move16_hex,uci,score_cp,result,decode_ok,legal_ok,next_ok,notes
```

- `stm`: `w` or `b`
- `chess960`: `true` / `false`
- `move16_hex`: original 16-bit code, hex
- `uci`: move as written above (castling is king-from → rook-from for Chess960)
- `score_cp`: signed centipawns from bin record
- `result`: `1-0`, `0-1`, or `1/2-1/2` from game_result byte
- `decode_ok`, `legal_ok`: `yes` / `no`
- `next_ok`: `yes` / `no` / `n/a`
- `notes`: `ok` or semicolon-separated issues

## Summaries

After processing, the validator prints:

```
csv written: <path> (games: X, records: Y, ok: Z, decode_fails: A, legal_fails: B, next_mismatch: C)
```

## Implementation notes

- Castling detection uses `infer_castling_from_board` to populate `pos.is_chess960`, king/rook start squares, and castling-clear tables.
- `move_to_csv_uci` writes all UCIs into a provided buffer to avoid lifetime issues.
- BINHCE size is computed from `tuner.Tuner` feature sizes; otherwise BIN40 layout is assumed.

## Troubleshooting

- If `decode_ok` is `no`: the `move16` could not be parsed (bad encoding).
- If `legal_ok` is `no`: the decoded move was not found in generated legals (stale side-to-move or corrupt record).
- If `next_ok` is `no`: SFEN after playing the move doesn’t match next record (record ordering or move mis-encoding).
- Chess960 castling in downstream tools: interpret `uci` as king-from → rook-from; convert to king-target (g/c) if needed.

## Datagen Example Output

Command:

```bash
lamb datagen games 500 depth 4 random_min_ply 4 random_50_ply 12 random_10_ply 24 random_move_count 6 save_min_ply 1 save_max_ply 400 filename test10 full_game std 0.4 frc 0.33 dfrc 0.27
```

Progress (truncated):

```text
info string datagen progress games=8 positions=1000 time 6.461s avg_per_1k 6.461s avg_per_game 0.808s eta_game 397.4s
info string datagen progress games=18 positions=2000 time 12.701s avg_per_1k 6.351s avg_per_game 0.706s eta_game 340.1s
...
info string datagen progress games=493 positions=54000 time 339.209s avg_per_1k 6.282s avg_per_game 0.688s eta_game 4.8s
info string datagen summary games=500 positions=54777 time 343.745s avg_per_1k 6.275s
info string datagen time_split play=99.79% (343.013s) save=0.14% (0.480s) other=0.07% (0.251s)
```

Validation:

```bash
D:\Ostalo\LambergarTesting\gitea\Lambergar-1>zig run src/datagen_validate.zig -- test10.bin --csv out.csv
```

Output:

```text
csv written: out.csv
  games: 500
  records: 54777
  ok: 54777
  decode_fails: 0
  legal_fails: 0
  next_mismatch: 0
  rt_sfen_mismatch: 0
  repeats: 0
  result_issues: 0
problematic games:
  (none)
```

CSV → PGN:

```bash
D:\Ostalo\LambergarTesting\gitea\Lambergar-1>python3.12 tests/csv_to_pgn.py out.csv out.pgn
```

Output:

```text
wrote PGN with 500 game(s) to out.pgn (skipped 0 games: [])
```

Final PGN validation:

```bash
D:\Ostalo\LambergarTesting\gitea\Lambergar-1>python3.12 tests/validate_pgn.py out.pgn
```

Output:

```text
All games legal.
```


