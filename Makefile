# open_ext4_for_mac — build system
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Deliberately plain make + swiftc: full Xcode is NOT required to build this
# project, only the Command Line Tools. Xcode is needed only if you prefer its
# signing workflow; `make sign` uses codesign directly.

DEPLOY_TARGET ?= 15.4
ARCHS         ?= arm64
BUILD         ?= build
CONFIG        ?= release

LWEXT4_DIR := Core/lwext4
SHIM_DIR   := Core/shim

# --- lwext4 tuning -----------------------------------------------------------
# CONFIG_USE_DEFAULT_CFG   : skip lwext4's generated/ header, use its defaults
# CONFIG_BLOCK_DEV_CACHE_SIZE: lwext4 defaults to 8 blocks (sized for MCUs);
#                            a desktop volume needs a real metadata cache
# CONFIG_DEBUG_PRINTF      : silence stdout; diagnostics go through ext4b_set_logger
#
# EXT_FINCOM_IGNORED adds metadata_csum_seed (0x2000) to the INCOMPAT bits
# lwext4 tolerates. Modern mke2fs enables it by default. lwext4 has no notion of
# s_checksum_seed and always derives the seed from the UUID, which is correct
# exactly while the two still agree -- ext4b_probe() verifies that and forces
# read-only when they diverge, so tolerating the bit here is safe.
# Requires patches/lwext4/0001-guard-EXT_FINCOM_IGNORED.patch.
LWEXT4_DEFS := -DCONFIG_USE_DEFAULT_CFG=1 \
               -DCONFIG_BLOCK_DEV_CACHE_SIZE=1024 \
               -DCONFIG_DEBUG_PRINTF=0 \
               -DCONFIG_DEBUG_ASSERT=1 \
               -D'EXT_FINCOM_IGNORED=(EXT4_FINCOM_RECOVER | EXT4_FINCOM_MMP | EXT4_FINCOM_BG_USE_META_CSUM)'

INCLUDES := -I$(LWEXT4_DIR)/include -I$(LWEXT4_DIR)/include/misc -I$(SHIM_DIR)

ifeq ($(CONFIG),debug)
  OPT := -O0 -g -fsanitize=address,undefined
else
  OPT := -O2 -g
endif

CFLAGS := $(OPT) -fno-common -Wall $(INCLUDES) $(LWEXT4_DEFS)
# lwext4 is third-party embedded C; its warnings are not actionable for us.
LWEXT4_CFLAGS := $(CFLAGS) -Wno-everything
SHIM_CFLAGS   := $(CFLAGS) -Wextra -Wno-unused-parameter

TARGET_FLAG := -target arm64-apple-macos$(DEPLOY_TARGET)

