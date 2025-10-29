def sfen_to_pgn_chess960(input_file, output_file):
    """
    Convert SFEN to PGN for Chess960 - build game from initial position
    """
    
    with open(input_file, 'r') as f:
        lines = f.readlines()
    
    if not lines:
        return
    
    # Get the initial position from first line
    first_line = lines[0].strip()
    parts = first_line.split(';')
    initial_fen = parts[0].strip()
    
    # Extract all moves and evaluations
    moves_with_eval = []
    
    for line in lines:
        line = line.strip()
        if not line:
            continue
            
        parts = line.split(';')
        metadata = {}
        for part in parts[1:]:
            if ' ' in part:
                key, value = part.strip().split(' ', 1)
                metadata[key] = value
        
        actual_move = metadata.get('acm', '')
        score = metadata.get('ce', '')
        
        if actual_move:
            moves_with_eval.append((actual_move, score))
    
    # Create PGN with initial FEN for Chess960
    pgn = '[Event "Chess960 Analysis"]\n'
    pgn += '[Site "Conversion"]\n'
    pgn += '[Date "2024.01.01"]\n'
    pgn += '[Round "1"]\n'
    pgn += '[White "White"]\n'
    pgn += '[Black "Black"]\n'
    pgn += '[Result "*"]\n'
    pgn += f'[FEN "{initial_fen}"]\n'
    pgn += '[SetUp "1"]\n'
    pgn += '[Variant "Chess960"]\n\n'
    
    # Add moves with evaluations
    move_text = ""
    move_number = 1
    
    for i in range(0, len(moves_with_eval), 2):
        # White move
        white_move, white_eval = moves_with_eval[i]
        
        # Black move (if exists)
        if i + 1 < len(moves_with_eval):
            black_move, black_eval = moves_with_eval[i + 1]
        else:
            black_move, black_eval = "", ""
        
        move_text += f'{move_number}. {white_move}'
        if white_eval:
            move_text += f' {{%eval {white_eval}}}'
        
        if black_move:
            move_text += f' {black_move}'
            if black_eval:
                move_text += f' {{%eval {black_eval}}}'
        
        move_text += ' '
        move_number += 1
    
    pgn += move_text.strip()
    pgn += ' *'
    
    with open(output_file, 'w') as f:
        f.write(pgn)

def sfen_to_pgn_chess960_with_san(input_file, output_file):
    """
    Convert using python-chess library for proper SAN conversion in Chess960
    """
    try:
        import chess
        import chess.pgn
        
        with open(input_file, 'r') as f:
            lines = f.readlines()
        
        if not lines:
            return
        
        # Get the initial position from first line
        first_line = lines[0].strip()
        parts = first_line.split(';')
        initial_fen = parts[0].strip()
        
        # Create a new game with Chess960 starting position
        board = chess.Board(initial_fen, chess960=True)
        game = chess.pgn.Game.from_board(board)
        
        # Set headers
        game.headers["Event"] = "Chess960 Analysis"
        game.headers["Site"] = "Conversion"
        game.headers["Date"] = "2024.01.01"
        game.headers["Round"] = "1"
        game.headers["White"] = "White"
        game.headers["Black"] = "Black"
        game.headers["Result"] = "*"
        game.headers["Variant"] = "Chess960"
        game.headers["FEN"] = initial_fen
        game.headers["SetUp"] = "1"
        
        node = game
        
        for i, line in enumerate(lines):
            line = line.strip()
            if not line:
                continue
                
            parts = line.split(';')
            metadata = {}
            for part in parts[1:]:
                if ' ' in part:
                    key, value = part.strip().split(' ', 1)
                    metadata[key] = value
            
            actual_move = metadata.get('acm', '')
            score = metadata.get('ce', '')
            
            if actual_move:
                # Convert UCI to move object
                move = chess.Move.from_uci(actual_move)
                
                # Verify the move is legal in the current position
                if move in board.legal_moves:
                    # Add comment with evaluation
                    comment = f"%eval {score}"
                    
                    # Add the move to the game
                    node = node.add_variation(move, comment=comment)
                    board.push(move)
        
        # Write the PGN
        with open(output_file, 'w') as f:
            exporter = chess.pgn.FileExporter(f)
            game.accept(exporter)
            
    except ImportError:
        print("python-chess library not available, using simple conversion")
        sfen_to_pgn_chess960(input_file, output_file)

