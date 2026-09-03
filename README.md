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

Scripts are used sparingly, and only where they genuinely have to be.
Some functions need to be callable from *inside a bash loop* (`poll.yml`'s
own Detect step, `sync-newreleases.yml`), which a reusable GitHub Action
can't be - actions are static workflow steps, not something you invoke
dynamically from within a loop. Others are called from more than one
*workflow file*, each just once per job - a plain function still, not
because of the loop constraint, but because there's no single shared job
to factor them into (see `generate_package()`/`render_pr_body()` below).
Anything else lives directly in the workflow that calls it, or as a
reusable workflow if more than one workflow needs the whole job.

- `packages/<prgnam>.conf` - one file per tracked package: category, upstream
  source, tag-matching regex, `STRATEGY` (`tarball`, the default, or
  `rust`/`rust64`), and `FROZEN=1` for packages that can't be updated right
  now (see below).
- `scripts/lib.sh` - shared helpers, sourced by every workflow that needs
  them: version resolvers per `SOURCE` type, `.info` parsing,
  `generate_package()` (regenerates `.info`+`.SlackBuild` from a fresh
  upstream checkout) and `render_pr_body()` - each called once per job,
  but from two different workflow files (`open-update-prs.yml`'s step and
  `submit.yml`'s), so they stay plain functions rather than one workflow
  owning them.
- `scripts/rust-info.sh` / `rust64-info.sh` - unchanged crate-list generators
  for Rust packages (originally run by hand; see `generate_package()`'s
  `rust`/`rust64` case for the invocation). Kept as real scripts, not
  functions - substantial standalone tools in their own right, not glue.
- `.github/workflows/open-update-prs.yml` - a *reusable* workflow
  (`on: workflow_call`, inputs `prgnam`/`category`/`version`), called once
  per `NEEDS_UPDATE` line by both `webhook.yml` and `poll.yml`. It
  regenerates the package (`generate_package()`), then hands the result
  to [`peter-evans/create-pull-request`](https://github.com/peter-evans/create-pull-request)
  to branch/commit/push/open (or update) the PR - see "Opening the PR"
  below for why that's a marketplace action here and not our own
  git/`gh` plumbing.

There's deliberately no `detect` action - `poll.yml` is the only workflow
that resolves a version by scanning (`check_one()`, via `resolve_latest()`),
so that loop is inlined directly into its own "Detect" step rather than
factored out for a single caller. `webhook.yml` never scans: it already
has a version from the webhook payload (or a manual dispatch input) and
calls `check_known()` instead - see "Detection" below. Both eventually
call the same `check_result()` to decide FROZEN/UP_TO_DATE/NEEDS_UPDATE
and format the output line; only how the candidate version was obtained
differs.

Both workflows turn their `check_one`/`check_known` output into a JSON
array of `{prgnam, category, version}` (one per `NEEDS_UPDATE` line) and
call `open-update-prs.yml` via `strategy: matrix` - one isolated job per
package, run on its own runner. That isolation is what makes a
subshell-resilience pattern unnecessary there: a runner-level failure in
one package's job (a `die()`, a network blip regenerating it) can't
affect any other package's job at all, matrix jobs don't share process
state the way a bash loop's iterations do. `poll.yml`'s own Detect step
and `sync-newreleases.yml` still loop over packages *within* one job, so
they still wrap each iteration in a subshell (`name() ( ... )`, parens
not braces) for the same reason established earlier in this file: `die()`
called directly, or via a plain function, aborts the *entire* loop under
`set -e`, silently skipping every remaining package while still
reporting the job as fine. In a subshell, `exit 1` only ends that one
iteration; the caller catches it with `||` and moves on.

`detect`-shaped output (and the JSON matrix built from it) carries data
that ultimately derives from upstream tag names, not just this repo's
own config - so callers pass it via `env:` rather than interpolating
`${{ }}` directly into a `run:` script body. The latter is a real GitHub
Actions footgun: `${{ }}` in a `run:` block is substituted as raw text
*before* the shell parses it, so untrusted content there can break out
of the intended command. An `env:` value becomes a plain environment
variable instead - substituted once, read safely as `"$VAR"`. (Passing
the same data as a job/action *input*, as `open-update-prs.yml`'s
`prgnam`/`category`/`version` or `create-pull-request`'s `with:` fields
do, is fine either way - the runner delivers those as plain strings, not
something the shell re-parses.)

**Opening the PR**: `open-update-prs.yml`'s own `run:` step only
regenerates the package into the checkout (`generate_package()`,
`render_pr_body()`, the `VERSION` bump, `UPDATE.json`) - branching,
committing, pushing, and creating (or updating) the PR itself is
`peter-evans/create-pull-request`, not custom git/`gh` plumbing. It
already handles what used to be hand-rolled here: if a branch for that
exact `prgnam`/`version` already exists with no differences from what
was just regenerated, it's a no-op (no needless push, no PR churn); if
the branch doesn't exist yet, it creates one and opens the PR. One
caveat worth noting because it's easy to forget: its `committer`/`author`
inputs are set explicitly to the same `github-actions[bot]` identity
regardless of what triggered the run - its own defaults would otherwise
vary (`author` defaults to whoever/whatever triggered the workflow,
which differs between a webhook `repository_dispatch`, a `poll.yml` cron,
and a manual `workflow_dispatch`).

A local variable-naming trap worth documenting since it silently
produced wrong output once, verified while writing this: `generate_package`/
`render_pr_body` call `load_package_conf`, which resets and re-sources
`PRGNAM`/`CATEGORY`/`VERSION` (and friends) from the package's `.conf`.
`open-update-prs.yml`'s own step copies its inputs into **lowercase**
locals (`prgnam`/`category`/`version`) before calling either function,
specifically so its own tracking variables don't share a name with (and
get silently overwritten by) those globals right after the first call.

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

`STRATEGY` defaults to `tarball` (download the source archive, compute its
md5, done) and only needs to be set explicitly for `rust`/`rust64` (crate
list regenerated via `scripts/rust-info.sh`/`rust64-info.sh`).

Freezing a package (e.g. blocked on a Slackware/glibc version) adds:

```sh
FROZEN=1
FROZEN_REASON="why, and what unblocks it"
```

`check_result()` skips frozen packages but still reports how far behind
they are in the run summary, so they don't rot silently.

## Detection

`webhook.yml` runs on a `repository_dispatch: upstream-release` event, fired
by a [newreleases.io](https://newreleases.io/) webhook watching each
tracked project, or manually via `workflow_dispatch`.

The webhook payload names which project changed and its new version
(`client_payload.project` / `client_payload.version`), so a firing is
scoped to just that one package (mapped back to a `prgnam` by matching
`SOURCE`'s `owner/repo` in `packages/*.conf`) and trusts that version
directly (`check_known()`) instead of scanning every tag for candidates -
newreleases.io already did that. It's still run through `TAG_REGEX` (not
as a filter over a full candidate list here, just to extract/normalize
the version the same way a full scan would) and the normal
`version_gt`-against-upstream check, so a garbage value can't silently
look like a real update; anything that still gets through is a PR to
review before merging, same as any other update. If the version doesn't
match `TAG_REGEX` (an unexpected tag shape), that package is reported
`UNRESOLVED` rather than falling back to a scan here - re-scanning on
every webhook firing to double-check what newreleases.io just told us
would defeat the point of it telling us; a package stuck `UNRESOLVED`
this way gets picked up by `poll.yml`'s own cron regardless (below), or
can be checked immediately with its `workflow_dispatch`. If the payload
names a project no `.conf` matches at all (a misconfigured webhook, or a
package not yet added here), `webhook.yml` just warns and does nothing -
same reasoning: it reacts to known versions, it doesn't go looking for
them.

**Webhook payload template** (newreleases.io → your webhook → payload
fields), since the default payload doesn't reach GitHub in a form it
accepts - `repository_dispatch` requires the POST body shaped exactly as
below:

```json
{
  "event_type": "upstream-release",
  "client_payload": {
    "project": "{project}",
    "version": "{version}"
  }
}
```

`{project}` and `{version}` are newreleases.io's own template variables:
`{project}` is the `provider/name` of whichever tracked project fired
(e.g. `jj-vcs/jj`) - matching the `owner/repo` path of that package's
`SOURCE` URL exactly - and `{version}` is that release's tag/version
string as newreleases.io itself resolved it (projects are registered
with `exclude_prereleases: true` - see `sync-newreleases.yml` below - so
this is never a pre-release).

`webhook.yml` has no cron and no scanning fallback of its own - it only
ever checks a version it's already been given. All scanning (the
`resolve_latest()`/`TAG_REGEX`-candidate-list/`nvchecker` machinery) lives
in exactly one place:

- **`poll.yml`** (weekly cron + `workflow_dispatch`) is the only workflow
  that resolves a version by scanning (`check_one()`). Its cron checks
  every `POLL=1` package - `wofi` (hg.sr.ht) and `libtraceevent`
  (git.kernel.org/cgit) currently, neither of which hosts an API of any
  kind for a service like newreleases.io to watch, so polling is the only
  option there. Its `workflow_dispatch` additionally takes an optional
  `package` input naming *any* package, not just `POLL=1` ones - the one
  remaining way to scan a github/codeberg package on demand, since
  `webhook.yml`'s own `workflow_dispatch` only simulates a webhook firing
  (it still requires a known version as input, it doesn't scan either).
  Both `poll.yml` and `webhook.yml` finish the same way regardless -
  `open-update-prs` for every `NEEDS_UPDATE` line - push vs. pull only
  changes *how a candidate version was obtained*, not what happens once
  one is.

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
