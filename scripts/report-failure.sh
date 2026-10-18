#!/usr/bin/env bash
# Opens or updates the one open blocked-build issue, and the first time a key fails
# with a conflict or a build error, tells the patch fixer through a webhook.
#
# Env:
#   RELEASE_REPO, ISSUE_LABEL, PATCH_REPO, PATCH_BRANCHES, UPSTREAM_REPO
#   KIND            conflict | missing-branch | empty | prepare | build | publish
#   KEY, UPSTREAM_TAG, UPSTREAM_SHA, PATCH_SHAS            from pick-build.sh
#   CONFLICTS, FAILED_BRANCH, FAILED_COMMIT                from apply-patches.sh (optional)
#   RUN_URL         the failed run
#   T3_PATCH_FIX_WEBHOOK  optional; receives the JSON payload once per key
#   DRY_RUN         "true" prints the issue and payload instead of writing anything
set -euo pipefail

: "${RELEASE_REPO:?}" "${PATCH_REPO:?}" "${PATCH_BRANCHES:?}" "${UPSTREAM_REPO:?}"
: "${KIND:?}" "${KEY:?}" "${UPSTREAM_TAG:?}" "${UPSTREAM_SHA:?}" "${PATCH_SHAS:?}" "${RUN_URL:?}"
ISSUE_LABEL=${ISSUE_LABEL:-patch-conflict}
CONFLICTS=${CONFLICTS:-}
[[ -n $CONFLICTS ]] || CONFLICTS='[]'
FAILED_BRANCH=${FAILED_BRANCH:-}
FAILED_COMMIT=${FAILED_COMMIT:-}
DRY_RUN=${DRY_RUN:-false}
WEBHOOK=${T3_PATCH_FIX_WEBHOOK:-}

case $KIND in
  conflict) summary="\`$FAILED_BRANCH\` does not apply to \`$UPSTREAM_TAG\`" ;;
  missing-branch) summary="patch branch \`$FAILED_BRANCH\` does not exist on $PATCH_REPO" ;;
  empty) summary="no patch branch has commits to apply to \`$UPSTREAM_TAG\`" ;;
  prepare) summary="preparing the patched source for \`$UPSTREAM_TAG\` failed" ;;
  build) summary="the Windows build of patched \`$UPSTREAM_TAG\` failed" ;;
  publish) summary="publishing patched \`$UPSTREAM_TAG\` failed" ;;
  *) summary="patched \`$UPSTREAM_TAG\` failed ($KIND)" ;;
esac

if [[ $DRY_RUN == true ]]; then
  existing='{}'
else
  # Idempotent; lets the first failure in a fresh repo label its issue.
  gh label create "$ISSUE_LABEL" -R "$RELEASE_REPO" --color D93F0B \
    --description "Patched build blocked: patch conflict or build failure" --force >/dev/null
  existing=$(gh issue list -R "$RELEASE_REPO" --label "$ISSUE_LABEL" --state open --limit 1 \
    --json number,url,body --jq '.[0] // {}')
fi
number=$(jq -r '.number // empty' <<<"$existing")
issue_url=$(jq -r '.url // empty' <<<"$existing")
notified=$(jq -r '.body // ""' <<<"$existing" | tr -d '\r' | sed -n 's/^notified: //p' | head -n 1)

# Only these two are something the fixer can act on: a conflict to resolve or a
# build the patches broke. "Once per key" holds even if the POST fails, so a
# flaky endpoint never turns hourly runs into repeated fix attempts.
notify=false
if [[ ($KIND == conflict || $KIND == build) && -n $WEBHOOK && $notified != "$KEY" ]]; then notify=true; fi

set -f
# shellcheck disable=SC2206 # split on whitespace on purpose; globbing is off
branches=($PATCH_BRANCHES)
set +f
IFS=, read -r -a shas <<<"$PATCH_SHAS"

