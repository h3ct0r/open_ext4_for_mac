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
changes=$(grep -cE '^\| `[0-9]{4}-' "$ROOT/docs/lwext4-changes.md")

# The README states both as digits, so a reader can check them, so we do.
grep -qE "\b$fixtures hostile fixtures" "$ROOT/README.md" \
  && ok "README says $fixtures hostile fixtures, which is the MANIFEST's count" \
  || bad "README says how many hostile fixtures there are" \
         "MANIFEST has $fixtures; README: $(grep -oE '[0-9]+ hostile fixtures' "$ROOT/README.md" | head -1)"
grep -qE "\b$changes recorded changes" "$ROOT/README.md" \
  && ok "README says $changes recorded changes to lwext4, which is the ledger's count" \
  || bad "README says how many lwext4 changes there are" \
         "ledger has $changes; README: $(grep -oE '[0-9]+ recorded changes' "$ROOT/README.md" | head -1)"

# Self-check: the fixture assertion must go red on a README that is off by one.
# No \b: BSD sed has none, and a substitution that silently does nothing
# would pass this self-check for the wrong reason.
sed -E "s/ $fixtures hostile fixtures/ $((fixtures+1)) hostile fixtures/" "$ROOT/README.md" > "$WORK/offbyone.md"
if grep -qE "\b$fixtures hostile fixtures" "$WORK/offbyone.md"; then
  bad "self-check: an off-by-one fixture count is caught" "the wrong number still matched"
else
  ok "self-check: an off-by-one fixture count is caught"
fi

# ------------------------------------------------------ lwext4 ledger ----
# lwext4 is an in-tree fork, and docs/lwext4-changes.md is the ledger of every
# change to it. Its IDs are cited all over the tree -- "patch 0067" in a code
# comment, "lwext4 0048" in a fixture's fixed_by, a bare 0071 in the MANIFEST's
# fix column, patches/lwext4/0012 in the notebook from when they were files --
# and a citation of an ID the ledger does not have is a pointer to nothing.
echo ""
echo "lwext4 ledger"
echo ""
check_citations() {  # check_citations <tree-root> -> prints "unknown: N"
  python3 - "$1" <<'PY'
import os, re, sys
root = sys.argv[1]
ledger = open(os.path.join(root, 'docs/lwext4-changes.md')).read()
known = set(re.findall(r'^\| `(\d{4})-', ledger, re.M))
cite = re.compile(r'(?:\bpatch(?:es)?|\blwext4(?: change)?|Lwext4-Change:|patches/lwext4/)\s+?(\d{4})(?:\s*[-/\u2013]\s*(\d{4}))?\b'
                  r'|patches/lwext4/(\d{4})')
where = ['Core/shim', 'Core/crypto', 'Core/lwext4/src', 'Core/lwext4/include', 'tools',
         'Tests', 'scripts', 'docs', 'App', 'Extension', 'Shared', 'Makefile',
         'README.md', 'CHANGELOG.md', 'CONTRIBUTING.md', 'SECURITY.md']
unknown = 0
def scan(path):
    global unknown
    try: text = open(path, errors='replace').read()
    except (IsADirectoryError, FileNotFoundError): return
    for m in cite.finditer(text):
        lo, hi, bare = m.group(1), m.group(2), m.group(3)
        ids = [bare] if bare else ([f'{i:04d}' for i in range(int(lo), int(hi) + 1)] if hi and int(hi) - int(lo) < 100 else [lo])
        for i in ids:
            if i not in known:
                unknown += 1
                print(f'  unknown lwext4 change {i}: {os.path.relpath(path, root)}')
    if path.endswith('MANIFEST'):
        for line in text.splitlines():
            cols = line.split()
            if len(cols) > 3 and re.fullmatch(r'\d{4}', cols[0]) and re.fullmatch(r'\d{4}', cols[3]) and cols[3] not in known:
                unknown += 1
                print(f'  unknown lwext4 change {cols[3]}: MANIFEST row {cols[0]}')
for w in where:
    p = os.path.join(root, w)
    if os.path.isfile(p): scan(p); continue
    for dp, dn, fn in os.walk(p):
        dn[:] = [d for d in dn if d not in ('__pycache__',)]
        for f in fn:
            if f.endswith(('.img', '.gz', '.a', '.o', '.pyc', '.icns', '.png')): continue
            scan(os.path.join(dp, f))
print(f'unknown: {unknown}')
PY
}
n=$(check_citations "$ROOT" | tee "$WORK/citations.txt" | sed -n 's/^unknown: //p')
grep '^  unknown' "$WORK/citations.txt" | head -10
[ "$n" = "0" ] && ok "every cited lwext4 change has a ledger row" \
               || bad "every cited lwext4 change has a ledger row" "$n citation(s) of IDs the ledger does not have"

