SOURCES := $(shell find "$(BUILD_DIR)" -type f -name '*.c')
OBJECTS := $(patsubst $(BUILD_DIR)/%.c,$(OBJ_DIR)/%.o,$(SOURCES))

.PHONY: all
all: $(OUTPUT)

$(OUTPUT): $(OBJECTS)
	@printf '  LINK        %s\n' '$@'
	@$(CC) $(OBJECTS) -o '$@' $(LDOPT) $(LDLIBS)

$(OBJ_DIR)/%.o: $(BUILD_DIR)/%.c
	@printf '  CC          %s\n' '$<'
	@mkdir -p '$(@D)'
	@$(CC) $(CSTD) $(OPT) -MMD -MP -c '$<' -o '$@'

# Header dependencies: a regenerated .h retriggers every object that includes it.
-include $(OBJECTS:.o=.d)