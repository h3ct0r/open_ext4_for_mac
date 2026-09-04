#!/usr/bin/env bash
# Do the documents say what the tree says?
#
# Numbers in prose rot: the changelog said seventeen hostile fixtures for a
# week in which there were twenty, and nobody noticed because nothing looked.
# Links rot too, and a README whose links 404 is the first thing a visitor
# judges the project by. docs/ENVELOPE.md already has its feature table diffed
# against the shim on every run; this suite extends that idea to the rest.
#
# Every cell has a self-check: the same assertion run against a deliberately
# broken copy, which must FAIL -- so a walker that finds nothing because it
# looked nowhere is caught here rather than trusted.
#
# Offline, no tools, no Homebrew. Runs in CI and in `make validate`.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/Tests/lib.sh"
WORK="$ROOT/build/docs"
rm -rf "$WORK"; mkdir -p "$WORK"

echo "########## DOCS SAY WHAT THE TREE SAYS ##########"
echo ""

# ------------------------------------------------------------ links ------
# Every relative link in every markdown file of ours resolves to a file or a
# directory. Vendored trees are not ours to fix. Prints one line per broken
# link, then the count, so the failure names the link.
check_links() {  # check_links <dir> -> prints "broken: N"
  python3 - "$1" <<'PY'
import os, re, sys
root = sys.argv[1]
skip = ('Core/lwext4', 'build/', '.fuzz/', '.soak/', '.claude/', 'node_modules/')
bad = 0
for dp, dn, fn in os.walk(root):
    rel = os.path.relpath(dp, root)
    if any((rel + '/').startswith(s) for s in skip): continue
    for f in fn:
        if not f.endswith('.md'): continue
        p = os.path.join(dp, f)
        text = open(p, encoding='utf-8', errors='replace').read()
        for m in re.finditer(r'\]\(([^)\s]*)\)', text):
            link = m.group(1)
            if link.startswith(('http://', 'https://', 'mailto:')): continue
            t, _, anchor = link.partition('#')
            target = os.path.normpath(os.path.join(dp, t)) if t else p
            if not os.path.exists(target):
                print(f"  broken in {os.path.relpath(p, root)}: {link}")
                bad += 1
                continue
            # An anchor into a markdown file has to name a heading there, the
            # way GitHub slugs it: lowercase, punctuation dropped, spaces to
            # hyphens. Moving a section between files is exactly what breaks
            # these silently.
            if anchor and target.endswith('.md'):
                heads = set()
                for line in open(target, encoding='utf-8', errors='replace'):
                    if line.startswith('#'):
                        h = line.lstrip('#').strip().lower()
                        h = re.sub(r'[^\w\s-]', '', h).strip().replace(' ', '-')
                        heads.add(h)
                if anchor.lower() not in heads:
                    print(f"  no anchor in {os.path.relpath(p, root)}: {link}")
                    bad += 1
print(f"broken: {bad}")
PY
}

echo "links"
echo ""
out=$(check_links "$ROOT")
n=$(sed -n 's/^broken: //p' <<<"$out")
if [ "$n" = "0" ]; then
  ok "every relative link in our markdown resolves"
else
  bad "every relative link in our markdown resolves" "$(grep '^  broken' <<<"$out" | head -5)"
fi

# Self-check: a full copy of the tracked tree with ONE link pointed at nothing
# must report exactly one more broken link than the tree itself. A full copy,
# not a hand-picked subset: the first version copied six files and reported
# six "broken" links that were only missing from the copy.
base=$(sed -n 's/^broken: //p' <<<"$out")
mkdir -p "$WORK/broken"
# Tracked and untracked-but-not-ignored alike: the walker above checks the
# working tree, so a file that exists but is not yet committed is a link
# target there and must be one here too.
( cd "$ROOT" && git ls-files -z --cached --others --exclude-standard | tar --null -T - -cf - ) \
  | ( cd "$WORK/broken" && tar -xf - )
