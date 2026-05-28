import os
import sys
import argparse
from pathlib import Path

def get_positions_count(filepath, entry_size):
    """Calculate the number of positions in a binary file based on entry size."""
    size = os.path.getsize(filepath)
    if size % entry_size != 0:
        return size // entry_size, False
    return size // entry_size, True

def combine_bins(folder_path, output_file, entry_size=40, extension='.bin'):
    """
    Combines all binary files with specified extension in a folder into one.
    Validates that the total number of positions matches the sum of individual files.
    """
    folder = Path(folder_path)
    if not folder.is_dir():
        print(f"Error: {folder_path} is not a directory.")
        return

    # Find all matching files
    bin_files = sorted([f for f in folder.glob(f"*{extension}") if f.is_file()])
    
    if not bin_files:
        print(f"No files with extension '{extension}' found in {folder_path}")
        return

    print(f"--- Combining {len(bin_files)} files from '{folder_path}' ---")
    
    total_positions_expected = 0
    file_stats = []

    # Step 1: Analysis and individual validation
    for file_path in bin_files:
        count, perfect = get_positions_count(file_path, entry_size)
        file_stats.append((file_path, count, perfect))
        total_positions_expected += count
        
        status = "OK" if perfect else f"MISMATCH (extra {os.path.getsize(file_path) % entry_size} bytes)"
        print(f"  {file_path.name:<30} | Positions: {count:>10,} | Status: {status}")

    print("-" * 70)
    print(f"Total expected positions: {total_positions_expected:,}")
    print(f"Total expected size:     {total_positions_expected * entry_size:,} bytes")
    print("-" * 70)

    # Step 2: Combination
    print(f"Writing to {output_file}...")
    try:
        with open(output_file, 'wb') as outfile:
            for file_path, _, _ in file_stats:
                with open(file_path, 'rb') as infile:
                    # Read and write in chunks to handle large files efficiently
                    while True:
                        chunk = infile.read(1024 * 1024)  # 1MB chunks
                        if not chunk:
                            break
                        outfile.write(chunk)
    except Exception as e:
        print(f"An error occurred during merging: {e}")
        return

    # Step 3: Final Validation
    print("\n--- Final Validation ---")
    final_size = os.path.getsize(output_file)
    final_positions, final_perfect = get_positions_count(output_file, entry_size)
    
    print(f"  Expected positions: {total_positions_expected:,}")
    print(f"  Actual positions:   {final_positions:,}")
    print(f"  Perfect alignment:  {'Yes' if final_perfect else 'No'}")
    
    if final_positions == total_positions_expected and final_perfect:
        print("\nSUCCESS: Combined file validated correctly!")
    else:
        print("\nWARNING: Validation failed!")
        if final_positions != total_positions_expected:
            print(f"  Position count mismatch: Expected {total_positions_expected}, got {final_positions}")
        if not final_perfect:
            print(f"  File size is not a multiple of entry size ({entry_size}). Extra bytes: {final_size % entry_size}")

def main():
    parser = argparse.ArgumentParser(description="Combine multiple binary position files into one with validation.")
    parser.add_argument("folder", help="Folder containing the .bin files")
    parser.add_argument("output", help="Output combined file path")
    parser.add_argument("--size", type=int, default=40, help="Entry size in bytes (default: 40 for standard Lambergar .bin)")
    parser.add_argument("--ext", default=".bin", help="File extension to look for (default: .bin)")

    args = parser.parse_args()

    # If the folder contains .binhce files, maybe use 1208?
    # We'll stick to the defaults but allow override.
    
    combine_bins(args.folder, args.output, args.size, args.ext)

if __name__ == "__main__":
    main()
