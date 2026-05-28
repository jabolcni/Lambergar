import os
from pathlib import Path

# --- Paths ---
ROOT_DIR = Path(__file__).parent.parent.absolute()
BIN_DIR = ROOT_DIR
SRC_DIR = ROOT_DIR / "src"
TUNER_DIR = ROOT_DIR / "tuner"
DATA_DIR = ROOT_DIR / "data"
LOG_DIR = ROOT_DIR / "logs"
RESULTS_DIR = ROOT_DIR / "results"

# Ensure directories exist
for d in [DATA_DIR, LOG_DIR, RESULTS_DIR]:
    d.mkdir(exist_ok=True)

# --- Engine Configuration ---
ENGINE_NAME = "lamb"
ENGINE_BIN = BIN_DIR / ENGINE_NAME
OLD_ENGINE_NAME = "old_lamb"
OLD_ENGINE_BIN = BIN_DIR / OLD_ENGINE_NAME
FASTCHESS_BIN = ROOT_DIR / "fastchess"

# --- Tuning Configuration ---
# Stage 1: Material + PSQT
STAGE1_GAMES = 1000
STAGE1_DEPTH = 5
STAGE1_EPOCHS = 250
STAGE1_LR = 0.1
STAGE1_ALPHA = 1.0
STAGE1_K_FACTOR = 0.006
STAGE1_LOOPS = 3

# Stage 2: Full HCE
STAGE2_GAMES = 2000
STAGE2_DEPTH = 8
STAGE2_EPOCHS = 250
STAGE2_LR = 0.1
STAGE2_ALPHA = 0.3
STAGE2_K_FACTOR = 0.006
STAGE2_LOOPS = 5

# Stage 3: Hyperparameter Optimization
STAGE3_GAMES = 2000
STAGE3_DEPTH = 8
STAGE3_EPOCHS = 250

# --- System Resources ---
CONCURRENCY = 16  # Number of parallel datagen/match threads
DEVICE = "cuda"   # 'cuda' or 'cpu'

# --- Fastchess Configuration ---
OPENINGS_FILE = ROOT_DIR / "8moves_v3.pgn"
TC = "1.0+0.01"
MATCH_ROUNDS = 500  # Total games = 2 * rounds
