# slackbuilds

Maintainer pipeline for Julian Grinblat's (`julian@dotcore.co.il`) packages on
[SlackBuilds.org](https://slackbuilds.org/). It detects upstream releases,
opens an update PR here, builds and lints it, and after merge opens the PR
against `SlackBuildsOrg/slackbuilds` from `perrin4869/sbo`.

```
upstream release ──▶ webhook.yml / poll.yml open a PR here
                          │
                          ▼
                    check.yml: sbolint + sbopkg -B -i + sbopkglint
                          │
                     review + merge
                          │
                          ▼
                    submit.yml: opens the PR upstream
```

## Layout

- `sbo/<category>/<prgnam>/` - each package's `.info`/`.SlackBuild`, as in
  `SlackBuildsOrg/slackbuilds`. An update PR's **Files changed** tab is the
  diff that gets submitted. `submit.yml` regenerates against fresh upstream
  at merge time and notes it on the upstream PR if the result differs.
- `packages/<prgnam>.conf` - how to detect and regenerate each package.
- `scripts/lib.sh` - shared functions for the workflows.
- `scripts/rust-info.sh` - crate list generator for Rust packages.
- `scripts/update-package.sh <prgnam> <version>` - regenerates a package
  locally, the same way CI does. Only touches the working tree.

## Adding a package

Copy `sbo/<category>/<prgnam>/` from upstream, then add
`packages/<prgnam>.conf`:

| Field | |
|---|---|
| `CATEGORY`, `PRGNAM` | As upstream. |
| `SOURCE` | Repository URL. For `github.com`/`codeberg.org` it also selects the version check. |
| `TAG_REGEX` | Anchored ERE; capture group 1 is the version. Filters out test tags, backports and the like. |
| `DOWNLOAD_URL` | Source URL with `%VERSION%`. |
| `STRATEGY` | `tarball` (default) or `rust` (regenerates the crate list). |
| `X86_64_ONLY=1` | Writes `DOWNLOAD_x86_64` instead of `DOWNLOAD`. |
| `CHECK_IMAGE` | Image variant for `check.yml` (`rust-opt`, `google-go-lang`). |
| `POLL=1` | For hosts with no API: checked weekly with nvchecker's `regex` source on `NVCHECKER_URL`/`NVCHECKER_REGEX`. |
| `FROZEN=1`, `FROZEN_REASON` | Never opens a PR; the run summary still reports how far behind it is. |

## Detection

- `webhook.yml` handles `repository_dispatch: upstream-release` events from a
  [newreleases.io](https://newreleases.io/) webhook and uses the version in
  the payload. It can also be run by hand with `workflow_dispatch`.
- `poll.yml` checks `POLL=1` packages weekly with
  [nvchecker](https://github.com/lilydjwg/nvchecker), or any single package
  by hand.
- `sync-newreleases.yml` adds every non-`POLL`, non-`FROZEN` GitHub package to
  newreleases.io when `packages/*.conf` changes on master.

Each package has one update branch, `update/<prgnam>`. A newer release
updates the open PR instead of opening another one.

newreleases.io webhook payload template:

```json
{
  "event_type": "upstream-release",
  "client_payload": {
    "project": "{project}",
    "version": "{version}"
  }
}
```

## Secrets

| Secret | Used by | Purpose |
|---|---|---|
| `SBO_SUBMIT_TOKEN` | `submit.yml` | Classic PAT with `repo` and `workflow` scopes. A fine-grained PAT can't open PRs on a repo you don't own. `workflow` is needed to sync `perrin4869/sbo` and push to it once upstream has changed its workflow files. |
| `SBO_UPDATE_PR_TOKEN` | `open-update-prs.yml`, `image-deps.yml` | Fine-grained PAT for this repo, Contents and Pull requests read/write. Workflows on PRs opened by `github-actions[bot]` need manual approval. |
| `NEWRELEASES_API_KEY` | `sync-newreleases.yml` | newreleases.io API key. |
| `NEWRELEASES_WEBHOOK_ID` | `sync-newreleases.yml` | Id of the newreleases.io webhook pointing at `https://api.github.com/repos/perrin4869/slackbuilds/dispatches`, with `Authorization: Bearer <PAT>`, `Accept: application/vnd.github+json` and the payload template above. |

## Security

Webhook payloads, PR diff paths and upstream tags are untrusted. Pass them to
`run:` steps through `env:` and read them as `"$VAR"`. Never write
`${{ }}` inside a script, since GitHub substitutes it as text before the shell
parses it ([script injection](https://docs.github.com/en/actions/reference/security/secure-use#good-practices-for-mitigating-script-injection-attacks)).

## Images

`image.yml` builds `ghcr.io/perrin4869/slackbuilds:15.0` on Dockerfile
changes and monthly. It also builds `slackbuilds-rust-opt` and
`slackbuilds-google-go-lang`, which preinstall that toolchain for packages
that set `CHECK_IMAGE`.

`image-deps.yml` runs weekly:

- **sbopkg** is pinned by `SBOPKG_VERSION` in the Dockerfile. A new release
  opens a PR to bump it.
- **sbo-maintainer-tools** comes from SBo at build time. When SBo's `15.0`
  branch has a newer version than the image, the job triggers a rebuild.
