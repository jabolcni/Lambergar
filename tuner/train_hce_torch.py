#!/usr/bin/env python3
"""
PyTorch HCE Training - V4 Advanced
Features:
- Learnable Sigmoid Slope (K-Factor)
- Cosine Annealing Warm Restarts (Scheduler)
- L1 Regularization (Lasso) for noise suppression
- Centered Material & Slope Constraints
- Correct Pawn PSQT Export (Ignoring ranks 1/8)
- High-Performance GPU Optimizations
"""

import argparse
import sys
import os
import random
import time
import json
import datetime
from pathlib import Path
from typing import List, Tuple, Optional

import numpy as np
import chess

# Try to import torch
try:
    import torch
    import torch.nn as nn
    import torch.nn.functional as F
    import torch.optim as optim
    from torch.utils.data import Dataset, DataLoader
except ImportError:
    print("Error: PyTorch is not installed. pip install torch tensorboard")
    sys.exit(1)

# Enable TensorFloat32 for 30xx/40xx GPUs (Free speedup)
if torch.cuda.is_available():
    torch.set_float32_matmul_precision('high')

# Import local reader
try:
    import binhce_reader
except ImportError:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import binhce_reader

# Import fast Zig-based loader if available
try:
    import binhce_loader_fast as fast_loader
    USING_FAST_LOADER = True
    print("Using fast Zig-based loader")
except (ImportError, FileNotFoundError, RuntimeError):
    fast_loader = None
    USING_FAST_LOADER = False
    print("Warning: Fast loader not available, using slow Python loader")

# --- Constants ---

PHASE_VALUES = {
    chess.PAWN: 0,
    chess.KNIGHT: 3,
    chess.BISHOP: 3,
    chess.ROOK: 5,
    chess.QUEEN: 10,
    chess.KING: 0,
}

INIT_MAT = [100.0, 300.0, 325.0, 500.0, 950.0, 0.0]

MAX_PHASE_VAL = 64.0
SCORE_DIVISOR = 400.0
MAX_HALFMOVE = 90
MAX_PLY = 240

# Feature Shapes
SHAPES: List[Tuple[str, Tuple[int, ...]]] = [
    ("mat", (2, 6)),
    ("psqt", (2, 6, 64)),
    ("passed_pawn", (2, 64)),
    ("isolated_pawn", (2, 8)),
    ("blocked_passer", (2, 8)),
    ("supported_pawn", (2, 8)),
    ("pawn_phalanx", (2, 8)),
    ("knight_mobility", (2, 9)),
    ("bishop_mobility", (2, 14)),
    ("rook_mobility", (2, 15)),
    ("queen_mobility", (2, 28)),
    ("pawn_attacking", (2, 6)),
    ("knight_attacking", (2, 6)),
    ("bishop_attacking", (2, 6)),
    ("rook_attacking", (2, 6)),
    ("queen_attacking", (2, 6)),
    ("doubled_pawns", (2,)),
    ("bishop_pair", (2,)),
    ("rook_open", (2,)),
    ("rook_semi_open", (2,)),
    ("knight_outpost", (2,)),
    ("backward_pawn", (2,)),
    ("king_pawn_shield", (2, 4)),
    ("king_virtual_mobility", (2, 9)),
    ("trapped_bishop", (2,)),
    ("trapped_rook", (2,)),
    ("tempo", (2,)),
    ("rook_behind_passer", (2,)),
    ("pawn_storm", (2, 4)),
    ("candidate_pawn", (2, 64)),

    ("connected_rooks", (2,)),
    ("blockade_passer", (2,)),
    ("bishop_outpost", (2,)),
    ("king_safety", (2, 25)),
]

# Calculate Side Offset dynamically from SHAPES
# "Base" features are mat and psqt. Everything else is "Positional".
BASE_SIZE = 0
for name, shape in SHAPES:
    if name in ["mat", "psqt"]:
        BASE_SIZE += int(np.prod(shape)) // 2
    else:
        break
