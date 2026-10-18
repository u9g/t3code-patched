# t3code-patched

Unofficial, patched builds of the [T3 Code](https://github.com/pingdotgg/t3code) desktop app
for Windows x64. Each release is an upstream nightly with these branches from
[u9g/t3code](https://github.com/u9g/t3code) applied, in this order:

1. [`feat/claude-code-cloud`](https://github.com/u9g/t3code/tree/feat/claude-code-cloud): Claude Code cloud sessions as a provider.
2. [`feat/desktop-update-repository`](https://github.com/u9g/t3code/tree/feat/desktop-update-repository): a runtime override for the update feed.

This repository is not affiliated with T3 Tools. The installers are **unsigned** and built
by GitHub Actions from public sources; see [`builds/`](builds) for what went into each one.

## Releases

Every release is a prerelease tagged `v<upstream version>`, for example
`v0.1.1-nightly.20261018.3315`. The version is exactly upstream's, so the app is
"T3 Code (Nightly)" on the nightly update channel, and the CLI archives that SSH
environments and `t3 update` fetch from upstream exist for it. Each release carries:

- `T3-Code-<version>-x64.exe`, the NSIS installer
- `T3-Code-<version>-x64.exe.blockmap`, for differential updates
- `nightly.yml`, the electron-updater manifest

A release here only ever moves forward: the workflow refuses to publish a nightly older
than the newest one already here, because the nightly channel allows downgrades.

## How the desktop app finds these releases

- **Baked feed.** Builds set `T3CODE_DESKTOP_UPDATE_REPOSITORY=u9g/t3code-patched`, so the
  installer's `resources/app-update.yml` reads `owner: u9g`, `repo: t3code-patched`,
  `releaseType: prerelease`, `channel: nightly`. The workflow reads that file back out of
  each installer before publishing. An installed patched app checks this repository's
  `releases.atom`, takes the newest nightly entry, and downloads its `nightly.yml`.
- **Runtime override.** The `feat/desktop-update-repository` patch makes the desktop main
  process read `T3CODE_DESKTOP_UPDATE_REPOSITORY=owner/repo` at startup and use that GitHub
  repository as the feed instead. The baked release type and T3's channel logic stay as
  they are, mock updates (`T3CODE_DESKTOP_MOCK_UPDATES`) still take precedence, and invalid
  values are ignored with a logged warning.
- **Signatures.** The installers are unsigned, so the baked `app-update.yml` has no
  `publisherName` and updates between these builds skip the publisher check. The sha512
  in `nightly.yml` is still verified.
- **First install is manual.** The official app updates from `pingdotgg/t3code` and never
  looks here. Download the `.exe` from a release and run it; Windows SmartScreen shows
  "Windows protected your PC", so choose **More info** then **Run anyway**. It installs over
  the official app (same app id and folder) and keeps your data in `~/.t3`. Quit the app and
  back up `~/.t3/userdata` first if you might go back to an older official release.

What stays unpatched: WSL environments run upstream's Linux server of the same version, and
SSH environments download upstream's CLI for that version.

## How a build happens

[`.github/workflows/patched-desktop-release.yml`](.github/workflows/patched-desktop-release.yml)
runs every hour, on manual dispatch, and on a `patches-updated` repository dispatch.

1. **prepare** ([`scripts/pick-build.sh`](scripts/pick-build.sh)) picks the newest published
   upstream nightly by its run number (the last number in the tag). It stops without building
   if that version is already released here, if it is older than the newest release here, if
   upstream has not finished uploading its files, or (on the hourly schedule) if the same
   upstream tag and patch branch commits already failed and are reported in an open issue.
   [`scripts/apply-patches.sh`](scripts/apply-patches.sh) then makes a blob-less clone, checks
   out the upstream tag (without the vendored `/.repos/` tree), and cherry-picks each branch's
   commits that are not on upstream main, in order. The result travels as a git bundle.
2. **windows** builds on `windows-2025` the way upstream's release does: `vp install`,
   `cp .env.example .env` (the public T3 Connect identifiers), version alignment,
   `vp run build:desktop`, the resource monitor (cached; Rust and Spectre libraries only on a
   cache miss), upstream's same-version Linux archive as the WSL runtime (checked against
   upstream's `SHA256SUMS`), then `dist:desktop:artifact --platform win --target nsis --arch x64`.
   This job has a read-only token.
3. **publish** commits `builds/<tag>.json` to `main` (a fresh commit per build keeps the
   release feed in build order), creates the release as a draft, uploads the three files,
   then publishes it as a prerelease that is not marked latest. It closes any open
   `patch-conflict` issue about that nightly or an older one.
4. **report** runs when anything above fails (see below).

## Adding or removing a patch branch

Edit `PATCH_BRANCHES` near the top of the workflow. It is a space-separated list of branch
names on `u9g/t3code`, applied in order. A branch contributes its commits that are not on
upstream main (merge commits are skipped, and commits an earlier branch already contributed
are not applied twice), so keep each branch based on upstream main or on a nightly tag.
A listed branch that does not exist fails the run with an issue that names it.

The change takes effect with the next upstream nightly. To apply it to the version that is
already out, rebuild it (below).

## Conflicts and failures

When a branch does not apply, or the build fails, the run opens (or updates) one issue labelled
`patch-conflict`. The label is created on first use. The issue starts with a line the workflow
reads back:

```
key: <upstream tag>@<sha of each patch branch, comma-separated>
```

and lists the failed branch, the commit and the conflicting files, with the commands to
rebase the branch onto the nightly. While that key is unchanged the hourly run does not
retry, so pushing a fixed branch or a new upstream nightly is what triggers the next attempt.
To retry right away:

```sh
gh api repos/u9g/t3code-patched/dispatches -f event_type=patches-updated
```

If the repository secret `T3_PATCH_FIX_WEBHOOK` is set, the first conflict or build failure
for each key is also POSTed there as JSON (failures to deliver are ignored):

```json
{"upstream_tag": "v0.1.1-nightly.20261018.3331", "upstream_sha": "eb7b35ac…",
 "conflicts": ["apps/server/src/orchestration-v2/Orchestrator.ts"],
 "failed_branch": "feat/claude-code-cloud",
 "run_url": "https://github.com/u9g/t3code-patched/actions/runs/…",
 "issue_url": "https://github.com/u9g/t3code-patched/issues/…"}
```

`failed_branch` is `null` and `conflicts` is empty for a build failure. A missing branch or a
publish failure opens the issue without calling the webhook. The issue is closed by the next
successful publish of that nightly or a newer one.

## Building or rebuilding a specific version

```sh
# Build a particular upstream nightly (it must not be older than the newest release here)
gh workflow run patched-desktop-release.yml -R u9g/t3code-patched -f upstream_tag=v0.1.1-nightly.20261018.3315

# Rebuild the newest version in place, for example after fixing a broken build
gh workflow run patched-desktop-release.yml -R u9g/t3code-patched -f upstream_tag=<tag> -f force=true
```

A forced rebuild replaces the release's files in place rather than deleting the release, so
the feed never briefly falls back to an older nightly. Apps that already installed that
version will not download it again, because the version number is the same; they pick up
the next nightly as usual.