# Exactly one occurrence: the README links INSTALL.md more than once, and
# breaking all of them made "one more" three.
python3 - "$WORK/broken/README.md" <<'PY'
import sys; p = sys.argv[1]; t = open(p).read()
open(p, 'w').write(t.replace('(docs/INSTALL.md)', '(docs/DOES-NOT-EXIST.md)', 1))
PY
n=$(check_links "$WORK/broken" | sed -n 's/^broken: //p')
[ "$n" = "$((base+1))" ] && ok "self-check: one deliberately broken link is reported as one more" \
                          || bad "self-check: one deliberately broken link is reported as one more" "tree $base, copy $n"

# ----------------------------------------------------------- counts ------
echo ""
echo "counts"
echo ""

fixtures=$(grep -cE '^[0-9]{4}-' "$ROOT/Tests/fixtures/hostile/MANIFEST")
patches=$(ls "$ROOT"/patches/lwext4/*.patch | wc -l | tr -d ' ')

# The README states both as digits, so a reader can check them, so we do.
grep -qE "\b$fixtures hostile fixtures" "$ROOT/README.md" \
  && ok "README says $fixtures hostile fixtures, which is the MANIFEST's count" \
  || bad "README says how many hostile fixtures there are" \
         "MANIFEST has $fixtures; README: $(grep -oE '[0-9]+ hostile fixtures' "$ROOT/README.md" | head -1)"
grep -qE "\b$patches numbered patches" "$ROOT/README.md" \
  && ok "README says $patches numbered patches, which is how many there are" \
  || bad "README says how many lwext4 patches there are" \
         "$patches files; README: $(grep -oE '[0-9]+ numbered patches' "$ROOT/README.md" | head -1)"

# Every patch file has a row in the patches README, by its full name.
missing=0
for p in "$ROOT"/patches/lwext4/*.patch; do
  name=$(basename "$p" .patch)
  grep -q "$name" "$ROOT/patches/lwext4/README.md" || { missing=$((missing+1)); echo "  no row: $name"; }
done
[ "$missing" = "0" ] && ok "every patch file has a row in patches/lwext4/README.md" \
                     || bad "every patch file has a row in patches/lwext4/README.md" "$missing without one"

# Self-check: the fixture assertion must go red on a README that is off by one.
# No \b: BSD sed has none, and a substitution that silently does nothing
# would pass this self-check for the wrong reason.
sed -E "s/ $fixtures hostile fixtures/ $((fixtures+1)) hostile fixtures/" "$ROOT/README.md" > "$WORK/offbyone.md"
if grep -qE "\b$fixtures hostile fixtures" "$WORK/offbyone.md"; then
  bad "self-check: an off-by-one fixture count is caught" "the wrong number still matched"
else
  ok "self-check: an off-by-one fixture count is caught"
fi

# ---------------------------------------------------------- make help ----
echo ""
echo "make help"
echo ""
documented=$(grep -cE '^[a-zA-Z0-9_-]+:.*  ## ' "$ROOT/Makefile")
listed=$(make -s -C "$ROOT" help 2>/dev/null | grep -cE '^  [a-zA-Z0-9_-]+ ')
[ "$documented" -gt 0 ] && [ "$documented" = "$listed" ] \
  && ok "make help lists every documented target ($listed)" \
  || bad "make help lists every documented target" "$documented documented, $listed listed"
for t in install validate release uninstall check-extension; do
  make -s -C "$ROOT" help 2>/dev/null | grep -qE "^  $t " \
    && ok "  and '$t' is among them" || bad "  and '$t' is among them"
done

# ---------------------------------------------------- version and log ----
echo ""
echo "version"
echo ""
v=$(tr -d '[:space:]' < "$ROOT/VERSION")
grep -qE "^## \[$v\]" "$ROOT/CHANGELOG.md" \
  && ok "CHANGELOG has a section for VERSION $v" \
  || bad "CHANGELOG has a section for VERSION $v"

echo ""
echo "─────────────────────────────────"
finish
