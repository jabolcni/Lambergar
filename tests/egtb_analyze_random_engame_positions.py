import chess
import chess.syzygy
import os

def analyze_epd_file(filename, syzygy_path=None):
    """Analyze positions from an EPD file"""
    tablebase_available = False
    if syzygy_path and os.path.exists(syzygy_path):
        tablebase = chess.syzygy.Tablebase()
        tablebase.add_directory(syzygy_path)
        tablebase_available = True
    
    with open(filename, 'r') as f:
        positions = f.readlines()
    
    print(f"Analyzing {len(positions)} positions from {filename}")
    print("-" * 60)
    
    for i, epd_line in enumerate(positions, 1):
        try:
            # Parse EPD (handle both basic and enhanced EPD)
            epd_parts = epd_line.strip().split(';')
            board_epd = epd_parts[0]
            
            board = chess.Board()
            board.set_epd(board_epd)
            
            print(f"Position {i}:")
            print(f"  FEN: {board.fen()}")
            print(f"  Pieces: {len(board.piece_map())}")
            print(f"  Turn: {'White' if board.turn else 'Black'}")
            
            # Extract best move from EPD
            for part in epd_parts:
                if part.strip().startswith('bm'):
                    bm_part = part.strip()
                    print(f"  Best move: {bm_part}")
            
            # Get tablebase info if available
            if tablebase_available and len(board.piece_map()) <= 5:
                try:
                    wdl = tablebase.probe_wdl(board)
                    dtz = tablebase.probe_dtz(board)
                    
                    # Convert WDL to readable format
                    wdl_map = {-2: "Loss", -1: "Loss", 0: "Draw", 1: "Win", 2: "Win"}
                    result = wdl_map.get(wdl, "Unknown")
                    
                    print(f"  Tablebase: {result} (WDL: {wdl}, DTZ: {dtz})")
                except:
                    print(f"  Tablebase: Not available for this position")
            
            print()
            
        except Exception as e:
            print(f"Error analyzing position {i}: {e}")
            print()

def generate_more_positions(num_additional, output_file, syzygy_path, max_pieces=5):
    """Generate additional positions and append to existing file"""
    generator = EndgamePositionGenerator(syzygy_path, max_pieces)
    new_positions = generator.generate_positions(num_additional)
    
    # Append to existing file
    with open(output_file, 'a') as f:
        for epd in new_positions:
            f.write(epd + '\n')
    
    print(f"Added {len(new_positions)} new positions to {output_file}")

# Example usage:
if __name__ == "__main__":
    SYZYGY_PATH = r"C:/Users/janezp/Downloads/syzygy"
    EPD_FILE = "endgame_positions.epd"
    
    # Analyze existing positions
    analyze_epd_file(EPD_FILE, SYZYGY_PATH)
    
    # Generate more positions (uncomment if needed)
    # generate_more_positions(50, EPD_FILE, SYZYGY_PATH)