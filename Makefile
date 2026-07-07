CC       ?= cc
CSTD     := -std=c11 -D_POSIX_C_SOURCE=200809L
WARN     := -Wall -Wextra
INCLUDE  := -Isrc
DEPFLAGS := -MMD -MP

# OpenMP runtime for the parallelized raii_gen test (the rest of the suite ignores it). Apple clang needs
# Homebrew's libomp; on GCC run `make OMP_FLAGS=-fopenmp`. Without it raii_gen still builds and runs serially.
# $(wildcard) probes the known Homebrew prefixes with no subprocess, so plain `make` pays nothing.
OMP_FLAGS ?=
ifeq ($(strip $(OMP_FLAGS)),)
  LIBOMP := $(firstword $(wildcard /opt/homebrew/opt/libomp /usr/local/opt/libomp))
  ifneq ($(LIBOMP),)
    OMP_FLAGS := -Xpreprocessor -fopenmp -I$(LIBOMP)/include -L$(LIBOMP)/lib -lomp
  endif
endif
OMP :=

V ?= 0
BAR_WIDTH := 20

ifndef ECHO
ifeq ($(V),0)
  COUNT_B := $(if $(filter clean,$(MAKECMDGOALS)),-B)
  STEP_TOTAL := $(shell $(MAKE) -nrR $(COUNT_B) -f $(firstword $(MAKEFILE_LIST)) \
                  $(or $(MAKECMDGOALS),all) ECHO=__STEP__ 2>/dev/null | grep -c __STEP__)
  ifeq ($(STEP_TOTAL),0)
    STEP_TOTAL := 1
  endif
  STEP_N := x
  STEP    = $(words $(STEP_N))$(eval STEP_N := x $(STEP_N))
  ECHO = c=$(STEP); t=$(STEP_TOTAL); [ $$c -gt $$t ] && c=$$t; \
         f=`expr $$c '*' $(BAR_WIDTH) / $$t`; e=`expr $(BAR_WIDTH) - $$f`; \
         printf '[%s%s] %3d%%  %-4s %s\n' \
           "`printf '%*s' $$f '' | tr ' ' '='`" "`printf '%*s' $$e '' | tr ' ' '-'`" \
           `expr $$c '*' 100 / $$t` '$1' '$2'
  Q := @
  MAKEFLAGS += --no-print-directory
else
  ECHO := :
  Q :=
endif
endif

PROFILE ?= dev

BIN := super-c

RELEASE_OPT := -O3 -DNDEBUG -finline-functions -fomit-frame-pointer \
               -ffunction-sections -fdata-sections -flto -fPIE
RELEASE_LDOPT := -flto -Wl,-O2

DEBUG_OPT := -g -O1 -fsanitize=address -fno-omit-frame-pointer \
             -fsanitize-recover=address -fsanitize=undefined \
             -fsanitize-address-use-after-scope

ifeq ($(PROFILE),release)
  OPT       := $(RELEASE_OPT)
  LDOPT     := $(RELEASE_LDOPT)
  STRIP_BIN := strip $(BIN)
else
  OPT       := $(DEBUG_OPT)
  LDOPT     :=
  STRIP_BIN := :
endif

SRC_DIR   := src
BUILD_DIR := build/$(PROFILE)

LIB_SRCS := $(filter-out $(SRC_DIR)/main.c,\
              $(wildcard $(SRC_DIR)/*.c) $(wildcard $(SRC_DIR)/*/*.c))
LIB_OBJS := $(LIB_SRCS:$(SRC_DIR)/%.c=$(BUILD_DIR)/%.o)

