# slackbuilds

Maintainer pipeline for Julian Grinblat's (`julian@dotcore.co.il`) packages on
[SlackBuilds.org](https://slackbuilds.org/). Upstream `SlackBuildsOrg/slackbuilds@master`
is always the source of truth; this repo detects updates, builds and lints
them, and once a human merges the resulting PR here, opens the real PR
upstream via `perrin4869/sbo`.

```
upstream release ──▶ webhook.yml opens a PR here (sbo/<category>/<pkg>/)
                          │
                          ▼
                    check.yml: sbolint + sbopkg -B -i + sbopkglint,
                    in ghcr.io/perrin4869/slackbuilds:15.0
                          │
                     you review + merge
                          │
                          ▼
                    submit.yml: opens the PR upstream via perrin4869/sbo
```

`submit.yml` re-derives the package fresh at merge time rather than reusing
what was reviewed here, since upstream may have moved in the meantime.

## Reviewing an update PR

Each tracked package lives in this repo at `sbo/<category>/<prgnam>/` -
everything under `sbo/` mirrors the path it occupies in
`SlackBuildsOrg/slackbuilds` (just nested one level deeper, under `sbo/`,
to keep the repo root itself uncluttered). So an update PR's **Files
changed** tab already is the real diff - what you see for
`sbo/libraries/tree-sitter/tree-sitter.info` is what lands upstream if you
merge, unless upstream moved since the PR was opened: `submit.yml`
re-derives the package fresh at merge time, and flags it on the resulting
upstream PR if that changes anything.

## Layout

- `packages/<prgnam>.conf` - one file per tracked package: category, upstream
  source, tag-matching regex, `STRATEGY` (`tarball`, the default, or
  `rust`/`rust64`), and `FROZEN=1` for packages that can't be updated right
  now (see below).
- `scripts/lib.sh` - shared helpers: version resolvers per `SOURCE` type,
  `.info` parsing, `generate_package()` (regenerates `.info`+`.SlackBuild`
  from a fresh upstream checkout), `render_pr_body()`.
- `scripts/rust-info.sh` / `rust64-info.sh` - the crate-list generators for
  Rust packages, unchanged from when they were run by hand.
- `.github/workflows/open-update-prs.yml` - reusable workflow
  (`workflow_call`), called once per package that needs an update by both
  `webhook.yml` and `poll.yml` via `strategy: matrix`. Regenerates the
  package, then hands it to
  [`peter-evans/create-pull-request`](https://github.com/peter-evans/create-pull-request)
  to open (or update) the PR.
- `sbo/<category>/<prgnam>/` - each tracked package's `.info`/`.SlackBuild`,
  kept around after submission as the diff baseline for that package's
  *next* update PR (so the Files-changed tab shows a real diff, not a wall
  of green "new file" lines each time).

`check.yml`/`submit.yml` discover which packages changed by diffing on
`sbo/**/*.info`.

## Adding a package

Add `packages/<prgnam>.conf`. See any existing file for the shape; a plain
GitHub-tagged, non-Rust package only needs `CATEGORY`, `PRGNAM`, `SOURCE`,
`TAG_REGEX`, and `SRC_URL`/`ARCHIVE`/`PRGDIR` templates, plus a starting
`VERSION`.

`SOURCE` is just the repo's URL (e.g.
`https://github.com/tree-sitter/tree-sitter`). If `POLL` isn't set, the
check mechanism is inferred from its host - `github.com` or `codeberg.org`,
the only two with a webhook-able API - and `TAG_REGEX` (anchored, capture
group 1 = version) picks the real version tag out of everything else a repo
tags (test tags, unrelated branches, LTS backports).

`POLL=1` marks a package with no webhook option at all - checked by
`poll.yml` on a cron instead, via `NVCHECKER_URL`/`NVCHECKER_REGEX`
([nvchecker](https://github.com/lilydjwg/nvchecker)'s own `regex` source
fields). `wofi`/`libtraceevent` are the current examples - hg.sr.ht and cgit
have no API for anything to watch.

`STRATEGY` defaults to `tarball` and only needs to be set explicitly for
`rust`/`rust64` (crate list regenerated via `rust-info.sh`/`rust64-info.sh`).

`IMAGE_VARIANT` is only needed if the package depends on a toolchain
expensive enough to warrant a prebuilt image variant - see "Image" below.
`jujutsu`/`difftastic` set `rust-opt`, `yq` sets `google-go-lang`.

Freezing a package (e.g. blocked on a Slackware/glibc version) adds:

```sh
FROZEN=1
FROZEN_REASON="why, and what unblocks it"
```

Frozen packages are skipped but still reported (how far behind) in the run
summary.

## Detection

`webhook.yml` reacts to a `repository_dispatch: upstream-release` event
fired by a [newreleases.io](https://newreleases.io/) webhook, or a manual
`workflow_dispatch`. The payload names the project and its version, so
`webhook.yml` trusts that version directly rather than scanning upstream
itself - newreleases.io already did that. It has no cron and no scanning
fallback of its own.

**Webhook payload template** (newreleases.io → your webhook → payload
fields) - `repository_dispatch` needs the POST body shaped exactly like
this:

```json
{
  "event_type": "upstream-release",
  "client_payload": {
    "project": "{project}",
    "version": "{version}"
  }
}
```

`poll.yml` (weekly cron + `workflow_dispatch`) is the only workflow that
resolves a version by scanning. Its cron checks every `POLL=1` package; its
`workflow_dispatch` also takes an optional `package` input naming any
package, for an ad hoc check outside the cron.

`sync-newreleases.yml` reconciles the tracked-project list on
newreleases.io with `packages/*.conf`, triggered on any push to master that
touches `packages/*.conf`.

## Secrets required

| Secret | Used by | Purpose |
|---|---|---|
| `SBO_SUBMIT_TOKEN` | `submit.yml` | Classic PAT, `repo` scope. Pushes to `perrin4869/sbo` and opens PRs against `SlackBuildsOrg/slackbuilds` - the default `GITHUB_TOKEN` can do neither, and a fine-grained PAT can't be scoped to a repo you don't own. |
| `SBO_UPDATE_PR_TOKEN` | `open-update-prs.yml` | Fine-grained PAT, scoped to just this repo, Contents + Pull requests (Read and write). Opens update PRs here - not `SBO_SUBMIT_TOKEN`, a different token for a different repo, and not the default `GITHUB_TOKEN`, since GitHub requires manual workflow-run approval for PRs opened by `github-actions[bot]`. |
| `NEWRELEASES_API_KEY` | `sync-newreleases.yml` | newreleases.io account API key. |
| `NEWRELEASES_WEBHOOK_ID` | `sync-newreleases.yml` | Id of a webhook already configured by hand on newreleases.io (Settings > Webhooks), pointed at `https://api.github.com/repos/perrin4869/slackbuilds/dispatches` with an `Authorization: Bearer <PAT>` header, `Accept: application/vnd.github+json`, and the payload template above. |

## Why `check.yml` uses the `local` repo slot

`check.yml` mounts the working tree at `/var/lib/sbopkg/local/local`, **not**
`/var/lib/sbopkg/SBo/15.0`. The `SBo/15.0` slot has `CheckGPG=GPG`, which
verifies the downloaded source tarball against SBo's signed source-archive
mirror - a signature a plain `git clone` of upstream can't satisfy, and
under `-e stop` that failure would kill every single build. The `local`
slot has no GPG checking and is meant for exactly this.

## Image

`ghcr.io/perrin4869/slackbuilds:15.0`, built by `image.yml` on every
`Dockerfile`/`Dockerfile.*` change and monthly (to pick up Slackware
package updates).

`image.yml` also builds two derived images - `slackbuilds-google-go-lang`
and `slackbuilds-rust-opt`, each `FROM` the base image with one expensive,
`REQUIRES=""` toolchain package pre-installed. A package sets
`IMAGE_VARIANT=google-go-lang`/`rust-opt` in its own `packages/*.conf` to
have `check.yml` build against that variant instead of the base image,
with `-k` (skip already-installed) so the toolchain itself isn't
rebuilt. Beyond saving that rebuild time, this matters specifically for
`google-go-lang`: its `/etc/profile.d/go.sh` (setting `GOROOT`/`PATH`)
only gets read at shell startup, so a package built from it within the
same already-running shell right after installing it would never see
that setup at all.

`image-deps.yml` (weekly cron + `workflow_dispatch`) tracks the image's two
build-time dependencies:

- **`sbopkg`** is pinned via the Dockerfile's `SBOPKG_VERSION` ARG. A new
  release opens a PR bumping it; merging triggers a rebuild.
- **`sbo-maintainer-tools`** has no pin - the Dockerfile installs whatever
  `sbopkg -B -i sbo-maintainer-tools` finds at build time. The job compares
  against what's actually installed in the published image and dispatches
  a rebuild if it's behind.
