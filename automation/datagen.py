import subprocess
import os
import glob
import time
import re
from pathlib import Path
from .config import ENGINE_BIN, DATA_DIR, CONCURRENCY, ROOT_DIR

def generate_data(filename_prefix, games, depth, dither=1, min_nodes=500):
    """
    Generates training data using parallel processes.
    """
    total_games = games * CONCURRENCY
    print(f"="*80)
    print(f"DATA GENERATION")
    print(f"="*80)
    print(f"Configuration:")
    print(f"  Games per thread: {games}")
    print(f"  Parallel threads: {CONCURRENCY}")
    print(f"  Total games: {total_games}")
    print(f"  Search depth: {depth}")
    print(f"  Dither: {dither}")
    print(f"  Min nodes: {min_nodes}")
    print(f"  Output prefix: {filename_prefix}")
    print(f"="*80)
    
    processes = []
    for i in range(CONCURRENCY):
        outfile = DATA_DIR / f"{filename_prefix}_{i}.binhce"
        
        # Use relative path for engine argument to avoid potential absolute path issues
        try:
            outfile_rel = outfile.relative_to(ROOT_DIR)
        except ValueError:
            # Fallback to absolute if not relative (e.g. different drive on Windows)
            outfile_rel = outfile

        cmd = [
            str(ENGINE_BIN), "datagen", "games", str(games),
            "depth", str(depth),
            "dither", str(dither),
            "min_nodes", str(min_nodes),
            "skipnoisy",
            "random_min_ply", "4",
            "random_50_ply", "12",
            "random_10_ply", "24",
            "random_move_count", "6",
            "save_min_ply", "6",
            "save_max_ply", "200",
            "adjudicate_draws_by_score",
            "adjudicate_draws_by_insufficient_mating_material",
            "eval", "hce",
            "format", "binhce",
            "filename", str(outfile_rel)
        ]
        
        # Start process
        # Capture output for debugging
        with open(f"{outfile}.log", "w") as log_file:
            p = subprocess.Popen(cmd, stdout=log_file, stderr=subprocess.STDOUT)
        processes.append(((p, f"{outfile}.log"), outfile))
        
    # Wait for all
    print(f"\nStarted {len(processes)} parallel data generation processes")
    print(f"Waiting for completion...")
    print()
    
    start_time = time.time()
    failed = False
    completed = 0
    remaining = list(enumerate(processes, 1))
    last_log_state = {}  # pid -> (mtime, line)
    rr_index = 0

    # Poll processes to show progress while they run
    while remaining:
        # Check if any finished in this poll
        newly_remaining = []
        for idx, ((p, log_path), outfile) in remaining:
            exit_code = p.poll()
            if exit_code is None:
                newly_remaining.append((idx, ((p, log_path), outfile)))
                continue

            progress_pct = ((completed) / len(processes)) * 100
            elapsed = time.time() - start_time
            elapsed_str = f"{int(elapsed // 60)}m {int(elapsed % 60)}s" if elapsed >= 60 else f"{int(elapsed)}s"
            print(f"[{idx}/{len(processes)} - {progress_pct:.0f}%] Process {idx} (elapsed: {elapsed_str})...", end="", flush=True)

            if exit_code != 0:
                print(f" FAILED (exit code {exit_code})")
                failed = True
                print(f"  ❌ Process failed! Check log: {log_path}")
                try:
                    with open(log_path, 'r') as f:
                        lines = f.readlines()
                        print(f"  Last 20 lines of error log:")
                        for line in lines[-20:]:
                            print(f"    {line.rstrip()}")
                except:
                    pass
            elif not os.path.exists(outfile):
                print(f" FAILED (missing output)")
                failed = True
                print(f"  ❌ Process finished but output file missing: {outfile}")
                print(f"  Check log: {log_path}")
                try:
                    with open(log_path, 'r') as f:
                        print(f"  Full log content:")
                        for line in f:
                            print(f"    {line.rstrip()}")
                except:
                    pass
            elif os.path.getsize(outfile) == 0:
                print(f" FAILED (empty output)")
                failed = True
                print(f"  ❌ Process finished but output file is empty: {outfile}")
                print(f"  Check log: {log_path}")
                try:
                    with open(log_path, 'r') as f:
                        print(f"  Full log content:")
                        for line in f:
                            print(f"    {line.rstrip()}")
                except:
                    pass
            else:
                file_size_mb = os.path.getsize(outfile) / (1024 * 1024)
                print(f" ✓ Complete ({file_size_mb:.2f} MB)")
                completed += 1

        remaining = newly_remaining
        if remaining:
            # Print a heartbeat every minute, showing aggregate progress from all running logs
            elapsed = time.time() - start_time
            elapsed_str = f"{int(elapsed // 60)}m {int(elapsed % 60)}s" if elapsed >= 60 else f"{int(elapsed)}s"

            total_games_seen = 0
            total_positions_seen = 0
            max_eta = None
            sample_line = None

            for idx, ((_, log_path), _) in remaining:
                try:
                    with open(log_path, "r") as lf:
                        lf.seek(0, os.SEEK_END)
                        size = lf.tell()
                        lf.seek(max(size - 4096, 0), os.SEEK_SET)
                        tail = lf.read().splitlines()
                    filtered = [ln.strip() for ln in tail if ln.strip()]
                    line = None
                    for ln in reversed(filtered):
                        if "datagen progress" in ln:
                            line = ln.strip()
                            break
                    if line is None and filtered:
                        line = filtered[-1]
                except Exception:
                    line = None

                if not line:
                    continue

                # Keep a sample from the latest processed log
                if sample_line is None:
                    sample_line = f"log[{os.path.basename(log_path)}]: {line}"

                # Parse games/positions/eta if present
                m_games = re.search(r"games=(\d+)", line)
                m_pos = re.search(r"positions=(\d+)", line)
                m_eta = re.search(r"eta_game\s+([\d\.]+)s", line)
                if m_games:
                    total_games_seen += int(m_games.group(1))
                if m_pos:
                    total_positions_seen += int(m_pos.group(1))
                if m_eta:
                    eta_val = float(m_eta.group(1))
                    max_eta = eta_val if max_eta is None else max(max_eta, eta_val)

            agg_snippet = f" | agg games={total_games_seen} pos={total_positions_seen}"
            if max_eta is not None:
                agg_snippet += f" max_eta={max_eta:.1f}s"
            sample_snippet = f" | sample: {sample_line[:200]}" if sample_line else " | sample: (no progress yet)"

            print(f"[heartbeat] {completed}/{len(processes)} done, {len(remaining)} running (elapsed: {elapsed_str}){agg_snippet}{sample_snippet}")
            time.sleep(60)
    
    print()
    total_elapsed = time.time() - start_time
    total_elapsed_str = f"{int(total_elapsed // 60)}m {int(total_elapsed % 60)}s" if total_elapsed >= 60 else f"{int(total_elapsed)}s"
    
    if failed:
        print(f"❌ Data generation FAILED for one or more processes")
        raise RuntimeError("Data generation failed for one or more processes.")
    
    print(f"✓ Data generation complete! Successfully generated {completed}/{len(processes)} files")
    print(f"  Total time: {total_elapsed_str}")
    print(f"="*80)
    print()

