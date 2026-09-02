#!/bin/bash
# Render the markdown body for an update PR.
#
# Packages live at <category>/<prgnam>/ in this repo - the exact same path
# they occupy in SlackBuildsOrg/slackbuilds - so the PR's own "Files
# changed" tab already *is* the real diff (full GitHub review UI: inline
# comments, viewed checkboxes, etc.), not something that needs restating
# here. This just states what merging it will do.
#
# Usage:
#   scripts/preview.sh <prgnam> <version>

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

prgnam="${1:?prgnam required}"
version="${2:?version required}"

conf="packages/${prgnam}.conf"
load_package_conf "$conf"
[ "$prgnam" = "$PRGNAM" ] || die "packages/${prgnam}.conf declares PRGNAM=$PRGNAM"

commit_msg="${CATEGORY}/${PRGNAM}: Updated for version ${version}"

cat <<EOF
Detected upstream update: **${CATEGORY}/${PRGNAM} → ${version}**.

The diff below (**Files changed** tab) is exactly what merging this PR
submits to
[SlackBuildsOrg/slackbuilds](https://github.com/SlackBuildsOrg/slackbuilds)
as \`${SBO_FORK:-perrin4869/sbo}:${PRGNAM}/${version}\` - modulo one thing:
\`submit.yml\` re-derives it against a fresh upstream clone at merge time
rather than trusting what's reviewed here, in case upstream moved since
this PR was opened. If that happens it'll say so on the resulting upstream
PR.

> **${commit_msg}**
EOF
