import subprocess
import chess
import chess.syzygy
import os
import sys
import time
from contextlib import contextmanager

# Paths based on your provided directory
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
EXE_PATH = os.path.normpath(os.path.join(SCRIPT_DIR, "../zig-out/bin/lambergar.exe"))
EPD_FILE = os.path.join(SCRIPT_DIR, "tb_sm.epd") # by Sergei S. Markoff, https://www.talkchess.com/forum/viewtopic.php?t=60244
SYZYGY_PATH = r"C:/Users/janezp/Downloads/syzygy"  # Forward slashes
LOG_FILE = os.path.join(SCRIPT_DIR, "test_wdl_probing.log")

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

def parse_epd_line(line, line_num):
    """
    Parse a single line from the EPD file.
    Returns (fen, bm_san) or None if invalid, with detailed error.
    """
    raw_line = line
    # Normalize line endings and strip whitespace
    line = line.replace('\r\n', '\n').replace('\r', '\n').strip()
    if not line or line.startswith('#'):
        # print(f"Line {line_num}: Skipped (empty or comment): '{raw_line}'")
        return None
    
    # Log bytes around the semicolon
    semicolon_idx = line.find(';')
    if semicolon_idx != -1:
        byte_str = raw_line[max(0, semicolon_idx-5):semicolon_idx+5]
        # print(f"Line {line_num}: Bytes around semicolon='{byte_str}', bytes={list(byte_str.encode('utf-8'))}")
    
    # Try splitting on semicolon
    parts = line.split(';', 1)
    if len(parts) < 2:
        # print(f"Line {line_num}: Skipped (no semicolon or incomplete): '{raw_line}'")
        print(f"Split parts: {parts}")
        return None
    
    fen = parts[0].strip()
    rest = parts[1].strip()
    # print(f"Line {line_num}: FEN='{fen}', Rest='{rest}'")  # Debug output
    
    # If Rest is empty, try splitting on 'bm '
    if not rest:
        parts = line.split(' bm ', 1)  # Add space to ensure correct split
        if len(parts) < 2:
            # print(f"Line {line_num}: Skipped (no 'bm' keyword after alternative split): '{raw_line}'")
            return None
        fen_part = parts[0].strip()
        rest = parts[1].split(';', 1)[0].strip()
        # print(f"Line {line_num}: Alternative split - Raw FEN='{fen_part}', Rest='{rest}'")
        fen = fen_part
        bm_san = rest
    else:
        # Find 'bm' keyword (case-insensitive)
        rest_lower = rest.lower()
        bm_start = rest_lower.find('bm ')
        if bm_start == -1:
            # print(f"Line {line_num}: Skipped (no 'bm' keyword): '{raw_line}'")
            return None
        bm_san = rest[bm_start + 3:].split(';', 1)[0].strip()
    
    if not bm_san:
        # print(f"Line {line_num}: Skipped (empty best move): '{raw_line}'")
        return None
    
    # Validate FEN
    try:
        chess.Board(fen)
    except ValueError as e:
        # print(f"Line {line_num}: Skipped (invalid FEN: {e}): '{raw_line}'")
        return None
    
    return fen, bm_san

def get_expected_wdl(fen, tablebase):
    """
    Probe the expected WDL using python-chess syzygy.
    Returns: 2 (win), 1 (cursed win), 0 (draw), -1 (blessed loss), -2 (loss), or None if invalid.
    """
    try:
        board = chess.Board(fen)
        wdl = tablebase.probe_wdl(board)
        return wdl
    except KeyError:
        print(f"Failed to probe WDL for FEN '{fen}': position not in tablebase")
        return None
    except ValueError as e:
        print(f"Invalid FEN '{fen}': {e}")
        return None

