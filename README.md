# slackbuilds

Maintainer pipeline for Julian Grinblat's (`julian@dotcore.co.il`) packages on
[SlackBuilds.org](https://slackbuilds.org/). Upstream `SlackBuildsOrg/slackbuilds@master`
is always the source of truth; this repo only detects updates, builds and
lints them, and - once a human merges the resulting PR here - opens the real
PR upstream.

```
upstream release ──▶ webhook.yml opens a PR here (<category>/<pkg>/)
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

The PR body (`render_pr_body`, in `scripts/lib.sh`) now just states the
plain facts: the exact commit message `submit.yml` will use, and that it
re-derives against a fresh upstream clone at merge time rather than
trusting what was reviewed here - flagging it explicitly on the resulting
upstream PR if upstream moved in the meantime.

## Layout

Scripts are used sparingly, and only where they genuinely have to be: a
few functions need to be callable from *inside a loop* (once per detected
update), which a reusable GitHub Action can't be - actions are static
workflow steps, not something you invoke dynamically from within a bash
loop. Anything else lives directly in the workflow that calls it, or as a
composite action if more than one workflow needs it.

- `packages/<prgnam>.conf` - one file per tracked package: category, upstream
  source, tag-matching regex, generator kind (`tarball`, the default, or
  `rust`/`rust64`), and `FROZEN=1` for packages that can't be updated right
  now (see below).
- `scripts/lib.sh` - shared helpers, sourced by every workflow/action that
  needs them: version resolvers per `SOURCE` type, `.info` parsing,
  `generate_package()` (regenerates `.info`+`.SlackBuild` from a fresh
  upstream checkout) and `render_pr_body()` - both called once per
  detected update from inside `open-update-prs`'s loop and (the former)
  again from `submit.yml`, so they have to be plain functions, not actions.
- `scripts/rust-info.sh` / `rust64-info.sh` - unchanged crate-list generators
  for Rust packages (originally run by hand; see `generate_package()`'s
  `rust`/`rust64` case for the invocation). Kept as real scripts, not
  functions - substantial standalone tools in their own right, not glue.
- `.github/actions/detect` - resolves the latest valid version for one,
  several, or all tracked packages and decides which need an update PR.
  A composite action (not a script) because both `webhook.yml` and
  `poll.yml` call it.
- `.github/actions/open-update-prs` - given `detect`'s output, opens an
  update PR for every `NEEDS_UPDATE` line. Also a composite action for the
  same reason - shared by `webhook.yml` and `poll.yml`.

`detect`'s output (and `open-update-prs`'s `detect-output` input) carries
data that ultimately derives from upstream tag names, not just this
repo's own config - so callers pass it via `env:` rather than
interpolating `${{ }}` directly into a `run:` script body. The latter is
a real GitHub Actions footgun: `${{ }}` in a `run:` block is substituted
as raw text *before* the shell parses it, so untrusted content there can
break out of the intended command. An `env:` value becomes a plain
environment variable instead - substituted once, read safely as `"$VAR"`.

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
`TAG_REGEX`, and `SRC_URL`/`ARCHIVE`/`PRGDIR` templates, plus a starting
`VERSION`.

`SOURCE` is just the repo's endpoint URL (e.g.
`https://github.com/tree-sitter/tree-sitter`) - it says where the code
lives, nothing about how to check it for updates. Earlier versions of
this file used `SOURCE` as an enum naming the check *mechanism*
(`github`, `codeberg`, `nvchecker`...) - a real inconsistency, since
`github`/`codeberg` name a *platform* and `nvchecker` names a *tool*, not
a platform. Now:

- If `POLL` isn't set, the mechanism is inferred from `SOURCE`'s host:
  `github.com` or `codeberg.org` (the only two with a webhook-able API,
  checked by `webhook.yml`), each taking `TAG_REGEX` (anchored, capture
  group 1 = version). `TAG_REGEX` matters more than it looks:
  newest-by-date tags are frequently unrelated branches or test tags.
- `POLL=1` marks a package with no webhook option at all - `SOURCE` is
  still the repo's endpoint (for humans reading the file), but resolution
  goes through `NVCHECKER_URL` + `NVCHECKER_REGEX` instead
  ([nvchecker](https://github.com/lilydjwg/nvchecker)'s `regex` source
  fields exactly - fetch the URL, take the max of every match of the
  regex). Checked by `poll.yml` on a cron instead of a webhook.
  `wofi`/`libtraceevent` are the current examples - hg.sr.ht and cgit
  instances have no API for anything to watch.

`resolve_kernel_cgit_version()` (`scripts/lib.sh`) also exists as a
bespoke scraper alternative to `nvchecker`'s regex source for cgit
specifically - not used by any `packages/*.conf` (nvchecker covers that
case fine), but kept since `image-deps.yml` calls it directly for a
non-SBo-package dependency (see "Image" below).

`GENERATOR` defaults to `tarball` (download the source archive, compute its
md5, done) and only needs to be set explicitly for `rust`/`rust64` (crate
list regenerated via `scripts/rust-info.sh`/`rust64-info.sh`).

Freezing a package (e.g. blocked on a Slackware/glibc version) adds:

```sh
FROZEN=1
FROZEN_REASON="why, and what unblocks it"
```

The `detect` action skips frozen packages but still reports how far behind
they are in the run summary, so they don't rot silently.

## Detection

`webhook.yml` runs on a `repository_dispatch: upstream-release` event, fired
by a [newreleases.io](https://newreleases.io/) webhook watching each
tracked project, or manually via `workflow_dispatch`.

The webhook payload names which project changed
(`client_payload.project`), so a firing is scoped to just that one
package (mapped back to a `prgnam` by matching `SOURCE`'s `owner/repo`
in `packages/*.conf`) instead of re-checking everything. It still goes
through the `detect` action's normal resolution and `TAG_REGEX` filtering rather
than trusting the webhook's own version field - that filter exists
precisely because raw upstream signals (test tags, LTS backports, etc.)
aren't trustworthy on their own; the webhook only saves re-checking
*every other* package. If the payload is missing or names a project no
`.conf` matches (manual dispatch with no `package` input, or a
misconfigured webhook), it falls back to checking every *webhook-able*
(github.com/codeberg.org `SOURCE`) package - excluding `POLL=1` ones,
which have no webhook option at all and are `poll.yml`'s job instead
(below).

**Webhook payload template** (newreleases.io → your webhook → payload
fields), since the default payload doesn't reach GitHub in a form it
accepts - `repository_dispatch` requires the POST body shaped exactly as
below:

```json
{
  "event_type": "upstream-release",
  "client_payload": {
    "project": "{project}"
  }
}
```

`{project}` is newreleases.io's own template variable, filled in with the
`provider/name` of whichever tracked project fired (e.g. `jj-vcs/jj`) -
matching the `owner/repo` path of that package's `SOURCE` URL exactly.

No cron here: every package `webhook.yml` handles is webhook-covered. The
one place a cron actually belongs is `poll.yml`, split out for
exactly the packages a webhook *can't* reach:

- **`poll.yml`** (weekly cron + `workflow_dispatch`) checks every
  `POLL=1` package - `wofi` (hg.sr.ht) and `libtraceevent`
  (git.kernel.org/cgit) currently. Neither hosts an API of any kind for a
  service like newreleases.io to watch, so polling is the only option.
  It installs [nvchecker](https://github.com/lilydjwg/nvchecker) itself,
  finds the poll-based packages by grepping `packages/*.conf` for
  `POLL=1`, then reuses the exact same `detect` +
  `open-update-prs` actions as `webhook.yml` - push vs. pull only changes
  *how a package's turn to be checked comes up*, not what happens once it
  is.

This push/pull split mirrors `image.yml`/`image-deps.yml`'s (below) -
detection workflows are separated by trigger mechanism, not bundled by
"they're all detection" convenience.

`sync-newreleases.yml` reconciles the tracked-project list on
newreleases.io with `packages/*.conf`, so adding a package here doesn't
also mean remembering to add it on their site. It's a *third*, separate
workflow, not a step in `webhook.yml`: newreleases.io doesn't track "what
this repo currently ships" at all - it independently watches each
project's upstream repo for new releases, regardless of what we've merged
- so there's nothing to tell it after a version-bump PR merges. The only
thing that can actually invalidate the sync is the *tracked package list*
changing, i.e. a push to master touching `packages/*.conf` - which is what
it's triggered on (plus manual `workflow_dispatch`).

## Secrets required

| Secret | Used by | Purpose |
|---|---|---|
| `SBO_SUBMIT_TOKEN` | `submit.yml` | Classic PAT, `repo` scope. Pushes to `perrin4869/sbo` and opens PRs against `SlackBuildsOrg/slackbuilds` - the default `GITHUB_TOKEN` can do neither. |
| `NEWRELEASES_API_KEY` | `sync-newreleases.yml` | newreleases.io account API key. |
| `NEWRELEASES_WEBHOOK_ID` | `sync-newreleases.yml` | Id of a webhook already configured by hand on newreleases.io (Settings > Webhooks), pointed at `https://api.github.com/repos/perrin4869/slackbuilds/dispatches` with an `Authorization: Bearer <PAT>` header, `Accept: application/vnd.github+json`, and the payload template in "Detection" above. |

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

`image-deps.yml` (weekly cron + `workflow_dispatch` - no webhook option
exists for either dependency) has two independent jobs, one per
build-time dependency, tracked differently because one is pinned and one
isn't:

- **`sbopkg`** is pinned via the Dockerfile's `SBOPKG_VERSION` ARG,
  fetched from a specific GitHub release - `newreleases.io` *could* watch
  it (it's on GitHub) but doesn't, to keep both dependencies on one
  schedule rather than splitting further. A new release opens a PR
  bumping the ARG; merging triggers a rebuild via `image.yml`'s
  `Dockerfile`-change trigger.
- **`sbo-maintainer-tools`** has no pin - the Dockerfile just installs
  whatever `sbopkg -B -i sbo-maintainer-tools` finds in the
  currently-synced SBo mirror at build time, so there's no Dockerfile line
  to bump and no diff to review. It's hosted on the maintainer's own cgit
  instance, which - like `git.kernel.org` - has no API at all, only HTML
  to scrape (`scripts/lib.sh`'s `resolve_kernel_cgit_version`, shared with
  the same function `image-deps.yml` uses here). A new release just needs
  a rebuild: the job compares against what's *actually installed in the
  published image* (`docker run ghcr.io/perrin4869/slackbuilds:15.0
  sbolint --version`, which prints sbo-maintainer-tools' own bundled
  version) rather than a separately-tracked state file that could drift
  from reality, then directly dispatches `image.yml` if it's behind.

Both jobs are inlined directly in `image-deps.yml` rather than calling a
shared script, since each is only ever invoked from its own one job.
