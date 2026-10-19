#!/usr/bin/env bash
# Decides whether this run builds, and which upstream nightly it builds.
#
# Writes its decisions as key=value lines to $GITHUB_OUTPUT and echoes them, so it
# also runs outside Actions for a dry run (only read-only gh/git calls).
#
# Env:
#   UPSTREAM_REPO   repo whose nightlies are patched (pingdotgg/t3code)
#   PATCH_REPO      repo holding the patch branches (u9g/t3code)
#   PATCH_BRANCHES  whitespace-separated branch names, applied in this order
#   RELEASE_REPO    repo the patched releases are published to (this repo)
#   ISSUE_LABEL     label of the blocked-build issue (default patch-conflict)
#   EVENT_NAME      github.event_name (default workflow_dispatch)
#   INPUT_TAG       upstream nightly tag to build instead of the newest one
#   FORCE           "true" builds a new revision even if the patch branches are
#                   unchanged since the newest release here
#
# Outputs: build, upstream_tag, upstream_version, tag, version, upstream_sha,
#          patch_shas, key, and on a missing branch failure + failed_branch.
#
# A release here is upstream's nightly version with the run number times 100 plus
# a revision: upstream v1.2.3-nightly.20261019.3348 ships here as .334800, and a
# patch branch push rebuilds it as .334801. The updater only offers a version that
# differs from the installed one; this one keeps the nightly shape the app accepts
# and sorts between upstream's nightlies.
set -euo pipefail

: "${UPSTREAM_REPO:?}" "${PATCH_REPO:?}" "${PATCH_BRANCHES:?}" "${RELEASE_REPO:?}"
ISSUE_LABEL=${ISSUE_LABEL:-patch-conflict}
EVENT_NAME=${EVENT_NAME:-workflow_dispatch}
INPUT_TAG=${INPUT_TAG:-}
FORCE=${FORCE:-false}

# Only nightlies are followed: the patched app is "T3 Code (Nightly)" and its
# updater only accepts nightly versions. Previews and stables share upstream's
# run-number sequence but never match this.
NIGHTLY_TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+-nightly\.[0-9]{8}\.[0-9]+$'

out() {
  echo "$1=$2"
  if [[ -n ${GITHUB_OUTPUT:-} ]]; then echo "$1=$2" >>"$GITHUB_OUTPUT"; fi
}
skip() {
  echo "::notice::No build: $*"
  out build false
  exit 0
}
# stderr, so the message still shows when fail runs inside $(...).
fail() {
  echo "::error::$*" >&2
  exit 1
}

