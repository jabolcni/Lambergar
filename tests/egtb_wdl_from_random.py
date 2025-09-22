import subprocess
import chess
import os
import sys
import time
import re
from contextlib import contextmanager

# Paths based on your provided directory
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
EXE_PATH = os.path.normpath(os.path.join(SCRIPT_DIR, "../zig-out/bin/lambergar.exe"))
EPD_FILE = os.path.join(SCRIPT_DIR, "endgame_positions.epd")  # Your generated EPD file
SYZYGY_PATH = r"C:/Users/janezp/Downloads/syzygy"  # Forward slashes
LOG_FILE = os.path.join(SCRIPT_DIR, "test_endgame_probing.log")

# Custom class to write output to both console and log file
class Tee:
    def __init__(self, *files):
        self.files = files

    def write(self, obj):
        for f in self.files:
            f.write(obj)
            f.flush()

    def flush(self):
        for f in self.files:
            f.flush()

def count_pieces(fen):
    """
    Count the number of pieces in a FEN position (excluding empty squares and slashes).
    """
    board_part = fen.split(' ')[0]
    piece_count = sum(1 for char in board_part if char in 'pnbrqkPNBRQK')
    return piece_count

def parse_enhanced_epd_line(line, line_num):
    """
    Parse a single line from the enhanced EPD file with tablebase metadata.
    Returns (fen, tb_wdl, tb_dtz, tb_result) or None if invalid.
    """
    raw_line = line
    line = line.replace('\r\n', '\n').replace('\r', '\n').strip()
    if not line or line.startswith('#'):
        return None
    
    # Split by semicolons
    parts = [part.strip() for part in line.split(';') if part.strip()]
    if len(parts) < 2:
        return None
    
    # The first part should be the FEN
    fen = parts[0]
    
    # Find the tablebase metadata
    tb_wdl = None
    tb_dtz = None
    tb_result = None
    
    for part in parts[1:]:
        if part.startswith('TB_WDL '):
            tb_wdl = part[7:].strip()
        elif part.startswith('TB_DTZ '):
            tb_dtz = part[7:].strip()
        elif part.startswith('TB_RESULT '):
            tb_result = part[10:].strip().strip('"')
    
    # Validate FEN
    try:
        chess.Board(fen)
    except ValueError as e:
        print(f"Line {line_num}: Skipped (invalid FEN: {e}): '{raw_line}'")
        return None
    
    return fen, tb_wdl, tb_dtz, tb_result

def get_tablebase_info(proc, fen):
    """
    Send UCI commands to probe the tablebase info for the given FEN.
    Returns (wdl, None) or (None, None) if failed.
    Note: This version only returns WDL, no DTZ.
    """
    if proc.poll() is not None:
        print(f"Engine process terminated (return code: {proc.poll()})")
        return None, None
    
    proc.stdin.write("ucinewgame\n")
    proc.stdin.flush()
    
    position_cmd = f"position fen {fen}\n"
    proc.stdin.write(position_cmd)
    proc.stdin.flush()
    
    proc.stdin.write("probe\n")  # Changed from "probebest" to "probe"
    proc.stdin.flush()
    
    wdl = None
    timeout_count = 0
    start_time = time.time()
    
    # Keep reading until we get WDL or timeout
    while proc.poll() is None and timeout_count < 100 and (time.time() - start_time) < 5:
        line = proc.stdout.readline()
        if not line:
            timeout_count += 1
            continue
            
        line = line.strip()
        print(f"Engine output: {line}")
        
        # Parse WDL Probe Result line
        if "WDL Probe Result:" in line:
            # First check for code - this is the most reliable source
            code_match = re.search(r'Code:\s*(\d+)', line)
            if code_match:
                code = int(code_match.group(1))
                # Map Fathom codes to WDL strings (highest priority)
                code_map = {
                    0: "Loss",
                    1: "Draw: Loss (blessed)", 
                    2: "Draw",
                    3: "Draw: Win (cursed)",
                    4: "Win"
                }
                wdl = code_map.get(code)
            elif wdl is None:
                # Fallback to text parsing only if no code and no WDL set
                wdl_match = re.search(r'WDL Probe Result:\s+([^(]+)', line)
                if wdl_match:
                    wdl = wdl_match.group(1).strip()
            
            # If we got WDL, we can exit early
            if wdl is not None:
                break
        
        # Check for end of output
        if line == "" or "bestmove" in line:
            timeout_count += 1
    
    return wdl, None  # Always return None for DTZ since probe command doesn't provide it

def convert_wdl_to_numeric(wdl_str):
    """
    Convert WDL string to numeric value for comparison.
    Maps Fathom WDL codes to chess.syzygy values:
    -2: Loss, -1: Blessed Loss, 0: Draw, 1: Cursed Win, 2: Win
    """
    if wdl_str is None:
        return None
    
    wdl_str = str(wdl_str).strip()
    
    # Handle exact matches first (highest priority)
    if wdl_str == "Loss":
        return -2
    elif wdl_str == "Draw: Loss (blessed)":
        return -1
    elif wdl_str == "Draw":
        return 0
    elif wdl_str == "Draw: Win (cursed)":
        return 1
    elif wdl_str == "Win":
        return 2
    
    # Handle partial matches for backward compatibility (lower priority)
    wdl_lower = wdl_str.lower()
    if "loss" in wdl_lower and "blessed" in wdl_lower:
        return -1
    elif "win" in wdl_lower and "cursed" in wdl_lower:
        return 1
    elif "loss" in wdl_lower:
        return -2
    elif "win" in wdl_lower:
        return 2
    elif "draw" in wdl_lower:
        return 0
    
    return None

