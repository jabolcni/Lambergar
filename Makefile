# Makefile for Lambergar chess engine (Windows-focused)
.EXPORT_ALL_VARIABLES:
.DEFAULT_GOAL := build

# Default engine name
ENGINE_COMP = lambergar

# If EXE is provided by OpenBench, use it
ifdef EXE
    ENGINE = $(EXE)
endif

# Detect OS and set commands accordingly
ifeq ($(OS),Windows_NT)
    # Windows commands
    MOVE_CMD = move zig-out\\bin\\$(ENGINE_COMP).exe ./$(ENGINE).exe
    RM_CMD = del /Q
    RMDIR_CMD = rmdir /S /Q
    EXE_SUFFIX = .exe
else
    # Linux commands (for future compatibility)
    MOVE_CMD = mv ./zig-out/bin/$(ENGINE_COMP) ./$(ENGINE)
    RM_CMD = rm -f
    RMDIR_CMD = rm -rf
    EXE_SUFFIX =
endif

.PHONY: build clean

build:
	@echo "Building $(ENGINE) for Windows with Zig..."
	zig build
	@echo "Moving binary to current directory..."
	@$(MOVE_CMD)
	@echo "Moved binary to $(ENGINE)$(EXE_SUFFIX)"
	@echo "Build complete: $(ENGINE)$(EXE_SUFFIX)"

clean:
	@echo "Cleaning build artifacts..."
	@if exist "lambergar*.exe" $(RM_CMD) "lambergar*.exe"
	@if exist "Lambergar*.exe" $(RM_CMD) "Lambergar*.exe"
	@if exist ".zig-cache" $(RMDIR_CMD) .zig-cache
	@if exist "zig-out" $(RMDIR_CMD) zig-out
	@echo "Clean complete"


