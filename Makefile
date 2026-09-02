# I know you can easily shoot yourself in the foot
# with this.
MAKEFLAGS += -j$(shell nproc)

# Gets all projects inside the examples/ directory
EXAMPLES := $(wildcard examples/*/)
FFI_DIR := src/eparch/ffi

.PHONY: all ffi-check ffi-deps-nix $(EXAMPLES)

# Default target
all: $(EXAMPLES)

# The recipe for each directory
$(EXAMPLES):
	@echo "Starting build for: $@"
	@cd $@ && gleam deps update && gleam build && gleam test
	@echo "Finished build for: $@"

ffi-check:
	@cd $(FFI_DIR) && rebar3 do eunit, dialyzer

ffi-deps-nix:
	@cd $(FFI_DIR) && rebar3 as nix nix lock
