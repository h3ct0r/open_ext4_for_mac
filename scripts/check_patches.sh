#!/usr/bin/env bash
# Do the patches in patches/lwext4/ actually reproduce the tree we build?
#
# The vendored lwext4 is a submodule pinned at an upstream commit, and every
# change we make to it lives in a patch file. That arrangement only works if
# applying the patches to the pinned commit yields exactly the working tree.
# Nothing enforced that, and it had already drifted twice:
#
#   * 0014 was generated as a whole-tree diff, so it re-contained hunks that
#     0005 and 0008 had already applied. `git apply` is all-or-nothing, so on a
#     clean checkout the whole patch failed -- and the Makefile's third branch,
#     meant for a patch being developed, swallowed the failure with a note.
#     A clone got a driver with no write barrier at all and no error to read.
#
#   * The journal checksum fix and the mkfs feature flags were edited straight
#     into the submodule and never written as patches, so they existed on one
#     machine and nowhere else.
#
# Both are invisible from inside the working tree: everything is there, builds,
# and passes. The only way to see it is to build the tree the way someone else
# would, from the pinned commit plus the patch files, and diff.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LWEXT4="$ROOT/Core/lwext4"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lwext4-patchcheck.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ -d "$LWEXT4/.git" ] || [ -f "$LWEXT4/.git" ] || fail "submodule not checked out: $LWEXT4"

# The commit the superproject pins, not whatever HEAD happens to be: a clone
# gets the pinned one, and that is the tree we are asking about.
# git 2.35+ refuses a working tree whose owner differs from the caller with
# "detected dubious ownership" and exit 128 -- a CI runner trips this. Name the
# command that failed rather than letting a bare 128 stand, and suggest the
# fix, so a runner problem does not read as a patch problem.
pinned="$(git -C "$ROOT" ls-tree HEAD Core/lwext4 2>/tmp/giterr | awk '{print $3}')"
if [ -z "$pinned" ]; then
    pinned="$(git -C "$LWEXT4" rev-parse HEAD 2>>/tmp/giterr)"
fi
if [ -z "$pinned" ]; then
    echo "check-patches: could not read the pinned lwext4 commit." >&2
    sed 's/^/  git: /' /tmp/giterr >&2 2>/dev/null || true
    if grep -q "dubious ownership" /tmp/giterr 2>/dev/null; then
        echo "  this is git refusing a checkout it does not own, not a patch problem." >&2
        echo "  fix: git config --global --add safe.directory '*'" >&2
    fi
    rm -f /tmp/giterr
    exit 1
fi
rm -f /tmp/giterr

# Extract rather than clone, so no .git comes along -- a copied submodule
# gitlink points back into the superproject and every git command in the copy
# fails in a way that reads as the patches failing.
git -C "$LWEXT4" archive "$pinned" | tar -x -C "$WORK" \
  || fail "cannot extract lwext4 at $pinned"

shopt -s nullglob
patches=("$ROOT"/patches/lwext4/*.patch)
[ ${#patches[@]} -gt 0 ] || fail "no patches found"

for p in "${patches[@]}"; do
    # --directory-less apply, run from inside the extracted tree. Same
    # all-or-nothing semantics the Makefile gets.
    if ! (cd "$WORK" && git apply --unsafe-paths --directory=. "$p" 2>&1); then
        fail "$(basename "$p") does not apply to $pinned"
    fi
done
shopt -u nullglob

# Compare against the tree we actually compile. Exclude the ignorable.
if ! diff -ru \
        --exclude='.git' --exclude='.DS_Store' --exclude='*.orig' \
        --exclude='*.rej' \
        "$WORK" "$LWEXT4" > "$WORK.diff" 2>/dev/null; then
    echo "the patch set does not reproduce Core/lwext4:" >&2
    sed -n '1,80p' "$WORK.diff" >&2
    rm -f "$WORK.diff"
    echo >&2
    echo "Either regenerate the patch for the changed file, or revert the" >&2
    echo "local edit. A change that exists only in the submodule working" >&2
    echo "tree exists only on this machine." >&2
    exit 1
fi
rm -f "$WORK.diff"

echo "${#patches[@]} patches reproduce Core/lwext4 at ${pinned:0:12}"
