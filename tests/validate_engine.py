#!/usr/bin/env python3
"""
Master validation script for the Lambergar chess engine.
Orchestrates comprehensive testing across multiple validation layers.
"""

import argparse
import subprocess
import sys
import json
import time
from pathlib import Path
from typing import Dict, List, Tuple, Optional
from dataclasses import dataclass, asdict

# Import UCI compliance tester
try:
    from uci_compliance import ComplianceTester
    HAS_COMPLIANCE = True
except ImportError:
    HAS_COMPLIANCE = False

# Import python-chess for move parsing
try:
    import chess
    HAS_CHESS_LIB = True
except ImportError:
    HAS_CHESS_LIB = False


@dataclass
class TestResult:
    """Result of a test suite"""
    name: str
    passed: int
    failed: int
    total: int
    duration_seconds: float
    details: Optional[str] = None
    
    @property
    def success(self) -> bool:
        return self.failed == 0
    
    def to_dict(self) -> Dict:
        return asdict(self)


class EngineValidator:
    """Main validation orchestrator"""
    
    def __init__(self, engine_path: str, verbose: bool = False):
        self.engine_path = Path(engine_path)
        self.verbose = verbose
        self.results: List[TestResult] = []
        
        if not self.engine_path.exists():
            raise FileNotFoundError(f"Engine not found: {engine_path}")
    
    def run_uci_command(self, command: str, timeout: int = 30) -> Tuple[str, str]:
        """
        Run a UCI command and return stdout, stderr
        """
        try:
            process = subprocess.Popen(
                [str(self.engine_path)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True
            )
            
            stdout, stderr = process.communicate(input=command + "\nquit\n", timeout=timeout)
            return stdout, stderr
        except subprocess.TimeoutExpired:
            process.kill()
            return "", "TIMEOUT"
        except Exception as e:
            return "", str(e)
    
    def test_perft(self) -> TestResult:
        """Run perft validation tests"""
        start_time = time.time()
        
        # Known perft results for starting position
        perft_tests = [
            ("startpos", 1, 20),
            ("startpos", 2, 400),
            ("startpos", 3, 8902),
            ("startpos", 4, 197281),
            ("startpos", 5, 4865609),
        ]
        
        passed = 0
        failed = 0
        details = []
        
        for pos, depth, expected_nodes in perft_tests:
            command = f"position {pos}\nperft {depth}"
            stdout, stderr = self.run_uci_command(command)
            
            # Parse node count from output
            nodes = None
            for line in stdout.split('\n'):
                if "nodes explored" in line.lower():
                    try:
                        nodes = int(line.split()[0])
                        break
                    except (ValueError, IndexError):
                        pass
            
            if nodes == expected_nodes:
                passed += 1
                if self.verbose:
                    print(f"  ✓ Perft depth {depth}: {nodes} nodes")
            else:
                failed += 1
                msg = f"  ✗ Perft depth {depth}: expected {expected_nodes}, got {nodes}"
                details.append(msg)
                print(msg)
        
        duration = time.time() - start_time
        return TestResult(
            name="Perft Validation",
            passed=passed,
            failed=failed,
            total=len(perft_tests),
            duration_seconds=duration,
            details="\n".join(details) if details else None
        )
    
    def test_perft_long(self) -> TestResult:
        """Run comprehensive perft test using 'lambergar perft' command"""
        start_time = time.time()
        
        print("  Running comprehensive perft test (this may take a while)...")
        
        # Run perft as command-line argument
        try:
            process = subprocess.Popen(
                [str(self.engine_path), "perft"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True
            )
            stdout, stderr = process.communicate(timeout=600)  # 10 minute timeout
        except subprocess.TimeoutExpired:
            process.kill()
            return TestResult(
                name="Perft Long",
                passed=0,
                failed=1,
                total=1,
                duration_seconds=time.time() - start_time,
                details="Timeout after 10 minutes"
            )
        except Exception as e:
            return TestResult(
                name="Perft Long",
                passed=0,
                failed=1,
                total=1,
                duration_seconds=time.time() - start_time,
                details=f"Error: {str(e)}"
            )
        
        # Check if perft completed successfully
        # Look for completion indicators in output (check both stdout and stderr)
        # Note: The engine outputs perft results to stderr
        combined_output = stdout + stderr
        success = False
        
        # Debug: Print what we received (first 500 chars)
        if self.verbose:
            print(f"  Debug - stdout length: {len(stdout)}")
            print(f"  Debug - stderr length: {len(stderr)}")
            print(f"  Debug - output preview: {combined_output[:500]}")
        
        if "perft passed" in combined_output.lower() or "nodes explored" in combined_output.lower():
            success = True
        
        duration = time.time() - start_time
        
        if success:
            print(f"  ✓ Perft long completed successfully")
            if self.verbose:
                print(f"  Full output:\n{combined_output}")
            return TestResult(
                name="Perft Long",
                passed=1,
                failed=0,
                total=1,
                duration_seconds=duration,
                details=None
            )
        else:
            print(f"  ✗ Perft long failed or produced unexpected output")
            # Always show some output when it fails to help debug
            print(f"  Stdout length: {len(stdout)}, Stderr length: {len(stderr)}")
            if len(stdout) > 0:
                print(f"  First 200 chars of stdout: {stdout[:200]}")
            if len(stderr) > 0:
                print(f"  First 200 chars of stderr: {stderr[:200]}")
            return TestResult(
                name="Perft Long",
                passed=0,
                failed=1,
                total=1,
                duration_seconds=duration,
                details="Unexpected output or failure"
            )
    
    def test_bench(self) -> TestResult:
        """Run benchmark and verify node count for both NNUE and HCE"""
        start_time = time.time()
        
        # Expected node counts
        EXPECTED_BENCH_NODES = 5648302  # bench (NNUE enabled)
        EXPECTED_BENCHHCE_NODES = 6472023  # benchhce (HCE mode)
        
        passed = 0
        failed = 0
        details = []
        
        # Test 1: bench (NNUE)
        try:
            process = subprocess.Popen(
                [str(self.engine_path), "bench"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True
            )
            stdout, stderr = process.communicate(timeout=120)
        except subprocess.TimeoutExpired:
            process.kill()
            stdout, stderr = "", "TIMEOUT"
        except Exception as e:
            stdout, stderr = "", str(e)
        
        # Parse node count from bench output
        nodes_bench = None
        for line in stdout.split('\n'):
            line = line.strip()
            if "nodes" in line.lower() and "nps" in line.lower():
                try:
                    parts = line.split()
                    for i, part in enumerate(parts):
                        if part.lower() == "nodes" and i > 0:
                            nodes_bench = int(parts[i-1].replace(',', ''))
                            break
                    if nodes_bench:
                        break
                except (ValueError, IndexError):
                    pass
        
        if nodes_bench == EXPECTED_BENCH_NODES:
            passed += 1
            if self.verbose:
                print(f"  ✓ Bench (NNUE) nodes: {nodes_bench}")
        else:
            failed += 1
            msg = f"Bench (NNUE): expected {EXPECTED_BENCH_NODES}, got {nodes_bench}"
            details.append(msg)
            print(f"  ✗ {msg}")
        
        # Test 2: benchhce (HCE)
        try:
            process = subprocess.Popen(
                [str(self.engine_path), "benchhce"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True
            )
            stdout, stderr = process.communicate(timeout=120)
        except subprocess.TimeoutExpired:
            process.kill()
            stdout, stderr = "", "TIMEOUT"
        except Exception as e:
            stdout, stderr = "", str(e)
        
        # Parse node count from benchhce output
        nodes_benchhce = None
        for line in stdout.split('\n'):
            line = line.strip()
            if "nodes" in line.lower() and "nps" in line.lower():
                try:
                    parts = line.split()
                    for i, part in enumerate(parts):
                        if part.lower() == "nodes" and i > 0:
                            nodes_benchhce = int(parts[i-1].replace(',', ''))
                            break
                    if nodes_benchhce:
                        break
                except (ValueError, IndexError):
                    pass
        
        if nodes_benchhce == EXPECTED_BENCHHCE_NODES:
            passed += 1
            if self.verbose:
                print(f"  ✓ BenchHCE nodes: {nodes_benchhce}")
        else:
            failed += 1
            msg = f"BenchHCE: expected {EXPECTED_BENCHHCE_NODES}, got {nodes_benchhce}"
            details.append(msg)
            print(f"  ✗ {msg}")
        
        duration = time.time() - start_time
        return TestResult(
            name="Benchmark",
            passed=passed,
            failed=failed,
            total=2,  # Now testing both bench and benchhce
            duration_seconds=duration,
            details="\n".join(details) if details else None
        )
    
    def test_eval_consistency(self) -> TestResult:
        """Test evaluation consistency for both NNUE and HCE"""
        start_time = time.time()
        
        test_fens = [
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
            "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
            "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        ]
        
        modes = [("NNUE", "true"), ("HCE", "false")]
        
        passed = 0
        failed = 0
        details = []
        total_checks = 0
        
        for mode_name, mode_val in modes:
            # Set evaluation mode
            self.run_uci_command(f"setoption name UseNNUE value {mode_val}")
            
            for fen in test_fens:
                total_checks += 1
                
                # Get eval twice to check consistency
                command1 = f"position fen {fen}\neval"
                stdout1, _ = self.run_uci_command(command1)
                
                command2 = f"position fen {fen}\neval"
                stdout2, _ = self.run_uci_command(command2)
                
                # Extract eval scores
                eval1 = None
                eval2 = None
                
                for line in stdout1.split('\n'):
                    if "from white's perspective" in line.lower():
                        try:
                            eval1 = int(line.split()[0])
                            break
                        except (ValueError, IndexError):
                            pass
                
                for line in stdout2.split('\n'):
                    if "from white's perspective" in line.lower():
                        try:
                            eval2 = int(line.split()[0])
                            break
                        except (ValueError, IndexError):
                            pass
                
                if eval1 is not None and eval1 == eval2:
                    passed += 1
                    if self.verbose:
                        print(f"  ✓ {mode_name} Eval consistent: {eval1}")
                else:
                    failed += 1
                    msg = f"  ✗ {mode_name} Eval inconsistent: {eval1} vs {eval2} for FEN: {fen[:50]}..."
                    details.append(msg)
                    print(msg)
        
        # Restore default (NNUE)
        self.run_uci_command("setoption name UseNNUE value true")
        
        duration = time.time() - start_time
        return TestResult(
            name="Evaluation Consistency",
            passed=passed,
            failed=failed,
            total=total_checks,
            duration_seconds=duration,
            details="\n".join(details) if details else None
        )
    
    def test_tactics(self, suite_file: str = "tests/suites/wac_sample.epd", depth: int = 10) -> TestResult:
        """Run tactical test suite (e.g., WAC)"""
        start_time = time.time()
        suite_path = Path(suite_file)
        
        if not suite_path.exists():
            return TestResult(
                name="Tactical Suite",
                passed=0,
                failed=1,
                total=1,
                duration_seconds=0.0,
                details=f"Suite file not found: {suite_file}"
            )
            
        print(f"  Running tactical suite: {suite_path.name} (depth: {depth})...")
        
        passed = 0
        failed = 0
        details = []
        total_positions = 0
        
        with open(suite_path, 'r') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                
                total_positions += 1
                
                # Parse EPD
                # Use python-chess if available for robust parsing
                best_moves_uci = []
                pos_id = "Unknown"
                
                if HAS_CHESS_LIB:
                    try:
                        board = chess.Board()
                        ops = board.set_epd(line)
                        
                        # Get FEN from board
                        fen = board.fen()
                        
                        # Get best moves
                        if "bm" in ops:
                            best_moves_uci = [m.uci() for m in ops["bm"]]
                        
                        # Get ID
                        if "id" in ops:
                            pos_id = ops["id"]
                            
                    except Exception as e:
                        if self.verbose:
                            print(f"  Warning: Failed to parse EPD line with python-chess: {e}")
                        # Fallback to manual parsing
                        parts = line.split(' bm ')
                        if len(parts) >= 2:
                            fen = parts[0].strip()
                            # Clean up FEN if it has other ops before bm
                            if ';' in fen:
                                fen = fen.split(';')[0].strip()
                                # Remove opcode if present at end of FEN (heuristic)
                                fen_parts = fen.split()
                                if len(fen_parts) > 6: # Standard FEN has 6 fields
                                    fen = " ".join(fen_parts[:6])
                            
                            rest = parts[1]
                            bm_part = rest.split(';')[0].strip()
                            best_moves_uci = [m.strip() for m in bm_part.split()]
                            
                            if 'id "' in rest:
                                pos_id = rest.split('id "')[1].split('"')[0]
                        else:
                            continue
                else:
                    # Manual parsing fallback
                    parts = line.split(' bm ')
                    if len(parts) < 2:
                        continue
                        
                    fen = parts[0].strip()
                    # Clean up FEN if it has other ops before bm
                    if ';' in fen:
                        fen = fen.split(';')[0].strip()
                        # Remove opcode if present at end of FEN (heuristic)
                        fen_parts = fen.split()
                        if len(fen_parts) > 6:
                            fen = " ".join(fen_parts[:6])
                            
                    rest = parts[1]
                    bm_part = rest.split(';')[0].strip()
                    best_moves_uci = [m.strip() for m in bm_part.split()]
                    
                    if 'id "' in rest:
                        pos_id = rest.split('id "')[1].split('"')[0]
                
                if not best_moves_uci:
                    continue
                
                # Run engine
                command = f"position fen {fen}\ngo depth {depth}"
                # Use a generous timeout since depth search time varies
                stdout, _ = self.run_uci_command(command, timeout=60)
                
                # Get engine move
                engine_move = None
                for out_line in stdout.split('\n'):
                    if out_line.startswith('bestmove'):
                        engine_move = out_line.split()[1]
                        break
                
                # Check if engine move matches any of the best moves
                match = False
                if engine_move in best_moves_uci:
                    match = True
                
                if match:
                    passed += 1
                    if self.verbose:
                        print(f"  ✓ {pos_id}: Found {engine_move}")
                else:
                    failed += 1
                    msg = f"  ✗ {pos_id}: Expected {best_moves_uci}, got {engine_move}"
                    details.append(msg)
                    if self.verbose:
                        print(msg)
        
        duration = time.time() - start_time
        score_percent = (passed / total_positions) * 100 if total_positions > 0 else 0
        
        summary = f"Score: {passed}/{total_positions} ({score_percent:.1f}%)"
        print(f"  Result: {summary}")
        
        if details:
            summary += "\n\nFailures:\n" + "\n".join(details[:10])
            if len(details) > 10:
                summary += f"\n...and {len(details)-10} more"
        
        return TestResult(
            name=f"Tactics ({suite_path.name})",
            passed=passed,
            failed=failed,
            total=total_positions,
            duration_seconds=duration,
            details=summary
        )

    def test_uci_compliance(self) -> TestResult:
        """Run UCI compliance test"""
        if not HAS_COMPLIANCE:
            return TestResult(
                name="UCI Compliance",
                passed=0,
                failed=1,
                total=1,
                duration_seconds=0.0,
                details="uci_compliance module not found"
            )
        
        start_time = time.time()
        
        print("  Running UCI compliance test (40 steps)...")
        
        tester = ComplianceTester(str(self.engine_path), verbose=self.verbose)
        
        try:
            success = tester.run_compliance_tests()
            duration = time.time() - start_time
            
            passed_count = sum(1 for r in tester.results if r.passed)
            failed_count = sum(1 for r in tester.results if not r.passed)
            
            return TestResult(
                name="UCI Compliance",
                passed=passed_count,
                failed=failed_count,
                total=len(tester.results),
                duration_seconds=duration,
                details=None if success else "Some compliance checks failed"
            )
        except Exception as e:
            return TestResult(
                name="UCI Compliance",
                passed=0,
                failed=1,
                total=1,
                duration_seconds=time.time() - start_time,
                details=f"Error: {str(e)}"
            )
        finally:
            tester.cleanup()
    
    def run_all_tests(self) -> bool:
        """Run all validation tests"""
        print("\n=== Lambergar Engine Validation ===\n")
        print(f"Engine: {self.engine_path}\n")
        
        # Run test suites
        self.results.append(self.test_perft())
        self.results.append(self.test_bench())
        self.results.append(self.test_eval_consistency())
        if HAS_COMPLIANCE:
            self.results.append(self.test_uci_compliance())
        
        # Print summary
        print("\n=== Test Summary ===\n")
        total_passed = 0
        total_failed = 0
        all_success = True
        
        for result in self.results:
            status = "✓ PASS" if result.success else "✗ FAIL"
            print(f"{result.name:30s} {status:10s} ({result.passed}/{result.total}) [{result.duration_seconds:.2f}s]")
            total_passed += result.passed
            total_failed += result.failed
            all_success = all_success and result.success
        
        print(f"\n{'Total':30s} {'✓ PASS' if all_success else '✗ FAIL':10s} ({total_passed}/{total_passed + total_failed})")
        
        return all_success
    
    def export_results(self, output_file: str):
        """Export results to JSON"""
        data = {
            "engine": str(self.engine_path),
            "timestamp": time.time(),
            "results": [r.to_dict() for r in self.results],
            "summary": {
                "total_passed": sum(r.passed for r in self.results),
                "total_failed": sum(r.failed for r in self.results),
                "all_success": all(r.success for r in self.results)
            }
        }
        
        with open(output_file, 'w') as f:
            json.dump(data, f, indent=2)
        
        print(f"\nResults exported to: {output_file}")


def main():
    parser = argparse.ArgumentParser(description="Validate Lambergar chess engine")
    parser.add_argument("--engine", required=True, help="Path to engine executable")
    parser.add_argument("--suite", choices=["perft", "perft-long", "bench", "eval", "compliance", "tactics", "all"], default="all",
                        help="Test suite to run")
    parser.add_argument("--epd", help="Path to EPD file for tactics test", default="tests/suites/wac_sample.epd")
    parser.add_argument("--depth", type=int, default=10, help="Search depth for tactics")
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose output")
    parser.add_argument("--output", "-o", help="Output JSON file for results")
    
    args = parser.parse_args()
    
    try:
        validator = EngineValidator(args.engine, verbose=args.verbose)
        
        if args.suite == "all":
            success = validator.run_all_tests()
        elif args.suite == "perft":
            result = validator.test_perft()
            validator.results.append(result)
            success = result.success
        elif args.suite == "perft-long":
            result = validator.test_perft_long()
            validator.results.append(result)
            success = result.success
        elif args.suite == "bench":
            result = validator.test_bench()
            validator.results.append(result)
            success = result.success
        elif args.suite == "eval":
            result = validator.test_eval_consistency()
            validator.results.append(result)
            success = result.success
        elif args.suite == "compliance":
            result = validator.test_uci_compliance()
            validator.results.append(result)
            success = result.success
        elif args.suite == "tactics":
            result = validator.test_tactics(args.epd, args.depth)
            validator.results.append(result)
            success = result.success
        
        if args.output:
            validator.export_results(args.output)
        
        sys.exit(0 if success else 1)
        
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