# Releases made before revisions carry upstream's run number unchanged; they rank
# just below revision 0 of the same nightly.
release_rank() {
  local run=${1##*.}
  if ((run >= 100000)); then echo "$run"; else echo $((run * 100 - 1)); fi
}

# The last tag component is upstream's release.yml run number. Every nightly comes
# from that one workflow, so the number only grows, across version bumps too.
newest_nightly() {
  { grep -E "$NIGHTLY_TAG_RE" || true; } | awk -F. '{ print $NF "\t" $0 }' | sort -n | tail -n 1 | cut -f2
}

# Prints the commit a ref points at, peeling annotated tags; empty if the ref does
# not exist. git ls-remote avoids the REST rate limit and separates "no such ref"
# (empty output) from "cannot reach the repo" (non-zero exit).
remote_sha() {
  local lines
  lines=$(git ls-remote "https://github.com/$1.git" "$2" "$2^{}") || fail "cannot read $2 from $1"
  awk -v ref="$2" '$2 == ref "^{}" { peeled = $1 } $2 == ref { plain = $1 } END { print peeled ? peeled : plain }' <<<"$lines"
}

if [[ -n $INPUT_TAG ]]; then
  [[ $INPUT_TAG =~ $NIGHTLY_TAG_RE ]] || fail "upstream_tag '$INPUT_TAG' is not a nightly tag (vX.Y.Z-nightly.YYYYMMDD.N)"
  tag=$INPUT_TAG
else
  upstream_tags=$(gh release list -R "$UPSTREAM_REPO" --limit 100 --exclude-drafts --json tagName --jq '.[].tagName')
  tag=$(newest_nightly <<<"$upstream_tags")
  [[ -n $tag ]] || fail "no published nightly in $UPSTREAM_REPO"
fi
version=${tag#v}
run_number=${tag##*.}
out upstream_tag "$tag"
out upstream_version "$version"

# The cheap checks come first because most hourly runs stop here.
released=$(gh release list -R "$RELEASE_REPO" --limit 100 --exclude-drafts --json tagName --jq '.[].tagName')
newest_here=$(
  { grep -E "$NIGHTLY_TAG_RE" <<<"$released" || true; } |
    while read -r t; do printf '%s\t%s\n' "$(release_rank "$t")" "$t"; done |
    sort -n | tail -n 1 | cut -f2
)
revision=0
newest_upstream_run=
if [[ -n $newest_here ]]; then
  newest_run=${newest_here##*.}
  newest_upstream_run=$newest_run
  next_revision=0
  if ((newest_run >= 100000)); then
    newest_upstream_run=$((newest_run / 100))
    next_revision=$((newest_run % 100 + 1))
  fi
  if ((newest_upstream_run > run_number)); then
    # The nightly channel allows downgrades and follows the newest feed entry, so an
    # older build published now would be offered to every installed app.
    message="$tag is older than $newest_here, the newest release in $RELEASE_REPO"
    if [[ -n $INPUT_TAG ]]; then fail "$message; refusing to publish it"; fi
    skip "$message"
  fi
  if ((newest_upstream_run == run_number)); then revision=$next_revision; fi
fi

# Upstream creates the release before it uploads the files, and the Windows build
# embeds upstream's Linux archive as the WSL runtime, so wait until it is there.
wsl_archive="t3-$version-linux-x64.tar.gz"
assets=$(gh release view "$tag" -R "$UPSTREAM_REPO" --json isDraft,assets \
  --jq 'select(.isDraft | not) | .assets[] | select(.state == "uploaded") | .name') ||
  fail "$tag is not a release in $UPSTREAM_REPO"
for asset in "$wsl_archive" SHA256SUMS; do
  grep -qxF "$asset" <<<"$assets" || skip "$tag has no $asset yet (upstream may still be uploading); a later run retries"
done

upstream_sha=$(remote_sha "$UPSTREAM_REPO" "refs/tags/$tag")
[[ -n $upstream_sha ]] || fail "$UPSTREAM_REPO has a release for $tag but no tag"
out upstream_sha "$upstream_sha"

set -f
# shellcheck disable=SC2206 # split on whitespace on purpose; globbing is off
branches=($PATCH_BRANCHES)
set +f
shas=()
missing=()
for branch in "${branches[@]}"; do
  sha=$(remote_sha "$PATCH_REPO" "refs/heads/$branch")
  if [[ -z $sha ]]; then
    missing+=("$branch")
    sha=missing
  fi
  echo "patch branch $PATCH_REPO:$branch = $sha"
  shas+=("$sha")
done
patch_shas=$(
  IFS=,
  echo "${shas[*]}"
)
# A conflict or failure is a function of exactly these inputs, so this key decides
# when it is worth trying again (and when the fixer was already told).
key="$tag@$patch_shas"
out patch_shas "$patch_shas"
out key "$key"

if [[ $newest_upstream_run == "$run_number" && $FORCE != true ]]; then
  # The ledger names the patch commits each release was built from.
  built_shas=$(gh api -H "Accept: application/vnd.github.raw" "repos/$RELEASE_REPO/contents/builds/$newest_here.json" |
    jq -r '[.patches[].sha] | join(",")') || fail "cannot read builds/$newest_here.json from $RELEASE_REPO"
  if [[ $built_shas == "$patch_shas" ]]; then
    skip "$newest_here already has these patch branch commits (dispatch with force to build a new revision)"
  fi
fi
((revision <= 99)) || fail "$tag already has 100 patched revisions; wait for the next upstream nightly"
patched_tag="${tag%.*}.$((run_number * 100 + revision))"
out tag "$patched_tag"
out version "${patched_tag#v}"

if [[ $EVENT_NAME == schedule ]]; then
  reported=$(gh issue list -R "$RELEASE_REPO" --label "$ISSUE_LABEL" --state open --json body --jq '.[].body' | tr -d '\r')
  if grep -qxF "key: $key" <<<"$reported"; then
    skip "$key is already reported in an open $ISSUE_LABEL issue; waiting for a new upstream nightly or a patch branch push"
  fi
fi

if ((${#missing[@]})); then
  out failure missing-branch
  out failed_branch "${missing[0]}"
  fail "patch branch(es) not found on $PATCH_REPO: ${missing[*]}. Push them, or remove them from PATCH_BRANCHES in .github/workflows/patched-desktop-release.yml."
fi

out build true
