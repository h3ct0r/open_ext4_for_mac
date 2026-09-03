# Shared plumbing for test suites. Source it:
#
#     ROOT="$(cd "$(dirname "$0")/.." && pwd)"
#     . "$ROOT/Tests/lib.sh"
#
# New suites use this; existing suites carry their own copies and migrate
# when they are next touched for another reason -- rewriting the safety net
# for tidiness is how safety nets get holes.
#
# Provides: PASS/FAIL counters, ok/bad, finish, the e2fsprogs PATH, the
# portable spellings of the four idioms that differ between BSD and GNU
# userland, and the Linux oracle -- in_linux/have_linux and the two helpers
# that make sure it has an image and the tools it needs.

export PATH="/opt/homebrew/opt/e2fsprogs/sbin:/opt/homebrew/opt/e2fsprogs/bin:$PATH"

# Linux oracle images. One place, because three different values had crept
# into eight scripts.
DOCKER_LINUX_IMAGE="${DOCKER_LINUX_IMAGE:-debian:stable-slim}"
DOCKER_LUKS_IMAGE="${DOCKER_LUKS_IMAGE:-ext4luks:cryptsetup-attr}"

PASS=0
FAIL=0

# `bad` must not return nonzero: under `set -e` (or a && chain) a failing
# assertion would otherwise abort the suite at the first red instead of
# counting it.
ok()  { PASS=$((PASS+1)); echo "  ok    $*"; }
# "$1", not "$*": the headline is the assertion, and the rest is the detail
# printed under it. With "$*" the detail appeared on both lines, so every
# failure with an explanation printed it twice -- harmless, and it made a
# four-finding run read as eight lines of the same thing.
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; shift; [ $# -gt 0 ] && echo "        $*"; return 0; }

# ---------------------------------------------------------------- portable --
#
# The suites were written on macOS and use BSD spellings throughout. The
# oracle suites now have somewhere else to run -- the Linux kernel's own ext4
# is the second opinion on everything this driver writes, and a CI runner can
# give us that natively instead of through Docker -- so the idioms that differ
# get one name each, here.
#
# Only the ones that actually differ. `wc`, `grep`, `awk` and `dd` are the
# same everywhere that matters, and wrapping them would be noise.

# File size in bytes. BSD stat takes -f, GNU takes -c.
fsize() {
  if stat -f%z "$1" 2>/dev/null; then :; else stat -c%s "$1"; fi
}

# SHA-256 of a file or of stdin. macOS ships shasum and no sha256sum; most
# Linux distributions ship sha256sum and not shasum.
sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$@" | cut -d' ' -f1
  else
    sha256sum "$@" | cut -d' ' -f1
  fi
}

# MD5 of a file. `md5 -q` on macOS, `md5sum` on Linux. Used where a digest is
# a change detector rather than a security property -- "did this verb touch
# the medium" -- which is what most of this suite's digests are.
md5of() {
  if command -v md5 >/dev/null 2>&1; then
    md5 -q "$1"
  else
    md5sum "$1" | cut -d' ' -f1
  fi
}

# Copy a filesystem image.
#
# The fixtures are 64-256 MB each and a crash sweep makes two hundred copies of
# one before it checks any of them, so a plain cp is 50 GB on the disk and
# minutes on the clock. Both systems have a way out and they are different
# ways: APFS clones the file, copy-on-write, instant and free until something
# writes to it; GNU cp punches holes wherever the source reads as zeros, which
# is nearly all of a freshly made ext4. Neither changes a byte of what a reader
# sees, and a runner's disk is not big enough for the honest version.
imgcopy() {  # imgcopy <src> <dst>
  cp -c "$1" "$2" 2>/dev/null \
    || cp --sparse=always "$1" "$2" 2>/dev/null \
    || cp "$1" "$2"
}