def merge_datasets(filename_prefix, output_filename):
    """
    Merges all chunks into a single dataset.
    """
    output_path = DATA_DIR / output_filename
    
    print(f"="*80)
    print(f"MERGING DATASETS")
    print(f"="*80)
    print(f"Output file: {output_path}")
    
    # Get all chunk files
    pattern = str(DATA_DIR / f"{filename_prefix}_*.binhce")
    files = sorted(glob.glob(pattern))
    
    if not files:
        print(f"❌ No files found to merge! Pattern: {pattern}")
        print(f"="*80)
        return
    
    print(f"Found {len(files)} chunk files to merge")
    print()
        
    # Simple concatenation for binary files
    total_size = 0
    with open(output_path, 'wb') as outfile:
        for idx, fname in enumerate(files, 1):
            file_size = os.path.getsize(fname)
            file_size_mb = file_size / (1024 * 1024)
            total_size += file_size
            print(f"  [{idx}/{len(files)}] Merging {Path(fname).name} ({file_size_mb:.2f} MB)")
            with open(fname, 'rb') as infile:
                outfile.write(infile.read())
    
    total_size_mb = total_size / (1024 * 1024)
    print()
    print(f"✓ Merged {len(files)} files into {output_filename} ({total_size_mb:.2f} MB total)")
    
    # Cleanup chunks
    print(f"Cleaning up {len(files)} chunk files...")
    for fname in files:
        os.remove(fname)
    
    print(f"✓ Merge complete!")
    print(f"="*80)
    print()