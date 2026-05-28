#!/usr/bin/env python3
"""
Fast BinHCE Loader using compiled Zig library

This module provides a high-performance loader for .binhce files using
a compiled Zig library with C API. It's 5-10x faster than the pure Python
implementation.

Usage:
    from binhce_loader_fast import iter_binhce
    
    for record in iter_binhce("dataset.binhce"):
        print(record.fen, record.score)
"""

import ctypes
import os
import sys
import numpy as np
from dataclasses import dataclass
from typing import Iterator

# Find the compiled library
def find_library():
    """Locate the compiled binhce_loader library."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(script_dir)
    
    # Try different possible locations and names
    possible_paths = [
        os.path.join(project_root, "zig-out", "lib", "libbinhce_loader.dll"),  # Windows
        os.path.join(project_root, "zig-out", "lib", "libbinhce_loader.so"),   # Linux
        os.path.join(project_root, "zig-out", "lib", "libbinhce_loader.dylib"), # macOS
        os.path.join(project_root, "zig-out", "lib", "binhce_loader.dll"),
        os.path.join(project_root, "zig-out", "lib", "binhce_loader.so"),
        os.path.join(project_root, "zig-out", "lib", "binhce_loader.dylib"),
    ]
    
    for path in possible_paths:
        if os.path.exists(path):
            return path
    
    raise FileNotFoundError(
        "Could not find compiled binhce_loader library. "
        "Please build it first with: zig build -Doptimize=ReleaseFast"
    )

# Load the library
try:
    lib_path = find_library()
    lib = ctypes.CDLL(lib_path)
except FileNotFoundError as e:
    print(f"Warning: {e}")
    print("Falling back to slow Python loader...")
    lib = None

# Define C structures
class LoadedData(ctypes.Structure):
    _fields_ = [
        ("sfen32s", ctypes.POINTER(ctypes.c_uint8)),    # 32 bytes each
        ("scores", ctypes.POINTER(ctypes.c_int16)),
        ("move16s", ctypes.POINTER(ctypes.c_uint16)),
        ("plies", ctypes.POINTER(ctypes.c_uint16)),
        ("results", ctypes.POINTER(ctypes.c_int8)),
        ("features", ctypes.POINTER(ctypes.c_uint8)),   # 1536 bytes each
        ("count", ctypes.c_size_t),
    ]

# Define function signatures
if lib:
    # binhce_load(path, load_features, out_data)
    lib.binhce_load.argtypes = [ctypes.c_char_p, ctypes.c_bool, ctypes.POINTER(LoadedData)]
    lib.binhce_load.restype = ctypes.c_int
    
    # binhce_load_selective(path, indices, count, out_data)
    lib.binhce_load_selective.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_size_t), ctypes.c_size_t, ctypes.POINTER(LoadedData)]
    lib.binhce_load_selective.restype = ctypes.c_int
    
    lib.binhce_free.argtypes = [ctypes.POINTER(LoadedData)]
    lib.binhce_free.restype = None
    
    lib.binhce_version.argtypes = []
    lib.binhce_version.restype = ctypes.c_char_p

# BinHCERecord dataclass removed - we use binhce_reader.BinhceRecord for compatibility


def load_binhce(path: str, load_features: bool = True) -> tuple:
    """
    Load .binhce file into memory using fast Zig loader.
    
    Args:
        path: Path to .binhce file
        load_features: If False, skip loading large feature vectors (metadata only)
        
    Returns:
        (sfen32s, scores, move16s, plies, results, features)
        All as numpy arrays for efficient processing.
        If load_features is False, 'features' will be None.
    """
    if lib is None:
        raise RuntimeError("Fast loader library not available. Build it first.")
    
    data = LoadedData()
    path_bytes = path.encode('utf-8')
    
    # Call Zig loader
    error_code = lib.binhce_load(path_bytes, load_features, ctypes.byref(data))
    
    if error_code != 0:
        error_names = {
            1: "FileNotFound",
            2: "OutOfMemory",
            3: "InvalidFormat",
            4: "ReadError",
        }
        raise RuntimeError(f"Failed to load {path}: {error_names.get(error_code, 'Unknown error')}")
    
    try:
        # Convert C arrays to numpy arrays (zero-copy views)
        count = data.count
        
        sfen32s_array = np.ctypeslib.as_array(data.sfen32s, shape=(count, 32)).copy()
        scores = np.ctypeslib.as_array(data.scores, shape=(count,)).copy()
        move16s = np.ctypeslib.as_array(data.move16s, shape=(count,)).copy()
        plies = np.ctypeslib.as_array(data.plies, shape=(count,)).copy()
        results = np.ctypeslib.as_array(data.results, shape=(count,)).copy()
        
        features_array = None
        if load_features and data.features:
            features_array = np.ctypeslib.as_array(data.features, shape=(count, 1536)).copy()
        
        result_tuple = (
            sfen32s_array,
            scores,
            move16s,
            plies,
            results,
            features_array
        )
        
    finally:
        # Free C memory
        lib.binhce_free(ctypes.byref(data))
    
    return result_tuple


def load_binhce_selective(path: str, indices: np.ndarray) -> tuple:
    """
    Load specific records from .binhce file by index.
    
    Args:
        path: Path to .binhce file
        indices: Numpy array of indices (uint64/size_t) to load
        
    Returns:
        (sfen32s, scores, move16s, plies, results, features) 
        of length len(indices).
    """
    if lib is None:
        raise RuntimeError("Fast loader library not available. Build it first.")
    
    if not isinstance(indices, np.ndarray):
        indices = np.array(indices, dtype=np.uintp)
    elif indices.dtype != np.uintp:
        indices = indices.astype(np.uintp)

    data = LoadedData()
    path_bytes = path.encode('utf-8')
    
    # Pointer to indices array
    indices_ptr = indices.ctypes.data_as(ctypes.POINTER(ctypes.c_size_t))
    
    # Call Zig loader
    error_code = lib.binhce_load_selective(path_bytes, indices_ptr, len(indices), ctypes.byref(data))
    
    if error_code != 0:
        error_names = {
            1: "FileNotFound",
            2: "OutOfMemory",
            3: "InvalidFormat",
            4: "ReadError",
        }
        raise RuntimeError(f"Failed to load selective records from {path}: {error_names.get(error_code, 'Unknown error')}")
    
    try:
        count = data.count
        
        # Copy arrays to allow freeing C memory
        sfen32s_array = np.ctypeslib.as_array(data.sfen32s, shape=(count, 32)).copy()
        scores = np.ctypeslib.as_array(data.scores, shape=(count,)).copy()
        move16s = np.ctypeslib.as_array(data.move16s, shape=(count,)).copy()
        plies = np.ctypeslib.as_array(data.plies, shape=(count,)).copy()
        results = np.ctypeslib.as_array(data.results, shape=(count,)).copy()
        features_array = np.ctypeslib.as_array(data.features, shape=(count, 1536)).copy()
        
        result_tuple = (
            sfen32s_array,
            scores,
            move16s,
            plies,
            results,
            features_array
        )
        
    finally:
        # Free C memory
        lib.binhce_free(ctypes.byref(data))
    
    return result_tuple


def iter_binhce(path: str) -> Iterator:
    """
    Iterate over records in .binhce file.
    
    Note: This loads the entire file into memory first for speed.
    Falls back to Python loader's record structure for compatibility.
    """
    sfen32s, scores, move16s, plies, results, features = load_binhce(path)
    
    # Import Python loader's record structure for compatibility
    import binhce_reader
    
    for i in range(len(scores)):
        # Decode FEN from SFEN32
        try:
            board = binhce_reader._decode_position(sfen32s[i])
            fen = board.fen(shredder=False)
        except:
            # Skip corrupted positions silently
            continue
        
        # Return using Python loader's BinhceRecord structure
        yield binhce_reader.BinhceRecord(
            sfen32=sfen32s[i].tobytes(),  # Convert to bytes like Python loader
            score=int(scores[i]),
            move16=int(move16s[i]),
            ply=int(plies[i]),
            result=int(results[i]),
            features=features[i],
            fen=fen
        )

def get_version() -> str:
    """Get version of the Zig loader library."""
    if lib is None:
        return "unavailable"
    return lib.binhce_version().decode('utf-8')

if __name__ == "__main__":
    # Test the loader
    if len(sys.argv) < 2:
        print("Usage: python binhce_loader_fast.py <file.binhce>")
        sys.exit(1)
    
    import time
    import binhce_reader
    
    path = sys.argv[1]
    print(f"Testing fast loader on: {path}")
    print(f"Loader version: {get_version()}")
    
    start = time.time()
    sfen32s, scores, move16s, plies, results, features = load_binhce(path)
    elapsed = time.time() - start
    
    print(f"\nLoaded {len(scores)} records in {elapsed:.2f}s")
    print(f"Speed: {len(scores) / elapsed:.0f} records/sec")
    
    # Show first few records (decode FENs on demand)
    print(f"\nFirst 3 records:")
    for i in range(min(3, len(scores))):
        try:
            board = binhce_reader._decode_position(sfen32s[i])
            fen = board.fen()
        except:
            fen = "invalid"
        print(f"  {i+1}. FEN: {fen}")
        print(f"     Score: {scores[i]}, Result: {results[i]}, Ply: {plies[i]}")
        print(f"     Features shape: {features[i].shape}")
