#!/bin/bash
# Resolve the latest valid upstream version for one or all tracked packages.
#
# Usage:
#   scripts/detect.sh                 # all packages/*.conf
#   scripts/detect.sh tree-sitter     # a single package by PRGNAM
#
# For each package, prints one line to stdout:
#   NEEDS_UPDATE <prgnam> <category> <new_version>   an update PR should be opened
#   FROZEN <prgnam> <reason> (N behind: <latest>)     skipped, reported for the summary
#   UP_TO_DATE <prgnam> <version>                     nothing to do
#   UNRESOLVED <prgnam>                               couldn't determine a latest version
#
# Diagnostics go to stderr so stdout stays script-parseable (consumed by
# detect.yml to decide which packages to run generate.sh against).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

# An update is only "needed" if it beats both what upstream currently ships
# AND the last version this repo already opened a PR for (which may still
# be sitting in review upstream) - the .conf VERSION exists purely to avoid
# filing the same PR twice.
already_pending() {
    local prgnam="$1" version="$2"
    gh pr list --repo "$(git config --get remote.origin.url | sed -E 's#.*[:/]([^/]+/[^/.]+)(\.git)?$#\1#')" \
        --state open --head "update/${prgnam}-${version}" --json number --jq 'length > 0' 2>/dev/null || echo false
}

resolve_latest() {
    local conf_source="$1"
    case "$conf_source" in
        github)
            [ -n "${GITHUB_REPO:-}" ] || die "$PRGNAM: SOURCE=github but GITHUB_REPO not set"
            [ -n "${TAG_REGEX:-}" ] || die "$PRGNAM: SOURCE=github but TAG_REGEX not set"
            resolve_github_version "$GITHUB_REPO" "$TAG_REGEX"
            ;;
        codeberg)
            [ -n "${CODEBERG_REPO:-}" ] || die "$PRGNAM: SOURCE=codeberg but CODEBERG_REPO not set"
            [ -n "${TAG_REGEX:-}" ] || die "$PRGNAM: SOURCE=codeberg but TAG_REGEX not set"
            resolve_codeberg_version "$CODEBERG_REPO" "$TAG_REGEX"
            ;;
        kernel-cgit)
            [ -n "${CGIT_URL:-}" ] || die "$PRGNAM: SOURCE=kernel-cgit but CGIT_URL not set"
            [ -n "${TAG_REGEX:-}" ] || die "$PRGNAM: SOURCE=kernel-cgit but TAG_REGEX not set"
            resolve_kernel_cgit_version "$CGIT_URL" "$TAG_REGEX"
            ;;
        sourcehut-hg)
            [ -n "${SRHT_REPO:-}" ] || die "$PRGNAM: SOURCE=sourcehut-hg but SRHT_REPO not set"
            [ -n "${TAG_REGEX:-}" ] || die "$PRGNAM: SOURCE=sourcehut-hg but TAG_REGEX not set"
            resolve_sourcehut_hg_version "$SRHT_REPO" "$TAG_REGEX"
            ;;
        *)
            log "warn: $PRGNAM: no version resolver implemented for SOURCE=$conf_source"
            ;;
    esac
}

check_one() {
    local conf="$1"
    load_package_conf "$conf"

    local latest
    latest="$(resolve_latest "$SOURCE" || true)"

    if [ "${FROZEN:-0}" = "1" ]; then
        if [ -n "$latest" ] && version_gt "$latest" "$VERSION"; then
            echo "FROZEN $PRGNAM ${FROZEN_REASON:-frozen} (behind: $latest)"
        else
            echo "FROZEN $PRGNAM ${FROZEN_REASON:-frozen}"
        fi
        return
    fi

    if [ -z "$latest" ]; then
        echo "UNRESOLVED $PRGNAM"
        return
    fi

    local upstream
    upstream="$(upstream_version "$CATEGORY" "$PRGNAM")"
    if [ -z "$upstream" ]; then
        log "warn: $PRGNAM: not found at ${CATEGORY}/${PRGNAM} upstream (moved/renamed?)"
        upstream="$VERSION"
    fi

    if ! version_gt "$latest" "$upstream" || ! version_gt "$latest" "$VERSION"; then
        echo "UP_TO_DATE $PRGNAM $upstream"
        return
    fi

    if [ "$(already_pending "$PRGNAM" "$latest")" = "true" ]; then
        log "info: $PRGNAM: PR for $latest already open, skipping"
        echo "UP_TO_DATE $PRGNAM $upstream"
        return
    fi

    echo "NEEDS_UPDATE $PRGNAM $CATEGORY $latest"
}

if [ $# -eq 1 ]; then
    conf="packages/$1.conf"
    [ -f "$conf" ] || die "no such package config: $conf"
    check_one "$conf"
else
    for conf in packages/*.conf; do
        [ -e "$conf" ] || continue
        check_one "$conf"
    done
fi
