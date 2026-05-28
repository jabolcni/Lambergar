#!/usr/bin/env python3
"""
Merge multiple .binhce files into a single combined dataset.

Usage:
    python merge_binhce.py output.binhce input1.binhce input2.binhce input3.binhce ...
    python merge_binhce.py output.binhce data/*.binhce
"""

import sys
import os
from pathlib import Path

# BinHCE format constants
ENTRY_SIZE = 1208  # 32 (sfen) + 8 (extra) + 1168 (hce features)

def get_file_entry_count(filepath):
    """Get the number of entries in a .binhce file."""
    size = os.path.getsize(filepath)
    if size % ENTRY_SIZE != 0:
        raise ValueError(f"File {filepath} has invalid size {size} (not a multiple of {ENTRY_SIZE})")
    return size // ENTRY_SIZE

def merge_binhce_files(output_path, input_paths):
    """Merge multiple .binhce files into one."""
    
    # Validate all input files exist
    for path in input_paths:
        if not os.path.exists(path):
            raise FileNotFoundError(f"Input file not found: {path}")
    
    total_entries = 0
    file_info = []
    
    # Get info about each file
    print("Analyzing input files...")
    for path in input_paths:
        count = get_file_entry_count(path)
        size_mb = os.path.getsize(path) / (1024 * 1024)
        file_info.append((path, count, size_mb))
        total_entries += count
        print(f"  {Path(path).name}: {count:,} entries ({size_mb:.1f} MB)")
    
    print(f"\nTotal entries to merge: {total_entries:,}")
    print(f"Output size: {total_entries * ENTRY_SIZE / (1024 * 1024):.1f} MB")
    
    # Merge files
    print(f"\nMerging into {output_path}...")
    entries_written = 0
    
    with open(output_path, 'wb') as outfile:
        for input_path, count, _ in file_info:
            print(f"  Reading {Path(input_path).name}...", end='', flush=True)
            
            with open(input_path, 'rb') as infile:
                # Read and write in chunks for efficiency
                chunk_size = 1024 * 1024  # 1 MB chunks
                while True:
                    chunk = infile.read(chunk_size)
                    if not chunk:
                        break
                    outfile.write(chunk)
            
            entries_written += count
            print(f" {entries_written:,}/{total_entries:,} entries ({entries_written*100//total_entries}%)")
    
    # Verify output
    output_count = get_file_entry_count(output_path)
    if output_count != total_entries:
        raise RuntimeError(f"Output verification failed: expected {total_entries}, got {output_count}")
    
    print(f"\n✓ Successfully merged {len(input_paths)} files into {output_path}")
    print(f"  Total entries: {output_count:,}")
    print(f"  File size: {os.path.getsize(output_path) / (1024 * 1024):.1f} MB")

def main():
    if len(sys.argv) < 3:
        print("Usage: python merge_binhce.py output.binhce input1.binhce input2.binhce ...")
        print("\nExamples:")
        print("  python merge_binhce.py combined.binhce file1.binhce file2.binhce")
        print("  python merge_binhce.py combined.binhce data/*.binhce")
        sys.exit(1)
    
    output_path = sys.argv[1]
    input_paths = sys.argv[2:]
    
    # Check if output file already exists
    if os.path.exists(output_path):
        response = input(f"Warning: {output_path} already exists. Overwrite? (y/n): ")
        if response.lower() != 'y':
            print("Aborted.")
            sys.exit(0)
    
    try:
        merge_binhce_files(output_path, input_paths)
    except Exception as e:
        print(f"\nError: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
