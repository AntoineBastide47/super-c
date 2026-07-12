# Self-hosted build. An existing super-c ($(SUPERC)) compiles the compiler, its @test suite, and the
# transpile benchmark straight from the .spc sources in src/ -- this Makefile compiles no C of its own.
#
# $(SUPERC) is the bootstrap. It defaults to the repo-local ./super-c, which then rebuilds itself; point it
# at any working super-c to build from a clean slate, e.g.  make SUPERC=/path/to/super-c  (a fresh checkout
# with no ./super-c must supply one this way -- e.g. a release binary).
SUPERC ?= ./super-c
CC     ?= cc
# ccache (if installed) makes stage-2 compiles ~free: at the self-hosting fixpoint its C is
# byte-identical to stage 1's, so every object is a cache hit.
ifneq ($(shell command -v ccache 2>/dev/null),)
  CC := ccache $(CC)
endif
BIN    := super-c
# All available cores for the generated-C compile fan-out (macOS: sysctl; Linux/msys: nproc;
# Windows: the NUMBER_OF_PROCESSORS env var is always set).
NPROC  := $(shell sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo $${NUMBER_OF_PROCESSORS:-4})

CSTD := -std=c11 -D_POSIX_C_SOURCE=200809L

# Backend C flags for the transpiled compiler. release: aggressive optimization + LTO; dev: -O1 + address/
# undefined sanitizers so the self-hosted compiler is checked while you work on it. (bench/profile use their
# own -O2, below -- you never want LTO build cost or sanitizer slowdown when measuring/profiling.)
RELEASE_OPT   := -O3 -DNDEBUG -finline-functions -fomit-frame-pointer -ffunction-sections -fdata-sections -flto=auto -fPIE
RELEASE_LDOPT := -flto=auto -Wl,-O2

DEBUG_OPT := -g -O1 -fsanitize=address -fno-omit-frame-pointer \
             -fsanitize-recover=address -fsanitize=undefined \
             -fsanitize-address-use-after-scope

PROFILE ?= dev
ifeq ($(PROFILE),release)
  OPT   := $(RELEASE_OPT)
  LDOPT := $(RELEASE_LDOPT)
  STRIP := strip '$(BIN)'
else
  OPT   := $(DEBUG_OPT)
  # sanitizers must also be passed at LINK time so their runtimes get linked
  LDOPT := -fsanitize=address -fsanitize=undefined
  STRIP := :
endif

# libm: needed on Linux (glibc splits it out) for the CTFE interpreter's <math.h>
# calls; a harmless no-op on macOS where it re-exports from libSystem. Must follow
# the objects on the link line for --as-needed (default on modern Linux) to keep it.
LDLIBS := -lm

SRC_DIR   := src
BUILD_DIR := build/$(PROFILE)
# The compiler's own sources: its module closure reachable from main.spc plus the C driver shim. Changing
# any of these rebuilds $(BIN); the test/bench entry roots are excluded (they are not part of the compiler).
COMPILER_SRCS := $(shell find src -name '*.spc' \
                   -not -path 'src/tests/*' \
                   -not -path 'src/benchmark/*' \
                   -not -name 'run_tests.spc' -not -name 'run_bench.spc' 2>/dev/null) \
                 src/driver_shim.c src/driver_shim.h

SELFHOST_TEST_ROOT  := src/run_tests.spc
SELFHOST_BENCH_ROOT := src/run_bench.spc

.PHONY: all build run release test bench profile clean distclean

# `make clean <goals>` (e.g. `make clean bench -j7`) races: a parallel `rm -rf build` can delete outputs
# from under a concurrent build. When clean is combined with other goals, run serially so it finishes first.
ifneq ($(filter clean,$(MAKECMDGOALS)),)
ifneq ($(filter-out clean,$(MAKECMDGOALS)),)
.NOTPARALLEL:
endif
endif

all: $(BIN)
build: $(BIN)

