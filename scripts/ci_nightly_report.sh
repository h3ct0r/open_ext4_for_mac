#!/usr/bin/env bash
# Turn a nightly's verdict into something a person will see.
#
# The nightly went red on 2026-09-22 with a heap-buffer-overflow and stayed
# red, crash and all, for eight days before anyone looked: nothing but an
# e-mail said so, and the e-mail looked like every other one. A red night now
# opens an issue (or comments on the one already open), with the failing jobs
# and the sanitizer's own summary line; the next green night closes it.
#
# Run by the nightly's last job, never by hand. Needs:
#   GH_TOKEN, GH_REPO   issues: write, actions: read
#   RUN_ID, RUN_URL     this run
#   FUZZ_RESULT, SOAK_RESULT   needs.<job>.result
set -euo pipefail

: "${RUN_ID:?}" "${RUN_URL:?}" "${FUZZ_RESULT:?}" "${SOAK_RESULT:?}"
LABEL=nightly

open_issue=$(gh issue list --label "$LABEL" --state open --limit 1 \
                 --json number --jq '.[0].number // empty')

if [ "$FUZZ_RESULT" = success ] && [ "$SOAK_RESULT" = success ]; then
    if [ -n "$open_issue" ]; then
        gh issue close "$open_issue" --comment "Green again: $RUN_URL"
        echo "closed #$open_issue"
    else
        echo "green, and nothing open"
    fi
    exit 0
fi

# What failed, from the jobs API rather than from the jobs themselves: a job
# that lost its runner never gets to say anything.
body=$(mktemp)
trap 'rm -f "$body"' EXIT
{
    echo "Nightly run: $RUN_URL"
    echo ""
    echo "| job | result | failed step |"
    echo "|---|---|---|"
    gh api "repos/$GH_REPO/actions/runs/$RUN_ID/jobs" --paginate \
        --jq '.jobs[] | select(.name != "file the night")
              | [.steps[]? | select(.conclusion == "failure") | .name] as $failed
              | "| \(.name) | \(.conclusion // .status) | \(if .conclusion == "success" then "" elif ($failed | length) == 0 then "(none: runner lost, timed out or cancelled)" else ($failed | join(", ")) end) |"'
    echo ""
    # The sanitizer's one-line verdict and the top of its stack say more than
    # any job name. Pulled per failed job; a log that is gone is skipped.
    for job in $(gh api "repos/$GH_REPO/actions/runs/$RUN_ID/jobs" --paginate \
                     --jq '.jobs[] | select(.conclusion == "failure") | .id'); do
        # --allow-escape-sequences: gh refuses to print a response with the
        # colour codes every job log carries, and prints nothing instead.
        log=$(gh api --allow-escape-sequences \
                  "repos/$GH_REPO/actions/jobs/$job/logs" 2>/dev/null) || continue
        hits=$(printf '%s\n' "$log" \
                 | sed -E 's/^[0-9TZ:.-]+ //; s/\x1b\[[0-9;]*m//g' \
                 | grep -E 'SUMMARY: |Test unit written to|^    #[0-4] |FAIL  |::error::' \
                 | head -20) || true
        if [ -n "$hits" ]; then
            echo '```'
            printf '%s\n' "$hits"
            echo '```'
        fi
    done
    echo ""
    echo "Triage: Tests/fuzz/README.md, 'The triage loop'. This issue closes itself on the next green night."
} > "$body"

gh label create "$LABEL" --color B60205 \
    --description "The nightly is red" >/dev/null 2>&1 || true

if [ -n "$open_issue" ]; then
    gh issue comment "$open_issue" --body-file "$body"
    echo "commented on #$open_issue"
else
    gh issue create --label "$LABEL" \
        --title "nightly is red ($(date -u +%Y-%m-%d))" --body-file "$body"
fi