LWEXT4_SRCS := $(wildcard $(LWEXT4_DIR)/src/*.c)
LWEXT4_OBJS := $(patsubst $(LWEXT4_DIR)/src/%.c,$(BUILD)/obj/lwext4/%.o,$(LWEXT4_SRCS))
SHIM_OBJS   := $(BUILD)/obj/shim/ext4_bridge.o

CORE_LIB := $(BUILD)/lib/libext4core.a

.PHONY: all core clean test test-asan test-crash test-diff validate tools check-submodule patch unpatch extension app sign install typecheck

all: app

check-submodule:
	@test -f $(LWEXT4_DIR)/include/ext4.h || { \
	  echo "error: lwext4 submodule missing. Run: git submodule update --init"; \
	  exit 1; }

core: check-submodule $(CORE_LIB)

# Vendored-dependency patches.
#
# The stamp file makes patching a real prerequisite of every object file. An
# earlier version listed a phony `patch` target on `core`, which compiled fine
# but was silently skipped whenever make reached $(CORE_LIB) through another
# path (`make app`), producing a library built from unpatched sources.
PATCHES     := $(sort $(wildcard patches/lwext4/*.patch))
PATCH_STAMP := $(BUILD)/.lwext4-patched

$(PATCH_STAMP): $(PATCHES) | check-submodule
	@mkdir -p $(dir $@)
	@for p in $(PATCHES); do \
	  if git -C $(LWEXT4_DIR) apply --check --reverse "$(CURDIR)/$$p" 2>/dev/null; then \
	    :; \
	  elif git -C $(LWEXT4_DIR) apply "$(CURDIR)/$$p" 2>/dev/null; then \
	    echo "applied $$p"; \
	  else \
	    echo "error: failed to apply $$p"; exit 1; \
	  fi; \
	done
	@touch $@

patch: $(PATCH_STAMP)

unpatch:
	@for p in $(PATCHES); do \
	  git -C $(LWEXT4_DIR) apply --reverse "$(CURDIR)/$$p" 2>/dev/null && echo "reverted $$p" || true; \
	done

$(BUILD)/obj/lwext4/%.o: $(LWEXT4_DIR)/src/%.c $(PATCH_STAMP)
	@mkdir -p $(dir $@)
	$(CC) $(TARGET_FLAG) $(LWEXT4_CFLAGS) -c $< -o $@

$(BUILD)/obj/shim/%.o: $(SHIM_DIR)/%.c $(SHIM_DIR)/ext4_bridge.h $(PATCH_STAMP)
	@mkdir -p $(dir $@)
	$(CC) $(TARGET_FLAG) $(SHIM_CFLAGS) -c $< -o $@

$(CORE_LIB): $(LWEXT4_OBJS) $(SHIM_OBJS)
	@mkdir -p $(dir $@)
	@rm -f $@
	ar rcs $@ $^
	@echo "built $@"

# --- test tooling ------------------------------------------------------------
# ext4dump drives the core against a plain file, with no FSKit, no signing and
# no mounting. This is what makes the core testable in CI.
tools: $(BUILD)/bin/ext4dump

$(BUILD)/bin/ext4dump: tools/ext4dump.c $(CORE_LIB)
	@mkdir -p $(dir $@)
	$(CC) $(TARGET_FLAG) $(CFLAGS) $< $(CORE_LIB) -o $@

test: tools
	@bash Tests/run_tests.sh
	@echo
	@bash Tests/run_write_tests.sh

test-crash: tools
	@bash Tests/run_crash_tests.sh

test-diff: tools
	@bash Tests/run_diff_tests.sh

# Everything, unattended, one stage after another. Stages 3 and 4 need Docker.
validate:
	@bash scripts/run_full_validation.sh

validate-asan:
	@bash scripts/run_full_validation.sh --asan

# Same suites under AddressSanitizer + UBSan. Slower, but this is how the
# NULL dereference in lwext4's xattr removal was found.
test-asan:
	@$(MAKE) --no-print-directory clean
	@$(MAKE) --no-print-directory tools CONFIG=debug
	@bash Tests/run_tests.sh
	@echo
	@bash Tests/run_write_tests.sh

clean:
	rm -rf $(BUILD)

# --- FSKit extension ---------------------------------------------------------

APP_NAME   := Ext4Mac
EXT_NAME   := Ext4FS
BUNDLE_ID  := dev.h3ct0r.ext4mac
APPEX      := $(BUILD)/$(APP_NAME).app/Contents/Extensions/$(EXT_NAME).appex
SWIFT_SRCS := $(wildcard Extension/*.swift)

SWIFTFLAGS := -target arm64-apple-macos$(DEPLOY_TARGET) \
              -I Core/shim \
              -framework FSKit \
              -swift-version 5 \
              -parse-as-library

ifeq ($(CONFIG),debug)
  SWIFTFLAGS += -Onone -g
else
  SWIFTFLAGS += -O
endif

typecheck: core
	swiftc -typecheck $(SWIFT_SRCS) $(SWIFTFLAGS)

extension: $(APPEX)

$(APPEX): $(SWIFT_SRCS) $(CORE_LIB) Extension/Info.plist
	@rm -rf "$(APPEX)"
	@mkdir -p "$(APPEX)/Contents/MacOS"
	swiftc $(SWIFT_SRCS) $(SWIFTFLAGS) $(CORE_LIB) \
	    -o "$(APPEX)/Contents/MacOS/$(EXT_NAME)"
	@cp Extension/Info.plist "$(APPEX)/Contents/Info.plist"
	@echo "built $(APPEX)"

# The container app exists only to host the extension: macOS discovers FSKit
# modules through an installed application bundle, and the user enables it in
# System Settings > General > Login Items & Extensions.
app: extension $(BUILD)/$(APP_NAME).app/Contents/Info.plist $(BUILD)/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)

$(BUILD)/$(APP_NAME).app/Contents/Info.plist: App/Info.plist
	@mkdir -p $(dir $@)
	@cp $< $@

$(BUILD)/$(APP_NAME).app/Contents/MacOS/$(APP_NAME): App/Ext4MacApp.swift
	@mkdir -p $(dir $@)
	swiftc App/Ext4MacApp.swift -target arm64-apple-macos$(DEPLOY_TARGET) -O -parse-as-library -o $@

# --- signing -----------------------------------------------------------------
# Requires a Developer ID Application certificate and a provisioning profile
# carrying the com.apple.developer.fskit.fsmodule entitlement.
# See docs/SIGNING.md. Override SIGN_ID on the command line:
#   make sign SIGN_ID="Developer ID Application: Your Name (TEAMID)"

SIGN_ID ?= -

sign: app
	@bash scripts/sign.sh "$(BUILD)/$(APP_NAME).app" "$(SIGN_ID)"

install: sign
	@rm -rf "/Applications/$(APP_NAME).app"
	@cp -R "$(BUILD)/$(APP_NAME).app" /Applications/
	@echo "installed to /Applications/$(APP_NAME).app"
	@echo "Enable it in System Settings > General > Login Items & Extensions > File System Extensions"
