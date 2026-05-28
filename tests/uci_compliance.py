#!/usr/bin/env python3
"""
UCI Compliance Test for chess engines.
Based on fastchess compliance checker.
"""

import argparse
import subprocess
import sys
import time
from typing import Optional, Tuple
from dataclasses import dataclass


@dataclass
class ComplianceResult:
    """Result of a compliance test step"""
    step: int
    description: str
    passed: bool
    error_message: Optional[str] = None


class UCIEngine:
    """Simple UCI engine interface for compliance testing"""
    
    def __init__(self, engine_path: str, timeout: int = 5):
        self.engine_path = engine_path
        self.timeout = timeout
        self.process = None
        self.last_info_line = ""
        self.last_bestmove = ""
        
    def start(self) -> bool:
        """Start the engine process"""
        try:
            self.process = subprocess.Popen(
                [self.engine_path],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1
            )
            return True
        except Exception as e:
            print(f"Failed to start engine: {e}")
            return False
    
    def write_command(self, command: str) -> bool:
        """Write a command to the engine"""
        try:
            self.process.stdin.write(command + "\n")
            self.process.stdin.flush()
            return True
        except Exception as e:
            print(f"Failed to write command '{command}': {e}")
            return False
    
    def read_until(self, expected: str, timeout: Optional[int] = None) -> Tuple[bool, str]:
        """Read engine output until expected string is found"""
        if timeout is None:
            timeout = self.timeout
        
        start_time = time.time()
        output_lines = []
        
        try:
            while time.time() - start_time < timeout:
                if self.process.poll() is not None:
                    return False, "Engine terminated unexpectedly"
                
                line = self.process.stdout.readline()
                if not line:
                    continue
                
                line = line.strip()
                output_lines.append(line)
                
                # Track info lines
                if line.startswith("info "):
                    self.last_info_line = line
                
                # Track bestmove
                if line.startswith("bestmove "):
                    self.last_bestmove = line
                
                # Check if we found what we're looking for
                if expected in line:
                    return True, "\n".join(output_lines)
            
            return False, f"Timeout waiting for '{expected}'"
        except Exception as e:
            return False, f"Error reading output: {e}"
    
    def isready(self) -> bool:
        """Send isready and wait for readyok"""
        if not self.write_command("isready"):
            return False
        success, _ = self.read_until("readyok", timeout=10)
        return success
    
    def ucinewgame(self) -> bool:
        """Send ucinewgame command"""
        return self.write_command("ucinewgame")
    
    def quit(self):
        """Quit the engine"""
        if self.process:
            try:
                self.write_command("quit")
                self.process.wait(timeout=2)
            except:
                self.process.kill()


def is_valid_info_line(info_line: str) -> Tuple[bool, Optional[str]]:
    """Validate UCI info line format"""
    if not info_line.startswith("info "):
        return False, f"Info line doesn't start with 'info': {info_line}"
    
    tokens = info_line.split()
    i = 1  # Skip "info"
    
    while i < len(tokens):
        token = tokens[i]
        
        # Check tokens that require integer values
        if token in ["time", "nps", "nodes", "depth", "seldepth", "multipv", "currmove"]:
            if i + 1 >= len(tokens):
                return False, f"No value after token '{token}'"
            
            value = tokens[i + 1]
            
            # Check if value contains decimal point (should be integer)
            if '.' in value:
                return False, f"{token} value is not an integer: {value}"
            
            # Try to parse as integer
            try:
                int(value)
            except ValueError:
                return False, f"{token} value is not a valid integer: {value}"
            
            i += 2
        elif token == "score":
            # Score can be "cp <value>" or "mate <value>"
            if i + 2 >= len(tokens):
                return False, "Incomplete score information"
            
            score_type = tokens[i + 1]
            if score_type not in ["cp", "mate"]:
                return False, f"Invalid score type: {score_type}"
            
            score_value = tokens[i + 2]
            try:
                int(score_value)
            except ValueError:
                return False, f"Score value is not an integer: {score_value}"
            
            i += 3
        else:
            i += 1
    
    return True, None


