#!/usr/bin/env bash
# Every image that was once a finding, run again.
#
# A fuzzer finds a bug once. This is what stops it coming back. Each row in
# Tests/fixtures/hostile/MANIFEST is an image that crashed, hung, tripped a
# sanitizer, or was written to by a read-only verb, kept gzipped beside a JSON
# recipe describing which bytes were changed and why.
#
# Three assertions per verb, the same three every time:
#
#   * exit code below 128 -- no abort, no signal, no watchdog kill
#   * no sanitizer line in the output
#   * the image byte-identical afterwards
#
# The third is not decoration. A read verb that modifies the medium is a data
# safety bug whatever it returns, and it is the class that an exit code alone
# cannot see.
#
# Fast: seconds, offline, no Docker, no extension. It belongs in every round.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)/.."
ROOT="$(cd "$ROOT" && pwd)"
. "$ROOT/Tests/lib.sh"

DUMP="$ROOT/build/bin/ext4dump"
HOSTILE="$ROOT/Tests/fixtures/hostile"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ext4-hostile.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

[ -x "$DUMP" ] || { echo "  build first: make tools"; exit 77; }
[ -f "$HOSTILE/MANIFEST" ] || { echo "  no $HOSTILE/MANIFEST"; exit 77; }

# run_deadline comes from Tests/lib.sh.

md5of() { md5 -q "$1" 2>/dev/null || md5sum "$1" | cut -d' ' -f1; }

# Say which build is judging, for the same reason the mutation campaign does.
# Several of these fixtures are memory-safety findings: an overflow that reads
# past a buffer returns the wrong answer without crashing, so against a
# release build the row passes whatever the code does. It is still worth
# running there -- crashes, hangs and writes are all real classes and all
# visible -- but a green release run is the narrower claim.
SANITIZED=no
DUMP_SYMS="$(nm "$DUMP" 2>/dev/null)"
case "$DUMP_SYMS" in *__asan*) SANITIZED=yes ;; esac

echo "hostile image regressions"
if [ "$SANITIZED" = "yes" ]; then
  echo "  sanitizer build: memory-safety rows are real assertions here"
else
  echo "  release build: crashes, hangs and writes only."
  echo "  Rows that were memory-safety findings pass vacuously; 'make test-asan'"
  echo "  is where they mean something."
fi
echo ""

