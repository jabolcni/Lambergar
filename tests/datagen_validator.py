#!/usr/bin/env python3
"""
Validate generated training data (binhce format) for quality and correctness.
Checks FEN validity, HCE feature extraction, score distribution, and phase balance.
"""

import argparse
import struct
import subprocess
import sys
from pathlib import Path
from typing import List, Tuple, Dict, Optional
from dataclasses import dataclass
import random


@dataclass
class BinHCEEntry:
    """Single entry from binhce file"""
    sfen32: bytes  # 32 bytes compressed position
    score_cp: int  # Score in centipawns
    move16: int    # Best move (16-bit encoding)
    ply: int       # Game ply
    game_result: int  # Game result (-1, 0, 1)
    hce_features: List[int]  # HCE feature vector


class BinHCEReader:
    """Reader for binhce format files"""
    
    # Feature vector sizes (from tuner.zig)
    FEATURE_SIZES = {
        'mat': 2 * 6,  # 2 colors × 6 piece types
        'psqt': 2 * 6 * 64,  # 2 colors × 6 piece types × 64 squares
        'passed_pawn': 2 * 64,
        'isolated_pawn': 2 * 8,
        'blocked_passer': 2 * 8,
        'supported_pawn': 2 * 8,
        'pawn_phalanx': 2 * 8,
        'knight_mobility': 2 * 9,
        'bishop_mobility': 2 * 14,
        'rook_mobility': 2 * 15,
        'queen_mobility': 2 * 28,
        'pawn_attacking': 2 * 6,
        'knight_attacking': 2 * 6,
        'bishop_attacking': 2 * 6,
        'rook_attacking': 2 * 6,
        'queen_attacking': 2 * 6,
        'doubled_pawns': 2,
        'bishop_pair': 2,
    }
    
    TOTAL_FEATURES = sum(FEATURE_SIZES.values())
    
    # Entry size: 32 (sfen) + 2 (score) + 2 (move) + 2 (ply) + 1 (result) + TOTAL_FEATURES
    ENTRY_SIZE = 32 + 2 + 2 + 2 + 1 + TOTAL_FEATURES
    
    def __init__(self, filepath: str):
        self.filepath = Path(filepath)
        if not self.filepath.exists():
            raise FileNotFoundError(f"File not found: {filepath}")
    
    def read_entries(self, max_entries: Optional[int] = None) -> List[BinHCEEntry]:
        """Read entries from binhce file"""
        entries = []
        
        with open(self.filepath, 'rb') as f:
            entry_count = 0
            while True:
                if max_entries and entry_count >= max_entries:
                    break
                
                # Read entry
                data = f.read(self.ENTRY_SIZE)
                if len(data) < self.ENTRY_SIZE:
                    break
                
                # Parse entry
                sfen32 = data[0:32]
                score_cp = struct.unpack('<h', data[32:34])[0]  # signed short
                move16 = struct.unpack('<H', data[34:36])[0]    # unsigned short
                ply = struct.unpack('<H', data[36:38])[0]       # unsigned short
                game_result = struct.unpack('<b', data[38:39])[0]  # signed byte
                
                # HCE features (all unsigned bytes)
                hce_features = list(data[39:39 + self.TOTAL_FEATURES])
                
                entry = BinHCEEntry(
                    sfen32=sfen32,
                    score_cp=score_cp,
                    move16=move16,
                    ply=ply,
                    game_result=game_result,
                    hce_features=hce_features
                )
                
                entries.append(entry)
                entry_count += 1
        
        return entries
    
    def get_file_size(self) -> int:
        """Get file size in bytes"""
        return self.filepath.stat().st_size
    
    def get_entry_count(self) -> int:
        """Get total number of entries in file"""
        return self.get_file_size() // self.ENTRY_SIZE


