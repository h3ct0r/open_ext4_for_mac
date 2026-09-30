#!/usr/bin/env bash
# Is every change to lwext4's code a numbered, recorded change?
#
#   bash scripts/check_lwext4_ledger.sh
#
# The rules (docs/lwext4-changes.md): a commit that changes Core/lwext4's
# src/ or include/ is `lwext4 NNNN: <what>` with a matching
# `Lwext4-Change: NNNN` trailer, or `lwext4 vendor: <what>` for a change that
# alters no behaviour. Every NNNN has a ledger row; every ledger row has its
# commit; no ID is used twice.
#
# This is what the patch series used to enforce by construction -- a change
# had to be a numbered file or the build refused it -- and what an in-tree
# fork loses unless something checks. Run by the docs suite, so by CI and by
# `make validate`.
#
# Exit 0 when the history keeps the rules, 1 when not, 77 when it cannot tell
# (a shallow clone, which has no history to read).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
LEDGER=docs/lwext4-changes.md

if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" != "false" ]; then
  echo "ledger: a shallow clone has no history to check (fetch-depth: 0 does)"
  exit 77
fi

# The import commit: by its tag when the clone has tags, by its subject when
# it does not. Its SHA is in the ledger's introduction too, for a person.
base=$(git rev-parse -q --verify 'lwext4-upstream-58bcf89a^{commit}' 2>/dev/null \
       || git log -1 --format=%H --grep='^lwext4 vendor: import upstream 58bcf89a')
if [ -z "$base" ]; then
  echo "ledger: the upstream import commit is not in this history"
  exit 1
fi

python3 - "$base" "$LEDGER" <<'PY'
import re, subprocess, sys
base, ledger_path = sys.argv[1], sys.argv[2]
rows = set(re.findall(r'^\| `(\d{4})-', open(ledger_path).read(), re.M))

log = subprocess.run(
    ['git', 'log', '--no-merges', '--reverse', '--format=%H%x00%s%x00%B%x1e',
     f'{base}..HEAD', '--', 'Core/lwext4/src', 'Core/lwext4/include'],
    capture_output=True, text=True, check=True).stdout

bad, seen = [], {}
for rec in filter(None, (r.strip('\n') for r in log.split('\x1e'))):
    sha, subject, body = rec.split('\x00', 2)
    short = sha[:9]
    m = re.match(r'lwext4 (\d{4}|vendor): ', subject)
    if not m:
        bad.append(f'{short} changes lwext4 code but its subject is not '
                   f'"lwext4 NNNN:" or "lwext4 vendor:": {subject}')
        continue
    if m.group(1) == 'vendor':
        continue
    num = m.group(1)
    trailers = re.findall(r'^Lwext4-Change: (\d{4})\s*$', body, re.M)
    if trailers != [num]:
        bad.append(f'{short} is lwext4 {num} but carries Lwext4-Change: {trailers or "none"}')
    if num not in rows:
        bad.append(f'{short} is lwext4 {num}, which has no row in {ledger_path}')
    if num in seen:
        bad.append(f'{short} reuses lwext4 {num}, already {seen[num]}')
    seen.setdefault(num, short)

for num in sorted(rows - set(seen)):
    bad.append(f'ledger row {num} has no commit carrying Lwext4-Change: {num}')

for b in bad:
    print(f'  {b}')
print(f'ledger: {len(seen)} numbered change(s) since the import, {len(rows)} row(s), '
      f'{len(bad)} problem(s)')
sys.exit(1 if bad else 0)
PY
