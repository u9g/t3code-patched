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
#   FORCE           "true" rebuilds a version that is already released here
#
# Outputs: build, upstream_tag, version, upstream_sha, patch_shas, key,
#          release_exists, and on a missing branch failure + failed_branch.
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
out version "$version"

# The cheap checks come first because most hourly runs stop here.
released=$(gh release list -R "$RELEASE_REPO" --limit 100 --exclude-drafts --json tagName --jq '.[].tagName')
newest_here=$(newest_nightly <<<"$released")
release_exists=false
if grep -qxF "$tag" <<<"$released"; then release_exists=true; fi
out release_exists "$release_exists"
if [[ -n $newest_here && ${newest_here##*.} -gt $run_number ]]; then
  # The nightly channel allows downgrades and follows the newest feed entry, so an
  # older build published now would be offered to every installed app.
  message="$tag is older than $newest_here, the newest release in $RELEASE_REPO"
  if [[ -n $INPUT_TAG ]]; then fail "$message; refusing to publish it"; fi
  skip "$message"
fi
if [[ $release_exists == true && $FORCE != true ]]; then
  skip "$tag is already released in $RELEASE_REPO (dispatch with force to rebuild it)"
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