render() {
  echo "<!-- Managed by .github/workflows/patched-desktop-release.yml, which reads the key and notified lines. -->"
  echo "key: $KEY"
  if [[ $notify == true || $notified == "$KEY" ]]; then echo "notified: $KEY"; fi
  echo
  echo "**Patched desktop build blocked:** $summary."
  echo
  echo "- Kind: \`$KIND\`"
  echo "- Upstream: [\`$UPSTREAM_TAG\`](https://github.com/$UPSTREAM_REPO/releases/tag/$UPSTREAM_TAG) at \`$UPSTREAM_SHA\`"
  echo "- Patch branches on $PATCH_REPO, in order:"
  for i in "${!branches[@]}"; do echo "  - \`${branches[$i]}\` at \`${shas[$i]:-?}\`"; done
  if [[ -n $FAILED_COMMIT ]]; then echo "- Failed commit: \`${FAILED_COMMIT%% *}\` ${FAILED_COMMIT#* }"; fi
  if [[ $(jq length <<<"$CONFLICTS") -gt 0 ]]; then
    echo "- Conflicting files:"
    jq -r '.[] | "  - `" + . + "`"' <<<"$CONFLICTS"
  fi
  echo "- Run: $RUN_URL"
  echo
  echo "### Unblocking"
  case $KIND in
    conflict | build)
      echo "Rebase the branch's own commits onto the nightly (not onto upstream main, which may be ahead of it), fix, and push:"
      echo
      echo '```sh'
      echo "git fetch https://github.com/$UPSTREAM_REPO.git main:refs/remotes/upstream/main tag $UPSTREAM_TAG"
      echo "git rebase --onto $UPSTREAM_TAG \$(git merge-base ${FAILED_BRANCH:-<branch>} upstream/main) ${FAILED_BRANCH:-<branch>}"
      echo "git push --force-with-lease <u9g/t3code remote> ${FAILED_BRANCH:-<branch>}"
      echo '```'
      ;;
    missing-branch) echo "Push \`$FAILED_BRANCH\` to $PATCH_REPO, or remove it from \`PATCH_BRANCHES\` in the workflow." ;;
    *) echo "Read the run log. If the failure was transient, run the workflow again." ;;
  esac
  echo
  echo "A push to any patch branch changes the key, so the next hourly run retries on its own. To retry now:"
  echo "\`gh api repos/$RELEASE_REPO/dispatches -f event_type=patches-updated\`"
}
body=$(render)
title="Patched build blocked: $KIND on $UPSTREAM_TAG"

if [[ $DRY_RUN == true ]]; then
  printf '[dry-run] issue title: %s\n[dry-run] issue body:\n%s\n' "$title" "$body"
  issue_url=${issue_url:-https://github.com/$RELEASE_REPO/issues/0}
elif [[ -n $number ]]; then
  gh issue edit "$number" -R "$RELEASE_REPO" --title "$title" --body "$body" >/dev/null
  gh issue comment "$number" -R "$RELEASE_REPO" --body "Still blocked ($KIND, key \`$KEY\`): $RUN_URL" >/dev/null
  echo "updated $issue_url"
else
  issue_url=$(gh issue create -R "$RELEASE_REPO" --title "$title" --label "$ISSUE_LABEL" --body "$body")
  echo "opened $issue_url"
fi

payload=$(jq -cn \
  --arg upstream_tag "$UPSTREAM_TAG" \
  --arg upstream_sha "$UPSTREAM_SHA" \
  --argjson conflicts "$CONFLICTS" \
  --arg failed_branch "$FAILED_BRANCH" \
  --arg run_url "$RUN_URL" \
  --arg issue_url "$issue_url" \
  '{upstream_tag: $upstream_tag, upstream_sha: $upstream_sha, conflicts: $conflicts,
    failed_branch: (if $failed_branch == "" then null else $failed_branch end),
    run_url: $run_url, issue_url: $issue_url}')
if [[ $DRY_RUN == true ]]; then
  echo "[dry-run] webhook payload (sent only for conflict/build, once per key, when T3_PATCH_FIX_WEBHOOK is set): $payload"
elif [[ $notify == true ]]; then
  if curl -fsS --max-time 30 -X POST -H "Content-Type: application/json" --data "$payload" "$WEBHOOK" >/dev/null; then
    echo "notified the patch fixer for $KEY"
  else
    echo "::warning::the patch fix webhook failed; not retried for $KEY"
  fi
fi
