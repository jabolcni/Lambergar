#!/usr/bin/env python3
import os
import subprocess
import argparse
import json
import random
import time
import uuid
import math
import sys
from pathlib import Path
from datetime import datetime

# ==========================================
# CONSTANTS & SETUP
# ==========================================
SCRIPT_DIR = Path(__file__).parent
CONFIG_FILE = SCRIPT_DIR / "datagen_params.json"

def load_config():
    if not CONFIG_FILE.exists():
        raise FileNotFoundError(f"Config file not found: {CONFIG_FILE}")
    with open(CONFIG_FILE, "r") as f:
        return json.load(f)

def generate_random_value(param_config):
    p_type = param_config.get("type")
    if p_type == "int":
        return random.randint(param_config["min"], param_config["max"])
    elif p_type == "float":
        return round(random.uniform(param_config["min"], param_config["max"]), 4)
    else:
        return param_config["default"]

def generate_constrained_distribution(params_list):
    """
    Generates values for a list of parameters such that:
    1. The sum of all values is exactly 1.0
    2. Each value respects its specific 'min' and 'max'
    """
    indices = list(range(len(params_list)))
    random.shuffle(indices)
    
    result = {}
    current_sum = 0.0
    
    # Pre-calculate global bounds
    total_min_required = sum(p["min"] for p in params_list)
    total_max_allowed = sum(p["max"] for p in params_list)
    
    if total_min_required > 1.0 or total_max_allowed < 1.0:
        print(f"WARNING: Impossible distribution constraints. Using defaults.")
        return {p["name"]: p["default"] for p in params_list}

    for step, i in enumerate(indices):
        is_last = (step == len(indices) - 1)
        param = params_list[i]
        name = param["name"]
        
        if is_last:
            val = 1.0 - current_sum
            val = max(param["min"], min(val, param["max"]))
            result[name] = round(val, 4)
        else:
            remaining_indices = indices[step+1:]
            min_needed_by_others = sum(params_list[k]["min"] for k in remaining_indices)
            max_allowed_by_others = sum(params_list[k]["max"] for k in remaining_indices)
            
            remaining_space = 1.0 - current_sum
            
            hard_max = remaining_space - min_needed_by_others
            effective_max = min(param["max"], hard_max)
            
            hard_min = remaining_space - max_allowed_by_others
            effective_min = max(param["min"], hard_min)
            
            if effective_max < effective_min:
                effective_max = effective_min

            val = random.uniform(effective_min, effective_max)
            val = round(val, 4)
            
            result[name] = val
            current_sum += val

    return result

def build_engine_cmd(engine_path, chunk_file, games_per_thread, current_params, settings):
    cmd = [
        str(engine_path), "datagen",
        "games", str(games_per_thread),
        "filename", str(chunk_file),
        "eval", settings["eval_mode"],
        "format", settings["format"]
    ]

    for key, value in current_params.items():
        if value is True:
            cmd.append(key)
        elif value is False:
            continue
        else:
            cmd.append(key)
            cmd.append(str(value))

    return cmd

