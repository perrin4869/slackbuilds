# slackbuilds

Maintainer pipeline for Julian Grinblat's (`julian@dotcore.co.il`) packages on
[SlackBuilds.org](https://slackbuilds.org/). Upstream `SlackBuildsOrg/slackbuilds@master`
is always the source of truth; this repo only detects updates, builds and
lints them, and - once a human merges the resulting PR here - opens the real
PR upstream.

```
upstream release ──▶ detect.yml opens a PR here (<category>/<pkg>/)
                          │
                          ▼
                    check.yml: sbolint + sbopkg -B -i + sbopkglint,
                    in ghcr.io/perrin4869/slackbuilds:15.0
                          │
                     you review + merge
                          │
                          ▼
                    submit.yml: re-derives from a FRESH upstream clone,
                    pushes perrin4869/sbo branch, opens the upstream PR
```

The re-derivation in `submit.yml` is deliberate: upstream may rewrite a
package (a mass script pass, someone else's PR) between review and merge, so
nothing here is ever treated as a base to build the submission from - only
as what got reviewed.

## Reviewing an update PR

Each tracked package lives in this repo at `<category>/<prgnam>/` - **the
exact same path it occupies in `SlackBuildsOrg/slackbuilds`**. That's
deliberate: it means an update PR's own **Files changed** tab already *is*
the real diff (full GitHub review UI - inline comments, viewed checkboxes,
the works), not a diff to reconstruct or restate elsewhere. What you see
there for `libraries/tree-sitter/tree-sitter.info` is exactly what lands at
that same path upstream if you merge.

An earlier version of this pipeline held files under a `staging/` prefix
and rendered a diff into the PR body instead - reviewable, but body text
has none of the Files-changed tab's tooling (no inline comments, no
per-line threading), so it was dropped in favor of the real thing.

The PR body (`scripts/preview.sh`) now just states the plain facts: the
exact commit message `submit.yml` will use, and that it re-derives against
a fresh upstream clone at merge time rather than trusting what was
reviewed here - flagging it explicitly on the resulting upstream PR if
upstream moved in the meantime.

## Layout

- `packages/<prgnam>.conf` - one file per tracked package: category, upstream
  source, tag-matching regex, generator kind (`tarball`, the default, or
  `rust`/`rust64`), and `FROZEN=1` for packages that can't be updated right
  now (see below).
- `scripts/detect.sh` - resolves the latest valid version per package.
- `scripts/generate.sh` - regenerates `.info` + `.SlackBuild` from a fresh
  upstream checkout at a target version.
- `scripts/preview.sh` - renders the PR body: the commit message
  `submit.yml` will use and a note about the merge-time re-derivation.
- `scripts/submit.sh` - re-derives and pushes the upstream PR.
- `scripts/rust-info.sh` / `rust64-info.sh` - unchanged crate-list generators
  for Rust packages (originally run by hand; see `scripts/generate.sh`'s
  `rust`/`rust64` case for the invocation).
- `<category>/<prgnam>/` - each tracked package's `.info`/`.SlackBuild` at
  its real upstream path (e.g. `libraries/tree-sitter/`), plus an
  `UPDATE.json` recording the pending version/upstream SHA. **Kept, not
  deleted, after submission** - it's the diff baseline for that package's
  *next* update PR, so the Files-changed tab shows exactly what changed
  (which crates got bumped, which `DOWNLOAD`/`MD5SUM` lines moved) instead
  of a wall of "new file added" green lines each time. `submit.yml` syncs it
  to the fresh copy it actually submitted (correcting for any drift), not
  the possibly-stale reviewed copy, so the baseline stays accurate even
  when upstream moved in between.

## Adding a package

Add `packages/<prgnam>.conf`. See any existing file for the shape; a plain
GitHub-tagged, non-Rust package only needs `CATEGORY`, `PRGNAM`, `SOURCE`,
`GITHUB_REPO`, `TAG_REGEX`, and `SRC_URL`/`ARCHIVE`/`PRGDIR` templates, plus
a starting `VERSION`. `TAG_REGEX` matters more than it looks: newest-by-date
tags are frequently unrelated branches or test tags, so it must be an
anchored pattern (`^v([0-9]+\.[0-9]+\.[0-9]+)$`) with the version in
capture group 1.

`GENERATOR` defaults to `tarball` (download the source archive, compute its
md5, done) and only needs to be set explicitly for `rust`/`rust64` (crate
list regenerated via `scripts/rust-info.sh`/`rust64-info.sh`).

`SOURCE` selects how the latest version is resolved: `github` (needs
`GITHUB_REPO`), `codeberg` (needs `CODEBERG_REPO`), `kernel-cgit` (needs
`CGIT_URL`, e.g. `libtraceevent`), or `sourcehut-hg` (needs `SRHT_REPO`,
e.g. `~scoopta/wofi` for `wofi`). All four take the same `TAG_REGEX`.

Freezing a package (e.g. blocked on a Slackware/glibc version) adds:

```sh
FROZEN=1
FROZEN_REASON="why, and what unblocks it"
```

`detect.sh` skips frozen packages but still reports how far behind they are
in the run summary, so they don't rot silently.

## Detection

`detect.yml` runs on a `repository_dispatch: upstream-release` event, fired
by a [newreleases.io](https://newreleases.io/) webhook watching each
tracked project, or manually via `workflow_dispatch`. The webhook is a
trigger only - it carries no version info, so every firing just re-runs
`detect.sh` over every package.

No cron backstop: every `packages/*.conf` right now is `SOURCE=github`,
which newreleases.io's webhook fully covers. If a non-GitHub source
(wofi/sr.ht, libtraceevent/kernel.org) ever gets tracked, that's the point
to add a cron back - newreleases.io doesn't watch those at all, so nothing
else would ever trigger detection for them.

`scripts/newreleases-sync.sh` reconciles the tracked-project list on
newreleases.io from `packages/*.conf`, so a new package only needs a
`.conf` file here.

## Secrets required

| Secret | Used by | Purpose |
|---|---|---|
| `SBO_SUBMIT_TOKEN` | `submit.yml` | Classic PAT, `repo` scope. Pushes to `perrin4869/sbo` and opens PRs against `SlackBuildsOrg/slackbuilds` - the default `GITHUB_TOKEN` can do neither. |
| `NEWRELEASES_API_KEY` | `detect.yml` (sync job) | newreleases.io account API key. |
| `NEWRELEASES_WEBHOOK_ID` | `detect.yml` (sync job) | Id of a webhook already configured by hand on newreleases.io (Settings > Webhooks), pointed at `https://api.github.com/repos/perrin4869/slackbuilds/dispatches` with an `Authorization: Bearer <PAT>` header, `Accept: application/vnd.github+json`, and `event_type: upstream-release`. |

## A load-bearing detail: the `local` repo slot

`check.yml` mounts the working tree at `/var/lib/sbopkg/local/local` (with
`REPO_NAME=local REPO_BRANCH=local`), **not** `/var/lib/sbopkg/SBo/15.0`. The
`SBo/15.0` slot (`/etc/sbopkg/repos.d/40-sbo.repo`) has `CheckGPG=GPG`, which
verifies the downloaded source tarball's signature against SBo's separate
signed source-archive mirror - a signature a plain `git clone` of upstream
has no way to satisfy. Under `-e stop` that "failure" is treated as a real
build error: sbopkg deletes the source directory and aborts, so *every*
build would fail this way. The `local` slot (`50-local.repo`) has no GPG
checking at all and is meant for exactly this - a manually-populated tree.

## Image

`ghcr.io/perrin4869/slackbuilds:15.0`, built by `image.yml` on every
`Dockerfile` change and monthly (to pick up Slackware package updates).
`SBOPKG_VERSION` is a build `ARG`; `scripts/detect-image-deps.sh` (run from
`detect.yml`) opens a PR bumping it when a new sbopkg release ships, and
merging that PR triggers a rebuild via the `Dockerfile`-change trigger.
