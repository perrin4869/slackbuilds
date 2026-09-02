#!/bin/bash
# Given detect.sh's output, open an update PR here for every NEEDS_UPDATE
# line: regenerate the package at its real upstream path, render the PR
# body, bump the .conf's dedupe VERSION, commit, push, and open the PR.
#
# Shared by detect.yml (push/webhook-triggered) and detect-pull.yml
# (cron-triggered) - opening a PR is the same step regardless of how the
# update was detected.
#
# Usage:
#   scripts/open-update-prs.sh <detect-output-file>
#
# Requires GH_TOKEN (or gh already authenticated) and a git identity - sets
# one for github-actions[bot] if none is configured.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

detect_output="${1:?detect-output file required}"

git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

while read -r status prgnam category version; do
    [ "$status" = NEEDS_UPDATE ] || continue

    branch="update/${prgnam}-${version}"
    echo "::group::${prgnam} -> ${version}"

    git fetch origin "$branch" 2>/dev/null && {
        echo "branch $branch already exists, skipping"
        echo "::endgroup::"
        continue
    }

    upstream_dir="$(mktemp -d)"
    git clone --quiet --depth 1 --branch master \
        https://github.com/SlackBuildsOrg/slackbuilds.git "$upstream_dir"
    upstream_sha="$(git -C "$upstream_dir" rev-parse HEAD)"

    rm -rf "${category}/${prgnam}"
    mkdir -p "${category}/${prgnam}"
    bash scripts/generate.sh "$prgnam" "$version" "$upstream_dir" "${category}/${prgnam}"

    bash scripts/preview.sh "$prgnam" "$version" > /tmp/pr-body.md

    cat > "${category}/${prgnam}/UPDATE.json" <<EOF
{
  "prgnam": "$prgnam",
  "category": "$category",
  "version": "$version",
  "upstream_sha": "$upstream_sha"
}
EOF

    sed -i "s/^VERSION=.*/VERSION=$version/" "packages/${prgnam}.conf"

    git checkout -b "$branch"
    git add "${category}/${prgnam}" "packages/${prgnam}.conf"
    git commit -m "${category}/${prgnam}: Updated for version ${version}"
    git push origin "$branch"

    gh pr create \
        --title "${category}/${prgnam}: Updated for version ${version}" \
        --body-file /tmp/pr-body.md \
        --head "$branch" --base master

    git checkout -
    rm -rf "$upstream_dir"
    echo "::endgroup::"
done < "$detect_output"
