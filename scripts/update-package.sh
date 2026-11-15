#!/bin/bash
# Regenerate sbo/<category>/<prgnam>/ for <version>, the same way
# open-update-prs.yml does. Only touches the working tree.
#
# Usage: scripts/update-package.sh <prgnam> <version>

set -euo pipefail

source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/lib.sh"

prgnam="${1:?usage: $0 <prgnam> <version>}"
version="${2:?usage: $0 <prgnam> <version>}"

conf="$PACKAGES_DIR/${prgnam}.conf"
[ -f "$conf" ] || die "no such package: $conf"
load_package_conf "$conf"

# Cached between local runs; CI starts from an empty cache each time.
upstream_dir="${XDG_CACHE_HOME:-$HOME/.cache}/slackbuilds/upstream"
if [ -d "$upstream_dir/.git" ]; then
    log "updating cached upstream checkout at $upstream_dir"
    git -C "$upstream_dir" fetch --quiet --depth 1 origin "$UPSTREAM_REF"
    git -C "$upstream_dir" checkout --quiet --detach FETCH_HEAD
else
    log "cloning ${UPSTREAM_OWNER}/${UPSTREAM_REPO}@${UPSTREAM_REF} into $upstream_dir"
    mkdir -p "$(dirname "$upstream_dir")"
    git clone --quiet --depth 1 --branch "$UPSTREAM_REF" \
        "https://github.com/${UPSTREAM_OWNER}/${UPSTREAM_REPO}.git" "$upstream_dir"
fi

# Generate aside so a failure leaves the tracked copy alone.
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
generate_package "$prgnam" "$version" "$upstream_dir" "$tmp_dir"

out_dir="$SBO_DIR/${CATEGORY}/${PRGNAM}"
mkdir -p "$out_dir"
cp "$tmp_dir/${PRGNAM}.info" "$tmp_dir/${PRGNAM}.SlackBuild" "$out_dir/"
log "updated $out_dir"