def get_engine_wdl(proc, fen):
    """
    Send UCI commands to probe the WDL for the given FEN.
    Returns the WDL value (2=win, 1=cursed win, 0=draw, -1=blessed loss, -2=loss),
    None if failed, or 'SKIP' if too many pieces.
    Parses engine output like 'info string WDL Probe Result: Win (Code: 4)'.
    Maps Lambergar WDL (4, 3, 2, 1, 0) to python-chess WDL (2, 1, 0, -1, -2).
    """
    if proc.poll() is not None:
        print(f"Engine process terminated (return code: {proc.poll()})")
        return None
    
    proc.stdin.write("ucinewgame\n")
    proc.stdin.flush()
    
    position_cmd = f"position fen {fen}\n"
    proc.stdin.write(position_cmd)
    proc.stdin.flush()
    
    proc.stdin.write("probebest\n")
    proc.stdin.flush()
    
    wdl = None
    timeout_count = 0
    start_time = time.time()
    while proc.poll() is None and timeout_count < 100 and (time.time() - start_time) < 5:
        line = proc.stdout.readline()
        if not line:
            break
        line = line.strip()
        print(f"Engine output: {line}")
        if "panic" in line.lower():
            print(f"Engine crashed: {line}")
            return None
        if "too many pieces" in line.lower():
            piece_count = count_pieces(fen)
            print(f"Skipping position (FEN='{fen}', {piece_count} pieces, exceeds tablebase limit)")
            return 'SKIP'
        if "info string WDL Probe Result" in line:
            parts = line.split()
            try:
                code_idx = parts.index("(Code:") + 1
                wdl_str = parts[code_idx].rstrip(")")
                wdl_value = int(wdl_str)
                # Map Lambergar WDL (4, 3, 2, 1, 0) to python-chess WDL (2, 1, 0, -1, -2)
                wdl_map = {4: 2, 3: 1, 2: 0, 1: -1, 0: -2}
                if wdl_value in wdl_map:
                    wdl = wdl_map[wdl_value]
                    break
                else:
                    print(f"Invalid WDL code {wdl_value} in: {line}")
            except (IndexError, ValueError):
                print(f"Failed to parse WDL from: {line}")
        timeout_count += 1
    
    return wdl

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
        
        # Initialize python-chess tablebase
        try:
            tablebase = chess.syzygy.open_tablebase(SYZYGY_PATH)
            print(f"Python-chess tablebase initialized with {SYZYGY_PATH}")
        except Exception as e:
            print(f"Error: Failed to initialize python-chess tablebase with {SYZYGY_PATH}: {e}")
            sys.exit(1)
        
        # Parse EPD positions
        positions = []
        with open(EPD_FILE, 'r', encoding='utf-8') as f:
            for line_num, line in enumerate(f, 1):
                pos = parse_epd_line(line, line_num)
                if pos:
                    positions.append(pos)
        
        if not positions:
            print(f"No valid positions loaded from {EPD_FILE}. Check file format.")
            tablebase.close()
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
            tablebase.close()
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
            tablebase.close()
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
            tablebase.close()
            sys.exit(1)
        
        print("Engine initialized. Starting WDL tests...")
        
        passed = 0
        failed = 0
        skipped = 0
        failed_positions = []
        for i, (fen, bm_san) in enumerate(positions, 1):
            print(f"\n--- Test {i}: {fen} (BM: {bm_san}) ---")
            
            # Get expected WDL from python-chess
            expected_wdl = get_expected_wdl(fen, tablebase)
            if expected_wdl is None:
                print(f"SKIP: Cannot probe expected WDL for FEN '{fen}'")
                skipped += 1
                continue
            
            # Get engine WDL
            actual_wdl = get_engine_wdl(proc, fen)
            if actual_wdl == 'SKIP':
                skipped += 1
                continue
            if actual_wdl is None:
                print(f"FAIL: No WDL returned for FEN '{fen}'")
                failed += 1
                failed_positions.append((fen, expected_wdl, None))
                continue
            
            # Compare WDL
            if actual_wdl == expected_wdl:
                wdl_str = {2: "Win", 1: "Cursed Win", 0: "Draw", -1: "Blessed Loss", -2: "Loss"}[actual_wdl]
                print(f"PASS: Expected WDL {wdl_str} ({expected_wdl}), got {wdl_str} ({actual_wdl})")
                passed += 1
            else:
                expected_str = {2: "Win", 1: "Cursed Win", 0: "Draw", -1: "Blessed Loss", -2: "Loss"}.get(expected_wdl, "Unknown")
                actual_str = {2: "Win", 1: "Cursed Win", 0: "Draw", -1: "Blessed Loss", -2: "Loss"}.get(actual_wdl, "Unknown")
                print(f"FAIL: Expected WDL {expected_str} ({expected_wdl}), got {actual_str} ({actual_wdl})")
                failed += 1
                failed_positions.append((fen, expected_wdl, actual_wdl))
        
        proc.stdin.close()
        proc.wait()
        tablebase.close()
        
        print(f"\n--- Summary ---")
        print(f"Passed: {passed}/{len(positions)}")
        print(f"Failed: {failed}")
        print(f"Skipped: {skipped} (positions with too many pieces or invalid)")
        if failed > 0:
            print("\nFailed Positions:")
            for fen, expected_wdl, actual_wdl in failed_positions:
                expected_str = {2: "Win", 1: "Cursed Win", 0: "Draw", -1: "Blessed Loss", -2: "Loss"}.get(expected_wdl, "Unknown")
                actual_str = {2: "Win", 1: "Cursed Win", 0: "Draw", -1: "Blessed Loss", -2: "Loss"}.get(actual_wdl, "Unknown")
                print(f"FEN: {fen}")
                print(f"Expected WDL: {expected_str} ({expected_wdl})")
                print(f"Actual WDL: {actual_str} ({actual_wdl})")
                print()
        if failed == 0 and passed + skipped == len(positions):
            print("All valid WDL probing tests passed!")
        else:
            print("Some tests failed. Check engine's Syzygy WDL probing or tablebase files.")

if __name__ == "__main__":
    main()