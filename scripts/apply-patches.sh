#!/usr/bin/env bash
# Builds the patched source: the upstream nightly commit plus, for each patch branch
# in order, the branch's own commits (those not on upstream main), cherry-picked.
# Writes a git bundle of the result for the Windows job.
#
# Env:
#   UPSTREAM_REPO, UPSTREAM_TAG, UPSTREAM_SHA   the nightly picked by pick-build.sh
#   PATCH_REPO, PATCH_BRANCHES                  as in pick-build.sh
#   PATCH_SHAS                                  comma-separated branch tips from pick-build.sh
#   WORK_DIR                                    path for the clone (must not exist yet)
#   BUNDLE                                      path the bundle is written to
#
# Outputs: patched_sha, picked; on a conflict failure=conflict, failed_branch,
#          failed_commit and conflicts (JSON array of paths).
set -euo pipefail

: "${UPSTREAM_REPO:?}" "${UPSTREAM_TAG:?}" "${UPSTREAM_SHA:?}" "${PATCH_REPO:?}" "${PATCH_BRANCHES:?}" "${PATCH_SHAS:?}"
: "${WORK_DIR:?}" "${BUNDLE:?}"

out() {
  echo "$1=$2"
  if [[ -n ${GITHUB_OUTPUT:-} ]]; then echo "$1=$2" >>"$GITHUB_OUTPUT"; fi
}
fail() {
  echo "::error::$*" >&2
  exit 1
}

set -f
# shellcheck disable=SC2206 # split on whitespace on purpose; globbing is off
branches=($PATCH_BRANCHES)
set +f
IFS=, read -r -a shas <<<"$PATCH_SHAS"
((${#branches[@]} == ${#shas[@]})) || fail "PATCH_BRANCHES has ${#branches[@]} entries but PATCH_SHAS has ${#shas[@]}"

log=$(mktemp)
BUNDLE=$(realpath -m "$BUNDLE")
git init -q "$WORK_DIR"
cd "$WORK_DIR"
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
for remote in "upstream $UPSTREAM_REPO" "patches $PATCH_REPO"; do
  # shellcheck disable=SC2086 # "name repo" pair
  set -- $remote
  git remote add "$1" "https://github.com/$2.git"
  # Blob-less: the full commit graph for the "not on upstream main" range, and
  # blobs only for what the checkout and the cherry-picks read.
  git config "remote.$1.promisor" true
  git config "remote.$1.partialclonefilter" blob:none
done

git fetch -q --no-tags --filter=blob:none upstream \
  "+refs/heads/main:refs/remotes/upstream/main" "+refs/tags/$UPSTREAM_TAG:refs/tags/$UPSTREAM_TAG"
[[ $(git rev-parse "refs/tags/$UPSTREAM_TAG^{commit}") == "$UPSTREAM_SHA" ]] ||
  fail "$UPSTREAM_TAG no longer points at $UPSTREAM_SHA"
# By commit, not by branch name: the build must match the key that was checked,
# even if a branch is pushed while this runs.
git fetch -q --no-tags --filter=blob:none patches "${shas[@]}"

# .repos/ holds vendored trees with gitlinks that have no .gitmodules entry;
# upstream's release checkout leaves it out the same way.
git sparse-checkout set --no-cone '/*' '!/.repos/'
git -c checkout.workers=0 checkout -q -B patched "$UPSTREAM_SHA"

picked=0
excludes=(^refs/remotes/upstream/main)
for i in "${!branches[@]}"; do
  branch=${branches[$i]}
  tip=${shas[$i]}
  # A branch's patch is its commits that are not on upstream main. Commits an
  # earlier branch already contributed are left out too, so a branch stacked on
  # another one is not applied twice. Merges are skipped, as git rebase does.
  mapfile -t commits < <(git rev-list --reverse --no-merges "$tip" "${excludes[@]}")
  merges=$(git rev-list --count --merges "$tip" "${excludes[@]}")
  echo "== $branch ($tip): ${#commits[@]} commit(s)"
  if ((merges > 0)); then
    echo "::warning::$branch has $merges merge commit(s) that are skipped; rebase the branch to keep their changes"
  fi
  if ((${#commits[@]} == 0)); then
    echo "::warning::$branch has no commits beyond upstream main and the branches before it"
  fi
  for commit in "${commits[@]}"; do
    subject=$(git log -1 --format='%h %s' "$commit")
    if git cherry-pick -x "$commit" >"$log" 2>&1; then
      echo "   applied $subject"
      picked=$((picked + 1))
      continue
    fi
    conflicts=$(git diff --name-only --diff-filter=U)
    if [[ -z $conflicts ]] && git diff --cached --quiet; then
      # Upstream already has this change; drop it, as git rebase would.
      echo "::notice::$subject is already in $UPSTREAM_TAG; skipped"
      git cherry-pick --skip
      continue
    fi
    cat "$log"
    if [[ -z $conflicts ]]; then
      fail "cherry-pick of $subject from $branch failed without a conflict"
    fi
    out failure conflict
    out failed_branch "$branch"
    out failed_commit "$(git log -1 --format='%H %s' "$commit")"
    out conflicts "$(jq -cnR '[inputs]' <<<"$conflicts")"
    git cherry-pick --abort
    fail "$branch does not apply to $UPSTREAM_TAG: $subject conflicts in $(paste -sd ' ' <<<"$conflicts")"
  done
  excludes+=("^$tip")
done

if ((picked == 0)); then
  out failure empty
  fail "no patch commits applied: every branch in PATCH_BRANCHES is empty or already in $UPSTREAM_TAG"
fi
out picked "$picked"
out patched_sha "$(git rev-parse HEAD)"
git bundle create -q "$BUNDLE" refs/heads/patched "^$UPSTREAM_SHA"
echo "bundle: $BUNDLE ($(wc -c <"$BUNDLE") bytes)"