# Build the self-hosted compiler from its .spc sources using the existing $(SUPERC): $(SUPERC) transpiles
# the module closure to a fresh src/build tree, then $(CC) compiles it with the profile's flags.
# Link to a temp name and mv into place so a running $(SUPERC) that IS $(BIN) is never overwritten mid-build.
# Two stages so a $(SUPERC) that predates a tag can still build source that uses it. Stage 1 passes
# --bootstrap-tags: any @attribute the bootstrap doesn't know is parsed and ignored, so the build always
# goes through and yields a tag-aware compiler. Stage 2 rebuilds the tree with that compiler and NO flag --
# a strict, self-hosted build (also catches misspelled attributes, which stage 1 would silently ignore).
$(BIN): $(COMPILER_SRCS)
	@printf '  SELF-BUILD  %s  (via %s, %s)\n' '$(BIN)' '$(SUPERC)' '$(PROFILE)'

	@rm -rf src/build
	@$(SUPERC) --bootstrap-tags src/main.spc
	@sh mk/sync-generated.sh src/build src/.gen-stage1
	@$(MAKE) --no-print-directory -j $(NPROC) -f mk/compile-generated.mk \
		BUILD_DIR=src/.gen-stage1 \
		OBJ_DIR=.obj/stage1 \
		OUTPUT='stage1-$(BIN)' \
		CC='$(CC)' \
		CSTD='$(CSTD)' \
		OPT='$(OPT)' \
		LDOPT='$(LDOPT)' \
		LDLIBS='$(LDLIBS)'

	@rm -rf src/build
	@./'stage1-$(BIN)' src/main.spc
	@sh mk/sync-generated.sh src/build src/.gen-stage2
	@$(MAKE) --no-print-directory -j $(NPROC) -f mk/compile-generated.mk \
		BUILD_DIR=src/.gen-stage2 \
		OBJ_DIR=.obj/stage2 \
		OUTPUT='$(BIN).new' \
		CC='$(CC)' \
		CSTD='$(CSTD)' \
		OPT='$(OPT)' \
		LDOPT='$(LDOPT)' \
		LDLIBS='$(LDLIBS)'

	@rm -f 'stage1-$(BIN)'
	@mv -f '$(BIN).new' '$(BIN)'
	@rm -rf ./*.dSYM
	@$(STRIP)

run: $(BIN)
	@./$(BIN)

# Force a rebuild: the binary is one path shared across profiles, so a stale dev/release build would
# otherwise look up-to-date when switching.
release:
	@$(MAKE) -B PROFILE=release all

# Run the self-hosted @test suite through the freshly built compiler. SUPERC is exported so the behavioral
# tests' compile_and_run drives the SAME binary when it builds+runs snippets.
test: $(BIN)
	@SUPERC='./$(BIN)' ./$(BIN) --test $(SELFHOST_TEST_ROOT)

# Transpile benchmark: the compiler emits the self-transpile timing program, cc -O2 compiles + runs it.
bench: $(BIN)
	@printf '\n========== Transpile benchmark ==========\n'
	@rm -rf src/build
	@./$(BIN) $(SELFHOST_BENCH_ROOT)
	@mkdir -p build
	@$(CC) $(CSTD) $(RELEASE_OPT) $$(find src/build -name '*.c') -o build/selfhost-bench $(RELEASE_LDOPT) $(LDLIBS)
	@build/selfhost-bench

# Profile the transpile benchmark with samply (CPU sampling -> Firefox Profiler UI). Same build as `bench`
# but -O2 -g -fno-omit-frame-pointer so optimized hotspots still symbolicate to source. For more samples,
# raise ITERS in src/benchmark/transpile_bench.spc (default 8, ~1s) or pass RATE=N (default 1000 Hz).
# Needs samply:  brew install samply  (or  cargo install samply).
RATE ?= 1000
# Never strip the binary built for a profiling run -- symbols must survive even under PROFILE=release.
profile: STRIP := :
profile: $(BIN)
	@rm -rf src/build
	@./$(BIN) $(SELFHOST_BENCH_ROOT)
	@mkdir -p build
	@$(CC) $(CSTD) -O2 -g -fno-omit-frame-pointer $$(find src/build -name '*.c') -o build/selfhost-bench
	@samply record --rate $(RATE) build/selfhost-bench

# clean drops build artifacts + emitted C but KEEPS $(BIN) -- it is the bootstrap that rebuilds itself.
# distclean also removes the binary (you then need an external $(SUPERC) to build again).
clean:
	@rm -rf build src/build src/.gen-stage1 src/.gen-stage2 .obj '$(BIN).new' 'stage1-$(BIN)' *.out profile.json.gz

distclean: clean
	@rm -f '$(BIN)'