POS_SIZE = sum(int(np.prod(shape)) // 2 for name, shape in SHAPES) - BASE_SIZE
SIDE_SIZE = BASE_SIZE + POS_SIZE
TOTAL_DIM = SIDE_SIZE * 2
print(f"Feature Dimension: {BASE_SIZE} (Base) + {POS_SIZE} (Positional) = {SIDE_SIZE} per side")


# ============================================================================
# Constraint System
# ============================================================================

def load_constraints(config_path: str = None) -> dict:
    """
    Load constraints from:
    1. Explicit path (if provided)
    2. 'hce_constraints_centered.json' (preferred default)
    3. 'hce_constraints.json' (legacy default)
    
    Raises FileNotFoundError if no constraint file is found.
    """
    candidates = []
    if config_path:
        candidates.append(Path(config_path))
    
    script_dir = Path(__file__).parent
    candidates.append(script_dir / "hce_constraints_centered.json")
    candidates.append(script_dir / "hce_constraints.json")

    for path in candidates:
        if path.exists():
            try:
                with open(path, 'r') as f:
                    data = json.load(f)
                    constraints = data.get("constraints", data)
                    print(f"Loaded constraints from: {path.name}")
                    return constraints
            except Exception as e:
                print(f"Error reading {path.name}: {e}")

    # If we get here, no file was successfully loaded
    error_msg = f"CRITICAL: No HCE constraint file found! Tried: {[str(p.name) for p in candidates]}"
    print(error_msg)
    raise FileNotFoundError(error_msg)

def apply_constraints(params_dict: dict, constraints: dict, shapes: List[Tuple[str, Tuple]]):
    if not constraints:
        return

    
    with torch.no_grad():
        for feature_name, param_val in params_dict.items():
            if feature_name not in constraints:
                continue
            
            constraint = constraints[feature_name]
            ctype = constraint.get("type")
            tensors = param_val if isinstance(param_val, (list, tuple)) else [param_val]
            
            for param in tensors:
                if ctype == "sign":
                    rule = constraint.get("rule")
                    if rule in ["positive", "non-negative"]: param.clamp_(min=0)
                    elif rule in ["negative", "non-positive"]: param.clamp_(max=0)
                
                if "min_val" in constraint:
                    _apply_val_constraint(param, constraint["min_val"], is_min=True)
                
                if "max_val" in constraint:
                    _apply_val_constraint(param, constraint["max_val"], is_min=False)

                if ctype == "slope":
                    max_slope = constraint.get("max_slope", 100.0)
                    _enforce_slope(param, max_slope)
                
                # Check for 64-element symmetry (PSQT, etc.)
                if param.numel() == 64:
                    _enforce_symmetry(param)

def _enforce_symmetry(param):
    """
    Enforces Left-Right symmetry for 64-square parameters.
    Sq (Rank, File) <-> Sq^7 (Rank, 7-File)
    """
    w = param.view(8, 8) # [Rank, File]
    w_sym = (w + w.flip(1)) * 0.5
    param.data.copy_(w_sym.view(-1))

def _apply_val_constraint(param, limit_val, is_min=True):
    if isinstance(limit_val, (list, tuple)):
        limit_t = torch.tensor(limit_val, device=param.device, dtype=param.dtype)
        while limit_t.ndim < param.ndim: limit_t = limit_t.unsqueeze(0)
        if is_min: param.data = torch.max(param, limit_t)
        else: param.data = torch.min(param, limit_t)
    else:
        if is_min: param.clamp_(min=limit_val)
        else: param.clamp_(max=limit_val)

def _enforce_slope(tensor: torch.Tensor, max_slope: float, axis: int = -1):
    """Enforces monotonicity and slope limits. 
    If max_slope > 0, enforces t[i] <= t[i+1] <= t[i] + max_slope
    If max_slope < 0, enforces t[i] + max_slope <= t[i+1] <= t[i] (for safety/storm)
    """
    ndim = tensor.ndim
    axis = axis if axis >= 0 else ndim + axis
    perm = list(range(ndim))
    perm[axis], perm[-1] = perm[-1], perm[axis]
    t = tensor.permute(perm)
    
    with torch.no_grad():
        for i in range(t.shape[-1] - 1):
            if max_slope >= 0:
                # Monotonic increasing: t[i+1] must be at least t[i]
                lower_bound = t[..., i]
                upper_bound = t[..., i] + max_slope
                t[..., i+1].clamp_(min=lower_bound, max=upper_bound)
            else:
                # Monotonic decreasing: t[i+1] must be at most t[i]
                # max_slope is negative (e.g. -100)
                upper_bound = t[..., i]
                lower_bound = t[..., i] + max_slope
                t[..., i+1].clamp_(min=lower_bound, max=upper_bound)
    
    # Copying back to ensure the original parameter is updated
    tensor.copy_(t.permute(perm))

# ============================================================================
# Helpers
# ============================================================================

def compute_phase(board_or_fen) -> Tuple[int, int]:
    if isinstance(board_or_fen, chess.Board):
        b = board_or_fen
    else:
        b = chess.Board(board_or_fen)
    wh = 0
    bl = 0
    for pt, val in PHASE_VALUES.items():
        if val == 0: continue
        wh += len(b.pieces(pt, chess.WHITE)) * val
        bl += len(b.pieces(pt, chess.BLACK)) * val
    return wh, bl

def classify_phase(total_capped: int) -> str:
    if total_capped >= 58: return "opening"
    if total_capped >= 45: return "early_middlegame"
    if total_capped >= 30: return "middlegame"
    if total_capped >= 18: return "late_middlegame"
    return "endgame"

def rebalance_indices(phases: List[str], target: dict, seed: int) -> List[int]:
    rng = random.Random(seed)
    PHASE_LABELS = ["opening", "early_middlegame", "middlegame", "late_middlegame", "endgame"]
    by_class = {label: [] for label in PHASE_LABELS}
    for idx, cls in enumerate(phases):
        by_class.setdefault(cls, []).append(idx)
    if target is None:
        all_indices = []
        for idxs in by_class.values(): all_indices.extend(idxs)
        rng.shuffle(all_indices)
        return all_indices
    ratios = {k: target.get(k, 0.0) for k in PHASE_LABELS}
    candidates = []
    for cls, ratio in ratios.items():
        if ratio > 0 and by_class[cls]:
            candidates.append(len(by_class[cls]) / ratio)
    total_target = int(min(candidates)) if candidates else len(phases)
    desired = {}
    for cls, ratio in ratios.items():
        need = int(total_target * ratio)
        desired[cls] = min(need, len(by_class[cls]))
    selected = []
    for cls, idxs in by_class.items():
        need = desired.get(cls, 0)
        if need <= 0: continue
        if len(idxs) <= need: selected.extend(idxs)
        else: selected.extend(rng.sample(idxs, need))
    rng.shuffle(selected)
    return selected

def print_phase_distribution(phases: List[str], title: str):
    from collections import Counter
    counts = Counter(phases)
    total = len(phases)
    if total == 0:
        print(f"\n{title}: Empty")
        return
    PHASE_LABELS = ["opening", "early_middlegame", "middlegame", "late_middlegame", "endgame"]
    print(f"\n{title}")
    print("-" * 40)
    for label in PHASE_LABELS:
        count = counts.get(label, 0)
        pct = (count / total) * 100
        print(f"{label:<20}: {count:>10,} ({pct:>6.2f}%)")
    print("-" * 40)
    print(f"{'Total':<20}: {total:>10,}\n")

# ============================================================================
# Loader
# ============================================================================

def load_and_process_data(binhce_path, target_dist, seed, filtered_indices=None, no_phase_balancing=False, no_pre_filtering=False):
    print(f"Loading {binhce_path} metadata...")
    if not USING_FAST_LOADER:
        raise RuntimeError("Fast loader is required for large datasets. Please build it.")

    # Load only metadata first (extremely fast)
    sfen32s_all, scores_all, _, plies_all, results_all, _ = fast_loader.load_binhce(binhce_path, load_features=False)
    count_all = len(scores_all)
    
    # Vectorized filtering
    print(f"Filtering {count_all:,} positions...")
    
    # 1. Basic filters (Score and Ply)
    if no_pre_filtering:
        mask = np.ones(count_all, dtype=bool)
    else:
        # Determine turn from sfen32 (byte 0, bit 0: 0=White, 1=Black)
        b0 = sfen32s_all[:, 0]
        is_white = (b0 & 1) == 0
        turn_sign = np.where(is_white, 1.0, -1.0).astype(np.float32)
        
        adj_scores = scores_all.astype(np.float32) * turn_sign
        mask = (np.abs(adj_scores) <= 750) & (plies_all <= MAX_PLY)
    
    filtered_indices_list = np.where(mask)[0]
    print(f"Kept {len(filtered_indices_list):,} positions after primary filters.")

    # Compute phases for balancing only if requested
    if not no_phase_balancing:
        print("Computing phases for balancing (Slow loop)...")
        total_phase = np.zeros(len(filtered_indices_list), dtype=np.uint8)
        for i in range(0, len(filtered_indices_list), 100000):
            chunk_indices = filtered_indices_list[i:i+100000]
            for j, idx in enumerate(chunk_indices):
                board = binhce_reader._decode_position(sfen32s_all[idx])
                wh, bl = compute_phase(board)
                total_phase[i + j] = min(wh + bl, 64)
        
        phase_class = [classify_phase(tot) for tot in total_phase]
        selected_relative_indices = rebalance_indices(phase_class, target_dist, seed)
        
        # Print distributions
        final_phases = [phase_class[j] for j in selected_relative_indices]
        print_phase_distribution(phase_class, "PHASE DISTRIBUTION (Raw)")
        print_phase_distribution(final_phases, "PHASE DISTRIBUTION (Balanced)")
    else:
        selected_relative_indices = np.arange(len(filtered_indices_list))
    
    final_indices_to_load = filtered_indices_list[selected_relative_indices]
    num_positions = len(final_indices_to_load)
    
    print(f"Loading {num_positions:,} feature vectors in chunks...")
    final_features = np.zeros((num_positions, TOTAL_DIM), dtype=np.uint8)
    final_scores = np.zeros(num_positions, dtype=np.int16)
    final_results = np.zeros(num_positions, dtype=np.int8)
    
    # Compute relative turn signs first to guide reordering
    # In Lambergar/Bin40 format: Bit 0 of Byte 0 is side to move
    # SideToMove: 0=White, 1=Black
    b0_final_all = sfen32s_all[final_indices_to_load, 0]
    is_white_move = (b0_final_all & 1) == 0
    ts_final = np.where(is_white_move, 1.0, -1.0).astype(np.float32)

    CHUNK_SIZE = 2000000 
    for start_idx in range(0, num_positions, CHUNK_SIZE):
        end_idx = min(start_idx + CHUNK_SIZE, num_positions)
        current_chunk_indices = final_indices_to_load[start_idx:end_idx]
        # Align turn mask for broadcasting: (batch, 1)
        turn_chunk_is_white = is_white_move[start_idx:end_idx, np.newaxis] 
        
        _, s_chunk, _, _, r_chunk, f_raw_chunk = fast_loader.load_binhce_selective(binhce_path, current_chunk_indices.astype(np.uintp))
        
        # --- Perspective-Reorder to [Ally, Enemy] PERSPECTIVE ---
        ally_ptr = 0
        enemy_ptr = SIDE_SIZE
        raw_curr = 0
        for name, shape in SHAPES:
            p_size = int(np.prod(shape)) // 2
            s0 = f_raw_chunk[:, raw_curr : raw_curr + p_size]
            s1 = f_raw_chunk[:, raw_curr + p_size : raw_curr + 2*p_size]
            
            # (Side 0 is White, Side 1 is Black)
            final_features[start_idx:end_idx, ally_ptr : ally_ptr + p_size] = np.where(turn_chunk_is_white, s0, s1)
            final_features[start_idx:end_idx, enemy_ptr : enemy_ptr + p_size] = np.where(turn_chunk_is_white, s1, s0)
            
            ally_ptr += p_size
            enemy_ptr += p_size
            raw_curr += 2*p_size
            
        final_scores[start_idx:end_idx] = s_chunk
        final_results[start_idx:end_idx] = r_chunk
        print(f"  Loaded and Ally-relative reordered {end_idx:,}/{num_positions:,} positions...", end='\r')
    print()

    # --- Phase and Metadata Calculation ---
    print("Computing phases and targets...")
    # Lambergar scores in the binary are already Side-To-Move perspective (Mover-relative).
    scores_list = final_scores.astype(np.float32) 
    # Results in BinHceWriter are also ALREADY relative to side-to-move.
    adj_res = final_results.astype(np.float32) 
    targets_list = np.where(adj_res > 0, 1.0, np.where(adj_res < 0, 0.0, 0.5)).astype(np.float32)
    
    if not no_phase_balancing:
        final_total_phase = total_phase[selected_relative_indices].astype(np.float32)
    else:
        # Calculate phase from Perspective material Features
        pv_v = np.array([0, 3, 3, 5, 10, 0], dtype=np.float32)
        ally_mat = np.sum(final_features[:, 0:6].astype(np.float32) * pv_v, axis=1)
        enemy_mat = np.sum(final_features[:, SIDE_SIZE : SIDE_SIZE + 6].astype(np.float32) * pv_v, axis=1)
        final_total_phase = np.minimum(ally_mat + enemy_mat, 64.0)

    phases_list = ((64.0 - final_total_phase) / 64.0).astype(np.float32)

    phases_list = ((64.0 - final_total_phase) / 64.0).astype(np.float32)

    # We NO LONGER zero out material counts. 
    # Features 0:6 (Ally) and SIDE_SIZE:SIDE_SIZE+6 (Enemy) learn the BASE piece values.
    # PSQT will learn only the square-specific BONUSES.
    
    return final_features, targets_list, scores_list, phases_list







# ============================================================================
# Advanced Model with Learnable K
# ============================================================================

class HCEModel(nn.Module):
    def __init__(self, k_value=0.006):
        super().__init__()
        # Leaf Tensors for the optimizer
        self.weights_mg_base = nn.Parameter(torch.zeros(BASE_SIZE))
        self.weights_eg_base = nn.Parameter(torch.zeros(BASE_SIZE))
        self.weights_mg_pos = nn.Parameter(torch.zeros(POS_SIZE))
        self.weights_eg_pos = nn.Parameter(torch.zeros(POS_SIZE))
        self.register_buffer('k_value', torch.tensor(k_value, dtype=torch.float32))

    def init_smart(self, shapes):
        with torch.no_grad():
            offset = 0
            for name, shape in shapes:
                size = int(np.prod(shape)) // 2
                if name == "mat":
                    for i in range(6): 
                        self.weights_mg_base[offset + i] = INIT_MAT[i]
                        self.weights_eg_base[offset + i] = INIT_MAT[i]
                offset += size
                if offset >= BASE_SIZE: break

    def forward(self, x_uint8, phase):
        # We work on batches, so view as [Batch, 2, SIDE_SIZE]
        x = x_uint8.view(x_uint8.shape[0], 2, SIDE_SIZE).float()
        x_diff = x[:, 0, :] - x[:, 1, :]
        
        # Concat is only for the forward pass calculation
        w_mg = torch.cat([self.weights_mg_base, self.weights_mg_pos])
        w_eg = torch.cat([self.weights_eg_base, self.weights_eg_pos])
        
        out_mg = torch.matmul(x_diff, w_mg).unsqueeze(-1)
        out_eg = torch.matmul(x_diff, w_eg).unsqueeze(-1)
        return out_mg * (1 - phase) + out_eg * phase

    @property
    def params_dict(self):
        pd = {}
        offset = 0
        for name, shape in SHAPES:
            perspective_size = int(np.prod(shape)) // 2
            
            # Identify which leaf parameter to slice from
            if offset < BASE_SIZE:
                p_mg, p_eg = self.weights_mg_base, self.weights_eg_base
                rel_offset = offset
            else:
                p_mg, p_eg = self.weights_mg_pos, self.weights_eg_pos
                rel_offset = offset - BASE_SIZE
            
            # SLICE of LEAF = VIEW. Editing this updates the leaf.
            pd[name] = [
                p_mg[rel_offset : rel_offset + perspective_size].view(shape[1:] if len(shape)>1 else (1,)),
                p_eg[rel_offset : rel_offset + perspective_size].view(shape[1:] if len(shape)>1 else (1,))
            ]
            offset += perspective_size
        return pd

def export_centered_zig(model, output_path, args=None):
    params = model.params_dict
    k_val = model.k_value.item()
    
    with torch.no_grad():
        # Get raw numpy values
        psqt_mg = params["psqt"][0].detach().cpu().numpy()
        psqt_eg = params["psqt"][1].detach().cpu().numpy()
        base_mg = params["mat"][0].detach().cpu().numpy().flatten()
        base_eg = params["mat"][1].detach().cpu().numpy().flatten()

        # Dictionary to store mean offsets for each piece type
        # 0: Pawn, 1: Knight, 2: Bishop, 3: Rook, 4: Queen, 5: King
        offsets_mg = np.zeros(6)
        offsets_eg = np.zeros(6)

        # 1. Center PSQT
        for i in range(6):
            if i == 0: # PAWN: Only center ranks 2-7
                m_mg = np.mean(psqt_mg[i][8:56])
                m_eg = np.mean(psqt_eg[i][8:56])
                psqt_mg[i][8:56] -= m_mg
                psqt_eg[i][8:56] -= m_eg
                psqt_mg[i][0:8] = 0; psqt_mg[i][56:64] = 0
                psqt_eg[i][0:8] = 0; psqt_eg[i][56:64] = 0
            else:
                m_mg = np.mean(psqt_mg[i])
                m_eg = np.mean(psqt_eg[i])
                psqt_mg[i] -= m_mg
                psqt_eg[i] -= m_eg
            offsets_mg[i] += m_mg
            offsets_eg[i] += m_eg

        # 2. Center Piece-Specific Mobility
        # Knight (1)
        m_mg = np.mean(params["knight_mobility"][0].detach().cpu().numpy())
        m_eg = np.mean(params["knight_mobility"][1].detach().cpu().numpy())
        params["knight_mobility"][0].sub_(m_mg)
        params["knight_mobility"][1].sub_(m_eg)
        offsets_mg[1] += m_mg; offsets_eg[1] += m_eg

        # Bishop (2)
        m_mg = np.mean(params["bishop_mobility"][0].detach().cpu().numpy())
        m_eg = np.mean(params["bishop_mobility"][1].detach().cpu().numpy())
        params["bishop_mobility"][0].sub_(m_mg)
        params["bishop_mobility"][1].sub_(m_eg)
        offsets_mg[2] += m_mg; offsets_eg[2] += m_eg

        # Rook (3)
        m_mg = np.mean(params["rook_mobility"][0].detach().cpu().numpy())
        m_eg = np.mean(params["rook_mobility"][1].detach().cpu().numpy())
        params["rook_mobility"][0].sub_(m_mg)
        params["rook_mobility"][1].sub_(m_eg)
        offsets_mg[3] += m_mg; offsets_eg[3] += m_eg

        # Queen (4)
        m_mg = np.mean(params["queen_mobility"][0].detach().cpu().numpy())
        m_eg = np.mean(params["queen_mobility"][1].detach().cpu().numpy())
        params["queen_mobility"][0].sub_(m_mg)
        params["queen_mobility"][1].sub_(m_eg)
        offsets_mg[4] += m_mg; offsets_eg[4] += m_eg

        # 3. Calculate Final Material
        final_mat_mg = [int(round(base_mg[i] + offsets_mg[i])) for i in range(6)]
        final_mat_eg = [int(round(base_eg[i] + offsets_eg[i])) for i in range(6)]
        final_mat_mg[5] = 0; final_mat_eg[5] = 0 # Force King to 0

    now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(output_path, 'w') as f:
        f.write("// Auto-generated HCE parameters (Centered)\n")
        f.write(f"// Generated: {now_str}\n\n")
        
        if args:
            f.write(f"// Training Config:\n")
            # Sort arguments alphabetically to keep the header clean
            for key, value in sorted(vars(args).items()):
                # Format boolean flags differently to match CLI usage
                if isinstance(value, bool):
                    if value:
                        f.write(f"//   --{key.replace('_', '-')}\n")
                elif value is not None:
                    f.write(f"//   --{key.replace('_', '-')} {value}\n")
            f.write("\n")

        f.write(f"// K-Factor (Internal): {k_val:.6f}\n\n")

        f.write(f"pub const material_mg = [6]i32{{ {', '.join(map(str, final_mat_mg))} }};\n")
        f.write(f"pub const material_eg = [6]i32{{ {', '.join(map(str, final_mat_eg))} }};\n\n")

        for i, pname in enumerate(["pawn", "knight", "bishop", "rook", "queen", "king"]):
            v_mg = ", ".join(f"{int(round(x))}" for x in psqt_mg[i])
            v_eg = ", ".join(f"{int(round(x))}" for x in psqt_eg[i])
            f.write(f"pub const mg_{pname}_table = [64]i32{{ {v_mg} }};\n")
            f.write(f"pub const eg_{pname}_table = [64]i32{{ {v_eg} }};\n")
        f.write("\n")

        for name, tensors in params.items():
            if name in ["psqt", "mat"]: continue
            mapped = name
            if name == "passed_pawn": mapped = "passed_score"
            elif name == "isolated_pawn": mapped = "isolated_pawn_score"
            elif name == "blocked_passer": mapped = "blocked_passer_score"

            t_mg = tensors[0].detach().cpu().numpy().flatten()
            t_eg = tensors[1].detach().cpu().numpy().flatten()
            v_mg = ", ".join(f"{int(round(x))}" for x in t_mg)
            v_eg = ", ".join(f"{int(round(x))}" for x in t_eg)
            f.write(f"pub const mg_{mapped} = [{len(t_mg)}]i32{{ {v_mg} }};\n")
            f.write(f"pub const eg_{mapped} = [{len(t_eg)}]i32{{ {v_eg} }};\n\n")

# ============================================================================
# Advanced Training
# ============================================================================

class BlendedLoss(nn.Module):
    def __init__(self, alpha=0.5):
        super().__init__()
        self.alpha = alpha
        self.bce = nn.BCEWithLogitsLoss()

    def forward(self, logits, targets, scores, k_value):
        # Sigmoid scaling
        score_prob = torch.sigmoid(scores * k_value)
        blended_target = self.alpha * targets + (1.0 - self.alpha) * score_prob
        # Logits are now in centipawns directly
        scaled_logits = logits * k_value 
        return self.bce(scaled_logits, blended_target)

class MSELossProb(nn.Module):
    def __init__(self, alpha=0.5):
        super().__init__()
        self.alpha = alpha
        self.mse = nn.MSELoss()

    def forward(self, logits, targets, scores, k_value):
        score_prob = torch.sigmoid(scores * k_value)
        blended_target = self.alpha * targets + (1.0 - self.alpha) * score_prob
        scaled_logits = logits * k_value
        pred_prob = torch.sigmoid(scaled_logits)
        return self.mse(pred_prob, blended_target)

class HuberLossProb(nn.Module):
    def __init__(self, alpha=0.5, delta=0.1):
        super().__init__()
        self.alpha = alpha
        self.huber = nn.HuberLoss(delta=delta)

    def forward(self, logits, targets, scores, k_value):
        score_prob = torch.sigmoid(scores * k_value)
        blended_target = self.alpha * targets + (1.0 - self.alpha) * score_prob
        scaled_logits = logits * k_value
        pred_prob = torch.sigmoid(scaled_logits)
        return self.huber(pred_prob, blended_target)

class Lookahead(torch.optim.Optimizer):
    """
    Lookahead Optimizer: https://arxiv.org/abs/1907.08610
    Maintains a 'slow' set of weights that improves generalization.
    """
    def __init__(self, optimizer, k=5, alpha=0.5):
        self.optimizer = optimizer
        self.k = k
        self.alpha = alpha
        self.param_groups = self.optimizer.param_groups
        self.state = self.optimizer.state
        self.fast_state = self.optimizer.state
        for group in self.param_groups:
            group["step_counter"] = 0
        self.slow_weights = [[p.data.clone().detach() for p in group["params"]] for group in self.param_groups]

    def step(self, closure=None):
        loss = self.optimizer.step(closure)
        for i, group in enumerate(self.param_groups):
            group["step_counter"] += 1
            if group["step_counter"] % self.k == 0:
                for p, slow_p in zip(group["params"], self.slow_weights[i]):
                    slow_p.data.add_(self.alpha, p.data - slow_p.data)
                    p.data.copy_(slow_p.data)
        return loss

    def state_dict(self):
        return self.optimizer.state_dict()

    def load_state_dict(self, state_dict):
        self.optimizer.load_state_dict(state_dict)

class EMAModel:
    """
    Exponential Moving Average of model weights.
    Often generalizes better than the raw weights.
    """
    def __init__(self, model, decay=0.999):
        self.decay = decay
        self.shadow = {}
        for name, param in model.named_parameters():
            if param.requires_grad:
                self.shadow[name] = param.data.clone()

    def update(self, model):
        for name, param in model.named_parameters():
            if param.requires_grad:
                new_average = (1.0 - self.decay) * param.data + self.decay * self.shadow[name]
                self.shadow[name].copy_(new_average)

    def apply_to_model(self, model):
        for name, param in model.named_parameters():
            if param.requires_grad:
                param.data.copy_(self.shadow[name])

class KLDivLossProb(nn.Module):
    def __init__(self, alpha=0.5, temperature=1.0):
        super().__init__()
        self.alpha = alpha
        self.temp = temperature
        self.kl = nn.KLDivLoss(reduction='batchmean')

    def forward(self, logits, targets, scores, k_value):
        # Soften targets using temperature
        score_prob = torch.sigmoid(scores * k_value / self.temp)
        blended_target = self.alpha * targets + (1.0 - self.alpha) * score_prob
        
        # Construct target distribution [p, 1-p]
        target_dist = torch.cat([blended_target, 1.0 - blended_target], dim=1)
        
        # Input Log-Distribution [log(p), log(1-p)] 
        scaled_logits = (logits * k_value) / self.temp
        log_p = F.logsigmoid(scaled_logits)
        log_one_minus_p = F.logsigmoid(-scaled_logits)
        input_log_dist = torch.cat([log_p, log_one_minus_p], dim=1)
        
        return self.kl(input_log_dist, target_dist)

class DatasetWrapper(Dataset):
    def __init__(self, f_uint8, t, s, p):
        self.f = torch.from_numpy(f_uint8) # uint8 tensor
        self.t = torch.from_numpy(t).float().unsqueeze(1)
        self.s = torch.from_numpy(s).float().unsqueeze(1)
        self.p = torch.from_numpy(p).float().unsqueeze(1)
    def __len__(self): return len(self.f)
    def __getitem__(self, i): return self.f[i], self.t[i], self.s[i], self.p[i]

def train_model(args, preloaded_data=None):
    # Device selection with sanity check
    device = torch.device("cpu")
    if torch.cuda.is_available():
        try:
            # Test if CUDA is actually working (handles Error 804 driver issues)
            test_tensor = torch.zeros(1).to("cuda")
            device = torch.device("cuda")
            print("Using CUDA acceleration.")
        except Exception as e:
            print(f"CUDA detected but failed to initialize: {e}")
            print("Falling back to CPU mode.")
    else:
        print("Using CPU mode.")

    # 1. Initialize Model First (Small and Fast)
    model = HCEModel(args.k_factor).to(device)
    model.init_smart(SHAPES)
    
    # Differential Learning Rate: Pass original Leaf parameters to the optimizer
    # We define this early so we can export the header
    optim_params = [
        {'params': [model.weights_mg_base, model.weights_eg_base], 'lr': args.lr},
        {'params': [model.weights_mg_pos, model.weights_eg_pos], 'lr': args.lr * 5.0}
    ]

    # Save initial config header immediately so user can verify it during the long data loading
    print(f"Initializing {args.zig_out} header...")
    export_centered_zig(model, args.zig_out, args)

    if preloaded_data:
        feats_uint8, targets, scores, phases = preloaded_data
    else:
        target_dist = { "opening": args.target_open, "early_middlegame": args.target_early_mid, "middlegame": args.target_mid, "late_middlegame": args.target_late_mid, "endgame": args.target_end }
        feats_uint8, targets, scores, phases = load_and_process_data(
            args.binhce, target_dist, args.seed, None,
            getattr(args, 'no_phase_balancing', False), 
            getattr(args, 'no_pre_filtering', False)
        )

    split = int(0.9 * len(feats_uint8))
    train_ds = DatasetWrapper(feats_uint8[:split], targets[:split], scores[:split], phases[:split])
    val_ds = DatasetWrapper(feats_uint8[split:], targets[split:], scores[split:], phases[split:])

    num_workers = getattr(args, 'workers', 0) # Windows handles workers better with 0 if memory is tight, or use small number
    
    kwargs = {'num_workers': num_workers, 'pin_memory': True} if device.type == 'cuda' else {}
    train_loader = DataLoader(train_ds, batch_size=args.batch_size, shuffle=True, **kwargs)
    val_loader = DataLoader(val_ds, batch_size=args.batch_size*2, shuffle=False, **kwargs)

    # Setup model and constraints
    constraint_interval = getattr(args, 'constraint_interval', 10)
    
    try: model = torch.compile(model)
    except: pass

    # Load constraints
    constraints_path = getattr(args, 'constraints', None)
    constraints = {}
    if not getattr(args, 'no_constraints', False):
        constraints = load_constraints(constraints_path)
        if constraints: print(f"Active constraints for {len(constraints)} features")
    apply_constraints(model.params_dict, constraints, SHAPES)

    # Differential Learning Rate: Pass original Leaf parameters to the optimizer
    optim_params = [
        {'params': [model.weights_mg_base, model.weights_eg_base], 'lr': args.lr},
        {'params': [model.weights_mg_pos, model.weights_eg_pos], 'lr': args.lr * 5.0}
    ]
    
    if args.optimizer == "adagrad":
        base_optimizer = torch.optim.Adagrad(optim_params, weight_decay=args.lambda_l2)
    elif args.optimizer == "adam":
        base_optimizer = torch.optim.Adam(optim_params, weight_decay=args.lambda_l2)
    else:
        base_optimizer = torch.optim.SGD(optim_params, momentum=0.9, weight_decay=args.lambda_l2)

    optimizer = Lookahead(base_optimizer) if args.lookahead else base_optimizer

    scheduler = None
    if not getattr(args, 'no_scheduler', False):
        if args.scheduler == "power":
            scheduler = torch.optim.lr_scheduler.LambdaLR(optimizer, 
                lr_lambda=lambda epoch: (1.0 + epoch / 10.0)**-0.5)
            print(f"Scheduler: Power-Law Decay (Gamma=0.5)")
        else:
            scheduler = torch.optim.lr_scheduler.ReduceLROnPlateau(optimizer, mode='min', factor=0.2, patience=8)
            print(f"Scheduler: ReduceLROnPlateau (Factor=0.2, Patience=8)")
    
    if args.loss == "mse":
        criterion = MSELossProb(alpha=args.alpha)
    elif args.loss == "huber":
        criterion = HuberLossProb(alpha=args.alpha, delta=args.huber_delta)
    elif args.loss == "kl":
        criterion = KLDivLossProb(alpha=args.alpha, temperature=args.temperature)
    else:
        criterion = BlendedLoss(alpha=args.alpha)
    
    # Regularization Config
    l1_lambda = getattr(args, 'lambda_l1', 0.0)
    l2_lambda = args.lambda_l2

    print("\n--- Training Configuration ---")
    print(f"Alpha: {args.alpha} ({args.alpha*100}% result, {(1-args.alpha)*100}% score)")
    print(f"Loss: {args.loss}")
    if args.loss == "kl":
        print(f"Temperature: {args.temperature}")
    if args.optimizer:
        print(f"Optimizer: {args.optimizer}")
    if args.ema > 0:
        print(f"EMA Smoothing: {args.ema}")
    if args.lookahead:
        print(f"Lookahead: Active (k=5, alpha=0.5)")
    print("------------------------------\n")
    
    
    best_val_loss = float('inf')
    best_state = None
    epochs_without_improvement = 0

    # Vectorized Batching Optimization:
    # Instead of DataLoader, we slice the NumPy arrays directly.
    # This is much faster for datasets that fit in RAM.
    train_indices = np.arange(split)
    val_indices = np.arange(split, len(feats_uint8))

    print(f"Training for {args.epochs} epochs...")
    print(f"Batch Size: {args.batch_size} | Fixed K: {args.k_factor} | L1: {l1_lambda}")
    if scheduler: print(f"Scheduler: ReduceLROnPlateau (Factor=0.2, Patience=8)")
    if args.patience > 0: print(f"Early Stopping: Active (Patience={args.patience})")
    
    ema = EMAModel(model, decay=args.ema) if args.ema > 0 else None

    for epoch in range(1, args.epochs+1):
        model.train()
        train_loss_sum = 0
        train_count = 0
        
        # Shuffle indices once at the start of epoch
        np.random.shuffle(train_indices)
        
        for i in range(0, split, args.batch_size):
            batch_idx = train_indices[i : i + args.batch_size]
            
            # Fast vectorized slice + move to GPU
            bx = torch.from_numpy(feats_uint8[batch_idx]).to(device, non_blocking=True)
            by = torch.from_numpy(targets[batch_idx]).float().unsqueeze(1).to(device, non_blocking=True)
            bs = torch.from_numpy(scores[batch_idx]).float().unsqueeze(1).to(device, non_blocking=True)
            bp = torch.from_numpy(phases[batch_idx]).float().unsqueeze(1).to(device, non_blocking=True)
            
            optimizer.zero_grad(set_to_none=True)
            
            # Loss and Backprop
            logits = model(bx, bp)
            loss = criterion(logits, by, bs, model.k_value)
            
            if l1_lambda > 0:
                l1_loss = sum(p.abs().sum() for p in model.parameters())
                loss += l1_lambda * l1_loss
            
            loss.backward()
            
            if args.grad_clip > 0:
                nn.utils.clip_grad_norm_(model.parameters(), args.grad_clip)
                
            optimizer.step()

            if ema:
                ema.update(model)
            
            if (i // args.batch_size) % constraint_interval == 0:
                apply_constraints(model.params_dict, constraints, SHAPES)
            
            train_loss_sum += loss.item() * len(batch_idx)
            train_count += len(batch_idx)
        
        apply_constraints(model.params_dict, constraints, SHAPES)
        avg_train = train_loss_sum / train_count

        # Validation
        model.eval()
        vloss_sum = 0
        vcount = 0
        with torch.no_grad():
            for i in range(0, len(val_indices), args.batch_size * 2):
                batch_idx = val_indices[i : i + args.batch_size * 2]
                bx = torch.from_numpy(feats_uint8[batch_idx]).to(device, non_blocking=True)
                by = torch.from_numpy(targets[batch_idx]).float().unsqueeze(1).to(device, non_blocking=True)
                bs = torch.from_numpy(scores[batch_idx]).float().unsqueeze(1).to(device, non_blocking=True)
                bp = torch.from_numpy(phases[batch_idx]).float().unsqueeze(1).to(device, non_blocking=True)
                
                vloss = criterion(model(bx, bp), by, bs, model.k_value)
                vloss_sum += vloss.item() * len(batch_idx)
                vcount += len(batch_idx)
        avg_val = vloss_sum / vcount

        if args.scheduler == "power":
            scheduler.step()
        else:
            scheduler.step(avg_val)

        # Early Stopping & Best Model Tracking
        if avg_val < best_val_loss:
            best_val_loss = avg_val
            epochs_without_improvement = 0
            # Save the best model state
            best_state = {k: v.cpu().clone() for k, v in model.state_dict().items()}
        else:
            epochs_without_improvement += 1

        if epoch % 10 == 0 or epoch == 1 or epoch == args.epochs or (args.patience > 0 and epochs_without_improvement >= args.patience):
            lr_val = optimizer.param_groups[0]['lr']
            k_disp = model.k_value.item()
            print(f"Epoch {epoch:3d} | Train: {avg_train:.6f} | Val: {avg_val:.6f} | LR: {lr_val:.1e} | K: {k_disp:.5f}")
            
            if epoch % 10 == 0 or epoch == 1:
                # Save the main rolling file
                export_centered_zig(model, args.zig_out, args)
                
                # Save a snapshot file for this specific epoch
                snapshot_path = args.zig_out.replace(".zig", f"_{epoch}.zig")
                export_centered_zig(model, snapshot_path, args)
        
        if args.patience > 0 and epochs_without_improvement >= args.patience:
            print(f"Early stopping triggered after {epoch} epochs (No improvement for {args.patience} epochs).")
            break

    # Restore best model before export
    if best_state is not None:
        model.load_state_dict(best_state)

    if ema:
        print("Applying EMA smoothing to final parameters...")
        ema.apply_to_model(model)

    print(f"Exporting centered parameters to {args.zig_out}...")
    export_centered_zig(model, args.zig_out, args)
    return True

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binhce", required=True)
    parser.add_argument("--zig-out", default="tuned_hce_params.zig")
    parser.add_argument("--epochs", type=int, default=100)
    parser.add_argument("--batch-size", type=int, default=65536)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--constraint-interval", type=int, default=10)
    parser.add_argument("--lr", type=float, default=0.05)
    parser.add_argument("--alpha", type=float, default=0.8)
    parser.add_argument("--lambda-l2", type=float, default=0.0, help="L2 regularization weight (shrinkage)")
    parser.add_argument("--lambda-l1", type=float, default=0.0, help="L1 regularization weight (sparsity)")
    parser.add_argument("--k-factor", type=float, default=0.006)
    parser.add_argument("--min-legal-moves", type=int, default=0)
    parser.add_argument("--max-material-imbalance", type=int, default=999)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--device", default="auto")
    parser.add_argument("--resume", type=str)
    parser.add_argument("--filter-indices", type=str)
    parser.add_argument("--target_open", type=float, default=0.07)
    parser.add_argument("--target_early_mid", type=float, default=0.25)
    parser.add_argument("--target_mid", type=float, default=0.25)
    parser.add_argument("--target_late_mid", type=float, default=0.25)
    parser.add_argument("--target_end", type=float, default=0.18)
    parser.add_argument("--no-phase-balancing", action="store_true")
    parser.add_argument("--no-pre-filtering", action="store_true")
    parser.add_argument("--no-constraints", action="store_true")
    parser.add_argument("--no-scheduler", action="store_true", help="Disable learning rate scheduler")
    parser.add_argument("--patience", type=int, default=8, help="Epochs to wait for improvement before stopping (0 to disable)")
    parser.add_argument("--constraints", type=str, help="Path to constraints .json file")
    parser.add_argument("--optimizer", choices=["adam", "adagrad", "sgd"], default="adam", help="Optimizer type")
    parser.add_argument("--loss", choices=["bce", "mse", "huber", "kl"], default="bce", help="Loss function type")
    parser.add_argument("--huber-delta", type=float, default=0.1, help="Delta parameter for Huber loss")
    parser.add_argument("--temperature", type=float, default=1.0, help="Temperature for KL divergence loss")
    parser.add_argument("--grad-clip", type=float, default=1.0, help="Clip gradient norm (0 to disable)")
    parser.add_argument("--ema", type=float, default=0.99, help="EMA decay for weights (0 to disable). 0.99-0.999 is good.")
    parser.add_argument("--lookahead", action="store_true", help="Use Lookahead optimizer wrapper")
    parser.add_argument("--scheduler", choices=["plateau", "power"], default="plateau", help="LR Scheduler type")
    args = parser.parse_args()
    train_model(args)