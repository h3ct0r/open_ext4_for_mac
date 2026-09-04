# open_ext4_for_mac — build system
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Deliberately plain make + swiftc: full Xcode is NOT required to build this
# project, only the Command Line Tools. Xcode is needed only if you prefer its
# signing workflow; `make sign` uses codesign directly.

# macOS is the product; Linux is the oracle. See the TARGET_FLAG block below.
HOST_OS       := $(shell uname -s)

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
# Overridable so that cache pressure is a dimension the tests can vary. lwext4
# writes a dirty buffer out when the cache fills, and whether it does that
# before or after the transaction owning it has committed is a correctness
# question -- one that only shows up under pressure, which a large cache hides.
BCACHE_BLOCKS ?= 1024

LWEXT4_DEFS := -DCONFIG_USE_DEFAULT_CFG=1 \
               -DCONFIG_BLOCK_DEV_CACHE_SIZE=$(BCACHE_BLOCKS) \
               -DCONFIG_DEBUG_PRINTF=0 \
               -DCONFIG_DEBUG_ASSERT=1 \
               -D'EXT_FINCOM_IGNORED=(EXT4_FINCOM_RECOVER | EXT4_FINCOM_MMP | EXT4_FINCOM_BG_USE_META_CSUM)'

INCLUDES := -I$(LWEXT4_DIR)/include -I$(LWEXT4_DIR)/include/misc -I$(SHIM_DIR) -I$(CRYPTO_DIR)