rows=0
while read -r file mode verbs fix note; do
  case "$file" in ''|'#'*) continue ;; esac
  rows=$(( rows + 1 ))

  gz="$HOSTILE/$file"
  if [ ! -f "$gz" ]; then
    bad "$file exists" "the MANIFEST names an image that is not here"
    continue
  fi

  img="$WORK/${file%.img.gz}.img"
  if ! gunzip -c "$gz" > "$img" 2>/dev/null; then
    bad "$file unpacks" "gunzip failed"
    continue
  fi

  before=$(md5of "$img")
  failed=0

  IFS=',' read -r -a verb_list <<<"$verbs"
  for v in "${verb_list[@]}"; do
    # '+' stands in for the space, so the MANIFEST stays one row per fixture.
    argv=$(printf '%s' "$v" | tr '+' ' ')
    # shellcheck disable=SC2086
    out=$(run_deadline 30 "$DUMP" "$img" $argv 2>&1); rc=$?

    if [ "$rc" -ge 128 ]; then
      bad "$file: $argv does not crash or hang" "rc=$rc (fix: $fix)"
      failed=1
      continue
    fi
    if grep -qE 'AddressSanitizer|LeakSanitizer|runtime error:' <<<"$out"; then
      bad "$file: $argv is free of sanitizer reports" \
          "$(grep -m1 -E 'AddressSanitizer|runtime error:' <<<"$out")"
      failed=1
      continue
    fi
  done

  after=$(md5of "$img")
  if [ "$before" != "$after" ]; then
    bad "$file: the read verbs leave the image untouched" \
        "md5 changed -- a read-only verb wrote to the medium"
    failed=1
  fi

  # rw rows additionally take the write path and then look at what it left.
  if [ "$mode" = "rw" ] && [ "$failed" -eq 0 ]; then
    # The script's OUTPUT matters as much as its exit code, and discarding it
    # is how the first version of this suite reported a pass on a fixture
    # whose whole finding was a "runtime error:" line printed during journal
    # replay. UBSan without -fno-sanitize-recover prints and carries on, so
    # the exit code says nothing.
    # A file, not a heredoc: run_deadline backgrounds its command, and an
    # asynchronous command's stdin is /dev/null. See the check below.
    # The same shape as the in-process harness's write pass, and for the same
    # reason it has that shape: each step's state is the next step's input,
    # and a step that FAILS is part of the state -- fixture 0014's finding is
    # a create that aborts followed by a create that trips over what the
    # abort left behind. So the script keeps going after a failure
    # (EXT4DUMP_SCRIPT_CONTINUE), and creates in the root as well as in the
    # directory, in case the directory never came to be.
    printf 'mkdir /hostile\ncreate /hostile/a\ncreate /a\nwrite /a some-bytes\nrm /a\nrm /hostile/a\n' \
      > "$WORK/rw-script.txt"
    EXT4DUMP_SCRIPT_CONTINUE=1 \
    run_deadline 60 "$DUMP" "$img" script "$WORK/rw-script.txt" > "$WORK/rw-out.txt" 2>&1
    rc=$?
    # The script has to have RUN. For its first weeks this suite fed the
    # script through a heredoc to run_deadline, which backgrounds the command,
    # and bash hands an asynchronous command /dev/null on stdin: ext4dump ran
    # an empty script, exited 0, and every rw row passed having written
    # nothing. ext4dump now ends every script with "script: N command(s) run"
    # and N must be nonzero -- a create that FAILS still counts as run, which
    # is the difference between "refused" and "never asked".
    if [ "$rc" -ge 128 ]; then
      # First, because a crash ends the process before any trailer.
      bad "$file: the write path does not crash or hang" "rc=$rc (fix: $fix)"
      failed=1
    elif grep -qE 'AddressSanitizer|LeakSanitizer|runtime error:' "$WORK/rw-out.txt"; then
      # Before the ran-at-all check: ASan on Linux exits 1 after its report,
      # below the crash arm, and never prints the trailer -- so the memory
      # bug would be reported as "the script never reached ext4dump".
      bad "$file: the write path is free of sanitizer reports" \
          "$(grep -m1 -E 'AddressSanitizer|runtime error:' "$WORK/rw-out.txt")"
      failed=1
    elif ! grep -qE "^script: [1-9][0-9]* command\(s\) run|^mount failed" "$WORK/rw-out.txt"; then
      # Either the script ran (N >= 1 -- a create that FAILS still counts), or
      # the read-write mount was refused before it could, and said so. A
      # refusal is a legitimate outcome for a fixture like 0005, whose whole
      # finding is that replay must not be believed. Silence is neither.
      bad "$file: the write script ran at all" \
          "$(grep -m1 '^script:' "$WORK/rw-out.txt" || echo 'no script: trailer and no refusal -- the script never reached ext4dump')"
      failed=1
    elif grep -qE 'AddressSanitizer|LeakSanitizer|runtime error:' "$WORK/rw-out.txt"; then
      bad "$file: the write path is free of sanitizer reports" \
          "$(grep -m1 -E 'AddressSanitizer|runtime error:' "$WORK/rw-out.txt")"
      failed=1
    else
      out=$(run_deadline 30 "$DUMP" "$img" check 2>&1); rc=$?
      if [ "$rc" -ge 128 ]; then
        bad "$file: check after writing does not crash" "rc=$rc"
        failed=1
      elif grep -qE 'AddressSanitizer|runtime error:' <<<"$out"; then
        bad "$file: check after writing is free of sanitizer reports" \
            "$(grep -m1 -E 'AddressSanitizer|runtime error:' <<<"$out")"
        failed=1
      fi
    fi
  fi

  [ "$failed" -eq 0 ] && ok "$file ($mode, ${#verb_list[@]} verb(s), fixed by $fix)"
done < "$HOSTILE/MANIFEST"

# A manifest that lists nothing is not a passing regression suite.
if [ "$rows" -eq 0 ]; then
  bad "the manifest lists any fixtures" "zero rows is not a clean run"
fi

echo ""
echo "  $rows fixture(s)"
finish