def run_batch(batch_index, config):
    settings = config["settings"]
    output_dir = Path(settings["output_dir"])
    output_dir.mkdir(exist_ok=True, parents=True)
    
    engine_bin = Path(settings["engine_binary"]).resolve()
    if not engine_bin.exists():
        raise FileNotFoundError(f"Engine binary not found at: {engine_bin}")
    if not os.access(engine_bin, os.X_OK):
        print(f"ERROR: Engine binary at {engine_bin} is not executable.")
        return False

    # 1. Randomize Parameters
    current_params = {}
    for k, v in config.get("fixed_parameters", {}).items():
        current_params[k] = v
    for k, v in config.get("random_parameters", {}).items():
        current_params[k] = generate_random_value(v)
    for group in config.get("distribution_groups", []):
        dist_values = generate_constrained_distribution(group["params"])
        current_params.update(dist_values)

    # 2. Prepare Output
    batch_uuid = str(uuid.uuid4())[:8]
    timestamp = datetime.now().strftime("%Y_%m_%d_%H_%M_%S")
    base_name = f"data_{batch_uuid}_{timestamp}"
    final_bin = output_dir / f"{base_name}.bin"
    final_json = output_dir / f"{base_name}.json"

    # 3. Launch
    num_threads = settings["threads"]
    total_games = settings["total_games_per_batch"]
    games_per_thread = math.ceil(total_games / num_threads)

    print(f"\n[Batch {batch_index}] {base_name}")
    print(f"  Types: Std={current_params.get('std'):.2f}, Frc={current_params.get('frc'):.2f}, Dfrc={current_params.get('dfrc'):.2f}")
    print(f"  Params: Depth={current_params.get('depth')}, Nodes={current_params.get('min_nodes')}, SaveMinPly={current_params.get('save_min_ply')}")

    processes = []
    chunk_data = [] 

    for t in range(num_threads):
        chunk_path = output_dir / f"temp_{batch_uuid}_{t}.chunk"
        log_path = output_dir / f"temp_{batch_uuid}_{t}.log"
        
        cmd = build_engine_cmd(engine_bin, chunk_path, games_per_thread, current_params, settings)
        
        with open(log_path, "w") as log_file:
            p = subprocess.Popen(cmd, stdout=log_file, stderr=subprocess.STDOUT)
            chunk_data.append((chunk_path, log_path, p))
            processes.append(p)

    try:
        for p in processes:
            p.wait()
    except KeyboardInterrupt:
        for p in processes:
            p.terminate()
        return False

    # 4. Merge and Check for Errors
    total_bytes = 0
    missing_chunks = 0
    
    with open(final_bin, "wb") as outfile:
        for chunk_path, log_path, p in chunk_data:
            # FIX: Check for both 'filename' and 'filename.bin'
            actual_file = chunk_path
            if not actual_file.exists():
                candidate = chunk_path.with_name(chunk_path.name + ".bin")
                if candidate.exists():
                    actual_file = candidate

            if actual_file.exists() and actual_file.stat().st_size > 0:
                with open(actual_file, "rb") as infile:
                    data = infile.read()
                    outfile.write(data)
                    total_bytes += len(data)
                actual_file.unlink() # Delete the actual file found
                if log_path.exists(): log_path.unlink()
            else:
                missing_chunks += 1
                print(f"  ERROR: Chunk missing: {chunk_path.name} (or .bin)")
                print(f"  --- LOG OUTPUT ({log_path.name}) ---")
                if log_path.exists():
                    with open(log_path, "r") as lf:
                        print(lf.read().strip())
                    log_path.unlink() 
                print("  -----------------------------------")

    if missing_chunks == num_threads:
        print("\nCRITICAL: All threads failed. Stopping to prevent error spam.")
        if final_bin.exists(): final_bin.unlink()
        return False

    # 5. Save Metadata
    meta = {
        "timestamp": timestamp,
        "batch_uuid": batch_uuid,
        "games_requested": total_games,
        "games_actual": num_threads * games_per_thread - (missing_chunks * games_per_thread),
        "parameters": current_params
    }
    with open(final_json, "w") as f:
        json.dump(meta, f, indent=4)

    size_mb = total_bytes / (1024 * 1024)
    print(f"  ✓ Saved {final_bin.name} ({size_mb:.2f} MB)")
    return True

def main():
    print("="*60)
    print("DATAGEN STARTED")
    print("="*60)
    try:
        config = load_config()
    except Exception as e:
        print(f"Config Error: {e}")
        return

    batch = 1
    while True:
        try:
            if not run_batch(batch, config): break
            batch += 1
        except KeyboardInterrupt:
            print("\nDatagen stopped by user.")
            break
        except Exception as e:
            print(f"Error: {e}")
            time.sleep(5)

if __name__ == "__main__":
    main()