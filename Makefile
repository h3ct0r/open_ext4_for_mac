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
CRYPTO_DIR := Core/crypto

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

INCLUDES := -I$(LWEXT4_DIR)/include -I$(LWEXT4_DIR)/include/misc -I$(SHIM_DIR) -I$(CRYPTO_DIR)

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
SHIM_OBJS   := $(BUILD)/obj/shim/ext4_bridge.o \
               $(BUILD)/obj/shim/device_barrier.o

# Block-level decryption, for ext4 inside a LUKS container. It sits below the
# filesystem, decorating the same read/write/flush callbacks ext4b_device_create
# already takes, so lwext4 never learns that anything is encrypted.
CRYPTO_SRCS := $(wildcard $(CRYPTO_DIR)/*.c)
CRYPTO_OBJS := $(patsubst $(CRYPTO_DIR)/%.c,$(BUILD)/obj/crypto/%.o,$(CRYPTO_SRCS))

# Argon2, vendored unmodified for LUKS2 key derivation; see
# Core/crypto/argon2/README.md. Third-party, so its warnings are silenced the
# same way lwext4's are -- they are not ours to act on.
ARGON2_DIR  := $(CRYPTO_DIR)/argon2
ARGON2_SRCS := $(ARGON2_DIR)/argon2.c $(ARGON2_DIR)/core.c $(ARGON2_DIR)/ref.c \
               $(ARGON2_DIR)/thread.c $(ARGON2_DIR)/encoding.c \
               $(ARGON2_DIR)/blake2/blake2b.c
ARGON2_OBJS := $(patsubst $(CRYPTO_DIR)/%.c,$(BUILD)/obj/crypto/%.o,$(ARGON2_SRCS))
ARGON2_CFLAGS := $(CFLAGS) -Wno-everything -I$(ARGON2_DIR)

CORE_LIB := $(BUILD)/lib/libext4core.a

.PHONY: all core clean test test-asan test-crash test-diff test-format test-crypto test-orphan test-luks test-mount-crash test-mount-luks test-kill-recovery check-extension check-signing validate tools entitlements check-submodule patch unpatch extension app sign install typecheck install-diskutil uninstall-diskutil

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

$(BUILD)/obj/crypto/argon2/%.o: $(ARGON2_DIR)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(TARGET_FLAG) $(ARGON2_CFLAGS) -c $< -o $@

$(BUILD)/obj/crypto/%.o: $(CRYPTO_DIR)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(TARGET_FLAG) $(SHIM_CFLAGS) -I$(ARGON2_DIR) -c $< -o $@

$(CORE_LIB): $(LWEXT4_OBJS) $(SHIM_OBJS) $(CRYPTO_OBJS) $(ARGON2_OBJS)
	@mkdir -p $(dir $@)
	@rm -f $@
	ar rcs $@ $^
	@echo "built $@"

# --- test tooling ------------------------------------------------------------
# ext4dump drives the core against a plain file, with no FSKit, no signing and
# no mounting. This is what makes the core testable in CI.
tools: $(BUILD)/bin/ext4dump $(BUILD)/bin/cryptotest

# Known-answer tests for the crypto primitives, against vectors generated by
# OpenSSL rather than transcribed by hand. See Tests/gen_xts_vectors.sh.
$(BUILD)/bin/cryptotest: tools/cryptotest.c $(CORE_LIB)
	@mkdir -p $(dir $@)
	$(CC) $(TARGET_FLAG) $(CFLAGS) $< $(CORE_LIB) -o $@

test-crypto: $(BUILD)/bin/cryptotest
	@$(BUILD)/bin/cryptotest

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

test-format: tools
	@bash Tests/run_format_tests.sh

# Open-unlink and the orphan list: recovery by this driver, by e2fsck and by
# the Linux kernel, plus lists deliberately damaged the way a power cut damages
# them. Only the Linux cross-check needs Docker; it skips itself without one.
test-orphan: tools
	@bash Tests/run_orphan_tests.sh

# ext4 inside a LUKS container. Fixtures come from real cryptsetup, and what we
# write is handed back to cryptsetup and the Linux kernel to read -- a
# decryption bug that is symmetric passes every test we could run alone.
test-luks: tools
	@bash Tests/run_luks_tests.sh

# Encrypted volumes against the mounted driver: the decrypting layer rebuilt
# inside the sandboxed extension, on top of FSBlockDeviceResource. Everything
# macOS writes is handed back to cryptsetup and the Linux kernel to read.
test-mount-luks:
	@bash Tests/run_mount_luks_tests.sh

# What a killed driver leaves behind, and whether the journal recovers it.
# Passes on a disk image; EXT4_KILL_DEVICE=diskN points it at real media, which
# it ERASES, and which is where the missing write barrier shows.
test-kill-recovery:
	@bash Tests/run_kill_recovery_tests.sh

# Crash consistency against the mounted driver rather than the offline core.
# Needs the extension signed, installed and enabled; skips with a message if
# it is not. This is the only suite that exercises FSBlockDeviceResource.
test-mount-crash:
	@bash Tests/run_mount_crash_tests.sh

# Is the extension installed, approved and answering? The failure messages for
# a disabled module are inconsistent enough to be worth a dedicated check.
# `|| true` so a disabled extension reads as a diagnosis rather than a build
# failure; call scripts/check_extension.sh directly if you want the exit code.
check-extension:
	@bash scripts/check_extension.sh || true

# Are the entitlements each binary claims actually authorised by the profile it
# embeds? An unauthorised one is not refused, it is fatal at launch with no
# crash report -- so it is checked at build time instead. Runs as part of sign.
check-signing:
	@bash scripts/verify_signing.sh "$(BUILD)/$(APP_NAME).app"

# Everything, unattended, one stage after another. Stages 5-7 need Docker.
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
# Ext4Volume+KernelIO.swift is deliberately excluded (kept as .disabled).
#
# Conforming to FSVolumeKernelOffloadedIOOperations makes FSKit route I/O
# through blockmapFile even for files reporting inhibitKernelOffloadedIO, and a
# write blockmap has to allocate blocks and journal the extent-tree change
# before returning, with no way to undo it if the kernel then fails the I/O.
# Until that is implemented, all I/O goes through FSVolume.ReadWriteOperations,
# where allocation stays inside a transaction we control.
# Shared/ is compiled into both the extension and the container app. It holds
# the one thing they have in common: the keychain items an encrypted volume's
# master key travels in. An app extension has no IPC back to its host, so that
# is the whole channel between them.
SHARED_SRCS := $(wildcard Shared/*.swift)
SWIFT_SRCS  := $(wildcard Extension/*.swift) $(SHARED_SRCS)

SWIFTFLAGS := -target arm64-apple-macos$(DEPLOY_TARGET) \
              -I Core/shim \
              -framework FSKit \
              -swift-version 5 \
              -parse-as-library \
              -application-extension \
              -framework ExtensionFoundation \
              -Xlinker -u -Xlinker _EXExtensionMain \
              -Xlinker -e -Xlinker _EXExtensionMain

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

# The app links the core so it can read a LUKS header and run the key
# derivation itself: a gigabyte of argon2id belongs in an ordinary application,
# not in a sandboxed app extension that pays for it once per load.
APP_SRCS := $(wildcard App/*.swift) $(SHARED_SRCS)

$(BUILD)/$(APP_NAME).app/Contents/MacOS/$(APP_NAME): $(APP_SRCS) $(CORE_LIB)
	@mkdir -p $(dir $@)
	swiftc $(APP_SRCS) -target arm64-apple-macos$(DEPLOY_TARGET) -O -parse-as-library \
	    -I $(SHIM_DIR) $(CORE_LIB) -o $@

# --- signing -----------------------------------------------------------------
# Requires a Developer ID Application certificate and a provisioning profile
# carrying the com.apple.developer.fskit.fsmodule entitlement.
# See docs/SIGNING.md. Override SIGN_ID on the command line:
#   make sign SIGN_ID="Developer ID Application: Your Name (TEAMID)"
#
# Auto-detected when the keychain holds exactly one Developer ID Application
# identity, because getting this wrong is expensive to notice: an ad-hoc
# signature cannot carry the fskit.fsmodule entitlement, so FSKit drops the
# module -- and a dropped module looks exactly like a disabled one. Falls back
# to ad-hoc, which sign.sh warns about, when there is no single obvious choice.
SIGN_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null | \
             sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | \
             sort -u | awk 'NR==1 { only = $$0 } END { if (NR == 1) print only }')
# Team ID is baked into the entitlements at sign time. Derived from the
# provisioning profile so there is one source of truth.
TEAM_ID ?= $(shell security cms -D -i Extension/Ext4FS.provisionprofile 2>/dev/null | \
             plutil -extract TeamIdentifier.0 raw - 2>/dev/null)
# Optional: a dedicated keychain holding only the signing identity. Use this if
# codesign reports errSecInternalComponent from a cluttered login keychain.
SIGN_KEYCHAIN ?=

sign: app entitlements
	@SIGN_KEYCHAIN="$(SIGN_KEYCHAIN)" bash scripts/sign.sh "$(BUILD)/$(APP_NAME).app" "$(SIGN_ID)"

# Expand the entitlements template with the team ID from the profile.
entitlements:
	@test -n "$(TEAM_ID)" || { echo "error: could not read TeamIdentifier from Extension/Ext4FS.provisionprofile"; exit 1; }
	@sed -e 's/@TEAM_ID@/$(TEAM_ID)/g' \
	     -e 's/@BUNDLE_ID@/$(BUNDLE_ID).$(EXT_NAME)/g' \
	     Extension/Ext4FS.entitlements.in > Extension/Ext4FS.entitlements
	@sed -e 's/@TEAM_ID@/$(TEAM_ID)/g' \
	     -e 's/@BUNDLE_ID@/$(BUNDLE_ID)/g' \
	     App/Ext4Mac.entitlements.in > App/Ext4Mac.entitlements
	@echo "entitlements: team $(TEAM_ID), app id $(TEAM_ID).$(BUNDLE_ID).$(EXT_NAME)"

# --- Disk Utility integration ------------------------------------------------
# FSKit is enough to mount, and enough for newfs_fskit/fsck_fskit on the
# command line. `diskutil listFilesystems` and Disk Utility's Erase menu are a
# separate mechanism: they read .fs bundles from /Library/Filesystems. This
# installs a plist-only bundle whose formatter is a wrapper around newfs_fskit,
# so there is still exactly one implementation.
FS_BUNDLE_SRC := Packaging/ext4.fs
# `override` so the destination cannot be replaced from the command line.
# These two targets run as root and both begin with `rm -rf $(FS_BUNDLE_DEST)`;
# a make variable that a caller can set is not something to point that at.
override FS_BUNDLE_DEST := /Library/Filesystems/ext4.fs

install-diskutil:
	@test "$$(id -u)" = "0" || { echo "needs root: sudo make install-diskutil"; exit 1; }
	@test "$(FS_BUNDLE_DEST)" = "/Library/Filesystems/ext4.fs" || { echo "refusing: unexpected destination"; exit 1; }
	@test -f "$(FS_BUNDLE_SRC)/Contents/Info.plist" || { echo "missing $(FS_BUNDLE_SRC)"; exit 1; }
	@rm -rf "$(FS_BUNDLE_DEST)"
	@cp -R "$(FS_BUNDLE_SRC)" "$(FS_BUNDLE_DEST)"
	@chown -R root:wheel "$(FS_BUNDLE_DEST)"
	@chmod -R go-w "$(FS_BUNDLE_DEST)"
	@echo "installed $(FS_BUNDLE_DEST)"
	@echo "verify with: diskutil listFilesystems | grep -i ext"
	@echo "remove with: sudo make uninstall-diskutil"

uninstall-diskutil:
	@test "$$(id -u)" = "0" || { echo "needs root: sudo make uninstall-diskutil"; exit 1; }
	@test "$(FS_BUNDLE_DEST)" = "/Library/Filesystems/ext4.fs" || { echo "refusing: unexpected destination"; exit 1; }
	@rm -rf "$(FS_BUNDLE_DEST)"
	@echo "removed $(FS_BUNDLE_DEST)"

install: sign
	@rm -rf "/Applications/$(APP_NAME).app"
	@cp -R "$(BUILD)/$(APP_NAME).app" /Applications/
	@echo "installed to /Applications/$(APP_NAME).app"
	@echo "Enable it in System Settings > General > Login Items & Extensions > File System Extensions"