# Shared/ is compiled into both the extension and the container app. It holds
# what they have in common and cannot pass between them any other way -- an app
# extension has no IPC back to its host: the keychain items an encrypted
# volume's master key travels in, and the volume events the extension writes
# because it has no other way to tell anybody anything.
SHARED_SRCS := $(wildcard Shared/*.swift)

# The event store, driven directly by a test.
#
# Nearly everything that can be wrong with that store -- a half-written file
# the app reads mid-write, a log that grows without bound, a label off a
# stranger's disk that becomes a path, a schema that does not survive a round
# trip -- has nothing to do with FSKit and needs no mounted volume, no
# installed extension and nobody to approve anything. This binary links the
# same Shared/ sources both bundles do and exercises them offline.
#
# Never shipped: nothing in the app or the appex links it. macOS only, because
# there is no swiftc on the Linux oracle runner; the suite skips there.
ifeq ($(HOST_OS),Linux)
  EVENT_PROBE :=
else
  EVENT_PROBE := $(BUILD)/bin/event_probe
endif

ifeq ($(CONFIG),debug)
  OPT := -O0 -g -fsanitize=address,undefined
else ifeq ($(CONFIG),cov)
  # Source-level coverage for the fuzz harness: same compiler, same target,
  # but LLVM's instrumentation-based profiling instead of the sanitizers, so
  # the HTML report shows which LINES a campaign reached rather than only
  # which functions. Sanitizers are off deliberately -- a coverage report is
  # a map, not a bug hunt, and ASan's shadow triples the run time of a sweep
  # over the whole corpus.
  FUZZ_CC ?= /opt/homebrew/opt/llvm/bin/clang
  CC      := $(FUZZ_CC)
  OPT     := -O1 -g -fprofile-instr-generate -fcoverage-mapping \
             -fsanitize=fuzzer-no-link
else ifeq ($(CONFIG),fuzz)
  # The in-process libFuzzer harness, and only it.
  #
  # Apple's Command Line Tools clang ships no libclang_rt.fuzzer_osx.a, so
  # -fsanitize=fuzzer fails at link; it accepts -fsanitize=fuzzer-no-link and
  # the coverage flags at compile time, but there is nothing to link against.
  # Homebrew's LLVM ships the runtime and builds, links and runs the target
  # against the CLT SDK. So this configuration is the one place in the build
  # that needs a second compiler, and `make validate` never reaches it.
  #
  # -fsanitize=fuzzer-no-link on the *core* objects is the whole point: that
  # is what gives libFuzzer edge coverage inside lwext4 rather than only
  # inside the harness. -O1 is ASan's throughput sweet spot.
  #
  # Nothing built here can reach the shipping extension: objects and libraries
  # carry the CONFIG in their path (see OBJ below), so build/obj/fuzz and
  # build/lib/fuzz are a world of their own, and the appex rule refuses to
  # link anything but a release core.
  FUZZ_CC ?= /opt/homebrew/opt/llvm/bin/clang
  CC      := $(FUZZ_CC)
  #
  # -fno-sanitize-recover=undefined is not a detail. By default UBSan PRINTS
  # "runtime error: ..." and carries on, so a campaign finds undefined
  # behaviour, says so once in a log nobody reads, writes no artifact, and
  # reports itself green. The first 30-second run here did exactly that with
  # a null-pointer offset in the xattr parser. Fatal, so it becomes a crash
  # with the input attached, like every other finding.
  OPT     := -O1 -g -fno-omit-frame-pointer \
             -fsanitize=address,undefined -fno-sanitize-recover=undefined \
             -fsanitize=fuzzer-no-link
else
  OPT := -O2 -g
endif

# Which source a running binary was built from. The signed-bundle CDHash that
# check_install_freshness.sh compares cannot be embedded in the binary it
# signs, and a stale installed extension has now cost three debugging sessions
# -- most recently a field log line that looked like today's build and was not.
BUILD_ID := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)$(shell git diff --quiet 2>/dev/null || echo -dirty)

# EXTRA_CFLAGS is an injection point for one-off diagnostic builds, e.g.
#   make EXTRA_CFLAGS=-DEXT4B_NO_UNWRITTEN_FASTPATH=1 app
# Changing it does not invalidate objects, so clear build/obj when switching.
CFLAGS := $(OPT) -fno-common -Wall $(INCLUDES) $(LWEXT4_DEFS) -DEXT4B_BUILD_ID=\"$(BUILD_ID)\" $(EXTRA_CFLAGS)
# lwext4 is third-party embedded C; its warnings are not actionable for us.
# -Wno-everything is clang's spelling and gcc does not have it: gcc accepts the
# option and then complains about it inside every later diagnostic, which is
# noisier than not passing it at all. -w means the same thing to both.
ifeq ($(HOST_OS),Linux)
  NO_WARN := -w
else
  NO_WARN := -Wno-everything
endif
LWEXT4_CFLAGS := $(CFLAGS) $(NO_WARN)
SHIM_CFLAGS   := $(CFLAGS) -Wextra -Wno-unused-parameter

# Which system this build runs on. macOS is the product. Linux is the oracle:
# the CI job that takes what this driver wrote, mounts it with the real ext4
# and reports whether the kernel agrees. Only tools/ is built there -- there is
# no FSKit to link against and no extension to sign, and `make app` on Linux
# says that rather than failing somewhere in swiftc.
#
# Two things differ, and they are the only two. There is no -target: the
# oracle runs on whatever the runner is, x86_64 today and arm64 whenever
# GitHub makes that the default, and naming an architecture here would be
# choosing one for no reason. And the core needs -lcrypto, because
# Core/crypto/crypto_portable.h reaches OpenSSL where macOS has CommonCrypto.
ifeq ($(HOST_OS),Linux)
  TARGET_FLAG :=
  CORE_LDLIBS := -lcrypto
else
  TARGET_FLAG := -target arm64-apple-macos$(DEPLOY_TARGET)
  CORE_LDLIBS :=
endif

ifneq ($(filter $(CONFIG),fuzz cov),)
  # Homebrew clang has no default macOS SDK: without this it finds no
  # <stdio.h> at all, which reads as the project failing to compile rather
  # than as a missing -isysroot. Appended after TARGET_FLAG is defined, not
  # inside the OPT block above, because that block runs before this line and a
  # `+=` there would be overwritten by this assignment.
  FUZZ_SDK    := $(shell xcrun --show-sdk-path)
  TARGET_FLAG += -isysroot $(FUZZ_SDK)
endif

# Objects and libraries carry the CONFIG in their path. Two reasons:
#
#  * A debug/ASan object must never silently link into a release appex. When
#    objects all landed in build/obj/, `make tools CONFIG=debug` then `make
#    app` linked the -O0 instrumented core into the shipping extension,
#    because make saw the objects as up to date.
#  * Only the *shim* differs between the shipping and test builds: lwext4,
#    crypto and argon2 objects are profile-independent, so they are compiled
#    once per config and shared by both libraries. The shim is compiled twice
#    -- plain for shipping, and with EXT4B_TEST_HOOKS for the tools, which is
#    how the orphan-inspection hooks (and any getenv) stay out of the appex's
#    symbol set entirely.
OBJ := $(BUILD)/obj/$(CONFIG)

LWEXT4_SRCS := $(wildcard $(LWEXT4_DIR)/src/*.c)
LWEXT4_OBJS := $(patsubst $(LWEXT4_DIR)/src/%.c,$(OBJ)/lwext4/%.o,$(LWEXT4_SRCS))

SHIM_NAMES     := ext4_bridge ext4_check
SHIM_OBJS      := $(patsubst %,$(OBJ)/shim/%.o,$(SHIM_NAMES))
SHIM_TEST_OBJS := $(patsubst %,$(OBJ)/shim-test/%.o,$(SHIM_NAMES))

# Block-level decryption, for ext4 inside a LUKS container. It sits below the
# filesystem, decorating the same read/write/flush callbacks ext4b_device_create
# already takes, so lwext4 never learns that anything is encrypted.
CRYPTO_SRCS := $(wildcard $(CRYPTO_DIR)/*.c)
CRYPTO_OBJS := $(patsubst $(CRYPTO_DIR)/%.c,$(OBJ)/crypto/%.o,$(CRYPTO_SRCS))

# Argon2, vendored unmodified for LUKS2 key derivation; see
# Core/crypto/argon2/README.md. Third-party, so its warnings are silenced the
# same way lwext4's are -- they are not ours to act on.
ARGON2_DIR  := $(CRYPTO_DIR)/argon2
ARGON2_SRCS := $(ARGON2_DIR)/argon2.c $(ARGON2_DIR)/core.c $(ARGON2_DIR)/ref.c \
               $(ARGON2_DIR)/thread.c $(ARGON2_DIR)/encoding.c \
               $(ARGON2_DIR)/blake2/blake2b.c
ARGON2_OBJS := $(patsubst $(CRYPTO_DIR)/%.c,$(OBJ)/crypto/%.o,$(ARGON2_SRCS))
ARGON2_CFLAGS := $(CFLAGS) $(NO_WARN) -I$(ARGON2_DIR)

# The shipping library (shim built plain) and the test library (shim built
# with EXT4B_TEST_HOOKS). lwext4/crypto/argon2 objects are shared.
CORE_LIB      := $(BUILD)/lib/$(CONFIG)/libext4core.a
CORE_TEST_LIB := $(BUILD)/lib/$(CONFIG)/libext4core-test.a

.PHONY: all core verify-patches clean test test-asan test-crash test-diff test-format test-prealloc test-newfs test-revoke test-bounds test-fuzz test-fuzz-regressions test-reorder test-crypto test-events test-orphan test-luks test-eio test-csum test-fragmentation test-scale soak test-mount-crash test-mount-luks test-replay-speed test-kill-recovery test-pull check-extension check-signing check-ship-surface validate validate-asan tools entitlements check-submodule check-patches patch repatch unpatch extension app sign install typecheck install-diskutil uninstall-diskutil uninstall-barrier preflight prepare-device dmg notarize staple ci-offline ci-linux print-fuzz-flags fuzz-build fuzz fuzz-rw fuzz-repro fuzz-minimize fuzz-merge fuzz-check fuzz-cov fuzz-cov-gate

all: app

check-submodule:
	@test -f $(LWEXT4_DIR)/include/ext4.h || { \
	  echo "error: lwext4 submodule missing. Run: git submodule update --init"; \
	  exit 1; }

core: check-submodule verify-patches $(CORE_LIB)

# Vendored-dependency patches.
#
# The stamp file makes patching a real prerequisite of every object file. An
# earlier version listed a phony `patch` target on `core`, which compiled fine
# but was silently skipped whenever make reached $(CORE_LIB) through another
# path (`make app`), producing a library built from unpatched sources.
PATCHES     := $(sort $(wildcard patches/lwext4/*.patch))
PATCH_STAMP := $(BUILD)/.lwext4-patched

# The authoritative test is the sequential replay in check_patches.sh: apply
# everything to the pinned commit, diff against the tree. Per-patch checks
# cannot be: a later patch may edit lines an earlier one introduced (0021
# adjusts the purge loop 0020 wrote), and then the earlier patch fails a
# reverse-check on a tree that is exactly right. So: if the replay proves the
# tree, stamp it. Only when it does not, try to bring a clean checkout up by
# applying whatever is missing, then prove it again.
$(PATCH_STAMP): $(PATCHES) | check-submodule
	@mkdir -p $(dir $@)
	@if bash scripts/check_patches.sh >/dev/null 2>&1; then touch $@; exit 0; fi; \
	failed=""; \
	for p in $(PATCHES); do \
	  if git -C $(LWEXT4_DIR) apply "$(CURDIR)/$$p" 2>/dev/null; then \
	    echo "applied $$p"; \
	  else \
	    failed="$$failed $$p"; \
	  fi; \
	done; \
	if bash scripts/check_patches.sh >/dev/null 2>&1; then :; \
	elif [ -n "$(ALLOW_UNAPPLIED_PATCHES)" ]; then \
	  echo "note: working tree does not match the patch set (ALLOW_UNAPPLIED_PATCHES)"; \
	else \
	  bash scripts/check_patches.sh; \
	  if [ -n "$$failed" ]; then \
	    echo "  patches that did not apply cleanly (already present, or in conflict):"; \
	    for p in $$failed; do echo "    $$p"; done; \
	  fi; \
	  echo "  Set ALLOW_UNAPPLIED_PATCHES=1 while developing a patch, or run"; \
	  echo "  'make repatch' to reset the submodule to pinned-plus-patches."; \
	  exit 1; \
	fi
	@touch $@

patch: $(PATCH_STAMP)

# The stamp records that the patches were applied once. It cannot know they
# still are: `git checkout -- src/foo.c` inside the submodule reverts every
# patch touching that file and leaves the stamp cheerfully claiming otherwise.
# The build then succeeds, and the result is a driver missing fixes it appears
# to have -- reverting 0009 alone puts a wrong free-block count on every volume
# this thing formats, which reads as a fresh bug in whatever you were working
# on rather than as a missing patch.
#
# So verify instead of trusting, and re-apply if anything is gone. Fourteen
# There are three states, not two, and conflating the last two is its own trap.
# A patch may be applied (the reverse-check succeeds), missing (the forward
# check succeeds, so re-apply it), or neither -- which means the file has been
# edited further, which is exactly what developing a new patch looks like. The
# first version re-applied in that case and broke the build.
#
# `git apply --check` runs cost milliseconds; the confusion costs an hour.
# One question, asked the strong way: does replaying the patch set onto the
# pinned commit reproduce this tree? (Per-patch reverse-checks used to live
# here and were wrong twice over -- blind to direct submodule edits, and
# falsely alarmed by stacked patches that edit each other's lines.)
# ALLOW_UNAPPLIED_PATCHES exempts a tree that is mid-patch-development -- the
# working tree legitimately leads the patch set while a fix is being built --
# but prints a note, so forgetting to regenerate stays visible.
verify-patches: $(PATCH_STAMP)
	@if [ -n "$(ALLOW_UNAPPLIED_PATCHES)" ]; then \
	  bash scripts/check_patches.sh >/dev/null 2>&1 || \
	    echo "note: working tree leads the patch set (ALLOW_UNAPPLIED_PATCHES)"; \
	else \
	  bash scripts/check_patches.sh >/dev/null || { \
	    bash scripts/check_patches.sh; exit 1; }; \
	fi

# Does the patch set reproduce the tree we compile? verify-patches asks whether
# each patch is applied; this asks the stronger question, which is whether the
# working tree contains anything the patches do not.
check-patches:
	@bash scripts/check_patches.sh

# Put the submodule back to pinned-plus-patches, whatever state it is in.
#
# `git checkout -- src/foo.c` inside the submodule reverts to the *pinned*
# commit, silently discarding every patch that touches that file -- the trap
# the comment above describes, which is easy to spring while trying to undo
# something unrelated. The repair is deterministic and check-patches proves it,
# but only if you know what it is.
#
# Destructive by design: it discards uncommitted edits in Core/lwext4. Run
# `make check-patches` first if there might be work there worth keeping.
repatch: check-submodule
	@pinned=$$(git ls-tree HEAD Core/lwext4 | awk '{print $$3}'); \
	git -C $(LWEXT4_DIR) reset -q --hard $$pinned; \
	for p in $(PATCHES); do \
	  git -C $(LWEXT4_DIR) apply "$(CURDIR)/$$p" || { echo "failed: $$p"; exit 1; }; \
	done; \
	rm -f $(PATCH_STAMP); \
	bash scripts/check_patches.sh

unpatch:
	@for p in $(PATCHES); do \
	  git -C $(LWEXT4_DIR) apply --reverse "$(CURDIR)/$$p" 2>/dev/null && echo "reverted $$p" || true; \
	done
	@rm -f $(PATCH_STAMP)

# The header dependency is not decoration. A struct in ext4_journal.h grew a
# field during development; only ext4_journal.o was rebuilt, every other
# object kept the old layout, and the result was a binary that segfaulted --
# silently, when its output was piped -- while a test sweep read its
# untouched images as a clean pass.
LWEXT4_HEADERS := $(wildcard $(LWEXT4_DIR)/include/*.h $(LWEXT4_DIR)/include/misc/*.h)

$(OBJ)/lwext4/%.o: $(LWEXT4_DIR)/src/%.c $(LWEXT4_HEADERS) $(PATCH_STAMP)
	@mkdir -p $(dir $@)
	$(CC) $(TARGET_FLAG) $(LWEXT4_CFLAGS) -c $< -o $@

# Shipping shim: no test hooks, no getenv.
# The build id is compiled in, so these have to rebuild when the revision
# changes even though no source file did -- otherwise the log lines keep
# naming the commit they were first built at while the re-stamped plists name
# the current one, and a hardware session reads as fresh when it is not.
$(OBJ)/shim/%.o: $(SHIM_DIR)/%.c $(SHIM_DIR)/ext4_bridge.h $(LWEXT4_HEADERS) $(PATCH_STAMP) $(BUILD)/.build-id
	@mkdir -p $(dir $@)
	$(CC) $(TARGET_FLAG) $(SHIM_CFLAGS) -c $< -o $@

# Test shim: EXT4B_TEST_HOOKS exposes the orphan-inspection API the suites use.
$(OBJ)/shim-test/%.o: $(SHIM_DIR)/%.c $(SHIM_DIR)/ext4_bridge.h $(LWEXT4_HEADERS) $(PATCH_STAMP) $(BUILD)/.build-id
	@mkdir -p $(dir $@)
	$(CC) $(TARGET_FLAG) $(SHIM_CFLAGS) -DEXT4B_TEST_HOOKS=1 -c $< -o $@

$(OBJ)/crypto/argon2/%.o: $(ARGON2_DIR)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(TARGET_FLAG) $(ARGON2_CFLAGS) -c $< -o $@

$(OBJ)/crypto/%.o: $(CRYPTO_DIR)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(TARGET_FLAG) $(SHIM_CFLAGS) -I$(ARGON2_DIR) -c $< -o $@

$(CORE_LIB): $(LWEXT4_OBJS) $(SHIM_OBJS) $(CRYPTO_OBJS) $(ARGON2_OBJS)
	@mkdir -p $(dir $@)
	@rm -f $@
	ar rcs $@ $^
	@echo "built $@"

$(CORE_TEST_LIB): $(LWEXT4_OBJS) $(SHIM_TEST_OBJS) $(CRYPTO_OBJS) $(ARGON2_OBJS)
	@mkdir -p $(dir $@)
	@rm -f $@
	ar rcs $@ $^
	@echo "built $@"

# --- test tooling ------------------------------------------------------------
# ext4dump drives the core against a plain file, with no FSKit, no signing and
# no mounting. This is what makes the core testable in CI.
#
# The binaries live at one path whatever the CONFIG, because fifteen suites
# name build/bin/ext4dump. That makes them the one place the per-CONFIG object
# tree does not protect: after `make tools CONFIG=debug`, a plain `make tools`
# finds the binary newer than the release library and leaves the ASan build
# sitting there. Every suite then measures the sanitizer build while its
# output says nothing about it -- and a bounds run reported 52 assertions
# instead of 50 for exactly that reason, which is the harmless version of the
# same mistake.
#
# `make validate` and `make test-asan` both begin with `make clean`, so the
# two entry points that matter were never wrong; a developer switching by hand
# was. The stamp makes the config a prerequisite, so switching relinks.
$(BUILD)/.tools-config: FORCE
	@mkdir -p $(BUILD)
	@printf '%s' "$(CONFIG)" | cmp -s - $@ 2>/dev/null || printf '%s' "$(CONFIG)" > $@

tools: verify-patches $(BUILD)/bin/ext4dump $(BUILD)/bin/cryptotest $(BUILD)/bin/datafile $(BUILD)/bin/ext4_stampcheck $(EVENT_PROBE)

# The fuzzing stamper's oracle. Built with the ordinary compiler and linked
# against nothing of ours -- it is a SECOND implementation of ext4's
# checksums, and it exists to disagree with the first one when the first one
# is wrong. Needs no libFuzzer, so `make validate` can run it.
$(BUILD)/bin/ext4_stampcheck: tools/fuzz/ext4_stampcheck.c tools/fuzz/ext4_csum.c tools/fuzz/ext4_csum.h $(BUILD)/.tools-config
	@mkdir -p $(dir $@)
	$(CC) $(TARGET_FLAG) $(OPT) -Wall -Wextra -Itools/fuzz \
	    tools/fuzz/ext4_stampcheck.c tools/fuzz/ext4_csum.c -o $@

# Known-answer tests for the crypto primitives, against vectors generated by
# OpenSSL rather than transcribed by hand. See Tests/gen_xts_vectors.sh.
# Links nothing of ours: it drives a MOUNTED volume through ordinary syscalls,
# which is the point. A helper that went through the core could not tell us
# whether the core and FSKit disagree.
# tools/events/main.swift, not event_probe.swift: swiftc allows top-level
# statements in a file called main.swift and nowhere else, and a 90-line test
# driver reads better as a script than as a @main struct wrapped around one.
$(BUILD)/bin/event_probe: tools/events/main.swift $(SHARED_SRCS)
	@mkdir -p $(dir $@)
	swiftc -target arm64-apple-macos$(DEPLOY_TARGET) -swift-version 5 -O \
	    $(SHARED_SRCS) tools/events/main.swift -o $@
	@echo "built $@"

$(BUILD)/bin/datafile: tools/datafile.c $(BUILD)/.tools-config
	@mkdir -p $(dir $@)
	$(CC) $(TARGET_FLAG) $(OPT) -Wall -Wextra -o $@ $<

$(BUILD)/bin/cryptotest: tools/cryptotest.c $(CORE_TEST_LIB) $(BUILD)/.tools-config
	@mkdir -p $(dir $@)
	$(CC) $(TARGET_FLAG) $(CFLAGS) $< $(CORE_TEST_LIB) $(CORE_LDLIBS) -o $@

# The volume-event store: what the extension writes when it has to refuse a
# volume, and what the app reads back. Offline -- no mount, no installed
# extension, nobody approving anything.
test-events: tools
	@bash Tests/run_events_tests.sh

test-crypto: $(BUILD)/bin/cryptotest
	@$(BUILD)/bin/cryptotest

# The tool is compiled with EXT4B_TEST_HOOKS so the header exposes the
# orphan-inspection declarations it calls, and links the test library that
# actually defines them.
$(BUILD)/bin/ext4dump: tools/ext4dump.c $(CORE_TEST_LIB) $(BUILD)/.build-id $(BUILD)/.tools-config
	@mkdir -p $(dir $@)
	$(CC) $(TARGET_FLAG) $(CFLAGS) -DEXT4B_TEST_HOOKS=1 $< $(CORE_TEST_LIB) $(CORE_LDLIBS) -o $@

test: tools
	@bash Tests/run_tests.sh
	@echo
	@bash Tests/run_write_tests.sh

test-reorder: tools
	@bash Tests/run_reorder_tests.sh

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

test-prealloc: tools
	@bash Tests/run_prealloc_tests.sh

# The live formatter: needs the extension installed and enabled.
test-newfs:
	@bash Tests/run_newfs_tests.sh

# Every revoke block in the journal, entry by entry. Offline, seconds.
test-revoke: tools
	@bash Tests/run_revoke_tests.sh

# Bounds, overflow, and POSIX-semantics checks. Offline, seconds.
# The mounted data path: does a file written through a real FSKit mount read
# back byte-exact? Runs on attached images, so it needs no hardware and no
# operator -- but it does need the extension installed and enabled.
test-mount-data: tools
	@bash Tests/run_mount_data_tests.sh

test-bounds: tools
	@bash Tests/run_bounds_tests.sh

# Mutated images against the offline driver, with no special toolchain: the
# fuzzing that runs in `make validate`. Against a release build it detects
# crashes, hangs and writes; under `make test-asan` the same mutants become a
# memory-safety sweep, which is a strictly wider claim and the suite says
# which one it is making.
#
# FUZZ_COUNT=300 mutants, FUZZ_SEED=1; the soak passes its round number so a
# long soak is a long campaign rather than the same mutants over and over.
test-fuzz: tools
	@bash Tests/run_fuzz_tests.sh

# Every image that was once a finding, run again. Seconds, offline, and the
# thing that stops a fixed bug coming back. Rows that were memory-safety
# findings only assert anything under `make test-asan`, and the suite says so.
test-fuzz-regressions: tools
	@bash Tests/run_fuzz_regressions_tests.sh

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

# Journal replay priced like the medium that produced the incident: a deep
# dirty journal inside LUKS, replayed against a modelled USB stick, inside
# DiskArbitration's ~20s mount budget.
test-replay-speed: tools
	@bash Tests/run_replay_speed_tests.sh

# A medium that answers EIO, aimed at the paths that historically swallowed
# it. Every cell asserts the fault fired AND the failure surfaced.
test-eio: tools
	@bash Tests/run_eio_tests.sh

# A bitmap whose checksum does not verify. Corrupts one byte from outside the
# driver, then asks both halves: was the write refused, and did the checksum
# survive untouched. The second is the one that matters -- the old behaviour
# passed the first while rewriting the checksum over the corruption.
test-csum: tools
	@bash Tests/run_csum_tests.sh

# What interleaved allocation costs. The same bytes to the same files in two
# orders, one mount, no threads and no timing: the difference is the whole
# 89%-non-contiguous field result, and the reservation that closes it has to
# give its space back as well as reduce the extent count.
test-fragmentation: tools
	@bash Tests/run_fragmentation_tests.sh

# Volumes and files past 4 GiB, which is where a byte count stops fitting in
# 32 bits. Writes ~4.5 GiB through a real mount, so it is opt-in: this target
# sets SLOW=1 for you.
test-scale: tools
	@SLOW=1 bash Tests/run_scale_tests.sh

# The full set, over and over, stopping dead at the first failure. Not a
# pass rate: the question is whether this ever loses data, and "usually not"
# is not an answer. SOAK_ROUNDS=N to bound it.
soak:
	@bash scripts/soak.sh

# What a killed driver leaves behind, and whether the journal recovers it.
# Passes on a disk image; EXT4_KILL_DEVICE=diskN points it at real media,
# which it ERASES. preflight checks the hand-granted switches (extension
# enabled, .fs bundle installed) before spending the run, not after -- none
# of them announces itself when it lapses.
preflight: tools
	@bash scripts/preflight.sh $(EXT4_KILL_DEVICE)

# `tools` is not decoration: the suite formats its target with ext4dump, and
# after `make clean` a hardware run would pass preflight, fail the format, and
# report "could not prepare the volume" -- on the one day that costs the most.
test-kill-recovery: preflight test-mount-data tools
	@bash Tests/run_kill_recovery_tests.sh

# Gated on test-mount-data, not just preflight. Preflight asks whether the
# switches are on; it cannot tell you the build corrupts files. A hardware
# session that starts against such a build spends an operator's evening
# measuring damage the offline suite would have found in ninety seconds --
# which is how the extent-split corruption reached a real stick.
# The hands-on suite: the operator pulls the stick on cue. Erases the device
# every round. See the header of the script for the safety notes.
test-pull: preflight test-mount-data tools
	@bash Tests/run_pull_tests.sh

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

# The subset a GitHub runner can run: no Docker, no mounted extension, no
# hands. Exactly what .github/workflows/ci.yml calls, so this is how you find
# out whether CI will be green before you push rather than after.
ci-offline:
	@bash scripts/ci_offline.sh

# The other half, and it only runs where the oracle is. On macOS the same five
# suites reach a Linux kernel through Docker one at a time; this is the set as
# CI runs it, with the kernel underfoot instead of in a container.
ci-linux:
	@bash scripts/ci_linux.sh

# Same suites under AddressSanitizer + UBSan. Slower, but this is how the
# NULL dereference in lwext4's xattr removal was found.
test-asan:
	@$(MAKE) --no-print-directory clean
	@$(MAKE) --no-print-directory tools CONFIG=debug
	@bash Tests/run_tests.sh
	@echo
	@# The corrupt-fixture cells exist to catch memory unsafety; running
	@# them without the sanitizer watching would test half their point.
	@bash Tests/run_bounds_tests.sh
	@echo
	@bash Tests/run_eio_tests.sh
	@echo
	@bash Tests/run_write_tests.sh
	@echo
	@# The mutation campaign, and every image that was once a finding.
	@# Both are worth far more here than in a release build: against
	@# release they see crashes, hangs and writes; here they see memory
	@# unsafety, which is what most of the hostile corpus was. Measured --
	@# 200 superblock-targeted mutants give zero findings against release
	@# and five heap-buffer-overflows here.
	@bash Tests/run_fuzz_tests.sh
	@echo
	@bash Tests/run_fuzz_regressions_tests.sh

clean:
	rm -rf $(BUILD)

# --- fuzzing ------------------------------------------------------------------
# An in-process libFuzzer target driving the same device seam ext4dump uses,
# against mutated images held in memory. A filesystem driver mounts untrusted
# media; every corruption bug found in this project so far lived in a surface a
# fuzzer would have reached first.
#
# Built ONLY with Homebrew clang, into CONFIG=fuzz. `make validate` never needs
# it: the toolchain-free Python mutation campaign is what runs in validation,
# and this is the deeper instrument for someone who has the runtime.
#
#   make fuzz-build                 build build/bin/ext4_fuzz
#   make fuzz                       10 minutes, read-only mode
#   make fuzz-rw FUZZ_TIME=3600     an hour, read-write mode
#   make fuzz-repro FILE=.fuzz/crashes/crash-abc   one input, symbolised
#   make fuzz-minimize FILE=...     shrink a crashing input
#   make fuzz-merge                 distil the corpus to its covering subset
#
# Durable state lives in .fuzz/, deliberately NOT under build/: a validation
# round begins with `make clean`, and a corpus that a round deletes is a corpus
# that never grows. .soak/ exists for the same reason.
FUZZ_DIR   := .fuzz
FUZZ_TIME  ?= 600
# Per-input deadline. A hang here is a finding; on a shared ASan runner it is
# also sometimes just a slow minute, so the CI smoke raises it to 60.
FUZZ_TIMEOUT ?= 20
FUZZ_JOBS  ?= 4
FUZZ_CC    ?= /opt/homebrew/opt/llvm/bin/clang

# Every source under tools/fuzz/ except the ones carrying their own main().
# A wildcard so that the later phases add a file rather than edit this line.
FUZZ_SRCS  := $(filter-out tools/fuzz/ext4_stampcheck.c,$(wildcard tools/fuzz/*.c))
FUZZ_BIN   := $(BUILD)/bin/ext4_fuzz

# Common flags for a libFuzzer run. -max_len covers the largest seed (8 MiB);
# -rss_limit_mb is generous because ASan's shadow accounts against it.
#
# Absolute paths throughout: the recipes below cd into $(FUZZ_DIR)/logs first,
# because -jobs=N makes libFuzzer scatter fuzz-0.log..fuzz-N.log into the
# working directory. A relative -dict= or -artifact_prefix= would then be
# resolved from there -- the dictionary silently not loading, which reads as a
# campaign that simply is not finding much.
#
# Two memory limits, not one, because they mean different things.
# -malloc_limit_mb catches a SINGLE allocation the driver was talked into by
# an input -- a corrupt count multiplied by a size -- which is a finding with
# an input attached. -rss_limit_mb catches total process memory, and on a
# filesystem fuzzer that is dominated by the corpus: seeds are megabytes, so
# five hundred inputs is gigabytes, and a run hits the limit with no input to
# blame. The first 2048 MB run produced exactly that -- a zero-byte oom
# artifact at corpus 294/1202Mb, rss 2098. Generous rss, tight malloc.
FUZZ_ARGS  := -dict=$(CURDIR)/tools/fuzz/ext4.dict -max_len=8388608 \
              -rss_limit_mb=4096 -malloc_limit_mb=512 \
              -use_value_profile=1 -detect_leaks=0 \
              -artifact_prefix=$(CURDIR)/$(FUZZ_DIR)/crashes/ \
              -max_total_time=$(FUZZ_TIME) -jobs=$(FUZZ_JOBS) -workers=$(FUZZ_JOBS)

# The guard is on the runtime file, not on a version string: Homebrew's LLVM
# moves, and what actually matters is whether libclang_rt.fuzzer_osx.a sits
# next to the compiler's own runtime. Exit 77 (SKIP), not 1: a machine without
# it has not failed anything, it just cannot run this.
# What scripts/fuzz_build.sh stamps, so that a flag change invalidates the
# fuzz objects. Everything that decides the generated code, and nothing that
# does not: the build id changes on every commit and would rebuild the world.
print-fuzz-flags:
	@echo "$(CC)|$(OPT)|$(TARGET_FLAG)|$(LWEXT4_DEFS)|$(EXTRA_CFLAGS)"

# The guard lives in the script, not here, because make collapses a recipe's
# exit code into its own 2: a caller that needs to tell "no libFuzzer runtime
# on this machine" (77, a SKIP) from "the harness does not compile" (a
# failure) has to run scripts/fuzz_build.sh directly. This target is the
# convenience wrapper for a human at a terminal.
fuzz-build:
	@FUZZ_CC="$(FUZZ_CC)" bash scripts/fuzz_build.sh

# Linked with the full -fsanitize=fuzzer (the core objects carry
# fuzzer-no-link), and with EXT4B_TEST_HOOKS so the harness can reach the
# orphan-inspection API and the deliberate-assert hook.
# Two links, because Homebrew clang and Xcode's linker do not always agree.
# Objects from a newer Homebrew clang carry relocations that an older Xcode
# ld-prime rejects ("invalid r_symbolnum") -- which is what the fuzz job hit on
# a macos-15 runner with Xcode 16.4 -- while Apple's classic linker still reads
# them. Try the default linker first (it works here, and -ld_classic is
# deprecated), and only fall back when it fails. The fuzz binary never ships,
# so which linker built it is nobody's concern but the campaign's.
$(FUZZ_BIN): $(FUZZ_SRCS) $(CORE_TEST_LIB)
	@mkdir -p $(dir $@)
	$(CC) $(TARGET_FLAG) $(CFLAGS) -DEXT4B_TEST_HOOKS=1 \
	    -DEXT4_FUZZ_WEIGHTS_PATH='"$(CURDIR)/tools/fuzz/mutweights.json"' \
	    -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=undefined \
	    $(FUZZ_SRCS) $(CORE_TEST_LIB) $(CORE_LDLIBS) -o $@ 2>$@.ld.log \
	|| { echo "fuzz: default linker refused the objects; retrying with -ld_classic"; \
	     sed -n '1,3p' $@.ld.log; \
	     $(CC) $(TARGET_FLAG) $(CFLAGS) -DEXT4B_TEST_HOOKS=1 \
	        -DEXT4_FUZZ_WEIGHTS_PATH='"$(CURDIR)/tools/fuzz/mutweights.json"' \
	        -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=undefined \
	        -Wl,-ld_classic \
	        $(FUZZ_SRCS) $(CORE_TEST_LIB) $(CORE_LDLIBS) -o $@; }
	@rm -f $@.ld.log
	@echo "built $@"

# The seed corpus is generated, never committed: it is mke2fs output, and
# regenerating it is cheaper than versioning ten disk images.
$(FUZZ_DIR)/seeds/.stamp:
	@mkdir -p $(FUZZ_DIR)/seeds
	@if [ -x Tests/fuzz/make_seeds.sh ] || [ -f Tests/fuzz/make_seeds.sh ]; then \
	  bash Tests/fuzz/make_seeds.sh || exit $$?; \
	else \
	  echo "fuzz: Tests/fuzz/make_seeds.sh does not exist yet (phase A2)."; \
	  echo "      Running against an empty seed corpus finds nothing:"; \
	  echo "      libFuzzer would spend its whole budget inventing a"; \
	  echo "      superblock magic it will never guess."; \
	  exit 1; \
	fi
	@touch $@

fuzz: fuzz-build $(FUZZ_DIR)/seeds/.stamp
	@mkdir -p $(FUZZ_DIR)/corpus/ro $(FUZZ_DIR)/crashes $(FUZZ_DIR)/logs
	@cd $(FUZZ_DIR)/logs && EXT4_FUZZ_MODE=ro \
	  $(CURDIR)/$(FUZZ_BIN) $(CURDIR)/$(FUZZ_DIR)/corpus/ro $(CURDIR)/$(FUZZ_DIR)/seeds \
	  $(FUZZ_ARGS) -timeout=$(FUZZ_TIMEOUT)

# Read-write is a different question, not more of the same one: it is the only
# mode that runs jbd2 recovery and the dx split, and it is the only mode where
# a bug can write. Slower per input, hence the longer per-input timeout.
fuzz-rw: fuzz-build $(FUZZ_DIR)/seeds/.stamp
	@mkdir -p $(FUZZ_DIR)/corpus/rw $(FUZZ_DIR)/crashes $(FUZZ_DIR)/logs
	@cd $(FUZZ_DIR)/logs && EXT4_FUZZ_MODE=rw \
	  $(CURDIR)/$(FUZZ_BIN) $(CURDIR)/$(FUZZ_DIR)/corpus/rw $(CURDIR)/$(FUZZ_DIR)/seeds \
	  $(FUZZ_ARGS) -timeout=40

# One input, both modes, verbose, with a symbolised stack. This is the first
# thing to run against a crash artifact.
fuzz-repro: fuzz-build
	@test -n "$(FILE)" || { echo "usage: make fuzz-repro FILE=.fuzz/crashes/crash-..."; exit 1; }
	@test -f "$(FILE)" || { echo "no such file: $(FILE)"; exit 1; }
	@EXT4_FUZZ_MODE=both EXT4_FUZZ_VERBOSE=1 \
	  ASAN_SYMBOLIZER_PATH="$$(dirname $(FUZZ_CC))/llvm-symbolizer" \
	  ASAN_OPTIONS=symbolize=1:print_stacktrace=1 \
	  UBSAN_OPTIONS=print_stacktrace=1 \
	  $(FUZZ_BIN) "$(FILE)"

fuzz-minimize: fuzz-build
	@test -n "$(FILE)" || { echo "usage: make fuzz-minimize FILE=.fuzz/crashes/crash-..."; exit 1; }
	@test -f "$(FILE)" || { echo "no such file: $(FILE)"; exit 1; }
	@mkdir -p $(FUZZ_DIR)/min
	@EXT4_FUZZ_MODE=both $(FUZZ_BIN) -minimize_crash=1 -runs=100000 \
	  -artifact_prefix=$(FUZZ_DIR)/min/ "$(FILE)"

# A corpus grows monotonically and most of it is redundant. Merging keeps the
# smallest subset covering the same edges, which is what makes a cached corpus
# in CI affordable.
# The HTML map: which lines of lwext4 and the shim a campaign has reached.
# Separate binary and separate CONFIG because instrumentation-based coverage
# and the sanitizers do not belong in the same build -- see the cov block at
# the top. Needs llvm-profdata and llvm-cov, which come with the same
# Homebrew LLVM as the fuzzer runtime.
COV_BIN := $(BUILD)/bin/ext4_fuzz_cov

$(COV_BIN): $(FUZZ_SRCS) $(CORE_TEST_LIB)
	@mkdir -p $(dir $@)
	$(CC) $(TARGET_FLAG) $(CFLAGS) -DEXT4B_TEST_HOOKS=1 \
	    -DEXT4_FUZZ_WEIGHTS_PATH='"$(CURDIR)/tools/fuzz/mutweights.json"' \
	    -fsanitize=fuzzer -fprofile-instr-generate -fcoverage-mapping \
	    $(FUZZ_SRCS) $(CORE_TEST_LIB) $(CORE_LDLIBS) -o $@ 2>$@.ld.log \
	|| { echo "cov: default linker refused the objects; retrying with -ld_classic"; \
	     $(CC) $(TARGET_FLAG) $(CFLAGS) -DEXT4B_TEST_HOOKS=1 \
	        -DEXT4_FUZZ_WEIGHTS_PATH='"$(CURDIR)/tools/fuzz/mutweights.json"' \
	        -fsanitize=fuzzer -fprofile-instr-generate -fcoverage-mapping \
	        -Wl,-ld_classic \
	        $(FUZZ_SRCS) $(CORE_TEST_LIB) $(CORE_LDLIBS) -o $@; }
	@rm -f $@.ld.log
	@echo "built $@"

fuzz-cov:
	@$(MAKE) --no-print-directory CONFIG=cov $(COV_BIN)
	@mkdir -p $(FUZZ_DIR)/cov
	@rm -f $(FUZZ_DIR)/cov/*.profraw $(FUZZ_DIR)/cov/merged.profdata
	@for mode in ro rw; do \
	  echo "  sweeping the corpus in $$mode mode"; \
	  LLVM_PROFILE_FILE="$(CURDIR)/$(FUZZ_DIR)/cov/$$mode.profraw" \
	  EXT4_FUZZ_MODE=$$mode EXT4_FUZZ_NO_SELFTEST=1 \
	    $(COV_BIN) -runs=0 -max_len=8388608 -rss_limit_mb=4096 \
	      $(FUZZ_DIR)/seeds $(wildcard $(FUZZ_DIR)/corpus/*) \
	      > $(FUZZ_DIR)/cov/$$mode-run.txt 2>&1 || true; \
	done
	@"$$(dirname $(FUZZ_CC))/llvm-profdata" merge -sparse \
	    $(FUZZ_DIR)/cov/*.profraw -o $(FUZZ_DIR)/cov/merged.profdata
	@"$$(dirname $(FUZZ_CC))/llvm-cov" show $(COV_BIN) \
	    -instr-profile=$(FUZZ_DIR)/cov/merged.profdata \
	    -format=html -output-dir=$(FUZZ_DIR)/cov/html \
	    -ignore-filename-regex='(argon2|tools/fuzz)' 2>/dev/null
	@"$$(dirname $(FUZZ_CC))/llvm-cov" report $(COV_BIN) \
	    -instr-profile=$(FUZZ_DIR)/cov/merged.profdata \
	    -ignore-filename-regex='(argon2|tools/fuzz)' 2>/dev/null | tail -20
	@echo "html: $(FUZZ_DIR)/cov/html/index.html"

# The gate, which is the part that can fail. fuzz-cov draws the map;
# this asserts the campaign is still reaching the code it was aimed at.
fuzz-cov-gate:
	@bash scripts/fuzz_coverage.sh

# What the crashes directory means, in one place, because the soak and CI both
# have to decide the same way.
#
# A zero-byte artifact carries no input: libFuzzer writes one when it hits the
# RSS limit outside any particular input, which on this target means the
# corpus outgrew the limit rather than that the driver did anything wrong.
# There is nothing to reproduce and nothing to minimize. Report it, say what
# to do about it, and do not call it a finding -- a red build nobody can act
# on teaches people to ignore red builds.
fuzz-check:
	@n=0; empty=0; \
	for f in $(FUZZ_DIR)/crashes/*; do \
	  [ -e "$$f" ] || continue; \
	  if [ -s "$$f" ]; then n=$$((n+1)); else empty=$$((empty+1)); fi; \
	done; \
	if [ "$$empty" -gt 0 ]; then \
	  echo "note: $$empty empty artifact(s) -- libFuzzer ran out of room for"; \
	  echo "      the corpus, not for an input. Run 'make fuzz-merge'."; \
	fi; \
	if [ "$$n" -gt 0 ]; then \
	  echo "the fuzzer produced $$n artifact(s) with an input:"; \
	  ls -l $(FUZZ_DIR)/crashes | grep -v '^total' | awk '$$5 > 0'; \
	  echo ""; \
	  echo "  make fuzz-repro FILE=$(FUZZ_DIR)/crashes/<name>"; \
	  echo "  then Tests/fuzz/README.md, 'The triage loop'."; \
	  exit 1; \
	fi; \
	echo "no artifacts with an input"

fuzz-merge: fuzz-build
	@mkdir -p $(FUZZ_DIR)/corpus/ro $(FUZZ_DIR)/corpus/rw $(FUZZ_DIR)/merged
	@rm -rf $(FUZZ_DIR)/merged && mkdir -p $(FUZZ_DIR)/merged
	@EXT4_FUZZ_MODE=ro $(FUZZ_BIN) -merge=1 \
	  $(FUZZ_DIR)/merged $(FUZZ_DIR)/corpus/ro $(FUZZ_DIR)/seeds
	@echo "merged corpus: $$(ls $(FUZZ_DIR)/merged | wc -l | tr -d ' ') inputs"
	@rm -rf $(FUZZ_DIR)/corpus/ro && mv $(FUZZ_DIR)/merged $(FUZZ_DIR)/corpus/ro

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

# The Swift half of EXTRA_CFLAGS: an injection point for one-off builds, and
# the way a red-first run turns a defence off to show the test noticing.
#
#   make app EXTRA_SWIFTFLAGS=-DLUKS_NO_MLOCK
#
# `Ext4Mac selftest` must fail with that and pass without it.
SWIFTFLAGS += $(EXTRA_SWIFTFLAGS)

typecheck: core
	swiftc -typecheck $(SWIFT_SRCS) $(SWIFTFLAGS)

extension: $(APPEX)

$(APPEX): $(SWIFT_SRCS) $(CORE_LIB) Extension/Info.plist $(BUILD)/.build-id
	@if [ "$(CONFIG)" != "release" ] && [ -z "$(ALLOW_DEBUG_APPEX)" ]; then \
	  echo "refusing to build the appex against a $(CONFIG) core."; \
	  echo "the shipping extension must be a release build -- a debug core"; \
	  echo "carries ASan, and a fuzz core carries ASan and coverage"; \
	  echo "instrumentation calling into a libFuzzer runtime that is not"; \
	  echo "there. Set ALLOW_DEBUG_APPEX=1 only if you really mean to."; \
	  exit 1; \
	fi
	@rm -rf "$(APPEX)"
	@mkdir -p "$(APPEX)/Contents/MacOS"
	swiftc $(SWIFT_SRCS) $(SWIFTFLAGS) $(CORE_LIB) \
	    -o "$(APPEX)/Contents/MacOS/$(EXT_NAME)"
	@cp Extension/Info.plist "$(APPEX)/Contents/Info.plist"
	@plutil -replace Ext4BuildID -string "$(BUILD_ID)" "$(APPEX)/Contents/Info.plist"
	@echo "built $(APPEX)"

# The container app exists only to host the extension: macOS discovers FSKit
# modules through an installed application bundle, and the user enables it in
# System Settings > General > Login Items & Extensions.
app: extension $(BUILD)/$(APP_NAME).app/Contents/Info.plist $(BUILD)/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)

# Stamping the plists has to notice a new commit even when no source file
# changed, or the bundle keeps claiming the revision it was first built at --
# which is the same stale-identity problem the stamp exists to solve.
$(BUILD)/.build-id: FORCE
	@mkdir -p $(BUILD)
	@printf '%s' "$(BUILD_ID)" | cmp -s - $@ 2>/dev/null || printf '%s' "$(BUILD_ID)" > $@

FORCE:

$(BUILD)/$(APP_NAME).app/Contents/Info.plist: App/Info.plist $(BUILD)/.build-id
	@mkdir -p $(dir $@)
	@cp $< $@
	@plutil -replace Ext4BuildID -string "$(BUILD_ID)" $@

# The app links the core so it can read a LUKS header and run the key
# derivation itself: a gigabyte of argon2id belongs in an ordinary application,
# not in a sandboxed app extension that pays for it once per load.
APP_SRCS := $(wildcard App/*.swift) $(SHARED_SRCS)

$(BUILD)/$(APP_NAME).app/Contents/MacOS/$(APP_NAME): $(APP_SRCS) $(CORE_LIB)
	@mkdir -p $(dir $@)
	swiftc $(APP_SRCS) -target arm64-apple-macos$(DEPLOY_TARGET) -O -parse-as-library \
	    -I $(SHIM_DIR) $(EXTRA_SWIFTFLAGS) $(CORE_LIB) -o $@

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

# Asserts the shipping core carries no getenv, no test-only exports, and none
# of the removed env-var names -- built once, then it is what gets signed.
check-ship-surface: $(CORE_LIB) $(CORE_TEST_LIB)
	@bash scripts/check_ship_surface.sh

sign: app entitlements check-ship-surface
	@SIGN_KEYCHAIN="$(SIGN_KEYCHAIN)" bash scripts/sign.sh "$(BUILD)/$(APP_NAME).app" "$(SIGN_ID)"

# ------------------------------------------------------------- distribution --
# The version drives the DMG's filename. One place, read from the app's plist
# so it cannot drift from what the bundle reports.
VERSION := $(shell plutil -extract CFBundleShortVersionString raw App/Info.plist 2>/dev/null || echo 0.0.0)
DMG     := $(BUILD)/$(APP_NAME)-$(VERSION).dmg

# Build the distributable disk image from the signed app. Notarize it before
# handing it to anyone: an unnotarized Developer ID app is refused by Gatekeeper
# on first launch.
dmg: sign
	@bash scripts/make_dmg.sh "$(BUILD)/$(APP_NAME).app" "$(DMG)"
	@echo "next: make notarize NOTARY_PROFILE=<your-stored-profile>"

# Submit the DMG to Apple's notary service and wait for the verdict. Credentials
# come from a keychain profile you create once with
#   xcrun notarytool store-credentials <name> --apple-id <email> --team-id $(TEAM_ID)
# so no password ever appears here. On success, staple the ticket into the DMG.
notarize:
	@test -n "$(NOTARY_PROFILE)" || { \
	  echo "set NOTARY_PROFILE=<name> (see 'make notarize' comment for setup)"; exit 1; }
	@test -f "$(DMG)" || { echo "no $(DMG); run 'make dmg' first"; exit 1; }
	xcrun notarytool submit "$(DMG)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(DMG)"
	@echo "stapled $(DMG); verifying it passes Gatekeeper:"
	@spctl -a -vvv -t open --context context:primary-signature "$(DMG)" 2>&1 | head -3 || true

# Just the staple, for a DMG already notarized in a previous submission.
staple:
	@test -f "$(DMG)" || { echo "no $(DMG)"; exit 1; }
	xcrun stapler staple "$(DMG)"

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

# --- the retired barrier daemon ----------------------------------------------
# ext4barrierd, a root LaunchDaemon issuing DKIOCSYNCHRONIZE for the sandboxed
# extension, was removed after remeasurement: twenty mid-write pulls across
# five drives recovered identically with and without it (docs/STATUS.md). This
# target remains so a machine that installed it can take it back out.
#
# `override` because this runs as root and removes what it finds.
override BARRIER_LABEL   := dev.h3ct0r.ext4mac.barrier
override BARRIER_PROGRAM := /Library/PrivilegedHelperTools/ext4barrierd
override BARRIER_PLIST   := /Library/LaunchDaemons/$(BARRIER_LABEL).plist

uninstall-barrier:
	@test "$$(id -u)" = "0" || { echo "needs root: sudo make uninstall-barrier"; exit 1; }
	@launchctl bootout system "$(BARRIER_PLIST)" 2>/dev/null || true
	@rm -f "$(BARRIER_PLIST)" "$(BARRIER_PROGRAM)"
	@rm -f /usr/local/libexec/ext4barrierd
	@echo "removed the retired barrier daemon (the driver no longer uses one)"

# Turn a USB stick into something macOS will route to this driver. Erases it.
# Needs DEVICE, and CONFIRM=ERASE, because BSD names change on every replug and
# a script that trusts a remembered one will eventually be pointed at something
# else. See scripts/prepare_device.sh for the three routes that do not work.
# `tools` first, always. This erases a real device with build/bin/ext4dump,
# and without the prerequisite it runs whatever happens to be in build/ --
# which on a machine where the last build came from somewhere else is code
# nobody chose. That cost three re-runs of a four-minute format against a
# stale binary before anyone thought to check the timestamp.
prepare-device: tools
	@DEVICE="$(DEVICE)" CONFIRM="$(CONFIRM)" EXT4_LABEL="$(EXT4_LABEL)" \
	    EXT4_SIZE="$(EXT4_SIZE)" \
	    bash scripts/prepare_device.sh

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
# In place, not delete-and-recreate. rm -rf + cp gives the bundle a new
# identity, and (since the last reboot, reliably) LaunchServices responds by
# deregistering the extension and dropping its System Settings approval --
# which only the user can grant back, one Settings visit per build. rsync
# --delete updates the contents while the directory keeps its inode, and the
# registration survives.
	@rsync -a --delete "$(BUILD)/$(APP_NAME).app/" "/Applications/$(APP_NAME).app/"
	@echo "installed to /Applications/$(APP_NAME).app"
# Make sure the module is registered, and say which state it is in.
#
# Replacing the bundle wholesale loses the registration -- and a lost
# registration does not show up in System Settings as "off", it does not show
# up at all, so the old advice to go and enable it pointed at an empty list.
# rsync above keeps it whenever it only rewrites the changed files, which is
# the steady state; what loses it is an install whose every file differs, as
# when the same tree is built somewhere else.
#
# The lever is not pluginkit. This is an ExtensionKit extension
# (EXAppExtensionAttributes in the manifest), and pluginkit -a registers it
# in the legacy world where FSKit never looks: it reports success, lists the
# module with a null version, and the module stays invisible. What actually
# registers it is the containing app running -- so if the module is missing,
# launch it once, in the background, hidden.
#
# Approval stays the user's: nothing here can grant it, which is the point of
# it. So this ends by reporting which of the two is missing rather than
# printing the same "enable it" line whether or not anything is needed.
	@state="$$(bash scripts/check_extension.sh 2>&1 || true)"; \
	if ! printf '%s' "$$state" | grep -qi 'known to FSKit *yes'; then \
	  echo "FSKit does not know the module yet; launching the app once to register it"; \
	  open -g -j -a "/Applications/$(APP_NAME).app" 2>/dev/null || true; \
	  sleep 4; \
	  state="$$(bash scripts/check_extension.sh 2>&1 || true)"; \
	fi; \
	if printf '%s' "$$state" | grep -qi 'enabled and answering *yes'; then \
	  echo "the extension is registered and enabled; nothing else to do"; \
	elif printf '%s' "$$state" | grep -qi 'known to FSKit *yes'; then \
	  echo ""; \
	  echo "the extension is registered but NOT enabled yet -- only you can"; \
	  echo "grant that:"; \
	  echo "    System Settings > General > Login Items & Extensions"; \
	  echo "      > File System Extensions  ->  open_ext4 (ext2/3/4)"; \
	  echo ""; \
	  echo "then check with: make check-extension"; \
	else \
	  echo ""; \
	  echo "the module is installed but FSKit still does not list it."; \
	  echo "Run 'make check-extension' for the diagnosis."; \
	fi
# Say which revision was just installed, and whether anything is still running
# the previous one. An extension serving a mounted volume keeps the binary it
# started with, so an install can be complete and correct while every log line
# still comes from the old code -- which has now misled two rounds of
# debugging.
	@echo ""
	@/Applications/$(APP_NAME).app/Contents/MacOS/$(APP_NAME) version 2>/dev/null \
	  | sed 's/^/  /' || echo "  (installed app has no version verb yet)"
	@if pgrep -x $(EXT_NAME) >/dev/null 2>&1; then \
	  echo "  an $(EXT_NAME) process is still running the PREVIOUS build."; \
	  echo "  Eject and replug the volume before reading any log line."; \
	fi
