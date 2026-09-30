#!/usr/bin/env bash
# The nightly fuzz campaign, as one script so the workflow holds no logic.
#
#   bash scripts/ci_nightly_fuzz.sh campaign          distil, fuzz both modes, distil
#   bash scripts/ci_nightly_fuzz.sh prune <keep-key>  delete every other corpus cache
#
# Why the campaign distils twice, and fails when it cannot:
#
# From 2026-09-05 to 09-30 the distil step failed on every runner (fuzz-merge
# wrote into a .fuzz/logs/ that CI never restores) and an `|| true` hid it.
# The corpus was never merged. It grew by about 500 units a night to 90 GB on
# disk -- two 4.9 GB cache entries that filled the repository's whole 10 GB
# Actions quota -- and four runners died "lost communication" restoring or
# replaying it. A merge that fails is now a red step, and the merged corpus
# must fit FUZZ_CORPUS_BUDGET_MB per mode before it is saved.
#
# Merging also quarantines: libFuzzer's merge survives a crashing unit by
# restarting and leaving that unit out, so a crasher found tonight is not
# replayed into tomorrow's campaign. The artifact keeps it.
#
# Environment (the workflow sets these; the defaults are a developer Mac's):
#   FUZZ_TIME          seconds per mode              (3600)
#   FUZZ_JOBS          libFuzzer jobs per mode       (2)
#   FUZZ_RSS_MB        per-job RSS ceiling           (make's default)
#   FUZZ_MERGE_RSS_MB  merge RSS ceiling             (make's default)
#   FUZZ_CORPUS_BUDGET_MB  per-mode ceiling after merging (1024)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# What the runner had left. Four nightlies were lost without a word about
# memory or disk; the next one that dies should at least say how close it was.
resources() {
    echo "── resources after $1"
    vm_stat 2>/dev/null | awk '/Pages (free|active|inactive|wired down)/' || true
    df -h "$ROOT" | tail -1 || true
    du -sh "$ROOT/.fuzz/corpus"/* 2>/dev/null || true
}

make_args=()
[ -n "${FUZZ_RSS_MB:-}" ]       && make_args+=("FUZZ_RSS_MB=$FUZZ_RSS_MB")
[ -n "${FUZZ_MERGE_RSS_MB:-}" ] && make_args+=("FUZZ_MERGE_RSS_MB=$FUZZ_MERGE_RSS_MB")

distil() {
    make fuzz-merge ${make_args[@]+"${make_args[@]}"}
    resources "distilling"
}

campaign() {
    local secs="${FUZZ_TIME:-3600}" jobs="${FUZZ_JOBS:-2}"
    mkdir -p .fuzz/corpus/ro .fuzz/corpus/rw .fuzz/crashes .fuzz/logs

    echo "::group::distil the restored corpus"
    distil
    echo "::endgroup::"

    # `|| true`, deliberately: libFuzzer exits non-zero for a crash, and the
    # workflow's fuzz-check step is the judge of what the crashes directory
    # holds. What must NOT be swallowed is the merge on either side.
    local mode
    for mode in fuzz fuzz-rw; do
        echo "::group::$mode for ${secs}s x $jobs jobs"
        make "$mode" FUZZ_TIME="$secs" FUZZ_JOBS="$jobs" \
            ${make_args[@]+"${make_args[@]}"} || true
        resources "$mode"
        echo "::endgroup::"
    done

    echo "::group::distil what the campaign added"
    distil
    echo "::endgroup::"

    local budget="${FUZZ_CORPUS_BUDGET_MB:-1024}" over=0 mb
    for mode in ro rw; do
        mb=$(du -sm ".fuzz/corpus/$mode" | cut -f1)
        echo "corpus ($mode): ${mb} MB of a ${budget} MB budget"
        [ "$mb" -le "$budget" ] || over=1
    done
    if [ "$over" = 1 ]; then
        echo "::error::the merged corpus is over its budget; it will not be saved"
        exit 1
    fi
}

# Keep exactly one corpus cache: the one this run saved. Everything else under
# the prefix is superseded -- earlier nightlies, the pre-v2 entries, and the
# per-branch keys ci.yml used to save before it became a reader.
prune() {
    local keep="$1" key
    command -v gh >/dev/null || { echo "prune: gh is not installed"; exit 1; }
    gh cache list --key fuzz-corpus- --limit 100 --json key --jq '.[].key' \
        | while read -r key; do
            [ "$key" = "$keep" ] && continue
            echo "deleting superseded cache $key"
            gh cache delete "$key"
        done
}

case "${1:-}" in
    campaign) campaign ;;
    prune)    [ -n "${2:-}" ] || { echo "usage: $0 prune <keep-key>"; exit 2; }
              prune "$2" ;;
    *)        echo "usage: $0 campaign | prune <keep-key>"; exit 2 ;;
esac
