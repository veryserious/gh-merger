#!/usr/bin/env bash
#
# Low-touch PR merge queue for the org PRs.
#
# Every POLL_INTERVAL seconds:
#   - finds your open PRs in the org
#   - if a PR is approved and auto-merge isn't on yet, enables it (squash)
#   - if a PR is approved, has auto-merge on, and is behind main, updates the branch
#
# Requires: gh (authenticated), jq
#
# Usage:
#   ./pr-merge-queue.sh --org <org>              run the poll loop forever
#   ./pr-merge-queue.sh --org <org> --once       run a single pass and exit
#   ./pr-merge-queue.sh --org <org> --dry-run    log actions instead of taking them (implies --once)
#
# Examples:
#   ./pr-merge-queue.sh --org my-org
#   ./pr-merge-queue.sh --org my-org --dry-run

set -uo pipefail

ORG=""
POLL_INTERVAL_SECONDS=1800
MERGE_METHOD="squash" # squash | merge | rebase
DRY_RUN=false
RUN_ONCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org) ORG="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; RUN_ONCE=true; shift ;;
    --once) RUN_ONCE=true; shift ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$ORG" ]]; then
  echo "usage: $0 --org <org> [--once] [--dry-run]" >&2
  exit 1
fi

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1"
}

run_once() {
  local prs
  if ! prs=$(gh search prs \
    --owner "$ORG" \
    --author "@me" \
    --state open \
    --limit 100 \
    --json number,title,url,repository,isDraft 2>&1); then
    log "ERROR: failed to list PRs: $prs"
    return
  fi

  local count
  count=$(jq 'length' <<<"$prs")
  log "found $count open PR(s) authored by you in $ORG"

  jq -c '.[]' <<<"$prs" | while read -r pr; do
    local number repo title is_draft
    number=$(jq -r '.number' <<<"$pr")
    repo=$(jq -r '.repository.nameWithOwner' <<<"$pr")
    title=$(jq -r '.title' <<<"$pr")
    is_draft=$(jq -r '.isDraft' <<<"$pr")
    local label="$repo#$number"

    if [[ "$is_draft" == "true" ]]; then
      log "$label: skipping (draft) - $title"
      continue
    fi

    local detail
    if ! detail=$(gh pr view "$number" -R "$repo" \
      --json reviewDecision,autoMergeRequest,mergeStateStatus,state 2>&1); then
      log "$label: ERROR fetching PR detail: $detail"
      continue
    fi

    local state review_decision auto_merge merge_state
    state=$(jq -r '.state' <<<"$detail")
    review_decision=$(jq -r '.reviewDecision' <<<"$detail")
    auto_merge=$(jq -r '.autoMergeRequest' <<<"$detail")
    merge_state=$(jq -r '.mergeStateStatus' <<<"$detail")

    if [[ "$state" != "OPEN" ]]; then
      log "$label: skipping (state=$state)"
      continue
    fi

    if [[ "$review_decision" != "APPROVED" ]]; then
      log "$label: not approved yet (reviewDecision=$review_decision) - $title"
      continue
    fi

    if [[ "$auto_merge" == "null" ]]; then
      if [[ "$DRY_RUN" == "true" ]]; then
        log "$label: [DRY-RUN] would enable auto-merge ($MERGE_METHOD) - $title"
        continue
      fi
      log "$label: approved, enabling auto-merge ($MERGE_METHOD) - $title"
      local out
      if ! out=$(gh pr merge "$number" -R "$repo" --auto --"$MERGE_METHOD" 2>&1); then
        log "$label: ERROR enabling auto-merge: $out"
      fi
      continue
    fi

    log "$label: approved, auto-merge already enabled (mergeStateStatus=$merge_state)"
    if [[ "$merge_state" == "BEHIND" ]]; then
      if [[ "$DRY_RUN" == "true" ]]; then
        log "$label: [DRY-RUN] would update branch from main"
        continue
      fi
      log "$label: behind main, updating branch"
      local out
      if ! out=$(gh api --method PUT "repos/$repo/pulls/$number/update-branch" 2>&1); then
        log "$label: ERROR updating branch: $out"
      fi
    fi
  done
}

if [[ "$RUN_ONCE" == "true" ]]; then
  [[ "$DRY_RUN" == "true" ]] && log "starting single dry-run pass for org=$ORG"
  run_once
  exit 0
fi

log "starting PR merge queue for org=$ORG, polling every ${POLL_INTERVAL_SECONDS}s (ctrl-c to stop)"
while true; do
  run_once
  log "sleeping ${POLL_INTERVAL_SECONDS}s"
  sleep "$POLL_INTERVAL_SECONDS"
done