TEST_SRCS := $(wildcard tests/*_test.c)
TEST_BINS := $(TEST_SRCS:tests/%.c=$(BUILD_DIR)/tests/%)

# Release/NDEBUG test lane: ast_fprint is compiled in only under NDEBUG, so its driver must link
# release lib objects. These run after the dev tests via `$(MAKE) PROFILE=release rtest`.
RTEST_SRCS := $(wildcard tests/*_rtest.c)
RTEST_BINS := $(RTEST_SRCS:tests/%.c=$(BUILD_DIR)/tests/%)

# Self-hosted tests: Super-C `@test` files under selfhost/tests/ that import the self-hosted compiler
# modules / std and run through `super-c --test` (dogfooding the language's own test framework on itself).
# They are aggregated by selfhost/run_tests.spc, the compilation ROOT (module imports resolve from there).
SELFHOST_TEST_ROOT := selfhost/run_tests.spc

BENCHMARK_SRCS := $(wildcard benchmark/*_bench.c)
BENCHMARK_BINS := $(BENCHMARK_SRCS:benchmark/%.c=$(BUILD_DIR)/benchmark/%)

.PHONY: all build run release test rtest selfhost-test bench clean

all: $(BIN)

run: all
	@./$(BIN)

release:
	@$(MAKE) PROFILE=release all

ifeq ($(PROFILE),dev)
test: $(BIN) $(TEST_BINS)
	@for test in $(TEST_BINS); do $$test || exit 1; done
	@$(MAKE) PROFILE=release rtest
	@$(MAKE) selfhost-test
else
test:
	@$(MAKE) PROFILE=dev test
endif

# Run the self-hosted @test suite (selfhost/tests/*.spc) through `super-c --test` via its aggregator root.
selfhost-test: $(BIN)
	@./$(BIN) --test $(SELFHOST_TEST_ROOT)

ifeq ($(PROFILE),release)
rtest: $(RTEST_BINS)
	@for test in $(RTEST_BINS); do $$test || exit 1; done
else
rtest:
	@$(MAKE) PROFILE=release rtest
endif

ifeq ($(PROFILE),release)
bench: $(BENCHMARK_BINS)
	@printf '\n========== Benchmarks ==========\n'
	@for benchmark in $(BENCHMARK_BINS); do \
	   printf '\n--- %s ---\n' "$$(basename $$benchmark)"; \
	   $$benchmark || exit 1; \
	 done
else
bench:
	@$(MAKE) PROFILE=release bench
endif

# raii_gen and codegen_run are OpenMP-parallelized; every other test links without it ($(OMP) stays empty).
$(BUILD_DIR)/tests/raii_gen_test $(BUILD_DIR)/tests/codegen_run_test: OMP := $(OMP_FLAGS)

$(BUILD_DIR)/tests/%: tests/%.c $(LIB_OBJS)
	@mkdir -p $(@D)
	@$(call ECHO,LINK,$@)
	$(Q)$(CC) $(CSTD) $(OPT) $(WARN) $(INCLUDE) -DSUPERC_STD_DIR='"$(CURDIR)/std"' $(DEPFLAGS) $< $(LIB_OBJS) -o $@ $(LDOPT) $(OMP)

$(BUILD_DIR)/benchmark/%: benchmark/%.c $(LIB_OBJS)
	@mkdir -p $(@D)
	@$(call ECHO,LINK,$@)
	$(Q)$(CC) $(CSTD) $(OPT) $(WARN) $(INCLUDE) $(DEPFLAGS) $< $(LIB_OBJS) -o $@ $(LDOPT)

$(BIN): $(LIB_OBJS) $(BUILD_DIR)/main.o
	@$(call ECHO,LINK,$@)
	$(Q)$(CC) $(CSTD) $(OPT) $^ -o $@ $(LDOPT)
	@$(STRIP_BIN)

$(BUILD_DIR)/%.o: $(SRC_DIR)/%.c
	@mkdir -p $(@D)
	@$(call ECHO,CC,$<)
	$(Q)$(CC) $(CSTD) $(OPT) $(WARN) $(INCLUDE) $(DEPFLAGS) $(CPPFLAGS_EXTRA) -c $< -o $@

$(BUILD_DIR)/main.o: CPPFLAGS_EXTRA := -DBIN_NAME='"$(BIN)"'

# Header-dependency tracking: -MMD -MP emits a .d file beside each object/binary listing the
# headers it includes (plus phony header targets so deleting a header doesn't break the build).
DEPS := $(LIB_OBJS:.o=.d) $(BUILD_DIR)/main.d $(addsuffix .d,$(TEST_BINS) $(RTEST_BINS) $(BENCHMARK_BINS))
-include $(DEPS)

clean:
	@rm -rf build $(BIN) profile.json.gz *.out
