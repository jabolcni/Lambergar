#!/usr/bin/env python3
"""
HCE Tuning Pipeline (Simplified)
---------------------------------
Workflow:
  1. Generate binhce training data (parallel self-play with HCE eval + feature vectors)
  2. Train parameters with PyTorch (train_hce_torch.py)
  3. Copy tuned params to src/hce_params.zig
  4. Rebuild the engine (zig build)

Usage examples:
  # Full pipeline: generate + train + apply + build
  python tune_hce.py --games 8000 --depth 8 --threads 16 --epochs 250

  # Skip datagen (use existing dataset)
  python tune_hce.py --skip-datagen --dataset data/my_data.binhce --epochs 250

  # Only generate data
  python tune_hce.py --only-datagen --games 8000 --depth 8 --threads 16

  # Only train (don't rebuild)
  python tune_hce.py --skip-datagen --skip-build --dataset data/my_data.binhce
"""

import os
import sys
import subprocess
import argparse
import shutil
from pathlib import Path

# ── Paths ──────────────────────────────────────────────────────────────────────
ROOT_DIR   = Path(__file__).parent.absolute()
ENGINE_BIN = ROOT_DIR / "zig-out" / "bin" / "lambergar"
DATA_DIR   = ROOT_DIR / "data"
SRC_DIR    = ROOT_DIR / "src"
TUNER_DIR  = ROOT_DIR / "tuner"
TRAINER    = TUNER_DIR / "train_hce_torch.py"
PARAMS_OUT = ROOT_DIR / "tuned_hce_params.zig"
PARAMS_DST = SRC_DIR  / "hce_params.zig"


# ── Helpers ────────────────────────────────────────────────────────────────────
def run(cmd, **kwargs):
    print(f"  $ {' '.join(str(c) for c in cmd)}")
    result = subprocess.run(cmd, **kwargs)
    if result.returncode != 0:
        print(f"ERROR: command failed (exit {result.returncode})")
        sys.exit(1)
    return result


def section(title):
    print(f"\n{'='*60}")
    print(f"  {title}")
    print(f"{'='*60}")


# ── Step 1: Data Generation ────────────────────────────────────────────────────
def generate_data(args):
    section("STEP 1: DATA GENERATION")

    if not ENGINE_BIN.exists():
        print(f"Engine not found at {ENGINE_BIN}. Building first...")
        run(["zig", "build"], cwd=ROOT_DIR)

    DATA_DIR.mkdir(exist_ok=True)
    dataset = DATA_DIR / args.dataset

    games_per_thread = args.games
    threads = args.threads
    print(f"  Games per thread : {games_per_thread}")
    print(f"  Threads          : {threads}")
    print(f"  Total games      : {games_per_thread * threads}")
    print(f"  Depth            : {args.depth}")
    print(f"  Output           : {dataset}")

    # Launch parallel datagen processes
    processes = []
    chunk_paths = []
    for i in range(threads):
        chunk = DATA_DIR / f"_chunk_{args.dataset}_{i}.binhce"
        log   = DATA_DIR / f"_chunk_{args.dataset}_{i}.log"
        chunk_paths.append((chunk, log))

        cmd = [
            str(ENGINE_BIN), "datagen",
            "games",       str(games_per_thread),
            "depth",       str(args.depth),
            "dither",      "2",
            "min_nodes",   "1000",
            "skipnoisy",
            "random_min_ply",   "4",
            "random_50_ply",    "12",
            "random_10_ply",    "24",
            "random_move_count","6",
            "save_min_ply",     "6",
            "save_max_ply",     "200",
            "adjudicate_draws_by_score",
            "adjudicate_draws_by_insufficient_mating_material",
            "eval",   "hce",
            "format", "binhce",
            "filename", str(chunk),
        ]
        print(f"  Starting thread {i+1}/{threads}...")
        with open(log, "w") as lf:
            p = subprocess.Popen(cmd, stdout=lf, stderr=subprocess.STDOUT)
        processes.append(p)

    # Wait for all threads
    failed = 0
    for i, ((chunk, log), p) in enumerate(zip(chunk_paths, processes)):
        code = p.wait()
        if code != 0 or not chunk.exists():
            print(f"  Thread {i+1} FAILED — see {log}")
            failed += 1
        else:
            mb = chunk.stat().st_size / 1_048_576
            print(f"  Thread {i+1} done  ({mb:.1f} MB)")

    if failed == threads:
        print("All threads failed — aborting.")
        sys.exit(1)

    # Merge chunks
    print(f"\n  Merging {threads - failed} chunks → {dataset.name}")
    with open(dataset, "wb") as out:
        for chunk, log in chunk_paths:
            if chunk.exists():
                out.write(chunk.read_bytes())
                chunk.unlink()
            if log.exists():
                log.unlink()

    mb = dataset.stat().st_size / 1_048_576
    print(f"  Dataset ready: {dataset} ({mb:.1f} MB)")
    return dataset