# Simple version that converts UCI to SAN-like notation for Chess960
def convert_uci_to_san_960(uci_move, fen):
    """
    Convert UCI move to SAN-like notation for Chess960
    This is a simplified version - for full SAN you'd need chess library
    """
    if len(uci_move) < 4:
        return uci_move
    
    from_square = uci_move[0:2]
    to_square = uci_move[2:4]
    
    # For pawn moves or simple piece moves
    if uci_move[0].islower():  # Pawn move
        if from_square[0] == to_square[0]:  # Same file - simple push
            return to_square
        else:  # Capture
            return f"{from_square[0]}x{to_square}"
    else:  # Piece move
        piece = uci_move[0]
        return f"{piece}{to_square}"

def sfen_to_pgn_chess960_readable(input_file, output_file):
    """
    Convert SFEN to PGN for Chess960 with more readable moves
    """
    
    with open(input_file, 'r') as f:
        lines = f.readlines()
    
    if not lines:
        return
    
    # Get the initial position from first line
    first_line = lines[0].strip()
    parts = first_line.split(';')
    initial_fen = parts[0].strip()
    
    # Extract all moves and evaluations
    moves_with_eval = []
    
    for line in lines:
        line = line.strip()
        if not line:
            continue
            
        parts = line.split(';')
        metadata = {}
        for part in parts[1:]:
            if ' ' in part:
                key, value = part.strip().split(' ', 1)
                metadata[key] = value
        
        actual_move = metadata.get('acm', '')
        score = metadata.get('ce', '')
        
        if actual_move:
            moves_with_eval.append((actual_move, score))
    
    # Create PGN with initial FEN for Chess960
    pgn = '[Event "Chess960 Analysis"]\n'
    pgn += '[Site "Conversion"]\n'
    pgn += '[Date "2024.01.01"]\n'
    pgn += '[Round "1"]\n'
    pgn += '[White "White"]\n'
    pgn += '[Black "Black"]\n'
    pgn += '[Result "*"]\n'
    pgn += f'[FEN "{initial_fen}"]\n'
    pgn += '[SetUp "1"]\n'
    pgn += '[Variant "Chess960"]\n\n'
    
    # Add moves with evaluations
    move_text = ""
    move_number = 1
    
    for i in range(0, len(moves_with_eval), 2):
        # White move
        white_move, white_eval = moves_with_eval[i]
        white_san = convert_uci_to_san_960(white_move, initial_fen)
        
        # Black move (if exists)
        if i + 1 < len(moves_with_eval):
            black_move, black_eval = moves_with_eval[i + 1]
            black_san = convert_uci_to_san_960(black_move, initial_fen)
        else:
            black_move, black_eval, black_san = "", "", ""
        
        move_text += f'{move_number}. {white_san}'
        if white_eval:
            move_text += f' {{%eval {white_eval}}}'
        
        if black_san:
            move_text += f' {black_san}'
            if black_eval:
                move_text += f' {{%eval {black_eval}}}'
        
        move_text += ' '
        move_number += 1
    
    pgn += move_text.strip()
    pgn += ' *'
    
    with open(output_file, 'w') as f:
        f.write(pgn)

# Usage
if __name__ == "__main__":
    input_filename = "dbg.sfen"
    output_filename = "chess960_game.pgn"
    
    print("Converting SFEN to Chess960 PGN...")
    
    # Try the advanced version first, fall back to simple version
    try:
        sfen_to_pgn_chess960_with_san(input_filename, output_filename)
        print("Created PGN using python-chess library")
    except:
        sfen_to_pgn_chess960(input_filename, output_filename)
        print("Created PGN using simple conversion")
    
    print(f"Created {output_filename}")
    
    # Show the PGN header and first few moves
    print("\nPGN content:")
    with open(output_filename, 'r') as f:
        content = f.read()
        print(content[:1000])  # Show first 1000 characters