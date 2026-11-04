#!/usr/bin/env bash
#
# Low-touch PR merge queue for the org PRs.
#
# Every POLL_INTERVAL seconds:
#   - finds your open PRs in the org
#   - if a PR is ready (see below) and auto-merge isn't on yet, enables it (squash),
#     pinned to the head commit it checked
#   - if a PR has auto-merge on but has since become blocked, disables it
#   - if a PR has auto-merge on and is behind main, updates the branch
#
# A PR is ready when all of these hold:
#   - not a draft, and based on the repository's default branch (stacked PRs are left
#     to `gh stack merge`)
#   - approved: reviewDecision is APPROVED, or it is empty and a human's latest review is
#     APPROVED with none CHANGES_REQUESTED. Bot reviews never count.
#   - the approval covers the head commit: it was given on the head, or every commit
#     since is a merge commit (e.g. one this script made by updating the branch)
#   - no unanswered comments: no unresolved review thread whose last comment is someone
#     else's, and no conversation comment or review body from someone else after your
#     last comment. CI notices (coverage, bundle size, deploy previews, ephemeral builds,
#     Copilot overviews) don't count.
#   - CI has checks, none failing and none pending
#   - no merge conflicts
#
# Auto-merge only waits for the repo's *required* checks. In a repo with none, enabling it
# merges straight away, so the CI check above is the only CI gate there.
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

read -r -d '' PRS_QUERY <<'GRAPHQL'
query($q: String!, $endCursor: String) {
  search(query: $q, type: ISSUE, first: 25, after: $endCursor) {
    pageInfo { hasNextPage endCursor }
    nodes {
      ... on PullRequest {
        number title isDraft mergeable mergeStateStatus baseRefName headRefOid reviewDecision
        autoMergeRequest { enabledAt }
        repository { nameWithOwner defaultBranchRef { name } }
        latestReviews(first: 50) { nodes { state commit { oid } author { __typename login } } }
        reviews(last: 100) { nodes { state body submittedAt author { __typename login } } }
        comments(last: 100) { nodes { body createdAt author { __typename login } } }
        reviewThreads(first: 100) {
          nodes { isResolved comments(last: 50) { nodes { createdAt author { __typename login } } } }
        }
        commits(last: 100) {
          nodes { commit {
            oid
            parents { totalCount }
            statusCheckRollup { contexts(first: 100) { totalCount nodes {
              __typename
              ... on CheckRun { status conclusion }
              ... on StatusContext { state }
            } } }
          } }
        }
      }
    }
  }
}
GRAPHQL

