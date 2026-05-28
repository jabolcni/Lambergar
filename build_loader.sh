#!/usr/bin/env bash
# Build script for binhce_loader shared library
# This compiles the Zig loader as a standalone shared library for Python

set -e

echo "Building binhce_loader shared library..."

# Detect OS
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" ]]; then
    OS="windows"
    LIB_EXT="dll"
elif [[ "$OSTYPE" == "darwin"* ]]; then
    OS="macos"
    LIB_EXT="dylib"
else
    OS="linux"
    LIB_EXT="so"
fi

# Create output directory
mkdir -p zig-out/lib

# Build the shared library
echo "Compiling for $OS..."
zig build-lib src/binhce_loader.zig \
    -dynamic \
    -O ReleaseFast \
    -femit-bin=zig-out/lib/binhce_loader.$LIB_EXT

echo "✓ Built: zig-out/lib/binhce_loader.$LIB_EXT"
echo ""
echo "Test the loader with:"
echo "  python tuner/binhce_loader_fast.py <dataset.binhce>"
