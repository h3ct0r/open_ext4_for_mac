#!/usr/bin/env bash
# Does docs/ENVELOPE.md still describe the code?
#
# The feature policy -- which ext4 feature bits mount read-write, which mount
# read-only and why, which are refused and why -- is a table in
# Core/shim/ext4_bridge.c that the probe walks. docs/ENVELOPE.md carries the
# same table for people. Two copies of one fact drift, and a document that
# says "supported" about a feature the code refuses is worse than no document,
# because somebody will plug a disk in on the strength of it.
#
# So the document is not trusted; it is checked. `ext4dump policy` prints the
# code's table one rule per line; this suite renders the document's markdown
# rows to the same lines and diffs. A row added, removed, reworded or reordered
# in either place is a red cell naming the line.
#
# Red-first: the cell must fail on an altered copy of the document before it is
# believed on the real one, and it does so here on every run -- the altered copy
# is made on the spot, because a drift check that has never seen drift is a
# drift check nobody has tested.
#
# Runs unattended. Needs build/bin/ext4dump (a test build: the policy hook is
# behind EXT4B_TEST_HOOKS, which the tool always carries and the appex never).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/Tests/lib.sh"

DUMP="$ROOT/build/bin/ext4dump"
DOC="$ROOT/docs/ENVELOPE.md"
FIX="$ROOT/Tests/fixtures/ext4_4k.img"
WORK="$ROOT/build/envelope"

[ -x "$DUMP" ] || { echo "build first: make tools"; exit 1; }
[ -f "$DOC" ]  || { echo "no docs/ENVELOPE.md"; exit 1; }
[ -f "$FIX" ]  || bash "$ROOT/Tests/make_fixtures.sh"
rm -rf "$WORK"; mkdir -p "$WORK"

echo "########## ENVELOPE ##########"
echo ""

# The code's table. The verb opens a volume only to have a device handle; the
# table is static and does not depend on which volume.
"$DUMP" "$FIX" policy 2>/dev/null > "$WORK/code.txt"
n=$(wc -l < "$WORK/code.txt" | tr -d ' ')
[ "$n" -gt 20 ] && ok "the code's policy table has $n rules" \
                || bad "the code's policy table is readable" "$n line(s) from ext4dump policy"

# The document's table, rendered to the same lines.
#
# The markdown rows look like:
#   | incompat | 0x00010 | meta_bg | refused | filesystem uses ... |
# and the code prints:
#   incompat 0x00010 meta_bg              refused    filesystem uses ...
# Column widths are cosmetic; both sides are normalised to single spaces before
# the diff, so a re-aligned table is not a drift and a reworded reason is.
render_doc() {  # render_doc <markdown> -> stdout
  awk -F'|' '
    /^\| *(incompat|ro_compat) *\|/ {
      for (i = 2; i <= 6; i++) { gsub(/^ +| +$/, "", $i) }
      printf "%s %s %s %s %s\n", $2, $3, $4, $5, $6
    }' "$1"
}
norm() { sed -E 's/[[:space:]]+/ /g; s/ $//' "$1"; }

render_doc "$DOC" > "$WORK/doc.txt"
norm "$WORK/code.txt" > "$WORK/code.norm"
norm "$WORK/doc.txt"  > "$WORK/doc.norm"

if diff -u "$WORK/code.norm" "$WORK/doc.norm" > "$WORK/drift.diff"; then
  ok "docs/ENVELOPE.md's feature table matches the code's, all $n rules"
else
  bad "docs/ENVELOPE.md's feature table matches the code's" \
      "$(grep -E '^[-+][^-+]' "$WORK/drift.diff" | head -4 | tr '\n' ';')"
fi

# ---------------------------------------------------------------- red-first --
# On a copy: reword one reason, and separately drop one row. Both must be
# caught. This runs every time, so the check's teeth are shown, not assumed.
echo ""
echo "the check has teeth"
echo ""
sedi 's/filesystem uses inline data/filesystem uses inline data, probably fine/' <(true) 2>/dev/null || true
sed 's/filesystem uses inline data/filesystem uses inline data, probably fine/' "$DOC" > "$WORK/reworded.md"
render_doc "$WORK/reworded.md" | norm /dev/stdin > "$WORK/reworded.norm"
if diff -q "$WORK/code.norm" "$WORK/reworded.norm" >/dev/null; then
  bad "a reworded reason is caught" "the diff did not notice a changed sentence"
else
  ok "a reworded reason is caught"
fi

grep -v '| meta_bg |' "$DOC" > "$WORK/dropped.md"
render_doc "$WORK/dropped.md" | norm /dev/stdin > "$WORK/dropped.norm"
if diff -q "$WORK/code.norm" "$WORK/dropped.norm" >/dev/null; then
  bad "a dropped row is caught" "the diff did not notice a missing rule"
else
  ok "a dropped row is caught"
fi

# --------------------------------------------------------- the other claims --
# Numbers in the document that the code or the plist also state. Each is one
# grep on each side; a changed constant with an unchanged sentence is the drift
# these exist for.
echo ""
echo "stated limits match their source"
echo ""

fmt_max=$(plutil -extract FSPersonalities.ext4.FSFormatMaximumSize raw -o - "$ROOT/Extension/Info.plist" 2>/dev/null \
          || sed -n '/FSFormatMaximumSize/{n;s/.*<integer>\(.*\)<\/integer>.*/\1/p;}' "$ROOT/Extension/Info.plist" | head -1)
if [ -n "$fmt_max" ] && grep -q "$fmt_max" "$DOC"; then
  ok "the format size cap in the document is the plist's ($fmt_max)"
else
  bad "the format size cap in the document is the plist's" "plist says '${fmt_max:-?}'"
fi

if grep -q "1 KiB << 6 == 64 KiB" "$ROOT/Core/shim/ext4_bridge.c" && grep -qE "64 KiB" "$DOC"; then
  ok "the largest block size the probe accepts is stated (64 KiB)"
else
  bad "the largest block size the probe accepts is stated"
fi

# The hostile fixture count is a claim the document makes about the suite.
hostile=$(grep -cE '^[0-9]{4}-' "$ROOT/Tests/fixtures/hostile/MANIFEST")
if grep -qE "\b$hostile hostile" "$DOC"; then
  ok "the hostile-fixture count is current ($hostile)"
else
  bad "the hostile-fixture count is current" "MANIFEST has $hostile rows; the document says otherwise"
fi

echo ""
echo "─────────────────────────────────"
finish
