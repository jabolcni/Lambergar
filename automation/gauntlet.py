import subprocess
import re
import shutil
from pathlib import Path
from .config import ENGINE_BIN, OLD_ENGINE_BIN, OPENINGS_FILE, TC, CONCURRENCY, MATCH_ROUNDS, FASTCHESS_BIN

def run_gauntlet(new_engine_path, old_engine_path, rounds=MATCH_ROUNDS):
    """
    Runs a gauntlet match between new and old engine using fastchess.
    """
    print(f"Starting gauntlet: New vs Old ({rounds * 2} games)...")
    
    cmd = [
        str(FASTCHESS_BIN),
        "-engine", f"cmd={new_engine_path}", "name=lambergar_new", 
        "option.Hash=128", "option.Threads=1", "option.UseNNUE=false",
        "-engine", f"cmd={old_engine_path}", "name=lambergar_old",
        "option.Hash=128", "option.Threads=1", "option.UseNNUE=false",
        "-openings", f"file={OPENINGS_FILE}", "format=pgn", "order=random", "plies=6",
        "-each", f"tc={TC}",
        "-tournament", "gauntlet",
        "-concurrency", str(CONCURRENCY),
        "-rounds", str(rounds),
        "-repeat",
        "-maxmoves", "400",
        "-recover",
        "-ratinginterval", "10"
    ]
    
    # Run fastchess and capture output
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        output = result.stdout
    except subprocess.CalledProcessError as e:
        print("Error running fastchess:")
        print("STDERR:", e.stderr)
        print("STDOUT:", e.stdout)
        print("Return code:", e.returncode)
        return None
    except FileNotFoundError as e:
        print(f"Error: fastchess binary not found at {FASTCHESS_BIN}")
        print(f"Please ensure fastchess is installed and the path is correct")
        return None

    return parse_fastchess_output(output)

def parse_fastchess_output(output):
    """
    Parses fastchess output to extract Elo, LOS, and DrawRatio.
    """
    stats = {
        'elo': 0.0,
        'elo_error': 0.0,
        'los': 0.0,
        'draw_ratio': 0.0,
        'wins': 0,
        'losses': 0,
        'draws': 0
    }
    
    # Regex patterns
    # Elo: 0.69 +/- 9.47
    elo_pattern = re.compile(r"Elo:\s+([-\d.]+)\s+\+/-\s+([\d.]+)")
    # LOS: 55.72 %
    los_pattern = re.compile(r"LOS:\s+([\d.]+)\s*%")
    # DrawRatio: 46.30 %
    draw_pattern = re.compile(r"DrawRatio:\s+([\d.]+)\s*%")
    # Games: 2000, Wins: 479, Losses: 475, Draws: 1046
    games_pattern = re.compile(r"Wins:\s+(\d+),\s+Losses:\s+(\d+),\s+Draws:\s+(\d+)")
    
    for line in output.splitlines():
        elo_match = elo_pattern.search(line)
        if elo_match:
            stats['elo'] = float(elo_match.group(1))
            stats['elo_error'] = float(elo_match.group(2))
            
        los_match = los_pattern.search(line)
        if los_match:
            stats['los'] = float(los_match.group(1))
            
        draw_match = draw_pattern.search(line)
        if draw_match:
            stats['draw_ratio'] = float(draw_match.group(1))
            
        games_match = games_pattern.search(line)
        if games_match:
            stats['wins'] = int(games_match.group(1))
            stats['losses'] = int(games_match.group(2))
            stats['draws'] = int(games_match.group(3))
            
    return stats
