# The stage runner shared by the CI entry points.
#
# There are two sets -- scripts/ci_offline.sh on macOS and scripts/ci_linux.sh
# on the Linux oracle -- and they differ only in which suites they list. The
# machinery for running one suite, giving it a deadline, extracting its own
# assertion count and printing one line about it is the same, and it had
# better stay the same: the summary is what a person reads to decide whether
# a run means anything, and two copies of it would drift into two different
# answers to "what does green mean".
#
# Source it, then call ci_begin, then stage ... for each suite, then ci_end.
#
#     SET_LABEL="linux oracle"
#     OUT="$ROOT/build/ci-linux"
#     . "$ROOT/scripts/ci_stages.sh"
#
# Exit status is ci_end's: 0 if every stage passed, 1 if any failed or timed
# out. A stage that exits 77 is a SKIP -- a missing prerequisite, not a pass.
# On a runner a skip is usually a mis-provisioned runner rather than a
# developer without Docker, so REQUIRE_ALL=1 turns one into a failure.

SET_LABEL="${SET_LABEL:-offline}"
OUT="${OUT:-$ROOT/build/ci}"
mkdir -p "$OUT"

# No stage may run forever. macOS has no timeout(1), so this is the same
# backgrounded-with-a-deadline shape run_full_validation.sh uses, and for the
# same reason: a stage that stops answering must be named, not waited on.
STAGE_TIMEOUT="${CI_STAGE_TIMEOUT:-900}"
REQUIRE_ALL="${REQUIRE_ALL:-0}"

NAMES=(); RESULTS=(); TALLIES=(); TIMES=()
FAILED=0; SKIPPED=0
TOT_PASS=0; TOT_FAIL=0

# Suites end with a line of the form "passed: N   failed: M" (some add more
# after it, like the write suite's e2fsck count). Extract the last one: that
# is the suite's own count of assertions, and printing it is the difference
# between "the suite exited 0" and "the suite ran 114 checks and exited 0".
# A suite that silently stopped testing anything shows up here as passed: 0.
#
# Prints "<passed> <failed>", or "- -" when the stage has no tally (a build, a
# typecheck). It must not accumulate the running totals itself: it is called
# in a command substitution, so anything it adds is added inside a subshell
# and thrown away -- which is how the first version of this script reported
# "assertions: 0 passed, 0 failed" under sixteen green suites.
# Three spellings, because three suites were written before there was a summary
# to read them. "passed: N failed: M" is the common one; the crash sweep counts
# in cut points recovered and unrecovered; the replay-speed suite ends with
# "PASS n FAIL m". A stage whose count cannot be read prints "-", which is how
# a suite that quietly stopped asserting anything used to look identical to one
# that asserted two hundred things.
tally_of() {
  local log="$1" line p f
  line=$(grep -oE 'passed:[[:space:]]*[0-9]+[[:space:]]+failed:[[:space:]]*[0-9]+' "$log" 2>/dev/null | tail -1)
  if [ -n "$line" ]; then
    p=$(printf '%s' "$line" | sed -nE 's/.*passed:[[:space:]]*([0-9]+).*/\1/p')
    f=$(printf '%s' "$line" | sed -nE 's/.*failed:[[:space:]]*([0-9]+).*/\1/p')
    printf '%s %s' "${p:--}" "${f:--}"; return 0
  fi
  line=$(grep -oE 'recovered:[[:space:]]*[0-9]+[[:space:]]+unrecovered:[[:space:]]*[0-9]+' "$log" 2>/dev/null | tail -1)
  if [ -n "$line" ]; then
    # Anchored: grep -oE already trimmed the line to start at "recovered:",
    # so there is no character before it for a [^n] guard to match against.
    p=$(printf '%s' "$line" | sed -nE 's/^recovered:[[:space:]]*([0-9]+).*/\1/p')
    f=$(printf '%s' "$line" | sed -nE 's/.*unrecovered:[[:space:]]*([0-9]+).*/\1/p')
    printf '%s %s' "${p:--}" "${f:--}"; return 0
  fi
  line=$(grep -oE '^PASS[[:space:]]+[0-9]+[[:space:]]+FAIL[[:space:]]+[0-9]+' "$log" 2>/dev/null | tail -1)
  if [ -n "$line" ]; then
    p=$(printf '%s' "$line" | sed -nE 's/^PASS[[:space:]]+([0-9]+).*/\1/p')
    f=$(printf '%s' "$line" | sed -nE 's/.*FAIL[[:space:]]+([0-9]+).*/\1/p')
    printf '%s %s' "${p:--}" "${f:--}"; return 0
  fi
  printf -- '- -'
}

