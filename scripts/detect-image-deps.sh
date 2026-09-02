#!/bin/bash
# Detect a new sbopkg release and open a PR bumping the SBOPKG_VERSION ARG
# in the Dockerfile. Not an SBo package - has its own tiny flow rather than
# reusing packages/*.conf + generate.sh, which are shaped around
# .info/.SlackBuild pairs.
#
# Merging the resulting PR triggers image.yml automatically (it watches
# `Dockerfile` on push to master).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

current="$(sed -n 's/^ARG SBOPKG_VERSION="\(.*\)"$/\1/p' Dockerfile)"
[ -n "$current" ] || die "couldn't find ARG SBOPKG_VERSION=\"...\" in Dockerfile"

latest="$(resolve_github_version sbopkg/sbopkg '^([0-9]+\.[0-9]+\.[0-9]+)$')"
if [ -z "$latest" ] || ! version_gt "$latest" "$current"; then
    echo "UP_TO_DATE sbopkg $current"
    exit 0
fi

branch="image/sbopkg-${latest}"
if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    echo "UP_TO_DATE sbopkg $current (branch $branch already open)"
    exit 0
fi

sed -i "s/^ARG SBOPKG_VERSION=\".*\"$/ARG SBOPKG_VERSION=\"${latest}\"/" Dockerfile

git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git checkout -b "$branch"
git add Dockerfile
git commit -m "Dockerfile: bump sbopkg to ${latest}"
git push origin "$branch"

gh pr create \
    --title "Dockerfile: bump sbopkg to ${latest}" \
    --body "sbopkg ${latest} released (was ${current}). Merging rebuilds and pushes ghcr.io/perrin4869/slackbuilds:15.0 automatically." \
    --head "$branch" --base master

echo "NEEDS_UPDATE sbopkg $latest"
