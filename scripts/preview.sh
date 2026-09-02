#!/bin/bash
# Render a markdown preview, for a PR body, of exactly what submit.sh will
# push to SlackBuildsOrg/slackbuilds once this PR is merged: the commit
# message it'll use and a real unified diff against the true upstream
# paths (category/prgnam/...), not the staging/ prefix this repo uses to
# hold the same files for review.
#
# Usage:
#   scripts/preview.sh <prgnam> <version> <upstream_dir> <staging_dir>
#
# <upstream_dir> a checkout of SlackBuildsOrg/slackbuilds (unmodified -
# this only reads from it). <staging_dir> the freshly generate.sh'd
# <prgnam>.info/.SlackBuild. Prints markdown to stdout.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

prgnam="${1:?prgnam required}"
version="${2:?version required}"
upstream_dir="${3:?upstream checkout dir required}"
staging_dir="${4:?staging dir required}"

conf="packages/${prgnam}.conf"
load_package_conf "$conf"
[ "$prgnam" = "$PRGNAM" ] || die "packages/${prgnam}.conf declares PRGNAM=$PRGNAM"

upstream_pkg_dir="${upstream_dir}/${CATEGORY}/${PRGNAM}"
commit_msg="${CATEGORY}/${PRGNAM}: Updated for version ${version}"

# Unified diff of one file against the true upstream path, as it will
# appear once submitted - not staging/'s path for it. --label overrides
# diff's a/b paths so the output reads exactly like the real PR's diff.
preview_diff() {
    local filename="$1" old="$upstream_pkg_dir/$1" new="$staging_dir/$1"
    [ -f "$old" ] || old=/dev/null
    diff -u \
        --label "${CATEGORY}/${PRGNAM}/${filename}" \
        --label "${CATEGORY}/${PRGNAM}/${filename}" \
        "$old" "$new" || true
}

info_diff="$(preview_diff "${PRGNAM}.info")"
slackbuild_diff="$(preview_diff "${PRGNAM}.SlackBuild")"
# Count of actual +/- changed lines, excluding the --- / +++ header lines
# (which also start with a single +/- but aren't diff hunk content).
info_changed="$(printf '%s\n' "$info_diff" | tail -n +3 | grep -cE '^[+-]' || true)"

cat <<EOF
Detected upstream update: **${CATEGORY}/${PRGNAM} → ${version}**.

Merging this PR (once \`check.yml\` passes) submits the diff below to
[SlackBuildsOrg/slackbuilds](https://github.com/SlackBuildsOrg/slackbuilds)
as \`${SBO_FORK:-perrin4869/sbo}:${PRGNAM}/${version}\`:

> **${commit_msg}**

<details><summary><code>${PRGNAM}.SlackBuild</code></summary>

\`\`\`diff
${slackbuild_diff}
\`\`\`

</details>

<details$([ "$info_changed" -le 20 ] && echo ' open')><summary><code>${PRGNAM}.info</code> (${info_changed} lines changed)</summary>

\`\`\`diff
${info_diff}
\`\`\`

</details>

*This preview is computed directly from the files below (\`staging/${CATEGORY}/${PRGNAM}/\`) against a fresh clone of upstream at PR-open time - what actually gets submitted is re-derived from upstream again at merge time in case it moved since. See \`submit.yml\` for that re-check.*
EOF
