#!/bin/bash
# Regenerate one tracked package's .info/.SlackBuild for a given version,
# from a fresh upstream checkout - the same regeneration open-update-prs.yml
# runs in CI, callable locally to preview an update before the real
# pipeline picks it up. Only touches sbo/<category>/<prgnam>/ in the
# working tree - never commits, pushes, or opens anything.
#
# Usage: scripts/update-package.sh <prgnam> <version>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source scripts/lib.sh

prgnam="${1:?usage: $0 <prgnam> <version>}"
version="${2:?usage: $0 <prgnam> <version>}"

conf="packages/${prgnam}.conf"
[ -f "$conf" ] || die "no such package: $conf"
load_package_conf "$conf"

# Unlike CI (a fresh ephemeral runner every time, nothing to gain from
# caching), this repo gets cloned and re-fetched over and over across
# separate local invocations - cached under XDG_CACHE_HOME, since it's
# exactly the kind of disposable, regenerable-on-demand data that's for
# (see the FHS's own near-identical description of /var/cache).
upstream_dir="${XDG_CACHE_HOME:-$HOME/.cache}/slackbuilds/upstream"
if [ -d "$upstream_dir/.git" ]; then
    log "updating cached upstream checkout at $upstream_dir"
    git -C "$upstream_dir" fetch --quiet --depth 1 origin "$UPSTREAM_REF"
    git -C "$upstream_dir" reset --quiet --hard FETCH_HEAD
else
    log "cloning ${UPSTREAM_OWNER}/${UPSTREAM_REPO}@${UPSTREAM_REF} into $upstream_dir"
    mkdir -p "$(dirname "$upstream_dir")"
    git clone --quiet --depth 1 --branch "$UPSTREAM_REF" \
        "https://github.com/${UPSTREAM_OWNER}/${UPSTREAM_REPO}.git" "$upstream_dir"
fi

out_dir="sbo/${CATEGORY}/${PRGNAM}"
rm -rf "$out_dir"
mkdir -p "$out_dir"
generate_package "$prgnam" "$version" "$upstream_dir" "$out_dir"

log "updated $out_dir/${PRGNAM}.info and ${PRGNAM}.SlackBuild - review with git diff, nothing committed"