@contextmanager
def tee_output():
    """
    Redirect print output to both console and log file.
    """
    log_file = open(LOG_FILE, 'w', encoding='utf-8')
    original_stdout = sys.stdout
    sys.stdout = Tee(sys.__stdout__, log_file)
    try:
        yield
    finally:
        sys.stdout = original_stdout
        log_file.close()

def main():
    with tee_output():
        if not os.path.exists(EXE_PATH):
            print(f"Error: Engine executable not found at {EXE_PATH}")
            sys.exit(1)
        
        if not os.path.exists(EPD_FILE):
            print(f"Error: EPD file not found at {EPD_FILE}")
            sys.exit(1)
        
        # Check Syzygy path
        if not os.path.exists(SYZYGY_PATH):
            print(f"Error: Syzygy path {SYZYGY_PATH} does not exist")
            sys.exit(1)
        
        # Parse EPD positions
        positions = []
        with open(EPD_FILE, 'r', encoding='utf-8') as f:
            for line_num, line in enumerate(f, 1):
                pos = parse_enhanced_epd_line(line, line_num)
                if pos:
                    fen, tb_wdl, tb_dtz, tb_result = pos
                    positions.append((fen, tb_wdl, tb_dtz, tb_result))
        
        if not positions:
            print(f"No valid positions loaded from {EPD_FILE}. Check file format.")
            sys.exit(1)
        
        print(f"Loaded {len(positions)} positions from {EPD_FILE}")
        
        # Start the engine process
        try:
            proc = subprocess.Popen(
                [EXE_PATH],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                universal_newlines=True,
                bufsize=1  # Line buffering
            )
        except Exception as e:
            print(f"Error: Failed to start engine at {EXE_PATH}: {e}")
            sys.exit(1)
        
        # Initialize UCI protocol
        print("Sending UCI command...")
        proc.stdin.write("uci\n")
        proc.stdin.flush()
        
        # Drain startup output
        print("Draining engine startup output...")
        start_time = time.time()
        while proc.poll() is None and (time.time() - start_time) < 5:
            line = proc.stdout.readline()
            if not line:
                break
            print(f"Engine startup: {line.strip()}")
            if "uciok" in line:
                break
        
        if proc.poll() is not None:
            print(f"Error: Engine exited during startup (return code: {proc.poll()})")
            sys.exit(1)
        
        # Set Syzygy path
        print(f"Setting Syzygy path: {SYZYGY_PATH}")
        proc.stdin.write(f"setoption name SyzygyPath value {SYZYGY_PATH}\n")
        proc.stdin.flush()
        
        # Wait for Fathom initialization
        print("Waiting for Fathom initialization...")
        initialized = False
        start_time = time.time()
        while proc.poll() is None and (time.time() - start_time) < 5:
            line = proc.stdout.readline()
            if not line:
                break
            line = line.strip()
            print(f"Engine init: {line}")
            if "fathom initialized" in line.lower():
                initialized = True
                break
        
        if not initialized:
            print(f"Error: Fathom failed to initialize with path {SYZYGY_PATH}")
            proc.stdin.close()
            proc.wait()
            sys.exit(1)
        
        print("Engine initialized. Starting tests...")
        
        passed = 0
        failed = 0
        skipped = 0
        failed_positions = []
        
        for i, (fen, tb_wdl, tb_dtz, tb_result) in enumerate(positions, 1):
            print(f"\n--- Test {i}: {fen} ---")
            print(f"Tablebase WDL: {tb_wdl}, DTZ: {tb_dtz}, Result: {tb_result}")
            
            # Get tablebase info from engine
            engine_wdl, engine_dtz = get_tablebase_info(proc, fen)
            
            if engine_wdl is None:
                print(f"FAIL: No tablebase WDL info returned for FEN '{fen}'")
                failed += 1
                failed_positions.append((fen, tb_wdl, tb_dtz, engine_wdl, engine_dtz))
                continue
            
            # Convert WDL to numeric for comparison
            expected_wdl_numeric = int(tb_wdl) if tb_wdl is not None else None
            engine_wdl_numeric = convert_wdl_to_numeric(engine_wdl)
            
            # Compare WDL values (DTZ comparison is skipped since probe doesn't return DTZ)
            wdl_match = (expected_wdl_numeric is not None and 
                        engine_wdl_numeric is not None and
                        expected_wdl_numeric == engine_wdl_numeric)
            
            if wdl_match:
                print(f"PASS: WDL={engine_wdl} ({engine_wdl_numeric})")
                passed += 1
            else:
                print(f"FAIL: Expected WDL={tb_wdl} ({expected_wdl_numeric}), got WDL={engine_wdl} ({engine_wdl_numeric})")
                failed += 1
                failed_positions.append((fen, tb_wdl, tb_dtz, engine_wdl, engine_dtz))
        
        proc.stdin.close()
        proc.wait()
        
        print(f"\n--- Summary ---")
        print(f"Passed: {passed}/{len(positions)}")
        print(f"Failed: {failed}")
        print(f"Skipped: {skipped}")
        
        if failed > 0:
            print("\nFailed Positions:")
            for fen, tb_wdl, tb_dtz, engine_wdl, engine_dtz in failed_positions:
                print(f"FEN: {fen}")
                print(f"Expected: WDL={tb_wdl}")
                print(f"Actual: WDL={engine_wdl}")
                print()
        
        if failed == 0:
            print("All tablebase probing tests passed!")
        else:
            print("Some tests failed. Check engine's Syzygy integration or tablebase files.")

if __name__ == "__main__":
    main()