# Say what went wrong, in the job log, without pasting the whole suite.
# Match the suites' own vocabulary first ("  FAIL  <what>"), then fall back to
# the tail, which is where a compiler or a make failure explains itself.
excerpt() {
  local log="$1"
  echo "      ── $log"
  # Strip the colour first. The suites print their verdicts as
  # "  <esc>[31mFAIL<esc>[0m the thing", so a pattern anchored on FAIL after
  # leading space matches nothing at all against the raw file -- the excerpt
  # then falls back to the tail and the failing assertion, which is the one
  # line anybody wants, scrolls off.
  local plain; plain=$(mktemp)
  sed -e $'s/\033\\[[0-9;]*[a-zA-Z]//g' "$log" > "$plain" 2>/dev/null
  local hits
  hits=$(grep -nE '^[[:space:]]*(FAIL|bad)[[:space:]]|FAIL:|error:|Assertion|AddressSanitizer|runtime error:' "$plain" 2>/dev/null | head -12)
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" | sed 's/^/      /'
  else
    tail -12 "$plain" 2>/dev/null | sed 's/^/      /'
  fi
  rm -f "$plain"
  echo ""
}

stage() {  # stage <name> <command...>
  local name="$1"; shift
  local log="$OUT/$name.log"
  local start=$SECONDS
  printf '  %-16s ' "$name"

  # Output to a file, not the terminal: one line per stage is the whole point
  # of this summary, and sixteen suites' worth of green ok-lines is the wall
  # of noise it exists instead of. The file is uploaded as a CI artifact.
  #
  # Job control so the deadline can take the process group down. Killing just
  # the subshell leaves the suite running and printing after it was declared
  # dead -- run_full_validation.sh learned that the expensive way.
  local rcfile; rcfile=$(mktemp)
  set -m
  ( "$@" >"$log" 2>&1; echo "${PIPESTATUS[0]}" >"$rcfile" ) &
  local pid=$! waited=0 rc=0
  set +m

  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$STAGE_TIMEOUT" ]; then
      kill -9 -- "-$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      rm -f "$rcfile"
      NAMES+=("$name"); RESULTS+=("TIMEOUT"); TALLIES+=("-"); TIMES+=("${STAGE_TIMEOUT}s")
      printf 'TIMEOUT  %-9s %ss\n' "-" "$STAGE_TIMEOUT"
      excerpt "$log"
      FAILED=1
      return 0
    fi
    sleep 2; waited=$(( waited + 2 ))
  done

  wait "$pid" 2>/dev/null
  rc=$(cat "$rcfile" 2>/dev/null || echo 1); rm -f "$rcfile"
  local elapsed=$(( SECONDS - start ))
  local p f t
  read -r p f <<<"$(tally_of "$log")"
  if [ "$p" = "-" ]; then
    t="-"
  else
    t="$p/$f"
    TOT_PASS=$(( TOT_PASS + p ))
    TOT_FAIL=$(( TOT_FAIL + f ))
  fi

  NAMES+=("$name"); TALLIES+=("$t"); TIMES+=("${elapsed}s")
  case "$rc" in
    0)
      RESULTS+=("PASS")
      printf 'PASS     %-9s %ss\n' "$t" "$elapsed"
      ;;
    77)
      RESULTS+=("SKIP"); SKIPPED=$(( SKIPPED + 1 ))
      printf 'SKIP     %-9s %ss\n' "$t" "$elapsed"
      head -3 "$log" 2>/dev/null | sed 's/^/      /'
      [ "$REQUIRE_ALL" = "1" ] && FAILED=1
      ;;
    *)
      RESULTS+=("FAIL"); FAILED=1
      printf 'FAIL     %-9s %ss  (rc=%s)\n' "$t" "$elapsed" "$rc"
      excerpt "$log"
      ;;
  esac
}

ci_begin() {
  echo "open_ext4_for_mac — $SET_LABEL CI set"
  echo "  $(date)"
  echo "  $(uname -srm), $( (cc --version || gcc --version) 2>/dev/null | head -1)"
  echo ""
  printf '  %-16s %-8s %-9s %s\n' "STAGE" "RESULT" "PASS/FAIL" "TIME"
}

ci_end() {
  local upper; upper=$(printf '%s' "$SET_LABEL" | tr '[:lower:]' '[:upper:]')
  echo ""
  echo "  ──────────────────────────────────────────────────"
  printf '  %d stage(s): %d passed, %d failed, %d skipped\n' \
    "${#NAMES[@]}" \
    "$(printf '%s\n' "${RESULTS[@]}" | grep -c '^PASS$')" \
    "$(printf '%s\n' "${RESULTS[@]}" | grep -cE '^(FAIL|TIMEOUT)$')" \
    "$SKIPPED"
  printf '  assertions: %d passed, %d failed\n' "$TOT_PASS" "$TOT_FAIL"
  printf '  logs: %s\n' "$OUT"
  echo ""

  if [ "$FAILED" -ne 0 ]; then
    echo "  $upper SET RED"
    printf '  did not pass:'
    local i
    for i in "${!NAMES[@]}"; do
      case "${RESULTS[$i]}" in
        PASS) ;;
        SKIP) [ "$REQUIRE_ALL" = "1" ] && printf ' %s(SKIP)' "${NAMES[$i]}" ;;
        *)    printf ' %s' "${NAMES[$i]}" ;;
      esac
    done
    echo ""
    return 1
  elif [ "$SKIPPED" -ne 0 ]; then
    # Green with something untested is not the same as green.
    echo "  $upper SET GREEN — but $SKIPPED stage(s) did not run"
  else
    echo "  $upper SET GREEN"
  fi
  return 0
}
