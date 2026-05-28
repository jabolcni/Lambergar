@echo off
REM Build script for binhce_loader shared library (Windows)
REM This compiles the Zig loader as a standalone DLL for Python

echo Building binhce_loader shared library...

REM Create output directory
if not exist zig-out\lib mkdir zig-out\lib

REM Build as object file (simpler, no linker needed)
echo Compiling for Windows...
zig build-lib src\binhce_loader.zig -O ReleaseFast -femit-bin=zig-out\lib\binhce_loader.dll -lc

if %ERRORLEVEL% EQU 0 (
    echo.
    echo Success! Built: zig-out\lib\binhce_loader.dll
    echo.
    echo Test the loader with:
    echo   python tuner\binhce_loader_fast.py ^<dataset.binhce^>
) else (
    echo.
    echo Build failed! Make sure you have:
    echo   1. Zig compiler installed
    echo   2. Visual Studio Build Tools (for linker)
    echo.
    echo Alternative: Use the slow Python loader (no build needed)
    exit /b 1
)