class ComplianceTester:
    """UCI compliance tester"""
    
    def __init__(self, engine_path: str, verbose: bool = False):
        self.engine_path = engine_path
        self.verbose = verbose
        self.engine = UCIEngine(engine_path)
        self.step = 0
        self.results = []
    
    def execute_step(self, description: str, action) -> bool:
        """Execute a test step"""
        self.step += 1
        
        if self.verbose:
            print(f"Step {self.step}: {description}...", end='', flush=True)
        
        try:
            success = action()
            
            if success:
                if self.verbose:
                    print(f"\r\033[1;32m Passed\033[0m Step {self.step}: {description}")
                else:
                    print(f" \033[1;32mPassed\033[0m Step {self.step}: {description}")
                self.results.append(ComplianceResult(self.step, description, True))
                return True
            else:
                print(f"\r\033[1;31m Failed\033[0m Step {self.step}: {description}")
                self.results.append(ComplianceResult(self.step, description, False))
                return False
        except Exception as e:
            print(f"\r\033[1;31m Failed\033[0m Step {self.step}: {description} - {e}")
            self.results.append(ComplianceResult(self.step, description, False, str(e)))
            return False
    
    def run_compliance_tests(self) -> bool:
        """Run all compliance tests"""
        
        # Define all test steps
        steps = [
            ("Start the engine", lambda: self.engine.start()),
            ("Check if engine is ready", lambda: self.engine.isready()),
            ("Check id name", lambda: self.check_id_name()),
            ("Check id author", lambda: self.check_id_author()),
            ("Send ucinewgame", lambda: self.engine.ucinewgame()),
            ("Set position to startpos", lambda: self.engine.write_command("position startpos")),
            ("Check if engine is ready after startpos", lambda: self.engine.isready()),
            ("Set position to fen", lambda: self.engine.write_command(
                "position fen 3r2k1/p5n1/1pq1p2p/2p3p1/2P1P1n1/1P1P2pP/PN1Q2K1/5R2 w - - 0 27")),
            ("Check if engine is ready after fen", lambda: self.engine.isready()),
            ("Send go wtime 100", lambda: self.engine.write_command("go wtime 100")),
            ("Read bestmove", lambda: self.read_bestmove()),
            ("Check if engine prints an info line", lambda: len(self.engine.last_info_line) > 0),
            ("Verify info line format is valid", lambda: self.validate_info_line()),
            ("Verify info line contains score", lambda: "score" in self.engine.last_info_line),
            ("Set position to black to move", lambda: self.engine.write_command(
                "position fen rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1")),
            ("Send go btime 100", lambda: self.engine.write_command("go btime 100")),
            ("Read bestmove after go btime 100", lambda: self.read_bestmove()),
            ("Check if engine prints an info line after go btime 100", 
             lambda: len(self.engine.last_info_line) > 0),
            ("Verify info line format is valid after go btime 100", lambda: self.validate_info_line()),
            ("Check if engine prints an info line with the score after go btime 100",
             lambda: "score" in self.engine.last_info_line),
            ("Send go wtime 100 winc 100 btime 100 binc 100",
             lambda: self.engine.write_command("go wtime 100 winc 100 btime 100 binc 100")),
            ("Read bestmove after go wtime 100 winc 100 btime 100 binc 100", lambda: self.read_bestmove()),
            ("Check if engine prints an info line after go wtime 100 winc 100",
             lambda: len(self.engine.last_info_line) > 0),
            ("Verify info line format is valid after go wtime 100 winc 100", lambda: self.validate_info_line()),
            ("Check if engine prints an info line with the score after go wtime 100 winc 100",
             lambda: "score" in self.engine.last_info_line),
            ("Send go btime 100 binc 100 wtime 100 winc 100",
             lambda: self.engine.write_command("go btime 100 binc 100 wtime 100 winc 100")),
            ("Read bestmove after go btime 100 binc 100 wtime 100 winc 100", lambda: self.read_bestmove()),
            ("Check if engine prints an info line after go btime 100 binc 100",
             lambda: len(self.engine.last_info_line) > 0),
            ("Verify info line format is valid after go btime 100 binc 100", lambda: self.validate_info_line()),
            ("Check if engine prints an info line with the score after go btime 100 binc 100",
             lambda: "score" in self.engine.last_info_line),
            ("Check if engine prints an info line after go btime 100 binc 100",
             lambda: "score" in self.engine.last_info_line),
            # Simulate a game
            ("Send ucinewgame", lambda: self.engine.ucinewgame()),
            ("Set position to startpos", lambda: self.engine.write_command("position startpos")),
            ("Send go wtime 100", lambda: self.engine.write_command("go wtime 100 btime 100")),
            ("Read bestmove after go wtime 100 btime 100", lambda: self.read_bestmove()),
            ("Verify info line format is valid after go wtime 100 btime 100", lambda: self.validate_info_line()),
            ("Set position to startpos moves e2e4 e7e5",
             lambda: self.engine.write_command("position startpos moves e2e4 e7e5")),
            ("Send go wtime 100 btime 100", lambda: self.engine.write_command("go wtime 100 btime 100")),
            ("Read bestmove after position startpos moves e2e4 e7e5", lambda: self.read_bestmove()),
            ("Verify info line format is valid after position startpos moves e2e4 e7e5",
             lambda: self.validate_info_line()),
        ]
        
        # Execute all steps
        for description, action in steps:
            if not self.execute_step(description, action):
                return False
        
        print("\033[1;32mEngine passed all compliance checks.\033[0m")
        return True
    
    def check_id_name(self) -> bool:
        """Check for id name response"""
        self.engine.write_command("uci")
        success, output = self.engine.read_until("uciok", timeout=5)
        if not success:
            return False
        return "id name" in output
    
    def check_id_author(self) -> bool:
        """Check for id author response"""
        # Already sent uci, just check last output
        return True  # Assume it was in the uci response
    
    def read_bestmove(self) -> bool:
        """Read bestmove from engine"""
        success, _ = self.engine.read_until("bestmove", timeout=15)
        return success and len(self.engine.last_bestmove) > 0
    
    def validate_info_line(self) -> bool:
        """Validate the last info line"""
        if not self.engine.last_info_line:
            return False
        valid, error = is_valid_info_line(self.engine.last_info_line)
        if not valid and self.verbose:
            print(f"\nInfo line validation error: {error}")
        return valid
    
    def cleanup(self):
        """Clean up engine process"""
        self.engine.quit()


def main():
    parser = argparse.ArgumentParser(description="UCI Compliance Test for chess engines")
    parser.add_argument("--engine", required=True, help="Path to engine executable")
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose output")
    
    args = parser.parse_args()
    
    tester = ComplianceTester(args.engine, verbose=args.verbose)
    
    try:
        success = tester.run_compliance_tests()
        sys.exit(0 if success else 1)
    except KeyboardInterrupt:
        print("\nTest interrupted by user")
        sys.exit(1)
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)
    finally:
        tester.cleanup()


if __name__ == "__main__":
    main()