# Self-check: the same walk over a copy with one citation of an ID that does
# not exist must count exactly one more.
mkdir -p "$WORK/ledger/docs" "$WORK/ledger/Core/shim"
cp "$ROOT/docs/lwext4-changes.md" "$WORK/ledger/docs/"
printf '/* see patch %s */\n' 0999 > "$WORK/ledger/Core/shim/x.c"
n=$(check_citations "$WORK/ledger" | sed -n 's/^unknown: //p')
[ "$n" = "1" ] && ok "self-check: a citation of an unknown change is caught" \
               || bad "self-check: a citation of an unknown change is caught" "counted $n"

# And the history: every commit that changed lwext4's code since the import is
# a numbered change with its row, or an `lwext4 vendor:` one. What the patch
# series enforced by construction, an in-tree fork has to check. A shallow
# clone has no history to read, and says so rather than passing.
out=$(bash "$ROOT/scripts/check_lwext4_ledger.sh" 2>&1); rc=$?
case "$rc" in
  0)  ok "every lwext4 code change since the import is numbered and in the ledger" ;;
  77) echo "  skip  $out" ;;
  *)  echo "$out" | sed '$d'
      bad "every lwext4 code change since the import is numbered and in the ledger" \
          "$(echo "$out" | tail -1)" ;;
esac

# Upstream's licence terms travel with its files: the BSD-3 ones require the
# notice to be kept, and GPL-2.0 requires it too. A reformat or a careless
# edit that drops a header is a licence problem, not a style one.
check_headers() {  # check_headers <lwext4-dir> -> prints the files missing a header
  local f
  for f in "$1"/src/*.c "$1"/include/*.h "$1"/include/misc/*.h; do
    [ -e "$f" ] || continue
    grep -q "Copyright" "$f" \
      && grep -qE "Redistribution and use in source and binary forms|GNU General Public License" "$f" \
      || echo "${f#$1/}"
  done
}
missing=$(check_headers "$ROOT/Core/lwext4")
[ -z "$missing" ] && ok "every lwext4 source keeps its copyright and licence header" \
                  || bad "every lwext4 source keeps its copyright and licence header" "$(echo $missing)"
mkdir -p "$WORK/lwext4/src"
sed -e '/Copyright/d' "$ROOT/Core/lwext4/src/ext4.c" > "$WORK/lwext4/src/ext4.c"
[ "$(check_headers "$WORK/lwext4")" = "src/ext4.c" ] \
  && ok "self-check: a source without its header is caught" \
  || bad "self-check: a source without its header is caught"

# ---------------------------------------------------- third-party notices --
# THIRD_PARTY_NOTICES.md is what the app and the DMG carry for the code they
# contain but this project did not write: BSD clause 2, in every lwext4 BSD
# licence, requires the notices with the binary. So every copyright line in
# that code has to be in it -- a new lwext4 file with a new holder, or a new
# Argon2 release, would otherwise ship without its notice and nothing would say.
echo ""
echo "third-party notices"
echo ""
check_notices() {  # check_notices <tree-root> <notices-file> -> prints "missing: N"
  python3 - "$1" "$2" <<'PY'
import glob, os, re, sys
root, notices = sys.argv[1], sys.argv[2]
norm = lambda t: re.sub(r'\s+', ' ', t).strip()
text = norm(open(notices).read())
files = []
for pat in ('Core/lwext4/src/*.c', 'Core/lwext4/include/*.h', 'Core/lwext4/include/misc/*.h',
            'Core/crypto/argon2/LICENSE', 'Core/crypto/argon2/*.[ch]', 'Core/crypto/argon2/blake2/*.[ch]'):
    files += sorted(glob.glob(os.path.join(root, pat)))
seen, missing = set(), 0
for f in files:
    # A notice is "Copyright", an optional (c), then a year -- not the phrase
    # "Copyright and Related Rights" that CC0's own legal text is full of.
    for m in re.finditer(r'Copyright (?:\([cC]\) )?[0-9][^\n]*', open(f, errors='replace').read()):
        line = norm(re.sub(r'[\s*/]+$', '', m.group(0)))
        if line in seen: continue
        seen.add(line)
        if line not in text:
            missing += 1
            print('  not in the notices: %s (%s)' % (line, os.path.relpath(f, root)))
print('missing: %d' % missing)
PY
}
n=$(check_notices "$ROOT" "$ROOT/THIRD_PARTY_NOTICES.md" | tee "$WORK/notices.txt" | sed -n 's/^missing: //p')
grep '^  not in' "$WORK/notices.txt" | head -5
[ "$n" = "0" ] && ok "THIRD_PARTY_NOTICES.md names every copyright in the third-party code" \
               || bad "THIRD_PARTY_NOTICES.md names every copyright in the third-party code" "$n missing"
grep -v "Niels Provos" "$ROOT/THIRD_PARTY_NOTICES.md" > "$WORK/notices-short.md"
n=$(check_notices "$ROOT" "$WORK/notices-short.md" | sed -n 's/^missing: //p')
[ "$n" = "1" ] && ok "self-check: a notice with one holder removed is caught" \
               || bad "self-check: a notice with one holder removed is caught" "counted $n"

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