# ── Step 2: Training ───────────────────────────────────────────────────────────
def train(args, dataset: Path):
    section("STEP 2: TRAINING")

    if not TRAINER.exists():
        print(f"Trainer not found: {TRAINER}")
        sys.exit(1)

    print(f"  Dataset : {dataset}")
    print(f"  Epochs  : {args.epochs}")
    print(f"  LR      : {args.lr}")
    print(f"  Alpha   : {args.alpha}")
    print(f"  K       : {args.k_factor}")
    print(f"  Output  : {PARAMS_OUT}")

    cmd = [
        sys.executable, str(TRAINER),
        "--binhce",    str(dataset),
        "--zig-out",   str(PARAMS_OUT),
        "--epochs",    str(args.epochs),
        "--lr",        str(args.lr),
        "--alpha",     str(args.alpha),
        "--k-factor",  str(args.k_factor),
        "--device",    args.device,
        "--batch-size",str(args.batch_size),
        "--ema",       str(args.ema),
    ]
    if args.no_phase_balancing:
        cmd.append("--no-phase-balancing")
    if args.no_scheduler:
        cmd.append("--no-scheduler")

    run(cmd)
    print(f"\n  Parameters saved to: {PARAMS_OUT}")


# ── Step 3: Apply Parameters ───────────────────────────────────────────────────
def apply_params():
    section("STEP 3: APPLY PARAMETERS")
    print(f"  {PARAMS_OUT} → {PARAMS_DST}")
    shutil.copy2(PARAMS_OUT, PARAMS_DST)
    print("  Done.")


# ── Step 4: Build ──────────────────────────────────────────────────────────────
def build():
    section("STEP 4: BUILD ENGINE")
    run(["zig", "build"], cwd=ROOT_DIR)
    bench = subprocess.run(
        [str(ENGINE_BIN), "bench"],
        capture_output=True, text=True
    )
    for line in bench.stdout.splitlines()[-3:]:
        print(f"  {line}")


# ── Main ───────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="HCE tuning pipeline")

    # Datagen
    dg = parser.add_argument_group("Data generation")
    dg.add_argument("--skip-datagen", action="store_true",
                    help="Skip data generation, use existing --dataset")
    dg.add_argument("--only-datagen", action="store_true",
                    help="Stop after data generation")
    dg.add_argument("--dataset",  default="hce_train.binhce",
                    help="Dataset filename (in data/) [default: hce_train.binhce]")
    dg.add_argument("--games",    type=int, default=8000,
                    help="Self-play games per thread [default: 8000]")
    dg.add_argument("--threads",  type=int, default=16,
                    help="Parallel datagen threads [default: 16]")
    dg.add_argument("--depth",    type=int, default=8,
                    help="Search depth for datagen [default: 8]")

    # Training
    tr = parser.add_argument_group("Training")
    tr.add_argument("--epochs",     type=int,   default=250)
    tr.add_argument("--lr",         type=float, default=0.1)
    tr.add_argument("--alpha",      type=float, default=0.3,
                    help="Blend: alpha×result + (1-alpha)×eval [default: 0.3]")
    tr.add_argument("--k-factor",   type=float, default=0.006)
    tr.add_argument("--batch-size", type=int,   default=65536)
    tr.add_argument("--ema",        type=float, default=0.99)
    tr.add_argument("--device",     default="cuda",
                    help="Training device: cuda or cpu [default: cuda]")
    tr.add_argument("--no-phase-balancing", action="store_true")
    tr.add_argument("--no-scheduler",       action="store_true")

    # Build
    bld = parser.add_argument_group("Build")
    bld.add_argument("--skip-build", action="store_true",
                     help="Don't rebuild engine after applying params")

    args = parser.parse_args()

    dataset_path = DATA_DIR / args.dataset

    # Step 1
    if not args.skip_datagen:
        dataset_path = generate_data(args)
    else:
        if not dataset_path.exists():
            print(f"Dataset not found: {dataset_path}")
            sys.exit(1)
        print(f"\nUsing existing dataset: {dataset_path}")

    if args.only_datagen:
        print("\nDone (--only-datagen).")
        return

    # Step 2
    train(args, dataset_path)

    # Step 3
    apply_params()

    # Step 4
    if not args.skip_build:
        build()

    section("COMPLETE")
    print(f"  Dataset  : {dataset_path}")
    print(f"  Params   : {PARAMS_DST}")
    print(f"  Engine   : {ENGINE_BIN}")


if __name__ == "__main__":
    main()
