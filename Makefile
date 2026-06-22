CC      ?= cc
CSTD    := -std=c11 -D_POSIX_C_SOURCE=200809L
WARN    := -Wall -Wextra
INCLUDE := -Isrc

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

BENCHMARK_SRCS := $(wildcard benchmark/*_bench.c)
BENCHMARK_BINS := $(BENCHMARK_SRCS:benchmark/%.c=$(BUILD_DIR)/benchmark/%)

.PHONY: all run release test bench clean

all: $(BIN)

run: all
	@./$(BIN)

release:
	@$(MAKE) PROFILE=release all

ifeq ($(PROFILE),dev)
test: $(TEST_BINS)
	@for test in $(TEST_BINS); do $$test || exit 1; done
else
test:
	@$(MAKE) PROFILE=dev test
endif

ifeq ($(PROFILE),release)
bench: $(BENCHMARK_BINS)
	@for benchmark in $(BENCHMARK_BINS); do $$benchmark || exit 1; done
else
bench:
	@$(MAKE) PROFILE=release bench
endif

$(BUILD_DIR)/tests/%: tests/%.c $(LIB_OBJS)
	@mkdir -p $(@D)
	@$(call ECHO,LINK,$@)
	$(Q)$(CC) $(CSTD) $(OPT) $(WARN) $(INCLUDE) $< $(LIB_OBJS) -o $@ $(LDOPT)

$(BUILD_DIR)/benchmark/%: benchmark/%.c $(LIB_OBJS)
	@mkdir -p $(@D)
	@$(call ECHO,LINK,$@)
	$(Q)$(CC) $(CSTD) $(OPT) $(WARN) $(INCLUDE) $< $(LIB_OBJS) -o $@ $(LDOPT)

$(BIN): $(LIB_OBJS) $(BUILD_DIR)/main.o
	@$(call ECHO,LINK,$@)
	$(Q)$(CC) $(CSTD) $(OPT) $^ -o $@ $(LDOPT)
	@$(STRIP_BIN)

$(BUILD_DIR)/%.o: $(SRC_DIR)/%.c
	@mkdir -p $(@D)
	@$(call ECHO,CC,$<)
	$(Q)$(CC) $(CSTD) $(OPT) $(WARN) $(INCLUDE) $(CPPFLAGS_EXTRA) -c $< -o $@

$(BUILD_DIR)/main.o: CPPFLAGS_EXTRA := -DBIN_NAME='"$(BIN)"'

clean:
	@rm -rf build $(BIN) profile.json.gz
