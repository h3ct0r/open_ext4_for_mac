#!/usr/bin/env bash
# The oracle half of the test set: the five suites whose verdict is the Linux
# kernel's rather than ours.
#
# Everything here already ran on a developer's Mac, where the kernel came from
# a privileged Docker container. This script runs the same suites on a Linux
# machine, where the kernel IS the machine -- EXT4_ORACLE=local, so in_linux()
# calls sudo instead of docker and there is no container in the picture at all.
# Same suites, same assertions, one less layer between the claim and the thing
# that judges it. And it is the only way to have them in CI: GitHub's macOS
# runners have no Docker.
#
# What each one asks the kernel:
#
#   crash        cut every mutating operation's write stream at every point,
#                let the kernel replay each journal, e2fsck every result
#   reorder      the same, on a drive that reorders writes within its cache
#   diff         we write, Linux reads; Linux writes, we read -- modes, links,
#                symlinks, xattrs, chattr flags, a 300-entry directory
#   luks         cryptsetup makes the container, we read and write inside it,
#                the kernel checks what we wrote
#   replay-speed how long a 128 MiB journal takes to replay through our reader
#
# Run it here the same way CI does:
#
#     EXT4_ORACLE=local bash scripts/ci_linux.sh
#
# On macOS it refuses rather than pretending: the suites themselves still run
# there through Docker, one at a time, which is what `make validate` does.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ "$(uname -s)" != "Linux" ]; then
  echo "scripts/ci_linux.sh runs on Linux. On macOS the same suites reach a"
  echo "kernel through Docker -- run them individually, or \`make validate\`."
  exit 2
fi

# The whole point of the job. Without it in_linux() would start a container on
# a machine that is already the thing the container was standing in for.
export EXT4_ORACLE="${EXT4_ORACLE:-local}"

SET_LABEL="linux oracle"
OUT="$ROOT/build/ci-linux"
. "$ROOT/scripts/ci_stages.sh"

# The sweeps are long: 203 cut points, each a mount and an e2fsck, and the
# reorder sweep is bigger again. 900s is the offline set's number and it is
# not enough here.
STAGE_TIMEOUT="${CI_STAGE_TIMEOUT:-2700}"

ci_begin

# Before anything is built: does the patch set reproduce the tree we are about
# to compile? Cheap, and it is the one check that a second machine can make
# that the first one cannot -- a patch that only applies to one working tree
# fails here.
stage check-patches  bash scripts/check_patches.sh

# gcc, no -target, -lcrypto: see the HOST_OS block in the Makefile.
stage build          make tools

# The crypto known-answer tests, run against OpenSSL as the backend rather
# than CommonCrypto. Thirty vectors that agree on both systems say the port
# did not change what the driver computes.
stage crypto         make test-crypto

# The read and write suites need no kernel, but they have never run on
# anything but macOS, and a byte-order or size-of-long mistake in the shim
# would show up here first.
stage read           bash Tests/run_tests.sh
stage write          bash Tests/run_write_tests.sh

# ------------------------------------------------------------- the oracle --
stage diff           bash Tests/run_diff_tests.sh
stage luks           bash Tests/run_luks_tests.sh
stage replay-speed   bash Tests/run_replay_speed_tests.sh
stage crash          bash Tests/run_crash_tests.sh
stage reorder        bash Tests/run_reorder_tests.sh

ci_end