# In-place sed. BSD requires an argument to -i and GNU refuses one, so there
# is no spelling that works on both and the difference has to be branched.
sedi() {
  local expr="$1"; shift
  if sed --version >/dev/null 2>&1; then
    sed -i "$expr" "$@"          # GNU
  else
    sed -i '' "$expr" "$@"       # BSD
  fi
}

# Run a command with a Linux kernel underneath it.
#
# The oracle suites need a real ext4 implementation to check ours against, and
# there are two ways to have one. On a developer's Mac it is a container; on a
# Linux CI runner it is the machine itself, and starting a container there to
# reach the kernel you are already running on would be absurd. EXT4_ORACLE=local
# picks the second.
#
# The fragment runs with the work directory as its working directory in both
# forms, so it addresses its images by relative name -- `mount -o loop a.img`,
# never `/w/a.img`. That is what lets one fragment mean the same thing in a
# container and on the runner itself.
#
# A suite that needs more of Linux than debian:stable-slim carries -- cryptsetup,
# attr -- sets ORACLE_IMAGE before calling. In local form the image name is
# irrelevant: the packages are the runner's.
in_linux() {  # in_linux <work-dir> <script>
  local work="$1"; shift
  if [ "${EXT4_ORACLE:-docker}" = "local" ]; then
    if [ "$(id -u)" = "0" ]; then
      ( cd "$work" && bash -c "$*" )
    else
      sudo bash -c "cd '$work' && $*"
      local rc=$?
      # Whatever the fragment created belongs to root, and the suite that
      # called it does not run as root -- it goes on to write those images
      # with ext4dump. Hand them back. (Not needed in the container form: the
      # bind mount keeps the host's ownership.)
      sudo chown -R "$(id -u):$(id -g)" "$work" 2>/dev/null || true
      return $rc
    fi
  else
    docker run --rm --privileged -v "$work:/w" -w /w \
      "${ORACLE_IMAGE:-$DOCKER_LINUX_IMAGE}" bash -c "$*"
  fi
}

# Build the oracle image if the container form needs one that is not there yet.
# A no-op in local form, where the packages came from apt and there is no image.
# Reads the Dockerfile from stdin; bump the tag when the package list changes,
# or a stale image from an earlier run is reused and the new checks skip.
ensure_oracle_image() {  # ensure_oracle_image <tag>  <<'DOCKERFILE'
  [ "${EXT4_ORACLE:-docker}" = "local" ] && return 0
  docker image inspect "$1" >/dev/null 2>&1 && return 0
  echo "building $1 (one-off, needs network)"
  docker build -q -t "$1" - >/dev/null
}

# The oracle's tools have to actually be present. The container form carries
# them in the image; the local form got them from the runner's apt, and a
# missing one has to say so here rather than fail inside a fragment, where a
# `command not found` on stderr looks like an empty answer from the kernel.
oracle_needs() {  # oracle_needs <cmd>...
  [ "${EXT4_ORACLE:-docker}" = "local" ] || return 0
  local c missing=""
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
  [ -z "$missing" ] && return 0
  echo "EXT4_ORACLE=local, but the oracle needs these and they are not here:$missing"
  return 1
}

# Is there a Linux oracle available at all?
have_linux() {
  if [ "${EXT4_ORACLE:-docker}" = "local" ]; then
    [ "$(uname -s)" = "Linux" ]
  else
    docker info >/dev/null 2>&1
  fi
}

# What to print when there is not one. Two different sentences, because the
# two situations have two different fixes.
no_linux_reason() {
  if [ "${EXT4_ORACLE:-docker}" = "local" ]; then
    echo "EXT4_ORACLE=local but this is not Linux ($(uname -s))"
  else
    echo "docker is not running; there is no Linux kernel to ask"
  fi
}

# Print the tally and exit nonzero on any failure.
finish() {
  echo ""
  echo "passed: $PASS failed: $FAIL"
  [ "$FAIL" -eq 0 ]
}
