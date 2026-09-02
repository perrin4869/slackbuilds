#!/bin/bash
# Detect new releases of the image's own build-time dependencies (not SBo
# packages - has its own tiny flow rather than reusing packages/*.conf +
# generate.sh, which are shaped around .info/.SlackBuild pairs).
#
# - sbopkg is pinned via the Dockerfile's SBOPKG_VERSION ARG, so a new
#   release opens a PR bumping it; merging triggers image.yml (it watches
#   `Dockerfile` on push to master).
# - sbo-maintainer-tools has no such pin - the Dockerfile just installs
#   whatever `sbopkg -B -i sbo-maintainer-tools` finds in the SBo mirror at
#   build time - so there's no line to bump and no diff to review. A new
#   release just needs a rebuild, tracked here (image/sbo-maintainer-tools.version)
#   purely to avoid redispatching one every run.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

check_sbopkg() {
    local current latest branch
    current="$(sed -n 's/^ARG SBOPKG_VERSION="\(.*\)"$/\1/p' Dockerfile)"
    [ -n "$current" ] || die "couldn't find ARG SBOPKG_VERSION=\"...\" in Dockerfile"

    latest="$(resolve_github_version sbopkg/sbopkg '^([0-9]+\.[0-9]+\.[0-9]+)$')"
    if [ -z "$latest" ] || ! version_gt "$latest" "$current"; then
        echo "UP_TO_DATE sbopkg $current"
        return
    fi

    branch="image/sbopkg-${latest}"
    if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
        echo "UP_TO_DATE sbopkg $current (branch $branch already open)"
        return
    fi

    sed -i "s/^ARG SBOPKG_VERSION=\".*\"$/ARG SBOPKG_VERSION=\"${latest}\"/" Dockerfile
    git checkout --quiet -b "$branch"
    git add Dockerfile
    git commit --quiet -m "Dockerfile: bump sbopkg to ${latest}"
    git push --quiet origin "HEAD:refs/heads/${branch}"

    gh pr create \
        --title "Dockerfile: bump sbopkg to ${latest}" \
        --body "sbopkg ${latest} released (was ${current}). Merging rebuilds and pushes ghcr.io/perrin4869/slackbuilds:15.0 automatically." \
        --head "$branch" --base master

    git checkout --quiet -
    echo "NEEDS_UPDATE sbopkg $latest"
}

check_sbo_maintainer_tools() {
    local state_file="image/sbo-maintainer-tools.version" current latest

    current="$(cat "$state_file" 2>/dev/null || echo 0)"
    latest="$(resolve_kernel_cgit_version \
        "https://slackware.uk/~urchlay/repos/sbo-maintainer-tools" \
        '^([0-9]+(\.[0-9]+)+)$')"

    if [ -z "$latest" ] || ! version_gt "$latest" "$current"; then
        echo "UP_TO_DATE sbo-maintainer-tools $current"
        return
    fi

    mkdir -p "$(dirname "$state_file")"
    printf '%s\n' "$latest" > "$state_file"
    git add "$state_file"
    git commit --quiet -m "image: sbo-maintainer-tools ${latest} released, rebuild"
    git push --quiet origin master

    gh workflow run image.yml --ref master

    echo "NEEDS_UPDATE sbo-maintainer-tools $latest"
}

git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

check_sbopkg
check_sbo_maintainer_tools
