import chess
import chess.syzygy
import random
import os

class EndgamePositionGenerator:
    def __init__(self, syzygy_path, max_pieces=5):
        self.syzygy_path = syzygy_path
        self.max_pieces = max_pieces
        
        # Initialize tablebase
        self.tablebase = chess.syzygy.Tablebase()
        if os.path.exists(syzygy_path):
            self.tablebase.add_directory(syzygy_path)
            self.tablebase_available = True
        else:
            print(f"Warning: Syzygy path {syzygy_path} does not exist!")
            print("Tablebase checking will be disabled.")
            self.tablebase_available = False
        
    def generate_random_position(self):
        """Generate a random position with specified number of pieces"""
        board = chess.Board()
        board.clear()
        
        # Choose random pieces (2-5 pieces total, including both kings)
        num_pieces = random.randint(2, self.max_pieces)
        
        # Always include both kings
        pieces = ['K', 'k']
        
        # Add random pieces (excluding kings)
        piece_types = ['Q', 'R', 'B', 'N', 'P', 'q', 'r', 'b', 'n', 'p']
        for _ in range(num_pieces - 2):
            pieces.append(random.choice(piece_types))
        
        # Assign pieces to random squares
        squares = list(chess.SQUARES)
        random.shuffle(squares)
        
        for piece_char in pieces:
            if not squares:
                break
            square = squares.pop()
            piece = chess.Piece.from_symbol(piece_char)
            board.set_piece_at(square, piece)
        
        # Set turn randomly
        board.turn = random.choice([chess.WHITE, chess.BLACK])
        
        # Set castling rights to none
        board.castling_rights = chess.BB_EMPTY
        
        # Set en passant to none
        board.ep_square = None
        
        # Set halfmove clock and fullmove number
        board.halfmove_clock = 0
        board.fullmove_number = 1
        
        return board
    
    def is_legal_position(self, board):
        """Check if the position is completely legal and could be reached in a real game"""
        try:
            piece_map = board.piece_map()
            
            # Must have exactly one white king and one black king
            white_kings = sum(1 for piece in piece_map.values() if piece.symbol() == 'K')
            black_kings = sum(1 for piece in piece_map.values() if piece.symbol() == 'k')
            if white_kings != 1 or black_kings != 1:
                return False
            
            # Kings cannot be adjacent
            white_king = board.king(chess.WHITE)
            black_king = board.king(chess.BLACK)
            if chess.square_distance(white_king, black_king) <= 1:
                return False
            
            # Cannot have pawns on first or eighth rank
            for square, piece in piece_map.items():
                if piece.piece_type == chess.PAWN:
                    rank = chess.square_rank(square)
                    if rank == 0 or rank == 7:  # First or eighth rank
                        return False
            
            # Cannot be in check (since it's our turn to move)
            if board.is_check():
                return False
            
            # Check for impossible piece promotions
            # Count original pieces vs current pieces
            white_pawns = sum(1 for piece in piece_map.values() if piece.color == chess.WHITE and piece.piece_type == chess.PAWN)
            black_pawns = sum(1 for piece in piece_map.values() if piece.color == chess.BLACK and piece.piece_type == chess.PAWN)
            
            white_queens = sum(1 for piece in piece_map.values() if piece.color == chess.WHITE and piece.piece_type == chess.QUEEN)
            black_queens = sum(1 for piece in piece_map.values() if piece.color == chess.BLACK and piece.piece_type == chess.QUEEN)
            
            white_rooks = sum(1 for piece in piece_map.values() if piece.color == chess.WHITE and piece.piece_type == chess.ROOK)
            black_rooks = sum(1 for piece in piece_map.values() if piece.color == chess.BLACK and piece.piece_type == chess.ROOK)
            
            white_bishops = sum(1 for piece in piece_map.values() if piece.color == chess.WHITE and piece.piece_type == chess.BISHOP)
            black_bishops = sum(1 for piece in piece_map.values() if piece.color == chess.BLACK and piece.piece_type == chess.BISHOP)
            
            white_knights = sum(1 for piece in piece_map.values() if piece.color == chess.WHITE and piece.piece_type == chess.KNIGHT)
            black_knights = sum(1 for piece in piece_map.values() if piece.color == chess.BLACK and piece.piece_type == chess.KNIGHT)
            
            # Each side starts with 8 pawns, 2 rooks, 2 bishops, 2 knights, 1 queen
            # Check for impossible promotions (this is a simplified check)
            if white_pawns > 8 or black_pawns > 8:
                return False
            if white_rooks > 10 or black_rooks > 10:  # 2 original + max 8 from pawns
                return False
            if white_bishops > 10 or black_bishops > 10:
                return False
            if white_knights > 10 or black_knights > 10:
                return False
            if white_queens > 9 or black_queens > 9:  # 1 original + max 8 from pawns
                return False
            
            # Try to validate the FEN - this catches many illegal positions
            fen = board.fen()
            test_board = chess.Board(fen)
            
            # Additional validation: check if position passes basic chess.Board validation
            # This includes checking for impossible piece placements that chess.Board can detect
            if not test_board.is_valid():
                return False
            
            return True
            
        except Exception:
            return False
    
    def is_in_tablebase(self, board):
        """Check if the position is in the Syzygy tablebase"""
        if not self.tablebase_available:
            return False
            
        try:
            # Check if the position has the right number of pieces for tablebase
            piece_count = len(board.piece_map())
            if piece_count > 5:  # Assuming 5-piece tablebases
                return False
            
            # Try to probe the tablebase
            wdl = self.tablebase.probe_wdl(board)
            # dtz = self.tablebase.probe_dtz(board)  # We don't need DTZ for the check

            # if wdl == -2:  
            #     return False
            # if wdl == 2:  
            #     return False
            # if wdl == 0:  
            #     return False
            
            # If we get here without exception, it's in tablebase
            return True
        except chess.syzygy.MissingTableError:
            return False
        except Exception:
            return False
    
    def get_tablebase_info(self, board):
        """Get tablebase information for a position"""
        if not self.tablebase_available:
            return None, None, None
            
        try:
            wdl = self.tablebase.probe_wdl(board)
            dtz = self.tablebase.probe_dtz(board)
            
            # Convert WDL to human-readable form
            wdl_map = {-2: "Loss", -1: "Loss", 0: "Draw", 1: "Win", 2: "Win"}
            result_str = wdl_map.get(wdl, "Unknown")
            
            return wdl, dtz, result_str
        except Exception:
            return None, None, None
    
    def generate_positions(self, num_positions):
        """Generate legal positions that are in the tablebase"""
        positions = []
        attempts = 0
        max_attempts = num_positions * 10000  # Much higher to account for strict legality
        
        print(f"Generating {num_positions} legal endgame positions...")
        
        while len(positions) < num_positions and attempts < max_attempts:
            attempts += 1
            board = self.generate_random_position()
            
            # Check basic legality first
            if not self.is_legal_position(board):
                continue
            
            # Check if position is in tablebase
            if not self.is_in_tablebase(board):
                continue
            
            # Get tablebase information
            wdl, dtz, result_str = self.get_tablebase_info(board)
            
            if wdl is not None and dtz is not None:
                # Create enhanced EPD with metadata
                epd = board.epd()
                enhanced_epd = f"{epd}; TB_WDL {wdl}; TB_DTZ {dtz}; TB_RESULT \"{result_str}\";"
                positions.append(enhanced_epd)
                
                # Progress indicator
                if len(positions) % 10 == 0:
                    print(f"Generated {len(positions)}/{num_positions} positions...")
        
        if len(positions) < num_positions:
            print(f"Warning: Only generated {len(positions)} out of {num_positions} requested positions after {attempts} attempts")
        
        return positions
    
    def save_to_epd(self, positions, filename):
        """Save positions to an EPD file"""
        with open(filename, 'w') as f:
            for epd in positions:
                f.write(epd + '\n')
        
        print(f"Saved {len(positions)} positions to {filename}")

def main():
    # Configuration
    SYZYGY_PATH = r"C:/Users/janezp/Downloads/syzygy"
    OUTPUT_FILE = "endgame_positions.epd"
    NUM_POSITIONS = 1000
    MAX_PIECES = 5
    
    # Create generator
    generator = EndgamePositionGenerator(SYZYGY_PATH, MAX_PIECES)
    
    # Generate positions
    print(f"Generating {NUM_POSITIONS} legal endgame positions with {MAX_PIECES} or fewer pieces...")
    positions = generator.generate_positions(NUM_POSITIONS)
    
    # Save to file
    generator.save_to_epd(positions, OUTPUT_FILE)
    
    # Print summary
    print(f"Successfully generated {len(positions)} positions")
    print(f"Positions saved to: {OUTPUT_FILE}")

if __name__ == "__main__":
    main()