# Turns the search pages into one object per PR with the reasons it isn't ready.
# `blockers` stop auto-merge being enabled and switch it off if it is on.
# `waits` (CI still pending, or no checks yet) only stop it being enabled: once on,
# auto-merge waits for required checks itself.
read -r -d '' EVALUATE <<'JQ'
def who: (.author.login // "ghost");
def is_bot: (.author // {}) as $a
  | ($a.__typename == "Bot") or (($a.login // "") | endswith("[bot]"))
    or ($a.login == "copilot-pull-request-reviewer");
def is_noise:
  (who | sub("\\[bot\\]$"; "")) as $name
  | any(["codecov", "cloudflare-workers-and-pages", "vercel", "netlify", "r2r-ephemeral-stale"][]; . == $name)
    or ((.body // "") | test("^\\s*<!-- (add-pr-comment:|ccr-overview)"))
    or ((.body // "") | contains("Ephemeral build completed"));
def plural($n; $word): "\($n) \($word)\(if $n == 1 then "" else "s" end)";

[.[].data.search.nodes[] | select(.number != null)]
| map(
    . as $pr
    | [.commits.nodes[].commit] as $commits
    | ($commits | last // {}) as $head
    | (.reviewThreads.nodes) as $threads

    # approval
    | [.latestReviews.nodes[] | select(is_bot | not)] as $human
    | [$human[] | select(.state == "APPROVED")] as $approvals
    | ((.reviewDecision == "APPROVED")
        or ((.reviewDecision // "") == "" and ($approvals | length) > 0
            and ([$human[] | select(.state == "CHANGES_REQUESTED")] | length) == 0)) as $approved
    | [$approvals[]
        | .commit.oid as $oid
        | ([$commits | to_entries[] | select(.value.oid == $oid) | .key][0]) as $i
        | select($i != null and all($commits[$i + 1:][]; .parents.totalCount > 1))
        | who] as $fresh_approvers

    # unanswered comments
    | ([(.comments.nodes[] | select(who == $me) | .createdAt),
        (.reviews.nodes[] | select(who == $me) | .submittedAt // empty),
        ($threads[].comments.nodes[] | select(who == $me) | .createdAt)] | max // "") as $last_mine
    | ([$threads[] | select((.isResolved | not) and ((.comments.nodes | last | who) != $me))] | length) as $open_threads
    | ([.comments.nodes[] | select(who != $me and .createdAt > $last_mine and (is_noise | not))] | length) as $open_comments
    | ([.reviews.nodes[] | select(who != $me and ((.body // "") | test("\\S"))
          and (.state == "COMMENTED" or .state == "CHANGES_REQUESTED")
          and (.submittedAt // "") > $last_mine and (is_noise | not))] | length) as $open_reviews
    | ($open_threads + $open_comments + $open_reviews) as $unanswered

    # CI
    | ($head.statusCheckRollup.contexts // {totalCount: 0, nodes: []}) as $ci
    | ([$ci.nodes[] | select(
          (.__typename == "CheckRun" and .status == "COMPLETED"
             and (.conclusion | IN("SUCCESS", "SKIPPED", "NEUTRAL") | not))
          or (.__typename == "StatusContext" and (.state | IN("FAILURE", "ERROR"))))] | length) as $failing
    | ([$ci.nodes[] | select(
          (.__typename == "CheckRun" and .status != "COMPLETED")
          or (.__typename == "StatusContext" and (.state | IN("PENDING", "EXPECTED"))))] | length) as $pending

    | ($pr.repository.defaultBranchRef.name // $pr.baseRefName) as $default
    | {
        repo: .repository.nameWithOwner,
        number,
        title,
        head: .headRefOid,
        autoMerge: (.autoMergeRequest != null),
        mergeState: .mergeStateStatus,
        approvers: ($fresh_approvers | unique),
        blockers: [
          (if .isDraft then "draft" else empty end),
          (if .baseRefName != $default then "stacked on \(.baseRefName), merge with gh stack merge" else empty end),
          (if ($approved | not) then "not approved (reviewDecision=\(.reviewDecision // "none"))"
           elif ($fresh_approvers | length) == 0 then "approval predates the latest commit"
           else empty end),
          (if $unanswered > 0 then plural($unanswered; "unanswered comment") else empty end),
          (if $failing > 0 then "CI: \($failing) failing" else empty end),
          (if .mergeable == "CONFLICTING" then "merge conflicts" else empty end)
        ],
        waits: [
          (if $ci.totalCount == 0 then "CI: no checks yet" else empty end),
          (if $pending > 0 then "CI: \($pending) pending" else empty end)
        ]
      }
  )
JQ

run_once() {
  local me pages prs
  if ! me=$(gh api user --jq .login 2>&1); then
    log "ERROR: failed to look up your login: $me"
    return
  fi
  if ! pages=$(gh api graphql --paginate \
    -f query="$PRS_QUERY" \
    -f q="is:pr is:open author:@me org:$ORG archived:false" 2>&1); then
    log "ERROR: failed to list PRs: $pages"
    return
  fi
  if ! prs=$(jq -s -c --arg me "$me" "$EVALUATE" <<<"$pages" 2>&1); then
    log "ERROR: failed to evaluate PRs: $prs"
    return
  fi

  local count
  count=$(jq 'length' <<<"$prs")
  log "found $count open PR(s) authored by you in $ORG"

  jq -c '.[]' <<<"$prs" | while read -r pr; do
    local number repo title head auto_merge merge_state blockers waits approvers
    number=$(jq -r '.number' <<<"$pr")
    repo=$(jq -r '.repo' <<<"$pr")
    title=$(jq -r '.title' <<<"$pr")
    head=$(jq -r '.head' <<<"$pr")
    auto_merge=$(jq -r '.autoMerge' <<<"$pr")
    merge_state=$(jq -r '.mergeState' <<<"$pr")
    blockers=$(jq -r '.blockers | join("; ")' <<<"$pr")
    waits=$(jq -r '.waits | join("; ")' <<<"$pr")
    approvers=$(jq -r '.approvers | join(", ")' <<<"$pr")
    local label="$repo#$number"
    local out

    if [[ "$auto_merge" == "true" ]]; then
      if [[ -n "$blockers" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
          log "$label: [DRY-RUN] would disable auto-merge ($blockers) - $title"
          continue
        fi
        log "$label: blocked, disabling auto-merge ($blockers) - $title"
        if ! out=$(gh pr merge "$number" -R "$repo" --disable-auto 2>&1); then
          log "$label: ERROR disabling auto-merge: $out"
        fi
        continue
      fi

      log "$label: auto-merge already enabled (mergeStateStatus=$merge_state)"
      if [[ "$merge_state" == "BEHIND" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
          log "$label: [DRY-RUN] would update branch from main"
          continue
        fi
        log "$label: behind main, updating branch"
        if ! out=$(gh api --method PUT "repos/$repo/pulls/$number/update-branch" 2>&1); then
          log "$label: ERROR updating branch: $out"
        fi
      fi
      continue
    fi

    if [[ -n "$blockers" || -n "$waits" ]]; then
      local reasons="$blockers"
      [[ -n "$waits" ]] && reasons="${reasons:+$reasons; }$waits"
      log "$label: not ready ($reasons) - $title"
      continue
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      log "$label: [DRY-RUN] would enable auto-merge ($MERGE_METHOD) at ${head:0:7}, approved by $approvers - $title"
      continue
    fi
    log "$label: ready, approved by $approvers, enabling auto-merge ($MERGE_METHOD) at ${head:0:7} - $title"
    if ! out=$(gh pr merge "$number" -R "$repo" --auto --"$MERGE_METHOD" --match-head-commit "$head" 2>&1); then
      log "$label: ERROR enabling auto-merge: $out"
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
