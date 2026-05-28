# Makefile for Lambergar chess engine (Cross-platform)
.EXPORT_ALL_VARIABLES:
.DEFAULT_GOAL := build

# Default engine name
ENGINE_COMP = lambergar

# If EXE is provided by OpenBench, use it
ifdef EXE
    ENGINE = $(EXE)
else
    ENGINE = lamb
endif

# Detect OS and set commands accordingly
ifeq ($(OS),Windows_NT)
    # Windows commands
    MOVE_CMD = move zig-out\\bin\\$(ENGINE_COMP).exe ./$(ENGINE).exe
    RM_CMD = del /Q
    RMDIR_CMD = rmdir /S /Q
    EXE_SUFFIX = .exe
    MKDIR_CMD = mkdir
    SHELL_CMD = cmd
else
    # Linux/Unix commands
    MOVE_CMD = mv ./zig-out/bin/$(ENGINE_COMP) ./$(ENGINE)
    RM_CMD = rm -f
    RMDIR_CMD = rm -rf
    EXE_SUFFIX =
    MKDIR_CMD = mkdir -p
    SHELL_CMD = sh
endif

.PHONY: build clean

build:
	@echo "Building $(ENGINE) for $(OS) with Zig..."
	zig build
	@echo "Moving binary to current directory..."
	@$(MOVE_CMD)
	@echo "Moved binary to $(ENGINE)$(EXE_SUFFIX)"
	@echo "Build complete: $(ENGINE)$(EXE_SUFFIX)"

clean:
	@echo "Cleaning build artifacts..."
ifeq ($(OS),Windows_NT)
	@if exist "$(ENGINE_COMP)*.exe" $(RM_CMD) "$(ENGINE_COMP)*.exe"
	@if exist "Lambergar*.exe" $(RM_CMD) "Lambergar*.exe"
	@if exist "lamb*.exe" $(RM_CMD) "lamb*.exe"
	@if exist ".zig-cache" $(RMDIR_CMD) .zig-cache
	@if exist "zig-out" $(RMDIR_CMD) zig-out
else
	@$(RM_CMD) $(ENGINE_COMP)*$(EXE_SUFFIX) Lambergar*$(EXE_SUFFIX) lamb*$(EXE_SUFFIX) 2>/dev/null || true
	@$(RMDIR_CMD) .zig-cache zig-out 2>/dev/null || true
endif
	@echo "Clean complete"