class DataValidator:
    """Validator for binhce training data"""
    
    def __init__(self, binhce_file: str, engine_path: str, verbose: bool = False):
        self.reader = BinHCEReader(binhce_file)
        self.engine_path = Path(engine_path)
        self.verbose = verbose
        
        if not self.engine_path.exists():
            raise FileNotFoundError(f"Engine not found: {engine_path}")
    
    def validate_hce_features(self, entries: List[BinHCEEntry], sample_size: int = 100) -> Tuple[int, int]:
        """
        Validate HCE features by comparing with engine recomputation
        Returns: (passed, failed) counts
        """
        print(f"\nValidating HCE features (sample size: {sample_size})...")
        
        # Sample entries
        if len(entries) > sample_size:
            sample = random.sample(entries, sample_size)
        else:
            sample = entries
        
        passed = 0
        failed = 0
        
        for i, entry in enumerate(sample):
            # Convert sfen32 to hex string
            sfen_hex = entry.sfen32.hex()
            
            # Query engine for HCE features
            command = f"hcefeatures_sfen32 {sfen_hex}\nquit\n"
            
            try:
                process = subprocess.Popen(
                    [str(self.engine_path)],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True
                )
                
                stdout, _ = process.communicate(input=command, timeout=5)
                
                # Parse HCE features from output
                engine_features = None
                for line in stdout.split('\n'):
                    if "info string hce_features" in line:
                        # Extract feature vector
                        parts = line.split("hce_features")
                        if len(parts) > 1:
                            feature_str = parts[1].strip()
                            engine_features = [int(x) for x in feature_str.split(',')]
                            break
                
                if engine_features is None:
                    print(f"  ✗ Entry {i}: Could not extract features from engine")
                    failed += 1
                    continue
                
                # Compare features
                if engine_features == entry.hce_features:
                    passed += 1
                    if self.verbose:
                        print(f"  ✓ Entry {i}: Features match")
                else:
                    failed += 1
                    print(f"  ✗ Entry {i}: Feature mismatch")
                    if self.verbose:
                        print(f"    Expected: {entry.hce_features[:20]}...")
                        print(f"    Got:      {engine_features[:20]}...")
                
            except subprocess.TimeoutExpired:
                print(f"  ✗ Entry {i}: Engine timeout")
                failed += 1
                process.kill()
            except Exception as e:
                print(f"  ✗ Entry {i}: Error - {e}")
                failed += 1
        
        return passed, failed
    
    def analyze_score_distribution(self, entries: List[BinHCEEntry]) -> Dict:
        """Analyze score distribution"""
        scores = [e.score_cp for e in entries]
        
        return {
            'min': min(scores),
            'max': max(scores),
            'mean': sum(scores) / len(scores) if scores else 0,
            'outliers_high': sum(1 for s in scores if s > 2500),
            'outliers_low': sum(1 for s in scores if s < -2500),
        }
    
    def analyze_phase_distribution(self, entries: List[BinHCEEntry]) -> Dict:
        """Analyze game phase distribution"""
        # Rough phase estimation based on ply
        opening = sum(1 for e in entries if e.ply < 20)
        middlegame = sum(1 for e in entries if 20 <= e.ply < 60)
        endgame = sum(1 for e in entries if e.ply >= 60)
        
        total = len(entries)
        return {
            'opening': opening,
            'opening_pct': 100 * opening / total if total > 0 else 0,
            'middlegame': middlegame,
            'middlegame_pct': 100 * middlegame / total if total > 0 else 0,
            'endgame': endgame,
            'endgame_pct': 100 * endgame / total if total > 0 else 0,
        }
    
    def analyze_result_distribution(self, entries: List[BinHCEEntry]) -> Dict:
        """Analyze game result distribution"""
        white_wins = sum(1 for e in entries if e.game_result == 1)
        draws = sum(1 for e in entries if e.game_result == 0)
        black_wins = sum(1 for e in entries if e.game_result == -1)
        
        total = len(entries)
        return {
            'white_wins': white_wins,
            'white_wins_pct': 100 * white_wins / total if total > 0 else 0,
            'draws': draws,
            'draws_pct': 100 * draws / total if total > 0 else 0,
            'black_wins': black_wins,
            'black_wins_pct': 100 * black_wins / total if total > 0 else 0,
        }
    
    def run_validation(self, sample_size: int = 1000) -> bool:
        """Run complete validation"""
        print(f"\n=== Validating binhce file: {self.reader.filepath} ===\n")
        
        # Get file info
        total_entries = self.reader.get_entry_count()
        file_size_mb = self.reader.get_file_size() / (1024 * 1024)
        print(f"File size: {file_size_mb:.2f} MB")
        print(f"Total entries: {total_entries:,}")
        
        # Read sample
        print(f"\nReading sample ({sample_size} entries)...")
        entries = self.reader.read_entries(max_entries=sample_size)
        print(f"Read {len(entries)} entries")
        
        # Validate HCE features
        passed, failed = self.validate_hce_features(entries, sample_size=min(100, len(entries)))
        print(f"\nHCE Feature Validation: {passed} passed, {failed} failed")
        
        # Analyze distributions
        print("\n=== Score Distribution ===")
        score_dist = self.analyze_score_distribution(entries)
        print(f"  Min: {score_dist['min']}")
        print(f"  Max: {score_dist['max']}")
        print(f"  Mean: {score_dist['mean']:.1f}")
        print(f"  Outliers (>2500): {score_dist['outliers_high']}")
        print(f"  Outliers (<-2500): {score_dist['outliers_low']}")
        
        print("\n=== Phase Distribution ===")
        phase_dist = self.analyze_phase_distribution(entries)
        print(f"  Opening (<20 ply): {phase_dist['opening']:5d} ({phase_dist['opening_pct']:.1f}%)")
        print(f"  Middlegame (20-60): {phase_dist['middlegame']:5d} ({phase_dist['middlegame_pct']:.1f}%)")
        print(f"  Endgame (>60):     {phase_dist['endgame']:5d} ({phase_dist['endgame_pct']:.1f}%)")
        
        print("\n=== Result Distribution ===")
        result_dist = self.analyze_result_distribution(entries)
        print(f"  White wins: {result_dist['white_wins']:5d} ({result_dist['white_wins_pct']:.1f}%)")
        print(f"  Draws:      {result_dist['draws']:5d} ({result_dist['draws_pct']:.1f}%)")
        print(f"  Black wins: {result_dist['black_wins']:5d} ({result_dist['black_wins_pct']:.1f}%)")
        
        # Overall assessment
        print("\n=== Validation Summary ===")
        all_passed = failed == 0 and score_dist['outliers_high'] == 0 and score_dist['outliers_low'] == 0
        
        if all_passed:
            print("✓ All validation checks PASSED")
        else:
            print("✗ Some validation checks FAILED")
            if failed > 0:
                print(f"  - {failed} HCE feature mismatches")
            if score_dist['outliers_high'] > 0 or score_dist['outliers_low'] > 0:
                print(f"  - Score outliers detected")
        
        return all_passed


def main():
    parser = argparse.ArgumentParser(description="Validate binhce training data")
    parser.add_argument("--binhce", required=True, help="Path to binhce file")
    parser.add_argument("--engine", required=True, help="Path to engine executable")
    parser.add_argument("--sample", type=int, default=1000, help="Sample size for validation")
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose output")
    
    args = parser.parse_args()
    
    try:
        validator = DataValidator(args.binhce, args.engine, verbose=args.verbose)
        success = validator.run_validation(sample_size=args.sample)
        sys.exit(0 if success else 1)
        
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
